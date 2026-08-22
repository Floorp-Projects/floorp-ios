// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation

struct FloorpWebExtensionFixture: Codable, Equatable, Hashable, Sendable {
    let extensionID: FloorpWebExtensionID
    let sourceRepository: URL
    let sourceCommit: String
    let version: String
    let buildFlavor: String
    let packageSHA256: String
    let license: String
    let supportedOSFloor: String

    init(
        extensionID: FloorpWebExtensionID,
        sourceRepository: URL,
        sourceCommit: String,
        version: String,
        buildFlavor: String = "local-fixture",
        packageSHA256: String,
        license: String,
        supportedOSFloor: String
    ) throws {
        guard Self.isPinnedRepository(sourceRepository),
              Self.isPinnedCommit(sourceCommit),
              Self.isSafeText(version, maximumLength: 128),
              Self.isSafeText(buildFlavor, maximumLength: 128),
              Self.isSHA256(packageSHA256),
              Self.isSafeLicense(license),
              FloorpWebExtensionOSVersion.parse(supportedOSFloor) != nil else {
            throw FloorpWebExtensionError.unsupported("invalid compatibility fixture metadata")
        }
        self.extensionID = extensionID
        self.sourceRepository = sourceRepository
        self.sourceCommit = sourceCommit.lowercased()
        self.version = version
        self.buildFlavor = buildFlavor
        self.packageSHA256 = packageSHA256.lowercased()
        self.license = license
        self.supportedOSFloor = supportedOSFloor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            extensionID: try container.decode(FloorpWebExtensionID.self, forKey: .extensionID),
            sourceRepository: try container.decode(URL.self, forKey: .sourceRepository),
            sourceCommit: try container.decode(String.self, forKey: .sourceCommit),
            version: try container.decode(String.self, forKey: .version),
            buildFlavor: try container.decode(String.self, forKey: .buildFlavor),
            packageSHA256: try container.decode(String.self, forKey: .packageSHA256),
            license: try container.decode(String.self, forKey: .license),
            supportedOSFloor: try container.decode(String.self, forKey: .supportedOSFloor)
        )
    }

    private static func isPinnedRepository(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
            url.host?.isEmpty == false &&
            url.user == nil &&
            url.password == nil &&
            url.query == nil &&
            url.fragment == nil
    }

    private static func isPinnedCommit(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func isSafeLicense(_ value: String) -> Bool {
        isSafeText(value, maximumLength: 256) && value.contains(where: \.isLetter)
    }

    fileprivate static func isSafeText(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.count <= maximumLength &&
            value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
            }
    }
}

/// Pinned metadata for a local compatibility fixture package. The fixture
/// itself remains test-only; this records the exact source, build flavor and
/// package content that produced a compatibility result.
struct FloorpWebExtensionFixturePackageMetadata: Codable, Equatable, Sendable {
    let fixture: FloorpWebExtensionFixture
    let requiredOperatingSystems: [String]
    let generatedRulesetLog: String

    init(
        fixture: FloorpWebExtensionFixture,
        requiredOperatingSystems: [String],
        generatedRulesetLog: String
    ) throws {
        guard !requiredOperatingSystems.isEmpty,
              Set(requiredOperatingSystems).count == requiredOperatingSystems.count,
              requiredOperatingSystems.allSatisfy({ FloorpWebExtensionOSVersion.parse($0) != nil }),
              !generatedRulesetLog.isEmpty,
              generatedRulesetLog.count <= 256 * 1_024,
              generatedRulesetLog.unicodeScalars.allSatisfy({ scalar in
                  scalar == "\n" || scalar == "\r" || scalar == "\t" ||
                      (scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value))
              }) else {
            throw FloorpWebExtensionError.unsupported("invalid fixture package metadata")
        }
        self.fixture = fixture
        self.requiredOperatingSystems = requiredOperatingSystems
        self.generatedRulesetLog = generatedRulesetLog
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: FloorpWebExtensionCompatibilityCodingKey.self)
        let expectedKeys: Set<String> = ["fixture", "requiredOperatingSystems", "generatedRulesetLog"]
        guard Set(rawContainer.allKeys.map(\.stringValue)) == expectedKeys else {
            throw FloorpWebExtensionError.unsupported("invalid fixture package metadata keys")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            fixture: try container.decode(FloorpWebExtensionFixture.self, forKey: .fixture),
            requiredOperatingSystems: try container.decode([String].self, forKey: .requiredOperatingSystems),
            generatedRulesetLog: try container.decode(String.self, forKey: .generatedRulesetLog)
        )
    }
}

