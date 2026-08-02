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

    func testMuteHideAndUnloadAPIsAreWindowScopedAndIdempotent() throws {
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

        XCTAssertFalse(firstStore.setAudioMuted(true, for: second.key))
        XCTAssertFalse(firstStore.unloadSession(for: second.key))
        XCTAssertFalse(firstStore.hideSession(second, autoUnload: true))
        XCTAssertFalse(second.isAudioMuted)
        XCTAssertEqual(second.invalidationCount, 0)

        XCTAssertTrue(firstStore.setAudioMuted(true, for: first.key))
        XCTAssertTrue(firstStore.setAudioMuted(true, for: first.key))
        XCTAssertTrue(first.isAudioMuted)
        XCTAssertEqual(first.audioMuteChanges, [true])
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
        XCTAssertNil(replacementBeforeCommit.restorationURL)
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
private final class FloorpMutablePrivacyState {
    var isPrivate: Bool

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
    }
}

@MainActor
final class FloorpWebPanelDrawerRuntimeTests: XCTestCase {
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

        privacyState.isPrivate = false
        tabManager.privateTabs = []
        fixture.presentationState.tabManager(
            tabManager,
            didRemoveTab: privateTab,
            isRestoring: false
        )

        XCTAssertEqual(privateSession.invalidationCount, 1)
        XCTAssertEqual(privateSession.stateObserverCount, 0)
        XCTAssertNil(privateSession.contentView?.superview)
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

        regularDrawer.viewDidDisappear(false)
        XCTAssertEqual(regularSession.stateObserverCount, 0)
        XCTAssertNil(regularSession.contentView?.superview)
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
        XCTAssertTrue(backButton.isEnabled)
        XCTAssertTrue(reloadButton.isEnabled)

        XCTAssertTrue(drawer.unloadActiveWebPanel())

        XCTAssertEqual(first.stateObserverCount, 0)
        XCTAssertEqual(first.invalidationCount, 1)
        XCTAssertNil(first.contentView)
        XCTAssertEqual(fixture.presentationState.webPanelSessionStore?.cachedSessionCount, 0)
        XCTAssertEqual(fixture.factory.makeCallCount, 1)
        XCTAssertFalse(backButton.isEnabled)
        XCTAssertFalse(reloadButton.isEnabled)
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
        let sessions = fixture.factory.sessions
        XCTAssertEqual(sessions.count, 2)

        fixture.presentationState.invalidateWebPanelRuntime()

        XCTAssertNil(fixture.presentationState.webPanelSessionStore)
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
    private(set) var audioMuteChanges = [Bool]()
    private(set) var isAudioMuted = false
    private let hostedContentView = UIView()
    private var stateObservers = [UUID: @MainActor (FloorpWebPanelSessionState) -> Void]()
    private var isVisible = true

    var contentView: UIView? { invalidationCount == 0 ? hostedContentView : nil }
    var stateObserverCount: Int { stateObservers.count }

    init(
        key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration,
        restorationURL: URL?
    ) {
        self.key = key
        self.restorationURL = restorationURL
        self.state = FloorpWebPanelSessionState(configuration: configuration)
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
    }

    func setAudioMuted(_ isMuted: Bool) {
        guard isAudioMuted != isMuted else { return }
        isAudioMuted = isMuted
        audioMuteChanges.append(isMuted)
    }

    func recordRuntimeState(
        currentURL: URL,
        pageTitle: String,
        canGoBack: Bool = true,
        canGoForward: Bool = false,
        isLoading: Bool = true
    ) {
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
