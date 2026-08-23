// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

enum FloorpWebExtensionManifestCapabilityStatus: String, Codable, Comparable, Sendable {
    case supported
    case degraded
    case rejected

    private var sortOrder: Int {
        switch self {
        case .supported:
            return 0
        case .degraded:
            return 1
        case .rejected:
            return 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

struct FloorpWebExtensionManifestCapability: Codable, Equatable, Sendable {
    let name: String
    let status: FloorpWebExtensionManifestCapabilityStatus
    let detail: String
}

struct FloorpWebExtensionManifestPreflightReport: Codable, Equatable, Sendable {
    let manifest: FloorpWebExtensionManifest
    let capabilities: [FloorpWebExtensionManifestCapability]
    let status: FloorpWebExtensionManifestCapabilityStatus

    var isActivationAllowed: Bool {
        status == .supported
    }

    var requiresReview: Bool {
        status == .degraded
    }

    init(manifest: FloorpWebExtensionManifest, capabilities: [FloorpWebExtensionManifestCapability]) {
        self.manifest = manifest
        self.capabilities = capabilities
        status = capabilities.map(\ .status).max() ?? .supported
    }
}

enum FloorpWebExtensionManifestError: Error, Equatable, LocalizedError, Sendable {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            return "The extension manifest is malformed: \(detail)"
        }
    }
}

/// A caller-supplied, extraction-time description of one package resource.
///
/// The manifest parser deliberately does not touch the filesystem. The package
/// installer builds this inventory only after it has completed its archive
/// safety checks, then uses it to prove every executable manifest resource is
/// a bounded regular file in the staged package.
struct FloorpWebExtensionManifestPackageResource: Codable, Equatable, Sendable {
    let path: String
    let isRegularFile: Bool
    let byteSize: Int

    init(path: String, isRegularFile: Bool, byteSize: Int) {
        self.path = path
        self.isRegularFile = isRegularFile
        self.byteSize = byteSize
    }
}

/// The trusted file inventory produced by package extraction.
///
/// This intentionally records metadata rather than URLs or file handles, so
/// manifest preflight remains deterministic and cannot follow an attacker
/// controlled path while reporting compatibility.
struct FloorpWebExtensionManifestPackageInventory: Codable, Equatable, Sendable {
    let resources: [FloorpWebExtensionManifestPackageResource]

    init(resources: [FloorpWebExtensionManifestPackageResource]) {
        self.resources = resources
    }
}

struct FloorpWebExtensionManifestContentScript: Codable, Equatable, Sendable {
    let matches: [FloorpWebExtensionMatchPattern]
    let excludeMatches: [FloorpWebExtensionMatchPattern]
    let javaScript: [FloorpWebExtensionScriptSource]
    let styleSheets: [FloorpWebExtensionScriptSource]
    let runAt: FloorpWebExtensionRunAt
    let allFrames: Bool
    let world: FloorpWebExtensionExecutionWorld
    let matchAboutBlank: Bool
    let matchOriginAsFallback: Bool
}

struct FloorpWebExtensionManifestBackground: Codable, Equatable, Sendable {
    let serviceWorker: FloorpWebExtensionScriptSource?
    let type: String?
    let scripts: [FloorpWebExtensionScriptSource]
    let persistent: Bool?
}

struct FloorpWebExtensionManifestDNRRuleResource: Codable, Equatable, Sendable {
    let identifier: String
    let enabled: Bool
    let path: FloorpWebExtensionScriptSource
}

struct FloorpWebExtensionManifestAction: Codable, Equatable, Sendable {
    let defaultTitle: String?
    let defaultPopup: FloorpWebExtensionScriptSource?
}

struct FloorpWebExtensionManifestOptionsUI: Codable, Equatable, Sendable {
    let page: FloorpWebExtensionScriptSource
    let openInTab: Bool
}

/// The small MV3 manifest surface required before an extension package can be
/// staged. This is intentionally not a general Chrome manifest model.
struct FloorpWebExtensionManifest: Codable, Equatable, Sendable {
    /// A manifest resource larger than this cannot be safely compiled or
    /// injected during staging. The installer may enforce tighter archive
    /// limits, but manifest admission never accepts a larger executable file.
    static let maximumPackageResourceByteSize = 8 * 1_024 * 1_024

    let manifestVersion: Int
    let name: String
    let version: String
    let permissionNames: [String]
    let apiPermissions: Set<FloorpWebExtensionAPIGrant>
    let hostPermissions: [FloorpWebExtensionMatchPattern]
    let contentScripts: [FloorpWebExtensionManifestContentScript]
    let background: FloorpWebExtensionManifestBackground?
    let dnrRuleResources: [FloorpWebExtensionManifestDNRRuleResource]
    let action: FloorpWebExtensionManifestAction?
    let optionsUI: FloorpWebExtensionManifestOptionsUI?

