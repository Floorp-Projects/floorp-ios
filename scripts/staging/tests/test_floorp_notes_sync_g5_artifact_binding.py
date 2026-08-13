"""TDD contract for offline G5 artifact-provenance binding.

These tests validate caller-supplied metadata only.  They do not retrieve an
artifact, authorize G5, or access any account, credential, browser, or device.
"""

from __future__ import annotations

import copy
import unittest
from collections.abc import Iterator, Mapping

from scripts.staging.floorp_notes_sync_g5_artifact_binding import (
    ArtifactBindingError,
    validate_artifact_provenance_binding,
)
from scripts.staging.floorp_notes_sync_g5_receipt import (
    EXPECTED_REPOSITORY,
    EXPECTED_WORKFLOW_PATH,
)


HEAD_SHA = "a" * 40
ZIP_SHA256 = "b" * 64
RECEIPT_MEMBER_SHA256 = "c" * 64
ARTIFACT_NAME = "floorp-notes-sync-two-client-xcresult"


class AlwaysEqual:
    def __eq__(self, _: object) -> bool:
        return True


class ForgedString(str):
    def __eq__(self, _: object) -> bool:
        return True


class MappingProxy(Mapping[str, object]):
    def __init__(self, values: dict[str, object]) -> None:
        self._values = values

    def __getitem__(self, key: str) -> object:
        return self._values[key]

    def __iter__(self) -> Iterator[str]:
        return iter(self._values)

    def __len__(self) -> int:
        return len(self._values)


def expected_run_binding() -> dict[str, object]:
    return {
        "head_sha": HEAD_SHA,
        "repository": EXPECTED_REPOSITORY,
        "run_attempt": 1,
        "run_id": 123456789,
        "workflow_path": EXPECTED_WORKFLOW_PATH,
    }


def receipt_metadata() -> dict[str, object]:
    return {
        "execution_authorization": "not-granted",
        "g5_result": "not-assessed",
        "run_binding": expected_run_binding(),
        "status": "receipt-valid",
    }


def provenance_snapshot() -> dict[str, object]:
    return {
        "artifact_id": 987654321,
        "artifact_name": ARTIFACT_NAME,
        "artifact_run_id": 123456789,
        "artifact_zip_sha256": ZIP_SHA256,
        "head_sha": HEAD_SHA,
        "receipt_member_sha256": RECEIPT_MEMBER_SHA256,
        "repository": EXPECTED_REPOSITORY,
        "run_attempt": 1,
        "run_id": 123456789,
        "workflow_path": EXPECTED_WORKFLOW_PATH,
    }


def expected_artifact_binding() -> dict[str, object]:
    return provenance_snapshot()


