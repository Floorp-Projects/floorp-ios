#!/usr/bin/env python3
"""Validate the FloorpCI test selection against its baseline and Notes traceability.

The FloorpCI test plan is the single authority for which deterministic tests
run in CI. This checker enforces three contracts:

1. Baseline: every test recorded in the baseline fixture
   (`scripts/ci/fixtures/floorpci-selected-tests.json`) must still be selected
   in the plan. A removal is a regression and fails.
2. Traceability: every deterministic test referenced by
   `docs/floorp-notes-local-v1-tests.json` must be selected in the plan, and
   the traceability document must bind the exact baseline SHA-256 so a stale
   document is rejected.
3. Issue coverage: the traceability document must cover issues #21-#24.

Exit codes:
  0  plan, baseline, and traceability agree
  1  a selection was removed, a traced test is missing, the traceability is
     stale, or an issue is uncovered
  2  malformed input
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path


class SelectionError(Exception):
    pass


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as error:
        raise SelectionError(f"{path}: invalid JSON ({error})") from error


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--baseline", required=True, type=Path)
    result.add_argument("--plan", required=True, type=Path)
    result.add_argument("--traceability", required=True, type=Path)
    return result


def plan_selection(plan_path: Path) -> set:
    plan = load_json(plan_path)
    if not isinstance(plan, dict) or not isinstance(plan.get("testTargets"), list):
        raise SelectionError(f"{plan_path}: malformed xctestplan (missing testTargets)")
    selection = set()
    for target in plan["testTargets"]:
        if not isinstance(target, dict):
            raise SelectionError(f"{plan_path}: malformed testTarget entry")
        name = target.get("target", {}).get("name")
        if not isinstance(name, str) or not name:
            raise SelectionError(f"{plan_path}: test target without a name")
        for test in target.get("selectedTests", []):
            if not isinstance(test, str) or "/" not in test:
                raise SelectionError(f"{plan_path}: malformed selected test {test!r}")
            selection.add((name, test))
    return selection


def load_baseline(baseline_path: Path) -> set:
    baseline = load_json(baseline_path)
    if not isinstance(baseline, dict) or baseline.get("schema_version") != 1:
        raise SelectionError(f"{baseline_path}: unsupported baseline schema")
    entries = baseline.get("selected_tests")
    if not isinstance(entries, list):
        raise SelectionError(f"{baseline_path}: missing selected_tests list")
    result = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise SelectionError(f"{baseline_path}: malformed baseline entry")
        target = entry.get("target")
        test = entry.get("test")
        if not isinstance(target, str) or not isinstance(test, str) or "/" not in test:
            raise SelectionError(f"{baseline_path}: malformed baseline entry {entry!r}")
        result.add((target, test))
    return result


def load_traceability(traceability_path: Path, baseline_path: Path) -> dict:
    traceability = load_json(traceability_path)
    if not isinstance(traceability, dict) or traceability.get("schema_version") != 1:
        raise SelectionError(f"{traceability_path}: unsupported traceability schema")
    bound_hash = traceability.get("baseline_sha256")
    if not isinstance(bound_hash, str) or len(bound_hash) != 64:
        raise SelectionError(f"{traceability_path}: missing baseline_sha256")
    cases = traceability.get("cases")
    if not isinstance(cases, list) or not cases:
        raise SelectionError(f"{traceability_path}: missing cases list")
    return traceability


def main(argv=None) -> int:
    arguments = parser().parse_args(argv)
    try:
        selection = plan_selection(arguments.plan)
        baseline = load_baseline(arguments.baseline)
        traceability = load_traceability(arguments.traceability, arguments.baseline)

        removed = sorted(baseline - selection)
        if removed:
            for target, test in removed[:5]:
                print(f"REMOVED_SELECTION {target}/{test}", file=sys.stderr)
            return 1

        bound_hash = traceability["baseline_sha256"]
        actual_hash = sha256(arguments.baseline)
        if bound_hash != actual_hash:
            print(
                f"STALE_TRACEABILITY expected baseline {bound_hash}, got {actual_hash}",
                file=sys.stderr,
            )
            return 1

        issues = set()
        missing = []
        for case in traceability["cases"]:
            if not isinstance(case, dict):
                raise SelectionError(f"{arguments.traceability}: malformed case")
            issue = case.get("issue")
            if not isinstance(issue, int):
                raise SelectionError(f"{arguments.traceability}: case without issue")
            issues.add(issue)
            for reference in case.get("tests", []):
                if not isinstance(reference, str) or "/" not in reference:
                    raise SelectionError(f"{arguments.traceability}: malformed test reference {reference!r}")
                target, test = reference.split("/", 1)
                if (target, test) not in selection:
                    missing.append(reference)
        if missing:
            for reference in missing[:5]:
                print(f"MISSING_TEST {reference}", file=sys.stderr)
            return 1
        if not {21, 22, 23, 24}.issubset(issues):
            uncovered = sorted({21, 22, 23, 24} - issues)
            print(f"UNCOVERED_ISSUES {uncovered}", file=sys.stderr)
            return 1
        return 0
    except SelectionError as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
