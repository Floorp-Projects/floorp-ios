// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import WebKit
import CryptoKit

/// The profile-scoped compiler used by ``FloorpWebExtensionRuntime`` for DNR.
///
/// A profile owns its `WKContentRuleListStore`; injecting this boundary keeps
/// private and normal profiles from sharing compiled rule-list state and makes
/// the asynchronous WebKit compilation boundary explicit.
@MainActor
protocol FloorpWebExtensionContentRuleListCompiling: AnyObject {
    func compileContentRuleList(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList

    func removeContentRuleList(forIdentifier identifier: String) async
}

@MainActor
final class FloorpWKContentRuleListStoreCompiler: FloorpWebExtensionContentRuleListCompiling {
    private let store: WKContentRuleListStore

    init(store: WKContentRuleListStore) {
        self.store = store
    }

    func compileContentRuleList(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedContentRuleList
            ) { contentRuleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let contentRuleList {
                    continuation.resume(returning: contentRuleList)
                } else {
                    continuation.resume(throwing: FloorpWebExtensionRuntimeError.missingCompiledRuleList)
                }
            }
        }
    }

    func removeContentRuleList(forIdentifier identifier: String) async {
        await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}

enum FloorpWebExtensionRuntimeError: Error, LocalizedError {
    case missingCompiledRuleList
    case contentRuleListStoreNotConfigured

    var errorDescription: String? {
        switch self {
        case .missingCompiledRuleList:
            return "WebKit did not return a compiled content rule list."
        case .contentRuleListStoreNotConfigured:
            return "The WebExtensions profile content-rule-list store is not configured."
        }
    }
}

/// The app-wide runtime deliberately starts without a rule-list store.
///
/// A `WKContentRuleListStore` is profile scoped. Falling back to WebKit's
/// default store would make private and normal profile DNR caches share state.
@MainActor
private final class FloorpUnconfiguredContentRuleListCompiler: FloorpWebExtensionContentRuleListCompiling {
    func compileContentRuleList(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList {
        throw FloorpWebExtensionRuntimeError.contentRuleListStoreNotConfigured
    }

    func removeContentRuleList(forIdentifier identifier: String) async {}
}

/// A small, test-visible summary of one extension's live WebKit policy.
struct FloorpWebExtensionRuntimePolicySnapshot: Equatable {
    let userScriptCount: Int
    let contentRuleListCount: Int
    let dnrGeneration: UInt64?
}

/// Identifies one isolated extension runtime and its injected rule-list store.
/// Normal and private tabs intentionally never share this key.
struct FloorpWebExtensionRuntimeProfileKey: Hashable, Sendable {
    let profileIdentifier: String
    let isPrivateBrowsing: Bool

    init(profileIdentifier: String, isPrivateBrowsing: Bool) {
        self.profileIdentifier = profileIdentifier
        self.isPrivateBrowsing = isPrivateBrowsing
    }
}

/// A WebExtensions script after package/resource validation, but before it is
/// materialized as a WebKit object. Keeping the execution world in this value
/// prevents arbitrary `WKUserScript` objects from bypassing extension isolation.
struct FloorpWebExtensionUserScriptPolicy: Sendable {
    let source: String
    let runAt: FloorpWebExtensionRunAt
    let allFrames: Bool
    let world: FloorpWebExtensionExecutionWorld
    let frameAuthorization: FloorpWebExtensionFrameScriptAuthorization?

    init(
        source: String,
        runAt: FloorpWebExtensionRunAt = .documentIdle,
        allFrames: Bool = false,
        world: FloorpWebExtensionExecutionWorld = .isolated,
        frameAuthorization: FloorpWebExtensionFrameScriptAuthorization? = nil
    ) {
        self.source = source
        self.runAt = runAt
        self.allFrames = allFrames
        self.world = world
        self.frameAuthorization = frameAuthorization
    }
}

/// Native-created identity for one materialized registered-script revision.
/// The random token prevents an old controller-local policy from borrowing a
/// newer registration that reused the same manifest script identifier.
struct FloorpWebExtensionFrameScriptAuthorization: Sendable {
    let scriptID: String
    let revisionToken: String
}

/// The MainActor bridge from extension policy output to a tab's WebKit policy.
///
/// The runtime stores one policy per extension and is the only WebExtensions
/// caller of `FloorpWebContentPolicyCoordinator`. It applies the complete
/// snapshot before a tab's first navigation, and replaces policies by owner so
/// updates cannot leave old scripts or DNR rules attached to a controller.
@MainActor
final class FloorpWebExtensionRuntime {
    /// Runtime instances are separated by profile and private-browsing mode.
    /// Composition injects a profile-owned rule-list store with ``install``.
    private static var runtimes = [FloorpWebExtensionRuntimeProfileKey: FloorpWebExtensionRuntime]()

