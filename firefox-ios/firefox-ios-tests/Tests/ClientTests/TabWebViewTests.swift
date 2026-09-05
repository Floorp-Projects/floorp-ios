// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

@testable import Client

import Common
import XCTest
import WebKit

class TabWebViewTests: XCTestCaseRootViewController, UIGestureRecognizerDelegate {
    private var configuration = WKWebViewConfiguration()
    private var navigationDelegate: MockNavigationDelegate?
    private var tabWebViewDelegate: MockTabWebViewDelegate?
    private let sleepTime: UInt64 = 1 * NSEC_PER_SEC
    let windowUUID: WindowUUID = .XCTestDefaultUUID

    override func setUp() async throws {
        try await super.setUp()
        navigationDelegate = MockNavigationDelegate()
        tabWebViewDelegate = MockTabWebViewDelegate()
        DependencyHelperMock().bootstrapDependencies()
    }

    override func tearDown() async throws {
        navigationDelegate = nil
        tabWebViewDelegate = nil
        DependencyHelperMock().reset()
        try await super.tearDown()
    }

    func testBasicTabWebView_doesntLeak() async throws {
        _ = try await createSubject()
    }

    func testSavedCardsClosure_doesntLeak() async throws {
        let subject = try await createSubject()
        subject.accessoryView.savedCardsClosure = {}
    }

    func testAddPullRefresh() async throws {
        let subject = try await createSubject()
        subject.addPullRefresh {}

        XCTAssertNotNil(subject.scrollView.subviews.first(where: { $0 is PullRefreshView }))
    }

    func testRemovePullRefresh() async throws {
        let subject = try await createSubject()

        subject.addPullRefresh {}
        subject.removePullRefresh()

        XCTAssertNil(subject.subviews.first(where: { $0 is PullRefreshView }))
    }

    func testTabWebView_doesntLeak() {
        let tab = Tab(profile: MockProfile(), windowUUID: windowUUID)
        tab.createWebview(configuration: configuration)

        trackForMemoryLeaks(tab)
    }

    func testTabWebView_load_doesntLeak() {
        let tab = Tab(profile: MockProfile(), windowUUID: windowUUID)
        tab.createWebview(configuration: configuration)
        tab.loadRequest(URLRequest(url: URL(string: "https://www.mozilla.com")!))

        trackForMemoryLeaks(tab)
    }

    func testTabWebView_withLegacySessionData_doesntLeak() {
        let tab = Tab(profile: MockProfile(), windowUUID: windowUUID)
        tab.url = URL(string: "http://yahoo.com/")!
        tab.createWebview(configuration: configuration)

        trackForMemoryLeaks(tab)
    }

    func testTabWebView_withSessionData_doesntLeak() {
        let tab = Tab(profile: MockProfile(), windowUUID: windowUUID)
        tab.createWebview(with: Data(), configuration: configuration)

        trackForMemoryLeaks(tab)
    }

    func testTabWebView_withURL_doesntLeak() {
        let tab = Tab(profile: MockProfile(), windowUUID: windowUUID)
        tab.url = URL(string: "https://www.mozilla.com")!
        tab.createWebview(configuration: configuration)

        trackForMemoryLeaks(tab)
    }

    func testHasOnlySecureContent_returnsTrue_ForLocalPDFFile() throws {
        let tab = Tab(profile: MockProfile(), windowUUID: windowUUID)
        tab.url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test.pdf")
        tab.createWebview(configuration: configuration)

        let tabWebView = try XCTUnwrap(tab.webView)

        XCTAssertTrue(tabWebView.hasOnlySecureContent)
    }