class FloorpNotesSyncG5ArtifactBindingTests(unittest.TestCase):
    def test_accepts_exact_receipt_metadata_and_bound_snapshot(self) -> None:
        decision = validate_artifact_provenance_binding(
            receipt_metadata(),
            provenance_snapshot(),
            expected_artifact_binding=expected_artifact_binding(),
        )

        self.assertEqual(decision["status"], "artifact-binding-valid")
        self.assertEqual(decision["artifact_provenance"], "binding-valid")
        self.assertEqual(decision["execution_authorization"], "not-granted")
        self.assertEqual(decision["g5_result"], "not-assessed")
        self.assertEqual(decision["run_binding"], expected_run_binding())

    def test_rejects_non_receipt_valid_metadata_and_extra_fields(self) -> None:
        mutations = (
            ("status", "g5-passed"),
            ("execution_authorization", "granted"),
            ("g5_result", "passed"),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                metadata = receipt_metadata()
                metadata[key] = value
                with self.assertRaises(ArtifactBindingError):
                    validate_artifact_provenance_binding(
                        metadata, provenance_snapshot(), expected_artifact_binding=expected_artifact_binding()
                    )

        metadata = receipt_metadata()
        metadata["extra"] = "value"
        with self.assertRaises(ArtifactBindingError):
            validate_artifact_provenance_binding(
                metadata, provenance_snapshot(), expected_artifact_binding=expected_artifact_binding()
            )

    def test_rejects_wrong_artifact_identity_or_digest(self) -> None:
        for key, value in (
            ("artifact_name", "wrong-artifact"),
            ("artifact_zip_sha256", "B" * 64),
            ("artifact_zip_sha256", "b" * 63),
            ("receipt_member_sha256", "c" * 63),
            ("receipt_member_sha256", "d" * 64),
            ("artifact_id", 0),
            ("artifact_id", True),
            ("artifact_id", 1.0),
        ):
            with self.subTest(key=key, value=value):
                snapshot = provenance_snapshot()
                snapshot[key] = value
                with self.assertRaises(ArtifactBindingError):
                    validate_artifact_provenance_binding(
                        receipt_metadata(), snapshot, expected_artifact_binding=expected_artifact_binding()
                    )

    def test_rejects_every_run_binding_mismatch(self) -> None:
        for key, value in (
            ("repository", "Floorp-Projects/other"),
            ("workflow_path", ".github/workflows/other.yml"),
            ("run_id", 123456790),
            ("run_attempt", 2),
            ("head_sha", "d" * 40),
            ("artifact_run_id", 123456790),
        ):
            with self.subTest(key=key):
                snapshot = provenance_snapshot()
                snapshot[key] = value
                with self.assertRaises(ArtifactBindingError):
                    validate_artifact_provenance_binding(
                        receipt_metadata(), snapshot, expected_artifact_binding=expected_artifact_binding()
                    )

    def test_rejects_non_builtin_objects_and_equality_forgery(self) -> None:
        for metadata, snapshot, expected in (
            (MappingProxy(receipt_metadata()), provenance_snapshot(), expected_artifact_binding()),
            (receipt_metadata(), MappingProxy(provenance_snapshot()), expected_artifact_binding()),
            (receipt_metadata(), provenance_snapshot(), MappingProxy(expected_artifact_binding())),
        ):
            with self.subTest(value_type=type(metadata).__name__):
                with self.assertRaises(ArtifactBindingError):
                    validate_artifact_provenance_binding(
                        metadata, snapshot, expected_artifact_binding=expected  # type: ignore[arg-type]
                    )

        for container, key in (
            ("metadata", "status"),
            ("snapshot", "artifact_name"),
            ("expected", "repository"),
        ):
            with self.subTest(container=container):
                metadata = receipt_metadata()
                snapshot = provenance_snapshot()
                expected = expected_artifact_binding()
                target = {"metadata": metadata, "snapshot": snapshot, "expected": expected}[container]
                target[key] = ForgedString(str(target[key]))
                with self.assertRaises(ArtifactBindingError):
                    validate_artifact_provenance_binding(
                        metadata, snapshot, expected_artifact_binding=expected
                    )

        metadata = receipt_metadata()
        metadata["status"] = AlwaysEqual()
        with self.assertRaises(ArtifactBindingError):
            validate_artifact_provenance_binding(
                metadata, provenance_snapshot(), expected_artifact_binding=expected_artifact_binding()
            )

    def test_rejects_bool_int_aliases_unsafe_hashes_and_extra_snapshot_keys(self) -> None:
        for key, value in (
            ("run_id", True),
            ("run_attempt", False),
            ("artifact_run_id", True),
            ("run_id", 9_007_199_254_740_992),
            ("head_sha", "A" * 40),
            ("head_sha", "x" * 40),
        ):
            with self.subTest(key=key, value=value):
                snapshot = provenance_snapshot()
                snapshot[key] = value
                with self.assertRaises(ArtifactBindingError):
                    validate_artifact_provenance_binding(
                        receipt_metadata(), snapshot, expected_artifact_binding=expected_artifact_binding()
                    )

        snapshot = copy.deepcopy(provenance_snapshot())
        snapshot["unexpected"] = "value"
        with self.assertRaises(ArtifactBindingError):
            validate_artifact_provenance_binding(
                receipt_metadata(), snapshot, expected_artifact_binding=expected_artifact_binding()
            )


if __name__ == "__main__":
    unittest.main()
