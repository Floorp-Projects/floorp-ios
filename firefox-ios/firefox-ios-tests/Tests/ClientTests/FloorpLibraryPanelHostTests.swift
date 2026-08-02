// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import XCTest

@testable import Client

@MainActor
final class FloorpLibraryPanelHostTests: XCTestCase {
    private var profile: MockProfile?
    private var tabManager: MockTabManager?
    private var actionDelegate: MockLibraryCoordinatorDelegate?

    override func setUp() async throws {
        try await super.setUp()
        DependencyHelperMock().bootstrapDependencies()
        profile = MockProfile()
        tabManager = MockTabManager(windowUUID: WindowUUID())
        actionDelegate = MockLibraryCoordinatorDelegate()
    }

    override func tearDown() async throws {
        profile?.shutdown()
        await drainMainQueue()
        profile = nil
        tabManager = nil
        actionDelegate = nil
        DependencyHelperMock().reset()
        try await super.tearDown()
    }

    func testSelectPreservesEachNativePanelNavigationStack() throws {
        let subject = try createSubject()

        XCTAssertTrue(subject.select(panelType: .bookmarks))
        let libraryViewController = try libraryViewController(from: subject)
        let bookmarksNavigationController = try XCTUnwrap(libraryViewController.childPanelControllers.first)
        let marker = FloorpMockLibraryPanel()
        bookmarksNavigationController.pushViewController(marker, animated: false)

        XCTAssertTrue(subject.select(panelType: .history))
        XCTAssertTrue(subject.select(panelType: .bookmarks))
        XCTAssertTrue(bookmarksNavigationController.topViewController === marker)
    }

    func testPushedBookmarkEditorBlocksExternalPanelSwitchingAndDismissal() throws {
        let subject = try createSubject()
        XCTAssertTrue(subject.select(panelType: .bookmarks))
        let libraryViewController = try libraryViewController(from: subject)
        let bookmarksNavigationController = try XCTUnwrap(libraryViewController.childPanelControllers.first)
        let editor = UIViewController()
        bookmarksNavigationController.pushViewController(editor, animated: false)

        XCTAssertFalse(subject.allowsPanelSwitching)
        XCTAssertFalse(subject.select(panelType: .history))
        XCTAssertEqual(subject.selectedPanelType, .bookmarks)
        XCTAssertEqual(subject.prepareForDrawerDismissal(), .blocked)

        bookmarksNavigationController.popViewController(animated: false)

        XCTAssertTrue(subject.allowsPanelSwitching)
        XCTAssertTrue(subject.select(panelType: .history))
    }

    func testBookmarkEditModeBlocksExternalPanelSwitchingAndDismissal() throws {
        let subject = try createSubject()
        XCTAssertTrue(subject.select(panelType: .bookmarks))
        let libraryViewController = try libraryViewController(from: subject)
        let bookmarksPanel = try XCTUnwrap(
            libraryViewController.childPanelControllers.first?.viewControllers.first as? BookmarksViewController
        )
        bookmarksPanel.state = .bookmarks(state: .inFolderEditMode)

        XCTAssertFalse(subject.allowsPanelSwitching)
        XCTAssertFalse(subject.select(panelType: .history))
        XCTAssertEqual(subject.selectedPanelType, .bookmarks)
        XCTAssertEqual(subject.prepareForDrawerDismissal(), .blocked)
    }

    func testHistorySearchPreservesStateAcrossSwitchAndConsumesFirstDismissalRequest() throws {
        let subject = try createSubject()
        XCTAssertTrue(subject.select(panelType: .history))
        let libraryViewController = try libraryViewController(from: subject)
        let historyPanel = try XCTUnwrap(
            libraryViewController.childPanelControllers[LibraryPanelType.history.rawValue]
                .viewControllers.first as? HistoryPanel
        )
        historyPanel.state = .history(state: .search)

        XCTAssertTrue(subject.allowsPanelSwitching)
        XCTAssertTrue(subject.select(panelType: .bookmarks))
        XCTAssertTrue(subject.select(panelType: .history))
        XCTAssertEqual(historyPanel.state, .history(state: .search))

        XCTAssertEqual(subject.prepareForDrawerDismissal(), .consumed)
        XCTAssertNotEqual(historyPanel.state, .history(state: .search))
        XCTAssertEqual(subject.prepareForDrawerDismissal(), .allow)
    }

