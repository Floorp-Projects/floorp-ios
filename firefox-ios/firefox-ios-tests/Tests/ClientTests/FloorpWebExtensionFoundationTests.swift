// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import XCTest
@testable import Client

final class FloorpWebExtensionFoundationTests: XCTestCase, @unchecked Sendable {
    func testMatchPatternHonorsSchemeSubdomainAndPath() throws {
        let pattern = try FloorpWebExtensionMatchPattern("*://*.example.com/content/*")

        XCTAssertTrue(pattern.matches(try XCTUnwrap(URL(string: "https://example.com/content/page"))))
        XCTAssertTrue(pattern.matches(try XCTUnwrap(URL(string: "http://a.example.com/content/page"))))
        XCTAssertFalse(pattern.matches(try XCTUnwrap(URL(string: "https://example.net/content/page"))))
        XCTAssertFalse(pattern.matches(try XCTUnwrap(URL(string: "https://example.com/other/page"))))
        XCTAssertFalse(pattern.matches(try XCTUnwrap(URL(string: "file:///content/page"))))
    }

    func testPermissionBrokerScopesHostGrantToPrivateModeAndDocumentGeneration() async throws {
        let extensionID = try XCTUnwrap(FloorpWebExtensionID(rawValue: "fixture.extension"))
        let requestedHost = try FloorpWebExtensionMatchPattern("https://example.com/*")
        let broker = FloorpWebExtensionPermissionBroker()
        let normalTab = FloorpWebExtensionTabContext(
            tabID: 10,
            documentGeneration: 4,
            url: try XCTUnwrap(URL(string: "https://example.com/article"))
        )
        let privateTab = FloorpWebExtensionTabContext(
            tabID: 11,
            documentGeneration: 2,
            url: try XCTUnwrap(URL(string: "https://example.com/article")),
            isPrivate: true
        )

        await broker.grant(
            [.activeTab, .scripting],
            requestedHosts: [requestedHost],
            hostAccess: .selectedSites([requestedHost]),
            privateBrowsingEnabled: true,
            to: extensionID
        )

        let allowsScripting = await broker.allows(.scripting, extensionID: extensionID)
        let allowsNormalHost = await broker.allowsHostAccess(for: extensionID, in: normalTab)
        let allowsPrivateHost = await broker.allowsHostAccess(for: extensionID, in: privateTab)
        XCTAssertTrue(allowsScripting)
        XCTAssertTrue(allowsNormalHost)
        XCTAssertFalse(allowsPrivateHost)

        try await broker.grantActiveTab(to: extensionID, for: privateTab)
        let allowsActivePrivateHost = await broker.allowsHostAccess(for: extensionID, in: privateTab)
        XCTAssertTrue(allowsActivePrivateHost)
        await broker.invalidate(tab: privateTab)
        let allowsInvalidatedPrivateHost = await broker.allowsHostAccess(for: extensionID, in: privateTab)
        XCTAssertFalse(allowsInvalidatedPrivateHost)
    }

