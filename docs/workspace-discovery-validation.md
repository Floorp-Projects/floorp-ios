# Workspace discovery validation

Validation date: 2026-10-26. This record describes local source verification;
it is not a signed release or authenticated service acceptance report.

## Source and runtime

- iOS worktree: `Floorp-iOS-workspace-discovery`, branch `codex/workspace-discovery-ios`, based on `d8ecf7aad2a972448176eb24c004a8d5611d33f2`.
- Application Services worktree: `application-services-workspace-discovery`, branch `codex/workspace-discovery-rust`, based on `e1c77eb6e333ef667456504100c7b09763b8ad35`.
- Local compiler: Xcode 27.1 / Rust 1.91.0; simulator runtime iOS 26.5, arm64.
- Developer framework source tree SHA-256: `ce12d792e53bebbae2f37e26baf301bc4d280db2784105606e64378348c52771`.
- Native library SHA-256: `c0412aa6dc1ea495f3e4f95b69f90a9cb61fc6185995a246940215365167f7ae`.
- The developer artifact has `releaseEligible=false`. The immutable `.5` production pin remains unchanged.

## Completed checks

- Rust: Workspace 21, sync15 90, Notes/prefs 25 and Sync Manager 6 unit tests passed. Desktop fixture generation covers 33 cases from the fixed Desktop implementation.
- Distribution automation: full 45 tests passed; the latest binding-verifier subset passed 32 after adding the lightweight copy eligibility API.
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

## Remaining release acceptance

- Publish a genuine immutable Application Services release, verify all required slices/assets and import its actual pin and matching generated bindings using `workspace-discovery-runtime.md`. The existing `.5` pin and historical evidence remain unchanged while this release is being prepared.
- Rebind strict Notes candidate identities to the real release and obtain fresh candidate-bound QA evidence before using strict enabled QA/release modes. The ordinary `release-default` Notes policy remains independent; publishing the new binary does not constitute live Notes QA.
- Build with the pinned release toolchain and signing configuration; record the final iOS/Rust source and TestFlight build identities.
- Authenticate a dedicated account and verify Desktop to iPhone and iPad reception, paging, reset, remote update/deletion, logout, relaunch and preservation of independent copies.
- Check actual browser copy/load behavior, iPad layout, VoiceOver and physical-device performance. Foundation persistence measurements and fixture renders do not replace these checks.