    static func decode(_ data: Data) throws -> Self {
        let rawManifest: RawManifest
        do {
            rawManifest = try JSONDecoder().decode(RawManifest.self, from: data)
        } catch {
            throw FloorpWebExtensionManifestError.malformed("invalid JSON or field type")
        }

        guard isSafeDisplayValue(rawManifest.name, maximumLength: 256) else {
            throw FloorpWebExtensionManifestError.malformed("invalid name")
        }
        guard isValidVersion(rawManifest.version) else {
            throw FloorpWebExtensionManifestError.malformed("invalid version")
        }

        let hostPermissions = try rawManifest.hostPermissions.map {
            do {
                return try FloorpWebExtensionMatchPattern($0)
            } catch {
                throw FloorpWebExtensionManifestError.malformed("invalid host permission \($0)")
            }
        }

        let contentScripts = try rawManifest.contentScripts.enumerated().map { index, script in
            try contentScript(script, index: index)
        }

        let background = try rawManifest.background.map(makeBackground)
        let dnrRuleResources = try rawManifest.declarativeNetRequest?.ruleResources.enumerated().map { index, resource in
            try makeDNRRuleResource(resource, index: index)
        } ?? []
        let action = try rawManifest.action.map(makeAction)
        let optionsUI = try rawManifest.optionsUI.map(makeOptionsUI)

        return Self(
            manifestVersion: rawManifest.manifestVersion,
            name: rawManifest.name,
            version: rawManifest.version,
            permissionNames: rawManifest.permissions,
            apiPermissions: Set(rawManifest.permissions.compactMap(FloorpWebExtensionAPIGrant.init(rawValue:))),
            hostPermissions: hostPermissions,
            contentScripts: contentScripts,
            background: background,
            dnrRuleResources: dnrRuleResources,
            action: action,
            optionsUI: optionsUI
        )
    }

    static func preflight(
        manifestData: Data,
        ruleResourceData: [String: Data] = [:]
    ) throws -> FloorpWebExtensionManifestPreflightReport {
        try preflight(decode(manifestData), ruleResourceData: ruleResourceData)
    }

    /// Performs installation-grade manifest preflight against the package
    /// inventory built by the extractor. New staging paths must use this
    /// overload; the inventory-free overload remains for compatibility tools
    /// that can only inspect a manifest and explicitly cannot admit a package.
    static func preflight(
        manifestData: Data,
        packageInventory: FloorpWebExtensionManifestPackageInventory,
        ruleResourceData: [String: Data] = [:]
    ) throws -> FloorpWebExtensionManifestPreflightReport {
        preflight(
            try decode(manifestData),
            packageInventory: packageInventory,
            ruleResourceData: ruleResourceData
        )
    }

    static func preflight(
        _ manifest: Self,
        ruleResourceData: [String: Data] = [:]
    ) -> FloorpWebExtensionManifestPreflightReport {
        preflight(manifest, packageInventory: nil, ruleResourceData: ruleResourceData)
    }

    /// Performs installation-grade manifest preflight against a trusted
    /// package inventory. Every content-script source, background source, and
    /// DNR resource must be a present, bounded regular file before activation.
    static func preflight(
        _ manifest: Self,
        packageInventory: FloorpWebExtensionManifestPackageInventory,
        ruleResourceData: [String: Data] = [:]
    ) -> FloorpWebExtensionManifestPreflightReport {
        preflight(manifest, packageInventory: Optional(packageInventory), ruleResourceData: ruleResourceData)
    }

