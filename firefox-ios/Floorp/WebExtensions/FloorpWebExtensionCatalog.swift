// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation
import Security

/// A permission category shown before a bundled package is enabled.
///
/// The UI deliberately uses these product-level categories rather than raw
/// manifest permission strings so the confirmation remains understandable.
enum FloorpWebExtensionPermissionCategory: String, CaseIterable, Hashable, Sendable {
    case siteData
    case tabs
    case storage
    case networkBlocking
    case browserAutomation

    var title: String {
        switch self {
        case .siteData:
            return "Read and change data on selected sites"
        case .tabs:
            return "Read tab metadata and open or reload tabs"
        case .storage:
            return "Store extension settings on this device"
        case .networkBlocking:
            return "Block supported network requests"
        case .browserAutomation:
            return "Run approved page scripts and styles"
        }
    }
}

/// Immutable product metadata for a package that ships inside the app bundle.
///
/// This is intentionally separate from an installed package record.  The
/// catalog describes provenance and requested capabilities before installation;
/// the package store owns all mutable install state.
struct FloorpWebExtensionBundledCatalogItem: Hashable, Sendable, Identifiable {
    let id: FloorpWebExtensionID
    let name: String
    let version: String
    let summary: String
    let source: String
    let license: String
    let packageDirectoryName: String
    let requestedPermissions: [FloorpWebExtensionPermissionCategory]

    /// Resolves the directory after the fixture has been copied as a folder
    /// resource into the application bundle.  It intentionally only accepts
    /// the actual bundle resource location so missing resources fail closed.
    func packageURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: packageDirectoryName, withExtension: nil) ??
            bundle.url(
                forResource: packageDirectoryName,
                withExtension: nil,
                subdirectory: "WebExtensions/Fixtures"
            )
    }
}

enum FloorpWebExtensionBundledCatalog {
    static let demandingMV3Fixture = FloorpWebExtensionBundledCatalogItem(
        id: FloorpWebExtensionID(rawValue: "floorp.fixture.demanding-mv3")!,
        name: "Floorp MV3 Compatibility Fixture",
        version: "1.0.0",
        summary: "Tests supported content scripts, cosmetic filtering, and safe network blocking.",
        source: "Floorp iOS compatibility fixture",
        license: "MPL-2.0",
        packageDirectoryName: "demanding-mv3",
        requestedPermissions: [.siteData, .tabs, .storage, .networkBlocking, .browserAutomation]
    )

    static let contentMessagingMV3Fixture = FloorpWebExtensionBundledCatalogItem(
        id: FloorpWebExtensionID(rawValue: "floorp.fixture.content-messaging-mv3")!,
        name: "Floorp Content Messaging Fixture",
        version: "1.0.0",
        summary: "Tests document-start content scripts and an authenticated runtime message round trip.",
        source: "Floorp iOS compatibility fixture",
        license: "MPL-2.0",
        packageDirectoryName: "content-messaging-mv3",
        requestedPermissions: [.siteData, .browserAutomation]
    )

    static let eventRuntimeMV3Fixture = FloorpWebExtensionBundledCatalogItem(
        id: FloorpWebExtensionID(rawValue: "floorp.fixture.event-runtime-mv3")!,
        name: "Floorp Event Runtime Fixture",
        version: "1.0.0",
        summary: "Tests the reviewed lazy event runtime, local storage, alarms, popup, and options resources.",
        source: "Floorp iOS compatibility fixture",
        license: "MPL-2.0",
        packageDirectoryName: "event-runtime-mv3",
        requestedPermissions: [.storage, .browserAutomation]
    )

    /// The App Store MVP intentionally exposes only pinned bundled packages.
    /// Remote sources and arbitrary file import remain independently gated.
    static let items = [contentMessagingMV3Fixture, eventRuntimeMV3Fixture, demandingMV3Fixture]
}

enum FloorpWebExtensionCatalogError: Error, Equatable, LocalizedError, Sendable {
    case invalidCanonicalJSON
    case invalidCatalog(String)
    case invalidSignature
    case expired
    case clockRollback
    case sequenceRollback
    case revoked
    case artifactRejected(String)
    case remoteCatalogDisabled
    case updateConsentRequired

    var errorDescription: String? {
        switch self {
        case .invalidCanonicalJSON:
            return "The signed WebExtensions catalog is not canonical JSON."
        case .invalidCatalog(let reason):
            return "The signed WebExtensions catalog is invalid: \(reason)"
        case .invalidSignature:
            return "The signed WebExtensions catalog signature is invalid."
        case .expired:
            return "The signed WebExtensions catalog has expired."
        case .clockRollback:
            return "The device clock moved backwards; catalog changes are blocked."
        case .sequenceRollback:
            return "The signed WebExtensions catalog sequence was rolled back."
        case .revoked:
            return "The signed WebExtensions catalog is revoked."
        case .artifactRejected(let reason):
            return "The signed WebExtensions artifact was rejected: \(reason)"
        case .remoteCatalogDisabled:
            return "The managed WebExtensions catalog is not authorized for this build."
        case .updateConsentRequired:
            return "Updating this WebExtension requires an explicit confirmation for this immutable generation."
        }
    }
}

/// A deliberately small JSON parser used for data that is covered by a
/// signature. `JSONSerialization` cannot report duplicate object keys, so it
/// is not a valid trust boundary for catalog-v1.
enum FloorpWebExtensionCanonicalJSON {
    indirect enum Value: Equatable, Sendable {
        case object([String: Value])
        case array([Value])
        case string(String)
        case integer(Int64)
        case bool(Bool)
        case null

        var object: [String: Value]? {
            guard case .object(let value) = self else { return nil }
            return value
        }

        var array: [Value]? {
            guard case .array(let value) = self else { return nil }
            return value
        }

        var string: String? {
            guard case .string(let value) = self else { return nil }
            return value
        }

        var integer: Int64? {
            guard case .integer(let value) = self else { return nil }
            return value
        }
    }

    static let maximumInputBytes = 1 * 1_024 * 1_024
    private static let maximumDepth = 64

