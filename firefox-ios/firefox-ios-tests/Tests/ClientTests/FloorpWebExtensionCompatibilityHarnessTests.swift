// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation
import XCTest
@testable import Client

final class FloorpWebExtensionCompatibilityHarnessTests: XCTestCase, @unchecked Sendable {
    func testPersistsDNRDiagnosticsPerformanceAndRequiredOSMatrix() throws {
        let fixture = try makeFixture()
        let dnr = FloorpWebExtensionDNREvidence(
            accepted: 2_000,
            transformed: 125,
            rejected: [
                "unsupported-redirect-transform": 12,
                "unsupported-regex": 4
            ],
            compilerLog: "compiled static=2000 dynamic=125 rejected=16"
        )
        let performance = try FloorpWebExtensionPerformanceEvidence(
            coldCompileMilliseconds: 42.5,
            warmCompileMilliseconds: 3.2,
            pageLoadOverheadMilliseconds: 1.6,
            memoryDeltaBytes: -4_096
        )
        let currentTargetEvidence = try makeEvidence(
            fixture: fixture,
            operatingSystem: "iOS 15.0",
            dnr: dnr,
            performance: performance
        )
        let latestOSEvidence = try makeEvidence(
            fixture: fixture,
            operatingSystem: "iOS 18.0",
            dnr: dnr,
            performance: performance
        )
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let saved = try FloorpWebExtensionCompatibilityHarness.save(currentTargetEvidence, to: directory)

        XCTAssertEqual(try FloorpWebExtensionCompatibilityHarness.load(from: saved), currentTargetEvidence)
        XCTAssertNoThrow(
            try FloorpWebExtensionCompatibilityHarness.verifyOSMatrix(
                [currentTargetEvidence, latestOSEvidence],
                requiredOperatingSystems: ["iOS 15", "iOS 18"]
            )
        )
    }

    func testRejectsIncompleteOrBelowFloorOSMatrix() throws {
        let fixture = try makeFixture(supportedOSFloor: "iOS 16")
        let evidence = try makeEvidence(fixture: fixture, operatingSystem: "iOS 16.0")

        XCTAssertThrowsError(
            try FloorpWebExtensionCompatibilityHarness.verifyOSMatrix(
                [evidence],
                requiredOperatingSystems: ["iOS 16", "iOS 18"]
            )
        )
        XCTAssertThrowsError(
            try FloorpWebExtensionCompatibilityHarness.verifyOSMatrix(
                [evidence],
                requiredOperatingSystems: ["iOS 15"]
            )
        )
    }

