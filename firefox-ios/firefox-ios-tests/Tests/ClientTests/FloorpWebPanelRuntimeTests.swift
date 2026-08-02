// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import TestKit
import UIKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebPanelSessionStoreTests: XCTestCase {
    func testSessionStateUsesSafeDefaults() throws {
        let configuration = FloorpWebPanelSessionConfiguration(
            panelTitle: "Panel",
            homeURL: try XCTUnwrap(URL(string: "https://example.com")),
            iconName: "globe"
        )

        let state = FloorpWebPanelSessionState(configuration: configuration)

        XCTAssertEqual(state.configuration, configuration)
        XCTAssertNil(state.currentURL)
        XCTAssertNil(state.pageTitle)
        XCTAssertFalse(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.estimatedProgress, 0)
    }

    func testSessionCreationIsLazyAndReusesTheSameIdentity() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        let panel = makePanel(id: "portal")

        XCTAssertEqual(factory.makeCallCount, 0)
        XCTAssertEqual(store.cachedSessionCount, 0)

        let first = try mockSession(from: store.session(for: panel, isPrivate: false))
        let second = try mockSession(from: store.session(for: panel, isPrivate: false))

        XCTAssertTrue(first === second)
        XCTAssertEqual(factory.makeCallCount, 1)
        XCTAssertEqual(store.cachedSessionCount, 1)
        XCTAssertEqual(first.state.configuration.panelTitle, "Panel portal")
        XCTAssertEqual(first.state.configuration.homeURL.absoluteString, "https://example.com/portal")
    }

    func testSessionKeysSeparateWindowsAndPrivacyModes() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let firstWindow = UUID()
        let secondWindow = UUID()
        let firstStore = FloorpWebPanelSessionStore(windowUUID: firstWindow, factory: factory)
        let secondStore = FloorpWebPanelSessionStore(windowUUID: secondWindow, factory: factory)
        let panel = makePanel(id: "portal")

        let regular = try mockSession(from: firstStore.session(for: panel, isPrivate: false))
        let privateSession = try mockSession(from: firstStore.session(for: panel, isPrivate: true))
        let otherWindow = try mockSession(from: secondStore.session(for: panel, isPrivate: false))

        XCTAssertEqual(
            Set(factory.sessions.map(\.key)),
            [
                FloorpWebPanelSessionKey(windowUUID: firstWindow, panelID: panel.id, isPrivate: false),
                FloorpWebPanelSessionKey(windowUUID: firstWindow, panelID: panel.id, isPrivate: true),
                FloorpWebPanelSessionKey(windowUUID: secondWindow, panelID: panel.id, isPrivate: false),
            ]
        )
        XCTAssertFalse(regular === privateSession)
        XCTAssertFalse(regular === otherWindow)
        XCTAssertFalse(privateSession === otherWindow)
    }

    func testHideAndUnloadAPIsAreWindowScopedAndIdempotent() throws {
        let firstWindow = WindowUUID()
        let secondWindow = WindowUUID()
        let firstFactory = MockFloorpWebPanelSessionFactory()
        let secondFactory = MockFloorpWebPanelSessionFactory()
        let firstStore = FloorpWebPanelSessionStore(
            windowUUID: firstWindow,
            factory: firstFactory
        )
        let secondStore = FloorpWebPanelSessionStore(
            windowUUID: secondWindow,
            factory: secondFactory
        )
        let panel = makePanel(id: "portal")
        let first = try mockSession(from: firstStore.session(for: panel, isPrivate: false))
        let second = try mockSession(from: secondStore.session(for: panel, isPrivate: false))

        XCTAssertFalse(firstStore.unloadSession(for: second.key))
        XCTAssertFalse(firstStore.hideSession(second, autoUnload: true))
        XCTAssertEqual(second.invalidationCount, 0)

        XCTAssertTrue(firstStore.hideSession(first, autoUnload: false))
        XCTAssertTrue(firstStore.hideSession(first, autoUnload: false))
        XCTAssertEqual(first.visibilityChanges, [false])
        XCTAssertEqual(first.invalidationCount, 0)

        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        first.recordRuntimeState(currentURL: currentURL, pageTitle: "Current")
        first.setVisible(true)
        XCTAssertTrue(firstStore.hideSession(first, autoUnload: true))
        XCTAssertFalse(firstStore.unloadSession(for: first.key))
        XCTAssertEqual(first.invalidationCount, 1)
        XCTAssertEqual(firstStore.cachedSessionCount, 0)
        XCTAssertEqual(secondStore.cachedSessionCount, 1)

        let replacement = try mockSession(from: firstStore.session(for: panel, isPrivate: false))
        XCTAssertFalse(replacement === first)
        XCTAssertEqual(replacement.restorationURL, currentURL)

        XCTAssertTrue(firstStore.unloadSession(for: replacement.key))
        let replacementBeforeCommit = try mockSession(
            from: firstStore.session(for: panel, isPrivate: false)
        )
        XCTAssertEqual(replacementBeforeCommit.restorationURL, currentURL)
    }

    func testUnloadUsesLatestSynchronousRestorationCandidateAndRejectsUnsafeURL() throws {
        let store = FloorpWebPanelSessionStore(
            windowUUID: WindowUUID(),
            factory: MockFloorpWebPanelSessionFactory()
        )
        let panel = makePanel(id: "latest-runtime")
        let session = try mockSession(from: store.session(for: panel, isPrivate: false))
        let staleStateURL = try XCTUnwrap(URL(string: "https://example.com/stale-state"))
        let latestRuntimeURL = try XCTUnwrap(URL(string: "https://example.com/latest-runtime"))
        session.recordRuntimeState(currentURL: staleStateURL, pageTitle: "Stale")
        session.setLatestRuntimeURLForRestoration(latestRuntimeURL)

        XCTAssertTrue(store.unloadSession(for: session.key))

        let restored = try mockSession(from: store.session(for: panel, isPrivate: false))
        XCTAssertEqual(restored.restorationURL, latestRuntimeURL)

        let unsafeURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        restored.recordRuntimeState(currentURL: staleStateURL, pageTitle: "Still stale")
        restored.setLatestRuntimeURLForRestoration(unsafeURL)
        XCTAssertTrue(store.unloadSession(for: restored.key))

        let unsafeReplacement = try mockSession(
            from: store.session(for: panel, isPrivate: false)
        )
        XCTAssertNil(unsafeReplacement.restorationURL)
    }

    func testRestorationSnapshotsStayWindowAndPrivacyScopedAndPrivatePurgeClearsThem() throws {
        let firstWindow = WindowUUID()
        let secondWindow = WindowUUID()
        let firstStore = FloorpWebPanelSessionStore(
            windowUUID: firstWindow,
            factory: MockFloorpWebPanelSessionFactory()
        )
        let secondStore = FloorpWebPanelSessionStore(
            windowUUID: secondWindow,
            factory: MockFloorpWebPanelSessionFactory()
        )
        let panel = makePanel(id: "portal")
        let regular = try mockSession(from: firstStore.session(for: panel, isPrivate: false))
        let privateSession = try mockSession(
            from: firstStore.session(for: panel, isPrivate: true)
        )
        let regularURL = try XCTUnwrap(URL(string: "https://example.com/regular-current"))
        let privateURL = try XCTUnwrap(URL(string: "https://example.com/private-current"))
        regular.recordRuntimeState(currentURL: regularURL, pageTitle: "Regular")
        privateSession.recordRuntimeState(currentURL: privateURL, pageTitle: "Private")

        XCTAssertTrue(firstStore.unloadSession(for: regular.key))
        XCTAssertTrue(firstStore.unloadSession(for: privateSession.key))

        let otherWindow = try mockSession(
            from: secondStore.session(for: panel, isPrivate: false)
        )
        XCTAssertNil(otherWindow.restorationURL)

        let restoredRegular = try mockSession(
            from: firstStore.session(for: panel, isPrivate: false)
        )
        XCTAssertEqual(restoredRegular.restorationURL, regularURL)

        XCTAssertFalse(firstStore.closePrivateSessions())
        let replacementPrivate = try mockSession(
            from: firstStore.session(for: panel, isPrivate: true)
        )
        XCTAssertNil(replacementPrivate.restorationURL)
    }

    func testReconcileDiscardsSnapshotsForChangedAndRemovedPanels() throws {
        let store = FloorpWebPanelSessionStore(
            windowUUID: WindowUUID(),
            factory: MockFloorpWebPanelSessionFactory()
        )
        let changedPanel = makePanel(id: "changed")
        let removedPanel = makePanel(id: "removed")
        let changedSession = try mockSession(
            from: store.session(for: changedPanel, isPrivate: false)
        )
        let removedSession = try mockSession(
            from: store.session(for: removedPanel, isPrivate: false)
        )
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        changedSession.recordRuntimeState(currentURL: currentURL, pageTitle: "Changed")
        removedSession.recordRuntimeState(currentURL: currentURL, pageTitle: "Removed")
        XCTAssertTrue(store.unloadSession(for: changedSession.key))
        XCTAssertTrue(store.unloadSession(for: removedSession.key))
        var changedHome = changedPanel
        changedHome.url = "https://floorp.app/new-home"

        store.reconcile(with: [changedHome])

        let changedReplacement = try mockSession(
            from: store.session(for: changedHome, isPrivate: false)
        )
        let removedReplacement = try mockSession(
            from: store.session(for: removedPanel, isPrivate: false)
        )
        XCTAssertNil(changedReplacement.restorationURL)
        XCTAssertNil(removedReplacement.restorationURL)
    }

    func testUnsafeURLsAndInvalidateAllCannotRestoreSnapshots() throws {
        let store = FloorpWebPanelSessionStore(
            windowUUID: WindowUUID(),
            factory: MockFloorpWebPanelSessionFactory()
        )
        let unsafePanel = makePanel(id: "unsafe")
        let unsafeSession = try mockSession(
            from: store.session(for: unsafePanel, isPrivate: false)
        )
        let unsafeURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        unsafeSession.recordRuntimeState(currentURL: unsafeURL, pageTitle: "Unsafe")
        XCTAssertTrue(store.unloadSession(for: unsafeSession.key))
        let unsafeReplacement = try mockSession(
            from: store.session(for: unsafePanel, isPrivate: false)
        )
        XCTAssertNil(unsafeReplacement.restorationURL)

        let safePanel = makePanel(id: "safe")
        let safeSession = try mockSession(from: store.session(for: safePanel, isPrivate: false))
        let safeURL = try XCTUnwrap(URL(string: "https://example.com/safe-current"))
        safeSession.recordRuntimeState(currentURL: safeURL, pageTitle: "Safe")
        XCTAssertTrue(store.unloadSession(for: safeSession.key))

        store.invalidateAll()

        let safeReplacement = try mockSession(
            from: store.session(for: safePanel, isPrivate: false)
        )
        XCTAssertNil(safeReplacement.restorationURL)
    }

    func testRegularSessionsUseLeastRecentlyUsedEviction() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(
            windowUUID: UUID(),
            regularSessionLimit: 2,
            factory: factory
        )
        let firstPanel = makePanel(id: "first")
        let secondPanel = makePanel(id: "second")
        let thirdPanel = makePanel(id: "third")
        let first = try mockSession(from: store.session(for: firstPanel, isPrivate: false))
        let second = try mockSession(from: store.session(for: secondPanel, isPrivate: false))

        _ = try store.session(for: firstPanel, isPrivate: false)
        let third = try mockSession(from: store.session(for: thirdPanel, isPrivate: false))

        XCTAssertEqual(first.invalidationCount, 0)
        XCTAssertEqual(second.invalidationCount, 1)
        XCTAssertEqual(third.invalidationCount, 0)
        XCTAssertEqual(store.cachedSessionKeys.map(\.panelID).sorted(), ["first", "third"])
    }

    func testPrivateSessionsDoNotConsumeRegularLRUCapacity() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(
            windowUUID: UUID(),
            regularSessionLimit: 1,
            factory: factory
        )
        let regularPanel = makePanel(id: "regular")
        let privatePanel = makePanel(id: "private")
        let nextRegularPanel = makePanel(id: "next-regular")
        let regular = try mockSession(from: store.session(for: regularPanel, isPrivate: false))
        let privateSession = try mockSession(from: store.session(for: privatePanel, isPrivate: true))

        _ = try store.session(for: nextRegularPanel, isPrivate: false)

        XCTAssertEqual(regular.invalidationCount, 1)
        XCTAssertEqual(privateSession.invalidationCount, 0)
        XCTAssertEqual(store.cachedSessionCount, 2)
        XCTAssertTrue(store.cachedSessionKeys.contains(privateSession.key))
    }

    func testClosingPrivateSessionsPurgesOnlyPrivateState() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        let panel = makePanel(id: "portal")
        let regular = try mockSession(from: store.session(for: panel, isPrivate: false))
        let privateSession = try mockSession(from: store.session(for: panel, isPrivate: true))
        privateSession.recordRuntimeState(
            currentURL: try XCTUnwrap(URL(string: "https://example.com/private-current")),
            pageTitle: "Private"
        )

        store.closePrivateSessions()

        XCTAssertEqual(regular.invalidationCount, 0)
        XCTAssertEqual(privateSession.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionCount, 1)
        let reusedRegular = try mockSession(from: store.session(for: panel, isPrivate: false))
        let replacementPrivate = try mockSession(from: store.session(for: panel, isPrivate: true))
        XCTAssertTrue(regular === reusedRegular)
        XCTAssertFalse(privateSession === replacementPrivate)
        XCTAssertNil(replacementPrivate.restorationURL)
    }

    func testPresentationStatePurgesPrivateSessionsWhenLastPrivateTabCloses() throws {
        let windowUUID = WindowUUID()
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: windowUUID, factory: factory)
        let panel = makePanel(id: "portal")
        let regular = try mockSession(from: store.session(for: panel, isPrivate: false))
        let privateSession = try mockSession(from: store.session(for: panel, isPrivate: true))
        let state = FloorpPanelPresentationState(
            windowUUID: windowUUID,
            webPanelSessionStore: store
        )
        let tabManager = MockTabManager(windowUUID: windowUUID)
        let closedPrivateTab = Tab(
            profile: MockProfile(),
            isPrivate: true,
            windowUUID: windowUUID,
            documentLogger: DocumentLogger(logger: MockLogger())
        )

        tabManager.privateTabs = [closedPrivateTab]
        state.observePrivateTabLifecycle(in: tabManager)
        tabManager.privateTabs = []
        state.tabManager(tabManager, didRemoveTab: closedPrivateTab, isRestoring: false)

        XCTAssertEqual(regular.invalidationCount, 0)
        XCTAssertEqual(privateSession.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionKeys, [regular.key])
    }

    func testPresentationStateKeepsPrivateSessionsWhileAnotherPrivateTabExists() throws {
        let windowUUID = WindowUUID()
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: windowUUID, factory: factory)
        let privateSession = try mockSession(
            from: store.session(for: makePanel(id: "portal"), isPrivate: true)
        )
        let state = FloorpPanelPresentationState(
            windowUUID: windowUUID,
            webPanelSessionStore: store
        )
        let tabManager = MockTabManager(windowUUID: windowUUID)
        let remainingPrivateTab = Tab(
            profile: MockProfile(),
            isPrivate: true,
            windowUUID: windowUUID,
            documentLogger: DocumentLogger(logger: MockLogger())
        )
        tabManager.privateTabs = [remainingPrivateTab]

        state.observePrivateTabLifecycle(in: tabManager)
        state.tabManager(tabManager, didRemoveTab: remainingPrivateTab, isRestoring: false)

        XCTAssertEqual(privateSession.invalidationCount, 0)
        XCTAssertEqual(store.cachedSessionKeys, [privateSession.key])
    }

    func testPresentationStateRegistersAndRemovesPrivateTabLifecycleObserver() {
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        let tabManager = FloorpRecordingTabManager()

        state.observePrivateTabLifecycle(in: tabManager)
        XCTAssertTrue(tabManager.addedDelegate === state)

        state.invalidateWebPanelRuntime()
        XCTAssertTrue(tabManager.removedDelegate === state)
    }

    func testPresentationStateIgnoresCallbacksFromPreviouslyObservedManager() throws {
        let windowUUID = WindowUUID()
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: windowUUID, factory: factory)
        let privateSession = try mockSession(
            from: store.session(for: makePanel(id: "portal"), isPrivate: true)
        )
        let state = FloorpPanelPresentationState(
            windowUUID: windowUUID,
            webPanelSessionStore: store
        )
        let previousManager = MockTabManager(windowUUID: windowUUID)
        let currentManager = MockTabManager(windowUUID: windowUUID)
        let closedPrivateTab = Tab(
            profile: MockProfile(),
            isPrivate: true,
            windowUUID: windowUUID,
            documentLogger: DocumentLogger(logger: MockLogger())
        )
        previousManager.privateTabs = [closedPrivateTab]
        currentManager.privateTabs = [closedPrivateTab]

        state.observePrivateTabLifecycle(in: previousManager)
        state.observePrivateTabLifecycle(in: currentManager)
        previousManager.privateTabs = []
        currentManager.privateTabs = []
        state.tabManager(previousManager, didRemoveTab: closedPrivateTab, isRestoring: false)

        XCTAssertEqual(privateSession.invalidationCount, 0)
        XCTAssertEqual(store.cachedSessionKeys, [privateSession.key])

        state.tabManager(currentManager, didRemoveTab: closedPrivateTab, isRestoring: false)

        XCTAssertEqual(privateSession.invalidationCount, 1)
        XCTAssertTrue(store.cachedSessionKeys.isEmpty)
    }

    func testPresentationStateRejectsForeignWindowLifecycleObserver() throws {
        let windowUUID = WindowUUID()
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: windowUUID, factory: factory)
        let privateSession = try mockSession(
            from: store.session(for: makePanel(id: "portal"), isPrivate: true)
        )
        let state = FloorpPanelPresentationState(
            windowUUID: windowUUID,
            webPanelSessionStore: store
        )
        let foreignManager = FloorpRecordingTabManager(windowUUID: WindowUUID())
        foreignManager.privateTabs = []

        state.observePrivateTabLifecycle(in: foreignManager)

        XCTAssertNil(foreignManager.addedDelegate)
        XCTAssertEqual(privateSession.invalidationCount, 0)
        XCTAssertEqual(store.cachedSessionKeys, [privateSession.key])
    }

    func testSelectedTabPrivacyBoundaryIsManagerScopedAndPrecedesPrivatePurge() throws {
        let windowUUID = WindowUUID()
        let store = FloorpWebPanelSessionStore(
            windowUUID: windowUUID,
            factory: MockFloorpWebPanelSessionFactory()
        )
        let privateSession = try mockSession(
            from: store.session(for: makePanel(id: "portal"), isPrivate: true)
        )
        let state = FloorpPanelPresentationState(
            windowUUID: windowUUID,
            webPanelSessionStore: store
        )
        let currentManager = MockTabManager(windowUUID: windowUUID)
        let otherManager = MockTabManager(windowUUID: windowUUID)
        let otherWindowManager = MockTabManager(windowUUID: WindowUUID())
        let privateTab = makeTab(isPrivate: true, windowUUID: windowUUID)
        let regularTab = makeTab(isPrivate: false, windowUUID: windowUUID)
        let otherWindowTab = makeTab(
            isPrivate: false,
            windowUUID: otherWindowManager.windowUUID
        )
        currentManager.selectedTab = privateTab
        currentManager.privateTabs = [privateTab]
        state.observePrivateTabLifecycle(in: currentManager)
        let presentation = FloorpPrivacyModePresentationSpy()
        XCTAssertTrue(state.attach(presentation))

        state.tabManager(
            otherManager,
            didSelectedTabChange: regularTab,
            previousTab: privateTab,
            isRestoring: false
        )
        state.tabManager(
            otherWindowManager,
            didSelectedTabChange: regularTab,
            previousTab: privateTab,
            isRestoring: false
        )
        state.tabManager(
            currentManager,
            didSelectedTabChange: otherWindowTab,
            previousTab: privateTab,
            isRestoring: false
        )
        XCTAssertTrue(presentation.events.isEmpty)
        XCTAssertEqual(privateSession.invalidationCount, 0)

        currentManager.selectedTab = regularTab
        currentManager.privateTabs = []
        state.tabManager(
            currentManager,
            didSelectedTabChange: regularTab,
            previousTab: privateTab,
            isRestoring: false
        )

        XCTAssertEqual(presentation.events, [.rebind(false), .privateSessionsClosed(false)])
        XCTAssertEqual(privateSession.invalidationCount, 1)
        state.detach(presentation)
    }

    func testSelectedPrivateTabDefersPurgeWhenPrivateListIsTransientlyEmpty() throws {
        let windowUUID = WindowUUID()
        let store = FloorpWebPanelSessionStore(
            windowUUID: windowUUID,
            factory: MockFloorpWebPanelSessionFactory()
        )
        let privateSession = try mockSession(
            from: store.session(for: makePanel(id: "portal"), isPrivate: true)
        )
        let state = FloorpPanelPresentationState(
            windowUUID: windowUUID,
            webPanelSessionStore: store
        )
        let tabManager = MockTabManager(windowUUID: windowUUID)
        let privateTab = makeTab(isPrivate: true, windowUUID: windowUUID)
        let regularTab = makeTab(isPrivate: false, windowUUID: windowUUID)
        tabManager.selectedTab = privateTab
        tabManager.privateTabs = [privateTab]
        state.observePrivateTabLifecycle(in: tabManager)
        let presentation = FloorpPrivacyModePresentationSpy()
        XCTAssertTrue(state.attach(presentation))

        tabManager.privateTabs = []
        state.tabManager(
            tabManager,
            didSelectedTabChange: privateTab,
            previousTab: regularTab,
            isRestoring: true
        )

        XCTAssertEqual(presentation.events, [.rebind(true)])
        XCTAssertEqual(privateSession.invalidationCount, 0)
        XCTAssertEqual(store.cachedSessionKeys, [privateSession.key])
        state.detach(presentation)
    }

    func testReconcileRemovesMissingInvalidAndDuplicatePanels() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        let missingPanel = makePanel(id: "missing")
        let invalidPanel = makePanel(id: "invalid")
        let duplicatePanel = makePanel(id: "duplicate")
        let missing = try mockSession(from: store.session(for: missingPanel, isPrivate: false))
        let invalid = try mockSession(from: store.session(for: invalidPanel, isPrivate: false))
        let duplicate = try mockSession(from: store.session(for: duplicatePanel, isPrivate: false))
        var malformed = invalidPanel
        malformed.url = "javascript:alert(1)"
        var duplicateCopy = duplicatePanel
        duplicateCopy.title = "Conflicting duplicate"

        store.reconcile(with: [malformed, duplicatePanel, duplicateCopy])

        XCTAssertEqual(missing.invalidationCount, 1)
        XCTAssertEqual(invalid.invalidationCount, 1)
        XCTAssertEqual(duplicate.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionCount, 0)
    }

    func testReconcileInvalidatesURLChangesWithoutEagerRecreation() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        let panel = makePanel(id: "portal")
        let first = try mockSession(from: store.session(for: panel, isPrivate: false))
        var changed = panel
        changed.url = "https://floorp.app/changed"

        store.reconcile(with: [changed])

        XCTAssertEqual(first.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionCount, 0)
        XCTAssertEqual(factory.makeCallCount, 1)

        let replacement = try mockSession(from: store.session(for: changed, isPrivate: false))
        XCTAssertFalse(first === replacement)
        XCTAssertEqual(factory.makeCallCount, 2)
    }

    func testLookupInvalidatesURLChangesWithoutReconcile() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        let panel = makePanel(id: "portal")
        let first = try mockSession(from: store.session(for: panel, isPrivate: false))
        var changed = panel
        changed.url = "https://floorp.app/changed"

        let replacement = try mockSession(from: store.session(for: changed, isPrivate: false))

        XCTAssertEqual(first.invalidationCount, 1)
        XCTAssertFalse(first === replacement)
        XCTAssertEqual(replacement.state.configuration.homeURL.absoluteString, changed.url)
    }

    func testMetadataChangesPreserveSessionAndRuntimeState() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        let panel = makePanel(id: "portal")
        let regular = try mockSession(from: store.session(for: panel, isPrivate: false))
        let privateSession = try mockSession(from: store.session(for: panel, isPrivate: true))
        let runtimeURL = try XCTUnwrap(URL(string: "https://example.com/portal/current"))
        regular.recordRuntimeState(currentURL: runtimeURL, pageTitle: "Loaded title")
        privateSession.recordRuntimeState(currentURL: runtimeURL, pageTitle: "Private loaded title")
        var changed = panel
        changed.title = "Updated panel"
        changed.iconName = "star"

        store.reconcile(with: [changed])

        XCTAssertEqual(regular.configurationUpdateCount, 1)
        XCTAssertEqual(privateSession.configurationUpdateCount, 1)
        XCTAssertEqual(regular.state.configuration.panelTitle, "Updated panel")
        XCTAssertEqual(regular.state.configuration.iconName, "star")
        XCTAssertEqual(regular.state.currentURL, runtimeURL)
        XCTAssertEqual(regular.state.pageTitle, "Loaded title")
        XCTAssertEqual(privateSession.state.pageTitle, "Private loaded title")
        XCTAssertEqual(regular.invalidationCount, 0)
        XCTAssertEqual(privateSession.invalidationCount, 0)
    }

    func testCanonicalEquivalentURLAndOrderingDoNotInvalidateSessions() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        let firstPanel = makePanel(id: "first", url: "HTTP://Example.COM/first")
        let secondPanel = makePanel(id: "second")
        let first = try mockSession(from: store.session(for: firstPanel, isPrivate: false))
        let second = try mockSession(from: store.session(for: secondPanel, isPrivate: false))
        var reorderedFirst = firstPanel
        reorderedFirst.url = "http://example.com/first"
        reorderedFirst.sortOrder = 1
        var reorderedSecond = secondPanel
        reorderedSecond.sortOrder = 0

        store.reconcile(with: [reorderedSecond, reorderedFirst])

        let reusedFirst = try mockSession(from: store.session(for: reorderedFirst, isPrivate: false))
        let reusedSecond = try mockSession(from: store.session(for: reorderedSecond, isPrivate: false))
        XCTAssertEqual(first.invalidationCount, 0)
        XCTAssertEqual(second.invalidationCount, 0)
        XCTAssertTrue(first === reusedFirst)
        XCTAssertTrue(second === reusedSecond)
    }

    func testInvalidateAllIsIdempotent() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        let regular = try mockSession(from: store.session(for: makePanel(id: "regular"), isPrivate: false))
        let privateSession = try mockSession(from: store.session(for: makePanel(id: "private"), isPrivate: true))

        store.invalidateAll()
        store.invalidateAll()

        XCTAssertEqual(regular.invalidationCount, 1)
        XCTAssertEqual(privateSession.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionCount, 0)
        XCTAssertTrue(store.cachedSessionKeys.isEmpty)
    }

    func testFactoryFailuresAndInvalidPanelsAreNotCached() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        factory.errorToThrow = MockFloorpWebPanelSessionFactory.ExpectedError.failure

        XCTAssertThrowsError(try store.session(for: makePanel(id: "failure"), isPrivate: false))
        XCTAssertEqual(store.cachedSessionCount, 0)
        XCTAssertEqual(factory.makeCallCount, 1)

        factory.errorToThrow = nil
        var invalidPanel = makePanel(id: "invalid")
        invalidPanel.url = "file:///tmp/panel"
        XCTAssertThrowsError(try store.session(for: invalidPanel, isPrivate: false))
        XCTAssertEqual(store.cachedSessionCount, 0)
        XCTAssertEqual(factory.makeCallCount, 1)
    }

    func testFactoryFailureDoesNotConsumeRestorationSnapshot() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: WindowUUID(), factory: factory)
        let panel = makePanel(id: "failure")
        let session = try mockSession(from: store.session(for: panel, isPrivate: false))
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        session.recordRuntimeState(currentURL: currentURL, pageTitle: "Current")
        XCTAssertTrue(store.unloadSession(for: session.key))
        factory.errorToThrow = MockFloorpWebPanelSessionFactory.ExpectedError.failure

        XCTAssertThrowsError(try store.session(for: panel, isPrivate: false))

        factory.errorToThrow = nil
        let restored = try mockSession(from: store.session(for: panel, isPrivate: false))
        XCTAssertEqual(restored.restorationURL, currentURL)
    }

    func testNonWebPanelsAreRejectedBeforeCallingFactory() {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)

        for panel in FloorpPanel.defaultPanels() {
            XCTAssertThrowsError(try store.session(for: panel, isPrivate: false))
        }

        XCTAssertEqual(factory.makeCallCount, 0)
        XCTAssertEqual(store.cachedSessionCount, 0)
    }

    func testMismatchedFactoryKeyIsInvalidatedAndRejected() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let windowUUID = WindowUUID()
        let store = FloorpWebPanelSessionStore(windowUUID: windowUUID, factory: factory)
        let panel = makePanel(id: "portal")
        let first = try mockSession(from: store.session(for: panel, isPrivate: false))
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        first.recordRuntimeState(currentURL: currentURL, pageTitle: "Current")
        XCTAssertTrue(store.unloadSession(for: first.key))
        factory.keyOverride = FloorpWebPanelSessionKey(
            windowUUID: UUID(),
            panelID: "wrong-panel",
            isPrivate: false
        )

        XCTAssertThrowsError(try store.session(for: panel, isPrivate: false)) { error in
            XCTAssertEqual(error as? FloorpWebPanelSessionStoreError, .factoryReturnedMismatchedKey)
        }
        XCTAssertEqual(factory.sessions.last?.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionCount, 0)

        factory.keyOverride = nil
        let restored = try mockSession(from: store.session(for: panel, isPrivate: false))
        XCTAssertEqual(restored.restorationURL, currentURL)
    }

    private func makePanel(
        id: String,
        url: String? = nil,
        iconName: String = "globe"
    ) -> FloorpPanel {
        FloorpPanel(
            id: id,
            type: .web,
            title: "Panel \(id)",
            url: url ?? "https://example.com/\(id)",
            iconName: iconName,
            sortOrder: 0
        )
    }

    private func mockSession(
        from session: any FloorpWebPanelSessionProtocol
    ) throws -> MockFloorpWebPanelSession {
        try XCTUnwrap(session as? MockFloorpWebPanelSession)
    }

    private func makeTab(isPrivate: Bool, windowUUID: WindowUUID) -> Tab {
        Tab(
            profile: MockProfile(),
            isPrivate: isPrivate,
            windowUUID: windowUUID,
            documentLogger: DocumentLogger(logger: MockLogger())
        )
    }
}

