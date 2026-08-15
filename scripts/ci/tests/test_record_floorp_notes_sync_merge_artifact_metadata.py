"""Tests for metadata-only protected artifact identity recording."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/record-floorp-notes-sync-merge-artifact-metadata.py"


def load_module(path: Path, name: str):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


RECORD = load_module(SCRIPT, "floorp_notes_sync_merge_artifact_metadata_test")


class ArtifactMetadataTests(unittest.TestCase):
    def test_records_only_safe_artifact_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "metadata.json"
            self.assertEqual(
                RECORD.main(
                    [
                        "--run-id", "123",
                        "--artifact-id", "456",
                        "--artifact-digest", "a" * 64,
                        "--head-sha", "2" * 40,
                        "--output", str(output),
                    ]
                ),
                0,
            )
            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["artifact_id"], 456)
            self.assertEqual(value["artifact_name"], "floorp-notes-sync-guarded-merge-123")
            self.assertNotIn("token", json.dumps(value).lower())

    def test_invalid_digest_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assertNotEqual(
                RECORD.main(
                    [
                        "--run-id", "123",
                        "--artifact-id", "456",
                        "--artifact-digest", "not-a-digest",
                        "--head-sha", "2" * 40,
                        "--output", str(Path(directory) / "metadata.json"),
                    ]
                ),
                0,
            )


if __name__ == "__main__":
    unittest.main()
