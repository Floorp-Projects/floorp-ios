# Floorp for iOS CI/CD

This document defines the delivery foundation for Floorp for iOS. The repository has a reproducible pull-request gate, a dedicated release configuration, a validated signed Internal TestFlight baseline, and an explicit cloud-delivery path for routine TestFlight builds.

## Architecture

| Concern | System | Current state |
| --- | --- | --- |
| Pull-request build and unit tests | GitHub Actions | Implemented in `.github/workflows/ci.yml` |
| Notes Sync production QA | GitHub Actions | Manual, protected workflow in `.github/workflows/floorp-notes-sync-production-qa.yml` |
| Notes Sync public-beta QA | GitHub Actions | Separate manual, protected two-account workflow in `.github/workflows/floorp-notes-sync-public-beta-qa.yml` |
| Signed public-beta delivery | Xcode Cloud | Source-bound `workflow_dispatch` bridge in `.github/workflows/floorp-xcode-cloud-testflight.yml` |
| Upstream Firefox synchronization | GitHub Actions | Weekly draft-PR workflow with trusted automation restoration, reviewed localization conflict resolution, and explicit CI dispatch |
| Signed archive and internal TestFlight | Manual Xcode upload | `0.1.0 (2)` signed, uploaded, and verified by the internal group |
| Repeatable signed delivery | Xcode Cloud | Configured as `Floorp TestFlight Manual`; archive, signing, and App Store Connect distribution run in Xcode Cloud |
| App Store release | App Store Connect | Manual approval initially |
| Mozilla/Focus maintenance automation | Git history | Removed pending a Floorp-owned replacement |

GitHub Actions never receives signing certificates or provisioning profiles for the public-beta path. The bridge receives only the protected App Store Connect API key needed to start and inspect the pinned Xcode Cloud workflow. Xcode Cloud performs archive, signing, and App Store Connect distribution; no certificate, profile, p8 key, or password is committed.

### Validated Internal TestFlight baseline

On August 1, 2026, Floorp `0.1.0 (2)` was signed by Team `DV2U35YBHT`, uploaded to App Store Connect app `6796708699`, processed successfully, assigned to the `Floorp Internal` group, and installed by an internal tester. App Store Connect read `ITSAppUsesNonExemptEncryption=false` as “Uses non-exempt encryption: No.”

The upload reported a non-blocking missing dSYM warning for `Glean.framework`.
`FloorpRelease` archives now generate and retain a UUID-matched Glean dSYM
companion after embedding the framework, and fail the archive if the UUID set
does not match. Confirm that the warning is absent on the next signed upload.
The upstream Glean 69 binary contains no source-level DWARF, so this companion
cannot restore source/line symbolication that upstream did not publish.

## CI contract

The `Floorp iOS CI` workflow runs for pull requests and pushes to `main` and performs these steps:

1. Validate Floorp branding, the Floorp-owned Application Services binary pin, and active workflow files.
2. Select the Xcode version in `.xcode-version` and Node.js version in `.nvmrc`.
3. Re-extract the localization policy from immutable reviewed commits, run its tests, and verify generated resources against the newest upstream commit already contained by the branch.
4. Install Node dependencies with `npm ci`, generate web assets, and reject high-severity npm advisories.
5. Download the pinned Nimbus helper and SwiftLint binary, verifying downloads with SHA-256 checksums.
6. For normal pull requests, run SwiftLint in strict mode for added or modified Swift files outside the inherited Focus tree. Existing inherited lint debt does not make the initial gate permanently red. Pushes and the explicitly dispatched upstream-sync build skip this step.
7. Resolve only the Swift package versions in `Package.resolved`.
8. Build `Fennec` with `Fennec_Testing` and the `FloorpCI` plan for an iOS Simulator with code signing disabled.
9. Run the already-built `FloorpCI` plan and retain diagnostics for seven days only when the job fails.

