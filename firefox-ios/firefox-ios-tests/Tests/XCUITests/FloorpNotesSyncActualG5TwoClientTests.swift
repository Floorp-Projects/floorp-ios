// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest

@MainActor
final class FloorpNotesSyncActualG5TwoClientTests: XCTestCase {
    private enum SummaryError: Error {
        case notAnObject
    }

    private static let requiredCases = [
        "desktop-create-mobile-sync-desktop-recheck",
        "mobile-create-desktop-sync-mobile-recheck",
        "same-record-concurrent-edit",
        "update-delete-conflict",
        "offline-edit-reconnect-retry",
        "upload-save-commit-failure",
        "restart-preserves-unsynced-local-data",
        "old-new-client-mixed",
        "large-empty-multiple-records",
        "account-switch-isolation",
        "retry-idempotence",
        "base-revision-confirmation-gate"
    ]

    private static let requiredInvariants = [
        "no-data-loss",
        "no-duplicate-records",
        "no-incorrect-delete-or-resurrection",
        "no-account-mixing",
        "no-rollback-on-retry",
        "base-revision-after-confirmation-only"
    ]

    func testActualG5TwoClientProductionMatrix() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLOORP_NOTES_SYNC_PRODUCTION_QA"] == "1" else {
            XCTFail("PRODUCTION_QA_NOT_AUTHORIZED")
            return
        }
        guard let resultPath = environment["FLOORP_NOTES_SYNC_QA_RESULT"],
              !resultPath.isEmpty else {
            XCTFail("CLIENT_PAIR_RESULT_MISSING")
            return
        }

        let summary = try loadSummary(from: resultPath)
        assertEnvelope(summary)
        assertSource(summary, environment: environment)
        assertCases(summary)
        assertInvariants(summary)
        assertNetwork(summary)
        assertCleanup(summary)
        assertAttestation(summary)
    }

    private func loadSummary(from path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let summary = object as? [String: Any] else {
            throw SummaryError.notAnObject
        }
        return summary
    }

    private func assertEnvelope(_ summary: [String: Any]) {
        XCTAssertEqual(summary["schema_version"] as? Int, 1)
        XCTAssertEqual(summary["phase"] as? String, "production-qa")
        XCTAssertEqual(summary["environment"] as? String, "floorp-notes-sync-production-qa")
        XCTAssertEqual(summary["accounts"] as? Int, 2)
        XCTAssertEqual(summary["clients"] as? [String], ["desktop", "mobile"])
        XCTAssertEqual(summary["public_release"] as? Bool, false)
        XCTAssertEqual(summary["phase_2_enablement_ready"] as? Bool, true)
    }

    private func assertSource(_ summary: [String: Any], environment: [String: String]) {
        guard let source = summary["source"] as? [String: Any] else {
            XCTFail("CLIENT_PAIR_RESULT_SOURCE_MISSING")
            return
        }
        XCTAssertEqual(source["event"] as? String, "workflow_dispatch")
        XCTAssertEqual(source["job_name"] as? String, "notes-sync-production-qa")
        XCTAssertEqual(source["repository"] as? String, "Floorp-Projects/floorp-ios")
        XCTAssertEqual(source["workflow_path"] as? String, ".github/workflows/ci.yml")
        XCTAssertEqual(source["head_sha"] as? String, environment["GITHUB_SHA"])
        XCTAssertEqual(source["workflow_run_id"] as? Int, Int(environment["GITHUB_RUN_ID"] ?? ""))
        XCTAssertEqual(
            source["workflow_run_attempt"] as? Int,
            Int(environment["GITHUB_RUN_ATTEMPT"] ?? "")
        )
        XCTAssertTrue(
            (environment["GITHUB_WORKFLOW_REF"] ?? "")
                .hasPrefix("Floorp-Projects/floorp-ios/.github/workflows/ci.yml@")
        )
        guard let attestation = summary["self_attestation"] as? [String: Any] else {
            XCTFail("CLIENT_PAIR_RESULT_ATTESTATION_MISSING")
            return
        }
        XCTAssertEqual(attestation["operator_id"] as? String, environment["GITHUB_ACTOR"])
    }

    private func assertCases(_ summary: [String: Any]) {
        guard let cases = summary["cases"] as? [[String: Any]],
              cases.count == Self.requiredCases.count else {
            XCTFail("CLIENT_PAIR_RESULT_CASES_INCOMPLETE")
            return
        }
        for (index, name) in Self.requiredCases.enumerated() {
            XCTAssertEqual(cases[index]["name"] as? String, name)
            XCTAssertEqual(cases[index]["passed"] as? Bool, true)
        }
    }

    private func assertInvariants(_ summary: [String: Any]) {
        guard let invariants = summary["invariants"] as? [String: Bool] else {
            XCTFail("CLIENT_PAIR_RESULT_INVARIANTS_MISSING")
            return
        }
        for name in Self.requiredInvariants {
            XCTAssertEqual(invariants[name], true)
        }
    }

    private func assertNetwork(_ summary: [String: Any]) {
        guard let network = summary["network"] as? [String: Any] else {
            XCTFail("CLIENT_PAIR_RESULT_NETWORK_MISSING")
            return
        }
        XCTAssertEqual(network["direct_rest_used"] as? Bool, false)
        XCTAssertEqual(network["metadata_only"] as? Bool, true)
        XCTAssertEqual(network["tls_verified"] as? Bool, true)
        XCTAssertEqual(network["wire_protocol"] as? String, "sync15")
    }

    private func assertCleanup(_ summary: [String: Any]) {
        guard let cleanup = summary["cleanup"] as? [String: Bool] else {
            XCTFail("CLIENT_PAIR_RESULT_CLEANUP_MISSING")
            return
        }
        XCTAssertTrue(cleanup.values.allSatisfy { $0 })
    }

    private func assertAttestation(_ summary: [String: Any]) {
        guard let attestation = summary["self_attestation"] as? [String: Any] else {
            XCTFail("CLIENT_PAIR_RESULT_ATTESTATION_MISSING")
            return
        }
        XCTAssertEqual(attestation["approved"] as? Bool, true)
        XCTAssertEqual(
            attestation["roles"] as? [String],
            ["owner", "operations", "executor"]
        )
    }
}
