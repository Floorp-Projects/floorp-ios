// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// A deliberately simulator-only, record-only Stage 3 measurement.
///
/// This is not release acceptance evidence. In particular, an empty
/// `WKContentRuleListStore` does not imply a cold WebKit compiler process,
/// localhost does not activate the fixture's `*.fixture.test` content scripts,
/// and the hosted Client process does not include WebContent/Network process
/// memory. Those limits are part of the validated payload rather than prose
/// supplied by the runner.
struct FloorpWebExtensionStage3SimulatorPerformanceRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let minimumMeasuredSampleCount = 7
    static let maximumMeasuredSampleCount = 100
    static let maximumMemorySampleCount = 10_000
    static let requiredFunctionalCheckIdentifiers: Set<String> = [
        "demanding-fixture-integrity",
        "webkit-dnr-local-resource-block",
        "package-background-release-recovery"
    ]
    static let requiredLimitations = [
        "simulator-only",
        "empty-store-is-not-cold-process",
        "localhost-page-load-measures-dnr-policy-only",
        "client-host-memory-excludes-webcontent-and-network-processes",
        "direct-release-hook-is-not-an-os-delivered-memory-warning",
        "record-only-not-release-acceptance"
    ]

    let schemaVersion: Int
    let recordClassification: String
    let runIdentifier: String
    let associatedSourceRevision: String
    let sourceAttestedRevision: String
    let sourceWorktreeState: String
    let recordedAt: Date
    let environment: Environment
    let fixture: FloorpWebExtensionPerformanceFixtureEvidence
    let measurementProtocol: MeasurementProtocol
    let nativeTransformation: NativeTransformationEvidence
    let webKitCompilation: CompilationEvidence
    let pageLoad: PageLoadEvidence
    let memory: MemoryEvidence
    let functionalChecks: [FunctionalCheck]
    let limitations: [String]

    init(
        runIdentifier: String,
        associatedSourceRevision: String,
        sourceAttestedRevision: String,
        sourceWorktreeState: String,
        recordedAt: Date,
        environment: Environment,
        fixture: FloorpWebExtensionPerformanceFixtureEvidence,
        measurementProtocol: MeasurementProtocol,
        nativeTransformation: NativeTransformationEvidence,
        webKitCompilation: CompilationEvidence,
        pageLoad: PageLoadEvidence,
        memory: MemoryEvidence,
        functionalChecks: [FunctionalCheck]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        recordClassification = "simulator-hosted-record-only"
        self.runIdentifier = runIdentifier
        self.associatedSourceRevision = associatedSourceRevision.lowercased()
        self.sourceAttestedRevision = sourceAttestedRevision.lowercased()
        self.sourceWorktreeState = sourceWorktreeState
        self.recordedAt = recordedAt
        self.environment = environment
        self.fixture = fixture
        self.measurementProtocol = measurementProtocol
        self.nativeTransformation = nativeTransformation
        self.webKitCompilation = webKitCompilation
        self.pageLoad = pageLoad
        self.memory = memory
        self.functionalChecks = functionalChecks
        limitations = Self.requiredLimitations
        try validate()
    }

    func validate() throws {
        let identifiers = functionalChecks.map(\.identifier)
        let runSuffix = String(runIdentifier.dropFirst("stage3-simulator-".count))
        guard schemaVersion == Self.currentSchemaVersion,
              recordClassification == "simulator-hosted-record-only",
              runIdentifier.hasPrefix("stage3-simulator-"),
              runIdentifier.utf8.count <= 128,
              UUID(uuidString: runSuffix) != nil,
              Self.isSourceRevision(associatedSourceRevision),
              sourceAttestedRevision == associatedSourceRevision,
              sourceWorktreeState == "clean",
              recordedAt.timeIntervalSinceReferenceDate.isFinite,
              environment.isSimulator,
              limitations == Self.requiredLimitations,
              measurementProtocol.measuredSampleCount == nativeTransformation.samples.count,
              measurementProtocol.measuredSampleCount == webKitCompilation.samples.count,
              measurementProtocol.pagePairCount == pageLoad.pairs.count,
              (Self.minimumMeasuredSampleCount...Self.maximumMeasuredSampleCount)
                .contains(measurementProtocol.measuredSampleCount),
              (Self.minimumMeasuredSampleCount...Self.maximumMeasuredSampleCount)
                .contains(measurementProtocol.pagePairCount),
              nativeTransformation.outputRuleCount == fixture.transformedRuleCount,
              webKitCompilation.outputRuleCount == fixture.transformedRuleCount,
              nativeTransformation.samples.map(\.index) == Array(nativeTransformation.samples.indices),
              webKitCompilation.samples.map(\.index) == Array(webKitCompilation.samples.indices),
              pageLoad.pairs.map(\.index) == Array(pageLoad.pairs.indices),
              Set(identifiers) == Self.requiredFunctionalCheckIdentifiers,
              functionalChecks.count == Self.requiredFunctionalCheckIdentifiers.count,
              functionalChecks.allSatisfy(\.passed) else {
            throw FloorpWebExtensionError.unsupported("invalid simulator performance record")
        }
        try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyDemandingFixtureBinding(fixture)
        try environment.validate()
        try measurementProtocol.validate()
        try nativeTransformation.validate(
            maximumSampleCount: Self.maximumMeasuredSampleCount,
            clockNumerator: measurementProtocol.clockNumerator,
            clockDenominator: measurementProtocol.clockDenominator
        )
        try webKitCompilation.validate(
            maximumSampleCount: Self.maximumMeasuredSampleCount,
            clockNumerator: measurementProtocol.clockNumerator,
            clockDenominator: measurementProtocol.clockDenominator
        )
        try pageLoad.validate(
            maximumPairCount: Self.maximumMeasuredSampleCount,
            clockNumerator: measurementProtocol.clockNumerator,
            clockDenominator: measurementProtocol.clockDenominator
        )
        try memory.validate(
            maximumSampleCount: Self.maximumMemorySampleCount,
            clockNumerator: measurementProtocol.clockNumerator,
            clockDenominator: measurementProtocol.clockDenominator
        )
    }

    private static func isSourceRevision(_ value: String) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}

