// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// A package-relative JavaScript or stylesheet resource.
///
/// Registered scripts deliberately name package resources instead of accepting
/// dynamically-created source. The package installer validates and owns the
/// resource before this descriptor can be registered.
struct FloorpWebExtensionScriptSource: Hashable, Codable, Sendable {
    let path: String

    init(_ path: String) throws {
        let byteCount = path.lengthOfBytes(using: .utf8)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              byteCount <= 1_024,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 }),
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw FloorpWebExtensionError.unsupported("invalid registered script resource")
        }
        self.path = path
    }
}

/// The persisted form of an MV3 registered content script.
///
/// JavaScript and CSS lists retain their caller-provided order; a plan retains
/// that order so package files are evaluated predictably.
struct FloorpWebExtensionRegisteredScript: Hashable, Codable, Sendable {
    let id: String
    let matches: [FloorpWebExtensionMatchPattern]
    let excludeMatches: [FloorpWebExtensionMatchPattern]
    let javaScript: [FloorpWebExtensionScriptSource]
    let styleSheets: [FloorpWebExtensionScriptSource]
    let runAt: FloorpWebExtensionRunAt
    let allFrames: Bool
    let world: FloorpWebExtensionExecutionWorld

    init(
        id: String,
        matches: [FloorpWebExtensionMatchPattern],
        excludeMatches: [FloorpWebExtensionMatchPattern] = [],
        javaScript: [FloorpWebExtensionScriptSource] = [],
        styleSheets: [FloorpWebExtensionScriptSource] = [],
        runAt: FloorpWebExtensionRunAt = .documentIdle,
        allFrames: Bool = false,
        world: FloorpWebExtensionExecutionWorld = .isolated
    ) {
        self.id = id
        self.matches = matches
        self.excludeMatches = excludeMatches
        self.javaScript = javaScript
        self.styleSheets = styleSheets
        self.runAt = runAt
        self.allFrames = allFrames
        self.world = world
    }

    /// Builds the complete replacement used by both the transactional registry
    /// and the coordinator's resource-materialization preflight.
    func applying(_ update: FloorpWebExtensionRegisteredScriptUpdate) -> Self {
        Self(
            id: id,
            matches: update.matches ?? matches,
            excludeMatches: update.excludeMatches ?? excludeMatches,
            javaScript: update.javaScript ?? javaScript,
            styleSheets: update.styleSheets ?? styleSheets,
            runAt: update.runAt ?? runAt,
            allFrames: update.allFrames ?? allFrames,
            world: update.world ?? world
        )
    }
}

/// A partial update to a previously registered content script.
///
/// `nil` retains the old value; an empty source or exclude list intentionally
/// clears that list. A script must still contain JavaScript or CSS afterwards.
struct FloorpWebExtensionRegisteredScriptUpdate: Hashable, Codable, Sendable {
    let id: String
    let matches: [FloorpWebExtensionMatchPattern]?
    let excludeMatches: [FloorpWebExtensionMatchPattern]?
    let javaScript: [FloorpWebExtensionScriptSource]?
    let styleSheets: [FloorpWebExtensionScriptSource]?
    let runAt: FloorpWebExtensionRunAt?
    let allFrames: Bool?
    let world: FloorpWebExtensionExecutionWorld?

    init(
        id: String,
        matches: [FloorpWebExtensionMatchPattern]? = nil,
        excludeMatches: [FloorpWebExtensionMatchPattern]? = nil,
        javaScript: [FloorpWebExtensionScriptSource]? = nil,
        styleSheets: [FloorpWebExtensionScriptSource]? = nil,
        runAt: FloorpWebExtensionRunAt? = nil,
        allFrames: Bool? = nil,
        world: FloorpWebExtensionExecutionWorld? = nil
    ) {
        self.id = id
        self.matches = matches
        self.excludeMatches = excludeMatches
        self.javaScript = javaScript
        self.styleSheets = styleSheets
        self.runAt = runAt
        self.allFrames = allFrames
        self.world = world
    }
}

/// A single, deterministic content-policy entry for a tab navigation.
struct FloorpWebExtensionScriptPlan: Hashable, Sendable {
    let extensionID: FloorpWebExtensionID
    let script: FloorpWebExtensionRegisteredScript
    let registrationOrder: UInt64

