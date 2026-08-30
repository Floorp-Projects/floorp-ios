"""Tests for the fail-closed Floorp Notes Sync release-evidence validator."""

from __future__ import annotations

import copy
import contextlib
import hashlib
import importlib.util
import inspect
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / "scripts/ci/validate-floorp-notes-sync-release.py"
SCHEMA = ROOT / "docs/floorp-notes-sync-release-evidence.schema.json"
FIXTURES = ROOT / "scripts/ci/fixtures"
SSH_KEYGEN = Path("/usr/bin/ssh-keygen")
NAMESPACE = "floorp-notes-sync"
ROLES = (
    "architecture-owner",
    "security-reviewer",
    "privacy-reviewer",
    "retention-reviewer",
    "rollout-approver",
)
PRODUCTION_QA_MODE = "production-qa"
RELEASE_ENABLED_MODE = "release-enabled"
G1_G4_NAMES = ("g1", "g2", "g3", "g4")
G1_G5_NAMES = (*G1_G4_NAMES, "g5")
STATIC_G5_XCRESULT_TEST = "FloorpNotesSyncTwoClientMatrixTests/testTwoClientProductionMatrix()"
ACTUAL_G5_XCRESULT_TEST = (
    "FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix()"
)

VALIDATOR_SPEC = importlib.util.spec_from_file_location(
    "floorp_notes_sync_release_validator",
    VALIDATOR,
)
if VALIDATOR_SPEC is None or VALIDATOR_SPEC.loader is None:
    raise RuntimeError("validator test module could not be loaded")
VALIDATOR_MODULE = importlib.util.module_from_spec(VALIDATOR_SPEC)
VALIDATOR_SPEC.loader.exec_module(VALIDATOR_MODULE)


MOCK_GH = r'''#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
scenario = os.environ.get("MOCK_GH_SCENARIO", "success")
head = "330870f9d6db91433afe1024ac8200f81d260a42"
run_id = 987654321
workflow_id = 123456789
workflow_path = ".github/workflows/floorp-notes-sync-validation-clock.yml"

if scenario == "require_hostname" and not (
    "--hostname" in args
    and args[args.index("--hostname") + 1] == "github.com"
):
    print("public GitHub hostname was not forced", file=sys.stderr)
    raise SystemExit(18)

if scenario == "api_failure":
    print("Authorization: Bearer should-never-be-reported", file=sys.stderr)
    raise SystemExit(17)

run = {
    "conclusion": "success",
    "created_at": "2026-08-09T23:59:00Z",
    "event": "workflow_dispatch",
    "head_sha": head,
    "html_url": f"https://github.com/Floorp-Projects/floorp-ios/actions/runs/{run_id}",
    "id": run_id,
    "path": f"{workflow_path}@{head}",
    "repository": {"full_name": "Floorp-Projects/floorp-ios"},
    "run_attempt": 1,
    "status": "completed",
    "updated_at": "2026-08-10T00:00:00Z",
    "url": f"https://api.github.com/repos/Floorp-Projects/floorp-ios/actions/runs/{run_id}",
    "workflow_id": workflow_id,
}
if scenario == "changed_run":
    run["updated_at"] = "2026-08-10T00:00:01Z"

job = {
    "completed_at": "2026-08-10T00:00:00Z",
    "conclusion": "success",
    "id": 987654322,
    "name": "validation-clock",
    "run_attempt": 1,
    "run_id": run_id,
    "started_at": "2026-08-09T23:59:00Z",
    "status": "completed",
}
if scenario == "wrong_jobs":
    job["name"] = "untrusted-job"

joined = " ".join(args)
if "/attempts/" in joined and "/jobs" in joined:
    print(json.dumps({"jobs": [job], "total_count": 1}))
elif f"/actions/runs/{run_id}" in joined and "--include" in args:
    http_date = "Mon, 10 Aug 2026 00:10:00 GMT" if scenario == "stale_live_date" else "Mon, 10 Aug 2026 00:02:00 GMT"
    print("HTTP/2.0 200 OK")
    print(f"Date: {http_date}")
    print("Content-Type: application/json")
    print()
    print(json.dumps(run))
else:
    print("unexpected mock gh invocation", file=sys.stderr)
    raise SystemExit(19)
'''


def canonical_bytes(value: object) -> bytes:
    if value is None:
        return b"null"
    if value is True:
        return b"true"
    if value is False:
        return b"false"
    if isinstance(value, int):
        return str(value).encode("ascii")
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if isinstance(value, list):
        return b"[" + b",".join(canonical_bytes(item) for item in value) + b"]"
    if isinstance(value, dict):
        ordered = sorted(value, key=lambda key: key.encode("utf-16-be"))
        members = (
            canonical_bytes(key) + b":" + canonical_bytes(value[key])
            for key in ordered
        )
        return b"{" + b",".join(members) + b"}"
    raise TypeError(f"unsupported canonical JSON value: {type(value).__name__}")


def digest(value: object) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def git_blob_sha(raw: bytes) -> str:
    return hashlib.sha1(f"blob {len(raw)}\0".encode("ascii") + raw).hexdigest()


