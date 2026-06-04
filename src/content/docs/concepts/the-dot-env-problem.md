---
title: The .env problem
description: Why dotenv breaks down once agents and teams get involved.
---

`.env` files were designed for one human, one machine, one trust boundary. AI agents shatter all three. Here's the breakdown.

## What `.env` assumes

1. **One person uses the secrets.** No granular access control. Whoever has the file has everything.
2. **The machine is trusted.** Plaintext on disk is fine because only you read it.
3. **You distribute out-of-band.** Slack DMs, password managers, "ping me when you onboard."

Those assumptions held when codebases had three developers and zero autonomous processes touching the file. They no longer hold.

## What changed

- **Multiple agents per developer.** Background sessions, scheduled jobs, delegated panes. Each may need different scopes.
- **Logs in shared contexts.** Agent transcripts, asciinemas, screen-shares. A single `cat .env` becomes a public broadcast.
- **CI/CD shares the same file.** GitHub Actions secrets diverge from local `.env`, drift accumulates, prod breaks.
- **Rotation is impossible at scale.** Rotating one API key means updating N humans, M agents, K CI environments. Most teams skip rotation.

## What `envless` does differently

```
.env (plaintext, gitignored)        →  secrets/*.env.enc (encrypted, committed)
shared password / file              →  per-identity age keypairs
out-of-band onboarding              →  PR adds pubkey to recipients
"hope it doesn't leak"              →  recipient list is the access-control plane
rotation requires N updates         →  rotation re-encrypts to current recipients
```

The substrate is two well-audited primitives — [age](https://github.com/FiloSottile/age) (file encryption) and [sops](https://github.com/getsops/sops) (per-value encryption with recipient lists). `envless` is the agent-facing ergonomics layer on top.

## Why not just use sops directly?

You can. We did for a while. Three issues kept biting:

1. **No `process.env` bridge.** `sops exec-env` exists but only handles dotenv format awkwardly. `envless exec` is the same idea, polished.
2. **No identity bootstrap.** sops assumes you already have an age key. Most devs do not. `envless init` solves it in one command.
3. **No migration story.** Going from `.env` to `secrets/dev.env.enc` is a half-dozen manual steps. `envless migrate .env` does it idempotently.

`envless` is sops with the rough edges removed and an opinion about how agents fit in.

## What it doesn't try to do

- Replace a real KMS for cloud-native deploys. If you have AWS KMS, use it.
- Be a password manager. 1Password, Bitwarden, etc. own that surface.
- Run a server. There is no server. There will never be a server.
- Have a free tier and a paid tier. There is no tier. It's a binary.

## Further reading

- [age — file encryption format](https://age-encryption.org/v1)
- [sops — secrets operations](https://getsops.io/docs/)
- [direnv — shell hook patterns](https://direnv.net/)
- [teller — provider-fetch alternative](https://github.com/tellerops/teller)
