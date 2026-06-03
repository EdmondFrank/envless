---
title: Key rotation & compromise response
description: How to revoke an identity, rotate a secret, and respond when one of either leaks.
---

There are two kinds of rotation in `envless`, and conflating them is the
most common mistake.

1. **Rotating an identity** — replacing an age keypair, e.g. when a
   developer leaves or a laptop is lost.
2. **Rotating a secret value** — replacing the credential itself
   (`OPENAI_API_KEY=sk-old → sk-new`), e.g. when a key leaks.

Each requires a different response.

## Identity rotation (someone leaves the project)

When a recipient must lose access:

```bash
# 1. Edit .envless/recipients — remove the departed pubkey.
$EDITOR .envless/recipients

# 2. Re-encrypt every env. v0.0.1 has no `envless re-encrypt`; the
#    portable approach is decrypt → write → push:
for env in dev prod; do
  envless list --env="$env" >/dev/null   # warms up state
  # round-trip: read every key, set it back. This re-encrypts to
  # the current recipients.
  envless exec --env="$env" -- printenv > /dev/null   # validates decrypt
  # Use a tiny shell loop to rewrite (manual until v0.1):
  for key in $(envless list --env="$env"); do
    val=$(envless get "$key" --env="$env" --confirm)
    printf '%s' "$val" | envless set "$key" --env="$env"
  done
done

# 3. Commit and push.
git add .envless/recipients secrets/
git commit -m "revoke departed recipient; re-encrypt envs"
git push
```

Important caveat: the removed recipient had access to the *current
secret values* up to the moment of revocation. They retain that
knowledge. Identity rotation does **not** protect against secrets they
have already observed.

If the recipient was hostile or compromised, treat every secret they
could read as compromised and follow *secret rotation* below.

## Secret rotation (a credential leaked)

When a value itself is compromised:

```bash
# 1. Rotate at the upstream provider (Stripe dashboard, OpenAI
#    console, etc.). Get the new value.
NEW="sk-newvalue-xyz"

# 2. Replace in envless.
printf '%s' "$NEW" | envless set OPENAI_API_KEY --env=prod

# 3. Commit and deploy.
git add secrets/prod.env.enc
git commit -m "rotate OPENAI_API_KEY (provider rotation)"
git push
```

Provider rotation is the source of truth; `envless set` is the
mirror. Future versions (v0.2) will add `envless rotate KEY` adapters
that call the provider API for you.

## Identity loss (laptop stolen, key file leaked)

This is the worst case: the secret key itself has escaped your
control. Do, in order:

1. **Treat every secret encrypted to that pubkey as compromised.**
   Anyone with the secret key can decrypt all current and prior
   encrypted files in Git history.
2. **Rotate every credential at the upstream provider.**
3. **Generate a new identity** (`envless init` after `rm .envless/identity.key`).
4. **Edit `.envless/recipients`** to replace the old pubkey with the new one.
5. **Re-encrypt every env** as above.
6. **Force-push history rewrites only if you must** — Git history
   contains the encrypted files. They are unreadable without the lost
   key, but a defense-in-depth rewrite is fine.

## What v0.0.1 does not have yet

- `envless panic` — single command for the steps above. Coming in v0.2.
- `envless rotate KEY` — provider-aware rotation. v0.2.
- `envless team revoke USER` — recipient management via CLI. v0.1.

Until then, the manual sequences above are the supported workflow.