    /// Only isolated worlds receive the native WebExtensions bridge. MAIN-world
    /// scripts execute in the page world without a browser API object.
    var requiresNativeBridge: Bool {
        script.world == .isolated
    }

    /// `WKUserScript.forMainFrameOnly` is the inverse of this property.
    var forMainFrameOnly: Bool {
        !script.allFrames
    }

    func applies(toMainFrame isMainFrame: Bool) -> Bool {
        isMainFrame || script.allFrames
    }
}

/// Stores registered scripts by extension and creates immutable policy plans.
///
/// Every mutating API first builds and validates a complete draft. The draft is
/// committed only after all identifiers, quotas, and descriptors are valid, so
/// a malformed member of a batch cannot expose a partially-updated registry.
actor FloorpWebExtensionScriptRegistry {
    static let maximumScriptsPerExtension = 500
    static let maximumSourcesPerScript = 50
    static let maximumMatchPatternsPerScript = 100
    static let maximumResourceBytesPerExtension = 512 * 1_024

    private struct StoredScript: Sendable {
        let script: FloorpWebExtensionRegisteredScript
        let registrationOrder: UInt64
    }

    private var scriptsByExtension = [FloorpWebExtensionID: [String: StoredScript]]()
    private var nextRegistrationOrder: UInt64 = 0

    func register(
        _ scripts: [FloorpWebExtensionRegisteredScript],
        for extensionID: FloorpWebExtensionID
    ) throws {
        guard !scripts.isEmpty else { return }

        let current = scriptsByExtension[extensionID] ?? [:]
        var draft = current
        var identifiers = Set<String>()
        var order = nextRegistrationOrder

        for script in scripts {
            try Self.validateIdentifier(script.id)
            guard identifiers.insert(script.id).inserted, draft[script.id] == nil else {
                throw FloorpWebExtensionError.duplicateIdentifier(script.id)
            }
            order &+= 1
            draft[script.id] = StoredScript(script: script, registrationOrder: order)
        }

        try Self.validate(draft)
        scriptsByExtension[extensionID] = draft
        nextRegistrationOrder = order
    }

    func update(
        _ updates: [FloorpWebExtensionRegisteredScriptUpdate],
        for extensionID: FloorpWebExtensionID
    ) throws {
        guard !updates.isEmpty else { return }

        let current = scriptsByExtension[extensionID] ?? [:]
        var draft = current
        var identifiers = Set<String>()

        for update in updates {
            try Self.validateIdentifier(update.id)
            guard identifiers.insert(update.id).inserted else {
                throw FloorpWebExtensionError.duplicateIdentifier(update.id)
            }
            guard let existing = draft[update.id] else {
                throw FloorpWebExtensionError.invalidScriptID(update.id)
            }
            draft[update.id] = StoredScript(
                script: existing.script.applying(update),
                registrationOrder: existing.registrationOrder
            )
        }

        try Self.validate(draft)
        scriptsByExtension[extensionID] = draft
    }

    /// Removes every script when `identifiers` is empty, matching the MV3 API.
    func unregister(_ identifiers: [String], for extensionID: FloorpWebExtensionID) throws {
        let current = scriptsByExtension[extensionID] ?? [:]
        let requestedIdentifiers = identifiers.isEmpty ? Array(current.keys) : identifiers
        var seen = Set<String>()

        for identifier in requestedIdentifiers {
            try Self.validateIdentifier(identifier)
            guard seen.insert(identifier).inserted else {
                throw FloorpWebExtensionError.duplicateIdentifier(identifier)
            }
            guard current[identifier] != nil else {
                throw FloorpWebExtensionError.invalidScriptID(identifier)
            }
        }

        var draft = current
        for identifier in requestedIdentifiers {
            draft.removeValue(forKey: identifier)
        }
        if draft.isEmpty {
            scriptsByExtension.removeValue(forKey: extensionID)
        } else {
            scriptsByExtension[extensionID] = draft
        }
    }

    func registeredScripts(for extensionID: FloorpWebExtensionID) -> [FloorpWebExtensionRegisteredScript] {
        orderedScripts(for: extensionID).map(\.script)
    }

    /// Plans scripts after the coordinator has already resolved eligible hosts.
    func plan(
        for tab: FloorpWebExtensionTabContext,
        allowedExtensionIDs: Set<FloorpWebExtensionID>
    ) -> [FloorpWebExtensionScriptPlan] {
        let candidates = scriptsByExtension.flatMap { extensionID, scripts in
            scripts.values.compactMap { stored -> FloorpWebExtensionScriptPlan? in
                guard allowedExtensionIDs.contains(extensionID),
                      stored.script.matches.contains(where: { $0.matches(tab.url) }),
                      !stored.script.excludeMatches.contains(where: { $0.matches(tab.url) }) else {
                    return nil
                }
                return FloorpWebExtensionScriptPlan(
                    extensionID: extensionID,
                    script: stored.script,
                    registrationOrder: stored.registrationOrder
                )
            }
        }
        return candidates.sorted {
            if $0.registrationOrder != $1.registrationOrder {
                return $0.registrationOrder < $1.registrationOrder
            }
            if $0.extensionID.rawValue != $1.extensionID.rawValue {
                return $0.extensionID.rawValue < $1.extensionID.rawValue
            }
            return $0.script.id < $1.script.id
        }
    }

    /// A convenience plan entry point that enforces both the scripting API and
    /// the normal/private per-site host grant.
    func plan(
        for tab: FloorpWebExtensionTabContext,
        permissionBroker: FloorpWebExtensionPermissionBroker
    ) async -> [FloorpWebExtensionScriptPlan] {
        var allowedExtensionIDs = Set<FloorpWebExtensionID>()
        for extensionID in scriptsByExtension.keys {
            guard await permissionBroker.allows(.scripting, extensionID: extensionID),
                  await permissionBroker.allowsHostAccess(for: extensionID, in: tab) else {
                continue
            }
            allowedExtensionIDs.insert(extensionID)
        }
        return plan(for: tab, allowedExtensionIDs: allowedExtensionIDs)
    }

    private func orderedScripts(for extensionID: FloorpWebExtensionID) -> [StoredScript] {
        (scriptsByExtension[extensionID] ?? [:]).values.sorted {
            if $0.registrationOrder != $1.registrationOrder {
                return $0.registrationOrder < $1.registrationOrder
            }
            return $0.script.id < $1.script.id
        }
    }

    private static func validate(_ scripts: [String: StoredScript]) throws {
        guard scripts.count <= maximumScriptsPerExtension else {
            throw FloorpWebExtensionError.quotaExceeded("registered content scripts")
        }

        var resourceBytes = 0
        for stored in scripts.values {
            let script = stored.script
            try validateIdentifier(script.id)
            guard !script.matches.isEmpty,
                  script.matches.count <= maximumMatchPatternsPerScript,
                  script.excludeMatches.count <= maximumMatchPatternsPerScript,
                  !script.javaScript.isEmpty || !script.styleSheets.isEmpty,
                  script.javaScript.count + script.styleSheets.count <= maximumSourcesPerScript else {
                throw FloorpWebExtensionError.unsupported("invalid registered content script \(script.id)")
            }
            resourceBytes += script.javaScript.reduce(into: 0) { $0 += $1.path.lengthOfBytes(using: .utf8) }
            resourceBytes += script.styleSheets.reduce(into: 0) { $0 += $1.path.lengthOfBytes(using: .utf8) }
        }
        guard resourceBytes <= maximumResourceBytesPerExtension else {
            throw FloorpWebExtensionError.quotaExceeded("registered content script resources")
        }
    }

    private static func validateIdentifier(_ identifier: String) throws {
        let isValid = !identifier.isEmpty &&
            identifier.lengthOfBytes(using: .utf8) <= 128 &&
            identifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard isValid else {
            throw FloorpWebExtensionError.invalidScriptID(identifier)
        }
    }
}

