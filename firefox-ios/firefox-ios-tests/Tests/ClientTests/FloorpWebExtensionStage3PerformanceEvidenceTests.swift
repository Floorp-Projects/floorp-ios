// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation
import XCTest
@testable import Client

final class FloorpWebExtensionStage3PerformanceEvidenceTests: XCTestCase {
    private struct ArtifactFixtureFile {
        let relativePath: String
        let kind: FloorpWebExtensionPerformanceArtifactKind
        let data: Data
    }

    private final class SemanticValidator: FloorpWebExtensionPerformanceArtifactSemanticValidating {
        static let xcresultPayload = Data("validated-xcresult-fixture-v1".utf8)
        static let profilePayload = Data("validated-performance-profile-fixture-v1".utf8)

        private(set) var validatedKinds = [FloorpWebExtensionPerformanceArtifactKind]()
        private(set) var observedSHA256 = [FloorpWebExtensionPerformanceArtifactKind: String]()
        private(set) var observedByteCounts = [FloorpWebExtensionPerformanceArtifactKind: Int64]()
        private(set) var observedChunkCounts = [FloorpWebExtensionPerformanceArtifactKind: Int]()
        private(set) var observedMaximumChunkByteCounts = [FloorpWebExtensionPerformanceArtifactKind: Int]()
        private(set) var interruptedReadKinds = [FloorpWebExtensionPerformanceArtifactKind]()
        private(set) var didSwapOriginalPath = false
        private let expectedSHA256: [FloorpWebExtensionPerformanceArtifactKind: String]
        private let expectedByteCounts: [FloorpWebExtensionPerformanceArtifactKind: Int64]
        var rejectedKind: FloorpWebExtensionPerformanceArtifactKind?
        var attestedRunIdentifier: String?
        var attestedSourceRevision: String?
        var attestedSHA256: String?
        var attestedByteCount: Int64?
        var swapOriginalPathWhenValidatingKind: FloorpWebExtensionPerformanceArtifactKind?
        var originalPathToSwap: URL?
        var alternatePayload = Data()
        var interruptReadBeforeValidationKind: FloorpWebExtensionPerformanceArtifactKind?

        init(
            xcresultPayload: Data = SemanticValidator.xcresultPayload,
            profilePayload: Data = SemanticValidator.profilePayload
        ) {
            expectedSHA256 = [
                .testResultBundle: Self.sha256(xcresultPayload),
                .performanceProfile: Self.sha256(profilePayload)
            ]
            expectedByteCounts = [
                .testResultBundle: Int64(xcresultPayload.count),
                .performanceProfile: Int64(profilePayload.count)
            ]
        }

