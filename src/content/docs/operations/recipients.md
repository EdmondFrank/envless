---
title: Recipient management
description: The .envless/recipients file format, semantics, and review process.
---

`.envless/recipients` is the access-control plane for `envless`. Every
encrypted file is encrypted to the keys listed here. Adding a line
grants future read access; removing a line stops future writes from
including the recipient — but does not retroactively redact past
encryptions.

## Format

Plain text, one [age] public key per line. Lines starting with `#` are
comments. Blank lines are ignored.

```
# Humans
age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p  # alice
age1z6f0ldygfp22k0w50zss5pl4kxvkzlulhpqcmm8m65rt6q08vrnsq8ec6t  # bob

# CI
age1mh6gh39mhqaeu2cysr0gwz2ts83krppyzj8nrz86g2yax7gx7scqgca2x9  # gh-actions-deploy
```

Comments are useful for owner labels but are not part of the access
decision — `sops` only sees the keys.

## Source-of-truth semantics

The file in the default branch of the repository is authoritative.
A local edit means nothing until it lands in `main`. This is by design:
PR review is the access-control workflow.

The parser ([`store.Recipients()`][gh-store]) treats lines like this:

```go
for _, line := range strings.Split(string(data), "\n") {
    line = strings.TrimSpace(line)
    if line == "" || strings.HasPrefix(line, "#") {
        continue
    }
    out = append(out, line)
}
```

A trailing inline `# comment` on the same line as a pubkey is **kept as
part of the key**. Put comments on their own line.

If the file is empty after stripping comments, every encryption call
fails with `store: no recipients in <path>`.

## Reviewing changes

Diffs to `.envless/recipients` are the moment to slow down. A PR that
touches this file should pass a checklist:

- Does the PR identify the human/agent/CI runner behind each new key?
- Does the same PR re-encrypt every `secrets/*.env.enc`? (See
  [Onboarding](../onboarding/) for the loop.)
- For removals: have the corresponding secrets been rotated upstream
  (see [Key rotation](../../security/rotation/))?

A CODEOWNERS rule pinning `.envless/**` to a security reviewer is a
good template for teams larger than three.

## Multi-environment caveat (v0.0.1)

Today there is one `.envless/recipients` file for the entire repo.
Every env (`dev`, `staging`, `prod`) uses the same recipient list. If
you need per-env access — e.g. ops sees prod, devs see dev — you have
two interim options:

1. **Two repos.** One per trust tier. Crude but secure.
2. **Wait for v0.1's `.envless/team.yaml`** which introduces per-env
   recipient roles.

## Programmatic listing

```bash
# Stable, scriptable list of pubkeys
grep -v '^#' .envless/recipients | grep -v '^$' | awk '{print $1}'
```

`envless` itself does not yet expose `envless recipients list` — that
is a v0.1 convenience.

[age]: https://age-encryption.org/v1
[gh-store]: https://github.com/biliboss/envless/blob/main/internal/store/store.go
