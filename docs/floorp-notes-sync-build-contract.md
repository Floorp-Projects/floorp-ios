# Floorp Notes Sync iOS build contract

`scripts/staging/build-floorp-notes-sync-ios.sh` remains the supported wrapper
for non-distributed QA and the legacy release-evidence path. The explicit
public-beta path is `scripts/release/build-floorp-notes-sync-public-beta.sh`.
Both build the `Floorp` scheme from the existing `FloorpRelease` configuration.
Mode-specific values come from a generated `-xcconfig` outside the source
worktree; no source or Xcode project file is rewritten during a build.
The ordinary `release-default` row is the checked-in configuration consumed
directly by Xcode Cloud; the staging wrapper remains focused on its explicit
QA and release-evidence modes.

## Modes

| Mode | Required evidence | Requested / effective | Archive or signing |
| --- | --- | --- | --- |
| `production-qa` | G1-G4 and a repository/head-bound validation clock | `true / true` | rejected |
| `release-disabled` | none; evidence inputs are rejected | `false / false` | unsigned build/archive only |
| `release-default` | none; the checked-in production endpoint policy is required | `true / true` | ordinary FloorpRelease archive; Xcode Cloud distribution |
| `release-enabled` | G1-G5 and a fresh repository/head-bound validation clock | `true / true` | device archive signing only with `--allow-signing` |
| `public-beta` | one validated protected two-client QA capability, or an explicit source-bound FxA QA waiver, plus external-TestFlight approval | `true / true` | signed device archive via the public-beta wrapper |

Production QA is a non-distributable build used to validate the two-client
production path. All enabled modes are hard-bound to `FxAConfig.Server.release`, `sync15`, no custom FxA or
token-server override, and the eight Mozilla production FxA/Sync hosts in
`docs/floorp-release-endpoints.json`.

`release-enabled` remains the strict source-bound release-evidence path. A
normal `FloorpRelease` uses `release-default`, which enables the optional Sync
feature while keeping the production endpoint matrix, FxA server, and sync15
protocol fixed in the checked-in configuration. `release-disabled` is an
explicit local-only fallback, not the ordinary release default.
`public-beta` evidence is also not required for the ordinary Xcode Cloud path:
its evidence record is created
from either a successful protected QA summary/capability or a separately
validated, source-bound FxA QA waiver, with an explicit `external-testflight`
approval. The waiver records `data_integrity_claim: false` and
`manual_validation_required: true`; it must never be treated as successful live
Sync QA. The public-beta wrapper then binds the signed archive to that record
and its exact source SHA.

## Validator boundary

The wrapper does not reimplement release-evidence validation. For each enabled mode it calls
the repository-owned validator with the planned stable interface:

```text
/usr/bin/python3 -I scripts/ci/validate-floorp-notes-sync-release.py \
  --schema docs/floorp-notes-sync-release-evidence.schema.json \
  --evidence EVIDENCE.json \
  --validation-clock-manifest CLOCK.json \
  --canonicalization rfc8785-jcs
```

The `public-beta` path intentionally does not consume the legacy G1-G6
validator. `create-floorp-notes-sync-public-beta-evidence.py` validates the
protected QA summary and capability directly, then requires an explicit
`--approve-public-beta` invocation before writing its canonical record.

Before parsing or validation, the wrapper copies the evidence, validation
clock, and schema bytes into the worktree-external `contract-inputs` directory.
It records each source path, snapshot path, size, and SHA-256 in a separately
hashed snapshot record. Preflight, validator arguments, resource embedding,
hashing, and the final manifest use only these immutable snapshots. The set is
reverified after preflight, validation, build, post-build inspection, and
manifest generation; changing any snapshot aborts before manifest publication.
Replacing an original caller-supplied path after snapshotting cannot change the
artifact.

After Xcode finishes, enabled modes run the exact-commit validation-clock
client with the fixed `/opt/homebrew/bin/gh`, capture a new five-minute clock,
and create a second no-clobber `publication-inputs` snapshot containing the
evidence, clock, schema, validator, merge fixture, and endpoint policy. The
wrapper generates the candidate manifest, then runs the snapshotted validator
again against those publication inputs. Snapshot, source, and worktree drift
checks are the only operations between that terminal validation and manifest
publication.

