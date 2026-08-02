# Floorp Notes cross-client fixtures

`floorp-notes-merge-v1.json` is the normative, client-neutral merge contract
for Floorp Notes. iOS bundles and executes it in `FloorpNotesSyncTests`.
Desktop must consume the same file from its test suite; copying expected values
into a client-specific test is not equivalent because the copies can drift.

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
edited again.
