#!/usr/bin/env bash
# bench/compare.sh — print a markdown delta table for two result files.
#
# Usage: bench/compare.sh <sha-a> <sha-b>
#   <sha-a>  baseline (e.g. main HEAD) — looked up at bench/results/<sha-a>.json
#   <sha-b>  candidate (e.g. PR HEAD)  — looked up at bench/results/<sha-b>.json
#
# Output: markdown to stdout, suitable for `gh pr comment --body-file -`.
# Color codes are emitted only when stdout is a TTY; markdown output stays plain.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <sha-a> <sha-b>" >&2
  exit 64
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RESULTS_DIR="$SCRIPT_DIR/results"

A_SHA="$1"
B_SHA="$2"
A_FILE="$RESULTS_DIR/${A_SHA}.json"
B_FILE="$RESULTS_DIR/${B_SHA}.json"

[[ -f "$A_FILE" ]] || { echo "compare: missing $A_FILE" >&2; exit 1; }
[[ -f "$B_FILE" ]] || { echo "compare: missing $B_FILE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "compare: jq required" >&2; exit 1; }

IS_TTY=0
if [[ -t 1 ]]; then IS_TTY=1; fi

red()   { if [[ $IS_TTY -eq 1 ]]; then printf '\033[31m%s\033[0m' "$1"; else printf '%s' "$1"; fi; }
green() { if [[ $IS_TTY -eq 1 ]]; then printf '\033[32m%s\033[0m' "$1"; else printf '%s' "$1"; fi; }
dim()   { if [[ $IS_TTY -eq 1 ]]; then printf '\033[2m%s\033[0m' "$1"; else printf '%s' "$1"; fi; }

# Format a delta. lower_is_better=1 means a negative delta is good (green).
# args: <a> <b> <unit> <lower_is_better>
fmt_delta() {
  local a="$1" b="$2" unit="$3" lower="$4"
  if [[ -z "$a" || "$a" == "null" || -z "$b" || "$b" == "null" ]]; then
    printf '%s' "n/a"; return
  fi
  local pct
  pct=$(awk -v a="$a" -v b="$b" 'BEGIN{ if (a+0==0) {print "inf"; exit}; printf "%.2f", ((b - a) / a) * 100 }')
  local sign="="
  if awk -v b="$b" -v a="$a" 'BEGIN{ exit !(b < a) }'; then sign="-";
  elif awk -v b="$b" -v a="$a" 'BEGIN{ exit !(b > a) }'; then sign="+"; fi

  local label
  if [[ "$sign" == "=" ]]; then
    label="0.00%"
  else
    # strip an awk-emitted leading minus to avoid double sign when sign=="-".
    label="${sign}${pct#-}%"
  fi

  # Determine good/bad colour (only matters for non-zero deltas).
  local improved=0
  if [[ "$sign" == "=" ]]; then
    improved=1
  elif [[ "$lower" -eq 1 ]] && [[ "$sign" == "-" ]]; then
    improved=1
  elif [[ "$lower" -eq 0 ]] && [[ "$sign" == "+" ]]; then
    improved=1
  fi

  if [[ $IS_TTY -eq 1 ]]; then
    if [[ "$improved" -eq 1 ]]; then green "$label"; else red "$label"; fi
  else
    printf '%s' "$label"
  fi
}

# Pretty-print a value with its unit.
fmt_val() {
  local v="$1" unit="$2"
  if [[ -z "$v" || "$v" == "null" ]]; then printf 'n/a'; return; fi
  case "$unit" in
    sec)   awk -v v="$v" 'BEGIN{ printf "%.4f s", v }' ;;
    ms)    awk -v v="$v" 'BEGIN{ printf "%.2f ms", v * 1000 }' ;;
    bytes) awk -v v="$v" 'BEGIN{ if (v >= 1048576) printf "%.2f MiB", v/1048576; else if (v >= 1024) printf "%.2f KiB", v/1024; else printf "%d B", v }' ;;
    *)     printf '%s' "$v" ;;
  esac
}

# Toolchain labels present in both files (intersection, ordered by A).
LABELS_A=$(jq -r '.toolchains[].label' "$A_FILE")
LABELS_B=$(jq -r '.toolchains[].label' "$B_FILE")

