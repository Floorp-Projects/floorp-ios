// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

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
    case immutableGenerationConflict(FloorpWebExtensionID)
    case invalidCatalogArtifact
    case catalogGenerationRevoked(FloorpWebExtensionID)

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
        case .immutableGenerationConflict(let extensionID):
            return "The immutable package generation conflicts with the installed extension: \(extensionID.rawValue)"
        case .invalidCatalogArtifact:
            return "The verified catalog artifact cannot be installed."
        case .catalogGenerationRevoked(let extensionID):
            return "The signed catalog revoked this extension generation: \(extensionID.rawValue)"
        }
    }
}

private final class FloorpWebExtensionPackageCompositionState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCurrent = true

    @discardableResult
    func invalidate() -> Bool {
        lock.lock()
        let wasCurrent = isCurrent
        isCurrent = false
        lock.unlock()
        return wasCurrent
    }

    func reactivate() {
        lock.lock()
        isCurrent = true
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

private final class FloorpWebExtensionPackageRegistrySnapshotState: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func replace(with data: Data?) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func matches(_ candidate: Data?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data == candidate
    }
}

/// Durable, non-user-overridable evidence that a signed catalog kill switch
/// stopped this exact immutable generation. The package bytes and owned data
/// may remain until policy-approved uninstall, but the generation can never
/// be re-enabled through the ordinary Settings lifecycle.
struct FloorpWebExtensionCatalogPackageRevocation: Codable, Equatable, Sendable {
    let catalogGeneration: String
}

/// The authority delta between two immutable catalog generations.  This is
/// computed from the replacement manifest and the authority actually granted
/// to the installed profile, rather than trusting display metadata supplied by
/// a catalog service. The native update-confirmation UI always displays this
/// delta, including the empty-delta case.
struct FloorpWebExtensionCatalogPermissionDelta: Equatable, Sendable {
    let addedRequiredAPIPermissions: [FloorpWebExtensionAPIGrant]
    let addedRequiredHostPermissions: [FloorpWebExtensionMatchPattern]

    var addsAuthority: Bool {
        !addedRequiredAPIPermissions.isEmpty || !addedRequiredHostPermissions.isEmpty
    }
}

/// Durable, profile-local evidence of an immutable catalog replacement.  It
/// gives Settings an audit trail without retaining executable bytes from a
/// retired generation.  History is removed with the package during uninstall.
struct FloorpWebExtensionCatalogUpdateHistoryEntry: Codable, Equatable, Hashable, Sendable {
    enum Method: String, Codable, Hashable, Sendable {
        /// A product-owned native UI displayed the replacement identity,
        /// concrete authority delta, and exact replacement digest.
        case userApproved
    }

    let extensionID: FloorpWebExtensionID
    let previousCatalogGeneration: String
    let replacementCatalogGeneration: String
    let previousVersion: String
    let replacementVersion: String
    let replacementArtifactSHA256: String
    let method: Method
    let occurredAt: Date
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
    /// Exactly one provenance record is present. Bundled fixtures retain their
    /// existing pinned verification; managed catalog generations retain the
    /// signed record's immutable artifact digests.
    let fixture: FloorpWebExtensionFixture?
    let catalogRecord: FloorpWebExtensionCatalogPackageRecord?
    let packageSHA256: String
    let installedAt: Date
    let rawManifest: Data
    let preflight: FloorpWebExtensionManifestPreflightReport
    let resourcePaths: Set<String>
    var isEnabled: Bool
    var grants: FloorpWebExtensionPermissionSnapshot
    var dnrConfiguration: FloorpWebExtensionStoredDNRConfiguration?
    /// Dynamic `scripting.registerContentScripts` entries that explicitly
    /// opted into persistence. An optional backing value keeps previously
    /// written package registries decodable; missing means no registrations.
    var persistentRegisteredScripts: [FloorpWebExtensionRegisteredScript]?
    /// A product-owned explanation for a fail-closed activation disable. This
    /// keeps a runtime activation failure distinct from a deliberate user
    /// disable after process restart.
    var activationError: String?
    /// Unlike `activationError`, this is a durable signed kill-switch state
    /// and is not cleared by a user enable attempt.
    var catalogRevocation: FloorpWebExtensionCatalogPackageRevocation?

