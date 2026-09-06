"""Unit tests for scripts/release/validate-floorp-privacy.py."""

import importlib.util
import json
import plistlib
import tempfile
import unittest
from pathlib import Path


def load_module():
    module_path = Path(__file__).parent.parent / "validate-floorp-privacy.py"
    spec = importlib.util.spec_from_file_location("validate_floorp_privacy", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


privacy = load_module()

FIXTURES = Path(__file__).parent.parent / "fixtures"
MATRIX = Path(__file__).parent.parent.parent.parent / "docs" / "floorp-release-endpoints.json"
METADATA = Path(__file__).parent.parent.parent.parent / "docs" / "app-store-connect-metadata.json"


class FloorpPrivacyValidatorTests(unittest.TestCase):
    def run_validator(self, **kwargs):
        args = ["--matrix", str(MATRIX), "--metadata", str(METADATA)]
        for key, value in kwargs.items():
            args += [f"--{key.replace('_', '-')}", str(value)]
        return privacy.main(args)

    def test_valid_boundaries_pass(self):
        self.assertEqual(
            self.run_validator(trace=FIXTURES / "floorp-release-network-flow.json"),
            0,
        )

    def test_unowned_traced_host_fails(self):
        self.assertEqual(
            self.run_validator(trace=FIXTURES / "floorp-release-network-flow-unowned.json"),
            1,
        )

    def test_disabled_service_traced_fails(self):
        self.assertEqual(
            self.run_validator(trace=FIXTURES / "floorp-release-network-flow-disabled.json"),
            1,
        )

    def test_metadata_drift_fails(self):
        self.assertEqual(
            privacy.main([
                "--matrix", str(MATRIX),
                "--metadata", str(FIXTURES / "floorp-privacy-metadata-drift.json"),
            ]),
            1,
        )

    def test_forbidden_entitlement_fails(self):
        self.assertEqual(
            self.run_validator(entitlements=FIXTURES / "floorp-privacy-entitlements-forbidden.plist"),
            1,
        )

    def test_enabled_default_browser_entitlement_passes(self):
        self.assertEqual(
            self.run_validator(
                entitlements=FIXTURES / "floorp-privacy-entitlements-default-browser.plist"
            ),
            0,
        )

    def test_missing_default_browser_entitlement_fails(self):
        source = FIXTURES / "floorp-privacy-entitlements-default-browser.plist"
        with tempfile.TemporaryDirectory() as tmp:
            entitlements = plistlib.loads(source.read_bytes())
            entitlements.pop("com.apple.developer.web-browser")
            path = Path(tmp) / "entitlements.plist"
            path.write_bytes(plistlib.dumps(entitlements))
            self.assertEqual(self.run_validator(entitlements=path), 1)

    def test_browser_app_installation_entitlement_fails(self):
        source = FIXTURES / "floorp-privacy-entitlements-default-browser.plist"
        with tempfile.TemporaryDirectory() as tmp:
            entitlements = plistlib.loads(source.read_bytes())
            entitlements["com.apple.developer.browser.app-installation"] = True
            path = Path(tmp) / "entitlements.plist"
            path.write_bytes(plistlib.dumps(entitlements))
            self.assertEqual(self.run_validator(entitlements=path), 1)

    def test_static_endpoint_outside_matrix_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            static = Path(tmp) / "static.txt"
            static.write_text("https://rogue-collector.example.net/ping\n")
            self.assertEqual(self.run_validator(static_endpoints=static), 1)


if __name__ == "__main__":
    unittest.main()
