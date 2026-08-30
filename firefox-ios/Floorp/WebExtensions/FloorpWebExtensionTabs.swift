// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import WebKit

/// A host-owned tab snapshot. The adapter is the sole authority for tab IDs,
/// active selection, and navigation; this value deliberately has no WebKit or
/// Firefox UI dependency so the API service can be tested independently.
struct FloorpWebExtensionHostTab: Equatable, Sendable {
    let context: FloorpWebExtensionTabContext
    let title: String?
    let isActive: Bool

    init(
        context: FloorpWebExtensionTabContext,
        title: String? = nil,
        isActive: Bool
    ) {
        self.context = context
        self.title = title
        self.isActive = isActive
    }
}

/// The permission-filtered representation exposed by the generic `tabs` API.
///
/// `url` and `title` are absent unless the extension has the `tabs` grant or
/// currently has host access to the particular document. This makes callers
/// unable to use `query` as a cross-site browsing-history API.
struct FloorpWebExtensionTab: Codable, Equatable, Sendable {
    let id: Int
    let active: Bool
    let isPrivate: Bool
    let url: URL?
    let title: String?
}

enum FloorpWebExtensionTabsQuery: Sendable {
    /// All tabs in this profile. Sensitive fields remain redacted per tab
    /// unless the extension has the `tabs` grant or matching host access.
    case all
    /// The selected tab in this iOS profile. iOS has no extension-visible
    /// desktop window collection, so "current" is this profile's active tab.
    case current
    case active
}

enum FloorpWebExtensionTabsError: Error, Equatable, LocalizedError, Sendable {
    case invalidProfileIdentifier
    case hostProfileMismatch
    case hostUnavailable
    case hostTabInvariantViolation
    case tabNotFound(Int)
    case privateBrowsingDenied
    case invalidNavigationURL
    case unsafeNavigationScheme
    case messageDeliveryFailed

    var errorDescription: String? {
        switch self {
        case .invalidProfileIdentifier:
            return "The WebExtensions tabs profile identifier is invalid."
        case .hostProfileMismatch:
            return "The tabs host does not belong to this extension profile."
        case .hostUnavailable:
            return "No live browser tab host is available for the requested tabs operation."
        case .hostTabInvariantViolation:
            return "The tabs host returned a tab outside its profile boundary."
        case .tabNotFound(let id):
            return "The requested tab does not exist: \(id)."
        case .privateBrowsingDenied:
            return "The extension does not have permission to access private tabs."
        case .invalidNavigationURL:
            return "The requested tab URL is invalid."
        case .unsafeNavigationScheme:
            return "The requested tab URL scheme is not supported."
        case .messageDeliveryFailed:
            return "The tab could not receive the extension message."
        }
    }
}

/// A production tabs host backed by the app's real `WindowManager` and tab
/// manager instances.
///
/// The adapter stays profile-scoped and browsing-mode-scoped; every call is
/// filtered through the active profile windows and the extension's permission
/// snapshot. sendMessage uses the isolated extension content world attached by
/// the message runtime, so it can only reach a document that already carries
/// the authenticated WebExtensions bridge.
@MainActor
final class FloorpWebExtensionProfileTabsHost: FloorpWebExtensionTabsHostAdapting {
    typealias JavaScriptEvaluator = @MainActor (
        WKWebView,
        String,
        WKContentWorld
    ) async throws -> Any?

    let profileIdentifier: String
    let isPrivateBrowsing: Bool

    private weak var windowManager: WindowManager?
    private let evaluateJavaScript: JavaScriptEvaluator

