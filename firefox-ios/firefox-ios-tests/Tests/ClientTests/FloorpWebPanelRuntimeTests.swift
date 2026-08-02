// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
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

        store.closePrivateSessions()

        XCTAssertEqual(regular.invalidationCount, 0)
        XCTAssertEqual(privateSession.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionCount, 1)
        let reusedRegular = try mockSession(from: store.session(for: panel, isPrivate: false))
        let replacementPrivate = try mockSession(from: store.session(for: panel, isPrivate: true))
        XCTAssertTrue(regular === reusedRegular)
        XCTAssertFalse(privateSession === replacementPrivate)
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
        let store = FloorpWebPanelSessionStore(windowUUID: UUID(), factory: factory)
        factory.keyOverride = FloorpWebPanelSessionKey(
            windowUUID: UUID(),
            panelID: "wrong-panel",
            isPrivate: false
        )

        XCTAssertThrowsError(try store.session(for: makePanel(id: "portal"), isPrivate: false)) { error in
            XCTAssertEqual(error as? FloorpWebPanelSessionStoreError, .factoryReturnedMismatchedKey)
        }
        XCTAssertEqual(factory.sessions.first?.invalidationCount, 1)
        XCTAssertEqual(store.cachedSessionCount, 0)
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
final class FloorpWebPanelDrawerRuntimeTests: XCTestCase {
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

        let reopenedRegularDrawer = fixture.makeDrawer(isPrivate: false)
        reopenedRegularDrawer.loadViewIfNeeded()
        XCTAssertEqual(fixture.factory.makeCallCount, 1)
        XCTAssertTrue(fixture.factory.sessions.first === regularSession)
        XCTAssertEqual(regularSession.stateObserverCount, 1)

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
    private(set) var state: FloorpWebPanelSessionState
    private(set) var configurationUpdateCount = 0
    private(set) var invalidationCount = 0
    private let hostedContentView = UIView()
    private var stateObservers = [UUID: @MainActor (FloorpWebPanelSessionState) -> Void]()

    var contentView: UIView? { hostedContentView }
    var stateObserverCount: Int { stateObservers.count }

    init(
        key: FloorpWebPanelSessionKey,
        configuration: FloorpWebPanelSessionConfiguration
    ) {
        self.key = key
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

    func recordRuntimeState(currentURL: URL, pageTitle: String) {
        state.currentURL = currentURL
        state.pageTitle = pageTitle
        state.canGoBack = true
        state.isLoading = true
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
        FloorpOverlayDrawerViewController(
            panelManager: manager,
            notesStore: .shared,
            presentationState: presentationState,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter(),
            isPrivateProvider: { isPrivate }
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
        configuration: FloorpWebPanelSessionConfiguration
    ) throws -> any FloorpWebPanelSessionProtocol {
        makeCallCount += 1
        if let errorToThrow {
            throw errorToThrow
        }
        let session = MockFloorpWebPanelSession(
            key: keyOverride ?? key,
            configuration: configuration
        )
        sessions.append(session)
        return session
    }
}
