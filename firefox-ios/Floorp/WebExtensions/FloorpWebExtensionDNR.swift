// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// A scope with the same lifetime semantics as Manifest V3 DNR rules.
///
/// Dynamic rules are suitable for persistence by the caller. Session rules are
/// deliberately kept in this actor only and can be discarded with
/// ``clearSessionRules()`` when a browser session ends.
enum FloorpWebExtensionDNRRuleScope: String, Codable, Sendable {
    case staticRules = "static"
    case dynamic
    case session
}

enum FloorpWebExtensionDNRActionType: String, Codable, Sendable {
    case block
    case allow
    case allowAllRequests
    case upgradeScheme
    case redirect
    case modifyHeaders
}

struct FloorpWebExtensionDNRAction: Hashable, Codable, Sendable {
    let type: FloorpWebExtensionDNRActionType
}

enum FloorpWebExtensionDNRResourceType: String, Codable, CaseIterable, Sendable {
    case mainFrame = "main_frame"
    case subFrame = "sub_frame"
    case stylesheet
    case script
    case image
    case font
    case object
    case xmlHttpRequest = "xmlhttprequest"
    case ping
    case cspReport = "csp_report"
    case media
    case websocket
    case webTransport = "webtransport"
    case webBundle = "webbundle"
    case other
}

enum FloorpWebExtensionDNRDomainType: String, Codable, Sendable {
    case firstParty
    case thirdParty
}

/// The DNR condition fields represented here intentionally include fields that
/// iOS 15 WebKit cannot express. Their presence is reported and rejects an
/// update; silently ignoring them would make an extension claim protection it
/// does not have.
struct FloorpWebExtensionDNRCondition: Hashable, Codable, Sendable {
    var urlFilter: String?
    var regexFilter: String?
    var isUrlFilterCaseSensitive: Bool?
    var requestDomains: [String]
    var excludedRequestDomains: [String]
    var initiatorDomains: [String]
    var excludedInitiatorDomains: [String]
    var resourceTypes: [FloorpWebExtensionDNRResourceType]
    var excludedResourceTypes: [FloorpWebExtensionDNRResourceType]
    var domainType: FloorpWebExtensionDNRDomainType?
    var tabIDs: [Int]
    var excludedTabIDs: [Int]
    var requestMethods: [String]
    var responseHeaders: [String]
    var excludedResponseHeaders: [String]

    init(
        urlFilter: String? = nil,
        regexFilter: String? = nil,
        isUrlFilterCaseSensitive: Bool? = nil,
        requestDomains: [String] = [],
        excludedRequestDomains: [String] = [],
        initiatorDomains: [String] = [],
        excludedInitiatorDomains: [String] = [],
        resourceTypes: [FloorpWebExtensionDNRResourceType] = [],
        excludedResourceTypes: [FloorpWebExtensionDNRResourceType] = [],
        domainType: FloorpWebExtensionDNRDomainType? = nil,
        tabIDs: [Int] = [],
        excludedTabIDs: [Int] = [],
        requestMethods: [String] = [],
        responseHeaders: [String] = [],
        excludedResponseHeaders: [String] = []
    ) {
        self.urlFilter = urlFilter
        self.regexFilter = regexFilter
        self.isUrlFilterCaseSensitive = isUrlFilterCaseSensitive
        self.requestDomains = requestDomains
        self.excludedRequestDomains = excludedRequestDomains
        self.initiatorDomains = initiatorDomains
        self.excludedInitiatorDomains = excludedInitiatorDomains
        self.resourceTypes = resourceTypes
        self.excludedResourceTypes = excludedResourceTypes
        self.domainType = domainType
        self.tabIDs = tabIDs
        self.excludedTabIDs = excludedTabIDs
        self.requestMethods = requestMethods
        self.responseHeaders = responseHeaders
        self.excludedResponseHeaders = excludedResponseHeaders
    }
}

struct FloorpWebExtensionDNRRule: Hashable, Codable, Sendable {
    let id: Int
    let priority: Int
    let action: FloorpWebExtensionDNRAction
    let condition: FloorpWebExtensionDNRCondition

    init(
        id: Int,
        priority: Int = 1,
        action: FloorpWebExtensionDNRAction,
        condition: FloorpWebExtensionDNRCondition = .init()
    ) {
        self.id = id
        self.priority = priority
        self.action = action
        self.condition = condition
    }
}

struct FloorpWebExtensionDNRStaticRuleSet: Hashable, Codable, Sendable {
    let identifier: String
    let rules: [FloorpWebExtensionDNRRule]
}

struct FloorpWebExtensionDNRLimits: Hashable, Codable, Sendable {
    let maxStaticRules: Int
    let maxEnabledStaticRuleSets: Int
    let maxDynamicRules: Int
    let maxSessionRules: Int
    let maxRulesPerUpdate: Int

    init(
        maxStaticRules: Int = 50_000,
        maxEnabledStaticRuleSets: Int = 50,
        maxDynamicRules: Int = 5_000,
        maxSessionRules: Int = 5_000,
        maxRulesPerUpdate: Int = 1_000
    ) {
        self.maxStaticRules = maxStaticRules
        self.maxEnabledStaticRuleSets = maxEnabledStaticRuleSets
        self.maxDynamicRules = maxDynamicRules
        self.maxSessionRules = maxSessionRules
        self.maxRulesPerUpdate = maxRulesPerUpdate
    }
}

enum FloorpWebExtensionDNRCompatibilityStatus: String, Codable, Sendable {
    case accepted
    case transformed
    case rejected
}

struct FloorpWebExtensionDNRRuleOrigin: Hashable, Codable, Sendable {
    let scope: FloorpWebExtensionDNRRuleScope
    let staticRuleSetID: String?

    init(scope: FloorpWebExtensionDNRRuleScope, staticRuleSetID: String? = nil) {
        self.scope = scope
        self.staticRuleSetID = staticRuleSetID
    }
}

struct FloorpWebExtensionDNRCompatibilityEntry: Hashable, Codable, Sendable {
    let ruleID: Int
    let origin: FloorpWebExtensionDNRRuleOrigin
    let status: FloorpWebExtensionDNRCompatibilityStatus
    let reasons: [String]
}

/// Machine-readable diagnostics that can be stored next to an installed
/// extension and shown before a ruleset is enabled.
struct FloorpWebExtensionDNRCompatibilityReport: Codable, Sendable {
    let entries: [FloorpWebExtensionDNRCompatibilityEntry]
    let acceptedRuleCount: Int
    let transformedRuleCount: Int
    let rejectedRuleCount: Int
    let countsByReason: [String: Int]

    init(entries: [FloorpWebExtensionDNRCompatibilityEntry]) {
        self.entries = entries
        acceptedRuleCount = entries.filter { $0.status == .accepted }.count
        transformedRuleCount = entries.filter { $0.status == .transformed }.count
        rejectedRuleCount = entries.filter { $0.status == .rejected }.count
        countsByReason = entries
            .flatMap(\.reasons)
            .reduce(into: [:]) { counts, reason in
                counts[reason, default: 0] += 1
            }
    }

