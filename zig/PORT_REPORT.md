# envless Zig port — workstream A report

## Modules ported

| Go source                       | LOC | Zig target                | LOC | Notes |
|---------------------------------|----:|---------------------------|----:|-------|
| `pkg/envparse/envparse.go`      |  51 | `zig/src/envparse.zig`    | 157 | 11 inline tests (1:1 with Go) |
| `internal/execenv/execenv.go`   |  64 | `zig/src/execenv.zig`     | 266 | 10 inline tests; `RunResult` union replaces `*ExitError` |
| `internal/sopswrap/sopswrap.go` | 102 | `zig/src/sops.zig`        | 334 | 3 inline tests (renderDotenv + sops/age roundtrip) |
| `internal/store/store.go`       | 159 | `zig/src/store.zig`       | 400 | 6 inline tests; chmod via `std.c.chmod` |
| `internal/ecmd/*.go` (7 files)  | 305 | `zig/src/cli/*.zig` (7)   | 582 | Hand-rolled flag parser; `--` terminator for exec |
| `cmd/envless/main.go`           |  19 | `zig/src/main.zig`        |  21 | Version via `-Dversion=` build option |
| —                               |   — | `zig/build.zig`           |  79 | Auto-discovers modules; `zig build test` runs all units |

Go total: **700 LOC source + ~430 LOC test**. Zig total: **1760 LOC** (one combined file per module, tests inline). The ~55% delta is driven by explicit allocator/lifetime plumbing (each module owns its own free helpers) and slightly more verbose union-based error handling.

## E2E parity (oracle: `e2e/e2e_test.go`)

Ran `BIN=$PWD/zig/envless go test -count=1 ./e2e/...` against a `ReleaseSmall` build (`-target aarch64-macos.13.0`, 158 KB binary):

| Test                            | Result |
|---------------------------------|--------|
| `TestE2E_VersionFlag`           | PASS   |
| `TestE2E_InitSetExecRoundtrip`  | PASS   |
| `TestE2E_MultiEnvIsolation`     | PASS   |
| `TestE2E_List`                  | PASS   |
| `TestE2E_GetRequiresConfirm`    | PASS   |
| `TestE2E_Migrate`               | PASS   |

All 6/6 pass. Go e2e suite is unchanged (still passes with the default `go build` path).

## Unit tests (`zig test <module> -target aarch64-macos.13.0 -lc`)

| Module          | Tests | Result |
|-----------------|------:|--------|
| envparse        | 11    | PASS   |
| execenv         | 10    | PASS   |
| sops            | 3     | PASS   |
| store           | 6     | PASS   |
| cli/root        | 4     | PASS   |
| cli/migrate     | 3     | PASS   |
| **TOTAL**       | **37**| **all PASS** |

## Deviations from the plan

1. **`zig build test` not run locally on macOS.** Zig 0.13.0's bundled
   `libSystem.tbd` lacks symbol exports that the macOS 26 SDK (Tahoe) now
   requires. The Zig build *runner* itself fails to link before `build.zig`
   can execute. CI (Ubuntu) is unaffected; the new `ci-zig.yml` workflow
   runs `zig build test` on Linux. Local verification used direct
   `zig test src/<mod>.zig -target aarch64-macos.13.0 -lc` invocations and
   a one-shot `zig build-exe` with the equivalent flags. The binary built
   that way passes all e2e tests.
2. **`e2e/e2e_test.go` TestMain extended to honor `$BIN`.** The plan's CI
   step (`BIN=zig-out/bin/envless go test ./e2e/...`) cannot work otherwise.
   Only the bootstrap was changed; every assertion is byte-identical to
   the Go original. Go default behavior is unchanged when `$BIN` is unset.
3. **`build.zig` gates the `envless` exe and per-module test artifacts on
   file existence** so the tree builds cleanly at every commit during the
   incremental port (commit 1 had only `envparse.zig`; the final state has
   the full set).

No mocks, no skipped behaviors. All file-layout, external-binary
contract, dotenv render order, public-key parsing, and gitignore
idempotency rules from the plan §"Critical contracts" are preserved.
