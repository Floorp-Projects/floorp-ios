// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import UIKit
import WebKit

struct FloorpOperatingSystemVersion: Codable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String {
        patch == 0 ? "iOS \(major).\(minor)" : "iOS \(major).\(minor).\(patch)"
    }

    var processInfoVersion: OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }
}

struct FloorpNativeWebExtensionCatalogItem: Hashable, Sendable {
    let identifier: String
    let resourceName: String
    let resourceExtension: String
    let expectedSHA256: String
    let expectedVersion: String
    let contextIdentifier: String
    let baseURLHost: String
    let minimumOS: FloorpOperatingSystemVersion
    let name: String
    let summary: String
    let source: String
    let sourceRevision: String
    let license: String
    let approvedParseErrorCodes: Set<Int>
    let disabledAPIs: Set<String>

    var bundledResourceURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }

    var packageReference: String {
        "\(resourceName).\(resourceExtension)"
    }

    var isAvailableOnCurrentOS: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumOS.processInfoVersion)
    }
}

enum FloorpNativeWebExtensionCatalog {
    static let darkReader = FloorpNativeWebExtensionCatalogItem(
        identifier: "floorp.bundled.darkreader",
        resourceName: "darkreader-chrome-mv3-4.9.129",
        resourceExtension: "zip",
        expectedSHA256: "20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64",
        expectedVersion: "4.9.129",
        contextIdentifier: "org.darkreader.floorp-ios",
        baseURLHost: "darkreader.floorp.internal",
        minimumOS: FloorpOperatingSystemVersion(18, 4),
        name: "Dark Reader",
        summary: FloorpStrings.WebExtensions.darkReaderSummary,
        source: "https://github.com/darkreader/darkreader/releases/tag/v4.9.129",
        sourceRevision: "c2a707302a39b8047543712e9c582bac07835d34",
        license: "MIT",
        approvedParseErrorCodes: [],
        disabledAPIs: [
            "browser.runtime.connectNative",
            "browser.runtime.sendNativeMessage",
            "browser.windows.create",
            "browser.windows.remove",
            "browser.windows.update"
        ]
    )

    static let uBlockOriginLite = FloorpNativeWebExtensionCatalogItem(
        identifier: "floorp.bundled.ublock-origin-lite",
        resourceName: "uBOLite_2026.825.1619.safari",
        resourceExtension: "zip",
        expectedSHA256: "89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94",
        expectedVersion: "2026.825.1619",
        contextIdentifier: "org.ublockorigin.lite.floorp-ios",
        baseURLHost: "ubol.floorp.internal",
        minimumOS: FloorpOperatingSystemVersion(18, 6),
        name: "uBlock Origin Lite",
        summary: FloorpStrings.WebExtensions.uBlockOriginLiteSummary,
        source: "https://github.com/uBlockOrigin/uBOL-home/releases/tag/2026.825.1619",
        sourceRevision: "080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b",
        license: "GPL-3.0-or-later",
        approvedParseErrorCodes: [],
        disabledAPIs: [
            "browser.runtime.connectNative",
            "browser.runtime.sendNativeMessage"
        ]
    )

    static let items = [darkReader, uBlockOriginLite]

    static func item(identifier: String) -> FloorpNativeWebExtensionCatalogItem? {
        items.first { $0.identifier == identifier }
    }
}

enum FloorpNativeWebExtensionPackageSource: String, Codable, Sendable {
    case bundled
    case managed
}

enum FloorpNativeWebExtensionTransactionState: String, Codable, Sendable {
    case stable
    case preparing
    case switching
    case pendingPurge
}

enum FloorpNativeWebExtensionRecoveryOutcome: Equatable, Sendable {
    case unchanged
    case rolledBack
    case pendingPurge
}

struct FloorpNativeWebExtensionPermissionDecision: Codable, Equatable, Hashable, Sendable {
    let value: String
    let expiration: Date

    init(value: String, expiration: Date = .distantFuture) {
        self.value = value
        self.expiration = expiration
    }
}

struct FloorpNativeWebExtensionDiagnostic: Codable, Equatable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable {
        case package
        case runtime
        case host
    }

    let phase: Phase
    let domain: String
    let code: Int
    let message: String
    let recordedAt: Date

    init(phase: Phase, error: NSError, recordedAt: Date = Date()) {
        self.phase = phase
        self.domain = error.domain
        self.code = error.code
        self.message = error.localizedDescription
        self.recordedAt = recordedAt
    }
}

struct FloorpNativeWebExtensionRollback: Codable, Equatable, Sendable {
    let packageSource: FloorpNativeWebExtensionPackageSource
    let packageReference: String
    let sha256: String
    let displayName: String
    let installedVersion: String
    let isEnabled: Bool
    let hasPrivateAccess: Bool
    let grantedPermissions: [FloorpNativeWebExtensionPermissionDecision]
    let deniedPermissions: [FloorpNativeWebExtensionPermissionDecision]
    let grantedMatchPatterns: [FloorpNativeWebExtensionPermissionDecision]
    let deniedMatchPatterns: [FloorpNativeWebExtensionPermissionDecision]
    let packageDiagnostics: [FloorpNativeWebExtensionDiagnostic]
    let runtimeDiagnostics: [FloorpNativeWebExtensionDiagnostic]
    let updatedAt: Date
}