`FloorpCI.xctestplan` has 17 target entries: 14 currently reliable broad suites plus explicit allowlists from `AccountTests`, `ClientTests`, and `MozillaRustComponentsTests`. It pins the test language and region to `en-US` and `US` so localized system messages cannot make the result depend on the runner locale. The inherited `UnitTest` plan and the rest of `ClientTests` are intentionally not required checks yet because unqualified Client tests still hit Floorp telemetry/dependency-container failures. Selecting individual cases still compiles the whole `ClientTests` target, so additions must pass a clean `build-for-testing` before promotion. Validate the remaining suites independently and promote each passing suite into `FloorpCI`; never hide a regression by removing a previously passing suite.

SwiftPM checkouts and Derived Data use job-local directories. This avoids shared-cache corruption and keeps untrusted pull-request code out of persistent caches.

`MozillaRustComponents/Package.swift` obtains both binary targets from a published immutable release in `Floorp-Projects/application-services`, rather than Mozilla's mutable Taskcluster index. `FloorpApplicationServicesPin.json` records the release tag, source commit and tree, authoritative source configuration, complete asset inventory, and SwiftPM checksums. CI checks that the package manifest still matches that lock and simulates both clean and conflicting upstream Application Services bumps. The upstream-sync workflow retains the upstream `Package.swift`, reapplies only the five managed literals from the trusted Floorp lock, and fails if their declaration shape changes; unrelated upstream package edits remain intact.

Before changing the lock, run `./scripts/ci/check-application-services-pin.sh --verify-remote`. This additionally verifies the live release is published and immutable, the tag resolves to the recorded commit, GitHub reports the recorded commit tree, the tagged source release configuration pins the recorded Mozilla repository, commit, source version, and artifact version, and the upstream commit exists. It also checks the complete release asset metadata, the small release manifest and SHA256SUMS downloads, and both binary download URLs without downloading the XCFramework archives.

Dependabot checks GitHub Actions and npm dependencies monthly. External actions remain pinned to immutable commit SHAs.

The upstream workflow validates and restores the complete trusted Floorp workflow, rebrand, localization-policy, and Application Services pin controls before executing them, so upstream-only automation cannot become active accidentally. Protected automation conflicts are resolved from the Floorp base. Localization conflicts are accepted only when the reviewed overlay proves that `ours` is generated from the merge base and can safely regenerate the complete upstream resource. An Application Services package conflict starts from the complete upstream manifest and reapplies only Floorp's five locked literals. Every other conflict aborts without publishing a branch and retains a short-lived diagnostic artifact. The workflow explicitly dispatches `ci.yml` for `automation/upstream-sync` after creating or updating the draft PR, instead of relying on the approval state and trigger behavior of events produced by `GITHUB_TOKEN`. The generated branch is disposable and must not receive manual fixes.

## GitHub repository settings

The live merge and release rules for `main` are captured in the branch
ruleset **Protect Floorp iOS main** (`gh api repos/Floorp-Projects/floorp-ios/rulesets/<id>`).
The machine-readable contract below is validated against the live ruleset by
`scripts/ci/check_repository_governance.py`; the documentation and the live
ruleset must not drift.

```governance
{
  "name": "Protect Floorp iOS main",
  "target": "branch",
  "enforcement": "active",
  "refs": ["refs/heads/main"],
  "required_approving_review_count": 0,
  "required_review_thread_resolution": true,
  "required_status_checks": ["Validate workflows", "Build and unit test"],
  "bypass_actors": [{"actor_type": "OrganizationAdmin", "bypass_mode": "pull_request"}]
}
```

Notes on the live contract:

- Pull requests are required with conversation resolution and stale-review
  dismissal. The live approving-review count is currently `0`; the intended
  policy is at least one approval, and raising `required_approving_review_count`
  to `1` is a tracked follow-up. Do not weaken the ruleset below the documented
  contract.
- Required checks are the job names `Validate workflows` and
  `Build and unit test` from `.github/workflows/ci.yml`.
- Force pushes and branch deletion are blocked. Only OrganizationAdmin may
  bypass pull-request rules (`pull_request` mode); there is no separate
  release-maintainer bypass group yet.
