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
and uBlock Origin Lite. They are not downloaded after review: the reviewed extension ZIPs,
their JavaScript/CSS, filter rules, license notices, and provenance records are all
self-contained in this app bundle. Floorp does not provide arbitrary ZIP import or a remote
extension catalog.

Implementation:
- Floorp uses only Apple's public WKWebExtension, WKWebExtensionContext, and
  WKWebExtensionController APIs.
- Each extension is disabled until the user chooses Settings > Extensions > the extension >
  Install and confirms the displayed source, license, permissions, and website access.
- Private Browsing access is off by default and requires a separate explicit user action.
- Dark Reader's <all_urls> access is used to apply the user's selected dark appearance to
  visited pages. uBlock Origin Lite's <all_urls> access is used so WebKit can apply
  declarative network rules, cosmetic CSS, and content-filtering scripts. Processing is
  performed locally by WebKit.

Bundled third-party open-source components:
- Name: Dark Reader
- Publisher: Dark Reader Ltd. and contributors
- Version/release: 4.9.129 / v4.9.129
- License: MIT
- Distribution: the unmodified official Chrome MV3 release asset
- Asset: darkreader-chrome-mv3-4.9.129.zip
- SHA-256: 20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64
- Upstream release and asset:
  https://github.com/darkreader/darkreader/releases/tag/v4.9.129
- Upstream corresponding source commit:
  https://github.com/darkreader/darkreader/tree/c2a707302a39b8047543712e9c582bac07835d34

- Name: uBlock Origin Lite
- Author: Raymond Hill and contributors
- Version/release: 2026.825.1619
- License: GNU General Public License v3.0 or later (GPL-3.0-or-later)
- Distribution: the unmodified official Safari release asset
- Asset: uBOLite_2026.825.1619.safari.zip
- SHA-256: 89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94
- Upstream release and asset:
  https://github.com/uBlockOrigin/uBOL-home/releases/tag/2026.825.1619
- Upstream corresponding source commit:
  https://github.com/uBlockOrigin/uBOL-home/tree/080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b
- Floorp source for this submitted binary:
  https://github.com/Floorp-Projects/floorp-ios/tree/[RELEASE_TAG_OR_FULL_COMMIT]
- The Dark Reader MIT notice and complete uBlock Origin Lite GPL text are separate resources
  in the app bundle and retained in Floorp's public source tree beside their assets. The
  official uBlock Origin Lite ZIP also contains its complete LICENSE.txt.

Compatibility and known limitation:
- The app's native extension host and Dark Reader are available from iOS 18.4. This uBlock
  Origin Lite package declares Safari/iOS 18.6 as its strict minimum and Floorp enforces
  that value.
- Standard network blocking, dynamic/session rules, cosmetic filtering, Japanese rules,
  action popup, options, normal browsing, and explicitly authorized Private Browsing were
  tested with the bundled asset.
- uBlock Origin Lite's strict-block interstitial is disabled by its official Safari build
  because of an upstream WebKit limitation. Normal request blocking and cosmetic filtering
  remain active. Floorp has not modified the GPL package to bypass this limitation.

No account or sign-in is required for review.

Review steps on iOS 18.6 or later:
1. Launch Floorp and open Settings > Extensions.
2. Under "Available from Floorp", select "uBlock Origin Lite".
3. Review the source/license/permission sheet and tap Install.
4. Browse a normal web page, then open the Floorp menu > Extensions > uBlock Origin Lite
   to inspect its action popup.
5. Return to Settings > Extensions > uBlock Origin Lite > Options to inspect its dashboard
   and filter-list controls.
6. Private Browsing remains unavailable to the extension unless "Allow in Private
   Browsing" is explicitly selected from the installed-extension actions.
7. Dark Reader can be independently installed from Settings > Extensions and inspected from
   the same Floorp menu without an account.

Please contact us through App Store Connect if you need a source archive, test details, or
additional licensing information for this build.
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
