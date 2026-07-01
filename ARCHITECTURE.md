# ARCHITECTURE.md — envless System Design

> **Version:** v0.0.1 (pre-1.0) · **Zig:** 0.16.0 · **License:** Apache-2.0

## 1. System Overview

envless is an **agent-first secrets manager** that replaces plaintext
`.env` files with sops-encrypted, git-committed dotenv files. It is a
single Zig binary with zero runtime dependencies beyond libc, composing
two external binaries (`age-keygen`, `sops`) for cryptography.

### Design philosophy

| Principle                | How                                                                                                     |
|--------------------------|---------------------------------------------------------------------------------------------------------|
| **No new crypto**        | All encryption delegated to age + sops (both audited). envless adds zero crypto code.                   |
| **Stateless by default** | Every CLI command reads from disk, shells out, and exits. No resident state unless explicitly opted in. |
| **Single binary**        | One static ~150 KB binary. No runtime, no GC, no language VM.                                           |
| **Agent-native**         | MCP server (JSON-RPC over stdio) lets AI agents call envless as a structured tool, not a shell-out.     |
| **Composable**           | Unix philosophy — does one thing (encrypted dotenv in git), delegates the rest to sops/age/your CI.     |

### Three modes of operation

```
 ┌─────────────────────────────────────────────────────────┐
 │                    envless binary                       │
 │                                                         │
 │  ┌──────────┐  ┌───────────┐  ┌──────────────────────┐  │
 │  │ CLI mode │  │ Daemon    │  │ MCP server           │  │
 │  │ (default)│  │ (opt-in)  │  │ (opt-in)             │  │
 │  │          │  │           │  │                      │  │
 │  │ init     │  │ Unix sock │  │ JSON-RPC 2.0 / stdio │  │
 │  │ set      │  │ LRU cache │  │ 8 tools              │  │
 │  │ get      │  │ 32 entries│  │ routes to daemon     │  │
 │  │ list     │  │ 60s TTL   │  │ when socket is live  │  │
 │  │ exec     │  │           │  │                      │  │
 │  │ migrate  │  │           │  │                      │  │
 │  │ backup   │  │           │  │                      │  │
 │  └────┬─────┘  └─────┬─────┘  └───────────┬──────────┘  │
 │       │              │                    │             │
 └───────┼──────────────┼────────────────────┼─────────────┘
         │              │                    │
         ▼              ▼                    ▼
    ┌─────────┐   ┌──────────┐        ┌───────────┐
    │ sops +  │   │ sops +   │        │ CLI /     │
    │ age     │   │ age      │        │ daemon    │
    │ binaries│   │ binaries │        │ path      │
    └─────────┘   └──────────┘        └───────────┘
         │              │
         ▼              ▼
    ┌─────────────────────────┐
    │  secrets/<env>.env.enc  │
    │  .envless/identity.key  │
    │  .envless/recipients    │
    └─────────────────────────┘
```

## 2. Component Breakdown

All source lives under `zig/src/`. Total: ~5,988 LOC (including inline
tests).

### Core modules

| Module            | LOC | Responsibility                                                                         |
|-------------------|-----|----------------------------------------------------------------------------------------|
| `main.zig`        | 24  | argv entry, `--version` flag, dispatch to `cli/root.zig`                               |
| `cli/root.zig`    | 339 | Subcommand dispatcher, flag parsing (`--env`, `--confirm`, `--keep`), `Context` struct |
| `cli/init.zig`    | 75  | `envless init` — identity bootstrap via `age-keygen`                                   |
| `cli/set.zig`     | 95  | `envless set KEY` — stdin → encrypted file                                             |
| `cli/get.zig`     | 92  | `envless get KEY` — decrypt + print (requires `--confirm`)                             |
| `cli/list.zig`    | 76  | `envless list` — keys only, no values                                                  |
| `cli/exec.zig`    | 143 | `envless exec -- CMD` — decrypt + spawn child with env                                 |
| `cli/migrate.zig` | 229 | `envless migrate FILE` — `.env` → encrypted, append `.gitignore`                       |
| `cli/backup.zig`  | 204 | `envless backup` — tar.gz of encrypted artefacts                                       |
| `cli/daemon.zig`  | 232 | `envless daemon` — start/stop/install/uninstall                                        |
| `cli/mcp.zig`     | 68  | `envless mcp` — start MCP server on stdio                                              |

