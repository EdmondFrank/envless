---
title: Benchmarks
description: DevOps metrics for the envless CLI — build time, binary size, cold start, latency, RSS, and end-to-end suite duration.
---

The envless project ships a benchmark harness under [`bench/`](https://github.com/biliboss/envless/tree/main/bench) that measures the operational cost of the CLI on every PR. Each run emits `bench/results/<git-sha>.json` covering build time, binary size, cold start, `envless list` and `envless exec` latency, peak RSS, and the end-to-end test-suite wall-clock. The CI workflow at `.github/workflows/bench.yml` runs the harness against both PR HEAD and `main` HEAD and posts a markdown delta table as a PR comment — that table is the authoritative perf signal for reviewers.

:::note[Auto-populated]
This page is a stub. Workstream C of the migration plan (`plans/reflective-churning-donut.md`) wires a build-time renderer that pulls the most recent `bench/results/<sha>.json` and replaces the rest of this page with a live metric table plus a per-release delta history. Until that renderer lands, browse the raw JSON in the `bench/results/` directory of the repository, or run `bench/run.sh` locally for an up-to-date number on your machine.
:::
