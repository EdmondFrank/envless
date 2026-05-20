# envless

Agent-first secrets. Zero `.env`. Zero servers. `process.env` kept.

> **Status:** v0.0.1 — single-user core works. Teams + plugins + skill in v0.1.

## Quickstart

```bash
# build
make build

# in any project
cd ~/your-project
~/src/envless/bin/envless init                       # creates .envless/identity.key
echo "sk-test-xyz" | ~/src/envless/bin/envless set OPENAI_API_KEY
~/src/envless/bin/envless list                       # → OPENAI_API_KEY
~/src/envless/bin/envless exec -- node server.js     # process.env.OPENAI_API_KEY populated
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
- Go 1.26 (build only)

## Architecture

- `cmd/envless/` — entrypoint
- `internal/ecmd/` — cobra commands
- `internal/store/` — file layout (.envless/, secrets/)
- `internal/sopswrap/` — sops binary wrapper
- `internal/execenv/` — env array build + child exec
- `pkg/envparse/` — .env parser

Single Go module. Apache-2.0.

## Tests

```bash
go test ./...     # 36 tests, < 3s
```

## Roadmap

- v0.1: skill (`npx @envless/skill install`), plugins (detect-node, ci-github), teams (`.envless/team.yaml`).
- v0.2: panic mode, rotation adapters, inbox/notice.
- v1: stable API, docs site, blog launch.

## License

Apache-2.0.
