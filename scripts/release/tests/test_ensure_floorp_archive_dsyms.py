"""Tests for the archive-only Glean dSYM repair build phase."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


RELEASE_DIR = Path(__file__).parent.parent
SCRIPT = RELEASE_DIR / "ensure-floorp-archive-dsyms.sh"
XCRUN = Path("/usr/bin/xcrun")


class FloorpArchiveGleanDsymTests(unittest.TestCase):
    def archive_environment(self, root):
        environment = os.environ.copy()
        environment.update({
            "CONFIGURATION": "FloorpRelease",
            "ACTION": "archive",
            "PLATFORM_NAME": "iphoneos",
            "DEPLOYMENT_LOCATION": "YES",
            "TARGET_NAME": "Client",
            "CODESIGNING_FOLDER_PATH": str(root / "Client.app"),
            "DWARF_DSYM_FOLDER_PATH": str(root / "dSYMs"),
            "TMPDIR": str(root),
        })
        return environment

    def run_script(self, environment, *arguments):
        return subprocess.run(
            [str(SCRIPT), *map(str, arguments)],
            capture_output=True,
            text=True,
            env=environment,
        )

    def macho_uuids(self, path):
        result = subprocess.run(
            [str(XCRUN), "dwarfdump", "--uuid", str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
        return {
            match.replace("-", "").upper()
            for match in re.findall(r"^UUID:\s+([^\s]+)", result.stdout, re.MULTILINE)
        }

    def test_non_archive_build_is_a_noop_without_requiring_build_paths(self):
        environment = os.environ.copy()
        environment.update({
            "CONFIGURATION": "Fennec_Testing",
            "ACTION": "build",
            "PLATFORM_NAME": "iphonesimulator",
        })

        result = self.run_script(environment)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipping", result.stdout)

    def test_unset_or_build_action_is_a_noop(self):
        for action in (None, "build"):
            with self.subTest(action=action):
                environment = os.environ.copy()
                environment.update({
                    "CONFIGURATION": "FloorpRelease",
                    "PLATFORM_NAME": "iphoneos",
                })
                if action is None:
                    environment.pop("ACTION", None)
                else:
                    environment["ACTION"] = action

                result = self.run_script(environment)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("skipping", result.stdout)

    def test_matching_archive_environment_fails_closed_without_embedded_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.run_script(self.archive_environment(root))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("embedded Glean binary is missing", result.stderr)

    def test_install_action_is_also_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            environment = self.archive_environment(root)
            environment["ACTION"] = "install"

            result = self.run_script(environment)

            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("skipping", result.stdout)
            self.assertIn("embedded Glean binary is missing", result.stderr)

    @unittest.skipUnless(XCRUN.is_file(), "Apple developer tools are required")
    def test_archive_action_with_real_apple_tools_generates_an_exact_uuid_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "glean_fixture.c"
            object_file = root / "glean_fixture.o"
            binary = root / "Client.app" / "Frameworks" / "Glean.framework" / "Glean"
            dsym = root / "dSYMs" / "Glean.framework.dSYM"
            binary.parent.mkdir(parents=True)
            source.write_text("int floorp_glean_fixture(void) { return 42; }\n")
            subprocess.run(
                [str(XCRUN), "clang", "-g", "-c", str(source), "-o", str(object_file)],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                [str(XCRUN), "clang", "-dynamiclib", str(object_file), "-o", str(binary)],
                check=True,
                capture_output=True,
                text=True,
            )

            result = self.run_script(self.archive_environment(root))

            self.assertEqual(result.returncode, 0, result.stderr)
            dwarf = dsym / "Contents" / "Resources" / "DWARF" / "Glean"
            self.assertTrue(dwarf.is_file())
            self.assertEqual(self.macho_uuids(binary), self.macho_uuids(dwarf))
            self.assertIn("generated", result.stdout)
            debug_info = subprocess.run(
                [str(XCRUN), "dwarfdump", "--debug-info", str(dwarf)],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            self.assertIn("DW_TAG_compile_unit", debug_info)

    def test_missing_dsym_slice_uuid_fails_before_replacing_previous_dsym(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / "Client.app" / "Frameworks" / "Glean.framework" / "Glean"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixture")
            dsym = root / "dSYMs" / "Glean.framework.dSYM"
            dsym.mkdir(parents=True)
            marker = dsym / "preserve-on-failure"
            marker.write_text("previous validated output")
            fake_xcrun = root / "xcrun"
            fake_xcrun.write_text(r'''#!/bin/bash
set -euo pipefail
tool="$1"
shift
case "$tool" in
    dsymutil)
        binary="$1"
        shift
        [[ "$1" == "-o" ]]
        destination="$2"
        mkdir -p "$destination/Contents/Resources/DWARF"
        printf 'fake dSYM' > "$destination/Contents/Resources/DWARF/Glean"
        ;;
    dwarfdump)
        [[ "$1" == "--uuid" ]]
        case "$2" in
            *.dSYM/Contents/Resources/DWARF/Glean)
                printf 'UUID: AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA (arm64) %s\n' "$2"
                ;;
            *)
                printf 'UUID: AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA (arm64) %s\n' "$2"
                printf 'UUID: BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB (arm64e) %s\n' "$2"
                ;;
        esac
        ;;
    *) exit 70 ;;
esac
''')
            fake_xcrun.chmod(0o755)

            result = self.run_script(
                self.archive_environment(root),
                "--test-xcrun",
                fake_xcrun,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("UUID mismatch", result.stderr)
            self.assertEqual(marker.read_text(), "previous validated output")


if __name__ == "__main__":
    unittest.main()
