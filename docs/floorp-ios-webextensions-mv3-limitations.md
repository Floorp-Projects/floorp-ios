# Floorp iOS MV3 compatibility limitations

This matrix is the intended Stage 3 compatibility contract. It is derived from
pinned, synthetic fixtures' manifests and rule corpora; it is not package-
opening or real-device evidence. The runtime provides a profile-local evidence
schema and optional store. This tree includes a simulator-only record generator
and a completed simulator record from a clean, SHA-attested worktree for native transformation,
WebKit compilation, localhost DNR-policy page-load, and Client-host memory
scopes. The resulting bundle and attachment remain local-only: no durable
release-evidence-store URI, archived artifact, or archival checksum has been
recorded. It is therefore not release evidence. The record is not a true cold
WebKit compiler measurement, full extension page-load workload, WebContent or
Network process memory, OS-delivered memory-pressure, device/OS, or UI
evidence; those release gates remain unrecorded here.

| Area | Status | Floorp iOS behaviour |
| --- | --- | --- |
| Static DNR block rules | Supported subset | Rules that compile to WebKit content rules are attached without a resident event runtime. |
| Dynamic and session DNR block rules | Partial | Transactional dynamic updates now persist through the profile package store and survive restart; session rules remain in memory and are discarded when the runtime ends. |
| DNR allow | Supported subset | Preserved only when the compiler proves that WebKit ordered actions keep the requested semantics; ambiguous priority is rejected. |
| DNR allowAllRequests | Unsupported | Rejected because the required per-frame policy attachment is not enabled by this compiler. |
| DNR upgradeScheme | Supported subset | Compiles to WebKit `make-https` where conditions translate exactly. |
| DNR redirects | Unsupported | WebKit on the iOS 15 baseline has no general subresource redirect mapping. |
| DNR request/response header modification | Unsupported | WebKit content rules do not expose an equivalent. |
| DNR matched-rule feedback and automatic action badge counts | Unsupported | WebKit does not offer the necessary per-request callbacks. |
| Registered content scripts | Supported subset | `scripting.registerContentScripts`, `updateContentScripts`, and `unregisterContentScripts` accept preflight-validated package resources and granted match patterns. Persistent registrations are supported only for an installed, active digest-pinned package backed by the profile package store; they are generation/resource-validated and restored at composition startup. `persistAcrossSessions: false` remains memory-only; omitted API values default to persistent. |
| Registered content-script `allFrames` | Supported subset | Isolated-world package scripts and styles perform a nonce-authenticated native authorization round trip in every frame immediately before package code runs. The native check uses the live profile/mode, package generation, document session, registered script ID, frame URL, match/exclude rules, host grant, and activeTab expiry. This makes document-start execution asynchronous. MAIN-world `allFrames` package bodies fail closed and do not execute because page code can tamper with any JavaScript-only frame guard while the native bridge is intentionally unavailable in MAIN. |
| `scripting.executeScript` | Supported subset | Only a non-empty `files` list of preflight-inventoried package JavaScript may execute in the current, settled top-level document after profile, host-access, and `scripting` permission checks. Function/source injection (`func`, `code`, and `args`), document IDs, subframes, `allFrames`, and arbitrary remote or document-provided code are rejected. |
| `scripting.insertCSS` / `removeCSS` | Supported subset | The standard CSS-text or package-CSS-file forms are accepted for the current, settled top-level document with `origin: "AUTHOR"` only. A native opaque handle is tracked by extension, tab, document generation, requested frame set, origin, and exact source; removal must reproduce that identity. `USER` origin, subframe, `allFrames`, and document-ID targeting are rejected. |
| Optional permissions | Supported subset with native consent | `permissions.getAll`, `contains`, and `remove` operate on the profile-local durable grant snapshot. `permissions.request` may request only manifest-declared optional API permissions and optional hosts. The bootstrapper supplies an application-owned visible-consent presenter that rechecks the enabled immutable package generation and browser profile/private mode before showing an allow/deny alert. A stale generation, absent presenter, cancellation, or a request outside the current profile is rejected; JavaScript and synthetic events are never consent. Catalog package distribution itself remains P0-gated. |
| Tabs query/create/update/reload/sendMessage | Supported subset | The profile- and private-mode-scoped host uses live app tabs, rejects stale document generations before delivery, and exposes only active/current query, URL navigation, reload, creation, and isolated-world content messaging. |
| Cosmetic / procedural / scriptlet filters | Supported subset | Only a bundled, digest-pinned package may declare the Floorp-specific `floorp_cosmetic_filter_resources` JSON resources. The closed schema applies per-resource and package-wide bounds to static selectors, `has-text` / `has-selector` / attribute-equality procedures, and the three reviewed scriptlets; remote lists, imported lists, arbitrary JavaScript, and dynamic cosmetic registration are rejected. Resources are main-frame-only and require the existing `scripting` and per-site host grants for each navigation. Generated resources run in the declared isolated or MAIN world; MAIN-world scripts never receive the native WebExtensions bridge. No catalog fixture currently declares one, so product/reviewer evidence for a catalog cosmetic filter remains unrecorded. |
| Per-site access | Supported | Denied, selected-site, requested-site, private, and active-tab grants are checked for every privileged operation. |
| Exact Chromium DNR priority parity | Unsupported | Conflicting combinations are rejected rather than reported as enabled. |
| Bundled MV3 background JavaScript | Supported subset | A preflight-verified bundled package may run `background.service_worker` (module or classic) or `persistent: false` `background.scripts` in a hidden, nonpersistent package-origin WebKit document. The runtime is created lazily for runtime messages and alarms, and is revoked on disable or generation replacement. |
| True ServiceWorker lifecycle and unrestricted background execution | Unsupported | The implementation is a restricted hidden page, not `ServiceWorkerGlobalScope`: `importScripts`, automatic idle eviction, arbitrary network fetch, remote/store-origin packages, and wake events beyond the supported runtime-message/alarm path are not available. |
| MV2 persistent backgrounds and webRequestBlocking | Unsupported | There is no persistent global/background page, and WebKit has no blocking request API. |

## Release evidence required separately

Implementing the runtime does not approve a package for release. Before any
fixture or catalog item ships, the sole Floorp iOS maintainer records P0
approval and verifies its source, redistribution licence, notice/provenance,
App Review evidence, privacy/moderation treatment, supported OS range, and a
reviewer exercise path. The ordinary PR, CI, protected-`main`, managed-signing,
physical-device/P5, and Apple review gates remain separate. Remote catalogs,
document imports, and store-origin packages remain prohibited by the shipping
contract and are not implied by this compatibility matrix.
