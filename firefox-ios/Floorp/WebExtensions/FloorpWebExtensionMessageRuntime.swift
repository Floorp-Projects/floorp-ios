// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import WebKit

/// A size-bounded JSON value crossing the WebExtensions trust boundary.
///
/// Keeping JSON encoded as `Data` avoids exposing WebKit's untyped property
/// list objects to background handlers and gives every ingress and egress a
/// single, testable quota check.
struct FloorpWebExtensionMessagePayload: Equatable, Sendable {
    static let maximumByteCount = 48 * 1024

    let jsonData: Data

    init(jsonData: Data) throws {
        guard jsonData.count <= Self.maximumByteCount else {
            throw FloorpWebExtensionMessageError.payloadTooLarge
        }
        _ = try JSONSerialization.jsonObject(with: jsonData, options: .fragmentsAllowed)
        self.jsonData = jsonData
    }

    init<T: Encodable>(_ value: T, encoder: JSONEncoder = .init()) throws {
        try self.init(jsonData: encoder.encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = .init()) throws -> T {
        try decoder.decode(type, from: jsonData)
    }
}

struct FloorpWebExtensionRuntimeMessageSender: Equatable, Sendable {
    let extensionID: FloorpWebExtensionID
    let tabID: Int
    let documentGeneration: UInt64
    let url: URL
    let isMainFrame: Bool
    let isPrivate: Bool
}

enum FloorpWebExtensionMessageError: Error, Equatable, LocalizedError, Sendable {
    case malformedEnvelope
    case authenticationFailed
    case unauthorizedDocument
    case unsupportedOperation
    case payloadTooLarge
    case backgroundUnavailable
    case tooManyPendingMessages
    case backgroundReplaced
    case handlerFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .malformedEnvelope:
            return "The extension message envelope is malformed."
        case .authenticationFailed:
            return "The extension message could not be authenticated."
        case .unauthorizedDocument:
            return "The document is not authorized to use the extension bridge."
        case .unsupportedOperation:
            return "The requested extension bridge operation is not supported."
        case .payloadTooLarge:
            return "The extension message exceeds the supported size."
        case .backgroundUnavailable:
            return "The extension has no registered background event handler."
        case .tooManyPendingMessages:
            return "The extension has too many pending background messages."
        case .backgroundReplaced:
            return "The extension background was replaced while handling the message."
        case .handlerFailed:
            return "The extension background handler failed."
        case .permissionDenied:
            return "The extension is not allowed to use the requested API."
        }
    }

    fileprivate var bridgeCode: String {
        switch self {
        case .malformedEnvelope: return "malformed_message"
        case .authenticationFailed: return "authentication_failed"
        case .unauthorizedDocument: return "document_not_authorized"
        case .unsupportedOperation: return "unsupported_operation"
        case .payloadTooLarge: return "message_too_large"
        case .backgroundUnavailable: return "background_unavailable"
        case .tooManyPendingMessages: return "too_many_pending_messages"
        case .backgroundReplaced: return "background_replaced"
        case .handlerFailed: return "background_handler_failed"
        case .permissionDenied: return "permission_denied"
        }
    }
}

/// The only background capability exposed by the Stage 2 bridge.
///
/// This deliberately does not evaluate arbitrary service-worker JavaScript.
/// Package composition may register a reviewed native-backed event handler;
/// no DOM, network, storage, or browser API is implicitly made available.
@MainActor
protocol FloorpWebExtensionBackgroundEventHandling: AnyObject {
    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: FloorpWebExtensionRuntimeMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload?
}

/// Lazily creates one restricted event handler per installed extension.
///
/// Entries are isolated to the owning profile's instance of this host. A
/// package update replaces the generation and invalidates in-flight replies,
/// preventing an old package from replying through a new package's bridge.
@MainActor
final class FloorpWebExtensionLazyBackgroundHost {
    typealias Factory = @MainActor () throws -> any FloorpWebExtensionBackgroundEventHandling

    struct Snapshot: Equatable {
        let isRegistered: Bool
        let isActive: Bool
        let activationCount: UInt64
        let pendingMessageCount: Int
    }

    private final class Entry {
        let generation: UInt64
        let factory: Factory
        var handler: (any FloorpWebExtensionBackgroundEventHandling)?
        var activationCount: UInt64 = 0
        var pendingMessageCount = 0

        init(generation: UInt64, factory: @escaping Factory) {
            self.generation = generation
            self.factory = factory
        }
    }

