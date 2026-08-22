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
            into: webView
        )
        try await coordinator.removeCSS(
            [insertion.handle],
            for: extensionID,
            target: target,
            from: webView
        )

        let privateTab = testTab(isPrivate: true)
        await assertAsyncThrows {
            _ = try await coordinator.insertCSS(
                ".blocked { display: none; }",
                for: self.extensionID,
                target: .init(tab: privateTab),
                tab: privateTab,
                into: webView
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
        source: String
    ) throws -> FloorpWebExtensionRegisteredScript {
        .init(
            id: id,
            matches: [try FloorpWebExtensionMatchPattern("https://allowed.example/*")],
            javaScript: [try FloorpWebExtensionScriptSource(source)]
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
    private let store: WKContentRuleListStore

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
        return try await withCheckedThrowingContinuation { continuation in
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
    }

    func removeContentRuleList(forIdentifier identifier: String) async {
        await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}
