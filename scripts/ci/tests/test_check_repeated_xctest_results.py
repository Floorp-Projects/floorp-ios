"""Tests for exact, retry-free xcresult repetition validation."""

import contextlib
import copy
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "check_repeated_xctest_results",
    Path(__file__).parents[1] / "check-repeated-xctest-results.py",
)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

TESTS = ["ClientTests/FirstTests/testSharedName()", "ClientTests/SecondTests/testSharedName()"]


def case(identifier, repetitions=10):
    return {
        "nodeType": "Test Case",
        "nodeIdentifier": identifier,
        "name": identifier.split("/")[-1],
        "result": "Passed",
        "children": [
            {"nodeType": "Repetition", "nodeIdentifier": str(number), "result": "Passed"}
            for number in range(1, repetitions + 1)
        ],
    }


def results(identifiers=TESTS, repetitions=10):
    bundles = {}
    for identifier in identifiers:
        bundle, test_class, method = identifier.split("/")
        suites = bundles.setdefault(bundle, {})
        suites.setdefault(test_class, []).append(case(f"{test_class}/{method}", repetitions))
    return {"testNodes": [{
        "nodeType": "Test Plan", "name": "FloorpCI", "result": "Passed",
        "children": [
            {"nodeType": "Unit test bundle", "name": bundle, "result": "Passed", "children": [
                {"nodeType": "Test Suite", "name": name, "result": "Passed", "children": cases}
                for name, cases in suites.items()
            ]}
            for bundle, suites in bundles.items()
        ],
    }]}


def first_case(data):
    return data["testNodes"][0]["children"][0]["children"][0]["children"][0]


