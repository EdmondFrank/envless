# Go purge report

Final cutover of `envless` from Go + Zig dual-binary to a full-Zig
repository. The Zig port reached parity in the previous milestone
(see `zig/PORT_REPORT.md`); this work removes every Go artifact and
collapses the toolchain surface to one compiler.

## Summary

- **8 logical commits** between `f2dccf5` (e2e port) and `dc50302` (final
  doc scrub). Each commit is independently revertable.
- **21 files / 1,424 LOC of Go source + configs deleted** in a single
  cleanup commit, after the Zig substitutes were proven via
  `zig build e2e` + Linux CI.
- **`zig build e2e` 6/6 pass** locally (in Docker / OrbStack — macOS 26
  Tahoe blocks local Zig 0.13.0, per AGENTS.md) and runs in CI under
  the new collapsed `.github/workflows/ci.yml`.
- **`zig build release -Dversion=…`** cross-builds the four release
  targets in a single invocation, producing
  `dist/envless_<version>_<target>.tar.gz` + `dist/checksums.txt`.
- **bench/run.sh stripped to Zig-only**, two fresh baseline rows
  appended to `bench/history.jsonl`.
- **Docs site builds clean** (11 pages, `pnpm build`), zero Go
  references except intentional "Go (predecessor)" callouts.

## Commit log

```
dc50302 docs: scrub residual Go-runtime references in cli.mdx and bench/README
07f165b docs(agents): document the lone bash exception (bench/run.sh)
6ffec77 chore: commit fresh Zig-only bench baseline
66f5eae chore: remove Go sources (cmd/, internal/, pkg/, go.mod, go.sum, Makefile, .goreleaser.yaml, e2e/e2e_test.go)
72f2fb9 docs: rewrite Go references for Zig substrate
15686c8 feat(bench): drop Go leg, default to Zig
64083ff ci: collapse to a single Zig-only workflow + Zig-native release.yml
36c92ce feat(build): add zig build release step (cross-target tarballs + checksums)
f2dccf5 feat(e2e): port harness from Go to Zig (zig build e2e)
```

## Files deleted

Single cleanup commit (`66f5eae`): **21 files / 1,424 LOC**.

| Path | LOC |
|---|---|
| `cmd/envless/main.go` | 19 |
| `internal/ecmd/{root,init,set,get,list,exec,migrate}.go` | 312 |
| `internal/sopswrap/sopswrap{,_test}.go` | 194 |
| `internal/execenv/execenv{,_test}.go` | 181 |
| `internal/store/store{,_test}.go` | 289 |
| `pkg/envparse/envparse{,_test}.go` | 139 |
| `e2e/e2e_test.go` | 204 |
| `go.mod`, `go.sum` | 19 |
| `Makefile`, `.goreleaser.yaml` | 67 |
| `.github/workflows/ci.yml` (old) | ~30 (replaced by ci-zig.yml renamed) |

The old `.github/workflows/ci.yml` was deleted; `ci-zig.yml` was
renamed to `ci.yml` and stripped of its Go install / e2e steps.

## Files added

- **`zig/src/e2e.zig`** — 6 ported e2e tests + harness (allocator,
  binary resolution via `BIN` env var, tempdir setup, child-process
  spawn with capture). Inline `test "..."` blocks per Go assertion;
  uses `error.SkipZigTest` to match the Go `skipIfMissing` semantics.
- **`GO_PURGE_REPORT.md`** (this file).

## Files modified