### Library modules

| Module         | LOC | Responsibility                                                                    |
|----------------|-----|-----------------------------------------------------------------------------------|
| `store.zig`    | 414 | Filesystem layout (`.envless/`, `secrets/`), KV read/write, recipients parsing    |
| `sops.zig`     | 338 | sops binary wrapper — encrypt/decrypt dotenv roundtrip, `KvMap` type              |
| `execenv.zig`  | 269 | Env array merge (parent + secrets), child process spawn via `std.process.run`     |
| `envparse.zig` | 157 | `.env` file parser (quotes, comments, `export` prefix)                            |
| `e2e.zig`      | —   | End-to-end test harness — builds binary, spawns it, asserts on stdout/stderr/exit |

### Optional infrastructure modules

| Module        | LOC  | Responsibility                                                                                                                      |
|---------------|------|-------------------------------------------------------------------------------------------------------------------------------------|
| `daemon.zig`  | 712  | In-memory decrypt-cache daemon: Unix socket server, LRU cache (32 entries, 60s TTL), `handleClient`, `serveExec`                    |
| `ipc.zig`     | 378  | Wire protocol: tab-delimited request/response, `socketPath()`, `encodeOk`/`encodeErr`, base64 argv/stdin for `EXEC`                 |
| `mcp.zig`     | 1037 | MCP server: JSON-RPC 2.0 over stdio, 8 tools (`envs`, `list`, `get`, `set`, `exec`, `init`, `migrate`, `whoami`), daemon auto-route |
| `backup.zig`  | 482  | tar.gz creation, `copyFile`, `isoTimestamp`, `findRepoRoot`, manifest writer                                                        |
| `launchd.zig` | 351  | macOS: generates `~/Library/LaunchAgents/envless.plist`, `load`/`unload`                                                            |
| `systemd.zig` | 273  | Linux: generates `~/.config/systemd/user/envless.service`, `enable`/`start`/`stop`                                                  |

### Dependency graph

```
main.zig
  └─ cli/root.zig
       ├─ cli/init.zig    ──┐
       ├─ cli/set.zig       ├─ store.zig ── sops.zig ── [sops binary]
       ├─ cli/get.zig       │                ├─ envparse.zig
       ├─ cli/list.zig      │                └─ execenv.zig ── [child process]
       ├─ cli/exec.zig      │
       ├─ cli/migrate.zig   │
       ├─ cli/backup.zig ───┼─ backup.zig
       ├─ cli/daemon.zig ───┼─ daemon.zig ── ipc.zig ── [Unix socket]
       └─ cli/mcp.zig ──────┴─ mcp.zig ── ipc.zig (daemon route)
                                         ├─ store.zig
                                         ├─ sops.zig
                                         ├─ execenv.zig
                                         └─ envparse.zig
```

## 3. Data Flow

### 3.1 CLI path (default — stateless)

```
User                CLI                 Store              sops              Disk
 │                   │                   │                  │                 │
 │── envless set ───▶│                   │                  │                 │
 │   KEY (stdin)     │── Read(env) ─────▶│                  │                 │
 │                   │                   │── decrypt ──────▶│── sops decrypt ▶│
 │                   │                   │◀── KvMap ────────│                 │
 │                   │◀── KvMap ─────────│                  │                 │
 │                   │── merge KV ───────│                  │                 │
 │                   │── Write(env) ────▶│                  │                 │
 │                   │                   │── encrypt ──────▶│── sops encrypt ▶│
 │                   │                   │                  │── write .enc ──▶│
 │                   │◀── ok ────────────│                  │                 │
 │◀── "SET env=..." ─│                   │                  │                 │
```

### 3.2 Daemon path (opt-in — cached)