    private static func preflight(
        _ manifest: Self,
        packageInventory: FloorpWebExtensionManifestPackageInventory?,
        ruleResourceData: [String: Data]
    ) -> FloorpWebExtensionManifestPreflightReport {
        var capabilities = [FloorpWebExtensionManifestCapability]()
        let inventory = packageInventory.map { preflightPackageInventory($0, capabilities: &capabilities) }

        if manifest.manifestVersion == 3 {
            capabilities.append(.init(
                name: "manifest_version",
                status: .supported,
                detail: "Manifest V3 is supported."
            ))
        } else {
            capabilities.append(.init(
                name: "manifest_version",
                status: .rejected,
                detail: "Only Manifest V3 packages can be staged."
            ))
        }

        capabilities.append(.init(name: "name", status: .supported, detail: "The extension name is valid."))
        capabilities.append(.init(name: "version", status: .supported, detail: "The extension version is valid."))

        var seenPermissionNames = Set<String>()
        for permission in manifest.permissionNames {
            guard seenPermissionNames.insert(permission).inserted else {
                capabilities.append(.init(
                    name: "permission.\(permission)",
                    status: .rejected,
                    detail: "A required permission is declared more than once."
                ))
                continue
            }
            guard FloorpWebExtensionAPIGrant(rawValue: permission) != nil else {
                capabilities.append(.init(
                    name: "permission.\(permission)",
                    status: .rejected,
                    detail: "This required permission is not supported."
                ))
                continue
            }
            capabilities.append(.init(
                name: "permission.\(permission)",
                status: .supported,
                detail: "This required permission is supported."
            ))
        }

        var seenHostPermissions = Set<FloorpWebExtensionMatchPattern>()
        for pattern in manifest.hostPermissions {
            let status: FloorpWebExtensionManifestCapabilityStatus = seenHostPermissions.insert(pattern).inserted
                ? .supported
                : .rejected
            let detail = status == .supported
                ? "This host permission can be presented for per-site consent."
                : "A host permission is declared more than once."
            capabilities.append(.init(name: "host_permission.\(pattern.original)", status: status, detail: detail))
        }

        for (index, script) in manifest.contentScripts.enumerated() {
            capabilities.append(.init(
                name: "content_scripts[\(index)]",
                status: .supported,
                detail: "Static content scripts are supported."
            ))
            if script.matchAboutBlank {
                capabilities.append(.init(
                    name: "content_scripts[\(index)].match_about_blank",
                    status: .rejected,
                    detail: "about:blank frame inheritance is not available."
                ))
            }
            if script.matchOriginAsFallback {
                capabilities.append(.init(
                    name: "content_scripts[\(index)].match_origin_as_fallback",
                    status: .rejected,
                    detail: "Origin-fallback content-script matching is not available."
                ))
            }
        }

        if let background = manifest.background {
            if background.serviceWorker == nil {
                capabilities.append(.init(
                    name: "background",
                    status: .rejected,
                    detail: "An MV3 background declaration requires service_worker."
                ))
            } else {
                capabilities.append(.init(
                    name: "background.service_worker",
                    status: .supported,
                    detail: "The service worker can run in the lazy event runtime."
                ))
            }
            if let type = background.type, type.lowercased() != "module" {
                capabilities.append(.init(
                    name: "background.type",
                    status: .degraded,
                    detail: "Only module workers receive the full lazy event-runtime path."
                ))
            }
            if !background.scripts.isEmpty {
                capabilities.append(.init(
                    name: "background.scripts",
                    status: .rejected,
                    detail: "Legacy background script arrays are not supported for MV3."
                ))
            }
            if background.persistent == true {
                capabilities.append(.init(
                    name: "background.persistent",
                    status: .rejected,
                    detail: "Persistent background execution is not available."
                ))
            }
        }

        if manifest.action != nil {
            capabilities.append(.init(
                name: "action",
                status: .supported,
                detail: "Action metadata and a package-local popup are supported."
            ))
        }
        if manifest.optionsUI != nil {
            capabilities.append(.init(
                name: "options_ui",
                status: .supported,
                detail: "A package-local options page is supported."
            ))
        }

        if !manifest.dnrRuleResources.isEmpty,
           !manifest.apiPermissions.contains(.declarativeNetRequest) {
            capabilities.append(.init(
                name: "declarative_net_request",
                status: .rejected,
                detail: "Static rule resources require declarativeNetRequest permission."
            ))
        }

        if let inventory {
            capabilities.append(contentsOf: preflightDeclaredPackageResources(
                in: manifest,
                inventory: inventory
            ))
        }

        for resource in manifest.dnrRuleResources {
            guard let data = ruleResourceData[resource.path.path] else {
                capabilities.append(.init(
                    name: "declarative_net_request.rule_resources.\(resource.identifier)",
                    status: .rejected,
                    detail: "The declared rule resource was not provided for inspection."
                ))
                continue
            }
            if let inventory {
                guard let packageResource = inventory.resource(at: resource.path.path) else {
                    // The resource-specific inventory capability already
                    // explains the rejection. Never inspect data which was
                    // not proven to be the declared staged file.
                    continue
                }
                guard packageResource.byteSize == data.count else {
                    capabilities.append(.init(
                        name: "declarative_net_request.rule_resources.\(resource.identifier)",
                        status: .rejected,
                        detail: "The inspected rule resource byte size does not match the staged package inventory."
                    ))
                    continue
                }
            }
            capabilities.append(contentsOf: preflightDNRRules(in: data, resource: resource))
        }

        return FloorpWebExtensionManifestPreflightReport(manifest: manifest, capabilities: capabilities)
    }