    /// The optional catalog provenance defaults to `nil` solely for existing
    /// bundled-fixture construction. Catalog installation calls pass the
    /// verified record explicitly; no decoded or default path can invent one.
    init(
        extensionID: FloorpWebExtensionID,
        generation: String,
        name: String,
        version: String,
        fixture: FloorpWebExtensionFixture?,
        catalogRecord: FloorpWebExtensionCatalogPackageRecord? = nil,
        packageSHA256: String,
        installedAt: Date,
        rawManifest: Data,
        preflight: FloorpWebExtensionManifestPreflightReport,
        resourcePaths: Set<String>,
        isEnabled: Bool,
        grants: FloorpWebExtensionPermissionSnapshot,
        dnrConfiguration: FloorpWebExtensionStoredDNRConfiguration? = nil,
        persistentRegisteredScripts: [FloorpWebExtensionRegisteredScript]? = nil,
        activationError: String? = nil,
        catalogRevocation: FloorpWebExtensionCatalogPackageRevocation? = nil
    ) {
        self.extensionID = extensionID
        self.generation = generation
        self.name = name
        self.version = version
        self.fixture = fixture
        self.catalogRecord = catalogRecord
        self.packageSHA256 = packageSHA256
        self.installedAt = installedAt
        self.rawManifest = rawManifest
        self.preflight = preflight
        self.resourcePaths = resourcePaths
        self.isEnabled = isEnabled
        self.grants = grants
        self.dnrConfiguration = dnrConfiguration
        self.persistentRegisteredScripts = persistentRegisteredScripts
        self.activationError = activationError
        self.catalogRevocation = catalogRevocation
    }

    var registeredPersistentScripts: [FloorpWebExtensionRegisteredScript] {
        persistentRegisteredScripts ?? []
    }

    var isCatalogRevoked: Bool {
        catalogRevocation != nil
    }
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
    /// The clock is injected so a catalog authorization can be enforced at
    /// the actor-isolated persistence boundary, rather than only before an
    /// async lifecycle operation starts.
    typealias Clock = @Sendable () -> Date

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
        /// Present only for signed-catalog replacements.  Optional decoding
        /// preserves crash recovery for registries written before update
        /// history was introduced.
        let catalogUpdateHistoryEntry: FloorpWebExtensionCatalogUpdateHistoryEntry?

        private enum CodingKeys: String, CodingKey {
            case previousPackage
            case replacementPackage
            case catalogUpdateHistoryEntry
        }

        init(
            previousPackage: FloorpWebExtensionInstalledPackage,
            replacementPackage: FloorpWebExtensionInstalledPackage,
            catalogUpdateHistoryEntry: FloorpWebExtensionCatalogUpdateHistoryEntry? = nil
        ) {
            self.previousPackage = previousPackage
            self.replacementPackage = replacementPackage
            self.catalogUpdateHistoryEntry = catalogUpdateHistoryEntry
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            previousPackage = try container.decode(
                FloorpWebExtensionInstalledPackage.self,
                forKey: .previousPackage
            )
            replacementPackage = try container.decode(
                FloorpWebExtensionInstalledPackage.self,
                forKey: .replacementPackage
            )
            catalogUpdateHistoryEntry = try container.decodeIfPresent(
                FloorpWebExtensionCatalogUpdateHistoryEntry.self,
                forKey: .catalogUpdateHistoryEntry
            )
        }
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
        /// Bounded audit history for committed catalog replacements.  It is
        /// metadata only; package removal removes these entries too.
        var catalogUpdateHistory: [FloorpWebExtensionCatalogUpdateHistoryEntry]

        init(packages: [FloorpWebExtensionInstalledPackage] = []) {
            schemaVersion = Self.currentSchemaVersion
            self.packages = packages
            pendingDataPurges = []
            pendingPackageUpdates = [:]
            catalogUpdateHistory = []
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case packages
            case pendingDataPurges
            case pendingPackageUpdates
            case catalogUpdateHistory
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
            catalogUpdateHistory = try container.decodeIfPresent(
                [FloorpWebExtensionCatalogUpdateHistoryEntry].self,
                forKey: .catalogUpdateHistory
            ) ?? []
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
    static let maximumCatalogUpdateHistoryEntries = 128

    nonisolated let profileKey: FloorpWebExtensionPackageProfileKey
    private let directory: URL
    private let packagesDirectory: URL
    private let stagingDirectory: URL
    nonisolated private let registryURL: URL
    private let registryPersister: RegistryPersister
    private let clock: Clock
    private let resourceState = FloorpWebExtensionPackageResourceState()
    private let compositionState = FloorpWebExtensionPackageCompositionState()
    nonisolated private let durableSnapshotState = FloorpWebExtensionPackageRegistrySnapshotState()
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
        },
        clock: @escaping Clock = { Date() }
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
        self.clock = clock

