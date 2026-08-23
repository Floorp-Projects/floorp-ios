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

    func testRuntimeTearDownInvalidatesBackgroundRegistrations() async throws {
        let host = FloorpWebExtensionLazyBackgroundHost()
        host.register(extensionID: extensionID) { EchoBackgroundHandler() }
        let runtime = FloorpWebExtensionMessageRuntime(backgroundHost: host)
        let payload = try FloorpWebExtensionMessagePayload(Ping(type: "ping"))

        XCTAssertNoThrow(try await host.dispatch(payload, sender: testSender(extensionID: extensionID)))
        XCTAssertTrue(host.snapshot(for: extensionID).isRegistered)

        runtime.tearDown()

        XCTAssertFalse(host.snapshot(for: extensionID).isRegistered)
        await XCTAssertThrowsErrorAsync {
            _ = try await host.dispatch(payload, sender: self.testSender(extensionID: self.extensionID))
        } verify: { error in
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

        await XCTAssertThrowsErrorAsync {
            try await inFlight.value
        } verify: { error in
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
        for _ in 0..<100 {
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
        sender: FloorpWebExtensionRuntimeMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        _ = try message.decode(Ping.self)
        receivedSenders.append(sender)
        return try FloorpWebExtensionMessagePayload(Pong(accepted: true))
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
        sender: FloorpWebExtensionRuntimeMessageSender
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

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected async operation to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}

private struct Ping: Codable, Equatable {
    let type: String
}

private struct Pong: Codable, Equatable {
    let accepted: Bool
}
