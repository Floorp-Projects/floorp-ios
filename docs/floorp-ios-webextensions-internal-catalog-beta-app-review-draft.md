# Floorp iOS: curated WebExtensions Beta App Review draft

Status: **draft only reviewer copy. 2026-08-27 の maintainer 判断により、exact
`main` source SHA、管理署名済み catalog、candidate-bound Xcode Cloud build が
揃った時点で Beta App Review に提出できる。** `draft only` は承認を表すものではなく、
App Store Connect で使う前に提出ワークフローが証跡で値を確定する。この文書は Apple、Legal,
Privacy、Security、または upstream author の承認を表すものではなく、Apple の
審査結果や external tester availability を先取りして主張してはならない。

## Release operator completion fields

Complete these outside the repository immediately before a source-bound
submission. Do not invent values or substitute an earlier build.

| Field | Required value/evidence |
| --- | --- |
| App Store Connect build | Exact `marketing version (build)` and build ID produced from merged `main` SHA |
| Catalog identity | Catalog ID, sequence, root key ID, leaf key ID, expiry, and signed catalog SHA-256 |
| IPA identity | IPA SHA-256, archive signing/team evidence, and the 16-artifact inventory SHA-256 list |
| Product/Apple review decision | Written owner-approved reviewer exercise path for the fixed app-bundled set and Guideline 3.2.2(i)/4.7 rationale |
| Legal/Privacy decision | Per-artifact redistribution/notice/support/privacy records for the 13 compatibility builds plus retention policy |
| Security decision | Managed-signer custody, dual approval, audit record, rotation and emergency-revocation exercise |
| Reviewer contact | Current contact name, email, and phone supplied by the responsible release owner |
| External group | Existing approved group ID; do not create a group as part of submission |

## Proposed Beta App Review notes

Use only after the fields above are complete and reviewed. Replace bracketed
values with evidence-backed values; omit any claim that cannot be shown in the
submitted build.

> Floorp for iOS [version/build] contains a fixed, product-curated set of 16
> WebExtensions that are all embedded in the signed application bundle. This is
> not an extension store or a catalog download client. The app provides no
> Chrome Web Store, Firefox Add-ons, arbitrary URL, ZIP/XPI/CRX, shared-sheet,
> or local-file installation flow. It does not fetch or execute remote
> JavaScript, WebAssembly, or DNR/filter lists.
>
> At startup the app validates a bundled, signed catalog against the app's
> embedded root public key and validates the catalog audience, expiry, sequence,
> revocation state, immutable generation, artifact SHA-256, manifest, and
> resource inventory before showing any catalog item. If validation fails, no
> catalog extension can be installed or enabled. Existing package updates are
> immutable generations and always require explicit native confirmation; there
> is no silent update or automatic permission escalation.
>
> Reviewer path: Settings > Extensions. Confirm the catalog shows exactly the
> fixed packages listed below. Install Floorp Site Appearance, Floorp Tracker
> Block Lite, and Floorp Session Timer as representative content-script,
> static-DNR, and popup/options/storage/alarms packages. Use an ordinary
> non-sensitive page for the content-script example. Disable/re-enable and
> remove/reinstall each; disabled extensions stop their runtime/rules/actions,
> and removal clears extension-owned local data. For DNR, the package supports
> only static `block` actions and per-site exclusion; it has no redirects,
> header modification, dynamic/session rules, or remote list refresh.
>
> Private Browsing use is opt-in and profile-local. Normal and private site
> grants, storage, alarms, DNR rules, and runtime state are separate. The
> catalog itself contains no account/login requirement and does not require a
> demo account.

## Fixed package inventory

The final signed catalog must equal this review input. Any name, version,
generation, digest, permission, host scope, or package-count change requires a
new review of this draft and the relevant approvals.

| Package | Floorp ID | Supported family |
| --- | --- | --- |
| Floorp Site Appearance | `floorp.site-appearance` | content script |
| Floorp Tracker Block Lite | `floorp.tracker-block-lite` | static block-only DNR |
| Floorp Session Timer | `floorp.session-timer` | popup/options/storage/alarms |
| Tracking Token Stripper | `floorp.thirdparty.utm-stripper` | content script, popup/storage |
| Minimal Twitter | `floorp.thirdparty.minimal-twitter` | content script |
| Refined Hacker News | `floorp.thirdparty.refined-hacker-news` | content script |
| ekill | `floorp.thirdparty.ekill` | content script |
| Medium Reading Layout | `floorp.thirdparty.medium-reading-layout` | content script |
| Web Search Navigator | `floorp.thirdparty.web-search-navigator` | content script |
| GitHub Dashboard Filter | `floorp.thirdparty.github-dashboard` | content script |
| Enhanced GitHub | `floorp.thirdparty.enhanced-github` | content script |
| Useful Forks | `floorp.thirdparty.useful-forks` | content script |
| Easy to RSS | `floorp.thirdparty.easy-to-rss` | content script, popup/storage |
| Scroll To Top | `floorp.thirdparty.scroll-to-top` | content script |
| Refined Twitter | `floorp.thirdparty.refined-twitter` | content script |
| Very Good AdBlock | `floorp.thirdparty.very-good-adblock` | static block-only DNR |

Exact versions, immutable generations, original-input and normalized artifact
digests, permissions, host patterns, and compatibility reductions are recorded
in [the third-party record](THIRD_PARTY_EXTENSIONS.md) and
[`catalog-input.json`](../firefox-ios/Floorp/WebExtensions/CuratedCatalog/catalog-input.json).
The candidate's public signed output must be source-bound to the exact merged
`main` commit before that commit is archived. Its signing composition must use
one of the P0-approved paths in the release-gate record: a review-bound
pre-merge signature whose **public output** is reviewed with the candidate, or
a separately reviewed second integration of the public signed output. No
signing private key, source archive, review workspace, or remote endpoint
belongs in the app target.