    func testRejectsCorruptedOrSemanticallyInvalidPersistedEvidence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = try makeEvidence(fixture: makeFixture())
        let saved = try FloorpWebExtensionCompatibilityHarness.save(evidence, to: directory)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any]
        )
        var dnr = try XCTUnwrap(object["dnr"] as? [String: Any])
        dnr["transformed"] = 2_001
        object["dnr"] = dnr
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        try tamperedData.write(to: saved, options: .atomic)

        XCTAssertThrowsError(try FloorpWebExtensionCompatibilityHarness.load(from: saved))

        dnr["transformed"] = 2
        object["dnr"] = dnr
        object["unexpected"] = "not accepted"
        let unknownFieldData = try JSONSerialization.data(withJSONObject: object)
        try unknownFieldData.write(to: saved, options: .atomic)

        XCTAssertThrowsError(try FloorpWebExtensionCompatibilityHarness.load(from: saved))
    }

    func testRejectsUnpinnedFixtureMetadataAndMismatchedPackageDigest() throws {
        let extensionID = try XCTUnwrap(FloorpWebExtensionID(rawValue: "fixture.extension"))

        XCTAssertThrowsError(
            try FloorpWebExtensionFixture(
                extensionID: extensionID,
                sourceRepository: try XCTUnwrap(URL(string: "https://example.com/fixture")),
                sourceCommit: "4b825dc",
                version: "1.0.0",
                packageSHA256: String(repeating: "a", count: 64),
                license: "MPL-2.0",
                supportedOSFloor: "iOS 15"
            )
        )

        let fixture = try makeFixture()
        XCTAssertThrowsError(try FloorpWebExtensionCompatibilityHarness.verifyPackage(Data(), fixture: fixture))
        XCTAssertThrowsError(
            try FloorpWebExtensionCompatibilityHarness.verifyPackage(Data("different".utf8), fixture: fixture)
        )
    }

    func testVerifiesLocalFixturePackageDigestManifestAndBuildFlavor() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let resources: [String: Data] = [
            "LICENSE": Data("MPL-2.0".utf8),
            "manifest.json": Data("""
            {
              "manifest_version": 3,
              "name": "Local fixture",
              "version": "1.0.0",
              "permissions": ["declarativeNetRequest"],
              "declarative_net_request": {
                "rule_resources": [{
                  "id": "base",
                  "enabled": true,
                  "path": "rules/base.json"
                }]
              }
            }
            """.utf8),
            "rules/base.json": Data("""
            [{ "id": 1, "action": { "type": "block" }, "condition": { "urlFilter": "ads.fixture.test" } }]
            """.utf8)
        ]
        for (path, data) in resources {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }

        let fixture = try FloorpWebExtensionFixture(
            extensionID: try XCTUnwrap(FloorpWebExtensionID(rawValue: "fixture.local")),
            sourceRepository: try XCTUnwrap(URL(string: "https://example.com/floorp-fixture")),
            sourceCommit: "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
            version: "1.0.0",
            buildFlavor: "local-stage3-fixture",
            packageSHA256: fixtureDigest(resources),
            license: "MPL-2.0",
            supportedOSFloor: "iOS 15"
        )
        let metadata = try FloorpWebExtensionFixturePackageMetadata(
            fixture: fixture,
            requiredOperatingSystems: ["iOS 15", "iOS 18"],
            generatedRulesetLog: "static=1; dynamic=runtime-managed; session=runtime-managed"
        )
        try JSONEncoder().encode(metadata).write(
            to: directory.appendingPathComponent("fixture-metadata.json"),
            options: .atomic
        )

        XCTAssertEqual(
            try FloorpWebExtensionCompatibilityHarness.verifyFixturePackage(at: directory),
            metadata
        )
    }

    func testVerifiesCheckedInDemandingMV3FixturePackage() throws {
        let metadata = try FloorpWebExtensionCompatibilityHarness.verifyFixturePackage(
            at: try checkedInFixtureDirectory(named: "demanding-mv3")
        )

        XCTAssertEqual(metadata.fixture.extensionID.rawValue, "floorp.fixture.demanding-mv3")
        XCTAssertEqual(metadata.fixture.sourceCommit, "6f58b2578825f74394fe16bb1c15aa17a17ad91d")
        XCTAssertEqual(metadata.fixture.buildFlavor, "local-stage3-fixture")
        XCTAssertEqual(
            metadata.fixture.packageSHA256,
            "3fcd3274c3f0502a23f029b6e827351a854c2cb1f1aadc668877d7ace5206c24"
        )
        XCTAssertEqual(metadata.requiredOperatingSystems, ["iOS 15", "iOS 18"])

        let contentMessaging = try FloorpWebExtensionCompatibilityHarness.verifyFixturePackage(
            at: try checkedInFixtureDirectory(named: "content-messaging-mv3")
        )
        XCTAssertEqual(
            contentMessaging.fixture.extensionID.rawValue,
            "floorp.fixture.content-messaging-mv3"
        )
        XCTAssertEqual(
            contentMessaging.fixture.packageSHA256,
            "7261daacea04355044a1b8aba264e181baf8dcf3ff38457a220b8d35a24b51f5"
        )
        XCTAssertEqual(
            contentMessaging.fixture.buildFlavor,
            "local-stage2-content-messaging-fixture"
        )

        let eventRuntimeDirectory = try checkedInFixtureDirectory(named: "event-runtime-mv3")
        let eventRuntime = try FloorpWebExtensionCompatibilityHarness.verifyFixturePackage(
            at: eventRuntimeDirectory
        )
        XCTAssertEqual(eventRuntime.fixture.extensionID.rawValue, "floorp.fixture.event-runtime-mv3")
        XCTAssertEqual(
            eventRuntime.fixture.packageSHA256,
            "25476f29098792b9a6aec64687d911651045768a433588d63a83e5eeaddebc32"
        )
        XCTAssertEqual(eventRuntime.fixture.buildFlavor, "local-stage2-event-runtime-fixture")
        XCTAssertEqual(eventRuntime.requiredOperatingSystems, ["iOS 15", "iOS 18"])

        let eventRuntimeManifest = try FloorpWebExtensionManifest.decode(
            Data(contentsOf: eventRuntimeDirectory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(eventRuntimeManifest.background?.serviceWorker?.path, "background/service-worker.js")
        XCTAssertEqual(eventRuntimeManifest.action?.defaultPopup?.path, "popup/index.html")
        XCTAssertEqual(eventRuntimeManifest.optionsUI?.page.path, "options/index.html")
        XCTAssertEqual(eventRuntimeManifest.apiPermissions, [.alarms, .storage])
    }

    @MainActor
    func testProfileLocalEvidenceRegistrySeparatesPrivateModeAndRetainsOSMatrix() throws {
        let normalDirectory = temporaryDirectory()
        let privateDirectory = temporaryDirectory()
        defer {
            FloorpWebExtensionCompatibilityEvidenceRegistry.removeStore(
                for: "test-profile",
                isPrivateBrowsing: false
            )
            FloorpWebExtensionCompatibilityEvidenceRegistry.removeStore(
                for: "test-profile",
                isPrivateBrowsing: true
            )
            try? FileManager.default.removeItem(at: normalDirectory)
            try? FileManager.default.removeItem(at: privateDirectory)
        }

        FloorpWebExtensionCompatibilityEvidenceRegistry.install(
            try .init(directory: normalDirectory),
            for: "test-profile",
            isPrivateBrowsing: false
        )
        FloorpWebExtensionCompatibilityEvidenceRegistry.install(
            try .init(directory: privateDirectory),
            for: "test-profile",
            isPrivateBrowsing: true
        )

        let fixture = try makeFixture()
        let ios15 = try makeEvidence(fixture: fixture, operatingSystem: "iOS 15.0")
        let ios18 = try makeEvidence(fixture: fixture, operatingSystem: "iOS 18.0")
        _ = try FloorpWebExtensionCompatibilityEvidenceRegistry.record(
            ios15,
            for: "test-profile",
            isPrivateBrowsing: false
        )
        _ = try FloorpWebExtensionCompatibilityEvidenceRegistry.record(
            ios18,
            for: "test-profile",
            isPrivateBrowsing: false
        )
        _ = try FloorpWebExtensionCompatibilityEvidenceRegistry.record(
            ios15,
            for: "test-profile",
            isPrivateBrowsing: true
        )

        let normalEvidence = try FloorpWebExtensionCompatibilityEvidenceRegistry.evidence(
            for: "test-profile",
            isPrivateBrowsing: false
        )
        let privateEvidence = try FloorpWebExtensionCompatibilityEvidenceRegistry.evidence(
            for: "test-profile",
            isPrivateBrowsing: true
        )
        XCTAssertEqual(normalEvidence.count, 2)
        XCTAssertEqual(privateEvidence, [ios15])
        XCTAssertNoThrow(
            try FloorpWebExtensionCompatibilityHarness.verifyOSMatrix(
                normalEvidence,
                requiredOperatingSystems: ["iOS 15", "iOS 18"]
            )
        )
    }

    private func makeFixture(supportedOSFloor: String = "iOS 15") throws -> FloorpWebExtensionFixture {
        let package = Data("pinned demanding fixture package".utf8)
        let digest = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
        return try FloorpWebExtensionFixture(
            extensionID: try XCTUnwrap(FloorpWebExtensionID(rawValue: "fixture.extension")),
            sourceRepository: try XCTUnwrap(URL(string: "https://example.com/floorp-fixture")),
            sourceCommit: "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
            version: "1.0.0",
            packageSHA256: digest,
            license: "MPL-2.0",
            supportedOSFloor: supportedOSFloor
        )
    }

    private func makeEvidence(
        fixture: FloorpWebExtensionFixture,
        operatingSystem: String = "iOS 15.0",
        dnr: FloorpWebExtensionDNREvidence = FloorpWebExtensionDNREvidence(
            accepted: 10,
            transformed: 2,
            rejected: ["unsupported-regex": 1],
            compilerLog: "compiled fixture"
        ),
        performance: FloorpWebExtensionPerformanceEvidence? = nil
    ) throws -> FloorpWebExtensionCompatibilityEvidence {
        let performance = try performance ?? FloorpWebExtensionPerformanceEvidence(
            coldCompileMilliseconds: 10,
            warmCompileMilliseconds: 2,
            pageLoadOverheadMilliseconds: 1,
            memoryDeltaBytes: 1_024
        )
        return try FloorpWebExtensionCompatibilityEvidence(
            fixture: fixture,
            deviceModel: "iPhone15,2",
            operatingSystem: operatingSystem,
            recordedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            results: [
                FloorpWebExtensionCompatibilityResult(
                    capability: "declarativeNetRequest.updateDynamicRules",
                    status: .partial,
                    detail: "Redirect transforms are rejected with a diagnostic."
                )
            ],
            dnr: dnr,
            performance: performance,
            visualEvidencePaths: ["screenshots/options-page.png"]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func checkedInFixtureDirectory(named fixtureName: String) throws -> URL {
        let fileManager = FileManager.default
        let sourceDirectory = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
        let workingDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
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

        throw NSError(
            domain: "FloorpWebExtensionCompatibilityHarnessTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The checked-in \(fixtureName) fixture was not found."]
        )
    }

    private func fixtureDigest(_ resources: [String: Data]) -> String {
        let package = resources.keys.sorted().reduce(into: Data()) { package, path in
            package.append(path.data(using: .utf8)!)
            package.append(0)
            package.append(resources[path]!)
        }
        return SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
    }
}