struct FloorpWebExtensionCSSTarget: Hashable, Codable, Sendable {
    let tabID: Int
    let documentGeneration: UInt64
    /// `nil` means the main frame. Child frame identifiers are issued by the
    /// tab coordinator for this document generation only.
    let frameID: UInt64?

    init(tab: FloorpWebExtensionTabContext, frameID: UInt64? = nil) {
        tabID = tab.tabID
        documentGeneration = tab.documentGeneration
        self.frameID = frameID
    }
}

struct FloorpWebExtensionCSSHandle: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.hasPrefix("floorp-css-"),
              rawValue.count <= 128,
              rawValue.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

struct FloorpWebExtensionCSSInsertion: Hashable, Sendable {
    let handle: FloorpWebExtensionCSSHandle
    let extensionID: FloorpWebExtensionID
    let target: FloorpWebExtensionCSSTarget
    let css: String
}

/// Tracks dynamically inserted CSS. A handle is capability-like: only the
/// extension that inserted it can remove it, and it is tied to one document and
/// frame so a handle cannot affect a later navigation.
/// Dynamic stylesheet handles are committed on the same actor as their
/// WebKit DOM mutation. Keeping this registry on `MainActor` lets the
/// coordinator perform its final live-document authorization, allocate (or
/// consume) handles, and enqueue the JavaScript mutation without an actor hop
/// that could admit a replacement navigation between those steps.
@MainActor
final class FloorpWebExtensionCSSRegistry {
    nonisolated static let maximumInsertionsPerExtension = 500
    nonisolated static let maximumStylesheetBytes = 128 * 1_024

