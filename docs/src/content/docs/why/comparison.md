---
title: vs. Vault / 1Password CLI / Infisical / dotenv-vault
description: How envless compares to neighboring tools in the secrets space.
---

There is no shortage of secret managers. Here is how `envless` sits next
to the most common alternatives. The goal is not to win every column —
it is to make the trade-offs explicit so you pick the right tool.

## Side by side

| Dimension | envless | HashiCorp Vault | 1Password CLI | Infisical | dotenv-vault |
|---|---|---|---|---|---|
| **Hosting** | none (file in repo) | self-hosted server | hosted | hosted or self | hosted |
| **Account required** | no | no | yes | yes | yes |
| **Cost** | free, OSS | free OSS / paid HCP | paid | freemium | freemium |
| **Encryption at rest** | age + sops | own KMS | proprietary | own KMS | proprietary |
| **Access control** | age recipients (per pubkey) | policies + tokens | vaults + groups | projects + roles | env-level |
| **Revocation** | remove pubkey + re-encrypt | revoke token | remove user | remove member | rotate token |
| **Audit trail** | git history of `recipients` | server logs | hosted logs | hosted logs | hosted logs |
| **Process injection** | `envless exec -- cmd` | sidecar / templates | `op run --env-file` | `infisical run` | `dotenv-vault run` |
| **Works offline** | yes | no (needs server) | partial | no | no |
| **CI/CD model** | bot keypair = recipient | token in CI | service account | service token | service token |
| **License** | Apache-2.0 | BSL 1.1 / MPL | proprietary | MIT + commercial | proprietary |
| **Lock-in risk** | none (files + age key) | medium (Vault paths) | high (account) | medium | high |

## When each makes sense

- **HashiCorp Vault** — large org, central security team, dynamic secrets,
  cross-cloud. You need policies, leases, audit devices. Don't pick
  `envless` against Vault for a regulated bank.
- **1Password CLI** — your team already lives in 1Password. Integrating
  `op` is friction-free for them. Lock-in is the price.
- **Infisical** — you want a hosted dashboard with project/role UI and
  webhook integrations. `envless` does not provide a dashboard.
- **dotenv-vault** — closest in spirit. Hosted, multi-env, simple CLI.
  Choose it if you want zero file-management and accept the hosted
  account.
- **envless** — you want the simplest possible substrate: encrypted files
  in your repo, age public keys as the access list, no server. You are
  comfortable with the file living in Git.

## What `envless` deliberately does not have

- A web dashboard.
- A free vs. paid tier.
- A hosted account or login flow.
- Provider integrations (AWS Secrets Manager, GCP Secret Manager) — those
  belong at deploy time, not in your developer loop.