    var hasRejections: Bool {
        rejectedRuleCount > 0
    }

    static let empty = FloorpWebExtensionDNRCompatibilityReport(entries: [])
}

struct FloorpWebExtensionDNRCompiledRule: Hashable, Codable, Sendable {
    let ruleID: Int
    let origin: FloorpWebExtensionDNRRuleOrigin
    /// A single JSON object in the WKContentRuleList grammar.
    let webKitRuleJSON: String
}

/// Foundation-only compilation output. A WebKit owner is responsible for
/// compiling this JSON in its profile-scoped `WKContentRuleListStore` and for
/// attaching it to tabs by owner.
struct FloorpWebExtensionDNRCompilation: Codable, Sendable {
    let generation: UInt64
    let webKitContentRuleJSON: String
    let compiledRules: [FloorpWebExtensionDNRCompiledRule]
    let report: FloorpWebExtensionDNRCompatibilityReport
}

struct FloorpWebExtensionDNRRegexSupport: Hashable, Codable, Sendable {
    let isSupported: Bool
    let reason: String?
}

/// A native, product-owned site exemption for a block-only DNR package.
///
/// This is deliberately a hostname rather than an extension-supplied DNR
/// condition.  The Settings UI uses it to construct a narrow WebKit
/// `unless-top-url` trigger at compile time; it never creates an `allow`
/// action or changes the immutable artifact's rules.
enum FloorpWebExtensionDNRExcludedTopLevelDomain {
    static let maximumCount = 128

    /// Normalizes the deliberately small input grammar accepted by the native
    /// settings UI. A bare hostname means HTTPS. Paths, credentials, ports,
    /// query strings, and non-web schemes are rejected rather than silently
    /// broadening the requested exclusion.
    static func normalizeUserInput(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let source = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased(),
              isCanonicalDomain(host) else {
            return nil
        }
        return host
    }

    static func isCanonicalDomain(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.lowercased(),
              value.count <= 253,
              !value.hasPrefix("."),
              !value.hasSuffix(".") else {
            return false
        }
        return value.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.count <= 63 &&
                !label.hasPrefix("-") && !label.hasSuffix("-") &&
                label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// WebKit evaluates `unless-top-url` values as regular expressions.  The
    /// expression is constrained to a canonical HTTP(S) host boundary, so a
    /// user entering `example.com` cannot accidentally exempt
    /// `not-example.com` or inject regular-expression syntax.
    static func webKitTopURLPattern(for domain: String) -> String {
        let escapedDomain = NSRegularExpression.escapedPattern(for: domain)
        // WebKit content-rule filters deliberately do not support regex
        // disjunction. Every canonical HTTP(S) URL has a path separator,
        // explicit port, query, or fragment marker after its host, so this
        // character class supplies the required host boundary without a
        // disjunction.
        return "^https?://([a-z0-9-]+\\.)*\(escapedDomain)[:/?#]"
    }
}

enum FloorpWebExtensionDNRError: Error, LocalizedError, Sendable {
    case invalidRuleSetIdentifier(String)
    case duplicateRuleSetIdentifier(String)
    case unknownStaticRuleSet(String)
    case duplicateRuleIdentifier(Int, FloorpWebExtensionDNRRuleScope)
    case ruleNotFound(Int, FloorpWebExtensionDNRRuleScope)
    case conflictingUpdate(String)
    case invalidRule(Int, String)
    case quotaExceeded(FloorpWebExtensionDNRRuleScope, limit: Int)
    case incompatibleRules(FloorpWebExtensionDNRCompatibilityReport)

    var errorDescription: String? {
        switch self {
        case .invalidRuleSetIdentifier(let identifier):
            return "The static ruleset identifier is invalid: \(identifier)"
        case .duplicateRuleSetIdentifier(let identifier):
            return "The static ruleset identifier is already registered: \(identifier)"
        case .unknownStaticRuleSet(let identifier):
            return "The static ruleset is not registered: \(identifier)"
        case .duplicateRuleIdentifier(let identifier, let scope):
            return "The \(scope.rawValue) DNR rule identifier is duplicated: \(identifier)"
        case .ruleNotFound(let identifier, let scope):
            return "The \(scope.rawValue) DNR rule does not exist: \(identifier)"
        case .conflictingUpdate(let reason):
            return "The DNR update is internally conflicting: \(reason)"
        case .invalidRule(let identifier, let reason):
            return "DNR rule \(identifier) is invalid: \(reason)"
        case .quotaExceeded(let scope, let limit):
            return "The \(scope.rawValue) DNR rule limit of \(limit) would be exceeded."
        case .incompatibleRules(let report):
            return "\(report.rejectedRuleCount) DNR rule(s) cannot be represented by WebKit."
        }
    }
}

struct FloorpWebExtensionDNRPolicySnapshot: Codable, Sendable {
    let generation: UInt64
    let staticRuleSets: [FloorpWebExtensionDNRStaticRuleSet]
    let enabledStaticRuleSetIDs: Set<String>
    let dynamicRules: [FloorpWebExtensionDNRRule]
    let sessionRules: [FloorpWebExtensionDNRRule]
    /// Native Settings exclusions, applied only to immutable static block
    /// rules while compiling the current profile's WebKit content-rule list.
    let excludedTopLevelDomains: [String]
    let compilation: FloorpWebExtensionDNRCompilation
}

/// Persisted profile DNR state.
///
/// Session rules remain memory-only and are intentionally omitted.
struct FloorpWebExtensionStoredDNRConfiguration: Codable, Equatable, Sendable {
    let limits: FloorpWebExtensionDNRLimits
    let enabledStaticRuleSetIDs: Set<String>
    let dynamicRules: [FloorpWebExtensionDNRRule]
    /// Last successfully applied DNR policy generation. It is informational
    /// in durable state and lets Settings describe the exact policy revision
    /// it is editing after a later process restore.
    let policyGeneration: UInt64
    /// Product-owned top-level-site exemptions for immutable static block
    /// rules. These are never populated from extension DNR API requests.
    let excludedTopLevelDomains: [String]

    init(
        limits: FloorpWebExtensionDNRLimits,
        enabledStaticRuleSetIDs: Set<String>,
        dynamicRules: [FloorpWebExtensionDNRRule],
        policyGeneration: UInt64 = 0,
        excludedTopLevelDomains: [String] = []
    ) {
        self.limits = limits
        self.enabledStaticRuleSetIDs = enabledStaticRuleSetIDs
        self.dynamicRules = dynamicRules
        self.policyGeneration = policyGeneration
        self.excludedTopLevelDomains = excludedTopLevelDomains
    }

    private enum CodingKeys: String, CodingKey {
        case limits
        case enabledStaticRuleSetIDs
        case dynamicRules
        case policyGeneration
        case excludedTopLevelDomains
    }

