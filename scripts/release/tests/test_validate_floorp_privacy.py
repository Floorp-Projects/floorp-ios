"""Unit tests for scripts/release/validate-floorp-privacy.py."""

import importlib.util
import io
import json
import plistlib
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


VALIDATOR = Path(__file__).parent.parent / "validate-floorp-privacy.py"


def load_module():
    spec = importlib.util.spec_from_file_location("validate_floorp_privacy", VALIDATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


privacy = load_module()

FIXTURES = Path(__file__).parent.parent / "fixtures"
MATRIX = Path(__file__).parent.parent.parent.parent / "docs" / "floorp-release-endpoints.json"
METADATA = Path(__file__).parent.parent.parent.parent / "docs" / "app-store-connect-metadata.json"


class FloorpPrivacyValidatorTests(unittest.TestCase):
    def make_fake_archive(self, root):
        archive = Path(root) / "Floorp.xcarchive"
        app = archive / "Products" / "Applications" / "Client.app"
        framework = app / "Frameworks" / "Example.framework"
        app_extension = app / "PlugIns" / "Share.appex"
        framework.mkdir(parents=True)
        app_extension.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Client"}))
        (framework / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": "Example"})
        )
        (app_extension / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": "Share"})
        )
        (app / "Client").write_bytes(b"app binary")
        (framework / "Example").write_bytes(b"framework binary")
        (app_extension / "Share").write_bytes(b"app extension binary")
        return archive, app / "Client", framework / "Example", app_extension / "Share"

    def write_inventory(self, root, *uuids):
        path = Path(root) / "dsyms.txt"
        path.write_text("".join(
            f"UUID: {uuid} (arm64) /tmp/Test.dSYM/Contents/Resources/DWARF/Test\n"
            for uuid in uuids
        ))
        return path

    def mock_dwarfdump(self, outputs):
        def run_dwarfdump(command, **_kwargs):
            binary = command[-1]
            return subprocess.CompletedProcess(
                command, 0, f"UUID: {outputs[binary]} (arm64) {binary}\n", ""
            )

        return run_dwarfdump

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

    def test_omitted_optional_endpoint_evidence_is_allowed(self):
        self.assertEqual(self.run_validator(), 0)

    def test_explicit_missing_endpoint_evidence_is_malformed(self):
        with tempfile.TemporaryDirectory() as tmp:
            for argument in ("trace", "static_endpoints"):
                with self.subTest(argument=argument):
                    self.assertEqual(
                        self.run_validator(**{argument: Path(tmp) / "missing"}),
                        2,
                    )

    def test_unused_ipa_argument_is_rejected(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            privacy.main([
                "--matrix", str(MATRIX),
                "--metadata", str(METADATA),
                "--ipa", "/tmp/not-a-privacy-input.ipa",
            ])
        self.assertEqual(raised.exception.code, 2)

    def test_endpoint_matrix_shape_is_validated(self):
        valid = json.loads(MATRIX.read_text(encoding="utf-8"))
        invalid_documents = []

        wrong_version_type = json.loads(json.dumps(valid))
        wrong_version_type["schema_version"] = True
        invalid_documents.append(wrong_version_type)

        empty = json.loads(json.dumps(valid))
        empty["endpoints"] = []
        invalid_documents.append(empty)

        bad_status = json.loads(json.dumps(valid))
        bad_status["endpoints"][0]["status"] = "unknown"
        invalid_documents.append(bad_status)

        duplicate = json.loads(json.dumps(valid))
        duplicate["endpoints"].append(dict(duplicate["endpoints"][0]))
        invalid_documents.append(duplicate)

        invalid_documents.append(json.loads(METADATA.read_text(encoding="utf-8")))

        for index, document in enumerate(invalid_documents):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "matrix.json"
                path.write_text(json.dumps(document), encoding="utf-8")
                self.assertEqual(
                    privacy.main([
                        "--matrix", str(path),
                        "--metadata", str(METADATA),
                    ]),
                    2,
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

    def test_dsym_inventory_covers_all_distributed_bundle_executable_uuids(self):
        app_uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        framework_uuid = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        appex_uuid = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        with tempfile.TemporaryDirectory() as tmp:
            archive, app_binary, framework_binary, appex_binary = self.make_fake_archive(tmp)
            inventory = self.write_inventory(tmp, app_uuid, framework_uuid, appex_uuid)
            outputs = {
                str(app_binary): app_uuid,
                str(framework_binary): framework_uuid,
                str(appex_binary): appex_uuid,
            }

            with mock.patch.object(
                privacy.subprocess, "run", side_effect=self.mock_dwarfdump(outputs)
            ) as run:
                privacy.validate_dsym_inventory(archive, inventory)

            self.assertEqual(
                [call.args[0][-1] for call in run.call_args_list],
                [str(app_binary), str(framework_binary), str(appex_binary)],
            )

    def test_missing_distributed_bundle_uuid_is_rejected(self):
        app_uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        framework_uuid = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        appex_uuid = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        with tempfile.TemporaryDirectory() as tmp:
            archive, app_binary, framework_binary, appex_binary = self.make_fake_archive(tmp)
            outputs = {
                str(app_binary): app_uuid,
                str(framework_binary): framework_uuid,
                str(appex_binary): appex_uuid,
            }
            cases = (
                ("Client.app", (framework_uuid, appex_uuid)),
                ("Example.framework", (app_uuid, appex_uuid)),
                ("Share.appex", (app_uuid, framework_uuid)),
            )
            for missing_bundle, retained_uuids in cases:
                with self.subTest(missing_bundle=missing_bundle):
                    inventory = self.write_inventory(tmp, *retained_uuids)
                    with mock.patch.object(
                        privacy.subprocess,
                        "run",
                        side_effect=self.mock_dwarfdump(outputs),
                    ):
                        with self.assertRaisesRegex(privacy.PrivacyError, missing_bundle):
                            privacy.validate_dsym_inventory(archive, inventory)

    def test_dwarfdump_failure_or_empty_uuid_is_rejected(self):
        app_uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        with tempfile.TemporaryDirectory() as tmp:
            archive, _app_binary, _framework_binary, _appex_binary = self.make_fake_archive(tmp)
            inventory = self.write_inventory(tmp, app_uuid)
            failures = (
                subprocess.CompletedProcess([], 1, "", "not a Mach-O"),
                subprocess.CompletedProcess([], 0, "", ""),
            )
            for result in failures:
                with self.subTest(returncode=result.returncode), mock.patch.object(
                    privacy.subprocess, "run", return_value=result
                ):
                    with self.assertRaises(privacy.PrivacyError):
                        privacy.validate_dsym_inventory(archive, inventory)

    def test_archive_root_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, _app, _framework, _appex = self.make_fake_archive(tmp)
            alias = Path(tmp) / "Alias.xcarchive"
            alias.symlink_to(archive, target_is_directory=True)
            inventory = self.write_inventory(
                tmp,
                "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            )
            with self.assertRaisesRegex(privacy.PrivacyError, "real directory"):
                privacy.validate_dsym_inventory(alias, inventory)

    def test_bundle_and_bundle_metadata_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, app_binary, framework_binary, _appex = self.make_fake_archive(tmp)
            app = app_binary.parent

            external_info = Path(tmp) / "ExternalInfo.plist"
            external_info.write_bytes((app / "Info.plist").read_bytes())
            (app / "Info.plist").unlink()
            (app / "Info.plist").symlink_to(external_info)
            with self.assertRaisesRegex(privacy.PrivacyError, "real regular file"):
                privacy.bundle_executable(app)

            (app / "Info.plist").unlink()
            (app / "Info.plist").write_bytes(
                plistlib.dumps({"CFBundleExecutable": "Client"})
            )
            external_binary = Path(tmp) / "ExternalClient"
            external_binary.write_bytes(app_binary.read_bytes())
            app_binary.unlink()
            app_binary.symlink_to(external_binary)
            with self.assertRaisesRegex(privacy.PrivacyError, "real regular file"):
                privacy.bundle_executable(app)

            framework = framework_binary.parent
            framework_alias = Path(tmp) / "FrameworkAlias.framework"
            framework_alias.symlink_to(framework, target_is_directory=True)
            with self.assertRaisesRegex(privacy.PrivacyError, "real directory"):
                privacy.bundle_executable(framework_alias)

            self.assertTrue(archive.is_dir())

    def test_cf_bundle_executable_must_be_a_safe_basename(self):
        unsafe_names = ("../Outside", "/tmp/Outside", "nested/Client", "nested\\Client")
        for unsafe_name in unsafe_names:
            with self.subTest(name=unsafe_name), tempfile.TemporaryDirectory() as tmp:
                archive, app_binary, _framework, _appex = self.make_fake_archive(tmp)
                app = app_binary.parent
                outside = archive / "Products" / "Applications" / "Outside"
                outside.write_bytes(b"outside executable")
                (app / "Info.plist").write_bytes(
                    plistlib.dumps({"CFBundleExecutable": unsafe_name})
                )
                with self.assertRaisesRegex(privacy.PrivacyError, "unsafe"):
                    privacy.bundle_executable(app)

    def test_symlinked_bundle_ancestor_cannot_hide_external_framework(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, app_binary, _framework, _appex = self.make_fake_archive(tmp)
            frameworks = app_binary.parent / "Frameworks"
            external = Path(tmp) / "ExternalFrameworks"
            frameworks.rename(external)
            frameworks.symlink_to(external, target_is_directory=True)
            with self.assertRaisesRegex(privacy.PrivacyError, "symbolic-link directory"):
                privacy.distributed_bundle_executables(app_binary.parent)
            self.assertTrue(archive.is_dir())

    def test_symlinked_archive_component_cannot_escape_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, _app, _framework, _appex = self.make_fake_archive(tmp)
            applications = archive / "Products" / "Applications"
            external = Path(tmp) / "ExternalApplications"
            applications.rename(external)
            applications.symlink_to(external, target_is_directory=True)
            inventory = self.write_inventory(
                tmp,
                "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            )
            with self.assertRaisesRegex(privacy.PrivacyError, "outside the archive"):
                privacy.validate_dsym_inventory(archive, inventory)


if __name__ == "__main__":
    unittest.main()
