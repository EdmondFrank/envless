# AGENTS.md — gotchas for Claude Code in this repo

## Caveman + RTK install (project-scoped)

Both installed at project scope via:
- rtk: `rtk init` (no `--global`) → creates `CLAUDE.md` + `.rtk/filters.toml`. Instruction-based, no hook patching.
- caveman: standalone `hooks/install.sh` with `CLAUDE_CONFIG_DIR=$PWD/.claude` → writes `.claude/hooks/` + `.claude/settings.json`.

### Gotchas

1. **caveman standalone install ≠ skills.** `hooks/install.sh` wires hooks + statusline only. Slash commands (`/caveman`, `/caveman-commit`, `/caveman-review`) and skills (`caveman`, `caveman-commit`, `caveman-help`, `caveman-review`, `compress`) are NOT registered. Fix = symlink them in:
   ```bash
   for s in caveman caveman-commit caveman-help caveman-review compress; do
     ln -sfn /Users/billiboss/.claude-pessoal/plugins/marketplaces/caveman/skills/$s \
       /Users/billiboss/src/envless/.claude/skills/$s
   done
   for c in caveman caveman-commit caveman-review; do
     ln -sfn /Users/billiboss/.claude-pessoal/plugins/marketplaces/caveman/commands/$c.toml \
       /Users/billiboss/src/envless/.claude/commands/$c.toml
   done
   ```
   Then `/reload-plugins`.

2. **Caveman statusline collision.** Installer writes a project-level `statusLine` block into `.claude/settings.json` pointing at `caveman-statusline.sh`. The canonical statusline at `~/.claude/statusline.sh` ALREADY renders the `[CAVEMAN]` badge itself (reads the same `.caveman-active` flag). Project `statusLine` replaces the 3-line canonical with a single-line badge — lose git status, context %, etc. **Always delete the `statusLine` block from project `.claude/settings.json` after running caveman install.**

3. **Re-running `bash hooks/install.sh --force` will re-add the `statusLine` block.** Delete it again after every reinstall.

4. **`rtk init` writes `CLAUDE.md` at project root.** If a project `CLAUDE.md` exists, rtk merges/appends — verify before committing. New untracked items after a fresh install: `CLAUDE.md`, `.rtk/`, `.claude/`.

5. **rtk is not a skill.** Never appears in the skills list. Invoked only as a Bash prefix per the rules in `CLAUDE.md`.

## Zig toolchain — macOS 26 Tahoe blocker

The Zig codebase is pinned to **0.13.0** (`zig/.zigversion`). On macOS 26 (Tahoe) the 0.13.0 linker fails with `undefined symbol: _arc4random_buf`, `_exit`, `_posix_memalign`, etc. — Tahoe's SDK exposes a different libSystem ABI than 0.13.0 expects.

What this means for local benchmarking:
- `bash bench/run.sh` on macOS 26 will run the Go leg only. The Zig leg's build step fails inside `hyperfine`, the harness skips the Zig toolchain cleanly, and the verbose result JSON has `toolchains: [{go: ...}]` with no zig entry.
- CI (`.github/workflows/ci-zig.yml`, `bench.yml`) uses Ubuntu runners where 0.13.0 links fine — Zig metrics will appear in CI artifacts.

Workarounds (if you must benchmark Zig locally on macOS 26):
1. Wait for Zig 0.14/0.15 macOS-26 fixes and port the codebase (stdlib churn: `std.fs.cwd`, `std.process.Child`).
2. Use Linux (VM, Docker, remote runner).
3. Downgrade macOS — not recommended.

Don't "fix" the Tahoe linker error by sprinkling `-lc` or `--sysroot` hacks in `build.zig`. The codebase ports cleanly to 0.14; the right move when this becomes painful is to bump `.zigversion` to 0.14 and update the stdlib calls.

## Bash exception: bench/run.sh

The repo is otherwise full-Zig (e2e harness, build, release, CI all in
Zig). `bench/run.sh` is the single intentional bash exception — it
orchestrates `hyperfine`, parses `/usr/bin/time` output, and shells `jq`
for JSON munging. Porting it to Zig would be 500+ LOC of zero-value
infrastructure code; bench harnesses are bash-native by tradition.