    /// Older registries intentionally migrate to a no-exemption state. A
    /// missing field can never turn off a block rule.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limits = try container.decode(FloorpWebExtensionDNRLimits.self, forKey: .limits)
        enabledStaticRuleSetIDs = try container.decode(Set<String>.self, forKey: .enabledStaticRuleSetIDs)
        dynamicRules = try container.decode([FloorpWebExtensionDNRRule].self, forKey: .dynamicRules)
        policyGeneration = try container.decodeIfPresent(UInt64.self, forKey: .policyGeneration) ?? 0
        excludedTopLevelDomains = try container.decodeIfPresent(
            [String].self,
            forKey: .excludedTopLevelDomains
        ) ?? []
    }
}

/// A per-profile, per-extension DNR state owner.
///
/// Every mutating API makes a complete candidate state, validates and compiles
/// it, then swaps the generation only when the candidate has no rejected
/// rules. Consequently a caller can keep the prior compiled WebKit list
/// attached if this actor throws.
actor FloorpWebExtensionDNRStore {
    fileprivate struct State: Sendable {
        var staticRuleSets: [String: FloorpWebExtensionDNRStaticRuleSet]
        var enabledStaticRuleSetIDs: Set<String>
        var dynamicRules: [Int: FloorpWebExtensionDNRRule]
        var sessionRules: [Int: FloorpWebExtensionDNRRule]
        var excludedTopLevelDomains: [String]
    }

    private let limits: FloorpWebExtensionDNRLimits
    private var state: State
    private var generation: UInt64
    private var compilation: FloorpWebExtensionDNRCompilation

    init(
        staticRuleSets: [FloorpWebExtensionDNRStaticRuleSet] = [],
        enabledStaticRuleSetIDs: Set<String> = [],
        dynamicRules: [FloorpWebExtensionDNRRule] = [],
        limits: FloorpWebExtensionDNRLimits = .init(),
        generation: UInt64 = 1,
        excludedTopLevelDomains: [String] = []
    ) throws {
        try Self.validateLimits(limits)
        let canonicalExcludedTopLevelDomains = try Self.validatedExcludedTopLevelDomains(
            excludedTopLevelDomains
        )

        var registeredRuleSets: [String: FloorpWebExtensionDNRStaticRuleSet] = [:]
        var staticRuleCount = 0
        for ruleSet in staticRuleSets {
            guard Self.isValidRuleSetIdentifier(ruleSet.identifier) else {
                throw FloorpWebExtensionDNRError.invalidRuleSetIdentifier(ruleSet.identifier)
            }
            guard registeredRuleSets[ruleSet.identifier] == nil else {
                throw FloorpWebExtensionDNRError.duplicateRuleSetIdentifier(ruleSet.identifier)
            }
            try Self.validateRules(ruleSet.rules, scope: .staticRules)
            staticRuleCount += ruleSet.rules.count
            registeredRuleSets[ruleSet.identifier] = ruleSet
        }
        guard staticRuleCount <= limits.maxStaticRules else {
            throw FloorpWebExtensionDNRError.quotaExceeded(.staticRules, limit: limits.maxStaticRules)
        }
        guard enabledStaticRuleSetIDs.count <= limits.maxEnabledStaticRuleSets else {
            throw FloorpWebExtensionDNRError.quotaExceeded(
                .staticRules,
                limit: limits.maxEnabledStaticRuleSets
            )
        }
        for identifier in enabledStaticRuleSetIDs where registeredRuleSets[identifier] == nil {
            throw FloorpWebExtensionDNRError.unknownStaticRuleSet(identifier)
        }
        try Self.validateRules(dynamicRules, scope: .dynamic)
        guard dynamicRules.count <= limits.maxDynamicRules else {
            throw FloorpWebExtensionDNRError.quotaExceeded(.dynamic, limit: limits.maxDynamicRules)
        }

        let initialState = State(
            staticRuleSets: registeredRuleSets,
            enabledStaticRuleSetIDs: enabledStaticRuleSetIDs,
            dynamicRules: Dictionary(uniqueKeysWithValues: dynamicRules.map { ($0.id, $0) }),
            sessionRules: [:],
            excludedTopLevelDomains: canonicalExcludedTopLevelDomains
        )
        // Static rules are only promised as enabled after their complete
        // translation succeeds. Unsupported disabled resources remain
        // inspectable and are rejected if a later enable request selects them.
        let initialCompilation = FloorpWebExtensionDNRCompiler.compile(
            state: initialState,
            generation: generation
        )
        guard !initialCompilation.report.hasRejections else {
            throw FloorpWebExtensionDNRError.incompatibleRules(initialCompilation.report)
        }

        self.limits = limits
        state = initialState
        self.generation = generation
        compilation = initialCompilation
    }

    /// Rebuilds an isolated candidate store from a committed snapshot.
    ///
    /// The coordinator uses this initializer to stage a DNR mutation without
    /// changing the active store.  Its successor generation is compiled by
    /// WebKit first; only then does the coordinator replace the active store.
    /// Replaying a snapshot deliberately does not use the public update APIs,
    /// whose per-request limit is not an appropriate limit for restoring a
    /// previously committed rule collection.
    init(
        replaying snapshot: FloorpWebExtensionDNRPolicySnapshot,
        limits: FloorpWebExtensionDNRLimits,
        minimumGeneration: UInt64? = nil
    ) throws {
        try Self.validateLimits(limits)
        let canonicalExcludedTopLevelDomains = try Self.validatedExcludedTopLevelDomains(
            snapshot.excludedTopLevelDomains
        )

        var staticRuleSets = [String: FloorpWebExtensionDNRStaticRuleSet]()
        var staticRuleCount = 0
        for ruleSet in snapshot.staticRuleSets {
            guard Self.isValidRuleSetIdentifier(ruleSet.identifier) else {
                throw FloorpWebExtensionDNRError.invalidRuleSetIdentifier(ruleSet.identifier)
            }
            guard staticRuleSets[ruleSet.identifier] == nil else {
                throw FloorpWebExtensionDNRError.duplicateRuleSetIdentifier(ruleSet.identifier)
            }
            try Self.validateRules(ruleSet.rules, scope: .staticRules)
            staticRuleCount += ruleSet.rules.count
            staticRuleSets[ruleSet.identifier] = ruleSet
        }
        guard staticRuleCount <= limits.maxStaticRules else {
            throw FloorpWebExtensionDNRError.quotaExceeded(.staticRules, limit: limits.maxStaticRules)
        }
        guard snapshot.enabledStaticRuleSetIDs.count <= limits.maxEnabledStaticRuleSets else {
            throw FloorpWebExtensionDNRError.quotaExceeded(
                .staticRules,
                limit: limits.maxEnabledStaticRuleSets
            )
        }
        for identifier in snapshot.enabledStaticRuleSetIDs where staticRuleSets[identifier] == nil {
            throw FloorpWebExtensionDNRError.unknownStaticRuleSet(identifier)
        }

        try Self.validateRules(snapshot.dynamicRules, scope: .dynamic)
        guard snapshot.dynamicRules.count <= limits.maxDynamicRules else {
            throw FloorpWebExtensionDNRError.quotaExceeded(.dynamic, limit: limits.maxDynamicRules)
        }
        try Self.validateRules(snapshot.sessionRules, scope: .session)
        guard snapshot.sessionRules.count <= limits.maxSessionRules else {
            throw FloorpWebExtensionDNRError.quotaExceeded(.session, limit: limits.maxSessionRules)
        }

        let restoredState = State(
            staticRuleSets: staticRuleSets,
            enabledStaticRuleSetIDs: snapshot.enabledStaticRuleSetIDs,
            dynamicRules: Dictionary(uniqueKeysWithValues: snapshot.dynamicRules.map { ($0.id, $0) }),
            sessionRules: Dictionary(uniqueKeysWithValues: snapshot.sessionRules.map { ($0.id, $0) }),
            excludedTopLevelDomains: canonicalExcludedTopLevelDomains
        )
        let restoredGeneration = max(snapshot.generation &+ 1, minimumGeneration ?? 0)
        let restoredCompilation = FloorpWebExtensionDNRCompiler.compile(
            state: restoredState,
            generation: restoredGeneration
        )
        guard !restoredCompilation.report.hasRejections else {
            throw FloorpWebExtensionDNRError.incompatibleRules(restoredCompilation.report)
        }

        self.limits = limits
        state = restoredState
        generation = restoredGeneration
        compilation = restoredCompilation
    }

    func getEnabledStaticRuleSetIDs() -> Set<String> {
        state.enabledStaticRuleSetIDs
    }

    func getDynamicRules() -> [FloorpWebExtensionDNRRule] {
        state.dynamicRules.values.sorted(by: Self.ruleOrder)
    }

    func getSessionRules() -> [FloorpWebExtensionDNRRule] {
        state.sessionRules.values.sorted(by: Self.ruleOrder)
    }

    func getExcludedTopLevelDomains() -> [String] {
        state.excludedTopLevelDomains
    }

    func currentCompilation() -> FloorpWebExtensionDNRCompilation {
        compilation
    }

    func snapshot() -> FloorpWebExtensionDNRPolicySnapshot {
        FloorpWebExtensionDNRPolicySnapshot(
            generation: generation,
            staticRuleSets: state.staticRuleSets.values.sorted { $0.identifier < $1.identifier },
            enabledStaticRuleSetIDs: state.enabledStaticRuleSetIDs,
            dynamicRules: state.dynamicRules.values.sorted(by: Self.ruleOrder),
            sessionRules: state.sessionRules.values.sorted(by: Self.ruleOrder),
            excludedTopLevelDomains: state.excludedTopLevelDomains,
            compilation: compilation
        )
    }

    /// Enables and disables static resources as one transaction. An identifier
    /// cannot appear in both arguments because accepting that ambiguity makes a
    /// caller's intended policy unknowable.
    func updateEnabledStaticRuleSets(enable: [String], disable: [String]) throws {
        try Self.validateDistinctRuleSetIDs(enable)
        try Self.validateDistinctRuleSetIDs(disable)
        let overlap = Set(enable).intersection(disable)
        guard overlap.isEmpty else {
            throw FloorpWebExtensionDNRError.conflictingUpdate(
                "a static ruleset cannot be enabled and disabled in the same update"
            )
        }
        for identifier in enable + disable where state.staticRuleSets[identifier] == nil {
            throw FloorpWebExtensionDNRError.unknownStaticRuleSet(identifier)
        }

        var candidate = state
        candidate.enabledStaticRuleSetIDs.subtract(disable)
        candidate.enabledStaticRuleSetIDs.formUnion(enable)
        guard candidate.enabledStaticRuleSetIDs.count <= limits.maxEnabledStaticRuleSets else {
            throw FloorpWebExtensionDNRError.quotaExceeded(
                .staticRules,
                limit: limits.maxEnabledStaticRuleSets
            )
        }
        try commit(candidate: candidate)
    }

    /// Applies a Chrome-compatible remove-then-add replacement transaction to
    /// persistent dynamic rules. Persist the returned dynamic snapshot only
    /// after this call succeeds.
    func updateDynamicRules(
        addRules: [FloorpWebExtensionDNRRule],
        removeRuleIDs: [Int]
    ) throws {
        var candidate = state
        candidate.dynamicRules = try Self.updatedRules(
            state.dynamicRules,
            addRules: addRules,
            removeRuleIDs: removeRuleIDs,
            scope: .dynamic,
            limit: limits.maxDynamicRules,
            maxRulesPerUpdate: limits.maxRulesPerUpdate
        )
        try commit(candidate: candidate)
    }

    /// Applies a transaction to in-memory session rules. Call
    /// ``clearSessionRules()`` at process/session termination instead of
    /// persisting this collection.
    func updateSessionRules(
        addRules: [FloorpWebExtensionDNRRule],
        removeRuleIDs: [Int]
    ) throws {
        var candidate = state
        candidate.sessionRules = try Self.updatedRules(
            state.sessionRules,
            addRules: addRules,
            removeRuleIDs: removeRuleIDs,
            scope: .session,
            limit: limits.maxSessionRules,
            maxRulesPerUpdate: limits.maxRulesPerUpdate
        )
        try commit(candidate: candidate)
    }

    /// Removes memory-only session rules through the same compile-and-swap
    /// path. This never changes persistent dynamic rules.
    func clearSessionRules() throws {
        guard !state.sessionRules.isEmpty else { return }
        var candidate = state
        candidate.sessionRules.removeAll()
        try commit(candidate: candidate)
    }

    /// Replaces the complete native site-exemption set in one compile-and-swap
    /// transaction. The caller can persist the returned configuration only
    /// after the candidate WebKit policy has been accepted.
    func updateExcludedTopLevelDomains(_ domains: [String]) throws {
        var candidate = state
        candidate.excludedTopLevelDomains = try Self.validatedExcludedTopLevelDomains(domains)
        guard candidate.excludedTopLevelDomains != state.excludedTopLevelDomains else { return }
        try commit(candidate: candidate)
    }

    func persistedConfiguration() -> FloorpWebExtensionStoredDNRConfiguration {
        FloorpWebExtensionStoredDNRConfiguration(
            limits: limits,
            enabledStaticRuleSetIDs: state.enabledStaticRuleSetIDs,
            dynamicRules: getDynamicRules(),
            policyGeneration: generation,
            excludedTopLevelDomains: state.excludedTopLevelDomains
        )
    }

    func isRegexSupported(_ regex: String) -> FloorpWebExtensionDNRRegexSupport {
        FloorpWebExtensionDNRCompiler.regexSupport(for: regex)
    }

    private func commit(candidate: State) throws {
        let nextGeneration = generation &+ 1
        let candidateCompilation = FloorpWebExtensionDNRCompiler.compile(
            state: candidate,
            generation: nextGeneration
        )
        guard !candidateCompilation.report.hasRejections else {
            throw FloorpWebExtensionDNRError.incompatibleRules(candidateCompilation.report)
        }
        state = candidate
        generation = nextGeneration
        compilation = candidateCompilation
    }

    private static func updatedRules(
        _ existing: [Int: FloorpWebExtensionDNRRule],
        addRules: [FloorpWebExtensionDNRRule],
        removeRuleIDs: [Int],
        scope: FloorpWebExtensionDNRRuleScope,
        limit: Int,
        maxRulesPerUpdate: Int
    ) throws -> [Int: FloorpWebExtensionDNRRule] {
        guard addRules.count + removeRuleIDs.count <= maxRulesPerUpdate else {
            throw FloorpWebExtensionDNRError.quotaExceeded(scope, limit: maxRulesPerUpdate)
        }
        try validateRules(addRules, scope: scope)
        try validateDistinctIdentifiers(removeRuleIDs, scope: scope)

        var candidate = existing
        for identifier in removeRuleIDs {
            candidate.removeValue(forKey: identifier)
        }
        for rule in addRules {
            guard candidate[rule.id] == nil else {
                throw FloorpWebExtensionDNRError.duplicateRuleIdentifier(rule.id, scope)
            }
            candidate[rule.id] = rule
        }
        guard candidate.count <= limit else {
            throw FloorpWebExtensionDNRError.quotaExceeded(scope, limit: limit)
        }
        return candidate
    }

    private static func validateLimits(_ limits: FloorpWebExtensionDNRLimits) throws {
        guard limits.maxStaticRules >= 0,
              limits.maxEnabledStaticRuleSets >= 0,
              limits.maxDynamicRules >= 0,
              limits.maxSessionRules >= 0,
              limits.maxRulesPerUpdate >= 0 else {
            throw FloorpWebExtensionDNRError.invalidRule(0, "all DNR limits must be non-negative")
        }
    }

    private static func validateDistinctRuleSetIDs(_ identifiers: [String]) throws {
        var seen = Set<String>()
        for identifier in identifiers {
            guard seen.insert(identifier).inserted else {
                throw FloorpWebExtensionDNRError.conflictingUpdate(
                    "static ruleset identifier \(identifier) was supplied more than once"
                )
            }
        }
    }

    private static func validateDistinctIdentifiers(
        _ identifiers: [Int],
        scope: FloorpWebExtensionDNRRuleScope
    ) throws {
        var seen = Set<Int>()
        for identifier in identifiers {
            guard seen.insert(identifier).inserted else {
                throw FloorpWebExtensionDNRError.duplicateRuleIdentifier(identifier, scope)
            }
        }
    }

    private static func validateRules(
        _ rules: [FloorpWebExtensionDNRRule],
        scope: FloorpWebExtensionDNRRuleScope
    ) throws {
        try validateDistinctIdentifiers(rules.map(\.id), scope: scope)
        for rule in rules {
            try validateRule(rule)
        }
    }

    private static func validateRule(_ rule: FloorpWebExtensionDNRRule) throws {
        guard rule.id > 0 else {
            throw FloorpWebExtensionDNRError.invalidRule(rule.id, "identifier must be positive")
        }
        guard rule.priority > 0 else {
            throw FloorpWebExtensionDNRError.invalidRule(rule.id, "priority must be positive")
        }
        guard !(rule.condition.urlFilter != nil && rule.condition.regexFilter != nil) else {
            throw FloorpWebExtensionDNRError.invalidRule(
                rule.id,
                "urlFilter and regexFilter cannot both be present"
            )
        }
        if let urlFilter = rule.condition.urlFilter, urlFilter.isEmpty {
            throw FloorpWebExtensionDNRError.invalidRule(rule.id, "urlFilter cannot be empty")
        }
        if let regexFilter = rule.condition.regexFilter, regexFilter.isEmpty {
            throw FloorpWebExtensionDNRError.invalidRule(rule.id, "regexFilter cannot be empty")
        }

        try validateDistinctValues(rule.condition.requestDomains, ruleID: rule.id, field: "requestDomains")
        try validateDistinctValues(rule.condition.excludedRequestDomains, ruleID: rule.id, field: "excludedRequestDomains")
        try validateDistinctValues(rule.condition.initiatorDomains, ruleID: rule.id, field: "initiatorDomains")
        try validateDistinctValues(
            rule.condition.excludedInitiatorDomains,
            ruleID: rule.id,
            field: "excludedInitiatorDomains"
        )
        for domain in rule.condition.requestDomains + rule.condition.excludedRequestDomains +
            rule.condition.initiatorDomains + rule.condition.excludedInitiatorDomains {
            guard isValidDomain(domain) else {
                throw FloorpWebExtensionDNRError.invalidRule(rule.id, "invalid domain \(domain)")
            }
        }
        try validateDistinctValues(rule.condition.resourceTypes, ruleID: rule.id, field: "resourceTypes")
        try validateDistinctValues(
            rule.condition.excludedResourceTypes,
            ruleID: rule.id,
            field: "excludedResourceTypes"
        )
        try validateDistinctValues(rule.condition.tabIDs, ruleID: rule.id, field: "tabIDs")
        try validateDistinctValues(rule.condition.excludedTabIDs, ruleID: rule.id, field: "excludedTabIDs")
        guard (rule.condition.tabIDs + rule.condition.excludedTabIDs).allSatisfy({ $0 >= 0 }) else {
            throw FloorpWebExtensionDNRError.invalidRule(rule.id, "tab identifiers cannot be negative")
        }
    }

    private static func validateDistinctValues<T: Hashable>(
        _ values: [T],
        ruleID: Int,
        field: String
    ) throws {
        guard Set(values).count == values.count else {
            throw FloorpWebExtensionDNRError.invalidRule(ruleID, "\(field) contains duplicates")
        }
    }

    private static func isValidRuleSetIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= 128 else { return false }
        return identifier.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) ||
                ($0.value >= 65 && $0.value <= 90) ||
                ($0.value >= 97 && $0.value <= 122) ||
                $0 == "-" || $0 == "_"
        }
    }

    private static func isValidDomain(_ value: String) -> Bool {
        let domain: String
        if value.hasPrefix("*.") {
            domain = String(value.dropFirst(2))
        } else {
            domain = value
        }
        guard !domain.isEmpty, domain.count <= 253,
              !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return false
        }
        return domain.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.count <= 63 &&
                !label.hasPrefix("-") && !label.hasSuffix("-") &&
                label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func validatedExcludedTopLevelDomains(_ domains: [String]) throws -> [String] {
        guard domains.count <= FloorpWebExtensionDNRExcludedTopLevelDomain.maximumCount else {
            throw FloorpWebExtensionDNRError.invalidRule(
                0,
                "at most \(FloorpWebExtensionDNRExcludedTopLevelDomain.maximumCount) site exclusions are supported"
            )
        }
        var seen = Set<String>()
        for domain in domains {
            guard FloorpWebExtensionDNRExcludedTopLevelDomain.isCanonicalDomain(domain) else {
                throw FloorpWebExtensionDNRError.invalidRule(0, "invalid excluded top-level domain \(domain)")
            }
            guard seen.insert(domain).inserted else {
                throw FloorpWebExtensionDNRError.invalidRule(0, "excluded top-level domains contain duplicates")
            }
        }
        return seen.sorted()
    }

    private static func ruleOrder(
        _ lhs: FloorpWebExtensionDNRRule,
        _ rhs: FloorpWebExtensionDNRRule
    ) -> Bool {
        lhs.id < rhs.id
    }
}

