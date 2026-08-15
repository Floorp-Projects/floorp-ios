"""TDD tests for the metadata-only protected QA evidence manifest."""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/create-floorp-notes-sync-production-qa-manifest.py"


def load_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


CREATE = load_module(SCRIPT, "floorp_notes_sync_production_qa_manifest_test")


def canonical(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode() + b"\n"


class ProductionQAManifestTests(unittest.TestCase):
    def test_manifest_binds_all_artifacts_without_copying_contents(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary = root / "qa-summary.json"
            cleanup = root / "cleanup-receipt.json"
            xcresult = root / "floorp-notes-sync-two-client.xcresult"
            xcresult.mkdir()
            (xcresult / "metadata").write_text("metadata\n")
            summary.write_bytes(canonical({"accounts": 2, "public_release": False}))
            cleanup.write_bytes(canonical({
                "accounts": True,
                "coordination_root": True,
                "local_cache": True,
                "runner_temp": True,
                "simulator_keychain": True,
            }))
            names = {
                "xcodebuild-log": root / "xcodebuild.log",
                "desktop-log": root / "desktop.log",
                "production-qa-capability": root / "production-qa-capability.json",
                "production-qa-xcconfig": root / "production-qa.xcconfig",
                "secret-scan": root / "secret-scan-pre.json",
            }
            for path in names.values():
                path.write_text("metadata\n")
            output = root / "qa-manifest.json"
            args = [
                "--output", str(output),
                "--source-sha", "a" * 40,
                "--desktop-sha", "b" * 40,
                "--run-id", "123",
                "--run-attempt", "1",
                "--qa-summary", str(summary),
                "--cleanup-receipt", str(cleanup),
                "--xcresult", str(xcresult),
                "--xcodebuild-log", str(names["xcodebuild-log"]),
                "--desktop-log", str(names["desktop-log"]),
                "--production-qa-capability", str(names["production-qa-capability"]),
                "--production-qa-xcconfig", str(names["production-qa-xcconfig"]),
                "--secret-scan", str(names["secret-scan"]),
            ]
            with patch.dict(os.environ, {"GITHUB_REPOSITORY": CREATE.REPOSITORY}, clear=False):
                self.assertEqual(CREATE.main(args), 0)
            manifest = json.loads(output.read_text())
            self.assertEqual(manifest["accounts"], 2)
            self.assertEqual({item["role"] for item in manifest["artifacts"]}, {role for role, _ in CREATE.ARTIFACTS})
            self.assertNotIn("metadata", output.read_text())

    def test_incomplete_cleanup_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary = root / "qa-summary.json"
            cleanup = root / "cleanup-receipt.json"
            summary.write_bytes(canonical({"accounts": 2, "public_release": False}))
            cleanup.write_bytes(canonical({"accounts": True}))
            self.assertEqual(
                CREATE.main([
                    "--output", str(root / "manifest.json"),
                    "--source-sha", "a" * 40,
                    "--desktop-sha", "b" * 40,
                    "--run-id", "123",
                    "--run-attempt", "1",
                    "--qa-summary", str(summary),
                    "--cleanup-receipt", str(cleanup),
                    *sum(([f"--{role}", str(root / f"{role}.json")] for role, _ in CREATE.ARTIFACTS if role not in {"qa-summary", "cleanup-receipt", "xcresult"}), []),
                    "--xcresult", str(root / "missing.xcresult"),
                ]),
                2,
            )


if __name__ == "__main__":
    unittest.main()
