"""Unit tests for scripts/ci/check-floorpci-selection.py."""

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_main():
    module_path = Path(__file__).parent.parent / "check-floorpci-selection.py"
    spec = importlib.util.spec_from_file_location("check_floorpci_selection", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.main


main = load_main()


def write_plan(tmpdir, selected=None):
    selected = selected if selected is not None else [
        "FloorpNotesStoreTests/testCRUDPersistsAcrossStoreInstancesIncludingEmptyArchive()",
        "FloorpNoteSaveCoordinatorTests/testAutosaveFiresAfterScheduledDelayWithInjectedSleep()",
    ]
    plan = {
        "configurations": [{"id": "id", "name": "CI", "options": {}}],
        "testTargets": [
            {"target": {"name": "ClientTests"}, "selectedTests": selected}
        ],
        "version": 1,
    }
    path = tmpdir / "FloorpCI.xctestplan"
    path.write_text(json.dumps(plan, indent=2) + "\n")
    return path


def write_baseline(tmpdir, entries=None):
    entries = entries if entries is not None else [
        {"target": "ClientTests", "test": "FloorpNotesStoreTests/testCRUDPersistsAcrossStoreInstancesIncludingEmptyArchive()"},
        {"target": "ClientTests", "test": "FloorpNoteSaveCoordinatorTests/testAutosaveFiresAfterScheduledDelayWithInjectedSleep()"},
    ]
    baseline = {"schema_version": 1, "selected_tests": entries}
    path = tmpdir / "baseline.json"
    path.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
    return path


def write_traceability(tmpdir, baseline_path, tests=None, issues=(21, 22, 23, 24)):
    tests = tests if tests is not None else [
        "ClientTests/FloorpNotesStoreTests/testCRUDPersistsAcrossStoreInstancesIncludingEmptyArchive()",
        "ClientTests/FloorpNoteSaveCoordinatorTests/testAutosaveFiresAfterScheduledDelayWithInjectedSleep()",
    ]
    traceability = {
        "schema_version": 1,
        "baseline_sha256": hashlib.sha256(baseline_path.read_bytes()).hexdigest(),
        "cases": [
            {"id": f"{issue}-1", "issue": issue, "scenario": "scenario", "tests": tests}
            for issue in issues
        ],
    }
    path = tmpdir / "traceability.json"
    path.write_text(json.dumps(traceability, indent=2, sort_keys=True) + "\n")
    return path


def run_checker(tmpdir, plan, baseline, traceability):
    return main(
        [
            "--baseline", str(baseline),
            "--plan", str(plan),
            "--traceability", str(traceability),
        ]
    )


class FloorpCISelectionValidatorTests(unittest.TestCase):
    def test_valid_selection_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            plan = write_plan(tmpdir)
            baseline = write_baseline(tmpdir)
            traceability = write_traceability(tmpdir, baseline)
            self.assertEqual(run_checker(tmpdir, plan, baseline, traceability), 0)

    def test_removed_selection_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            plan = write_plan(
                tmpdir,
                selected=["FloorpNotesStoreTests/testCRUDPersistsAcrossStoreInstancesIncludingEmptyArchive()"],
            )
            baseline = write_baseline(tmpdir)
            traceability = write_traceability(
                tmpdir,
                baseline,
                tests=["ClientTests/FloorpNotesStoreTests/testCRUDPersistsAcrossStoreInstancesIncludingEmptyArchive()"],
            )
            self.assertEqual(run_checker(tmpdir, plan, baseline, traceability), 1)

    def test_missing_traced_test_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            plan = write_plan(tmpdir)
            baseline = write_baseline(tmpdir)
            traceability = write_traceability(
                tmpdir,
                baseline,
                tests=[
                    "ClientTests/FloorpNotesStoreTests/testCRUDPersistsAcrossStoreInstancesIncludingEmptyArchive()",
                    "ClientTests/FloorpNotesImportExportTests/testExportImportRoundTripPreservesIDsTimestampsAndOpaqueRichBytes()",
                ],
            )
            self.assertEqual(run_checker(tmpdir, plan, baseline, traceability), 1)

    def test_stale_traceability_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            plan = write_plan(tmpdir)
            baseline = write_baseline(tmpdir)
            traceability = write_traceability(tmpdir, baseline)
            traceability.write_text(
                traceability.read_text().replace(
                    hashlib.sha256(baseline.read_bytes()).hexdigest(),
                    "0" * 64,
                )
            )
            self.assertEqual(run_checker(tmpdir, plan, baseline, traceability), 1)

    def test_uncovered_issue_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            plan = write_plan(tmpdir)
            baseline = write_baseline(tmpdir)
            traceability = write_traceability(tmpdir, baseline, issues=(21, 22, 23))
            self.assertEqual(run_checker(tmpdir, plan, baseline, traceability), 1)

    def test_malformed_plan_fails_with_exit_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            plan = tmpdir / "FloorpCI.xctestplan"
            plan.write_text("not json")
            baseline = write_baseline(tmpdir)
            traceability = write_traceability(tmpdir, baseline)
            self.assertEqual(run_checker(tmpdir, plan, baseline, traceability), 2)


if __name__ == "__main__":
    unittest.main()
