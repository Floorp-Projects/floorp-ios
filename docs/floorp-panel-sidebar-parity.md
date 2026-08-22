# Floorp Panel Sidebar parity and shipping contract

This document defines the Floorp iOS panel-sidebar feature contract. It keeps
two questions separate:

1. Is the behavior implemented and covered by deterministic source-level
   tests?
2. Was that behavior exercised on the exact commit and build that will ship?

The first question is recorded here. The second is recorded in
[the release acceptance checklist](floorp-panel-sidebar-acceptance.md). A green
unit-test run is not runtime acceptance, and a manual smoke test on a different
commit is not release evidence.

## Reference and status language

- Desktop reference: Floorp `main` at
  [`410c211c202012631159d1bce1f3ab208305d2b7`](https://github.com/Floorp-Projects/Floorp/commit/410c211c202012631159d1bce1f3ab208305d2b7).
- The candidate source SHA, build number, CI runs, devices, OS versions, and
  screenshots are intentionally not asserted here. They must be recorded in
  the acceptance checklist after the release candidate is immutable.
- Desktop parity means equivalent user-visible behavior and data ownership. It
  does not mean copying Gecko/XUL internals or desktop pixel dimensions.

### iOS media-playback divergence

Floorp desktop can mute a Web panel's audio while playback continues. Public
WebKit API on iOS instead provides `setAllMediaPlaybackSuspended`, which pauses
and resumes all audio and video playback together. The iOS action is therefore
intentionally exposed as **Pause Panel Media** / **Resume Panel Media**, not as
Mute / Unmute. This pause state belongs only to the loaded panel session and is
not a persisted desktop-compatible preference.

Status terms:

- **Implemented**: a user-reachable implementation and focused automated tests
  are present in the integration line.
- **Candidate — final CI pending**: implementation exists in the release
  candidate work, but must not be described as shipped until its final CI and
  runtime evidence are recorded.
- **Architecture implemented — live evidence pending**: the production
  boundary is present and unit-tested, but a real WebKit fixture is still
  required to prove the end-to-end contract.
- **Intentional iOS divergence**: an explicit platform/product boundary. It is
  not a missing implementation for this milestone.

## Functional implementation status

### P0: dependable daily use

| ID | Contract | Status | Source and deterministic evidence | Remaining release evidence |
| --- | --- | --- | --- | --- |
| P0-1 | Maintain one ordered, profile-persistent registry with add, edit, remove, restore, and reorder UI. | **Implemented** | [`FloorpPanelManager.swift`](../firefox-ios/Floorp/FloorpPanelManager.swift) owns validated CRUD, ordering, optimistic revisions, migration, and future-schema read-only behavior. [`FloorpPanelRegistryViewController.swift`](../firefox-ios/Floorp/FloorpPanelRegistryViewController.swift) exposes add/edit/reorder/remove/restore through touch, context menus, and accessibility actions. `FloorpPanelManagerRegistryTests`, `FloorpWebPanelValidatorTests`, and `FloorpPanelRegistryUIHelperTests` are in [`FloorpNotesTests.swift`](../firefox-ios/firefox-ios-tests/Tests/ClientTests/FloorpNotesTests.swift). | On the final build, add, edit, reorder, relaunch, remove, and restore a panel without damaging built-ins. |
| P0-2 | Keep active selection, loaded Web views, and private/normal state scoped to one browser window. Ordinary hide/show and panel switches retain the session. | **Implemented** | [`BrowserViewController+Floorp.swift`](../firefox-ios/Floorp/BrowserViewController+Floorp.swift) associates a presentation state with each browser controller. [`FloorpOverlayDrawerViewController.swift`](../firefox-ios/Floorp/FloorpOverlayDrawerViewController.swift) owns window-local selection and attachment. [`FloorpWebPanelSessionStore.swift`](../firefox-ios/Floorp/FloorpWebPanelSessionStore.swift) keys sessions by window, panel, and privacy mode. Coverage includes `testSessionKeysSeparateWindowsAndPrivacyModes`, `testRegularAndPrivateSessionsSurviveDrawerHideAndRemainSeparated`, and `testWindowAssociationTeardownInvalidatesAndRemovesRuntimeState` in [`FloorpWebPanelRuntimeTests.swift`](../firefox-ios/firefox-ios-tests/Tests/ClientTests/FloorpWebPanelRuntimeTests.swift). | Exercise two windows and both privacy modes on the final build, including hide/show and panel switching without an unintended reload. |
| P0-3 | Provide Back, Forward, Reload/Stop, Home, Open in Main, Close, and Find for a Web panel. | **Implemented** | The toolbar, command enablement, keyboard commands, and main-browser handoff are in [`FloorpOverlayDrawerViewController.swift`](../firefox-ios/Floorp/FloorpOverlayDrawerViewController.swift). Find uses [`FloorpWebPanelFindController.swift`](../firefox-ios/Floorp/FloorpWebPanelFindController.swift) and native `WKFindInteraction` where available. Coverage includes `testWebPanelToolbarTracksStateAndDispatchesCommands`, `testFindToolbarIsDiscoverableAndClearsWhenSwitchingPanels`, `testOpenInMainBrowserDismissesDrawerAndPreservesSessionForReopen`, and `FloorpWebPanelFindControllerTests`. | Run all commands against a multi-page local fixture; record Cmd-F, next/previous, Escape, and VoiceOver behavior. |
| P0-4 | Use the normal/private Floorp WebKit profile boundary and content-blocking pipeline without writing panel navigation to the main browsing-history store. | **Architecture implemented — live evidence pending** | [`FloorpWebPanelWebViewSession.swift`](../firefox-ios/Floorp/FloorpWebPanelWebViewSession.swift) creates an isolated `TabWebView` with the shared normal configuration or a leased private session. It does not create a main-browser `Tab` or call the history manager. [`FloorpWebPanelContentRules.swift`](../firefox-ios/Floorp/FloorpWebPanelContentRules.swift) installs `FirefoxTabContentBlocker` rules before first load. Block Images reads and observes the live profile preference, applies the same document-start/all-frame CSS contract as a normal tab without replacing unrelated scripts, refreshes loaded regular/private sessions once, and re-reads the preference after unload. Coverage includes `testConfigurationUsesSharedDefaultAndPrivateDataStores`, `testInitialLoadWaitsForContentRules`, `testNoImageModeScriptMatchesNormalTabContractAndPreservesForeignScripts`, `testDefaultFactoryAdapterReadsLiveProfileImageBlockingPreference`, `testImageBlockingPreferenceChangeRefreshesRegularAndPrivatePanelsExactlyOnce`, and `testRecreatedSessionReadsLatestImageBlockingPreferenceAfterUnload` in [`FloorpWebPanelWebViewSessionTests.swift`](../firefox-ios/firefox-ios-tests/Tests/ClientTests/FloorpWebPanelWebViewSessionTests.swift). | A live local HTTPS fixture must prove shared normal cookies/login, private isolation, equivalent blocking and Block Images behavior, and no main-history additions. This row remains open until that artifact is recorded. |
| P0-5 | Use an overlay on compact iPhone layouts and a pinned, resizable sidebar on sufficiently wide regular iPad layouts without address-bar overlap. | **Implemented** | [`FloorpAdaptivePanelPresentation.swift`](../firefox-ios/Floorp/FloorpAdaptivePanelPresentation.swift) resolves the presentation mode. The same drawer controller migrates between modes, preserving content identity. `FloorpBrowserChromeLayoutTests` and `FloorpOverlayDrawerPresentationTests` are in [`FloorpNotesTests.swift`](../firefox-ios/firefox-ios-tests/Tests/ClientTests/FloorpNotesTests.swift); `testAdaptivePresentationMigrationPreservesLoadedWebPanelSessionAndContent` is in [`FloorpWebPanelRuntimeTests.swift`](../firefox-ios/firefox-ios-tests/Tests/ClientTests/FloorpWebPanelRuntimeTests.swift). [`FloorpAdaptiveSidebarUITests.swift`](../firefox-ios/firefox-ios-tests/Tests/XCUITests/FloorpAdaptiveSidebarUITests.swift) covers iPhone top/bottom address bars, iPad orientation migration, resizing, and RTL. | Attach the final iPhone and iPad UI-test run URLs and their screenshots. Also record the supported Split View size used for acceptance. |
| P0-6 | Retain normal sessions, support explicit unload and optional auto-unload, evict only inactive sessions under memory pressure, and restore only a safe last URL. | **Implemented** | Explicit-unload markers and UI live in [`FloorpOverlayDrawerViewController.swift`](../firefox-ios/Floorp/FloorpOverlayDrawerViewController.swift). Auto-unload configuration and persistence live in [`FloorpPanelManager.swift`](../firefox-ios/Floorp/FloorpPanelManager.swift). LRU, memory-pressure eviction, and privacy-scoped restoration snapshots live in [`FloorpWebPanelSessionStore.swift`](../firefox-ios/Floorp/FloorpWebPanelSessionStore.swift). Coverage includes `testActiveExplicitUnloadDetachesRuntimeUntilSelectedAgain`, `testAutoUnloadRestoresLastSafeURLAfterPanelSwitchAndDrawerHide`, `testMemoryPressureEvictsOnlyInactiveSessionsAndRestoresSafeLatestURLs`, `testRegularLRUAllowsVisibleOverflowUntilASessionIsHidden`, and `testMemoryWarningObservationIsIdempotentAndPreservesExplicitUnloadMarkers`. | Verify the visible panel is retained, inactive Web views are released, and explicit/auto/memory unload restores the expected URL once on the final build. |
| P0-7 | Ship first-class Notes, Bookmarks, History, and Downloads panels. | **Implemented** | Defaults are in [`FloorpPanel.swift`](../firefox-ios/Floorp/FloorpPanel.swift). [`FloorpLibraryPanelHost.swift`](../firefox-ios/Floorp/FloorpLibraryPanelHost.swift) embeds the native Library stacks while [`FloorpOverlayDrawerViewController.swift`](../firefox-ios/Floorp/FloorpOverlayDrawerViewController.swift) hosts Notes. `FloorpLibraryPanelHostTests`, `FloorpNativeLibraryDrawerTests`, and the Notes suites cover state retention, window routing, edits, search, reorder, and failure paths. | Smoke all four panels on iPhone and iPad, including empty/error states and opening an item, on the final build. |

### P1: desktop-equivalent panel affordances

| ID | Contract | Status | Source and deterministic evidence | Remaining release evidence |
| --- | --- | --- | --- | --- |
| P1-1 | Show stable built-in icons and a stable user-selected icon for each Web panel. | **Implemented with an intentional iOS choice** | [`FloorpPanel.swift`](../firefox-ios/Floorp/FloorpPanel.swift) defines a curated, validated SF Symbols allow-list and safe fallback. [`FloorpPanelRegistryViewController.swift`](../firefox-ios/Floorp/FloorpPanelRegistryViewController.swift) exposes the localized icon picker. `testEnforcesTitleAndIconPolicy` and `testIconPickerUsesHumanReadableLocalizedNames` cover validation and UI mapping. iOS does not fetch favicons or contact a third-party favicon service. | Confirm every curated icon renders in light/dark mode and remains stable after relaunch. |
| P1-2 | Retain a useful width for each panel. | **Implemented with an intentional persistence split** | `FloorpWebPanelPreferences.contentWidth` in [`FloorpPanel.swift`](../firefox-ios/Floorp/FloorpPanel.swift) persists each Web panel's validated width. Built-in panel widths remain independent only for the browser-window lifetime in `FloorpPanelPresentationState`. Coverage includes `testPreferencesRemainIndependentPerWebPanelAcrossRestart`, `testStoredWidthClampsToModelBoundsWhilePresentationOwnsAvailableWidthClamp`, `testPinnedWebPanelResizePersistsWithoutReplacingWideWindowPreference`, and `testClosedWindowStateReloadsWebPanelWidthAfterRegistryChange`. | Resize Web and built-in panels, switch between them, relaunch, and verify the documented persistence split. |
| P1-3 | Persist per-Web-panel zoom with bounded increase, decrease, and reset actions. | **Implemented** | The model and persistence are in [`FloorpPanel.swift`](../firefox-ios/Floorp/FloorpPanel.swift) and [`FloorpPanelManager.swift`](../firefox-ios/Floorp/FloorpPanelManager.swift); the WebView applies `pageZoom` in [`FloorpWebPanelWebViewSession.swift`](../firefox-ios/Floorp/FloorpWebPanelWebViewSession.swift). Menu and VoiceOver actions are in [`FloorpOverlayDrawerViewController.swift`](../firefox-ios/Floorp/FloorpOverlayDrawerViewController.swift). Coverage includes `testZoomUsesBoundedNativeStepsAndResetWithoutNoOpNotification`, `testZoomIsAppliedBeforeInitialNavigationAndUpdatesInPlaceOnlyWhenChanged`, `testZoomMenuAndVoiceOverActionsRespectBoundsAndReset`, and `testPersistedZoomAppliesWhenAutoUnloadRecreatesSession`. | Verify visible scale and persistence after panel switch, unload, and relaunch without changing main-tab zoom. |
| P1-4 | Persist Request Desktop Site / Request Mobile Site per Web panel and reload safely. | **Candidate — final CI pending** | [`FloorpWebPanelNavigationExecutor.swift`](../firefox-ios/Floorp/FloorpWebPanelNavigationExecutor.swift) applies `WKWebpagePreferences.preferredContentMode` and the app's domain-aware `UserAgent` only to allowed main-frame HTTP(S) navigation; exact `about:blank` participates in navigation lifecycle tracking without receiving HTTP content-mode overrides. [`FloorpWebPanelWebViewSession.swift`](../firefox-ios/Floorp/FloorpWebPanelWebViewSession.swift) uses one identity-bound arbiter for content-mode, Block Images, and manual reload reasons. It coalesces overlapping work, retires success/failure for the matching navigation (including `about:blank`), and retries a nil or failed reload only after an explicit trigger. The selected Mobile/Desktop mode persists per Web panel and propagates to loaded sessions in every window. Focused coverage includes `testMainFrameContentModeAppliesPreferredModeAndDomainUserAgent`, `testAboutBlankTracksLifecycleWithoutApplyingHTTPContentMode`, `testAboutBlankManualAndImageReloadsRetireUnifiedArbiter`, `testHiddenContentAndImageChangesCoalesceIntoOneOriginReload`, `testFailedContentReloadDoesNotRetryFromKVOUntilExplicitRequest`, and `testContentModeMenuUpdatesEveryWindowInPlaceAndClosesFindBeforeReload`. | Final CI must include all registered content-mode and reload-arbiter tests. A fixture must report the effective mode/UA before and after switching, hiding, unloading, and relaunching, and must exercise manual/content-mode/Block Images reloads on HTTP(S) and exact `about:blank`. |
| P1-5 | Expose state-aware panel actions through touch context menus and an equivalent non-pointer accessibility route. | **Implemented** | Sidebar buttons receive state-aware `UIMenu` content in [`FloorpOverlayDrawerViewController.swift`](../firefox-ios/Floorp/FloorpOverlayDrawerViewController.swift), including edit, move, remove, unload, content mode, and zoom. The same active-session actions are exposed as VoiceOver custom actions. Registry rows also expose context menus and accessibility actions in [`FloorpPanelRegistryViewController.swift`](../firefox-ios/Floorp/FloorpPanelRegistryViewController.swift). | Exercise long press, iPad pointer, destructive confirmation, and VoiceOver actions on the final build. |
| P1-6 | Find text in the loaded Web panel with next, previous, close, and hardware-keyboard commands. | **Implemented** | [`FloorpWebPanelFindController.swift`](../firefox-ios/Floorp/FloorpWebPanelFindController.swift) owns native/fallback find and request serialization. The drawer installs it only for the active Web session and removes it on switch/unload. `FloorpWebPanelFindControllerTests`, `testFindToolbarIsDiscoverableAndClearsWhenSwitchingPanels`, and default-runtime find tests cover the lifecycle. | Use a dynamic fixture with zero, one, and multiple matches; record wrap, keyboard avoidance, Cmd-F, Escape, and VoiceOver announcements. |
| P1-7 | Pause/resume all media in the active Web panel without persisting that state or affecting a replacement/private session. | **Candidate — final CI pending; intentional iOS divergence** | The candidate adds session-local `isUserMediaPaused` state and reversible native `setAllMediaPlaybackSuspended` transitions in [`FloorpWebPanelWebViewSession.swift`](../firefox-ios/Floorp/FloorpWebPanelWebViewSession.swift). [`FloorpOverlayDrawerViewController.swift`](../firefox-ios/Floorp/FloorpOverlayDrawerViewController.swift) exposes Pause Panel Media / Resume Panel Media through deferred menus and VoiceOver actions bound to the exact session identity, privacy mode, state, and revision. Transitions coalesce safely, roll back on native failure, withstand reentrant or late completions, and cannot let hidden-session retries override the newest user intent. Coverage includes `testExplicitMediaPauseAndVisibilityShareOneReversibleSuppressionState`, `testDelayedMediaPauseChangesCoalesceToLatestIntent`, `testOldPauseAndHiddenRetryFailuresCannotRollbackNewestResumeIntent`, `testMediaPauseMenuAndVoiceOverTogglePreserveActiveRuntime`, and `testStaleMediaPauseActionsCannotAffectReplacementPrivacyOrNewerState`. The pause state resets when the loaded session unloads or is recreated. | Final CI must include every registered media-pause test. Verify with an audible/video local fixture that Pause stops all playback and Resume continues it; do not record this as audio-only mute parity. |

## Notes status within the sidebar

Notes is a first-class built-in panel. Its local editing contract is separate
from the release-gated network transport.

| Area | Functional status | Evidence and boundary |
| --- | --- | --- |
| CRUD, search, reorder, and autosave | **Implemented** | [`FloorpNotes.swift`](../firefox-ios/Floorp/FloorpNotes.swift), [`FloorpOverlayDrawerViewController.swift`](../firefox-ios/Floorp/FloorpOverlayDrawerViewController.swift), and [`FloorpNoteEditorViewController.swift`](../firefox-ios/Floorp/FloorpNoteEditorViewController.swift). `FloorpNotesStoreTests`, `FloorpNotesInteractionControllerTests`, `FloorpNoteEditorInteractionTests`, and save-coordinator tests cover persistence, conflicts, filtered reorder, focus, and retry. |
| Desktop-compatible rich editing | **Implemented** | [`FloorpRichTextDocument.swift`](../firefox-ios/Floorp/FloorpRichTextDocument.swift) and [`FloorpNoteEditorViewController.swift`](../firefox-ios/Floorp/FloorpNoteEditorViewController.swift) support H1-H3, bold, italic, underline, strike, lists, alignment, undo/redo, and bounded image import while preserving unsupported source safely. `FloorpRichTextWebEditorViewTests` and `FloorpRichTextDocumentTests` provide executable round-trip and safety coverage. |
| Deterministic merge and transport boundary | **Implemented; optional Sync enabled in FloorpRelease** | [`FloorpNotesSync.swift`](../firefox-ios/Floorp/FloorpNotesSync.swift) contains the Application Services adapter contract, deterministic merge/runner, and the ordinary `release-default` policy gate. `FloorpNotesSyncTests` covers conflicts, retries, limits, cancellation, commit ordering, endpoint policy, and the shared fixture. Strict source-bound QA/release modes remain available separately. |

## Intentional iOS divergences and security boundary

These decisions are part of the shipping contract and must not be described as
accidental omissions:

- Web-panel navigation accepts HTTP, HTTPS, and exact `about:blank` only.
  [`FloorpWebPanelNavigationPolicy.swift`](../firefox-ios/Floorp/FloorpWebPanelNavigationPolicy.swift)
  cancels credential-bearing/invalid URLs and other schemes. A safe,
  user-initiated new-window request is handed to the owning main browser and
  privacy mode.
- Downloads, file pickers, media-permission prompts, and HTTP authentication
  are main-browser boundaries. The embedded panel does not promise those
  privileged workflows; the user opens the page in the main browser to perform
  them.
- Normal Web panels use the normal profile WebKit store; private panels use the
  private-session coordinator. Desktop containers and `userContextId` do not
  exist on iOS, so per-panel container identities are excluded.
- Registry data and Web preferences survive process restart. Active selection,
  loaded Web views, restoration snapshots, explicit-unload markers,
  media-pause state, and built-in widths are browser-window-lifetime state.
  Process restoration
  is excluded until Floorp adopts an explicit iOS scene-restoration contract.
- Web-panel icons are user-selected curated SF Symbols. Automatic favicon
  acquisition and third-party favicon services are excluded.
- Web-panel width persists per Web panel. Built-in panel width lasts for the
  current browser window only.
- Notes remains local unless the explicit network release gate has exact
  desktop, fixture, and linked Application Services evidence. The merge code
  alone never enables network traffic.
- Browser Manager, Floorp OS panels, extension sidebars, desktop containers,
  free-floating panel windows, and desktop process-restoration semantics are
  outside this iOS milestone.
- Add-ons, Passwords, and Settings continue to use native iOS destinations
  rather than becoming panel-registry entries.

## Shipping rule

The functional matrix may be updated when code and focused tests land, but the
sidebar may be declared release-accepted only when:

1. every candidate row is present in the recorded candidate source SHA;
2. required CI jobs succeed for that source SHA;
3. the live P0-4 fixture contract passes;
4. device, OS, accessibility, localization, and screenshot evidence is entered
   in [the acceptance checklist](floorp-panel-sidebar-acceptance.md); and
5. the recorded candidate source SHA is the source used for the evaluated
   Internal TestFlight build.

Any unfilled required field remains **pending**. Do not infer acceptance from a
different branch, earlier TestFlight build, source inspection, or a similar CI
workflow.

An Internal TestFlight candidate may be uploaded before manual acceptance is
complete, solely to collect the runtime evidence above. Uploading, processing,
or installing that candidate does not change its acceptance status. While any
required acceptance evidence is pending, its distribution status must remain
**Internal evidence collection only**: assign it only to **Floorp Internal** and
do not enable any external tester group, public link, Beta App Review, App Store
submission, or public release.
