# App Review notes: Floorp native WebExtensions

- Owner: Floorp release manager
- Applies to: the first build shipping `WKWebExtension` and every build that changes a bundled extension
- Product minimum: iOS / iPadOS 18.4
- Dark Reader minimum: iOS / iPadOS 18.4
- uBlock Origin Lite minimum: iOS / iPadOS 26.0

This document is the source of truth for App Store Connect review notes. It is not a legal
opinion and does not predict Apple's decision. The release manager must disclose the bundled
GPL component and submit the resulting binary for Apple's review, as directed by the Floorp
project policy.

## Submission gate

Do not submit a build until all of the following values identify the exact public source used
for that binary. App Review notes must not contain placeholders or private URLs.

- Floorp version and build number
- Floorp release tag or full commit SHA
- Public immutable Floorp source URL:
  `https://github.com/Floorp-Projects/floorp-ios/tree/<release-tag-or-full-commit>`
- Confirmation that the tag/commit is publicly reachable without authentication
- Confirmation that both bundled ZIP digests match the values below
- Confirmation that the App Privacy answers still describe this build

## Paste into App Store Connect — Review Notes

Replace the bracketed build-specific values before submission.

```text
Floorp [VERSION] ([BUILD]) bundles Dark Reader and uBlock Origin Lite.
Floorp does not download WebExtension code or load external ZIPs. Code, rules, licenses, and provenance
ship in-app; patches and reproducible builds are public.

Implementation:
- Floorp uses only Apple's public WKWebExtension APIs, including MatchPattern,
  loadBackgroundContent, and context.webViewConfiguration.
- Popup routes settle before close. Private data is nonpersistent, separately authorized, and off by default.
  Lifecycle changes finish at cold startup.

Bundled open-source components:
- Dark Reader 4.9.129, MIT, Floorp-derived. Its patch replaces background.service_worker with
  nonpersistent background.scripts, adds durable Safari storage/readback and acknowledged popup routes,
  and removes unsupported shortcut UI.
  Upstream: https://github.com/darkreader/darkreader/releases/download/v4.9.129/darkreader-chrome-mv3.zip
  Upstream SHA-256: 20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64
  Derived SHA-256: 92f40f485205f61233185d1fb7cfb84b1dec243ebefc181d5f53943adc3c97c6
  Patch: firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-floorp-ios-mv3-4.9.129.patch
  Build: scripts/package-darkreader-ios.sh
  Source commit: c2a707302a39b8047543712e9c582bac07835d34
- uBlock Origin Lite 2026.825.1619, GNU GPL v3.0 or later, Floorp-derived. Its patch adds public
  declarativeNetRequestFeedback, incognito/window routes, deterministic startup, and durable readback.
  Custom/procedural filters use per-document random root scopes; ambiguous hostless frames fail closed.
  WebKit's ignored frame CSS target is handled by inert-scoped all-frame insertion. A canary must prove application
  before commit; each activation/lifecycle event has a 15-second retry window.
  Restore uses a journaled lock; managed-policy changes share that lock and retry failed native side effects.
  Malformed journals fail closed. DNR updates are
  serialized and read back exactly. Two hidden DNR keeper slots cap each public dynamic/session store at 14,999;
  ID 7,000,000 matches only floorp.invalid, makes no request, is hidden from reads, and rejects collisions.
  Legacy full stores remain readable; failed updates never auto-delete user rules. UI failures remain retryable.
  Upstream: https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.825.1619/uBOLite_2026.825.1619.safari.zip
  Upstream SHA-256: 89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94
  Derived SHA-256: 9cd2e9f6c3d62ef6154dd4dd9f94a5ef70a7ec7386bd2f05c11e29126b3aa6d6
  Patch: firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite-floorp-ios-2026.825.1619.patch
  Build: scripts/package-ubol-ios.sh
  Source commit: 080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b
- Floorp source: https://github.com/Floorp-Projects/floorp-ios/tree/[RELEASE_TAG_OR_FULL_COMMIT]
  ZIPs, MIT/GPL text, and provenance ship in-app.

Compatibility: Floorp/Dark Reader require iOS 18.4; uBO requires iOS 26.0. Floorp raises only
uBO's package minimum to avoid the older WebKit DNR allow-priority behavior; its upstream Safari
build also omits strict-block UI for a WebKit limit. Request/cosmetic filtering remains. No sign-in.

Privacy: telemetry/crash/sponsored/ad-attribution uploads and tracking are off. Optional Mozilla
Account services process account/operational data; Sync is E2EE and user-controlled.

Review on iOS 26.0+: install both in Settings > Extensions. Dark Reader readiness fails open; uBO's
first install, cold restore, or re-enable can spend up to 240 seconds compiling its native DNR data;
its first normal/private navigation per context waits up to 90 seconds and fails closed. Verify both
popups, Options, uBO request/cosmetic blocking, and separate Private access. Enable uBO Developer
mode and open Matched rules in both modes. After Dark Reader idles 35 seconds, verify a fresh
HTTP(S) page is dark without popup/reload.
```

## Paste into TestFlight — What to Test