        try Self.ensureStoreDirectory(self.directory)
        try Self.ensureStoreDirectory(packagesDirectory)
        try Self.ensureStoreDirectory(stagingDirectory)
        let loadedRegistry = try Self.loadRegistry(
            from: registryURL,
            packagesDirectory: packagesDirectory
        )
        registry = loadedRegistry.registry
        var durableSnapshotData = loadedRegistry.data
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
            durableSnapshotData = data

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
        durableSnapshotState.replace(with: durableSnapshotData)
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
                try? abortPreparedBundledPackageUpdate(
                    extensionID: expectedExtensionID,
                    replacementGeneration: transaction.installedPackage.generation
                )
                throw error
            }
        }
        return transaction.installedPackage
    }

    // swiftlint:disable function_body_length
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
               Self.catalogPermissionDelta(
                   from: previousPackage,
                   to: preflight.manifest,
                   isPrivateBrowsing: profileKey.isPrivateBrowsing
               ).addsAuthority {
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
            let existingPersistentScripts = registry.packages.first {
                $0.extensionID == expectedExtensionID
            }?.registeredPersistentScripts ?? []
            try Self.validatePersistentRegisteredScripts(
                existingPersistentScripts,
                for: preflight.manifest,
                resourcePaths: Set(resources.dataByPath.keys)
            )
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
                catalogRecord: nil,
                packageSHA256: fixtureMetadata.fixture.packageSHA256,
                installedAt: Date(),
                rawManifest: manifestData,
                preflight: preflight,
                resourcePaths: Set(resources.dataByPath.keys),
                isEnabled: previousPackage?.isEnabled ?? true,
                grants: grants,
                dnrConfiguration: existingDNRConfiguration,
                persistentRegisteredScripts: existingPersistentScripts,
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
    // swiftlint:enable function_body_length

    // swiftlint:disable function_body_length
    /// Stages bytes that were already bound to one verified `catalog-v1`
    /// record. This accepts no path, URL, ZIP, CRX, or caller-provided
    /// archive: only the resource map emitted by the signed-artifact decoder.
    func installVerifiedCatalogPackageTransaction(
        _ artifact: FloorpWebExtensionVerifiedCatalogArtifact,
        initialGrants: FloorpWebExtensionPermissionSnapshot? = nil,
        updateConsent: FloorpWebExtensionCatalogUpdateConsent? = nil,
        catalogExpiresAt: Date? = nil
    ) throws -> BundledPackageInstallationTransaction {
        try requireCatalogNotExpired(catalogExpiresAt)
        let record = artifact.record
        guard record.availability == .available || record.availability == .updateAvailable else {
            throw FloorpWebExtensionCatalogError.revoked
        }
        guard !registry.pendingDataPurges.contains(record.extensionID),
              registry.pendingPackageUpdates[record.extensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.resourceUnavailable(
                "package transaction pending for \(record.extensionID.rawValue)"
            )
        }
        let resourcePaths = Set(artifact.resources.keys)
        let reconstructedArtifact: Data
        do {
            reconstructedArtifact = try FloorpWebExtensionCatalogArchive.encodedArtifact(
                resources: artifact.resources
            )
        } catch {
            throw FloorpWebExtensionPackageStoreError.invalidCatalogArtifact
        }
        guard resourcePaths.count == artifact.resources.count,
              resourcePaths.contains("manifest.json"),
              resourcePaths.allSatisfy({ (try? FloorpWebExtensionScriptSource($0)) != nil }),
              artifact.resources.values.allSatisfy({
                  $0.count <= FloorpWebExtensionManifest.maximumPackageResourceByteSize
              }),
              artifact.resources.values.reduce(0, { $0 + $1.count }) <= Self.maximumPackageByteSize,
              FloorpWebExtensionArtifactDownloader.sha256(reconstructedArtifact) == record.artifactSHA256 else {
            throw FloorpWebExtensionPackageStoreError.invalidCatalogArtifact
        }
        do {
            // The downloader normally performed this check already. Repeating
            // it here makes the package-store boundary independently reject a
            // forged in-memory "verified" value or a corrupted durable
            // catalog record before any resource is materialized.
            _ = try FloorpWebExtensionCatalogArchive.decode(
                reconstructedArtifact,
                record: record
            )
        } catch {
            throw FloorpWebExtensionPackageStoreError.invalidCatalogArtifact
        }
        let resources = ResourceSnapshot(
            dataByPath: artifact.resources,
            inventory: .init(resources: resourcePaths.sorted().map {
                .init(path: $0, isRegularFile: true, byteSize: artifact.resources[$0]?.count ?? 0)
            })
        )
        let transactionID = UUID().uuidString.lowercased()
        let stagedPackage = stagingDirectory.appendingPathComponent(transactionID, isDirectory: true)
        let generation = record.localGeneration

        do {
            try Self.materialize(resources.dataByPath, at: stagedPackage)
            guard let manifestData = resources.dataByPath["manifest.json"] else {
                throw FloorpWebExtensionPackageStoreError.invalidCatalogArtifact
            }
            let preflight = try FloorpWebExtensionManifest.preflight(
                manifestData: manifestData,
                packageInventory: resources.inventory,
                ruleResourceData: resources.dataByPath
            )
            guard preflight.isActivationAllowed,
                  preflight.manifest.version == record.version else {
                throw FloorpWebExtensionPackageStoreError.invalidCatalogArtifact
            }
            try FloorpWebExtensionManifest.validateCuratedCatalogDNRRules(
                manifest: preflight.manifest,
                ruleResourceData: resources.dataByPath
            )
            try Self.validateCatalogCompatibilityProfiles(
                record.compatibilityProfiles,
                manifest: preflight.manifest
            )
            let previousPackage = registry.packages.first {
                $0.extensionID == record.extensionID
            }
            if let previousCatalogRecord = previousPackage?.catalogRecord,
               previousCatalogRecord.generation == record.generation {
                throw FloorpWebExtensionPackageStoreError.immutableGenerationConflict(record.extensionID)
            }
            let catalogUpdateHistoryEntry: FloorpWebExtensionCatalogUpdateHistoryEntry?
            if let previousPackage {
                // A package from any non-catalog source can never be silently
                // replaced by a catalog record.  This preserves the origin
                // boundary even when the replacement itself is validly signed.
                guard let previousCatalogRecord = previousPackage.catalogRecord else {
                    throw FloorpWebExtensionCatalogError.updateConsentRequired
                }
                guard FloorpWebExtensionCatalogVerifier.semanticVersionIsStrictlyGreater(
                    record.version,
                    than: previousPackage.version
                ) else {
                    throw FloorpWebExtensionCatalogError.artifactRejected(
                        "catalog replacement version must be strictly newer than the installed version"
                    )
                }
                guard let updateConsent,
                      Self.matches(
                          updateConsent,
                          previousPackage: previousPackage,
                          replacementRecord: record
                      ) else {
                    // The old immutable generation remains committed and
                    // runnable until the product-owned native consent path
                    // approves this exact replacement digest.
                    throw FloorpWebExtensionCatalogError.updateConsentRequired
                }
                catalogUpdateHistoryEntry = .init(
                    extensionID: record.extensionID,
                    previousCatalogGeneration: previousCatalogRecord.generation,
                    replacementCatalogGeneration: record.generation,
                    previousVersion: previousPackage.version,
                    replacementVersion: record.version,
                    replacementArtifactSHA256: record.artifactSHA256,
                    method: .userApproved,
                    occurredAt: Date()
                )
            } else {
                catalogUpdateHistoryEntry = nil
            }
            if let previousPackage,
               previousPackage.generation == generation {
                throw FloorpWebExtensionPackageStoreError.immutableGenerationConflict(record.extensionID)
            }
            let grants = if let previousPackage {
                try Self.migratedGrants(from: previousPackage, to: preflight.manifest)
            } else {
                try Self.validatedGrants(
                    initialGrants,
                    for: preflight.manifest,
                    scope: .initialInstallation
                )
            }
            let generationDirectory = Self.generationDirectory(
                packagesDirectory: packagesDirectory,
                extensionID: record.extensionID,
                generation: generation
            )
            let existingDNRConfiguration = previousPackage?.dnrConfiguration
            if let existingDNRConfiguration {
                let manifestRuleIDs = Set(preflight.manifest.dnrRuleResources.map(\.identifier))
                guard existingDNRConfiguration.enabledStaticRuleSetIDs.isSubset(of: manifestRuleIDs) else {
                    throw FloorpWebExtensionPackageStoreError.corruptedRegistry
                }
                try Self.validateStoredDNRConfiguration(existingDNRConfiguration)
            }
            let existingPersistentScripts = previousPackage?.registeredPersistentScripts ?? []
            try Self.validatePersistentRegisteredScripts(
                existingPersistentScripts,
                for: preflight.manifest,
                resourcePaths: resourcePaths
            )
            try Self.ensureStoreDirectory(generationDirectory.deletingLastPathComponent())
            guard !FileManager.default.fileExists(atPath: generationDirectory.path) else {
                throw FloorpWebExtensionPackageStoreError.immutableGenerationConflict(record.extensionID)
            }
            // Staging is not executable. Recheck before moving it into the
            // immutable package area, then again immediately before the
            // registry commit below so a long preflight cannot cross expiry.
            try requireCatalogNotExpired(catalogExpiresAt)
            try FileManager.default.moveItem(at: stagedPackage, to: generationDirectory)
            let installed = FloorpWebExtensionInstalledPackage(
                extensionID: record.extensionID,
                generation: generation,
                name: preflight.manifest.name,
                version: preflight.manifest.version,
                fixture: nil,
                catalogRecord: record,
                packageSHA256: record.artifactSHA256,
                installedAt: Date(),
                rawManifest: manifestData,
                preflight: preflight,
                resourcePaths: resourcePaths,
                isEnabled: previousPackage?.isEnabled ?? true,
                grants: grants,
                dnrConfiguration: existingDNRConfiguration,
                persistentRegisteredScripts: existingPersistentScripts,
                activationError: previousPackage?.activationError
            )
            var next = registry
            if let previousPackage {
                next.pendingPackageUpdates[record.extensionID] = .init(
                    previousPackage: previousPackage,
                    replacementPackage: installed,
                    catalogUpdateHistoryEntry: catalogUpdateHistoryEntry
                )
            } else {
                next.packages.append(installed)
                next.packages.sort { $0.extensionID.rawValue < $1.extensionID.rawValue }
            }
            do {
                try requireCatalogNotExpired(catalogExpiresAt)
                try persist(next)
            } catch {
                try? FileManager.default.removeItem(at: generationDirectory)
                throw error
            }
            registry = next
            if previousPackage == nil {
                refreshResourceState()
            } else {
                preparedResourceStates[record.extensionID] = .init(
                    package: installed,
                    packagesDirectory: packagesDirectory
                )
            }
            return .init(installedPackage: installed, previousPackage: previousPackage)
        } catch {
            try? FileManager.default.removeItem(at: stagedPackage)
            throw error
        }
    }
    // swiftlint:enable function_body_length

    func installedPackages() -> [FloorpWebExtensionInstalledPackage] {
        registry.packages
    }

    @discardableResult
    nonisolated func invalidateComposition() -> Bool {
        compositionState.invalidate()
    }

    nonisolated func reactivateComposition() {
        compositionState.reactivate()
    }

    func installedPackage(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionInstalledPackage? {
        registry.packages.first { $0.extensionID == extensionID }
    }

    /// Returns the concrete authority change a replacement would introduce in
    /// this profile.  This is a presentation helper only: the transaction
    /// below repeats the decision after full FWEA1 reconstruction before it
    /// changes any durable state.
    func catalogUpdatePermissionDelta(
        for artifact: FloorpWebExtensionVerifiedCatalogArtifact
    ) throws -> FloorpWebExtensionCatalogPermissionDelta? {
        let record = artifact.record
        guard record.availability == .available || record.availability == .updateAvailable else {
            throw FloorpWebExtensionCatalogError.revoked
        }
        guard let previousPackage = registry.packages.first(where: {
            $0.extensionID == record.extensionID
        }) else {
            return nil
        }
        guard previousPackage.catalogRecord != nil else {
            throw FloorpWebExtensionCatalogError.updateConsentRequired
        }
        let manifest = try Self.catalogManifest(from: artifact)
        return Self.catalogPermissionDelta(
            from: previousPackage,
            to: manifest,
            isPrivateBrowsing: profileKey.isPrivateBrowsing
        )
    }

    /// A signed catalog authenticates bytes but never authorizes a replacement
    /// by itself. Every existing immutable catalog package requires one
    /// product-owned, digest-bound native confirmation before it can change.
    func catalogUpdateRequiresExplicitConsent(
        for artifact: FloorpWebExtensionVerifiedCatalogArtifact
    ) throws -> Bool {
        try catalogUpdatePermissionDelta(for: artifact) != nil
    }

    func catalogUpdateHistory(
        for extensionID: FloorpWebExtensionID
    ) -> [FloorpWebExtensionCatalogUpdateHistoryEntry] {
        registry.catalogUpdateHistory.filter { $0.extensionID == extensionID }
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
        replacementGeneration: String,
        catalogExpiresAt: Date? = nil
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
        if let historyEntry = update.catalogUpdateHistoryEntry {
            next.catalogUpdateHistory.append(historyEntry)
            if next.catalogUpdateHistory.count > Self.maximumCatalogUpdateHistoryEntries {
                next.catalogUpdateHistory.removeFirst(
                    next.catalogUpdateHistory.count - Self.maximumCatalogUpdateHistoryEntries
                )
            }
        }
        try requireCatalogNotExpired(catalogExpiresAt)
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

    func setEnabled(
        _ enabled: Bool,
        for extensionID: FloorpWebExtensionID,
        catalogExpiresAt: Date? = nil
    ) throws {
        guard registry.pendingPackageUpdates[extensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        var next = registry
        guard let index = next.packages.firstIndex(where: { $0.extensionID == extensionID }) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        guard !enabled || next.packages[index].catalogRevocation == nil else {
            throw FloorpWebExtensionPackageStoreError.catalogGenerationRevoked(extensionID)
        }
        next.packages[index].isEnabled = enabled
        // A user-initiated state change clears a prior failed attempt. A
        // subsequent failed activation records a new failure atomically below.
        next.packages[index].activationError = nil
        if enabled {
            try requireCatalogNotExpired(catalogExpiresAt)
        }
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

    /// A signed generation revocation never swaps in another package. Runtime
    /// ownership is revoked by the lifecycle manager before this durable
    /// transition; package-owned storage is retained until the P0-approved
    /// policy explicitly requests an uninstall.
    func recordCatalogRevocation(
        for extensionID: FloorpWebExtensionID,
        catalogGeneration: String
    ) throws {
        guard registry.pendingPackageUpdates[extensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        var next = registry
        guard let index = next.packages.firstIndex(where: { $0.extensionID == extensionID }),
              let catalogRecord = next.packages[index].catalogRecord,
              catalogRecord.generation == catalogGeneration else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        next.packages[index].isEnabled = false
        next.packages[index].activationError = "This extension generation was revoked and has been stopped."
        next.packages[index].catalogRevocation = .init(catalogGeneration: catalogGeneration)
        try persist(next)
        registry = next
        refreshResourceState()
    }

    func updateGrants(
        _ grants: FloorpWebExtensionPermissionSnapshot,
        for extensionID: FloorpWebExtensionID,
        expectedGeneration: String,
        catalogExpiresAt: Date? = nil
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
        try requireCatalogNotExpired(catalogExpiresAt)
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

    /// Replaces the durable subset of dynamically registered content scripts.
    /// The caller supplies the complete live registry snapshot; only entries
    /// explicitly marked `persistAcrossSessions` reach this API. A package
    /// generation comparison prevents an old coordinator from committing a
    /// registration after update, disable, or uninstall has superseded it.
    func updatePersistentRegisteredScripts(
        _ scripts: [FloorpWebExtensionRegisteredScript],
        for extensionID: FloorpWebExtensionID,
        expectedGeneration: String,
        expectedCurrentScripts: [FloorpWebExtensionRegisteredScript]? = nil
    ) throws {
        guard registry.pendingPackageUpdates[extensionID] == nil else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        var next = registry
        guard let index = next.packages.firstIndex(where: { $0.extensionID == extensionID }),
              next.packages[index].isEnabled,
              next.packages[index].generation == expectedGeneration else {
            throw FloorpWebExtensionPackageStoreError.inactivePackageGeneration(extensionID)
        }
        if let expectedCurrentScripts,
           next.packages[index].registeredPersistentScripts != expectedCurrentScripts {
            throw FloorpWebExtensionPackageStoreError.stalePackageComposition
        }
        try Self.validatePersistentRegisteredScripts(
            scripts,
            for: next.packages[index].preflight.manifest,
            resourcePaths: next.packages[index].resourcePaths
        )
        next.packages[index].persistentRegisteredScripts = scripts
        try persist(next)
        registry = next
    }

    nonisolated func validateDurableSnapshotForCompositionInstall() throws {
        let currentData = try Self.registrySnapshotData(at: registryURL)
        guard durableSnapshotState.matches(currentData) else {
            throw FloorpWebExtensionPackageStoreError.stalePackageComposition
        }
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
        next.catalogUpdateHistory.removeAll { $0.extensionID == extensionID }
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

    private static func catalogManifest(
        from artifact: FloorpWebExtensionVerifiedCatalogArtifact
    ) throws -> FloorpWebExtensionManifest {
        guard let manifestData = artifact.resources["manifest.json"] else {
            throw FloorpWebExtensionPackageStoreError.invalidCatalogArtifact
        }
        let manifest: FloorpWebExtensionManifest
        do {
            manifest = try FloorpWebExtensionManifest.decode(manifestData)
        } catch {
            throw FloorpWebExtensionPackageStoreError.invalidCatalogArtifact
        }
        guard manifest.version == artifact.record.version else {
            throw FloorpWebExtensionPackageStoreError.invalidCatalogArtifact
        }
        return manifest
    }

    private static func matches(
        _ consent: FloorpWebExtensionCatalogUpdateConsent,
        previousPackage: FloorpWebExtensionInstalledPackage,
        replacementRecord: FloorpWebExtensionCatalogPackageRecord
    ) -> Bool {
        consent.extensionID == replacementRecord.extensionID &&
            consent.installedGeneration == previousPackage.generation &&
            consent.replacementCatalogGeneration == replacementRecord.generation &&
            consent.replacementArtifactSHA256 == replacementRecord.artifactSHA256
    }

    /// Identifies only authority that the replacement would newly require in
    /// the current profile.  A prior optional permission can become required
    /// without another prompt if it was already granted; a broad prior host
    /// grant can likewise cover a narrower new host.  This is deliberately
    /// semantic containment, not string comparison, so `<all_urls>` and
    /// wildcard patterns cannot be misclassified as a harmless expansion.
    private static func catalogPermissionDelta(
        from previousPackage: FloorpWebExtensionInstalledPackage,
        to manifest: FloorpWebExtensionManifest,
        isPrivateBrowsing: Bool
    ) -> FloorpWebExtensionCatalogPermissionDelta {
        let previousManifest = previousPackage.preflight.manifest
        let addedRequiredAPIPermissions = manifest.apiPermissions.subtracting(
            previousManifest.apiPermissions
        ).subtracting(previousPackage.grants.apiPermissions)

        let priorRequiredHosts = Set(previousManifest.hostPermissions)
        let priorAuthorizedHosts = authorizedHostPatterns(
            isPrivateBrowsing
                ? previousPackage.grants.privateHostAccess
                : previousPackage.grants.normalHostAccess,
            requestedHosts: previousPackage.grants.requestedHosts
        )
        let addedRequiredHostPermissions = manifest.hostPermissions.filter { newRequiredHost in
            let wasAlreadyRequired = priorRequiredHosts.contains {
                $0.covers(newRequiredHost)
            }
            let wasAlreadyAuthorized = priorAuthorizedHosts.contains {
                $0.covers(newRequiredHost)
            }
            return !wasAlreadyRequired && !wasAlreadyAuthorized
        }
        return .init(
            addedRequiredAPIPermissions: addedRequiredAPIPermissions.sorted {
                $0.rawValue < $1.rawValue
            },
            addedRequiredHostPermissions: addedRequiredHostPermissions.sorted {
                $0.original < $1.original
            }
        )
    }

    /// Catalog profiles are a review boundary, not display-only metadata. A
    /// signed record must claim every capability family present in the fixed
    /// manifest, including optional permissions that could later be requested.
    private static func validateCatalogCompatibilityProfiles(
        _ profiles: Set<String>,
        manifest: FloorpWebExtensionManifest
    ) throws {
        var required = Set<String>()
        let allAPIs = manifest.apiPermissions.union(manifest.optionalAPIPermissions)
        let contentScriptAPIs: Set<FloorpWebExtensionAPIGrant> = [.activeTab, .scripting]
        if !manifest.contentScripts.isEmpty ||
            !manifest.hostPermissions.isEmpty ||
            !manifest.optionalHostPermissions.isEmpty ||
            !allAPIs.intersection(contentScriptAPIs).isEmpty {
            required.insert("content-script")
        }
        if !manifest.dnrRuleResources.isEmpty ||
            !manifest.cosmeticFilterResources.isEmpty ||
            allAPIs.contains(.declarativeNetRequest) {
            required.insert("dnr")
        }
        let actionStorageAPIs: Set<FloorpWebExtensionAPIGrant> = [.alarms, .storage, .tabs]
        if manifest.action != nil ||
            manifest.optionsUI != nil ||
            manifest.background != nil ||
            !allAPIs.intersection(actionStorageAPIs).isEmpty {
            required.insert("action-storage")
        }
        guard profiles.isSuperset(of: required) else {
            throw FloorpWebExtensionCatalogError.artifactRejected(
                "catalog compatibility profile does not cover manifest capabilities"
            )
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

    private static func loadRegistry(
        from url: URL,
        packagesDirectory: URL
    ) throws -> (registry: Registry, data: Data?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (Registry(), nil)
        }
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
              Set(decoded.pendingPackageUpdates.keys).isSubset(of: decoded.packages.map(\.extensionID)),
              decoded.catalogUpdateHistory.count <= maximumCatalogUpdateHistoryEntries,
              decoded.catalogUpdateHistory.allSatisfy({ entry in
                  decoded.packages.contains(where: { $0.extensionID == entry.extensionID }) &&
                      isSafeGeneration(entry.previousCatalogGeneration) &&
                      isSafeGeneration(entry.replacementCatalogGeneration) &&
                      entry.previousCatalogGeneration != entry.replacementCatalogGeneration &&
                      entry.replacementArtifactSHA256.count == 64 &&
                      entry.replacementArtifactSHA256 == entry.replacementArtifactSHA256.lowercased() &&
                      entry.replacementArtifactSHA256.allSatisfy(\.isHexDigit)
              }) else {
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
                if let historyEntry = update.catalogUpdateHistoryEntry {
                    guard historyEntry.extensionID == extensionID,
                          historyEntry.previousCatalogGeneration == update.previousPackage.catalogRecord?.generation,
                          historyEntry.replacementCatalogGeneration == update.replacementPackage.catalogRecord?.generation,
                          historyEntry.replacementArtifactSHA256 ==
                            update.replacementPackage.catalogRecord?.artifactSHA256 else {
                        throw FloorpWebExtensionPackageStoreError.corruptedRegistry
                    }
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
        return (decoded, registryData)
    }

    /// A registry is an index, not an authority. Rebuild every security-
    /// relevant value from the immutable generation before exposing any
    /// package or resource loader after a process restart.
    private static func validateInstalledPackage(
        _ package: FloorpWebExtensionInstalledPackage,
        packagesDirectory: URL
    ) throws {
        guard isSafeGeneration(package.generation),
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

        try validateInstalledPackageOrigin(
            package,
            resources: resources,
            generationDirectory: generationDirectory
        )

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

        if let catalogRecord = package.catalogRecord {
            do {
                try FloorpWebExtensionManifest.validateCuratedCatalogDNRRules(
                    manifest: preflight.manifest,
                    ruleResourceData: resources.dataByPath
                )
                try validateCatalogCompatibilityProfiles(
                    catalogRecord.compatibilityProfiles,
                    manifest: preflight.manifest
                )
            } catch {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
        }

        if let catalogRevocation = package.catalogRevocation {
            guard package.catalogRecord?.generation == catalogRevocation.catalogGeneration,
                  !package.isEnabled else {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
        }

        if let dnrConfiguration = package.dnrConfiguration {
            let manifestRuleIDs = Set(preflight.manifest.dnrRuleResources.map(\.identifier))
            guard dnrConfiguration.enabledStaticRuleSetIDs.isSubset(of: manifestRuleIDs) else {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
            try validateStoredDNRConfiguration(dnrConfiguration)
        }
        try validatePersistentRegisteredScripts(
            package.registeredPersistentScripts,
            for: preflight.manifest,
            resourcePaths: package.resourcePaths
        )
    }

    private static func validateInstalledPackageOrigin(
        _ package: FloorpWebExtensionInstalledPackage,
        resources: ResourceSnapshot,
        generationDirectory: URL
    ) throws {
        switch (package.fixture, package.catalogRecord) {
        case let (.some(fixture), .none):
            guard package.extensionID == fixture.extensionID,
                  package.packageSHA256 == fixture.packageSHA256 else {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
            let fixtureMetadata = try FloorpWebExtensionCompatibilityHarness.verifyFixturePackage(
                at: generationDirectory
            )
            guard fixtureMetadata.fixture == fixture,
                  fixtureMetadata.fixture.extensionID == package.extensionID,
                  fixtureMetadata.fixture.version == package.version,
                  fixtureMetadata.fixture.packageSHA256 == package.packageSHA256 else {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
        case let (.none, .some(record)):
            let reconstructedArtifact: Data
            do {
                reconstructedArtifact = try FloorpWebExtensionCatalogArchive.encodedArtifact(
                    resources: resources.dataByPath
                )
            } catch {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
            guard record.extensionID == package.extensionID,
                  FloorpWebExtensionCatalogVerifier.isSafeIdentifier(
                      record.signingKeyID,
                      maximumLength: 96
                  ),
                  record.version == package.version,
                  record.localGeneration == package.generation,
                  record.availability == .available || record.availability == .updateAvailable,
                  record.artifactSHA256 == package.packageSHA256,
                  FloorpWebExtensionArtifactDownloader.sha256(reconstructedArtifact) == record.artifactSHA256 else {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
            do {
                _ = try FloorpWebExtensionCatalogArchive.decode(
                    reconstructedArtifact,
                    record: record
                )
            } catch {
                throw FloorpWebExtensionPackageStoreError.corruptedRegistry
            }
        case (.some, .some), (.none, .none):
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }
    }

    private static func validatePersistentRegisteredScripts(
        _ scripts: [FloorpWebExtensionRegisteredScript],
        for manifest: FloorpWebExtensionManifest,
        resourcePaths: Set<String>
    ) throws {
        guard scripts.allSatisfy(\.persistAcrossSessions) else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }

        do {
            // Manifest content scripts occupy a separate immutable namespace
            // and do not count against or collide with the dynamic API store.
            try FloorpWebExtensionScriptRegistry.validatePersistedScripts(scripts)
        } catch {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }

        for script in scripts {
            for source in script.javaScript + script.styleSheets {
                guard resourcePaths.contains(source.path) else {
                    throw FloorpWebExtensionPackageStoreError.resourceUnavailable(source.path)
                }
            }
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

    private static func registrySnapshotData(at registryURL: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return nil }
        return try Data(contentsOf: registryURL, options: [.mappedIfSafe])
    }

    /// A catalog operation may wait for consent, runtime suspension, or an
    /// actor hop after its initial signature check. Requiring the signed
    /// lifetime again at the write boundary prevents that stale authority
    /// from becoming a durable install, update, revival, or grant change.
    private func requireCatalogNotExpired(_ catalogExpiresAt: Date?) throws {
        guard let catalogExpiresAt else { return }
        // Treat the exact timestamp as expired. This conservative boundary
        // matches Settings and avoids granting an operation to a timer wake
        // that races the catalog lifetime endpoint.
        guard clock() < catalogExpiresAt else {
            throw FloorpWebExtensionCatalogError.expired
        }
    }

    private func persist(_ registry: Registry) throws {
        let data = try Self.encodedRegistryData(registry)
        try compositionState.performIfCurrent {
            try registryPersister(data, registryURL)
            durableSnapshotState.replace(with: data)
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
    ) throws {
        var previousToReactivate: FloorpWebExtensionPackageStore?
        if let previous = stores[store.profileKey], previous !== store {
            if previous.invalidateComposition() {
                previousToReactivate = previous
            }
        }
        do {
            try store.validateDurableSnapshotForCompositionInstall()
        } catch {
            // Publication has not happened. If this install performed the
            // invalidation itself, restore the still-registered store whose
            // in-memory snapshot matches the durable file. A composition that
            // was already invalidated by its owner stays fail-closed.
            previousToReactivate?.reactivateComposition()
            throw error
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

    /// Catalog acceptance is device-wide, so a signed kill switch must fan
    /// out to every currently composed normal/private profile manager rather
    /// than trusting the caller to remember one browsing mode.
    static func catalogRevocationManagers() -> [FloorpWebExtensionLivePackageManager] {
        managers.keys.sorted { lhs, rhs in
            if lhs.profileIdentifier != rhs.profileIdentifier {
                return lhs.profileIdentifier < rhs.profileIdentifier
            }
            return !lhs.isPrivateBrowsing && rhs.isPrivateBrowsing
        }.compactMap { managers[$0] }
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