    func testPresentedViewControllerBlocksExternalPanelSwitchingAndDismissal() throws {
        let subject = try createSubject()
        XCTAssertTrue(subject.select(panelType: .bookmarks))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = subject.viewController
        window.makeKeyAndVisible()
        defer {
            subject.viewController.dismiss(animated: false)
            window.rootViewController = nil
            window.isHidden = true
        }
        subject.viewController.present(UIViewController(), animated: false)

        XCTAssertFalse(subject.allowsPanelSwitching)
        XCTAssertFalse(subject.select(panelType: .history))
        XCTAssertEqual(subject.prepareForDrawerDismissal(), .blocked)
    }

    func testLibraryActionsPreserveVisitTypeAndPrivateChoice() throws {
        let subject = try createSubject()
        let actionDelegate = try XCTUnwrap(actionDelegate)
        let url = URL(string: "https://example.com")!

        subject.libraryPanel(didSelectURL: url, visitType: .bookmark)
        subject.libraryPanelDidRequestToOpenInNewTab(url, isPrivate: true)
        subject.openRecentlyClosedSiteInNewTab(url, isPrivate: true)

        XCTAssertTrue(actionDelegate.didSelectURLCalled)
        XCTAssertEqual(actionDelegate.lastVisitType, .bookmark)
        XCTAssertTrue(actionDelegate.didRequestToOpenInNewTabCalled)
        XCTAssertTrue(actionDelegate.isPrivate)
        XCTAssertEqual(actionDelegate.didOpenRecentlyClosedSiteInNewTab, 1)
        XCTAssertTrue(actionDelegate.recentlyClosedIsPrivate)
    }

    func testExternalDoneRequestsDrawerDismissal() throws {
        let subject = try createSubject()
        XCTAssertTrue(subject.select(panelType: .bookmarks))
        var dismissCount = 0
        subject.onRequestDrawerDismiss = { dismissCount += 1 }

        try libraryViewController(from: subject).topRightButtonAction()

        XCTAssertEqual(dismissCount, 1)
    }

    func testExternalSwitcherDoesNotInstallInternalSegmentControl() throws {
        let subject = try createSubject()
        XCTAssertTrue(subject.select(panelType: .bookmarks))
        let libraryViewController = try libraryViewController(from: subject)
        libraryViewController.loadViewIfNeeded()

        XCTAssertFalse(libraryViewController.view.containsSubview(ofType: UISegmentedControl.self))
    }

    func testLibraryNotificationsOnlyUpdateTheirOwningWindow() throws {
        let subject = try createSubject()
        let tabManager = try XCTUnwrap(tabManager)
        XCTAssertTrue(subject.select(panelType: .bookmarks))
        let libraryViewController = try libraryViewController(from: subject)
        let originalTitle = libraryViewController.navigationItem.title
        var foreignUserInfo = WindowUUID().userInfo
        foreignUserInfo["title"] = "Foreign"

        libraryViewController.handleNotifications(
            Notification(name: .LibraryPanelBookmarkTitleChanged, userInfo: foreignUserInfo)
        )
        XCTAssertEqual(libraryViewController.navigationItem.title, originalTitle)

        var localUserInfo = tabManager.windowUUID.userInfo
        localUserInfo["title"] = "Local"
        libraryViewController.handleNotifications(
            Notification(name: .LibraryPanelBookmarkTitleChanged, userInfo: localUserInfo)
        )
        XCTAssertEqual(libraryViewController.navigationItem.title, "Local")
    }