    private struct ExtensionPolicy {
        var userScripts = [WKUserScript]()
        var contentRuleLists = [WKContentRuleList]()
        var dnrContentRuleList: WKContentRuleList?
        var dnrRuleListIdentifier: String?
        var dnrGeneration: UInt64?

        var allContentRuleLists: [WKContentRuleList] {
            contentRuleLists + (dnrContentRuleList.map { [$0] } ?? [])
        }

        var isEmpty: Bool {
            userScripts.isEmpty && contentRuleLists.isEmpty && dnrContentRuleList == nil && dnrGeneration == nil
        }
    }

    private struct DNRRequest: Equatable {
        let generation: UInt64
        let payloadDigest: [UInt8]
        let token: UInt64
    }

    /// Tracks a dynamic stylesheet without retaining its tab. This lets an
    /// uninstall or feature disable retract styles that were already applied
    /// to a still-live document.
    private final class AppliedCSSInsertion {
        weak var webView: WKWebView?
        let insertion: FloorpWebExtensionCSSInsertion

        init(webView: WKWebView, insertion: FloorpWebExtensionCSSInsertion) {
            self.webView = webView
            self.insertion = insertion
        }
    }

    private let contentRuleListCompiler: any FloorpWebExtensionContentRuleListCompiling
    private let managedControllers = NSHashTable<WKUserContentController>.weakObjects()
    private var policies = [FloorpWebExtensionID: ExtensionPolicy]()
    private var appliedOwnersByController = [ObjectIdentifier: Set<String>]()
    private var appliedCSSInsertions = [FloorpWebExtensionID: [AppliedCSSInsertion]]()
    private var dnrRequestTokens = [FloorpWebExtensionID: UInt64]()
    private var latestDNRRequests = [FloorpWebExtensionID: DNRRequest]()

    private init() {
        contentRuleListCompiler = FloorpUnconfiguredContentRuleListCompiler()
    }

    /// Creates a runtime for one browser profile.
    init(contentRuleListStore: WKContentRuleListStore) {
        contentRuleListCompiler = FloorpWKContentRuleListStoreCompiler(store: contentRuleListStore)
    }

    /// Dependency-injection initializer used by profile composition and tests.
    init(contentRuleListCompiler: any FloorpWebExtensionContentRuleListCompiling) {
        self.contentRuleListCompiler = contentRuleListCompiler
    }

    /// Returns the runtime for one profile and browsing mode.
    ///
    /// Before composition installs a profile-specific compiler, the returned
    /// runtime accepts script policy but rejects DNR compilation. This fails
    /// closed instead of sharing WebKit's default store with another profile.
    static func runtime(
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) -> FloorpWebExtensionRuntime {
        let key = FloorpWebExtensionRuntimeProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        if let runtime = runtimes[key] {
            return runtime
        }
        let runtime = FloorpWebExtensionRuntime()
        runtimes[key] = runtime
        return runtime
    }

    /// Installs a runtime assembled with this profile's own content-rule-list
    /// store. Call before its tabs begin navigation.
    static func install(
        _ runtime: FloorpWebExtensionRuntime,
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) {
        let key = FloorpWebExtensionRuntimeProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        let replacedRuntime = runtimes.updateValue(runtime, forKey: key)
        // A replacement is a profile-generation boundary. Fully tear down the
        // old runtime so an in-flight compile cannot attach its obsolete rule
        // list to a controller after this profile has installed a new store.
        replacedRuntime?.tearDown()
    }

    /// Removes the runtime for a profile that is being torn down.
    static func removeRuntime(
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) {
        let key = FloorpWebExtensionRuntimeProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        runtimes.removeValue(forKey: key)?.tearDown()
    }

