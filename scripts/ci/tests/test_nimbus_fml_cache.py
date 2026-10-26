"""Network-free checks for the ordinary Nimbus FML cache/download boundary."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
VERSION = "155.20260731050244"
BINARY = b'#!/bin/bash\nprintf "%s\\n" "$*" >> "$NIMBUS_TEST_EXEC_LOG"\n'


class NimbusFMLCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nimbus-fml-cache-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        scripts = self.source / "bin"
        scripts.mkdir(parents=True)
        self.script = scripts / "nimbus-fml.sh"
        shutil.copy2(ROOT / "scripts/nimbus-fml-vendor/nimbus-fml.sh", self.script)
        (scripts / "nimbus-fml-configuration.sh").write_text(
            'CHANNEL=developer\nMODULES=Client\nAPP_FML_FILE=Client/nimbus.fml.yaml\n'
        )
        (self.source / "Client").mkdir()
        self.cache = self.source / "build/nimbus" / VERSION / "bin"
        self.cache.mkdir(parents=True)
        self.requests = self.root / "requests.jsonl"
        self.execution = self.root / "executed.log"
        self.remote_zip = self.root / "remote.zip"
        self.remote_checksum = self.root / "remote.sha256"
        self.write_zip(self.remote_zip)
        self.remote_checksum.write_text(self.checksum(self.remote_zip))
        self.write_cache()
        curl = self.bin / "curl"
        curl.write_text(f"#!{sys.executable}\n" + '''
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
url = next(value for value in args if value.startswith("https://"))
with Path(os.environ["NIMBUS_TEST_REQUESTS"]).open("a") as stream:
    stream.write(json.dumps(url) + "\\n")
output = Path(args[args.index("--output") + 1])
archive = "archive.mozilla.org" in url
mode = os.environ.get("NIMBUS_TEST_CHECKSUM_MODE", "offline")
status = "200"
code = 0
if url.endswith(".sha256"):
    if archive and os.environ.get("NIMBUS_TEST_ARCHIVE_AVAILABLE") != "1":
        status, code = "404", 22
    elif mode == "offline":
        status, code = "000", 6
    elif mode == "invalid":
        output.write_text("invalid remote checksum\\n")
    else:
        output.write_bytes(Path(os.environ["NIMBUS_TEST_REMOTE_CHECKSUM"]).read_bytes())
else:
    if os.environ.get("NIMBUS_TEST_ZIP_FAILURE") == "1":
        output.write_bytes(b"partial download")
        code = 7
    else:
        output.write_bytes(Path(os.environ["NIMBUS_TEST_REMOTE_ZIP"]).read_bytes())
if "--write-out" in args:
    sys.stdout.write(status)
sys.exit(code)
''')
        curl.chmod(0o755)

    @staticmethod
    def write_zip(path, binary=BINARY):
        with zipfile.ZipFile(path, "w") as archive:
            for arch in ["aarch64-apple-darwin", "x86_64-apple-darwin"]:
                archive.writestr(f"{arch}/release/nimbus-fml", binary)

    @staticmethod
    def checksum(path):
        return f"{hashlib.sha256(path.read_bytes()).hexdigest()}  nimbus-fml.zip\n"

    def write_cache(self):
        shutil.copy2(self.remote_zip, self.cache / "nimbus-fml.zip")
        shutil.copy2(self.remote_checksum, self.cache / "nimbus-fml.sha256")
        (self.cache / "nimbus-fml").write_bytes(BINARY)
        (self.cache / "nimbus-fml").chmod(0o755)

    def run_generator(self, *arguments, mode="offline", **settings):
        environment = dict(os.environ)
        environment.update({
            "PATH": f"{self.bin}{os.pathsep}{environment['PATH']}",
            "SOURCE_ROOT": str(self.source), "PROJECT": "Client", "CONFIGURATION": "Fennec",
            "NIMBUS_TEST_REQUESTS": str(self.requests),
            "NIMBUS_TEST_EXEC_LOG": str(self.execution),
            "NIMBUS_TEST_REMOTE_CHECKSUM": str(self.remote_checksum),
            "NIMBUS_TEST_REMOTE_ZIP": str(self.remote_zip),
            "NIMBUS_TEST_CHECKSUM_MODE": mode,
            **settings,
        })
        return subprocess.run(
            ["/bin/bash", str(self.script), "--use-fml-version", VERSION, *arguments],
            env=environment, capture_output=True, text=True,
        )

    def assert_cache_unchanged(self, previous):
        for name, data in previous.items():
            self.assertEqual((self.cache / name).read_bytes(), data)
        self.assertFalse(list(self.cache.glob(".download.*")))

    def cache_bytes(self):
        return {name: (self.cache / name).read_bytes() for name in [
            "nimbus-fml.zip", "nimbus-fml.sha256", "nimbus-fml",
        ]}

    def test_offline_verified_cache_reextracts_unverified_binary(self):
        (self.cache / "nimbus-fml").write_text("unverified binary")
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("using verified cache", result.stderr)
        self.assertEqual((self.cache / "nimbus-fml").read_bytes(), BINARY)
        self.assertIn("validate", self.execution.read_text())
        self.assertIn("generate", self.execution.read_text())

    def test_offline_corrupt_or_missing_exact_version_cache_fails(self):
        for damage in ["zip", "checksum", "missing-zip", "missing-checksum", "different-version"]:
            with self.subTest(damage=damage):
                self.write_cache()
                if damage == "zip":
                    (self.cache / "nimbus-fml.zip").write_bytes(b"corrupt")
                elif damage == "checksum":
                    (self.cache / "nimbus-fml.sha256").write_text("invalid")
                elif damage == "missing-zip":
                    (self.cache / "nimbus-fml.zip").unlink()
                elif damage == "missing-checksum":
                    (self.cache / "nimbus-fml.sha256").unlink()
                else:
                    other = self.cache.parents[1] / "another-version/bin"
                    other.mkdir(parents=True)
                    shutil.copy2(self.cache / "nimbus-fml.zip", other)
                    shutil.copy2(self.cache / "nimbus-fml.sha256", other)
                    (self.cache / "nimbus-fml.zip").unlink()
                    (self.cache / "nimbus-fml.sha256").unlink()
                result = self.run_generator()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no verified cache exists", result.stderr)
                self.assertFalse(self.execution.exists())

    def test_fresh_cannot_fall_back_to_cached_copy_and_does_not_delete_it(self):
        before = self.cache_bytes()
        result = self.run_generator("--fresh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot refresh", result.stderr)
        self.assertFalse(self.execution.exists())
        self.assert_cache_unchanged(before)

    def test_known_changed_remote_checksum_and_failed_download_cannot_fall_back(self):
        before = self.cache_bytes()
        self.write_zip(self.remote_zip, BINARY + b"# new version\n")
        self.remote_checksum.write_text(self.checksum(self.remote_zip))
        result = self.run_generator(mode="valid", NIMBUS_TEST_ZIP_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("using verified cache", result.stderr)
        self.assertFalse(self.execution.exists())
        self.assert_cache_unchanged(before)

    def test_invalid_remote_checksum_cannot_fall_back(self):
        before = self.cache_bytes()
        result = self.run_generator(mode="invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("downloaded Nimbus FML checksum is invalid", result.stderr)
        self.assertFalse(self.execution.exists())
        self.assert_cache_unchanged(before)

    def test_online_reuse_verifies_zip_and_repairs_corrupt_cache(self):
        (self.cache / "nimbus-fml.zip").write_bytes(b"corrupt")
        result = self.run_generator(mode="valid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.cache / "nimbus-fml.zip").read_bytes(), self.remote_zip.read_bytes())
        urls = [json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertTrue(any("firefox-ci-tc.services.mozilla.com" in url and url.endswith(".zip") for url in urls))

    def test_online_archive_endpoint_and_valid_cache_do_not_redownload_zip(self):
        result = self.run_generator(mode="valid", NIMBUS_TEST_ARCHIVE_AVAILABLE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        urls = [json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertEqual(len(urls), 1)
        self.assertIn("archive.mozilla.org", urls[0])
        self.assertFalse(list(self.cache.glob(".download.*")))

    def test_shared_zip_replacement_after_hash_does_not_change_the_extracted_binary(self):
        replacement = self.root / "replacement.zip"
        self.write_zip(replacement, b'#!/bin/bash\necho TAMPERED >> "$NIMBUS_TEST_EXEC_LOG"\n')
        real_shasum = shutil.which("shasum")
        wrapper = self.bin / "shasum"
        wrapper.write_text(f"#!{sys.executable}\n" + '''
import os
from pathlib import Path
import shutil
import subprocess
import sys

result = subprocess.run([os.environ["NIMBUS_TEST_REAL_SHASUM"], *sys.argv[1:]], capture_output=True)
if sys.argv[-1].endswith("nimbus-fml.zip"):
    shutil.copyfile(os.environ["NIMBUS_TEST_REPLACEMENT_ZIP"], os.environ["NIMBUS_TEST_SHARED_ZIP"])
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
''')
        wrapper.chmod(0o755)
        result = self.run_generator(
            NIMBUS_TEST_REAL_SHASUM=real_shasum,
            NIMBUS_TEST_REPLACEMENT_ZIP=str(replacement),
            NIMBUS_TEST_SHARED_ZIP=str(self.cache / "nimbus-fml.zip"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("TAMPERED", self.execution.read_text())
        self.assertIn("generate", self.execution.read_text())

    def test_shared_executable_replacement_between_validate_and_generate_is_not_executed(self):
        replacement = self.root / "replacement-binary"
        replacement.write_bytes(b'#!/bin/bash\necho TAMPERED >> "$NIMBUS_TEST_EXEC_LOG"\n')
        replacement.chmod(0o755)
        binary = BINARY + b'''if [[ "$1" == "validate" ]]; then
cp "$NIMBUS_TEST_REPLACEMENT_BINARY" "$NIMBUS_TEST_SHARED_BINARY"
fi
'''
        self.write_zip(self.remote_zip, binary)
        self.remote_checksum.write_text(self.checksum(self.remote_zip))
        self.write_cache()
        result = self.run_generator(
            NIMBUS_TEST_REPLACEMENT_BINARY=str(replacement),
            NIMBUS_TEST_SHARED_BINARY=str(self.cache / "nimbus-fml"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("TAMPERED", self.execution.read_text())
        self.assertIn("validate", self.execution.read_text())
        self.assertIn("generate", self.execution.read_text())

    def prepare_bootstrap(self):
        repository = self.root / "bootstrap-source"
        (repository / "firefox-ios/bin").mkdir(parents=True)
        (repository / "scripts/nimbus-fml-vendor").mkdir(parents=True)
        shutil.copy2(ROOT / "bootstrap.sh", repository)
        shutil.copy2(ROOT / "scripts/nimbus-fml-vendor/nimbus-fml.sh", repository / "scripts/nimbus-fml-vendor")
        metrics = repository / "scripts/generate-glean-metrics.sh"
        metrics.write_text("#!/bin/bash\nexit 0\n")
        metrics.chmod(0o755)
        npm = self.bin / "npm"
        npm.write_text("#!/bin/bash\nexit 0\n")
        npm.chmod(0o755)
        return repository

    def run_bootstrap(self, repository):
        environment = dict(os.environ)
        environment.update({
            "PATH": f"{self.bin}{os.pathsep}{environment['PATH']}",
            "CI": "true",
            "NIMBUS_TEST_REQUESTS": str(self.requests),
        })
        return subprocess.run(
            ["/bin/bash", str(repository / "bootstrap.sh"), "firefox"],
            env=environment, capture_output=True, text=True,
        )

    def test_bootstrap_installs_tracked_reviewed_script_and_repairs_stale_generated_copy(self):
        repository = self.prepare_bootstrap()
        generated = repository / "firefox-ios/bin/nimbus-fml.sh"
        for stale in [False, True]:
            with self.subTest(stale=stale):
                if stale:
                    generated.write_text("stale generated copy\n")
                result = self.run_bootstrap(repository)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(generated.read_bytes(), self.script.read_bytes())
                self.assertTrue(os.access(generated, os.X_OK))
                self.assertFalse(list(generated.parent.glob("nimbus-fml.sh.*")))
                self.assertFalse(self.requests.exists())

    def test_bootstrap_rejects_changed_vendored_input_without_replacing_valid_generated_copy(self):
        repository = self.prepare_bootstrap()
        generated = repository / "firefox-ios/bin/nimbus-fml.sh"
        self.assertEqual(self.run_bootstrap(repository).returncode, 0)
        previous = generated.read_bytes()
        vendored = repository / "scripts/nimbus-fml-vendor/nimbus-fml.sh"
        vendored.write_bytes(vendored.read_bytes() + b"# unreviewed change\n")
        result = self.run_bootstrap(repository)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from its reviewed checksum", result.stderr)
        self.assertEqual(generated.read_bytes(), previous)
        self.assertFalse(self.requests.exists())


if __name__ == "__main__":
    unittest.main()
