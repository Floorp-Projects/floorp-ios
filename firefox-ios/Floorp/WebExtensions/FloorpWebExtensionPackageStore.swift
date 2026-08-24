// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

enum FloorpWebExtensionPackageStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidStoreDirectory
    case corruptedRegistry
    case unsafePackageResource(String)
    case packageQuotaExceeded(String)
    case extensionIdentifierMismatch
    case invalidInitialGrants
    case packageNotInstalled(FloorpWebExtensionID)
    case inactivePackageGeneration(FloorpWebExtensionID)
    case packageUpdateRequiresPermissionConsent(FloorpWebExtensionID)
    case stalePackageComposition
    case resourceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidStoreDirectory:
            return "The WebExtensions package-store directory is invalid."
        case .corruptedRegistry:
            return "The WebExtensions package registry is corrupted."
        case .unsafePackageResource(let path):
            return "The extension package contains an unsafe resource: \(path)"
        case .packageQuotaExceeded(let quota):
            return "The extension package exceeded the \(quota) quota."
        case .extensionIdentifierMismatch:
            return "The extension package identifier does not match the catalog entry."
        case .invalidInitialGrants:
            return "The extension package requested an invalid initial permission grant."
        case .packageNotInstalled(let extensionID):
            return "The extension package is not installed: \(extensionID.rawValue)"
        case .inactivePackageGeneration(let extensionID):
            return "The extension package generation is no longer active: \(extensionID.rawValue)"
        case .packageUpdateRequiresPermissionConsent(let extensionID):
            return "The extension package update requires permission consent: \(extensionID.rawValue)"
        case .stalePackageComposition:
            return "The WebExtensions package-store composition is no longer current."
        case .resourceUnavailable(let path):
            return "The extension package resource is unavailable: \(path)"
        }
    }
}

private final class FloorpWebExtensionPackageCompositionState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCurrent = true

    func invalidate() {
        lock.lock()
        isCurrent = false
        lock.unlock()
    }

    func performIfCurrent<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrent else {
            throw FloorpWebExtensionPackageStoreError.stalePackageComposition
        }
        return try operation()
    }
}

/// Durable metadata for one active immutable package generation.
///
/// The raw manifest is retained for the future `runtime.getManifest()` bridge,
/// while all execution decisions use the normalized preflight report. Grants
/// are committed in the same registry write as the active generation so a
/// restart cannot observe a package without its permission state.
struct FloorpWebExtensionInstalledPackage: Codable, Equatable, Sendable {
    let extensionID: FloorpWebExtensionID
    let generation: String
    let name: String
    let version: String
    let fixture: FloorpWebExtensionFixture
    let packageSHA256: String
    let installedAt: Date
    let rawManifest: Data
    let preflight: FloorpWebExtensionManifestPreflightReport
    let resourcePaths: Set<String>
    var isEnabled: Bool
    var grants: FloorpWebExtensionPermissionSnapshot
    var dnrConfiguration: FloorpWebExtensionStoredDNRConfiguration?
    /// A product-owned explanation for a fail-closed activation disable. This
    /// keeps a runtime activation failure distinct from a deliberate user
    /// disable after process restart.
    var activationError: String? = nil
}

struct FloorpWebExtensionPackageProfileKey: Hashable, Sendable {
    let profileIdentifier: String
    let isPrivateBrowsing: Bool
}

private final class FloorpWebExtensionPackageResourceState: @unchecked Sendable {
    struct Entry: Sendable {
        let packageDirectory: URL
        let generation: String
        let resourcePaths: Set<String>
    }

    private let lock = NSLock()
    private var entries = [FloorpWebExtensionID: Entry]()

    func replace(with entries: [FloorpWebExtensionID: Entry]) {
        lock.lock()
        self.entries = entries
        lock.unlock()
    }

    func load(extensionID: FloorpWebExtensionID, source: FloorpWebExtensionScriptSource) throws -> String {
        lock.lock()
        let entry = entries[extensionID]
        lock.unlock()

        guard let entry, entry.resourcePaths.contains(source.path) else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(source.path)
        }
        return try FloorpWebExtensionPackageStore.loadUTF8Resource(
            source.path,
            from: entry.packageDirectory
        )
    }

    func loadIfPresent(
        extensionID: FloorpWebExtensionID,
        source: FloorpWebExtensionScriptSource
    ) throws -> String? {
        lock.lock()
        let entry = entries[extensionID]
        lock.unlock()

        guard let entry, entry.resourcePaths.contains(source.path) else {
            return nil
        }
        return try FloorpWebExtensionPackageStore.loadUTF8Resource(
            source.path,
            from: entry.packageDirectory
        )
    }

    func loadData(_ request: FloorpWebExtensionPageResourceRequest) throws -> Data {
        lock.lock()
        let entry = entries[request.extensionID]
        lock.unlock()

        guard let entry,
              entry.generation == request.generation,
              entry.resourcePaths.contains(request.path) else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
        }
        return try FloorpWebExtensionPackageStore.loadBinaryResource(
            request.path,
            from: entry.packageDirectory
        )
    }
}

/// Revocable access to one verified but not-yet-committed update candidate.
/// Normal package loaders never consult this state, so an old runtime cannot
/// observe replacement bytes while its registry record is still active.
private final class FloorpWebExtensionPreparedPackageResourceState: @unchecked Sendable {
    private let lock = NSLock()
    private let extensionID: FloorpWebExtensionID
    private let generation: String
    private let packageDirectory: URL
    private let resourcePaths: Set<String>
    private var isValid = true

    init(
        package: FloorpWebExtensionInstalledPackage,
        packagesDirectory: URL
    ) {
        extensionID = package.extensionID
        generation = package.generation
        packageDirectory = packagesDirectory
            .appendingPathComponent(package.extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(package.generation, isDirectory: true)
        resourcePaths = package.resourcePaths
    }

    func invalidate() {
        lock.lock()
        isValid = false
        lock.unlock()
    }

    func load(
        extensionID requestedExtensionID: FloorpWebExtensionID,
        source: FloorpWebExtensionScriptSource
    ) throws -> String {
        lock.lock()
        let allowed = isValid && requestedExtensionID == extensionID && resourcePaths.contains(source.path)
        lock.unlock()
        guard allowed else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(source.path)
        }
        return try FloorpWebExtensionPackageStore.loadUTF8Resource(
            source.path,
            from: packageDirectory
        )
    }

