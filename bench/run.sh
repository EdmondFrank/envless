#!/usr/bin/env bash
# bench/run.sh — DevOps metric driver for envless.
#
# Builds the Go binary (and, if zig/build.zig exists, the Zig binary), then
# measures: build time, binary size, cold start, `envless list` latency,
# `envless exec` latency, peak RSS, and e2e wall-clock. All metrics for all
# binaries in the run are emitted to a single JSON file under bench/results/
# keyed by the current git SHA.
#
# Exits non-zero on any benchmark failure so CI fails loudly.
#
# Prereqs: hyperfine, sops, age, go (optional zig, jq).

set -euo pipefail

# --- locate repo root and bench dir ------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

cd "$REPO_ROOT"

# --- preflight --------------------------------------------------------------------
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "bench: missing required tool: $1" >&2; exit 1; }
}
need hyperfine
need go
need sops
need age

GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GO_VERSION="$(go version | awk '{print $3}')"
HYPERFINE_VERSION="$(hyperfine --version | awk '{print $2}')"

ZIG_VERSION="null"
HAS_ZIG=0
if [[ -f "$REPO_ROOT/zig/build.zig" ]] && command -v zig >/dev/null 2>&1; then
  HAS_ZIG=1
  ZIG_VERSION="\"$(zig version)\""
fi

# --- per-toolchain bench runner ---------------------------------------------------
TMP="$(mktemp -d -t envless-bench-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# stat byte-size cross-platform.
binsize() {
  local f="$1"
  if [[ "$OS_NAME" == "Darwin" ]]; then
    stat -f '%z' "$f"
  else
    stat -c '%s' "$f"
  fi
}

# peak RSS in bytes, cross-platform. Echoes -1 if parsing fails.
peak_rss_bytes() {
  local cmd_out
  local rss
  if [[ "$OS_NAME" == "Darwin" ]]; then
    # /usr/bin/time -l reports max RSS in bytes on macOS.
    cmd_out="$(/usr/bin/time -l "$@" 2>&1 1>/dev/null || true)"
    rss="$(printf '%s\n' "$cmd_out" | awk '/maximum resident set size/ {print $1; exit}')"
  else
    # /usr/bin/time -v reports max RSS in kilobytes on GNU/Linux.
    cmd_out="$(/usr/bin/time -v "$@" 2>&1 1>/dev/null || true)"
    local kb
    kb="$(printf '%s\n' "$cmd_out" | awk -F': ' '/Maximum resident set size/ {print $2; exit}')"
    if [[ -n "${kb:-}" ]]; then
      rss=$(( kb * 1024 ))
    fi
  fi
  if [[ -z "${rss:-}" ]]; then
    echo "-1"
  else
    echo "$rss"
  fi
}

# Read mean+stddev from a hyperfine JSON export.
hf_mean() { jq -r '.results[0].mean' "$1"; }
hf_stddev() { jq -r '.results[0].stddev' "$1"; }
hf_min() { jq -r '.results[0].min' "$1"; }
hf_max() { jq -r '.results[0].max' "$1"; }

need jq

