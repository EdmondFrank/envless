# Docs site expansion — Workstream C report

## What shipped

### Sidebar IA
Rewrote `docs/astro.config.mjs` with the full IA from the plan: Getting
Started, Why envless, Concepts, Security, Operations, Reference,
Releases, Contributing. Wired favicon, OG meta tags, logo, and a
client-side Mermaid bootstrap. MDX integration added so the changelog
pages can import components.

### Content pages (23 new + index update)

| Section | Page | File |
|---|---|---|
| why | Positioning | `src/content/docs/why/positioning.md` |
| why | vs. Vault / 1Password / Infisical / dotenv-vault | `src/content/docs/why/comparison.md` |
| why | When NOT to use | `src/content/docs/why/when-not.md` |
| why | License & governance | `src/content/docs/why/license.md` |
| why | Roadmap | `src/content/docs/why/roadmap.md` |
| concepts | Architecture (Mermaid diagram) | `src/content/docs/concepts/architecture.md` |
| concepts | Lifecycle of a secret | `src/content/docs/concepts/lifecycle.md` |
| security | Threat model | `src/content/docs/security/threat-model.md` |
| security | Cryptography (age + sops) | `src/content/docs/security/cryptography.md` |
| security | Key rotation | `src/content/docs/security/rotation.md` |
| security | Audit & supply chain | `src/content/docs/security/audit.md` |
| operations | Team onboarding | `src/content/docs/operations/onboarding.md` |
| operations | Recipient management | `src/content/docs/operations/recipients.md` |
| operations | Disaster recovery | `src/content/docs/operations/disaster-recovery.md` |
| operations | CI/CD integration | `src/content/docs/operations/cicd.md` |
| reference | CLI commands | `src/content/docs/reference/cli.md` |
| reference | File formats | `src/content/docs/reference/file-formats.md` |
| reference | Exit codes | `src/content/docs/reference/exit-codes.md` |
| reference | Environment variables | `src/content/docs/reference/env-vars.md` |
| reference | Benchmarks (methodology) | `src/content/docs/reference/benchmarks.md` |
| releases | Changelog | `src/content/docs/releases/changelog.mdx` |
| releases | Latest | `src/content/docs/releases/latest.mdx` |
| releases | All versions | `src/content/docs/releases/versions.mdx` |
| contributing | Development setup | `src/content/docs/contributing/setup.md` |
| contributing | Testing | `src/content/docs/contributing/testing.md` |
| contributing | Release process (incl. intended `release.yml`) | `src/content/docs/contributing/releases.md` |
| home | Updated hero w/ "Latest v0.0.1 →" link + CEO/CTO entry cards | `src/content/docs/index.mdx` |

All content was authored by mining the actual source files in the
worktree — no invented behavior. The CLI reference table lines up
verbatim with `internal/ecmd/*.go`; the lifecycle page is a narrative
of `e2e/e2e_test.go`; the cryptography page documents the exact `sops`
invocations from `internal/sopswrap/sopswrap.go`.

### Changelog system

- `src/lib/releases.ts` — build-time loader. Fetches the GitHub
  Releases API (uses `GITHUB_TOKEN` if set), falls back to
  `src/data/releases.json` on empty/error. Reads
  `bench/results/*.json` and joins by `target_commitish` SHA. Returns
  a typed `Release[]` sorted newest-first with `bench` and `benchPrev`
  joined.
- `src/components/BenchDeltaTable.astro` — inline-styled metrics table
  with green/red delta coloring. Renders a "no data yet" empty state
  when bench is missing — verified at build time.
- `src/components/ReleaseCard.astro` — title, ISO date, GH link, commit
  SHA, sanitized markdown body (marked + sanitize-html), Performance
  subsection (delegates to `BenchDeltaTable`), Assets list.
- `src/data/releases.json` — offline-fallback seed for the v0.0.1 tag.
  Used both when offline and when the GH API returns `[]` (current
  state — only one tag exists, no published release).
