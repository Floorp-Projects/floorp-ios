// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Darwin
import Foundation

/// A versioned, reproducible performance-run record for the Stage 3 MV3
/// implementation. This intentionally does not replace the compact
/// `FloorpWebExtensionPerformanceEvidence` compatibility-v1 summary.
struct FloorpWebExtensionStage3PerformanceEvidence: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let runIdentifier: String
    let associatedSourceRevision: String
    let recordedAt: Date
    let build: FloorpWebExtensionPerformanceBuildEvidence
    let device: FloorpWebExtensionPerformanceDeviceEvidence
    let fixture: FloorpWebExtensionPerformanceFixtureEvidence
    let measurementProtocol: FloorpWebExtensionPerformanceProtocolEvidence
    let compileSpans: FloorpWebExtensionPerformanceCompileSpans
    let pageLoad: FloorpWebExtensionPerformancePageLoadEvidence
    let memory: FloorpWebExtensionPerformanceMemoryEvidence
    let functionalChecks: [FloorpWebExtensionPerformanceFunctionalCheck]
    let artifacts: [FloorpWebExtensionPerformanceArtifact]
    let failures: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, runIdentifier, associatedSourceRevision, recordedAt
        case build, device, fixture, measurementProtocol, compileSpans, pageLoad, memory
        case functionalChecks, artifacts, failures
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        runIdentifier: String,
        associatedSourceRevision: String,
        recordedAt: Date = Date(),
        build: FloorpWebExtensionPerformanceBuildEvidence,
        device: FloorpWebExtensionPerformanceDeviceEvidence,
        fixture: FloorpWebExtensionPerformanceFixtureEvidence,
        measurementProtocol: FloorpWebExtensionPerformanceProtocolEvidence,
        compileSpans: FloorpWebExtensionPerformanceCompileSpans,
        pageLoad: FloorpWebExtensionPerformancePageLoadEvidence,
        memory: FloorpWebExtensionPerformanceMemoryEvidence,
        functionalChecks: [FloorpWebExtensionPerformanceFunctionalCheck],
        artifacts: [FloorpWebExtensionPerformanceArtifact],
        failures: [String]
    ) throws {
        self.schemaVersion = schemaVersion
        self.runIdentifier = runIdentifier
        self.associatedSourceRevision = associatedSourceRevision.lowercased()
        self.recordedAt = recordedAt
        self.build = build
        self.device = device
        self.fixture = fixture
        self.measurementProtocol = measurementProtocol
        self.compileSpans = compileSpans
        self.pageLoad = pageLoad
        self.memory = memory
        self.functionalChecks = functionalChecks
        self.artifacts = artifacts
        self.failures = failures
        try validate()
    }

    init(from decoder: Decoder) throws {
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(
            decoder,
            CodingKeys.self,
            scope: "Stage 3 performance evidence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            runIdentifier: container.decode(String.self, forKey: .runIdentifier),
            associatedSourceRevision: container.decode(String.self, forKey: .associatedSourceRevision),
            recordedAt: container.decode(Date.self, forKey: .recordedAt),
            build: container.decode(FloorpWebExtensionPerformanceBuildEvidence.self, forKey: .build),
            device: container.decode(FloorpWebExtensionPerformanceDeviceEvidence.self, forKey: .device),
            fixture: container.decode(FloorpWebExtensionPerformanceFixtureEvidence.self, forKey: .fixture),
            // swiftlint:disable:next line_length
            measurementProtocol: container.decode(FloorpWebExtensionPerformanceProtocolEvidence.self, forKey: .measurementProtocol),
            compileSpans: container.decode(FloorpWebExtensionPerformanceCompileSpans.self, forKey: .compileSpans),
            pageLoad: container.decode(FloorpWebExtensionPerformancePageLoadEvidence.self, forKey: .pageLoad),
            memory: container.decode(FloorpWebExtensionPerformanceMemoryEvidence.self, forKey: .memory),
            // swiftlint:disable:next line_length
            functionalChecks: container.decode([FloorpWebExtensionPerformanceFunctionalCheck].self, forKey: .functionalChecks),
            artifacts: container.decode([FloorpWebExtensionPerformanceArtifact].self, forKey: .artifacts),
            failures: container.decode([String].self, forKey: .failures)
        )
    }

    fileprivate func validate() throws {
        let checkIdentifiers = functionalChecks.map(\.identifier)
        let unsuccessfulRun = !fixture.integrityVerified ||
            !memory.recoverySucceeded ||
            !memory.postRecoveryFunctionalCheckPassed ||
            functionalChecks.contains(where: { !$0.passed })

        guard schemaVersion == Self.currentSchemaVersion,
              FloorpWebExtensionPerformanceEvidenceValidation.isSafeIdentifier(runIdentifier, maximumLength: 128),
              FloorpWebExtensionPerformanceEvidenceValidation.isRevision(associatedSourceRevision),
              recordedAt.timeIntervalSinceReferenceDate.isFinite,
              (0...32_503_680_000).contains(recordedAt.timeIntervalSince1970),
              measurementProtocol.compileSampleCount == compileSpans.sampleCount,
              measurementProtocol.pageSampleCount == pageLoad.sampleCount,
              (1...128).contains(functionalChecks.count),
              Set(checkIdentifiers).count == checkIdentifiers.count,
              (1...FloorpWebExtensionPerformanceArtifactKind.allCases.count).contains(artifacts.count),
              Set(artifacts.map(\.relativePath)).count == artifacts.count,
              Set(artifacts.map(\.kind)).count == artifacts.count,
              failures.count <= 128,
              Set(failures).count == failures.count,
              // swiftlint:disable:next line_length
              failures.allSatisfy({ FloorpWebExtensionPerformanceEvidenceValidation.isSafeLogText($0, maximumLength: 4_096) }),
              memory.recoverySucceeded || !memory.postRecoveryFunctionalCheckPassed,
              !unsuccessfulRun || !failures.isEmpty else {
            throw FloorpWebExtensionError.unsupported("invalid Stage 3 performance evidence")
        }
    }
}

/// A content-addressed entry in a Stage 3 performance run's artifact
/// manifest. The manifest deliberately records relative paths: callers can
/// relocate a complete evidence directory without weakening its binding.
struct FloorpWebExtensionPerformanceArtifact: Codable, Equatable, Sendable {
    /// Upper bound used by generic validated-snapshot readers. Individual
    /// artifact kinds use narrower limits below; no caller may request more
    /// than the largest supported binary artifact.
    static let maximumByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024

    let relativePath: String
    let kind: FloorpWebExtensionPerformanceArtifactKind
    let sha256: String
    let byteCount: Int64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case relativePath, kind, sha256, byteCount
    }

    init(
        relativePath: String,
        kind: FloorpWebExtensionPerformanceArtifactKind,
        sha256: String,
        byteCount: Int64
    ) throws {
        guard FloorpWebExtensionPerformanceEvidenceValidation.isSafeArtifactPath(relativePath),
              FloorpWebExtensionPerformanceEvidenceValidation.isSHA256(sha256),
              (1...kind.maximumByteCount).contains(byteCount) else {
            throw FloorpWebExtensionError.unsupported("invalid performance artifact manifest entry")
        }
        self.relativePath = relativePath
        self.kind = kind
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
    }

    init(from decoder: Decoder) throws {
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(
            decoder,
            CodingKeys.self,
            scope: "performance artifact"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relativePath: container.decode(String.self, forKey: .relativePath),
            kind: container.decode(FloorpWebExtensionPerformanceArtifactKind.self, forKey: .kind),
            sha256: container.decode(String.self, forKey: .sha256),
            byteCount: container.decode(Int64.self, forKey: .byteCount)
        )
    }
}

