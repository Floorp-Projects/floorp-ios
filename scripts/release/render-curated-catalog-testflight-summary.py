#!/usr/bin/env python3
"""Render the non-secret summary for a verified curated-catalog submission."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


class CuratedCatalogSummaryError(RuntimeError):
    """The submission evidence cannot safely be rendered."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CuratedCatalogSummaryError(message)


def render_submission_summary(evidence: dict[str, Any]) -> str:
    """Return stable Markdown only for the expected verified evidence shape."""

    fields = (
        "buildID",
        "buildNumber",
        "catalogID",
        "catalogSHA256",
        "catalogSequence",
        "marketingVersion",
        "xcodeCloudRunID",
    )
    for field in fields:
        _require(isinstance(evidence.get(field), (str, int)), f"submission evidence {field} is invalid")
    _require(evidence.get("status") == "verified", "submission evidence is not verified")

    return "\n".join(
        (
            f"- App Store Connect build: `{evidence['buildID']}` ({evidence['marketingVersion']} ({evidence['buildNumber']}))",
            f"- Xcode Cloud run: `{evidence['xcodeCloudRunID']}`",
            f"- Signed catalog: `{evidence['catalogID']}` sequence `{evidence['catalogSequence']}` SHA-256 `{evidence['catalogSHA256']}`",
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    try:
        value = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CuratedCatalogSummaryError(f"cannot read submission evidence: {error}") from error
    _require(isinstance(value, dict), "submission evidence is not an object")
    print(render_submission_summary(value))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CuratedCatalogSummaryError as error:
        raise SystemExit(f"error: {error}") from error