@MainActor
private final class FloorpRecordingTabManager: MockTabManager {
    private(set) weak var addedDelegate: (any TabManagerDelegate)?
    private(set) weak var removedDelegate: (any TabManagerDelegate)?

    override func addDelegate(_ delegate: any TabManagerDelegate) {
        addedDelegate = delegate
    }

    override func removeDelegate(
        _ delegate: any TabManagerDelegate,
        completion: (() -> Void)?
    ) {
        removedDelegate = delegate
        completion?()
    }
}

@MainActor
private final class FloorpPrivacyModePresentationSpy: FloorpPanelPrivacyModePresenting {
    enum Event: Equatable {
        case rebind(Bool)
        case privateSessionsClosed(Bool?)
    }

    private(set) var events = [Event]()

    func rebindActiveContent(forSelectedTabIsPrivate isPrivate: Bool) {
        events.append(.rebind(isPrivate))
    }

    func privateWebPanelSessionsDidClose(selectedTabIsPrivate: Bool?) {
        events.append(.privateSessionsClosed(selectedTabIsPrivate))
    }
}

@MainActor
private final class FloorpMutablePrivacyState {
    var isPrivate: Bool

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
    }
}

@MainActor
final class FloorpWebPanelFindControllerTests: XCTestCase {
    func testNativeInteractionOwnsPresentationAndKeyboardNavigation() {
        let target = MockFloorpWebPanelFindTarget(supportsNativeFindInteraction: true)
        let controller = FloorpWebPanelFindController(
            target: target,
            accessibilityAnnouncement: { _ in }
        )

        XCTAssertTrue(controller.present())
        XCTAssertEqual(controller.state, .native)
        XCTAssertTrue(controller.toolbarView.isHidden)
        XCTAssertEqual(target.nativePresentationCount, 1)

        controller.findNext()
        controller.findPrevious()

        XCTAssertEqual(target.nativeNextCount, 1)
        XCTAssertEqual(target.nativePreviousCount, 1)
        XCTAssertTrue(controller.dismissIfActive())
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertEqual(target.endSessionCount, 1)
    }

