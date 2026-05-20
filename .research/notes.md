# envless research — consolidated agent findings

## age (FiloSottile/age) — key takeaways

- **Library-at-root**: `age.go`, `recipients_test.go` flat. Library first, CLI second.
- **CLI = separate binaries**: `cmd/age`, `cmd/age-keygen`, `cmd/age-inspect`, `cmd/age-plugin-batchpass`.
- **Plugin protocol**: subprocess. `age-plugin-<name>` binaries. Stanza-based, base64 over stdio. Third party ships binary, no fork.
- **Tests**: table-driven, test vectors via `c2sp.org/CCTV/age`, no mocks.
- **Module**: `filippo.io/age`, minimal deps, scoped namespace.
- **No config files**: flags + env vars only.

**Adopt for envless:**
- Library at root + CLI in `cmd/` + plugins as subprocess binaries `envless-<kind>-<name>`.
- One interface per concern.
- Test vectors as code (canonical fixtures).
- Avoid SDK — JSON over stdio.

## sops — key takeaways

- **Layout**: `cmd/sops/` monolithic CLI. `age/ pgp/ kms/ gcpkms/ azkv/ hcvault/` provider-per-dir. `stores/{json,yaml,dotenv,ini}/` format-agnostic. `config/` walks up dirs (max 100). `keyservice/` gRPC remote keys.
- **CLI framework**: urfave/cli v1 (NOT cobra). Flat command array w/ inline Action closures.
- **Tests**: unit colocated `*_test.go`. E2E in **separate Rust crate** `functional-tests/`. KMS dev tokens in CI.
- **Provider pattern**: `MasterKey` interface (Encrypt/Decrypt/ID/ToMap). But: **no central registry**, hardcoded dispatch in sops.go. Adding KMS = editing sops.go + metadata.go.
- **Format**: data key per file, encrypted per recipient. AES-GCM values. MAC over key/value order. Plaintext keys for merge-friendly diffs.
- **Module**: single `github.com/getsops/sops/v3`. ~40 deps.
- **CI**: matrix linux/darwin/windows × amd64/arm64. Multi-stage: unit → build artifacts → E2E w/ Vault.
- **Config discovery**: `.sops.yaml` walk-up. Env vars override (`SOPS_AGE_RECIPIENTS`).

