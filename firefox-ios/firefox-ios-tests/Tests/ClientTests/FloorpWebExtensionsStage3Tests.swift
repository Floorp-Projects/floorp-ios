// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@preconcurrency import GCDWebServers
import WebKit
@testable import Client

final class FloorpWebExtensionsStage3Tests: XCTestCase, @unchecked Sendable {
    private let extensionID = FloorpWebExtensionID(rawValue: "stage3-fixture")!
    private let otherExtensionID = FloorpWebExtensionID(rawValue: "stage3-other")!

    func testRegisterUpdateAndUnregisterAreAtomic() async throws {
        let registry = FloorpWebExtensionScriptRegistry()
        let original = try script(id: "original", source: "original.js")
        try await registry.register([original], for: extensionID)

        let duplicate = try script(id: "original", source: "replacement.js")
        await assertAsyncThrows {
            try await registry.register([try self.script(id: "new", source: "new.js"), duplicate], for: self.extensionID)
        }
        let afterFailedRegister = await registry.registeredScripts(for: extensionID)
        XCTAssertEqual(afterFailedRegister, [original])

        let invalidUpdate = FloorpWebExtensionRegisteredScriptUpdate(id: "original", javaScript: [])
        await assertAsyncThrows {
            try await registry.update([invalidUpdate], for: self.extensionID)
        }
        let afterFailedUpdate = await registry.registeredScripts(for: extensionID)
        XCTAssertEqual(afterFailedUpdate, [original])

        await assertAsyncThrows {
            try await registry.unregister(["original", "missing"], for: self.extensionID)
        }
        let afterFailedUnregister = await registry.registeredScripts(for: extensionID)
        XCTAssertEqual(afterFailedUnregister, [original])

        try await registry.update([.init(id: "original", runAt: .documentStart, allFrames: true)], for: extensionID)
        let updatedScripts = await registry.registeredScripts(for: extensionID)
        let updated = try XCTUnwrap(updatedScripts.first)
        XCTAssertEqual(updated.runAt, .documentStart)
        XCTAssertTrue(updated.allFrames)

        try await registry.unregister(["original"], for: extensionID)
        let remainingScripts = await registry.registeredScripts(for: extensionID)
        XCTAssertTrue(remainingScripts.isEmpty)
    }

    func testPlanIsOrderedAndPreservesWorldFrameAndMatchingRules() async throws {
        let registry = FloorpWebExtensionScriptRegistry()
        let excluded = try FloorpWebExtensionMatchPattern("https://allowed.example/private/*")
        let first = try script(
            id: "first",
            source: "first.js",
            excludes: [excluded],
            runAt: .documentStart,
            allFrames: true,
            world: .isolated
        )
        let main = try script(
            id: "main",
            source: "main.js",
            runAt: .documentIdle,
            allFrames: false,
            world: .main
        )
        try await registry.register([first, main], for: extensionID)
        try await registry.register([try script(id: "other", source: "other.js")], for: otherExtensionID)

        let tab = FloorpWebExtensionTabContext(
            tabID: 1,
            documentGeneration: 8,
            url: try XCTUnwrap(URL(string: "https://allowed.example/path"))
        )
        let plan = await registry.plan(for: tab, allowedExtensionIDs: [extensionID, otherExtensionID])
        XCTAssertEqual(plan.map(\.script.id), ["first", "main", "other"])
        XCTAssertEqual(plan[0].script.runAt, .documentStart)
        XCTAssertTrue(plan[0].script.allFrames)
        XCTAssertTrue(plan[0].requiresNativeBridge)
        XCTAssertFalse(plan[0].forMainFrameOnly)
        XCTAssertTrue(plan[0].applies(toMainFrame: false))
        XCTAssertEqual(plan[1].script.runAt, .documentIdle)
        XCTAssertEqual(plan[1].script.world, .main)
        XCTAssertFalse(plan[1].requiresNativeBridge)
        XCTAssertTrue(plan[1].forMainFrameOnly)
        XCTAssertFalse(plan[1].applies(toMainFrame: false))

        let excludedTab = FloorpWebExtensionTabContext(
            tabID: 1,
            documentGeneration: 9,
            url: try XCTUnwrap(URL(string: "https://allowed.example/private/page"))
        )
        let excludedPlan = await registry.plan(for: excludedTab, allowedExtensionIDs: [extensionID])
        XCTAssertEqual(excludedPlan.map(\.script.id), ["main"])
    }

    func testPermissionAwarePlanRequiresScriptingAndHostGrant() async throws {
        let registry = FloorpWebExtensionScriptRegistry()
        try await registry.register([try script(id: "script", source: "content.js")], for: extensionID)
        let broker = FloorpWebExtensionPermissionBroker()
        let match = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        let tab = FloorpWebExtensionTabContext(
            tabID: 1,
            documentGeneration: 1,
            url: try XCTUnwrap(URL(string: "https://allowed.example/path"))
        )

        let deniedPlan = await registry.plan(for: tab, permissionBroker: broker)
        XCTAssertTrue(deniedPlan.isEmpty)
        await broker.grant([.scripting], requestedHosts: [match], hostAccess: .allRequestedSites, to: extensionID)
        let grantedPlan = await registry.plan(for: tab, permissionBroker: broker)
        XCTAssertEqual(grantedPlan.map(\.script.id), ["script"])
    }

    func testCSSHandlesAreOwnerScopedAndBatchRemovalIsAtomic() async throws {
        let suffixes = HandleSuffixes(["one", "two"])
        let registry = await FloorpWebExtensionCSSRegistry(nextHandleSuffix: { suffixes.next() })
        let tab = FloorpWebExtensionTabContext(
            tabID: 2,
            documentGeneration: 4,
            url: try XCTUnwrap(URL(string: "https://allowed.example/path"))
        )
        let firstTarget = FloorpWebExtensionCSSTarget(tab: tab)
        let broker = FloorpWebExtensionPermissionBroker()
        await assertAsyncThrows {
            try await registry.insert(
                css: ".first { color: red; }",
                for: self.extensionID,
                target: firstTarget,
                tab: tab,
                permissionBroker: broker
            )
        }
        let host = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        await broker.grant([.scripting], requestedHosts: [host], hostAccess: .allRequestedSites, to: extensionID)
        let first = try await registry.insert(
            css: ".first { color: red; }",
            for: extensionID,
            target: firstTarget,
            tab: tab,
            permissionBroker: broker
        )
        let second = try await registry.insert(
            css: ".second { color: blue; }",
            for: extensionID,
            target: .init(tab: tab, frameID: 99)
        )

        await assertAsyncThrows {
            try await registry.remove([first.handle], for: self.otherExtensionID, target: first.target)
        }
        let afterWrongOwner = await registry.activeInsertions(for: extensionID)
        XCTAssertEqual(afterWrongOwner.count, 2)
        await assertAsyncThrows {
            try await registry.remove([first.handle, first.handle], for: self.extensionID, target: first.target)
        }
        let afterDuplicateHandle = await registry.activeInsertions(for: extensionID)
        XCTAssertEqual(afterDuplicateHandle.count, 2)

        let removed = try await registry.remove([first.handle], for: extensionID, target: first.target)
        XCTAssertEqual(removed.map(\.handle), [first.handle])
        let remainingAfterFirstRemoval = await registry.activeInsertions(for: extensionID)
        XCTAssertEqual(remainingAfterFirstRemoval.map(\.handle), [second.handle])
        let staleTarget = FloorpWebExtensionCSSTarget(
            tab: FloorpWebExtensionTabContext(
                tabID: tab.tabID,
                documentGeneration: tab.documentGeneration + 1,
                url: tab.url
            ),
            frameID: second.target.frameID
        )
        await assertAsyncThrows {
            try await registry.remove([second.handle], for: self.extensionID, target: staleTarget)
        }
        _ = try await registry.remove([second.handle], for: extensionID, target: second.target)
        let remainingInsertions = await registry.activeInsertions(for: extensionID)
        XCTAssertTrue(remainingInsertions.isEmpty)
    }