    func testFallbackFindSerializesRequestsAndKeepsOnlyLatestQuery() {
        let target = MockFloorpWebPanelFindTarget()
        var announcements = [String]()
        let controller = FloorpWebPanelFindController(
            target: target,
            accessibilityAnnouncement: { announcements.append($0) }
        )
        XCTAssertTrue(controller.present())

        controller.updateQuery("first")
        controller.updateQuery("second")
        controller.updateQuery("third")

        XCTAssertEqual(target.requests.map(\.query), ["first"])
        XCTAssertEqual(target.requests.first?.kind, .queryChanged)
        XCTAssertEqual(target.requests.first?.wraps, true)
        target.completeNext(matchFound: true)
        XCTAssertEqual(target.requests.map(\.query), ["first", "third"])
        XCTAssertEqual(target.requests.last?.kind, .queryChanged)
        XCTAssertEqual(target.requests.last?.wraps, true)
        XCTAssertEqual(controller.state, .searching("third"))

        target.completeNext(matchFound: false)

        XCTAssertEqual(controller.state, .noMatch("third"))
        XCTAssertEqual(announcements, [FloorpStrings.Drawer.webPanelFindNoMatches])
    }

    func testFallbackReportsDocumentBoundariesAfterFindingAMatch() {
        let target = MockFloorpWebPanelFindTarget()
        let controller = FloorpWebPanelFindController(
            target: target,
            accessibilityAnnouncement: { _ in }
        )
        XCTAssertTrue(controller.present())
        controller.updateQuery("needle")
        XCTAssertEqual(target.requests.last?.wraps, true)
        target.completeNext(matchFound: true)
        XCTAssertEqual(controller.state, .match("needle"))

        controller.findNext()
        XCTAssertEqual(target.requests.last?.direction, .forward)
        XCTAssertEqual(target.requests.last?.kind, .navigation)
        XCTAssertEqual(target.requests.last?.wraps, false)
        target.completeNext(matchFound: false)
        XCTAssertEqual(controller.state, .finished("needle", .forward))

        controller.findPrevious()
        XCTAssertEqual(target.requests.last?.direction, .backward)
        XCTAssertEqual(target.requests.last?.kind, .navigation)
        XCTAssertEqual(target.requests.last?.wraps, false)
        target.completeNext(matchFound: false)
        XCTAssertEqual(controller.state, .finished("needle", .backward))
    }

