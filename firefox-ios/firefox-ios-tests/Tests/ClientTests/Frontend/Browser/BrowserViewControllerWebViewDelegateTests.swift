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
    // swiftlint:disable:next function_body_length line_length
    func testWebViewDecidePolicyForNavigationAction_reconcilesWebExtensionPolicyBeforeAllowingMainFrameNavigation() async throws {
        let profileIdentifier = profile.localName()
        let extensionID = try XCTUnwrap(FloorpWebExtensionID(rawValue: "navigation-policy-fixture"))
        let runtime = FloorpWebExtensionRuntime.runtime(
            for: profileIdentifier,
            isPrivateBrowsing: false
        )
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: { _, source in
                guard source.path == "content.js" else {
                    throw FloorpWebExtensionError.unsupported("unexpected test resource")
                }
                return "window.navigationPolicyFixture = true;"
            }
        )
        FloorpWebExtensionCoordinator.install(coordinator)
        let bridgeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-webextension-navigation-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
        let bridgeHost = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: bridgeDirectory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil }
        )
        let messageRuntime = FloorpWebExtensionMessageRuntime(
            backgroundHost: .init(),
            profileKey: .init(profileIdentifier: profileIdentifier, isPrivateBrowsing: false)
        )
        FloorpWebExtensionAPIHostRegistry.install(bridgeHost, messageRuntime: messageRuntime)
        defer {
            FloorpWebExtensionCoordinator.removeCoordinator(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
            FloorpWebExtensionRuntime.removeRuntime(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
            try? FileManager.default.removeItem(at: bridgeDirectory)
        }

        let priorCoreFlag = FloorpFlags.isWebExtensionFeatureEnabled(.core)
        FloorpFlags.setWebExtensionFeature(.core, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.core, enabled: priorCoreFlag) }

        let script = try FloorpWebExtensionRegisteredScript(
            id: "content",
            matches: [FloorpWebExtensionMatchPattern("https://allowed.example/*")],
            javaScript: [FloorpWebExtensionScriptSource("content.js")],
            runAt: .documentStart
        )
        let allowedHost = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        try await coordinator.registerScripts([script], for: extensionID)
        await coordinator.grantPermissions(
            [.scripting],
            requestedHosts: [allowedHost],
            hostAccess: .allRequestedSites,
            to: extensionID
        )

        let subject = MockBrowserViewController(
            profile: profile,
            tabManager: tabManager,
            userInitiatedQueue: MockDispatchQueue()
        )
        subject.mockIsMainFrameNavigation = true
        let tab = createTab()
        let webView = try XCTUnwrap(tab.webView as? MockTabWebView)
        tabManager.tabs = [tab]
        let allowedURL = try XCTUnwrap(URL(string: "https://allowed.example/page"))

        for type in [WKNavigationType.linkActivated, .other, .formSubmitted, .backForward] {
            subject.webView(
                tab.webView!,
                decidePolicyFor: MockNavigationAction(url: allowedURL, type: type)
            ) { policy in
                XCTAssertEqual(policy, .allow)
            }
            XCTAssertEqual(
                tab.webView?.configuration.userContentController.userScripts.filter {
                    $0.source == "window.navigationPolicyFixture = true;"
                }.count,
                1
            )
            XCTAssertEqual(
                tab.webView?.configuration.userContentController.userScripts.filter {
                    $0.source.contains("floorpRuntime_")
                }.count,
                1,
                "The authorised isolated content script must receive exactly one authenticated bridge."
            )
        }

        webView.loadedURL = allowedURL
        let activeDocument = try XCTUnwrap(tab.floorpWebExtensionActiveDocumentContext)
        let activeScripts = webView.configuration.userContentController.userScripts.map(\.source)
        XCTAssertFalse(activeScripts.isEmpty)

        // Regression: A visible authorised document A must survive an initial
        // authorised action B, a denied redirect C, and a final download. The
        // action and redirect callbacks are provisional and cannot replace A.
        let initialDownloadURL = try XCTUnwrap(URL(string: "https://allowed.example/download"))
        let deniedDownloadURL = try XCTUnwrap(URL(string: "https://denied.example/download"))
        subject.webView(
            webView,
            decidePolicyFor: MockNavigationAction(url: initialDownloadURL, type: .other)
        ) { policy in
            XCTAssertEqual(policy, .allow)
        }
        XCTAssertEqual(tab.floorpWebExtensionActiveDocumentContext, activeDocument)
        XCTAssertEqual(webView.configuration.userContentController.userScripts.map(\.source), activeScripts)

        webView.loadedURL = deniedDownloadURL
        subject.webView(webView, didReceiveServerRedirectForProvisionalNavigation: nil)
        XCTAssertEqual(tab.floorpWebExtensionActiveDocumentContext, activeDocument)
        XCTAssertEqual(webView.configuration.userContentController.userScripts.map(\.source), activeScripts)

        // WKNavigationResponse is a WebKit-owned object and cannot safely be
        // synthesized in a unit test. Exercise the same BrowserViewController
        // completion boundary that the response delegate calls before it
        // returns `.download`. The real-WebKit redirect test proves callback
        // timing separately.
        subject.completeFloorpWebExtensionNavigationResponse(
            for: webView,
            responseURL: deniedDownloadURL,
            isForMainFrame: true,
            disposition: .download
        )
        XCTAssertEqual(
            tab.floorpWebExtensionActiveDocumentContext,
            activeDocument,
            "A download response must not replace the active WebExtension document."
        )
        XCTAssertEqual(
            webView.configuration.userContentController.userScripts.map(\.source),
            activeScripts,
            "A download response must preserve the visible page's scripts and authenticated bridge."
        )
        XCTAssertEqual(
            activeScripts.filter { $0 == "window.navigationPolicyFixture = true;" }.count,
            1
        )
        XCTAssertEqual(
            activeScripts.filter { $0.contains("floorpRuntime_") }.count,
            1
        )

        // Regression: the same A -> B -> redirect C lifecycle must preserve A
        // when a response helper returns `.cancel`.
        let initialCancelURL = try XCTUnwrap(URL(string: "https://allowed.example/calendar"))
        let deniedCancelURL = try XCTUnwrap(URL(string: "https://denied.example/calendar"))
        subject.webView(
            webView,
            decidePolicyFor: MockNavigationAction(url: initialCancelURL, type: .other)
        ) { policy in
            XCTAssertEqual(policy, .allow)
        }
        webView.loadedURL = deniedCancelURL
        subject.webView(webView, didReceiveServerRedirectForProvisionalNavigation: nil)
        subject.completeFloorpWebExtensionNavigationResponse(
            for: webView,
            responseURL: deniedCancelURL,
            isForMainFrame: true,
            disposition: .cancel
        )
        XCTAssertEqual(tab.floorpWebExtensionActiveDocumentContext, activeDocument)
        XCTAssertEqual(webView.configuration.userContentController.userScripts.map(\.source), activeScripts)

        // Conversely, once the final denied response is allowed, replacement
        // must happen synchronously before WebKit creates its document.
        let initialAllowedResponseURL = try XCTUnwrap(URL(string: "https://allowed.example/final"))
        let deniedAllowedResponseURL = try XCTUnwrap(URL(string: "https://denied.example/final"))
        subject.webView(
            webView,
            decidePolicyFor: MockNavigationAction(url: initialAllowedResponseURL, type: .other)
        ) { policy in
            XCTAssertEqual(policy, .allow)
        }
        webView.loadedURL = deniedAllowedResponseURL
        subject.webView(webView, didReceiveServerRedirectForProvisionalNavigation: nil)
        subject.completeFloorpWebExtensionNavigationResponse(
            for: webView,
            responseURL: deniedAllowedResponseURL,
            isForMainFrame: true,
            disposition: .allow
        )
        XCTAssertTrue(
            webView.configuration.userContentController.userScripts.isEmpty,
            "Only an allowed final response may replace the visible document's policy."
        )
        XCTAssertEqual(tab.floorpWebExtensionActiveDocumentContext?.url, deniedAllowedResponseURL)

        subject.webView(
            tab.webView!,
            decidePolicyFor: MockNavigationAction(url: deniedAllowedResponseURL, type: .other)
        ) { policy in
            XCTAssertEqual(policy, .allow)
        }
        XCTAssertTrue(tab.webView!.configuration.userContentController.userScripts.isEmpty)

        let internalURL = try XCTUnwrap(URL(string: "internal://local/about/home"))
        subject.webView(
            tab.webView!,
            decidePolicyFor: MockNavigationAction(url: internalURL, type: .backForward)
        ) { policy in
            XCTAssertEqual(policy, .allow)
        }
        XCTAssertTrue(tab.webView!.configuration.userContentController.userScripts.isEmpty)

        await FloorpWebExtensionAPIHostRegistry.removeHost(
            for: .init(profileIdentifier: profileIdentifier, isPrivateBrowsing: false)
        )
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
                XCTAssertNotNil(subject.pendingRequests[url.absoluteString])
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
