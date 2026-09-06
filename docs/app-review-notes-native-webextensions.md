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
Floorp [VERSION] ([BUILD]) optionally bundles Dark Reader and uBlock Origin Lite.
Floorp does not download WebExtension code or accept external ZIPs/catalogs. Code, rules, licenses, and provenance
ship in-app; patches and reproducible builds are public.

Implementation:
- Floorp uses only Apple's public WKWebExtension APIs, including MatchPattern,
  loadBackgroundContent, and context.webViewConfiguration.
- Popups retain their source tab. Private data is nonpersistent, separately authorized, and off by
  default. Updates, re-enable, and reinstall complete at cold startup.

Bundled open-source components:
- Dark Reader 4.9.129, MIT, Floorp-derived. Its patch replaces background.service_worker with
  nonpersistent background.scripts and adds Safari storage durability, readback, and UI-close
  handshakes.
  Upstream: https://github.com/darkreader/darkreader/releases/download/v4.9.129/darkreader-chrome-mv3.zip
  Upstream SHA-256: 20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64
  Derived SHA-256: ebbb916a7b2bd8e3c5c6e538316fe3eea2e11875432522934f489697654cd761
  Patch: firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-floorp-ios-mv3-4.9.129.patch
  Build: scripts/package-darkreader-ios.sh
  Source commit: c2a707302a39b8047543712e9c582bac07835d34
- uBlock Origin Lite 2026.825.1619, GNU GPL v3.0 or later, Floorp-derived. Its patch adds public
  declarativeNetRequestFeedback; incognito/window IDs keep Matched rules and Report in the source
  realm. It validates Page Action data and adds deterministic startup, serialized storage, and
  durable DNR/script reconciliation.
  Popup/Dashboard Done await native readback. Restore preserves drafts, validates effective user DNR
  before mutation, and recovers journals, alarms, and badge state. Audited official Safari-ignored
  regex/domain rules are exact-normalized when provable and otherwise omitted instead of broadened.
  A rejected live user rule aborts the whole update; mismatched native readback restores and verifies
  the complete pre-update rule set.
  An unvisited Filter lists pane preserves the installed selection. Failures remain visible and
  retryable, with an explicit Close Anyway escape.
  Upstream: https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.825.1619/uBOLite_2026.825.1619.safari.zip
  Upstream SHA-256: 89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94
  Derived SHA-256: 1408e320bd8ed6f0d3c12e95c53c477f219e7f04b5c154fe7743e9d42f94a22d
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
Floorp 0.3.0 — Native WebExtensions release candidate

This build replaces Floorp's experimental extension runtime with Apple's public
WKWebExtension APIs. It contains two optional, app-bundled extensions: Dark
Reader 4.9.129 and uBlock Origin Lite 2026.825.1619. No sign-in is required.

In Settings > Extensions, install Dark Reader. Confirm that page appearance,
its action popup and options work; disabling or uninstalling it immediately
restores open pages. After disabling, enabling must show “Will enable after restart”
and remain inactive until Floorp is restarted. After uninstalling, restart Floorp before
reinstalling; installation then works. Confirm that
closing its popup does not reveal a disabled
Extensions picker underneath it.
After leaving Floorp/Dark Reader idle for at least 35 seconds, navigate to a fresh
HTTP(S) page and confirm that its first load is dark without a popup or reload.

On iOS 26.0 or later, install uBlock Origin Lite. On non-sensitive test sites,
allow up to four minutes for its first install, cold restore, or re-enable while
WebKit compiles the native ruleset. Subsequent first navigation in each normal/private
context can wait up to 90 seconds and fails closed if readiness is not confirmed. Then
confirm that ad/tracker requests and cosmetic elements covered by its official
rules are removed. Test its popup and dashboard; enable the Japanese filter list
(if already enabled, turn it off and back on) and tap Done
immediately, then confirm the selection and blocking persist. Also test disable/deferred-enable
across restart, uninstall/restart/reinstall, and persistence after restart.
If an update is offered, confirm it requires restart and completes on the next cold launch.
Enable Developer mode in the dashboard, then open Matched rules from both normal
and explicitly allowed Private Browsing and confirm each page stays in its originating
browsing mode.
Confirm links from its dashboard open in a Floorp tab and retain the current
normal/private browsing mode.
The upstream Safari package intentionally does not show its strict-block
interstitial; ordinary request blocking and cosmetic filtering should still
work. On iOS versions earlier than 26.0, uBlock Origin Lite must be shown as
requiring iOS 26.0 while Dark Reader remains available.

Private Browsing access must remain off until separately enabled. Before
opt-in, confirm neither extension affects private tabs. After opt-in, test both
without leaking private tabs, grants, or extension state into normal browsing.

There must be no arbitrary ZIP, XPI, CRX, URL, or extension-store installation
path. Please also report regressions in tabs, navigation history, downloads,
Reader Mode, tracking protection, Notes, or Notes Sync.
```

## Release evidence retained in the repository

| Extension | Catalog identifier | Version | SHA-256 | Source commit | License | Package policy | Minimum |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Dark Reader | `floorp.bundled.darkreader` | `4.9.129` | `ebbb916a7b2bd8e3c5c6e538316fe3eea2e11875432522934f489697654cd761` | `c2a707302a39b8047543712e9c582bac07835d34` | `MIT` | Floorp-derived; nonpersistent background plus Safari storage/readiness/UI-close durability; upstream SHA-256 `20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64` | iOS 18.4 |
| uBlock Origin Lite | `floorp.bundled.ublock-origin-lite` | `2026.825.1619` | `1408e320bd8ed6f0d3c12e95c53c477f219e7f04b5c154fe7743e9d42f94a22d` | `080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b` | `GPL-3.0-or-later` | Floorp-derived; public DNR feedback, realm-safe routing, serialized storage, durable DNR/script reconciliation, transaction-safe draft-preserving user-DNR restore, fail-closed Safari DNR shape/regex handling without partial user-rule replacement, foreground-completed rollback/readback, cross-dashboard state convergence, DOM-safe ruleset readback, host-awaited UI close, and startup-safe schema-validated Page Action initialization; upstream SHA-256 `89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94` | iOS / Safari 26.0 |

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
