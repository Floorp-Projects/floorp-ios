# Floorp for iOS CI/CD

This document defines the delivery foundation for Floorp for iOS. The repository has a reproducible pull-request gate, a dedicated release configuration, and a validated signed Internal TestFlight baseline. Repeatable cloud delivery, retained main-app capabilities, and service ownership still need to be finalized before public distribution.

## Architecture

| Concern | System | Current state |
| --- | --- | --- |
| Pull-request build and unit tests | GitHub Actions | Implemented in `.github/workflows/ci.yml` |
| Notes Sync production QA | GitHub Actions | Manual, protected workflow in `.github/workflows/floorp-notes-sync-production-qa.yml` |
| Notes Sync public-beta QA | GitHub Actions | Separate manual, protected two-account workflow in `.github/workflows/floorp-notes-sync-public-beta-qa.yml` |
| Signed public-beta delivery | GitHub Actions | Manual, source-bound workflow in `.github/workflows/floorp-public-beta-release.yml` |
| Upstream Firefox synchronization | GitHub Actions | Weekly draft-PR workflow with trusted automation restoration, reviewed localization conflict resolution, and explicit CI dispatch |
| Signed archive and internal TestFlight | Manual Xcode upload | `0.1.0 (2)` signed, uploaded, and verified by the internal group |
| Repeatable signed delivery | Xcode Cloud | Scaffold implemented; workflow not yet configured |
| App Store release | App Store Connect | Manual approval initially |
| Mozilla/Focus maintenance automation | Git history | Removed pending a Floorp-owned replacement |

The public-beta release job receives signing and App Store Connect material only as protected GitHub secrets for the one approved run; no certificate, profile, p8 key, or password is committed. The first build was uploaded manually from a locally signed archive. Xcode Cloud remains the preferred repeatable CD system for routine delivery because it supports cloud-managed signing and direct TestFlight distribution.

### Validated Internal TestFlight baseline

On August 1, 2026, Floorp `0.1.0 (2)` was signed by Team `DV2U35YBHT`, uploaded to App Store Connect app `6796708699`, processed successfully, assigned to the `Floorp Internal` group, and installed by an internal tester. App Store Connect read `ITSAppUsesNonExemptEncryption=false` as “Uses non-exempt encryption: No.”

The upload reported a non-blocking missing dSYM warning for `Glean.framework`. Resolve that warning before relying on production crash symbolication.

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

`FloorpCI.xctestplan` has 16 target entries: 14 currently reliable broad suites plus explicit allowlists from `AccountTests` and `ClientTests`. It pins the test language and region to `en-US` and `US` so localized system messages cannot make the result depend on the runner locale. The inherited `UnitTest` plan and the rest of `ClientTests` are intentionally not required checks yet because unqualified Client tests still hit Floorp telemetry/dependency-container failures. Selecting individual cases still compiles the whole `ClientTests` target, so additions must pass a clean `build-for-testing` before promotion. Validate the remaining suites independently and promote each passing suite into `FloorpCI`; never hide a regression by removing a previously passing suite.

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

Do not create an App Store archive from `Fennec`; it remains a development configuration. Use the shared `Floorp` scheme and its `FloorpRelease` Archive action. The repository-side release scaffold is implemented; every release candidate still requires a signed archive and Organizer validation before TestFlight distribution. A Notes Sync public-beta candidate uses the separate protected `floorp-notes-sync-public-beta-qa.yml` workflow, then `scripts/release/create-floorp-notes-sync-public-beta-evidence.py` and `scripts/release/build-floorp-notes-sync-public-beta.sh`; the checked-in `FloorpRelease` default remains Sync-disabled. The manual `floorp-public-beta-release.yml` workflow can consume that exact QA run, sign and upload the candidate, and submit it to an already-existing external TestFlight group after the live App Store Connect review details pass a read-only preflight.

### Release build configuration

`Fennec.xcconfig` inherits the debug configuration and is intentionally unsuitable for distribution. `FloorpRelease.xcconfig` instead uses release optimization and dSYMs, selects the release Nimbus channel, and disables assertions, testability, coverage instrumentation, and the Settings bundle. The shared `Floorp` scheme uses this configuration for Profile, Analyze, and Archive while retaining the existing development configuration for local Run and the `FloorpCI` plan for Test.

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

