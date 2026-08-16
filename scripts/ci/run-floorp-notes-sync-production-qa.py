#!/usr/bin/python3 -I
"""Run the protected Todo 20 desktop/mobile production-QA executor.

This entry point is intentionally fail-closed. It starts the staged Desktop
UI actor, starts the real iOS XCTest actor, waits for observed metadata-only
case events, and writes a summary only after all cases and cleanup are
proven. It never reads the local test-accounts directory and never prints a
credential.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from floorp_notes_sync_live_executor import (  # noqa: E402
    LiveExecutor,
    LiveExecutorError,
    LiveRunPaths,
    SECRET_ENV_NAMES,
)


SHA1 = re.compile(r"[0-9a-f]{40}\Z")


def require_protected_secrets() -> None:
    missing = [name for name in SECRET_ENV_NAMES if not os.environ.get(name)]
    if missing:
        raise LiveExecutorError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations "
            "resume=populate all four protected Environment secrets without using the local account directory"
        )


def require_desktop_binding(desktop_root: Path, desktop_sha: str) -> None:
    if SHA1.fullmatch(desktop_sha) is None:
        raise LiveExecutorError(
            "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
            "reason=desktop_source_invalid "
            "resume=bind the reviewed Desktop commit"
        )
    try:
        actual = subprocess.check_output(
            ["git", "-C", str(desktop_root), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
            env={key: value for key, value in os.environ.items() if not key in SECRET_ENV_NAMES},
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise LiveExecutorError(
            "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
            "reason=desktop_checkout_unavailable "
            "resume=checkout the reviewed Desktop commit"
        ) from error
    if actual != desktop_sha:
        raise LiveExecutorError(
            "[blocked] OID_DRIFT owner=Operations "
            "reason=desktop_checkout_mismatch "
            "resume=checkout the exact reviewed Desktop SHA"
        )


def parse_args(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--cleanup-receipt", type=Path, required=True)
    parser.add_argument("--desktop-log", type=Path, required=True)
    parser.add_argument("--xcodebuild-log", type=Path, required=True)
    parser.add_argument("--client-state", type=Path, required=True)
    parser.add_argument("--desktop-root", type=Path, required=True)
    parser.add_argument("--desktop-sha", required=True)
    parser.add_argument("--simulator-udid", required=True)
    parser.add_argument("--coordination-root", required=True)
    parser.add_argument("--ios-project", type=Path, required=True)
    parser.add_argument("--scheme", default="FloorpNotesSyncG5")
    parser.add_argument("--configuration", default="FloorpRelease")
    parser.add_argument("--destination", required=True)
    parser.add_argument("--test-plan", default="FloorpNotesSyncG5")
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--source-packages", type=Path, required=True)
    parser.add_argument("--xcconfig", type=Path, required=True)
    parser.add_argument("--result-bundle", type=Path, required=True)
    return parser.parse_args(arguments)


def build_xcodebuild_command(args: argparse.Namespace) -> list[str]:
    selectors = getattr(args, "selectors", None) or [
        "XCUITests/FloorpNotesSyncActualG5TwoClientTests/testActualG5TwoClientProductionMatrix"
    ]
    return [
        "xcodebuild",
        "test",
        "-quiet",
        "-project",
        str(args.ios_project),
        "-scheme",
        args.scheme,
        "-configuration",
        args.configuration,
        "-destination",
        args.destination,
        "-testPlan",
        args.test_plan,
        *[f"-only-testing:{selector}" for selector in selectors],
        "-resultBundlePath",
        str(args.result_bundle),
        "-derivedDataPath",
        str(args.derived_data),
        "-clonedSourcePackagesDirPath",
        str(args.source_packages),
        "-disableAutomaticPackageResolution",
        "-onlyUsePackageVersionsFromResolvedFile",
        "-skipMacroValidation",
        "-parallel-testing-enabled",
        "NO",
        "-xcconfig",
        str(args.xcconfig),
        "COMPILER_INDEX_STORE_ENABLE=NO",
        "CODE_SIGN_IDENTITY=",
        "CODE_SIGNING_REQUIRED=NO",
        "CODE_SIGNING_ALLOWED=NO",
    ]


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments)
    try:
        require_protected_secrets()
        require_desktop_binding(args.desktop_root, args.desktop_sha)
        args.client_state.mkdir(mode=0o700, parents=True, exist_ok=False)
        executor_environment = {
            "FLOORP_NOTES_SYNC_PRODUCTION_QA": "1",
            "FLOORP_NOTES_SYNC_G5_RUN": "1",
            "FLOORP_NOTES_SYNC_CAPABILITY_VERSION": "todo20-production-sync-integrity-v1",
            "FLOORP_NOTES_SYNC_BUILD_NUMBER": "4",
            "FLOORP_NOTES_SYNC_COORDINATION_ROOT": args.coordination_root,
        }
        executor_environment.update(
            {name: os.environ[name] for name in SECRET_ENV_NAMES}
        )
        executor = LiveExecutor(
            desktop_root=args.desktop_root.resolve(),
            simulator_udid=args.simulator_udid,
            coordination_root=args.coordination_root,
            xcodebuild_command=build_xcodebuild_command(args),
            xcodebuild_environment=executor_environment,
            paths=LiveRunPaths(
                summary=args.summary.resolve(),
                cleanup_receipt=args.cleanup_receipt.resolve(),
                desktop_log=args.desktop_log.resolve(),
                xcodebuild_log=args.xcodebuild_log.resolve(),
                client_state=args.client_state.resolve(),
            ),
        )
        executor.run()
    except (LiveExecutorError, OSError, subprocess.CalledProcessError) as error:
        message = str(error)
        print(message, file=sys.stderr)
        return 78 if message.startswith("[blocked]") else 2
    print('{\"status\":\"live-production-qa-summary-created\"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
