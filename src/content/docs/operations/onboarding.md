---
title: Team onboarding
description: How a new teammate gets read access to encrypted secrets.
---

`envless` treats every team member as a public key. Onboarding is one
PR: the newcomer generates an identity, posts their pubkey, and the
existing team re-encrypts to include them.

## The newcomer's side

```bash
# 1. Clone the repo.
git clone git@github.com:org/repo.git
cd repo

# 2. Generate a local identity. The repo already has secrets/*.env.enc
#    and .envless/recipients — your `init` only creates your own
#    keypair if missing.
envless init

# 3. Print your pubkey so you can paste it into a PR.
grep "public key" .envless/identity.key
# → # public key: age1abcd...
```

The newcomer does not yet have decrypt access — their pubkey is not in
`.envless/recipients`.

## The team's side

A maintainer adds the newcomer's pubkey and re-encrypts.

```bash
# 1. Append the new pubkey.
echo "age1abcd..." >> .envless/recipients

# 2. Re-encrypt every env so the new recipient is in the data-key
#    wrap. v0.0.1 has no `envless re-encrypt`; the portable approach:
for env in dev prod; do
  for key in $(envless list --env="$env"); do
    val=$(envless get "$key" --env="$env" --confirm)
    printf '%s' "$val" | envless set "$key" --env="$env"
  done
done

# 3. Commit.
git checkout -b onboard-alice
git add .envless/recipients secrets/
git commit -m "onboard alice: add recipient + re-encrypt envs"
git push -u origin onboard-alice
gh pr create --fill
```

The PR diff makes the change auditable: one new line in `recipients`
and N changed lines in `secrets/*.env.enc`. The encrypted-bytes diff
is noise, but the `recipients` diff is human-readable and reviewable.

After merge, the newcomer pulls and runs `envless list` to confirm
decrypt access.

## Onboarding agents and CI runners

Identical pattern with a different name on the pubkey. Agents and CI
get their own keypairs — never share a human's identity with a bot.

```bash
# On the CI runner (or one-shot, key stored in GH Actions secret):
age-keygen -o /tmp/ci-identity.key
PUBKEY=$(grep "public key" /tmp/ci-identity.key | awk '{print $4}')
# Add PUBKEY to .envless/recipients via PR.
# Store /tmp/ci-identity.key contents as the GH secret AGE_IDENTITY.
```

See [CI/CD integration](../cicd/) for the workflow side.

## Anti-patterns to avoid

- **One identity for the whole team.** Defeats per-recipient revocation.
- **Committing `identity.key`.** It is gitignored by default; double-check
  before pushing.
- **Sending pubkeys over Slack as the source of truth.** The
  `.envless/recipients` PR is the source. Slack is a notification
  channel, not an audit trail.
- **Adding a pubkey without re-encrypting.** Until you re-encrypt, the
  new recipient cannot decrypt anything. The PR should bundle both
  changes.

## Tooling improvements coming in v0.1

- `envless team add alice@org --pubkey=age1...` — one-command recipient
  addition.
- `envless team revoke alice@org` — removal + automatic re-encrypt.
- `.envless/team.yaml` — per-env recipient lists with role names.

Until then, the manual flow above is the supported workflow.