The validator pins its schema to the canonical path under its own repository
root. To preserve that check without rereading the live worktree, the wrapper
also snapshots the validator and its pinned merge fixture/endpoint policy into
`contract-inputs/validator-repository` with their canonical relative paths,
then executes that fixed validator copy. This preserves both the canonical-path
check and the no-TOCTOU input boundary.

Evidence identifies its `build_contract_mode`. The validator is authoritative
for schema conformance, RFC 8785 canonicalization, expiry/future checks, mixed
release inputs, endpoint bindings, and clock freshness. The wrapper adds
fail-closed checks for required passed gates, exact production authority, the
immutable prerelease Todo 17 Application Services revision `.4`, and the
successful repository/workflow/head clock identity. The iOS release input must contain
exactly repository `Floorp-Projects/floorp-ios`, the requested source SHA,
configuration `FloorpRelease`, and a nonempty build number. Post-build
inspection then requires that build number to equal the built
`CFBundleVersion` before a manifest can be emitted.

`release_inputs.application_services` is compared as an exact object against a
projection of the checked-in `FloorpApplicationServicesPin.json`. This binds
the repository, release tag, source commit, source tree, and all five relevant
asset digests: Mozilla and Focus xcframeworks, Swift components, release
manifest, and `SHA256SUMS`. Missing and unexpected evidence fields both fail.

The legacy embedded schema forms are mutually exclusive. `production-qa`
contains exactly G1-G4 plus `g1_g4_digest_sha256`; `release-enabled` contains
exactly G1-G5 plus `g1_g5_digest_sha256`. `public-beta` uses a smaller,
source-bound record containing the protected QA summary/capability digests,
the approved production endpoint matrix, and the explicit TestFlight approval;
it does not claim G1-G5 or embed G6 trust material. G6 approvals remain an
out-of-process release authorization input and are never embedded into an app
runtime capability record. The legacy forms retain the complete nested `release_inputs`,
`same_release_key_sha256`, and nested validation-clock manifest used by the
final validator.

G3 and G5 test-result bundles must be GitHub Actions artifacts bound to the
candidate repository, head SHA, successful run, canonical workflow path, run
ID, artifact ID, and canonical artifact name. A local or hand-built
`.xcresult` cannot satisfy either gate. Local metadata used by the other gates
is still content-addressed and copied into the immutable contract snapshots.
Both the local snapshotter and the downloaded-artifact validator stream every
uncompressed byte of accepted test-result files for forbidden credential
markers, including markers spanning read-chunk boundaries. Declared and
observed cumulative uncompressed sizes are bounded before the artifact can
satisfy a gate.

G3 uses `artifacts/task-19-integration-receipt.json`, not the terminal Todo 19
manifest. The receipt state is exactly `integration_complete`; it binds the
successful terminal commands and squash-merged iOS commit while recording the
reviewed head,
without claiming Todo 19 completion before the production-QA build exists.
Each receipt command has exactly `argv`, `exit_code`, and `terminal`; `argv` is
a non-empty string array. The bound G3 CI run must be a `push` run whose
`head_branch` is `main`, so feature-branch and manually dispatched runs cannot
stand in for merged-main integration evidence.
G4 uses the decimal successful Desktop GitHub Actions run ID as its build
number, binding the Desktop build identity to the retrievable CI run source.
The iOS build number must equal the single `FLOORP_BUILD_NUMBER` declared by
the reviewed `FloorpRelease.xcconfig`; production validation has no CLI
override for that authority.
G2 issuance is bound to the immutable release's live GitHub `published_at`.
G3 and G5 bind issuance and lifetime to the selected XCResult artifact's live
`created_at` and `expires_at`, so rerunning a workflow cannot refresh an older
artifact. G4 retrieves the canonical merged-source
`floorp-notes-sync-g4-attestation.json`; that record binds the exact Todo 18
manifest, execution-validator `APPROVE` verdict, and xpcshell/TPS summary
digests to Desktop and Runtime identities.
An explicitly selected FloorpCI test verifies the attestation, and G4 reuses
the exact G3 main-push run and XCResult as its external notarization. The
validator parses that XCResult with `xcresulttool` and requires the exact test
node to have only `Passed` results; raw test-name bytes are insufficient. G4
issuance uses immutable run `created_at` values and
expires no later than the earliest source or notarization-artifact deadline.
The post-build clock dispatch passes the canonical workflow file name
`floorp-notes-sync-validation-clock.yml` to the public clock client.