        func validateArtifact(
            _ snapshot: FloorpWebExtensionPerformanceArtifactValidatedSnapshot,
            evidence: FloorpWebExtensionStage3PerformanceEvidence
        ) throws -> FloorpWebExtensionPerformanceArtifactSemanticAttestation {
            let kind = snapshot.artifactKind
            XCTAssertNotEqual(kind, .measurementRecord)
            validatedKinds.append(kind)
            if rejectedKind == kind {
                throw NSError(domain: "SemanticValidator", code: 1)
            }

            if swapOriginalPathWhenValidatingKind == kind,
               let originalPathToSwap {
                try alternatePayload.write(to: originalPathToSwap, options: .atomic)
                didSwapOriginalPath = true
            }

            if interruptReadBeforeValidationKind == kind {
                XCTAssertThrowsError(
                    try snapshot.forEachDataChunk { _ in
                        throw NSError(domain: "SemanticValidator", code: 4)
                    },
                    "A semantic validator's interrupted stream must report its consume error."
                )
                interruptedReadKinds.append(kind)
            }

            guard kind != .measurementRecord,
                  let expectedSHA256 = self.expectedSHA256[kind],
                  let expectedByteCount = self.expectedByteCounts[kind] else {
                throw NSError(domain: "SemanticValidator", code: 2)
            }

            var digest = SHA256()
            var observedByteCount: Int64 = 0
            var observedChunkCount = 0
            var observedMaximumChunkByteCount = 0
            try snapshot.forEachDataChunk { chunk in
                digest.update(data: chunk)
                observedByteCount += Int64(chunk.count)
                observedChunkCount += 1
                observedMaximumChunkByteCount = max(observedMaximumChunkByteCount, chunk.count)
            }
            let observedDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
            observedSHA256[kind] = observedDigest
            observedByteCounts[kind] = observedByteCount
            observedChunkCounts[kind] = observedChunkCount
            observedMaximumChunkByteCounts[kind] = observedMaximumChunkByteCount
            guard observedDigest == expectedSHA256,
                  observedByteCount == expectedByteCount else {
                throw NSError(domain: "SemanticValidator", code: 3)
            }
            return try .init(
                artifactKind: kind,
                runIdentifier: attestedRunIdentifier ?? evidence.runIdentifier,
                associatedSourceRevision: attestedSourceRevision ?? evidence.associatedSourceRevision,
                sha256: attestedSHA256 ?? snapshot.sha256,
                byteCount: attestedByteCount ?? snapshot.byteCount
            )
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    func testComputesStatisticsAndPreservesSignedPageDelta() throws {
        let series = try FloorpWebExtensionPerformanceSampleSeries(
            samplesMilliseconds: [4, 1, 3, 2]
        )

        XCTAssertEqual(series.statistics.sampleCount, 4)
        XCTAssertEqual(series.statistics.minimum, 1)
        XCTAssertEqual(series.statistics.maximum, 4)
        XCTAssertEqual(series.statistics.mean, 2.5)
        XCTAssertEqual(series.statistics.median, 2.5)
        XCTAssertEqual(series.statistics.percentile95, 4)
        XCTAssertEqual(series.statistics.populationStandardDeviation, sqrt(1.25), accuracy: 1e-12)

        let pageLoad = try FloorpWebExtensionPerformancePageLoadEvidence(
            baseline: try .init(samplesMilliseconds: [10, 12, 14]),
            fixtureEnabled: try .init(samplesMilliseconds: [8, 9, 10])
        )
        XCTAssertEqual(pageLoad.signedMeanDeltaMilliseconds, -3, accuracy: 1e-12)
    }

    func testStrictVerifierRoundTripsCompleteVersionedEvidence() throws {
        let artifactFixture = try makeArtifactFixture()
        defer { try? FileManager.default.removeItem(at: artifactFixture.directory) }
        let evidence = try makeEvidence(artifacts: artifactFixture.artifacts)
        let semanticValidator = SemanticValidator()

        let data = try FloorpWebExtensionStage3PerformanceEvidenceVerifier.encode(evidence)
        let decoded = try FloorpWebExtensionStage3PerformanceEvidenceVerifier.decode(data)

        XCTAssertEqual(decoded, evidence)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.fixture.totalRuleCount, 5_000)
        XCTAssertEqual(decoded.compileSpans.webKitCold.statistics.sampleCount, 3)
        XCTAssertEqual(decoded.memory.signedResidentDeltaBytes, 4_096)
        let requiredArtifactKinds = FloorpWebExtensionStage3PerformanceEvidenceVerifier.requiredAcceptanceArtifactKinds
        XCTAssertEqual(Set(decoded.artifacts.map(\.kind)), requiredArtifactKinds)
        XCTAssertNoThrow(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                decoded,
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: semanticValidator
            )
        )
        XCTAssertEqual(Set(semanticValidator.validatedKinds), [.testResultBundle, .performanceProfile])
        XCTAssertEqual(semanticValidator.validatedKinds.count, 2)

        let interruptedReadValidator = SemanticValidator()
        interruptedReadValidator.interruptReadBeforeValidationKind = .performanceProfile
        XCTAssertNoThrow(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                decoded,
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: interruptedReadValidator
            ),
            "A consumed stream that throws must rewind before the semantic validator reads it again."
        )
        XCTAssertEqual(interruptedReadValidator.interruptedReadKinds, [.performanceProfile])
        XCTAssertEqual(
            interruptedReadValidator.observedSHA256[.performanceProfile],
            SHA256.hash(data: SemanticValidator.profilePayload).map { String(format: "%02x", $0) }.joined(),
            "The follow-up semantic read must restart at offset zero after a consume error."
        )

