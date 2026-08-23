// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

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
struct FloorpWebExtensionTab: Equatable, Sendable {
    let id: Int
    let active: Bool
    let isPrivate: Bool
    let url: URL?
    let title: String?
}

enum FloorpWebExtensionTabsQuery: Sendable {
    /// The selected tab in this iOS profile. iOS has no extension-visible
    /// desktop window collection, so "current" is this profile's active tab.
    case current
    case active
}

struct FloorpWebExtensionTabMessageSender: Equatable, Sendable {
    let extensionID: FloorpWebExtensionID
    let tabID: Int
    let documentGeneration: UInt64
    let url: URL
    let isPrivate: Bool
}

enum FloorpWebExtensionTabsError: Error, Equatable, LocalizedError, Sendable {
    case invalidProfileIdentifier
    case hostProfileMismatch
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
        sender: FloorpWebExtensionTabMessageSender,
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
        case .current, .active:
            guard let active = tabs.first(where: \.isActive) else { return [] }
            return [await publicTab(from: active, extensionID: extensionID)]
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
        for extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionJSONValue? {
        let tab = try tab(withID: tabID)
        try await requireContentAccess(to: tab.context, for: extensionID)
        let sender = FloorpWebExtensionTabMessageSender(
            extensionID: extensionID,
            tabID: tab.context.tabID,
            documentGeneration: tab.context.documentGeneration,
            url: tab.context.url,
            isPrivate: tab.context.isPrivate
        )
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
        guard Set(tabs.map(\.context.tabID)).count == tabs.count,
              tabs.filter(\.isActive).count <= 1 else {
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
              tab.context.tabID >= 0 else {
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
        guard !url.absoluteString.isEmpty, url.host != nil else {
            throw FloorpWebExtensionTabsError.invalidNavigationURL
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw FloorpWebExtensionTabsError.unsafeNavigationScheme
        }
    }
}
