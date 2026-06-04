---
title: Threat model
description: What envless protects against, and just as importantly, what it does not.
---

`envless` inherits its cryptographic guarantees from [age] and [sops]. It
is a thin orchestrator; it adds no new primitives, but it also adds no
new attack surface beyond the shell-out to those binaries. The threat
model below is the practical consequence of that design.

## What envless protects against

- **Secret leakage in commits.** Plaintext `.env` files are gone. Every
  committed file (`secrets/*.env.enc`, `.envless/recipients`) is either
  encrypted or a public-key list.
- **Casual shoulder-surfing.** `envless list` prints keys but never
  values. `envless get` requires `--confirm`. `envless exec` writes
  secrets only into the child process's env array — never stdout.
- **Lost laptop, no `identity.key`.** Without the age secret key,
  encrypted files in the repo are bytes of ciphertext. Recipients can
  be added/removed, identities revoked by re-encrypting.
- **Drift between developer machines.** The encrypted file in Git is
  the canonical source. There is no "what's in your local `.env`?"
  divergence.
- **Stale agent transcripts.** Logs containing `OPENAI_API_KEY=...` are
  no longer possible: the variable is set inside the child process,
  not echoed to stdout by `envless` itself.

## What envless does NOT protect against

These are the parts where treating `envless` as a vault would be a
category error.

- **A running process inspected via `ptrace`, `/proc/<pid>/environ`, or
  memory dump.** Once a secret is loaded into the child's env, the
  child's memory is fair game. Use a real cloud KMS with workload
  identity if this is your threat.
- **A malicious recipient.** Adding a pubkey to `.envless/recipients`
  grants permanent access to every encrypted file from that point on.
  Revoking the pubkey only stops *future* encryptions from being
  readable. Anyone who held the key during the window can decrypt
  history. Rotate secret values, not just recipients. See
  [Key rotation](../rotation/).
- **Compromised `identity.key`.** Anyone with the secret key can
  decrypt anything encrypted to their pubkey. Treat the file as a
  credential of last resort: `0600`, never committed, store off-host
  if you back it up.
- **Compromised `sops` or `age` binary.** `envless` does not verify
  signatures on the shelled-out binaries. Pin versions, use your
  distro's verified packages, or `cosign verify`.
- **Side channels in your editor / shell history.** `envless get
  --confirm` prints plaintext. So does `echo $SECRET`. If you type the
  secret on stdin during `envless set`, your `bash` history will
  remember `echo "..." | envless set`. Use `read -s` or paste via a
  here-string with leading whitespace.
- **Supply-chain attacks on Go modules.** `envless`'s direct deps are
  three Go packages (cobra + transitive). The encryption substrate is
  external binaries. See [Audit & supply chain](../audit/).
- **Plaintext logs from your application.** If your code does
  `console.log(process.env)`, that's on you, not on `envless`.

## Trust boundaries

| Boundary | Who is trusted | What can they do |
|---|---|---|
| File at rest in repo | anyone with the repo + a recipient key | nothing without the secret key |
| `.envless/identity.key` | the developer / agent on this machine | decrypt every env they have a recipient for |
| `sops` + `age` binaries on `PATH` | whoever installed them | full read of plaintext during decrypt |
| Child process spawned by `exec` | inherits the env you injected | act on the secrets per your app's code |

If your operations require a tighter trust model than this — RBAC,
auditable access, ephemeral creds — see [When NOT to use
envless](../../why/when-not/).

[age]: https://age-encryption.org/v1
[sops]: https://getsops.io/docs/
