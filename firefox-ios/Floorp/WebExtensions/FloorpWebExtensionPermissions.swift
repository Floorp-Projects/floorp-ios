// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

enum FloorpWebExtensionAPIGrant: String, CaseIterable, Codable, Hashable, Sendable {
    case activeTab
    case alarms
    case declarativeNetRequest
    /// Declared MV3 packages may use a generic-font fallback. Floorp does not
    /// expose native iOS font preferences to extension JavaScript.
    case fontSettings
    case scripting
    case storage
    case tabs
}

enum FloorpWebExtensionHostAccess: Codable, Equatable, Hashable, Sendable {
    case denied
    case selectedSites(Set<FloorpWebExtensionMatchPattern>)
    case allRequestedSites

    fileprivate func allows(_ url: URL, requested: Set<FloorpWebExtensionMatchPattern>) -> Bool {
        switch self {
        case .denied:
            return false
        case .selectedSites(let patterns):
            return patterns.contains { $0.matches(url) }
        case .allRequestedSites:
            return requested.contains { $0.matches(url) }
        }
    }
}

struct FloorpWebExtensionPermissionSnapshot: Codable, Equatable, Sendable {
    let apiPermissions: Set<FloorpWebExtensionAPIGrant>
    let requestedHosts: Set<FloorpWebExtensionMatchPattern>
    let normalHostAccess: FloorpWebExtensionHostAccess
    let privateHostAccess: FloorpWebExtensionHostAccess
    let privateBrowsingEnabled: Bool

    init(
        apiPermissions: Set<FloorpWebExtensionAPIGrant> = [],
        requestedHosts: Set<FloorpWebExtensionMatchPattern> = [],
        normalHostAccess: FloorpWebExtensionHostAccess = .denied,
        privateHostAccess: FloorpWebExtensionHostAccess = .denied,
        privateBrowsingEnabled: Bool = false
    ) {
        self.apiPermissions = apiPermissions
        self.requestedHosts = requestedHosts
        self.normalHostAccess = normalHostAccess
        self.privateHostAccess = privateHostAccess
        self.privateBrowsingEnabled = privateBrowsingEnabled
    }
}

struct FloorpWebExtensionPermissionChange: Equatable, Sendable {
    let extensionID: FloorpWebExtensionID
    let previous: FloorpWebExtensionPermissionSnapshot
    let current: FloorpWebExtensionPermissionSnapshot
}

actor FloorpWebExtensionPermissionBroker {
    private struct ActiveTabGrant: Sendable {
        let tabID: Int
        let documentGeneration: UInt64
        let expiration: Date

        func allows(_ tab: FloorpWebExtensionTabContext, now: Date) -> Bool {
            tab.tabID == tabID && tab.documentGeneration == documentGeneration && now < expiration
        }
    }

    private var snapshots = [FloorpWebExtensionID: FloorpWebExtensionPermissionSnapshot]()
    private var activeTabGrants = [FloorpWebExtensionID: ActiveTabGrant]()
    private var observers = [UUID: @Sendable (FloorpWebExtensionPermissionChange) -> Void]()
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func snapshot(for extensionID: FloorpWebExtensionID) -> FloorpWebExtensionPermissionSnapshot {
        snapshots[extensionID] ?? FloorpWebExtensionPermissionSnapshot()
    }

    func grant(
        _ permissions: Set<FloorpWebExtensionAPIGrant>,
        requestedHosts: Set<FloorpWebExtensionMatchPattern>,
        hostAccess: FloorpWebExtensionHostAccess,
        privateHostAccess: FloorpWebExtensionHostAccess = .denied,
        privateBrowsingEnabled: Bool = false,
        to extensionID: FloorpWebExtensionID
    ) {
        let previous = snapshot(for: extensionID)
        let current = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: permissions,
            requestedHosts: requestedHosts,
            normalHostAccess: hostAccess,
            privateHostAccess: privateHostAccess,
            privateBrowsingEnabled: privateBrowsingEnabled
        )
        snapshots[extensionID] = current
        activeTabGrants.removeValue(forKey: extensionID)
        notify(extensionID, previous: previous, current: current)
    }

    func updateSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        privateAccess: Bool,
        for extensionID: FloorpWebExtensionID
    ) {
        let previous = snapshot(for: extensionID)
        let current = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: previous.apiPermissions,
            requestedHosts: previous.requestedHosts,
            normalHostAccess: privateAccess ? previous.normalHostAccess : access,
            privateHostAccess: privateAccess ? access : previous.privateHostAccess,
            privateBrowsingEnabled: previous.privateBrowsingEnabled
        )
        snapshots[extensionID] = current
        notify(extensionID, previous: previous, current: current)
    }

    func grantActiveTab(
        to extensionID: FloorpWebExtensionID,
        for tab: FloorpWebExtensionTabContext,
        duration: TimeInterval = 300
    ) throws {
        let permissions = snapshot(for: extensionID).apiPermissions
        guard permissions.contains(.activeTab) else {
            throw FloorpWebExtensionError.permissionDenied(FloorpWebExtensionAPIGrant.activeTab.rawValue)
        }
        activeTabGrants[extensionID] = ActiveTabGrant(
            tabID: tab.tabID,
            documentGeneration: tab.documentGeneration,
            expiration: now().addingTimeInterval(duration)
        )
    }

    func allows(
        _ permission: FloorpWebExtensionAPIGrant,
        extensionID: FloorpWebExtensionID
    ) -> Bool {
        snapshot(for: extensionID).apiPermissions.contains(permission)
    }

    func allowsHostAccess(
        for extensionID: FloorpWebExtensionID,
        in tab: FloorpWebExtensionTabContext
    ) -> Bool {
        let snapshot = snapshot(for: extensionID)
        if tab.isPrivate && !snapshot.privateBrowsingEnabled {
            return false
        }
        let access = tab.isPrivate ? snapshot.privateHostAccess : snapshot.normalHostAccess
        if access.allows(tab.url, requested: snapshot.requestedHosts) {
            return true
        }
        return activeTabGrants[extensionID]?.allows(tab, now: now()) ?? false
    }

    func invalidate(tab: FloorpWebExtensionTabContext) {
        activeTabGrants = activeTabGrants.filter { _, grant in
            !(grant.tabID == tab.tabID && grant.documentGeneration == tab.documentGeneration)
        }
    }

    @discardableResult
    func observeChanges(
        _ observer: @escaping @Sendable (FloorpWebExtensionPermissionChange) -> Void
    ) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notify(
        _ extensionID: FloorpWebExtensionID,
        previous: FloorpWebExtensionPermissionSnapshot,
        current: FloorpWebExtensionPermissionSnapshot
    ) {
        guard previous != current else { return }
        let change = FloorpWebExtensionPermissionChange(
            extensionID: extensionID,
            previous: previous,
            current: current
        )
        for observer in observers.values {
            observer(change)
        }
    }
}
