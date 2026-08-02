# Floorp Notes Sync architecture

This document defines the supported path for Notes Sync. The Swift merger in
this repository is intentionally transport-neutral and does not enable network
sync by itself.

## Current transport boundary

Firefox iOS currently consumes Mozilla's prebuilt Application Services v155
XCFramework. Its Sync manager exposes a fixed set of engines and has no Swift
API for registering an arbitrary record or collection. Supplying an unknown
engine name is not a supported extension point: the iOS wrapper filters it out
before the Rust manager runs.

Floorp must not work around that boundary with direct Sync REST requests. The
existing Firefox Accounts and Application Services pipeline owns tokenserver
access, key derivation, collection encryption, retries, backoff, and persisted
Sync manager state. Notes code must never receive an OAuth token or raw Sync
key.

The production transport therefore requires a reproducible Floorp build of
Application Services that:

- implements and registers a supported prefs-compatible Sync engine;
- publishes generated UniFFI bindings in a pinned Floorp-owned XCFramework;
- preserves opaque Sync manager state across calls;
- keeps cryptography and server transport inside `sync15`;
- has a documented upstream-rebase, signing, provenance, and release process.

Until that artifact exists and passes staging tests, the transport remains
disabled and Notes remain local-only.

## Target wire contract and current Desktop gap

Floorp Desktop stores Notes in the JSON string preference
`floorp.browser.note.memos`. That payload contains parallel arrays for IDs,
titles, content, creation timestamps, and update timestamps. The iOS adapter
uses `titles.count` as Desktop's canonical note count, ignores surplus values
in the other arrays, fills missing values, and always emits the complete array
set. Explicit ID arrays must exactly match that count; blank or duplicate IDs
fail closed. Unknown top-level fields are preserved by refusing to write until
the adapter has been updated, rather than silently erasing future data.
Missing IDs are migrated only on first sync. If an established account's
non-empty remote payload loses its IDs, sync fails closed instead of churning
identity or duplicating every note. A revisioned legacy empty payload remains
an explicit remote bulk deletion and is canonicalized after merge.

Desktop syncs the preference through Gecko's aggregate `prefs` record, not a
dedicated `floorpnotes` collection. A compatible engine must use the exact
production Desktop application record ID and engine version. The production
application GUID must be measured from signed Desktop builds; it must not be
guessed from source names.

The aggregate record can contain unrelated synchronized preferences. A Floorp
engine must preserve every unknown `value` entry byte-for-byte while changing
only the Notes value and its control preference. Uploading a Notes-only map
would delete other preferences and is forbidden.

Matching the storage shape is not the same as having a compatible merge
algorithm. An audit of production Desktop commit
`410c211c202012631159d1bce1f3ab208305d2b7` found that its current merger uses
random conflict-copy UUIDs, resolves equal timestamps from the local client's
point of view, drops the loser of a first-sync same-ID collision, advances its
base on local save before Sync succeeds, and does not apply a one-sided remote
reorder. It therefore **does not implement** the deterministic iOS merge
contract and must not be described as cross-client compatible.

The target `floorp-notes-merge-v1` contract is captured in the shared
`sync-fixtures/floorp-notes/floorp-notes-merge-v1.json` fixture. iOS executes
that fixture as a bundled unit-test resource and the release gate pins its
exact SHA-256 digest. Desktop must execute every required merge, sequence, and
error case from those exact bytes and publish that contract version, or ship a
coordinated migration declaring it, before network Notes Sync can be enabled.
A partial fixture port or Desktop source change without the shared fixture
passing is not sufficient evidence.

The Application Services delegate boundary also remains typed. Its
`RecordMissing`, `NotesKeyMissing`, `NotesNull`, and `NotesString` cases are
not collapsed into an optional string. A missing aggregate resets the stale
merge base and preserves local Notes as a first sync. A present aggregate with
a missing or null Notes value represents an empty remote Notes value without
resetting the account association. `NotesString` contains the inner Notes JSON
string. The size advertised by Application Services counts that whole string
after encoding it as an outer JSON string value, including quotes and escaping;
iOS checks that exact byte count on incoming and outgoing values.

## Merge and commit contract

`FloorpNotesSyncMerger` performs a deterministic three-way merge over the last
successfully synchronized base, current local notes, and the decrypted remote
snapshot.

- Stable note IDs identify records; duplicate or blank IDs fail closed.
- A one-sided edit wins over an unchanged value.
- A one-sided deletion removes an unchanged value.
- An edit wins over a concurrent deletion.
- Concurrent different edits retain a deterministic winner and a deterministic
  conflict copy. Every conflict-copy wire field and its SHA-256 identity derive
  only from the losing note. A later edit to the winner therefore cannot create
  another copy when an upload succeeded but the local base commit failed.
- A one-sided reorder wins. Concurrent reorders prefer the local order and
  append remote-only notes deterministically.
- The engine supplies a usable payload budget derived from the negotiated
  record-size limit after framing/encryption overhead. The limit counts the
  Notes payload after outer JSON-string quoting and escaping and is checked on
  both incoming and outgoing values.
- A canonical remote Notes payload equal to the merged payload is not uploaded;
  the fetched revision still confirms the state and allows the local base to
  advance. Legacy/incomplete arrays are canonicalized with one conditional
  upload.

The base is account-scoped by Firefox Account UID. Before any upload, the local
store compares the captured Notes revision and fully serializes/validates both
the candidate Notes archive and base. It returns an opaque preparation token.
After the engine confirms upload (or confirms a no-op fetched revision), the
store authenticates that token, compares the revision again, and atomically
commits merged Notes and the new base. This prevents a server write that is
already known to be impossible to persist locally. Upload failure, backoff,
cancellation, a stale local revision, or a process crash before that commit
leaves the prior local base unchanged; cancellation is checked after every
external await and before commit.

A nil remote revision is the typed missing/reset-record signal. It invalidates
the old merge base and starts a first-sync merge, retaining local Notes rather
than interpreting the missing record as a bulk remote deletion. Disconnect
clears the account association and base. Local Notes are retained by default
unless the user explicitly chooses to delete them.

## Privacy and retention

- Notes use Firefox Sync end-to-end encryption through `sync15`.
- No Notes title, content, URL, payload, token, or key is logged or sent to
  telemetry.
- Local merge/base storage uses the same protected transactional component as
  Notes and is keyed by account UID.
- A future engine reset removes server-derived state and account association.
  Local Notes are retained by default unless the user explicitly chooses to
  delete them.
- Normal application data protection, backup, and device-removal behavior must
  be documented in the release privacy review.

## Release gates

Network Sync stays disabled until all of the following pass:

1. `FloorpNotesSyncReleaseGate` has exact evidence for the shared fixture,
   including its pinned SHA-256 digest and complete required case set, either a
   matching current Desktop contract or the coordinated Desktop migration
   contract, and the linked `floorp-prefs-sync-v1` Application Services
   artifact. The evidence embedded by this branch deliberately fails this
   gate.
2. Rust engine tests against a fake Sync server, including aggregate-map
   preservation, conditional writes, retry/backoff, reset, and account
   isolation.
3. iOS integration tests proving engine registration, foreground/manual/
   background triggers, transactional base advancement, disconnect, and UI
   refresh.
4. Desktop xpcshell/TPS coverage executes the shared v1 fixtures and verifies a
   corrected base that advances only after successful Sync.
5. Two-device iOS-to-Desktop staging tests for offline edits, delete-versus-
   edit, equal timestamps, reorder, rich unknown nodes, payload limits, and
   repeated retries.
6. Binary provenance, security, privacy, retention, and rollout ownership
   approval for the Floorp Application Services artifact.