    private func createSubject() throws -> FloorpLibraryPanelHost {
        try FloorpLibraryPanelHost(
            profile: XCTUnwrap(profile),
            tabManager: XCTUnwrap(tabManager),
            actionDelegate: XCTUnwrap(actionDelegate),
            themeManager: MockThemeManager(),
            notificationCenter: NotificationCenter.default,
            bookmarksHandler: MockBookmarksHandler()
        )
    }

    private func libraryViewController(
        from subject: FloorpLibraryPanelHost
    ) throws -> LibraryViewController {
        let navigationController = try XCTUnwrap(subject.viewController as? UINavigationController)
        return try XCTUnwrap(navigationController.viewControllers.first as? LibraryViewController)
    }
}

@MainActor
final class FloorpLibraryRegressionTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DependencyHelperMock().bootstrapDependencies()
    }

    override func tearDown() async throws {
        await drainMainQueue()
        DependencyHelperMock().reset()
        try await super.tearDown()
    }

    func testDefaultLibraryPresentationRemainsModalWithInternalSwitcher() throws {
        let profile = MockProfile()
        defer { profile.shutdown() }
        let router = MockRouter(navigationController: MockNavigationController())
        let subject = LibraryCoordinator(
            router: router,
            profile: profile,
            tabManager: MockTabManager(),
            bookmarksHandler: MockBookmarksHandler()
        )
        let libraryViewController = try XCTUnwrap(subject.libraryViewController)

        libraryViewController.loadViewIfNeeded()
        libraryViewController.viewWillAppear(false)

        XCTAssertEqual(libraryViewController.presentationMode, .modal)
        XCTAssertTrue(libraryViewController.view.containsSubview(ofType: UISegmentedControl.self))
    }

    func testRecentlyClosedTabPreservesPrivateMode() throws {
        let profile = MockProfile()
        defer { profile.shutdown() }
        let tabManager = MockTabManager()
        DependencyHelperMock().reset()
        DependencyHelperMock().bootstrapDependencies(injectedTabManager: tabManager)
        let subject = BrowserViewController(
            profile: profile,
            tabManager: tabManager,
            appStartupTelemetry: MockAppStartupTelemetry(),
            recordVisitManager: MockRecordVisitObservationManager()
        )

        subject.openRecentlyClosedSiteInNewTab(
            URL(string: "https://example.com")!,
            isPrivate: true
        )

        let selectedTab = try XCTUnwrap(tabManager.selectedTab)
        XCTAssertTrue(tabManager.addTabWasCalled)
        XCTAssertTrue(selectedTab.isPrivate)
    }

    func testHistoryNotificationsOnlyAffectTheirOwningWindow() {
        let profile = MockProfile()
        defer { profile.shutdown() }
        let notificationCenter = MockNotificationCenter()
        let windowUUID = WindowUUID()
        let panel = HistoryPanel(
            profile: profile,
            windowUUID: windowUUID,
            notificationCenter: notificationCenter
        )
        let delegate = FloorpMockHistoryCoordinatorDelegate()
        panel.historyCoordinatorDelegate = delegate
        panel.loadViewIfNeeded()

        panel.handleNotifications(
            Notification(name: .OpenRecentlyClosedTabs, userInfo: WindowUUID().userInfo)
        )
        XCTAssertEqual(delegate.showRecentlyClosedTabCallCount, 0)

        panel.handleNotifications(
            Notification(name: .OpenRecentlyClosedTabs, userInfo: windowUUID.userInfo)
        )
        XCTAssertEqual(delegate.showRecentlyClosedTabCallCount, 1)
    }

    func testHistoryCoordinatorOnlyClearsItsOwningWindow() {
        let profile = MockProfile()
        defer { profile.shutdown() }
        let notificationCenter = MockNotificationCenter()
        let windowUUID = WindowUUID()
        let router = MockRouter(navigationController: MockNavigationController())
        let historyPanel = FloorpMockHistoryPanel(
            profile: profile,
            windowUUID: windowUUID,
            notificationCenter: notificationCenter
        )
        router.rootViewController = historyPanel
        let subject = HistoryCoordinator(
            profile: profile,
            windowUUID: windowUUID,
            router: router,
            notificationCenter: notificationCenter,
            parentCoordinator: nil,
            navigationHandler: nil
        )

        subject.handleNotifications(
            Notification(name: .OpenClearRecentHistory, userInfo: WindowUUID().userInfo)
        )
        XCTAssertEqual(historyPanel.showClearRecentHistoryCallCount, 0)

        subject.handleNotifications(
            Notification(name: .OpenClearRecentHistory, userInfo: windowUUID.userInfo)
        )
        XCTAssertEqual(historyPanel.showClearRecentHistoryCallCount, 1)
    }
}