    static func parse(_ data: Data) throws -> Value {
        guard !data.isEmpty, data.count <= maximumInputBytes else {
            throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
        }
        var parser = Parser(bytes: Array(data))
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
        }
        return value
    }

    static func canonicalData(_ value: Value) throws -> Data {
        var bytes = [UInt8]()
        try append(value, to: &bytes)
        return Data(bytes)
    }

    static func canonicalData(
        from data: Data,
        excludingTopLevelKey excludedKey: String? = nil
    ) throws -> Data {
        let value = try parse(data)
        if let excludedKey {
            guard case .object(var object) = value,
                  object.removeValue(forKey: excludedKey) != nil else {
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
            return try canonicalData(.object(object))
        }
        return try canonicalData(value)
    }

    static func utf8LessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func append(_ value: Value, to bytes: inout [UInt8]) throws {
        switch value {
        case .object(let object):
            bytes.append(0x7B)
            for (index, key) in object.keys.sorted(by: utf8LessThan).enumerated() {
                if index > 0 { bytes.append(0x2C) }
                try appendString(key, to: &bytes)
                bytes.append(0x3A)
                guard let child = object[key] else {
                    throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
                try append(child, to: &bytes)
            }
            bytes.append(0x7D)
        case .array(let array):
            bytes.append(0x5B)
            for (index, child) in array.enumerated() {
                if index > 0 { bytes.append(0x2C) }
                try append(child, to: &bytes)
            }
            bytes.append(0x5D)
        case .string(let string):
            try appendString(string, to: &bytes)
        case .integer(let integer):
            bytes.append(contentsOf: String(integer).utf8)
        case .bool(let bool):
            bytes.append(contentsOf: bool ? [0x74, 0x72, 0x75, 0x65] : [0x66, 0x61, 0x6C, 0x73, 0x65])
        case .null:
            bytes.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
        }
    }

    private static func appendString(_ string: String, to bytes: inout [UInt8]) throws {
        guard string.unicodeScalars.allSatisfy({ $0.value != 0 }) else {
            throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
        }
        bytes.append(0x22)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: bytes.append(contentsOf: [0x5C, 0x22])
            case 0x5C: bytes.append(contentsOf: [0x5C, 0x5C])
            case 0x08: bytes.append(contentsOf: [0x5C, 0x62])
            case 0x0C: bytes.append(contentsOf: [0x5C, 0x66])
            case 0x0A: bytes.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: bytes.append(contentsOf: [0x5C, 0x72])
            case 0x09: bytes.append(contentsOf: [0x5C, 0x74])
            case 0...0x1F:
                let encoded = String(format: "\\u%04x", scalar.value)
                bytes.append(contentsOf: encoded.utf8)
            default:
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        bytes.append(0x22)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> Value {
            guard depth <= FloorpWebExtensionCanonicalJSON.maximumDepth else {
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
            skipWhitespace()
            guard index < bytes.count else {
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
            switch bytes[index] {
            case 0x7B: return try parseObject(depth: depth + 1)
            case 0x5B: return try parseArray(depth: depth + 1)
            case 0x22: return .string(try parseString())
            case 0x74:
                try consumeLiteral([0x74, 0x72, 0x75, 0x65])
                return .bool(true)
            case 0x66:
                try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
                return .bool(false)
            case 0x6E:
                try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
                return .null
            case 0x2D, 0x30...0x39:
                return .integer(try parseInteger())
            default:
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
        }

        mutating func parseObject(depth: Int) throws -> Value {
            try consume(0x7B)
            skipWhitespace()
            var object = [String: Value]()
            if try consumeIf(0x7D) { return .object(object) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
                let key = try parseString()
                guard key == key.precomposedStringWithCanonicalMapping,
                      !key.isEmpty,
                      key.unicodeScalars.allSatisfy({ $0.isASCII }) else {
                    throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
                skipWhitespace()
                try consume(0x3A)
                let value = try parseValue(depth: depth)
                guard object.updateValue(value, forKey: key) == nil else {
                    throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
                skipWhitespace()
                if try consumeIf(0x7D) { return .object(object) }
                try consume(0x2C)
            }
        }

        mutating func parseArray(depth: Int) throws -> Value {
            try consume(0x5B)
            skipWhitespace()
            var values = [Value]()
            if try consumeIf(0x5D) { return .array(values) }
            while true {
                values.append(try parseValue(depth: depth))
                skipWhitespace()
                if try consumeIf(0x5D) { return .array(values) }
                try consume(0x2C)
            }
        }

        mutating func parseInteger() throws -> Int64 {
            let start = index
            if bytes[index] == 0x2D {
                index += 1
                guard index < bytes.count, bytes[index] != 0x30 else {
                    throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
            }
            guard index < bytes.count else {
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
            if bytes[index] == 0x30 {
                index += 1
            } else {
                guard (0x31...0x39).contains(bytes[index]) else {
                    throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
                repeat { index += 1 } while index < bytes.count && (0x30...0x39).contains(bytes[index])
            }
            guard index == bytes.count || ![0x2E, 0x45, 0x65].contains(bytes[index]),
                  let result = Int64(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
            return result
        }

        mutating func parseString() throws -> String {
            try consume(0x22)
            var result = ""
            var segmentStart = index
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 || byte == 0x5C {
                    guard let segment = String(bytes: bytes[segmentStart..<index], encoding: .utf8),
                          segment.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else {
                        throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                    }
                    result.append(segment)
                    index += 1
                    if byte == 0x22 { return result }
                    guard index < bytes.count else {
                        throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                    }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case 0x22: result.append("\"")
                    case 0x5C: result.append("\\")
                    case 0x2F: result.append("/")
                    case 0x62: result.append("\u{08}")
                    case 0x66: result.append("\u{0C}")
                    case 0x6E: result.append("\n")
                    case 0x72: result.append("\r")
                    case 0x74: result.append("\t")
                    case 0x75:
                        let scalar = try parseEscapedUnicodeScalar()
                        result.unicodeScalars.append(scalar)
                    default:
                        throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                    }
                    segmentStart = index
                } else {
                    guard byte >= 0x20 else {
                        throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                    }
                    index += 1
                }
            }
            throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
        }

        mutating func parseEscapedUnicodeScalar() throws -> UnicodeScalar {
            let first = try parseHexQuad()
            if (0xD800...0xDBFF).contains(first) {
                guard index + 2 <= bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                    throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
                index += 2
                let second = try parseHexQuad()
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
                let value = 0x1_0000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                guard let scalar = UnicodeScalar(value) else {
                    throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
                return scalar
            }
            guard !(0xDC00...0xDFFF).contains(first), let scalar = UnicodeScalar(first) else {
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
            return scalar
        }

        mutating func parseHexQuad() throws -> UInt32 {
            guard index + 4 <= bytes.count else {
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
            var value: UInt32 = 0
            for byte in bytes[index..<(index + 4)] {
                let nibble: UInt32
                switch byte {
                case 0x30...0x39: nibble = UInt32(byte - 0x30)
                case 0x41...0x46: nibble = UInt32(byte - 0x41 + 10)
                case 0x61...0x66: nibble = UInt32(byte - 0x61 + 10)
                default: throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
                }
                value = (value << 4) | nibble
            }
            index += 4
            return value
        }

        mutating func consume(_ expected: UInt8) throws {
            guard index < bytes.count, bytes[index] == expected else {
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
            index += 1
        }

        mutating func consumeIf(_ expected: UInt8) throws -> Bool {
            guard index < bytes.count, bytes[index] == expected else { return false }
            index += 1
            return true
        }

        mutating func consumeLiteral(_ literal: [UInt8]) throws {
            guard bytes.count - index >= literal.count,
                  bytes[index..<(index + literal.count)].elementsEqual(literal) else {
                throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
            }
            index += literal.count
        }
    }
}

struct FloorpWebExtensionCatalogTrustConfiguration: Sendable {
    let catalogID: String
    let appBundleID: String
    let appVersion: String
    let channel: String
    let rootPublicKey: Data
    let maximumCatalogValidity: TimeInterval
    let maximumLeafValidity: TimeInterval

    init(
        catalogID: String,
        appBundleID: String,
        appVersion: String,
        channel: String,
        rootPublicKey: Data,
        maximumCatalogValidity: TimeInterval = 14 * 24 * 60 * 60,
        maximumLeafValidity: TimeInterval = 90 * 24 * 60 * 60
    ) throws {
        guard FloorpWebExtensionCatalogVerifier.isSafeIdentifier(catalogID, maximumLength: 96),
              FloorpWebExtensionCatalogVerifier.isSafeIdentifier(appBundleID, maximumLength: 255),
              FloorpWebExtensionCatalogVerifier.isSafeIdentifier(channel, maximumLength: 32),
              FloorpWebExtensionCatalogVerifier.semanticVersion(appVersion) != nil,
              rootPublicKey.count == 32,
              maximumCatalogValidity > 0,
              maximumLeafValidity > 0 else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid trust configuration")
        }
        self.catalogID = catalogID
        self.appBundleID = appBundleID
        self.appVersion = appVersion
        self.channel = channel
        self.rootPublicKey = rootPublicKey
        self.maximumCatalogValidity = maximumCatalogValidity
        self.maximumLeafValidity = maximumLeafValidity
    }
}

struct FloorpWebExtensionCatalogPackageRecord: Codable, Hashable, Sendable {
    enum Availability: String, Codable, Hashable, Sendable {
        case available
        case updateAvailable
        case withdrawn
        case revoked
    }

    let extensionID: FloorpWebExtensionID
    let generation: String
    /// Derived from the root-certified leaf that signed this catalog. It is
    /// retained with the installed generation so a later key revocation can
    /// stop all packages that key authorized.
    let signingKeyID: String
    let version: String
    let artifactURL: URL
    let artifactBytes: Int
    let artifactSHA256: String
    let manifestSHA256: String
    let resourceInventorySHA256: String
    let compatibilityProfiles: Set<String>
    let availability: Availability

    var localGeneration: String {
        "\(generation)-\(artifactSHA256.prefix(16))"
    }
}

struct FloorpWebExtensionCatalogGeneration: Codable, Hashable, Sendable {
    let extensionID: FloorpWebExtensionID
    let generation: String
}

/// A generation label is not merely a display value. Once it has appeared in
/// an accepted catalog, the label is permanently bound to this artifact
/// digest on this device. This prevents a later, validly signed catalog from
/// redefining the bytes behind an existing immutable generation.
struct FloorpWebExtensionCatalogGenerationArtifactDigest: Codable, Hashable, Sendable {
    let catalogGeneration: FloorpWebExtensionCatalogGeneration
    let artifactSHA256: String
    /// The one leaf key that authorized this immutable generation. Leaf-key
    /// provenance is deliberately as immutable as the artifact digest: a
    /// key rotation must publish a new generation even when bytes are
    /// unchanged, so a mutable registry record cannot retag an old-key
    /// installation as a new-key installation after revocation.
    /// `nil` is only the read-compatible representation of pre-P0 Keychain
    /// state; it never authorizes a catalog package at startup or re-enable.
    let signingKeyID: String?

    init(
        catalogGeneration: FloorpWebExtensionCatalogGeneration,
        artifactSHA256: String,
        signingKeyID: String? = nil
    ) {
        self.catalogGeneration = catalogGeneration
        self.artifactSHA256 = artifactSHA256
        self.signingKeyID = signingKeyID
    }

    private enum CodingKeys: String, CodingKey {
        case catalogGeneration
        case artifactSHA256
        case signingKeyID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        catalogGeneration = try container.decode(
            FloorpWebExtensionCatalogGeneration.self,
            forKey: .catalogGeneration
        )
        artifactSHA256 = try container.decode(String.self, forKey: .artifactSHA256)
        signingKeyID = try container.decodeIfPresent(String.self, forKey: .signingKeyID)
    }
}

struct FloorpWebExtensionCatalogAcceptanceState: Codable, Equatable, Sendable {
    let catalogID: String
    let highestSequence: Int64
    let maximumObservedAt: Date
    let revokedKeyIDs: Set<String>
    let revokedGenerations: Set<FloorpWebExtensionCatalogGeneration>
    /// Optional in old Keychain state so the P0-gated implementation can be
    /// introduced without making an existing state unreadable. Once a new
    /// catalog is accepted, every observed catalog generation is bound here.
    let acceptedGenerationArtifacts: Set<FloorpWebExtensionCatalogGenerationArtifactDigest>

    init(
        catalogID: String,
        highestSequence: Int64,
        maximumObservedAt: Date,
        revokedKeyIDs: Set<String>,
        revokedGenerations: Set<FloorpWebExtensionCatalogGeneration>,
        acceptedGenerationArtifacts: Set<FloorpWebExtensionCatalogGenerationArtifactDigest> = []
    ) {
        self.catalogID = catalogID
        self.highestSequence = highestSequence
        self.maximumObservedAt = maximumObservedAt
        self.revokedKeyIDs = revokedKeyIDs
        self.revokedGenerations = revokedGenerations
        self.acceptedGenerationArtifacts = acceptedGenerationArtifacts
    }

    private enum CodingKeys: String, CodingKey {
        case catalogID
        case highestSequence
        case maximumObservedAt
        case revokedKeyIDs
        case revokedGenerations
        case acceptedGenerationArtifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        catalogID = try container.decode(String.self, forKey: .catalogID)
        highestSequence = try container.decode(Int64.self, forKey: .highestSequence)
        maximumObservedAt = try container.decode(Date.self, forKey: .maximumObservedAt)
        revokedKeyIDs = try container.decode(Set<String>.self, forKey: .revokedKeyIDs)
        revokedGenerations = try container.decode(
            Set<FloorpWebExtensionCatalogGeneration>.self,
            forKey: .revokedGenerations
        )
        acceptedGenerationArtifacts = try container.decodeIfPresent(
            Set<FloorpWebExtensionCatalogGenerationArtifactDigest>.self,
            forKey: .acceptedGenerationArtifacts
        ) ?? []
    }
}

struct FloorpWebExtensionVerifiedCatalog: Sendable {
    let catalogID: String
    let sequence: Int64
    let issuedAt: Date
    let expiresAt: Date
    let packages: [FloorpWebExtensionCatalogPackageRecord]
    let revokedKeyIDs: Set<String>
    let revokedGenerations: Set<FloorpWebExtensionCatalogGeneration>
    let nextAcceptanceState: FloorpWebExtensionCatalogAcceptanceState
}

struct FloorpWebExtensionCatalogVerificationResult: Sendable {
    let catalog: FloorpWebExtensionVerifiedCatalog

    func installablePackage(
        extensionID: FloorpWebExtensionID,
        generation: String
    ) throws -> FloorpWebExtensionCatalogPackageRecord {
        guard let record = catalog.packages.first(where: {
            $0.extensionID == extensionID && $0.generation == generation
        }),
              record.availability == .available || record.availability == .updateAvailable,
              !catalog.revokedKeyIDs.contains(record.signingKeyID),
              !catalog.revokedGenerations.contains(.init(extensionID: extensionID, generation: generation)) else {
            throw FloorpWebExtensionCatalogError.revoked
        }
        return record
    }
}

/// Verifies a complete catalog and produces a new anti-rollback state. The
/// caller must durably commit `nextAcceptanceState` before it presents a new
/// install or update affordance.
struct FloorpWebExtensionCatalogVerifier: Sendable {
    private struct LeafKey: Sendable {
        let keyID: String
        let publicKey: Data
        let notBefore: Date
        let notAfter: Date
    }

    private enum Revocation: Sendable {
        case key(String, Date)
        case generation(FloorpWebExtensionCatalogGeneration, Date)
    }

    let configuration: FloorpWebExtensionCatalogTrustConfiguration
    let clockRollbackTolerance: TimeInterval

    init(
        configuration: FloorpWebExtensionCatalogTrustConfiguration,
        clockRollbackTolerance: TimeInterval = 5 * 60
    ) throws {
        guard clockRollbackTolerance >= 0 else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid clock tolerance")
        }
        self.configuration = configuration
        self.clockRollbackTolerance = clockRollbackTolerance
    }

    func verify(
        catalogData: Data,
        previousState: FloorpWebExtensionCatalogAcceptanceState?,
        now: Date = Date()
    ) throws -> FloorpWebExtensionCatalogVerificationResult {
        let value = try FloorpWebExtensionCanonicalJSON.parse(catalogData)
        // The signature covers the canonical form, and catalog-v1 also
        // requires the transported bytes themselves to be canonical. This
        // keeps a signed semantic value from acquiring a second, tolerated
        // wire representation through whitespace, key ordering, or escapes.
        guard try FloorpWebExtensionCanonicalJSON.canonicalData(value) == catalogData else {
            throw FloorpWebExtensionCatalogError.invalidCanonicalJSON
        }
        let root = try exactObject(
            value,
            keys: [
                "schemaVersion", "catalogID", "sequence", "issuedAt", "expiresAt", "audience",
                "signingKey", "packages", "revocations", "signature"
            ]
        )
        guard try integer(root, "schemaVersion") == 1,
              try string(root, "catalogID", maximumLength: 96) == configuration.catalogID else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("unsupported catalog identity")
        }
        let sequence = try integer(root, "sequence")
        guard sequence > 0 else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid sequence")
        }
        let issuedAt = try timestamp(try string(root, "issuedAt", maximumLength: 20))
        let expiresAt = try timestamp(try string(root, "expiresAt", maximumLength: 20))
        guard issuedAt <= expiresAt,
              expiresAt.timeIntervalSince(issuedAt) <= configuration.maximumCatalogValidity,
              now >= issuedAt,
              now <= expiresAt else {
            throw FloorpWebExtensionCatalogError.expired
        }
        if let previousState {
            guard previousState.catalogID == configuration.catalogID else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("acceptance state belongs to another catalog")
            }
            guard now.addingTimeInterval(clockRollbackTolerance) >= previousState.maximumObservedAt else {
                throw FloorpWebExtensionCatalogError.clockRollback
            }
            guard sequence > previousState.highestSequence else {
                throw FloorpWebExtensionCatalogError.sequenceRollback
            }
        }
        try verifyAudience(try exactObject(root["audience"], keys: ["bundleIDs", "minimumAppVersion", "channel"]))
        let signingKey = try verifyLeafKey(
            try exactObject(
                root["signingKey"],
                keys: ["keyID", "publicKey", "notBefore", "notAfter", "signature"]
            )
        )
        guard signingKey.notBefore <= issuedAt,
              signingKey.notAfter >= expiresAt,
              now >= signingKey.notBefore,
              now <= signingKey.notAfter else {
            throw FloorpWebExtensionCatalogError.expired
        }
        let signature = try base64URL(
            try string(root, "signature", maximumLength: 128),
            exactByteCount: 64
        )
        var unsignedCatalog = root
        unsignedCatalog.removeValue(forKey: "signature")
        let signedBytes = try FloorpWebExtensionCanonicalJSON.canonicalData(.object(unsignedCatalog))
        let leafPublicKey: Curve25519.Signing.PublicKey
        do {
            leafPublicKey = try .init(rawRepresentation: signingKey.publicKey)
        } catch {
            throw FloorpWebExtensionCatalogError.invalidSignature
        }
        guard leafPublicKey.isValidSignature(signature, for: signedBytes) else {
            throw FloorpWebExtensionCatalogError.invalidSignature
        }

        let revocations = try parseRevocations(try array(root, "revocations"))
        // The client deliberately has no background scheduler that could
        // safely enforce a future kill switch while it is suspended. Accepting
        // a future-dated revocation and then forgetting it would be fail-open,
        // so catalog-v1 only accepts revocations that are already effective.
        guard revocations.allSatisfy({ revocation in
            switch revocation {
            case .key(_, let effectiveAt), .generation(_, let effectiveAt):
                return effectiveAt <= now
            }
        }) else {
            throw FloorpWebExtensionCatalogError.invalidCatalog(
                "future-dated revocations are not supported"
            )
        }
        var revokedKeyIDs = previousState?.revokedKeyIDs ?? []
        var revokedGenerations = previousState?.revokedGenerations ?? []
        for revocation in revocations {
            switch revocation {
            case .key(let keyID, _): revokedKeyIDs.insert(keyID)
            case .generation(let generation, _): revokedGenerations.insert(generation)
            }
        }
        guard !revokedKeyIDs.contains(signingKey.keyID) else {
            throw FloorpWebExtensionCatalogError.revoked
        }
        let packages = try parsePackages(
            try array(root, "packages"),
            signingKeyID: signingKey.keyID
        )
        var acceptedGenerationArtifacts = Set<FloorpWebExtensionCatalogGenerationArtifactDigest>()
        for binding in previousState?.acceptedGenerationArtifacts ?? [] {
            let identity = binding.catalogGeneration
            guard Self.isSafeGeneration(identity.generation),
                  binding.artifactSHA256.count == 64,
                  binding.artifactSHA256 == binding.artifactSHA256.lowercased(),
                  binding.artifactSHA256.allSatisfy(\.isHexDigit) else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("catalog generation state is malformed")
            }
            if let signingKeyID = binding.signingKeyID,
               !Self.isSafeIdentifier(signingKeyID, maximumLength: 96) {
                throw FloorpWebExtensionCatalogError.invalidCatalog("catalog generation state has invalid signing key")
            }
            try mergeAcceptedGenerationBinding(
                binding,
                into: &acceptedGenerationArtifacts
            )
        }
        for record in packages {
            let identity = FloorpWebExtensionCatalogGeneration(
                extensionID: record.extensionID,
                generation: record.generation
            )
            try mergeAcceptedGenerationBinding(
                .init(
                    catalogGeneration: identity,
                    artifactSHA256: record.artifactSHA256,
                    signingKeyID: signingKey.keyID
                ),
                into: &acceptedGenerationArtifacts
            )
        }
        let state = FloorpWebExtensionCatalogAcceptanceState(
            catalogID: configuration.catalogID,
            highestSequence: sequence,
            maximumObservedAt: max(previousState?.maximumObservedAt ?? .distantPast, now),
            revokedKeyIDs: revokedKeyIDs,
            revokedGenerations: revokedGenerations,
            acceptedGenerationArtifacts: acceptedGenerationArtifacts
        )
        return .init(catalog: .init(
            catalogID: configuration.catalogID,
            sequence: sequence,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            packages: packages,
            revokedKeyIDs: revokedKeyIDs,
            revokedGenerations: revokedGenerations,
            nextAcceptanceState: state
        ))
    }

    /// Keeps a generation immutable across every accepted catalog dimension
    /// that controls execution, including leaf-key provenance. A trusted key
    /// rotation must therefore publish a new generation even if the artifact
    /// bytes are unchanged. An older Keychain state may lack provenance; it
    /// is replaced when a newly verified record supplies one and can never
    /// authorize execution itself.
    private func mergeAcceptedGenerationBinding(
        _ proposed: FloorpWebExtensionCatalogGenerationArtifactDigest,
        into bindings: inout Set<FloorpWebExtensionCatalogGenerationArtifactDigest>
    ) throws {
        let identity = proposed.catalogGeneration
        if proposed.signingKeyID != nil {
            let legacyBindings = bindings.filter { binding in
                binding.catalogGeneration == identity && binding.signingKeyID == nil
            }
            guard legacyBindings.allSatisfy({
                $0.artifactSHA256 == proposed.artifactSHA256
            }) else {
                throw FloorpWebExtensionCatalogError.invalidCatalog(
                    "catalog generation was already bound to another artifact"
                )
            }
            bindings.subtract(legacyBindings)
        }
        guard !bindings.contains(where: {
            $0.catalogGeneration == identity &&
                ($0.artifactSHA256 != proposed.artifactSHA256 ||
                    $0.signingKeyID != proposed.signingKeyID)
        }) else {
            throw FloorpWebExtensionCatalogError.invalidCatalog(
                "catalog generation was already bound to another artifact or signing key"
            )
        }
        bindings.insert(proposed)
    }

    private func verifyAudience(_ audience: [String: FloorpWebExtensionCanonicalJSON.Value]) throws {
        let bundleIDs = try array(audience, "bundleIDs").map { value -> String in
            guard let value = value.string,
                  Self.isSafeIdentifier(value, maximumLength: 255) else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("invalid audience bundle ID")
            }
            return value
        }
        guard !bundleIDs.isEmpty,
              Set(bundleIDs).count == bundleIDs.count,
              bundleIDs.contains(configuration.appBundleID),
              try string(audience, "channel", maximumLength: 32) == configuration.channel,
              let minimum = Self.semanticVersion(try string(audience, "minimumAppVersion", maximumLength: 32)),
              let current = Self.semanticVersion(configuration.appVersion),
              Self.semanticVersionIsAtLeast(current, minimum) else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("catalog audience does not match this app")
        }
    }

    private func verifyLeafKey(_ object: [String: FloorpWebExtensionCanonicalJSON.Value]) throws -> LeafKey {
        let keyID = try string(object, "keyID", maximumLength: 96)
        guard Self.isSafeIdentifier(keyID, maximumLength: 96) else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid signing key ID")
        }
        let publicKey = try base64URL(
            try string(object, "publicKey", maximumLength: 96),
            exactByteCount: 32
        )
        let notBefore = try timestamp(try string(object, "notBefore", maximumLength: 20))
        let notAfter = try timestamp(try string(object, "notAfter", maximumLength: 20))
        guard notBefore < notAfter,
              notAfter.timeIntervalSince(notBefore) <= configuration.maximumLeafValidity else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid signing-key validity")
        }
        let signature = try base64URL(
            try string(object, "signature", maximumLength: 128),
            exactByteCount: 64
        )
        var unsigned = object
        unsigned.removeValue(forKey: "signature")
        let signedBytes = try FloorpWebExtensionCanonicalJSON.canonicalData(.object(unsigned))
        let root: Curve25519.Signing.PublicKey
        do {
            root = try .init(rawRepresentation: configuration.rootPublicKey)
        } catch {
            throw FloorpWebExtensionCatalogError.invalidSignature
        }
        guard root.isValidSignature(signature, for: signedBytes) else {
            throw FloorpWebExtensionCatalogError.invalidSignature
        }
        return .init(keyID: keyID, publicKey: publicKey, notBefore: notBefore, notAfter: notAfter)
    }

    private func parsePackages(
        _ values: [FloorpWebExtensionCanonicalJSON.Value],
        signingKeyID: String
    ) throws -> [FloorpWebExtensionCatalogPackageRecord] {
        guard values.count <= 128 else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("too many packages")
        }
        var records = [FloorpWebExtensionCatalogPackageRecord]()
        var identifiers = Set<FloorpWebExtensionCatalogGeneration>()
        for value in values {
            let object = try exactObject(value, keys: [
                "extensionID", "generation", "version", "artifactURL", "artifactBytes", "artifactSHA256",
                "manifestSHA256", "resourceInventorySHA256", "compatibilityProfiles", "availability"
            ])
            let extensionIDValue = try string(object, "extensionID", maximumLength: 128)
            guard let extensionID = FloorpWebExtensionID(rawValue: extensionIDValue),
                  extensionID.rawValue == extensionIDValue else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("invalid extension ID")
            }
            let generation = try string(object, "generation", maximumLength: 48)
            guard Self.isSafeGeneration(generation) else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("invalid generation")
            }
            let version = try string(object, "version", maximumLength: 32)
            guard Self.semanticVersion(version) != nil else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("invalid package version")
            }
            let artifactURLValue = try string(object, "artifactURL", maximumLength: 2_048)
            guard let artifactURL = URL(string: artifactURLValue),
                  artifactURL.absoluteString == artifactURLValue else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("invalid artifact URL")
            }
            let artifactBytes = try integer(object, "artifactBytes")
            guard artifactBytes > 0,
                  artifactBytes <= Int64(FloorpWebExtensionPackageStore.maximumPackageByteSize) else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("invalid artifact byte size")
            }
            let profiles = try Set(array(object, "compatibilityProfiles").map { value -> String in
                guard let profile = value.string,
                      ["content-script", "dnr", "action-storage"].contains(profile) else {
                    throw FloorpWebExtensionCatalogError.invalidCatalog("unsupported compatibility profile")
                }
                return profile
            })
            guard !profiles.isEmpty,
                  profiles.count == (try array(object, "compatibilityProfiles")).count else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("duplicate compatibility profile")
            }
            guard let availability = FloorpWebExtensionCatalogPackageRecord.Availability(
                rawValue: try string(object, "availability", maximumLength: 32)
            ) else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("invalid package availability")
            }
            let record = FloorpWebExtensionCatalogPackageRecord(
                extensionID: extensionID,
                generation: generation,
                signingKeyID: signingKeyID,
                version: version,
                artifactURL: artifactURL,
                artifactBytes: Int(artifactBytes),
                artifactSHA256: try sha256(object, "artifactSHA256"),
                manifestSHA256: try sha256(object, "manifestSHA256"),
                resourceInventorySHA256: try sha256(object, "resourceInventorySHA256"),
                compatibilityProfiles: profiles,
                availability: availability
            )
            guard identifiers.insert(.init(extensionID: extensionID, generation: generation)).inserted else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("duplicate package generation")
            }
            records.append(record)
        }
        return records
    }

    private func parseRevocations(
        _ values: [FloorpWebExtensionCanonicalJSON.Value]
    ) throws -> [Revocation] {
        guard values.count <= 256 else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("too many revocations")
        }
        var result = [Revocation]()
        var seenKeys = Set<String>()
        var seenGenerations = Set<FloorpWebExtensionCatalogGeneration>()
        for value in values {
            guard let raw = value.object,
                  let kind = raw["kind"]?.string else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("invalid revocation")
            }
            switch kind {
            case "key":
                let object = try exactObject(value, keys: ["kind", "keyID", "effectiveAt"])
                let keyID = try string(object, "keyID", maximumLength: 96)
                guard Self.isSafeIdentifier(keyID, maximumLength: 96), seenKeys.insert(keyID).inserted else {
                    throw FloorpWebExtensionCatalogError.invalidCatalog("duplicate or invalid revoked key")
                }
                result.append(.key(keyID, try timestamp(try string(object, "effectiveAt", maximumLength: 20))))
            case "generation":
                let object = try exactObject(value, keys: ["kind", "extensionID", "generation", "effectiveAt"])
                let extensionIDValue = try string(object, "extensionID", maximumLength: 128)
                guard let extensionID = FloorpWebExtensionID(rawValue: extensionIDValue),
                      extensionID.rawValue == extensionIDValue else {
                    throw FloorpWebExtensionCatalogError.invalidCatalog("invalid revoked extension ID")
                }
                let generation = try string(object, "generation", maximumLength: 48)
                let record = FloorpWebExtensionCatalogGeneration(extensionID: extensionID, generation: generation)
                guard Self.isSafeGeneration(generation), seenGenerations.insert(record).inserted else {
                    throw FloorpWebExtensionCatalogError.invalidCatalog("duplicate or invalid revoked generation")
                }
                result.append(.generation(record, try timestamp(try string(object, "effectiveAt", maximumLength: 20))))
            default:
                throw FloorpWebExtensionCatalogError.invalidCatalog("unsupported revocation kind")
            }
        }
        return result
    }

    private func exactObject(
        _ value: FloorpWebExtensionCanonicalJSON.Value?,
        keys: Set<String>
    ) throws -> [String: FloorpWebExtensionCanonicalJSON.Value] {
        guard let object = value?.object, Set(object.keys) == keys else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("unexpected object fields")
        }
        return object
    }

    private func array(
        _ object: [String: FloorpWebExtensionCanonicalJSON.Value],
        _ key: String
    ) throws -> [FloorpWebExtensionCanonicalJSON.Value] {
        guard let value = object[key]?.array else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid \(key)")
        }
        return value
    }

    private func string(
        _ object: [String: FloorpWebExtensionCanonicalJSON.Value],
        _ key: String,
        maximumLength: Int
    ) throws -> String {
        guard let value = object[key]?.string,
              !value.isEmpty,
              value.count <= maximumLength,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) }) else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid \(key)")
        }
        return value
    }

    private func integer(
        _ object: [String: FloorpWebExtensionCanonicalJSON.Value],
        _ key: String
    ) throws -> Int64 {
        guard let value = object[key]?.integer else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid \(key)")
        }
        return value
    }

    private func sha256(
        _ object: [String: FloorpWebExtensionCanonicalJSON.Value],
        _ key: String
    ) throws -> String {
        let value = try string(object, key, maximumLength: 64)
        guard value.count == 64, value.allSatisfy(\.isHexDigit), value == value.lowercased() else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid \(key)")
        }
        return value
    }

    private func timestamp(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid timestamp")
        }
        return date
    }

    private func base64URL(_ value: String, exactByteCount: Int) throws -> Data {
        guard !value.contains("="),
              !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) ||
                      (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x5F
              }) else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid base64url")
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64), data.count == exactByteCount else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid base64url")
        }
        return data
    }

    static func isSafeIdentifier(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    private static func isSafeGeneration(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 47 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    static func semanticVersion(_ value: String) -> [Int]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(components.count), components.allSatisfy({ component in
            !component.isEmpty && component.count <= 9 &&
                (component == "0" || !component.hasPrefix("0")) && component.allSatisfy(\.isNumber)
        }) else {
            return nil
        }
        return components.compactMap { Int($0) }
    }

    private static func semanticVersionIsAtLeast(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}

struct FloorpWebExtensionCatalogArtifactEndpointPolicy: Sendable {
    let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) throws {
        let normalized = Set(allowedHosts.map { $0.lowercased() })
        guard !normalized.isEmpty,
              normalized.allSatisfy({ host in
                  host.count <= 253 && host.contains(".") &&
                      host.utf8.allSatisfy { byte in
                          (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x2E
                      }
              }) else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid artifact host allow-list")
        }
        self.allowedHosts = normalized
    }

    func permits(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
            url.host.map({ allowedHosts.contains($0.lowercased()) }) == true &&
            url.user == nil && url.password == nil && url.port == nil &&
            url.query == nil && url.fragment == nil
    }
}