enum FloorpWebExtensionPerformanceArtifactKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// The XCTest result bundle (or its deterministic archive) containing the
    /// functional checks associated with the performance run.
    case testResultBundle = "xcresult"

    /// The ETTrace/Instruments profile used to inspect launch and runtime cost.
    case performanceProfile = "performance-profile"

    /// Raw machine-readable samples from which the evidence statistics were
    /// derived. This is separate from the self-describing evidence summary.
    case measurementRecord = "measurement-record"

    /// These limits apply to compressed, archived evidence bytes. They are
    /// deliberately generous for the focused Stage 3 run while bounding the
    /// disk work performed before trusted semantic tooling sees an artifact.
    var maximumByteCount: Int64 {
        switch self {
        case .testResultBundle:
            return 1 * 1_024 * 1_024 * 1_024
        case .performanceProfile:
            return 2 * 1_024 * 1_024 * 1_024
        case .measurementRecord:
            return 4 * 1_024 * 1_024
        }
    }
}

struct FloorpWebExtensionPerformanceArtifactValidatedSnapshot {
    static let maximumStreamingChunkByteCount = 1_048_576
    private static let maximumInMemoryByteCount: Int64 = 4 * 1_024 * 1_024

    let artifactKind: FloorpWebExtensionPerformanceArtifactKind
    let relativePath: String
    let sha256: String
    let byteCount: Int64

    /// This read-only descriptor is opened on a private, unlinked snapshot of
    /// the exact bytes whose digest was checked. Validators inspect it through
    /// the bounded chunk stream and never reopen the original path.
    fileprivate let fileHandle: FileHandle

    /// Streams the complete validated snapshot through a fixed-size buffer.
    /// Semantic validators can inspect multi-gigabyte binary artifacts without
    /// making their manifest limit an equally large in-memory allocation.
    func forEachDataChunk(
        _ consume: (Data) throws -> Void
    ) throws {
        try fileHandle.seek(toOffset: 0)
        defer { try? fileHandle.seek(toOffset: 0) }

        var streamedByteCount: Int64 = 0
        while let chunk = try fileHandle.read(
            upToCount: Self.maximumStreamingChunkByteCount
        ), !chunk.isEmpty {
            let (updatedByteCount, overflowed) = streamedByteCount.addingReportingOverflow(
                Int64(chunk.count)
            )
            guard !overflowed,
                  chunk.count <= Self.maximumStreamingChunkByteCount,
                  updatedByteCount <= byteCount,
                  updatedByteCount <= artifactKind.maximumByteCount else {
                throw FloorpWebExtensionError.unsupported(
                    "validated artifact snapshot exceeds the streaming limit"
                )
            }
            streamedByteCount = updatedByteCount
            try consume(chunk)
        }
        guard streamedByteCount == byteCount else {
            throw FloorpWebExtensionError.unsupported("validated artifact snapshot was truncated")
        }
    }

    /// Only the bounded JSON measurement record is materialized as one value.
    /// Binary semantic validators intentionally cannot call this fileprivate API.
    fileprivate func readSmallData(maximumByteCount: Int64) throws -> Data {
        guard byteCount <= maximumByteCount,
              maximumByteCount > 0,
              maximumByteCount <= Self.maximumInMemoryByteCount else {
            throw FloorpWebExtensionError.unsupported(
                "validated artifact snapshot exceeds the in-memory read limit"
            )
        }
        var data = Data()
        data.reserveCapacity(Int(byteCount))
        try forEachDataChunk { data.append($0) }
        return data
    }
}

struct FloorpWebExtensionPerformanceArtifactSemanticAttestation: Equatable, Sendable {
    let artifactKind: FloorpWebExtensionPerformanceArtifactKind
    let runIdentifier: String
    let associatedSourceRevision: String
    let sha256: String
    let byteCount: Int64

    init(
        artifactKind: FloorpWebExtensionPerformanceArtifactKind,
        runIdentifier: String,
        associatedSourceRevision: String,
        sha256: String,
        byteCount: Int64
    ) throws {
        guard artifactKind != .measurementRecord,
              FloorpWebExtensionPerformanceEvidenceValidation.isSafeIdentifier(runIdentifier, maximumLength: 128),
              FloorpWebExtensionPerformanceEvidenceValidation.isRevision(associatedSourceRevision),
              FloorpWebExtensionPerformanceEvidenceValidation.isSHA256(sha256),
              (1...artifactKind.maximumByteCount).contains(byteCount) else {
            throw FloorpWebExtensionError.unsupported("invalid performance artifact semantic attestation")
        }
        self.artifactKind = artifactKind
        self.runIdentifier = runIdentifier
        self.associatedSourceRevision = associatedSourceRevision.lowercased()
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
    }
}

/// Complete acceptance deliberately delegates binary artifact semantics to a
/// trusted release-tooling boundary. Implementations must parse the xcresult
/// with `xcresulttool` and the captured trace with its owning profiler; file
/// names, ZIP entries, and self-asserted JSON are not semantic evidence.
protocol FloorpWebExtensionPerformanceArtifactSemanticValidating {
    func validateArtifact(
        _ snapshot: FloorpWebExtensionPerformanceArtifactValidatedSnapshot,
        evidence: FloorpWebExtensionStage3PerformanceEvidence
    ) throws -> FloorpWebExtensionPerformanceArtifactSemanticAttestation
}

private struct FloorpWebExtensionPerformanceMeasurementRecord: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let artifactKind: FloorpWebExtensionPerformanceArtifactKind
    let runIdentifier: String
    let associatedSourceRevision: String
    let evidenceSchemaVersion: Int
    let recordedAt: Date
    let build: FloorpWebExtensionPerformanceBuildEvidence
    let device: FloorpWebExtensionPerformanceDeviceEvidence
    let fixture: FloorpWebExtensionPerformanceFixtureEvidence
    let measurementProtocol: FloorpWebExtensionPerformanceProtocolEvidence
    let compileSpans: FloorpWebExtensionPerformanceCompileSpans
    let pageLoad: FloorpWebExtensionPerformancePageLoadEvidence
    let memory: FloorpWebExtensionPerformanceMemoryEvidence
    let functionalChecks: [FloorpWebExtensionPerformanceFunctionalCheck]
    let failures: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, artifactKind, runIdentifier, associatedSourceRevision
        case evidenceSchemaVersion, recordedAt, build, device, fixture, measurementProtocol
        case compileSpans, pageLoad, memory, functionalChecks, failures
    }

    init(evidence: FloorpWebExtensionStage3PerformanceEvidence) {
        schemaVersion = Self.currentSchemaVersion
        artifactKind = .measurementRecord
        runIdentifier = evidence.runIdentifier
        associatedSourceRevision = evidence.associatedSourceRevision
        evidenceSchemaVersion = evidence.schemaVersion
        recordedAt = evidence.recordedAt
        build = evidence.build
        device = evidence.device
        fixture = evidence.fixture
        measurementProtocol = evidence.measurementProtocol
        compileSpans = evidence.compileSpans
        pageLoad = evidence.pageLoad
        memory = evidence.memory
        functionalChecks = evidence.functionalChecks
        failures = evidence.failures
    }

    init(from decoder: Decoder) throws {
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(
            decoder,
            CodingKeys.self,
            scope: "performance measurement record"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        artifactKind = try container.decode(FloorpWebExtensionPerformanceArtifactKind.self, forKey: .artifactKind)
        runIdentifier = try container.decode(String.self, forKey: .runIdentifier)
        associatedSourceRevision = try container.decode(String.self, forKey: .associatedSourceRevision).lowercased()
        evidenceSchemaVersion = try container.decode(Int.self, forKey: .evidenceSchemaVersion)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        build = try container.decode(FloorpWebExtensionPerformanceBuildEvidence.self, forKey: .build)
        device = try container.decode(FloorpWebExtensionPerformanceDeviceEvidence.self, forKey: .device)
        fixture = try container.decode(FloorpWebExtensionPerformanceFixtureEvidence.self, forKey: .fixture)
        // swiftlint:disable:next line_length
        measurementProtocol = try container.decode(FloorpWebExtensionPerformanceProtocolEvidence.self, forKey: .measurementProtocol)
        compileSpans = try container.decode(FloorpWebExtensionPerformanceCompileSpans.self, forKey: .compileSpans)
        pageLoad = try container.decode(FloorpWebExtensionPerformancePageLoadEvidence.self, forKey: .pageLoad)
        memory = try container.decode(FloorpWebExtensionPerformanceMemoryEvidence.self, forKey: .memory)
        // swiftlint:disable:next line_length
        functionalChecks = try container.decode([FloorpWebExtensionPerformanceFunctionalCheck].self, forKey: .functionalChecks)
        failures = try container.decode([String].self, forKey: .failures)
        try validate()
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              artifactKind == .measurementRecord,
              FloorpWebExtensionPerformanceEvidenceValidation.isSafeIdentifier(runIdentifier, maximumLength: 128),
              FloorpWebExtensionPerformanceEvidenceValidation.isRevision(associatedSourceRevision),
              evidenceSchemaVersion == FloorpWebExtensionStage3PerformanceEvidence.currentSchemaVersion,
              recordedAt.timeIntervalSinceReferenceDate.isFinite,
              (1...128).contains(functionalChecks.count),
              failures.count <= 128 else {
            throw FloorpWebExtensionError.unsupported("invalid performance measurement record")
        }
    }
}