    func testCSSDiscardExtensionReleasesQuotaWithoutTouchingOtherOwners() async throws {
        let registry = await FloorpWebExtensionCSSRegistry()
        let target = FloorpWebExtensionCSSTarget(
            tab: .init(
                tabID: 22,
                documentGeneration: 7,
                url: try XCTUnwrap(URL(string: "https://allowed.example/quota"))
            )
        )
        _ = try await registry.insert(
            css: ".other { color: blue; }",
            for: otherExtensionID,
            target: target
        )
        for index in 0..<FloorpWebExtensionCSSRegistry.maximumInsertionsPerExtension {
            _ = try await registry.insert(
                css: ".fixture-\(index) { color: red; }",
                for: extensionID,
                target: target
            )
        }
        await assertAsyncThrows {
            try await registry.insert(
                css: ".over-quota { color: black; }",
                for: self.extensionID,
                target: target
            )
        }

        await registry.discardInsertions(for: extensionID)

        let discardedOwnerInsertions = await registry.activeInsertions(for: extensionID)
        let retainedOtherOwnerInsertions = await registry.activeInsertions(for: otherExtensionID)
        XCTAssertTrue(discardedOwnerInsertions.isEmpty)
        XCTAssertEqual(retainedOtherOwnerInsertions.count, 1)
        _ = try await registry.insert(
            css: ".after-reactivation { color: green; }",
            for: extensionID,
            target: target
        )
        let reactivatedOwnerInsertions = await registry.activeInsertions(for: extensionID)
        XCTAssertEqual(reactivatedOwnerInsertions.count, 1)
    }

    func testCosmeticBuilderBoundsInputsAndDoesNotBridgeMainWorld() throws {
        let match = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        let filter = FloorpWebExtensionCosmeticFilter(
            matches: [match],
            selectors: [".advertisement", "[data-ad]"],
            proceduralFilters: [.init(selector: "article", operations: [.hasText("sponsored")])],
            scriptlets: [.init(name: .setConstant, arguments: ["adEnabled", "false"])],
            world: .main
        )
        let resource = try FloorpWebExtensionCosmeticFilterBuilder.build(filter)
        XCTAssertEqual(resource.css, ".advertisement { display: none !important; }\n[data-ad] { display: none !important; }")
        XCTAssertNotNil(resource.javaScript)
        XCTAssertFalse(resource.requiresNativeBridge)
        XCTAssertFalse(resource.javaScript!.contains("sponsored"))

        let unsafe = FloorpWebExtensionCosmeticFilter(matches: [match], selectors: [".ad { color: red }"])
        XCTAssertThrowsError(try FloorpWebExtensionCosmeticFilterBuilder.build(unsafe))
    }