struct FloorpNativeWebExtensionRegistry: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var controllerIdentifier: UUID
    var extensions: [FloorpNativeWebExtensionRecord]

    init(
        schemaVersion: Int = currentSchemaVersion,
        controllerIdentifier: UUID = UUID(),
        extensions: [FloorpNativeWebExtensionRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.controllerIdentifier = controllerIdentifier
        self.extensions = extensions
    }
}

struct FloorpNativeWebExtensionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var contextIdentifier: String
    var baseURLHost: String
    var packageSource: FloorpNativeWebExtensionPackageSource
    var packageReference: String
    var sha256: String
    var displayName: String
    var installedVersion: String
    var isEnabled: Bool
    var hasPrivateAccess: Bool
    var grantedPermissions: [FloorpNativeWebExtensionPermissionDecision]
    var deniedPermissions: [FloorpNativeWebExtensionPermissionDecision]
    var grantedMatchPatterns: [FloorpNativeWebExtensionPermissionDecision]
    var deniedMatchPatterns: [FloorpNativeWebExtensionPermissionDecision]
    var hasRequestedOptionalAccessToAllHosts: Bool
    var packageDiagnostics: [FloorpNativeWebExtensionDiagnostic]
    var runtimeDiagnostics: [FloorpNativeWebExtensionDiagnostic]
    var installedAt: Date
    var updatedAt: Date
    var transactionState: FloorpNativeWebExtensionTransactionState
    var rollback: FloorpNativeWebExtensionRollback?
    var lastError: String?

    init(
        id: String,
        contextIdentifier: String,
        baseURLHost: String,
        packageSource: FloorpNativeWebExtensionPackageSource,
        packageReference: String,
        sha256: String,
        displayName: String,
        installedVersion: String,
        isEnabled: Bool = true,
        hasPrivateAccess: Bool = false,
        grantedPermissions: [FloorpNativeWebExtensionPermissionDecision] = [],
        deniedPermissions: [FloorpNativeWebExtensionPermissionDecision] = [],
        grantedMatchPatterns: [FloorpNativeWebExtensionPermissionDecision] = [],
        deniedMatchPatterns: [FloorpNativeWebExtensionPermissionDecision] = [],
        hasRequestedOptionalAccessToAllHosts: Bool = false,
        packageDiagnostics: [FloorpNativeWebExtensionDiagnostic] = [],
        runtimeDiagnostics: [FloorpNativeWebExtensionDiagnostic] = [],
        installedAt: Date = Date(),
        updatedAt: Date = Date(),
        transactionState: FloorpNativeWebExtensionTransactionState = .stable,
        rollback: FloorpNativeWebExtensionRollback? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.contextIdentifier = contextIdentifier
        self.baseURLHost = baseURLHost
        self.packageSource = packageSource
        self.packageReference = packageReference
        self.sha256 = sha256
        self.displayName = displayName
        self.installedVersion = installedVersion
        self.isEnabled = isEnabled
        self.hasPrivateAccess = hasPrivateAccess
        self.grantedPermissions = grantedPermissions
        self.deniedPermissions = deniedPermissions
        self.grantedMatchPatterns = grantedMatchPatterns
        self.deniedMatchPatterns = deniedMatchPatterns
        self.hasRequestedOptionalAccessToAllHosts = hasRequestedOptionalAccessToAllHosts
        self.packageDiagnostics = packageDiagnostics
        self.runtimeDiagnostics = runtimeDiagnostics
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.transactionState = transactionState
        self.rollback = rollback
        self.lastError = lastError
    }

    var rollbackSnapshot: FloorpNativeWebExtensionRollback {
        FloorpNativeWebExtensionRollback(
            packageSource: packageSource,
            packageReference: packageReference,
            sha256: sha256,
            displayName: displayName,
            installedVersion: installedVersion,
            isEnabled: isEnabled,
            hasPrivateAccess: hasPrivateAccess,
            grantedPermissions: grantedPermissions,
            deniedPermissions: deniedPermissions,
            grantedMatchPatterns: grantedMatchPatterns,
            deniedMatchPatterns: deniedMatchPatterns,
            packageDiagnostics: packageDiagnostics,
            runtimeDiagnostics: runtimeDiagnostics,
            updatedAt: updatedAt
        )
    }

    mutating func restore(_ snapshot: FloorpNativeWebExtensionRollback) {
        packageSource = snapshot.packageSource
        packageReference = snapshot.packageReference
        sha256 = snapshot.sha256
        displayName = snapshot.displayName
        installedVersion = snapshot.installedVersion
        isEnabled = snapshot.isEnabled
        hasPrivateAccess = snapshot.hasPrivateAccess
        grantedPermissions = snapshot.grantedPermissions
        deniedPermissions = snapshot.deniedPermissions
        grantedMatchPatterns = snapshot.grantedMatchPatterns
        deniedMatchPatterns = snapshot.deniedMatchPatterns
        packageDiagnostics = snapshot.packageDiagnostics
        runtimeDiagnostics = snapshot.runtimeDiagnostics
        updatedAt = snapshot.updatedAt
        transactionState = .stable
        rollback = nil
        lastError = nil
    }

    mutating func recoverInterruptedTransaction() -> FloorpNativeWebExtensionRecoveryOutcome {
        switch transactionState {
        case .stable, .pendingPurge:
            return .unchanged
        case .preparing, .switching:
            guard let rollback else {
                isEnabled = false
                transactionState = .pendingPurge
                self.rollback = nil
                lastError = nil
                return .pendingPurge
            }
            restore(rollback)
            return .rolledBack
        }
    }
}

