---
title: When NOT to use envless
description: Honest non-goals. The cases where another tool is the right answer.
---

`envless` is small on purpose. The cost of staying small is that it does
not fit every secret-management need. Here are the situations where you
should pick something else.

## Pick a real KMS when

- You deploy to a single cloud and the workload runs under an IAM role.
  Cloud-native KMS (AWS Secrets Manager, GCP Secret Manager, Azure Key
  Vault) ties secrets to identity at the platform layer. Bypassing that
  to ship encrypted files in a repo is a regression.
- You need dynamic credentials with leases — short-lived database
  passwords, ephemeral cloud tokens. `envless` is static-secret only.
- You have an active red team and need pre-deploy secret rotation
  with attested supply-chain integrity. Vault + a notary tool is the
  expected stack.

## Pick a hosted vault when

- You want a UI for non-engineers to manage keys.
- You need SSO/SAML integration for human access.
- You need a compliance-grade audit log (SOC 2, ISO 27001) wired into a
  SIEM.

## Pick a password manager when

- The credentials are human-only: server SSH passphrases, account
  recovery codes, personal API tokens you do not want any agent or
  process to read.
- You need to share with non-developers who will never check out the
  repo.

## Pick `gh secrets set` / provider-native secrets when

- The secret is exclusive to one CI provider and never touches developer
  machines. GitHub Actions secrets, Vercel env vars, etc. are encrypted
  at rest by the provider and can be limited to deploy contexts.

## Hard limits of envless v0.0.1

These are not philosophical — they are current implementation gaps. Track
the [roadmap](../roadmap/) for status.

- **Single identity per repo.** Multi-recipient is the file format
  (`.envless/recipients` accepts many lines), but the v0.0.1 `init`
  command writes only the local pubkey. You manage extra recipients by
  editing the file by hand.
- **No `panic` mode.** No one-command revoke-and-re-encrypt across all
  envs. Coming in v0.2.
- **No GUI.** There will never be a GUI.
- **No remote sync.** Sync is `git push`. If your team cannot use Git,
  `envless` is the wrong tool.

## Co-existing with envless

`envless` is happy to share a project with:

- **direnv** for shell-level env loading. `envless exec` is for spawning;
  `direnv` is for interactive shells.
- **gh secrets / Vercel env** as deploy-time stores. Use `envless export`
  (planned) or a CI step that decrypts and re-exports.
- **A KMS for prod.** `envless` for dev/staging, KMS for prod. Different
  trust boundaries, different tools.
