// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import GCDWebServers
import WebKit
import XCTest

@testable import Client

@MainActor
final class FloorpNativeWebExtensionIntegrationTests: XCTestCase {
    func testBundledDarkReaderZIPIsVerifiedAndLoadsWithNativeWebKit() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let installer = try FloorpNativeWebExtensionPackageInstaller(rootDirectory: temporaryRoot)
        let package = try await installer.verifiedBundledPackage(
            for: FloorpNativeWebExtensionCatalog.darkReader
        )
        XCTAssertEqual(
            package.sha256,
            "20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64"
        )
        XCTAssertEqual(package.url.pathExtension, "zip")

        let webExtension = try await WKWebExtension(resourceBaseURL: package.url)
        XCTAssertEqual(webExtension.displayName, "Dark Reader")
        XCTAssertEqual(webExtension.version, "4.9.129")
        XCTAssertTrue(webExtension.errors.isEmpty)

        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = FloorpNativeWebExtensionCatalog.darkReader.contextIdentifier
        context.baseURL = URL(
            string: "webkit-extension://\(FloorpNativeWebExtensionCatalog.darkReader.baseURLHost)/"
        )!
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        configuration.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration: configuration)

        try controller.load(context)
        defer { try? controller.unload(context) }

        XCTAssertTrue(context.isLoaded)
        XCTAssertNotNil(context.optionsPageURL)
        XCTAssertTrue(webExtension.hasBackgroundContent)
        XCTAssertTrue(webExtension.hasInjectedContent)
        XCTAssertTrue(webExtension.requestedPermissions.contains(.storage))
        XCTAssertTrue(webExtension.requestedPermissions.contains(.scripting))
        XCTAssertFalse(webExtension.requestedPermissions.contains(.nativeMessaging))
    }

    func testNativeRegistryV2RoundTripsIdentityPermissionsAndTransactionState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FloorpNativeWebExtensionRegistryStore(
            url: root.appendingPathComponent("registry-v2.json")
        )

        let controllerIdentifier = UUID()
        var record = makeRecord()
        record.transactionState = .switching
        record.rollback = record.rollbackSnapshot
        let expected = FloorpNativeWebExtensionRegistry(
            controllerIdentifier: controllerIdentifier,
            extensions: [record]
        )

        try store.save(expected)
        let actual = try store.load()

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.controllerIdentifier, controllerIdentifier)
        XCTAssertEqual(actual.schemaVersion, 2)
        XCTAssertEqual(actual.extensions.first?.contextIdentifier, "org.darkreader.floorp-ios")
        XCTAssertEqual(actual.extensions.first?.grantedPermissions.first?.value, "storage")
        XCTAssertEqual(actual.extensions.first?.transactionState, .switching)

        var corruptRecord = record
        corruptRecord.grantedPermissions.append(
            FloorpNativeWebExtensionPermissionDecision(value: "storage")
        )
        XCTAssertThrowsError(
            try store.save(
                FloorpNativeWebExtensionRegistry(
                    controllerIdentifier: controllerIdentifier,
                    extensions: [corruptRecord]
                )
            )
        )
    }

    func testInterruptedTransactionRollbackRestoresPreviousPackageAndState() throws {
        var record = makeRecord()
        let rollback = record.rollbackSnapshot
        record.packageReference = "packages/floorp.bundled.darkreader/new/extension.zip"
        record.sha256 = String(repeating: "b", count: 64)
        record.installedVersion = "5.0.0"
        record.isEnabled = false
        record.transactionState = .switching
        record.rollback = rollback

        record.restore(try XCTUnwrap(record.rollback))

        XCTAssertEqual(record.packageReference, FloorpNativeWebExtensionCatalog.darkReader.packageReference)
        XCTAssertEqual(record.installedVersion, "4.9.129")
        XCTAssertTrue(record.isEnabled)
        XCTAssertEqual(record.transactionState, .stable)
        XCTAssertNil(record.rollback)
    }

    func testSurfaceHistoryPreservesCrossOriginBackForwardAndDropsForwardBranch() throws {
        let website = try XCTUnwrap(URL(string: "https://example.com/article"))
        let strictBlock = try XCTUnwrap(
            URL(string: "webkit-extension://ubol.floorp.internal/strictblock.html")
        )
        let replacement = try XCTUnwrap(URL(string: "https://example.org/new-branch"))
        var history = FloorpNativeWebExtensionSurfaceHistory()

        history.commit(contextIdentifier: nil, url: website)
        history.transition(
            from: .init(contextIdentifier: nil, url: website),
            to: .init(contextIdentifier: "ubol", url: strictBlock)
        )
        XCTAssertEqual(history.backTarget?.url, website)
        XCTAssertEqual(history.moveBack()?.url, website)
        XCTAssertEqual(history.forwardTarget?.url, strictBlock)
        XCTAssertEqual(history.moveForward()?.url, strictBlock)
        XCTAssertEqual(history.moveBack()?.url, website)

        history.discardForward()
        history.commit(contextIdentifier: nil, url: replacement)

        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.currentEntry?.url, replacement)
    }

    func testBundledPackageRejectsDigestNotApprovedByCatalog() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let installer = try FloorpNativeWebExtensionPackageInstaller(rootDirectory: temporaryRoot)
        let approved = FloorpNativeWebExtensionCatalog.darkReader
        let tamperedCatalog = FloorpNativeWebExtensionCatalogItem(
            identifier: approved.identifier,
            resourceName: approved.resourceName,
            resourceExtension: approved.resourceExtension,
            expectedSHA256: String(repeating: "0", count: 64),
            expectedVersion: approved.expectedVersion,
            contextIdentifier: approved.contextIdentifier,
            baseURLHost: approved.baseURLHost,
            minimumOS: approved.minimumOS,
            name: approved.name,
            summary: approved.summary,
            source: approved.source,
            sourceRevision: approved.sourceRevision,
            license: approved.license,
            approvedParseErrorCodes: approved.approvedParseErrorCodes,
            disabledAPIs: approved.disabledAPIs
        )

        do {
            _ = try await installer.verifiedBundledPackage(for: tamperedCatalog)
            XCTFail("A mismatched catalog digest must not be accepted")
        } catch FloorpNativeWebExtensionError.packageDigestMismatch(let expected, let actual) {
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
            XCTAssertEqual(actual, approved.expectedSHA256)
        }
    }

    func testBundledUBOLCatalogPackageIsVerifiedLoadsAndDeclaresDNRAndUI() async throws {
        let item = FloorpNativeWebExtensionCatalog.uBlockOriginLite
        XCTAssertEqual(item.identifier, "floorp.bundled.ublock-origin-lite")
        XCTAssertEqual(item.expectedVersion, "2026.825.1619")
        XCTAssertEqual(
            item.expectedSHA256,
            "89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94"
        )
        XCTAssertEqual(item.minimumOS, FloorpOperatingSystemVersion(18, 6))
        XCTAssertEqual(item.license, "GPL-3.0-or-later")
        XCTAssertEqual(item.sourceRevision, "080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b")

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let installer = try FloorpNativeWebExtensionPackageInstaller(rootDirectory: temporaryRoot)
        let package = try await installer.verifiedBundledPackage(for: item)
        XCTAssertEqual(package.sha256, item.expectedSHA256)
        XCTAssertEqual(package.url.lastPathComponent, item.packageReference)

        let webExtension = try await WKWebExtension(resourceBaseURL: package.url)
        XCTAssertEqual(webExtension.displayName, item.name)
        XCTAssertEqual(webExtension.version, item.expectedVersion)
        XCTAssertTrue(
            webExtension.errors.isEmpty,
            webExtension.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        XCTAssertTrue(webExtension.requestedPermissions.contains(.declarativeNetRequest))
        XCTAssertTrue(webExtension.requestedPermissions.contains(.declarativeNetRequestWithHostAccess))

        let dnr = try XCTUnwrap(webExtension.manifest["declarative_net_request"] as? [String: Any])
        let rulesets = try XCTUnwrap(dnr["rule_resources"] as? [[String: Any]])
        XCTAssertEqual(rulesets.count, 51)
        let browserSettings = try XCTUnwrap(
            webExtension.manifest["browser_specific_settings"] as? [String: Any]
        )
        let safariSettings = try XCTUnwrap(browserSettings["safari"] as? [String: Any])
        XCTAssertEqual(safariSettings["strict_min_version"] as? String, "18.6")

        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = item.contextIdentifier
        context.baseURL = URL(string: "webkit-extension://\(item.baseURLHost)/")!
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissions.map { ($0, Date.distantFuture) }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissionMatchPatterns.map {
                ($0, Date.distantFuture)
            }
        )
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        configuration.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration: configuration)

        try controller.load(context)
        defer { try? controller.unload(context) }
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(context.isLoaded)
        XCTAssertNotNil(context.action(for: nil))
        XCTAssertNotNil(context.optionsPageURL)
    }

    func testFirefoxTrackingProtectionPreservesWebExtensionOwnedContentRules() async throws {
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let identifier = "floorp-native-owner-\(UUID().uuidString)"
        let rule = try await compileContentRuleList(
            in: store,
            identifier: identifier,
            source: """
            [{"trigger":{"url-filter":"/floorp-extension-owned\\\\.js"},"action":{"type":"block"}}]
            """
        )
        defer {
            store.removeContentRuleList(forIdentifier: identifier) { _ in }
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rule)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let tab = FloorpContentBlockerTestTab(webView: webView)

        ContentBlocker.shared.setupTrackingProtection(
            forTab: tab,
            isEnabled: false,
            rules: [],
            completion: nil
        )

        let server = try makeRuleOwnershipTestServer()
        defer { server.stop() }
        let navigation = FloorpWebExtensionNavigationWaiter()
        try await navigation.load(
            try XCTUnwrap(URL(string: "http://localhost:\(server.port)/")),
            in: webView
        )
        let didExecute = try await webView.callAsyncJavaScript(
            "return window.floorpExtensionOwnedRuleDidExecute === true;",
            arguments: [:],
            contentWorld: .page
        ) as? Bool

        XCTAssertEqual(didExecute, false)
    }

    func testNativeDNRBlocksAndRedirectsInManagedWebView() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let extensionRoot = temporaryRoot.appendingPathComponent("extension", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let webExtension = try await makeDNRTestExtension(at: extensionRoot)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = "app.floorp.dnr-acceptance.\(UUID().uuidString)"
        context.baseURL = URL(string: "webkit-extension://dnr-acceptance.floorp.internal/")!
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissions.map { ($0, Date.distantFuture) }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissionMatchPatterns.map {
                ($0, Date.distantFuture)
            }
        )
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        configuration.defaultWebsiteDataStore = .default()
        let controller = WKWebExtensionController(configuration: configuration)
        let browsingConfiguration = WKWebViewConfiguration()
        browsingConfiguration.websiteDataStore = .default()
        browsingConfiguration.webExtensionController = controller
        let browsingWebView = WKWebView(frame: .zero, configuration: browsingConfiguration)
        let testTab = FloorpWebExtensionTestTab(webView: browsingWebView)
        let testWindow = FloorpWebExtensionTestWindow(tab: testTab)
        testTab.testWindow = testWindow
        let testDelegate = FloorpWebExtensionTestControllerDelegate(window: testWindow)
        controller.delegate = testDelegate
        controller.didOpenWindow(testWindow)
        controller.didOpenTab(testTab)
        controller.didFocusWindow(testWindow)
        controller.didActivateTab(testTab, previousActiveTab: nil)

        try controller.load(context)
        defer { try? controller.unload(context) }
        try? await Task.sleep(nanoseconds: 750_000_000)

        let server = try makeDNRTestServer()
        defer { server.stop() }
        let browsingNavigation = FloorpWebExtensionNavigationWaiter()
        try await browsingNavigation.load(
            try XCTUnwrap(URL(string: "http://localhost:\(server.port)/")),
            in: browsingWebView
        )
        try? await Task.sleep(nanoseconds: 750_000_000)
        let result = try await browsingWebView.callAsyncJavaScript(
            """
            return {
                controlScriptExecuted: window.floorpControlScriptExecuted === true,
                blockedScriptExecuted: window.floorpBlockedScriptExecuted === true,
                controlImageWidth: document.getElementById('control').naturalWidth,
                redirectedImageWidth: document.getElementById('redirected').naturalWidth
            };
            """,
            arguments: [:],
            contentWorld: .page
        ) as? [String: Any]
        let dnrResult = try XCTUnwrap(result)
        XCTAssertEqual(dnrResult["controlScriptExecuted"] as? Bool, true)
        XCTAssertEqual(dnrResult["blockedScriptExecuted"] as? Bool, false)
        XCTAssertEqual((dnrResult["controlImageWidth"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((dnrResult["redirectedImageWidth"] as? NSNumber)?.intValue, 1)
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        withExtendedLifetime(testDelegate) {}
    }

    private func makeDNRTestExtension(at extensionRoot: URL) async throws -> WKWebExtension {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Floorp DNR Acceptance",
            "description": "Exercises native declarative network request handling.",
            "version": "1.0",
            "permissions": [
                "declarativeNetRequest",
                "declarativeNetRequestWithHostAccess"
            ],
            "host_permissions": ["<all_urls>"],
            "declarative_net_request": [
                "rule_resources": [[
                    "id": "floorp-smoke",
                    "enabled": true,
                    "path": "rules.json"
                ]]
            ],
            "web_accessible_resources": [[
                "resources": ["one.svg"],
                "matches": ["<all_urls>"]
            ]]
        ]
        let rules: [[String: Any]] = [
            [
                "id": 1,
                "priority": 1,
                "action": ["type": "block"],
                "condition": [
                    "urlFilter": "/floorp-blocked.js",
                    "resourceTypes": ["script"]
                ]
            ],
            [
                "id": 2,
                "priority": 1,
                "action": [
                    "type": "redirect",
                    "redirect": ["extensionPath": "/one.svg"]
                ],
                "condition": [
                    "urlFilter": "/floorp-redirected.svg",
                    "resourceTypes": ["image"]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: extensionRoot.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
            .write(to: extensionRoot.appendingPathComponent("rules.json"), options: .atomic)
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'></svg>".utf8)
            .write(to: extensionRoot.appendingPathComponent("one.svg"), options: .atomic)

        let webExtension = try await WKWebExtension(resourceBaseURL: extensionRoot)
        XCTAssertTrue(
            webExtension.errors.isEmpty,
            webExtension.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        return webExtension
    }

    private func compileContentRuleList(
        in store: WKContentRuleListStore,
        identifier: String,
        source: String
    ) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: source
            ) { rule, error in
                if let rule {
                    continuation.resume(returning: rule)
                } else {
                    continuation.resume(
                        throwing: error
                            ?? FloorpNativeWebExtensionError.unsupportedOperation(
                                "compile content-rule ownership fixture"
                            )
                    )
                }
            }
        }
    }

    nonisolated private func makeRuleOwnershipTestServer() throws -> GCDWebServer {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "GET",
            path: "/",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(html: """
            <!doctype html>
            <script>window.floorpExtensionOwnedRuleDidExecute = false;</script>
            <script src="/floorp-extension-owned.js"></script>
            """)
        }
        server.addHandler(
            forMethod: "GET",
            path: "/floorp-extension-owned.js",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                data: Data("window.floorpExtensionOwnedRuleDidExecute = true;".utf8),
                contentType: "text/javascript"
            )
        }
        guard server.start(withPort: 0, bonjourName: nil) else {
            throw FloorpNativeWebExtensionError.unsupportedOperation(
                "start content-rule ownership test server"
            )
        }
        return server
    }

    nonisolated private func makeDNRTestServer() throws -> GCDWebServer {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "GET",
            path: "/",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(html: """
            <!doctype html>
            <script>window.floorpControlScriptExecuted = false;</script>
            <script>window.floorpBlockedScriptExecuted = false;</script>
            <script src="/control.js"></script>
            <script src="/floorp-blocked.js"></script>
            <img id="control" src="/control.svg">
            <img id="redirected" src="/floorp-redirected.svg">
            """)
        }
        server.addHandler(
            forMethod: "GET",
            path: "/control.js",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                data: Data("window.floorpControlScriptExecuted = true;".utf8),
                contentType: "text/javascript"
            )
        }
        server.addHandler(
            forMethod: "GET",
            path: "/floorp-blocked.js",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                data: Data("window.floorpBlockedScriptExecuted = true;".utf8),
                contentType: "text/javascript"
            )
        }
        let twoPixelSVG = Data(
            "<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'></svg>".utf8
        )
        for path in ["/control.svg", "/floorp-redirected.svg"] {
            server.addHandler(forMethod: "GET", path: path, request: GCDWebServerRequest.self) { _ in
                GCDWebServerDataResponse(data: twoPixelSVG, contentType: "image/svg+xml")
            }
        }
        guard server.start(withPort: 0, bonjourName: nil) else {
            throw FloorpNativeWebExtensionError.unsupportedOperation("start DNR test server")
        }
        return server
    }

    private func makeRecord() -> FloorpNativeWebExtensionRecord {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        return FloorpNativeWebExtensionRecord(
            id: item.identifier,
            contextIdentifier: item.contextIdentifier,
            baseURLHost: item.baseURLHost,
            packageSource: .bundled,
            packageReference: item.packageReference,
            sha256: item.expectedSHA256,
            displayName: item.name,
            installedVersion: item.expectedVersion,
            grantedPermissions: [
                FloorpNativeWebExtensionPermissionDecision(value: "storage")
            ],
            grantedMatchPatterns: [
                FloorpNativeWebExtensionPermissionDecision(value: "*://*/*")
            ],
            installedAt: fixedDate,
            updatedAt: fixedDate
        )
    }
}

