// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Storage
import WebEngine
import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebPanelWebViewSessionTests: XCTestCase {
    func testConfigurationUsesSharedDefaultAndPrivateDataStores() {
        let provider = DefaultFloorpWebPanelWebViewConfigurationProvider(profile: MockProfile())

        let firstRegular = provider.configuration(isPrivate: false)
        let secondRegular = provider.configuration(isPrivate: false)
        let firstPrivate = provider.configuration(isPrivate: true)
        let secondPrivate = provider.configuration(isPrivate: true)

        XCTAssertTrue(firstRegular.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(firstRegular.websiteDataStore === secondRegular.websiteDataStore)
        XCTAssertFalse(firstPrivate.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(firstPrivate.websiteDataStore === secondPrivate.websiteDataStore)
    }

    func testDefaultRuntimeOwnsTabWebViewAndReleasesItOnInvalidate() throws {
        let profile = MockProfile()
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(injectedProfile: profile)
        defer { dependencies.reset() }
        let windowUUID = UUID()
        let runtime = DefaultFloorpWebPanelWebViewRuntimeFactory().makeRuntime(
            configuration: WKWebViewConfiguration(),
            windowUUID: windowUUID,
            certStore: profile.certStore
        )
        let webView = try XCTUnwrap(runtime.webView as? TabWebView)

        XCTAssertTrue(runtime.contentView === webView)
        XCTAssertEqual(webView.windowUUID, windowUUID)

        runtime.invalidate()

        XCTAssertNil(runtime.webView)
        XCTAssertNil(runtime.contentView)
    }

    func testInitialLoadWaitsForContentRules() throws {
        let fixture = makeFixture()

        XCTAssertTrue(fixture.runtime.loadedRequests.isEmpty)
        XCTAssertEqual(fixture.installer.installCallCount, 1)
        fixture.session.loadHome()
        fixture.session.loadHome()
        XCTAssertTrue(fixture.runtime.loadedRequests.isEmpty)

        fixture.installer.completeInstallation()

        XCTAssertEqual(
            fixture.runtime.loadedRequests.map(\.url),
            [fixture.configuration.homeURL]
        )
    }

    func testRestorationURLLoadsExactlyOnceAfterContentRulesAndRejectsUnsafeURL() throws {
        let restorationURL = try XCTUnwrap(URL(string: "https://example.com/restored"))
        let restoredFixture = makeFixture(restorationURL: restorationURL)

        restoredFixture.installer.completeInstallation()
        restoredFixture.installer.completeInstallation()

        XCTAssertEqual(restoredFixture.runtime.loadedRequests.map(\.url), [restorationURL])

        let homeFixture = makeFixture(restorationURL: restoredFixture.configuration.homeURL)
        homeFixture.installer.completeInstallation()
        XCTAssertEqual(
            homeFixture.runtime.loadedRequests.map(\.url),
            [homeFixture.configuration.homeURL]
        )

        let unsafeURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        let unsafeFixture = makeFixture(restorationURL: unsafeURL)
        unsafeFixture.installer.completeInstallation()
        XCTAssertEqual(
            unsafeFixture.runtime.loadedRequests.map(\.url),
            [unsafeFixture.configuration.homeURL]
        )
    }

    func testHiddenSessionContinuesPendingLoadAndRequestsMediaSuppression() {
        let fixture = makeFixture()

        fixture.session.setVisible(false)
        fixture.installer.completeInstallation()

        XCTAssertEqual(
            fixture.runtime.loadedRequests.map(\.url),
            [fixture.configuration.homeURL]
        )
        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true])

        fixture.session.setVisible(true)

        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true, false])
    }

    func testStateObserversReceiveInitialAndRuntimeStates() throws {
        let fixture = makeFixture()
        var states = [FloorpWebPanelSessionState]()
        let identifier = try XCTUnwrap(fixture.session.addStateObserver { states.append($0) })
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))

        fixture.runtime.currentURL = currentURL
        fixture.runtime.pageTitle = "Current title"
        fixture.runtime.canGoBack = true
        fixture.runtime.canGoForward = true
        fixture.runtime.isLoading = true
        fixture.runtime.estimatedProgress = 1.4
        fixture.runtime.stateDidChange?()

        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.last?.currentURL, currentURL)
        XCTAssertEqual(states.last?.pageTitle, "Current title")
        XCTAssertEqual(states.last?.canGoBack, true)
        XCTAssertEqual(states.last?.canGoForward, true)
        XCTAssertEqual(states.last?.isLoading, true)
        XCTAssertEqual(states.last?.estimatedProgress, 1)

        fixture.session.removeStateObserver(identifier)
        fixture.runtime.pageTitle = "No longer observed"
        fixture.runtime.stateDidChange?()
        XCTAssertEqual(states.count, 2)
    }

    func testObserverCanRemoveItselfDuringNotification() throws {
        let fixture = makeFixture()
        var callbackCount = 0
        var identifier: UUID?
        identifier = fixture.session.addStateObserver { _ in
            callbackCount += 1
            if let identifier {
                fixture.session.removeStateObserver(identifier)
            }
        }

        fixture.session.updateConfiguration(fixture.configuration)
        fixture.session.updateConfiguration(fixture.configuration)

        XCTAssertEqual(callbackCount, 2)
    }

    func testCommandsRespectNavigationState() {
        let fixture = makeFixture()

        fixture.session.goBack()
        fixture.session.goForward()
        XCTAssertEqual(fixture.runtime.goBackCallCount, 0)
        XCTAssertEqual(fixture.runtime.goForwardCallCount, 0)

        fixture.runtime.canGoBack = true
        fixture.runtime.canGoForward = true
        fixture.runtime.stateDidChange?()
        fixture.session.goBack()
        fixture.session.goForward()
        fixture.session.reload()
        fixture.session.stopLoading()

        XCTAssertEqual(fixture.runtime.goBackCallCount, 1)
        XCTAssertEqual(fixture.runtime.goForwardCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 1)
        XCTAssertEqual(fixture.runtime.stopLoadingCallCount, 1)
    }

    func testVisibilityAndExplicitMuteRemainIdempotentWhenJavaScriptFails() {
        let fixture = makeFixture()
        fixture.runtime.mediaPlaybackError = MockMediaPlaybackError.javaScriptFailure

        fixture.session.setVisible(false)
        fixture.session.setVisible(false)
        fixture.session.setVisible(true)
        fixture.session.setAudioMuted(true)
        fixture.session.setAudioMuted(true)
        fixture.session.setVisible(false)
        fixture.session.setVisible(true)
        fixture.session.setAudioMuted(false)

        XCTAssertEqual(
            fixture.runtime.mediaPlaybackSuppressionRequests,
            [true, false, true, false]
        )
        XCTAssertFalse(fixture.session.isAudioMuted)
        XCTAssertEqual(fixture.runtime.invalidateCallCount, 0)
    }

    func testDelayedMediaCallbacksDoNotOverrideLatestStateAfterInvalidate() {
        let fixture = makeFixture()
        fixture.runtime.delaysMediaPlaybackCompletions = true

        fixture.session.setVisible(false)
        fixture.session.setVisible(true)
        fixture.session.setAudioMuted(true)

        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true, false, true])
        XCTAssertEqual(fixture.runtime.pendingMediaPlaybackCompletionCount, 3)
        XCTAssertTrue(fixture.session.isAudioMuted)

        fixture.session.invalidate()
        fixture.runtime.mediaPlaybackError = MockMediaPlaybackError.javaScriptFailure
        fixture.runtime.completePendingMediaPlaybackTransitions()
        fixture.session.setAudioMuted(false)
        fixture.session.setVisible(false)

        XCTAssertEqual(fixture.runtime.pendingMediaPlaybackCompletionCount, 0)
        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true, false, true])
        XCTAssertTrue(fixture.session.isAudioMuted)
        XCTAssertEqual(fixture.runtime.invalidateCallCount, 1)
    }

    func testOpenCurrentPageInMainBrowserAllowsOnlySafeCurrentURL() throws {
        var requests = [FloorpWebPanelMainBrowserRequest]()
        let fixture = makeFixture(
            windowUUID: .XCTestDefaultUUID,
            isPrivate: true
        ) { requests.append($0) }
        let safeURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        let unsafeURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))

        fixture.session.openCurrentPageInMainBrowser()
        fixture.runtime.currentURL = safeURL
        fixture.runtime.stateDidChange?()
        fixture.session.openCurrentPageInMainBrowser()
        fixture.runtime.currentURL = unsafeURL
        fixture.runtime.stateDidChange?()
        fixture.session.openCurrentPageInMainBrowser()

        XCTAssertEqual(
            requests,
            [
                FloorpWebPanelMainBrowserRequest(
                    url: safeURL,
                    windowUUID: .XCTestDefaultUUID,
                    isPrivate: true
                ),
            ]
        )
    }

    func testMetadataUpdatePreservesRuntimeAndNotifies() throws {
        let fixture = makeFixture()
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        fixture.runtime.currentURL = currentURL
        fixture.runtime.stateDidChange?()
        var states = [FloorpWebPanelSessionState]()
        _ = fixture.session.addStateObserver { states.append($0) }
        let updated = FloorpWebPanelSessionConfiguration(
            panelTitle: "Updated",
            homeURL: fixture.configuration.homeURL,
            iconName: "star"
        )

        fixture.session.updateConfiguration(updated)

        XCTAssertEqual(fixture.session.state.configuration, updated)
        XCTAssertEqual(fixture.session.state.currentURL, currentURL)
        XCTAssertEqual(states.last?.configuration, updated)
        XCTAssertTrue(fixture.runtime.loadedRequests.isEmpty)
    }

    func testInvalidateCancelsPendingLoadAndReleasesResources() {
        let fixture = makeFixture()

        fixture.session.invalidate()
        fixture.session.invalidate()
        fixture.installer.completeInstallation()
        fixture.session.loadHome()
        fixture.session.reload()

        XCTAssertEqual(fixture.installer.invalidateCallCount, 1)
        XCTAssertEqual(fixture.runtime.invalidateCallCount, 1)
        XCTAssertTrue(fixture.runtime.loadedRequests.isEmpty)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
        XCTAssertNil(fixture.session.contentView)
        XCTAssertNil(fixture.session.addStateObserver { _ in })
    }

    func testUnloadCancelsPendingRuleCallbackIdempotently() {
        let fixture = makeFixture()

        fixture.session.unload()
        fixture.session.unload()
        fixture.installer.completeInstallation()

        XCTAssertEqual(fixture.installer.invalidateCallCount, 1)
        XCTAssertEqual(fixture.runtime.invalidateCallCount, 1)
        XCTAssertTrue(fixture.runtime.loadedRequests.isEmpty)
        XCTAssertNil(fixture.session.contentView)
    }

    func testContentBlockerAdapterDetachesFromWebView() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let adapter = FloorpWebPanelContentBlockerTab(isPrivate: true, webView: webView)

        XCTAssertTrue(adapter.isPrivate)
        XCTAssertTrue(adapter.currentWebView() === webView)
        XCTAssertFalse(adapter.imageContentBlockingEnabled())

        adapter.detach()

        XCTAssertNil(adapter.currentWebView())
        XCTAssertNil(adapter.currentURL())
    }

    func testPrivateFactoryLeaseSurvivesUntilSessionInvalidationAndIgnoresLateCallbacks() throws {
        let coordinator = WKPrivateBrowsingSessionCoordinator()
        let initialStore = coordinator.websiteDataStore
        let runtime = MockFloorpWebPanelWebViewRuntime()
        let installer = MockFloorpWebPanelContentRuleInstaller()
        let factory = DefaultFloorpWebPanelSessionFactory(
            profile: MockProfile(),
            runtimeFactory: MockFloorpWebPanelWebViewRuntimeFactory(runtime: runtime),
            contentRuleInstallerFactory: MockFloorpWebPanelContentRuleInstallerFactory(
                installer: installer
            ),
            privateBrowsingSessionCoordinator: coordinator,
            openInMainBrowser: { _ in }
        )
        let configuration = FloorpWebPanelSessionConfiguration(
            panelTitle: "Private panel",
            homeURL: try XCTUnwrap(URL(string: "https://example.com/private")),
            iconName: "globe"
        )
        let session = try factory.makeSession(
            for: FloorpWebPanelSessionKey(
                windowUUID: UUID(),
                panelID: "private-panel",
                isPrivate: true
            ),
            configuration: configuration
        )

        coordinator.endSessionIfUnowned()
        XCTAssertTrue(initialStore === coordinator.websiteDataStore)

        session.invalidate()
        let replacementLease = coordinator.acquireLease()
        let replacementStore = coordinator.websiteDataStore
        installer.completeInstallation()

        XCTAssertFalse(initialStore === replacementStore)
        XCTAssertTrue(replacementStore === coordinator.websiteDataStore)
        XCTAssertTrue(runtime.loadedRequests.isEmpty)
        replacementLease.invalidate()
    }

    private func makeFixture(
        windowUUID: WindowUUID = UUID(),
        isPrivate: Bool = false,
        restorationURL: URL? = nil,
        openInMainBrowser: @escaping FloorpWebPanelNavigationExecutor.OpenInMainBrowser = { _ in }
    ) -> Fixture {
        let runtime = MockFloorpWebPanelWebViewRuntime()
        let installer = MockFloorpWebPanelContentRuleInstaller()
        let installerFactory = MockFloorpWebPanelContentRuleInstallerFactory(installer: installer)
        let configuration = FloorpWebPanelSessionConfiguration(
            panelTitle: "Panel",
            homeURL: URL(string: "https://example.com/home")!,
            iconName: "globe"
        )
        let session = FloorpWebPanelWebViewSession(
            key: FloorpWebPanelSessionKey(
                windowUUID: windowUUID,
                panelID: "panel",
                isPrivate: isPrivate
            ),
            configuration: configuration,
            runtime: runtime,
            contentRuleInstallerFactory: installerFactory,
            navigationExecutor: FloorpWebPanelNavigationExecutor(
                windowUUID: windowUUID,
                isPrivate: isPrivate,
                openInMainBrowser: openInMainBrowser
            ),
            restorationURL: restorationURL
        )
        return Fixture(
            session: session,
            runtime: runtime,
            installer: installer,
            configuration: configuration
        )
    }

    private struct Fixture {
        let session: FloorpWebPanelWebViewSession
        let runtime: MockFloorpWebPanelWebViewRuntime
        let installer: MockFloorpWebPanelContentRuleInstaller
        let configuration: FloorpWebPanelSessionConfiguration
    }
}

