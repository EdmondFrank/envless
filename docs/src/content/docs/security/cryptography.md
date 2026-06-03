---
title: Cryptography (age + sops)
description: The concrete primitives envless relies on. Not "we use AES-256" hand-waving.
---

`envless` does not implement any cryptography itself. It composes two
well-audited primitives. Knowing exactly which primitives matters for
your security review.

## age — file-level encryption

[`age`][age-spec] (Actually Good Encryption) is a small format and tool
for file encryption with multiple recipients.

- **Key agreement:** X25519 for recipient keys (`age1...`).
- **Key derivation:** HKDF-SHA256 from the X25519 shared secret.
- **Symmetric cipher:** ChaCha20-Poly1305 (AEAD).
- **Header format:** stanza-based, one per recipient + a single file
  key wrapped per recipient.

In `envless`, age is invoked indirectly through `sops` (sops handles the
data-key encryption). Identity generation goes through the standalone
`age-keygen` binary, which writes:

```
# created: 2026-01-01T00:00:00Z
# public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
AGE-SECRET-KEY-1XQ...
```

`envless` scans for the `# public key: ` marker to extract the pubkey
for the recipients file. See
[`store.PubKey()`][gh-store].

## sops — per-value encryption + metadata

[`sops`][sops-docs] (Mozilla's Secrets OPerationS) sits on top of age
and adds:

- **Per-value encryption** with a per-file *data key*. Keys (top-level
  field names) stay plaintext so file diffs remain semantic; only
  values are AES-GCM encrypted.
- **MAC** over the encrypted document for integrity (sorted-key
  hash).
- **Multi-recipient data-key wrap**: the data key is encrypted once
  per recipient (per age pubkey, in our case).
- **Format-aware**: dotenv, YAML, JSON, INI, BINARY. `envless` uses
  dotenv exclusively.

The exact invocations `envless` uses (from
[`internal/sopswrap`][gh-sopswrap]):

```
sops encrypt \
  --input-type dotenv \
  --output-type dotenv \
  --age age1...,age1... \
  /tmp/envless-enc-*.env

sops decrypt \
  --input-type dotenv \
  --output-type dotenv \
  secrets/dev.env.enc
# with SOPS_AGE_KEY_FILE pointing at .envless/identity.key
```

Decryption reads the SOPS_AGE_KEY_FILE env var to locate the identity.
This is the *only* way `envless` references its secret key inside a
child process — never on argv.

## What this means in practice

- An attacker who reads `secrets/dev.env.enc` from the repo sees the
  key names but never the values without a matching age secret key.
- Rotating one recipient does not re-encrypt existing files — `sops`
  needs an explicit `sops updatekeys` invocation. `envless` does not
  expose this yet; see [Key rotation](../rotation/).
- The data key is symmetric (AES-256) — there is no asymmetric per-value
  encryption. Cracking one value worth of ciphertext does not extend
  to others, but compromising the data key compromises the entire file.
  The data key is itself wrapped to each recipient's age pubkey via
  X25519 + ChaCha20-Poly1305.

## Audited and battle-tested

- **age** has had at least [two formal audits][age-audits] (Cure53,
  Trail of Bits) and is built by Filippo Valsorda, ex-Go cryptography
  lead.
- **sops** is an OWASP-sponsored project, used in production by
  Mozilla, Adobe, and others, with [security advisories][sops-sec]
  published openly.

`envless` adds zero new crypto code on top. Its security posture is
"the union of age and sops at their currently pinned versions."

[age-spec]: https://age-encryption.org/v1
[sops-docs]: https://getsops.io/docs/
[age-audits]: https://github.com/FiloSottile/age#security
[sops-sec]: https://github.com/getsops/sops/security
[gh-store]: https://github.com/biliboss/envless/blob/main/internal/store/store.go
[gh-sopswrap]: https://github.com/biliboss/envless/blob/main/internal/sopswrap/sopswrap.go