# Runs every metric for one toolchain. Echoes a JSON object on stdout.
bench_toolchain() {
  local label="$1"        # "go" | "zig"
  local bin_path="$2"     # absolute path to a built envless binary
  local build_cmd="$3"    # full shell command that produces bin_path

  echo "==> [$label] bench start (bin=$bin_path)" >&2

  # 1. Build time.
  # NOTE: hyperfine and the fallback rebuild are both wrapped in `bash -c`
  # subshells so a `cd zig && …` style build_cmd cannot leak its cwd into
  # the rest of the bench (which would break e2e step that expects
  # repo-root cwd).
  local build_json="$TMP/${label}-build.json"
  echo "    [$label] build time" >&2
  if ! hyperfine --warmup 3 --runs 10 \
    --export-json "$build_json" \
    --prepare "rm -f '$bin_path'" \
    "bash -c \"$build_cmd\"" >&2; then
    echo "    [$label] build FAILED — skipping remaining metrics for $label" >&2
    echo "null"
    return 0
  fi

  # Verify the artifact exists for the rest of the metrics.
  if [[ ! -x "$bin_path" ]]; then
    # rebuild once if the warmup loop happened to clean up the artifact.
    ( eval "$build_cmd" ) >&2 || true
  fi
  if [[ ! -x "$bin_path" ]]; then
    echo "    [$label] artifact missing after build — skipping" >&2
    echo "null"
    return 0
  fi

  # 2. Binary size.
  local size_bytes
  size_bytes="$(binsize "$bin_path")"
  echo "    [$label] size=${size_bytes}B" >&2

  # 3. Cold start.
  local cold_json="$TMP/${label}-cold.json"
  echo "    [$label] cold start" >&2
  hyperfine --warmup 3 --runs 50 \
    --export-json "$cold_json" \
    "$bin_path --version" >&2

  # 4. Seed repo for latency benchmarks.
  local seed_dir="$TMP/seed-$label"
  rm -rf "$seed_dir"
  mkdir -p "$seed_dir"
  echo "    [$label] seeding repo" >&2
  "$SCRIPT_DIR/seed.sh" "$bin_path" "$seed_dir" >&2

  # 5. `envless list` latency.
  local list_json="$TMP/${label}-list.json"
  echo "    [$label] list latency" >&2
  ( cd "$seed_dir" && hyperfine --warmup 3 --runs 30 \
    --export-json "$list_json" \
    "$bin_path list --env=dev" ) >&2

  # 6. `envless exec` latency.
  local exec_json="$TMP/${label}-exec.json"
  echo "    [$label] exec latency" >&2
  ( cd "$seed_dir" && hyperfine --warmup 3 --runs 30 \
    --export-json "$exec_json" \
    "$bin_path exec --env=dev -- true" ) >&2

  # 7. Peak RSS — measure `envless list` once under /usr/bin/time.
  local rss
  echo "    [$label] peak RSS" >&2
  rss="$(cd "$seed_dir" && peak_rss_bytes "$bin_path" list --env=dev)"

  # 8. E2E wall-clock.
  echo "    [$label] e2e wall-clock" >&2
  local e2e_start e2e_end e2e_dur e2e_exit=0
  e2e_start=$(date +%s.%N 2>/dev/null || date +%s)
  if ! BIN="$bin_path" go test -count=1 ./e2e/... >"$TMP/${label}-e2e.log" 2>&1; then
    e2e_exit=$?
    echo "    [$label] e2e FAILED (exit=$e2e_exit) — see $TMP/${label}-e2e.log" >&2
    tail -40 "$TMP/${label}-e2e.log" >&2 || true
    exit 1
  fi
  e2e_end=$(date +%s.%N 2>/dev/null || date +%s)
  e2e_dur=$(awk -v a="$e2e_start" -v b="$e2e_end" 'BEGIN{printf "%.3f", b - a}')

  # Emit JSON for this toolchain.
  jq -n \
    --arg label "$label" \
    --arg bin "$bin_path" \
    --argjson size "$size_bytes" \
    --argjson rss "$rss" \
    --argjson e2e_sec "$e2e_dur" \
    --slurpfile build "$build_json" \
    --slurpfile cold "$cold_json" \
    --slurpfile list "$list_json" \
    --slurpfile exec "$exec_json" \
    '{
       label: $label,
       binary: $bin,
       binary_size_bytes: $size,
       build_time_sec: { mean: $build[0].results[0].mean, stddev: $build[0].results[0].stddev, min: $build[0].results[0].min, max: $build[0].results[0].max, runs: ($build[0].results[0].times|length) },
       cold_start_sec:   { mean: $cold[0].results[0].mean,  stddev: $cold[0].results[0].stddev,  min: $cold[0].results[0].min,  max: $cold[0].results[0].max,  runs: ($cold[0].results[0].times|length) },
       list_latency_sec: { mean: $list[0].results[0].mean,  stddev: $list[0].results[0].stddev,  min: $list[0].results[0].min,  max: $list[0].results[0].max,  runs: ($list[0].results[0].times|length) },
       exec_latency_sec: { mean: $exec[0].results[0].mean,  stddev: $exec[0].results[0].stddev,  min: $exec[0].results[0].min,  max: $exec[0].results[0].max,  runs: ($exec[0].results[0].times|length) },
       peak_rss_bytes:   $rss,
       e2e_wallclock_sec: $e2e_sec
     }'
}

