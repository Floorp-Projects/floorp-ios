# Workspace discovery validation

Validation date: 2026-10-26. This record covers source verification and the
published Rust dependency. It is not a signed iOS app release or authenticated
service acceptance report.

## Source and runtime

- iOS worktree: `Floorp-iOS-workspace-discovery`, branch `codex/workspace-discovery-ios`, based on `d8ecf7aad2a972448176eb24c004a8d5611d33f2`.
- Application Services implementation branch: `codex/workspace-discovery-rust`, based on `e1c77eb6e333ef667456504100c7b09763b8ad35`. The worktree now checks out the published mainline source on `codex/workspace-discovery-rust-release`.
- Local compiler: Xcode 27.1 / Rust 1.91.0; simulator runtime iOS 26.5, arm64.
- Developer framework source tree SHA-256: `ce12d792e53bebbae2f37e26baf301bc4d280db2784105606e64378348c52771`.
- Native library SHA-256: `c0412aa6dc1ea495f3e4f95b69f90a9cb61fc6185995a246940215365167f7ae`.
- The developer artifact has `releaseEligible=false`. The initial implementation checks below used the existing `.5` pin or that explicitly selected developer runtime.

## Published runtime

- Immutable release: [`floorp-ios-155.20260731050244.6`](https://github.com/Floorp-Projects/application-services/releases/tag/floorp-ios-155.20260731050244.6), release ID `423961346`. It retains the distribution workflow's required prerelease flag.
- Protected source: `a859c7883820fd9db4891800801161eada561551`, tree `d8d362a75986a3c0bf30df21e47b9a816dc57ee1`, merged through [Application Services PR 10](https://github.com/Floorp-Projects/application-services/pull/10). All five required PR checks passed before the merge, including the native candidate and Floorp Sync contract tests.
- The lightweight release tag directly targets that protected mainline commit. Its exact Mozilla upstream merge-base remains `b21da19867ff58b1cfd8c83fceba8dac1f243c44`.
- [Release run 40283634342](https://github.com/Floorp-Projects/application-services/actions/runs/40283634342) rebuilt the source with pinned Xcode 26.3, Rust 1.91.0 and Python 3.12.10. It verified device arm64 and simulator arm64/x86_64 slices, generated Swift/headers and the read-only Workspace API, then attested all five assets before protected publication.
- Downloaded bytes for both frameworks, the Swift archive, manifest and checksum inventory match every GitHub SHA-256 and size. `SHA256SUMS` verifies all four listed payloads. Each asset additionally passed `gh attestation verify` constrained to the exact `.6` workflow certificate identity, exact source digest and GitHub-hosted runners.
- The first publish attempt could not resolve its just-created draft. Retrying only the publish job completed successfully using the same built and attested bytes. The empty duplicate draft created by that retry was removed by its exact ID; the immutable published release and earlier `.5` releases were unchanged.
- All 27 main and 9 Focus generated Swift files match the published archive after ignoring trailing whitespace/final newline. Existing generated formatting is retained. SwiftPM's installed frameworks were also compared file-for-file with the published ZIPs: all 66 Mozilla and 28 Focus files match.
- A new standalone binding smoke compiled the official simulator library with the exact published generated bindings and ran successfully on iOS 26.5, arm64. It exercised construction, both JSON APIs, binding/account switch, registration, real `SyncManager.disconnectChecked`, invalidation and durable reopen. It did not authenticate or call the Sync network API.

## Published dependency integration checks

- Full remote pin verification, pin synchronization and capable/legacy/local runtime-selection harnesses passed with the real `.6` metadata.
- The ordinary `Floorp` scheme, `Fennec` configuration, built successfully for the selected arm64 iOS 26.5 simulator using a fresh DerivedData directory. The local Rust override was unset, optimization settings were not overridden, and signing was disabled. The host compiler is Xcode 27.1; the published native dependency was built with pinned Xcode 26.3.
- The same ordinary scheme/configuration also built successfully for a generic arm64 iOS device using a separate fresh DerivedData directory, again without a Rust or optimization override and with signing disabled. Both logs include the real Workspace compilation flag and process the verified SwiftPM framework. This is a device-target build, not signed physical-device acceptance.
- The 11 network-free Nimbus cache/bootstrap tests and 110 Notes evidence-validator tests passed. These cover build/evidence contracts; they are not authenticated service QA.
- All 68 staging-wrapper tests passed against the final `.6` pin, with zero skips. This includes synthetic candidate-bound positive cases, source/artifact mismatch rejection and rejection of unchanged historical `.5` evidence. The synthetic cases do not establish new live QA evidence.
- Xcode regressions using the official pinned runtime passed: 144 tests, zero failures (105 Client, 37 datastore and 2 generated Sync Manager wrapper tests). The Client tests cover 18 copy, 10 discovery, 47 Sync Manager, 7 real TabManager, 6 Notes adapter and 17 Notes engine-selection cases. The existing `UnitTest` plan exclusions remain in effect. The new historical-evidence rejection ran and passed. This test run used `Fennec_Testing` with `SWIFT_OPTIMIZATION_LEVEL=-Onone`; the local Rust override was unset.

## Initial implementation checks

- Rust: Workspace 21, sync15 90, Notes/prefs 25 and Sync Manager 6 unit tests passed. Desktop fixture generation covers 33 cases from the fixed Desktop implementation.
- Distribution automation: the final 46 tests passed, including the lightweight copy eligibility API verifier. Hosted formatting and Clippy checks also passed.
- Swift copy/persistence: 18 service tests and 17 real datastore tests passed, including interrupted receipt reads, failed durable/ordinary saves, lost inventory, closed-tab crash recovery and active journal cache lifecycle.
- Swift discovery/provider: 10 tests plus one legacy-runtime compatibility test passed.
- Default `.5` runtime: unsigned arm64 simulator app build passed with `Fennec_Testing` and `SWIFT_OPTIMIZATION_LEVEL=-Onone`.
- New real Workspace runtime: final unsigned arm64 simulator app build passed using the generated XCFramework and matching Swift binding, including the final offline/timestamp preview footer.
- Real generated Swift/native binding smoke: simulator execution passed constructor, both JSON APIs, account binding/switch, registration, Sync Manager reset, invalidation and durable reopen. No network or authentication was used.
- UI fixture: actual list/preview controller sources rendered in English and Japanese on iPhone 17 Pro / iOS 26.5, including long text, duplicate URLs, pins, unknown icons and offline timestamp. The coordinator and tab destination were fixtures; this does not prove service or full-browser acceptance.
- Xcode simulator tests with the actual Workspace runtime: 123 passed (86 Client tests and 37 TabDataStore tests), zero failures. This includes all 51 RustSyncManager cases, the 18 copy service cases, 10 discovery cases and 7 actual TabManager cases.
- Xcode project and string catalog parsing passed.

## Persistence performance

A release-mode Foundation harness used the production copy service and actual
`DefaultTabDataStore`, with atomic JSON files and a destination fixture. A final
32-item batch run completed 100 tabs in 0.515 seconds (4 durable commits,
10.27 MiB peak RSS) and 1,000 tabs in 4.774 seconds (32 durable commits,
16.39 MiB peak RSS). It verified order, titles, duplicate URLs, distinct local
IDs, all receipts and the selected first tab. A prior per-tab run measured
52.483 seconds for 1,000 tabs; host load was not controlled across runs.

These measurements exclude UIKit, TabManager snapshot generation, WebKit,
network and physical-device storage. They establish the persistence behavior
and do not complete device performance acceptance.

The focused reproduction commands and receive/copy boundaries are documented in
`workspace-discovery-architecture.md`; native dependency selection is documented
in `workspace-discovery-runtime.md`.

## Remaining iOS release acceptance

- Obtain fresh `.6` candidate-bound Notes QA evidence before using strict enabled QA/release modes. The ordinary `release-default` Notes policy remains independent; publishing the new binary does not constitute live Notes QA. Historical `.5` evidence is preserved.
- Build with the pinned release toolchain and signing configuration; record the final iOS/Rust source and TestFlight build identities.
- Authenticate a dedicated account and verify Desktop to iPhone and iPad reception, paging, reset, remote update/deletion, logout, relaunch and preservation of independent copies.
- Check actual browser copy/load behavior, iPad layout, VoiceOver and physical-device performance. Foundation persistence measurements and fixture renders do not replace these checks.
