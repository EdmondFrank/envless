---
title: Release process
description: How an envless release is cut today, and the intended automated flow.
---

`envless` releases on Git tags. The process is largely automated by
[GoReleaser][gr] and GitHub Actions. This page documents both the
current shape and the changelog/benchmark hand-off that Workstream B
will close.

## Current release flow (`v0.0.1`)

The pipeline ([`.github/workflows/release.yml`][gh-release-yml]) triggers
on `push: tags: ['v*']`:

1. Check out at depth 0 (so goreleaser can read the full history).
2. Set up Go 1.26.
3. Run `goreleaser release --clean` with `GITHUB_TOKEN` from the workflow.

GoReleaser ([`.goreleaser.yaml`][gh-goreleaser]) emits, for each
`{linux,darwin} × {amd64,arm64}`:

- A static binary built with `CGO_ENABLED=0 -trimpath -ldflags "-s -w
  -X main.version=<tag>"`.
- A `.tar.gz` archive named
  `envless_<version>_<os>_<arch>.tar.gz`.
- A `checksums.txt` with SHA-256 of every archive.

The release is created as a **draft** (`release.draft: true`). A
maintainer flips it to "Published" once the assets are verified.

## Cutting a release locally

```bash
# 1. Make sure main is green and the changes you want are in.
git checkout main && git pull
make test

# 2. Bump the spec / docs as needed, then tag.
git tag v0.0.2
git push origin v0.0.2

# 3. Watch the release workflow finish, then publish the draft on
#    https://github.com/biliboss/envless/releases.
```

The docs site is rebuilt by [`docs.yml`][gh-docs-yml] on the next push
to `main` (or via `workflow_dispatch`). The Changelog page picks up the
new release from the GH API; no doc edits required.

## Intended automated flow (Workstream B)

The end state is a single tag push that produces:

1. Cross-built binaries (today).
2. **Bench artifacts** — `bench/run.sh` runs against the release SHA on
   a known runner and commits the result to `bench/results/<sha>.json`
   on `main`.
3. **A published GitHub Release** (no draft, signed assets).
4. **Docs site rebuild** — picks up the release entry, joins to the
   bench JSON, renders the perf delta inline.

The proposed `release.yml` once Workstream B lands:

```yaml
name: release

on:
  push:
    tags: ['v*']

jobs:
  bench:
    runs-on: ubuntu-latest      # consistent runner = consistent numbers
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.26' }
      - run: sudo apt-get install -y hyperfine
      - run: ./bench/run.sh
      - uses: stefanzweifel/git-auto-commit-action@v5
        with:
          commit_message: "bench: record results for ${{ github.ref_name }}"
          file_pattern: bench/results/*.json
          branch: main

  goreleaser:
    needs: bench
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-go@v5
        with: { go-version: '1.26' }
      - uses: goreleaser/goreleaser-action@v6
        with: { args: release --clean }
        env: { GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
```

Once that workflow exists, the only manual step in a release is the
tag push.

## Versioning policy

Pre-1.0: SemVer-shaped but not SemVer-binding. The CLI surface is
allowed to break between minor versions. File-format compatibility is
guaranteed within `0.x` — a `secrets/dev.env.enc` written by `0.0.1`
will decrypt under `0.1`.

Post-1.0: full SemVer. Breaking changes to the CLI or file format
require a major bump.

## Changelog discipline

The release notes you write on the GitHub Release page become the
Changelog page. Keep them:

- **Conventional-commits styled** — `feat:`, `fix:`, `docs:`,
  `chore:`, `BREAKING:`.
- **Linkable** — reference issue / PR numbers.
- **Concise** — the perf delta table is rendered automatically; you
  do not need to restate it in prose.

[gr]: https://goreleaser.com/
[gh-release-yml]: https://github.com/biliboss/envless/blob/main/.github/workflows/release.yml
[gh-goreleaser]: https://github.com/biliboss/envless/blob/main/.goreleaser.yaml
[gh-docs-yml]: https://github.com/biliboss/envless/blob/main/.github/workflows/docs.yml
