# Floorp iOS WebExtensions Stage 3 release evidence

Status: engineering evidence template; not a product, legal, privacy, or App
Review approval.

This document separates the bundled-MV3 runtime's technical verification from
the independent decisions required before a package is shipped.  A green test
run or a pinned fixture digest does not approve redistribution, remote code,
or an App Store release.

## Scope of the current package class

- Package source: bundled, immutable fixture directories only.
- Package identity and integrity: manifest extension ID and canonical SHA-256
  are checked by `FloorpWebExtensionPackageStore` and the compatibility
  harness before activation.
- Included fixtures: `content-messaging-mv3`, `event-runtime-mv3`, and
  `demanding-mv3` under `firefox-ios/Floorp/WebExtensions/Fixtures/`.
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
