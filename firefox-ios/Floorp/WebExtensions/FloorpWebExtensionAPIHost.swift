// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import WebKit

private struct FloorpWebExtensionDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private func rejectUnknownKeys(
    in decoder: Decoder,
    allowing allowedKeys: Set<String>
) throws {
    let container = try decoder.container(keyedBy: FloorpWebExtensionDynamicCodingKey.self)
    guard let unknownKey = container.allKeys.first(where: { !allowedKeys.contains($0.stringValue) }) else {
        return
    }
    throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath + [unknownKey],
        debugDescription: "Unsupported key: \(unknownKey.stringValue)"
    ))
}

@MainActor
protocol FloorpWebExtensionNativeAPIDispatching: AnyObject {
    func dispatch(
        operation: String,
        payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload?
}

/// Trusted live-document authority used by the dynamic CSS API. The resolver
/// is supplied by browser UI composition, never by extension JavaScript. Its
/// document context and WebView must describe the same current navigation.
@MainActor
struct FloorpWebExtensionLiveScriptingTarget {
    let tab: FloorpWebExtensionTabContext
    let webView: WKWebView
}

/// Parsed permission expansion presented to an application-owned consent UI.
/// `permissions.request` is rejected when no authorizer is installed, so a
/// JavaScript boolean or synthetic event can never stand in for user action.
struct FloorpWebExtensionPermissionRequest: Sendable {
    let extensionID: FloorpWebExtensionID
    let packageGeneration: String?
    let apiPermissions: Set<FloorpWebExtensionAPIGrant>
    let origins: Set<FloorpWebExtensionMatchPattern>
}

/// Profile-owned native implementation of the Stage 2 API subset.
///
/// The message bridge authenticates the extension and document before this
/// host sees a request. This second boundary still verifies profile mode,
/// active package state, API permission, payload shape, and store quotas so a
/// compromised content script cannot acquire a capability by naming it.
@MainActor
final class FloorpWebExtensionAPIHost: FloorpWebExtensionNativeAPIDispatching {
    typealias AlarmEventHandler = @MainActor @Sendable (FloorpWebExtensionAlarmEvent) async -> Void
    typealias RuntimeReloader = @MainActor @Sendable (FloorpWebExtensionID) async throws -> Void
    typealias PermissionRequestAuthorizer = @MainActor @Sendable (
        FloorpWebExtensionPermissionRequest
    ) async -> Bool
    typealias PermissionMutationHandler = @MainActor @Sendable (
        FloorpWebExtensionPermissionSnapshot,
        FloorpWebExtensionID,
        String?
    ) async throws -> Void
    typealias LiveScriptingTargetResolver = @MainActor @Sendable (
        Int
    ) throws -> FloorpWebExtensionLiveScriptingTarget

    private struct ActiveExtension {
        let authorityRevision: UUID
        var permissions: Set<FloorpWebExtensionAPIGrant>
        let defaultLocale: String
        let declaredPermissions: Set<FloorpWebExtensionAPIGrant>
        let declaredHosts: Set<FloorpWebExtensionMatchPattern>
        let optionalPermissions: Set<FloorpWebExtensionAPIGrant>
        let optionalHosts: Set<FloorpWebExtensionMatchPattern>
        let rawManifest: Data?
        let packageGeneration: String?
        let resourcePaths: Set<String>
    }

    private enum PermissionMutationAuthority {
        case liveManager(
            FloorpWebExtensionLivePackageManager,
            FloorpWebExtensionLivePackageManager.PermissionMutationAuthorization
        )
        case injected(packageGeneration: String?)
    }

    private struct KeysRequest: Decodable {
        let keys: [String]?
    }

    private struct StorageSetRequest: Decodable {
        let items: [String: FloorpWebExtensionJSONValue]
    }

    private struct TabsQueryInfoRequest: Decodable {
        let active: Bool?
        let currentWindow: Bool?
        let current: Bool?
    }

    private struct TabsQueryRequest: Decodable {
        let queryInfo: TabsQueryInfoRequest?
    }

    private struct TabsIDRequest: Decodable {
        let tabId: Int
    }

    private struct TabsCreatePropertiesRequest: Decodable {
        let url: String?
        let active: Bool?
    }

    private struct TabsCreateRequest: Decodable {
        let createProperties: TabsCreatePropertiesRequest?
    }

    private struct TabsUpdatePropertiesRequest: Decodable {
        let url: String?
    }

    private struct TabsUpdateRequest: Decodable {
        let tabId: Int
        let updateProperties: TabsUpdatePropertiesRequest?
    }

    private struct TabsReloadPropertiesRequest: Decodable {
        let bypassCache: Bool?
    }

    private struct TabsReloadRequest: Decodable {
        let tabId: Int
        let reloadProperties: TabsReloadPropertiesRequest?
    }

    private struct TabsSendMessageRequest: Decodable {
        let tabId: Int
        let message: FloorpWebExtensionJSONValue
        let options: [String: FloorpWebExtensionJSONValue]?
    }

    private struct AlarmNameRequest: Decodable {
        let name: String
    }

    private struct AlarmCreateRequest: Decodable {
        let name: String
        let when: Double?
        let delayInMinutes: Double?
        let periodInMinutes: Double?
    }

    private struct I18nMessageRequest: Decodable {
        let name: String
        let substitutions: [String]
    }

    private struct ActionTextRequest: Decodable {
        let value: String?
    }

    private struct RuntimeGetURLRequest: Decodable {
        let path: String
    }

    private struct PermissionDetailsRequest: Decodable {
        let permissions: [String]?
        let origins: [String]?
    }

    private struct RegisteredScriptFilterRequest: Decodable {
        struct Filter: Decodable { let ids: [String]? }
        let filter: Filter?
    }

    private struct RegisteredScriptDetails: Decodable {
        let id: String
        let matches: [String]?
        let excludeMatches: [String]?
        let js: [String]?
        let css: [String]?
        let runAt: String?
        let allFrames: Bool?
        let world: String?
        let persistAcrossSessions: Bool?
    }

    private struct RegisterScriptsRequest: Decodable {
        let scripts: [RegisteredScriptDetails]
    }

    private struct UnregisterScriptsRequest: Decodable {
        let ids: [String]?
    }

    private struct ScriptingTargetRequest: Decodable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case tabId
            case frameIds
            case documentIds
            case allFrames
        }