    private let maximumPendingMessagesPerExtension: Int
    private var nextGeneration: UInt64 = 0
    private var entries = [FloorpWebExtensionID: Entry]()

    init(maximumPendingMessagesPerExtension: Int = 32) {
        self.maximumPendingMessagesPerExtension = max(1, maximumPendingMessagesPerExtension)
    }

    func register(
        extensionID: FloorpWebExtensionID,
        factory: @escaping Factory
    ) {
        nextGeneration &+= 1
        entries[extensionID] = Entry(generation: nextGeneration, factory: factory)
    }

    func suspend(extensionID: FloorpWebExtensionID) {
        entries[extensionID]?.handler = nil
    }

    func unregister(extensionID: FloorpWebExtensionID) {
        entries.removeValue(forKey: extensionID)
    }

    func tearDown() {
        entries.removeAll()
    }

    func snapshot(for extensionID: FloorpWebExtensionID) -> Snapshot {
        guard let entry = entries[extensionID] else {
            return Snapshot(
                isRegistered: false,
                isActive: false,
                activationCount: 0,
                pendingMessageCount: 0
            )
        }
        return Snapshot(
            isRegistered: true,
            isActive: entry.handler != nil,
            activationCount: entry.activationCount,
            pendingMessageCount: entry.pendingMessageCount
        )
    }

    func dispatch(
        _ message: FloorpWebExtensionMessagePayload,
        sender: FloorpWebExtensionRuntimeMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        guard let entry = entries[sender.extensionID] else {
            throw FloorpWebExtensionMessageError.backgroundUnavailable
        }
        guard entry.pendingMessageCount < maximumPendingMessagesPerExtension else {
            throw FloorpWebExtensionMessageError.tooManyPendingMessages
        }

        let handler: any FloorpWebExtensionBackgroundEventHandling
        if let activeHandler = entry.handler {
            handler = activeHandler
        } else {
            do {
                handler = try entry.factory()
            } catch {
                throw FloorpWebExtensionMessageError.backgroundUnavailable
            }
            entry.handler = handler
            entry.activationCount &+= 1
        }

        entry.pendingMessageCount += 1
        defer { entry.pendingMessageCount -= 1 }

        let response: FloorpWebExtensionMessagePayload?
        do {
            response = try await handler.handleRuntimeMessage(message, sender: sender)
        } catch let error as FloorpWebExtensionMessageError {
            throw error
        } catch {
            throw FloorpWebExtensionMessageError.handlerFailed
        }

        guard entries[sender.extensionID] === entry else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }
        return response
    }
}

/// Owns authenticated, per-extension WebKit bridges for one browser profile.
/// Package/profile composition must reinstall a bridge with the new trusted tab
/// context before every navigation.
@MainActor
final class FloorpWebExtensionMessageRuntime {
    typealias DocumentAuthorization = @MainActor (
        _ currentURL: URL,
        _ isMainFrame: Bool,
        _ trustedTab: FloorpWebExtensionTabContext
    ) -> Bool

    private final class ControllerEntry {
        weak var controller: WKUserContentController?
        var sessions = [FloorpWebExtensionID: FloorpWebExtensionMessageBridgeSession]()

        init(controller: WKUserContentController) {
            self.controller = controller
        }
    }

