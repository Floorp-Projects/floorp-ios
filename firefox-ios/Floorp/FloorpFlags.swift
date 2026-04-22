// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Floorp Flags
// Single source of truth for all Floorp feature flags.
// These flags are set by FloorpBootstrapper and checked by Firefox hook points.

import Foundation

/// Centralized flags for Floorp customizations.
///
/// Each flag corresponds to a specific hook point in the Firefox codebase.
/// The flags are checked via `FloorpFlags.<flagName>` in the hooked methods.
///
/// ## Thread Safety
/// All flag access is protected by an `NSLock` to ensure thread safety.
/// Flags are written once during app startup (`FloorpBootstrapper.configure()`)
/// and read-only afterwards, but the lock protects against edge cases where
/// reads may occur from background threads before startup completes.
///
/// ## Hook Points (Firefox files modified):
/// - `TelemetryWrapper.swift` — checks `isTelemetryDisabled`
/// - `MetricKitWrapper.swift` — checks `isTelemetryDisabled`
/// - `SentryWrapper.swift` — checks `isTelemetryDisabled`
/// - `DependencyHelper.swift` — calls `FloorpBootstrapper.configure()`
///
/// ## Overlay Drawer (Floorp feature):
/// - `FloorpPanelManager` — checks `isOverlayDrawerEnabled`
public final class FloorpFlags: Sendable {
    private static let _lock = NSLock()

    // Backing storage (protected by _lock)
    // nonisolated(unsafe) is required to satisfy Swift Concurrency's global
    // actor isolation checks. Thread safety is guaranteed by NSLock above.
    nonisolated(unsafe) private static var _isTelemetryDisabled = false
    nonisolated(unsafe) private static var _isOverlayDrawerEnabled = false

    /// When `true`, all telemetry (Glean, MetricKit, Sentry) is disabled.
    /// Set by `FloorpBootstrapper.disableTelemetry()`.
    public static var isTelemetryDisabled: Bool {
        _lock.withLock { _isTelemetryDisabled }
    }

    /// Sets the telemetry disabled flag. Called once during app startup.
    public static func setTelemetryDisabled(_ value: Bool) {
        _lock.withLock { _isTelemetryDisabled = value }
    }

    /// When `true`, the overlay drawer feature is enabled.
    /// Set by `FloorpBootstrapper.configureOverlayDrawer()`.
    public static var isOverlayDrawerEnabled: Bool {
        _lock.withLock { _isOverlayDrawerEnabled }
    }

    /// Sets the overlay drawer enabled flag. Called once during app startup.
    public static func setOverlayDrawerEnabled(_ value: Bool) {
        _lock.withLock { _isOverlayDrawerEnabled = value }
    }
}