struct FloorpWebExtensionCatalogFetchResponse: Sendable {
    let finalURL: URL
    let statusCode: Int
    let data: Data
}

/// A downloaded FWEA1 artifact bound to the exact accepted catalog sequence
/// that selected it. The package-manager entry point separately requires an
/// opaque lifecycle authorization, so merely assembling this in-process value
/// cannot become a catalog/import authority.
struct FloorpWebExtensionVerifiedCatalogArtifact: Sendable {
    let catalogID: String
    let catalogSequence: Int64
    let record: FloorpWebExtensionCatalogPackageRecord
    let resources: [String: Data]

    init(
        catalogID: String,
        catalogSequence: Int64,
        record: FloorpWebExtensionCatalogPackageRecord,
        resources: [String: Data]
    ) {
        self.catalogID = catalogID
        self.catalogSequence = catalogSequence
        self.record = record
        self.resources = resources
    }
}

/// An opaque capability minted only by the lifecycle acceptance coordinator
/// after it has rechecked the current durable anti-rollback state. The
/// capability remains bound to the exact catalog-selected artifact at the
/// package-manager boundary, so it cannot be replayed for another record.
/// Keeping construction file-scoped prevents the package-manager entry point
/// from becoming an alternate catalog/import authority.
struct FloorpWebExtensionCatalogInstallationAuthorization: Sendable {
    private let catalogID: String
    private let catalogSequence: Int64
    private let record: FloorpWebExtensionCatalogPackageRecord