    @MainActor
    func testDeclaredCosmeticResourceIsBoundedGrantCheckedAndMainFrameOnly() async throws {
        let resourceData = Data("""
        {
          "schema_version": 1,
          "filters": [{
            "matches": ["https://allowed.example/*"],
            "exclude_matches": ["https://allowed.example/excluded/*"],
            "selectors": [".advertisement"],
            "procedural": [{
              "selector": "article",
              "operations": [{ "kind": "has-text", "value": "sponsored" }],
              "action": "remove"
            }],
            "scriptlets": [{ "name": "set-constant", "arguments": ["adEnabled", "false"] }],
            "run_at": "document_start",
            "world": "MAIN"
          }]
        }
        """.utf8)
        let resources = try FloorpWebExtensionCosmeticFilterPackageDecoder.decode(resourceData)
        let cosmeticResource = try XCTUnwrap(resources.first)
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(cosmeticResource.runAt, .documentStart)
        XCTAssertEqual(cosmeticResource.resource.world, .main)
        XCTAssertFalse(cosmeticResource.resource.requiresNativeBridge)
        XCTAssertTrue(cosmeticResource.resource.javaScript?.contains("sponsored") == false)
        let cssPolicySource = try FloorpWebExtensionCoordinator.styleInjectionSource(
            try XCTUnwrap(cosmeticResource.resource.css)
        )
        let expectedGeneratedBytes = cssPolicySource.lengthOfBytes(using: .utf8) +
            (cosmeticResource.resource.javaScript?.lengthOfBytes(using: .utf8) ?? 0)
        XCTAssertEqual(cosmeticResource.generatedByteCount, expectedGeneratedBytes)

        let match = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "cosmetic-package-resource",
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: FailingContentRuleListCompiler()),
            scriptResourceLoader: { _, _ in
                throw FloorpWebExtensionError.unsupported("not used by generated cosmetic resource")
            }
        )
        await coordinator.grantPermissions(
            [.scripting],
            requestedHosts: [match],
            hostAccess: .selectedSites([match]),
            to: extensionID
        )
        try coordinator.restoreCosmeticResources(resources, for: extensionID)

        let allowedTab = FloorpWebExtensionTabContext(
            tabID: 1,
            documentGeneration: 1,
            url: try XCTUnwrap(URL(string: "https://allowed.example/path"))
        )
        let allowedPolicies = try XCTUnwrap(
            coordinator.preNavigationPolicies(for: allowedTab).first?.scriptPolicies
        )
        XCTAssertEqual(allowedPolicies.count, 2)
        XCTAssertTrue(allowedPolicies.allSatisfy { $0.world == .main })
        XCTAssertTrue(allowedPolicies.allSatisfy { policy in
            guard !policy.allFrames else { return false }
            if case nil = policy.frameAuthorization { return true }
            return false
        })

        let excludedTab = FloorpWebExtensionTabContext(
            tabID: 1,
            documentGeneration: 2,
            url: try XCTUnwrap(URL(string: "https://allowed.example/excluded/page"))
        )
        XCTAssertTrue(coordinator.preNavigationPolicies(for: excludedTab).isEmpty)

        await coordinator.setHostAccess(.denied, privateAccess: false, for: extensionID)
        XCTAssertTrue(coordinator.preNavigationPolicies(for: allowedTab).isEmpty)
        try coordinator.restoreCosmeticResources([], for: extensionID)
    }

    func testDeclaredCosmeticResourceRejectsUnknownKeysAndNoopScriptlets() throws {
        let unknownKey = Data("""
        { "schema_version": 1, "filters": [], "unexpected": true }
        """.utf8)
        XCTAssertThrowsError(try FloorpWebExtensionCosmeticFilterPackageDecoder.decode(unknownKey))

        let noOpScriptlet = Data("""
        {
          "schema_version": 1,
          "filters": [{
            "matches": ["https://allowed.example/*"],
            "scriptlets": [{ "name": "set-constant", "arguments": ["onlyProperty"] }]
          }]
        }
        """.utf8)
        XCTAssertThrowsError(try FloorpWebExtensionCosmeticFilterPackageDecoder.decode(noOpScriptlet))
    }

    func testManifestPreflightAdmitsOnlyInventoriedBoundedCosmeticResources() throws {
        let manifestData = Data("""
        {
          "manifest_version": 3,
          "name": "Cosmetic Package Fixture",
          "version": "1.0.0",
          "permissions": ["scripting"],
          "host_permissions": ["https://allowed.example/*"],
          "floorp_cosmetic_filter_resources": ["filters/cosmetic.json"]
        }
        """.utf8)
        let cosmeticData = Data("""
        {
          "schema_version": 1,
          "filters": [{
            "matches": ["https://allowed.example/*"],
            "selectors": [".advertisement"]
          }]
        }
        """.utf8)
        let inventory = FloorpWebExtensionManifestPackageInventory(resources: [
            .init(path: "manifest.json", isRegularFile: true, byteSize: manifestData.count),
            .init(path: "filters/cosmetic.json", isRegularFile: true, byteSize: cosmeticData.count)
        ])
        let report = try FloorpWebExtensionManifest.preflight(
            manifestData: manifestData,
            packageInventory: inventory,
            ruleResourceData: ["filters/cosmetic.json": cosmeticData]
        )
        XCTAssertTrue(report.isActivationAllowed)
        XCTAssertEqual(report.manifest.cosmeticFilterResources.map(\.path.path), ["filters/cosmetic.json"])

        let missingResourceReport = try FloorpWebExtensionManifest.preflight(
            manifestData: manifestData,
            packageInventory: .init(resources: [
                .init(path: "manifest.json", isRegularFile: true, byteSize: manifestData.count)
            ]),
            ruleResourceData: ["filters/cosmetic.json": cosmeticData]
        )
        XCTAssertFalse(missingResourceReport.isActivationAllowed)
    }

    func testDeclaredCosmeticResourcesRejectAggregateSelectorBudgetExhaustion() throws {
        let selectors = (0 ..< 1_000).map { ".ad-\($0)" }
        let withinBudgetFilters: [[String: Any]] = [
            ["matches": ["https://allowed.example/*"], "selectors": selectors],
            ["matches": ["https://allowed.example/*"], "selectors": selectors]
        ]
        let withinBudgetData = try JSONSerialization.data(
            withJSONObject: ["schema_version": 1, "filters": withinBudgetFilters],
            options: [.sortedKeys]
        )
        XCTAssertEqual(
            try FloorpWebExtensionCosmeticFilterPackageDecoder.decodePackage([withinBudgetData]).count,
            2
        )
        let filters: [[String: Any]] = [
            withinBudgetFilters[0],
            withinBudgetFilters[1],
            ["matches": ["https://allowed.example/*"], "selectors": [".one-too-many"]]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: ["schema_version": 1, "filters": filters],
            options: [.sortedKeys]
        )

        // Each filter and its resource are within their individual bounds.
        let individuallyDecoded = try FloorpWebExtensionCosmeticFilterPackageDecoder.decode(data)
        XCTAssertEqual(individuallyDecoded.count, 3)
        // A package must nevertheless have one aggregate budget; otherwise
        // multiple valid filters can schedule an unbounded number of DOM scans.
        XCTAssertThrowsError(
            try FloorpWebExtensionCosmeticFilterPackageDecoder.decodePackage([data])
        )

        let manifestData = Data("""
        {
          "manifest_version": 3,
          "name": "Aggregate Cosmetic Quota Fixture",
          "version": "1.0.0",
          "permissions": ["scripting"],
          "host_permissions": ["https://allowed.example/*"],
          "floorp_cosmetic_filter_resources": ["filters/cosmetic.json"]
        }
        """.utf8)
        let report = try FloorpWebExtensionManifest.preflight(
            manifestData: manifestData,
            packageInventory: .init(resources: [
                .init(path: "manifest.json", isRegularFile: true, byteSize: manifestData.count),
                .init(path: "filters/cosmetic.json", isRegularFile: true, byteSize: data.count)
            ]),
            ruleResourceData: ["filters/cosmetic.json": data]
        )
        XCTAssertFalse(report.isActivationAllowed)

        let singleResourceData = Data("""
        {
          "schema_version": 1,
          "filters": [{
            "matches": ["https://allowed.example/*"],
            "selectors": [".ad"]
          }]
        }
        """.utf8)
        XCTAssertEqual(
            try FloorpWebExtensionCosmeticFilterPackageDecoder.decodePackage(
                Array(repeating: singleResourceData, count: 32)
            ).count,
            32
        )
        XCTAssertThrowsError(
            try FloorpWebExtensionCosmeticFilterPackageDecoder.decodePackage(
                Array(repeating: singleResourceData, count: 33)
            )
        )
    }

    @MainActor
    func testRuntimeAppliesUpdatesAndRemovesPoliciesByExtensionOwnerBeforeNavigation() {
        let priorCoreFlag = FloorpFlags.isWebExtensionFeatureEnabled(.core)
        FloorpFlags.setWebExtensionFeature(.core, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.core, enabled: priorCoreFlag) }

        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: FailingContentRuleListCompiler())
        let controller = WKUserContentController()
        runtime.setScriptPolicies([scriptPolicy("window.stage3First = 1;")], for: extensionID)
        runtime.setScriptPolicies([scriptPolicy("window.stage3Second = 1;")], for: otherExtensionID)

        // `apply` is the pre-navigation handoff used by Tab.createWebview.
        runtime.apply(to: controller)
        XCTAssertEqual(
            controller.userScripts.map(\.source),
            ["window.stage3First = 1;", "window.stage3Second = 1;"]
        )

        runtime.setScriptPolicies([
            scriptPolicy("window.stage3First = 2;", world: .main)
        ], for: extensionID)
        XCTAssertEqual(
            controller.userScripts.map(\.source),
            ["window.stage3First = 2;", "window.stage3Second = 1;"]
        )

        runtime.removePolicies(for: extensionID)
        XCTAssertEqual(controller.userScripts.map(\.source), ["window.stage3Second = 1;"])
        XCTAssertNil(runtime.policySnapshot(for: extensionID))
        XCTAssertEqual(runtime.policySnapshot(for: otherExtensionID)?.userScriptCount, 1)
    }

    @MainActor
    func testRuntimeClearsOnlyExtensionPoliciesWhenCoreFeatureIsDisabled() async {
        let priorCoreFlag = FloorpFlags.isWebExtensionFeatureEnabled(.core)
        FloorpFlags.setWebExtensionFeature(.core, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.core, enabled: priorCoreFlag) }

        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: FailingContentRuleListCompiler())
        let profileIdentifier = "stage3-feature-\(UUID().uuidString)"
        FloorpWebExtensionRuntime.install(
            runtime,
            for: profileIdentifier,
            isPrivateBrowsing: false
        )
        defer {
            FloorpWebExtensionRuntime.removeRuntime(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
        }
        let controller = WKUserContentController()
        let browserScript = WKUserScript(
            source: "window.firefoxBrowser = 1;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        FloorpWebContentPolicyCoordinator.coordinator(for: controller)
            .replaceUserScripts([browserScript], ownedBy: "firefox.browser")
        runtime.setScriptPolicies([scriptPolicy("window.stage3Extension = 1;")], for: extensionID)
        runtime.apply(to: controller)
        XCTAssertEqual(
            controller.userScripts.map(\.source),
            ["window.firefoxBrowser = 1;", "window.stage3Extension = 1;"]
        )

        FloorpFlags.setWebExtensionFeature(.core, enabled: false)
        await Task.yield()

        XCTAssertEqual(controller.userScripts.map(\.source), ["window.firefoxBrowser = 1;"])
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.userScriptCount, 1)
    }

    @MainActor
    func testRuntimeRegistrySeparatesNormalAndPrivateBrowsingPolicies() {
        let profileIdentifier = "stage3-profile-\(UUID().uuidString)"
        defer {
            FloorpWebExtensionRuntime.removeRuntime(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
            FloorpWebExtensionRuntime.removeRuntime(
                for: profileIdentifier,
                isPrivateBrowsing: true
            )
        }

        let normalRuntime = FloorpWebExtensionRuntime.runtime(
            for: profileIdentifier,
            isPrivateBrowsing: false
        )
        let privateRuntime = FloorpWebExtensionRuntime.runtime(
            for: profileIdentifier,
            isPrivateBrowsing: true
        )

        XCTAssertFalse(normalRuntime === privateRuntime)
        XCTAssertEqual(
            FloorpWebExtensionRuntime.isolatedContentWorldName(for: extensionID),
            "floorp.webextension.content.stage3-fixture"
        )
    }

    @MainActor
    func testRuntimePassesDNRCompilationToInjectedProfileStoreAndFailsClosed() async {
        let compiler = FailingContentRuleListCompiler()
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: compiler)
        let compilation = FloorpWebExtensionDNRCompilation(
            generation: 7,
            webKitContentRuleJSON: validBlockRuleJSON("failure.example"),
            compiledRules: [],
            report: .empty
        )

        do {
            _ = try await runtime.compileAndSetDNR(compilation, for: extensionID)
            XCTFail("A failed profile compiler must not install DNR policy")
        } catch FailingContentRuleListCompiler.Failure.expected {
            // Expected: DNR remains absent unless the injected profile store compiles it.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(compiler.requests.count, 1)
        XCTAssertEqual(compiler.requests.first?.encodedContentRuleList, validBlockRuleJSON("failure.example"))
        XCTAssertEqual(compiler.requests.first?.identifier, "floorp.webextension.dnr.stage3-fixture.7.1")
        XCTAssertNil(runtime.policySnapshot(for: extensionID))
    }

    @MainActor
    func testRuntimeCompilesAndSwapsDNRWithoutAccumulatingOldLivePolicy() async throws {
        let compiler = RecordingContentRuleListCompiler()
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: compiler)
        let first = FloorpWebExtensionDNRCompilation(
            generation: 7,
            webKitContentRuleJSON: validBlockRuleJSON("first.example"),
            compiledRules: [],
            report: .empty
        )
        let replacement = FloorpWebExtensionDNRCompilation(
            generation: 8,
            webKitContentRuleJSON: validBlockRuleJSON("replacement.example"),
            compiledRules: [],
            report: .empty
        )

        let appliedFirst = try await runtime.compileAndSetDNR(first, for: extensionID)
        XCTAssertTrue(appliedFirst)
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.contentRuleListCount, 1)
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.dnrGeneration, 7)

        let appliedReplacement = try await runtime.compileAndSetDNR(replacement, for: extensionID)
        XCTAssertTrue(appliedReplacement)
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.contentRuleListCount, 1)
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.dnrGeneration, 8)
        let conflictingSameGeneration = FloorpWebExtensionDNRCompilation(
            generation: 8,
            webKitContentRuleJSON: validBlockRuleJSON("conflict.example"),
            compiledRules: [],
            report: .empty
        )
        let appliedConflictingGeneration = try await runtime.compileAndSetDNR(
            conflictingSameGeneration,
            for: extensionID
        )
        XCTAssertFalse(appliedConflictingGeneration)
        let appliedStaleGeneration = try await runtime.compileAndSetDNR(first, for: extensionID)
        XCTAssertFalse(appliedStaleGeneration)
        XCTAssertEqual(compiler.requests.map(\.identifier), [
            "floorp.webextension.dnr.stage3-fixture.7.1",
            "floorp.webextension.dnr.stage3-fixture.8.2"
        ])
    }

    @MainActor
    func testRuntimeClearsDNRPolicyForAnEmptyEffectiveRuleSet() async throws {
        let compiler = RecordingContentRuleListCompiler()
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: compiler)
        let active = dnrCompilation(generation: 7, ruleJSON: validBlockRuleJSON("active.example"))
        let empty = FloorpWebExtensionDNRCompilation(
            generation: 8,
            webKitContentRuleJSON: "[]",
            compiledRules: [],
            report: .empty
        )

        let activeApplied = try await runtime.compileAndSetDNR(active, for: extensionID)
        XCTAssertTrue(activeApplied)
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.contentRuleListCount, 1)

        let emptyApplied = try await runtime.compileAndSetDNR(empty, for: extensionID)
        XCTAssertTrue(emptyApplied)
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.contentRuleListCount, 0)
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.dnrGeneration, 8)
        XCTAssertEqual(compiler.requests.count, 1)
    }

    @MainActor
    func testRuntimeDiscardsAnOlderDNRCompilationThatFinishesLast() async throws {
        let compiler = DeferredContentRuleListCompiler()
        defer { compiler.cancelOutstandingRequests() }
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: compiler)
        let older = dnrCompilation(generation: 10, ruleJSON: validBlockRuleJSON("older.example"))
        let newer = dnrCompilation(
            generation: 11,
            ruleJSON: validBlockRuleJSON("newer.example")
        )

        let olderTask = Task { try await runtime.compileAndSetDNR(older, for: extensionID) }
        guard await waitForDeferredCompiler(compiler, requestCount: 1) else { return }
        let newerTask = Task { try await runtime.compileAndSetDNR(newer, for: extensionID) }
        guard await waitForDeferredCompiler(compiler, requestCount: 2) else { return }

        compiler.completeRequest(at: 1)
        let newerApplied = try await newerTask.value
        compiler.completeRequest(at: 0)
        let olderApplied = try await olderTask.value
        guard await waitForDeferredCompilerRemoval(compiler, removalCount: 1) else { return }

        XCTAssertTrue(newerApplied)
        XCTAssertFalse(olderApplied)
        XCTAssertEqual(runtime.policySnapshot(for: extensionID)?.dnrGeneration, 11)
        XCTAssertEqual(
            compiler.removedIdentifiers,
            ["floorp.webextension.dnr.stage3-fixture.10.1"]
        )
    }

    @MainActor
    func testRuntimeUninstallInvalidatesAnInFlightDNRCompilation() async throws {
        let compiler = DeferredContentRuleListCompiler()
        defer { compiler.cancelOutstandingRequests() }
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: compiler)
        let compilation = dnrCompilation(generation: 10, ruleJSON: validBlockRuleJSON("uninstall.example"))

        let task = Task { try await runtime.compileAndSetDNR(compilation, for: extensionID) }
        guard await waitForDeferredCompiler(compiler, requestCount: 1) else { return }
        runtime.removePolicies(for: extensionID)
        compiler.completeRequest(at: 0)
        let applied = try await task.value
        guard await waitForDeferredCompilerRemoval(compiler, removalCount: 1) else { return }

        XCTAssertFalse(applied)
        XCTAssertNil(runtime.policySnapshot(for: extensionID))
        XCTAssertEqual(
            compiler.removedIdentifiers,
            ["floorp.webextension.dnr.stage3-fixture.10.1"]
        )
    }

    @MainActor
    func testRuntimeReplacementInvalidatesAnInFlightDNRCompilation() async throws {
        let oldCompiler = DeferredContentRuleListCompiler()
        defer { oldCompiler.cancelOutstandingRequests() }
        let oldRuntime = FloorpWebExtensionRuntime(contentRuleListCompiler: oldCompiler)
        let replacementRuntime = FloorpWebExtensionRuntime(
            contentRuleListCompiler: FailingContentRuleListCompiler()
        )
        let profileIdentifier = "stage3-replacement-\(UUID().uuidString)"
        let compilation = dnrCompilation(
            generation: 10,
            ruleJSON: validBlockRuleJSON("replaced-runtime.example")
        )

        FloorpWebExtensionRuntime.install(
            oldRuntime,
            for: profileIdentifier,
            isPrivateBrowsing: false
        )
        defer {
            FloorpWebExtensionRuntime.removeRuntime(
                for: profileIdentifier,
                isPrivateBrowsing: false
            )
        }

        let task = Task { try await oldRuntime.compileAndSetDNR(compilation, for: extensionID) }
        guard await waitForDeferredCompiler(oldCompiler, requestCount: 1) else { return }

        FloorpWebExtensionRuntime.install(
            replacementRuntime,
            for: profileIdentifier,
            isPrivateBrowsing: false
        )
        oldCompiler.completeRequest(at: 0)
        let applied = try await task.value
        guard await waitForDeferredCompilerRemoval(oldCompiler, removalCount: 1) else { return }

        XCTAssertFalse(applied)
        XCTAssertNil(oldRuntime.policySnapshot(for: extensionID))
        XCTAssertEqual(
            oldCompiler.removedIdentifiers,
            ["floorp.webextension.dnr.stage3-fixture.10.1"]
        )
        XCTAssertNil(replacementRuntime.policySnapshot(for: extensionID))
    }

    /// This is deliberately a first-navigation proof: policies must be added
    /// before `load`, rather than being observed only after a reload.  It also
    /// proves that a WebKit named content world does not leak its globals into
    /// the page world.
    @MainActor
    func testWebKitFirstNavigationRunsDocumentStartBeforePageAndIsolatesContentWorld() async throws {
        let priorCoreFlag = FloorpFlags.isWebExtensionFeatureEnabled(.core)
        FloorpFlags.setWebExtensionFeature(.core, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.core, enabled: priorCoreFlag) }

        let server = try Stage3WebKitIntegrationServer()
        defer { server.stop() }
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: FailingContentRuleListCompiler())
        let configuration = WKWebViewConfiguration()
        runtime.setScriptPolicies([
            .init(
                source: "globalThis.floorpNavigationOrder = ['extension-document-start'];",
                runAt: .documentStart,
                world: .main
            ),
            .init(
                source: "globalThis.floorpIsolatedStartProof = 'isolated-document-start';",
                runAt: .documentStart,
                world: .isolated
            ),
            .init(
                source: "globalThis.floorpNavigationOrder.push('extension-document-end');",
                runAt: .documentEnd,
                world: .main
            )
        ], for: extensionID)
        // The runtime's pre-navigation handoff is what production tab creation
        // invokes.  Do it before WKWebView's very first `load` below.
        runtime.apply(to: configuration.userContentController)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = Stage3NavigationRecorder()
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: server.url(path: "/proof/first-navigation")))
        try await waitForSuccessfulNavigation(navigation)

        let order = try await webView.callAsyncJavaScript(
            "return JSON.stringify(globalThis.floorpNavigationOrder)",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(
            order,
            "[\"extension-document-start\",\"page-inline\",\"extension-document-end\"]"
        )
        let pageWorldVisibility = try await webView.callAsyncJavaScript(
            "return typeof globalThis.floorpIsolatedStartProof",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(pageWorldVisibility, "undefined")
        let isolatedWorldValue = try await webView.callAsyncJavaScript(
            "return globalThis.floorpIsolatedStartProof",
            contentWorld: .world(name: FloorpWebExtensionRuntime.isolatedContentWorldName(for: extensionID))
        ) as? String
        XCTAssertEqual(isolatedWorldValue, "isolated-document-start")
        XCTAssertEqual(server.requestCount(for: "/proof/first-navigation"), 1)
    }

    /// A top-level grant is only enough to install an `all_frames` policy for
    /// the imminent navigation. Every child frame must still independently
    /// match the registered script and a host grant before package code runs.
    @MainActor
    func testWebKitAllFramesPackageBodyRunsOnlyInMatchingGrantedFrames() async throws {
        let priorCoreFlag = FloorpFlags.isWebExtensionFeatureEnabled(.core)
        FloorpFlags.setWebExtensionFeature(.core, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.core, enabled: priorCoreFlag) }

        let server = try Stage3WebKitIntegrationServer()
        defer { server.stop() }
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: FailingContentRuleListCompiler())
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "stage3-all-frames-\(UUID().uuidString)",
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: { _, source in
                guard source.path == "all-frames.js" else {
                    throw FloorpWebExtensionError.unsupported("test resource \(source.path)")
                }
                return """
                const markPackageExecution = () => {
                  document.documentElement.dataset.floorpAllFramesPackage = 'executed';
                };
                if (document.documentElement) {
                  markPackageExecution();
                } else {
                  addEventListener('DOMContentLoaded', markPackageExecution, { once: true });
                }
                """
            }
        )
        let allowedHost = try FloorpWebExtensionMatchPattern("http://localhost/*")
        let registeredScript = try FloorpWebExtensionRegisteredScript(
            id: "all-frames",
            matches: [allowedHost],
            javaScript: [FloorpWebExtensionScriptSource("all-frames.js")],
            runAt: .documentStart,
            allFrames: true,
            world: .isolated
        )
        try await coordinator.registerScripts([registeredScript], for: extensionID)
        await coordinator.grantPermissions(
            [.scripting],
            requestedHosts: [allowedHost],
            hostAccess: .allRequestedSites,
            to: extensionID
        )

        let mainURL = server.url(path: "/proof/all-frames")
        let tab = FloorpWebExtensionTabContext(
            tabID: 31,
            documentGeneration: 1,
            url: mainURL
        )
        let snapshot = try XCTUnwrap(coordinator.preNavigationPolicies(for: tab).first)
        XCTAssertEqual(snapshot.extensionID, extensionID)
        let frameAuthorization = try XCTUnwrap(snapshot.scriptPolicies.first?.frameAuthorization)
        XCTAssertEqual(frameAuthorization.scriptID, "all-frames")

        let configuration = WKWebViewConfiguration()
        let messageRuntime = FloorpWebExtensionMessageRuntime()
        messageRuntime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { currentURL, isMainFrame, trustedTab in
                coordinator.authorizesBridge(
                    for: self.extensionID,
                    currentURL: currentURL,
                    isMainFrame: isMainFrame,
                    tab: trustedTab
                )
            },
            authorizeFrameScript: { scriptID, revisionToken, currentURL, isMainFrame, trustedTab in
                coordinator.authorizesFrameScript(
                    for: self.extensionID,
                    scriptID: scriptID,
                    revisionToken: revisionToken,
                    currentURL: currentURL,
                    isMainFrame: isMainFrame,
                    tab: trustedTab
                )
            }
        )
        runtime.applyPreNavigationPolicy(snapshot, to: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = Stage3NavigationRecorder()
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: mainURL))
        try await waitForSuccessfulNavigation(navigation)

        let reports = try await waitForJavaScriptString(
            in: webView,
            source: """
            const reports = globalThis.floorpAllFramesReports || {};
            return reports.allowed && reports.denied
              ? reports.allowed + ',' + reports.denied
              : '';
            """,
            expected: "executed,absent"
        )
        XCTAssertEqual(reports, "executed,absent")
        XCTAssertEqual(server.requestCount(for: "/proof/all-frames"), 1)
        XCTAssertEqual(server.requestCount(for: "/proof/frame-allowed"), 1)
        XCTAssertEqual(server.requestCount(for: "/proof/frame-denied"), 1)
    }

    /// The navigation snapshot is deliberately applied while host access is
    /// live. Revocation then happens without navigating or rebuilding the
    /// `WKWebView`; a child frame created afterward must still be denied by the
    /// native, per-frame authorization check instead of executing stale body.
    @MainActor
    func testWebKitAllFramesHostRevocationBlocksDelayedChildFrame() async throws {
        let priorCoreFlag = FloorpFlags.isWebExtensionFeatureEnabled(.core)
        FloorpFlags.setWebExtensionFeature(.core, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.core, enabled: priorCoreFlag) }

        let server = try Stage3WebKitIntegrationServer()
        defer { server.stop() }
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: FailingContentRuleListCompiler())
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "stage3-revoked-all-frames-\(UUID().uuidString)",
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: Self.delayedAllFramesResourceLoader
        )
        let allowedHost = try FloorpWebExtensionMatchPattern("http://localhost/*")
        let registeredScript = try FloorpWebExtensionRegisteredScript(
            id: "delayed-all-frames",
            matches: [allowedHost],
            javaScript: [FloorpWebExtensionScriptSource("delayed-all-frames.js")],
            runAt: .documentStart,
            allFrames: true,
            world: .isolated
        )
        try await coordinator.registerScripts([registeredScript], for: extensionID)
        await coordinator.grantPermissions(
            [.scripting],
            requestedHosts: [allowedHost],
            hostAccess: .allRequestedSites,
            to: extensionID
        )

        let mainURL = server.url(path: "/proof/delayed-all-frames")
        let tab = FloorpWebExtensionTabContext(
            tabID: 32,
            documentGeneration: 1,
            url: mainURL
        )
        let snapshot = try XCTUnwrap(coordinator.preNavigationPolicies(for: tab).first)
        let frameAuthorization = try XCTUnwrap(snapshot.scriptPolicies.first?.frameAuthorization)
        XCTAssertEqual(frameAuthorization.scriptID, "delayed-all-frames")

        let configuration = WKWebViewConfiguration()
        let messageRuntime = FloorpWebExtensionMessageRuntime()
        messageRuntime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { currentURL, isMainFrame, trustedTab in
                coordinator.authorizesBridge(
                    for: self.extensionID,
                    currentURL: currentURL,
                    isMainFrame: isMainFrame,
                    tab: trustedTab
                )
            },
            authorizeFrameScript: { scriptID, revisionToken, currentURL, isMainFrame, trustedTab in
                coordinator.authorizesFrameScript(
                    for: self.extensionID,
                    scriptID: scriptID,
                    revisionToken: revisionToken,
                    currentURL: currentURL,
                    isMainFrame: isMainFrame,
                    tab: trustedTab
                )
            }
        )
        runtime.applyPreNavigationPolicy(snapshot, to: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = Stage3NavigationRecorder()
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: mainURL))
        try await waitForSuccessfulNavigation(navigation)
        _ = try await waitForJavaScriptString(
            in: webView,
            source: "return document.documentElement.dataset.floorpDelayedAllFramesPackage || '';",
            expected: "executed"
        )

        await coordinator.revokeHostPermissions(for: extensionID)
        XCTAssertFalse(coordinator.authorizesFrameScript(
            for: extensionID,
            scriptID: "delayed-all-frames",
            revisionToken: frameAuthorization.revisionToken,
            currentURL: server.url(path: "/proof/frame-after-revoke"),
            isMainFrame: false,
            tab: tab
        ))
        _ = try await webView.callAsyncJavaScript(
            "globalThis.floorpAppendDelayedFrame('/proof/frame-after-revoke'); return true;",
            contentWorld: .page
        )
        let report = try await waitForJavaScriptString(
            in: webView,
            source: "return globalThis.floorpDelayedFrameReports?.revoked || '';",
            expected: "absent"
        )
        XCTAssertEqual(report, "absent")
        XCTAssertEqual(server.requestCount(for: "/proof/frame-after-revoke"), 1)
    }

    /// activeTab is document- and time-scoped. A pre-navigation all-frame
    /// snapshot may outlive its grant, so a same-origin child created after
    /// expiry must consult the live native clock and leave package body absent.
    @MainActor
    func testWebKitAllFramesActiveTabExpiryBlocksDelayedSameOriginChildFrame() async throws {
        let priorCoreFlag = FloorpFlags.isWebExtensionFeatureEnabled(.core)
        FloorpFlags.setWebExtensionFeature(.core, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.core, enabled: priorCoreFlag) }

        let server = try Stage3WebKitIntegrationServer()
        defer { server.stop() }
        let clock = Stage3MutableClock(Date(timeIntervalSince1970: 1_000))
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: FailingContentRuleListCompiler())
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "stage3-expired-active-tab-\(UUID().uuidString)",
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: Self.delayedAllFramesResourceLoader,
            now: { clock.now() }
        )
        let allowedHost = try FloorpWebExtensionMatchPattern("http://localhost/*")
        let registeredScript = try FloorpWebExtensionRegisteredScript(
            id: "delayed-all-frames",
            matches: [allowedHost],
            javaScript: [FloorpWebExtensionScriptSource("delayed-all-frames.js")],
            runAt: .documentStart,
            allFrames: true,
            world: .isolated
        )
        try await coordinator.registerScripts([registeredScript], for: extensionID)
        await coordinator.grantPermissions(
            [.activeTab, .scripting],
            requestedHosts: [allowedHost],
            hostAccess: .denied,
            to: extensionID
        )

        let mainURL = server.url(path: "/proof/delayed-all-frames")
        let tab = FloorpWebExtensionTabContext(
            tabID: 33,
            documentGeneration: 1,
            url: mainURL
        )
        try await coordinator.grantActiveTab(to: extensionID, for: tab, duration: 1)
        let snapshot = try XCTUnwrap(coordinator.preNavigationPolicies(for: tab).first)
        let frameAuthorization = try XCTUnwrap(snapshot.scriptPolicies.first?.frameAuthorization)
        XCTAssertEqual(frameAuthorization.scriptID, "delayed-all-frames")

        let configuration = WKWebViewConfiguration()
        let messageRuntime = FloorpWebExtensionMessageRuntime()
        messageRuntime.installBridge(
            for: extensionID,
            tab: tab,
            on: configuration.userContentController,
            authorizeDocument: { currentURL, isMainFrame, trustedTab in
                coordinator.authorizesBridge(
                    for: self.extensionID,
                    currentURL: currentURL,
                    isMainFrame: isMainFrame,
                    tab: trustedTab
                )
            },
            authorizeFrameScript: { scriptID, revisionToken, currentURL, isMainFrame, trustedTab in
                coordinator.authorizesFrameScript(
                    for: self.extensionID,
                    scriptID: scriptID,
                    revisionToken: revisionToken,
                    currentURL: currentURL,
                    isMainFrame: isMainFrame,
                    tab: trustedTab
                )
            }
        )
        runtime.applyPreNavigationPolicy(snapshot, to: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = Stage3NavigationRecorder()
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: mainURL))
        try await waitForSuccessfulNavigation(navigation)
        _ = try await waitForJavaScriptString(
            in: webView,
            source: "return document.documentElement.dataset.floorpDelayedAllFramesPackage || '';",
            expected: "executed"
        )

        clock.advance(by: 2)
        XCTAssertFalse(coordinator.authorizesFrameScript(
            for: extensionID,
            scriptID: "delayed-all-frames",
            revisionToken: frameAuthorization.revisionToken,
            currentURL: server.url(path: "/proof/frame-after-active-tab-expiry"),
            isMainFrame: false,
            tab: tab
        ))
        _ = try await webView.callAsyncJavaScript(
            "globalThis.floorpAppendDelayedFrame('/proof/frame-after-active-tab-expiry'); return true;",
            contentWorld: .page
        )
        let report = try await waitForJavaScriptString(
            in: webView,
            source: "return globalThis.floorpDelayedFrameReports?.expired || '';",
            expected: "absent"
        )
        XCTAssertEqual(report, "absent")
        XCTAssertEqual(server.requestCount(for: "/proof/frame-after-active-tab-expiry"), 1)
    }

    /// Page code can replace any JavaScript-only guard, while the authenticated
    /// bridge intentionally exists only in the isolated world. MAIN-world
    /// all-frame registration therefore fails closed in both the top document
    /// and a child frame instead of exposing a forgeable authorization path.
    @MainActor
    func testWebKitMainWorldAllFramesFailsClosedWithoutRunningPackageBody() async throws {
        let priorCoreFlag = FloorpFlags.isWebExtensionFeatureEnabled(.core)
        FloorpFlags.setWebExtensionFeature(.core, enabled: true)
        defer { FloorpFlags.setWebExtensionFeature(.core, enabled: priorCoreFlag) }

        let server = try Stage3WebKitIntegrationServer()
        defer { server.stop() }
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: FailingContentRuleListCompiler())
        let coordinator = FloorpWebExtensionCoordinator(
            profileIdentifier: "stage3-main-all-frames-\(UUID().uuidString)",
            isPrivateBrowsing: false,
            runtime: runtime,
            scriptResourceLoader: Self.delayedAllFramesResourceLoader
        )
        let allowedHost = try FloorpWebExtensionMatchPattern("http://localhost/*")
        let registeredScript = try FloorpWebExtensionRegisteredScript(
            id: "main-world-all-frames",
            matches: [allowedHost],
            javaScript: [FloorpWebExtensionScriptSource("delayed-all-frames.js")],
            runAt: .documentStart,
            allFrames: true,
            world: .main
        )
        try await coordinator.registerScripts([registeredScript], for: extensionID)
        await coordinator.grantPermissions(
            [.scripting],
            requestedHosts: [allowedHost],
            hostAccess: .allRequestedSites,
            to: extensionID
        )

        let mainURL = server.url(path: "/proof/delayed-all-frames")
        let tab = FloorpWebExtensionTabContext(
            tabID: 34,
            documentGeneration: 1,
            url: mainURL
        )
        let snapshot = try XCTUnwrap(coordinator.preNavigationPolicies(for: tab).first)
        XCTAssertEqual(snapshot.scriptPolicies.first?.world, .main)
        let frameAuthorization = try XCTUnwrap(snapshot.scriptPolicies.first?.frameAuthorization)
        XCTAssertEqual(frameAuthorization.scriptID, "main-world-all-frames")

        let configuration = WKWebViewConfiguration()
        runtime.applyPreNavigationPolicy(snapshot, to: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = Stage3NavigationRecorder()
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: mainURL))
        try await waitForSuccessfulNavigation(navigation)
        let mainResult = try await webView.callAsyncJavaScript(
            "return document.documentElement.dataset.floorpDelayedAllFramesPackage || 'absent';",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(mainResult, "absent")

        _ = try await webView.callAsyncJavaScript(
            "globalThis.floorpAppendDelayedFrame('/proof/frame-after-main-world'); return true;",
            contentWorld: .page
        )
        let childResult = try await waitForJavaScriptString(
            in: webView,
            source: "return globalThis.floorpDelayedFrameReports?.mainWorld || '';",
            expected: "absent"
        )
        XCTAssertEqual(childResult, "absent")
        XCTAssertEqual(server.requestCount(for: "/proof/frame-after-main-world"), 1)
    }

    /// Exercises the actual `WKContentRuleList` data path, not just the JSON
    /// compiler.  A blocked main frame must never reach the local server.
    @MainActor
    func testWebKitDNRBlocksMainFrameBeforeTheServerReceivesIt() async throws {
        let server = try Stage3WebKitIntegrationServer()
        defer { server.stop() }
        let blockedURL = server.url(path: "/dnr/main-frame-blocked")
        let rules = try FloorpWebExtensionDNRStore(
            staticRuleSets: [.init(
                identifier: "main-frame",
                rules: [.init(
                    id: 1,
                    action: .init(type: .block),
                    condition: .init(
                        regexFilter: "^\(NSRegularExpression.escapedPattern(for: blockedURL.absoluteString))$",
                        resourceTypes: [.mainFrame]
                    )
                )]
            )],
            enabledStaticRuleSetIDs: ["main-frame"]
        )
        let compilation = await rules.currentCompilation()
        XCTAssertFalse(compilation.report.hasRejections)
        let ruleStore = TestContentRuleListStore()
        let ruleList = try await ruleStore.compile(
            identifier: "stage3-main-block-\(UUID().uuidString)",
            contentRuleListJSON: compilation.webKitContentRuleJSON
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(ruleList)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = Stage3NavigationRecorder()
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: blockedURL))
        try await waitForFailedNavigation(navigation)

        XCTAssertEqual(server.requestCount(for: "/dnr/main-frame-blocked"), 0)
    }

    /// WebKit's `ignore-previous-rules` is the supported implementation of a
    /// higher-priority MV3 allow exception.  This proves both outcomes against
    /// real subresource requests in one deterministic document.
    @MainActor
    func testWebKitDNRBlocksSubresourceAndAllowsHigherPriorityException() async throws {
        let server = try Stage3WebKitIntegrationServer()
        defer { server.stop() }
        let basePattern = NSRegularExpression.escapedPattern(
            for: server.url(path: "/dnr/subresource-").absoluteString
        )
        let rules = try FloorpWebExtensionDNRStore(
            staticRuleSets: [.init(
                identifier: "subresources",
                rules: [
                    .init(
                        id: 10,
                        priority: 1,
                        action: .init(type: .block),
                        condition: .init(
                            regexFilter: "^\(basePattern).*$",
                            resourceTypes: [.image]
                        )
                    ),
                    .init(
                        id: 11,
                        priority: 2,
                        action: .init(type: .allow),
                        condition: .init(
                            regexFilter: "^\(basePattern)allowed$",
                            resourceTypes: [.image]
                        )
                    )
                ]
            )],
            enabledStaticRuleSetIDs: ["subresources"]
        )
        let compilation = await rules.currentCompilation()
        XCTAssertFalse(compilation.report.hasRejections)
        let ruleStore = TestContentRuleListStore()
        let ruleList = try await ruleStore.compile(
            identifier: "stage3-subresource-rules-\(UUID().uuidString)",
            contentRuleListJSON: compilation.webKitContentRuleJSON
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(ruleList)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = Stage3NavigationRecorder()
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: server.url(path: "/dnr/subresources")))
        try await waitForSuccessfulNavigation(navigation)
        let events = try await waitForJavaScriptString(
            in: webView,
            source: """
            const events = globalThis.floorpSubresourceEvents || [];
            return events.includes('blocked-error') && events.includes('allowed-load')
              ? JSON.stringify([...events].sort())
              : '';
            """,
            expected: "[\"allowed-load\",\"blocked-error\"]"
        )

        XCTAssertEqual(events, "[\"allowed-load\",\"blocked-error\"]")
        XCTAssertEqual(server.requestCount(for: "/dnr/subresource-blocked"), 0)
        XCTAssertEqual(server.requestCount(for: "/dnr/subresource-allowed"), 1)
    }

    private func script(
        id: String,
        source: String,
        excludes: [FloorpWebExtensionMatchPattern] = [],
        runAt: FloorpWebExtensionRunAt = .documentEnd,
        allFrames: Bool = false,
        world: FloorpWebExtensionExecutionWorld = .isolated
    ) throws -> FloorpWebExtensionRegisteredScript {
        try .init(
            id: id,
            matches: [FloorpWebExtensionMatchPattern("https://allowed.example/*")],
            excludeMatches: excludes,
            javaScript: [FloorpWebExtensionScriptSource(source)],
            runAt: runAt,
            allFrames: allFrames,
            world: world
        )
    }

    private func scriptPolicy(
        _ source: String,
        world: FloorpWebExtensionExecutionWorld = .isolated
    ) -> FloorpWebExtensionUserScriptPolicy {
        FloorpWebExtensionUserScriptPolicy(
            source: source,
            runAt: .documentStart,
            allFrames: false,
            world: world
        )
    }

    private func dnrCompilation(generation: UInt64, ruleJSON: String) -> FloorpWebExtensionDNRCompilation {
        FloorpWebExtensionDNRCompilation(
            generation: generation,
            webKitContentRuleJSON: ruleJSON,
            compiledRules: [],
            report: .empty
        )
    }

    private func validBlockRuleJSON(_ urlFilter: String) -> String {
        "[{\"trigger\":{\"url-filter\":\"\(urlFilter)\"},\"action\":{\"type\":\"block\"}}]"
    }

    private static func delayedAllFramesResourceLoader(
        _ extensionID: FloorpWebExtensionID,
        _ source: FloorpWebExtensionScriptSource
    ) throws -> String {
        guard source.path == "delayed-all-frames.js" else {
            throw FloorpWebExtensionError.unsupported("test resource \(source.path)")
        }
        return """
        const markDelayedAllFramesExecution = () => {
          document.documentElement.dataset.floorpDelayedAllFramesPackage = 'executed';
        };
        if (document.documentElement) {
          markDelayedAllFramesExecution();
        } else {
          addEventListener('DOMContentLoaded', markDelayedAllFramesExecution, { once: true });
        }
        """
    }

    @MainActor
    private func waitForSuccessfulNavigation(
        _ navigation: Stage3NavigationRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<250 {
            if navigation.didFinishCount > 0 { return }
            if let error = navigation.lastError {
                XCTFail("Expected WebKit navigation to succeed: \(error)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for WebKit navigation to finish", file: file, line: line)
    }

    @MainActor
    private func waitForFailedNavigation(
        _ navigation: Stage3NavigationRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<250 {
            if navigation.lastError != nil { return }
            if navigation.didFinishCount > 0 {
                XCTFail("Expected WebKit navigation to be blocked", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for WebKit to reject the blocked navigation", file: file, line: line)
    }

    @MainActor
    private func waitForJavaScriptString(
        in webView: WKWebView,
        source: String,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> String? {
        for _ in 0..<250 {
            let value = try await webView.callAsyncJavaScript(source, contentWorld: .page) as? String
            if value == expected { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for expected JavaScript value \(expected)", file: file, line: line)
        return nil
    }

    @MainActor
    private func waitForDeferredCompiler(
        _ compiler: DeferredContentRuleListCompiler,
        requestCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100 where compiler.requests.count < requestCount {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                XCTFail("Deferred DNR compilation wait was cancelled", file: file, line: line)
                return false
            }
        }
        guard compiler.requests.count >= requestCount else {
            XCTFail("Timed out waiting for deferred DNR compilation", file: file, line: line)
            return false
        }
        return true
    }

    @MainActor
    private func waitForDeferredCompilerRemoval(
        _ compiler: DeferredContentRuleListCompiler,
        removalCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100 where compiler.removedIdentifiers.count < removalCount {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                XCTFail("Deferred DNR removal wait was cancelled", file: file, line: line)
                return false
            }
        }
        guard compiler.removedIdentifiers.count >= removalCount else {
            XCTFail("Timed out waiting for deferred DNR removal", file: file, line: line)
            return false
        }
        return true
    }

    private func assertAsyncThrows<T>(
        _ operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            // The failure type is asserted by the state-preservation checks.
        }
    }
}

@MainActor
private final class FailingContentRuleListCompiler: FloorpWebExtensionContentRuleListCompiling {
    enum Failure: Error {
        case expected
    }

    struct Request {
        let identifier: String
        let encodedContentRuleList: String
    }

    private(set) var requests = [Request]()

    func compileContentRuleList(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList {
        requests.append(.init(identifier: identifier, encodedContentRuleList: encodedContentRuleList))
        throw Failure.expected
    }

    func removeContentRuleList(forIdentifier identifier: String) async {}
}

@MainActor
private final class RecordingContentRuleListCompiler: FloorpWebExtensionContentRuleListCompiling {
    struct Request {
        let identifier: String
        let encodedContentRuleList: String
    }

    private(set) var requests = [Request]()
    private let ruleStore = TestContentRuleListStore()

    func compileContentRuleList(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList {
        requests.append(.init(identifier: identifier, encodedContentRuleList: encodedContentRuleList))
        return try await ruleStore.compile(
            identifier: identifier,
            contentRuleListJSON: encodedContentRuleList
        )
    }

    func removeContentRuleList(forIdentifier identifier: String) async {
        await ruleStore.remove(identifier: identifier)
    }
}

@MainActor
private final class DeferredContentRuleListCompiler: FloorpWebExtensionContentRuleListCompiling {
    struct Request {
        let identifier: String
        let encodedContentRuleList: String
    }

    private(set) var requests = [Request]()
    private(set) var removedIdentifiers = [String]()
    private var continuations = [CheckedContinuation<WKContentRuleList, Error>?]()
    private var compiledRuleLists = [WKContentRuleList?]()
    private let ruleStore = TestContentRuleListStore()

    func compileContentRuleList(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList {
        let compiledRuleList = try await ruleStore.compile(
            identifier: identifier,
            contentRuleListJSON: encodedContentRuleList
        )
        requests.append(.init(identifier: identifier, encodedContentRuleList: encodedContentRuleList))
        compiledRuleLists.append(compiledRuleList)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func removeContentRuleList(forIdentifier identifier: String) async {
        removedIdentifiers.append(identifier)
    }

    func completeRequest(at index: Int) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else {
            XCTFail("Missing deferred DNR compilation request at index \(index)")
            return
        }
        continuations[index] = nil
        guard let compiledRuleList = compiledRuleLists[index] else {
            XCTFail("Missing compiled DNR rule list at index \(index)")
            return
        }
        compiledRuleLists[index] = nil
        continuation.resume(returning: compiledRuleList)
    }

    func cancelOutstandingRequests() {
        for index in continuations.indices {
            guard let continuation = continuations[index] else { continue }
            continuations[index] = nil
            compiledRuleLists[index] = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}

@MainActor
private final class TestContentRuleListStore {
    private let store: WKContentRuleListStore

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-webextension-runtime-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)!
    }

    func compile(identifier: String, contentRuleListJSON: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: contentRuleListJSON
            ) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: ContentRuleListTestError.missingRuleList)
                }
            }
        }
    }

    func remove(identifier: String) async {
        await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}

private enum ContentRuleListTestError: Error {
    case missingRuleList
}

private final class HandleSuffixes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private final class Stage3MutableClock: @unchecked Sendable {
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
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

/// A dedicated local server gives the WebKit integration tests deterministic
/// request accounting: assertions distinguish an actual network block from a
/// document that merely failed after reaching the origin.
private final class Stage3WebKitIntegrationServer {
    private let server = GCDWebServer()
    private let requests = Stage3RequestRecorder()

    init() throws {
        server.addHandler(
            forMethod: "GET",
            path: "/proof/first-navigation",
            request: GCDWebServerRequest.self
        ) { [requests, server] _ in
            requests.record("/proof/first-navigation")
            return GCDWebServerDataResponse(html: """
            <!doctype html><html><body>
            <script>globalThis.floorpNavigationOrder.push('page-inline');</script>
            first navigation
            </body></html>
            """)!
        }
        server.addHandler(
            forMethod: "GET",
            path: "/proof/all-frames",
            request: GCDWebServerRequest.self
        ) { [requests] _ in
            requests.record("/proof/all-frames")
            return GCDWebServerDataResponse(html: """
            <!doctype html><html><body>
            <script>
              globalThis.floorpAllFramesReports = {};
              addEventListener('message', event => {
                const report = event.data;
                if (report && report.kind === 'floorp-all-frames-report') {
                  globalThis.floorpAllFramesReports[report.frame] = report.result;
                }
              });
            </script>
            <iframe src="/proof/frame-allowed"></iframe>
            <iframe src="http://127.0.0.1:\(self.server.port)/proof/frame-denied"></iframe>
            </body></html>
            """)!
        }
        for (path, frame) in [
            ("/proof/frame-allowed", "allowed"),
            ("/proof/frame-denied", "denied")
        ] {
            server.addHandler(
                forMethod: "GET",
                path: path,
                request: GCDWebServerRequest.self
            ) { [requests] _ in
                requests.record(path)
                return GCDWebServerDataResponse(html: """
                <!doctype html><html><body>
                <script>
                  addEventListener('DOMContentLoaded', () => {
                    const deadline = Date.now() + 1000;
                    const report = () => {
                      const result = document.documentElement.dataset.floorpAllFramesPackage;
                      if (!result && Date.now() < deadline) {
                        setTimeout(report, 20);
                        return;
                      }
                      parent.postMessage({
                        kind: 'floorp-all-frames-report',
                        frame: '\(frame)',
                        result: result || 'absent'
                      }, '*');
                    };
                    report();
                  });
                </script>
                </body></html>
                """)!
            }
        }
        server.addHandler(
            forMethod: "GET",
            path: "/proof/delayed-all-frames",
            request: GCDWebServerRequest.self
        ) { [requests] _ in
            requests.record("/proof/delayed-all-frames")
            return GCDWebServerDataResponse(html: """
            <!doctype html><html><body>
            <script>
              globalThis.floorpDelayedFrameReports = {};
              globalThis.floorpAppendDelayedFrame = path => {
                const frame = document.createElement('iframe');
                frame.src = path;
                document.body.appendChild(frame);
              };
              addEventListener('message', event => {
                const report = event.data;
                if (report && report.kind === 'floorp-delayed-frame-report') {
                  globalThis.floorpDelayedFrameReports[report.frame] = report.result;
                }
              });
            </script>
            delayed all-frames host
            </body></html>
            """)!
        }
        for (path, frame) in [
            ("/proof/frame-after-revoke", "revoked"),
            ("/proof/frame-after-active-tab-expiry", "expired"),
            ("/proof/frame-after-main-world", "mainWorld")
        ] {
            server.addHandler(
                forMethod: "GET",
                path: path,
                request: GCDWebServerRequest.self
            ) { [requests] _ in
                requests.record(path)
                return GCDWebServerDataResponse(html: """
                <!doctype html><html><body>
                <script>
                  addEventListener('DOMContentLoaded', () => {
                    const deadline = Date.now() + 1000;
                    const report = () => {
                      const result = document.documentElement.dataset.floorpDelayedAllFramesPackage;
                      if (!result && Date.now() < deadline) {
                        setTimeout(report, 20);
                        return;
                      }
                      parent.postMessage({
                        kind: 'floorp-delayed-frame-report',
                        frame: '\(frame)',
                        result: result || 'absent'
                      }, '*');
                    };
                    report();
                  });
                </script>
                </body></html>
                """)!
            }
        }
        server.addHandler(
            forMethod: "GET",
            path: "/dnr/main-frame-blocked",
            request: GCDWebServerRequest.self
        ) { [requests] _ in
            requests.record("/dnr/main-frame-blocked")
            return GCDWebServerDataResponse(html: "<!doctype html><title>unexpected main-frame response</title>")!
        }
        server.addHandler(
            forMethod: "GET",
            path: "/dnr/subresources",
            request: GCDWebServerRequest.self
        ) { [requests] _ in
            requests.record("/dnr/subresources")
            return GCDWebServerDataResponse(html: """
            <!doctype html><html><body>
            <script>globalThis.floorpSubresourceEvents = [];</script>
            <img src="/dnr/subresource-blocked"
                 onload="globalThis.floorpSubresourceEvents.push('blocked-load')"
                 onerror="globalThis.floorpSubresourceEvents.push('blocked-error')">
            <img src="/dnr/subresource-allowed"
                 onload="globalThis.floorpSubresourceEvents.push('allowed-load')"
                 onerror="globalThis.floorpSubresourceEvents.push('allowed-error')">
            </body></html>
            """)!
        }
        for path in ["/dnr/subresource-blocked", "/dnr/subresource-allowed"] {
            server.addHandler(
                forMethod: "GET",
                path: path,
                request: GCDWebServerRequest.self
            ) { [requests] _ in
                requests.record(path)
                return GCDWebServerDataResponse(
                    data: Stage3WebKitIntegrationServer.onePixelGIF,
                    contentType: "image/gif"
                )
            }
        }
        guard server.start(withPort: 0, bonjourName: nil) else {
            throw Stage3WebKitIntegrationServerError.couldNotStart
        }
    }

    func stop() {
        server.stop()
    }

    func url(path: String) -> URL {
        URL(string: "http://localhost:\(server.port)\(path)")!
    }

    func requestCount(for path: String) -> Int {
        requests.count(for: path)
    }

    private static let onePixelGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!
}

private enum Stage3WebKitIntegrationServerError: Error {
    case couldNotStart
}

private final class Stage3RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = [String: Int]()

    func record(_ path: String) {
        lock.lock()
        counts[path, default: 0] += 1
        lock.unlock()
    }

    func count(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path, default: 0]
    }
}

@MainActor
private final class Stage3NavigationRecorder: NSObject, WKNavigationDelegate {
    private(set) var didFinishCount = 0
    private(set) var lastError: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishCount += 1
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        lastError = error
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        lastError = error
    }
}
