// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Common
import WebKit

/// Central entry point for all Floorp customizations.
///
/// Called from `DependencyHelper.bootstrapDependencies()` with a single line:
/// ```swift
/// FloorpBootstrapper.configure()
/// ```
///
/// All Floorp-specific behavior is managed here to minimize
/// modifications to the upstream Firefox codebase and reduce
/// merge conflict surface area.
public final class FloorpBootstrapper {
    @MainActor
    private static var privateRuleStoreDirectories = [String: URL]()
    @MainActor
    private static var packageRestoreTasks = [String: Task<Void, Never>]()
    @MainActor
    private static var packageCompositionGenerations = [String: UUID]()
    /// Apply all Floorp customizations.
    ///
    /// This method is called once during app startup, after
    /// dependency registration but before the UI is presented.
    @MainActor
    public static func configure() {
        let logger = DefaultLogger.shared

        // Step 1: Disable all telemetry
        disableTelemetry(logger: logger)

        // Step 2: Disable Mozilla Unified Ads and sponsored shortcuts
        disableSponsoredShortcuts(logger: logger)

        // Step 3: Disable Apple advertising attribution postbacks
        disableAdAttribution(logger: logger)

        // Step 4: Configure overlay drawer
        configureOverlayDrawer(logger: logger)

        // Step 5: Enable the locally bundled MV3 runtime and compatibility evidence.
        configureWebExtensions(logger: logger)

        logger.log("Floorp: Bootstrapper configured successfully", level: .info, category: .setup)
    }

    // MARK: - Telemetry Disabling

    /// Disables all telemetry collection by setting flags that are
    /// checked at each telemetry initialization point in Firefox code.
    ///
    /// This approach (flag-based) is preferred over deleting code because:
    /// - Minimizes merge conflicts with upstream
    /// - Keeps Firefox code compiling without modification
    /// - Easy to verify (check flag value)
    @MainActor
    private static func disableTelemetry(logger: Logger) {
        // The actual disabling happens via static flags that are checked
        // in TelemetryWrapper.setup(), TelemetryWrapper.initGlean(),
        // MetricKitWrapper.beginObservingMXPayloads(), and
        // SentryWrapper.startWithConfigureOptions().
        //
        // SentryWrapper is in BrowserKit (separate SPM package) and cannot
        // import FloorpFlags, so it uses a direct return instead.
        FloorpFlags.setTelemetryDisabled(true)

        logger.log("Floorp: All telemetry disabled via FloorpFlags", level: .info, category: .setup)
    }

    // MARK: - Sponsored Content

    @MainActor
    private static func disableSponsoredShortcuts(logger: Logger) {
        FloorpFlags.setSponsoredShortcutsDisabled(true)
        logger.log("Floorp: Mozilla sponsored and partner tiles disabled", level: .info, category: .setup)
    }

    @MainActor
    private static func disableAdAttribution(logger: Logger) {
        FloorpFlags.setAdAttributionDisabled(true)
        logger.log("Floorp: SKAdNetwork attribution disabled", level: .info, category: .setup)
    }

    // MARK: - Overlay Drawer

    /// Configures the overlay drawer feature.
    ///
    /// Initializes the panel manager which loads persisted panel data
    /// and enables the overlay drawer flag.
    @MainActor
    private static func configureOverlayDrawer(logger: Logger) {
        // Initialize the panel manager (loads persisted panels + config)
        _ = FloorpPanelManager.shared

        // Enable the overlay drawer
        FloorpFlags.setOverlayDrawerEnabled(true)

        logger.log("Floorp: Overlay drawer enabled", level: .info, category: .setup)
    }

