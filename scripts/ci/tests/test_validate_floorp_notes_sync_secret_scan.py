"""TDD tests for the metadata-only secret-scan receipt."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-secret-scan.py"
RECORDER = ROOT / "scripts/ci/record-floorp-notes-sync-secret-scan.py"


def load_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


SCAN = load_module(VALIDATOR, "floorp_notes_sync_secret_scan_validator_test")
RECORD = load_module(RECORDER, "floorp_notes_sync_secret_scan_recorder_test")


def receipt() -> dict[str, Any]:
    return {
        "job_name": "notes-sync-production-qa",
        "marker_set_sha256": SCAN.MARKER_SET_SHA256,
        "passed": True,
        "repository": SCAN.REPOSITORY,
        "scan_method": SCAN.SCAN_METHOD,
        "scan_passed": True,
        "secret_env_names": list(SCAN.SECRET_ENV_NAMES),
        "schema_version": 1,
        "scope": list(SCAN.SCOPE),
        "target_digests": [
            {"byte_count": 1, "file_count": 1, "name": name, "sha256": "0" * 64}
            for name in sorted(SCAN.REQUIRED_TARGETS)
        ],
        "source": {
            "head_sha": "0123456789abcdef0123456789abcdef01234567",
            "workflow_path": SCAN.WORKFLOW_PATH,
            "workflow_run_attempt": 1,
            "workflow_run_id": 123456,
        },
    }


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def materialize_targets(root: Path, text: str = "safe\n") -> list[Path]:
    targets = [
        root / "qa-summary.json",
        root / "cleanup-receipt.json",
        root / "floorp-notes-sync-two-client.xcresult",
        root / "xcodebuild.log",
        root / "desktop.log",
        root / "production-qa-capability.json",
        root / "production-qa.xcconfig",
        root / "self-attestation.jsonl",
        root / "review-receipt.json",
    ]
    targets[2].mkdir()
    (targets[2] / "result").write_text(text)
    for target in (*targets[:2], *targets[3:]):
        target.write_text(text)
    return targets


def receipt_for_targets(targets: list[Path]) -> dict[str, Any]:
    value = receipt()
    value["target_digests"] = [SCAN.digest_target(target) for target in targets]
    return value


class ValidateSecretScanReceiptTests(unittest.TestCase):
    def test_exact_receipt_is_bound_to_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            targets = materialize_targets(Path(directory))
            SCAN.validate(receipt_for_targets(targets), "0123456789abcdef0123456789abcdef01234567", 123456, 1, targets)

    def test_scope_or_run_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            targets = materialize_targets(Path(directory))
            value = receipt_for_targets(targets)
            value["scope"] = ["qa-summary"]
            with self.assertRaises(SCAN.SecretScanError):
                SCAN.validate(value, "0123456789abcdef0123456789abcdef01234567", 123456, 1, targets)
            with self.assertRaises(SCAN.SecretScanError):
                SCAN.validate(receipt_for_targets(targets), "fedcba9876543210fedcba9876543210fedcba98", 123456, 1, targets)

    def test_cli_requires_canonical_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "scan.json"
            targets = materialize_targets(root)
            value = receipt_for_targets(targets)
            path.write_bytes(canonical(value))
            self.assertEqual(
                SCAN.main(
                    [
                        "--receipt",
                        str(path),
                        "--head-sha",
                        "0123456789abcdef0123456789abcdef01234567",
                        "--run-id",
                        "123456",
                        "--run-attempt",
                        "1",
                        "--target", str(targets[0]),
                        "--target", str(targets[1]),
                        "--target", str(targets[2]),
                        "--target", str(targets[3]),
                        "--target", str(targets[4]),
                        "--target", str(targets[5]),
                        "--target", str(targets[6]),
                        "--target", str(targets[7]),
                        "--target", str(targets[8]),
                    ]
                ),
                0,
            )

    def test_recorder_hashes_only_declared_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary = root / "qa-summary.json"
            cleanup = root / "cleanup-receipt.json"
            xcresult = root / "floorp-notes-sync-two-client.xcresult"
            log = root / "xcodebuild.log"
            desktop_log = root / "desktop.log"
            capability = root / "production-qa-capability.json"
            xcconfig = root / "production-qa.xcconfig"
            attestation = root / "self-attestation.jsonl"
            xcresult.mkdir()
            (xcresult / "result").write_text("safe metadata\n")
            for path in (summary, cleanup, log, desktop_log, capability, xcconfig, attestation):
                path.write_text("safe metadata\n")
            review_receipt = root / "review-receipt.json"
            review_receipt.write_text("safe metadata\n")
            output = root / "secret-scan.json"
            environment = {
                "GITHUB_REPOSITORY": SCAN.REPOSITORY,
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_RUN_ID": "123456",
                "GITHUB_SHA": "0123456789abcdef0123456789abcdef01234567",
                SCAN.SECRET_ENV_NAMES[0]: "account-a@example.invalid",
                SCAN.SECRET_ENV_NAMES[1]: "A-password-not-for-real-use",
                SCAN.SECRET_ENV_NAMES[2]: "account-b@example.invalid",
                SCAN.SECRET_ENV_NAMES[3]: "B-password-not-for-real-use",
            }
            with patch.dict(RECORD.os.environ, environment, clear=False):
                self.assertEqual(
                    RECORD.main(
                        [
                            "--output", str(output),
                            "--target", str(summary),
                            "--target", str(cleanup),
                            "--target", str(xcresult),
                            "--target", str(log),
                            "--target", str(desktop_log),
                            "--target", str(capability),
                            "--target", str(xcconfig),
                            "--target", str(attestation),
                            "--target", str(review_receipt),
                            "--secret-env", RECORD.SECRET_ENV_NAMES[0],
                            "--secret-env", RECORD.SECRET_ENV_NAMES[1],
                            "--secret-env", RECORD.SECRET_ENV_NAMES[2],
                            "--secret-env", RECORD.SECRET_ENV_NAMES[3],
                        ]
                    ),
                    0,
                )
            value, raw = SCAN.load(output)
            SCAN.validate(value, environment["GITHUB_SHA"], 123456, 1, [summary, cleanup, xcresult, log, desktop_log, capability, xcconfig, attestation, review_receipt])
            self.assertNotIn(b"safe metadata", raw)

    def test_target_digest_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            targets = [
                root / "qa-summary.json",
                root / "cleanup-receipt.json",
                root / "floorp-notes-sync-two-client.xcresult",
                root / "xcodebuild.log",
                root / "desktop.log",
                root / "production-qa-capability.json",
                root / "production-qa.xcconfig",
                root / "self-attestation.jsonl",
                root / "review-receipt.json",
            ]
            targets[2].mkdir()
            (targets[2] / "result").write_text("actual\n")
            for target in (*targets[:2], *targets[3:]):
                target.write_text("actual\n")
            with self.assertRaises(SCAN.SecretScanError):
                SCAN.validate(receipt(), "0123456789abcdef0123456789abcdef01234567", 123456, 1, targets)

    def test_recorder_rejects_exact_secret_value_in_declared_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            targets = materialize_targets(root)
            leaked = "OpaqueSecretValue-12345"
            targets[4].write_text(leaked + "\n")
            output = root / "secret-scan.json"
            environment = {
                "GITHUB_REPOSITORY": RECORD.REPOSITORY,
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_RUN_ID": "123456",
                "GITHUB_SHA": "0123456789abcdef0123456789abcdef01234567",
                RECORD.SECRET_ENV_NAMES[0]: "account-a@example.invalid",
                RECORD.SECRET_ENV_NAMES[1]: leaked,
                RECORD.SECRET_ENV_NAMES[2]: "account-b@example.invalid",
                RECORD.SECRET_ENV_NAMES[3]: "OtherOpaqueSecretValue-67890",
            }
            with patch.dict(RECORD.os.environ, environment, clear=False):
                self.assertEqual(
                    RECORD.main(
                        [
                            "--output", str(output),
                            *sum((["--target", str(target)] for target in targets), []),
                            *sum((["--secret-env", name] for name in RECORD.SECRET_ENV_NAMES), []),
                        ]
                    ),
                    78,
                )
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
