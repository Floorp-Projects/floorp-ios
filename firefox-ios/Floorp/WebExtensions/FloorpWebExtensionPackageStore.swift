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
        case .resourceUnavailable(let path):
            return "The extension package resource is unavailable: \(path)"
        }
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

    private struct Registry: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        var packages: [FloorpWebExtensionInstalledPackage]

        init(packages: [FloorpWebExtensionInstalledPackage] = []) {
            schemaVersion = Self.currentSchemaVersion
            self.packages = packages
        }
    }

    private struct ResourceSnapshot: Sendable {
        let dataByPath: [String: Data]
        let inventory: FloorpWebExtensionManifestPackageInventory
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
    private var registry: Registry

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

            let grants = try Self.validatedGrants(
                initialGrants,
                for: preflight.manifest
            )
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
                isEnabled: true,
                grants: grants,
                dnrConfiguration: existingDNRConfiguration
            )

            var next = registry
            next.packages.removeAll { $0.extensionID == expectedExtensionID }
            next.packages.append(installed)
            next.packages.sort { $0.extensionID.rawValue < $1.extensionID.rawValue }
            do {
                try persist(next)
            } catch {
                try? FileManager.default.removeItem(at: generationDirectory)
                throw error
            }
            registry = next
            refreshResourceState()
            return installed
        } catch {
            try? FileManager.default.removeItem(at: stagedPackage)
            throw error
        }
    }

    func installedPackages() -> [FloorpWebExtensionInstalledPackage] {
        registry.packages
    }

    func installedPackage(
        for extensionID: FloorpWebExtensionID
    ) -> FloorpWebExtensionInstalledPackage? {
        registry.packages.first { $0.extensionID == extensionID }
    }

    func setEnabled(_ enabled: Bool, for extensionID: FloorpWebExtensionID) throws {
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
    func recordActivationFailure(for extensionID: FloorpWebExtensionID) throws {
        var next = registry
        guard let index = next.packages.firstIndex(where: { $0.extensionID == extensionID }) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        next.packages[index].isEnabled = false
        next.packages[index].activationError = "This extension could not be activated. Enable it to try again."
        try persist(next)
        registry = next
        refreshResourceState()
    }

    func updateGrants(
        _ grants: FloorpWebExtensionPermissionSnapshot,
        for extensionID: FloorpWebExtensionID
    ) throws {
        var next = registry
        guard let index = next.packages.firstIndex(where: { $0.extensionID == extensionID }) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        next.packages[index].grants = try Self.validatedGrants(
            grants,
            for: next.packages[index].preflight.manifest
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

    /// Registry removal is committed before files are deleted. A crash during
    /// cleanup therefore leaves only an inactive orphan, never an unregistered
    /// package that can still be loaded by a newly-created resource loader.
    func uninstall(_ extensionID: FloorpWebExtensionID) throws {
        guard registry.packages.contains(where: { $0.extensionID == extensionID }) else {
            throw FloorpWebExtensionPackageStoreError.packageNotInstalled(extensionID)
        }
        var next = registry
        next.packages.removeAll { $0.extensionID == extensionID }
        try persist(next)
        registry = next
        refreshResourceState()
        try? FileManager.default.removeItem(
            at: packagesDirectory.appendingPathComponent(extensionID.rawValue, isDirectory: true)
        )
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
        for manifest: FloorpWebExtensionManifest
    ) throws -> FloorpWebExtensionPermissionSnapshot {
        let requestedHosts = Set(manifest.hostPermissions)
        guard let proposed else {
            return .init(requestedHosts: requestedHosts)
        }
        guard proposed.apiPermissions.isSubset(of: manifest.apiPermissions),
              proposed.requestedHosts == requestedHosts,
              hostAccess(proposed.normalHostAccess, isSubsetOf: requestedHosts),
              hostAccess(proposed.privateHostAccess, isSubsetOf: requestedHosts),
              proposed.privateBrowsingEnabled || proposed.privateHostAccess == .denied else {
            throw FloorpWebExtensionPackageStoreError.invalidInitialGrants
        }
        return proposed
    }

    private static func hostAccess(
        _ access: FloorpWebExtensionHostAccess,
        isSubsetOf requestedHosts: Set<FloorpWebExtensionMatchPattern>
    ) -> Bool {
        switch access {
        case .denied, .allRequestedSites:
            return true
        case .selectedSites(let selected):
            return selected.isSubset(of: requestedHosts)
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
              Set(decoded.packages.map(\.extensionID)).count == decoded.packages.count else {
            throw FloorpWebExtensionPackageStoreError.corruptedRegistry
        }
        do {
            for package in decoded.packages {
                try validateInstalledPackage(package, packagesDirectory: packagesDirectory)
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
              try validatedGrants(package.grants, for: preflight.manifest) == package.grants else {
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

    private func persist(_ registry: Registry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(registry)
        guard data.count <= Self.maximumRegistryByteSize else {
            throw FloorpWebExtensionPackageStoreError.packageQuotaExceeded("registry size")
        }
        try registryPersister(data, registryURL)
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
        stores[store.profileKey] = store
        managers[store.profileKey] = manager
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
        stores.removeValue(forKey: key)
        managers.removeValue(forKey: key)
    }
}
