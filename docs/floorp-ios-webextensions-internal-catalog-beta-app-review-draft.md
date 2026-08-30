# Floorp iOS: curated WebExtensions Beta App Review draft

Status: **draft only — reviewer copy.** Beta App Review submission requires an
exact merged `main` source SHA, a managed-signed Dark Reader-only catalog,
candidate-bound Xcode Cloud build, and approval records bound to that exact
candidate. This document does not claim Apple approval or external tester
availability.

## Release operator completion fields

Complete these outside the repository immediately before a source-bound
submission. Do not invent values or substitute an earlier build.

| Field | Required value/evidence |
| --- | --- |
| App Store Connect build | Exact `marketing version (build)` and build ID produced from merged `main` SHA |
| Catalog identity | Catalog ID, sequence, root key ID, leaf key ID, expiry, and signed catalog SHA-256 |
| IPA identity | IPA SHA-256, archive signing/team evidence, and the single Dark Reader artifact inventory SHA-256 |
| P0 maintainer record | Current Dark Reader-only policy receipt plus the exact signed candidate's schema 2 `maintainerApproval` record and protected raw SHA-256 |
| Redistribution basis | Dark Reader MIT license, local `LICENSE`/`NOTICE`, pinned provenance, and candidate-time archive re-verification |
| Managed signing and revocation | 1Password SSH Agent custody, key IDs/root digest, audit record, rotation, and emergency-revocation exercise |
| Apple reviewer path | Evidence-backed fixed-bundle reviewer exercise path and Guideline 3.2.2(i)/4.7 rationale; Apple makes the actual review decision after submission |
| Reviewer contact | Current App Store Connect contact name, email, and phone; the submission workflow checks that the live record is complete |
| External group | Existing approved group ID; do not create a group as part of submission |

## Proposed Beta App Review notes

Use only after the fields above are complete and reviewed. Replace bracketed
values with evidence-backed values; omit any claim that cannot be shown in the
submitted build.

> Floorp for iOS [version/build] contains one product-curated WebExtension:
> Dark Reader. The reviewed package and its configuration are embedded in the
> signed application bundle. This is not an extension store or a catalog
> download client. The app provides no Chrome Web Store, Firefox Add-ons,
> arbitrary URL, ZIP/XPI/CRX, shared-sheet, or local-file installation flow.
> It does not fetch or execute remote JavaScript, WebAssembly, configuration,
> extension updates, or DNR/filter lists.
>
> At startup the app validates a bundled, signed catalog against the app's
> embedded root public key and validates the catalog audience, expiry,
> sequence, revocation state, immutable generation, artifact SHA-256,
> manifest, and resource inventory before showing Dark Reader. If validation
> fails, it cannot be installed or enabled. A replacement is an immutable
> generation and requires explicit native confirmation; there is no silent update
> or automatic permission escalation.
>
> Reviewer path: Settings > Extensions > Dark Reader. Install it, open an
> ordinary non-sensitive HTTP(S) page, and grant access using Floorp's native
> site-access control. Confirm that Dark Reader changes the page appearance
> and that its popup shows the actual hostname rather than `about:`. Toggle
> Off and On and confirm both the page and popup state update. Tap Settings
> and confirm the bundled Dark Reader settings page opens. Disable/re-enable
> and remove/reinstall the extension; disabling stops its runtime and page
> changes, while removal clears extension-owned local data.
>
> Private Browsing use is opt-in and profile-local. Normal and private site
> grants, storage, alarms, package state, and runtime state are separate.
> `storage.sync` is a device-local compatibility namespace and does not
> synchronize through a Floorp account or cloud service. No demo account is
> required.

## Fixed package inventory

The final signed catalog must equal this review input.

| Package | Floorp ID | Supported family |
| --- | --- | --- |
| Dark Reader | `floorp.thirdparty.darkreader` | content scripts, popup/settings, storage, alarms; bundled configuration only |

Exact version, immutable generation, original-input and normalized artifact
digests, permissions, host patterns, and compatibility reductions are recorded
in [the third-party record](THIRD_PARTY_EXTENSIONS.md) and
[`catalog-input.json`](../firefox-ios/Floorp/WebExtensions/CuratedCatalog/catalog-input.json).
Adding another extension or changing any signed field requires fresh source
review, provenance verification, catalog generation, managed signing, and
candidate-bound approval; an earlier candidate's approval cannot authorize the
new set.

The candidate's public signed output must be source-bound to the exact merged
`main` commit before that commit is archived. Its signing composition must use
one of the sole-maintainer-approved paths in the release-gate record: a
review-bound pre-merge signature whose **public output** is reviewed with the
candidate, or a separately reviewed second integration of the public signed
output. No signing private key, source archive, review workspace, or remote
endpoint belongs in the app target.