    func testTimeoutKeepsRequestSlotUntilLateCompletionAndStartsLatestQuery() {
        let target = MockFloorpWebPanelFindTarget()
        let timeoutScheduler = MockFloorpWebPanelFindTimeoutScheduler()
        let controller = FloorpWebPanelFindController(
            target: target,
            requestTimeoutNanoseconds: 1,
            timeoutScheduler: timeoutScheduler,
            accessibilityAnnouncement: { _ in }
        )
        XCTAssertTrue(controller.present())
        controller.updateQuery("slow")
        XCTAssertEqual(target.requests.map(\.query), ["slow"])
        XCTAssertEqual(target.pendingCompletionCount, 1)
        XCTAssertEqual(timeoutScheduler.scheduledDelays, [1])

        timeoutScheduler.fireNext()
        XCTAssertEqual(controller.state, .unavailable("slow"))
        controller.updateQuery("newer")
        controller.updateQuery("latest")

        XCTAssertEqual(target.requests.map(\.query), ["slow"])
        XCTAssertEqual(target.pendingCompletionCount, 1)
        XCTAssertEqual(controller.state, .searching("latest"))
        target.completeNext(matchFound: true)

        XCTAssertEqual(target.requests.map(\.query), ["slow", "latest"])
        XCTAssertEqual(target.pendingCompletionCount, 1)
        XCTAssertEqual(controller.state, .searching("latest"))
        target.completeNext(matchFound: false)
        XCTAssertEqual(target.pendingCompletionCount, 0)
        XCTAssertEqual(controller.state, .noMatch("latest"))
    }

    func testInvalidationClearsMemoryAndIgnoresLateResults() {
        let target = MockFloorpWebPanelFindTarget()
        let controller = FloorpWebPanelFindController(
            target: target,
            accessibilityAnnouncement: { _ in }
        )
        XCTAssertTrue(controller.present())
        controller.updateQuery("private query")
        XCTAssertEqual(controller.state, .searching("private query"))

        controller.invalidate()
        target.completeNext(matchFound: true)

        XCTAssertEqual(controller.state, .inactive)
        XCTAssertTrue(controller.toolbarView.isHidden)
        XCTAssertEqual(target.endSessionCount, 1)
    }
}

@MainActor
final class FloorpWebPanelDrawerRuntimeTests: XCTestCase {
    func testSelectedTabModeChangesRebindBothDirectionsWithoutReplacingDrawer() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let privacyState = FloorpMutablePrivacyState(isPrivate: false)
        let tabManager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let regularTab = makeTab(isPrivate: false)
        let privateTab = makeTab(isPrivate: true)
        tabManager.selectedTab = regularTab
        tabManager.privateTabs = [privateTab]
        fixture.presentationState.observePrivateTabLifecycle(in: tabManager)
        let drawer = fixture.makeDrawer(isPrivateProvider: { privacyState.isPrivate })
        let presentation = try await present(drawer: drawer)
        defer { presentation.cleanup() }
        let container = try XCTUnwrap(
            findView(identifier: "Floorp.Drawer.Container", in: drawer.view)
        )
        let originalFrame = container.frame
        let regularSession = try XCTUnwrap(fixture.factory.sessions.first)
        regularSession.recordRuntimeState(
            currentURL: try XCTUnwrap(URL(string: "https://example.com/regular-current")),
            pageTitle: "Regular"
        )

        privacyState.isPrivate = true
        tabManager.selectedTab = privateTab
        fixture.presentationState.tabManager(
            tabManager,
            didSelectedTabChange: privateTab,
            previousTab: regularTab,
            isRestoring: false
        )
        let privateSession = try XCTUnwrap(fixture.factory.sessions.last)
        privateSession.recordRuntimeState(
            currentURL: try XCTUnwrap(URL(string: "https://example.com/private-current")),
            pageTitle: "Private"
        )
        XCTAssertTrue(privateSession.key.isPrivate)
        XCTAssertEqual(regularSession.visibilityChanges, [false])
        XCTAssertNil(regularSession.contentView?.superview)

