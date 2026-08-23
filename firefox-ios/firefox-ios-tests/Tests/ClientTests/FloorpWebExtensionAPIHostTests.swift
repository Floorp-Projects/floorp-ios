// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebExtensionAPIHostTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "api-host-fixture")!

    func testAuthenticatedNativeSubsetIsPermissionAndProfileScoped() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = [
            "_locales/en/messages.json": #"{"greeting":{"message":"Hello $1"}}"#
        ]
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-host-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en-US"]
        ) { _, source in
            resources[source.path]
        }
        await host.activate(
            extensionID: extensionID,
            grants: .init(
                apiPermissions: [.storage, .alarms],
                requestedHosts: [],
                normalHostAccess: .denied
            ),
            defaultLocale: "en"
        )
        let sender = testSender()

        _ = try await host.dispatch(
            operation: "storage.local.set",
            payload: try payload(["items": ["theme": "dark", "count": 2]]),
            sender: sender
        )
        let storedPayload = try await host.dispatch(
            operation: "storage.local.get",
            payload: try payload(["keys": ["theme", "count"]]),
            sender: sender
        )
        let stored = try XCTUnwrap(storedPayload)
        XCTAssertEqual(
            try stored.decode([String: FloorpWebExtensionJSONValue].self),
            ["theme": .string("dark"), "count": .number(2)]
        )

        let localizedPayload = try await host.dispatch(
            operation: "i18n.getMessage",
            payload: try payload(["name": "greeting", "substitutions": ["Floorp"]]),
            sender: sender
        )
        let localized = try XCTUnwrap(localizedPayload)
        XCTAssertEqual(try localized.decode(ValueResponse.self).value, "Hello Floorp")

        _ = try await host.dispatch(
            operation: "alarms.create",
            payload: try payload([
                "name": "refresh",
                "delayInMinutes": 1,
                "periodInMinutes": 1
            ]),
            sender: sender
        )
        let alarmNames = await host.alarms.alarms(for: extensionID).map(\.name)
        XCTAssertEqual(alarmNames, ["refresh"])

        _ = try await host.dispatch(
            operation: "action.setTitle",
            payload: try payload(["value": "Fixture action"]),
            sender: sender
        )
        let actionTitle = await host.actions.state(for: extensionID).title
        XCTAssertEqual(actionTitle, "Fixture action")

        let privateSender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: sender.tabID,
            documentGeneration: sender.documentGeneration,
            url: sender.url,
            isMainFrame: true,
            isPrivate: true
        )
        do {
            _ = try await host.dispatch(
                operation: "storage.local.get",
                payload: try payload(["keys": NSNull()]),
                sender: privateSender
            )
            XCTFail("Expected cross-profile API use to fail")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unauthorizedDocument)
        }
    }

    func testDeactivateClearsStoresAndRevokesEveryOperation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-cleanup-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"],
            packageResourceLoader: { _, _ in nil }
        )
        await host.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.storage, .alarms]),
            defaultLocale: "en"
        )
        let sender = testSender()
        _ = try await host.dispatch(
            operation: "storage.session.set",
            payload: try payload(["items": ["token": "ephemeral"]]),
            sender: sender
        )
        _ = try await host.dispatch(
            operation: "action.setBadgeText",
            payload: try payload(["value": "4"]),
            sender: sender
        )

        await host.deactivate(extensionID)

        let localValues = try await host.storage.values(for: extensionID, in: .local)
        let sessionValues = try await host.storage.values(for: extensionID, in: .session)
        let alarms = await host.alarms.alarms(for: extensionID)
        let action = await host.actions.state(for: extensionID)
        XCTAssertTrue(localValues.isEmpty)
        XCTAssertTrue(sessionValues.isEmpty)
        XCTAssertTrue(alarms.isEmpty)
        XCTAssertEqual(action, .init())
        do {
            _ = try await host.dispatch(
                operation: "i18n.getUILanguage",
                payload: try payload([String: String]()),
                sender: sender
            )
            XCTFail("Expected a deactivated package to lose its bridge capabilities")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .unauthorizedDocument)
        }
    }

    func testWebKitBootstrapUsesNativeStorageAndI18nThroughIsolatedWorld() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: "api-webkit-profile",
            isPrivateBrowsing: false,
            directory: directory,
            preferredLocales: ["en"]
        ) { _, source in
            source.path == "_locales/en/messages.json"
                ? #"{"hello":{"message":"Hello"}}"#
                : nil
        }
        await host.activate(
            extensionID: extensionID,
            grants: .init(apiPermissions: [.storage]),
            defaultLocale: "en"
        )
        let runtime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: host)
        let configuration = WKWebViewConfiguration()
        let tab = FloorpWebExtensionTabContext(
            tabID: 73,
            documentGeneration: 2,
            url: URL(string: "https://allowed.example/api")!,
            isPrivate: false
        )
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { url, _, trustedTab in
                url.host == "allowed.example" && trustedTab == tab
            }
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>api</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)
        let contentWorld = WKContentWorld.world(
            name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID)
        )

        let result = try await webView.callAsyncJavaScript(
            """
            await browser.storage.local.set({enabled: true});
            const values = await browser.storage.local.get("enabled");
            const message = await browser.i18n.getMessage("hello");
            return {enabled: values.enabled, message};
            """,
            contentWorld: contentWorld
        ) as? [String: Any]

        XCTAssertEqual(result?["enabled"] as? Bool, true)
        XCTAssertEqual(result?["message"] as? String, "Hello")
        let pageWorldStorage = try await webView.callAsyncJavaScript(
            "return globalThis.browser?.storage",
            contentWorld: .page
        )
        XCTAssertNil(pageWorldStorage)
    }

    private func payload(_ object: Any) throws -> FloorpWebExtensionMessagePayload {
        try .init(jsonData: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
    }

    private func testSender() -> FloorpWebExtensionRuntimeMessageSender {
        .init(
            extensionID: extensionID,
            tabID: 73,
            documentGeneration: 2,
            url: URL(string: "https://allowed.example/api")!,
            isMainFrame: true,
            isPrivate: false
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-api-host-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func waitForLoad(_ webView: WKWebView) async throws {
        for _ in 0..<100 {
            if !webView.isLoading, webView.url != nil { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the API bridge document")
    }
}

private struct ValueResponse: Decodable {
    let value: String
}
