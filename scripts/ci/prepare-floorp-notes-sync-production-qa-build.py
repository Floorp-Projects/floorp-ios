#!/usr/bin/python3 -I
"""Prepare an external, non-distributed production-QA xcconfig."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from floorp_notes_sync_production_qa_capability import (  # noqa: E402
    APPROVED_FXA_HOSTS,
    APPROVED_SYNC_HOSTS,
    load_capability,
    sha256_file,
)


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capability", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--desktop-sha", required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--endpoint-policy", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        capability = load_capability(
            args.capability,
            expected_source_sha=args.source_sha,
            expected_desktop_sha=args.desktop_sha,
            expected_contract_sha=sha256_file(args.contract),
            expected_endpoint_policy_sha=sha256_file(args.endpoint_policy),
        )
        if capability["ios_build_number"] != "4":
            raise ValueError("production-QA build number is not the approved value")
        resource = args.capability.resolve(strict=True)
        if any(character in str(resource) for character in "\r\n"):
            raise ValueError("capability resource path contains a control character")
        hosts = ",".join((*APPROVED_FXA_HOSTS, *APPROVED_SYNC_HOSTS))
        digest = sha256_file(resource)
        values = [
            "// Generated in the protected workflow; never commit this file.",
            "FLOORP_BUILD_NUMBER = 4",
            "FLOORP_NOTES_SYNC_BUILD_MODE = production-qa",
            f"FLOORP_NOTES_SYNC_SOURCE_SHA = {args.source_sha}",
            "FLOORP_NOTES_SYNC_REQUESTED = YES",
            "FLOORP_NOTES_SYNC_EFFECTIVE = YES",
            "FLOORP_NOTES_SYNC_FXA_SERVER = release",
            "FLOORP_NOTES_SYNC_ENDPOINT_AUTHORITY = production",
            "FLOORP_NOTES_SYNC_PROTOCOL = sync15",
            "FLOORP_NOTES_SYNC_CUSTOM_FXA_OVERRIDE = NO",
            "FLOORP_NOTES_SYNC_CUSTOM_TOKEN_SERVER_OVERRIDE = NO",
            f"FLOORP_NOTES_SYNC_ALLOWED_HOSTS = {hosts}",
            f"FLOORP_NOTES_SYNC_ENDPOINT_MATRIX_SHA256 = {capability['endpoint']['endpoint_policy_sha256']}",
            f"FLOORP_NOTES_SYNC_EVIDENCE_DIGEST = {digest}",
            f"FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE = {resource}",
            f"FLOORP_NOTES_SYNC_EVIDENCE_RESOURCE_SHA256 = {digest}",
        ]
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8") as handle:
            handle.write("\n".join(values) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(args.output, 0o600)
    except (OSError, ValueError) as error:
        print(f"production-QA xcconfig rejected: {error}", file=sys.stderr)
        return 2
    print('{"status":"production-qa-xcconfig-created"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
