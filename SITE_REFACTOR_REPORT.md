# envless Starlight site refactor — agent-tts pattern

The docs site was previously a Starlight project inside `docs/` with 27+
nested pages across 8 sidebar groups. It has been refactored to follow
the [agent-tts](https://github.com/biliboss/agent-tts) pattern:
Astro lives at the repo root, sidebar is a flat list of ~10 top-level
entries, one Markdown/MDX per entry.

## 1. Layout moves

| Before (`docs/...`) | After (repo root) |
|---|---|
| `docs/astro.config.mjs` | `astro.config.mjs` |
| `docs/package.json` | `package.json` |
| `docs/pnpm-lock.yaml` | `pnpm-lock.yaml` |
| `docs/src/` | `src/` |
| `docs/public/` | `public/` |
| `docs/scripts/` | `scripts/` |
| `docs/.gitignore` | merged into root `.gitignore` (`docs/dist/` → `dist/`, `docs/.astro/` → `.astro/`) |
| `docs/SITE_REPORT.md` | dropped |

`docs/` directory removed entirely. Astro src tree and Zig src tree
coexist via separate top-level dirs:

```
<repo>/
├── astro.config.mjs       # Astro root = repo root
├── package.json
├── src/                   # Astro reads src/content/, src/lib/, src/components/, src/styles/
│   ├── content/docs/
│   ├── components/
│   ├── lib/
│   ├── data/
│   └── styles/
├── public/
├── scripts/
├── zig/                   # Zig sources, untouched
│   └── src/               # ← reads only what build.zig points at, no collision
├── internal/ pkg/ cmd/    # Go sources, untouched
└── bench/                 # benchmark harness + history.jsonl
```

`src/lib/releases.ts` was patched: it now resolves `REPO_ROOT` as
`resolve(__dirname, "..", "..")` (Astro root = repo root, two levels up
from `src/lib/`). `BENCH_HISTORY`, `BENCH_DIR`, `FALLBACK` all resolve
correctly to the same paths as before.

## 2. Page consolidation map

27 nested pages collapsed into 10 flat top-level documents. Every code
block, Mermaid diagram, CLI flag table, and exit-code matrix from the
old pages is preserved verbatim — only the structure changes. Cross-page
links rewritten to anchor-on-page form (`/envless/security/#cryptography-age--sops`).

| New page | Old sources consolidated into it |
|---|---|
| `src/content/docs/index.mdx` | rewritten — new splash hero, comparison teaser, four entry cards |
| `src/content/docs/quickstart.mdx` | `getting-started/install.md` + `getting-started/quickstart.md` |
| `src/content/docs/architecture.mdx` | `concepts/architecture.md` + `concepts/lifecycle.md` + `concepts/the-dot-env-problem.md` |
| `src/content/docs/security.mdx` | `security/threat-model.md` + `security/cryptography.md` + `security/rotation.md` + `security/audit.md` |
| `src/content/docs/operations.mdx` | `operations/onboarding.md` + `operations/recipients.md` + `operations/disaster-recovery.md` + `operations/cicd.md` |
| `src/content/docs/cli.mdx` | `reference/cli.md` + `reference/exit-codes.md` + `reference/env-vars.md` + `reference/file-formats.md` |
| `src/content/docs/benchmarks.mdx` | `reference/benchmarks.md` (renamed, links updated) |
| `src/content/docs/why.mdx` | `why/positioning.md` + `why/comparison.md` + `why/when-not.md` + `why/license.md` + `why/roadmap.md` |
| `src/content/docs/changelog.mdx` | `releases/changelog.mdx` + `releases/latest.mdx` + `releases/versions.mdx` |
| `src/content/docs/contributing.mdx` | `contributing/setup.md` + `contributing/testing.md` + `contributing/releases.md` |

`git mv` was used to rename the largest source of each merge group so
blame stays clean on the bulk content; the smaller siblings were `git
rm`-ed after their material was hand-merged into the canonical doc.

## 3. Sidebar before / after

**Before** — 8 nested groups, 27+ leaves:

```
Getting Started
  - Install
  - Quickstart
Why envless
  - Positioning
  - Comparison
  - When NOT to use
  - License & governance
  - Roadmap
Concepts
  - The .env problem
  - Architecture
  - Lifecycle of a secret
Security
  - Threat model
  - Cryptography (age + sops)
  - Key rotation
  - Audit & supply chain
Operations
  - Team onboarding
  - Recipient management
  - Disaster recovery
  - CI/CD integration
Reference
  - CLI commands
  - File formats
  - Exit codes
  - Environment variables
  - Benchmarks
Releases
  - Latest
  - Changelog
  - All versions
Contributing
  - Development setup
  - Testing
  - Release process
```

**After** — 10 flat entries:

```js
sidebar: [
  { label: 'Overview',     link: '/' },
  { label: 'Quickstart',   link: '/quickstart/' },
  { label: 'Architecture', link: '/architecture/' },
  { label: 'Security',     link: '/security/' },
  { label: 'CLI reference',link: '/cli/' },
  { label: 'Operations',   link: '/operations/' },
  { label: 'Benchmarks',   link: '/benchmarks/' },
  { label: 'Why envless',  link: '/why/' },
  { label: 'Changelog',    link: '/changelog/' },
  { label: 'Contributing', link: '/contributing/' },
]
```

## 4. astro.config.mjs delta

Adopts the agent-tts shape:

- `SITE` + `BASE` overrideable via env vars
- `trailingSlash: 'always'`
- `editLink.baseUrl: 'https://github.com/biliboss/envless/edit/main/'`
- Mermaid wiring (inline init script + `rehype-pre-mermaid` plugin) preserved
- og:image + twitter:card meta tags preserved (`BASE`-prefixed so they work under `/envless`)
- `customCss: ['./src/styles/custom.css']` preserved
- Logo: `./public/logo.svg` (PNG/SVG, agent-tts uses PNG; envless retains its SVG)

## 5. Build status

Run from repo root:

```
$ pnpm install        # 535 packages resolved, all from cache
$ pnpm build
```

Result:

- **11 page(s) built in 15.88s** (10 sidebar pages + the auto-generated 404)
- **Zero Astro warnings, zero errors**
  (the `[DEP0190]` notice is a Node-internal child-process deprecation, not from this codebase)
- Pagefind indexed 10 pages, 2063 words
- Sitemap-index generated

Generated files in `dist/`:

```
404.html
architecture/index.html
benchmarks/index.html
changelog/index.html
cli/index.html
contributing/index.html
index.html
operations/index.html
quickstart/index.html
security/index.html
why/index.html
+ pagefind/, _astro/, sitemap-index.xml
```

## 6. Verification — HTTP 200 sweep

`pnpm preview` served on `http://localhost:4322/envless/`. All ten
sidebar entries returned HTTP 200:

```
200 /
200 /quickstart/
200 /architecture/
200 /security/
200 /cli/
200 /operations/
200 /benchmarks/
200 /why/
200 /changelog/
200 /contributing/
```

Additional spot checks:

- **Mermaid renders**: `dist/architecture/index.html` contains
  `class="mermaid"` (rehype-pre-mermaid wrapped the flowchart block;
  the inline cdn-loaded `mermaid` ESM script picks it up at runtime).
- **Changelog joins releases**: built-time fetch of GH Releases API
  succeeded via `GITHUB_TOKEN` fallback, otherwise served from
  `src/data/releases.json`. v0.0.1 renders **twice** — once in the
  "Latest" block, once in the "Full history" block — exactly as
  designed.
- **Empty-state bench panel**: the v0.0.1 release SHA
  (`585b8c1b9beabc83`) is not in `bench/history.jsonl` (which only has
  later post-release commits), so its `<ReleaseCard>` Performance
  section renders the empty-state copy:
  `"No benchmark data for this release yet. Performance numbers land
  automatically once bench/results/<sha>.json is committed for the
  release SHA."`
  Exactly the contract `BenchDeltaTable.astro` documents.
- **Prev/next nav**: changelog page wires "Previous: Why envless" → "Next: Contributing" per the new sidebar order.
- **Edit link**: footer shows `https://github.com/biliboss/envless/edit/main/src/content/docs/changelog.mdx`, confirming `editLink.baseUrl` works against the repo-root layout.

## 7. CI workflow update (`.github/workflows/docs.yml`)

- Removed `defaults.run.working-directory: docs`
- `cache-dependency-path: pnpm-lock.yaml` (was `docs/pnpm-lock.yaml`)
- `upload-pages-artifact` uploads `dist` (was `docs/dist`)
- Triggers expanded to the new content-path set:
  `src/content/**`, `src/components/**`, `src/lib/**`, `src/styles/**`,
  `src/data/**`, `public/**`, `astro.config.mjs`, `package.json`,
  `pnpm-lock.yaml`, `bench/results/**`, `bench/history.jsonl`,
  `.github/workflows/docs.yml`
- `GITHUB_TOKEN` env on the build step preserved (so `src/lib/releases.ts` is not rate-limited)

## 8. Commits

```
bdec2cc ci(docs): update docs.yml for repo-root Astro layout
b25d3bb refactor(site): rewrite astro.config.mjs to agent-tts shape
55b1ef2 refactor(site): flatten sidebar to 10 pages (agent-tts pattern)
59bf363 refactor(site): move Astro from docs/ to repo root
```

`SITE_REPORT.md` from `docs/` was dropped as part of commit `59bf363`
(its contents are superseded by this report).

## 9. Follow-ups / known gaps

- **No redirects from old URLs**. Existing inbound links to
  `/envless/getting-started/install/`, `/envless/concepts/architecture/`,
  `/envless/reference/cli/`, etc. will 404. Two options for follow-up:
  1. Add Starlight `redirects` config mapping each old slug to its new
     anchor (e.g. `getting-started/install` → `/quickstart/`).
  2. Accept the break — the site has been live for one day, traffic is
     near zero, and the launch-day announcement can use the new URLs.
- **`benchmarks.mdx` link to `releases/changelog`**: already retargeted
  to `/envless/changelog/` (single anchor-free URL).
- **`releases/latest`** as a hero CTA — the old `index.mdx` had a
  "Latest v0.0.1 → /releases/latest/" button; the new hero replaces it
  with "Quickstart" + "Architecture" CTAs since the "Latest" block now
  lives at the top of `/envless/changelog/` and is reachable via the
  sidebar.
- **Page density**: each consolidated page is long (e.g. `cli.mdx` is
  ~470 lines, `security.mdx` is ~250). Matches the agent-tts page
  density convention (single long dense reference). If reader feedback
  prefers smaller pages, the natural next step is to split `cli.mdx`
  back into `cli.mdx` + `reference.mdx` (file formats / exit codes /
  env vars) — easy reversal because every former subpage retains its
  own `##` heading.
- **The `<a href="#release-vX">` jump-link in the "All versions" table**
  is now intra-page (the `Latest` section above duplicates the v0.0.1
  card with `id="release-v0.0.1"`, so the first match wins). On future
  releases with N ≥ 2 entries this still resolves to the first
  occurrence; users land on the "Latest" card for the latest tag and
  on the "Full history" entry for older tags. Acceptable today;
  re-evaluate if it confuses anyone.
