"""Keep release-critical native WebExtension tests selectable by FloorpCI."""

from __future__ import annotations

import json
import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
TEST_PLAN = ROOT / "firefox-ios/firefox-ios-tests/Tests/FloorpCI.xctestplan"
TEST_ROOT = ROOT / "firefox-ios/firefox-ios-tests/Tests/ClientTests"

RELEASE_CRITICAL_CLASSES = {
    "BrowserViewControllerWebViewDelegateTests",
    "FloorpDarkReaderWebKitAcceptanceTests",
    "FloorpNativeWebExtensionIntegrationTests",
    "FloorpUBOLWebKitDiagnosticsTests",
    "TabManagerTests",
    "TabWebViewTests",
}


def methods_for_class(class_name: str) -> set[str]:
    declaration = re.compile(
        rf"(?m)^\s*(?:final\s+)?class\s+{re.escape(class_name)}\b"
    )
    next_class = re.compile(r"(?m)^\s*(?:final\s+)?class\s+[A-Za-z_][A-Za-z0-9_]*\b")
    for source in TEST_ROOT.rglob("*.swift"):
        text = source.read_text(encoding="utf-8")
        match = declaration.search(text)
        if match is None:
            continue
        following = next_class.search(text, match.end())
        body = text[match.end() : following.start() if following else len(text)]
        return set(re.findall(r"\bfunc\s+(test[A-Za-z0-9_]+)\s*\(", body))
    raise AssertionError(f"could not find Swift test class {class_name}")


class FloorpExtensionTestPlanTests(unittest.TestCase):
    def test_every_release_critical_selected_test_resolves_to_a_swift_method(self):
        plan = json.loads(TEST_PLAN.read_text(encoding="utf-8"))
        client_tests = next(
            target
            for target in plan["testTargets"]
            if target["target"]["name"] == "ClientTests"
        )["selectedTests"]

        selected: dict[str, set[str]] = {name: set() for name in RELEASE_CRITICAL_CLASSES}
        for identifier in client_tests:
            class_name, separator, method = identifier.partition("/")
            if separator and class_name in selected:
                selected[class_name].add(method.removesuffix("()"))

        for class_name, expected_methods in selected.items():
            self.assertTrue(expected_methods, f"no selected tests for {class_name}")
            actual_methods = methods_for_class(class_name)
            self.assertEqual(
                expected_methods - actual_methods,
                set(),
                f"FloorpCI contains stale test identifiers for {class_name}",
            )


if __name__ == "__main__":
    unittest.main()