    func testCompatibilityEvidenceVerifiesDigestAndRoundTrips() throws {
        let package = Data("fixture-package".utf8)
        let digest = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
        let extensionID = try XCTUnwrap(FloorpWebExtensionID(rawValue: "fixture.extension"))
        let fixture = try FloorpWebExtensionFixture(
            extensionID: extensionID,
            sourceRepository: try XCTUnwrap(URL(string: "https://example.com/fixture")),
            sourceCommit: "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
            version: "1.0.0",
            packageSHA256: digest,
            license: "MPL-2.0",
            supportedOSFloor: "iOS 15"
        )
        let performance = try FloorpWebExtensionPerformanceEvidence(
            coldCompileMilliseconds: 15,
            warmCompileMilliseconds: 3,
            pageLoadOverheadMilliseconds: 1,
            memoryDeltaBytes: 2048
        )
        let evidence = try FloorpWebExtensionCompatibilityEvidence(
            fixture: fixture,
            deviceModel: "iPhone",
            operatingSystem: "iOS 15.0",
            recordedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            results: [
                FloorpWebExtensionCompatibilityResult(
                    capability: "dynamic-rules",
                    status: .passed,
                    detail: "fixture passed"
                )
            ],
            dnr: FloorpWebExtensionDNREvidence(
                accepted: 2,
                transformed: 1,
                rejected: ["modifyHeaders": 1],
                compilerLog: "fixture run"
            ),
            performance: performance
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNoThrow(try FloorpWebExtensionCompatibilityHarness.verifyPackage(package, fixture: fixture))
        let saved = try FloorpWebExtensionCompatibilityHarness.save(evidence, to: directory)
        XCTAssertEqual(try FloorpWebExtensionCompatibilityHarness.load(from: saved), evidence)
    }

    func testMV3ManifestPreflightAcceptsSupportedStaticPackage() throws {
        let manifest = try FloorpWebExtensionManifest.decode(Data("""
        {
          "manifest_version": 3,
          "name": "Fixture",
          "version": "1.2.3",
          "permissions": ["storage", "scripting", "declarativeNetRequest"],
          "host_permissions": ["https://*.example.com/*"],
          "content_scripts": [{
            "matches": ["https://*.example.com/*"],
            "js": ["content.js"],
            "run_at": "document_start",
            "world": "ISOLATED"
          }],
          "background": {
            "service_worker": "background.js",
            "type": "module"
          },
          "declarative_net_request": {
            "rule_resources": [{
              "id": "base",
              "enabled": true,
              "path": "rules/base.json"
            }]
          }
        }
        """.utf8))
        let report = FloorpWebExtensionManifest.preflight(
            manifest,
            ruleResourceData: [
                "rules/base.json": Data("""
                [
                  { "id": 1, "action": { "type": "block" } },
                  { "id": 2, "action": { "type": "upgradeScheme" } }
                ]
                """.utf8)
            ]
        )

        XCTAssertEqual(report.status, .supported)
        XCTAssertTrue(report.isActivationAllowed)
        XCTAssertEqual(manifest.contentScripts.first?.runAt, .documentStart)
        XCTAssertEqual(manifest.contentScripts.first?.world, .isolated)
        XCTAssertEqual(manifest.dnrRuleResources.first?.path.path, "rules/base.json")
    }

    func testMV3ManifestPreflightFailsClosedForUnknownPermissionAndUnsupportedDNRAction() throws {
        let report = try FloorpWebExtensionManifest.preflight(
            manifestData: Data("""
            {
              "manifest_version": 3,
              "name": "Incompatible fixture",
              "version": "1.0",
              "permissions": ["storage", "cookies", "declarativeNetRequest"],
              "declarative_net_request": {
                "rule_resources": [{
                  "id": "base",
                  "enabled": true,
                  "path": "rules.json"
                }]
              }
            }
            """.utf8),
            ruleResourceData: [
                "rules.json": Data("""
                [{ "id": 1, "action": { "type": "modifyHeaders" } }]
                """.utf8)
            ]
        )

        XCTAssertEqual(report.status, .rejected)
        XCTAssertFalse(report.isActivationAllowed)
        XCTAssertEqual(
            report.capabilities.first(where: { $0.name == "permission.cookies" })?.status,
            .rejected
        )
        XCTAssertEqual(
            report.capabilities.first(where: { $0.name == "declarative_net_request.rule_resources.base[0]" })?.status,
            .rejected
        )
    }

    func testMV3ManifestPreflightRejectsUninspectedRuleResourcesAndMalformedPaths() throws {
        let uninspected = try FloorpWebExtensionManifest.preflight(
            manifestData: Data("""
            {
              "manifest_version": 3,
              "name": "Missing rule file",
              "version": "1.0",
              "permissions": ["declarativeNetRequest"],
              "declarative_net_request": {
                "rule_resources": [{ "id": "base", "enabled": true, "path": "rules.json" }]
              }
            }
            """.utf8)
        )
        XCTAssertEqual(uninspected.status, .rejected)
        XCTAssertThrowsError(
            try FloorpWebExtensionManifest.decode(Data("""
            {
              "manifest_version": 3,
              "name": "Bad path",
              "version": "1.0",
              "content_scripts": [{
                "matches": ["https://example.com/*"],
                "js": ["../content.js"]
              }]
            }
            """.utf8))
        )
    }

    func testMV3ManifestDecodeRejectsUnknownTopLevelKeys() {
        XCTAssertThrowsError(
            try FloorpWebExtensionManifest.decode(Data("""
            {
              "manifest_version": 3,
              "name": "Unexpected key",
              "version": "1.0",
              "externally_connectable": { "matches": ["https://example.com/*"] }
            }
            """.utf8))
        )
    }

    func testMV3ManifestPreflightValidatesEveryDeclaredPackageResource() throws {
        let ruleData = Data("""
        [{
          "id": 1,
          "action": { "type": "block" },
          "condition": { "resourceTypes": ["script"] }
        }]
        """.utf8)
        let inventory = FloorpWebExtensionManifestPackageInventory(resources: [
            .init(path: "content.js", isRegularFile: true, byteSize: 12),
            .init(path: "content.css", isRegularFile: true, byteSize: 8),
            .init(path: "background.js", isRegularFile: true, byteSize: 16),
            .init(path: "rules/base.json", isRegularFile: true, byteSize: ruleData.count)
        ])

        let report = try FloorpWebExtensionManifest.preflight(
            manifestData: Data("""
            {
              "manifest_version": 3,
              "name": "Complete package",
              "version": "1.0",
              "permissions": ["declarativeNetRequest"],
              "content_scripts": [{
                "matches": ["https://example.com/*"],
                "js": ["content.js"],
                "css": ["content.css"]
              }],
              "background": { "service_worker": "background.js", "type": "module" },
              "declarative_net_request": {
                "rule_resources": [{ "id": "base", "enabled": true, "path": "rules/base.json" }]
              }
            }
            """.utf8),
            packageInventory: inventory,
            ruleResourceData: ["rules/base.json": ruleData]
        )

        XCTAssertEqual(report.status, .supported)
        XCTAssertEqual(
            report.capabilities.first(where: { $0.name == "package_resource.background.service_worker" })?.status,
            .supported
        )
        XCTAssertEqual(
            report.capabilities.first(where: {
                $0.name == "package_resource.declarative_net_request.rule_resources.base"
            })?.status,
            .supported
        )
    }

    func testMV3ManifestPreflightRejectsMissingInvalidAndMismatchedPackageResources() throws {
        let ruleData = Data("[{ \"id\": 1, \"action\": { \"type\": \"block\" } }]".utf8)
        let inventory = FloorpWebExtensionManifestPackageInventory(resources: [
            .init(path: "content.js", isRegularFile: false, byteSize: 10),
            .init(path: "background.js", isRegularFile: true, byteSize: 10),
            .init(path: "rules.json", isRegularFile: true, byteSize: ruleData.count + 1)
        ])

        let report = try FloorpWebExtensionManifest.preflight(
            manifestData: Data("""
            {
              "manifest_version": 3,
              "name": "Invalid inventory",
              "version": "1.0",
              "permissions": ["declarativeNetRequest"],
              "content_scripts": [{
                "matches": ["https://example.com/*"],
                "js": ["content.js"],
                "css": ["missing.css"]
              }],
              "background": { "service_worker": "background.js", "type": "module" },
              "declarative_net_request": {
                "rule_resources": [{ "id": "base", "enabled": true, "path": "rules.json" }]
              }
            }
            """.utf8),
            packageInventory: inventory,
            ruleResourceData: ["rules.json": ruleData]
        )

        XCTAssertEqual(report.status, .rejected)
        XCTAssertEqual(
            report.capabilities.first(where: { $0.name == "package_resource.content_scripts[0].js[0]" })?.status,
            .rejected
        )
        XCTAssertEqual(
            report.capabilities.first(where: { $0.name == "package_resource.content_scripts[0].css[0]" })?.status,
            .rejected
        )
        XCTAssertEqual(
            report.capabilities.first(where: { $0.name == "declarative_net_request.rule_resources.base" })?.status,
            .rejected
        )
    }

    func testMV3ManifestPreflightRejectsUnrepresentableDNRConditions() throws {
        let ruleData = Data("""
        [{
          "id": 1,
          "action": { "type": "block" },
          "condition": { "tabIds": [7] }
        }]
        """.utf8)
        let inventory = FloorpWebExtensionManifestPackageInventory(resources: [
            .init(path: "rules.json", isRegularFile: true, byteSize: ruleData.count)
        ])
        let report = try FloorpWebExtensionManifest.preflight(
            manifestData: Data("""
            {
              "manifest_version": 3,
              "name": "Unsupported DNR condition",
              "version": "1.0",
              "permissions": ["declarativeNetRequest"],
              "declarative_net_request": {
                "rule_resources": [{ "id": "base", "enabled": true, "path": "rules.json" }]
              }
            }
            """.utf8),
            packageInventory: inventory,
            ruleResourceData: ["rules.json": ruleData]
        )

        XCTAssertEqual(report.status, .rejected)
        XCTAssertEqual(
            report.capabilities.first(where: {
                $0.name == "declarative_net_request.rule_resources.base[0]"
            })?.status,
            .rejected
        )
    }

    func testMV3ManifestPreflightSupportsOnlyNonPersistentBackgroundScriptArrays() throws {
        let inventory = FloorpWebExtensionManifestPackageInventory(resources: [
            .init(path: "background/first.js", isRegularFile: true, byteSize: 12),
            .init(path: "background/second.js", isRegularFile: true, byteSize: 12)
        ])
        let supported = try FloorpWebExtensionManifest.preflight(
            manifestData: Data("""
            {
              "manifest_version": 3,
              "name": "Nonpersistent background scripts",
              "version": "1.0",
              "background": {
                "scripts": ["background/first.js", "background/second.js"],
                "persistent": false
              }
            }
            """.utf8),
            packageInventory: inventory
        )
        XCTAssertEqual(supported.status, .supported)
        XCTAssertEqual(
            supported.capabilities.first(where: { $0.name == "background.scripts" })?.status,
            .supported
        )

        for backgroundJSON in [
            #"{"scripts":["background/first.js"]}"#,
            #"{"scripts":["background/first.js"],"persistent":true}"#,
            #"{"service_worker":"background/first.js","scripts":["background/second.js"]}"#
        ] {
            let rejected = try FloorpWebExtensionManifest.preflight(
                manifestData: Data("""
                {
                  "manifest_version": 3,
                  "name": "Rejected background",
                  "version": "1.0",
                  "background": \(backgroundJSON)
                }
                """.utf8),
                packageInventory: inventory
            )
            XCTAssertEqual(rejected.status, .rejected, backgroundJSON)
        }
    }
}
