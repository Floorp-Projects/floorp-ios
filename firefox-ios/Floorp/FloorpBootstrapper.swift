// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Common

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
    /// Apply all Floorp customizations.
    ///
    /// This method is called once during app startup, after
    /// dependency registration but before the UI is presented.
    @MainActor
    public static func configure() {
        let logger = DefaultLogger.shared

        // Step 1: Disable all telemetry
        disableTelemetry(logger: logger)

        // Step 2: Configure overlay drawer
        configureOverlayDrawer(logger: logger)

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
}
