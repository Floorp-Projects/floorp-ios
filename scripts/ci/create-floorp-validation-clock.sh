#!/bin/bash -p
set -euo pipefail

exec /usr/bin/python3 -I -S - "$@" <<'PY'
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from email.utils import format_datetime, parsedate_to_datetime
from pathlib import Path
from typing import Any


EXPECTED_REPOSITORY = "Floorp-Projects/floorp-ios"
EXPECTED_WORKFLOW_FILE = "floorp-notes-sync-validation-clock.yml"
EXPECTED_WORKFLOW_PATH = f".github/workflows/{EXPECTED_WORKFLOW_FILE}"
EXPECTED_GITHUB_HOST = "github.com"
PRODUCTION_GH_BIN = Path("/opt/homebrew/bin/gh")
PRODUCTION_GH_SHA256 = "6a2ab5fa89553eac1f0df50a26a5eaeea9a665d8971f5a51b32487b72c708f5c"
PRODUCTION_GH_SIZE = 38_983_666
TRUSTED_GH_DIRECTORIES: list[tempfile.TemporaryDirectory[str]] = []
UNSAFE_GITHUB_ENVIRONMENT = frozenset(
    {
        "ALL_PROXY",
        "CURL_CA_BUNDLE",
        "GH_CONFIG_DIR",
        "GH_HOST",
        "GH_HTTP_UNIX_SOCKET",
        "GITHUB_API_URL",
        "GITHUB_SERVER_URL",
        "GIT_SSL_CAINFO",
        "GIT_SSL_CAPATH",
        "GIT_SSL_NO_VERIFY",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "NO_PROXY",
        "NODE_EXTRA_CA_CERTS",
        "REQUESTS_CA_BUNDLE",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "all_proxy",
        "curl_ca_bundle",
        "gh_config_dir",
        "gh_host",
        "gh_http_unix_socket",
        "github_api_url",
        "github_server_url",
        "git_ssl_cainfo",
        "git_ssl_capath",
        "git_ssl_no_verify",
        "https_proxy",
        "http_proxy",
        "no_proxy",
        "node_extra_ca_certs",
        "requests_ca_bundle",
        "ssl_cert_dir",
        "ssl_cert_file",
    }
)
PRODUCTION_GH_ENVIRONMENT = (
    "HOME",
    "USER",
    "LOGNAME",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "GH_TOKEN",
    "GITHUB_TOKEN",
)


