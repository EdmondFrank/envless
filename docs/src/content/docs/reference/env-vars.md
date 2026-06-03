---
title: Environment variables
description: Variables envless reads, sets, or forwards. There are fewer than you think.
---

`envless` is configured almost entirely by files and flags. It reads
exactly one external env var, sets one for child processes (`sops`
decryption), and forwards every variable in the parent's environment
into `exec` children.

## Read by envless

| Variable | Read by | Purpose |
|---|---|---|
| `PATH` | OS / `os/exec` | Locating `age-keygen` and `sops`. Standard `exec.LookPath` semantics. |

That is the entire intentional read set in v0.0.1. Anything else cobra
or the Go runtime touches (`HOME`, `TMPDIR`) is incidental and not
part of the contract.

## Set by envless (for child processes)

| Variable | Set by | Purpose |
|---|---|---|
| `SOPS_AGE_KEY_FILE` | `internal/sopswrap.Decrypt` | Points sops at `.envless/identity.key`. Set only on the `sops decrypt` child process — not exported to your shell. |

The `sops` call ([`sopswrap.go`][gh-sopswrap]) builds its env like so:

```go
cmd.Env = append(os.Environ(), "SOPS_AGE_KEY_FILE="+identityFile)
```

So `SOPS_AGE_KEY_FILE` overrides any inherited value for the duration
of the decrypt.

## Forwarded into `envless exec` children

`envless exec` constructs the child env by merging:

- Every `KEY=VALUE` from `os.Environ()` (the envless process's parent
  env).
- Every entry from the decrypted secrets map. Secrets override matching
  parent keys.

The merged set is sorted lexicographically and passed as `cmd.Env`.
The merge logic is in [`internal/execenv.BuildEnv`][gh-execenv]:

```go
merged := map[string]string{}
for _, e := range parent {
    k, v, ok := strings.Cut(e, "=")
    if !ok { continue }
    merged[k] = v
}
for k, v := range kv {
    merged[k] = v
}
```

Note: secrets win. If your shell exports `OPENAI_API_KEY=local` and the
env file contains `OPENAI_API_KEY=sops`, the child sees `sops`.

## Variables NOT defined by envless

For clarity, `envless` does **not** read or honour any of the
following — listed because users sometimes expect them by analogy with
sops, dotenv-vault, or direnv:

- `ENVLESS_HOME`, `ENVLESS_CONFIG`, `ENVLESS_NO_COLOR`, etc. — not
  implemented.
- `SOPS_AGE_RECIPIENTS` — sops respects this for encryption, but
  `envless` always reads recipients from `.envless/recipients`, so
  setting `SOPS_AGE_RECIPIENTS` has no effect on `envless`-mediated
  calls.
- `AGE_IDENTITY` — convention for storing the secret key in CI, but
  `envless` does not read it directly. Materialise the file (see
  [CI/CD integration](../../operations/cicd/)).

## Convention used elsewhere in the docs

In CI examples, we use `AGE_IDENTITY` (a CI-provider secret holding
the contents of `.envless/identity.key`). That is a documented
convention for users, not a variable `envless` reads — the CI step
writes it to disk before invoking `envless`.

[gh-sopswrap]: https://github.com/biliboss/envless/blob/main/internal/sopswrap/sopswrap.go
[gh-execenv]: https://github.com/biliboss/envless/blob/main/internal/execenv/execenv.go
