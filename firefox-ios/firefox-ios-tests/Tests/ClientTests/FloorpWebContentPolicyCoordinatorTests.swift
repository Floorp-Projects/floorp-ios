// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import WebKit
import XCTest
@testable import Client

@MainActor
final class FloorpWebContentPolicyCoordinatorTests: XCTestCase {
    private var compiledRuleListIdentifiers = [String]()

    override func tearDown() {
        let store = WKContentRuleListStore.default()!
        compiledRuleListIdentifiers.forEach { identifier in
            store.removeContentRuleList(forIdentifier: identifier) { _ in }
        }
        compiledRuleListIdentifiers.removeAll()
        super.tearDown()
    }

    func testReplacingBrowserScriptsPreservesExtensionScripts() {
        let controller = WKUserContentController()
        let coordinator = FloorpWebContentPolicyCoordinator.coordinator(for: controller)
        let browserScript = userScript("window.floorpBrowserPolicy = 'initial';")
        let updatedBrowserScript = userScript("window.floorpBrowserPolicy = 'updated';")
        let extensionScript = userScript("window.floorpExtensionPolicy = true;")

        coordinator.replaceUserScripts([browserScript], ownedBy: "browser.core")
        coordinator.replaceUserScripts([extensionScript], ownedBy: "extension.fixture")
        coordinator.replaceUserScripts([updatedBrowserScript], ownedBy: "browser.core")

        XCTAssertEqual(
            controller.userScripts.map(\.source),
            [updatedBrowserScript.source, extensionScript.source]
        )
    }

    func testReplacingTrackingNoImageAndDNROwnersPreservesOtherRuleLists() async throws {
        let controller = RecordingUserContentController()
        let coordinator = FloorpWebContentPolicyCoordinator.coordinator(for: controller)
        let trackingV1 = try await contentRuleList(named: "tracking-v1")
        let noImage = try await contentRuleList(named: "no-image")
        let dnr = try await contentRuleList(named: "dnr")
        let trackingV2 = try await contentRuleList(named: "tracking-v2")

        coordinator.replaceContentRuleLists([trackingV1], ownedBy: "browser.tracking")
        coordinator.replaceContentRuleLists([noImage], ownedBy: "browser.no-image")
        coordinator.replaceContentRuleLists([dnr], ownedBy: "extension.dnr")
        coordinator.replaceContentRuleLists([trackingV2], ownedBy: "browser.tracking")

        XCTAssertEqual(
            controller.attachedContentRuleListIdentifiers,
            [trackingV2.identifier, noImage.identifier, dnr.identifier]
        )
        XCTAssertEqual(controller.removedContentRuleListIdentifiers, [trackingV1.identifier])
        XCTAssertFalse(controller.removeAllContentRuleListsWasCalled)
    }

    func testRemovingAnOwnerLeavesOtherScriptAndRuleListOwnersInPlace() async throws {
        let controller = RecordingUserContentController()
        let coordinator = FloorpWebContentPolicyCoordinator.coordinator(for: controller)
        let browserScript = userScript("window.floorpBrowserPolicy = true;")
        let extensionScript = userScript("window.floorpExtensionPolicy = true;")
        let tracking = try await contentRuleList(named: "tracking")
        let noImage = try await contentRuleList(named: "no-image")
        let dnr = try await contentRuleList(named: "dnr")

        coordinator.replaceUserScripts([browserScript], ownedBy: "browser.core")
        coordinator.replaceUserScripts([extensionScript], ownedBy: "extension.fixture")
        coordinator.replaceContentRuleLists([tracking], ownedBy: "browser.tracking")
        coordinator.replaceContentRuleLists([noImage], ownedBy: "browser.no-image")
        coordinator.replaceContentRuleLists([dnr], ownedBy: "extension.dnr")

        coordinator.removeUserScripts(ownedBy: "browser.core")
        coordinator.removeContentRuleLists(ownedBy: "browser.tracking")

        XCTAssertEqual(controller.userScripts.map(\.source), [extensionScript.source])
        XCTAssertEqual(
            controller.attachedContentRuleListIdentifiers,
            [noImage.identifier, dnr.identifier]
        )
        XCTAssertEqual(controller.removedContentRuleListIdentifiers, [tracking.identifier])
        XCTAssertFalse(controller.removeAllContentRuleListsWasCalled)
    }

    private func userScript(_ source: String) -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private func contentRuleList(named purpose: String) async throws -> WKContentRuleList {
        let identifier = "floorp-policy-test-\(purpose)-\(UUID().uuidString)"
        compiledRuleListIdentifiers.append(identifier)
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: """
                [{
                    "trigger": { "url-filter": ".*" },
                    "action": { "type": "block" }
                }]
                """
            ) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: ContentRuleListCompilationError.missingRuleList)
                }
            }
        }
    }
}

@MainActor
private final class RecordingUserContentController: WKUserContentController {
    private(set) var attachedContentRuleListIdentifiers = Set<String>()
    private(set) var removedContentRuleListIdentifiers = [String]()
    private(set) var removeAllContentRuleListsWasCalled = false

    override func add(_ contentRuleList: WKContentRuleList) {
        super.add(contentRuleList)
        attachedContentRuleListIdentifiers.insert(contentRuleList.identifier)
    }

    override func remove(_ contentRuleList: WKContentRuleList) {
        super.remove(contentRuleList)
        attachedContentRuleListIdentifiers.remove(contentRuleList.identifier)
        removedContentRuleListIdentifiers.append(contentRuleList.identifier)
    }

    override func removeAllContentRuleLists() {
        super.removeAllContentRuleLists()
        attachedContentRuleListIdentifiers.removeAll()
        removeAllContentRuleListsWasCalled = true
    }
}

private enum ContentRuleListCompilationError: Error {
    case missingRuleList
}
