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
- `update_url`, remote JavaScript/WASM, remote DNR lists, dynamic code
  (`eval`/`Function`), `webRequestBlocking`, `debugger`, `nativeMessaging`,
  or unsupported DNR actions;
- a compatibility patch that is not a separately recorded narrow JSON patch.

It writes an inspection record with input SHA-256, normalized-tree SHA-256,
manifest and inventory digests, every finding, and the patch digest. It then
emits one deterministic non-compressed `FWEA1` file. `FWEA1` has a canonical
header and fixed per-resource inventory; it is the only artifact format the
iOS client decodes.

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
require `PATCH.txt`. It produces:

```text
Artifacts/<id>.fwea1       normalized execution artifact
Review/<id>/inspection.json, normalized/, inventory/  review evidence
catalog-input.json         deterministic unsigned signed-record input
review-index.json          provenance index
```

The application target must include only `Artifacts/` plus the signed catalog
and root public key. `Packages/` and `Review/` remain review evidence in the
source repository and must not become executable app resources.

## Signing and release handoff

`scripts/webextensions/sign_catalog.py` accepts the deterministic record input
and managed paths to root/leaf PKCS#8 Ed25519 keys. The release broker writes
only `Artifacts/Signed/catalog.json` and
`Artifacts/Signed/root-public-key.txt`; the existing app resource folder then
copies those two public outputs alongside the fixed FWEA1 files. It never
generates or stores a private key. Its invocation must come from the approved
signing broker or protected release environment, not from a shell history,
repository file, GitHub Actions log, or Xcode project setting.

The signer must record all of the following with the release candidate:

- catalog ID, schema, sequence, issued/expiry times, root and leaf key IDs;
- canonical catalog SHA-256 and every artifact/manifest/inventory digest;
- the two approval identities and timestamp;
- revocation exercise request/result; and
- the exact merged `main` commit that contains the safe public outputs.

If the signer, approval, or input provenance is absent, do not substitute a
test key or produce an External TestFlight catalog. The correct result is a
release gate block.
