# Third-party WebExtensions: provenance and selection record

Status: **technical review only.** An MIT license and a public GitHub source do
not by themselves grant Floorp the legal/privacy/support approval required for
External TestFlight. Every adopted entry remains subject to `AGREEMENT_MISSING`
until Legal/Privacy records authorization and a support contact.

## Adopted compatibility builds

The app does not download these packages and does not execute upstream ZIP/CRX
binaries. Each is a small useful behavior selected from a pinned upstream
revision, rewritten into the supported MV3 subset, documented in `PATCH.txt`,
and normalized to FWEA1. The complete original-input SHA-256, normalized
artifact SHA-256, manifest/inventory digests, notices digest, and inspection
result are in `CuratedCatalog/review-index.json` and
`Review/<id>/inspection.json`.

All 13 third-party compatibility builds carry a review-only
`SourceProvenance/<id>.json` record. For the twelve generic compatibility
builds it pins the GitHub archive URL/root/SHA-256, upstream license member,
reviewed source-member hashes, and the local `LICENSE`, `NOTICE`,
`manifest.json`, and `PATCH.txt` derivation hashes. The managed signer must
receive exactly one real quarantined archive for each of those 13 records,
re-verify every binding, and preserve a separate provenance-evidence output
before a candidate can rely on them. For
`floorp.thirdparty.very-good-adblock`, the specialized record also requires
the exact `src/rules/static-rules.ts` member and its sixteen retained upstream
static `block` rule mappings. Synthetic regression archives test reject paths;
they are not proof that a candidate archive was re-fetched.
`verify_curated_source_provenance.py` is not packaged in the app and performs
no runtime fetch. These technical records do not themselves approve
redistribution, privacy, support, or author contact obligations.

