# Curated WebExtension compatibility contract

This document describes the executable compatibility boundary for the signed
catalog. The authoritative broader matrix remains
[MV3 compatibility limitations](floorp-ios-webextensions-mv3-limitations.md).
An upstream extension is never “mostly supported”: a manifest/resource using an
unsupported API or DNR action rejects the immutable artifact before install.

## Supported profiles

| Profile | Catalog packages | Supported contract | Isolation / lifecycle |
| --- | --- | --- | --- |
| `content-script` | Site Appearance and 12 constrained third-party builds | Fixed manifest-declared JS/CSS, document start/end, bounded isolated-world runtime message path | Native host grant and profile/private checks on every navigation; disable/uninstall/revocation stop execution |
| `dnr` | Tracker Block Lite and Very Good AdBlock compatibility build | Static reviewed DNR rules; supported `block` action only | Rules are profile-scoped; runtime replacement/removal is transactional |
| `action-storage` | Session Timer, Tracking Token Stripper, and Easy to RSS | Manifest action popup, options page where declared, local/session storage, alarms where declared, fixed runtime messages | Package-origin pages only; normal/private storage and alarms do not mix |

Every catalog record declares all profiles it needs. The app verifies the
record-to-manifest relationship when installing and restoring, so metadata
cannot describe a safer profile than the actual fixed resource set.

## Permission and private-profile behavior

- Normal site access begins as denied. A user chooses the requested site scope
  through a native Floorp control; JavaScript cannot grant it.
- A catalog entry explicitly says whether private profile support is
  `not-supported`, `opt-in`, or `supported`. The release candidate uses the
  conservative `opt-in` path for its catalog packages.
- Enabling private browsing creates an independent ephemeral package instance.
  It starts with private site access denied and does not clone normal storage,
  DNR configuration, package files, runtime objects, or grants.
- Disable preserves durable extension data; explicit uninstall removes
  profile-owned package data. Revocation immediately stops runtime/DNR/page
  hosts and retains data until the approved deletion policy says otherwise.
- A new generation with increased API/host/DNR/private authority is inactive
  until an in-app native confirmation, bound to the installed generation and
  replacement artifact digest, succeeds. A cancelled/stale/unpresentable
  confirmation rejects the update.

## DNR action boundary

The following actions are accepted only when they can be represented safely by
the native DNR/WebKit implementation:

| Accepted in this catalog | Rejected artifact-wide |
| --- | --- |
| `block` (Tracker Block Lite and Very Good AdBlock) | `allow`, `allowAllRequests`, `upgradeScheme`, `redirect` |
| Reviewed static rule resources | request/response header modification |
| Profile-local native site exclusion for an already accepted static block rule | dynamic/session extension rules, matched-rule feedback, unsupported priority semantics, remote/imported lists |

The compatibility builder and the iOS package preflight both enforce this
boundary. The signed-catalog package-store boundary repeats the block-only
check during install and restart restoration, so a generic Stage 3-compatible
`upgradeScheme` artifact cannot enter the external catalog. An unsupported
action is not silently ignored.

Floorp may additionally apply a native per-site exclusion only to an already
accepted static `block` rule. The input is a canonical top-level HTTP(S)
domain selected in native UI, stored per profile, and compiled atomically into
WebKit's `unless-top-url` condition. It does not turn the extension's DNR API
into an allow-list API: `allow`, `allowAllRequests`, `ignore-previous-rules`,
extension-supplied `excludedInitiatorDomains`, and all dynamic/session rule
exceptions remain rejected.

## Action, pages, storage, and alarms

- If `action.default_popup` is declared, popup content must be a fixed
  immutable package resource. If no action is declared, the Extensions menu
  displays a safe empty state rather than constructing a missing page host.
- `options_ui.page` is similarly package-origin-only. An external URL opens as
  an ordinary browser tab and receives no extension authority.
- `storage.local`, `storage.session`, `alarms`, and supported runtime messages
  are profile-scoped. `storage.sync`, unrestricted background pages,
  `importScripts`, remote module loading, and arbitrary fetch are not part of
  the supported catalog contract.

## Per-package verification matrix

This is the current source-bound compatibility record for every immutable
package. “Install/start” means the FWEA1 preflight, profile-scoped activation,
and lifecycle test route passed locally; it does **not** claim that a managed
production signature or TestFlight build exists. The functional column names
the behavior exercised by `curated_catalog_functional.mjs` against local Web
content. A real signed-device pass remains a P5 release gate.

