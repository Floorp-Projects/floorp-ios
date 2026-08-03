// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Shared
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

    func testZoomConfigurationUpdatesCachedPrivacySessionsAndSurvivesUnload() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        var panel = makePanel(id: "zoomed")
        panel.webPreferences = FloorpWebPanelPreferences(
            zoomLevel: .oneHundredTwentyFivePercent
        )
        let regular = try mockSession(from: store.session(for: panel, isPrivate: false))
        let privateSession = try mockSession(from: store.session(for: panel, isPrivate: true))

        XCTAssertEqual(regular.state.configuration.zoomLevel, .oneHundredTwentyFivePercent)
        XCTAssertEqual(privateSession.state.configuration.zoomLevel, .oneHundredTwentyFivePercent)

        store.updateZoomLevel(.oneHundredFiftyPercent, for: panel.id)
        store.updateZoomLevel(.oneHundredFiftyPercent, for: panel.id)

        XCTAssertEqual(regular.state.configuration.zoomLevel, .oneHundredFiftyPercent)
        XCTAssertEqual(privateSession.state.configuration.zoomLevel, .oneHundredFiftyPercent)
        XCTAssertEqual(regular.configurationUpdateCount, 1)
        XCTAssertEqual(privateSession.configurationUpdateCount, 1)
        XCTAssertEqual(factory.makeCallCount, 2)

        XCTAssertTrue(store.unloadSession(for: regular.key))
        panel.webPreferences = FloorpWebPanelPreferences(
            revision: 1,
            zoomLevel: .oneHundredSeventyFivePercent
        )
        store.reconcile(with: [panel])
        let replacement = try mockSession(from: store.session(for: panel, isPrivate: false))

        XCTAssertFalse(replacement === regular)
        XCTAssertTrue(try store.session(for: panel, isPrivate: true) === privateSession)
        XCTAssertEqual(replacement.state.configuration.zoomLevel, .oneHundredSeventyFivePercent)
        XCTAssertEqual(privateSession.state.configuration.zoomLevel, .oneHundredSeventyFivePercent)
    }

    func testContentModeUpdatesCachedPrivacySessionsAndSurvivesUnload() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        var panel = makePanel(id: "content-mode")
        panel.webPreferences = FloorpWebPanelPreferences(contentMode: .mobile)
        let regular = try mockSession(from: store.session(for: panel, isPrivate: false))
        let privateSession = try mockSession(from: store.session(for: panel, isPrivate: true))

        store.updateContentMode(.desktop, for: panel.id)
        store.updateContentMode(.desktop, for: panel.id)

        XCTAssertEqual(regular.state.configuration.contentMode, .desktop)
        XCTAssertEqual(privateSession.state.configuration.contentMode, .desktop)
        XCTAssertEqual(regular.configurationUpdateCount, 1)
        XCTAssertEqual(privateSession.configurationUpdateCount, 1)
        XCTAssertEqual(factory.makeCallCount, 2)

        XCTAssertTrue(store.unloadSession(for: regular.key))
        panel.webPreferences = FloorpWebPanelPreferences(
            revision: 1,
            contentMode: .desktop
        )
        let replacement = try mockSession(from: store.session(for: panel, isPrivate: false))

        XCTAssertFalse(replacement === regular)
        XCTAssertEqual(replacement.state.configuration.contentMode, .desktop)
        XCTAssertEqual(privateSession.state.configuration.contentMode, .desktop)
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
        let privateSession = try XCTUnwrap(
            try firstStore.session(for: panel, isPrivate: true)
                as? MockFloorpWebPanelSession
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

    func testMemoryPressureEvictsOnlyInactiveSessionsAndRestoresSafeLatestURLs() throws {
        let factory = MockFloorpWebPanelSessionFactory()
        let store = FloorpWebPanelSessionStore(windowUUID: WindowUUID(), factory: factory)
        let active = try mockSession(
            from: store.session(for: makePanel(id: "active"), isPrivate: false)
        )
        let activePrivate = try mockSession(
            from: store.session(for: makePanel(id: "active-private"), isPrivate: true)
        )
        let hiddenPanel = makePanel(id: "hidden")
        let hidden = try mockSession(from: store.session(for: hiddenPanel, isPrivate: false))
        let privatePanel = makePanel(id: "private")
        let hiddenPrivate = try mockSession(
            from: store.session(for: privatePanel, isPrivate: true)
        )
        let safeURL = try XCTUnwrap(URL(string: "https://example.com/latest-safe"))
        hidden.setLatestRuntimeURLForRestoration(safeURL)
        hiddenPrivate.recordRuntimeState(
            currentURL: try XCTUnwrap(URL(string: "https://example.com/stale-safe")),
            pageTitle: "Stale"
        )
        hiddenPrivate.setLatestRuntimeURLForRestoration(
            try XCTUnwrap(URL(string: "javascript:alert(1)"))
        )
        XCTAssertTrue(store.hideSession(hidden, autoUnload: false))
        XCTAssertTrue(store.hideSession(hiddenPrivate, autoUnload: false))

        let evicted = store.evictInactiveSessionsForMemoryPressure()

        XCTAssertEqual(evicted, [hidden.key, hiddenPrivate.key])
        XCTAssertEqual(active.invalidationCount, 0)
        XCTAssertEqual(activePrivate.invalidationCount, 0)
        XCTAssertEqual(hidden.invalidationCount, 1)
        XCTAssertEqual(hiddenPrivate.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionKeys, [active.key, activePrivate.key])
        XCTAssertTrue(store.evictInactiveSessionsForMemoryPressure().isEmpty)

        let restored = try mockSession(
            from: store.session(for: hiddenPanel, isPrivate: false)
        )
        let restoredPrivate = try mockSession(
            from: store.session(for: privatePanel, isPrivate: true)
        )
        XCTAssertEqual(restored.restorationURL, safeURL)
        XCTAssertNil(restoredPrivate.restorationURL)
    }

    func testMemoryPressureEvictionDoesNotMixWindowStores() throws {
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
        let first = try mockSession(from: firstStore.session(for: panel, isPrivate: false))
        let second = try mockSession(from: secondStore.session(for: panel, isPrivate: false))
        XCTAssertTrue(firstStore.hideSession(first, autoUnload: false))
        XCTAssertTrue(secondStore.hideSession(second, autoUnload: false))

        XCTAssertEqual(firstStore.evictInactiveSessionsForMemoryPressure(), [first.key])

        XCTAssertEqual(first.invalidationCount, 1)
        XCTAssertEqual(second.invalidationCount, 0)
        XCTAssertTrue(firstStore.cachedSessionKeys.isEmpty)
        XCTAssertEqual(secondStore.cachedSessionKeys, [second.key])
    }

    func testMemoryPressureDoesNotDoubleUnloadAutoUnloadedSession() throws {
        let store = FloorpWebPanelSessionStore(
            windowUUID: WindowUUID(),
            factory: MockFloorpWebPanelSessionFactory()
        )
        let session = try mockSession(
            from: store.session(for: makePanel(id: "auto-unload"), isPrivate: false)
        )

        XCTAssertTrue(store.hideSession(session, autoUnload: true))
        XCTAssertTrue(store.evictInactiveSessionsForMemoryPressure().isEmpty)
        XCTAssertEqual(session.invalidationCount, 1)
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
        XCTAssertTrue(store.hideSession(second, autoUnload: false))
        let third = try mockSession(from: store.session(for: thirdPanel, isPrivate: false))

        XCTAssertEqual(first.invalidationCount, 0)
        XCTAssertEqual(second.invalidationCount, 1)
        XCTAssertEqual(third.invalidationCount, 0)
        XCTAssertEqual(store.cachedSessionKeys.map(\.panelID).sorted(), ["first", "third"])
    }

    func testRegularLRUAllowsVisibleOverflowUntilASessionIsHidden() throws {
        let store = FloorpWebPanelSessionStore(
            windowUUID: WindowUUID(),
            regularSessionLimit: 2,
            factory: MockFloorpWebPanelSessionFactory()
        )
        let first = try mockSession(
            from: store.session(for: makePanel(id: "first"), isPrivate: false)
        )
        let second = try mockSession(
            from: store.session(for: makePanel(id: "second"), isPrivate: false)
        )
        let third = try mockSession(
            from: store.session(for: makePanel(id: "third"), isPrivate: false)
        )

        XCTAssertEqual(store.cachedSessionCount, 3)
        XCTAssertEqual(first.invalidationCount, 0)
        XCTAssertEqual(second.invalidationCount, 0)
        XCTAssertEqual(third.invalidationCount, 0)

        XCTAssertTrue(store.hideSession(second, autoUnload: false))

        XCTAssertEqual(second.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionKeys, [first.key, third.key])
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

        XCTAssertTrue(store.hideSession(regular, autoUnload: false))
        _ = try store.session(for: nextRegularPanel, isPrivate: false)

        XCTAssertEqual(regular.invalidationCount, 1)
        XCTAssertEqual(privateSession.invalidationCount, 0)
        XCTAssertEqual(store.cachedSessionCount, 2)
        XCTAssertTrue(store.cachedSessionKeys.contains(privateSession.key))
    }

    func testMemoryWarningObservationIsIdempotentAndPreservesExplicitUnloadMarkers() throws {
        let notificationCenter = FloorpMemoryPressureNotificationCenter()
        let windowUUID = WindowUUID()
        let store = FloorpWebPanelSessionStore(
            windowUUID: windowUUID,
            factory: MockFloorpWebPanelSessionFactory()
        )
        let active = try mockSession(
            from: store.session(for: makePanel(id: "active"), isPrivate: false)
        )
        let hidden = try mockSession(
            from: store.session(for: makePanel(id: "hidden"), isPrivate: false)
        )
        XCTAssertTrue(store.hideSession(hidden, autoUnload: false))
        let state = FloorpPanelPresentationState(
            windowUUID: windowUUID,
            webPanelSessionStore: store,
            notificationCenter: notificationCenter
        )
        let explicitlyUnloadedKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: "explicitly-unloaded",
            isPrivate: false
        )
        XCTAssertTrue(state.markWebPanelExplicitlyUnloaded(explicitlyUnloadedKey))

        state.configureWebPanelRuntime(profile: MockProfile(), openInMainBrowser: { _ in })
        state.configureWebPanelRuntime(profile: MockProfile(), openInMainBrowser: { _ in })

        XCTAssertEqual(
            notificationCenter.addedNames.filter {
                $0 == UIApplication.didReceiveMemoryWarningNotification
            }.count,
            1
        )
        XCTAssertEqual(
            notificationCenter.addedNames.filter { $0 == .FloorpPanelRegistryDidChange }.count,
            1
        )

        notificationCenter.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            withObject: nil,
            withUserInfo: nil
        )

        XCTAssertEqual(active.invalidationCount, 0)
        XCTAssertEqual(hidden.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionKeys, [active.key])
        XCTAssertTrue(state.isWebPanelExplicitlyUnloaded(explicitlyUnloadedKey))

        state.invalidateWebPanelRuntime()

        XCTAssertEqual(
            notificationCenter.removedNames,
            [.FloorpPanelRegistryDidChange, UIApplication.didReceiveMemoryWarningNotification]
        )
        XCTAssertFalse(state.isWebPanelExplicitlyUnloaded(explicitlyUnloadedKey))
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

    func testExplicitUnloadMarkersAreExactAndRuntimeInvalidationClearsThem() {
        let windowUUID = WindowUUID()
        let state = FloorpPanelPresentationState(windowUUID: windowUUID)
        let regularKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: "portal",
            isPrivate: false
        )
        let privateKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: "portal",
            isPrivate: true
        )
        let otherPanelKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: "other",
            isPrivate: false
        )
        let foreignWindowKey = FloorpWebPanelSessionKey(
            windowUUID: WindowUUID(),
            panelID: "portal",
            isPrivate: false
        )

        XCTAssertTrue(state.markWebPanelExplicitlyUnloaded(regularKey))
        XCTAssertTrue(state.markWebPanelExplicitlyUnloaded(privateKey))
        XCTAssertTrue(state.markWebPanelExplicitlyUnloaded(otherPanelKey))
        XCTAssertFalse(state.markWebPanelExplicitlyUnloaded(foreignWindowKey))
        XCTAssertFalse(state.markWebPanelExplicitlyUnloaded(regularKey))
        XCTAssertTrue(state.isWebPanelExplicitlyUnloaded(regularKey))
        XCTAssertTrue(state.isWebPanelExplicitlyUnloaded(privateKey))
        XCTAssertTrue(state.isWebPanelExplicitlyUnloaded(otherPanelKey))
        XCTAssertFalse(state.isWebPanelExplicitlyUnloaded(foreignWindowKey))

        XCTAssertTrue(state.clearWebPanelExplicitlyUnloaded(regularKey))
        XCTAssertFalse(state.clearWebPanelExplicitlyUnloaded(regularKey))
        XCTAssertTrue(state.isWebPanelExplicitlyUnloaded(privateKey))
        XCTAssertTrue(state.isWebPanelExplicitlyUnloaded(otherPanelKey))

        state.invalidateWebPanelRuntime()

        XCTAssertFalse(state.isWebPanelExplicitlyUnloaded(privateKey))
        XCTAssertFalse(state.isWebPanelExplicitlyUnloaded(otherPanelKey))
    }

    func testExplicitUnloadMarkersPruneRemovedPanelsDuringRuntimeReconcile() {
        let windowUUID = WindowUUID()
        let state = FloorpPanelPresentationState(windowUUID: windowUUID)
        let retainedPanel = makePanel(id: "retained")
        let removedPanel = makePanel(id: "removed")
        let retainedKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: retainedPanel.id,
            isPrivate: false
        )
        let removedRegularKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: removedPanel.id,
            isPrivate: false
        )
        let removedPrivateKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: removedPanel.id,
            isPrivate: true
        )
        state.markWebPanelExplicitlyUnloaded(retainedKey)
        state.markWebPanelExplicitlyUnloaded(removedRegularKey)
        state.markWebPanelExplicitlyUnloaded(removedPrivateKey)

        state.reconcileWebPanelRuntime(with: [retainedPanel])

        XCTAssertTrue(state.isWebPanelExplicitlyUnloaded(retainedKey))
        XCTAssertFalse(state.isWebPanelExplicitlyUnloaded(removedRegularKey))
        XCTAssertFalse(state.isWebPanelExplicitlyUnloaded(removedPrivateKey))
    }

    func testLastPrivateTabCloseClearsPrivateMarkerWithoutCachedSession() {
        let windowUUID = WindowUUID()
        let state = FloorpPanelPresentationState(windowUUID: windowUUID)
        let regularKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: "portal",
            isPrivate: false
        )
        let privateKey = FloorpWebPanelSessionKey(
            windowUUID: windowUUID,
            panelID: "portal",
            isPrivate: true
        )
        state.markWebPanelExplicitlyUnloaded(regularKey)
        state.markWebPanelExplicitlyUnloaded(privateKey)
        let tabManager = MockTabManager(windowUUID: windowUUID)
        let privateTab = makeTab(isPrivate: true, windowUUID: windowUUID)
        let regularTab = makeTab(isPrivate: false, windowUUID: windowUUID)
        tabManager.selectedTab = privateTab
        tabManager.privateTabs = [privateTab]
        state.observePrivateTabLifecycle(in: tabManager)

        tabManager.selectedTab = regularTab
        tabManager.privateTabs = []
        state.tabManager(tabManager, didRemoveTab: privateTab, isRestoring: false)

        XCTAssertTrue(state.isWebPanelExplicitlyUnloaded(regularKey))
        XCTAssertFalse(state.isWebPanelExplicitlyUnloaded(privateKey))
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

