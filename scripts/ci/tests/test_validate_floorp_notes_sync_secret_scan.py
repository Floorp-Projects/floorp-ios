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


class ValidateSecretScanReceiptTests(unittest.TestCase):
    def test_exact_receipt_is_bound_to_run(self) -> None:
        SCAN.validate(receipt(), "0123456789abcdef0123456789abcdef01234567", 123456, 1)

    def test_scope_or_run_mismatch_is_rejected(self) -> None:
        value = receipt()
        value["scope"] = ["qa-summary"]
        with self.assertRaises(SCAN.SecretScanError):
            SCAN.validate(value, "0123456789abcdef0123456789abcdef01234567", 123456, 1)
        with self.assertRaises(SCAN.SecretScanError):
            SCAN.validate(receipt(), "fedcba9876543210fedcba9876543210fedcba98", 123456, 1)

    def test_cli_requires_canonical_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scan.json"
            path.write_bytes(canonical(receipt()))
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
            xcresult.mkdir()
            (xcresult / "result").write_text("safe metadata\n")
            for path in (summary, cleanup, log):
                path.write_text("safe metadata\n")
            output = root / "secret-scan.json"
            environment = {
                "GITHUB_REPOSITORY": SCAN.REPOSITORY,
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_RUN_ID": "123456",
                "GITHUB_SHA": "0123456789abcdef0123456789abcdef01234567",
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
                        ]
                    ),
                    0,
                )
            value, raw = SCAN.load(output)
            SCAN.validate(value, environment["GITHUB_SHA"], 123456, 1)
            self.assertNotIn(b"safe metadata", raw)


if __name__ == "__main__":
    unittest.main()