@MainActor
final class FloorpNativeLibraryDrawerTests: XCTestCase {
    func testNativePanelsReuseHostAndNotesDetachesIt() throws {
        let resources = try makeResources()
        defer { resources.cleanUp() }
        let nativeHost = MockFloorpLibraryPanelHost()
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        let bookmarks = try XCTUnwrap(resources.panelManager.panel(for: "floorp//bookmarks"))
        state.select(bookmarks)
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: resources.panelManager,
            notesStore: FloorpNotesStore(fileURL: resources.notesURL),
            presentationState: state,
            libraryPanelHost: nativeHost,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter()
        )
        let owner = UIViewController()
        owner.loadViewIfNeeded()
        owner.addChild(drawer)
        owner.view.addSubview(drawer.view)
        drawer.didMove(toParent: owner)

        XCTAssertTrue(nativeHost.viewController.parent === drawer)
        XCTAssertEqual(nativeHost.selections, [.bookmarks])
        XCTAssertFalse(try nativeContent(in: drawer).isHidden)
        XCTAssertTrue(try legacyContent(in: drawer).isHidden)

        let historyButton = try XCTUnwrap(
            drawer.view.findSubview(accessibilityIdentifier: "floorp//history") as? UIButton
        )
        historyButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(nativeHost.selections, [.bookmarks, .history])
        XCTAssertTrue(nativeHost.viewController.parent === drawer)