private enum FloorpWebExtensionDNRCompiler {
    private struct ActiveRule: Sendable {
        let rule: FloorpWebExtensionDNRRule
        let origin: FloorpWebExtensionDNRRuleOrigin
        /// Only the product-owned static block-rule path can set this. DNR
        /// API-created dynamic/session rules therefore remain unable to turn
        /// a top-level-domain condition into a native WebKit exemption.
        let nativeExcludedTopLevelDomains: [String]
    }

    private enum TranslationResult<Value> {
        case success(Value, transformations: [String])
        case rejected(String)
    }

    private static let supportedResourceTypes: [FloorpWebExtensionDNRResourceType: String] = [
        .mainFrame: "document",
        .stylesheet: "style-sheet",
        .script: "script",
        .image: "image",
        .font: "font",
        .media: "media",
        .xmlHttpRequest: "raw"
    ]

    static func compile(
        state: FloorpWebExtensionDNRStore.State,
        generation: UInt64
    ) -> FloorpWebExtensionDNRCompilation {
        let activeRules = makeActiveRules(from: state)
        let reasonsByRule = incompatibilityReasons(in: activeRules)
        var entries: [FloorpWebExtensionDNRCompatibilityEntry] = []
        var compiledRules: [FloorpWebExtensionDNRCompiledRule] = []
        var webKitRules: [[String: Any]] = []

        for activeRule in activeRules.sorted(by: compilationOrder) {
            if let reasons = reasonsByRule[
                .init(ruleID: activeRule.rule.id, origin: activeRule.origin)
            ] {
                entries.append(
                    .init(
                        ruleID: activeRule.rule.id,
                        origin: activeRule.origin,
                        status: .rejected,
                        reasons: reasons.sorted()
                    )
                )
                continue
            }

            switch translate(activeRule) {
            case .rejected(let reason):
                entries.append(
                    .init(
                        ruleID: activeRule.rule.id,
                        origin: activeRule.origin,
                        status: .rejected,
                        reasons: [reason]
                    )
                )
            case .success(let webKitRule, let transformations):
                guard JSONSerialization.isValidJSONObject(webKitRule),
                      let ruleData = try? JSONSerialization.data(withJSONObject: webKitRule, options: [.sortedKeys]),
                      let ruleJSON = String(data: ruleData, encoding: .utf8) else {
                    entries.append(
                        .init(
                            ruleID: activeRule.rule.id,
                            origin: activeRule.origin,
                            status: .rejected,
                            reasons: ["the generated WebKit content rule was not valid JSON"]
                        )
                    )
                    continue
                }

                entries.append(
                    .init(
                        ruleID: activeRule.rule.id,
                        origin: activeRule.origin,
                        status: transformations.isEmpty ? .accepted : .transformed,
                        reasons: transformations
                    )
                )
                compiledRules.append(
                    .init(ruleID: activeRule.rule.id, origin: activeRule.origin, webKitRuleJSON: ruleJSON)
                )
                webKitRules.append(webKitRule)
            }
        }

        let contentRuleJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: webKitRules, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            contentRuleJSON = json
        } else {
            // Every individual rule has already passed JSON validation. This is
            // a defensive fallback that makes an impossible serialization fault
            // fail closed at the caller's next validation boundary.
            contentRuleJSON = "[]"
        }