```
Client              Daemon              sops              Disk
 │                   │                   │                 │
 │── EXEC env ──────▶│                   │                 │
 │   (Unix socket)   │── cache lookup    │                 │
 │                   │   key=(repo,env)  │                 │
 │                   │                   │                 │
 │                   │   [hit + fresh]   │                 │
 │                   │   ── return ──────│─────────────────│
 │                   │                   │                 │
 │                   │   [miss/stale]    │                 │
 │                   │── decrypt ───────▶│── sops decrypt ▶│
 │                   │◀── KvMap ─────────│                 │
 │                   │── cache insert    │                 │
 │                   │   (LRU evict if   │                 │
 │                   │    full)          │                 │
 │                   │── spawn child ───────────────────────▶│
 │                   │   (concurrent     │                 │
 │                   │    stdout/stderr  │                 │
 │                   │    drain)         │                 │
 │◀── OK + output ───│                   │                 │
```

### 3.3 MCP path (opt-in — agent-facing)

```
Agent               MCP Server           CLI / Daemon
 │                   │                   │
 │── tools/call ────▶│                   │
 │   "set"           │                   │
 │   {env, key,      │── check daemon ───│
 │    value}         │   socket (100ms)  │
 │                   │                   │
 │                   │   [daemon live]   │
 │                   │   ── route ──────▶│── Unix socket ──▶ Daemon
 │                   │                   │
 │                   │   [no daemon]     │
 │                   │   ── call Store ─▶│── sops ──▶ Disk
 │                   │                   │
 │◀── tool result ───│                   │
 │   {content:[...], │                   │
 │    isError:false} │                   │
```

## 4. Security Architecture

### 4.1 Trust boundaries

```
┌─────────────────────────────────────────────────────────────┐
│                    Developer Machine                        │
│                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────┐    │
│  │ envless  │  │ identity │  │ sops +   │  │ child     │    │
│  │ binary   │  │ .key     │  │ age bin  │  │ process   │    │
│  │ (Zig)    │  │ (0600)   │  │ (PATH)   │  │ (env set) │    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └─────┬─────┘    │
│       │             │             │              │          │
│  ┌────▼─────────────▼─────────────▼──────────────▼──────┐   │
│  │              Trusted zone (FDE required)             │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────┬───────────────────────────────────┘
                          │
                    ┌─────▼─────┐
                    │ Git repo  │
                    │ (public)  │
                    │           │
                    │ secrets/  │ ← encrypted, committed
                    │ *.env.enc │
                    │           │
                    │ .envless/ │ ← recipients committed
                    │ recipients│
                    └───────────┘
```

### 4.2 Crypto pipeline

```
Plaintext KV          sops encrypt              Encrypted file
─────────────         ──────────────            ──────────────
KEY=value    ──▶     sops encrypt     ──▶    KEY: [AES-GCM ciphertext]
KEY2=value2          --input-type dotenv       KEY2: [AES-GCM ciphertext]
                     --output-type dotenv      mac: [HMAC]
                     --age <recipients>        sops:
                                               ...
                                                 recipient: age1...
                                               recipient: age1...
```

- **Per-value encryption:** AES-256-GCM (sops data key)
- **Data key wrap:** X25519 + ChaCha20-Poly1305 (age), one wrap per recipient
- **Integrity:** sops MAC over sorted-key hash
- **Key names stay plaintext** — semantic diffs remain useful

### 4.3 Attack surface

| Surface                     | Risk                                | Mitigation                                                  |
|-----------------------------|-------------------------------------|-------------------------------------------------------------|
| `identity.key` on disk      | Full compromise if extracted        | `0600` perms, FDE required, gitignored, never in cloud sync |
| `sops`/`age` binary on PATH | Compromised binary = plaintext leak | Pin versions, install from trusted sources                  |
| Child process memory        | `ptrace`/`/proc/<pid>/environ`      | Out of scope — use KMS for hostile environments             |
| Daemon resident plaintext   | Wider window for ptrace             | Opt-in only, 60s TTL, best-effort memory wipe on evict      |
| Shell injection via sops    | Attacker-controlled env var values  | `std.process.run` + `Environ.Map` (no `sh -c`)              |
| Agent transcripts           | Secrets leaked to LLM context       | `exec` injects into child env, never stdout                 |

## 5. Zig 0.16 I/O Architecture

The codebase was migrated from Zig 0.13.0 to 0.16.0, adopting the
unified `std.Io` interface. Key architectural patterns:

### 5.1 Unified I/O (`std.Io`)