## G5 two-client evidence boundary

G5 is valid only when a successful, manually dispatched `main` run of
`.github/workflows/floorp-notes-sync-production-qa.yml` publishes
`floorp-notes-sync-two-client-xcresult`. The archive must contain a passing
`FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix()`
node. This execution-only node is separate from the current static preflight
selector; a passed
`FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix()` node,
renaming an ordinary FloorpCI result, or reusing the canonical artifact name
does not satisfy this requirement.

The external public-beta route is intentionally separate from that legacy
Todo20 admission job. A successful, manually dispatched `main` run of
`.github/workflows/floorp-notes-sync-public-beta-qa.yml` publishes the same
metadata-only two-client result under a run-specific artifact name and is
accepted only as the source of a `public-beta` evidence record. It does not
consume the stale guarded-merge receipts or owner-waiver variables used by
the historical production-QA job.

Ordinary PR/main CI compiles only the static preflight selector
`XCUITests/FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix`
without executing its protected selector. This compile-only output has no
production-QA authorization, credentials, artifact upload, or operational evidence and
cannot satisfy G5 evidence.

`FloorpNotesSyncActualG5TwoClientTests` is compiled into `XCUITests` so the
future evidence selector has a stable product identity. Until the external
driver, disposable protected runner, cleanup receipt, metadata-only network
record, and fresh G1-G4 inputs are admitted together, that selector is
unconditionally skipped with `UPSTREAM_ARTIFACT_MISSING`. It does not inspect
environment values, launch an app, contact a service, or access credentials.

The protected manual preflight is a `workflow_dispatch` job restricted to
`main` and the `floorp-notes-sync-production-qa` Environment. It compiles the
guard selector with `build-for-testing`; it does not execute the selector,
does not authorize G5, consumes no FxA/Sync credential or endpoint input, and
uploads no artifact. It uses an anonymous source checkout from the public
repository, has empty job-level GitHub permissions, explicitly clears GitHub,
Node, and npm token inputs, and disables the Node package cache. It does not
pass a GitHub token to checkout, setup, cache, shell, or tool calls. GitHub
Actions may still provide its platform-managed `github.token` context; this
job makes no nonissuance claim, does not reference that context, and does not
forward it to any configured action or command. The Environment is a
scheduling boundary, not a G5 approval; this preflight cannot satisfy G5
evidence.

### Future external-driver prerequisites

The same non-live protected preflight also validates
`scripts/ci/floorp-notes-sync-g5-external-driver-admission-contract.json`.
That document is public policy only: it neither schedules a self-hosted runner
nor invokes a driver, receives an Environment secret, executes the actual
selector, or uploads an artifact. It cannot satisfy G5 evidence.
This preflight does not validate a driver admission attestation; it only proves
that the checked-in policy requires one before execution.

Before any later actual-run PR may remove the unconditional skip, an external
driver must have a fresh, independently verified driver admission attestation
that binds its binary digest, expiry, revocation status, run/head/attempt and
same-release inputs. Credentials must reach the driver only through a
root-owned broker; they must not be put in a workflow step environment, repo
script, XCTest process, command argument, output file, or artifact.

scripts/staging/floorp_notes_sync_g5_driver_admission.py is only a
metadata-only verifier for that future attestation. Its production-facing
entry point accepts canonical raw admission bytes plus a separately
owner-pinned trust bundle and expected run and release bindings. A successful
verification still returns "execution_authorization": "not-granted" and
"g5_result": "not-assessed"; it does not establish broker, runner, cleanup,
or G5 evidence requirements.
The verifier deliberately does not source or approve its trust bundle. Before
an actual run, a root-owned broker must load a distinct driver trust manifest
from an immutable owner-controlled path, verify its signature, expiry and
monotonic version, and reject rollback or any bundle supplied by the workflow
or a repository checkout.