struct FloorpWebExtensionPerformanceBuildEvidence: Codable, Equatable, Sendable {
    let buildIdentifier: String
    let configuration: String
    let appVersion: String
    let appBuildNumber: String
    let xcodeVersion: String
    let swiftVersion: String
    let sdkName: String
    let sdkBuild: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case buildIdentifier, configuration, appVersion, appBuildNumber
        case xcodeVersion, swiftVersion, sdkName, sdkBuild
    }

    init(
        buildIdentifier: String,
        configuration: String,
        appVersion: String,
        appBuildNumber: String,
        xcodeVersion: String,
        swiftVersion: String,
        sdkName: String,
        sdkBuild: String
    ) throws {
        // swiftlint:disable:next line_length
        let values = [buildIdentifier, configuration, appVersion, appBuildNumber, xcodeVersion, swiftVersion, sdkName, sdkBuild]
        // swiftlint:disable:next line_length
        guard values.allSatisfy({ FloorpWebExtensionPerformanceEvidenceValidation.isSafeText($0, maximumLength: 256) }) else {
            throw FloorpWebExtensionError.unsupported("invalid performance build evidence")
        }
        self.buildIdentifier = buildIdentifier
        self.configuration = configuration
        self.appVersion = appVersion
        self.appBuildNumber = appBuildNumber
        self.xcodeVersion = xcodeVersion
        self.swiftVersion = swiftVersion
        self.sdkName = sdkName
        self.sdkBuild = sdkBuild
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "build evidence")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            buildIdentifier: container.decode(String.self, forKey: .buildIdentifier),
            configuration: container.decode(String.self, forKey: .configuration),
            appVersion: container.decode(String.self, forKey: .appVersion),
            appBuildNumber: container.decode(String.self, forKey: .appBuildNumber),
            xcodeVersion: container.decode(String.self, forKey: .xcodeVersion),
            swiftVersion: container.decode(String.self, forKey: .swiftVersion),
            sdkName: container.decode(String.self, forKey: .sdkName),
            sdkBuild: container.decode(String.self, forKey: .sdkBuild)
        )
    }
}

struct FloorpWebExtensionPerformanceDeviceEvidence: Codable, Equatable, Sendable {
    let model: String
    let identifier: String
    let operatingSystem: String
    let operatingSystemBuild: String
    let architecture: String
    let isSimulator: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case model, identifier, operatingSystem, operatingSystemBuild, architecture, isSimulator
    }

    init(
        model: String,
        identifier: String,
        operatingSystem: String,
        operatingSystemBuild: String,
        architecture: String,
        isSimulator: Bool
    ) throws {
        guard FloorpWebExtensionPerformanceEvidenceValidation.isSafeText(model, maximumLength: 256),
              FloorpWebExtensionPerformanceEvidenceValidation.isSafeIdentifier(identifier, maximumLength: 128),
              FloorpWebExtensionPerformanceEvidenceValidation.isOperatingSystem(operatingSystem),
              FloorpWebExtensionPerformanceEvidenceValidation.isSafeText(operatingSystemBuild, maximumLength: 128),
              FloorpWebExtensionPerformanceEvidenceValidation.isSafeIdentifier(architecture, maximumLength: 64) else {
            throw FloorpWebExtensionError.unsupported("invalid performance device evidence")
        }
        self.model = model
        self.identifier = identifier
        self.operatingSystem = operatingSystem
        self.operatingSystemBuild = operatingSystemBuild
        self.architecture = architecture
        self.isSimulator = isSimulator
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "device evidence")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            model: container.decode(String.self, forKey: .model),
            identifier: container.decode(String.self, forKey: .identifier),
            operatingSystem: container.decode(String.self, forKey: .operatingSystem),
            operatingSystemBuild: container.decode(String.self, forKey: .operatingSystemBuild),
            architecture: container.decode(String.self, forKey: .architecture),
            isSimulator: container.decode(Bool.self, forKey: .isSimulator)
        )
    }
}

struct FloorpWebExtensionPerformanceFixtureEvidence: Codable, Equatable, Sendable {
    let identifier: String
    let version: String
    let packageSHA256: String
    let integrityVerified: Bool
    let staticRuleCount: Int
    let dynamicRuleCount: Int
    let sessionRuleCount: Int
    let totalRuleCount: Int
    let enabledRuleCount: Int
    let transformedRuleCount: Int
    let rejectedRuleCount: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier, version, packageSHA256, integrityVerified
        case staticRuleCount, dynamicRuleCount, sessionRuleCount, totalRuleCount, enabledRuleCount
        case transformedRuleCount, rejectedRuleCount
    }

    init(
        identifier: String,
        version: String,
        packageSHA256: String,
        integrityVerified: Bool,
        staticRuleCount: Int,
        dynamicRuleCount: Int,
        sessionRuleCount: Int,
        totalRuleCount: Int,
        enabledRuleCount: Int,
        transformedRuleCount: Int,
        rejectedRuleCount: Int
    ) throws {
        let ruleCounts = [
            staticRuleCount, dynamicRuleCount, sessionRuleCount, totalRuleCount,
            enabledRuleCount, transformedRuleCount, rejectedRuleCount
        ]
        let (staticAndDynamic, overflow1) = staticRuleCount.addingReportingOverflow(dynamicRuleCount)
        let (recomputedTotal, overflow2) = staticAndDynamic.addingReportingOverflow(sessionRuleCount)
        let (recomputedCompilerTotal, overflow3) = transformedRuleCount.addingReportingOverflow(rejectedRuleCount)
        guard FloorpWebExtensionPerformanceEvidenceValidation.isSafeIdentifier(identifier, maximumLength: 256),
              FloorpWebExtensionPerformanceEvidenceValidation.isSafeText(version, maximumLength: 128),
              FloorpWebExtensionPerformanceEvidenceValidation.isSHA256(packageSHA256),
              ruleCounts.allSatisfy({ (0...1_000_000).contains($0) }),
              !overflow1,
              !overflow2,
              !overflow3,
              totalRuleCount == recomputedTotal,
              totalRuleCount == recomputedCompilerTotal,
              enabledRuleCount <= transformedRuleCount else {
            throw FloorpWebExtensionError.unsupported("invalid performance fixture evidence")
        }
        self.identifier = identifier
        self.version = version
        self.packageSHA256 = packageSHA256.lowercased()
        self.integrityVerified = integrityVerified
        self.staticRuleCount = staticRuleCount
        self.dynamicRuleCount = dynamicRuleCount
        self.sessionRuleCount = sessionRuleCount
        self.totalRuleCount = totalRuleCount
        self.enabledRuleCount = enabledRuleCount
        self.transformedRuleCount = transformedRuleCount
        self.rejectedRuleCount = rejectedRuleCount
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "fixture evidence")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: container.decode(String.self, forKey: .identifier),
            version: container.decode(String.self, forKey: .version),
            packageSHA256: container.decode(String.self, forKey: .packageSHA256),
            integrityVerified: container.decode(Bool.self, forKey: .integrityVerified),
            staticRuleCount: container.decode(Int.self, forKey: .staticRuleCount),
            dynamicRuleCount: container.decode(Int.self, forKey: .dynamicRuleCount),
            sessionRuleCount: container.decode(Int.self, forKey: .sessionRuleCount),
            totalRuleCount: container.decode(Int.self, forKey: .totalRuleCount),
            enabledRuleCount: container.decode(Int.self, forKey: .enabledRuleCount),
            transformedRuleCount: container.decode(Int.self, forKey: .transformedRuleCount),
            rejectedRuleCount: container.decode(Int.self, forKey: .rejectedRuleCount)
        )
    }
}