enum FloorpWebExtensionCompatibilityStatus: String, Codable, Sendable {
    case passed
    case partial
    case unsupported
    case failed
}

struct FloorpWebExtensionCompatibilityResult: Codable, Equatable, Sendable {
    let capability: String
    let status: FloorpWebExtensionCompatibilityStatus
    let detail: String
}

struct FloorpWebExtensionDNREvidence: Codable, Equatable, Sendable {
    let accepted: Int
    let transformed: Int
    let rejected: [String: Int]
    let compilerLog: String
}

extension FloorpWebExtensionCompatibilityResult {
    fileprivate static func isValid(_ result: Self) -> Bool {
        FloorpWebExtensionFixture.isSafeText(result.capability, maximumLength: 256) &&
            FloorpWebExtensionFixture.isSafeText(result.detail, maximumLength: 4_096)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capability = try container.decode(String.self, forKey: .capability)
        let status = try container.decode(FloorpWebExtensionCompatibilityStatus.self, forKey: .status)
        let detail = try container.decode(String.self, forKey: .detail)
        let result = Self(capability: capability, status: status, detail: detail)
        guard Self.isValid(result) else {
            throw FloorpWebExtensionError.unsupported("invalid compatibility result")
        }
        self = result
    }
}

extension FloorpWebExtensionDNREvidence {
    fileprivate var isValid: Bool {
        accepted >= 0 &&
            transformed >= 0 &&
            transformed <= accepted &&
            rejected.allSatisfy {
                FloorpWebExtensionFixture.isSafeText($0.key, maximumLength: 256) && $0.value >= 0
            } &&
            isSafeCompilerLog(compilerLog)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let evidence = Self(
            accepted: try container.decode(Int.self, forKey: .accepted),
            transformed: try container.decode(Int.self, forKey: .transformed),
            rejected: try container.decode([String: Int].self, forKey: .rejected),
            compilerLog: try container.decode(String.self, forKey: .compilerLog)
        )
        guard evidence.isValid else {
            throw FloorpWebExtensionError.unsupported("invalid DNR compatibility diagnostics")
        }
        self = evidence
    }

    private func isSafeCompilerLog(_ value: String) -> Bool {
        !value.isEmpty &&
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.count <= 256 * 1_024 &&
            value.unicodeScalars.allSatisfy { scalar in
                scalar == "\n" || scalar == "\r" || scalar == "\t" ||
                    (scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value))
            }
    }
}

struct FloorpWebExtensionPerformanceEvidence: Codable, Equatable, Sendable {
    let coldCompileMilliseconds: Double
    let warmCompileMilliseconds: Double
    let pageLoadOverheadMilliseconds: Double
    let memoryDeltaBytes: Int64

    init(
        coldCompileMilliseconds: Double,
        warmCompileMilliseconds: Double,
        pageLoadOverheadMilliseconds: Double,
        memoryDeltaBytes: Int64
    ) throws {
        guard coldCompileMilliseconds.isFinite,
              warmCompileMilliseconds.isFinite,
              pageLoadOverheadMilliseconds.isFinite,
              coldCompileMilliseconds >= 0,
              warmCompileMilliseconds >= 0,
              pageLoadOverheadMilliseconds >= 0 else {
            throw FloorpWebExtensionError.unsupported("invalid compatibility performance measurement")
        }
        self.coldCompileMilliseconds = coldCompileMilliseconds
        self.warmCompileMilliseconds = warmCompileMilliseconds
        self.pageLoadOverheadMilliseconds = pageLoadOverheadMilliseconds
        self.memoryDeltaBytes = memoryDeltaBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            coldCompileMilliseconds: try container.decode(Double.self, forKey: .coldCompileMilliseconds),
            warmCompileMilliseconds: try container.decode(Double.self, forKey: .warmCompileMilliseconds),
            pageLoadOverheadMilliseconds: try container.decode(Double.self, forKey: .pageLoadOverheadMilliseconds),
            memoryDeltaBytes: try container.decode(Int64.self, forKey: .memoryDeltaBytes)
        )
    }
}

struct FloorpWebExtensionCompatibilityEvidence: Codable, Equatable, Sendable {
    let fixture: FloorpWebExtensionFixture
    let deviceModel: String
    let operatingSystem: String
    let recordedAt: Date
    let results: [FloorpWebExtensionCompatibilityResult]
    let dnr: FloorpWebExtensionDNREvidence
    let performance: FloorpWebExtensionPerformanceEvidence
    let visualEvidencePaths: [String]