    private static func contentScript(
        _ raw: RawContentScript,
        index: Int
    ) throws -> FloorpWebExtensionManifestContentScript {
        guard !raw.matches.isEmpty else {
            throw FloorpWebExtensionManifestError.malformed("content_scripts[\(index)].matches is empty")
        }
        let matches = try raw.matches.map(matchPattern)
        let excludeMatches = try raw.excludeMatches.map(matchPattern)
        let javaScript = try raw.javaScript.map { try resourcePath($0, field: "content_scripts[\(index)].js") }
        let styleSheets = try raw.styleSheets.map { try resourcePath($0, field: "content_scripts[\(index)].css") }
        guard !javaScript.isEmpty || !styleSheets.isEmpty else {
            throw FloorpWebExtensionManifestError.malformed("content_scripts[\(index)] has no js or css resource")
        }
        guard let runAt = raw.runAt.map(FloorpWebExtensionRunAt.init(rawValue:)) ?? .documentIdle else {
            throw FloorpWebExtensionManifestError.malformed("invalid content_scripts[\(index)].run_at")
        }
        guard let world = raw.world.map({ FloorpWebExtensionExecutionWorld(rawValue: $0.lowercased()) }) ?? .isolated else {
            throw FloorpWebExtensionManifestError.malformed("invalid content_scripts[\(index)].world")
        }
        return .init(
            matches: matches,
            excludeMatches: excludeMatches,
            javaScript: javaScript,
            styleSheets: styleSheets,
            runAt: runAt,
            allFrames: raw.allFrames,
            world: world,
            matchAboutBlank: raw.matchAboutBlank,
            matchOriginAsFallback: raw.matchOriginAsFallback
        )
    }

    private static func makeBackground(_ raw: RawBackground) throws -> FloorpWebExtensionManifestBackground {
        .init(
            serviceWorker: try raw.serviceWorker.map { try resourcePath($0, field: "background.service_worker") },
            type: raw.type,
            scripts: try raw.scripts.map { try resourcePath($0, field: "background.scripts") },
            persistent: raw.persistent
        )
    }

    private static func makeAction(_ raw: RawAction) throws -> FloorpWebExtensionManifestAction {
        if let title = raw.defaultTitle,
           !isSafeDisplayValue(title, maximumLength: 256) {
            throw FloorpWebExtensionManifestError.malformed("invalid action.default_title")
        }
        return try .init(
            defaultTitle: raw.defaultTitle,
            defaultPopup: raw.defaultPopup.map { try resourcePath($0, field: "action.default_popup") }
        )
    }

    private static func makeOptionsUI(_ raw: RawOptionsUI) throws -> FloorpWebExtensionManifestOptionsUI {
        try .init(
            page: resourcePath(raw.page, field: "options_ui.page"),
            openInTab: raw.openInTab
        )
    }

    private static func makeDNRRuleResource(
        _ raw: RawDNRRuleResource,
        index: Int
    ) throws -> FloorpWebExtensionManifestDNRRuleResource {
        guard isValidRuleResourceIdentifier(raw.identifier) else {
            throw FloorpWebExtensionManifestError.malformed(
                "invalid declarative_net_request.rule_resources[\(index)].id"
            )
        }
        return .init(
            identifier: raw.identifier,
            enabled: raw.enabled,
            path: try resourcePath(raw.path, field: "declarative_net_request.rule_resources[\(index)].path")
        )
    }

    private struct ValidatedPackageInventory {
        let resourcesByPath: [String: FloorpWebExtensionManifestPackageResource]
        let invalidPaths: Set<String>

        func resource(at path: String) -> FloorpWebExtensionManifestPackageResource? {
            guard !invalidPaths.contains(path) else { return nil }
            return resourcesByPath[path]
        }
    }

    private struct DeclaredPackageResource {
        let capabilityName: String
        let path: String
    }

    private static func preflightPackageInventory(
        _ packageInventory: FloorpWebExtensionManifestPackageInventory,
        capabilities: inout [FloorpWebExtensionManifestCapability]
    ) -> ValidatedPackageInventory {
        var resourcesByPath = [String: FloorpWebExtensionManifestPackageResource]()
        var invalidPaths = Set<String>()

        for (index, resource) in packageInventory.resources.enumerated() {
            let capabilityName = "package_inventory[\(index)]"
            guard let safePath = try? FloorpWebExtensionScriptSource(resource.path) else {
                capabilities.append(.init(
                    name: capabilityName,
                    status: .rejected,
                    detail: "A package inventory entry has an unsafe resource path."
                ))
                continue
            }

            let path = safePath.path
            guard resource.isRegularFile else {
                invalidPaths.insert(path)
                capabilities.append(.init(
                    name: capabilityName,
                    status: .rejected,
                    detail: "A package inventory entry is not a regular file."
                ))
                continue
            }
            guard (0...maximumPackageResourceByteSize).contains(resource.byteSize) else {
                invalidPaths.insert(path)
                capabilities.append(.init(
                    name: capabilityName,
                    status: .rejected,
                    detail: "A package inventory entry has an invalid or oversized byte size."
                ))
                continue
            }
            guard resourcesByPath[path] == nil else {
                invalidPaths.insert(path)
                capabilities.append(.init(
                    name: capabilityName,
                    status: .rejected,
                    detail: "The package inventory declares the same resource path more than once."
                ))
                continue
            }
            resourcesByPath[path] = resource
        }

        return .init(resourcesByPath: resourcesByPath, invalidPaths: invalidPaths)
    }

