---
title: Quickstart
description: From zero to a running process with secrets injected — 60 seconds.
---

```bash
cd my-project

envless init                                 # creates .envless/identity.key
echo "sk-test-xyz" | envless set OPENAI_API_KEY

envless list                                 # → OPENAI_API_KEY
envless exec -- node server.js               # process.env.OPENAI_API_KEY populated
```

That's it. Your code keeps using `process.env.OPENAI_API_KEY`. No library import. No `.env` on disk.

## Multi-env

`dev` is the default. Add `prod`:

```bash
echo "sk-prod-xyz" | envless set OPENAI_API_KEY --env=prod
envless exec --env=prod -- npm run deploy
```

Recipients per env are deferred to v0.1 (`.envless/team.yaml`). For v0.0.1, all envs share the local identity.

## Migrate from `.env`

```bash
envless migrate .env
# → encrypts .env → secrets/dev.env.enc
# → removes .env
# → adds .env to .gitignore
```

If you want to keep the plaintext for reference (e.g. mid-migration):

```bash
envless migrate .env --keep
```

## Read a value back

`get` requires `--confirm` to print plaintext. Prevents accidental shell-history leaks.

```bash
envless get OPENAI_API_KEY --confirm
```

For programmatic use, prefer `envless exec`.

## What gets committed

```
.envless/
  recipients          # public keys (commit)
  identity.key        # YOUR SECRET KEY — gitignored

secrets/
  dev.env.enc         # commit (encrypted)
  prod.env.enc        # commit (encrypted)

.env                  # gitignored after migrate
```

`identity.key` is on `.envless/` ignore list automatically. Triple-check with `git status`.

## Next

- [The .env problem](../../concepts/the-dot-env-problem/) — why this exists.