- The upstream sync branch `automation/upstream-sync` is disposable: it is
  regenerated by the workflow, receives no manual commits, and its PR is
  merged by squash from the reviewed head OID only.

## Execution worktrees, blockers, and external mutations

- Task work executes in disposable worktrees under `.omo/worktrees/` at the
  exact recorded dependency SHA; the stale local checkout is never used.
- Missing permissions, agreements, ownership, external review, upstream
  artifacts, or dependencies are recorded as exact blockers
  (`AUTHORIZATION_MISSING`, `AGREEMENT_MISSING`, `OWNER_APPROVAL_MISSING`,
  `EXTERNAL_REVIEW_PENDING`, `UPSTREAM_ARTIFACT_MISSING`,
  `DEPENDENCY_BLOCKED`) with an owner, missing prerequisite, and resume
  condition. Blocked tasks are never reported as complete.
- Every external mutation (GitHub merge, branch/issue/PR writes, App Store
  Connect, Xcode Cloud) runs the read-only preflight, captures prior state
  and immutable target IDs, applies an idempotent mutation keyed by those IDs,
  and diffs the post-state. A missing permission stops with zero mutation.

## Release readiness

Do not create an App Store archive from `Fennec`; it remains a development configuration. Use the shared `Floorp` scheme and its `FloorpRelease` Archive action. The repository-side release scaffold is implemented; every release candidate still requires a signed archive and Organizer validation before TestFlight distribution. `FloorpRelease` now uses the reviewed `release-default` Notes Sync policy, so ordinary internal and public TestFlight builds exercise the optional Sync feature against production FxA/Sync. The separate protected `floorp-notes-sync-public-beta-qa.yml` workflow and its evidence wrapper remain available for dedicated two-client integrity validation; they are not a prerequisite for the normal Xcode Cloud TestFlight workflow. The Xcode Cloud bridge does require a successful exact-source `Floorp iOS CI` run and its dedicated uBlock Origin Lite acceptance artifact before it can start the immutable tagged candidate.

### Release build configuration

`Fennec.xcconfig` inherits the debug configuration and is intentionally unsuitable for distribution. `FloorpRelease.xcconfig` instead uses release optimization and dSYMs, selects the release Nimbus channel, enables the reviewed `release-default` Notes Sync policy, and disables assertions, testability, coverage instrumentation, and the Settings bundle. The shared `Floorp` scheme uses this configuration for Profile, Analyze, and Archive while retaining the existing development configuration for local Run and the `FloorpCI` plan for Test.

The release configuration uses automatic signing and leaves provisioning-profile selectors empty. An unsigned generic-device build is the repository-level validation baseline; a signed archive and Organizer validation remain required.

### Signing team

Mozilla team identifiers remain in upstream-only configurations. `FloorpRelease` instead resolves `DEVELOPMENT_TEAM` from the confirmed Floorp Team ID `DV2U35YBHT`. Xcode and Xcode Cloud must still obtain a valid signing identity and provisioning profile for that team, then validate that the archived app is signed by it. The Team ID is not a secret; certificates and private keys must never be committed.

The `Floorp` scheme's Run and Test actions still use the inherited Fennec development configurations. Treat them as Simulator-only until a Floorp-owned debug signing configuration replaces the inherited Mozilla team.

### Bundle IDs and extensions

The main release bundle ID is `app.floorp.Floorp`. The initial Internal TestFlight build is Client-only. `FloorpRelease` excludes all six inherited extension products and explicit target dependencies: Widget, Notification Service, Credential Provider, Sticker, Action, and Share.

Only the main App ID is required for the first build. Extension configurations remain available for future work, but an extension must be fully branded, capability-reviewed, registered, signed, and tested before being added back to `FloorpRelease`.

### App Group and Keychain groups

The Floorp release entitlements use the Team-owned `group.app.floorp.Floorp.DV2U35YBHT` App Group and the separate `$(AppIdentifierPrefix)app.floorp.Floorp` keychain access group. The shorter App Group was unavailable to Team `DV2U35YBHT`, so `FloorpReleaseInfo.plist` provides the Team-scoped value to runtime code through `MozSharedContainerIdentifier`; upstream configurations continue deriving their group from the bundle ID. This happened before the first production release, so there is no production shared-container migration. Sticker has no shared-container entitlement. Grant App Group and keychain access only to retained targets that actually share those data.