`scripts/staging/floorp_notes_sync_g5_owner_trust.py` implements the
fail-closed loader portion of that boundary. Its only public entry point reads
the fixed `/opt/floorp-notes-sync/driver-trust` path as root-owned material;
it does not accept a caller-supplied path, bytes, or `ssh-keygen` executable.
The loader requires `O_NOFOLLOW` and `O_DIRECTORY` support, walks the
production path through non-symlink, root-owned, non-group/world-writable
directories, then opens only root-owned, regular, non-group/world-writable,
single-link files without following a final symlink. It validates these six
files in the trust root:

- `owner-allowed-signers`, containing exactly one distinct driver-trust owner
  public key;
- canonical `manifest.json` and its detached `manifest.sig`, signed under the
  `floorp-notes-sync-g5-driver-trust-v1` namespace;
- `allowed-signers`, `driver-registry.json`, and `revocations.json`, whose
  SHA-256 digests are bound by the signed manifest.

It additionally reads
`/private/var/db/floorp-notes-sync/driver-trust-high-water.json` from a
separate root-owned, non-symlink, non-group/world-writable directory chain.
The physical `/private/var` path is intentional: on macOS `/var` is a symlink,
which this loader rejects. The high-water record must exactly bind the manifest
digest and version. It is not stored with the replaceable trust bundle: the
broker must atomically advance this separate persistent record before accepting
a newer signed bundle. Consequently, restoring a complete older
manifest/signature/revocation bundle cannot make the loader accept it after the
high-water mark has advanced.

The manifest has the distinct `g5-driver-trust-owner` role, owner login/key
fingerprint, a different driver login/key fingerprint, strict UTC issuance and
expiry, version and previous-digest fields, and the three driver-bundle
digests. The loader checks the owner signature against the separately stored
owner root key before it makes the driver trust bundle available to the
separate admission verifier. It rejects an expired, forged, untrusted,
noncanonical, revoked, tampered, or rollback-inconsistent bundle. A valid load
still returns `execution_authorization: not-granted` and
`g5_result: not-assessed`.

The owner root key, the initial signed version-1 bundle, the external
high-water record, their root-only installation, and later rotation/revocation
are Operations-owned inputs. They are never generated from a workflow, stored
in this repository, or replaced by the five G6 approval keys. The following
broker/runner implementation must atomically persist and advance the external
high-water record. When advancing a version, that broker must verify the new
manifest's `previous_manifest_sha256` against the currently accepted external
record before replacing either artifact. This static loader does not install a
trust bundle or establish a broker, runner, lease, cleanup, or G5 result.

`scripts/staging/floorp_notes_sync_g5_broker_admission.py` is the next,
metadata-only connection between those two static controls. Its sole public
entry point accepts one canonical signed admission envelope plus expected
run/release bindings and a broker-provided trusted clock. It reloads the fixed
owner-pinned trust source on every call, then immediately passes that freshly
loaded bundle to the existing driver-admission verifier. It accepts no caller
supplied trust bundle, prior loader result, path, signature verifier, SSH
executable, execution callback, or force/override flag. Even after both
checks succeed, it returns exactly `execution_authorization: not-granted` and
`g5_result: not-assessed`; it deliberately discards the validation metadata so
this library cannot become an execution capability or a G5 receipt.

The bridge is not the future root-owned broker. An eventual Operations-owned
broker must install and invoke its reviewed code from a root-controlled
location, supply a separately trusted clock, atomically manage the external
high-water record, provide the isolated runner lease and credential boundary,
and retain independently verified cleanup evidence. Repository code and a
workflow checkout never substitute for those controls.

The eventual runner must be an ephemeral runner in a dedicated restricted
runner group, under a dedicated OS account and an expiring lease. It must be
destroyed after the operation, with an independent watchdog responsible for
remote cleanup, lease revocation, simulator/keychain erasure, and refusal to
admit an incomplete cleanup receipt. A label or Environment approval alone is
not a runner-isolation or secret-isolation boundary.

Any future G5 operation has a strict participant split: the external driver is
the coordinator. A separate iOS XCTest may be a metadata-only participant, but
it must not carry credentials, coordinate a Desktop client or proxy, initiate
or capture network traffic, inspect Notes payloads, or retain attachments,
screenshots, or UI hierarchy. The existing protected selector remains a
non-live preflight; this contract does not authorize a future driver or iOS
participant implementation.

