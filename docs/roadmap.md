# Floorp for iOS Roadmap

This roadmap turns the validated `0.1.0 (1)` internal TestFlight baseline into
small, reviewable product milestones. Work should proceed in order unless a
release-blocking regression requires reprioritization.

## Current baseline

- The main Floorp app builds, signs, uploads, installs, and runs through
  Internal TestFlight.
- GitHub Actions builds the inherited browser and runs the `FloorpCI` test
  plan on pull requests and pushes to `main`.
- Floorp Notes supports local create, edit, search, delete, persistence,
  corruption recovery, and safe read-only projection of unsupported desktop
  rich-text content.
- Notes support local persistence plus optional production FxA/Sync in
  `FloorpRelease`; hosted summarization, Push, and all app extensions remain
  disabled.

## Milestone 0.2.0 — Floorp Notes Local v1

Goal: make local Notes safe and predictable enough for daily internal use
before adding cloud synchronization.

Tracking: [GitHub milestone](https://github.com/Floorp-Projects/floorp-ios/milestone/1)

- [#20 Prevent untouched Floorp Notes drafts from persisting](https://github.com/Floorp-Projects/floorp-ios/issues/20)
- [#21 Extract testable Floorp Notes editor save state and coordination](https://github.com/Floorp-Projects/floorp-ios/issues/21)
- [#22 Add recovery UI for Floorp Notes conflicts and save failures](https://github.com/Floorp-Projects/floorp-ios/issues/22)
- [#23 Add validated JSON export and import for Floorp Notes](https://github.com/Floorp-Projects/floorp-ios/issues/23)
- [#24 Add Floorp Notes unit and UI regression coverage](https://github.com/Floorp-Projects/floorp-ios/issues/24)
- [#25 Prepare and verify Floorp 0.2.0 in Internal TestFlight](https://github.com/Floorp-Projects/floorp-ios/issues/25)

### Work items

1. Prevent an untouched new-note draft from leaving an empty persisted note.
2. Extract the editor save state and Notes-specific drawer coordination behind
   testable boundaries without rewriting the whole drawer.
3. Replace generic save failures with actionable handling for edit conflicts,
   deleted notes, oversized archives, and persistence errors.
4. Offer conflict recovery actions such as reload, save as a copy, and keep
   editing without silently overwriting another window's changes.
5. Expose validated JSON export and import, including a way to retrieve a
   preserved corruption backup.
6. Add unit coverage for editor autosave, lifecycle saves, conversion,
   failure, conflict, and currently unused store operations.
7. Add a Floorp Notes UI smoke test covering create, edit, search, delete, and
   relaunch persistence.
8. Verify the flow in English and Japanese on iPhone and iPad, including basic
   Dynamic Type, VoiceOver, and multiple-window checks.

### Exit criteria

- Backgrounding, closing, relaunching, and concurrent windows do not cause
  silent data loss.
- TipTap and Lexical source content stays byte-for-byte unchanged until the
  user explicitly approves conversion to plain text.
- Core Notes behavior is covered by deterministic unit tests and one stable UI
  smoke path in CI or a dedicated scheduled workflow.
- `0.2.0` passes Internal TestFlight verification.

## Milestone 0.3.0 — Desktop interoperability and sync design

Goal: define a safe cross-device contract before implementing remote sync.

### Work items

1. Record an ADR covering service ownership, authentication, transport,
   retention, encryption assumptions, and operational responsibility.
2. Define a versioned Notes schema with stable identifiers, tombstones for
   deletions, deterministic conflict rules, and clock-skew handling.
3. Round-trip the desktop parallel-array payload through export and import
   without losing unknown rich-text nodes.
4. Prototype offline create, update, and delete conflicts before selecting a
   production backend.
5. Decide how the feature relates to Firefox Accounts; the inherited iOS Sync
   manager does not currently expose a Notes or preferences engine.

### Exit criteria

- Desktop and iOS fixtures round-trip without destructive conversion.
- Concurrent offline updates and deletions have documented, tested outcomes.
- No production network path is enabled until its owner and privacy contract
  are explicit.

## Milestone 0.4.0 — Floorp browser differentiation

Goal: make the product visibly useful beyond the inherited Firefox baseline.

Candidate work, ordered after Notes stability:

1. Save the current page title, URL, or selected text into Floorp Notes.
2. Implement custom web panels and a panel-management UI.
3. Finish Floorp-specific onboarding, settings, branding, and localization.
4. Restore app extensions one at a time, beginning with the Share extension,
   after capability, branding, signing, and test review.

## External beta and App Store gates

These are release gates rather than prerequisites for Notes development:

- Make signed delivery repeatable through Xcode Cloud or another explicitly
  owned CD path.
- Resolve missing third-party dSYMs needed for useful crash symbolication.
- Complete the retained endpoint, privacy manifest, App Privacy, and branding
  review.
- Confirm the default-browser entitlement and remaining export-compliance
  obligations.
- Validate external TestFlight metadata and Beta App Review before inviting
  external testers.

## Working agreement

- Keep Floorp-specific code concentrated under `firefox-ios/Floorp` and use
  narrow upstream hook points.
- Deliver each work item as a small pull request with tests and explicit
  acceptance criteria.
- Do not remove a passing test from `FloorpCI` to hide a regression.
- Re-run Internal TestFlight at the end of each product milestone.