    /// The feature-flag hook used after core WebExtensions is disabled.
    /// It removes extension-owned policies from every live controller now,
    /// without waiting for a future navigation or tab creation.
    static func clearAllPoliciesForDisabledCoreFeature() {
        runtimes.values.forEach { $0.removeAppliedPoliciesFromManagedControllers() }
    }

    /// Registers a controller and applies the current extension policy before
    /// its first navigation. It is safe to call again for an existing tab.
    func apply(to webView: WKWebView) {
        apply(to: webView.configuration.userContentController)
    }

    /// Registers a controller and applies the current extension policy before
    /// its first navigation. This overload keeps the lifecycle testable without
    /// constructing a full browser tab.
    func apply(to controller: WKUserContentController) {
        managedControllers.add(controller)
        applyCurrentPolicies(to: controller)
    }

    /// Removes the prior navigation's controller-local content scripts before
    /// a coordinator applies the next navigation snapshot. DNR and other
    /// profile-wide owners are deliberately retained.
    func clearPreNavigationPolicies(from controller: WKUserContentController) {
        let controllerID = ObjectIdentifier(controller)
        let coordinator = FloorpWebContentPolicyCoordinator.coordinator(for: controller)
        let localOwners = (appliedOwnersByController[controllerID] ?? []).filter {
            $0.hasPrefix(Self.preNavigationOwnerPrefix)
        }
        for owner in localOwners {
            coordinator.removeUserScripts(ownedBy: owner)
        }
        appliedOwnersByController[controllerID]?.subtract(localOwners)
    }

    /// Replaces one extension's scripts for one imminent navigation. The owner
    /// includes the controller identity so a URL/grant-qualified snapshot can
    /// never be replayed into another tab during a later reconciliation.
    func applyPreNavigationPolicy(
        _ snapshot: FloorpWebExtensionNavigationPolicySnapshot,
        to controller: WKUserContentController
    ) {
        managedControllers.add(controller)
        let owner = Self.preNavigationOwner(for: snapshot.extensionID, controller: controller)
        let coordinator = FloorpWebContentPolicyCoordinator.coordinator(for: controller)
        guard FloorpFlags.isWebExtensionFeatureEnabled(.core) else {
            coordinator.removeUserScripts(ownedBy: owner)
            appliedOwnersByController[ObjectIdentifier(controller)]?.remove(owner)
            return
        }

        let scripts = snapshot.scriptPolicies.map {
            Self.makeUserScript(from: $0, for: snapshot.extensionID)
        }
        coordinator.replaceUserScripts(scripts, ownedBy: owner)
        appliedOwnersByController[ObjectIdentifier(controller), default: []].insert(owner)
    }

    /// Applies an already-authorized CSS insertion to the current main-frame
    /// document. Subframe targets are rejected by the coordinator because a
    /// `WKWebView` alone does not identify a safe `WKFrameInfo` target.
    func applyCSSInsertion(_ insertion: FloorpWebExtensionCSSInsertion, to webView: WKWebView) {
        guard FloorpFlags.isWebExtensionFeatureEnabled(.core) else { return }
        let identifier = Self.cssElementIdentifier(insertion)
        let script = Self.cssInsertionJavaScript(identifier: identifier, css: insertion.css)
        webView.evaluateJavaScript(script) { _, _ in }
        let retained = (appliedCSSInsertions[insertion.extensionID] ?? []).filter {
            guard let existingWebView = $0.webView else { return false }
            return existingWebView !== webView || $0.insertion.handle != insertion.handle
        }
        appliedCSSInsertions[insertion.extensionID] = retained + [
            AppliedCSSInsertion(webView: webView, insertion: insertion)
        ]
    }

