#!/usr/bin/python3 -I
"""Fail when protected QA process command lines contain secret markers."""

from __future__ import annotations

import subprocess
import sys


MARKERS = (
    "password",
    "access_token",
    "refresh_token",
    "sync_key",
    "authorization",
    "bearer ",
    "cookie",
    "credential",
    "secret",
    "begin private key",
    "oauth_token",
    "note(_|s_)(content|title|payload)",
    "request_body",
    "response_body",
)
OWNED_PROCESS_MARKERS = (
    "xcodebuild",
    "feles-build",
    "floorp-notes-sync-production-qa",
    "Floorp",
)


def main() -> int:
    try:
        output = subprocess.check_output(
            ["ps", "-axww", "-o", "command="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"process argv scan unavailable: {error}", file=sys.stderr)
        return 2
    for line in output.splitlines():
        lowered = line.lower()
        if "scan-floorp-notes-sync-process-argv.py" in lowered:
            continue
        if not any(marker.lower() in lowered for marker in OWNED_PROCESS_MARKERS):
            continue
        if any(marker in lowered for marker in MARKERS):
            print("owned QA process argv secret marker detected", file=sys.stderr)
            return 1
    print('{"process_argv_scan":"passed"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
