"""Unit tests for scripts/release/validate-floorp-release-evidence.py."""

from __future__ import annotations

import base64
import copy
import contextlib
import hashlib
import importlib.util
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


RELEASE_DIR = Path(__file__).parent.parent
SCHEMA = RELEASE_DIR / "floorp-release-evidence.schema.json"
SOURCE_SHA = "a" * 40
MARKETING_VERSION = "0.3.0"
BUILD_NUMBER = "42"
BUNDLE_ID = "app.floorp.Floorp"
APP_ID = "6796708699"
CI_RUN_URL = "https://github.com/Floorp-Projects/floorp-ios/actions/runs/123456"
XCODE_RUN_ID = "xcode-run-42"
XCODE_WORKFLOW_ID = "xcode-workflow-1"
ASC_BUILD_ID = "asc-build-42"
APP_UUID = "A" * 32
FRAMEWORK_UUID = "B" * 32
APPEX_UUID = "C" * 32
SIGNING_IDENTITY = "Apple Distribution: Floorp (DV2U35YBHT)"
ENTITLEMENTS = {
    "application-identifier": f"DV2U35YBHT.{BUNDLE_ID}",
    "com.apple.developer.web-browser": True,
    "keychain-access-groups": [f"DV2U35YBHT.{BUNDLE_ID}"],
    "com.apple.security.application-groups": [
        "group.app.floorp.Floorp.DV2U35YBHT"
    ],
}
PROVISIONING_PROFILE = {
    "TeamIdentifier": ["DV2U35YBHT"],
    "ApplicationIdentifierPrefix": ["DV2U35YBHT"],
    "Entitlements": {
        "application-identifier": f"DV2U35YBHT.{BUNDLE_ID}",
        "com.apple.developer.team-identifier": "DV2U35YBHT",
        "get-task-allow": False,
    },
    "DeveloperCertificates": [b"mock Apple Distribution leaf certificate"],
}
MOCK_ROOT_DER = b"mock reviewed Apple root certificate"
MOCK_ROOT_PEM = (
    b"-----BEGIN CERTIFICATE-----\n"
    + base64.b64encode(MOCK_ROOT_DER)
    + b"\n-----END CERTIFICATE-----\n"
)
MOCK_SIGNER_DER = b"mock Apple provisioning-profile signer"
MOCK_SIGNER_PEM = (
    b"-----BEGIN CERTIFICATE-----\n"
    + base64.b64encode(MOCK_SIGNER_DER)
    + b"\n-----END CERTIFICATE-----\n"
)


def load_module(name: str, filename: str):
    path = RELEASE_DIR / filename
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validator = load_module(
    "validate_floorp_release_evidence", "validate-floorp-release-evidence.py"
)
archive_tree = load_module("floorp_archive_tree_test", "floorp_archive_tree.py")


class FloorpReleaseEvidenceValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.binary_uuids = {}
        self.artifact_index = 0

    def tearDown(self):
        self.temporary.cleanup()

    def make_bundle(self, bundle: Path, executable_name: str, uuid: str) -> Path:
        bundle.mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": executable_name,
                    "CFBundleIdentifier": f"test.{executable_name.lower()}",
                }
            )
        )
        executable = bundle / executable_name
        executable.write_bytes(f"binary:{executable_name}".encode())
        self.binary_uuids[str(executable)] = uuid
        return executable

    def make_archive(self, *, archive_only: bool) -> Path:
        self.artifact_index += 1
        artifact_root = self.root / f"artifact-{self.artifact_index}"
        archive = artifact_root / "Floorp.xcarchive"
        app = archive / "Products" / "Applications" / "Client.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleShortVersionString": MARKETING_VERSION,
                    "CFBundleVersion": BUILD_NUMBER,
                    "CFBundleIdentifier": BUNDLE_ID,
                    "CFBundleExecutable": "Client",
                    "MozFloorpSourceSHA": SOURCE_SHA,
                }
            )
        )
        app_binary = app / "Client"
        app_binary.write_bytes(b"client binary")
        self.binary_uuids[str(app_binary)] = APP_UUID
        self.make_bundle(
            app / "Frameworks" / "Example.framework", "Example", FRAMEWORK_UUID
        )
        self.make_bundle(app / "PlugIns" / "Share.appex", "Share", APPEX_UUID)
        (archive / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "ApplicationProperties": {
                        "Team": "DV2U35YBHT",
                        "SigningIdentity": SIGNING_IDENTITY,
                    }
                }
            )
        )
        dsym_uuids = {
            "Client": APP_UUID,
            "Example": FRAMEWORK_UUID,
            "Share": APPEX_UUID,
        }
        for name, uuid in dsym_uuids.items():
            binary = (
                archive
                / "dSYMs"
                / f"{name}.dSYM"
                / "Contents"
                / "Resources"
                / "DWARF"
                / name
            )
            binary.parent.mkdir(parents=True)
            binary.write_bytes(f"symbols:{name}".encode())
            self.binary_uuids[str(binary)] = uuid
        return archive

    def make_evidence(self, *, artifact_kind: str = "archive-only") -> dict:
        archive_only = artifact_kind == "archive-only"
        archive = self.make_archive(archive_only=archive_only)
        ipa_path = ""
        ipa_sha256 = ""
        ipa_info = None
        signing_identity = SIGNING_IDENTITY
        export_status = None
        if not archive_only:
            ipa = archive.parent / "Floorp.ipa"
            with zipfile.ZipFile(ipa, "w") as ipa_archive:
                ipa_archive.writestr(
                    "Payload/Client.app/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleShortVersionString": MARKETING_VERSION,
                            "CFBundleVersion": BUILD_NUMBER,
                            "CFBundleIdentifier": BUNDLE_ID,
                            "CFBundleExecutable": "Client",
                            "MozFloorpSourceSHA": SOURCE_SHA,
                        }
                    ),
                )
                ipa_archive.writestr(
                    "Payload/Client.app/Client",
                    b"client binary",
                )
                ipa_archive.writestr(
                    "Payload/Client.app/embedded.mobileprovision",
                    b"mock signed provisioning profile",
                )
                ipa_archive.writestr(
                    "Payload/Client.app/Frameworks/Example.framework/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleIdentifier": "test.example",
                            "CFBundleExecutable": "Example",
                        }
                    ),
                )
                ipa_archive.writestr(
                    "Payload/Client.app/Frameworks/Example.framework/Example",
                    b"binary:Example",
                )
                ipa_archive.writestr(
                    "Payload/Client.app/PlugIns/Share.appex/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleIdentifier": "test.share",
                            "CFBundleExecutable": "Share",
                        }
                    ),
                )
                ipa_archive.writestr(
                    "Payload/Client.app/PlugIns/Share.appex/Share",
                    b"binary:Share",
                )
            ipa_path = str(ipa)
            ipa_sha256 = hashlib.sha256(ipa.read_bytes()).hexdigest()
            ipa_info = {
                "marketing_version": MARKETING_VERSION,
                "build_number": BUILD_NUMBER,
            }
            export_status = "ready-for-upload"

        team_id = "DV2U35YBHT"
        inventory = []
        for name, uuid in (
            ("Client", APP_UUID),
            ("Example", FRAMEWORK_UUID),
            ("Share", APPEX_UUID),
        ):
            inventory.append(
                {
                    "uuid": uuid,
                    "path": str(
                        (
                            archive
                            / "dSYMs"
                            / f"{name}.dSYM"
                            / "Contents"
                            / "Resources"
                            / "DWARF"
                            / name
                        ).resolve()
                    ),
                }
            )
        return {
            "schema_version": 1,
            "archive_only": archive_only,
            "source_sha256": SOURCE_SHA,
            "marketing_version": MARKETING_VERSION,
            "build_number": BUILD_NUMBER,
            "bundle_id": BUNDLE_ID,
            "team_id": team_id,
            "archive_path": str(archive),
            "archive_sha256": archive_tree.archive_tree_sha256(archive),
            "ipa_path": ipa_path,
            "ipa_sha256": ipa_sha256,
            "signing_identity": signing_identity,
            "archive_info": {
                "marketing_version": MARKETING_VERSION,
                "build_number": BUILD_NUMBER,
                "bundle_id": BUNDLE_ID,
                "team_id": team_id,
            },
            "ipa_info": ipa_info,
            "entitlements": copy.deepcopy(ENTITLEMENTS),
            "dsym_inventory": inventory,
            "app_store_connect_build_id": None,
            "ci_run_url": None,
            "xcresult_path": None,
            "export_status": export_status,
        }

    def make_receipt(self) -> dict:
        return {
            "schema_version": 1,
            "workflow": {
                "id": XCODE_WORKFLOW_ID,
                "name": "Floorp TestFlight Manual",
                "product_id": "product-1",
            },
            "source": {
                "name": f"floorp-catalog-{SOURCE_SHA}",
                "kind": "tag",
                "reference_id": "tag-reference",
                "commit_sha": SOURCE_SHA,
            },
            "run": {
                "id": XCODE_RUN_ID,
                "execution_progress": "COMPLETE",
                "completion_status": "SUCCEEDED",
                "source_commit": SOURCE_SHA,
                "workflow_id": XCODE_WORKFLOW_ID,
            },
            "baseline": {
                "app_id": APP_ID,
                "build_count": 1,
                "build_ids_sha256": "d" * 64,
                "max_build_number": "41",
            },
            "build": {
                "id": ASC_BUILD_ID,
                "number": BUILD_NUMBER,
                "app_id": APP_ID,
                "bundle_id": BUNDLE_ID,
                "marketing_version": MARKETING_VERSION,
                "platform": "IOS",
                "processing_state": "VALID",
                "build_audience_type": "APP_STORE_ELIGIBLE",
                "expired": False,
                "uses_non_exempt_encryption": False,
                "min_os_version": "18.4",
            },
        }

    def make_artifact_manifest(self, evidence: dict) -> dict:
        artifact_root = Path(evidence["archive_path"]).parent
        archive_download = artifact_root / "authenticated-archive.zip"
        export_download = artifact_root / "authenticated-export.zip"
        archive_download.write_bytes(b"authenticated Xcode Cloud archive wrapper")
        export_download.write_bytes(b"authenticated Xcode Cloud export wrapper")

        def artifact(path: Path, artifact_id: str, file_type: str) -> dict:
            contents = path.read_bytes()
            return {
                "id": artifact_id,
                "file_type": file_type,
                "file_name": path.name,
                "file_size": len(contents),
                "downloaded_size": len(contents),
                "sha256": hashlib.sha256(contents).hexdigest(),
            }

        return {
            "schema_version": 1,
            "run_id": XCODE_RUN_ID,
            "action": {
                "id": "archive-action-42",
                "name": "Archive Floorp",
                "action_type": "ARCHIVE",
                "execution_progress": "COMPLETE",
                "completion_status": "SUCCEEDED",
            },
            "artifacts": {
                "archive": artifact(
                    archive_download, "archive-artifact-42", "ARCHIVE"
                ),
                "archive_export": artifact(
                    export_download, "export-artifact-42", "ARCHIVE_EXPORT"
                ),
            },
            "downloads": {
                "archive": str(archive_download),
                "archive_export": str(export_download),
            },
            "materialized": {
                "archive_path": evidence["archive_path"],
                "archive_tree_sha256": evidence["archive_sha256"],
                "ipa_path": evidence["ipa_path"],
                "ipa_sha256": evidence["ipa_sha256"],
                "ipa_size": Path(evidence["ipa_path"]).stat().st_size,
            },
        }

    def fake_dwarfdump(self, command, **_kwargs):
        if Path(command[0]).name == "security":
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=MOCK_ROOT_PEM,
                stderr=b"",
            )
        if Path(command[0]).name == "openssl":
            if len(command) > 1 and command[1] == "smime":
                Path(command[command.index("-out") + 1]).write_bytes(
                    plistlib.dumps(PROVISIONING_PROFILE)
                )
                Path(command[command.index("-signer") + 1]).write_bytes(
                    MOCK_SIGNER_PEM
                )
                return subprocess.CompletedProcess(
                    command, 0, stdout=b"", stderr=b"Verification successful"
                )
            if len(command) > 1 and command[1] == "x509":
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout=(
                        validator.PROFILE_SIGNER_SUBJECT
                        + "\nCertificate:\n"
                        + f"            {validator.PROFILE_SIGNER_OID}: \n"
                        + "                ..\n"
                    ),
                    stderr="",
                )
            return subprocess.CompletedProcess(
                command, 1, stdout=b"", stderr=b"unexpected openssl command"
            )
        if Path(command[0]).name == "codesign":
            if "--verify" in command:
                return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
            certificate_options = [
                item
                for item in command
                if item.startswith("--extract-certificates=")
            ]
            if certificate_options:
                prefix = certificate_options[0].split("=", 1)[1]
                Path(f"{prefix}0").write_bytes(
                    b"mock Apple Distribution leaf certificate"
                )
                return subprocess.CompletedProcess(
                    command, 0, stdout=b"", stderr=b""
                )
            details = (
                f"Identifier={BUNDLE_ID}\n"
                f"Authority={SIGNING_IDENTITY}\n"
                "Authority=Apple Worldwide Developer Relations Certification Authority\n"
                "TeamIdentifier=DV2U35YBHT\n"
            ).encode()
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=plistlib.dumps(ENTITLEMENTS),
                stderr=details,
            )
        binary = str(Path(command[-1]))
        uuid = self.binary_uuids.get(binary)
        if uuid is None:
            try:
                contents = Path(binary).read_bytes()
            except OSError:
                contents = b""
            uuid = {
                b"client binary": APP_UUID,
                b"binary:Example": FRAMEWORK_UUID,
                b"binary:Share": APPEX_UUID,
                b"alternate signed binary": "D" * 32,
            }.get(contents)
        if uuid is None:
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="unknown binary")
        return subprocess.CompletedProcess(
            command,
            0,
            stdout=f"UUID: {uuid} (arm64) {binary}\n",
            stderr="",
        )

    @contextlib.contextmanager
    def patched_subprocess(self, side_effect):
        fingerprint = hashlib.sha256(MOCK_ROOT_DER).hexdigest()
        with mock.patch.object(
            validator,
            "APPLE_ROOT_CERTIFICATE_SHA256",
            {fingerprint},
        ), mock.patch("subprocess.run", side_effect=side_effect):
            yield

    def write_json(self, name: str, value) -> Path:
        path = self.root / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def validator_arguments(
        self,
        evidence_path: Path,
        *,
        artifact_kind: str,
        phase: str = "pre-upload",
        receipt_path: Path | None = None,
        manifest_path: Path | None = None,
    ) -> list[str]:
        arguments = [
            "--evidence",
            str(evidence_path),
            "--schema",
            str(SCHEMA),
            "--phase",
            phase,
            "--artifact-kind",
            artifact_kind,
            "--expected-source-sha",
            SOURCE_SHA,
            "--expected-marketing-version",
            MARKETING_VERSION,
            "--expected-build-number",
            BUILD_NUMBER,
            "--expected-bundle-id",
            BUNDLE_ID,
        ]
        if phase == "pre-upload" and artifact_kind == "local-export":
            arguments.extend(["--expected-export-status", "ready-for-upload"])
        if phase == "publication":
            arguments.extend(
                [
                    "--expected-ci-run-url",
                    CI_RUN_URL,
                    "--expected-export-status",
                    "uploaded-and-processed",
                    "--expected-app-store-connect-build-id",
                    ASC_BUILD_ID,
                    "--xcode-cloud-build-receipt",
                    str(receipt_path),
                    "--xcode-cloud-artifact-manifest",
                    str(manifest_path),
                    "--expected-xcode-cloud-run-id",
                    XCODE_RUN_ID,
                    "--expected-xcode-cloud-workflow-id",
                    XCODE_WORKFLOW_ID,
                    "--expected-app-id",
                    APP_ID,
                    "--expected-platform",
                    "IOS",
                    "--expected-min-os-version",
                    "18.4",
                ]
            )
        return arguments

    def run_validator(
        self,
        evidence: dict,
        *,
        artifact_kind: str = "archive-only",
        phase: str = "pre-upload",
        receipt: dict | None = None,
        manifest: dict | None = None,
    ) -> int:
        evidence_path = self.write_json("evidence.json", evidence)
        receipt_path = None
        if receipt is not None:
            receipt_path = self.write_json("receipt.json", receipt)
        manifest_path = None
        if phase == "publication":
            if manifest is None:
                manifest = self.make_artifact_manifest(evidence)
            manifest_path = self.write_json("artifact-manifest.json", manifest)
        arguments = self.validator_arguments(
            evidence_path,
            artifact_kind=artifact_kind,
            phase=phase,
            receipt_path=receipt_path,
            manifest_path=manifest_path,
        )
        with self.patched_subprocess(self.fake_dwarfdump):
            return validator.main(arguments)

    def publication_evidence(self, *, artifact_kind: str = "archive-only") -> dict:
        evidence = self.make_evidence(artifact_kind=artifact_kind)
        evidence["app_store_connect_build_id"] = ASC_BUILD_ID
        evidence["ci_run_url"] = CI_RUN_URL
        evidence["export_status"] = "uploaded-and-processed"
        return evidence

    def test_pre_upload_archive_only_and_local_export_pass(self):
        archive_evidence = self.make_evidence()
        self.assertEqual(self.run_validator(archive_evidence), 0)

        local_evidence = self.make_evidence(artifact_kind="local-export")
        self.assertEqual(
            self.run_validator(local_evidence, artifact_kind="local-export"), 0
        )

    def test_signature_verification_targets_complete_app_bundles(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        evidence_path = self.write_json("evidence.json", evidence)
        commands = []

        def record_commands(command, **kwargs):
            commands.append(command)
            return self.fake_dwarfdump(command, **kwargs)

        with self.patched_subprocess(record_commands):
            result = validator.main(
                self.validator_arguments(
                    evidence_path,
                    artifact_kind="local-export",
                )
            )

        self.assertEqual(result, 0)
        verify_commands = [
            command
            for command in commands
            if Path(command[0]).name == "codesign" and "--verify" in command
        ]
        self.assertEqual(len(verify_commands), 2)
        archived_app = (
            Path(evidence["archive_path"])
            / "Products"
            / "Applications"
            / "Client.app"
        )
        self.assertEqual(
            verify_commands[0],
            [
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                "-R",
                validator.APPLE_TEAM_REQUIREMENT,
                str(archived_app),
            ],
        )
        self.assertEqual(
            verify_commands[1][0:6],
            [
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                "-R",
                validator.APPLE_DISTRIBUTION_REQUIREMENT,
                verify_commands[1][-1],
            ],
        )
        self.assertTrue(verify_commands[1][-1].endswith(".app"))
        self.assertNotIn("--ignore-resources", verify_commands[1])
        self.assertNotEqual(Path(verify_commands[1][-1]).suffix, "")

    def test_invalid_exported_app_signature_is_rejected(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        evidence_path = self.write_json("evidence.json", evidence)

        def reject_exported_bundle(command, **kwargs):
            if (
                Path(command[0]).name == "codesign"
                and "--verify" in command
                and "floorp-ipa-signature-" in command[-1]
            ):
                return subprocess.CompletedProcess(
                    command, 1, stdout="", stderr="invalid exported signature"
                )
            return self.fake_dwarfdump(command, **kwargs)

        with self.patched_subprocess(reject_exported_bundle):
            self.assertEqual(
                validator.main(
                    self.validator_arguments(
                        evidence_path,
                        artifact_kind="local-export",
                    )
                ),
                1,
            )

    def test_signature_must_satisfy_apple_team_and_distribution_requirements(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        evidence_path = self.write_json("evidence.json", evidence)

        for rejected_requirement in (
            validator.APPLE_TEAM_REQUIREMENT,
            validator.APPLE_DISTRIBUTION_REQUIREMENT,
        ):
            with self.subTest(requirement=rejected_requirement):
                def reject_requirement(command, **kwargs):
                    if (
                        Path(command[0]).name == "codesign"
                        and "--verify" in command
                        and rejected_requirement in command
                    ):
                        return subprocess.CompletedProcess(
                            command, 1, stdout="", stderr="requirement failed"
                        )
                    return self.fake_dwarfdump(command, **kwargs)

                with self.patched_subprocess(reject_requirement):
                    self.assertEqual(
                        validator.main(
                            self.validator_arguments(
                                evidence_path,
                                artifact_kind="local-export",
                            )
                        ),
                        1,
                    )

    def test_distribution_profile_must_match_signed_floorp_identity(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        evidence_path = self.write_json("evidence.json", evidence)

        def mismatched_profile(command, **kwargs):
            if Path(command[0]).name == "openssl" and command[1] == "smime":
                result = self.fake_dwarfdump(command, **kwargs)
                profile = copy.deepcopy(PROVISIONING_PROFILE)
                profile["TeamIdentifier"] = ["ATTACKERTEAM"]
                Path(command[command.index("-out") + 1]).write_bytes(
                    plistlib.dumps(profile)
                )
                return result
            return self.fake_dwarfdump(command, **kwargs)

        with self.patched_subprocess(mismatched_profile):
            self.assertEqual(
                validator.main(
                    self.validator_arguments(
                        evidence_path,
                        artifact_kind="local-export",
                    )
                ),
                1,
            )

    def test_tampered_mobileprovision_cms_and_wrong_apple_signer_are_rejected(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        evidence_path = self.write_json("evidence.json", evidence)

        def reject_cms(command, **kwargs):
            if Path(command[0]).name == "openssl" and command[1] == "smime":
                self.assertIn("-verify", command)
                self.assertIn("-CAfile", command)
                self.assertNotIn("-noverify", command)
                return subprocess.CompletedProcess(
                    command, 4, stdout=b"", stderr=b"signature failure"
                )
            return self.fake_dwarfdump(command, **kwargs)

        with self.patched_subprocess(reject_cms):
            self.assertEqual(
                validator.main(
                    self.validator_arguments(
                        evidence_path,
                        artifact_kind="local-export",
                    )
                ),
                1,
            )

        def wrong_signer(command, **kwargs):
            if Path(command[0]).name == "openssl" and command[1] == "x509":
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout="subject= C=US,O=Apple Inc.,CN=Apple Distribution\n",
                    stderr="",
                )
            return self.fake_dwarfdump(command, **kwargs)

        with self.patched_subprocess(wrong_signer):
            self.assertEqual(
                validator.main(
                    self.validator_arguments(
                        evidence_path,
                        artifact_kind="local-export",
                    )
                ),
                1,
            )

    def test_publication_cross_checks_xcode_cloud_receipt(self):
        evidence = self.publication_evidence(artifact_kind="local-export")
        self.assertEqual(
            self.run_validator(
                evidence,
                artifact_kind="local-export",
                phase="publication",
                receipt=self.make_receipt(),
            ),
            0,
        )

    def test_publication_cross_checks_authenticated_artifact_manifest(self):
        def alias_downloads(manifest):
            manifest["downloads"]["archive_export"] = manifest["downloads"]["archive"]
            archive = manifest["artifacts"]["archive"]
            exported = manifest["artifacts"]["archive_export"]
            exported["file_size"] = archive["file_size"]
            exported["downloaded_size"] = archive["downloaded_size"]
            exported["sha256"] = archive["sha256"]

        mutations = (
            ("run", lambda manifest: manifest.__setitem__("run_id", "other-run")),
            (
                "action-status",
                lambda manifest: manifest["action"].__setitem__(
                    "completion_status", "FAILED"
                ),
            ),
            (
                "archive-id",
                lambda manifest: manifest["artifacts"]["archive"].__setitem__(
                    "id", manifest["artifacts"]["archive_export"]["id"]
                ),
            ),
            (
                "archive-digest",
                lambda manifest: manifest["materialized"].__setitem__(
                    "archive_tree_sha256", "b" * 64
                ),
            ),
            (
                "download-digest",
                lambda manifest: manifest["artifacts"]["archive"].__setitem__(
                    "sha256", "b" * 64
                ),
            ),
            ("aliased-downloads", alias_downloads),
            (
                "ipa-digest",
                lambda manifest: manifest["materialized"].__setitem__(
                    "ipa_sha256", "b" * 64
                ),
            ),
        )
        for label, mutation in mutations:
            with self.subTest(label=label):
                evidence = self.publication_evidence(artifact_kind="local-export")
                manifest = self.make_artifact_manifest(evidence)
                mutation(manifest)
                self.assertEqual(
                    self.run_validator(
                        evidence,
                        artifact_kind="local-export",
                        phase="publication",
                        receipt=self.make_receipt(),
                        manifest=manifest,
                    ),
                    1,
                )

    def test_publication_rejects_archive_only_evidence(self):
        self.assertEqual(
            self.run_validator(
                self.publication_evidence(),
                phase="publication",
                receipt=self.make_receipt(),
            ),
            1,
        )

    def test_internally_consistent_arbitrary_source_sha_fails(self):
        evidence = self.make_evidence()
        evidence["source_sha256"] = "b" * 40
        self.assertEqual(self.run_validator(evidence), 1)

    def test_internally_consistent_version_change_fails(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        evidence["marketing_version"] = "9.9.9"
        evidence["archive_info"]["marketing_version"] = "9.9.9"
        evidence["ipa_info"]["marketing_version"] = "9.9.9"
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_internally_consistent_build_number_change_fails(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        evidence["build_number"] = "999999"
        evidence["archive_info"]["build_number"] = "999999"
        evidence["ipa_info"]["build_number"] = "999999"
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_nonexistent_archive_fails(self):
        evidence = self.make_evidence()
        evidence["archive_path"] = str(self.root / "missing.xcarchive")
        self.assertEqual(self.run_validator(evidence), 1)

    def test_archived_app_cannot_escape_through_intermediate_symlink(self):
        evidence = self.make_evidence()
        archive = Path(evidence["archive_path"])
        applications = archive / "Products" / "Applications"
        external = self.root / "ExternalApplications"
        applications.rename(external)
        applications.symlink_to(external, target_is_directory=True)

        with self.assertRaisesRegex(validator.ValidationError, "symbolic-link"):
            validator.validate_archive_metadata(archive, evidence, SOURCE_SHA, "local-export")

    def test_cloud_archive_requires_an_adhoc_signature(self):
        adhoc = (
            f"Identifier={BUNDLE_ID}\n"
            "Signature=adhoc\n"
            "TeamIdentifier=not set\n"
        ).encode()

        def run_adhoc(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, stdout=b"", stderr=adhoc)

        with mock.patch.object(validator.subprocess, "run", run_adhoc):
            validator.assert_adhoc_archive_signature(self.root / "Client.app")

        distribution = (
            f"Identifier={BUNDLE_ID}\n"
            f"Authority={SIGNING_IDENTITY}\n"
            "TeamIdentifier=DV2U35YBHT\n"
        ).encode()

        def run_distribution(command, **kwargs):
            return subprocess.CompletedProcess(
                command, 0, stdout=b"", stderr=distribution
            )

        with mock.patch.object(validator.subprocess, "run", run_distribution):
            with self.assertRaisesRegex(validator.ValidationError, "authority"):
                validator.assert_adhoc_archive_signature(self.root / "Client.app")

    def test_artifact_paths_must_be_absolute_and_canonical(self):
        evidence = self.make_evidence()
        evidence["archive_path"] = "relative/Floorp.xcarchive"
        self.assertEqual(self.run_validator(evidence), 1)

        evidence = self.make_evidence()
        archive = Path(evidence["archive_path"])
        (archive.parent / "existing").mkdir()
        evidence["archive_path"] = str(
            archive.parent / "existing" / ".." / archive.name
        )
        self.assertEqual(self.run_validator(evidence), 1)

        evidence = self.make_evidence(artifact_kind="local-export")
        evidence["ipa_path"] = "relative/Floorp.ipa"
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_archive_tree_tampering_fails(self):
        evidence = self.make_evidence()
        app_binary = (
            Path(evidence["archive_path"])
            / "Products"
            / "Applications"
            / "Client.app"
            / "Client"
        )
        app_binary.write_bytes(b"tampered client binary")
        self.assertEqual(self.run_validator(evidence), 1)

    def test_archive_plist_mismatch_fails_even_with_updated_tree_digest(self):
        evidence = self.make_evidence()
        archive = Path(evidence["archive_path"])
        info_path = archive / "Products" / "Applications" / "Client.app" / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleShortVersionString"] = "9.9.9"
        info_path.write_bytes(plistlib.dumps(info))
        evidence["archive_sha256"] = archive_tree.archive_tree_sha256(archive)
        self.assertEqual(self.run_validator(evidence), 1)

    def test_archive_embedded_source_sha_is_externally_bound(self):
        evidence = self.make_evidence()
        archive = Path(evidence["archive_path"])
        info_path = archive / "Products" / "Applications" / "Client.app" / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["MozFloorpSourceSHA"] = "b" * 40
        info_path.write_bytes(plistlib.dumps(info))
        evidence["archive_sha256"] = archive_tree.archive_tree_sha256(archive)
        self.assertEqual(self.run_validator(evidence), 1)

    def test_ipa_plist_mismatch_fails_even_with_updated_ipa_digest(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        ipa = Path(evidence["ipa_path"])
        with zipfile.ZipFile(ipa, "w") as ipa_archive:
            ipa_archive.writestr(
                "Payload/Client.app/Info.plist",
                plistlib.dumps(
                    {
                        "CFBundleShortVersionString": "9.9.9",
                        "CFBundleVersion": BUILD_NUMBER,
                        "CFBundleIdentifier": BUNDLE_ID,
                        "CFBundleExecutable": "Client",
                        "MozFloorpSourceSHA": SOURCE_SHA,
                    }
                ),
            )
            ipa_archive.writestr(
                "Payload/Client.app/Client",
                b"signed IPA executable",
            )
        evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_ipa_embedded_source_sha_is_externally_bound(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        ipa = Path(evidence["ipa_path"])
        with zipfile.ZipFile(ipa) as source:
            entries = [(entry, source.read(entry)) for entry in source.infolist()]
        with zipfile.ZipFile(ipa, "w") as destination:
            for entry, contents in entries:
                if entry.filename == "Payload/Client.app/Info.plist":
                    info = plistlib.loads(contents)
                    info["MozFloorpSourceSHA"] = "b" * 40
                    contents = plistlib.dumps(info)
                destination.writestr(entry, contents)
        evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()

        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_ipa_with_multiple_direct_payload_apps_fails(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        ipa = Path(evidence["ipa_path"])
        with zipfile.ZipFile(ipa, "a") as ipa_archive:
            ipa_archive.writestr(
                "Payload/Other.app/Info.plist",
                plistlib.dumps(
                    {
                        "CFBundleShortVersionString": MARKETING_VERSION,
                        "CFBundleVersion": BUILD_NUMBER,
                        "CFBundleIdentifier": "other.bundle",
                        "CFBundleExecutable": "Other",
                    }
                ),
            )
            ipa_archive.writestr("Payload/Other.app/Other", b"other executable")
        evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_ipa_rejects_unsafe_members_outside_selected_payload_app(self):
        cases = ("../outside", "/absolute", "Sibling/../../outside", "Sibling\\outside")
        for member in cases:
            with self.subTest(member=member):
                evidence = self.make_evidence(artifact_kind="local-export")
                ipa = Path(evidence["ipa_path"])
                with zipfile.ZipFile(ipa, "a") as ipa_archive:
                    ipa_archive.writestr(member, b"ignored attacker bytes")
                evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()

                self.assertEqual(
                    self.run_validator(evidence, artifact_kind="local-export"), 1
                )

    def test_ipa_rejects_casefold_alias_and_sibling_symlink(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        ipa = Path(evidence["ipa_path"])
        with zipfile.ZipFile(ipa, "a") as ipa_archive:
            ipa_archive.writestr("SwiftSupport/Foo", b"one")
            ipa_archive.writestr("swiftsupport/foo", b"two")
        evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

        evidence = self.make_evidence(artifact_kind="local-export")
        ipa = Path(evidence["ipa_path"])
        link = zipfile.ZipInfo("Symbols/external-link")
        link.create_system = 3
        link.external_attr = (0o120777 << 16)
        with zipfile.ZipFile(ipa, "a") as ipa_archive:
            ipa_archive.writestr(link, "../../outside")
        evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_ipa_allows_safe_swift_support_symbols_and_watchkit_roots(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        ipa = Path(evidence["ipa_path"])
        with zipfile.ZipFile(ipa, "a") as ipa_archive:
            ipa_archive.writestr("SwiftSupport/iphoneos/libswiftFoo.dylib", b"swift")
            ipa_archive.writestr("Symbols/Client.symbols", b"symbols")
            ipa_archive.writestr("WatchKitSupport/WK", b"watch support")
        evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()

        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 0
        )

    def test_ipa_rejects_file_directory_conflicts_and_excessive_compression(self):
        for order in ("file-first", "child-first"):
            with self.subTest(order=order):
                evidence = self.make_evidence(artifact_kind="local-export")
                ipa = Path(evidence["ipa_path"])
                with zipfile.ZipFile(ipa, "a") as ipa_archive:
                    if order == "file-first":
                        ipa_archive.writestr("Symbols", b"regular")
                        ipa_archive.writestr("Symbols/child", b"child")
                    else:
                        ipa_archive.writestr("Symbols/child", b"child")
                        ipa_archive.writestr("Symbols", b"regular")
                evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
                self.assertEqual(
                    self.run_validator(evidence, artifact_kind="local-export"), 1
                )

        evidence = self.make_evidence(artifact_kind="local-export")
        ipa = Path(evidence["ipa_path"])
        with zipfile.ZipFile(ipa, "a", compression=zipfile.ZIP_DEFLATED) as ipa_archive:
            ipa_archive.writestr("Symbols/compression-bomb", b"\0" * (8 * 1024 * 1024))
        evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_valid_signature_ipa_with_different_executable_uuid_is_rejected(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        ipa = Path(evidence["ipa_path"])
        with zipfile.ZipFile(ipa) as source:
            entries = [(entry, source.read(entry)) for entry in source.infolist()]
        with zipfile.ZipFile(ipa, "w") as destination:
            for entry, contents in entries:
                if entry.filename == "Payload/Client.app/Client":
                    contents = b"alternate signed binary"
                destination.writestr(entry, contents)
        evidence["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()

        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_unsigned_archive_only_artifact_fails(self):
        evidence = self.make_evidence()
        evidence_path = self.write_json("evidence.json", evidence)
        arguments = self.validator_arguments(
            evidence_path,
            artifact_kind="archive-only",
        )

        def fail_codesign(command, **kwargs):
            if Path(command[0]).name == "codesign":
                output = "" if kwargs.get("text") else b""
                error = "not signed" if kwargs.get("text") else b"not signed"
                return subprocess.CompletedProcess(command, 1, output, error)
            return self.fake_dwarfdump(command, **kwargs)

        with self.patched_subprocess(fail_codesign):
            self.assertEqual(validator.main(arguments), 1)

    def test_fake_dsym_inventory_missing_shipped_framework_uuid_fails(self):
        evidence = self.make_evidence()
        evidence["dsym_inventory"] = [
            entry for entry in evidence["dsym_inventory"] if entry["uuid"] != FRAMEWORK_UUID
        ]
        self.assertEqual(self.run_validator(evidence), 1)

    def test_evidence_file_swap_after_load_cannot_change_dsym_coverage(self):
        evidence = self.make_evidence()
        evidence_path = self.write_json("evidence.json", evidence)
        swapped = False

        def swap_after_load(command, **kwargs):
            nonlocal swapped
            if not swapped:
                swapped = True
                replacement = copy.deepcopy(evidence)
                replacement["dsym_inventory"] = []
                evidence_path.write_text(json.dumps(replacement), encoding="utf-8")
            return self.fake_dwarfdump(command, **kwargs)

        with self.patched_subprocess(swap_after_load):
            result = validator.main(
                self.validator_arguments(
                    evidence_path,
                    artifact_kind="archive-only",
                )
            )

        self.assertTrue(swapped)
        self.assertEqual(result, 0)

    def test_archive_rename_swap_during_validation_is_rejected_by_closing_hash(self):
        evidence = self.make_evidence()
        evidence_path = self.write_json("evidence.json", evidence)
        archive = Path(evidence["archive_path"])
        swapped = False

        def swap_archive(command, **kwargs):
            nonlocal swapped
            if (
                not swapped
                and Path(command[0]).name == "codesign"
                and "-dvv" in command
            ):
                swapped = True
                original = archive.with_name("Original.xcarchive")
                replacement = archive.with_name("Replacement.xcarchive")
                shutil.copytree(archive, replacement)
                (replacement / "late-swap-marker").write_bytes(b"different archive")
                archive.rename(original)
                replacement.rename(archive)
            return self.fake_dwarfdump(command, **kwargs)

        with self.patched_subprocess(swap_archive):
            result = validator.main(
                self.validator_arguments(
                    evidence_path,
                    artifact_kind="archive-only",
                )
            )
        self.assertTrue(swapped)
        self.assertEqual(result, 1)

    def test_ipa_rename_swap_during_validation_is_rejected_by_closing_hash(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        evidence_path = self.write_json("evidence.json", evidence)
        ipa = Path(evidence["ipa_path"])
        swapped = False

        def swap_ipa(command, **kwargs):
            nonlocal swapped
            if not swapped and Path(command[0]).name == "security":
                swapped = True
                replacement = ipa.with_name("Replacement.ipa")
                shutil.copy2(ipa, replacement)
                with zipfile.ZipFile(replacement, "a") as ipa_archive:
                    ipa_archive.writestr("Symbols/late-swap-marker", b"different IPA")
                original = ipa.with_name("Original.ipa")
                ipa.rename(original)
                replacement.rename(ipa)
            return self.fake_dwarfdump(command, **kwargs)

        with self.patched_subprocess(swap_ipa):
            result = validator.main(
                self.validator_arguments(
                    evidence_path,
                    artifact_kind="local-export",
                )
            )
        self.assertTrue(swapped)
        self.assertEqual(result, 1)

    def test_fake_dsym_path_with_matching_uuid_fails(self):
        evidence = self.make_evidence()
        framework = next(
            entry
            for entry in evidence["dsym_inventory"]
            if entry["uuid"] == FRAMEWORK_UUID
        )
        framework["path"] = str(
            self.root
            / "Fake.dSYM"
            / "Contents"
            / "Resources"
            / "DWARF"
            / "Fake"
        )
        self.assertEqual(self.run_validator(evidence), 1)

    def test_dsym_intermediate_symlink_escape_is_rejected(self):
        evidence = self.make_evidence()
        archive = Path(evidence["archive_path"])
        dsym = archive / "dSYMs" / "Client.dSYM"
        original_contents = dsym / "Contents"
        external_dsym = self.root / "External.dSYM"
        external_contents = external_dsym / "Contents"
        external_dsym.mkdir()
        original_contents.rename(external_contents)
        original_contents.symlink_to(external_contents, target_is_directory=True)
        external_binary = external_contents / "Resources" / "DWARF" / "Client"
        self.binary_uuids[str(external_binary)] = APP_UUID
        client_entry = next(
            entry for entry in evidence["dsym_inventory"] if entry["uuid"] == APP_UUID
        )
        client_entry["path"] = str(external_binary.resolve())

        self.assertEqual(self.run_validator(evidence), 1)

    def test_local_export_requires_existing_ipa_and_metadata(self):
        evidence = self.make_evidence(artifact_kind="local-export")
        Path(evidence["ipa_path"]).unlink()
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

        evidence = self.make_evidence(artifact_kind="local-export")
        evidence["ipa_info"] = None
        self.assertEqual(
            self.run_validator(evidence, artifact_kind="local-export"), 1
        )

    def test_publication_identity_fields_are_externally_bound(self):
        cases = (
            ("app_store_connect_build_id", "other-build"),
            (
                "ci_run_url",
                "https://github.com/Floorp-Projects/floorp-ios/actions/runs/999999",
            ),
            ("export_status", "ready-for-upload"),
        )
        for field, value in cases:
            with self.subTest(field=field):
                evidence = self.publication_evidence(artifact_kind="local-export")
                evidence[field] = value
                self.assertEqual(
                    self.run_validator(
                        evidence,
                        artifact_kind="local-export",
                        phase="publication",
                        receipt=self.make_receipt(),
                    ),
                    1,
                )

    def test_receipt_mismatch_fails(self):
        receipt = self.make_receipt()
        receipt["run"]["id"] = "other-xcode-run"
        self.assertEqual(
            self.run_validator(
                self.publication_evidence(artifact_kind="local-export"),
                artifact_kind="local-export",
                phase="publication",
                receipt=receipt,
            ),
            1,
        )

    def test_pre_upload_rejects_final_identity_fields(self):
        evidence = self.make_evidence()
        evidence["app_store_connect_build_id"] = ASC_BUILD_ID
        self.assertEqual(self.run_validator(evidence), 1)

        evidence = self.make_evidence()
        evidence_path = self.write_json("evidence.json", evidence)
        manifest_path = self.write_json("unexpected-manifest.json", {})
        arguments = self.validator_arguments(
            evidence_path,
            artifact_kind="archive-only",
        )
        arguments.extend(["--xcode-cloud-artifact-manifest", str(manifest_path)])
        with self.patched_subprocess(self.fake_dwarfdump):
            self.assertEqual(validator.main(arguments), 1)

    def test_bundle_team_entitlements_and_mixed_build_are_checked(self):
        mutations = []

        def wrong_bundle(evidence):
            evidence["bundle_id"] = "attacker.bundle"

        mutations.append(wrong_bundle)

        def wrong_team(evidence):
            evidence["team_id"] = "ATTACKERTEAM"

        mutations.append(wrong_team)

        def forbidden_entitlement(evidence):
            evidence["entitlements"]["aps-environment"] = "production"

        mutations.append(forbidden_entitlement)

        def mixed_build(evidence):
            evidence["ipa_info"]["build_number"] = "43"

        mutations.append(mixed_build)

        for mutation in mutations:
            with self.subTest(mutation=mutation.__name__):
                evidence = self.make_evidence(artifact_kind="local-export")
                mutation(evidence)
                self.assertEqual(
                    self.run_validator(evidence, artifact_kind="local-export"), 1
                )

    def test_nested_dsym_schema_is_enforced(self):
        evidence = self.make_evidence()
        evidence["dsym_inventory"] = [
            {
                "uuid": APP_UUID,
                "path": "arm64",
            }
        ]
        self.assertEqual(self.run_validator(evidence), 1)

    def test_malformed_json_exits_two(self):
        malformed_documents = (
            "not json",
            '{"schema_version":1,"schema_version":1}',
            '{"schema_version":NaN}',
        )
        for index, document in enumerate(malformed_documents):
            with self.subTest(document=document):
                evidence_path = self.root / f"malformed-{index}.json"
                evidence_path.write_text(document, encoding="utf-8")
                arguments = self.validator_arguments(
                    evidence_path,
                    artifact_kind="archive-only",
                )
                self.assertEqual(validator.main(arguments), 2)

    def test_boolean_schema_version_is_rejected(self):
        evidence = self.make_evidence()
        evidence["schema_version"] = True
        self.assertEqual(self.run_validator(evidence), 1)

    def test_missing_required_nested_object_is_controlled_rejection(self):
        evidence = self.make_evidence()
        del evidence["archive_info"]
        self.assertEqual(self.run_validator(evidence), 1)

    def test_bare_legacy_cli_fails_closed(self):
        evidence_path = self.write_json("evidence.json", self.make_evidence())
        with self.assertRaises(SystemExit) as raised:
            validator.main(
                ["--evidence", str(evidence_path), "--schema", str(SCHEMA)]
            )
        self.assertEqual(raised.exception.code, 2)

    def test_direct_api_rejects_unknown_phase_and_artifact_kind(self):
        evidence = self.make_evidence()
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        base = {
            "expected_source_sha": SOURCE_SHA,
            "expected_marketing_version": MARKETING_VERSION,
            "expected_build_number": BUILD_NUMBER,
            "expected_bundle_id": BUNDLE_ID,
        }
        for phase, artifact_kind in (
            ("unknown", "archive-only"),
            ("pre-upload", "unknown"),
        ):
            with self.subTest(phase=phase, artifact_kind=artifact_kind):
                with self.assertRaises(validator.ValidationError):
                    validator.validate_release_evidence(
                        schema,
                        evidence,
                        phase=phase,
                        artifact_kind=artifact_kind,
                        **base,
                    )

    def test_receipt_mutations_cover_external_expected_identity(self):
        mutations = (
            (("run", "workflow_id"), "other-workflow"),
            (("source", "commit_sha"), "b" * 40),
            (("build", "id"), "other-build"),
            (("build", "number"), "43"),
            (("build", "marketing_version"), "9.9.9"),
            (("build", "app_id"), "other-app"),
            (("build", "bundle_id"), "other.bundle"),
            (("build", "platform"), "MAC_OS"),
            (("build", "min_os_version"), "18.5"),
        )
        for path, value in mutations:
            with self.subTest(path=path):
                receipt = copy.deepcopy(self.make_receipt())
                receipt[path[0]][path[1]] = value
                self.assertEqual(
                    self.run_validator(
                        self.publication_evidence(artifact_kind="local-export"),
                        artifact_kind="local-export",
                        phase="publication",
                        receipt=receipt,
                    ),
                    1,
                )


if __name__ == "__main__":
    unittest.main()
