// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import UIKit
import WebKit

extension Notification.Name {
    static let floorpNativeWebExtensionActionsDidChange = Notification.Name(
        "FloorpNativeWebExtensionActionsDidChange"
    )
}

@MainActor
final class FloorpNativeWebExtensionHost: NSObject {
    private final class WeakTabManager {
        weak var value: (any TabManager)?

        init(_ value: any TabManager) {
            self.value = value
        }
    }

    private struct WindowKey: Hashable {
        let windowUUID: WindowUUID
        let isPrivate: Bool
    }

    private struct PreparedExtension {
        let item: FloorpNativeWebExtensionCatalogItem
        let package: FloorpNativeWebExtensionVerifiedPackage
        let webExtension: WKWebExtension
        let diagnostics: [FloorpNativeWebExtensionDiagnostic]
    }

    private static var hosts = [String: FloorpNativeWebExtensionHost]()

    static func install(for profile: Profile) throws -> FloorpNativeWebExtensionHost {
        let profileIdentifier = profile.localName()
        if let host = hosts[profileIdentifier] {
            return host
        }
        do {
            let host = try FloorpNativeWebExtensionHost(profile: profile)
            hosts[profileIdentifier] = host
            return host
        } catch {
            guard UIApplication.shared.isProtectedDataAvailable else {
                throw FloorpNativeWebExtensionError.protectedDataUnavailable
            }
            throw error
        }
    }

    static func host(for profileIdentifier: String) -> FloorpNativeWebExtensionHost? {
        hosts[profileIdentifier]
    }

    static func remove(for profileIdentifier: String) {
        hosts.removeValue(forKey: profileIdentifier)?.tearDown()
    }

    let controller: WKWebExtensionController
    let profileIdentifier: String

    private weak var profile: Profile?
    private let rootDirectory: URL
    private let registryStore: FloorpNativeWebExtensionRegistryStore
    private let installer: FloorpNativeWebExtensionPackageInstaller
    private let logger: Logger
    private var registry: FloorpNativeWebExtensionRegistry
    private var hostDiagnostics = [FloorpNativeWebExtensionDiagnostic]()
    private var contexts = [String: WKWebExtensionContext]()
    private var tabAdapters = [ObjectIdentifier: FloorpNativeWebExtensionTab]()
    private var windowAdapters = [WindowKey: FloorpNativeWebExtensionWindow]()
    private var tabManagers = [WindowUUID: WeakTabManager]()
    private var announcedTabs = Set<ObjectIdentifier>()
    private var announcedWindows = Set<WindowKey>()
    private var lastFocusedWindow: WindowKey?

    private init(profile: Profile, logger: Logger = DefaultLogger.shared) throws {
        self.profile = profile
        self.profileIdentifier = profile.localName()
        self.logger = logger
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw FloorpNativeWebExtensionError.protectedDataUnavailable
        }

        let directoryPath = try profile.files.getAndEnsureDirectory("WebExtensionsV2")
        let rootDirectory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .standardizedFileURL
        self.rootDirectory = rootDirectory
        let registryStore = FloorpNativeWebExtensionRegistryStore(
            url: rootDirectory.appendingPathComponent("registry-v2.json", isDirectory: false)
        )
        self.registryStore = registryStore
        self.installer = try FloorpNativeWebExtensionPackageInstaller(rootDirectory: rootDirectory)

        do {
            self.registry = try registryStore.load()
        } catch {
            guard UIApplication.shared.isProtectedDataAvailable else {
                throw FloorpNativeWebExtensionError.protectedDataUnavailable
            }
            registryStore.quarantineCorruptRegistry()
            self.registry = FloorpNativeWebExtensionRegistry()
            self.hostDiagnostics = [FloorpNativeWebExtensionDiagnostic(
                phase: .host,
                error: error as NSError
            )]
        }

        let configuration = WKWebExtensionController.Configuration(
            identifier: registry.controllerIdentifier
        )
        configuration.defaultWebsiteDataStore = .default()
        self.controller = WKWebExtensionController(configuration: configuration)