        return .init(
            generation: generation,
            webKitContentRuleJSON: contentRuleJSON,
            compiledRules: compiledRules,
            report: .init(entries: entries)
        )
    }

    static func regexSupport(for regex: String) -> FloorpWebExtensionDNRRegexSupport {
        guard !regex.isEmpty else {
            return .init(isSupported: false, reason: "regexFilter cannot be empty")
        }
        guard regex.utf8.count <= 2_000 else {
            return .init(isSupported: false, reason: "regexFilter exceeds the 2000 byte safety limit")
        }
        if hasUnsupportedGroupSyntax(regex) {
            return .init(
                isSupported: false,
                reason: "regexFilter uses look-around, inline flags, or named groups"
            )
        }
        if let expression = try? NSRegularExpression(pattern: "\\\\[1-9]"),
           expression.firstMatch(
               in: regex,
               range: NSRange(regex.startIndex..., in: regex)
           ) != nil {
            return .init(isSupported: false, reason: "regexFilter uses a backreference")
        }
        do {
            _ = try NSRegularExpression(pattern: regex)
            return .init(isSupported: true, reason: nil)
        } catch {
            return .init(isSupported: false, reason: "regexFilter is not a valid WebKit-compatible regular expression")
        }
    }

    private static func makeActiveRules(
        from state: FloorpWebExtensionDNRStore.State
    ) -> [ActiveRule] {
        var activeRules: [ActiveRule] = []
        for identifier in state.enabledStaticRuleSetIDs.sorted() {
            guard let ruleSet = state.staticRuleSets[identifier] else { continue }
            activeRules += ruleSet.rules.map {
                ActiveRule(
                    rule: $0,
                    origin: .init(scope: .staticRules, staticRuleSetID: ruleSet.identifier),
                    nativeExcludedTopLevelDomains: $0.action.type == .block
                        ? state.excludedTopLevelDomains
                        : []
                )
            }
        }
        activeRules += state.dynamicRules.values.map {
            ActiveRule(rule: $0, origin: .init(scope: .dynamic), nativeExcludedTopLevelDomains: [])
        }
        activeRules += state.sessionRules.values.map {
            ActiveRule(rule: $0, origin: .init(scope: .session), nativeExcludedTopLevelDomains: [])
        }
        return activeRules
    }

    private static func incompatibilityReasons(
        in activeRules: [ActiveRule]
    ) -> [RuleKey: Set<String>] {
        let mixedPriorityReason = "mixed action types at the same priority are not provably ordered"
        let blockUpgradeReason = "a higher-priority upgradeScheme cannot override a lower-priority block in WebKit"
        var reasonsByRule: [RuleKey: Set<String>] = [:]
        let orderedActionRules = activeRules.filter {
            switch $0.rule.action.type {
            case .block, .upgradeScheme, .allow:
                return true
            case .allowAllRequests, .redirect, .modifyHeaders:
                // Unsupported actions are rejected on their own. They must not
                // make an already active supported rule appear incompatible.
                return false
            }
        }
        for rulesAtPriority in Dictionary(grouping: orderedActionRules, by: { $0.rule.priority }).values {
            guard Set(rulesAtPriority.map(\.rule.action.type)).count > 1 else { continue }
            for activeRule in rulesAtPriority {
                reasonsByRule[
                    .init(ruleID: activeRule.rule.id, origin: activeRule.origin),
                    default: []
                ].insert(mixedPriorityReason)
            }
        }

        // DNR selects the higher-priority matching rule. WebKit instead runs
        // matching content-rule actions in list order, and `make-https` cannot
        // cancel an earlier `block`. Since arbitrary URL filters and regular
        // expressions cannot be proven disjoint, reject every rule that can
        // participate in this unsafe priority relationship.
        let blockRules = orderedActionRules.filter { $0.rule.action.type == .block }
        let upgradeRules = orderedActionRules.filter { $0.rule.action.type == .upgradeScheme }
        if let lowestBlockPriority = blockRules.map(\.rule.priority).min(),
           let highestUpgradePriority = upgradeRules.map(\.rule.priority).max(),
           lowestBlockPriority < highestUpgradePriority {
            for activeRule in blockRules where activeRule.rule.priority < highestUpgradePriority {
                reasonsByRule[
                    .init(ruleID: activeRule.rule.id, origin: activeRule.origin),
                    default: []
                ].insert(blockUpgradeReason)
            }
            for activeRule in upgradeRules where activeRule.rule.priority > lowestBlockPriority {
                reasonsByRule[
                    .init(ruleID: activeRule.rule.id, origin: activeRule.origin),
                    default: []
                ].insert(blockUpgradeReason)
            }
        }

        return reasonsByRule
    }

    private static func compilationOrder(_ lhs: ActiveRule, _ rhs: ActiveRule) -> Bool {
        if lhs.rule.priority != rhs.rule.priority {
            // WebKit evaluates later matching content rules after earlier rules.
            // Ascending DNR priority lets a supported higher-priority allow rule
            // use `ignore-previous-rules` to cancel lower-priority actions.
            return lhs.rule.priority < rhs.rule.priority
        }
        if lhs.origin.scope.rawValue != rhs.origin.scope.rawValue {
            return lhs.origin.scope.rawValue < rhs.origin.scope.rawValue
        }
        if lhs.origin.staticRuleSetID != rhs.origin.staticRuleSetID {
            return (lhs.origin.staticRuleSetID ?? "") < (rhs.origin.staticRuleSetID ?? "")
        }
        return lhs.rule.id < rhs.rule.id
    }

    private static func translate(
        _ activeRule: ActiveRule
    ) -> TranslationResult<[String: Any]> {
        let rule = activeRule.rule
        switch rule.action.type {
        case .redirect:
            return .rejected("redirect is not available in the iOS 15 WebKit content-rule subset")
        case .modifyHeaders:
            return .rejected("modifyHeaders has no WKContentRuleList equivalent")
        case .allowAllRequests:
            return .rejected("allowAllRequests requires per-frame policy attachment and is not enabled by this compiler")
        case .block, .upgradeScheme, .allow:
            break
        }

        let condition = rule.condition
        if !condition.initiatorDomains.isEmpty {
            return .rejected("initiator domain conditions are not exactly representable by WebKit top-URL conditions")
        }
        if !condition.excludedInitiatorDomains.isEmpty {
            // This remains unsupported for all artifact and WebExtension API
            // rule inputs. The Settings-owned exemption set is carried
            // separately on ActiveRule so no extension can manufacture one.
            return .rejected("extension-supplied excluded initiator domains are not supported")
        }
        if !condition.tabIDs.isEmpty || !condition.excludedTabIDs.isEmpty {
            return .rejected("tab-scoped conditions require per-tab generated content-rule lists")
        }
        if !condition.requestMethods.isEmpty {
            return .rejected("request method conditions are unavailable in the iOS 15 WebKit content-rule subset")
        }
        if !condition.responseHeaders.isEmpty || !condition.excludedResponseHeaders.isEmpty {
            return .rejected("response header conditions are unavailable in the iOS 15 WebKit content-rule subset")
        }
        if condition.isUrlFilterCaseSensitive != nil && condition.urlFilter == nil {
            return .rejected("isUrlFilterCaseSensitive is valid only with urlFilter")
        }

        var transformations: [String] = []
        let urlFilter: String
        if let source = condition.urlFilter {
            switch translateURLFilter(source) {
            case .rejected(let reason):
                return .rejected(reason)
            case .success(let translated, let filterTransformations):
                urlFilter = translated
                transformations += filterTransformations
            }
        } else if let regex = condition.regexFilter {
            let support = regexSupport(for: regex)
            guard support.isSupported else {
                return .rejected(support.reason ?? "regexFilter is unsupported")
            }
            urlFilter = regex
        } else {
            // Content blockers require url-filter. `.*` exactly represents an
            // unconstrained DNR condition in the supported condition subset.
            urlFilter = ".*"
            transformations.append("an unconstrained condition was expanded to an all-URL WebKit filter")
        }

        var trigger: [String: Any] = ["url-filter": urlFilter]
        if condition.urlFilter != nil {
            trigger["url-filter-is-case-sensitive"] = condition.isUrlFilterCaseSensitive ?? false
        } else if condition.regexFilter != nil {
            // DNR regex filters are case-sensitive. Set this explicitly rather
            // than inheriting WebKit's default for url-filter.
            trigger["url-filter-is-case-sensitive"] = true
        }

        switch translateResourceTypes(condition) {
        case .rejected(let reason):
            return .rejected(reason)
        case .success(let resourceTypes, let resourceTransformations):
            if let resourceTypes {
                trigger["resource-type"] = resourceTypes
            }
            transformations += resourceTransformations
        }

        switch translateDomains(condition.requestDomains, field: "requestDomains") {
        case .rejected(let reason):
            return .rejected(reason)
        case .success(let domains, let domainTransformations):
            if let domains {
                trigger["if-domain"] = domains
            }
            transformations += domainTransformations
        }
        switch translateDomains(condition.excludedRequestDomains, field: "excludedRequestDomains") {
        case .rejected(let reason):
            return .rejected(reason)
        case .success(let domains, let domainTransformations):
            if let domains {
                trigger["unless-domain"] = domains
            }
            transformations += domainTransformations
        }

        if !activeRule.nativeExcludedTopLevelDomains.isEmpty {
            let topURLPatterns = activeRule.nativeExcludedTopLevelDomains.map {
                FloorpWebExtensionDNRExcludedTopLevelDomain.webKitTopURLPattern(for: $0)
            }
            trigger["unless-top-url"] = topURLPatterns
            transformations.append("native top-level site exclusions were applied to this block rule")
        }

        if let domainType = condition.domainType {
            trigger["load-type"] = [
                domainType == .firstParty ? "first-party" : "third-party"
            ]
        }

        let actionType: String
        switch rule.action.type {
        case .block:
            actionType = "block"
        case .upgradeScheme:
            actionType = "make-https"
        case .allow:
            actionType = "ignore-previous-rules"
            transformations.append("allow was translated to ordered ignore-previous-rules")
        case .allowAllRequests, .redirect, .modifyHeaders:
            // These cases are rejected above. Keeping the switch exhaustive
            // protects this mapping when a new public action is added.
            return .rejected("the DNR action is not supported by WebKit")
        }

        return .success(
            ["trigger": trigger, "action": ["type": actionType]],
            transformations: Array(Set(transformations)).sorted()
        )
    }

    private static func translateURLFilter(_ source: String) -> TranslationResult<String> {
        guard source.utf8.count <= 2_000 else {
            return .rejected("urlFilter exceeds the 2000 byte safety limit")
        }
        guard source.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            return .rejected("urlFilter contains unsupported non-ASCII or control characters")
        }

        var index = source.startIndex
        var pieces: [String] = []
        if source.hasPrefix("||") {
            pieces.append("^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*\\\\.)?")
            index = source.index(index, offsetBy: 2)
        } else if source.hasPrefix("|") {
            pieces.append("^")
            index = source.index(after: index)
        }

        while index < source.endIndex {
            let character = source[index]
            if character == "|" {
                guard source.index(after: index) == source.endIndex else {
                    return .rejected("urlFilter contains a non-anchor pipe")
                }
                pieces.append("$")
            } else if character == "*" {
                pieces.append(".*")
            } else if character == "^" {
                pieces.append("(?:[^A-Za-z0-9_.%-]|$)")
            } else {
                pieces.append(NSRegularExpression.escapedPattern(for: String(character)))
            }
            source.formIndex(after: &index)
        }

        let translated = pieces.joined()
        guard (try? NSRegularExpression(pattern: translated)) != nil else {
            return .rejected("urlFilter could not be safely converted to a WebKit regular expression")
        }
        return .success(translated, transformations: ["urlFilter was parsed and translated to a WebKit regular expression"])
    }

    private static func translateDomains(
        _ domains: [String],
        field: String
    ) -> TranslationResult<[String]?> {
        guard !domains.isEmpty else {
            return .success(nil, transformations: [])
        }
        var translated: [String] = []
        for source in domains {
            let bareDomain = source.hasPrefix("*.") ? String(source.dropFirst(2)) : source
            guard isValidDomain(bareDomain) else {
                return .rejected("\(field) contains invalid domain \(source)")
            }
            // DNR request domain matching includes subdomains. WebKit's suffix
            // pattern makes that intent explicit in the generated rule.
            translated.append("*\(bareDomain.lowercased())")
        }
        return .success(
            translated.sorted(),
            transformations: ["\(field) was translated to WebKit domain suffix patterns"]
        )
    }

    private static func translateResourceTypes(
        _ condition: FloorpWebExtensionDNRCondition
    ) -> TranslationResult<[String]?> {
        let requested = condition.resourceTypes
        let excluded = condition.excludedResourceTypes
        let unsupported = Set(requested + excluded).subtracting(supportedResourceTypes.keys)
        guard unsupported.isEmpty else {
            let values = unsupported.map(\.rawValue).sorted().joined(separator: ", ")
            return .rejected("resource types are not exactly representable by WebKit: \(values)")
        }

        var selected = requested.isEmpty ? Set(supportedResourceTypes.keys) : Set(requested)
        selected.subtract(excluded)
        guard !selected.isEmpty else {
            return .rejected("resource type conditions exclude every WebKit-supported resource type")
        }

        // Without either field there is no resource-type condition at all; do
        // not accidentally restrict this rule to the subset listed above.
        guard !requested.isEmpty || !excluded.isEmpty else {
            return .success(nil, transformations: [])
        }
        let webKitTypes = selected.compactMap { supportedResourceTypes[$0] }.sorted()
        let transformations = excluded.isEmpty
            ? []
            : ["excludedResourceTypes was expanded to the supported WebKit resource-type complement"]
        return .success(webKitTypes, transformations: transformations)
    }

    private static func isValidDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.count <= 253,
              !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return false
        }
        return domain.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.count <= 63 &&
                !label.hasPrefix("-") && !label.hasSuffix("-") &&
                label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private struct RuleKey: Hashable {
        let ruleID: Int
        let origin: FloorpWebExtensionDNRRuleOrigin
    }

    private static func hasUnsupportedGroupSyntax(_ regex: String) -> Bool {
        var index = regex.startIndex
        while index < regex.endIndex {
            guard regex[index] == "(" else {
                regex.formIndex(after: &index)
                continue
            }
            let questionMark = regex.index(after: index)
            guard questionMark < regex.endIndex, regex[questionMark] == "?" else {
                regex.formIndex(after: &index)
                continue
            }
            let groupKind = regex.index(after: questionMark)
            guard groupKind < regex.endIndex, regex[groupKind] == ":" else {
                return true
            }
            regex.formIndex(after: &index)
        }
        return false
    }
}