    fileprivate init(artifact: FloorpWebExtensionVerifiedCatalogArtifact) {
        catalogID = artifact.catalogID
        catalogSequence = artifact.catalogSequence
        record = artifact.record
    }

    func authorizes(_ artifact: FloorpWebExtensionVerifiedCatalogArtifact) -> Bool {
        catalogID == artifact.catalogID &&
            catalogSequence == artifact.catalogSequence &&
            record == artifact.record
    }
}

/// The package-store half of an explicit catalog-update confirmation. It
/// deliberately binds the active immutable generation to the signed record;
/// a generic "yes" cannot authorize a different digest after a refresh.
struct FloorpWebExtensionCatalogUpdateConsent: Sendable, Equatable {
    let extensionID: FloorpWebExtensionID
    let installedGeneration: String
    let replacementCatalogGeneration: String
    let replacementArtifactSHA256: String
}

/// Fetches exactly one selected artifact. The production transport is not
/// constructed until P0 enables the managed source; this type accepts a
/// caller-owned transport so it cannot turn arbitrary URLs into an API.
struct FloorpWebExtensionArtifactDownloader: Sendable {
    typealias Transport = @Sendable (URL) async throws -> FloorpWebExtensionCatalogFetchResponse

    let endpointPolicy: FloorpWebExtensionCatalogArtifactEndpointPolicy