The private Internal TestFlight line intentionally omits `com.apple.developer.web-browser`. Apple has not approved that managed capability for the Floorp App ID, so these builds will not appear as a default-browser choice. Apple's request form requires an App Store build or a public TestFlight link, so the request is intentionally deferred while distribution remains private. When Floorp adopts external testing or public distribution, first provide an assessment build without the entitlement; after Apple approves the request, enable the capability for `app.floorp.Floorp`, regenerate the distribution profile, re-add the entitlement, and verify it in the signed archive.

The Floorp release entitlement omits `com.apple.developer.browser.app-installation`, which is for installing alternative-distribution apps from a website. Add it only if Floorp deliberately adopts that distribution path and Apple approves the request.

### Versioning

The last validated Internal TestFlight baseline is `0.1.0 (2)`, and the checked-in Web panel sidebar candidate is `0.1.0 (3)`. The main app and all extension Info.plists consume the shared marketing version and build number. Approve the independent Floorp marketing-version policy; Xcode Cloud can assign monotonically increasing distribution build numbers after its TestFlight workflow is configured.

### Floorp-owned services and App Store ID

The initial Floorp service policy keeps FxA/Sync, Remote Settings/Nimbus, and the existing Mozilla content services enabled. It disables remote Push, Hosted Summarizer (including its App Attest authentication path), and Quick Answers. Apple Intelligence summarization remains independently available on supported devices and executes on-device. All three disabled services are protected by `FloorpRelease` Info.plist policy values in addition to their normal feature flags, so a remote Nimbus rollout cannot re-enable them.

Continue reviewing Sentry and every retained endpoint before public distribution. Where ownership is unresolved, disable the feature rather than silently using an inherited production default. Xcode Cloud secret variables prevent values from appearing in logs, but any value embedded in the app bundle remains extractable and must not be a privileged server secret.

Firefox's App Store ID has been removed. `FLOORP_APP_STORE_ID` is optional; while it is unset or invalid, Floorp hides the rating setting and does not open a review URL. Set it to Floorp's numeric Apple ID only after the public App Store listing is live.

### Release branding

The primary classic and Liquid Glass icon sources render the Floorp logo, and `FloorpRelease` selects the canonical `AppIcon` set. The classic default/marketing PNG is full-bleed and opaque; its Dark and Tinted variants follow Apple's appearance-specific asset rules. The Liquid Glass layer filenames still say `nightly`; those internal filenames are cleanup work, not a TestFlight blocker. `FloorpRelease` excludes the inherited Firefox alternate icons. Review the remaining main-app names, artwork, localized strings, and product metadata; repeat that review before restoring any extension.

## Apple account checklist

Complete the remaining unchecked steps before enabling repeatable Xcode Cloud distribution or public beta delivery:

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
- [ ] Request the default-browser managed entitlement.
- [x] Omit the browser app-installation entitlement from the initial release configuration.
- [ ] Choose the Floorp marketing-version policy and initial version.
- [x] Create the Floorp app record in App Store Connect (`6796708699`).
- [ ] Set `FLOORP_APP_STORE_ID` after the public App Store listing is live.
- [ ] Replace remaining inherited main-app branding; review extension branding before any extension is restored.
- [x] Create the `Floorp Internal` TestFlight group and add the initial tester.
- [ ] Assign an owner and safe client-side value for each external service setting used by the release configuration.
- [x] Produce a signed `Floorp` archive, upload it, and install the processed build through Internal TestFlight.

Do not commit certificates, provisioning profiles, `.p8` API keys, `.p12` files, or passwords.

## Xcode Cloud rollout

The repository includes `firefox-ios/ci_scripts/ci_post_clone.sh`. Xcode Cloud discovers it next to `Client.xcodeproj`; it downloads the `.nvmrc` Node.js release with a pinned checksum and runs the root bootstrap in the clean clone. `.nvmrc` and `.xcode-version` are declarations for developers and GitHub Actions, not settings that Xcode Cloud applies automatically.

After the shared `Floorp` scheme archives locally with `FloorpRelease` and passes Organizer validation:

1. In Signing & Capabilities, explicitly confirm the main `app.floorp.Floorp` bundle ID once before initial setup because the project derives it from an `.xcconfig` file. Register extension IDs only when those targets return to the release.
2. Connect `Floorp-Projects/Floorp-iOS` to Xcode Cloud from Xcode's Report navigator. A GitHub organization owner must authorize the first connection.
3. Create a manually started development build workflow first. Select the repository's pinned Xcode version where Xcode Cloud offers it and verify the post-clone bootstrap.
4. After the development build is stable, create a manually started archive workflow for the Floorp release scheme with internal TestFlight distribution as the post-action.
5. Let Xcode Cloud manage signing; verify the Client-only app is signed by the Floorp team and inspect its production entitlements. Repeat this check for each extension if one is restored later.
6. Confirm `firefox-ios/TestFlight/WhatToTest.en-US.txt` appears in the TestFlight build and invite the internal group.
7. After several successful builds, add a `main` or release-tag start condition.
8. Download and retain each shipped archive and its dSYMs outside Xcode Cloud; Xcode Cloud build information and artifacts are available for only 30 days.

The public-beta workflow does not create groups or invent reviewer credentials. It selects one existing external group (or requires its explicit ID), reuses complete live Beta App Review details, records before/after state, and stops with a blocker if Apple agreements, review details, or group setup are incomplete.

## Later hardening

- Add a non-blocking manual or scheduled full `UnitTest` run with `.xcresult` retention while the remaining suites are repaired and promoted into `FloorpCI`.
- Restore a legacy maintenance workflow from Git history only after assigning a Floorp owner, removing Mozilla secrets and destinations, and pinning every external action.
- Split stable UI smoke tests into a nightly workflow after the simulator unit-test gate is reliable.
- Add a protected GitHub `testflight` environment only if distribution later moves from Xcode Cloud to GitHub Actions.
- Keep the pinned Nimbus script revision aligned with Application Services updates during upstream synchronization.
- Add CODEOWNERS for `.github/workflows/`, `scripts/ci/`, and `firefox-ios/ci_scripts/` after the Floorp GitHub maintainer team slug is known.

## Official references

### Release evidence, retention, and rollback

One release/version authority: Xcode Cloud owns monotonic distribution build
numbers; the marketing version remains reviewed in the repository
(`FloorpRelease.xcconfig`). Manual and cloud numbering must never be mixed; a
release candidate is identified only by the recorded source SHA-256, marketing
version, and build number triple.

`scripts/release/collect-floorp-release-evidence.sh` binds each candidate to
its source SHA, archived marketing version/build, signing identity,
entitlements, archive and IPA digests, and the dSYM UUID inventory.
`scripts/release/validate-floorp-release-evidence.py` re-verifies the document
against `scripts/release/floorp-release-evidence.schema.json` and rejects mixed
build IDs, forbidden entitlements, missing dSYMs, and digest mismatches.

`scripts/release/app-store-connect-api.py` is the only App Store Connect
surface. Its read allowlist covers the required GETs and its write allowlist is
exactly `POST /v1/ciBuildRuns`, `POST /v1/betaBuildLocalizations`,
`PATCH /v1/betaBuildLocalizations/{id}`, `PATCH /v1/betaAppReviewDetails/{id}`,
`POST /v1/betaAppReviewSubmissions`, and
`POST /v1/betaGroups/{id}/relationships/builds`. Every other write route,
including group creation, is denied before any request. Writes require the
intended object ID, a prior-state SHA-256, and `--authorize-mutation`;
`--dry-run` issues zero requests.

Retention: release evidence documents, `.xcresult` bundles, archives, IPAs,
and dSYM inventories are retained for at least 90 days; CI artifacts are
retained 7 days by the workflow. Rollback: because each candidate is bound to
its exact source SHA and App Store Connect build ID, a defective upload is
removed through the allowlisted relationship and localization routes without
re-uploading; the last-good archive and its evidence document remain the
rollback target. IPAs are uploaded exclusively with `xcrun altool` during
Todo 11 and never through the ASC REST client.

- [GitHub Actions repository settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
- [Triggering a workflow with `GITHUB_TOKEN`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)
- [GitHub-hosted macOS runner images](https://github.com/actions/runner-images)
- [Writing Xcode Cloud custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
- [Making dependencies available to Xcode Cloud](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud)
- [Configuring the first Xcode Cloud workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)
- [Including TestFlight notes](https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app)
- [Preparing an app to be the default browser](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser)
- [Requesting managed capabilities](https://developer.apple.com/help/account/capabilities/capability-requests/)
- [`com.apple.developer.browser.app-installation`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.browser.app-installation)