| Floorp ID | Upstream / pinned revision | License | Retained local function | Legal release state |
| --- | --- | --- | --- | --- |
| `floorp.thirdparty.utm-stripper` | [jparise/chrome-utm-stripper](https://github.com/jparise/chrome-utm-stripper) `b1e83aa49cb7` | MIT | Cleans fixed tracking parameters from the current document and rendered links | pending authorization |
| `floorp.thirdparty.minimal-twitter` | [typefully/minimal-twitter](https://github.com/typefully/minimal-twitter) `64d834e9577d` | MIT | Fixed local focus/escape aid on X/Twitter | pending authorization |
| `floorp.thirdparty.refined-hacker-news` | [plibither8/refined-hacker-news](https://github.com/plibither8/refined-hacker-news) `ee7ef6d55ae1` | MIT | Keyboard story navigation and accessibility labels | pending authorization |
| `floorp.thirdparty.ekill` | [rhardih/ekill](https://github.com/rhardih/ekill) `fa1c474cced4` | MIT | Temporary local element hide/restore interaction | pending authorization |
| `floorp.thirdparty.medium-reading-layout` | [thebaer/MMRA](https://github.com/thebaer/MMRA) `0e53dcb8a102` | MIT | Fixed Medium article readability markers/style | pending authorization |
| `floorp.thirdparty.web-search-navigator` | [infokiller/web-search-navigator](https://github.com/infokiller/web-search-navigator) `b3364e74621f` | MIT | Keyboard selection of existing search result links | pending authorization |
| `floorp.thirdparty.github-dashboard` | [muan/github-dashboard](https://github.com/muan/github-dashboard) `4aca2d4e9fe2` | MIT | Filters GitHub dashboard content already on the page | pending authorization |
| `floorp.thirdparty.enhanced-github` | [softvar/enhanced-github](https://github.com/softvar/enhanced-github) `e245d813d95f` | MIT | Adds fixed local path labels to GitHub tree/blob links | pending authorization |
| `floorp.thirdparty.useful-forks` | [useful-forks/useful-forks.github.io](https://github.com/useful-forks/useful-forks.github.io) `8254d60e8586` | MIT | Filters rendered GitHub fork lists | pending authorization |
| `floorp.thirdparty.easy-to-rss` | [idealclover/Easy-to-RSS](https://github.com/idealclover/Easy-to-RSS) `c4f88670a696` | MIT | Announces a page-local RSS/Atom link | pending authorization |
| `floorp.thirdparty.scroll-to-top` | [pratikabu/scrolltotop](https://github.com/pratikabu/scrolltotop) `ec3db4664765` | MIT | Adds an accessible local scroll-to-top button | pending authorization |
| `floorp.thirdparty.refined-twitter` | [sindresorhus/refined-twitter](https://github.com/sindresorhus/refined-twitter) `bceb4440811f` | MIT | Applies a fixed local marker/style to rendered tweets | pending authorization |
| `floorp.thirdparty.very-good-adblock` | [chrisbbreuer/very-good-adblock](https://github.com/chrisbbreuer/very-good-adblock) `828148f94b12` | MIT | Fixed 16-rule, block-only DNR subset for advertising/tracking hosts | pending authorization |

### Exact immutable compatibility-build records

The following values are copied from the deterministic unsigned catalog input
that the managed signer will sign. `original SHA-256` is the frozen upstream
input recorded before Floorp's compatibility reduction; `FWEA1 SHA-256` is the
immutable normalized package that the iOS client verifies. Every row is an
`opt-in` private-profile candidate. None has a remote executable, remote DNR
list, `update_url`, or a client-side download path.

| Floorp ID | Floorp version / immutable generation | Original SHA-256 | FWEA1 SHA-256 | Declared APIs / host patterns | Recorded compatibility modification |
| --- | --- | --- | --- | --- | --- |
| `floorp.thirdparty.utm-stripper` | `2.12.0` / `g20260826-thirdparty-utm-stripper` | `55351ab8e93c3701bfab5ebd300ace16c7495341766f7508182f1a90ba27ee09` | `bc946caf8ab7fbc2077f35dec06b007c55515be5e43314251e8453e4c2a763a3` | `storage` / `https://*/*` | `PATCH.txt`; fixed local document/link cleaner and popup, no upstream request interception |
| `floorp.thirdparty.minimal-twitter` | `1.0.0` / `g20260826-thirdparty-minimal-twitter` | `ac5956e69792f3c02d8f9d202acfdfd01693d405182e6842dab35226a5019e5e` | `5b8170c0fe6e2e9358f7de7c7caad0f6e7a8075760d46fc56ca377f1af250e59` | none / `https://twitter.com/*`, `https://x.com/*` | `PATCH.txt`; retained local focus/escape behavior only |
| `floorp.thirdparty.refined-hacker-news` | `1.0.0` / `g20260826-thirdparty-refined-hacker-news` | `fb0157d83b22eaee14e30c6585e68f3f5d71cfcd578f39855ab538b4c1346b03` | `efdada6572de5a05ff06e704971716429964499a70a45a0a6141a21c6edb34c1` | none / `https://news.ycombinator.com/*` | `PATCH.txt`; retained keyboard navigation and labels |
| `floorp.thirdparty.ekill` | `1.9.0` / `g20260826-thirdparty-ekill` | `234ec4de9fc0091aae995532265afebc7e8127b0003b19ed95fd47819eaeb96b` | `2c08345418b096aa2598238b52f0f117fd6d61eddd6b5d61ef811e3d9facee4d` | none / `https://*/*` | `PATCH.txt`; retained temporary local hide/restore only |
| `floorp.thirdparty.medium-reading-layout` | `1.5.1` / `g20260826-thirdparty-mmra` | `e19f32b8ba31d780bc08a66986b5e46ab12060298b78dc861e4a4e3c1ac7d51a` | `83a307980ac272e9e6c08c1921748de63440370ac8533e6e1d12babc04b9e344` | none / `https://medium.com/*` | `PATCH.txt`; retained article readability treatment only |
| `floorp.thirdparty.web-search-navigator` | `1.0.0` / `g20260826-thirdparty-web-search-navigator` | `fb3b398f3ac11eeb12a2a9dbcd329ee461c99b46b87d44a67e70dcd3d3e8ec51` | `a82ca8e3a39ef8edaa7376f47cd6502947dbbbbd909c424da6086c9cdb9d4cc3` | none / Google, Bing, GitHub Search | `PATCH.txt`; retained fixed result-key navigation only |
| `floorp.thirdparty.github-dashboard` | `0.8.8` / `g20260826-thirdparty-github-dashboard` | `aaf2fa3e6ff1049d941a639cfbadf099929d002ccbb919756c5354b211511840` | `deb3b4ffaf0b7b4fc781d8310394a3b11f91862e389a420c6066d14aa8142d69` | none / GitHub dashboard | `PATCH.txt`; retained local rendered-list filter only |
| `floorp.thirdparty.enhanced-github` | `1.0.0` / `g20260826-thirdparty-enhanced-github` | `b6083814b9349e96b3b43f3284f30c273e286b64fcd91133318d7a3f4856550e` | `a9608d1a3795867741e85984a56564fd8a950c23e6541d74a48c8a9c45782e67` | none / `https://github.com/*` | `PATCH.txt`; retained local tree/blob path labels only |
| `floorp.thirdparty.useful-forks` | `1.0.0` / `g20260826-thirdparty-useful-forks` | `b7bf5746a388c3e3ce30f81bd0e3532af30e0e2729d2786f86bc564478be315c` | `c794f7a211b24b284046b7b58c7a1af030cc179868b9d9ef1aa1d5d64636583e` | none / `https://github.com/*/forks` | `PATCH.txt`; retained local rendered-fork filter only |
| `floorp.thirdparty.easy-to-rss` | `0.2.0` / `g20260826-thirdparty-easy-to-rss` | `4d829b6cc03035e7d23a33037da9d662d0db5de25dce3e60e0589b7c3ab4c2f9` | `ccea21a177196f76e55b2b42d0ffdc8c06a0c3da5993d8cfa5017bb9e03ba38d` | `storage` / `https://*/*` | `PATCH.txt`; retained page-local feed discovery and popup only |
| `floorp.thirdparty.scroll-to-top` | `1.0.0` / `g20260826-thirdparty-scrolltotop` | `c0953a05d96775d98c69430a830e1690be260d961b6c90efb2d2cf293d48a6dd` | `f4e2c388bf0a03468e1eb1bdf07439f9ce62033c162c896f63aea8524bf83f95` | none / `https://*/*` | `PATCH.txt`; retained one accessible local control only |
| `floorp.thirdparty.refined-twitter` | `1.0.0` / `g20260826-thirdparty-refined-twitter` | `9db815c188f7ce413e0282774a29c0158775494ca6a08f408056d3831bdd7133` | `c9b7a9ceb57ca727d4887cefdfa7453f401b38d8efd65376db653d37acca3c6f` | none / `https://twitter.com/*`, `https://x.com/*` | `PATCH.txt`; retained fixed local tweet marker/style only |
| `floorp.thirdparty.very-good-adblock` | `1.0.0` / `g20260826-thirdparty-very-good-adblock` | `1f7e2a0560a2d5e606893993a470a342d21ed314ae5d94a9ec468259283f3fc4` | `85b77dadf2e4e0faa160a1403696cf2e0d528d649b84227cd4926c85b41c9ffe` | `declarativeNetRequest` / none | `PATCH.txt` + source-provenance record; retained mapped 16 static `block` rules only; removed redirect, dynamic rules, remote refresh, telemetry, reports, and UI |

Floorp-managed Site Appearance, Tracker Block Lite, and Session Timer are in
[the catalog inventory](EXTENSION_CATALOG.md). The current technical inventory
therefore has 16 immutable packages: 13 third-party compatibility builds and
three Floorp-managed packages. It includes 13 content-script packages, two
static DNR packages, three action-bearing packages, and more than two packages
with explicit host permissions. The DNR compatibility build and Web Search
Navigator are the higher-complexity representatives; both remain constrained
to the closed API contract rather than retaining their upstream breadth.

## Initial assessed set

The following set of more than 20 candidates was screened for user value and compatibility.
“Deferred/rejected” is not a security verdict on the upstream project. It says
that the current closed iOS API contract cannot safely implement the claimed
feature without a materially broader review.

| Candidate | Decision | Reason at this stage |
| --- | --- | --- |
| chrome-utm-stripper | adopted as constrained build | Local link/document sanitizer replaces `webRequest` behavior |
| minimal-twitter | adopted as constrained build | Fixed content-script behavior only |
| refined-hacker-news | adopted as constrained build | Local keyboard/accessibility subset |
| ekill | adopted as constrained build | No network or persistent page modification |
| MMRA | adopted as constrained build | Fixed page-local layout subset |
| web-search-navigator | adopted as constrained build | Fixed result navigation subset |
| github-dashboard | adopted as constrained build | Local filtering of rendered content |
| enhanced-github | adopted as constrained build | Fixed DOM annotation subset |
| useful-forks | adopted as constrained build | Local rendered-list filtering subset |
| Easy-to-RSS | adopted as constrained build | Page-local feed discovery subset |
| scrolltotop | adopted as constrained build | Small accessible control |
| refined-twitter | adopted as constrained build | Fixed local marker/style subset |
| Dark Reader | deferred | Dynamic style generation and broad page behavior need a separate review |
| ClearURLs | deferred | LGPL-3.0 source plus a large rule maintenance/update model and broad URL rewriting need policy approval; no ClearURLs data is shipped |
| uBlock Origin Lite | deferred | Large DNR rule corpus and performance/error-reporting evidence are not yet available |
| Privacy Badger | deferred | Learning/heuristics exceed the fixed static rule model |
| NoCoin | deferred | Rule source/update/false-positive policy needs a dedicated DNR review |
| Refined GitHub | deferred | Larger API surface and high UI churn than the constrained GitHub subsets |
| Linkclump | deferred | Broad pointer/selection automation needs interaction and accessibility review |
| Global Privacy Control | rejected for current scope | Requires request-header modification, which the DNR contract rejects |
| Vimium C | deferred | Broad keyboard command/navigation needs a separate private/accessibility model |
| SingleFile | rejected for current scope | Download/file/export capabilities are outside the supported API subset |
| Auto Tab Discard | rejected for current scope | Tab lifecycle/background authority is not supported |
| SponsorBlock | rejected for current scope | Remote data service and media control are outside the fixed-local model |
| LanguageTool | rejected for current scope | Remote text processing would need a separate privacy/service review |
| I still don't care about cookies | deferred | Large maintained rule list needs false-positive and update governance |
| Very Good AdBlock | adopted as constrained DNR build | Pinned MIT source; retained static `block` subset only; redirect, remote refresh, dynamic rules, telemetry, reports, and UI removed |
| AdGuard MV3 | deferred | DNR scale and performance budget need device measurements first |
| Stylus | rejected for current scope | User-authored arbitrary CSS is not a curated immutable resource |
| Tampermonkey | rejected for current scope | User-authored arbitrary JavaScript violates the code-origin boundary |
| Enhancer for YouTube | deferred | Media/page integration and broad host behavior need a separate review |
| Return YouTube Dislike | rejected for current scope | Remote API/data dependency is not allowed |

## Review before a new item can be adopted

1. Pin the upstream revision and capture the original input SHA-256.
2. Verify license, notice obligations, redistribution/update/support authority,
   privacy declaration, and contact/report path.
3. Reduce the behavior to the supported local MV3 subset and record every
   change in `PATCH.txt`; never silently rewrite an upstream package.
4. Run ingestion quarantine and review the FWEA1 artifact/manifest/inventory
   digests and inspection findings.
5. Test normal/private profile behavior, site grant, disable, uninstall,
   update, and revocation for the exact immutable artifact.
6. Obtain Product, Security, and Legal/Privacy approval before managed signing.

The selection record must also name the requested APIs and host scope, whether
the upstream has remote code/filter data, its update and support posture, the
exact source/archive digest, and every compatibility removal. For the adopted
items, those fields live in `catalog-sources.json`, `NOTICE`, `PATCH.txt`, and
the generated review index so that catalog metadata alone is never the sole
provenance record.