class ClockError(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ClockError(message)


def select_gh_executable(test_gh_bin: Path | None) -> Path:
    if test_gh_bin is not None:
        check(test_gh_bin.is_absolute(), "test GitHub CLI path must be absolute")
        try:
            selected = test_gh_bin.resolve(strict=True)
        except OSError as error:
            raise ClockError("test GitHub CLI executable is unavailable") from error
        check(
            selected != PRODUCTION_GH_BIN.resolve(strict=False),
            "test GitHub CLI injection requires a non-production executable path",
        )
        check(selected.is_file() and os.access(selected, os.X_OK), "trusted GitHub CLI executable is unavailable")
        return selected

    try:
        source = PRODUCTION_GH_BIN.resolve(strict=True)
        source_fd = os.open(
            source,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as error:
        raise ClockError("trusted GitHub CLI executable is unavailable") from error
    temporary = tempfile.TemporaryDirectory(prefix="floorp-trusted-gh-")
    target = Path(temporary.name) / "gh"
    target_fd = -1
    try:
        before = os.fstat(source_fd)
        check(stat.S_ISREG(before.st_mode), "trusted GitHub CLI is not a regular file")
        check(before.st_size == PRODUCTION_GH_SIZE, "trusted GitHub CLI size mismatch")
        check(before.st_mode & 0o222 == 0, "trusted GitHub CLI source is writable")
        target_fd = os.open(
            target,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o500,
        )
        digest = hashlib.sha256()
        size = 0
        while chunk := os.read(source_fd, 1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
            offset = 0
            while offset < len(chunk):
                offset += os.write(target_fd, chunk[offset:])
        after = os.fstat(source_fd)
        check(
            (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
            "trusted GitHub CLI changed while it was copied",
        )
        check(size == PRODUCTION_GH_SIZE, "trusted GitHub CLI copied size mismatch")
        check(digest.hexdigest() == PRODUCTION_GH_SHA256, "trusted GitHub CLI digest mismatch")
        os.fsync(target_fd)
        os.fchmod(target_fd, 0o500)
    finally:
        os.close(source_fd)
        if target_fd >= 0:
            os.close(target_fd)
    TRUSTED_GH_DIRECTORIES.append(temporary)
    return target


def hardened_gh_environment(
    source: dict[str, str],
    *,
    include_test_controls: bool = False,
) -> dict[str, str]:
    unsafe = sorted(name for name in UNSAFE_GITHUB_ENVIRONMENT if source.get(name))
    check(not unsafe, f"unsafe GitHub network environment is set: {', '.join(unsafe)}")
    environment = {
        name: source[name]
        for name in PRODUCTION_GH_ENVIRONMENT
        if source.get(name)
    }
    if include_test_controls:
        environment.update(
            {
                name: value
                for name, value in source.items()
                if name.startswith("MOCK_")
            }
        )
    environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    environment["GH_PROMPT_DISABLED"] = "1"
    return environment


def run_gh_api(gh_bin: Path, environment: dict[str, str], arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(gh_bin), "api", "--hostname", EXPECTED_GITHUB_HOST, *arguments],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
        timeout=30,
        env=environment,
    )


def gh_json(gh_bin: Path, environment: dict[str, str], arguments: list[str]) -> Any:
    result = run_gh_api(gh_bin, environment, arguments)
    if result.returncode != 0:
        raise ClockError("GitHub API call failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ClockError("GitHub API returned malformed JSON") from error


def gh_dispatch(
    gh_bin: Path,
    environment: dict[str, str],
    repository: str,
    workflow: str,
    reference: str,
    nonce: str,
) -> None:
    result = run_gh_api(
        gh_bin,
        environment,
        [
            "--method",
            "POST",
            f"repos/{repository}/actions/workflows/{workflow}/dispatches",
            "-f",
            f"ref={reference}",
            "-f",
            f"inputs[clock_nonce]={nonce}",
        ],
    )
    if result.returncode != 0:
        raise ClockError("validation-clock dispatch failed")


def gh_json_with_date(gh_bin: Path, environment: dict[str, str], endpoint: str) -> tuple[Any, str]:
    result = run_gh_api(gh_bin, environment, ["--include", endpoint])
    if result.returncode != 0:
        raise ClockError("terminal run capture failed")
    normalized = result.stdout.replace("\r\n", "\n")
    sections = normalized.split("\n\n")
    check(len(sections) >= 2, "terminal run response omitted HTTP headers")
    body = sections[-1].strip()
    header_lines = "\n\n".join(sections[:-1]).splitlines()
    dates = [line.split(":", 1)[1].strip() for line in header_lines if line.lower().startswith("date:")]
    check(len(dates) == 1, "terminal run response must contain exactly one GitHub HTTP Date")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as error:
        raise ClockError("terminal run response contained malformed JSON") from error
    return payload, dates[0]


def parse_timestamp(value: str, label: str) -> datetime:
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError) as error:
        raise ClockError(f"{label} is not whole-second RFC 3339 UTC") from error
    return parsed


def parse_http_date(value: str) -> datetime:
    try:
        parsed = parsedate_to_datetime(value)
    except (TypeError, ValueError) as error:
        raise ClockError("GitHub HTTP Date is malformed") from error
    check(parsed is not None and parsed.tzinfo is not None, "GitHub HTTP Date has no timezone")
    normalized = parsed.astimezone(timezone.utc).replace(microsecond=0)
    check(format_datetime(normalized, usegmt=True) == value, "GitHub HTTP Date is not canonical")
    return normalized


def repository_name(run: dict[str, Any]) -> str:
    repository = run.get("repository")
    if isinstance(repository, dict):
        return repository.get("full_name", "")
    return repository if isinstance(repository, str) else ""


def workflow_path(run: dict[str, Any]) -> str:
    path = run.get("path")
    if not isinstance(path, str):
        return ""
    return path.split("@", 1)[0]


def wait_for_run(
    gh_bin: Path,
    environment: dict[str, str],
    repository: str,
    workflow: str,
    nonce: str,
    timeout_seconds: int,
    poll_interval_seconds: float,
) -> dict[str, Any]:
    expected_title = f"Floorp Notes Sync validation clock {nonce}"
    deadline = time.monotonic() + timeout_seconds
    endpoint = f"repos/{repository}/actions/workflows/{workflow}/runs"
    while True:
        listing = gh_json(
            gh_bin,
            environment,
            ["--method", "GET", endpoint, "-f", "event=workflow_dispatch", "-f", "per_page=100"],
        )
        check(isinstance(listing, dict), "workflow-runs response is not an object")
        runs = listing.get("workflow_runs")
        check(isinstance(runs, list), "workflow-runs response omitted workflow_runs")
        matches = [run for run in runs if isinstance(run, dict) and run.get("display_title") == expected_title]
        check(len(matches) <= 1, "dispatch nonce matched multiple workflow runs")
        if matches:
            run = matches[0]
            if run.get("status") == "completed":
                return run
        if time.monotonic() >= deadline:
            raise ClockError("timed out waiting for validation-clock run")
        time.sleep(poll_interval_seconds)


def matching_runs(
    gh_bin: Path,
    environment: dict[str, str],
    repository: str,
    workflow: str,
    nonce: str,
) -> list[dict[str, Any]]:
    endpoint = f"repos/{repository}/actions/workflows/{workflow}/runs"
    listing = gh_json(
        gh_bin,
        environment,
        ["--method", "GET", endpoint, "-f", "event=workflow_dispatch", "-f", "per_page=100"],
    )
    check(isinstance(listing, dict), "workflow-runs response is not an object")
    runs = listing.get("workflow_runs")
    check(isinstance(runs, list), "workflow-runs response omitted workflow_runs")
    expected_title = f"Floorp Notes Sync validation clock {nonce}"
    matches = [run for run in runs if isinstance(run, dict) and run.get("display_title") == expected_title]
    check(len(matches) <= 1, "dispatch nonce matched multiple workflow runs")
    return matches


def normalize_job(job: dict[str, Any]) -> dict[str, Any]:
    return {
        "completed_at": job.get("completed_at"),
        "conclusion": job.get("conclusion"),
        "id": job.get("id"),
        "name": job.get("name"),
        "run_attempt": job.get("run_attempt"),
        "run_id": job.get("run_id"),
        "started_at": job.get("started_at"),
        "status": job.get("status"),
    }


def validate_terminal_run(
    run: dict[str, Any],
    jobs: list[dict[str, Any]],
    repository: str,
    expected_head: str,
    http_date: str,
    max_age_seconds: int,
) -> None:
    run_id = run.get("id")
    attempt = run.get("run_attempt")
    check(isinstance(run_id, int) and run_id > 0, "run ID is missing")
    check(isinstance(attempt, int) and attempt > 0, "run attempt is missing")
    check(repository_name(run) == repository, "run repository mismatch")
    check(workflow_path(run) == EXPECTED_WORKFLOW_PATH, "run workflow path mismatch")
    check(run.get("event") == "workflow_dispatch", "run event is not workflow_dispatch")
    check(run.get("head_sha") == expected_head, "run head does not match the expected commit")
    check(run.get("status") == "completed", "run is nonterminal")
    check(run.get("conclusion") == "success", "run did not succeed")
    check(
        run.get("url") == f"https://api.github.com/repos/{repository}/actions/runs/{run_id}",
        "run API URL mismatch",
    )
    check(
        run.get("html_url") == f"https://github.com/{repository}/actions/runs/{run_id}",
        "run HTML URL mismatch",
    )
    trusted_now = parse_http_date(http_date)
    updated_at = parse_timestamp(run.get("updated_at"), "run.updated_at")
    created_at = parse_timestamp(run.get("created_at"), "run.created_at")
    check(created_at <= updated_at, "run updated before it was created")
    skew = (updated_at - trusted_now).total_seconds()
    check(
        -max_age_seconds <= skew <= max_age_seconds,
        "run is stale or more than five minutes in the future",
    )
    check(len(jobs) == 1, "run must contain exactly one validation-clock job")
    check(jobs[0].get("name") == "validation-clock", "run contains an unexpected job")
    job_ids: set[int] = set()
    for job in jobs:
        job_id = job.get("id")
        check(isinstance(job_id, int) and job_id > 0, "job ID is missing")
        check(job_id not in job_ids, "duplicate job ID")
        job_ids.add(job_id)
        check(job.get("run_id") == run_id, "job run ID mismatch")
        check(job.get("run_attempt") == attempt, "job run attempt mismatch")
        check(job.get("status") == "completed", "job is nonterminal")
        check(job.get("conclusion") == "success", "job did not succeed")
        started_at = parse_timestamp(job.get("started_at"), "job.started_at")
        completed_at = parse_timestamp(job.get("completed_at"), "job.completed_at")
        check(started_at <= completed_at, "job completion precedes start")


def fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    temporary_descriptor, temporary_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    descriptor_is_open = True
    try:
        with os.fdopen(temporary_descriptor, "wb") as handle:
            descriptor_is_open = False
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary_name, path)
        except FileExistsError as error:
            raise ClockError("output already exists; validation-clock artifacts are append-only") from error
        fsync_directory(path.parent)
    finally:
        if descriptor_is_open:
            os.close(temporary_descriptor)
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
            fsync_directory(path.parent)


def main(
    argv: list[str] | None = None,
    *,
    test_gh_bin: Path | None = None,
    test_environment: dict[str, str] | None = None,
) -> int:
    parser = argparse.ArgumentParser(description="Dispatch and capture a trusted Floorp Notes Sync validation clock")
    parser.add_argument("--repository", required=True)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--ref")
    parser.add_argument("--max-age-seconds", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--poll-interval-seconds", type=float, default=5.0)
    parser.add_argument("--timeout-seconds", type=int, default=600)
    arguments = parser.parse_args(argv)
    try:
        check(arguments.repository == EXPECTED_REPOSITORY, "repository is not the approved floorp-ios repository")
        check(Path(arguments.workflow).name == EXPECTED_WORKFLOW_FILE, "workflow is not the approved validation clock")
        check(re.fullmatch(r"[0-9a-f]{40}", arguments.expected_head) is not None, "expected head is not a full SHA")
        check(arguments.max_age_seconds == 300, "max age must be exactly 300 seconds")
        check(arguments.poll_interval_seconds >= 0, "poll interval must not be negative")
        check(arguments.timeout_seconds > 0, "timeout must be positive")
        gh_bin = select_gh_executable(test_gh_bin)
        gh_environment = hardened_gh_environment(
            dict(os.environ) if test_environment is None else test_environment,
            include_test_controls=test_environment is not None,
        )
        check(not arguments.output.exists(), "output already exists; validation-clock artifacts are append-only")
        # Dispatch uses a Git ref; the terminal head check below binds the exact commit.
        reference = arguments.ref or "main"
        nonce_input = "\n".join(
            (
                arguments.repository,
                arguments.workflow,
                arguments.expected_head,
                str(arguments.output.resolve()),
            )
        ).encode("utf-8")
        nonce = hashlib.sha256(nonce_input).hexdigest()[:32]
        if not matching_runs(gh_bin, gh_environment, arguments.repository, arguments.workflow, nonce):
            gh_dispatch(gh_bin, gh_environment, arguments.repository, arguments.workflow, reference, nonce)
        observed = wait_for_run(
            gh_bin,
            gh_environment,
            arguments.repository,
            arguments.workflow,
            nonce,
            arguments.timeout_seconds,
            arguments.poll_interval_seconds,
        )
        observed_id = observed.get("id")
        check(isinstance(observed_id, int) and observed_id > 0, "observed run omitted ID")
        terminal, http_date = gh_json_with_date(
            gh_bin,
            gh_environment,
            f"repos/{arguments.repository}/actions/runs/{observed_id}",
        )
        check(isinstance(terminal, dict), "terminal run response is not an object")
        check(terminal.get("id") == observed_id, "terminal run ID changed")
        attempt = terminal.get("run_attempt")
        check(isinstance(attempt, int) and attempt > 0, "terminal run omitted attempt")
        jobs_response = gh_json(
            gh_bin,
            gh_environment,
            [
                "--method",
                "GET",
                f"repos/{arguments.repository}/actions/runs/{observed_id}/attempts/{attempt}/jobs",
                "-f",
                "per_page=100",
            ],
        )
        check(isinstance(jobs_response, dict), "jobs response is not an object")
        jobs = jobs_response.get("jobs")
        total_count = jobs_response.get("total_count")
        check(isinstance(jobs, list), "jobs response omitted jobs")
        check(total_count == len(jobs), "jobs response is incomplete")
        check(all(isinstance(job, dict) for job in jobs), "jobs response contains a non-object")
        validate_terminal_run(
            terminal,
            jobs,
            arguments.repository,
            arguments.expected_head,
            http_date,
            arguments.max_age_seconds,
        )
        run_id = terminal["id"]
        manifest = {
            "expected_head_sha": arguments.expected_head,
            "github_http_date": http_date,
            "jobs": [normalize_job(job) for job in jobs],
            "max_age_seconds": arguments.max_age_seconds,
            "provider": "github-actions",
            "repository": arguments.repository,
            "run": {
                "api_url": terminal["url"],
                "attempt": terminal["run_attempt"],
                "conclusion": terminal["conclusion"],
                "created_at": terminal["created_at"],
                "event": terminal["event"],
                "head_sha": terminal["head_sha"],
                "html_url": terminal["html_url"],
                "id": run_id,
                "repository": repository_name(terminal),
                "status": terminal["status"],
                "updated_at": terminal["updated_at"],
                "workflow_id": terminal["workflow_id"],
                "workflow_path": workflow_path(terminal),
            },
            "schema_version": 1,
            "workflow": {
                "id": terminal["workflow_id"],
                "path": workflow_path(terminal),
            },
        }
        write_atomic(arguments.output, manifest)
        print(f"APPROVE: captured terminal validation clock run {run_id}")
        return 0
    except ClockError as error:
        print(f"REJECT: {error}", file=sys.stderr)
        return 1
    except (OSError, subprocess.SubprocessError) as error:
        print(f"INPUT_ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
PY