    private var insertions = [FloorpWebExtensionCSSHandle: FloorpWebExtensionCSSInsertion]()
    private var handlesByExtension = [FloorpWebExtensionID: Set<FloorpWebExtensionCSSHandle>]()
    private let nextHandleSuffix: @Sendable () -> String

    init(nextHandleSuffix: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.nextHandleSuffix = nextHandleSuffix
    }

    func insert(
        css: String,
        for extensionID: FloorpWebExtensionID,
        target: FloorpWebExtensionCSSTarget
    ) throws -> FloorpWebExtensionCSSInsertion {
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              css.lengthOfBytes(using: .utf8) <= Self.maximumStylesheetBytes else {
            throw FloorpWebExtensionError.quotaExceeded("inserted stylesheet")
        }
        guard (handlesByExtension[extensionID]?.count ?? 0) < Self.maximumInsertionsPerExtension else {
            throw FloorpWebExtensionError.quotaExceeded("inserted stylesheets")
        }
        guard let handle = FloorpWebExtensionCSSHandle(rawValue: "floorp-css-\(nextHandleSuffix())"),
              insertions[handle] == nil else {
            throw FloorpWebExtensionError.invalidCSSHandle("generated handle")
        }

        let insertion = FloorpWebExtensionCSSInsertion(
            handle: handle,
            extensionID: extensionID,
            target: target,
            css: css
        )
        insertions[handle] = insertion
        handlesByExtension[extensionID, default: []].insert(handle)
        return insertion
    }

    func remove(
        _ handles: [FloorpWebExtensionCSSHandle],
        for extensionID: FloorpWebExtensionID,
        target: FloorpWebExtensionCSSTarget
    ) throws -> [FloorpWebExtensionCSSInsertion] {
        guard !handles.isEmpty else { return [] }
        var seen = Set<FloorpWebExtensionCSSHandle>()
        for handle in handles {
            guard seen.insert(handle).inserted,
                  let insertion = insertions[handle],
                  insertion.extensionID == extensionID,
                  insertion.target == target else {
                throw FloorpWebExtensionError.invalidCSSHandle(handle.rawValue)
            }
        }

        let removed = handles.compactMap { insertions[$0] }
        for handle in handles {
            insertions.removeValue(forKey: handle)
            handlesByExtension[extensionID]?.remove(handle)
        }
        if handlesByExtension[extensionID]?.isEmpty == true {
            handlesByExtension.removeValue(forKey: extensionID)
        }
        return removed
    }

    /// The permission-aware entry point used by the scripting API gateway.
    /// `target` must refer to the current tab document; a caller cannot insert
    /// CSS into a stale generation or a URL outside its host grant.
    func insert(
        css: String,
        for extensionID: FloorpWebExtensionID,
        target: FloorpWebExtensionCSSTarget,
        tab: FloorpWebExtensionTabContext,
        permissionBroker: FloorpWebExtensionPermissionBroker
    ) async throws -> FloorpWebExtensionCSSInsertion {
        guard target.tabID == tab.tabID,
              target.documentGeneration == tab.documentGeneration,
              await permissionBroker.allows(.scripting, extensionID: extensionID),
              await permissionBroker.allowsHostAccess(for: extensionID, in: tab) else {
            throw FloorpWebExtensionError.permissionDenied(FloorpWebExtensionAPIGrant.scripting.rawValue)
        }
        return try insert(css: css, for: extensionID, target: target)
    }