    let backgroundHost: FloorpWebExtensionLazyBackgroundHost
    private let nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)?
    private var controllers = [ObjectIdentifier: ControllerEntry]()

    init(
        backgroundHost: FloorpWebExtensionLazyBackgroundHost,
        nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)? = nil
    ) {
        self.backgroundHost = backgroundHost
        self.nativeAPIDispatcher = nativeAPIDispatcher
    }

    convenience init(
        nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)? = nil
    ) {
        self.init(
            backgroundHost: FloorpWebExtensionLazyBackgroundHost(),
            nativeAPIDispatcher: nativeAPIDispatcher
        )
    }

    static func isolatedContentWorldName(for extensionID: FloorpWebExtensionID) -> String {
        "floorp.webextension.content.\(extensionID.rawValue)"
    }

    /// Replaces the extension's bridge for this controller and trusted
    /// document generation. Registration happens before the bootstrap script
    /// is installed, so the first document-start call cannot race the handler.
    func installBridge(
        for extensionID: FloorpWebExtensionID,
        tab: FloorpWebExtensionTabContext,
        on controller: WKUserContentController,
        authorizeDocument: @escaping DocumentAuthorization
    ) {
        removeReleasedControllers()
        let identifier = ObjectIdentifier(controller)
        let entry = controllers[identifier] ?? ControllerEntry(controller: controller)
        controllers[identifier] = entry
        entry.sessions.removeValue(forKey: extensionID)?.detach()

        let session = FloorpWebExtensionMessageBridgeSession(
            extensionID: extensionID,
            trustedTab: tab,
            backgroundHost: backgroundHost,
            nativeAPIDispatcher: nativeAPIDispatcher,
            authorizeDocument: authorizeDocument
        )
        session.attach(to: controller)
        entry.sessions[extensionID] = session
    }

    func removeBridge(
        for extensionID: FloorpWebExtensionID,
        from controller: WKUserContentController
    ) {
        let identifier = ObjectIdentifier(controller)
        controllers[identifier]?.sessions.removeValue(forKey: extensionID)?.detach()
        if controllers[identifier]?.sessions.isEmpty == true {
            controllers.removeValue(forKey: identifier)
        }
    }

    func removeExtension(_ extensionID: FloorpWebExtensionID) {
        for entry in controllers.values {
            entry.sessions.removeValue(forKey: extensionID)?.detach()
        }
        backgroundHost.unregister(extensionID: extensionID)
        removeReleasedControllers()
    }

    func tearDown() {
        for entry in controllers.values {
            entry.sessions.values.forEach { $0.detach() }
        }
        controllers.removeAll()
        backgroundHost.tearDown()
    }

    private func removeReleasedControllers() {
        controllers = controllers.filter { _, entry in entry.controller != nil }
    }
}

@MainActor
private final class FloorpWebExtensionMessageBridgeSession: NSObject, WKScriptMessageHandlerWithReply {
    private static let envelopeMaximumByteCount = 64 * 1024
    private static let version = 1

