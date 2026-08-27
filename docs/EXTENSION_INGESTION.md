# Curated WebExtension ingestion

This is a build/review boundary. It is intentionally separate from the iOS
installer: the shipping app never parses ZIP, XPI, CRX, shared-sheet files,
local files, source trees, or arbitrary HTTPS inputs.

## Accepted only as untrusted review input

`scripts/webextensions/ingest_extension.py` may be run by a reviewer on:

- a local unpacked source directory;
- a downloaded ZIP/XPI;
- a CRX v2/v3 container after the CRX envelope is stripped; or
- a source revision fetched from an approved upstream URL.

An HTTPS URL is not itself an install authority. The reviewer must first bind
the input to a source URL, immutable upstream revision, license, and original
SHA-256 in `catalog-sources.json`. The resulting iOS catalog has no API to
accept that URL, archive, or revision directly.

## Quarantine and normalization

The ingestion tool rejects before artifact creation when it sees, among other
things:

- archive size, expanded-size, file-count, compression-ratio, or per-file
  limits exceeded;
- ZIP Slip paths, absolute paths, symlinks, duplicate/case/NFC-colliding
  paths, unlisted archive members, or unsafe resource suffixes;
- malformed/duplicate-key manifest JSON, MV2, unknown manifest keys, or a
  manifest that fails the closed Floorp MV3 preflight;
- `update_url`, remote JavaScript/WASM, an unbound remote executable or DNR
  list, dynamic code (`eval`/`Function`), `webRequestBlocking`, `debugger`,
  `nativeMessaging`, or unsupported DNR actions;
- a compatibility patch that is not a separately recorded narrow JSON patch.

It writes an inspection record with input SHA-256, normalized-tree SHA-256,
manifest and inventory digests, every finding, and the patch digest. It then
emits one deterministic non-compressed `FWEA1` file. `FWEA1` has a canonical
header and fixed per-resource inventory; it is the only artifact format the
iOS client decodes.

An ordinary HTTPS endpoint found in a reviewed package is an **inspection
warning**, not an automatic rejection and not an execution approval. The
reviewer must classify it as user-initiated data, fixed image/CSS/data,
remote configuration, or a signed/digest-pinned data feed; record endpoint
origin, purpose, retention/privacy impact, cache/refresh behavior, expected
content type/size, and failure behavior. A remote executable remains a hard
reject. The first signed-bundled candidate contains no such runtime endpoint;
enabling any future feed requires a separately approved client transport and
catalog metadata that binds its allow-listed origin, version, digest,
signature, and rollback policy. It must never turn a URL or discovery result
into executable installation authority.

Example review-only invocation:

```sh
python3 scripts/webextensions/ingest_extension.py \
  /review/input/example.xpi \
  --output /review/output/example \
  --extension-id floorp.example \
  --generation g20260826-example \
  --upstream https://github.com/upstream/project \
  --license MIT \
  --patch /review/patches/example.json
```

This command is not an app feature and its output directory must be a dedicated
review location. It does not mutate the input archive or source tree.

## Curated repository build

For the reviewed package directories already committed under
`firefox-ios/Floorp/WebExtensions/CuratedCatalog/Packages`, use:

```sh
python3 scripts/webextensions/build_curated_catalog.py \
  --sources firefox-ios/Floorp/WebExtensions/CuratedCatalog/catalog-sources.json \
  --output firefox-ios/Floorp/WebExtensions/CuratedCatalog \
  --generation-prefix g20260826
```

The builder requires 12–128 source records, unique IDs, a bounded HTTPS source
URL, an immutable upstream revision, a license, a private-profile declaration,
and a package-local `LICENSE` and `NOTICE`. Compatibility-patched packages also
require `PATCH.txt` and a review-only `SourceProvenance/<id>.json`; the current
fixed candidate has exactly thirteen such records. It also requires the exact
16-entry `catalog-disclosures.json`, which produces schema-v3 signed,
display-only publisher/attribution/review/privacy/retention/fixed-route
metadata. It produces:

