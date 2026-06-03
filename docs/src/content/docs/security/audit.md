---
title: Audit & supply chain
description: What's in the binary, where it comes from, and how to verify it.
---

`envless` is a small Go binary built from a small dependency graph. The
audit surface is intentionally narrow.

## Direct dependencies

From `go.mod` ([source][gh-gomod]):

| Module | Version | Why |
|---|---|---|
| `github.com/spf13/cobra` | v1.10.2 | CLI subcommand wiring |
| `github.com/spf13/pflag` | v1.0.9 | flag parsing (cobra transitive) |
| `github.com/inconshreveable/mousetrap` | v1.1.0 | Windows entry-point shim (cobra transitive) |

That is the entire transitive set. No HTTP clients, no JSON schemas, no
YAML libraries, no SDKs. A `go mod graph` should print three lines.

## External binaries `envless` shells out to

`envless` is useless without these on `PATH`. They are not bundled.

- **`age-keygen`** — from [filippo.io/age][age-gh]. BSD-3-Clause.
- **`sops`** — from [getsops/sops][sops-gh]. MPL-2.0.

The shell-out commands are exactly:

- `age-keygen -o <path>`
- `sops encrypt --input-type dotenv --output-type dotenv --age <recipients> <file>`
- `sops decrypt --input-type dotenv --output-type dotenv <file>` (with `SOPS_AGE_KEY_FILE`)

No other binary is invoked. No network calls.

## Network behaviour

`envless` makes zero outbound network calls in v0.0.1. Confirm with:

```bash
strace -f -e trace=network envless exec -- true
# (no connect, no sendto)
```

If that ever changes, it will be documented and gated behind an explicit
flag.

## Build provenance

The release pipeline ([`.github/workflows/release.yml`][gh-release])
uses [goreleaser] to cross-compile static binaries on
`ubuntu-latest` GitHub-hosted runners. The build:

- Disables CGO (`CGO_ENABLED=0`) — pure-Go static binary.
- Uses `-trimpath` and `-ldflags "-s -w"` — reproducible-ish output,
  no debug symbols, no local paths leaking into the binary.
- Targets `linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`.

The release tag is the only input. To reproduce a release locally:

```bash
git checkout v0.0.1
goreleaser release --snapshot --clean
sha256sum dist/envless_*.tar.gz
```

## Verifying a downloaded binary

GoReleaser emits `checksums.txt` next to each release. Verify:

```bash
curl -LO https://github.com/biliboss/envless/releases/download/v0.0.1/envless_0.0.1_linux_amd64.tar.gz
curl -LO https://github.com/biliboss/envless/releases/download/v0.0.1/checksums.txt
sha256sum -c --ignore-missing checksums.txt
```

Signed binaries (cosign) are a v1.0 goal — see the [roadmap](../../why/roadmap/).

## Vulnerability response

Report security issues by email rather than a public issue. See the
GitHub repo's `SECURITY.md` (will be added before v0.1). For now, file
a [private security advisory][gh-advisory].

## What you should still audit yourself

- The pinned versions of `age` and `sops` on your developer machines.
  They are not part of the envless release artifact.
- The `.envless/recipients` file in your repo — `git log -p
  .envless/recipients` shows every access change.
- The build provenance of `envless` itself if you build from source.
  `go mod verify` confirms the dependency hashes match `go.sum`.

[gh-gomod]: https://github.com/biliboss/envless/blob/main/go.mod
[gh-release]: https://github.com/biliboss/envless/blob/main/.github/workflows/release.yml
[gh-advisory]: https://github.com/biliboss/envless/security/advisories
[age-gh]: https://github.com/FiloSottile/age
[sops-gh]: https://github.com/getsops/sops
[goreleaser]: https://goreleaser.com/
