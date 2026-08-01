# Floorp for iOS branding specification

This document is the repository-level source of truth for product naming,
public links, and release identifiers. It separates user-facing branding from
inherited Firefox iOS implementation contracts so that upstream merges can be
reviewed without unsafe global search-and-replace operations.

Run `./scripts/ci/check-floorp-branding.sh` after an upstream merge and before
creating a public build.

## Product names

The desktop release branding defines the following names. iOS uses the same
capitalization and does not translate or transliterate `Floorp`.

| Context | Required value | Notes |
| --- | --- | --- |
| App display name and normal UI | `Floorp` | Use for the Home Screen, navigation titles, onboarding, Settings, and About. |
| Marketing name | `Floorp Browser` | Use in descriptive or marketing prose when a product category is useful. |
| Desktop full/installer name | `Ablaze Floorp` | Do not use as the normal iOS display name. |
| Vendor | `Ablaze` | Use only when the vendor or project relationship is relevant. |
| Project/community | `Floorp Projects` | This is not a substitute for the product or vendor name. |
| Desktop beta channel | `Floorp Daylight` | Do not use for the stable iOS app. |
| Lowercase technical stem | `floorp` | Use only in identifiers, schemes, file paths, and similar technical contexts. |

`AppName.shortName` must therefore be `Floorp`. A user-facing sentence must
not use `Firefox` as the subject when it means the installed iOS app.

When attribution is needed, use wording equivalent to:

> Floorp is based on Mozilla Firefox. Floorp is an independent project and is
> not affiliated with Mozilla or Firefox.

Do not imply that Mozilla publishes, operates, endorses, or supports Floorp.

## Public URLs

Top-level Floorp UI must use the Floorp-owned links below.

| Purpose | Canonical URL |
| --- | --- |
| Official site | `https://floorp.app` |
| Terms of Service | `https://floorp.app/terms` |
| Terms prompt Learn more/Here | `https://floorp.app/terms?utm_source=floorp-ios&utm_medium=in-product&utm_campaign=terms-of-use` |
| Privacy Policy | `https://floorp.app/privacy` |
| Floorp iOS Settings Help | `https://github.com/Floorp-Projects/floorp-ios#readme` |
| Desktop documentation (not iOS Help) | `https://docs.floorp.app` |
| Blog | `https://blog.floorp.app` |
| Release notes index | `https://blog.floorp.app/en/categories/release/` |
| Source and issue tracker | `https://github.com/Floorp-Projects/floorp-ios` |

Do not copy the desktop About dialog's legacy `ja.floorp.app` links or the old
`www.ablaze.one` and `blog.ablaze.one` installer links into iOS. Floorp legal
links must not silently fall back to the Mozilla Firefox Terms of Use or
Firefox Privacy Notice.

If a localized website route is introduced later, resolve it centrally and
keep the URLs in this table as the locale-neutral fallback.

Floorp does not yet publish a dedicated iOS support site or legal-update FAQ.
The iOS project page is therefore the current Settings Help hub, while the
Terms prompt uses the canonical legal document with a distinct in-product
campaign URL. Replace only the corresponding `FloorpBrand` constants when
dedicated pages become available; do not point either surface at the desktop
feature documentation.

Acceptance of inherited Mozilla terms is not acceptance of Floorp's legal
documents. A versioned, one-time migration clears the legacy Terms of Service
and Terms of Use acceptance, dismissal, reminder, experiment, and link-event
preferences before launch code checks consent. Once that migration marker is
stored, a user's subsequent Floorp acceptance and prompt state are preserved.
Increase the migration version only when a reviewed legal-document change
requires existing users to consent again.

## Names and links that remain Mozilla- or Firefox-specific

Some inherited names identify a third-party product, service, protocol, or
compatibility target. Keep these names when the UI is actually referring to
that thing:

- Mozilla and Mozilla Account;
- Firefox Sync, Firefox Suggest, Firefox Relay, and Firefox Focus/Klar;
- Pocket;
- Nimbus, Remote Settings, Mozilla Autopush, and Mozilla support content;
- Firefox or Mozilla terms and privacy notices shown as part of an explicitly
  identified Mozilla-provided service;
- Firefox compatibility labels used by WebCompat and the Firefox-compatible
  user agent.

The surrounding copy must make ownership clear. For example, a Mozilla
Account sign-in flow may say `Mozilla Account`, but the app title and the
button's subject remain `Floorp`. A top-level Floorp onboarding agreement must
link to Floorp Terms and Privacy; a separately identified Mozilla service may
link to its own service terms.

Do not mechanically replace the following inherited implementation names:

- Mozilla Public License headers and source attribution;
- the `firefox-ios` directory, `Client` target, or development `Fennec` scheme;
- `MOZ_*` build setting names and `Moz*` Info.plist keys consumed by the
  inherited runtime;
- source type names, telemetry metric identifiers, migration keys, or persisted
  preference keys unless a migration has been designed;
- the `firefox-focus` and `firefox-klar` query schemes, which identify other
  installed apps rather than Floorp.

These implementation names are not permission to expose Firefox as the Floorp
product name.

## Floorp data and external-service policy

`FloorpRelease` disables Glean upload, studies, rollouts, crash reporting,
daily usage reporting, Mozilla Unified Ads, sponsored shortcuts, and
SKAdNetwork/Adjust advertising attribution. The corresponding inherited
preferences are forced to `false` on every launch and their controls are not
shown as if they were user-configurable. The release plist contains no
SKAdNetwork IDs or Adjust token.

