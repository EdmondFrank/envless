---
title: Disaster recovery
description: What to do when an identity is lost, a key is leaked, or the repo is gone.
---

`envless` is file-based, so disaster recovery is largely Git recovery
plus a small set of key-management steps. The scenarios below cover the
realistic failure modes.

## Scenario 1 — Identity file lost (no leak)

You deleted `.envless/identity.key`, or it lived on a wiped laptop, but
you have no reason to believe anyone else has a copy.

1. On a fresh checkout, run `envless init`. A new identity is generated.
2. Get a teammate (or any existing recipient) to add your new pubkey to
   `.envless/recipients` and re-encrypt — see
   [Team onboarding](../onboarding/).

You temporarily lose the ability to decrypt until step 2 lands. The
encrypted data is intact.

## Scenario 2 — Identity file leaked

Assume the worst: someone has a copy of `.envless/identity.key`.

1. **Rotate every secret value** at the upstream provider. The leaked
   key can decrypt all current and historical encrypted files in Git.
   See [Key rotation](../../security/rotation/).
2. **Remove the leaked pubkey** from `.envless/recipients`.
3. **Generate a new identity** (`envless init` after `rm
   .envless/identity.key`) and add it to recipients.
4. **Re-encrypt every env** with the new recipient set.
5. **Communicate to the team** — the leaked identity is permanently
   useless after step 1, but document the timeline.

Do NOT skip step 1. Revoking the recipient stops future encryptions
from including the leaked key, but the attacker already has copies of
the encrypted files via Git history.

## Scenario 3 — Last remaining identity holder is gone

The only person who could decrypt left, and they're not reachable.

If no other recipient has access, **the secrets are unrecoverable from
the encrypted files**. This is by design — there is no backdoor. Your
recovery path:

1. Recover secret values from their upstream sources (provider
   dashboards, prior `.env` backups, the team password manager, etc.).
2. Initialize a fresh envless state on a clone:
   ```bash
   rm -rf .envless secrets
   envless init
   # then `envless set` each recovered value
   ```
3. Commit and force-push, or replace history if your repo policy
   requires it.

**Mitigation**: always keep at least two recipients with decrypt
access — e.g. one human and one bot identity stored encrypted in a
password manager.

## Scenario 4 — Repository gone (host loss)

Git is distributed. Any team member who pulled recently has the
encrypted files locally. To recover:

1. Identify the most recent clone.
2. `git push --mirror` to a new remote.
3. Resume normal operation.

The `.envless/identity.key` files are *not* in Git, so each developer's
local copy is still valid against the recovered repo.

## Scenario 5 — Corrupted `secrets/<env>.env.enc`

The file fails to decrypt — `sops` errors with MAC mismatch or YAML
parse failure.

1. `git log -p secrets/<env>.env.enc` — find the last known-good commit.
2. `git checkout <good-sha> -- secrets/<env>.env.enc`.
3. Decrypt and commit. The intervening encrypted edits are lost; merge
   from a teammate's working copy if they have newer values.

If no good commit exists in history (e.g. a bad commit landed in main
weeks ago and propagated), follow Scenario 3 — recover from upstream
sources.

## Backups worth keeping

- `.envless/identity.key` in an offline password manager (1Password,
  Bitwarden) per identity holder.
- Periodic `git bundle create` of the repo, stored off-host, if your
  Git host is the only copy.

The encrypted files in Git are not sensitive on their own — they are
just bytes. The keys are.
