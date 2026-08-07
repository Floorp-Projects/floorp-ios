# Floorp Notes JSON Export and Import

> Applies to milestone 0.2.0 (issue #23). Notes remain local-only; this
> document describes the validated document format, import policy, corruption
> backup retrieval, and privacy behavior.

## Document format (export)

Export produces the desktop parallel-array payload (schema
`floorp-notes-desktop-payload-v1`), the same shape Floorp desktop persists in
`floorp.browser.note.memos`. The payload is a JSON object with four parallel
arrays:

| Field | Type | Meaning |
| --- | --- | --- |
| `ids` | `[string]` | Byte-exact opaque note identifiers |
| `titles` | `[string]` | Note titles |
| `contents` | `[string]` | Opaque note bodies (plain text or rich JSON source) |
| `createdAts` | `[int64]` | Creation timestamps in milliseconds |
| `updatedAts` | `[int64]` | Last-update timestamps in milliseconds |

`createdAts` and `updatedAts` are optional in the wire type but always emitted
by export. Timestamps are Unix milliseconds. Content bytes are never rewritten:
TipTap/Lexical JSON source and unknown rich text remain byte-for-byte
unchanged through export and import.

## Import validation

Import accepts only the export format above. Every check runs **before** any
mutation; a rejected document leaves the archive and its revision untouched:

1. **Size** — the document must not exceed the archive byte limit
   (`FloorpNotesStore.maximumArchiveBytes`).
2. **Shape** — the document must decode as the desktop payload and every
   parallel array must have the same length; `ids` is required.
3. **Identifiers** — each ID must be non-empty (after trimming whitespace) and
   byte-exact unique. Duplicate or empty IDs reject the import.
4. **Timestamps** — when present, `createdAts` must be positive and
   `updatedAts` must be greater than or equal to the corresponding
   `createdAts` value.
5. **Limits** — the note count must not exceed
   `FloorpNotesStore.maximumNoteCount`.
6. **Rich text** — content is preserved as opaque bytes. Imported notes carry
   the `automatic` content format and are analyzed on open, so rich source
   stays byte-identical and plain text remains editable.

Malformed JSON, inconsistent arrays, missing IDs, oversized documents,
duplicate IDs, invalid timestamps, and over-limit note counts each produce a
typed `FloorpNotesStoreError` and never partially replace the last-good
archive.

## Import policy

The UI requires explicit confirmation before either destructive operation.

### Replace

The imported notes replace the entire local archive. `replacedCount` reports
the number of local notes that were replaced.

### Merge

Notes are merged by exact ID with a deterministic policy:

- A shared ID keeps the version with the newer `updatedAt`.
- A timestamp tie keeps the local version.
- Imported IDs that do not exist locally are appended in payload order.

`mergedCount` reports how many existing local notes changed.

Both policies commit atomically. If the write, rename, or commit step fails,
the last-good archive remains byte-identical and no partial or temporary file
is left behind; a fresh store open restores the last-good state.

## Corruption backup retrieval

When the local archive is detected as damaged, the store copies the original
bytes to a `*.corrupt-<timestamp>.json` recovery file and blocks writes until
an explicit reset. The preserved backup is exposed as **untrusted data**
through `preservedCorruptionBackupURL()` / `preservedCorruptionBackupData()`:

- The backup is never auto-imported and is never treated as trusted Notes
  content.
- Loading still fails while the source is corrupt; the backup is only a
  read-only recovery artifact for the user to inspect or export manually.
- `resetAfterCorruption()` requires an explicit destructive decision and keeps
  the recovery copy byte-identical on disk.

## Privacy

Export and import are local document operations. No network request is
issued, no telemetry is attached to note content, and the payload is never
persisted outside the archive and the explicit document the user chose.
