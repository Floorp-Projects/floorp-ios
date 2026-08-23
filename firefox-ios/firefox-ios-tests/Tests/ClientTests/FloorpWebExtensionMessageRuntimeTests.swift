// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebExtensionMessageRuntimeTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "message-fixture")!

    func testLazyBackgroundActivatesOnFirstMessageAndReusesHandler() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        var factoryCalls = 0
        let handler = EchoBackgroundHandler()
        host.register(extensionID: extensionID) {
            factoryCalls += 1
            return handler
        }
        let sender = testSender(extensionID: extensionID)
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))

        let first = try await host.dispatch(payload, sender: sender)
        let second = try await host.dispatch(payload, sender: sender)

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(handler.receivedSenders, [sender, sender])
        XCTAssertEqual(try first?.decode(Pong.self), Pong(accepted: true))
        XCTAssertEqual(try second?.decode(Pong.self), Pong(accepted: true))
        XCTAssertEqual(
            host.snapshot(for: extensionID),
            .init(isRegistered: true, isActive: true, activationCount: 1, pendingMessageCount: 0)
        )

        host.suspend(extensionID: extensionID)
        _ = try await host.dispatch(payload, sender: sender)
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(host.snapshot(for: extensionID).activationCount, 2)
    }

    func testStage2EventRuntimeFixtureUsesReviewedLazyNativeHandler() async throws {
        let fixtureID = FloorpWebExtensionID(rawValue: "floorp.fixture.event-runtime-mv3")!
        let host = FloorpWebExtensionLazyBackgroundHost()
        var factoryCalls = 0
        let handler = EventRuntimeFixtureHandler()
        host.register(extensionID: fixtureID) {
            factoryCalls += 1
            return handler
        }
        let sender = testSender(extensionID: fixtureID)
        let payload = try FloorpWebExtensionMessagePayload(EventRuntimePing(type: "floorp-event-runtime-ping"))

        let first = try await host.dispatch(payload, sender: sender)
        host.suspend(extensionID: fixtureID)
        let second = try await host.dispatch(payload, sender: sender)

        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(try first?.decode(EventRuntimeReply.self).activationCount, 1)
        XCTAssertEqual(try second?.decode(EventRuntimeReply.self).activationCount, 2)
        XCTAssertEqual(host.snapshot(for: fixtureID).activationCount, 2)
    }

    func testBackgroundRegistrationIsStrictlyExtensionScoped() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        host.register(extensionID: extensionID) { EchoBackgroundHandler() }
        let otherExtension = FloorpWebExtensionID(rawValue: "other-message-fixture")!
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))

        do {
            _ = try await host.dispatch(payload, sender: testSender(extensionID: otherExtension))
            XCTFail("Expected an unregistered extension to fail closed")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundUnavailable)
        }
        XCTAssertFalse(host.snapshot(for: otherExtension).isRegistered)
        XCTAssertFalse(host.snapshot(for: extensionID).isActive)
    }

    func testPayloadRejectsInvalidJSONAndValuesOverQuota() throws {
        XCTAssertThrowsError(try FloorpWebExtensionMessagePayload(jsonData: Data("{".utf8)))
        XCTAssertThrowsError(
            try FloorpWebExtensionMessagePayload(
                jsonData: Data(repeating: 0x20, count: FloorpWebExtensionMessagePayload.maximumByteCount + 1)
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .payloadTooLarge)
        }
    }

    func testIsolatedWorldBridgeAuthenticatesAndUsesTrustedSenderContext() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        let handler = EchoBackgroundHandler()
        host.register(extensionID: extensionID) { handler }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let configuration = WKWebViewConfiguration()
        let tab = testTab()
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { url, isMainFrame, trustedTab in
                url.host == "allowed.example" && isMainFrame && trustedTab == tab
            }
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>bridge</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)

        let pageWorldType = try await webView.callAsyncJavaScript(
            "return typeof globalThis.browser",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(pageWorldType, "undefined")

        let result = try await webView.callAsyncJavaScript(
            "return await browser.runtime.sendMessage({type: 'ping'})",
            contentWorld: .world(name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID))
        ) as? [String: Any]
        XCTAssertEqual(result?["accepted"] as? Bool, true)
        XCTAssertEqual(handler.receivedSenders.first?.extensionID, extensionID)
        XCTAssertEqual(handler.receivedSenders.first?.tabID, tab.tabID)
        XCTAssertEqual(handler.receivedSenders.first?.documentGeneration, tab.documentGeneration)
        XCTAssertEqual(handler.receivedSenders.first?.url.host, "allowed.example")
        XCTAssertEqual(handler.receivedSenders.first?.isMainFrame, true)
    }

    func testDocumentAuthorizationRunsBeforeLazyBackgroundActivation() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        host.register(extensionID: extensionID) { EchoBackgroundHandler() }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let configuration = WKWebViewConfiguration()
        let tab = testTab()
        runtime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { _, _, _ in false }
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body>denied</body></html>", baseURL: tab.url)
        try await waitForLoad(webView)

        do {
            _ = try await webView.callAsyncJavaScript(
                "return await browser.runtime.sendMessage({type: 'ping'})",
                contentWorld: .world(name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID))
            )
            XCTFail("Expected the document authorization gate to reject the message")
        } catch {
            XCTAssertFalse(host.snapshot(for: extensionID).isActive)
        }
    }

    func testExtensionPageBridgeDispatchesNativeAPIWithPageSenderAndRevokesOnDisable() async throws {
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: "page-bridge-profile",
            isPrivateBrowsing: false
        )
        let nativeDispatcher = PageNativeDispatcher()
        let runtime = FloorpWebExtensionMessageRuntime(
            backgroundHost: .init(),
            nativeAPIDispatcher: nativeDispatcher,
            profileKey: profileKey
        )
        let package = try FloorpWebExtensionPagePackageGeneration(
            extensionID: extensionID,
            generation: "page-bridge-generation",
            resourcePaths: ["popup/index.html"]
        )
        let page = try FloorpWebExtensionPageViewController(
            surface: .actionPopup,
            package: package,
            entryPoint: .init("popup/index.html"),
            resolver: .init { _ in Data("<html><body>Extension page</body></html>".utf8) },
            messageRuntime: runtime,
            openExternal: { _ in }
        )
        page.loadViewIfNeeded()
        try await waitForLoad(page.webView)
        XCTAssertEqual(page.webView.url?.scheme, FloorpWebExtensionPageNavigationPolicy.resourceScheme)
        let originHost = try XCTUnwrap(page.webView.url?.host)
        let world = WKContentWorld.world(name: FloorpWebExtensionMessageRuntime.pageIsolatedContentWorldName(
            for: extensionID,
            originHost: originHost
        ))

        let language = try await page.webView.callAsyncJavaScript(
            "return await browser.i18n.getUILanguage()",
            contentWorld: world
        ) as? String
        XCTAssertEqual(language, "en-US")
        let sender = try XCTUnwrap(nativeDispatcher.receivedSenders.first as? FloorpWebExtensionPageRuntimeMessageSender)
        XCTAssertEqual(sender.extensionID, extensionID)
        XCTAssertEqual(sender.profileKey, profileKey)
        XCTAssertEqual(sender.packageGeneration, package.generation)
        XCTAssertEqual(sender.originHost, originHost)
        XCTAssertEqual(sender.surface, .actionPopup)

        runtime.removeExtension(extensionID)
        XCTAssertTrue(page.webView.configuration.userContentController.userScripts.isEmpty)
        page.webView.reload()
        try await waitForLoad(page.webView)
        let bridgeType = try await page.webView.callAsyncJavaScript(
            "return typeof globalThis.browser",
            contentWorld: world
        ) as? String
        XCTAssertEqual(bridgeType, "undefined")
        XCTAssertEqual(nativeDispatcher.receivedSenders.count, 1)
    }

    func testRuntimeTearDownInvalidatesBackgroundRegistrations() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        host.register(extensionID: extensionID) { EchoBackgroundHandler() }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))

        do {
            _ = try await host.dispatch(payload, sender: testSender(extensionID: extensionID))
        } catch {
            XCTFail("Expected the registered background to receive messages before tearDown: \(error)")
        }
        XCTAssertTrue(host.snapshot(for: extensionID).isRegistered)

        runtime.tearDown()

        XCTAssertFalse(host.snapshot(for: extensionID).isRegistered)
        let senderAfterTearDown = testSender(extensionID: extensionID)
        do {
            _ = try await host.dispatch(payload, sender: senderAfterTearDown)
            XCTFail("Expected dispatch after tearDown to throw")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundUnavailable)
        }
    }

    func testRuntimeTearDownSuppressesInFlightBackgroundReplies() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        let gate = AsyncReplyGate()
        host.register(extensionID: extensionID) { gate }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))
        let sender = testSender(extensionID: extensionID)

        let inFlight = Task {
            _ = try await host.dispatch(payload, sender: sender)
        }
        await gate.waitUntilStarted()

        runtime.tearDown()
        await gate.release()

        do {
            try await inFlight.value
            XCTFail("Expected in-flight dispatch to throw after tearDown")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionMessageError, .backgroundReplaced)
        }
    }

    private func testTab() -> FloorpWebExtensionTabContext {
        FloorpWebExtensionTabContext(
            tabID: 41,
            documentGeneration: 9,
            url: URL(string: "https://allowed.example/bridge")!,
            isPrivate: false
        )
    }

    private func testSender(
        extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionRuntimeMessageSender {
        FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: 41,
            documentGeneration: 9,
            url: URL(string: "https://allowed.example/bridge")!,
            isMainFrame: true,
            isPrivate: false
        )
    }

    private func waitForLoad(_ webView: WKWebView) async throws {
        for _ in 0..<250 {
            if !webView.isLoading, webView.url != nil {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the bridge test document")
    }
}

@MainActor
private final class EchoBackgroundHandler: FloorpWebExtensionBackgroundEventHandling {
    private(set) var receivedSenders = [FloorpWebExtensionRuntimeMessageSender]()

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        _ = try message.decode(Ping.self)
        guard let tabSender = sender as? FloorpWebExtensionRuntimeMessageSender else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        receivedSenders.append(tabSender)
        return try FloorpWebExtensionMessagePayload(Pong(accepted: true))
    }
}