    /// Removes CSS inserted by ``applyCSSInsertion(_:to:)`` from the current
    /// main-frame document. Each removal is handle-scoped to its extension.
    func removeCSSInsertions(_ insertions: [FloorpWebExtensionCSSInsertion], from webView: WKWebView) {
        for insertion in insertions {
            let script = Self.cssRemovalJavaScript(identifier: Self.cssElementIdentifier(insertion))
            webView.evaluateJavaScript(script) { _, _ in }
        }
        let removedHandles = Set(insertions.map(\.handle))
        for extensionID in Set(insertions.map(\.extensionID)) {
            let retained = (appliedCSSInsertions[extensionID] ?? []).filter {
                guard let existingWebView = $0.webView else { return false }
                return existingWebView !== webView || !removedHandles.contains($0.insertion.handle)
            }
            if retained.isEmpty {
                appliedCSSInsertions.removeValue(forKey: extensionID)
            } else {
                appliedCSSInsertions[extensionID] = retained
            }
        }
    }

    /// Replaces every script owned by one extension with policy-derived WebKit
    /// scripts. Callers cannot provide a raw `WKUserScript`, which would let a
    /// MAIN-world script accidentally receive an extension bridge.
    func setScriptPolicies(
        _ scriptPolicies: [FloorpWebExtensionUserScriptPolicy],
        for extensionID: FloorpWebExtensionID
    ) {
        var policy = policies[extensionID] ?? ExtensionPolicy()
        policy.userScripts = scriptPolicies.map {
            Self.makeUserScript(from: $0, for: extensionID)
        }
        store(policy, for: extensionID)
        synchronizeManagedControllers()
    }

    /// Replaces non-DNR content rule lists owned by one extension.
    ///
    /// DNR output is managed separately by ``compileAndSetDNR(_:for:)`` so an
    /// asynchronous DNR compilation cannot discard other policy sources.
    func setContentRuleLists(_ contentRuleLists: [WKContentRuleList], for extensionID: FloorpWebExtensionID) {
        var policy = policies[extensionID] ?? ExtensionPolicy()
        policy.contentRuleLists = contentRuleLists
        store(policy, for: extensionID)
        synchronizeManagedControllers()
    }

    /// Removes all script and content-rule-list state for one extension.
    ///
    /// An in-flight DNR compilation is invalidated before live policies are
    /// reconciled, so it cannot reattach policy after an uninstall/disable.
    func removePolicies(for extensionID: FloorpWebExtensionID) {
        _ = nextDNRRequestToken(for: extensionID)
        latestDNRRequests.removeValue(forKey: extensionID)
        let removedPolicy = policies.removeValue(forKey: extensionID)
        removePreNavigationPolicies(for: extensionID)
        removeAppliedCSSInsertions(for: extensionID)
        synchronizeManagedControllers()

        if let identifier = removedPolicy?.dnrRuleListIdentifier {
            removeCompiledRuleList(identifier)
        }
    }

    /// Compiles DNR output in this runtime's injected profile store, then
    /// atomically replaces that extension's active DNR rule list.
    ///
    /// Returns `false` when a newer request or extension removal superseded
    /// this asynchronous result. In that case the just-compiled store entry is
    /// discarded and no old or new live policy is changed.
    @discardableResult
    func compileAndSetDNR(
        _ compilation: FloorpWebExtensionDNRCompilation,
        for extensionID: FloorpWebExtensionID
    ) async throws -> Bool {
        guard !compilation.report.hasRejections else {
            throw FloorpWebExtensionDNRError.incompatibleRules(compilation.report)
        }
        let payloadDigest = Self.dnrPayloadDigest(compilation.webKitContentRuleJSON)
        if let latestRequest = latestDNRRequests[extensionID] {
            guard compilation.generation >= latestRequest.generation else {
                return false
            }
            guard compilation.generation != latestRequest.generation ||
                    payloadDigest == latestRequest.payloadDigest else {
                return false
            }
        }

        let requestToken = nextDNRRequestToken(for: extensionID)
        let request = DNRRequest(
            generation: compilation.generation,
            payloadDigest: payloadDigest,
            token: requestToken
        )
        latestDNRRequests[extensionID] = request

        // WebKit rejects an empty rule-list JSON array (WKErrorDomain code 6).
        // An empty DNR compilation is nevertheless a valid desired state: it
        // means the extension has no effective network rules. Remove its prior
        // list atomically and retain the generation for stale-request ordering.
        guard !Self.isEmptyContentRuleList(compilation) else {
            var policy = policies[extensionID] ?? ExtensionPolicy()
            let previousIdentifier = policy.dnrRuleListIdentifier
            policy.dnrContentRuleList = nil
            policy.dnrRuleListIdentifier = nil
            policy.dnrGeneration = compilation.generation
            store(policy, for: extensionID)
            synchronizeManagedControllers()
            if let previousIdentifier {
                removeCompiledRuleList(previousIdentifier)
            }
            return true
        }

        let identifier = Self.dnrRuleListIdentifier(
            for: extensionID,
            compilationGeneration: compilation.generation,
            requestToken: requestToken
        )
        let contentRuleList = try await contentRuleListCompiler.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: compilation.webKitContentRuleJSON
        )

