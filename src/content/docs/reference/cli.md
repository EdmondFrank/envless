---
title: CLI commands
description: Every subcommand, every flag, with the exact source-of-truth behaviour.
---

`envless` has six subcommands plus a root version flag. The surface is
deliberately flat — no nested groups, no hidden commands.

```
envless --version

envless init
envless set    KEY                        [--env=ENV]
envless get    KEY                        [--env=ENV] --confirm
envless list                              [--env=ENV]
envless exec                              [--env=ENV] -- CMD [ARGS...]
envless migrate FILE                      [--env=ENV] [--keep]
```

Default for `--env` is always `dev`.

## `envless --version`

Prints the version baked into the binary at build time
(`-ldflags "-X main.version=…"`). Exits 0.

```
$ envless --version
envless version v0.0.1
```

## `envless init`

Creates the `.envless/` directory and a local age identity. Idempotent
— re-running with an existing `identity.key` is a no-op.

- Creates `.envless/` with mode `0700`.
- Runs `age-keygen -o .envless/identity.key`.
- Chmods the key file to `0600`.
- Writes the new pubkey as the sole line of `.envless/recipients`.

Output:

```
INIT  identity=.envless/identity.key pubkey=age1...
```

Takes no positional args. Fails if `age-keygen` is not on `PATH`.

## `envless set KEY`

Reads the value from **stdin** (the trailing `\n` is stripped) and
writes it to the encrypted store for `--env=ENV`.

| Flag | Default | Description |
|---|---|---|
| `--env` | `dev` | Target environment name. Becomes the prefix of `secrets/<env>.env.enc`. |

Output:

```
SET   env=dev key=OPENAI_API_KEY
```

The value never appears on stdout or stderr. Read-modify-write of the
existing env file under the hood.

## `envless get KEY`

Prints the plaintext value. Requires `--confirm` — printing a secret
must be intentional.

| Flag | Default | Description |
|---|---|---|
| `--env` | `dev` | Target environment. |
| `--confirm` | `false` | Required. Without it, the command errors out with `printing a secret requires --confirm` (exit 1). |

Output (with `--confirm`):

```
sk-test-xyz
```

If the key is missing for the given env, exit 1 with:
`key "OPENAI_API_KEY" not found in env "dev"`.

For programmatic reads, prefer `envless exec` so the plaintext does not
hit a shell.

## `envless list`

Prints all keys for the env, one per line, sorted alphabetically.
Values are never printed.

| Flag | Default | Description |
|---|---|---|
| `--env` | `dev` | Target environment. |

Output:

```
A
B
OPENAI_API_KEY
URL
```

Empty output (exit 0) means no env file or no keys yet.

## `envless exec [--env=ENV] -- CMD [ARGS...]`

The star command. Decrypts the env file, merges its KV map into
`os.Environ()` (env-file keys override the parent), sorts the merged
list, spawns `CMD` with that environment, and proxies stdin/stdout/
stderr.

| Flag | Default | Description |
|---|---|---|
| `--env` | `dev` | Target environment. |

The `--` separator is conventional but not strictly required by cobra;
include it to avoid ambiguity with envless's own flags.

Exit code: child's exit code on a clean run. See
[Exit codes](../exit-codes/) for failure modes.

Example:

```bash
envless exec -- node server.js
envless exec --env=prod -- npm run deploy
envless exec -- /bin/sh -c 'echo $OPENAI_API_KEY'
```

## `envless migrate FILE`

One-shot migration from a plaintext `.env`-style file to an encrypted
env. Idempotently amends `.gitignore`.

| Flag | Default | Description |
|---|---|---|
| `--env` | `dev` | Target environment. |
| `--keep` | `false` | If set, the plaintext source file is **not** removed after migration. |

Behaviour:

1. Reads `FILE`, parses via [`pkg/envparse`][gh-envparse] (handles
   `KEY=VALUE`, quoted values, trailing `# comments`).
2. Merges into the existing env file (last-write-wins on duplicate
   keys; migration overrides).
3. Encrypts via `sops`.
4. Appends `basename(FILE)` to `.gitignore` (idempotent; skipped if
   the pattern is already present).
5. Removes `FILE` unless `--keep`.

Output (without `--keep`):

```
MIGRATE  src=.env env=dev keys=3
REMOVE   .env
```

## Implementation pointers

| Subcommand | Source |
|---|---|
| `init` | [`internal/ecmd/init.go`][gh-init] |
| `set` | [`internal/ecmd/set.go`][gh-set] |
| `get` | [`internal/ecmd/get.go`][gh-get] |
| `list` | [`internal/ecmd/list.go`][gh-list] |
| `exec` | [`internal/ecmd/exec.go`][gh-exec] |
| `migrate` | [`internal/ecmd/migrate.go`][gh-migrate] |
| root wiring | [`internal/ecmd/root.go`][gh-root] |

[gh-envparse]: https://github.com/biliboss/envless/blob/main/pkg/envparse/envparse.go
[gh-init]: https://github.com/biliboss/envless/blob/main/internal/ecmd/init.go
[gh-set]: https://github.com/biliboss/envless/blob/main/internal/ecmd/set.go
[gh-get]: https://github.com/biliboss/envless/blob/main/internal/ecmd/get.go
[gh-list]: https://github.com/biliboss/envless/blob/main/internal/ecmd/list.go
[gh-exec]: https://github.com/biliboss/envless/blob/main/internal/ecmd/exec.go
[gh-migrate]: https://github.com/biliboss/envless/blob/main/internal/ecmd/migrate.go
[gh-root]: https://github.com/biliboss/envless/blob/main/internal/ecmd/root.go
