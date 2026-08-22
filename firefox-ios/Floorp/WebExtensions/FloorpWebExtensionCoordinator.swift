// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import WebKit

/// Identifies a coordinator whose mutable extension state is isolated to one
/// browser profile and browsing mode.  In particular, private DNR caches and
/// grants can never become visible to a normal-profile coordinator.
struct FloorpWebExtensionCoordinatorProfileKey: Hashable, Sendable {
    let profileIdentifier: String
    let isPrivateBrowsing: Bool

    init(profileIdentifier: String, isPrivateBrowsing: Bool) {
        self.profileIdentifier = profileIdentifier
        self.isPrivateBrowsing = isPrivateBrowsing
    }
}

/// The complete script policy for one extension and one imminent navigation.
///
/// This value is intentionally pre-materialized: `Tab` can ask its
/// profile-owned coordinator for it synchronously immediately before calling
/// `load`, without doing package I/O or crossing an actor boundary.
struct FloorpWebExtensionNavigationPolicySnapshot: Sendable {
    let extensionID: FloorpWebExtensionID
    let scriptPolicies: [FloorpWebExtensionUserScriptPolicy]
}

/// A small FIFO gate used only for mutations to one extension's DNR store.
/// Actors are re-entrant at `await` points, so an ordinary DNR actor alone
/// would allow a second update to start compiling against the same generation.
private actor FloorpWebExtensionDNRMutationGate {
    private var isLocked = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Coordinates the Stage 3 MV3 registries with one profile's live WebKit
/// runtime.
///
/// Registries remain actors because they validate transactional API requests.
/// The coordinator keeps a MainActor cache of the validated, materialized
/// state.  That cache is refreshed before every public mutation returns, which
/// gives `Tab` a synchronous pre-navigation snapshot and avoids a first-load
/// race after a script or host-grant update.
@MainActor
final class FloorpWebExtensionCoordinator {
    typealias ScriptResourceLoader = @Sendable (
        FloorpWebExtensionID,
        FloorpWebExtensionScriptSource
    ) throws -> String

    private struct MaterializedScript: Sendable {
        let script: FloorpWebExtensionRegisteredScript
        let policies: [FloorpWebExtensionUserScriptPolicy]
    }

    private struct ActiveTabGrant: Sendable {
        let tabID: Int
        let documentGeneration: UInt64
        let expiration: Date

        func allows(_ tab: FloorpWebExtensionTabContext, now: Date) -> Bool {
            tabID == tab.tabID && documentGeneration == tab.documentGeneration && now < expiration
        }
    }

    private static var coordinators = [FloorpWebExtensionCoordinatorProfileKey: FloorpWebExtensionCoordinator]()

    let profileKey: FloorpWebExtensionCoordinatorProfileKey
    private let runtime: FloorpWebExtensionRuntime
    private let scriptResourceLoader: ScriptResourceLoader
    private let now: @Sendable () -> Date

    /// These actors are deliberately coordinator-owned; no caller receives a
    /// mutable registry that could bypass runtime reconciliation.
    private let scriptRegistry: FloorpWebExtensionScriptRegistry
    private let permissionBroker: FloorpWebExtensionPermissionBroker
    private let cssRegistry: FloorpWebExtensionCSSRegistry
    private var dnrStores = [FloorpWebExtensionID: FloorpWebExtensionDNRStore]()
    private var dnrLimits = [FloorpWebExtensionID: FloorpWebExtensionDNRLimits]()
    private var dnrMutationGates = [FloorpWebExtensionID: FloorpWebExtensionDNRMutationGate]()

    /// MainActor cache used by `preNavigationPolicies(for:)`.
    /// Arrays retain `FloorpWebExtensionScriptRegistry`'s registration order.
    /// A dictionary would accidentally change cross-script execution order.
    private var materializedScripts = [FloorpWebExtensionID: [MaterializedScript]]()
    private var permissionSnapshots = [FloorpWebExtensionID: FloorpWebExtensionPermissionSnapshot]()
    private var activeTabGrants = [FloorpWebExtensionID: ActiveTabGrant]()

    init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        runtime: FloorpWebExtensionRuntime,
        scriptResourceLoader: @escaping ScriptResourceLoader,
        scriptRegistry: FloorpWebExtensionScriptRegistry = .init(),
        permissionBroker: FloorpWebExtensionPermissionBroker = .init(),
        cssRegistry: FloorpWebExtensionCSSRegistry = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        profileKey = .init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        self.runtime = runtime
        self.scriptResourceLoader = scriptResourceLoader
        self.scriptRegistry = scriptRegistry
        self.permissionBroker = permissionBroker
        self.cssRegistry = cssRegistry
        self.now = now
    }

    /// Returns the coordinator registered for a profile.  Production package
    /// installation must install a coordinator with a validated in-memory
    /// resource loader before it can register a script.
    static func coordinator(
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) -> FloorpWebExtensionCoordinator {
        let key = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        if let coordinator = coordinators[key] {
            return coordinator
        }
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            runtime: .runtime(
                for: profileIdentifier,
                isPrivateBrowsing: isPrivateBrowsing
            ),
            scriptResourceLoader: { _, resource in
                throw FloorpWebExtensionError.unsupported(
                    "package resource \(resource.path) was not materialized by the installer"
                )
            }
        )
        coordinators[key] = coordinator
        return coordinator
    }

    /// Registers the profile-owned coordinator created by package/profile
    /// composition. Replacing a coordinator never combines normal and private
    /// state: the key includes the browsing mode.
    static func install(_ coordinator: FloorpWebExtensionCoordinator) {
        coordinators[coordinator.profileKey] = coordinator
    }

    static func removeCoordinator(for profileIdentifier: String, isPrivateBrowsing: Bool) {
        let key = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        coordinators.removeValue(forKey: key)?.tearDown()
    }

    /// Adds registered scripts and immediately refreshes the pre-navigation
    /// cache. A caller observing this async method's return can safely create
    /// a tab and receive the new policy on its first navigation.
    func registerScripts(
        _ scripts: [FloorpWebExtensionRegisteredScript],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        // Resource materialization must succeed before the registry commits.
        // Otherwise a package-resource failure could leave a persistent script
        // registration that has no corresponding pre-navigation policy.
        try scripts.forEach { _ = try materialize($0, for: extensionID) }
        try await scriptRegistry.register(scripts, for: extensionID)
        try await refreshScripts(for: extensionID)
    }

    func updateScripts(
        _ updates: [FloorpWebExtensionRegisteredScriptUpdate],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        let existing = await scriptRegistry.registeredScripts(for: extensionID)
        var prospective = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for update in updates {
            if let script = prospective[update.id] {
                prospective[update.id] = script.applying(update)
            }
        }
        try prospective.values.forEach { _ = try materialize($0, for: extensionID) }
        try await scriptRegistry.update(updates, for: extensionID)
        try await refreshScripts(for: extensionID)
    }

    func unregisterScripts(
        _ identifiers: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        try await scriptRegistry.unregister(identifiers, for: extensionID)
        try await refreshScripts(for: extensionID)
    }

    /// Replaces the extension's permission and host-grant snapshot. This is
    /// intentionally a full snapshot API so permission expansion cannot occur
    /// by accident through a partial merge.
    func grantPermissions(
        _ permissions: Set<FloorpWebExtensionAPIGrant>,
        requestedHosts: Set<FloorpWebExtensionMatchPattern>,
        hostAccess: FloorpWebExtensionHostAccess,
        privateHostAccess: FloorpWebExtensionHostAccess = .denied,
        privateBrowsingEnabled: Bool = false,
        to extensionID: FloorpWebExtensionID
    ) async {
        await permissionBroker.grant(
            permissions,
            requestedHosts: requestedHosts,
            hostAccess: hostAccess,
            privateHostAccess: privateHostAccess,
            privateBrowsingEnabled: privateBrowsingEnabled,
            to: extensionID
        )
        permissionSnapshots[extensionID] = await permissionBroker.snapshot(for: extensionID)
        activeTabGrants.removeValue(forKey: extensionID)
    }

    func setHostAccess(
        _ access: FloorpWebExtensionHostAccess,
        privateAccess: Bool,
        for extensionID: FloorpWebExtensionID
    ) async {
        await permissionBroker.updateSiteAccess(
            access,
            privateAccess: privateAccess,
            for: extensionID
        )
        permissionSnapshots[extensionID] = await permissionBroker.snapshot(for: extensionID)
        activeTabGrants.removeValue(forKey: extensionID)
    }

    /// Revokes this profile mode's host access while preserving the extension's
    /// declared hosts and unrelated API grants. Normal and private permission
    /// stores are never shared by this operation.
    func revokeHostPermissions(for extensionID: FloorpWebExtensionID) async {
        await setHostAccess(
            .denied,
            privateAccess: profileKey.isPrivateBrowsing,
            for: extensionID
        )
    }

    func grantActiveTab(
        to extensionID: FloorpWebExtensionID,
        for tab: FloorpWebExtensionTabContext,
        duration: TimeInterval = 300
    ) async throws {
        try validateProfile(tab)
        try await permissionBroker.grantActiveTab(
            to: extensionID,
            for: tab,
            duration: duration
        )
        activeTabGrants[extensionID] = .init(
            tabID: tab.tabID,
            documentGeneration: tab.documentGeneration,
            expiration: now().addingTimeInterval(duration)
        )
    }

    func invalidate(tab: FloorpWebExtensionTabContext) async {
        guard tab.isPrivate == profileKey.isPrivateBrowsing else { return }
        await permissionBroker.invalidate(tab: tab)
        activeTabGrants = activeTabGrants.filter { _, grant in
            !(grant.tabID == tab.tabID && grant.documentGeneration == tab.documentGeneration)
        }
        await cssRegistry.discardInsertions(for: tab)
    }

    /// Inserts CSS only after the scripting permission, profile mode, host
    /// access, and document generation have all been verified by the owned
    /// registry. The runtime owns the corresponding page-world DOM mutation.
    func insertCSS(
        _ css: String,
        for extensionID: FloorpWebExtensionID,
        target: FloorpWebExtensionCSSTarget,
        tab: FloorpWebExtensionTabContext,
        into webView: WKWebView
    ) async throws -> FloorpWebExtensionCSSInsertion {
        try validateProfile(tab)
        // The current WebKit runtime can address the main document only. A
        // subframe target must not silently fall back to page-world CSS in the
        // main frame, which would both violate the caller's target and leak a
        // policy across frame boundaries.
        guard target.frameID == nil else {
            throw FloorpWebExtensionError.unsupported("subframe CSS insertion")
        }
        let insertion = try await cssRegistry.insert(
            css: css,
            for: extensionID,
            target: target,
            tab: tab,
            permissionBroker: permissionBroker
        )
        runtime.applyCSSInsertion(insertion, to: webView)
        return insertion
    }

    func removeCSS(
        _ handles: [FloorpWebExtensionCSSHandle],
        for extensionID: FloorpWebExtensionID,
        target: FloorpWebExtensionCSSTarget,
        from webView: WKWebView
    ) async throws {
        let removed = try await cssRegistry.remove(
            handles,
            for: extensionID,
            target: target
        )
        runtime.removeCSSInsertions(removed, from: webView)
    }

    /// Configures an extension-specific DNR store. Its compilation is attached
    /// before the store becomes active, so a WebKit compile failure cannot
    /// replace an already functioning ruleset.
    @discardableResult
    func configureDNR(
        for extensionID: FloorpWebExtensionID,
        staticRuleSets: [FloorpWebExtensionDNRStaticRuleSet] = [],
        enabledStaticRuleSetIDs: Set<String> = [],
        limits: FloorpWebExtensionDNRLimits = .init()
    ) async throws -> Bool {
        let gate = dnrMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        try requireDNRPermission(for: extensionID)
        let candidate = try FloorpWebExtensionDNRStore(
            staticRuleSets: staticRuleSets,
            enabledStaticRuleSetIDs: enabledStaticRuleSetIDs,
            limits: limits
        )
        let compilation = await candidate.currentCompilation()
        let applied = try await runtime.compileAndSetDNR(compilation, for: extensionID)
        guard applied else { return false }
        dnrStores[extensionID] = candidate
        dnrLimits[extensionID] = limits
        return true
    }

    @discardableResult
    func updateEnabledStaticRuleSets(
        enable: [String],
        disable: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws -> Bool {
        try await stageDNRMutation(for: extensionID) { candidate in
            try await candidate.updateEnabledStaticRuleSets(enable: enable, disable: disable)
        }
    }

    @discardableResult
    func updateDynamicRules(
        addRules: [FloorpWebExtensionDNRRule],
        removeRuleIDs: [Int],
        for extensionID: FloorpWebExtensionID
    ) async throws -> Bool {
        try await stageDNRMutation(for: extensionID) { candidate in
            try await candidate.updateDynamicRules(addRules: addRules, removeRuleIDs: removeRuleIDs)
        }
    }

    @discardableResult
    func updateSessionRules(
        addRules: [FloorpWebExtensionDNRRule],
        removeRuleIDs: [Int],
        for extensionID: FloorpWebExtensionID
    ) async throws -> Bool {
        try await stageDNRMutation(for: extensionID) { candidate in
            try await candidate.updateSessionRules(addRules: addRules, removeRuleIDs: removeRuleIDs)
        }
    }

    @discardableResult
    func clearSessionRules(for extensionID: FloorpWebExtensionID) async throws -> Bool {
        try await stageDNRMutation(for: extensionID) { candidate in
            try await candidate.clearSessionRules()
        }
    }

    /// Returns the already-materialized, profile-correct policy for the very
    /// next navigation. It deliberately has no `async` marker.
    func preNavigationPolicies(
        for tab: FloorpWebExtensionTabContext
    ) -> [FloorpWebExtensionNavigationPolicySnapshot] {
        guard tab.isPrivate == profileKey.isPrivateBrowsing else { return [] }

        return materializedScripts.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { extensionID in
            guard allowsScripting(for: extensionID, in: tab) else { return nil }
            let policies = (materializedScripts[extensionID] ?? [])
                .filter { materialized in
                    materialized.script.matches.contains(where: { $0.matches(tab.url) }) &&
                        !materialized.script.excludeMatches.contains(where: { $0.matches(tab.url) })
                }
                .flatMap(\.policies)
            guard !policies.isEmpty else { return nil }
            return .init(extensionID: extensionID, scriptPolicies: policies)
        }
    }

    func permissionSnapshot(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionPermissionSnapshot {
        permissionSnapshots[extensionID] ?? .init()
    }

    func dnrSnapshot(
        for extensionID: FloorpWebExtensionID
    ) async -> FloorpWebExtensionDNRPolicySnapshot? {
        guard let store = dnrStores[extensionID] else { return nil }
        return await store.snapshot()
    }

    /// Removes all profile-local extension state and its live WebKit policy.
    func removeExtension(_ extensionID: FloorpWebExtensionID) async {
        let identifiers = await scriptRegistry.registeredScripts(for: extensionID).map(\.id)
        if !identifiers.isEmpty {
            try? await scriptRegistry.unregister(identifiers, for: extensionID)
        }
        materializedScripts.removeValue(forKey: extensionID)
        permissionSnapshots.removeValue(forKey: extensionID)
        activeTabGrants.removeValue(forKey: extensionID)
        dnrStores.removeValue(forKey: extensionID)
        dnrLimits.removeValue(forKey: extensionID)
        await permissionBroker.grant(
            [],
            requestedHosts: [],
            hostAccess: .denied,
            to: extensionID
        )
        runtime.removePolicies(for: extensionID)
    }

    private func refreshScripts(for extensionID: FloorpWebExtensionID) async throws {
        let registered = await scriptRegistry.registeredScripts(for: extensionID)
        var refreshed = [MaterializedScript]()
        for script in registered {
            let policies = try materialize(script, for: extensionID)
            refreshed.append(.init(script: script, policies: policies))
        }
        if refreshed.isEmpty {
            materializedScripts.removeValue(forKey: extensionID)
        } else {
            materializedScripts[extensionID] = refreshed
        }
    }

    private func materialize(
        _ script: FloorpWebExtensionRegisteredScript,
        for extensionID: FloorpWebExtensionID
    ) throws -> [FloorpWebExtensionUserScriptPolicy] {
        let cssPolicies = try script.styleSheets.map { source in
            let css = try scriptResourceLoader(extensionID, source)
            return FloorpWebExtensionUserScriptPolicy(
                source: try Self.styleInjectionSource(css),
                runAt: script.runAt,
                allFrames: script.allFrames,
                world: script.world
            )
        }
        let javaScriptPolicies = try script.javaScript.map { source in
            FloorpWebExtensionUserScriptPolicy(
                source: try scriptResourceLoader(extensionID, source),
                runAt: script.runAt,
                allFrames: script.allFrames,
                world: script.world
            )
        }
        return cssPolicies + javaScriptPolicies
    }

    private func allowsScripting(
        for extensionID: FloorpWebExtensionID,
        in tab: FloorpWebExtensionTabContext
    ) -> Bool {
        let snapshot = permissionSnapshot(for: extensionID)
        guard snapshot.apiPermissions.contains(.scripting) else { return false }
        if tab.isPrivate && !snapshot.privateBrowsingEnabled {
            return false
        }
        let access = tab.isPrivate ? snapshot.privateHostAccess : snapshot.normalHostAccess
        switch access {
        case .denied:
            return activeTabGrants[extensionID]?.allows(tab, now: now()) ?? false
        case .selectedSites(let patterns):
            return patterns.contains(where: { $0.matches(tab.url) }) ||
                (activeTabGrants[extensionID]?.allows(tab, now: now()) ?? false)
        case .allRequestedSites:
            return snapshot.requestedHosts.contains(where: { $0.matches(tab.url) }) ||
                (activeTabGrants[extensionID]?.allows(tab, now: now()) ?? false)
        }
    }

    private func stageDNRMutation(
        for extensionID: FloorpWebExtensionID,
        mutation: @escaping @Sendable (FloorpWebExtensionDNRStore) async throws -> Void
    ) async throws -> Bool {
        let gate = dnrMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        try requireDNRPermission(for: extensionID)
        guard let activeStore = dnrStores[extensionID],
              let limits = dnrLimits[extensionID] else {
            throw FloorpWebExtensionError.unsupported("DNR was not configured for \(extensionID.rawValue)")
        }
        let snapshot = await activeStore.snapshot()
        let candidate = try FloorpWebExtensionDNRStore(replaying: snapshot, limits: limits)
        try await mutation(candidate)

        // The active dictionary is intentionally not changed until WebKit has
        // asynchronously compiled and atomically installed this generation.
        let compilation = await candidate.currentCompilation()
        let applied = try await runtime.compileAndSetDNR(compilation, for: extensionID)
        guard applied else { return false }
        dnrStores[extensionID] = candidate
        return true
    }

    private func requireDNRPermission(for extensionID: FloorpWebExtensionID) throws {
        guard permissionSnapshot(for: extensionID).apiPermissions.contains(.declarativeNetRequest) else {
            throw FloorpWebExtensionError.permissionDenied(
                FloorpWebExtensionAPIGrant.declarativeNetRequest.rawValue
            )
        }
    }

    private func dnrMutationGate(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionDNRMutationGate {
        if let existing = dnrMutationGates[extensionID] {
            return existing
        }
        let gate = FloorpWebExtensionDNRMutationGate()
        dnrMutationGates[extensionID] = gate
        return gate
    }

    private func validateProfile(_ tab: FloorpWebExtensionTabContext) throws {
        guard tab.isPrivate == profileKey.isPrivateBrowsing else {
            throw FloorpWebExtensionError.permissionDenied("profile mode")
        }
    }

    private static func styleInjectionSource(_ css: String) throws -> String {
        let encoded = try JSONEncoder().encode(css)
        guard let literal = String(data: encoded, encoding: .utf8) else {
            throw FloorpWebExtensionError.unsupported("stylesheet serialization")
        }
        return """
        (() => {
          const style = document.createElement('style');
          style.textContent = \(literal);
          (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    private func tearDown() {
        let extensionIDs = Set(materializedScripts.keys)
            .union(dnrStores.keys)
            .union(permissionSnapshots.keys)
        extensionIDs.forEach(runtime.removePolicies(for:))
        materializedScripts.removeAll()
        permissionSnapshots.removeAll()
        activeTabGrants.removeAll()
        dnrStores.removeAll()
        dnrLimits.removeAll()
        dnrMutationGates.removeAll()
    }
}
