#!/usr/bin/env bash
# bench/seed.sh — deterministic seed for latency benchmarks.
#
# Usage: bench/seed.sh <bin> <dir>
#   <bin>  absolute path to an envless binary
#   <dir>  empty directory that will be initialised as an envless repo
#
# Idempotent: if <dir>/.envless/identity.key already exists, only missing keys
# are re-seeded. The seed shape is fixed at 10 keys named BENCH_KEY_01..10
# with values "value-XX" so the harness can be re-run without surprises.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <envless-binary> <seed-dir>" >&2
  exit 64
fi

BIN="$1"
DIR="$2"

if [[ ! -x "$BIN" ]]; then
  echo "seed: binary not executable: $BIN" >&2
  exit 1
fi

mkdir -p "$DIR"

if [[ ! -f "$DIR/.envless/identity.key" ]]; then
  ( cd "$DIR" && "$BIN" init >/dev/null )
fi

# Seed exactly 10 keys. If a key already exists envless overwrites it — that's fine.
for i in 01 02 03 04 05 06 07 08 09 10; do
  printf 'value-%s' "$i" | ( cd "$DIR" && "$BIN" set --env=dev "BENCH_KEY_$i" >/dev/null )
done
