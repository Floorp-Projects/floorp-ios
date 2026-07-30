# Floorp for iOS CI/CD

This document defines the initial delivery foundation for Floorp for iOS. The immediate goal is a reproducible, unsigned pull-request gate. TestFlight delivery follows after the Floorp release configuration and Apple capabilities are valid.

## Architecture

| Concern | System | Current state |
| --- | --- | --- |
| Pull-request build and unit tests | GitHub Actions | Implemented in `.github/workflows/ci.yml` |
| Upstream Firefox synchronization | GitHub Actions | Weekly PR workflow with a workflow allowlist and explicit CI dispatch |
| Signed archive and internal TestFlight | Xcode Cloud | Recommended; requires the release configuration below |
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

`FloorpCI.xctestplan` is an explicit baseline of 14 currently reliable suites (796 tests in the initial local run). It pins the test language and region to `en-US` and `US` so localized system messages cannot make the result depend on the runner locale. The inherited `UnitTest` plan is intentionally not a required check yet: `ClientTests` hits a Floorp telemetry/dependency-container crash, and eight remaining suites have not yet been qualified as a stable Floorp baseline. Validate those suites independently and promote each passing suite into `FloorpCI`; never hide a regression by removing a previously passing suite.

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

## Release blockers

Do not create an App Store archive from the current `Fennec` configuration. The following items must be resolved first:

### Release build configuration

`Fennec.xcconfig` inherits the debug configuration, uses the developer Nimbus channel, keeps assertions enabled, and instruments the binary for profiling. The obsolete Archive pre-action that referenced a deleted script has been removed, but `Fennec` is still not a production archive configuration.

Add a dedicated Floorp release build configuration and shared scheme that use release optimization and the release Nimbus channel. Do not copy the inherited Mozilla/Bitrise signing values from `Release.xcconfig` unchanged: the app and each retained extension must use automatic signing, the Floorp Team ID, and no manually selected provisioning profile.

### Signing team

The project still contains Mozilla development-team identifiers. Set the Floorp Apple Developer Team ID in the Floorp configurations for the app and every retained extension. Avoid a repository-wide replacement that makes upstream-only schemes harder to merge. The Team ID is not a secret and may be committed after the correct account is confirmed.

### Bundle IDs and extensions

The main bundle ID is `app.floorp.Floorp`. The app currently embeds six extensions: Widget, Notification Service, Credential Provider, Sticker, Action, and Share. Keep only extensions that are part of the first release, then register an explicit App ID for the app and each retained extension.

Reducing the first release to required extensions lowers the number of identifiers, capabilities, and signing profiles that must be maintained.

### App Group and Keychain groups

The main app and Credential Provider use `group.app.floorp.Floorp`, while several Fennec extension entitlements still use `group.org.mozilla.ios.Fennec`. Before device or archive testing, grant the Floorp App Group and compatible keychain groups only to retained targets that actually share those data. Do not broaden entitlements for extensions such as Sticker that do not need them.

### Push notifications

The current Fennec entitlement declares the development APNs environment. If version 1 uses Push, create production release entitlements, enable Push on the Floorp App ID, retain the Notification Service extension, and configure a Floorp-owned APNs key and backend. If Push is out of scope, remove the capability and Notification Service extension from the first release.

### Managed browser entitlements

The app declares `com.apple.developer.web-browser`, which lets an approved app appear as a default browser. The Apple Account Holder must request and receive this managed capability.

The app also declares `com.apple.developer.browser.app-installation`. This is specifically for installing alternative-distribution apps from a website. Remove it unless Floorp deliberately needs that feature and Apple approves the request.

### Versioning

Define an independent Floorp marketing-version policy. CI/CD must inject one monotonically increasing build number into the main app and every extension. Xcode Cloud's build number is suitable for the initial TestFlight workflow.

### Floorp-owned services and App Store ID

Decide which Adjust, Nimbus, Pocket, Sentry, LiteLLM, and related build settings Floorp owns before creating a release archive. Xcode Cloud secret variables prevent values from appearing in logs, but any value embedded in the app bundle remains extractable and must not be a privileged server secret.

`BrowserKit/Sources/Shared/AppInfo.swift` still contains Firefox's App Store ID. Replace it with the Floorp App Store Connect Apple ID after the Floorp app record exists so rating prompts cannot open Firefox's listing.

## Apple account checklist

Complete these steps before enabling Xcode Cloud distribution:

- [ ] Decide whether the Apple Developer account is permanently owned by a Floorp organization or an individual; avoid a later transfer if possible.
- [ ] Confirm the Apple Developer Team that owns Floorp and record its Team ID.
- [ ] Confirm an App Store Connect Account Holder, Admin, App Manager, or Developer with Create Apps permission can perform setup.
- [ ] Confirm a GitHub organization owner can authorize the initial Xcode Cloud connection.
- [ ] Accept all current Apple Developer and App Store Connect agreements.
- [ ] Create or confirm the `app.floorp.Floorp` App ID.
- [ ] Decide whether development builds use a separate bundle ID such as `app.floorp.Floorp.Developer`.
- [ ] Decide which of the six bundled extensions ship in version 1 and register their App IDs.
- [ ] Register `group.app.floorp.Floorp` and assign it to every retained target that shares data.
- [ ] Decide whether Push, AutoFill Credential Provider, App Attest, and Multipath are in version 1; enable only the required capabilities.
- [ ] Request the default-browser managed entitlement.
- [ ] Decide whether the browser app-installation entitlement is intentionally required.
- [ ] Choose the Floorp marketing-version policy and initial version.
- [ ] Create the Floorp app record in App Store Connect.
- [ ] Replace the Firefox App Store ID after App Store Connect assigns Floorp's Apple ID.
- [ ] Create an internal TestFlight group.
- [ ] Assign an owner and safe client-side value for each external service setting used by the release configuration.

Do not commit certificates, provisioning profiles, `.p8` API keys, `.p12` files, or passwords.

## Xcode Cloud rollout

The repository includes `firefox-ios/ci_scripts/ci_post_clone.sh`. Xcode Cloud discovers it next to `Client.xcodeproj`; it downloads the `.nvmrc` Node.js release with a pinned checksum and runs the root bootstrap in the clean clone. `.nvmrc` and `.xcode-version` are declarations for developers and GitHub Actions, not settings that Xcode Cloud applies automatically.

After the Floorp release scheme archives locally and passes Organizer validation:

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
