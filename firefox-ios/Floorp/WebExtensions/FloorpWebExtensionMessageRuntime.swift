// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

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

    var frameID: Int {
        isMainFrame ? 0 : -1
    }

    var documentID: String {
        if isMainFrame {
            return FloorpWebExtensionDocumentIdentity.mainFrameID(
                tabID: tabID,
                documentGeneration: documentGeneration
            )
        }
        return FloorpWebExtensionDocumentIdentity.unsupportedSubframeID(
            tabID: tabID,
            documentGeneration: documentGeneration
        )
    }
}

/// Stable API-visible identity for the current main-frame document. The
/// browser-owned tab generation changes on every committed navigation, while
/// hashing keeps those internal counters out of extension-visible messages.
enum FloorpWebExtensionDocumentIdentity {
    static func mainFrameID(tabID: Int, documentGeneration: UInt64) -> String {
        let source = Data("\(tabID):\(documentGeneration):0".utf8)
        return SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    }

    /// We do not currently expose a stable native ID for individual
    /// subframes. Still provide a generation-bound opaque value so extension
    /// code cannot accidentally turn an unavailable subframe target into an
    /// unconstrained main-frame tabs.sendMessage call when JSON omits nil.
    static func unsupportedSubframeID(tabID: Int, documentGeneration: UInt64) -> String {
        let source = Data("\(tabID):\(documentGeneration):unsupported-subframe".utf8)
        return SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    }

    static func mainFrameID(for tab: FloorpWebExtensionTabContext) -> String {
        mainFrameID(tabID: tab.tabID, documentGeneration: tab.documentGeneration)
    }
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
    /// The authenticated WebKit URL that produced the message. This retains
    /// the exact package-relative path so a receiving package WebView can map
    /// it onto its own loadable transport origin.
    let transportURL: URL?

    init(
        extensionID: FloorpWebExtensionID,
        profileKey: FloorpWebExtensionCoordinatorProfileKey,
        packageGeneration: String,
        originHost: String,
        surface: FloorpWebExtensionPageSurface,
        transportURL: URL? = nil
    ) {
        self.extensionID = extensionID
        self.profileKey = profileKey
        self.packageGeneration = packageGeneration
        self.originHost = originHost
        self.surface = surface
        self.transportURL = transportURL
    }

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

    /// Invalidates volatile resources owned by this activation. Implementations
    /// must make outstanding work complete fail-closed and release any hidden
    /// WebKit document even when the caller that started the work is still
    /// awaiting its result.
    func invalidateBackgroundResources()
}

extension FloorpWebExtensionBackgroundEventHandling {
    func handleAlarm(_ event: FloorpWebExtensionAlarmEvent) async throws {
        throw FloorpWebExtensionMessageError.unsupportedOperation
    }

    func invalidateBackgroundResources() {}
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
        entries[extensionID]?.handler?.invalidateBackgroundResources()
        nextGeneration &+= 1
        entries[extensionID] = Entry(generation: nextGeneration, factory: factory)
    }

    func suspend(extensionID: FloorpWebExtensionID) {
        guard let current = entries[extensionID] else { return }
        current.handler?.invalidateBackgroundResources()
        nextGeneration &+= 1
        let replacement = Entry(generation: nextGeneration, factory: current.factory)
        replacement.activationCount = current.activationCount
        entries[extensionID] = replacement
    }

    /// Drops only active background handlers while retaining their reviewed
    /// factories. Replacing each active entry gives in-flight work an obsolete
    /// identity, so a reply that completes after the release fails closed.
    /// The next message or alarm creates a fresh handler lazily.
    func releaseActiveHandlers() {
        let activeExtensionIDs = entries.compactMap { extensionID, entry in
            entry.handler == nil ? nil : extensionID
        }
        for extensionID in activeExtensionIDs {
            guard let current = entries[extensionID] else { continue }
            current.handler?.invalidateBackgroundResources()
            nextGeneration &+= 1
            let replacement = Entry(generation: nextGeneration, factory: current.factory)
            replacement.activationCount = current.activationCount
            entries[extensionID] = replacement
        }
    }

    func unregister(extensionID: FloorpWebExtensionID) {
        entries[extensionID]?.handler?.invalidateBackgroundResources()
        entries.removeValue(forKey: extensionID)
    }

    func tearDown() {
        entries.values.forEach { $0.handler?.invalidateBackgroundResources() }
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
            guard entries[sender.extensionID] === entry else {
                throw FloorpWebExtensionMessageError.backgroundReplaced
            }
            throw error
        } catch {
            guard entries[sender.extensionID] === entry else {
                throw FloorpWebExtensionMessageError.backgroundReplaced
            }
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
            guard entries[event.extensionID] === entry else {
                throw FloorpWebExtensionMessageError.backgroundReplaced
            }
            throw error
        } catch {
            guard entries[event.extensionID] === entry else {
                throw FloorpWebExtensionMessageError.backgroundReplaced
            }
            throw FloorpWebExtensionMessageError.handlerFailed
        }
        guard entries[event.extensionID] === entry else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }
    }
}

@MainActor
final class FloorpWebExtensionPageMessageReceiver {
    let identity: FloorpWebExtensionPageBridgeIdentity
    let controllerIdentifier: ObjectIdentifier
    private(set) weak var webView: WKWebView?
    private var isInvalidated = false

    init(identity: FloorpWebExtensionPageBridgeIdentity, webView: WKWebView) {
        self.identity = identity
        self.webView = webView
        controllerIdentifier = ObjectIdentifier(webView.configuration.userContentController)
    }

    var isAvailable: Bool {
        guard !isInvalidated, let url = webView?.url else { return false }
        return identity.authorizesDocument(url, isMainFrame: true)
    }

    func invalidate() {
        isInvalidated = true
        webView = nil
    }