    init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        windowManager: WindowManager,
        javaScriptEvaluator: JavaScriptEvaluator? = nil
    ) {
        self.profileIdentifier = profileIdentifier
        self.isPrivateBrowsing = isPrivateBrowsing
        self.windowManager = windowManager
        evaluateJavaScript = javaScriptEvaluator ?? Self.defaultJavaScriptEvaluator
    }

    func tabsSnapshot() -> [FloorpWebExtensionHostTab] {
        liveTabs().map { makeSnapshot(from: $0) }
    }

    func createTab(url: URL, makeActive: Bool) throws -> FloorpWebExtensionHostTab {
        let tabManager = try activeTabManager()
        let tab = tabManager.addTab(URLRequest(url: url), zombie: false, isPrivate: isPrivateBrowsing)
        guard tab.profile.localName() == profileIdentifier else {
            throw FloorpWebExtensionTabsError.hostProfileMismatch
        }
        if makeActive {
            tabManager.selectTab(tab)
        }
        return makeSnapshot(from: tab)
    }

    func updateTab(id: Int, url: URL) throws -> FloorpWebExtensionHostTab {
        let tab = try liveTab(for: id)
        guard tab.isPrivate == isPrivateBrowsing else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }
        tab.loadRequest(URLRequest(url: url))
        return makeSnapshot(from: tab)
    }

    func reloadTab(id: Int) throws -> FloorpWebExtensionHostTab {
        let tab = try liveTab(for: id)
        guard tab.isPrivate == isPrivateBrowsing else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }
        tab.reload()
        return makeSnapshot(from: tab)
    }

    func deliverMessage(
        _ message: FloorpWebExtensionJSONValue,
        sender: any FloorpWebExtensionMessageSender,
        to tab: FloorpWebExtensionTabContext
    ) async throws -> FloorpWebExtensionJSONValue? {
        let liveTab = try liveTab(for: tab.tabID)
        guard let activeDocument = liveTab.floorpWebExtensionActiveDocumentContext,
              activeDocument.documentGeneration == tab.documentGeneration,
              activeDocument.url == tab.url,
              activeDocument.isPrivate == tab.isPrivate else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }

        guard let webView = liveTab.webView else {
            throw FloorpWebExtensionTabsError.hostUnavailable
        }

        let messageJSON = try jsonLiteral(message)
        let senderPayload = try FloorpWebExtensionTabMessageSenderPayload(sender: sender)
        let senderJSON = try jsonLiteral(senderPayload)
        let script = "return await globalThis.__floorpWebExtensionDeliverTabsMessage(\(messageJSON), \(senderJSON))"
        let contentWorld = WKContentWorld.world(
            name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: sender.extensionID)
        )

        do {
            let rawReply = try await evaluateJavaScript(webView, script, contentWorld)
            if rawReply is NSNull {
                return nil
            }
            let data: Data
            if let string = rawReply as? String {
                data = Data(string.utf8)
            } else if let rawReply {
                data = try JSONSerialization.data(withJSONObject: rawReply, options: .fragmentsAllowed)
            } else {
                return nil
            }
            return try JSONDecoder().decode(FloorpWebExtensionJSONValue.self, from: data)
        } catch {
            throw FloorpWebExtensionTabsError.messageDeliveryFailed
        }
    }

    /// Resolves a live main-frame document for the native `scripting` API.
    /// This stays behind the profile-owned tab adapter so extension JavaScript
    /// can never supply a `WKWebView` or forge a document context.
    func liveScriptingTarget(tabID: Int) throws -> FloorpWebExtensionLiveScriptingTarget {
        let tab = try liveTab(for: tabID)
        guard tab.isPrivate == isPrivateBrowsing,
              tab.profile.localName() == profileIdentifier,
              let document = tab.floorpWebExtensionActiveDocumentContext,
              let webView = tab.webView else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }
        return .init(tab: document, webView: webView)
    }

    private func activeTabManager() throws -> TabManager {
        guard let manager = windowManager?.allWindowTabManagers().first(where: { tabManager in
            (
                tabManager.selectedTab?.isPrivate == isPrivateBrowsing &&
                tabManager.selectedTab?.profile.localName() == profileIdentifier
            ) ||
                tabManager.tabs.contains(where: {
                    $0.isPrivate == isPrivateBrowsing && $0.profile.localName() == profileIdentifier
                })
        }) else {
            throw FloorpWebExtensionTabsError.hostUnavailable
        }
        return manager
    }

    private func liveTabs() -> [Tab] {
        windowManager?.allWindowTabManagers().flatMap { manager in
            manager.tabs.filter {
                $0.isPrivate == isPrivateBrowsing && $0.profile.localName() == profileIdentifier
            }
        } ?? []
    }

    private func liveTab(for tabID: Int) throws -> Tab {
        guard let tab = liveTabs().first(where: { $0.floorpWebExtensionTabID == tabID }) else {
            throw FloorpWebExtensionTabsError.tabNotFound(tabID)
        }
        return tab
    }

    private func makeSnapshot(from tab: Tab) -> FloorpWebExtensionHostTab {
        guard tab.profile.localName() == profileIdentifier else {
            preconditionFailure("Tabs host snapshot escaped its profile boundary")
        }
        return FloorpWebExtensionHostTab(
            context: tab.floorpWebExtensionActiveDocumentContext ?? .init(
                tabID: tab.floorpWebExtensionTabID,
                documentGeneration: 0,
                url: tab.webView?.url ?? tab.url ?? URL(string: "about:blank")!,
                isPrivate: tab.isPrivate
            ),
            title: tab.title,
            isActive: tabManagerSelectedTab(for: tab)
        )
    }

    private func tabManagerSelectedTab(for tab: Tab) -> Bool {
        windowManager?.allWindowTabManagers().contains(where: { manager in
            manager.selectedTab === tab
        }) ?? false
    }

    private static func defaultJavaScriptEvaluator(
        webView: WKWebView,
        script: String,
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, contentWorld: contentWorld)
    }

    private struct FloorpWebExtensionTabMessageSenderPayload: Encodable {
        struct TabPayload: Encodable {
            let id: Int
            let url: String
            let isPrivate: Bool
        }

        struct PagePayload: Encodable {
            let originHost: String
            let surface: String
        }

        let extensionId: String
        let tabId: Int?
        let documentGeneration: UInt64?
        let url: String?
        let isPrivate: Bool
        let isMainFrame: Bool?
        let tab: TabPayload?
        let page: PagePayload?

        init(sender: any FloorpWebExtensionMessageSender) throws {
            extensionId = sender.extensionID.rawValue
            isPrivate = sender.isPrivate
            if let tabSender = sender as? FloorpWebExtensionRuntimeMessageSender {
                tabId = tabSender.tabID
                documentGeneration = tabSender.documentGeneration
                url = tabSender.url.absoluteString
                isMainFrame = tabSender.isMainFrame
                tab = .init(
                    id: tabSender.tabID,
                    url: tabSender.url.absoluteString,
                    isPrivate: tabSender.isPrivate
                )
                page = nil
            } else if let pageSender = sender as? FloorpWebExtensionPageRuntimeMessageSender {
                tabId = nil
                documentGeneration = nil
                guard let transportURL = pageSender.transportURL,
                      FloorpWebExtensionPageNavigationPolicy(
                          originHost: pageSender.originHost
                      ).isPackageURL(transportURL),
                      FloorpWebExtensionPageSchemeHandler.packagePath(from: transportURL) != nil,
                      transportURL.query == nil else {
                    throw FloorpWebExtensionMessageError.malformedEnvelope
                }
                url = transportURL.absoluteString
                isMainFrame = true
                tab = nil
                switch pageSender.surface {
                case .actionPopup:
                    page = .init(originHost: pageSender.originHost, surface: "actionPopup")
                case .options:
                    page = .init(originHost: pageSender.originHost, surface: "options")
                }
            } else if let backgroundSender = sender as? FloorpWebExtensionBackgroundRuntimeMessageSender {
                tabId = nil
                documentGeneration = nil
                url = "\(FloorpWebExtensionPageNavigationPolicy.resourceScheme)://\(backgroundSender.originHost)/"
                isMainFrame = nil
                tab = nil
                page = nil
            } else {
                tabId = nil
                documentGeneration = nil
                url = nil
                isMainFrame = nil
                tab = nil
                page = nil
            }
        }
    }

    private func jsonLiteral<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw FloorpWebExtensionTabsError.messageDeliveryFailed
        }
        return json
    }
}

