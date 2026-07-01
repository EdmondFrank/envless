# `bench/` — envless DevOps metric harness

This harness measures the operational cost of the envless Zig binary
across releases. It emits a single JSON file per git SHA and a
comparison script renders a markdown delta table that CI posts on PRs.

> Note: `bench/run.sh` is the one intentional bash file in an otherwise
> full-Zig repo — hyperfine orchestration is bash-native by tradition.
> See AGENTS.md.

## Layout

```
bench/
  run.sh         # build + measure + emit results/<sha>.json
  seed.sh        # deterministic 10-key repo, used by run.sh
  compare.sh     # diff two result files → markdown table
  results/       # one JSON per measured SHA, committed
  history.jsonl  # one summary line per measured SHA, committed
  REPORT.md      # methodology + caveats (free-form)
```

## Prereqs

| tool | why |
|---|---|
| `hyperfine` | statistical timing for build / cold start / list / exec |
| `jq` | result aggregation in `run.sh`, delta math in `compare.sh` |
| `sops`, `age` | envless shells out to these to seed the latency repo |
| `zig` | builds the Zig binary and runs the e2e suite |

Install on macOS: `brew install hyperfine jq sops age zig`.
Install on Debian/Ubuntu: `apt-get install hyperfine jq age` and grab
a sops release tarball; install Zig via the upstream tarball pinned to
`zig/.zigversion`.

## Run locally

```bash
# from repo root
bench/run.sh
# → bench/results/<git-sha>.json
# → bench/history.jsonl (appended)
```

The script:

1. Builds `zig/zig-out/bin/envless` via `cd zig && zig build
   -Doptimize=ReleaseSmall` and times it under hyperfine.
2. Seeds a throwaway envless repo (10 keys) via `bench/seed.sh`.
3. Measures cold start, `envless list --env=dev`, `envless exec
   --env=dev -- true`, peak RSS (`/usr/bin/time`), and `zig build e2e`
   wall-clock.
4. Emits `bench/results/<sha>.json` with the Zig toolchain version +
   OS/arch metadata.
5. Appends a one-line summary to `bench/history.jsonl`.

Any benchmark failure exits non-zero so CI surfaces the regression.

## Interpreting results

The JSON shape (`schema_version: 1`):

```jsonc
{
  "git_sha": "…",
  "timestamp": "2026-…Z",
  "platform":  { "os": "Linux", "arch": "aarch64" },
  "toolchain_versions": { "zig": "0.16.0", "hyperfine": "1.18.0" },
  "toolchains": [
    {
      "label": "zig",
      "binary": "/.../zig/zig-out/bin/envless",
      "binary_size_bytes": 143000,
      "build_time_sec":    { "mean": 0.05, "stddev": 0.01, "min": 0.04, "max": 0.07, "runs": 10 },
      "cold_start_sec":    { … },
      "list_latency_sec":  { … },
      "exec_latency_sec":  { … },
      "peak_rss_bytes":    5128192,
      "e2e_wallclock_sec": 1.20
    }
  ]
}
```

Lower is better for every metric. The comparison script renders deltas with
`-X%` for improvements and `+X%` for regressions; CI posts that table as a PR
comment.

```bash
bench/compare.sh <baseline-sha> <candidate-sha>
```

## Adding a new metric

1. Capture the measurement inside `bench_toolchain()` in `run.sh`. Use a
   temp-file under `$TMP`, follow the hyperfine pattern for timed runs.
2. Add the field to the `jq -n` object emitted per toolchain. Keep the field
   name `snake_case`, suffix the unit (`_bytes`, `_sec`).
3. Add a row to the loop in `compare.sh` matching the new field, with a
   `lower_is_better` flag for the delta sign.
4. Bump `schema_version` if you change an existing field's shape.
5. Document the metric here.

## Platform notes & caveats

- **Peak RSS units**: macOS `/usr/bin/time -l` reports bytes; GNU
  `/usr/bin/time -v` reports kilobytes. `run.sh` normalises to bytes. On
  Alpine/BusyBox `time` does not implement either flag — the harness falls
  back to `-1` and the comparison renders `n/a`.
- **Build-time hyperfine warmup deletes the binary**. After the timed loop
  the script issues one extra build so the size/cold-start steps have an
  artifact to measure.
- **Hyperfine warmup count is intentionally small**. 3 warmups + 10/30/50
  runs keeps the harness under a minute per toolchain on a 2024-class
  laptop. If you bump it, also bump the CI workflow timeout.
- **E2E wall-clock includes `zig build e2e` from a cold cache**. We
  measure the whole suite end-to-end on purpose — that is what a
  contributor actually waits for.

## CI

`.github/workflows/bench.yml` runs `bench/run.sh` against both PR HEAD and
`main` HEAD, then posts the comparison as a PR comment. Both result JSONs
are also uploaded as workflow artifacts.

For details on how the docs site picks up the latest result, see
`docs/src/content/docs/reference/benchmarks.md` and Workstream C of the plan.
