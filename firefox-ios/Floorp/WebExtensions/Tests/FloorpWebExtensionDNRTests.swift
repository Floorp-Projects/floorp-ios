// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import Client

final class FloorpWebExtensionDNRTests: XCTestCase {
    func testSupportedStaticRulesCompileToWebKitJSONWithDiagnostics() async throws {
        let acceptedRule = FloorpWebExtensionDNRRule(
            id: 1,
            priority: 2,
            action: .init(type: .block),
            condition: .init(regexFilter: "^https?://ads\\.example/", resourceTypes: [.script])
        )
        let transformedRule = FloorpWebExtensionDNRRule(
            id: 2,
            priority: 1,
            action: .init(type: .upgradeScheme),
            condition: .init(
                urlFilter: "||example.org^",
                requestDomains: ["example.org"],
                excludedResourceTypes: [.image]
            )
        )
        let store = try FloorpWebExtensionDNRStore(
            staticRuleSets: [.init(identifier: "default", rules: [acceptedRule, transformedRule])],
            enabledStaticRuleSetIDs: ["default"]
        )

        let compilation = await store.currentCompilation()
        XCTAssertEqual(compilation.report.acceptedRuleCount, 1)
        XCTAssertEqual(compilation.report.transformedRuleCount, 1)
        XCTAssertEqual(compilation.report.rejectedRuleCount, 0)

        let contentRules = try decodedContentRules(compilation.webKitContentRuleJSON)
        XCTAssertEqual(contentRules.count, 2)
        XCTAssertTrue(contentRules.contains { $0.actionType == "block" })
        XCTAssertTrue(contentRules.contains { $0.actionType == "make-https" })
        XCTAssertTrue(contentRules.contains { $0.ifDomains == ["*example.org"] })
    }

    func testUnsupportedDynamicRuleRollsBackAtomically() async throws {
        let store = try FloorpWebExtensionDNRStore()
        let supported = FloorpWebExtensionDNRRule(
            id: 10,
            action: .init(type: .block),
            condition: .init(urlFilter: "||ads.example^")
        )
        try await store.updateDynamicRules(addRules: [supported], removeRuleIDs: [])
        let before = await store.snapshot()

        let unsupported = FloorpWebExtensionDNRRule(
            id: 11,
            action: .init(type: .redirect),
            condition: .init(urlFilter: "||ads.example^")
        )
        do {
            try await store.updateDynamicRules(addRules: [unsupported], removeRuleIDs: [])
            XCTFail("An unsupported action must fail closed")
        } catch FloorpWebExtensionDNRError.incompatibleRules(let report) {
            XCTAssertEqual(report.rejectedRuleCount, 1)
            let rejectedEntry = report.entries.first { $0.ruleID == unsupported.id }
            XCTAssertEqual(rejectedEntry?.reasons, [
                "redirect is not available in the iOS 15 WebKit content-rule subset"
            ])
        }

        let after = await store.snapshot()
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(after.dynamicRules, [supported])
        XCTAssertEqual(after.compilation.webKitContentRuleJSON, before.compilation.webKitContentRuleJSON)
    }

    func testDuplicateIDsAndQuotaFailBeforeStateChanges() async throws {
        let store = try FloorpWebExtensionDNRStore(
            limits: .init(
                maxStaticRules: 10,
                maxEnabledStaticRuleSets: 2,
                maxDynamicRules: 1,
                maxSessionRules: 1,
                maxRulesPerUpdate: 4
            )
        )
        let first = FloorpWebExtensionDNRRule(
            id: 20,
            action: .init(type: .block),
            condition: .init(regexFilter: "^https://one\\.example/")
        )
        let duplicate = FloorpWebExtensionDNRRule(
            id: 20,
            action: .init(type: .block),
            condition: .init(regexFilter: "^https://two\\.example/")
        )

        do {
            try await store.updateDynamicRules(addRules: [first, duplicate], removeRuleIDs: [])
            XCTFail("Duplicate IDs must be rejected")
        } catch FloorpWebExtensionDNRError.duplicateRuleIdentifier(let identifier, let scope) {
            XCTAssertEqual(identifier, 20)
            XCTAssertEqual(scope, .dynamic)
        }
        let rulesAfterDuplicateFailure = await store.getDynamicRules()
        XCTAssertTrue(rulesAfterDuplicateFailure.isEmpty)

        try await store.updateDynamicRules(addRules: [first], removeRuleIDs: [])
        let second = FloorpWebExtensionDNRRule(
            id: 21,
            action: .init(type: .block),
            condition: .init(regexFilter: "^https://three\\.example/")
        )
        do {
            try await store.updateDynamicRules(addRules: [second], removeRuleIDs: [])
            XCTFail("The configured limit must be enforced")
        } catch FloorpWebExtensionDNRError.quotaExceeded(let scope, let limit) {
            XCTAssertEqual(scope, .dynamic)
            XCTAssertEqual(limit, 1)
        }
        let rulesAfterQuotaFailure = await store.getDynamicRules()
        XCTAssertEqual(rulesAfterQuotaFailure, [first])
    }

