---
title: Positioning
description: What envless is, who it serves, and why it exists.
---

`envless` is an open-source CLI that replaces plaintext `.env` files with
encrypted-in-repo secrets, while preserving the `process.env.KEY` interface
that every language and framework already speaks.

It is built for the era where every developer drives multiple AI agents,
schedules background jobs, and shares logs in transcripts that were never
meant to hold credentials. The assumptions that made `.env` workable for a
single human at a single laptop have stopped holding.

## What envless is

- A single static binary on top of two well-audited primitives: [age] for
  encryption and [sops] for per-value secret operations.
- File-based and Git-native. Encrypted files live next to your code; access
  control is a public-key list that diffs cleanly in a pull request.
- Zero servers, zero accounts, zero SaaS. There is nothing to log into, no
  tier to upgrade, no vendor to depend on.
- Language-agnostic. `envless exec -- your-command` injects secrets into
  the child process's environment at fork time. Your application keeps
  reading `process.env.X`.

## Who it is for

- **Solo developers** who want secrets out of `.env` without standing up a
  KMS.
- **Small teams** that need granular, revocable access without buying a
  vault service.
- **Agent-driven workflows** where multiple autonomous processes need
  scoped credentials and where shared `.env` files are an audit nightmare.
- **CI/CD pipelines** that today copy-paste `.env` contents into provider
  secret stores and watch them drift.

## What envless is not

`envless` is not a hosted vault, not a password manager, not a KMS
replacement for cloud-native deployments. See
[When NOT to use envless](../when-not/) for the explicit non-goals.

## Status

v0.0.1 — single-user core. Teams, plugins, and an `npx @envless/skill`
installer ship in v0.1. See the [roadmap](../roadmap/).

[age]: https://age-encryption.org/v1
[sops]: https://getsops.io/docs/