    func deliver(
        _ message: FloorpWebExtensionMessagePayload,
        sender: FloorpWebExtensionBackgroundRuntimeMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        guard sender.extensionID == identity.extensionID,
              sender.profileKey == identity.profileKey,
              sender.packageGeneration == identity.packageGeneration,
              isAvailable,
              let webView else {
            throw FloorpWebExtensionMessageError.authenticationFailed
        }
        let expectedWebView = webView
        let messageJSON = try Self.jsonString(from: message.jsonData)
        let senderJSON = try Self.senderJSON(sender, receiver: identity)
        let serialized = try await webView.callAsyncJavaScript(
            """
            const deliver = globalThis.__floorpWebExtensionDeliverPageRuntimeMessage;
            if (typeof deliver !== "function") throw new Error("Extension page bridge unavailable");
            return await deliver(JSON.parse(messageJSON), JSON.parse(senderJSON));
            """,
            arguments: ["messageJSON": messageJSON, "senderJSON": senderJSON],
            in: nil,
            contentWorld: .page
        ) as? String
        guard !isInvalidated,
              self.webView === expectedWebView,
              isAvailable else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }
        guard let serialized,
              let envelopeData = serialized.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
              let hasResponse = envelope["hasResponse"] as? Bool else {
            throw FloorpWebExtensionMessageError.handlerFailed
        }
        guard hasResponse else { return nil }
        let value = envelope["value"] ?? NSNull()
        guard JSONSerialization.isValidJSONObject(["value": value]) else {
            throw FloorpWebExtensionMessageError.handlerFailed
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try FloorpWebExtensionMessagePayload(jsonData: data)
    }

    private static func jsonString(from data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        return value
    }

