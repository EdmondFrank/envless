---
title: Install
description: How to get envless on your machine.
---

`envless` is a Go binary that shells out to `age` and `sops`. You need all three.

## Requirements

- [age](https://github.com/FiloSottile/age) >= 1.2
- [sops](https://github.com/getsops/sops) >= 3.9
- macOS or Linux (Windows untested)

## macOS (Homebrew)

```bash
brew install age sops
```

`envless` itself: clone + build until binaries are published.

```bash
git clone https://github.com/biliboss/envless.git
cd envless
make build
sudo install -m 0755 bin/envless /usr/local/bin/envless
envless --version
```

## Linux

Install `age` and `sops` from your package manager or upstream releases:

```bash
# Debian / Ubuntu
sudo apt-get install age
curl -sSfL -o /tmp/sops https://github.com/getsops/sops/releases/latest/download/sops-v3.9.4.linux.amd64
sudo install -m 0755 /tmp/sops /usr/local/bin/sops

# Arch
sudo pacman -S age sops
```

Build envless from source (Go 1.26+):

```bash
git clone https://github.com/biliboss/envless.git
cd envless
make build
sudo install -m 0755 bin/envless /usr/local/bin/envless
```

## Verify

```bash
envless --version       # → v0.0.1
age --version           # → v1.3.x
sops --version          # → 3.x
```

If all three print, you're ready.

## What's next

→ [Quickstart](../quickstart/) — encrypt your first secret in 60 seconds.
