# Signed curated catalog security model

## Trust boundaries

```text
untrusted upstream ZIP/XPI/CRX/source/HTTPS
        │  review-only quarantine, static inspection, compatibility patch
        ▼
reviewed immutable FWEA1 + provenance/digests
        │  managed root/leaf signing, two-person approval
        ▼
signed catalog.json + root public key + FWEA1 app resources
        │  iOS canonical verification and local artifact validation
        ▼
profile-scoped atomic package generation → runtime / DNR / page hosts
```

The first arrow is not present in the shipping application. The client accepts
only an FWEA1 selected by a currently accepted signed record and physically
present as a safe static app resource. It cannot accept a URL, archive, local
path, Chrome Web Store/AMO item, shared-sheet attachment, remote list, or
extension-provided code payload.

## Acceptance conditions

Before a catalog package is visible, installable, restorable, or re-enabled,
the client requires all of the following:

1. strict canonical JSON and an Ed25519 root-signed leaf, then a leaf-signed
   catalog;
2. exact app bundle ID, channel, minimum app version, issuance/expiry limits,
   monotonic sequence, and observed-clock constraints;
3. device-bound acceptance state in `ThisDeviceOnly` Keychain, including
   accepted `(extensionID, generation, artifact SHA-256, leaf key ID)` binding;
4. a matching static FWEA1 artifact whose byte count/SHA-256, canonical header,
   manifest SHA-256, inventory SHA-256, resource hashes, and closed manifest
   preflight all pass; and
5. current non-revoked generation/key state plus the profile-specific native
   permissions required to activate it.

Failure of any condition is fail-closed: no new install/update/re-enable occurs.
The client never interprets catalog authentication, TLS, a CDN host, or the
presence of an artifact file as sufficient trust on its own.

## Immutable generations and update rule

A generation cannot be overwritten. Installation stages resource files in a
profile directory, validates them, records a rollback journal, suspends the
old runtime/DNR/page hosts, and publishes the new generation atomically. A
failed transition keeps the known-good generation active where it is still
authorized.

There is no remote, catalog-refresh, or app-bundle silent update. Every
replacement generation needs one-use native consent bound to both generations
and the replacement digest, even when its authority is unchanged or reduced.
A stale dialog, cancellation, missing presenter, or ambiguous candidate
rejects and keeps the known-good generation active.

## Revocation and withdrawal

- A signed key or generation revocation stops matching normal/private runtimes,
  DNR rules, content scripts, popup/options origins, and reactivation before
  the new Keychain state is committed.
- Revocation never points at a replacement and never chooses an old generation
  as a fallback. A withdrawn catalog item similarly loses current execution
  authority.
- Future-dated revocations reject the entire catalog. The app has no persistent
  scheduled-stop mechanism, so accepting one would create a fail-open window.
- Disable/revocation data retention is explicit policy; uninstall is the
  operation that removes profile-owned package data.

## Key management requirements

- Root private material stays offline and never enters the repository, Xcode
  project, app bundle, GitHub Actions log, or Xcode Cloud build environment.
- A short-lived leaf signs catalog records. Key IDs are immutable and may not
  be reused for a different public key. Rotation uses a new key ID and a new
  extension generation even if artifact bytes are unchanged.
- Signing, publication, and revocation require a recorded two-person approval,
  audit identity/timestamp, and on-call owner. The public root key is safe to
  bundle; it is not a signing credential.

Until Security, Product, Legal/Privacy, and Release supply the required P0
records, this security model is an implementation boundary—not permission to
ship or to submit External TestFlight review. See
[release gates](floorp-ios-webextensions-internal-catalog-release-gates.md).
