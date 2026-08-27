# Floorp iOS: curated WebExtensions managed-signer handoff

This is the production handoff for the fixed, app-bundled catalog. It signs
only reviewed catalog bytes and never places a catalog private key in Git,
GitHub Actions, Xcode Cloud, the app bundle, or a shell argument.

## Where signing runs

Run signing on the Security-approved signing workstation or release service,
after the catalog infrastructure is merged and from a clean clone of that
exact `main` commit. Do not run it in GitHub Actions or Xcode Cloud.

Security provides two non-exportable Ed25519 keys:

- an offline root key that signs the leaf-key certificate and requires the
  approved dual-control operation;
- a short-lived leaf key that signs the canonical catalog.

The root and leaf `keyID` values are stable approved identifiers, not key
material. The signing adapter executable must live outside the checkout, be
owner-controlled and non-group/world-writable, and be pinned by its SHA-256
in the invocation. Its existing parent directory chain is checked both when
rendering and before every invocation: each directory must belong to the
signing user or root and cannot be group/world-writable, except for a
root-owned sticky system directory such as `/tmp`. The renderer never creates
the output parent; create a private directory first. A root and leaf adapter
may be separate executables or a single pinned executable with a key-ID
allowlist.

## Adapter protocol v1

`sign_curated_catalog.py` invokes the adapter by absolute executable path with
no arguments, its working directory set to `/`, and a minimal environment.
It writes one canonical JSON request to standard input and accepts one
canonical JSON response on standard output. The adapter must emit no log text
on standard output; it should send diagnostics only to its protected audit
sink or standard error.

The adapter receives a fixed system `PATH`, not the caller's `PATH`; it must
use absolute paths for any non-system HSM/KMS client. It receives only explicit
`--managed-signer-env NAME` values. Deployment credentials, dynamic-loader
variables, Python search paths, and `PATH` itself cannot be passed through.

Public-key request:

```json
{"keyID":"approved-key-id","operation":"public-key","schemaVersion":1}
```

Public-key response:

```json
{"keyID":"approved-key-id","operation":"public-key","publicKey":"32-byte-base64url","schemaVersion":1}
```

Signing request:

```json
{"keyID":"approved-key-id","operation":"sign","payload":"canonical-message-base64url","purpose":"floorp-curated-catalog/leaf-catalog/v1","schemaVersion":1}
```

Signing response:

```json
{"keyID":"approved-key-id","operation":"sign","publicKey":"32-byte-base64url","purpose":"floorp-curated-catalog/leaf-catalog/v1","schemaVersion":1,"signature":"64-byte-base64url"}
```

For the root request, the purpose is
`floorp-curated-catalog/root-leaf-certificate/v1`. The adapter must allow only
the approved key IDs and these two purposes. The release tool verifies the
adapter hash, output shape, key identity, stable public key, and Ed25519
signature before writing any public artifact.

## Release operator sequence

1. Merge the catalog infrastructure through the normal protected `main`
   route. Clone the resulting exact `main` SHA to the approved signing host.
2. Obtain the immutable upstream archive(s) in the review quarantine. Pass
   every source-provenance-bound archive explicitly; the signer refuses a
   missing, extra, or mismatched archive.
3. Invoke `sign_curated_catalog.py` with `--root-managed-signer` and
   `--leaf-managed-signer`, their approved SHA-256 values, approved key IDs,
   the exact source SHA, dates, sequence, and an evidence path outside the
   checkout. Use `--managed-signer-env NAME` only for named HSM/KMS runtime
   values the adapter requires; values are inherited, never printed.
4. The tool writes only `Artifacts/Signed/catalog.json` and
   `Artifacts/Signed/root-public-key.txt` into the checkout, and writes
   provenance evidence outside it. Commit only the two public app-bound files
   through a second normal review/CI integration. Do not commit the evidence,
   source archive, adapter, private key, or adapter configuration.
5. Put the reported `root_public_key_sha256` into the protected GitHub
   environment secret `FLOORP_CURATED_CATALOG_ROOT_PUBLIC_KEY_SHA256` for both
   `floorp-curated-catalog-candidate` and
   `floorp-curated-catalog-external-release`. This is the release trust
   anchor; it is the SHA-256 of the raw 32-byte root public key, not a hash of
   the text file.
6. After the public-output integration is merged and CI passes, create the
   protected annotated `floorp-catalog-<main-sha>` tag and use the curated
   candidate workflow. It will reject any mismatched root, source, tag,
   version, digest, expiry, or package inventory before App Store Connect
   credentials are used.

The production command deliberately has no `--root-private-key` or
`--leaf-private-key` argument when using this handoff. A local PEM mode remains
only for isolated automated tests and is not a release authority.

## 1Password SSH Agent adapter

For the approved `iOS Extensions` vault, use
`render_floorp_1password_managed_signer.py` from the clean, exact signing
checkout to render `floorp_1password_ssh_agent_signer.py` into an
owner-controlled, non-group/world-writable executable **outside** that
checkout. The renderer receives only the two raw public keys, stable key IDs,
and the independently approved root raw-key SHA-256; it rejects a root key
that does not match that digest and refuses to overwrite an existing output.
Its parent must already exist and pass the owner-control check described
above; this prevents replacing an approved pathname between the SHA-256 check
and invocation. The rendered file is the artifact whose SHA-256 is pinned in
the signing invocation.

The adapter is intentionally a narrow SSH-agent client rather than a generic
shell wrapper. It does not enumerate identities or invoke `ssh-add`,
`ssh-keygen`, or a private-key tool. It constructs the configured
`ssh-ed25519` public-key blob and asks the agent for a raw signature only when
the managed-signer request exactly matches one of these bindings:

- root key ID → `floorp-curated-catalog/root-leaf-certificate/v1`;
- leaf key ID → `floorp-curated-catalog/leaf-catalog/v1`.

Pass only `SSH_AUTH_SOCK` with `--managed-signer-env SSH_AUTH_SOCK`; the
adapter verifies that it is the current user's non-group/world-writable Unix
socket. It returns the configured public key for `public-key` requests and
validates the SSH-agent response shape before it returns a 64-byte Ed25519
signature. The release tool independently verifies that signature before it
writes a public artifact. The SSH Agent must supply any required local user
confirmation; no secret is read from, copied from, or written to the source
checkout.

## Required operation record

Before the first operation, the sole Floorp iOS maintainer records the
root/leaf key IDs, adapter SHA-256, 1Password vault custody, expiry and
rotation policy, revocation operation, and audit-event location. The candidate
record binds the exact source SHA, catalog sequence, root fingerprint, signed
catalog digest, and provenance-evidence location. These records remain outside
the app source tree and contain no private key material. A separate Security or
Release approver is not required in the sole-maintainer operating model.