struct FloorpWebExtensionPerformanceProtocolEvidence: Codable, Equatable, Sendable {
    let measurementClock: String
    let resetBetweenColdSamples: String
    let resetBetweenWarmSamples: String
    let resetBetweenPageSamples: String
    let coldCacheState: String
    let warmCacheState: String
    let pageCacheState: String
    let sampleOrder: String
    let warmupSampleCount: Int
    let compileSampleCount: Int
    let pageSampleCount: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case measurementClock, resetBetweenColdSamples, resetBetweenWarmSamples, resetBetweenPageSamples
        case coldCacheState, warmCacheState, pageCacheState, sampleOrder
        case warmupSampleCount, compileSampleCount, pageSampleCount
    }

    init(
        measurementClock: String,
        resetBetweenColdSamples: String,
        resetBetweenWarmSamples: String,
        resetBetweenPageSamples: String,
        coldCacheState: String,
        warmCacheState: String,
        pageCacheState: String,
        sampleOrder: String,
        warmupSampleCount: Int,
        compileSampleCount: Int,
        pageSampleCount: Int
    ) throws {
        let details = [
            measurementClock, resetBetweenColdSamples, resetBetweenWarmSamples,
            resetBetweenPageSamples, coldCacheState, warmCacheState, pageCacheState, sampleOrder
        ]
        guard details.allSatisfy({ FloorpWebExtensionPerformanceEvidenceValidation.isSafeText($0, maximumLength: 1_024) }),
              (0...1_000).contains(warmupSampleCount),
              (1...10_000).contains(compileSampleCount),
              (1...10_000).contains(pageSampleCount) else {
            throw FloorpWebExtensionError.unsupported("invalid performance measurement protocol")
        }
        self.measurementClock = measurementClock
        self.resetBetweenColdSamples = resetBetweenColdSamples
        self.resetBetweenWarmSamples = resetBetweenWarmSamples
        self.resetBetweenPageSamples = resetBetweenPageSamples
        self.coldCacheState = coldCacheState
        self.warmCacheState = warmCacheState
        self.pageCacheState = pageCacheState
        self.sampleOrder = sampleOrder
        self.warmupSampleCount = warmupSampleCount
        self.compileSampleCount = compileSampleCount
        self.pageSampleCount = pageSampleCount
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "measurement protocol")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            measurementClock: container.decode(String.self, forKey: .measurementClock),
            resetBetweenColdSamples: container.decode(String.self, forKey: .resetBetweenColdSamples),
            resetBetweenWarmSamples: container.decode(String.self, forKey: .resetBetweenWarmSamples),
            resetBetweenPageSamples: container.decode(String.self, forKey: .resetBetweenPageSamples),
            coldCacheState: container.decode(String.self, forKey: .coldCacheState),
            warmCacheState: container.decode(String.self, forKey: .warmCacheState),
            pageCacheState: container.decode(String.self, forKey: .pageCacheState),
            sampleOrder: container.decode(String.self, forKey: .sampleOrder),
            warmupSampleCount: container.decode(Int.self, forKey: .warmupSampleCount),
            compileSampleCount: container.decode(Int.self, forKey: .compileSampleCount),
            pageSampleCount: container.decode(Int.self, forKey: .pageSampleCount)
        )
    }
}

struct FloorpWebExtensionPerformanceStatistics: Codable, Equatable, Sendable {
    let sampleCount: Int
    let minimum: Double
    let maximum: Double
    let mean: Double
    let median: Double
    let percentile95: Double
    let populationStandardDeviation: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sampleCount, minimum, maximum, mean, median, percentile95, populationStandardDeviation
    }

    fileprivate init(samples: [Double]) {
        let sorted = samples.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        let mean = sum / Double(count)
        let median: Double
        if count.isMultiple(of: 2) {
            median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        } else {
            median = sorted[count / 2]
        }
        let variance = sorted.reduce(0) { partial, sample in
            let distance = sample - mean
            return partial + distance * distance
        } / Double(count)
        let percentileIndex = max(0, Int(ceil(Double(count) * 0.95)) - 1)

        sampleCount = count
        minimum = sorted[0]
        maximum = sorted[count - 1]
        self.mean = mean
        self.median = median
        percentile95 = sorted[percentileIndex]
        populationStandardDeviation = variance.squareRoot()
    }

    private init(
        sampleCount: Int,
        minimum: Double,
        maximum: Double,
        mean: Double,
        median: Double,
        percentile95: Double,
        populationStandardDeviation: Double
    ) {
        self.sampleCount = sampleCount
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
        self.median = median
        self.percentile95 = percentile95
        self.populationStandardDeviation = populationStandardDeviation
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "performance statistics")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sampleCount: try container.decode(Int.self, forKey: .sampleCount),
            minimum: try container.decode(Double.self, forKey: .minimum),
            maximum: try container.decode(Double.self, forKey: .maximum),
            mean: try container.decode(Double.self, forKey: .mean),
            median: try container.decode(Double.self, forKey: .median),
            percentile95: try container.decode(Double.self, forKey: .percentile95),
            populationStandardDeviation: try container.decode(Double.self, forKey: .populationStandardDeviation)
        )
    }

    fileprivate func matches(_ expected: Self) -> Bool {
        sampleCount == expected.sampleCount &&
            FloorpWebExtensionPerformanceEvidenceValidation.equal(minimum, expected.minimum) &&
            FloorpWebExtensionPerformanceEvidenceValidation.equal(maximum, expected.maximum) &&
            FloorpWebExtensionPerformanceEvidenceValidation.equal(mean, expected.mean) &&
            FloorpWebExtensionPerformanceEvidenceValidation.equal(median, expected.median) &&
            FloorpWebExtensionPerformanceEvidenceValidation.equal(percentile95, expected.percentile95) &&
            FloorpWebExtensionPerformanceEvidenceValidation.equal(
                populationStandardDeviation,
                expected.populationStandardDeviation
            )
    }
}

struct FloorpWebExtensionPerformanceSampleSeries: Codable, Equatable, Sendable {
    let samplesMilliseconds: [Double]
    let statistics: FloorpWebExtensionPerformanceStatistics

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case samplesMilliseconds, statistics
    }

    init(samplesMilliseconds: [Double]) throws {
        guard FloorpWebExtensionPerformanceEvidenceValidation.areSafeSamples(samplesMilliseconds) else {
            throw FloorpWebExtensionError.unsupported("invalid performance samples")
        }
        self.samplesMilliseconds = samplesMilliseconds
        statistics = FloorpWebExtensionPerformanceStatistics(samples: samplesMilliseconds)
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "sample series")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let samples = try container.decode([Double].self, forKey: .samplesMilliseconds)
        let suppliedStatistics = try container.decode(FloorpWebExtensionPerformanceStatistics.self, forKey: .statistics)
        try self.init(samplesMilliseconds: samples)
        guard suppliedStatistics.matches(statistics) else {
            throw FloorpWebExtensionError.unsupported("performance statistics do not match raw samples")
        }
    }
}