@MainActor
final class FloorpWebPanelNavigationExecutorTests: XCTestCase {
    func testOpenRequestPreservesOwningWindowAndSourcePrivacy() throws {
        let windowUUID = WindowUUID()
        let url = try XCTUnwrap(URL(string: "https://example.com/private-panel"))
        var requests = [FloorpWebPanelMainBrowserRequest]()
        let executor = FloorpWebPanelNavigationExecutor(
            windowUUID: windowUUID,
            isPrivate: true,
            openInMainBrowser: { requests.append($0) }
        )

        executor.openInMainBrowserIfSafe(url)

        XCTAssertEqual(
            requests,
            [
                FloorpWebPanelMainBrowserRequest(
                    url: url,
                    windowUUID: windowUUID,
                    isPrivate: true
                ),
            ]
        )
    }

    func testAllowsAndCancelsExistingFrameDecisions() throws {
        let executor = FloorpWebPanelNavigationExecutor(
            windowUUID: .XCTestDefaultUUID,
            isPrivate: false,
            openInMainBrowser: { _ in }
        )
        let url = try XCTUnwrap(URL(string: "https://example.com"))

        XCTAssertEqual(
            executor.execution(for: .allow, isUserInitiated: false, at: 0),
            .allow
        )
        XCTAssertEqual(
            executor.execution(for: .cancel, isUserInitiated: true, at: 0),
            .cancel
        )
        XCTAssertEqual(
            executor.execution(for: .openInMainBrowser(url), isUserInitiated: false, at: 0),
            .cancel
        )
    }