    func download(
        catalog: FloorpWebExtensionCatalogVerificationResult,
        record: FloorpWebExtensionCatalogPackageRecord,
        transport: Transport
    ) async throws -> FloorpWebExtensionVerifiedCatalogArtifact {
        let installableRecord = try catalog.installablePackage(
            extensionID: record.extensionID,
            generation: record.generation
        )
        guard installableRecord == record else {
            throw FloorpWebExtensionCatalogError.artifactRejected(
                "artifact record is not the verified catalog record"
            )
        }
        guard endpointPolicy.permits(record.artifactURL) else {
            throw FloorpWebExtensionCatalogError.artifactRejected("artifact endpoint is not allowed")
        }
        let response: FloorpWebExtensionCatalogFetchResponse
        do {
            response = try await transport(record.artifactURL)
        } catch {
            throw FloorpWebExtensionCatalogError.artifactRejected("artifact transfer failed")
        }
        guard response.finalURL.absoluteString == record.artifactURL.absoluteString,
              response.statusCode == 200,
              response.data.count == record.artifactBytes else {
            throw FloorpWebExtensionCatalogError.artifactRejected("redirect, status, or byte-count mismatch")
        }
        guard Self.sha256(response.data) == record.artifactSHA256 else {
            throw FloorpWebExtensionCatalogError.artifactRejected("artifact digest mismatch")
        }
        return try .init(
            catalogID: catalog.catalog.catalogID,
            catalogSequence: catalog.catalog.sequence,
            record: record,
            resources: FloorpWebExtensionCatalogArchive.decode(response.data, record: record)
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// `FWEA1` is the only accepted catalog artifact envelope. It is not a ZIP or
/// CRX parser: a fixed, hash-described, non-compressed sequence of files keeps
/// archive attacks outside the public distribution format.
enum FloorpWebExtensionCatalogArchive {
    private static let magic: [UInt8] = [0x46, 0x57, 0x45, 0x41, 0x31, 0x0A]
    private static let maximumHeaderBytes = 1 * 1_024 * 1_024

    private struct FileEntry {
        let path: String
        let sha256: String
        let byteCount: Int
    }

    static func decode(
        _ data: Data,
        record: FloorpWebExtensionCatalogPackageRecord
    ) throws -> [String: Data] {
        guard data.count == record.artifactBytes,
              data.count >= magic.count + 4,
              data.count <= FloorpWebExtensionPackageStore.maximumPackageByteSize,
              Array(data.prefix(magic.count)) == magic else {
            throw FloorpWebExtensionCatalogError.artifactRejected("unsupported archive format")
        }
        guard FloorpWebExtensionArtifactDownloader.sha256(data) == record.artifactSHA256 else {
            throw FloorpWebExtensionCatalogError.artifactRejected("artifact digest mismatch")
        }
        let bytes = Array(data)
        let headerSize = Int(bytes[magic.count]) << 24 |
            Int(bytes[magic.count + 1]) << 16 |
            Int(bytes[magic.count + 2]) << 8 |
            Int(bytes[magic.count + 3])
        let payloadOffset = magic.count + 4
        guard headerSize > 0,
              headerSize <= maximumHeaderBytes,
              headerSize <= bytes.count - payloadOffset else {
            throw FloorpWebExtensionCatalogError.artifactRejected("invalid archive header length")
        }
        let header = try FloorpWebExtensionCanonicalJSON.parse(
            Data(bytes[payloadOffset..<(payloadOffset + headerSize)])
        )
        guard try FloorpWebExtensionCanonicalJSON.canonicalData(header) == Data(bytes[payloadOffset..<(payloadOffset + headerSize)]) else {
            throw FloorpWebExtensionCatalogError.artifactRejected("non-canonical archive header")
        }
        let entries = try parseHeader(header)
        var offset = payloadOffset + headerSize
        var resources = [String: Data]()
        for entry in entries {
            guard entry.byteCount <= bytes.count - offset else {
                throw FloorpWebExtensionCatalogError.artifactRejected("truncated archive entry")
            }
            let resource = Data(bytes[offset..<(offset + entry.byteCount)])
            guard FloorpWebExtensionArtifactDownloader.sha256(resource) == entry.sha256 else {
                throw FloorpWebExtensionCatalogError.artifactRejected("resource digest mismatch")
            }
            resources[entry.path] = resource
            offset += entry.byteCount
        }
        guard offset == bytes.count,
              let manifest = resources["manifest.json"],
              FloorpWebExtensionArtifactDownloader.sha256(manifest) == record.manifestSHA256,
              try inventoryDigest(entries) == record.resourceInventorySHA256 else {
            throw FloorpWebExtensionCatalogError.artifactRejected("manifest or inventory digest mismatch")
        }
        return resources
    }

    static func encodedArtifact(resources: [String: Data]) throws -> Data {
        guard !resources.isEmpty,
              resources.count <= FloorpWebExtensionPackageStore.maximumResourceCount else {
            throw FloorpWebExtensionCatalogError.artifactRejected("invalid archive resource count")
        }
        let sortedPaths = resources.keys.sorted(by: FloorpWebExtensionCanonicalJSON.utf8LessThan)
        var entries = [FileEntry]()
        var totalBytes = 0
        for path in sortedPaths {
            guard let resource = resources[path],
                  path == path.precomposedStringWithCanonicalMapping,
                  path.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
                  (try? FloorpWebExtensionScriptSource(path)) != nil,
                  resource.count <= FloorpWebExtensionManifest.maximumPackageResourceByteSize else {
                throw FloorpWebExtensionCatalogError.artifactRejected("unsafe archive resource")
            }
            totalBytes += resource.count
            guard totalBytes <= FloorpWebExtensionPackageStore.maximumPackageByteSize else {
                throw FloorpWebExtensionCatalogError.artifactRejected("expanded archive exceeds quota")
            }
            entries.append(.init(
                path: path,
                sha256: FloorpWebExtensionArtifactDownloader.sha256(resource),
                byteCount: resource.count
            ))
        }
        let header = try headerData(entries)
        guard header.count <= maximumHeaderBytes,
              header.count <= Int(UInt32.max) else {
            throw FloorpWebExtensionCatalogError.artifactRejected("archive header exceeds quota")
        }
        var output = Data(magic)
        let headerLength = UInt32(header.count)
        output.append(UInt8((headerLength >> 24) & 0xFF))
        output.append(UInt8((headerLength >> 16) & 0xFF))
        output.append(UInt8((headerLength >> 8) & 0xFF))
        output.append(UInt8(headerLength & 0xFF))
        output.append(header)
        for path in sortedPaths {
            guard let resource = resources[path] else { continue }
            output.append(resource)
        }
        return output
    }

    private static func parseHeader(
        _ value: FloorpWebExtensionCanonicalJSON.Value
    ) throws -> [FileEntry] {
        guard case .object(let object) = value,
              Set(object.keys) == Set(["files"]),
              case .array(let rawEntries) = object["files"],
              !rawEntries.isEmpty,
              rawEntries.count <= FloorpWebExtensionPackageStore.maximumResourceCount else {
            throw FloorpWebExtensionCatalogError.artifactRejected("invalid archive inventory")
        }
        var entries = [FileEntry]()
        var previousPath: String?
        var totalBytes = 0
        for value in rawEntries {
            guard case .object(let object) = value,
                  Set(object.keys) == Set(["path", "sha256", "size"]),
                  case .string(let path) = object["path"],
                  case .string(let digest) = object["sha256"],
                  case .integer(let size) = object["size"],
                  path == path.precomposedStringWithCanonicalMapping,
                  path.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
                  (try? FloorpWebExtensionScriptSource(path)) != nil,
                  digest.count == 64,
                  digest == digest.lowercased(),
                  digest.allSatisfy(\.isHexDigit),
                  size >= 0,
                  size <= Int64(FloorpWebExtensionManifest.maximumPackageResourceByteSize),
                  size <= Int64(Int.max) else {
                throw FloorpWebExtensionCatalogError.artifactRejected("unsafe archive inventory entry")
            }
            if let previousPath, !FloorpWebExtensionCanonicalJSON.utf8LessThan(previousPath, path) {
                throw FloorpWebExtensionCatalogError.artifactRejected("duplicate or unordered archive path")
            }
            let byteCount = Int(size)
            totalBytes += byteCount
            guard totalBytes <= FloorpWebExtensionPackageStore.maximumPackageByteSize else {
                throw FloorpWebExtensionCatalogError.artifactRejected("expanded archive exceeds quota")
            }
            entries.append(.init(path: path, sha256: digest, byteCount: byteCount))
            previousPath = path
        }
        return entries
    }

    private static func inventoryDigest(_ entries: [FileEntry]) throws -> String {
        FloorpWebExtensionArtifactDownloader.sha256(try headerData(entries))
    }

    private static func headerData(_ entries: [FileEntry]) throws -> Data {
        let files: [FloorpWebExtensionCanonicalJSON.Value] = entries.map { entry in
            .object([
                "path": .string(entry.path),
                "sha256": .string(entry.sha256),
                "size": .integer(Int64(entry.byteCount))
            ])
        }
        return try FloorpWebExtensionCanonicalJSON.canonicalData(.object(["files": .array(files)]))
    }
}

enum FloorpWebExtensionInternalCatalogReleaseGate {
    /// No caller in the production bootstrapper enables this flag. A release
    /// must supply P0 approval and a separate, reviewed composition before a
    /// managed endpoint, root key, or catalog UI can be connected.
    static func requireManagedSourceEnabled() throws {
        guard FloorpFlags.isWebExtensionFeatureEnabled(.managedRemoteSource) else {
            throw FloorpWebExtensionCatalogError.remoteCatalogDisabled
        }
    }
}

protocol FloorpWebExtensionCatalogAcceptanceStatePersisting: AnyObject, Sendable {
    func load(catalogID: String) throws -> FloorpWebExtensionCatalogAcceptanceState?
    func save(_ state: FloorpWebExtensionCatalogAcceptanceState) throws
}

/// Anti-rollback state is device-bound rather than ordinary profile data. A
/// private-browsing teardown therefore cannot erase the highest accepted
/// sequence and re-open an old catalog for installation.
final class FloorpWebExtensionCatalogKeychainStateStore: FloorpWebExtensionCatalogAcceptanceStatePersisting, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    init(service: String = "one.ablaze.floorp.webextensions.catalog-state") {
        self.service = service
    }

    func load(catalogID: String) throws -> FloorpWebExtensionCatalogAcceptanceState? {
        guard FloorpWebExtensionCatalogVerifier.isSafeIdentifier(catalogID, maximumLength: 96) else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid state catalog ID")
        }
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery(catalogID: catalogID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("catalog state cannot be read")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let state = try decoder.decode(FloorpWebExtensionCatalogAcceptanceState.self, from: data)
            guard state.catalogID == catalogID else {
                throw FloorpWebExtensionCatalogError.invalidCatalog("catalog state identity mismatch")
            }
            return state
        } catch let error as FloorpWebExtensionCatalogError {
            throw error
        } catch {
            throw FloorpWebExtensionCatalogError.invalidCatalog("catalog state is malformed")
        }
    }

    func save(_ state: FloorpWebExtensionCatalogAcceptanceState) throws {
        guard FloorpWebExtensionCatalogVerifier.isSafeIdentifier(state.catalogID, maximumLength: 96),
              state.highestSequence > 0 else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("invalid catalog state")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= 256 * 1_024 else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("catalog state exceeds quota")
        }
        lock.lock()
        defer { lock.unlock() }
        let query = baseQuery(catalogID: state.catalogID)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("catalog state cannot be saved")
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw FloorpWebExtensionCatalogError.invalidCatalog("catalog state cannot be created")
        }
    }

    private func baseQuery(catalogID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: catalogID
        ]
    }
}

