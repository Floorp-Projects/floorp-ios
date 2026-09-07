"""Integration tests for scripts/release/collect-floorp-release-evidence.sh."""

import importlib.util
import json
import os
import plistlib
import shlex
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


RELEASE_DIR = Path(__file__).parent.parent
COLLECTOR = RELEASE_DIR / "collect-floorp-release-evidence.sh"


def load_archive_tree_module():
    path = RELEASE_DIR / "floorp_archive_tree.py"
    spec = importlib.util.spec_from_file_location("floorp_archive_tree_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


archive_tree = load_archive_tree_module()


class FloorpReleaseEvidenceCollectorTests(unittest.TestCase):
    def make_fake_archive(self, root, include_dsym=True):
        archive = Path(root) / "Floorp.xcarchive"
        app = archive / "Products" / "Applications" / "Client.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.3.0",
            "CFBundleVersion": "42",
            "CFBundleIdentifier": "app.floorp.Floorp",
            "CFBundleExecutable": "Client",
            "MozFloorpSourceSHA": "a" * 40,
        }))
        (app / "Client").write_bytes(b"app binary")
        (archive / "Info.plist").write_bytes(plistlib.dumps({
            "ApplicationProperties": {
                "Team": "DV2U35YBHT",
                "SigningIdentity": "Apple Distribution: Floorp",
            },
        }))
        dwarf_binary = (
            archive / "dSYMs" / "Client.app.dSYM"
            / "Contents" / "Resources" / "DWARF" / "Client"
        )
        if include_dsym:
            dwarf_binary.parent.mkdir(parents=True)
            dwarf_binary.write_bytes(b"debug symbols")
        return archive, dwarf_binary

    def install_fake_dwarfdump(self, root, body, *, command_log=None):
        bin_dir = Path(root) / "bin"
        bin_dir.mkdir(exist_ok=True)
        executable = bin_dir / "dwarfdump"
        executable.write_text("#!/bin/sh\n" + body)
        executable.chmod(0o755)
        entitlements = bin_dir / "entitlements.plist"
        entitlements.write_bytes(
            plistlib.dumps(
                {
                    "application-identifier": "DV2U35YBHT.app.floorp.Floorp",
                    "com.apple.developer.web-browser": True,
                    "keychain-access-groups": [
                        "DV2U35YBHT.app.floorp.Floorp"
                    ],
                    "com.apple.security.application-groups": [
                        "group.app.floorp.Floorp.DV2U35YBHT"
                    ],
                }
            )
        )
        codesign = bin_dir / "codesign"
        log_command = ""
        if command_log is not None:
            log_command = (
                "printf '%s\\n' \"$*\" >> "
                f"{shlex.quote(str(command_log))}\n"
            )
        codesign.write_text(
            "#!/bin/sh\n"
            + log_command
            + "case \" $* \" in\n"
            "  *\" --entitlements \"*) "
            f"cat {shlex.quote(str(entitlements))} ;;\n"
            "esac\n"
            "echo 'Authority=Apple Distribution: Floorp (DV2U35YBHT)' >&2\n"
            "echo 'TeamIdentifier=DV2U35YBHT' >&2\n"
        )
        codesign.chmod(0o755)
        return bin_dir

    def run_collector(
        self,
        root,
        archive,
        bin_dir,
        *,
        archive_only=True,
        ipa=None,
        temporary_root=None,
        output_path=None,
    ):
        output = Path(root) / "evidence.json" if output_path is None else Path(output_path)
        environment = os.environ.copy()
        environment["PATH"] = f"{bin_dir}:{environment['PATH']}"
        if temporary_root is not None:
            environment["TMPDIR"] = str(temporary_root)
        arguments = [
            str(COLLECTOR),
            "--archive",
            str(archive),
            "--source-sha",
            "a" * 40,
            "--output",
            str(output),
        ]
        if archive_only:
            arguments.append("--archive-only")
        else:
            arguments.extend(["--ipa", str(ipa)])
        result = subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            env=environment,
        )
        return result, output

    def test_collects_normalized_uuid_from_actual_dwarf_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, dwarf_binary = self.make_fake_archive(tmp)
            bin_dir = self.install_fake_dwarfdump(tmp, r'''
if [ "$1" != "--uuid" ] || [ ! -f "$2" ]; then
    exit 70
fi
case "$2" in
    *.dSYM/Contents/Resources/DWARF/*) ;;
    *) exit 71 ;;
esac
printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef (arm64) %s\n' "$2"
''')
            result, output = self.run_collector(tmp, archive, bin_dir)

            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads(output.read_text())
            self.assertEqual(
                evidence["archive_sha256"],
                archive_tree.archive_tree_sha256(archive),
            )
            inventory = evidence["dsym_inventory"]
            self.assertEqual(inventory, [{
                "uuid": "1234567890ABCDEF1234567890ABCDEF",
                "path": str(dwarf_binary.resolve()),
            }])

    def test_archive_tree_digest_covers_regular_files_and_symlink_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archives = []
            for name in ("one.xcarchive", "two.xcarchive"):
                archive = root / name
                nested = archive / "nested"
                nested.mkdir(parents=True)
                (nested / "payload").write_bytes(b"same bytes")
                os.symlink("nested/payload", archive / "payload-link")
                archives.append(archive)

            first = archive_tree.archive_tree_sha256(archives[0])
            self.assertEqual(first, archive_tree.archive_tree_sha256(archives[1]))

            (archives[1] / "nested" / "payload").write_bytes(b"changed bytes")
            self.assertNotEqual(first, archive_tree.archive_tree_sha256(archives[1]))

            (archives[1] / "nested" / "payload").write_bytes(b"same bytes")
            (archives[1] / "payload-link").unlink()
            (archives[1] / "other-target").write_bytes(b"other bytes")
            os.symlink("other-target", archives[1] / "payload-link")
            self.assertNotEqual(first, archive_tree.archive_tree_sha256(archives[1]))

    def test_archive_tree_rejects_broken_external_and_cyclic_symlinks(self):
        for kind in ("broken", "external", "cycle"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive = root / "Floorp.xcarchive"
                archive.mkdir()
                if kind == "broken":
                    (archive / "link").symlink_to("missing")
                elif kind == "external":
                    external = root / "outside"
                    external.write_bytes(b"outside")
                    (archive / "link").symlink_to(external)
                else:
                    (archive / "first").symlink_to("second")
                    (archive / "second").symlink_to("first")
                with self.assertRaises(archive_tree.ArchiveTreeError):
                    archive_tree.archive_tree_sha256(archive)

    def test_missing_dsym_inventory_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, _dwarf_binary = self.make_fake_archive(tmp, include_dsym=False)
            bin_dir = self.install_fake_dwarfdump(tmp, "exit 99\n")
            result, output = self.run_collector(tmp, archive, bin_dir)

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_dsym_intermediate_symlink_escape_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, dwarf_binary = self.make_fake_archive(root)
            dsym = archive / "dSYMs" / "Client.app.dSYM"
            original_contents = dsym / "Contents"
            external_dsym = root / "External.dSYM"
            external_contents = external_dsym / "Contents"
            external_dsym.mkdir()
            original_contents.rename(external_contents)
            original_contents.symlink_to(external_contents, target_is_directory=True)
            self.assertTrue((external_contents / "Resources" / "DWARF" / dwarf_binary.name).is_file())
            bin_dir = self.install_fake_dwarfdump(
                root,
                "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                "(arm64) %s\\n' \"$2\"\n",
            )

            result, output = self.run_collector(root, archive, bin_dir)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive symlink", result.stderr)
            self.assertFalse(output.exists())

    def test_local_export_requires_extractable_ipa_info_and_cleans_up(self):
        cases = ("malformed", "missing-info")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive, _dwarf_binary = self.make_fake_archive(root)
                bin_dir = self.install_fake_dwarfdump(
                    root,
                    "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                    "(arm64) %s\\n' \"$2\"\n",
                )
                ipa = root / "Floorp.ipa"
                if case == "malformed":
                    ipa.write_bytes(b"not a zip archive")
                else:
                    with zipfile.ZipFile(ipa, "w") as archive_file:
                        archive_file.writestr(
                            "Payload/Client.app/Client", b"app binary"
                        )
                temporary_root = root / "collector-tmp"
                temporary_root.mkdir()

                result, output = self.run_collector(
                    root,
                    archive,
                    bin_dir,
                    archive_only=False,
                    ipa=ipa,
                    temporary_root=temporary_root,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
                self.assertEqual(list(temporary_root.iterdir()), [])

    def test_local_export_collects_selected_ipa_signature_and_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            archive_info_path = archive / "Info.plist"
            archive_info = plistlib.loads(archive_info_path.read_bytes())
            archive_info["ApplicationProperties"]["SigningIdentity"] = (
                "Apple Development: Floorp (DV2U35YBHT)"
            )
            archive_info_path.write_bytes(plistlib.dumps(archive_info))
            bin_dir = self.install_fake_dwarfdump(
                root,
                "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                "(arm64) %s\\n' \"$2\"\n",
            )
            ipa = root / "Floorp.ipa"
            with zipfile.ZipFile(ipa, "w") as archive_file:
                archive_file.writestr(
                    "Payload/Floorp.app/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleShortVersionString": "0.3.0",
                            "CFBundleVersion": "42",
                            "CFBundleIdentifier": "app.floorp.Floorp",
                            "CFBundleExecutable": "Floorp",
                            "MozFloorpSourceSHA": "a" * 40,
                        }
                    ),
                )
                archive_file.writestr(
                    "Payload/Floorp.app/Floorp",
                    b"signed executable",
                )

            result, output = self.run_collector(
                root,
                archive,
                bin_dir,
                archive_only=False,
                ipa=ipa,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads(output.read_text())
            self.assertEqual(
                evidence["signing_identity"],
                "Apple Distribution: Floorp (DV2U35YBHT)",
            )
            self.assertEqual(evidence["team_id"], "DV2U35YBHT")
            self.assertEqual(
                evidence["ipa_info"],
                {"marketing_version": "0.3.0", "build_number": "42"},
            )

    def test_collector_verifies_archive_strictly_and_ipa_as_app_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            command_log = root / "codesign-commands.txt"
            bin_dir = self.install_fake_dwarfdump(
                root,
                "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                "(arm64) %s\\n' \"$2\"\n",
                command_log=command_log,
            )
            ipa = root / "Floorp.ipa"
            with zipfile.ZipFile(ipa, "w") as ipa_archive:
                ipa_archive.writestr(
                    "Payload/Floorp.app/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleShortVersionString": "0.3.0",
                            "CFBundleVersion": "42",
                            "CFBundleIdentifier": "app.floorp.Floorp",
                            "CFBundleExecutable": "Floorp",
                            "MozFloorpSourceSHA": "a" * 40,
                        }
                    ),
                )
                ipa_archive.writestr("Payload/Floorp.app/Floorp", b"signed")

            result, _output = self.run_collector(
                root,
                archive,
                bin_dir,
                archive_only=False,
                ipa=ipa,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            commands = command_log.read_text().splitlines()
            archived_app = archive.resolve() / "Products" / "Applications" / "Client.app"
            archive_verify = [
                command
                for command in commands
                if command.startswith("--verify --strict -R ")
                and command.endswith(str(archived_app))
            ]
            self.assertEqual(len(archive_verify), 1)
            self.assertIn("anchor apple generic", archive_verify[0])
            self.assertIn('subject.OU] = "DV2U35YBHT"', archive_verify[0])
            ipa_verify = [
                command
                for command in commands
                if command.startswith("--verify --strict -R ")
                and command.endswith("/Exported.app")
            ]
            self.assertEqual(len(ipa_verify), 1)
            self.assertIn("1.2.840.113635.100.6.1.4", ipa_verify[0])
            self.assertTrue(ipa_verify[0].endswith("/Exported.app"))
            ipa_inspections = [
                command
                for command in commands
                if command.startswith("-d") and "/Exported.app" in command
            ]
            self.assertEqual(len(ipa_inspections), 3)

    def test_collector_canonicalizes_artifact_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            bin_dir = self.install_fake_dwarfdump(
                root,
                "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                "(arm64) %s\\n' \"$2\"\n",
            )
            result, output = self.run_collector(root, archive, bin_dir)

            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads(output.read_text())
            self.assertEqual(evidence["archive_path"], str(archive.resolve()))
            self.assertTrue(Path(evidence["archive_path"]).is_absolute())

    def test_collector_rejects_archive_symlink_and_unsafe_output_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            bin_dir = self.install_fake_dwarfdump(
                root,
                "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                "(arm64) %s\\n' \"$2\"\n",
            )

            alias = root / "Alias.xcarchive"
            alias.symlink_to(archive, target_is_directory=True)
            result, output = self.run_collector(root, alias, bin_dir)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())

            inside = archive / "evidence.json"
            result, _output = self.run_collector(
                root,
                archive,
                bin_dir,
                output_path=inside,
            )
            self.assertEqual(result.returncode, 2)
            self.assertFalse(inside.exists())

            existing = root / "existing-evidence.json"
            existing.write_text("stale", encoding="utf-8")
            result, _output = self.run_collector(
                root,
                archive,
                bin_dir,
                output_path=existing,
            )
            self.assertEqual(result.returncode, 2)
            self.assertEqual(existing.read_text(encoding="utf-8"), "stale")

    def test_collector_uses_filesystem_identity_for_output_ancestry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            casing_alias = archive.with_name(archive.name.swapcase())
            try:
                same_archive = casing_alias.samefile(archive)
            except FileNotFoundError:
                same_archive = False
            if not same_archive:
                self.skipTest("test volume is case-sensitive")
            bin_dir = self.install_fake_dwarfdump(
                root,
                "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                "(arm64) %s\\n' \"$2\"\n",
            )
            output = casing_alias / "evidence.json"

            result, _output = self.run_collector(
                root,
                archive,
                bin_dir,
                output_path=output,
            )

            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())

    def test_collector_rejects_symlinked_archived_app_ancestor(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            applications = archive / "Products" / "Applications"
            external = root / "ExternalApplications"
            applications.rename(external)
            applications.symlink_to(external, target_is_directory=True)
            bin_dir = self.install_fake_dwarfdump(root, "exit 0\n")

            result, output = self.run_collector(root, archive, bin_dir)

            self.assertEqual(result.returncode, 2)
            self.assertIn("symbolic-link directory", result.stderr)
            self.assertFalse(output.exists())

    def test_unsigned_archive_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            bin_dir = self.install_fake_dwarfdump(root, "exit 0\n")
            (bin_dir / "codesign").write_text("#!/bin/sh\nexit 1\n")
            (bin_dir / "codesign").chmod(0o755)

            result, output = self.run_collector(root, archive, bin_dir)

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_archive_embedded_source_sha_must_match_requested_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            info_path = archive / "Products" / "Applications" / "Client.app" / "Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["MozFloorpSourceSHA"] = "b" * 40
            info_path.write_bytes(plistlib.dumps(info))
            bin_dir = self.install_fake_dwarfdump(
                root,
                "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                "(arm64) %s\\n' \"$2\"\n",
            )

            result, output = self.run_collector(root, archive, bin_dir)

            self.assertEqual(result.returncode, 2)
            self.assertIn("source SHA", result.stderr)
            self.assertFalse(output.exists())

    def test_ipa_embedded_source_sha_must_match_requested_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            bin_dir = self.install_fake_dwarfdump(
                root,
                "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                "(arm64) %s\\n' \"$2\"\n",
            )
            ipa = root / "Floorp.ipa"
            with zipfile.ZipFile(ipa, "w") as ipa_archive:
                ipa_archive.writestr(
                    "Payload/Floorp.app/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleShortVersionString": "0.3.0",
                            "CFBundleVersion": "42",
                            "CFBundleIdentifier": "app.floorp.Floorp",
                            "CFBundleExecutable": "Floorp",
                            "MozFloorpSourceSHA": "b" * 40,
                        }
                    ),
                )
                ipa_archive.writestr("Payload/Floorp.app/Floorp", b"signed")

            result, output = self.run_collector(
                root,
                archive,
                bin_dir,
                archive_only=False,
                ipa=ipa,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("source SHA", result.stderr)
            self.assertFalse(output.exists())

    def test_plist_quotes_are_passed_as_data_not_python_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _dwarf_binary = self.make_fake_archive(root)
            app_info_path = (
                archive
                / "Products"
                / "Applications"
                / "Client.app"
                / "Info.plist"
            )
            app_info = plistlib.loads(app_info_path.read_bytes())
            app_info["CFBundleShortVersionString"] = "0.3.0'preview"
            app_info_path.write_bytes(plistlib.dumps(app_info))
            bin_dir = self.install_fake_dwarfdump(
                root,
                "printf 'UUID: 12345678-90ab-cdef-1234-567890abcdef "
                "(arm64) %s\\n' \"$2\"\n",
            )

            result, output = self.run_collector(root, archive, bin_dir)

            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads(output.read_text())
            self.assertEqual(evidence["marketing_version"], "0.3.0'preview")
            self.assertEqual(
                evidence["archive_info"]["marketing_version"],
                "0.3.0'preview",
            )

    def test_dwarfdump_failure_or_unparseable_output_fails_closed(self):
        cases = (
            ("printf 'not a UUID\\n'\n", "no UUID"),
            ("printf 'UUID: malformed (arm64) fake\\n'\n", "invalid UUID"),
            ("echo 'dwarfdump failed' >&2\nexit 1\n", "dwarfdump failed"),
        )
        for body, expected_error in cases:
            with self.subTest(expected_error=expected_error), tempfile.TemporaryDirectory() as tmp:
                archive, _dwarf_binary = self.make_fake_archive(tmp)
                bin_dir = self.install_fake_dwarfdump(tmp, body)
                result, output = self.run_collector(tmp, archive, bin_dir)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