The public records are exact metadata-only summaries. Account isolation must
prove two isolated accounts, post-upload base advancement, cleanup, rollback,
and local-only fallback against the pinned fixture. Network evidence must prove
the pinned endpoint policy, approved hosts, port 443, TLS verification without
interception, and no retained payload or secret. A G5 operation record has
`state: g5_completed`; it is not the terminal Todo 20 manifest and cannot claim
completion before the separately validated G6 signatures.

## App integration interface

The generated xcconfig provides these build settings:

- `FLOORP_NOTES_SYNC_BUILD_MODE`
- `FLOORP_BUILD_NUMBER`
- `FLOORP_NOTES_SYNC_SOURCE_SHA`
- `FLOORP_NOTES_SYNC_REQUESTED`
- `FLOORP_NOTES_SYNC_EFFECTIVE`
- `FLOORP_NOTES_SYNC_FXA_SERVER`
- `FLOORP_NOTES_SYNC_ENDPOINT_AUTHORITY`
- `FLOORP_NOTES_SYNC_PROTOCOL`
- `FLOORP_NOTES_SYNC_CUSTOM_FXA_OVERRIDE`
- `FLOORP_NOTES_SYNC_CUSTOM_TOKEN_SERVER_OVERRIDE`
- `FLOORP_NOTES_SYNC_ALLOWED_HOSTS`
- `FLOORP_NOTES_SYNC_ENDPOINT_MATRIX_SHA256`
- `FLOORP_NOTES_SYNC_EVIDENCE_DIGEST`
- `FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE`
- `FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE_SHA256`

The app integration must copy the evidence resource byte-for-byte when an
evidence-backed mode has an effective gate, while `release-default` must not
require or embed that resource. All modes expose the corresponding build
values as these
Info.plist keys:

- `MozFloorpNotesSyncBuildMode`
- `MozFloorpNotesSyncBuildNumber`
- `MozFloorpNotesSyncSourceSHA`
- `MozFloorpNotesSyncRequested`
- `MozAllowFloorpNotesSync`
- `MozFloorpNotesSyncRegistrationAllowed`
- `MozFloorpNotesSyncEngineRequestsAllowed`
- `MozFloorpNotesSyncUIExposureAllowed`
- `MozFloorpNotesSyncEndpointAuthority`
- `MozFloorpNotesSyncProtocol`
- `MozFloorpNotesSyncEndpointMatrixSHA256`
- `MozFloorpNotesSyncEvidenceDigest`
- `MozFloorpNotesSyncEvidenceResourceSHA256`

The wrapper rejects the artifact if any post-build value differs. A disabled
artifact may still contain Notes Sync capability symbols; its contract is zero
engine registration, zero `prefs` requests, and zero Notes Sync UI exposure.
Swift integration tests separately prove that runtime behavior honors these
three false values.
The exact embedded evidence shape and runtime parser reject a G6 gate. As
defense in depth, post-build inspection also rejects recognized Notes Sync G6
approval, signer, or revocation Info.plist keys and bundle-resource names. This
name screening is not a semantic scan of arbitrary resource contents; candidate
source review remains responsible for preventing a newly named runtime trust
mechanism. G6 remains outside the app capability record and build artifact.

## Signing boundary

`--allow-signing` is accepted only for a `release-enabled` archive whose exact
destination is `generic/platform=iOS`. The public-beta wrapper applies the
same destination and signing requirements directly. The completed app must pass
`/usr/bin/codesign --verify --deep --strict`. Ad-hoc and Apple Development
signatures are rejected. The signing chain must be an Apple Distribution (or
legacy iPhone Distribution) leaf for team `DV2U35YBHT`, followed by the Apple
Worldwide Developer Relations CA and Apple Root CA. The extracted leaf
certificate must also occur in the Apple-CMS-decoded
`embedded.mobileprovision`, and `/usr/bin/security verify-cert` must trust the
chain at the fresh GitHub clock time.

The code-signature entitlement dictionary is an exact allowlist: application
identifier `DV2U35YBHT.app.floorp.Floorp`, team identifier `DV2U35YBHT`,
multipath networking, app group `group.app.floorp.Floorp.DV2U35YBHT`, and
keychain group `DV2U35YBHT.app.floorp.Floorp`. `get-task-allow` and every
unexpected signed entitlement are rejected. The provisioning profile must
have the matching team/application identity, authorize the app/keychain
groups, explicitly disable `get-task-allow`, and be inside its validity window.
Missing signing, profile, certificate, or entitlement proof fails before
manifest publication. `production-qa` continues to reject archive and signing.

