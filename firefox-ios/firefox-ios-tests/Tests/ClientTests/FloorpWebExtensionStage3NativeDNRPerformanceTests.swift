// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Darwin
import Foundation
import XCTest
@testable import Client

/// Produces a record-only measurement for the Foundation DNR transform.
///
/// This deliberately does not populate the complete Stage 3 release evidence:
/// WebKit compilation, page loading, and memory-pressure recovery require their
/// own measurement boundaries. The generated artifact names those scopes as
/// unmeasured so it cannot be mistaken for full release acceptance evidence.
final class FloorpWebExtensionStage3NativeDNRPerformanceTests: XCTestCase, @unchecked Sendable {
    private let fixtureIdentifier = "demanding-mv3"
    private let staticRuleSetIdentifier = "large-static"
    private let measuredSampleCount = 7
    private let warmupSampleCount = 1

    func testRecordsRepeatedDemandingFixtureNativeTransformEvidence() async throws {
        let fixtureDirectory = try checkedInFixtureDirectory(named: fixtureIdentifier)
        let metadata = try FloorpWebExtensionCompatibilityHarness.verifyFixturePackage(at: fixtureDirectory)
        let ruleData = try Data(
            contentsOf: fixtureDirectory.appendingPathComponent("rules/static.json")
        )
        let rules = try materializeStaticRules(from: ruleData)

        XCTAssertEqual(rules.count, 5_000)
        XCTAssertEqual(rules.map(\.id), Array(1 ... 5_000))

        for _ in 0..<warmupSampleCount {
            _ = try await measuredNativeTransform(rules: rules)
        }

        var samples = [Double]()
        var finalCompilation: FloorpWebExtensionDNRCompilation?
        for _ in 0..<measuredSampleCount {
            let measured = try await measuredNativeTransform(rules: rules)
            try verifyCompilation(measured.compilation)
            samples.append(measured.durationMilliseconds)
            finalCompilation = measured.compilation
        }

        let compilation = try XCTUnwrap(finalCompilation)
        let fixture = try FloorpWebExtensionPerformanceFixtureEvidence(
            identifier: fixtureIdentifier,
            version: metadata.fixture.version,
            packageSHA256: metadata.fixture.packageSHA256,
            integrityVerified: true,
            staticRuleCount: rules.count,
            dynamicRuleCount: 0,
            sessionRuleCount: 0,
            totalRuleCount: rules.count,
            enabledRuleCount: compilation.compiledRules.count,
            transformedRuleCount: compilation.report.transformedRuleCount,
            rejectedRuleCount: compilation.report.rejectedRuleCount
        )

        // The production verifier owns the immutable fixture identity and
        // compiler invariants; this test does not duplicate or weaken them.
        try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyDemandingFixtureBinding(fixture)

        let artifact = try NativeTransformEvidence(
            runIdentifier: "native-dnr-\(UUID().uuidString.lowercased())",
            recordedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            environment: currentEnvironment(),
            fixture: fixture,
            measurementProtocol: .init(
                clock: "mach_continuous_time",
                inputPreparation: "Parse and validate rules/static.json before timing",
                sampleBoundary: "Create a fresh FloorpWebExtensionDNRStore from the same immutable 5000-rule value array",
                cacheTreatment: "No native transform cache exists; every measured sample creates a new store",
                warmupSampleCount: warmupSampleCount,
                measuredSampleCount: measuredSampleCount
            ),
            nativeTransform: .init(samplesMilliseconds: samples),
            outcome: .init(
                compiledRuleCount: compilation.compiledRules.count,
                acceptedRuleCount: compilation.report.acceptedRuleCount,
                transformedRuleCount: compilation.report.transformedRuleCount,
                rejectedRuleCount: compilation.report.rejectedRuleCount
            ),
            unmeasuredScopes: NativeTransformEvidence.requiredUnmeasuredScopes
        )

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-stage3-performance-tests", isDirectory: true)
            .appendingPathComponent(artifact.runIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let artifactURL = outputDirectory.appendingPathComponent("native-dnr-transform.json")
        let encoded = try NativeTransformEvidenceVerifier.encode(artifact)
        try encoded.write(to: artifactURL, options: [.atomic, .completeFileProtectionUnlessOpen])

        let decoded = try NativeTransformEvidenceVerifier.decode(Data(contentsOf: artifactURL))
        XCTAssertEqual(decoded, artifact)
        try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyDemandingFixtureBinding(decoded.fixture)

        let attachment = XCTAttachment(contentsOfFile: artifactURL)
        attachment.name = "Stage 3 demanding-mv3 native DNR transform evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("FLOORP_STAGE3_NATIVE_DNR_EVIDENCE=\(artifactURL.path)")
    }

    private func measuredNativeTransform(
        rules: [FloorpWebExtensionDNRRule]
    ) async throws -> (compilation: FloorpWebExtensionDNRCompilation, durationMilliseconds: Double) {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            throw evidenceError("Unable to read the monotonic clock timebase.")
        }

        let started = mach_continuous_time()
        let store = try FloorpWebExtensionDNRStore(
            staticRuleSets: [.init(identifier: staticRuleSetIdentifier, rules: rules)],
            enabledStaticRuleSetIDs: [staticRuleSetIdentifier]
        )
        let finished = mach_continuous_time()
        let elapsedTicks = finished &- started
        let elapsedNanoseconds = Double(elapsedTicks) * Double(timebase.numer) / Double(timebase.denom)
        let elapsedMilliseconds = elapsedNanoseconds / 1_000_000
        guard elapsedMilliseconds.isFinite, elapsedMilliseconds > 0 else {
            throw evidenceError("The monotonic native-transform duration was invalid.")
        }

        // Compilation is produced synchronously by the actor initializer. An
        // isolated read after the clock boundary does not inflate the sample.
        return (await store.currentCompilation(), elapsedMilliseconds)
    }