# --- run benchmarks per toolchain --------------------------------------------------
TOOLCHAINS_JSON="$TMP/toolchains.json"
echo "[]" > "$TOOLCHAINS_JSON"

run_one() {
  local label="$1" bin="$2" build_cmd="$3"
  local out
  out="$(bench_toolchain "$label" "$bin" "$build_cmd")"
  # Skip if the toolchain build failed (bench_toolchain emitted "null").
  if [[ "$out" == "null" ]]; then
    echo "==> [$label] omitted from results" >&2
    return 0
  fi
  jq --argjson new "$out" '. + [$new]' "$TOOLCHAINS_JSON" > "$TOOLCHAINS_JSON.tmp"
  mv "$TOOLCHAINS_JSON.tmp" "$TOOLCHAINS_JSON"
}

# Go binary.
GO_BIN="$REPO_ROOT/bin/envless"
run_one "go" "$GO_BIN" "make build"

# Zig binary, if present.
if [[ "$HAS_ZIG" -eq 1 ]]; then
  # Zig's build root is the zig/ subdir, so the install prefix is zig/zig-out.
  ZIG_BIN="$REPO_ROOT/zig/zig-out/bin/envless"
  run_one "zig" "$ZIG_BIN" "cd zig && zig build -Doptimize=ReleaseSmall"
fi

# --- assemble final result file ---------------------------------------------------
OUT_FILE="$RESULTS_DIR/${GIT_SHA}.json"
jq -n \
  --arg sha "$GIT_SHA" \
  --arg short "$GIT_SHORT" \
  --arg ts "$TIMESTAMP" \
  --arg os "$OS_NAME" \
  --arg arch "$ARCH_NAME" \
  --arg go_v "$GO_VERSION" \
  --argjson zig_v "$ZIG_VERSION" \
  --arg hf_v "$HYPERFINE_VERSION" \
  --slurpfile toolchains "$TOOLCHAINS_JSON" \
  '{
     schema_version: 1,
     git_sha: $sha,
     git_short: $short,
     timestamp: $ts,
     platform: { os: $os, arch: $arch },
     toolchain_versions: { go: $go_v, zig: $zig_v, hyperfine: $hf_v },
     toolchains: $toolchains[0]
   }' > "$OUT_FILE"

echo "==> wrote $OUT_FILE"

# --- append summary line to history.jsonl ------------------------------------------
# bench/history.jsonl is the agent-friendly summary index: one line per run,
# flat metrics keyed by `<toolchain>.<metric>`, consumed by the docs changelog.
# The verbose per-SHA JSON above stays as the forensic source of truth — we
# derive the summary FROM that file (not from the $TMP staging dir) so the
# transform is debuggable and doesn't depend on tmpfiles that the EXIT trap
# may have already touched.
HISTORY_FILE="$SCRIPT_DIR/history.jsonl"
jq -c '
  {
    schema_version: 1,
    sha: .git_sha,
    short: .git_short,
    timestamp: .timestamp,
    platform: .platform,
    toolchain_versions: .toolchain_versions,
    metrics: (
      (.toolchains // [])
      | map(
          . as $t
          | [
              {key: ($t.label + ".build_time_sec"),    value: $t.build_time_sec.mean},
              {key: ($t.label + ".cold_start_sec"),    value: $t.cold_start_sec.mean},
              {key: ($t.label + ".list_latency_sec"),  value: $t.list_latency_sec.mean},
              {key: ($t.label + ".exec_latency_sec"),  value: $t.exec_latency_sec.mean},
              {key: ($t.label + ".binary_size_bytes"), value: $t.binary_size_bytes},
              {key: ($t.label + ".peak_rss_bytes"),    value: $t.peak_rss_bytes},
              {key: ($t.label + ".e2e_wallclock_sec"), value: $t.e2e_wallclock_sec}
            ]
        )
      | (if length == 0 then [] else add end)
      | from_entries
    )
  }
' "$OUT_FILE" >> "$HISTORY_FILE"

echo "==> appended summary to $HISTORY_FILE"