class RepeatedXCTestResultsTests(unittest.TestCase):
    def assert_invalid(self, data, expected=TESTS, repetitions=10):
        with self.assertRaises(checker.ValidationError):
            checker.validate_results(data, expected, repetitions)

    def test_exact_passed_repetitions_accept_one_two_and_ten_runs(self):
        for count in [1, 2, 10]:
            with self.subTest(repetitions=count):
                checker.validate_results(results(repetitions=count), TESTS, count)

    def test_repetition_order_is_not_significant(self):
        data = results()
        first_case(data)["children"].reverse()
        checker.validate_results(data, TESTS, 10)

    def test_same_class_and_method_in_distinct_bundles_are_distinct_tests(self):
        expected = ["ClientTests/FirstTests/testSharedName()", "OtherTests/FirstTests/testSharedName()"]
        checker.validate_results(results(expected), expected, 10)

    def test_expected_bundle_and_class_must_match_even_when_method_matches(self):
        for identifier in ["OtherTests/FirstTests/testSharedName()", "ClientTests/WrongTests/testSharedName()"]:
            with self.subTest(identifier=identifier):
                self.assert_invalid(results([identifier, TESTS[1]]))

    def test_missing_extra_and_duplicate_cases_are_rejected(self):
        self.assert_invalid(results(TESTS[:1]))
        self.assert_invalid(results(TESTS + ["ClientTests/ExtraTests/testExtra()"]))
        data = results()
        suite = data["testNodes"][0]["children"][0]["children"][0]
        suite["children"].append(copy.deepcopy(suite["children"][0]))
        self.assert_invalid(data)

    def test_duplicate_case_across_plan_configurations_is_rejected(self):
        data = results()
        data["testNodes"].append(copy.deepcopy(data["testNodes"][0]))
        self.assert_invalid(data)

    def test_missing_extra_and_duplicate_repetitions_are_rejected(self):
        for change in ["missing", "extra", "duplicate"]:
            with self.subTest(change=change):
                data = results()
                children = first_case(data)["children"]
                if change == "missing":
                    children.pop()
                elif change == "extra":
                    children.append({"nodeType": "Repetition", "nodeIdentifier": "11", "result": "Passed"})
                else:
                    children[-1]["nodeIdentifier"] = "1"
                self.assert_invalid(data)

    def test_repetition_identifiers_must_be_exact_unique_strings_one_through_count(self):
        for identifier in [None, 1, "", "0", "01", "11", "1 "]:
            with self.subTest(identifier=identifier):
                data = results()
                first_case(data)["children"][0]["nodeIdentifier"] = identifier
                self.assert_invalid(data)

    def test_all_container_case_and_repetition_results_must_be_passed(self):
        for level in range(5):
            for status in [None, "Failed", "Skipped", "Expected Failure", "Passed with failures", "passed"]:
                with self.subTest(level=level, status=status):
                    data = results()
                    node = data["testNodes"][0]
                    for _ in range(level):
                        node = node["children"][0]
                    node["result"] = status
                    self.assert_invalid(data)

    def test_retries_cannot_be_hidden_under_a_passed_repetition(self):
        for children in [None, {}, [{"nodeType": "Attempt", "result": "Passed"}]]:
            with self.subTest(children=children):
                data = results()
                first_case(data)["children"][0]["children"] = children
                self.assert_invalid(data)

    def test_direct_repetition_children_only(self):
        for replacement in [None, "Passed", {}, {"nodeType": "Test Case", "result": "Passed"}]:
            with self.subTest(replacement=replacement):
                data = results()
                first_case(data)["children"][0] = replacement
                self.assert_invalid(data)

    def test_malformed_top_level_and_missing_nodes_are_rejected(self):
        for data in [None, [], {}, {"testNodes": None}, {"testNodes": {}}, {"testNodes": []}, {"testNodes": [None]}]:
            with self.subTest(data=data):
                self.assert_invalid(data)

    def test_malformed_children_and_node_types_are_rejected_at_each_level(self):
        for level in range(4):
            for malformed in [None, {}, [], "children"]:
                with self.subTest(level=level, children=malformed):
                    data = results()
                    node = data["testNodes"][0]
                    for _ in range(level):
                        node = node["children"][0]
                    node["children"] = malformed
                    self.assert_invalid(data)
            for kind in ["Unknown", None, 42, [], {}]:
                with self.subTest(level=level, node_type=kind):
                    data = results()
                    node = data["testNodes"][0]
                    for _ in range(level):
                        node = node["children"][0]
                    node["nodeType"] = kind
                    self.assert_invalid(data)

    def test_missing_bundle_name_and_case_identifier_are_rejected(self):
        for name in [None, "", "ClientTests/OtherTests"]:
            with self.subTest(bundle=name):
                data = results()
                data["testNodes"][0]["children"][0]["name"] = name
                self.assert_invalid(data)
        for identifier in [None, 42, "", "testSharedName()", "Bundle/Class/testSharedName()"]:
            with self.subTest(identifier=identifier):
                data = results()
                first_case(data)["nodeIdentifier"] = identifier
                self.assert_invalid(data)

    def test_expected_identifiers_and_repetition_count_are_validated(self):
        for expected in [[], None, [42], ["FirstTests/testSharedName()"], ["ClientTests//test()"],
                         ["ClientTests/FirstTests/testSharedName"], [" ClientTests/FirstTests/test()"],
                         [TESTS[0], TESTS[0]]]:
            with self.subTest(expected=expected):
                self.assert_invalid(results(), expected=expected)
        for count in [0, -1, True, "10", None]:
            with self.subTest(repetitions=count):
                self.assert_invalid(results(), repetitions=count)

    def run_cli(self, path, tests=TESTS, repetitions=10):
        arguments = ["--results", str(path), "--repetitions", str(repetitions)]
        for identifier in tests:
            arguments.extend(["--test", identifier])
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = checker.main(arguments)
        return status, output.getvalue(), errors.getvalue()

    def test_cli_accepts_json_without_running_xcresulttool(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tests.json"
            path.write_text(json.dumps(results()), encoding="utf-8")
            status, output, errors = self.run_cli(path)
            self.assertEqual(status, 0)
            self.assertIn("2 tests, 10 repetitions each", output)
            self.assertEqual(errors, "")

    def test_cli_rejects_invalid_json_missing_file_and_failed_results(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tests.json"
            self.assertEqual(self.run_cli(path)[0], 1)
            path.write_text("{broken", encoding="utf-8")
            self.assertEqual(self.run_cli(path)[0], 1)
            data = results()
            first_case(data)["children"][0]["result"] = "Failed"
            path.write_text(json.dumps(data), encoding="utf-8")
            status, output, errors = self.run_cli(path)
            self.assertEqual(status, 1)
            self.assertEqual(output, "")
            self.assertIn("not Passed", errors)


if __name__ == "__main__":
    unittest.main()