    private func verifyCompilation(_ compilation: FloorpWebExtensionDNRCompilation) throws {
        guard compilation.compiledRules.count == 5_000,
              compilation.report.acceptedRuleCount == 0,
              compilation.report.transformedRuleCount == 5_000,
              compilation.report.rejectedRuleCount == 0,
              !compilation.report.hasRejections else {
            throw evidenceError("The demanding fixture native transform did not preserve its 5000-rule invariant.")
        }
    }

    private func currentEnvironment() -> NativeTransformEnvironment {
        var system = utsname()
        uname(&system)
        let architecture = withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        let environment = ProcessInfo.processInfo.environment
        return NativeTransformEnvironment(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            modelIdentifier: environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unavailable",
            deviceIdentifier: environment["SIMULATOR_UDID"] ?? "unavailable",
            architecture: architecture,
            isSimulator: isSimulator
        )
    }

    private func checkedInFixtureDirectory(named fixtureName: String) throws -> URL {
        let fileManager = FileManager.default
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let fixturePath = "firefox-ios/Floorp/WebExtensions/Fixtures/\(fixtureName)"

        for startingDirectory in [workingDirectory, sourceDirectory] {
            var directory = startingDirectory.standardizedFileURL
            while true {
                let candidate = directory.appendingPathComponent(fixturePath, isDirectory: true)
                if fileManager.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                    return candidate
                }
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { break }
                directory = parent
            }
        }
        throw evidenceError("The checked-in \(fixtureName) fixture was not found.")
    }

    private func materializeStaticRules(from data: Data) throws -> [FloorpWebExtensionDNRRule] {
        let rawRules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            "The demanding fixture must contain a JSON rule array."
        )
        let supportedConditionKeys: Set<String> = ["urlFilter", "resourceTypes"]
        return try rawRules.map { rawRule in
            let id = try XCTUnwrap(rawRule["id"] as? Int)
            let priority = rawRule["priority"] as? Int ?? 1
            let actionObject = try XCTUnwrap(rawRule["action"] as? [String: Any])
            let actionType = try XCTUnwrap(
                FloorpWebExtensionDNRActionType(rawValue: try XCTUnwrap(actionObject["type"] as? String))
            )
            let conditionObject = try XCTUnwrap(rawRule["condition"] as? [String: Any])
            guard Set(conditionObject.keys).isSubset(of: supportedConditionKeys) else {
                throw evidenceError("The demanding fixture contains an unsupported condition key.")
            }
            let resourceTypes = try (conditionObject["resourceTypes"] as? [String] ?? []).map {
                try XCTUnwrap(FloorpWebExtensionDNRResourceType(rawValue: $0))
            }
            return .init(
                id: id,
                priority: priority,
                action: .init(type: actionType),
                condition: .init(
                    urlFilter: conditionObject["urlFilter"] as? String,
                    resourceTypes: resourceTypes
                )
            )
        }
    }
}

