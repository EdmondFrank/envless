---
title: License & governance
description: Apache-2.0, single maintainer, no CLA. What that means for adopters.
---

`envless` is licensed under the [Apache License, Version 2.0][apache], a
permissive open-source license that the OSI, FSF, and most corporate
legal teams already accept without review.

## What Apache-2.0 grants you

- **Use** — commercial or otherwise, with no royalty.
- **Modify** — fork, patch, vendor. No callback obligation.
- **Distribute** — ship the binary in your product, embed it in a Docker
  image, redistribute under a different name. Keep the NOTICE.
- **Patent grant** — explicit patent license from contributors. Vault's
  BSL does not give you this.

## What it asks of you

- Keep the copyright notice and the LICENSE file with any redistribution.
- Mark significant changes if you redistribute a modified version.
- No warranty. Treat it like every other OSS dependency.

The full text lives in [LICENSE][gh-license] at the repo root, dated 2026
and copyrighted to Gabriel Fonseca.

## Governance

`envless` is, today, a single-maintainer project. There is no foundation,
no steering committee, and no Contributor License Agreement. The
contribution model is:

1. Open a GitHub issue describing the change.
2. Send a pull request. The Apache-2.0 implied-license clause (§5)
   covers contributions; you do not sign a separate CLA.
3. Reviews focus on parity with the architectural principles in
   [Positioning](../positioning/) — no SaaS coupling, no language SDKs,
   no spinners.

If `envless` grows beyond a single maintainer, governance will be
formalised before that becomes a problem (likely a small TSC and a
trademark policy). It will not be retroactively re-licensed.

## Relicensing posture

The license will stay permissive. `envless` will not adopt:

- BSL or SSPL — they break the "use commercially without negotiation"
  promise.
- AGPL — overkill for a CLI; chills downstream embedding.
- Source-available-then-commercial — that is a SaaS funnel, not OSS.

If those terms matter to your procurement team, the answer is the same
today as it will be in five years: Apache-2.0.

## Dependencies and their licenses

`envless` is intentionally low-dependency. Run `go mod graph` (or read
[`go.mod`][gh-gomod]) for the current set. The substrate it shells out to:

- **age** — BSD-3-Clause.
- **sops** — MPL-2.0.

Both are compatible with Apache-2.0 redistribution.

[apache]: https://www.apache.org/licenses/LICENSE-2.0
[gh-license]: https://github.com/biliboss/envless/blob/main/LICENSE
[gh-gomod]: https://github.com/biliboss/envless/blob/main/go.mod
