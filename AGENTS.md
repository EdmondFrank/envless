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
