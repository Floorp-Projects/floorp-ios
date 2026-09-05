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

    def test_ubol_production_host_integration_runs_in_an_isolated_process(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        test_identifier = (
            "ClientTests/FloorpNativeWebExtensionIntegrationTests/"
            "testBundledUBOLBlocksProductionHostTabsAndRendersDashboard"
        )
        unit_step = workflow.split("      - name: Run unit tests\n", 1)[1].split(
            "\n      - name:", 1
        )[0]
        isolated_step = workflow.split(
            "      - name: Run uBlock Origin Lite production-host integration\n", 1
        )[1].split("\n      - name:", 1)[0]
        acceptance = workflow.index(
            "      - name: Run uBlock Origin Lite release acceptance\n"
        )
        isolated = workflow.index(
            "      - name: Run uBlock Origin Lite production-host integration\n"
        )

        self.assertIn(f"-skip-testing:{test_identifier}", unit_step)
        self.assertIn(f"-only-testing:{test_identifier}", isolated_step)
        self.assertIn("FloorpUBOLProductionHost.xcresult", isolated_step)
        self.assertIn(
            "testBundledUBOLBlocksProductionHostTabsAndRendersDashboard]' passed",
            isolated_step,
        )
        self.assertLess(isolated, acceptance)


if __name__ == "__main__":
    unittest.main()