    func testUserInitiatedPopupsAreThrottled() throws {
        let executor = FloorpWebPanelNavigationExecutor(
            windowUUID: .XCTestDefaultUUID,
            isPrivate: false,
            minimumPopupInterval: 1,
            openInMainBrowser: { _ in }
        )
        let first = try XCTUnwrap(URL(string: "https://example.com/first"))
        let second = try XCTUnwrap(URL(string: "https://example.com/second"))

        XCTAssertEqual(
            executor.execution(for: .openInMainBrowser(first), isUserInitiated: true, at: 10),
            .openInMainBrowser(first)
        )
        XCTAssertEqual(
            executor.execution(for: .openInMainBrowser(second), isUserInitiated: true, at: 10.5),
            .cancel
        )
        XCTAssertEqual(
            executor.execution(for: .openInMainBrowser(second), isUserInitiated: true, at: 11),
            .openInMainBrowser(second)
        )
    }

    func testInvalidatedExecutorRejectsEveryDecision() throws {
        let executor = FloorpWebPanelNavigationExecutor(
            windowUUID: .XCTestDefaultUUID,
            isPrivate: false,
            openInMainBrowser: { _ in }
        )
        let url = try XCTUnwrap(URL(string: "https://example.com"))

        executor.invalidate()

        XCTAssertEqual(
            executor.execution(for: .allow, isUserInitiated: true, at: 0),
            .cancel
        )
        XCTAssertEqual(
            executor.execution(for: .openInMainBrowser(url), isUserInitiated: true, at: 0),
            .cancel
        )
    }
}