        super.init()
        controller.delegate = self
        do {
            try persistRegistry()
        } catch {
            guard UIApplication.shared.isProtectedDataAvailable else {
                throw FloorpNativeWebExtensionError.protectedDataUnavailable
            }
            throw error
        }
    }

    func restoreInstalledExtensions() async {
        recoverInterruptedTransactions()
        for record in registry.extensions {
            if record.transactionState == .pendingPurge {
                do {
                    try await completePendingPurge(record)
                } catch {
                    updateRecord(record.id) { $0.lastError = error.localizedDescription }
                    try? persistRegistry()
                }
                continue
            }
            do {
                let context = try await makeContext(for: record)
                contexts[record.id] = context
                if record.isEnabled {
                    try controller.load(context)
                }
                observeContextChanges(in: context)
                persistRuntimeDiagnostics(for: context)
            } catch {
                updateRecord(record.id) {
                    $0.lastError = error.localizedDescription
                    $0.runtimeDiagnostics = [FloorpNativeWebExtensionDiagnostic(
                        phase: .host,
                        error: error as NSError
                    )]
                }
                logger.log(
                    "Floorp: native WebExtension \(record.id) restore failed: \(error)",
                    level: .warning,
                    category: .setup
                )
            }
        }
        try? persistRegistry()
    }

    func attach(to configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    func register(tabManager: any TabManager) {
        let uuid = tabManager.windowUUID
        guard tabManagers[uuid]?.value !== tabManager else { return }
        tabManagers[uuid] = WeakTabManager(tabManager)
        tabManager.addDelegate(self)

        for isPrivate in [false, true] where !tabs(for: uuid, isPrivate: isPrivate).isEmpty {
            announceWindowIfNeeded(windowUUID: uuid, isPrivate: isPrivate)
        }
        tabManager.tabs.forEach { announceTabIfNeeded($0) }
        if let selectedTab = tabManager.selectedTab {
            didActivate(selectedTab, previousTab: nil)
        }
    }

    func unregister(windowUUID: WindowUUID) {
        if let manager = tabManagers.removeValue(forKey: windowUUID)?.value {
            manager.removeDelegate(self, completion: nil)
        }
        for isPrivate in [false, true] {
            let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
            if announcedWindows.remove(key) != nil,
               let adapter = windowAdapters[key] {
                controller.didCloseWindow(adapter)
            }
            windowAdapters.removeValue(forKey: key)
        }
        let closingAdapters = tabAdapters.filter { $0.value.tab?.windowUUID == windowUUID }
        closingAdapters.forEach {
            announcedTabs.remove($0.key)
            tabAdapters.removeValue(forKey: $0.key)
        }
        if lastFocusedWindow?.windowUUID == windowUUID {
            lastFocusedWindow = nil
            controller.didFocusWindow(nil)
        }
    }

    func tabManager(for windowUUID: WindowUUID) -> (any TabManager)? {
        if let manager = tabManagers[windowUUID]?.value {
            return manager
        }
        let windowManager: WindowManager = AppContainer.shared.resolve()
        return windowManager.allWindowTabManagers().first { $0.windowUUID == windowUUID }
    }

    func tabs(for windowUUID: WindowUUID, isPrivate: Bool) -> [Tab] {
        guard let manager = tabManager(for: windowUUID) else { return [] }
        return isPrivate ? manager.privateTabs : manager.normalTabs
    }

    func tabAdapter(for tab: Tab) -> FloorpNativeWebExtensionTab {
        let key = ObjectIdentifier(tab)
        if let adapter = tabAdapters[key] {
            return adapter
        }
        let adapter = FloorpNativeWebExtensionTab(tab: tab, host: self)
        tabAdapters[key] = adapter
        return adapter
    }

    func windowAdapter(
        for windowUUID: WindowUUID,
        isPrivate: Bool
    ) -> FloorpNativeWebExtensionWindow {
        let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
        if let adapter = windowAdapters[key] {
            return adapter
        }
        let adapter = FloorpNativeWebExtensionWindow(
            windowUUID: windowUUID,
            isPrivateBrowsing: isPrivate,
            host: self
        )
        windowAdapters[key] = adapter
        return adapter
    }

    func canExpose(tab: Tab, to context: WKWebExtensionContext) -> Bool {
        !tab.isPrivate || context.hasAccessToPrivateData
    }

    func focus(windowUUID: WindowUUID, isPrivate: Bool) {
        guard let manager = tabManager(for: windowUUID) else { return }
        if manager.selectedTab?.isPrivate != isPrivate {
            let candidates = isPrivate ? manager.privateTabs : manager.normalTabs
            if let tab = candidates.first {
                manager.selectTab(tab)
            }
        }
        let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
        lastFocusedWindow = key
        announceWindowIfNeeded(windowUUID: windowUUID, isPrivate: isPrivate)
        controller.didFocusWindow(windowAdapter(for: windowUUID, isPrivate: isPrivate))
    }

    func settingsItems() -> [FloorpNativeWebExtensionSettingsItem] {
        registry.extensions.map { record in
            let context = contexts[record.id]
            let item = FloorpNativeWebExtensionCatalog.item(identifier: record.id)
            return FloorpNativeWebExtensionSettingsItem(
                identifier: record.id,
                name: record.displayName,
                summary: item?.summary,
                version: record.installedVersion,
                iconData: context?.webExtension.icon(for: CGSize(width: 64, height: 64))?.pngData(),
                source: item?.source ?? "Managed Floorp catalog",
                license: item?.license ?? "See package metadata",
                isEnabled: record.isEnabled,
                hasPrivateAccess: record.hasPrivateAccess,
                permissions: Set(record.grantedPermissions.map {
                    WKWebExtension.Permission(rawValue: $0.value).floorpDisplayName
                }).sorted(),
                optionalPermissions: context?.webExtension.optionalPermissions
                    .map(\.floorpDisplayName).sorted() ?? [],
                matchPatterns: record.grantedMatchPatterns.map(\.value).sorted(),
                optionalMatchPatterns: context?.webExtension.optionalPermissionMatchPatterns
                    .map(\.string).sorted() ?? [],
                hasOptionsPage: context?.optionsPageURL != nil,
                hasUpdate: item.map {
                    $0.expectedVersion != record.installedVersion || $0.expectedSHA256 != record.sha256
                } ?? false,
                diagnostics: record.packageDiagnostics + record.runtimeDiagnostics + hostDiagnostics,
                errorDescription: record.lastError
            )
        }
    }

    func installationPreview(identifier: String) async throws -> FloorpNativeWebExtensionInstallationPreview {
        let prepared = try await prepareBundledExtension(identifier: identifier)
        let webExtension = prepared.webExtension
        return FloorpNativeWebExtensionInstallationPreview(
            identifier: identifier,
            name: webExtension.displayName ?? prepared.item.name,
            version: webExtension.version ?? "0",
            iconData: webExtension.icon(for: CGSize(width: 64, height: 64))?.pngData(),
            requiredPermissions: Set(webExtension.requestedPermissions.map(\.floorpDisplayName)).sorted(),
            optionalPermissions: Set(webExtension.optionalPermissions.map(\.floorpDisplayName)).sorted(),
            requiredMatchPatterns: webExtension.requestedPermissionMatchPatterns
                .map(\.string).sorted(),
            optionalMatchPatterns: webExtension.optionalPermissionMatchPatterns
                .map(\.string).sorted(),
            packageDiagnostics: prepared.diagnostics,
            source: prepared.item.source,
            license: prepared.item.license,
            minimumOS: prepared.item.minimumOS,
            isUpdate: registry.extensions.contains { $0.id == identifier }
        )
    }

    func installBundledExtension(identifier: String) async throws {
        let prepared = try await prepareBundledExtension(identifier: identifier)
        let item = prepared.item
        let webExtension = prepared.webExtension
        let allowedPermissions = webExtension.requestedPermissions.filter { $0 != .nativeMessaging }
        let deniedPermissions = webExtension.requestedPermissions.subtracting(allowedPermissions)
        let previousRecord = registry.extensions.first { $0.id == identifier }
        let previousContext = contexts[identifier]

        var grantedPermissions = Dictionary(
            uniqueKeysWithValues: (previousRecord?.grantedPermissions ?? []).map { ($0.value, $0) }
        )
        allowedPermissions.forEach {
            grantedPermissions[$0.rawValue] = FloorpNativeWebExtensionPermissionDecision(value: $0.rawValue)
        }
        var deniedPermissionValues = Dictionary(
            uniqueKeysWithValues: (previousRecord?.deniedPermissions ?? []).map { ($0.value, $0) }
        )
        deniedPermissions.forEach {
            deniedPermissionValues[$0.rawValue] = FloorpNativeWebExtensionPermissionDecision(value: $0.rawValue)
        }
        var grantedPatterns = Dictionary(
            uniqueKeysWithValues: (previousRecord?.grantedMatchPatterns ?? []).map { ($0.value, $0) }
        )
        webExtension.requestedPermissionMatchPatterns.forEach {
            grantedPatterns[$0.string] = FloorpNativeWebExtensionPermissionDecision(value: $0.string)
        }

        var record = FloorpNativeWebExtensionRecord(
            id: item.identifier,
            contextIdentifier: previousRecord?.contextIdentifier ?? item.contextIdentifier,
            baseURLHost: previousRecord?.baseURLHost ?? item.baseURLHost,
            packageSource: prepared.package.source,
            packageReference: prepared.package.reference,
            sha256: prepared.package.sha256,
            displayName: webExtension.displayName ?? item.name,
            installedVersion: webExtension.version ?? "0",
            isEnabled: previousRecord?.isEnabled ?? true,
            hasPrivateAccess: previousRecord?.hasPrivateAccess ?? false,
            grantedPermissions: grantedPermissions.values.sorted { $0.value < $1.value },
            deniedPermissions: deniedPermissionValues.values.sorted { $0.value < $1.value },
            grantedMatchPatterns: grantedPatterns.values.sorted { $0.value < $1.value },
            deniedMatchPatterns: previousRecord?.deniedMatchPatterns ?? [],
            hasRequestedOptionalAccessToAllHosts: webExtension.optionalPermissionMatchPatterns
                .contains { $0.string == "<all_urls>" },
            packageDiagnostics: prepared.diagnostics,
            runtimeDiagnostics: [],
            installedAt: previousRecord?.installedAt ?? Date(),
            updatedAt: Date(),
            transactionState: .preparing,
            rollback: previousRecord?.rollbackSnapshot,
            lastError: nil
        )
        replaceRecord(record)
        try persistRegistry()

        do {
            record.transactionState = .switching
            replaceRecord(record)
            try persistRegistry()

            if previousContext?.isLoaded == true {
                try controller.unload(previousContext!)
            }
            let newContext = makeContext(webExtension: webExtension, record: record)
            if record.isEnabled {
                try controller.load(newContext)
            }
            contexts[identifier] = newContext
            observeContextChanges(in: newContext)
            record.runtimeDiagnostics = Self.diagnostics(newContext.errors, phase: .runtime)
            record.lastError = record.runtimeDiagnostics.last?.message
            record.transactionState = .stable
            record.rollback = nil
            replaceRecord(record)
            try persistRegistry()
            if let previousContext, previousContext !== newContext {
                NotificationCenter.default.removeObserver(self, name: nil, object: previousContext)
            }
        } catch {
            if let newContext = contexts[identifier], newContext !== previousContext {
                NotificationCenter.default.removeObserver(self, name: nil, object: newContext)
                if newContext.isLoaded {
                    try? controller.unload(newContext)
                }
            }
            if let previousRecord {
                replaceRecord(previousRecord)
                if let previousContext {
                    contexts[identifier] = previousContext
                    if previousRecord.isEnabled {
                        try? controller.load(previousContext)
                    }
                } else {
                    contexts.removeValue(forKey: identifier)
                }
                try? persistRegistry()
            } else {
                contexts.removeValue(forKey: identifier)
                registry.extensions.removeAll { $0.id == identifier }
                try? persistRegistry()
            }
            throw error
        }
    }

    func setEnabled(_ isEnabled: Bool, identifier: String) async throws {
        guard var record = registry.extensions.first(where: { $0.id == identifier }),
              let context = contexts[identifier] else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        guard record.isEnabled != isEnabled else { return }

        let previous = record
        record.rollback = record.rollbackSnapshot
        record.transactionState = .switching
        replaceRecord(record)
        let affectedTabs = isEnabled ? [] : tabsAffectedByRemoval(
            of: context,
            identifier: identifier
        )

        do {
            try persistRegistry()
            if isEnabled {
                try controller.load(context)
            } else if context.isLoaded {
                try controller.unload(context)
            }
            record.isEnabled = isEnabled
            record.transactionState = .stable
            record.rollback = nil
            record.lastError = nil
            replaceRecord(record)
            try persistRegistry()
            if !isEnabled {
                reloadAfterRemovingExtension(from: affectedTabs, identifier: identifier)
                clearSurfaceHistory(for: identifier)
            }
        } catch {
            replaceRecord(previous)
            if previous.isEnabled, !context.isLoaded {
                try? controller.load(context)
            } else if !previous.isEnabled, context.isLoaded {
                try? controller.unload(context)
            }
            try? persistRegistry()
            throw error
        }
    }

    func setPrivateAccess(_ allowed: Bool, identifier: String) throws {
        guard var record = registry.extensions.first(where: { $0.id == identifier }),
              let context = contexts[identifier] else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        let previous = context.hasAccessToPrivateData
        context.hasAccessToPrivateData = allowed
        record.hasPrivateAccess = allowed
        replaceRecord(record)
        do {
            try persistRegistry()
        } catch {
            context.hasAccessToPrivateData = previous
            record.hasPrivateAccess = previous
            replaceRecord(record)
            throw error
        }

        if !allowed {
            for manager in tabManagers.values.compactMap(\.value) {
                for tab in manager.privateTabs {
                    if tab.floorpNativeWebExtensionContextIdentifier == identifier,
                       let blankURL = URL(string: "about:blank") {
                        switchSurface(in: tab, to: nil, loading: blankURL)
                    } else {
                        tab.reload()
                    }
                }
            }
            clearSurfaceHistory(for: identifier)
        }
    }

    func uninstall(identifier: String) async throws {
        guard var record = registry.extensions.first(where: { $0.id == identifier }) else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        let affectedTabs = contexts[identifier].map {
            tabsAffectedByRemoval(of: $0, identifier: identifier)
        } ?? []
        record.transactionState = .pendingPurge
        record.rollback = nil
        replaceRecord(record)
        try persistRegistry()
        do {
            try await completePendingPurge(record)
        } catch {
            reloadAfterRemovingExtension(from: affectedTabs, identifier: identifier)
            clearSurfaceHistory(for: identifier)
            throw error
        }
        reloadAfterRemovingExtension(from: affectedTabs, identifier: identifier)
        clearSurfaceHistory(for: identifier)
    }

    func optionsViewController(identifier: String, isPrivate: Bool = false) throws -> UIViewController {
        guard let context = contexts[identifier] else {
            throw FloorpNativeWebExtensionError.extensionNotInstalled(identifier)
        }
        guard context.isLoaded else {
            throw FloorpNativeWebExtensionError.extensionDisabled(identifier)
        }
        guard let url = context.optionsPageURL else {
            throw FloorpNativeWebExtensionError.unsupportedOperation("options page")
        }
        if isPrivate, !context.hasAccessToPrivateData {
            throw FloorpNativeWebExtensionError.privateAccessDenied
        }
        guard let configuration = context.webViewConfiguration else {
            throw FloorpNativeWebExtensionError.hostUnavailable
        }
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        let page = FloorpNativeWebExtensionPageViewController(
            title: "\(context.webExtension.displayName ?? FloorpStrings.WebExtensions.genericExtensionName)"
                + " · \(FloorpStrings.WebExtensions.options)",
            url: url,
            configuration: configuration
        )
        return UINavigationController(rootViewController: page)
    }

    func actionItems(for tab: Tab?) -> [FloorpNativeWebExtensionActionItem] {
        guard let tab else { return [] }
        let adapter = tabAdapter(for: tab)
        return registry.extensions.compactMap { record in
            guard record.isEnabled,
                  let context = contexts[record.id],
                  context.isLoaded,
                  canExpose(tab: tab, to: context),
                  let action = context.action(for: adapter) else { return nil }
            return FloorpNativeWebExtensionActionItem(
                contextIdentifier: record.id,
                label: action.label.isEmpty ? record.displayName : action.label,
                version: record.installedVersion,
                icon: action.icon(for: CGSize(width: 32, height: 32)),
                isEnabled: action.isEnabled
            )
        }
    }

    func performAction(
        contextIdentifier: String,
        for tab: Tab
    ) throws {
        guard let context = contexts[contextIdentifier], context.isLoaded else {
            throw FloorpNativeWebExtensionError.extensionDisabled(contextIdentifier)
        }
        guard canExpose(tab: tab, to: context) else {
            throw FloorpNativeWebExtensionError.privateAccessDenied
        }
        let adapter = tabAdapter(for: tab)
        context.performAction(for: adapter)
    }

    /// Returns true when the caller must cancel the current navigation because
    /// the tab is being rebuilt with a context-specific WebKit configuration.
    func routeNavigationIfNeeded(
        tab: Tab,
        url: URL,
        navigationType: WKNavigationType
    ) -> Bool {
        let destination = controller.extensionContext(for: url)
        let currentIdentifier = tab.floorpNativeWebExtensionContextIdentifier
        let destinationIdentifier = destination.flatMap(identifier(for:))

        guard currentIdentifier != destinationIdentifier else {
            if tab.consumeFloorpNativePreserveForwardNavigation() {
                return false
            }
            if navigationType != .backForward, navigationType != .reload,
               tab.webView?.url != url {
                tab.discardFloorpNativeSurfaceForwardHistory()
            }
            return false
        }
        if let destination, tab.isPrivate, !destination.hasAccessToPrivateData {
            return true
        }

        tab.recordFloorpNativeSurfaceTransition(
            toContextIdentifier: destinationIdentifier,
            url: url
        )

        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.switchSurface(in: tab, to: destination, loading: url)
        }
        return true
    }

    func load(url: URL, in tab: Tab, requestedBy context: WKWebExtensionContext? = nil) {
        let destination = controller.extensionContext(for: url)
        if let destination, tab.isPrivate, !destination.hasAccessToPrivateData {
            return
        }
        if let context, let destination, context !== destination,
           !context.hasAccess(to: url, in: tabAdapter(for: tab)) {
            return
        }

        let currentIdentifier = tab.floorpNativeWebExtensionContextIdentifier
        let destinationIdentifier = destination.flatMap(identifier(for:))
        if currentIdentifier != destinationIdentifier {
            tab.recordFloorpNativeSurfaceTransition(
                toContextIdentifier: destinationIdentifier,
                url: url
            )
            switchSurface(in: tab, to: destination, loading: url)
        } else {
            tab.discardFloorpNativeSurfaceForwardHistory()
            tab.loadRequest(URLRequest(url: url))
        }
    }

    func recordCommittedNavigation(in tab: Tab, url: URL) {
        tab.commitFloorpNativeSurfaceNavigation(url: url)
    }

    @discardableResult
    func goBackAcrossSurface(in tab: Tab) -> Bool {
        guard let target = tab.floorpNativeSurfaceBackTarget,
              let context = context(forSurfaceIdentifier: target.contextIdentifier),
              !tab.isPrivate || context?.hasAccessToPrivateData != false else {
            return false
        }
        _ = tab.moveFloorpNativeSurfaceHistoryBack()
        tab.preserveFloorpNativeForwardHistoryForNextNavigation()
        switchSurface(in: tab, to: context, loading: target.url, forceRebuild: true)
        return true
    }

    @discardableResult
    func goForwardAcrossSurface(in tab: Tab) -> Bool {
        guard let target = tab.floorpNativeSurfaceForwardTarget,
              let context = context(forSurfaceIdentifier: target.contextIdentifier),
              !tab.isPrivate || context?.hasAccessToPrivateData != false else {
            return false
        }
        _ = tab.moveFloorpNativeSurfaceHistoryForward()
        tab.preserveFloorpNativeForwardHistoryForNextNavigation()
        switchSurface(in: tab, to: context, loading: target.url, forceRebuild: true)
        return true
    }

    func tabPropertiesDidChange(_ properties: WKWebExtension.TabChangedProperties, for tab: Tab) {
        let adapter = tabAdapter(for: tab)
        controller.didChangeTabProperties(properties, for: adapter)
    }

    func removeLegacyRuntimeData() {
        guard let profile else { return }
        if profile.files.exists("WebExtensions") {
            try? profile.files.remove("WebExtensions")
        }
        let obsoleteNativeRegistry = rootDirectory.appendingPathComponent("registry.json")
        if FileManager.default.fileExists(atPath: obsoleteNativeRegistry.path) {
            try? FileManager.default.removeItem(at: obsoleteNativeRegistry)
        }
        let privateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-webextensions-private", isDirectory: true)
        if FileManager.default.fileExists(atPath: privateRoot.path) {
            try? FileManager.default.removeItem(at: privateRoot)
        }
        profile.prefs.removeObjectForKey("webExtensions.darkReaderMV3InitialInstallCompleted")
    }

    private func switchSurface(
        in tab: Tab,
        to context: WKWebExtensionContext?,
        loading url: URL,
        forceRebuild: Bool = false
    ) {
        if let context,
           let identifier = identifier(for: context),
           let configuration = context.webViewConfiguration {
            configuration.websiteDataStore = tab.floorpNativeWebsiteDataStore
            tab.replaceWebViewForNativeWebExtension(
                contextIdentifier: identifier,
                configuration: configuration,
                url: url,
                forceRebuild: forceRebuild
            )
        } else {
            tab.replaceWebViewForNativeWebExtension(
                contextIdentifier: nil,
                configuration: nil,
                url: url,
                forceRebuild: forceRebuild
            )
        }
    }

    private func identifier(for context: WKWebExtensionContext) -> String? {
        contexts.first(where: { $0.value === context })?.key
    }

    private func context(forSurfaceIdentifier identifier: String?) -> WKWebExtensionContext?? {
        guard let identifier else { return .some(nil) }
        guard let context = contexts[identifier], context.isLoaded else { return nil }
        return .some(context)
    }

    private func clearSurfaceHistory(for identifier: String) {
        for adapter in tabAdapters.values where adapter.tab != nil {
            adapter.tab?.clearFloorpNativeSurfaceHistory()
        }
    }

    private func tabsAffectedByRemoval(
        of context: WKWebExtensionContext,
        identifier: String
    ) -> [Tab] {
        tabManagers.values.compactMap(\.value).flatMap(\.tabs).filter { tab in
            if tab.floorpNativeWebExtensionContextIdentifier == identifier {
                return true
            }
            guard canExpose(tab: tab, to: context),
                  let url = tab.webView?.url ?? tab.url else { return false }
            return context.hasAccess(to: url, in: tabAdapter(for: tab))
        }
    }

    private func reloadAfterRemovingExtension(from tabs: [Tab], identifier: String) {
        for tab in tabs {
            if tab.floorpNativeWebExtensionContextIdentifier == identifier,
               let blankURL = URL(string: "about:blank") {
                switchSurface(in: tab, to: nil, loading: blankURL)
            } else {
                tab.reload()
            }
        }
    }

    private func announceWindowIfNeeded(windowUUID: WindowUUID, isPrivate: Bool) {
        let key = WindowKey(windowUUID: windowUUID, isPrivate: isPrivate)
        guard announcedWindows.insert(key).inserted else { return }
        controller.didOpenWindow(windowAdapter(for: windowUUID, isPrivate: isPrivate))
    }

    private func announceTabIfNeeded(_ tab: Tab) {
        announceWindowIfNeeded(windowUUID: tab.windowUUID, isPrivate: tab.isPrivate)
        let key = ObjectIdentifier(tab)
        guard announcedTabs.insert(key).inserted else { return }
        controller.didOpenTab(tabAdapter(for: tab))
    }

    private func didActivate(_ tab: Tab, previousTab: Tab?) {
        announceTabIfNeeded(tab)
        let key = WindowKey(windowUUID: tab.windowUUID, isPrivate: tab.isPrivate)
        lastFocusedWindow = key
        let adapter = tabAdapter(for: tab)
        controller.didFocusWindow(windowAdapter(for: tab.windowUUID, isPrivate: tab.isPrivate))
        controller.didActivateTab(adapter, previousActiveTab: previousTab.map(tabAdapter(for:)))
    }

    private func makeContext(for record: FloorpNativeWebExtensionRecord) async throws -> WKWebExtensionContext {
        let package = try await installer.verifiedPackage(for: record)
        guard package.sha256 == record.sha256 else {
            throw FloorpNativeWebExtensionError.packageDigestMismatch(
                expected: record.sha256,
                actual: package.sha256
            )
        }
        let webExtension = try await WKWebExtension(resourceBaseURL: package.url)
        let actualVersion = webExtension.version ?? "0"
        guard actualVersion == record.installedVersion else {
            throw FloorpNativeWebExtensionError.packageVersionMismatch(
                expected: record.installedVersion,
                actual: actualVersion
            )
        }
        let diagnostics = Self.diagnostics(webExtension.errors, phase: .package)
        if let item = FloorpNativeWebExtensionCatalog.item(identifier: record.id) {
            let unapproved = diagnostics.filter { !item.approvedParseErrorCodes.contains($0.code) }
            if !unapproved.isEmpty {
                throw FloorpNativeWebExtensionError.unapprovedPackageDiagnostics(unapproved)
            }
        }
        updateRecord(record.id) { $0.packageDiagnostics = diagnostics }
        return makeContext(webExtension: webExtension, record: record)
    }

    private func prepareBundledExtension(identifier: String) async throws -> PreparedExtension {
        guard let item = FloorpNativeWebExtensionCatalog.item(identifier: identifier) else {
            throw FloorpNativeWebExtensionError.catalogResourceMissing(identifier)
        }
        let package = try await installer.verifiedBundledPackage(for: item)
        let webExtension = try await WKWebExtension(resourceBaseURL: package.url)
        let actualVersion = webExtension.version ?? "0"
        guard actualVersion == item.expectedVersion else {
            throw FloorpNativeWebExtensionError.packageVersionMismatch(
                expected: item.expectedVersion,
                actual: actualVersion
            )
        }
        let diagnostics = Self.diagnostics(webExtension.errors, phase: .package)
        let unapproved = diagnostics.filter { !item.approvedParseErrorCodes.contains($0.code) }
        guard unapproved.isEmpty else {
            throw FloorpNativeWebExtensionError.unapprovedPackageDiagnostics(unapproved)
        }
        return PreparedExtension(
            item: item,
            package: package,
            webExtension: webExtension,
            diagnostics: diagnostics
        )
    }

    private func makeContext(
        webExtension: WKWebExtension,
        record: FloorpNativeWebExtensionRecord
    ) -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.contextIdentifier
        context.baseURL = URL(string: "webkit-extension://\(record.baseURLHost)/")!
        context.hasAccessToPrivateData = record.hasPrivateAccess
        context.unsupportedAPIs = FloorpNativeWebExtensionCatalog.item(identifier: record.id)?
            .disabledAPIs ?? [
                "browser.runtime.connectNative",
                "browser.runtime.sendNativeMessage"
            ]
