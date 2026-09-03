// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation

struct FloorpNativeWebExtensionVerifiedPackage: Sendable {
    let source: FloorpNativeWebExtensionPackageSource
    let reference: String
    let url: URL
    let sha256: String
    let byteCount: Int64
}

/// Owns package trust and immutable managed package storage. WebKit remains
/// responsible for archive expansion, manifest parsing, and runtime loading.
actor FloorpNativeWebExtensionPackageInstaller {
    static let maximumPackageByteCount: Int64 = 64 * 1_048_576

    private let rootDirectory: URL
    private let managedPackagesDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.managedPackagesDirectory = rootDirectory
            .appendingPathComponent("packages", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: managedPackagesDirectory,
            withIntermediateDirectories: true
        )
    }

    func verifiedBundledPackage(
        for item: FloorpNativeWebExtensionCatalogItem
    ) throws -> FloorpNativeWebExtensionVerifiedPackage {
        guard item.isAvailableOnCurrentOS else {
            throw FloorpNativeWebExtensionError.unsupportedOperatingSystem(required: item.minimumOS)
        }
        guard let resourceURL = item.bundledResourceURL else {
            throw FloorpNativeWebExtensionError.catalogResourceMissing(item.packageReference)
        }
        guard let bundleRoot = Bundle.main.resourceURL?.resolvingSymlinksInPath().standardizedFileURL,
              Self.isDescendant(resourceURL, of: bundleRoot) else {
            throw FloorpNativeWebExtensionError.invalidPackageSource
        }
        let verified = try verifyPackage(
            at: resourceURL,
            expectedSHA256: item.expectedSHA256,
            source: .bundled,
            reference: item.packageReference
        )
        return verified
    }

    /// Stages a package from a future signed catalog into a digest-addressed,
    /// immutable path. There is intentionally no arbitrary-import UI.
    func stageManagedPackage(
        from sourceURL: URL,
        catalogIdentifier: String,
        expectedSHA256: String
    ) throws -> FloorpNativeWebExtensionVerifiedPackage {
        let source = try verifyPackage(
            at: sourceURL,
            expectedSHA256: expectedSHA256,
            source: .managed,
            reference: "staging"
        )
        let safeCatalogIdentifier = try Self.safePathComponent(catalogIdentifier)
        let safeDigest = try Self.safeDigest(expectedSHA256)
        let relativeReference = "packages/\(safeCatalogIdentifier)/\(safeDigest)/extension.zip"
        let destination = try managedURL(for: relativeReference)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destination.path) {
            return try verifyPackage(
                at: destination,
                expectedSHA256: expectedSHA256,
                source: .managed,
                reference: relativeReference
            )
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString).zip")
        do {
            try fileManager.copyItem(at: source.url, to: temporary)
            let staged = try verifyPackage(
                at: temporary,
                expectedSHA256: expectedSHA256,
                source: .managed,
                reference: relativeReference
            )
            try fileManager.moveItem(at: temporary, to: destination)
            return FloorpNativeWebExtensionVerifiedPackage(
                source: staged.source,
                reference: staged.reference,
                url: destination,
                sha256: staged.sha256,
                byteCount: staged.byteCount
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func verifiedPackage(
        for record: FloorpNativeWebExtensionRecord
    ) throws -> FloorpNativeWebExtensionVerifiedPackage {
        switch record.packageSource {
        case .bundled:
            guard let item = FloorpNativeWebExtensionCatalog.item(identifier: record.id),
                  item.packageReference == record.packageReference else {
                throw FloorpNativeWebExtensionError.catalogResourceMissing(record.packageReference)
            }
            return try verifiedBundledPackage(for: item)
        case .managed:
            let packageURL = try managedURL(for: record.packageReference)
            return try verifyPackage(
                at: packageURL,
                expectedSHA256: record.sha256,
                source: .managed,
                reference: record.packageReference
            )
        }
    }

    func removeManagedPackage(reference: String) throws {
        let packageURL = try managedURL(for: reference)
        guard fileManager.fileExists(atPath: packageURL.path) else { return }
        try fileManager.removeItem(at: packageURL)

        var directory = packageURL.deletingLastPathComponent()
        while directory != managedPackagesDirectory && Self.isDescendant(directory, of: managedPackagesDirectory) {
            let contents = try fileManager.contentsOfDirectory(atPath: directory.path)
            guard contents.isEmpty else { break }
            try fileManager.removeItem(at: directory)
            directory.deleteLastPathComponent()
        }
    }

    private func verifyPackage(
        at url: URL,
        expectedSHA256: String,
        source: FloorpNativeWebExtensionPackageSource,
        reference: String
    ) throws -> FloorpNativeWebExtensionVerifiedPackage {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.isFileURL, resolvedURL.pathExtension.lowercased() == "zip" else {
            throw FloorpNativeWebExtensionError.invalidPackageFormat
        }
        let values = try resolvedURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true else {
            throw FloorpNativeWebExtensionError.invalidPackageFormat
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount > 0, byteCount <= Self.maximumPackageByteCount else {
            throw FloorpNativeWebExtensionError.packageTooLarge(Self.maximumPackageByteCount)
        }

        let handle = try FileHandle(forReadingFrom: resolvedURL)
        defer { try? handle.close() }
        let signature = try handle.read(upToCount: 4) ?? Data()
        guard signature.count == 4,
              signature[0] == 0x50,
              signature[1] == 0x4B,
              [0x03, 0x05, 0x07].contains(signature[2]) else {
            throw FloorpNativeWebExtensionError.invalidPackageFormat
        }
        try handle.seek(toOffset: 0)

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = try Self.safeDigest(expectedSHA256)
        guard actual == expected else {
            throw FloorpNativeWebExtensionError.packageDigestMismatch(expected: expected, actual: actual)
        }

        return FloorpNativeWebExtensionVerifiedPackage(
            source: source,
            reference: reference,
            url: resolvedURL,
            sha256: actual,
            byteCount: byteCount
        )
    }

    private func managedURL(for reference: String) throws -> URL {
        guard !reference.hasPrefix("/"),
              !reference.split(separator: "/").contains("..") else {
            throw FloorpNativeWebExtensionError.invalidPackageSource
        }
        let url = rootDirectory.appendingPathComponent(reference).standardizedFileURL
        guard Self.isDescendant(url, of: managedPackagesDirectory),
              url.lastPathComponent == "extension.zip" else {
            throw FloorpNativeWebExtensionError.invalidPackageSource
        }
        return url
    }

    private static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let ancestorPath = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == ancestorPath || candidatePath.hasPrefix(ancestorPath + "/")
    }

    private static func safePathComponent(_ value: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !value.isEmpty,
              value.rangeOfCharacter(from: allowed.inverted) == nil,
              value != ".",
              value != ".." else {
            throw FloorpNativeWebExtensionError.invalidPackageSource
        }
        return value
    }

    private static func safeDigest(_ value: String) throws -> String {
        let normalized = value.lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.count == 64,
              normalized.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw FloorpNativeWebExtensionError.invalidPackageSource
        }
        return normalized
    }
}