    func activeInsertions(for extensionID: FloorpWebExtensionID) -> [FloorpWebExtensionCSSInsertion] {
        (handlesByExtension[extensionID] ?? []).compactMap { insertions[$0] }.sorted {
            if $0.target.tabID != $1.target.tabID { return $0.target.tabID < $1.target.tabID }
            if $0.target.documentGeneration != $1.target.documentGeneration {
                return $0.target.documentGeneration < $1.target.documentGeneration
            }
            return $0.handle.rawValue < $1.handle.rawValue
        }
    }

    /// Drops every handle owned by one extension when its live composition is
    /// suspended or removed. The WebKit runtime independently removes the
    /// corresponding DOM nodes; this registry cleanup releases quota and
    /// prevents handles from an old activation from becoming valid again.
    func discardInsertions(for extensionID: FloorpWebExtensionID) {
        let handles = handlesByExtension.removeValue(forKey: extensionID) ?? []
        handles.forEach { insertions.removeValue(forKey: $0) }
    }

    func discardInsertions(for tab: FloorpWebExtensionTabContext) {
        let stale = insertions.values.filter {
            $0.target.tabID == tab.tabID && $0.target.documentGeneration == tab.documentGeneration
        }
        for insertion in stale {
            insertions.removeValue(forKey: insertion.handle)
            handlesByExtension[insertion.extensionID]?.remove(insertion.handle)
            if handlesByExtension[insertion.extensionID]?.isEmpty == true {
                handlesByExtension.removeValue(forKey: insertion.extensionID)
            }
        }
    }
}

enum FloorpWebExtensionCosmeticAction: String, Hashable, Codable, Sendable {
    case hide
    case remove
}

enum FloorpWebExtensionProceduralOperation: Hashable, Codable, Sendable {
    case hasText(String)
    case hasSelector(String)
    case attributeEquals(name: String, value: String)
}

struct FloorpWebExtensionProceduralFilter: Hashable, Codable, Sendable {
    let selector: String
    let operations: [FloorpWebExtensionProceduralOperation]
    let action: FloorpWebExtensionCosmeticAction

    init(
        selector: String,
        operations: [FloorpWebExtensionProceduralOperation],
        action: FloorpWebExtensionCosmeticAction = .hide
    ) {
        self.selector = selector
        self.operations = operations
        self.action = action
    }
}

/// The small allowlist is intentionally data-only. Generated resources never
/// accept a caller-supplied function body or string-eval expression.
enum FloorpWebExtensionScriptletName: String, Hashable, Codable, Sendable {
    case abortOnPropertyRead = "abort-on-property-read"
    case setConstant = "set-constant"
    case preventSetTimeout = "prevent-set-timeout"
}

struct FloorpWebExtensionScriptletInvocation: Hashable, Codable, Sendable {
    let name: FloorpWebExtensionScriptletName
    let arguments: [String]

    init(name: FloorpWebExtensionScriptletName, arguments: [String] = []) {
        self.name = name
        self.arguments = arguments
    }
}

struct FloorpWebExtensionCosmeticFilter: Hashable, Codable, Sendable {
    let matches: [FloorpWebExtensionMatchPattern]
    let excludeMatches: [FloorpWebExtensionMatchPattern]
    let selectors: [String]
    let proceduralFilters: [FloorpWebExtensionProceduralFilter]
    let scriptlets: [FloorpWebExtensionScriptletInvocation]
    let world: FloorpWebExtensionExecutionWorld

    init(
        matches: [FloorpWebExtensionMatchPattern],
        excludeMatches: [FloorpWebExtensionMatchPattern] = [],
        selectors: [String] = [],
        proceduralFilters: [FloorpWebExtensionProceduralFilter] = [],
        scriptlets: [FloorpWebExtensionScriptletInvocation] = [],
        world: FloorpWebExtensionExecutionWorld = .isolated
    ) {
        self.matches = matches
        self.excludeMatches = excludeMatches
        self.selectors = selectors
        self.proceduralFilters = proceduralFilters
        self.scriptlets = scriptlets
        self.world = world
    }
}

