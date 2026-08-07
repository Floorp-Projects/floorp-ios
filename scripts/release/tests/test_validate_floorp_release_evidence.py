"""Unit tests for scripts/release/validate-floorp-release-evidence.py."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


def load_main():
    module_path = Path(__file__).parent.parent / "validate-floorp-release-evidence.py"
    spec = importlib.util.spec_from_file_location("validate_floorp_release_evidence", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.main


main = load_main()


FIXTURES = Path(__file__).parent.parent / "fixtures"
SCHEMA = Path(__file__).parent.parent / "floorp-release-evidence.schema.json"


class FloorpReleaseEvidenceValidatorTests(unittest.TestCase):
    def run_validator(self, evidence_path):
        with tempfile.TemporaryDirectory() as tmp:
            return main(
                [
                    "--evidence", str(evidence_path),
                    "--schema", str(SCHEMA),
                ]
            )

    def test_valid_evidence_passes(self):
        self.assertEqual(self.run_validator(FIXTURES / "floorp-release-evidence-valid.json"), 0)

    def test_wrong_source_sha_fails(self):
        self.assertEqual(self.run_validator(FIXTURES / "floorp-release-evidence-wrong-sha.json"), 1)

    def test_wrong_marketing_version_fails(self):
        self.assertEqual(self.run_validator(FIXTURES / "floorp-release-evidence-wrong-version.json"), 1)

    def test_forbidden_entitlement_fails(self):
        self.assertEqual(self.run_validator(FIXTURES / "floorp-release-evidence-wrong-entitlement.json"), 1)

    def test_missing_dsym_inventory_fails(self):
        self.assertEqual(self.run_validator(FIXTURES / "floorp-release-evidence-missing-dsym.json"), 1)

    def test_mixed_build_ids_fail(self):
        self.assertEqual(self.run_validator(FIXTURES / "floorp-release-evidence-mixed-build-ids.json"), 1)

    def test_malformed_evidence_exits_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            malformed = Path(tmp) / "malformed.json"
            malformed.write_text("not json")
            self.assertEqual(self.run_validator(malformed), 2)


if __name__ == "__main__":
    unittest.main()