    private static func senderJSON(
        _ sender: FloorpWebExtensionBackgroundRuntimeMessageSender,
        receiver: FloorpWebExtensionPageBridgeIdentity
    ) throws -> String {
        var components = URLComponents()
        components.scheme = FloorpWebExtensionPageNavigationPolicy.resourceScheme
        components.host = receiver.originHost
        components.path = "/"
        guard let receiverURL = components.url else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        let object: [String: Any] = [
            "id": sender.extensionID.rawValue,
            "isPrivate": sender.isPrivate,
            "url": receiverURL.absoluteString
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= FloorpWebExtensionMessagePayload.maximumByteCount,
              let serialized = String(data: data, encoding: .utf8) else {
            throw FloorpWebExtensionMessageError.payloadTooLarge
        }
        return serialized
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
    typealias FrameScriptAuthorization = @MainActor (
        _ scriptID: String,
        _ revisionToken: String,
        _ currentURL: URL,
        _ isMainFrame: Bool,
        _ trustedTab: FloorpWebExtensionTabContext
    ) -> Bool

    static let frameAuthorizationFunctionName = "__floorpWebExtensionAuthorizeFrameScript"
    fileprivate static let frameAuthorizationOperation = "internal.authorizeFrameScript"

    private final class ControllerEntry {
        weak var controller: WKUserContentController?
        var sessions = [BridgeSessionKey: FloorpWebExtensionMessageBridgeSession]()
        var pageIdentities = [FloorpWebExtensionID: FloorpWebExtensionPageBridgeIdentity]()

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

    private struct PageReceiverKey: Hashable {
        let controllerIdentifier: ObjectIdentifier
        let extensionID: FloorpWebExtensionID
    }

    private final class WeakPageReceiver {
        weak var value: FloorpWebExtensionPageMessageReceiver?

        init(_ value: FloorpWebExtensionPageMessageReceiver) {
            self.value = value
        }
    }

    let backgroundHost: FloorpWebExtensionLazyBackgroundHost
    let profileKey: FloorpWebExtensionCoordinatorProfileKey?
    private let nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)?
    private let scheduleBridgeRequest: @MainActor (
        @escaping @MainActor @Sendable () async -> Void
    ) -> Void
    private var controllers = [ObjectIdentifier: ControllerEntry]()
    private var pageReceivers = [PageReceiverKey: WeakPageReceiver]()
    private var activePageGenerations = [FloorpWebExtensionID: String]()
    private var activeBackgroundBridges = [FloorpWebExtensionID: FloorpWebExtensionBackgroundBridgeIdentity]()

    init(
        backgroundHost: FloorpWebExtensionLazyBackgroundHost,
        nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)? = nil,
        profileKey: FloorpWebExtensionCoordinatorProfileKey? = nil,
        scheduleBridgeRequest: @escaping @MainActor (
            @escaping @MainActor @Sendable () async -> Void
        ) -> Void = { operation in
            Task { @MainActor in
                await operation()
            }
        }
    ) {
        self.backgroundHost = backgroundHost
        self.nativeAPIDispatcher = nativeAPIDispatcher
        self.profileKey = profileKey
        self.scheduleBridgeRequest = scheduleBridgeRequest
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
        authorizeDocument: @escaping DocumentAuthorization,
        authorizeFrameScript: @escaping FrameScriptAuthorization = { _, _, _, _, _ in false }
    ) {
        removeReleasedControllers()
        let identifier = ObjectIdentifier(controller)
        let entry = controllers[identifier] ?? ControllerEntry(controller: controller)
        controllers[identifier] = entry
        let key = BridgeSessionKey(extensionID: extensionID, kind: .tab)
        entry.sessions.removeValue(forKey: key)?.detach()

        let nativeHost = nativeAPIDispatcher as? FloorpWebExtensionAPIHost
        let expectedPackageGeneration = nativeHost?.activePackageGeneration(for: extensionID)
        let session = FloorpWebExtensionMessageBridgeSession(
            extensionID: extensionID,
            nativeAPIDispatcher: nativeAPIDispatcher,
            bootstrap: nativeHost?.javaScriptBootstrap(for: extensionID),
            contentWorld: .world(name: Self.isolatedContentWorldName(for: extensionID)),
            supportsSameSurfacePageNavigation: false,
            owner: "floorp.webextension.bridge.tab.\(extensionID.rawValue)",
            authorizeDocument: { url, isMainFrame in
                authorizeDocument(url, isMainFrame, tab)
            },
            authorizeFrameScript: { scriptID, revisionToken, url, isMainFrame in
                if let nativeHost {
                    guard let expectedPackageGeneration,
                          nativeHost.isActivePackageGeneration(
                              expectedPackageGeneration,
                              for: extensionID
                          ) else {
                        return false
                    }
                }
                return authorizeFrameScript(scriptID, revisionToken, url, isMainFrame, tab)
            },
            dispatchRuntimeMessage: { [weak self] message, sender in
                guard let self else {
                    throw FloorpWebExtensionMessageError.backgroundUnavailable
                }
                return try await self.dispatchRuntimeMessage(message, sender: sender)
            },
            scheduleRequest: scheduleBridgeRequest,
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
        let nativeHost = nativeAPIDispatcher as? FloorpWebExtensionAPIHost
        if let nativeHost, nativeHost.profileKey != page.profileKey {
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
        invalidatePageReceiver(
            for: page.extensionID,
            controllerIdentifier: identifier
        )
        entry.pageIdentities[page.extensionID] = page

        let session = FloorpWebExtensionMessageBridgeSession(
            extensionID: page.extensionID,
            nativeAPIDispatcher: nativeAPIDispatcher,
            bootstrap: nativeHost?.javaScriptBootstrap(for: page.extensionID),
            // Popup/options resources run in WebKit's page world.  Their
            // custom-scheme origin is a per-controller random value, and the
            // session revalidates that exact main-frame origin plus immutable
            // package generation before every message.  This is therefore a
            // deliberately narrow exception to tab content-script isolation:
            // package JavaScript can reach its APIs, while web content cannot
            // reuse the bridge after a navigation.
            contentWorld: .page,
            supportsSameSurfacePageNavigation: true,
            owner: "floorp.webextension.bridge.page.\(page.extensionID.rawValue).\(page.originHost)",
            authorizeDocument: { [weak self] url, isMainFrame in
                self?.activePageGenerations[page.extensionID] == page.packageGeneration &&
                    page.authorizesDocument(url, isMainFrame: isMainFrame)
            },
            dispatchRuntimeMessage: { [weak self] message, sender in
                guard let self else {
                    throw FloorpWebExtensionMessageError.backgroundUnavailable
                }
                return try await self.dispatchRuntimeMessage(message, sender: sender)
            },
            scheduleRequest: scheduleBridgeRequest,
            makeSender: { url, _ in
                FloorpWebExtensionPageRuntimeMessageSender(
                    extensionID: page.extensionID,
                    profileKey: page.profileKey,
                    packageGeneration: page.packageGeneration,
                    originHost: page.originHost,
                    surface: page.surface,
                    transportURL: url
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
        let nativeHost = nativeAPIDispatcher as? FloorpWebExtensionAPIHost
        if let nativeHost, nativeHost.profileKey != background.profileKey {
            return false
        }

        if let activeBackground = activeBackgroundBridges[background.extensionID],
           activeBackground != background {
            invalidateBackgroundBridges(for: background.extensionID)
        }
        activeBackgroundBridges[background.extensionID] = background

        removeReleasedControllers()
        let identifier = ObjectIdentifier(controller)
        let entry = controllers[identifier] ?? ControllerEntry(controller: controller)
        controllers[identifier] = entry
        let key = BridgeSessionKey(extensionID: background.extensionID, kind: .background)
        entry.sessions.removeValue(forKey: key)?.detach()

        let session = FloorpWebExtensionMessageBridgeSession(
            extensionID: background.extensionID,
            nativeAPIDispatcher: nativeAPIDispatcher,
            bootstrap: nativeHost?.javaScriptBootstrap(for: background.extensionID),
            contentWorld: .page,
            supportsSameSurfacePageNavigation: false,
            owner: "floorp.webextension.bridge.background.\(background.extensionID.rawValue).\(background.originHost)",
            authorizeDocument: { [weak self] url, isMainFrame in
                self?.activeBackgroundBridges[background.extensionID] == background &&
                    background.authorizesDocument(url, isMainFrame: isMainFrame)
            },
            dispatchRuntimeMessage: { [weak self] message, sender in
                guard let self else {
                    throw FloorpWebExtensionMessageError.backgroundUnavailable
                }
                return try await self.dispatchRuntimeMessage(message, sender: sender)
            },
            scheduleRequest: scheduleBridgeRequest,
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
        for (controllerIdentifier, entry) in controllers {
            let pageKeys = entry.sessions.keys.filter {
                $0.extensionID == extensionID && $0.kind == .page
            }
            for key in pageKeys {
                entry.sessions.removeValue(forKey: key)?.detach()
            }
            entry.pageIdentities.removeValue(forKey: extensionID)
            invalidatePageReceiver(
                for: extensionID,
                controllerIdentifier: controllerIdentifier
            )
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
        if activeBackgroundBridges[extensionID]?.packageGeneration != retainingGeneration {
            activeBackgroundBridges.removeValue(forKey: extensionID)
        }
        removeReleasedControllers()
    }

    func isBackgroundBridgeActive(
        _ background: FloorpWebExtensionBackgroundBridgeIdentity
    ) -> Bool {
        profileKey == background.profileKey &&
            activeBackgroundBridges[background.extensionID] == background
    }

    func dispatchAlarmEvent(_ event: FloorpWebExtensionAlarmEvent) async throws {
        guard profileKey != nil else {
            throw FloorpWebExtensionMessageError.authenticationFailed
        }
        try await backgroundHost.dispatchAlarm(event)
    }

    func removeExtension(_ extensionID: FloorpWebExtensionID) {
        for (controllerIdentifier, entry) in controllers {
            let keys = entry.sessions.keys.filter { $0.extensionID == extensionID }
            keys.forEach { key in
                entry.sessions.removeValue(forKey: key)?.detach()
            }
            entry.pageIdentities.removeValue(forKey: extensionID)
            invalidatePageReceiver(
                for: extensionID,
                controllerIdentifier: controllerIdentifier
            )
        }
        activePageGenerations.removeValue(forKey: extensionID)
        activeBackgroundBridges.removeValue(forKey: extensionID)
        backgroundHost.unregister(extensionID: extensionID)
        removeReleasedControllers()
    }

    func tearDown() {
        for entry in controllers.values {
            entry.sessions.values.forEach { $0.detach() }
        }
        pageReceivers.values.forEach { $0.value?.invalidate() }
        controllers.removeAll()
        pageReceivers.removeAll()
        activePageGenerations.removeAll()
        activeBackgroundBridges.removeAll()
        backgroundHost.tearDown()
    }

    /// Releases the memory-heavy hidden background documents without
    /// disturbing tab/page bridges, package registration, native API state,
    /// or profile-owned policy. Background factories remain registered and
    /// will install a new authenticated bridge on the next event.
    func releaseBackgroundResources() {
        backgroundHost.releaseActiveHandlers()
        let extensionIDs = Set(activeBackgroundBridges.keys)
        for extensionID in extensionIDs {
            invalidateBackgroundBridges(for: extensionID)
        }
    }

    private func removeReleasedControllers() {
        pageReceivers = pageReceivers.filter { key, weakReceiver in
            guard let receiver = weakReceiver.value,
                  let entry = controllers[key.controllerIdentifier],
                  entry.controller != nil,
                  entry.pageIdentities[key.extensionID] == receiver.identity else {
                weakReceiver.value?.invalidate()
                return false
            }
            return true
        }
        controllers = controllers.filter { _, entry in entry.controller != nil }
    }

    func registerPageMessageReceiver(
        _ page: FloorpWebExtensionPageBridgeIdentity,
        webView: WKWebView
    ) -> FloorpWebExtensionPageMessageReceiver? {
        removeReleasedControllers()
        guard profileKey == page.profileKey,
              activePageGenerations[page.extensionID] == page.packageGeneration else {
            return nil
        }
        let controllerIdentifier = ObjectIdentifier(webView.configuration.userContentController)
        guard controllers[controllerIdentifier]?.pageIdentities[page.extensionID] == page else {
            return nil
        }
        let key = PageReceiverKey(
            controllerIdentifier: controllerIdentifier,
            extensionID: page.extensionID
        )
        if let receiver = pageReceivers[key]?.value,
           receiver.identity == page,
           receiver.webView === webView {
            return receiver
        }
        pageReceivers.removeValue(forKey: key)?.value?.invalidate()
        let receiver = FloorpWebExtensionPageMessageReceiver(
            identity: page,
            webView: webView
        )
        pageReceivers[key] = WeakPageReceiver(receiver)
        return receiver
    }

    func dispatchRuntimeMessage(
        _ message: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        guard let backgroundSender = sender as? FloorpWebExtensionBackgroundRuntimeMessageSender else {
            return try await backgroundHost.dispatch(message, sender: sender)
        }
        guard isActive(backgroundSender) else {
            throw FloorpWebExtensionMessageError.authenticationFailed
        }

        removeReleasedControllers()
        let receivers = pageReceivers.values.compactMap(\.value).filter {
            $0.identity.profileKey == backgroundSender.profileKey &&
                $0.identity.extensionID == backgroundSender.extensionID &&
                $0.identity.packageGeneration == backgroundSender.packageGeneration &&
                $0.isAvailable
        }
        var firstResponse: FloorpWebExtensionMessagePayload?
        for receiver in receivers {
            guard isActive(backgroundSender) else {
                throw FloorpWebExtensionMessageError.backgroundReplaced
            }
            do {
                let response = try await receiver.deliver(message, sender: backgroundSender)
                if firstResponse == nil, let response, isRegistered(receiver) {
                    firstResponse = response
                }
            } catch {
                if !isActive(backgroundSender) {
                    throw FloorpWebExtensionMessageError.backgroundReplaced
                }
            }
        }
        guard isActive(backgroundSender) else {
            throw FloorpWebExtensionMessageError.backgroundReplaced
        }
        return firstResponse
    }

    private func invalidatePageReceiver(
        for extensionID: FloorpWebExtensionID,
        controllerIdentifier: ObjectIdentifier
    ) {
        let key = PageReceiverKey(
            controllerIdentifier: controllerIdentifier,
            extensionID: extensionID
        )
        pageReceivers.removeValue(forKey: key)?.value?.invalidate()
    }

    private func isActive(
        _ sender: FloorpWebExtensionBackgroundRuntimeMessageSender
    ) -> Bool {
        guard profileKey == sender.profileKey,
              let background = activeBackgroundBridges[sender.extensionID] else {
            return false
        }
        return background.profileKey == sender.profileKey &&
            background.packageGeneration == sender.packageGeneration &&
            background.originHost == sender.originHost
    }

    private func isRegistered(_ receiver: FloorpWebExtensionPageMessageReceiver) -> Bool {
        let key = PageReceiverKey(
            controllerIdentifier: receiver.controllerIdentifier,
            extensionID: receiver.identity.extensionID
        )
        return pageReceivers[key]?.value === receiver &&
            controllers[key.controllerIdentifier]?.pageIdentities[key.extensionID] == receiver.identity &&
            receiver.isAvailable
    }
}

@MainActor
private final class FloorpWebExtensionMessageBridgeSession: NSObject, WKScriptMessageHandlerWithReply {
    private static let envelopeMaximumByteCount = 64 * 1024
    private static let version = 1

    private let extensionID: FloorpWebExtensionID
    private let nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)?
    private let bootstrap: FloorpWebExtensionAPIHost.JavaScriptBootstrap?
    private let contentPolicyOwner: String
    private let authorizeDocument: @MainActor (URL, Bool) -> Bool
    private let authorizeFrameScript: (@MainActor (String, String, URL, Bool) -> Bool)?
    private let dispatchRuntimeMessage: @MainActor (
        FloorpWebExtensionMessagePayload,
        any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload?
    private let scheduleRequest: @MainActor (
        @escaping @MainActor @Sendable () async -> Void
    ) -> Void
    private let makeSender: @MainActor (URL, Bool) -> any FloorpWebExtensionMessageSender
    private let nonce: String
    private let handlerName: String
    private let contentWorld: WKContentWorld
    private let supportsSameSurfacePageNavigation: Bool
    private weak var controller: WKUserContentController?
    private var attachmentGeneration: UInt64 = 0

    init(
        extensionID: FloorpWebExtensionID,
        nativeAPIDispatcher: (any FloorpWebExtensionNativeAPIDispatching)?,
        bootstrap: FloorpWebExtensionAPIHost.JavaScriptBootstrap?,
        contentWorld: WKContentWorld,
        supportsSameSurfacePageNavigation: Bool,
        owner: String,
        authorizeDocument: @escaping @MainActor (URL, Bool) -> Bool,
        authorizeFrameScript: (@MainActor (String, String, URL, Bool) -> Bool)? = nil,
        dispatchRuntimeMessage: @escaping @MainActor (
            FloorpWebExtensionMessagePayload,
            any FloorpWebExtensionMessageSender
        ) async throws -> FloorpWebExtensionMessagePayload?,
        scheduleRequest: @escaping @MainActor (
            @escaping @MainActor @Sendable () async -> Void
        ) -> Void,
        makeSender: @escaping @MainActor (URL, Bool) -> any FloorpWebExtensionMessageSender
    ) {
        self.extensionID = extensionID
        self.nativeAPIDispatcher = nativeAPIDispatcher
        self.bootstrap = bootstrap
        contentPolicyOwner = owner
        self.authorizeDocument = authorizeDocument
        self.authorizeFrameScript = authorizeFrameScript
        self.dispatchRuntimeMessage = dispatchRuntimeMessage
        self.scheduleRequest = scheduleRequest
        self.makeSender = makeSender
        nonce = Self.makeNonce()
        handlerName = "floorpRuntime_\(nonce.prefix(24))"
        self.contentWorld = contentWorld
        self.supportsSameSurfacePageNavigation = supportsSameSurfacePageNavigation
    }

    func attach(to controller: WKUserContentController) {
        detach()
        attachmentGeneration &+= 1
        self.controller = controller
        controller.addScriptMessageHandler(self, contentWorld: contentWorld, name: handlerName)
        let script = WKUserScript(
            source: Self.bootstrapSource(
                extensionID: extensionID,
                nonce: nonce,
                handlerName: handlerName,
                bootstrap: bootstrap,
                supportsSameSurfacePageNavigation: supportsSameSurfacePageNavigation
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
        attachmentGeneration &+= 1
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
        let isMainFrame = message.frameInfo.isMainFrame
        let expectedAttachment = AttachmentToken(
            generation: attachmentGeneration,
            controllerIdentifier: ObjectIdentifier(userContentController)
        )
        scheduleRequest { [self] in
            let reply = await serializedReply(
                body: body,
                currentURL: currentURL,
                isMainFrame: isMainFrame,
                expectedAttachment: expectedAttachment
            )
            replyHandler(reply, nil)
        }
    }

    /// Kept as a narrow test seam so authentication and authorization failures
    /// do not require constructing WebKit-owned `WKScriptMessage` instances.
    private func serializedReply(
        body: Any,
        currentURL: URL,
        isMainFrame: Bool,
        expectedAttachment: AttachmentToken
    ) async -> String {
        var requestID: String?
        do {
            let envelope = try decodeEnvelope(body)
            requestID = envelope.requestID
            guard isRequestAuthorized(
                expectedAttachment: expectedAttachment,
                currentURL: currentURL,
                isMainFrame: isMainFrame
            ) else {
                throw FloorpWebExtensionMessageError.unauthorizedDocument
            }
            if envelope.operation == FloorpWebExtensionMessageRuntime.frameAuthorizationOperation {
                guard let authorizeFrameScript else {
                    throw FloorpWebExtensionMessageError.unauthorizedDocument
                }
                let request = try envelope.payload.decode(FrameAuthorizationRequest.self)
                guard (1...128).contains(request.scriptID.utf8.count),
                      (1...128).contains(request.revisionToken.utf8.count) else {
                    throw FloorpWebExtensionMessageError.malformedEnvelope
                }
                let authorized = authorizeFrameScript(
                    request.scriptID,
                    request.revisionToken,
                    currentURL,
                    isMainFrame
                )
                guard isExpectedAttachmentCurrent(expectedAttachment) else {
                    throw FloorpWebExtensionMessageError.unauthorizedDocument
                }
                return try Self.successReply(
                    FloorpWebExtensionMessagePayload(FrameAuthorizationResponse(authorized: authorized)),
                    requestID: envelope.requestID
                )
            }
            guard isExpectedAttachmentCurrent(expectedAttachment) else {
                throw FloorpWebExtensionMessageError.unauthorizedDocument
            }
            let sender = makeSender(currentURL, isMainFrame)
            // Authorization callbacks and sender construction are synchronous,
            // but may trigger bridge reconciliation. Recheck the exact receipt
            // attachment immediately before invoking native code.
            guard isRequestAuthorized(
                expectedAttachment: expectedAttachment,
                currentURL: currentURL,
                isMainFrame: isMainFrame
            ) else {
                throw FloorpWebExtensionMessageError.unauthorizedDocument
            }
            let response: FloorpWebExtensionMessagePayload?
            if envelope.operation == "runtime.sendMessage" {
                response = try await dispatchRuntimeMessage(envelope.payload, sender)
            } else if let nativeAPIDispatcher {
                response = try await nativeAPIDispatcher.dispatch(
                    operation: envelope.operation,
                    payload: envelope.payload,
                    sender: sender
                )
            } else {
                throw FloorpWebExtensionMessageError.unsupportedOperation
            }
            guard isRequestAuthorized(
                expectedAttachment: expectedAttachment,
                currentURL: currentURL,
                isMainFrame: isMainFrame
            ) else {
                throw FloorpWebExtensionMessageError.unauthorizedDocument
            }
            return try Self.successReply(response, requestID: envelope.requestID)
        } catch let error as FloorpWebExtensionMessageError {
            if !isRequestAuthorized(
                expectedAttachment: expectedAttachment,
                currentURL: currentURL,
                isMainFrame: isMainFrame
            ) {
                return Self.failureReply(.unauthorizedDocument, requestID: requestID)
            }
            return Self.failureReply(error, requestID: requestID)
        } catch {
            if !isRequestAuthorized(
                expectedAttachment: expectedAttachment,
                currentURL: currentURL,
                isMainFrame: isMainFrame
            ) {
                return Self.failureReply(.unauthorizedDocument, requestID: requestID)
            }
            return Self.failureReply(.handlerFailed, requestID: requestID)
        }
    }

    private func isRequestAuthorized(
        expectedAttachment: AttachmentToken,
        currentURL: URL,
        isMainFrame: Bool
    ) -> Bool {
        isExpectedAttachmentCurrent(expectedAttachment) &&
            authorizeDocument(currentURL, isMainFrame)
    }

    private func isExpectedAttachmentCurrent(_ expectedAttachment: AttachmentToken) -> Bool {
        guard let controller else { return false }
        return attachmentGeneration == expectedAttachment.generation &&
            ObjectIdentifier(controller) == expectedAttachment.controllerIdentifier
    }

    private struct AttachmentToken: Sendable {
        let generation: UInt64
        let controllerIdentifier: ObjectIdentifier
    }

    private struct Envelope {
        let requestID: String
        let operation: String
        let payload: FloorpWebExtensionMessagePayload
    }

    private struct FrameAuthorizationRequest: Decodable {
        let scriptID: String
        let revisionToken: String
    }

    private struct FrameAuthorizationResponse: Encodable {
        let authorized: Bool
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

    // swiftlint:disable:next function_body_length
    private static func bootstrapSource(
        extensionID: FloorpWebExtensionID,
        nonce: String,
        handlerName: String,
        bootstrap: FloorpWebExtensionAPIHost.JavaScriptBootstrap?,
        supportsSameSurfacePageNavigation: Bool
    ) -> String {
        let extensionLiteral = javaScriptLiteral(extensionID.rawValue)
        let nonceLiteral = javaScriptLiteral(nonce)
        let handlerLiteral = javaScriptLiteral(handlerName)
        let sameSurfacePageNavigationLiteral = supportsSameSurfacePageNavigation ? "true" : "false"
        let bootstrapLiteral: String
        if let bootstrap,
           let data = try? JSONEncoder().encode(bootstrap),
           let value = String(data: data, encoding: .utf8) {
            bootstrapLiteral = javaScriptLiteral(value)
        } else {
            bootstrapLiteral = "null"
        }
        return """
        (() => {
          "use strict";
          const nativeHandler = globalThis.webkit?.messageHandlers?.[\(handlerLiteral)];
          if (!nativeHandler || typeof nativeHandler.postMessage !== "function") return;
          const floorpBootstrap = \(bootstrapLiteral) == null ? null : JSON.parse(\(bootstrapLiteral));
          const floorpI18nBootstrap = floorpBootstrap?.i18n ?? null;
          const floorpManifestBootstrap = floorpBootstrap?.manifest ?? null;
          let nextRequest = 0;
          const runtimeOnMessageListeners = [];
          const alarmListeners = [];
          const makeEvent = () => {
            const listeners = [];
            return {
              event: Object.freeze({
                addListener(listener) {
                  if (typeof listener === "function" && !listeners.includes(listener)) {
                    listeners.push(listener);
                  }
                },
                removeListener(listener) {
                  const index = listeners.indexOf(listener);
                  if (index >= 0) listeners.splice(index, 1);
                },
                hasListener(listener) { return listeners.includes(listener); }
              }),
              emit(...args) {
                for (const listener of listeners.slice()) {
                  try { listener(...args); } catch (_) {}
                }
              }
            };
          };
          const runtimeOnInstalled = makeEvent();
          const runtimeOnStartup = makeEvent();
          const tabsOnRemoved = makeEvent();
          const storageOnChanged = makeEvent();
          const serializeResponse = (value) => JSON.stringify(value === undefined ? null : value);
          const backgroundStartupActivity = (() => {
            let pendingNativeRequests = 0;
            let pendingResources = 0;
            let didFinishScripts = false;
            let lastActivity = performance.now();
            const touch = () => { lastActivity = performance.now(); };
            return Object.freeze({
              nativeRequestStarted() {
                pendingNativeRequests += 1;
                touch();
              },
              nativeRequestFinished() {
                pendingNativeRequests = Math.max(0, pendingNativeRequests - 1);
                touch();
              },
              resourceStarted() {
                pendingResources += 1;
                touch();
              },
              resourceFinished() {
                pendingResources = Math.max(0, pendingResources - 1);
                touch();
              },
              scriptsFinished() {
                didFinishScripts = true;
                touch();
              },
              isIdleFor(milliseconds) {
                return didFinishScripts &&
                  pendingNativeRequests === 0 &&
                  pendingResources === 0 &&
                  performance.now() - lastActivity >= milliseconds;
              }
            });
          })();
          Object.defineProperty(globalThis, "__floorpWebExtensionBackgroundStartupActivity", {
            value: backgroundStartupActivity,
            enumerable: false,
            configurable: false,
            writable: false
          });
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
            // Message delivery can re-enter this same lazy background while
            // it is starting. Waiting for that request here would make the
            // inner delivery wait for itself forever. Ordinary initialization
            // APIs (storage, i18n, permissions, and so on) remain tracked.
            const tracksStartupActivity = operation !== "runtime.sendMessage" &&
              operation !== "tabs.sendMessage";
            if (tracksStartupActivity) backgroundStartupActivity.nativeRequestStarted();
            let nativeReply;
            try {
              nativeReply = nativeHandler.postMessage(serialized);
            } catch (error) {
              if (tracksStartupActivity) backgroundStartupActivity.nativeRequestFinished();
              return Promise.reject(error);
            }
            return Promise.resolve(nativeReply).then((rawReply) => {
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
            }).finally(() => {
              if (tracksStartupActivity) backgroundStartupActivity.nativeRequestFinished();
            });
          };
          Object.defineProperty(globalThis, \(javaScriptLiteral(FloorpWebExtensionMessageRuntime.frameAuthorizationFunctionName)), {
            value: async (scriptId, revisionToken) => {
              if (typeof scriptId !== "string" || scriptId.length < 1 || scriptId.length > 128 ||
                  typeof revisionToken !== "string" || revisionToken.length < 1 || revisionToken.length > 128) {
                return false;
              }
              try {
                const result = await request("internal.authorizeFrameScript", {scriptID: scriptId, revisionToken});
                return result?.authorized === true;
              } catch (_) {
                return false;
              }
            },
            enumerable: false,
            configurable: false,
            writable: false
          });
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
            // Chrome treats a synchronous false return as "this listener did
            // not respond". It must not consume the message or become a false
            // response payload; a later listener may still handle it.
            if (result === false) return undefined;
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
          const deliverRuntimeMessage = async (message, sender) => {
            for (const listener of runtimeOnMessageListeners) {
              if (typeof listener !== "function") continue;
              const value = await invokeMessageListener(listener, message, sender);
              if (typeof value !== "undefined") {
                return JSON.stringify({hasResponse: true, value});
              }
            }
            return JSON.stringify({hasResponse: false});
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
          const storageGetRequest = (keys) => {
            if (keys && typeof keys === "object" && !Array.isArray(keys)) {
              return {keys: Object.keys(keys), defaults: keys};
            }
            return {keys: normalizeKeys(keys), defaults: null};
          };
          const storageArea = (area, quotaBytes = 5 * 1024 * 1024, quotaBytesPerItem = quotaBytes) => {
            const areaOnChanged = makeEvent();
            const operation = (name) => `storage.${area}.${name}`;
            const emitChanges = (changes) => {
              if (Object.keys(changes).length === 0) return;
              storageOnChanged.emit(changes, area);
              areaOnChanged.emit(changes, area);
            };
            const changed = (oldValue, newValue) => JSON.stringify(oldValue) !== JSON.stringify(newValue);
            return Object.freeze({
              QUOTA_BYTES: quotaBytes,
              QUOTA_BYTES_PER_ITEM: quotaBytesPerItem,
              get(keys = null) {
                const details = storageGetRequest(keys);
                return request(operation("get"), {keys: details.keys}).then((values) =>
                  details.defaults ? {...details.defaults, ...values} : values
                );
              },
              set(items) {
                if (!items || typeof items !== "object" || Array.isArray(items)) {
                  return Promise.reject(new TypeError("storage.set requires an object"));
                }
                const keys = Object.keys(items);
                return request(operation("get"), {keys}).then((oldValues) =>
                  request(operation("set"), {items}).then(() => {
                    const changes = {};
                    for (const key of keys) {
                      if (changed(oldValues[key], items[key])) {
                        changes[key] = {oldValue: oldValues[key], newValue: items[key]};
                      }
                    }
                    emitChanges(changes);
                  })
                );
              },
              remove(keys) {
                const normalized = normalizeKeys(keys);
                return request(operation("get"), {keys: normalized}).then((oldValues) =>
                  request(operation("remove"), {keys: normalized}).then(() => {
                    const changes = {};
                    for (const key of Object.keys(oldValues)) {
                      changes[key] = {oldValue: oldValues[key]};
                    }
                    emitChanges(changes);
                  })
                );
              },
              clear() {
                return request(operation("get"), {keys: null}).then((oldValues) =>
                  request(operation("clear")).then(() => {
                    const changes = {};
                    for (const key of Object.keys(oldValues)) {
                      changes[key] = {oldValue: oldValues[key]};
                    }
                    emitChanges(changes);
                  })
                );
              },
              getBytesInUse(keys = null) {
                return request(operation("getBytesInUse"), {keys: normalizeKeys(keys)})
                  .then((result) => result.value);
              },
              onChanged: areaOnChanged.event
            });
          };
          const runtime = Object.freeze({
            id: \(extensionLiteral),
            sendMessage(message) { return request("runtime.sendMessage", message); },
            getManifest() {
              return floorpManifestBootstrap ? JSON.parse(JSON.stringify(floorpManifestBootstrap)) : {};
            },
            getURL(path = "") {
              return request("runtime.getURL", {path: String(path)}).then((result) => result.value);
            },
            reload() { return request("runtime.reload"); },
            getPlatformInfo() {
              return Promise.resolve(Object.freeze({os: "ios", arch: "arm", nacl_arch: ""}));
            },
            setUninstallURL(url) {
              if (typeof url !== "string") {
                return Promise.reject(new TypeError("runtime.setUninstallURL requires a string"));
              }
              // iOS has no browser-owned uninstall landing-page flow.
              return Promise.resolve(undefined);
            },
            onInstalled: runtimeOnInstalled.event,
            onStartup: runtimeOnStartup.event,
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
              return request("scripting.insertCSS", details).then(() => undefined);
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
          // iOS presents popup/options resources inside one authenticated,
          // package-owned WKWebView.  Some desktop extensions discover or
          // create another window before opening Settings.  On that page
          // surface only, translate a same-origin package URL into a
          // same-WebView navigation.  Tab content and hidden backgrounds never
          // receive this compatibility capability.
          const supportsSameSurfacePageNavigation = \(sameSurfacePageNavigationLiteral);
          const sameSurfacePageNavigationTarget = (value) => {
            if (!supportsSameSurfacePageNavigation || typeof value !== "string") return null;
            let current;
            let target;
            try {
              current = new URL(globalThis.location.href);
              target = new URL(value, current);
            } catch (_) {
              return null;
            }
            if (current.protocol !== "floorp-extension:" ||
                target.protocol !== current.protocol ||
                target.host !== current.host ||
                current.username || current.password || current.port ||
                target.username || target.password || target.port ||
                target.search) {
              return null;
            }
            return target;
          };
          const navigateSameSurfacePage = (value) => {
            const target = sameSurfacePageNavigationTarget(value);
            if (!target) return null;
            globalThis.location.assign(target.href);
            return Object.freeze({active: true, url: target.href});
          };
          const tabs = Object.freeze({
            query(queryInfo = {}) { return request("tabs.query", {queryInfo}); },
            get(tabId) { return request("tabs.get", {tabId}); },
            create(createProperties = {}) {
              const navigatedTab = navigateSameSurfacePage(createProperties?.url);
              return navigatedTab
                ? Promise.resolve(navigatedTab)
                : request("tabs.create", {createProperties});
            },
            update(tabId, updateProperties = {}) { return request("tabs.update", {tabId, updateProperties}); },
            reload(tabId, reloadProperties = {}) { return request("tabs.reload", {tabId, reloadProperties}); },
            sendMessage(tabId, message, options = {}) {
              return request("tabs.sendMessage", {tabId, message, options});
            },
            onRemoved: tabsOnRemoved.event
          });
          const windows = supportsSameSurfacePageNavigation ? Object.freeze({
            getAll() {
              // There are no separately addressable extension popup windows
              // in this page surface.  Returning an empty list makes the
              // extension take its create path without inventing tab IDs.
              return Promise.resolve([]);
            },
            create(createData = {}) {
              const navigatedTab = navigateSameSurfacePage(createData?.url);
              if (!navigatedTab) {
                return Promise.reject(new Error("windows.create only supports a same-origin package page"));
              }
              return Promise.resolve(Object.freeze({
                focused: true,
                type: createData?.type || "popup",
                tabs: Object.freeze([navigatedTab])
              }));
            }
          }) : null;
          const storage = Object.freeze({
            local: storageArea("local"),
            sync: storageArea("sync", 5 * 1024 * 1024, 8 * 1024),
            session: storageArea("session"),
            onChanged: storageOnChanged.event
          });
          const asynchronousI18n = Object.freeze({
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
          const i18n = floorpI18nBootstrap ? (() => {
            const messageLimit = 256 * 1024;
            const language = String(floorpI18nBootstrap.uiLanguage || "en")
              .split(/[-_]/, 1)[0]
              .toLowerCase();
            const rightToLeft = ["ar", "ckb", "dv", "fa", "he", "ku", "ps", "ur", "yi"].includes(language);
            const normalizeSubstitutions = (substitutions) => {
              const values = typeof substitutions === "string" ? [substitutions] : substitutions;
              return Array.isArray(values) && values.every((value) => typeof value === "string")
                ? values
                : null;
            };
            const specialMessage = (name) => {
              switch (name.toLowerCase()) {
                case "@@extension_id": return floorpI18nBootstrap.extensionID;
                case "@@ui_locale": return String(floorpI18nBootstrap.uiLanguage || "en").replace(/-/g, "_");
                case "@@bidi_dir": return rightToLeft ? "rtl" : "ltr";
                case "@@bidi_reversed_dir": return rightToLeft ? "ltr" : "rtl";
                case "@@bidi_start_edge": return rightToLeft ? "right" : "left";
                case "@@bidi_end_edge": return rightToLeft ? "left" : "right";
                default: return null;
              }
            };
            const interpolate = (template, values, placeholders, allowNamedPlaceholders) => {
              let output = "";
              for (let index = 0; index < template.length;) {
                if (template[index] !== "$") {
                  output += template[index++];
                } else if (index + 1 >= template.length) {
                  output += "$";
                  index += 1;
                } else if (template[index + 1] === "$") {
                  output += "$";
                  index += 2;
                } else if (template[index + 1] >= "0" && template[index + 1] <= "9") {
                  let end = index + 1;
                  while (end < template.length && template[end] >= "0" && template[end] <= "9") end += 1;
                  const position = Number(template.slice(index + 1, end));
                  output += position > 0 && position <= values.length ? values[position - 1] : "";
                  index = end;
                } else {
                  const end = template.indexOf("$", index + 1);
                  if (end < 0) {
                    output += "$";
                    index += 1;
                  } else {
                    const name = template.slice(index + 1, end).toLowerCase();
                    const placeholder = allowNamedPlaceholders ? placeholders?.[name] : null;
                    if (typeof placeholder === "string") {
                      output += interpolate(placeholder, values, {}, false);
                      index = end + 1;
                    } else {
                      output += "$";
                      index += 1;
                    }
                  }
                }
                if (output.length > messageLimit) return "";
              }
              return output;
            };
            return Object.freeze({
              getMessage(name, substitutions = []) {
                if (typeof name !== "string") return "";
                const values = normalizeSubstitutions(substitutions);
                if (!values) return "";
                const special = specialMessage(name);
                if (special != null) return special;
                const entry = floorpI18nBootstrap.messages?.[name.toLowerCase()];
                return entry && typeof entry.message === "string"
                  ? interpolate(entry.message, values, entry.placeholders || {}, true)
                  : "";
              },
              getUILanguage() { return String(floorpI18nBootstrap.uiLanguage || "en"); },
              getAcceptLanguages() {
                return Promise.resolve(Array.isArray(floorpI18nBootstrap.acceptLanguages)
                  ? floorpI18nBootstrap.acceptLanguages.slice()
                  : []);
              }
            });
          })() : asynchronousI18n;
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
            setIcon(details) { return request("action.setIcon", details || {}); },
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
          Object.defineProperty(globalThis, "__floorpWebExtensionDeliverPageRuntimeMessage", {
            value: deliverRuntimeMessage,
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
          const browserNamespaces = {
            runtime,
            permissions,
            scripting,
            declarativeNetRequest,
            storage,
            i18n,
            alarms,
            action,
            browserAction: action,
            tabs
          };
          if (windows) browserNamespaces.windows = windows;
          for (const [name, value] of Object.entries(browserNamespaces)) {
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
          const chromeI18n = floorpI18nBootstrap ? Object.freeze({
            // Chrome defines these as synchronous. Keep callback spellings
            // without converting a no-callback result into a Promise.
            getMessage: i18n.getMessage,
            getUILanguage(callback) {
              const language = i18n.getUILanguage();
              if (typeof callback === "function") {
                callback(language);
                return undefined;
              }
              return language;
            },
            getAcceptLanguages: callbackMethod(i18n.getAcceptLanguages)
          }) : callbackNamespace(i18n);
          const chromeExtension = Object.freeze({
            // iOS has no file:// extension permission. This legacy feature
            // check never grants filesystem access.
            isAllowedFileSchemeAccess(callback) {
              if (typeof callback === "function") {
                callback(false);
                return undefined;
              }
              return Promise.resolve(false);
            }
          });
          const packageRuntimeBaseURL = new URL("/", globalThis.location.href);
          const packageRuntimeURL = (path = "") => {
            if (globalThis.location?.protocol !== "floorp-extension:") {
              throw new Error("runtime.getURL is unavailable outside a package origin");
            }
            const normalized = String(path).replace(/^\\/+/, "");
            const value = new URL(normalized, packageRuntimeBaseURL);
            if (value.protocol !== packageRuntimeBaseURL.protocol ||
                value.host !== packageRuntimeBaseURL.host ||
                value.username || value.password) {
              throw new Error("runtime.getURL rejected a cross-origin path");
            }
            return value.href;
          };
          const chromeRuntime = callbackNamespace(runtime, ["id", "getManifest", "getURL", "onMessage"]);
          Object.defineProperties(chromeRuntime, {
            id: {value: \(extensionLiteral), enumerable: true},
            getManifest: {value: runtime.getManifest, enumerable: true},
            getURL: {value: packageRuntimeURL, enumerable: true},
            onMessage: {value: runtime.onMessage, enumerable: true},
            lastError: {get: () => chromeLastError, enumerable: true}
          });
          const chromeObject = globalThis.chrome && typeof globalThis.chrome === "object"
            ? globalThis.chrome
            : {};
          const chromeNamespaces = {
            runtime: chromeRuntime,
            permissions: callbackNamespace(permissions),
            scripting: callbackNamespace(scripting),
            declarativeNetRequest: callbackNamespace(declarativeNetRequest),
            storage: Object.freeze({
              local: callbackNamespace(storage.local),
              sync: callbackNamespace(storage.sync),
              onChanged: storage.onChanged,
              session: callbackNamespace(storage.session)
            }),
            i18n: chromeI18n,
            alarms: callbackNamespace(alarms, ["onAlarm"]),
            action: callbackNamespace(action),
            browserAction: callbackNamespace(action),
            tabs: callbackNamespace(tabs),
            extension: chromeExtension
          };
          if (windows) chromeNamespaces.windows = callbackNamespace(windows);
          for (const [name, value] of Object.entries(chromeNamespaces)) {
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
