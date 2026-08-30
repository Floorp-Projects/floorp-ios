// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Dispatch
import Foundation
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

    func testPersistentRegisteredScriptsRestoreWhileMemoryOnlyScriptsAreDiscarded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hosts: Set<FloorpWebExtensionMatchPattern> = [
            try .init("http://*.fixture.test/*"),
            try .init("https://*.fixture.test/*")
        ]
        let grants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.scripting, .declarativeNetRequest],
            requestedHosts: hosts,
            normalHostAccess: .allRequestedSites
        )
        let profileIdentifier = "package-persistent-scripts-\(UUID().uuidString)"
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID,
            initialGrants: grants
        )
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        await FloorpBootstrapper.restoreInstalledPackages(from: store, into: coordinator)

        let source = try FloorpWebExtensionScriptSource("content/document-start.js")
        let durable = FloorpWebExtensionRegisteredScript(
            id: "survives-restart",
            matches: [try .init("https://*.fixture.test/*")],
            javaScript: [source],
            runAt: .documentStart,
            persistAcrossSessions: true
        )
        let memoryOnly = FloorpWebExtensionRegisteredScript(
            id: "memory-only",
            matches: [try .init("https://*.fixture.test/*")],
            javaScript: [source],
            persistAcrossSessions: false
        )
        try await coordinator.registerScripts([durable, memoryOnly], for: extensionID)

        let storedPackageRecord = await store.installedPackage(for: extensionID)
        let storedPackage = try XCTUnwrap(storedPackageRecord)
        XCTAssertEqual(storedPackage.generation, installed.generation)
        XCTAssertEqual(storedPackage.registeredPersistentScripts, [durable])

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedCoordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: restartedStore.makeResourceLoader(),
            packageStore: restartedStore
        )
        await FloorpBootstrapper.restoreInstalledPackages(
            from: restartedStore,
            into: restartedCoordinator
        )

        let restored = await restartedCoordinator.registeredScripts(for: extensionID)
        XCTAssertEqual(restored.map(\.id), ["survives-restart"])
        XCTAssertEqual(restored.first, durable)
        XCTAssertFalse(restored.contains(where: { $0.id == memoryOnly.id }))

        try await restartedCoordinator.updateScripts(
            [.init(id: durable.id, allFrames: true)],
            for: extensionID
        )
        let updatedPackageRecord = await restartedStore.installedPackage(for: extensionID)
        let updatedPackage = try XCTUnwrap(updatedPackageRecord)
        XCTAssertEqual(updatedPackage.registeredPersistentScripts.count, 1)
        XCTAssertTrue(updatedPackage.registeredPersistentScripts[0].allFrames)

        try await restartedCoordinator.unregisterScripts([durable.id], for: extensionID)
        let afterUnregisterRecord = await restartedStore.installedPackage(for: extensionID)
        let afterUnregister = try XCTUnwrap(afterUnregisterRecord)
        XCTAssertTrue(afterUnregister.registeredPersistentScripts.isEmpty)
    }

    func testScriptingAPIDefaultsRegisteredScriptsToPersistentAndRestoresThem() async throws {
        let directory = temporaryDirectory()
        let apiDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: apiDirectory)
        }
        let profileIdentifier = "package-persistent-scripts-api-\(UUID().uuidString)"
        let hosts: Set<FloorpWebExtensionMatchPattern> = [
            try .init("http://*.fixture.test/*"),
            try .init("https://*.fixture.test/*")
        ]
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID,
            initialGrants: .init(
                apiPermissions: [.scripting, .declarativeNetRequest],
                requestedHosts: hosts,
                normalHostAccess: .allRequestedSites
            )
        )
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        FloorpWebExtensionCoordinator.install(coordinator)
        defer {
            FloorpWebExtensionCoordinator.removeCoordinator(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
        }
        let host = try FloorpWebExtensionAPIHost(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: apiDirectory,
            preferredLocales: ["en"],
            packageResourceLoader: store.makeI18nResourceLoader()
        )
        await host.activate(installed)
        let sender = FloorpWebExtensionRuntimeMessageSender(
            extensionID: extensionID,
            tabID: 1,
            documentGeneration: 1,
            url: try XCTUnwrap(URL(string: "https://www.fixture.test/page")),
            isMainFrame: true,
            isPrivate: false
        )
        let request = try FloorpWebExtensionMessagePayload(jsonData: JSONSerialization.data(
            withJSONObject: [
                "scripts": [[
                    "id": "api-default-persistent",
                    "matches": ["https://*.fixture.test/*"],
                    "js": ["content/document-start.js"]
                ]]
            ]
        ))
        _ = try await host.dispatch(
            operation: "scripting.registerContentScripts",
            payload: request,
            sender: sender
        )

        let optionalRegisteredPayload = try await host.dispatch(
            operation: "scripting.getRegisteredContentScripts",
            payload: .init(jsonData: Data("{}".utf8)),
            sender: sender
        )
        let registeredPayload = try XCTUnwrap(optionalRegisteredPayload)
        let registered = try registeredPayload.decode([PersistentScriptAPIView].self)
        XCTAssertEqual(registered.map(\.id), ["api-default-persistent"])
        XCTAssertEqual(registered.first?.persistAcrossSessions, true)
        let storedPackageRecord = await store.installedPackage(for: extensionID)
        let storedPackage = try XCTUnwrap(storedPackageRecord)
        XCTAssertEqual(storedPackage.registeredPersistentScripts.map(\.id), ["api-default-persistent"])

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedCoordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: restartedStore.makeResourceLoader(),
            packageStore: restartedStore
        )
        await FloorpBootstrapper.restoreInstalledPackages(
            from: restartedStore,
            into: restartedCoordinator
        )
        let restored = await restartedCoordinator.registeredScripts(for: extensionID)
        XCTAssertTrue(restored.contains { $0.id == "api-default-persistent" && $0.persistAcrossSessions })
    }

    func testPersistentRegisteredScriptWriteFailureLeavesLiveAndDurableStateUnchanged() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registryWriter = RegistryWriteFailureInjector()
        let profileIdentifier = "package-persistent-scripts-failure-\(UUID().uuidString)"
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory,
            registryPersister: { data, url in
                try registryWriter.persist(data, to: url)
            }
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        let durable = FloorpWebExtensionRegisteredScript(
            id: "must-not-partially-register",
            matches: [try .init("https://*.fixture.test/*")],
            javaScript: [try .init("content/document-start.js")],
            persistAcrossSessions: true
        )

        registryWriter.shouldFail = true
        await assertAsyncThrows {
            try await coordinator.registerScripts([durable], for: self.extensionID)
        }

        let liveScripts = await coordinator.registeredScripts(for: extensionID)
        XCTAssertTrue(liveScripts.isEmpty)
        let packageRecord = await store.installedPackage(for: extensionID)
        let package = try XCTUnwrap(packageRecord)
        XCTAssertTrue(package.registeredPersistentScripts.isEmpty)
    }

    func testConcurrentPersistentRegistrationsCommitOneCoherentLiveAndDurableSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registryWriter = PausedRegistryPersister()
        let profileIdentifier = "package-persistent-scripts-concurrent-\(UUID().uuidString)"
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory,
            registryPersister: { data, url in
                try registryWriter.persist(data, to: url)
            }
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        let source = try FloorpWebExtensionScriptSource("content/document-start.js")
        let first = FloorpWebExtensionRegisteredScript(
            id: "first-persistent",
            matches: [try .init("https://*.fixture.test/*")],
            javaScript: [source],
            persistAcrossSessions: true
        )
        let second = FloorpWebExtensionRegisteredScript(
            id: "second-persistent",
            matches: [try .init("https://*.fixture.test/*")],
            javaScript: [source],
            persistAcrossSessions: true
        )

        registryWriter.pauseNextWrite()
        let firstRegistration = Task { @MainActor in
            try await coordinator.registerScripts([first], for: self.extensionID)
        }
        await registryWriter.waitUntilWriteIsPaused()
        let secondRegistration = Task { @MainActor in
            try await coordinator.registerScripts([second], for: self.extensionID)
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let scriptsBeforeRelease = await coordinator.registeredScripts(for: extensionID)
        // Live state is staged first, then the package-store write is the
        // transaction's final linearization point. The per-extension gate
        // keeps the second registration queued while that write is paused.
        XCTAssertEqual(scriptsBeforeRelease.map(\.id), [first.id])

        registryWriter.resumeWrite()
        try await firstRegistration.value
        try await secondRegistration.value

        let live = await coordinator.registeredScripts(for: extensionID)
        XCTAssertEqual(live.map(\.id), [first.id, second.id])
        let packageRecord = await store.installedPackage(for: extensionID)
        let package = try XCTUnwrap(packageRecord)
        XCTAssertEqual(package.registeredPersistentScripts, [first, second])
    }

    func testDisableGrantUpdateAndUninstallAreDurableAndRevokeExistingLoader() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-mutations",
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await store.installBundledPackage(
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
        await assertAsyncThrows {
            try await store.updateGrants(
                updatedGrants,
                for: self.extensionID,
                expectedGeneration: installed.generation
            )
        }
        try await store.setEnabled(true, for: extensionID)
        try await store.updateGrants(
            updatedGrants,
            for: extensionID,
            expectedGeneration: installed.generation
        )
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

    func testInitialGrantsCannotPregrantOptionalPermissionsAndApprovedOptionalGrantsPersist() async throws {
        let directory = temporaryDirectory()
        let fixture = try optionalPermissionFixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: fixture)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-optional-permissions",
            isPrivateBrowsing: false,
            directory: directory
        )
        let requiredHosts: Set<FloorpWebExtensionMatchPattern> = [
            try .init("http://*.fixture.test/*"),
            try .init("https://*.fixture.test/*")
        ]
        let optionalHost = try FloorpWebExtensionMatchPattern("https://one.optional.fixture.test/*")

        let pregrantedOptional = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.scripting, .tabs],
            requestedHosts: requiredHosts,
            normalHostAccess: .selectedSites([optionalHost])
        )
        await assertAsyncThrows {
            _ = try await store.installBundledPackage(
                at: fixture,
                expectedExtensionID: self.extensionID,
                initialGrants: pregrantedOptional
            )
        }

        let requiredOnly = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.scripting],
            requestedHosts: requiredHosts,
            normalHostAccess: .selectedSites([try .init("https://www.fixture.test/*")])
        )
        let installed = try await store.installBundledPackage(
            at: fixture,
            expectedExtensionID: extensionID,
            initialGrants: requiredOnly
        )

        let approvedOptional = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.scripting, .tabs],
            requestedHosts: requiredHosts,
            normalHostAccess: .selectedSites([optionalHost])
        )
        try await store.updateGrants(
            approvedOptional,
            for: extensionID,
            expectedGeneration: installed.generation
        )
        let livePackage = await store.installedPackage(for: extensionID)
        let live = try XCTUnwrap(livePackage)
        XCTAssertEqual(live.grants, approvedOptional)

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-optional-permissions",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedPackage = await restartedStore.installedPackage(for: extensionID)
        let restarted = try XCTUnwrap(restartedPackage)
        XCTAssertEqual(restarted.grants, approvedOptional)

        let undeclaredOptional = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.activeTab, .scripting, .tabs],
            requestedHosts: requiredHosts,
            normalHostAccess: .selectedSites([optionalHost])
        )
        await assertAsyncThrows {
            try await restartedStore.updateGrants(
                undeclaredOptional,
                for: self.extensionID,
                expectedGeneration: restarted.generation
            )
        }
    }

    func testBundledPackageUpdateMigratesExistingAuthorityWithoutGrantingNewRequirements() async throws {
        let directory = temporaryDirectory()
        let initialFixture = try optionalPermissionFixture()
        let replacementFixture = try permissionExpansionFixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: initialFixture)
            try? FileManager.default.removeItem(at: replacementFixture)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-update-permission-migration",
            isPrivateBrowsing: false,
            directory: directory
        )
        let initialManifest = try FloorpWebExtensionManifest.decode(
            Data(contentsOf: initialFixture.appendingPathComponent("manifest.json"))
        )
        let initialRequiredHosts = Set(initialManifest.hostPermissions)
        let optionalSite = try FloorpWebExtensionMatchPattern(
            "https://one.optional.fixture.test/*"
        )
        let initial = try await store.installBundledPackage(
            at: initialFixture,
            expectedExtensionID: extensionID,
            initialGrants: .init(
                apiPermissions: initialManifest.apiPermissions,
                requestedHosts: initialRequiredHosts,
                normalHostAccess: .allRequestedSites
            )
        )
        let approvedOptional = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: initialManifest.apiPermissions.union([.tabs]),
            requestedHosts: initialRequiredHosts,
            normalHostAccess: .selectedSites(initialRequiredHosts.union([optionalSite])),
            privateHostAccess: .selectedSites([optionalSite]),
            privateBrowsingEnabled: true
        )
        try await store.updateGrants(
            approvedOptional,
            for: extensionID,
            expectedGeneration: initial.generation
        )

        let replacement = try await store.installBundledPackage(
            at: initialFixture,
            expectedExtensionID: extensionID,
            initialGrants: approvedOptional
        )

        XCTAssertNotEqual(replacement.generation, initial.generation)
        XCTAssertTrue(replacement.grants.apiPermissions.contains(.tabs))
        XCTAssertFalse(replacement.grants.apiPermissions.contains(.activeTab))
        XCTAssertEqual(replacement.grants.requestedHosts, initialRequiredHosts)
        XCTAssertTrue(replacement.grants.privateBrowsingEnabled)
        guard case .selectedSites(let normalSites) = replacement.grants.normalHostAccess,
              case .selectedSites(let privateSites) = replacement.grants.privateHostAccess else {
            return XCTFail("An update must represent retained host authority without widening it")
        }
        // The replacement's optional declaration is a strict subset of the
        // already-approved `https://*.fixture.test/*` required host. Retaining
        // that narrower current declaration preserves existing authority if a
        // later update removes the broader declaration; it must not create any
        // URL authority outside the prior selection.
        let optionalDeclaration = try FloorpWebExtensionMatchPattern(
            "https://*.optional.fixture.test/*"
        )
        let previouslyApprovedNormalSites = initialRequiredHosts.union([optionalSite])
        XCTAssertEqual(
            normalSites,
            previouslyApprovedNormalSites.union([optionalDeclaration])
        )
        XCTAssertTrue(normalSites.allSatisfy { retained in
            previouslyApprovedNormalSites.contains { approved in
                approved.covers(retained)
            }
        })
        XCTAssertEqual(privateSites, [optionalSite])

        let replacementManifest = try FloorpWebExtensionManifest.decode(
            Data(contentsOf: replacementFixture.appendingPathComponent("manifest.json"))
        )
        do {
            _ = try await store.installBundledPackage(
                at: replacementFixture,
                expectedExtensionID: extensionID,
                initialGrants: .init(
                    apiPermissions: replacementManifest.apiPermissions,
                    requestedHosts: Set(replacementManifest.hostPermissions),
                    normalHostAccess: .allRequestedSites
                )
            )
            XCTFail("New required authority must require explicit update consent")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionPackageStoreError,
                .packageUpdateRequiresPermissionConsent(extensionID)
            )
        }
        let retainedRecord = await store.installedPackage(for: extensionID)
        let retained = try XCTUnwrap(retainedRecord)
        XCTAssertEqual(retained.generation, replacement.generation)
        XCTAssertEqual(retained.grants, replacement.grants)

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-update-permission-migration",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedRecord = await restartedStore.installedPackage(for: extensionID)
        let restarted = try XCTUnwrap(restartedRecord)
        XCTAssertEqual(restarted.generation, replacement.generation)
        XCTAssertEqual(restarted.grants, replacement.grants)
    }

    func testStalePreparedUpdateCannotCommitOverNewerTransaction() async throws {
        let directory = temporaryDirectory()
        let fixture = try optionalPermissionFixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: fixture)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-stale-update-rollback",
            isPrivateBrowsing: false,
            directory: directory
        )
        let first = try await store.installBundledPackage(
            at: fixture,
            expectedExtensionID: extensionID
        )
        let second = try await store.installBundledPackageTransaction(
            at: fixture,
            expectedExtensionID: extensionID
        )
        try await store.abortPreparedBundledPackageUpdate(
            extensionID: extensionID,
            replacementGeneration: second.installedPackage.generation
        )
        let third = try await store.installBundledPackageTransaction(
            at: fixture,
            expectedExtensionID: extensionID
        )

        do {
            try await store.commitPreparedBundledPackageUpdate(
                extensionID: extensionID,
                replacementGeneration: second.installedPackage.generation
            )
            XCTFail("A stale transaction must not commit over its replacement")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionPackageStoreError,
                .inactivePackageGeneration(extensionID)
            )
        }
        let currentRecord = await store.installedPackage(for: extensionID)
        let current = try XCTUnwrap(currentRecord)
        XCTAssertEqual(current.generation, first.generation)
        try await store.commitPreparedBundledPackageUpdate(
            extensionID: extensionID,
            replacementGeneration: third.installedPackage.generation
        )
        let committedRecord = await store.installedPackage(for: extensionID)
        XCTAssertEqual(committedRecord?.generation, third.installedPackage.generation)
    }

    func testPreparedUpdateKeepsCommittedLoadersOldAndRestartAbortsJournal() async throws {
        let directory = temporaryDirectory()
        let initialFixture = try optionalPermissionFixture()
        let candidateFixture = try contentUpdatedPermissionFixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: initialFixture)
            try? FileManager.default.removeItem(at: candidateFixture)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-prepared-update-recovery",
            isPrivateBrowsing: false,
            directory: directory
        )
        let original = try await store.installBundledPackage(
            at: initialFixture,
            expectedExtensionID: extensionID
        )
        let source = try FloorpWebExtensionScriptSource("content/document-start.js")
        let normalLoader = store.makeResourceLoader()
        XCTAssertFalse(try normalLoader(extensionID, source).contains("prepared-update-v2"))

        let transaction = try await store.installBundledPackageTransaction(
            at: candidateFixture,
            expectedExtensionID: extensionID
        )
        let candidate = transaction.installedPackage
        let stillCommittedRecord = await store.installedPackage(for: extensionID)
        XCTAssertEqual(stillCommittedRecord?.generation, original.generation)
        XCTAssertFalse(try normalLoader(extensionID, source).contains("prepared-update-v2"))
        let preparedResources = try await store.preparedPackageResources(
            extensionID: extensionID,
            replacementGeneration: candidate.generation
        )
        XCTAssertTrue(
            try preparedResources.scriptResourceLoader(extensionID, source)
                .contains("prepared-update-v2")
        )

        // Reopening the store models a process death anywhere after journal
        // persistence and before the final atomic commit.
        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-prepared-update-recovery",
            isPrivateBrowsing: false,
            directory: directory
        )
        let recoveredRecord = await restartedStore.installedPackage(for: extensionID)
        let recovered = try XCTUnwrap(recoveredRecord)
        XCTAssertEqual(recovered.generation, original.generation)
        XCTAssertFalse(
            try restartedStore.makeResourceLoader()(extensionID, source)
                .contains("prepared-update-v2")
        )
        let candidateDirectory = committedGenerationDirectory(root: directory, installed: candidate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateDirectory.path))
    }

    func testInterruptedUpdateRecoversPreviousWhenCandidateIsMissingOrCorrupt() async throws {
        enum CandidateFailure: String, CaseIterable {
            case missing
            case corrupt
        }

        let initialFixture = try optionalPermissionFixture()
        let candidateFixture = try contentUpdatedPermissionFixture()
        defer {
            try? FileManager.default.removeItem(at: initialFixture)
            try? FileManager.default.removeItem(at: candidateFixture)
        }
        let source = try FloorpWebExtensionScriptSource("content/document-start.js")

        for failure in CandidateFailure.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let profileIdentifier = "package-store-candidate-\(failure.rawValue)-recovery"
            let store = try FloorpWebExtensionPackageStore(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: false,
                directory: directory
            )
            let original = try await store.installBundledPackage(
                at: initialFixture,
                expectedExtensionID: extensionID
            )
            let transaction = try await store.installBundledPackageTransaction(
                at: candidateFixture,
                expectedExtensionID: extensionID
            )
            let candidateDirectory = committedGenerationDirectory(
                root: directory,
                installed: transaction.installedPackage
            )

            switch failure {
            case .missing:
                try FileManager.default.removeItem(at: candidateDirectory)
            case .corrupt:
                try Data("not a manifest".utf8).write(
                    to: candidateDirectory.appendingPathComponent("manifest.json"),
                    options: [.atomic]
                )
            }

            let restartedStore = try FloorpWebExtensionPackageStore(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: false,
                directory: directory
            )
            let recoveredRecord = await restartedStore.installedPackage(for: extensionID)
            let recovered = try XCTUnwrap(recoveredRecord)
            XCTAssertEqual(recovered.generation, original.generation, failure.rawValue)
            XCTAssertFalse(
                try restartedStore.makeResourceLoader()(extensionID, source)
                    .contains("prepared-update-v2"),
                failure.rawValue
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: candidateDirectory.path),
                failure.rawValue
            )
        }
    }

    func testLiveManagerActivatesCandidateBeforeAtomicRegistryCommit() async throws {
        let directory = temporaryDirectory()
        let initialFixture = try optionalPermissionFixture()
        let candidateFixture = try contentUpdatedPermissionFixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: initialFixture)
            try? FileManager.default.removeItem(at: candidateFixture)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-prepared-activation",
            isPrivateBrowsing: false,
            directory: directory
        )
        var packageURL = initialFixture
        var originalGeneration: String?
        var preparedActivationCount = 0
        let source = try FloorpWebExtensionScriptSource("content/document-start.js")
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, package, _ in
                if let package, originalGeneration == nil {
                    originalGeneration = package.generation
                }
            },
            bundledPackageURL: { _ in packageURL },
            reconcilePrepared: { _, candidate, _, resources in
                preparedActivationCount += 1
                let committed = await store.installedPackage(for: self.extensionID)
                XCTAssertEqual(committed?.generation, originalGeneration)
                XCTAssertNotEqual(candidate.generation, originalGeneration)
                XCTAssertFalse(
                    try store.makeResourceLoader()(self.extensionID, source)
                        .contains("prepared-update-v2")
                )
                XCTAssertTrue(
                    try resources.scriptResourceLoader(self.extensionID, source)
                        .contains("prepared-update-v2")
                )
            },
            unsignedPackageActivationPolicy: .allowVerifiedFixtureForTesting
        )

        try await manager.installBundledPackage(
            FloorpWebExtensionBundledCatalog.demandingMV3Fixture
        )
        packageURL = candidateFixture
        try await manager.installBundledPackage(
            FloorpWebExtensionBundledCatalog.demandingMV3Fixture
        )

        XCTAssertEqual(preparedActivationCount, 1)
        let committedRecord = await store.installedPackage(for: extensionID)
        let committed = try XCTUnwrap(committedRecord)
        XCTAssertNotEqual(committed.generation, originalGeneration)
        XCTAssertTrue(
            try store.makeResourceLoader()(extensionID, source)
                .contains("prepared-update-v2")
        )
    }

    func testLiveManagerUpdatePreservesDisabledStateWithoutActivation() async throws {
        let directory = temporaryDirectory()
        let fixture = try optionalPermissionFixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: fixture)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-disabled-update",
            isPrivateBrowsing: false,
            directory: directory
        )
        let original = try await store.installBundledPackage(
            at: fixture,
            expectedExtensionID: extensionID
        )
        try await store.setEnabled(false, for: extensionID)
        var reconciliationCount = 0
        var preparedActivationCount = 0
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in reconciliationCount += 1 },
            bundledPackageURL: { _ in fixture },
            reconcilePrepared: { _, _, _, _ in preparedActivationCount += 1 },
            unsignedPackageActivationPolicy: .allowVerifiedFixtureForTesting
        )

        try await manager.installBundledPackage(
            FloorpWebExtensionBundledCatalog.demandingMV3Fixture
        )

        let updatedRecord = await store.installedPackage(for: extensionID)
        let updated = try XCTUnwrap(updatedRecord)
        XCTAssertNotEqual(updated.generation, original.generation)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(reconciliationCount, 0)
        XCTAssertEqual(preparedActivationCount, 0)

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-disabled-update",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedRecord = await restartedStore.installedPackage(for: extensionID)
        XCTAssertEqual(restartedRecord?.generation, updated.generation)
        XCTAssertEqual(restartedRecord?.isEnabled, false)
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

    func testRestartFailsClosedWhenRegistryDNRLimitsAreInvalid() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-dnr-limit-tamper",
            isPrivateBrowsing: false,
            directory: directory
        )
        var installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        installed.dnrConfiguration = .init(
            limits: .init(maxDynamicRules: -1),
            enabledStaticRuleSetIDs: [],
            dynamicRules: []
        )
        try writeRegistry(root: directory, packages: [installed])

        XCTAssertThrowsError(
            try FloorpWebExtensionPackageStore(
                profileIdentifier: "package-store-dnr-limit-tamper",
                isPrivateBrowsing: false,
                directory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPackageStoreError, .corruptedRegistry)
        }
    }

    func testRestartFailsClosedWhenPersistentScriptMatchPatternFieldsAreNotCanonical() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileIdentifier = "package-store-script-pattern-fields-tamper"
        try await writePersistentRegisteredScript(
            root: directory,
            profileIdentifier: profileIdentifier
        )
        try mutateFirstPersistentRegisteredScript(root: directory) { script in
            var matches = try XCTUnwrap(script["matches"] as? [[String: Any]])
            matches[0]["path"] = "/tampered/*"
            script["matches"] = matches
        }

        XCTAssertThrowsError(
            try FloorpWebExtensionPackageStore(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: false,
                directory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPackageStoreError, .corruptedRegistry)
        }
    }

    func testRestartFailsClosedWhenPersistentScriptMatchPatternOriginalIsMalformed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileIdentifier = "package-store-script-pattern-original-tamper"
        try await writePersistentRegisteredScript(
            root: directory,
            profileIdentifier: profileIdentifier
        )
        try mutateFirstPersistentRegisteredScript(root: directory) { script in
            var matches = try XCTUnwrap(script["matches"] as? [[String: Any]])
            matches[0]["original"] = "not-a-match-pattern"
            script["matches"] = matches
        }

        XCTAssertThrowsError(
            try FloorpWebExtensionPackageStore(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: false,
                directory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPackageStoreError, .corruptedRegistry)
        }
    }

    func testRestartFailsClosedWhenPersistentScriptSourcePathIsUnsafe() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileIdentifier = "package-store-script-source-tamper"
        try await writePersistentRegisteredScript(
            root: directory,
            profileIdentifier: profileIdentifier
        )
        try mutateFirstPersistentRegisteredScript(root: directory) { script in
            var javaScript = try XCTUnwrap(script["javaScript"] as? [[String: Any]])
            javaScript[0]["path"] = "../manifest.json"
            script["javaScript"] = javaScript
        }

        XCTAssertThrowsError(
            try FloorpWebExtensionPackageStore(
                profileIdentifier: profileIdentifier,
                isPrivateBrowsing: false,
                directory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FloorpWebExtensionPackageStoreError, .corruptedRegistry)
        }
    }

    func testRegistryPersistenceFailureRestoresPriorLiveDNRPolicy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registryWriter = RegistryWriteFailureInjector()
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-dnr-persistence-failure",
            isPrivateBrowsing: false,
            directory: directory,
            registryPersister: { data, url in
                try registryWriter.persist(data, to: url)
            }
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )

        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: PackageStoreRuleListCompiler())
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "package-store-dnr-persistence-failure",
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        await coordinator.grantPermissions(
            [.declarativeNetRequest],
            requestedHosts: [],
            hostAccess: .denied,
            to: extensionID
        )
        let configuredInitialDNR = try await coordinator.configureDNR(for: extensionID)
        XCTAssertTrue(configuredInitialDNR)

        registryWriter.shouldFail = true
        await assertAsyncThrows {
            _ = try await coordinator.updateDynamicRules(
                addRules: [
                    .init(
                        id: 41,
                        action: .init(type: .block),
                        condition: .init(urlFilter: "tracker.example")
                    )
                ],
                removeRuleIDs: [],
                for: self.extensionID
            )
        }

        let failedUpdateSnapshot = await coordinator.dnrSnapshot(for: extensionID)
        let afterFailure = try XCTUnwrap(failedUpdateSnapshot)
        XCTAssertTrue(afterFailure.dynamicRules.isEmpty)
        let failedUpdateConfiguration = await store.dnrConfiguration(for: extensionID)
        XCTAssertEqual(failedUpdateConfiguration?.dynamicRules, [])
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.contentRuleListCount, 0)

        registryWriter.shouldFail = false
        let dynamicRulesUpdated = try await coordinator.updateDynamicRules(
            addRules: [
                .init(
                    id: 41,
                    action: .init(type: .block),
                    condition: .init(urlFilter: "tracker.example")
                )
            ],
            removeRuleIDs: [],
            for: extensionID
        )
        XCTAssertTrue(dynamicRulesUpdated)
        let updatedSnapshot = await coordinator.dnrSnapshot(for: extensionID)
        let updatedConfiguration = await store.dnrConfiguration(for: extensionID)
        XCTAssertEqual(updatedSnapshot?.dynamicRules.map(\.id), [41])
        XCTAssertEqual(updatedConfiguration?.dynamicRules.map(\.id), [41])

        let updatedExclusions = try await coordinator.updateExcludedTopLevelDomains(
            ["example.com"],
            for: extensionID
        )
        XCTAssertTrue(updatedExclusions)
        let exclusionConfiguration = await store.dnrConfiguration(for: extensionID)
        XCTAssertEqual(exclusionConfiguration?.excludedTopLevelDomains, ["example.com"])
        XCTAssertNotEqual(exclusionConfiguration?.policyGeneration, 0)

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-dnr-persistence-failure",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedConfiguration = await restartedStore.dnrConfiguration(for: extensionID)
        XCTAssertEqual(restartedConfiguration?.excludedTopLevelDomains, ["example.com"])
        XCTAssertEqual(
            restartedConfiguration?.policyGeneration,
            exclusionConfiguration?.policyGeneration
        )
    }

    func testRegistryPersistenceFailureFailsClosedWhenRollbackCannotCompile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registryWriter = RegistryWriteFailureInjector()
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-dnr-rollback-failure",
            isPrivateBrowsing: false,
            directory: directory,
            registryPersister: { data, url in
                try registryWriter.persist(data, to: url)
            }
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )

        let compiler = PackageStoreRuleListCompiler()
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: compiler)
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "package-store-dnr-rollback-failure",
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        await coordinator.grantPermissions(
            [.declarativeNetRequest],
            requestedHosts: [],
            hostAccess: .denied,
            to: extensionID
        )
        let staticRule = FloorpWebExtensionDNRRule(
            id: 1,
            action: .init(type: .block),
            condition: .init(urlFilter: "static.example")
        )
        let configuredStaticDNR = try await coordinator.configureDNR(
            for: extensionID,
            staticRuleSets: [.init(identifier: "large-static", rules: [staticRule])],
            enabledStaticRuleSetIDs: ["large-static"]
        )
        XCTAssertTrue(configuredStaticDNR)

        registryWriter.shouldFail = true
        compiler.failOnCompilationAttempt = 3
        await assertAsyncThrows {
            _ = try await coordinator.updateDynamicRules(
                addRules: [
                    .init(
                        id: 41,
                        action: .init(type: .block),
                        condition: .init(urlFilter: "dynamic.example")
                    )
                ],
                removeRuleIDs: [],
                for: self.extensionID
            )
        }

        let rollbackFailureSnapshot = await coordinator.dnrSnapshot(for: extensionID)
        XCTAssertNil(rollbackFailureSnapshot)
        XCTAssertNil(runtime.policySnapshot(for: extensionID))
        let rollbackFailureConfiguration = await store.dnrConfiguration(for: extensionID)
        XCTAssertTrue(rollbackFailureConfiguration?.dynamicRules.isEmpty ?? false)
    }

    // swiftlint:disable:next function_body_length
    func testRestoreFailurePreservesDynamicSnapshotAndDoesNotRestoreSessionRules() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: [.declarativeNetRequest],
            requestedHosts: [
                try .init("http://*.fixture.test/*"),
                try .init("https://*.fixture.test/*")
            ],
            normalHostAccess: .denied
        )
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-dnr-restore-atomicity",
            isPrivateBrowsing: false,
            directory: directory
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID,
            initialGrants: grants
        )
        let initialCoordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "package-store-dnr-restore-atomicity",
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        await initialCoordinator.grantPermissions(
            [.declarativeNetRequest],
            requestedHosts: [],
            hostAccess: .denied,
            to: extensionID
        )
        let configuredInitialDNR = try await initialCoordinator.configureDNR(for: extensionID)
        XCTAssertTrue(configuredInitialDNR)
        let updatedDynamicRules = try await initialCoordinator.updateDynamicRules(
            addRules: [
                .init(
                    id: 41,
                    action: .init(type: .block),
                    condition: .init(urlFilter: "dynamic.example")
                )
            ],
            removeRuleIDs: [],
            for: extensionID
        )
        XCTAssertTrue(updatedDynamicRules)
        let updatedSessionRules = try await initialCoordinator.updateSessionRules(
            addRules: [
                .init(
                    id: 42,
                    action: .init(type: .block),
                    condition: .init(urlFilter: "session.example")
                )
            ],
            removeRuleIDs: [],
            for: extensionID
        )
        XCTAssertTrue(updatedSessionRules)
        let persistedDynamicConfiguration = await store.dnrConfiguration(for: extensionID)
        XCTAssertEqual(persistedDynamicConfiguration?.dynamicRules.map(\.id), [41])

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-dnr-restore-atomicity",
            isPrivateBrowsing: false,
            directory: directory
        )
        let failingCompiler = PackageStoreRuleListCompiler()
        failingCompiler.shouldFail = true
        let failingCoordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "package-store-dnr-restore-atomicity",
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: failingCompiler),
            scriptResourceLoader: restartedStore.makeResourceLoader(),
            packageStore: restartedStore
        )
        await FloorpBootstrapper.restoreInstalledPackages(
            from: restartedStore,
            into: failingCoordinator
        )
        let failedRestoreSnapshot = await failingCoordinator.dnrSnapshot(for: extensionID)
        let failedRestoreConfiguration = await restartedStore.dnrConfiguration(for: extensionID)
        XCTAssertNil(failedRestoreSnapshot)
        XCTAssertEqual(failedRestoreConfiguration?.dynamicRules.map(\.id), [41])
        let failedPackageRecord = await restartedStore.installedPackage(for: extensionID)
        let failedPackage = try XCTUnwrap(failedPackageRecord)
        XCTAssertFalse(failedPackage.isEnabled)
        XCTAssertEqual(
            failedPackage.activationError,
            "This extension could not be activated. Enable it to try again."
        )

        let restoredStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-store-dnr-restore-atomicity",
            isPrivateBrowsing: false,
            directory: directory
        )
        // A disabled activation failure is inert after restart until the user
        // explicitly retries it.  Retrying clears the old diagnostic first.
        try await restoredStore.setEnabled(true, for: extensionID)
        let restoredCoordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "package-store-dnr-restore-atomicity",
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: restoredStore.makeResourceLoader(),
            packageStore: restoredStore
        )
        await FloorpBootstrapper.restoreInstalledPackages(
            from: restoredStore,
            into: restoredCoordinator
        )
        let restoredSnapshot = await restoredCoordinator.dnrSnapshot(for: extensionID)
        let restored = try XCTUnwrap(restoredSnapshot)
        XCTAssertEqual(restored.dynamicRules.map(\.id), [41])
        XCTAssertTrue(restored.sessionRules.isEmpty)
        let recoveredPackageRecord = await restoredStore.installedPackage(for: extensionID)
        let recoveredPackage = try XCTUnwrap(recoveredPackageRecord)
        XCTAssertTrue(recoveredPackage.isEnabled)
        XCTAssertNil(recoveredPackage.activationError)
    }

    func testLiveManagerPersistsDisabledActivationFailureUntilExplicitRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-activation-failure",
            isPrivateBrowsing: false,
            directory: directory
        )
        var shouldFailActivation = true
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, package, _ in
                if package != nil, shouldFailActivation {
                    throw FloorpWebExtensionError.unsupported("simulated WebKit policy failure")
                }
            },
            bundledPackageURL: { _ in
                try? self.checkedInDemandingMV3FixtureDirectory()
            },
            unsignedPackageActivationPolicy: .allowVerifiedFixtureForTesting
        )

        await assertAsyncThrows {
            try await manager.installBundledPackage(
                FloorpWebExtensionBundledCatalog.demandingMV3Fixture
            )
        }
        let failedPackageRecord = await store.installedPackage(for: extensionID)
        let failedPackage = try XCTUnwrap(failedPackageRecord)
        XCTAssertFalse(failedPackage.isEnabled)
        XCTAssertEqual(
            failedPackage.activationError,
            "This extension could not be activated. Enable it to try again."
        )

        let reloadedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-activation-failure",
            isPrivateBrowsing: false,
            directory: directory
        )
        let reloadedPackageRecord = await reloadedStore.installedPackage(for: extensionID)
        let reloadedPackage = try XCTUnwrap(reloadedPackageRecord)
        XCTAssertFalse(reloadedPackage.isEnabled)
        XCTAssertEqual(reloadedPackage.activationError, failedPackage.activationError)

        shouldFailActivation = false
        try await manager.setEnabled(true, for: extensionID)
        let recoveredPackageRecord = await store.installedPackage(for: extensionID)
        let recoveredPackage = try XCTUnwrap(recoveredPackageRecord)
        XCTAssertTrue(recoveredPackage.isEnabled)
        XCTAssertNil(recoveredPackage.activationError)
    }

    func testLiveManagerFailedUpdateRestoresPriorActiveGenerationAndGrants() async throws {
        let directory = temporaryDirectory()
        let fixture = try optionalPermissionFixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: fixture)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-update-rollback",
            isPrivateBrowsing: false,
            directory: directory
        )
        var failNextActivation = false
        var activatedGenerations = [String]()
        var rejectedGeneration: String?
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, package, _ in
                guard let package else { return }
                activatedGenerations.append(package.generation)
                if failNextActivation {
                    failNextActivation = false
                    rejectedGeneration = package.generation
                    throw FloorpWebExtensionError.unsupported(
                        "simulated replacement activation failure"
                    )
                }
            },
            bundledPackageURL: { _ in fixture },
            unsignedPackageActivationPolicy: .allowVerifiedFixtureForTesting
        )

        try await manager.installBundledPackage(
            FloorpWebExtensionBundledCatalog.demandingMV3Fixture
        )
        let originalRecord = await store.installedPackage(for: extensionID)
        let original = try XCTUnwrap(originalRecord)
        let optionalSite = try FloorpWebExtensionMatchPattern(
            "https://one.optional.fixture.test/*"
        )
        let approvedOptional = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: original.grants.apiPermissions.union([.tabs]),
            requestedHosts: original.grants.requestedHosts,
            normalHostAccess: .selectedSites(
                original.grants.requestedHosts.union([optionalSite])
            )
        )
        try await store.updateGrants(
            approvedOptional,
            for: extensionID,
            expectedGeneration: original.generation
        )
        let previousRecord = await store.installedPackage(for: extensionID)
        let previous = try XCTUnwrap(previousRecord)

        failNextActivation = true
        await assertAsyncThrows {
            try await manager.installBundledPackage(
                FloorpWebExtensionBundledCatalog.demandingMV3Fixture
            )
        }

        let rejected = try XCTUnwrap(rejectedGeneration)
        let retainedRecord = await store.installedPackage(for: extensionID)
        let retained = try XCTUnwrap(retainedRecord)
        XCTAssertEqual(retained.generation, previous.generation)
        XCTAssertEqual(retained.grants, approvedOptional)
        XCTAssertTrue(retained.isEnabled)
        XCTAssertNil(retained.activationError)
        XCTAssertEqual(
            activatedGenerations,
            [previous.generation, rejected, previous.generation]
        )
        let rejectedDirectory = directory
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(rejected, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedDirectory.path))

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-update-rollback",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedRecord = await restartedStore.installedPackage(for: extensionID)
        let restarted = try XCTUnwrap(restartedRecord)
        XCTAssertEqual(restarted.generation, previous.generation)
        XCTAssertEqual(restarted.grants, approvedOptional)
        XCTAssertTrue(restarted.isEnabled)
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
        var reconciliationOperations = [FloorpWebExtensionLivePackageManager.ReconciliationOperation]()
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { id, package, operation in
                XCTAssertEqual(id, self.extensionID)
                reconciledStates.append(package != nil)
                reconciliationOperations.append(operation)
            },
            unsignedPackageActivationPolicy: .allowVerifiedFixtureForTesting
        )

        try await manager.setEnabled(false, for: extensionID)
        XCTAssertEqual(reconciledStates, [false])
        let disabled = await store.installedPackage(for: extensionID)
        XCTAssertEqual(disabled?.isEnabled, false)

        try await manager.setEnabled(true, for: extensionID)
        XCTAssertEqual(reconciledStates, [false, true])
        let enabled = await store.installedPackage(for: extensionID)
        XCTAssertEqual(enabled?.isEnabled, true)

        try await manager.uninstall(extensionID)
        XCTAssertEqual(reconciledStates, [false, true, false, false])
        XCTAssertEqual(reconciliationOperations, [.suspend, .suspend, .suspend, .uninstall])
        let uninstalled = await store.installedPackage(for: extensionID)
        XCTAssertNil(uninstalled)
        let hasPendingPurge = await store.hasPendingDataPurge(for: extensionID)
        XCTAssertFalse(hasPendingPurge)
    }

    func testLiveManagerRestoresPackageAndPreservesDataWhenUninstallRegistryCommitFails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registryWriter = RegistryWriteFailureInjector()
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-uninstall-rollback",
            isPrivateBrowsing: false,
            directory: directory,
            registryPersister: { data, url in
                try registryWriter.persist(data, to: url)
            }
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        let loader = store.makeResourceLoader()
        let source = try FloorpWebExtensionScriptSource("content/document-start.js")
        var reconciledStates = [Bool]()
        var operations = [FloorpWebExtensionLivePackageManager.ReconciliationOperation]()
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, package, operation in
            reconciledStates.append(package != nil)
            operations.append(operation)
        }

        registryWriter.shouldFail = true
        await assertAsyncThrows {
            try await manager.uninstall(self.extensionID)
        }

        XCTAssertEqual(reconciledStates, [false, true])
        XCTAssertEqual(operations, [.suspend, .suspend])
        let retainedPackage = await store.installedPackage(for: extensionID)
        let hasPendingPurge = await store.hasPendingDataPurge(for: extensionID)
        XCTAssertNotNil(retainedPackage)
        XCTAssertFalse(hasPendingPurge)
        XCTAssertNoThrow(try loader(extensionID, source))

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-uninstall-rollback",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedPackage = await restartedStore.installedPackage(for: extensionID)
        XCTAssertNotNil(restartedPackage)
    }

    func testLiveManagerLeavesDurableTombstoneWhenCleanupFailsAndRetriesIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-uninstall-tombstone",
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        var shouldFailCleanup = true
        var operations = [FloorpWebExtensionLivePackageManager.ReconciliationOperation]()
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, _, operation in
            operations.append(operation)
            if operation == .uninstall, shouldFailCleanup {
                throw FloorpWebExtensionError.unsupported("simulated API cleanup failure")
            }
        }

        await assertAsyncThrows {
            try await manager.uninstall(self.extensionID)
        }
        let removedPackage = await store.installedPackage(for: extensionID)
        let pendingAfterFailure = await store.hasPendingDataPurge(for: extensionID)
        XCTAssertNil(removedPackage)
        XCTAssertTrue(pendingAfterFailure)
        let generationDirectory = directory
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(installed.generation, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: generationDirectory.path))

        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-uninstall-tombstone",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedPendingPurge = await restartedStore.hasPendingDataPurge(for: extensionID)
        XCTAssertTrue(restartedPendingPurge)

        shouldFailCleanup = false
        try await manager.uninstall(extensionID)
        let pendingAfterRetry = await store.hasPendingDataPurge(for: extensionID)
        XCTAssertFalse(pendingAfterRetry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: generationDirectory.path))
        XCTAssertEqual(operations, [.suspend, .uninstall, .suspend, .uninstall])
    }

    func testLiveManagerSerializesReloadBeforeConcurrentDisable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-live-manager-lifecycle-gate",
            isPrivateBrowsing: false,
            directory: directory
        )
        _ = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )

        let reconciliation = PausedLifecycleReconciliation()
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { id, package, operation in
                XCTAssertEqual(id, self.extensionID)
                XCTAssertEqual(operation, .suspend)
                try await reconciliation.reconcile(package)
            },
            unsignedPackageActivationPolicy: .allowVerifiedFixtureForTesting
        )

        let reloadTask = Task { @MainActor in
            try await manager.reload(self.extensionID)
        }
        await reconciliation.waitUntilInitialRevocation()

        let disableTask = Task { @MainActor in
            try await manager.setEnabled(false, for: self.extensionID)
        }
        // The disable task is allowed to reach the manager, but the gate must
        // prevent it from beginning its own reconciliation while reload is
        // paused between revocation and reactivation.
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(reconciliation.states, [false])

        await reconciliation.resumeInitialRevocation()
        try await reloadTask.value
        try await disableTask.value

        XCTAssertEqual(reconciliation.states, [false, true, false])
        let package = await store.installedPackage(for: extensionID)
        XCTAssertEqual(package?.isEnabled, false)
    }

    func testPermissionMutationAuthorizationCannotCrossDisableReenableOrReload() async throws {
        let directory = temporaryDirectory()
        let fixture = try optionalPermissionFixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: fixture)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-permission-authorization-lifecycle",
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await store.installBundledPackage(
            at: fixture,
            expectedExtensionID: extensionID
        )
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            unsignedPackageActivationPolicy: .allowVerifiedFixtureForTesting
        )
        let proposed = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: installed.grants.apiPermissions.union([.tabs]),
            requestedHosts: installed.grants.requestedHosts,
            normalHostAccess: installed.grants.normalHostAccess
        )

        let beforeDisable = try await manager.authorizePermissionMutation(
            for: extensionID,
            expectedGeneration: installed.generation
        )
        try await manager.setEnabled(false, for: extensionID)
        try await manager.setEnabled(true, for: extensionID)
        do {
            try await manager.updateGrants(proposed, authorization: beforeDisable)
            XCTFail("Consent captured before disable must not survive re-enable")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionPackageStoreError,
                .inactivePackageGeneration(extensionID)
            )
        }

        let beforeReload = try await manager.authorizePermissionMutation(
            for: extensionID,
            expectedGeneration: installed.generation
        )
        try await manager.reload(extensionID)
        do {
            try await manager.updateGrants(proposed, authorization: beforeReload)
            XCTFail("Consent captured before reload must not survive runtime replacement")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionPackageStoreError,
                .inactivePackageGeneration(extensionID)
            )
        }

        let retainedRecord = await store.installedPackage(for: extensionID)
        let retained = try XCTUnwrap(retainedRecord)
        XCTAssertFalse(retained.grants.apiPermissions.contains(.tabs))

        let currentAuthorization = try await manager.authorizePermissionMutation(
            for: extensionID,
            expectedGeneration: retained.generation
        )
        try await manager.updateGrants(proposed, authorization: currentAuthorization)
        let committedRecord = await store.installedPackage(for: extensionID)
        let committed = try XCTUnwrap(committedRecord)
        XCTAssertTrue(committed.grants.apiPermissions.contains(.tabs))
        await assertAsyncThrows {
            try await manager.updateGrants(proposed, authorization: currentAuthorization)
        }
    }

    func testPermissionMutationAuthorizationCannotCrossUpdateOrUninstall() async throws {
        let directory = temporaryDirectory()
        let fixture = try optionalPermissionFixture()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: fixture)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-permission-authorization-generation",
            isPrivateBrowsing: false,
            directory: directory
        )
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            bundledPackageURL: { _ in fixture },
            unsignedPackageActivationPolicy: .allowVerifiedFixtureForTesting
        )
        try await manager.installBundledPackage(
            FloorpWebExtensionBundledCatalog.demandingMV3Fixture
        )
        let firstRecord = await store.installedPackage(for: extensionID)
        let first = try XCTUnwrap(firstRecord)
        let beforeUpdate = try await manager.authorizePermissionMutation(
            for: extensionID,
            expectedGeneration: first.generation
        )
        let proposed = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: first.grants.apiPermissions.union([.tabs]),
            requestedHosts: first.grants.requestedHosts,
            normalHostAccess: first.grants.normalHostAccess
        )

        try await manager.installBundledPackage(
            FloorpWebExtensionBundledCatalog.demandingMV3Fixture
        )
        let replacementRecord = await store.installedPackage(for: extensionID)
        let replacement = try XCTUnwrap(replacementRecord)
        XCTAssertNotEqual(replacement.generation, first.generation)
        do {
            try await manager.updateGrants(proposed, authorization: beforeUpdate)
            XCTFail("Consent for a replaced generation must not mutate its replacement")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionPackageStoreError,
                .inactivePackageGeneration(extensionID)
            )
        }
        XCTAssertFalse(replacement.grants.apiPermissions.contains(.tabs))

        let beforeUninstall = try await manager.authorizePermissionMutation(
            for: extensionID,
            expectedGeneration: replacement.generation
        )
        try await manager.uninstall(extensionID)
        do {
            try await manager.updateGrants(proposed, authorization: beforeUninstall)
            XCTFail("Consent for an uninstalled generation must not be persisted")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionPackageStoreError,
                .inactivePackageGeneration(extensionID)
            )
        }
        let removed = await store.installedPackage(for: extensionID)
        XCTAssertNil(removed)
    }

    func testBootstrapRestoreSerializesWithConcurrentDisableThroughRegisteredManager() async throws {
        let directory = temporaryDirectory()
        let profileIdentifier = "package-startup-restore-\(UUID().uuidString)"
        defer {
            FloorpWebExtensionPackageStoreRegistry.removeStore(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        let reconciliation = PausedPackageRestoreReconciliation()
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, package, operation in
                XCTAssertEqual(operation, .suspend)
                await reconciliation.reconcile(package)
            },
            unsignedPackageActivationPolicy: .allowVerifiedFixtureForTesting
        )
        try FloorpWebExtensionPackageStoreRegistry.install(store, manager: manager)
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )

        let restoreTask = Task { @MainActor in
            await FloorpBootstrapper.restoreInstalledPackages(
                from: store,
                into: coordinator
            )
        }
        await reconciliation.waitUntilRestoreStarted()
        let disableTask = Task { @MainActor in
            try await manager.setEnabled(false, for: self.extensionID)
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(reconciliation.states, [true])
        let enabledWhileRestoreIsPaused = await store.installedPackage(for: extensionID)
        XCTAssertEqual(enabledWhileRestoreIsPaused?.isEnabled, true)

        reconciliation.resumeRestore()
        await restoreTask.value
        try await disableTask.value
        XCTAssertEqual(reconciliation.states, [true, false])
        let disabled = await store.installedPackage(for: extensionID)
        XCTAssertEqual(disabled?.isEnabled, false)

        let staleRestore = try await manager.restoreInstalledPackageIfCurrent(installed)
        XCTAssertFalse(staleRestore)
        XCTAssertEqual(reconciliation.states, [true, false])
    }

    func testReplacingRegisteredPackageStoreRejectsStalePermissionCommit() async throws {
        let directory = temporaryDirectory()
        let fixture = try optionalPermissionFixture()
        let profileIdentifier = "package-composition-cas-\(UUID().uuidString)"
        defer {
            FloorpWebExtensionPackageStoreRegistry.removeStore(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: fixture)
        }
        let firstStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await firstStore.installBundledPackage(
            at: fixture,
            expectedExtensionID: extensionID
        )
        let firstManager = FloorpWebExtensionLivePackageManager(store: firstStore) { _, _, _ in }
        try FloorpWebExtensionPackageStoreRegistry.install(firstStore, manager: firstManager)

        let replacementStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory
        )
        let replacementManager = FloorpWebExtensionLivePackageManager(
            store: replacementStore
        ) { _, _, _ in }
        try FloorpWebExtensionPackageStoreRegistry.install(
            replacementStore,
            manager: replacementManager
        )
        let proposed = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: installed.grants.apiPermissions.union([.tabs]),
            requestedHosts: installed.grants.requestedHosts,
            normalHostAccess: installed.grants.normalHostAccess
        )

        do {
            try await firstStore.updateGrants(
                proposed,
                for: extensionID,
                expectedGeneration: installed.generation
            )
            XCTFail("A replaced package-store actor must not write the shared registry")
        } catch {
            XCTAssertEqual(
                error as? FloorpWebExtensionPackageStoreError,
                .stalePackageComposition
            )
        }
        let current = await replacementStore.installedPackage(for: extensionID)
        XCTAssertEqual(current?.isEnabled, true)
        XCTAssertFalse(current?.grants.apiPermissions.contains(.tabs) ?? true)
        let restartedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory
        )
        let restarted = await restartedStore.installedPackage(for: extensionID)
        XCTAssertEqual(restarted?.isEnabled, true)
        XCTAssertFalse(restarted?.grants.apiPermissions.contains(.tabs) ?? true)
    }

    // swiftlint:disable:next function_body_length
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
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        let apiHost = try FloorpWebExtensionAPIHost(
            profileIdentifier: "package-bootstrap-restore",
            isPrivateBrowsing: false,
            directory: apiHostDirectory,
            preferredLocales: ["en"],
            packageResourceLoader: store.makeI18nResourceLoader()
        )
        let messageRuntime = FloorpWebExtensionMessageRuntime(nativeAPIDispatcher: apiHost)
        FloorpWebExtensionAPIHostRegistry.install(
            apiHost,
            messageRuntime: messageRuntime
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
        XCTAssertEqual(dnr.staticRuleSets.first?.rules.count, 5_000)
        XCTAssertEqual(dnr.enabledStaticRuleSetIDs, ["large-static"])

        let dynamicApplied = try await coordinator.updateDynamicRules(
            addRules: [
                .init(
                    id: 41,
                    action: .init(type: .block),
                    condition: .init(urlFilter: "tracker.example")
                )
            ],
            removeRuleIDs: [],
            for: extensionID
        )
        XCTAssertTrue(dynamicApplied)
        let updatedSnapshot = await coordinator.dnrSnapshot(for: extensionID)
        XCTAssertNotNil(updatedSnapshot)
        XCTAssertEqual(updatedSnapshot?.dynamicRules.map(\.id), [41])

        let reloadedStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "package-bootstrap-restore",
            isPrivateBrowsing: false,
            directory: directory
        )
        let reloadedRuntime = FloorpWebExtensionRuntime(
            contentRuleListCompiler: FloorpWKContentRuleListStoreCompiler(
                store: try XCTUnwrap(WKContentRuleListStore(url: ruleStoreDirectory))
            )
        )
        let reloadedCoordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "package-bootstrap-restore",
            isPrivateBrowsing: false,
            runtime: reloadedRuntime,
            scriptResourceLoader: reloadedStore.makeResourceLoader(),
            packageStore: reloadedStore
        )
        await FloorpBootstrapper.restoreInstalledPackages(
            from: reloadedStore,
            into: reloadedCoordinator
        )
        let restoredSnapshot = await reloadedCoordinator.dnrSnapshot(for: extensionID)
        XCTAssertNotNil(restoredSnapshot)
        XCTAssertEqual(restoredSnapshot?.dynamicRules.map(\.id), [41])
        XCTAssertEqual(restoredSnapshot?.enabledStaticRuleSetIDs, ["large-static"])

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
        await FloorpWebExtensionAPIHostRegistry.removeHost(for: apiHost.profileKey)
    }

    // swiftlint:disable:next function_body_length
    func testSignedCatalogVerifierFailsClosedForTamperingExpiryRollbackAndCrossLeafReuse() throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let valid = try signing.catalog(sequence: 2)
        let accepted = try verifier.verify(catalogData: valid, previousState: nil, now: signing.now)

        XCTAssertEqual(accepted.catalog.sequence, 2)
        XCTAssertEqual(accepted.catalog.packages.count, 1)
        XCTAssertEqual(accepted.catalog.packages[0].generation, "catalog-gen-1")
        var redefinedGenerationResources = signing.resources()
        redefinedGenerationResources["content/document-start.js"] = Data(
            "globalThis.floorpCatalogContentScript = 'redefined-generation';".utf8
        )
        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(
                sequence: 3,
                resources: redefinedGenerationResources
            ),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            guard case .invalidCatalog = error as? FloorpWebExtensionCatalogError else {
                return XCTFail("Expected an immutable-generation catalog rejection, got \(error)")
            }
        }

        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(
                sequence: 3,
                signingKeyID: "catalog-2026-q4",
                signingKey: signing.replacementLeaf
            ),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            guard case .invalidCatalog = error as? FloorpWebExtensionCatalogError else {
                return XCTFail("Expected cross-leaf generation reuse to be rejected, got \(error)")
            }
        }

        let revoked = try verifier.verify(
            catalogData: signing.catalog(
                sequence: 3,
                revocations: [.object([
                    "kind": .string("generation"),
                    "extensionID": .string(signing.extensionID.rawValue),
                    "generation": .string("catalog-gen-1"),
                    "effectiveAt": .string("2026-08-25T00:00:00Z")
                ])]
            ),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )
        XCTAssertTrue(revoked.catalog.nextAcceptanceState.revokedGenerations.contains(
            .init(extensionID: signing.extensionID, generation: "catalog-gen-1")
        ))
        XCTAssertThrowsError(try revoked.installablePackage(
            extensionID: signing.extensionID,
            generation: "catalog-gen-1"
        )) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .revoked)
        }

        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(
                sequence: 4,
                revocations: [.object([
                    "kind": .string("generation"),
                    "extensionID": .string(signing.extensionID.rawValue),
                    "generation": .string("catalog-gen-1"),
                    "effectiveAt": .string("2026-08-27T12:00:00Z")
                ])]
            ),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionCatalogError,
                .invalidCatalog("future-dated revocations are not supported")
            )
        }

        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(sequence: 3, corruptCatalogSignature: true),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .invalidSignature)
        }
        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(sequence: 3, expiresAt: "2026-08-25T00:00:00Z"),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .expired)
        }
        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .sequenceRollback)
        }
        XCTAssertThrowsError(try verifier.verify(
            catalogData: Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8),
            previousState: nil,
            now: signing.now
        )) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .invalidCanonicalJSON)
        }
        var nonCanonicalCatalog = try signing.catalog(sequence: 4)
        nonCanonicalCatalog.append(0x0A)
        XCTAssertThrowsError(try verifier.verify(
            catalogData: nonCanonicalCatalog,
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .invalidCanonicalJSON)
        }
    }

    func testSignedCatalogSchema2BindsCuratedProvenanceAndRejectsMalformedMetadata() throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let accepted = try verifier.verify(
            catalogData: signing.catalog(sequence: 1, schemaVersion: 2),
            previousState: nil,
            now: signing.now
        )

        let metadata = try XCTUnwrap(accepted.catalog.packages.first?.metadata)
        XCTAssertEqual(metadata.displayName, "Catalog Content Script")
        XCTAssertEqual(metadata.category, "productivity")
        XCTAssertEqual(metadata.sourceURL.host, "github.com")
        XCTAssertEqual(metadata.privateProfileCapability, .optIn)
        XCTAssertEqual(metadata.modificationStatus, .compatibilityPatched)
        XCTAssertEqual(metadata.hostPermissions.map(\.original), ["https://content-message.fixture.test/*"])

        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(
                sequence: 2,
                schemaVersion: 2,
                packageMetadata: signing.v2Metadata(permissions: ["tabs", "tabs"])
            ),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionCatalogError,
                .invalidCatalog("duplicate metadata permission")
            )
        }

        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(
                sequence: 2,
                schemaVersion: 2,
                packageMetadata: signing.v2Metadata(sourceURL: "http://example.test/source")
            ),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionCatalogError,
                .invalidCatalog("invalid upstream source URL")
            )
        }
    }

    func testSignedCatalogSchema2ArtifactRejectsMetadataThatLiesAboutPermissions() throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let accepted = try verifier.verify(
            catalogData: signing.catalog(sequence: 1, schemaVersion: 2),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(accepted.catalog.packages.first)
        let artifact = try signing.archive()

        XCTAssertNoThrow(try FloorpWebExtensionCatalogArchive.decode(artifact, record: record))
        let metadata = try XCTUnwrap(record.metadata)
        let misleadingMetadata = FloorpWebExtensionCatalogPackageMetadata(
            displayName: metadata.displayName,
            description: metadata.description,
            category: metadata.category,
            upstream: metadata.upstream,
            upstreamRevision: metadata.upstreamRevision,
            originalArtifactSHA256: metadata.originalArtifactSHA256,
            sourceURL: metadata.sourceURL,
            license: metadata.license,
            noticesSHA256: metadata.noticesSHA256,
            permissions: [.tabs],
            hostPermissions: metadata.hostPermissions,
            privateProfileCapability: metadata.privateProfileCapability,
            modificationStatus: metadata.modificationStatus,
            minimumFloorpBuild: metadata.minimumFloorpBuild,
            disclosure: metadata.disclosure
        )
        let misleadingRecord = FloorpWebExtensionCatalogPackageRecord(
            extensionID: record.extensionID,
            generation: record.generation,
            signingKeyID: record.signingKeyID,
            version: record.version,
            artifactURL: record.artifactURL,
            artifactBytes: record.artifactBytes,
            artifactSHA256: record.artifactSHA256,
            manifestSHA256: record.manifestSHA256,
            resourceInventorySHA256: record.resourceInventorySHA256,
            compatibilityProfiles: record.compatibilityProfiles,
            availability: record.availability,
            metadata: misleadingMetadata
        )

        XCTAssertThrowsError(try FloorpWebExtensionCatalogArchive.decode(
            artifact,
            record: misleadingRecord
        )) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionCatalogError,
                .artifactRejected("signed metadata does not match manifest permissions")
            )
        }
    }

    func testSettingsPermissionPresentationIncludesEverySupportedDarkReaderCapability() throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let accepted = try verifier.verify(
            catalogData: signing.catalog(
                sequence: 1,
                schemaVersion: 3,
                packageMetadata: signing.v3Metadata(permissions: [
                    "tabs",
                    "storage",
                    "alarms",
                    "fontSettings",
                    "declarativeNetRequest",
                    "scripting"
                ])
            ),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(accepted.catalog.packages.first)
        let item = try XCTUnwrap(FloorpWebExtensionBundledCatalog.signedItem(
            record: record,
            catalogExpiresAt: accepted.catalog.expiresAt
        ))

        XCTAssertEqual(item.requestedPermissions, [
            .siteData,
            .tabs,
            .storage,
            .alarms,
            .fontSettings,
            .networkBlocking,
            .browserAutomation
        ])
    }

    func testSignedCatalogSchema3BindsDisplayOnlyDisclosureAndRejectsUnsafeValues() throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let accepted = try verifier.verify(
            catalogData: signing.catalog(sequence: 1, schemaVersion: 3),
            previousState: nil,
            now: signing.now
        )

        let disclosure = try XCTUnwrap(accepted.catalog.packages.first?.metadata?.disclosure)
        XCTAssertEqual(disclosure.publisherDisplayName, "Floorp iOS")
        XCTAssertEqual(disclosure.attribution, "Original project: Floorp test fixture.")
        XCTAssertEqual(disclosure.supportRoute, .floorpGitHubIssues)
        XCTAssertEqual(disclosure.reportRoute, .floorpGitHubBugReport)
        XCTAssertEqual(disclosure.reviewedAt, "2026-08-26T00:00:00Z")

        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(
                sequence: 2,
                schemaVersion: 3,
                packageMetadata: signing.v3Metadata(
                    disclosure: signing.v3Disclosure(supportRoute: "unreviewed-external-url")
                )
            ),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionCatalogError,
                .invalidCatalog("invalid package disclosure")
            )
        }

        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(
                sequence: 2,
                schemaVersion: 3,
                packageMetadata: signing.v3Metadata(
                    disclosure: signing.v3Disclosure(reviewedAt: "2026-08-27T00:00:00Z")
                )
            ),
            previousState: accepted.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(
                error as? FloorpWebExtensionCatalogError,
                .invalidCatalog("invalid package disclosure")
            )
        }
    }

    func testExactAcceptedCatalogIsIdempotentButSequenceReuseWithDifferentBytesFailsClosed() throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let catalog = try signing.catalog(sequence: 1, schemaVersion: 2)
        let first = try verifier.verify(
            catalogData: catalog,
            previousState: nil,
            now: signing.now
        )
        let reaccepted = try verifier.verify(
            catalogData: catalog,
            previousState: first.catalog.nextAcceptanceState,
            now: signing.now
        )
        XCTAssertEqual(reaccepted.catalog.sequence, 1)
        XCTAssertEqual(
            reaccepted.catalog.nextAcceptanceState.acceptedCatalogSHA256,
            FloorpWebExtensionArtifactDownloader.sha256(catalog)
        )

        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(
                sequence: 1,
                generation: "catalog-gen-sequence-reuse",
                schemaVersion: 2
            ),
            previousState: first.catalog.nextAcceptanceState,
            now: signing.now
        )) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .sequenceRollback)
        }
    }

    func testSignedBundledCatalogRequiresEveryArtifactAndInstallsOnlyAcceptedRecord() async throws {
        let signing = try CatalogSigningFixture()
        let catalogData = try signing.catalog(sequence: 1, schemaVersion: 2)
        let artifactData = try signing.archive()
        let stateStore = InMemoryCatalogStateStore()
        let wasEnabled = FloorpFlags.isWebExtensionFeatureEnabled(.bundledCatalog)
        FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: wasEnabled) }

        let unavailable = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: catalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: signing.configuration.appBundleID,
            appVersion: signing.configuration.appVersion,
            catalogID: signing.configuration.catalogID,
            channel: signing.configuration.channel,
            stateStore: InMemoryCatalogStateStore(),
            artifactDataProvider: { _ in nil },
            clock: { signing.now },
            packageManagers: { [] }
        )
        await assertAsyncThrows {
            _ = try await unavailable.acceptAndApplyRevocations(now: signing.now)
        }
        XCTAssertTrue(unavailable.catalogItems().isEmpty)

        let runtime = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: catalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: signing.configuration.appBundleID,
            appVersion: signing.configuration.appVersion,
            catalogID: signing.configuration.catalogID,
            channel: signing.configuration.channel,
            stateStore: stateStore,
            artifactDataProvider: { record in
                record.extensionID == signing.extensionID ? artifactData : nil
            },
            clock: { signing.now },
            packageManagers: { [] }
        )
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-bundled-catalog",
            isPrivateBrowsing: false,
            directory: directory
        )
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            catalogRecordAuthorization: { record in
                try runtime.authorizeInstalledCatalogRecord(record)
            }
        )

        _ = try await runtime.acceptAndApplyRevocations(now: signing.now)
        let item = try XCTUnwrap(runtime.catalogItems().first)
        XCTAssertEqual(item.id, signing.extensionID)
        XCTAssertNotNil(item.catalogRecord)

        try await runtime.install(item, packageManager: manager)
        let installedRecord = await store.installedPackage(for: signing.extensionID)
        let installed = try XCTUnwrap(installedRecord)
        XCTAssertEqual(installed.catalogRecord, item.catalogRecord)
        XCTAssertEqual(installed.grants.normalHostAccess, .denied)
        XCTAssertFalse(installed.grants.privateBrowsingEnabled)

        let expectedMetadata = try XCTUnwrap(item.catalogRecord?.metadata)
        let settingsPackages = await manager.settingsPackages()
        let settingsPackage = try XCTUnwrap(settingsPackages.first(where: { $0.id == signing.extensionID }))
        XCTAssertEqual(settingsPackage.catalogGeneration, item.catalogRecord?.generation)
        XCTAssertEqual(settingsPackage.catalogDescription, expectedMetadata.description)
        XCTAssertEqual(
            settingsPackage.catalogSource,
            "\(expectedMetadata.upstream) @ \(expectedMetadata.upstreamRevision)"
        )
        XCTAssertEqual(settingsPackage.catalogLicense, expectedMetadata.license)
        XCTAssertEqual(settingsPackage.catalogHomepage, expectedMetadata.sourceURL)
        XCTAssertEqual(settingsPackage.catalogCategory, expectedMetadata.category)
        XCTAssertEqual(settingsPackage.catalogModificationStatus, expectedMetadata.modificationStatus)
        XCTAssertEqual(settingsPackage.privateProfileCapability, expectedMetadata.privateProfileCapability)

        var staleItem = item
        let staleRecord = FloorpWebExtensionCatalogPackageRecord(
            extensionID: signing.extensionID,
            generation: "stale-generation",
            signingKeyID: item.catalogRecord!.signingKeyID,
            version: item.version,
            artifactURL: item.catalogRecord!.artifactURL,
            artifactBytes: item.catalogRecord!.artifactBytes,
            artifactSHA256: item.catalogRecord!.artifactSHA256,
            manifestSHA256: item.catalogRecord!.manifestSHA256,
            resourceInventorySHA256: item.catalogRecord!.resourceInventorySHA256,
            compatibilityProfiles: item.catalogRecord!.compatibilityProfiles,
            availability: .available,
            metadata: item.catalogRecord!.metadata
        )
        staleItem = .init(
            id: item.id,
            name: item.name,
            version: item.version,
            summary: item.summary,
            source: item.source,
            license: item.license,
            packageDirectoryName: item.packageDirectoryName,
            requestedPermissions: item.requestedPermissions,
            catalogRecord: staleRecord
        )
        await assertAsyncThrows {
            try await runtime.install(staleItem, packageManager: manager)
        }
    }

    // swiftlint:disable:next function_body_length
    func testCatalogExpiryBlocksInstallAndRevivalWhilePreservingOfflineRestore() async throws {
        let signing = try CatalogSigningFixture()
        let expiresAt = "2026-08-26T12:01:00Z"
        var catalogResources = signing.resources()
        catalogResources["manifest.json"] = Data("""
        {
          "manifest_version": 3,
          "name": "Catalog Content Script",
          "version": "1.0.0",
          "host_permissions": ["https://content-message.fixture.test/*"],
          "optional_permissions": ["tabs"],
          "content_scripts": [{
            "matches": ["https://content-message.fixture.test/*"],
            "js": ["content/document-start.js"],
            "css": ["content/marker.css"],
            "run_at": "document_start",
            "world": "ISOLATED"
          }]
        }
        """.utf8)
        let catalogData = try signing.catalog(
            sequence: 1,
            expiresAt: expiresAt,
            resources: catalogResources,
            compatibilityProfiles: ["content-script", "action-storage"],
            schemaVersion: 2,
            packageMetadata: signing.v2Metadata(permissions: ["tabs"])
        )
        let artifactData = try signing.archive(resources: catalogResources)
        let stateStore = InMemoryCatalogStateStore()
        let clock = CatalogMutableClock(signing.now)
        let wasEnabled = FloorpFlags.isWebExtensionFeatureEnabled(.bundledCatalog)
        FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: wasEnabled) }

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-expiry-offline-restore",
            isPrivateBrowsing: false,
            directory: directory,
            clock: { clock.now() }
        )
        let signedRuntime = SignedCatalogRuntimeReference()
        let reconciliation = PausedLifecycleReconciliation()
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, package, _ in
                await reconciliation.reconcile(package)
            },
            catalogRecordAuthorization: { record in
                try signedRuntime.require().authorizeInstalledCatalogRecord(record)
            },
            catalogRecordExpirationProvider: { record in
                try signedRuntime.require().currentCatalogAuthorizationExpiry(for: record)
            },
            catalogRecordRestoreAuthorization: { record in
                try signedRuntime.require().authorizeInstalledCatalogRecordForOfflineRestore(record)
            }
        )
        let runtime = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: catalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: signing.configuration.appBundleID,
            appVersion: signing.configuration.appVersion,
            catalogID: signing.configuration.catalogID,
            channel: signing.configuration.channel,
            stateStore: stateStore,
            artifactDataProvider: { _ in artifactData },
            clock: { clock.now() },
            packageManagers: { [manager] }
        )
        signedRuntime.value = runtime

        _ = try await runtime.acceptAndApplyRevocations(now: signing.now)
        let item = try XCTUnwrap(runtime.catalogItems().first)
        let record = try XCTUnwrap(item.catalogRecord)
        let catalogExpiresAt = try XCTUnwrap(item.catalogExpiresAt)
        try await runtime.install(item, packageManager: manager)
        let installedPackage = await store.installedPackage(for: record.extensionID)
        let installed = try XCTUnwrap(installedPackage)
        let pendingOptionalPermission = try await manager.authorizePermissionMutation(
            for: record.extensionID,
            expectedGeneration: installed.generation
        )
        let proposedOptionalPermissionGrants = FloorpWebExtensionPermissionSnapshot(
            apiPermissions: installed.grants.apiPermissions.union([.tabs]),
            requestedHosts: installed.grants.requestedHosts,
            normalHostAccess: installed.grants.normalHostAccess,
            privateHostAccess: installed.grants.privateHostAccess,
            privateBrowsingEnabled: installed.grants.privateBrowsingEnabled
        )

        // The consent begins while valid, then the reconciler holds its
        // runtime suspension. Advancing past expiry at that await proves the
        // post-await authorization and actor-local durable write both reject
        // a grant captured before the native consent completed.
        let pendingGrantUpdate = Task { @MainActor in
            try await manager.updateGrants(
                proposedOptionalPermissionGrants,
                authorization: pendingOptionalPermission
            )
        }
        await reconciliation.waitUntilInitialRevocation()
        clock.advance(by: 120)
        reconciliation.resumeInitialRevocation()

        XCTAssertTrue(runtime.catalogItems().isEmpty)

        // A consent token captured before expiry cannot add an optional API
        // permission after the signed catalog lifetime ends.
        do {
            try await pendingGrantUpdate.value
            XCTFail("Expired catalog must not commit a pending optional permission grant")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .expired)
        }
        let afterExpiredConsent = await store.installedPackage(for: record.extensionID)
        XCTAssertFalse(try XCTUnwrap(afterExpiredConsent).grants.apiPermissions.contains(.tabs))

        // A fresh wrapper records the expiry failure, keeps catalog UI hidden,
        // and uses the narrow restore-only path for the already-enabled
        // package state. It never makes the expired catalog installable.
        let resumed = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: catalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: signing.configuration.appBundleID,
            appVersion: signing.configuration.appVersion,
            catalogID: signing.configuration.catalogID,
            channel: signing.configuration.channel,
            stateStore: stateStore,
            artifactDataProvider: { _ in artifactData },
            clock: { clock.now() },
            packageManagers: { [] }
        )
        do {
            _ = try await resumed.acceptAndApplyRevocations(now: clock.now())
            XCTFail("Expired catalog must not be accepted after restart")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .expired)
        }
        XCTAssertTrue(resumed.catalogItems().isEmpty)
        signedRuntime.value = resumed

        // Expiry does not revoke an already-enabled package: documented
        // offline behavior still restores its immutable generation.
        let restored = try await manager.restoreInstalledPackageIfCurrent(installed)
        XCTAssertTrue(restored)

        do {
            try await resumed.install(item, packageManager: manager)
            XCTFail("Expired catalog must not install a stale catalog item")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .expired)
        }

        try await manager.setEnabled(false, for: record.extensionID)
        do {
            try await store.setEnabled(
                true,
                for: record.extensionID,
                catalogExpiresAt: catalogExpiresAt
            )
            XCTFail("Store must reject an expired catalog at its durable enable boundary")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .expired)
        }
        do {
            try await manager.setEnabled(true, for: record.extensionID)
            XCTFail("Expired catalog must not revive a disabled package")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .expired)
        }
        let disabledPackage = await store.installedPackage(for: record.extensionID)
        let disabled = try XCTUnwrap(disabledPackage)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertFalse(disabled.isCatalogRevoked)
        XCTAssertThrowsError(try resumed.authorizeInstalledCatalogRecord(record)) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .expired)
        }

        // A pre-P0 Keychain record remains readable for anti-rollback history,
        // but has no signed expiry and therefore cannot authorize any path.
        let identity = FloorpWebExtensionCatalogGeneration(
            extensionID: record.extensionID,
            generation: record.generation
        )
        let binding = FloorpWebExtensionCatalogGenerationArtifactDigest(
            catalogGeneration: identity,
            artifactSHA256: record.artifactSHA256,
            signingKeyID: record.signingKeyID
        )
        let legacyStore = InMemoryCatalogStateStore()
        try legacyStore.save(.init(
            catalogID: signing.configuration.catalogID,
            highestSequence: 1,
            maximumObservedAt: signing.now,
            revokedKeyIDs: [],
            revokedGenerations: [],
            acceptedGenerationArtifacts: [binding],
            currentGenerationArtifacts: [binding]
        ))
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let legacyCoordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: legacyStore,
            clock: { signing.now },
            packageManagers: { [] }
        )
        let wasRemoteEnabled = FloorpFlags.isWebExtensionFeatureEnabled(.managedRemoteSource)
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: wasRemoteEnabled) }
        XCTAssertThrowsError(try legacyCoordinator.authorizeInstalledCatalogRecord(record)) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .revoked)
        }
        XCTAssertThrowsError(try legacyCoordinator.authorizeInstalledCatalogRecordForOfflineRestore(record)) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .revoked)
        }
    }

    func testSettingsNeverShowsFixtureCatalogWhileSignedCatalogIsLoading() async {
        let manager = PausedCatalogSettingsManager()
        defer { manager.resumeCatalogLoad() }
        let subject = FloorpWebExtensionSettingsViewController(
            windowUUID: .XCTestDefaultUUID,
            packageManager: manager,
            themeManager: MockThemeManager()
        )

        subject.loadViewIfNeeded()
        await manager.waitUntilCatalogRequested()

        XCTAssertEqual(subject.numberOfSections(in: subject.tableView), 2)
        XCTAssertEqual(subject.tableView(subject.tableView, numberOfRowsInSection: 0), 1)
        let installedLoading = subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        XCTAssertEqual(installedLoading.textLabel?.text, FloorpStrings.WebExtensions.loading)
        XCTAssertFalse(installedLoading.isUserInteractionEnabled)
        XCTAssertEqual(installedLoading.accessibilityIdentifier, "Floorp.WebExtensions.Installed.Loading")
        XCTAssertEqual(subject.tableView(subject.tableView, numberOfRowsInSection: 1), 1)
        let cell = subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )
        XCTAssertEqual(cell.textLabel?.text, FloorpStrings.WebExtensions.loading)
        XCTAssertFalse(cell.isUserInteractionEnabled)
        XCTAssertEqual(cell.accessibilityIdentifier, "Floorp.WebExtensions.CatalogLoading")
    }

    func testSettingsHidesPreviousCatalogWhileRefreshingItsSignedResult() async {
        let manager = PausedCatalogSettingsManager(
            initialCatalog: [FloorpWebExtensionBundledCatalog.demandingMV3Fixture],
            pauseOnRequest: 2
        )
        defer { manager.resumeCatalogLoad() }
        let subject = FloorpWebExtensionSettingsViewController(
            windowUUID: .XCTestDefaultUUID,
            packageManager: manager,
            themeManager: MockThemeManager()
        )

        subject.loadViewIfNeeded()
        await manager.waitUntilInitialCatalogDelivered()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(subject.tableView(subject.tableView, numberOfRowsInSection: 1), 1)
        let initiallyAvailable = subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )
        XCTAssertEqual(
            initiallyAvailable.accessibilityIdentifier,
            "Floorp.WebExtensions.Available.\(extensionID.rawValue)"
        )

        subject.viewWillAppear(false)
        await manager.waitUntilCatalogRequested()

        XCTAssertEqual(subject.tableView(subject.tableView, numberOfRowsInSection: 1), 1)
        let refreshLoading = subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )
        XCTAssertEqual(refreshLoading.accessibilityIdentifier, "Floorp.WebExtensions.CatalogLoading")
        XCTAssertFalse(refreshLoading.isUserInteractionEnabled)
    }

    func testSettingsCoalescesRefreshRequestedDuringAnInFlightSnapshot() async throws {
        let disabledPackage = settingsPackage(isEnabled: false)
        let enabledPackage = settingsPackage(isEnabled: true)
        let manager = PausedCatalogSettingsManager(
            initialPackages: [disabledPackage],
            pauseOnRequest: 2
        )
        defer { manager.resumeCatalogLoad() }
        let subject = FloorpWebExtensionSettingsViewController(
            windowUUID: .XCTestDefaultUUID,
            packageManager: manager,
            themeManager: MockThemeManager()
        )

        subject.loadViewIfNeeded()
        await manager.waitUntilInitialCatalogDelivered()
        for _ in 0 ..< 10 { await Task.yield() }
        let initialCell = try XCTUnwrap(subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        ) as? FloorpWebExtensionCardCell)
        XCTAssertEqual(initialCell.displayedStatus, FloorpStrings.WebExtensions.disabled)

        subject.viewWillAppear(false)
        await manager.waitUntilCatalogRequested()
        manager.replacePackages(with: [enabledPackage])
        subject.viewWillAppear(false)
        manager.resumeCatalogLoad()
        for _ in 0 ..< 50 { await Task.yield() }

        let refreshedCell = try XCTUnwrap(subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        ) as? FloorpWebExtensionCardCell)
        XCTAssertEqual(refreshedCell.displayedStatus, FloorpStrings.WebExtensions.enabled)
    }

    func testSettingsKeepsMutationBusyUntilAuthoritativeSnapshotCompletes() async throws {
        let disabledPackage = settingsPackage(isEnabled: false)
        let enabledPackage = settingsPackage(isEnabled: true)
        let manager = PausedCatalogSettingsManager(
            initialPackages: [disabledPackage],
            pauseOnRequest: 2,
            allowsEnabledMutation: true
        )
        defer { manager.resumeCatalogLoad() }
        let subject = FloorpWebExtensionSettingsViewController(
            windowUUID: .XCTestDefaultUUID,
            packageManager: manager,
            themeManager: MockThemeManager()
        )

        subject.loadViewIfNeeded()
        await manager.waitUntilInitialCatalogDelivered()
        for _ in 0 ..< 10 { await Task.yield() }
        manager.replacePackages(with: [enabledPackage])
        let mutationExtensionID = extensionID

        subject.mutate(for: mutationExtensionID) { manager in
            try await manager.setEnabled(true, for: mutationExtensionID)
        }
        await manager.waitUntilEnabledMutationCompleted()
        await manager.waitUntilCatalogRequested()

        let busyCell = try XCTUnwrap(subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        ) as? FloorpWebExtensionCardCell)
        XCTAssertTrue(busyCell.isShowingActivity)
        XCTAssertFalse(busyCell.isUserInteractionEnabled)
        XCTAssertEqual(busyCell.displayedStatus, FloorpStrings.WebExtensions.disabled)

        manager.resumeCatalogLoad()
        for _ in 0 ..< 50 { await Task.yield() }

        let refreshedCell = try XCTUnwrap(subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        ) as? FloorpWebExtensionCardCell)
        XCTAssertFalse(refreshedCell.isShowingActivity)
        XCTAssertTrue(refreshedCell.isUserInteractionEnabled)
        XCTAssertEqual(refreshedCell.displayedStatus, FloorpStrings.WebExtensions.enabled)
    }

    func testSettingsAvailableCatalogRowDisplaysSignedSchema3Disclosure() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let accepted = try verifier.verify(
            catalogData: signing.catalog(sequence: 1, schemaVersion: 3),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(accepted.catalog.packages.first)
        let item = try XCTUnwrap(FloorpWebExtensionBundledCatalog.signedItem(
            record: record,
            catalogExpiresAt: accepted.catalog.expiresAt
        ))
        let manager = PausedCatalogSettingsManager(
            initialCatalog: [item],
            pauseOnRequest: 2
        )
        defer { manager.resumeCatalogLoad() }
        let subject = FloorpWebExtensionSettingsViewController(
            windowUUID: .XCTestDefaultUUID,
            packageManager: manager,
            themeManager: MockThemeManager()
        )

        subject.loadViewIfNeeded()
        await manager.waitUntilInitialCatalogDelivered()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let available = try XCTUnwrap(subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        ) as? FloorpWebExtensionCardCell)
        XCTAssertEqual(
            available.accessibilityIdentifier,
            "Floorp.WebExtensions.Available.\(record.extensionID.rawValue)"
        )
        XCTAssertEqual(available.displayedTitle, item.name)
        XCTAssertEqual(available.displayedSummary, item.summary)
        XCTAssertEqual(available.displayedVersion, FloorpStrings.WebExtensions.version(item.version))
        XCTAssertEqual(available.displayedStatus, FloorpStrings.WebExtensions.add)
        XCTAssertNotNil(available.displayedIcon)

        let disclosure = try XCTUnwrap(record.metadata?.disclosure)
        let installPresentation = FloorpWebExtensionInstallPresentation(
            extensionID: record.extensionID,
            name: item.name,
            summary: item.summary,
            version: item.version,
            catalogPublisher: disclosure.publisherDisplayName,
            catalogAttribution: disclosure.attribution,
            catalogPrivacySummary: disclosure.privacySummary,
            catalogRetentionPolicy: disclosure.retentionPolicy,
            catalogReviewedAt: disclosure.reviewedAt,
            source: item.source,
            license: item.license,
            permissions: item.requestedPermissions,
            requestedSites: record.metadata?.hostPermissions.map(\.original) ?? [],
            privateProfileCapability: record.metadata?.privateProfileCapability
        )
        var installCount = 0
        let installController = FloorpWebExtensionInstallConfirmationViewController(
            presentation: installPresentation,
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager(),
            onCancel: {},
            onInstall: { installCount += 1 }
        )
        installController.loadViewIfNeeded()
        let allViews = Self.allSubviews(in: installController.view)
        let visibleText = allViews.compactMap { ($0 as? UILabel)?.text }.joined(separator: "\n")
        XCTAssertTrue(visibleText.contains(disclosure.publisherDisplayName))
        XCTAssertTrue(visibleText.contains(disclosure.attribution))
        XCTAssertTrue(visibleText.contains(FloorpStrings.WebExtensions.attributionLabel))
        XCTAssertTrue(visibleText.contains(disclosure.reviewedAt))
        XCTAssertTrue(visibleText.contains(disclosure.privacySummary))
        XCTAssertTrue(visibleText.contains(disclosure.retentionPolicy))
        XCTAssertTrue(visibleText.contains(FloorpStrings.WebExtensions.dataRetentionLabel))
        XCTAssertTrue(visibleText.contains(item.source))
        XCTAssertTrue(visibleText.contains(item.license))
        XCTAssertTrue(visibleText.contains(FloorpStrings.WebExtensions.siteAccessStartsOffTitle))
        for permission in item.requestedPermissions {
            XCTAssertTrue(visibleText.contains(permission.title))
        }
        let installButton = try XCTUnwrap(allViews.first {
            $0.accessibilityIdentifier ==
                "Floorp.WebExtensions.InstallConsent.Install.\(record.extensionID.rawValue)"
        } as? UIButton)
        installButton.sendActions(for: .touchUpInside)
        installButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(installCount, 1)
    }

    func testInstallReviewExplainsSiteAccessOnlyWhenRequestedAndDistinguishesUpdates() {
        func visibleText(for presentation: FloorpWebExtensionInstallPresentation) -> String {
            let controller = FloorpWebExtensionInstallConfirmationViewController(
                presentation: presentation,
                windowUUID: .XCTestDefaultUUID,
                themeManager: MockThemeManager(),
                onCancel: {},
                onInstall: {}
            )
            controller.loadViewIfNeeded()
            return Self.allSubviews(in: controller.view)
                .compactMap { ($0 as? UILabel)?.text }
                .joined(separator: "\n")
        }

        let base = FloorpWebExtensionInstallPresentation(
            extensionID: extensionID,
            name: "Fixture Extension",
            summary: "Reviewed extension",
            version: "2.0.0",
            source: "Fixture source",
            license: "MPL-2.0",
            permissions: [],
            requestedSites: ["https://example.com/*"]
        )
        let installText = visibleText(for: base)
        XCTAssertTrue(installText.contains(FloorpStrings.WebExtensions.siteAccessStartsOffTitle))
        XCTAssertFalse(installText.contains(FloorpStrings.WebExtensions.siteAccessPreservedTitle))

        let update = FloorpWebExtensionInstallPresentation(
            extensionID: base.extensionID,
            name: base.name,
            summary: base.summary,
            version: base.version,
            source: base.source,
            license: base.license,
            permissions: base.permissions,
            requestedSites: base.requestedSites,
            mode: .update
        )
        let updateText = visibleText(for: update)
        XCTAssertTrue(updateText.contains(FloorpStrings.WebExtensions.siteAccessPreservedTitle))
        XCTAssertTrue(updateText.contains(FloorpStrings.WebExtensions.siteAccessPreservedMessage))
        XCTAssertFalse(updateText.contains(FloorpStrings.WebExtensions.siteAccessStartsOffTitle))

        let noHosts = FloorpWebExtensionInstallPresentation(
            extensionID: base.extensionID,
            name: base.name,
            summary: base.summary,
            version: base.version,
            source: base.source,
            license: base.license,
            permissions: base.permissions,
            requestedSites: []
        )
        let noHostsText = visibleText(for: noHosts)
        XCTAssertFalse(noHostsText.contains(FloorpStrings.WebExtensions.siteAccessStartsOffTitle))
        XCTAssertFalse(noHostsText.contains(FloorpStrings.WebExtensions.siteAccessPreservedTitle))

        let allPermissions = FloorpWebExtensionInstallPresentation(
            extensionID: base.extensionID,
            name: base.name,
            summary: base.summary,
            version: base.version,
            source: base.source,
            license: base.license,
            permissions: FloorpWebExtensionPermissionCategory.allCases,
            requestedSites: []
        )
        let allPermissionsText = visibleText(for: allPermissions)
        let localizedExplanations = [
            FloorpStrings.WebExtensions.permissionSiteDataExplanation,
            FloorpStrings.WebExtensions.permissionTabsExplanation,
            FloorpStrings.WebExtensions.permissionStorageExplanation,
            FloorpStrings.WebExtensions.permissionAlarmsExplanation,
            FloorpStrings.WebExtensions.permissionFontSettingsExplanation,
            FloorpStrings.WebExtensions.permissionNetworkBlockingExplanation,
            FloorpStrings.WebExtensions.permissionBrowserAutomationExplanation
        ]
        for explanation in localizedExplanations {
            XCTAssertTrue(allPermissionsText.contains(explanation))
        }
    }

    func testExtensionIconRegistryAndCardBusyPresentation() throws {
        let darkReaderID = try XCTUnwrap(
            FloorpWebExtensionID(rawValue: "floorp.thirdparty.darkreader")
        )
        let descriptor = FloorpWebExtensionIconRegistry.descriptor(for: darkReaderID)
        XCTAssertEqual(descriptor.source, .system(name: "moon.stars.fill"))
        XCTAssertNotNil(descriptor.image())
        XCTAssertTrue(descriptor.usesTemplateRendering())

        let genericDescriptor = FloorpWebExtensionIconRegistry.descriptor(for: extensionID)
        XCTAssertEqual(genericDescriptor.source, .system(name: "puzzlepiece.extension.fill"))
        XCTAssertTrue(genericDescriptor.usesTemplateRendering())

        let theme = MockThemeManager().getCurrentTheme(for: .XCTestDefaultUUID)
        let cell = FloorpWebExtensionCardCell(style: .default, reuseIdentifier: nil)
        cell.configure(
            with: FloorpWebExtensionCardPresentation(
                extensionID: darkReaderID,
                title: "Dark Reader",
                summary: "Reviewed appearance extension",
                version: "4.9.129",
                status: .updateAvailable,
                accessibilityIdentifier: "Floorp.WebExtensions.Card.Test",
                accessibilityHint: FloorpStrings.WebExtensions.manage,
                isBusy: true
            ),
            theme: theme
        )
        XCTAssertEqual(cell.displayedTitle, "Dark Reader")
        XCTAssertEqual(cell.displayedStatus, FloorpStrings.WebExtensions.updateAvailable)
        XCTAssertNotNil(cell.displayedIcon)
        XCTAssertTrue(cell.isShowingActivity)
        XCTAssertFalse(cell.isUserInteractionEnabled)
        XCTAssertEqual(cell.accessibilityValue, FloorpStrings.WebExtensions.loading)

        cell.configure(
            with: FloorpWebExtensionCardPresentation(
                extensionID: darkReaderID,
                title: "Dark Reader",
                summary: "Reviewed appearance extension",
                version: "4.9.129",
                status: .enabled,
                accessibilityIdentifier: "Floorp.WebExtensions.Card.Test",
                accessibilityHint: FloorpStrings.WebExtensions.manage
            ),
            theme: theme
        )
        XCTAssertFalse(cell.isShowingActivity)
        XCTAssertTrue(cell.isUserInteractionEnabled)
        XCTAssertEqual(cell.accessibilityValue, FloorpStrings.WebExtensions.enabled)
    }

    func testInstalledDetailKeepsRevokedAndUnsupportedActionsFailClosed() throws {
        let presentation = FloorpWebExtensionInstalledDetailPresentation(
            extensionID: extensionID,
            name: "Fixture Extension",
            version: "1.0.0",
            isEnabled: false,
            isCatalogRevoked: true,
            permissions: [],
            siteAccessDescription: "No sites allowed",
            privateAccessDescription: "Not supported",
            isPrivateBrowsingEnabled: true,
            privateProfileCapability: .notSupported,
            updateVersion: "2.0.0"
        )
        let actions = FloorpWebExtensionInstalledDetailActions(
            onEnabledChanged: { _ in XCTFail("Revoked toggle must remain disabled") },
            onOpenOptions: nil,
            onManageSiteAccess: nil,
            onTogglePrivateBrowsing: { _ in XCTFail("Unsupported private action must be hidden") },
            onManagePrivateSiteAccess: { XCTFail("Unsupported private-site action must be hidden") },
            onManageNetworkProtection: nil,
            onManagePrivateNetworkProtection: nil,
            onOpenWebsite: nil,
            onViewUpdateHistory: nil,
            onUpdate: { XCTFail("Revoked update action must be hidden") },
            onUninstall: {}
        )
        let subject = FloorpWebExtensionInstalledDetailViewController(
            presentation: presentation,
            actions: actions,
            windowUUID: .XCTestDefaultUUID,
            themeManager: MockThemeManager()
        )
        subject.loadViewIfNeeded()

        let statusLabel = try XCTUnwrap(
            Self.allSubviews(in: subject.view)
                .compactMap { $0 as? UILabel }
                .first { $0.text == FloorpStrings.WebExtensions.revoked }
        )
        XCTAssertEqual(statusLabel.numberOfLines, 0)
        XCTAssertTrue(statusLabel.superview?.constraints.contains { constraint in
            (constraint.firstItem as? UIView) === statusLabel &&
                constraint.firstAttribute == .trailing &&
                constraint.relation == .lessThanOrEqual
        } == true)
        var identifiers = [String]()
        var visibleText = [String]()
        for section in 0 ..< subject.numberOfSections(in: subject.tableView) {
            for row in 0 ..< subject.tableView(subject.tableView, numberOfRowsInSection: section) {
                let cell = subject.tableView(
                    subject.tableView,
                    cellForRowAt: IndexPath(row: row, section: section)
                )
                if let identifier = cell.accessibilityIdentifier { identifiers.append(identifier) }
                if let text = cell.textLabel?.text { visibleText.append(text) }
                if let detail = cell.detailTextLabel?.text { visibleText.append(detail) }
                if let toggle = cell.accessoryView as? UISwitch {
                    XCTAssertFalse(toggle.isEnabled)
                    XCTAssertEqual(toggle.accessibilityLabel, "Fixture Extension")
                }
            }
        }
        XCTAssertFalse(identifiers.contains { $0.contains("PrivateBrowsing") })
        XCTAssertFalse(identifiers.contains { $0.contains("PrivateSiteAccess") })
        XCTAssertFalse(identifiers.contains { $0.contains("Update.") })
        XCTAssertTrue(identifiers.contains {
            $0 == "Floorp.WebExtensions.Detail.Uninstall.\(extensionID.rawValue)"
        })
        XCTAssertTrue(visibleText.contains(FloorpStrings.WebExtensions.catalogRevokedDisabledMessage))
        XCTAssertTrue(visibleText.contains(FloorpStrings.WebExtensions.catalogRevokedGuidance))
    }

    func testSettingsReportsMissingPackageStoreWithoutClaimingCatalogFailure() {
        let subject = FloorpWebExtensionSettingsViewController(
            windowUUID: .XCTestDefaultUUID,
            packageManager: nil,
            themeManager: MockThemeManager()
        )
        subject.loadViewIfNeeded()

        let cell = subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        XCTAssertEqual(cell.textLabel?.text, FloorpStrings.WebExtensions.packageStoreUnavailableTitle)
        XCTAssertEqual(cell.detailTextLabel?.text, FloorpStrings.WebExtensions.packageStoreUnavailableMessage)
        XCTAssertNotEqual(cell.detailTextLabel?.text, FloorpStrings.WebExtensions.loadErrorMessage)
        XCTAssertEqual(cell.accessibilityIdentifier, "Floorp.WebExtensions.Unavailable")
        XCTAssertFalse(cell.isUserInteractionEnabled)
    }

    func testPrimaryExtensionAccessSummariesUseLocalizedFormats() {
        XCTAssertTrue(FloorpStrings.WebExtensions.allRequestedSites(1).contains("1"))
        XCTAssertTrue(FloorpStrings.WebExtensions.allRequestedSites(2).contains("2"))
        XCTAssertTrue(FloorpStrings.WebExtensions.selectedSites(1).contains("1"))
        XCTAssertTrue(FloorpStrings.WebExtensions.selectedSites(2).contains("2"))
        XCTAssertFalse(FloorpStrings.WebExtensions.allRequestedWebsites.isEmpty)
        XCTAssertFalse(FloorpStrings.WebExtensions.privateAccessNotAllowed.isEmpty)
    }

    func testSettingsHidesCachedCatalogItemsWhenTheirSignedLifetimeEnds() async {
        let clock = CatalogMutableClock(Date(timeIntervalSince1970: 1_000))
        let item = FloorpWebExtensionBundledCatalogItem(
            id: extensionID,
            name: "Expiring catalog item",
            version: "1.0.0",
            summary: "A test-only Settings row with signed-lifetime metadata.",
            source: "Floorp test",
            license: "MPL-2.0",
            packageDirectoryName: "expiring-catalog-item",
            requestedPermissions: [],
            catalogExpiresAt: clock.now().addingTimeInterval(86_400)
        )
        let manager = PausedCatalogSettingsManager(
            initialCatalog: [item],
            pauseOnRequest: 2
        )
        defer { manager.resumeCatalogLoad() }
        let subject = FloorpWebExtensionSettingsViewController(
            windowUUID: .XCTestDefaultUUID,
            packageManager: manager,
            clock: { clock.now() },
            themeManager: MockThemeManager()
        )

        subject.loadViewIfNeeded()
        await manager.waitUntilInitialCatalogDelivered()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        let available = subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )
        XCTAssertEqual(
            available.accessibilityIdentifier,
            "Floorp.WebExtensions.Available.\(extensionID.rawValue)"
        )

        clock.advance(by: 86_401)
        XCTAssertEqual(subject.tableView(subject.tableView, numberOfRowsInSection: 1), 1)
        let unavailable = subject.tableView(
            subject.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1)
        )
        XCTAssertEqual(unavailable.accessibilityIdentifier, "Floorp.WebExtensions.CatalogUnavailable")
        XCTAssertFalse(unavailable.isUserInteractionEnabled)
    }

    func testLiveManagerDefaultCompositionRejectsUnsignedFixtureCatalog() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "unsigned-fixture-default-rejection",
            isPrivateBrowsing: false,
            directory: directory
        )
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, _, _ in }

        let catalogItems = await manager.catalogItems()
        XCTAssertTrue(catalogItems.isEmpty)
        await assertAsyncThrows {
            try await manager.installBundledPackage(
                FloorpWebExtensionBundledCatalog.demandingMV3Fixture
            )
        }
        let installedPackage = await store.installedPackage(for: extensionID)
        XCTAssertNil(installedPackage)
    }

    func testProductionCatalogPolicyStopsPersistedUnsignedFixtureAcrossLifecycle() async throws {
        let directory = temporaryDirectory()
        let profileIdentifier = "unsigned-fixture-upgrade-\(UUID().uuidString)"
        defer {
            FloorpWebExtensionPackageStoreRegistry.removeStore(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: directory
        )
        let installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID,
            initialGrants: .init(
                apiPermissions: [.declarativeNetRequest],
                requestedHosts: [
                    try .init("http://*.fixture.test/*"),
                    try .init("https://*.fixture.test/*")
                ]
            )
        )
        var reconciledPackages = [FloorpWebExtensionInstalledPackage?]()
        var didUpdateDNRExclusions = false
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, package, _ in
                reconciledPackages.append(package)
            },
            unsignedPackageActivationPolicy: .reject,
            dnrExcludedTopLevelDomainsUpdater: { _, _ in
                didUpdateDNRExclusions = true
                return true
            }
        )
        try FloorpWebExtensionPackageStoreRegistry.install(store, manager: manager)

        await assertAsyncThrows {
            try await manager.setNormalDNRExcludedTopLevelDomains(
                ["fixture.test"],
                for: self.extensionID
            )
        }
        XCTAssertFalse(didUpdateDNRExclusions)
        XCTAssertEqual(reconciledPackages, [nil])
        let stoppedByDNRMutationRecord = await store.installedPackage(for: extensionID)
        let stoppedByDNRMutation = try XCTUnwrap(stoppedByDNRMutationRecord)
        XCTAssertFalse(stoppedByDNRMutation.isEnabled)
        XCTAssertNotNil(stoppedByDNRMutation.activationError)

        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: PackageStoreRuleListCompiler()),
            scriptResourceLoader: store.makeResourceLoader(),
            packageStore: store
        )
        await FloorpBootstrapper.restoreInstalledPackages(from: store, into: coordinator)

        XCTAssertEqual(reconciledPackages, [nil])
        let registeredScripts = await coordinator.registeredScripts(for: extensionID)
        XCTAssertTrue(registeredScripts.isEmpty)
        let stoppedRecord = await store.installedPackage(for: extensionID)
        let stopped = try XCTUnwrap(stoppedRecord)
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertNotNil(stopped.activationError)
        XCTAssertEqual(stopped.generation, installed.generation)
        XCTAssertNotNil(stopped.fixture)
        XCTAssertNil(stopped.catalogRecord)

        await assertAsyncThrows {
            try await manager.setEnabled(true, for: self.extensionID)
        }
        await assertAsyncThrows {
            try await manager.reload(self.extensionID)
        }
        let stillStopped = await store.installedPackage(for: extensionID)
        XCTAssertFalse(stillStopped?.isEnabled ?? true)
        XCTAssertFalse(didUpdateDNRExclusions)
    }

    func testCatalogStateMigratesLegacySignerlessBindingWithoutAuthorizingIt() throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        let generation = FloorpWebExtensionCatalogGeneration(
            extensionID: record.extensionID,
            generation: record.generation
        )
        let legacyState = FloorpWebExtensionCatalogAcceptanceState(
            catalogID: signing.configuration.catalogID,
            highestSequence: 1,
            maximumObservedAt: signing.now,
            revokedKeyIDs: [],
            revokedGenerations: [],
            acceptedGenerationArtifacts: [
                .init(
                    catalogGeneration: generation,
                    artifactSHA256: record.artifactSHA256,
                    signingKeyID: nil
                )
            ]
        )

        let migrated = try verifier.verify(
            catalogData: signing.catalog(sequence: 2),
            previousState: legacyState,
            now: signing.now
        )
        XCTAssertTrue(migrated.catalog.nextAcceptanceState.acceptedGenerationArtifacts.contains(
            .init(
                catalogGeneration: generation,
                artifactSHA256: record.artifactSHA256,
                signingKeyID: "catalog-2026-q3"
            )
        ))
        XCTAssertFalse(migrated.catalog.nextAcceptanceState.acceptedGenerationArtifacts.contains(
            .init(
                catalogGeneration: generation,
                artifactSHA256: record.artifactSHA256,
                signingKeyID: nil
            )
        ))

        var redefinedResources = signing.resources()
        redefinedResources["content/document-start.js"] = Data(
            "globalThis.floorpCatalogContentScript = 'legacy-binding-redefinition';".utf8
        )
        XCTAssertThrowsError(try verifier.verify(
            catalogData: signing.catalog(sequence: 2, resources: redefinedResources),
            previousState: legacyState,
            now: signing.now
        )) { error in
            guard case .invalidCatalog = error as? FloorpWebExtensionCatalogError else {
                return XCTFail("Expected legacy immutable-generation rejection, got \(error)")
            }
        }
    }

    func testCatalogAcceptanceStateIsCommittedOnlyForANewerVerifiedCatalog() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let stateStore = InMemoryCatalogStateStore()
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: stateStore,
            clock: { signing.now },
            packageManagers: { [] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        XCTAssertEqual(stateStore.state?.highestSequence, 1)

        await assertAsyncThrows {
            _ = try await coordinator.acceptAndApplyRevocations(
                catalogData: signing.catalog(sequence: 2, corruptCatalogSignature: true),
                now: signing.now
            )
        }
        XCTAssertEqual(stateStore.state?.highestSequence, 1)

        do {
            _ = try await coordinator.acceptAndApplyRevocations(
                catalogData: signing.catalog(sequence: 2),
                now: signing.now.addingTimeInterval(-301)
            )
            XCTFail("Clock rollback must reject catalog acceptance")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .clockRollback)
        }
        XCTAssertEqual(stateStore.state?.highestSequence, 1)
    }

    func testManagedRemoteCatalogGateIsClosedUnlessExplicitlyEnabled() throws {
        let wasEnabled = FloorpFlags.isWebExtensionFeatureEnabled(.managedRemoteSource)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: wasEnabled) }
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false)

        XCTAssertThrowsError(try FloorpWebExtensionInternalCatalogReleaseGate.requireManagedSourceEnabled()) {
            XCTAssertEqual($0 as? FloorpWebExtensionCatalogError, .remoteCatalogDisabled)
        }
    }

    func testSignedCatalogArtifactRejectsDigestZipAndPathAttacks() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let result = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(result.catalog.packages.first)
        let archive = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let downloaded = try await downloader.download(catalog: result, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        XCTAssertEqual(downloaded.resources["manifest.json"], signing.resources()["manifest.json"])

        await assertAsyncThrows {
            _ = try await downloader.download(catalog: result, record: record) { _ in
                .init(
                    finalURL: URL(string: "https://catalog.floorp.test/redirected.fwea")!,
                    statusCode: 200,
                    data: archive
                )
            }
        }

        var modified = archive
        modified[modified.startIndex] ^= 0x01
        let tamperedArchive = modified
        await assertAsyncThrows {
            _ = try await downloader.download(catalog: result, record: record) { url in
                .init(finalURL: url, statusCode: 200, data: tamperedArchive)
            }
        }

        let manifestMismatchRecord = signing.record(
            generation: "manifest-mismatch",
            artifact: archive,
            manifestDigest: String(repeating: "0", count: 64),
            inventoryDigest: record.resourceInventorySHA256
        )
        await assertAsyncThrows {
            _ = try await downloader.download(catalog: result, record: manifestMismatchRecord) { url in
                .init(finalURL: url, statusCode: 200, data: archive)
            }
        }

        let zip = Data([0x50, 0x4B, 0x03, 0x04])
        let zipRecord = signing.record(
            generation: "zip-attack",
            artifact: zip,
            manifestDigest: String(repeating: "0", count: 64),
            inventoryDigest: String(repeating: "0", count: 64)
        )
        await assertAsyncThrows {
            _ = try await downloader.download(catalog: result, record: zipRecord) { url in
                .init(finalURL: url, statusCode: 200, data: zip)
            }
        }

        let unsafeArchive = try signing.rawArchive(
            path: "../manifest.json",
            payload: Data("blocked".utf8)
        )
        let unsafeRecord = signing.record(
            generation: "path-attack",
            artifact: unsafeArchive,
            manifestDigest: String(repeating: "0", count: 64),
            inventoryDigest: String(repeating: "0", count: 64)
        )
        await assertAsyncThrows {
            _ = try await downloader.download(catalog: result, record: unsafeRecord) { url in
                .init(finalURL: url, statusCode: 200, data: unsafeArchive)
            }
        }
    }

    func testCatalogPackageInstallationIsAtomicAndRevocationStopsResources() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let firstCatalog = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let firstRecord = try XCTUnwrap(firstCatalog.catalog.packages.first)
        let firstArchive = try signing.archive()
        let firstArtifact = try await downloader.download(catalog: firstCatalog, record: firstRecord) { url in
            .init(finalURL: url, statusCode: 200, data: firstArchive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-catalog-package-store",
            isPrivateBrowsing: false,
            directory: directory
        )
        let forgedRecord = signing.record(
            generation: "catalog-forged-manifest",
            artifact: firstArchive,
            manifestDigest: String(repeating: "0", count: 64),
            inventoryDigest: firstRecord.resourceInventorySHA256
        )
        await assertAsyncThrows {
            _ = try await store.installVerifiedCatalogPackageTransaction(.init(
                catalogID: firstArtifact.catalogID,
                catalogSequence: firstArtifact.catalogSequence,
                record: forgedRecord,
                resources: firstArtifact.resources
            ))
        }
        let packagesAfterForgedArtifact = await store.installedPackages()
        XCTAssertTrue(packagesAfterForgedArtifact.isEmpty)
        let initialGrants = FloorpWebExtensionPermissionSnapshot(
            requestedHosts: [try .init("https://content-message.fixture.test/*")],
            normalHostAccess: .allRequestedSites
        )
        let installed = (try await store.installVerifiedCatalogPackageTransaction(
            firstArtifact,
            initialGrants: initialGrants
        )).installedPackage
        XCTAssertEqual(installed.catalogRecord, firstRecord)
        XCTAssertNil(installed.fixture)
        XCTAssertTrue(try store.makeResourceLoader()(
            firstRecord.extensionID,
            .init("content/document-start.js")
        ).contains("floorpCatalogContentScript"))

        let unsupportedCatalog = try verifier.verify(
            catalogData: signing.catalog(
                sequence: 2,
                generation: "catalog-gen-2",
                resources: signing.unsupportedDNRResources()
            ),
            previousState: firstCatalog.catalog.nextAcceptanceState,
            now: signing.now
        )
        let unsupportedRecord = try XCTUnwrap(unsupportedCatalog.catalog.packages.first)
        let unsupportedArchive = try signing.archive(resources: signing.unsupportedDNRResources())
        let unsupportedArtifact = try await downloader.download(
            catalog: unsupportedCatalog,
            record: unsupportedRecord
        ) { url in
            .init(finalURL: url, statusCode: 200, data: unsupportedArchive)
        }
        await assertAsyncThrows {
            _ = try await store.installVerifiedCatalogPackageTransaction(unsupportedArtifact)
        }
        let afterRejectedRecord = await store.installedPackage(for: firstRecord.extensionID)
        let afterRejectedUpdate = try XCTUnwrap(afterRejectedRecord)
        XCTAssertEqual(afterRejectedUpdate.generation, installed.generation)
        XCTAssertTrue(afterRejectedUpdate.isEnabled)

        try await store.recordCatalogRevocation(
            for: firstRecord.extensionID,
            catalogGeneration: firstRecord.generation
        )
        let revokedRecord = await store.installedPackage(for: firstRecord.extensionID)
        let revoked = try XCTUnwrap(revokedRecord)
        XCTAssertFalse(revoked.isEnabled)
        XCTAssertTrue(revoked.activationError?.contains("revoked") == true)
        XCTAssertThrowsError(try store.makeResourceLoader()(
            firstRecord.extensionID,
            .init("content/document-start.js")
        ))
        await assertAsyncThrows {
            try await store.setEnabled(true, for: firstRecord.extensionID)
        }
        let afterEnableAttempt = await store.installedPackage(for: firstRecord.extensionID)
        XCTAssertTrue(try XCTUnwrap(afterEnableAttempt).isCatalogRevoked)
        XCTAssertFalse(try XCTUnwrap(afterEnableAttempt).isEnabled)

        let restarted = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-catalog-package-store",
            isPrivateBrowsing: false,
            directory: directory
        )
        let restartedRecord = await restarted.installedPackage(for: firstRecord.extensionID)
        XCTAssertFalse(try XCTUnwrap(restartedRecord).isEnabled)
    }

    func testCuratedCatalogDNRRejectsAnOtherwiseSupportedNonBlockAction() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let resources = signing.upgradeSchemeDNRResources()
        let catalog = try verifier.verify(
            catalogData: signing.catalog(
                sequence: 1,
                resources: resources,
                compatibilityProfiles: ["dnr"]
            ),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(catalog.catalog.packages.first)
        let archive = try signing.archive(resources: resources)
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: catalog, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-dnr-block-only",
            isPrivateBrowsing: false,
            directory: directory
        )

        await assertAsyncThrows {
            _ = try await store.installVerifiedCatalogPackageTransaction(artifact)
        }
        let installedPackages = await store.installedPackages()
        XCTAssertTrue(installedPackages.isEmpty)
    }

    func testCatalogRevocationReconcilesRuntimeBeforePersistingDisable() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let catalog = try verifier.verify(catalogData: signing.catalog(sequence: 1), previousState: nil, now: signing.now)
        let record = try XCTUnwrap(catalog.catalog.packages.first)
        let archive = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: catalog, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-catalog-manager",
            isPrivateBrowsing: false,
            directory: directory
        )
        var reconciliation = [(
            FloorpWebExtensionInstalledPackage?,
            FloorpWebExtensionLivePackageManager.ReconciliationOperation
        )]()
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, package, operation in
            reconciliation.append((package, operation))
        }
        let stateStore = InMemoryCatalogStateStore()
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: stateStore,
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }
        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: manager)
        try await manager.revokeCatalogGeneration(
            extensionID: record.extensionID,
            catalogGeneration: record.generation
        )
        XCTAssertEqual(reconciliation.last?.0, nil)
        XCTAssertEqual(reconciliation.last?.1, .suspend)
        let managerRecord = await store.installedPackage(for: record.extensionID)
        XCTAssertFalse(try XCTUnwrap(managerRecord).isEnabled)
    }

    func testKeyRevocationStopsInstalledGenerationsBeforeCatalogStateCommits() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        XCTAssertEqual(record.signingKeyID, "catalog-2026-q3")
        let archive = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: initial, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-catalog-key-revocation",
            isPrivateBrowsing: false,
            directory: directory
        )
        var reconciliation = [(
            FloorpWebExtensionInstalledPackage?,
            FloorpWebExtensionLivePackageManager.ReconciliationOperation
        )]()
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, package, operation in
            reconciliation.append((package, operation))
        }
        let stateStore = InMemoryCatalogStateStore()
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: stateStore,
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }
        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: manager)

        let revokedCatalog = try signing.catalog(
            sequence: 2,
            generation: "catalog-gen-2",
            revocations: [.object([
                "kind": .string("key"),
                "keyID": .string("catalog-2026-q3"),
                "effectiveAt": .string("2026-08-25T00:00:00Z")
            ])],
            signingKeyID: "catalog-2026-q4",
            signingKey: signing.replacementLeaf
        )
        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: revokedCatalog,
            now: signing.now
        )
        XCTAssertTrue(stateStore.state?.revokedKeyIDs.contains("catalog-2026-q3") == true)
        XCTAssertEqual(reconciliation.last?.0, nil)
        XCTAssertEqual(reconciliation.last?.1, .suspend)
        let revoked = await store.installedPackage(for: record.extensionID)
        XCTAssertFalse(try XCTUnwrap(revoked).isEnabled)
    }

    func testCatalogAcceptanceStateStopsAnUnboundCatalogPackageBeforeCommit() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        let archive = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: initial, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-acceptance-state",
            isPrivateBrowsing: false,
            directory: directory
        )
        var reconciliation = [(
            FloorpWebExtensionInstalledPackage?,
            FloorpWebExtensionLivePackageManager.ReconciliationOperation
        )]()
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, package, operation in
            reconciliation.append((package, operation))
        }
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: InMemoryCatalogStateStore(),
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: manager)
        reconciliation.removeAll()

        try await manager.applySignedCatalogAcceptanceState(
            initial.catalog.nextAcceptanceState
        )
        XCTAssertTrue(reconciliation.isEmpty)

        // This models a catalog record whose immutable provenance no longer
        // appears in the verifier-produced device state (for example after a
        // local registry-record alteration). The runtime must stop before the
        // new state is written to Keychain.
        let unboundState = FloorpWebExtensionCatalogAcceptanceState(
            catalogID: initial.catalog.catalogID,
            highestSequence: 2,
            maximumObservedAt: signing.now,
            revokedKeyIDs: [],
            revokedGenerations: [],
            acceptedGenerationArtifacts: []
        )
        try await manager.applySignedCatalogAcceptanceState(unboundState)

        XCTAssertEqual(reconciliation.count, 1)
        XCTAssertNil(reconciliation.first?.0)
        XCTAssertEqual(reconciliation.first?.1, .suspend)
        let stoppedPackage = await store.installedPackage(for: record.extensionID)
        let stopped = try XCTUnwrap(stoppedPackage)
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertTrue(stopped.isCatalogRevoked)
    }

    func testCatalogLifecycleRejectsAStaleArtifactAfterLaterRevocation() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let archive = try signing.archive()
        let artifact = try await downloader.download(catalog: initial, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "stale-revoked-catalog-artifact",
            isPrivateBrowsing: false,
            directory: directory
        )
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, _, _ in }
        let stateStore = InMemoryCatalogStateStore()
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: stateStore,
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(
                sequence: 2,
                generation: "catalog-gen-2",
                revocations: [.object([
                    "kind": .string("key"),
                    "keyID": .string("catalog-2026-q3"),
                    "effectiveAt": .string("2026-08-25T00:00:00Z")
                ])],
                signingKeyID: "catalog-2026-q4",
                signingKey: signing.replacementLeaf
            ),
            now: signing.now
        )

        await assertAsyncThrows {
            try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: manager)
        }
        let packageAfterRejectedInstall = await store.installedPackage(for: record.extensionID)
        XCTAssertNil(packageAfterRejectedInstall)
    }

    func testCatalogStartupAuthorizationRequiresAcceptedBindingAndPersistsRevocation() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        let archive = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: initial, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-startup-authorization",
            isPrivateBrowsing: false,
            directory: directory
        )
        let stateStore = InMemoryCatalogStateStore()
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: stateStore,
            clock: { signing.now },
            packageManagers: { [] }
        )
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            catalogRecordAuthorization: { record in
                try coordinator.authorizeInstalledCatalogRecord(record)
            }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: manager)

        let rogueRecord = signing.record(
            generation: "not-accepted-by-catalog",
            artifact: archive,
            manifestDigest: record.manifestSHA256,
            inventoryDigest: record.resourceInventorySHA256
        )
        XCTAssertThrowsError(try coordinator.authorizeInstalledCatalogRecord(rogueRecord)) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .revoked)
        }
        let alteredSignerRecord = FloorpWebExtensionCatalogPackageRecord(
            extensionID: record.extensionID,
            generation: record.generation,
            signingKeyID: "catalog-2026-q4",
            version: record.version,
            artifactURL: record.artifactURL,
            artifactBytes: record.artifactBytes,
            artifactSHA256: record.artifactSHA256,
            manifestSHA256: record.manifestSHA256,
            resourceInventorySHA256: record.resourceInventorySHA256,
            compatibilityProfiles: record.compatibilityProfiles,
            availability: record.availability
        )
        XCTAssertThrowsError(try coordinator.authorizeInstalledCatalogRecord(alteredSignerRecord)) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .revoked)
        }

        let revoked = try verifier.verify(
            catalogData: signing.catalog(
                sequence: 2,
                revocations: [.object([
                    "kind": .string("generation"),
                    "extensionID": .string(record.extensionID.rawValue),
                    "generation": .string(record.generation),
                    "effectiveAt": .string("2026-08-25T00:00:00Z")
                ])]
            ),
            previousState: stateStore.state,
            now: signing.now
        )
        try stateStore.save(revoked.catalog.nextAcceptanceState)

        let installedPackage = await store.installedPackage(for: record.extensionID)
        let installed = try XCTUnwrap(installedPackage)
        await assertAsyncThrows {
            _ = try await manager.restoreInstalledPackageIfCurrent(installed)
        }
        let afterRestorePackage = await store.installedPackage(for: record.extensionID)
        let afterRestore = try XCTUnwrap(afterRestorePackage)
        XCTAssertTrue(afterRestore.isCatalogRevoked)
        XCTAssertFalse(afterRestore.isEnabled)
    }

    func testCatalogReloadAuthorizationFailureStopsRuntimeAndPersistsRevocation() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        let archive = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: initial, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-reload-authorization",
            isPrivateBrowsing: false,
            directory: directory
        )
        let stateStore = InMemoryCatalogStateStore()
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: stateStore,
            clock: { signing.now },
            packageManagers: { [] }
        )
        var reconciledPackages = [FloorpWebExtensionInstalledPackage?]()
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, package, operation in
                XCTAssertEqual(operation, .suspend)
                reconciledPackages.append(package)
            },
            catalogRecordAuthorization: { record in
                try coordinator.authorizeInstalledCatalogRecord(record)
            }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: manager)
        reconciledPackages.removeAll()

        let revoked = try verifier.verify(
            catalogData: signing.catalog(
                sequence: 2,
                revocations: [.object([
                    "kind": .string("generation"),
                    "extensionID": .string(record.extensionID.rawValue),
                    "generation": .string(record.generation),
                    "effectiveAt": .string("2026-08-25T00:00:00Z")
                ])]
            ),
            previousState: stateStore.state,
            now: signing.now
        )
        try stateStore.save(revoked.catalog.nextAcceptanceState)

        do {
            try await manager.reload(record.extensionID)
            XCTFail("A revoked catalog package must not reload")
        } catch {
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .revoked)
        }
        XCTAssertEqual(reconciledPackages.count, 1)
        XCTAssertNil(reconciledPackages.first!)
        let afterReloadPackage = await store.installedPackage(for: record.extensionID)
        let afterReload = try XCTUnwrap(afterReloadPackage)
        XCTAssertTrue(afterReload.isCatalogRevoked)
        XCTAssertFalse(afterReload.isEnabled)
    }

    func testCatalogRevocationFansOutToNormalAndPrivateManagers() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        let archive = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: initial, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let normalStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-revocation-fanout",
            isPrivateBrowsing: false,
            directory: directory.appendingPathComponent("normal", isDirectory: true)
        )
        let privateStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-revocation-fanout",
            isPrivateBrowsing: true,
            directory: directory.appendingPathComponent("private", isDirectory: true)
        )
        let normalManager = FloorpWebExtensionLivePackageManager(store: normalStore) { _, _, _ in }
        let privateManager = FloorpWebExtensionLivePackageManager(store: privateStore) { _, _, _ in }
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: InMemoryCatalogStateStore(),
            clock: { signing.now },
            packageManagers: { [normalManager, privateManager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: normalManager)
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: privateManager)
        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(
                sequence: 2,
                revocations: [.object([
                    "kind": .string("generation"),
                    "extensionID": .string(record.extensionID.rawValue),
                    "generation": .string(record.generation),
                    "effectiveAt": .string("2026-08-25T00:00:00Z")
                ])]
            ),
            now: signing.now
        )

        let normalPackage = await normalStore.installedPackage(for: record.extensionID)
        let privatePackage = await privateStore.installedPackage(for: record.extensionID)
        XCTAssertFalse(try XCTUnwrap(normalPackage).isEnabled)
        XCTAssertFalse(try XCTUnwrap(privatePackage).isEnabled)
    }

    func testSignedBundledCatalogRequiresConsentForSamePermissionGeneration() async throws {
        let signing = try CatalogSigningFixture()
        let firstCatalogData = try signing.catalog(sequence: 1, schemaVersion: 2)
        var updatedResources = signing.resources()
        updatedResources["manifest.json"] = Data("""
        {
          "manifest_version": 3,
          "name": "Catalog Content Script",
          "version": "1.0.1",
          "host_permissions": ["https://content-message.fixture.test/*"],
          "content_scripts": [{
            "matches": ["https://content-message.fixture.test/*"],
            "js": ["content/document-start.js"],
            "css": ["content/marker.css"],
            "run_at": "document_start",
            "world": "ISOLATED"
          }]
        }
        """.utf8)
        updatedResources["content/document-start.js"] = Data(
            "globalThis.floorpCatalogContentScript = 'signed-generation-two';".utf8
        )
        let secondCatalogData = try signing.catalog(
            sequence: 2,
            generation: "catalog-gen-2",
            version: "1.0.1",
            resources: updatedResources,
            schemaVersion: 2
        )
        let firstArtifactData = try signing.archive()
        let secondArtifactData = try signing.archive(resources: updatedResources)
        let stateStore = InMemoryCatalogStateStore()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-bundled-confirmed-update",
            isPrivateBrowsing: false,
            directory: directory
        )
        var didRequestConsent = false
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            catalogUpdateConfirmation: { _ in
                didRequestConsent = true
                return true
            }
        )
        let wasEnabled = FloorpFlags.isWebExtensionFeatureEnabled(.bundledCatalog)
        FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: wasEnabled) }

        let firstRuntime = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: firstCatalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: signing.configuration.appBundleID,
            appVersion: signing.configuration.appVersion,
            catalogID: signing.configuration.catalogID,
            channel: signing.configuration.channel,
            stateStore: stateStore,
            artifactDataProvider: { _ in firstArtifactData },
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        _ = try await firstRuntime.acceptAndApplyRevocations(now: signing.now)
        try await firstRuntime.install(
            try XCTUnwrap(firstRuntime.catalogItems().first),
            packageManager: manager
        )

        let secondRuntime = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: secondCatalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: signing.configuration.appBundleID,
            appVersion: signing.configuration.appVersion,
            catalogID: signing.configuration.catalogID,
            channel: signing.configuration.channel,
            stateStore: stateStore,
            artifactDataProvider: { _ in secondArtifactData },
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        _ = try await secondRuntime.acceptAndApplyRevocations(now: signing.now)
        let secondItem = try XCTUnwrap(secondRuntime.catalogItems().first)

        let installedAfterAcceptance = await store.installedPackage(for: signing.extensionID)
        XCTAssertEqual(
            try XCTUnwrap(installedAfterAcceptance).generation,
            try XCTUnwrap(firstRuntime.catalogItems().first).catalogRecord?.localGeneration
        )
        XCTAssertFalse(didRequestConsent)

        try await secondRuntime.install(secondItem, packageManager: manager)
        let installedAfterUpdate = await store.installedPackage(for: signing.extensionID)
        XCTAssertEqual(
            try XCTUnwrap(installedAfterUpdate).generation,
            try XCTUnwrap(secondItem.catalogRecord).localGeneration
        )
        XCTAssertTrue(didRequestConsent)
        let history = await store.catalogUpdateHistory(for: signing.extensionID)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.method, .userApproved)
    }

    // swiftlint:disable:next function_body_length
    func testPrivateProfileRequiresExplicitSeparateSignedInstallationAndKeepsGrantsIsolated() async throws {
        let signing = try CatalogSigningFixture()
        let catalogData = try signing.catalog(sequence: 1, schemaVersion: 2)
        let artifactData = try signing.archive()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let normalStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-private-isolation",
            isPrivateBrowsing: false,
            directory: directory.appendingPathComponent("normal", isDirectory: true)
        )
        let privateStore = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-private-isolation",
            isPrivateBrowsing: true,
            directory: directory.appendingPathComponent("private", isDirectory: true)
        )
        var signedRuntime: FloorpWebExtensionSignedBundledCatalog?
        let signedInstaller: FloorpWebExtensionLivePackageManager.SignedBundledCatalogInstaller = { manager, item in
            guard let signedRuntime else {
                throw FloorpWebExtensionCatalogError.revoked
            }
            try await signedRuntime.install(item, packageManager: manager)
        }
        let normalManager = FloorpWebExtensionLivePackageManager(
            store: normalStore,
            reconcile: { _, _, _ in },
            catalogItemsProvider: {
                signedRuntime?.catalogItems() ?? []
            },
            signedBundledCatalogInstaller: signedInstaller,
            catalogRecordAuthorization: { record in
                guard let signedRuntime else {
                    throw FloorpWebExtensionCatalogError.revoked
                }
                try signedRuntime.authorizeInstalledCatalogRecord(record)
            },
            catalogRecordExpirationProvider: { record in
                guard let signedRuntime else {
                    throw FloorpWebExtensionCatalogError.revoked
                }
                return try signedRuntime.currentCatalogAuthorizationExpiry(for: record)
            }
        )
        let privateManager = FloorpWebExtensionLivePackageManager(
            store: privateStore,
            reconcile: { _, _, _ in },
            catalogItemsProvider: {
                signedRuntime?.catalogItems() ?? []
            },
            signedBundledCatalogInstaller: signedInstaller,
            catalogRecordAuthorization: { record in
                guard let signedRuntime else {
                    throw FloorpWebExtensionCatalogError.revoked
                }
                try signedRuntime.authorizeInstalledCatalogRecord(record)
            },
            catalogRecordExpirationProvider: { record in
                guard let signedRuntime else {
                    throw FloorpWebExtensionCatalogError.revoked
                }
                return try signedRuntime.currentCatalogAuthorizationExpiry(for: record)
            }
        )
        let wasEnabled = FloorpFlags.isWebExtensionFeatureEnabled(.bundledCatalog)
        FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: wasEnabled) }
        let runtime = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: catalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: signing.configuration.appBundleID,
            appVersion: signing.configuration.appVersion,
            catalogID: signing.configuration.catalogID,
            channel: signing.configuration.channel,
            stateStore: InMemoryCatalogStateStore(),
            artifactDataProvider: { _ in artifactData },
            clock: { signing.now },
            packageManagers: { [normalManager, privateManager] }
        )
        signedRuntime = runtime
        _ = try await runtime.acceptAndApplyRevocations(now: signing.now)
        let settings = FloorpWebExtensionProfileSettingsManager(
            normalManager: normalManager,
            privateManager: privateManager
        )
        let item = try XCTUnwrap(runtime.catalogItems().first)
        try await settings.installBundledPackage(item)
        let initialNormalPackage = await normalStore.installedPackage(for: signing.extensionID)
        let initialPrivatePackage = await privateStore.installedPackage(for: signing.extensionID)
        XCTAssertNotNil(initialNormalPackage)
        XCTAssertNil(initialPrivatePackage)

        try await settings.setPrivateBrowsingEnabled(true, for: signing.extensionID)
        let normalPackageRecord = await normalStore.installedPackage(for: signing.extensionID)
        let privatePackageRecord = await privateStore.installedPackage(for: signing.extensionID)
        let normalPackage = try XCTUnwrap(normalPackageRecord)
        let privatePackage = try XCTUnwrap(privatePackageRecord)
        XCTAssertFalse(normalPackage.grants.privateBrowsingEnabled)
        XCTAssertTrue(privatePackage.grants.privateBrowsingEnabled)
        XCTAssertEqual(normalPackage.grants.normalHostAccess, .denied)
        XCTAssertEqual(privatePackage.grants.privateHostAccess, .denied)

        try await settings.setPrivateSiteAccess(.allRequestedSites, for: signing.extensionID)
        let normalAfterPrivateGrantRecord = await normalStore.installedPackage(for: signing.extensionID)
        let privateAfterGrantRecord = await privateStore.installedPackage(for: signing.extensionID)
        let normalAfterPrivateGrant = try XCTUnwrap(normalAfterPrivateGrantRecord)
        let privateAfterGrant = try XCTUnwrap(privateAfterGrantRecord)
        XCTAssertEqual(normalAfterPrivateGrant.grants.normalHostAccess, .denied)
        XCTAssertEqual(privateAfterGrant.grants.privateHostAccess, .allRequestedSites)

        try await settings.setEnabled(false, for: signing.extensionID)
        let disabledNormalPackage = await normalStore.installedPackage(for: signing.extensionID)
        let disabledPrivatePackage = await privateStore.installedPackage(for: signing.extensionID)
        XCTAssertFalse(try XCTUnwrap(disabledNormalPackage).isEnabled)
        XCTAssertFalse(try XCTUnwrap(disabledPrivatePackage).isEnabled)
        try await settings.uninstall(signing.extensionID)
        let finalNormalPackage = await normalStore.installedPackage(for: signing.extensionID)
        let finalPrivatePackage = await privateStore.installedPackage(for: signing.extensionID)
        XCTAssertNil(finalNormalPackage)
        XCTAssertNil(finalPrivatePackage)
    }

    func testCatalogWithdrawalStopsTheCurrentGenerationAndRejectsRestartAuthorization() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        let artifactData = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: initial, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: artifactData)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-withdrawal",
            isPrivateBrowsing: false,
            directory: directory
        )
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, _, _ in }
        let stateStore = InMemoryCatalogStateStore()
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: stateStore,
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: manager)

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 2, availability: "withdrawn"),
            now: signing.now
        )
        let installedRecord = await store.installedPackage(for: record.extensionID)
        let installed = try XCTUnwrap(installedRecord)
        XCTAssertFalse(installed.isEnabled)
        XCTAssertTrue(installed.isCatalogRevoked)
        XCTAssertTrue(stateStore.state?.currentGenerationArtifacts.isEmpty == true)
        XCTAssertThrowsError(try coordinator.authorizeInstalledCatalogRecord(record)) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .revoked)
        }
    }

    func testCatalogOmissionStopsInstalledGenerationAndRetainsDataUntilExplicitUninstall() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        let artifactData = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: initial, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: artifactData)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-omission",
            isPrivateBrowsing: false,
            directory: directory
        )
        let ownedDataURL = directory.appendingPathComponent("extension-owned-data.marker")
        var reconciliationOperations = [FloorpWebExtensionLivePackageManager.ReconciliationOperation]()
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, _, operation in
            reconciliationOperations.append(operation)
            if operation == .uninstall {
                try FileManager.default.removeItem(at: ownedDataURL)
            }
        }
        let stateStore = InMemoryCatalogStateStore()
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: stateStore,
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: manager)
        try Data("retained until uninstall".utf8).write(to: ownedDataURL, options: .atomic)
        reconciliationOperations.removeAll()

        let installedBeforeOmissionRecord = await store.installedPackage(for: record.extensionID)
        let installedBeforeOmission = try XCTUnwrap(installedBeforeOmissionRecord)
        let generationDirectory = directory
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(record.extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(installedBeforeOmission.generation, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: generationDirectory.path))

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 2, includePackage: false),
            now: signing.now
        )

        let retainedPackageRecord = await store.installedPackage(for: record.extensionID)
        let retainedRecord = try XCTUnwrap(retainedPackageRecord)
        XCTAssertFalse(retainedRecord.isEnabled)
        XCTAssertTrue(retainedRecord.isCatalogRevoked)
        XCTAssertEqual(retainedRecord.catalogRecord, record)
        XCTAssertTrue(stateStore.state?.currentGenerationArtifacts.isEmpty == true)
        XCTAssertEqual(reconciliationOperations, [.suspend])
        XCTAssertTrue(FileManager.default.fileExists(atPath: generationDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedDataURL.path))
        let hasPendingPurgeAfterOmission = await store.hasPendingDataPurge(for: record.extensionID)
        XCTAssertFalse(hasPendingPurgeAfterOmission)
        XCTAssertThrowsError(try coordinator.authorizeInstalledCatalogRecord(record)) { error in
            XCTAssertEqual(error as? FloorpWebExtensionCatalogError, .revoked)
        }

        try await manager.uninstall(record.extensionID)

        let packageAfterUninstall = await store.installedPackage(for: record.extensionID)
        let hasPendingPurgeAfterUninstall = await store.hasPendingDataPurge(for: record.extensionID)
        XCTAssertNil(packageAfterUninstall)
        XCTAssertFalse(hasPendingPurgeAfterUninstall)
        XCTAssertFalse(FileManager.default.fileExists(atPath: generationDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedDataURL.path))
        XCTAssertEqual(reconciliationOperations, [.suspend, .suspend, .uninstall])
    }

    func testSamePermissionCatalogUpdateRequiresConsentAndRecordsHistory() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let firstCatalogData = try signing.catalog(sequence: 1)
        let firstCatalog = try verifier.verify(
            catalogData: firstCatalogData,
            previousState: nil,
            now: signing.now
        )
        let firstRecord = try XCTUnwrap(firstCatalog.catalog.packages.first)
        var updatedResources = signing.resources()
        updatedResources["manifest.json"] = Data("""
        {
          "manifest_version": 3,
          "name": "Catalog Content Script",
          "version": "1.0.1",
          "host_permissions": ["https://content-message.fixture.test/*"],
          "content_scripts": [{
            "matches": ["https://content-message.fixture.test/*"],
            "js": ["content/document-start.js"],
            "css": ["content/marker.css"],
            "run_at": "document_start",
            "world": "ISOLATED"
          }]
        }
        """.utf8)
        updatedResources["content/document-start.js"] = Data(
            "globalThis.floorpCatalogContentScript = 'generation-two';".utf8
        )
        let secondCatalogData = try signing.catalog(
            sequence: 2,
            generation: "catalog-gen-2",
            version: "1.0.1",
            resources: updatedResources
        )
        let secondCatalog = try verifier.verify(
            catalogData: secondCatalogData,
            previousState: firstCatalog.catalog.nextAcceptanceState,
            now: signing.now
        )
        let secondRecord = try XCTUnwrap(secondCatalog.catalog.packages.first)
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let firstArtifactData = try signing.archive()
        let firstArtifact = try await downloader.download(catalog: firstCatalog, record: firstRecord) { url in
            .init(finalURL: url, statusCode: 200, data: firstArtifactData)
        }
        let secondArtifactData = try signing.archive(resources: updatedResources)
        let secondArtifact = try await downloader.download(catalog: secondCatalog, record: secondRecord) { url in
            .init(finalURL: url, statusCode: 200, data: secondArtifactData)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-same-permission-update",
            isPrivateBrowsing: false,
            directory: directory
        )
        var didRequestConsent = false
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            catalogUpdateConfirmation: { _ in
                didRequestConsent = true
                return true
            }
        )
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: InMemoryCatalogStateStore(),
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: firstCatalogData,
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(firstArtifact, packageManager: manager)
        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: secondCatalogData,
            now: signing.now
        )
        let requiresConsent = try await store.catalogUpdateRequiresExplicitConsent(for: secondArtifact)
        XCTAssertTrue(requiresConsent)
        await assertAsyncThrows {
            try await coordinator.installVerifiedCatalogPackage(secondArtifact, packageManager: manager)
        }
        let authorization = try await manager.authorizeCatalogUpdate(for: secondArtifact)
        try await coordinator.installVerifiedCatalogPackage(
            secondArtifact,
            packageManager: manager,
            updateAuthorization: authorization
        )

        let installedRecord = await store.installedPackage(for: signing.extensionID)
        let installed = try XCTUnwrap(installedRecord)
        XCTAssertEqual(installed.generation, secondRecord.localGeneration)
        XCTAssertTrue(didRequestConsent)
        let history = await store.catalogUpdateHistory(for: signing.extensionID)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.previousCatalogGeneration, firstRecord.generation)
        XCTAssertEqual(history.first?.replacementCatalogGeneration, secondRecord.generation)
        XCTAssertEqual(history.first?.method, .userApproved)
        await assertAsyncThrows {
            _ = try await manager.authorizeCatalogUpdate(for: secondArtifact)
        }
        XCTAssertTrue(didRequestConsent)
    }

    func testSignedBundledCatalogRequiresConsentForSamePermissionUpdate() async throws {
        let signing = try CatalogSigningFixture()
        let firstCatalogData = try signing.catalog(sequence: 1, schemaVersion: 2)
        var updatedResources = signing.resources()
        updatedResources["manifest.json"] = Data("""
        {
          "manifest_version": 3,
          "name": "Catalog Content Script",
          "version": "1.0.1",
          "host_permissions": ["https://content-message.fixture.test/*"],
          "content_scripts": [{
            "matches": ["https://content-message.fixture.test/*"],
            "js": ["content/document-start.js"],
            "css": ["content/marker.css"],
            "run_at": "document_start",
            "world": "ISOLATED"
          }]
        }
        """.utf8)
        updatedResources["content/document-start.js"] = Data(
            "globalThis.floorpCatalogContentScript = 'confirmed-generation-two';".utf8
        )
        let secondCatalogData = try signing.catalog(
            sequence: 2,
            generation: "catalog-gen-2",
            version: "1.0.1",
            resources: updatedResources,
            schemaVersion: 2
        )
        let firstArchive = try signing.archive()
        let secondArchive = try signing.archive(resources: updatedResources)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-catalog-confirmed-update",
            isPrivateBrowsing: false,
            directory: directory
        )
        var didRequestConsent = false
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            catalogUpdateConfirmation: { _ in
                didRequestConsent = true
                return true
            }
        )
        let stateStore = InMemoryCatalogStateStore()
        FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: true)
        defer {
            FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: false)
        }

        let first = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: firstCatalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: "one.ablaze.floorp",
            appVersion: "0.3.0",
            catalogID: "floorp-production",
            channel: "production",
            stateStore: stateStore,
            artifactDataProvider: { _ in firstArchive },
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        _ = try await first.acceptAndApplyRevocations(now: signing.now)
        let firstItem = try XCTUnwrap(first.catalogItems().first)
        try await first.install(firstItem, packageManager: manager)

        let second = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: secondCatalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: "one.ablaze.floorp",
            appVersion: "0.3.0",
            catalogID: "floorp-production",
            channel: "production",
            stateStore: stateStore,
            artifactDataProvider: { _ in secondArchive },
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        _ = try await second.acceptAndApplyRevocations(now: signing.now)
        try await second.install(try XCTUnwrap(second.catalogItems().first), packageManager: manager)

        XCTAssertTrue(didRequestConsent)
        let installedRecord = await store.installedPackage(for: signing.extensionID)
        let installed = try XCTUnwrap(installedRecord)
        XCTAssertEqual(installed.catalogRecord?.generation, "catalog-gen-2")
        let history = await store.catalogUpdateHistory(for: signing.extensionID)
        XCTAssertEqual(history.last?.method, .userApproved)
    }

    // swiftlint:disable:next function_body_length
    func testSignedBundledCatalogRejectsOlderVersionBeforeConsent() async throws {
        let signing = try CatalogSigningFixture()
        var installedResources = signing.resources()
        installedResources["manifest.json"] = Data("""
        {
          "manifest_version": 3,
          "name": "Catalog Content Script",
          "version": "2.0.0",
          "host_permissions": ["https://content-message.fixture.test/*"],
          "content_scripts": [{
            "matches": ["https://content-message.fixture.test/*"],
            "js": ["content/document-start.js"],
            "css": ["content/marker.css"],
            "run_at": "document_start",
            "world": "ISOLATED"
          }]
        }
        """.utf8)
        let firstCatalogData = try signing.catalog(
            sequence: 1,
            generation: "catalog-gen-2",
            version: "2.0.0",
            resources: installedResources,
            schemaVersion: 2
        )
        // The later signed catalog sequence intentionally offers an older
        // immutable package. This must never become a rollback, even after an
        // explicit update gesture.
        let downgradeCatalogData = try signing.catalog(
            sequence: 2,
            generation: "catalog-gen-1",
            version: "1.0.0",
            schemaVersion: 2
        )
        let firstArchive = try signing.archive(resources: installedResources)
        let downgradeArchive = try signing.archive()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-catalog-confirmed-downgrade",
            isPrivateBrowsing: false,
            directory: directory
        )
        var didRequestConsent = false
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            catalogUpdateConfirmation: { _ in
                didRequestConsent = true
                return true
            }
        )
        let stateStore = InMemoryCatalogStateStore()
        FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: true)
        defer {
            FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: false)
        }

        let first = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: firstCatalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: "one.ablaze.floorp",
            appVersion: "0.3.0",
            catalogID: "floorp-production",
            channel: "production",
            stateStore: stateStore,
            artifactDataProvider: { _ in firstArchive },
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        _ = try await first.acceptAndApplyRevocations(now: signing.now)
        try await first.install(try XCTUnwrap(first.catalogItems().first), packageManager: manager)

        let downgrade = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: downgradeCatalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: "one.ablaze.floorp",
            appVersion: "0.3.0",
            catalogID: "floorp-production",
            channel: "production",
            stateStore: stateStore,
            artifactDataProvider: { _ in downgradeArchive },
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        _ = try await downgrade.acceptAndApplyRevocations(now: signing.now)
        let downgradeItem = try XCTUnwrap(downgrade.catalogItems().first)
        await assertAsyncThrows {
            try await downgrade.install(downgradeItem, packageManager: manager)
        }
        XCTAssertFalse(didRequestConsent)
        let installedRecord = await store.installedPackage(for: signing.extensionID)
        let installed = try XCTUnwrap(installedRecord)
        XCTAssertEqual(installed.catalogRecord?.generation, "catalog-gen-2")
        XCTAssertEqual(installed.version, "2.0.0")
        let history = await store.catalogUpdateHistory(for: signing.extensionID)
        XCTAssertTrue(history.isEmpty)
    }

    // swiftlint:disable:next function_body_length
    func testSignedBundledCatalogKeepsOldGenerationWhenUpdateConsentIsCancelled() async throws {
        let signing = try CatalogSigningFixture()
        let firstCatalogData = try signing.catalog(sequence: 1, schemaVersion: 2)
        var updatedResources = signing.resources()
        updatedResources["manifest.json"] = Data("""
        {
          "manifest_version": 3,
          "name": "Catalog Content Script",
          "version": "1.0.1",
          "permissions": ["storage"],
          "host_permissions": [
            "https://content-message.fixture.test/*",
            "https://automatic-expansion.fixture.test/*"
          ],
          "content_scripts": [{
            "matches": ["https://content-message.fixture.test/*"],
            "js": ["content/document-start.js"],
            "css": ["content/marker.css"],
            "run_at": "document_start",
            "world": "ISOLATED"
          }]
        }
        """.utf8)
        updatedResources["content/document-start.js"] = Data(
            "globalThis.floorpCatalogContentScript = 'cancelled-permission-expansion';".utf8
        )
        let secondCatalogData = try signing.catalog(
            sequence: 2,
            generation: "catalog-gen-2",
            version: "1.0.1",
            resources: updatedResources,
            compatibilityProfiles: ["content-script", "action-storage"],
            schemaVersion: 2,
            packageMetadata: signing.v2Metadata(
                permissions: ["storage"],
                hostPermissions: [
                    "https://content-message.fixture.test/*",
                    "https://automatic-expansion.fixture.test/*"
                ]
            )
        )
        let firstArchive = try signing.archive()
        let secondArchive = try signing.archive(resources: updatedResources)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-catalog-cancelled-permission-increase",
            isPrivateBrowsing: false,
            directory: directory
        )
        var didRequestConsent = false
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            catalogUpdateConfirmation: { _ in
                didRequestConsent = true
                return false
            }
        )
        let stateStore = InMemoryCatalogStateStore()
        FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: true)
        defer {
            FloorpFlags.setWebExtensionFeature(.bundledCatalog, enabled: false)
        }

        let first = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: firstCatalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: "one.ablaze.floorp",
            appVersion: "0.3.0",
            catalogID: "floorp-production",
            channel: "production",
            stateStore: stateStore,
            artifactDataProvider: { _ in firstArchive },
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        _ = try await first.acceptAndApplyRevocations(now: signing.now)
        try await first.install(try XCTUnwrap(first.catalogItems().first), packageManager: manager)

        let second = try FloorpWebExtensionSignedBundledCatalog(
            catalogData: secondCatalogData,
            rootPublicKey: signing.root.publicKey.rawRepresentation,
            appBundleID: "one.ablaze.floorp",
            appVersion: "0.3.0",
            catalogID: "floorp-production",
            channel: "production",
            stateStore: stateStore,
            artifactDataProvider: { _ in secondArchive },
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        _ = try await second.acceptAndApplyRevocations(now: signing.now)
        let secondItem = try XCTUnwrap(second.catalogItems().first)
        await assertAsyncThrows {
            try await second.install(secondItem, packageManager: manager)
        }

        XCTAssertTrue(didRequestConsent)
        let installedAfterCancelledPermissionIncrease = await store.installedPackage(
            for: signing.extensionID
        )
        XCTAssertEqual(
            installedAfterCancelledPermissionIncrease?.catalogRecord?.generation,
            "catalog-gen-1"
        )
        let history = await store.catalogUpdateHistory(for: signing.extensionID)
        XCTAssertTrue(history.isEmpty)
    }

    func testCatalogLifecycleSerializesConcurrentAcceptanceBeforeSavingState() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let initial = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let record = try XCTUnwrap(initial.catalog.packages.first)
        let archive = try signing.archive()
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let artifact = try await downloader.download(catalog: initial, record: record) { url in
            .init(finalURL: url, statusCode: 200, data: archive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "catalog-acceptance-serialization",
            isPrivateBrowsing: false,
            directory: directory
        )
        let reconciliation = PausedLifecycleReconciliation()
        let manager = FloorpWebExtensionLivePackageManager(store: store) { _, package, operation in
            XCTAssertEqual(operation, .suspend)
            await reconciliation.reconcile(package)
        }
        let stateStore = InMemoryCatalogStateStore()
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: stateStore,
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }

        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(artifact, packageManager: manager)
        let secondCatalog = try signing.catalog(
            sequence: 2,
            generation: "catalog-gen-2",
            revocations: [.object([
                "kind": .string("key"),
                "keyID": .string("catalog-2026-q3"),
                "effectiveAt": .string("2026-08-25T00:00:00Z")
            ])],
            signingKeyID: "catalog-2026-q4",
            signingKey: signing.replacementLeaf
        )
        let thirdCatalog = try signing.catalog(
            sequence: 3,
            generation: "catalog-gen-2",
            signingKeyID: "catalog-2026-q4",
            signingKey: signing.replacementLeaf
        )

        let secondAcceptance = Task { @MainActor in
            try await coordinator.acceptAndApplyRevocations(catalogData: secondCatalog, now: signing.now)
        }
        await reconciliation.waitUntilInitialRevocation()
        let thirdAcceptance = Task { @MainActor in
            try await coordinator.acceptAndApplyRevocations(catalogData: thirdCatalog, now: signing.now)
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(stateStore.state?.highestSequence, 1)

        await reconciliation.resumeInitialRevocation()
        _ = try await secondAcceptance.value
        let final = try await thirdAcceptance.value
        XCTAssertEqual(final.catalog.sequence, 3)
        XCTAssertEqual(stateStore.state?.highestSequence, 3)
        XCTAssertTrue(stateStore.state?.revokedKeyIDs.contains("catalog-2026-q3") == true)
    }

    // swiftlint:disable:next function_body_length
    func testCatalogUpdateRequiresDigestBoundExplicitConsent() async throws {
        let signing = try CatalogSigningFixture()
        let verifier = try FloorpWebExtensionCatalogVerifier(configuration: signing.configuration)
        let downloader = try FloorpWebExtensionArtifactDownloader(
            endpointPolicy: .init(allowedHosts: ["catalog.floorp.test"])
        )
        let firstCatalog = try verifier.verify(
            catalogData: signing.catalog(sequence: 1),
            previousState: nil,
            now: signing.now
        )
        let firstRecord = try XCTUnwrap(firstCatalog.catalog.packages.first)
        let firstArchive = try signing.archive()
        let firstArtifact = try await downloader.download(catalog: firstCatalog, record: firstRecord) { url in
            .init(finalURL: url, statusCode: 200, data: firstArchive)
        }
        var updatedResources = signing.resources()
        // This fixture exercises a required-authority expansion, which needs
        // a digest-bound native consent and must retain the old generation
        // until that consent succeeds.
        updatedResources["manifest.json"] = Data("""
        {
          "manifest_version": 3,
          "name": "Catalog Content Script",
          "version": "1.0.1",
          "permissions": ["storage"],
          "host_permissions": [
            "https://content-message.fixture.test/*",
            "https://expanded-permission.fixture.test/*"
          ],
          "content_scripts": [{
            "matches": ["https://content-message.fixture.test/*"],
            "js": ["content/document-start.js"],
            "css": ["content/marker.css"],
            "run_at": "document_start",
            "world": "ISOLATED"
          }]
        }
        """.utf8)
        updatedResources["content/document-start.js"] = Data(
            "globalThis.floorpCatalogContentScript = 'generation-2';".utf8
        )
        let secondCatalogData = try signing.catalog(
            sequence: 2,
            generation: "catalog-gen-2",
            version: "1.0.1",
            resources: updatedResources,
            compatibilityProfiles: ["content-script", "action-storage"]
        )
        let secondCatalog = try verifier.verify(
            catalogData: secondCatalogData,
            previousState: firstCatalog.catalog.nextAcceptanceState,
            now: signing.now
        )
        let secondRecord = try XCTUnwrap(secondCatalog.catalog.packages.first)
        let secondArchive = try signing.archive(resources: updatedResources)
        let secondArtifact = try await downloader.download(catalog: secondCatalog, record: secondRecord) { url in
            .init(finalURL: url, statusCode: 200, data: secondArchive)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: "signed-catalog-update-consent",
            isPrivateBrowsing: false,
            directory: directory
        )
        var confirmation: FloorpWebExtensionLivePackageManager.CatalogUpdateConfirmationRequest?
        let manager = FloorpWebExtensionLivePackageManager(
            store: store,
            reconcile: { _, _, _ in },
            catalogUpdateConfirmation: { request in
                confirmation = request
                return true
            }
        )
        let coordinator = FloorpWebExtensionCatalogLifecycleAcceptanceCoordinator(
            verifier: verifier,
            stateStore: InMemoryCatalogStateStore(),
            clock: { signing.now },
            packageManagers: { [manager] }
        )
        FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.managedRemoteSource, enabled: false) }
        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: signing.catalog(sequence: 1),
            now: signing.now
        )
        try await coordinator.installVerifiedCatalogPackage(firstArtifact, packageManager: manager)
        _ = try await coordinator.acceptAndApplyRevocations(
            catalogData: secondCatalogData,
            now: signing.now
        )

        await assertAsyncThrows {
            try await coordinator.installVerifiedCatalogPackage(secondArtifact, packageManager: manager)
        }
        let authorization = try await manager.authorizeCatalogUpdate(for: secondArtifact)
        XCTAssertEqual(confirmation?.installedGeneration, firstRecord.localGeneration)
        XCTAssertEqual(confirmation?.replacementCatalogGeneration, secondRecord.generation)
        XCTAssertEqual(confirmation?.replacementArtifactSHA256, secondRecord.artifactSHA256)
        XCTAssertEqual(confirmation?.addedRequiredAPIPermissions, [.storage])
        XCTAssertEqual(
            confirmation?.addedRequiredHostPermissions.map(\.original),
            ["https://expanded-permission.fixture.test/*"]
        )
        try await coordinator.installVerifiedCatalogPackage(
            secondArtifact,
            packageManager: manager,
            updateAuthorization: authorization
        )
        let installed = await store.installedPackage(for: secondRecord.extensionID)
        XCTAssertEqual(try XCTUnwrap(installed).generation, secondRecord.localGeneration)
        let history = await store.catalogUpdateHistory(for: secondRecord.extensionID)
        XCTAssertEqual(history.last?.method, .userApproved)
    }

    func testNativeOptionalPermissionConsentRequiresCurrentGenerationAndIsProfileScoped() async throws {
        let extensionID = FloorpWebExtensionID(rawValue: "floorp.permission-consent")!
        let origin = try FloorpWebExtensionMatchPattern("https://permissions.fixture.test/*")
        var shown: FloorpWebExtensionNativePermissionConsentPresenter.RequestPresentation?
        let presenter = FloorpWebExtensionNativePermissionConsentPresenter(
            isPrivateBrowsing: true,
            packageNameLookup: { id, generation in
                id == extensionID && generation == "generation-1" ? "Permission Fixture" : nil
            },
            confirmation: { presentation in
                shown = presentation
                return true
            }
        )
        let allowed = await presenter.authorize(.init(
            extensionID: extensionID,
            packageGeneration: "generation-1",
            apiPermissions: [.storage],
            origins: [origin]
        ))
        XCTAssertTrue(allowed)
        XCTAssertEqual(shown?.extensionName, "Permission Fixture")
        XCTAssertEqual(shown?.packageGeneration, "generation-1")
        XCTAssertEqual(shown?.origins, [origin])
        XCTAssertTrue(shown?.isPrivateBrowsing == true)
        XCTAssertTrue(shown?.message.contains("private browsing") == true)

        let stale = await presenter.authorize(.init(
            extensionID: extensionID,
            packageGeneration: "generation-2",
            apiPermissions: [.storage],
            origins: [origin]
        ))
        XCTAssertFalse(stale)
        let empty = await presenter.authorize(.init(
            extensionID: extensionID,
            packageGeneration: "generation-1",
            apiPermissions: [],
            origins: []
        ))
        XCTAssertFalse(empty)
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

    /// Builds a package-local, digest-pinned fixture with one optional API
    /// permission and one optional host. The source fixture remains immutable;
    /// this test-only copy proves package-store validation independently of
    /// catalog fixtures and their checked-in digest.
    private func optionalPermissionFixture() throws -> URL {
        let fixture = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: fixture.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: checkedInDemandingMV3FixtureDirectory(), to: fixture)

        let manifestURL = fixture.appendingPathComponent("manifest.json", isDirectory: false)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        let requiredPermissions = try XCTUnwrap(manifest["permissions"] as? [String])
            .filter { $0 != "activeTab" && $0 != "tabs" }
        manifest["permissions"] = requiredPermissions
        manifest["optional_permissions"] = ["tabs"]
        manifest["optional_host_permissions"] = ["https://*.optional.fixture.test/*"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(
            to: manifestURL,
            options: [.atomic]
        )

        let metadataURL = fixture.appendingPathComponent("fixture-metadata.json", isDirectory: false)
        var metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        var fixtureMetadata = try XCTUnwrap(metadata["fixture"] as? [String: Any])
        fixtureMetadata["packageSHA256"] = try fixtureDigest(in: fixture)
        metadata["fixture"] = fixtureMetadata
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(
            to: metadataURL,
            options: [.atomic]
        )
        return fixture
    }

    /// Produces a replacement whose manifest adds one required API and host.
    /// These declarations intentionally have no prior grant and therefore must
    /// not gain authority merely because package bytes were refreshed.
    private func permissionExpansionFixture() throws -> URL {
        let fixture = try optionalPermissionFixture()
        let manifestURL = fixture.appendingPathComponent("manifest.json", isDirectory: false)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        var permissions = try XCTUnwrap(manifest["permissions"] as? [String])
        permissions.append("activeTab")
        manifest["permissions"] = permissions
        var hosts = try XCTUnwrap(manifest["host_permissions"] as? [String])
        hosts.append("https://new-required.fixture.test/*")
        manifest["host_permissions"] = hosts
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(
            to: manifestURL,
            options: [.atomic]
        )

        let metadataURL = fixture.appendingPathComponent("fixture-metadata.json", isDirectory: false)
        var metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        var fixtureMetadata = try XCTUnwrap(metadata["fixture"] as? [String: Any])
        fixtureMetadata["packageSHA256"] = try fixtureDigest(in: fixture)
        metadata["fixture"] = fixtureMetadata
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(
            to: metadataURL,
            options: [.atomic]
        )
        return fixture
    }

    private func contentUpdatedPermissionFixture() throws -> URL {
        let fixture = try optionalPermissionFixture()
        let scriptURL = fixture.appendingPathComponent(
            "content/document-start.js",
            isDirectory: false
        )
        var script = try String(contentsOf: scriptURL, encoding: .utf8)
        script.append("\n// prepared-update-v2\n")
        try Data(script.utf8).write(to: scriptURL, options: [.atomic])

        let metadataURL = fixture.appendingPathComponent("fixture-metadata.json", isDirectory: false)
        var metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        var fixtureMetadata = try XCTUnwrap(metadata["fixture"] as? [String: Any])
        fixtureMetadata["packageSHA256"] = try fixtureDigest(in: fixture)
        metadata["fixture"] = fixtureMetadata
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(
            to: metadataURL,
            options: [.atomic]
        )
        return fixture
    }

    private func fixtureDigest(in directory: URL) throws -> String {
        let fileManager = FileManager.default
        let rootPath = directory.standardizedFileURL.path + "/"
        let enumerator = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        var resources = [String: Data]()
        var pendingDirectories = enumerator
        while let url = pendingDirectories.popLast() {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                let standardizedURL = url.standardizedFileURL
                guard standardizedURL.path.hasPrefix(rootPath) else {
                    throw NSError(domain: "FloorpWebExtensionPackageStoreTests", code: 2)
                }
                let path = String(standardizedURL.path.dropFirst(rootPath.count))
                resources[path] = try Data(contentsOf: standardizedURL)
            } else {
                let children = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: []
                )
                pendingDirectories.append(contentsOf: children)
            }
        }
        let packageData = resources.keys
            .filter { $0 != "fixture-metadata.json" }
            .sorted()
            .reduce(into: Data()) { data, path in
                data.append(path.data(using: .utf8)!)
                data.append(0)
                data.append(resources[path]!)
            }
        return SHA256.hash(data: packageData).map { String(format: "%02x", $0) }.joined()
    }

    private func committedGenerationDirectory(
        root: URL,
        installed: FloorpWebExtensionInstalledPackage
    ) -> URL {
        root.appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(installed.extensionID.rawValue, isDirectory: true)
            .appendingPathComponent(installed.generation, isDirectory: true)
    }

    private func writePersistentRegisteredScript(
        root: URL,
        profileIdentifier: String
    ) async throws {
        let store = try FloorpWebExtensionPackageStore(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: false,
            directory: root
        )
        let installed = try await store.installBundledPackage(
            at: checkedInDemandingMV3FixtureDirectory(),
            expectedExtensionID: extensionID
        )
        let script = FloorpWebExtensionRegisteredScript(
            id: "persistent-tamper-target",
            matches: [try .init("https://*.fixture.test/*")],
            javaScript: [try .init("content/document-start.js")],
            persistAcrossSessions: true
        )
        try await store.updatePersistentRegisteredScripts(
            [script],
            for: extensionID,
            expectedGeneration: installed.generation
        )
    }

    private func mutateFirstPersistentRegisteredScript(
        root: URL,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        let registryURL = root.appendingPathComponent("installed-packages.json")
        var registry = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        var packages = try XCTUnwrap(registry["packages"] as? [[String: Any]])
        var package = try XCTUnwrap(packages.first)
        var scripts = try XCTUnwrap(
            package["persistentRegisteredScripts"] as? [[String: Any]]
        )
        var script = try XCTUnwrap(scripts.first)
        try mutation(&script)
        scripts[0] = script
        package["persistentRegisteredScripts"] = scripts
        packages[0] = package
        registry["packages"] = packages
        try JSONSerialization.data(withJSONObject: registry, options: [.sortedKeys]).write(
            to: registryURL,
            options: [.atomic]
        )
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

    private static func allSubviews(in view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
    }

    private func settingsPackage(isEnabled: Bool) -> FloorpWebExtensionSettingsInstalledPackage {
        FloorpWebExtensionSettingsInstalledPackage(
            id: extensionID,
            name: "Fixture Extension",
            version: "1.0.0",
            catalogGeneration: nil,
            catalogDescription: "A reviewed extension used to verify Settings refresh behavior.",
            catalogSource: nil,
            catalogLicense: nil,
            catalogHomepage: nil,
            isEnabled: isEnabled,
            isCatalogRevoked: false,
            permissions: [],
            siteAccessDescription: "No sites allowed",
            requestedSites: [],
            normalHostAccess: .denied,
            privateHostAccess: .denied,
            isPrivateBrowsingEnabled: false,
            privateAccessDescription: "Not allowed",
            errorDescription: nil,
            optionsPage: nil,
            dnrStatus: nil,
            privateDNRStatus: nil,
            updateHistory: []
        )
    }
}