        let notesButton = try XCTUnwrap(
            drawer.view.findSubview(accessibilityIdentifier: "floorp//notes") as? UIButton
        )
        notesButton.sendActions(for: .touchUpInside)
        XCTAssertNil(nativeHost.viewController.parent)
        XCTAssertTrue(try nativeContent(in: drawer).isHidden)
        XCTAssertFalse(try legacyContent(in: drawer).isHidden)
    }

    func testBlockedHostPreventsRailSelection() throws {
        let resources = try makeResources()
        defer { resources.cleanUp() }
        let nativeHost = MockFloorpLibraryPanelHost()
        nativeHost.allowsPanelSwitching = false
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        state.select(try XCTUnwrap(resources.panelManager.panel(for: "floorp//bookmarks")))
        let drawer = FloorpOverlayDrawerViewController(
            panelManager: resources.panelManager,
            notesStore: FloorpNotesStore(fileURL: resources.notesURL),
            presentationState: state,
            libraryPanelHost: nativeHost,
            themeManager: MockThemeManager(),
            notificationCenter: MockNotificationCenter()
        )
        drawer.loadViewIfNeeded()

        let historyButton = try XCTUnwrap(
            drawer.view.findSubview(accessibilityIdentifier: "floorp//history") as? UIButton
        )
        historyButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(state.selectedPanelId, "floorp//bookmarks")
        XCTAssertEqual(nativeHost.selections, [.bookmarks])
    }

    func testBlockedHostPreventsLocalRegistryMutations() throws {
        let resources = try makeResources()
        defer { resources.cleanUp() }
        let nativeHost = MockFloorpLibraryPanelHost()
        nativeHost.allowsPanelSwitching = false
        let state = FloorpPanelPresentationState(windowUUID: .XCTestDefaultUUID)
        let bookmarks = try XCTUnwrap(resources.panelManager.panel(for: "floorp//bookmarks"))
        state.select(bookmarks)
        let drawer = makeDrawer(
            resources: resources,
            state: state,
            nativeHost: nativeHost,
            notificationCenter: MockNotificationCenter()
        )
        drawer.loadViewIfNeeded()
        let originalPanelIDs = resources.panelManager.panels.map(\.id)

        drawer.movePanel(id: bookmarks.id, offset: 1)
        drawer.requestPanelRemoval(id: bookmarks.id)
        drawer.presentPanelRegistry()

        XCTAssertEqual(resources.panelManager.panels.map(\.id), originalPanelIDs)
        XCTAssertNil(drawer.presentedViewController)
    }

    func testForeignRegistryRemovalDefersFallbackUntilBookmarkEditEnds() throws {
        let resources = try makeResources()
        defer { resources.cleanUp() }
        let nativeHost = MockFloorpLibraryPanelHost()
        nativeHost.allowsPanelSwitching = false
        let windowUUID = WindowUUID()
        let state = FloorpPanelPresentationState(windowUUID: windowUUID)
        let bookmarks = try XCTUnwrap(resources.panelManager.panel(for: "floorp//bookmarks"))
        state.select(bookmarks)
        let drawer = makeDrawer(
            resources: resources,
            state: state,
            nativeHost: nativeHost,
            notificationCenter: NotificationCenter.default
        )
        drawer.loadViewIfNeeded()

        try resources.panelManager.removePanel(id: bookmarks.id)

        XCTAssertEqual(state.selectedPanelId, bookmarks.id)
        XCTAssertEqual(nativeHost.selections, [.bookmarks])
        XCTAssertTrue(nativeHost.viewController.parent === drawer)

        nativeHost.allowsPanelSwitching = true
        NotificationCenter.default.post(
            name: .LibraryPanelStateDidChange,
            object: nil,
            userInfo: windowUUID.userInfo
        )

        let fallbackPanel = try XCTUnwrap(resources.panelManager.panels.first)
        XCTAssertEqual(state.selectedPanelId, fallbackPanel.id)
        XCTAssertEqual(nativeHost.selections, [.bookmarks, fallbackPanel.type])
        XCTAssertTrue(nativeHost.viewController.parent === drawer)
    }

    func testForeignRegistryRemovalRetriesFallbackAfterPresentedWorkflowEnds() async throws {
        let resources = try makeResources()
        defer { resources.cleanUp() }
        let nativeHost = MockFloorpLibraryPanelHost()
        nativeHost.allowsPanelSwitching = false
        let fallbackApplied = expectation(description: "Deferred registry fallback applied")
        nativeHost.onSelection = { panelType in
            guard panelType != .bookmarks else { return }
            fallbackApplied.fulfill()
        }
        let state = FloorpPanelPresentationState(windowUUID: WindowUUID())
        let bookmarks = try XCTUnwrap(resources.panelManager.panel(for: "floorp//bookmarks"))
        state.select(bookmarks)
        let drawer = makeDrawer(
            resources: resources,
            state: state,
            nativeHost: nativeHost,
            notificationCenter: NotificationCenter.default,
            registryFallbackRetryDelayNanoseconds: 1_000_000
        )
        drawer.loadViewIfNeeded()

        try resources.panelManager.removePanel(id: bookmarks.id)

        XCTAssertEqual(state.selectedPanelId, bookmarks.id)
        nativeHost.allowsPanelSwitching = true
        await fulfillment(of: [fallbackApplied], timeout: 1)

        let fallbackPanel = try XCTUnwrap(resources.panelManager.panels.first)
        XCTAssertEqual(state.selectedPanelId, fallbackPanel.id)
        XCTAssertEqual(nativeHost.selections, [.bookmarks, fallbackPanel.type])
        XCTAssertTrue(nativeHost.viewController.parent === drawer)
    }

    private func nativeContent(in drawer: FloorpOverlayDrawerViewController) throws -> UIView {
        try XCTUnwrap(
            drawer.view.findSubview(accessibilityIdentifier: "Floorp.Drawer.NativeLibraryContent")
        )
    }

    private func legacyContent(in drawer: FloorpOverlayDrawerViewController) throws -> UIView {
        try XCTUnwrap(drawer.view.findSubview(accessibilityIdentifier: "Floorp.Drawer.Content"))
    }

    private func makeResources() throws -> FloorpDrawerTestResources {
        let suiteName = "FloorpNativeLibraryDrawerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let notesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpNativeLibraryDrawerTests-\(UUID().uuidString).json")
        return FloorpDrawerTestResources(
            suiteName: suiteName,
            panelManager: FloorpPanelManager(defaults: defaults),
            notesURL: notesURL
        )
    }

    private func makeDrawer(
        resources: FloorpDrawerTestResources,
        state: FloorpPanelPresentationState,
        nativeHost: MockFloorpLibraryPanelHost,
        notificationCenter: NotificationProtocol,
        registryFallbackRetryDelayNanoseconds: UInt64 = 250_000_000
    ) -> FloorpOverlayDrawerViewController {
        FloorpOverlayDrawerViewController(
            panelManager: resources.panelManager,
            notesStore: FloorpNotesStore(fileURL: resources.notesURL),
            presentationState: state,
            libraryPanelHost: nativeHost,
            themeManager: MockThemeManager(),
            notificationCenter: notificationCenter,
            registryFallbackRetryDelayNanoseconds: registryFallbackRetryDelayNanoseconds
        )
    }
}