#if DEBUG
        context.isInspectable = true
        context.inspectionName = record.displayName
#endif
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: record.grantedPermissions
                .filter { $0.expiration > Date() }
                .map {
                    (WKWebExtension.Permission(rawValue: $0.value), $0.expiration)
                }
        )
        context.deniedPermissions = Dictionary(
            uniqueKeysWithValues: record.deniedPermissions
                .filter { $0.expiration > Date() }
                .map {
                    (WKWebExtension.Permission(rawValue: $0.value), $0.expiration)
                }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: record.grantedMatchPatterns.compactMap { decision in
                guard decision.expiration > Date(),
                      let pattern = try? WKWebExtension.MatchPattern(string: decision.value) else { return nil }
                return (pattern, decision.expiration)
            }
        )
        context.deniedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: record.deniedMatchPatterns.compactMap { decision in
                guard decision.expiration > Date(),
                      let pattern = try? WKWebExtension.MatchPattern(string: decision.value) else { return nil }
                return (pattern, decision.expiration)
            }
        )
        return context
    }

    private func observeContextChanges(in context: WKWebExtensionContext) {
        let names: [Notification.Name] = [
            WKWebExtensionContext.errorsDidUpdateNotification,
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification
        ]
        names.forEach { name in
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(permissionStateDidChange(_:)),
                name: name,
                object: context
            )
        }
    }

    @objc
    private func permissionStateDidChange(_ notification: Notification) {
        guard let context = notification.object as? WKWebExtensionContext else { return }
        if notification.name == WKWebExtensionContext.errorsDidUpdateNotification {
            persistRuntimeDiagnostics(for: context)
        } else {
            persistPermissionState(for: context)
        }
    }

    private func persistPermissionState(for context: WKWebExtensionContext) {
        guard let identifier = identifier(for: context) else { return }
        updateRecord(identifier) { record in
            record.grantedPermissions = context.grantedPermissions.map {
                FloorpNativeWebExtensionPermissionDecision(value: $0.key.rawValue, expiration: $0.value)
            }.sorted { $0.value < $1.value }
            record.deniedPermissions = context.deniedPermissions.map {
                FloorpNativeWebExtensionPermissionDecision(value: $0.key.rawValue, expiration: $0.value)
            }.sorted { $0.value < $1.value }
            record.grantedMatchPatterns = context.grantedPermissionMatchPatterns.map {
                FloorpNativeWebExtensionPermissionDecision(value: $0.key.string, expiration: $0.value)
            }.sorted { $0.value < $1.value }
            record.deniedMatchPatterns = context.deniedPermissionMatchPatterns.map {
                FloorpNativeWebExtensionPermissionDecision(value: $0.key.string, expiration: $0.value)
            }.sorted { $0.value < $1.value }
        }
        try? persistRegistry()
    }

    private func persistRuntimeDiagnostics(for context: WKWebExtensionContext) {
        guard let identifier = identifier(for: context) else { return }
        updateRecord(identifier) { record in
            record.runtimeDiagnostics = Self.diagnostics(context.errors, phase: .runtime)
            record.lastError = record.runtimeDiagnostics.last?.message
        }
        try? persistRegistry()
    }

    private static func diagnostics(
        _ errors: [Error],
        phase: FloorpNativeWebExtensionDiagnostic.Phase
    ) -> [FloorpNativeWebExtensionDiagnostic] {
        errors.map { FloorpNativeWebExtensionDiagnostic(phase: phase, error: $0 as NSError) }
    }

    private func replaceRecord(_ record: FloorpNativeWebExtensionRecord) {
        if let index = registry.extensions.firstIndex(where: { $0.id == record.id }) {
            registry.extensions[index] = record
        } else {
            registry.extensions.append(record)
        }
    }

    private func updateRecord(
        _ identifier: String,
        mutation: (inout FloorpNativeWebExtensionRecord) -> Void
    ) {
        guard let index = registry.extensions.firstIndex(where: { $0.id == identifier }) else { return }
        mutation(&registry.extensions[index])
    }

    private func persistRegistry() throws {
        try registryStore.save(registry)
    }

    private func recoverInterruptedTransactions() {
        var recovered = [FloorpNativeWebExtensionRecord]()
        for var record in registry.extensions {
            let outcome = record.recoverInterruptedTransaction()
            recovered.append(record)
            switch outcome {
            case .unchanged:
                break
            case .rolledBack:
                logger.log(
                    "Floorp: rolled back interrupted WebExtension transaction \(record.id)",
                    level: .warning,
                    category: .setup
                )
            case .pendingPurge:
                logger.log(
                    "Floorp: queued interrupted WebExtension install \(record.id) for data purge",
                    level: .warning,
                    category: .setup
                )
            }
        }
        registry.extensions = recovered
        try? persistRegistry()
    }

    private func completePendingPurge(_ record: FloorpNativeWebExtensionRecord) async throws {
        if let context = contexts.removeValue(forKey: record.id) {
            if context.isLoaded {
                try controller.unload(context)
            }
            NotificationCenter.default.removeObserver(self, name: nil, object: context)
        }

        let dataTypes = WKWebExtensionController.allExtensionDataTypes
        let dataRecords = await controller.dataRecords(ofTypes: dataTypes)
            .filter { $0.uniqueIdentifier == record.contextIdentifier }
        if let error = dataRecords.flatMap(\.errors).first {
            throw error
        }
        if !dataRecords.isEmpty {
            await controller.removeData(ofTypes: dataTypes, from: dataRecords)
        }

        let previousRegistry = registry
        registry.extensions.removeAll { $0.id == record.id }
        do {
            try persistRegistry()
        } catch {
            registry = previousRegistry
            throw error
        }

        if record.packageSource == .managed {
            do {
                try await installer.removeManagedPackage(reference: record.packageReference)
            } catch {
                logger.log(
                    "Floorp: orphaned managed WebExtension package cleanup failed: \(error)",
                    level: .warning,
                    category: .setup
                )
            }
        }
    }

    private func tearDown() {
        NotificationCenter.default.removeObserver(self)
        tabManagers.values.compactMap(\.value).forEach { manager in
            manager.removeDelegate(self, completion: nil)
        }
        for context in contexts.values where context.isLoaded {
            try? controller.unload(context)
        }
        controller.delegate = nil
        tabManagers.removeAll()
        tabAdapters.removeAll()
        windowAdapters.removeAll()
        contexts.removeAll()
    }

    private func openWindows(for context: WKWebExtensionContext) -> [FloorpNativeWebExtensionWindow] {
        var windows = [FloorpNativeWebExtensionWindow]()
        for manager in tabManagers.values.compactMap(\.value) {
            if !manager.normalTabs.isEmpty {
                windows.append(windowAdapter(for: manager.windowUUID, isPrivate: false))
            }
            if context.hasAccessToPrivateData, !manager.privateTabs.isEmpty {
                windows.append(windowAdapter(for: manager.windowUUID, isPrivate: true))
            }
        }
        if let focused = lastFocusedWindow,
           let index = windows.firstIndex(where: {
               $0.windowUUID == focused.windowUUID && $0.isPrivateBrowsing == focused.isPrivate
           }) {
            let focusedWindow = windows.remove(at: index)
            windows.insert(focusedWindow, at: 0)
        }
        return windows
    }

    private func focusedWindow(for context: WKWebExtensionContext) -> FloorpNativeWebExtensionWindow? {
        if let key = lastFocusedWindow,
           !key.isPrivate || context.hasAccessToPrivateData {
            return windowAdapter(for: key.windowUUID, isPrivate: key.isPrivate)
        }
        return openWindows(for: context).first
    }

    private func presenter(for tab: (any WKWebExtensionTab)?) -> UIViewController? {
        let tabViewController = (tab as? FloorpNativeWebExtensionTab)?.tab?.webView?.window?.rootViewController
        if let tabViewController {
            return Self.topViewController(from: tabViewController)
        }
        if let focused = lastFocusedWindow,
           let manager = tabManager(for: focused.windowUUID) {
            let focusedTabs = focused.isPrivate ? manager.privateTabs : manager.normalTabs
            let selectedTab = manager.selectedTab.flatMap { $0.isPrivate == focused.isPrivate ? $0 : nil }
            let candidates = [selectedTab].compactMap { $0 } + focusedTabs
            if let focusedRoot = candidates.lazy.compactMap({
                $0.webView?.window?.rootViewController
            }).first {
                return Self.topViewController(from: focusedRoot)
            }
        }
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }?
            .rootViewController
        return root.flatMap(Self.topViewController(from:))
    }

    private func presentActionPopup(
        _ popup: UIViewController,
        for tab: (any WKWebExtensionTab)?,
        remainingTransitionRetries: Int = 4,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let presenter = presenter(for: tab), presenter.viewIfLoaded?.window != nil else {
            completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
            return
        }

        let isTransitioning = presenter.isBeingDismissed
            || presenter.isBeingPresented
            || presenter.presentingViewController?.isBeingDismissed == true
        if isTransitioning {
            guard remainingTransitionRetries > 0 else {
                completionHandler(FloorpNativeWebExtensionError.unsupportedOperation("action popup presentation"))
                return
            }
            let retry = { [weak self] in
                guard let self else {
                    completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
                    return
                }
                self.presentActionPopup(
                    popup,
                    for: tab,
                    remainingTransitionRetries: remainingTransitionRetries - 1,
                    completionHandler: completionHandler
                )
            }
            if let transitionCoordinator = presenter.transitionCoordinator {
                transitionCoordinator.animate(alongsideTransition: nil) { _ in retry() }
            } else {
                DispatchQueue.main.async(execute: retry)
            }
            return
        }

        if let popover = popup.popoverPresentationController,
           popover.barButtonItem == nil,
           popover.sourceView == nil {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        presenter.present(popup, animated: true) {
            completionHandler(nil)
        }
    }

    private static func topViewController(from root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController, let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }
        if let tabs = root as? UITabBarController, let selected = tabs.selectedViewController {
            return topViewController(from: selected)
        }
        return root
    }

    private func prompt(
        title: String,
        message: String,
        in tab: (any WKWebExtensionTab)?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let presenter = presenter(for: tab) else {
            completion(false)
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: FloorpStrings.WebExtensions.cancel, style: .cancel) { _ in
            completion(false)
        })
        alert.addAction(UIAlertAction(title: FloorpStrings.WebExtensions.allow, style: .default) { _ in
            completion(true)
        })
        presenter.present(alert, animated: true)
    }
}