| Catalog package | Install/start and primary functional evidence | Content script / DNR / UI / network | Normal and private profiles | Update and known limitations |
| --- | --- | --- | --- | --- |
| Floorp Site Appearance | Preflight then site-grant activation; adds local readability class/style to an allowed document | content script / — / no extension page / no network | normal grant starts denied; private copy is separate opt-in and also denied | digest-bound update confirmation; users cannot author arbitrary CSS |
| Floorp Tracker Block Lite | Preflight then static rule installation; reviewed tracker host request is blocked | — / static `block` / native per-site exclusion / no network | static rules and exclusions are profile-local; private is separate opt-in | digest-bound update confirmation; no redirect, headers, allow, or dynamic/session rules |
| Floorp Session Timer | Popup/options/background page host starts a bounded alarm; completion timestamp is stored | — / — / popup + options + alarms/storage / no network | storage and alarms do not cross profiles; private data is ephemeral | digest-bound update confirmation; no sync or arbitrary background fetch |
| Tracking Token Stripper | Content-script activation removes UTM/gclid parameters from current URL and links; popup shows/reset count | content script / — / popup + local storage / no network | host access is separately granted per profile; counts never mix | digest-bound update confirmation; does not intercept requests or redirect traffic |
| Minimal Twitter | Content script applies the focus/escape aid on X/Twitter | content script / — / no extension page / no network | host access and private installation are separate | digest-bound update confirmation; only the retained local interaction is supported |
| Refined Hacker News | Content script adds keyboard story navigation and accessible rank labels | content script / — / no extension page / no network | Hacker News grant and private copy are separate | digest-bound update confirmation; no upstream broader UI/API set |
| ekill | Content script marks hovered element; keyboard hide/restore changes only current page DOM | content script / — / no extension page / no network | page mutation is limited to the enabled profile and granted site | digest-bound update confirmation; no persistent or cross-site element policy |
| Medium Reading Layout | Content script marks the rendered Medium article for local readability treatment | content script / — / no extension page / no network | Medium host grant and private copy are separate | digest-bound update confirmation; no dynamic style generator or remote site-fix data |
| Web Search Navigator | Content script focuses and marks the next existing Google/Bing/GitHub-search result | content script / — / no extension page / no network | each search host grant is profile-scoped and starts denied | digest-bound update confirmation; no broad keyboard-command/navigation runtime |
| GitHub Dashboard Filter | Content script inserts a local filter that mutes nonmatching rendered dashboard rows | content script / — / no extension page / no network | GitHub dashboard grant and private copy are separate | digest-bound update confirmation; no GitHub API/network client |
| Enhanced GitHub | Content script adds path labels to rendered GitHub tree/blob links | content script / — / no extension page / no network | GitHub host grant and private copy are separate | digest-bound update confirmation; no file editing, downloads, or broad upstream feature set |
| Useful Forks | Content script locally filters rendered GitHub forks list | content script / — / no extension page / no network | GitHub forks grant and private copy are separate | digest-bound update confirmation; no server-side ranking or remote data |
| Easy to RSS | Content script finds an existing page-local feed link; popup displays stored discovery | content script / — / popup + local storage / no network | feed discovery and popup state stay profile-local | digest-bound update confirmation; no subscription service or remote feed fetch |
| Scroll To Top | Content script adds an accessible button and scrolls the current page to the top | content script / — / no extension page / no network | host grant and private copy are separate | digest-bound update confirmation; no global user-script injection |
| Refined Twitter | Content script marks rendered tweets for fixed local styling | content script / — / no extension page / no network | X/Twitter grants and private copy are separate | digest-bound update confirmation; no dynamic social API or remote rules |
| Very Good AdBlock | Preflight accepts exactly 16 static block rules; advertising/tracking request matching is blocked | — / static `block` / native per-site exclusion / no network | rules and exclusions are profile-local; private is separate opt-in | digest-bound update confirmation; no redirect, cosmetic remote list, telemetry, report, or dynamic/session rules |

## Known non-compatible APIs and patterns

The following are intentionally not adopted by this catalog:

- MV2 and persistent/service-worker lifecycle assumptions outside the existing
  bounded page-host model;
- `webRequestBlocking`, `debugger`, `nativeMessaging`, broad tabs/downloads/
  filesystem APIs, user-script managers, and arbitrary code injection;
- `eval`, `Function`, `scripting.executeScript` code/func payloads, remote JS,
  remote WASM, remote DNR/cosmetic-filter subscriptions, and `update_url`;
- DNR redirect/header modification/allow-all/matched-rule-feedback actions;
- `storage.sync`, arbitrary background fetch, dynamic imported scripts, and
  a Chrome Web Store/Firefox Add-ons/URL/ZIP/CRX/shared-sheet install flow.

An item needing one of these is deferred or rejected, not weakened into an
incomplete catalog entry. See [the third-party selection record](THIRD_PARTY_EXTENSIONS.md).
