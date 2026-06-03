---
title: Lifecycle of a secret
description: From init to exec, what happens at each stage. Derived from the e2e test suite.
---

The `e2e/e2e_test.go` file is the executable specification for what
`envless` does. This page narrates that spec.

## Stage 1 — `envless init`

```bash
envless init
# → INIT  identity=.envless/identity.key pubkey=age1...
```

What happens:

1. Creates `.envless/` with mode `0700`.
2. Shells out to `age-keygen -o .envless/identity.key`.
3. Chmods the identity to `0600`.
4. Scans the key file for the `# public key: ` marker.
5. Writes `.envless/recipients` containing that one pubkey.

Idempotent. Re-running `init` with an existing identity is a no-op.

## Stage 2 — `envless set KEY` (stdin → encrypted file)

```bash
echo "sk-test-xyz" | envless set OPENAI_API_KEY
# → SET   env=dev key=OPENAI_API_KEY
```

What happens:

1. Reads value from stdin. Trailing `\n` is stripped.
2. Calls `store.Read("dev")` — decrypts the existing
   `secrets/dev.env.enc` if present, else returns an empty map.
3. Merges the new KV into the map.
4. Calls `store.Write("dev", merged)`:
   - Renders dotenv format (sorted keys, `KEY=VALUE\n`, no quoting).
   - Writes to a temp file in `secrets/`.
   - Shells out to `sops encrypt --input-type dotenv --output-type
     dotenv --age <recipients> <tmpfile>`.
   - Writes sops stdout to `secrets/dev.env.enc`.
   - Removes the tempfile.

## Stage 3 — `envless list` (keys only)

```bash
envless list
# → OPENAI_API_KEY
```

Decrypts, sorts keys, prints to stdout. Values never touch stdout. This
is the same code path as `get`, with the value column stripped.

## Stage 4 — `envless exec -- CMD`

```bash
envless exec -- node server.js
```

What happens (per [`internal/execenv`][gh-execenv]):

1. Decrypts the env file via `store.Read(env)`.
2. Merges the secrets map into the current `os.Environ()`. Secrets
   override matching parent vars.
3. Sorts the merged `KEY=VALUE` list for determinism.
4. Spawns the child with `os/exec.Cmd.Env = merged`.
5. Stdin/stdout/stderr are passed through.
6. On non-zero exit, returns an `*execenv.ExitError{Code}` which the CLI
   propagates via `os.Exit(code)`. See [Exit codes](../../reference/exit-codes/).

The child process is unaware that the credentials were ever encrypted.
It just reads `process.env.OPENAI_API_KEY` like any other variable.

## Stage 5 — `envless migrate FILE`

```bash
envless migrate .env
# → MIGRATE  src=.env env=dev keys=3
# → REMOVE   .env
```

What happens:

1. Reads `.env` and runs [`pkg/envparse`][gh-envparse] over it (handles
   quoted values and trailing `# comments`).
2. Merges parsed entries into the env (existing keys override is set by
   the migration, not the source — last-write-wins on the env key).
3. Writes the encrypted file via the same path as `set`.
4. Appends the source filename to `.gitignore` if not already present.
5. Removes the plaintext source unless `--keep` is set.

## End to end

These stages are exactly what the test
[`TestE2E_InitSetExecRoundtrip`][gh-e2e] verifies on every CI run:
init → set → exec → child sees the secret in `process.env`. If anything
in this lifecycle drifts, that test goes red.

[gh-execenv]: https://github.com/biliboss/envless/blob/main/internal/execenv/execenv.go
[gh-envparse]: https://github.com/biliboss/envless/blob/main/pkg/envparse/envparse.go
[gh-e2e]: https://github.com/biliboss/envless/blob/main/e2e/e2e_test.go