    init(
        fixture: FloorpWebExtensionFixture,
        deviceModel: String,
        operatingSystem: String,
        recordedAt: Date = Date(),
        results: [FloorpWebExtensionCompatibilityResult],
        dnr: FloorpWebExtensionDNREvidence,
        performance: FloorpWebExtensionPerformanceEvidence,
        visualEvidencePaths: [String] = []
    ) throws {
        guard FloorpWebExtensionFixture.isSafeText(deviceModel, maximumLength: 256),
              let operatingSystemVersion = FloorpWebExtensionOSVersion.parse(operatingSystem),
              let supportedOSFloor = FloorpWebExtensionOSVersion.parse(fixture.supportedOSFloor),
              operatingSystemVersion >= supportedOSFloor,
              recordedAt.timeIntervalSinceReferenceDate.isFinite,
              !results.isEmpty,
              results.allSatisfy(FloorpWebExtensionCompatibilityResult.isValid),
              dnr.isValid,
              visualEvidencePaths.allSatisfy(Self.isSafeRelativeEvidencePath) else {
            throw FloorpWebExtensionError.unsupported("invalid compatibility evidence")
        }
        self.fixture = fixture
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.recordedAt = recordedAt
        self.results = results
        self.dnr = dnr
        self.performance = performance
        self.visualEvidencePaths = visualEvidencePaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            fixture: try container.decode(FloorpWebExtensionFixture.self, forKey: .fixture),
            deviceModel: try container.decode(String.self, forKey: .deviceModel),
            operatingSystem: try container.decode(String.self, forKey: .operatingSystem),
            recordedAt: try container.decode(Date.self, forKey: .recordedAt),
            results: try container.decode([FloorpWebExtensionCompatibilityResult].self, forKey: .results),
            dnr: try container.decode(FloorpWebExtensionDNREvidence.self, forKey: .dnr),
            performance: try container.decode(FloorpWebExtensionPerformanceEvidence.self, forKey: .performance),
            visualEvidencePaths: try container.decode([String].self, forKey: .visualEvidencePaths)
        )
    }

    private static func isSafeRelativeEvidencePath(_ value: String) -> Bool {
        guard FloorpWebExtensionFixture.isSafeText(value, maximumLength: 1_024),
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\\\") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

enum FloorpWebExtensionCompatibilityHarness {
    private static let maximumEvidenceFileSize = 1_024 * 1_024
    private static let maximumFixtureResourceSize = 8 * 1_024 * 1_024

    /// Loads and verifies a checked-in local fixture package. Its digest is
    /// computed over the sorted resource path/data stream, excluding only the
    /// metadata file that contains the digest itself.
    static func verifyFixturePackage(
        at packageDirectory: URL
    ) throws -> FloorpWebExtensionFixturePackageMetadata {
        let resources = try fixtureResources(in: packageDirectory)
        guard let metadataData = resources["fixture-metadata.json"],
              let manifestData = resources["manifest.json"] else {
            throw FloorpWebExtensionError.unsupported("fixture package is missing metadata or manifest")
        }

        let metadata = try JSONDecoder().decode(
            FloorpWebExtensionFixturePackageMetadata.self,
            from: metadataData
        )
        let packageData = canonicalFixturePackageData(resources)
        try verifyPackage(packageData, fixture: metadata.fixture)

        let inventory = FloorpWebExtensionManifestPackageInventory(resources: resources.map {
            .init(path: $0.key, isRegularFile: true, byteSize: $0.value.count)
        })
        let preflight = try FloorpWebExtensionManifest.preflight(
            manifestData: manifestData,
            packageInventory: inventory,
            ruleResourceData: resources
        )
        guard preflight.isActivationAllowed else {
            throw FloorpWebExtensionError.unsupported("fixture manifest contains unsupported capabilities")
        }
        return metadata
    }

    static func verifyPackage(_ data: Data, fixture: FloorpWebExtensionFixture) throws {
        guard !data.isEmpty else {
            throw FloorpWebExtensionError.unsupported("fixture package is empty")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == fixture.packageSHA256 else {
            throw FloorpWebExtensionError.unsupported("fixture package digest does not match the pinned SHA-256")
        }
    }

    /// Verifies that every fixture has evidence for every required iOS release.
    /// Each `requiredOperatingSystems` entry must use the same `iOS <version>`
    /// format as `FloorpWebExtensionCompatibilityEvidence.operatingSystem`.
    static func verifyOSMatrix(
        _ evidence: [FloorpWebExtensionCompatibilityEvidence],
        requiredOperatingSystems: [String]
    ) throws {
        guard !evidence.isEmpty,
              !requiredOperatingSystems.isEmpty else {
            throw FloorpWebExtensionError.unsupported("compatibility OS matrix is empty")
        }

        let requiredVersions = try Set(requiredOperatingSystems.map { operatingSystem in
            guard let version = FloorpWebExtensionOSVersion.parse(operatingSystem) else {
                throw FloorpWebExtensionError.unsupported("invalid required compatibility OS")
            }
            return version
        })

        let evidenceByFixture = Dictionary(grouping: evidence, by: \.fixture)
        for (fixture, records) in evidenceByFixture {
            guard let floor = FloorpWebExtensionOSVersion.parse(fixture.supportedOSFloor) else {
                throw FloorpWebExtensionError.unsupported("invalid compatibility fixture OS floor")
            }
            guard requiredVersions.allSatisfy({ $0 >= floor }) else {
                throw FloorpWebExtensionError.unsupported("compatibility OS matrix is below the fixture OS floor")
            }

            let measuredVersions = Set(records.compactMap {
                FloorpWebExtensionOSVersion.parse($0.operatingSystem)
            })
            guard measuredVersions.isSuperset(of: requiredVersions) else {
                throw FloorpWebExtensionError.unsupported("compatibility OS matrix is incomplete")
            }
        }
    }

    static func save(
        _ evidence: FloorpWebExtensionCompatibilityEvidence,
        to directory: URL,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(evidence)
        guard data.count <= maximumEvidenceFileSize else {
            throw FloorpWebExtensionError.unsupported("compatibility evidence exceeds the size limit")
        }
        let name = safeFileComponent(evidence.fixture.extensionID.rawValue) + "--" +
            safeFileComponent(evidence.operatingSystem) + ".json"
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func load(
        from url: URL,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> FloorpWebExtensionCompatibilityEvidence {
        try validateEvidenceFile(url)
        let data = try Data(contentsOf: url)
        try validateEvidenceJSONStructure(data)
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(FloorpWebExtensionCompatibilityEvidence.self, from: data)
    }

    private static func validateEvidenceFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumEvidenceFileSize else {
            throw FloorpWebExtensionError.unsupported("invalid compatibility evidence file")
        }
    }

    private static func fixtureResources(in packageDirectory: URL) throws -> [String: Data] {
        let root = packageDirectory.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isFileURL,
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                  options: []
              ) else {
            throw FloorpWebExtensionError.unsupported("invalid fixture package directory")
        }

        var resources = [String: Data]()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let candidate as URL in enumerator {
            let url = candidate.standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                throw FloorpWebExtensionError.unsupported("fixture package contains a symbolic link")
            }
            guard values.isRegularFile == true else { continue }
            guard url.path.hasPrefix(rootPrefix) else {
                throw FloorpWebExtensionError.unsupported("fixture package resource escapes its root")
            }

            let path = String(url.path.dropFirst(rootPrefix.count))
            guard (try? FloorpWebExtensionScriptSource(path)) != nil,
                  let fileSize = values.fileSize,
                  (0...maximumFixtureResourceSize).contains(fileSize),
                  resources[path] == nil else {
                throw FloorpWebExtensionError.unsupported("invalid fixture package resource")
            }

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count == fileSize else {
                throw FloorpWebExtensionError.unsupported("fixture package resource changed while loading")
            }
            resources[path] = data
        }
        guard !resources.isEmpty else {
            throw FloorpWebExtensionError.unsupported("fixture package is empty")
        }
        return resources
    }

    private static func canonicalFixturePackageData(_ resources: [String: Data]) -> Data {
        resources.keys
            .filter { $0 != "fixture-metadata.json" }
            .sorted()
            .reduce(into: Data()) { package, path in
                package.append(path.data(using: .utf8)!)
                package.append(0)
                package.append(resources[path]!)
            }
    }

    private static func validateEvidenceJSONStructure(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let evidence = object as? [String: Any],
              hasExactlyKeys(evidence, [
                  "fixture", "deviceModel", "operatingSystem", "recordedAt",
                  "results", "dnr", "performance", "visualEvidencePaths"
              ]),
              let fixture = evidence["fixture"] as? [String: Any],
              hasExactlyKeys(fixture, [
                  "extensionID", "sourceRepository", "sourceCommit", "version",
                  "buildFlavor", "packageSHA256", "license", "supportedOSFloor"
              ]),
              let results = evidence["results"] as? [[String: Any]],
              !results.isEmpty,
              results.allSatisfy({
                  hasExactlyKeys($0, ["capability", "status", "detail"])
              }),
              let dnr = evidence["dnr"] as? [String: Any],
              hasExactlyKeys(dnr, ["accepted", "transformed", "rejected", "compilerLog"]),
              let performance = evidence["performance"] as? [String: Any],
              hasExactlyKeys(performance, [
                  "coldCompileMilliseconds", "warmCompileMilliseconds",
                  "pageLoadOverheadMilliseconds", "memoryDeltaBytes"
              ]),
              evidence["visualEvidencePaths"] is [Any] else {
            throw FloorpWebExtensionError.unsupported("malformed compatibility evidence")
        }
    }

    private static func hasExactlyKeys(_ object: [String: Any], _ keys: [String]) -> Bool {
        Set(object.keys) == Set(keys)
    }

    private static func safeFileComponent(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
                ? String(scalar)
                : "_"
        }.joined()
    }
}