@MainActor
private struct CatalogSigningFixture {
    let root = Curve25519.Signing.PrivateKey()
    let leaf = Curve25519.Signing.PrivateKey()
    let replacementLeaf = Curve25519.Signing.PrivateKey()
    let configuration: FloorpWebExtensionCatalogTrustConfiguration
    let now: Date
    let extensionID = FloorpWebExtensionID(rawValue: "floorp.catalog.fixture")!

    init() throws {
        configuration = try .init(
            catalogID: "floorp-production",
            appBundleID: "one.ablaze.floorp",
            appVersion: "0.3.0",
            channel: "production",
            rootPublicKey: root.publicKey.rawRepresentation
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        now = try XCTUnwrap(formatter.date(from: "2026-08-26T12:00:00Z"))
    }

    func resources() -> [String: Data] {
        [
            "manifest.json": Data("""
            {
              "manifest_version": 3,
              "name": "Catalog Content Script",
              "version": "1.0.0",
              "host_permissions": ["https://content-message.fixture.test/*"],
              "content_scripts": [{
                "matches": ["https://content-message.fixture.test/*"],
                "js": ["content/document-start.js"],
                "css": ["content/marker.css"],
                "run_at": "document_start",
                "world": "ISOLATED"
              }]
            }
            """.utf8),
            "content/document-start.js": Data("globalThis.floorpCatalogContentScript = true;".utf8),
            "content/marker.css": Data(".floorp-catalog-marker { display: block; }".utf8)
        ]
    }

    func unsupportedDNRResources() -> [String: Data] {
        [
            "manifest.json": Data("""
            {
              "manifest_version": 3,
              "name": "Unsupported DNR",
              "version": "1.0.0",
              "permissions": ["declarativeNetRequest"],
              "declarative_net_request": {
                "rule_resources": [{
                  "id": "redirect-rules",
                  "enabled": true,
                  "path": "rules/static.json"
                }]
              }
            }
            """.utf8),
            "rules/static.json": Data("""
            [{
              "id": 1,
              "priority": 1,
              "action": {
                "type": "redirect",
                "redirect": {"url": "https://blocked.fixture.test/"}
              },
              "condition": {"urlFilter": "ads.fixture.test"}
            }]
            """.utf8)
        ]
    }

    func upgradeSchemeDNRResources() -> [String: Data] {
        [
            "manifest.json": Data("""
            {
              "manifest_version": 3,
              "name": "Upgrade Scheme DNR",
              "version": "1.0.0",
              "permissions": ["declarativeNetRequest"],
              "declarative_net_request": {
                "rule_resources": [{
                  "id": "upgrade-rules",
                  "enabled": true,
                  "path": "rules/static.json"
                }]
              }
            }
            """.utf8),
            "rules/static.json": Data("""
            [{
              "id": 1,
              "priority": 1,
              "action": {"type": "upgradeScheme"},
              "condition": {"urlFilter": "||tracker.fixture.test^"}
            }]
            """.utf8)
        ]
    }

    func archive(resources: [String: Data]? = nil) throws -> Data {
        try FloorpWebExtensionCatalogArchive.encodedArtifact(resources: resources ?? self.resources())
    }

    func catalog(
        sequence: Int64,
        generation: String = "catalog-gen-1",
        version: String = "1.0.0",
        expiresAt: String = "2026-09-01T00:00:00Z",
        resources: [String: Data]? = nil,
        compatibilityProfiles: [String] = ["content-script"],
        revocations: [FloorpWebExtensionCanonicalJSON.Value] = [],
        signingKeyID: String = "catalog-2026-q3",
        signingKey: Curve25519.Signing.PrivateKey? = nil,
        corruptCatalogSignature: Bool = false,
        schemaVersion: Int64 = 1,
        packageMetadata: FloorpWebExtensionCanonicalJSON.Value? = nil,
        availability: String = "available",
        includePackage: Bool = true
    ) throws -> Data {
        let signer = signingKey ?? leaf
        let packageResources = resources ?? self.resources()
        let artifact = try archive(resources: packageResources)
        var package: [String: FloorpWebExtensionCanonicalJSON.Value] = [
            "extensionID": .string(extensionID.rawValue),
            "generation": .string(generation),
            "version": .string(version),
            "artifactURL": .string("https://catalog.floorp.test/artifacts/\(generation).fwea"),
            "artifactBytes": .integer(Int64(artifact.count)),
            "artifactSHA256": .string(digest(artifact)),
            "manifestSHA256": .string(digest(try XCTUnwrap(packageResources["manifest.json"]))),
            "resourceInventorySHA256": .string(archiveInventoryDigest(artifact)),
            "compatibilityProfiles": .array(compatibilityProfiles.map { .string($0) }),
            "availability": .string(availability)
        ]
        if schemaVersion >= 2 {
            package["metadata"] = packageMetadata ?? (schemaVersion == 3 ? v3Metadata() : v2Metadata())
        }
        let packages: [FloorpWebExtensionCanonicalJSON.Value] = includePackage ? [.object(package)] : []
        let unsigned = FloorpWebExtensionCanonicalJSON.Value.object([
            "schemaVersion": .integer(schemaVersion),
            "catalogID": .string("floorp-production"),
            "sequence": .integer(sequence),
            "issuedAt": .string("2026-08-26T00:00:00Z"),
            "expiresAt": .string(expiresAt),
            "audience": .object([
                "bundleIDs": .array([.string("one.ablaze.floorp")]),
                "minimumAppVersion": .string("0.3.0"),
                "channel": .string("production")
            ]),
            "signingKey": try signingKeyCertificate(keyID: signingKeyID, publicKey: signer.publicKey),
            "packages": .array(packages),
            "revocations": .array(revocations)
        ])
        let signature = corruptCatalogSignature
            ? Data(repeating: 0, count: 64)
            : try signer.signature(for: FloorpWebExtensionCanonicalJSON.canonicalData(unsigned))
        guard case .object(var object) = unsigned else { fatalError("catalog must be an object") }
        object["signature"] = .string(base64URL(signature))
        return try FloorpWebExtensionCanonicalJSON.canonicalData(.object(object))
    }

    func v2Metadata(
        permissions: [String] = [],
        hostPermissions: [String] = ["https://content-message.fixture.test/*"],
        sourceURL: String = "https://github.com/Floorp-Projects/Floorp"
    ) -> FloorpWebExtensionCanonicalJSON.Value {
        .object([
            "displayName": .string("Catalog Content Script"),
            "description": .string("A reviewed catalog schema-v2 fixture."),
            "category": .string("productivity"),
            "upstream": .string("Floorp test fixture"),
            "upstreamRevision": .string("test-revision"),
            "originalArtifactSHA256": .string(String(repeating: "a", count: 64)),
            "sourceURL": .string(sourceURL),
            "license": .string("MPL-2.0"),
            "noticesSHA256": .string(String(repeating: "b", count: 64)),
            "permissions": .array(permissions.map { .string($0) }),
            "hostPermissions": .array(hostPermissions.map { .string($0) }),
            "privateProfileCapability": .string("opt-in"),
            "modificationStatus": .string("compatibility-patched"),
            "minimumFloorpBuild": .string("0.3.0")
        ])
    }

    func v3Metadata(
        disclosure: FloorpWebExtensionCanonicalJSON.Value? = nil,
        permissions: [String] = [],
        hostPermissions: [String] = ["https://content-message.fixture.test/*"],
        sourceURL: String = "https://github.com/Floorp-Projects/Floorp"
    ) -> FloorpWebExtensionCanonicalJSON.Value {
        guard case .object(var metadata) = v2Metadata(
            permissions: permissions,
            hostPermissions: hostPermissions,
            sourceURL: sourceURL
        ) else {
            fatalError("schema-v2 metadata must be an object")
        }
        metadata["disclosure"] = disclosure ?? v3Disclosure()
        return .object(metadata)
    }

    func v3Disclosure(
        reviewedAt: String = "2026-08-26T00:00:00Z",
        supportRoute: String = "floorp-github-issues",
        reportRoute: String = "floorp-github-bug-report"
    ) -> FloorpWebExtensionCanonicalJSON.Value {
        .object([
            "publisherDisplayName": .string("Floorp iOS"),
            "attribution": .string("Original project: Floorp test fixture."),
            "privacySummary": .string("Review requested sites and permissions before installation."),
            "retentionPolicy": .string("Settings stay in the selected profile until removal."),
            "reviewedAt": .string(reviewedAt),
            "reviewEvidenceSHA256": .string(String(repeating: "c", count: 64)),
            "sourceReviewSHA256": .string(String(repeating: "d", count: 64)),
            "supportRoute": .string(supportRoute),
            "reportRoute": .string(reportRoute)
        ])
    }

    func record(
        generation: String,
        artifact: Data,
        manifestDigest: String,
        inventoryDigest: String
    ) -> FloorpWebExtensionCatalogPackageRecord {
        .init(
            extensionID: extensionID,
            generation: generation,
            signingKeyID: "catalog-2026-q3",
            version: "1.0.0",
            artifactURL: URL(string: "https://catalog.floorp.test/artifacts/\(generation).fwea")!,
            artifactBytes: artifact.count,
            artifactSHA256: digest(artifact),
            manifestSHA256: manifestDigest,
            resourceInventorySHA256: inventoryDigest,
            compatibilityProfiles: ["content-script"],
            availability: .available
        )
    }

    func rawArchive(path: String, payload: Data) throws -> Data {
        let header = try FloorpWebExtensionCanonicalJSON.canonicalData(.object([
            "files": .array([.object([
                "path": .string(path),
                "sha256": .string(digest(payload)),
                "size": .integer(Int64(payload.count))
            ])])
        ]))
        var archive = Data([0x46, 0x57, 0x45, 0x41, 0x31, 0x0A])
        let length = UInt32(header.count)
        archive.append(UInt8((length >> 24) & 0xFF))
        archive.append(UInt8((length >> 16) & 0xFF))
        archive.append(UInt8((length >> 8) & 0xFF))
        archive.append(UInt8(length & 0xFF))
        archive.append(header)
        archive.append(payload)
        return archive
    }

    private func signingKeyCertificate(
        keyID: String,
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> FloorpWebExtensionCanonicalJSON.Value {
        let unsigned = FloorpWebExtensionCanonicalJSON.Value.object([
            "keyID": .string(keyID),
            "publicKey": .string(base64URL(publicKey.rawRepresentation)),
            "notBefore": .string("2026-08-01T00:00:00Z"),
            "notAfter": .string("2026-10-01T00:00:00Z")
        ])
        let signature = try root.signature(for: FloorpWebExtensionCanonicalJSON.canonicalData(unsigned))
        guard case .object(var object) = unsigned else { fatalError("certificate must be an object") }
        object["signature"] = .string(base64URL(signature))
        return .object(object)
    }

    private func archiveInventoryDigest(_ artifact: Data) -> String {
        let bytes = Array(artifact)
        let length = Int(bytes[6]) << 24 | Int(bytes[7]) << 16 | Int(bytes[8]) << 8 | Int(bytes[9])
        return digest(Data(bytes[10..<(10 + length)]))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct PersistentScriptAPIView: Decodable {
    let id: String
    let persistAcrossSessions: Bool
}

private final class InMemoryCatalogStateStore: FloorpWebExtensionCatalogAcceptanceStatePersisting, @unchecked Sendable {
    var state: FloorpWebExtensionCatalogAcceptanceState?

    func load(catalogID: String) throws -> FloorpWebExtensionCatalogAcceptanceState? {
        state
    }

    func save(_ state: FloorpWebExtensionCatalogAcceptanceState) throws {
        self.state = state
    }
}

@MainActor
private final class SignedCatalogRuntimeReference {
    var value: FloorpWebExtensionSignedBundledCatalog?

    func require() throws -> FloorpWebExtensionSignedBundledCatalog {
        guard let value else {
            throw FloorpWebExtensionCatalogError.revoked
        }
        return value
    }
}

private final class CatalogMutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}

/// Holds the Settings catalog request after the view has started refreshing so
/// the test can prove that no Stage 3 fixture row is visible before a signed
/// catalog result arrives.
@MainActor
private final class PausedCatalogSettingsManager: FloorpWebExtensionSettingsManaging {
    private let initialCatalog: [FloorpWebExtensionBundledCatalogItem]
    private let pauseOnRequest: Int
    private let allowsEnabledMutation: Bool
    private var packages: [FloorpWebExtensionSettingsInstalledPackage]
    private var requestCount = 0
    private var initialCatalogDelivered = false
    private var catalogRequested = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var initialCatalogWaiter: CheckedContinuation<Void, Never>?
    private var enabledMutationWaiter: CheckedContinuation<Void, Never>?
    private var catalogLoadContinuation: CheckedContinuation<[FloorpWebExtensionBundledCatalogItem], Never>?
    private var enabledMutationCompleted = false

    init(
        initialCatalog: [FloorpWebExtensionBundledCatalogItem] = [],
        initialPackages: [FloorpWebExtensionSettingsInstalledPackage] = [],
        pauseOnRequest: Int = 1,
        allowsEnabledMutation: Bool = false
    ) {
        self.initialCatalog = initialCatalog
        self.packages = initialPackages
        self.pauseOnRequest = pauseOnRequest
        self.allowsEnabledMutation = allowsEnabledMutation
    }

    func settingsPackages() async -> [FloorpWebExtensionSettingsInstalledPackage] { packages }

    func catalogItems() async -> [FloorpWebExtensionBundledCatalogItem] {
        requestCount += 1
        if requestCount != pauseOnRequest {
            initialCatalogDelivered = true
            initialCatalogWaiter?.resume()
            initialCatalogWaiter = nil
            return initialCatalog
        }
        catalogRequested = true
        requestWaiter?.resume()
        requestWaiter = nil
        return await withCheckedContinuation { continuation in
            catalogLoadContinuation = continuation
        }
    }

    func installBundledPackage(_ item: FloorpWebExtensionBundledCatalogItem) async throws {
        throw StubError.unexpectedMutation
    }

    func setNormalSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        throw StubError.unexpectedMutation
    }

    func setPrivateBrowsingEnabled(
        _ isEnabled: Bool,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        throw StubError.unexpectedMutation
    }

    func setPrivateSiteAccess(
        _ access: FloorpWebExtensionHostAccess,
        for extensionID: FloorpWebExtensionID
    ) async throws {
        throw StubError.unexpectedMutation
    }

    func setNormalDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        throw StubError.unexpectedMutation
    }

    func setPrivateDNRExcludedTopLevelDomains(
        _ domains: [String],
        for extensionID: FloorpWebExtensionID
    ) async throws {
        throw StubError.unexpectedMutation
    }

    func setEnabled(_ isEnabled: Bool, for extensionID: FloorpWebExtensionID) async throws {
        guard allowsEnabledMutation else { throw StubError.unexpectedMutation }
        enabledMutationCompleted = true
        enabledMutationWaiter?.resume()
        enabledMutationWaiter = nil
    }

    func uninstall(_ extensionID: FloorpWebExtensionID) async throws {
        throw StubError.unexpectedMutation
    }

    func waitUntilCatalogRequested() async {
        if catalogRequested { return }
        await withCheckedContinuation { continuation in
            requestWaiter = continuation
        }
    }

    func waitUntilInitialCatalogDelivered() async {
        if initialCatalogDelivered { return }
        await withCheckedContinuation { continuation in
            initialCatalogWaiter = continuation
        }
    }

    func waitUntilEnabledMutationCompleted() async {
        if enabledMutationCompleted { return }
        await withCheckedContinuation { continuation in
            enabledMutationWaiter = continuation
        }
    }

    func resumeCatalogLoad() {
        catalogLoadContinuation?.resume(returning: initialCatalog)
        catalogLoadContinuation = nil
    }

    func replacePackages(with packages: [FloorpWebExtensionSettingsInstalledPackage]) {
        self.packages = packages
    }

    private enum StubError: Error {
        case unexpectedMutation
    }
}

/// Holds the first live-state revocation in a reload so a competing lifecycle
/// mutation can prove it queues behind the manager's per-extension gate.
@MainActor
private final class PausedLifecycleReconciliation {
    private var didPauseInitialRevocation = false
    private var initialRevocationStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    private(set) var states = [Bool]()

