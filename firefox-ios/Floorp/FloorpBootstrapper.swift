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
        FloorpFlags.setWebExtensionFeature(.compatibilityHarness, enabled: true)
        logger.log("Floorp: WebExtensions core and compatibility harness enabled", level: .info, category: .setup)
    }

    /// Creates and injects independent WebKit content-rule-list stores for a
    /// profile's normal and private WebExtensions runtimes. This must run
    /// before tab restoration so the first navigation observes the policy.
    @MainActor
    static func configureWebExtensionRuntime(for profile: Profile, logger: Logger = DefaultLogger.shared) {
        guard FloorpFlags.isWebExtensionFeatureEnabled(.core) else { return }

        let profileIdentifier = profile.localName()
        do {
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
            // Keep the state-owning coordinator paired with the same profile
            // and browsing-mode split as its runtime. The default coordinator
            // refuses unmaterialized package resources; package composition
            // replaces it with one that has the installer-owned resolver.
            _ = FloorpWebExtensionCoordinator.coordinator(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
            _ = FloorpWebExtensionCoordinator.coordinator(
                for: profileIdentifier,
                isPrivateBrowsing: true
            )
        } catch {
            logger.log("Floorp: WebExtensions rule-list store setup failed: \(error)", level: .warning, category: .setup)
        }
    }

    /// Removes both runtime instances on process termination and deletes the
    /// ephemeral private store. The normal store remains profile-owned.
    @MainActor
    static func tearDownWebExtensionRuntime(for profile: Profile) {
        let profileIdentifier = profile.localName()
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
}
