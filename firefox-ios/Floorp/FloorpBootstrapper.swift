// Floorp iOS Bootstrapper
// Centralizes all Floorp-specific customizations into a single entry point.
// Called once from DependencyHelper.bootstrapDependencies().
//
// This file is part of the Floorp customization layer.
// DO NOT modify Firefox source files directly — add hooks here instead.

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
        FloorpFlags.isTelemetryDisabled = true

        logger.log("Floorp: All telemetry disabled via FloorpFlags", level: .info, category: .setup)
    }
}
