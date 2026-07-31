# Floorp for iOS CI/CD

This document defines the delivery foundation for Floorp for iOS. The repository now has a reproducible pull-request gate and a dedicated unsigned release-archive path. Signed delivery still requires the Floorp Apple account, capabilities, product scope, and service ownership to be finalized.

## Architecture

| Concern | System | Current state |
| --- | --- | --- |
| Pull-request build and unit tests | GitHub Actions | Implemented in `.github/workflows/ci.yml` |
| Upstream Firefox synchronization | GitHub Actions | Weekly PR workflow with a workflow allowlist and explicit CI dispatch |
| Signed archive and internal TestFlight | Xcode Cloud | Release scaffold implemented; workflow and signing not yet configured or validated |
| App Store release | App Store Connect | Manual approval initially |
| Mozilla/Focus maintenance automation | Git history | Removed pending a Floorp-owned replacement |

GitHub Actions never receives an Apple certificate or private key in this first stage. Xcode Cloud is the preferred first CD system because it supports cloud-managed signing and direct TestFlight distribution.

## CI contract

The `Floorp iOS CI` workflow runs for pull requests and pushes to `main` and performs these steps:

1. Validate active workflow files with a checksum-pinned Actionlint binary.
2. Select the Xcode version in `.xcode-version` and Node.js version in `.nvmrc`.
3. Install Node dependencies with `npm ci`, generate web assets, and reject high-severity npm advisories.
4. Download the pinned Nimbus helper and SwiftLint binary, verifying downloads with SHA-256 checksums.
5. For normal pull requests, run SwiftLint in strict mode for added or modified Swift files outside the inherited Focus tree. Existing inherited lint debt does not make the initial gate permanently red. Pushes and the explicitly dispatched upstream-sync build skip this step.
6. Resolve only the Swift package versions in `Package.resolved`.
7. Build `Fennec` with `Fennec_Testing` and the `FloorpCI` plan for an iOS Simulator with code signing disabled.
8. Run the already-built `FloorpCI` plan and retain diagnostics for seven days only when the job fails.

`FloorpCI.xctestplan` is an explicit baseline of 15 test targets: 14 currently reliable suites plus 16 selected Floorp Notes cases from `ClientTests` (812 tests relative to the initial 796-test local baseline). It pins the test language and region to `en-US` and `US` so localized system messages cannot make the result depend on the runner locale. The inherited `UnitTest` plan and the rest of `ClientTests` are intentionally not required checks yet because unqualified Client tests still hit Floorp telemetry/dependency-container failures. Selecting individual cases still compiles the whole `ClientTests` target, so additions must pass a clean `build-for-testing` before promotion. Validate the remaining suites independently and promote each passing suite into `FloorpCI`; never hide a regression by removing a previously passing suite.

SwiftPM checkouts and Derived Data use job-local directories. This avoids shared-cache corruption and keeps untrusted pull-request code out of persistent caches.

Dependabot checks GitHub Actions and npm dependencies monthly. External actions remain pinned to immutable commit SHAs.

The upstream workflow restores the trusted Floorp workflow and rebrand files after merging, removes every non-allowlisted workflow, and aborts on conflicts outside `.github/workflows`. It explicitly dispatches `ci.yml` for `automation/upstream-sync` after creating or updating the PR, instead of relying on the approval state and trigger behavior of events produced by `GITHUB_TOKEN`.

## GitHub repository settings

After the workflow passes once, configure these settings on GitHub:

1. In **Settings → Actions → General**, set the default `GITHUB_TOKEN` permission to read-only.
2. Enable **Allow GitHub Actions to create and approve pull requests**; the upstream workflow needs PR creation but never approves its own PR.
3. Require approval for workflows from all external contributors.
4. Allow only required actions and require actions to be pinned to a full commit SHA when organization policy permits it.
5. Create a ruleset for `main` that:
   - requires a pull request and at least one approval;
   - requires conversation resolution;
   - requires `Floorp iOS CI / Validate workflows`;
   - requires `Floorp iOS CI / Build and unit test`;
   - blocks force pushes and deletion;
   - permits bypass only for a small release-maintainer group.

At the time this document was introduced, `main` was not protected. Repository settings are external state and are not stored in this repository.

## Release readiness

