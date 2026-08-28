"""Regression coverage for the untrusted extension ingestion boundary."""

from __future__ import annotations

import importlib.util
import io
import json
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "ingest_extension.py"
SPEC = importlib.util.spec_from_file_location("floorp_ingest_extension", MODULE_PATH)
assert SPEC and SPEC.loader
INGEST = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = INGEST
SPEC.loader.exec_module(INGEST)


def manifest(**extra: object) -> dict[str, object]:
    result: dict[str, object] = {
        "manifest_version": 3,
        "name": "Useful Example",
        "version": "1.0.0",
        "permissions": ["storage", "scripting"],
        "host_permissions": ["https://example.test/*"],
        "content_scripts": [{
            "matches": ["https://example.test/*"],
            "js": ["content/main.js"],
            "run_at": "document_idle",
        }],
    }
    result.update(extra)
    return result


def make_zip(entries: dict[str, bytes], *, compression: int = zipfile.ZIP_DEFLATED) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=compression) as archive:
        for path, payload in entries.items():
            archive.writestr(path, payload)
    return output.getvalue()


class IngestExtensionTests(unittest.TestCase):
    def ingest(self, source: Path, output: Path, **kwargs: object):
        return INGEST.ingest(
            source,
            output_directory=output,
            extension_id="example.useful-extension",
            generation="2026.08.26.1",
            upstream="https://github.com/example/useful-extension",
            license_id="MIT",
            patch_path=kwargs.get("patch_path"),
        )

    def test_normalizes_zip_to_deterministic_fwea1_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.xpi"
            source.write_bytes(make_zip({
                "manifest.json": json.dumps(manifest(), indent=2).encode(),
                "content/main.js": b"document.documentElement.dataset.useful = 'yes';\n",
                "LICENSE": b"MIT License\n",
            }))
            result = self.ingest(source, root / "out")
            artifact = (root / "out" / "artifact.fwea1").read_bytes()
            self.assertTrue(artifact.startswith(INGEST.FWEA1_MAGIC))
            header_length = struct.unpack(">I", artifact[len(INGEST.FWEA1_MAGIC) : len(INGEST.FWEA1_MAGIC) + 4])[0]
            header_start = len(INGEST.FWEA1_MAGIC) + 4
            header = json.loads(artifact[header_start : header_start + header_length])
            self.assertEqual(result.artifact_digest, INGEST.sha256(artifact))
            self.assertEqual(result.inventory_digest, INGEST.sha256(INGEST.canonical_json(header)))
            self.assertEqual(
                [entry["path"] for entry in header["files"]],
                ["LICENSE", "content/main.js", "manifest.json"],
            )
            report = json.loads((root / "out" / "inspection.json").read_bytes())
            self.assertEqual(report["status"], "accepted")
            self.assertEqual(report["artifact_sha256"], result.artifact_digest)

    def test_accepts_a_crx_v3_wrapper_only_after_extracting_its_zip_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = make_zip({
                "manifest.json": json.dumps(manifest()).encode(),
                "content/main.js": b"document.body.hidden = false;\n",
            })
            crx = root / "source.crx"
            crx.write_bytes(b"Cr24" + struct.pack("<II", 3, 0) + payload)
            result = self.ingest(crx, root / "out")
            self.assertGreater(result.artifact_bytes, len(INGEST.FWEA1_MAGIC))

    def test_quarantines_zip_slip_before_writing_normalized_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "unsafe.zip"
            source.write_bytes(make_zip({
                "manifest.json": json.dumps(manifest()).encode(),
                "../outside.js": b"unsafe",
            }))
            with self.assertRaisesRegex(INGEST.IngestionError, "path traversal"):
                self.ingest(source, root / "out")
            self.assertFalse((root / "out" / "artifact.fwea1").exists())

    def test_quarantines_case_collisions_and_symlink_members(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collision = root / "collision.zip"
            collision.write_bytes(make_zip({
                "manifest.json": json.dumps(manifest()).encode(),
                "content/main.js": b"1",
                "content/MAIN.js": b"2",
            }))
            with self.assertRaisesRegex(INGEST.IngestionError, "case-colliding"):
                self.ingest(collision, root / "collision-out")

            link = root / "link.zip"
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w") as archive:
                archive.writestr("manifest.json", json.dumps(manifest()).encode())
                info = zipfile.ZipInfo("content/main.js")
                info.external_attr = (0o120777 << 16)
                archive.writestr(info, "../manifest.json")
            link.write_bytes(output.getvalue())
            with self.assertRaisesRegex(INGEST.IngestionError, "symlink"):
                self.ingest(link, root / "link-out")

    def test_quarantines_remote_executable_and_dynamic_code(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "remote.zip"
            remote.write_bytes(make_zip({
                "manifest.json": json.dumps(manifest()).encode(),
                "content/main.js": b"fetch('https://example.test/remote.js');\n",
            }))
            with self.assertRaisesRegex(INGEST.IngestionError, "remote-executable"):
                self.ingest(remote, root / "remote-out")

            dynamic = root / "dynamic.zip"
            dynamic.write_bytes(make_zip({
                "manifest.json": json.dumps(manifest()).encode(),
                "content/main.js": b"Function('return 1')();\n",
            }))
            with self.assertRaisesRegex(INGEST.IngestionError, "dynamic-code"):
                self.ingest(dynamic, root / "dynamic-out")

    def test_accepts_packaged_configuration_fonts_and_json_endpoints(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.zip"
            source.write_bytes(make_zip({
                "manifest.json": json.dumps(manifest()).encode(),
                "content/main.js": b"fetch('https://example.test/posts.json');\n",
                "config/dark-sites.config": b"example.test\n",
                "config/color-schemes.drconf": b"[Dark]\n",
                "ui/fonts/example.ttf": b"\x00\x01\x00\x00",
            }))
            result = self.ingest(source, root / "out")
            self.assertTrue(any(
                finding.code == "network-endpoint"
                for finding in result.findings
            ))

    def test_normalizes_utf8_text_line_endings_without_touching_binary_resources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.zip"
            png = b"\x89PNG\r\n\x1a\nnot-text\r\n"
            source.write_bytes(make_zip({
                "manifest.json": json.dumps(manifest()).encode(),
                "content/main.js": b"const enabled = true;\r\n",
                "config/dark-sites.config": b"example.test\r\n",
                "icons/icon.png": png,
            }))

            self.ingest(source, root / "out")

            normalized = root / "out" / "normalized"
            self.assertEqual((normalized / "content/main.js").read_bytes(), b"const enabled = true;\n")
            self.assertEqual((normalized / "config/dark-sites.config").read_bytes(), b"example.test\n")
            self.assertEqual((normalized / "icons/icon.png").read_bytes(), png)

    def test_patch_is_recorded_and_unknown_manifest_fields_require_reviewed_patch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.zip"
            source.write_bytes(make_zip({
                "manifest.json": json.dumps(manifest(update_url="https://vendor.test/update.xml")).encode(),
                "content/main.js": b"document.body.dataset.patched = 'yes';\n",
            }))
            with self.assertRaisesRegex(INGEST.IngestionError, "requiring a compatibility patch"):
                self.ingest(source, root / "unpatched")

            patch = root / "patch.json"
            patch.write_text(json.dumps({"drop_manifest_keys": ["update_url"]}), encoding="utf-8")
            result = self.ingest(source, root / "patched", patch_path=patch)
            self.assertIsNotNone(result.patch_digest)
            self.assertNotIn("update_url", result.manifest)

    def test_rejects_over_limit_expansion_without_unpacking_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "large.zip"
            old_limit = INGEST.MAX_FILE_BYTES
            try:
                INGEST.MAX_FILE_BYTES = 64
                source.write_bytes(make_zip({
                    "manifest.json": json.dumps(manifest()).encode(),
                    "content/main.js": b"a" * 65,
                }))
                with self.assertRaisesRegex(INGEST.IngestionError, "per-file size"):
                    self.ingest(source, root / "out")
            finally:
                INGEST.MAX_FILE_BYTES = old_limit


if __name__ == "__main__":
    unittest.main()
