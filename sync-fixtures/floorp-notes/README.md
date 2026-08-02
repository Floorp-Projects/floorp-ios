# Floorp Notes cross-client fixtures

`floorp-notes-merge-v1.json` is the normative, client-neutral merge contract
for Floorp Notes. iOS bundles and executes it in `FloorpNotesSyncTests`.
Desktop must consume the same file from its test suite; copying expected values
into a client-specific test is not equivalent because the copies can drift.

Fixture schema 2 separates independent `mergeCases`, stateful
`sequenceCases`, and `errorCases`. Every sequence step contains a complete,
explicit base/local/remote snapshot; `transitionFromPrevious` names the
simulated transport or commit boundary, and `invariants` compare results across
steps. Error cases use stable cross-client error codes instead of Swift enum
spellings. `requiredCaseNames` must exactly equal the union of all three case
groups, without duplicates.

The release gate pins the exact fixture bytes with SHA-256
`2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd`.
A client cannot declare v1 compatibility after running only a subset of cases.
Any byte change requires an intentional digest update and coordinated client
review. The required vectors cover one-sided deletion, edit-versus-delete,
one-sided and concurrent reorder, deterministic conflicts and probes, nested
candidate reuse, retry after server upload/local commit failure, byte-preserved
unknown rich content, and fail-closed duplicate identity.

The fixture records an audit of the production Desktop implementation at the
exact commit shown in `productionDesktopObservation`. That implementation does
not yet match v1, so `declaredContractVersion` is `null` and the release gate
must remain closed. When Desktop is migrated, its tests must pass this file and
the coordinated release must declare `floorp-notes-merge-v1`. Do not change the
observation to claim compatibility based only on matching the parallel-array
storage shape.

## Conflict identity

The conflict copy is a pure function of the losing note. First encode its `id`
as an unsigned 64-bit big-endian UTF-8 byte length followed by those bytes.
Then append a canonical losing-note encoding: `id`, `title`, and `content` in
that same length-prefixed form, followed by `createdAt` and `updatedAt` as
signed 64-bit big-endian integers. Hash the result with SHA-256, render
lowercase hexadecimal, and prefix it with `floorp-sync-conflict-`. For a
collision probe greater than zero, append the probe's decimal UTF-8 string in
the same length-prefixed form before hashing.

No winner field may affect the copy ID, title, content, creation timestamp, or
update timestamp. This is required for an upload-success/local-commit-failure
retry to reuse the copy already present on the server even if the winner was
edited again. If a candidate ID is itself an independently conflicting note
whose resolved winner has the candidate's exact wire fields, that winner is
the existing copy and must be reused; probing would create a duplicate.