    private static func preflightDeclaredPackageResources(
        in manifest: Self,
        inventory: ValidatedPackageInventory
    ) -> [FloorpWebExtensionManifestCapability] {
        var declared = [DeclaredPackageResource]()
        for (scriptIndex, script) in manifest.contentScripts.enumerated() {
            declared += script.javaScript.enumerated().map {
                .init(
                    capabilityName: "package_resource.content_scripts[\(scriptIndex)].js[\($0.offset)]",
                    path: $0.element.path
                )
            }
            declared += script.styleSheets.enumerated().map {
                .init(
                    capabilityName: "package_resource.content_scripts[\(scriptIndex)].css[\($0.offset)]",
                    path: $0.element.path
                )
            }
        }
        if let background = manifest.background {
            if let serviceWorker = background.serviceWorker {
                declared.append(.init(
                    capabilityName: "package_resource.background.service_worker",
                    path: serviceWorker.path
                ))
            }
            declared += background.scripts.enumerated().map {
                .init(
                    capabilityName: "package_resource.background.scripts[\($0.offset)]",
                    path: $0.element.path
                )
            }
        }
        if let popup = manifest.action?.defaultPopup {
            declared.append(.init(
                capabilityName: "package_resource.action.default_popup",
                path: popup.path
            ))
        }
        if let optionsUI = manifest.optionsUI {
            declared.append(.init(
                capabilityName: "package_resource.options_ui.page",
                path: optionsUI.page.path
            ))
        }
        declared += manifest.dnrRuleResources.map {
            .init(
                capabilityName: "package_resource.declarative_net_request.rule_resources.\($0.identifier)",
                path: $0.path.path
            )
        }

        return declared.map { resource in
            guard inventory.resource(at: resource.path) != nil else {
                return .init(
                    name: resource.capabilityName,
                    status: .rejected,
                    detail: "The declared resource is absent, invalid, or oversized in the staged package inventory."
                )
            }
            return .init(
                name: resource.capabilityName,
                status: .supported,
                detail: "The declared resource is a bounded regular file in the staged package inventory."
            )
        }
    }

    private static func preflightDNRRules(
        in data: Data,
        resource: FloorpWebExtensionManifestDNRRuleResource
    ) -> [FloorpWebExtensionManifestCapability] {
        let rules: [RawDNRRule]
        do {
            rules = try JSONDecoder().decode([RawDNRRule].self, from: data)
        } catch {
            return [.init(
                name: "declarative_net_request.rule_resources.\(resource.identifier)",
                status: .rejected,
                detail: "The rule resource is not a valid JSON rule array."
            )]
        }

        var capabilities = [FloorpWebExtensionManifestCapability]()
        var ruleIDs = Set<Int>()
        for (index, rule) in rules.enumerated() {
            let name = "declarative_net_request.rule_resources.\(resource.identifier)[\(index)]"
            guard let identifier = rule.identifier, identifier > 0, ruleIDs.insert(identifier).inserted else {
                capabilities.append(.init(
                    name: name,
                    status: .rejected,
                    detail: "Each DNR rule requires a unique positive id."
                ))
                continue
            }
            guard rule.priority == nil || rule.priority! > 0 else {
                capabilities.append(.init(
                    name: name,
                    status: .rejected,
                    detail: "Each DNR rule priority must be positive."
                ))
                continue
            }
            guard let action = rule.action?.type else {
                capabilities.append(.init(
                    name: name,
                    status: .rejected,
                    detail: "Each DNR rule requires an action type."
                ))
                continue
            }
            if let reason = unsupportedDNRConditionReason(rule.condition) {
                capabilities.append(.init(name: name, status: .rejected, detail: reason))
                continue
            }
            switch action {
            case "block", "upgradeScheme":
                capabilities.append(.init(name: name, status: .supported, detail: "The \(action) DNR action is supported."))
            case "allow":
                capabilities.append(.init(
                    name: name,
                    status: .degraded,
                    detail: "The allow DNR action requires ordered-rule compatibility review."
                ))
            case "allowAllRequests", "redirect", "modifyHeaders":
                capabilities.append(.init(
                    name: name,
                    status: .rejected,
                    detail: "The \(action) DNR action is not supported by the WebKit rule path."
                ))
            default:
                capabilities.append(.init(
                    name: name,
                    status: .rejected,
                    detail: "The \(action) DNR action is unknown or unsupported."
                ))
            }
        }
        if rules.isEmpty {
            capabilities.append(.init(
                name: "declarative_net_request.rule_resources.\(resource.identifier)",
                status: .supported,
                detail: "The static DNR rule resource is empty."
            ))
        }
        return capabilities
    }