extension FloorpWebExtensionStage3SimulatorPerformanceRecord {
    struct Environment: Codable, Equatable, Sendable {
        let operatingSystem: String
        let operatingSystemBuild: String
        let modelIdentifier: String
        let deviceIdentifier: String
        let architecture: String
        let isSimulator: Bool

        fileprivate func validate() throws {
            let values = [
                operatingSystem, operatingSystemBuild, modelIdentifier,
                deviceIdentifier, architecture
            ]
            guard values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                throw FloorpWebExtensionError.unsupported("invalid simulator environment")
            }
        }
    }

    struct MeasurementProtocol: Codable, Equatable, Sendable {
        let clock: String
        let clockNumerator: UInt32
        let clockDenominator: UInt32
        let nativeState: String
        let webKitEmptyState: String
        let webKitPrimedState: String
        let pagePairing: String
        let memoryMetric: String
        let memoryScope: String
        let memoryReleaseAction: String
        let nativeWarmupSampleCount: Int
        let webKitWarmupSampleCount: Int
        let pageWarmupPairCount: Int
        let measuredSampleCount: Int
        let pagePairCount: Int
        let memorySamplingIntervalMilliseconds: Int

        func validate() throws {
            guard clock == "mach_continuous_time",
                  nativeState == "fresh-store-transform-from-prevalidated-retained-rules-no-native-cache",
                  webKitEmptyState == "empty-profile-scoped-store-compile",
                  webKitPrimedState == "same-store-fresh-identifier-compile-after-untimed-prime",
                  pagePairing == "alternating-baseline-enabled-identical-local-page",
                  memoryMetric == "task_vm_info.phys_footprint",
                  memoryScope == "Client-hosted-XCTest-process-only",
                  memoryReleaseAction == "direct-bootstrapper-release-hook",
                  clockNumerator > 0,
                  clockDenominator > 0,
                  nativeWarmupSampleCount == 1,
                  webKitWarmupSampleCount == 1,
                  pageWarmupPairCount == 2,
                  (10...1_000).contains(memorySamplingIntervalMilliseconds) else {
                throw FloorpWebExtensionError.unsupported("invalid simulator measurement protocol")
            }
        }
    }

    struct DurationSample: Codable, Equatable, Sendable {
        let index: Int
        let startTicks: UInt64
        let endTicks: UInt64
        let milliseconds: Double

        fileprivate func validate(clockNumerator: UInt32, clockDenominator: UInt32) throws {
            guard index >= 0,
                  endTicks >= startTicks,
                  milliseconds.isFinite,
                  milliseconds > 0,
                  milliseconds <= 3_600_000,
                  Self.durationMatchesTicks(
                      start: startTicks,
                      end: endTicks,
                      milliseconds: milliseconds,
                      clockNumerator: clockNumerator,
                      clockDenominator: clockDenominator
                  ) else {
                throw FloorpWebExtensionError.unsupported("invalid simulator duration sample")
            }
        }

        fileprivate static func durationMatchesTicks(
            start: UInt64,
            end: UInt64,
            milliseconds: Double,
            clockNumerator: UInt32,
            clockDenominator: UInt32
        ) -> Bool {
            guard end >= start, clockNumerator > 0, clockDenominator > 0 else { return false }
            let expected = Double(end - start) * Double(clockNumerator) /
                Double(clockDenominator) / 1_000_000
            let scale = max(1, max(abs(expected), abs(milliseconds)))
            return expected.isFinite && abs(expected - milliseconds) <= scale * 1e-12
        }
    }

    struct NativeTransformationEvidence: Codable, Equatable, Sendable {
        let samples: [DurationSample]
        let outputRuleCount: Int

        fileprivate func validate(
            maximumSampleCount: Int,
            clockNumerator: UInt32,
            clockDenominator: UInt32
        ) throws {
            guard !samples.isEmpty,
                  samples.count <= maximumSampleCount,
                  outputRuleCount == 5_000 else {
                throw FloorpWebExtensionError.unsupported("invalid native transformation evidence")
            }
            for sample in samples {
                try sample.validate(
                    clockNumerator: clockNumerator,
                    clockDenominator: clockDenominator
                )
            }
        }
    }

    struct TimedSample: Codable, Equatable, Sendable {
        let index: Int
        let emptyStartTicks: UInt64
        let emptyEndTicks: UInt64
        let emptyMilliseconds: Double
        let primedStartTicks: UInt64
        let primedEndTicks: UInt64
        let primedMilliseconds: Double

        fileprivate func validate(clockNumerator: UInt32, clockDenominator: UInt32) throws {
            guard index >= 0,
                  emptyEndTicks >= emptyStartTicks,
                  primedEndTicks >= primedStartTicks,
                  Self.safeDuration(emptyMilliseconds),
                  Self.safeDuration(primedMilliseconds),
                  DurationSample.durationMatchesTicks(
                      start: emptyStartTicks,
                      end: emptyEndTicks,
                      milliseconds: emptyMilliseconds,
                      clockNumerator: clockNumerator,
                      clockDenominator: clockDenominator
                  ),
                  DurationSample.durationMatchesTicks(
                      start: primedStartTicks,
                      end: primedEndTicks,
                      milliseconds: primedMilliseconds,
                      clockNumerator: clockNumerator,
                      clockDenominator: clockDenominator
                  ) else {
                throw FloorpWebExtensionError.unsupported("invalid simulator compilation sample")
            }
        }

        private static func safeDuration(_ value: Double) -> Bool {
            value.isFinite && value > 0 && value <= 3_600_000
        }
    }

    struct CompilationEvidence: Codable, Equatable, Sendable {
        let samples: [TimedSample]
        let outputRuleCount: Int

        fileprivate func validate(
            maximumSampleCount: Int,
            clockNumerator: UInt32,
            clockDenominator: UInt32
        ) throws {
            guard !samples.isEmpty,
                  samples.count <= maximumSampleCount,
                  outputRuleCount == 5_000 else {
                throw FloorpWebExtensionError.unsupported("invalid simulator compilation evidence")
            }
            for sample in samples {
                try sample.validate(
                    clockNumerator: clockNumerator,
                    clockDenominator: clockDenominator
                )
            }
        }
    }

    enum PagePairOrder: String, Codable, Sendable {
        case baselineThenEnabled
        case enabledThenBaseline
    }

    struct PagePair: Codable, Equatable, Sendable {
        let index: Int
        let order: PagePairOrder
        let baselineStartTicks: UInt64
        let baselineEndTicks: UInt64
        let baselineMilliseconds: Double
        let enabledStartTicks: UInt64
        let enabledEndTicks: UInt64
        let enabledMilliseconds: Double
        let signedDeltaMilliseconds: Double

        fileprivate func validate(clockNumerator: UInt32, clockDenominator: UInt32) throws {
            let expectedDelta = enabledMilliseconds - baselineMilliseconds
            guard index >= 0,
                  baselineEndTicks >= baselineStartTicks,
                  enabledEndTicks >= enabledStartTicks,
                  baselineMilliseconds.isFinite,
                  enabledMilliseconds.isFinite,
                  signedDeltaMilliseconds.isFinite,
                  baselineMilliseconds > 0,
                  enabledMilliseconds > 0,
                  baselineMilliseconds <= 3_600_000,
                  enabledMilliseconds <= 3_600_000,
                  DurationSample.durationMatchesTicks(
                      start: baselineStartTicks,
                      end: baselineEndTicks,
                      milliseconds: baselineMilliseconds,
                      clockNumerator: clockNumerator,
                      clockDenominator: clockDenominator
                  ),
                  DurationSample.durationMatchesTicks(
                      start: enabledStartTicks,
                      end: enabledEndTicks,
                      milliseconds: enabledMilliseconds,
                      clockNumerator: clockNumerator,
                      clockDenominator: clockDenominator
                  ),
                  abs(expectedDelta - signedDeltaMilliseconds) <= 0.000_001 else {
                throw FloorpWebExtensionError.unsupported("invalid simulator page-load pair")
            }
        }
    }

    struct PageLoadEvidence: Codable, Equatable, Sendable {
        let pairs: [PagePair]
        let signedMeanDeltaMilliseconds: Double

        fileprivate func validate(
            maximumPairCount: Int,
            clockNumerator: UInt32,
            clockDenominator: UInt32
        ) throws {
            guard !pairs.isEmpty, pairs.count <= maximumPairCount else {
                throw FloorpWebExtensionError.unsupported("invalid simulator page-load evidence")
            }
            try pairs.forEach {
                try $0.validate(
                    clockNumerator: clockNumerator,
                    clockDenominator: clockDenominator
                )
            }
            let expected = pairs.map(\.signedDeltaMilliseconds).reduce(0, +) / Double(pairs.count)
            guard signedMeanDeltaMilliseconds.isFinite,
                  abs(expected - signedMeanDeltaMilliseconds) <= 0.000_001,
                  pairs.enumerated().allSatisfy({ index, pair in
                      pair.order == (index.isMultiple(of: 2) ? .baselineThenEnabled : .enabledThenBaseline)
                  }) else {
                throw FloorpWebExtensionError.unsupported("invalid simulator page-load aggregation")
            }
        }
    }

    struct MemoryEvidence: Codable, Equatable, Sendable {
        let processName: String
        let processIdentifier: Int32
        let baselineSamplesBytes: [Int64]
        let fixtureSamplesBytes: [Int64]
        let postReleaseSamplesBytes: [Int64]
        let postRecoverySamplesBytes: [Int64]
        let periodicSamplesBytes: [Int64]
        let peakObservedBytes: Int64
        let recoveryStartTicks: UInt64
        let recoveryEndTicks: UInt64
        let recoveryMilliseconds: Double
        let backgroundObservedBeforeRelease: Bool
        let priorBackgroundReleased: Bool
        let replacementActivationCount: UInt64
        let postRecoveryReplyPassed: Bool

        fileprivate func validate(
            maximumSampleCount: Int,
            clockNumerator: UInt32,
            clockDenominator: UInt32
        ) throws {
            let phaseSamples = [
                baselineSamplesBytes, fixtureSamplesBytes,
                postReleaseSamplesBytes, postRecoverySamplesBytes
            ]
            let allSamples = phaseSamples.flatMap { $0 } + periodicSamplesBytes
            guard !processName.isEmpty,
                  processName.utf8.count <= 256,
                  processIdentifier > 0,
                  phaseSamples.allSatisfy({ (3...100).contains($0.count) }),
                  !periodicSamplesBytes.isEmpty,
                  periodicSamplesBytes.count <= maximumSampleCount,
                  allSamples.allSatisfy({ $0 > 0 && $0 <= 1_099_511_627_776 }),
                  peakObservedBytes == allSamples.max(),
                  recoveryEndTicks >= recoveryStartTicks,
                  recoveryMilliseconds.isFinite,
                  recoveryMilliseconds > 0,
                  recoveryMilliseconds <= 3_600_000,
                  DurationSample.durationMatchesTicks(
                      start: recoveryStartTicks,
                      end: recoveryEndTicks,
                      milliseconds: recoveryMilliseconds,
                      clockNumerator: clockNumerator,
                      clockDenominator: clockDenominator
                  ),
                  backgroundObservedBeforeRelease,
                  priorBackgroundReleased,
                  replacementActivationCount == 2,
                  postRecoveryReplyPassed else {
                throw FloorpWebExtensionError.unsupported("invalid simulator memory evidence")
            }
        }
    }

    struct FunctionalCheck: Codable, Equatable, Sendable {
        let identifier: String
        let passed: Bool
        let detail: String

        init(identifier: String, passed: Bool, detail: String) throws {
            guard !identifier.isEmpty,
                  identifier.utf8.count <= 128,
                  !detail.isEmpty,
                  detail.utf8.count <= 1_024 else {
                throw FloorpWebExtensionError.unsupported("invalid simulator functional check")
            }
            self.identifier = identifier
            self.passed = passed
            self.detail = detail
        }
    }
}