/// An application-side adapter for one normal or private browser profile.
///
/// Firefox's tab manager implements this protocol. It is intentionally not a
/// JavaScript bridge: the bridge validates an API request, then asks this
/// service to perform the same native, profile-scoped operation.
@MainActor
protocol FloorpWebExtensionTabsHostAdapting: AnyObject {
    var profileIdentifier: String { get }
    var isPrivateBrowsing: Bool { get }

    func tabsSnapshot() -> [FloorpWebExtensionHostTab]
    func createTab(url: URL, makeActive: Bool) throws -> FloorpWebExtensionHostTab
    func updateTab(id: Int, url: URL) throws -> FloorpWebExtensionHostTab
    func reloadTab(id: Int) throws -> FloorpWebExtensionHostTab
    func deliverMessage(
        _ message: FloorpWebExtensionJSONValue,
        sender: any FloorpWebExtensionMessageSender,
        to tab: FloorpWebExtensionTabContext
    ) async throws -> FloorpWebExtensionJSONValue?
}

/// Profile-bound implementation of the Stage 2 `tabs` subset.
///
/// Every call reads permission state from `permissionBroker`; cached UI state
/// is never authorization. The host adapter owns all actual tab mutations and
/// validates its returned snapshots after each mutation, closing both profile
/// and private-mode escape paths at this API boundary.
@MainActor
final class FloorpWebExtensionTabsService {
    private static let maximumJavaScriptSafeInteger = 9_007_199_254_740_991

