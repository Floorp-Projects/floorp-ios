"""TDD contract for the fail-closed G5 evidence-admission boundary."""

from __future__ import annotations

import copy
import unittest

from scripts.staging.floorp_notes_sync_g5_admission import (
    AdmissionError,
    CI_WORKFLOW_PATH,
    G5_CI_EVENT,
    G5_CI_HEAD_BRANCH,
    G5_ARTIFACT_NAME,
    G5_ARTIFACT_KIND,
    G5_REQUIRED_SYNC_HOST,
    G5_TEST,
    RELEASE_VALIDATOR,
    validate_admission_contract,
)


IOS_REPOSITORY = "Floorp-Projects/floorp-ios"
ACTUAL_G5_TEST = "FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix()"
FXA_HOSTS = [
    "accounts.firefox.com",
    "api.accounts.firefox.com",
    "oauth.accounts.firefox.com",
    "profile.accounts.firefox.com",
    "static.accounts.firefox.com",
]
SYNC_HOSTS = [
    "event-sync.services.mozilla.com",
    "sync.services.mozilla.com",
    "token.services.mozilla.com",
]


def valid_admission_contract() -> dict[str, object]:
    return {
        "artifact_contract": {
            "artifact_kind": "github-actions-artifact",
            "artifact_name": "floorp-notes-sync-two-client-xcresult",
            "required_test": ACTUAL_G5_TEST,
            "retrieval": "required-after-run",
        },
        "boundary": {
            "credential_delivery": "protected-environment-only",
            "execution_authorization": "not-authorized",
            "g5_result": "not-assessed",
            "runner_receipts_accepted": False,
        },
        "candidate": {
            "head_sha": "a" * 40,
            "repository": IOS_REPOSITORY,
        },
        "isolation_contract": {
            "accounts": 2,
            "cleanup_required": True,
            "local_only_fallback_required": True,
            "payload_retained": False,
            "rollback_required": True,
            "secrets_retained": False,
        },
        "network_contract": {
            "hosts": sorted(FXA_HOSTS + SYNC_HOSTS),
            "metadata_only": True,
            "payload_retained": False,
            "port": 443,
            "secrets_retained": False,
            "tls_interception": False,
            "tls_verified": True,
        },
        "schema_version": 1,
        "workflow": {
            "event": "workflow_dispatch",
            "head_branch": "main",
            "path": ".github/workflows/floorp-notes-sync-production-qa.yml",
        },
    }


class FloorpNotesSyncG5AdmissionTests(unittest.TestCase):
    def test_binds_g5_protocol_constants_to_release_validator(self) -> None:
        self.assertEqual(CI_WORKFLOW_PATH, RELEASE_VALIDATOR.G5_CI_WORKFLOW_PATH)
        self.assertEqual(G5_CI_EVENT, RELEASE_VALIDATOR.G5_CI_EVENT)
        self.assertEqual(G5_CI_HEAD_BRANCH, RELEASE_VALIDATOR.G5_CI_HEAD_BRANCH)
        self.assertEqual(G5_ARTIFACT_NAME, RELEASE_VALIDATOR.G5_XCRESULT_ARTIFACT_NAME)
        self.assertEqual(G5_ARTIFACT_KIND, RELEASE_VALIDATOR.G5_XCRESULT_ARTIFACT_KIND)
        self.assertEqual(G5_REQUIRED_SYNC_HOST, RELEASE_VALIDATOR.G5_REQUIRED_SYNC_HOST)
        self.assertEqual(G5_TEST, RELEASE_VALIDATOR.G5_ACTUAL_TWO_CLIENT_XCRESULT_TEST)

    def test_exact_contract_is_not_execution_authorization(self) -> None:
        decision = validate_admission_contract(valid_admission_contract())

        self.assertEqual(decision["status"], "admission-contract-valid")
        self.assertEqual(decision["execution_authorization"], "not-authorized")
        self.assertEqual(decision["g5_result"], "not-assessed")
        self.assertEqual(decision["cleanup_boundary"], "not-established")
        self.assertEqual(decision["artifact_retrieval"], "required-after-run")

    def test_rejects_arbitrary_runner_receipt_and_execution_authorization(self) -> None:
        for key, value in (
            ("runner", "/usr/local/bin/untrusted-runner"),
            ("runnerReceipt", {"g5": "passed"}),
            ("execution_authorization", "authorized"),
        ):
            with self.subTest(key=key):
                contract = valid_admission_contract()
                if key == "execution_authorization":
                    contract["boundary"][key] = value
                else:
                    contract[key] = value
                with self.assertRaises(AdmissionError):
                    validate_admission_contract(contract)

    def test_rejects_non_main_dispatch_missing_artifact_and_missing_sync_host(self) -> None:
        mutations = (
            (("workflow", "head_branch"), "agent/untrusted", "non-main dispatch"),
            (("artifact_contract", "retrieval"), "not-required", "artifact omission"),
            (("network_contract", "hosts"), FXA_HOSTS, "missing Sync host"),
        )
        for path, value, label in mutations:
            with self.subTest(label=label):
                contract = valid_admission_contract()
                target: dict[str, object] = contract
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(AdmissionError):
                    validate_admission_contract(contract)

    def test_rejects_malformed_or_duplicate_network_hosts(self) -> None:
        malformed_hosts = (
            [["sync.services.mozilla.com"]],
            [{"host": "sync.services.mozilla.com"}],
            valid_admission_contract()["network_contract"]["hosts"] + ["sync.services.mozilla.com"],
        )
        for hosts in malformed_hosts:
            with self.subTest(hosts=hosts):
                contract = valid_admission_contract()
                contract["network_contract"]["hosts"] = hosts
                with self.assertRaises(AdmissionError):
                    validate_admission_contract(contract)

    def test_accepts_validator_permitted_approved_host_subset(self) -> None:
        contract = valid_admission_contract()
        contract["network_contract"]["hosts"] = ["sync.services.mozilla.com"]

        decision = validate_admission_contract(contract)

        self.assertEqual(decision["status"], "admission-contract-valid")

    def test_rejects_secret_aliases_and_unproved_cleanup(self) -> None:
        aliases = (
            "authorizationHeader",
            "authorization-header",
            "authorization_header",
            "notePayload",
            "note-payload",
            "note_payload",
            "rawSyncKey",
            "raw-sync-key",
            "raw_sync_key",
        )
        for alias in aliases:
            with self.subTest(alias=alias):
                contract = valid_admission_contract()
                contract["network_contract"][alias] = "not-a-secret"
                with self.assertRaises(AdmissionError):
                    validate_admission_contract(contract)

        contract = copy.deepcopy(valid_admission_contract())
        contract["isolation_contract"]["cleanup_required"] = False
        with self.assertRaises(AdmissionError):
            validate_admission_contract(contract)


if __name__ == "__main__":
    unittest.main()
