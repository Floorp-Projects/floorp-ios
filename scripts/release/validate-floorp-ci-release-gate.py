#!/usr/bin/env python3
"""Validate source-bound CI and uBO Lite acceptance evidence for release."""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


SHA1 = re.compile(r"^[0-9a-f]{40}$")
EXPECTED_WORKFLOW = ".github/workflows/ci.yml"
ACCEPTANCE_MARKER = "FLOORP_UBOL_RELEASE_GATE report"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def load_json(path: Path) -> dict:
    require(path.is_file() and not path.is_symlink(), f"run JSON is missing: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(value, dict), "run JSON must contain an object")
    return value


def one_path(root: Path, name: str, *, directory: bool) -> Path:
    matches = [
        path for path in root.rglob(name)
        if not path.is_symlink() and (path.is_dir() if directory else path.is_file())
    ]
    require(len(matches) == 1, f"expected one {name} in the CI artifact")
    return matches[0]


def validate(arguments: argparse.Namespace) -> dict:
    require(arguments.expected_run_id > 0, "CI run ID must be positive")
    require(SHA1.fullmatch(arguments.expected_head_sha) is not None,
            "expected source SHA is invalid")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
                         arguments.expected_repository) is not None,
            "expected repository is invalid")

    run = load_json(arguments.run_json)
    require(run.get("id") == arguments.expected_run_id, "CI run ID mismatch")
    require(run.get("head_sha") == arguments.expected_head_sha, "CI source SHA mismatch")
    require(run.get("head_branch") == "main", "CI run is not for main")
    require(run.get("path") == EXPECTED_WORKFLOW, "CI workflow path mismatch")
    require(run.get("status") == "completed", "CI run is not complete")
    require(run.get("conclusion") == "success", "CI run did not succeed")
    require(run.get("event") in {"push", "workflow_dispatch"},
            "CI run event is not an approved main-branch event")
    require(isinstance(run.get("run_attempt"), int) and run["run_attempt"] > 0,
            "CI run attempt is invalid")
    repository = run.get("repository", {})
    require(isinstance(repository, dict)
            and repository.get("full_name") == arguments.expected_repository,
            "CI repository mismatch")

    root = arguments.artifact_root
    require(root.is_dir() and not root.is_symlink(), "uBO acceptance artifact is missing")
    log = one_path(root, "ubol-release-acceptance.log", directory=False)
    result = one_path(root, "FloorpUBOLReleaseAcceptance.xcresult", directory=True)
    log_bytes = log.read_bytes()
    log_text = log_bytes.decode("utf-8", errors="replace")
    require(ACCEPTANCE_MARKER in log_text, "uBO acceptance completion marker is missing")
    require("** TEST SUCCEEDED **" in log_text, "uBO acceptance test did not succeed")
    require("** TEST FAILED **" not in log_text, "uBO acceptance log records a failure")

    return {
        "artifact_name": f"floorp-ubol-release-acceptance-{arguments.expected_run_id}",
        "ci_run_attempt": run.get("run_attempt"),
        "ci_run_id": arguments.expected_run_id,
        "conclusion": "success",
        "head_sha": arguments.expected_head_sha,
        "repository": arguments.expected_repository,
        "result_bundle": result.name,
        "status": "release-gate-passed",
        "ubol_acceptance_log_sha256": hashlib.sha256(log_bytes).hexdigest(),
        "workflow_path": EXPECTED_WORKFLOW,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-json", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--expected-run-id", type=int, required=True)
    parser.add_argument("--expected-head-sha", required=True)
    parser.add_argument("--expected-repository", required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        receipt = validate(arguments)
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(json.dumps(receipt, separators=(",", ":"), sort_keys=True))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