@MainActor
private final class PageNativeDispatcher: FloorpWebExtensionNativeAPIDispatching {
    private(set) var receivedSenders = [any FloorpWebExtensionMessageSender]()

    func dispatch(
        operation: String,
        payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        guard operation == "i18n.getUILanguage" else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        receivedSenders.append(sender)
        return try .init(jsonData: Data(#"{"value":"en-US"}"#.utf8))
    }
}

@MainActor
private final class AsyncReplyGate: FloorpWebExtensionBackgroundEventHandling {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func release() async {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        _ = try message.decode(Ping.self)
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return try FloorpWebExtensionMessagePayload(Pong(accepted: true))
    }
}

private struct Ping: Codable, Equatable {
    let type: String
}

private struct Pong: Codable, Equatable {
    let accepted: Bool
}

private struct EventRuntimePing: Codable, Equatable {
    let type: String
}

private struct EventRuntimeReply: Codable, Equatable {
    let accepted: Bool
    let activationCount: Int
}

@MainActor
private final class EventRuntimeFixtureHandler: FloorpWebExtensionBackgroundEventHandling {
    private var activationCount = 0

    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        let ping = try message.decode(EventRuntimePing.self)
        guard ping.type == "floorp-event-runtime-ping" else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        activationCount += 1
        return try FloorpWebExtensionMessagePayload(EventRuntimeReply(
            accepted: true,
            activationCount: activationCount
        ))
    }
}