```text
Artifacts/<id>.fwea1       normalized execution artifact
Review/<id>/inspection.json, normalized/, inventory/  review evidence
catalog-input.json         deterministic schema-v3 unsigned signed-record input
review-index.json          provenance index
```

The application target must include only `Artifacts/` plus the signed catalog
and root public key. `Packages/` and `Review/` remain review evidence in the
source repository and must not become executable app resources.

## Signing and release handoff

`scripts/webextensions/sign_catalog.py` is a low-level cryptographic primitive.
The production handoff for this catalog is
`scripts/webextensions/sign_curated_catalog.py`: it accepts the deterministic
record input and managed paths to root/leaf PKCS#8 Ed25519 keys **only after**
it has checked a clean, exact source commit and every review-quarantined source
archive declared by `sourceProvenance` (all thirteen compatibility builds). It binds the catalog root to that same
Git checkout, parses the verified `catalog-input.json` byte snapshot without
reopening it, and rechecks checkout cleanliness immediately before private keys
are read. It writes only
`Artifacts/Signed/catalog.json` and `Artifacts/Signed/root-public-key.txt`
into the app resource folder; it refuses to overwrite either or a pre-existing
external evidence file. The separate review-only provenance evidence record must
use an absolute path **outside the signing checkout**. Its archive parser works
from one bounded in-memory snapshot and rejects excessive compressed bytes,
members, declared expansion, target-file size, or duplicate target names. It
never generates, fetches, or stores a private key or source archive. Its
invocation must come from the approved signing broker or
protected release environment, not from a shell history, repository file,
GitHub Actions log, or Xcode project setting.

The signer must record all of the following with the release candidate:

- catalog ID, schema, sequence, issued/expiry times, root and leaf key IDs;
- canonical catalog SHA-256 and every artifact/manifest/inventory digest;
- canonical input SHA-256, exact clean source commit, and the result of each
  archive-to-source-provenance verification;
- the two approval identities and timestamp;
- revocation exercise request/result; and
- the exact merged `main` commit that contains the safe public outputs.

If the signer, approval, or input provenance is absent, do not substitute a
test key or produce an External TestFlight catalog. The correct result is a
release gate block.

After the public outputs are normally integrated, the candidate-only
`Floorp Curated Catalog TestFlight Candidate` workflow runs
`verify_signed_curated_catalog_release.py` from a protected annotated
`floorp-catalog-<40 lowercase commit SHA>` tag whose name, tag commit, checked-out
commit, and current `origin/main` HEAD all match. The tool uses no private key. It checks the root/leaf signature chain against a root-key
SHA-256 supplied by the protected release environment, the exact 16-record
catalog input, the release app version/audience, and every FWEA1
envelope/digest/inventory/manifest. The workflow passes that tag to Xcode Cloud.
Before `xcodebuild`, the source-controlled post-clone gate independently requires
the tag-shaped `CI_GIT_REF`, `CI_TAG`, `CI_COMMIT`, approved manual workflow and
bundle ID to agree, then fetches and compares the actual current `origin/main`
commit. It rejects tag moves, a stale main commit, automatic starts, and a
different workflow before an archive exists. The workflow also waits for
completion and rejects a returned source commit that is not the tag commit. An
ordinary TestFlight workflow run is not evidence for this catalog
candidate. The protected root digest is intentionally not inferred from
`root-public-key.txt`; otherwise a source change could replace both public files
and make a self-signed catalog appear valid.

The separate `Floorp Curated Catalog External TestFlight` workflow may mutate
App Store Connect only after the same release verifier has succeeded and
`verify_curated_catalog_release_approval.py` has accepted
`docs/floorp-ios-webextensions-curated-catalog-release-approval.json`. The
approval file must be canonical, `approved`, bound to the exact catalog/input/
root/leaf/sequence/version/expiry evidence, and have its raw SHA-256 stored as
`FLOORP_CURATED_CATALOG_RELEASE_APPROVAL_SHA256` in the protected
`floorp-curated-catalog-external-release` environment. The checked-in
`pending` template is intentionally a release block. This record contains
opaque evidence IDs for Legal, Privacy, Security, Product, and Release; it
does not expose identities, keys, or source archives.