    func loadData(_ request: FloorpWebExtensionPageResourceRequest) throws -> Data {
        lock.lock()
        let allowed = isValid &&
            request.extensionID == extensionID &&
            request.generation == generation &&
            resourcePaths.contains(request.path)
        lock.unlock()
        guard allowed else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(request.path)
        }
        return try FloorpWebExtensionPackageStore.loadBinaryResource(
            request.path,
            from: packageDirectory
        )
    }
}

/// A profile-owned installer and registry for curated bundled MV3 packages.
///
/// Every installation is copied into a fresh generation under `packages/`.
/// The store never mutates a committed generation; registry replacement is the
/// only activation point, and a failed install leaves the prior generation and
/// grants active. The source is accepted only after symlink-safe enumeration,
/// pinned fixture verification, and installation-grade manifest preflight.
actor FloorpWebExtensionPackageStore {
    typealias ResourceLoader = @Sendable (
        FloorpWebExtensionID,
        FloorpWebExtensionScriptSource
    ) throws -> String
    typealias RegistryPersister = @Sendable (Data, URL) throws -> Void

    struct BundledPackageInstallationTransaction: Sendable {
        let installedPackage: FloorpWebExtensionInstalledPackage
        let previousPackage: FloorpWebExtensionInstalledPackage?
    }

    struct PreparedPackageResources: Sendable {
        let scriptResourceLoader: ResourceLoader
        let pageResourceResolver: FloorpWebExtensionPageResourceResolver
    }

    private struct PendingPackageUpdate: Codable, Equatable, Sendable {
        let previousPackage: FloorpWebExtensionInstalledPackage
        let replacementPackage: FloorpWebExtensionInstalledPackage
    }

    private struct Registry: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        var packages: [FloorpWebExtensionInstalledPackage]
        /// Package registry removal and profile-owned API data cleanup cannot
        /// be one filesystem transaction. A tombstone bridges that boundary:
        /// once present, the package is no longer loadable after restart, but
        /// cleanup can be retried until every owned store has been purged.
        var pendingDataPurges: Set<FloorpWebExtensionID>
        /// A two-phase update journal. While present, `packages` may still
        /// point at the previous generation (prepared/revoking) or at the
        /// replacement (activating). Startup recovery always chooses the known
        /// good previous generation and discards the unfinalized replacement.
        var pendingPackageUpdates: [FloorpWebExtensionID: PendingPackageUpdate]

        init(packages: [FloorpWebExtensionInstalledPackage] = []) {
            schemaVersion = Self.currentSchemaVersion
            self.packages = packages
            pendingDataPurges = []
            pendingPackageUpdates = [:]
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case packages
            case pendingDataPurges
            case pendingPackageUpdates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            packages = try container.decode([FloorpWebExtensionInstalledPackage].self, forKey: .packages)
            pendingDataPurges = try container.decodeIfPresent(
                Set<FloorpWebExtensionID>.self,
                forKey: .pendingDataPurges
            ) ?? []
            pendingPackageUpdates = try container.decodeIfPresent(
                [FloorpWebExtensionID: PendingPackageUpdate].self,
                forKey: .pendingPackageUpdates
            ) ?? [:]
        }
    }

    private struct ResourceSnapshot: Sendable {
        let dataByPath: [String: Data]
        let inventory: FloorpWebExtensionManifestPackageInventory
    }

    /// Installation may only receive required manifest authority. A later,
    /// trusted `permissions.request` transaction can persist an explicitly
    /// declared optional grant, but no other caller can widen the package's
    /// durable authority.
    private enum GrantValidationScope {
        case initialInstallation
        case durablePermissionUpdate
    }

    static let maximumResourceCount = 1_024
    static let maximumDirectoryDepth = 16
    static let maximumPackageByteSize = 64 * 1_024 * 1_024
    static let maximumRegistryByteSize = 2 * 1_024 * 1_024

    nonisolated let profileKey: FloorpWebExtensionPackageProfileKey
    private let directory: URL
    private let packagesDirectory: URL
    private let stagingDirectory: URL
    private let registryURL: URL
    private let registryPersister: RegistryPersister
    private let resourceState = FloorpWebExtensionPackageResourceState()
    private let compositionState = FloorpWebExtensionPackageCompositionState()
    private var registry: Registry
    private var preparedResourceStates = [
        FloorpWebExtensionID: FloorpWebExtensionPreparedPackageResourceState
    ]()

    /// `directory` is the profile-local `webextensions` directory. Private
    /// composition must supply an ephemeral directory and remove it with the
    /// private profile; this store never falls back to a shared global path.
    init(
        profileIdentifier: String,
        isPrivateBrowsing: Bool,
        directory: URL,
        registryPersister: @escaping RegistryPersister = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) throws {
        profileKey = .init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        self.directory = directory.standardizedFileURL
        packagesDirectory = self.directory.appendingPathComponent("packages", isDirectory: true)
        stagingDirectory = self.directory.appendingPathComponent("staging", isDirectory: true)
        registryURL = self.directory.appendingPathComponent("installed-packages.json", isDirectory: false)
        self.registryPersister = registryPersister

        try Self.ensureStoreDirectory(self.directory)
        try Self.ensureStoreDirectory(packagesDirectory)
        try Self.ensureStoreDirectory(stagingDirectory)
        registry = try Self.loadRegistry(from: registryURL, packagesDirectory: packagesDirectory)
        if !registry.pendingPackageUpdates.isEmpty {
            let interruptedUpdates = registry.pendingPackageUpdates
            var recovered = registry
            for (extensionID, update) in interruptedUpdates {
                guard let index = recovered.packages.firstIndex(where: {
                    $0.extensionID == extensionID
                }) else {
                    throw FloorpWebExtensionPackageStoreError.corruptedRegistry
                }
                recovered.packages[index] = update.previousPackage
            }
            recovered.packages.sort { $0.extensionID.rawValue < $1.extensionID.rawValue }
            recovered.pendingPackageUpdates.removeAll()
            let data = try Self.encodedRegistryData(recovered)
            try registryPersister(data, registryURL)
            registry = recovered

            for update in interruptedUpdates.values {
                let rejectedDirectory = Self.generationDirectory(
                    packagesDirectory: packagesDirectory,
                    extensionID: update.replacementPackage.extensionID,
                    generation: update.replacementPackage.generation
                )
                try? FileManager.default.removeItem(at: rejectedDirectory)
            }
        }
        resourceState.replace(with: Self.enabledResourceEntries(
            registry: registry,
            packagesDirectory: packagesDirectory
        ))
    }

    /// Installs a digest-pinned bundled fixture into a fresh immutable
    /// generation. No registry state changes until the fully materialized
    /// generation has passed manifest and package verification.
    @discardableResult
    func installBundledPackage(
        at sourceDirectory: URL,
        expectedExtensionID: FloorpWebExtensionID,
        initialGrants: FloorpWebExtensionPermissionSnapshot? = nil
    ) throws -> FloorpWebExtensionInstalledPackage {
        let transaction = try installBundledPackageTransaction(
            at: sourceDirectory,
            expectedExtensionID: expectedExtensionID,
            initialGrants: initialGrants
        )
        if transaction.previousPackage != nil {
            do {
                try commitPreparedBundledPackageUpdate(
                    extensionID: expectedExtensionID,
                    replacementGeneration: transaction.installedPackage.generation
                )
            } catch {
                if let previousPackage = transaction.previousPackage {
                    try? abortPreparedBundledPackageUpdate(
                        extensionID: expectedExtensionID,
                        replacementGeneration: transaction.installedPackage.generation
                    )
                }
                throw error
            }
        }
        return transaction.installedPackage
    }

    /// Returns the replacement and its exact predecessor from one actor-
    /// isolated registry transaction. Lifecycle code must use this result for
    /// rollback instead of taking a separate, racy pre-install snapshot.
    func installBundledPackageTransaction(
        at sourceDirectory: URL,
        expectedExtensionID: FloorpWebExtensionID,
        initialGrants: FloorpWebExtensionPermissionSnapshot? = nil
    ) throws -> BundledPackageInstallationTransaction {
        guard !registry.pendingDataPurges.contains(expectedExtensionID),
              registry.pendingPackageUpdates[expectedExtensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(
                "package transaction pending for \(expectedExtensionID.rawValue)"
            )
        }
        let resources = try Self.resourceSnapshot(at: sourceDirectory)
        let transactionID = UUID().uuidString.lowercased()
        let stagedPackage = stagingDirectory.appendingPathComponent(transactionID, isDirectory: true)

        do {
            try Self.materialize(resources.dataByPath, at: stagedPackage)
            let fixtureMetadata = try FloorpWebExtensionCompatibilityHarness.verifyFixturePackage(
                at: stagedPackage
            )
            guard fixtureMetadata.fixture.extensionID == expectedExtensionID else {
                throw FloorpWebExtensionPackageStoreError.extensionIdentifierMismatch
            }
            guard let manifestData = resources.dataByPath["manifest.json"] else {
                throw FloorpWebExtensionPackageStoreError.unsafePackageResource("manifest.json")
            }
            let preflight = try FloorpWebExtensionManifest.preflight(
                manifestData: manifestData,
                packageInventory: resources.inventory,
                ruleResourceData: resources.dataByPath
            )
            guard preflight.isActivationAllowed else {
                throw FloorpWebExtensionError.unsupported("bundled package failed manifest preflight")
            }

            let previousPackage = registry.packages.first {
                $0.extensionID == expectedExtensionID
            }
            if let previousPackage,
               Self.updateRequiresPermissionConsent(
                   from: previousPackage,
                   to: preflight.manifest
               ) {
                throw FloorpWebExtensionPackageStoreError
                    .packageUpdateRequiresPermissionConsent(expectedExtensionID)
            }
            // A catalog refresh is not permission consent. Carry forward only
            // authority already present in the previous immutable generation,
            // narrowed to declarations that still exist in the replacement.
            // In particular, newly-added required permissions and hosts remain
            // ungranted until a trusted product flow explicitly approves them.
            let grants = if let previousPackage {
                try Self.migratedGrants(
                    from: previousPackage,
                    to: preflight.manifest
                )
            } else {
                try Self.validatedGrants(
                    initialGrants,
                    for: preflight.manifest,
                    scope: .initialInstallation
                )
            }
            let generation = transactionID
            let generationDirectory = Self.generationDirectory(
                packagesDirectory: packagesDirectory,
                extensionID: expectedExtensionID,
                generation: generation
            )
            let existingDNRConfiguration = registry.packages.first {
                $0.extensionID == expectedExtensionID
            }?.dnrConfiguration
            if let existingDNRConfiguration {
                let manifestRuleIDs = Set(preflight.manifest.dnrRuleResources.map(\.identifier))
                guard existingDNRConfiguration.enabledStaticRuleSetIDs.isSubset(of: manifestRuleIDs) else {
                    throw FloorpWebExtensionPackageStoreError.corruptedRegistry
                }
                try Self.validateStoredDNRConfiguration(existingDNRConfiguration)
            }
            try Self.ensureStoreDirectory(generationDirectory.deletingLastPathComponent())
            guard !FileManager.default.fileExists(atPath: generationDirectory.path) else {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
            try FileManager.default.moveItem(at: stagedPackage, to: generationDirectory)

            let installed = FloorpWebExtensionInstalledPackage(
                extensionID: expectedExtensionID,
                generation: generation,
                name: preflight.manifest.name,
                version: preflight.manifest.version,
                fixture: fixtureMetadata.fixture,
                packageSHA256: fixtureMetadata.fixture.packageSHA256,
                installedAt: Date(),
                rawManifest: manifestData,
                preflight: preflight,
                resourcePaths: Set(resources.dataByPath.keys),
                isEnabled: previousPackage?.isEnabled ?? true,
                grants: grants,
                dnrConfiguration: existingDNRConfiguration,
                activationError: previousPackage?.activationError
            )

            var next = registry
            if let previousPackage {
                // Phase 1 publishes only the durable rollback journal. The
                // active registry and resource snapshot continue pointing to
                // the previous generation until its runtime is suspended.
                next.pendingPackageUpdates[expectedExtensionID] = .init(
                    previousPackage: previousPackage,
                    replacementPackage: installed
                )
            } else {
                next.packages.append(installed)
                next.packages.sort { $0.extensionID.rawValue < $1.extensionID.rawValue }
            }
            do {
                try persist(next)
            } catch {
                try? FileManager.default.removeItem(at: generationDirectory)
                throw error
            }
            registry = next
            if previousPackage == nil {
                refreshResourceState()
            } else {
                preparedResourceStates[expectedExtensionID] = .init(
                    package: installed,
                    packagesDirectory: packagesDirectory
                )
            }
            return .init(
                installedPackage: installed,
                previousPackage: previousPackage
            )
        } catch {
            try? FileManager.default.removeItem(at: stagedPackage)
            throw error
        }
    }

    func installedPackages() -> [FloorpWebExtensionInstalledPackage] {
        registry.packages
    }

    nonisolated func invalidateComposition() {
        compositionState.invalidate()
    }

    func installedPackage(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionInstalledPackage? {
        registry.packages.first { $0.extensionID == extensionID }
    }

    func preparedPackageResources(
        extensionID: FloorpWebExtensionID,
        replacementGeneration: String
    ) throws -> PreparedPackageResources {
        guard let update = registry.pendingPackageUpdates[extensionID],
              update.replacementPackage.generation == replacementGeneration,
              let state = preparedResourceStates[extensionID] else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        return .init(
            scriptResourceLoader: { requestedExtensionID, source in
                try state.load(extensionID: requestedExtensionID, source: source)
            },
            pageResourceResolver: .init { request in
                try state.loadData(request)
            }
        )
    }

    /// Atomically publishes an already-activated candidate and clears its
    /// rollback journal. No restart can observe the replacement as committed
    /// unless both changes reached disk in the same registry write.
    func commitPreparedBundledPackageUpdate(
        extensionID: FloorpWebExtensionID,
        replacementGeneration: String
    ) throws {
        guard let update = registry.pendingPackageUpdates[extensionID],
              update.replacementPackage.generation == replacementGeneration,
              let index = registry.packages.firstIndex(where: {
                  $0.extensionID == extensionID
              }),
              registry.packages[index] == update.previousPackage else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        try Self.validateInstalledPackage(
            update.replacementPackage,
            packagesDirectory: packagesDirectory
        )
        var next = registry
        next.packages[index] = update.replacementPackage
        next.packages.sort { $0.extensionID.rawValue < $1.extensionID.rawValue }
        next.pendingPackageUpdates.removeValue(forKey: extensionID)
        try persist(next)
        registry = next
        refreshResourceState()
        // Closures already handed to the activated runtime keep the immutable
        // candidate state alive. Future consumers use the committed loaders.
        preparedResourceStates.removeValue(forKey: extensionID)
        removeGenerationIfPresent(update.previousPackage)
    }

    /// Cancels a prepared update before the active registry has switched. A
    /// crash at this point is equivalent: startup recovery keeps the old
    /// package and removes the candidate.
    func abortPreparedBundledPackageUpdate(
        extensionID: FloorpWebExtensionID,
        replacementGeneration: String
    ) throws {
        guard let update = registry.pendingPackageUpdates[extensionID],
              update.replacementPackage.generation == replacementGeneration,
              registry.packages.contains(where: {
                  $0.extensionID == extensionID && $0 == update.previousPackage
              }) else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        var next = registry
        next.pendingPackageUpdates.removeValue(forKey: extensionID)
        try persist(next)
        registry = next
        preparedResourceStates.removeValue(forKey: extensionID)?.invalidate()
        removeGenerationIfPresent(update.replacementPackage)
    }

    private func removeGenerationIfPresent(
        _ package: FloorpWebExtensionInstalledPackage
    ) {
        let directory = Self.generationDirectory(
            packagesDirectory: packagesDirectory,
            extensionID: package.extensionID,
            generation: package.generation
        )
        try? FileManager.default.removeItem(at: directory)
    }

    func setEnabled(_ enabled: Bool, for extensionID: FloorpWebExtensionID) throws {
        guard registry.pendingPackageUpdates[extensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        var next = registry
        guard let index = next.packages.firstIndex(where: { $0.extensionID == extensionID }) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        next.packages[index].isEnabled = enabled
        // A user-initiated state change clears a prior failed attempt. A
        // subsequent failed activation records a new failure atomically below.
        next.packages[index].activationError = nil
        try persist(next)
        registry = next
        refreshResourceState()
    }

    /// Fails closed after a WebKit policy activation or restoration error.
    /// The disabled state and its Settings-visible explanation are written in
    /// one registry transaction, so a future start cannot claim the package is
    /// enabled while it has no usable runtime policy.
    func recordActivationFailure(
        for extensionID: FloorpWebExtensionID,
        expectedGeneration: String? = nil
    ) throws {
        guard registry.pendingPackageUpdates[extensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        var next = registry
        guard let index = next.packages.firstIndex(where: { $0.extensionID == extensionID }) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        if let expectedGeneration {
            guard next.packages[index].isEnabled,
                  next.packages[index].generation == expectedGeneration else {
                throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
            }
        }
        next.packages[index].isEnabled = false
        next.packages[index].activationError = "This extension could not be activated. Enable it to try again."
        try persist(next)
        registry = next
        refreshResourceState()
    }

    func updateGrants(
        _ grants: FloorpWebExtensionPermissionSnapshot,
        for extensionID: FloorpWebExtensionID,
        expectedGeneration: String
    ) throws {
        guard registry.pendingPackageUpdates[extensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        var next = registry
        guard let index = next.packages.firstIndex(where: { $0.extensionID == extensionID }) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        guard next.packages[index].isEnabled,
              next.packages[index].generation == expectedGeneration else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        next.packages[index].grants = try Self.validatedGrants(
            grants,
            for: next.packages[index].preflight.manifest,
            scope: .durablePermissionUpdate
        )
        try persist(next)
        registry = next
    }

    func dnrConfiguration(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionStoredDNRConfiguration? {
        registry.packages.first { $0.extensionID == extensionID }?.dnrConfiguration
    }

    func updateDNRConfiguration(
        _ configuration: FloorpWebExtensionStoredDNRConfiguration?,
        for extensionID: FloorpWebExtensionID
    ) throws {
        guard registry.pendingPackageUpdates[extensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        var next = registry
        guard let index = next.packages.firstIndex(where: { $0.extensionID == extensionID }) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        if let configuration {
            let manifestRuleIDs = Set(next.packages[index].preflight.manifest.dnrRuleResources.map(\.identifier))
            guard configuration.enabledStaticRuleSetIDs.isSubset(of: manifestRuleIDs) else {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
            try Self.validateStoredDNRConfiguration(configuration)
        }
        next.packages[index].dnrConfiguration = configuration
        try persist(next)
        registry = next
    }

    /// Atomically removes the active package and records a durable cleanup
    /// tombstone. No package files or profile-owned API data are deleted before
    /// this registry commit succeeds, so callers can safely restore live state
    /// if persistence rejects the uninstall.
    func uninstall(_ extensionID: FloorpWebExtensionID) throws {
        guard registry.pendingPackageUpdates[extensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        guard registry.packages.contains(where: { $0.extensionID == extensionID }) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        var next = registry
        next.packages.removeAll { $0.extensionID == extensionID }
        next.pendingDataPurges.insert(extensionID)
        try persist(next)
        registry = next
        refreshResourceState()
    }

    func hasPendingDataPurge(for extensionID: FloorpWebExtensionID) -> Bool {
        registry.pendingDataPurges.contains(extensionID)
    }

    /// Completes the second phase only after every external API store has been
    /// purged. File deletion happens while the tombstone is still durable; a
    /// failure therefore remains visible and retryable after process restart.
    func completeUninstallCleanup(_ extensionID: FloorpWebExtensionID) throws {
        guard registry.pendingDataPurges.contains(extensionID) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        let packageDirectory = packagesDirectory.appendingPathComponent(
            extensionID.rawValue,
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: packageDirectory.path) {
            try FileManager.default.removeItem(at: packageDirectory)
        }
        var next = registry
        next.pendingDataPurges.remove(extensionID)
        try persist(next)
        registry = next
    }

    /// Returns the synchronous loader expected by the coordinator. It shares
    /// a revocable in-memory snapshot with this actor, so an already-installed
    /// coordinator immediately observes disable and uninstall operations.
    nonisolated func makeResourceLoader() -> ResourceLoader {
        let state = resourceState
        return { extensionID, source in
            try state.load(extensionID: extensionID, source: source)
        }
    }

    /// Returns an optional loader because a locale catalog may legitimately
    /// be absent. An inventoried catalog still fails closed on read/UTF-8
    /// errors instead of being misreported as an untranslated message.
    nonisolated func makeI18nResourceLoader() -> FloorpWebExtensionI18n.ResourceLoader {
        let state = resourceState
        return { extensionID, source in
            try state.loadIfPresent(extensionID: extensionID, source: source)
        }
    }

    /// Supplies bytes only for the generation that is still enabled in the
    /// revocable resource-state snapshot. Extension pages must not see a
    /// package update through an old document's opaque origin.
    nonisolated func makePageResourceResolver() -> FloorpWebExtensionPageResourceResolver {
        let state = resourceState
        return .init { request in
            try state.loadData(request)
        }
    }

    private func refreshResourceState() {
        resourceState.replace(with: Self.enabledResourceEntries(
            registry: registry,
            packagesDirectory: packagesDirectory
        ))
    }

    private static func validatedGrants(
        _ proposed: FloorpWebExtensionPermissionSnapshot?,
        for manifest: FloorpWebExtensionManifest,
        scope: GrantValidationScope
    ) throws -> FloorpWebExtensionPermissionSnapshot {
        let requiredHosts = Set(manifest.hostPermissions)
        let allowedAPIPermissions: Set<FloorpWebExtensionAPIGrant>
        let allowedHosts: Set<FloorpWebExtensionMatchPattern>
        switch scope {
        case .initialInstallation:
            allowedAPIPermissions = manifest.apiPermissions
            allowedHosts = requiredHosts
        case .durablePermissionUpdate:
            allowedAPIPermissions = manifest.apiPermissions.union(manifest.optionalAPIPermissions)
            allowedHosts = requiredHosts.union(manifest.optionalHostPermissions)
        }
        guard let proposed else {
            return .init(requestedHosts: requiredHosts)
        }
        guard proposed.apiPermissions.isSubset(of: allowedAPIPermissions),
              // `requestedHosts` is the package's required declaration. An
              // optional origin becomes a durable grant only via a selected
              // host-access set after trusted consent, never by converting an
              // initial `.allRequestedSites` request into optional access.
              proposed.requestedHosts == requiredHosts,
              hostAccess(proposed.normalHostAccess, isSubsetOf: allowedHosts),
              hostAccess(proposed.privateHostAccess, isSubsetOf: allowedHosts),
              proposed.privateBrowsingEnabled || proposed.privateHostAccess == .denied else {
            throw FloorpWebExtensionPackageStoreError.invalidInitialGrants
        }
        return proposed
    }

    /// Produces the non-expanding permission snapshot used by a bundled
    /// package update. Required and optional declarations share one live grant
    /// set, so the safe update rule is intersection with authority that the old
    /// generation actually possessed—not union with the new required set.
    private static func migratedGrants(
        from previousPackage: FloorpWebExtensionInstalledPackage,
        to manifest: FloorpWebExtensionManifest
    ) throws -> FloorpWebExtensionPermissionSnapshot {
        let previous = previousPackage.grants
        let declaredAPIPermissions = manifest.apiPermissions.union(
            manifest.optionalAPIPermissions
        )
        let declaredHosts = Set(manifest.hostPermissions).union(
            manifest.optionalHostPermissions
        )
        let migrated = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: previous.apiPermissions.intersection(declaredAPIPermissions),
            requestedHosts: Set(manifest.hostPermissions),
            normalHostAccess: migratedHostAccess(
                previous.normalHostAccess,
                previousRequestedHosts: previous.requestedHosts,
                newDeclaredHosts: declaredHosts
            ),
            privateHostAccess: previous.privateBrowsingEnabled
                ? migratedHostAccess(
                    previous.privateHostAccess,
                    previousRequestedHosts: previous.requestedHosts,
                    newDeclaredHosts: declaredHosts
                )
                : .denied,
            privateBrowsingEnabled: previous.privateBrowsingEnabled
        )
        return try validatedGrants(
            migrated,
            for: manifest,
            scope: .durablePermissionUpdate
        )
    }

    /// A newly required declaration may cross the update boundary only when
    /// the prior generation already possessed equivalent authority (for
    /// example, an explicitly approved optional permission becoming required).
    /// Otherwise the known-good generation remains active pending a future
    /// trusted consent UI.
    private static func updateRequiresPermissionConsent(
        from previousPackage: FloorpWebExtensionInstalledPackage,
        to manifest: FloorpWebExtensionManifest
    ) -> Bool {
        let previousManifest = previousPackage.preflight.manifest
        let newlyRequiredAPIs = manifest.apiPermissions.subtracting(
            previousManifest.apiPermissions
        )
        if !newlyRequiredAPIs.isSubset(of: previousPackage.grants.apiPermissions) {
            return true
        }

        let priorRequiredHosts = Set(previousManifest.hostPermissions)
        let priorAuthorizedHosts = authorizedHostPatterns(
            previousPackage.grants.normalHostAccess,
            requestedHosts: previousPackage.grants.requestedHosts
        )
        return manifest.hostPermissions.contains { newRequiredHost in
            let wasAlreadyRequired = priorRequiredHosts.contains {
                $0.covers(newRequiredHost)
            }
            let wasAlreadyAuthorized = priorAuthorizedHosts.contains {
                $0.covers(newRequiredHost)
            }
            return !wasAlreadyRequired && !wasAlreadyAuthorized
        }
    }

    private static func authorizedHostPatterns(
        _ access: FloorpWebExtensionHostAccess,
        requestedHosts: Set<FloorpWebExtensionMatchPattern>
    ) -> Set<FloorpWebExtensionMatchPattern> {
        switch access {
        case .denied:
            return []
        case .allRequestedSites:
            return requestedHosts
        case .selectedSites(let selected):
            return selected
        }
    }

    /// Intersects semantic match patterns without broadening them. When the
    /// replacement declaration is narrower, retain that narrower declaration;
    /// when it is broader, retain the old authorized pattern itself.
    private static func migratedHostAccess(
        _ access: FloorpWebExtensionHostAccess,
        previousRequestedHosts: Set<FloorpWebExtensionMatchPattern>,
        newDeclaredHosts: Set<FloorpWebExtensionMatchPattern>
    ) -> FloorpWebExtensionHostAccess {
        let previouslyAuthorized: Set<FloorpWebExtensionMatchPattern>
        let authorized = authorizedHostPatterns(
            access,
            requestedHosts: previousRequestedHosts
        )
        guard !authorized.isEmpty else {
            return .denied
        }
        previouslyAuthorized = authorized

        var retained = Set<FloorpWebExtensionMatchPattern>()
        for oldPattern in previouslyAuthorized {
            for newDeclaration in newDeclaredHosts {
                if newDeclaration.covers(oldPattern) {
                    retained.insert(oldPattern)
                } else if oldPattern.covers(newDeclaration) {
                    retained.insert(newDeclaration)
                }
            }
        }
        return retained.isEmpty ? .denied : .selectedSites(retained)
    }

    private static func hostAccess(
        _ access: FloorpWebExtensionHostAccess,
        isSubsetOf requestedHosts: Set<FloorpWebExtensionMatchPattern>
    ) -> Bool {
        switch access {
        case .denied, .allRequestedSites:
            return true
        case .selectedSites(let selected):
            // A consent UI may select a narrower origin from a wildcard
            // manifest declaration. Require every persisted selection to be
            // covered by a declared pattern, rather than requiring literal
            // pattern equality.
            return selected.allSatisfy { selectedPattern in
                requestedHosts.contains { $0.covers(selectedPattern) }
            }
        }
    }

    private static func resourceSnapshot(at sourceDirectory: URL) throws -> ResourceSnapshot {
        let source = sourceDirectory.standardizedFileURL
        guard source.isFileURL else {
            throw FloorpWebExtensionPackageStoreError.unsafePackageResource(source.path)
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw FloorpWebExtensionPackageStoreError.unsafePackageResource(source.path)
        }

        var resources = [String: Data]()
        var totalBytes = 0
        try collectResources(
            in: source,
            relativePath: "",
            depth: 0,
            resources: &resources,
            totalBytes: &totalBytes
        )
        guard !resources.isEmpty else {
            throw FloorpWebExtensionPackageStoreError.unsafePackageResource("empty package")
        }
        let inventory = FloorpWebExtensionManifestPackageInventory(
            resources: resources.keys.sorted().map {
                .init(path: $0, isRegularFile: true, byteSize: resources[$0]?.count ?? 0)
            }
        )
        return ResourceSnapshot(dataByPath: resources, inventory: inventory)
    }

    private static func collectResources(
        in directory: URL,
        relativePath: String,
        depth: Int,
        resources: inout [String: Data],
        totalBytes: inout Int
    ) throws {
        guard depth <= maximumDirectoryDepth else {
            throw FloorpWebExtensionPackageStoreError.packageQuotaExceeded("directory depth")
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey
            ],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in children {
            let path = relativePath.isEmpty
                ? child.lastPathComponent
                : relativePath + "/" + child.lastPathComponent
            guard (try? FloorpWebExtensionScriptSource(path)) != nil else {
                throw FloorpWebExtensionPackageStoreError.unsafePackageResource(path)
            }
            let before = try child.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey
            ])
            guard before.isSymbolicLink != true else {
                throw FloorpWebExtensionPackageStoreError.unsafePackageResource(path)
            }
            if before.isDirectory == true {
                try collectResources(
                    in: child,
                    relativePath: path,
                    depth: depth + 1,
                    resources: &resources,
                    totalBytes: &totalBytes
                )
                continue
            }
            guard before.isRegularFile == true,
                  let declaredSize = before.fileSize,
                  declaredSize <= FloorpWebExtensionManifest.maximumPackageResourceByteSize else {
                throw FloorpWebExtensionPackageStoreError.unsafePackageResource(path)
            }
            guard resources.count < maximumResourceCount else {
                throw FloorpWebExtensionPackageStoreError.packageQuotaExceeded("resource count")
            }
            let data = try Data(contentsOf: child, options: [.mappedIfSafe])
            let after = try child.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
            ])
            guard after.isRegularFile == true,
                  after.isSymbolicLink != true,
                  declaredSize == data.count,
                  after.fileSize == before.fileSize,
                  after.contentModificationDate == before.contentModificationDate else {
                throw FloorpWebExtensionPackageStoreError.unsafePackageResource(path)
            }
            totalBytes += data.count
            guard totalBytes <= maximumPackageByteSize else {
                throw FloorpWebExtensionPackageStoreError.packageQuotaExceeded("expanded byte size")
            }
            resources[path] = data
        }
    }

    private static func materialize(_ resources: [String: Data], at directory: URL) throws {
        try ensureStoreDirectory(directory)
        for path in resources.keys.sorted() {
            guard let data = resources[path] else { continue }
            let destination = directory.appendingPathComponent(path, isDirectory: false)
            try ensureStoreDirectory(destination.deletingLastPathComponent())
            try data.write(to: destination, options: [.atomic])
        }
    }

    fileprivate static func loadUTF8Resource(_ path: String, from packageDirectory: URL) throws -> String {
        let data = try loadBinaryResource(path, from: packageDirectory)
        guard let string = String(data: data, encoding: .utf8) else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(path)
        }
        return string
    }

    fileprivate static func loadBinaryResource(_ path: String, from packageDirectory: URL) throws -> Data {
        guard let source = try? FloorpWebExtensionScriptSource(path) else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(path)
        }
        let root = packageDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resource = packageDirectory.appendingPathComponent(source.path, isDirectory: false)
        let resolved = resource.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(path)
        }
        let values = try resource.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= FloorpWebExtensionManifest.maximumPackageResourceByteSize else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(path)
        }
        let data = try Data(contentsOf: resource, options: [.mappedIfSafe])
        guard data.count == size else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(path)
        }
        return data
    }

    private static func ensureStoreDirectory(_ directory: URL) throws {
        guard directory.isFileURL else {
            throw FloorpWebExtensionPackageStoreError.invalidStoreDirectory
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw FloorpWebExtensionPackageStoreError.invalidStoreDirectory
        }
    }

    private static func loadRegistry(from url: URL, packagesDirectory: URL) throws -> Registry {
        guard FileManager.default.fileExists(atPath: url.path) else { return Registry() }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= maximumRegistryByteSize else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }
        let registryData: Data
        let decoded: Registry
        do {
            registryData = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard registryData.count == size else {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoded = try decoder.decode(Registry.self, from: registryData)
        } catch {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }
        guard decoded.schemaVersion == Registry.currentSchemaVersion,
              Set(decoded.packages.map(\.extensionID)).count == decoded.packages.count,
              decoded.pendingDataPurges.isDisjoint(with: decoded.packages.map(\.extensionID)),
              decoded.pendingDataPurges.isDisjoint(with: decoded.pendingPackageUpdates.keys),
              Set(decoded.pendingPackageUpdates.keys).isSubset(of: decoded.packages.map(\.extensionID)) else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }
        do {
            for package in decoded.packages {
                try validateInstalledPackage(package, packagesDirectory: packagesDirectory)
            }
            for (extensionID, update) in decoded.pendingPackageUpdates {
                guard update.previousPackage.extensionID == extensionID,
                      update.replacementPackage.extensionID == extensionID,
                      update.previousPackage.generation != update.replacementPackage.generation,
                      isSafeGeneration(update.replacementPackage.generation),
                      let active = decoded.packages.first(where: {
                          $0.extensionID == extensionID
                      }),
                      active == update.previousPackage else {
                    throw FloorpWebExtensionPackageStoreError.corruptedRegistry
                }
                try validateInstalledPackage(
                    update.previousPackage,
                    packagesDirectory: packagesDirectory
                )
                // The replacement is the uncommitted side of a rollback
                // journal. A process or power failure may leave its directory
                // missing or partially durable even though the atomic journal
                // write reached disk. Do not require candidate bytes in order
                // to recover the independently verified active generation.
                // Its generation still has to be path-safe because init uses
                // that value to remove the rejected directory after clearing
                // the journal.
            }
        } catch {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }
        return decoded
    }

    /// A registry is an index, not an authority. Rebuild every security-
    /// relevant value from the immutable generation before exposing any
    /// package or resource loader after a process restart.
    private static func validateInstalledPackage(
        _ package: FloorpWebExtensionInstalledPackage,
        packagesDirectory: URL
    ) throws {
        guard isSafeGeneration(package.generation),
              package.extensionID == package.fixture.extensionID,
              package.packageSHA256 == package.fixture.packageSHA256,
              package.resourcePaths.contains("manifest.json"),
              package.resourcePaths.allSatisfy({ (try? FloorpWebExtensionScriptSource($0)) != nil }) else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }

        let generationDirectory = try validatedGenerationDirectory(
            packagesDirectory: packagesDirectory,
            extensionID: package.extensionID,
            generation: package.generation
        )
        let resources = try resourceSnapshot(at: generationDirectory)
        guard Set(resources.dataByPath.keys) == package.resourcePaths,
              let manifestData = resources.dataByPath["manifest.json"],
              manifestData == package.rawManifest else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }

        let fixtureMetadata = try FloorpWebExtensionCompatibilityHarness.verifyFixturePackage(
            at: generationDirectory
        )
        guard fixtureMetadata.fixture == package.fixture,
              fixtureMetadata.fixture.extensionID == package.extensionID,
              fixtureMetadata.fixture.version == package.version,
              fixtureMetadata.fixture.packageSHA256 == package.packageSHA256 else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }

        let preflight = try FloorpWebExtensionManifest.preflight(
            manifestData: manifestData,
            packageInventory: resources.inventory,
            ruleResourceData: resources.dataByPath
        )
        guard preflight.isActivationAllowed,
              preflight == package.preflight,
              preflight.manifest.name == package.name,
              preflight.manifest.version == package.version,
              try validatedGrants(
                  package.grants,
                  for: preflight.manifest,
                  scope: .durablePermissionUpdate
              ) == package.grants else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }

        if let dnrConfiguration = package.dnrConfiguration {
            let manifestRuleIDs = Set(preflight.manifest.dnrRuleResources.map(\.identifier))
            guard dnrConfiguration.enabledStaticRuleSetIDs.isSubset(of: manifestRuleIDs) else {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
            try validateStoredDNRConfiguration(dnrConfiguration)
        }
    }

    private static func validatedGenerationDirectory(
        packagesDirectory: URL,
        extensionID: FloorpWebExtensionID,
        generation: String
    ) throws -> URL {
        let extensionDirectory = packagesDirectory.appendingPathComponent(
            extensionID.rawValue,
            isDirectory: true
        )
        let generationDirectory = generationDirectory(
            packagesDirectory: packagesDirectory,
            extensionID: extensionID,
            generation: generation
        )
        let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let extensionValues = try extensionDirectory.resourceValues(forKeys: directoryKeys)
        let generationValues = try generationDirectory.resourceValues(forKeys: directoryKeys)
        guard extensionValues.isDirectory == true,
              extensionValues.isSymbolicLink != true,
              generationValues.isDirectory == true,
              generationValues.isSymbolicLink != true else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }

        let resolvedPackages = packagesDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedExtension = extensionDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedGeneration = generationDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedExtension.deletingLastPathComponent() == resolvedPackages,
              resolvedExtension.lastPathComponent == extensionID.rawValue,
              resolvedGeneration.deletingLastPathComponent() == resolvedExtension,
              resolvedGeneration.lastPathComponent == generation else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }
        return generationDirectory
    }

    private static func validateStoredDNRConfiguration(
        _ configuration: FloorpWebExtensionStoredDNRConfiguration
    ) throws {
        try FloorpWebExtensionDNRStore.validateStoredConfiguration(configuration)
    }

    private static func encodedRegistryData(_ registry: Registry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(registry)
        guard data.count <= maximumRegistryByteSize else {
            throw FloorpWebExtensionPackageStoreError.packageQuotaExceeded("registry size")
        }
        return data
    }

    private func persist(_ registry: Registry) throws {
        let data = try Self.encodedRegistryData(registry)
        try compositionState.performIfCurrent {
            try registryPersister(data, registryURL)
        }
    }

    private static func enabledResourceEntries(
        registry: Registry,
        packagesDirectory: URL
    ) -> [FloorpWebExtensionID: FloorpWebExtensionPackageResourceState.Entry] {
        Dictionary(uniqueKeysWithValues: registry.packages.compactMap { package in
            guard package.isEnabled else { return nil }
            return (
                package.extensionID,
                .init(
                    packageDirectory: generationDirectory(
                        packagesDirectory: packagesDirectory,
                        extensionID: package.extensionID,
                        generation: package.generation
                    ),
                    generation: package.generation,
                    resourcePaths: package.resourcePaths
                )
            )
        })
    }

    private static func generationDirectory(
        packagesDirectory: URL,
        extensionID: FloorpWebExtensionID,
        generation: String
    ) -> URL {
        packagesDirectory
            .appendingPathComponent(extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(generation, isDirectory: true)
    }

    private static func isSafeGeneration(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }
}

