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

protocol FloorpWebExtensionMessageSender: Sendable {
    var extensionID: FloorpWebExtensionID { get }
    var isPrivate: Bool { get }
}

/// Sender identity for a document associated with an ordinary browser tab.
/// Extension-owned pages deliberately use `FloorpWebExtensionPageRuntimeMessageSender`
/// instead of inventing a tab identifier or document generation.
struct FloorpWebExtensionRuntimeMessageSender: Equatable, Sendable, FloorpWebExtensionMessageSender {
    let extensionID: FloorpWebExtensionID
    let tabID: Int
    let documentGeneration: UInt64
    let url: URL
    let isMainFrame: Bool
    let isPrivate: Bool
}

/// Sender identity for an action popup or options page.  Its opaque origin and
/// immutable package generation are authenticated by the page bridge before
/// it reaches either the native API host or a lazy background handler.
struct FloorpWebExtensionPageRuntimeMessageSender: Equatable, Sendable, FloorpWebExtensionMessageSender {
    let extensionID: FloorpWebExtensionID
    let profileKey: FloorpWebExtensionCoordinatorProfileKey
    let packageGeneration: String
    let originHost: String
    let surface: FloorpWebExtensionPageSurface

    var isPrivate: Bool {
        profileKey.isPrivateBrowsing
    }
}

/// Sender identity for JavaScript executing in the package-owned hidden
/// background WebView. Unlike a popup/options sender, this identity is bound
/// to the profile and immutable package generation that created the runtime.
struct FloorpWebExtensionBackgroundRuntimeMessageSender: Equatable, Sendable, FloorpWebExtensionMessageSender {
    let extensionID: FloorpWebExtensionID
    let profileKey: FloorpWebExtensionCoordinatorProfileKey
    let packageGeneration: String
    let originHost: String

    var isPrivate: Bool {
        profileKey.isPrivateBrowsing
    }
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
    case unsupportedCodeExecution

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
        case .unsupportedCodeExecution:
            return "Arbitrary JavaScript code execution is not supported."
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
        case .unsupportedCodeExecution: return "unsupported_code_execution"
        }
    }
}

/// A lazily-created background event target. Implementations may be reviewed
/// native handlers or the restricted package-backed WebKit runtime.
@MainActor
protocol FloorpWebExtensionBackgroundEventHandling: AnyObject {
    func handleRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload?

    func handleAlarm(_ event: FloorpWebExtensionAlarmEvent) async throws
}

extension FloorpWebExtensionBackgroundEventHandling {
    func handleAlarm(_ event: FloorpWebExtensionAlarmEvent) async throws {
        throw FloorpWebExtensionMessageError.unsupportedOperation
    }
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
        sender: any FloorpWebExtensionMessageSender
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

    /// Wakes the same lazy generation used by runtime messaging and delivers
    /// a typed alarm event. The generation identity check after JavaScript
    /// returns suppresses an old worker's completion after update/disable.
    func dispatchAlarm(_ event: FloorpWebExtensionAlarmEvent) async throws {
        guard let entry = entries[event.extensionID] else {
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
        do {
            try await handler.handleAlarm(event)
        } catch let error as FloorpWebExtensionMessageError {
            throw error
        } catch {
            throw FloorpWebExtensionMessageError.handlerFailed
        }
        guard entries[event.extensionID] === entry else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }
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
        var sessions = [BridgeSessionKey: FloorpWebExtensionMessageBridgeSession]()

        init(controller: WKUserContentController) {
            self.controller = controller
        }
    }

    private enum BridgeSessionKind: Hashable {
        case tab
        case page
        case background
    }

    private struct BridgeSessionKey: Hashable {
        let extensionID: FloorpWebExtensionID
        let kind: BridgeSessionKind
    }