    @MainActor
    private static func configureWebExtensions(logger: Logger) {
        FloorpFlags.setWebExtensionFeature(.core, enabled: true)
        FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: true)
        FloorpFlags.setWebExtensionFeature(.compatibilityHarness, enabled: true)
        logger.log(
            "Floorp: WebExtensions core, bundled catalog, and compatibility harness enabled",
            level: .info,
            category: .setup
        )
    }

    /// Creates and injects independent WebKit content-rule-list stores for a
    /// profile's normal and private WebExtensions runtimes. This must run
    /// before tab restoration so the first navigation observes the policy.
    @MainActor
    // swiftlint:disable:next function_body_length
    static func configureWebExtensionRuntime(for profile: Profile, logger: Logger = DefaultLogger.shared) {
        guard FloorpFlags.isWebExtensionFeatureEnabled(.core) else {
            signalWebExtensionReadiness()
            return
        }

        let profileIdentifier = profile.localName()
        do {
            packageRestoreTasks.removeValue(forKey: profileIdentifier)?.cancel()
            let compositionGeneration = UUID()
            packageCompositionGenerations[profileIdentifier] = compositionGeneration
            for isPrivateBrowsing in [false, true] {
                FloorpWebExtensionPackageStoreRegistry.invalidateStore(
                    for: profileIdentifier,
                    isPrivateBrowsing: isPrivateBrowsing
                )
            }
            let normalDirectory = try profile.files.getAndEnsureDirectory(
                "WebExtensions/ContentRuleLists/normal"
            )
            let normalEvidenceDirectory = try profile.files.getAndEnsureDirectory(
                "WebExtensions/CompatibilityEvidence/normal"
            )
            let privateDirectory = try privateRuleStoreDirectory(for: profileIdentifier)
            let privateEvidenceDirectory = privateDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("CompatibilityEvidence", isDirectory: true)
            guard let normalStore = WKContentRuleListStore(url: URL(fileURLWithPath: normalDirectory)),
                  let privateStore = WKContentRuleListStore(url: privateDirectory) else {
                logger.log("Floorp: WebExtensions rule-list store could not be created", level: .warning, category: .setup)
                signalWebExtensionReadiness()
                return
            }
            FloorpWebExtensionRuntime.install(
                .init(contentRuleListStore: normalStore),
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
            FloorpWebExtensionRuntime.install(
                .init(contentRuleListStore: privateStore),
                for: profileIdentifier,
                isPrivateBrowsing: true
            )
            FloorpWebExtensionCompatibilityEvidenceRegistry.install(
                try .init(directory: URL(fileURLWithPath: normalEvidenceDirectory)),
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
            FloorpWebExtensionCompatibilityEvidenceRegistry.install(
                try .init(directory: privateEvidenceDirectory),
                for: profileIdentifier,
                isPrivateBrowsing: true
            )
            let normalPackageDirectory = try profile.files.getAndEnsureDirectory(
                "WebExtensions/Packages/normal"
            )
            let privatePackageDirectory = privateDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Packages", isDirectory: true)
            let normalPackageStore = try FloorpWebExtensionPackageStore(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: false,
                directory: URL(fileURLWithPath: normalPackageDirectory)
            )
            let privatePackageStore = try FloorpWebExtensionPackageStore(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: true,
                directory: privatePackageDirectory
            )
            let normalAPIHost = try installAPIHostComposition(
                store: normalPackageStore,
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: false,
                directory: URL(fileURLWithPath: try profile.files.getAndEnsureDirectory(
                    "WebExtensions/APIHost/normal"
                ))
            )
            let privateAPIHost = try installAPIHostComposition(
                store: privatePackageStore,
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: true,
                directory: privateDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent("APIHost", isDirectory: true)
            )
            let normalCoordinator = try installPackageComposition(
                store: normalPackageStore,
                apiHost: normalAPIHost,
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: false,
                compositionGeneration: compositionGeneration
            )
            let privateCoordinator = try installPackageComposition(
                store: privatePackageStore,
                apiHost: privateAPIHost,
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: true,
                compositionGeneration: compositionGeneration
            )
            packageRestoreTasks[profileIdentifier] = Task { @MainActor in
                await restoreInstalledPackages(
                    from: normalPackageStore,
                    into: normalCoordinator,
                    apiHost: normalAPIHost,
                    logger: logger,
                    while: {
                        packageCompositionGenerations[profileIdentifier] == compositionGeneration
                    }
                )
                guard !Task.isCancelled,
                      packageCompositionGenerations[profileIdentifier] == compositionGeneration else { return }
                await restoreInstalledPackages(
                    from: privatePackageStore,
                    into: privateCoordinator,
                    apiHost: privateAPIHost,
                    logger: logger,
                    while: {
                        packageCompositionGenerations[profileIdentifier] == compositionGeneration
                    }
                )
                guard !Task.isCancelled,
                      packageCompositionGenerations[profileIdentifier] == compositionGeneration else { return }
                packageRestoreTasks.removeValue(forKey: profileIdentifier)
                signalWebExtensionReadiness()
            }
        } catch {
            logger.log("Floorp: WebExtensions rule-list store setup failed: \(error)", level: .warning, category: .setup)
            signalWebExtensionReadiness()
        }
    }

    /// Removes both runtime instances on process termination and deletes the
    /// ephemeral private store. The normal store remains profile-owned.
    @MainActor
    static func tearDownWebExtensionRuntime(for profile: Profile) async {
        let profileIdentifier = profile.localName()
        packageRestoreTasks.removeValue(forKey: profileIdentifier)?.cancel()
        packageCompositionGenerations.removeValue(forKey: profileIdentifier)
        // Remove the coordinators before their runtimes so extension-owned
        // policy can be detached from any live controllers during teardown.
        FloorpWebExtensionCoordinator.removeCoordinator(
            for: profileIdentifier,
            isPrivateBrowsing: false
        )
        FloorpWebExtensionCoordinator.removeCoordinator(
            for: profileIdentifier,
            isPrivateBrowsing: true
        )
        FloorpWebExtensionCompatibilityEvidenceRegistry.removeStore(
            for: profileIdentifier,
            isPrivateBrowsing: false
        )
        FloorpWebExtensionCompatibilityEvidenceRegistry.removeStore(
            for: profileIdentifier,
            isPrivateBrowsing: true
        )
        for isPrivateBrowsing in [false, true] {
            await FloorpWebExtensionAPIHostRegistry.removeHost(for: .init(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: isPrivateBrowsing
            ))
            FloorpWebExtensionPackageStoreRegistry.removeStore(
                for: profileIdentifier,
                isPrivateBrowsing: isPrivateBrowsing
            )
        }
        FloorpWebExtensionRuntime.removeRuntime(for: profileIdentifier, isPrivateBrowsing: false)
        FloorpWebExtensionRuntime.removeRuntime(for: profileIdentifier, isPrivateBrowsing: true)
        if let privateDirectory = privateRuleStoreDirectories.removeValue(forKey: profileIdentifier) {
            // The private compatibility evidence directory is a sibling of
            // ContentRuleLists under this unique session root. Remove the
            // whole root so private diagnostics never outlive the session.
            try? FileManager.default.removeItem(at: privateDirectory.deletingLastPathComponent())
        }
    }

    /// Responds to system memory pressure without dismantling the installed
    /// WebExtensions composition. Hidden background WebViews are recreated
    /// lazily; package stores, grants, content/DNR policy, alarms, storage,
    /// action state, and extension pages remain owned by their existing hosts.
    @MainActor
    static func releaseWebExtensionBackgroundResources(for profile: Profile) {
        releaseWebExtensionBackgroundResources(profileIdentifier: profile.localName())
    }

    @MainActor
    static func releaseWebExtensionBackgroundResources(profileIdentifier: String) {
        FloorpWebExtensionAPIHostRegistry.releaseBackgroundResources(
            for: profileIdentifier
        )
    }

    @MainActor
    private static func privateRuleStoreDirectory(for profileIdentifier: String) throws -> URL {
        if let directory = privateRuleStoreDirectories[profileIdentifier] {
            return directory
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-webextensions-private", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("ContentRuleLists", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        privateRuleStoreDirectories[profileIdentifier] = directory
        return directory
    }

    @MainActor
    private static func installPackageComposition(
        store: FloorpWebExtensionPackageStore,
        apiHost: FloorpWebExtensionAPIHost,
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        compositionGeneration: UUID
    ) throws -> FloorpWebExtensionCoordinator {
        let messageRuntime = FloorpWebExtensionAPIHostRegistry.messageRuntime(
            for: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            runtime: .runtime(
                for: profileIdentifier,
                isPrivateBrowsing: isPrivateBrowsing
            ),
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store,
            suspendAPIHost: { extensionID in
                await apiHost.suspend(extensionID)
            },
            purgeAPIHost: { extensionID in
                try await apiHost.purge(extensionID)
            }
        )
        let reconcileComposition: @MainActor (
            FloorpWebExtensionID,
            FloorpWebExtensionInstalledPackage?,
            FloorpWebExtensionLivePackageManager.ReconciliationOperation,
            FloorpWebExtensionPackageStore.PreparedPackageResources?
        // swiftlint:disable:next closure_body_length
        ) async throws -> Void = { extensionID, package, operation, preparedResources in
            guard packageCompositionGenerations[profileIdentifier] == compositionGeneration else {
                throw FloorpWebExtensionError.unsupported("stale package composition")
            }
            switch operation {
            case .suspend:
                await coordinator.removeExtension(extensionID)
                await apiHost.suspend(extensionID)
            case .uninstall:
                try await coordinator.uninstallExtension(extensionID)
                try await apiHost.purge(extensionID)
            }
            guard packageCompositionGenerations[profileIdentifier] == compositionGeneration else {
                throw FloorpWebExtensionError.unsupported("stale package composition")
            }
            messageRuntime?.removeExtension(extensionID)
            guard let package else { return }
            guard !isPrivateBrowsing || package.grants.privateBrowsingEnabled else { return }
            guard packageCompositionGenerations[profileIdentifier] == compositionGeneration else {
                throw FloorpWebExtensionError.unsupported("stale package composition")
            }
            do {
                try await restoreInstalledPackage(
                    package,
                    resourceLoader: preparedResources?.scriptResourceLoader
                        ?? store.makeResourceLoader(),
                    into: coordinator
                )
                guard packageCompositionGenerations[profileIdentifier] == compositionGeneration else {
                    throw FloorpWebExtensionError.unsupported("stale package composition")
                }
                await apiHost.activate(package)
                guard packageCompositionGenerations[profileIdentifier] == compositionGeneration else {
                    throw FloorpWebExtensionError.unsupported("stale package composition")
                }
                try configurePackageBackground(
                    package,
                    packageStore: store,
                    coordinator: coordinator,
                    pageResourceResolver: preparedResources?.pageResourceResolver
                )
            } catch {
                await coordinator.removeExtension(extensionID)
                await apiHost.suspend(extensionID)
                messageRuntime?.removeExtension(extensionID)
                throw error
            }
        }
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            isCurrentComposition: {
                packageCompositionGenerations[profileIdentifier] == compositionGeneration
            },
            reconcile: { extensionID, package, operation in
                try await reconcileComposition(extensionID, package, operation, nil)
            },
            reconcilePrepared: { extensionID, package, operation, resources in
                try await reconcileComposition(extensionID, package, operation, resources)
            }
        )
        try FloorpWebExtensionPackageStoreRegistry.install(store, manager: manager)
        FloorpWebExtensionCoordinator.install(coordinator)
        return coordinator
    }

    /// Creates the native Stage 2 API surface and its authenticated WebKit
    /// message runtime as one profile-mode-owned composition. The profile- and
    /// mode-bound tab adapter is the sole live-browser dependency; API calls
    /// remain fail-closed when no matching tab or document is available.
    @MainActor
    private static func installAPIHostComposition(
        store: FloorpWebExtensionPackageStore,
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        directory: URL
    ) throws -> FloorpWebExtensionAPIHost {
        let windowManager = AppContainer.shared.resolve() as WindowManager
        let tabsHost = FloorpWebExtensionProfileTabsHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            windowManager: windowManager
        )
        let permissionConsent = FloorpWebExtensionNativePermissionConsentPresenter(
            isPrivateBrowsing: isPrivateBrowsing,
            packageNameLookup: { extensionID, generation in
                guard let package = await store.installedPackage(for: extensionID),
                      package.isEnabled,
                      package.generation == generation else {
                    return nil
                }
                return package.name
            }
        )
        let backgroundRuntimeReference = FloorpWebExtensionBackgroundRuntimeReference()
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            directory: directory,
            preferredLocales: Locale.preferredLanguages,
            packageResourceLoader: store.makeI18nResourceLoader(),
            alarmEvents: FloorpWebExtensionAlarmEventHost(),
            permissionBroker: FloorpWebExtensionPermissionBroker(),
            tabsHost: tabsHost,
            alarmEventHandler: { event in
                guard let runtime = backgroundRuntimeReference.runtime else { return }
                do {
                    try await runtime.dispatchAlarmEvent(event)
                } catch {
                    DefaultLogger.shared.log(
                        "Floorp: WebExtension alarm delivery failed: \(error)",
                        level: .warning,
                        category: .storage
                    )
                }
            },
            runtimeReloader: { extensionID in
                guard let manager = FloorpWebExtensionPackageStoreRegistry.manager(
                    for: profileIdentifier,
                    isPrivateBrowsing: isPrivateBrowsing
                ) else {
                    throw FloorpWebExtensionError.unsupported("WebExtension package manager is unavailable")
                }
                try await manager.reload(extensionID)
            },
            permissionRequestAuthorizer: { request in
                await permissionConsent.authorize(request)
            },
            liveScriptingTargetResolver: { tabID in
                try tabsHost.liveScriptingTarget(tabID: tabID)
            }
        )
        let messageRuntime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: host)
        backgroundRuntimeReference.runtime = messageRuntime
        FloorpWebExtensionAPIHostRegistry.install(
            host,
            messageRuntime: messageRuntime
        )
        return host
    }

    /// Rehydrates the execution policy stored with each immutable package
    /// generation. A package is activated as a unit: if any resource cannot be
    /// materialized or compiled, all of that extension's live policy is
    /// removed while other installed extensions continue restoring.
    @MainActor
    static func restoreInstalledPackages(
        from store: FloorpWebExtensionPackageStore,
        into coordinator: FloorpWebExtensionCoordinator,
        apiHost: FloorpWebExtensionAPIHost? = nil,
        logger: Logger = DefaultLogger.shared,
        while isCurrentComposition: @MainActor () -> Bool = { true }
    ) async {
        let packages = await store.installedPackages().filter { package in
            package.isEnabled &&
                (!coordinator.profileKey.isPrivateBrowsing || package.grants.privateBrowsingEnabled)
        }
        let resourceLoader = store.makeResourceLoader()
        let registeredManager = FloorpWebExtensionPackageStoreRegistry.manager(
            for: coordinator.profileKey.profileIdentifier,
            isPrivateBrowsing: coordinator.profileKey.isPrivateBrowsing
        )
        let lifecycleManager = registeredManager?.store === store ? registeredManager : nil

        for package in packages {
            guard !Task.isCancelled, isCurrentComposition() else { return }
            if let lifecycleManager {
                do {
                    _ = try await lifecycleManager.restoreInstalledPackageIfCurrent(package)
                } catch is CancellationError {
                    return
                } catch {
                    logger.log(
                        "Floorp: WebExtension \(package.extensionID.rawValue) restore failed: \(error)",
                        level: .warning,
                        category: .setup
                    )
                }
                continue
            }

            do {
                guard await store.installedPackage(for: package.extensionID) == package else {
                    continue
                }
                try await restoreInstalledPackage(
                    package,
                    resourceLoader: resourceLoader,
                    into: coordinator
                )
                guard await store.installedPackage(for: package.extensionID) == package,
                      isCurrentComposition() else {
                    await coordinator.removeExtension(package.extensionID)
                    continue
                }
                if let apiHost {
                    await apiHost.activate(package)
                    try configurePackageBackground(
                        package,
                        packageStore: store,
                        coordinator: coordinator
                    )
                }
            } catch is CancellationError {
                await coordinator.removeExtension(package.extensionID)
                return
            } catch {
                await coordinator.removeExtension(package.extensionID)
                do {
                    try await store.recordActivationFailure(
                        for: package.extensionID,
                        expectedGeneration: package.generation
                    )
                } catch {
                    logger.log(
                        "Floorp: WebExtension \(package.extensionID.rawValue) could not persist its activation failure: \(error)",
                        level: .warning,
                        category: .setup
                    )
                }
                logger.log(
                    "Floorp: WebExtension \(package.extensionID.rawValue) restore failed: \(error)",
                    level: .warning,
                    category: .setup
                )
            }
        }
    }

    /// Delivers the bounded set of alarms that became due while iOS had the
    /// process suspended. Callers use this at a foreground execution
    /// opportunity; the durable alarm actor prevents duplicate consumption if
    /// multiple scenes activate together.
    @MainActor
    static func applicationDidBecomeActive(
        for profile: Profile,
        logger: Logger = DefaultLogger.shared
    ) async {
        guard FloorpFlags.isWebExtensionFeatureEnabled(.core) else { return }
        let profileIdentifier = profile.localName()
        if let restoreTask = packageRestoreTasks[profileIdentifier] {
            await restoreTask.value
        }
        let now = Date()
        for isPrivateBrowsing in [false, true] {
            await drainDueWebExtensionAlarms(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: isPrivateBrowsing,
                now: now,
                logger: logger
            )
        }
    }

    @MainActor
    static func drainDueWebExtensionAlarms(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        now: Date,
        logger: Logger = DefaultLogger.shared
    ) async {
        guard let host = FloorpWebExtensionAPIHostRegistry.host(
            for: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        ) else { return }
        do {
            let events = try await host.alarms.takeDueEvents(now: now)
            await host.alarmEvents.dispatch(events)
        } catch {
            logger.log(
                "Floorp: WebExtensions alarm delivery failed: \(error)",
                level: .warning,
                category: .storage
            )
        }
    }

    @MainActor
    private static func restoreInstalledPackage(
        _ package: FloorpWebExtensionInstalledPackage,
        resourceLoader: FloorpWebExtensionPackageStore.ResourceLoader,
        into coordinator: FloorpWebExtensionCoordinator
    ) async throws {
        let extensionID = package.extensionID
        let manifest = package.preflight.manifest
        let grants = package.grants
        let storedDNRConfiguration = package.dnrConfiguration

        await coordinator.grantPermissions(
            grants.apiPermissions,
            requestedHosts: grants.requestedHosts,
            hostAccess: grants.normalHostAccess,
            privateHostAccess: grants.privateHostAccess,
            privateBrowsingEnabled: grants.privateBrowsingEnabled,
            to: extensionID
        )

        let manifestScripts = manifest.contentScripts.enumerated().map { index, script in
            FloorpWebExtensionRegisteredScript(
                id: "manifest.content-script.\(index)",
                matches: script.matches,
                excludeMatches: script.excludeMatches,
                javaScript: script.javaScript,
                styleSheets: script.styleSheets,
                runAt: script.runAt,
                allFrames: script.allFrames,
                world: script.world
            )
        }
        if !manifestScripts.isEmpty {
            try await coordinator.restoreManifestScripts(manifestScripts, for: extensionID)
        }
        if !package.registeredPersistentScripts.isEmpty {
            try await coordinator.restoreScripts(package.registeredPersistentScripts, for: extensionID)
        }

        let cosmeticResourceData = try manifest.cosmeticFilterResources.map { declaredResource in
            let source = try resourceLoader(extensionID, declaredResource.path)
            return Data(source.utf8)
        }
        let cosmeticResources = try FloorpWebExtensionCosmeticFilterPackageDecoder
            .decodePackage(cosmeticResourceData)
        // Call even for an empty manifest declaration so a package replacement
        // cannot retain generated policies from its prior immutable generation.
        try coordinator.restoreCosmeticResources(cosmeticResources, for: extensionID)

        if storedDNRConfiguration != nil || !manifest.dnrRuleResources.isEmpty {
            var staticRuleSets = [FloorpWebExtensionDNRStaticRuleSet]()
            if !manifest.dnrRuleResources.isEmpty {
                for resource in manifest.dnrRuleResources {
                    try Task.checkCancellation()
                    let source = try resourceLoader(extensionID, resource.path)
                    let rules = try JSONDecoder().decode(
                        [RestoredDNRRule].self,
                        from: Data(source.utf8)
                    ).map(\.materialized)
                    staticRuleSets.append(.init(identifier: resource.identifier, rules: rules))
                }
            }
            let enabledRuleSetIDs = storedDNRConfiguration?.enabledStaticRuleSetIDs
                ?? Set(manifest.dnrRuleResources.filter { $0.enabled }.map(\.identifier))
            let applied = try await coordinator.restoreDNR(
                for: extensionID,
                staticRuleSets: staticRuleSets,
                enabledStaticRuleSetIDs: enabledRuleSetIDs,
                dynamicRules: storedDNRConfiguration?.dynamicRules ?? [],
                limits: storedDNRConfiguration?.limits ?? .init()
            )
            guard applied else {
                throw FloorpWebExtensionError.unsupported("restored DNR generation was superseded")
            }
        }
    }

    /// Publishes a lazy package background only after the native API host has
    /// committed the package's permission snapshot. This ordering prevents an
    /// incoming first message from reaching a background document that has not
    /// yet acquired its profile-scoped capabilities.
    @MainActor
    private static func configurePackageBackground(
        _ package: FloorpWebExtensionInstalledPackage,
        packageStore: FloorpWebExtensionPackageStore,
        coordinator: FloorpWebExtensionCoordinator,
        pageResourceResolver: FloorpWebExtensionPageResourceResolver? = nil
    ) throws {
        let messageRuntime = FloorpWebExtensionAPIHostRegistry.messageRuntime(
            for: coordinator.profileKey.profileIdentifier,
            isPrivateBrowsing: coordinator.profileKey.isPrivateBrowsing
        )
        guard package.preflight.manifest.background != nil else {
            // Unit-level policy restoration can intentionally omit the API
            // composition. A package without a background remains valid in
            // that mode; when the composition exists, revoke any handler
            // retained from an older package generation.
            messageRuntime?.unregisterPackageBackground(for: package.extensionID)
            return
        }
        guard let messageRuntime else {
            throw FloorpWebExtensionError.unsupported("message runtime is unavailable")
        }
        try messageRuntime.registerPackageBackground(
            package: package,
            packageProfileKey: packageStore.profileKey,
            resolver: pageResourceResolver ?? packageStore.makePageResourceResolver()
        )
    }

    @MainActor
    private static func signalWebExtensionReadiness() {
        guard !AppEventQueue.hasSignalled(.floorpWebExtensionsReady) else { return }
        AppEventQueue.signal(event: .floorpWebExtensionsReady)
    }
}

