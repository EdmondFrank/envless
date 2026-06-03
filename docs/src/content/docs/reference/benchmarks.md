---
title: Benchmarks
description: How envless's performance is measured. Numbers live in the changelog, not here.
---

`envless` is benchmarked on every release. The numbers themselves are
not embedded in this page — they flow through the
[Changelog](../../releases/changelog/), where each release joins to its
recorded `bench/results/<sha>.json` and renders a delta table. Linking
performance to the release that produced it keeps history truthful and
avoids stale screenshots.

## What gets measured

The harness in `bench/run.sh` (Workstream B) measures, on every commit
to `main` and every release tag:

| Metric | Tool | What |
|---|---|---|
| **Build time** | `hyperfine` | Wall time for `make build` (or `zig build -Doptimize=ReleaseSmall` once Zig lands). 3 warmup, 10 measured runs. |
| **Binary size** | `du -b bin/envless` | Bytes per OS/arch. Static, stripped. |
| **Cold start** | `hyperfine` | `./bin/envless --version`. Fresh process, no warmup. |
| **`envless exec` latency** | `hyperfine` | `./bin/envless exec --env=dev -- true` against a seeded repo with 10 keys. Captures full lifecycle: cobra parse → sops decrypt → fork/exec. |
| **`envless list` latency** | `hyperfine` | `./bin/envless list --env=dev` against the same seeded repo. |
| **Peak RSS** | `/usr/bin/time -v` | `Maximum resident set size` for the operations above. |
| **E2E wall-clock** | `time` | `go test ./e2e/...`. The full e2e suite. |

The full driver, knobs, and CI matrix are documented in `bench/run.sh`
once Workstream B lands.

## Where the data lives

```
bench/
├── run.sh                  # the driver
├── compare.sh              # delta-table generator
└── results/
    ├── 585b8c1b9beabc83.json
    ├── ...
```

Each `results/<sha>.json` is a single JSON document with one key per
metric. The schema is intentionally flat so the changelog renderer
([`docs/src/lib/releases.ts`](https://github.com/biliboss/envless/blob/main/docs/src/lib/releases.ts))
can join releases to bench results without any munging.

## How the changelog joins benchmarks to releases

For each GitHub Release, the renderer:

1. Reads `release.target_commitish` (the commit SHA the tag points to).
2. Looks for `bench/results/<sha>.json`.
3. If found, computes the delta against the previous release's bench
   record and renders a colored table (green for improvements, red for
   regressions, neutral grey for no-change-or-no-data).

If a release has no bench record (e.g. a quick patch tag), its Performance
table renders an empty-state row that links here.

## Comparing local to CI

To reproduce the CI numbers locally, install `hyperfine` and run:

```bash
hyperfine --warmup 3 --runs 10 './bin/envless --version'
hyperfine --warmup 3 --runs 10 './bin/envless list --env=dev'
hyperfine --warmup 3 --runs 10 './bin/envless exec --env=dev -- true'
```

Local laptops will be 20–50% off CI-measured runners — the absolute
numbers only matter as deltas between commits on the same hardware.
The changelog's delta column does the right thing.

## Once the Zig port lands

The Zig binary will be measured side-by-side with the Go binary on the
same harness. The Workstream A goal is parity on functionality and
a non-regression on every metric, with wins expected on cold start,
binary size, and peak RSS.

## Status — v0.0.1

The harness is not yet implemented. v0.0.1 ships without bench
artifacts. Once Workstream B publishes `bench/run.sh` and populates
`bench/results/`, the changelog will retroactively pick up everything
that has a matching commit SHA — no doc edits required.