        privacyState.isPrivate = false
        tabManager.selectedTab = regularTab
        fixture.presentationState.tabManager(
            tabManager,
            didSelectedTabChange: regularTab,
            previousTab: privateTab,
            isRestoring: false
        )
        drawer.view.layoutIfNeeded()

        XCTAssertEqual(fixture.factory.makeCallCount, 2)
        XCTAssertTrue(fixture.presentationState.activeDrawer === drawer)
        XCTAssertTrue(presentation.parent.presentedViewController === drawer)
        XCTAssertEqual(container.frame, originalFrame)
        XCTAssertEqual(regularSession.visibilityChanges, [false, true])
        XCTAssertEqual(privateSession.visibilityChanges, [false])
        XCTAssertNil(privateSession.contentView?.superview)
        XCTAssertNotNil(regularSession.contentView?.superview)
        XCTAssertEqual(regularSession.invalidationCount, 0)
        XCTAssertEqual(privateSession.invalidationCount, 0)

        fixture.presentationState.tabManager(
            tabManager,
            didSelectedTabChange: regularTab,
            previousTab: regularTab,
            isRestoring: false
        )
        XCTAssertEqual(fixture.factory.makeCallCount, 2)
        XCTAssertEqual(regularSession.visibilityChanges, [false, true])

