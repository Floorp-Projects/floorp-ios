#!/usr/bin/python3 -I
"""Clean only the protected runner-local Todo 20 temporary state.

This command intentionally has no account-file, FxA, Sync, REST, or token
operation. Server-account cleanup is performed by the existing client pair
and is represented by the metadata-only QA summary; this command removes the
runner-local material after the run.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path


class CleanupError(RuntimeError):
    pass


def require_runner_temp_child(path: Path) -> Path:
    runner_temp = os.environ.get("RUNNER_TEMP")
    if not runner_temp:
        raise CleanupError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=cleanup_scope_unknown "
            "resume=run on a CI runner with RUNNER_TEMP"
        )
    root = Path(runner_temp).resolve(strict=False)
    candidate = path.resolve(strict=False)
    if candidate == root or root not in candidate.parents:
        raise CleanupError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations reason=cleanup_scope_unknown "
            "resume=provide a RUNNER_TEMP child path"
        )
    return candidate


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-root", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        target = require_runner_temp_child(args.work_root)
        if target.exists() or target.is_symlink():
            if target.is_symlink() or not target.is_dir():
                raise CleanupError(
                    "[blocked] AUTHORIZATION_MISSING owner=Operations reason=cleanup_scope_unknown "
                    "resume=use a real runner temp directory"
                )
            shutil.rmtree(target)
    except (CleanupError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 78
    print('{"status":"runner-local-cleanup-complete"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
