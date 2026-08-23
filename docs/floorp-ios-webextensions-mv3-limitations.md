# Floorp iOS MV3 compatibility limitations

This matrix is the intended Stage 3 compatibility contract. It is derived from
pinned, synthetic fixtures' manifests and rule corpora; it is not package-
opening, real-device, or performance evidence. The runtime provides a
profile-local evidence schema and optional store, but this tree does not yet
contain recorded device/OS, benchmark, or UI evidence.

| Area | Status | Floorp iOS behaviour |
| --- | --- | --- |
| Static DNR block rules | Supported subset | Rules that compile to WebKit content rules are attached without a resident event runtime. |
| Dynamic and session DNR block rules | Partial | Transactional dynamic updates now persist through the profile package store and survive restart; session rules remain in memory and are discarded when the runtime ends. |
| DNR allow / allowAllRequests | Partial | Preserved only when the compiler proves that WebKit ordered actions keep the requested semantics; ambiguous priority is rejected. |
| DNR upgradeScheme | Supported subset | Compiles to WebKit `make-https` where conditions translate exactly. |
| DNR redirects | Unsupported | WebKit on the iOS 15 baseline has no general subresource redirect mapping. |
| DNR request/response header modification | Unsupported | WebKit content rules do not expose an equivalent. |
| DNR matched-rule feedback and automatic action badge counts | Unsupported | WebKit does not offer the necessary per-request callbacks. |
| Registered scripts and package-file execution | Supported subset | Scripts are validated before registration, planned before navigation, and injected only for granted hosts. |
| CSS insertion/removal | Supported subset | A native opaque handle binds every inserted stylesheet to its extension, tab, frame, and document generation. |
| Tabs query/create/update/reload/sendMessage | Supported subset | The profile- and private-mode-scoped host uses live app tabs, rejects stale document generations before delivery, and exposes only active/current query, URL navigation, reload, creation, and isolated-world content messaging. |
| Cosmetic / procedural / scriptlet filters | Supported subset | Generated resources run in the declared isolated or MAIN world. MAIN-world scripts never receive the native WebExtensions bridge. |
| Per-site access | Supported | Denied, selected-site, requested-site, private, and active-tab grants are checked for every privileged operation. |
| Exact Chromium DNR priority parity | Unsupported | Conflicting combinations are rejected rather than reported as enabled. |
| Bundled MV3 background JavaScript | Supported subset | A preflight-verified bundled package may run `background.service_worker` (module or classic) or `persistent: false` `background.scripts` in a hidden, nonpersistent package-origin WebKit document. The runtime is created lazily for runtime messages and alarms, and is revoked on disable or generation replacement. |
| True ServiceWorker lifecycle and unrestricted background execution | Unsupported | The implementation is a restricted hidden page, not `ServiceWorkerGlobalScope`: `importScripts`, automatic idle eviction, arbitrary network fetch, remote/store-origin packages, and wake events beyond the supported runtime-message/alarm path are not available. |
| MV2 persistent backgrounds and webRequestBlocking | Unsupported | There is no persistent global/background page, and WebKit has no blocking request API. |

## Release evidence required separately

Implementing the runtime does not approve a package for release. Before any
fixture or catalog item ships, product/legal must approve its source,
redistribution licence and notice/source obligations, the App Review evidence,
privacy/moderation treatment, supported OS range, and a reviewer exercise path.
Remote catalogs, document imports, and store-origin packages remain separately
gated and are not implied by this compatibility matrix.