/// The profile-owned persistence boundary for Stage 3 compatibility evidence.
/// Normal profiles receive a durable directory from profile composition;
/// private mode receives an ephemeral directory that is removed with its
/// profile runtime.
@MainActor
final class FloorpWebExtensionCompatibilityEvidenceStore {
    private let directory: URL

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let values = try self.directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard self.directory.isFileURL,
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw FloorpWebExtensionError.unsupported("invalid compatibility evidence directory")
        }
    }

    @discardableResult
    func record(_ evidence: FloorpWebExtensionCompatibilityEvidence) throws -> URL {
        try FloorpWebExtensionCompatibilityHarness.save(evidence, to: directory)
    }

    func allEvidence() throws -> [FloorpWebExtensionCompatibilityEvidence] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw FloorpWebExtensionError.unsupported("invalid compatibility evidence entry")
            }
            return try FloorpWebExtensionCompatibilityHarness.load(from: url)
        }
    }

    func verifyOSMatrix(requiredOperatingSystems: [String]) throws {
        try FloorpWebExtensionCompatibilityHarness.verifyOSMatrix(
            allEvidence(),
            requiredOperatingSystems: requiredOperatingSystems
        )
    }
}

/// Registers the profile-local stores created by application composition.
/// Compatibility-harness callers use this registry rather than a global
/// documents directory, so normal and private evidence can never mix.
@MainActor
enum FloorpWebExtensionCompatibilityEvidenceRegistry {
    private struct ProfileKey: Hashable {
        let profileIdentifier: String
        let isPrivateBrowsing: Bool
    }