Do not create an App Store archive from `Fennec`; it remains a development configuration. Use the shared `Floorp` scheme and its `FloorpRelease` Archive action. The repository-side release scaffold is implemented, but the external and product decisions below remain before TestFlight distribution.

### Release build configuration

`Fennec.xcconfig` inherits the debug configuration and is intentionally unsuitable for distribution. `FloorpRelease.xcconfig` instead uses release optimization and dSYMs, selects the release Nimbus channel, and disables assertions, testability, coverage instrumentation, and the Settings bundle. The shared `Floorp` scheme uses this configuration for Profile, Analyze, and Archive while retaining the existing development configuration for local Run and the `FloorpCI` plan for Test.

The release configuration uses automatic signing and leaves provisioning-profile selectors empty. An unsigned generic-device build is the repository-level validation baseline; a signed archive and Organizer validation remain required.

### Signing team

Mozilla team identifiers remain in upstream-only configurations. `FloorpRelease` instead resolves `DEVELOPMENT_TEAM` from `FLOORP_DEVELOPMENT_TEAM`, which is intentionally blank until the owning Floorp team is confirmed. Supply the 10-character Team ID through the Floorp configuration or Xcode Cloud, then validate that the app and every retained extension are signed by that team. The Team ID is not a secret and may be committed after the correct account is confirmed.

The `Floorp` scheme's Run and Test actions still use the inherited Fennec development configurations. Treat them as Simulator-only until a Floorp-owned debug signing configuration replaces the inherited Mozilla team.

### Bundle IDs and extensions

The main release bundle ID is `app.floorp.Floorp`. The current scaffold can archive all six inherited extensions with explicit Floorp IDs: `WidgetKit`, `NotificationService`, `CredentialProvider`, `Sticker`, `ActionExtension`, and `ShareTo` below the main bundle ID. This is build-system capability, not a decision that all six must ship.

Approve the version 1 extension scope, remove excluded products from the release archive, then register an explicit App ID for the app and every retained extension. Reducing the first release to required extensions lowers the number of identifiers, capabilities, and signing profiles that must be maintained.

### App Group and Keychain groups

The Floorp release entitlements use `group.app.floorp.Floorp` and the matching Floorp keychain group. Sticker has no shared-container entitlement. Register the App Group in Apple Developer and grant App Group and keychain access only to retained targets that actually share those data.

### Push notifications

The Floorp release entitlement intentionally omits APNs, and the current beta plan therefore has no Push support. Remove Notification Service from the first release unless Push becomes an approved version 1 feature. Adding it later requires production entitlements, the Floorp App ID capability, a Floorp-owned APNs key, and a Floorp-owned or explicitly authorized backend.

### Managed browser entitlements

The app declares `com.apple.developer.web-browser`, which lets an approved app appear as a default browser. The Apple Account Holder must request and receive this managed capability.

The Floorp release entitlement omits `com.apple.developer.browser.app-installation`, which is for installing alternative-distribution apps from a website. Add it only if Floorp deliberately adopts that distribution path and Apple approves the request.

### Versioning

The checked-in release baseline is `0.1.0 (1)`. The main app and all extension Info.plists consume the shared marketing version and build number. Approve the independent Floorp marketing-version policy; Xcode Cloud can assign the monotonically increasing distribution build number for the initial TestFlight workflow.

### Floorp-owned services and App Store ID

Decide which FxA/Sync, Remote Settings, sponsored-content/Merino, summarizer, Push, Nimbus, Sentry, LiteLLM, and related endpoints Floorp owns or is authorized to use before distributing a release archive. Where ownership is unresolved, disable the feature rather than silently using an inherited Mozilla production default. Xcode Cloud secret variables prevent values from appearing in logs, but any value embedded in the app bundle remains extractable and must not be a privileged server secret.

Firefox's App Store ID has been removed. `FLOORP_APP_STORE_ID` is optional; while it is unset or invalid, Floorp hides the rating setting and does not open a review URL. Set it to Floorp's numeric Apple ID after the App Store Connect record exists.

### Release branding

The primary classic and Liquid Glass icon sources already render the Floorp logo, although `FloorpRelease` still selects the inherited `AppIcon_Developer` name and the Liquid Glass layer filenames still say `nightly`. Those internal names are cleanup work, not a TestFlight blocker. Before distribution, disable the inherited Firefox alternate icons and review the remaining main-app and extension names, artwork, localized strings, and product metadata.

