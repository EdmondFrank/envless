---
title: Roadmap
description: What ships next, what is deferred, and why.
---

`envless` follows a deliberate "smallest useful thing first" release
cadence. The v0.0.1 line is single-developer ergonomics. The v0.1 line
opens to teams. The v0.2 line hardens the security operations surface.
v1 is the API-stable cutover.

## Shipped — v0.0.1

The single-user core is complete and tested end-to-end.

- `envless init` — local age identity + recipients file
- `envless set / get / list` — encrypted KV operations
- `envless exec` — process injection, the star command
- `envless migrate` — one-shot `.env` → encrypted migration
- Apache-2.0, GitHub Pages docs, GitHub Actions CI

See [Reference → CLI](../../reference/cli/) for the full surface.

## Next — v0.1 (Teams)

- **`@envless/skill`** — `npx @envless/skill install` installs envless,
  configures the local repo, and registers a Claude Code / Cursor skill.
- **Per-env recipients** — `.envless/team.yaml` enumerates members and
  scopes. `envless set` and `envless write` re-encrypt to the current
  recipient list per env.
- **Plugins** — subprocess binaries `envless-<kind>-<name>`. Initial
  plugins: `detect-node` (autodetects `process.env` keys), `ci-github`
  (patches workflows to inject from envless).
- **`envless team add / remove`** — recipient management via CLI.

## After that — v0.2 (Operations)

- **`envless panic`** — one command rotates the identity, re-encrypts
  every env, and emits a recipients-changed manifest.
- **Rotation adapters** — OpenAI, Stripe, Anthropic, etc. `envless
  rotate KEY` invokes the adapter, replaces the secret in-place.
- **Inbox / notice** — asynchronous secret hand-off between team members
  without out-of-band channels.

## v1 — API stable

- File-format freeze: any v0.x encrypted file decrypts under v1.
- CLI flag/exit-code freeze.
- Docs blog launch.
- Signed releases (cosign).

## What is explicitly off the roadmap

- A hosted dashboard.
- Provider-fetch (Vault, AWS Secrets Manager) — that is `teller`'s job.
- A language SDK. `process.env.X` is the SDK.
- A free vs. paid tier.

## Read the open issues

The roadmap above is the editorial summary. The truth lives in GitHub.

→ [Open issues](https://github.com/biliboss/envless/issues)
→ [Milestones](https://github.com/biliboss/envless/milestones)
