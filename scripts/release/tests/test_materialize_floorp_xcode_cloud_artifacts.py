"""Tests for strict Xcode Cloud ARCHIVE/ARCHIVE_EXPORT materialization."""

from __future__ import annotations

import hashlib
import io
import json
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).parent.parent / "materialize-floorp-xcode-cloud-artifacts.py"
RUN_ID = "run-123"


class FloorpXcodeCloudArtifactMaterializerTests(unittest.TestCase):
    def write_zip(self, path: Path, members: dict[str, bytes]) -> None:
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, contents in members.items():
                info = zipfile.ZipInfo(name)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, contents)

    def zip_bytes(self, members: dict[str, bytes]) -> bytes:
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, contents in members.items():
                info = zipfile.ZipInfo(name)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, contents)
        return output.getvalue()

    def metadata(
        self,
        download: Path,
        *,
        file_type: str,
        file_name: str,
        action_id: str = "action-123",
        artifact_id: str | None = None,
    ) -> dict:
        contents = download.read_bytes()
        return {
            "schema_version": 1,
            "run_id": RUN_ID,
            "action": {
                "id": action_id,
                "name": "Archive",
                "action_type": "ARCHIVE",
                "execution_progress": "COMPLETE",
                "completion_status": "SUCCEEDED",
            },
            "artifact": {
                "id": artifact_id or f"artifact-{file_type.lower()}",
                "file_type": file_type,
                "file_name": file_name,
                "file_size": len(contents),
                "downloaded_size": len(contents),
                "sha256": hashlib.sha256(contents).hexdigest(),
            },
            "download_path": str(download.resolve()),
        }

    def fixture(self, root: Path, *, wrapped_export: bool = False):
        archive_download = root / "archive.download"
        export_download = root / "export.download"
        self.write_zip(
            archive_download,
            {
                "Floorp.xcarchive/Info.plist": b"archive-info",
                "Floorp.xcarchive/Products/Applications/Client.app/Info.plist": b"app-info",
                "Floorp.xcarchive/Products/Applications/Client.app/Client": b"macho",
            },
        )
        ipa_contents = self.zip_bytes(
            {
                "Payload/Client.app/Info.plist": b"app-info",
                "Payload/Client.app/Client": b"macho",
            }
        )
        if wrapped_export:
            self.write_zip(export_download, {"Export/Floorp.ipa": ipa_contents})
            export_name = "Floorp-export.bundle"
        else:
            export_download.write_bytes(ipa_contents)
            export_name = "Floorp-export"

        archive_metadata = root / "archive.metadata.json"
        export_metadata = root / "export.metadata.json"
        archive_metadata.write_text(
            json.dumps(
                self.metadata(
                    archive_download,
                    file_type="ARCHIVE",
                    file_name="Floorp.xcarchive",
                    artifact_id="artifact-archive",
                )
            )
        )
        export_metadata.write_text(
            json.dumps(
                self.metadata(
                    export_download,
                    file_type="ARCHIVE_EXPORT",
                    file_name=export_name,
                    artifact_id="artifact-export",
                )
            )
        )
        return archive_download, export_download, archive_metadata, export_metadata

    def run_script(self, root: Path, fixture) -> subprocess.CompletedProcess:
        archive_download, export_download, archive_metadata, export_metadata = fixture
        return subprocess.run(
            [
                str(SCRIPT),
                "--expected-run-id",
                RUN_ID,
                "--archive-download",
                str(archive_download),
                "--archive-metadata",
                str(archive_metadata),
                "--export-download",
                str(export_download),
                "--export-metadata",
                str(export_metadata),
                "--output-root",
                str(root / "materialized"),
                "--manifest-output",
                str(root / "manifest.json"),
            ],
            capture_output=True,
            text=True,
        )

    def test_materializes_direct_ipa_and_binds_both_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            result = self.run_script(root, self.fixture(root))

            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((root / "manifest.json").read_text())
            self.assertEqual(manifest["run_id"], RUN_ID)
            self.assertEqual(manifest["action"]["id"], "action-123")
            self.assertEqual(manifest["artifacts"]["archive"]["id"], "artifact-archive")
            self.assertEqual(
                manifest["artifacts"]["archive_export"]["id"], "artifact-export"
            )
            self.assertEqual(
                Path(manifest["materialized"]["archive_path"]).name,
                "Floorp.xcarchive",
            )
            self.assertEqual(
                Path(manifest["materialized"]["ipa_path"]),
                root / "export.download",
            )

    def test_materializes_one_ipa_from_an_export_wrapper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            result = self.run_script(root, self.fixture(root, wrapped_export=True))

            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((root / "manifest.json").read_text())
            self.assertEqual(
                Path(manifest["materialized"]["ipa_path"]).name,
                "Floorp.ipa",
            )

    def test_rejects_traversal_anywhere_in_archive_wrapper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self.fixture(root)
            archive_download = fixture[0]
            self.write_zip(
                archive_download,
                {
                    "Floorp.xcarchive/Info.plist": b"archive-info",
                    "../outside": b"escape",
                },
            )
            fixture[2].write_text(
                json.dumps(
                    self.metadata(
                        archive_download,
                        file_type="ARCHIVE",
                        file_name="Floorp.xcarchive",
                        artifact_id="artifact-archive",
                    )
                )
            )

            result = self.run_script(root, fixture)

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "outside").exists())
            self.assertFalse((root / "manifest.json").exists())

    def test_rejects_different_archive_actions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self.fixture(root)
            export_metadata = json.loads(fixture[3].read_text())
            export_metadata["action"]["id"] = "action-other"
            fixture[3].write_text(json.dumps(export_metadata))

            result = self.run_script(root, fixture)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("different Xcode Cloud actions", result.stderr)

    def test_rejects_changed_download_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self.fixture(root)
            fixture[1].write_bytes(fixture[1].read_bytes() + b"changed")

            result = self.run_script(root, fixture)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("size does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