All file, network, and process I/O flows through `std.Io` — a single
allocator + I/O context threaded through every function:

```zig
// Before (0.13): file-specific APIs
const f = try std.fs.cwd().openFile(path, .{});
defer f.close();
var buf: [4096]u8 = undefined;
const n = try f.read(&buf);

// After (0.16): unified I/O with explicit buffers
const io = std.Io{ ... };
var f = try std.Io.Dir.cwd().openFile(io, path, .{});
defer f.close(io);
var read_buf: [4096]u8 = undefined;
var reader = f.reader(io, &read_buf);
const n = try reader.interface.readSliceShort(&buf);
```

### 5.2 Concurrent stdout/stderr drain (`MultiReader`)

When spawning child processes (daemon `serveExec`, e2e harness), stdout
and stderr must be drained **concurrently** to prevent pipe-buffer
deadlock. Zig 0.16's `std.Io.File.MultiReader` handles this:

```zig
var mr_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
var mr: std.Io.File.MultiReader = undefined;
mr.init(allocator, io, mr_buffer.toStreams(), &.{ stdout_file, stderr_file });
defer mr.deinit();

while (mr.fill(64, .none)) |_| {
    // Check output size limits (16 MB cap per stream)
} else |err| switch (err) {
    error.EndOfStream => {},
    else => |e| return e,
}

const stdout_data = try mr.toOwnedSlice(0);
const stderr_data = try mr.toOwnedSlice(1);
```

### 5.3 Safe environment passing (`Environ.Map`)

The sops wrapper passes `SOPS_AGE_KEY_FILE` to the child process via
`std.process.Environ.Map` instead of `sh -c` — eliminating shell
injection risk:

```zig
var env_map = std.process.Environ.Map.init(allocator);
defer env_map.deinit();

// Copy current environment
var i: usize = 0;
while (std.c.environ[i]) |entry_ptr| : (i += 1) {
    const e = std.mem.span(entry_ptr);
    const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
    try env_map.put(e[0..eq], e[eq + 1 ..]);
}
// Override with our variable
try env_map.put("SOPS_AGE_KEY_FILE", identity_file);

const result = try std.process.run(allocator, io, .{
    .argv = &argv,
    .environ_map = &env_map,
    .stdout_limit = .limited(64 * 1024 * 1024),
});
```

## 6. Daemon Design

### 6.1 Cache

- **Type:** Bounded LRU with TTL
- **Capacity:** 32 entries
- **TTL:** 60 seconds
- **Key:** `<repo_root>\x00<env>` (NUL-separated, no escaping needed)
- **Freshness:** File mtime checked on every access — if the encrypted
  file changed on disk, the cache entry is stale and re-decrypted
- **Eviction:** Sweep oldest `last_access_ns` on insert when full
- **Memory wipe:** Best-effort `wipe()` of value bytes before freeing
  (defence-in-depth against ptrace/coredump)

### 6.2 Wire protocol (IPC)

Transport: Unix stream socket at `$XDG_RUNTIME_DIR/envless/sock` or
`$HOME/.cache/envless/sock`.

```
Request format (tab-delimited, newline-terminated):

  LIST\t<env>\n
  GET\t<env>\t<key>\n
  SET\t<env>\t<key>\t<value>\n
  EXEC\t<env>\t<cwd>\t<argv-base64>\t<stdin-base64>\t<timeout-ms>\n
  WHOAMI\n
  PING\n

Response format:

  OK\t<json-payload>\n    → success
  ERR\t<json-payload>\n   → error ({"code":"...","message":"..."})
```

- `argv` is base64(JSON-array-of-strings) — embedded TABs/newlines
  round-trip safely
- `stdin` is base64(raw bytes)
- `cwd` is an absolute POSIX path (no TAB/newline possible)
- Request line limit: 1 MB (rejected with `ERR` response)

### 6.3 Process supervision

| Platform | Unit file                                | Commands                             |
|----------|------------------------------------------|--------------------------------------|
| macOS    | `~/Library/LaunchAgents/envless.plist`   | `launchctl load/unload`              |
| Linux    | `~/.config/systemd/user/envless.service` | `systemctl --user enable/start/stop` |

`envless daemon install` generates the unit file and enables it.
`envless daemon uninstall` removes it. The daemon itself runs in the
foreground — supervision is delegated to the OS.