struct FloorpWebExtensionPerformanceCompileSpans: Codable, Equatable, Sendable {
    let nativeCold: FloorpWebExtensionPerformanceSampleSeries
    let nativeWarm: FloorpWebExtensionPerformanceSampleSeries
    let webKitCold: FloorpWebExtensionPerformanceSampleSeries
    let webKitWarm: FloorpWebExtensionPerformanceSampleSeries

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case nativeCold, nativeWarm, webKitCold, webKitWarm
    }

    var sampleCount: Int { nativeCold.samplesMilliseconds.count }

    init(
        nativeCold: FloorpWebExtensionPerformanceSampleSeries,
        nativeWarm: FloorpWebExtensionPerformanceSampleSeries,
        webKitCold: FloorpWebExtensionPerformanceSampleSeries,
        webKitWarm: FloorpWebExtensionPerformanceSampleSeries
    ) throws {
        let counts = [nativeCold, nativeWarm, webKitCold, webKitWarm].map(\.samplesMilliseconds.count)
        guard Set(counts).count == 1 else {
            throw FloorpWebExtensionError.unsupported("compile span sample counts do not match")
        }
        self.nativeCold = nativeCold
        self.nativeWarm = nativeWarm
        self.webKitCold = webKitCold
        self.webKitWarm = webKitWarm
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "compile spans")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nativeCold: container.decode(FloorpWebExtensionPerformanceSampleSeries.self, forKey: .nativeCold),
            nativeWarm: container.decode(FloorpWebExtensionPerformanceSampleSeries.self, forKey: .nativeWarm),
            webKitCold: container.decode(FloorpWebExtensionPerformanceSampleSeries.self, forKey: .webKitCold),
            webKitWarm: container.decode(FloorpWebExtensionPerformanceSampleSeries.self, forKey: .webKitWarm)
        )
    }
}

struct FloorpWebExtensionPerformancePageLoadEvidence: Codable, Equatable, Sendable {
    let baseline: FloorpWebExtensionPerformanceSampleSeries
    let fixtureEnabled: FloorpWebExtensionPerformanceSampleSeries
    let signedMeanDeltaMilliseconds: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case baseline, fixtureEnabled, signedMeanDeltaMilliseconds
    }

    var sampleCount: Int { baseline.samplesMilliseconds.count }

    init(
        baseline: FloorpWebExtensionPerformanceSampleSeries,
        fixtureEnabled: FloorpWebExtensionPerformanceSampleSeries
    ) throws {
        guard baseline.samplesMilliseconds.count == fixtureEnabled.samplesMilliseconds.count else {
            throw FloorpWebExtensionError.unsupported("page-load sample counts do not match")
        }
        self.baseline = baseline
        self.fixtureEnabled = fixtureEnabled
        signedMeanDeltaMilliseconds = fixtureEnabled.statistics.mean - baseline.statistics.mean
    }

    private init(
        baseline: FloorpWebExtensionPerformanceSampleSeries,
        fixtureEnabled: FloorpWebExtensionPerformanceSampleSeries,
        signedMeanDeltaMilliseconds: Double
    ) throws {
        try self.init(baseline: baseline, fixtureEnabled: fixtureEnabled)
        guard FloorpWebExtensionPerformanceEvidenceValidation.equal(
            self.signedMeanDeltaMilliseconds,
            signedMeanDeltaMilliseconds
        ) else {
            throw FloorpWebExtensionError.unsupported("page-load delta does not match raw samples")
        }
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "page-load evidence")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            baseline: container.decode(FloorpWebExtensionPerformanceSampleSeries.self, forKey: .baseline),
            fixtureEnabled: container.decode(FloorpWebExtensionPerformanceSampleSeries.self, forKey: .fixtureEnabled),
            signedMeanDeltaMilliseconds: container.decode(Double.self, forKey: .signedMeanDeltaMilliseconds)
        )
    }
}

struct FloorpWebExtensionPerformanceMemoryEvidence: Codable, Equatable, Sendable {
    let processName: String
    let processIdentifier: Int32
    let baselineResidentBytes: Int64
    let fixtureResidentBytes: Int64
    let signedResidentDeltaBytes: Int64
    let peakResidentBytes: Int64
    let memoryPressureAction: String
    let postPressureResidentBytes: Int64
    let postRecoveryResidentBytes: Int64
    let recoveryDurationMilliseconds: Double
    let recoverySucceeded: Bool
    let postRecoveryFunctionalCheckPassed: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case processName, processIdentifier, baselineResidentBytes, fixtureResidentBytes
        case signedResidentDeltaBytes, peakResidentBytes, memoryPressureAction
        case postPressureResidentBytes, postRecoveryResidentBytes, recoveryDurationMilliseconds
        case recoverySucceeded, postRecoveryFunctionalCheckPassed
    }

    init(
        processName: String,
        processIdentifier: Int32,
        baselineResidentBytes: Int64,
        fixtureResidentBytes: Int64,
        peakResidentBytes: Int64,
        memoryPressureAction: String,
        postPressureResidentBytes: Int64,
        postRecoveryResidentBytes: Int64,
        recoveryDurationMilliseconds: Double,
        recoverySucceeded: Bool,
        postRecoveryFunctionalCheckPassed: Bool
    ) throws {
        let (delta, overflow) = fixtureResidentBytes.subtractingReportingOverflow(baselineResidentBytes)
        let byteValues = [
            baselineResidentBytes, fixtureResidentBytes, peakResidentBytes,
            postPressureResidentBytes, postRecoveryResidentBytes
        ]
        guard FloorpWebExtensionPerformanceEvidenceValidation.isSafeText(processName, maximumLength: 256),
              processIdentifier >= 0,
              byteValues.allSatisfy({ (0...FloorpWebExtensionPerformanceEvidenceValidation.maximumByteCount).contains($0) }),
              !overflow,
              peakResidentBytes >= baselineResidentBytes,
              peakResidentBytes >= fixtureResidentBytes,
              peakResidentBytes >= postPressureResidentBytes,
              peakResidentBytes >= postRecoveryResidentBytes,
              FloorpWebExtensionPerformanceEvidenceValidation.isSafeText(memoryPressureAction, maximumLength: 1_024),
              recoveryDurationMilliseconds.isFinite,
              (0...3_600_000).contains(recoveryDurationMilliseconds) else {
            throw FloorpWebExtensionError.unsupported("invalid process memory evidence")
        }
        self.processName = processName
        self.processIdentifier = processIdentifier
        self.baselineResidentBytes = baselineResidentBytes
        self.fixtureResidentBytes = fixtureResidentBytes
        signedResidentDeltaBytes = delta
        self.peakResidentBytes = peakResidentBytes
        self.memoryPressureAction = memoryPressureAction
        self.postPressureResidentBytes = postPressureResidentBytes
        self.postRecoveryResidentBytes = postRecoveryResidentBytes
        self.recoveryDurationMilliseconds = recoveryDurationMilliseconds
        self.recoverySucceeded = recoverySucceeded
        self.postRecoveryFunctionalCheckPassed = postRecoveryFunctionalCheckPassed
    }

    private init(
        processName: String,
        processIdentifier: Int32,
        baselineResidentBytes: Int64,
        fixtureResidentBytes: Int64,
        signedResidentDeltaBytes: Int64,
        peakResidentBytes: Int64,
        memoryPressureAction: String,
        postPressureResidentBytes: Int64,
        postRecoveryResidentBytes: Int64,
        recoveryDurationMilliseconds: Double,
        recoverySucceeded: Bool,
        postRecoveryFunctionalCheckPassed: Bool
    ) throws {
        try self.init(
            processName: processName,
            processIdentifier: processIdentifier,
            baselineResidentBytes: baselineResidentBytes,
            fixtureResidentBytes: fixtureResidentBytes,
            peakResidentBytes: peakResidentBytes,
            memoryPressureAction: memoryPressureAction,
            postPressureResidentBytes: postPressureResidentBytes,
            postRecoveryResidentBytes: postRecoveryResidentBytes,
            recoveryDurationMilliseconds: recoveryDurationMilliseconds,
            recoverySucceeded: recoverySucceeded,
            postRecoveryFunctionalCheckPassed: postRecoveryFunctionalCheckPassed
        )
        guard self.signedResidentDeltaBytes == signedResidentDeltaBytes else {
            throw FloorpWebExtensionError.unsupported("memory delta does not match measured byte counts")
        }
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "memory evidence")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            processName: container.decode(String.self, forKey: .processName),
            processIdentifier: container.decode(Int32.self, forKey: .processIdentifier),
            baselineResidentBytes: container.decode(Int64.self, forKey: .baselineResidentBytes),
            fixtureResidentBytes: container.decode(Int64.self, forKey: .fixtureResidentBytes),
            signedResidentDeltaBytes: container.decode(Int64.self, forKey: .signedResidentDeltaBytes),
            peakResidentBytes: container.decode(Int64.self, forKey: .peakResidentBytes),
            memoryPressureAction: container.decode(String.self, forKey: .memoryPressureAction),
            postPressureResidentBytes: container.decode(Int64.self, forKey: .postPressureResidentBytes),
            postRecoveryResidentBytes: container.decode(Int64.self, forKey: .postRecoveryResidentBytes),
            recoveryDurationMilliseconds: container.decode(Double.self, forKey: .recoveryDurationMilliseconds),
            recoverySucceeded: container.decode(Bool.self, forKey: .recoverySucceeded),
            postRecoveryFunctionalCheckPassed: container.decode(Bool.self, forKey: .postRecoveryFunctionalCheckPassed)
        )
    }
}

