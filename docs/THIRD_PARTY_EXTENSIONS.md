# Third-party WebExtensions: provenance and selection record

Status: **redistribution basis verified for the current Dark Reader-only
catalog.** The sole Floorp iOS maintainer accepts the preserved MIT license,
local `LICENSE` and `NOTICE`, pinned upstream revision/archive digest, and
checked-in provenance record as the redistribution basis. This does not claim
upstream endorsement or third-party support.

Earlier catalog candidates and their evidence remain part of version-control
and release history, but they are not members of the current catalog. A future
extension whose license, notice, provenance, privacy, or compatibility basis is
absent, incompatible, or cannot be re-verified is excluded before signing.

## Current adopted compatibility build

The app does not download Dark Reader and does not execute an upstream ZIP,
XPI, or CRX binary. Floorp builds a compatibility-patched package from the
pinned upstream revision, documents the changes in `PATCH.txt`, and normalizes
the reviewed resources to FWEA1. The complete original-input SHA-256,
normalized artifact SHA-256, manifest/inventory digests, notices digest, and
inspection result are recorded in `CuratedCatalog/review-index.json` and
`Review/thirdparty-darkreader/inspection.json`.

The review-only
`SourceProvenance/thirdparty-darkreader.json` record pins the GitHub archive
URL, archive root and SHA-256, upstream license member, reviewed source-member
hashes, and the local `LICENSE`, `NOTICE`, `manifest.json`, and
`PATCH.txt` derivation hashes. The managed signer must receive the real
quarantined archive, re-verify every binding, and preserve separate provenance
evidence before a candidate can rely on it.
`verify_curated_source_provenance.py` is not packaged in the app and performs
no runtime fetch.

| Floorp ID | Upstream / pinned revision | License | Retained local function | Redistribution basis |
| --- | --- | --- | --- | --- |
| `floorp.thirdparty.darkreader` | [darkreader/darkreader](https://github.com/darkreader/darkreader) `c2a707302a39` | MIT | Applies reviewed local dark-theme transformations to allowed sites | MIT + `LICENSE`/`NOTICE` + pinned provenance |

## Exact immutable compatibility-build record

The following values are copied from the deterministic unsigned catalog input
that the managed signer signs. `original SHA-256` is the frozen upstream input
recorded before Floorp's compatibility work; `FWEA1 SHA-256` is the immutable
normalized package that the iOS client verifies. Private-profile use is
`opt-in`.

| Floorp ID | Floorp version / immutable generation | Original SHA-256 | FWEA1 SHA-256 | Declared APIs / host patterns | Recorded compatibility modification |
| --- | --- | --- | --- | --- | --- |
| `floorp.thirdparty.darkreader` | `4.9.129` / `g20260826-thirdparty-darkreader` | `b0a1af878da40dbb21544d5f8a19d15ab3120fc5c2a84f6654d795363ee88755` | `ca6b6a61ab5c46a0224919de1da2fc7b50b8904488ad0975afb22245732379d8` | `alarms`, `fontSettings`, `scripting`, `storage` / `*://*/*` | `PATCH.txt`; bundled configuration only, device-local sync namespace, no remote configuration/news/update fetch |

The current technical inventory is therefore one immutable third-party
package: Dark Reader. It has no remote executable, remote DNR list,
`update_url`, or client-side download path.

## Selection policy

The current catalog intentionally prioritizes a richer, end-to-end extension
experience instead of shipping many small compatibility samples. Dark Reader
is the only selected package at this stage because its page transformation,
background logic, popup, settings page, storage, alarms, and site-access flow
exercise that richer supported path.

This is a current-set decision, not a permanent one-package limit. Any future
addition must complete the same source review and managed signing path and must
not reuse approval evidence from an earlier catalog candidate.

## Review before a new item can be adopted

1. Pin the upstream revision and capture the original input SHA-256.
2. Verify a compatible redistribution license, preserve its notice obligations,
   pin the upstream archive/source provenance, and record Floorp's privacy
   disclosure and fixed support/report path.
3. Reduce behavior to the supported local MV3 subset where necessary and record
   every change in `PATCH.txt`; never silently rewrite an upstream package.
4. Run ingestion quarantine and review the FWEA1 artifact, manifest, inventory
   digests, and inspection findings.
5. Test normal/private profile behavior, site grant, action and settings pages,
   disable, uninstall, update, and revocation for the exact immutable artifact.
6. Regenerate the catalog input, verify every source-provenance binding, obtain
   candidate-bound maintainer approval, and create a new managed signature.
7. Complete normal PR/CI review, source-bound TestFlight verification, and Apple
   review before external distribution.

The selection record must also name requested APIs and host scope, whether the
upstream has remote code or data, its update and support posture, the exact
source/archive digest, and every compatibility removal. Catalog metadata alone
is never the sole provenance record.