def local_source(role: str, path: str, policy: str, raw: bytes) -> dict[str, object]:
    return {
        "content_policy": policy,
        "kind": "local-file",
        "path": path,
        "role": role,
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def repository_source(
    role: str,
    repository: str,
    commit_sha: str,
    path: str,
    policy: str,
    raw: bytes,
) -> dict[str, object]:
    return {
        "blob_sha": git_blob_sha(raw),
        "commit_sha": commit_sha,
        "content_policy": policy,
        "kind": "github-repository-file",
        "path": path,
        "repository": repository,
        "role": role,
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def actions_run_payload(
    repository: str,
    run_id: int,
    workflow_path: str,
    head_sha: str,
    *,
    event: str = "workflow_dispatch",
    head_branch: str = "main",
) -> dict[str, object]:
    return {
        "conclusion": "success",
        "created_at": "2026-08-09T23:00:00Z",
        "event": event,
        "head_branch": head_branch,
        "head_sha": head_sha,
        "id": run_id,
        "repository": repository,
        "run_attempt": 1,
        "status": "completed",
        "updated_at": "2026-08-09T23:30:00Z",
        "workflow_path": workflow_path,
    }


def actions_run_source(
    role: str,
    repository: str,
    run_id: int,
    workflow_path: str,
    head_sha: str,
    *,
    event: str = "workflow_dispatch",
    head_branch: str = "main",
) -> dict[str, object]:
    raw = canonical_bytes(
        actions_run_payload(
            repository,
            run_id,
            workflow_path,
            head_sha,
            event=event,
            head_branch=head_branch,
        )
    )
    return {
        "content_policy": "metadata-json",
        "head_sha": head_sha,
        "kind": "github-actions-run",
        "repository": repository,
        "role": role,
        "run_id": run_id,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "workflow_path": workflow_path,
    }


def actions_artifact_source(
    role: str,
    repository: str,
    run_id: int,
    artifact_id: int,
    artifact_name: str,
    head_sha: str,
    raw: bytes,
) -> dict[str, object]:
    return {
        "artifact_id": artifact_id,
        "artifact_name": artifact_name,
        "artifact_created_at": "2026-08-09T23:31:00Z",
        "artifact_expires_at": "2026-08-16T23:31:00Z",
        "content_policy": "test-result-bundle",
        "head_sha": head_sha,
        "kind": "github-actions-artifact",
        "repository": repository,
        "role": role,
        "run_id": run_id,
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def release_asset_source(
    role: str,
    asset_name: str,
    asset_id: int,
    raw: bytes,
    inputs: dict[str, object],
) -> dict[str, object]:
    services = inputs["application_services"]
    return {
        "asset_id": asset_id,
        "asset_name": asset_name,
        "content_policy": "release-binary",
        "kind": "github-release-asset",
        "release_id": 379394157,
        "release_immutable": True,
        "release_prerelease": True,
        "release_published_at": "2026-08-08T05:41:30Z",
        "release_tag": services["release_tag"],
        "repository": services["repository"],
        "role": role,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "source_sha": services["source_sha"],
    }


def artifact_bundle(sources: list[dict[str, object]]) -> dict[str, object]:
    return {"sha256": digest({"sources": sources}), "sources": sources}


def synthetic_xcresult_zip(
    summary: bytes = b"synthetic-only test metadata",
) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for path, raw in (
            ("FloorpNotesSync.xcresult/Info.plist", b"<?xml version='1.0'?><plist version='1.0'><dict/></plist>"),
            ("FloorpNotesSync.xcresult/Data/test-summary", summary),
        ):
            info = zipfile.ZipInfo(path, date_time=(2026, 8, 10, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            archive.writestr(info, raw)
    return output.getvalue()


def contents_root_xcresult_zip(
    summary: bytes = b"synthetic-only test metadata",
) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for path, raw in (
            ("Info.plist", b"<?xml version='1.0'?><plist version='1.0'><dict/></plist>"),
            ("Data/test-summary", summary),
        ):
            info = zipfile.ZipInfo(path, date_time=(2026, 8, 10, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            archive.writestr(info, raw)
    return output.getvalue()


TEST_SOURCE_BYTES = {
    "todo16-contract": canonical_bytes(
        {
            "g6": {
                "allowed_signers_path": "docs/development/floorp-notes-sync/allowed-signers",
                "revocations_path": "docs/development/floorp-notes-sync/revocations.json",
            },
            "production_environment": {
                "application_record_id": "e2VjODAzMGY3LWMyMGEtNDY0Zi05YjBlLTEzYTNhOWU5NzM4NH0=",
                "endpoint_policy_sha256": "af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca",
                "fxa_configuration": "FxAConfig.Server.release",
                "fxa_hosts": [
                    "accounts.firefox.com",
                    "api.accounts.firefox.com",
                    "oauth.accounts.firefox.com",
                    "profile.accounts.firefox.com",
                    "static.accounts.firefox.com",
                ],
                "status": "approved",
                "sync_hosts": [
                    "event-sync.services.mozilla.com",
                    "sync.services.mozilla.com",
                    "token.services.mozilla.com",
                ],
                "wire": "sync15",
            },
            "schema_version": 1,
        }
    ),
    "ios-contract-source": b"# Test iOS Notes Sync contract\n",
    "desktop-contract-source": b"# Test Desktop Notes Sync contract\n",
    "fake-server-run": canonical_bytes({"failed": 0, "passed": 24, "secrets_retained": False}),
    "focus-xcframework": b"test FocusRustComponents XCFramework archive",
    "mozilla-xcframework": b"test MozillaRustComponents XCFramework archive",
    "release-manifest": b'{"schema_version":1,"test":"release-manifest"}\n',
    "sha256sums": b"test SHA256SUMS metadata\n",
    "swift-components": b"test swift-components archive",
    "xcresult": synthetic_xcresult_zip(
        b"ClientTests/FloorpNotesSyncEngineSelectionTests/"
        b"testG4AttestationBindsTask18Evidence()"
    ),
    "g5-xcresult": synthetic_xcresult_zip(
        b"XCUITests/FloorpNotesSyncActualG5TwoClientTests/"
        b"testActualG5TwoClientProductionMatrix()"
    ),
    "static-g5-xcresult": synthetic_xcresult_zip(
        b"XCUITests/FloorpNotesSyncTwoClientMatrixTests/"
        b"testTwoClientProductionMatrix()"
    ),
    "task18-execution-verdict": canonical_bytes(
        {
            "errors": [],
            "tasks": [
                {"completion_claim_count": 1, "id": 16, "state": "completed"},
                {"completion_claim_count": 1, "id": 18, "state": "completed"},
            ],
            "verdict": "APPROVE",
        }
    ),
    "xpcshell-run": canonical_bytes({"failed": 0, "passed": 109, "secrets_retained": False}),
    "tps-run": canonical_bytes(
        {"failed": 0, "passed": 1, "payload_retained": False, "secrets_retained": False}
    ),
    "account-isolation-run": canonical_bytes(
        {
            "accounts": 2,
            "base_advanced_after_upload": True,
            "cleanup_completed": True,
            "fixture_sha256": "2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd",
            "isolated": True,
            "local_only_fallback_succeeded": True,
            "payload_retained": False,
            "rollback_succeeded": True,
            "secrets_retained": False,
        }
    ),
    "proxy-trace": canonical_bytes(
        {
            "endpoint_policy_sha256": "af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca",
            "hosts": ["accounts.firefox.com", "sync.services.mozilla.com"],
            "metadata_only": True,
            "payload_retained": False,
            "port": 443,
            "secrets_retained": False,
            "tls_interception": False,
            "tls_verified": True,
        }
    ),
}


def release_inputs() -> dict[str, object]:
    return {
        "application_services": {
            "artifacts": {
                "focus_xcframework_sha256": hashlib.sha256(TEST_SOURCE_BYTES["focus-xcframework"]).hexdigest(),
                "mozilla_xcframework_sha256": hashlib.sha256(TEST_SOURCE_BYTES["mozilla-xcframework"]).hexdigest(),
                "release_manifest_sha256": hashlib.sha256(TEST_SOURCE_BYTES["release-manifest"]).hexdigest(),
                "sha256sums_sha256": hashlib.sha256(TEST_SOURCE_BYTES["sha256sums"]).hexdigest(),
                "swift_components_sha256": hashlib.sha256(TEST_SOURCE_BYTES["swift-components"]).hexdigest(),
            },
            "release_tag": "floorp-ios-155.20260731050244.5",
            "repository": "Floorp-Projects/application-services",
            "source_sha": "e1c77eb6e333ef667456504100c7b09763b8ad35",
            "tree_sha": "338e0dc010b48fb63c93892f527ce56905805344",
        },
        "contract": {
            "case_set_sha256": "c19ec1a3229b0d09aa424498471941409bc77505862e8aa278aadb3396032802",
            "endpoint_policy_sha256": "af96437acde3d05eb8f18dc9cc81450aa9d61703579c092b962922de8934c9ca",
            "fixture_sha256": "2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd",
        },
        "desktop": {
            "build_number": "31338438952",
            "repository": "Floorp-Projects/Floorp",
            "source_sha": "fc244eed70248796fa92ff5821c6046ecd576e7e",
        },
        "environment": {
            "fxa_configuration": "FxAConfig.Server.release",
            "fxa_hosts": [
                "accounts.firefox.com",
                "api.accounts.firefox.com",
                "oauth.accounts.firefox.com",
                "profile.accounts.firefox.com",
                "static.accounts.firefox.com",
            ],
            "sync_hosts": [
                "event-sync.services.mozilla.com",
                "sync.services.mozilla.com",
                "token.services.mozilla.com",
            ],
            "wire_protocol": "sync15",
        },
        "ios": {
            "build_number": "2026081001",
            "configuration": "FloorpRelease",
            "repository": "Floorp-Projects/floorp-ios",
            "source_sha": "330870f9d6db91433afe1024ac8200f81d260a42",
        },
        "runtime": {
            "repository": "Floorp-Projects/Floorp-Runtime",
            "source_sha": "3bf9399564e59be32f92dcc1b044094881b4fb6a",
            "tree_sha": "533f9fdca9bdccb7f3d2a13842be7e2375160ae5",
        },
    }


def task_manifest_bytes(task_id: int, inputs: dict[str, object]) -> bytes:
    repositories_by_task = {
        16: [
            {
                "base_oid": "c23319ffbb710d0ae167608fcad4615fd99a028c",
                "head_oid": "d90f320ae0d3225382d75dbab94daaf8d38733fd",
                "merged_oid": "18841c0c43d0eda428e1c88170769c1539543848",
                "name": "Floorp",
            }
        ],
        17: [
            {
                "base_oid": "d588863894e9b3ce58b05a964a7694ab00e28054",
                "head_oid": inputs["application_services"]["source_sha"],
                "merged_oid": inputs["application_services"]["source_sha"],
                "name": "application-services",
            }
        ],
        18: [
            {
                "base_oid": "ca3d0003976321fd67061d463ab56958b0f38cd9",
                "head_oid": "515da7cf9c7fc258eacd56902448eb10989d17b0",
                "merged_oid": inputs["runtime"]["source_sha"],
                "name": "Floorp-Runtime",
            },
            {
                "base_oid": "18841c0c43d0eda428e1c88170769c1539543848",
                "head_oid": "17b47fcb837272040a6231963b5221aaec80fa42",
                "merged_oid": inputs["desktop"]["source_sha"],
                "name": "Floorp",
            },
        ],
        19: [
            {
                "base_oid": inputs["ios"]["source_sha"],
                "head_oid": inputs["ios"]["source_sha"],
                "merged_oid": inputs["ios"]["source_sha"],
                "name": "floorp-ios",
            }
        ],
        20: [
            {
                "base_oid": inputs["ios"]["source_sha"],
                "head_oid": inputs["ios"]["source_sha"],
                "name": "floorp-ios",
            }
        ],
    }
    return canonical_bytes(
        {
            "commands": [
                {
                    "argv": ["test", f"task-{task_id}"],
                    "exit_code": 0,
                    "terminal": True,
                }
            ],
            "repositories": repositories_by_task[task_id],
            "schema_version": 1,
            "state": "g5_completed" if task_id == 20 else "completed",
            "task_id": task_id,
        }
    )


def integration_receipt_bytes(inputs: dict[str, object]) -> bytes:
    return canonical_bytes(
        {
            "commands": [
                {
                    "argv": ["verify", "task-19-integration"],
                    "exit_code": 0,
                    "terminal": True,
                }
            ],
            "repositories": [
                {
                    "base_oid": "330870f9d6db91433afe1024ac8200f81d260a42",
                    "head_oid": "af21d1a4f95eda87dabfaf3a0dfa0fbb89b7ccfb",
                    "merged_oid": inputs["ios"]["source_sha"],
                    "name": "floorp-ios",
                }
            ],
            "schema_version": 1,
            "state": "integration_complete",
            "task_id": 19,
        }
    )


def g4_attestation_bytes(inputs: dict[str, object]) -> bytes:
    return canonical_bytes(
        {
            "desktop": {
                "merged_sha": inputs["desktop"]["source_sha"],
                "run_head_sha": "17b47fcb837272040a6231963b5221aaec80fa42",
                "run_id": 31338438952,
                "workflow_path": ".github/workflows/colocated_runner_test.yml",
            },
            "floorpci_test": (
                "ClientTests/FloorpNotesSyncEngineSelectionTests/"
                "testG4AttestationBindsTask18Evidence()"
            ),
            "runtime": {
                "merged_sha": inputs["runtime"]["source_sha"],
                "run_head_sha": "515da7cf9c7fc258eacd56902448eb10989d17b0",
                "run_id": 31330766054,
                "tree_sha": inputs["runtime"]["tree_sha"],
                "workflow_path": ".github/workflows/wrapper-mac-build.yml",
            },
            "schema_version": 1,
            "summaries": {
                "execution_verdict_sha256": hashlib.sha256(
                    TEST_SOURCE_BYTES["task18-execution-verdict"]
                ).hexdigest(),
                "task_manifest_sha256": hashlib.sha256(task_manifest_bytes(18, inputs)).hexdigest(),
                "tps_sha256": hashlib.sha256(TEST_SOURCE_BYTES["tps-run"]).hexdigest(),
                "xpcshell_sha256": hashlib.sha256(TEST_SOURCE_BYTES["xpcshell-run"]).hexdigest(),
            },
            "task_id": 18,
        }
    )


def make_gate_sources(inputs: dict[str, object]) -> dict[str, list[dict[str, object]]]:
    fixture_raw = (ROOT / "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json").read_bytes()
    manifests = {task: task_manifest_bytes(task, inputs) for task in (16, 17, 18, 20)}
    g1 = [
        local_source("task-manifest", "artifacts/task-16-manifest.json", "metadata-json", manifests[16]),
        repository_source(
            "todo16-contract",
            "Floorp-Projects/Floorp",
            "18841c0c43d0eda428e1c88170769c1539543848",
            "docs/development/floorp-notes-sync/prerequisites.json",
            "metadata-json",
            TEST_SOURCE_BYTES["todo16-contract"],
        ),
        repository_source(
            "ios-contract-source",
            inputs["ios"]["repository"],
            inputs["ios"]["source_sha"],
            "docs/floorp-notes-sync-architecture.md",
            "source-code",
            TEST_SOURCE_BYTES["ios-contract-source"],
        ),
        repository_source(
            "desktop-contract-source",
            inputs["desktop"]["repository"],
            inputs["desktop"]["source_sha"],
            "docs/development/floorp-notes-sync/ADR-001-floorp-notes-sync-contract.md",
            "source-code",
            TEST_SOURCE_BYTES["desktop-contract-source"],
        ),
        repository_source(
            "merge-fixture",
            inputs["ios"]["repository"],
            inputs["ios"]["source_sha"],
            "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json",
            "metadata-json",
            fixture_raw,
        ),
    ]
    g2 = [
        local_source("task-manifest", "artifacts/task-17-manifest.json", "metadata-json", manifests[17]),
        local_source(
            "fake-server-run",
            "artifacts/g2-fake-server-run.json",
            "metadata-json",
            TEST_SOURCE_BYTES["fake-server-run"],
        ),
    ]
    release_assets = (
        ("focus-xcframework", "FocusRustComponents.xcframework.zip", 506076697),
        ("mozilla-xcframework", "MozillaRustComponents.xcframework.zip", 506076696),
        ("release-manifest", "release-manifest.json", 506076698),
        ("sha256sums", "SHA256SUMS", 506076695),
        ("swift-components", "swift-components.tar.xz", 506076699),
    )
    g2.extend(
        release_asset_source(role, name, asset_id, TEST_SOURCE_BYTES[role], inputs)
        for role, name, asset_id in release_assets
    )
    g3 = [
        local_source(
            "integration-receipt",
            "artifacts/task-19-integration-receipt.json",
            "metadata-json",
            integration_receipt_bytes(inputs),
        ),
        actions_run_source(
            "ci-run",
            inputs["ios"]["repository"],
            400000003,
            ".github/workflows/ci.yml",
            inputs["ios"]["source_sha"],
            event="push",
            head_branch="main",
        ),
        actions_artifact_source(
            "xcresult",
            inputs["ios"]["repository"],
            400000003,
            500000003,
            "floorp-notes-sync-xcresult",
            inputs["ios"]["source_sha"],
            TEST_SOURCE_BYTES["xcresult"],
        ),
    ]
    g4 = [
        local_source("task-manifest", "artifacts/task-18-manifest.json", "metadata-json", manifests[18]),
        local_source(
            "task18-execution-verdict",
            "artifacts/task-18-execution-verdict.json",
            "metadata-json",
            TEST_SOURCE_BYTES["task18-execution-verdict"],
        ),
        actions_run_source(
            "desktop-ci-run",
            inputs["desktop"]["repository"],
            31338438952,
            ".github/workflows/colocated_runner_test.yml",
            "17b47fcb837272040a6231963b5221aaec80fa42",
        ),
        actions_run_source(
            "runtime-ci-run",
            inputs["runtime"]["repository"],
            31330766054,
            ".github/workflows/wrapper-mac-build.yml",
            "515da7cf9c7fc258eacd56902448eb10989d17b0",
        ),
        repository_source(
            "g4-attestation-source",
            inputs["ios"]["repository"],
            inputs["ios"]["source_sha"],
            "docs/floorp-notes-sync-g4-attestation.json",
            "metadata-json",
            g4_attestation_bytes(inputs),
        ),
        actions_run_source(
            "g4-attestation-ci-run",
            inputs["ios"]["repository"],
            400000003,
            ".github/workflows/ci.yml",
            inputs["ios"]["source_sha"],
            event="push",
            head_branch="main",
        ),
        actions_artifact_source(
            "g4-attestation-xcresult",
            inputs["ios"]["repository"],
            400000003,
            500000003,
            "floorp-notes-sync-xcresult",
            inputs["ios"]["source_sha"],
            TEST_SOURCE_BYTES["xcresult"],
        ),
        local_source(
            "xpcshell-run",
            "artifacts/g4-xpcshell-run.json",
            "metadata-json",
            TEST_SOURCE_BYTES["xpcshell-run"],
        ),
        local_source(
            "tps-run",
            "artifacts/g4-tps-run.json",
            "metadata-json",
            TEST_SOURCE_BYTES["tps-run"],
        ),
    ]
    g5 = [
        local_source("task-manifest", "artifacts/task-20-manifest.json", "metadata-json", manifests[20]),
        actions_run_source(
            "ci-run",
            inputs["ios"]["repository"],
            400000005,
            ".github/workflows/floorp-notes-sync-production-qa.yml",
            inputs["ios"]["source_sha"],
        ),
        actions_artifact_source(
            "xcresult",
            inputs["ios"]["repository"],
            400000005,
            500000005,
            "floorp-notes-sync-two-client-xcresult",
            inputs["ios"]["source_sha"],
            TEST_SOURCE_BYTES["g5-xcresult"],
        ),
        local_source(
            "account-isolation-run",
            "artifacts/g5-account-isolation.json",
            "metadata-json",
            TEST_SOURCE_BYTES["account-isolation-run"],
        ),
        local_source(
            "proxy-trace",
            "artifacts/g5-proxy-trace.json",
            "network-metadata-json",
            TEST_SOURCE_BYTES["proxy-trace"],
        ),
    ]
    return {"g1": g1, "g2": g2, "g3": g3, "g4": g4, "g5": g5}


def make_evidence(*, mode: str = RELEASE_ENABLED_MODE) -> dict[str, object]:
    inputs = release_inputs()
    sources = make_gate_sources(inputs)
    gates = {
        "g1": {
            "artifact": artifact_bundle(sources["g1"]),
            "contract": {
                "case_set_sha256": inputs["contract"]["case_set_sha256"],
                "control_pref_name": "services.sync.prefs.sync.floorp.browser.note.memos",
                "control_pref_value": True,
                "desktop_contract_sha": inputs["desktop"]["source_sha"],
                "fixture_sha256": inputs["contract"]["fixture_sha256"],
                "ios_contract_sha": inputs["ios"]["source_sha"],
                "notes_pref_name": "floorp.browser.note.memos",
                "record_id": "e2VjODAzMGY3LWMyMGEtNDY0Zi05YjBlLTEzYTNhOWU5NzM4NH0=",
            },
            "issued_at": "2026-08-01T00:00:00Z",
            "status": "passed",
        },
        "g2": {
            "application_services": copy.deepcopy(inputs["application_services"]),
            "artifact": artifact_bundle(sources["g2"]),
            "expires_at": "2026-09-07T05:41:30Z",
            "fake_server_run_sha256": hashlib.sha256(TEST_SOURCE_BYTES["fake-server-run"]).hexdigest(),
            "issued_at": "2026-08-08T05:41:30Z",
            "status": "passed",
        },
        "g3": {
            "artifact": artifact_bundle(sources["g3"]),
            "candidate": copy.deepcopy(inputs["ios"]),
            "expires_at": "2026-08-16T23:31:00Z",
            "issued_at": "2026-08-09T23:31:00Z",
            "status": "passed",
            "xcresult_sha256": hashlib.sha256(TEST_SOURCE_BYTES["xcresult"]).hexdigest(),
        },
        "g4": {
            "artifact": artifact_bundle(sources["g4"]),
            "desktop": copy.deepcopy(inputs["desktop"]),
            "expires_at": "2026-08-16T23:31:00Z",
            "issued_at": "2026-08-09T23:00:00Z",
            "runtime": copy.deepcopy(inputs["runtime"]),
            "status": "passed",
            "tps_run_sha256": hashlib.sha256(TEST_SOURCE_BYTES["tps-run"]).hexdigest(),
            "xpcshell_run_sha256": hashlib.sha256(TEST_SOURCE_BYTES["xpcshell-run"]).hexdigest(),
        },
        "g5": {
            "account_isolation_run_sha256": hashlib.sha256(TEST_SOURCE_BYTES["account-isolation-run"]).hexdigest(),
            "application_services": {
                "mozilla_xcframework_sha256": inputs["application_services"]["artifacts"][
                    "mozilla_xcframework_sha256"
                ],
                "release_tag": inputs["application_services"]["release_tag"],
                "source_sha": inputs["application_services"]["source_sha"],
            },
            "artifact": artifact_bundle(sources["g5"]),
            "desktop": copy.deepcopy(inputs["desktop"]),
            "expires_at": "2026-08-16T23:31:00Z",
            "ios": copy.deepcopy(inputs["ios"]),
            "issued_at": "2026-08-09T23:31:00Z",
            "proxy_trace_sha256": hashlib.sha256(TEST_SOURCE_BYTES["proxy-trace"]).hexdigest(),
            "runtime": copy.deepcopy(inputs["runtime"]),
            "status": "passed",
        },
    }
    if mode == PRODUCTION_QA_MODE:
        del gates["g5"]
    evidence = {
        "build_contract_mode": mode,
        "gates": gates,
        "release_inputs": inputs,
        "same_release_key_sha256": "",
        "schema_version": 1,
    }
    if mode == PRODUCTION_QA_MODE:
        evidence["g1_g4_digest_sha256"] = ""
    else:
        evidence["g1_g5_digest_sha256"] = ""
    rehash(evidence)
    return evidence


def make_production_qa_evidence() -> dict[str, object]:
    return make_evidence(mode=PRODUCTION_QA_MODE)


def rehash(evidence: dict[str, object]) -> None:
    gates = evidence["gates"]
    mode = evidence["build_contract_mode"]
    if mode == PRODUCTION_QA_MODE:
        selected_gates = {name: gates[name] for name in G1_G4_NAMES}
        evidence["g1_g4_digest_sha256"] = digest(
            {"gates": selected_gates, "release_inputs": evidence["release_inputs"]}
        )
    elif mode == RELEASE_ENABLED_MODE:
        selected_gates = {name: gates[name] for name in G1_G5_NAMES}
        evidence["g1_g5_digest_sha256"] = digest(
            {"gates": selected_gates, "release_inputs": evidence["release_inputs"]}
        )
    else:
        raise ValueError(f"unsupported test evidence mode: {mode}")
    gate_digests = {
        name: gate["artifact"]["sha256"]
        for name, gate in gates.items()
    }
    evidence["same_release_key_sha256"] = digest(
        {
            "gate_artifact_digests": gate_digests,
            "release_inputs": evidence["release_inputs"],
        }
    )


def source_identity_key(source: dict[str, object]) -> str:
    return digest({name: value for name, value in source.items() if name != "sha256"})


def test_materials(evidence: dict[str, object]) -> tuple[dict[str, bytes], dict[str, bytes]]:
    local: dict[str, bytes] = {}
    remote: dict[str, bytes] = {}
    task_for_gate = {"g1": 16, "g2": 17, "g3": 19, "g4": 18, "g5": 20}
    for gate_name, gate in evidence["gates"].items():
        if gate_name not in task_for_gate:
            continue
        for source in gate["artifact"]["sources"]:
            role = source["role"]
            kind = source["kind"]
            if role == "integration-receipt":
                raw = integration_receipt_bytes(evidence["release_inputs"])
            elif role == "task-manifest":
                raw = task_manifest_bytes(task_for_gate[gate_name], evidence["release_inputs"])
            elif role == "merge-fixture":
                raw = (ROOT / "sync-fixtures/floorp-notes/floorp-notes-merge-v1.json").read_bytes()
            elif role == "g4-attestation-source":
                raw = g4_attestation_bytes(evidence["release_inputs"])
            elif kind == "github-actions-run":
                raw = canonical_bytes(
                    actions_run_payload(
                        source["repository"],
                        source["run_id"],
                        source["workflow_path"],
                        source["head_sha"],
                        event=(
                            "push"
                            if role in ("ci-run", "g4-attestation-ci-run")
                            and gate_name in ("g3", "g4")
                            else "workflow_dispatch"
                        ),
                        head_branch="main",
                    )
                )
            elif kind == "github-actions-artifact":
                raw = (
                    TEST_SOURCE_BYTES["g5-xcresult"]
                    if gate_name == "g5" and role == "xcresult"
                    else TEST_SOURCE_BYTES["xcresult"]
                )
            else:
                raw = TEST_SOURCE_BYTES[role]
            if kind == "local-file":
                local[source["path"]] = raw
            else:
                remote[source_identity_key(source)] = raw
    return local, remote


def make_clock() -> dict[str, object]:
    head = release_inputs()["ios"]["source_sha"]
    return {
        "expected_head_sha": head,
        "github_http_date": "Mon, 10 Aug 2026 00:02:00 GMT",
        "jobs": [
            {
                "completed_at": "2026-08-10T00:00:00Z",
                "conclusion": "success",
                "id": 987654322,
                "name": "validation-clock",
                "run_attempt": 1,
                "run_id": 987654321,
                "started_at": "2026-08-09T23:59:00Z",
                "status": "completed",
            }
        ],
        "max_age_seconds": 300,
        "provider": "github-actions",
        "repository": "Floorp-Projects/floorp-ios",
        "run": {
            "api_url": "https://api.github.com/repos/Floorp-Projects/floorp-ios/actions/runs/987654321",
            "attempt": 1,
            "conclusion": "success",
            "created_at": "2026-08-09T23:59:00Z",
            "event": "workflow_dispatch",
            "head_sha": head,
            "html_url": "https://github.com/Floorp-Projects/floorp-ios/actions/runs/987654321",
            "id": 987654321,
            "repository": "Floorp-Projects/floorp-ios",
            "status": "completed",
            "updated_at": "2026-08-10T00:00:00Z",
            "workflow_id": 123456789,
            "workflow_path": ".github/workflows/floorp-notes-sync-validation-clock.yml",
        },
        "schema_version": 1,
        "workflow": {
            "id": 123456789,
            "path": ".github/workflows/floorp-notes-sync-validation-clock.yml",
        },
    }


class FloorpNotesSyncReleaseValidatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.key_dir_owner = tempfile.TemporaryDirectory()
        cls.key_dir = Path(cls.key_dir_owner.name)
        cls.signers: list[dict[str, str | Path]] = []
        cls.mock_gh = cls.key_dir / "mock-gh"
        cls.mock_gh.write_text(MOCK_GH, encoding="utf-8")
        cls.mock_gh.chmod(cls.mock_gh.stat().st_mode | stat.S_IXUSR)
        if not SSH_KEYGEN.is_file():
            return
        for index, role in enumerate(ROLES):
            login = f"notes-sync-test-{index}"
            private_key = cls.key_dir / login
            subprocess.run(
                [str(SSH_KEYGEN), "-q", "-t", "ed25519", "-N", "", "-f", str(private_key)],
                check=True,
            )
            fingerprint_output = subprocess.run(
                [str(SSH_KEYGEN), "-lf", f"{private_key}.pub"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            fingerprint = fingerprint_output.split()[1]
            public_parts = Path(f"{private_key}.pub").read_text(encoding="utf-8").split()
            cls.signers.append(
                {
                    "fingerprint": fingerprint,
                    "key_type": public_parts[0],
                    "key_value": public_parts[1],
                    "login": login,
                    "private_key": private_key,
                    "role": role,
                }
            )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.key_dir_owner.cleanup()

    def write_json(self, directory: Path, name: str, value: object, *, canonical: bool = True) -> Path:
        path = directory / name
        if canonical:
            path.write_bytes(canonical_bytes(value))
        else:
            path.write_text(json.dumps(value, indent=2), encoding="utf-8")
        return path

    def make_local_xcresult(self, directory: Path) -> Path:
        result = directory / "FloorpNotesSync.xcresult"
        data = result / "Data"
        data.mkdir(parents=True)
        (result / "Info.plist").write_bytes(b"test plist metadata")
        (data / "test-summary").write_bytes(b"synthetic-only test metadata")
        return result

    def verify_test_release_asset(
        self,
        *,
        prerelease: bool,
        immutable: bool,
        expected_published_at: str = "2026-08-08T05:41:30Z",
        published_at: str = "2026-08-08T05:41:30Z",
    ) -> str:
        raw = TEST_SOURCE_BYTES["mozilla-xcframework"]
        source = release_asset_source(
            "application-services-mozilla-xcframework",
            "MozillaRustComponents.xcframework.zip",
            501,
            raw,
            release_inputs(),
        )
        source["release_prerelease"] = True
        source["release_immutable"] = True
        source["release_published_at"] = expected_published_at
        release = {
            "assets": [
                {
                    "id": source["asset_id"],
                    "name": source["asset_name"],
                }
            ],
            "draft": False,
            "id": source["release_id"],
            "immutable": immutable,
            "prerelease": prerelease,
            "published_at": published_at,
            "tag_name": source["release_tag"],
        }
        with (
            mock.patch.object(VALIDATOR_MODULE, "gh_api_json", return_value=release),
            mock.patch.object(
                VALIDATOR_MODULE,
                "resolve_release_tag",
                return_value=source["source_sha"],
            ),
            mock.patch.object(
                VALIDATOR_MODULE,
                "gh_api_download_digest",
                return_value=source["sha256"],
            ),
        ):
            return VALIDATOR_MODULE.verify_github_release_asset(
                source,
                Path("/usr/bin/false"),
                {},
                "g2 application-services asset",
            )

    def run_validator(
        self,
        evidence: object | None = None,
        clock: object | None = None,
        *,
        evidence_bytes: bytes | None = None,
        clock_bytes: bytes | None = None,
        gh_scenario: str = "success",
        schema: Path = SCHEMA,
        extra: list[str] | None = None,
        g6_trust_bundle: dict[str, bytes] | None = None,
        local_artifact_overrides: dict[str, bytes] | None = None,
        remote_artifact_overrides: dict[str, bytes] | None = None,
        test_xcresult_results: dict[str, str | list[str]] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            evidence_path = directory / "evidence.json"
            clock_path = directory / "clock.json"
            selected_evidence = evidence if evidence is not None else make_evidence()
            mode = (
                selected_evidence.get("build_contract_mode", RELEASE_ENABLED_MODE)
                if isinstance(selected_evidence, dict)
                else RELEASE_ENABLED_MODE
            )
            if mode not in (PRODUCTION_QA_MODE, RELEASE_ENABLED_MODE):
                mode = RELEASE_ENABLED_MODE
            canonical_test_evidence = make_evidence(mode=mode)
            local_artifacts, remote_artifacts = test_materials(canonical_test_evidence)
            if local_artifact_overrides:
                local_artifacts.update(local_artifact_overrides)
            if remote_artifact_overrides:
                remote_artifacts.update(remote_artifact_overrides)
            for relative, raw in local_artifacts.items():
                path = directory / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(raw)
            evidence_path.write_bytes(
                evidence_bytes if evidence_bytes is not None else canonical_bytes(selected_evidence)
            )
            clock_path.write_bytes(
                clock_bytes if clock_bytes is not None else canonical_bytes(clock or make_clock())
            )
            command = [
                "--schema",
                str(schema),
                "--evidence",
                str(evidence_path),
                "--validation-clock-manifest",
                str(clock_path),
                "--canonicalization",
                "rfc8785-jcs",
            ]
            if extra:
                command.extend(extra)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                return_code = VALIDATOR_MODULE.main(
                    command,
                    test_gh_bin=self.mock_gh,
                    test_gh_environment={"MOCK_GH_SCENARIO": gh_scenario},
                    test_remote_artifacts=remote_artifacts,
                    test_xcresult_results=(
                        test_xcresult_results
                        if test_xcresult_results is not None
                        else {
                            (
                                "FloorpNotesSyncEngineSelectionTests/"
                                "testG4AttestationBindsTask18Evidence()"
                            ): "Passed",
                            ACTUAL_G5_XCRESULT_TEST: "Passed",
                        }
                    ),
                    test_g6_trust_bundle=g6_trust_bundle,
                    test_ssh_keygen=SSH_KEYGEN if g6_trust_bundle is not None else None,
                    test_expected_ios_build_number=release_inputs()["ios"]["build_number"],
                )
            return subprocess.CompletedProcess(
                command,
                return_code,
                stdout.getvalue(),
                stderr.getvalue(),
            )

    def assert_rejected(self, evidence: object, clock: object | None = None) -> None:
        result = self.run_validator(evidence, clock)
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_rfc8785_utf16_key_order_reference_vector(self):
        value = {"\ufb33": 1, "😀": 2, "€": 3, "ö": 4, "\u0080": 5, "1": 6, "\r": 7}
        expected = '{"\\r":7,"1":6,"\u0080":5,"ö":4,"€":3,"😀":2,"דּ":1}'.encode()
        self.assertEqual(canonical_bytes(value), expected)

    def test_valid_release_enabled_g1_g5_evidence_passes_without_g6_files(self):
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_g5_rejects_a_terminal_todo20_completion_claim(self):
        evidence = make_evidence()
        source = evidence["gates"]["g5"]["artifact"]["sources"][0]
        manifest = json.loads(task_manifest_bytes(20, evidence["release_inputs"]))
        manifest["state"] = "completed"
        raw = canonical_bytes(manifest)
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g5"]["artifact"] = artifact_bundle(
            evidence["gates"]["g5"]["artifact"]["sources"]
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: raw},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("state is not g5_completed", result.stderr)

    def test_g5_rejects_an_unverified_todo20_merged_oid_claim(self):
        evidence = make_evidence()
        source = evidence["gates"]["g5"]["artifact"]["sources"][0]
        manifest = json.loads(task_manifest_bytes(20, evidence["release_inputs"]))
        manifest["repositories"][0]["merged_oid"] = evidence["release_inputs"]["ios"]["source_sha"]
        raw = canonical_bytes(manifest)
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g5"]["artifact"] = artifact_bundle(
            evidence["gates"]["g5"]["artifact"]["sources"]
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: raw},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("must not claim a merged OID", result.stderr)

    def test_g5_rejects_missing_cleanup_rollback_or_local_only_fallback_proof(self):
        evidence = make_evidence()
        source = evidence["gates"]["g5"]["artifact"]["sources"][3]
        payload = json.loads(TEST_SOURCE_BYTES["account-isolation-run"])
        del payload["cleanup_completed"]
        raw = canonical_bytes(payload)
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g5"]["account_isolation_run_sha256"] = source["sha256"]
        evidence["gates"]["g5"]["artifact"] = artifact_bundle(
            evidence["gates"]["g5"]["artifact"]["sources"]
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: raw},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("cleanup, rollback, or local-only fallback", result.stderr)

    def test_g5_rejects_tls_interception_or_unbound_endpoint_policy(self):
        evidence = make_evidence()
        source = evidence["gates"]["g5"]["artifact"]["sources"][4]
        payload = json.loads(TEST_SOURCE_BYTES["proxy-trace"])
        payload["tls_interception"] = True
        raw = canonical_bytes(payload)
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g5"]["proxy_trace_sha256"] = source["sha256"]
        evidence["gates"]["g5"]["artifact"] = artifact_bundle(
            evidence["gates"]["g5"]["artifact"]["sources"]
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: raw},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("metadata-only TLS evidence", result.stderr)

    def test_g5_requires_a_sync_service_host_in_the_proxy_evidence(self):
        evidence = make_evidence()
        source = evidence["gates"]["g5"]["artifact"]["sources"][4]
        payload = json.loads(TEST_SOURCE_BYTES["proxy-trace"])
        payload["hosts"] = ["accounts.firefox.com"]
        raw = canonical_bytes(payload)
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g5"]["proxy_trace_sha256"] = source["sha256"]
        evidence["gates"]["g5"]["artifact"] = artifact_bundle(
            evidence["gates"]["g5"]["artifact"]["sources"]
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: raw},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not prove an approved Sync host", result.stderr)

    def test_g5_rejects_duplicate_or_non_string_proxy_hosts(self):
        for hosts in (
            ["sync.services.mozilla.com", "sync.services.mozilla.com"],
            [{"host": "sync.services.mozilla.com"}],
        ):
            with self.subTest(hosts=hosts):
                evidence = make_evidence()
                source = evidence["gates"]["g5"]["artifact"]["sources"][4]
                payload = json.loads(TEST_SOURCE_BYTES["proxy-trace"])
                payload["hosts"] = hosts
                raw = canonical_bytes(payload)
                source["sha256"] = hashlib.sha256(raw).hexdigest()
                evidence["gates"]["g5"]["proxy_trace_sha256"] = source["sha256"]
                evidence["gates"]["g5"]["artifact"] = artifact_bundle(
                    evidence["gates"]["g5"]["artifact"]["sources"]
                )
                rehash(evidence)
                result = self.run_validator(
                    evidence,
                    local_artifact_overrides={source["path"]: raw},
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("proxy hosts", result.stderr)

    def test_g5_rejects_noninteractive_ci_run(self):
        evidence = make_evidence()
        source = evidence["gates"]["g5"]["artifact"]["sources"][1]
        raw = canonical_bytes(
            actions_run_payload(
                source["repository"],
                source["run_id"],
                source["workflow_path"],
                source["head_sha"],
                event="push",
                head_branch="main",
            )
        )
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g5"]["artifact"] = artifact_bundle(
            evidence["gates"]["g5"]["artifact"]["sources"]
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            remote_artifact_overrides={source_identity_key(source): raw},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("not an explicit main dispatch", result.stderr)

    def test_g5_rejects_a_passed_static_preflight_xcresult_node(self):
        evidence = make_evidence()
        source = evidence["gates"]["g5"]["artifact"]["sources"][2]
        raw = TEST_SOURCE_BYTES["static-g5-xcresult"]
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g5"]["artifact"] = artifact_bundle(
            evidence["gates"]["g5"]["artifact"]["sources"]
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            remote_artifact_overrides={source_identity_key(source): raw},
            test_xcresult_results={
                (
                    "FloorpNotesSyncEngineSelectionTests/"
                    "testG4AttestationBindsTask18Evidence()"
                ): "Passed",
                STATIC_G5_XCRESULT_TEST: "Passed",
            },
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("required XCTest did not have Passed result nodes", result.stderr)

    def test_g5_rejects_an_explicitly_empty_xcresult_result_map(self):
        result = self.run_validator(make_evidence(), test_xcresult_results={})
        self.assertEqual(result.returncode, 1)
        self.assertIn("required XCTest did not have Passed result nodes", result.stderr)

    def test_valid_production_qa_g1_g4_evidence_passes(self):
        result = self.run_validator(make_production_qa_evidence())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_xcresult_archive_accepts_artifact_contents_root(self):
        for raw in (
            contents_root_xcresult_zip(),
            synthetic_xcresult_zip(),
        ):
            with self.subTest(shape=raw[:8]):
                VALIDATOR_MODULE.validate_xcresult_archive(
                    io.BytesIO(raw),
                    "xcresult",
                )

    def test_xcresult_archive_rejects_unexpected_roots(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
            for path, raw in (
                ("Info.plist", b"x"),
                ("Data/test-summary", b"y"),
                ("Junk/extra", b"z"),
            ):
                info = zipfile.ZipInfo(path, date_time=(2026, 8, 10, 0, 0, 0))
                info.external_attr = 0o100644 << 16
                archive.writestr(info, raw)
        with self.assertRaisesRegex(
            VALIDATOR_MODULE.ValidationError,
            "root is not one xcresult",
        ):
            VALIDATOR_MODULE.validate_xcresult_archive(
                io.BytesIO(output.getvalue()),
                "xcresult",
            )

    def test_download_digest_headers_differ_for_artifact_and_release_asset(self):
        record = self.key_dir / "download-args.jsonl"
        fake_gh = self.key_dir / "fake-gh-download"
        fake_gh.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/python3
                import json, os, sys
                with open(os.environ["FAKE_GH_RECORD"], "a") as handle:
                    handle.write(json.dumps(sys.argv[1:]) + "\\n")
                """
            ),
            encoding="utf-8",
        )
        fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IXUSR)
        environment = {"FAKE_GH_RECORD": str(record)}
        VALIDATOR_MODULE.gh_api_download_digest(
            fake_gh,
            "repos/F/repos/a/actions/artifacts/1/zip",
            "artifact",
            environment,
        )
        VALIDATOR_MODULE.gh_api_download_digest(
            fake_gh,
            "repos/F/repos/a/releases/assets/1",
            "asset",
            environment,
            release_asset=True,
        )
        calls = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertNotIn("Accept: application/octet-stream", calls[0])
        self.assertIn("Accept: application/octet-stream", calls[1])

    def test_g3_rejects_completed_terminal_manifest_as_integration_receipt(self):
        evidence = make_production_qa_evidence()
        completed_manifest = task_manifest_bytes(19, evidence["release_inputs"])
        source = evidence["gates"]["g3"]["artifact"]["sources"][0]
        source["sha256"] = hashlib.sha256(completed_manifest).hexdigest()
        evidence["gates"]["g3"]["artifact"]["sha256"] = digest(
            {"sources": evidence["gates"]["g3"]["artifact"]["sources"]}
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: completed_manifest},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("integration receipt", result.stderr)

    def test_g3_rejects_non_main_non_push_ci_run(self):
        evidence = make_production_qa_evidence()
        source = evidence["gates"]["g3"]["artifact"]["sources"][1]
        raw = canonical_bytes(
            actions_run_payload(
                source["repository"],
                source["run_id"],
                source["workflow_path"],
                source["head_sha"],
                event="workflow_dispatch",
                head_branch="agent/floorp-plan-t19-production-notes-sync",
            )
        )
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g3"]["artifact"]["sha256"] = digest(
            {"sources": evidence["gates"]["g3"]["artifact"]["sources"]}
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            remote_artifact_overrides={source_identity_key(source): raw},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("main push", result.stderr)

    def test_g3_rejects_integration_receipt_command_without_argv(self):
        evidence = make_production_qa_evidence()
        receipt = json.loads(integration_receipt_bytes(evidence["release_inputs"]))
        receipt["commands"][0].pop("argv")
        raw = canonical_bytes(receipt)
        source = evidence["gates"]["g3"]["artifact"]["sources"][0]
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g3"]["artifact"]["sha256"] = digest(
            {"sources": evidence["gates"]["g3"]["artifact"]["sources"]}
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: raw},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("argv", result.stderr)

    def test_g3_rejects_boolean_integration_receipt_exit_code(self):
        evidence = make_production_qa_evidence()
        receipt = json.loads(integration_receipt_bytes(evidence["release_inputs"]))
        receipt["commands"][0]["exit_code"] = False
        raw = canonical_bytes(receipt)
        source = evidence["gates"]["g3"]["artifact"]["sources"][0]
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g3"]["artifact"]["sha256"] = digest(
            {"sources": evidence["gates"]["g3"]["artifact"]["sources"]}
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: raw},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("did not pass", result.stderr)

    def test_g3_rejects_boolean_integration_receipt_schema_version(self):
        evidence = make_production_qa_evidence()
        receipt = json.loads(integration_receipt_bytes(evidence["release_inputs"]))
        receipt["schema_version"] = True
        raw = canonical_bytes(receipt)
        source = evidence["gates"]["g3"]["artifact"]["sources"][0]
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        evidence["gates"]["g3"]["artifact"]["sha256"] = digest(
            {"sources": evidence["gates"]["g3"]["artifact"]["sources"]}
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: raw},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("schema version", result.stderr)

    def test_g4_desktop_build_number_is_bound_to_ci_run(self):
        evidence = make_production_qa_evidence()
        evidence["release_inputs"]["desktop"]["build_number"] = "999"
        evidence["gates"]["g4"]["desktop"] = copy.deepcopy(
            evidence["release_inputs"]["desktop"]
        )
        rehash(evidence)
        result = self.run_validator(evidence)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Desktop build number", result.stderr)

    def test_ios_build_number_is_bound_to_reviewed_floorp_release_config(self):
        evidence = make_production_qa_evidence()
        evidence["release_inputs"]["ios"]["build_number"] = "999"
        evidence["gates"]["g3"]["candidate"] = copy.deepcopy(
            evidence["release_inputs"]["ios"]
        )
        rehash(evidence)
        result = self.run_validator(evidence)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("FloorpRelease build number", result.stderr)

    def test_floorp_release_build_number_authority_is_exact(self):
        configuration = ROOT / "firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
        self.assertEqual(
            VALIDATOR_MODULE.load_floorp_release_build_number(configuration),
            "4",
        )
        with tempfile.TemporaryDirectory() as temporary:
            ambiguous = Path(temporary) / "FloorpRelease.xcconfig"
            ambiguous.write_text(
                "FLOORP_BUILD_NUMBER = 4\nFLOORP_BUILD_NUMBER = 5\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "not exact"):
                VALIDATOR_MODULE.load_floorp_release_build_number(ambiguous)

    def test_pinned_prerelease_immutable_release_asset_is_accepted(self):
        expected = hashlib.sha256(TEST_SOURCE_BYTES["mozilla-xcframework"]).hexdigest()
        self.assertEqual(
            self.verify_test_release_asset(prerelease=True, immutable=True),
            expected,
        )

    def test_final_release_cannot_replace_pinned_prerelease(self):
        with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "prerelease"):
            self.verify_test_release_asset(prerelease=False, immutable=True)

    def test_mutable_release_cannot_replace_pinned_immutable_release(self):
        with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "immutable"):
            self.verify_test_release_asset(prerelease=True, immutable=False)

    def test_release_asset_publication_time_must_match_live_release(self):
        with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "published"):
            self.verify_test_release_asset(
                prerelease=True,
                immutable=True,
                expected_published_at="2026-08-10T00:00:00Z",
                published_at="2026-08-08T05:41:30Z",
            )

    def test_xcresult_artifact_time_must_match_live_artifact(self):
        inputs = release_inputs()
        raw = TEST_SOURCE_BYTES["xcresult"]
        source = actions_artifact_source(
            "xcresult",
            inputs["ios"]["repository"],
            400000003,
            500000003,
            "floorp-notes-sync-xcresult",
            inputs["ios"]["source_sha"],
            raw,
        )
        run = actions_run_payload(
            source["repository"],
            source["run_id"],
            ".github/workflows/ci.yml",
            source["head_sha"],
            event="push",
            head_branch="main",
        )
        run["path"] = f".github/workflows/ci.yml@{source['head_sha']}"
        run["repository"] = {"full_name": source["repository"]}
        artifact = {
            "created_at": "2026-08-09T23:32:00Z",
            "expired": False,
            "expires_at": source["artifact_expires_at"],
            "id": source["artifact_id"],
            "name": source["artifact_name"],
            "workflow_run": {"id": source["run_id"]},
        }
        with (
            mock.patch.object(VALIDATOR_MODULE, "gh_api_json", side_effect=[run, artifact]),
            mock.patch.object(
                VALIDATOR_MODULE,
                "gh_api_download_digest",
                return_value=source["sha256"],
            ),
            self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "created time"),
        ):
            VALIDATOR_MODULE.verify_github_actions_artifact(
                source,
                Path("/usr/bin/false"),
                {},
                "g3 xcresult",
            )

    def test_g4_attestation_xcresult_requires_selected_test_marker(self):
        required_test = (
            "FloorpNotesSyncEngineSelectionTests/"
            "testG4AttestationBindsTask18Evidence()"
        )
        with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "Passed"):
            VALIDATOR_MODULE.validate_xcresult_archive(
                io.BytesIO(synthetic_xcresult_zip(b"different test")),
                "g4 attestation xcresult",
                required_test=required_test,
                test_results={},
            )

    def test_g4_attestation_marker_without_passed_result_node_is_rejected(self):
        required_test = (
            "FloorpNotesSyncEngineSelectionTests/"
            "testG4AttestationBindsTask18Evidence()"
        )
        with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "Passed"):
            VALIDATOR_MODULE.validate_xcresult_archive(
                io.BytesIO(synthetic_xcresult_zip(required_test.encode("utf-8"))),
                "g4 attestation xcresult",
                required_test=required_test,
                test_results={required_test: "Failed"},
            )

    def test_xcresulttool_semantics_extract_exact_passed_test_node(self):
        required_test = (
            "FloorpNotesSyncEngineSelectionTests/"
            "testG4AttestationBindsTask18Evidence()"
        )
        payload = {
            "testNodes": [
                {
                    "children": [
                        {
                            "name": "testG4AttestationBindsTask18Evidence()",
                            "nodeIdentifier": required_test,
                            "nodeType": "Test Case",
                            "result": "Passed",
                        }
                    ],
                    "name": "FloorpCI",
                    "nodeType": "Test Plan",
                    "result": "Passed",
                }
            ]
        }
        completed = subprocess.CompletedProcess(
            ["xcrun", "xcresulttool"],
            0,
            json.dumps(payload),
            "",
        )
        archive = io.BytesIO(synthetic_xcresult_zip(b"no raw marker required"))
        with mock.patch.object(VALIDATOR_MODULE.subprocess, "run", return_value=completed):
            results = VALIDATOR_MODULE.xcresult_test_results(
                archive,
                "FloorpNotesSync.xcresult",
                "g4 attestation xcresult",
            )
        self.assertEqual(results, {required_test: ["Passed"]})

    def test_gate_timestamps_cannot_refresh_older_ci_runs(self):
        for gate_name, days in (("g3", 7), ("g4", 30), ("g5", 7)):
            with self.subTest(gate=gate_name):
                evidence = make_evidence()
                evidence["gates"][gate_name]["issued_at"] = "2026-08-10T00:01:00Z"
                evidence["gates"][gate_name]["expires_at"] = (
                    "2026-08-17T00:01:00Z" if days == 7 else "2026-09-09T00:01:00Z"
                )
                rehash(evidence)
                result = self.run_validator(evidence)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("artifact time", result.stderr)

    def test_g3_rerun_timestamp_cannot_refresh_older_xcresult(self):
        evidence = make_production_qa_evidence()
        gate = evidence["gates"]["g3"]
        run_source = gate["artifact"]["sources"][1]
        payload = actions_run_payload(
            run_source["repository"],
            run_source["run_id"],
            run_source["workflow_path"],
            run_source["head_sha"],
            event="push",
            head_branch="main",
        )
        payload["updated_at"] = "2026-08-10T00:01:00Z"
        raw = canonical_bytes(payload)
        run_source["sha256"] = hashlib.sha256(raw).hexdigest()
        gate["issued_at"] = "2026-08-10T00:01:00Z"
        gate["expires_at"] = "2026-08-17T00:01:00Z"
        gate["artifact"]["sha256"] = digest({"sources": gate["artifact"]["sources"]})
        rehash(evidence)
        result = self.run_validator(
            evidence,
            remote_artifact_overrides={source_identity_key(run_source): raw},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("XCResult artifact time", result.stderr)

    def test_g2_gate_timestamp_cannot_refresh_older_release(self):
        evidence = make_production_qa_evidence()
        evidence["gates"]["g2"]["issued_at"] = "2026-08-10T00:01:00Z"
        evidence["gates"]["g2"]["expires_at"] = "2026-09-09T00:01:00Z"
        rehash(evidence)
        result = self.run_validator(evidence)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("artifact time", result.stderr)

    def test_g4_local_summary_requires_external_attestation(self):
        evidence = make_production_qa_evidence()
        gate = evidence["gates"]["g4"]
        source = next(
            item
            for item in gate["artifact"]["sources"]
            if item["role"] == "xpcshell-run"
        )
        raw = canonical_bytes(
            {
                "failed": 0,
                "passed": 999,
                "secrets_retained": False,
                "source_log_sha256": "e" * 64,
            }
        )
        source["sha256"] = hashlib.sha256(raw).hexdigest()
        gate["xpcshell_run_sha256"] = source["sha256"]
        gate["artifact"]["sha256"] = digest({"sources": gate["artifact"]["sources"]})
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: raw},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("attestation", result.stderr)

    def test_g4_requires_task18_execution_validator_approval(self):
        evidence = make_production_qa_evidence()
        gate = evidence["gates"]["g4"]
        gate["artifact"]["sources"] = [
            source
            for source in gate["artifact"]["sources"]
            if source["role"] != "task18-execution-verdict"
        ]
        gate["artifact"]["sha256"] = digest({"sources": gate["artifact"]["sources"]})
        rehash(evidence)
        result = self.run_validator(evidence)
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_legacy_repository_fixture_without_retrievable_artifacts_fails_closed(self):
        result = self.run_validator(
            evidence_bytes=(FIXTURES / "floorp-notes-sync-g1-g5-valid.json").read_bytes(),
            clock_bytes=(FIXTURES / "validation-clock-valid.json").read_bytes(),
        )
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_legacy_production_qa_fixture_without_retrievable_artifacts_fails_closed(self):
        result = self.run_validator(
            evidence_bytes=(FIXTURES / "floorp-notes-sync-g1-g4-production-qa-valid.json").read_bytes(),
            clock_bytes=(FIXTURES / "validation-clock-valid.json").read_bytes(),
        )
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_missing_gate_fails_closed(self):
        evidence = make_evidence()
        del evidence["gates"]["g4"]
        self.assert_rejected(evidence)

    def test_production_qa_missing_gate_fails_closed(self):
        evidence = make_production_qa_evidence()
        del evidence["gates"]["g4"]
        self.assert_rejected(evidence)

    def test_production_qa_missing_digest_fails_closed(self):
        evidence = make_production_qa_evidence()
        del evidence["g1_g4_digest_sha256"]
        self.assert_rejected(evidence)

    def test_production_qa_tampered_digest_fails_closed(self):
        evidence = make_production_qa_evidence()
        evidence["g1_g4_digest_sha256"] = "0" * 64
        self.assert_rejected(evidence)

    def test_production_qa_mixed_release_input_fails_closed(self):
        evidence = make_production_qa_evidence()
        evidence["gates"]["g3"]["candidate"]["source_sha"] = "9" * 40
        rehash(evidence)
        self.assert_rejected(evidence)

    def test_production_qa_rejects_extra_g5_gate(self):
        evidence = make_production_qa_evidence()
        evidence["gates"]["g5"] = copy.deepcopy(make_evidence()["gates"]["g5"])
        rehash(evidence)
        self.assert_rejected(evidence)

    def test_production_qa_rejects_g1_g5_digest(self):
        evidence = make_production_qa_evidence()
        evidence["g1_g5_digest_sha256"] = "0" * 64
        self.assert_rejected(evidence)

    def test_release_enabled_rejects_production_qa_gate_shape(self):
        evidence = make_production_qa_evidence()
        evidence["build_contract_mode"] = RELEASE_ENABLED_MODE
        self.assert_rejected(evidence)

    def test_unknown_build_contract_mode_fails_closed(self):
        evidence = make_evidence()
        evidence["build_contract_mode"] = "unsupported"
        self.assert_rejected(evidence)

    def test_failed_gate_is_rejected_by_independent_semantic_check(self):
        evidence = make_evidence()
        evidence["gates"]["g1"]["status"] = "failed"
        rehash(evidence)
        result = self.run_validator(evidence)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("required gate status is not passed", result.stderr)

    def test_same_id_schema_substitution_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            substituted = Path(temporary) / "schema.json"
            schema = json.loads(SCHEMA.read_bytes())
            schema["title"] = "attacker-controlled schema with the expected $id"
            substituted.write_text(json.dumps(schema), encoding="utf-8")
            result = self.run_validator(schema=substituted)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("canonical repository schema path", result.stderr)

    def test_validator_pins_the_current_repository_schema_digest(self):
        expected = hashlib.sha256(SCHEMA.read_bytes()).hexdigest()
        source = VALIDATOR.read_text(encoding="utf-8")
        self.assertIn(f'EXPECTED_SCHEMA_SHA256 = "{expected}"', source)

    def test_public_validator_uses_the_pinned_system_python_shebang(self):
        self.assertEqual(VALIDATOR.read_bytes().splitlines()[0], b"#!/usr/bin/python3 -I")

    def test_dependency_injection_is_keyword_only_and_internal(self):
        signature = inspect.signature(VALIDATOR_MODULE.main)
        parameters = list(signature.parameters.values())
        self.assertEqual(parameters[0].name, "argv")
        self.assertEqual(parameters[0].kind, inspect.Parameter.POSITIONAL_OR_KEYWORD)
        self.assertTrue(parameters[1:])
        for parameter in parameters[1:]:
            with self.subTest(parameter=parameter.name):
                self.assertEqual(parameter.kind, inspect.Parameter.KEYWORD_ONLY)
                self.assertTrue(parameter.name.startswith("test_"))
                self.assertIsNone(parameter.default)

    @unittest.skipUnless(Path("/opt/homebrew/bin/gh").is_file(), "production gh path is unavailable")
    def test_internal_test_injection_rejects_the_production_executable(self):
        with self.assertRaises(VALIDATOR_MODULE.ValidationError):
            VALIDATOR_MODULE.select_gh_executable(Path("/opt/homebrew/bin/gh"))

    @unittest.skipUnless(Path("/opt/homebrew/bin/gh").is_file(), "production gh path is unavailable")
    def test_production_gh_is_digest_pinned_and_executed_from_private_copy(self):
        production = Path("/opt/homebrew/bin/gh").resolve()
        if (
            hashlib.sha256(production.read_bytes()).hexdigest()
            != VALIDATOR_MODULE.PRODUCTION_GH_SHA256
            or production.stat().st_size != VALIDATOR_MODULE.PRODUCTION_GH_SIZE
        ):
            with self.assertRaises(VALIDATOR_MODULE.ValidationError):
                VALIDATOR_MODULE.select_gh_executable(None)
            return
        trusted = VALIDATOR_MODULE.select_gh_executable(None)

        self.assertNotEqual(trusted, production)
        self.assertEqual(
            hashlib.sha256(trusted.read_bytes()).hexdigest(),
            VALIDATOR_MODULE.PRODUCTION_GH_SHA256,
        )
        self.assertEqual(trusted.stat().st_size, VALIDATOR_MODULE.PRODUCTION_GH_SIZE)
        self.assertEqual(trusted.stat().st_mode & 0o777, 0o500)
        self.assertEqual(trusted.parent.stat().st_mode & 0o777, 0o700)

    def test_production_help_exposes_no_offline_or_response_file_bypass(self):
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), "--help"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--offline", result.stdout)
        self.assertNotIn("--api-response", result.stdout)
        self.assertNotIn("--test-gh-bin", result.stdout)

        rejected = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--schema",
                str(SCHEMA),
                "--evidence",
                str(FIXTURES / "floorp-notes-sync-g1-g5-valid.json"),
                "--validation-clock-manifest",
                str(FIXTURES / "validation-clock-valid.json"),
                "--test-gh-bin",
                str(self.mock_gh),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(rejected.returncode, 2, rejected.stderr)
        self.assertIn("unrecognized arguments", rejected.stderr)

    def test_malformed_json_is_input_error(self):
        result = self.run_validator(evidence_bytes=b'{"schema_version":1')
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_duplicate_json_key_is_input_error(self):
        raw = canonical_bytes(make_evidence())
        duplicate = b'{"schema_version":1,' + raw[1:]
        result = self.run_validator(evidence_bytes=duplicate)
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_float_is_input_error(self):
        raw = canonical_bytes(make_evidence()).replace(b'"schema_version":1', b'"schema_version":1.0')
        result = self.run_validator(evidence_bytes=raw)
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_noncanonical_evidence_fails_closed(self):
        raw = json.dumps(make_evidence(), indent=2).encode()
        result = self.run_validator(evidence_bytes=raw)
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_future_gate_fails_closed(self):
        evidence = make_evidence()
        evidence["gates"]["g3"]["issued_at"] = "2026-08-10T00:03:00Z"
        evidence["gates"]["g3"]["expires_at"] = "2026-08-17T00:03:00Z"
        rehash(evidence)
        self.assert_rejected(evidence)

    def test_expired_gate_fails_closed(self):
        evidence = make_evidence()
        evidence["gates"]["g5"]["expires_at"] = "2026-08-09T23:59:59Z"
        rehash(evidence)
        self.assert_rejected(evidence)

    def test_wrong_endpoint_fails_closed(self):
        evidence = make_evidence()
        evidence["release_inputs"]["environment"]["sync_hosts"][-1] = "sync.invalid.example"
        rehash(evidence)
        self.assert_rejected(evidence)

    def test_mixed_same_release_fails_closed(self):
        evidence = make_evidence()
        evidence["gates"]["g3"]["candidate"]["source_sha"] = "9" * 40
        rehash(evidence)
        self.assert_rejected(evidence)

    def test_tampered_combined_digest_fails_closed(self):
        evidence = make_evidence()
        evidence["g1_g5_digest_sha256"] = "0" * 64
        self.assert_rejected(evidence)

    def test_gate_artifacts_cannot_self_authenticate_with_arbitrary_uri_and_hash(self):
        evidence = make_evidence()
        for index, gate in enumerate(evidence["gates"].values(), 1):
            gate["artifact"] = {
                "sha256": f"{index:x}" * 64,
                "uri": f"https://attacker.invalid/g{index}",
            }
        rehash(evidence)
        result = self.run_validator(evidence)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("APPROVE", result.stdout)

    def test_local_xcresult_file_swap_to_symlink_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = self.make_local_xcresult(directory)
            summary = result / "Data/test-summary"
            outside = directory / "outside-secret"
            outside.write_bytes(b"must not be followed")
            real_open = os.open
            swapped = False

            def swap_before_open(path, flags, mode=0o777, *, dir_fd=None):
                nonlocal swapped
                if path == "test-summary" and dir_fd is not None and not swapped:
                    swapped = True
                    summary.unlink()
                    summary.symlink_to(outside)
                return real_open(path, flags, mode, dir_fd=dir_fd)

            with mock.patch.object(VALIDATOR_MODULE.os, "open", side_effect=swap_before_open):
                with self.assertRaises(VALIDATOR_MODULE.ValidationError):
                    VALIDATOR_MODULE.local_directory_digest(
                        directory,
                        result.name,
                        "test xcresult",
                    )
            self.assertTrue(swapped)

    def test_local_xcresult_digest_is_deterministic_for_a_stable_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = self.make_local_xcresult(directory)
            first = VALIDATOR_MODULE.local_directory_digest(directory, result.name, "test xcresult")
            second = VALIDATOR_MODULE.local_directory_digest(directory, result.name, "test xcresult")
            self.assertEqual(first, second)
            (result / "Data/test-summary").write_bytes(b"new synthetic-only metadata")
            changed = VALIDATOR_MODULE.local_directory_digest(directory, result.name, "test xcresult")
            self.assertNotEqual(first, changed)

    def test_local_xcresult_directory_identity_swap_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = self.make_local_xcresult(directory)
            data = result / "Data"
            original = result / "Data-original"
            real_open = os.open
            swapped = False

            def swap_before_open(path, flags, mode=0o777, *, dir_fd=None):
                nonlocal swapped
                if path == "Data" and dir_fd is not None and not swapped:
                    swapped = True
                    data.rename(original)
                    data.mkdir()
                    (data / "replacement").write_bytes(b"replacement tree")
                return real_open(path, flags, mode, dir_fd=dir_fd)

            with mock.patch.object(VALIDATOR_MODULE.os, "open", side_effect=swap_before_open):
                with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "identity changed"):
                    VALIDATOR_MODULE.local_directory_digest(
                        directory,
                        result.name,
                        "test xcresult",
                    )
            self.assertTrue(swapped)

    def test_local_xcresult_enforces_global_entry_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = self.make_local_xcresult(directory)
            with mock.patch.object(VALIDATOR_MODULE, "MAX_XCRESULT_ENTRIES", 2, create=True):
                with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "entry count"):
                    VALIDATOR_MODULE.local_directory_digest(directory, result.name, "test xcresult")

    def test_local_xcresult_enforces_global_size_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = self.make_local_xcresult(directory)
            with mock.patch.object(VALIDATOR_MODULE, "MAX_XCRESULT_BYTES", 8, create=True):
                with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "too large"):
                    VALIDATOR_MODULE.local_directory_digest(directory, result.name, "test xcresult")

    def test_local_xcresult_scans_secrets_after_old_cutoff_and_across_chunks(self):
        for prefix_size in (4 * 1024 * 1024 + 17, 1024 * 1024 - 5):
            with self.subTest(prefix_size=prefix_size):
                with tempfile.TemporaryDirectory() as temporary:
                    directory = Path(temporary)
                    result = self.make_local_xcresult(directory)
                    (result / "Data/test-summary").write_bytes(
                        b"x" * prefix_size + b"access_token"
                    )
                    with self.assertRaisesRegex(
                        VALIDATOR_MODULE.ValidationError,
                        "forbidden secret metadata",
                    ):
                        VALIDATOR_MODULE.local_directory_digest(
                            directory,
                            result.name,
                            "test xcresult",
                        )

    def test_remote_xcresult_scans_secrets_after_old_cutoff_and_across_chunks(self):
        for prefix_size in (4 * 1024 * 1024 + 17, 1024 * 1024 - 5):
            with self.subTest(prefix_size=prefix_size):
                archive = synthetic_xcresult_zip(
                    b"x" * prefix_size + b"access_token"
                )
                with self.assertRaisesRegex(
                    VALIDATOR_MODULE.ValidationError,
                    "secret metadata",
                ):
                    VALIDATOR_MODULE.validate_xcresult_archive(
                        io.BytesIO(archive),
                        "remote xcresult",
                    )

    def test_remote_xcresult_accepts_clean_multichunk_member(self):
        archive = synthetic_xcresult_zip(b"x" * (4 * 1024 * 1024 + 17))

        VALIDATOR_MODULE.validate_xcresult_archive(
            io.BytesIO(archive),
            "remote xcresult",
        )

    def test_remote_xcresult_enforces_uncompressed_size_bound(self):
        archive = synthetic_xcresult_zip(b"x" * 128)

        with mock.patch.object(VALIDATOR_MODULE, "MAX_XCRESULT_BYTES", 64):
            with self.assertRaisesRegex(
                VALIDATOR_MODULE.ValidationError,
                "too large|member size is invalid",
            ):
                VALIDATOR_MODULE.validate_xcresult_archive(
                    io.BytesIO(archive),
                    "remote xcresult",
                )

    def test_remote_artifact_digest_is_recomputed_from_retrieved_bytes(self):
        evidence = make_evidence()
        source = evidence["gates"]["g1"]["artifact"]["sources"][2]
        source["sha256"] = "a" * 64
        evidence["gates"]["g1"]["artifact"]["sha256"] = digest(
            {"sources": evidence["gates"]["g1"]["artifact"]["sources"]}
        )
        rehash(evidence)
        result = self.run_validator(evidence)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("artifact bytes do not match SHA-256", result.stderr)

    def test_task_manifest_bytes_are_rehashed_and_semantically_bound_to_the_gate(self):
        evidence = make_evidence()
        malicious = canonical_bytes(
            {
                "commands": [{"argv": ["true"], "exit_code": 0, "terminal": True}],
                "repositories": [
                    {
                        "base_oid": "c23319ffbb710d0ae167608fcad4615fd99a028c",
                        "head_oid": "d90f320ae0d3225382d75dbab94daaf8d38733fd",
                        "merged_oid": "18841c0c43d0eda428e1c88170769c1539543848",
                        "name": "Floorp",
                    }
                ],
                "schema_version": 1,
                "state": "completed",
                "task_id": 99,
            }
        )
        source = evidence["gates"]["g1"]["artifact"]["sources"][0]
        source["sha256"] = hashlib.sha256(malicious).hexdigest()
        evidence["gates"]["g1"]["artifact"]["sha256"] = digest(
            {"sources": evidence["gates"]["g1"]["artifact"]["sources"]}
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: malicious},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("wrong task ID", result.stderr)

    def test_network_evidence_rejects_authorization_and_content_fields(self):
        evidence = make_evidence()
        malicious = canonical_bytes(
            {
                "authorization_header": "Bearer should-never-be-evidence",
                "hosts": ["sync.services.mozilla.com"],
                "request_body": {"note_title": "private"},
            }
        )
        source = evidence["gates"]["g5"]["artifact"]["sources"][4]
        source["sha256"] = hashlib.sha256(malicious).hexdigest()
        evidence["gates"]["g5"]["proxy_trace_sha256"] = source["sha256"]
        evidence["gates"]["g5"]["artifact"]["sha256"] = digest(
            {"sources": evidence["gates"]["g5"]["artifact"]["sources"]}
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            local_artifact_overrides={source["path"]: malicious},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("forbidden secret/content field", result.stderr)

    def test_tampered_bound_fixture_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary) / "fixture.json"
            fixture.write_text('{"requiredCaseNames":[]}', encoding="utf-8")
            result = self.run_validator(extra=["--fixture", str(fixture)])
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_tampered_endpoint_policy_source_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            policy = Path(temporary) / "endpoints.json"
            policy.write_text('{"endpoints":[]}', encoding="utf-8")
            result = self.run_validator(extra=["--endpoint-policy", str(policy)])
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_stale_clock_fails_closed(self):
        clock = make_clock()
        clock["run"]["updated_at"] = "2026-08-09T23:50:00Z"
        self.assert_rejected(make_evidence(), clock)

    def test_stale_captured_http_date_fails_closed_against_live_date(self):
        clock = make_clock()
        clock["github_http_date"] = "Sun, 09 Aug 2026 23:50:00 GMT"
        self.assert_rejected(make_evidence(), clock)

    def test_forged_future_captured_http_date_fails_closed_against_live_date(self):
        clock = make_clock()
        clock["github_http_date"] = "Mon, 10 Aug 2026 00:10:00 GMT"
        self.assert_rejected(make_evidence(), clock)

    def test_stale_live_github_date_fails_closed(self):
        result = self.run_validator(gh_scenario="stale_live_date")
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_github_api_calls_force_the_public_github_hostname(self):
        result = self.run_validator(gh_scenario="require_hostname")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_github_host_and_proxy_redirection_environment_fails_closed(self):
        unsafe_names = (
            "GH_HOST",
            "GH_HTTP_UNIX_SOCKET",
            "GH_CONFIG_DIR",
            "GITHUB_API_URL",
            "GITHUB_SERVER_URL",
            "HTTPS_PROXY",
            "SSL_CERT_FILE",
            "GIT_SSL_NO_VERIFY",
            "GIT_SSL_CAPATH",
            "NODE_EXTRA_CA_CERTS",
            "gh_host",
            "gh_http_unix_socket",
            "gh_config_dir",
            "github_api_url",
            "github_server_url",
            "git_ssl_no_verify",
            "git_ssl_capath",
            "node_extra_ca_certs",
        )
        for name in unsafe_names:
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: "attacker.invalid"}):
                with self.assertRaisesRegex(VALIDATOR_MODULE.ValidationError, "redirect environment"):
                    VALIDATOR_MODULE.trusted_gh_environment()

    def test_changed_live_run_fails_closed(self):
        result = self.run_validator(gh_scenario="changed_run")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("live GitHub run updated_at differs", result.stderr)

    def test_wrong_live_jobs_fail_closed(self):
        result = self.run_validator(gh_scenario="wrong_jobs")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("live GitHub jobs differ", result.stderr)

    def test_github_api_failure_fails_closed_without_leaking_diagnostics(self):
        result = self.run_validator(gh_scenario="api_failure")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("trusted GitHub API run request failed", result.stderr)
        self.assertNotIn("Authorization", result.stderr)
        self.assertNotIn("should-never-be-reported", result.stderr)

    def test_wrong_workflow_fails_closed(self):
        clock = make_clock()
        wrong = ".github/workflows/not-the-clock.yml"
        clock["workflow"]["path"] = wrong
        clock["run"]["workflow_path"] = wrong
        self.assert_rejected(make_evidence(), clock)

    def test_workflow_id_can_be_pinned_independently(self):
        valid = self.run_validator(extra=["--expected-workflow-id", "123456789"])
        wrong = self.run_validator(extra=["--expected-workflow-id", "987654321"])
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(wrong.returncode, 1, wrong.stderr)

    def test_wrong_head_fails_closed(self):
        clock = make_clock()
        clock["expected_head_sha"] = "8" * 40
        clock["run"]["head_sha"] = "8" * 40
        self.assert_rejected(make_evidence(), clock)

    def test_nonterminal_or_failed_job_fails_closed(self):
        clock = make_clock()
        clock["jobs"][0]["status"] = "completed"
        clock["jobs"][0]["conclusion"] = "failure"
        self.assert_rejected(make_evidence(), clock)

    def test_run_attempt_drift_fails_closed(self):
        clock = make_clock()
        clock["jobs"][0]["run_attempt"] = 2
        self.assert_rejected(make_evidence(), clock)

    def test_wrong_clock_repository_fails_closed(self):
        clock = make_clock()
        clock["repository"] = "attacker/example"
        self.assert_rejected(make_evidence(), clock)

    def test_wrong_clock_event_fails_closed(self):
        clock = make_clock()
        clock["run"]["event"] = "push"
        self.assert_rejected(make_evidence(), clock)

    def test_clock_more_than_five_minutes_in_future_fails_closed(self):
        clock = make_clock()
        clock["run"]["updated_at"] = "2026-08-10T00:08:00Z"
        self.assert_rejected(make_evidence(), clock)

    def test_malformed_github_http_date_fails_closed(self):
        clock = make_clock()
        clock["github_http_date"] = "not-a-provider-date"
        self.assert_rejected(make_evidence(), clock)

    def test_inconsistent_github_http_date_weekday_fails_closed(self):
        clock = make_clock()
        clock["github_http_date"] = "Tue, 10 Aug 2026 00:02:00 GMT"
        self.assert_rejected(make_evidence(), clock)

    def test_noncanonical_clock_fails_closed(self):
        result = self.run_validator(clock_bytes=json.dumps(make_clock(), indent=2).encode())
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_require_g6_rejects_capability_only_evidence(self):
        result = self.run_validator(extra=["--require-g6"])
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_public_cli_rejects_g6_trust_anchor_and_ssh_keygen_overrides(self):
        result = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--help",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for option in ("--allowed-signers", "--revocations", "--signer-registry", "--ssh-keygen"):
            self.assertNotIn(option, result.stdout)

    def test_g6_trust_is_pinned_to_todo16_merged_paths_and_digests(self):
        self.assertEqual(
            VALIDATOR_MODULE.TODO16_MERGED_SHA,
            "18841c0c43d0eda428e1c88170769c1539543848",
        )
        self.assertEqual(
            VALIDATOR_MODULE.TODO16_TRUST_FILES,
            {
                "allowed_signers": {
                    "path": "docs/development/floorp-notes-sync/allowed-signers",
                    "blob_sha": "5abaca8c221feabe792f9bb3ffb65464809bb0f2",
                    "sha256": "4acf23f23f9a0c2c449f25df6c7bfd84a9b3ee38953455cf8858711cfd78447e",
                },
                "revocations": {
                    "path": "docs/development/floorp-notes-sync/revocations.json",
                    "blob_sha": "06274ee5aa9e91f2514bab282b0f6155c75ea62e",
                    "sha256": "79f69d733eceb6484f67d6cf7969d01c68b52a245e8b3d72c65d1eb8b40bc3c4",
                },
                "signer_registry": {
                    "path": "docs/development/floorp-notes-sync/prerequisites.json",
                    "blob_sha": "43d6826903d49b65d71c593a6e4759eaf32d02a2",
                    "sha256": "e8c99a574d1171f2ae8df55782e69bcfa0d517938aea0152ca11d587df33d6ba",
                },
            },
        )

    @unittest.skipUnless(SSH_KEYGEN.is_file(), "ssh-keygen is required for G6 tests")
    def test_valid_g6_signatures_pass(self):
        evidence, trust_bundle = self.make_g6_evidence()
        result = self.run_validator(
            evidence,
            extra=["--require-g6"],
            g6_trust_bundle=trust_bundle,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(SSH_KEYGEN.is_file(), "ssh-keygen is required for G6 tests")
    def test_bad_g6_signature_fails_closed(self):
        evidence, trust_bundle = self.make_g6_evidence()
        signature = evidence["gates"]["g6"]["approvals"][0]["signature"]
        lines = signature.splitlines(keepends=True)
        body_index = next(
            index
            for index, line in enumerate(lines)
            if not line.startswith("-----") and line.strip()
        )
        replacement = "A" if lines[body_index][0] != "A" else "B"
        lines[body_index] = replacement + lines[body_index][1:]
        evidence["gates"]["g6"]["approvals"][0]["signature"] = "".join(lines)
        evidence["gates"]["g6"]["artifact"]["sha256"] = digest(
            {"approvals": evidence["gates"]["g6"]["approvals"]}
        )
        rehash(evidence)
        result = self.run_validator(
            evidence,
            g6_trust_bundle=trust_bundle,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("bad detached signature", result.stderr)

    @unittest.skipUnless(SSH_KEYGEN.is_file(), "ssh-keygen is required for G6 tests")
    def test_revoked_g6_key_fails_closed(self):
        evidence, trust_bundle = self.make_g6_evidence()
        revoked = {
            "revocations": [
                {
                    "identifier": self.signers[0]["fingerprint"],
                    "kind": "key",
                    "reason": "test revocation",
                    "revoked_at": "2026-08-09T12:00:00Z",
                }
            ],
            "schema_version": 1,
        }
        trust_bundle["revocations"] = canonical_bytes(revoked)
        result = self.run_validator(
            evidence,
            g6_trust_bundle=trust_bundle,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("signer key is revoked", result.stderr)

    @unittest.skipUnless(SSH_KEYGEN.is_file(), "ssh-keygen is required for G6 tests")
    def test_untrusted_g6_key_fails_closed(self):
        evidence, trust_bundle = self.make_g6_evidence()
        retained_lines = trust_bundle["allowed_signers"].decode("utf-8").splitlines()[1:]
        trust_bundle["allowed_signers"] = ("\n".join(retained_lines) + "\n").encode("utf-8")
        result = self.run_validator(
            evidence,
            g6_trust_bundle=trust_bundle,
        )
        self.assertEqual(result.returncode, 1, result.stderr)

    @unittest.skipUnless(SSH_KEYGEN.is_file(), "ssh-keygen is required for G6 tests")
    def test_g6_role_identity_must_match_todo16_registry(self):
        evidence, trust_bundle = self.make_g6_evidence()
        registry = json.loads(trust_bundle["signer_registry"])
        registry["role_registry"][1]["login"] = self.signers[0]["login"]
        trust_bundle["signer_registry"] = canonical_bytes(registry)
        result = self.run_validator(
            evidence,
            g6_trust_bundle=trust_bundle,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("login does not match the Todo 16 registry", result.stderr)

    @unittest.skipUnless(SSH_KEYGEN.is_file(), "ssh-keygen is required for G6 tests")
    def test_revoked_g6_approval_fails_closed(self):
        evidence, trust_bundle = self.make_g6_evidence()
        approval_digest = digest(evidence["gates"]["g6"]["approvals"][0])
        revoked = {
            "revocations": [
                {
                    "identifier": approval_digest,
                    "kind": "approval",
                    "reason": "test approval revocation",
                    "revoked_at": "2026-08-09T12:00:00Z",
                }
            ],
            "schema_version": 1,
        }
        trust_bundle["revocations"] = canonical_bytes(revoked)
        result = self.run_validator(
            evidence,
            g6_trust_bundle=trust_bundle,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("approval is revoked", result.stderr)

    @unittest.skipUnless(SSH_KEYGEN.is_file(), "ssh-keygen is required for G6 tests")
    def test_future_g6_approval_fails_closed(self):
        evidence, trust_bundle = self.make_g6_evidence(
            issued_at="2026-08-10T00:03:00Z",
            expires_at="2026-11-08T00:03:00Z",
        )
        result = self.run_validator(
            evidence,
            g6_trust_bundle=trust_bundle,
        )
        self.assertEqual(result.returncode, 1, result.stderr)

    @unittest.skipUnless(SSH_KEYGEN.is_file(), "ssh-keygen is required for G6 tests")
    def test_expired_g6_approval_fails_closed(self):
        evidence, trust_bundle = self.make_g6_evidence(
            issued_at="2026-05-01T00:00:00Z",
            expires_at="2026-07-30T00:00:00Z",
        )
        result = self.run_validator(
            evidence,
            g6_trust_bundle=trust_bundle,
        )
        self.assertEqual(result.returncode, 1, result.stderr)

    def make_g6_evidence(
        self,
        *,
        issued_at: str = "2026-08-09T12:00:00Z",
        expires_at: str = "2026-11-07T12:00:00Z",
    ) -> tuple[dict[str, object], dict[str, bytes]]:
        evidence = make_evidence()
        approvals = []
        allowed_lines = []
        for signer in self.signers:
            payload = {
                "expires_at": expires_at,
                "g1_g5_digest_sha256": evidence["g1_g5_digest_sha256"],
                "github_login": signer["login"],
                "issued_at": issued_at,
                "key_fingerprint": signer["fingerprint"],
                "release_inputs": evidence["release_inputs"],
                "role": signer["role"],
            }
            signature = subprocess.run(
                [
                    str(SSH_KEYGEN),
                    "-Y",
                    "sign",
                    "-f",
                    str(signer["private_key"]),
                    "-n",
                    NAMESPACE,
                ],
                input=canonical_bytes(payload),
                check=True,
                capture_output=True,
            ).stdout.decode("ascii")
            approvals.append({"payload": payload, "signature": signature})
            allowed_lines.append(
                f'{signer["login"]} {signer["key_type"]} {signer["key_value"]}'
            )
        trust_bundle = {
            "allowed_signers": ("\n".join(allowed_lines) + "\n").encode("utf-8"),
            "revocations": canonical_bytes({"revocations": [], "schema_version": 1}),
            "signer_registry": canonical_bytes(
                {
                    "role_registry": [
                        {
                            "key_fingerprint": signer["fingerprint"],
                            "login": signer["login"],
                            "role": signer["role"],
                        }
                        for signer in self.signers
                    ],
                    "schema_version": 1,
                }
            ),
        }
        evidence["gates"]["g6"] = {
            "approvals": approvals,
            "artifact": {"sha256": digest({"approvals": approvals})},
            "expires_at": expires_at,
            "issued_at": issued_at,
            "status": "passed",
        }
        rehash(evidence)
        return evidence, trust_bundle


if __name__ == "__main__":
    unittest.main()
