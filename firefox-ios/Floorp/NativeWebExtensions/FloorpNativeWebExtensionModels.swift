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

enum FloorpNativeWebExtensionNavigationFailurePolicy: Hashable, Sendable {
    case failOpen
    case failClosed
}

struct FloorpNativeWebExtensionCatalogItem: Hashable, Sendable {
    let identifier: String
    let resourceName: String
    let resourceExtension: String
    let expectedSHA256: String
    let expectedVersion: String
    let contextIdentifier: String
    let baseURLScheme: String
    let baseURLHost: String
    /// Canonical, digest-pinned popup resource for bundled actions. Floorp
    /// presents this page in a tab-scoped WKWebView instead of WebKit's popup
    /// view, whose data store is always the controller's persistent default.
    let actionPopupPath: String?
    let requiresBackgroundReadiness: Bool
    let requiresNavigationBackgroundReadiness: Bool
    let navigationReadinessFailurePolicy: FloorpNativeWebExtensionNavigationFailurePolicy
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
    static let legacyDarkReaderSHA256 =
        "20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64"
    static let previousDarkReaderSHA256 =
        "775dd26e8a3b1414d71f5329d52bcf0c1cfe57986f370f6d27fdc003a18fa16c"
    static let preDurableStorageDarkReaderSHA256 =
        "c397484ffd0b1a413bab9263ff4e2ef479bc7973689e0ae88c2e77e82cbfd076"
    static let legacyUBlockOriginLiteSHA256 =
        "89dbaf3bfe913b77e959ac8473190b0992cd37c43714bf628713de13dce5bd94"
    static let initialFloorpUBlockOriginLiteSHA256 =
        "8c1e478b690fe4545b2d80df23f28afbe366ca0913dc472a74b78350b8c1dd3d"
    static let previousUBlockOriginLiteSHA256 =
        "2fdb69bd1c9ad9965a61351bd0e94cebb158f787eb3b5c7d8b7e9dcc0fe37585"
    static let preStorageSerializationUBlockOriginLiteSHA256 =
        "33c9006cbe094283c506d7219cd0e57d5b9bd508b8a5bd103dfb6ae32f330076"
    static let preContentScriptSentinelUBlockOriginLiteSHA256 =
        "8c47c090123b7a99b6525910a7d5c34688bb96b3ed07c02711f0a740051255b2"
    static let preLocalStorageSentinelUBlockOriginLiteSHA256 =
        "2f14ed921c05a2ab6a0dcafe1cc5ae0b79e8991ec26e129a63d9b77c9231c915"
    static let preWakeContentScriptReconciliationUBlockOriginLiteSHA256 =
        "cc8ce47cb1957a3bde40492b1c2fcba6f9a38e873b08e5d9348796cd63f31e1c"
    static let preDurableProtectionReconciliationUBlockOriginLiteSHA256 =
        "87c01f8c8e71ab2f65a14225ddaf284198c19417ea77d3d3e70497bfeeec4fcd"
    static let prePopupInitializationRetryUBlockOriginLiteSHA256 =
        "0bf4f4ce6716a971bcf03bf1e18612161a6005152a37b591bf54200b00eb5a6d"
    static let preSafariDNRNormalizationUBlockOriginLiteSHA256 =
        "402934f1f49d0c83d3eec7fb1c4f421897cced7f0fe78e9745551f8ebb80a9a2"
    static let preUserDNRFailClosedUBlockOriginLiteSHA256 =
        "f820df6b21d6a32ff002cd8d25d44063183ab0768c9386a010c2561e8c8ae7ee"
    static let preSafariDNRKeeperUBlockOriginLiteSHA256 =
        "1408e320bd8ed6f0d3c12e95c53c477f219e7f04b5c154fe7743e9d42f94a22d"
    static let preSafariDNRPerStoreCapacityGuardUBlockOriginLiteSHA256 =
        "8f7a43ac13ad09531af2e20023fddcd5354fd737ac6839b85d48f9d041ab429f"

