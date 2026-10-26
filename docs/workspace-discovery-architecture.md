# Shared workspace discovery and independent copies

The first release implements the scope in `workspace-sync-ios-plan.md`: receive
Desktop workspaces, preview their links without loading websites, and explicitly
open independent normal tabs. It does not implement local workspace membership
or two-way editing.

## Receive boundary

`floorp-workspaces-sync` in the Application Services fork owns validated Desktop
v1 records, deletion evidence, the account/collection association and the cursor.
The transport fetches every page under one collection boundary before staging.
An invalid record, changed boundary, failed page or failed durable commit keeps
the previous confirmed snapshot and cursor.

The engine does not provision an absent Workspace definition in `meta/global`.
Unsupported versions, a declined engine, account invalidation and collection
reset withdraw the old snapshot's copy authorization. Workspace-only discovery
must not enter destructive shared Sync fresh-start paths. No Workspace outbox,
record upload, tombstone upload or collection wipe is permitted.

Wire URLs retain their original spelling for Desktop-compatible validation and
merge comparisons. The public snapshot exposes their serialized WHATWG navigation
URLs so Foundation opens the same destination. Percent encoding can expand a
validated wire URL beyond the raw wire character limit.

`FloorpWorkspaceSyncEngineProvider` registers the Rust store, binds its account
and publishes generation-tagged results. `FloorpWorkspaceDiscoveryCoordinator`
rejects old account/provider/revision events and authorizes copies using the
profile, account, feature epoch, collection association and engine version.
An ordinary content update preserves authorization for an already frozen copy
operation. Before starting or saving each batch, the coordinator reads the live
Rust eligibility header, so an early metadata withdrawal takes effect even
before the overall sync result arrives. Lifecycle invalidation clears the preview and pending source data.

## Copy boundary

`FloorpWorkspaceCopyService` freezes the selected links and allocates fresh local
UUIDs before creating tabs. Its journal distinguishes a new deliberate copy from
a retry of the same operation. Operations targeting one window are serialized.
The destination always creates normal, unloaded tabs in that window; only the
first copy is selected after completion.

Copies are saved in ordered batches of at most 32. Each batch and its
account-free receipts are committed together in `WindowData`, then acknowledged
in one journal write. A failed batch is reconciled by receipt before retry. Receipts survive tab closure,
so a crash between these writes does not recreate a tab the user already closed.
Late window snapshots that predate a durable receipt are rejected. Pending
snapshots, throttled writes and backup paths are tracked per window, so a late
save from another scene cannot overwrite the destination window. Receipts
from an attempted ordinary save enter the committed inventory only after disk
readback; a failed save cannot acknowledge an unfinished copy.

Backup restoration or lost/corrupt primary storage marks the receipt inventory
uncertain. Ordinary browser saves preserve this marker across restart. Copy
recovery stays blocked until the user discards the window's pending operations
and explicitly reconciles the receipt inventory. Saved browser tabs and known
receipts are retained.

Remote changes, deletion, logout and cache removal never navigate or close saved
copies. Ordinary Firefox tab sync remains independent and may advertise the
copies when enabled. Copies are not a promise that URLs stay on the device.

## Runtime and verification

See `workspace-discovery-validation.md` for the current local evidence and the
remaining release acceptance.

The existing immutable `.5` Application Services release does not contain this
engine. The default dependency remains buildable but reports workspace runtime
unavailability; it never substitutes another collection or transport. Use the
real developer XCFramework described in `workspace-discovery-runtime.md` to
exercise the feature. Production activation requires a genuine compatible
release, matching generated bindings, verified assets and an updated pin.

Run focused checks from the iOS repository:

```sh
python3 scripts/ci/test-floorp-workspace-copy.py
python3 scripts/ci/test-floorp-workspace-discovery.py
python3 scripts/ci/test-floorp-workspace-runtime.py
```

The copy harness executes the production Foundation implementation and real
TabDataStore with only the unrelated Common logger/app-group configuration
replaced. It does not verify UIKit adapters. The discovery harness verifies the
real provider/models and explicit legacy-runtime rejection. Simulator app
build/tests and authenticated Desktop-to-iOS acceptance are separate checks.

In the Application Services worktree, run the Workspace, prefs, sync manager,
`sync15 --features sync-client` and distribution automation tests. Desktop golden
fixtures include original normalized records and navigation destinations.
`automation/floorp/build-workspaces-simulator-dev.sh` creates a real arm64
simulator-only framework with dirty-source provenance and `releaseEligible=false`;
it is not a signed production artifact or a substitute for release acceptance.
