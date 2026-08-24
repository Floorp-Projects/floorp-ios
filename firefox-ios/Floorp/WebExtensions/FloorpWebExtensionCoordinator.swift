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

/// A FIFO gate for a single extension's registered-content-script mutation
/// transaction. Main-actor methods still yield while the package registry is
/// persisted, so this separate actor prevents another mutation from planning
/// against the same stale registry and replacing the first transaction's
/// materialized cache or durable snapshot.
private actor FloorpWebExtensionScriptMutationGate {
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
/// Transactional registries remain actors where their state is independent of
/// WebKit. Dynamic CSS state instead shares `MainActor` with the live DOM
/// commit so a navigation cannot interleave between authorization and
/// mutation. The coordinator keeps a cache of validated, materialized state;
/// that cache is refreshed before every public mutation returns, which gives
/// `Tab` a synchronous pre-navigation snapshot and avoids a first-load race
/// after a script or host-grant update.
@MainActor
final class FloorpWebExtensionCoordinator {
    typealias ScriptResourceLoader = @Sendable (
        FloorpWebExtensionID,
        FloorpWebExtensionScriptSource
    ) throws -> String
    typealias APIHostSuspender = @MainActor (FloorpWebExtensionID) async -> Void
    typealias APIHostPurger = @MainActor (FloorpWebExtensionID) async throws -> Void
    /// Test synchronization point for proving that the final authorization is
    /// performed after every asynchronous preparation step. Production uses
    /// the no-op default; the live-target validator still remains mandatory.
    typealias DynamicCSSMutationCheckpoint = @MainActor @Sendable () async -> Void
    typealias ScriptMutationValidator = @MainActor () throws -> Void

    private struct MaterializedScript: Sendable {
        let script: FloorpWebExtensionRegisteredScript
        let policies: [FloorpWebExtensionUserScriptPolicy]
        let frameAuthorizationRevision: String
    }

    /// Generated package cosmetic resources intentionally have no dynamic
    /// registration API. Keeping them separate prevents a registered-content
    /// script update from addressing generated source.
    private struct MaterializedCosmeticResource: Sendable {
        let resource: FloorpWebExtensionCosmeticResource
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
    private let packageStore: FloorpWebExtensionPackageStore?
    private let suspendAPIHost: APIHostSuspender
    private let purgeAPIHost: APIHostPurger
    private let beforeDynamicCSSMutation: DynamicCSSMutationCheckpoint
    private let now: @Sendable () -> Date

    /// These registries are deliberately coordinator-owned; no caller receives
    /// mutable production state that could bypass runtime reconciliation.
    private let scriptRegistry: FloorpWebExtensionScriptRegistry
    private let permissionBroker: FloorpWebExtensionPermissionBroker
    private let cssRegistry: FloorpWebExtensionCSSRegistry
    private var dnrStores = [FloorpWebExtensionID: FloorpWebExtensionDNRStore]()
    private var dnrLimits = [FloorpWebExtensionID: FloorpWebExtensionDNRLimits]()
    private var dnrMutationGates = [FloorpWebExtensionID: FloorpWebExtensionDNRMutationGate]()
    private var scriptMutationGates = [FloorpWebExtensionID: FloorpWebExtensionScriptMutationGate]()

    /// MainActor cache used by `preNavigationPolicies(for:)`.
    /// Arrays retain `FloorpWebExtensionScriptRegistry`'s registration order.
    /// A dictionary would accidentally change cross-script execution order.
    private var materializedScripts = [FloorpWebExtensionID: [MaterializedScript]]()
    private var materializedCosmeticResources = [FloorpWebExtensionID: [MaterializedCosmeticResource]]()
    private var permissionSnapshots = [FloorpWebExtensionID: FloorpWebExtensionPermissionSnapshot]()
    private var activeTabGrants = [FloorpWebExtensionID: ActiveTabGrant]()

    init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        runtime: FloorpWebExtensionRuntime,
        scriptResourceLoader: @escaping ScriptResourceLoader,
        packageStore: FloorpWebExtensionPackageStore? = nil,
        suspendAPIHost: APIHostSuspender? = nil,
        purgeAPIHost: APIHostPurger? = nil,
        scriptRegistry: FloorpWebExtensionScriptRegistry = .init(),
        permissionBroker: FloorpWebExtensionPermissionBroker = .init(),
        cssRegistry: FloorpWebExtensionCSSRegistry = .init(),
        beforeDynamicCSSMutation: DynamicCSSMutationCheckpoint? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let profileKey = FloorpWebExtensionCoordinatorProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        self.profileKey = profileKey
        self.runtime = runtime
        self.scriptResourceLoader = scriptResourceLoader
        self.packageStore = packageStore
        self.suspendAPIHost = suspendAPIHost ?? { extensionID in
            await FloorpWebExtensionAPIHostRegistry.suspend(extensionID, profileKey: profileKey)
        }
        self.purgeAPIHost = purgeAPIHost ?? { extensionID in
            try await FloorpWebExtensionAPIHostRegistry.purge(extensionID, profileKey: profileKey)
        }
        self.scriptRegistry = scriptRegistry
        self.permissionBroker = permissionBroker
        self.cssRegistry = cssRegistry
        self.beforeDynamicCSSMutation = beforeDynamicCSSMutation ?? {}
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

    /// Looks up an already-composed profile runtime without manufacturing a
    /// fallback coordinator. Native API dispatch must use this entry point so
    /// a script cannot mutate an unattached registry when profile composition
    /// is unavailable or still starting.
    static func installedCoordinator(
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) -> FloorpWebExtensionCoordinator? {
        coordinators[.init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )]
    }

    static func isInstalled(_ coordinator: FloorpWebExtensionCoordinator) -> Bool {
        coordinators[coordinator.profileKey] === coordinator
    }

    /// Registers the profile-owned coordinator created by package/profile
    /// composition. Replacing a coordinator never combines normal and private
    /// state: the key includes the browsing mode.
    static func install(_ coordinator: FloorpWebExtensionCoordinator) {
        if let previous = coordinators.updateValue(coordinator, forKey: coordinator.profileKey),
           previous !== coordinator {
            previous.tearDown()
        }
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
        for extensionID: FloorpWebExtensionID,
        expectedPackageGeneration: String? = nil,
        validateAuthority: ScriptMutationValidator = {}
    ) async throws {
        try validateAuthority()
        let gate = scriptMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        try validateAuthority()
        let previous = await scriptRegistry.dynamicSnapshot(for: extensionID)
        let previousDynamic = await scriptRegistry.registeredScripts(for: extensionID)
        let prospective = try await scriptRegistry.scriptsAfterRegistering(
            scripts,
            for: extensionID
        )
        try validateAuthority()
        let materialized = try materializedScripts(for: prospective, extensionID: extensionID)
        do {
            try validateAuthority()
            try await scriptRegistry.register(scripts, for: extensionID)
            try validateAuthority()
            let committedDurably = try await persistRegisteredScripts(
                prospective,
                replacing: previousDynamic,
                for: extensionID,
                expectedPackageGeneration: expectedPackageGeneration
            )
            if !committedDurably { try validateAuthority() }
        } catch {
            await scriptRegistry.restoreDynamicSnapshot(previous, for: extensionID)
            throw error
        }
        installMaterializedScripts(materialized, for: extensionID)
    }

    func updateScripts(
        _ updates: [FloorpWebExtensionRegisteredScriptUpdate],
        for extensionID: FloorpWebExtensionID,
        expectedPackageGeneration: String? = nil,
        validateAuthority: ScriptMutationValidator = {}
    ) async throws {
        try validateAuthority()
        let gate = scriptMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        try validateAuthority()
        let previous = await scriptRegistry.dynamicSnapshot(for: extensionID)
        let previousDynamic = await scriptRegistry.registeredScripts(for: extensionID)
        let prospective = try await scriptRegistry.scriptsAfterUpdating(
            updates,
            for: extensionID
        )
        try validateAuthority()
        let materialized = try materializedScripts(for: prospective, extensionID: extensionID)
        do {
            try validateAuthority()
            try await scriptRegistry.update(updates, for: extensionID)
            try validateAuthority()
            let committedDurably = try await persistRegisteredScripts(
                prospective,
                replacing: previousDynamic,
                for: extensionID,
                expectedPackageGeneration: expectedPackageGeneration
            )
            if !committedDurably { try validateAuthority() }
        } catch {
            await scriptRegistry.restoreDynamicSnapshot(previous, for: extensionID)
            throw error
        }
        installMaterializedScripts(materialized, for: extensionID)
    }

    func unregisterScripts(
        _ identifiers: [String],
        for extensionID: FloorpWebExtensionID,
        expectedPackageGeneration: String? = nil,
        validateAuthority: ScriptMutationValidator = {}
    ) async throws {
        try validateAuthority()
        let gate = scriptMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        try validateAuthority()
        let previous = await scriptRegistry.dynamicSnapshot(for: extensionID)
        let previousDynamic = await scriptRegistry.registeredScripts(for: extensionID)
        let prospective = try await scriptRegistry.scriptsAfterUnregistering(
            identifiers,
            for: extensionID
        )
        try validateAuthority()
        let materialized = try materializedScripts(for: prospective, extensionID: extensionID)
        do {
            try validateAuthority()
            try await scriptRegistry.unregister(identifiers, for: extensionID)
            try validateAuthority()
            let committedDurably = try await persistRegisteredScripts(
                prospective,
                replacing: previousDynamic,
                for: extensionID,
                expectedPackageGeneration: expectedPackageGeneration
            )
            if !committedDurably { try validateAuthority() }
        } catch {
            await scriptRegistry.restoreDynamicSnapshot(previous, for: extensionID)
            throw error
        }
        installMaterializedScripts(materialized, for: extensionID)
    }

    /// Restores package-owned script state that has already passed durable
    /// package validation. Startup must not call the public mutation path:
    /// registering manifest scripts first would otherwise replace the saved
    /// dynamic persistent subset with an empty list.
    func restoreScripts(
        _ scripts: [FloorpWebExtensionRegisteredScript],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        let gate = scriptMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        let prospective = try await scriptRegistry.scriptsAfterRegistering(
            scripts,
            for: extensionID
        )
        let materialized = try materializedScripts(for: prospective, extensionID: extensionID)
        try await scriptRegistry.register(scripts, for: extensionID)
        installMaterializedScripts(materialized, for: extensionID)
    }

    func restoreManifestScripts(
        _ scripts: [FloorpWebExtensionRegisteredScript],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        let gate = scriptMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        try await scriptRegistry.registerManifestScripts(scripts, for: extensionID)
        let registered = await scriptRegistry.allRegisteredScripts(for: extensionID)
        let materialized = try materializedScripts(for: registered, extensionID: extensionID)
        installMaterializedScripts(materialized, for: extensionID)
    }

    /// Replaces the static cosmetic policies decoded from the active immutable
    /// package generation. This is deliberately not exposed through the
    /// scripting API: callers can only reach it after the installer has
    /// checked a declared package resource and generated its bounded source.
    /// Cosmetic resources are main-frame-only, so this path cannot create an
    /// unauthenticated subframe execution policy.
    func restoreCosmeticResources(
        _ resources: [FloorpWebExtensionCosmeticPackageResource],
        for extensionID: FloorpWebExtensionID
    ) throws {
        try FloorpWebExtensionCosmeticFilterPackageDecoder.validatePackage(resources)
        let materialized = try resources.map { packageResource -> MaterializedCosmeticResource in
            let resource = packageResource.resource
            var policies = [FloorpWebExtensionUserScriptPolicy]()
            if let css = resource.css {
                policies.append(.init(
                    source: try Self.styleInjectionSource(css),
                    runAt: packageResource.runAt,
                    world: resource.world
                ))
            }
            if let javaScript = resource.javaScript {
                policies.append(.init(
                    source: javaScript,
                    runAt: packageResource.runAt,
                    world: resource.world
                ))
            }
            guard !policies.isEmpty else {
                throw FloorpWebExtensionError.unsupported("empty cosmetic filter resource")
            }
            return .init(resource: resource, policies: policies)
        }
        if materialized.isEmpty {
            materializedCosmeticResources.removeValue(forKey: extensionID)
        } else {
            materializedCosmeticResources[extensionID] = materialized
        }
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
        cssRegistry.discardInsertions(for: tab)
    }

    /// Inserts CSS only after the scripting permission, profile mode, host
    /// access, and document generation have all been verified by the owned
    /// registry. The runtime owns the corresponding page-world DOM mutation.
    func insertCSS(
        _ css: String,
        for extensionID: FloorpWebExtensionID,
        target: FloorpWebExtensionCSSTarget,
        tab: FloorpWebExtensionTabContext,
        into webView: WKWebView,
        validateLiveTarget: @MainActor () throws -> Void
    ) async throws -> FloorpWebExtensionCSSInsertion {
        try validateProfile(tab)
        // The current WebKit runtime can address the main document only. A
        // subframe target must not silently fall back to page-world CSS in the
        // main frame, which would both violate the caller's target and leak a
        // policy across frame boundaries.
        guard target.frameID == nil else {
            throw FloorpWebExtensionError.unsupported("subframe CSS insertion")
        }
        guard target == FloorpWebExtensionCSSTarget(tab: tab),
              authorizesDynamicScripting(for: extensionID, tab: tab) else {
            throw FloorpWebExtensionError.permissionDenied(FloorpWebExtensionAPIGrant.scripting.rawValue)
        }

        // Resource loading and permission actors may have yielded since the
        // API host first resolved this document. Revalidate after that last
        // asynchronous boundary, then commit the handle and DOM mutation
        // without another actor hop. A rotated document therefore receives
        // neither a stylesheet nor a quota-consuming stale handle.
        await beforeDynamicCSSMutation()
        try validateLiveTarget()
        guard authorizesDynamicScripting(for: extensionID, tab: tab) else {
            throw FloorpWebExtensionError.permissionDenied(FloorpWebExtensionAPIGrant.scripting.rawValue)
        }
        let insertion = try cssRegistry.insert(
            css: css,
            for: extensionID,
            target: target
        )
        runtime.applyCSSInsertion(insertion, to: webView)
        return insertion
    }

    func removeCSS(
        _ handles: [FloorpWebExtensionCSSHandle],
        for extensionID: FloorpWebExtensionID,
        target: FloorpWebExtensionCSSTarget,
        tab: FloorpWebExtensionTabContext,
        from webView: WKWebView,
        validateLiveTarget: @MainActor () throws -> Void
    ) async throws {
        try validateProfile(tab)
        guard target == FloorpWebExtensionCSSTarget(tab: tab),
              authorizesDynamicScripting(for: extensionID, tab: tab) else {
            throw FloorpWebExtensionError.permissionDenied(FloorpWebExtensionAPIGrant.scripting.rawValue)
        }
        await beforeDynamicCSSMutation()
        try validateLiveTarget()
        guard authorizesDynamicScripting(for: extensionID, tab: tab) else {
            throw FloorpWebExtensionError.permissionDenied(FloorpWebExtensionAPIGrant.scripting.rawValue)
        }
        let removed = try cssRegistry.remove(
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
        let previousStore = dnrStores[extensionID]
        let previousSnapshot = await previousStore?.snapshot()
        let previousLimits = dnrLimits[extensionID]
        let candidate = try FloorpWebExtensionDNRStore(
            staticRuleSets: staticRuleSets,
            enabledStaticRuleSetIDs: enabledStaticRuleSetIDs,
            limits: limits,
            generation: (previousSnapshot?.generation ?? 0) &+ 1
        )
        return try await installDNR(
            candidate,
            for: extensionID,
            limits: limits,
            previousSnapshot: previousSnapshot,
            previousLimits: previousLimits,
            persistConfiguration: true
        )
    }

    /// Restores one package's complete persisted DNR state in a single WebKit
    /// compilation. Registry state is deliberately not rewritten here: a
    /// partially restored package must never erase its durable dynamic-rule
    /// snapshot before all static and dynamic rules have been accepted.
    @discardableResult
    func restoreDNR(
        for extensionID: FloorpWebExtensionID,
        staticRuleSets: [FloorpWebExtensionDNRStaticRuleSet],
        enabledStaticRuleSetIDs: Set<String>,
        dynamicRules: [FloorpWebExtensionDNRRule],
        limits: FloorpWebExtensionDNRLimits
    ) async throws -> Bool {
        let gate = dnrMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }
        try requireDNRPermission(for: extensionID)
        let previousStore = dnrStores[extensionID]
        let previousSnapshot = await previousStore?.snapshot()
        let candidate = try FloorpWebExtensionDNRStore(
            staticRuleSets: staticRuleSets,
            enabledStaticRuleSetIDs: enabledStaticRuleSetIDs,
            dynamicRules: dynamicRules,
            limits: limits,
            generation: (previousSnapshot?.generation ?? 0) &+ 1
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

        let activeExtensionIDs = Set(materializedScripts.keys)
            .union(materializedCosmeticResources.keys)
            .sorted { $0.rawValue < $1.rawValue }
        return activeExtensionIDs.compactMap { extensionID in
            let snapshot = permissionSnapshot(for: extensionID)
            guard snapshot.apiPermissions.contains(.scripting),
                  !tab.isPrivate || snapshot.privateBrowsingEnabled else {
                return nil
            }
            let hasActiveTab = activeTabGrants[extensionID]?.allows(tab, now: now()) == true
            let hostAccess = tab.isPrivate ? snapshot.privateHostAccess : snapshot.normalHostAccess
            let hasDurableHostAccess: Bool
            switch hostAccess {
            case .denied:
                hasDurableHostAccess = false
            case .selectedSites(let patterns):
                hasDurableHostAccess = !patterns.isEmpty
            case .allRequestedSites:
                hasDurableHostAccess = !snapshot.requestedHosts.isEmpty
            }
            // An all-frame registration may legitimately match only a child
            // frame. Install its authenticated policy even when the top-level
            // URL is outside the extension's host grant. Every frame asks the
            // native coordinator again immediately before package code runs.
            guard hasDurableHostAccess || hasActiveTab else { return nil }
            let registeredScriptPolicies = (materializedScripts[extensionID] ?? [])
                .flatMap { materialized -> [FloorpWebExtensionUserScriptPolicy] in
                    let script = materialized.script
                    if !script.allFrames {
                        guard script.matches.contains(where: { $0.matches(tab.url) }),
                              !script.excludeMatches.contains(where: { $0.matches(tab.url) }),
                              allowsScripting(for: extensionID, in: tab) else {
                            return []
                        }
                        return materialized.policies
                    }
                    return materialized.policies.map { policy in
                        FloorpWebExtensionUserScriptPolicy(
                            source: policy.source,
                            runAt: policy.runAt,
                            allFrames: policy.allFrames,
                            world: policy.world,
                            frameAuthorization: .init(
                                scriptID: script.id,
                                revisionToken: materialized.frameAuthorizationRevision
                            )
                        )
                    }
                }
            let cosmeticPolicies = (materializedCosmeticResources[extensionID] ?? [])
                .flatMap { materialized -> [FloorpWebExtensionUserScriptPolicy] in
                    guard materialized.resource.applies(to: tab),
                          allowsScripting(for: extensionID, in: tab) else {
                        return []
                    }
                    return materialized.policies
                }
            let policies = registeredScriptPolicies + cosmeticPolicies
            guard !policies.isEmpty else { return nil }
            return .init(extensionID: extensionID, scriptPolicies: policies)
        }
    }

    /// Re-checks an already registered bridge message against the exact frame
    /// URL that produced it.  A `WKUserScript` is installed for the imminent
    /// top-level navigation, but it can run in a subframe whose host no longer
    /// has a grant or whose content-script match pattern does not apply.  The
    /// bridge must not turn that injection detail into authority.
    func authorizesBridge(
        for extensionID: FloorpWebExtensionID,
        currentURL: URL,
        isMainFrame: Bool,
        tab: FloorpWebExtensionTabContext
    ) -> Bool {
        let frame = FloorpWebExtensionTabContext(
            tabID: tab.tabID,
            documentGeneration: tab.documentGeneration,
            url: currentURL,
            isPrivate: tab.isPrivate
        )
        guard frame.isPrivate == profileKey.isPrivateBrowsing,
              allowsScripting(
                  for: extensionID,
                  in: frame,
                  activeTabTopLevelURL: tab.url
              ) else {
            return false
        }

        return (materializedScripts[extensionID] ?? []).contains { materialized in
            let script = materialized.script
            return script.world == .isolated &&
                !script.javaScript.isEmpty &&
                (isMainFrame || script.allFrames) &&
                script.matches.contains(where: { $0.matches(currentURL) }) &&
                !script.excludeMatches.contains(where: { $0.matches(currentURL) })
        }
    }

    /// Authenticates one concrete registered all-frame script immediately
    /// before its package body executes. The caller supplies only the script
    /// identifier; extension/profile/document identity and frame URL come from
    /// the nonce-bound native bridge session rather than JavaScript payload.
    func authorizesFrameScript(
        for extensionID: FloorpWebExtensionID,
        scriptID: String,
        revisionToken: String,
        currentURL: URL,
        isMainFrame: Bool,
        tab: FloorpWebExtensionTabContext
    ) -> Bool {
        let frame = FloorpWebExtensionTabContext(
            tabID: tab.tabID,
            documentGeneration: tab.documentGeneration,
            url: currentURL,
            isPrivate: tab.isPrivate
        )
        guard frame.isPrivate == profileKey.isPrivateBrowsing,
              allowsScripting(
                  for: extensionID,
                  in: frame,
                  activeTabTopLevelURL: tab.url
              ),
              let materialized = (materializedScripts[extensionID] ?? []).first(where: {
                  $0.script.id == scriptID && $0.frameAuthorizationRevision == revisionToken
              }) else {
            return false
        }
        let script = materialized.script
        return script.allFrames && script.world == .isolated && !materialized.policies.isEmpty &&
            (isMainFrame || script.allFrames) &&
            script.matches.contains(where: { $0.matches(currentURL) }) &&
            !script.excludeMatches.contains(where: { $0.matches(currentURL) })
    }

    /// Authorizes a dynamic package-file execution against the live main
    /// document. Unlike a content-script bridge, dynamic scripting is not
    /// coupled to an already registered match entry; it still requires the
    /// scripting API grant, current profile, and host access for this tab.
    func authorizesDynamicScripting(
        for extensionID: FloorpWebExtensionID,
        tab: FloorpWebExtensionTabContext
    ) -> Bool {
        tab.isPrivate == profileKey.isPrivateBrowsing && allowsScripting(for: extensionID, in: tab)
    }

    func permissionSnapshot(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionPermissionSnapshot {
        permissionSnapshots[extensionID] ?? .init()
    }

    func registeredScripts(
        for extensionID: FloorpWebExtensionID
    ) async -> [FloorpWebExtensionRegisteredScript] {
        await scriptRegistry.registeredScripts(for: extensionID)
    }

    func dnrSnapshot(
        for extensionID: FloorpWebExtensionID
    ) async -> FloorpWebExtensionDNRPolicySnapshot? {
        guard let store = dnrStores[extensionID] else { return nil }
        return await store.snapshot()
    }

    func configuredDNRLimits(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionDNRLimits? {
        dnrLimits[extensionID]
    }

    func dnrRegexSupport(
        _ regex: String,
        for extensionID: FloorpWebExtensionID
    ) async -> FloorpWebExtensionDNRRegexSupport? {
        guard let store = dnrStores[extensionID] else { return nil }
        return await store.isRegexSupported(regex)
    }

    /// Removes live extension state and WebKit policy without deleting
    /// profile-owned API data. Disable, reload, grant replacement, and
    /// activation rollback all use this reversible path.
    func removeExtension(_ extensionID: FloorpWebExtensionID) async {
        try? await removeExtension(extensionID, purgingAPIData: false)
    }

    /// Final uninstall path. The caller must select this operation explicitly;
    /// a nil reconciliation alone is not evidence that the package was
    /// uninstalled.
    func uninstallExtension(_ extensionID: FloorpWebExtensionID) async throws {
        try await removeExtension(extensionID, purgingAPIData: true)
    }

    private func removeExtension(
        _ extensionID: FloorpWebExtensionID,
        purgingAPIData: Bool
    ) async throws {
        let scriptGate = scriptMutationGate(for: extensionID)
        await scriptGate.acquire()
        defer { Task { await scriptGate.release() } }
        // Revocation participates in the same per-extension gate as
        // every DNR compile-and-swap. If a mutation is already awaiting
        // WebKit, removal waits and then wins; if a mutation is queued behind
        // removal, its permission/store preconditions fail after the gate is
        // released. This prevents stale async compilation from resurrecting a
        // disabled extension's policy.
        let gate = dnrMutationGate(for: extensionID)
        await gate.acquire()
        defer { Task { await gate.release() } }

        // Always revoke callable authority before any fallible durable cleanup.
        // A purge failure therefore leaves an inactive extension plus a
        // package-store tombstone, never a partially deleted live extension.
        await suspendAPIHost(extensionID)
        await scriptRegistry.removeAllScripts(for: extensionID)
        materializedScripts.removeValue(forKey: extensionID)
        materializedCosmeticResources.removeValue(forKey: extensionID)
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
        cssRegistry.discardInsertions(for: extensionID)
        runtime.removePolicies(for: extensionID)
        if purgingAPIData {
            try await purgeAPIHost(extensionID)
        }
    }

    private func refreshScripts(for extensionID: FloorpWebExtensionID) async throws {
        let registered = await scriptRegistry.allRegisteredScripts(for: extensionID)
        let refreshed = try materializedScripts(for: registered, extensionID: extensionID)
        installMaterializedScripts(refreshed, for: extensionID)
    }

    /// Materializes all prospective entries before either durable or live
    /// state changes. This prevents a package-resource failure from leaving a
    /// restored registration with no equivalent pre-navigation policy.
    private func materializedScripts(
        for registered: [FloorpWebExtensionRegisteredScript],
        extensionID: FloorpWebExtensionID
    ) throws -> [MaterializedScript] {
        var refreshed = [MaterializedScript]()
        for script in registered {
            let policies = try materialize(script, for: extensionID)
            refreshed.append(.init(
                script: script,
                policies: policies,
                frameAuthorizationRevision: UUID().uuidString.lowercased()
            ))
        }
        return refreshed
    }

    private func installMaterializedScripts(
        _ refreshed: [MaterializedScript],
        for extensionID: FloorpWebExtensionID
    ) {
        if refreshed.isEmpty {
            materializedScripts.removeValue(forKey: extensionID)
        } else {
            materializedScripts[extensionID] = refreshed
        }
    }

    /// Writes only the explicitly persistent dynamic registrations. The
    /// package store verifies the exact active generation and package resource
    /// inventory before committing. A coordinator without a package store may
    /// still host memory-only registrations, but must reject persistence
    /// rather than silently downgrading it.
    private func persistRegisteredScripts(
        _ scripts: [FloorpWebExtensionRegisteredScript],
        replacing previousScripts: [FloorpWebExtensionRegisteredScript],
        for extensionID: FloorpWebExtensionID,
        expectedPackageGeneration: String?
    ) async throws -> Bool {
        let persistent = scripts.filter(\.persistAcrossSessions)
        let previousPersistent = previousScripts.filter(\.persistAcrossSessions)
        guard let packageStore else {
            guard persistent.isEmpty else {
                throw FloorpWebExtensionError.unsupported(
                    "persistent registered content scripts require a package store"
                )
            }
            return false
        }
        guard let package = await packageStore.installedPackage(for: extensionID) else {
            guard persistent.isEmpty else {
                throw FloorpWebExtensionError.unsupported(
                    "persistent registered content scripts require an installed package"
                )
            }
            return false
        }
        let generation = expectedPackageGeneration ?? package.generation
        guard package.generation == generation else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        guard persistent != previousPersistent else { return false }
        try await packageStore.updatePersistentRegisteredScripts(
            persistent,
            for: extensionID,
            expectedGeneration: generation,
            expectedCurrentScripts: previousPersistent
        )
        return true
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
        in tab: FloorpWebExtensionTabContext,
        activeTabTopLevelURL: URL? = nil
    ) -> Bool {
        let snapshot = permissionSnapshot(for: extensionID)
        guard snapshot.apiPermissions.contains(.scripting) else { return false }
        if tab.isPrivate && !snapshot.privateBrowsingEnabled {
            return false
        }
        let access = tab.isPrivate ? snapshot.privateHostAccess : snapshot.normalHostAccess
        let activeTabAllowsFrame =
            activeTabGrants[extensionID]?.allows(tab, now: now()) == true &&
            (activeTabTopLevelURL.map { Self.hasSameSecurityOrigin(tab.url, $0) } ?? true)
        switch access {
        case .denied:
            return activeTabAllowsFrame
        case .selectedSites(let patterns):
            return patterns.contains(where: { $0.matches(tab.url) }) ||
                activeTabAllowsFrame
        case .allRequestedSites:
            return snapshot.requestedHosts.contains(where: { $0.matches(tab.url) }) ||
                activeTabAllowsFrame
        }
    }

    private static func hasSameSecurityOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else {
            return false
        }
        func effectivePort(_ url: URL, scheme: String) -> Int? {
            url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : nil))
        }
        return lhsScheme == rhsScheme && lhsHost == rhsHost &&
            effectivePort(lhs, scheme: lhsScheme) == effectivePort(rhs, scheme: rhsScheme)
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
        return try await installDNR(
            candidate,
            for: extensionID,
            limits: limits,
            previousSnapshot: snapshot,
            previousLimits: limits,
            persistConfiguration: true
        )
    }

    /// Atomically reconciles the three DNR authorities: the live WebKit
    /// rule-list, this coordinator's validated store, and the package
    /// registry. WebKit must be changed first because its compilation is
    /// asynchronous; if the subsequent registry transaction fails, the
    /// previous policy is compiled again at a newer generation. If that
    /// compensation cannot be installed, remove all live DNR state instead
    /// of retaining a policy that no durable registry state represents.
    private func installDNR(
        _ candidate: FloorpWebExtensionDNRStore,
        for extensionID: FloorpWebExtensionID,
        limits: FloorpWebExtensionDNRLimits,
        previousSnapshot: FloorpWebExtensionDNRPolicySnapshot?,
        previousLimits: FloorpWebExtensionDNRLimits?,
        persistConfiguration: Bool
    ) async throws -> Bool {
        let compilation = await candidate.currentCompilation()
        let applied = try await runtime.compileAndSetDNR(compilation, for: extensionID)
        guard applied else { return false }

        guard persistConfiguration, let packageStore else {
            dnrStores[extensionID] = candidate
            dnrLimits[extensionID] = limits
            return true
        }

        do {
            try await packageStore.updateDNRConfiguration(
                await candidate.persistedConfiguration(),
                for: extensionID
            )
        } catch {
            await restorePreviousDNRPolicyAfterPersistenceFailure(
                for: extensionID,
                previousSnapshot: previousSnapshot,
                previousLimits: previousLimits,
                afterGeneration: compilation.generation
            )
            throw error
        }

        dnrStores[extensionID] = candidate
        dnrLimits[extensionID] = limits
        return true
    }

    private func restorePreviousDNRPolicyAfterPersistenceFailure(
        for extensionID: FloorpWebExtensionID,
        previousSnapshot: FloorpWebExtensionDNRPolicySnapshot?,
        previousLimits: FloorpWebExtensionDNRLimits?,
        afterGeneration: UInt64
    ) async {
        guard let previousSnapshot, let previousLimits else {
            failClosedDNR(for: extensionID)
            return
        }

        do {
            let restoredStore = try FloorpWebExtensionDNRStore(
                replaying: previousSnapshot,
                limits: previousLimits,
                minimumGeneration: afterGeneration &+ 1
            )
            let restored = try await runtime.compileAndSetDNR(
                await restoredStore.currentCompilation(),
                for: extensionID
            )
            guard restored else {
                failClosedDNR(for: extensionID)
                return
            }
            dnrStores[extensionID] = restoredStore
            dnrLimits[extensionID] = previousLimits
        } catch {
            failClosedDNR(for: extensionID)
        }
    }

    private func failClosedDNR(for extensionID: FloorpWebExtensionID) {
        runtime.removePolicies(for: extensionID)
        dnrStores.removeValue(forKey: extensionID)
        dnrLimits.removeValue(forKey: extensionID)
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

    private func scriptMutationGate(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionScriptMutationGate {
        if let existing = scriptMutationGates[extensionID] {
            return existing
        }
        let gate = FloorpWebExtensionScriptMutationGate()
        scriptMutationGates[extensionID] = gate
        return gate
    }

    private func validateProfile(_ tab: FloorpWebExtensionTabContext) throws {
        guard tab.isPrivate == profileKey.isPrivateBrowsing else {
            throw FloorpWebExtensionError.permissionDenied("profile mode")
        }
    }

    nonisolated static func styleInjectionSource(_ css: String) throws -> String {
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
            .union(materializedCosmeticResources.keys)
            .union(dnrStores.keys)
            .union(permissionSnapshots.keys)
        extensionIDs.forEach(runtime.removePolicies(for:))
        materializedScripts.removeAll()
        materializedCosmeticResources.removeAll()
        permissionSnapshots.removeAll()
        activeTabGrants.removeAll()
        dnrStores.removeAll()
        dnrLimits.removeAll()
        dnrMutationGates.removeAll()
        scriptMutationGates.removeAll()
    }
}
