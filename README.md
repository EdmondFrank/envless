# envless

Agent-first secrets. Zero `.env`. Zero servers. `process.env` kept.

> **Status:** v0.0.1 — single-user core works. Teams + plugins + skill in v0.1.

## Install

```bash
# Homebrew (macOS + Linux). Pulls age + sops as deps.
brew tap biliboss/envless https://github.com/biliboss/envless
brew install biliboss/envless/envless
```

Or download a pre-built tarball from
[Releases](https://github.com/biliboss/envless/releases), or build
from source (see below).

## Quickstart

```bash
# build from source (needs Zig 0.13.0)
cd zig && zig build -Doptimize=ReleaseSmall

# in any project
cd ~/your-project
~/src/envless/zig/zig-out/bin/envless init                       # creates .envless/identity.key
echo "sk-test-xyz" | ~/src/envless/zig/zig-out/bin/envless set OPENAI_API_KEY
~/src/envless/zig/zig-out/bin/envless list                       # → OPENAI_API_KEY
~/src/envless/zig/zig-out/bin/envless exec -- node server.js     # process.env.OPENAI_API_KEY populated
```

Multi-env:

```bash
echo "sk-prod-xyz" | envless set OPENAI_API_KEY --env=prod
envless exec --env=prod -- npm run deploy
```

Migrate existing `.env`:

```bash
envless migrate .env       # encrypts → secrets/dev.env.enc, removes .env, adds to .gitignore
```

## Commands (v0.0.1)

| Command | Use |
|---|---|
| `envless init` | create local identity + recipients |
| `envless set KEY [--env=E]` | store secret from stdin |
| `envless get KEY [--env=E] --confirm` | print value (requires confirmation) |
| `envless list [--env=E]` | list keys, no values |
| `envless exec [--env=E] -- CMD` | run command with secrets injected |
| `envless migrate FILE [--env=E] [--keep]` | encrypt a .env file |
| `envless --version` | version |

## Requires

- `age` >= 1.2 (`brew install age`)
- `sops` >= 3.9 (`brew install sops`)
- Zig 0.13.0 (build only) — pinned in `zig/.zigversion`

## Architecture

- `zig/src/main.zig` — entrypoint
- `zig/src/cli/` — subcommand dispatcher (no cobra; hand-rolled)
- `zig/src/store.zig` — file layout (.envless/, secrets/)
- `zig/src/sops.zig` — sops binary wrapper
- `zig/src/execenv.zig` — env array build + child exec
- `zig/src/envparse.zig` — .env parser

Single Zig binary, no runtime deps, ~150 KB stripped. Apache-2.0.

## Tests

```bash
cd zig
zig build test     # 37 inline unit tests
zig build e2e      # 6 end-to-end tests against the built binary
```

## Release

```bash
cd zig
zig build release -Dversion=v0.0.1
# → dist/envless_v0.0.1_<target>.tar.gz × 4
# → dist/checksums.txt
```

Cross-builds for `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-macos`,
`aarch64-macos`.

## Roadmap

- v0.1: skill (`npx @envless/skill install`), plugins (detect-node, ci-github), teams (`.envless/team.yaml`).
- v0.2: panic mode, rotation adapters, inbox/notice.
- v1: stable API, docs site, blog launch.

## License

Apache-2.0.