    private static func unsupportedDNRConditionReason(_ condition: RawDNRCondition?) -> String? {
        guard let condition else { return nil }
        guard !(condition.urlFilter != nil && condition.regexFilter != nil) else {
            return "urlFilter and regexFilter cannot both be present."
        }
        if let urlFilter = condition.urlFilter {
            guard !urlFilter.isEmpty else { return "urlFilter cannot be empty." }
            guard urlFilter.utf8.count <= 2_000 else {
                return "urlFilter exceeds the 2000 byte safety limit."
            }
            guard urlFilter.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
                return "urlFilter contains unsupported non-ASCII or control characters."
            }
            guard isSupportedDNRURLFilter(urlFilter) else {
                return "urlFilter cannot be safely converted to a WebKit regular expression."
            }
        }
        if let regexFilter = condition.regexFilter {
            guard !regexFilter.isEmpty else { return "regexFilter cannot be empty." }
            guard isSupportedDNRRegex(regexFilter) else {
                return "regexFilter is not compatible with the WebKit rule path."
            }
        }
        if condition.isUrlFilterCaseSensitive != nil && condition.urlFilter == nil {
            return "isUrlFilterCaseSensitive is valid only with urlFilter."
        }
        if let domainType = condition.domainType,
           domainType != "firstParty", domainType != "thirdParty" {
            return "DNR domainType is unknown or unsupported."
        }
        guard condition.initiatorDomains.isEmpty, condition.excludedInitiatorDomains.isEmpty else {
            return "Initiator-domain DNR conditions are not representable by WebKit."
        }
        guard condition.tabIDs.isEmpty, condition.excludedTabIDs.isEmpty else {
            return "Tab-scoped DNR conditions are not supported by the WebKit rule path."
        }
        guard condition.requestMethods.isEmpty else {
            return "Request-method DNR conditions are not supported by the WebKit rule path."
        }
        guard condition.responseHeaders.isEmpty, condition.excludedResponseHeaders.isEmpty else {
            return "Response-header DNR conditions are not supported by the WebKit rule path."
        }
        for (field, domains) in [
            ("requestDomains", condition.requestDomains),
            ("excludedRequestDomains", condition.excludedRequestDomains)
        ] {
            guard Set(domains).count == domains.count,
                  domains.allSatisfy(isValidDNRDomain) else {
                return "\(field) contains an invalid or duplicate domain."
            }
        }
        let supportedResourceTypes: Set<String> = [
            "main_frame", "stylesheet", "script", "image", "font", "media", "xmlhttprequest"
        ]
        guard Set(condition.resourceTypes).count == condition.resourceTypes.count,
              Set(condition.excludedResourceTypes).count == condition.excludedResourceTypes.count else {
            return "DNR resource type conditions contain duplicates."
        }
        let resourceTypes = condition.resourceTypes + condition.excludedResourceTypes
        guard Set(resourceTypes).isSubset(of: supportedResourceTypes) else {
            return "DNR resource type conditions are not exactly representable by WebKit."
        }
        let selectedTypes = condition.resourceTypes.isEmpty
            ? supportedResourceTypes.subtracting(Set(condition.excludedResourceTypes))
            : Set(condition.resourceTypes).subtracting(Set(condition.excludedResourceTypes))
        guard !selectedTypes.isEmpty else {
            return "DNR resource type conditions exclude every WebKit-supported resource type."
        }
        return nil
    }

    private static func isSupportedDNRURLFilter(_ filter: String) -> Bool {
        !filter.dropLast().contains("|")
    }

    private static func isSupportedDNRRegex(_ regex: String) -> Bool {
        guard regex.utf8.count <= 2_000, !hasUnsupportedDNRRegexGroupSyntax(regex) else { return false }
        if let expression = try? NSRegularExpression(pattern: "\\\\[1-9]"),
           expression.firstMatch(in: regex, range: NSRange(regex.startIndex..., in: regex)) != nil {
            return false
        }
        return (try? NSRegularExpression(pattern: regex)) != nil
    }

    private static func hasUnsupportedDNRRegexGroupSyntax(_ regex: String) -> Bool {
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
            guard groupKind < regex.endIndex, regex[groupKind] == ":" else { return true }
            regex.formIndex(after: &index)
        }
        return false
    }

    private static func isValidDNRDomain(_ value: String) -> Bool {
        let domain = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
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

    private static func matchPattern(_ pattern: String) throws -> FloorpWebExtensionMatchPattern {
        do {
            return try FloorpWebExtensionMatchPattern(pattern)
        } catch {
            throw FloorpWebExtensionManifestError.malformed("invalid content-script match pattern \(pattern)")
        }
    }

    private static func resourcePath(_ path: String, field: String) throws -> FloorpWebExtensionScriptSource {
        do {
            return try FloorpWebExtensionScriptSource(path)
        } catch {
            throw FloorpWebExtensionManifestError.malformed("invalid \(field) resource path")
        }
    }

    private static func isSafeDisplayValue(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.count <= maximumLength &&
            value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
            }
    }

    private static func isValidVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count) else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = UInt(component),
                  number <= 65_535 else {
                return false
            }
            return component == "0" || !component.hasPrefix("0")
        }
    }

    private static func isValidRuleResourceIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }
}

