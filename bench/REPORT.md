# bench/REPORT.md — Go baseline (workstream B)

Result file: [`bench/results/49dc6f2a90f1512fb6ba91790b255a064f0fab9b.json`](results/49dc6f2a90f1512fb6ba91790b255a064f0fab9b.json)
Captured: `2026-06-03T22:02:28Z`
Toolchain: `go1.26.0`, `hyperfine 1.20.0`
Platform: `Darwin/arm64` (Apple Silicon, local laptop — not a CI runner)
Build: `make build` → `-trimpath -ldflags "-s -w -X main.version=v0.0.1-1-g49dc6f2"`

This is the Go baseline that Workstream A's Zig port has to beat (or at least
match) before cutover. Numbers below come from the very first end-to-end run
of `bench/run.sh`, committed alongside the harness as proof of life.

## Metrics

- **Build time** — mean 159.8 ms (σ 13.0 ms, 10 runs over hyperfine, range
  147–184 ms). `make build` invokes `go build -trimpath -ldflags "-s -w …"`
  against a warm Go build cache. Cold builds (cache cleared) are not measured
  yet — the warmup phase guarantees a warm cache, which matches how the
  binary is actually rebuilt during dev loops.
- **Binary size** — 2,725,874 bytes (~2.60 MiB) stripped. This is the
  go-built `bin/envless` after `-s -w` and `-trimpath`. UPX is not used.
  Zig's `ReleaseSmall` target should beat this comfortably; treat 2.60 MiB
  as the ceiling.
- **Cold start** — mean 1.80 ms (σ 0.44 ms, 50 runs, range 1.25–3.39 ms) for
  `./bin/envless --version`. Hyperfine warns it's near the calibration
  floor (~5 ms) so the absolute value should be read as "low single-digit
  milliseconds, dominated by exec/shell overhead". Use it as an ordering
  signal vs Zig, not as a literal latency budget.
- **`envless list --env=dev` latency** — mean 16.0 ms (σ 0.8 ms, 30 runs,
  range 14.8–17.6 ms) against a seeded 10-key repo. The hot path is one
  `sops decrypt` subprocess; the Go binary itself contributes well under
  the noise floor here, so the metric mostly measures sops + age.
- **`envless exec --env=dev -- true` latency** — mean 18.0 ms (σ 1.3 ms, 30
  runs, range 16.3–23.2 ms). Same shape as `list` but with a child
  process exec on top. The extra ~2 ms vs `list` matches expected fork+exec
  overhead on this hardware.
- **Peak RSS** — 35,323,904 bytes (~33.7 MiB) for one `envless list` run,
  captured via `/usr/bin/time -l`. Note this measures the envless process
  itself, not the sops/age children. The Go runtime floor (goroutine stacks,
  GC) is most of this footprint and is exactly what Workstream A targets.
- **E2E wall-clock** — 4.478 s for `go test -count=1 ./e2e/...` (8 tests
  including TestE2E_VersionFlag through TestE2E_Migrate). This includes
  the `go test` binary compile step inside `TestMain`. Expect Zig's e2e
  number to be similar because the cost is in the test runner, not the
  binary under test — included as a tripwire for "did the port regress
  the test suite shape".

## Caveats

- The numbers above are from an Apple M-series laptop, not a CI runner.
  CI numbers (Ubuntu runners) will differ — that is fine: the comparison
  script always diffs two runs on the *same* runner, so absolute drift
  between hosts doesn't matter.
- Hyperfine's calibration floor (~5 ms) means cold-start measurements
  carry meaningful noise. Reported stddev makes this visible.
- Peak RSS via `/usr/bin/time` measures the parent envless process only.
  `sops`/`age` child RSS is not included; a future metric could sum
  cgroup-level RSS but that requires Linux. Documented as a known gap.
- `bench/run.sh` exits non-zero on any subprocess failure (`set -euo
  pipefail`), so a broken e2e run will fail CI loudly rather than silently
  embedding `e2e_wallclock_sec: null`.

## Reproduce

```bash
# from repo root, with hyperfine + sops + age + jq + go installed
bench/run.sh
jq . bench/results/$(git rev-parse HEAD).json
```