    let backgroundHost: FloorpWebExtensionLazyBackgroundHost
    let profileKey: FloorpWebExtensionCoordinatorProfileKey?
    private let nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)?
    private var controllers = [ObjectIdentifier: ControllerEntry]()
    private var activePageGenerations = [FloorpWebExtensionID: String]()
    private var activeBackgroundGenerations = [FloorpWebExtensionID: String]()

    init(
        backgroundHost: FloorpWebExtensionLazyBackgroundHost,
        nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)? = nil,
        profileKey: FloorpWebExtensionCoordinatorProfileKey? = nil
    ) {
        self.backgroundHost = backgroundHost
        self.nativeAPIDispatcher = nativeAPIDispatcher
        self.profileKey = profileKey
    }

    convenience init(
        nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)? = nil
    ) {
        self.init(
            backgroundHost: FloorpWebExtensionLazyBackgroundHost(),
            nativeAPIDispatcher: nativeAPIDispatcher,
            profileKey: (nativeAPIDispatcher as? FloorpWebExtensionAPIHost)?.profileKey
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
        let key = BridgeSessionKey(extensionID: extensionID, kind: .tab)
        entry.sessions.removeValue(forKey: key)?.detach()

        let session = FloorpWebExtensionMessageBridgeSession(
            extensionID: extensionID,
            backgroundHost: backgroundHost,
            nativeAPIDispatcher: nativeAPIDispatcher,
            contentWorld: .world(name: Self.isolatedContentWorldName(for: extensionID)),
            owner: "floorp.webextension.bridge.tab.\(extensionID.rawValue)",
            authorizeDocument: { url, isMainFrame in
                authorizeDocument(url, isMainFrame, tab)
            },
            makeSender: { url, isMainFrame in
                FloorpWebExtensionRuntimeMessageSender(
                    extensionID: extensionID,
                    tabID: tab.tabID,
                    documentGeneration: tab.documentGeneration,
                    url: url,
                    isMainFrame: isMainFrame,
                    isPrivate: tab.isPrivate
                )
            }
        )
        session.attach(to: controller)
        entry.sessions[key] = session
    }

    /// Removes tab-only bridge sessions that are not part of the current
    /// pre-navigation snapshot.  Without this reconciliation a bridge from a
    /// previously granted URL could remain attached after host access is
    /// revoked or the next navigation no longer matches that extension.
    func reconcileTabBridges(
        on controller: WKUserContentController,
        retaining extensionIDs: Set<FloorpWebExtensionID>
    ) {
        let identifier = ObjectIdentifier(controller)
        guard let entry = controllers[identifier] else { return }
        let staleKeys = entry.sessions.keys.filter {
            $0.kind == .tab && !extensionIDs.contains($0.extensionID)
        }
        for key in staleKeys {
            entry.sessions.removeValue(forKey: key)?.detach()
        }
        if entry.sessions.isEmpty {
            controllers.removeValue(forKey: identifier)
        }
    }

    /// Installs an action/options-page bridge only when this runtime belongs to
    /// the page's profile.  Unlike a browser-tab bridge this never creates a
    /// synthetic tab context: the dispatched sender retains its page origin
    /// and immutable package generation.
    @discardableResult
    func installPageBridge(
        _ page: FloorpWebExtensionPageBridgeIdentity,
        on controller: WKUserContentController
    ) -> Bool {
        guard profileKey == page.profileKey else {
            return false
        }
        if let nativeHost = nativeAPIDispatcher as? FloorpWebExtensionAPIHost,
           nativeHost.profileKey != page.profileKey {
            return false
        }

        if let activeGeneration = activePageGenerations[page.extensionID],
           activeGeneration != page.packageGeneration {
            invalidatePageBridges(for: page.extensionID)
        }
        activePageGenerations[page.extensionID] = page.packageGeneration

        removeReleasedControllers()
        let identifier = ObjectIdentifier(controller)
        let entry = controllers[identifier] ?? ControllerEntry(controller: controller)
        controllers[identifier] = entry
        let key = BridgeSessionKey(extensionID: page.extensionID, kind: .page)
        entry.sessions.removeValue(forKey: key)?.detach()

        let session = FloorpWebExtensionMessageBridgeSession(
            extensionID: page.extensionID,
            backgroundHost: backgroundHost,
            nativeAPIDispatcher: nativeAPIDispatcher,
            // Popup/options resources run in WebKit's page world.  Their
            // custom-scheme origin is a per-controller random value, and the
            // session revalidates that exact main-frame origin plus immutable
            // package generation before every message.  This is therefore a
            // deliberately narrow exception to tab content-script isolation:
            // package JavaScript can reach its APIs, while web content cannot
            // reuse the bridge after a navigation.
            contentWorld: .page,
            owner: "floorp.webextension.bridge.page.\(page.extensionID.rawValue).\(page.originHost)",
            authorizeDocument: { [weak self] url, isMainFrame in
                self?.activePageGenerations[page.extensionID] == page.packageGeneration &&
                    page.authorizesDocument(url, isMainFrame: isMainFrame)
            },
            makeSender: { _, _ in
                FloorpWebExtensionPageRuntimeMessageSender(
                    extensionID: page.extensionID,
                    profileKey: page.profileKey,
                    packageGeneration: page.packageGeneration,
                    originHost: page.originHost,
                    surface: page.surface
                )
            }
        )
        session.attach(to: controller)
        entry.sessions[key] = session
        return true
    }

    /// Installs the native API bridge into one hidden, package-origin
    /// background document. The profile, extension, generation, random origin,
    /// and main-frame URL are revalidated for every request from JavaScript.
    @discardableResult
    func installBackgroundBridge(
        _ background: FloorpWebExtensionBackgroundBridgeIdentity,
        on controller: WKUserContentController
    ) -> Bool {
        guard profileKey == background.profileKey else {
            return false
        }
        if let nativeHost = nativeAPIDispatcher as? FloorpWebExtensionAPIHost,
           nativeHost.profileKey != background.profileKey {
            return false
        }

        if let activeGeneration = activeBackgroundGenerations[background.extensionID],
           activeGeneration != background.packageGeneration {
            invalidateBackgroundBridges(for: background.extensionID)
        }
        activeBackgroundGenerations[background.extensionID] = background.packageGeneration

        removeReleasedControllers()
        let identifier = ObjectIdentifier(controller)
        let entry = controllers[identifier] ?? ControllerEntry(controller: controller)
        controllers[identifier] = entry
        let key = BridgeSessionKey(extensionID: background.extensionID, kind: .background)
        entry.sessions.removeValue(forKey: key)?.detach()

        let session = FloorpWebExtensionMessageBridgeSession(
            extensionID: background.extensionID,
            backgroundHost: backgroundHost,
            nativeAPIDispatcher: nativeAPIDispatcher,
            contentWorld: .page,
            owner: "floorp.webextension.bridge.background.\(background.extensionID.rawValue).\(background.originHost)",
            authorizeDocument: { [weak self] url, isMainFrame in
                self?.activeBackgroundGenerations[background.extensionID] == background.packageGeneration &&
                    background.authorizesDocument(url, isMainFrame: isMainFrame)
            },
            makeSender: { _, _ in
                FloorpWebExtensionBackgroundRuntimeMessageSender(
                    extensionID: background.extensionID,
                    profileKey: background.profileKey,
                    packageGeneration: background.packageGeneration,
                    originHost: background.originHost
                )
            }
        )
        session.attach(to: controller)
        entry.sessions[key] = session
        return true
    }

    func removeBridge(
        for extensionID: FloorpWebExtensionID,
        from controller: WKUserContentController
    ) {
        let identifier = ObjectIdentifier(controller)
        let key = BridgeSessionKey(extensionID: extensionID, kind: .tab)
        controllers[identifier]?.sessions.removeValue(forKey: key)?.detach()
        if controllers[identifier]?.sessions.isEmpty == true {
            controllers.removeValue(forKey: identifier)
        }
    }

    /// Revokes page capabilities on package disable/update.  Passing a
    /// generation retains only page bridges bound to that exact generation.
    func invalidatePageBridges(
        for extensionID: FloorpWebExtensionID,
        retainingGeneration: String? = nil
    ) {
        for entry in controllers.values {
            let pageKeys = entry.sessions.keys.filter {
                $0.extensionID == extensionID && $0.kind == .page
            }
            for key in pageKeys {
                entry.sessions.removeValue(forKey: key)?.detach()
            }
        }
        if activePageGenerations[extensionID] != retainingGeneration {
            activePageGenerations.removeValue(forKey: extensionID)
        }
        removeReleasedControllers()
    }

    /// Revokes all JavaScript/API capabilities for a background generation.
    /// An update may retain only an exact generation; disable/uninstall passes
    /// nil and therefore fails closed immediately.
    func invalidateBackgroundBridges(
        for extensionID: FloorpWebExtensionID,
        retainingGeneration: String? = nil
    ) {
        for entry in controllers.values {
            let backgroundKeys = entry.sessions.keys.filter {
                $0.extensionID == extensionID && $0.kind == .background
            }
            for key in backgroundKeys {
                entry.sessions.removeValue(forKey: key)?.detach()
            }
        }
        if activeBackgroundGenerations[extensionID] != retainingGeneration {
            activeBackgroundGenerations.removeValue(forKey: extensionID)
        }
        removeReleasedControllers()
    }

    func isBackgroundBridgeActive(
        _ background: FloorpWebExtensionBackgroundBridgeIdentity
    ) -> Bool {
        profileKey == background.profileKey &&
            activeBackgroundGenerations[background.extensionID] == background.packageGeneration
    }

    func dispatchAlarmEvent(_ event: FloorpWebExtensionAlarmEvent) async throws {
        guard profileKey != nil else {
            throw FloorpWebExtensionMessageError.authenticationFailed
        }
        try await backgroundHost.dispatchAlarm(event)
    }

    func removeExtension(_ extensionID: FloorpWebExtensionID) {
        for entry in controllers.values {
            let keys = entry.sessions.keys.filter { $0.extensionID == extensionID }
            keys.forEach { key in
                entry.sessions.removeValue(forKey: key)?.detach()
            }
        }
        activePageGenerations.removeValue(forKey: extensionID)
        activeBackgroundGenerations.removeValue(forKey: extensionID)
        backgroundHost.unregister(extensionID: extensionID)
        removeReleasedControllers()
    }

    func tearDown() {
        for entry in controllers.values {
            entry.sessions.values.forEach { $0.detach() }
        }
        controllers.removeAll()
        activePageGenerations.removeAll()
        activeBackgroundGenerations.removeAll()
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
    private let backgroundHost: FloorpWebExtensionLazyBackgroundHost
    private let nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)?
    private let contentPolicyOwner: String
    private let authorizeDocument: @MainActor (URL, Bool) -> Bool
    private let makeSender: @MainActor (URL, Bool) -> any FloorpWebExtensionMessageSender
    private let nonce: String
    private let handlerName: String
    private let contentWorld: WKContentWorld
    private weak var controller: WKUserContentController?

    init(
        extensionID: FloorpWebExtensionID,
        backgroundHost: FloorpWebExtensionLazyBackgroundHost,
        nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)?,
        contentWorld: WKContentWorld,
        owner: String,
        authorizeDocument: @escaping @MainActor (URL, Bool) -> Bool,
        makeSender: @escaping @MainActor (URL, Bool) -> any FloorpWebExtensionMessageSender
    ) {
        self.extensionID = extensionID
        self.backgroundHost = backgroundHost
        self.nativeAPIDispatcher = nativeAPIDispatcher
        contentPolicyOwner = owner
        self.authorizeDocument = authorizeDocument
        self.makeSender = makeSender
        nonce = Self.makeNonce()
        handlerName = "floorpRuntime_\(nonce.prefix(24))"
        self.contentWorld = contentWorld
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
            ownedBy: contentPolicyOwner
        )
    }

    func detach() {
        guard let controller else { return }
        FloorpWebContentPolicyCoordinator.coordinator(for: controller).removeUserScripts(
            ownedBy: contentPolicyOwner
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
            guard authorizeDocument(currentURL, isMainFrame) else {
                throw FloorpWebExtensionMessageError.unauthorizedDocument
            }
            let sender = makeSender(currentURL, isMainFrame)
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
          const runtimeOnMessageListeners = [];
          const alarmListeners = [];
          const serializeResponse = (value) => JSON.stringify(value === undefined ? null : value);
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
                const error = new Error(reply.error || "WebExtension bridge request failed");
                error.code = reply.error || "bridge_request_failed";
                throw error;
              }
              return reply.hasPayload ? reply.payload : undefined;
            });
          };
          const invokeMessageListener = async (listener, message, sender) => {
            let didRespond = false;
            let resolveResponse;
            const response = new Promise((resolve) => { resolveResponse = resolve; });
            const sendResponse = (value) => {
              if (didRespond) return false;
              didRespond = true;
              resolveResponse(value);
              return true;
            };
            const result = listener(message, sender, sendResponse);
            if (result && typeof result.then === "function") return await result;
            if (didRespond) return await response;
            if (result === true) {
              return await Promise.race([
                response,
                new Promise((resolve) => setTimeout(() => resolve(undefined), 5_000))
              ]);
            }
            return result;
          };
          const deliverTabsMessage = async (message, sender) => {
            for (const listener of runtimeOnMessageListeners) {
              if (typeof listener !== "function") continue;
              const value = await invokeMessageListener(listener, message, sender);
              if (typeof value !== "undefined") {
                return serializeResponse(value);
              }
            }
            return serializeResponse(null);
          };
          const deliverAlarm = async (alarm) => {
            for (const listener of alarmListeners) {
              if (typeof listener === "function") await listener(alarm);
            }
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
            id: \(extensionLiteral),
            sendMessage(message) { return request("runtime.sendMessage", message); },
            getManifest() { return request("runtime.getManifest"); },
            getURL(path = "") {
              return request("runtime.getURL", {path: String(path)}).then((result) => result.value);
            },
            reload() { return request("runtime.reload"); },
            onMessage: Object.freeze({
              addListener(listener) {
                if (typeof listener === "function" && !runtimeOnMessageListeners.includes(listener)) {
                  runtimeOnMessageListeners.push(listener);
                }
              },
              removeListener(listener) {
                const index = runtimeOnMessageListeners.indexOf(listener);
                if (index >= 0) runtimeOnMessageListeners.splice(index, 1);
              },
              hasListener(listener) {
                return runtimeOnMessageListeners.includes(listener);
              }
            })
          });
          const permissions = Object.freeze({
            getAll() { return request("permissions.getAll"); },
            contains(details = {}) {
              return request("permissions.contains", {
                permissions: details?.permissions,
                origins: details?.origins
              }).then((result) => result.value);
            },
            request(details = {}) {
              return request("permissions.request", {
                permissions: details?.permissions,
                origins: details?.origins
              }).then((result) => result.value);
            },
            remove(details = {}) {
              return request("permissions.remove", {
                permissions: details?.permissions,
                origins: details?.origins
              }).then((result) => result.value);
            }
          });
          const scripting = Object.freeze({
            getRegisteredContentScripts(filter = {}) {
              return request("scripting.getRegisteredContentScripts", {filter});
            },
            registerContentScripts(scripts) {
              return request("scripting.registerContentScripts", {scripts});
            },
            updateContentScripts(scripts) {
              return request("scripting.updateContentScripts", {scripts});
            },
            unregisterContentScripts(filter = {}) {
              return request("scripting.unregisterContentScripts", {ids: filter?.ids});
            },
            insertCSS(details) {
              return request("scripting.insertCSS", details).then((result) => result.handles);
            },
            removeCSS(details) { return request("scripting.removeCSS", details); },
            executeScript(details) { return request("scripting.executeScript", details); }
          });
          const declarativeNetRequest = Object.freeze({
            GUARANTEED_MINIMUM_STATIC_RULES: 50_000,
            MAX_NUMBER_OF_STATIC_RULESETS: 50,
            MAX_NUMBER_OF_DYNAMIC_RULES: 5_000,
            MAX_NUMBER_OF_SESSION_RULES: 5_000,
            MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 5_000,
            MAX_NUMBER_OF_RULES_PER_UPDATE: 1_000,
            getEnabledRulesets() {
              return request("declarativeNetRequest.getEnabledRulesets").then((result) => result.values);
            },
            updateEnabledRulesets(details = {}) {
              return request("declarativeNetRequest.updateEnabledRulesets", details);
            },
            getDynamicRules() { return request("declarativeNetRequest.getDynamicRules"); },
            updateDynamicRules(details = {}) {
              return request("declarativeNetRequest.updateDynamicRules", details);
            },
            getSessionRules() { return request("declarativeNetRequest.getSessionRules"); },
            updateSessionRules(details = {}) {
              return request("declarativeNetRequest.updateSessionRules", details);
            },
            isRegexSupported(details) {
              return request("declarativeNetRequest.isRegexSupported", details);
            },
            getLimits() { return request("declarativeNetRequest.getLimits"); }
          });
          const tabs = Object.freeze({
            query(queryInfo = {}) { return request("tabs.query", {queryInfo}); },
            get(tabId) { return request("tabs.get", {tabId}); },
            create(createProperties = {}) { return request("tabs.create", {createProperties}); },
            update(tabId, updateProperties = {}) { return request("tabs.update", {tabId, updateProperties}); },
            reload(tabId, reloadProperties = {}) { return request("tabs.reload", {tabId, reloadProperties}); },
            sendMessage(tabId, message, options = {}) {
              return request("tabs.sendMessage", {tabId, message, options});
            }
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
            clearAll() { return request("alarms.clearAll").then((result) => result.value); },
            onAlarm: Object.freeze({
              addListener(listener) {
                if (typeof listener === "function" && !alarmListeners.includes(listener)) {
                  alarmListeners.push(listener);
                }
              },
              removeListener(listener) {
                const index = alarmListeners.indexOf(listener);
                if (index >= 0) alarmListeners.splice(index, 1);
              },
              hasListener(listener) { return alarmListeners.includes(listener); }
            })
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
          Object.defineProperty(globalThis, "__floorpWebExtensionDeliverTabsMessage", {
            value: deliverTabsMessage,
            enumerable: false,
            configurable: false,
            writable: false
          });
          Object.defineProperty(globalThis, "__floorpWebExtensionDeliverRuntimeMessage", {
            value: deliverTabsMessage,
            enumerable: false,
            configurable: false,
            writable: false
          });
          Object.defineProperty(globalThis, "__floorpWebExtensionDeliverAlarm", {
            value: deliverAlarm,
            enumerable: false,
            configurable: false,
            writable: false
          });
          for (const [name, value] of Object.entries({
            runtime,
            permissions,
            scripting,
            declarativeNetRequest,
            storage,
            i18n,
            alarms,
            action,
            tabs
          })) {
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

          let chromeLastError = null;
          const invokeChromeCallback = (promise, callback) => {
            if (typeof callback !== "function") return promise;
            promise.then(
              (value) => callback(value),
              (error) => {
                chromeLastError = Object.freeze({
                  message: error?.message || "WebExtension bridge request failed",
                  code: error?.code || "bridge_request_failed"
                });
                try { callback(); } finally { chromeLastError = null; }
              }
            );
            return undefined;
          };
          const callbackMethod = (method) => (...args) => {
            const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
            let promise;
            try {
              promise = Promise.resolve(method(...args));
            } catch (error) {
              promise = Promise.reject(error);
            }
            return invokeChromeCallback(promise, callback);
          };
          const callbackNamespace = (source, excluded = []) => {
            const target = {};
            for (const [name, value] of Object.entries(source)) {
              if (excluded.includes(name)) continue;
              Object.defineProperty(target, name, {
                value: typeof value === "function" ? callbackMethod(value) : value,
                enumerable: true,
                configurable: false,
                writable: false
              });
            }
            return target;
          };
          const packageRuntimeURL = (path = "") => {
            if (globalThis.location?.protocol !== "floorp-extension:") {
              throw new Error("runtime.getURL is unavailable outside a package origin");
            }
            const normalized = String(path).replace(/^\\/+/, "");
            const value = new URL(normalized, `${globalThis.location.origin}/`);
            if (value.origin !== globalThis.location.origin) {
              throw new Error("runtime.getURL rejected a cross-origin path");
            }
            return value.href;
          };
          const chromeRuntime = callbackNamespace(runtime, ["id", "getURL", "onMessage"]);
          Object.defineProperties(chromeRuntime, {
            id: {value: \(extensionLiteral), enumerable: true},
            getURL: {value: packageRuntimeURL, enumerable: true},
            onMessage: {value: runtime.onMessage, enumerable: true},
            lastError: {get: () => chromeLastError, enumerable: true}
          });
          const chromeObject = globalThis.chrome && typeof globalThis.chrome === "object"
            ? globalThis.chrome
            : {};
          for (const [name, value] of Object.entries({
            runtime: chromeRuntime,
            permissions: callbackNamespace(permissions),
            scripting: callbackNamespace(scripting),
            declarativeNetRequest: callbackNamespace(declarativeNetRequest),
            storage: Object.freeze({
              local: callbackNamespace(storage.local),
              session: callbackNamespace(storage.session)
            }),
            i18n: callbackNamespace(i18n),
            alarms: callbackNamespace(alarms, ["onAlarm"]),
            action: callbackNamespace(action),
            tabs: callbackNamespace(tabs)
          })) {
            if (name === "alarms") {
              Object.defineProperty(value, "onAlarm", {value: alarms.onAlarm, enumerable: true});
            }
            Object.defineProperty(chromeObject, name, {
              value,
              enumerable: true,
              configurable: false,
              writable: false
            });
          }
          Object.defineProperty(globalThis, "chrome", {
            value: chromeObject,
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
