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
| Performance | Native transformation, WebKit cold/warm compilation, page-load delta and memory are measured for the demanding fixture | Measurements |

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

## Recorded native DNR transform measurement — limited scope

This addendum records one repeatable, native-only measurement.  It is **not**
a WebKit content-rule compilation measurement, a page-load benchmark, a memory
pressure/recovery measurement, or a release-performance conclusion.

The test parsed and preflight-validated the immutable `demanding-mv3`
`rules/static.json` before timing. After one untimed warm-up, each of the seven
samples created a fresh `FloorpWebExtensionDNRStore` from the same in-memory
5,000-rule value array. The recorded boundary is therefore a fresh-store,
cache-bypassing native transform. Timing uses `mach_continuous_time`.

| Field | Record |
| --- | --- |
| Source state at capture | The then-uncommitted working-tree changes that add the Stage 3 performance-evidence test and artifact export; no committed revision identifies this measurement yet |
| Fixture | `demanding-mv3` 1.0.0; SHA-256 `05c6dc2719aea1429f70cffc1c0fc1ad8dcb053a842eb0f3a3fa994424f33d37` |
| Runner | iPhone 17 Pro Simulator (`iPhone18,1`, `8167A41E-0E88-40A2-896B-0D939E2F941F`), arm64, iOS Simulator 26.5 (build 23F77) |
| Samples | 1 warm-up (untimed), then 7 measured fresh-store native transforms |
| Raw samples | 388.732, 364.159, 371.023, 386.515, 389.774, 389.989, 455.591 ms |
| Summary | mean 392.255 ms; median 388.732 ms; p95 455.591 ms (n=7; p95 is the highest ordered sample) |
| Functional output | 5,000 compiled/transformed rules; 0 rejected rules; fixture integrity verified |
| Native-artifact JSON | `/private/tmp/floorp-stage3-native-attachment-export-20260824/7D6AB0C6-40F1-4A95-A4E2-5EA4AFD0133D.json` (SHA-256 `5156237c8ce644d08723ef28e13f0cb5c64d0580a08f06fa3df5eabcd909f66d`) |
| Attachment manifest | `/private/tmp/floorp-stage3-native-attachment-export-20260824/manifest.json` (identifies `FloorpWebExtensionStage3NativeDNRPerformanceTests/testRecordsRepeatedDemandingFixtureNativeTransformEvidence()`) |
| Related acceptance result | `/private/tmp/floorp-stage3-final-signed-v5-20260824-webextensions-final.xcresult`: 146/146 passed on the same simulator OS; this earlier regression result is not a substitute for the native measurement artifact |

The earlier 146/146 regression run remains associated with `96053894f6` in
the preceding section. This native measurement was produced from an
uncommitted worktree and is retained only as a non-release engineering
record; it must not be attributed to that revision or any later commit.
Before release use, check out the exact clean committed SHA containing the
performance-evidence changes, rerun the measurement from that checkout, and
record that SHA together with the newly produced artifact hashes in the
release-evidence store.

Still unmeasured: WebKit content-rule compilation (both cold and warm), the
extension-enabled page-load delta, memory use and memory-pressure recovery,
real-device behavior, and iOS 15 behavior. These remain required release
evidence; the numbers above must not be extrapolated to them.

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
