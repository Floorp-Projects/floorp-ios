#!/usr/bin/python3 -I
"""Validate a non-distributed Todo 20 production-QA capability record."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from floorp_notes_sync_production_qa_capability import (  # noqa: E402
    CapabilityError,
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
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        load_capability(
            args.capability,
            expected_source_sha=args.source_sha,
            expected_desktop_sha=args.desktop_sha,
            expected_contract_sha=sha256_file(args.contract),
            expected_endpoint_policy_sha=sha256_file(args.endpoint_policy),
        )
    except (OSError, UnicodeError, ValueError, CapabilityError) as error:
        print(f"production-QA capability rejected: {error}", file=sys.stderr)
        return 2
    print('{"status":"production-qa-capability-valid"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