    static let darkReader = FloorpNativeWebExtensionCatalogItem(
        identifier: "floorp.bundled.darkreader",
        resourceName: "darkreader-floorp-ios-mv3-4.9.129",
        resourceExtension: "zip",
        expectedSHA256: "92f40f485205f61233185d1fb7cfb84b1dec243ebefc181d5f53943adc3c97c6",
        expectedVersion: "4.9.129",
        contextIdentifier: "org.darkreader.floorp-ios",
        baseURLScheme: "webkit-extension",
        baseURLHost: "darkreader.floorp.internal",
        actionPopupPath: "ui/popup/index.html",
        requiresBackgroundReadiness: true,
        requiresNavigationBackgroundReadiness: true,
        navigationReadinessFailurePolicy: .failOpen,
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
            "browser.action.openPopup",
            "browser.action.setPopup",
            "browser.windows.create",
            "browser.windows.remove",
            "browser.windows.update"
        ]
    )

    static let uBlockOriginLite = FloorpNativeWebExtensionCatalogItem(
        identifier: "floorp.bundled.ublock-origin-lite",
        resourceName: "uBOLite-floorp-ios-2026.825.1619",
        resourceExtension: "zip",
        expectedSHA256: "cfd521ed8a139ace31c00a0f5047caaa3fe15f61cfe2e3672981cafc373f4057",
        expectedVersion: "2026.825.1619",
        contextIdentifier: "org.ublockorigin.lite.floorp-ios",
        baseURLScheme: "safari-web-extension",
        baseURLHost: "ubol.floorp.internal",
        actionPopupPath: "popup.html",
        requiresBackgroundReadiness: true,
        requiresNavigationBackgroundReadiness: true,
        navigationReadinessFailurePolicy: .failClosed,
        minimumOS: FloorpOperatingSystemVersion(26, 0),
        name: "uBlock Origin Lite",
        summary: FloorpStrings.WebExtensions.uBlockOriginLiteSummary,
        source: "https://github.com/uBlockOrigin/uBOL-home/releases/tag/2026.825.1619",
        sourceRevision: "080d4a2c9d8264e076daa512cf7bbd97f8a2ca6b",
        license: "GPL-3.0-or-later",
        approvedParseErrorCodes: [],
        disabledAPIs: [
            "browser.runtime.connectNative",
            "browser.runtime.sendNativeMessage",
            "browser.action.openPopup",
            "browser.action.setPopup"
        ]
    )

    static let items = [darkReader, uBlockOriginLite]

    @MainActor private static let registeredCustomBaseURLSchemes: Void = {
        Set(items.map(\.baseURLScheme)).subtracting(["webkit-extension"]).forEach {
            WKWebExtension.MatchPattern.registerCustomURLScheme($0)
        }
    }()

    @MainActor static func registerBaseURLSchemes() {
        _ = registeredCustomBaseURLSchemes
    }

    static func item(identifier: String) -> FloorpNativeWebExtensionCatalogItem? {
        items.first { $0.identifier == identifier }
    }

    static func replacementForLegacyBundledRecord(
        _ record: FloorpNativeWebExtensionRecord
    ) -> FloorpNativeWebExtensionCatalogItem? {
        guard record.packageSource == .bundled,
              record.transactionState == .stable else { return nil }
        if record.id == darkReader.identifier,
           record.installedVersion == darkReader.expectedVersion {
            let isOfficialPackage = record.packageReference == "darkreader-chrome-mv3-4.9.129.zip"
                && record.sha256 == legacyDarkReaderSHA256
            let isPreviousFloorpPackage = record.packageReference == darkReader.packageReference
                && [
                    previousDarkReaderSHA256,
                    preDurableStorageDarkReaderSHA256
                ].contains(record.sha256)
            return isOfficialPackage || isPreviousFloorpPackage ? darkReader : nil
        }
        if record.id == uBlockOriginLite.identifier,
           record.installedVersion == uBlockOriginLite.expectedVersion {
            let isOfficialPackage = record.packageReference == "uBOLite_2026.825.1619.safari.zip"
                && record.sha256 == legacyUBlockOriginLiteSHA256
            let isPreviousFloorpPackage = record.packageReference == uBlockOriginLite.packageReference
                && [
                    initialFloorpUBlockOriginLiteSHA256,
                    previousUBlockOriginLiteSHA256,
                    preStorageSerializationUBlockOriginLiteSHA256,
                    preContentScriptSentinelUBlockOriginLiteSHA256,
                    preLocalStorageSentinelUBlockOriginLiteSHA256,
                    preWakeContentScriptReconciliationUBlockOriginLiteSHA256,
                    preDurableProtectionReconciliationUBlockOriginLiteSHA256,
                    prePopupInitializationRetryUBlockOriginLiteSHA256,
                    preSafariDNRNormalizationUBlockOriginLiteSHA256,
                    preUserDNRFailClosedUBlockOriginLiteSHA256,
                    preSafariDNRKeeperUBlockOriginLiteSHA256,
                    preSafariDNRPerStoreCapacityGuardUBlockOriginLiteSHA256
                ].contains(record.sha256)
            return isOfficialPackage || isPreviousFloorpPackage ? uBlockOriginLite : nil
        }
        return nil
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

enum FloorpNativeWebExtensionPermissionDecisionReconciler {
    static func reconcile(
        previousGranted: [FloorpNativeWebExtensionPermissionDecision],
        previousDenied: [FloorpNativeWebExtensionPermissionDecision],
        declaredValues: Set<String>,
        requiredGrantedValues: Set<String>,
        requiredDeniedValues: Set<String>
    ) -> (
        granted: [FloorpNativeWebExtensionPermissionDecision],
        denied: [FloorpNativeWebExtensionPermissionDecision]
    ) {
        var granted = Dictionary(
            uniqueKeysWithValues: previousGranted
                .filter { declaredValues.contains($0.value) }
                .map { ($0.value, $0) }
        )
        var denied = Dictionary(
            uniqueKeysWithValues: previousDenied
                .filter { declaredValues.contains($0.value) }
                .map { ($0.value, $0) }
        )
        for value in requiredGrantedValues {
            granted[value] = FloorpNativeWebExtensionPermissionDecision(value: value)
            denied.removeValue(forKey: value)
        }
        for value in requiredDeniedValues {
            denied[value] = FloorpNativeWebExtensionPermissionDecision(value: value)
            granted.removeValue(forKey: value)
        }
        return (
            granted.values.sorted { $0.value < $1.value },
            denied.values.sorted { $0.value < $1.value }
        )
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
    let unloadState: FloorpNativeWebExtensionUnloadState?
    let hasPrivateAccess: Bool
    let grantedPermissions: [FloorpNativeWebExtensionPermissionDecision]
    let deniedPermissions: [FloorpNativeWebExtensionPermissionDecision]
    let grantedMatchPatterns: [FloorpNativeWebExtensionPermissionDecision]
    let deniedMatchPatterns: [FloorpNativeWebExtensionPermissionDecision]
    /// Optional for backward-compatible decoding of an interrupted transaction
    /// written before this WebKit-owned state was included in rollback data.
    let hasRequestedOptionalAccessToAllHosts: Bool?
    let packageDiagnostics: [FloorpNativeWebExtensionDiagnostic]
    let runtimeDiagnostics: [FloorpNativeWebExtensionDiagnostic]
    let updatedAt: Date
}

struct FloorpNativeWebExtensionUnloadState: Codable, Equatable, Sendable {
    let processIdentifier: UUID
    var enableOnNextColdLaunch: Bool
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
    var unloadState: FloorpNativeWebExtensionUnloadState?
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
        unloadState: FloorpNativeWebExtensionUnloadState? = nil,
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
        self.unloadState = unloadState
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
            unloadState: unloadState,
            hasPrivateAccess: hasPrivateAccess,
            grantedPermissions: grantedPermissions,
            deniedPermissions: deniedPermissions,
            grantedMatchPatterns: grantedMatchPatterns,
            deniedMatchPatterns: deniedMatchPatterns,
            hasRequestedOptionalAccessToAllHosts: hasRequestedOptionalAccessToAllHosts,
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
        unloadState = snapshot.unloadState
        hasPrivateAccess = snapshot.hasPrivateAccess
        grantedPermissions = snapshot.grantedPermissions
        deniedPermissions = snapshot.deniedPermissions
        grantedMatchPatterns = snapshot.grantedMatchPatterns
        deniedMatchPatterns = snapshot.deniedMatchPatterns
        hasRequestedOptionalAccessToAllHosts =
            snapshot.hasRequestedOptionalAccessToAllHosts ?? false
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
    let requiresRestartToEnable: Bool
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
    case backgroundContentStartupTimedOut(String)
    case operationAlreadyInProgress(String)
    case restartRequired(String)
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
        case .backgroundContentStartupTimedOut(let identifier):
            return "The extension background content did not become ready in time: \(identifier)."
        case .operationAlreadyInProgress(let identifier):
            return "Another operation is already in progress for this extension: \(identifier)."
        case .restartRequired(let operation):
            return "\(operation) requires restarting Floorp."
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