@MainActor
final class FloorpWebPanelMainBrowserRouterTests: XCTestCase {
    func testRoutesRegularRequestToRegularNewTab() throws {
        let windowUUID = WindowUUID()
        let url = try XCTUnwrap(URL(string: "https://example.com/regular"))
        var openedURL: URL?
        var openedPrivately: Bool?
        let router = FloorpWebPanelMainBrowserRouter(windowUUID: windowUUID) {
            openedURL = $0
            openedPrivately = $1
        }

        router.open(
            FloorpWebPanelMainBrowserRequest(
                url: url,
                windowUUID: windowUUID,
                isPrivate: false
            )
        )

        XCTAssertEqual(openedURL, url)
        XCTAssertEqual(openedPrivately, false)
    }

    func testRoutesPrivateRequestToPrivateNewTab() throws {
        let windowUUID = WindowUUID()
        let url = try XCTUnwrap(URL(string: "https://example.com/private"))
        var openedURL: URL?
        var openedPrivately: Bool?
        let router = FloorpWebPanelMainBrowserRouter(windowUUID: windowUUID) {
            openedURL = $0
            openedPrivately = $1
        }

        router.open(
            FloorpWebPanelMainBrowserRequest(
                url: url,
                windowUUID: windowUUID,
                isPrivate: true
            )
        )

        XCTAssertEqual(openedURL, url)
        XCTAssertEqual(openedPrivately, true)
    }