## 7. MCP Server Design

### 7.1 Protocol

- **Transport:** JSON-RPC 2.0 over stdio, NDJSON framing (one request
  per line, no `Content-Length:` headers)
- **Protocol version:** `2024-11-05`
- **Capability surface:** tools-only (no resources, no prompts)

### 7.2 Tool surface

| Tool      | Maps to                       | Notes                                     |
|-----------|-------------------------------|-------------------------------------------|
| `envs`    | `store.envs()`                | List available env names                  |
| `list`    | `store.Read(env)` → keys      | No values exposed                         |
| `get`     | `store.Read(env)` → one value | Requires `confirm: true`                  |
| `set`     | `store.Write(env, merged)`    | Encrypts and writes                       |
| `exec`    | `execenv.run()`               | 300s hard timeout, concurrent drain       |
| `init`    | `cli/init.zig`                | Accepts explicit `path` argument          |
| `migrate` | `cli/migrate.zig`             | Encrypts `.env` into envless              |
| `whoami`  | `store.pubKey()`              | Returns identity pubkey + recipient count |

### 7.3 Daemon auto-routing

When the MCP server receives a `tools/call`, it checks if the daemon
socket is live (100ms `PING` timeout). If yes, it routes through the
socket for cached decrypt. If no, it calls Store/sops directly. This is
transparent to the caller — the MCP tool result shape is identical
either way.

### 7.4 CWD scope

The MCP server resolves `.envless/` from the process cwd — typically
the directory where the MCP client (Claude Code, etc.) was started.
One envless repo per MCP server instance. The `init` tool is the only
one that accepts an explicit `path` argument.

## 8. Build & Release

### 8.1 Build graph (`zig/build.zig`)

```
zig build              # compile binary → zig-out/bin/envless
zig build test         # 75 inline unit tests across 11 modules
zig build e2e          # 18 end-to-end tests (builds binary, spawns it)
zig build run -- <args>  # compile + run in one step
zig build release -Dversion=v0.X.Y  # cross-compile 4 targets → dist/
```

### 8.2 Release targets

| Target       | Triple              |
|--------------|---------------------|
| Linux x86_64 | `x86_64-linux-gnu`  |
| Linux ARM64  | `aarch64-linux-gnu` |
| macOS x86_64 | `x86_64-macos`      |
| macOS ARM64  | `aarch64-macos`     |

All built with `-Doptimize=ReleaseSmall` — small stripped static
binary, no debug symbols. Output: `dist/envless_<version>_<target>.tar.gz`
per target + `dist/checksums.txt` with SHA-256 per tarball.

### 8.3 CI pipeline

| Workflow      | Trigger              | Purpose                                            |
|---------------|----------------------|----------------------------------------------------|
| `ci.yml`      | PR + push to main    | `zig build test && zig build e2e`                  |
| `release.yml` | `push: tags: ['v*']` | Cross-build, draft GitHub Release                  |
| `docs.yml`    | push to main         | Build Astro/Starlight docs site → GH Pages         |
| `bench.yml`   | PR + release tag     | Run `bench/run.sh`, post delta table as PR comment |

## 9. Testing Strategy

### 9.1 Unit tests (75 total)

Inline `test "..."` blocks per module. Run via `zig build test`.

| Module         | Test style      | Notes                                                  |
|----------------|-----------------|--------------------------------------------------------|
| `envparse.zig` | Table-driven    | Pure-logic parser tests, no I/O                        |
| `execenv.zig`  | Table-driven    | Env merge logic + `run` against `/bin/sh`              |
| `sops.zig`     | Skip-if-missing | Roundtrip through real `sops` + `age`                  |
| `store.zig`    | Skip-if-missing | Full filesystem behaviour                              |
| `backup.zig`   | Mixed           | `isoTimestamp` format, `findRepoRoot` graceful failure |
| `ipc.zig`      | Unit            | Large IPC request handling, `socketPath` dir creation  |
| `migrate.zig`  | Filesystem      | `appendGitignore` idempotency                          |
| `daemon.zig`   | Unit            | Cache LRU eviction, TTL expiry                         |
| `mcp.zig`      | Unit            | JSON-RPC parsing, tool dispatch                        |
| `launchd.zig`  | Unit            | Plist generation                                       |
| `systemd.zig`  | Unit            | Service file generation                                |

