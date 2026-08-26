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
