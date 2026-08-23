// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebExtensionPackageStoreTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "floorp.fixture.demanding-mv3")!

    func testBundledCatalogResolvesFolderResourceAtApplicationBundleRoot() throws {
        let bundleDirectory = temporaryDirectory().appendingPathExtension("bundle")
        defer { try? FileManager.default.removeItem(at: bundleDirectory) }

        let item = FloorpWebExtensionBundledCatalog.demandingMV3Fixture
        let packageDirectory = bundleDirectory.appendingPathComponent(
            item.packageDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: packageDirectory.appendingPathComponent("manifest.json"))
        let infoPlist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "org.floorp.tests.webextensions",
                "CFBundleName": "FloorpWebExtensionsCatalogTest"
            ],
            format: .xml,
            options: 0
        )
        try infoPlist.write(to: bundleDirectory.appendingPathComponent("Info.plist"))

        let bundle = try XCTUnwrap(Bundle(path: bundleDirectory.path))
        let resolved = try XCTUnwrap(item.packageURL(in: bundle))

        XCTAssertEqual(resolved.standardizedFileURL, packageDirectory.standardizedFileURL)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: resolved.appendingPathComponent("manifest.json").path
            )
        )
    }

    func testBundledCatalogResolvesNestedFixtureFolderResourceWithoutSourceCheckoutFallback() throws {
        let bundleDirectory = temporaryDirectory().appendingPathExtension("bundle")
        defer { try? FileManager.default.removeItem(at: bundleDirectory) }

        let item = FloorpWebExtensionBundledCatalog.demandingMV3Fixture
        let fixtureRoot = bundleDirectory.appendingPathComponent("WebExtensions/Fixtures", isDirectory: true)
        let packageDirectory = fixtureRoot.appendingPathComponent(
            item.packageDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: packageDirectory.appendingPathComponent("manifest.json"))
        let infoPlist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "org.floorp.tests.webextensions",
                "CFBundleName": "FloorpWebExtensionsCatalogTest"
            ],
            format: .xml,
            options: 0
        )
        try infoPlist.write(to: bundleDirectory.appendingPathComponent("Info.plist"))

        let bundle = try XCTUnwrap(Bundle(path: bundleDirectory.path))
        let resolved = try XCTUnwrap(item.packageURL(in: bundle))

        XCTAssertEqual(resolved.standardizedFileURL, packageDirectory.standardizedFileURL)
        XCTAssertFalse(resolved.path.contains("firefox-ios/Floorp/WebExtensions/Fixtures"))
    }

    func testInstallsDemandingFixtureIntoProfileGenerationAndRestoresAfterRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestedHosts: Set<FloorpWebExtensionMatchPattern> = [
            try .init("http://*.fixture.test/*"),
            try .init("https://*.fixture.test/*")
        ]
        let grants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.declarativeNetRequest, .scripting, .storage],
            requestedHosts: requestedHosts,
            normalHostAccess: .selectedSites([try .init("https://*.fixture.test/*")])
        )
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-test",
            isPrivateBrowsing: false,
            directory: directory
        )

        let installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID,
            initialGrants: grants
        )
        let loader = store.makeResourceLoader()
        let source = try FloorpWebExtensionScriptSource("content/document-start.js")

        XCTAssertEqual(installed.extensionID, extensionID)
        XCTAssertEqual(installed.version, "1.0.0")
        XCTAssertTrue(installed.preflight.isActivationAllowed)
        XCTAssertEqual(installed.grants, grants)
        XCTAssertTrue(try loader(extensionID, source).contains("floorp-fixture-ping"))

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-test",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restoredPackage = await restartedStore.installedPackage(for: extensionID)
        let restored = try XCTUnwrap(restoredPackage)
        XCTAssertEqual(restored.generation, installed.generation)
        XCTAssertEqual(restored.packageSHA256, installed.packageSHA256)
        XCTAssertEqual(restored.grants, grants)
        XCTAssertTrue(try restartedStore.makeResourceLoader()(extensionID, source).contains("floorp-fixture-ping"))
    }

    func testDisableGrantUpdateAndUninstallAreDurableAndRevokeExistingLoader() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-mutations",
            isPrivateBrowsing: false,
            directory: directory
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        let loader = store.makeResourceLoader()
        let source = try FloorpWebExtensionScriptSource("content/document-start.js")

        XCTAssertNoThrow(try loader(extensionID, source))
        try await store.setEnabled(false, for: extensionID)
        XCTAssertThrowsError(try loader(extensionID, source))

        let hosts = Set([
            try FloorpWebExtensionMatchPattern("http://*.fixture.test/*"),
            try FloorpWebExtensionMatchPattern("https://*.fixture.test/*")
        ])
        let updatedGrants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.scripting],
            requestedHosts: hosts,
            normalHostAccess: .allRequestedSites
        )
        try await store.updateGrants(updatedGrants, for: extensionID)
        try await store.setEnabled(true, for: extensionID)
        XCTAssertNoThrow(try loader(extensionID, source))

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-mutations",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restoredPackage = await restartedStore.installedPackage(for: extensionID)
        let restored = try XCTUnwrap(restoredPackage)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(restored.grants, updatedGrants)

        try await store.uninstall(extensionID)
        XCTAssertThrowsError(try loader(extensionID, source))
        let remainingPackages = await store.installedPackages()
        XCTAssertTrue(remainingPackages.isEmpty)
    }

    func testRejectsSymlinkAndFailedReplacementPreservesActiveGeneration() async throws {
        let directory = temporaryDirectory()
        let unsafeFixture = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: unsafeFixture)
        }
        let fixture = try checkedInDemandingMV3FixtureDirectory()
        try FileManager.default.copyItem(at: fixture, to: unsafeFixture)
        let script = unsafeFixture.appendingPathComponent("content/document-start.js")
        let external = directory.appendingPathComponent("outside.js")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("window.outside = true;".utf8).write(to: external)
        try FileManager.default.removeItem(at: script)
        try FileManager.default.createSymbolicLink(at: script, withDestinationURL: external)

        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-rollback",
            isPrivateBrowsing: false,
            directory: directory.appendingPathComponent("store", isDirectory: true)
        )
        await assertAsyncThrows {
            _ = try await store.installBundledPackage(
                at: unsafeFixture,
                expectedExtensionID: self.extensionID
            )
        }
        let packagesAfterRejection = await store.installedPackages()
        XCTAssertTrue(packagesAfterRejection.isEmpty)

        let installed = try await store.installBundledPackage(
            at: fixture,
            expectedExtensionID: extensionID
        )
        await assertAsyncThrows {
            _ = try await store.installBundledPackage(
                at: fixture,
                expectedExtensionID: FloorpWebExtensionID(rawValue: "different.fixture")!
            )
        }
        let activeAfterFailure = await store.installedPackage(for: extensionID)
        let afterFailure = try XCTUnwrap(activeAfterFailure)
        XCTAssertEqual(afterFailure.generation, installed.generation)
        XCTAssertNoThrow(
            try store.makeResourceLoader()(
                extensionID,
                FloorpWebExtensionScriptSource("content/document-start.js")
            )
        )
    }

    func testRestartFailsClosedWhenCommittedGenerationIsTampered() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-tamper",
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        let manifestURL = committedGenerationDirectory(
            root: directory,
            installed: installed
        ).appendingPathComponent("manifest.json")

        try Data(#"{"manifest_version":3,"name":"tampered","version":"1.0.0"}"#.utf8)
            .write(to: manifestURL, options: [.atomic])

        XCTAssertThrowsError(
            try FloorpWebExtensionPackageStore(
                profileIdentifier: "package-store-tamper",
                isPrivateBrowsing: false,
                directory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPackageStoreError, .corruptedRegistry)
        }
    }

    func testRestartFailsClosedWhenGenerationPathEscapesPackageRoot() async throws {
        let directory = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-path-escape",
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        let generationDirectory = committedGenerationDirectory(root: directory, installed: installed)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: generationDirectory)
        try FileManager.default.createSymbolicLink(at: generationDirectory, withDestinationURL: outside)

        XCTAssertThrowsError(
            try FloorpWebExtensionPackageStore(
                profileIdentifier: "package-store-path-escape",
                isPrivateBrowsing: false,
                directory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPackageStoreError, .corruptedRegistry)
        }
    }

    func testRestartFailsClosedWhenRegistryGrantsExceedManifest() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-grant-tamper",
            isPrivateBrowsing: false,
            directory: directory
        )
        var installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        installed.grants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.declarativeNetRequest, .scripting, .storage],
            requestedHosts: Set(installed.preflight.manifest.hostPermissions),
            normalHostAccess: .selectedSites([try FloorpWebExtensionMatchPattern("https://not-requested.example/*")])
        )
        try writeRegistry(root: directory, packages: [installed])

        XCTAssertThrowsError(
            try FloorpWebExtensionPackageStore(
                profileIdentifier: "package-store-grant-tamper",
                isPrivateBrowsing: false,
                directory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPackageStoreError, .corruptedRegistry)
        }
    }

    func testLiveManagerRevokesBeforeDisableAndUninstallAndRestoresOnEnable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager",
            isPrivateBrowsing: false,
            directory: directory
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        var reconciledStates = [Bool]()
        let manager = FloorpWebExtensionLivePackageManager(store: store) { id, package in
            XCTAssertEqual(id, self.extensionID)
            reconciledStates.append(package != nil)
        }

        try await manager.setEnabled(false, for: extensionID)
        XCTAssertEqual(reconciledStates, [false])
        let disabled = await store.installedPackage(for: extensionID)
        XCTAssertEqual(disabled?.isEnabled, false)

        try await manager.setEnabled(true, for: extensionID)
        XCTAssertEqual(reconciledStates, [false, true])
        let enabled = await store.installedPackage(for: extensionID)
        XCTAssertEqual(enabled?.isEnabled, true)

        try await manager.uninstall(extensionID)
        XCTAssertEqual(reconciledStates, [false, true, false])
        let uninstalled = await store.installedPackage(for: extensionID)
        XCTAssertNil(uninstalled)
    }

    func testBootstrapRestoreMaterializesManifestScriptsGrantsAndStaticDNR() async throws {
        let directory = temporaryDirectory()
        let ruleStoreDirectory = temporaryDirectory()
        let apiHostDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: ruleStoreDirectory)
            try? FileManager.default.removeItem(at: apiHostDirectory)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-bootstrap-restore",
            isPrivateBrowsing: false,
            directory: directory
        )
        let hosts: Set<FloorpWebExtensionMatchPattern> = [
            try .init("http://*.fixture.test/*"),
            try .init("https://*.fixture.test/*")
        ]
        let grants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.declarativeNetRequest, .scripting],
            requestedHosts: hosts,
            normalHostAccess: .allRequestedSites
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID,
            initialGrants: grants
        )
        try FileManager.default.createDirectory(at: ruleStoreDirectory, withIntermediateDirectories: true)
        let webKitStore = try XCTUnwrap(WKContentRuleListStore(url: ruleStoreDirectory))
        let runtime = FloorpWebExtensionRuntime(
            contentRuleListCompiler: FloorpWKContentRuleListStoreCompiler(store: webKitStore)
        )
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "package-bootstrap-restore",
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: store.makeResourceLoader()
        )
        let apiHost = try FloorpWebExtensionAPIHost(
            profileIdentifier: "package-bootstrap-restore",
            isPrivateBrowsing: false,
            directory: apiHostDirectory,
            preferredLocales: ["en"],
            packageResourceLoader: store.makeI18nResourceLoader()
        )

        await FloorpBootstrapper.restoreInstalledPackages(
            from: store,
            into: coordinator,
            apiHost: apiHost
        )

        let tab = FloorpWebExtensionTabContext(
            tabID: 91,
            documentGeneration: 1,
            url: URL(string: "https://www.fixture.test/page")!,
            isPrivate: false
        )
        let policies = try XCTUnwrap(coordinator.preNavigationPolicies(for: tab).first)
        XCTAssertEqual(policies.extensionID, extensionID)
        XCTAssertEqual(policies.scriptPolicies.count, 3)
        let dnrSnapshot = await coordinator.dnrSnapshot(for: extensionID)
        let dnr = try XCTUnwrap(dnrSnapshot)
        XCTAssertEqual(dnr.staticRuleSets.first?.rules.count, 40)
        XCTAssertEqual(dnr.enabledStaticRuleSetIDs, ["large-static"])

        let apiResponse = try await apiHost.dispatch(
            operation: "i18n.getUILanguage",
            payload: try .init(jsonData: Data("{}".utf8)),
            sender: FloorpWebExtensionRuntimeMessageSender(
                extensionID: extensionID,
                tabID: tab.tabID,
                documentGeneration: tab.documentGeneration,
                url: tab.url,
                isMainFrame: true,
                isPrivate: false
            )
        )
        XCTAssertNotNil(apiResponse, "restored packages must be activated in the native API host")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-webextension-package-store-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func checkedInDemandingMV3FixtureDirectory() throws -> URL {
        let fileManager = FileManager.default
        let sourceDirectory = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
        let workingDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        let fixturePath = "firefox-ios/Floorp/WebExtensions/Fixtures/demanding-mv3"

        for startingDirectory in [workingDirectory, sourceDirectory] {
            var searchDirectory = startingDirectory.standardizedFileURL
            while true {
                let candidate = searchDirectory.appendingPathComponent(fixturePath, isDirectory: true)
                if fileManager.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                    return candidate
                }
                let parent = searchDirectory.deletingLastPathComponent()
                guard parent.path != searchDirectory.path else { break }
                searchDirectory = parent
            }
        }
        throw NSError(
            domain: "FloorpWebExtensionPackageStoreTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The demanding MV3 fixture was not found."]
        )
    }

    private func committedGenerationDirectory(
        root: URL,
        installed: FloorpWebExtensionInstalledPackage
    ) -> URL {
        root.appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(installed.extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(installed.generation, isDirectory: true)
    }

    private func writeRegistry(
        root: URL,
        packages: [FloorpWebExtensionInstalledPackage]
    ) throws {
        struct TestRegistry: Encodable {
            let schemaVersion = 1
            let packages: [FloorpWebExtensionInstalledPackage]
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(TestRegistry(packages: packages))
        try data.write(
            to: root.appendingPathComponent("installed-packages.json"),
            options: [.atomic]
        )
    }

    private func assertAsyncThrows(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            // Callers assert the transaction state after the expected failure.
        }
    }
}
