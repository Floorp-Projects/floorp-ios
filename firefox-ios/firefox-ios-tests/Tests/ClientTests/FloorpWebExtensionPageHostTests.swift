// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebExtensionPageHostTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "page-host-fixture")!

    func testSchemeHandlerResolvesOnlyInventoriedResourceFromExactGeneration() throws {
        let resolvedRequest = LockedValue<FloorpWebExtensionPageResourceRequest?>(nil)
        let handler = try makeHandler(
            resourcePaths: ["popup/index.html"],
            resolver: .init { request in
                resolvedRequest.set(request)
                return Data("<html><body>Popup</body></html>".utf8)
            }
        )
        let url = try XCTUnwrap(URL(string: "floorp-extension://test-origin/popup/index.html"))

        let result = try handler.response(for: URLRequest(url: url))

        XCTAssertEqual(result.data, Data("<html><body>Popup</body></html>".utf8))
        XCTAssertEqual(result.response.mimeType, "text/html")
        XCTAssertEqual(
            result.response.value(forHTTPHeaderField: "Content-Security-Policy"),
            FloorpWebExtensionPageSchemeHandler.contentSecurityPolicy
        )
        XCTAssertEqual(result.response.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(
            resolvedRequest.get(),
            .init(extensionID: extensionID, generation: "generation-1", path: "popup/index.html")
        )
    }

    func testSchemeHandlerRejectsCrossOriginTraversalQueryAndUninventoriedResources() throws {
        let handler = try makeHandler(
            resourcePaths: ["popup/index.html"],
            resolver: .init { _ in Data() }
        )
        let rejectedURLs = [
            "floorp-extension://another-origin/popup/index.html",
            "floorp-extension://test-origin/%2e%2e/manifest.json",
            "floorp-extension://test-origin/popup%2findex.html",
            "floorp-extension://test-origin/popup/index.html?remote=https://example.com",
            "floorp-extension://test-origin/manifest.json"
        ]

        for value in rejectedURLs {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try handler.response(for: URLRequest(url: url)), value)
        }
    }

    func testSchemeHandlerDerivesMimeTypeAndEnforcesResourceQuota() throws {
        XCTAssertEqual(
            try FloorpWebExtensionPageSchemeHandler.mimeType(for: "assets/popup.js"),
            "text/javascript; charset=utf-8"
        )
        XCTAssertThrowsError(
            try FloorpWebExtensionPageSchemeHandler.mimeType(for: "native/payload.wasm")
        ) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionPageHostError,
                .unsupportedResourceType("native/payload.wasm")
            )
        }

        let oversized = Data(
            repeating: 0,
            count: FloorpWebExtensionManifest.maximumPackageResourceByteSize + 1
        )
        let handler = try makeHandler(
            resourcePaths: ["popup/index.html"],
            resolver: .init { _ in oversized }
        )
        let url = try XCTUnwrap(URL(string: "floorp-extension://test-origin/popup/index.html"))
        XCTAssertThrowsError(try handler.response(for: URLRequest(url: url))) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPageHostError, .resourceTooLarge)
        }
    }

    func testBackgroundSchemeGeneratesRestrictedEntryAndServesOnlyInventoriedPackageScripts() throws {
        let package = try FloorpWebExtensionPagePackageGeneration(
            extensionID: extensionID,
            generation: "background-generation",
            resourcePaths: ["background/main.js", "background/dependency.js"]
        )
        let manifest = try FloorpWebExtensionManifest.decode(Data("""
        {
          "manifest_version": 3,
          "name": "Background Scheme",
          "version": "1.0",
          "background": { "service_worker": "background/main.js", "type": "module" }
        }
        """.utf8))
        let background = try FloorpWebExtensionBackgroundPackageGeneration(
            package: package,
            background: try XCTUnwrap(manifest.background)
        )
        let originHost = "background-" + UUID().uuidString.lowercased()
        let identity = try FloorpWebExtensionBackgroundBridgeIdentity(
            profileKey: .init(profileIdentifier: "background-profile", isPrivateBrowsing: false),
            package: package,
            originHost: originHost,
            entryPath: "__floorp_background_test.html"
        )
        let resources = [
            "background/main.js": Data("import './dependency.js';".utf8),
            "background/dependency.js": Data("export const ready = true;".utf8)
        ]
        let handler = try FloorpWebExtensionBackgroundSchemeHandler(
            identity: identity,
            background: background,
            resolver: .init { request in
                guard let data = resources[request.path] else {
                    throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
                }
                return data
            }
        )
        let entryURL = try XCTUnwrap(URL(
            string: "floorp-extension://\(originHost)/__floorp_background_test.html"
        ))
        let entry = try handler.response(for: URLRequest(url: entryURL))
        let html = try XCTUnwrap(String(data: entry.data, encoding: .utf8))
        XCTAssertTrue(html.contains("type=\"module\""))
        XCTAssertTrue(html.contains("floorp-extension://\(originHost)/background/main.js"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertEqual(
            entry.response.value(forHTTPHeaderField: "Content-Security-Policy"),
            FloorpWebExtensionBackgroundSchemeHandler.contentSecurityPolicy
        )

        let scriptURL = try XCTUnwrap(URL(
            string: "floorp-extension://\(originHost)/background/main.js"
        ))
        XCTAssertEqual(
            try handler.response(for: URLRequest(url: scriptURL)).data,
            resources["background/main.js"]
        )
        for rejectedValue in [
            "floorp-extension://another-origin/background/main.js",
            "floorp-extension://\(originHost)/background/missing.js",
            "floorp-extension://\(originHost)/__floorp_background_test.html?generation=other"
        ] {
            let rejectedURL = try XCTUnwrap(URL(string: rejectedValue))
            XCTAssertThrowsError(try handler.response(for: URLRequest(url: rejectedURL)))
        }
    }

    func testNavigationPolicyKeepsPackageNavigationInternalAndHandsOffOnlyTopLevelHTTPLinks() throws {
        let policy = FloorpWebExtensionPageNavigationPolicy(originHost: "test-origin")
        let packageURL = try XCTUnwrap(URL(string: "floorp-extension://test-origin/popup/next.html"))
        let externalURL = try XCTUnwrap(URL(string: "https://example.com/details"))
        let scriptURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))

        XCTAssertEqual(policy.decision(for: packageURL, isTopLevel: true), .allowPackageResource)
        XCTAssertEqual(policy.decision(for: packageURL, isTopLevel: false), .cancel)
        XCTAssertEqual(policy.decision(for: externalURL, isTopLevel: true), .openExternal(externalURL))
        XCTAssertEqual(policy.decision(for: externalURL, isTopLevel: false), .cancel)
        XCTAssertEqual(policy.decision(for: scriptURL, isTopLevel: true), .cancel)
        XCTAssertEqual(
            policy.decision(
                for: URL(string: "floorp-extension://other-origin/popup/index.html"),
                isTopLevel: true
            ),
            .cancel
        )
    }

    func testPageControllerUsesDedicatedConfigurationAndRequiresInventoriedEntryPoint() throws {
        let package = try FloorpWebExtensionPagePackageGeneration(
            extensionID: extensionID,
            generation: "generation-1",
            resourcePaths: ["popup/index.html"]
        )
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: "page-host-profile",
            isPrivateBrowsing: false
        )
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: .init(),
            profileKey: profileKey
        )
        let controller = try FloorpWebExtensionPageViewController(
            surface: .actionPopup,
            package: package,
            entryPoint: .init("popup/index.html"),
            resolver: .init { _ in Data("<html></html>".utf8) },
            messageRuntime: runtime,
            openExternal: { _ in }
        )

        XCTAssertFalse(controller.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertNotNil(
            controller.webView.configuration.urlSchemeHandler(
                forURLScheme: FloorpWebExtensionPageNavigationPolicy.resourceScheme
            )
        )
        XCTAssertEqual(controller.webView.configuration.userContentController.userScripts.count, 1)
        XCTAssertEqual(controller.preferredContentSize, CGSize(width: 360, height: 520))

        let originHost = "page-" + UUID().uuidString.lowercased()
        let identity = try FloorpWebExtensionPageBridgeIdentity(
            profileKey: profileKey,
            package: package,
            originHost: originHost,
            surface: .actionPopup
        )
        let exactURL = try XCTUnwrap(URL(string: "floorp-extension://\(originHost)/popup/index.html"))
        XCTAssertTrue(identity.authorizesDocument(exactURL, isMainFrame: true))
        XCTAssertFalse(identity.authorizesDocument(exactURL, isMainFrame: false))
        XCTAssertFalse(identity.authorizesDocument(
            try XCTUnwrap(URL(string: "floorp-extension://page-\(UUID().uuidString.lowercased())/popup/index.html")),
            isMainFrame: true
        ))
        XCTAssertFalse(identity.authorizesDocument(
            try XCTUnwrap(URL(string: "floorp-extension://\(originHost)/popup/index.html?query=1")),
            isMainFrame: true
        ))
        let mismatchedRuntime = FloorpWebExtensionMessageRuntime(
            backgroundHost: .init(),
            profileKey: .init(profileIdentifier: "other-profile", isPrivateBrowsing: false)
        )
        XCTAssertFalse(mismatchedRuntime.installPageBridge(
            identity,
            on: WKWebViewConfiguration().userContentController
        ))

        XCTAssertThrowsError(
            try FloorpWebExtensionPageViewController(
                surface: .options,
                package: package,
                entryPoint: .init("options/index.html"),
                resolver: .init { _ in Data() },
                openExternal: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionPageHostError,
                .resourceNotInGeneration("options/index.html")
            )
        }
    }

    func testCustomSchemePageExecutesESModuleInWebKit() async throws {
        let package = try FloorpWebExtensionPagePackageGeneration(
            extensionID: extensionID,
            generation: "module-proof-generation",
            resourcePaths: ["page/index.html", "page/main.js", "page/dependency.js"]
        )
        let resources = [
            "page/index.html": Data("""
            <!doctype html>
            <html><body><script type="module" src="main.js"></script></body></html>
            """.utf8),
            "page/main.js": Data("""
            import { value } from "./dependency.js";
            globalThis.floorpExtensionModuleProof = value;
            """.utf8),
            "page/dependency.js": Data("export const value = 'module-ready';".utf8)
        ]
        let controller = try FloorpWebExtensionPageViewController(
            surface: .options,
            package: package,
            entryPoint: .init("page/index.html"),
            resolver: .init { request in resources[request.path] ?? Data() },
            openExternal: { _ in }
        )

        controller.loadViewIfNeeded()
        try await waitForLoad(controller.webView)
        for _ in 0..<250 {
            let result = try await controller.webView.callAsyncJavaScript(
                "return globalThis.floorpExtensionModuleProof",
                contentWorld: .page
            ) as? String
            if result == "module-ready" {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The extension page ES module did not execute.")
    }

    func testActionPopupFactoryUsesDefaultAndDisabledStatesWithoutOpeningAPage() throws {
        let package = try makeInstalledPackage(resourcePaths: ["popup/index.html"])
        let popup = try FloorpWebExtensionActionResource("popup/index.html")
        let resolver = FloorpWebExtensionPageResourceResolver { _ in Data("<html></html>".utf8) }

        XCTAssertNil(
            try FloorpWebExtensionPageHost.makeActionPopup(
                package: package,
                actionState: .init(),
                resolver: resolver,
                openExternal: { _ in }
            )
        )
        XCTAssertNil(
            try FloorpWebExtensionPageHost.makeActionPopup(
                package: package,
                actionState: .init(isEnabled: false, popup: popup),
                resolver: resolver,
                openExternal: { _ in }
            )
        )

        let controller = try XCTUnwrap(
            FloorpWebExtensionPageHost.makeActionPopup(
                package: package,
                actionState: .init(popup: popup),
                resolver: resolver,
                openExternal: { _ in }
            )
        )
        switch controller.surface {
        case .actionPopup:
            break
        case .options:
            XCTFail("Expected the action-popup surface.")
        }
        XCTAssertEqual(controller.preferredContentSize, CGSize(width: 360, height: 520))

        var disabledPackage = package
        disabledPackage.isEnabled = false
        XCTAssertThrowsError(
            try FloorpWebExtensionPageHost.makeActionPopup(
                package: disabledPackage,
                actionState: .init(popup: popup),
                resolver: resolver,
                openExternal: { _ in }
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPageHostError, .packageDisabled)
        }
    }

    func testOptionsPageFactoryUsesOptionsSurfaceAndFailsClosedForInvalidResources() throws {
        let package = try makeInstalledPackage(resourcePaths: ["options/index.html"])
        let resolver = FloorpWebExtensionPageResourceResolver { _ in Data("<html></html>".utf8) }
        let options = try FloorpWebExtensionActionResource("options/index.html")

        let controller = try FloorpWebExtensionPageHost.makeOptionsPage(
            package: package,
            entryPoint: options,
            resolver: resolver,
            openExternal: { _ in }
        )
        switch controller.surface {
        case .options:
            break
        case .actionPopup:
            XCTFail("Expected the options-page surface.")
        }
        XCTAssertEqual(controller.preferredContentSize, CGSize(width: 640, height: 720))

        let missing = try FloorpWebExtensionActionResource("options/missing.html")
        XCTAssertThrowsError(
            try FloorpWebExtensionPageHost.makeOptionsPage(
                package: package,
                entryPoint: missing,
                resolver: resolver,
                openExternal: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionPageHostError,
                .resourceNotInGeneration("options/missing.html")
            )
        }

        var disabledPackage = package
        disabledPackage.isEnabled = false
        XCTAssertThrowsError(
            try FloorpWebExtensionPageHost.makeOptionsPage(
                package: disabledPackage,
                entryPoint: options,
                resolver: resolver,
                openExternal: { _ in }
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPageHostError, .packageDisabled)
        }
    }

    private func makeHandler(
        resourcePaths: Set<String>,
        resolver: FloorpWebExtensionPageResourceResolver
    ) throws -> FloorpWebExtensionPageSchemeHandler {
        let package = try FloorpWebExtensionPagePackageGeneration(
            extensionID: extensionID,
            generation: "generation-1",
            resourcePaths: resourcePaths
        )
        let policy = FloorpWebExtensionPageNavigationPolicy(originHost: "test-origin")
        return .init(package: package, navigationPolicy: policy, resolver: resolver)
    }

    private func waitForLoad(_ webView: WKWebView) async throws {
        for _ in 0..<250 {
            if !webView.isLoading, webView.url != nil {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the extension page document.")
    }

    private func makeInstalledPackage(
        resourcePaths: Set<String>
    ) throws -> FloorpWebExtensionInstalledPackage {
        let rawManifest = Data("""
        {
          "manifest_version": 3,
          "name": "Page Host Fixture",
          "version": "1.0.0"
        }
        """.utf8)
        let fixture = try FloorpWebExtensionFixture(
            extensionID: extensionID,
            sourceRepository: try XCTUnwrap(URL(string: "https://example.com/page-host-fixture")),
            sourceCommit: String(repeating: "a", count: 40),
            version: "1.0.0",
            packageSHA256: String(repeating: "0", count: 64),
            license: "MPL-2.0",
            supportedOSFloor: "iOS 15"
        )
        return .init(
            extensionID: extensionID,
            generation: "generation-1",
            name: "Page Host Fixture",
            version: "1.0.0",
            fixture: fixture,
            packageSHA256: String(repeating: "0", count: 64),
            installedAt: .distantPast,
            rawManifest: rawManifest,
            preflight: try FloorpWebExtensionManifest.preflight(manifestData: rawManifest),
            resourcePaths: resourcePaths,
            isEnabled: true,
            grants: .init()
        )
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