struct FloorpWebExtensionCosmeticResource: Hashable, Sendable {
    let matches: [FloorpWebExtensionMatchPattern]
    let excludeMatches: [FloorpWebExtensionMatchPattern]
    let css: String?
    let javaScript: String?
    let world: FloorpWebExtensionExecutionWorld

    /// A MAIN-world resource is never paired with the native extension bridge.
    var requiresNativeBridge: Bool {
        world == .isolated
    }

    func applies(to tab: FloorpWebExtensionTabContext) -> Bool {
        matches.contains(where: { $0.matches(tab.url) }) &&
            !excludeMatches.contains(where: { $0.matches(tab.url) })
    }
}

/// Safely compiles cosmetic, procedural, and scriptlet descriptors into fixed
/// CSS/JavaScript resources. Input data is size-bounded and embedded as base64
/// JSON, so selectors and scriptlet arguments cannot alter generated code.
enum FloorpWebExtensionCosmeticFilterBuilder {
    static let maximumSelectors = 1_000
    static let maximumProceduralFilters = 250
    static let maximumScriptlets = 128
    static let maximumSelectorBytes = 2_048
    static let maximumArgumentBytes = 4_096
    static let maximumInputBytes = 512 * 1_024

    private struct ProceduralPayload: Encodable {
        struct Operation: Encodable {
            let kind: String
            let value: String?
            let name: String?
        }

        let selector: String
        let action: String
        let operations: [Operation]
    }

    private struct ScriptletPayload: Encodable {
        let name: String
        let arguments: [String]
    }

    private struct Payload: Encodable {
        let procedural: [ProceduralPayload]
        let scriptlets: [ScriptletPayload]
    }

    static func build(_ filter: FloorpWebExtensionCosmeticFilter) throws -> FloorpWebExtensionCosmeticResource {
        guard !filter.matches.isEmpty,
              filter.matches.count <= FloorpWebExtensionScriptRegistry.maximumMatchPatternsPerScript,
              filter.excludeMatches.count <= FloorpWebExtensionScriptRegistry.maximumMatchPatternsPerScript,
              filter.selectors.count <= maximumSelectors,
              filter.proceduralFilters.count <= maximumProceduralFilters,
              filter.scriptlets.count <= maximumScriptlets,
              !filter.selectors.isEmpty || !filter.proceduralFilters.isEmpty || !filter.scriptlets.isEmpty else {
            throw FloorpWebExtensionError.unsupported("invalid cosmetic filter")
        }

        var inputBytes = 0
        for selector in filter.selectors {
            try validateSelector(selector)
            inputBytes += selector.lengthOfBytes(using: .utf8)
        }
        let payload = try makePayload(filter, inputBytes: &inputBytes)
        guard inputBytes <= maximumInputBytes else {
            throw FloorpWebExtensionError.quotaExceeded("cosmetic filter input")
        }

        let css = filter.selectors.isEmpty ? nil : filter.selectors.map {
            "\($0) { display: none !important; }"
        }.joined(separator: "\n")
        let javaScript: String?
        if filter.proceduralFilters.isEmpty && filter.scriptlets.isEmpty {
            javaScript = nil
        } else {
            let payloadData = try JSONEncoder().encode(payload)
            guard payloadData.count <= maximumInputBytes else {
                throw FloorpWebExtensionError.quotaExceeded("generated cosmetic resource")
            }
            javaScript = proceduralRuntime.replacingOccurrences(
                of: "__FLOORP_COSMETIC_PAYLOAD__",
                with: payloadData.base64EncodedString()
            )
        }

        return FloorpWebExtensionCosmeticResource(
            matches: filter.matches,
            excludeMatches: filter.excludeMatches,
            css: css,
            javaScript: javaScript,
            world: filter.world
        )
    }

