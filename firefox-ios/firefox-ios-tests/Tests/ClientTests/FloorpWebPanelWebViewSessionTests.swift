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

    @available(iOS 16.0, *)
    func testDefaultFindTargetEnablesAndDismissesNativeInteraction() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let target = DefaultFloorpWebPanelFindTarget(webView: webView)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        webView.frame = host.view.bounds
        host.view.addSubview(webView)
        defer {
            target.invalidate()
            webView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        XCTAssertFalse(webView.isFindInteractionEnabled)
        XCTAssertTrue(target.supportsNativeFindInteraction)
        XCTAssertTrue(target.presentNativeFindNavigator())
        XCTAssertTrue(webView.isFindInteractionEnabled)
        XCTAssertNotNil(webView.findInteraction)

        target.endFindSession()

        XCTAssertFalse(webView.isFindInteractionEnabled)
    }

    func testDefaultFindTargetUsesWKFindForFallbackRequests() async {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let target = DefaultFloorpWebPanelFindTarget(webView: webView)
        let navigationDelegate = FloorpWebPanelFindNavigationDelegate()
        let loaded = expectation(description: "Web content loaded for find")
        navigationDelegate.onCompletion = { loaded.fulfill() }
        webView.navigationDelegate = navigationDelegate
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        webView.frame = host.view.bounds
        host.view.addSubview(webView)
        defer {
            target.invalidate()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }
        webView.loadHTMLString(
            "<html><body>first value<span>middle</span>last value</body></html>",
            baseURL: nil
        )
        await fulfillment(of: [loaded], timeout: 2)

        let foundLast = await performFind(
            FloorpWebPanelFindRequest(
                query: "last value",
                direction: .forward,
                kind: .queryChanged
            ),
            on: target
        )
        let wrappedToFirst = await performFind(
            FloorpWebPanelFindRequest(
                query: "first value",
                direction: .forward,
                kind: .queryChanged
            ),
            on: target
        )

        XCTAssertTrue(foundLast)
        XCTAssertTrue(wrappedToFirst)
    }

    private func performFind(
        _ request: FloorpWebPanelFindRequest,
        on target: DefaultFloorpWebPanelFindTarget
    ) async -> Bool {
        var result = false
        let completed = expectation(description: "WKWebView find completed")
        target.find(request) { matchFound in
            result = matchFound
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        return result
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

        XCTAssertEqual(restoredFixture.session.restorationURLForUnload(), restorationURL)
        restoredFixture.installer.completeInstallation()
        XCTAssertEqual(restoredFixture.session.restorationURLForUnload(), restorationURL)
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

    func testRestorationCandidatePrefersLatestRuntimeURLAndRejectsUnsafeLatestURL() throws {
        let fixture = makeFixture()
        let staleStateURL = try XCTUnwrap(URL(string: "https://example.com/stale-state"))
        let latestRuntimeURL = try XCTUnwrap(URL(string: "https://example.com/latest-runtime"))
        fixture.runtime.currentURL = staleStateURL
        fixture.runtime.stateDidChange?()

        fixture.runtime.currentURL = latestRuntimeURL
        XCTAssertEqual(fixture.session.state.currentURL, staleStateURL)
        XCTAssertEqual(fixture.session.restorationURLForUnload(), latestRuntimeURL)

        fixture.runtime.currentURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        XCTAssertNil(fixture.session.restorationURLForUnload())

        fixture.runtime.currentURL = nil
        XCTAssertEqual(fixture.session.restorationURLForUnload(), staleStateURL)
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

    func testVisibilityTransitionsRemainIdempotent() {
        let fixture = makeFixture()

        fixture.session.setVisible(false)
        fixture.session.setVisible(false)
        fixture.session.setVisible(true)
        fixture.session.setVisible(true)

        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true, false])
        XCTAssertEqual(fixture.runtime.invalidateCallCount, 0)
    }

    func testDelayedMediaTransitionsCoalesceAndIgnoreCompletionAfterInvalidate() {
        let fixture = makeFixture()
        fixture.runtime.delaysMediaPlaybackCompletions = true

        fixture.session.setVisible(false)
        fixture.session.setVisible(true)

        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true])
        XCTAssertEqual(fixture.runtime.pendingMediaPlaybackCompletionCount, 1)
        fixture.runtime.completePendingMediaPlaybackTransitions()
        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true, false])

        fixture.session.setVisible(false)
        fixture.runtime.completePendingMediaPlaybackTransitions()
        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true, false, true])
        XCTAssertEqual(fixture.runtime.pendingMediaPlaybackCompletionCount, 1)

        fixture.session.invalidate()
        fixture.runtime.completePendingMediaPlaybackTransitions()
        fixture.session.setVisible(true)
        fixture.session.setVisible(false)

        XCTAssertEqual(fixture.runtime.pendingMediaPlaybackCompletionCount, 0)
        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true, false, true])
        XCTAssertEqual(fixture.runtime.invalidateCallCount, 1)
    }

    func testInvalidateReleasesSessionAndRuntimeBeforeLateMediaCompletion() {
        let relay = MockFloorpWebPanelMediaPlaybackCompletionRelay()

        let references = makeInvalidatedMediaReferences(relay: relay)

        XCTAssertEqual(relay.pendingCompletionCount, 1)
        XCTAssertNil(references.session.value)
        XCTAssertNil(references.runtime.value)

        relay.completePendingTransitions(with: .success(()))
        XCTAssertEqual(relay.pendingCompletionCount, 0)
        XCTAssertNil(references.session.value)
        XCTAssertNil(references.runtime.value)
    }

    func testInvalidateCleanupOrdersFinalSuppressionAfterDelayedResume() {
        let nativeSetter = MockFloorpWebPanelNativeMediaSetter()
        let transitioner = makeMediaPlaybackTransitioner(nativeSetter: nativeSetter)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let controller = FloorpWebPanelMediaPlaybackController(
            webView: webView,
            transitioner: transitioner
        )
        var results = [Result<Void, Error>]()

        controller.setSuppressed(true) { results.append($0) }
        nativeSetter.completeNextTransition()
        controller.setSuppressed(false) { results.append($0) }

        XCTAssertEqual(nativeSetter.requests, [true, false])
        XCTAssertEqual(nativeSetter.pendingCompletionCount, 1)

        controller.invalidate()

        XCTAssertEqual(nativeSetter.requests, [true, false, true])
        XCTAssertEqual(nativeSetter.pendingCompletionCount, 1)

        nativeSetter.completeNextTransition()

        XCTAssertEqual(nativeSetter.requests, [true, false, true, true])
        XCTAssertEqual(nativeSetter.pendingCompletionCount, 0)
        XCTAssertEqual(results.count, 1)
        if case .failure = results[0] {
            XCTFail("Initial suppression should complete successfully")
        }
    }

    func testInvalidateReleasesWebViewWhenNativeMediaTransitionNeverCompletes() async {
        let nativeSetter = MockFloorpWebPanelNativeMediaSetter()
        let transitioner = makeMediaPlaybackTransitioner(nativeSetter: nativeSetter)
        var webViewReference: WeakReference<WKWebView>?
        var controllerReference: WeakReference<FloorpWebPanelMediaPlaybackController>?
        var completionOwnerReference: WeakReference<MockFloorpWebPanelCompletionOwner>?

        autoreleasepool {
            let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            let completionOwner = MockFloorpWebPanelCompletionOwner()
            let controller = FloorpWebPanelMediaPlaybackController(
                webView: webView,
                transitioner: transitioner
            )
            webViewReference = WeakReference(webView)
            controllerReference = WeakReference(controller)
            completionOwnerReference = WeakReference(completionOwner)
            controller.setSuppressed(true) { [completionOwner] _ in
                completionOwner.callCount += 1
            }
            controller.invalidate()
        }
        await waitForDeallocation(webViewReference)

        XCTAssertEqual(nativeSetter.requests, [true, true])
        XCTAssertEqual(nativeSetter.pendingCompletionCount, 1)
        XCTAssertNil(webViewReference?.value)
        XCTAssertNil(controllerReference?.value)
        XCTAssertNil(completionOwnerReference?.value)
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

    private func makeInvalidatedMediaReferences(
        relay: MockFloorpWebPanelMediaPlaybackCompletionRelay
    ) -> (
        session: WeakReference<FloorpWebPanelWebViewSession>,
        runtime: WeakReference<MockFloorpWebPanelWebViewRuntime>
    ) {
        let fixture = makeFixture()
        fixture.runtime.mediaPlaybackCompletionRelay = relay
        fixture.session.setVisible(false)
        XCTAssertEqual(fixture.runtime.mediaPlaybackSuppressionRequests, [true])

        let session = WeakReference(fixture.session)
        let runtime = WeakReference(fixture.runtime)
        fixture.session.invalidate()
        XCTAssertEqual(fixture.runtime.invalidateCallCount, 1)
        return (session, runtime)
    }

    private func makeMediaPlaybackTransitioner(
        nativeSetter: MockFloorpWebPanelNativeMediaSetter
    ) -> FloorpWebPanelMediaPlaybackTransitioner {
        FloorpWebPanelMediaPlaybackTransitioner(
            nativeSetter: { webView, isSuppressed, callback in
                nativeSetter.setSuppressed(
                    isSuppressed,
                    on: webView,
                    callback: callback
                )
            }
        )
    }

    private func waitForDeallocation<Object: AnyObject>(
        _ reference: WeakReference<Object>?
    ) async {
        for _ in 0..<50 where reference?.value != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
private final class FloorpWebPanelFindNavigationDelegate: NSObject, WKNavigationDelegate {
    var onCompletion: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        complete()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        complete()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        complete()
    }

    private func complete() {
        let onCompletion = onCompletion
        self.onCompletion = nil
        onCompletion?()
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
    var mediaPlaybackCompletionRelay: MockFloorpWebPanelMediaPlaybackCompletionRelay?

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
        if let mediaPlaybackCompletionRelay {
            mediaPlaybackCompletionRelay.append(completion)
            return
        }
        if delaysMediaPlaybackCompletions {
            pendingMediaPlaybackCompletions.append(completion)
            return
        }
        completion(.success(()))
    }

    func completePendingMediaPlaybackTransitions() {
        let completions = pendingMediaPlaybackCompletions
        pendingMediaPlaybackCompletions.removeAll()
        completions.forEach { $0(.success(())) }
    }

    func invalidate() {
        invalidateCallCount += 1
        stateDidChange = nil
    }
}

@MainActor
private final class MockFloorpWebPanelMediaPlaybackCompletionRelay {
    private var completions = [@MainActor (Result<Void, Error>) -> Void]()

    var pendingCompletionCount: Int {
        completions.count
    }

    func append(_ completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        completions.append(completion)
    }

    func completePendingTransitions(with result: Result<Void, Error>) {
        let pendingCompletions = completions
        completions.removeAll()
        pendingCompletions.forEach { $0(result) }
    }
}

@MainActor
private final class MockFloorpWebPanelNativeMediaSetter {
    private var completions = [FloorpWebPanelMediaPlaybackTransitioner.NativeCallbackBox]()
    private(set) var requests = [Bool]()
    private(set) var webViews = [WeakReference<WKWebView>]()

    var pendingCompletionCount: Int {
        completions.count
    }

    func setSuppressed(
        _ isSuppressed: Bool,
        on webView: WKWebView,
        callback: FloorpWebPanelMediaPlaybackTransitioner.NativeCallbackBox?
    ) {
        requests.append(isSuppressed)
        webViews.append(WeakReference(webView))
        guard let callback else { return }
        completions.append(callback)
    }

    func completeNextTransition() {
        guard !completions.isEmpty else { return }
        completions.removeFirst().call()
    }
}

private final class MockFloorpWebPanelCompletionOwner {
    var callCount = 0
}

private final class WeakReference<Object: AnyObject> {
    private(set) weak var value: Object?

    init(_ value: Object) {
        self.value = value
    }
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