struct FloorpWebExtensionPerformanceFunctionalCheck: Codable, Equatable, Sendable {
    let identifier: String
    let passed: Bool
    let detail: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier, passed, detail
    }

    init(identifier: String, passed: Bool, detail: String) throws {
        guard FloorpWebExtensionPerformanceEvidenceValidation.isSafeIdentifier(identifier, maximumLength: 128),
              FloorpWebExtensionPerformanceEvidenceValidation.isSafeLogText(detail, maximumLength: 4_096) else {
            throw FloorpWebExtensionError.unsupported("invalid performance functional check")
        }
        self.identifier = identifier
        self.passed = passed
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        // swiftlint:disable:next line_length
        try FloorpWebExtensionPerformanceEvidenceValidation.requireExactKeys(decoder, CodingKeys.self, scope: "functional check")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: container.decode(String.self, forKey: .identifier),
            passed: container.decode(Bool.self, forKey: .passed),
            detail: container.decode(String.self, forKey: .detail)
        )
    }
}

enum FloorpWebExtensionStage3PerformanceEvidenceVerifier {
    static let maximumEncodedByteCount = 4 * 1_024 * 1_024
    static let maximumArtifactSnapshotByteCount: Int64 = 3 * 1_024 * 1_024 * 1_024
    static let demandingFixtureIdentifier = "demanding-mv3"
    static let demandingFixturePackageSHA256 = "05c6dc2719aea1429f70cffc1c0fc1ad8dcb053a842eb0f3a3fa994424f33d37"
    static let demandingFixtureRuleCount = 5_000
    static let requiredAcceptanceArtifactKinds = Set(FloorpWebExtensionPerformanceArtifactKind.allCases)

    static func verify(_ evidence: FloorpWebExtensionStage3PerformanceEvidence) throws {
        try evidence.validate()
    }

    /// Applies the release-gate semantics on top of structural validation.
    /// Failed measurements remain encodable audit records, but cannot satisfy
    /// this successful-run check.
    static func verifySuccessfulRun(_ evidence: FloorpWebExtensionStage3PerformanceEvidence) throws {
        try verify(evidence)
        guard evidence.fixture.integrityVerified,
              evidence.memory.recoverySucceeded,
              evidence.memory.postRecoveryFunctionalCheckPassed,
              evidence.functionalChecks.allSatisfy(\.passed),
              evidence.failures.isEmpty else {
            throw FloorpWebExtensionError.unsupported("Stage 3 performance run did not satisfy its functional gates")
        }
    }

    /// Validates only the immutable fixture/compiler binding. Measurement
    /// harnesses may use this before all performance scopes have been sampled;
    /// it never upgrades a partial record to full acceptance.
    static func verifyDemandingFixtureBinding(
        _ fixture: FloorpWebExtensionPerformanceFixtureEvidence
    ) throws {
        guard fixture.integrityVerified,
              fixture.identifier == demandingFixtureIdentifier,
              fixture.packageSHA256 == demandingFixturePackageSHA256,
              fixture.staticRuleCount == demandingFixtureRuleCount,
              fixture.dynamicRuleCount == 0,
              fixture.sessionRuleCount == 0,
              fixture.totalRuleCount == demandingFixtureRuleCount,
              fixture.enabledRuleCount == demandingFixtureRuleCount,
              fixture.transformedRuleCount == demandingFixtureRuleCount,
              fixture.rejectedRuleCount == 0 else {
            throw FloorpWebExtensionError.unsupported("performance evidence does not match the demanding fixture")
        }
    }

    /// Binds a structurally valid successful record to the checked-in Stage 3
    /// demanding fixture and its reviewed DNR compiler result. These constants
    /// deliberately are not caller-controlled release-gate inputs. Full
    /// acceptance also requires every content-addressed manifest entry to match
    /// a regular file below the supplied evidence directory. Binary xcresult
    /// and profile semantics must be established by explicit trusted release
    /// tooling; there is intentionally no default or filename-only validator.
    static func verifyAcceptance(
        _ evidence: FloorpWebExtensionStage3PerformanceEvidence,
        evidenceDirectory: URL,
        semanticValidator: any FloorpWebExtensionPerformanceArtifactSemanticValidating
    ) throws {
        try verifySuccessfulRun(evidence)
        try verifyDemandingFixtureBinding(evidence.fixture)
        guard Set(evidence.artifacts.map(\.kind)) == requiredAcceptanceArtifactKinds else {
            throw FloorpWebExtensionError.unsupported(
                "Stage 3 acceptance evidence is missing a required content-addressed artifact"
            )
        }
        try verifyArtifactBindings(
            evidence.artifacts,
            evidenceDirectory: evidenceDirectory,
            evidence: evidence,
            semanticValidator: semanticValidator
        )
    }

    /// Produces the exact raw-sample record accepted for the measurement-record
    /// artifact. Keeping this separate from the summary prevents a digest-only
    /// manifest from silently binding samples from another run.
    static func measurementRecordData(
        for evidence: FloorpWebExtensionStage3PerformanceEvidence
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(FloorpWebExtensionPerformanceMeasurementRecord(evidence: evidence))
    }