    private static func makePayload(
        _ filter: FloorpWebExtensionCosmeticFilter,
        inputBytes: inout Int
    ) throws -> Payload {
        let procedural = try filter.proceduralFilters.map { filter in
            try validateSelector(filter.selector)
            inputBytes += filter.selector.lengthOfBytes(using: .utf8)
            guard !filter.operations.isEmpty, filter.operations.count <= 16 else {
                throw FloorpWebExtensionError.unsupported("invalid procedural cosmetic filter")
            }
            let operations = try filter.operations.map { operation -> ProceduralPayload.Operation in
                switch operation {
                case .hasText(let value):
                    try validateArgument(value)
                    inputBytes += value.lengthOfBytes(using: .utf8)
                    return .init(kind: "has-text", value: value, name: nil)
                case .hasSelector(let selector):
                    try validateSelector(selector)
                    inputBytes += selector.lengthOfBytes(using: .utf8)
                    return .init(kind: "has-selector", value: selector, name: nil)
                case .attributeEquals(let name, let value):
                    guard isAttributeName(name) else {
                        throw FloorpWebExtensionError.unsupported("invalid procedural attribute name")
                    }
                    try validateArgument(value)
                    inputBytes += name.lengthOfBytes(using: .utf8) + value.lengthOfBytes(using: .utf8)
                    return .init(kind: "attribute-equals", value: value, name: name)
                }
            }
            return ProceduralPayload(selector: filter.selector, action: filter.action.rawValue, operations: operations)
        }

        let scriptlets = try filter.scriptlets.map { scriptlet in
            guard scriptlet.arguments.count <= 8 else {
                throw FloorpWebExtensionError.quotaExceeded("scriptlet arguments")
            }
            for argument in scriptlet.arguments {
                try validateArgument(argument)
                inputBytes += argument.lengthOfBytes(using: .utf8)
            }
            return ScriptletPayload(name: scriptlet.name.rawValue, arguments: scriptlet.arguments)
        }
        return Payload(procedural: procedural, scriptlets: scriptlets)
    }

    private static func validateSelector(_ selector: String) throws {
        let forbidden = CharacterSet(charactersIn: "{};@\\u{0000}")
        guard !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selector.lengthOfBytes(using: .utf8) <= maximumSelectorBytes,
              selector.rangeOfCharacter(from: forbidden) == nil else {
            throw FloorpWebExtensionError.unsupported("unsafe cosmetic selector")
        }
    }

    private static func validateArgument(_ argument: String) throws {
        guard argument.lengthOfBytes(using: .utf8) <= maximumArgumentBytes,
              !argument.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw FloorpWebExtensionError.quotaExceeded("cosmetic scriptlet argument")
        }
    }

    private static func isAttributeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128,
              let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static let proceduralRuntime = """
    (() => {
      const bytes = Uint8Array.from(atob("__FLOORP_COSMETIC_PAYLOAD__"), value => value.charCodeAt(0));
      const payload = JSON.parse(new TextDecoder().decode(bytes));
      const safely = operation => { try { operation(); } catch (_) {} };
      const matches = (element, operations) => operations.every(operation => {
        if (operation.kind === "has-text") return (element.textContent || "").includes(operation.value);
        if (operation.kind === "has-selector") {
          try {
            return !!element.querySelector(operation.value);
          } catch (_) {
            return false;
          }
        }
        if (operation.kind === "attribute-equals") return element.getAttribute(operation.name) === operation.value;
        return false;
      });
      const applyProcedural = () => payload.procedural.forEach(rule => safely(() => {
        document.querySelectorAll(rule.selector).forEach(element => {
          if (!matches(element, rule.operations)) return;
          if (rule.action === "remove") element.remove();
          else element.style.setProperty("display", "none", "important");
        });
      }));
      const propertyName = value => /^[A-Za-z_$][A-Za-z0-9_$]{0,127}$/.test(value || "") ? value : null;
      const runScriptlet = scriptlet => safely(() => {
        const property = propertyName(scriptlet.arguments[0]);
        if (scriptlet.name === "abort-on-property-read" && property) {
          Object.defineProperty(globalThis, property, { configurable: true, get() { throw new ReferenceError(property); } });
        } else if (scriptlet.name === "set-constant" && property && scriptlet.arguments.length > 1) {
          Object.defineProperty(globalThis, property, {
            configurable: true,
            value: scriptlet.arguments[1],
            writable: false
          });
        } else if (scriptlet.name === "prevent-set-timeout" && scriptlet.arguments.length > 0) {
          const original = globalThis.setTimeout;
          const needle = scriptlet.arguments[0];
          globalThis.setTimeout = function(callback, ...arguments) {
            if (typeof callback === "string" && callback.includes(needle)) return 0;
            return original.call(this, callback, ...arguments);
          };
        }
      });
      payload.scriptlets.forEach(runScriptlet);
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", applyProcedural, { once: true });
      else applyProcedural();
    })();
    """
}