private extension FloorpWebExtensionManifest {
    struct RawManifest: Decodable {
        enum CodingKeys: String, CodingKey {
            case manifestVersion = "manifest_version"
            case name
            case version
            case permissions
            case hostPermissions = "host_permissions"
            case contentScripts = "content_scripts"
            case background
            case declarativeNetRequest = "declarative_net_request"
            case action
            case optionsUI = "options_ui"
        }

        let manifestVersion: Int
        let name: String
        let version: String
        let permissions: [String]
        let hostPermissions: [String]
        let contentScripts: [RawContentScript]
        let background: RawBackground?
        let declarativeNetRequest: RawDeclarativeNetRequest?
        let action: RawAction?
        let optionsUI: RawOptionsUI?

        init(from decoder: Decoder) throws {
            let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
            try rejectUnknownKeys(rawContainer, allowed: CodingKeys.self, scope: "top-level manifest")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            manifestVersion = try container.decode(Int.self, forKey: .manifestVersion)
            name = try container.decode(String.self, forKey: .name)
            version = try container.decode(String.self, forKey: .version)
            permissions = try container.valueIfPresent([String].self, forKey: .permissions) ?? []
            hostPermissions = try container.valueIfPresent([String].self, forKey: .hostPermissions) ?? []
            contentScripts = try container.valueIfPresent([RawContentScript].self, forKey: .contentScripts) ?? []
            background = try container.valueIfPresent(RawBackground.self, forKey: .background)
            declarativeNetRequest = try container.valueIfPresent(
                RawDeclarativeNetRequest.self,
                forKey: .declarativeNetRequest
            )
            action = try container.valueIfPresent(RawAction.self, forKey: .action)
            optionsUI = try container.valueIfPresent(RawOptionsUI.self, forKey: .optionsUI)
        }
    }

    struct RawContentScript: Decodable {
        enum CodingKeys: String, CodingKey {
            case matches
            case excludeMatches = "exclude_matches"
            case javaScript = "js"
            case styleSheets = "css"
            case runAt = "run_at"
            case allFrames = "all_frames"
            case world
            case matchAboutBlank = "match_about_blank"
            case matchOriginAsFallback = "match_origin_as_fallback"
        }

