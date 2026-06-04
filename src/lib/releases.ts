// Build-time loader for releases + benchmark joins.
//
// Strategy:
// 1. Try the GitHub Releases API. Use GITHUB_TOKEN if available (CI).
//    Fall back to the bundled `src/data/releases.json` snapshot on any
//    failure (network down, rate-limited, empty payload, etc).
// 2. Read every `bench/results/*.json` (sibling repo path), join on
//    the release's `target_commitish` SHA.
// 3. Return a typed, sorted-newest-first `Release[]`.

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
// After the agent-tts pattern refactor, Astro lives at the repo root.
// `src/lib/releases.ts` sits two levels under the repo root, so the Astro
// root and the repo root are the same directory.
const REPO_ROOT = resolve(__dirname, "..", "..");
const FALLBACK = join(REPO_ROOT, "src", "data", "releases.json");
const BENCH_DIR = join(REPO_ROOT, "bench", "results");
const BENCH_HISTORY = join(REPO_ROOT, "bench", "history.jsonl");
const REPO = "biliboss/envless";

export interface ReleaseAsset {
  name: string;
  browser_download_url: string;
  size: number;
}

export interface GithubRelease {
  tag_name: string;
  name: string | null;
  html_url: string;
  published_at: string;
  target_commitish: string;
  body: string;
  assets: ReleaseAsset[];
}

export interface BenchMetric {
  value: number;
  unit: string;
  // Optional: lower-is-better defaults to true.
  lowerIsBetter?: boolean;
}

export type BenchRecord = Record<string, BenchMetric>;

export interface Release {
  tag: string;
  name: string;
  date: string;
  url: string;
  sha: string;
  body: string;
  assets: ReleaseAsset[];
  bench: BenchRecord | null;
  benchPrev: BenchRecord | null;
}

async function fetchReleases(): Promise<GithubRelease[] | null> {
  try {
    const headers: Record<string, string> = {
      Accept: "application/vnd.github+json",
      "User-Agent": "envless-docs-build",
      "X-GitHub-Api-Version": "2022-11-28",
    };
    if (process.env.GITHUB_TOKEN) {
      headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
    }
    const res = await fetch(
      `https://api.github.com/repos/${REPO}/releases?per_page=100`,
      { headers },
    );
    if (!res.ok) {
      console.warn(
        `[releases] GitHub API returned ${res.status}; using fallback`,
      );
      return null;
    }
    const data = (await res.json()) as GithubRelease[];
    if (!Array.isArray(data) || data.length === 0) return null;
    return data;
  } catch (err) {
    console.warn("[releases] fetch failed; using fallback:", err);
    return null;
  }
}

function loadFallback(): GithubRelease[] {
  if (!existsSync(FALLBACK)) return [];
  try {
    const data = JSON.parse(readFileSync(FALLBACK, "utf8")) as GithubRelease[];
    return Array.isArray(data) ? data : [];
  } catch {
    return [];
  }
}

interface HistoryEntry {
  schema_version: number;
  sha: string;
  short?: string;
  timestamp: string;
  metrics: Record<string, number>;
}

function unitFor(key: string): string {
  if (key.endsWith("_bytes")) return "B";
  if (key.endsWith("_sec")) return "s";
  return "";
}

function toBenchRecord(metrics: Record<string, number>): BenchRecord {
  const out: BenchRecord = {};
  for (const [k, v] of Object.entries(metrics)) {
    if (typeof v !== "number") continue;
    out[k] = { value: v, unit: unitFor(k), lowerIsBetter: true };
  }
  return out;
}

function loadBenchResults(): Map<string, BenchRecord> {
  const out = new Map<string, BenchRecord>();

  // Primary source: bench/history.jsonl (append-only summary index).
  if (existsSync(BENCH_HISTORY)) {
    try {
      const lines = readFileSync(BENCH_HISTORY, "utf8").split("\n");
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const entry = JSON.parse(trimmed) as HistoryEntry;
          if (!entry.sha || !entry.metrics) continue;
          out.set(entry.sha, toBenchRecord(entry.metrics));
        } catch (err) {
          console.warn(`[releases] failed to parse history line:`, err);
        }
      }
    } catch (err) {
      console.warn(`[releases] failed to read history.jsonl:`, err);
    }
  }

  // No history.jsonl yet — fall back to per-SHA verbose files for bootstrap.
  if (out.size === 0 && existsSync(BENCH_DIR)) {
    let files: string[] = [];
    try {
      files = readdirSync(BENCH_DIR).filter((f) => f.endsWith(".json"));
    } catch {
      return out;
    }
    for (const f of files) {
      try {
        const sha = f.replace(/\.json$/, "");
        const data = JSON.parse(readFileSync(join(BENCH_DIR, f), "utf8")) as {
          toolchains?: Array<Record<string, unknown>>;
        };
        const metrics: Record<string, number> = {};
        for (const t of data.toolchains ?? []) {
          const label = String(t.label ?? "");
          if (!label) continue;
          const pick = (k: string, src: unknown): void => {
            if (typeof src === "number") metrics[`${label}.${k}`] = src;
            else if (
              src &&
              typeof src === "object" &&
              typeof (src as { mean?: number }).mean === "number"
            ) {
              metrics[`${label}.${k}`] = (src as { mean: number }).mean;
            }
          };
          pick("build_time_sec", t.build_time_sec);
          pick("cold_start_sec", t.cold_start_sec);
          pick("list_latency_sec", t.list_latency_sec);
          pick("exec_latency_sec", t.exec_latency_sec);
          pick("binary_size_bytes", t.binary_size_bytes);
          pick("peak_rss_bytes", t.peak_rss_bytes);
          pick("e2e_wallclock_sec", t.e2e_wallclock_sec);
        }
        out.set(sha, toBenchRecord(metrics));
      } catch (err) {
        console.warn(`[releases] failed to parse ${f}:`, err);
      }
    }
  }

  return out;
}

export async function getReleases(): Promise<Release[]> {
  const raw = (await fetchReleases()) ?? loadFallback();
  const bench = loadBenchResults();

  const sorted = [...raw].sort(
    (a, b) =>
      new Date(b.published_at).getTime() - new Date(a.published_at).getTime(),
  );

  return sorted.map((r, idx) => {
    const sha = r.target_commitish ?? "";
    const benchForRelease = sha
      ? bench.get(sha) ?? bench.get(sha.slice(0, 12)) ?? null
      : null;
    // previous = next entry in sorted-newest-first list
    const prev = sorted[idx + 1];
    const prevSha = prev?.target_commitish ?? "";
    const benchPrev = prevSha
      ? bench.get(prevSha) ?? bench.get(prevSha.slice(0, 12)) ?? null
      : null;

    return {
      tag: r.tag_name,
      name: r.name?.trim() || r.tag_name,
      date: r.published_at,
      url: r.html_url,
      sha,
      body: r.body ?? "",
      assets: r.assets ?? [],
      bench: benchForRelease,
      benchPrev,
    };
  });
}

export function getLatestRelease(releases: Release[]): Release | null {
  return releases[0] ?? null;
}