## Apple account checklist

Complete these steps before enabling Xcode Cloud distribution:

- [ ] Decide whether the Apple Developer account is permanently owned by a Floorp organization or an individual; avoid a later transfer if possible.
- [ ] Confirm the Apple Developer Team that owns Floorp and record its Team ID.
- [ ] Confirm an App Store Connect Account Holder, Admin, App Manager, or Developer with Create Apps permission can perform setup.
- [ ] Confirm a GitHub organization owner can authorize the initial Xcode Cloud connection.
- [ ] Accept all current Apple Developer and App Store Connect agreements.
- [ ] Create or confirm the `app.floorp.Floorp` App ID.
- [ ] Decide whether development builds use a separate bundle ID such as `app.floorp.Floorp.Developer`.
- [ ] Decide which of the six bundled extensions ship in version 1, remove excluded products from the release archive, and register retained App IDs.
- [ ] Register `group.app.floorp.Floorp` and assign it to every retained target that shares data.
- [ ] Decide whether Push, AutoFill Credential Provider, App Attest, and Multipath are in version 1; enable only the required capabilities.
- [ ] Request the default-browser managed entitlement.
- [x] Omit the browser app-installation entitlement from the initial release configuration.
- [ ] Choose the Floorp marketing-version policy and initial version.
- [ ] Create the Floorp app record in App Store Connect.
- [ ] Set `FLOORP_APP_STORE_ID` after App Store Connect assigns Floorp's numeric Apple ID.
- [ ] Replace inherited Liquid Glass and extension branding with approved Floorp release artwork and copy.
- [ ] Create an internal TestFlight group.
- [ ] Assign an owner and safe client-side value for each external service setting used by the release configuration.
- [ ] Produce a signed `Floorp` archive and pass Organizer validation.

Do not commit certificates, provisioning profiles, `.p8` API keys, `.p12` files, or passwords.

## Xcode Cloud rollout

The repository includes `firefox-ios/ci_scripts/ci_post_clone.sh`. Xcode Cloud discovers it next to `Client.xcodeproj`; it downloads the `.nvmrc` Node.js release with a pinned checksum and runs the root bootstrap in the clean clone. `.nvmrc` and `.xcode-version` are declarations for developers and GitHub Actions, not settings that Xcode Cloud applies automatically.

After the shared `Floorp` scheme archives locally with `FloorpRelease` and passes Organizer validation:

1. In Signing & Capabilities, explicitly set every app and extension bundle ID once before initial setup because the project derives IDs from `.xcconfig` files.
2. Connect `Floorp-Projects/Floorp-iOS` to Xcode Cloud from Xcode's Report navigator. A GitHub organization owner must authorize the first connection.
3. Create a manually started development build workflow first. Select the repository's pinned Xcode version where Xcode Cloud offers it and verify the post-clone bootstrap.
4. After the development build is stable, create a manually started archive workflow for the Floorp release scheme with internal TestFlight distribution as the post-action.
5. Let Xcode Cloud manage signing; verify every embedded extension is signed by the Floorp team and inspect the production entitlements.
6. Confirm `firefox-ios/TestFlight/WhatToTest.en-US.txt` appears in the TestFlight build and invite the internal group.
7. After several successful builds, add a `main` or release-tag start condition.
8. Download and retain each shipped archive and its dSYMs outside Xcode Cloud; Xcode Cloud build information and artifacts are available for only 30 days.

External TestFlight groups, Beta App Review submission, and App Store submission remain manual until internal distribution is stable.

## Later hardening

- Add a non-blocking manual or scheduled full `UnitTest` run with `.xcresult` retention while the remaining suites are repaired and promoted into `FloorpCI`.
- Restore a legacy maintenance workflow from Git history only after assigning a Floorp owner, removing Mozilla secrets and destinations, and pinning every external action.
- Split stable UI smoke tests into a nightly workflow after the simulator unit-test gate is reliable.
- Add a protected GitHub `testflight` environment only if distribution later moves from Xcode Cloud to GitHub Actions.
- Keep the pinned Nimbus script revision aligned with Application Services updates during upstream synchronization.
- Add CODEOWNERS for `.github/workflows/`, `scripts/ci/`, and `firefox-ios/ci_scripts/` after the Floorp GitHub maintainer team slug is known.

## Official references

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