private final class FloorpMemoryPressureNotificationCenter: NotificationProtocol, @unchecked Sendable {
    private let center = NotificationCenter()
    private(set) var addedNames = [Notification.Name]()
    private(set) var removedNames = [Notification.Name]()

    func addObserver(
        _ observer: Any,
        selector aSelector: Selector,
        name aName: Notification.Name?,
        object anObject: Any?
    ) {
        if let aName {
            addedNames.append(aName)
        }
        center.addObserver(observer, selector: aSelector, name: aName, object: anObject)
    }

    func removeObserver(_ observer: Any) {
        center.removeObserver(observer)
    }

    func removeObserver(
        _ observer: Any,
        name aName: Notification.Name?,
        object anObject: Any?
    ) {
        if let aName {
            removedNames.append(aName)
        }
        center.removeObserver(observer, name: aName, object: anObject)
    }

    func post(
        name: Notification.Name,
        withObject object: Any?,
        withUserInfo userInfo: [AnyHashable: Any]?
    ) {
        center.post(name: name, object: object, userInfo: userInfo)
    }

    func publisher(
        for name: Notification.Name,
        object: AnyObject?
    ) -> NotificationCenter.Publisher {
        center.publisher(for: name, object: object)
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
    func testAdaptivePresentationMigrationPreservesLoadedWebPanelSessionAndContent() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let requestedMode = FloorpMutableWebPanelPresentationMode(.pinned)
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: fixture.manager,
            notesStore: .shared,
            presentationState: fixture.presentationState,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            isPrivateProvider: { false },
            presentationModeProvider: { _, _ in requestedMode.value }
        )
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
            window.rootViewController = nil
        }

        let presented = expectation(description: "Pinned web panel drawer presented")
        XCTAssertTrue(drawer.show(from: parent) { presented.fulfill() })
        await fulfillment(of: [presented], timeout: 1)
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let contentView = try XCTUnwrap(session.contentView)
        let contentSuperview = try XCTUnwrap(contentView.superview)
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/retained"))
        session.recordRuntimeState(currentURL: currentURL, pageTitle: "Retained")
        let visibilityChanges = session.visibilityChanges

        requestedMode.value = .overlay
        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        let becameOverlay = await waitForPresentationState {
            drawer.presentationMode == .overlay
                && drawer.isPresentationTransitionSettled
                && parent.presentedViewController === drawer
        }
        XCTAssertTrue(becameOverlay)

        requestedMode.value = .pinned
        drawer.view.setNeedsLayout()
        drawer.view.layoutIfNeeded()
        let becamePinned = await waitForPresentationState {
            drawer.presentationMode == .pinned
                && drawer.isPresentationTransitionSettled
                && drawer.parent === parent
        }
        XCTAssertTrue(becamePinned)

        XCTAssertEqual(fixture.factory.makeCallCount, 1)
        XCTAssertTrue(fixture.factory.sessions.first === session)
        XCTAssertTrue(session.contentView === contentView)
        XCTAssertTrue(contentView.superview === contentSuperview)
        XCTAssertEqual(session.stateObserverCount, 1)
        XCTAssertEqual(session.invalidationCount, 0)
        XCTAssertEqual(session.state.currentURL, currentURL)
        XCTAssertEqual(session.visibilityChanges, visibilityChanges)
        XCTAssertTrue(session.isVisible)
        XCTAssertTrue(
            fixture.presentationState.webPanelSessionStore?
                .evictInactiveSessionsForMemoryPressure().isEmpty == true
        )

        let dismissed = expectation(description: "Migrated web panel drawer dismissed")
        drawer.onDismissed = { dismissed.fulfill() }
        drawer.dismissDrawer()
        await fulfillment(of: [dismissed], timeout: 1)
    }

    // swiftlint:disable:next function_body_length
    func testPinnedWidthChangePreservesFindStateInEveryVisibleWindow() async throws {
        let suiteName = "FloorpPinnedFindResizeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        let panel = try manager.addWebPanel(
            draft: FloorpWebPanelDraft(title: "Resizable", urlText: "https://example.com/panel")
        )
        let firstFactory = MockFloorpWebPanelSessionFactory()
        let secondFactory = MockFloorpWebPanelSessionFactory()
        let firstWindowUUID = WindowUUID()
        let secondWindowUUID = WindowUUID()
        let firstState = FloorpPanelPresentationState(
            windowUUID: firstWindowUUID,
            selectedPanelId: panel.id,
            webPanelSessionStore: FloorpWebPanelSessionStore(
                windowUUID: firstWindowUUID,
                factory: firstFactory
            )
        )
        let secondState = FloorpPanelPresentationState(
            windowUUID: secondWindowUUID,
            selectedPanelId: panel.id,
            webPanelSessionStore: FloorpWebPanelSessionStore(
                windowUUID: secondWindowUUID,
                factory: secondFactory
            )
        )
        let firstDrawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: .shared,
            presentationState: firstState,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            presentationModeProvider: { _, _ in .pinned }
        )
        let secondDrawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: .shared,
            presentationState: secondState,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            presentationModeProvider: { _, _ in .pinned }
        )
        let firstParent = UIViewController()
        let secondParent = UIViewController()
        let firstWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        let secondWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        firstWindow.rootViewController = firstParent
        secondWindow.rootViewController = secondParent
        firstWindow.makeKeyAndVisible()
        secondWindow.makeKeyAndVisible()
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            firstWindow.isHidden = true
            secondWindow.isHidden = true
        }

        let firstPresented = expectation(description: "First pinned Web panel presented")
        let secondPresented = expectation(description: "Second pinned Web panel presented")
        XCTAssertTrue(firstDrawer.show(from: firstParent) { firstPresented.fulfill() })
        XCTAssertTrue(secondDrawer.show(from: secondParent) { secondPresented.fulfill() })
        await fulfillment(of: [firstPresented, secondPresented], timeout: 1)

        let firstSession = try XCTUnwrap(firstFactory.sessions.first)
        let secondSession = try XCTUnwrap(secondFactory.sessions.first)
        let firstContent = try XCTUnwrap(firstSession.contentView)
        let secondContent = try XCTUnwrap(secondSession.contentView)
        let firstContentSuperview = try XCTUnwrap(firstContent.superview)
        let secondContentSuperview = try XCTUnwrap(secondContent.superview)
        let firstFindButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: firstDrawer.view) as? UIButton
        )
        let secondFindButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: secondDrawer.view) as? UIButton
        )
        firstFindButton.sendActions(for: .touchUpInside)
        secondFindButton.sendActions(for: .touchUpInside)
        let firstFindToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: firstDrawer.view)
        )
        let secondFindToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: secondDrawer.view)
        )
        let firstQuery = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Query", in: firstDrawer.view) as? UITextField
        )
        let secondQuery = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Query", in: secondDrawer.view) as? UITextField
        )
        firstQuery.text = "first needle"
        secondQuery.text = "second needle"
        firstQuery.sendActions(for: .editingChanged)
        secondQuery.sendActions(for: .editingChanged)
        let firstVisibilityChanges = firstSession.visibilityChanges
        let secondVisibilityChanges = secondSession.visibilityChanges
        let firstEndFindCount = firstSession.findTargetMock.endSessionCount
        let secondEndFindCount = secondSession.findTargetMock.endSessionCount

        let resizeHandle = try XCTUnwrap(
            findView(
                identifier: "Floorp.Drawer.ResizeHandle",
                in: firstDrawer.view
            ) as? FloorpPanelResizeHandleView
        )
        resizeHandle.accessibilityIncrement()
        firstParent.view.layoutIfNeeded()
        secondParent.view.layoutIfNeeded()

        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).contentWidth, 420)
        for drawer in [firstDrawer, secondDrawer] {
            let container = try XCTUnwrap(
                findView(identifier: "Floorp.Drawer.Container", in: drawer.view)
            )
            XCTAssertEqual(container.frame.width, 420, accuracy: 0.5)
        }
        XCTAssertTrue(firstSession.contentView === firstContent)
        XCTAssertTrue(secondSession.contentView === secondContent)
        XCTAssertTrue(firstContent.superview === firstContentSuperview)
        XCTAssertTrue(secondContent.superview === secondContentSuperview)
        XCTAssertTrue(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: firstDrawer.view)
                === firstFindToolbar
        )
        XCTAssertTrue(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: secondDrawer.view)
                === secondFindToolbar
        )
        XCTAssertFalse(firstFindToolbar.isHidden)
        XCTAssertFalse(secondFindToolbar.isHidden)
        XCTAssertEqual(firstQuery.text, "first needle")
        XCTAssertEqual(secondQuery.text, "second needle")
        XCTAssertEqual(firstSession.stateObserverCount, 1)
        XCTAssertEqual(secondSession.stateObserverCount, 1)
        XCTAssertEqual(firstSession.visibilityChanges, firstVisibilityChanges)
        XCTAssertEqual(secondSession.visibilityChanges, secondVisibilityChanges)
        XCTAssertEqual(firstSession.findTargetMock.endSessionCount, firstEndFindCount)
        XCTAssertEqual(secondSession.findTargetMock.endSessionCount, secondEndFindCount)
        XCTAssertEqual(firstSession.findTargetMock.invalidationCount, 0)
        XCTAssertEqual(secondSession.findTargetMock.invalidationCount, 0)
        XCTAssertEqual(firstSession.findTargetMock.requests.map(\.query), ["first needle"])
        XCTAssertEqual(secondSession.findTargetMock.requests.map(\.query), ["second needle"])

        let firstDismissed = expectation(description: "First pinned Web panel dismissed")
        let secondDismissed = expectation(description: "Second pinned Web panel dismissed")
        firstDrawer.onDismissed = { firstDismissed.fulfill() }
        secondDrawer.onDismissed = { secondDismissed.fulfill() }
        firstDrawer.dismissDrawer()
        secondDrawer.dismissDrawer()
        await fulfillment(of: [firstDismissed, secondDismissed], timeout: 1)
    }

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

    func testClosedWindowStateReloadsWebPanelWidthAfterRegistryChange() throws {
        let suiteName = "FloorpWebPanelWidthInvalidationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = FloorpPanelManager(defaults: defaults)
        let panel = try manager.addWebPanel(
            draft: FloorpWebPanelDraft(title: "Portal", urlText: "https://example.com/panel")
        )
        let state = FloorpPanelPresentationState(
            windowUUID: .XCTestDefaultUUID,
            selectedPanelId: panel.id
        )
        state.configureWebPanelRuntime(
            profile: MockProfile(),
            panelManager: manager,
            openInMainBrowser: { _ in }
        )
        defer { state.invalidateWebPanelRuntime() }
        state.setPreferredPanelWidth(420, for: panel.id)
        XCTAssertEqual(state.preferredPanelWidth(for: panel), 420)

        let revision = try manager.webPanelPreferencesRevision(for: panel.id)
        _ = try manager.setWebPanelContentWidth(
            380,
            for: panel.id,
            expectedRevision: revision
        )

        let updatedPanel = try XCTUnwrap(manager.panel(for: panel.id))
        XCTAssertEqual(state.preferredPanelWidth(for: updatedPanel), 380)
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

    // swiftlint:disable:next function_body_length
    func testMediaPauseMenuAndVoiceOverTogglePreserveActiveRuntime() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let content = try XCTUnwrap(session.contentView)
        let contentSuperview = try XCTUnwrap(content.superview)
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/media-pause-current"))
        session.recordRuntimeState(currentURL: currentURL, pageTitle: "Media Pause")
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: drawer.view) as? UIButton
        )
        findButton.sendActions(for: .touchUpInside)
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
        )
        let findQuery = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Query", in: drawer.view) as? UITextField
        )
        findQuery.text = "keep media query"
        findQuery.sendActions(for: .editingChanged)
        let button = try XCTUnwrap(
            findView(identifier: panel.id, in: drawer.view) as? UIButton
        )
        let pauseMediaAction = try XCTUnwrap(
            drawer.currentMediaPauseMenuElements(for: panel.id).first as? UIAction
        )

        XCTAssertEqual(pauseMediaAction.title, FloorpStrings.Drawer.webPanelPauseMedia)
        XCTAssertNotNil(pauseMediaAction.image)
        XCTAssertNil(button.accessibilityValue)
        invoke(pauseMediaAction)

        XCTAssertTrue(session.state.isUserMediaPaused)
        XCTAssertEqual(button.accessibilityValue, FloorpStrings.Drawer.webPanelMediaPausedState)
        XCTAssertEqual(
            button.accessibilityCustomActions?.map(\.name),
            [
                FloorpStrings.Drawer.webPanelUnload,
                FloorpStrings.Drawer.webPanelResumeMedia,
                String.LegacyAppMenu.AppMenuViewDesktopSiteTitleString,
                FloorpStrings.Drawer.webPanelZoomIn,
                FloorpStrings.Drawer.webPanelZoomOut,
            ]
        )
        let resumeMediaMenuAction = try XCTUnwrap(
            drawer.currentMediaPauseMenuElements(for: panel.id).first as? UIAction
        )
        XCTAssertEqual(resumeMediaMenuAction.title, FloorpStrings.Drawer.webPanelResumeMedia)
        let resumeMediaAccessibilityAction = try XCTUnwrap(
            button.accessibilityCustomActions?.first(where: {
                $0.name == FloorpStrings.Drawer.webPanelResumeMedia
            })
        )
        XCTAssertTrue(
            resumeMediaAccessibilityAction.actionHandler?(resumeMediaAccessibilityAction) == true
        )

        XCTAssertFalse(session.state.isUserMediaPaused)
        XCTAssertNil(button.accessibilityValue)
        XCTAssertTrue(session.contentView === content)
        XCTAssertTrue(content.superview === contentSuperview)
        XCTAssertEqual(session.state.currentURL, currentURL)
        XCTAssertTrue(findToolbar.superview != nil)
        XCTAssertFalse(findToolbar.isHidden)
        XCTAssertEqual(findQuery.text, "keep media query")
        XCTAssertEqual(session.findTargetMock.invalidationCount, 0)
    }

    func testStaleMediaPauseActionsCannotAffectReplacementPrivacyOrNewerState() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let privacyMode = FloorpMutableWebPanelPrivacyMode(false)
        let drawer = fixture.makeDrawer(isPrivateProvider: { privacyMode.value })
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let original = try XCTUnwrap(fixture.factory.sessions.last)
        let staleOriginalMediaAction = try XCTUnwrap(
            drawer.currentMediaPauseMenuElements(for: panel.id).first as? UIAction
        )

        XCTAssertTrue(drawer.unloadWebPanelIfActive(panelID: panel.id))
        let button = try XCTUnwrap(
            findView(identifier: panel.id, in: drawer.view) as? UIButton
        )
        button.sendActions(for: .touchUpInside)
        let replacement = try XCTUnwrap(fixture.factory.sessions.last)
        invoke(staleOriginalMediaAction)

        XCTAssertFalse(replacement === original)
        XCTAssertFalse(replacement.state.isUserMediaPaused)

        let staleRegularMediaAction = try XCTUnwrap(
            drawer.currentMediaPauseMenuElements(for: panel.id).first as? UIAction
        )
        privacyMode.value = true
        drawer.rebindActiveContent(forSelectedTabIsPrivate: true)
        let privateSession = try XCTUnwrap(fixture.factory.sessions.last)
        invoke(staleRegularMediaAction)

        XCTAssertTrue(privateSession.key.isPrivate)
        XCTAssertFalse(privateSession.state.isUserMediaPaused)
        let privatePauseMediaAction = try XCTUnwrap(
            drawer.currentMediaPauseMenuElements(for: panel.id).first as? UIAction
        )
        invoke(privatePauseMediaAction)
        invoke(privatePauseMediaAction)

        XCTAssertTrue(privateSession.state.isUserMediaPaused)
        XCTAssertFalse(replacement.state.isUserMediaPaused)
    }

    func testStaleMediaPauseContextCannotTargetReplacementAfterOriginalDeallocation() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        var originalSession: MockFloorpWebPanelSession? = try XCTUnwrap(
            fixture.factory.sessions.last
        )
        let staleContext = try XCTUnwrap(
            drawer.currentWebPanelMediaPauseActionContext(for: panel.id)
        )
        let originalIdentifier = try XCTUnwrap(originalSession?.sessionIdentifier)
        weak var releasedSession = originalSession

        XCTAssertTrue(drawer.unloadWebPanelIfActive(panelID: panel.id))
        fixture.factory.releaseSession(identifier: originalIdentifier)
        originalSession = nil
        XCTAssertNil(releasedSession)

        let button = try XCTUnwrap(
            findView(identifier: panel.id, in: drawer.view) as? UIButton
        )
        button.sendActions(for: .touchUpInside)
        let replacement = try XCTUnwrap(fixture.factory.sessions.last)

        XCTAssertEqual(replacement.key, staleContext.key)
        XCTAssertNotEqual(replacement.sessionIdentifier, originalIdentifier)
        XCTAssertFalse(replacement.state.isUserMediaPaused)
        XCTAssertEqual(replacement.state.userMediaStateRevision, 0)
        XCTAssertFalse(drawer.performWebPanelMediaPauseAction(context: staleContext))
        XCTAssertFalse(replacement.state.isUserMediaPaused)
        XCTAssertEqual(replacement.state.userMediaStateRevision, 0)
    }

    func testStaleMediaPauseActionRejectsABAReturnToOriginalState() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let staleInitialContext = try XCTUnwrap(
            drawer.currentWebPanelMediaPauseActionContext(for: panel.id)
        )

        XCTAssertEqual(staleInitialContext.expectedRevision, 0)
        XCTAssertTrue(drawer.performWebPanelMediaPauseAction(context: staleInitialContext))
        XCTAssertTrue(session.state.isUserMediaPaused)
        XCTAssertEqual(session.state.userMediaStateRevision, 1)

        let resumeContext = try XCTUnwrap(
            drawer.currentWebPanelMediaPauseActionContext(for: panel.id)
        )
        XCTAssertTrue(drawer.performWebPanelMediaPauseAction(context: resumeContext))
        XCTAssertFalse(session.state.isUserMediaPaused)
        XCTAssertEqual(session.state.userMediaStateRevision, 2)

        XCTAssertFalse(drawer.performWebPanelMediaPauseAction(context: staleInitialContext))
        XCTAssertFalse(session.state.isUserMediaPaused)
        XCTAssertEqual(session.state.userMediaStateRevision, 2)
    }

    func testMediaPauseFailureRollsBackVoiceOverStateAndShowsMediaPlaybackError() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = drawer
        window.makeKeyAndVisible()
        defer {
            drawer.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let button = try XCTUnwrap(
            findView(identifier: panel.id, in: drawer.view) as? UIButton
        )
        session.mediaPauseError = FloorpPanelError.storageError("Injected media pause failure")
        let context = try XCTUnwrap(drawer.currentWebPanelMediaPauseActionContext(for: panel.id))

        XCTAssertTrue(drawer.performWebPanelMediaPauseAction(context: context))
        let presentedError = await waitForPresentationState {
            drawer.presentedViewController is UIAlertController
        }

        XCTAssertTrue(presentedError)
        XCTAssertFalse(session.state.isUserMediaPaused)
        XCTAssertEqual(session.state.userMediaStateRevision, 2)
        XCTAssertFalse(drawer.performWebPanelMediaPauseAction(context: context))
        XCTAssertNil(button.accessibilityValue)
        let alert = try XCTUnwrap(drawer.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, FloorpStrings.Drawer.webPanelMediaPlaybackErrorTitle)
        XCTAssertEqual(alert.message, FloorpStrings.Drawer.webPanelMediaPlaybackErrorMessage)
    }

    // swiftlint:disable:next function_body_length
    func testZoomMenuFastPathPreservesFindAndUpdatesEveryWindowAndPrivacySession() throws {
        let suiteName = "FloorpWebPanelZoomFastPathTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        let panel = try manager.addWebPanel(
            draft: FloorpWebPanelDraft(title: "Zoom", urlText: "https://example.com/zoom")
        )
        let firstFactory = MockFloorpWebPanelSessionFactory()
        let secondFactory = MockFloorpWebPanelSessionFactory()
        let firstWindowUUID = WindowUUID()
        let secondWindowUUID = WindowUUID()
        let firstStore = FloorpWebPanelSessionStore(
            windowUUID: firstWindowUUID,
            factory: firstFactory
        )
        let secondStore = FloorpWebPanelSessionStore(
            windowUUID: secondWindowUUID,
            factory: secondFactory
        )
        let firstState = FloorpPanelPresentationState(
            windowUUID: firstWindowUUID,
            selectedPanelId: panel.id,
            webPanelSessionStore: firstStore
        )
        let secondState = FloorpPanelPresentationState(
            windowUUID: secondWindowUUID,
            selectedPanelId: panel.id,
            webPanelSessionStore: secondStore
        )
        defer {
            firstState.invalidateWebPanelRuntime()
            secondState.invalidateWebPanelRuntime()
        }
        let privateSession = try XCTUnwrap(
            try firstStore.session(for: panel, isPrivate: true)
                as? MockFloorpWebPanelSession
        )
        let firstDrawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: .shared,
            presentationState: firstState,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            isPrivateProvider: { false }
        )
        let secondDrawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: .shared,
            presentationState: secondState,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            isPrivateProvider: { false }
        )
        firstDrawer.loadViewIfNeeded()
        secondDrawer.loadViewIfNeeded()
        let firstSession = try XCTUnwrap(firstFactory.sessions.first(where: { !$0.key.isPrivate }))
        let secondSession = try XCTUnwrap(secondFactory.sessions.first)
        let firstContent = try XCTUnwrap(firstSession.contentView)
        let secondContent = try XCTUnwrap(secondSession.contentView)
        let firstSuperview = try XCTUnwrap(firstContent.superview)
        let secondSuperview = try XCTUnwrap(secondContent.superview)
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first-current"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second-current"))
        firstSession.recordRuntimeState(currentURL: firstURL, pageTitle: "First")
        secondSession.recordRuntimeState(currentURL: secondURL, pageTitle: "Second")
        let firstFindButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: firstDrawer.view) as? UIButton
        )
        let secondFindButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: secondDrawer.view) as? UIButton
        )
        firstFindButton.sendActions(for: .touchUpInside)
        secondFindButton.sendActions(for: .touchUpInside)
        let firstFindToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: firstDrawer.view)
        )
        let secondFindToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: secondDrawer.view)
        )
        let firstQuery = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Query", in: firstDrawer.view) as? UITextField
        )
        let secondQuery = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Query", in: secondDrawer.view) as? UITextField
        )
        firstQuery.text = "first needle"
        secondQuery.text = "second needle"
        firstQuery.sendActions(for: .editingChanged)
        secondQuery.sendActions(for: .editingChanged)

        let initialMenu = try zoomMenu(in: firstDrawer, panelID: panel.id)
        XCTAssertEqual(
            initialMenu.title,
            FloorpStrings.Drawer.webPanelZoomMenuTitle(percent: 100)
        )
        XCTAssertTrue(
            try zoomAction(FloorpStrings.Drawer.webPanelZoomReset, in: initialMenu)
                .attributes.contains(.disabled)
        )
        invoke(try zoomAction(FloorpStrings.Drawer.webPanelZoomIn, in: initialMenu))

        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).zoomLevel, .oneHundredTenPercent)
        for session in [firstSession, privateSession, secondSession] {
            XCTAssertEqual(session.state.configuration.zoomLevel, .oneHundredTenPercent)
            XCTAssertEqual(session.invalidationCount, 0)
        }
        XCTAssertTrue(firstSession.contentView === firstContent)
        XCTAssertTrue(secondSession.contentView === secondContent)
        XCTAssertTrue(firstContent.superview === firstSuperview)
        XCTAssertTrue(secondContent.superview === secondSuperview)
        XCTAssertEqual(firstSession.state.currentURL, firstURL)
        XCTAssertEqual(secondSession.state.currentURL, secondURL)
        XCTAssertTrue(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: firstDrawer.view)
                === firstFindToolbar
        )
        XCTAssertTrue(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: secondDrawer.view)
                === secondFindToolbar
        )
        XCTAssertFalse(firstFindToolbar.isHidden)
        XCTAssertFalse(secondFindToolbar.isHidden)
        XCTAssertEqual(firstQuery.text, "first needle")
        XCTAssertEqual(secondQuery.text, "second needle")
        XCTAssertEqual(firstSession.findTargetMock.invalidationCount, 0)
        XCTAssertEqual(secondSession.findTargetMock.invalidationCount, 0)
        XCTAssertEqual(firstSession.findTargetMock.requests.map(\.query), ["first needle"])
        XCTAssertEqual(secondSession.findTargetMock.requests.map(\.query), ["second needle"])

        let firstButton = try XCTUnwrap(
            findView(identifier: panel.id, in: firstDrawer.view) as? UIButton
        )
        XCTAssertEqual(
            firstButton.accessibilityCustomActions?.map(\.name),
            [
                FloorpStrings.Drawer.webPanelUnload,
                FloorpStrings.Drawer.webPanelPauseMedia,
                String.LegacyAppMenu.AppMenuViewDesktopSiteTitleString,
                FloorpStrings.Drawer.webPanelZoomIn,
                FloorpStrings.Drawer.webPanelZoomOut,
                FloorpStrings.Drawer.webPanelZoomReset,
            ]
        )
        let resetAccessibilityAction = try XCTUnwrap(
            firstButton.accessibilityCustomActions?.first(where: {
                $0.name == FloorpStrings.Drawer.webPanelZoomReset
            })
        )
        XCTAssertTrue(
            resetAccessibilityAction.actionHandler?(resetAccessibilityAction) == true
        )
        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).zoomLevel, .defaultLevel)
        XCTAssertEqual(
            firstButton.accessibilityCustomActions?.map(\.name),
            [
                FloorpStrings.Drawer.webPanelUnload,
                FloorpStrings.Drawer.webPanelPauseMedia,
                String.LegacyAppMenu.AppMenuViewDesktopSiteTitleString,
                FloorpStrings.Drawer.webPanelZoomIn,
                FloorpStrings.Drawer.webPanelZoomOut,
            ]
        )
    }

    // swiftlint:disable:next function_body_length
    func testContentModeMenuUpdatesEveryWindowInPlaceAndClosesFindBeforeReload() throws {
        let suiteName = "FloorpWebPanelContentModeFastPathTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        let manager = FloorpPanelManager(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        let panel = try manager.addWebPanel(
            draft: FloorpWebPanelDraft(title: "Mode", urlText: "https://example.com/mode")
        )
        let firstFactory = MockFloorpWebPanelSessionFactory()
        let secondFactory = MockFloorpWebPanelSessionFactory()
        let firstStore = FloorpWebPanelSessionStore(
            windowUUID: .XCTestDefaultUUID,
            factory: firstFactory
        )
        let secondWindowUUID = WindowUUID()
        let secondStore = FloorpWebPanelSessionStore(
            windowUUID: secondWindowUUID,
            factory: secondFactory
        )
        let firstState = FloorpPanelPresentationState(
            windowUUID: .XCTestDefaultUUID,
            selectedPanelId: panel.id,
            webPanelSessionStore: firstStore
        )
        let secondState = FloorpPanelPresentationState(
            windowUUID: secondWindowUUID,
            selectedPanelId: panel.id,
            webPanelSessionStore: secondStore
        )
        defer {
            firstState.invalidateWebPanelRuntime()
            secondState.invalidateWebPanelRuntime()
        }
        let privateSession = try XCTUnwrap(
            firstStore.session(for: panel, isPrivate: true) as? MockFloorpWebPanelSession
        )
        let firstDrawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: .shared,
            presentationState: firstState,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            isPrivateProvider: { false }
        )
        let secondDrawer = FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: .shared,
            presentationState: secondState,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            isPrivateProvider: { false }
        )
        firstDrawer.loadViewIfNeeded()
        secondDrawer.loadViewIfNeeded()
        let firstSession = try XCTUnwrap(firstFactory.sessions.first(where: { !$0.key.isPrivate }))
        let secondSession = try XCTUnwrap(secondFactory.sessions.first)
        let firstContent = try XCTUnwrap(firstSession.contentView)
        let secondContent = try XCTUnwrap(secondSession.contentView)
        let firstSuperview = try XCTUnwrap(firstContent.superview)
        let secondSuperview = try XCTUnwrap(secondContent.superview)
        firstSession.recordRuntimeState(
            currentURL: try XCTUnwrap(URL(string: "https://example.com/first")),
            pageTitle: "First"
        )
        secondSession.recordRuntimeState(
            currentURL: try XCTUnwrap(URL(string: "https://example.com/second")),
            pageTitle: "Second"
        )
        privateSession.recordRuntimeState(
            currentURL: try XCTUnwrap(URL(string: "https://example.com/private")),
            pageTitle: "Private"
        )
        let firstFindButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: firstDrawer.view) as? UIButton
        )
        let secondFindButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: secondDrawer.view) as? UIButton
        )
        firstFindButton.sendActions(for: .touchUpInside)
        secondFindButton.sendActions(for: .touchUpInside)
        let firstFindToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: firstDrawer.view)
        )
        let secondFindToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: secondDrawer.view)
        )
        XCTAssertFalse(firstFindToolbar.isHidden)
        XCTAssertFalse(secondFindToolbar.isHidden)
        let action = try XCTUnwrap(
            firstDrawer.currentContentModeMenuElements(for: panel.id).first as? UIAction
        )
        XCTAssertEqual(
            action.title,
            String.LegacyAppMenu.AppMenuViewDesktopSiteTitleString
        )

        invoke(action)

        XCTAssertEqual(try manager.webPanelPreferences(for: panel.id).contentMode, .desktop)
        for session in [firstSession, privateSession, secondSession] {
            XCTAssertEqual(session.state.configuration.contentMode, .desktop)
            XCTAssertEqual(session.invalidationCount, 0)
        }
        XCTAssertEqual(firstSession.contentModeReloadCount, 1)
        XCTAssertEqual(secondSession.contentModeReloadCount, 1)
        XCTAssertEqual(privateSession.contentModeReloadCount, 0)
        XCTAssertEqual(
            firstSession.contentModeEvents,
            ["executor-desktop", "find-ended", "reload-from-origin"]
        )
        XCTAssertTrue(firstSession.contentView === firstContent)
        XCTAssertTrue(secondSession.contentView === secondContent)
        XCTAssertTrue(firstContent.superview === firstSuperview)
        XCTAssertTrue(secondContent.superview === secondSuperview)
        XCTAssertTrue(firstFindToolbar.isHidden)
        XCTAssertTrue(secondFindToolbar.isHidden)
        let mobileAction = try XCTUnwrap(
            firstDrawer.currentContentModeMenuElements(for: panel.id).first as? UIAction
        )
        XCTAssertEqual(
            mobileAction.title,
            String.LegacyAppMenu.AppMenuViewMobileSiteTitleString
        )
        let firstButton = try XCTUnwrap(
            findView(identifier: panel.id, in: firstDrawer.view) as? UIButton
        )
        let firstActionNames = firstButton.accessibilityCustomActions?.map(\.name) ?? []
        XCTAssertEqual(
            Array(firstActionNames.prefix(3)),
            [
                FloorpStrings.Drawer.webPanelUnload,
                FloorpStrings.Drawer.webPanelPauseMedia,
                String.LegacyAppMenu.AppMenuViewMobileSiteTitleString,
            ]
        )
        let staleContext = try XCTUnwrap(
            firstDrawer.currentWebPanelContentModeActionContext(for: panel.id)
        )
        XCTAssertFalse(firstDrawer.performWebPanelContentModeAction(
            .desktop,
            context: staleContext
        ))
        XCTAssertEqual(firstSession.contentModeReloadCount, 1)
    }

    func testGenericReconcileAppliesActiveContentModeWithoutReplacingSession() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        XCTAssertTrue(fixture.presentationState.attach(drawer))
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let preferences = try XCTUnwrap(panel.effectiveWebPreferences)
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let contentView = try XCTUnwrap(session.contentView)
        let contentSuperview = try XCTUnwrap(contentView.superview)
        session.recordRuntimeState(
            currentURL: try XCTUnwrap(URL(string: "https://example.com/reconciled")),
            pageTitle: "Reconciled"
        )
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: drawer.view) as? UIButton
        )
        findButton.sendActions(for: .touchUpInside)
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
        )
        XCTAssertFalse(findToolbar.isHidden)
        var reconciledPanel = panel
        reconciledPanel.webPreferences = FloorpWebPanelPreferences(
            revision: preferences.revision + 1,
            contentWidth: preferences.contentWidth,
            zoomLevel: preferences.zoomLevel,
            contentMode: .desktop
        )

        fixture.presentationState.reconcileWebPanelRuntime(with: [reconciledPanel])

        XCTAssertTrue(fixture.factory.sessions.first === session)
        XCTAssertTrue(session.contentView === contentView)
        XCTAssertTrue(contentView.superview === contentSuperview)
        XCTAssertEqual(session.invalidationCount, 0)
        XCTAssertEqual(session.state.configuration.contentMode, .desktop)
        XCTAssertEqual(session.contentModeReloadCount, 1)
        XCTAssertEqual(
            session.contentModeEvents,
            ["executor-desktop", "find-ended", "reload-from-origin"]
        )
        XCTAssertTrue(findToolbar.isHidden)
    }

    func testStaleContentModeActionCannotMutateReplacementSession() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let staleAction = try XCTUnwrap(
            drawer.currentContentModeMenuElements(for: panel.id).first as? UIAction
        )
        let original = try XCTUnwrap(fixture.factory.sessions.first)

        XCTAssertTrue(drawer.unloadWebPanelIfActive(panelID: panel.id))
        let button = try XCTUnwrap(
            findView(identifier: panel.id, in: drawer.view) as? UIButton
        )
        button.sendActions(for: .touchUpInside)
        let replacement = try XCTUnwrap(fixture.factory.sessions.last)
        XCTAssertFalse(replacement === original)

        invoke(staleAction)

        XCTAssertEqual(try fixture.manager.webPanelPreferences(for: panel.id).contentMode, .mobile)
        XCTAssertEqual(replacement.state.configuration.contentMode, .mobile)
        XCTAssertEqual(replacement.contentModeReloadCount, 0)
    }

    func testContentModeStorageFailureKeepsRuntimeAndShowsOperationError() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        var mutationCallCount = 0
        let drawer = fixture.makeDrawer(
            isPrivateProvider: { false },
            webPanelContentModeMutation: { _, _, _ in
                mutationCallCount += 1
                throw FloorpPanelError.storageError("Injected content mode write failure")
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = drawer
        window.makeKeyAndVisible()
        defer {
            drawer.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let content = try XCTUnwrap(session.contentView)
        let contentSuperview = try XCTUnwrap(content.superview)
        session.recordRuntimeState(
            currentURL: try XCTUnwrap(URL(string: "https://example.com/error")),
            pageTitle: "Error"
        )
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: drawer.view) as? UIButton
        )
        findButton.sendActions(for: .touchUpInside)
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
        )
        XCTAssertFalse(findToolbar.isHidden)
        let context = try XCTUnwrap(
            drawer.currentWebPanelContentModeActionContext(for: panel.id)
        )

        XCTAssertFalse(drawer.performWebPanelContentModeAction(.desktop, context: context))
        let presentedError = await waitForPresentationState {
            drawer.presentedViewController is UIAlertController
        }

        XCTAssertTrue(presentedError)
        XCTAssertEqual(mutationCallCount, 1)
        XCTAssertEqual(try fixture.manager.webPanelPreferences(for: panel.id).contentMode, .mobile)
        XCTAssertEqual(session.state.configuration.contentMode, .mobile)
        XCTAssertEqual(session.contentModeReloadCount, 0)
        XCTAssertEqual(session.invalidationCount, 0)
        XCTAssertFalse(findToolbar.isHidden)
        XCTAssertTrue(session.contentView === content)
        XCTAssertTrue(content.superview === contentSuperview)
        XCTAssertEqual(
            (drawer.presentedViewController as? UIAlertController)?.title,
            FloorpStrings.PanelRegistry.operationFailedTitle
        )
    }

    func testZoomMenuAndVoiceOverActionsRespectBoundsAndReset() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        while try fixture.manager.webPanelPreferences(for: panel.id).zoomLevel != .fiftyPercent {
            _ = try fixture.manager.adjustWebPanelZoom(
                for: panel.id,
                change: .decrease,
                expectedRevision: try fixture.manager.webPanelPreferencesRevision(for: panel.id)
            )
        }
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        let button = try XCTUnwrap(
            findView(identifier: panel.id, in: drawer.view) as? UIButton
        )
        let minimumMenu = try zoomMenu(in: drawer, panelID: panel.id)

        XCTAssertTrue(
            try zoomAction(FloorpStrings.Drawer.webPanelZoomOut, in: minimumMenu)
                .attributes.contains(.disabled)
        )
        XCTAssertEqual(
            button.accessibilityCustomActions?.map(\.name),
            [
                FloorpStrings.Drawer.webPanelUnload,
                FloorpStrings.Drawer.webPanelPauseMedia,
                String.LegacyAppMenu.AppMenuViewDesktopSiteTitleString,
                FloorpStrings.Drawer.webPanelZoomIn,
                FloorpStrings.Drawer.webPanelZoomReset,
            ]
        )

        while try fixture.manager.webPanelPreferences(for: panel.id).zoomLevel
            != .threeHundredPercent {
            let context = try XCTUnwrap(drawer.currentWebPanelZoomActionContext(for: panel.id))
            XCTAssertTrue(drawer.performWebPanelZoomAction(.increase, context: context))
        }
        let maximumMenu = try zoomMenu(in: drawer, panelID: panel.id)
        XCTAssertTrue(
            try zoomAction(FloorpStrings.Drawer.webPanelZoomIn, in: maximumMenu)
                .attributes.contains(.disabled)
        )
        XCTAssertEqual(
            button.accessibilityCustomActions?.map(\.name),
            [
                FloorpStrings.Drawer.webPanelUnload,
                FloorpStrings.Drawer.webPanelPauseMedia,
                String.LegacyAppMenu.AppMenuViewDesktopSiteTitleString,
                FloorpStrings.Drawer.webPanelZoomOut,
                FloorpStrings.Drawer.webPanelZoomReset,
            ]
        )

        invoke(try zoomAction(FloorpStrings.Drawer.webPanelZoomReset, in: maximumMenu))

        XCTAssertEqual(try fixture.manager.webPanelPreferences(for: panel.id).zoomLevel, .defaultLevel)
        XCTAssertEqual(
            button.accessibilityCustomActions?.map(\.name),
            [
                FloorpStrings.Drawer.webPanelUnload,
                FloorpStrings.Drawer.webPanelPauseMedia,
                String.LegacyAppMenu.AppMenuViewDesktopSiteTitleString,
                FloorpStrings.Drawer.webPanelZoomIn,
                FloorpStrings.Drawer.webPanelZoomOut,
            ]
        )
    }

    func testStaleZoomMenuActionsCannotMutateReplacementOrOtherPrivacySession() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let privacyMode = FloorpMutableWebPanelPrivacyMode(false)
        let drawer = fixture.makeDrawer(isPrivateProvider: { privacyMode.value })
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let staleOriginalMediaAction = try zoomAction(
            FloorpStrings.Drawer.webPanelZoomIn,
            in: zoomMenu(in: drawer, panelID: panel.id)
        )
        let original = try XCTUnwrap(fixture.factory.sessions.last)

        XCTAssertTrue(drawer.unloadWebPanelIfActive(panelID: panel.id))
        let button = try XCTUnwrap(
            findView(identifier: panel.id, in: drawer.view) as? UIButton
        )
        button.sendActions(for: .touchUpInside)
        let replacement = try XCTUnwrap(fixture.factory.sessions.last)
        XCTAssertFalse(replacement === original)

        invoke(staleOriginalMediaAction)
        XCTAssertEqual(try fixture.manager.webPanelPreferences(for: panel.id).zoomLevel, .defaultLevel)
        XCTAssertEqual(replacement.state.configuration.zoomLevel, .defaultLevel)

        let staleRegularMediaAction = try zoomAction(
            FloorpStrings.Drawer.webPanelZoomIn,
            in: zoomMenu(in: drawer, panelID: panel.id)
        )
        privacyMode.value = true
        drawer.rebindActiveContent(forSelectedTabIsPrivate: true)
        let privateSession = try XCTUnwrap(fixture.factory.sessions.last)
        XCTAssertTrue(privateSession.key.isPrivate)

        invoke(staleRegularMediaAction)
        XCTAssertEqual(try fixture.manager.webPanelPreferences(for: panel.id).zoomLevel, .defaultLevel)
        XCTAssertEqual(privateSession.state.configuration.zoomLevel, .defaultLevel)
        let privateMenu = try zoomMenu(in: drawer, panelID: panel.id)
        invoke(try zoomAction(FloorpStrings.Drawer.webPanelZoomIn, in: privateMenu))

        XCTAssertEqual(try fixture.manager.webPanelPreferences(for: panel.id).zoomLevel, .oneHundredTenPercent)
        XCTAssertEqual(privateSession.state.configuration.zoomLevel, .oneHundredTenPercent)
        XCTAssertEqual(replacement.state.configuration.zoomLevel, .oneHundredTenPercent)
    }

    func testStaleZoomRevisionSynchronizesLatestAndShowsOperationErrorInPlace() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = drawer
        window.makeKeyAndVisible()
        defer {
            drawer.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let content = try XCTUnwrap(session.contentView)
        let contentSuperview = try XCTUnwrap(content.superview)
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/cas-current"))
        session.recordRuntimeState(currentURL: currentURL, pageTitle: "CAS")
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: drawer.view) as? UIButton
        )
        findButton.sendActions(for: .touchUpInside)
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
        )
        let findQuery = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Query", in: drawer.view) as? UITextField
        )
        findQuery.text = "keep cas query"
        findQuery.sendActions(for: .editingChanged)
        let staleContext = try XCTUnwrap(drawer.currentWebPanelZoomActionContext(for: panel.id))
        _ = try fixture.manager.adjustWebPanelZoom(
            for: panel.id,
            change: .increase,
            expectedRevision: try fixture.manager.webPanelPreferencesRevision(for: panel.id)
        )

        XCTAssertFalse(drawer.performWebPanelZoomAction(.increase, context: staleContext))
        let presentedError = await waitForPresentationState {
            drawer.presentedViewController is UIAlertController
        }

        XCTAssertTrue(presentedError)
        XCTAssertEqual(
            (drawer.presentedViewController as? UIAlertController)?.title,
            FloorpStrings.PanelRegistry.operationFailedTitle
        )
        XCTAssertEqual(try fixture.manager.webPanelPreferences(for: panel.id).zoomLevel, .oneHundredTenPercent)
        XCTAssertEqual(session.state.configuration.zoomLevel, .oneHundredTenPercent)
        XCTAssertEqual(session.invalidationCount, 0)
        XCTAssertTrue(session.contentView === content)
        XCTAssertTrue(content.superview === contentSuperview)
        XCTAssertEqual(session.state.currentURL, currentURL)
        XCTAssertTrue(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
                === findToolbar
        )
        XCTAssertFalse(findToolbar.isHidden)
        XCTAssertEqual(findQuery.text, "keep cas query")
        XCTAssertEqual(session.findTargetMock.invalidationCount, 0)
        XCTAssertEqual(session.findTargetMock.requests.map(\.query), ["keep cas query"])
    }

    func testZoomStorageFailureRollsBackLatestAndPreservesFindRuntime() async throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        var mutationCallCount = 0
        let drawer = fixture.makeDrawer(
            isPrivateProvider: { false },
            webPanelZoomMutation: { _, _, _ in
                mutationCallCount += 1
                throw FloorpPanelError.storageError("Injected zoom write failure")
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = drawer
        window.makeKeyAndVisible()
        defer {
            drawer.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let session = try XCTUnwrap(fixture.factory.sessions.first)
        let content = try XCTUnwrap(session.contentView)
        let contentSuperview = try XCTUnwrap(content.superview)
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/storage-current"))
        session.recordRuntimeState(currentURL: currentURL, pageTitle: "Storage")
        let findButton = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find", in: drawer.view) as? UIButton
        )
        findButton.sendActions(for: .touchUpInside)
        let findToolbar = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
        )
        let findQuery = try XCTUnwrap(
            findView(identifier: "Floorp.WebPanel.Find.Query", in: drawer.view) as? UITextField
        )
        findQuery.text = "keep storage query"
        findQuery.sendActions(for: .editingChanged)
        let context = try XCTUnwrap(drawer.currentWebPanelZoomActionContext(for: panel.id))

        XCTAssertFalse(drawer.performWebPanelZoomAction(.increase, context: context))
        let presentedError = await waitForPresentationState {
            drawer.presentedViewController is UIAlertController
        }

        XCTAssertTrue(presentedError)
        XCTAssertEqual(mutationCallCount, 1)
        XCTAssertEqual(try fixture.manager.webPanelPreferences(for: panel.id).zoomLevel, .defaultLevel)
        XCTAssertEqual(session.state.configuration.zoomLevel, .defaultLevel)
        XCTAssertEqual(session.invalidationCount, 0)
        XCTAssertTrue(session.contentView === content)
        XCTAssertTrue(content.superview === contentSuperview)
        XCTAssertEqual(session.state.currentURL, currentURL)
        XCTAssertTrue(
            findView(identifier: "Floorp.WebPanel.Find.Toolbar", in: drawer.view)
                === findToolbar
        )
        XCTAssertFalse(findToolbar.isHidden)
        XCTAssertEqual(findQuery.text, "keep storage query")
        XCTAssertEqual(session.findTargetMock.invalidationCount, 0)
        XCTAssertEqual(session.findTargetMock.requests.map(\.query), ["keep storage query"])
    }

    func testPersistedZoomAppliesWhenAutoUnloadRecreatesSession() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        _ = try fixture.manager.setAutoUnload(
            true,
            expectedRevision: FloorpOverlayDrawerConfigRevision(config: fixture.manager.config)
        )
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        let panel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let context = try XCTUnwrap(drawer.currentWebPanelZoomActionContext(for: panel.id))
        XCTAssertTrue(drawer.performWebPanelZoomAction(.increase, context: context))
        let first = try XCTUnwrap(fixture.factory.sessions.last)
        let builtIn = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type != .web }))
        let builtInButton = try XCTUnwrap(
            findView(identifier: builtIn.id, in: drawer.view) as? UIButton
        )

        builtInButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(first.invalidationCount, 1)
        let webPanelButton = try XCTUnwrap(
            findView(identifier: panel.id, in: drawer.view) as? UIButton
        )
        webPanelButton.sendActions(for: .touchUpInside)
        let replacement = try XCTUnwrap(fixture.factory.sessions.last)

        XCTAssertFalse(replacement === first)
        XCTAssertEqual(replacement.state.configuration.zoomLevel, .oneHundredTenPercent)
        XCTAssertEqual(try fixture.manager.webPanelPreferences(for: panel.id).zoomLevel, .oneHundredTenPercent)
    }

    func testActiveExplicitUnloadDetachesRuntimeUntilSelectedAgain() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let otherWebPanel = try fixture.manager.addWebPanel(
            draft: FloorpWebPanelDraft(
                title: "Other",
                urlText: "https://example.com/other"
            )
        )
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

        let webPanel = try XCTUnwrap(fixture.manager.panels.first(where: {
            $0.type == .web && $0.id != otherWebPanel.id
        }))
        let webPanelButton = try XCTUnwrap(
            findView(identifier: webPanel.id, in: drawer.view) as? UIButton
        )
        let otherWebPanelButton = try XCTUnwrap(
            findView(identifier: otherWebPanel.id, in: drawer.view) as? UIButton
        )
        XCTAssertTrue(webPanelButton.menu?.children.first is UIDeferredMenuElement)
        let unloadMenuAction = try XCTUnwrap(
            drawer.currentUnloadMenuElements(for: webPanel.id).first as? UIAction
        )
        XCTAssertEqual(
            drawer.currentUnloadMenuElements(for: webPanel.id)
                .compactMap { ($0 as? UIAction)?.title },
            [FloorpStrings.Drawer.webPanelUnload]
        )
        XCTAssertTrue(drawer.currentUnloadMenuElements(for: otherWebPanel.id).isEmpty)
        XCTAssertEqual(
            webPanelButton.accessibilityCustomActions?.map(\.name),
            [
                FloorpStrings.Drawer.webPanelUnload,
                FloorpStrings.Drawer.webPanelPauseMedia,
                String.LegacyAppMenu.AppMenuViewDesktopSiteTitleString,
                FloorpStrings.Drawer.webPanelZoomIn,
                FloorpStrings.Drawer.webPanelZoomOut,
            ]
        )
        XCTAssertNil(otherWebPanelButton.accessibilityCustomActions)
        XCTAssertFalse(drawer.unloadWebPanelIfActive(panelID: otherWebPanel.id))
        XCTAssertEqual(first.invalidationCount, 0)

        let unloadAccessibilityAction = try XCTUnwrap(
            webPanelButton.accessibilityCustomActions?.first
        )
        XCTAssertTrue(unloadAccessibilityAction.actionHandler?(unloadAccessibilityAction) == true)

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
        XCTAssertTrue(drawer.currentUnloadMenuElements(for: webPanel.id).isEmpty)
        XCTAssertNil(webPanelButton.accessibilityCustomActions)
        let staleMenuActionSender = UIButton(type: .system)
        staleMenuActionSender.addAction(unloadMenuAction, for: .touchUpInside)
        staleMenuActionSender.sendActions(for: .touchUpInside)
        XCTAssertEqual(first.invalidationCount, 1)

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

        let activeMenuAction = try XCTUnwrap(
            drawer.currentUnloadMenuElements(for: webPanel.id).first as? UIAction
        )
        let activeMenuActionSender = UIButton(type: .system)
        activeMenuActionSender.addAction(activeMenuAction, for: .touchUpInside)
        activeMenuActionSender.sendActions(for: .touchUpInside)

        XCTAssertEqual(restored.invalidationCount, 1)
        XCTAssertNotNil(
            findLabel(text: FloorpStrings.Drawer.webPanelUnloaded, in: drawer.view)
        )
        XCTAssertTrue(drawer.currentUnloadMenuElements(for: webPanel.id).isEmpty)
        XCTAssertNil(webPanelButton.accessibilityCustomActions)
    }

    func testExplicitUnloadSurvivesDrawerRecreationUntilExactPanelReselection() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let firstDrawer = fixture.makeDrawer(isPrivate: false)
        firstDrawer.loadViewIfNeeded()
        let webPanel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let key = FloorpWebPanelSessionKey(
            windowUUID: fixture.presentationState.windowUUID,
            panelID: webPanel.id,
            isPrivate: false
        )

        XCTAssertTrue(firstDrawer.unloadWebPanelIfActive(panelID: webPanel.id))
        XCTAssertTrue(fixture.presentationState.isWebPanelExplicitlyUnloaded(key))
        XCTAssertEqual(fixture.factory.makeCallCount, 1)

        let replacementDrawer = fixture.makeDrawer(isPrivate: false)
        replacementDrawer.loadViewIfNeeded()

        XCTAssertEqual(fixture.factory.makeCallCount, 1)
        XCTAssertNotNil(
            findLabel(
                text: FloorpStrings.Drawer.webPanelUnloaded,
                in: replacementDrawer.view
            )
        )
        XCTAssertTrue(replacementDrawer.currentUnloadMenuElements(for: webPanel.id).isEmpty)

        let webPanelButton = try XCTUnwrap(
            findView(identifier: webPanel.id, in: replacementDrawer.view) as? UIButton
        )
        webPanelButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(fixture.presentationState.isWebPanelExplicitlyUnloaded(key))
        XCTAssertEqual(fixture.factory.makeCallCount, 2)
        XCTAssertEqual(
            fixture.factory.sessions.last?.contentView?.superview?.accessibilityIdentifier,
            "Floorp.Drawer.WebPanelContent"
        )
    }

    func testReselectionClearsOnlyExactPrivacyMarkerAndRestoresEachMode() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let privacyMode = FloorpMutableWebPanelPrivacyMode(false)
        let drawer = fixture.makeDrawer(isPrivateProvider: { privacyMode.value })
        drawer.loadViewIfNeeded()
        let webPanel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let regularKey = FloorpWebPanelSessionKey(
            windowUUID: fixture.presentationState.windowUUID,
            panelID: webPanel.id,
            isPrivate: false
        )
        let privateKey = FloorpWebPanelSessionKey(
            windowUUID: fixture.presentationState.windowUUID,
            panelID: webPanel.id,
            isPrivate: true
        )
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/regular-current"))
        fixture.factory.sessions.first?.recordRuntimeState(
            currentURL: currentURL,
            pageTitle: "Regular"
        )
        XCTAssertTrue(drawer.unloadWebPanelIfActive(panelID: webPanel.id))
        fixture.presentationState.markWebPanelExplicitlyUnloaded(privateKey)
        let webPanelButton = try XCTUnwrap(
            findView(identifier: webPanel.id, in: drawer.view) as? UIButton
        )

        webPanelButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(fixture.presentationState.isWebPanelExplicitlyUnloaded(regularKey))
        XCTAssertTrue(fixture.presentationState.isWebPanelExplicitlyUnloaded(privateKey))
        XCTAssertEqual(fixture.factory.sessions.last?.restorationURL, currentURL)

        privacyMode.value = true
        drawer.rebindActiveContent(forSelectedTabIsPrivate: true)

        XCTAssertEqual(fixture.factory.makeCallCount, 2)
        XCTAssertNotNil(findLabel(text: FloorpStrings.Drawer.webPanelUnloaded, in: drawer.view))
        XCTAssertNil(webPanelButton.accessibilityCustomActions)

        webPanelButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(fixture.presentationState.isWebPanelExplicitlyUnloaded(privateKey))
        XCTAssertEqual(fixture.factory.makeCallCount, 3)
        XCTAssertEqual(fixture.factory.sessions.last?.key, privateKey)
        XCTAssertEqual(
            webPanelButton.accessibilityCustomActions?.map(\.name),
            [
                FloorpStrings.Drawer.webPanelUnload,
                FloorpStrings.Drawer.webPanelPauseMedia,
                String.LegacyAppMenu.AppMenuViewDesktopSiteTitleString,
                FloorpStrings.Drawer.webPanelZoomIn,
                FloorpStrings.Drawer.webPanelZoomOut,
            ]
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

    func testRuntimeTeardownClearsMarkerOnlyDrawerStateAndShowsUnavailable() throws {
        let fixture = try makeDrawerFixture()
        defer { fixture.cleanup() }
        let drawer = fixture.makeDrawer(isPrivate: false)
        drawer.loadViewIfNeeded()
        let webPanel = try XCTUnwrap(fixture.manager.panels.first(where: { $0.type == .web }))
        let key = FloorpWebPanelSessionKey(
            windowUUID: fixture.presentationState.windowUUID,
            panelID: webPanel.id,
            isPrivate: false
        )
        XCTAssertTrue(drawer.unloadWebPanelIfActive(panelID: webPanel.id))
        XCTAssertTrue(fixture.presentationState.isWebPanelExplicitlyUnloaded(key))
        XCTAssertTrue(fixture.presentationState.attach(drawer))

        fixture.presentationState.invalidateWebPanelRuntime()

        XCTAssertFalse(fixture.presentationState.isWebPanelExplicitlyUnloaded(key))
        XCTAssertNil(findLabel(text: FloorpStrings.Drawer.webPanelUnloaded, in: drawer.view))
        XCTAssertNotNil(findLabel(text: FloorpStrings.Drawer.webPanelUnavailable, in: drawer.view))
        XCTAssertNil(fixture.presentationState.webPanelSessionStore)
    }

    private func zoomMenu(
        in drawer: FloorpOverlayDrawerViewController,
        panelID: String
    ) throws -> UIMenu {
        try XCTUnwrap(drawer.currentZoomMenuElements(for: panelID).first as? UIMenu)
    }

    private func zoomAction(_ title: String, in menu: UIMenu) throws -> UIAction {
        try XCTUnwrap(menu.children.first(where: { ($0 as? UIAction)?.title == title }) as? UIAction)
    }

    private func invoke(_ action: UIAction) {
        let sender = UIButton(type: .system)
        sender.addAction(action, for: .touchUpInside)
        sender.sendActions(for: .touchUpInside)
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

    private func waitForPresentationState(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
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
    let sessionIdentifier = UUID()
    let restorationURL: URL?
    private(set) var state: FloorpWebPanelSessionState
    private(set) var configurationUpdateCount = 0
    private(set) var invalidationCount = 0
    private(set) var loadHomeCallCount = 0
    private(set) var goBackCallCount = 0
    private(set) var goForwardCallCount = 0
    private(set) var reloadCallCount = 0
    private(set) var contentModeReloadCount = 0
    private(set) var contentModeEvents = [String]()
    private(set) var stopLoadingCallCount = 0
    private(set) var openInMainBrowserCallCount = 0
    private(set) var visibilityChanges = [Bool]()
    var mediaPauseError: Error?
    private let hostedContentView = UIView()
    private var stateObservers = [UUID: @MainActor (FloorpWebPanelSessionState) -> Void]()
    private(set) var isVisible = true
    private var latestRuntimeURL: URL?
    private var hasLatestRuntimeURL = false
    private var pendingRestorationCandidateURL: URL?
    private var loadedContentMode: FloorpWebPanelContentMode
    private var hasPendingContentModeReload = false
    let findTargetMock = MockFloorpWebPanelFindTarget()

    var contentView: UIView? { invalidationCount == 0 ? hostedContentView : nil }
    var findTarget: (any FloorpWebPanelFindTarget)? {
        invalidationCount == 0 ? findTargetMock : nil
    }
    var stateObserverCount: Int { stateObservers.count }
    var isContentModeReloadPending: Bool { hasPendingContentModeReload }

    init(
        key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration,
        restorationURL: URL?
    ) {
        self.key = key
        self.restorationURL = restorationURL
        self.state = FloorpWebPanelSessionState(configuration: configuration)
        self.loadedContentMode = configuration.contentMode
        self.pendingRestorationCandidateURL = restorationURL
    }

    func updateConfiguration(_ configuration: FloorpWebPanelSessionConfiguration) {
        let previousContentMode = state.configuration.contentMode
        state.configuration = configuration
        configurationUpdateCount += 1
        if previousContentMode != configuration.contentMode {
            contentModeEvents.append("executor-\(configuration.contentMode.rawValue)")
            if state.currentURL != nil {
                hasPendingContentModeReload = loadedContentMode != configuration.contentMode
            } else {
                loadedContentMode = configuration.contentMode
                hasPendingContentModeReload = false
            }
        }
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
        } else {
            applyPendingContentModeReload()
        }
    }

    @discardableResult
    func applyPendingContentModeReload() -> Bool {
        guard isVisible, hasPendingContentModeReload, state.currentURL != nil else {
            return false
        }
        findTargetMock.endFindSession()
        contentModeEvents.append("find-ended")
        loadedContentMode = state.configuration.contentMode
        hasPendingContentModeReload = false
        contentModeReloadCount += 1
        contentModeEvents.append("reload-from-origin")
        return true
    }

    @discardableResult
    func setUserMediaPaused(
        _ isUserMediaPaused: Bool,
        completion: @escaping FloorpWebPanelMediaPauseCompletion
    ) -> Bool {
        guard invalidationCount == 0, state.isUserMediaPaused != isUserMediaPaused else { return false }
        let previousIsUserMediaPaused = state.isUserMediaPaused
        state.isUserMediaPaused = isUserMediaPaused
        state.userMediaStateRevision += 1
        notifyStateObservers()
        if let mediaPauseError {
            state.isUserMediaPaused = previousIsUserMediaPaused
            state.userMediaStateRevision += 1
            notifyStateObservers()
            completion(.failure(mediaPauseError))
        } else {
            completion(.success(()))
        }
        return true
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
private final class FloorpMutableWebPanelPresentationMode {
    var value: FloorpPanelPresentationMode

    init(_ value: FloorpPanelPresentationMode) {
        self.value = value
    }
}

@MainActor
private final class FloorpMutableWebPanelPrivacyMode {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
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
        makeDrawer(
            isPrivateProvider: { isPrivate },
            webPanelZoomMutation: nil,
            webPanelContentModeMutation: nil
        )
    }

    func makeDrawer(
        isPrivateProvider: @escaping @MainActor () -> Bool,
        webPanelZoomMutation: FloorpWebPanelZoomMutation? = nil,
        webPanelContentModeMutation: FloorpWebPanelContentModeMutation? = nil
    ) -> FloorpOverlayDrawerViewController {
        FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: .shared,
            presentationState: presentationState,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            isPrivateProvider: isPrivateProvider,
            webPanelZoomMutation: webPanelZoomMutation,
            webPanelContentModeMutation: webPanelContentModeMutation
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

    func releaseSession(identifier: UUID) {
        sessions.removeAll { $0.sessionIdentifier == identifier }
    }

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
