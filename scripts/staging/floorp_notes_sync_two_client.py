#!/usr/bin/env python3
"""Fail-closed, non-executing static-input preflight for Todo 20 evidence.

This tool only verifies that local inputs form one canonical G1-G4 release
record.  It does not retrieve artifacts, establish a trusted clock, start a
client, access Firefox Accounts or Sync, or authorize G5 execution.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any, Iterable


SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
RELEASE_TAG = re.compile(r"floorp-ios-[0-9]+\.[0-9]{14}\.[1-9][0-9]*\Z")
MAX_INPUT_BYTES = 4 * 1024 * 1024
IOS_REPOSITORY = "Floorp-Projects/floorp-ios"
DESKTOP_REPOSITORY = "Floorp-Projects/Floorp"
RUNTIME_REPOSITORY = "Floorp-Projects/Floorp-Runtime"
AS_REPOSITORY = "Floorp-Projects/application-services"
ENGINE_AUTHORITY_COMMIT = "d588863894e9b3ce58b05a964a7694ab00e28054"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RELEASE_VALIDATOR_PATH = REPOSITORY_ROOT / "scripts" / "ci" / "validate-floorp-notes-sync-release.py"
RELEASE_SCHEMA_PATH = REPOSITORY_ROOT / "docs" / "floorp-notes-sync-release-evidence.schema.json"
REQUIRED_FIXTURE_CASES = (
    "concurrent-edits-preserve-deterministic-loser",
    "equal-timestamp-has-commutative-bytewise-winner",
    "first-sync-same-id-preserves-both-versions",
    "one-sided-remote-reorder-wins",
    "one-sided-deletion-wins",
    "delete-versus-edit-keeps-edit-in-both-directions",
    "concurrent-reorder-prefers-local-and-appends-remote-new",
    "conflict-probe-skips-unrelated-collision",
    "conflict-candidate-conflict-winner-is-reused",
    "rich-unknown-content-is-byte-preserved",
    "uploaded-then-local-commit-failure-retry-is-idempotent",
    "duplicate-local-id-fails-closed",
)
AS_ASSET_NAMES = {
    "focus_xcframework_sha256": "FocusRustComponents.xcframework.zip",
    "mozilla_xcframework_sha256": "MozillaRustComponents.xcframework.zip",
    "release_manifest_sha256": "release-manifest.json",
    "sha256sums_sha256": "SHA256SUMS",
    "swift_components_sha256": "swift-components.tar.xz",
}
AS_HANDOFF_KEYS = (
    "assets",
    "branch",
    "contract_symbols",
    "engine_authority_commit",
    "engine_component",
    "merged_commit",
    "merged_tree",
    "publication_status",
    "publication_verification",
    "release_state",
    "release_tag",
    "release_url",
    "repository",
    "schema_version",
    "todo",
    "upstream",
    "workflow_url",
)
AS_UPSTREAM_KEYS = (
    "actual_merge_base",
    "artifact_version",
    "commit",
    "repository",
    "source_version",
)
FIXTURE_KEYS = (
    "canonicalConflictIdentity",
    "contractVersion",
    "errorCases",
    "fixtureSchemaVersion",
    "mergeCases",
    "productionDesktopObservation",
    "requiredCaseNames",
    "sequenceCases",
    "wirePayloadVersion",
)
ENDPOINT_MATRIX_KEYS = ("endpoints", "note", "schema_version")
ENDPOINT_KEYS = ("host", "owner", "purpose", "service", "status")
SENSITIVE_FIELD_NAMES = frozenset(
    {
        "access_token",
        "authorization",
        "authorization_header",
        "client_secret",
        "cookie",
        "cookie_header",
        "credential",
        "credentials",
        "key",
        "note_content",
        "note_title",
        "notes_content",
        "notes_payload",
        "notes_title",
        "oauth_token",
        "password",
        "private_key",
        "raw_sync_key",
        "refresh_token",
        "request_body",
        "response_body",
        "secret",
        "session",
        "set_cookie_header",
        "sync_key",
        "token",
        "trust_anchor",
    }
)
SENSITIVE_VALUE_MARKERS = (
    "authorization: bearer",
    "begin private key",
    "bearer ",
    "oauth_token",
)
class PreflightError(Exception):
    """A local input does not satisfy the non-executing preflight contract."""


def reject(message: str) -> None:
    raise PreflightError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        reject(message)


def load_release_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "floorp_notes_sync_release_validator_for_preflight",
        RELEASE_VALIDATOR_PATH,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load the repository release-evidence validator")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


RELEASE_VALIDATOR = load_release_validator()


def require_exact_keys(value: Any, expected: Iterable[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    require(set(value) == set(expected), f"{label} fields are not exact")
    return value


def require_fields(value: Any, expected: Iterable[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    missing = sorted(set(expected) - set(value))
    require(not missing, f"{label} is missing required fields: {', '.join(missing)}")
    return value


def require_sha1(value: Any, label: str) -> str:
    require(isinstance(value, str) and SHA1.fullmatch(value) is not None, f"{label} must be a lowercase SHA-1")
    return value


def require_sha256(value: Any, label: str) -> str:
    require(isinstance(value, str) and SHA256.fullmatch(value) is not None, f"{label} must be a lowercase SHA-256")
    return value


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be a nonempty string")
    return value


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def regular_json(
    raw_path: str,
    label: str,
    *,
    require_canonical: bool = False,
) -> tuple[Path, dict[str, Any], bytes]:
    path = Path(raw_path)
    try:
        metadata = path.lstat()
    except OSError as error:
        reject(f"{label} is unavailable ({error})")
    require(not stat.S_ISLNK(metadata.st_mode), f"{label} must be a regular non-symlink file")
    require(stat.S_ISREG(metadata.st_mode), f"{label} must be a regular file")
    require(metadata.st_size <= MAX_INPUT_BYTES, f"{label} exceeds the input size limit")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        reject(f"{label} cannot be opened safely ({error})")
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode), f"{label} must be a regular file")
        chunks: list[bytes] = []
        remaining = MAX_INPUT_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        require(len(raw) <= MAX_INPUT_BYTES, f"{label} exceeds the input size limit")
        after = os.fstat(descriptor)
        require(
            (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            == (after.st_dev, after.st_ino, after.st_mode, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
            f"{label} changed while being read",
        )
    finally:
        os.close(descriptor)
    try:
        value = RELEASE_VALIDATOR.parse_json_bytes(raw, require_canonical=require_canonical, label=label)
    except RELEASE_VALIDATOR.ValidationError as error:
        reject(str(error))
    require(isinstance(value, dict), f"{label} root must be an object")
    return path.resolve(), value, raw


def sensitive_field(name: str) -> bool:
    normalized = re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower().replace("-", "_")
    parts = tuple(part for part in normalized.split("_") if part)
    return (
        normalized in SENSITIVE_FIELD_NAMES
        or normalized.endswith(("_content", "_key", "_session", "_title", "_token"))
        or any(part in {"cookie", "credential", "key", "secret", "session", "token"} for part in parts)
        or normalized in {"note_content", "note_payload", "note_title", "notes_content", "notes_payload", "notes_title"}
    )


def assert_no_sensitive_values(
    value: Any,
    label: str,
    *,
    allowed_field_paths: frozenset[tuple[str, ...]] = frozenset(),
    path: tuple[str, ...] = (),
) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            require(isinstance(key, str), f"{label} has a non-string field")
            child_path = (*path, key)
            if sensitive_field(key) and child_path not in allowed_field_paths:
                reject(f"{label} contains a sensitive field")
            assert_no_sensitive_values(
                child,
                label,
                allowed_field_paths=allowed_field_paths,
                path=child_path,
            )
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_no_sensitive_values(
                child,
                label,
                allowed_field_paths=allowed_field_paths,
                path=(*path, str(index)),
            )
    elif isinstance(value, str):
        normalized = value.lower()
        if any(marker in normalized for marker in SENSITIVE_VALUE_MARKERS):
            reject(f"{label} contains a sensitive value")


def validate_fixture(fixture: dict[str, Any], raw: bytes) -> tuple[str, str]:
    fixture_digest = sha256(raw)
    require(
        fixture_digest == RELEASE_VALIDATOR.EXPECTED_FIXTURE_SHA256,
        "fixture SHA does not match the approved shared fixture",
    )
    require_exact_keys(fixture, FIXTURE_KEYS, "fixture")
    require(fixture["fixtureSchemaVersion"] == 2, "fixture schema version is not 2")
    require(fixture["contractVersion"] == "floorp-notes-merge-v1", "fixture contract version is not floorp-notes-merge-v1")
    require(fixture["wirePayloadVersion"] == 1, "fixture wire payload version is not 1")
    require(fixture["requiredCaseNames"] == list(REQUIRED_FIXTURE_CASES), "fixture required case set is not exact")
    for key in ("canonicalConflictIdentity", "productionDesktopObservation"):
        require(isinstance(fixture[key], dict), f"fixture {key} must be an object")
    for key in ("errorCases", "mergeCases", "sequenceCases"):
        require(isinstance(fixture[key], list), f"fixture {key} must be an array")
    case_set_digest = RELEASE_VALIDATOR.digest(fixture["requiredCaseNames"])
    require(
        case_set_digest == RELEASE_VALIDATOR.EXPECTED_CASE_SET_SHA256,
        "fixture required case-set digest does not match the approved shared fixture",
    )
    return fixture_digest, case_set_digest


def validate_endpoint_matrix(matrix: dict[str, Any], raw: bytes) -> tuple[str, list[str]]:
    matrix_digest = sha256(raw)
    require(
        matrix_digest == RELEASE_VALIDATOR.EXPECTED_ENDPOINT_POLICY_SHA256,
        "endpoint matrix SHA does not match the approved endpoint policy",
    )
    require_exact_keys(matrix, ENDPOINT_MATRIX_KEYS, "endpoint matrix")
    require(matrix["schema_version"] == 1, "endpoint matrix schema version is not 1")
    require_string(matrix["note"], "endpoint matrix note")
    endpoints = matrix["endpoints"]
    require(isinstance(endpoints, list) and endpoints, "endpoint matrix endpoints must be nonempty")
    services: dict[str, str] = {}
    for index, item in enumerate(endpoints):
        entry = require_exact_keys(item, ENDPOINT_KEYS, f"endpoint matrix entry {index}")
        host = require_string(entry["host"], f"endpoint matrix entry {index} host")
        service = require_string(entry["service"], f"endpoint matrix entry {index} service")
        status = require_string(entry["status"], f"endpoint matrix entry {index} status")
        require_string(entry["owner"], f"endpoint matrix entry {index} owner")
        require_string(entry["purpose"], f"endpoint matrix entry {index} purpose")
        if status == "enabled" and service in {"fxa", "sync"}:
            require(host not in services, "endpoint matrix has duplicate enabled production host")
            services[host] = service
    expected = {host: "fxa" for host in RELEASE_VALIDATOR.EXPECTED_FXA_HOSTS}
    expected.update({host: "sync" for host in RELEASE_VALIDATOR.EXPECTED_SYNC_HOSTS})
    for host, service in expected.items():
        require(services.get(host) == service, f"endpoint matrix has no enabled {service} host {host}")
    return matrix_digest, sorted(expected)


def validate_as_handoff(handoff: dict[str, Any]) -> dict[str, Any]:
    require_exact_keys(handoff, AS_HANDOFF_KEYS, "AS handoff")
    require(handoff["schema_version"] == 1, "AS handoff schema version is not 1")
    require(handoff["todo"] == 17, "AS handoff task is not Todo 17")
    require(handoff["repository"] == AS_REPOSITORY, f"AS handoff repository is not {AS_REPOSITORY}")
    require(handoff["branch"] == "floorp-ios", "AS handoff branch is not floorp-ios")
    require(handoff["engine_authority_commit"] == ENGINE_AUTHORITY_COMMIT, "AS handoff engine authority commit is not approved")
    require(handoff["engine_component"] == "components/floorp-prefs-sync", "AS handoff engine component is not approved")
    require(handoff["contract_symbols"] == ["get_registered_sync_engine"], "AS handoff contract symbols are not exact")
    require(handoff["publication_status"] == "published", "AS handoff publication status is not published")
    require(handoff["release_state"] == "published_prerelease", "AS handoff release state is not immutable prerelease")
    release_tag = require_string(handoff["release_tag"], "AS handoff release tag")
    require(RELEASE_TAG.fullmatch(release_tag) is not None, "AS handoff release tag is malformed")
    source_sha = require_sha1(handoff["merged_commit"], "AS handoff merged commit")
    tree_sha = require_sha1(handoff["merged_tree"], "AS handoff merged tree")
    assets = require_exact_keys(handoff["assets"], AS_ASSET_NAMES.values(), "AS handoff assets")
    canonical_artifacts: dict[str, str] = {}
    for canonical_name, asset_name in AS_ASSET_NAMES.items():
        canonical_artifacts[canonical_name] = require_sha256(
            assets[asset_name],
            f"AS handoff asset {asset_name}",
        )
    upstream = require_exact_keys(handoff["upstream"], AS_UPSTREAM_KEYS, "AS handoff upstream")
    require_sha1(upstream["actual_merge_base"], "AS handoff upstream merge base")
    require_string(upstream["artifact_version"], "AS handoff upstream artifact version")
    require_sha1(upstream["commit"], "AS handoff upstream commit")
    require(upstream["repository"] == "mozilla/application-services", "AS handoff upstream repository is incorrect")
    require_string(upstream["source_version"], "AS handoff upstream source version")
    return {
        "artifacts": canonical_artifacts,
        "release_tag": release_tag,
        "repository": AS_REPOSITORY,
        "source_sha": source_sha,
        "tree_sha": tree_sha,
    }


def validate_static_evidence(
    evidence: dict[str, Any],
    fixture_digest: str,
    case_set_digest: str,
    matrix_digest: str,
    as_input: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], str]:
    try:
        schema = RELEASE_VALIDATOR.load_pinned_schema(REPOSITORY_ROOT, RELEASE_SCHEMA_PATH)
        RELEASE_VALIDATOR.validate_schema_instance(
            evidence,
            {"$ref": "#/$defs/productionQaEvidence"},
            schema,
        )
        RELEASE_VALIDATOR.validate_mode_gate_semantics(evidence, False)
    except RELEASE_VALIDATOR.ValidationError as error:
        reject(f"G1-G4 evidence schema validation failed: {error}")

    inputs = evidence["release_inputs"]
    gates = evidence["gates"]
    required_gate_names = ("g1", "g2", "g3", "g4")
    for name in required_gate_names:
        gate = gates[name]
        artifact = gate["artifact"]
        sources = artifact["sources"]
        require(
            tuple(source["role"] for source in sources) == RELEASE_VALIDATOR.GATE_SOURCE_ROLES[name],
            f"{name} artifact source roles are not exact",
        )
        require(
            artifact["sha256"] == RELEASE_VALIDATOR.digest({"sources": sources}),
            f"{name} artifact bundle digest does not match its source descriptors",
        )

    contract = inputs["contract"]
    require(contract["fixture_sha256"] == fixture_digest, "G1-G4 fixture SHA does not match fixture")
    require(contract["case_set_sha256"] == case_set_digest, "G1-G4 case-set SHA does not match fixture")
    require(contract["endpoint_policy_sha256"] == matrix_digest, "G1-G4 endpoint SHA does not match endpoint matrix")
    require(inputs["application_services"] == as_input, "G1-G4 Application Services input does not match AS handoff")
    environment = inputs["environment"]
    require(environment["fxa_configuration"] == "FxAConfig.Server.release", "G1-G4 FxA configuration is not release")
    require(tuple(environment["fxa_hosts"]) == RELEASE_VALIDATOR.EXPECTED_FXA_HOSTS, "G1-G4 FxA host policy is not exact")
    require(tuple(environment["sync_hosts"]) == RELEASE_VALIDATOR.EXPECTED_SYNC_HOSTS, "G1-G4 Sync host policy is not exact")
    require(environment["wire_protocol"] == "sync15", "G1-G4 Sync protocol is not sync15")

    ios = inputs["ios"]
    desktop = inputs["desktop"]
    runtime = inputs["runtime"]
    require(ios["repository"] == IOS_REPOSITORY, "G1-G4 iOS repository is incorrect")
    require(ios["configuration"] == "FloorpRelease", "G1-G4 iOS configuration is incorrect")
    require(desktop["repository"] == DESKTOP_REPOSITORY, "G1-G4 Desktop repository is incorrect")
    require(desktop["build_number"] == ios["build_number"], "G1-G4 Desktop build number differs from iOS")
    require(runtime["repository"] == RUNTIME_REPOSITORY, "G1-G4 Runtime repository is incorrect")
    expected_g1_contract = {
        "case_set_sha256": contract["case_set_sha256"],
        "control_pref_name": RELEASE_VALIDATOR.EXPECTED_CONTROL_PREF,
        "control_pref_value": True,
        "desktop_contract_sha": desktop["source_sha"],
        "fixture_sha256": contract["fixture_sha256"],
        "ios_contract_sha": ios["source_sha"],
        "notes_pref_name": RELEASE_VALIDATOR.EXPECTED_NOTES_PREF,
        "record_id": RELEASE_VALIDATOR.EXPECTED_RECORD_ID,
    }
    require(gates["g1"]["contract"] == expected_g1_contract, "G1 contract is mixed")
    require(gates["g2"]["application_services"] == as_input, "G2 Application Services input is mixed")
    require(gates["g3"]["candidate"] == ios, "G3 iOS candidate is mixed")
    require(gates["g4"]["desktop"] == desktop, "G4 Desktop input is mixed")
    require(gates["g4"]["runtime"] == runtime, "G4 Runtime input is mixed")
    expected_combined_digest = RELEASE_VALIDATOR.digest(
        {"gates": {name: gates[name] for name in required_gate_names}, "release_inputs": inputs}
    )
    require(
        evidence["g1_g4_digest_sha256"] == expected_combined_digest,
        "combined G1-G4 digest does not match canonical inputs and gates",
    )
    try:
        RELEASE_VALIDATOR.validate_same_release(evidence)
    except RELEASE_VALIDATOR.ValidationError as error:
        reject(f"G1-G4 same-release validation failed: {error}")
    return ios, desktop, runtime, expected_combined_digest


def validate_endpoint_authority(value: Any, matrix_digest: str, expected_hosts: list[str], label: str) -> None:
    authority = require_fields(
        value,
        (
            "custom_fxa_override",
            "custom_token_server_override",
            "environment",
            "fxa_server",
            "hosts",
            "matrix_path",
            "matrix_sha256",
            "wire_protocol",
        ),
        label,
    )
    require(authority["environment"] == "production", f"{label} environment is not production")
    require(authority["fxa_server"] == "FxAConfig.Server.release", f"{label} FxA server is not release")
    require(authority["wire_protocol"] == "sync15", f"{label} wire protocol is not sync15")
    require(authority["custom_fxa_override"] is False, f"{label} allows a custom FxA override")
    require(authority["custom_token_server_override"] is False, f"{label} allows a custom token override")
    require(authority["hosts"] == expected_hosts, f"{label} host set is not the exact approved endpoint set")
    require(authority["matrix_sha256"] == matrix_digest, f"{label} matrix SHA does not match endpoint matrix")
    require_string(authority["matrix_path"], f"{label} matrix path")


def validate_ios_manifest(
    value: dict[str, Any],
    *,
    mode: str,
    ios: dict[str, Any],
    as_input: dict[str, Any],
    combined_evidence_digest: str,
    matrix_digest: str,
    expected_hosts: list[str],
) -> str:
    require(value.get("schema_version") == 1, f"{mode} iOS manifest schema version is not 1")
    require(value.get("mode") == mode, f"iOS manifest mode is not {mode}")
    source = require_fields(value.get("source"), ("commit", "dirty", "tree"), f"{mode} iOS source")
    require(source["commit"] == ios["source_sha"], f"{mode} iOS source does not match G1-G4 iOS source")
    source_tree = require_sha1(source["tree"], f"{mode} iOS source tree")
    require(source["dirty"] is False, f"{mode} iOS source is dirty")
    build = require_fields(
        value.get("build"),
        ("action", "build_number", "configuration", "scheme", "signing_allowed", "signing_verified"),
        f"{mode} iOS build",
    )
    require(build["configuration"] == "FloorpRelease", f"{mode} iOS configuration is not FloorpRelease")
    require(build["build_number"] == ios["build_number"], f"{mode} iOS build number does not match G1-G4")
    require(build["signing_allowed"] is False and build["signing_verified"] is False, f"{mode} iOS build must remain unsigned")
    if mode == "production-qa":
        require(build["action"] == "build-for-testing", "production-qa iOS build action is not build-for-testing")
        require(build["scheme"] == "FloorpNotesSyncQA", "production-qa iOS scheme is not FloorpNotesSyncQA")
        require(
            value.get("release_inputs") == {"application_services": as_input, "ios": ios},
            "production-qa iOS release inputs do not match G1-G4",
        )
        evidence = require_fields(value.get("evidence"), ("embedded_digest_sha256",), "production-qa iOS evidence")
        require(
            evidence["embedded_digest_sha256"] == combined_evidence_digest,
            "production-qa embedded evidence digest does not match G1-G4",
        )
        expected_gate = True
    else:
        require(build["action"] == "build", "release-disabled iOS build action is not build")
        require(build["scheme"] == "Floorp", "release-disabled iOS scheme is not Floorp")
        require(
            value.get("release_inputs") == {"application_services": None, "ios": None},
            "release-disabled iOS release inputs are not empty",
        )
        evidence = require_fields(value.get("evidence"), ("embedded_digest_sha256",), "release-disabled iOS evidence")
        require(evidence["embedded_digest_sha256"] is None, "release-disabled iOS evidence digest is not empty")
        expected_gate = False
    validate_endpoint_authority(value.get("endpoint_authority"), matrix_digest, expected_hosts, f"{mode} endpoint authority")
    require(value.get("gate") == {"requested": expected_gate, "effective": expected_gate}, f"{mode} iOS gate is not exact")
    require(
        value.get("runtime_contract")
        == {
            "engine_registration_allowed": expected_gate,
            "engine_requests_allowed": expected_gate,
            "ui_exposure_allowed": expected_gate,
        },
        f"{mode} iOS runtime contract is not exact",
    )
    return source_tree


def validate_desktop_manifest(value: dict[str, Any], desktop: dict[str, Any], runtime: dict[str, Any]) -> None:
    require(value.get("schema_version") == 1, "Desktop manifest schema version is not 1")
    source = require_fields(value.get("source"), ("commit", "repository"), "Desktop manifest source")
    require(source["repository"] == DESKTOP_REPOSITORY, "Desktop manifest repository is incorrect")
    require(source["commit"] == desktop["source_sha"], "Desktop manifest source does not match G1-G4")
    build = require_fields(value.get("build"), ("build_number",), "Desktop manifest build")
    require(build["build_number"] == desktop["build_number"], "Desktop manifest build number does not match G1-G4")
    require(value.get("runtime") == runtime, "Desktop manifest Runtime input does not match G1-G4")
    require(
        value.get("notes_sync") == {"endpoint_authority": "production", "wire_protocol": "sync15"},
        "Desktop manifest Notes Sync authority is not exact",
    )


def preflight(arguments: argparse.Namespace) -> int:
    _, qa, qa_raw = regular_json(arguments.ios_production_qa_manifest, "production-qa iOS manifest")
    _, disabled, disabled_raw = regular_json(arguments.ios_release_disabled_manifest, "release-disabled iOS manifest")
    _, evidence, evidence_raw = regular_json(arguments.g1_g4_evidence, "G1-G4 evidence", require_canonical=True)
    _, desktop, desktop_raw = regular_json(arguments.desktop_manifest, "Desktop manifest")
    _, handoff, handoff_raw = regular_json(arguments.as_handoff, "AS handoff")
    _, fixture, fixture_raw = regular_json(arguments.fixture, "fixture")
    _, matrix, matrix_raw = regular_json(arguments.endpoint_matrix, "endpoint matrix")
    endpoint_authority_safe_fields = frozenset(
        {
            ("endpoint_authority", "custom_token_server_override"),
        }
    )
    assert_no_sensitive_values(
        qa,
        "production-qa iOS manifest",
        allowed_field_paths=endpoint_authority_safe_fields,
    )
    assert_no_sensitive_values(
        disabled,
        "release-disabled iOS manifest",
        allowed_field_paths=endpoint_authority_safe_fields,
    )
    assert_no_sensitive_values(
        evidence,
        "G1-G4 evidence",
        allowed_field_paths=frozenset(
            {
                ("same_release_key_sha256",),
            }
        ),
    )
    assert_no_sensitive_values(desktop, "Desktop manifest")
    assert_no_sensitive_values(handoff, "AS handoff")
    assert_no_sensitive_values(fixture, "fixture")
    assert_no_sensitive_values(matrix, "endpoint matrix")

    fixture_digest, case_set_digest = validate_fixture(fixture, fixture_raw)
    matrix_digest, expected_hosts = validate_endpoint_matrix(matrix, matrix_raw)
    as_input = validate_as_handoff(handoff)
    ios, desktop_input, runtime, combined_evidence_digest = validate_static_evidence(
        evidence,
        fixture_digest,
        case_set_digest,
        matrix_digest,
        as_input,
    )
    qa_tree = validate_ios_manifest(
        qa,
        mode="production-qa",
        ios=ios,
        as_input=as_input,
        combined_evidence_digest=combined_evidence_digest,
        matrix_digest=matrix_digest,
        expected_hosts=expected_hosts,
    )
    disabled_tree = validate_ios_manifest(
        disabled,
        mode="release-disabled",
        ios=ios,
        as_input=as_input,
        combined_evidence_digest=combined_evidence_digest,
        matrix_digest=matrix_digest,
        expected_hosts=expected_hosts,
    )
    require(qa_tree == disabled_tree, "iOS production-qa and release-disabled source trees differ")
    validate_desktop_manifest(desktop, desktop_input, runtime)

    result = {
        "artifact_retrievability": "not-assessed",
        "cleanup_boundary": "not-established",
        "evidence_freshness": "not-assessed",
        "execution_authorization": "not-authorized",
        "fixture_sha256": fixture_digest,
        "g5_result": "not-assessed",
        "inputs": {
            "as_handoff_sha256": sha256(handoff_raw),
            "desktop_manifest_sha256": sha256(desktop_raw),
            "endpoint_matrix_sha256": matrix_digest,
            "g1_g4_evidence_sha256": sha256(evidence_raw),
            "ios_production_qa_manifest_sha256": sha256(qa_raw),
            "ios_release_disabled_manifest_sha256": sha256(disabled_raw),
        },
        "ios_source_sha": ios["source_sha"],
        "static_evidence_integrity": "verified",
        "status": "preflight-valid",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Floorp Notes Sync Todo 20 operational tools")
    result.add_argument("command", choices=("preflight", "desktop-build", "matrix", "collect-approvals"))
    result.add_argument("--ios-production-qa-manifest")
    result.add_argument("--ios-release-disabled-manifest")
    result.add_argument("--g1-g4-evidence")
    result.add_argument("--desktop-manifest")
    result.add_argument("--as-handoff")
    result.add_argument("--fixture")
    result.add_argument("--endpoint-matrix")
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    if arguments.command != "preflight":
        print("Todo 20 operational implementation is not yet configured", file=sys.stderr)
        return 2
    for name in (
        "ios_production_qa_manifest",
        "ios_release_disabled_manifest",
        "g1_g4_evidence",
        "desktop_manifest",
        "as_handoff",
        "fixture",
        "endpoint_matrix",
    ):
        if getattr(arguments, name) is None:
            print(f"preflight: missing --{name.replace('_', '-')}", file=sys.stderr)
            return 2
    try:
        return preflight(arguments)
    except PreflightError as error:
        print(f"preflight: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
