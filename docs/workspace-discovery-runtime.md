# Workspace discovery runtime dependency

Normal builds use the read-only `floorp-workspaces` engine from the published,
immutable [Application Services `.6` release](https://github.com/Floorp-Projects/application-services/releases/tag/floorp-ios-155.20260731050244.6).
The pin records release ID `423961346`, source commit
`a859c7883820fd9db4891800801161eada561551`, tree
`d8d362a75986a3c0bf30df21e47b9a816dc57ee1`, and the actual five asset digests.
The matching main and Focus generated bindings, including their Metrics, are
imported from that release's `swift-components.tar.xz`. Its Workspace
capability is enabled in `FloorpApplicationServicesPin.json`; an environment
override is unnecessary for ordinary builds.
Both main and Focus generated trees were compared against the release archive,
ignoring trailing whitespace and the final newline. Their code already matches
the published bindings, so existing formatting is preserved. The downloaded
archive remains byte-identical.

## Local development and simulator verification

Build an actual `MozillaRustComponents.xcframework` from the matching changed
Application Services source, including the device and simulator slices needed
for the build. Copy its matching generated Swift bindings to
`MozillaRustComponents/Sources/MozillaRustComponentsWrapper/Generated/`,
including `floorp_workspaces_sync.swift`. Headers, native libraries, and Swift
bindings must come from the same build.

For an arm64 simulator development build, the Application Services worktree also
provides `automation/floorp/build-workspaces-simulator-dev.sh`. Build its simulator
NSS dependencies first with `IOS_DEPLOYMENT_TARGET=15.0 ./build-all.sh ios`
from its `libs/` directory, then pass a new absolute output
directory to the developer builder. Its `developer-build.json` records the dirty
source tree hash, library hash and toolchain. It intentionally marks the output
`releaseEligible=false` and contains no device or Intel simulator slice.

When using that artifact, select an arm64 simulator destination and add
`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` to the build command below. A generic simulator
build that requests both architectures needs an XCFramework with both slices.
Generated Swift may have trailing whitespace removed; the existing generated
bindings were checked to match the final source apart from that whitespace.

Pass the absolute path to the unzipped framework when resolving and building:

```sh
export FLOORP_APPLICATION_SERVICES_XCFRAMEWORK=/absolute/path/MozillaRustComponents.xcframework
xcodebuild -resolvePackageDependencies -project firefox-ios/Client.xcodeproj -scheme Floorp
xcodebuild -project firefox-ios/Client.xcodeproj -scheme Floorp \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

`Package.swift` checks for the Workspace UniFFI header and contract symbol,
selects the local binary, includes the real generated binding, and sets
`FloorpWorkspaceRuntimeSupport.isAvailable` to `true`. This selects the real
engine, with workspace reception enabled by default. The header check is a
build dependency check; it does not replace native link, transport, or
interoperability tests. This override changes only the Mozilla binary target;
the Focus product keeps its existing pin.

The account-free Swift model/provider and legacy fallback checks can be run with
`python3 scripts/ci/test-floorp-workspace-discovery.py`. The package manifest
selection checks use `python3 scripts/ci/test-floorp-workspace-runtime.py`;
they use a header-only fixture to check selection, not a substitute native
runtime or a link-success claim.

The variable must be present in the process running SwiftPM/Xcode. An Xcode
instance launched from Finder does not inherit a terminal's exported variables.
Do not use a local override as evidence for a distributed release, or describe
it as the artifact recorded in the official release pin.

Without an override, the `.6` pin includes the real generated binding and
sets `FloorpWorkspaceRuntimeSupport.isAvailable` to `true`. The legacy
compatibility class remains available for an explicitly selected older pin
without the Workspace capability. Its constructor throws `runtimeUnavailable`;
it cannot register an engine, create a cache, or perform a substitute transport.
Notes keeps its independent release policy and existing engine.

## Publishing a compatible artifact

A distributed workspace-enabled build requires a real immutable Application
Services release containing the new native engine and matching generated
bindings. Update the checked-in release URL/checksums and
`FloorpApplicationServicesPin.json` to that actual release together, and add:

```json
"capabilities": { "floorpWorkspaces": true }
```

The explicit capability makes the package include the real generated binding
without a local environment override. It is already set for `.6`; `.5` does
not contain the required symbols and must not claim this capability. Revalidate
Notes against each new artifact and update its reviewed candidate identity
where required; a Workspace capability does not authorize or disable Notes.

### Importing the published release

The iOS pin validator requires a published, immutable **prerelease** in
`Floorp-Projects/application-services`. The tag must have the form
`floorp-ios-MAJOR.YYYYMMDDhhmmss.REVISION` and resolve directly to the recorded
source commit. The release contains exactly these five assets:

- `MozillaRustComponents.xcframework.zip`
- `FocusRustComponents.xcframework.zip`
- `swift-components.tar.xz`
- `release-manifest.json`
- `SHA256SUMS`

The release manifest, tagged source configuration, upstream revision, GitHub
asset metadata, and checksum inventory must agree. Use the release metadata
and downloaded bytes to record the real release ID, source commit/tree, sizes,
and SHA-256 values in `FloorpApplicationServicesPin.json`. Add the Workspace
capability only after checking that the published Mozilla framework exports
`floorp_workspaces_syncFFI.h` and its matching native symbols on every required
device/simulator slice. A simulator developer build is insufficient.

Then apply and verify the pin from the iOS repository root:

```sh
./scripts/ci/check-application-services-pin.sh --apply
./scripts/ci/check-application-services-pin.sh --verify-remote
./scripts/ci/test-application-services-pin-sync.sh
python3 scripts/ci/test-floorp-workspace-runtime.py
```

The `--apply` operation updates exactly the five managed `Package.swift`
literals. It does not import Swift bindings. Import the `all/Generated` and
`focus/Generated` wrapper directories from the verified
`swift-components.tar.xz` from that same release, retaining the repository's
existing policy of excluding `.h` files except `RustViaductFFI.h`, and excluding
`.modulemap` files. Do not run `update_from_application_services.py` for this
operation: it selects Mozilla archive/nightly URLs rather than the Floorp
immutable release.

Finally, unset `FLOORP_APPLICATION_SERVICES_XCFRAMEWORK`, resolve dependencies
from a clean build directory, and build/test the ordinary `Floorp` scheme with
the actual pinned binary. Confirm
`FloorpWorkspaceRuntimeSupport.isAvailable == true` without an override and run
the selected discovery/copy/Sync Manager/Notes tests. The manifest harness
always tests both legacy and capable selection using isolated metadata
fixtures; those fixtures neither download nor validate a native binary.

Use a new DerivedData directory when changing between `.5`, a local override
and `.6`. Xcode can otherwise retain a precompiled Clang module for the previous
framework at the same copied framework path. The ordinary build validation
uses fresh simulator and device DerivedData directories.

### Notes evidence boundary

The ordinary `FloorpRelease` configuration uses `release-default`. Its Notes
gate validates the production endpoint policy independently and does not
require a historical `.5` evidence file. Keep that behavior when updating the
Workspace runtime.

The strict `production-qa` and `release-enabled` paths additionally bind the
exact Application Services candidate. `FloorpNotesSyncReleaseGate` in
`firefox-ios/Floorp/FloorpNotesSync.swift` pins its commit, tree, tag, and five
asset digests; `scripts/staging/build-floorp-notes-sync-ios.sh` pins its
repository, tag, revision, commit, and tree before comparing evidence. Rebind
those code identities to the genuine new candidate when importing it. This
does not establish that its live Notes QA passed. Preserve historical QA
records and obtain new candidate-bound evidence before using either strict
enabled path. Until then, those paths must reject old or mixed evidence.

The strict candidate identities now refer to the real `.6` artifact. Historical
`.5` QA JSON remains unchanged, and the test suite separately verifies that it
cannot authorize the new candidate. Candidate-bound authenticated Notes QA is
still pending; updating the dependency and its code identities makes no live
QA claim. The ordinary `release-default` Notes policy remains enabled.

Native link checks, paging/version/association transport tests, Notes and
standard Sync regressions, and Desktop-to-iPhone/iPad interoperability remain
release requirements. A local successful build alone does not complete them.
