---
title: CI/CD integration patterns
description: Wiring envless into GitHub Actions, GitLab CI, and arbitrary pipelines.
---

`envless` shines in CI: the pipeline holds one age secret key, and
every encrypted file in the repo is suddenly readable. No
per-environment env-var maze, no drift between local `.env` and
`gh secrets`.

The integration shape is the same on every CI:

1. Generate a **CI bot identity** (an age keypair).
2. Add its pubkey to `.envless/recipients` and re-encrypt.
3. Store the **secret key** as a single CI-provider secret
   (`AGE_IDENTITY` or similar).
4. In the workflow, write that secret to a temp file and point
   `envless` at it.

## GitHub Actions

```yaml
# .github/workflows/deploy.yml
name: deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: install age + sops
        run: |
          sudo apt-get update
          sudo apt-get install -y age
          curl -sSfL -o /tmp/sops \
            https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
          sudo install -m 0755 /tmp/sops /usr/local/bin/sops

      - name: install envless
        run: |
          curl -sSfL https://github.com/biliboss/envless/releases/latest/download/envless_linux_amd64.tar.gz \
            | sudo tar -xz -C /usr/local/bin envless

      - name: provision identity from secret
        run: |
          mkdir -p .envless
          umask 077
          printf '%s' "${{ secrets.AGE_IDENTITY }}" > .envless/identity.key

      - name: deploy with secrets injected
        run: envless exec --env=prod -- npm run deploy
```

The `envless exec` line is the only place secrets enter the build —
they live inside the deploy step's child process only.

## GitLab CI

```yaml
deploy:
  image: alpine:3.20
  before_script:
    - apk add --no-cache age curl
    - curl -sSfL -o /tmp/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
    - install -m 0755 /tmp/sops /usr/local/bin/sops
    - curl -sSfL https://github.com/biliboss/envless/releases/latest/download/envless_linux_amd64.tar.gz | tar -xz -C /usr/local/bin envless
    - mkdir -p .envless && umask 077 && printf '%s' "$AGE_IDENTITY" > .envless/identity.key
  script:
    - envless exec --env=prod -- ./deploy.sh
  variables:
    AGE_IDENTITY: $AGE_IDENTITY     # masked CI/CD variable
```

## Arbitrary Docker-based pipeline

Same shape, in a Dockerfile:

```dockerfile
FROM golang:1.26-alpine AS build
RUN apk add --no-cache age curl \
    && curl -sSfL -o /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64 \
    && chmod +x /usr/local/bin/sops
RUN curl -sSfL https://github.com/biliboss/envless/releases/latest/download/envless_linux_amd64.tar.gz | tar -xz -C /usr/local/bin envless

WORKDIR /src
COPY . .
RUN --mount=type=secret,id=age_identity \
    mkdir -p .envless \
    && cp /run/secrets/age_identity .envless/identity.key \
    && chmod 0600 .envless/identity.key \
    && envless exec --env=prod -- make build
```

Build with `docker build --secret id=age_identity,src=$HOME/.config/envless/ci.key .`.

## Hardening tips

- **One bot identity per pipeline** — separate keys for `staging` and
  `prod`. Lets you revoke independently.
- **No `envless get` in CI.** Use `envless exec` so plaintext only
  exists in the child process's env, never in CI logs.
- **`umask 077` before writing the identity file** — defaults vary
  across runners; this is one line of insurance.
- **Mask the `AGE_IDENTITY` secret.** Every major CI provider supports
  this; it scrubs accidental echo from logs.
- **Pin sops + age versions** — let the workflow break on upgrade
  rather than silently picking up a new release.

## What v0.1 will simplify

- `envless-ci-github` plugin — emits the workflow snippet above for you.
- `envless ci provision` — single command that creates a bot identity,
  prints the pubkey, and outputs the secret value to paste into
  `gh secret set`.

Until then, the snippets above are the supported pattern.
