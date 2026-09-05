"""Unit tests for scripts/release/validate-floorp-privacy.py."""

import importlib.util
import json
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

    def test_every_approved_sync_and_account_disclosure_is_required(self):
        required = {
            "Name",
            "Email Address",
            "Phone Number",
            "Physical Address",
            "Payment Info",
            "Coarse Location",
            "Photos or Videos",
            "Other User Content",
            "Browsing History",
            "Search History",
            "User ID",
            "Device ID",
            "Product Interaction",
            "Crash Data",
            "Performance Data",
            "Other Diagnostic Data",
            "Other Data Types",
        }
        for data_type in required:
            with self.subTest(data_type=data_type), tempfile.TemporaryDirectory() as tmp:
                metadata = json.loads(METADATA.read_text(encoding="utf-8"))
                metadata["privacy"]["data_types"] = [
                    entry for entry in metadata["privacy"]["data_types"]
                    if entry.get("data_type") != data_type
                ]
                path = Path(tmp) / "metadata.json"
                path.write_text(json.dumps(metadata), encoding="utf-8")
                self.assertEqual(
                    privacy.main([
                        "--matrix", str(MATRIX),
                        "--metadata", str(path),
                    ]),
                    1,
                )

    def test_unapproved_extra_disclosure_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            metadata = json.loads(METADATA.read_text(encoding="utf-8"))
            metadata["privacy"]["data_types"].append({
                "category": "Usage Data",
                "data_type": "Advertising Data",
                "collected": True,
                "linked_to_user_identity": True,
                "used_for_tracking": False,
                "purpose": ["App Functionality"],
            })
            path = Path(tmp) / "metadata.json"
            path.write_text(json.dumps(metadata), encoding="utf-8")
            self.assertEqual(
                privacy.main([
                    "--matrix", str(MATRIX),
                    "--metadata", str(path),
                ]),
                1,
            )

    def test_tracking_answer_must_be_explicitly_false(self):
        for value in (True, None):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp:
                metadata = json.loads(METADATA.read_text(encoding="utf-8"))
                if value is None:
                    metadata["privacy"].pop("tracking")
                else:
                    metadata["privacy"]["tracking"] = value
                path = Path(tmp) / "metadata.json"
                path.write_text(json.dumps(metadata), encoding="utf-8")
                self.assertEqual(
                    privacy.main([
                        "--matrix", str(MATRIX),
                        "--metadata", str(path),
                    ]),
                    1,
                )

    def test_live_privacy_policy_gate_is_required(self):
        for field, value in (
            ("privacy_policy_url", "https://example.invalid/privacy"),
            ("live_verification", "App Store Connect checked"),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                metadata = json.loads(METADATA.read_text(encoding="utf-8"))
                metadata["privacy"][field] = value
                path = Path(tmp) / "metadata.json"
                path.write_text(json.dumps(metadata), encoding="utf-8")
                self.assertEqual(
                    privacy.main([
                        "--matrix", str(MATRIX),
                        "--metadata", str(path),
                    ]),
                    1,
                )

    def test_sync_disclosure_must_be_account_linked_app_functionality_and_not_tracking(self):
        for field, value in (
            ("linked_to_user_identity", False),
            ("purpose", ["Analytics"]),
            ("used_for_tracking", True),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                metadata = json.loads(METADATA.read_text(encoding="utf-8"))
                entry = next(
                    item for item in metadata["privacy"]["data_types"]
                    if item.get("data_type") == "Other User Content"
                )
                entry[field] = value
                path = Path(tmp) / "metadata.json"
                path.write_text(json.dumps(metadata), encoding="utf-8")
                self.assertEqual(
                    privacy.main([
                        "--matrix", str(MATRIX),
                        "--metadata", str(path),
                    ]),
                    1,
                )

    def test_every_disclosure_explicitly_rejects_tracking(self):
        metadata = json.loads(METADATA.read_text(encoding="utf-8"))
        self.assertTrue(metadata["privacy"]["data_types"])
        self.assertTrue(all(
            entry.get("used_for_tracking") is False
            for entry in metadata["privacy"]["data_types"]
        ))

    def test_forbidden_entitlement_fails(self):
        self.assertEqual(
            self.run_validator(entitlements=FIXTURES / "floorp-privacy-entitlements-forbidden.plist"),
            1,
        )

    def test_static_endpoint_outside_matrix_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            static = Path(tmp) / "static.txt"
            static.write_text("https://rogue-collector.example.net/ping\n")
            self.assertEqual(self.run_validator(static_endpoints=static), 1)


if __name__ == "__main__":
    unittest.main()