struct FloorpNativeWebExtensionInstallationPreview: Sendable {
    let identifier: String
    let name: String
    let version: String
    let iconData: Data?
    let requiredPermissions: [String]
    let optionalPermissions: [String]
    let requiredMatchPatterns: [String]
    let optionalMatchPatterns: [String]
    let packageDiagnostics: [FloorpNativeWebExtensionDiagnostic]
    let source: String
    let license: String
    let minimumOS: FloorpOperatingSystemVersion
    let isUpdate: Bool
}

struct FloorpNativeWebExtensionSettingsItem: Hashable, Sendable {
    let identifier: String
    let name: String
    let summary: String?
    let version: String
    let iconData: Data?
    let source: String
    let license: String
    let isEnabled: Bool
    let hasPrivateAccess: Bool
    let permissions: [String]
    let optionalPermissions: [String]
    let matchPatterns: [String]
    let optionalMatchPatterns: [String]
    let hasOptionsPage: Bool
    let hasUpdate: Bool
    let diagnostics: [FloorpNativeWebExtensionDiagnostic]
    let errorDescription: String?
}

struct FloorpNativeWebExtensionActionItem {
    let contextIdentifier: String
    let label: String
    let version: String
    let icon: UIImage?
    let isEnabled: Bool
}

enum FloorpNativeWebExtensionError: LocalizedError {
    case hostUnavailable
    case protectedDataUnavailable
    case catalogResourceMissing(String)
    case extensionNotInstalled(String)
    case extensionDisabled(String)
    case invalidRegistry
    case privateAccessDenied
    case unsupportedOperatingSystem(required: FloorpOperatingSystemVersion)
    case invalidPackageSource
    case invalidPackageFormat
    case packageTooLarge(Int64)
    case packageDigestMismatch(expected: String, actual: String)
    case packageVersionMismatch(expected: String, actual: String)
    case unapprovedPackageDiagnostics([FloorpNativeWebExtensionDiagnostic])
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .hostUnavailable:
            return "The native WebExtension host is not available."
        case .protectedDataUnavailable:
            return "The native WebExtension registry is unavailable until protected data is unlocked."
        case .catalogResourceMissing(let name):
            return "The bundled extension resource is missing: \(name)."
        case .extensionNotInstalled(let identifier):
            return "The extension is not installed: \(identifier)."
        case .extensionDisabled(let identifier):
            return "The extension is disabled: \(identifier)."
        case .invalidRegistry:
            return "The native WebExtension registry is invalid."
        case .privateAccessDenied:
            return "This extension is not allowed in private browsing."
        case .unsupportedOperatingSystem(let required):
            return "This extension requires \(required.description) or later."
        case .invalidPackageSource:
            return "The extension package is outside an approved Floorp package source."
        case .invalidPackageFormat:
            return "The extension package is not a regular ZIP archive."
        case .packageTooLarge(let maximum):
            return "The extension package exceeds the \(maximum / 1_048_576) MB size limit."
        case .packageDigestMismatch(let expected, let actual):
            return "The extension package failed its SHA-256 check (expected \(expected), got \(actual))."
        case .packageVersionMismatch(let expected, let actual):
            return "The extension package version is \(actual), but the catalog requires \(expected)."
        case .unapprovedPackageDiagnostics(let diagnostics):
            return "WebKit reported unapproved package diagnostics: "
                + diagnostics.map(\.message).joined(separator: "; ")
        case .unsupportedOperation(let operation):
            return "The extension operation is not supported: \(operation)."
        }
    }
}

extension WKWebExtension.Permission {
    var floorpDisplayName: String {
        switch self {
        case .activeTab, .tabs: return FloorpStrings.WebExtensions.permissionTabs
        case .alarms: return FloorpStrings.WebExtensions.permissionAlarms
        case .clipboardWrite,
             .contextMenus,
             .menus,
             .scripting:
            return FloorpStrings.WebExtensions.permissionBrowserAutomation
        case .cookies,
             .webNavigation,
             .webRequest:
            return FloorpStrings.WebExtensions.permissionSiteData
        case .declarativeNetRequest,
             .declarativeNetRequestFeedback,
             .declarativeNetRequestWithHostAccess:
            return FloorpStrings.WebExtensions.permissionNetworkBlocking
        case .storage, .unlimitedStorage:
            return FloorpStrings.WebExtensions.permissionStorage
        case .nativeMessaging:
            return FloorpStrings.WebExtensions.permissionGenericExplanation
        default: return rawValue
        }
    }
}