Because the initial release excludes Credential Provider, the main app's AutoFill Credential Provider entitlement is also omitted.

### Push notifications

The Floorp release entitlement intentionally omits APNs, and the current beta plan therefore has no Push support. Its dedicated Info.plist also omits the `remote-notification` background mode. `FloorpRelease` applies a fail-closed runtime policy before APNs registration and Mozilla Autopush construction, clears any APNs registration retained from an older build, ignores stale remote notification delivery, hides the Sync-notification setting, suppresses notification-permission onboarding that advertises Sync Push, and suppresses account-flow Push prompts. Notification Service is excluded from `FloorpRelease`. Local Tips and notification-surface delivery remain available through Settings.

Adding Push later requires restoring that target where needed, production entitlements, the Floorp App ID capability, a Floorp-owned APNs key, and a Floorp-owned or explicitly authorized backend. Enabling a Nimbus feature or user preference alone cannot bypass the release policy.

### Managed browser entitlements

Apple has assigned `com.apple.developer.web-browser` to `app.floorp.Floorp`. `FloorpReleaseApplication.entitlements` declares it as `true`, allowing eligible signed builds to appear in iOS’s Default Browser App settings. `FloorpReleaseInfo.plist` already registers the required `http` and `https` URL schemes.

The capability is managed. Before producing a distribution archive, let Xcode refresh the automatically managed provisioning profile for Team `DV2U35YBHT`, then verify the signed archive contains `com.apple.developer.web-browser = true`.

The Floorp release entitlement continues to omit `com.apple.developer.browser.app-installation`, which is for installing alternative-distribution apps from a website. Add it only if Floorp deliberately adopts that distribution path and Apple approves the request.

### Versioning

The last validated Internal TestFlight baseline is `0.1.0 (2)`, and the checked-in native WebExtensions release candidate is `0.3.0 (4)`. The main app and all extension Info.plists consume the shared marketing version and build number. Approve the independent Floorp marketing-version policy; Xcode Cloud can assign monotonically increasing distribution build numbers after its TestFlight workflow is configured.

### Floorp-owned services and App Store ID

The initial Floorp service policy keeps FxA/Sync, Remote Settings/Nimbus, and the existing Mozilla content services enabled. It disables remote Push, Hosted Summarizer (including its App Attest authentication path), and Quick Answers. Apple Intelligence summarization remains independently available on supported devices and executes on-device. All three disabled services are protected by `FloorpRelease` Info.plist policy values in addition to their normal feature flags, so a remote Nimbus rollout cannot re-enable them.

Continue reviewing Sentry and every retained endpoint before public distribution. Where ownership is unresolved, disable the feature rather than silently using an inherited production default. Xcode Cloud secret variables prevent values from appearing in logs, but any value embedded in the app bundle remains extractable and must not be a privileged server secret.

Firefox's App Store ID has been removed. `FLOORP_APP_STORE_ID` is optional; while it is unset or invalid, Floorp hides the rating setting and does not open a review URL. Set it to Floorp's numeric Apple ID only after the public App Store listing is live.

### Release branding

The primary classic and Liquid Glass icon sources render the Floorp logo, and `FloorpRelease` selects the canonical `AppIcon` set. The classic default/marketing PNG is full-bleed and opaque; its Dark and Tinted variants follow Apple's appearance-specific asset rules. The Liquid Glass layer filenames still say `nightly`; those internal filenames are cleanup work, not a TestFlight blocker. `FloorpRelease` excludes the inherited Firefox alternate icons. Review the remaining main-app names, artwork, localized strings, and product metadata; repeat that review before restoring any extension.

## Apple account checklist

Complete the remaining unchecked steps before broad public distribution:

- [ ] Decide whether the Apple Developer account is permanently owned by a Floorp organization or an individual; avoid a later transfer if possible.
- [x] Confirm the Apple Developer Team ID: `DV2U35YBHT`.
- [x] Confirm an App Store Connect Account Holder, Admin, App Manager, or Developer with Create Apps permission can perform setup.
- [ ] Confirm a GitHub organization owner can authorize the initial Xcode Cloud connection.
- [ ] Accept all current Apple Developer and App Store Connect agreements.
- [x] Create or confirm the `app.floorp.Floorp` App ID.
- [ ] Decide whether development builds use a separate bundle ID such as `app.floorp.Floorp.Developer`.
- [x] Ship Client-only in the initial Internal TestFlight build; exclude all six inherited extensions from `FloorpRelease`.
- [x] Register `group.app.floorp.Floorp.DV2U35YBHT` and assign it to every retained target that shares data.
- [x] Omit Push/APNs and AutoFill Credential Provider from the initial Client-only release.
- [ ] Confirm Multipath remains a product requirement; it is currently retained because networking code uses `.handover`.
- [x] Disable Hosted Summarizer, its App Attest path, and Quick Answers; retain Apple on-device summarization.
- [x] Request and enable the default-browser managed entitlement.
- [x] Omit the browser app-installation entitlement from the initial release configuration.
- [ ] Choose the Floorp marketing-version policy and initial version.
- [x] Create the Floorp app record in App Store Connect (`6796708699`).
- [ ] Set `FLOORP_APP_STORE_ID` after the public App Store listing is live.
- [ ] Replace remaining inherited main-app branding; review extension branding before any extension is restored.
- [x] Create the `Floorp Internal` TestFlight group and add the initial tester.
- [ ] Assign an owner and safe client-side value for each external service setting used by the release configuration.
- [x] Produce a signed `Floorp` archive, upload it, and install the processed build through Internal TestFlight.
- [x] Add `APPLE_DEVELOPER_API_KEY_JSON` to the `floorp-testflight` GitHub Environment for the Actions-to-Xcode-Cloud trigger; keep signing certificates and profiles out of GitHub.

Do not commit certificates, provisioning profiles, `.p8` API keys, `.p12` files, or passwords.

## Xcode Cloud rollout

The repository includes `firefox-ios/ci_scripts/ci_post_clone.sh` and
`ci_pre_xcodebuild.sh`. Xcode Cloud discovers them next to `Client.xcodeproj`;
the post-clone script downloads the `.nvmrc` Node.js release with a pinned
checksum and runs the root bootstrap in the clean clone. Before a `Floorp`
archive only, the pre-build script requires the exact protected catalog tag in
both `CI_TAG` and canonical `CI_GIT_REF`, requires `CI_COMMIT` to match the
checked-out Git `HEAD`, and atomically injects that SHA into the single empty
`FLOORP_SOURCE_SHA` release setting. Other schemes and non-archive actions do
not mutate the setting. For the App Store Connect API-started release path,
Xcode Cloud exposes `CI_TEAM_ID` as the App Store Connect team resource UUID
`74c6a531-19e2-4ed5-a34b-915003cc10f9`; the pre-build script verifies that
identity. This is distinct from the signing Developer Team ID `DV2U35YBHT`,
which the script independently verifies in `FloorpRelease.xcconfig` and the
release-evidence gate verifies again from the signed app and provisioning
profile. `.nvmrc` and `.xcode-version` are declarations for
developers and GitHub Actions, not settings that Xcode Cloud applies
automatically.

Immediately after verifying source identity, the GitHub Actions bridge runs
`validate-floorp-privacy.py` against the checked-in endpoint matrix and App
Store Connect privacy/export declarations. This happens before a protected
GitHub token or App Store Connect credential is exposed to a
repository-controlled release command, and before any external release
mutation. The initial checkout necessarily authenticates the exact source
fetch, but uses `persist-credentials: false`. This is a declaration-consistency
gate, not runtime network evidence: the deployment does not fabricate or pass
a `--trace` or `--static-endpoints` artifact. Those optional checks run only
when real evidence is explicitly provided, and an explicitly named but missing
file is rejected as malformed. IPA identity and signature verification belong
to the release-evidence gate; the privacy validator has no `--ipa` input.

