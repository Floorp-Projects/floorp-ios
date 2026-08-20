#!/usr/bin/python3 -I

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from floorp_notes_sync_production_qa_capability import (  # noqa: E402
    APPROVED_FXA_HOSTS,
    APPROVED_SYNC_HOSTS,
    CAPABILITY_VERSION,
    CASE_NAMES,
    CapabilityError,
    ENVIRONMENT,
    INVARIANT_NAMES,
    JOB_NAME,
    PUBLIC_BETA_JOB_NAME,
    PUBLIC_BETA_WORKFLOW_PATH,
    REPOSITORY,
    WORKFLOW_PATH,
    canonical_bytes,
    load_capability,
    sha256_bytes,
    validate_capability,
)


def valid_record() -> dict[str, object]:
    return {
        "accounts": 2,
        "build_contract_mode": "production-qa",
        "clients": ["desktop", "mobile"],
        "contract_sha256": "a" * 64,
        "desktop": {"repository": "Floorp-Projects/Floorp", "source_sha": "b" * 40},
        "endpoint": {
            "endpoint_policy_sha256": "c" * 64,
            "fxa_configuration": "FxAConfig.Server.release",
            "fxa_hosts": APPROVED_FXA_HOSTS,
            "sync_hosts": APPROVED_SYNC_HOSTS,
            "wire_protocol": "sync15",
        },
        "integrity_matrix_sha256": sha256_bytes(
            canonical_bytes({"cases": CASE_NAMES, "invariants": INVARIANT_NAMES})
        ),
        "ios_build_number": "4",
        "public_release": False,
        "schema_version": 1,
        "self_attestation": {
            "approved": True,
            "environment": ENVIRONMENT,
            "operator_id": "operator",
            "roles": ["owner", "operations", "executor"],
        },
        "source": {
            "event": "workflow_dispatch",
            "head_sha": "e" * 40,
            "job_name": JOB_NAME,
            "repository": REPOSITORY,
            "workflow_path": WORKFLOW_PATH,
            "workflow_run_attempt": 1,
            "workflow_run_id": 123,
        },
        "todo20_contract_version": CAPABILITY_VERSION,
    }


class ProductionQACapabilityTests(unittest.TestCase):
    def test_valid_record_is_exact_and_source_bound(self) -> None:
        record = valid_record()
        self.assertEqual(validate_capability(record, expected_source_sha="e" * 40)["accounts"], 2)

    def test_public_release_and_secret_fields_are_rejected(self) -> None:
        record = valid_record()
        record["public_release"] = True
        with self.assertRaises(CapabilityError):
            validate_capability(record)

    def test_public_beta_job_and_workflow_binding_is_accepted(self) -> None:
        record = valid_record()
        record["source"]["job_name"] = PUBLIC_BETA_JOB_NAME
        record["source"]["workflow_path"] = PUBLIC_BETA_WORKFLOW_PATH
        self.assertEqual(validate_capability(record)["source"]["job_name"], PUBLIC_BETA_JOB_NAME)

    def test_contract_and_endpoint_digests_can_be_bound_to_checked_out_bytes(self) -> None:
        record = valid_record()
        self.assertEqual(
            validate_capability(
                record,
                expected_contract_sha="a" * 64,
                expected_endpoint_policy_sha="c" * 64,
            )["contract_sha256"],
            "a" * 64,
        )
        with self.assertRaises(CapabilityError):
            validate_capability(record, expected_contract_sha="f" * 64)
        with self.assertRaises(CapabilityError):
            validate_capability(record, expected_endpoint_policy_sha="f" * 64)
        record = valid_record()
        record["secret"] = "forbidden"
        with self.assertRaises(CapabilityError):
            validate_capability(record)

    def test_loader_requires_canonical_newline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "capability.json"
            path.write_bytes(canonical_bytes(valid_record())[:-1])
            with self.assertRaises(CapabilityError):
                load_capability(path)


if __name__ == "__main__":
    unittest.main()
