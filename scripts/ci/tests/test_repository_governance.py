"""Unit tests for scripts/ci/check-repository-governance.py."""

import json
import tempfile
import unittest
from pathlib import Path

from scripts.ci.check_repository_governance import main

VALID_CONTRACT = {
    "name": "Protect Floorp iOS main",
    "target": "branch",
    "enforcement": "active",
    "refs": ["refs/heads/main"],
    "required_approving_review_count": 0,
    "required_review_thread_resolution": True,
    "required_status_checks": ["Validate workflows", "Build and unit test"],
    "bypass_actors": [{"actor_type": "OrganizationAdmin", "bypass_mode": "pull_request"}],
}

FIXTURES = Path(__file__).parent.parent / "fixtures"


def write_docs(tmpdir, contract=VALID_CONTRACT):
    docs = tmpdir / "ci-cd.md"
    docs.write_text(
        "## GitHub repository settings\n\n"
        "The live ruleset contract:\n\n"
        "```governance\n"
        + json.dumps(contract, indent=2)
        + "\n```\n\n"
        "Prose follows.\n"
    )
    return docs


class GovernanceValidatorTests(unittest.TestCase):
    def run_validator(self, ruleset_path, docs_path):
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            output = tmpdir / "out.json"
            code = main(["--rulesets", str(ruleset_path), "--docs", str(docs_path)])
            return code

    def test_valid_ruleset_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            docs = write_docs(Path(tmp))
            self.assertEqual(
                self.run_validator(FIXTURES / "ruleset-valid.json", docs), 0
            )

    def test_missing_required_check_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            docs = write_docs(Path(tmp))
            self.assertEqual(
                self.run_validator(
                    FIXTURES / "ruleset-missing-required-check.json", docs
                ),
                1,
            )

    def test_review_count_drift_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            docs = write_docs(Path(tmp))
            self.assertEqual(
                self.run_validator(
                    FIXTURES / "ruleset-review-count-drift.json", docs
                ),
                1,
            )

    def test_missing_governance_fence_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            docs = Path(tmp) / "ci-cd.md"
            docs.write_text("no fence here\n")
            self.assertEqual(self.run_validator(FIXTURES / "ruleset-valid.json", docs), 1)

    def test_enforcement_drift_fails(self):
        contract = dict(VALID_CONTRACT)
        contract["enforcement"] = "evaluate"
        with tempfile.TemporaryDirectory() as tmp:
            docs = write_docs(Path(tmp), contract)
            self.assertEqual(
                self.run_validator(FIXTURES / "ruleset-valid.json", docs), 1
            )

    def test_bypass_drift_fails(self):
        contract = dict(VALID_CONTRACT)
        contract["bypass_actors"] = [
            {"actor_type": "RepositoryRole", "bypass_mode": "pull_request"}
        ]
        with tempfile.TemporaryDirectory() as tmp:
            docs = write_docs(Path(tmp), contract)
            self.assertEqual(
                self.run_validator(FIXTURES / "ruleset-valid.json", docs), 1
            )


if __name__ == "__main__":
    unittest.main()