Unified Ads is blocked at the preference, provider, tile-manager, callback, and
settings layers. The inherited Google partner-attributed pinned tile is also
disabled. Floorp does not create a Unified Ads contextual identifier.
For an identifier left by an earlier Internal TestFlight build, Floorp clears
the local value immediately and makes a best-effort request to Mozilla's
deletion endpoint; a failed deletion remains pending and is retried on the
next launch.

Remote push notifications and the hosted summarizer also remain disabled.
Re-enabling any of these services requires an owner, endpoint/capability
review, precise in-product disclosure and control, Privacy Policy and App
Privacy updates, and production tests before the build is distributed.

Nimbus/Remote Settings configuration delivery and the Merino/Firefox Suggest
content APIs remain inherited Mozilla services. They are not Glean upload or
identifier-bearing advertising callbacks, but the release review must verify
their exact requests and describe this service boundary accurately in the
Floorp Privacy Policy and App Privacy answers.

Search-engine configuration also remains inherited. Desktop Floorp currently
uses Mozilla-origin partner codes for some engines, while iOS obtains its
mobile search configuration from Mozilla Remote Settings. Before public
distribution, confirm that the iOS partner codes and `firefoxIos` selector
identity are contractually authorized for Floorp; otherwise ship a
Floorp-owned static search configuration without those codes.

## iOS release identifiers

The following values are release contracts. Changing one requires coordinated
Apple Developer, App Store Connect, signing, runtime, and migration work.

| Identifier | Fixed value |
| --- | --- |
| Apple Team ID | `DV2U35YBHT` |
| Main bundle ID | `app.floorp.Floorp` |
| App Group | `group.app.floorp.Floorp.DV2U35YBHT` |
| Keychain group suffix | `app.floorp.Floorp` |
| Public URL scheme | `floorp` |
| Internal URL scheme | `floorp-internal` |
| Background sync task 1 | `app.floorp.sync.part1` |
| Background sync task 2 | `app.floorp.sync.part2` |
| Notification refresh task | `app.floorp.surface.notification.refresh` |
| Suggest ingestion task | `app.floorp.suggest.ingest` |
| Browsing user activity | `app.floorp.Floorp.browsing` |
| New-tab user activity | `app.floorp.Floorp.newTab` |

`MozSharedContainerIdentifier`, `MozPublicURLScheme`,
`MozInternalURLScheme`, and their `MOZ_*` build variables deliberately retain
their inherited names. Their values must resolve to the Floorp identifiers
above. A concrete `org.mozilla.*` bundle or App Group identifier and Mozilla's
Apple Team ID must never enter `FloorpRelease`.

The release plist expresses the two user activity identifiers as
`$(PRODUCT_BUNDLE_IDENTIFIER).browsing` and
`$(PRODUCT_BUNDLE_IDENTIFIER).newTab`. Runtime code derives the same values
from `AppInfo.bundleIdentifier`; the fixed values in the table are the resolved
`FloorpRelease` identifiers.

The initial `FloorpRelease` remains main-app-only. Before restoring an
extension, define and register its final bundle ID, App Group and keychain
access, capabilities, URL behavior, display name, artwork, localization, and
release tests as one reviewed change.

## User-facing assets and localized strings

- Product artwork must contain the Floorp logo. Renaming an inherited Firefox
  asset or image set is not sufficient.
- The classic app icon, Liquid Glass icon, launch screen, onboarding artwork,
  home header, main-app logo, and any enabled extension artwork must be
  inspected visually.
- Every localized `Client/*.lproj/InfoPlist.strings` permission description
  must name `Floorp`, not `Firefox`, when it names the requesting app.
- Preserve Apple feature names such as Face ID and third-party service names.
- Floorp-specific strings require at least English and Japanese review. Other
  inherited locales may use a narrowly scoped product-name substitution until
  a native translation is available; do not rewrite general translated prose.
- Accessibility labels, Siri/App Intent phrases, quick actions, notifications,
  widgets, share/action extensions, and credential-provider UI count as
  user-facing copy.

## Public-release checklist

1. Run `./scripts/ci/check-floorp-branding.sh` from the repository root.
2. Archive the shared `Floorp` scheme with `FloorpRelease`; do not distribute a
   `Fennec` build.
3. Inspect the archived app's display name, bundle ID, entitlements, App Group,
   keychain group, URL schemes, background task identifiers, icons, and embedded
   extensions.
4. Install the archive and inspect launch, onboarding, Home, private browsing,
   menus, tab tray, Settings, About, permission prompts, quick actions, app
   switcher, default-browser flow, and multi-window behavior in English and
   Japanese.
5. Open Terms, Privacy, Support, and source/feedback links from the app. Confirm
   that Floorp links are used for the Floorp product and Mozilla links appear
   only in clearly identified Mozilla-service contexts.
6. Review every retained endpoint, SDK, privacy manifest entry, App Privacy
   answer, permission purpose string, and data-collection toggle against actual
   `FloorpRelease` behavior.
7. Confirm that Push and Hosted Summarizer remain disabled unless Floorp has the
   required capability, service ownership, privacy disclosure, and production
   tests.
8. Verify App Store name, subtitle, description, keywords, screenshots,
   copyright, support URL, marketing URL, privacy URL, age rating, and review
   notes in App Store Connect.
9. If any extension is restored, repeat the full branding, signing, capability,
   localization, artwork, and privacy review for that extension.
10. Repeat this checklist after every upstream merge and before each external
    TestFlight or App Store submission.

The static check intentionally covers high-confidence invariants. It does not
replace visual inspection, localization review, endpoint ownership review, or
an archive inspection.