    func reconcile(_ package: FloorpWebExtensionInstalledPackage?) async {
        states.append(package != nil)
        guard !didPauseInitialRevocation, package == nil else { return }

        didPauseInitialRevocation = true
        initialRevocationStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilInitialRevocation() async {
        if initialRevocationStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func resumeInitialRevocation() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

/// Pauses the package-bearing startup reconciliation so a concurrent disable
/// can prove it queues behind the same per-extension lifecycle gate.
@MainActor
private final class PausedPackageRestoreReconciliation {
    private var restoreStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    private(set) var states = [Bool]()

    func reconcile(_ package: FloorpWebExtensionInstalledPackage?) async {
        states.append(package != nil)
        guard package != nil, !restoreStarted else { return }
        restoreStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilRestoreStarted() async {
        if restoreStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func resumeRestore() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private final class RegistryWriteFailureInjector: @unchecked Sendable {
    enum Failure: Error {
        case expected
    }

    var shouldFail = false

    func persist(_ data: Data, to url: URL) throws {
        if shouldFail {
            throw Failure.expected
        }
        try data.write(to: url, options: [.atomic])
    }
}

/// Blocks exactly one synchronous package-registry write without blocking the
/// main actor. This exposes coordinator reentrancy around its actor hop and
/// lets the test prove a second script mutation waits behind the first.
private final class PausedRegistryPersister: @unchecked Sendable {
    private let lock = NSLock()
    private let resumeSemaphore = DispatchSemaphore(value: 0)
    private var pausesNextWrite = false
    private var writeIsPaused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?

    func pauseNextWrite() {
        lock.lock()
        pausesNextWrite = true
        lock.unlock()
    }

    func waitUntilWriteIsPaused() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if writeIsPaused {
                lock.unlock()
                continuation.resume()
            } else {
                pauseWaiter = continuation
                lock.unlock()
            }
        }
    }

    func resumeWrite() {
        resumeSemaphore.signal()
    }

    func persist(_ data: Data, to url: URL) throws {
        lock.lock()
        let shouldPause = pausesNextWrite
        pausesNextWrite = false
        if shouldPause {
            writeIsPaused = true
        }
        let waiter = shouldPause ? pauseWaiter : nil
        if shouldPause {
            pauseWaiter = nil
        }
        lock.unlock()

        if shouldPause {
            waiter?.resume()
            resumeSemaphore.wait()
        }
        try data.write(to: url, options: [.atomic])
    }
}

@MainActor
private final class PackageStoreRuleListCompiler: FloorpWebExtensionContentRuleListCompiling {
    enum Failure: Error {
        case expected
    }

    var shouldFail = false
    var failOnCompilationAttempt: Int?
    private var compilationAttemptCount = 0
    private let store: WKContentRuleListStore

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-webextension-package-store-dnr-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // swiftlint:disable:next force_try
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)!
    }

    func compileContentRuleList(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList {
        compilationAttemptCount += 1
        if shouldFail {
            throw Failure.expected
        }
        if compilationAttemptCount == failOnCompilationAttempt {
            throw Failure.expected
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedContentRuleList
            ) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: RegistryWriteFailureInjector.Failure.expected)
                }
            }
        }
    }

    func removeContentRuleList(forIdentifier identifier: String) async {
        await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}
