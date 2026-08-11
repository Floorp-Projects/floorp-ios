from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]


class FloorpCIPythonContractTests(unittest.TestCase):
    def test_primary_ci_runs_release_contract_suites(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("name: Run Floorp release contract tests", workflow)
        self.assertIn(
            "python3 -m unittest discover -s scripts/ci/tests -p 'test_*.py'",
            workflow,
        )
        self.assertIn(
            "python3 -m unittest discover -s scripts/staging/tests -p 'test_*.py'",
            workflow,
        )


if __name__ == "__main__":
    unittest.main()
