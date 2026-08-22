// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
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
        let registry = FloorpWebExtensionCSSRegistry(nextHandleSuffix: { suffixes.next() })
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
