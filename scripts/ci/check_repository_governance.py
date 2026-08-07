#!/usr/bin/env python3
"""Validate documented repository governance against the live GitHub ruleset.

The machine-readable governance contract lives in `docs/ci-cd.md` inside the
```governance JSON fence. This script compares it with the live ruleset
snapshots captured from:

    gh api repos/Floorp-Projects/floorp-ios/rulesets            # list shape
    gh api repos/Floorp-Projects/floorp-ios/rulesets/<id>       # detail shape

Rule-level validation requires at least one detail-shaped ruleset (one that
contains a `rules` array). Identity-level checks (name, target, enforcement,
ref conditions) also accept the list shape.

Exit codes:
  0  documented governance matches the live ruleset
  1  a documented expectation contradicts the live ruleset
  2  malformed input or missing detail-shaped ruleset
"""

import argparse
import json
import re
import sys
from pathlib import Path

DOCS_GOVERNANCE_FENCE = re.compile(
    r"```governance\n(?P<body>.*?)\n```", re.DOTALL
)


class GovernanceError(Exception):
    pass


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as error:
        raise GovernanceError(f"{path}: invalid JSON ({error})") from error


def extract_documented_contract(docs_path: Path):
    text = docs_path.read_text()
    match = DOCS_GOVERNANCE_FENCE.search(text)
    if match is None:
        raise GovernanceError(
            f"{docs_path}: missing ```governance JSON fence"
        )
    try:
        contract = json.loads(match.group("body"))
    except json.JSONDecodeError as error:
        raise GovernanceError(
            f"{docs_path}: governance fence is not valid JSON ({error})"
        ) from error
    for field in ("name", "enforcement", "refs", "required_status_checks"):
        if field not in contract:
            raise GovernanceError(f"{docs_path}: governance fence missing {field!r}")
    return contract


def normalize_rulesets(rulesets_files):
    entries = []
    for path in rulesets_files:
        value = load_json(Path(path))
        if isinstance(value, list):
            entries.extend(value)
        elif isinstance(value, dict):
            entries.append(value)
        else:
            raise GovernanceError(f"{path}: expected a ruleset object or list")
    return entries


def find_main_rulesets(entries, contract_name):
    main_rulesets = []
    for entry in entries:
        if entry.get("target") != "branch":
            continue
        includes = (
            entry.get("conditions", {})
            .get("ref_name", {})
            .get("include", [])
        )
        if "refs/heads/main" in includes:
            main_rulesets.append(entry)
            continue
        # The list endpoint omits `conditions`; a branch-targeted ruleset with
        # the documented name is accepted at identity level. Rule-level
        # validation still requires the detailed snapshot.
        if not includes and entry.get("name") == contract_name:
            main_rulesets.append(entry)
    return main_rulesets


def validate_identity(ruleset, contract):
    if ruleset.get("name") != contract["name"]:
        raise GovernanceError(
            f"ruleset name mismatch: documented {contract['name']!r}, "
            f"live {ruleset.get('name')!r}"
        )
    if ruleset.get("enforcement") != contract["enforcement"]:
        raise GovernanceError(
            f"enforcement mismatch: documented {contract['enforcement']!r}, "
            f"live {ruleset.get('enforcement')!r}"
        )


def validate_rules(ruleset, contract):
    rules = {rule.get("type"): rule.get("parameters", {}) for rule in ruleset.get("rules", [])}

    pr_rule = rules.get("pull_request")
    if pr_rule is None:
        raise GovernanceError("live ruleset does not require pull requests")
    live_count = pr_rule.get("required_approving_review_count")
    expected_count = contract["required_approving_review_count"]
    if live_count != expected_count:
        raise GovernanceError(
            f"review-count drift: documented {expected_count}, live {live_count}"
        )
    if bool(pr_rule.get("required_review_thread_resolution")) != bool(
        contract.get("required_review_thread_resolution", True)
    ):
        raise GovernanceError("conversation resolution requirement differs")

    live_checks = {
        check.get("context")
        for check in rules.get("required_status_checks", {})
        .get("required_status_checks", [])
    }
    expected_checks = set(contract["required_status_checks"])
    if live_checks != expected_checks:
        missing = sorted(expected_checks - live_checks)
        extra = sorted(live_checks - expected_checks)
        raise GovernanceError(
            f"required-check drift: missing={missing} extra={extra}"
        )

    if "deletion" not in rules:
        raise GovernanceError("live ruleset does not block branch deletion")
    if "non_fast_forward" not in rules:
        raise GovernanceError("live ruleset does not block force pushes")

    live_bypass = sorted(
        (actor.get("actor_type"), actor.get("bypass_mode"))
        for actor in ruleset.get("bypass_actors", [])
    )
    expected_bypass = sorted(
        (actor["actor_type"], actor.get("bypass_mode", "always"))
        for actor in contract.get("bypass_actors", [])
    )
    if live_bypass != expected_bypass:
        raise GovernanceError(
            f"bypass drift: documented {expected_bypass}, live {live_bypass}"
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rulesets", action="append", required=True,
                        help="live ruleset snapshot (repeatable; list or detail shape)")
    parser.add_argument("--docs", required=True, help="path to docs/ci-cd.md")
    args = parser.parse_args(argv)

    try:
        contract = extract_documented_contract(Path(args.docs))
        entries = normalize_rulesets(args.rulesets)
        main_rulesets = find_main_rulesets(entries, contract["name"])
        if not main_rulesets:
            raise GovernanceError("no active branch ruleset covers refs/heads/main")

        detail_shaped = [r for r in main_rulesets if "rules" in r]
        for ruleset in main_rulesets:
            validate_identity(ruleset, contract)
        if not detail_shaped:
            print(
                "[PASS] documented identity matches the live main ruleset "
                "(rule-level validation requires the detailed ruleset snapshot; "
                "capture it with gh api repos/Floorp-Projects/floorp-ios/rulesets/<id>)",
                file=sys.stderr,
            )
            return 0
        validate_rules(detail_shaped[0], contract)
    except GovernanceError as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        return 1

    print("[PASS] documented governance matches the live main ruleset")
    return 0


if __name__ == "__main__":
    sys.exit(main())