## Production toolchain boundary

The production CLI runs privileged-mode Bash (so `BASH_ENV` and inherited
shell functions are ignored), closes `PATH`, runs Python in isolated/no-site
mode, disables global/system Git configuration and `core.fsmonitor`, clears
Git/Xcode selector and proxy/TLS override variables, and invokes Git and
Apple/system tools by absolute path.
`/usr/bin/xcode-select` must resolve directly to an Xcode `.app`; the app and
its contained `xcodebuild` must pass `codesign`, exact Apple identifier, team,
and authority checks, and Gatekeeper assessment. Xcode runs from that contained
absolute binary under a minimal `env -i`. The manifest records the selected
developer directory, Xcode app identity, Gatekeeper result, xcodebuild path,
CDHash, SHA-256, authority chain, and version.

GitHub API calls begin at `/opt/homebrew/bin/gh`, but never execute that
mutable Homebrew path directly. The client opens the resolved binary without
following a final symlink, verifies the reviewed size and SHA-256 while
copying it into a newly created mode-0700 directory, fsyncs a mode-0500 copy,
and executes only that content-pinned copy with `--hostname github.com` and an
allowlist containing only authentication, identity, locale, and temporary-path
environment variables.

## Reproducibility and manifest

The source worktree must be clean, `--source-sha` must equal `HEAD`, and Git
status must remain unchanged through publication. The wrapper creates a Git
archive for that exact commit, verifies the archive's embedded commit ID, and
extracts it outside the worktree. Before freezing the snapshot, the reviewed
generated-source preparer runs bootstrap, Glean, and Nimbus with fresh private
tool state below the exclusive output directory. It proves that every archive
file and executable bit is unchanged, permits only the exact reviewed
generated JS/Swift path set, removes package and generator caches, and emits a
canonical manifest containing every generated-file digest plus Node, npm,
Nimbus, Python, Glean-version, and installed-package identities. The wrapper
downloads the exact `.nvmrc` Node release from the versioned Node.js archive,
requires its reviewed SHA-256 before private extraction, and never uses a
mutable Homebrew Node installation. The wrapper
then removes every source-snapshot write bit, rejects symlinks or special
files, and records a content Merkle digest that binds the generated-source
manifest. Xcode receives only this read-only snapshot; the live worktree is
never a build source. Glean phases regenerate into private external temporary
directories and compare bytes, while the Nimbus phase verifies the canonical
manifest instead of writing source files. Archive, generated-input, snapshot,
and worktree identity are rechecked after the build and immediately before
publication.

The output directory, manifest, archive, temporary xcconfig, all contract
snapshots, and evidence resource must be outside the worktree. The output and
archive paths must not exist; the wrapper creates the output directory
exclusively with mode 0700 under an owner-controlled, non-group/world-writable
parent. A pre-existing manifest path is rejected. Final publication recomputes
the full app Merkle digest after the terminal validator, opens the target
relative to a no-follow parent descriptor with `O_EXCL|O_NOFOLLOW`, writes and
fsyncs it, verifies the resulting inode, then fsyncs and rechecks the parent
directory; no rename or replace operation can clobber an earlier manifest.

This filesystem boundary assumes that no hostile process runs as the release
UID while the wrapper is active. Mode-0700 output directories exclude other
UIDs, but the owning UID can still mutate its own app bundle after an integrity
check. A release environment that cannot make this assumption must isolate the
publisher under a dedicated account or introduce an OS-enforced immutable,
sealed artifact outside this scoped wrapper contract; validation must not be
weakened to conceal that trust boundary.

The emitted JSON manifest records absolute app/archive paths, source commit and
tree, generated-source manifest path/digest, dirty state, configuration, Xcode
version and arguments, version/build,
configured and observed signed entitlements, executable and Info.plist hashes,
Application Services pin/framework hashes, app Merkle digest, production
endpoint authority, embedded evidence digest, validation-clock run ID, and the
requested/effective/runtime gate values. Enabled manifests also retain the
bound iOS/Application Services release inputs and the hashed snapshot record.