        guard latestDNRRequests[extensionID] == request else {
            // This list was compiled, but a newer request now owns the
            // extension policy. Await removal before completing the stale
            // request so callers never observe an orphaned rule-list entry.
            await contentRuleListCompiler.removeContentRuleList(forIdentifier: identifier)
            return false
        }

        var policy = policies[extensionID] ?? ExtensionPolicy()
        let previousIdentifier = policy.dnrRuleListIdentifier
        policy.dnrContentRuleList = contentRuleList
        policy.dnrRuleListIdentifier = identifier
        policy.dnrGeneration = compilation.generation
        store(policy, for: extensionID)
        synchronizeManagedControllers()

        if let previousIdentifier, previousIdentifier != identifier {
            removeCompiledRuleList(previousIdentifier)
        }
        return true
    }

    func policySnapshot(for extensionID: FloorpWebExtensionID) -> FloorpWebExtensionRuntimePolicySnapshot? {
        guard let policy = policies[extensionID] else { return nil }
        return FloorpWebExtensionRuntimePolicySnapshot(
            userScriptCount: policy.userScripts.count,
            contentRuleListCount: policy.allContentRuleLists.count,
            dnrGeneration: policy.dnrGeneration
        )
    }

    static func owner(for extensionID: FloorpWebExtensionID) -> String {
        "floorp.webextension.\(extensionID.rawValue)"
    }

    private static let preNavigationOwnerPrefix = "floorp.webextension.navigation."

    private static func preNavigationOwner(
        for extensionID: FloorpWebExtensionID,
        controller: WKUserContentController
    ) -> String {
        "\(preNavigationOwnerPrefix)\(extensionID.rawValue).\(ObjectIdentifier(controller))"
    }

    static func dnrRuleListIdentifier(
        for extensionID: FloorpWebExtensionID,
        compilationGeneration: UInt64,
        requestToken: UInt64
    ) -> String {
        "floorp.webextension.dnr.\(extensionID.rawValue).\(compilationGeneration).\(requestToken)"
    }

    static func isolatedContentWorldName(for extensionID: FloorpWebExtensionID) -> String {
        "floorp.webextension.content.\(extensionID.rawValue)"
    }

    private func store(_ policy: ExtensionPolicy, for extensionID: FloorpWebExtensionID) {
        if policy.isEmpty {
            policies.removeValue(forKey: extensionID)
        } else {
            policies[extensionID] = policy
        }
    }

    private func nextDNRRequestToken(for extensionID: FloorpWebExtensionID) -> UInt64 {
        let next = (dnrRequestTokens[extensionID] ?? 0) &+ 1
        dnrRequestTokens[extensionID] = next
        return next
    }

    private static func makeUserScript(
        from policy: FloorpWebExtensionUserScriptPolicy,
        for extensionID: FloorpWebExtensionID
    ) -> WKUserScript {
        let injectionTime: WKUserScriptInjectionTime
        switch policy.runAt {
        case .documentStart:
            injectionTime = .atDocumentStart
        case .documentEnd, .documentIdle:
            // WebKit has no document-idle timing; document end is the supported
            // deterministic approximation used by the MV3 policy layer.
            injectionTime = .atDocumentEnd
        }

        let contentWorld: WKContentWorld
        switch policy.world {
        case .main:
            // A MAIN-world policy receives exactly its package script. No
            // extension bridge is prepended or otherwise exposed here.
            contentWorld = .page
        case .isolated:
            contentWorld = .world(name: isolatedContentWorldName(for: extensionID))
        }
        let source: String
        if policy.allFrames {
            switch (policy.world, policy.frameAuthorization) {
            case (.isolated, .some(let authorization)):
                source = authenticatedAllFramesSource(policy.source, authorization: authorization)
            case (.main, _), (_, .none):
                // MAIN-world page code can replace every JavaScript guard and
                // must never receive the authenticated native bridge. Until
                // WebKit exposes URL-scoped frame injection, fail closed rather
                // than execute package code under stale or page-forged policy.
                source = "void 0;"
            }
        } else {
            source = policy.source
        }
        return WKUserScript(
            source: source,
            injectionTime: injectionTime,
            forMainFrameOnly: !policy.allFrames,
            in: contentWorld
        )
    }