extension FloorpWebExtensionDNRStore {
    static func validateStoredConfiguration(
        _ configuration: FloorpWebExtensionStoredDNRConfiguration
    ) throws {
        try validateLimits(configuration.limits)
        guard configuration.enabledStaticRuleSetIDs.count <= configuration.limits.maxEnabledStaticRuleSets else {
            throw FloorpWebExtensionDNRError.quotaExceeded(
                .staticRules,
                limit: configuration.limits.maxEnabledStaticRuleSets
            )
        }

        try validateRules(configuration.dynamicRules, scope: .dynamic)
        guard configuration.dynamicRules.count <= configuration.limits.maxDynamicRules else {
            throw FloorpWebExtensionDNRError.quotaExceeded(
                .dynamic,
                limit: configuration.limits.maxDynamicRules
            )
        }

        let canonicalExcludedTopLevelDomains = try validatedExcludedTopLevelDomains(
            configuration.excludedTopLevelDomains
        )
        guard canonicalExcludedTopLevelDomains == configuration.excludedTopLevelDomains else {
            throw FloorpWebExtensionDNRError.invalidRule(
                0,
                "excluded top-level domains are not in canonical order"
            )
        }

        let state = State(
            staticRuleSets: [:],
            enabledStaticRuleSetIDs: [],
            dynamicRules: Dictionary(uniqueKeysWithValues: configuration.dynamicRules.map { ($0.id, $0) }),
            sessionRules: [:],
            excludedTopLevelDomains: canonicalExcludedTopLevelDomains
        )
        let compilation = FloorpWebExtensionDNRCompiler.compile(state: state, generation: 1)
        guard !compilation.report.hasRejections else {
            throw FloorpWebExtensionDNRError.incompatibleRules(compilation.report)
        }
    }
}