        let swappedPathFixture = try makeArtifactFixture()
        defer { try? FileManager.default.removeItem(at: swappedPathFixture.directory) }
        let profileArtifact = try XCTUnwrap(
            swappedPathFixture.artifacts.first(where: { $0.kind == .performanceProfile })
        )
        let profileURL = swappedPathFixture.directory.appendingPathComponent(profileArtifact.relativePath)
        let alternateProfilePayload = Data(repeating: 0xa5, count: SemanticValidator.profilePayload.count)
        XCTAssertNotEqual(alternateProfilePayload, SemanticValidator.profilePayload)
        let swappingValidator = SemanticValidator()
        swappingValidator.swapOriginalPathWhenValidatingKind = .testResultBundle
        swappingValidator.originalPathToSwap = profileURL
        swappingValidator.alternatePayload = alternateProfilePayload
        XCTAssertNoThrow(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: swappedPathFixture.artifacts),
                evidenceDirectory: swappedPathFixture.directory,
                semanticValidator: swappingValidator
            ),
            "Semantic validation must inspect the immutable profile snapshot even if its original path is " +
                "atomically replaced after manifest validation."
        )
        XCTAssertTrue(swappingValidator.didSwapOriginalPath)
        XCTAssertEqual(try Data(contentsOf: profileURL), alternateProfilePayload)
        XCTAssertEqual(
            swappingValidator.observedSHA256[.performanceProfile],
            SHA256.hash(data: SemanticValidator.profilePayload).map { String(format: "%02x", $0) }.joined(),
            "The validator must never observe replacement bytes from the original path."
        )
        XCTAssertNoThrow(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyDemandingFixtureBinding(
                decoded.fixture
            )
        )
        let wrongFixture = try FloorpWebExtensionStage3PerformanceEvidenceVerifier.decode(
            try decodeDataByMutating(
                FloorpWebExtensionStage3PerformanceEvidenceVerifier.encode(decoded)
            ) { object in
                var fixture = try XCTUnwrap(object["fixture"] as? [String: Any])
                fixture["packageSHA256"] = String(repeating: "c", count: 64)
                object["fixture"] = fixture
            }
        )
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                wrongFixture,
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: SemanticValidator()
            )
        )
        let wrongRulePartition = try FloorpWebExtensionStage3PerformanceEvidenceVerifier.decode(
            try decodeDataByMutating(
                FloorpWebExtensionStage3PerformanceEvidenceVerifier.encode(decoded)
            ) { object in
                var fixture = try XCTUnwrap(object["fixture"] as? [String: Any])
                fixture["staticRuleCount"] = 4_999
                fixture["dynamicRuleCount"] = 1
                object["fixture"] = fixture
            }
        )
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                wrongRulePartition,
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: SemanticValidator()
            )
        )
    }

    func testSourceRevisionRequiresASCIIHexGitObjectID() throws {
        for revision in [
            String(repeating: "a", count: 40),
            String(repeating: "F", count: 64),
        ] {
            let evidence = try makeEvidence(associatedSourceRevision: revision)
            let decoded = try FloorpWebExtensionStage3PerformanceEvidenceVerifier.decode(
                FloorpWebExtensionStage3PerformanceEvidenceVerifier.encode(evidence)
            )
            XCTAssertEqual(decoded.associatedSourceRevision, revision.lowercased())
        }

        for revision in [
            String(repeating: "ａ", count: 40),
            String(repeating: "０", count: 64),
        ] {
            XCTAssertThrowsError(
                try makeEvidence(associatedSourceRevision: revision),
                "Unicode hexadecimal characters are not Git object IDs."
            )
        }
    }

    func testRejectsTamperedDerivedStatisticsPageAndMemoryDeltas() throws {
        let original = try FloorpWebExtensionStage3PerformanceEvidenceVerifier.encode(makeEvidence())

        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var compileSpans = try XCTUnwrap(object["compileSpans"] as? [String: Any])
                var nativeCold = try XCTUnwrap(compileSpans["nativeCold"] as? [String: Any])
                var statistics = try XCTUnwrap(nativeCold["statistics"] as? [String: Any])
                statistics["mean"] = 999
                nativeCold["statistics"] = statistics
                compileSpans["nativeCold"] = nativeCold
                object["compileSpans"] = compileSpans
            }
        )

        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var pageLoad = try XCTUnwrap(object["pageLoad"] as? [String: Any])
                pageLoad["signedMeanDeltaMilliseconds"] = 0
                object["pageLoad"] = pageLoad
            }
        )

        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var memory = try XCTUnwrap(object["memory"] as? [String: Any])
                memory["signedResidentDeltaBytes"] = 0
                object["memory"] = memory
            }
        )
    }

    func testRejectsUnknownKeysUnsafePathsAndInconsistentCounts() throws {
        let original = try FloorpWebExtensionStage3PerformanceEvidenceVerifier.encode(makeEvidence())

        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var build = try XCTUnwrap(object["build"] as? [String: Any])
                build["unreviewedToolchain"] = "unknown"
                object["build"] = build
            }
        )
        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
                artifacts[0]["relativePath"] = "../escaped.trace"
                object["artifacts"] = artifacts
            }
        )
        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var measurementProtocol = try XCTUnwrap(object["measurementProtocol"] as? [String: Any])
                measurementProtocol["compileSampleCount"] = 4
                object["measurementProtocol"] = measurementProtocol
            }
        )
        XCTAssertThrowsError(
            try FloorpWebExtensionPerformanceFixtureEvidence(
                identifier: "demanding-mv3",
                version: "1.0.0",
                packageSHA256: String(repeating: "a", count: 64),
                integrityVerified: true,
                staticRuleCount: 5_000,
                dynamicRuleCount: 1,
                sessionRuleCount: 1,
                totalRuleCount: 5_000,
                enabledRuleCount: 5_000,
                transformedRuleCount: 5_000,
                rejectedRuleCount: 2
            )
        )
        XCTAssertThrowsError(
            try FloorpWebExtensionPerformanceSampleSeries(samplesMilliseconds: [-1])
        )
    }

    // swiftlint:disable:next function_body_length
    func testArtifactManifestBindsContentAndAcceptanceRequiresExactKinds() throws {
        let original = try FloorpWebExtensionStage3PerformanceEvidenceVerifier.encode(makeEvidence())
        let artifactFixture = try makeArtifactFixture()
        defer { try? FileManager.default.removeItem(at: artifactFixture.directory) }
        let boundEvidence = try makeEvidence(artifacts: artifactFixture.artifacts)
        let semanticValidator = SemanticValidator()

        XCTAssertNoThrow(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                boundEvidence,
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: semanticValidator
            )
        )
        XCTAssertEqual(Set(semanticValidator.validatedKinds), [.testResultBundle, .performanceProfile])
        XCTAssertEqual(semanticValidator.validatedKinds.count, 2)

        let firstArtifact = try XCTUnwrap(boundEvidence.artifacts.first)
        let firstArtifactURL = artifactFixture.directory.appendingPathComponent(firstArtifact.relativePath)
        let originalArtifactData = try Data(contentsOf: firstArtifactURL)
        var tamperedArtifactData = originalArtifactData
        tamperedArtifactData[0] ^= 0xff
        try tamperedArtifactData.write(to: firstArtifactURL, options: .atomic)
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                boundEvidence,
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: SemanticValidator()
            ),
            "Acceptance must reject an artifact whose digest no longer matches, even when its byte count is unchanged."
        )

        try originalArtifactData.write(to: firstArtifactURL, options: .atomic)
        try FileManager.default.removeItem(at: firstArtifactURL)
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                boundEvidence,
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: SemanticValidator()
            ),
            "Acceptance must reject a missing artifact."
        )

        let externalArtifactURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpStage3ExternalArtifact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: externalArtifactURL) }
        try originalArtifactData.write(to: externalArtifactURL, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: firstArtifactURL,
            withDestinationURL: externalArtifactURL
        )
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                boundEvidence,
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: SemanticValidator()
            ),
            "Acceptance must reject an artifact symlink even when its target content matches the manifest."
        )

        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
                artifacts[0]["unexpected"] = true
                object["artifacts"] = artifacts
            }
        )
        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
                artifacts[1]["relativePath"] = artifacts[0]["relativePath"]
                object["artifacts"] = artifacts
            }
        )
        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
                artifacts[1]["kind"] = artifacts[0]["kind"]
                object["artifacts"] = artifacts
            }
        )
        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
                artifacts[0]["sha256"] = String(repeating: "f", count: 63)
                object["artifacts"] = artifacts
            }
        )
        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
                artifacts[0]["byteCount"] = 0
                object["artifacts"] = artifacts
            }
        )
        XCTAssertThrowsError(
            try decodeByMutating(original) { object in
                var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
                artifacts[0]["byteCount"] = FloorpWebExtensionPerformanceArtifact.maximumByteCount + 1
                object["artifacts"] = artifacts
            }
        )

        for missingKind in FloorpWebExtensionPerformanceArtifactKind.allCases {
            let incomplete = try decodeByMutating(original) { object in
                var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
                artifacts.removeAll { artifact in
                    artifact["kind"] as? String == missingKind.rawValue
                }
                object["artifacts"] = artifacts
            }
            XCTAssertNoThrow(
                try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifySuccessfulRun(incomplete)
            )
            XCTAssertThrowsError(
                try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                    incomplete,
                    evidenceDirectory: artifactFixture.directory,
                    semanticValidator: SemanticValidator()
                ),
                "Acceptance must reject evidence missing \(missingKind.rawValue)."
            )
        }

        let arbitraryFiles: [ArtifactFixtureFile] = [
            .init(
                relativePath: "artifacts/stage3-ios26.5-simulator-001.xcresult.zip",
                kind: .testResultBundle,
                data: Data("xcresult-archive".utf8)
            ),
            .init(
                relativePath: "artifacts/stage3-ios26.5-simulator-001.trace.zip",
                kind: .performanceProfile,
                data: Data("performance-profile".utf8)
            ),
            .init(
                relativePath: "artifacts/stage3-ios26.5-simulator-001-samples.json",
                kind: .measurementRecord,
                data: Data("{\"samples\":[1,2,3]}".utf8)
            )
        ]
        let arbitraryFixture = try writeArtifactFixture(files: arbitraryFiles)
        defer { try? FileManager.default.removeItem(at: arbitraryFixture.directory) }
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: arbitraryFixture.artifacts),
                evidenceDirectory: arbitraryFixture.directory,
                semanticValidator: SemanticValidator()
            ),
            "Kind labels and matching digests must not turn arbitrary text into acceptance artifacts."
        )

        let foreignFixture = try makeArtifactFixture()
        defer { try? FileManager.default.removeItem(at: foreignFixture.directory) }
        let foreignValidator = SemanticValidator()
        foreignValidator.attestedRunIdentifier = "stage3-foreign-run"
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: foreignFixture.artifacts),
                evidenceDirectory: foreignFixture.directory,
                semanticValidator: foreignValidator
            ),
            "A semantic attestation for another run must not satisfy acceptance."
        )

        let foreignSourceValidator = SemanticValidator()
        foreignSourceValidator.attestedSourceRevision = String(repeating: "f", count: 40)
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: foreignFixture.artifacts),
                evidenceDirectory: foreignFixture.directory,
                semanticValidator: foreignSourceValidator
            ),
            "A semantic attestation for another source revision must not satisfy acceptance."
        )

        let wrongDigestValidator = SemanticValidator()
        wrongDigestValidator.attestedSHA256 = String(repeating: "f", count: 64)
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: foreignFixture.artifacts),
                evidenceDirectory: foreignFixture.directory,
                semanticValidator: wrongDigestValidator
            ),
            "A semantic attestation for different bytes must not satisfy acceptance."
        )

        let wrongByteCountValidator = SemanticValidator()
        wrongByteCountValidator.attestedByteCount = 1
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: foreignFixture.artifacts),
                evidenceDirectory: foreignFixture.directory,
                semanticValidator: wrongByteCountValidator
            ),
            "A semantic attestation with a different byte count must not satisfy acceptance."
        )

        for rejectedKind in [
            FloorpWebExtensionPerformanceArtifactKind.testResultBundle,
            .performanceProfile
        ] {
            let rejectingValidator = SemanticValidator()
            rejectingValidator.rejectedKind = rejectedKind
            XCTAssertThrowsError(
                try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                    makeEvidence(artifacts: foreignFixture.artifacts),
                    evidenceDirectory: foreignFixture.directory,
                    semanticValidator: rejectingValidator
                ),
                "Complete acceptance must fail closed when trusted \(rejectedKind.rawValue) inspection fails."
            )
        }

        let foreignMeasurementFixture = try makeArtifactFixture()
        defer { try? FileManager.default.removeItem(at: foreignMeasurementFixture.directory) }
        let measurementArtifact = try XCTUnwrap(
            foreignMeasurementFixture.artifacts.first(where: { $0.kind == .measurementRecord })
        )
        let measurementURL = foreignMeasurementFixture.directory.appendingPathComponent(measurementArtifact.relativePath)
        var measurementObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: measurementURL)) as? [String: Any]
        )
        measurementObject["associatedSourceRevision"] = String(repeating: "f", count: 40)
        let foreignMeasurementData = try JSONSerialization.data(withJSONObject: measurementObject, options: [.sortedKeys])
        let foreignMeasurementArtifacts = try replacingArtifact(
            .measurementRecord,
            data: foreignMeasurementData,
            in: foreignMeasurementFixture
        )
        let measurementValidator = SemanticValidator()
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: foreignMeasurementArtifacts),
                evidenceDirectory: foreignMeasurementFixture.directory,
                semanticValidator: measurementValidator
            ),
            "Raw samples from another source revision must not satisfy acceptance."
        )
        XCTAssertTrue(
            measurementValidator.validatedKinds.isEmpty,
            "Local measurement validation must fail before trusted binary tooling is invoked."
        )

        let foreignBuildFixture = try makeArtifactFixture()
        defer { try? FileManager.default.removeItem(at: foreignBuildFixture.directory) }
        let buildMeasurementArtifact = try XCTUnwrap(
            foreignBuildFixture.artifacts.first(where: { $0.kind == .measurementRecord })
        )
        let buildMeasurementURL = foreignBuildFixture.directory.appendingPathComponent(
            buildMeasurementArtifact.relativePath
        )
        var buildMeasurementObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: buildMeasurementURL)) as? [String: Any]
        )
        var recordedBuild = try XCTUnwrap(buildMeasurementObject["build"] as? [String: Any])
        recordedBuild["configuration"] = "Different release configuration"
        buildMeasurementObject["build"] = recordedBuild
        let foreignBuildMeasurementData = try JSONSerialization.data(
            withJSONObject: buildMeasurementObject,
            options: [.sortedKeys]
        )
        let foreignBuildArtifacts = try replacingArtifact(
            .measurementRecord,
            data: foreignBuildMeasurementData,
            in: foreignBuildFixture
        )
        let buildMeasurementValidator = SemanticValidator()
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: foreignBuildArtifacts),
                evidenceDirectory: foreignBuildFixture.directory,
                semanticValidator: buildMeasurementValidator
            ),
            "A measurement record describing another build must not satisfy acceptance."
        )
        XCTAssertTrue(
            buildMeasurementValidator.validatedKinds.isEmpty,
            "Measurement metadata must fail before trusted binary tooling is invoked."
        )
    }

    func testRejectsOversizedAndCumulativeArtifactManifestsBeforeFileAccess() throws {
        XCTAssertThrowsError(
            try FloorpWebExtensionPerformanceArtifact(
                relativePath: "artifacts/oversized.xcresult.zip",
                kind: .testResultBundle,
                sha256: String(repeating: "a", count: 64),
                byteCount: FloorpWebExtensionPerformanceArtifactKind.testResultBundle.maximumByteCount + 1
            )
        )

        let artifacts = try [
            FloorpWebExtensionPerformanceArtifact(
                relativePath: "artifacts/budget.xcresult.zip",
                kind: .testResultBundle,
                sha256: String(repeating: "a", count: 64),
                byteCount: FloorpWebExtensionPerformanceArtifactKind.testResultBundle.maximumByteCount
            ),
            FloorpWebExtensionPerformanceArtifact(
                relativePath: "artifacts/budget.trace.zip",
                kind: .performanceProfile,
                sha256: String(repeating: "b", count: 64),
                byteCount: FloorpWebExtensionPerformanceArtifactKind.performanceProfile.maximumByteCount
            ),
            FloorpWebExtensionPerformanceArtifact(
                relativePath: "artifacts/budget-samples.json",
                kind: .measurementRecord,
                sha256: String(repeating: "c", count: 64),
                byteCount: 1
            )
        ]
        let nonexistentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpStage3MissingEvidence-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonexistentDirectory.path))

        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: artifacts),
                evidenceDirectory: nonexistentDirectory,
                semanticValidator: SemanticValidator()
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("cumulative snapshot budget"))
        }
    }

    func testRejectsSparseArtifactBeforeSnapshotCopy() throws {
        let artifactFixture = try makeArtifactFixture()
        defer { try? FileManager.default.removeItem(at: artifactFixture.directory) }
        let originalArtifact = try XCTUnwrap(
            artifactFixture.artifacts.first(where: { $0.kind == .testResultBundle })
        )
        let artifactURL = artifactFixture.directory.appendingPathComponent(originalArtifact.relativePath)
        try FileManager.default.removeItem(at: artifactURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: artifactURL.path, contents: Data([0x5a])))
        let sparseByteCount: Int64 = 64 * 1_024 * 1_024
        let fileHandle = try FileHandle(forWritingTo: artifactURL)
        try fileHandle.truncate(atOffset: UInt64(sparseByteCount))
        try fileHandle.close()

        let sparseArtifacts = try artifactFixture.artifacts.map { artifact in
            guard artifact.kind == .testResultBundle else { return artifact }
            return try FloorpWebExtensionPerformanceArtifact(
                relativePath: artifact.relativePath,
                kind: artifact.kind,
                sha256: String(repeating: "d", count: 64),
                byteCount: sparseByteCount
            )
        }
        let semanticValidator = SemanticValidator()
        XCTAssertThrowsError(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: sparseArtifacts),
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: semanticValidator
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("sparse"))
        }
        XCTAssertTrue(semanticValidator.validatedKinds.isEmpty)
    }

    func testSemanticValidatorStreamsLargeBinaryArtifactInBoundedChunks() throws {
        let baseEvidence = try makeEvidence()
        let chunkLimit = FloorpWebExtensionPerformanceArtifactValidatedSnapshot
            .maximumStreamingChunkByteCount
        let largeProfilePayload = Data(repeating: 0x7c, count: (chunkLimit * 3) + 37)
        let artifactFiles: [ArtifactFixtureFile] = [
            .init(
                relativePath: "artifacts/stage3-ios26.5-simulator-001.xcresult.zip",
                kind: .testResultBundle,
                data: SemanticValidator.xcresultPayload
            ),
            .init(
                relativePath: "artifacts/stage3-ios26.5-simulator-001.trace.zip",
                kind: .performanceProfile,
                data: largeProfilePayload
            ),
            .init(
                relativePath: "artifacts/stage3-ios26.5-simulator-001-samples.json",
                kind: .measurementRecord,
                data: try FloorpWebExtensionStage3PerformanceEvidenceVerifier.measurementRecordData(
                    for: baseEvidence
                )
            )
        ]
        let artifactFixture = try writeArtifactFixture(files: artifactFiles)
        defer { try? FileManager.default.removeItem(at: artifactFixture.directory) }
        let semanticValidator = SemanticValidator(profilePayload: largeProfilePayload)

        XCTAssertNoThrow(
            try FloorpWebExtensionStage3PerformanceEvidenceVerifier.verifyAcceptance(
                makeEvidence(artifacts: artifactFixture.artifacts),
                evidenceDirectory: artifactFixture.directory,
                semanticValidator: semanticValidator
            )
        )
        XCTAssertEqual(
            semanticValidator.observedByteCounts[.performanceProfile],
            Int64(largeProfilePayload.count)
        )
        XCTAssertGreaterThan(semanticValidator.observedChunkCounts[.performanceProfile] ?? 0, 1)
        XCTAssertLessThanOrEqual(
            semanticValidator.observedMaximumChunkByteCounts[.performanceProfile] ?? .max,
            chunkLimit
        )
    }

    func testFailedRunRequiresAndRetainsFailureDescriptions() throws {
        XCTAssertThrowsError(
            try makeEvidence(
                recoverySucceeded: false,
                postRecoveryFunctionalCheckPassed: false,
                failures: []
            )
        )
        XCTAssertThrowsError(
            try makeEvidence(
                recoverySucceeded: false,
                postRecoveryFunctionalCheckPassed: true,
                failures: ["Recovery did not complete."]
            )
        )

        let failed = try makeEvidence(
            recoverySucceeded: false,
            postRecoveryFunctionalCheckPassed: false,
            failures: ["WebContent recovery timed out after the memory-pressure action."]
        )
        let decoded = try FloorpWebExtensionStage3PerformanceEvidenceVerifier.decode(
            FloorpWebExtensionStage3PerformanceEvidenceVerifier.encode(failed)
        )

        XCTAssertFalse(decoded.memory.recoverySucceeded)
        XCTAssertEqual(decoded.failures.count, 1)
    }

    private func makeEvidence(
        runIdentifier: String = "stage3-ios26.5-simulator-001",
        associatedSourceRevision: String = String(repeating: "a", count: 40),
        recoverySucceeded: Bool = true,
        postRecoveryFunctionalCheckPassed: Bool = true,
        artifacts: [FloorpWebExtensionPerformanceArtifact]? = nil,
        failures: [String] = []
    ) throws -> FloorpWebExtensionStage3PerformanceEvidence {
        let nativeCold = try FloorpWebExtensionPerformanceSampleSeries(samplesMilliseconds: [38, 40, 42])
        let nativeWarm = try FloorpWebExtensionPerformanceSampleSeries(samplesMilliseconds: [3, 4, 5])
        let webKitCold = try FloorpWebExtensionPerformanceSampleSeries(samplesMilliseconds: [55, 57, 59])
        let webKitWarm = try FloorpWebExtensionPerformanceSampleSeries(samplesMilliseconds: [7, 8, 9])
        let evidenceArtifacts = try artifacts ?? placeholderArtifacts()

        return try FloorpWebExtensionStage3PerformanceEvidence(
            runIdentifier: runIdentifier,
            associatedSourceRevision: associatedSourceRevision,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            build: try .init(
                buildIdentifier: "Client-Debug-001",
                configuration: "Fennec Floorp Debug",
                appVersion: "1.0",
                appBuildNumber: "1",
                xcodeVersion: "Xcode 26.0 (17A123)",
                swiftVersion: "Swift 6.2",
                sdkName: "iphonesimulator26.0",
                sdkBuild: "23A123"
            ),
            device: try .init(
                model: "iPhone 17 Pro",
                identifier: "8167A41E-0E88-40A2-896B-0D939E2F941F",
                operatingSystem: "iOS 26.5",
                operatingSystemBuild: "23F5053",
                architecture: "arm64",
                isSimulator: true
            ),
            fixture: try .init(
                identifier: "demanding-mv3",
                version: "1.0.0",
                packageSHA256: FloorpWebExtensionStage3PerformanceEvidenceVerifier.demandingFixturePackageSHA256,
                integrityVerified: true,
                staticRuleCount: 5_000,
                dynamicRuleCount: 0,
                sessionRuleCount: 0,
                totalRuleCount: 5_000,
                enabledRuleCount: 5_000,
                transformedRuleCount: 5_000,
                rejectedRuleCount: 0
            ),
            measurementProtocol: try .init(
                measurementClock: "mach_continuous_time converted to milliseconds",
                resetBetweenColdSamples: "Terminate Client and recreate native and WebKit stores",
                resetBetweenWarmSamples: "Keep the compiled policy and repeat activation",
                resetBetweenPageSamples: "Create a new tab and wait for didFinish",
                coldCacheState: "Native and WebKit caches cleared before each measured sample",
                warmCacheState: "One unrecorded priming activation retained",
                pageCacheState: "URL cache disabled; alternating paired order",
                sampleOrder: "cold native, cold WebKit, warm native, warm WebKit; paired page baseline then fixture",
                warmupSampleCount: 1,
                compileSampleCount: 3,
                pageSampleCount: 3
            ),
            compileSpans: try .init(
                nativeCold: nativeCold,
                nativeWarm: nativeWarm,
                webKitCold: webKitCold,
                webKitWarm: webKitWarm
            ),
            pageLoad: try .init(
                baseline: try .init(samplesMilliseconds: [100, 102, 104]),
                fixtureEnabled: try .init(samplesMilliseconds: [105, 107, 109])
            ),
            memory: try .init(
                processName: "Client",
                processIdentifier: 42,
                baselineResidentBytes: 100_000,
                fixtureResidentBytes: 104_096,
                peakResidentBytes: 120_000,
                memoryPressureAction: "Simulator critical-memory warning followed by WebContent process termination",
                postPressureResidentBytes: 90_000,
                postRecoveryResidentBytes: 105_000,
                recoveryDurationMilliseconds: 250,
                recoverySucceeded: recoverySucceeded,
                postRecoveryFunctionalCheckPassed: postRecoveryFunctionalCheckPassed
            ),
            functionalChecks: [
                try .init(identifier: "dnr-block", passed: true, detail: "Block rule still matched."),
                try .init(identifier: "content-script", passed: true, detail: "Content script marker was present.")
            ],
            artifacts: evidenceArtifacts,
            failures: failures
        )
    }

    private func placeholderArtifacts() throws -> [FloorpWebExtensionPerformanceArtifact] {
        [
            try .init(
                relativePath: "artifacts/stage3-ios26.5-001.xcresult",
                kind: .testResultBundle,
                sha256: String(repeating: "b", count: 64),
                byteCount: 8_192
            ),
            try .init(
                relativePath: "artifacts/stage3-ios26.5-001.ettrace",
                kind: .performanceProfile,
                sha256: String(repeating: "c", count: 64),
                byteCount: 4_096
            ),
            try .init(
                relativePath: "artifacts/stage3-ios26.5-001-samples.json",
                kind: .measurementRecord,
                sha256: String(repeating: "d", count: 64),
                byteCount: 2_048
            )
        ]
    }

    private func makeArtifactFixture() throws -> (
        directory: URL,
        artifacts: [FloorpWebExtensionPerformanceArtifact]
    ) {
        let evidence = try makeEvidence()
        let files: [ArtifactFixtureFile] = [
            .init(
                relativePath: "artifacts/stage3-ios26.5-simulator-001.xcresult.zip",
                kind: .testResultBundle,
                data: SemanticValidator.xcresultPayload
            ),
            .init(
                relativePath: "artifacts/stage3-ios26.5-simulator-001.trace.zip",
                kind: .performanceProfile,
                data: SemanticValidator.profilePayload
            ),
            .init(
                relativePath: "artifacts/stage3-ios26.5-simulator-001-samples.json",
                kind: .measurementRecord,
                data: try FloorpWebExtensionStage3PerformanceEvidenceVerifier.measurementRecordData(for: evidence)
            )
        ]
        return try writeArtifactFixture(files: files)
    }

    private func writeArtifactFixture(
        files: [ArtifactFixtureFile]
    ) throws -> (
        directory: URL,
        artifacts: [FloorpWebExtensionPerformanceArtifact]
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpWebExtensionStage3Evidence-\(UUID().uuidString)", isDirectory: true)
        let artifactsDirectory = directory.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
        let artifacts = try files.map { file in
            try file.data.write(to: directory.appendingPathComponent(file.relativePath), options: .atomic)
            return try makeArtifact(relativePath: file.relativePath, kind: file.kind, data: file.data)
        }
        return (directory, artifacts)
    }

    private func replacingArtifact(
        _ kind: FloorpWebExtensionPerformanceArtifactKind,
        data: Data,
        in fixture: (directory: URL, artifacts: [FloorpWebExtensionPerformanceArtifact])
    ) throws -> [FloorpWebExtensionPerformanceArtifact] {
        try fixture.artifacts.map { artifact in
            guard artifact.kind == kind else { return artifact }
            try data.write(
                to: fixture.directory.appendingPathComponent(artifact.relativePath),
                options: .atomic
            )
            return try makeArtifact(relativePath: artifact.relativePath, kind: kind, data: data)
        }
    }

    private func makeArtifact(
        relativePath: String,
        kind: FloorpWebExtensionPerformanceArtifactKind,
        data: Data
    ) throws -> FloorpWebExtensionPerformanceArtifact {
        try FloorpWebExtensionPerformanceArtifact(
            relativePath: relativePath,
            kind: kind,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(data.count)
        )
    }

    private func decodeByMutating(
        _ data: Data,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> FloorpWebExtensionStage3PerformanceEvidence {
        try FloorpWebExtensionStage3PerformanceEvidenceVerifier.decode(
            decodeDataByMutating(data, mutate: mutate)
        )
    }

    private func decodeDataByMutating(
        _ data: Data,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
