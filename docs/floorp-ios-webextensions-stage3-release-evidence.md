# Floorp iOS WebExtensions Stage 3 release evidence

Status: engineering evidence template; not a product, legal, privacy, or App
Review approval.

This document separates the bundled-MV3 runtime's technical verification from
the independent decisions required before a package is shipped.  A green test
run or a pinned fixture digest does not approve redistribution, remote code,
or an App Store release.

## Scope of the current package class

- Package source: bundled, immutable fixture directories only.
- Package identity and integrity: catalog/fixture extension ID and canonical
  SHA-256 are checked by `FloorpWebExtensionPackageStore` and the
  compatibility harness before activation.
- Included fixtures: `content-messaging-mv3`, `event-runtime-mv3`, and
  `demanding-mv3` under `firefox-ios/Floorp/WebExtensions/Fixtures/`.
- High-load DNR fixture: `demanding-mv3` pins 5,000 static block rules;
  4,960 deterministic image rules extend the original 40 fixture rules
  without changing their semantics.
- Licence metadata: every included fixture carries `LICENSE` and
  `fixture-metadata.json`; the current fixtures declare MPL-2.0.
- Remote catalog, document import, and store-origin sources remain disabled
  behind separate feature gates.

## Engineering evidence to attach to a release candidate

Record the exact source revision, Xcode version, simulator/device model, OS
version, and generated result bundle for each row.  Do not substitute a local
smoke test for an unchecked row.

| Evidence | Required result | Record |
| --- | --- | --- |
| Package preflight | Fixture digest, manifest inventory, licence and supported OS floor verify | Result bundle / log |
| API and policy regression suite | All selected `FloorpCI` WebExtensions tests pass | Result bundle / log |
| Content policy ownership | Tracking protection, No Image Mode and extension policies coexist after toggles | Integration result |
| DNR | Static, dynamic and session rules compile; failed update rolls back | Integration result |
| Background and page host | Bundled background, popup and options resources run through the private package origin | WebKit result |
| Device/OS matrix | Current deployment target and newest supported iOS are both tested | Per-device records |
| Performance | Cold/warm compilation, page-load delta and memory are measured for the demanding fixture | Measurements |

## Recorded local engineering run

This is a reproducible simulator regression record, not a device/OS-matrix or
release approval.  Copy the result bundle to the release-evidence store before
cleaning local build artifacts.

| Field | Record |
| --- | --- |
| Associated source revision | `96053894f6` (`feat: complete stage 3 MV3 compatibility`) |
| Build | Signed iOS Simulator `build-for-testing`; app and test bundle used ad-hoc Simulator signatures |
| Toolchain | Xcode 26.6 (build 17F113) |
| Simulator | iPhone 17 Pro, iOS Simulator 26.5 |
| Test scope | 146 Floorp CI tests in the WebExtensions acceptance scope, including browser/content-policy, menu and Settings integration cases |
| Result | 146 passed, 0 failed, 0 skipped, 0 expected failures (75.267 s) |
| Local result bundle | `/private/tmp/floorp-stage3-final-signed-v5-20260824-webextensions-final.xcresult` |

This run includes the bundled-fixture, package-store, API, DNR, background,
page-host, tabs, storage/i18n and Stage 3 WebKit cases.  It does **not** prove
iOS 15 compatibility, real-device behavior, performance/memory targets, or
any of the release approvals below.

The result bundle does not embed a Git revision; retain it with the cited
revision in the release-evidence store.

## Release approvals — required before shipping a package

These rows must be completed by the accountable product/legal/release owners;
they cannot be inferred from source control.

| Decision | Owner | Approval / reference |
| --- | --- | --- |
| Package provenance, publisher and update policy | Product | Pending |
| Redistribution licence, notices and source obligations | Legal | Pending |
| App Review guideline analysis and reviewer exercise path | Release / App Review | Pending |
| Privacy, moderation and age-rating treatment | Privacy / Product | Pending |
| Supported OS floor from device evidence | Engineering / Product | Pending |
| Package-specific kill or block decision | Release | Pending |

## Non-approval statement

No item in this repository authorizes installation of arbitrary Chrome or
Firefox extensions, remote package updates, document imports, or a general
extension store.  Those sources require their separately gated implementation
and the approvals above.
