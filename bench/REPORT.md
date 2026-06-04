# bench/REPORT.md — Zig-only baseline (workstream B)

Result files: `bench/results/<sha>.json` per-SHA (verbose hyperfine
output), with a one-line summary appended to `bench/history.jsonl`.

The harness in `bench/run.sh` measures the Zig binary only.
Pre-cutover Go numbers remain in `bench/history.jsonl` as historical
data (lines with `go.*` keys) — they are not re-measured.

## What gets measured

- **Build time** — `cd zig && zig build -Doptimize=ReleaseSmall`, timed
  by `hyperfine --warmup 3 --runs 10`. A `--prepare` hook removes
  `zig/zig-out` and `zig/.zig-cache` so every measured run is a cold
  rebuild against a primed Zig stdlib cache.
- **Binary size** — `stat` on `zig/zig-out/bin/envless`. Typical
  ReleaseSmall output is ~150 KB on aarch64-linux; the static Zig
  binary has no runtime, no GC, and one dependency (libc).
- **Cold start** — `envless --version` × 50 hyperfine runs. Often
  dips below hyperfine's 5 ms calibration floor; treat the value as
  "indistinguishable from process spawn overhead" rather than a
  literal latency budget.
- **`envless list --env=dev` latency** — 30 runs against a 10-key
  seeded repo. Dominated by the `sops decrypt` subprocess.
- **`envless exec --env=dev -- true` latency** — 30 runs against the
  same repo. Adds one fork+exec on top of decrypt.
- **Peak RSS** — `/usr/bin/time -l` / `-v` for one `envless list`
  invocation. Measures the envless process only — not the sops/age
  children.
- **E2E wall-clock** — `zig build e2e` wall time (build + test
  runner + 6 e2e tests). Captures the contributor-visible test loop.

## Caveats

- Local-laptop and CI-runner numbers are not comparable. The
  comparison script always diffs two runs on the *same* runner.
- Hyperfine's calibration floor (~5 ms) means cold-start measurements
  carry noise. Reported stddev makes this visible.
- Peak RSS does not include sops/age child memory.
- `bench/run.sh` is the one intentional bash file in the otherwise
  full-Zig repo. See AGENTS.md.
- `bench/run.sh` exits non-zero on any subprocess failure (`set -euo
  pipefail`), so a broken e2e run fails CI loudly rather than silently
  embedding `e2e_wallclock_sec: null`.

## Reproduce

```bash
# from repo root, with hyperfine + sops + age + jq + zig installed
bench/run.sh
jq . bench/results/$(git rev-parse HEAD).json
```

On macOS 26 (Tahoe) the local Zig 0.13.0 build fails; run the harness
inside the OrbStack / Docker workflow documented in AGENTS.md.