    func testSessionRulesAreClearedWithoutChangingDynamicOrStaticRules() async throws {
        let staticRule = FloorpWebExtensionDNRRule(
            id: 30,
            action: .init(type: .block),
            condition: .init(regexFilter: "^https://static\\.example/")
        )
        let store = try FloorpWebExtensionDNRStore(
            staticRuleSets: [.init(identifier: "static-rules", rules: [staticRule])],
            enabledStaticRuleSetIDs: ["static-rules"]
        )
        let dynamicRule = FloorpWebExtensionDNRRule(
            id: 31,
            action: .init(type: .block),
            condition: .init(regexFilter: "^https://dynamic\\.example/")
        )
        let sessionRule = FloorpWebExtensionDNRRule(
            id: 32,
            action: .init(type: .block),
            condition: .init(regexFilter: "^https://session\\.example/")
        )

        try await store.updateDynamicRules(addRules: [dynamicRule], removeRuleIDs: [])
        try await store.updateSessionRules(addRules: [sessionRule], removeRuleIDs: [])
        try await store.clearSessionRules()

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.enabledStaticRuleSetIDs, ["static-rules"])
        XCTAssertEqual(snapshot.dynamicRules, [dynamicRule])
        XCTAssertTrue(snapshot.sessionRules.isEmpty)
        XCTAssertEqual(snapshot.compilation.compiledRules.count, 2)
    }

    func testAmbiguousAllowPriorityAndUnsupportedRegexAreReported() async throws {
        let store = try FloorpWebExtensionDNRStore()
        let block = FloorpWebExtensionDNRRule(
            id: 40,
            priority: 1,
            action: .init(type: .block),
            condition: .init(urlFilter: "||example.com^")
        )
        let allow = FloorpWebExtensionDNRRule(
            id: 41,
            priority: 1,
            action: .init(type: .allow),
            condition: .init(urlFilter: "||allowed.example.com^")
        )

        do {
            try await store.updateSessionRules(addRules: [block, allow], removeRuleIDs: [])
            XCTFail("Mixed action types at one priority are not safely ordered")
        } catch FloorpWebExtensionDNRError.incompatibleRules(let report) {
            XCTAssertEqual(report.rejectedRuleCount, 2)
            XCTAssertEqual(
                report.countsByReason["mixed action types at the same priority are not provably ordered"],
                2
            )
        }
        let regexSupport = await store.isRegexSupported("(a)\\1")
        XCTAssertFalse(regexSupport.isSupported)
        XCTAssertEqual(regexSupport.reason, "regexFilter uses a backreference")
    }

    func testHigherPriorityUpgradeCannotOverrideLowerPriorityBlock() async throws {
        let store = try FloorpWebExtensionDNRStore()
        let block = FloorpWebExtensionDNRRule(
            id: 50,
            priority: 1,
            action: .init(type: .block),
            condition: .init(urlFilter: "||insecure.example^")
        )
        try await store.updateDynamicRules(addRules: [block], removeRuleIDs: [])
        let before = await store.snapshot()

        let upgrade = FloorpWebExtensionDNRRule(
            id: 51,
            priority: 2,
            action: .init(type: .upgradeScheme),
            condition: .init(urlFilter: "||insecure.example^")
        )
        do {
            try await store.updateSessionRules(addRules: [upgrade], removeRuleIDs: [])
            XCTFail("A WebKit make-https action cannot cancel an earlier block")
        } catch FloorpWebExtensionDNRError.incompatibleRules(let report) {
            let reason = "a higher-priority upgradeScheme cannot override a lower-priority block in WebKit"
            XCTAssertEqual(report.rejectedRuleCount, 2)
            XCTAssertEqual(report.countsByReason[reason], 2)
            XCTAssertEqual(
                Set(report.entries.filter { $0.status == .rejected }.map(\.ruleID)),
                [block.id, upgrade.id]
            )
        }

        let after = await store.snapshot()
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(after.dynamicRules, before.dynamicRules)
        XCTAssertTrue(after.sessionRules.isEmpty)
        XCTAssertEqual(after.compilation.webKitContentRuleJSON, before.compilation.webKitContentRuleJSON)
    }

    func testHigherPriorityBlockCanFollowLowerPriorityUpgrade() async throws {
        let upgrade = FloorpWebExtensionDNRRule(
            id: 60,
            priority: 1,
            action: .init(type: .upgradeScheme),
            condition: .init(urlFilter: "||insecure.example^")
        )
        let block = FloorpWebExtensionDNRRule(
            id: 61,
            priority: 2,
            action: .init(type: .block),
            condition: .init(urlFilter: "||insecure.example^")
        )
        let store = try FloorpWebExtensionDNRStore(
            staticRuleSets: [.init(identifier: "default", rules: [block, upgrade])],
            enabledStaticRuleSetIDs: ["default"]
        )

        let compilation = await store.currentCompilation()
        XCTAssertEqual(compilation.report.rejectedRuleCount, 0)
        XCTAssertEqual(
            try decodedContentRules(compilation.webKitContentRuleJSON).map(\.actionType),
            ["make-https", "block"]
        )
    }

    private func decodedContentRules(_ json: String) throws -> [(actionType: String, ifDomains: [String]?)] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rawRules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try rawRules.map { rule in
            let action = try XCTUnwrap(rule["action"] as? [String: Any])
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            return (
                try XCTUnwrap(action["type"] as? String),
                trigger["if-domain"] as? [String]
            )
        }
    }
}
