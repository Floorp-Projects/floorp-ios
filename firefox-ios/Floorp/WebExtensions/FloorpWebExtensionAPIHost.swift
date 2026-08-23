// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

@MainActor
protocol FloorpWebExtensionNativeAPIDispatching: AnyObject {
    func dispatch(
        operation: String,
        payload: FloorpWebExtensionMessagePayload,
        sender: any FloorpWebExtensionMessageSender
    ) async throws -> FloorpWebExtensionMessagePayload?
}

/// Profile-owned native implementation of the Stage 2 API subset.
///
/// The message bridge authenticates the extension and document before this
/// host sees a request. This second boundary still verifies profile mode,
/// active package state, API permission, payload shape, and store quotas so a
/// compromised content script cannot acquire a capability by naming it.
@MainActor
final class FloorpWebExtensionAPIHost: FloorpWebExtensionNativeAPIDispatching {
    private struct ActiveExtension {
        let permissions: Set<FloorpWebExtensionAPIGrant>
        let defaultLocale: String
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

    private struct EmptyResponse: Encodable {}
    private struct BooleanResponse: Encodable { let value: Bool }
    private struct IntegerResponse: Encodable { let value: Int }
    private struct StringResponse: Encodable { let value: String }
    private struct StringsResponse: Encodable { let values: [String] }
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
    private let permissionBroker: FloorpWebExtensionPermissionBroker
    private let now: @Sendable () -> Date
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
            defaultLocale: Self.defaultLocale(in: package.rawManifest) ?? i18n.uiLanguage
        )
    }

    func activate(
        extensionID: FloorpWebExtensionID,
        grants: FloorpWebExtensionPermissionSnapshot,
        defaultLocale: String
    ) async {
        activeExtensions[extensionID] = .init(
            permissions: grants.apiPermissions,
            defaultLocale: defaultLocale
        )
        await permissionBroker.grant(
            grants.apiPermissions,
            requestedHosts: grants.requestedHosts,
            hostAccess: grants.normalHostAccess,
            privateHostAccess: grants.privateHostAccess,
            privateBrowsingEnabled: grants.privateBrowsingEnabled,
            to: extensionID
        )
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