// MARK: - Browser lifecycle events

extension FloorpNativeWebExtensionHost: TabManagerDelegate {
    func tabManager(
        _ tabManager: any TabManager,
        didSelectedTabChange selectedTab: Tab,
        previousTab: Tab?,
        isRestoring: Bool
    ) {
        didActivate(selectedTab, previousTab: previousTab)
    }

    func tabManager(
        _ tabManager: any TabManager,
        didAddTab tab: Tab,
        placeNextToParentTab: Bool,
        isRestoring: Bool
    ) {
        announceTabIfNeeded(tab)
    }

    func tabManager(_ tabManager: any TabManager, didRemoveTab tab: Tab, isRestoring: Bool) {
        let key = ObjectIdentifier(tab)
        if announcedTabs.remove(key) != nil {
            controller.didCloseTab(tabAdapter(for: tab), windowIsClosing: false)
        }
        tabAdapters.removeValue(forKey: key)
        let privacyKey = WindowKey(windowUUID: tab.windowUUID, isPrivate: tab.isPrivate)
        if tabs(for: tab.windowUUID, isPrivate: tab.isPrivate).isEmpty,
           announcedWindows.remove(privacyKey) != nil,
           let window = windowAdapters[privacyKey] {
            controller.didCloseWindow(window)
        }
    }

