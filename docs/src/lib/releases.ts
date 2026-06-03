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
const DOCS_ROOT = resolve(__dirname, "..", "..");
const REPO_ROOT = resolve(DOCS_ROOT, "..");
const FALLBACK = join(DOCS_ROOT, "src", "data", "releases.json");
const BENCH_DIR = join(REPO_ROOT, "bench", "results");
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

function loadBenchResults(): Map<string, BenchRecord> {
  const out = new Map<string, BenchRecord>();
  if (!existsSync(BENCH_DIR)) return out;
  let files: string[] = [];
  try {
    files = readdirSync(BENCH_DIR).filter((f) => f.endsWith(".json"));
  } catch {
    return out;
  }
  for (const f of files) {
    try {
      const sha = f.replace(/\.json$/, "");
      const data = JSON.parse(
        readFileSync(join(BENCH_DIR, f), "utf8"),
      ) as BenchRecord;
      out.set(sha, data);
    } catch (err) {
      console.warn(`[releases] failed to parse ${f}:`, err);
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