private struct NativeTransformEvidence: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let requiredUnmeasuredScopes = ["webKitCompilation", "pageLoad", "memoryPressureRecovery"]

    let schemaVersion: Int
    let recordClassification: String
    let runIdentifier: String
    let recordedAt: Date
    let environment: NativeTransformEnvironment
    let fixture: FloorpWebExtensionPerformanceFixtureEvidence
    let measurementProtocol: NativeTransformProtocol
    let nativeTransform: FloorpWebExtensionPerformanceSampleSeries
    let outcome: NativeTransformOutcome
    let unmeasuredScopes: [String]

    init(
        runIdentifier: String,
        recordedAt: Date,
        environment: NativeTransformEnvironment,
        fixture: FloorpWebExtensionPerformanceFixtureEvidence,
        measurementProtocol: NativeTransformProtocol,
        nativeTransform: FloorpWebExtensionPerformanceSampleSeries,
        outcome: NativeTransformOutcome,
        unmeasuredScopes: [String]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        recordClassification = "native-transform-record-only"
        self.runIdentifier = runIdentifier
        self.recordedAt = recordedAt
        self.environment = environment
        self.fixture = fixture
        self.measurementProtocol = measurementProtocol
        self.nativeTransform = nativeTransform
        self.outcome = outcome
        self.unmeasuredScopes = unmeasuredScopes
        try validate()
    }

    fileprivate func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              recordClassification == "native-transform-record-only",
              runIdentifier.hasPrefix("native-dnr-"),
              recordedAt.timeIntervalSinceReferenceDate.isFinite,
              measurementProtocol.clock == "mach_continuous_time",
              measurementProtocol.measuredSampleCount == nativeTransform.samplesMilliseconds.count,
              measurementProtocol.warmupSampleCount >= 0,
              measurementProtocol.measuredSampleCount >= 3,
              outcome.compiledRuleCount == fixture.enabledRuleCount,
              outcome.acceptedRuleCount == 0,
              outcome.transformedRuleCount == fixture.transformedRuleCount,
              outcome.rejectedRuleCount == fixture.rejectedRuleCount,
              unmeasuredScopes == Self.requiredUnmeasuredScopes else {
            throw evidenceError("Invalid native-transform-only performance evidence.")
        }
        try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyDemandingFixtureBinding(fixture)
    }
}

private struct NativeTransformEnvironment: Codable, Equatable {
    let operatingSystem: String
    let modelIdentifier: String
    let deviceIdentifier: String
    let architecture: String
    let isSimulator: Bool
}

private struct NativeTransformProtocol: Codable, Equatable {
    let clock: String
    let inputPreparation: String
    let sampleBoundary: String
    let cacheTreatment: String
    let warmupSampleCount: Int
    let measuredSampleCount: Int
}

private struct NativeTransformOutcome: Codable, Equatable {
    let compiledRuleCount: Int
    let acceptedRuleCount: Int
    let transformedRuleCount: Int
    let rejectedRuleCount: Int
}

private enum NativeTransformEvidenceVerifier {
    private static let expectedTopLevelKeys: Set<String> = [
        "schemaVersion", "recordClassification", "runIdentifier", "recordedAt", "environment",
        "fixture", "measurementProtocol", "nativeTransform", "outcome", "unmeasuredScopes"
    ]
    private static let expectedEnvironmentKeys: Set<String> = [
        "operatingSystem", "modelIdentifier", "deviceIdentifier", "architecture", "isSimulator"
    ]
    private static let expectedProtocolKeys: Set<String> = [
        "clock", "inputPreparation", "sampleBoundary", "cacheTreatment", "warmupSampleCount", "measuredSampleCount"
    ]
    private static let expectedOutcomeKeys: Set<String> = [
        "compiledRuleCount", "acceptedRuleCount", "transformedRuleCount", "rejectedRuleCount"
    ]

    static func encode(_ evidence: NativeTransformEvidence) throws -> Data {
        try evidence.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(evidence)
    }

    static func decode(_ data: Data) throws -> NativeTransformEvidence {
        guard !data.isEmpty, data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expectedTopLevelKeys,
              let environment = object["environment"] as? [String: Any],
              Set(environment.keys) == expectedEnvironmentKeys,
              let measurementProtocol = object["measurementProtocol"] as? [String: Any],
              Set(measurementProtocol.keys) == expectedProtocolKeys,
              let outcome = object["outcome"] as? [String: Any],
              Set(outcome.keys) == expectedOutcomeKeys else {
            throw evidenceError("Native-transform evidence has unknown, missing, or oversized content.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let evidence = try decoder.decode(NativeTransformEvidence.self, from: data)
        try evidence.validate()
        return evidence
    }
}

private func evidenceError(_ message: String) -> NSError {
    NSError(
        domain: "FloorpWebExtensionStage3NativeDNRPerformanceTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