@MainActor
private final class FloorpContentBlockerTestTab: ContentBlockerTab {
    let webView: WKWebView
    let isPrivate = false

    init(webView: WKWebView) {
        self.webView = webView
    }

    func currentURL() -> URL? {
        webView.url
    }

    func currentWebView() -> WKWebView? {
        webView
    }

    func imageContentBlockingEnabled() -> Bool {
        false
    }
}

@MainActor
private final class FloorpWebExtensionNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func load(_ url: URL, in webView: WKWebView) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class FloorpWebExtensionTestControllerDelegate: NSObject,
    WKWebExtensionControllerDelegate {
    let window: FloorpWebExtensionTestWindow

    init(window: FloorpWebExtensionTestWindow) {
        self.window = window
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        window
    }
}

@MainActor
private final class FloorpWebExtensionTestWindow: NSObject, WKWebExtensionWindow {
    let tab: FloorpWebExtensionTestTab

    init(tab: FloorpWebExtensionTestTab) {
        self.tab = tab
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        [tab]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        tab
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        tab.webView.bounds
    }
}

@MainActor
private final class FloorpWebExtensionTestTab: NSObject, WKWebExtensionTab {
    let webView: WKWebView
    weak var testWindow: FloorpWebExtensionTestWindow?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        testWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        webView.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        webView.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        webView.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !webView.isLoading
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool {
        false
    }
}