    func testRejectsRequestOwnedByAnotherWindow() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/other-window"))
        var openCallCount = 0
        let router = FloorpWebPanelMainBrowserRouter(windowUUID: WindowUUID()) { _, _ in
            openCallCount += 1
        }

        router.open(
            FloorpWebPanelMainBrowserRequest(
                url: url,
                windowUUID: WindowUUID(),
                isPrivate: false
            )
        )

        XCTAssertEqual(openCallCount, 0)
    }
}

@MainActor
private final class MockFloorpWebPanelWebViewRuntime: FloorpWebPanelWebViewRuntime {
    let retainedWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    var stateDidChange: (@MainActor () -> Void)?
    var currentURL: URL?
    var pageTitle: String?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var estimatedProgress = 0.0
    private(set) var loadedRequests = [URLRequest]()
    private(set) var goBackCallCount = 0
    private(set) var goForwardCallCount = 0
    private(set) var reloadCallCount = 0
    private(set) var stopLoadingCallCount = 0
    private(set) var invalidateCallCount = 0
    private(set) var mediaPlaybackSuppressionRequests = [Bool]()
    private var pendingMediaPlaybackCompletions = [
        @MainActor (Result<Void, Error>) -> Void
    ]()
    var delaysMediaPlaybackCompletions = false
    var mediaPlaybackError: Error?

