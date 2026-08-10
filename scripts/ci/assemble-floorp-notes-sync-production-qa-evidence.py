#!/usr/bin/python3 -I
"""Assemble deterministic Floorp Notes Sync production-QA G1-G4 evidence.

The recipe is canonical RFC 8785 JCS JSON with this exact root shape::

    {
      "schema_version": 1,
      "build_contract_mode": "production-qa",
      "release_inputs": { ...exact schema release_inputs... },
      "g3_integration_commands": [
        {"argv": ["command", "argument"], "exit_code": 0, "terminal": true}
      ],
      "gates": {
        "g1": {"issued_at": "...Z", "sources": [ ... ]},
        "g2": {"issued_at": "...Z", "expires_at": "...Z", "sources": [ ... ]},
        "g3": {"issued_at": "...Z", "expires_at": "...Z", "sources": [ ... ]},
        "g4": {"issued_at": "...Z", "expires_at": "...Z", "sources": [ ... ]}
      }
    }

Each ordered source entry has exactly ``descriptor`` (the final schema source
descriptor) and ``bytes_path`` (a relative path below the recipe directory to
the already captured bytes). Remote GitHub descriptors therefore remain
content-addressed, offline inputs; this command never fetches the network.

The G3 integration-receipt entry is special: its canonical ``bytes_path`` must
not exist. The command creates it from the CLI OIDs and reviewed command list,
verifies its recipe-declared digest, and publishes it with the evidence. The
output and receipt are no-clobber files.

G4 has the exact ordered roles ``task-manifest``,
``task18-execution-verdict``, ``desktop-ci-run``, ``runtime-ci-run``,
``g4-attestation-source``, ``g4-attestation-ci-run``,
``g4-attestation-xcresult``, ``xpcshell-run``, and ``tps-run``. Its canonical
attestation source binds the Task 18 manifest, execution verdict, summary
digests, and exact Desktop/Runtime producer identities. The attestation run
and XCResult descriptors must be exact G3 descriptors with only their roles
changed. The XCResult is parsed by xcresulttool and must have one or more
Passed nodes for the selected FloorpCI attestation test identifier.

Example::

    python3 -I scripts/ci/assemble-floorp-notes-sync-production-qa-evidence.py \
      --recipe /secure/run/production-qa-recipe.json \
      --g3-base-oid BASE_SHA \
      --g3-reviewed-head-oid REVIEWED_HEAD_SHA \
      --g3-merged-oid MERGED_MAIN_SHA \
      --output /secure/run/g1-g4-production-qa.json
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import os
import re
import stat
import sys
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = REPOSITORY_ROOT / "scripts/ci/validate-floorp-notes-sync-release.py"
SCHEMA_PATH = REPOSITORY_ROOT / "docs/floorp-notes-sync-release-evidence.schema.json"
FLOORP_RELEASE_XCCONFIG = REPOSITORY_ROOT / "firefox-ios/Client/Configuration/FloorpRelease.xcconfig"
RECIPE_ROOT_KEYS = {
    "build_contract_mode",
    "g3_integration_commands",
    "gates",
    "release_inputs",
    "schema_version",
}
GATE_NAMES = ("g1", "g2", "g3", "g4")
G4_ATTESTATION_PATH = "docs/floorp-notes-sync-g4-attestation.json"
G4_ATTESTATION_TEST = (
    "ClientTests/FloorpNotesSyncEngineSelectionTests/"
    "testG4AttestationBindsTask18Evidence()"
)
G4_ATTESTATION_XCRESULT_TEST = (
    "FloorpNotesSyncEngineSelectionTests/"
    "testG4AttestationBindsTask18Evidence()"
)
GATE_SOURCE_ROLES = {
    "g1": (
        "task-manifest",
        "todo16-contract",
        "ios-contract-source",
        "desktop-contract-source",
        "merge-fixture",
    ),
    "g2": (
        "task-manifest",
        "fake-server-run",
        "focus-xcframework",
        "mozilla-xcframework",
        "release-manifest",
        "sha256sums",
        "swift-components",
    ),
    "g3": ("integration-receipt", "ci-run", "xcresult"),
    "g4": (
        "task-manifest",
        "task18-execution-verdict",
        "desktop-ci-run",
        "runtime-ci-run",
        "g4-attestation-source",
        "g4-attestation-ci-run",
        "g4-attestation-xcresult",
        "xpcshell-run",
        "tps-run",
    ),
}
SHA1_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
RELATIVE_PATH_PATTERN = re.compile(r"[A-Za-z0-9._/-]{1,1024}\Z")
MAX_JSON_MATERIAL_BYTES = 32 * 1024 * 1024
READ_CHUNK_BYTES = 1024 * 1024
RUN_PAYLOAD_KEYS = {
    "conclusion",
    "created_at",
    "event",
    "head_branch",
    "head_sha",
    "id",
    "repository",
    "run_attempt",
    "status",
    "updated_at",
    "workflow_path",
}


class AssemblyError(Exception):
    pass


def load_validator() -> Any:
    spec = importlib.util.spec_from_file_location("floorp_notes_sync_release_validator", VALIDATOR_PATH)
    if spec is None or spec.loader is None:
        raise AssemblyError("cannot load the repository release-evidence validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VALIDATOR = load_validator()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssemblyError(message)


def validator_call(function: Any, *arguments: Any, **keywords: Any) -> Any:
    try:
        return function(*arguments, **keywords)
    except (VALIDATOR.ValidationError, VALIDATOR.MalformedError) as error:
        raise AssemblyError(str(error)) from error


def exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label}: must be an object")
    require(set(value) == expected, f"{label}: fields are not exact")
    return value


def relative_parts(value: Any, label: str) -> tuple[str, ...]:
    require(isinstance(value, str), f"{label}: path must be a string")
    require(RELATIVE_PATH_PATTERN.fullmatch(value) is not None, f"{label}: path is malformed")
    path = PurePosixPath(value)
    require(not path.is_absolute(), f"{label}: absolute path is forbidden")
    require(
        bool(path.parts) and all(part not in ("", ".", "..") for part in path.parts),
        f"{label}: path escape is forbidden",
    )
    return path.parts


def checked_target(
    root: Path,
    relative: Any,
    label: str,
    *,
    require_file: bool,
) -> Path:
    parts = relative_parts(relative, label)
    current = root
    for index, part in enumerate(parts):
        current = current / part
        is_last = index == len(parts) - 1
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            if is_last and not require_file:
                return current
            raise AssemblyError(f"{label}: source bytes are missing")
        except OSError as error:
            raise AssemblyError(f"{label}: cannot inspect source path ({error})") from error
        require(not stat.S_ISLNK(metadata.st_mode), f"{label}: symlink paths are forbidden")
        if is_last:
            if require_file:
                require(stat.S_ISREG(metadata.st_mode), f"{label}: source must be a regular file")
        else:
            require(stat.S_ISDIR(metadata.st_mode), f"{label}: parent is not a directory")
    return current


def stable_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def read_material(
    root: Path,
    bytes_path: Any,
    descriptor: dict[str, Any],
    label: str,
) -> tuple[str, Any | None, Path]:
    path = checked_target(root, bytes_path, label, require_file=True)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor_fd = os.open(path, flags)
    except OSError as error:
        raise AssemblyError(f"{label}: cannot open source bytes ({error})") from error
    try:
        before = os.fstat(descriptor_fd)
        require(stat.S_ISREG(before.st_mode), f"{label}: source must be a regular file")
        sha256 = hashlib.sha256()
        blob_sha = hashlib.sha1(
            f"blob {before.st_size}\0".encode("ascii")
        ) if descriptor.get("kind") == "github-repository-file" else None
        policy = descriptor.get("content_policy")
        keep_json = policy in ("metadata-json", "network-metadata-json")
        if keep_json:
            require(before.st_size <= MAX_JSON_MATERIAL_BYTES, f"{label}: JSON source is too large")
        raw = bytearray() if keep_json else None
        while chunk := os.read(descriptor_fd, READ_CHUNK_BYTES):
            sha256.update(chunk)
            if blob_sha is not None:
                blob_sha.update(chunk)
            if raw is not None:
                raw.extend(chunk)
        actual_digest = sha256.hexdigest()
        if descriptor.get("kind") == "github-actions-artifact":
            required_test = (
                VALIDATOR.G4_ATTESTATION_XCRESULT_TEST
                if descriptor.get("role") == "g4-attestation-xcresult"
                else None
            )
            os.lseek(descriptor_fd, 0, os.SEEK_SET)
            with os.fdopen(os.dup(descriptor_fd), "rb") as archive:
                validator_call(
                    VALIDATOR.validate_xcresult_archive,
                    archive,
                    label,
                    required_test=required_test,
                )
        after = os.fstat(descriptor_fd)
        require(stable_identity(before) == stable_identity(after), f"{label}: source changed while read")
        expected_digest = descriptor.get("sha256")
        require(
            isinstance(expected_digest, str) and SHA256_PATTERN.fullmatch(expected_digest) is not None,
            f"{label}: descriptor SHA-256 is malformed",
        )
        require(actual_digest == expected_digest, f"{label}: source bytes do not match SHA-256")
        if blob_sha is not None:
            require(
                blob_sha.hexdigest() == descriptor.get("blob_sha"),
                f"{label}: source bytes do not match Git blob SHA",
            )
        payload: Any | None = None
        if raw is not None:
            require_canonical = descriptor.get("kind") == "github-actions-run" or descriptor.get(
                "role"
            ) == "g4-attestation-source"
            payload = validator_call(
                VALIDATOR.parse_json_bytes,
                bytes(raw),
                require_canonical=require_canonical,
                label=label,
            )
            validator_call(
                VALIDATOR.validate_metadata_value,
                payload,
                label,
                network_only=policy == "network-metadata-json",
            )
        if descriptor.get("kind") == "github-actions-run":
            validate_run_capture(descriptor, payload, label)
        return actual_digest, payload, path
    finally:
        os.close(descriptor_fd)


def validate_run_capture(descriptor: dict[str, Any], payload: Any, label: str) -> None:
    require(isinstance(payload, dict), f"{label}: captured run metadata is malformed")
    require(set(payload) == RUN_PAYLOAD_KEYS, f"{label}: captured run fields are not exact")
    expected = {
        "head_sha": descriptor.get("head_sha"),
        "id": descriptor.get("run_id"),
        "repository": descriptor.get("repository"),
        "workflow_path": descriptor.get("workflow_path"),
    }
    for field, value in expected.items():
        require(payload.get(field) == value, f"{label}: captured run {field} mismatch")
    require(payload.get("status") == "completed", f"{label}: captured run is nonterminal")
    require(payload.get("conclusion") == "success", f"{label}: captured run did not succeed")


def load_recipe(path: Path) -> tuple[dict[str, Any], Path]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AssemblyError(f"recipe: cannot inspect input ({error})") from error
    require(not stat.S_ISLNK(metadata.st_mode), "recipe: symlink input is forbidden")
    require(stat.S_ISREG(metadata.st_mode), "recipe: input must be a regular file")
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise AssemblyError(f"recipe: cannot read input ({error})") from error
    recipe = validator_call(
        VALIDATOR.parse_json_bytes,
        raw,
        require_canonical=True,
        label="recipe",
    )
    exact_keys(recipe, RECIPE_ROOT_KEYS, "recipe")
    return recipe, path.resolve(strict=True).parent


def floorp_release_build_number() -> str:
    return validator_call(
        VALIDATOR.load_floorp_release_build_number,
        FLOORP_RELEASE_XCCONFIG,
    )


def validate_recipe_root(recipe: dict[str, Any], merged_oid: str) -> None:
    for gate_name, roles in GATE_SOURCE_ROLES.items():
        require(
            tuple(VALIDATOR.GATE_SOURCE_ROLES.get(gate_name, ())) == roles,
            f"recipe: repository validator {gate_name} source-role contract drifted",
        )
    require(
        getattr(VALIDATOR, "G4_ATTESTATION_PATH", None) == G4_ATTESTATION_PATH
        and getattr(VALIDATOR, "G4_ATTESTATION_TEST", None) == G4_ATTESTATION_TEST
        and getattr(VALIDATOR, "G4_ATTESTATION_XCRESULT_TEST", None)
        == G4_ATTESTATION_XCRESULT_TEST,
        "recipe: repository validator G4 attestation contract drifted",
    )
    schema_version = recipe.get("schema_version")
    require(
        isinstance(schema_version, int) and not isinstance(schema_version, bool) and schema_version == 1,
        "recipe: schema_version must be 1",
    )
    require(
        recipe.get("build_contract_mode") == VALIDATOR.PRODUCTION_QA_MODE,
        "recipe: build_contract_mode must be production-qa",
    )
    release_inputs = recipe.get("release_inputs")
    require(isinstance(release_inputs, dict), "recipe: release_inputs must be an object")
    ios = release_inputs.get("ios")
    require(isinstance(ios, dict), "recipe: iOS release input is missing")
    require(ios.get("source_sha") == merged_oid, "recipe: merged G3 OID does not match the iOS release input")
    require(
        ios.get("build_number") == floorp_release_build_number(),
        "recipe: iOS build_number does not match FloorpRelease.xcconfig",
    )
    require(ios.get("configuration") == "FloorpRelease", "recipe: iOS configuration is not FloorpRelease")
    commands_record = {"commands": recipe.get("g3_integration_commands")}
    validator_call(
        VALIDATOR.validate_terminal_commands,
        commands_record,
        "recipe G3 integration commands",
        require_identity=True,
    )
    gates = recipe.get("gates")
    require(isinstance(gates, dict) and set(gates) == set(GATE_NAMES), "recipe: gates must be exactly G1-G4")


def validate_oid(value: str, label: str) -> None:
    require(SHA1_PATTERN.fullmatch(value) is not None, f"{label}: value is not a lowercase Git SHA")


def build_receipt(
    recipe: dict[str, Any],
    base_oid: str,
    reviewed_head_oid: str,
    merged_oid: str,
) -> tuple[dict[str, Any], bytes]:
    receipt = {
        "commands": copy.deepcopy(recipe["g3_integration_commands"]),
        "repositories": [
            {
                "base_oid": base_oid,
                "head_oid": reviewed_head_oid,
                "merged_oid": merged_oid,
                "name": "floorp-ios",
            }
        ],
        "schema_version": 1,
        "state": "integration_complete",
        "task_id": 19,
    }
    validator_call(VALIDATOR.validate_integration_receipt, receipt, recipe["release_inputs"])
    validator_call(
        VALIDATOR.validate_metadata_value,
        receipt,
        "G3 integration receipt",
    )
    return receipt, VALIDATOR.canonical_bytes(receipt)


def validate_local_mapping(
    descriptor: dict[str, Any],
    material_path: Path,
    output_parent: Path,
    label: str,
) -> None:
    if descriptor.get("kind") != "local-file":
        return
    source_parts = relative_parts(descriptor.get("path"), f"{label} descriptor")
    expected = output_parent.joinpath(*source_parts)
    require(
        os.path.abspath(material_path) == os.path.abspath(expected),
        f"{label}: local bytes_path does not match the evidence-relative descriptor path",
    )


def gate_shape(gate_name: str, value: Any) -> dict[str, Any]:
    expected = {"issued_at", "sources"}
    if gate_name != "g1":
        expected.add("expires_at")
    gate = exact_keys(value, expected, f"recipe {gate_name}")
    require(isinstance(gate["sources"], list), f"recipe {gate_name}: sources must be an array")
    return gate


def collect_gate(
    gate_name: str,
    gate_recipe: dict[str, Any],
    recipe_root: Path,
    output_parent: Path,
    receipt: dict[str, Any],
    receipt_bytes: bytes,
) -> tuple[list[dict[str, Any]], dict[str, Any | None], Path | None]:
    entries = gate_recipe["sources"]
    descriptors: list[dict[str, Any]] = []
    for index, entry_value in enumerate(entries):
        entry = exact_keys(entry_value, {"bytes_path", "descriptor"}, f"recipe {gate_name} source {index}")
        descriptor = entry["descriptor"]
        require(isinstance(descriptor, dict), f"recipe {gate_name} source {index}: descriptor is malformed")
        descriptors.append(copy.deepcopy(descriptor))
    roles = tuple(descriptor.get("role") for descriptor in descriptors)
    require(
        roles == GATE_SOURCE_ROLES[gate_name],
        f"recipe {gate_name}: source roles or order are not exact",
    )

    payloads: dict[str, Any | None] = {}
    receipt_path: Path | None = None
    seen_materials: set[Path] = set()
    for index, (entry, descriptor) in enumerate(zip(entries, descriptors)):
        role = descriptor["role"]
        label = f"recipe {gate_name} {role}"
        if role == "integration-receipt":
            require(gate_name == "g3", f"{label}: integration receipt is in the wrong gate")
            receipt_path = checked_target(
                recipe_root,
                entry["bytes_path"],
                label,
                require_file=False,
            )
            require(not os.path.lexists(receipt_path), f"{label}: output already exists")
            actual_digest = hashlib.sha256(receipt_bytes).hexdigest()
            require(
                descriptor.get("sha256") == actual_digest,
                f"{label}: generated receipt does not match descriptor SHA-256",
            )
            payloads[role] = receipt
            material_path = receipt_path
        else:
            _, payload, material_path = read_material(
                recipe_root,
                entry["bytes_path"],
                descriptor,
                label,
            )
            payloads[role] = payload
        require(material_path not in seen_materials, f"{label}: bytes_path is reused")
        seen_materials.add(material_path)
        validate_local_mapping(descriptor, material_path, output_parent, label)
    return descriptors, payloads, receipt_path


def make_gate(
    gate_name: str,
    gate_recipe: dict[str, Any],
    sources: list[dict[str, Any]],
    inputs: dict[str, Any],
) -> dict[str, Any]:
    artifact = {"sha256": VALIDATOR.digest({"sources": sources}), "sources": sources}
    gate: dict[str, Any] = {
        "artifact": artifact,
        "issued_at": gate_recipe["issued_at"],
        "status": "passed",
    }
    if gate_name != "g1":
        gate["expires_at"] = gate_recipe["expires_at"]
    source_by_role = {source["role"]: source for source in sources}
    if gate_name == "g1":
        gate["contract"] = {
            "case_set_sha256": inputs["contract"]["case_set_sha256"],
            "control_pref_name": VALIDATOR.EXPECTED_CONTROL_PREF,
            "control_pref_value": True,
            "desktop_contract_sha": inputs["desktop"]["source_sha"],
            "fixture_sha256": inputs["contract"]["fixture_sha256"],
            "ios_contract_sha": inputs["ios"]["source_sha"],
            "notes_pref_name": VALIDATOR.EXPECTED_NOTES_PREF,
            "record_id": VALIDATOR.EXPECTED_RECORD_ID,
        }
    elif gate_name == "g2":
        gate["application_services"] = copy.deepcopy(inputs["application_services"])
        gate["fake_server_run_sha256"] = source_by_role["fake-server-run"]["sha256"]
    elif gate_name == "g3":
        gate["candidate"] = copy.deepcopy(inputs["ios"])
        gate["xcresult_sha256"] = source_by_role["xcresult"]["sha256"]
    elif gate_name == "g4":
        gate["desktop"] = copy.deepcopy(inputs["desktop"])
        gate["runtime"] = copy.deepcopy(inputs["runtime"])
        gate["tps_run_sha256"] = source_by_role["tps-run"]["sha256"]
        gate["xpcshell_run_sha256"] = source_by_role["xpcshell-run"]["sha256"]
    return gate


def with_role(source: dict[str, Any], role: str) -> dict[str, Any]:
    rebound = copy.deepcopy(source)
    rebound["role"] = role
    return rebound


def validate_g4_cross_gate_identity(
    gate: dict[str, Any],
    payloads: dict[str, Any | None],
    g3_gate: dict[str, Any],
    g3_payloads: dict[str, Any | None],
) -> None:
    label = "G4 external attestation"
    sources = {source["role"]: source for source in gate["artifact"]["sources"]}
    g3_sources = {source["role"]: source for source in g3_gate["artifact"]["sources"]}
    require(
        sources["g4-attestation-ci-run"]
        == with_role(g3_sources["ci-run"], "g4-attestation-ci-run"),
        f"{label}: CI run descriptor is not a role-only copy of G3",
    )
    require(
        sources["g4-attestation-xcresult"]
        == with_role(g3_sources["xcresult"], "g4-attestation-xcresult"),
        f"{label}: XCResult descriptor is not a role-only copy of G3",
    )
    require(
        payloads["g4-attestation-ci-run"] == g3_payloads["ci-run"],
        f"{label}: captured CI run differs from G3",
    )


def validate_gate_semantics(
    gate_name: str,
    gate: dict[str, Any],
    payloads: dict[str, Any | None],
    inputs: dict[str, Any],
    g3_gate: dict[str, Any] | None,
    g3_payloads: dict[str, Any | None] | None,
) -> None:
    sources = {source["role"]: source for source in gate["artifact"]["sources"]}
    if gate_name == "g3":
        manifest = validator_call(VALIDATOR.validate_integration_receipt, payloads["integration-receipt"], inputs)
    else:
        manifest = validator_call(
            VALIDATOR.validate_task_manifest,
            gate_name,
            payloads["task-manifest"],
            inputs,
        )
    validator_call(
        VALIDATOR.validate_gate_source_semantics,
        gate_name,
        gate,
        sources,
        manifest,
        inputs,
        payloads,
    )
    issued_at = validator_call(VALIDATOR.parse_timestamp, gate["issued_at"], f"{gate_name}.issued_at")
    max_age = {"g1": None, "g2": 30, "g3": 7, "g4": 30}[gate_name]
    if gate_name == "g4":
        require(g3_gate is not None and g3_payloads is not None, "G4 external attestation: G3 is unavailable")
        validate_g4_cross_gate_identity(gate, payloads, g3_gate, g3_payloads)
    validator_call(
        VALIDATOR.validate_artifact_bound_gate_time,
        gate_name,
        gate,
        sources,
        payloads,
        issued_at,
    )
    validator_call(
        VALIDATOR.validate_gate_time,
        gate_name.upper(),
        gate,
        issued_at,
        max_age,
    )


def assemble(
    recipe_path: Path,
    output_path: Path,
    base_oid: str,
    reviewed_head_oid: str,
    merged_oid: str,
) -> tuple[bytes, Path, bytes]:
    for value, label in (
        (base_oid, "G3 base OID"),
        (reviewed_head_oid, "G3 reviewed head OID"),
        (merged_oid, "G3 merged OID"),
    ):
        validate_oid(value, label)
    recipe, recipe_root = load_recipe(recipe_path)
    validate_recipe_root(recipe, merged_oid)

    output = output_path.absolute()
    try:
        output_parent = output.parent.resolve(strict=True)
        parent_metadata = output.parent.lstat()
    except OSError as error:
        raise AssemblyError(f"output: parent directory is unavailable ({error})") from error
    require(stat.S_ISDIR(parent_metadata.st_mode), "output: parent is not a directory")
    require(not stat.S_ISLNK(parent_metadata.st_mode), "output: symlink parent is forbidden")
    require(not os.path.lexists(output), "output: file already exists")

    receipt, receipt_bytes = build_receipt(recipe, base_oid, reviewed_head_oid, merged_oid)
    gates: dict[str, Any] = {}
    gate_payloads: dict[str, dict[str, Any | None]] = {}
    receipt_output: Path | None = None
    issued_times: list[datetime] = []
    for gate_name in GATE_NAMES:
        gate_recipe = gate_shape(gate_name, recipe["gates"][gate_name])
        sources, payloads, candidate_receipt_path = collect_gate(
            gate_name,
            gate_recipe,
            recipe_root,
            output_parent,
            receipt,
            receipt_bytes,
        )
        if candidate_receipt_path is not None:
            require(receipt_output is None, "recipe: multiple integration receipt outputs are forbidden")
            receipt_output = candidate_receipt_path
        gate = make_gate(gate_name, gate_recipe, sources, recipe["release_inputs"])
        validate_gate_semantics(
            gate_name,
            gate,
            payloads,
            recipe["release_inputs"],
            gates.get("g3"),
            gate_payloads.get("g3"),
        )
        gates[gate_name] = gate
        gate_payloads[gate_name] = payloads
        issued_times.append(
            validator_call(VALIDATOR.parse_timestamp, gate["issued_at"], f"{gate_name}.issued_at")
        )
    require(receipt_output is not None, "recipe: G3 integration receipt output is missing")
    require(receipt_output != output, "recipe: receipt and evidence outputs must differ")

    evidence: dict[str, Any] = {
        "build_contract_mode": VALIDATOR.PRODUCTION_QA_MODE,
        "g1_g4_digest_sha256": "",
        "gates": gates,
        "release_inputs": copy.deepcopy(recipe["release_inputs"]),
        "same_release_key_sha256": "",
        "schema_version": 1,
    }
    evidence["g1_g4_digest_sha256"] = VALIDATOR.digest(
        {"gates": {name: gates[name] for name in GATE_NAMES}, "release_inputs": evidence["release_inputs"]}
    )
    gate_digests = {name: gates[name]["artifact"]["sha256"] for name in GATE_NAMES}
    evidence["same_release_key_sha256"] = VALIDATOR.digest(
        {"gate_artifact_digests": gate_digests, "release_inputs": evidence["release_inputs"]}
    )

    schema = validator_call(VALIDATOR.load_pinned_schema, REPOSITORY_ROOT, SCHEMA_PATH)
    validator_call(VALIDATOR.validate_mode_gate_semantics, evidence, False)
    validator_call(VALIDATOR.validate_schema_instance, evidence, schema, schema)
    validator_call(
        VALIDATOR.validate_release_contract,
        evidence,
        max(issued_times),
        floorp_release_build_number(),
    )
    validator_call(VALIDATOR.validate_same_release, evidence)
    return VALIDATOR.canonical_bytes(evidence), receipt_output, receipt_bytes


def write_all(descriptor_fd: int, raw: bytes) -> None:
    offset = 0
    while offset < len(raw):
        offset += os.write(descriptor_fd, raw[offset:])
    os.fsync(descriptor_fd)


def publish_no_clobber(evidence_path: Path, evidence_raw: bytes, receipt_path: Path, receipt_raw: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    receipt_fd = -1
    evidence_fd = -1
    created_receipt = False
    created_evidence = False
    try:
        receipt_fd = os.open(receipt_path, flags, 0o600)
        created_receipt = True
        evidence_fd = os.open(evidence_path, flags, 0o600)
        created_evidence = True
        write_all(receipt_fd, receipt_raw)
        write_all(evidence_fd, evidence_raw)
    except OSError as error:
        raise AssemblyError(f"no-clobber publication failed ({error})") from error
    finally:
        if receipt_fd >= 0:
            os.close(receipt_fd)
        if evidence_fd >= 0:
            os.close(evidence_fd)
        if sys.exc_info()[0] is not None:
            if created_evidence:
                evidence_path.unlink(missing_ok=True)
            if created_receipt:
                receipt_path.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipe", required=True, type=Path, help="canonical offline assembly recipe")
    parser.add_argument("--g3-base-oid", required=True, help="iOS main SHA before the reviewed PR")
    parser.add_argument("--g3-reviewed-head-oid", required=True, help="OID-guarded reviewed PR head SHA")
    parser.add_argument("--g3-merged-oid", required=True, help="squash-merged iOS main SHA")
    parser.add_argument("--output", required=True, type=Path, help="new canonical G1-G4 evidence path")
    arguments = parser.parse_args(argv)
    try:
        evidence_raw, receipt_path, receipt_raw = assemble(
            arguments.recipe,
            arguments.output,
            arguments.g3_base_oid,
            arguments.g3_reviewed_head_oid,
            arguments.g3_merged_oid,
        )
        publish_no_clobber(arguments.output.absolute(), evidence_raw, receipt_path, receipt_raw)
        print(
            "APPROVE: assembled canonical production-qa G1-G4 evidence "
            f"and integration receipt at {receipt_path}"
        )
        return 0
    except AssemblyError as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError) as error:
        print(f"INPUT_ERROR: assembly dependency failed ({error})", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
