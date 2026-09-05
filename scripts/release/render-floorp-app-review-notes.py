#!/usr/bin/env python3
"""Render the reviewed App Review Notes block from a source-bound build receipt."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


REPOSITORY = "https://github.com/Floorp-Projects/floorp-ios"
REVIEW_NOTES_HEADING = "## Paste into App Store Connect — Review Notes"
PLACEHOLDERS = ("[VERSION]", "[BUILD]", "[RELEASE_TAG_OR_FULL_COMMIT]")
REQUIRED_DISCLOSURES = (
    "GNU GPL v3.0 or later",
    "uBOLite-floorp-ios-2026.825.1619.patch",
    "scripts/package-ubol-ios.sh",
)


class RenderError(ValueError):
    pass


def render(template: str, receipt: dict) -> dict[str, str]:
    if not isinstance(receipt, dict) or receipt.get("schema_version") != 1:
        raise RenderError("source-bound build receipt schema is invalid")
    source = receipt.get("source")
    build = receipt.get("build")
    if not isinstance(source, dict) or not isinstance(build, dict):
        raise RenderError("source-bound build receipt identity is missing")
    commit = source.get("commit_sha")
    reference = source.get("name")
    if (
        source.get("kind") != "tag"
        or not isinstance(commit, str)
        or re.fullmatch(r"[0-9a-f]{40}", commit) is None
        or reference != f"floorp-catalog-{commit}"
    ):
        raise RenderError("source-bound build receipt tag is not commit-bound")
    version = build.get("marketing_version")
    number = build.get("number")
    if not isinstance(version, str) or not version or not isinstance(number, str) or not number:
        raise RenderError("source-bound build receipt version is missing")
    if template.count(REVIEW_NOTES_HEADING) != 1:
        raise RenderError("App Review notes template has no unique reviewed section")
    reviewed = template.split(REVIEW_NOTES_HEADING, 1)[1].split("\n## ", 1)[0]
    blocks = re.findall(r"(?:^|\n)```text\n(.*?)\n```(?=\n|$)", reviewed, re.DOTALL)
    if len(blocks) != 1:
        raise RenderError("App Review notes reviewed section has no unique text block")
    notes = blocks[0]
    notes = (
        notes.replace("[VERSION]", version)
        .replace("[BUILD]", number)
        .replace("[RELEASE_TAG_OR_FULL_COMMIT]", reference)
    )
    public_url = f"{REPOSITORY}/tree/{reference}"
    if any(placeholder in notes for placeholder in PLACEHOLDERS):
        raise RenderError("rendered App Review notes contain placeholders")
    if public_url not in notes:
        raise RenderError("rendered App Review notes omit the immutable public source URL")
    if any(marker not in notes for marker in REQUIRED_DISCLOSURES):
        raise RenderError("rendered App Review notes omit a required GPL disclosure marker")
    if len(notes.encode("utf-8")) > 4000:
        raise RenderError("rendered App Review notes exceed Apple's 4,000-byte limit")
    return {"notes": notes}


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        value = render(
            arguments.template.read_text(encoding="utf-8"),
            json.loads(arguments.receipt.read_text(encoding="utf-8")),
        )
        arguments.output.write_text(
            json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            + "\n",
            encoding="utf-8",
        )
        print(arguments.output)
        return 0
    except (RenderError, json.JSONDecodeError, OSError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