    private let profileIdentifier: String
    private let isPrivateBrowsing: Bool
    private let host: any FloorpWebExtensionTabsHostAdapting
    private let permissionBroker: FloorpWebExtensionPermissionBroker

    init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        host: any FloorpWebExtensionTabsHostAdapting,
        permissionBroker: FloorpWebExtensionPermissionBroker
    ) throws {
        let normalizedProfile = profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProfile.isEmpty, normalizedProfile.utf8.count <= 256 else {
            throw FloorpWebExtensionTabsError.invalidProfileIdentifier
        }
        guard host.profileIdentifier == normalizedProfile,
              host.isPrivateBrowsing == isPrivateBrowsing else {
            throw FloorpWebExtensionTabsError.hostProfileMismatch
        }
        self.profileIdentifier = normalizedProfile
        self.isPrivateBrowsing = isPrivateBrowsing
        self.host = host
        self.permissionBroker = permissionBroker
    }

    func query(
        _ query: FloorpWebExtensionTabsQuery,
        for extensionID: FloorpWebExtensionID
    ) async throws -> [FloorpWebExtensionTab] {
        let tabs = try snapshots()
        switch query {
        case .all:
            var result = [FloorpWebExtensionTab]()
            for tab in tabs {
                result.append(await publicTab(from: tab, extensionID: extensionID))
            }
            return result.sorted { lhs, rhs in lhs.id < rhs.id }
        case .current, .active:
            var result = [FloorpWebExtensionTab]()
            for tab in tabs where tab.isActive {
                result.append(await publicTab(from: tab, extensionID: extensionID))
            }
            return result.sorted { lhs, rhs in lhs.id < rhs.id }
        }
    }

    func get(
        _ tabID: Int,
        for extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionTab {
        let tab = try tab(withID: tabID)
        return await publicTab(from: tab, extensionID: extensionID)
    }

    func create(
        url: URL,
        active: Bool = true,
        for extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionTab {
        try await requireTabsControl(for: extensionID)
        try validateNavigationURL(url)
        let created = try validate(host.createTab(url: url, makeActive: active))
        try requireCurrentHostTab(created)
        return await publicTab(
            from: created,
            extensionID: extensionID
        )
    }

    func update(
        _ tabID: Int,
        url: URL,
        for extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionTab {
        try await requireTabsControl(for: extensionID)
        _ = try tab(withID: tabID)
        try validateNavigationURL(url)
        let updated = try validate(host.updateTab(id: tabID, url: url))
        guard updated.context.tabID == tabID else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }
        try requireCurrentHostTab(updated)
        return await publicTab(
            from: updated,
            extensionID: extensionID
        )
    }

    func reload(
        _ tabID: Int,
        for extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionTab {
        try await requireTabsControl(for: extensionID)
        _ = try tab(withID: tabID)
        let reloaded = try validate(host.reloadTab(id: tabID))
        guard reloaded.context.tabID == tabID else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }
        try requireCurrentHostTab(reloaded)
        return await publicTab(
            from: reloaded,
            extensionID: extensionID
        )
    }

    /// Routes a message only to the host's currently trusted document. The
    /// adapter must reject a stale document generation rather than retargeting
    /// the message after navigation.
    func sendMessage(
        _ message: FloorpWebExtensionJSONValue,
        to tabID: Int,
        for extensionID: FloorpWebExtensionID,
        sender: any FloorpWebExtensionMessageSender,
        frameID: Int? = nil,
        documentID: String? = nil
    ) async throws -> FloorpWebExtensionJSONValue? {
        guard sender.extensionID == extensionID,
              sender.isPrivate == isPrivateBrowsing else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        let tab = try tab(withID: tabID)
        let currentDocumentID = FloorpWebExtensionDocumentIdentity.mainFrameID(for: tab.context)
        guard frameID == nil || frameID == 0,
              documentID == nil || documentID == currentDocumentID else {
            throw FloorpWebExtensionTabsError.messageDeliveryFailed
        }
        try await requireContentAccess(to: tab.context, for: extensionID)
        do {
            return try await host.deliverMessage(message, sender: sender, to: tab.context)
        } catch let error as FloorpWebExtensionTabsError {
            throw error
        } catch {
            throw FloorpWebExtensionTabsError.messageDeliveryFailed
        }
    }

    private func snapshots() throws -> [FloorpWebExtensionHostTab] {
        let tabs = try host.tabsSnapshot().map(validate)
        guard Set(tabs.map(\.context.tabID)).count == tabs.count else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }
        return tabs
    }

    private func tab(withID tabID: Int) throws -> FloorpWebExtensionHostTab {
        guard let tab = try snapshots().first(where: { $0.context.tabID == tabID }) else {
            throw FloorpWebExtensionTabsError.tabNotFound(tabID)
        }
        return tab
    }

    private func validate(_ tab: FloorpWebExtensionHostTab) throws -> FloorpWebExtensionHostTab {
        guard tab.context.isPrivate == isPrivateBrowsing,
              tab.context.tabID > 0,
              tab.context.tabID <= Self.maximumJavaScriptSafeInteger else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }
        return tab
    }

    private func requireCurrentHostTab(_ returnedTab: FloorpWebExtensionHostTab) throws {
        guard try snapshots().contains(where: { $0.context == returnedTab.context }) else {
            throw FloorpWebExtensionTabsError.hostTabInvariantViolation
        }
    }

    private func publicTab(
        from tab: FloorpWebExtensionHostTab,
        extensionID: FloorpWebExtensionID
    ) async -> FloorpWebExtensionTab {
        let snapshot = await permissionBroker.snapshot(for: extensionID)
        let hasTabsGrant = snapshot.apiPermissions.contains(.tabs) &&
            (!tab.context.isPrivate || snapshot.privateBrowsingEnabled)
        let hasHostAccess = await permissionBroker.allowsHostAccess(
            for: extensionID,
            in: tab.context
        )
        let mayReadSensitiveFields = hasTabsGrant || hasHostAccess
        return FloorpWebExtensionTab(
            id: tab.context.tabID,
            active: tab.isActive,
            isPrivate: tab.context.isPrivate,
            url: mayReadSensitiveFields ? tab.context.url : nil,
            title: mayReadSensitiveFields ? tab.title : nil
        )
    }

    private func requireTabsControl(for extensionID: FloorpWebExtensionID) async throws {
        let snapshot = await permissionBroker.snapshot(for: extensionID)
        guard snapshot.apiPermissions.contains(.tabs) else {
            throw FloorpWebExtensionError.permissionDenied(FloorpWebExtensionAPIGrant.tabs.rawValue)
        }
        guard !isPrivateBrowsing || snapshot.privateBrowsingEnabled else {
            throw FloorpWebExtensionTabsError.privateBrowsingDenied
        }
    }

    private func requireContentAccess(
        to tab: FloorpWebExtensionTabContext,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        guard await permissionBroker.allowsHostAccess(for: extensionID, in: tab) else {
            throw FloorpWebExtensionError.permissionDenied("host_access")
        }
    }

    private func validateNavigationURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw FloorpWebExtensionTabsError.unsafeNavigationScheme
        }
        guard !url.absoluteString.isEmpty, url.host != nil else {
            throw FloorpWebExtensionTabsError.invalidNavigationURL
        }
    }
}