@MainActor
private final class MockFloorpLibraryPanelHost: FloorpLibraryPanelHosting {
    let viewController = UIViewController()
    var selectedPanelType: FloorpPanelType?
    var allowsPanelSwitching = true
    var onRequestDrawerDismiss: (() -> Void)?
    var dismissalDisposition = FloorpLibraryPanelDismissalDisposition.allow
    var selections = [FloorpPanelType]()
    var onSelection: ((FloorpPanelType) -> Void)?

    func select(panelType: FloorpPanelType) -> Bool {
        guard allowsPanelSwitching || selectedPanelType == nil || selectedPanelType == panelType else {
            return false
        }
        selectedPanelType = panelType
        selections.append(panelType)
        onSelection?(panelType)
        return true
    }

    func prepareForDrawerDismissal() -> FloorpLibraryPanelDismissalDisposition {
        dismissalDisposition
    }
}

@MainActor
private final class FloorpMockLibraryPanel: UIViewController, LibraryPanel {
    weak var libraryPanelDelegate: LibraryPanelDelegate?
    var state = LibraryPanelMainState.bookmarks(state: .inFolder)
    var isTransitioning = false
    var bottomToolbarItems = [UIBarButtonItem]()
}

private final class FloorpMockHistoryCoordinatorDelegate: HistoryCoordinatorDelegate {
    var showRecentlyClosedTabCallCount = 0

    func showRecentlyClosedTab() {
        showRecentlyClosedTabCallCount += 1
    }

    func shareLibraryItem(url: URL, sourceView: UIView) {}
}

private final class FloorpMockHistoryPanel: HistoryPanel {
    var showClearRecentHistoryCallCount = 0

    override func showClearRecentHistory() {
        showClearRecentHistoryCallCount += 1
    }
}

private struct FloorpDrawerTestResources {
    let suiteName: String
    let panelManager: FloorpPanelManager
    let notesURL: URL

    func cleanUp() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: notesURL)
    }
}

private extension UIView {
    func containsSubview<T: UIView>(ofType type: T.Type) -> Bool {
        if self is T { return true }
        return subviews.contains { $0.containsSubview(ofType: type) }
    }

    func findSubview(accessibilityIdentifier: String) -> UIView? {
        if self.accessibilityIdentifier == accessibilityIdentifier {
            return self
        }
        return subviews.lazy.compactMap {
            $0.findSubview(accessibilityIdentifier: accessibilityIdentifier)
        }.first
    }
}

@MainActor
private func drainMainQueue() async {
    for _ in 0..<3 {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
