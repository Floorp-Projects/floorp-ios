// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebExtensionCoordinatorTests: XCTestCase {
    private let extensionID = FloorpWebExtensionID(rawValue: "coordinator-fixture")!

    func testRegisteredScriptsAndHostGrantsSynchronouslyRefreshPreNavigationPolicy() async throws {
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: CoordinatorRuleListCompiler())
        let coordinator = makeCoordinator(runtime: runtime)
        let script = try registeredScript(id: "registered", source: "content.js")
        let tab = testTab()

        try await coordinator.registerScripts([script], for: extensionID)
        XCTAssertTrue(coordinator.preNavigationPolicies(for: tab).isEmpty)

        let host = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        await coordinator.grantPermissions(
            [.scripting],
            requestedHosts: [host],
            hostAccess: .allRequestedSites,
            to: extensionID
        )
        let afterGrant = coordinator.preNavigationPolicies(for: tab)
        XCTAssertEqual(afterGrant.count, 1)
        XCTAssertEqual(afterGrant.first?.extensionID, extensionID)
        XCTAssertEqual(afterGrant.first?.scriptPolicies.map(\.source), ["window.coordinatorContent = true;"])

        try await coordinator.updateScripts(
            [.init(id: "registered", runAt: .documentStart, allFrames: true)],
            for: extensionID
        )
        let afterUpdate = try XCTUnwrap(coordinator.preNavigationPolicies(for: tab).first)
        XCTAssertEqual(afterUpdate.scriptPolicies.first?.runAt, .documentStart)
        XCTAssertEqual(afterUpdate.scriptPolicies.first?.allFrames, true)

        await coordinator.revokeHostPermissions(for: extensionID)
        XCTAssertTrue(coordinator.preNavigationPolicies(for: tab).isEmpty)

        try await coordinator.unregisterScripts(["registered"], for: extensionID)
        XCTAssertTrue(coordinator.preNavigationPolicies(for: tab).isEmpty)
    }

    func testNormalAndPrivateCoordinatorsNeverShareScriptsOrGrants() async throws {
        let profile = "coordinator-profile-\(UUID().uuidString)"
        let normal = makeCoordinator(
            profileIdentifier: profile,
            isPrivateBrowsing: false,
            runtime: .init(contentRuleListCompiler: CoordinatorRuleListCompiler())
        )
        let privateCoordinator = makeCoordinator(
            profileIdentifier: profile,
            isPrivateBrowsing: true,
            runtime: .init(contentRuleListCompiler: CoordinatorRuleListCompiler())
        )
        let script = try registeredScript(id: "isolated", source: "content.js")
        let host = try FloorpWebExtensionMatchPattern("https://allowed.example/*")

        try await normal.registerScripts([script], for: extensionID)
        await normal.grantPermissions(
            [.scripting],
            requestedHosts: [host],
            hostAccess: .allRequestedSites,
            to: extensionID
        )

        XCTAssertEqual(normal.preNavigationPolicies(for: testTab(isPrivate: false)).count, 1)
        XCTAssertTrue(privateCoordinator.preNavigationPolicies(for: testTab(isPrivate: true)).isEmpty)
        XCTAssertTrue(normal.preNavigationPolicies(for: testTab(isPrivate: true)).isEmpty)

        try await privateCoordinator.registerScripts([script], for: extensionID)
        await privateCoordinator.grantPermissions(
            [.scripting],
            requestedHosts: [host],
            hostAccess: .allRequestedSites,
            privateHostAccess: .allRequestedSites,
            privateBrowsingEnabled: true,
            to: extensionID
        )
        XCTAssertEqual(privateCoordinator.preNavigationPolicies(for: testTab(isPrivate: true)).count, 1)
        XCTAssertEqual(normal.preNavigationPolicies(for: testTab(isPrivate: false)).count, 1)
    }

    func testBridgeAuthorizationRechecksFrameHostMatchAndFrameScope() async throws {
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: CoordinatorRuleListCompiler())
        let coordinator = makeCoordinator(runtime: runtime)
        let tab = testTab()
        let script = try registeredScript(id: "bridge", source: "content.js")
        let host = try FloorpWebExtensionMatchPattern("https://allowed.example/*")

        try await coordinator.registerScripts([script], for: extensionID)
        await coordinator.grantPermissions(
            [.scripting],
            requestedHosts: [host],
            hostAccess: .allRequestedSites,
            to: extensionID
        )

        XCTAssertTrue(coordinator.authorizesBridge(
            for: extensionID,
            currentURL: tab.url,
            isMainFrame: true,
            tab: tab
        ))
        XCTAssertFalse(coordinator.authorizesBridge(
            for: extensionID,
            currentURL: tab.url,
            isMainFrame: false,
            tab: tab
        ))
        XCTAssertFalse(coordinator.authorizesBridge(
            for: extensionID,
            currentURL: URL(string: "https://ungranted.example/frame")!,
            isMainFrame: false,
            tab: tab
        ))

        try await coordinator.updateScripts(
            [.init(id: "bridge", allFrames: true)],
            for: extensionID
        )
        XCTAssertTrue(coordinator.authorizesBridge(
            for: extensionID,
            currentURL: tab.url,
            isMainFrame: false,
            tab: tab
        ))

        await coordinator.revokeHostPermissions(for: extensionID)
        XCTAssertFalse(coordinator.authorizesBridge(
            for: extensionID,
            currentURL: tab.url,
            isMainFrame: true,
            tab: tab
        ))
    }

    func testActiveTabGrantDoesNotAuthorizeCrossOriginChildFrame() async throws {
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: CoordinatorRuleListCompiler())
        let coordinator = makeCoordinator(runtime: runtime)
        let tab = testTab()
        let allURLs = try FloorpWebExtensionMatchPattern("<all_urls>")
        let script = try registeredScript(
            id: "active-tab-frames",
            matches: [allURLs],
            source: "content.js",
            allFrames: true
        )

        try await coordinator.registerScripts([script], for: extensionID)
        await coordinator.grantPermissions(
            [.activeTab, .scripting],
            requestedHosts: [allURLs],
            hostAccess: .denied,
            to: extensionID
        )
        try await coordinator.grantActiveTab(to: extensionID, for: tab)

        let snapshot = try XCTUnwrap(coordinator.preNavigationPolicies(for: tab).first)
        let frameAuthorization = try XCTUnwrap(snapshot.scriptPolicies.first?.frameAuthorization)
        XCTAssertEqual(frameAuthorization.scriptID, "active-tab-frames")
        XCTAssertTrue(coordinator.authorizesBridge(
            for: extensionID,
            currentURL: URL(string: "https://allowed.example/same-origin-frame")!,
            isMainFrame: false,
            tab: tab
        ))
        XCTAssertFalse(coordinator.authorizesBridge(
            for: extensionID,
            currentURL: URL(string: "https://ungranted.example/cross-origin-frame")!,
            isMainFrame: false,
            tab: tab
        ))
        XCTAssertTrue(coordinator.authorizesFrameScript(
            for: extensionID,
            scriptID: "active-tab-frames",
            revisionToken: frameAuthorization.revisionToken,
            currentURL: URL(string: "https://allowed.example/same-origin-frame")!,
            isMainFrame: false,
            tab: tab
        ))
        XCTAssertFalse(coordinator.authorizesFrameScript(
            for: extensionID,
            scriptID: "unexpected-script-id",
            revisionToken: frameAuthorization.revisionToken,
            currentURL: URL(string: "https://allowed.example/same-origin-frame")!,
            isMainFrame: false,
            tab: tab
        ))

        try await coordinator.updateScripts(
            [.init(id: "active-tab-frames", runAt: .documentStart)],
            for: extensionID
        )
        let replacementSnapshot = try XCTUnwrap(coordinator.preNavigationPolicies(for: tab).first)
        let replacementAuthorization = try XCTUnwrap(
            replacementSnapshot.scriptPolicies.first?.frameAuthorization
        )
        XCTAssertNotEqual(replacementAuthorization.revisionToken, frameAuthorization.revisionToken)
        XCTAssertFalse(coordinator.authorizesFrameScript(
            for: extensionID,
            scriptID: "active-tab-frames",
            revisionToken: frameAuthorization.revisionToken,
            currentURL: URL(string: "https://allowed.example/same-origin-frame")!,
            isMainFrame: false,
            tab: tab
        ))
        XCTAssertTrue(coordinator.authorizesFrameScript(
            for: extensionID,
            scriptID: "active-tab-frames",
            revisionToken: replacementAuthorization.revisionToken,
            currentURL: URL(string: "https://allowed.example/same-origin-frame")!,
            isMainFrame: false,
            tab: tab
        ))
    }

    func testDNRStoreIsNotReplacedWhenRuntimeCompilationFails() async throws {
        let compiler = CoordinatorRuleListCompiler()
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: compiler)
        let coordinator = makeCoordinator(runtime: runtime)
        await coordinator.grantPermissions(
            [.declarativeNetRequest],
            requestedHosts: [],
            hostAccess: .denied,
            to: extensionID
        )
        let configured = try await coordinator.configureDNR(for: extensionID)
        XCTAssertTrue(configured)
        let beforeSnapshot = await coordinator.dnrSnapshot(for: extensionID)
        let before = try XCTUnwrap(beforeSnapshot)

        compiler.shouldFail = true
        await assertAsyncThrows {
            try await coordinator.updateDynamicRules(
                addRules: [
                    .init(
                        id: 1,
                        action: .init(type: .block),
                        condition: .init(urlFilter: "ads.example")
                    )
                ],
                removeRuleIDs: [],
                for: self.extensionID
            )
        }

        let afterSnapshot = await coordinator.dnrSnapshot(for: extensionID)
        let after = try XCTUnwrap(afterSnapshot)
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(after.dynamicRules, [])
    }

    func testRemovingExtensionInvalidatesAnInFlightDNRMutation() async throws {
        let compiler = CoordinatorRuleListCompiler()
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: compiler)
        let coordinator = makeCoordinator(runtime: runtime)
        await coordinator.grantPermissions(
            [.declarativeNetRequest],
            requestedHosts: [],
            hostAccess: .denied,
            to: extensionID
        )
        let initialDNRConfigured = try await coordinator.configureDNR(for: extensionID)
        XCTAssertTrue(initialDNRConfigured)

        compiler.pauseNextCompilation = true
        let mutation = Task {
            try await coordinator.updateDynamicRules(
                addRules: [
                    .init(
                        id: 1,
                        action: .init(type: .block),
                        condition: .init(urlFilter: "stale.example")
                    )
                ],
                removeRuleIDs: [],
                for: self.extensionID
            )
        }
        await compiler.waitUntilCompilationPaused()

        let removal = Task {
            await coordinator.removeExtension(self.extensionID)
        }
        await Task.yield()
        compiler.resumePausedCompilation()

        let mutationApplied = try await mutation.value
        await removal.value
        let snapshotAfterRemoval = await coordinator.dnrSnapshot(for: extensionID)
        XCTAssertTrue(mutationApplied)
        XCTAssertNil(snapshotAfterRemoval)
        XCTAssertNil(runtime.policySnapshot(for: extensionID))
        await assertAsyncThrows {
            _ = try await coordinator.updateDynamicRules(
                addRules: [
                    .init(
                        id: 2,
                        action: .init(type: .block),
                        condition: .init(urlFilter: "still-stale.example")
                    )
                ],
                removeRuleIDs: [],
                for: self.extensionID
            )
        }
    }

    func testCSSRefusesTheOtherProfileBeforeMutatingPagePolicy() async throws {
        let runtime = FloorpWebExtensionRuntime(contentRuleListCompiler: CoordinatorRuleListCompiler())
        let coordinator = makeCoordinator(runtime: runtime)
        let tab = testTab()
        let host = try FloorpWebExtensionMatchPattern("https://allowed.example/*")
        await coordinator.grantPermissions(
            [.scripting],
            requestedHosts: [host],
            hostAccess: .allRequestedSites,
            to: extensionID
        )
        let webView = WKWebView(frame: .zero, configuration: .init())
        let target = FloorpWebExtensionCSSTarget(tab: tab)
        let insertion = try await coordinator.insertCSS(
            ".coordinator { display: none; }",
            for: extensionID,
            target: target,
            tab: tab,
            into: webView,
            validateLiveTarget: {}
        )
        try await coordinator.removeCSS(
            [insertion.handle],
            for: extensionID,
            target: target,
            tab: tab,
            from: webView,
            validateLiveTarget: {}
        )

        let privateTab = testTab(isPrivate: true)
        await assertAsyncThrows {
            _ = try await coordinator.insertCSS(
                ".blocked { display: none; }",
                for: self.extensionID,
                target: .init(tab: privateTab),
                tab: privateTab,
                into: webView,
                validateLiveTarget: {}
            )
        }
    }

    private func makeCoordinator(
        profileIdentifier: String = "coordinator-test",
        isPrivateBrowsing: Bool = false,
        runtime: FloorpWebExtensionRuntime
    ) -> FloorpWebExtensionCoordinator {
        FloorpWebExtensionCoordinator(
            profileIdentifier: profileIdentifier,
            isPrivateBrowsing: isPrivateBrowsing,
            runtime: runtime,
            scriptResourceLoader: { _, source in
                switch source.path {
                case "content.js":
                    return "window.coordinatorContent = true;"
                default:
                    throw FloorpWebExtensionError.unsupported("test resource \(source.path)")
                }
            }
        )
    }

    private func registeredScript(
        id: String,
        matches: [FloorpWebExtensionMatchPattern]? = nil,
        source: String,
        allFrames: Bool = false
    ) throws -> FloorpWebExtensionRegisteredScript {
        try .init(
            id: id,
            matches: matches ?? [try FloorpWebExtensionMatchPattern("https://allowed.example/*")],
            javaScript: [try FloorpWebExtensionScriptSource(source)],
            allFrames: allFrames
        )
    }

    private func testTab(isPrivate: Bool = false) -> FloorpWebExtensionTabContext {
        FloorpWebExtensionTabContext(
            tabID: 9,
            documentGeneration: 1,
            url: URL(string: "https://allowed.example/page")!,
            isPrivate: isPrivate
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
            // State assertions in the caller validate the failure boundary.
        }
    }
}

@MainActor
private final class CoordinatorRuleListCompiler: FloorpWebExtensionContentRuleListCompiling {
    enum Failure: Error {
        case expected
    }

    var shouldFail = false
    var pauseNextCompilation = false
    private let store: WKContentRuleListStore
    private var compilationStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floorp-webextension-coordinator-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)!
    }

    func compileContentRuleList(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList {
        if shouldFail {
            throw Failure.expected
        }
        let ruleList: WKContentRuleList = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WKContentRuleList, Error>) in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedContentRuleList
            ) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: Failure.expected)
                }
            }
        }
        if pauseNextCompilation {
            pauseNextCompilation = false
            compilationStarted = true
            startedContinuation?.resume()
            startedContinuation = nil
            await withCheckedContinuation { continuation in
                pauseContinuation = continuation
            }
        }
        return ruleList
    }

    func waitUntilCompilationPaused() async {
        guard !compilationStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func resumePausedCompilation() {
        guard let pauseContinuation else {
            XCTFail("Expected a paused DNR compilation")
            return
        }
        self.pauseContinuation = nil
        pauseContinuation.resume()
    }

    func removeContentRuleList(forIdentifier identifier: String) async {
        await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}
