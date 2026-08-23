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
        logger.log("Floorp: WebExtensions core, bundled catalog, and compatibility harness enabled", level: .info, category: .setup)
    }

    /// Creates and injects independent WebKit content-rule-list stores for a
    /// profile's normal and private WebExtensions runtimes. This must run
    /// before tab restoration so the first navigation observes the policy.
    @MainActor
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
            let normalCoordinator = installPackageComposition(
                store: normalPackageStore,
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: false,
                compositionGeneration: compositionGeneration
            )
            let privateCoordinator = installPackageComposition(
                store: privatePackageStore,
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: true,
                compositionGeneration: compositionGeneration
            )
            packageRestoreTasks[profileIdentifier] = Task { @MainActor in
                await restoreInstalledPackages(
                    from: normalPackageStore,
                    into: normalCoordinator,
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
    static func tearDownWebExtensionRuntime(for profile: Profile) {
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
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        compositionGeneration: UUID
    ) -> FloorpWebExtensionCoordinator {
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            runtime: .runtime(
                for: profileIdentifier,
                isPrivateBrowsing: isPrivateBrowsing
            ),
            scriptResourceLoader: store.makeResourceLoader()
        )
        let manager = FloorpWebExtensionLivePackageManager(store: store) { extensionID, package in
            guard packageCompositionGenerations[profileIdentifier] == compositionGeneration else {
                throw FloorpWebExtensionError.unsupported("stale package composition")
            }
            await coordinator.removeExtension(extensionID)
            guard let package else { return }
            guard packageCompositionGenerations[profileIdentifier] == compositionGeneration else {
                throw FloorpWebExtensionError.unsupported("stale package composition")
            }
            do {
                try await restoreInstalledPackage(
                    package,
                    resourceLoader: store.makeResourceLoader(),
                    into: coordinator
                )
            } catch {
                await coordinator.removeExtension(extensionID)
                throw error
            }
        }
        FloorpWebExtensionPackageStoreRegistry.install(store, manager: manager)
        FloorpWebExtensionCoordinator.install(coordinator)
        return coordinator
    }

    /// Rehydrates the execution policy stored with each immutable package
    /// generation. A package is activated as a unit: if any resource cannot be
    /// materialized or compiled, all of that extension's live policy is
    /// removed while other installed extensions continue restoring.
    @MainActor
    static func restoreInstalledPackages(
        from store: FloorpWebExtensionPackageStore,
        into coordinator: FloorpWebExtensionCoordinator,
        logger: Logger = DefaultLogger.shared,
        while isCurrentComposition: @MainActor () -> Bool = { true }
    ) async {
        let packages = await store.installedPackages().filter(\.isEnabled)
        let resourceLoader = store.makeResourceLoader()

        for package in packages {
            guard !Task.isCancelled, isCurrentComposition() else { return }
            do {
                try await restoreInstalledPackage(
                    package,
                    resourceLoader: resourceLoader,
                    into: coordinator
                )
            } catch is CancellationError {
                await coordinator.removeExtension(package.extensionID)
                return
            } catch {
                await coordinator.removeExtension(package.extensionID)
                logger.log(
                    "Floorp: WebExtension \(package.extensionID.rawValue) restore failed: \(error)",
                    level: .warning,
                    category: .setup
                )
            }
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

        await coordinator.grantPermissions(
            grants.apiPermissions,
            requestedHosts: grants.requestedHosts,
            hostAccess: grants.normalHostAccess,
            privateHostAccess: grants.privateHostAccess,
            privateBrowsingEnabled: grants.privateBrowsingEnabled,
            to: extensionID
        )

        let scripts = manifest.contentScripts.enumerated().map { index, script in
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
        if !scripts.isEmpty {
            try await coordinator.registerScripts(scripts, for: extensionID)
        }

        guard !manifest.dnrRuleResources.isEmpty else { return }
        var staticRuleSets = [FloorpWebExtensionDNRStaticRuleSet]()
        var enabledRuleSetIDs = Set<String>()
        for resource in manifest.dnrRuleResources {
            try Task.checkCancellation()
            let source = try resourceLoader(extensionID, resource.path)
            let rules = try JSONDecoder().decode(
                [RestoredDNRRule].self,
                from: Data(source.utf8)
            ).map(\.materialized)
            staticRuleSets.append(.init(identifier: resource.identifier, rules: rules))
            if resource.enabled {
                enabledRuleSetIDs.insert(resource.identifier)
            }
        }
        let applied = try await coordinator.configureDNR(
            for: extensionID,
            staticRuleSets: staticRuleSets,
            enabledStaticRuleSetIDs: enabledRuleSetIDs
        )
        guard applied else {
            throw FloorpWebExtensionError.unsupported("restored DNR generation was superseded")
        }
    }

    @MainActor
    private static func signalWebExtensionReadiness() {
        guard !AppEventQueue.hasSignalled(.floorpWebExtensionsReady) else { return }
        AppEventQueue.signal(event: .floorpWebExtensionsReady)
    }
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