    func tabManagerDidRestoreTabs(_ tabManager: any TabManager) {
        tabManager.tabs.forEach { announceTabIfNeeded($0) }
        if let selectedTab = tabManager.selectedTab {
            didActivate(selectedTab, previousTab: nil)
        }
    }
}

// MARK: - WebKit host delegate

extension FloorpNativeWebExtensionHost: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        openWindows(for: extensionContext)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindow(for: extensionContext)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let requestedWindow = configuration.window as? FloorpNativeWebExtensionWindow
        let window = requestedWindow ?? focusedWindow(for: extensionContext)
        guard let window,
              !window.isPrivateBrowsing || extensionContext.hasAccessToPrivateData,
              let manager = tabManager(for: window.windowUUID) else {
            completionHandler(nil, FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }
        let parent = (configuration.parentTab as? FloorpNativeWebExtensionTab)?.tab
        let tab = manager.addTab(
            nil as URLRequest?,
            afterTab: parent,
            zombie: false,
            isPrivate: window.isPrivateBrowsing
        )
        if let url = configuration.url {
            load(url: url, in: tab, requestedBy: extensionContext)
        }
        if configuration.shouldBeActive {
            manager.selectTab(tab)
        }
        completionHandler(tabAdapter(for: tab), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard !configuration.shouldBePrivate || extensionContext.hasAccessToPrivateData,
              let manager = focusedWindow(for: extensionContext).flatMap({ tabManager(for: $0.windowUUID) })
                ?? tabManagers.values.compactMap(\.value).first else {
            completionHandler(nil, FloorpNativeWebExtensionError.privateAccessDenied)
            return
        }

        let urls = configuration.tabURLs.isEmpty ? [URL(string: "about:blank")!]: configuration.tabURLs
        var lastTab: Tab?
        for url in urls {
            let tab = manager.addTab(
                nil as URLRequest?,
                afterTab: lastTab,
                zombie: false,
                isPrivate: configuration.shouldBePrivate
            )
            load(url: url, in: tab, requestedBy: extensionContext)
            lastTab = tab
        }
        if configuration.shouldBeFocused, let lastTab {
            manager.selectTab(lastTab)
        }
        let window = windowAdapter(for: manager.windowUUID, isPrivate: configuration.shouldBePrivate)
        announceWindowIfNeeded(windowUUID: manager.windowUUID, isPrivate: configuration.shouldBePrivate)
        completionHandler(window, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let identifier = identifier(for: extensionContext),
              let presenter = presenter(for: nil) else {
            completionHandler(FloorpNativeWebExtensionError.hostUnavailable)
            return
        }
        do {
            let options = try optionsViewController(identifier: identifier)
            options.modalPresentationStyle = .formSheet
            presenter.present(options, animated: true)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let eligible = permissions.filter { $0 != .nativeMessaging }
        let detail = Set(eligible.map(\.floorpDisplayName))
            .sorted()
            .map { "• \($0)" }
            .joined(separator: "\n")
        prompt(
            title: FloorpStrings.WebExtensions.permissionRequestTitle,
            message: detail,
            in: tab
        ) { [weak self, weak extensionContext] allowed in
            completionHandler(allowed ? eligible : [], allowed ? .distantFuture : nil)
            guard let self, let extensionContext else { return }
            DispatchQueue.main.async { self.persistPermissionState(for: extensionContext) }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let detail = urls.map(\.absoluteString).sorted().prefix(8).map { "• \($0)" }.joined(separator: "\n")
        prompt(
            title: FloorpStrings.WebExtensions.websiteAccessRequestTitle,
            message: detail,
            in: tab
        ) { [weak self, weak extensionContext] allowed in
            completionHandler(allowed ? urls : [], allowed ? .distantFuture : nil)
            guard let self, let extensionContext else { return }
            DispatchQueue.main.async { self.persistPermissionState(for: extensionContext) }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let detail = matchPatterns.map(\.string).sorted().prefix(8).map { "• \($0)" }.joined(separator: "\n")
        prompt(
            title: FloorpStrings.WebExtensions.websiteAccessRequestTitle,
            message: detail,
            in: tab
        ) { [weak self, weak extensionContext] allowed in
            completionHandler(allowed ? matchPatterns : [], allowed ? .distantFuture : nil)
            guard let self, let extensionContext else { return }
            DispatchQueue.main.async { self.persistPermissionState(for: extensionContext) }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        NotificationCenter.default.post(name: .floorpNativeWebExtensionActionsDidChange, object: self)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard identifier(for: context) != nil,
              let popup = action.popupViewController else {
            completionHandler(FloorpNativeWebExtensionError.unsupportedOperation("action popup"))
            return
        }
        presentActionPopup(
            popup,
            for: action.associatedTab,
            completionHandler: completionHandler
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        replyHandler(nil, FloorpNativeWebExtensionError.unsupportedOperation("native messaging"))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let error = FloorpNativeWebExtensionError.unsupportedOperation("native messaging")
        port.disconnect(throwing: error)
        completionHandler(error)
    }
}