/// Breaks the API-host/background-runtime construction cycle without retaining
/// an obsolete runtime after profile composition is replaced. The alarm
/// callback owns this reference, while the profile registry owns the runtime.
@MainActor
private final class FloorpWebExtensionBackgroundRuntimeReference {
    weak var runtime: FloorpWebExtensionMessageRuntime?
}

private struct RestoredDNRRule: Decodable {
    let id: Int
    let priority: Int
    let action: FloorpWebExtensionDNRAction
    let condition: RestoredDNRCondition

    private enum CodingKeys: String, CodingKey {
        case id, priority, action, condition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 1
        action = try container.decode(FloorpWebExtensionDNRAction.self, forKey: .action)
        condition = try container.decodeIfPresent(RestoredDNRCondition.self, forKey: .condition) ?? .init()
    }

    var materialized: FloorpWebExtensionDNRRule {
        .init(id: id, priority: priority, action: action, condition: condition.materialized)
    }
}

private struct RestoredDNRCondition: Decodable {
    var urlFilter: String?
    var regexFilter: String?
    var isUrlFilterCaseSensitive: Bool?
    var requestDomains = [String]()
    var excludedRequestDomains = [String]()
    var initiatorDomains = [String]()
    var excludedInitiatorDomains = [String]()
    var resourceTypes = [FloorpWebExtensionDNRResourceType]()
    var excludedResourceTypes = [FloorpWebExtensionDNRResourceType]()
    var domainType: FloorpWebExtensionDNRDomainType?
    var tabIDs = [Int]()
    var excludedTabIDs = [Int]()
    var requestMethods = [String]()
    var responseHeaders = [String]()
    var excludedResponseHeaders = [String]()