    func testOffloadedNativeWebExtensionSurfaceRestoresItsExtensionConfiguration() async throws {
        let profile = MockProfile()
        let tab = Tab(profile: profile, windowUUID: windowUUID)
        let baseConfiguration = WKWebViewConfiguration()
        baseConfiguration.applicationNameForUserAgent = "Floorp-Base-Configuration"
        let extensionConfiguration = WKWebViewConfiguration()
        extensionConfiguration.applicationNameForUserAgent = "Floorp-Extension-Configuration"
        tab.createWebview(configuration: baseConfiguration)
        tab.replaceWebViewForNativeWebExtension(
            contextIdentifier: "org.example.floorp-extension",
            configuration: extensionConfiguration,
            url: try XCTUnwrap(URL(string: "webkit-extension://example.floorp.internal/options.html"))
        )
        XCTAssertEqual(
            tab.webView?.configuration.applicationNameForUserAgent,
            "Floorp-Extension-Configuration"
        )

        await tab.offloadWebView()
        XCTAssertNil(tab.webView)
        tab.createWebview(configuration: baseConfiguration)

        XCTAssertEqual(
            tab.webView?.configuration.applicationNameForUserAgent,
            "Floorp-Extension-Configuration"
        )
        XCTAssertEqual(
            tab.floorpNativeWebExtensionContextIdentifier,
            "org.example.floorp-extension"
        )
    }

    @MainActor
    func testContentScriptManagerUninstallsHandlersFromTheirRegisteredContentWorlds() throws {
        let tab = Tab(profile: MockProfile(), windowUUID: windowUUID)
        let configuration = WKWebViewConfiguration()
        tab.createWebview(configuration: configuration)
        let manager = TabContentScriptManager()

        func installHelpers() {
            manager.addContentScript(
                ContentWorldTestScript(handlerName: "floorp-default-client-handler"),
                name: "floorp-default-client-script",
                forTab: tab
            )
            manager.addContentScriptToPage(
                ContentWorldTestScript(handlerName: "floorp-page-handler"),
                name: "floorp-page-script",
                forTab: tab
            )
            manager.addContentScriptToCustomWorld(
                ContentWorldTestScript(handlerName: "floorp-custom-handler"),
                name: "floorp-custom-script",
                forTab: tab
            )
        }

        installHelpers()
        manager.uninstall(tab: tab)

        // WKUserContentController raises an Objective-C exception if a handler
        // remains registered in any of these worlds. Reinstalling against the
        // exact same controller therefore exercises the real replacement path.
        installHelpers()
        XCTAssertNotNil(manager.getContentScript("floorp-default-client-script"))
        XCTAssertNotNil(manager.getContentScript("floorp-page-script"))
        XCTAssertNotNil(manager.getContentScript("floorp-custom-script"))
        manager.uninstall(tab: tab)
    }

    // MARK: - Helper methods

    func createSubject(file: StaticString = #filePath,
                       line: UInt = #line) async throws -> TabWebView {
        let subject = TabWebView(frame: CGRect(origin: .zero, size: CGSize(width: 100, height: 100)),
                                 configuration: .init(),
                                 windowUUID: windowUUID,
                                 certStore: MockProfile().certStore)
        try await Task.sleep(nanoseconds: sleepTime)
        subject.configure(
            delegate: try XCTUnwrap(tabWebViewDelegate, file: file, line: line),
            navigationDelegate: try XCTUnwrap(navigationDelegate, file: file, line: line)
        )
        trackForMemoryLeaks(subject)
        return subject
    }
}

// MARK: - MockTabWebViewDelegate
class MockTabWebViewDelegate: TabWebViewDelegate {
    func tabWebView(_ tabWebView: TabWebView,
                    didSelectFindInPageForSelection selection: String) {}

    func tabWebViewSearchWithFirefox(_ tabWebViewSearchWithFirefox: TabWebView,
                                     didSelectSearchWithFirefoxForSelection selection: String) {}

    func tabWebViewShouldShowAccessoryView(_ tabWebView: TabWebView) -> Bool {
        return true
    }
}

// MARK: - MockNavigationDelegate
class MockNavigationDelegate: NSObject, WKNavigationDelegate {}

@MainActor
private final class ContentWorldTestScript: TabContentScript {
    private let handlerName: String

    init(handlerName: String) {
        self.handlerName = handlerName
    }

    static func name() -> String {
        "ContentWorldTestScript"
    }

    func scriptMessageHandlerNames() -> [String]? {
        [handlerName]
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceiveScriptMessage message: WKScriptMessage
    ) {}
}
