// Floorp Flags
// Single source of truth for all Floorp feature flags.
// These flags are set by FloorpBootstrapper and checked by Firefox hook points.

import Foundation

/// Centralized flags for Floorp customizations.
///
/// Each flag corresponds to a specific hook point in the Firefox codebase.
/// The flags are checked via `FloorpFlags.<flagName>` in the hooked methods.
///
/// ## Hook Points (Firefox files modified):
/// - `TelemetryWrapper.swift` — checks `isTelemetryDisabled`
/// - `MetricKitWrapper.swift` — checks `isTelemetryDisabled`
/// - `SentryWrapper.swift` — checks `isTelemetryDisabled`
/// - `DependencyHelper.swift` — calls `FloorpBootstrapper.configure()`
@MainActor
public final class FloorpFlags {
    /// When `true`, all telemetry (Glean, MetricKit, Sentry) is disabled.
    /// Set by `FloorpBootstrapper.disableTelemetry()`.
    nonisolated(unsafe) public static var isTelemetryDisabled: Bool = false
}