| File | What |
|---|---|
| `zig/build.zig` | Added `e2e` step (depends on install, sets BIN env var) and `release` step (cross-builds 4 targets, tars to ../dist/, writes checksums.txt). |
| `.github/workflows/ci.yml` | Now the only CI workflow. Zig-only. Builds, runs `zig build test` + `zig build e2e`. |
| `.github/workflows/release.yml` | Rewritten around `zig build release` + `softprops/action-gh-release@v2`. No goreleaser. |
| `.github/workflows/bench.yml` | Go install steps removed. |
| `bench/run.sh` | Single Zig leg, e2e timed via `zig build e2e`, drop `BIN=` fallback. |
| `README.md` | Build / test / release commands swap to `zig build`. Architecture map points at `zig/src/*`. |
| `spec/v0.0.1.md` | Module paths + acceptance checklist. |
| `bench/README.md`, `bench/REPORT.md` | Zig-only methodology; flag `bench/run.sh` as the lone bash exception. |
| `src/content/docs/{quickstart,architecture,cli,security,operations,contributing,benchmarks,why}.mdx` | Every code snippet, table, and reference link points at `zig/src/`. Build commands swap to `zig build`. |
| `AGENTS.md` | New section documenting `bench/run.sh` as the intentional bash exception. |
| `.gitignore` | Add `.docker-build/` (developer-local Docker helper). |

## E2E pass count

`zig build e2e` runs **6/6** end-to-end tests against the
just-built binary:

```
TestE2E_VersionFlag
TestE2E_InitSetExecRoundtrip
TestE2E_MultiEnvIsolation
TestE2E_List
TestE2E_GetRequiresConfirm
TestE2E_Migrate
```

Verified locally (Ubuntu 24.04 aarch64 container, Zig 0.13.0):

```
$ zig build test                           # 37 inline unit tests
$ zig build e2e                            # 6 e2e tests
$ zig build release -Dversion=v0.0.1-...   # 4 tarballs + checksums.txt
```

All three exit 0.

## Bench numbers (Zig only, this run)

Most recent row in `bench/history.jsonl`
(`66f5eae16b6645b20a782ccf8b2f3f2bd0570ba3`, Linux/aarch64, in container):

| Metric | Value |
|---|---|
| build_time_sec.mean | ~7.0 s (cold rebuild, `-Doptimize=ReleaseSmall`) |
| binary_size_bytes | 143,240 (~140 KB stripped) |
| cold_start_sec.mean | < 1 ms (below hyperfine calibration floor) |
| list_latency_sec.mean | ~8 ms |
| exec_latency_sec.mean | ~9 ms |
| peak_rss_bytes | ~31 MB |
| e2e_wallclock_sec | ~6 s (build + 6 tests, cold cache) |

Build time is dominated by Zig stdlib + cross-target codegen on every
warmup run because `--prepare` removes the Zig cache; warm builds are
~10× faster and not part of the bench surface.

## Docs build status

`pnpm build` from repo root: **clean**. 11 pages, Pagefind search index
generated. Sitemap produced. Same page count as before the purge.

## The lone bash exception

`bench/run.sh` remains in bash. Hyperfine orchestration is bash-native
by tradition (hyperfine itself is a binary, but its driver scripts in
every major language ecosystem are bash). Porting `bench/run.sh` to
Zig would be ~500 LOC of zero-value infrastructure code.

This is the only `.sh` file in the repo's product surface. `AGENTS.md`
documents the entrypoint contract should a future agent want to port it.

## Outstanding / manual follow-up

- **Tag a new release** (`v0.0.2` or similar) to exercise the new
  release.yml pipeline end-to-end on Ubuntu CI. The first tag-push
  is the proof of life for `zig build release -Dversion=<tag>` in CI.
- **macOS 26 Tahoe local builds** still require the Docker/OrbStack
  workflow (AGENTS.md). When Zig 0.14+ macOS-26 fixes land, bump
  `zig/.zigversion` and update the small stdlib API surface that
  shifted (`std.fs.cwd`, etc.).
- **CHANGELOG.md** — not yet created; the docs changelog reader pulls
  from the GitHub Releases API + `bench/history.jsonl` directly, so no
  blocker, but a per-release human-edited summary would land here when
  the next tag goes out.
- **`bin/`** directory was removed locally but is gitignored — no
  tracked file to delete. The pre-existing Go binary at `bin/envless`
  is gone from the worktree.
