// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Shared
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

    func testDefaultRuntimeAppliesPageZoomThroughOwnedWebView() throws {
        let profile = MockProfile()
        let dependencies = DependencyHelperMock()
        dependencies.bootstrapDependencies(injectedProfile: profile)
        defer { dependencies.reset() }
        let runtime = DefaultFloorpWebPanelWebViewRuntimeFactory().makeRuntime(
            configuration: WKWebViewConfiguration(),
            windowUUID: UUID(),
            certStore: profile.certStore
        )
        let webView = try XCTUnwrap(runtime.webView)

        runtime.setPageZoom(1.25)

        XCTAssertEqual(runtime.pageZoom, 1.25)
        XCTAssertEqual(webView.pageZoom, 1.25)
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
        await fulfillment(of: [loaded], timeout: 5)

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

    func testZoomIsAppliedBeforeInitialNavigationAndUpdatesInPlaceOnlyWhenChanged() {
        let fixture = makeFixture(zoomLevel: .oneHundredTwentyFivePercent)
        let webView = fixture.runtime.retainedWebView
        let currentURL = URL(string: "https://example.com/current")
        fixture.runtime.currentURL = currentURL

        XCTAssertEqual(fixture.runtime.pageZoom, 1.25)
        XCTAssertEqual(fixture.runtime.pageZoomAssignments, [1.25])
        XCTAssertTrue(fixture.runtime.loadedRequests.isEmpty)

        fixture.installer.completeInstallation()
        let updatedConfiguration = FloorpWebPanelSessionConfiguration(
            panelTitle: fixture.configuration.panelTitle,
            homeURL: fixture.configuration.homeURL,
            iconName: fixture.configuration.iconName,
            zoomLevel: .oneHundredFiftyPercent
        )
        fixture.session.updateConfiguration(updatedConfiguration)
        fixture.session.updateConfiguration(updatedConfiguration)

        XCTAssertTrue(fixture.runtime.retainedWebView === webView)
        XCTAssertEqual(fixture.runtime.currentURL, currentURL)
        XCTAssertEqual(fixture.runtime.loadedRequests.map(\.url), [fixture.configuration.homeURL])
        XCTAssertEqual(fixture.runtime.pageZoom, 1.5)
        XCTAssertEqual(fixture.runtime.pageZoomAssignments, [1.25, 1.5])
    }

    func testContentModeUpdatePreservesRuntimeAndReloadsFromOriginExactlyOnce() throws {
        let fixture = makeFixture(contentMode: .mobile)
        let webView = fixture.runtime.retainedWebView
        fixture.installer.completeInstallation()
        fixture.runtime.currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        fixture.runtime.stateDidChange?()
        let desktopConfiguration = FloorpWebPanelSessionConfiguration(
            panelTitle: fixture.configuration.panelTitle,
            homeURL: fixture.configuration.homeURL,
            iconName: fixture.configuration.iconName,
            zoomLevel: fixture.configuration.zoomLevel,
            contentMode: .desktop
        )

        fixture.session.updateConfiguration(desktopConfiguration)

        XCTAssertEqual(fixture.navigationExecutor.contentMode, .desktop)
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 0)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())
        XCTAssertFalse(fixture.session.applyPendingContentModeReload())
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        try commitContentModeNavigation(in: fixture)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
        XCTAssertTrue(fixture.runtime.retainedWebView === webView)
        XCTAssertEqual(fixture.session.state.configuration.contentMode, .desktop)
    }

    func testHiddenContentModeChangesCoalesceUntilVisible() throws {
        let fixture = makeFixture(contentMode: .mobile)
        fixture.installer.completeInstallation()
        fixture.runtime.currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        fixture.runtime.stateDidChange?()
        fixture.session.setVisible(false)

        func update(_ contentMode: FloorpWebPanelContentMode) {
            fixture.session.updateConfiguration(FloorpWebPanelSessionConfiguration(
                panelTitle: fixture.configuration.panelTitle,
                homeURL: fixture.configuration.homeURL,
                iconName: fixture.configuration.iconName,
                zoomLevel: fixture.configuration.zoomLevel,
                contentMode: contentMode
            ))
        }

        update(.desktop)
        update(.mobile)
        update(.desktop)
        update(.desktop)

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 0)
        fixture.session.setVisible(true)
        fixture.session.setVisible(true)
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertEqual(fixture.navigationExecutor.contentMode, .desktop)
        try commitContentModeNavigation(in: fixture)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
    }

    func testContentModeChangedBeforeInitialLoadUsesLatestModeWithoutReload() {
        let fixture = makeFixture(contentMode: .mobile)
        let desktopConfiguration = FloorpWebPanelSessionConfiguration(
            panelTitle: fixture.configuration.panelTitle,
            homeURL: fixture.configuration.homeURL,
            iconName: fixture.configuration.iconName,
            zoomLevel: fixture.configuration.zoomLevel,
            contentMode: .desktop
        )

        fixture.session.updateConfiguration(desktopConfiguration)
        fixture.installer.completeInstallation()

        XCTAssertEqual(fixture.navigationExecutor.contentMode, .desktop)
        XCTAssertEqual(fixture.runtime.loadedRequests.map(\.url), [fixture.configuration.homeURL])
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 0)
        XCTAssertFalse(fixture.session.applyPendingContentModeReload())
    }

    func testContentModeReloadNilKeepsPendingAndRetriesWhenShown() throws {
        let fixture = makeFixture(contentMode: .mobile)
        fixture.installer.completeInstallation()
        fixture.runtime.currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        fixture.runtime.stateDidChange?()
        fixture.runtime.reloadFromOriginSucceeds = false
        updateContentMode(.desktop, in: fixture)

        XCTAssertFalse(fixture.session.applyPendingContentModeReload())
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)
        fixture.runtime.stateDidChange?()
        fixture.runtime.stateDidChange?()
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)

        fixture.session.setVisible(false)
        fixture.runtime.reloadFromOriginSucceeds = true
        fixture.session.setVisible(true)

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 2)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)
        try commitContentModeNavigation(in: fixture)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
    }

    func testFailedContentModeNavigationKeepsPendingAndRetriesWhenShown() throws {
        let fixture = makeFixture(contentMode: .mobile)
        fixture.installer.completeInstallation()
        fixture.runtime.currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        fixture.runtime.stateDidChange?()
        updateContentMode(.desktop, in: fixture)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())
        let navigationID = try beginContentModeNavigation(in: fixture)
        fixture.session.setVisible(false)

        fixture.navigationExecutor.failContentModeNavigation(navigationID)

        XCTAssertTrue(fixture.session.isContentModeReloadPending)
        fixture.session.setVisible(true)
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 2)
    }

    func testFailedContentReloadDoesNotRetryFromKVOUntilExplicitRequest() throws {
        let fixture = makeFixture(contentMode: .mobile)
        finishInitialLoad(in: fixture)
        updateContentMode(.desktop, in: fixture)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())
        let navigationID = try beginContentModeNavigation(in: fixture)

        fixture.navigationExecutor.failContentModeNavigation(navigationID)
        fixture.runtime.stateDidChange?()
        fixture.runtime.stateDidChange?()

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 2)
        try commitContentModeNavigation(in: fixture)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
    }

    func testContentModeChangesDuringReloadCoalesceAndStateCallbacksDoNotDoubleReload() throws {
        let fixture = makeFixture(contentMode: .mobile)
        fixture.installer.completeInstallation()
        fixture.runtime.currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        fixture.runtime.stateDidChange?()
        fixture.runtime.invokesStateChangeDuringReloadFromOrigin = true
        updateContentMode(.desktop, in: fixture)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())
        let firstNavigationID = try beginContentModeNavigation(in: fixture)

        fixture.runtime.stateDidChange?()
        fixture.runtime.stateDidChange?()
        updateContentMode(.mobile, in: fixture)
        updateContentMode(.desktop, in: fixture)
        updateContentMode(.mobile, in: fixture)

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        fixture.navigationExecutor.commitContentModeNavigation(firstNavigationID)

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 2)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)
        try commitContentModeNavigation(in: fixture)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
        XCTAssertEqual(fixture.session.state.configuration.contentMode, .mobile)
    }

    func testSupersededNavigationCallbacksDoNotReleaseInFlightContentModeReload() throws {
        let fixture = makeFixture(contentMode: .mobile)
        fixture.installer.completeInstallation()
        fixture.runtime.currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        fixture.runtime.stateDidChange?()
        let supersededCommitNavigationID = FloorpWebPanelNavigationIdentity.synthetic()
        _ = try beginContentModeNavigation(
            in: fixture,
            navigationID: supersededCommitNavigationID
        )
        let supersededFailureNavigationID = FloorpWebPanelNavigationIdentity.synthetic()
        _ = try beginContentModeNavigation(
            in: fixture,
            navigationID: supersededFailureNavigationID
        )

        updateContentMode(.desktop, in: fixture)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())
        let reloadNavigationID = try beginContentModeNavigation(in: fixture)

        fixture.navigationExecutor.commitContentModeNavigation(supersededCommitNavigationID)
        fixture.navigationExecutor.failContentModeNavigation(supersededFailureNavigationID)
        fixture.runtime.stateDidChange?()
        fixture.runtime.stateDidChange?()

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)

        fixture.navigationExecutor.commitContentModeNavigation(reloadNavigationID)

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
        XCTAssertEqual(fixture.session.state.configuration.contentMode, .desktop)
    }

    func testManualReloadDoesNotSupersedeContentReloadBeforeNavigationBinding() throws {
        let fixture = makeFixture(contentMode: .mobile)
        finishInitialLoad(in: fixture)
        updateContentMode(.desktop, in: fixture)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())
        let navigationID = try XCTUnwrap(
            fixture.runtime.reloadFromOriginNavigationIDs.last
        )

        fixture.session.reload()

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)
        bindContentModeNavigation(navigationID, in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(navigationID)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)

        fixture.session.reload()

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 1)
        try commitReloadNavigation(in: fixture)
    }

    func testLoadHomeAdoptsInFlightContentReloadBeforeNavigationBinding() throws {
        let fixture = makeFixture(contentMode: .mobile)
        finishInitialLoad(in: fixture)
        updateContentMode(.desktop, in: fixture)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())

        fixture.session.loadHome()

        let homeNavigationID = try XCTUnwrap(fixture.runtime.loadNavigationIDs.last)
        XCTAssertEqual(fixture.runtime.loadedRequests.count, 2)
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)
        bindContentModeNavigation(homeNavigationID, in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(homeNavigationID)

        XCTAssertFalse(fixture.session.isContentModeReloadPending)
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
    }

    func testBackAndForwardAdoptInFlightContentReloadBeforeNavigationBinding() throws {
        for usesBackNavigation in [true, false] {
            let fixture = makeFixture(contentMode: .mobile)
            finishInitialLoad(in: fixture)
            updateContentMode(.desktop, in: fixture)
            XCTAssertTrue(fixture.session.applyPendingContentModeReload())
            fixture.runtime.canGoBack = usesBackNavigation
            fixture.runtime.canGoForward = !usesBackNavigation
            fixture.runtime.stateDidChange?()

            let navigationID: FloorpWebPanelNavigationIdentity
            if usesBackNavigation {
                fixture.session.goBack()
                navigationID = try XCTUnwrap(fixture.runtime.goBackNavigationIDs.last)
            } else {
                fixture.session.goForward()
                navigationID = try XCTUnwrap(fixture.runtime.goForwardNavigationIDs.last)
            }

            XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
            XCTAssertTrue(fixture.session.isContentModeReloadPending)
            bindContentModeNavigation(navigationID, in: fixture)
            fixture.navigationExecutor.commitContentModeNavigation(navigationID)
            XCTAssertFalse(fixture.session.isContentModeReloadPending)
            XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        }
    }

    func testFailedBackStartKeepsInFlightReloadIdentityAndReasons() throws {
        let fixture = makeFixture(contentMode: .mobile)
        finishInitialLoad(in: fixture)
        updateContentMode(.desktop, in: fixture)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())
        let reloadNavigationID = try XCTUnwrap(
            fixture.runtime.reloadFromOriginNavigationIDs.last
        )
        fixture.runtime.canGoBack = true
        fixture.runtime.goBackSucceeds = false
        fixture.runtime.stateDidChange?()

        fixture.session.goBack()

        XCTAssertEqual(fixture.runtime.goBackCallCount, 1)
        XCTAssertTrue(fixture.runtime.goBackNavigationIDs.isEmpty)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)
        bindContentModeNavigation(reloadNavigationID, in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(reloadNavigationID)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
    }

    func testStopBeforeNavigationBindingRequeuesReasonsWithoutKVORetry() throws {
        let fixture = makeFixture(contentMode: .mobile)
        finishInitialLoad(in: fixture)
        updateContentMode(.desktop, in: fixture)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())

        fixture.session.stopLoading()
        fixture.runtime.stateDidChange?()
        fixture.runtime.stateDidChange?()

        XCTAssertEqual(fixture.runtime.stopLoadingCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)

        fixture.session.setVisible(false)
        fixture.session.setVisible(true)

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 2)
        try commitContentModeNavigation(in: fixture)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
    }

    func testFailedManualReloadDoesNotRetryFromKVOUntilManualRequest() throws {
        let fixture = makeFixture()
        finishInitialLoad(in: fixture)
        fixture.session.reload()
        let failedNavigationID = try beginReloadNavigation(in: fixture)

        fixture.navigationExecutor.failContentModeNavigation(failedNavigationID)
        fixture.runtime.stateDidChange?()
        fixture.runtime.stateDidChange?()

        XCTAssertEqual(fixture.runtime.reloadCallCount, 1)
        fixture.session.reload()
        XCTAssertEqual(fixture.runtime.reloadCallCount, 2)
        try commitReloadNavigation(in: fixture)
    }

    func testAboutBlankManualAndImageReloadsRetireUnifiedArbiter() async throws {
        let notificationCenter = NotificationCenter()
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let fixture = makeFixture(
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        finishInitialLoad(in: fixture)
        fixture.runtime.currentURL = try XCTUnwrap(URL(string: "about:blank"))
        fixture.runtime.stateDidChange?()

        fixture.session.reload()
        let firstManualNavigationID = try XCTUnwrap(
            fixture.runtime.reloadNavigationIDs.last
        )
        bindAboutBlankNavigation(firstManualNavigationID, in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(firstManualNavigationID)

        fixture.session.reload()
        XCTAssertEqual(fixture.runtime.reloadCallCount, 2)
        let secondManualNavigationID = try XCTUnwrap(
            fixture.runtime.reloadNavigationIDs.last
        )
        bindAboutBlankNavigation(secondManualNavigationID, in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(secondManualNavigationID)

        preference.isEnabled = true
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()
        fixture.installer.completeNextRefresh()

        XCTAssertEqual(fixture.runtime.reloadCallCount, 3)
        let imageNavigationID = try XCTUnwrap(fixture.runtime.reloadNavigationIDs.last)
        bindAboutBlankNavigation(imageNavigationID, in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(imageNavigationID)

        fixture.session.reload()
        XCTAssertEqual(fixture.runtime.reloadCallCount, 4)
        let finalManualNavigationID = try XCTUnwrap(
            fixture.runtime.reloadNavigationIDs.last
        )
        bindAboutBlankNavigation(finalManualNavigationID, in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(finalManualNavigationID)
    }

    func testImageRefreshWaitsForUnboundContentReloadThenReloadsExactlyOnce() async throws {
        let notificationCenter = NotificationCenter()
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let fixture = makeFixture(
            contentMode: .mobile,
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        finishInitialLoad(in: fixture)
        updateContentMode(.desktop, in: fixture)
        XCTAssertTrue(fixture.session.applyPendingContentModeReload())
        let contentNavigationID = try XCTUnwrap(
            fixture.runtime.reloadFromOriginNavigationIDs.last
        )

        preference.isEnabled = true
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()
        fixture.installer.completeNextRefresh()

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
        XCTAssertTrue(fixture.session.isContentModeReloadPending)

        bindContentModeNavigation(contentNavigationID, in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(contentNavigationID)

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 1)
        try commitReloadNavigation(in: fixture)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
    }

    func testHiddenContentAndImageChangesCoalesceIntoOneOriginReload() async throws {
        let notificationCenter = NotificationCenter()
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let fixture = makeFixture(
            contentMode: .mobile,
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        finishInitialLoad(in: fixture)
        fixture.session.setVisible(false)
        updateContentMode(.desktop, in: fixture)

        preference.isEnabled = true
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()
        fixture.installer.completeNextRefresh()

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 0)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)

        fixture.session.setVisible(true)

        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
        try commitContentModeNavigation(in: fixture)
        XCTAssertEqual(fixture.runtime.reloadFromOriginCallCount, 1)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
        XCTAssertFalse(fixture.session.isContentModeReloadPending)
    }

    func testNilAndFailedImageReloadsRemainRetryableWithoutManualSupersession() async throws {
        let notificationCenter = NotificationCenter()
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let fixture = makeFixture(
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        finishInitialLoad(in: fixture)
        fixture.runtime.reloadSucceeds = false
        preference.isEnabled = true
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()
        fixture.installer.completeNextRefresh()

        XCTAssertEqual(fixture.runtime.reloadCallCount, 1)
        XCTAssertTrue(fixture.runtime.reloadNavigationIDs.isEmpty)

        fixture.session.setVisible(false)
        fixture.runtime.reloadSucceeds = true
        fixture.session.setVisible(true)
        let failedNavigationID = try XCTUnwrap(fixture.runtime.reloadNavigationIDs.last)
        fixture.session.reload()

        XCTAssertEqual(fixture.runtime.reloadCallCount, 2)
        bindContentModeNavigation(failedNavigationID, in: fixture)
        fixture.navigationExecutor.failContentModeNavigation(failedNavigationID)
        fixture.runtime.stateDidChange?()
        fixture.runtime.stateDidChange?()

        XCTAssertEqual(fixture.runtime.reloadCallCount, 2)

        fixture.session.setVisible(false)
        fixture.session.setVisible(true)

        XCTAssertEqual(fixture.runtime.reloadCallCount, 3)
        try commitReloadNavigation(in: fixture)
        fixture.session.reload()
        XCTAssertEqual(fixture.runtime.reloadCallCount, 4)
        try commitReloadNavigation(in: fixture)
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
        fixture.runtime.currentURL = fixture.configuration.homeURL
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
            isPrivate: true,
            openInMainBrowser: { requests.append($0) }
        )
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
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let adapter = FloorpWebPanelContentBlockerTab(
            isPrivate: true,
            webView: webView,
            imageContentBlockingEnabled: { preference.isEnabled }
        )

        XCTAssertTrue(adapter.isPrivate)
        XCTAssertTrue(adapter.currentWebView() === webView)
        XCTAssertFalse(adapter.imageContentBlockingEnabled())

        preference.isEnabled = true
        XCTAssertTrue(adapter.imageContentBlockingEnabled())

        adapter.detach()

        XCTAssertNil(adapter.currentWebView())
        XCTAssertNil(adapter.currentURL())
    }

    func testNoImageModeScriptMatchesNormalTabContractAndPreservesForeignScripts() throws {
        let configuration = WKWebViewConfiguration()
        let foreignScript = WKUserScript.createInDefaultContentWorld(
            source: "window.foreignScript = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(foreignScript)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let controller = DefaultFloorpWebPanelNoImageModeScriptController(
            webView: webView,
            isEnabled: true
        )

        var scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.contains { $0 === foreignScript })
        var noImageScript = try XCTUnwrap(scripts.first { $0 !== foreignScript })
        XCTAssertEqual(noImageScript.injectionTime, .atDocumentStart)
        XCTAssertFalse(noImageScript.isForMainFrameOnly)
        XCTAssertTrue(noImageScript.source.contains("const enabled = true"))
        XCTAssertTrue(noImageScript.source.contains("__firefox__NoImageMode"))
        XCTAssertTrue(noImageScript.source.contains(
            "*{background-image:none !important;}img{visibility:hidden !important;}"
        ))

        controller.setEnabled(false)

        scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.contains { $0 === foreignScript })
        noImageScript = try XCTUnwrap(scripts.first { $0 !== foreignScript })
        XCTAssertFalse(noImageScript.isForMainFrameOnly)
        XCTAssertTrue(noImageScript.source.contains("const enabled = false"))

        controller.invalidate()

        scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts.first === foreignScript)
    }

    func testDefaultFactoryAdapterReadsLiveProfileImageBlockingPreference() throws {
        let profile = MockProfile()
        profile.prefs.setBool(false, forKey: NoImageModePrefsKey.NoImageModeStatus)
        let runtime = MockFloorpWebPanelWebViewRuntime()
        let installer = MockFloorpWebPanelContentRuleInstaller()
        let installerFactory = MockFloorpWebPanelContentRuleInstallerFactory(installer: installer)
        let factory = DefaultFloorpWebPanelSessionFactory(
            profile: profile,
            runtimeFactory: MockFloorpWebPanelWebViewRuntimeFactory(runtime: runtime),
            contentRuleInstallerFactory: installerFactory,
            openInMainBrowser: { _ in }
        )
        let configuration = FloorpWebPanelSessionConfiguration(
            panelTitle: "Panel",
            homeURL: try XCTUnwrap(URL(string: "https://example.com/home")),
            iconName: "globe"
        )
        let session = try factory.makeSession(
            for: FloorpWebPanelSessionKey(
                windowUUID: UUID(),
                panelID: "panel",
                isPrivate: false
            ),
            configuration: configuration
        )
        defer { session.invalidate() }
        let adapter = try XCTUnwrap(installerFactory.tabs.first)

        XCTAssertFalse(adapter.imageContentBlockingEnabled())

        profile.prefs.setBool(true, forKey: NoImageModePrefsKey.NoImageModeStatus)

        XCTAssertTrue(adapter.imageContentBlockingEnabled())
    }

    func testImageBlockingPreferenceChangeRefreshesRegularAndPrivatePanelsExactlyOnce() async throws {
        let notificationCenter = NotificationCenter()
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let regular = makeFixture(
            isPrivate: false,
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        let privatePanel = makeFixture(
            isPrivate: true,
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        finishInitialLoad(in: regular)
        finishInitialLoad(in: privatePanel)
        defer {
            regular.session.invalidate()
            privatePanel.session.invalidate()
        }

        preference.isEnabled = true
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()

        XCTAssertEqual(regular.installer.refreshCallCount, 1)
        XCTAssertEqual(privatePanel.installer.refreshCallCount, 1)
        XCTAssertEqual(regular.runtime.reloadCallCount, 0)
        XCTAssertEqual(privatePanel.runtime.reloadCallCount, 0)

        regular.installer.completeNextRefresh()
        privatePanel.installer.completeNextRefresh()

        XCTAssertEqual(regular.runtime.reloadCallCount, 1)
        XCTAssertEqual(privatePanel.runtime.reloadCallCount, 1)
        try commitReloadNavigation(in: regular)
        try commitReloadNavigation(in: privatePanel)

        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()

        XCTAssertEqual(regular.installer.refreshCallCount, 1)
        XCTAssertEqual(privatePanel.installer.refreshCallCount, 1)
        XCTAssertEqual(regular.runtime.reloadCallCount, 1)
        XCTAssertEqual(privatePanel.runtime.reloadCallCount, 1)

        preference.isEnabled = false
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()
        regular.installer.completeNextRefresh()
        privatePanel.installer.completeNextRefresh()

        XCTAssertEqual(regular.installer.refreshCallCount, 2)
        XCTAssertEqual(privatePanel.installer.refreshCallCount, 2)
        XCTAssertEqual(regular.runtime.reloadCallCount, 2)
        XCTAssertEqual(privatePanel.runtime.reloadCallCount, 2)
        XCTAssertEqual(regular.noImageModeScriptController.enabledValues, [false, true, false])
        XCTAssertEqual(privatePanel.noImageModeScriptController.enabledValues, [false, true, false])
        try commitReloadNavigation(in: regular)
        try commitReloadNavigation(in: privatePanel)
        privatePanel.session.invalidate()
        XCTAssertEqual(privatePanel.noImageModeScriptController.invalidateCallCount, 1)
    }

    func testImageBlockingChangeBeforeInitialRulesRefreshesBeforeFirstLoad() async {
        let notificationCenter = NotificationCenter()
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let fixture = makeFixture(
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        defer { fixture.session.invalidate() }

        preference.isEnabled = true
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()
        fixture.installer.completeInstallation()
        fixture.session.loadHome()
        fixture.session.loadHome()

        XCTAssertEqual(fixture.installer.refreshCallCount, 1)
        XCTAssertTrue(fixture.runtime.loadedRequests.isEmpty)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
        XCTAssertEqual(fixture.noImageModeScriptController.enabledValues, [false, true])

        fixture.installer.completeNextRefresh()

        XCTAssertEqual(
            fixture.runtime.loadedRequests.map(\.url),
            [fixture.configuration.homeURL]
        )
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
    }

    func testImageBlockingChangesDuringRefreshAreSerializedWithoutDroppingIntent() async throws {
        let notificationCenter = NotificationCenter()
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let fixture = makeFixture(
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        finishInitialLoad(in: fixture)
        defer { fixture.session.invalidate() }

        preference.isEnabled = true
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()
        preference.isEnabled = false
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()

        XCTAssertEqual(fixture.installer.refreshCallCount, 1)
        fixture.installer.completeNextRefresh()

        XCTAssertEqual(fixture.installer.refreshCallCount, 2)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)

        fixture.installer.completeNextRefresh()

        XCTAssertEqual(fixture.installer.refreshCallCount, 2)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 1)
        XCTAssertEqual(fixture.noImageModeScriptController.enabledValues, [false, true, false])
        try commitReloadNavigation(in: fixture)
    }

    func testImageBlockingObserverIgnoresNoOpAndStopsAfterInvalidate() async {
        let notificationCenter = NotificationCenter()
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let fixture = makeFixture(
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        fixture.installer.completeInstallation()

        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()

        XCTAssertEqual(fixture.installer.refreshCallCount, 0)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)

        fixture.session.invalidate()
        preference.isEnabled = true
        notificationCenter.post(
            name: .FloorpWebPanelImageBlockingPreferenceDidChange,
            object: nil
        )
        await Task.yield()

        XCTAssertEqual(fixture.installer.refreshCallCount, 0)
        XCTAssertEqual(fixture.runtime.reloadCallCount, 0)
        XCTAssertEqual(fixture.installer.invalidateCallCount, 1)
        XCTAssertEqual(fixture.noImageModeScriptController.enabledValues, [false])
        XCTAssertEqual(fixture.noImageModeScriptController.invalidateCallCount, 1)
    }

    func testRecreatedSessionReadsLatestImageBlockingPreferenceAfterUnload() throws {
        let notificationCenter = NotificationCenter()
        let preference = MockFloorpWebPanelImageBlockingPreference()
        let first = makeFixture(
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        let firstAdapter = try XCTUnwrap(first.installerFactory.tabs.first)
        XCTAssertFalse(firstAdapter.imageContentBlockingEnabled())
        XCTAssertEqual(first.noImageModeScriptController.enabledValues, [false])

        first.session.unload()
        preference.isEnabled = true

        let recreated = makeFixture(
            imageContentBlockingEnabled: { preference.isEnabled },
            notificationCenter: notificationCenter
        )
        defer { recreated.session.invalidate() }
        let recreatedAdapter = try XCTUnwrap(recreated.installerFactory.tabs.first)

        XCTAssertTrue(recreatedAdapter.imageContentBlockingEnabled())
        XCTAssertEqual(first.installer.invalidateCallCount, 1)
        XCTAssertEqual(first.noImageModeScriptController.invalidateCallCount, 1)
        XCTAssertEqual(recreated.noImageModeScriptController.enabledValues, [true])
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
        zoomLevel: FloorpWebPanelZoomLevel = .defaultLevel,
        contentMode: FloorpWebPanelContentMode = .mobile,
        restorationURL: URL? = nil,
        imageContentBlockingEnabled: @escaping @MainActor () -> Bool = { false },
        notificationCenter: NotificationCenter = .default,
        openInMainBrowser: @escaping FloorpWebPanelNavigationExecutor.OpenInMainBrowser = { _ in }
    ) -> Fixture {
        let runtime = MockFloorpWebPanelWebViewRuntime()
        let installer = MockFloorpWebPanelContentRuleInstaller()
        let installerFactory = MockFloorpWebPanelContentRuleInstallerFactory(installer: installer)
        let noImageModeScriptController = MockFloorpWebPanelNoImageModeScriptController()
        let noImageModeScriptControllerFactory =
            MockFloorpWebPanelNoImageModeScriptControllerFactory(
                controller: noImageModeScriptController
            )
        let configuration = FloorpWebPanelSessionConfiguration(
            panelTitle: "Panel",
            homeURL: URL(string: "https://example.com/home")!,
            iconName: "globe",
            zoomLevel: zoomLevel,
            contentMode: contentMode
        )
        let navigationExecutor = FloorpWebPanelNavigationExecutor(
            windowUUID: windowUUID,
            isPrivate: isPrivate,
            contentMode: contentMode,
            openInMainBrowser: openInMainBrowser
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
            noImageModeScriptControllerFactory: noImageModeScriptControllerFactory,
            navigationExecutor: navigationExecutor,
            imageContentBlockingEnabled: imageContentBlockingEnabled,
            notificationCenter: notificationCenter,
            restorationURL: restorationURL
        )
        return Fixture(
            session: session,
            runtime: runtime,
            installer: installer,
            installerFactory: installerFactory,
            noImageModeScriptController: noImageModeScriptController,
            noImageModeScriptControllerFactory: noImageModeScriptControllerFactory,
            configuration: configuration,
            navigationExecutor: navigationExecutor
        )
    }

    private func updateContentMode(
        _ contentMode: FloorpWebPanelContentMode,
        in fixture: Fixture
    ) {
        fixture.session.updateConfiguration(FloorpWebPanelSessionConfiguration(
            panelTitle: fixture.configuration.panelTitle,
            homeURL: fixture.configuration.homeURL,
            iconName: fixture.configuration.iconName,
            zoomLevel: fixture.configuration.zoomLevel,
            contentMode: contentMode
        ))
    }

    @discardableResult
    private func beginContentModeNavigation(
        in fixture: Fixture,
        navigationID: FloorpWebPanelNavigationIdentity? = nil
    ) throws -> FloorpWebPanelNavigationIdentity {
        let navigationID = try XCTUnwrap(
            navigationID ?? fixture.runtime.reloadFromOriginNavigationIDs.last
        )
        return bindContentModeNavigation(navigationID, in: fixture)
    }

    @discardableResult
    private func beginReloadNavigation(
        in fixture: Fixture,
        navigationID: FloorpWebPanelNavigationIdentity? = nil
    ) throws -> FloorpWebPanelNavigationIdentity {
        let navigationID = try XCTUnwrap(
            navigationID ?? fixture.runtime.reloadNavigationIDs.last
        )
        return bindContentModeNavigation(navigationID, in: fixture)
    }

    @discardableResult
    private func bindContentModeNavigation(
        _ navigationID: FloorpWebPanelNavigationIdentity,
        in fixture: Fixture
    ) -> FloorpWebPanelNavigationIdentity {
        let preferences = WKWebpagePreferences()
        XCTAssertTrue(fixture.navigationExecutor.applyContentMode(
            to: fixture.runtime.retainedWebView,
            preferences: preferences,
            for: FloorpWebPanelNavigationRequest(
                url: fixture.runtime.currentURL,
                target: .mainFrame
            )
        ))
        fixture.navigationExecutor.bindPendingContentMode(to: navigationID)
        return navigationID
    }

    private func bindAboutBlankNavigation(
        _ navigationID: FloorpWebPanelNavigationIdentity,
        in fixture: Fixture
    ) {
        let preferences = WKWebpagePreferences()
        XCTAssertFalse(fixture.navigationExecutor.applyContentMode(
            to: fixture.runtime.retainedWebView,
            preferences: preferences,
            for: FloorpWebPanelNavigationRequest(
                url: fixture.runtime.currentURL,
                target: .mainFrame
            )
        ))
        fixture.navigationExecutor.bindPendingContentMode(to: navigationID)
    }

    private func commitContentModeNavigation(in fixture: Fixture) throws {
        let navigationID = try beginContentModeNavigation(in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(navigationID)
    }

    private func commitReloadNavigation(in fixture: Fixture) throws {
        let navigationID = try beginReloadNavigation(in: fixture)
        fixture.navigationExecutor.commitContentModeNavigation(navigationID)
    }

    private func finishInitialLoad(in fixture: Fixture) {
        fixture.installer.completeInstallation()
        fixture.runtime.currentURL = fixture.configuration.homeURL
        fixture.runtime.stateDidChange?()
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
        let installerFactory: MockFloorpWebPanelContentRuleInstallerFactory
        let noImageModeScriptController: MockFloorpWebPanelNoImageModeScriptController
        let noImageModeScriptControllerFactory:
            MockFloorpWebPanelNoImageModeScriptControllerFactory
        let configuration: FloorpWebPanelSessionConfiguration
        let navigationExecutor: FloorpWebPanelNavigationExecutor
    }
}

@MainActor
final class FloorpWebPanelNavigationExecutorTests: XCTestCase {
    func testMainFrameContentModeAppliesPreferredModeAndDomainUserAgent() throws {
        let executor = FloorpWebPanelNavigationExecutor(
            windowUUID: .XCTestDefaultUUID,
            isPrivate: false,
            contentMode: .desktop,
            openInMainBrowser: { _ in }
        )
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let preferences = WKWebpagePreferences()
        let url = try XCTUnwrap(URL(string: "https://subdomain.google.com/path"))
        var committedModes = [FloorpWebPanelContentMode]()
        executor.contentModeDidCommit = { _, contentMode in
            committedModes.append(contentMode)
        }
        let desktopNavigationID = FloorpWebPanelNavigationIdentity.synthetic()

        XCTAssertTrue(executor.applyContentMode(
            to: webView,
            preferences: preferences,
            for: FloorpWebPanelNavigationRequest(url: url, target: .mainFrame)
        ))
        XCTAssertEqual(preferences.preferredContentMode, .desktop)
        XCTAssertEqual(
            webView.customUserAgent,
            UserAgent.getUserAgent(
                domain: url.baseDomain ?? "",
                platform: .Desktop
            )
        )
        XCTAssertTrue(committedModes.isEmpty)
        executor.bindPendingContentMode(to: desktopNavigationID)
        executor.commitContentModeNavigation(desktopNavigationID)
        XCTAssertEqual(committedModes, [.desktop])

        executor.updateContentMode(.mobile)
        let mobileNavigationID = FloorpWebPanelNavigationIdentity.synthetic()
        XCTAssertTrue(executor.applyContentMode(
            to: webView,
            preferences: preferences,
            for: FloorpWebPanelNavigationRequest(url: url, target: .mainFrame)
        ))
        XCTAssertEqual(preferences.preferredContentMode, .mobile)
        XCTAssertEqual(
            webView.customUserAgent,
            UserAgent.getUserAgent(
                domain: url.baseDomain ?? "",
                platform: .Mobile
            )
        )
        XCTAssertEqual(committedModes, [.desktop])
        executor.bindPendingContentMode(to: mobileNavigationID)
        executor.commitContentModeNavigation(mobileNavigationID)
        XCTAssertEqual(committedModes, [.desktop, .mobile])
    }

    func testAboutBlankTracksLifecycleWithoutApplyingHTTPContentMode() throws {
        let executor = FloorpWebPanelNavigationExecutor(
            windowUUID: .XCTestDefaultUUID,
            isPrivate: false,
            contentMode: .desktop,
            openInMainBrowser: { _ in }
        )
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.customUserAgent = "sentinel"
        let preferences = WKWebpagePreferences()
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let committedNavigationID = FloorpWebPanelNavigationIdentity.synthetic()
        let failedNavigationID = FloorpWebPanelNavigationIdentity.synthetic()
        var committed = [(FloorpWebPanelNavigationIdentity, FloorpWebPanelContentMode)]()
        var failed = [FloorpWebPanelNavigationIdentity]()
        executor.contentModeDidCommit = { committed.append(($0, $1)) }
        executor.contentModeNavigationDidFail = { failed.append($0) }

        XCTAssertFalse(executor.applyContentMode(
            to: webView,
            preferences: preferences,
            for: FloorpWebPanelNavigationRequest(url: url, target: .mainFrame)
        ))
        XCTAssertEqual(preferences.preferredContentMode, .recommended)
        XCTAssertEqual(webView.customUserAgent, "sentinel")
        executor.bindPendingContentMode(to: committedNavigationID)
        executor.commitContentModeNavigation(committedNavigationID)

        XCTAssertEqual(committed.map(\.0), [committedNavigationID])
        XCTAssertEqual(committed.map(\.1), [.desktop])

        XCTAssertFalse(executor.applyContentMode(
            to: webView,
            preferences: preferences,
            for: FloorpWebPanelNavigationRequest(url: url, target: .mainFrame)
        ))
        executor.bindPendingContentMode(to: failedNavigationID)
        executor.failContentModeNavigation(failedNavigationID)
        XCTAssertEqual(failed, [failedNavigationID])
    }

    func testContentModeCallbacksStayBoundToEachNavigationIdentity() throws {
        let executor = FloorpWebPanelNavigationExecutor(
            windowUUID: .XCTestDefaultUUID,
            isPrivate: false,
            contentMode: .mobile,
            openInMainBrowser: { _ in }
        )
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let url = try XCTUnwrap(URL(string: "https://example.com/path"))
        let supersededNavigationID = FloorpWebPanelNavigationIdentity.synthetic()
        let latestNavigationID = FloorpWebPanelNavigationIdentity.synthetic()
        var committedIDs = [FloorpWebPanelNavigationIdentity]()
        var committedModes = [FloorpWebPanelContentMode]()
        var failedIDs = [FloorpWebPanelNavigationIdentity]()
        executor.contentModeDidCommit = { navigationID, contentMode in
            committedIDs.append(navigationID)
            committedModes.append(contentMode)
        }
        executor.contentModeNavigationDidFail = { failedIDs.append($0) }

        XCTAssertTrue(executor.applyContentMode(
            to: webView,
            preferences: WKWebpagePreferences(),
            for: FloorpWebPanelNavigationRequest(url: url, target: .mainFrame)
        ))
        executor.bindPendingContentMode(to: supersededNavigationID)
        executor.updateContentMode(.desktop)
        XCTAssertTrue(executor.applyContentMode(
            to: webView,
            preferences: WKWebpagePreferences(),
            for: FloorpWebPanelNavigationRequest(url: url, target: .mainFrame)
        ))
        executor.bindPendingContentMode(to: latestNavigationID)

        executor.webView(webView, didCommit: nil)
        executor.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: URLError(.cancelled)
        )
        executor.failContentModeNavigation(supersededNavigationID)
        executor.commitContentModeNavigation(latestNavigationID)
        executor.commitContentModeNavigation(supersededNavigationID)

        XCTAssertEqual(failedIDs, [supersededNavigationID])
        XCTAssertEqual(committedIDs, [latestNavigationID])
        XCTAssertEqual(committedModes, [.desktop])
    }

    func testContentModeDoesNotMutateSubframeNewWindowOrCancelledNavigation() throws {
        let executor = FloorpWebPanelNavigationExecutor(
            windowUUID: .XCTestDefaultUUID,
            isPrivate: false,
            contentMode: .desktop,
            openInMainBrowser: { _ in }
        )
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.customUserAgent = "sentinel"
        let url = try XCTUnwrap(URL(string: "https://example.com/path"))

        for target in [
            FloorpWebPanelNavigationTarget.subframe,
            FloorpWebPanelNavigationTarget.newWindow,
        ] {
            let preferences = WKWebpagePreferences()
            XCTAssertFalse(executor.applyContentMode(
                to: webView,
                preferences: preferences,
                for: FloorpWebPanelNavigationRequest(url: url, target: target)
            ))
            XCTAssertEqual(preferences.preferredContentMode, .recommended)
            XCTAssertEqual(webView.customUserAgent, "sentinel")
        }

        let preferences = WKWebpagePreferences()
        XCTAssertFalse(executor.applyContentMode(
            to: webView,
            preferences: preferences,
            for: FloorpWebPanelNavigationRequest(
                url: try XCTUnwrap(URL(string: "javascript:alert(1)")),
                target: .mainFrame
            )
        ))
        XCTAssertEqual(preferences.preferredContentMode, .recommended)
        XCTAssertEqual(webView.customUserAgent, "sentinel")
    }

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
    private(set) var pageZoom: CGFloat = 1
    private(set) var pageZoomAssignments = [CGFloat]()
    private(set) var loadedRequests = [URLRequest]()
    private(set) var loadNavigationIDs = [FloorpWebPanelNavigationIdentity]()
    private(set) var goBackCallCount = 0
    private(set) var goBackNavigationIDs = [FloorpWebPanelNavigationIdentity]()
    private(set) var goForwardCallCount = 0
    private(set) var goForwardNavigationIDs = [FloorpWebPanelNavigationIdentity]()
    private(set) var reloadCallCount = 0
    private(set) var reloadNavigationIDs = [FloorpWebPanelNavigationIdentity]()
    private(set) var reloadFromOriginCallCount = 0
    private(set) var reloadFromOriginNavigationIDs = [FloorpWebPanelNavigationIdentity]()
    private(set) var stopLoadingCallCount = 0
    private(set) var invalidateCallCount = 0
    private(set) var mediaPlaybackSuppressionRequests = [Bool]()
    private var pendingMediaPlaybackCompletions = [
        @MainActor (Result<Void, Error>) -> Void
    ]()
    var delaysMediaPlaybackCompletions = false
    var goBackSucceeds = true
    var reloadSucceeds = true
    var reloadFromOriginSucceeds = true
    var invokesStateChangeDuringReloadFromOrigin = false
    var mediaPlaybackCompletionRelay: MockFloorpWebPanelMediaPlaybackCompletionRelay?

    var pendingMediaPlaybackCompletionCount: Int {
        pendingMediaPlaybackCompletions.count
    }

    var contentView: UIView? { invalidateCallCount == 0 ? retainedWebView : nil }
    var webView: WKWebView? { invalidateCallCount == 0 ? retainedWebView : nil }

    func setNavigationExecutor(_ executor: FloorpWebPanelNavigationExecutor?) {}

    @discardableResult
    func load(_ request: URLRequest) -> FloorpWebPanelNavigationIdentity? {
        loadedRequests.append(request)
        let navigationID = FloorpWebPanelNavigationIdentity.synthetic()
        loadNavigationIDs.append(navigationID)
        return navigationID
    }

    @discardableResult
    func goBack() -> FloorpWebPanelNavigationIdentity? {
        goBackCallCount += 1
        guard goBackSucceeds else { return nil }
        let navigationID = FloorpWebPanelNavigationIdentity.synthetic()
        goBackNavigationIDs.append(navigationID)
        return navigationID
    }

    @discardableResult
    func goForward() -> FloorpWebPanelNavigationIdentity? {
        goForwardCallCount += 1
        let navigationID = FloorpWebPanelNavigationIdentity.synthetic()
        goForwardNavigationIDs.append(navigationID)
        return navigationID
    }

    @discardableResult
    func reload() -> FloorpWebPanelNavigationIdentity? {
        reloadCallCount += 1
        let navigationID = reloadSucceeds
            ? FloorpWebPanelNavigationIdentity.synthetic()
            : nil
        if let navigationID {
            reloadNavigationIDs.append(navigationID)
        }
        return navigationID
    }

    @discardableResult
    func reloadFromOrigin() -> FloorpWebPanelNavigationIdentity? {
        reloadFromOriginCallCount += 1
        let navigationID = reloadFromOriginSucceeds
            ? FloorpWebPanelNavigationIdentity.synthetic()
            : nil
        if let navigationID {
            reloadFromOriginNavigationIDs.append(navigationID)
        }
        if invokesStateChangeDuringReloadFromOrigin {
            stateDidChange?()
        }
        return navigationID
    }

    func stopLoading() {
        stopLoadingCallCount += 1
    }

    func setPageZoom(_ pageZoom: CGFloat) {
        guard self.pageZoom != pageZoom else { return }
        self.pageZoom = pageZoom
        pageZoomAssignments.append(pageZoom)
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
    private(set) var tabs = [ContentBlockerTab]()

    init(installer: MockFloorpWebPanelContentRuleInstaller) {
        self.installer = installer
    }

    func makeInstaller(
        for tab: ContentBlockerTab
    ) -> any FloorpWebPanelContentRuleInstalling {
        tabs.append(tab)
        installer
    }
}

@MainActor
private final class MockFloorpWebPanelContentRuleInstaller:
    FloorpWebPanelContentRuleInstalling {
    private var completion: (@MainActor () -> Void)?
    private var refreshCompletions = [@MainActor () -> Void]()
    private(set) var installCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var invalidateCallCount = 0

    func install(completion: @escaping @MainActor () -> Void) {
        installCallCount += 1
        self.completion = completion
    }

    func invalidate() {
        invalidateCallCount += 1
        completion = nil
        refreshCompletions.removeAll()
    }

    func refresh(completion: @escaping @MainActor () -> Void) {
        refreshCallCount += 1
        refreshCompletions.append(completion)
    }

    func completeInstallation() {
        let completion = completion
        self.completion = nil
        completion?()
    }

    func completeNextRefresh() {
        guard !refreshCompletions.isEmpty else { return }
        refreshCompletions.removeFirst()()
    }
}

@MainActor
private final class MockFloorpWebPanelNoImageModeScriptControllerFactory:
    FloorpWebPanelNoImageModeScriptControllerFactory {
    private let controller: MockFloorpWebPanelNoImageModeScriptController
    private(set) var webViews = [WeakReference<WKWebView>]()
    private(set) var initialEnabledValues = [Bool]()

    init(controller: MockFloorpWebPanelNoImageModeScriptController) {
        self.controller = controller
    }

    func makeController(
        for webView: WKWebView,
        isEnabled: Bool
    ) -> any FloorpWebPanelNoImageModeScriptControlling {
        webViews.append(WeakReference(webView))
        initialEnabledValues.append(isEnabled)
        controller.setEnabled(isEnabled)
        return controller
    }
}

@MainActor
private final class MockFloorpWebPanelNoImageModeScriptController:
    FloorpWebPanelNoImageModeScriptControlling {
    private(set) var enabledValues = [Bool]()
    private(set) var invalidateCallCount = 0

    func setEnabled(_ isEnabled: Bool) {
        enabledValues.append(isEnabled)
    }

    func invalidate() {
        invalidateCallCount += 1
    }
}

@MainActor
private final class MockFloorpWebPanelImageBlockingPreference {
    var isEnabled = false
}
