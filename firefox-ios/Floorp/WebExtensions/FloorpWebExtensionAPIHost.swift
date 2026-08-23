// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import WebKit

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
        FloorpWebExtensionID
    ) async throws -> Void
    typealias LiveScriptingTargetResolver = @MainActor @Sendable (
        Int
    ) throws -> FloorpWebExtensionLiveScriptingTarget

    private struct ActiveExtension {
        var permissions: Set<FloorpWebExtensionAPIGrant>
        let defaultLocale: String
        let declaredPermissions: Set<FloorpWebExtensionAPIGrant>
        let declaredHosts: Set<FloorpWebExtensionMatchPattern>
        let rawManifest: Data?
        let packageGeneration: String?
        let resourcePaths: Set<String>
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
        let tabId: Int
        let frameIds: [UInt64]?
        let documentIds: [String]?
    }

    private struct InsertCSSRequest: Decodable {
        let target: ScriptingTargetRequest
        let css: String?
        let files: [String]?
        let origin: String?
    }

    private struct RemoveCSSRequest: Decodable {
        let target: ScriptingTargetRequest
        let handles: [String]
    }

    private struct DNRActionRequest: Decodable {
        let type: String
    }

    private struct DNRConditionRequest: Decodable {
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
    }

    private struct DNRRuleRequest: Decodable {
        let id: Int
        let priority: Int?
        let action: DNRActionRequest
        let condition: DNRConditionRequest
    }

    private struct DNRUpdateRequest: Decodable {
        let addRules: [DNRRuleRequest]?
        let removeRuleIds: [Int]?
    }

    private struct DNRStaticUpdateRequest: Decodable {
        let enableRulesetIds: [String]?
        let disableRulesetIds: [String]?
    }

    private struct DNRRegexRequest: Decodable {
        let regex: String
    }

    private struct EmptyResponse: Encodable {}
    private struct BooleanResponse: Encodable { let value: Bool }
    private struct IntegerResponse: Encodable { let value: Int }
    private struct StringResponse: Encodable { let value: String }
    private struct StringsResponse: Encodable { let values: [String] }
    private struct PermissionDetailsResponse: Encodable {
        let permissions: [String]
        let origins: [String]
    }
    private struct CSSHandlesResponse: Encodable { let handles: [String] }
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
        let persistAcrossSessions = false

        init(_ script: FloorpWebExtensionRegisteredScript) {
            id = script.id
            matches = script.matches.map(\.original)
            excludeMatches = script.excludeMatches.map(\.original)
            js = script.javaScript.map(\.path)
            css = script.styleSheets.map(\.path)
            runAt = script.runAt.rawValue
            allFrames = script.allFrames
            world = script.world.rawValue.uppercased()
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
        rawManifest: Data? = nil,
        packageGeneration: String? = nil,
        resourcePaths: Set<String> = []
    ) async {
        activeExtensions[extensionID] = .init(
            permissions: grants.apiPermissions,
            defaultLocale: defaultLocale,
            declaredPermissions: declaredPermissions ?? grants.apiPermissions,
            declaredHosts: declaredHosts ?? grants.requestedHosts,
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

    /// Disable and uninstall both revoke every callable capability immediately.
    /// Local/session data, alarm definitions, and action presentation state are
    /// also cleared so package removal cannot leave profile-visible residue.
    func deactivate(_ extensionID: FloorpWebExtensionID) async {
        activeExtensions.removeValue(forKey: extensionID)
        alarmEvents.unregister(extensionID: extensionID)
        await permissionBroker.grant(
            [],
            requestedHosts: [],
            hostAccess: .denied,
            to: extensionID
        )
        try? await storage.removeAllData(for: extensionID)
        _ = try? await alarms.clearAll(for: extensionID)
        _ = try? await actions.clearState(for: extensionID)
    }

    func tearDown() async {
        let identifiers = Array(activeExtensions.keys)
        for extensionID in identifiers {
            await deactivate(extensionID)
        }
        alarmEvents.tearDown()
    }

    /// Revokes callable capabilities when profile composition is replaced,
    /// while preserving durable extension data for the replacement host.
    func suspend() async {
        let identifiers = Array(activeExtensions.keys)
        activeExtensions.removeAll()
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
              let active = activeExtensions[sender.extensionID] else {
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
            return try await getRegisteredScripts(payload, extensionID: sender.extensionID)
        case "scripting.registerContentScripts":
            try require(.scripting, in: active)
            return try await registerScripts(payload, extensionID: sender.extensionID)
        case "scripting.updateContentScripts":
            try require(.scripting, in: active)
            return try await updateScripts(payload, extensionID: sender.extensionID)
        case "scripting.unregisterContentScripts":
            try require(.scripting, in: active)
            return try await unregisterScripts(payload, extensionID: sender.extensionID)
        case "scripting.insertCSS":
            try require(.scripting, in: active)
            return try await insertCSS(payload, extensionID: sender.extensionID)
        case "scripting.removeCSS":
            try require(.scripting, in: active)
            return try await removeCSS(payload, extensionID: sender.extensionID)
        case "scripting.executeScript":
            throw FloorpWebExtensionMessageError.unsupportedCodeExecution
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
            requested.origins.isSubset(of: grantedOrigins(in: snapshot))
        return try response(BooleanResponse(value: contains))
    }

    private func requestPermissions(
        _ payload: FloorpWebExtensionMessagePayload,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let details = try decode(PermissionDetailsRequest.self, from: payload)
        let requested = try parsePermissionDetails(details)
        guard requested.apiPermissions.isSubset(of: active.declaredPermissions),
              requested.origins.isSubset(of: active.declaredHosts),
              let permissionRequestAuthorizer else {
            throw FloorpWebExtensionMessageError.permissionDenied
        }
        let consent = FloorpWebExtensionPermissionRequest(
            extensionID: sender.extensionID,
            apiPermissions: requested.apiPermissions,
            origins: requested.origins
        )
        guard await permissionRequestAuthorizer(consent) else {
            return try response(BooleanResponse(value: false))
        }

        let current = await permissionBroker.snapshot(for: sender.extensionID)
        let updated = replacingGrantedOrigins(
            grantedOrigins(in: current).union(requested.origins),
            apiPermissions: current.apiPermissions.union(requested.apiPermissions),
            in: current
        )
        try await persistPermissions(updated, extensionID: sender.extensionID)
        return try response(BooleanResponse(value: true))
    }

    private func removePermissions(
        _ payload: FloorpWebExtensionMessagePayload,
        active: ActiveExtension,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload {
        let details = try decode(PermissionDetailsRequest.self, from: payload)
        let requested = try parsePermissionDetails(details)
        guard requested.apiPermissions.isSubset(of: active.declaredPermissions),
              requested.origins.isSubset(of: active.declaredHosts) else {
            throw FloorpWebExtensionMessageError.malformedEnvelope
        }
        let current = await permissionBroker.snapshot(for: sender.extensionID)
        guard requested.apiPermissions.isSubset(of: current.apiPermissions),
              requested.origins.isSubset(of: grantedOrigins(in: current)) else {
            return try response(BooleanResponse(value: false))
        }
        let updated = replacingGrantedOrigins(
            grantedOrigins(in: current).subtracting(requested.origins),
            apiPermissions: current.apiPermissions.subtracting(requested.apiPermissions),
            in: current
        )
        try await persistPermissions(updated, extensionID: sender.extensionID)
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

    private func persistPermissions(
        _ snapshot: FloorpWebExtensionPermissionSnapshot,
        extensionID: FloorpWebExtensionID
    ) async throws {
        if let permissionMutationHandler {
            try await permissionMutationHandler(snapshot, extensionID)
        } else {
            guard let manager = FloorpWebExtensionPackageStoreRegistry.manager(
                for: profileKey.profileIdentifier,
                isPrivateBrowsing: profileKey.isPrivateBrowsing
            ) else {
                throw FloorpWebExtensionMessageError.permissionDenied
            }
            try await manager.updateGrants(snapshot, for: extensionID)
        }
        // The production manager reactivates this host with the durable
        // snapshot. The explicit refresh also supports an injected transactional
        // test/backend and keeps `contains` linearizable with the mutation.
        await permissionBroker.grant(
            snapshot.apiPermissions,
            requestedHosts: snapshot.requestedHosts,
            hostAccess: snapshot.normalHostAccess,
            privateHostAccess: snapshot.privateHostAccess,
            privateBrowsingEnabled: snapshot.privateBrowsingEnabled,
            to: extensionID
        )
        activeExtensions[extensionID]?.permissions = snapshot.apiPermissions
    }

    private func getRegisteredScripts(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(RegisteredScriptFilterRequest.self, from: payload)
        let ids = request.filter?.ids.map(Set.init)
        let scripts = try await tryCoordinator().registeredScripts(for: extensionID)
            .filter { ids?.contains($0.id) ?? true }
            .map(RegisteredScriptResponse.init)
        return try response(scripts)
    }

    private func registerScripts(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(RegisterScriptsRequest.self, from: payload)
        let scripts = try request.scripts.map(makeRegisteredScript)
        try await tryCoordinator().registerScripts(scripts, for: extensionID)
        return try response(EmptyResponse())
    }

    private func updateScripts(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(RegisterScriptsRequest.self, from: payload)
        let updates = try request.scripts.map(makeRegisteredScriptUpdate)
        try await tryCoordinator().updateScripts(updates, for: extensionID)
        return try response(EmptyResponse())
    }

    private func unregisterScripts(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(UnregisterScriptsRequest.self, from: payload)
        try await tryCoordinator().unregisterScripts(request.ids ?? [], for: extensionID)
        return try response(EmptyResponse())
    }

    private func makeRegisteredScript(
        _ details: RegisteredScriptDetails
    ) throws -> FloorpWebExtensionRegisteredScript {
        guard details.persistAcrossSessions != true,
              let matches = details.matches,
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
            world: try makeWorld(details.world)
        )
    }

    private func makeRegisteredScriptUpdate(
        _ details: RegisteredScriptDetails
    ) throws -> FloorpWebExtensionRegisteredScriptUpdate {
        guard details.persistAcrossSessions != true else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        return .init(
            id: details.id,
            matches: try details.matches.map(makeMatchPatterns),
            excludeMatches: try details.excludeMatches.map(makeMatchPatterns),
            javaScript: try details.js.map(makeSources),
            styleSheets: try details.css.map(makeSources),
            runAt: try details.runAt.map(makeRunAt),
            allFrames: details.allFrames,
            world: try details.world.map(makeWorld)
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

    private func insertCSS(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(InsertCSSRequest.self, from: payload)
        guard request.origin == nil || request.origin == "AUTHOR",
              (request.css == nil) != ((request.files ?? []).isEmpty),
              request.target.documentIds?.isEmpty != false,
              request.target.frameIds == nil || request.target.frameIds == [0],
              let liveScriptingTargetResolver else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        let target = try liveScriptingTargetResolver(request.target.tabId)
        guard target.tab.tabID == request.target.tabId,
              target.tab.isPrivate == profileKey.isPrivateBrowsing,
              target.webView.url == target.tab.url,
              !target.webView.isLoading else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        let css: String
        if let inlineCSS = request.css {
            css = inlineCSS
        } else {
            guard let active = activeExtensions[extensionID] else {
                throw FloorpWebExtensionMessageError.unauthorizedDocument
            }
            css = try (request.files ?? []).map { path in
                guard let source = try? FloorpWebExtensionScriptSource(path),
                      active.resourcePaths.contains(source.path),
                      let loaded = try packageResourceLoader(extensionID, source) else {
                    throw FloorpWebExtensionMessageError.malformedEnvelope
                }
                return loaded
            }.joined(separator: "\n")
        }
        let insertion = try await tryCoordinator().insertCSS(
            css,
            for: extensionID,
            target: .init(tab: target.tab),
            tab: target.tab,
            into: target.webView
        )
        return try response(CSSHandlesResponse(handles: [insertion.handle.rawValue]))
    }

    private func removeCSS(
        _ payload: FloorpWebExtensionMessagePayload,
        extensionID: FloorpWebExtensionID
    ) async throws -> FloorpWebExtensionMessagePayload {
        let request = try decode(RemoveCSSRequest.self, from: payload)
        guard request.target.documentIds?.isEmpty != false,
              request.target.frameIds == nil || request.target.frameIds == [0],
              let liveScriptingTargetResolver else {
            throw FloorpWebExtensionMessageError.unsupportedOperation
        }
        let target = try liveScriptingTargetResolver(request.target.tabId)
        guard target.tab.tabID == request.target.tabId,
              target.tab.isPrivate == profileKey.isPrivateBrowsing,
              target.webView.url == target.tab.url,
              !target.webView.isLoading else {
            throw FloorpWebExtensionMessageError.unauthorizedDocument
        }
        let handles = try request.handles.map { value -> FloorpWebExtensionCSSHandle in
            guard let handle = FloorpWebExtensionCSSHandle(rawValue: value) else {
                throw FloorpWebExtensionMessageError.malformedEnvelope
            }
            return handle
        }
        try await tryCoordinator().removeCSS(
            handles,
            for: extensionID,
            target: .init(tab: target.tab),
            from: target.webView
        )
        return try response(EmptyResponse())
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
        if let previous = entries.updateValue(
            .init(host: host, messageRuntime: messageRuntime),
            forKey: host.profileKey
        ) {
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

    static func deactivate(
        _ extensionID: FloorpWebExtensionID,
        profileKey: FloorpWebExtensionCoordinatorProfileKey
    ) async {
        guard let entry = entries[profileKey] else { return }
        entry.messageRuntime.removeExtension(extensionID)
        await entry.host.deactivate(extensionID)
    }

    static func removeHost(for profileKey: FloorpWebExtensionCoordinatorProfileKey) async {
        guard let entry = entries.removeValue(forKey: profileKey) else { return }
        entry.messageRuntime.tearDown()
        await entry.host.tearDown()
    }
}