/// Serializes the complete read/verify/revoke/save lifecycle for every
/// catalog coordinator in this process. `@MainActor` alone is insufficient:
/// it becomes re-entrant at the package-manager await points.
private actor FloorpWebExtensionCatalogLifecycleAcceptanceGate {
    static let shared = FloorpWebExtensionCatalogLifecycleAcceptanceGate()

    private var isLocked = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// P0-gated catalog acceptance which makes durable anti-rollback state and
/// live revocation one transaction boundary. It accepts bytes that a separate
/// fixed-endpoint transport already fetched; it has no URL, import, or share
/// sheet API. If a live package cannot be stopped, no newer catalog state is
/// committed, so the caller must retry rather than treating revocation as
/// successfully applied.
@MainActor
final class FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator {
    typealias PackageManagerProvider = @MainActor @Sendable () -> [FloorpWebExtensionLivePackageManager]

    private let verifier: FloorpWebExtensionCatalogVerifier
    private let stateStore: FloorpWebExtensionCatalogAcceptanceStatePersisting
    private let packageManagers: PackageManagerProvider

    init(
        verifier: FloorpWebExtensionCatalogVerifier,
        stateStore: FloorpWebExtensionCatalogAcceptanceStatePersisting,
        packageManagers: @escaping PackageManagerProvider = {
            FloorpWebExtensionPackageStoreRegistry.catalogRevocationManagers()
        }
    ) {
        self.verifier = verifier
        self.stateStore = stateStore
        self.packageManagers = packageManagers
    }

    func acceptAndApplyRevocations(
        catalogData: Data,
        now: Date = Date()
    ) async throws -> FloorpWebExtensionCatalogVerificationResult {
        try FloorpWebExtensionInternalCatalogReleaseGate.requireManagedSourceEnabled()
        let gate = FloorpWebExtensionCatalogLifecycleAcceptanceGate.shared
        await gate.acquire()
        defer { Task { await gate.release() } }
        let previous = try stateStore.load(catalogID: verifier.configuration.catalogID)
        let result = try verifier.verify(
            catalogData: catalogData,
            previousState: previous,
            now: now
        )
        for packageManager in packageManagers() {
            try await packageManager.applySignedCatalogAcceptanceState(
                result.catalog.nextAcceptanceState
            )
        }
        try stateStore.save(result.catalog.nextAcceptanceState)
        return result
    }

    /// Installs only an artifact selected by the currently accepted catalog.
    /// An artifact that was downloaded before a subsequent acceptance (for
    /// example, before a key/generation revocation) is rejected rather than
    /// being allowed to race the kill switch.
    func installVerifiedCatalogPackage(
        _ artifact: FloorpWebExtensionVerifiedCatalogArtifact,
        packageManager: FloorpWebExtensionLivePackageManager,
        initialGrants: FloorpWebExtensionPermissionSnapshot? = nil,
        updateAuthorization: FloorpWebExtensionLivePackageManager.CatalogUpdateAuthorization? = nil
    ) async throws {
        try FloorpWebExtensionInternalCatalogReleaseGate.requireManagedSourceEnabled()
        let gate = FloorpWebExtensionCatalogLifecycleAcceptanceGate.shared
        await gate.acquire()
        defer { Task { await gate.release() } }

        let state = try stateStore.load(catalogID: verifier.configuration.catalogID)
        guard catalogState(state, authorizes: artifact) else {
            throw FloorpWebExtensionCatalogError.revoked
        }
        try await packageManager.installVerifiedCatalogPackage(
            artifact,
            catalogAuthorization: .init(artifact: artifact),
            initialGrants: initialGrants,
            updateAuthorization: updateAuthorization
        )
    }

    /// A P0 composition injects this method into every normal/private live
    /// manager. It also protects a restart where a catalog package remains on
    /// disk but the latest accepted state has revoked it.
    func authorizeInstalledCatalogRecord(
        _ record: FloorpWebExtensionCatalogPackageRecord
    ) throws {
        let state = try stateStore.load(catalogID: verifier.configuration.catalogID)
        guard catalogState(state, authorizes: record) else {
            throw FloorpWebExtensionCatalogError.revoked
        }
    }

    private func catalogState(
        _ state: FloorpWebExtensionCatalogAcceptanceState?,
        authorizes artifact: FloorpWebExtensionVerifiedCatalogArtifact
    ) -> Bool {
        guard artifact.catalogID == verifier.configuration.catalogID,
              artifact.catalogSequence == state?.highestSequence else {
            return false
        }
        return catalogState(state, authorizes: artifact.record)
    }

    /// A persisted package record carries only its immutable record, not a
    /// cached catalog response. The device-bound acceptance state must still
    /// prove the exact generation/digest binding before startup or re-enable;
    /// otherwise a locally forged or stale record could become executable.
    private func catalogState(
        _ state: FloorpWebExtensionCatalogAcceptanceState?,
        authorizes record: FloorpWebExtensionCatalogPackageRecord
    ) -> Bool {
        guard let state,
              state.catalogID == verifier.configuration.catalogID else {
            return false
        }
        let generation = FloorpWebExtensionCatalogGeneration(
            extensionID: record.extensionID,
            generation: record.generation
        )
        let binding = FloorpWebExtensionCatalogGenerationArtifactDigest(
            catalogGeneration: generation,
            artifactSHA256: record.artifactSHA256,
            signingKeyID: record.signingKeyID
        )
        return state.acceptedGenerationArtifacts.contains(binding) &&
            !state.revokedKeyIDs.contains(record.signingKeyID) &&
            !state.revokedGenerations.contains(generation)
    }
}