        let matches: [String]
        let excludeMatches: [String]
        let javaScript: [String]
        let styleSheets: [String]
        let runAt: String?
        let allFrames: Bool
        let world: String?
        let matchAboutBlank: Bool
        let matchOriginAsFallback: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            matches = try container.decode([String].self, forKey: .matches)
            excludeMatches = try container.valueIfPresent([String].self, forKey: .excludeMatches) ?? []
            javaScript = try container.valueIfPresent([String].self, forKey: .javaScript) ?? []
            styleSheets = try container.valueIfPresent([String].self, forKey: .styleSheets) ?? []
            runAt = try container.valueIfPresent(String.self, forKey: .runAt)
            allFrames = try container.valueIfPresent(Bool.self, forKey: .allFrames) ?? false
            world = try container.valueIfPresent(String.self, forKey: .world)
            matchAboutBlank = try container.valueIfPresent(Bool.self, forKey: .matchAboutBlank) ?? false
            matchOriginAsFallback = try container.valueIfPresent(Bool.self, forKey: .matchOriginAsFallback) ?? false
        }
    }

    struct RawBackground: Decodable {
        enum CodingKeys: String, CodingKey {
            case serviceWorker = "service_worker"
            case type
            case scripts
            case persistent
        }

        let serviceWorker: String?
        let type: String?
        let scripts: [String]
        let persistent: Bool?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            serviceWorker = try container.valueIfPresent(String.self, forKey: .serviceWorker)
            type = try container.valueIfPresent(String.self, forKey: .type)
            scripts = try container.valueIfPresent([String].self, forKey: .scripts) ?? []
            persistent = try container.valueIfPresent(Bool.self, forKey: .persistent)
        }
    }

    struct RawAction: Decodable {
        enum CodingKeys: String, CodingKey {
            case defaultTitle = "default_title"
            case defaultPopup = "default_popup"
        }

        let defaultTitle: String?
        let defaultPopup: String?

        init(from decoder: Decoder) throws {
            let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
            try rejectUnknownKeys(rawContainer, allowed: CodingKeys.self, scope: "action")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultTitle = try container.valueIfPresent(String.self, forKey: .defaultTitle)
            defaultPopup = try container.valueIfPresent(String.self, forKey: .defaultPopup)
        }
    }

    struct RawOptionsUI: Decodable {
        enum CodingKeys: String, CodingKey {
            case page
            case openInTab = "open_in_tab"
        }

        let page: String
        let openInTab: Bool

        init(from decoder: Decoder) throws {
            let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
            try rejectUnknownKeys(rawContainer, allowed: CodingKeys.self, scope: "options_ui")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            page = try container.decode(String.self, forKey: .page)
            openInTab = try container.valueIfPresent(Bool.self, forKey: .openInTab) ?? false
        }
    }

    struct RawDeclarativeNetRequest: Decodable {
        enum CodingKeys: String, CodingKey {
            case ruleResources = "rule_resources"
        }

        let ruleResources: [RawDNRRuleResource]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ruleResources = try container.decode([RawDNRRuleResource].self, forKey: .ruleResources)
        }
    }

    struct RawDNRRuleResource: Decodable {
        enum CodingKeys: String, CodingKey {
            case identifier = "id"
            case enabled
            case path
        }

        let identifier: String
        let enabled: Bool
        let path: String
    }

    struct RawDNRRule: Decodable {
        let identifier: Int?
        let priority: Int?
        let action: RawDNRAction?
        let condition: RawDNRCondition?

        enum CodingKeys: String, CodingKey {
            case identifier = "id"
            case priority
            case action
            case condition
        }

        init(from decoder: Decoder) throws {
            let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
            try rejectUnknownKeys(rawContainer, allowed: CodingKeys.self, scope: "DNR rule")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try container.valueIfPresent(Int.self, forKey: .identifier)
            priority = try container.valueIfPresent(Int.self, forKey: .priority)
            action = try container.valueIfPresent(RawDNRAction.self, forKey: .action)
            condition = try container.valueIfPresent(RawDNRCondition.self, forKey: .condition)
        }
    }

    struct RawDNRAction: Decodable {
        let type: String?

        enum CodingKeys: String, CodingKey {
            case type
        }

        init(from decoder: Decoder) throws {
            let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
            try rejectUnknownKeys(rawContainer, allowed: CodingKeys.self, scope: "DNR action")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.valueIfPresent(String.self, forKey: .type)
        }
    }

    struct RawDNRCondition: Decodable {
        let urlFilter: String?
        let regexFilter: String?
        let isUrlFilterCaseSensitive: Bool?
        let requestDomains: [String]
        let excludedRequestDomains: [String]
        let initiatorDomains: [String]
        let excludedInitiatorDomains: [String]
        let resourceTypes: [String]
        let excludedResourceTypes: [String]
        let domainType: String?
        let tabIDs: [Int]
        let excludedTabIDs: [Int]
        let requestMethods: [String]
        let responseHeaders: [String]
        let excludedResponseHeaders: [String]

        enum CodingKeys: String, CodingKey {
            case urlFilter
            case regexFilter
            case isUrlFilterCaseSensitive
            case requestDomains
            case excludedRequestDomains
            case initiatorDomains
            case excludedInitiatorDomains
            case resourceTypes
            case excludedResourceTypes
            case domainType
            case tabIDs = "tabIds"
            case excludedTabIDs = "excludedTabIds"
            case requestMethods
            case responseHeaders
            case excludedResponseHeaders
        }

        init(from decoder: Decoder) throws {
            let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
            try rejectUnknownKeys(rawContainer, allowed: CodingKeys.self, scope: "DNR condition")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            urlFilter = try container.valueIfPresent(String.self, forKey: .urlFilter)
            regexFilter = try container.valueIfPresent(String.self, forKey: .regexFilter)
            isUrlFilterCaseSensitive = try container.valueIfPresent(Bool.self, forKey: .isUrlFilterCaseSensitive)
            requestDomains = try container.valueIfPresent([String].self, forKey: .requestDomains) ?? []
            excludedRequestDomains = try container.valueIfPresent([String].self, forKey: .excludedRequestDomains) ?? []
            initiatorDomains = try container.valueIfPresent([String].self, forKey: .initiatorDomains) ?? []
            excludedInitiatorDomains = try container.valueIfPresent([String].self, forKey: .excludedInitiatorDomains) ?? []
            resourceTypes = try container.valueIfPresent([String].self, forKey: .resourceTypes) ?? []
            excludedResourceTypes = try container.valueIfPresent([String].self, forKey: .excludedResourceTypes) ?? []
            domainType = try container.valueIfPresent(String.self, forKey: .domainType)
            tabIDs = try container.valueIfPresent([Int].self, forKey: .tabIDs) ?? []
            excludedTabIDs = try container.valueIfPresent([Int].self, forKey: .excludedTabIDs) ?? []
            requestMethods = try container.valueIfPresent([String].self, forKey: .requestMethods) ?? []
            responseHeaders = try container.valueIfPresent([String].self, forKey: .responseHeaders) ?? []
            excludedResponseHeaders = try container.valueIfPresent([String].self, forKey: .excludedResponseHeaders) ?? []
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys<Key: CodingKey>(
    _ container: KeyedDecodingContainer<AnyCodingKey>,
    allowed: Key.Type,
    scope: String
) throws {
    guard let unexpectedKey = container.allKeys.first(where: { allowed.init(stringValue: $0.stringValue) == nil }) else {
        return
    }
    throw DecodingError.dataCorrupted(.init(
        codingPath: container.codingPath + [unexpectedKey],
        debugDescription: "unknown \(scope) key"
    ))
}

private extension KeyedDecodingContainer {
    func valueIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(T.self, forKey: key)
    }
}