/// Profile composition installs stores here for Settings and runtime assembly.
/// The browsing-mode key prevents an ephemeral private store from being
/// returned to a normal coordinator (or vice versa).
@MainActor
enum FloorpWebExtensionPackageStoreRegistry {
    private static var stores = [FloorpWebExtensionPackageProfileKey: FloorpWebExtensionPackageStore]()
    private static var managers = [FloorpWebExtensionPackageProfileKey: FloorpWebExtensionLivePackageManager]()

    static func install(
        _ store: FloorpWebExtensionPackageStore,
        manager: FloorpWebExtensionLivePackageManager
    ) {
        if let previous = stores[store.profileKey], previous !== store {
            previous.invalidateComposition()
        }
        stores[store.profileKey] = store
        managers[store.profileKey] = manager
    }

    static func invalidateStore(for profileIdentifier: String, isPrivateBrowsing: Bool) {
        stores[.init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )]?.invalidateComposition()
    }

    static func store(
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) -> FloorpWebExtensionPackageStore? {
        stores[.init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )]
    }

    static func manager(
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) -> FloorpWebExtensionLivePackageManager? {
        managers[.init(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )]
    }

    static func removeStore(for profileIdentifier: String, isPrivateBrowsing: Bool) {
        let key = FloorpWebExtensionPackageProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        stores.removeValue(forKey: key)?.invalidateComposition()
        managers.removeValue(forKey: key)
    }
}
