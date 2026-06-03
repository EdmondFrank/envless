---
title: Exit codes
description: Every exit code envless emits, what it means, and what causes it.
---

`envless` follows Unix conventions: `0` on success, non-zero on
failure. The two interesting nuances are `exec`, which propagates the
child's exit code verbatim, and `get`, which fails fast without
`--confirm`.

## Codes table

| Code | Where it comes from | Meaning |
|---|---|---|
| `0` | every subcommand | success |
| `1` | cobra / envless wrapper | unhandled error (missing arg, parse failure, file not found, sops error, `get` without `--confirm`, etc.) |
| **N** | `envless exec` | child process exited with code N (propagated via [`execenv.ExitError`][gh-execenv]) |
| `127` | shell or OS | binary not found on `PATH` — comes from the shell, not from `envless` |

## Behaviour, by subcommand

### `envless --version`

- `0` always (assuming the binary launched at all).

### `envless init`

- `0` on success or no-op (identity already exists).
- `1` if `age-keygen` is missing or fails. Stderr includes
  `store: age-keygen: ...` and the captured `age-keygen` stderr.

### `envless set`

- `0` on success.
- `1` if stdin read fails, if recipients file is empty, or if
  `sops encrypt` errors.

### `envless get`

- `0` and prints the value on success.
- `1` if `--confirm` is absent. Stderr: `printing a secret requires
  --confirm`.
- `1` if the key is not in the env. Stderr: `key "X" not found in env
  "Y"`.
- `1` if `sops decrypt` errors.

### `envless list`

- `0` on success, including the empty-set case.
- `1` on decrypt or store errors.

### `envless exec`

- **Child exit code**, verbatim, when the child runs and exits normally
  or with an error code. `envless` itself does not interpret the code.
- `1` if `--` is followed by no command (`exec: missing command`).
- `1` if decryption fails before the child starts.
- Shell-level `127` if the command binary is not found — that is the
  OS exec failure, not an `envless` exit. The Go `os/exec` package
  surfaces this as `*exec.ExitError`, which envless wraps and exits
  with `1`.

### `envless migrate`

- `0` on success (and on `--keep`).
- `1` if the source file is missing, unreadable, fails to parse, or
  the encrypt step fails.

## Implementation reference

The `exec` propagation is the only non-trivial case. From
[`internal/ecmd/exec.go`][gh-exec]:

```go
runErr := execenv.Run(args, child, os.Stdin, cmd.OutOrStdout(), cmd.ErrOrStderr())
if runErr == nil {
    return nil
}
var xe *execenv.ExitError
if errors.As(runErr, &xe) {
    os.Exit(xe.Code)
}
return runErr
```

And the `ExitError` definition from [`internal/execenv`][gh-execenv]:

```go
type ExitError struct{ Code int }
func (e *ExitError) Error() string { return fmt.Sprintf("exit status %d", e.Code) }
```

Any non-`ExitError` returned from the run path bubbles up to the cobra
default handler, which prints to stderr and exits `1`.

## Scripting against `envless exec`

Because `exec` propagates exactly, the common shell idiom works:

```bash
envless exec -- ./run-tests.sh
echo "tests exited $?"
```

Or, for fail-fast pipelines:

```bash
set -euo pipefail
envless exec -- ./run-tests.sh
envless exec -- ./deploy.sh
```

[gh-execenv]: https://github.com/biliboss/envless/blob/main/internal/execenv/execenv.go
[gh-exec]: https://github.com/biliboss/envless/blob/main/internal/ecmd/exec.go
