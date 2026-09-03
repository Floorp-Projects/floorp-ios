// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared

/// Central entry point for all Floorp customizations.
public final class FloorpBootstrapper {
    @MainActor
    private static var restoreTasks = [String: Task<Void, Never>]()
    @MainActor
    private static var readinessTimeoutTasks = [String: Task<Void, Never>]()
    @MainActor
    private static var readyProfiles = Set<String>()
    @MainActor
    private static var readinessWaiters = [String: [CheckedContinuation<Void, Never>]]()

    @MainActor
    public static func configure() {
        let logger = DefaultLogger.shared
        disableTelemetry(logger: logger)
        disableSponsoredShortcuts(logger: logger)
        disableAdAttribution(logger: logger)
        configureOverlayDrawer(logger: logger)
        configureWebExtensions(logger: logger)
        logger.log("Floorp: Bootstrapper configured successfully", level: .info, category: .setup)
    }

    @MainActor
    private static func disableTelemetry(logger: Logger) {
        FloorpFlags.setTelemetryDisabled(true)
        logger.log("Floorp: All telemetry disabled via FloorpFlags", level: .info, category: .setup)
    }

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

    @MainActor
    private static func configureOverlayDrawer(logger: Logger) {
        _ = FloorpPanelManager.shared
        FloorpFlags.setOverlayDrawerEnabled(true)
        logger.log("Floorp: Overlay drawer enabled", level: .info, category: .setup)
    }

    @MainActor
    private static func configureWebExtensions(logger: Logger) {
        FloorpFlags.setNativeWebExtensionsEnabled(true)
        logger.log(
            "Floorp: WebKit native WebExtensions enabled (iOS 18.4+)",
            level: .info,
            category: .setup
        )
    }

    /// Installs one persistent `WKWebExtensionController` for the profile,
    /// restores enabled contexts, then allows scene/tab restoration to begin.
    @MainActor
    static func configureWebExtensionRuntime(
        for profile: Profile,
        logger: Logger = DefaultLogger.shared
    ) {
        let profileIdentifier = profile.localName()
        readyProfiles.remove(profileIdentifier)
        guard FloorpFlags.isNativeWebExtensionsEnabled else {
            markWebExtensionRuntimeReady(for: profileIdentifier, logger: logger)
            return
        }

        restoreTasks.removeValue(forKey: profileIdentifier)?.cancel()
        readinessTimeoutTasks.removeValue(forKey: profileIdentifier)?.cancel()
        do {
            let host = try FloorpNativeWebExtensionHost.install(for: profile)
            logger.log(
                "Floorp: native WebExtension host installed for profile \(profileIdentifier)",
                level: .info,
                category: .setup
            )
            readinessTimeoutTasks[profileIdentifier] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                logger.log(
                    "Floorp: native WebExtension restore exceeded startup budget; continuing in degraded mode",
                    level: .warning,
                    category: .setup
                )
                readinessTimeoutTasks.removeValue(forKey: profileIdentifier)
                markWebExtensionRuntimeReady(for: profileIdentifier, logger: logger)
            }
            restoreTasks[profileIdentifier] = Task { @MainActor in
                logger.log(
                    "Floorp: restoring native WebExtensions for profile \(profileIdentifier)",
                    level: .info,
                    category: .setup
                )
                await host.restoreInstalledExtensions()
                guard !Task.isCancelled else { return }
                host.removeLegacyRuntimeData()
                readinessTimeoutTasks.removeValue(forKey: profileIdentifier)?.cancel()
                restoreTasks.removeValue(forKey: profileIdentifier)
                markWebExtensionRuntimeReady(for: profileIdentifier, logger: logger)
            }
        } catch {
            logger.log(
                "Floorp: native WebExtension host setup failed: \(error)",
                level: .warning,
                category: .setup
            )
            markWebExtensionRuntimeReady(for: profileIdentifier, logger: logger)
        }
    }

    @MainActor
    static func waitForWebExtensionRuntime(for profile: Profile) async {
        let profileIdentifier = profile.localName()
        guard !readyProfiles.contains(profileIdentifier) else { return }
        await withCheckedContinuation { continuation in
            if readyProfiles.contains(profileIdentifier) {
                continuation.resume()
            } else {
                readinessWaiters[profileIdentifier, default: []].append(continuation)
            }
        }
    }

    @MainActor
    static func tearDownWebExtensionRuntime(for profile: Profile) async {
        let profileIdentifier = profile.localName()
        restoreTasks.removeValue(forKey: profileIdentifier)?.cancel()
        readinessTimeoutTasks.removeValue(forKey: profileIdentifier)?.cancel()
        markWebExtensionRuntimeReady(for: profileIdentifier, logger: DefaultLogger.shared)
        FloorpNativeWebExtensionHost.remove(for: profileIdentifier)
    }

    /// WebKit owns extension background process lifetime. There is no custom
    /// hidden WKWebView pool to release under memory pressure anymore.
    @MainActor
    static func releaseWebExtensionBackgroundResources(for profile: Profile) {}

    /// WebKit resumes extension background work with the owning application.
    /// Waiting for an in-flight restore keeps callers from racing host startup.
    @MainActor
    static func applicationDidBecomeActive(
        for profile: Profile,
        logger: Logger = DefaultLogger.shared
    ) async {
        if let restoreTask = restoreTasks[profile.localName()] {
            await restoreTask.value
        }
    }

    @MainActor
    private static func markWebExtensionRuntimeReady(
        for profileIdentifier: String,
        logger: Logger
    ) {
        guard readyProfiles.insert(profileIdentifier).inserted else { return }
        logger.log(
            "Floorp: native WebExtension startup is ready",
            level: .info,
            category: .setup
        )
        readinessWaiters.removeValue(forKey: profileIdentifier)?.forEach { $0.resume() }
    }
}