struct FloorpNativeWebExtensionRegistryStore {
    let url: URL

    func load() throws -> FloorpNativeWebExtensionRegistry {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FloorpNativeWebExtensionRegistry()
        }
        let data = try Data(contentsOf: url)
        let registry = try Self.decoder.decode(FloorpNativeWebExtensionRegistry.self, from: data)
        guard registry.schemaVersion == FloorpNativeWebExtensionRegistry.currentSchemaVersion,
              Set(registry.extensions.map(\.id)).count == registry.extensions.count,
              Set(registry.extensions.map(\.contextIdentifier)).count == registry.extensions.count,
              Set(registry.extensions.map(\.baseURLHost)).count == registry.extensions.count,
              registry.extensions.allSatisfy(Self.isValid) else {
            throw FloorpNativeWebExtensionError.invalidRegistry
        }
        return registry
    }

    func save(_ registry: FloorpNativeWebExtensionRegistry) throws {
        guard registry.schemaVersion == FloorpNativeWebExtensionRegistry.currentSchemaVersion,
              Set(registry.extensions.map(\.id)).count == registry.extensions.count,
              Set(registry.extensions.map(\.contextIdentifier)).count == registry.extensions.count,
              Set(registry.extensions.map(\.baseURLHost)).count == registry.extensions.count,
              registry.extensions.allSatisfy(Self.isValid) else {
            throw FloorpNativeWebExtensionError.invalidRegistry
        }
        try Self.encoder.encode(registry).write(to: url, options: [.atomic, .completeFileProtection])
    }

    func quarantineCorruptRegistry() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let quarantineURL = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp).json")
        try? FileManager.default.moveItem(at: url, to: quarantineURL)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func isValid(_ record: FloorpNativeWebExtensionRecord) -> Bool {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        let grantedPermissionValues = record.grantedPermissions.map(\.value)
        let deniedPermissionValues = record.deniedPermissions.map(\.value)
        let grantedMatchPatternValues = record.grantedMatchPatterns.map(\.value)
        let deniedMatchPatternValues = record.deniedMatchPatterns.map(\.value)
        guard !record.id.isEmpty,
              !record.contextIdentifier.isEmpty,
              !record.baseURLHost.isEmpty,
              !record.packageReference.isEmpty,
              record.sha256.count == 64,
              record.sha256.rangeOfCharacter(from: lowercaseHex.inverted) == nil,
              grantedPermissionValues.allSatisfy({ !$0.isEmpty }),
              deniedPermissionValues.allSatisfy({ !$0.isEmpty }),
              grantedMatchPatternValues.allSatisfy({ !$0.isEmpty }),
              deniedMatchPatternValues.allSatisfy({ !$0.isEmpty }),
              Set(grantedPermissionValues).count == grantedPermissionValues.count,
              Set(deniedPermissionValues).count == deniedPermissionValues.count,
              Set(grantedMatchPatternValues).count == grantedMatchPatternValues.count,
              Set(deniedMatchPatternValues).count == deniedMatchPatternValues.count,
              URL(string: "webkit-extension://\(record.baseURLHost)/")?.host == record.baseURLHost else {
            return false
        }
        return true
    }
}