    /// Defers an isolated all-frame package body until the nonce-authenticated
    /// native bridge re-checks this exact frame and registered script against
    /// live profile grants. Host revocation, activeTab expiry, navigation, and
    /// native Unicode match semantics are therefore observed at execution
    /// time rather than frozen into a pre-navigation JavaScript snapshot.
    private static func authenticatedAllFramesSource(
        _ packageSource: String,
        authorization: FloorpWebExtensionFrameScriptAuthorization
    ) -> String {
        let functionLiteral = javaScriptStringLiteral(
            FloorpWebExtensionMessageRuntime.frameAuthorizationFunctionName
        )
        let scriptLiteral = javaScriptStringLiteral(authorization.scriptID)
        let revisionLiteral = javaScriptStringLiteral(authorization.revisionToken)
        return """
        (async () => {
          const authorizeFrame = globalThis[\(functionLiteral)];
          if (typeof authorizeFrame !== "function") return;
          let authorized = false;
          try {
            authorized = await authorizeFrame(\(scriptLiteral), \(revisionLiteral));
          } catch (_) {
            return;
          }
          if (!authorized) return;
          (function() {
        \(packageSource)
          }).call(globalThis);
        })();
        """
    }

    private static func dnrPayloadDigest(_ contentRuleJSON: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(contentRuleJSON.utf8)))
    }

    private static func isEmptyContentRuleList(_ compilation: FloorpWebExtensionDNRCompilation) -> Bool {
        compilation.compiledRules.isEmpty &&
            compilation.webKitContentRuleJSON.trimmingCharacters(in: .whitespacesAndNewlines) == "[]"
    }

    private static func cssElementIdentifier(_ insertion: FloorpWebExtensionCSSInsertion) -> String {
        "floorp-webextension-css-\(insertion.extensionID.rawValue)-\(insertion.handle.rawValue)"
    }

    private static func cssInsertionJavaScript(identifier: String, css: String) -> String {
        let identifierLiteral = javaScriptStringLiteral(identifier)
        let cssLiteral = javaScriptStringLiteral(css)
        return """
        (function() {
          const identifier = \(identifierLiteral);
          const css = \(cssLiteral);
          const styles = Array.from(document.querySelectorAll('style[data-floorp-webextension-css]'));
          let style = styles.find((element) => element.dataset.floorpWebextensionCss === identifier);
          if (!style) {
            style = document.createElement('style');
            style.dataset.floorpWebextensionCss = identifier;
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = css;
        })();
        """
    }

    private static func cssRemovalJavaScript(identifier: String) -> String {
        let identifierLiteral = javaScriptStringLiteral(identifier)
        return """
        (function() {
          const identifier = \(identifierLiteral);
          Array.from(document.querySelectorAll('style[data-floorp-webextension-css]'))
            .filter((element) => element.dataset.floorpWebextensionCss === identifier)
            .forEach((element) => element.remove());
        })();
        """
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            // A Swift String always encodes as JSON, but returning an empty
            // literal fails closed if Foundation ever reports an error.
            return "\"\""
        }
        return literal
    }

    private func synchronizeManagedControllers() {
        let liveControllers = managedControllers.allObjects
        let liveControllerIDs = Set(liveControllers.map(ObjectIdentifier.init))
        appliedOwnersByController = appliedOwnersByController.filter { liveControllerIDs.contains($0.key) }
        liveControllers.forEach(applyCurrentPolicies(to:))
    }

    private func removeAppliedPoliciesFromManagedControllers() {
        let liveControllers = managedControllers.allObjects
        let liveControllerIDs = Set(liveControllers.map(ObjectIdentifier.init))
        appliedOwnersByController = appliedOwnersByController.filter { liveControllerIDs.contains($0.key) }
        for controller in liveControllers {
            let controllerID = ObjectIdentifier(controller)
            let coordinator = FloorpWebContentPolicyCoordinator.coordinator(for: controller)
            for owner in appliedOwnersByController[controllerID] ?? [] {
                coordinator.removeUserScripts(ownedBy: owner)
                coordinator.removeContentRuleLists(ownedBy: owner)
            }
            appliedOwnersByController[controllerID] = []
        }
        removeAllAppliedCSSInsertions()
    }

    private func tearDown() {
        let extensionIDs = Set(policies.keys)
            .union(dnrRequestTokens.keys)
            .union(latestDNRRequests.keys)
        for extensionID in extensionIDs {
            _ = nextDNRRequestToken(for: extensionID)
        }
        latestDNRRequests.removeAll()

        let dnrIdentifiers = policies.values.compactMap(\.dnrRuleListIdentifier)
        policies.removeAll()
        removeAppliedPoliciesFromManagedControllers()
        dnrIdentifiers.forEach(removeCompiledRuleList)
    }

    private func removePreNavigationPolicies(for extensionID: FloorpWebExtensionID) {
        let ownerPrefix = "\(Self.preNavigationOwnerPrefix)\(extensionID.rawValue)."
        for controller in managedControllers.allObjects {
            let controllerID = ObjectIdentifier(controller)
            let owners = (appliedOwnersByController[controllerID] ?? []).filter {
                $0.hasPrefix(ownerPrefix)
            }
            guard !owners.isEmpty else { continue }
            let coordinator = FloorpWebContentPolicyCoordinator.coordinator(for: controller)
            for owner in owners {
                coordinator.removeUserScripts(ownedBy: owner)
            }
            appliedOwnersByController[controllerID]?.subtract(owners)
        }
    }

    private func removeAppliedCSSInsertions(for extensionID: FloorpWebExtensionID) {
        guard let applied = appliedCSSInsertions.removeValue(forKey: extensionID) else { return }
        for record in applied {
            guard let webView = record.webView else { continue }
            let script = Self.cssRemovalJavaScript(
                identifier: Self.cssElementIdentifier(record.insertion)
            )
            webView.evaluateJavaScript(script) { _, _ in }
        }
    }

    private func removeAllAppliedCSSInsertions() {
        let extensionIDs = Array(appliedCSSInsertions.keys)
        extensionIDs.forEach(removeAppliedCSSInsertions(for:))
    }

    private func applyCurrentPolicies(to controller: WKUserContentController) {
        let controllerID = ObjectIdentifier(controller)
        let coordinator = FloorpWebContentPolicyCoordinator.coordinator(for: controller)
        let previousOwners = appliedOwnersByController[controllerID] ?? []

        guard FloorpFlags.isWebExtensionFeatureEnabled(.core) else {
            previousOwners.forEach { owner in
                coordinator.removeUserScripts(ownedBy: owner)
                coordinator.removeContentRuleLists(ownedBy: owner)
            }
            appliedOwnersByController[controllerID] = []
            return
        }

        let currentOwners = Set(policies.keys.map(Self.owner(for:)))
        let localOwners = previousOwners.filter { $0.hasPrefix(Self.preNavigationOwnerPrefix) }
        for extensionID in policies.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let policy = policies[extensionID] else { continue }
            let owner = Self.owner(for: extensionID)
            coordinator.replaceUserScripts(policy.userScripts, ownedBy: owner)
            coordinator.replaceContentRuleLists(policy.allContentRuleLists, ownedBy: owner)
        }
        for owner in previousOwners.subtracting(currentOwners).subtracting(localOwners) {
            coordinator.removeUserScripts(ownedBy: owner)
            coordinator.removeContentRuleLists(ownedBy: owner)
        }
        appliedOwnersByController[controllerID] = currentOwners.union(localOwners)
    }

    private func removeCompiledRuleList(_ identifier: String) {
        Task { [contentRuleListCompiler] in
            await contentRuleListCompiler.removeContentRuleList(forIdentifier: identifier)
        }
    }
}