The shared `Floorp` scheme now archives with `FloorpRelease` in Xcode Cloud. The existing workflow is manually started in App Store Connect, and the repository also provides a GitHub Actions bridge for the same explicit operation:

1. In Signing & Capabilities, explicitly confirm the main `app.floorp.Floorp` bundle ID once before initial setup because the project derives it from an `.xcconfig` file. Register extension IDs only when those targets return to the release.
2. Connect `Floorp-Projects/Floorp-iOS` to Xcode Cloud from Xcode's Report navigator. A GitHub organization owner must authorize the first connection.
3. Keep `Floorp TestFlight Manual` manually started in Xcode Cloud, but start public-release candidates only through the GitHub Actions bridge. A direct App Store Connect start does not produce the source-bound release receipt and is not eligible for submission. Release builds use a protected immutable `floorp-catalog-<40-character merged SHA>` lightweight tag whose ref points directly at the exact reviewed `main` commit; annotated tags are rejected by the source-identity gate. Never delete or retarget a candidate tag after creating it, including when its build fails. Xcode Cloud supplies the tag/ref/commit values embedded by the pre-build script; the bridge and retained receipt remain responsible for resolving the live App Store Connect tag reference and proving that it points to that commit. A local `refs/tags/*` ref is not assumed in Xcode Cloud's detached checkout.
4. Use `.github/workflows/floorp-xcode-cloud-testflight.yml`. It verifies the immutable tag and exact-source CI acceptance, validates the workflow repository and product against App Store Connect app `6796708699` / bundle `app.floorp.Floorp`, snapshots the current maximum build number, and starts the tagged run through `POST /v1/ciBuildRuns`.
5. The bridge always waits for `COMPLETE` / `SUCCEEDED`, rechecks the exact source commit and workflow, and requires exactly one nonpaginated run-to-build linkage. The linked build must be a new, larger build number for Floorp `0.3.0` on iOS, `VALID`, `APP_STORE_ELIGIBLE`, unexpired, non-exempt-encryption false, and minimum OS `18.4`.
6. The bridge downloads the unique `ARCHIVE` and `ARCHIVE_EXPORT` resources from the same successful archive action through the authenticated App Store Connect API. It verifies the recorded resource IDs, types, sizes, and SHA-256 values, safely materializes the `.xcarchive` and `.ipa`, and emits `floorp-xcode-cloud-artifact-manifest.json`. Retain that manifest together with `floorp-xcode-cloud-build-receipt.json`. The workflow also materializes a notes-only App Review payload from the receipt; it rejects placeholders, a missing immutable public source URL or GPL disclosure, and content over 4,000 bytes.
7. Before any external-beta write, `submit-floorp-external-beta.sh` re-reads the run, run-to-build linkage, build, and group. It requires the receipt and all expected source/build values, and requires the selected group to be external and belong to the same app. Contact fields must be complete; demo credentials are required only when App Store Connect reports `demoAccountRequired=true`. The client never creates groups or writes contact/demo credentials.
8. Let Xcode Cloud manage signing; verify the Client-only app is signed by the Floorp team and inspect its production entitlements. Confirm `firefox-ios/TestFlight/WhatToTest.en-US.txt`. The bridge retains the raw downloads, materialized archive/IPA, manifest, evidence, and dSYMs in one binary-evidence artifact and retains the deployment receipt in a separate receipt artifact; both use 90-day retention. Xcode Cloud itself retains artifacts for only 30 days.

## Later hardening

- Add a non-blocking manual or scheduled full `UnitTest` run with `.xcresult` retention while the remaining suites are repaired and promoted into `FloorpCI`.
- Restore a legacy maintenance workflow from Git history only after assigning a Floorp owner, removing Mozilla secrets and destinations, and pinning every external action.
- Split stable UI smoke tests into a nightly workflow after the simulator unit-test gate is reliable.
- Keep the `floorp-testflight` GitHub Environment limited to the App Store Connect API key needed to start and monitor Xcode Cloud; do not add signing certificates or profiles.
- Keep the pinned Nimbus script revision aligned with Application Services updates during upstream synchronization.
- Add CODEOWNERS for `.github/workflows/`, `scripts/ci/`, and `firefox-ios/ci_scripts/` after the Floorp GitHub maintainer team slug is known.