### 9.2 E2E tests (18 total)

`zig/src/e2e.zig` — builds the real binary and spawns it. Each test
gets its own `makeTmpDir()` and cleans up. Run via `zig build e2e`.

Pattern:
```zig
test "init set exec roundtrip" {
    const dir = try makeTmpDir();
    defer cleanup(dir);
    try runEnvlessOk(dir, &.{ "init" });
    try runEnvlessOk(dir, &.{ "set", "TEST" }, "value\n");
    const out = try runEnvlessOk(dir, &.{ "exec", "--", "sh", "-c", "echo $TEST" });
    try expectContains(out, "value");
}
```

### 9.3 Skip-if-missing pattern

Tests requiring `age-keygen` or `sops` skip gracefully when the
binaries aren't on PATH. CI installs both; local contributors without
them see skips, not failures.

## 10. On-disk Layout

```
your-repo/
├── .envless/
│   ├── identity.key       # age secret key — gitignored, 0600
│   └── recipients         # age public keys — committed (access control plane)
├── secrets/
│   ├── dev.env.enc        # sops-encrypted dotenv — committed
│   ├── staging.env.enc
│   └── prod.env.enc
└── .gitignore             # auto-appended on migrate
```

### File formats

| File                    | Format                                   | Sensitive?       | Committed?      |
|-------------------------|------------------------------------------|------------------|-----------------|
| `.envless/identity.key` | age key file (`AGE-SECRET-KEY-...`)      | **Yes** — 0600   | No (gitignored) |
| `.envless/recipients`   | One age pubkey per line                  | No (public keys) | Yes             |
| `secrets/*.env.enc`     | sops dotenv (YAML-ish, values encrypted) | No (ciphertext)  | Yes             |

## 11. Design Decisions & Trade-offs

### Why not a server?

envless is a CLI tool first. The daemon is opt-in and ephemeral — it
caches, it doesn't persist. There is no database, no API server, no
always-on process in the default mode. This keeps the attack surface
minimal and the operational burden zero.

### Why sops + age instead of raw age?

sops provides **per-value encryption** with plaintext key names —
encrypted diffs remain semantic and reviewable. Raw age encrypts the
entire file as a blob, making diffs opaque. sops also handles
multi-recipient data-key wrapping cleanly.

### Why Zig?

- Single static binary, no runtime, ~150 KB stripped
- No GC pauses, no language VM, no dependency hell
- `std.Io` unified interface makes the I/O layer clean
- Cross-compilation is first-class (4 targets from one `build.zig`)

### Why not a KMS?

envless targets the **casual/opportunistic** threat tier (shoulder-surfing,
lost laptop with FDE, agent transcript leakage). For compliance regimes
requiring HSM-backed keys, per-secret ACLs, or auditable access logs,
use AWS KMS / GCP KMS / Vault. envless can coexist — see
[Pattern 3 in the security docs](src/content/docs/security.mdx#pattern-3--cloud-native-kms-for-prod-envless-for-devstaging).

### Why the daemon cache?

`envless exec` spawns `sops decrypt` on every invocation (~200ms).
For latency-sensitive workflows (e.g., MCP tool calls from agents),
the daemon caches decrypted maps in memory for 60s, dropping latency
to sub-millisecond. The trade-off: resident plaintext in the daemon's
heap for up to 60s per `(repo, env)` pair. This is an explicit opt-in.

## 12. Further Reading

- [Security model](src/content/docs/security.mdx) — threat model, crypto, rotation
- [Architecture (docs)](src/content/docs/architecture.mdx) — lifecycle of a secret
- [Contributing](src/content/docs/contributing.mdx) — dev setup, testing, release
- [CLI reference](src/content/docs/cli.mdx) — commands, flags, exit codes
- [AGENTS.md](AGENTS.md) — gotchas for AI coding assistants
- [age spec](https://age-encryption.org/v1) — file encryption format
- [sops docs](https://getsops.io/docs/) — secrets operations
- [MCP spec](https://modelcontextprotocol.io/) — Model Context Protocol
