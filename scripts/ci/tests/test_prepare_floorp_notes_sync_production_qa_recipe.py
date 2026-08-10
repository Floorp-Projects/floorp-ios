from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
PREPARER_PATH = ROOT / "scripts/ci/prepare-floorp-notes-sync-production-qa-recipe.py"


def load_preparer():
    spec = importlib.util.spec_from_file_location("floorp_production_qa_preparer", PREPARER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load production-QA recipe preparer")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


PREPARER = load_preparer()


class FloorpNotesSyncProductionQaRecipePreparerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_owner = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_owner.name)
        self.run_dir = self.directory / "run"
        self.run_dir.mkdir(mode=0o700)
        self.evidence = self.directory / "evidence"
        self.evidence.mkdir()
        self.inputs = self.directory / "inputs"
        self.inputs.mkdir()
        self.ios = self.directory / "ios"
        self.floorp = self.directory / "Floorp"
        self.base_oid, self.merged_oid = self.make_ios_repository()
        self.floorp_oid = self.make_floorp_repository()
        self.contract = self.make_contract()
        self.output = self.run_dir / "production-qa-recipe.json"
        self.g3_run_path = self.inputs / "g3-run.json"
        self.artifact_metadata_path = self.inputs / "g3-artifact.json"
        self.xcresult_path = self.inputs / "g3-xcresult.zip"
        self.desktop_run_path = self.inputs / "desktop-run.json"
        self.runtime_run_path = self.inputs / "runtime-run.json"
        self.write_captures()

    def tearDown(self) -> None:
        self.temporary_owner.cleanup()

    def git(self, repository: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["/usr/bin/git", "-C", str(repository), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={
                **os.environ,
                "GIT_AUTHOR_NAME": "Recipe Test",
                "GIT_AUTHOR_EMAIL": "recipe@example.invalid",
                "GIT_COMMITTER_NAME": "Recipe Test",
                "GIT_COMMITTER_EMAIL": "recipe@example.invalid",
            },
        )
        return result.stdout.strip()

    def write_repo_file(self, repository: Path, relative: str, raw: bytes) -> Path:
        path = repository / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return path

    def make_ios_repository(self) -> tuple[str, str]:
        self.ios.mkdir()
        self.git(self.ios, "init", "-q")
        self.write_repo_file(self.ios, "base.txt", b"base\n")
        self.git(self.ios, "add", "base.txt")
        self.git(self.ios, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base")
        base = self.git(self.ios, "rev-parse", "HEAD")
        self.write_repo_file(
            self.ios,
            "firefox-ios/Client/Configuration/FloorpRelease.xcconfig",
            b"FLOORP_BUILD_NUMBER = 4\n",
        )
        self.write_repo_file(
            self.ios,
            "docs/floorp-notes-sync-architecture.md",
            b"# synthetic architecture\n",
        )
        self.write_repo_file(
            self.ios,
            "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json",
            PREPARER.canonical_bytes({"fixture": 1}),
        )
        self.write_repo_file(
            self.ios,
            "docs/floorp-notes-sync-g4-attestation.json",
            PREPARER.canonical_bytes({"schema_version": 1, "task_id": 18}),
        )
        self.git(self.ios, "add", ".")
        self.git(self.ios, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "merged")
        merged = self.git(self.ios, "rev-parse", "HEAD")
        self.ios_branch = self.git(self.ios, "symbolic-ref", "--short", "HEAD")
        self.git(self.ios, "checkout", "-q", "--detach", merged)
        return base, merged

    def make_floorp_repository(self) -> str:
        self.floorp.mkdir()
        self.git(self.floorp, "init", "-q")
        self.write_repo_file(
            self.floorp,
            "docs/development/floorp-notes-sync/prerequisites.json",
            PREPARER.canonical_bytes({"schema_version": 1}),
        )
        self.write_repo_file(
            self.floorp,
            "docs/development/floorp-notes-sync/ADR-001-floorp-notes-sync-contract.md",
            b"# synthetic desktop contract\n",
        )
        self.git(self.floorp, "add", ".")
        self.git(self.floorp, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "floorp")
        return self.git(self.floorp, "rev-parse", "HEAD")

    def blob_spec(
        self,
        role: str,
        repository: str,
        worktree_name: str,
        repository_path: Path,
        commit_sha: str | None,
        path: str,
        policy: str,
        target: str,
    ):
        selected_commit = self.merged_oid if commit_sha is None else commit_sha
        raw = subprocess.run(
            ["/usr/bin/git", "-C", str(repository_path), "show", f"{selected_commit}:{path}"],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        return PREPARER.RepositoryFileSpec(
            role,
            repository,
            worktree_name,
            commit_sha,
            path,
            policy,
            PREPARER.git_blob_sha(raw),
            hashlib.sha256(raw).hexdigest(),
            target,
        )

    def evidence_spec(self, key: str, source: str, target: str, raw: bytes):
        path = self.evidence / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return PREPARER.EvidenceFileSpec(key, source, target, hashlib.sha256(raw).hexdigest())

    def make_summary(
        self,
        key: str,
        target: str,
        source_names: tuple[str, ...],
        base_payload: dict[str, object],
    ):
        sources: list[tuple[str, str]] = []
        payload = dict(base_payload)
        for index, source_name in enumerate(source_names):
            raw = f"{key}-source-{index}\n".encode()
            source_path = self.evidence / source_name
            source_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.write_bytes(raw)
            digest = hashlib.sha256(raw).hexdigest()
            sources.append((source_name, digest))
        if key == "tps":
            payload["source_log_sha256"] = sources[0][1]
            payload["source_summary_sha256"] = sources[1][1]
        else:
            payload["source_log_sha256"] = sources[0][1]
        raw = PREPARER.canonical_bytes(payload)
        return PREPARER.SummarySpec(
            key,
            target,
            payload,
            hashlib.sha256(raw).hexdigest(),
            tuple(sources),
        )

    def make_asset(self, role: str, name: str, asset_id: int):
        source = f"assets/{name}"
        raw = f"synthetic-{role}".encode()
        path = self.evidence / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return PREPARER.ReleaseAssetSpec(
            role,
            name,
            asset_id,
            hashlib.sha256(raw).hexdigest(),
            source,
            f"captures/g2-{name}",
        )

    def make_contract(self):
        evidence_files = (
            self.evidence_spec("task16", "task16.json", "artifacts/task-16-manifest.json", b'{"task":16}\n'),
            self.evidence_spec("task17", "task17.json", "artifacts/task-17-manifest.json", b'{"task":17}\n'),
            self.evidence_spec("task18", "task18.json", "artifacts/task-18-manifest.json", b'{"task":18}\n'),
            self.evidence_spec(
                "task18-verdict",
                "verdict.json",
                "artifacts/task-18-execution-verdict.json",
                PREPARER.canonical_bytes({"verdict": "APPROVE"}),
            ),
        )
        summaries = (
            self.make_summary(
                "fake-server",
                "artifacts/g2-fake-server-run.json",
                ("logs/fake.log",),
                {"failed": 0, "passed": 24, "secrets_retained": False},
            ),
            self.make_summary(
                "xpcshell",
                "artifacts/g4-xpcshell-run.json",
                ("logs/xpcshell.log",),
                {"failed": 0, "passed": 108, "secrets_retained": False},
            ),
            self.make_summary(
                "tps",
                "artifacts/g4-tps-run.json",
                ("logs/tps.log", "logs/tps.json"),
                {
                    "failed": 0,
                    "passed": 1,
                    "payload_retained": False,
                    "secrets_retained": False,
                },
            ),
        )
        assets = (
            self.make_asset("focus-xcframework", "FocusRustComponents.xcframework.zip", 506076697),
            self.make_asset("mozilla-xcframework", "MozillaRustComponents.xcframework.zip", 506076696),
            self.make_asset("release-manifest", "release-manifest.json", 506076698),
            self.make_asset("sha256sums", "SHA256SUMS", 506076695),
            self.make_asset("swift-components", "swift-components.tar.xz", 506076699),
        )
        repository_files = (
            self.blob_spec(
                "todo16-contract",
                "Floorp-Projects/Floorp",
                "floorp",
                self.floorp,
                self.floorp_oid,
                "docs/development/floorp-notes-sync/prerequisites.json",
                "metadata-json",
                "captures/g1-todo16-contract.json",
            ),
            self.blob_spec(
                "ios-contract-source",
                "Floorp-Projects/floorp-ios",
                "ios",
                self.ios,
                None,
                "docs/floorp-notes-sync-architecture.md",
                "source-code",
                "captures/g1-ios-contract-source.md",
            ),
            self.blob_spec(
                "desktop-contract-source",
                "Floorp-Projects/Floorp",
                "floorp",
                self.floorp,
                self.floorp_oid,
                "docs/development/floorp-notes-sync/ADR-001-floorp-notes-sync-contract.md",
                "source-code",
                "captures/g1-desktop-contract-source.md",
            ),
            self.blob_spec(
                "merge-fixture",
                "Floorp-Projects/floorp-ios",
                "ios",
                self.ios,
                None,
                "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json",
                "metadata-json",
                "captures/g1-merge-fixture.json",
            ),
            self.blob_spec(
                "g4-attestation-source",
                "Floorp-Projects/floorp-ios",
                "ios",
                self.ios,
                None,
                "docs/floorp-notes-sync-g4-attestation.json",
                "metadata-json",
                "captures/g4-attestation-source.json",
            ),
        )
        return replace(
            PREPARER.PRODUCTION_CONTRACT,
            base_oid=self.base_oid,
            reviewed_head_oid=self.merged_oid,
            todo16_source_sha=self.floorp_oid,
            desktop_source_sha=self.floorp_oid,
            desktop_run_head_sha="a" * 40,
            runtime_run_head_sha="b" * 40,
            runtime_source_sha="c" * 40,
            runtime_tree_sha="d" * 40,
            evidence_files=evidence_files,
            summaries=summaries,
            release_assets=assets,
            repository_files=repository_files,
        )

    def write_json(self, path: Path, value: object, *, canonical: bool = True) -> None:
        raw = PREPARER.canonical_bytes(value) if canonical else json.dumps(value, indent=2).encode()
        path.write_bytes(raw)
        path.chmod(0o600)

    def run_payload(
        self,
        repository: str,
        run_id: int,
        head_sha: str,
        workflow: str,
        created_at: str,
        *,
        event: str = "workflow_dispatch",
        branch: str = "main",
    ) -> dict[str, object]:
        created = datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        return {
            "conclusion": "success",
            "created_at": created_at,
            "event": event,
            "head_branch": branch,
            "head_sha": head_sha,
            "id": run_id,
            "repository": repository,
            "run_attempt": 1,
            "status": "completed",
            "updated_at": (created + timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "workflow_path": workflow,
        }

    def write_captures(self) -> None:
        self.g3_run = self.run_payload(
            self.contract.ios_repository,
            400000003,
            self.merged_oid,
            ".github/workflows/ci.yml",
            "2026-08-10T00:00:00Z",
            event="push",
        )
        self.desktop_run = self.run_payload(
            self.contract.floorp_repository,
            self.contract.desktop_run_id,
            self.contract.desktop_run_head_sha,
            self.contract.desktop_workflow_path,
            "2026-08-09T22:00:00Z",
        )
        self.runtime_run = self.run_payload(
            self.contract.runtime_repository,
            self.contract.runtime_run_id,
            self.contract.runtime_run_head_sha,
            self.contract.runtime_workflow_path,
            "2026-08-09T21:00:00Z",
        )
        self.artifact_metadata = {
            "artifact_created_at": "2026-08-10T00:31:00Z",
            "artifact_expires_at": "2026-08-17T00:31:00Z",
            "artifact_id": 500000003,
            "artifact_name": "floorp-notes-sync-xcresult",
            "head_sha": self.merged_oid,
            "run_id": self.g3_run["id"],
        }
        self.write_json(self.g3_run_path, self.g3_run)
        self.write_json(self.desktop_run_path, self.desktop_run)
        self.write_json(self.runtime_run_path, self.runtime_run)
        self.write_json(self.artifact_metadata_path, self.artifact_metadata)
        self.xcresult_path.write_bytes(b"synthetic-xcresult-zip")
        self.xcresult_path.chmod(0o600)

    def arguments(self, *, merged_oid: str | None = None, output: Path | None = None) -> list[str]:
        return [
            "--run-dir",
            str(self.run_dir),
            "--merged-ios-worktree",
            str(self.ios),
            "--floorp-worktree",
            str(self.floorp),
            "--merged-oid",
            self.merged_oid if merged_oid is None else merged_oid,
            "--g3-run-json",
            str(self.g3_run_path),
            "--g3-artifact-metadata-json",
            str(self.artifact_metadata_path),
            "--g3-xcresult-zip",
            str(self.xcresult_path),
            "--desktop-run-json",
            str(self.desktop_run_path),
            "--runtime-run-json",
            str(self.runtime_run_path),
            "--output-recipe",
            str(self.output if output is None else output),
            "--evidence-root",
            str(self.evidence),
        ]

    def invoke(self, **kwargs) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(PREPARER, "PRODUCTION_CONTRACT", self.contract),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            result = PREPARER.main(self.arguments(**kwargs))
        return result, stdout.getvalue(), stderr.getvalue()

    def rewrite_canonical(self, path: Path, payload: dict[str, object]) -> None:
        self.write_json(path, payload)

    def test_prepares_exact_canonical_recipe_and_idempotently_resumes(self):
        result, stdout, stderr = self.invoke()
        self.assertEqual(result, 0, stderr)
        self.assertIn("APPROVE", stdout)
        raw = self.output.read_bytes()
        recipe = json.loads(raw)
        self.assertEqual(raw, PREPARER.canonical_bytes(recipe))
        self.assertFalse(raw.endswith(b"\n"))
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.run_dir / "artifacts").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.run_dir / "captures").stat().st_mode), 0o700)
        for gate_name, roles in PREPARER.GATE_SOURCE_ROLES.items():
            self.assertEqual(
                tuple(entry["descriptor"]["role"] for entry in recipe["gates"][gate_name]["sources"]),
                roles,
            )
        receipt_path = self.run_dir / "artifacts/task-19-integration-receipt.json"
        self.assertFalse(receipt_path.exists())
        receipt = {
            "commands": recipe["g3_integration_commands"],
            "repositories": [
                {
                    "base_oid": self.base_oid,
                    "head_oid": self.merged_oid,
                    "merged_oid": self.merged_oid,
                    "name": "floorp-ios",
                }
            ],
            "schema_version": 1,
            "state": "integration_complete",
            "task_id": 19,
        }
        receipt_source = recipe["gates"]["g3"]["sources"][0]["descriptor"]
        self.assertEqual(receipt_source["sha256"], hashlib.sha256(PREPARER.canonical_bytes(receipt)).hexdigest())
        g3_run = recipe["gates"]["g3"]["sources"][1]
        g4_run = recipe["gates"]["g4"]["sources"][5]
        self.assertEqual({**g4_run["descriptor"], "role": "ci-run"}, g3_run["descriptor"])
        self.assertEqual(g4_run["bytes_path"], g3_run["bytes_path"])
        before = {path: path.stat().st_mtime_ns for path in self.run_dir.rglob("*") if path.is_file()}
        result, _, stderr = self.invoke()
        self.assertEqual(result, 0, stderr)
        after = {path: path.stat().st_mtime_ns for path in self.run_dir.rglob("*") if path.is_file()}
        self.assertEqual(before, after)

    def test_rejects_mismatch_symlink_and_wrong_mode_without_clobbering(self):
        artifacts = self.run_dir / "artifacts"
        artifacts.mkdir(mode=0o700)
        target = artifacts / "task-16-manifest.json"
        target.write_bytes(b"existing-mismatch")
        target.chmod(0o600)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertTrue("does not match" in stderr or "size differs" in stderr, stderr)
        self.assertEqual(target.read_bytes(), b"existing-mismatch")

        target.unlink()
        target.symlink_to(self.evidence / "task16.json")
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("symlink", stderr.lower())
        self.assertTrue(target.is_symlink())

        target.unlink()
        raw = (self.evidence / "task16.json").read_bytes()
        target.write_bytes(raw)
        target.chmod(0o644)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("0600", stderr)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)

    def test_rejects_dirty_wrong_head_and_attached_worktree(self):
        (self.ios / "untracked.txt").write_text("dirty", encoding="utf-8")
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("dirty", stderr)
        (self.ios / "untracked.txt").unlink()

        result, _, stderr = self.invoke(merged_oid=self.base_oid)
        self.assertEqual(result, 1)
        self.assertIn("HEAD", stderr)

        self.git(self.ios, "checkout", "-q", self.ios_branch)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("detached", stderr)

    def test_rejects_noncanonical_run_and_run_identity_mismatch(self):
        self.write_json(self.g3_run_path, self.g3_run, canonical=False)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("canonical", stderr)

        wrong = dict(self.g3_run)
        wrong["event"] = "workflow_dispatch"
        self.rewrite_canonical(self.g3_run_path, wrong)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("event mismatch", stderr)

        self.rewrite_canonical(self.g3_run_path, self.g3_run)
        wrong_desktop = dict(self.desktop_run)
        wrong_desktop["id"] = self.contract.desktop_run_id + 1
        self.rewrite_canonical(self.desktop_run_path, wrong_desktop)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("run ID mismatch", stderr)

    def test_rejects_artifact_identity_and_time_errors(self):
        wrong = dict(self.artifact_metadata)
        wrong["artifact_name"] = "not-the-canonical-artifact"
        self.rewrite_canonical(self.artifact_metadata_path, wrong)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("artifact name", stderr)

        wrong = dict(self.artifact_metadata)
        wrong["artifact_expires_at"] = "2026-08-17T00:31:01Z"
        self.rewrite_canonical(self.artifact_metadata_path, wrong)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("seven-day", stderr)

        self.rewrite_canonical(self.artifact_metadata_path, self.artifact_metadata)
        future_desktop = dict(self.desktop_run)
        future_desktop["created_at"] = "2026-08-18T00:00:00Z"
        future_desktop["updated_at"] = "2026-08-18T00:30:00Z"
        self.rewrite_canonical(self.desktop_run_path, future_desktop)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("G4 evidence lifetime", stderr)

    def test_verifies_summary_sources_before_writing_summary(self):
        summary = next(spec for spec in self.contract.summaries if spec.key == "fake-server")
        source = self.evidence / summary.source_artifacts[0][0]
        source.write_bytes(source.read_bytes() + b"tampered")
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("summary source artifact SHA-256", stderr)
        self.assertFalse((self.run_dir / summary.target_relative).exists())

    def test_rejects_output_outside_run_dir_and_existing_receipt(self):
        outside = self.directory / "outside-recipe.json"
        result, _, stderr = self.invoke(output=outside)
        self.assertEqual(result, 1)
        self.assertIn("under --run-dir", stderr)
        self.assertFalse(outside.exists())

        receipt = self.run_dir / "artifacts/task-19-integration-receipt.json"
        receipt.parent.mkdir(mode=0o700)
        receipt.write_bytes(b"assembler-owned")
        receipt.chmod(0o600)
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("only the assembler", stderr)
        self.assertEqual(receipt.read_bytes(), b"assembler-owned")

    def test_rejects_repository_blob_drift_and_wrong_build_number(self):
        repository_files = list(self.contract.repository_files)
        repository_files[0] = replace(repository_files[0], blob_sha="0" * 40)
        self.contract = replace(self.contract, repository_files=tuple(repository_files))
        result, _, stderr = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn("Git blob SHA mismatch", stderr)

        self.contract = self.make_contract()
        self.git(self.ios, "checkout", "-q", self.ios_branch)
        config = self.ios / "firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
        config.write_text("FLOORP_BUILD_NUMBER = 5\n", encoding="utf-8")
        self.git(self.ios, "add", str(config.relative_to(self.ios)))
        self.git(self.ios, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "wrong build")
        wrong_oid = self.git(self.ios, "rev-parse", "HEAD")
        self.git(self.ios, "checkout", "-q", "--detach", wrong_oid)
        self.contract = replace(
            self.contract,
            base_oid=self.merged_oid,
            reviewed_head_oid=wrong_oid,
        )
        result, _, stderr = self.invoke(merged_oid=wrong_oid)
        self.assertEqual(result, 1)
        self.assertIn("FLOORP_BUILD_NUMBER", stderr)

    def test_cli_has_no_test_bypass_and_production_constants_match_contract(self):
        source = PREPARER_PATH.read_text(encoding="utf-8")
        self.assertNotIn("test_", source)
        self.assertNotIn("urllib", source)
        self.assertNotIn("requests", source)
        self.assertEqual(
            PREPARER.PRODUCTION_CONTRACT.release_published_at,
            "2026-08-08T05:41:30Z",
        )
        self.assertEqual(
            tuple(spec.role for spec in PREPARER.PRODUCTION_CONTRACT.release_assets),
            PREPARER.GATE_SOURCE_ROLES["g2"][2:],
        )


if __name__ == "__main__":
    unittest.main()