    private static func verifyArtifactBindings(
        _ artifacts: [FloorpWebExtensionPerformanceArtifact],
        evidenceDirectory: URL,
        evidence: FloorpWebExtensionStage3PerformanceEvidence,
        semanticValidator: any FloorpWebExtensionPerformanceArtifactSemanticValidating
    ) throws {
        guard evidenceDirectory.isFileURL else {
            throw FloorpWebExtensionError.unsupported("invalid Stage 3 evidence directory")
        }
        try verifyArtifactSnapshotBudget(artifacts)

        let root = evidenceDirectory.standardizedFileURL
        let rootDescriptor = try openEvidenceDirectory(at: root)
        defer { Darwin.close(rootDescriptor) }

        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpStage3EvidenceValidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: snapshotDirectory) }

        var snapshots = [FloorpWebExtensionPerformanceArtifactValidatedSnapshot]()
        defer {
            for snapshot in snapshots {
                try? snapshot.fileHandle.close()
            }
        }
        var semanticSnapshots = [FloorpWebExtensionPerformanceArtifactValidatedSnapshot]()
        for artifact in artifacts {
            guard FloorpWebExtensionPerformanceEvidenceValidation.isSafeArtifactPath(artifact.relativePath) else {
                throw FloorpWebExtensionError.unsupported("unsafe Stage 3 performance artifact path")
            }

            let source = try openRegularArtifact(
                below: rootDescriptor,
                artifact: artifact
            )
            let snapshot = try makeValidatedSnapshot(
                of: artifact,
                from: source,
                snapshotDirectory: snapshotDirectory
            )
            snapshots.append(snapshot)
            switch artifact.kind {
            case .testResultBundle:
                guard artifact.relativePath.hasSuffix(".xcresult.zip") else {
                    throw FloorpWebExtensionError.unsupported("Stage 3 xcresult artifact must be a .xcresult.zip archive")
                }
                semanticSnapshots.append(snapshot)
            case .performanceProfile:
                guard artifact.relativePath.hasSuffix(".trace.zip") else {
                    throw FloorpWebExtensionError.unsupported("Stage 3 performance profile must be a .trace.zip archive")
                }
                semanticSnapshots.append(snapshot)
            case .measurementRecord:
                try verifyMeasurementRecord(snapshot, evidence: evidence)
            }
        }

        for snapshot in semanticSnapshots {
            let attestation = try semanticValidator.validateArtifact(
                snapshot,
                evidence: evidence
            )
            guard attestation.artifactKind == snapshot.artifactKind,
                  attestation.runIdentifier == evidence.runIdentifier,
                  attestation.associatedSourceRevision == evidence.associatedSourceRevision,
                  attestation.sha256 == snapshot.sha256,
                  attestation.byteCount == snapshot.byteCount else {
                // swiftlint:disable:next line_length
                throw FloorpWebExtensionError.unsupported("Stage 3 binary artifact semantic attestation did not match its evidence run")
            }
            try verifySnapshotDigest(snapshot)
        }
    }

    /// Rejects an unsafe manifest before opening the evidence root or creating
    /// temporary snapshots. The cumulative ceiling also bounds future schema
    /// extensions even if additional artifact kinds are introduced later.
    private static func verifyArtifactSnapshotBudget(
        _ artifacts: [FloorpWebExtensionPerformanceArtifact]
    ) throws {
        var totalByteCount: Int64 = 0
        for artifact in artifacts {
            guard artifact.byteCount <= artifact.kind.maximumByteCount else {
                throw FloorpWebExtensionError.unsupported(
                    "Stage 3 performance artifact exceeds its kind-specific snapshot limit"
                )
            }
            let (updatedTotal, overflowed) = totalByteCount.addingReportingOverflow(artifact.byteCount)
            guard !overflowed, updatedTotal <= maximumArtifactSnapshotByteCount else {
                throw FloorpWebExtensionError.unsupported(
                    "Stage 3 performance artifacts exceed the cumulative snapshot budget"
                )
            }
            totalByteCount = updatedTotal
        }
    }

    private static func openEvidenceDirectory(at rootURL: URL) throws -> Int32 {
        let descriptor = rootURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw posixError("open Stage 3 evidence directory", code: errno)
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            let code = errno
            Darwin.close(descriptor)
            throw posixError("inspect Stage 3 evidence directory", code: code)
        }
        return descriptor
    }

    private static func openRegularArtifact(
        below rootDescriptor: Int32,
        artifact: FloorpWebExtensionPerformanceArtifact
    ) throws -> FileHandle {
        let relativePath = artifact.relativePath
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FloorpWebExtensionError.unsupported("unsafe Stage 3 performance artifact path")
        }

        var directoryDescriptor = Darwin.dup(rootDescriptor)
        guard directoryDescriptor >= 0 else {
            throw posixError("duplicate Stage 3 evidence directory descriptor", code: errno)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fcntl(directoryDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw posixError("protect Stage 3 evidence directory descriptor", code: errno)
        }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString { name in
                Darwin.openat(
                    directoryDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw posixError("open Stage 3 artifact directory component", code: errno)
            }
            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        let fileDescriptor = components[components.count - 1].withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else {
            throw posixError("open Stage 3 artifact", code: errno)
        }
        do {
            var metadata = stat()
            guard Darwin.fstat(fileDescriptor, &metadata) == 0 else {
                throw posixError("inspect Stage 3 artifact", code: errno)
            }
            guard metadata.st_mode & S_IFMT == S_IFREG else {
                throw FloorpWebExtensionError.unsupported("Stage 3 performance artifact is not a regular file")
            }
            guard Int64(metadata.st_size) == artifact.byteCount else {
                throw FloorpWebExtensionError.unsupported(
                    "Stage 3 performance artifact size does not match its manifest"
                )
            }
            let (allocatedByteCount, allocationOverflowed) = Int64(metadata.st_blocks)
                .multipliedReportingOverflow(by: 512)
            guard !allocationOverflowed,
                  allocatedByteCount >= artifact.byteCount else {
                throw FloorpWebExtensionError.unsupported(
                    "sparse Stage 3 performance artifacts are not accepted"
                )
            }
            return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private static func makeValidatedSnapshot(
        of artifact: FloorpWebExtensionPerformanceArtifact,
        from source: FileHandle,
        snapshotDirectory: URL
    ) throws -> FloorpWebExtensionPerformanceArtifactValidatedSnapshot {
        defer { try? source.close() }

        var template = Array(
            snapshotDirectory
                .appendingPathComponent("artifact.XXXXXX", isDirectory: false)
                .path
                .utf8CString
        )
        var writerDescriptor = template.withUnsafeMutableBufferPointer { buffer in
            Darwin.mkstemp(buffer.baseAddress!)
        }
        guard writerDescriptor >= 0 else {
            throw posixError("create private Stage 3 artifact snapshot", code: errno)
        }
        var readerDescriptor: Int32 = -1
        var namedSnapshotPath: String? = String(cString: template)
        defer {
            if writerDescriptor >= 0 {
                Darwin.close(writerDescriptor)
            }
            if readerDescriptor >= 0 {
                Darwin.close(readerDescriptor)
            }
            if let namedSnapshotPath {
                Darwin.unlink(namedSnapshotPath)
            }
        }

        guard Darwin.fcntl(writerDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw posixError("protect private Stage 3 artifact snapshot", code: errno)
        }
        readerDescriptor = try namedSnapshotPath!.withCString { path -> Int32 in
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw posixError("open private Stage 3 artifact snapshot", code: errno)
            }
            return descriptor
        }

        var writerMetadata = stat()
        var readerMetadata = stat()
        guard Darwin.fstat(writerDescriptor, &writerMetadata) == 0,
              Darwin.fstat(readerDescriptor, &readerMetadata) == 0,
              writerMetadata.st_mode & S_IFMT == S_IFREG,
              readerMetadata.st_mode & S_IFMT == S_IFREG,
              writerMetadata.st_dev == readerMetadata.st_dev,
              writerMetadata.st_ino == readerMetadata.st_ino else {
            throw FloorpWebExtensionError.unsupported("private Stage 3 artifact snapshot identity did not match")
        }

        guard Darwin.unlink(namedSnapshotPath!) == 0 else {
            throw posixError("unlink private Stage 3 artifact snapshot", code: errno)
        }
        namedSnapshotPath = nil
        guard Darwin.fstat(writerDescriptor, &writerMetadata) == 0,
              Darwin.fstat(readerDescriptor, &readerMetadata) == 0,
              writerMetadata.st_nlink == 0,
              readerMetadata.st_nlink == 0 else {
            throw FloorpWebExtensionError.unsupported("private Stage 3 artifact snapshot remained addressable")
        }

        var copiedByteCount: Int64 = 0
        while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
            let (updatedByteCount, overflowed) = copiedByteCount.addingReportingOverflow(Int64(chunk.count))
            guard !overflowed,
                  updatedByteCount <= artifact.byteCount,
                  updatedByteCount <= artifact.kind.maximumByteCount else {
                throw FloorpWebExtensionError.unsupported("Stage 3 performance artifact exceeds the size limit")
            }
            copiedByteCount = updatedByteCount
            try writeAll(chunk, to: writerDescriptor)
        }
        guard copiedByteCount == artifact.byteCount else {
            throw FloorpWebExtensionError.unsupported("Stage 3 performance artifact byte count does not match its manifest")
        }
        guard Darwin.fsync(writerDescriptor) == 0 else {
            throw posixError("flush private Stage 3 artifact snapshot", code: errno)
        }
        let descriptorToClose = writerDescriptor
        writerDescriptor = -1
        guard Darwin.close(descriptorToClose) == 0 else {
            throw posixError("close private Stage 3 artifact snapshot writer", code: errno)
        }
        guard Darwin.lseek(readerDescriptor, 0, SEEK_SET) == 0 else {
            throw posixError("rewind private Stage 3 artifact snapshot", code: errno)
        }

        let snapshotHandle = FileHandle(fileDescriptor: readerDescriptor, closeOnDealloc: true)
        readerDescriptor = -1
        let snapshot = FloorpWebExtensionPerformanceArtifactValidatedSnapshot(
            artifactKind: artifact.kind,
            relativePath: artifact.relativePath,
            sha256: artifact.sha256,
            byteCount: artifact.byteCount,
            fileHandle: snapshotHandle
        )
        do {
            try verifySnapshotDigest(snapshot)
            return snapshot
        } catch {
            try? snapshotHandle.close()
            throw error
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw posixError("write private Stage 3 artifact snapshot", code: result < 0 ? errno : EIO)
                }
                offset += result
            }
        }
    }

    private static func posixError(_ operation: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (errno \(code))"]
        )
    }

    private static func verifySnapshotDigest(
        _ snapshot: FloorpWebExtensionPerformanceArtifactValidatedSnapshot
    ) throws {
        try snapshot.fileHandle.seek(toOffset: 0)
        var digest = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try snapshot.fileHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
            let (updatedByteCount, overflowed) = byteCount.addingReportingOverflow(Int64(chunk.count))
            guard !overflowed,
                  updatedByteCount <= FloorpWebExtensionPerformanceArtifact.maximumByteCount else {
                throw FloorpWebExtensionError.unsupported("validated Stage 3 artifact snapshot exceeds the size limit")
            }
            byteCount = updatedByteCount
            digest.update(data: chunk)
        }
        try snapshot.fileHandle.seek(toOffset: 0)
        let sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard byteCount == snapshot.byteCount,
              sha256 == snapshot.sha256 else {
            throw FloorpWebExtensionError.unsupported("validated Stage 3 artifact snapshot changed during inspection")
        }
    }

    private static func verifyMeasurementRecord(
        _ snapshot: FloorpWebExtensionPerformanceArtifactValidatedSnapshot,
        evidence: FloorpWebExtensionStage3PerformanceEvidence
    ) throws {
        guard snapshot.artifactKind == .measurementRecord,
              snapshot.relativePath.hasSuffix(".json"),
              snapshot.byteCount <= Int64(maximumEncodedByteCount) else {
            throw FloorpWebExtensionError.unsupported("Stage 3 measurement record must be a bounded JSON file")
        }
        let data = try snapshot.readSmallData(maximumByteCount: Int64(maximumEncodedByteCount))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(FloorpWebExtensionPerformanceMeasurementRecord.self, from: data)
        guard record.runIdentifier == evidence.runIdentifier,
              record.associatedSourceRevision == evidence.associatedSourceRevision,
              record.evidenceSchemaVersion == evidence.schemaVersion,
              record.recordedAt == evidence.recordedAt,
              record.build == evidence.build,
              record.device == evidence.device,
              record.fixture == evidence.fixture,
              record.measurementProtocol == evidence.measurementProtocol,
              record.compileSpans == evidence.compileSpans,
              record.pageLoad == evidence.pageLoad,
              record.memory == evidence.memory else {
            throw FloorpWebExtensionError.unsupported("Stage 3 measurement record does not match its evidence run")
        }
        guard record.functionalChecks == evidence.functionalChecks,
              record.failures == evidence.failures else {
            throw FloorpWebExtensionError.unsupported("Stage 3 measurement record does not match its evidence outcome")
        }
        try verifySnapshotDigest(snapshot)
    }

    static func encode(
        _ evidence: FloorpWebExtensionStage3PerformanceEvidence,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        try verify(evidence)
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(evidence)
        guard data.count <= maximumEncodedByteCount else {
            throw FloorpWebExtensionError.unsupported("Stage 3 performance evidence exceeds the size limit")
        }
        return data
    }

    static func decode(
        _ data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> FloorpWebExtensionStage3PerformanceEvidence {
        guard !data.isEmpty, data.count <= maximumEncodedByteCount else {
            throw FloorpWebExtensionError.unsupported("invalid Stage 3 performance evidence size")
        }
        decoder.dateDecodingStrategy = .secondsSince1970
        let evidence = try decoder.decode(FloorpWebExtensionStage3PerformanceEvidence.self, from: data)
        try verify(evidence)
        return evidence
    }
}