    private let extensionID: FloorpWebExtensionID
    private let trustedTab: FloorpWebExtensionTabContext
    private let backgroundHost: FloorpWebExtensionLazyBackgroundHost
    private let nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)?
    private let authorizeDocument: FloorpWebExtensionMessageRuntime.DocumentAuthorization
    private let nonce: String
    private let handlerName: String
    private let contentWorld: WKContentWorld
    private weak var controller: WKUserContentController?

    init(
        extensionID: FloorpWebExtensionID,
        trustedTab: FloorpWebExtensionTabContext,
        backgroundHost: FloorpWebExtensionLazyBackgroundHost,
        nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)?,
        authorizeDocument: @escaping FloorpWebExtensionMessageRuntime.DocumentAuthorization
    ) {
        self.extensionID = extensionID
        self.trustedTab = trustedTab
        self.backgroundHost = backgroundHost
        self.nativeAPIDispatcher = nativeAPIDispatcher
        self.authorizeDocument = authorizeDocument
        nonce = Self.makeNonce()
        handlerName = "floorpRuntime_\(nonce.prefix(24))"
        contentWorld = .world(name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID))
    }

    func attach(to controller: WKUserContentController) {
        detach()
        self.controller = controller
        controller.addScriptMessageHandler(self, contentWorld: contentWorld, name: handlerName)
        let script = WKUserScript(
            source: Self.bootstrapSource(
                extensionID: extensionID,
                nonce: nonce,
                handlerName: handlerName
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: contentWorld
        )
        FloorpWebContentPolicyCoordinator.coordinator(for: controller).replaceUserScripts(
            [script],
            ownedBy: Self.owner(for: extensionID)
        )
    }

    func detach() {
        guard let controller else { return }
        FloorpWebContentPolicyCoordinator.coordinator(for: controller).removeUserScripts(
            ownedBy: Self.owner(for: extensionID)
        )
        controller.removeScriptMessageHandler(forName: handlerName, contentWorld: contentWorld)
        self.controller = nil
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard userContentController === controller,
              let currentURL = message.frameInfo.request.url else {
            replyHandler(Self.failureReply(.unauthorizedDocument, requestID: nil), nil)
            return
        }

        let body = message.body
        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler(Self.failureReply(.backgroundUnavailable, requestID: nil), nil)
                return
            }
            let reply = await serializedReply(
                body: body,
                currentURL: currentURL,
                isMainFrame: message.frameInfo.isMainFrame
            )
            replyHandler(reply, nil)
        }
    }

    /// Kept as a narrow test seam so authentication and authorization failures
    /// do not require constructing WebKit-owned `WKScriptMessage` instances.
    func serializedReply(
        body: Any,
        currentURL: URL,
        isMainFrame: Bool
    ) async -> String {
        var requestID: String?
        do {
            let envelope = try decodeEnvelope(body)
            requestID = envelope.requestID
            guard authorizeDocument(currentURL, isMainFrame, trustedTab) else {
                throw FloorpWebExtensionMessageError.unauthorizedDocument
            }
            let sender = FloorpWebExtensionRuntimeMessageSender(
                extensionID: extensionID,
                tabID: trustedTab.tabID,
                documentGeneration: trustedTab.documentGeneration,
                url: currentURL,
                isMainFrame: isMainFrame,
                isPrivate: trustedTab.isPrivate
            )
            let response: FloorpWebExtensionMessagePayload?
            if envelope.operation == "runtime.sendMessage" {
                response = try await backgroundHost.dispatch(envelope.payload, sender: sender)
            } else if let nativeAPIDispatcher {
                response = try await nativeAPIDispatcher.dispatch(
                    operation: envelope.operation,
                    payload: envelope.payload,
                    sender: sender
                )
            } else {
                throw FloorpWebExtensionMessageError.unsupportedOperation
            }
            return try Self.successReply(response, requestID: envelope.requestID)
        } catch let error as FloorpWebExtensionMessageError {
            return Self.failureReply(error, requestID: requestID)
        } catch {
            return Self.failureReply(.handlerFailed, requestID: requestID)
        }
    }

    private struct Envelope {
        let requestID: String
        let operation: String
        let payload: FloorpWebExtensionMessagePayload
    }

    private func decodeEnvelope(_ body: Any) throws -> Envelope {
        guard let serialized = body as? String,
              let data = serialized.data(using: .utf8),
              data.count <= Self.envelopeMaximumByteCount,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "nonce", "extensionId", "operation", "requestId", "payload"],
              let version = object["version"] as? NSNumber,
              version.intValue == Self.version,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              let suppliedNonce = object["nonce"] as? String,
              Self.constantTimeEqual(suppliedNonce, nonce),
              let suppliedExtensionID = object["extensionId"] as? String,
              suppliedExtensionID == extensionID.rawValue,
              let operation = object["operation"] as? String,
              Self.isValidOperation(operation),
              let requestID = object["requestId"] as? String,
              (1...128).contains(requestID.utf8.count),
              let payloadObject = object["payload"] else {
            throw FloorpWebExtensionMessageError.authenticationFailed
        }

        let payloadData: Data
        do {
            payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: .fragmentsAllowed)
        } catch {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        return Envelope(
            requestID: requestID,
            operation: operation,
            payload: try FloorpWebExtensionMessagePayload(jsonData: payloadData)
        )
    }

    private static func isValidOperation(_ operation: String) -> Bool {
        (1...128).contains(operation.utf8.count) && operation.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) ||
                ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z")) ||
                ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) ||
                $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_")
        }
    }

    private static func successReply(
        _ payload: FloorpWebExtensionMessagePayload?,
        requestID: String
    ) throws -> String {
        var object: [String: Any] = [
            "ok": true,
            "requestId": requestID,
            "hasPayload": payload != nil
        ]
        if let payload {
            object["payload"] = try JSONSerialization.jsonObject(
                with: payload.jsonData,
                options: .fragmentsAllowed
            )
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= envelopeMaximumByteCount,
              let serialized = String(data: data, encoding: .utf8) else {
            throw FloorpWebExtensionMessageError.payloadTooLarge
        }
        return serialized
    }

    private static func failureReply(
        _ error: FloorpWebExtensionMessageError,
        requestID: String?
    ) -> String {
        var object: [String: Any] = [
            "ok": false,
            "error": error.bridgeCode
        ]
        if let requestID {
            object["requestId"] = requestID
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let serialized = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"malformed_message"}"#
        }
        return serialized
    }

    private static func owner(for extensionID: FloorpWebExtensionID) -> String {
        "floorp.webextension.bridge.\(extensionID.rawValue)"
    }

    private static func makeNonce() -> String {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func bootstrapSource(
        extensionID: FloorpWebExtensionID,
        nonce: String,
        handlerName: String
    ) -> String {
        let extensionLiteral = javaScriptLiteral(extensionID.rawValue)
        let nonceLiteral = javaScriptLiteral(nonce)
        let handlerLiteral = javaScriptLiteral(handlerName)
        return """
        (() => {
          "use strict";
          const nativeHandler = globalThis.webkit?.messageHandlers?.[\(handlerLiteral)];
          if (!nativeHandler || typeof nativeHandler.postMessage !== "function") return;
          let nextRequest = 0;
          const request = (operation, payload = {}) => {
            const requestId = `${Date.now()}:${++nextRequest}`;
            let serialized;
            try {
              serialized = JSON.stringify({
                version: 1,
                nonce: \(nonceLiteral),
                extensionId: \(extensionLiteral),
                operation,
                requestId,
                payload
              });
            } catch (_) {
              return Promise.reject(new Error("WebExtension message is not JSON serializable"));
            }
            if (typeof serialized !== "string") {
              return Promise.reject(new Error("WebExtension message is not JSON serializable"));
            }
            return nativeHandler.postMessage(serialized).then((rawReply) => {
              const reply = JSON.parse(rawReply);
              if (!reply || reply.requestId !== requestId) {
                throw new Error("Invalid WebExtension bridge reply");
              }
              if (!reply.ok) {
                throw new Error(reply.error || "WebExtension bridge request failed");
              }
              return reply.hasPayload ? reply.payload : undefined;
            });
          };
          const normalizeKeys = (keys) => {
            if (keys == null) return null;
            if (typeof keys === "string") return [keys];
            if (Array.isArray(keys) && keys.every((key) => typeof key === "string")) return keys;
            throw new TypeError("Only string and string-array storage keys are supported");
          };
          const storageArea = (area) => Object.freeze({
            get(keys = null) { return request(`storage.${area}.get`, {keys: normalizeKeys(keys)}); },
            set(items) {
              if (!items || typeof items !== "object" || Array.isArray(items)) {
                return Promise.reject(new TypeError("storage.set requires an object"));
              }
              return request(`storage.${area}.set`, {items});
            },
            remove(keys) { return request(`storage.${area}.remove`, {keys: normalizeKeys(keys)}); },
            clear() { return request(`storage.${area}.clear`); },
            getBytesInUse(keys = null) {
              return request(`storage.${area}.getBytesInUse`, {keys: normalizeKeys(keys)})
                .then((result) => result.value);
            }
          });
          const runtime = Object.freeze({
            sendMessage(message) { return request("runtime.sendMessage", message); }
          });
          const storage = Object.freeze({local: storageArea("local"), session: storageArea("session")});
          const i18n = Object.freeze({
            getMessage(name, substitutions = []) {
              const values = typeof substitutions === "string" ? [substitutions] : substitutions;
              if (!Array.isArray(values) || !values.every((value) => typeof value === "string")) return "";
              return request("i18n.getMessage", {name, substitutions: values}).then((result) => result.value);
            },
            getUILanguage() { return request("i18n.getUILanguage").then((result) => result.value); },
            getAcceptLanguages() {
              return request("i18n.getAcceptLanguages").then((result) => result.values);
            }
          });
          const alarms = Object.freeze({
            create(name, info) { return request("alarms.create", Object.assign({name}, info || {})); },
            get(name) { return request("alarms.get", {name}); },
            getAll() { return request("alarms.getAll"); },
            clear(name) { return request("alarms.clear", {name}).then((result) => result.value); },
            clearAll() { return request("alarms.clearAll").then((result) => result.value); }
          });
          const action = Object.freeze({
            getTitle() { return request("action.getTitle").then((result) => result.value); },
            setTitle(details) { return request("action.setTitle", {value: details?.title ?? null}); },
            getBadgeText() { return request("action.getBadgeText").then((result) => result.value); },
            setBadgeText(details) { return request("action.setBadgeText", {value: details?.text ?? null}); },
            getBadgeBackgroundColor() {
              return request("action.getBadgeBackgroundColor").then((result) => result.value);
            },
            setBadgeBackgroundColor(details) {
              return request("action.setBadgeBackgroundColor", {value: details?.color ?? null});
            },
            enable() { return request("action.enable"); },
            disable() { return request("action.disable"); }
          });
          const browserObject = globalThis.browser && typeof globalThis.browser === "object"
            ? globalThis.browser
            : {};
          for (const [name, value] of Object.entries({runtime, storage, i18n, alarms, action})) {
            Object.defineProperty(browserObject, name, {
              value,
              enumerable: true,
              configurable: false,
              writable: false
            });
          }
          Object.defineProperty(globalThis, "browser", {
            value: browserObject,
            enumerable: true,
            configurable: false,
            writable: false
          });
        })();
        """
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