    private static var stores = [ProfileKey: FloorpWebExtensionCompatibilityEvidenceStore]()

    static func install(
        _ store: FloorpWebExtensionCompatibilityEvidenceStore,
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) {
        stores[ProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )] = store
    }

    static func removeStore(for profileIdentifier: String, isPrivateBrowsing: Bool) {
        stores.removeValue(forKey: ProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        ))
    }

    @discardableResult
    static func record(
        _ evidence: FloorpWebExtensionCompatibilityEvidence,
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) throws -> URL {
        let key = ProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        guard let store = stores[key] else {
            throw FloorpWebExtensionError.unsupported("compatibility evidence store is not configured for this profile")
        }
        return try store.record(evidence)
    }

    static func evidence(
        for profileIdentifier: String,
        isPrivateBrowsing: Bool
    ) throws -> [FloorpWebExtensionCompatibilityEvidence] {
        let key = ProfileKey(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing
        )
        guard let store = stores[key] else {
            throw FloorpWebExtensionError.unsupported("compatibility evidence store is not configured for this profile")
        }
        return try store.allEvidence()
    }
}

private struct FloorpWebExtensionCompatibilityCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct FloorpWebExtensionOSVersion: Comparable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    static func parse(_ value: String) -> Self? {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0] == "iOS",
              !parts[1].isEmpty else {
            return nil
        }

        let versionParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(versionParts.count),
              versionParts.allSatisfy({
                  !$0.isEmpty && $0.allSatisfy(\.isNumber) &&
                      ($0.count == 1 || $0.first != "0")
              }),
              let major = Int(versionParts[0]),
              major > 0 else {
            return nil
        }

        let minor = versionParts.count > 1 ? Int(versionParts[1]) : 0
        let patch = versionParts.count > 2 ? Int(versionParts[2]) : 0
        guard let minor, let patch else { return nil }
        return Self(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
