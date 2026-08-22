# Floorp iOS MV3 compatibility limitations

This matrix is the Stage 3 compatibility contract. It is derived from a pinned
fixture's manifest and rule corpus, not from a package-opening smoke test.
Every fixture run records its source commit, package SHA-256, licence, DNR
translation diagnostics, functional results, performance measurements, and
device/OS version in the profile-local compatibility evidence store.

| Area | Status | Floorp iOS behaviour |
| --- | --- | --- |
| Static, dynamic, and session DNR block rules | Supported subset | Rules that compile to WebKit content rules are attached without a resident event runtime. |
| DNR allow / allowAllRequests | Partial | Preserved only when the compiler proves that WebKit ordered actions keep the requested semantics; ambiguous priority is rejected. |
| DNR upgradeScheme | Supported subset | Compiles to WebKit `make-https` where conditions translate exactly. |
| DNR redirects | Unsupported | WebKit on the iOS 15 baseline has no general subresource redirect mapping. |
| DNR request/response header modification | Unsupported | WebKit content rules do not expose an equivalent. |
| DNR matched-rule feedback and automatic action badge counts | Unsupported | WebKit does not offer the necessary per-request callbacks. |
| Registered scripts and package-file execution | Supported subset | Scripts are validated before registration, planned before navigation, and injected only for granted hosts. |
| CSS insertion/removal | Supported subset | A native opaque handle binds every inserted stylesheet to its extension, tab, frame, and document generation. |
| Cosmetic / procedural / scriptlet filters | Supported subset | Generated resources run in the declared isolated or MAIN world. MAIN-world scripts never receive the native WebExtensions bridge. |
| Per-site access | Supported | Denied, selected-site, requested-site, private, and active-tab grants are checked for every privileged operation. |
| Exact Chromium DNR priority parity | Unsupported | Conflicting combinations are rejected rather than reported as enabled. |
| MV2 persistent backgrounds and webRequestBlocking | Unsupported | The MV3 event-runtime model has no persistent global/background page and WebKit has no blocking request API. |

## Release evidence required separately

Implementing the runtime does not approve a package for release. Before any
fixture or catalog item ships, product/legal must approve its source,
redistribution licence and notice/source obligations, the App Review evidence,
privacy/moderation treatment, supported OS range, and a reviewer exercise path.
Remote catalogs, document imports, and store-origin packages remain separately
gated and are not implied by this compatibility matrix.