If you ever do port it, the entrypoint contract is:
- Build the Zig binary via `(cd zig && zig build -Doptimize=ReleaseSmall)`
- Time each metric with hyperfine (or equivalent)
- Emit one verbose JSON to `bench/results/<sha>.json`
- Append one summary line to `bench/history.jsonl`

## Versioning policy (pre-1.0)

Until the project ships `v1.0.0`, every release **bumps MINOR**.

- Next release after `v0.0.2` is `v0.1.0`. Then `v0.2.0`, `v0.3.0`, ...
- `v0.X.0` is the only "normal" release shape pre-1.0.
- **PATCH (`v0.X.Y` with `Y > 0`)** is reserved for true hot-fixes — a
  critical regression in an already-published release that needs to
  ship within hours. Use sparingly. If you find yourself reaching for
  `v0.X.1` for anything that can wait until the next MINOR, bump
  MINOR instead.
- **MAJOR (`v1.0.0`)** is set deliberately by the maintainer; do not
  bump major automatically.
- Pre-release suffixes (`-rc1`, `-beta`, etc) are honored by
  `release.yml` and tagged as GitHub prereleases — fine for testing
  the pipeline without polluting the changelog.

Operationally: `git tag v0.X.0 && git push origin v0.X.0` is the
canonical release path. CI does the rest (build → publish → bump
brew formula → commit).

## MCP server cwd scope (v0.2.x)

`envless mcp` is rooted at the cwd of the process that launched it. That cwd is **whichever directory Claude Code (or the MCP client) was started in**. Consequence: one envless repo per MCP server instance.

- `init` is the **only** tool that accepts an explicit `path` argument — useful for bootstrapping a fresh repo from elsewhere.
- `set`, `get`, `list`, `migrate`, `whoami`, `envs` resolve `.envless/` from the MCP process cwd. They **do not** accept a cwd override.
- `exec` accepts a `cwd` for the spawned child but the env-decrypt path still uses the MCP server's cwd.

Practical implications:
- Multi-repo workflows need separate Claude Code sessions, each launched in the target repo. Don't try to drive two envless repos from a single MCP session — you'll silently read from the first.
- `init {"path":"/tmp/other-repo"}` creates `.envless/` there but subsequent `set` calls against the same MCP server will write to the original cwd's `.envless/` — confusing.
- When testing the MCP server from a Claude Code session rooted at the envless repo itself, `init` (no path) creates `.envless/` in the repo root. Clean up afterwards (`rm -rf .envless secrets`) — identity.key is gitignored but `recipients` + `secrets/` are not.

v0.3.x candidate: add optional `cwd` param to `set/get/list/migrate` so a single MCP server can target multiple envless repos. Until then, **one repo per MCP server**.

## Benchmark history storage

Format: **JSONL** at `bench/history.jsonl` (one line = one bench run, keyed by `sha` + `timestamp`). Not SQLite, not per-SHA files-only.

Rationale:
- Line-based git diffs — every release shows a single appended line, trivial to review.
- Claude Code reads it with the `Read` tool directly, no driver.
- `jq -s '.[] | select(.sha=="…")' bench/history.jsonl` for queries; `tail -1` for latest; `wc -l` for run count.
- SQLite = binary blob → opaque diffs, lock contention, schema migrations, can't be read without the sqlite CLI.
- Dataset stays tiny (one row per release/PR run for years) — index/query speed irrelevant.

Schema per line (extend, never rename):
```json
{"schema_version":1,"sha":"<full-sha>","ref":"<tag-or-branch>","timestamp":"<iso8601>","os":"darwin","arch":"arm64","toolchain":{"go":"1.26.0","zig":"0.13.0"},"binaries":{"go":{"build_ms":...,"size_b":...,"cold_start_ms":...,"list_ms":...,"exec_ms":...,"rss_b":...,"e2e_s":...},"zig":{...}}}
```

Bench harness writes one line via `>>` append. Per-SHA detail JSONs (`bench/results/<sha>.json`) stay as the verbose source for raw hyperfine output; `history.jsonl` is the summarized index the changelog renderer reads. Both committed.

**Don't** introduce SQLite for "queries later" — when the dataset outgrows JSONL (10k+ rows), the right next step is DuckDB-over-JSONL, not SQLite.