        let tabId: Int
        let frameIds: [UInt64]?
        let documentIds: [String]?
        let allFrames: Bool?

        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowing: Set(CodingKeys.allCases.map(\.rawValue)))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tabId = try container.decode(Int.self, forKey: .tabId)
            frameIds = try container.decodeIfPresent([UInt64].self, forKey: .frameIds)
            documentIds = try container.decodeIfPresent([String].self, forKey: .documentIds)
            allFrames = try container.decodeIfPresent(Bool.self, forKey: .allFrames)
        }
    }

    private struct InsertCSSRequest: Decodable {
        let target: ScriptingTargetRequest
        let css: String?
        let files: [String]?
        let origin: String?
    }

    private struct ExecuteScriptRequest: Decodable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case target
            case files
            case functionSource = "func"
            case args
            case world
            case injectImmediately
        }

        let target: ScriptingTargetRequest
        let files: [String]?
        let functionSource: String?
        let args: [FloorpWebExtensionJSONValue]?
        let world: String?
        let injectImmediately: Bool?

        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowing: Set(CodingKeys.allCases.map(\.rawValue)))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            target = try container.decode(ScriptingTargetRequest.self, forKey: .target)
            files = try container.decodeIfPresent([String].self, forKey: .files)
            functionSource = try container.decodeIfPresent(String.self, forKey: .functionSource)
            args = try container.decodeIfPresent(
                [FloorpWebExtensionJSONValue].self,
                forKey: .args
            )
            world = try container.decodeIfPresent(String.self, forKey: .world)
            injectImmediately = try container.decodeIfPresent(Bool.self, forKey: .injectImmediately)
        }
    }

    private enum CSSInjectionSource: Hashable {
        case inline(String)
        case files([String])
    }

    private struct CSSInjectionIdentity: Hashable {
        let tabID: Int
        let documentGeneration: UInt64
        let frameIDs: [UInt64]?
        let origin: String
        let source: CSSInjectionSource
    }

    private struct TrackedCSSInsertion {
        let identity: CSSInjectionIdentity
        let handle: FloorpWebExtensionCSSHandle
    }

    private struct DNRActionRequest: Decodable {
        private enum CodingKeys: String, CodingKey, CaseIterable { case type }
        let type: String

        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowing: Set(CodingKeys.allCases.map(\.rawValue)))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
        }
    }

    private struct DNRConditionRequest: Decodable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
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
            case tabIds
            case excludedTabIds
            case requestMethods
            case responseHeaders
            case excludedResponseHeaders
        }

        let urlFilter: String?
        let regexFilter: String?
        let isUrlFilterCaseSensitive: Bool?
        let requestDomains: [String]?
        let excludedRequestDomains: [String]?
        let initiatorDomains: [String]?
        let excludedInitiatorDomains: [String]?
        let resourceTypes: [String]?
        let excludedResourceTypes: [String]?
        let domainType: String?
        let tabIds: [Int]?
        let excludedTabIds: [Int]?
        let requestMethods: [String]?
        let responseHeaders: [String]?
        let excludedResponseHeaders: [String]?

        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowing: Set(CodingKeys.allCases.map(\.rawValue)))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            urlFilter = try container.decodeIfPresent(String.self, forKey: .urlFilter)
            regexFilter = try container.decodeIfPresent(String.self, forKey: .regexFilter)
            isUrlFilterCaseSensitive = try container.decodeIfPresent(
                Bool.self,
                forKey: .isUrlFilterCaseSensitive
            )
            requestDomains = try container.decodeIfPresent([String].self, forKey: .requestDomains)
            excludedRequestDomains = try container.decodeIfPresent(
                [String].self,
                forKey: .excludedRequestDomains
            )
            initiatorDomains = try container.decodeIfPresent([String].self, forKey: .initiatorDomains)
            excludedInitiatorDomains = try container.decodeIfPresent(
                [String].self,
                forKey: .excludedInitiatorDomains
            )
            resourceTypes = try container.decodeIfPresent([String].self, forKey: .resourceTypes)
            excludedResourceTypes = try container.decodeIfPresent(
                [String].self,
                forKey: .excludedResourceTypes
            )
            domainType = try container.decodeIfPresent(String.self, forKey: .domainType)
            tabIds = try container.decodeIfPresent([Int].self, forKey: .tabIds)
            excludedTabIds = try container.decodeIfPresent([Int].self, forKey: .excludedTabIds)
            requestMethods = try container.decodeIfPresent([String].self, forKey: .requestMethods)
            responseHeaders = try container.decodeIfPresent([String].self, forKey: .responseHeaders)
            excludedResponseHeaders = try container.decodeIfPresent(
                [String].self,
                forKey: .excludedResponseHeaders
            )
        }
    }

    private struct DNRRuleRequest: Decodable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id
            case priority
            case action
            case condition
        }

        let id: Int
        let priority: Int?
        let action: DNRActionRequest
        let condition: DNRConditionRequest

        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowing: Set(CodingKeys.allCases.map(\.rawValue)))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            priority = try container.decodeIfPresent(Int.self, forKey: .priority)
            action = try container.decode(DNRActionRequest.self, forKey: .action)
            condition = try container.decode(DNRConditionRequest.self, forKey: .condition)
        }
    }

    private struct DNRUpdateRequest: Decodable {
        private enum CodingKeys: String, CodingKey, CaseIterable { case addRules, removeRuleIds }
        let addRules: [DNRRuleRequest]?
        let removeRuleIds: [Int]?

        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowing: Set(CodingKeys.allCases.map(\.rawValue)))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            addRules = try container.decodeIfPresent([DNRRuleRequest].self, forKey: .addRules)
            removeRuleIds = try container.decodeIfPresent([Int].self, forKey: .removeRuleIds)
        }
    }

    private struct DNRStaticUpdateRequest: Decodable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case enableRulesetIds
            case disableRulesetIds
        }

        let enableRulesetIds: [String]?
        let disableRulesetIds: [String]?

        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowing: Set(CodingKeys.allCases.map(\.rawValue)))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enableRulesetIds = try container.decodeIfPresent([String].self, forKey: .enableRulesetIds)
            disableRulesetIds = try container.decodeIfPresent([String].self, forKey: .disableRulesetIds)
        }
    }

    private struct DNRRegexRequest: Decodable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case regex
            case isCaseSensitive
            case requireCapturing
        }

        let regex: String
        let isCaseSensitive: Bool?
        let requireCapturing: Bool?

        init(from decoder: Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowing: Set(CodingKeys.allCases.map(\.rawValue)))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            regex = try container.decode(String.self, forKey: .regex)
            isCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isCaseSensitive)
            requireCapturing = try container.decodeIfPresent(Bool.self, forKey: .requireCapturing)
        }
    }

    private struct EmptyResponse: Encodable {}
    private struct ScriptInjectionResultResponse: Encodable {
        let frameId = 0
        let result: FloorpWebExtensionJSONValue?
    }
    private struct BooleanResponse: Encodable { let value: Bool }
    private struct IntegerResponse: Encodable { let value: Int }
    private struct StringResponse: Encodable { let value: String }
    private struct StringsResponse: Encodable { let values: [String] }
    private struct PermissionDetailsResponse: Encodable {
        let permissions: [String]
        let origins: [String]
    }
    private struct DNRRegexResponse: Encodable {
        let isSupported: Bool
        let reason: String?
    }
    private struct DNRActionResponse: Encodable {
        let type: String
    }
    private struct DNRConditionResponse: Encodable {
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
        let tabIds: [Int]
        let excludedTabIds: [Int]
        let requestMethods: [String]
        let responseHeaders: [String]
        let excludedResponseHeaders: [String]

        init(_ condition: FloorpWebExtensionDNRCondition) {
            urlFilter = condition.urlFilter
            regexFilter = condition.regexFilter
            isUrlFilterCaseSensitive = condition.isUrlFilterCaseSensitive
            requestDomains = condition.requestDomains
            excludedRequestDomains = condition.excludedRequestDomains
            initiatorDomains = condition.initiatorDomains
            excludedInitiatorDomains = condition.excludedInitiatorDomains
            resourceTypes = condition.resourceTypes.map(\.rawValue)
            excludedResourceTypes = condition.excludedResourceTypes.map(\.rawValue)
            domainType = condition.domainType?.rawValue
            tabIds = condition.tabIDs
            excludedTabIds = condition.excludedTabIDs
            requestMethods = condition.requestMethods
            responseHeaders = condition.responseHeaders
            excludedResponseHeaders = condition.excludedResponseHeaders
        }
    }
    private struct DNRRuleResponse: Encodable {
        let id: Int
        let priority: Int
        let action: DNRActionResponse
        let condition: DNRConditionResponse

        init(_ rule: FloorpWebExtensionDNRRule) {
            id = rule.id
            priority = rule.priority
            action = .init(type: rule.action.type.rawValue)
            condition = .init(rule.condition)
        }
    }
    private struct RegisteredScriptResponse: Encodable {
        let id: String
        let matches: [String]
        let excludeMatches: [String]
        let js: [String]
        let css: [String]
        let runAt: String
        let allFrames: Bool
        let world: String
        let persistAcrossSessions: Bool

        init(_ script: FloorpWebExtensionRegisteredScript) {
            id = script.id
            matches = script.matches.map(\.original)
            excludeMatches = script.excludeMatches.map(\.original)
            js = script.javaScript.map(\.path)
            css = script.styleSheets.map(\.path)
            runAt = script.runAt.rawValue
            allFrames = script.allFrames
            world = script.world.rawValue.uppercased()
            persistAcrossSessions = script.persistAcrossSessions
        }
    }
    private struct AlarmResponse: Encodable {
        let name: String
        let scheduledTime: Double
        let periodInMinutes: Double?

        init(_ alarm: FloorpWebExtensionAlarm) {
            name = alarm.name
            scheduledTime = alarm.scheduledTime.timeIntervalSince1970 * 1_000
            periodInMinutes = alarm.period.map { $0 / 60 }
        }
    }

    let profileKey: FloorpWebExtensionCoordinatorProfileKey
    let storage: FloorpWebExtensionStorageService
    let alarms: FloorpWebExtensionAlarmStore
    let alarmEvents: FloorpWebExtensionAlarmEventHost
    let actions: FloorpWebExtensionActionStore
    private let tabs: FloorpWebExtensionTabsService?

    private let i18n: FloorpWebExtensionI18n
    private let packageResourceLoader: FloorpWebExtensionI18n.ResourceLoader
    private let permissionBroker: FloorpWebExtensionPermissionBroker
    private let now: @Sendable () -> Date
    private let alarmEventHandler: AlarmEventHandler?
    private let runtimeReloader: RuntimeReloader?
    private let permissionRequestAuthorizer: PermissionRequestAuthorizer?
    private let permissionMutationHandler: PermissionMutationHandler?
    private let liveScriptingTargetResolver: LiveScriptingTargetResolver?
    private var activeExtensions = [FloorpWebExtensionID: ActiveExtension]()
    private enum RegistryBinding {
        case unmanaged
        case installed
        case invalidated
    }
    private var registryBinding: RegistryBinding = .unmanaged
    private var cssInsertions = [FloorpWebExtensionID: [TrackedCSSInsertion]]()

    init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        directory: URL,
        preferredLocales: [String],
        packageResourceLoader: @escaping FloorpWebExtensionI18n.ResourceLoader,
        alarmEvents: FloorpWebExtensionAlarmEventHost,
        permissionBroker: FloorpWebExtensionPermissionBroker,
        tabsHost: (any FloorpWebExtensionTabsHostAdapting)? = nil,
        alarmEventHandler: AlarmEventHandler? = nil,
        runtimeReloader: RuntimeReloader? = nil,
        permissionRequestAuthorizer: PermissionRequestAuthorizer? = nil,
        permissionMutationHandler: PermissionMutationHandler? = nil,
        liveScriptingTargetResolver: LiveScriptingTargetResolver? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        profileKey = .init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        storage = try .init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            directory: isPrivateBrowsing
                ? nil
                : directory.appendingPathComponent("storage", isDirectory: true)
        )
        alarms = try .init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            directory: directory.appendingPathComponent("alarms", isDirectory: true)
        )
        actions = try .init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            directory: directory.appendingPathComponent("actions", isDirectory: true)
        )
        i18n = try .init(
            preferredLocales: preferredLocales,
            resourceLoader: packageResourceLoader
        )
        self.packageResourceLoader = packageResourceLoader
        if let tabsHost {
            tabs = try .init(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: isPrivateBrowsing,
                host: tabsHost,
                permissionBroker: permissionBroker
            )
        } else {
            tabs = nil
        }
        self.alarmEvents = alarmEvents
        self.permissionBroker = permissionBroker
        self.alarmEventHandler = alarmEventHandler
        self.runtimeReloader = runtimeReloader
        self.permissionRequestAuthorizer = permissionRequestAuthorizer
        self.permissionMutationHandler = permissionMutationHandler
        self.liveScriptingTargetResolver = liveScriptingTargetResolver
        self.now = now
    }

    convenience init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        directory: URL,
        preferredLocales: [String],
        packageResourceLoader: @escaping FloorpWebExtensionI18n.ResourceLoader,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try self.init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            directory: directory,
            preferredLocales: preferredLocales,
            packageResourceLoader: packageResourceLoader,
            alarmEvents: FloorpWebExtensionAlarmEventHost(),
            permissionBroker: FloorpWebExtensionPermissionBroker(),
            now: now
        )
    }

    func activate(_ package: FloorpWebExtensionInstalledPackage) async {
        guard package.isEnabled else {
            await deactivate(package.extensionID)
            return
        }
        await activate(
            extensionID: package.extensionID,
            grants: package.grants,
            defaultLocale: Self.defaultLocale(in: package.rawManifest) ?? i18n.uiLanguage,
            declaredPermissions: package.preflight.manifest.apiPermissions,
            declaredHosts: Set(package.preflight.manifest.hostPermissions),
            optionalPermissions: package.preflight.manifest.optionalAPIPermissions,
            optionalHosts: Set(package.preflight.manifest.optionalHostPermissions),
            rawManifest: package.rawManifest,
            packageGeneration: package.generation,
            resourcePaths: package.resourcePaths
        )
    }

    func activate(
        extensionID: FloorpWebExtensionID,
        grants: FloorpWebExtensionPermissionSnapshot,
        defaultLocale: String,
        declaredPermissions: Set<FloorpWebExtensionAPIGrant>? = nil,
        declaredHosts: Set<FloorpWebExtensionMatchPattern>? = nil,
        optionalPermissions: Set<FloorpWebExtensionAPIGrant> = [],
        optionalHosts: Set<FloorpWebExtensionMatchPattern> = [],
        rawManifest: Data? = nil,
        packageGeneration: String? = nil,
        resourcePaths: Set<String> = []
    ) async {
        activeExtensions[extensionID] = .init(
            authorityRevision: UUID(),
            permissions: grants.apiPermissions,
            defaultLocale: defaultLocale,
            declaredPermissions: declaredPermissions ?? grants.apiPermissions,
            declaredHosts: declaredHosts ?? grants.requestedHosts,
            optionalPermissions: optionalPermissions,
            optionalHosts: optionalHosts,
            rawManifest: rawManifest,
            packageGeneration: packageGeneration,
            resourcePaths: resourcePaths
        )
        await permissionBroker.grant(
            grants.apiPermissions,
            requestedHosts: grants.requestedHosts,
            hostAccess: grants.normalHostAccess,
            privateHostAccess: grants.privateHostAccess,
            privateBrowsingEnabled: grants.privateBrowsingEnabled,
            to: extensionID
        )
        if grants.apiPermissions.contains(.alarms), let alarmEventHandler {
            alarmEvents.register(extensionID: extensionID, handler: alarmEventHandler)
        } else {
            // A narrower reactivation must revoke an older event target now.
            alarmEvents.unregister(extensionID: extensionID)
        }
    }

    /// Native bridge sessions capture this immutable value at installation
    /// and compare it again for every internal frame-authorization request.
    /// A package update therefore invalidates an old session even when the
    /// extension identifier and registered script identifier are reused.
    func activePackageGeneration(for extensionID: FloorpWebExtensionID) -> String? {
        activeExtensions[extensionID]?.packageGeneration
    }

    func isActivePackageGeneration(
        _ generation: String,
        for extensionID: FloorpWebExtensionID
    ) -> Bool {
        activeExtensions[extensionID]?.packageGeneration == generation
    }

    /// Revokes one extension's live API authority while retaining its
    /// profile-owned data. Reload, grant replacement, disable, and failed
    /// reactivation all pass through this path and must not masquerade as an
    /// uninstall.
    func suspend(_ extensionID: FloorpWebExtensionID) async {
        activeExtensions.removeValue(forKey: extensionID)
        cssInsertions.removeValue(forKey: extensionID)
        alarmEvents.unregister(extensionID: extensionID)
        await permissionBroker.grant(
            [],
            requestedHosts: [],
            hostAccess: .denied,
            to: extensionID
        )
    }

    /// Compatibility spelling for callers that only intend to revoke live
    /// authority. Durable extension-owned data is removed exclusively by
    /// `purge`, after an uninstall has been selected.
    func deactivate(_ extensionID: FloorpWebExtensionID) async {
        await suspend(extensionID)
    }

    func purge(_ extensionID: FloorpWebExtensionID) async throws {
        await suspend(extensionID)
        try await storage.removeAllData(for: extensionID)
        _ = try await alarms.clearAll(for: extensionID)
        _ = try await actions.clearState(for: extensionID)
    }

    func tearDown() async {
        let identifiers = Array(activeExtensions.keys)
        for extensionID in identifiers {
            await suspend(extensionID)
        }
        alarmEvents.tearDown()
    }

    /// Revokes callable capabilities when profile composition is replaced,
    /// while preserving durable extension data for the replacement host.
    func suspend() async {
        let identifiers = Array(activeExtensions.keys)
        activeExtensions.removeAll()
        cssInsertions.removeAll()
        alarmEvents.tearDown()
        for extensionID in identifiers {
            await permissionBroker.grant(
                [],
                requestedHosts: [],
                hostAccess: .denied,
                to: extensionID
            )
        }
    }

    func dispatch(
        operation: String,
        payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        guard sender.isPrivate == profileKey.isPrivateBrowsing,
              let active = activeExtensions[sender.extensionID],
              senderMatchesActivePackage(sender, active: active) else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }

        switch operation {
        case "runtime.id":
            return try response(StringResponse(value: sender.extensionID.rawValue))
        case "runtime.getManifest":
            guard let rawManifest = active.rawManifest else {
                throw FloorpWebExtensionMessageError.unsupportedOperation
            }
            return try FloorpWebExtensionMessagePayload(jsonData: rawManifest)
        case "runtime.getURL":
            return try runtimeURL(payload, active: active, sender: sender)
        case "runtime.reload":
            guard let runtimeReloader else {
                throw FloorpWebExtensionMessageError.unsupportedOperation
            }
            try await runtimeReloader(sender.extensionID)
            return try response(EmptyResponse())
        case "permissions.getAll":
            return try await permissionDetails(for: sender.extensionID)
        case "permissions.contains":
            return try await containsPermissions(payload, extensionID: sender.extensionID)
        case "permissions.request":
            return try await requestPermissions(payload, active: active, sender: sender)
        case "permissions.remove":
            return try await removePermissions(payload, active: active, sender: sender)
        case "scripting.getRegisteredContentScripts":
            try require(.scripting, in: active)
            return try await getRegisteredScripts(payload, active: active, sender: sender)
        case "scripting.registerContentScripts":
            try require(.scripting, in: active)
            return try await registerScripts(payload, active: active, sender: sender)
        case "scripting.updateContentScripts":
            try require(.scripting, in: active)
            return try await updateScripts(payload, active: active, sender: sender)
        case "scripting.unregisterContentScripts":
            try require(.scripting, in: active)
            return try await unregisterScripts(payload, active: active, sender: sender)
        case "scripting.insertCSS":
            try require(.scripting, in: active)
            return try await insertCSS(payload, extensionID: sender.extensionID)
        case "scripting.removeCSS":
            try require(.scripting, in: active)
            return try await removeCSS(payload, extensionID: sender.extensionID)
        case "scripting.executeScript":
            try require(.scripting, in: active)
            return try await executeScript(payload, extensionID: sender.extensionID)
        case "declarativeNetRequest.getEnabledRulesets":
            try require(.declarativeNetRequest, in: active)
            return try await getEnabledStaticRuleSets(extensionID: sender.extensionID)
        case "declarativeNetRequest.updateEnabledRulesets":
            try require(.declarativeNetRequest, in: active)
            return try await updateEnabledStaticRuleSets(payload, extensionID: sender.extensionID)
        case "declarativeNetRequest.getDynamicRules":
            try require(.declarativeNetRequest, in: active)
            return try await getDNRRules(scope: .dynamic, extensionID: sender.extensionID)
        case "declarativeNetRequest.updateDynamicRules":
            try require(.declarativeNetRequest, in: active)
            return try await updateDNRRules(payload, scope: .dynamic, extensionID: sender.extensionID)
        case "declarativeNetRequest.getSessionRules":
            try require(.declarativeNetRequest, in: active)
            return try await getDNRRules(scope: .session, extensionID: sender.extensionID)
        case "declarativeNetRequest.updateSessionRules":
            try require(.declarativeNetRequest, in: active)
            return try await updateDNRRules(payload, scope: .session, extensionID: sender.extensionID)
        case "declarativeNetRequest.isRegexSupported":
            try require(.declarativeNetRequest, in: active)
            return try await regexSupport(payload, extensionID: sender.extensionID)
        case "declarativeNetRequest.getLimits":
            try require(.declarativeNetRequest, in: active)
            return try dnrLimits(extensionID: sender.extensionID)
        case "storage.local.get":
            try require(.storage, in: active)
            return try await storageGet(payload, area: .local, sender: sender)
        case "storage.local.set":
            try require(.storage, in: active)
            return try await storageSet(payload, area: .local, sender: sender)
        case "storage.local.remove":
            try require(.storage, in: active)
            return try await storageRemove(payload, area: .local, sender: sender)
        case "storage.local.clear":
            try require(.storage, in: active)
            try await storage.clear(for: sender.extensionID, in: .local)
            return try response(EmptyResponse())
        case "storage.local.getBytesInUse":
            try require(.storage, in: active)
            return try await storageBytesInUse(payload, area: .local, sender: sender)
        case "storage.session.get":
            try require(.storage, in: active)
            return try await storageGet(payload, area: .session, sender: sender)
        case "storage.session.set":
            try require(.storage, in: active)
            return try await storageSet(payload, area: .session, sender: sender)
        case "storage.session.remove":
            try require(.storage, in: active)
            return try await storageRemove(payload, area: .session, sender: sender)
        case "storage.session.clear":
            try require(.storage, in: active)
            try await storage.clear(for: sender.extensionID, in: .session)
            return try response(EmptyResponse())
        case "storage.session.getBytesInUse":
            try require(.storage, in: active)
            return try await storageBytesInUse(payload, area: .session, sender: sender)
        case "i18n.getMessage":
            let request = try decode(I18nMessageRequest.self, from: payload)
            let value = try i18n.message(
                request.name,
                substitutions: request.substitutions,
                extensionID: sender.extensionID,
                defaultLocale: active.defaultLocale
            )
            return try response(StringResponse(value: value))
        case "i18n.getUILanguage":
            return try response(StringResponse(value: i18n.uiLanguage))
        case "i18n.getAcceptLanguages":
            return try response(StringsResponse(values: i18n.acceptLanguages))
        case "alarms.create":
            try require(.alarms, in: active)
            return try await createAlarm(payload, sender: sender)
        case "alarms.get":
            try require(.alarms, in: active)
            let request = try decode(AlarmNameRequest.self, from: payload)
            let alarm = await alarms.alarm(named: request.name, for: sender.extensionID)
            return try alarm.map { try response(AlarmResponse($0)) }
        case "alarms.getAll":
            try require(.alarms, in: active)
            return try response(await alarms.alarms(for: sender.extensionID).map(AlarmResponse.init))
        case "alarms.clear":
            try require(.alarms, in: active)
            let request = try decode(AlarmNameRequest.self, from: payload)
            return try response(BooleanResponse(
                value: try await alarms.clear(named: request.name, for: sender.extensionID)
            ))
        case "alarms.clearAll":
            try require(.alarms, in: active)
            return try response(BooleanResponse(
                value: try await alarms.clearAll(for: sender.extensionID)
            ))
        case "action.getTitle":
            let state = await actions.state(for: sender.extensionID)
            return try response(StringResponse(value: state.title ?? ""))
        case "action.setTitle":
            return try await updateAction(payload, sender: sender) { state, request in
                state.title = request.value
            }
        case "action.getBadgeText":
            let state = await actions.state(for: sender.extensionID)
            return try response(StringResponse(value: state.badgeText ?? ""))
        case "action.setBadgeText":
            return try await updateAction(payload, sender: sender) { state, request in
                state.badgeText = request.value
            }
        case "action.getBadgeBackgroundColor":
            let state = await actions.state(for: sender.extensionID)
            return try response(StringResponse(value: state.badgeBackgroundColor ?? ""))
        case "action.setBadgeBackgroundColor":
            return try await updateAction(payload, sender: sender) { state, request in
                state.badgeBackgroundColor = request.value
            }
        case "action.enable":
            return try await setActionEnabled(true, sender: sender)
        case "action.disable":
            return try await setActionEnabled(false, sender: sender)
        case "tabs.query":
            try require(.tabs, in: active)
            return try await queryTabs(payload, sender: sender)
        case "tabs.get":
            try require(.tabs, in: active)
            return try await getTab(payload, sender: sender)
        case "tabs.create":
            try require(.tabs, in: active)
            return try await createTab(payload, sender: sender)
        case "tabs.update":
            try require(.tabs, in: active)
            return try await updateTab(payload, sender: sender)
        case "tabs.reload":
            try require(.tabs, in: active)
            return try await reloadTab(payload, sender: sender)
        case "tabs.sendMessage":
            try require(.tabs, in: active)
            return try await sendTabMessage(payload, sender: sender)
        default:
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
    }

    private func senderMatchesActivePackage(
        _ sender: any FloorpWebExtensionMessageSender,
        active: ActiveExtension
    ) -> Bool {
        if let page = sender as? FloorpWebExtensionPageRuntimeMessageSender {
            return page.profileKey == profileKey && page.packageGeneration == active.packageGeneration
        }
        if let background = sender as? FloorpWebExtensionBackgroundRuntimeMessageSender {
            return background.profileKey == profileKey &&
                background.packageGeneration == active.packageGeneration
        }
        return true
    }

    /// Re-authenticates a sender after any consent, actor, or lifecycle await.
    /// Package pages and backgrounds carry their immutable generation. A tab
    /// content script is instead rebound to the current tab generation and
    /// the coordinator's exact frame URL/host/script authorization.
    private func requireCurrentSender(
        _ sender: any FloorpWebExtensionMessageSender,
        expectedActive: ActiveExtension
    ) throws {
        guard let currentActive = activeExtensions[sender.extensionID],
              currentActive.authorityRevision == expectedActive.authorityRevision,
              currentActive.packageGeneration == expectedActive.packageGeneration,
              senderMatchesActivePackage(sender, active: currentActive) else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }

        guard let tabSender = sender as? FloorpWebExtensionRuntimeMessageSender,
              let liveScriptingTargetResolver else {
            return
        }
        guard let target = try? liveScriptingTargetResolver(tabSender.tabID),
              target.tab.tabID == tabSender.tabID,
              target.tab.documentGeneration == tabSender.documentGeneration,
              target.tab.isPrivate == tabSender.isPrivate,
              let coordinator = FloorpWebExtensionCoordinator.installedCoordinator(
                  for: profileKey.profileIdentifier,
                  isPrivateBrowsing: profileKey.isPrivateBrowsing
              ),
              coordinator.authorizesBridge(
                  for: sender.extensionID,
                  currentURL: tabSender.url,
                  isMainFrame: tabSender.isMainFrame,
                  tab: target.tab
              ) else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
    }

    fileprivate func markInstalledInRegistry() {
        registryBinding = .installed
    }

    fileprivate func invalidateRegistryBinding() {
        registryBinding = .invalidated
        activeExtensions.removeAll()
    }

    private var hasCurrentRegistryBinding: Bool {
        switch registryBinding {
        case .unmanaged:
            // Unit-composed hosts are deliberately usable without installing
            // global production state.
            return true
        case .installed:
            return FloorpWebExtensionAPIHostRegistry.host(
                for: profileKey.profileIdentifier,
                isPrivateBrowsing: profileKey.isPrivateBrowsing
            ) === self
        case .invalidated:
            return false
        }
    }

    private func runtimeURL(
        _ payload: FloorpWebExtensionMessagePayload,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(RuntimeGetURLRequest.self, from: payload)
        let originHost: String
        let senderGeneration: String
        if let page = sender as? FloorpWebExtensionPageRuntimeMessageSender {
            originHost = page.originHost
            senderGeneration = page.packageGeneration
        } else if let background = sender as? FloorpWebExtensionBackgroundRuntimeMessageSender {
            originHost = background.originHost
            senderGeneration = background.packageGeneration
        } else {
            // Ordinary web tabs do not own a package-scheme handler. Returning
            // a made-up origin would produce a URL that cannot be loaded.
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        guard let packageGeneration = active.packageGeneration,
              packageGeneration == senderGeneration else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }

        let normalizedPath: String
        if request.path.isEmpty {
            normalizedPath = ""
        } else {
            guard let source = try? FloorpWebExtensionScriptSource(request.path),
                  active.resourcePaths.contains(source.path) else {
                throw FloorpWebExtensionMessageError.malformedEnvelope
            }
            normalizedPath = source.path
        }
        var components = URLComponents()
        components.scheme = FloorpWebExtensionPageNavigationPolicy.resourceScheme
        components.host = originHost
        components.path = "/" + normalizedPath
        guard let url = components.url else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        return try response(StringResponse(value: url.absoluteString))
    }

    private func permissionDetails(
        for extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let snapshot = await permissionBroker.snapshot(for: extensionID)
        return try response(PermissionDetailsResponse(
            permissions: snapshot.apiPermissions.map(\.rawValue).sorted(),
            origins: grantedOrigins(in: snapshot).map(\.original).sorted()
        ))
    }

    private func containsPermissions(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let details = try decode(PermissionDetailsRequest.self, from: payload)
        let requested = try parsePermissionDetails(details)
        let snapshot = await permissionBroker.snapshot(for: extensionID)
        let contains = requested.apiPermissions.isSubset(of: snapshot.apiPermissions) &&
            origins(requested.origins, areCoveredBy: grantedOrigins(in: snapshot))
        return try response(BooleanResponse(value: contains))
    }

    private func requestPermissions(
        _ payload: FloorpWebExtensionMessagePayload,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let details = try decode(PermissionDetailsRequest.self, from: payload)
        let requested = try parsePermissionDetails(details)
        guard requested.apiPermissions.isSubset(of: active.optionalPermissions),
              origins(requested.origins, areCoveredBy: active.optionalHosts),
              let permissionRequestAuthorizer else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        let mutationAuthority = try await permissionMutationAuthority(
            active: active,
            sender: sender
        )
        try requireCurrentSender(sender, expectedActive: active)
        let consent = FloorpWebExtensionPermissionRequest(
            extensionID: sender.extensionID,
            packageGeneration: active.packageGeneration,
            apiPermissions: requested.apiPermissions,
            origins: requested.origins
        )
        guard await permissionRequestAuthorizer(consent) else {
            return try response(BooleanResponse(value: false))
        }

        // Consent is an asynchronous profile/UI boundary. The package may be
        // disabled, uninstalled, or replaced while the prompt is visible, so
        // the sender and immutable package generation authenticated at ingress
        // cannot be trusted after the await. Never apply an old package's
        // approval to a newly installed generation that happens to reuse the
        // same extension identifier.
        try requireCurrentSender(sender, expectedActive: active)

        let current = await permissionBroker.snapshot(for: sender.extensionID)
        try requireCurrentSender(sender, expectedActive: active)
        let updated = replacingGrantedOrigins(
            grantedOrigins(in: current).union(requested.origins),
            apiPermissions: current.apiPermissions.union(requested.apiPermissions),
            in: current
        )
        try await persistPermissions(
            updated,
            authority: mutationAuthority,
            expectedActive: active,
            sender: sender
        )
        return try response(BooleanResponse(value: true))
    }

    private func removePermissions(
        _ payload: FloorpWebExtensionMessagePayload,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let details = try decode(PermissionDetailsRequest.self, from: payload)
        let requested = try parsePermissionDetails(details)
        guard requested.apiPermissions.isSubset(of: active.optionalPermissions),
              origins(requested.origins, areCoveredBy: active.optionalHosts) else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        let mutationAuthority = try await permissionMutationAuthority(
            active: active,
            sender: sender
        )
        try requireCurrentSender(sender, expectedActive: active)
        let current = await permissionBroker.snapshot(for: sender.extensionID)
        try requireCurrentSender(sender, expectedActive: active)
        guard requested.apiPermissions.isSubset(of: current.apiPermissions),
              requested.origins.isSubset(of: grantedOrigins(in: current)) else {
            return try response(BooleanResponse(value: false))
        }
        let updated = replacingGrantedOrigins(
            grantedOrigins(in: current).subtracting(requested.origins),
            apiPermissions: current.apiPermissions.subtracting(requested.apiPermissions),
            in: current
        )
        try await persistPermissions(
            updated,
            authority: mutationAuthority,
            expectedActive: active,
            sender: sender
        )
        return try response(BooleanResponse(value: true))
    }

    private func parsePermissionDetails(
        _ details: PermissionDetailsRequest
    ) throws -> (
        apiPermissions: Set<FloorpWebExtensionAPIGrant>,
        origins: Set<FloorpWebExtensionMatchPattern>
    ) {
        var permissions = Set<FloorpWebExtensionAPIGrant>()
        for name in details.permissions ?? [] {
            guard let permission = FloorpWebExtensionAPIGrant(rawValue: name),
                  permissions.insert(permission).inserted else {
                throw FloorpWebExtensionMessageError.malformedEnvelope
            }
        }
        var origins = Set<FloorpWebExtensionMatchPattern>()
        for value in details.origins ?? [] {
            guard let pattern = try? FloorpWebExtensionMatchPattern(value),
                  origins.insert(pattern).inserted else {
                throw FloorpWebExtensionMessageError.malformedEnvelope
            }
        }
        return (permissions, origins)
    }

    private func origins(
        _ requested: Set<FloorpWebExtensionMatchPattern>,
        areCoveredBy available: Set<FloorpWebExtensionMatchPattern>
    ) -> Bool {
        requested.allSatisfy { requestedOrigin in
            available.contains { $0.covers(requestedOrigin) }
        }
    }

    private func grantedOrigins(
        in snapshot: FloorpWebExtensionPermissionSnapshot
    ) -> Set<FloorpWebExtensionMatchPattern> {
        let access = profileKey.isPrivateBrowsing
            ? snapshot.privateHostAccess
            : snapshot.normalHostAccess
        switch access {
        case .denied:
            return []
        case .selectedSites(let patterns):
            return patterns
        case .allRequestedSites:
            return snapshot.requestedHosts
        }
    }

    private func replacingGrantedOrigins(
        _ origins: Set<FloorpWebExtensionMatchPattern>,
        apiPermissions: Set<FloorpWebExtensionAPIGrant>,
        in snapshot: FloorpWebExtensionPermissionSnapshot
    ) -> FloorpWebExtensionPermissionSnapshot {
        let access: FloorpWebExtensionHostAccess = origins.isEmpty ? .denied : .selectedSites(origins)
        return .init(
            apiPermissions: apiPermissions,
            requestedHosts: snapshot.requestedHosts,
            normalHostAccess: profileKey.isPrivateBrowsing ? snapshot.normalHostAccess : access,
            privateHostAccess: profileKey.isPrivateBrowsing ? access : snapshot.privateHostAccess,
            privateBrowsingEnabled: snapshot.privateBrowsingEnabled
        )
    }

    private func permissionMutationAuthority(
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> PermissionMutationAuthority {
        if permissionMutationHandler != nil {
            return .injected(packageGeneration: active.packageGeneration)
        }
        guard let packageGeneration = active.packageGeneration,
              let manager = FloorpWebExtensionPackageStoreRegistry.manager(
                  for: profileKey.profileIdentifier,
                  isPrivateBrowsing: profileKey.isPrivateBrowsing
              ) else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        do {
            let authorization = try await manager.authorizePermissionMutation(
                for: sender.extensionID,
                expectedGeneration: packageGeneration
            )
            return .liveManager(manager, authorization)
        } catch FloorpWebExtensionPackageStoreError.inactivePackageGeneration,
                FloorpWebExtensionPackageStoreError.packageNotInstalled {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
    }

    private func persistPermissions(
        _ snapshot: FloorpWebExtensionPermissionSnapshot,
        authority: PermissionMutationAuthority,
        expectedActive: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws {
        switch authority {
        case .liveManager(let manager, let authorization):
            do {
                try await manager.updateGrants(snapshot, authorization: authorization) {
                    do {
                        try self.requireCurrentSender(sender, expectedActive: expectedActive)
                        return true
                    } catch {
                        return false
                    }
                }
            } catch FloorpWebExtensionPackageStoreError.inactivePackageGeneration,
                    FloorpWebExtensionPackageStoreError.packageNotInstalled {
                throw FloorpWebExtensionMessageError.unauthorizedDocument
            }
            // The production manager reconciles and reactivates this host
            // inside its lifecycle transaction. A second grant here could run
            // after a disable and resurrect stale broker authority.
            return

        case .injected(let packageGeneration):
            guard let permissionMutationHandler else {
                throw FloorpWebExtensionMessageError.permissionDenied
            }
            try await permissionMutationHandler(
                snapshot,
                sender.extensionID,
                packageGeneration
            )
            try requireCurrentSender(sender, expectedActive: expectedActive)
        }

        // Injected transactional test/backends do not own host activation, so
        // refresh the broker only after their durable mutation and a second
        // package/sender identity check.
        await permissionBroker.grant(
            snapshot.apiPermissions,
            requestedHosts: snapshot.requestedHosts,
            hostAccess: snapshot.normalHostAccess,
            privateHostAccess: snapshot.privateHostAccess,
            privateBrowsingEnabled: snapshot.privateBrowsingEnabled,
            to: sender.extensionID
        )
        try requireCurrentSender(sender, expectedActive: expectedActive)
        activeExtensions[sender.extensionID]?.permissions = snapshot.apiPermissions
    }

    private func getRegisteredScripts(
        _ payload: FloorpWebExtensionMessagePayload,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let coordinator = try authorizedScriptingCoordinator(active: active, sender: sender)
        let request = try decode(RegisteredScriptFilterRequest.self, from: payload)
        let ids = request.filter?.ids.map(Set.init)
        let scripts = await coordinator.registeredScripts(for: sender.extensionID)
            .filter { ids?.contains($0.id) ?? true }
            .map(RegisteredScriptResponse.init)
        try validateScriptingAuthority(coordinator, active: active, sender: sender)
        return try response(scripts)
    }

    private func registerScripts(
        _ payload: FloorpWebExtensionMessagePayload,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let coordinator = try authorizedScriptingCoordinator(active: active, sender: sender)
        let request = try decode(RegisterScriptsRequest.self, from: payload)
        let scripts = try request.scripts.map(makeRegisteredScript)
        do {
            try await coordinator.registerScripts(
                scripts,
                for: sender.extensionID,
                expectedPackageGeneration: active.packageGeneration
            ) {
                try self.validateScriptingAuthority(coordinator, active: active, sender: sender)
            }
        } catch FloorpWebExtensionPackageStoreError.inactivePackageGeneration,
                FloorpWebExtensionPackageStoreError.packageNotInstalled,
                FloorpWebExtensionPackageStoreError.stalePackageComposition {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        return try response(EmptyResponse())
    }

    private func updateScripts(
        _ payload: FloorpWebExtensionMessagePayload,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let coordinator = try authorizedScriptingCoordinator(active: active, sender: sender)
        let request = try decode(RegisterScriptsRequest.self, from: payload)
        let updates = try request.scripts.map(makeRegisteredScriptUpdate)
        do {
            try await coordinator.updateScripts(
                updates,
                for: sender.extensionID,
                expectedPackageGeneration: active.packageGeneration
            ) {
                try self.validateScriptingAuthority(coordinator, active: active, sender: sender)
            }
        } catch FloorpWebExtensionPackageStoreError.inactivePackageGeneration,
                FloorpWebExtensionPackageStoreError.packageNotInstalled,
                FloorpWebExtensionPackageStoreError.stalePackageComposition {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        return try response(EmptyResponse())
    }

    private func unregisterScripts(
        _ payload: FloorpWebExtensionMessagePayload,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let coordinator = try authorizedScriptingCoordinator(active: active, sender: sender)
        let request = try decode(UnregisterScriptsRequest.self, from: payload)
        do {
            try await coordinator.unregisterScripts(
                request.ids ?? [],
                for: sender.extensionID,
                expectedPackageGeneration: active.packageGeneration
            ) {
                try self.validateScriptingAuthority(coordinator, active: active, sender: sender)
            }
        } catch FloorpWebExtensionPackageStoreError.inactivePackageGeneration,
                FloorpWebExtensionPackageStoreError.packageNotInstalled,
                FloorpWebExtensionPackageStoreError.stalePackageComposition {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        return try response(EmptyResponse())
    }

    private func authorizedScriptingCoordinator(
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) throws -> FloorpWebExtensionCoordinator {
        let coordinator = try tryCoordinator()
        try validateScriptingAuthority(coordinator, active: active, sender: sender)
        return coordinator
    }

    private func validateScriptingAuthority(
        _ coordinator: FloorpWebExtensionCoordinator,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) throws {
        try requireCurrentSender(sender, expectedActive: active)
        guard hasCurrentRegistryBinding,
              FloorpWebExtensionCoordinator.isInstalled(coordinator) else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
    }

    private func makeRegisteredScript(
        _ details: RegisteredScriptDetails
    ) throws -> FloorpWebExtensionRegisteredScript {
        guard let matches = details.matches,
              !matches.isEmpty else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        return FloorpWebExtensionRegisteredScript(
            id: details.id,
            matches: try makeMatchPatterns(matches),
            excludeMatches: try makeMatchPatterns(details.excludeMatches ?? []),
            javaScript: try makeSources(details.js ?? []),
            styleSheets: try makeSources(details.css ?? []),
            runAt: try makeRunAt(details.runAt),
            allFrames: details.allFrames ?? false,
            world: try makeWorld(details.world),
            // Chrome and Firefox default this option to persistent.  Before
            // durable registration existed, Floorp rejected omission to avoid
            // silently weakening that contract; now omission is faithful and
            // still fails closed if no package store can commit it.
            persistAcrossSessions: details.persistAcrossSessions ?? true
        )
    }

    private func makeRegisteredScriptUpdate(
        _ details: RegisteredScriptDetails
    ) throws -> FloorpWebExtensionRegisteredScriptUpdate {
        return .init(
            id: details.id,
            matches: try details.matches.map(makeMatchPatterns),
            excludeMatches: try details.excludeMatches.map(makeMatchPatterns),
            javaScript: try details.js.map(makeSources),
            styleSheets: try details.css.map(makeSources),
            runAt: try details.runAt.map(makeRunAt),
            allFrames: details.allFrames,
            world: try details.world.map(makeWorld),
            persistAcrossSessions: details.persistAcrossSessions
        )
    }

    private func makeMatchPatterns(
        _ values: [String]
    ) throws -> [FloorpWebExtensionMatchPattern] {
        do {
            return try values.map(FloorpWebExtensionMatchPattern.init)
        } catch {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
    }

    private func makeSources(
        _ values: [String]
    ) throws -> [FloorpWebExtensionScriptSource] {
        do {
            return try values.map(FloorpWebExtensionScriptSource.init)
        } catch {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
    }

    private func makeRunAt(_ value: String?) throws -> FloorpWebExtensionRunAt {
        guard let value else { return .documentIdle }
        guard let runAt = FloorpWebExtensionRunAt(rawValue: value) else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        return runAt
    }

    private func makeWorld(_ value: String?) throws -> FloorpWebExtensionExecutionWorld {
        guard let value else { return .isolated }
        guard let world = FloorpWebExtensionExecutionWorld(rawValue: value.lowercased()) else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        return world
    }

    private func executeScript(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        guard let rawRequest = try? JSONSerialization.jsonObject(with: payload.jsonData) as? [String: Any]
        else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        // Functions disappear during ordinary JSON serialization, while some
        // adapters encode their source. In either representation, absence of
        // a package-file list is an explicit code-execution request rather
        // than a malformed file request.
        guard rawRequest["func"] == nil,
              rawRequest["code"] == nil,
              rawRequest["files"] != nil else {
            throw FloorpWebExtensionMessageError.unsupportedCodeExecution
        }

        let request = try decode(ExecuteScriptRequest.self, from: payload)
        guard request.functionSource == nil,
              request.args == nil,
              let files = request.files,
              !files.isEmpty else {
            throw FloorpWebExtensionMessageError.unsupportedCodeExecution
        }
        let target = try liveScriptingTarget(for: request.target)
        let coordinator = try tryCoordinator()
        guard coordinator.authorizesDynamicScripting(for: extensionID, tab: target.tab),
              let active = activeExtensions[extensionID] else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        let sources = try files.map { path -> String in
            guard let source = try? FloorpWebExtensionScriptSource(path),
                  active.resourcePaths.contains(source.path),
                  let loaded = try packageResourceLoader(extensionID, source) else {
                throw FloorpWebExtensionMessageError.malformedEnvelope
            }
            return loaded
        }
        let world = try makeWorld(request.world)
        let contentWorld: WKContentWorld = switch world {
        case .isolated:
            .world(name: FloorpWebExtensionMessageRuntime.isolatedContentWorldName(for: extensionID))
        case .main:
            .page
        }
        let rawResult: Any?
        do {
            rawResult = try await target.webView.callAsyncJavaScript(
                sources.joined(separator: "\n;\n"),
                contentWorld: contentWorld
            )
        } catch {
            throw FloorpWebExtensionMessageError.handlerFailed
        }
        let currentTarget = try liveScriptingTarget(for: request.target)
        guard currentTarget.tab == target.tab,
              currentTarget.webView === target.webView else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        let result: FloorpWebExtensionJSONValue?
        if let rawResult {
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: rawResult,
                    options: .fragmentsAllowed
                )
                result = try JSONDecoder().decode(FloorpWebExtensionJSONValue.self, from: data)
            } catch {
                throw FloorpWebExtensionMessageError.handlerFailed
            }
        } else {
            result = nil
        }
        return try response([ScriptInjectionResultResponse(result: result)])
    }

    private func insertCSS(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(InsertCSSRequest.self, from: payload)
        let target = try liveScriptingTarget(for: request)
        let (source, css) = try cssInjectionSource(
            for: request,
            extensionID: extensionID,
            loadContent: true
        )
        guard let css else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        let insertion = try await tryCoordinator().insertCSS(
            css,
            for: extensionID,
            target: .init(tab: target.tab),
            tab: target.tab,
            into: target.webView,
            validateLiveTarget: {
                try self.validateLiveScriptingTarget(target, for: request.target)
            }
        )
        let identity = CSSInjectionIdentity(
            tabID: target.tab.tabID,
            documentGeneration: target.tab.documentGeneration,
            frameIDs: request.target.frameIds,
            origin: request.origin ?? "AUTHOR",
            source: source
        )
        cssInsertions[extensionID, default: []].append(.init(
            identity: identity,
            handle: insertion.handle
        ))
        return try response(EmptyResponse())
    }

    private func removeCSS(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(InsertCSSRequest.self, from: payload)
        let target = try liveScriptingTarget(for: request)
        let (source, _) = try cssInjectionSource(
            for: request,
            extensionID: extensionID,
            loadContent: false
        )
        let identity = CSSInjectionIdentity(
            tabID: target.tab.tabID,
            documentGeneration: target.tab.documentGeneration,
            frameIDs: request.target.frameIds,
            origin: request.origin ?? "AUTHOR",
            source: source
        )
        let tracked = cssInsertions[extensionID] ?? []
        let handles = tracked.filter { $0.identity == identity }.map(\.handle)
        if !handles.isEmpty {
            try await tryCoordinator().removeCSS(
                handles,
                for: extensionID,
                target: .init(tab: target.tab),
                tab: target.tab,
                from: target.webView,
                validateLiveTarget: {
                    try self.validateLiveScriptingTarget(target, for: request.target)
                }
            )
            cssInsertions[extensionID] = tracked.filter { $0.identity != identity }
        }
        return try response(EmptyResponse())
    }

    private func liveScriptingTarget(
        for request: InsertCSSRequest
    ) throws -> FloorpWebExtensionLiveScriptingTarget {
        guard request.origin == nil || request.origin == "AUTHOR",
              (request.css == nil) != ((request.files ?? []).isEmpty) else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        return try liveScriptingTarget(for: request.target)
    }

    private func liveScriptingTarget(
        for request: ScriptingTargetRequest
    ) throws -> FloorpWebExtensionLiveScriptingTarget {
        guard request.documentIds?.isEmpty != false,
              request.frameIds == nil || request.frameIds == [0],
              request.allFrames != true,
              let liveScriptingTargetResolver else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        let target = try liveScriptingTargetResolver(request.tabId)
        guard target.tab.tabID == request.tabId,
              target.tab.isPrivate == profileKey.isPrivateBrowsing,
              target.webView.url == target.tab.url,
              !target.webView.isLoading else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        return target
    }

    /// Re-resolves the browser-owned document immediately before a dynamic
    /// stylesheet mutates the DOM. Any resolver failure at this second
    /// boundary is an authorization failure: the request was valid for an
    /// earlier document, not authority to fall through to the replacement.
    private func validateLiveScriptingTarget(
        _ expected: FloorpWebExtensionLiveScriptingTarget,
        for request: ScriptingTargetRequest
    ) throws {
        let current: FloorpWebExtensionLiveScriptingTarget
        do {
            current = try liveScriptingTarget(for: request)
        } catch {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        guard current.tab == expected.tab,
              current.webView === expected.webView else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
    }

    private func cssInjectionSource(
        for request: InsertCSSRequest,
        extensionID: FloorpWebExtensionID,
        loadContent: Bool
    ) throws -> (CSSInjectionSource, String?) {
        if let inlineCSS = request.css {
            return (.inline(inlineCSS), loadContent ? inlineCSS : nil)
        }
        guard let active = activeExtensions[extensionID] else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        let sources = try (request.files ?? []).map { path -> FloorpWebExtensionScriptSource in
            guard let source = try? FloorpWebExtensionScriptSource(path),
                  active.resourcePaths.contains(source.path) else {
                throw FloorpWebExtensionMessageError.malformedEnvelope
            }
            return source
        }
        let css: String?
        if loadContent {
            css = try sources.map { source in
                guard let loaded = try packageResourceLoader(extensionID, source) else {
                    throw FloorpWebExtensionMessageError.malformedEnvelope
                }
                return loaded
            }.joined(separator: "\n")
        } else {
            css = nil
        }
        return (.files(sources.map(\.path)), css)
    }

    private func getEnabledStaticRuleSets(
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let snapshot = try await requireDNRSnapshot(extensionID: extensionID)
        return try response(StringsResponse(values: snapshot.enabledStaticRuleSetIDs.sorted()))
    }

    private func updateEnabledStaticRuleSets(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(DNRStaticUpdateRequest.self, from: payload)
        let applied = try await tryCoordinator().updateEnabledStaticRuleSets(
            enable: request.enableRulesetIds ?? [],
            disable: request.disableRulesetIds ?? [],
            for: extensionID
        )
        guard applied else { throw FloorpWebExtensionMessageError.handlerFailed }
        return try response(EmptyResponse())
    }

    private func getDNRRules(
        scope: FloorpWebExtensionDNRRuleScope,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let snapshot = try await requireDNRSnapshot(extensionID: extensionID)
        switch scope {
        case .dynamic:
            return try response(snapshot.dynamicRules.map(DNRRuleResponse.init))
        case .session:
            return try response(snapshot.sessionRules.map(DNRRuleResponse.init))
        case .staticRules:
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
    }

    private func updateDNRRules(
        _ payload: FloorpWebExtensionMessagePayload,
        scope: FloorpWebExtensionDNRRuleScope,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(DNRUpdateRequest.self, from: payload)
        let addRules = try makeDNRRules(request.addRules ?? [])
        let applied: Bool
        switch scope {
        case .dynamic:
            applied = try await tryCoordinator().updateDynamicRules(
                addRules: addRules,
                removeRuleIDs: request.removeRuleIds ?? [],
                for: extensionID
            )
        case .session:
            applied = try await tryCoordinator().updateSessionRules(
                addRules: addRules,
                removeRuleIDs: request.removeRuleIds ?? [],
                for: extensionID
            )
        case .staticRules:
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        guard applied else { throw FloorpWebExtensionMessageError.handlerFailed }
        return try response(EmptyResponse())
    }

    private func makeDNRRules(
        _ requests: [DNRRuleRequest]
    ) throws -> [FloorpWebExtensionDNRRule] {
        try requests.map { request in
            guard let actionType = FloorpWebExtensionDNRActionType(rawValue: request.action.type),
                  let resourceTypes = makeDNRResourceTypes(request.condition.resourceTypes),
                  let excludedResourceTypes = makeDNRResourceTypes(
                    request.condition.excludedResourceTypes
                  ),
                  let domainType = makeDNRDomainType(request.condition.domainType) else {
                throw FloorpWebExtensionMessageError.malformedEnvelope
            }
            return .init(
                id: request.id,
                priority: request.priority ?? 1,
                action: .init(type: actionType),
                condition: .init(
                    urlFilter: request.condition.urlFilter,
                    regexFilter: request.condition.regexFilter,
                    isUrlFilterCaseSensitive: request.condition.isUrlFilterCaseSensitive,
                    requestDomains: request.condition.requestDomains ?? [],
                    excludedRequestDomains: request.condition.excludedRequestDomains ?? [],
                    initiatorDomains: request.condition.initiatorDomains ?? [],
                    excludedInitiatorDomains: request.condition.excludedInitiatorDomains ?? [],
                    resourceTypes: resourceTypes,
                    excludedResourceTypes: excludedResourceTypes,
                    domainType: domainType,
                    tabIDs: request.condition.tabIds ?? [],
                    excludedTabIDs: request.condition.excludedTabIds ?? [],
                    requestMethods: request.condition.requestMethods ?? [],
                    responseHeaders: request.condition.responseHeaders ?? [],
                    excludedResponseHeaders: request.condition.excludedResponseHeaders ?? []
                )
            )
        }
    }

    private func makeDNRResourceTypes(
        _ values: [String]?
    ) -> [FloorpWebExtensionDNRResourceType]? {
        guard let values else { return [] }
        let types = values.compactMap(FloorpWebExtensionDNRResourceType.init(rawValue:))
        return types.count == values.count ? types : nil
    }

    private func makeDNRDomainType(
        _ value: String?
    ) -> FloorpWebExtensionDNRDomainType?? {
        guard let value else { return .some(nil) }
        guard let type = FloorpWebExtensionDNRDomainType(rawValue: value) else { return nil }
        return .some(type)
    }

    private func regexSupport(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(DNRRegexRequest.self, from: payload)
        if request.requireCapturing == true {
            return try response(DNRRegexResponse(
                isSupported: false,
                reason: "Capturing-group substitution is not supported"
            ))
        }
        guard let support = try await tryCoordinator().dnrRegexSupport(
            request.regex,
            for: extensionID
        ) else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        return try response(DNRRegexResponse(
            isSupported: support.isSupported,
            reason: support.reason
        ))
    }

    private func dnrLimits(
        extensionID: FloorpWebExtensionID
    ) throws -> FloorpWebExtensionMessagePayload {
        guard let limits = try tryCoordinator().configuredDNRLimits(for: extensionID) else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        return try response(limits)
    }

    private func requireDNRSnapshot(
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionDNRPolicySnapshot {
        guard let snapshot = try await tryCoordinator().dnrSnapshot(for: extensionID) else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        return snapshot
    }

    private func tryCoordinator() throws -> FloorpWebExtensionCoordinator {
        guard let coordinator = FloorpWebExtensionCoordinator.installedCoordinator(
            for: profileKey.profileIdentifier,
            isPrivateBrowsing: profileKey.isPrivateBrowsing
        ) else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        return coordinator
    }

    private func queryTabs(
        _ payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        _ = try? decode(TabsQueryRequest.self, from: payload)
        guard let tabs else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        return try response(try await tabs.query(.active, for: sender.extensionID))
    }

    private func getTab(
        _ payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(TabsIDRequest.self, from: payload)
        guard let tabs else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        return try response(try await tabs.get(request.tabId, for: sender.extensionID))
    }

    private func createTab(
        _ payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(TabsCreateRequest.self, from: payload)
        guard let tabs else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        guard let urlString = request.createProperties?.url,
              let url = URL(string: urlString) else {
            throw FloorpWebExtensionTabsError.invalidNavigationURL
        }
        return try response(try await tabs.create(
            url: url,
            active: request.createProperties?.active ?? true,
            for: sender.extensionID
        ))
    }

    private func updateTab(
        _ payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(TabsUpdateRequest.self, from: payload)
        guard let tabs else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        guard let urlString = request.updateProperties?.url,
              let url = URL(string: urlString) else {
            throw FloorpWebExtensionTabsError.invalidNavigationURL
        }
        return try response(try await tabs.update(
            request.tabId,
            url: url,
            for: sender.extensionID
        ))
    }

    private func reloadTab(
        _ payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(TabsReloadRequest.self, from: payload)
        guard let tabs else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        _ = request.reloadProperties?.bypassCache
        return try response(try await tabs.reload(request.tabId, for: sender.extensionID))
    }

    private func sendTabMessage(
        _ payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload? {
        let request = try decode(TabsSendMessageRequest.self, from: payload)
        guard let tabs else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        let reply = try await tabs.sendMessage(
            request.message,
            to: request.tabId,
            for: sender.extensionID,
            sender: sender
        )
        return try reply.map { try response($0) }
    }

    private func storageGet(
        _ payload: FloorpWebExtensionMessagePayload,
        area: FloorpWebExtensionStorageArea,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(KeysRequest.self, from: payload)
        return try response(try await storage.values(
            for: sender.extensionID,
            in: area,
            keys: request.keys.map(Set.init)
        ))
    }

    private func storageSet(
        _ payload: FloorpWebExtensionMessagePayload,
        area: FloorpWebExtensionStorageArea,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(StorageSetRequest.self, from: payload)
        try await storage.set(request.items, for: sender.extensionID, in: area)
        return try response(EmptyResponse())
    }

    private func storageRemove(
        _ payload: FloorpWebExtensionMessagePayload,
        area: FloorpWebExtensionStorageArea,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(KeysRequest.self, from: payload)
        try await storage.remove(Set(request.keys ?? []), for: sender.extensionID, in: area)
        return try response(EmptyResponse())
    }

    private func storageBytesInUse(
        _ payload: FloorpWebExtensionMessagePayload,
        area: FloorpWebExtensionStorageArea,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(KeysRequest.self, from: payload)
        return try response(IntegerResponse(value: try await storage.bytesInUse(
            for: sender.extensionID,
            in: area,
            keys: request.keys.map(Set.init)
        )))
    }

    private func createAlarm(
        _ payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(AlarmCreateRequest.self, from: payload)
        let hasWhen = request.when != nil
        let hasDelay = request.delayInMinutes != nil
        guard hasWhen != hasDelay else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        let scheduledTime: Date
        if let milliseconds = request.when, milliseconds.isFinite {
            scheduledTime = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else if let delay = request.delayInMinutes, delay.isFinite, delay >= 0 {
            scheduledTime = now().addingTimeInterval(delay * 60)
        } else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        let period = request.periodInMinutes.map { $0 * 60 }
        try await alarms.create(
            .init(name: request.name, scheduledTime: scheduledTime, period: period),
            for: sender.extensionID,
            permissionBroker: permissionBroker
        )
        return try response(EmptyResponse())
    }

    private func updateAction(
        _ payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender,
        update: (inout FloorpWebExtensionActionState, ActionTextRequest) -> Void
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(ActionTextRequest.self, from: payload)
        var state = await actions.state(for: sender.extensionID)
        update(&state, request)
        try await actions.setState(state, for: sender.extensionID)
        return try response(EmptyResponse())
    }

    private func setActionEnabled(
        _ enabled: Bool,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        var state = await actions.state(for: sender.extensionID)
        state.isEnabled = enabled
        try await actions.setState(state, for: sender.extensionID)
        return try response(EmptyResponse())
    }

    private func require(
        _ permission: FloorpWebExtensionAPIGrant,
        in active: ActiveExtension
    ) throws {
        guard active.permissions.contains(permission) else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from payload: FloorpWebExtensionMessagePayload
    ) throws -> T {
        do {
            return try payload.decode(type)
        } catch {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
    }

    private func response<T: Encodable>(_ value: T) throws -> FloorpWebExtensionMessagePayload {
        do {
            return try FloorpWebExtensionMessagePayload(value)
        } catch let error as FloorpWebExtensionMessageError {
            throw error
        } catch {
            throw FloorpWebExtensionMessageError.handlerFailed
        }
    }

    private static func defaultLocale(in rawManifest: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: rawManifest) as? [String: Any],
              let locale = object["default_locale"] as? String,
              !locale.isEmpty else {
            return nil
        }
        return locale
    }
}

/// Installs the API host and authenticated message runtime for exactly one
/// profile/browsing-mode pair. Coordinator removal calls this registry before
/// package mutation completes, making disable and uninstall fail closed.
@MainActor
enum FloorpWebExtensionAPIHostRegistry {
    private struct Entry {
        let host: FloorpWebExtensionAPIHost
        let messageRuntime: FloorpWebExtensionMessageRuntime
    }

    private static var entries = [FloorpWebExtensionCoordinatorProfileKey: Entry]()

    static func install(
        _ host: FloorpWebExtensionAPIHost,
        messageRuntime: FloorpWebExtensionMessageRuntime
    ) {
        host.markInstalledInRegistry()
        if let previous = entries.updateValue(
            .init(host: host, messageRuntime: messageRuntime),
            forKey: host.profileKey
        ) {
            previous.host.invalidateRegistryBinding()
            previous.messageRuntime.tearDown()
            Task { await previous.host.suspend() }
        }
    }

    static func host(
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) -> FloorpWebExtensionAPIHost? {
        entries[.init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )]?.host
    }

    /// Returns only the message runtime installed for this exact
    /// profile/browsing-mode pair. Page factories must obtain their bridge
    /// runtime through this lookup rather than retaining a runtime from a
    /// different profile.
    static func messageRuntime(
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) -> FloorpWebExtensionMessageRuntime? {
        entries[.init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )]?.messageRuntime
    }

    static func invalidatePageBridges(
        for extensionID: FloorpWebExtensionID,
        profileKey: FloorpWebExtensionCoordinatorProfileKey,
        retainingGeneration: String? = nil
    ) {
        entries[profileKey]?.messageRuntime.invalidatePageBridges(
            for: extensionID,
            retainingGeneration: retainingGeneration
        )
    }

    static func suspend(
        _ extensionID: FloorpWebExtensionID,
        profileKey: FloorpWebExtensionCoordinatorProfileKey
    ) async {
        guard let entry = entries[profileKey] else { return }
        entry.messageRuntime.removeExtension(extensionID)
        await entry.host.suspend(extensionID)
    }

    /// Handles memory pressure for both normal and private runtimes belonging
    /// to one browser profile. API hosts and all durable/profile-owned state
    /// stay installed; only lazy hidden background resources are released.
    static func releaseBackgroundResources(for profileIdentifier: String) {
        let runtimes = entries.compactMap { profileKey, entry in
            profileKey.profileIdentifier == profileIdentifier ? entry.messageRuntime : nil
        }
        runtimes.forEach { $0.releaseBackgroundResources() }
    }

    static func purge(
        _ extensionID: FloorpWebExtensionID,
        profileKey: FloorpWebExtensionCoordinatorProfileKey
    ) async throws {
        guard let entry = entries[profileKey] else {
            throw FloorpWebExtensionError.unsupported("WebExtension API host is unavailable")
        }
        entry.messageRuntime.removeExtension(extensionID)
        try await entry.host.purge(extensionID)
    }

    static func removeHost(for profileKey: FloorpWebExtensionCoordinatorProfileKey) async {
        guard let entry = entries.removeValue(forKey: profileKey) else { return }
        entry.host.invalidateRegistryBinding()
        entry.messageRuntime.tearDown()
        await entry.host.tearDown()
    }
}
