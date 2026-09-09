// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
import Common
import Glean
import WebKit
import Shared

@testable import Client

class BrowserViewControllerWebViewDelegateTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var profile: MockProfile!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tabManager: MockTabManager!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var fileManager: MockFileManager!
    private var allowPolicyRawValue: Int {
        return WKNavigationActionPolicy.allow.rawValue
    }
    private lazy var allowBlockingUniversalLinksPolicy = WKNavigationActionPolicy(rawValue: allowPolicyRawValue + 2)

    override func setUp() async throws {
        try await super.setUp()
        await DependencyHelperMock().bootstrapDependencies()
        profile = MockProfile()
        tabManager = MockTabManager()
        fileManager = MockFileManager()
    }

    override func tearDown() async throws {
        profile = nil
        tabManager = nil
        fileManager = nil
        DependencyHelperMock().reset()
        try await super.tearDown()
    }

    // MARK: - Decide policy for navigation action
    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelWhenTabNotInTabManager() {
        let subject = createSubject()
        let url = URL(string: "https://example.com")!
        let tab = createTab()

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelFacetimeScheme() {
        let subject = createSubject()
        let url = URL(string: "facetime://testuser")!
        let tab = createTab()
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelFacetimeAudioScheme() {
        let subject = createSubject()
        let url = URL(string: "facetime-audio://testuser")!
        let tab = createTab()
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelTelScheme() {
        let subject = createSubject()
        let url = URL(string: "tel://3484563742")!
        let tab = createTab()
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelAppStoreScheme() {
        let subject = createSubject()
        let url = URL(string: "itms-apps://test-app")!
        let tab = createTab()
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelAppStoreURL() {
        let subject = createSubject()
        let url = URL(string: "https://apps.apple.com/test-app")!
        let tab = createTab()
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_allowsAnyWebsite_withNormalTabs() {
        let subject = createSubject()
        let tab = createTab()
        let url = URL(string: "https://www.example.com")!
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .allow)
        }
    }

    @MainActor
    func testNavigationProtectionFailureAlertUsesTopPresenterAndDeduplicatesIdentity() throws {
        let harness = try makeNavigationProtectionFailureAlertHarness(prefix: "presentation")
        defer { harness.cleanup() }

        harness.subject.presentNavigationProtectionFailure(
            harness.failure,
            for: harness.tab,
            webView: harness.webView,
            generation: harness.generation,
            host: harness.host
        )

        let firstAlert = try XCTUnwrap(
            harness.presenter.presentedControllers.first as? UIAlertController
        )
        XCTAssertEqual(harness.presenter.presentedControllers.count, 1)
        XCTAssertTrue(harness.subject.navigationProtectionFailureAlertState?.alert === firstAlert)

        harness.subject.presentNavigationProtectionFailure(
            harness.failure,
            for: harness.tab,
            webView: harness.webView,
            generation: harness.generation,
            host: harness.host
        )

        XCTAssertEqual(harness.presenter.presentedControllers.count, 1)
    }

    @MainActor
    func testNavigationProtectionFailureAlertRetriesFailedPresentationWithoutAcknowledging() async throws {
        let harness = try makeNavigationProtectionFailureAlertHarness(prefix: "presentation-retry")
        defer { harness.cleanup() }
        harness.presenter.completesPresentation = false

        harness.subject.presentNavigationProtectionFailure(
            harness.failure,
            for: harness.tab,
            webView: harness.webView,
            generation: harness.generation,
            host: harness.host
        )
        for _ in 0..<30 {
            if harness.presenter.presentedControllers.count >= 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertGreaterThanOrEqual(harness.presenter.presentedControllers.count, 2)
        XCTAssertFalse(harness.subject.navigationProtectionFailureAlertState?.isAcknowledged == true)
        XCTAssertNotNil(harness.subject.navigationProtectionFailureAlertState)
    }

    @MainActor
    func testNavigationProtectionFailureAlertRejectsBackgroundAndStaleTargets() throws {
        let harness = try makeNavigationProtectionFailureAlertHarness(prefix: "stale")
        defer { harness.cleanup() }
        harness.subject.navigationProtectionFailureSceneForegroundOverrideForTesting = false

        harness.subject.presentNavigationProtectionFailure(
            harness.failure,
            for: harness.tab,
            webView: harness.webView,
            generation: harness.generation,
            host: harness.host
        )

        XCTAssertTrue(harness.presenter.presentedControllers.isEmpty)
        XCTAssertNil(harness.subject.navigationProtectionFailureAlertState)

        harness.subject.navigationProtectionFailureSceneForegroundOverrideForTesting = true
        let otherTab = createTab()
        tabManager.tabs.append(otherTab)
        tabManager.normalTabs.append(otherTab)
        tabManager.selectedTab = otherTab
        harness.subject.presentNavigationProtectionFailure(
            harness.failure,
            for: harness.tab,
            webView: harness.webView,
            generation: harness.generation,
            host: harness.host
        )

        XCTAssertTrue(harness.presenter.presentedControllers.isEmpty)
        XCTAssertNil(harness.subject.navigationProtectionFailureAlertState)
    }

    @MainActor
    func testNavigationProtectionFailureAlertRoutesToExtensionsAndClearsForNewNavigation() async throws {
        let harness = try makeNavigationProtectionFailureAlertHarness(prefix: "route")
        defer { harness.cleanup() }
        let navigationHandler = MockBrowserCoordinator()
        harness.subject.navigationHandler = navigationHandler

        harness.subject.presentNavigationProtectionFailure(
            harness.failure,
            for: harness.tab,
            webView: harness.webView,
            generation: harness.generation,
            host: harness.host
        )
        let state = try XCTUnwrap(harness.subject.navigationProtectionFailureAlertState)
        let alert = try XCTUnwrap(state.alert)
        let openSettingsAction = try XCTUnwrap(alert.actions.last)
        let openSettingsHandler = try XCTUnwrap(state.openSettingsActionHandlerForTesting)
        openSettingsHandler(openSettingsAction)
        for _ in 0..<10 where navigationHandler.showSettingsCalled == 0 {
            await Task.yield()
        }

        XCTAssertEqual(navigationHandler.showSettingsCalled, 1)
        XCTAssertTrue(harness.subject.navigationProtectionFailureAlertState?.isAcknowledged == true)
        XCTAssertNil(harness.subject.navigationProtectionFailureAlertState?.alert)

        harness.subject.openWebExtensionSettingsForNavigationProtectionFailure()
        await Task.yield()
        XCTAssertEqual(navigationHandler.showSettingsCalled, 1)

        let action = MockNavigationAction(
            url: try XCTUnwrap(URL(string: "https://example.com/retry")),
            type: .linkActivated
        )
        var decidedPolicy: WKNavigationActionPolicy?
        harness.subject.webView(harness.webView, decidePolicyFor: action) { policy in
            decidedPolicy = policy
        }

        XCTAssertEqual(decidedPolicy, .allow)
        XCTAssertNil(harness.subject.navigationProtectionFailureAlertState)
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_reconcilesWebExtensionPolicyBeforeAllowingMainFrameNavigation()
        async throws {
        let fixture = try makeIsolatedNativeExtensionProfile(prefix: "navigation-policy")
        let isolatedProfile = fixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: isolatedProfile)
        defer { fixture.cleanup() }
        let subject = MockBrowserViewController(
            profile: isolatedProfile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        subject.mockIsMainFrameNavigation = true
        trackForMemoryLeaks(subject)

        let tab = Tab(
            profile: isolatedProfile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        tab.webView = MockTabWebView(tab: tab)
        let url = try XCTUnwrap(URL(string: "https://example.com/fresh-navigation"))
        tab.url = url
        tabManager.tabs = [tab]
        tabManager.normalTabs = [tab]
        tabManager.selectedTab = tab
        host.register(tabManager: tabManager)
        try await host.installBundledExtension(
            identifier: FloorpNativeWebExtensionCatalog.darkReader.identifier
        )
        XCTAssertTrue(host.needsBackgroundReadiness(beforeNavigating: tab, to: url))

        let staleAction = MockNavigationAction(url: url, type: .linkActivated)
        let currentAction = MockNavigationAction(url: url, type: .linkActivated)
        // A nil target frame is the shape WebKit uses for window.open and
        // target=_blank. It still represents a new top-level request and must
        // cross the native extension readiness barrier.
        XCTAssertNil(staleAction.targetFrame)
        XCTAssertNil(currentAction.targetFrame)
        let stalePolicy = expectation(description: "Stale navigation is cancelled")
        let currentPolicy = expectation(description: "Latest navigation is allowed")
        var staleCallbackCount = 0
        var currentCallbackCount = 0

        subject.webView(tab.webView!, decidePolicyFor: staleAction) { policy in
            staleCallbackCount += 1
            XCTAssertEqual(policy, .cancel)
            stalePolicy.fulfill()
        }
        subject.webView(tab.webView!, decidePolicyFor: currentAction) { policy in
            currentCallbackCount += 1
            XCTAssertEqual(policy, .allow)
            currentPolicy.fulfill()
        }

        await fulfillment(of: [stalePolicy, currentPolicy], timeout: 10)
        XCTAssertEqual(staleCallbackCount, 1)
        XCTAssertEqual(currentCallbackCount, 1)
        XCTAssertFalse(host.consumePreparedNavigation(staleAction))
        XCTAssertFalse(host.consumePreparedNavigation(currentAction))

        let supersededAfterPreparation = MockNavigationAction(
            url: url,
            type: .linkActivated
        )
        var didSupersedeAfterPreparation = false
        host.navigationPreparationCompletedHookForTesting = { preparedTab, preparedAction in
            guard preparedAction === supersededAfterPreparation,
                  !didSupersedeAfterPreparation else { return }
            didSupersedeAfterPreparation = true
            _ = host.beginNavigationPreparation(for: preparedTab)
        }
        defer { host.navigationPreparationCompletedHookForTesting = nil }
        let supersededPolicy = expectation(
            description: "Navigation superseded after preparation is cancelled"
        )
        var supersededCallbackCount = 0
        subject.webView(tab.webView!, decidePolicyFor: supersededAfterPreparation) { policy in
            supersededCallbackCount += 1
            XCTAssertEqual(policy, .cancel)
            supersededPolicy.fulfill()
        }
        await fulfillment(of: [supersededPolicy], timeout: 10)
        XCTAssertTrue(didSupersedeAfterPreparation)
        XCTAssertEqual(supersededCallbackCount, 1)
        XCTAssertFalse(host.consumePreparedNavigation(supersededAfterPreparation))
    }

    @MainActor
    // swiftlint:disable:next function_body_length
    func testCommittedExtensionTabGatesDocumentReplacementButNotFragmentOrSubframe() async throws {
        let fixture = try makeIsolatedNativeExtensionProfile(prefix: "surface-departure")
        let isolatedProfile = fixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: isolatedProfile)
        defer { fixture.cleanup() }
        let item = FloorpNativeWebExtensionCatalog.darkReader
        try await host.installBundledExtension(identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let subject = MockBrowserViewController(
            profile: isolatedProfile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        trackForMemoryLeaks(subject)
        let tab = Tab(
            profile: isolatedProfile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        tab.tabDelegate = subject
        let configuration = WKWebViewConfiguration()
        host.attach(to: configuration)
        tab.createWebview(configuration: configuration)
        tabManager.tabs = [tab]
        tabManager.normalTabs = [tab]
        tabManager.selectedTab = tab
        host.register(tabManager: tabManager)
        defer { host.unregister(windowUUID: tabManager.windowUUID) }

        let optionsURL = try XCTUnwrap(context.optionsPageURL)
        host.load(url: optionsURL, in: tab)
        var extensionWebView = try XCTUnwrap(tab.webView)
        for _ in 0..<80 where extensionWebView.url != optionsURL {
            try await Task.sleep(nanoseconds: 50_000_000)
            extensionWebView = try XCTUnwrap(tab.webView)
        }
        XCTAssertEqual(extensionWebView.url, optionsURL)
        tab.commitFloorpNativeSurfaceNavigation(url: optionsURL)
        host.setNavigationReadinessVerifiedForTesting(
            identifier: item.identifier,
            isPrivate: false
        )
        var closePreparationCount = 0
        host.extensionSurfaceClosePreparationHookForTesting = { identifier, webView in
            XCTAssertEqual(identifier, item.identifier)
            XCTAssertTrue(webView === extensionWebView)
            closePreparationCount += 1
            return true
        }
        defer { host.extensionSurfaceClosePreparationHookForTesting = nil }

        subject.mockIsMainFrameNavigation = true
        var fragmentComponents = try XCTUnwrap(
            URLComponents(url: optionsURL, resolvingAgainstBaseURL: false)
        )
        fragmentComponents.fragment = "appearance"
        let fragmentAction = MockNavigationAction(
            url: try XCTUnwrap(fragmentComponents.url),
            type: .linkActivated
        )
        let fragmentDecision = expectation(description: "Fragment navigation resolved")
        subject.webView(extensionWebView, decidePolicyFor: fragmentAction) { policy in
            XCTAssertEqual(policy, .allow)
            fragmentDecision.fulfill()
        }
        await fulfillment(of: [fragmentDecision], timeout: 2)
        XCTAssertEqual(closePreparationCount, 0)

        var sameExtensionComponents = try XCTUnwrap(
            URLComponents(url: optionsURL, resolvingAgainstBaseURL: false)
        )
        sameExtensionComponents.queryItems = [
            URLQueryItem(name: "shortcut", value: "same-extension"),
        ]
        let sameExtensionURL = try XCTUnwrap(sameExtensionComponents.url)
        var forwardComponents = sameExtensionComponents
        forwardComponents.queryItems = [
            URLQueryItem(name: "history", value: "forward"),
        ]
        let forwardURL = try XCTUnwrap(forwardComponents.url)
        tab.recordFloorpNativeSurfaceTransition(
            toContextIdentifier: item.identifier,
            url: forwardURL
        )
        XCTAssertNotNil(tab.moveFloorpNativeSurfaceHistoryBack())
        XCTAssertEqual(tab.floorpNativeSurfaceForwardTarget?.url, forwardURL)

        let commandPress = MockPress(
            mockKey: MockKey(keyCode: .keyboardLeftGUI)
        )
        let keyboardHandler = subject.keyboardPressesHandler()
        keyboardHandler.handlePressesBegan(Set([commandPress]), with: nil)
        let shortcutAction = MockNavigationAction(
            url: try XCTUnwrap(fragmentComponents.url),
            type: .linkActivated
        )
        let shortcutDecision = expectation(
            description: "Extension link shortcut opens a background tab"
        )
        subject.webView(extensionWebView, decidePolicyFor: shortcutAction) { policy in
            XCTAssertEqual(policy, .cancel)
            shortcutDecision.fulfill()
        }
        await fulfillment(of: [shortcutDecision], timeout: 2)
        keyboardHandler.handlePressesEnded(Set([commandPress]), with: nil)
        XCTAssertTrue(tabManager.addTabWasCalled)
        XCTAssertTrue(tabManager.lastSelectedTabs.isEmpty)
        XCTAssertEqual(closePreparationCount, 0)
        XCTAssertEqual(tab.floorpNativeSurfaceForwardTarget?.url, forwardURL)

        tabManager.addTabWasCalled = false
        let sameExtensionCommandPress = MockPress(
            mockKey: MockKey(keyCode: .keyboardLeftGUI)
        )
        keyboardHandler.handlePressesBegan(Set([sameExtensionCommandPress]), with: nil)
        let sameExtensionShortcutDecision = expectation(
            description: "Non-fragment extension shortcut opens a background tab"
        )
        subject.webView(
            extensionWebView,
            decidePolicyFor: MockNavigationAction(url: sameExtensionURL, type: .linkActivated)
        ) { policy in
            XCTAssertEqual(policy, .cancel)
            sameExtensionShortcutDecision.fulfill()
        }
        await fulfillment(of: [sameExtensionShortcutDecision], timeout: 2)
        keyboardHandler.handlePressesEnded(Set([sameExtensionCommandPress]), with: nil)
        XCTAssertTrue(tabManager.addTabWasCalled)
        XCTAssertEqual(closePreparationCount, 0)
        XCTAssertEqual(tab.floorpNativeSurfaceForwardTarget?.url, forwardURL)

        tabManager.addTabWasCalled = false
        let externalURL = try XCTUnwrap(URL(string: "https://example.com/u-bol-documentation"))
        let externalCommandPress = MockPress(
            mockKey: MockKey(keyCode: .keyboardLeftGUI)
        )
        keyboardHandler.handlePressesBegan(Set([externalCommandPress]), with: nil)
        let externalShortcutDecision = expectation(
            description: "External extension shortcut opens a background tab"
        )
        subject.webView(
            extensionWebView,
            decidePolicyFor: MockNavigationAction(url: externalURL, type: .linkActivated)
        ) { policy in
            XCTAssertEqual(policy, .cancel)
            externalShortcutDecision.fulfill()
        }
        await fulfillment(of: [externalShortcutDecision], timeout: 2)
        keyboardHandler.handlePressesEnded(Set([externalCommandPress]), with: nil)
        XCTAssertTrue(tabManager.addTabWasCalled)
        XCTAssertEqual(closePreparationCount, 0)
        XCTAssertEqual(tab.floorpNativeSurfaceForwardTarget?.url, forwardURL)

        tabManager.addTabWasCalled = false
        tabManager.lastSelectedTabs.removeAll()
        let shiftedCommandPress = MockPress(
            mockKey: MockKey(keyCode: .keyboardLeftGUI)
        )
        let shiftPress = MockPress(
            mockKey: MockKey(keyCode: .keyboardLeftShift)
        )
        let shiftedPresses = Set([shiftedCommandPress, shiftPress])
        keyboardHandler.handlePressesBegan(shiftedPresses, with: nil)
        let foregroundShortcutDecision = expectation(
            description: "Shift-command extension shortcut selects the new tab"
        )
        subject.webView(
            extensionWebView,
            decidePolicyFor: MockNavigationAction(url: externalURL, type: .linkActivated)
        ) { policy in
            XCTAssertEqual(policy, .cancel)
            foregroundShortcutDecision.fulfill()
        }
        await fulfillment(of: [foregroundShortcutDecision], timeout: 2)
        keyboardHandler.handlePressesEnded(shiftedPresses, with: nil)
        XCTAssertTrue(tabManager.addTabWasCalled)
        XCTAssertEqual(tabManager.lastSelectedTabs.count, 1)
        XCTAssertEqual(closePreparationCount, 0)
        XCTAssertEqual(tab.floorpNativeSurfaceForwardTarget?.url, forwardURL)

        subject.mockIsMainFrameNavigation = false
        let subframeAction = MockNavigationAction(
            url: try XCTUnwrap(URL(string: "https://example.com/subframe")),
            type: .other
        )
        let subframeDecision = expectation(description: "Subframe navigation resolved")
        subject.webView(extensionWebView, decidePolicyFor: subframeAction) { policy in
            XCTAssertEqual(policy, .allow)
            subframeDecision.fulfill()
        }
        await fulfillment(of: [subframeDecision], timeout: 2)
        XCTAssertEqual(closePreparationCount, 0)

        subject.mockIsMainFrameNavigation = true
        let replacementAction = MockNavigationAction(
            url: sameExtensionURL,
            type: .linkActivated
        )
        let replacementDecision = expectation(
            description: "Ordinary extension navigation waits for close preparation"
        )
        subject.webView(extensionWebView, decidePolicyFor: replacementAction) { policy in
            XCTAssertEqual(policy, .allow)
            replacementDecision.fulfill()
        }
        await fulfillment(of: [replacementDecision], timeout: 2)
        XCTAssertEqual(closePreparationCount, 1)

        let reloadAction = MockNavigationAction(url: optionsURL, type: .reload)
        let reloadDecision = expectation(description: "Reload waits for close preparation")
        subject.webView(extensionWebView, decidePolicyFor: reloadAction) { policy in
            XCTAssertEqual(policy, .allow)
            reloadDecision.fulfill()
        }
        await fulfillment(of: [reloadDecision], timeout: 2)
        XCTAssertEqual(closePreparationCount, 2)
        XCTAssertTrue(extensionWebView.isUserInteractionEnabled)

        host.setContextReadyForTesting(false, identifier: item.identifier)
        XCTAssertTrue(
            host.routeNavigationIfNeeded(
                tab: tab,
                url: optionsURL,
                navigationType: .reload
            )
        )
        XCTAssertFalse(host.isCurrentExtensionSurfaceURL(optionsURL, in: tab))
        host.setContextReadyForTesting(true, identifier: item.identifier)
        XCTAssertTrue(host.isCurrentExtensionSurfaceURL(optionsURL, in: tab))

        await tab.close()
    }

    @MainActor
    // swiftlint:disable:next function_body_length
    func testCommittedExtensionOptionDownloadsPreserveSurfaceAndClearFailureState() async throws {
        let fixture = try makeIsolatedNativeExtensionProfile(prefix: "surface-download")
        let isolatedProfile = fixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: isolatedProfile)
        defer { fixture.cleanup() }
        let item = FloorpNativeWebExtensionCatalog.darkReader
        try await host.installBundledExtension(identifier: item.identifier)
        let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
        let subject = MockBrowserViewController(
            profile: isolatedProfile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        subject.mockIsMainFrameNavigation = true
        trackForMemoryLeaks(subject)
        let tab = Tab(
            profile: isolatedProfile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        tab.tabDelegate = subject
        let configuration = WKWebViewConfiguration()
        host.attach(to: configuration)
        tab.createWebview(configuration: configuration)
        tabManager.tabs = [tab]
        tabManager.normalTabs = [tab]
        tabManager.selectedTab = tab
        host.register(tabManager: tabManager)
        defer { host.unregister(windowUUID: tabManager.windowUUID) }

        let optionsURL = try XCTUnwrap(context.optionsPageURL)
        var extensionWebView = try await loadCommittedExtensionSurface(
            in: tab,
            host: host,
            optionsURL: optionsURL
        )
        XCTAssertTrue(tab.webView === extensionWebView)
        host.setNavigationReadinessVerifiedForTesting(
            identifier: item.identifier,
            isPrivate: false
        )
        var closePreparationCount = 0
        host.extensionSurfaceClosePreparationHookForTesting = { _, _ in
            closePreparationCount += 1
            return true
        }
        defer { host.extensionSurfaceClosePreparationHookForTesting = nil }

        // Drive the synthetic follow-up policy calls explicitly. This keeps
        // the test deterministic while still verifying that Option starts the
        // same real WKWebView load used in production.
        extensionWebView.navigationDelegate = nil
        let keyboardHandler = subject.keyboardPressesHandler()
        var sameExtensionComponents = try XCTUnwrap(
            URLComponents(url: optionsURL, resolvingAgainstBaseURL: false)
        )
        sameExtensionComponents.queryItems = [
            URLQueryItem(name: "download", value: "same-extension"),
        ]
        let sameExtensionURL = try XCTUnwrap(sameExtensionComponents.url)
        let externalURL = try XCTUnwrap(URL(string: "https://example.invalid/u-bol-download"))

        for targetURL in [sameExtensionURL, externalURL] {
            let optionPress = MockPress(
                mockKey: MockKey(keyCode: .keyboardLeftAlt)
            )
            keyboardHandler.handlePressesBegan(Set([optionPress]), with: nil)
            XCTAssertTrue(keyboardHandler.isOnlyOptionPressed)
            XCTAssertTrue(tab.floorpNativeHasCommittedDocument)
            XCTAssertTrue(
                host.isCurrentExtensionSurfaceURL(
                    try XCTUnwrap(extensionWebView.url),
                    in: tab
                )
            )
            var initialPolicy: WKNavigationActionPolicy?
            let initialDecision = expectation(
                description: "Option extension link starts a forced download"
            )
            subject.webView(
                extensionWebView,
                decidePolicyFor: MockNavigationAction(
                    url: targetURL,
                    type: .linkActivated
                )
            ) { policy in
                initialPolicy = policy
                initialDecision.fulfill()
            }
            keyboardHandler.handlePressesEnded(Set([optionPress]), with: nil)
            await fulfillment(of: [initialDecision], timeout: 2)

            XCTAssertEqual(initialPolicy, .cancel)
            var pendingDownload = try XCTUnwrap(
                subject.pendingDownloadState(for: extensionWebView)
            )
            XCTAssertTrue(pendingDownload.webView === extensionWebView)
            XCTAssertEqual(pendingDownload.initiatingRequest.url, targetURL)
            XCTAssertEqual(
                pendingDownload.sourceExtensionContextIdentifier,
                item.identifier
            )
            XCTAssertEqual(closePreparationCount, 0)

            let syntheticRequest = URLRequest(url: targetURL)
            var syntheticPolicy: WKNavigationActionPolicy?
            subject.webView(
                extensionWebView,
                decidePolicyFor: MockNavigationAction(url: targetURL, type: .other)
            ) { policy in
                syntheticPolicy = policy
            }

            XCTAssertEqual(syntheticPolicy, .allow)
            pendingDownload = try XCTUnwrap(subject.pendingDownloadState(for: extensionWebView))
            XCTAssertTrue(pendingDownload.hasStartedNavigationPolicy)
            XCTAssertEqual(subject.pendingRequest(for: targetURL, in: extensionWebView), syntheticRequest)
            XCTAssertEqual(tab.floorpNativeWebExtensionContextIdentifier, item.identifier)
            XCTAssertTrue(tab.webView === extensionWebView)
            XCTAssertEqual(closePreparationCount, 0)

            subject.clearPendingDownload(for: extensionWebView)
            extensionWebView.stopLoading()
            extensionWebView = try await loadCommittedExtensionSurface(
                in: tab,
                host: host,
                optionsURL: optionsURL
            )

            if targetURL == sameExtensionURL {
                var unexpectedComponents = sameExtensionComponents
                unexpectedComponents.queryItems = [
                    URLQueryItem(name: "download", value: "unexpected-navigation"),
                ]
                let unexpectedURL = try XCTUnwrap(unexpectedComponents.url)
                subject.beginPendingDownload(URLRequest(url: sameExtensionURL), in: extensionWebView)
                var unexpectedPolicy: WKNavigationActionPolicy?
                let unexpectedDecision = expectation(
                    description: "Mismatched synthetic navigation follows ordinary policy"
                )
                subject.webView(
                    extensionWebView,
                    decidePolicyFor: MockNavigationAction(url: unexpectedURL, type: .other)
                ) { policy in
                    unexpectedPolicy = policy
                    unexpectedDecision.fulfill()
                }
                await fulfillment(of: [unexpectedDecision], timeout: 2)
                XCTAssertEqual(unexpectedPolicy, .allow)
                XCTAssertNil(subject.pendingDownloadState(for: extensionWebView))
                XCTAssertEqual(closePreparationCount, 1)
                closePreparationCount = 0
            }
        }

        // Two extension tabs may reach response policy concurrently. Their
        // trust-boundary markers and DownloadHelpers must remain independent,
        // including across a process-wide blob notification and an unrelated
        // policy callback on the first surface.
        let secondTab = Tab(
            profile: isolatedProfile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        secondTab.tabDelegate = subject
        let secondConfiguration = WKWebViewConfiguration()
        host.attach(to: secondConfiguration)
        secondTab.createWebview(configuration: secondConfiguration)
        tabManager.tabs = [tab, secondTab]
        tabManager.normalTabs = [tab, secondTab]
        host.announceTabIfNeeded(secondTab)
        let secondWebView = try await loadCommittedExtensionSurface(
            in: secondTab,
            host: host,
            optionsURL: optionsURL
        )
        XCTAssertTrue(secondTab.webView === secondWebView)

        let backgroundShortcutURL = try XCTUnwrap(
            URL(string: "https://example.invalid/background-shortcut")
        )
        let backgroundOptionPress = MockPress(
            mockKey: MockKey(keyCode: .keyboardLeftAlt)
        )
        keyboardHandler.handlePressesBegan(Set([backgroundOptionPress]), with: nil)
        XCTAssertFalse(
            subject.navigateLinkShortcutIfNeeded(
                url: backgroundShortcutURL,
                sourceTab: secondTab
            )
        )
        keyboardHandler.handlePressesEnded(Set([backgroundOptionPress]), with: nil)
        XCTAssertNil(subject.pendingDownloadState(for: secondWebView))
        XCTAssertEqual(secondWebView.url, optionsURL)

        let concurrentURLA = try XCTUnwrap(
            URL(string: "https://example.invalid/concurrent-download-a")
        )
        let concurrentURLB = try XCTUnwrap(
            URL(string: "https://example.invalid/concurrent-download-b")
        )
        subject.beginPendingDownload(URLRequest(url: concurrentURLA), in: extensionWebView)
        subject.beginPendingDownload(URLRequest(url: concurrentURLB), in: secondWebView)

        subject.handleNotifications(Notification(name: .PendingBlobDownloadAddedToQueue))
        await Task.yield()
        subject.mockIsMainFrameNavigation = false
        subject.mockIsTopLevelNavigation = true
        let preStartSubframeDecision = expectation(
            description: "Pre-start new-window policy preserves forced download"
        )
        subject.webView(
            extensionWebView,
            decidePolicyFor: MockNavigationAction(
                url: try XCTUnwrap(URL(string: "https://example.invalid/pre-start-subframe")),
                type: .other
            )
        ) { _ in preStartSubframeDecision.fulfill() }
        await fulfillment(of: [preStartSubframeDecision], timeout: 2)
        subject.mockIsTopLevelNavigation = nil
        subject.mockIsMainFrameNavigation = true
        XCTAssertEqual(subject.pendingDownloads.count, 2)

        let optionPress = MockPress(mockKey: MockKey(keyCode: .keyboardLeftAlt))
        keyboardHandler.handlePressesBegan(Set([optionPress]), with: nil)
        var secondOptionPolicy: WKNavigationActionPolicy?
        subject.webView(
            extensionWebView,
            decidePolicyFor: MockNavigationAction(
                url: try XCTUnwrap(URL(string: "https://example.invalid/rejected-second-download")),
                type: .linkActivated
            )
        ) { secondOptionPolicy = $0 }
        keyboardHandler.handlePressesEnded(Set([optionPress]), with: nil)
        XCTAssertEqual(secondOptionPolicy, .cancel)
        XCTAssertEqual(
            subject.pendingDownloadState(for: extensionWebView)?.initiatingRequest.url,
            concurrentURLA
        )

        for (webView, targetURL) in [
            (extensionWebView, concurrentURLA),
            (secondWebView, concurrentURLB),
        ] {
            var policy: WKNavigationActionPolicy?
            subject.webView(
                webView,
                decidePolicyFor: MockNavigationAction(
                    url: targetURL,
                    type: .other
                )
            ) { policy = $0 }
            XCTAssertEqual(policy, .allow)
            XCTAssertTrue(
                try XCTUnwrap(subject.pendingDownloadState(for: webView))
                    .hasStartedNavigationPolicy
            )
        }
        XCTAssertEqual(subject.pendingDownloads.count, 2)

        subject.handleNotifications(Notification(name: .PendingBlobDownloadAddedToQueue))
        await Task.yield()
        subject.mockIsMainFrameNavigation = false
        let unrelatedDecision = expectation(
            description: "Unrelated policy preserves both forced downloads"
        )
        subject.webView(
            extensionWebView,
            decidePolicyFor: MockNavigationAction(
                url: try XCTUnwrap(URL(string: "https://example.invalid/subframe")),
                type: .linkActivated
            )
        ) { _ in unrelatedDecision.fulfill() }
        await fulfillment(of: [unrelatedDecision], timeout: 2)
        subject.mockIsMainFrameNavigation = true
        XCTAssertEqual(subject.pendingDownloads.count, 2)

        let dispositionA = subject.pendingDownloadResponseDisposition(
            for: concurrentURLA,
            isForMainFrame: true,
            in: extensionWebView
        )
        let dispositionB = subject.pendingDownloadResponseDisposition(
            for: concurrentURLB,
            isForMainFrame: true,
            in: secondWebView
        )
        XCTAssertFalse(dispositionA.shouldCancel)
        XCTAssertFalse(dispositionB.shouldCancel)
        XCTAssertTrue(dispositionA.forceDownload)
        XCTAssertTrue(dispositionB.forceDownload)
        XCTAssertEqual(dispositionA.request?.url, concurrentURLA)
        XCTAssertEqual(dispositionB.request?.url, concurrentURLB)
        XCTAssertNil(subject.pendingDownloadState(for: extensionWebView))
        XCTAssertNil(subject.pendingDownloadState(for: secondWebView))

        let helperA = try XCTUnwrap(DownloadHelper(
            request: dispositionA.request,
            response: URLResponse(
                url: concurrentURLA,
                mimeType: MIMEType.HTML,
                expectedContentLength: 0,
                textEncodingName: "utf-8"
            ),
            cookieStore: extensionWebView.configuration.websiteDataStore.httpCookieStore
        ))
        let helperB = try XCTUnwrap(DownloadHelper(
            request: dispositionB.request,
            response: URLResponse(
                url: concurrentURLB,
                mimeType: MIMEType.HTML,
                expectedContentLength: 0,
                textEncodingName: "utf-8"
            ),
            cookieStore: secondWebView.configuration.websiteDataStore.httpCookieStore
        ))
        subject.storeDownloadHelper(helperA, for: extensionWebView)
        subject.storeDownloadHelper(helperB, for: secondWebView)
        XCTAssertTrue(
            subject.downloadHelpers[ObjectIdentifier(extensionWebView)] === helperA
        )
        XCTAssertTrue(
            subject.downloadHelpers[ObjectIdentifier(secondWebView)] === helperB
        )
        XCTAssertFalse(helperA === helperB)
        XCTAssertTrue(subject.takeDownloadHelper(for: secondWebView) === helperB)
        XCTAssertTrue(subject.takeDownloadHelper(for: extensionWebView) === helperA)

        let processTerminationURL = try XCTUnwrap(
            URL(string: "https://example.invalid/process-termination-download")
        )
        let processTerminationRequest = URLRequest(url: processTerminationURL)
        let processTerminationHelper = try XCTUnwrap(DownloadHelper(
            request: processTerminationRequest,
            response: URLResponse(
                url: processTerminationURL,
                mimeType: MIMEType.HTML,
                expectedContentLength: 0,
                textEncodingName: "utf-8"
            ),
            cookieStore: secondWebView.configuration.websiteDataStore.httpCookieStore
        ))
        subject.beginPendingDownload(processTerminationRequest, in: secondWebView)
        subject.recordPendingRequest(processTerminationRequest, for: secondWebView)
        subject.storeDownloadHelper(processTerminationHelper, for: secondWebView)
        subject.webViewWebContentProcessDidTerminate(secondWebView)
        XCTAssertNil(subject.pendingDownloadState(for: secondWebView))
        XCTAssertNil(subject.pendingRequest(for: processTerminationURL, in: secondWebView))
        XCTAssertNil(subject.downloadHelpers[ObjectIdentifier(secondWebView)])

        let deletedWebViewURL = try XCTUnwrap(
            URL(string: "https://example.invalid/deleted-webview-download")
        )
        let deletedWebViewRequest = URLRequest(url: deletedWebViewURL)
        let deletedWebViewHelper = try XCTUnwrap(DownloadHelper(
            request: deletedWebViewRequest,
            response: URLResponse(
                url: deletedWebViewURL,
                mimeType: MIMEType.HTML,
                expectedContentLength: 0,
                textEncodingName: "utf-8"
            ),
            cookieStore: secondWebView.configuration.websiteDataStore.httpCookieStore
        ))
        subject.beginPendingDownload(deletedWebViewRequest, in: secondWebView)
        subject.recordPendingRequest(deletedWebViewRequest, for: secondWebView)
        subject.storeDownloadHelper(deletedWebViewHelper, for: secondWebView)
        await secondTab.close()
        XCTAssertNil(subject.pendingDownloadState(for: secondWebView))
        XCTAssertNil(subject.pendingRequest(for: deletedWebViewURL, in: secondWebView))
        XCTAssertNil(subject.downloadHelpers[ObjectIdentifier(secondWebView)])

        let failureRequest = URLRequest(url: externalURL)
        subject.beginPendingDownload(failureRequest, in: extensionWebView)
        subject.webView(
            extensionWebView,
            didFail: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
        XCTAssertNil(subject.pendingDownloadState(for: extensionWebView))

        subject.beginPendingDownload(failureRequest, in: extensionWebView)
        subject.webView(
            extensionWebView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: "WebKitErrorDomain", code: 102)
        )
        XCTAssertNil(subject.pendingDownloadState(for: extensionWebView))

        // Same-document fragments and empty responses may finish without a
        // navigation-response policy callback. Their marker must not affect
        // the next link handled by this extension surface.
        subject.beginPendingDownload(failureRequest, in: extensionWebView)
        subject.webView(extensionWebView, didFinish: nil)
        XCTAssertNil(subject.pendingDownloadState(for: extensionWebView))

        await tab.close()
    }

    @MainActor
    private func loadCommittedExtensionSurface(
        in tab: Tab,
        host: FloorpNativeWebExtensionHost,
        optionsURL: URL
    ) async throws -> TabWebView {
        let navigationWaiter = ExtensionSurfaceNavigationWaiter(
            tab: tab,
            expectedURL: optionsURL
        )
        tab.navigationDelegate = navigationWaiter
        defer { tab.navigationDelegate = nil }

        try await navigationWaiter.waitForNavigation {
            host.load(url: optionsURL, in: tab)
        }
        let webView = try XCTUnwrap(tab.webView)
        XCTAssertTrue(navigationWaiter.didCommit)
        XCTAssertEqual(webView.url, optionsURL)
        XCTAssertFalse(webView.isLoading)
        tab.commitFloorpNativeSurfaceNavigation(url: optionsURL)
        XCTAssertTrue(tab.floorpNativeHasCommittedDocument)
        return webView
    }

    @MainActor
    func testNormalWebOptionDownloadKeepsForcedDownloadMarkerUntilResponse() async throws {
        let subject = MockBrowserViewController(
            profile: profile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        subject.mockIsMainFrameNavigation = true
        trackForMemoryLeaks(subject)
        let tab = Tab(
            profile: profile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        tab.tabDelegate = subject
        tab.createWebview(configuration: WKWebViewConfiguration())
        let webView = try XCTUnwrap(tab.webView)
        webView.navigationDelegate = nil
        tabManager.tabs = [tab]
        tabManager.normalTabs = [tab]
        tabManager.selectedTab = tab
        let targetURL = try XCTUnwrap(URL(string: "https://example.com/download"))
        let keyboardHandler = subject.keyboardPressesHandler()
        let optionPress = MockPress(
            mockKey: MockKey(keyCode: .keyboardLeftAlt)
        )

        keyboardHandler.handlePressesBegan(Set([optionPress]), with: nil)
        var initialPolicy: WKNavigationActionPolicy?
        subject.webView(
            webView,
            decidePolicyFor: MockNavigationAction(url: targetURL, type: .linkActivated)
        ) { policy in
            initialPolicy = policy
        }
        keyboardHandler.handlePressesEnded(Set([optionPress]), with: nil)

        XCTAssertEqual(initialPolicy, .cancel)
        var pendingDownload = try XCTUnwrap(subject.pendingDownloadState(for: webView))
        XCTAssertTrue(pendingDownload.webView === webView)
        XCTAssertEqual(pendingDownload.initiatingRequest.url, targetURL)
        XCTAssertNil(pendingDownload.sourceExtensionContextIdentifier)

        var syntheticPolicy: WKNavigationActionPolicy?
        subject.webView(
            webView,
            decidePolicyFor: MockNavigationAction(url: targetURL, type: .other)
        ) { policy in
            syntheticPolicy = policy
        }

        XCTAssertNotNil(syntheticPolicy)
        XCTAssertNotEqual(syntheticPolicy, .cancel)
        pendingDownload = try XCTUnwrap(subject.pendingDownloadState(for: webView))
        XCTAssertTrue(pendingDownload.webView === webView)
        XCTAssertEqual(pendingDownload.initiatingRequest.url, targetURL)
        XCTAssertEqual(subject.pendingRequest(for: targetURL, in: webView)?.url, targetURL)
        subject.clearPendingDownload(for: webView)
        webView.stopLoading()

        let trackedURL = try XCTUnwrap(URL(string: "https://example.invalid/tracked-download"))
        subject.startPendingDownload(URLRequest(url: trackedURL), in: webView)
        let trackedState = try XCTUnwrap(subject.pendingDownloadState(for: webView))
        let trackedNavigation = try XCTUnwrap(trackedState.navigation)
        subject.webView(webView, didStartProvisionalNavigation: trackedNavigation)
        XCTAssertTrue(subject.pendingDownloadState(for: webView) === trackedState)
        subject.webView(webView, didReceiveServerRedirectForProvisionalNavigation: trackedNavigation)
        XCTAssertTrue(trackedState.hasReceivedServerRedirect)

        let competingURL = try XCTUnwrap(URL(string: "https://example.invalid/competing-navigation"))
        let competingNavigation = try XCTUnwrap(webView.load(URLRequest(url: competingURL)))
        XCTAssertFalse(trackedNavigation === competingNavigation)
        subject.webView(webView, didStartProvisionalNavigation: competingNavigation)
        XCTAssertNil(subject.pendingDownloadState(for: webView))
        webView.stopLoading()
        await tab.close()
    }

    @MainActor
    func testForcedDownloadResponseRecoversRequestAndFailsClosedWhenMissing() throws {
        let subject = createSubject()
        let tab = createTab()
        let webView = try XCTUnwrap(tab.webView)
        tabManager.tabs = [tab]
        tabManager.normalTabs = [tab]
        tabManager.selectedTab = tab
        let targetURL = try XCTUnwrap(URL(string: "https://example.com/download"))

        let unrelatedURL = try XCTUnwrap(URL(string: "https://example.com/unrelated"))
        subject.beginPendingDownload(URLRequest(url: unrelatedURL), in: webView)
        let missingRequestDisposition = subject.pendingDownloadResponseDisposition(
            for: targetURL,
            isForMainFrame: true,
            in: webView
        )
        XCTAssertTrue(missingRequestDisposition.shouldCancel)
        XCTAssertFalse(missingRequestDisposition.forceDownload)
        XCTAssertNil(missingRequestDisposition.request)
        XCTAssertNotNil(subject.pendingDownloadState(for: webView))
        subject.clearPendingDownload(for: webView)

        subject.beginPendingDownload(URLRequest(url: targetURL), in: webView)
        let recoveredRequestDisposition = subject.pendingDownloadResponseDisposition(
            for: targetURL,
            isForMainFrame: true,
            in: webView
        )
        XCTAssertFalse(recoveredRequestDisposition.shouldCancel)
        XCTAssertTrue(recoveredRequestDisposition.forceDownload)
        XCTAssertEqual(recoveredRequestDisposition.request?.url, targetURL)
        XCTAssertNil(subject.pendingDownloadState(for: webView))

        let redirectSourceURL = try XCTUnwrap(URL(string: "https://example.com/redirect"))
        let redirectDestinationURL = try XCTUnwrap(URL(string: "https://cdn.example.com/file"))
        subject.beginPendingDownload(URLRequest(url: redirectSourceURL), in: webView)
        subject.webView(webView, didReceiveServerRedirectForProvisionalNavigation: nil)
        let redirectedResponseDisposition = subject.pendingDownloadResponseDisposition(
            for: redirectDestinationURL,
            isForMainFrame: true,
            in: webView
        )
        XCTAssertFalse(redirectedResponseDisposition.shouldCancel)
        XCTAssertTrue(redirectedResponseDisposition.forceDownload)
        XCTAssertEqual(redirectedResponseDisposition.request?.url, redirectSourceURL)
        XCTAssertNil(subject.pendingDownloadState(for: webView))
    }

    @MainActor
    func testSelectedNativeExtensionSurfaceTransitionsRefreshDisplayedWebView() throws {
        let subject = createSubject()
        let browserCoordinator = MockBrowserCoordinator()
        subject.browserDelegate = browserCoordinator
        let tab = Tab(
            profile: profile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        tabManager.tabs = [tab]
        tabManager.normalTabs = [tab]
        tabManager.selectedTab = tab
        tab.tabDelegate = subject

        tab.createWebview(configuration: WKWebViewConfiguration())
        let initialWebView = try XCTUnwrap(tab.webView)
        XCTAssertTrue(browserCoordinator.shownWebView === initialWebView)

        let extensionConfiguration = WKWebViewConfiguration()
        tab.replaceWebViewForNativeWebExtension(
            contextIdentifier: "test-extension",
            configuration: extensionConfiguration,
            url: try XCTUnwrap(URL(string: "about:blank#extension"))
        )
        let extensionWebView = try XCTUnwrap(tab.webView)
        XCTAssertFalse(extensionWebView === initialWebView)
        XCTAssertTrue(browserCoordinator.shownWebView === extensionWebView)

        tab.replaceWebViewForNativeWebExtension(
            contextIdentifier: nil,
            configuration: nil,
            url: try XCTUnwrap(URL(string: "https://example.com/external"))
        )
        let externalWebView = try XCTUnwrap(tab.webView)
        XCTAssertFalse(externalWebView === extensionWebView)
        XCTAssertTrue(browserCoordinator.shownWebView === externalWebView)

        tab.replaceWebViewForNativeWebExtension(
            contextIdentifier: "test-extension",
            configuration: extensionConfiguration,
            url: try XCTUnwrap(URL(string: "about:blank#extension-back")),
            forceRebuild: true
        )
        let restoredExtensionWebView = try XCTUnwrap(tab.webView)
        XCTAssertFalse(restoredExtensionWebView === externalWebView)
        XCTAssertTrue(browserCoordinator.shownWebView === restoredExtensionWebView)
        XCTAssertEqual(browserCoordinator.showWebViewCalled, 4)
    }

    @MainActor
    func testConcurrentNormalNativeExtensionSurfacesUseIndependentContentControllers() async throws {
        let fixture = try makeIsolatedNativeExtensionProfile(prefix: "concurrent-surfaces")
        let isolatedProfile = fixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: isolatedProfile)
        defer { fixture.cleanup() }
        let item = FloorpNativeWebExtensionCatalog.darkReader
        try await host.installBundledExtension(identifier: item.identifier)

        let subject = BrowserViewController(
            profile: isolatedProfile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        trackForMemoryLeaks(subject)
        let firstTab = Tab(
            profile: isolatedProfile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        let secondTab = Tab(
            profile: isolatedProfile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        let tabs = [firstTab, secondTab]
        tabManager.tabs = tabs
        tabManager.normalTabs = tabs
        tabManager.selectedTab = firstTab
        for tab in tabs {
            tab.tabDelegate = subject
            let configuration = WKWebViewConfiguration()
            host.attach(to: configuration)
            tab.createWebview(configuration: configuration)
        }
        host.register(tabManager: tabManager)
        defer { host.unregister(windowUUID: tabManager.windowUUID) }

        do {
            let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
            let optionsURL = try XCTUnwrap(context.optionsPageURL)
            host.load(url: optionsURL, in: firstTab)
            host.load(url: optionsURL, in: secondTab)

            let firstWebView = try XCTUnwrap(firstTab.webView)
            let secondWebView = try XCTUnwrap(secondTab.webView)
            XCTAssertEqual(firstTab.floorpNativeWebExtensionContextIdentifier, item.identifier)
            XCTAssertEqual(secondTab.floorpNativeWebExtensionContextIdentifier, item.identifier)
            XCTAssertFalse(
                firstWebView.configuration.userContentController
                    === secondWebView.configuration.userContentController
            )
            let firstRuntimeResult = await waitForExtensionRuntime(in: firstWebView)
            let secondRuntimeResult = await waitForExtensionRuntime(in: secondWebView)
            let firstRuntime = try XCTUnwrap(firstRuntimeResult)
            let secondRuntime = try XCTUnwrap(secondRuntimeResult)
            XCTAssertEqual(firstRuntime["identifier"], secondRuntime["identifier"])
            XCTAssertFalse(firstRuntime["identifier"]?.isEmpty == true)
            XCTAssertEqual(firstRuntime["baseURL"], context.baseURL.absoluteString)
            XCTAssertEqual(secondRuntime["baseURL"], context.baseURL.absoluteString)
            XCTAssertTrue(
                context.errors.isEmpty,
                context.errors.map(\.localizedDescription).joined(separator: "\n")
            )
        } catch {
            await firstTab.close()
            await secondTab.close()
            throw error
        }

        await firstTab.close()
        await secondTab.close()
    }

    @MainActor
    func testDisablingSelectedNativeExtensionRefreshesDisplayedBlankSurface() async throws {
        let fixture = try makeIsolatedNativeExtensionProfile(prefix: "disable-surface")
        let isolatedProfile = fixture.profile
        let host = try FloorpNativeWebExtensionHost.install(for: isolatedProfile)
        defer { fixture.cleanup() }
        let item = FloorpNativeWebExtensionCatalog.darkReader
        try await host.installBundledExtension(identifier: item.identifier)

        let subject = BrowserViewController(
            profile: isolatedProfile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        trackForMemoryLeaks(subject)
        let browserCoordinator = MockBrowserCoordinator()
        subject.browserDelegate = browserCoordinator
        let tab = Tab(
            profile: isolatedProfile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        tabManager.tabs = [tab]
        tabManager.normalTabs = [tab]
        tabManager.selectedTab = tab
        tab.tabDelegate = subject
        let baseConfiguration = WKWebViewConfiguration()
        host.attach(to: baseConfiguration)
        tab.createWebview(configuration: baseConfiguration)
        host.register(tabManager: tabManager)
        defer { host.unregister(windowUUID: tabManager.windowUUID) }

        do {
            let context = try XCTUnwrap(host.installedContext(identifier: item.identifier))
            let optionsURL = try XCTUnwrap(context.optionsPageURL)
            host.load(url: optionsURL, in: tab)
            let extensionWebView = try XCTUnwrap(tab.webView)
            XCTAssertEqual(tab.floorpNativeWebExtensionContextIdentifier, item.identifier)
            XCTAssertTrue(browserCoordinator.shownWebView === extensionWebView)

            try await host.setEnabled(false, identifier: item.identifier)

            let blankWebView = try XCTUnwrap(tab.webView)
            XCTAssertNil(tab.floorpNativeWebExtensionContextIdentifier)
            XCTAssertEqual(tab.url?.absoluteString, "about:blank")
            XCTAssertFalse(blankWebView === extensionWebView)
            XCTAssertTrue(browserCoordinator.shownWebView === blankWebView)
            XCTAssertTrue(
                context.errors.isEmpty,
                context.errors.map(\.localizedDescription).joined(separator: "\n")
            )
        } catch {
            await tab.close()
            throw error
        }
        await tab.close()
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_allowsAnyWebsiteBlockingUniversalLink_whenOptionEnabled() {
        let subject = createSubject()
        let tab = createTab()
        let url = URL(string: "https://www.example.com")!
        tabManager.tabs = [tab]
        profile.prefs.setBool(true, forKey: PrefsKeys.BlockOpeningExternalApps)

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, self.allowBlockingUniversalLinksPolicy)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_allowsAnyWebsite_andBlockUniversalLinksWithPrivateTab() {
        let subject = createSubject()
        let tab = createTab(isPrivate: true)
        let url = URL(string: "https://www.example.com")!
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, self.allowBlockingUniversalLinksPolicy)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_addRequestToPending() {
        let subject = createSubject()
        let tab = createTab()
        let url = URL(string: "https://www.example.com")!
        tabManager.tabs = [tab]
        let expectation = XCTestExpectation()

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { _ in
            ensureMainThread {
                XCTAssertNotNil(subject.pendingRequest(for: url, in: tab.webView!))
                expectation.fulfill()
            }
        }

        wait(for: [expectation])
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_allowsLoading_whenBlobSchemeWithNavigationTypeOther() {
        let subject = createSubject()
        let tab = createTab()
        let blob = URL(string: "blob://blobfile")!
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: blob,
                                                              type: .other)) { policy in
            XCTAssertEqual(policy, .allow)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelLoading_withBlobScheme() {
        let subject = createSubject()
        let tab = createTab()
        let blob = URL(string: "blob://blobfile")!
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: blob,
                                                              type: .backForward)) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_allowsLoading_whenLoadingLocalPDFurlPreviouslyDownloaded() {
        let subject = createSubject()
        let tab = createTab()

        let pdfURL = URL(string: "file://test.pdf")!
        tabManager.tabs = [tab]

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: pdfURL,
                                                              type: .other)) { policy in
            XCTAssertEqual(policy, .allow)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_allowMarketPlaceScheme_whenUserAction() {
        let subject = MockBrowserViewController(
            profile: profile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        subject.mockIsMainFrameNavigation = true
        trackForMemoryLeaks(subject)

        let url = URL(string: "marketplace-kit://install?exampleApp.com")!
        let tab = createTab()
        tabManager.tabs = [tab]
        let navigationAction = MockNavigationAction(url: url, type: .linkActivated)

        subject.webView(tab.webView!,
                        decidePolicyFor: navigationAction) { policy in
            XCTAssertEqual(policy, .allow)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelMarketPlaceScheme_whenNotMainFrame() {
        let subject = MockBrowserViewController(
            profile: profile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        subject.mockIsMainFrameNavigation = false
        trackForMemoryLeaks(subject)

        let url = URL(string: "marketplace-kit://install?exampleApp.com")!
        let tab = createTab()
        tabManager.tabs = [tab]
        let navigationAction = MockNavigationAction(url: url, type: .linkActivated)

        subject.webView(tab.webView!,
                        decidePolicyFor: navigationAction) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelMarketPlaceScheme_whenReloadAction() {
        let subject = MockBrowserViewController(
            profile: profile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        subject.mockIsMainFrameNavigation = true
        trackForMemoryLeaks(subject)

        let url = URL(string: "marketplace-kit://install?exampleApp.com")!
        let tab = createTab()
        tabManager.tabs = [tab]
        let navigationAction = MockNavigationAction(url: url, type: .reload)

        subject.webView(tab.webView!,
                        decidePolicyFor: navigationAction) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_allowInternalURL_whenAuthorized() {
        let subject = createSubject()
        let tab = createTab()
        tabManager.tabs = [tab]
        let internalURL = URL(string: "internal://local/about/home")!
        let authorizedURL = InternalURL.authorize(url: internalURL)!

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: authorizedURL,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .allow)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_cancelInternalURL_whenUnprivileged() {
        let subject = createSubject()
        let tab = createTab()
        tabManager.tabs = [tab]
        let url = URL(string: "internal://local/about/home")!

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .cancel)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_allowInternalURL_whenUnprivilegedWithBackForwardNavigation() {
        let subject = createSubject()
        let tab = createTab()
        tabManager.tabs = [tab]
        let url = URL(string: "internal://local/about/home")!

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .backForward)) { policy in
            XCTAssertEqual(policy, .allow)
        }
    }

    @MainActor
    func testWebViewDecidePolicyForNavigationAction_allowInternalURL_whenUnprivilegedReaderModeURL() {
        let subject = createSubject()
        let tab = createTab()
        tabManager.tabs = [tab]
        let url = URL(string: "http://localhost:6571/reader-mode/page")!

        subject.webView(tab.webView!,
                        decidePolicyFor: MockNavigationAction(url: url,
                                                              type: .linkActivated)) { policy in
            XCTAssertEqual(policy, .allow)
        }
    }

    // MARK: - Authentication

    @MainActor
    func testWebViewDidReceiveChallenge_MethodServerTrust() async {
        let subject = createSubject()

        let result = await subject.webView(
            anyWebView(),
            respondTo: anyAuthenticationChallenge(for: "NSURLAuthenticationMethodServerTrust")
        )

        XCTAssertEqual(result.0, .performDefaultHandling)
        XCTAssertNil(result.1)
    }

    @MainActor
    func testWebViewDidReceiveChallenge_MethodHTTPDigest() async {
        let subject = createSubject()

        let result = await subject.webView(
            anyWebView(),
            respondTo: anyAuthenticationChallenge(for: "NSURLAuthenticationMethodHTTPDigest")
        )

        XCTAssertEqual(result.0, .performDefaultHandling)
        XCTAssertNil(result.1)
    }

    @MainActor
    func testWebViewDidReceiveChallenge_MethodHTTPNTLM() async {
        let subject = createSubject()

        let result = await subject.webView(
            anyWebView(),
            respondTo: anyAuthenticationChallenge(for: "NSURLAuthenticationMethodNTLM")
        )

        XCTAssertEqual(result.0, .performDefaultHandling)
        XCTAssertNil(result.1)
    }

    @MainActor
    func testWebViewDidReceiveChallenge_MethodHTTPBasic() async {
        let subject = createSubject()

        let result = await subject.webView(
            anyWebView(),
            respondTo: anyAuthenticationChallenge(for: "NSURLAuthenticationMethodHTTPBasic")
        )

        XCTAssertEqual(result.0, .performDefaultHandling)
        XCTAssertNil(result.1)
    }

    @MainActor
    private func createSubject(gleanWrapper: GleanWrapper = DefaultGleanWrapper()) -> BrowserViewController {
        let subject = BrowserViewController(profile: profile,
                                            tabManager: tabManager,
                                            gleanWrapper: gleanWrapper,
                                            userInitiatedQueue: MockDispatchQueue())
        trackForMemoryLeaks(subject)
        return subject
    }

    @MainActor
    private struct IsolatedNativeExtensionProfile {
        let profile: MockProfile
        let rootDirectory: URL

        func cleanup() {
            FloorpNativeWebExtensionHost.remove(for: profile.localName())
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    @MainActor
    private struct NavigationProtectionFailureAlertHarness {
        let fixture: IsolatedNativeExtensionProfile
        let host: FloorpNativeWebExtensionHost
        let subject: MockBrowserViewController
        let tab: Tab
        let webView: WKWebView
        let window: UIWindow
        let presenter: NavigationFailureRecordingViewController
        let generation: Int
        let failure: FloorpNativeWebExtensionHost.NavigationProtectionFailure

        func cleanup() {
            subject.dismissNavigationProtectionFailureAlert(animated: false)
            subject.view.removeFromSuperview()
            presenter.view.removeFromSuperview()
            window.isHidden = true
            fixture.cleanup()
        }
    }

    @MainActor
    private func makeNavigationProtectionFailureAlertHarness(
        prefix: String
    ) throws -> NavigationProtectionFailureAlertHarness {
        let fixture = try makeIsolatedNativeExtensionProfile(prefix: prefix)
        let host = try FloorpNativeWebExtensionHost.install(for: fixture.profile)
        let subject = MockBrowserViewController(
            profile: fixture.profile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        let tab = Tab(
            profile: fixture.profile,
            isPrivate: false,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        let webView = MockTabWebView(tab: tab)
        tab.webView = webView
        tabManager.tabs = [tab]
        tabManager.normalTabs = [tab]
        tabManager.selectedTab = tab

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        subject.view.frame = window.bounds
        window.addSubview(subject.view)
        webView.frame = subject.view.bounds
        subject.view.addSubview(webView)

        let presenter = NavigationFailureRecordingViewController()
        presenter.view.frame = window.bounds
        window.addSubview(presenter.view)
        subject.viewControllerToPresent = presenter

        let failure = FloorpNativeWebExtensionHost.NavigationProtectionFailure(
            extensionName: "uBlock Origin Lite",
            detail: "Injected navigation readiness failure"
        )
        let generation = host.beginNavigationPreparation(for: tab)
        subject.navigationProtectionFailureSceneForegroundOverrideForTesting = true
        subject.navigationProtectionFailureRecordedFailureOverrideForTesting = failure
        return NavigationProtectionFailureAlertHarness(
            fixture: fixture,
            host: host,
            subject: subject,
            tab: tab,
            webView: webView,
            window: window,
            presenter: presenter,
            generation: generation,
            failure: failure
        )
    }

    @MainActor
    private func makeIsolatedNativeExtensionProfile(
        prefix: String
    ) throws -> IsolatedNativeExtensionProfile {
        let identifier = UUID().uuidString
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "floorp-bvc-web-extension-\(identifier)",
            isDirectory: true
        )
        let profile = MockProfile(
            databasePrefix: "bvc_web_extension_\(prefix)_\(identifier.prefix(8))",
            localName: "bvc-web-extension-\(identifier)",
            fileRootPath: rootDirectory.path
        )
        return IsolatedNativeExtensionProfile(profile: profile, rootDirectory: rootDirectory)
    }

    @MainActor
    private func waitForExtensionRuntime(in webView: WKWebView) async -> [String: String]? {
        for _ in 0..<60 {
            if let value = try? await webView.floorpCallAsyncJavaScript(
                """
                if (document.readyState !== 'complete' ||
                    typeof browser !== 'object' ||
                    typeof browser.runtime !== 'object') {
                    return null;
                }
                return {
                    identifier: browser.runtime.id,
                    baseURL: browser.runtime.getURL('/'),
                };
                """,
                contentWorld: .page,
                timeoutNanoseconds: 2_000_000_000
            ) as? [String: String] {
                return value
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    @MainActor
    private func anyWebView(url: URL? = nil) -> MockTabWebView {
        let tab = MockTabWebView(frame: .zero,
                                 configuration: WKWebViewConfiguration(),
                                 windowUUID: .XCTestDefaultUUID,
                                 certStore: MockProfile().certStore)
        tab.loadedURL = url
        return tab
    }

    @MainActor
    private func createTab(isPrivate: Bool = false) -> Tab {
        let tab = Tab(
            profile: profile,
            isPrivate: isPrivate,
            windowUUID: .XCTestDefaultUUID,
            fileManager: fileManager
        )
        let webView = MockTabWebView(tab: tab)
        tab.webView = webView
        return tab
    }

    private func anyAuthenticationChallenge(for authenticationMethod: String) -> URLAuthenticationChallenge {
        let protectionSpace = URLProtectionSpace(host: "https:test.com",
                                                 port: 443,
                                                 protocol: nil,
                                                 realm: nil,
                                                 authenticationMethod: authenticationMethod)
        return URLAuthenticationChallenge(protectionSpace: protectionSpace,
                                          proposedCredential: nil,
                                          previousFailureCount: 0,
                                          failureResponse: nil,
                                          error: nil,
                                          sender: MockURLAuthenticationChallengeSender())
    }

    private func getCertificate(_ file: String) -> SecCertificate {
        let path = Bundle(for: type(of: self)).path(forResource: file, ofType: "pem")
        let data = try? Data(contentsOf: URL(fileURLWithPath: path!))
        return SecCertificateCreateWithData(nil, data! as CFData)!
    }

    // MARK: - didCommit

    @MainActor
    func testWebViewDidCommit_withNoHandler_clearsTranslationConfiguration() {
        let subject = createSubject()
        let tab = createTab()
        tab.translationConfiguration = TranslationConfiguration(prefs: profile.prefs, state: .inactive)
        (tab.webView as? MockTabWebView)?.loadedURL = URL(string: "https://example.com")
        tabManager.tabs = [tab]

        subject.webView(tab.webView!, didCommit: nil)

        XCTAssertNil(tab.translationConfiguration)
    }

    @MainActor
    func testWebViewDidCommit_withOnNextCommit_callsHandlerAndPreservesTranslationConfiguration() {
        let subject = createSubject()
        let tab = createTab()
        tab.translationConfiguration = TranslationConfiguration(prefs: profile.prefs, state: .inactive)
        var handlerCalled = false
        tab.onNextCommit = { handlerCalled = true }
        (tab.webView as? MockTabWebView)?.loadedURL = URL(string: "https://example.com")
        tabManager.tabs = [tab]

        subject.webView(tab.webView!, didCommit: nil)

        XCTAssertTrue(handlerCalled)
        XCTAssertNil(tab.onNextCommit)
        XCTAssertNotNil(tab.translationConfiguration)
    }

    // This test is being skipped because there are some very strange side effects
    // in webView didFinish because the profile database is not being stubbed out
    // TODO: FXIOS-13435 to look in to this
    @MainActor
    func testWebViewDidFinishNavigation_takeScreenshotWhenTabIsSelected() {
        let subject = createSubject()
        let screenshotHelper = MockScreenshotHelper(controller: subject)
        subject.screenshotHelper = screenshotHelper

        let tab = createTab()
        tabManager.tabs = [tab]
        tabManager.selectedTab = tab

        subject.webView(tab.webView!, didFinish: nil)

        XCTAssertTrue(screenshotHelper.takeScreenshotCalled)
    }

    // MARK: - Google Lens search completion

    @MainActor
    func testWebViewDidFinish_clearsPendingGoogleLensSearch() {
        let gleanWrapper = MockGleanWrapper()
        let subject = createSubject(gleanWrapper: gleanWrapper)
        let tab = createTab()
        tabManager.tabs = [tab]
        tabManager.selectedTab = tab
        subject.googleLensSearches[tab.tabUUID] = GoogleLensSearchState(source: .camera,
                                                                        searchTimerId: gleanWrapper.savedTimerId)

        subject.webView(tab.webView!, didFinish: nil)

        XCTAssertNil(subject.googleLensSearches[tab.tabUUID],
                     "Finishing navigation should report and clear the pending Google Lens search")
        XCTAssertEqual(gleanWrapper.stopAndAccumulateCalled, 1)
    }

    @MainActor
    func testWebViewDidFailProvisionalNavigation_clearsPendingGoogleLensSearch() {
        let gleanWrapper = MockGleanWrapper()
        let subject = createSubject(gleanWrapper: gleanWrapper)
        let tab = createTab()
        tabManager.tabs = [tab]
        subject.googleLensSearches[tab.tabUUID] = GoogleLensSearchState(source: .photoPicker,
                                                                        searchTimerId: gleanWrapper.savedTimerId)

        // Code 102 ("Frame load interrupted") makes the delegate return early right after the
        // Google Lens reporting, keeping the test free of error-page side effects.
        subject.webView(tab.webView!,
                        didFailProvisionalNavigation: nil,
                        withError: NSError(domain: "WebKitErrorDomain", code: 102))

        XCTAssertNil(subject.googleLensSearches[tab.tabUUID],
                     "A failed navigation should report and clear the pending Google Lens search")
        XCTAssertEqual(gleanWrapper.stopAndAccumulateCalled, 1)
    }

    @MainActor
    func testWebViewDidFinish_withWebpageImageSearch_stopsSearchTimer() {
        let gleanWrapper = MockGleanWrapper()
        let subject = createSubject(gleanWrapper: gleanWrapper)
        let tab = createTab()
        tabManager.tabs = [tab]
        tabManager.selectedTab = tab
        subject.googleLensSearches[tab.tabUUID] = GoogleLensSearchState(source: .contextMenu,
                                                                        searchTimerId: gleanWrapper.savedTimerId)

        subject.webView(tab.webView!, didFinish: nil)

        let savedMetrics = gleanWrapper.savedEvents.compactMap { $0 as? TimingDistributionMetricType }
        XCTAssertEqual(gleanWrapper.stopAndAccumulateCalled, 1)
        XCTAssertTrue(savedMetrics.contains { $0 === GleanMetrics.GoogleLens.webpageImageSearchTime })
    }

    @MainActor
    func testWebViewDidFail_withWebpageImageSearch_stopsSearchTimer() {
        let gleanWrapper = MockGleanWrapper()
        let subject = createSubject(gleanWrapper: gleanWrapper)
        let tab = createTab()
        tabManager.tabs = [tab]
        tabManager.selectedTab = tab
        subject.googleLensSearches[tab.tabUUID] = GoogleLensSearchState(source: .contextMenu,
                                                                        searchTimerId: gleanWrapper.savedTimerId)

        subject.webView(tab.webView!,
                        didFailProvisionalNavigation: nil,
                        withError: NSError(domain: "WebKitErrorDomain", code: 102))

        let savedMetrics = gleanWrapper.savedEvents.compactMap { $0 as? TimingDistributionMetricType }
        XCTAssertEqual(gleanWrapper.stopAndAccumulateCalled, 1)
        XCTAssertTrue(savedMetrics.contains { $0 === GleanMetrics.GoogleLens.webpageImageSearchTime })
    }

    @MainActor
    func testWebViewDidFinish_withoutPendingGoogleLensSearch_doesNothing() {
        let subject = createSubject()
        let tab = createTab()
        tabManager.tabs = [tab]
        tabManager.selectedTab = tab

        subject.webView(tab.webView!, didFinish: nil)

        XCTAssertTrue(subject.googleLensSearches.isEmpty)
    }
}

@MainActor
private final class ExtensionSurfaceNavigationWaiter: NSObject, WKNavigationDelegate {
    private weak var tab: Tab?
    private let expectedURL: URL
    private var continuation: CheckedContinuation<Void, any Error>?
    private var loadToken: UUID?
    private(set) var didCommit = false

    init(tab: Tab, expectedURL: URL) {
        self.tab = tab
        self.expectedURL = expectedURL
    }

    func waitForNavigation(
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        start: () -> Void
    ) async throws {
        let token = UUID()
        loadToken = token
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard let self, self.loadToken == token else { return }
                self.complete(.failure(NSError(
                    domain: "ExtensionSurfaceNavigationWaiter",
                    code: 2,
                    userInfo: [NSURLErrorFailingURLErrorKey: self.expectedURL]
                )))
            }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        guard isExpectedNavigation(in: webView) else { return }
        didCommit = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard isExpectedNavigation(in: webView) else { return }
        complete(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        guard shouldHandleFailure(error, in: webView) else { return }
        complete(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        guard shouldHandleFailure(error, in: webView) else { return }
        complete(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === tab?.webView else { return }
        complete(.failure(NSError(domain: "ExtensionSurfaceNavigationWaiter", code: 1)))
    }

    private func complete(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        loadToken = nil
        continuation.resume(with: result)
    }

    private func isExpectedNavigation(in webView: WKWebView) -> Bool {
        webView === tab?.webView && webView.url == expectedURL
    }

    private func shouldHandleFailure(_ error: any Error, in webView: WKWebView) -> Bool {
        guard webView === tab?.webView else { return false }
        let error = error as NSError
        let failingURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if let failingURL {
            return failingURL == expectedURL
        }
        return error.code != NSURLErrorCancelled && webView.url == expectedURL
    }
}

@MainActor
private final class NavigationFailureRecordingViewController: UIViewController {
    private(set) var presentedControllers = [UIViewController]()
    var completesPresentation = true

    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        presentedControllers.append(viewControllerToPresent)
        if completesPresentation {
            completion?()
        }
    }
}
