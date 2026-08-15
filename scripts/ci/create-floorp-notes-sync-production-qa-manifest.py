#!/usr/bin/python3 -I
"""Create a metadata-only manifest for the protected Todo 20 QA run.

The manifest contains only artifact names, sizes, and digests. It never copies
or serializes Notes payloads, credentials, or log contents.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
from pathlib import Path
from typing import Any


ENVIRONMENT = "floorp-notes-sync-production-qa"
REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/ci.yml"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
ARTIFACTS = (
    ("qa-summary", "qa-summary.json"),
    ("cleanup-receipt", "cleanup-receipt.json"),
    ("xcresult", "floorp-notes-sync-two-client.xcresult"),
    ("xcodebuild-log", "xcodebuild.log"),
    ("desktop-log", "desktop.log"),
    ("production-qa-capability", "production-qa-capability.json"),
    ("production-qa-xcconfig", "production-qa.xcconfig"),
    ("secret-scan", "secret-scan-pre.json"),
)


class ManifestError(ValueError):
    pass


def canonical(value: dict[str, Any]) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True).encode()
        + b"\n"
    )


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--desktop-sha", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--run-attempt", type=int, required=True)
    for option, _ in ARTIFACTS:
        parser.add_argument(f"--{option}", type=Path, required=True)
    return parser.parse_args(arguments)


def digest_artifact(path: Path) -> dict[str, Any]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ManifestError(f"manifest artifact is unavailable: {path.name}") from error
    if path.is_symlink() or not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)):
        raise ManifestError(f"manifest artifact is not a regular file or directory: {path.name}")
    if path.is_file():
        try:
            raw = path.read_bytes()
        except OSError as error:
            raise ManifestError(f"manifest artifact cannot be read: {path.name}") from error
        return {"name": path.name, "sha256": hashlib.sha256(raw).hexdigest(), "byte_count": len(raw)}
    entries: list[bytes] = []
    byte_count = 0
    try:
        children = sorted(path.rglob("*"))
        for child in children:
            if child.is_symlink():
                raise ManifestError(f"manifest artifact contains a symlink: {path.name}")
            if not child.is_file():
                continue
            raw = child.read_bytes()
            byte_count += len(raw)
            entries.append(child.relative_to(path).as_posix().encode() + b"\0" + hashlib.sha256(raw).hexdigest().encode())
    except OSError as error:
        raise ManifestError(f"manifest artifact cannot be read: {path.name}") from error
    return {"name": path.name, "sha256": hashlib.sha256(b"\n".join(entries)).hexdigest(), "byte_count": byte_count}


def read_json_file(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise ManifestError(f"manifest JSON artifact is not a regular file: {path.name}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"manifest JSON artifact is invalid: {path.name}") from error


def validate_context(args: argparse.Namespace) -> None:
    if not SHA1.fullmatch(args.source_sha) or not SHA1.fullmatch(args.desktop_sha):
        raise ManifestError("manifest source or Desktop SHA is invalid")
    if args.run_id <= 0 or args.run_attempt <= 0:
        raise ManifestError("manifest workflow run binding is invalid")
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise ManifestError("manifest repository context is invalid")


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        validate_context(args)
        artifacts: list[dict[str, Any]] = []
        descriptors_by_role: dict[str, dict[str, Any]] = {}
        for role, _ in ARTIFACTS:
            descriptor = digest_artifact(getattr(args, role.replace("-", "_")))
            descriptor["role"] = role
            descriptors_by_role[role] = descriptor
            artifacts.append(descriptor)
        summary = read_json_file(getattr(args, "qa_summary"))
        cleanup = read_json_file(getattr(args, "cleanup_receipt"))
        if summary.get("accounts") != 2 or summary.get("public_release") is not False:
            raise ManifestError("manifest is not bound to the two-account non-public QA")
        if not all(
            cleanup.get(field) is True
            for field in ("accounts", "coordination_root", "local_cache", "runner_temp", "simulator_keychain")
        ):
            raise ManifestError("manifest cleanup receipt is incomplete")
        manifest = {
            "accounts": 2,
            "artifacts": artifacts,
            "desktop_sha": args.desktop_sha,
            "environment": ENVIRONMENT,
            "head_sha": args.source_sha,
            "public_release": False,
            "repository": REPOSITORY,
            "schema_version": 1,
            "workflow_path": WORKFLOW_PATH,
            "workflow_run_attempt": args.run_attempt,
            "workflow_run_id": args.run_id,
        }
        raw = canonical(manifest)
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("xb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
    except (OSError, UnicodeError, json.JSONDecodeError, ManifestError) as error:
        print(f"production QA manifest rejected: {error}", flush=True)
        return 2
    print('{"status":"production-qa-manifest-created"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