## Official references

### Release evidence, retention, and rollback

The marketing version is reviewed in the repository (`FloorpRelease.xcconfig`),
while Xcode Cloud owns monotonically increasing distribution build numbers. The
bridge snapshots all existing Floorp build IDs and the maximum build number
before starting the run, then accepts only the single new build linked from that
run. A release candidate is identified by its immutable source SHA, Xcode Cloud
run/workflow IDs, App Store Connect app/build IDs, marketing version, platform,
and build number in the retained receipt.

`scripts/release/collect-floorp-release-evidence.sh` binds each candidate to
its source SHA (also embedded as `MozFloorpSourceSHA` in the archive and IPA),
archived marketing version/build, signing identity,
entitlements, a deterministic full-tree archive SHA-256 (regular-file bytes,
relative paths, entry types, and symbolic-link targets), the IPA digest, and
the dSYM UUID inventory. IPA extraction is mandatory for a local export;
archive-only evidence deliberately leaves every IPA field empty.
`scripts/release/validate-floorp-release-evidence.py` re-verifies the document
against `scripts/release/floorp-release-evidence.schema.json` and rejects mixed
build IDs, a missing default-browser entitlement, forbidden entitlements, missing
dSYMs, fake dSYM paths, and digest mismatches. It re-runs `dwarfdump` over both
the retained dSYMs and every shipped app, framework, and app-extension binary.
It also re-reads the real archive and IPA Info.plists, verifies the actual code
signatures against the Apple trust anchor and Floorp team, and requires the recorded entitlements to exactly match the signed
artifact selected by `--artifact-kind`. For `archive-only`, that artifact is
the signed app in the archive; for `local-export`, it is the single direct
`Payload/*.app` in the IPA. An unsigned archive is not valid release evidence,
even during pre-upload validation. A local export must use an Apple Distribution
leaf certificate and an Apple-verified embedded App Store provisioning profile
whose team, application identifier, and authorized leaf certificate match the
signature. For a local export, every app, framework,
and app-extension executable must have the same bundle-relative path and
Mach-O UUID set as the archive, and those IPA UUIDs must also be covered by the
retained dSYMs.

Validation is phase- and artifact-specific. A pre-upload check accepts either
`--artifact-kind archive-only` or `--artifact-kind local-export`; the latter
also requires `--expected-export-status ready-for-upload`. A publication check
requires `--phase publication` with expected export state
`uploaded-and-processed`, `--artifact-kind local-export`, the expected GitHub
Actions run URL and App Store
Connect build ID, plus the retained Xcode Cloud receipt, authenticated artifact
manifest, and their externally
known run/workflow/app/platform/minimum-OS identity. The receipt is passed back
through `floorp_xcode_cloud_build_receipt.validate_receipt` and cross-checked
with the release evidence. The artifact manifest must name the same run and
successful archive action, two distinct `ARCHIVE` / `ARCHIVE_EXPORT` resource
IDs, retained download bytes, and the exact materialized archive tree and IPA
digests recorded by the evidence. Source SHA, marketing version, build number, bundle
ID, CI/Xcode run IDs, App Store Connect IDs, and export state must come from the
trusted release invocation or live API lookup; never copy them out of the
evidence or receipt being checked. The old evidence/schema-only CLI invocation
is intentionally rejected with exit status 2. Publication with
`archive-only` is rejected. The supported Xcode Cloud publication path is the
bridge's authenticated download of the exact run's `ARCHIVE` and
`ARCHIVE_EXPORT`, followed by safe materialization and local-export validation;
a receipt-only direct submission remains ineligible.