    private enum CodingKeys: String, CodingKey {
        case urlFilter, regexFilter, isUrlFilterCaseSensitive
        case requestDomains, excludedRequestDomains
        case initiatorDomains, excludedInitiatorDomains
        case resourceTypes, excludedResourceTypes, domainType
        case tabIDs, excludedTabIDs, requestMethods
        case responseHeaders, excludedResponseHeaders
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlFilter = try container.decodeIfPresent(String.self, forKey: .urlFilter)
        regexFilter = try container.decodeIfPresent(String.self, forKey: .regexFilter)
        isUrlFilterCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isUrlFilterCaseSensitive)
        requestDomains = try container.decodeIfPresent([String].self, forKey: .requestDomains) ?? []
        excludedRequestDomains = try container.decodeIfPresent([String].self, forKey: .excludedRequestDomains) ?? []
        initiatorDomains = try container.decodeIfPresent([String].self, forKey: .initiatorDomains) ?? []
        excludedInitiatorDomains = try container.decodeIfPresent([String].self, forKey: .excludedInitiatorDomains) ?? []
        resourceTypes = try container.decodeIfPresent(
            [FloorpWebExtensionDNRResourceType].self,
            forKey: .resourceTypes
        ) ?? []
        excludedResourceTypes = try container.decodeIfPresent(
            [FloorpWebExtensionDNRResourceType].self,
            forKey: .excludedResourceTypes
        ) ?? []
        domainType = try container.decodeIfPresent(FloorpWebExtensionDNRDomainType.self, forKey: .domainType)
        tabIDs = try container.decodeIfPresent([Int].self, forKey: .tabIDs) ?? []
        excludedTabIDs = try container.decodeIfPresent([Int].self, forKey: .excludedTabIDs) ?? []
        requestMethods = try container.decodeIfPresent([String].self, forKey: .requestMethods) ?? []
        responseHeaders = try container.decodeIfPresent([String].self, forKey: .responseHeaders) ?? []
        excludedResponseHeaders = try container.decodeIfPresent([String].self, forKey: .excludedResponseHeaders) ?? []
    }

    var materialized: FloorpWebExtensionDNRCondition {
        .init(
            urlFilter: urlFilter,
            regexFilter: regexFilter,
            isUrlFilterCaseSensitive: isUrlFilterCaseSensitive,
            requestDomains: requestDomains,
            excludedRequestDomains: excludedRequestDomains,
            initiatorDomains: initiatorDomains,
            excludedInitiatorDomains: excludedInitiatorDomains,
            resourceTypes: resourceTypes,
            excludedResourceTypes: excludedResourceTypes,
            domainType: domainType,
            tabIDs: tabIDs,
            excludedTabIDs: excludedTabIDs,
            requestMethods: requestMethods,
            responseHeaders: responseHeaders,
            excludedResponseHeaders: excludedResponseHeaders
        )
    }
}