**Adopt:**
- `MasterKey`-like interface for adapters.
- Format-agnostic stores under `internal/store/{yaml,json,env,ini}/`.
- Embed metadata in file (no sidecar).
- Multi-stage CI but **all in Go** (avoid sops's Rust E2E split).

**Avoid:**
- urfave/cli — cobra is now standard.
- Hardcoded provider dispatch — use registry.
- Splitting languages for E2E.

## cli/cli (gh) — pending

## teller — key takeaways

- **Layout**: 4 Rust crates (cli, core, providers, xtask).
- **Model**: fetches live from providers. No encrypt-in-repo. Stateless.
- **Provider trait**: async `get/put/del` + `PathMap`.
- **CLI**: `teller run -- cmd` star command. `env`, `sh`, `show`, `export`, `redact`, `template`, `scan`, `put/delete/copy`.
- **Tests**: insta snapshots + dockertest-server for real Vault/etcd. `trycmd` for CLI goldens.
- **Config**: `.teller.yml` w/ Tera templating, key transforms.

**Adopt:**
- `envless exec` + `envless export` + `envless redact` (clean logs).
- Subcommand trait pattern for plugins.
- `trycmd`-equivalent golden CLI tests (Go: `testscript`).

**Avoid:**
- Provider lock-in (cloud SDKs).
- Docker integration tests (slow CI).
- No audit trail.

## charmbracelet (gum, vhs)

- **Layout**: subcommand per dir w/ `command.go` + `options.go`.
- **Framework**: kong for gum, cobra for vhs.
- **Output restraint**: styling for interactive only, raw for piping. One result per stdout line.
- **No emojis in help text. Verb + noun naming.**
- **Tests**: hard algorithmic correctness > coverage.
- **Goreleaser**: shared template, override only overrides.

**Adopt:**
- Caveman output is alignment, not deviation.
- Flag conventions: `--name`, env var fallback `ENVLESS_X`.
- Single-line per action. No spinners.

## direnv

- **Trust model**: dual SHA256 hashes (path+content) at `~/.direnv/allow/<hash>`. Content change = re-allow.
- **Exec mechanism**: `syscall.Exec()`. True process replacement, no child overhead.
- **Shell-agnostic diff**: parse RC in bash subprocess, capture JSON env, parent renders shell-specific exports.
- **`.envrc` parsing**: bash subprocess + 40KB embedded stdlib via `//go:embed`.
- **Tests**: per-shell integration files in `test/`.

**Adopt:**
- `syscall.Exec` for `envless exec` (no child overhead, true replace).
- Hash-based trust for plugins.
- Detect direnv presence + offer interop hook.

## goreleaser — key takeaways

- **Minimal config**: `version: 2`, `builds:`, `archives:`, `checksum: sha256`, `signs:` (cosign), `npms:`, `nfpms:`, `dockers_v2:`, `brews:`.
- **Cross-compile**: `CGO_ENABLED=0`, `-trimpath`, `goos: [linux,darwin,windows]`, `goarch: [amd64,arm64]`.
- **GH Action**: trigger `on: push: tags: ["v*"]`. `goreleaser/goreleaser-action@v7` w/ `args: release --clean`.
- **npm wrap**: `npms:` section auto-generates postinstall to download platform binary.
- **Versioning**: ldflags `-X main.version={{.Version}}`.

## esbuild npm-wraps-Go pattern — key takeaways

- **Mechanism**: `optionalDependencies` pinning ~25 scoped platform packages (`@esbuild/darwin-arm64`, etc.) w/ `os/cpu` constraints. npm resolver installs only the matching one.
- **Fallback ladder**: `require.resolve()` → spawn `npm install @scope/platform` to temp → direct HTTPS tarball + SHA256 verify.
- **Security**: SHA256 hashes in `package.json['esbuild.binaryHashes']`. Install script verifies.
- **Reproducible builds**: `-trimpath -ldflags="-s -w"`.
- **Edge cases handled**: corp proxies, offline, musl, Yarn PnP, Rosetta 2, `--no-optional`, `--ignore-scripts`, Windows `.exe`.
- **Release**: Makefile cross-compiles per target, publishes platform packages in parallel, then main package last (avoid races).

**Adopt for `@envless/skill`:**
- Same optionalDependencies pattern.
- `@envless/cli-darwin-arm64`, `@envless/cli-linux-x64`, etc.
- SHA256 hash table in main package.json.
- Install script does require.resolve → fallback download.
- Goreleaser `npms:` config to auto-generate the platform tarballs + main package + hash table.

## gh CLI — key takeaways (most scalable Go CLI shipping)

- **Layout**:
  - `cmd/gh/` thin entrypoint (main.go → `internal/ghcmd.Main()`).
  - `internal/` closed domain (config, gh interfaces, ghcmd, telemetry).
  - `pkg/` reusable libs (cmd, cmdutil, httpmock, iostreams, tableprinter, extensions).
  - `pkg/cmd/<name>/<subcmd>/{name.go, name_test.go, shared/}`.
- **Cobra factory pattern**: `NewCmd<Name>(f *cmdutil.Factory, runF func(*Options) error) *cobra.Command`. Factory injects deps. `runF` = test hook.
- **Tests**: colocated `*_test.go`. Table-driven `[]struct{ name, tty, cli, config, wantsErr, wantsOpts }`. `pkg/httpmock` replaces transport on `*http.Client`, register matchers+responders.
- **Extension model**: `gh-<name>` binaries discovered via repos or local. `ExtensionManager.Dispatch(args, stdin, stdout, stderr)` execs subprocess. `:generate moq` for mock generation.
- **Config**: `internal/gh.Config` interface, `internal/config` implements. Lazy-loaded. Per-host overrides. `Option[T]` for null-safety.
- **internal/ vs pkg/**: internal = closed domain, stateful, platform-aware. pkg = reusable utilities.
- **CI**: golangci-lint v2, go-licenses, govulncheck, go mod tidy clean.
- **Antipatterns to avoid**: 1328-line `createRun` god functions, 78-field Options struct, monolithic flag defs, test tables with 100+ cases in one func, ad-hoc string errors w/o structured logging.

**Adopt for envless:**
- Cobra + `NewCmd<Name>` factory + `cmdutil.Factory` dep injection.
- `internal/` vs `pkg/` split exactly as gh does.
- Per-command dir w/ colocated test.
- `pkg/httpmock`-style: replace transport, not whole client.
- Extension model = our plugin model. Subprocess + stdio.
- Lazy config load (non-fatal startup errors).

---

# CONSOLIDATED DESIGN DECISIONS

## Project layout (final)

```
envless/
├── cmd/envless/main.go            # thin entrypoint → internal/ecmd.Main()
├── internal/
│   ├── ecmd/                      # root command orchestration
│   ├── config/                    # .envless/team.yaml, .sops.yaml parsing
│   ├── store/                     # secrets/*.yaml.enc store abstraction
│   ├── age/                       # age identity wrapper
│   ├── sops/                      # sops invocation wrapper
│   ├── exec/                      # syscall.Exec env injection
│   ├── plan/                      # detect → plan JSON merger
│   ├── plugin/                    # subprocess plugin dispatcher
│   ├── audit/                     # JSONL log
│   ├── iostreams/                 # TTY detection, caveman renderer
│   ├── factory/                   # cmdutil.Factory equivalent
│   └── version/
├── pkg/cmd/
│   ├── root/root.go
│   ├── exec/exec.go               # envless exec
│   ├── set/set.go
│   ├── get/get.go
│   ├── rotate/rotate.go
│   ├── panic_cmd/panic.go
│   ├── team/{add,remove,grant,revoke,list,sync,join}/
│   ├── inbox/{send,open}/
│   ├── notice/{send,listen}/
│   ├── plugin/{install,list,remove}/
│   ├── sync/sync.go
│   ├── doctor/doctor.go
│   ├── plan_cmd/plan.go
│   └── apply/apply.go
├── pkg/
│   ├── cmdutil/                   # factory, error types, common flags
│   ├── envparse/                  # .env parser w/ quotes/multiline/interp
│   ├── execmock/                  # test helper for exec mocking
│   └── testenv/                   # fixture loader for testdata/
├── plugins/                       # bundled v1 plugins (built as separate bins)
│   ├── detect-node/
│   ├── detect-dotenv/
│   ├── ci-github/
│   └── rotate-openai/
├── skill/                         # @envless/skill npm package
│   ├── package.json
│   ├── bin/install.js
│   ├── SKILL.md
│   └── scripts/
├── testdata/
│   ├── node-dotenv-basic/
│   ├── pnpm-monorepo/
│   ├── gh-actions-deploy/
│   └── team-3-members/
├── e2e/                           # all-Go e2e (avoid sops's Rust split)
├── docs/
├── .github/workflows/
│   ├── ci.yml                     # lint + unit + e2e matrix
│   └── release.yml                # goreleaser on tag push
├── .goreleaser.yaml
├── Makefile
├── go.mod
├── LICENSE                        # Apache-2.0
└── README.md
```

## CLI framework: cobra + NewCmdX factory (gh pattern)

## Plugin model: subprocess binaries `envless-<kind>-<name>`, JSON over stdio (age + gh hybrid)

## Exec mechanism: `syscall.Exec()` (direnv pattern, true replace)

## Trust: hash-based `envless.lock` for plugins (direnv-inspired)

## Output: caveman one-line, no spinners, no emojis (charm restraint)

## Tests:
- colocated `_test.go`, table-driven
- `testdata/` fixture repos
- Go-only E2E (avoid sops Rust split)
- `testscript`-style golden CLI tests
- httpmock-style transport replacement for upstream API mocks

## Release: goreleaser + esbuild-pattern npm wrap (optionalDependencies + SHA256 hashes)

## Module: single `github.com/biliboss/envless`. Apache-2.0.

## Risky parts (TDD priority order)

1. **`internal/exec`** — syscall.Exec env array build. Wrong env = wrong process. Highest risk.
2. **`pkg/envparse`** — `.env` quirks (quotes, multiline, `$VAR` interp). Wrong parse = data loss.
3. **`internal/sops`** — sops invocation wrapper. Roundtrip correctness.
4. **`internal/plan`** — plan JSON contract between detect plugins → apply. API stability.
5. **`internal/plugin`** — subprocess dispatch, stdin/stdout framing, exit codes.
6. **`internal/store`** — secrets/*.yaml.enc read/write. Concurrency edges.
7. **`pkg/cmd/exec`** — end-to-end glue. Where bugs surface.

TDD slices in this order.