        let openButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.OpenInMainBrowser", in: drawer.view) as? UIButton
        )
        let dismissed = expectation(description: "Rebound web panel drawer dismissed")
        drawer.onDismissed = { dismissed.fulfill() }
        openButton.sendActions(for: .touchUpInside)
        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertEqual(regularSession.openInMainBrowserCallCount, 1)
        XCTAssertEqual(privateSession.openInMainBrowserCallCount, 0)
    }

    func testPrivacyModeRebindAutoUnloadKeepsRestorationModeScoped() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        _ = try fixture.manager.setAutoUnload(
            true,
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: fixture.manager.config)
        )
        let privacyState = FloorpMutablePrivacyState(isPrivate: false)
        let tabManager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let regularTab = makeTab(isPrivate: false)
        let privateTab = makeTab(isPrivate: true)
        tabManager.selectedTab = regularTab
        tabManager.privateTabs = [privateTab]
        fixture.presentationState.observePrivateTabLifecycle(in: tabManager)
        let drawer = fixture.makeDrawer(isPrivateProvider: { privacyState.isPrivate })
        let presentation = try await present(drawer: drawer)
        defer { presentation.cleanup() }
        let regularSession = try XCTUnwrap(fixture.factory.sessions.first)
        let regularURL = try XCTUnwrap(URL(string: "https://example.com/regular-current"))
        let privateURL = try XCTUnwrap(URL(string: "https://example.com/private-current"))
        regularSession.recordRuntimeState(currentURL: regularURL, pageTitle: "Regular")

        privacyState.isPrivate = true
        tabManager.selectedTab = privateTab
        fixture.presentationState.tabManager(
            tabManager,
            didSelectedTabChange: privateTab,
            previousTab: regularTab,
            isRestoring: false
        )
        let privateSession = try XCTUnwrap(fixture.factory.sessions.last)
        privateSession.recordRuntimeState(currentURL: privateURL, pageTitle: "Private")
        XCTAssertEqual(regularSession.invalidationCount, 1)

        privacyState.isPrivate = false
        tabManager.selectedTab = regularTab
        fixture.presentationState.tabManager(
            tabManager,
            didSelectedTabChange: regularTab,
            previousTab: privateTab,
            isRestoring: false
        )
        let restoredRegularSession = try XCTUnwrap(fixture.factory.sessions.last)

        XCTAssertEqual(privateSession.invalidationCount, 1)
        XCTAssertFalse(restoredRegularSession.key.isPrivate)
        XCTAssertEqual(restoredRegularSession.restorationURL, regularURL)
        XCTAssertNotEqual(restoredRegularSession.restorationURL, privateURL)
        XCTAssertNotNil(restoredRegularSession.contentView?.superview)
        XCTAssertNil(privateSession.contentView)
    }

    func testLastPrivateTabCloseRebindsVisibleWebPanelToRegularSession() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let privacyState = FloorpMutablePrivacyState(isPrivate: true)
        let drawer = fixture.makeDrawer(isPrivateProvider: { privacyState.isPrivate })
        let tabManager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let privateTab = Tab(
            profile: MockProfile(),
            isPrivate: true,
            windowUUID: .XCTestDefaultUUID,
            documentLogger: DocumentLogger(logger: MockLogger())
        )
        tabManager.privateTabs = [privateTab]
        fixture.presentationState.observePrivateTabLifecycle(in: tabManager)
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let presented = expectation(description: "Private web panel drawer presented")
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        let privateSession = try XCTUnwrap(fixture.factory.sessions.first)
        XCTAssertTrue(privateSession.key.isPrivate)
        XCTAssertEqual(privateSession.stateObserverCount, 1)
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: drawer.view) as? UIButton
        )
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
        )
        findButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(findToolbar.isHidden)

        let regularTab = makeTab(isPrivate: false)
        privacyState.isPrivate = false
        tabManager.selectedTab = regularTab
        tabManager.privateTabs = []
        fixture.presentationState.tabManager(
            tabManager,
            didSelectedTabChange: regularTab,
            previousTab: privateTab,
            isRestoring: false
        )
        fixture.presentationState.tabManager(
            tabManager,
            didRemoveTab: privateTab,
            isRestoring: false
        )

        XCTAssertEqual(privateSession.invalidationCount, 1)
        XCTAssertEqual(privateSession.stateObserverCount, 0)
        XCTAssertNil(privateSession.contentView?.superview)
        XCTAssertNil(findToolbar.superview)
        XCTAssertEqual(privateSession.findTargetMock.invalidationCount, 1)
        XCTAssertEqual(fixture.factory.sessions.count, 2)
        let regularSession = try XCTUnwrap(fixture.factory.sessions.last)
        XCTAssertFalse(regularSession.key.isPrivate)
        XCTAssertEqual(regularSession.stateObserverCount, 1)
        XCTAssertNotNil(regularSession.contentView?.superview)

        let dismissed = expectation(description: "Rebound drawer dismissed")
        drawer.onDismissed = { dismissed.fulfill() }
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
    }

    func testLastPrivateTabCloseDismissesDrawerUntilSelectionLeavesPrivateMode() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: true)
        let tabManager = MockTabManager(windowUUID: .XCTestDefaultUUID)
        let privateTab = Tab(
            profile: MockProfile(),
            isPrivate: true,
            windowUUID: .XCTestDefaultUUID,
            documentLogger: DocumentLogger(logger: MockLogger())
        )
        tabManager.privateTabs = [privateTab]
        fixture.presentationState.observePrivateTabLifecycle(in: tabManager)
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let presented = expectation(description: "Private web panel drawer presented")
        let dismissed = expectation(description: "Stale private drawer dismissed")
        drawer.onDismissed = { dismissed.fulfill() }
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        let privateSession = try XCTUnwrap(fixture.factory.sessions.first)

        tabManager.privateTabs = []
        fixture.presentationState.tabManager(
            tabManager,
            didRemoveTab: privateTab,
            isRestoring: false
        )

        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertEqual(privateSession.invalidationCount, 1)
        XCTAssertEqual(privateSession.stateObserverCount, 0)
        XCTAssertNil(privateSession.contentView?.superview)
        XCTAssertNil(fixture.presentationState.activeDrawer)
        XCTAssertEqual(fixture.factory.sessions.count, 1)
    }

    func testFailedPresentationDetachesWebPanelContentAndObserver() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        let parent = RejectingPresentationViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        XCTAssertFalse(drawer.show(from: parent))

        let session = try XCTUnwrap(fixture.factory.sessions.first)
        XCTAssertEqual(session.stateObserverCount, 0)
        XCTAssertNil(session.contentView?.superview)
        XCTAssertEqual(session.invalidationCount, 0)
        XCTAssertEqual(session.visibilityChanges, [false])
    }

    func testWindowAssociationTeardownInvalidatesAndRemovesRuntimeState() throws {
        let suiteName = "FloorpWebPanelWindowTeardownTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = NSObject()
        let windowUUID = WindowUUID()
        let state = FloorpPanelPresentationStateAssociation.state(
            for: owner,
            windowUUID: windowUUID
        )
        state.configureWebPanelRuntime(
            profile: MockProfile(),
            panelManager: FloorpPanelManager(defaults: defaults),
            openInMainBrowser: { _ in }
        )
        XCTAssertNotNil(state.webPanelSessionStore)

        FloorpPanelPresentationStateAssociation.invalidateState(for: owner)

        XCTAssertNil(state.webPanelSessionStore)
        let replacement = FloorpPanelPresentationStateAssociation.state(
            for: owner,
            windowUUID: windowUUID
        )
        XCTAssertFalse(replacement === state)
        FloorpPanelPresentationStateAssociation.invalidateState(for: owner)
    }

    func testRegularAndPrivateSessionsSurviveDrawerHideAndRemainSeparated() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }

        let regularDrawer = fixture.makeDrawer(isPrivate: false)
        regularDrawer.loadViewIfNeeded()
        let regularSession = try XCTUnwrap(fixture.factory.sessions.first)
        XCTAssertEqual(regularSession.key.isPrivate, false)
        XCTAssertEqual(regularSession.stateObserverCount, 1)
        XCTAssertEqual(
            regularSession.contentView?.superview?.accessibilityIdentifier,
            "Floorp.Drawer.WebPanelContent"
        )
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: regularDrawer.view) as? UIButton
        )
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: regularDrawer.view)
        )
        findButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(findToolbar.isHidden)

        regularDrawer.viewDidDisappear(false)
        XCTAssertEqual(regularSession.stateObserverCount, 0)
        XCTAssertNil(regularSession.contentView?.superview)
        XCTAssertNil(findToolbar.superview)
        XCTAssertEqual(regularSession.invalidationCount, 0)
        XCTAssertEqual(regularSession.visibilityChanges, [false])

        let reopenedRegularDrawer = fixture.makeDrawer(isPrivate: false)
        reopenedRegularDrawer.loadViewIfNeeded()
        XCTAssertEqual(fixture.factory.makeCallCount, 1)
        XCTAssertTrue(fixture.factory.sessions.first === regularSession)
        XCTAssertEqual(regularSession.stateObserverCount, 1)
        XCTAssertEqual(regularSession.visibilityChanges, [false, true])

        reopenedRegularDrawer.viewDidDisappear(false)
        let privateDrawer = fixture.makeDrawer(isPrivate: true)
        privateDrawer.loadViewIfNeeded()
        let privateSession = try XCTUnwrap(fixture.factory.sessions.last)
        XCTAssertEqual(fixture.factory.makeCallCount, 2)
        XCTAssertTrue(privateSession.key.isPrivate)
        XCTAssertFalse(privateSession === regularSession)
        XCTAssertNil(regularSession.contentView?.superview)
        XCTAssertEqual(
            privateSession.contentView?.superview?.accessibilityIdentifier,
            "Floorp.Drawer.WebPanelContent"
        )

        privateDrawer.viewDidDisappear(false)
        let reopenedPrivateDrawer = fixture.makeDrawer(isPrivate: true)
        reopenedPrivateDrawer.loadViewIfNeeded()
        XCTAssertEqual(fixture.factory.makeCallCount, 2)
        XCTAssertTrue(fixture.factory.sessions.last === privateSession)
        XCTAssertEqual(privateSession.invalidationCount, 0)
    }

    func testAutoUnloadRestoresLastSafeURLAfterPanelSwitchAndDrawerHide() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        _ = try fixture.manager.setAutoUnload(
            true,
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: fixture.manager.config)
        )
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        let first = try XCTUnwrap(fixture.factory.sessions.first)
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        first.recordRuntimeState(currentURL: currentURL, pageTitle: "Current")
        let builtInPanel = try XCTUnwrap(
            fixture.manager.panels.first(where: { $0.type == .bookmarks })
        )
        let builtInButton = try XCTUnwrap(
            findView(identifier: builtInPanel.id, in: drawer.view) as? UIButton
        )

        builtInButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(first.visibilityChanges, [false])
        XCTAssertEqual(first.invalidationCount, 1)
        XCTAssertEqual(fixture.presentationState.webPanelSessionStore?.cachedSessionCount, 0)

        let webPanel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let webPanelButton = try XCTUnwrap(
            findView(identifier: webPanel.id, in: drawer.view) as? UIButton
        )
        webPanelButton.sendActions(for: .touchUpInside)
        let second = try XCTUnwrap(fixture.factory.sessions.last)

        XCTAssertFalse(second === first)
        XCTAssertEqual(second.restorationURL, currentURL)
        XCTAssertEqual(fixture.factory.makeCallCount, 2)

        second.recordRuntimeState(currentURL: currentURL, pageTitle: "Restored")
        drawer.viewDidDisappear(false)
        XCTAssertEqual(second.visibilityChanges, [false])
        XCTAssertEqual(second.invalidationCount, 1)

        let reopened = fixture.makeDrawer(isPrivate: false)
        reopened.loadViewIfNeeded()
        let third = try XCTUnwrap(fixture.factory.sessions.last)
        XCTAssertFalse(third === second)
        XCTAssertEqual(third.restorationURL, currentURL)
        XCTAssertEqual(fixture.factory.makeCallCount, 3)
    }

    func testActiveExplicitUnloadDetachesRuntimeUntilSelectedAgain() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        let first = try XCTUnwrap(fixture.factory.sessions.first)
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        first.recordRuntimeState(currentURL: currentURL, pageTitle: "Current")
        let backButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Back", in: drawer.view) as? UIButton
        )
        let reloadButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.ReloadOrStop", in: drawer.view) as? UIButton
        )
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: drawer.view) as? UIButton
        )
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
        )
        XCTAssertTrue(backButton.isEnabled)
        XCTAssertTrue(reloadButton.isEnabled)
        findButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(findToolbar.isHidden)

        XCTAssertTrue(drawer.unloadActiveWebPanel())

        XCTAssertEqual(first.stateObserverCount, 0)
        XCTAssertEqual(first.invalidationCount, 1)
        XCTAssertNil(first.contentView)
        XCTAssertEqual(fixture.presentationState.webPanelSessionStore?.cachedSessionCount, 0)
        XCTAssertEqual(fixture.factory.makeCallCount, 1)
        XCTAssertFalse(backButton.isEnabled)
        XCTAssertFalse(reloadButton.isEnabled)
        XCTAssertNil(findToolbar.superview)
        XCTAssertEqual(first.findTargetMock.invalidationCount, 1)
        XCTAssertNotNil(
            findLabel(text: FloorpStrings.Drawer.webPanelUnloaded, in: drawer.view)
        )

        let webPanel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let webPanelButton = try XCTUnwrap(
            findView(identifier: webPanel.id, in: drawer.view) as? UIButton
        )
        webPanelButton.sendActions(for: .touchUpInside)

        let restored = try XCTUnwrap(fixture.factory.sessions.last)
        XCTAssertFalse(restored === first)
        XCTAssertEqual(restored.restorationURL, currentURL)
        XCTAssertEqual(restored.stateObserverCount, 1)
        XCTAssertEqual(fixture.factory.makeCallCount, 2)
        XCTAssertEqual(fixture.presentationState.webPanelSessionStore?.cachedSessionCount, 1)
        XCTAssertEqual(
            restored.contentView?.superview?.accessibilityIdentifier,
            "Floorp.Drawer.WebPanelContent"
        )
    }

    func testWebPanelToolbarTracksStateAndDispatchesCommands() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        _ = try fixture.manager.updateConfig(
            FloorpOverlayDrawerConfig(isEnabled: true, sidebarWidth: 72),
            expectedRevision: FloorpOverlayDrawerConfigRevision(
                config: fixture.manager.config
            )
        )
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        drawer.view.semanticContentAttribute = .forceRightToLeft
        drawer.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        drawer.view.layoutIfNeeded()
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let toolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Toolbar", in: drawer.view)
        )
        let webContent = try XCTUnwrap(
            findView(identifier: "Floorp.Drawer.WebPanelContent", in: drawer.view)
        )
        let backButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Back", in: drawer.view) as? UIButton
        )
        let forwardButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Forward", in: drawer.view) as? UIButton
        )
        let reloadButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.ReloadOrStop", in: drawer.view) as? UIButton
        )
        let homeButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Home", in: drawer.view) as? UIButton
        )
        let openButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.OpenInMainBrowser", in: drawer.view) as? UIButton
        )

        XCTAssertFalse(toolbar.isHidden)
        XCTAssertEqual(webContent.frame.minY, toolbar.frame.maxY, accuracy: 0.5)
        XCTAssertFalse(toolbar.hasAmbiguousLayout)
        for button in [backButton, forwardButton, reloadButton, homeButton, openButton] {
            XCTAssertEqual(button.bounds.width, 44, accuracy: 0.5)
            XCTAssertEqual(button.bounds.height, 44, accuracy: 0.5)
        }
        let toolbarScrollView = try XCTUnwrap(toolbar.subviews.first as? UIScrollView)
        XCTAssertGreaterThan(toolbarScrollView.contentSize.width, toolbarScrollView.bounds.width)
        XCTAssertFalse(backButton.isEnabled)
        XCTAssertFalse(forwardButton.isEnabled)
        XCTAssertFalse(reloadButton.isEnabled)
        XCTAssertTrue(homeButton.isEnabled)
        XCTAssertFalse(openButton.isEnabled)

        homeButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(session.reloadCallCount, 0)
        XCTAssertEqual(session.loadHomeCallCount, 1)

        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        session.recordRuntimeState(
            currentURL: currentURL,
            pageTitle: "Current",
            canGoBack: true,
            canGoForward: true,
            isLoading: true
        )

        XCTAssertTrue(backButton.isEnabled)
        XCTAssertTrue(forwardButton.isEnabled)
        XCTAssertTrue(openButton.isEnabled)
        XCTAssertEqual(
            reloadButton.accessibilityLabel,
            FloorpStrings.Drawer.webPanelStopLoading
        )

        backButton.sendActions(for: .touchUpInside)
        forwardButton.sendActions(for: .touchUpInside)
        reloadButton.sendActions(for: .touchUpInside)
        openButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(session.goBackCallCount, 1)
        XCTAssertEqual(session.goForwardCallCount, 1)
        XCTAssertEqual(session.stopLoadingCallCount, 1)
        XCTAssertEqual(session.openInMainBrowserCallCount, 1)

        session.recordRuntimeState(
            currentURL: currentURL,
            pageTitle: "Current",
            isLoading: false
        )
        XCTAssertEqual(reloadButton.accessibilityLabel, FloorpStrings.Drawer.webPanelReload)
        reloadButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(session.reloadCallCount, 1)

        let builtInPanel = try XCTUnwrap(
            fixture.manager.panels.first(where: { $0.type == .bookmarks })
        )
        let builtInButton = try XCTUnwrap(
            findView(identifier: builtInPanel.id, in: drawer.view) as? UIButton
        )
        builtInButton.sendActions(for: .touchUpInside)
        drawer.view.layoutIfNeeded()
        XCTAssertTrue(toolbar.isHidden)
        XCTAssertEqual(toolbar.bounds.height, 0, accuracy: 0.5)
        XCTAssertEqual(session.visibilityChanges, [false])
        XCTAssertEqual(session.invalidationCount, 0)

        let webPanel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let webPanelButton = try XCTUnwrap(
            findView(identifier: webPanel.id, in: drawer.view) as? UIButton
        )
        webPanelButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(fixture.factory.makeCallCount, 1)
        XCTAssertTrue(fixture.factory.sessions.first === session)
        XCTAssertEqual(session.state.currentURL, currentURL)
        XCTAssertEqual(session.visibilityChanges, [false, true])
    }

    func testFindToolbarIsDiscoverableAndClearsWhenSwitchingPanels() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        drawer.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        drawer.view.layoutIfNeeded()
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: drawer.view) as? UIButton
        )
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
        )
        let webContent = try XCTUnwrap(
            findView(identifier: "Floorp.Drawer.WebPanelContent", in: drawer.view)
        )

        XCTAssertTrue(findButton.isEnabled)
        XCTAssertTrue(findToolbar.isHidden)
        let keyCommands = try XCTUnwrap(drawer.keyCommands)
        XCTAssertTrue(keyCommands.contains {
            $0.input == "f" && $0.modifierFlags == .command
        })
        XCTAssertTrue(keyCommands.contains {
            $0.input == "g" && $0.modifierFlags == .command
        })
        XCTAssertTrue(keyCommands.contains {
            $0.input == "g" && $0.modifierFlags == [.command, .shift]
        })
        findButton.sendActions(for: .touchUpInside)
        drawer.view.layoutIfNeeded()

        XCTAssertFalse(findToolbar.isHidden)
        XCTAssertLessThanOrEqual(
            findToolbar.frame.maxY,
            webContent.safeAreaLayoutGuide.layoutFrame.maxY + 0.5
        )
        XCTAssertTrue(drawer.accessibilityPerformEscape())
        XCTAssertTrue(findToolbar.isHidden)
        findButton.sendActions(for: .touchUpInside)
        let queryField = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Query", in: drawer.view) as? UITextField
        )
        queryField.text = "ephemeral"
        queryField.sendActions(for: .editingChanged)
        XCTAssertEqual(session.findTargetMock.requests.map(\.query), ["ephemeral"])

        let builtInPanel = try XCTUnwrap(
            fixture.manager.panels.first(where: { $0.type == .bookmarks })
        )
        let builtInButton = try XCTUnwrap(
            findView(identifier: builtInPanel.id, in: drawer.view) as? UIButton
        )
        builtInButton.sendActions(for: .touchUpInside)

        XCTAssertNil(findToolbar.superview)
        XCTAssertGreaterThanOrEqual(session.findTargetMock.endSessionCount, 1)
        let builtInKeyCommands = try XCTUnwrap(drawer.keyCommands)
        XCTAssertFalse(builtInKeyCommands.contains {
            $0.input == "f" && $0.modifierFlags.contains(.command)
        })
        XCTAssertFalse(builtInKeyCommands.contains {
            $0.input == "g" && $0.modifierFlags.contains(.command)
        })
    }

    func testOpenInMainBrowserDismissesDrawerAndPreservesSessionForReopen() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
            window.rootViewController = nil
        }

        let drawer = fixture.makeDrawer(isPrivate: false)
        let presented = expectation(description: "Web panel drawer presented")
        let dismissed = expectation(description: "Web panel drawer dismissed after open")
        drawer.onDismissed = { dismissed.fulfill() }
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        session.recordRuntimeState(currentURL: currentURL, pageTitle: "Current")
        let openButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.OpenInMainBrowser", in: drawer.view) as? UIButton
        )

        openButton.sendActions(for: .touchUpInside)
        await fulfillment(of: [dismissed], timeout: 1)

        XCTAssertEqual(session.openInMainBrowserCallCount, 1)
        XCTAssertEqual(session.stateObserverCount, 0)
        XCTAssertNil(session.contentView?.superview)
        XCTAssertEqual(session.invalidationCount, 0)
        XCTAssertNil(fixture.presentationState.activeDrawer)

        let replacement = fixture.makeDrawer(isPrivate: false)
        let replacementPresented = expectation(description: "Replacement web panel drawer presented")
        let replacementDismissed = expectation(description: "Replacement web panel drawer dismissed")
        replacement.onDismissed = { replacementDismissed.fulfill() }
        XCTAssertTrue(replacement.show(from: parent) { replacementPresented.fulfill() })
        await fulfillment(of: [replacementPresented], timeout: 1)
        XCTAssertEqual(fixture.factory.makeCallCount, 1)
        XCTAssertTrue(fixture.factory.sessions.first === session)
        XCTAssertEqual(session.state.currentURL, currentURL)
        XCTAssertEqual(session.stateObserverCount, 1)

        replacement.dismissDrawer()
        await fulfillment(of: [replacementDismissed], timeout: 1)
    }

    func testWindowRuntimeTeardownPurgesEveryPrivacyModeAndDetachesContent() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }

        let regularDrawer = fixture.makeDrawer(isPrivate: false)
        regularDrawer.loadViewIfNeeded()
        regularDrawer.viewDidDisappear(false)
        let privateDrawer = fixture.makeDrawer(isPrivate: true)
        privateDrawer.loadViewIfNeeded()
        XCTAssertTrue(fixture.presentationState.attach(privateDrawer))
        let sessions = fixture.factory.sessions
        XCTAssertEqual(sessions.count, 2)
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: privateDrawer.view) as? UIButton
        )
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: privateDrawer.view)
        )
        findButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(findToolbar.isHidden)

        fixture.presentationState.invalidateWebPanelRuntime()

        XCTAssertNil(fixture.presentationState.webPanelSessionStore)
        XCTAssertNil(findToolbar.superview)
        XCTAssertTrue(sessions.allSatisfy { $0.invalidationCount == 1 })
        XCTAssertTrue(sessions.allSatisfy { $0.contentView?.superview == nil })
        XCTAssertTrue(sessions.allSatisfy { $0.stateObserverCount == 0 })
    }

    private func makeDrawerFixture() throws -> FloorpWebPanelDrawerFixture {
        let suiteName = "FloorpWebPanelDrawerRuntimeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let manager = FloorpPanelManager(defaults: defaults)
        let webPanel = try manager.addWebPanel(
            draft: FloorpWebPanelDraft(title: "Portal", urlText: "https://example.com/panel")
        )
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(
            windowUUID: .XCTestDefaultUUID,
            factory: factory
        )
        let presentationState = FloorpPanelPresentationState(
            windowUUID: .XCTestDefaultUUID,
            selectedPanelId: webPanel.id,
            webPanelSessionStore: store
        )
        return FloorpWebPanelDrawerFixture(
            suiteName: suiteName,
            defaults: defaults,
            manager: manager,
            presentationState: presentationState,
            factory: factory
        )
    }

    private func makeTab(isPrivate: Bool) -> Tab {
        Tab(
            profile: MockProfile(),
            isPrivate: isPrivate,
            windowUUID: .XCTestDefaultUUID,
            documentLogger: DocumentLogger(logger: MockLogger())
        )
    }

    private func present(
        drawer: FloorpOverlayDrawerViewController
    ) async throws -> FloorpDrawerPresentationFixture {
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let presented = expectation(description: "Web panel drawer presented")
        guard drawer.show(from: parent, onPresented: { presented.fulfill() }) else {
            window.isHidden = true
            window.rootViewController = nil
            throw FloorpDrawerPresentationFixture.PresentationError.rejected
        }
        await fulfillment(of: [presented], timeout: 1)
        return FloorpDrawerPresentationFixture(parent: parent, window: window)
    }

    private func findView(identifier: String, in rootView: UIView) -> UIView? {
        if rootView.accessibilityIdentifier == identifier {
            return rootView
        }
        for subview in rootView.subviews {
            if let match = findView(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func findLabel(text: String, in rootView: UIView) -> UILabel? {
        if let label = rootView as? UILabel, label.text == text {
            return label
        }
        for subview in rootView.subviews {
            if let match = findLabel(text: text, in: subview) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private struct FloorpDrawerPresentationFixture {
    enum PresentationError: Error {
        case rejected
    }

    let parent: UIViewController
    let window: UIWindow

    func cleanup() {
        parent.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private final class RejectingPresentationViewController: UIViewController {
    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        // Simulates UIKit rejecting a late presentation during a transition.
    }
}

final class FloorpWebPanelNavigationPolicyTests: XCTestCase {
    func testAllowsSafeHTTPAndHTTPSInExistingFrames() throws {
        let urls = [
            try XCTUnwrap(URL(string: "http://localhost:8080/path")),
            try XCTUnwrap(URL(string: "https://example.com/path?q=1#section")),
            try XCTUnwrap(URL(string: "HTTPS://[2001:db8::1]:65535/path")),
        ]

        for target in [FloorpWebPanelNavigationTarget.mainFrame, .subframe] {
            for url in urls {
                XCTAssertEqual(decision(for: url, target: target), .allow)
            }
        }
    }

    func testRoutesSafeNewWindowsToTheMainBrowser() throws {
        let urls = [
            try XCTUnwrap(URL(string: "http://example.com/popup")),
            try XCTUnwrap(URL(string: "https://floorp.app/popup")),
        ]

        for url in urls {
            XCTAssertEqual(decision(for: url, target: .newWindow), .openInMainBrowser(url))
        }
    }

    func testAllowsOnlyExactAboutBlankInExistingFrames() throws {
        let exactValues = ["about:blank", "ABOUT:BLANK"]
        for value in exactValues {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(decision(for: url, target: .mainFrame), .allow)
            XCTAssertEqual(decision(for: url, target: .subframe), .allow)
            XCTAssertEqual(decision(for: url, target: .newWindow), .cancel)
        }

        let extendedValues = ["about:blank?query", "about:blank#fragment", "about:blank/path"]
        for value in extendedValues {
            let url = try XCTUnwrap(URL(string: value))
            for target in FloorpWebPanelNavigationTarget.allCases {
                XCTAssertEqual(decision(for: url, target: target), .cancel)
            }
        }
    }

    func testRejectsDangerousSchemesForEveryTarget() throws {
        let values = [
            "about:config",
            "blob:https://example.com/id",
            "data:text/plain,panel",
            "file:///tmp/panel",
            "floorp://notes",
            "internal://local/page",
            "javascript:alert(1)",
        ]

        for value in values {
            let url = try XCTUnwrap(URL(string: value))
            for target in FloorpWebPanelNavigationTarget.allCases {
                XCTAssertEqual(decision(for: url, target: target), .cancel, "Expected rejection for \(value)")
            }
        }
    }

    func testRejectsUnsafeHTTPURLsForEveryTarget() {
        let values = [
            "http://",
            "https:///path-only",
            "https://example.com:",
            "https://example.com:0/path",
            "https://example.com:65536/path",
            "https://user:secret@example.com/path",
        ]

        for value in values {
            for target in FloorpWebPanelNavigationTarget.allCases {
                XCTAssertEqual(
                    decision(for: URL(string: value), target: target),
                    .cancel,
                    "Expected rejection for \(value)"
                )
            }
        }
    }

    func testRejectsMissingURLForEveryTarget() {
        for target in FloorpWebPanelNavigationTarget.allCases {
            XCTAssertEqual(decision(for: nil, target: target), .cancel)
        }
    }

    private func decision(
        for url: URL?,
        target: FloorpWebPanelNavigationTarget
    ) -> FloorpWebPanelNavigationDecision {
        FloorpWebPanelNavigationPolicy.decision(
            for: FloorpWebPanelNavigationRequest(url: url, target: target)
        )
    }
}

@MainActor
private final class MockFloorpWebPanelFindTimeoutScheduler:
    FloorpWebPanelFindTimeoutScheduling {
    private(set) var scheduledDelays = [UInt64]()
    private var handlers = [FloorpWebPanelFindTimeoutHandler]()

    func schedule(
        after nanoseconds: UInt64,
        handler: @escaping FloorpWebPanelFindTimeoutHandler
    ) -> Task<Void, Never> {
        scheduledDelays.append(nanoseconds)
        handlers.append(handler)
        return Task {}
    }

    func fireNext() {
        guard !handlers.isEmpty else { return }
        handlers.removeFirst()()
    }
}

@MainActor
private final class MockFloorpWebPanelFindTarget: FloorpWebPanelFindTarget {
    let supportsNativeFindInteraction: Bool
    private(set) var nativePresentationCount = 0
    private(set) var nativeNextCount = 0
    private(set) var nativePreviousCount = 0
    private(set) var endSessionCount = 0
    private(set) var invalidationCount = 0
    private(set) var requests = [FloorpWebPanelFindRequest]()
    private var completions = [FloorpWebPanelFindCompletion]()

    var pendingCompletionCount: Int {
        completions.count
    }

    init(supportsNativeFindInteraction: Bool = false) {
        self.supportsNativeFindInteraction = supportsNativeFindInteraction
    }

    func presentNativeFindNavigator() -> Bool {
        nativePresentationCount += 1
        return supportsNativeFindInteraction
    }

    func findNextUsingNativeInteraction() {
        nativeNextCount += 1
    }

    func findPreviousUsingNativeInteraction() {
        nativePreviousCount += 1
    }

    func find(
        _ request: FloorpWebPanelFindRequest,
        completion: @escaping FloorpWebPanelFindCompletion
    ) {
        requests.append(request)
        completions.append(completion)
    }

    func endFindSession() {
        endSessionCount += 1
    }

    func invalidate() {
        invalidationCount += 1
        endFindSession()
    }

    func completeNext(matchFound: Bool) {
        guard !completions.isEmpty else { return }
        completions.removeFirst()(matchFound)
    }
}

@MainActor
private final class MockFloorpWebPanelSession: FloorpWebPanelSessionProtocol {
    let key: FloorpWebPanelSessionKey
    let restorationURL: URL?
    private(set) var state: FloorpWebPanelSessionState
    private(set) var configurationUpdateCount = 0
    private(set) var invalidationCount = 0
    private(set) var loadHomeCallCount = 0
    private(set) var goBackCallCount = 0
    private(set) var goForwardCallCount = 0
    private(set) var reloadCallCount = 0
    private(set) var stopLoadingCallCount = 0
    private(set) var openInMainBrowserCallCount = 0
    private(set) var visibilityChanges = [Bool]()
    private let hostedContentView = UIView()
    private var stateObservers = [UUID: @MainActor (FloorpWebPanelSessionState) -> Void]()
    private var isVisible = true
    private var latestRuntimeURL: URL?
    private var hasLatestRuntimeURL = false
    private var pendingRestorationCandidateURL: URL?
    let findTargetMock = MockFloorpWebPanelFindTarget()

    var contentView: UIView? { invalidationCount == 0 ? hostedContentView : nil }
    var findTarget: (any FloorpWebPanelFindTarget)? {
        invalidationCount == 0 ? findTargetMock : nil
    }
    var stateObserverCount: Int { stateObservers.count }

    init(
        key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration,
        restorationURL: URL?
    ) {
        self.key = key
        self.restorationURL = restorationURL
        self.state = FloorpWebPanelSessionState(configuration: configuration)
        self.pendingRestorationCandidateURL = restorationURL
    }

    func updateConfiguration(_ configuration: FloorpWebPanelSessionConfiguration) {
        state.configuration = configuration
        configurationUpdateCount += 1
        notifyStateObservers()
    }

    func addStateObserver(
        _ observer: @escaping @MainActor (FloorpWebPanelSessionState) -> Void
    ) -> UUID? {
        let identifier = UUID()
        stateObservers[identifier] = observer
        observer(state)
        return identifier
    }

    func removeStateObserver(_ identifier: UUID) {
        stateObservers.removeValue(forKey: identifier)
    }

    func invalidate() {
        invalidationCount += 1
        findTargetMock.invalidate()
        stateObservers.removeAll()
        hostedContentView.removeFromSuperview()
    }

    func loadHome() {
        loadHomeCallCount += 1
    }

    func goBack() {
        goBackCallCount += 1
    }

    func goForward() {
        goForwardCallCount += 1
    }

    func reload() {
        reloadCallCount += 1
    }

    func stopLoading() {
        stopLoadingCallCount += 1
    }

    func openCurrentPageInMainBrowser() {
        openInMainBrowserCallCount += 1
    }

    func setVisible(_ isVisible: Bool) {
        guard self.isVisible != isVisible else { return }
        self.isVisible = isVisible
        visibilityChanges.append(isVisible)
        if !isVisible {
            findTargetMock.endFindSession()
        }
    }

    func restorationURLForUnload() -> URL? {
        if hasLatestRuntimeURL {
            return FloorpWebPanelRestorationPolicy.safeWebURL(latestRuntimeURL)
        }
        if let pendingRestorationCandidateURL {
            return FloorpWebPanelRestorationPolicy.safeWebURL(pendingRestorationCandidateURL)
        }
        return FloorpWebPanelRestorationPolicy.safeWebURL(state.currentURL)
    }

    func setLatestRuntimeURLForRestoration(_ url: URL?) {
        latestRuntimeURL = url
        hasLatestRuntimeURL = true
        pendingRestorationCandidateURL = nil
    }

    func recordRuntimeState(
        currentURL: URL,
        pageTitle: String,
        canGoBack: Bool = true,
        canGoForward: Bool = false,
        isLoading: Bool = true
    ) {
        setLatestRuntimeURLForRestoration(currentURL)
        state.currentURL = currentURL
        state.pageTitle = pageTitle
        state.canGoBack = canGoBack
        state.canGoForward = canGoForward
        state.isLoading = isLoading
        state.estimatedProgress = 0.5
        notifyStateObservers()
    }

    private func notifyStateObservers() {
        let currentState = state
        Array(stateObservers.values).forEach { $0(currentState) }
    }
}

@MainActor
private struct FloorpWebPanelDrawerFixture {
    let suiteName: String
    let defaults: UserDefaults
    let manager: FloorpPanelManager
    let presentationState: FloorpPanelPresentationState
    let factory: MockFloorpWebPanelSessionFactory

    func makeDrawer(isPrivate: Bool) -> FloorpOverlayDrawerViewController {
        makeDrawer(isPrivateProvider: { isPrivate })
    }

    func makeDrawer(
        isPrivateProvider: @escaping @MainActor () -> Bool
    ) -> FloorpOverlayDrawerViewController {
        FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: .shared,
            presentationState: presentationState,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            isPrivateProvider: isPrivateProvider
        )
    }

    func cleanup() {
        presentationState.invalidateWebPanelRuntime()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class MockFloorpWebPanelSessionFactory: FloorpWebPanelSessionFactory {
    enum ExpectedError: Error {
        case failure
    }

    private(set) var sessions = [MockFloorpWebPanelSession]()
    private(set) var makeCallCount = 0
    var errorToThrow: Error?
    var keyOverride: FloorpWebPanelSessionKey?

    func makeSession(
        for key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration,
        restorationURL: URL?
    ) throws -> any FloorpWebPanelSessionProtocol {
        makeCallCount += 1
        if let errorToThrow {
            throw errorToThrow
        }
        let session = MockFloorpWebPanelSession(
            key: keyOverride ?? key,
            configuration: configuration,
            restorationURL: restorationURL
        )
        sessions.append(session)
        return session
    }
}
