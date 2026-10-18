#!/usr/bin/env python3
"""Check exact, retry-free repetitions in xcresulttool test-results JSON."""

import argparse
import json
import sys
from pathlib import Path


class ValidationError(Exception):
    pass


def validate_results(results, expected_tests, repetitions):
    """Validate JSON exported by xcresulttool get test-results tests."""
    if type(repetitions) is not int or repetitions < 1:
        raise ValidationError("repetitions must be a positive integer")
    if not isinstance(expected_tests, (list, tuple)) or not expected_tests:
        raise ValidationError("at least one expected test is required")
    for identifier in expected_tests:
        if not isinstance(identifier, str):
            raise ValidationError("expected tests must be Bundle/Class/method() identifiers")
        parts = identifier.split("/")
        if len(parts) != 3 or not all(parts) or any(part.strip() != part for part in parts) or not parts[2].endswith("()"):
            raise ValidationError(f"invalid expected test identifier: {identifier!r}")
    expected = set(expected_tests)
    if len(expected) != len(expected_tests):
        raise ValidationError("expected test identifiers must be unique")
    if not isinstance(results, dict):
        raise ValidationError("results must be a JSON object")
    roots = results.get("testNodes")
    if not isinstance(roots, list) or not roots:
        raise ValidationError("results must contain a nonempty testNodes array")

    found = set()
    expected_repetitions = {str(number) for number in range(1, repetitions + 1)}
    allowed_children = {
        "Test Plan": {"Unit test bundle"},
        "Unit test bundle": {"Test Suite"},
        "Test Suite": {"Test Suite", "Test Case"},
        "Test Case": {"Repetition"},
    }

    def visit(node, parent_type=None, bundle=None):
        if not isinstance(node, dict):
            raise ValidationError("every test node must be an object")
        kind = node.get("nodeType")
        if not isinstance(kind, str):
            raise ValidationError("every test node must have a string nodeType")
        if parent_type is None:
            valid_kind = kind == "Test Plan"
        else:
            valid_kind = kind in allowed_children[parent_type]
        if not valid_kind:
            raise ValidationError(f"unexpected node type {kind!r} under {parent_type!r}")
        if node.get("result") != "Passed":
            raise ValidationError(f"{kind} {node.get('name')!r} is not Passed")
        if kind == "Unit test bundle":
            bundle = node.get("name")
            if not isinstance(bundle, str) or not bundle or "/" in bundle:
                raise ValidationError("test bundle must have an unambiguous name")
        children = node.get("children")
        if not isinstance(children, list) or not children:
            raise ValidationError(f"{kind} must contain a nonempty children array")
        if kind == "Test Case":
            identifier = node.get("nodeIdentifier")
            if not isinstance(identifier, str) or len(identifier.split("/")) != 2:
                raise ValidationError("test case must have a Class/method() nodeIdentifier")
            identifier = f"{bundle}/{identifier}"
            if identifier not in expected:
                raise ValidationError(f"unexpected test case: {identifier}")
            if identifier in found:
                raise ValidationError(f"duplicate test case: {identifier}")
            found.add(identifier)
            observed = set()
            for repetition in children:
                if not isinstance(repetition, dict) or repetition.get("nodeType") != "Repetition":
                    raise ValidationError(f"{identifier} must have direct Repetition children only")
                number = repetition.get("nodeIdentifier")
                if not isinstance(number, str) or number not in expected_repetitions:
                    raise ValidationError(f"{identifier} has an invalid repetition identifier: {number!r}")
                if number in observed:
                    raise ValidationError(f"{identifier} has duplicate repetition {number}")
                observed.add(number)
                if repetition.get("result") != "Passed":
                    raise ValidationError(f"{identifier} repetition {number} is not Passed")
                if repetition.get("children", []) != []:
                    raise ValidationError(f"{identifier} repetition {number} has nested runs or retries")
            if observed != expected_repetitions:
                missing = sorted(expected_repetitions - observed, key=int)
                raise ValidationError(f"{identifier} is missing repetitions: {', '.join(missing)}")
            return
        for child in children:
            visit(child, kind, bundle)

    for root in roots:
        visit(root)
    if found != expected:
        raise ValidationError(f"missing test cases: {', '.join(sorted(expected - found))}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, required=True)
    parser.add_argument("--test", action="append", required=True, dest="tests")
    arguments = parser.parse_args(argv)
    try:
        results = json.loads(arguments.results.read_text(encoding="utf-8"))
        validate_results(results, arguments.tests, arguments.repetitions)
    except (OSError, UnicodeError, json.JSONDecodeError, ValidationError) as error:
        print(f"Invalid repeated XCTest results: {error}", file=sys.stderr)
        return 1
    print(f"Passed: {len(arguments.tests)} tests, {arguments.repetitions} repetitions each")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