```text
Floorp 0.3.0 — Runtime fixes and native WebExtensions candidate

Please focus on three reported regressions:

1. Fully quit and cold-launch Floorp repeatedly. The browser UI should appear promptly;
   startup must not pause for 8–15 seconds while bundled extensions initialize.
2. Use Google Search, especially on iPad. Google must not show an outdated-browser
   warning. Floorp's displayed app version should remain 0.3.0.
3. With NinjaMiles Japanese Romaji predictive input enabled, type “ka” and longer
   text in the address bar. Composition should produce “か”, never “kか” or duplicated
   characters. Editing and committing the text should remain stable.

This build uses Apple's public WKWebExtension APIs for two optional, app-bundled
extensions: Dark Reader 4.9.129 and uBlock Origin Lite 2026.825.1619. No sign-in
is required.

In Settings > Extensions, install Dark Reader. Confirm page appearance, popup and
Options work. Disabling or uninstalling it should restore open pages immediately.
Re-enabling and reinstalling complete after restart and retain state. After at least
35 seconds idle, a fresh HTTP(S) page should be dark on first load without a popup
or reload.

On iOS 26.0 or later, install uBlock Origin Lite. Allow up to four minutes for its
first install, cold restore or re-enable while WebKit compiles the native ruleset.
First navigation in each normal/private context can wait up to 90 seconds and fails
closed if readiness is not confirmed. Confirm request and cosmetic blocking, popup,
dashboard, Japanese filter-list persistence, restart/update flows, and dashboard links.
Enable Developer mode and open Matched rules in normal and allowed Private Browsing;
the route must open once and preserve its browsing mode. Save and clear a harmless
user DNR rule: no “unknown error” should appear, state must survive relaunch, and
Matched rules must never expose internal keeper ID 7,000,000. Existing installs must
retain their rules without automatic deletion. The upstream Safari package has no
strict-block interstitial; normal request/cosmetic filtering should still work.

Private Browsing access must remain off until separately enabled. Before opt-in,
neither extension may affect private tabs; after opt-in, private tabs, grants and
extension state must not leak into normal browsing. Below iOS 26.0, uBlock Origin
Lite must be shown as requiring iOS 26.0 while Dark Reader remains available.

There must be no arbitrary ZIP, XPI, CRX, URL or extension-store installation path.
Please also report regressions in tabs, history, downloads, Reader Mode, tracking
protection, Notes or Notes Sync.
```

## Release evidence retained in the repository

| Extension | Catalog identifier | Version | SHA-256 | Source commit | License | Package policy | Minimum |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Dark Reader | `floorp.bundled.darkreader` | `4.9.129` | `92f40f485205f61233185d1fb7cfb84b1dec243ebefc181d5f53943adc3c97c6` | `c2a707302a39b8047543712e9c582bac07835d34` | `MIT` | Floorp-derived; nonpersistent background plus Safari storage/readiness/UI-close durability, close-tracked acknowledged popup routing, and unsupported shortcut UI removal; upstream SHA-256 `20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64` | iOS 18.4 |
| uBlock Origin Lite | `floorp.bundled.ublock-origin-lite` | `2026.825.1619` | `9cd2e9f6c3d62ef6154dd4dd9f94a5ef70a7ec7386bd2f05c11e29126b3aa6d6` | `080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b` | `GPL-3.0-or-later` | Floorp-derived; public DNR feedback, realm-safe close-tracked acknowledged popup routing, serialized storage, combined/per-store-capacity-reserved hidden Safari dynamic/session DNR keepers with non-destructive legacy migration, durable serialized DNR/script reconciliation with delayed-readback convergence, exact-runtime-URL fallback for WebKit lifecycle sender validation, random document-root-scoped custom cosmetic/procedural reinjection over WebKit all-frame native CSS with canary-backed acknowledgements and bounded 15-second retry windows, direct/inherited same-registration procedural API preload, transport-fallback bounded custom-filter snapshots, queue-time document-idle/dynamic recovery, dynamic-preflight-free origin-fallback replies, uncommitted-only document-idle replay, and event-bounded BFCache recovery across cross-host/normal/private/origin-fallback navigation, transaction-safe draft-preserving user-DNR restore, fail-closed Safari DNR shape/regex handling without partial user-rule replacement, foreground-completed rollback/readback, cross-dashboard state convergence, DOM-safe ruleset readback, host-awaited UI close, and startup-safe schema-validated Page Action initialization; upstream SHA-256 `89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94` | iOS / Safari 26.0 |

The canonical local evidence is:

- `firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-floorp-ios-mv3-4.9.129.zip`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-floorp-ios-mv3-4.9.129.LICENSE`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-floorp-ios-mv3-4.9.129.provenance.json`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-floorp-ios-mv3-4.9.129.patch`
- `scripts/package-darkreader-ios.sh`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite-floorp-ios-2026.825.1619.zip`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite-floorp-ios-2026.825.1619.LICENSE`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite-floorp-ios-2026.825.1619.provenance.json`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite-floorp-ios-2026.825.1619.patch`
- `scripts/package-ubol-ios.sh`
- `firefox-ios/Floorp/NativeWebExtensions/FloorpNativeWebExtensionModels.swift`

Apple asks developers to provide special settings and review instructions in App Review
Information. Before each submission, compare this template with the current
[App Review page](https://developer.apple.com/app-store/review/) and
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially
the current public-API, self-contained-bundle, privacy, and intellectual-property sections.