# Header.
A_SHORT="$(jq -r '.git_short' "$A_FILE")"
B_SHORT="$(jq -r '.git_short' "$B_FILE")"
A_TS="$(jq -r '.timestamp' "$A_FILE")"
B_TS="$(jq -r '.timestamp' "$B_FILE")"
A_OS="$(jq -r '.platform.os + "/" + .platform.arch' "$A_FILE")"
B_OS="$(jq -r '.platform.os + "/" + .platform.arch' "$B_FILE")"

echo "## envless benchmark comparison"
echo
echo "| | baseline | candidate |"
echo "|--|--|--|"
echo "| sha | \`$A_SHORT\` | \`$B_SHORT\` |"
echo "| run at | $A_TS | $B_TS |"
echo "| platform | $A_OS | $B_OS |"
echo

for label in $LABELS_A; do
  if ! grep -qx "$label" <<< "$LABELS_B"; then
    echo "_(toolchain \`$label\` missing in candidate)_"
    continue
  fi

  A=$(jq --arg l "$label" '.toolchains[] | select(.label==$l)' "$A_FILE")
  B=$(jq --arg l "$label" '.toolchains[] | select(.label==$l)' "$B_FILE")

  echo "### toolchain: \`$label\`"
  echo
  echo "| metric | baseline | candidate | Δ |"
  echo "|---|---:|---:|---:|"

  # Build time.
  a_v=$(jq -r '.build_time_sec.mean' <<<"$A"); b_v=$(jq -r '.build_time_sec.mean' <<<"$B")
  printf "| build time (mean) | %s | %s | %s |\n" "$(fmt_val "$a_v" sec)" "$(fmt_val "$b_v" sec)" "$(fmt_delta "$a_v" "$b_v" sec 1)"

  # Binary size.
  a_v=$(jq -r '.binary_size_bytes' <<<"$A"); b_v=$(jq -r '.binary_size_bytes' <<<"$B")
  printf "| binary size | %s | %s | %s |\n" "$(fmt_val "$a_v" bytes)" "$(fmt_val "$b_v" bytes)" "$(fmt_delta "$a_v" "$b_v" bytes 1)"

  # Cold start.
  a_v=$(jq -r '.cold_start_sec.mean' <<<"$A"); b_v=$(jq -r '.cold_start_sec.mean' <<<"$B")
  printf "| cold start (mean) | %s | %s | %s |\n" "$(fmt_val "$a_v" ms)" "$(fmt_val "$b_v" ms)" "$(fmt_delta "$a_v" "$b_v" ms 1)"

  # List latency.
  a_v=$(jq -r '.list_latency_sec.mean' <<<"$A"); b_v=$(jq -r '.list_latency_sec.mean' <<<"$B")
  printf "| envless list (mean) | %s | %s | %s |\n" "$(fmt_val "$a_v" ms)" "$(fmt_val "$b_v" ms)" "$(fmt_delta "$a_v" "$b_v" ms 1)"

  # Exec latency.
  a_v=$(jq -r '.exec_latency_sec.mean' <<<"$A"); b_v=$(jq -r '.exec_latency_sec.mean' <<<"$B")
  printf "| envless exec (mean) | %s | %s | %s |\n" "$(fmt_val "$a_v" ms)" "$(fmt_val "$b_v" ms)" "$(fmt_delta "$a_v" "$b_v" ms 1)"

  # Peak RSS.
  a_v=$(jq -r '.peak_rss_bytes' <<<"$A"); b_v=$(jq -r '.peak_rss_bytes' <<<"$B")
  printf "| peak RSS | %s | %s | %s |\n" "$(fmt_val "$a_v" bytes)" "$(fmt_val "$b_v" bytes)" "$(fmt_delta "$a_v" "$b_v" bytes 1)"

  # E2E wall-clock.
  a_v=$(jq -r '.e2e_wallclock_sec' <<<"$A"); b_v=$(jq -r '.e2e_wallclock_sec' <<<"$B")
  printf "| e2e wall-clock | %s | %s | %s |\n" "$(fmt_val "$a_v" sec)" "$(fmt_val "$b_v" sec)" "$(fmt_delta "$a_v" "$b_v" sec 1)"

  echo
done

echo "_Lower is better for every metric. \`-X%\` = improvement, \`+X%\` = regression._"
