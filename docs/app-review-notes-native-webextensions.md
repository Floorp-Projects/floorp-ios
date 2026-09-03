# App Review notes: Floorp native WebExtensions

- Owner: Floorp release manager
- Applies to: the first build shipping `WKWebExtension` and every build that changes a bundled extension
- Product minimum: iOS / iPadOS 18.4
- Dark Reader minimum: iOS / iPadOS 18.4
- uBlock Origin Lite minimum: iOS / iPadOS 18.6

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
Floorp [VERSION] ([BUILD]) includes two optional, user-installed WebExtensions: Dark Reader
and uBlock Origin Lite. Floorp does not download WebExtension code, accept arbitrary ZIPs,
or provide a remote extension catalog. The reviewed ZIPs, JavaScript/CSS, rules, license
notices, and provenance records are self-contained in this app bundle.

Implementation:
- Floorp uses only Apple's public WKWebExtension APIs.
- Extensions remain disabled until the user opens Settings > Extensions, selects one, taps
  Install, and confirms its source, license, permissions, and website access.
- Private Browsing access is off by default and requires a separate user action.
- Website access lets Dark Reader apply the selected appearance and lets WebKit locally apply
  uBlock Origin Lite's declarative rules, cosmetic CSS, and content-filtering scripts.

Bundled third-party open-source components:
- Dark Reader 4.9.129, MIT, unmodified official Chrome MV3 asset.
  SHA-256: 20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64
  Release: https://github.com/darkreader/darkreader/releases/tag/v4.9.129
  Source: https://github.com/darkreader/darkreader/tree/c2a707302a39b8047543712e9c582bac07835d34
- uBlock Origin Lite 2026.825.1619, GNU GPL v3.0 or later, unmodified official
  Safari asset.
  SHA-256: 89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94
  Release: https://github.com/uBlockOrigin/uBOL-home/releases/tag/2026.825.1619
  Source: https://github.com/uBlockOrigin/uBOL-home/tree/080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b
- Floorp source for this submitted binary:
  https://github.com/Floorp-Projects/floorp-ios/tree/[RELEASE_TAG_OR_FULL_COMMIT]
- The MIT notice and complete GPL text are app resources and public beside the assets above.
  uBlock Origin Lite's official ZIP also contains LICENSE.txt. Floorp publishes the complete
  corresponding source for this binary at the Floorp URL above.

Compatibility and known limitation:
- Floorp and Dark Reader require iOS 18.4. This uBlock Origin Lite package requires iOS 18.6,
  which Floorp enforces.
- Its official Safari build disables only the strict-block interstitial due to an upstream
  WebKit limitation. Request blocking and cosmetic filtering remain active. Floorp has not
  modified the GPL package to bypass that limitation.

No account or sign-in is required for review.

Review steps on iOS 18.6 or later:
1. Launch Floorp and open Settings > Extensions.
2. Select uBlock Origin Lite, review the sheet, and tap Install.
3. Browse a page, then open Floorp menu > Extensions > uBlock Origin Lite for its popup.
4. Open Settings > Extensions > uBlock Origin Lite > Options for its dashboard.
5. Private Browsing remains unavailable until "Allow in Private Browsing" is selected.
6. Dark Reader can be installed and inspected through the same menus.

Please contact us through App Store Connect for additional source or license information.
```

## Paste into TestFlight — What to Test

```text
Floorp 0.3.0 — Native WebExtensions release candidate

This build replaces Floorp's experimental extension runtime with Apple's public
WKWebExtension APIs. It contains two optional, app-bundled extensions: Dark
Reader 4.9.129 and uBlock Origin Lite 2026.825.1619. No sign-in is required.

In Settings > Extensions, install Dark Reader. Confirm that page appearance,
its action popup and options work; disabling or uninstalling it immediately
restores open pages; enabling or reinstalling works; and its state persists
after restarting Floorp.

On iOS 18.6 or later, install uBlock Origin Lite. On non-sensitive test sites,
confirm that ad/tracker requests and cosmetic elements covered by its official
rules are removed. Test its popup and dashboard, Japanese filter-list
selection, disable/enable, uninstall/reinstall, and persistence after restart.
The upstream Safari package intentionally does not show its strict-block
interstitial; ordinary request blocking and cosmetic filtering should still
work. On iOS 18.4 or 18.5, uBlock Origin Lite must be shown as requiring iOS
18.6 while Dark Reader remains available.

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
| Dark Reader | `floorp.bundled.darkreader` | `4.9.129` | `20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64` | `c2a707302a39b8047543712e9c582bac07835d34` | `MIT` | Unmodified official Chrome MV3 asset | iOS 18.4 |
| uBlock Origin Lite | `floorp.bundled.ublock-origin-lite` | `2026.825.1619` | `89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94` | `080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b` | `GPL-3.0-or-later` | Unmodified official Safari asset | iOS / Safari 18.6 |

The canonical local evidence is:

- `firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-chrome-mv3-4.9.129.zip`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-chrome-mv3-4.9.129.LICENSE`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/darkreader-chrome-mv3-4.9.129.provenance.json`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite_2026.825.1619.safari.zip`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite_2026.825.1619.LICENSE`
- `firefox-ios/Floorp/NativeWebExtensions/Bundled/uBOLite_2026.825.1619.provenance.json`
- `firefox-ios/Floorp/NativeWebExtensions/FloorpNativeWebExtensionModels.swift`

Apple asks developers to provide special settings and review instructions in App Review
Information. Before each submission, compare this template with the current
[App Review page](https://developer.apple.com/app-store/review/) and
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially
the current public-API, self-contained-bundle, privacy, and intellectual-property sections.
