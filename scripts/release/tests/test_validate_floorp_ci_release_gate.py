"""Tests for the source-bound CI release gate."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).parent.parent / "validate-floorp-ci-release-gate.py"
    spec = importlib.util.spec_from_file_location("validate_floorp_ci_release_gate", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = load_module()
RUN_ID = 123456
HEAD_SHA = "a" * 40
REPOSITORY = "Floorp-Projects/floorp-ios"


def valid_run() -> dict:
    return {
        "id": RUN_ID,
        "head_sha": HEAD_SHA,
        "head_branch": "main",
        "path": ".github/workflows/ci.yml",
        "status": "completed",
        "conclusion": "success",
        "event": "push",
        "run_attempt": 1,
        "repository": {"full_name": REPOSITORY},
    }


class FloorpCIReleaseGateTests(unittest.TestCase):
    def run_gate(self, mutate_run=None, log=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run = valid_run()
            if mutate_run is not None:
                mutate_run(run)
            run_path = root / "run.json"
            run_path.write_text(json.dumps(run), encoding="utf-8")
            artifact = root / "artifact"
            artifact.mkdir()
            (artifact / "FloorpUBOLReleaseAcceptance.xcresult").mkdir()
            (artifact / "ubol-release-acceptance.log").write_text(
                log
                if log is not None
                else "FLOORP_UBOL_RELEASE_GATE report\n** TEST SUCCEEDED **\n",
                encoding="utf-8",
            )
            output = root / "receipt.json"
            result = gate.main([
                "--run-json", str(run_path),
                "--artifact-root", str(artifact),
                "--expected-run-id", str(RUN_ID),
                "--expected-head-sha", HEAD_SHA,
                "--expected-repository", REPOSITORY,
                "--output", str(output),
            ])
            receipt = json.loads(output.read_text(encoding="utf-8")) if output.exists() else None
            return result, receipt

    def test_valid_source_bound_acceptance_passes(self):
        result, receipt = self.run_gate()
        self.assertEqual(result, 0)
        self.assertEqual(receipt["head_sha"], HEAD_SHA)
        self.assertEqual(receipt["ci_run_id"], RUN_ID)
        self.assertEqual(receipt["status"], "release-gate-passed")

    def test_different_source_sha_fails(self):
        result, receipt = self.run_gate(
            lambda run: run.__setitem__("head_sha", "b" * 40)
        )
        self.assertEqual(result, 1)
        self.assertIsNone(receipt)

    def test_failed_ci_run_fails(self):
        result, receipt = self.run_gate(
            lambda run: run.__setitem__("conclusion", "failure")
        )
        self.assertEqual(result, 1)
        self.assertIsNone(receipt)

    def test_different_workflow_fails(self):
        result, receipt = self.run_gate(
            lambda run: run.__setitem__("path", ".github/workflows/other.yml")
        )
        self.assertEqual(result, 1)
        self.assertIsNone(receipt)

    def test_acceptance_without_completion_marker_fails(self):
        result, receipt = self.run_gate(log="** TEST SUCCEEDED **\n")
        self.assertEqual(result, 1)
        self.assertIsNone(receipt)

    def test_failed_acceptance_log_fails(self):
        result, receipt = self.run_gate(
            log="FLOORP_UBOL_RELEASE_GATE report\n** TEST FAILED **\n"
        )
        self.assertEqual(result, 1)
        self.assertIsNone(receipt)


if __name__ == "__main__":
    unittest.main()