    var pendingMediaPlaybackCompletionCount: Int {
        pendingMediaPlaybackCompletions.count
    }

    var contentView: UIView? { invalidateCallCount == 0 ? retainedWebView : nil }
    var webView: WKWebView? { invalidateCallCount == 0 ? retainedWebView : nil }

    func setNavigationExecutor(_ executor: FloorpWebPanelNavigationExecutor?) {}

    func load(_ request: URLRequest) {
        loadedRequests.append(request)
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

    func setMediaPlaybackSuppressed(
        _ isSuppressed: Bool,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        mediaPlaybackSuppressionRequests.append(isSuppressed)
        if delaysMediaPlaybackCompletions {
            pendingMediaPlaybackCompletions.append(completion)
            return
        }
        if let mediaPlaybackError {
            completion(.failure(mediaPlaybackError))
        } else {
            completion(.success(()))
        }
    }

    func completePendingMediaPlaybackTransitions() {
        let completions = pendingMediaPlaybackCompletions
        pendingMediaPlaybackCompletions.removeAll()
        completions.forEach { completion in
            if let mediaPlaybackError {
                completion(.failure(mediaPlaybackError))
            } else {
                completion(.success(()))
            }
        }
    }

    func invalidate() {
        invalidateCallCount += 1
        stateDidChange = nil
    }
}

private enum MockMediaPlaybackError: Error {
    case javaScriptFailure
}

@MainActor
private final class MockFloorpWebPanelWebViewRuntimeFactory: FloorpWebPanelWebViewRuntimeFactory {
    private let runtime: MockFloorpWebPanelWebViewRuntime

    init(runtime: MockFloorpWebPanelWebViewRuntime) {
        self.runtime = runtime
    }

    func makeRuntime(
        configuration: WKWebViewConfiguration,
        windowUUID: WindowUUID,
        certStore: CertStore
    ) -> any FloorpWebPanelWebViewRuntime {
        runtime
    }
}

@MainActor
private final class MockFloorpWebPanelContentRuleInstallerFactory:
    FloorpWebPanelContentRuleInstallerFactory {
    private let installer: MockFloorpWebPanelContentRuleInstaller

    init(installer: MockFloorpWebPanelContentRuleInstaller) {
        self.installer = installer
    }

    func makeInstaller(
        for tab: ContentBlockerTab
    ) -> any FloorpWebPanelContentRuleInstalling {
        installer
    }
}

@MainActor
private final class MockFloorpWebPanelContentRuleInstaller:
    FloorpWebPanelContentRuleInstalling {
    private var completion: (@MainActor () -> Void)?
    private(set) var installCallCount = 0
    private(set) var invalidateCallCount = 0

    func install(completion: @escaping @MainActor () -> Void) {
        installCallCount += 1
        self.completion = completion
    }

    func invalidate() {
        invalidateCallCount += 1
    }

    func completeInstallation() {
        let completion = completion
        self.completion = nil
        completion?()
    }
}
