---
title: Development setup
description: Clone, build, test. Plus the conventions you should know before sending a PR.
---

`envless` is a Go module today, with a planned Zig port (see
[roadmap](../../why/roadmap/)). This page covers the Go-era setup.
Once Zig lands, both paths will be documented side-by-side here.

## Prerequisites

- **Go 1.26+**
- **age** ≥ 1.2 — `brew install age` / `apt install age`
- **sops** ≥ 3.9 — install from
  [getsops/sops releases][sops-releases]
- A POSIX shell. Tests assume `/bin/sh` is available.

## Clone and build

```bash
git clone https://github.com/biliboss/envless.git
cd envless

make build
# → bin/envless

./bin/envless --version
```

`make build` (see [`Makefile`][gh-makefile]) runs:

```bash
go build -trimpath -ldflags "-s -w -X main.version=$(VERSION)" -o bin/envless ./cmd/envless
```

`VERSION` defaults to `git describe --tags --always --dirty`, falling
back to `dev`.

## Project layout

```
.
├── cmd/envless/main.go              # entrypoint (20 LOC)
├── internal/
│   ├── ecmd/                        # cobra subcommands
│   ├── execenv/                     # env merge + child spawn
│   ├── sopswrap/                    # sops binary wrapper
│   └── store/                       # filesystem layout, KV
├── pkg/envparse/                    # .env parser
├── e2e/                             # all-Go e2e tests
├── docs/                            # this site (Astro + Starlight)
├── spec/                            # release acceptance specs
└── .github/workflows/               # ci, release, docs
```

The `internal/` vs. `pkg/` split mirrors `cli/cli` (the GitHub CLI):
`internal/` is closed-domain and stateful; `pkg/` is reusable utilities
(`envparse` could be imported by an external Go project; the rest
should not).

## Coding style

- Standard Go style: `gofmt`, `go vet`, no extra lint config (yet).
- `make lint` runs both:
  ```bash
  go vet ./...
  test -z "$(gofmt -l .)"
  ```
- Caveman output convention: one line per action, all caps verb,
  `key=value` fields. Examples from the codebase:
  ```
  INIT  identity=.envless/identity.key pubkey=age1...
  SET   env=dev key=OPENAI_API_KEY
  MIGRATE  src=.env env=dev keys=3
  ```
  No spinners, no banners, no emojis.

## Adding a subcommand

The pattern is one file per subcommand under `internal/ecmd/`,
following the existing examples:

```go
// internal/ecmd/foo.go
func newFooCmd() *cobra.Command {
    var envName string
    cmd := &cobra.Command{
        Use:   "foo [args...]",
        Short: "one-line description",
        RunE: func(cmd *cobra.Command, args []string) error {
            // ...
            fmt.Fprintf(cmd.OutOrStdout(), "FOO  env=%s\n", envName)
            return nil
        },
    }
    cmd.Flags().StringVar(&envName, "env", "dev", "environment name")
    return cmd
}
```

Wire it in `internal/ecmd/root.go`'s `root.AddCommand(...)`. Add unit
tests next to it (`foo_test.go`) and add an `e2e/` scenario.

## Running locally

```bash
go run ./cmd/envless --version
go run ./cmd/envless init
echo "v" | go run ./cmd/envless set TEST
```

For repeated dev cycles, `make build` plus `./bin/envless` is faster
because there's no compile-per-invocation.

## Docs

The docs site (this site) lives under `docs/` and is an Astro 5 +
Starlight 0.30 project. To work on it:

```bash
cd docs
pnpm install
pnpm dev          # live reload on http://localhost:4321
pnpm build        # production build, output to docs/dist/
```

GH Pages deploys are handled by
[`.github/workflows/docs.yml`][gh-docs-yml].

## Once Zig lands

The Zig port (Workstream A) will live in a parallel `src/` tree with a
`build.zig`. Until cutover, both binaries are exercised by the same
`e2e/` test suite. See the [roadmap](../../why/roadmap/) for status.

[sops-releases]: https://github.com/getsops/sops/releases
[gh-makefile]: https://github.com/biliboss/envless/blob/main/Makefile
[gh-docs-yml]: https://github.com/biliboss/envless/blob/main/.github/workflows/docs.yml
