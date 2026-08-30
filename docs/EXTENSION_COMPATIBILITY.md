# Curated WebExtension compatibility contract

This document describes the executable compatibility boundary for the signed
catalog. The authoritative broader matrix remains
[MV3 compatibility limitations](floorp-ios-webextensions-mv3-limitations.md).
An upstream extension is never “mostly supported”: a manifest/resource using an
unsupported API or DNR action rejects the immutable artifact before install.

## Supported profiles

| Profile | Catalog packages | Supported contract | Isolation / lifecycle |
| --- | --- | --- | --- |
| `content-script` | Dark Reader | Fixed manifest-declared JS/CSS, document start/end, bounded isolated-world runtime message path | Native host grant and profile/private checks on every navigation; disable/uninstall/revocation stop execution |
| `action-storage` | Dark Reader | Manifest action popup, package-origin settings page, local/session/device-local sync storage, alarms, and fixed runtime messages | Package-origin pages only; normal/private storage and alarms do not mix |

The compatibility layer also has a reviewed static DNR `block` contract, but
the current catalog contains no DNR package. A future package may use any
supported profile only after its exact artifact passes compatibility review,
provenance verification, catalog signing, and release approval.

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
| Reviewed static `block` rules | `allow`, `allowAllRequests`, `upgradeScheme`, `redirect` |
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
- `storage.local`, `storage.session`, `storage.sync`, `alarms`, and supported
  runtime messages are profile-scoped. `storage.sync` is a durable device-local
  compatibility namespace, never an account or cloud synchronization service.
  Unrestricted background pages, `importScripts`, remote module loading, and
  arbitrary fetch are not part of the supported catalog contract.
- Package pages and bundled backgrounds may fetch only their own reviewed
  package resources under the fixed extension-page policy. Dark Reader uses
  this for its packaged configuration corpus; remote configuration, news, and
  update endpoints are not available.
- `runtime.getManifest`, synchronous Chrome i18n lookup, and package-resource
  `action.setIcon` are available to the bounded bridge. `fontSettings` maps
  only to the iOS generic-font fallback; it never exposes device font settings.

## Per-package verification matrix

This is the current source-bound compatibility record for every immutable
package. “Install/start” means the FWEA1 preflight, profile-scoped activation,
and lifecycle test route passed locally; it does **not** claim that a managed
production signature or TestFlight build exists. The functional column names
the behavior exercised by `curated_catalog_functional.mjs` against local Web
content. A real signed-device pass remains a P5 release gate.

| Catalog package | Install/start and primary functional evidence | Content script / DNR / UI / network | Normal and private profiles | Update and known limitations |
| --- | --- | --- | --- | --- |
| Dark Reader | Bundled MV3 background, popup, and content scripts apply its local appearance transformation after a site grant | content scripts / — / popup + device-local storage + alarms / bundled configuration only | site grants and local/sync settings are profile-local; private data is ephemeral | digest-bound update confirmation; no cloud sync, context menus, desktop commands, remote config/news/update fetch, or native font preferences |

## Known non-compatible APIs and patterns

The following are intentionally not adopted by this catalog:

- MV2 and persistent/service-worker lifecycle assumptions outside the existing
  bounded page-host model;
- `webRequestBlocking`, `debugger`, `nativeMessaging`, broad tabs/downloads/
  filesystem APIs, user-script managers, and arbitrary code injection;
- `eval`, `Function`, `scripting.executeScript` code/func payloads, remote JS,
  remote WASM, remote DNR/cosmetic-filter subscriptions, and `update_url`;
- DNR redirect/header modification/allow-all/matched-rule-feedback actions;
- cloud `storage.sync`, arbitrary background fetch, dynamic imported scripts,
  and a Chrome Web Store/Firefox Add-ons/URL/ZIP/CRX/shared-sheet install flow.

An item needing one of these is deferred or rejected, not weakened into an
incomplete catalog entry. See [the third-party selection record](THIRD_PARTY_EXTENSIONS.md).