private struct FloorpWebExtensionPerformanceEvidenceCodingKey: CodingKey {
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

private enum FloorpWebExtensionPerformanceEvidenceValidation {
    static let maximumByteCount: Int64 = 1 << 50

    static func requireExactKeys<Keys: CodingKey & CaseIterable>(
        _ decoder: Decoder,
        _ keyType: Keys.Type,
        scope: String
    ) throws {
        let container = try decoder.container(keyedBy: FloorpWebExtensionPerformanceEvidenceCodingKey.self)
        let expected = Set(keyType.allCases.map(\.stringValue))
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual == expected else {
            throw FloorpWebExtensionError.unsupported("invalid \(scope) keys")
        }
    }

    static func isSafeText(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.count <= maximumLength &&
            value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
            }
    }

    static func isSafeIdentifier(_ value: String, maximumLength: Int) -> Bool {
        isSafeText(value, maximumLength: maximumLength) &&
            value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || "-._:".unicodeScalars.contains(scalar)
            }
    }

    static func isSafeLogText(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.count <= maximumLength &&
            value.unicodeScalars.allSatisfy { scalar in
                scalar == "\n" || scalar == "\r" || scalar == "\t" ||
                    (scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value))
            }
    }

    static func isRevision(_ value: String) -> Bool {
        let byteCount = value.utf8.count
        return (byteCount == 40 || byteCount == 64) && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) ||
                (0x41...0x46).contains(byte) ||
                (0x61...0x66).contains(byte)
        }
    }

    static func isOperatingSystem(_ value: String) -> Bool {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0] == "iOS",
              !parts[1].isEmpty else {
            return false
        }
        let versionParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(versionParts.count),
              versionParts.allSatisfy({
                  !$0.isEmpty && $0.allSatisfy(\.isNumber) &&
                      ($0.count == 1 || $0.first != "0")
              }),
              let major = Int(versionParts[0]),
              major > 0 else {
            return false
        }
        return versionParts.dropFirst().allSatisfy { Int($0) != nil }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) ||
                (0x41...0x46).contains(byte) ||
                (0x61...0x66).contains(byte)
        }
    }

    static func areSafeSamples(_ samples: [Double]) -> Bool {
        (1...10_000).contains(samples.count) && samples.allSatisfy {
            $0.isFinite && (0...3_600_000).contains($0)
        }
    }

    static func equal(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        let scale = max(1, max(abs(lhs), abs(rhs)))
        return abs(lhs - rhs) <= scale * 1e-12
    }

    static func isSafeArtifactPath(_ value: String) -> Bool {
        guard isSafeText(value, maximumLength: 1_024),
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