The Python contract suite injects fake Git, Xcode, signing, and profile fixtures
only by patching a private temporary copy of the wrapper. The production CLI
has no test flag or environment-controlled tool path, and fake output is not
build evidence. The suite also proves that the repository validator rejects
legacy fixtures whose gate artifact bytes are not retrievable. Run the
following integration check from a clean committed worktree to exercise the
real Xcode toolchain as an unsigned simulator build:

```bash
ROOT="$(git rev-parse --show-toplevel)"
SOURCE_SHA="$(git rev-parse HEAD)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/floorp-notes-sync-real.XXXXXX")"
"$ROOT/scripts/staging/build-floorp-notes-sync-ios.sh" \
  --mode release-disabled \
  --source-sha "$SOURCE_SHA" \
  --output-dir "$OUT/build" \
  --manifest "$OUT/build-manifest.json" \
  --destination 'generic/platform=iOS Simulator'
```

An evidence-backed real build additionally requires current validated evidence
whose `release_inputs.ios.build_number` is exactly the `FloorpRelease` build
number. The ordinary `release-default` build uses the checked-in endpoint
matrix and does not require a generated evidence file.

The public-beta build wrapper builds and archives only. The protected
`floorp-public-beta-release.yml` workflow performs export, signing, upload,
and the allowlisted external TestFlight/Beta App Review submission after an
explicit approval input. Enabled modes do make narrowly scoped GitHub API requests through the pinned
`gh` copy to validate retrievable evidence and to dispatch and capture the
validation-clock workflow.

## Formal Todo 20 rescope boundary — 2026-08-15

The append-only plan amendment
`.omo/plans/floorp-ios-next-milestone-production-sync-amendment.md` is the
authoritative Todo 20 acceptance overlay. It supersedes the earlier G5/G6
driver-admission text in this document for this milestone. The old text remains
historical documentation of PR #104 and is not an active requirement for the
bounded QA described here.

Todo 20 has two phases: a protected production-endpoint desktop/mobile
integrity QA using exactly two disposable FxA accounts, followed by a reviewed
production Sync enablement bound to the Phase 1 digest. The existing FxA,
Application Services, and `sync15` path is used. no direct REST/token calls,
custom endpoint overrides, user accounts, and Notes payload retention remain
forbidden.

The active Phase 1 boundary is `single-operator-protected-qa` in the
`floorp-notes-sync-production-qa` Environment. Owner/Operations/executor
self-attestation is permitted for this pre-public QA, while ordinary PR
review, CI, validator, evidence hashing, cleanup, local-only fallback, and
append-only ledger requirements remain mandatory. Mozilla approval, five G6
signatures, a custom broker, a dedicated runner group, a driver trust bundle,
and a driver-admission chain are not Todo 20 gates.
G6 and broker requirements are not Todo 20 gates.

The `notes-sync-production-qa` workflow job uses a standard GitHub-hosted
macOS runner. It consumes credentials only from protected Environment secrets;
the app/test process receives no credential environment values. The existing
client pair must produce a canonical metadata-only summary and an XCResult
with no Notes content, titles, tokens, keys, authorization headers, screenshots,
or attachments. The job validates the requested data-loss matrix, approved
hosts, `sync15`, account isolation, cleanup, and base/revision confirmation
before any Phase 2 enablement is accepted.

`release-enabled` archive signing and any distribution-oriented build are not
part of this amendment. Phase 2 means only the reviewed production Sync path
is enabled in a non-distributed QA/release configuration after Phase 1
validator `APPROVE`; App Store, TestFlight, and general-user publication stay
outside the Todo and require separate approval.

The phrase “user accounts” above means unrelated general-user accounts. The
amendment permits exactly two disposable FxA test accounts, delivered only by
the protected Environment. The active workflow additionally binds the
metadata summary to its exact dispatch/run/head/job and provides a dependent
Phase 2 enablement-record job; neither job claims live QA when the existing
desktop/mobile pair or protected capability is absent.

### Todo 20 Phase 2 binding tightening (2026-08-15)

The non-distributed enablement record is accepted only when the cleanup and
secret-scan receipts are revalidated for the same Phase 1 run and their exact
bytes and validator digests are recorded. Secret scans retain hashes only;
payloads, credentials, and process contents are never artifacts.

Phase 2 supplies the four downloaded target paths to the scan validator, which
recomputes each target digest before accepting the enablement record.