enum FloorpWebExtensionStage3SimulatorPerformanceRecordVerifier {
    static let maximumEncodedByteCount = 4 * 1_024 * 1_024

    static func encode(_ record: FloorpWebExtensionStage3SimulatorPerformanceRecord) throws -> Data {
        try record.measurementProtocol.validate()
        try record.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= maximumEncodedByteCount else {
            throw FloorpWebExtensionError.quotaExceeded("simulator performance record")
        }
        return data
    }

    static func decode(_ data: Data) throws -> FloorpWebExtensionStage3SimulatorPerformanceRecord {
        guard !data.isEmpty, data.count <= maximumEncodedByteCount else {
            throw FloorpWebExtensionError.quotaExceeded("simulator performance record")
        }
        try verifyExactJSONKeys(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(FloorpWebExtensionStage3SimulatorPerformanceRecord.self, from: data)
        try record.measurementProtocol.validate()
        try record.validate()
        return record
    }

    private static func verifyExactJSONKeys(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              exactKeys(root, [
                  "schemaVersion", "recordClassification", "runIdentifier",
                  "associatedSourceRevision", "sourceAttestedRevision", "sourceWorktreeState",
                  "recordedAt", "environment", "fixture",
                  "measurementProtocol", "nativeTransformation", "webKitCompilation",
                  "pageLoad", "memory", "functionalChecks", "limitations",
              ]),
              let environment = root["environment"] as? [String: Any],
              exactKeys(environment, [
                  "operatingSystem", "operatingSystemBuild", "modelIdentifier",
                  "deviceIdentifier", "architecture", "isSimulator",
              ]),
              let measurementProtocol = root["measurementProtocol"] as? [String: Any],
              exactKeys(measurementProtocol, [
                  "clock", "clockNumerator", "clockDenominator", "nativeState", "webKitEmptyState",
                  "webKitPrimedState", "pagePairing", "memoryMetric", "memoryScope",
                  "memoryReleaseAction", "nativeWarmupSampleCount", "webKitWarmupSampleCount",
                  "pageWarmupPairCount", "measuredSampleCount",
                  "pagePairCount", "memorySamplingIntervalMilliseconds",
              ]),
              let native = root["nativeTransformation"] as? [String: Any],
              exactNativeTransformationKeys(native),
              let webKit = root["webKitCompilation"] as? [String: Any],
              exactCompilationKeys(webKit),
              let pageLoad = root["pageLoad"] as? [String: Any],
              exactKeys(pageLoad, ["pairs", "signedMeanDeltaMilliseconds"]),
              let pagePairs = pageLoad["pairs"] as? [[String: Any]],
              pagePairs.allSatisfy({ pair in
                  exactKeys(pair, [
                      "index", "order", "baselineStartTicks", "baselineEndTicks",
                      "baselineMilliseconds", "enabledStartTicks", "enabledEndTicks",
                      "enabledMilliseconds",
                      "signedDeltaMilliseconds",
                  ])
              }),
              let memory = root["memory"] as? [String: Any],
              exactKeys(memory, [
                  "processName", "processIdentifier", "baselineSamplesBytes",
                  "fixtureSamplesBytes", "postReleaseSamplesBytes", "postRecoverySamplesBytes",
                  "periodicSamplesBytes", "peakObservedBytes", "recoveryStartTicks",
                  "recoveryEndTicks", "recoveryMilliseconds", "priorBackgroundReleased",
                  "backgroundObservedBeforeRelease", "replacementActivationCount",
                  "postRecoveryReplyPassed",
              ]),
              let fixture = root["fixture"] as? [String: Any],
              exactKeys(fixture, [
                  "identifier", "version", "packageSHA256", "integrityVerified",
                  "staticRuleCount", "dynamicRuleCount", "sessionRuleCount", "totalRuleCount",
                  "enabledRuleCount", "transformedRuleCount", "rejectedRuleCount",
              ]),
              let functionalChecks = root["functionalChecks"] as? [[String: Any]],
              functionalChecks.allSatisfy({ check in
                  exactKeys(check, ["identifier", "passed", "detail"])
              }) else {
            throw FloorpWebExtensionError.unsupported(
                "simulator performance record has unknown or missing keys"
            )
        }
    }

    private static func exactNativeTransformationKeys(_ object: [String: Any]) -> Bool {
        guard exactKeys(object, ["samples", "outputRuleCount"]),
              let samples = object["samples"] as? [[String: Any]] else {
            return false
        }
        return samples.allSatisfy { sample in
            exactKeys(sample, ["index", "startTicks", "endTicks", "milliseconds"])
        }
    }

    private static func exactCompilationKeys(_ object: [String: Any]) -> Bool {
        guard exactKeys(object, ["samples", "outputRuleCount"]),
              let samples = object["samples"] as? [[String: Any]] else {
            return false
        }
        return samples.allSatisfy { sample in
            exactKeys(sample, [
                "index", "emptyStartTicks", "emptyEndTicks", "emptyMilliseconds",
                "primedStartTicks", "primedEndTicks", "primedMilliseconds",
            ])
        }
    }

    private static func exactKeys(_ object: [String: Any], _ expected: Set<String>) -> Bool {
        Set(object.keys) == expected
    }
}