The evidence is also path-bound within the same publication job: archive and IPA paths are canonical absolute
paths, and the collector refuses to create evidence inside the archive,
overwrite the IPA, or overwrite an existing evidence document. Retain the
raw authenticated downloads, archive, IPA (when present), dSYMs, artifact
manifest, and evidence JSON as one binary-evidence artifact, and retain the
deployment receipt artifact beside it under the same immutable retention
policy. Absolute paths bind the same publication job and are not portable
across machines; later audits can re-materialize a fresh bundle from the
retained raw downloads and recompute the digests. The tree digest detects a
changed artifact; it does not make a rewritten evidence JSON trustworthy on
its own.

An archive-only pre-upload gate therefore has this minimum shape:

```sh
scripts/release/validate-floorp-release-evidence.py \
  --evidence "$EVIDENCE" \
  --schema scripts/release/floorp-release-evidence.schema.json \
  --phase pre-upload \
  --artifact-kind archive-only \
  --expected-source-sha "$SOURCE_SHA" \
  --expected-marketing-version "$MARKETING_VERSION" \
  --expected-build-number "$BUILD_NUMBER" \
  --expected-bundle-id app.floorp.Floorp
```

At publication, add the externally obtained identity and receipt:

```sh
scripts/release/validate-floorp-release-evidence.py \
  --evidence "$EVIDENCE" \
  --schema scripts/release/floorp-release-evidence.schema.json \
  --phase publication \
  --artifact-kind local-export \
  --expected-source-sha "$SOURCE_SHA" \
  --expected-marketing-version "$MARKETING_VERSION" \
  --expected-build-number "$BUILD_NUMBER" \
  --expected-bundle-id app.floorp.Floorp \
  --expected-ci-run-url "$CI_RUN_URL" \
  --expected-export-status uploaded-and-processed \
  --expected-app-store-connect-build-id "$ASC_BUILD_ID" \
  --xcode-cloud-build-receipt "$XCODE_CLOUD_RECEIPT" \
  --xcode-cloud-artifact-manifest "$XCODE_CLOUD_ARTIFACT_MANIFEST" \
  --expected-xcode-cloud-run-id "$XCODE_CLOUD_RUN_ID" \
  --expected-xcode-cloud-workflow-id "$XCODE_CLOUD_WORKFLOW_ID" \
  --expected-app-id 6796708699 \
  --expected-platform IOS \
  --expected-min-os-version 18.4
```

`scripts/release/app-store-connect-api.py` is the only App Store Connect
surface. Its read allowlist covers the required workflow, repository, and Git
reference GETs and its write allowlist is
exactly `POST /v1/ciBuildRuns`, `POST /v1/betaBuildLocalizations`,
`PATCH /v1/betaBuildLocalizations/{id}`, `PATCH /v1/betaAppReviewDetails/{id}`,
`POST /v1/betaAppReviewSubmissions`, and
`POST /v1/betaGroups/{id}/relationships/builds`. Every other write route,
including group creation, is denied before any request. Writes require the
intended object ID, a prior-state SHA-256, and `--authorize-mutation`;
`--dry-run` issues zero requests.

Retention: source-bound receipts and rendered review notes are retained for 90
days; release evidence documents, `.xcresult` bundles, archives, IPAs, and dSYM
inventories follow the release retention policy. The REST client intentionally
has no delete route. Stop testing or remove a defective build from groups in App
Store Connect under an authorized operator account; never reinterpret an older
build as the current candidate. Xcode Cloud, not the REST client or GitHub
Actions, uploads the signed archive.

- [GitHub Actions repository settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
- [Triggering a workflow with `GITHUB_TOKEN`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)
- [GitHub-hosted macOS runner images](https://github.com/actions/runner-images)
- [Writing Xcode Cloud custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
- [Xcode Cloud environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference)
- [Making dependencies available to Xcode Cloud](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud)
- [Configuring the first Xcode Cloud workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)
- [Including TestFlight notes](https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app)
- [Preparing an app to be the default browser](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser)
- [Requesting managed capabilities](https://developer.apple.com/help/account/capabilities/capability-requests/)
- [`com.apple.developer.browser.app-installation`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.browser.app-installation)