- `src/content/docs/releases/{changelog,latest,versions}.mdx` — wire it
  together. Newest first. Static, no JS islands required.

### Mermaid

- Skipped `rehype-mermaid` package because it imports
  `mermaid-isomorphic` which pulls in Playwright at module load —
  unworkable in CI without provisioning headless Chrome.
- Replaced with a 30-line local rehype plugin
  (`src/lib/rehype-pre-mermaid.mjs`) that turns ` ```mermaid ` fenced
  blocks into `<pre class="mermaid">` for client-side rendering.
- Mermaid 11.4.1 is loaded at runtime via a CDN ESM import in the
  Starlight `head` config. Theme-aware (reads `data-theme` and picks
  `dark` vs `default`).
- Architecture diagram on `concepts/architecture.md` verified to emit
  `<pre class="mermaid">` in the built HTML.

### Assets

- `docs/public/favicon.svg` — 32×32, terracotta `#d96e3a` "E" glyph on
  `#17110d` background. Matches the existing custom.css accent palette.
- `docs/public/logo.svg` — horizontal sidebar logo (glyph + wordmark).
- `docs/public/og-image.png` — 1200×630, generated via
  `docs/scripts/gen-og.mjs` (sharp). Reproducible — re-run the script
  for design changes. Wordmark + tagline + version chip.
- All three wired into `astro.config.mjs`: favicon → Starlight config,
  OG image → `head` meta tags (twitter:card too), logo → Starlight
  logo config.

### CI

- Updated `.github/workflows/docs.yml`:
  - Passes `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` env to
    `pnpm build` so `releases.ts` is not rate-limited.
  - Added `bench/results/**` to the path filter so a new bench commit
    rebuilds the changelog.
- Did NOT modify `.github/workflows/release.yml` — the intended
  bench-aware release workflow is documented in
  `contributing/releases.md` for Workstream B to implement.

## Build status

`cd docs && pnpm install && pnpm build`:

- Final build: 31 pages built in 4.10s, clean. Pagefind indexed 30 pages,
  2056 words.
- All 27 sidebar entries return HTTP 200 in `pnpm preview` (verified
  with a curl sweep).
- `dist/_astro/*.css|*.js` chunks emit normally; no unresolved
  references reported.

## Verification

- `dist/concepts/architecture/index.html` contains `<pre class="mermaid"`
  — confirmed Mermaid passes through.
- `dist/releases/latest/index.html` renders the v0.0.1 release card
  with the "No benchmark data" empty-state copy — confirms the
  bench-fallback path works.
- `dist/releases/changelog/index.html` contains `id="release-v0.0.1"`
  — confirms anchor links from the versions table work.
- `favicon.svg`, `logo.svg`, `og-image.png` all serve under the
  `/envless/` base path.

## Screenshots

None taken — preview was sanity-checked via HTTP status codes and
content greps. The HTML and assets are deterministic from the source
files; a screenshot of v0.0.1 would not preserve the rendered Mermaid
(client-side) anyway.

## TODOs for Workstream B

1. **Bench harness** — `bench/run.sh` + `bench/compare.sh` need to land
   for `bench/results/<sha>.json` files to exist. Until then, the
   Performance sections of every release card show the empty-state
   message and the "All versions" table shows `—` in the perf columns.
   The release-detection path itself is working end-to-end.
2. **`release.yml` v2** — the workflow proposed in
   `contributing/releases.md` (bench → commit → goreleaser) needs
   implementation. The current `release.yml` only runs goreleaser.
3. **Publish v0.0.1 as a GH Release** — there's a tag (`v0.0.1`) but no
   published release on github.com/biliboss/envless/releases. Until
   that exists, `releases.ts` falls back to
   `docs/src/data/releases.json` (which mirrors the tag). Publishing a
   real release will let the fallback shrink to a single dummy entry
   or be removed entirely.

## TODOs left for follow-up

- `SECURITY.md` at repo root (referenced by `security/audit.md`) — not
  yet present, planned for v0.1.
- Lighthouse score not measured locally; CI Pages deploy is the natural
  place for that.
