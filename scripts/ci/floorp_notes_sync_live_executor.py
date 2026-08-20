#!/usr/bin/python3 -I
"""Real host-side coordinator for Todo 20 production Sync integrity QA.

The coordinator drives the two clients through their user interfaces:

* iOS is an XCTest actor running on the dedicated Simulator.
* Desktop is a staged Floorp build driven over Marionette.

The only cross-process data is the metadata-only coordination event schema.
This module never calls FxA or Sync APIs directly and never puts account
credentials in a command line, event, summary, or artifact.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from floorp_notes_sync_coordination import CASE_NAMES, validate_event


SECRET_ENV_NAMES = (
    "FLOORP_NOTES_SYNC_ACCOUNT_A_EMAIL",
    "FLOORP_NOTES_SYNC_ACCOUNT_A_PASSWORD",
    "FLOORP_NOTES_SYNC_ACCOUNT_B_EMAIL",
    "FLOORP_NOTES_SYNC_ACCOUNT_B_PASSWORD",
)
APPROVED_HOSTS = [
    "accounts.firefox.com",
    "api.accounts.firefox.com",
    "event-sync.services.mozilla.com",
    "oauth.accounts.firefox.com",
    "profile.accounts.firefox.com",
    "static.accounts.firefox.com",
    "sync.services.mozilla.com",
    "token.services.mozilla.com",
]
ENVIRONMENT = "floorp-notes-sync-production-qa"
REPOSITORY = "Floorp-Projects/floorp-ios"
WORKFLOW_PATH = ".github/workflows/floorp-notes-sync-production-qa.yml"
JOB_NAME = "notes-sync-production-qa"
SHA1 = re.compile(r"[0-9a-f]{40}\Z")
INVARIANT_CASES = {
    "no-data-loss": frozenset(
        {CASE_NAMES[0], CASE_NAMES[1], CASE_NAMES[4], CASE_NAMES[5], CASE_NAMES[6], CASE_NAMES[7], CASE_NAMES[8]}
    ),
    "no-duplicate-records": frozenset({CASE_NAMES[8], CASE_NAMES[10], CASE_NAMES[11]}),
    "no-incorrect-delete-or-resurrection": frozenset({CASE_NAMES[3], CASE_NAMES[5], CASE_NAMES[6]}),
    "no-account-mixing": frozenset({CASE_NAMES[9]}),
    "no-rollback-on-retry": frozenset({CASE_NAMES[5], CASE_NAMES[10], CASE_NAMES[11]}),
    "base-revision-after-confirmation-only": frozenset({CASE_NAMES[5], CASE_NAMES[11]}),
}
CASE_BLOCKERS = {
    CASE_NAMES[5]: (
        "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
        "reason=upload_save_commit_failure_observation_missing "
        "resume=provide deterministic UI-level upload-save-commit fault injection and retry evidence"
    ),
    CASE_NAMES[7]: (
        "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
        "reason=legacy_client_artifact_and_driver_missing "
        "resume=provide a reproducible pinned legacy client, isolated profile, and reviewed UI driver"
    ),
    CASE_NAMES[11]: (
        "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
        "reason=base_revision_observation_missing "
        "resume=provide metadata-only base/revision observation before failure and after authoritative commit"
    ),
}


class LiveExecutorError(RuntimeError):
    """A live execution or cleanup boundary was not proven."""


def canonical_bytes(value: dict[str, Any]) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        + b"\n"
    )


def private_environment() -> dict[str, str]:
    environment = dict(os.environ)
    for name in SECRET_ENV_NAMES:
        environment.pop(name, None)
    return environment


def source_from_environment() -> dict[str, Any]:
    required = (
        "GITHUB_ACTOR",
        "GITHUB_EVENT_NAME",
        "GITHUB_JOB",
        "GITHUB_REF",
        "GITHUB_REPOSITORY",
        "GITHUB_RUN_ATTEMPT",
        "GITHUB_RUN_ID",
        "GITHUB_SHA",
        "GITHUB_WORKFLOW_REF",
    )
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise LiveExecutorError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations "
            "reason=execution_context_missing "
            "resume=run only inside the protected workflow"
        )
    try:
        source = {
            "event": os.environ["GITHUB_EVENT_NAME"],
            "head_sha": os.environ["GITHUB_SHA"],
            "job_name": os.environ["GITHUB_JOB"],
            "repository": os.environ["GITHUB_REPOSITORY"],
            "workflow_path": WORKFLOW_PATH,
            "workflow_run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
            "workflow_run_id": int(os.environ["GITHUB_RUN_ID"]),
        }
    except (KeyError, ValueError) as error:
        raise LiveExecutorError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations "
            "reason=execution_context_invalid "
            "resume=provide numeric immutable workflow metadata"
        ) from error
    if (
        source["event"] != "workflow_dispatch"
        or os.environ["GITHUB_REF"] != "refs/heads/main"
        or source["job_name"] != JOB_NAME
        or source["repository"] != REPOSITORY
        or not SHA1.fullmatch(source["head_sha"])
        or not os.environ["GITHUB_WORKFLOW_REF"].startswith(
            f"{REPOSITORY}/{WORKFLOW_PATH}@"
        )
    ):
        raise LiveExecutorError(
            "[blocked] AUTHORIZATION_MISSING owner=Operations "
            "reason=execution_context_invalid "
            "resume=bind the run to the canonical manual workflow"
        )
    return source


class SimulatorCoordination:
    """Metadata event exchange through the dedicated Simulator's /tmp."""

    def __init__(self, udid: str, root: str):
        if not udid or not root.startswith("/tmp/"):
            raise LiveExecutorError(
                "[blocked] AUTHORIZATION_MISSING owner=Operations "
                "reason=simulator_coordination_scope_invalid "
                "resume=use a dedicated Simulator /tmp root"
            )
        self.udid = udid
        self.root = root.rstrip("/")
        self.events = f"{self.root}/events"

    def _spawn(
        self,
        command: list[str],
        *,
        input_bytes: bytes | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ["xcrun", "simctl", "spawn", self.udid, *command],
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=private_environment(),
            check=check,
        )

    def prepare(self) -> None:
        script = (
            f"umask 077; mkdir -p {shlex.quote(self.events)}; "
            f"chmod 700 {shlex.quote(self.root)} {shlex.quote(self.events)}"
        )
        self._spawn(["/bin/sh", "-c", script])

    def _path(self, actor: str, sequence: int) -> str:
        if actor not in {"desktop", "mobile"} or sequence <= 0:
            raise LiveExecutorError("invalid coordination event path")
        return f"{self.events}/{actor}-{sequence:04d}.json"

    def write(
        self,
        *,
        actor: str,
        case_name: str,
        phase: str,
        outcome: str,
        sequence: int,
    ) -> None:
        event = validate_event(
            {
                "actor": actor,
                "case_name": case_name,
                "outcome": outcome,
                "phase": phase,
                "schema_version": 1,
                "sequence": sequence,
            }
        )
        payload = canonical_bytes(event).decode("utf-8")
        path = self._path(actor, sequence)
        script = (
            f"umask 077; set -C; "
            f"printf %s {shlex.quote(payload)} > {shlex.quote(path)}; "
            f"chmod 600 {shlex.quote(path)}"
        )
        result = self._spawn(["/bin/sh", "-c", script], check=False)
        if result.returncode != 0:
            raise LiveExecutorError("desktop coordination event publish failed")

    def read(self, *, actor: str, sequence: int) -> dict[str, Any] | None:
        path = self._path(actor, sequence)
        result = self._spawn(["/bin/cat", path], check=False)
        if result.returncode != 0:
            return None
        try:
            value = json.loads(result.stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise LiveExecutorError("coordination event is not JSON") from error
        if result.stdout != canonical_bytes(value):
            raise LiveExecutorError("coordination event is not canonical")
        return validate_event(value)

    def wait(
        self,
        *,
        actor: str,
        sequence: int,
        timeout_seconds: float = 240,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            event = self.read(actor=actor, sequence=sequence)
            if event is not None:
                return event
            time.sleep(0.5)
        raise LiveExecutorError("coordination event timed out")

    def remove(self) -> bool:
        removed = self._spawn(["/bin/rm", "-rf", self.root], check=False)
        if removed.returncode != 0:
            return False
        verification = self._spawn(
            [
                "/bin/sh",
                "-c",
                f"test ! -e {shlex.quote(self.root)} && test ! -L {shlex.quote(self.root)}",
            ],
            check=False,
        )
        return verification.returncode == 0


class MarionetteClient:
    """Small protocol-v3 client with no logging of command arguments."""

    def __init__(self, port: int):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=30)
        self.socket.settimeout(30)
        self.next_id = 0
        handshake = self._read_packet()
        if not isinstance(handshake, dict) or handshake.get("marionetteProtocol") != 3:
            self.socket.close()
            raise LiveExecutorError("Marionette protocol handshake rejected")
        self._send("WebDriver:NewSession", {})

    def _read_exact(self, length: int) -> bytes:
        chunks: list[bytes] = []
        remaining = length
        while remaining:
            chunk = self.socket.recv(remaining)
            if not chunk:
                raise LiveExecutorError("Marionette connection closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _read_packet(self) -> Any:
        prefix = bytearray()
        while True:
            byte = self.socket.recv(1)
            if not byte:
                raise LiveExecutorError("Marionette packet prefix closed")
            if byte == b":":
                break
            prefix.extend(byte)
        try:
            length = int(prefix.decode("ascii"))
        except ValueError as error:
            raise LiveExecutorError("Marionette packet length is invalid") from error
        return json.loads(self._read_exact(length).decode("utf-8"))

    def _send(self, command: str, params: dict[str, Any]) -> Any:
        message_id = self.next_id
        self.next_id += 1
        payload = json.dumps([0, message_id, command, params], separators=(",", ":")).encode(
            "utf-8"
        )
        self.socket.sendall(str(len(payload)).encode("ascii") + b":" + payload)
        response = self._read_packet()
        if (
            not isinstance(response, list)
            or len(response) != 4
            or response[0] != 1
        ):
            raise LiveExecutorError("Marionette response is malformed")
        if response[2]:
            error = response[2]
            raise LiveExecutorError(
                f"Marionette command failed: {error.get('error', 'unknown')}"
            )
        return response[3]

    def context(self, value: str) -> None:
        self._send("Marionette:SetContext", {"value": value})

    def navigate(self, url: str) -> None:
        self._send("WebDriver:Navigate", {"url": url})

    def execute(self, script: str, args: list[Any] | None = None) -> Any:
        result = self._send(
            "WebDriver:ExecuteScript",
            {"script": script, "args": args or []},
        )
        return result.get("value") if isinstance(result, dict) else None

    def close(self) -> None:
        try:
            self._send("WebDriver:DeleteSession", {})
        except Exception:
            pass
        try:
            self.socket.close()
        except OSError:
            pass


class DesktopNotesClient:
    """UI-only Desktop Notes and FxA actor."""

    def __init__(self, browser: MarionetteClient, observed_hosts: set[str]):
        self.browser = browser
        self.observed_hosts = observed_hosts

    def _assert_page_scope(self) -> None:
        href = self.browser.execute("return window.location.href;")
        if not isinstance(href, str) or not href:
            raise LiveExecutorError("Desktop page URL was not observable")
        parsed = urlparse(href)
        if parsed.scheme in {"about", "chrome", "resource", "file", "data", "blob"}:
            return
        if parsed.scheme != "https" or parsed.hostname not in APPROVED_HOSTS:
            raise LiveExecutorError(
                "[blocked] AUTHORIZATION_MISSING owner=Operations "
                "reason=unapproved_desktop_destination "
                "resume=restrict the FxA/Sync UI flow to the approved HTTPS hosts"
            )
        try:
            port = parsed.port
        except ValueError as error:
            raise LiveExecutorError(
                "[blocked] AUTHORIZATION_MISSING owner=Operations reason=invalid_desktop_destination"
            ) from error
        if port not in {None, 443}:
            raise LiveExecutorError("[blocked] AUTHORIZATION_MISSING owner=Operations reason=non_tls_desktop_destination")
        self.observed_hosts.add(parsed.hostname)

    def _wait(self, script: str, timeout: float = 180) -> Any:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self._assert_page_scope()
            result = self.browser.execute(script)
            if result:
                return result
            time.sleep(0.5)
        raise LiveExecutorError("Desktop UI condition timed out")

    def _click_text(self, pattern: str) -> bool:
        return bool(
            self.browser.execute(
                """
                const pattern = new RegExp(arguments[0], "i");
                const nodes = [...document.querySelectorAll("button,a,input[type=submit]")];
                const node = nodes.find((candidate) => pattern.test(
                  String(candidate.textContent || "") + " " +
                  String(candidate.getAttribute("aria-label") || "") + " " +
                  String(candidate.getAttribute("data-l10n-id") || "")
                ));
                if (!node) return false;
                node.click();
                return true;
                """,
                [pattern],
            )
        )

    def sign_in(self, email: str, password: str) -> None:
        self.browser.context("content")
        self.browser.navigate("about:preferences#sync")
        self._assert_page_scope()
        self._wait(
            """
            return document.readyState === "complete" ||
              document.querySelector("button,a,input");
            """,
            timeout=60,
        )
        if not self._wait_for_selector("input[type=email]", timeout=60):
            if not self._click_text("sign up|sign in|connect|account"):
                raise LiveExecutorError("Desktop FxA sign-in control is unavailable")
            if not self._wait_for_selector("input[type=email]", timeout=120):
                raise LiveExecutorError("Desktop FxA email field is unavailable")
        self._set_value("input[type=email]", email)
        if not self._click_text("continue|sign up|sign in|next"):
            raise LiveExecutorError("Desktop FxA email submit control is unavailable")
        if not self._wait_for_selector("input[type=password]", timeout=120):
            raise LiveExecutorError("Desktop FxA password field is unavailable")
        self._set_value("input[type=password]", password)
        if not self._click_text("sign in|log in|continue|next"):
            raise LiveExecutorError("Desktop FxA password submit control is unavailable")
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if not self._has_selector("input[type=password]"):
                return
            time.sleep(1)
        raise LiveExecutorError(
            "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
            "reason=FxA_UI_AUTHORIZATION_PENDING "
            "resume=complete the disposable account's production FxA authorization flow"
        )

    def sign_out(self) -> bool:
        self.browser.navigate("about:preferences#sync")
        self.browser.context("content")
        self._assert_page_scope()
        if not self._click_text("disconnect|sign out|log out"):
            return False
        try:
            self._wait(
                """
                return !/disconnect|sign out|log out/i.test(
                  document.body?.innerText || ""
                );
                """,
                timeout=60,
            )
            return True
        except LiveExecutorError:
            return False

    def _has_selector(self, selector: str) -> bool:
        return bool(
            self.browser.execute(
                "return Boolean(document.querySelector(arguments[0]));",
                [selector],
            )
        )

    def _wait_for_selector(self, selector: str, timeout: float = 180) -> bool:
        try:
            self._wait(
                "return Boolean(document.querySelector(arguments[0]));",
                timeout=timeout,
            )
            return True
        except LiveExecutorError:
            return False

    def _set_value(self, selector: str, value: str) -> None:
        result = self.browser.execute(
            """
            const element = document.querySelector(arguments[0]);
            if (!element) return false;
            const prototype = element instanceof HTMLInputElement
              ? HTMLInputElement.prototype
              : HTMLTextAreaElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
            if (!setter) return false;
            setter.call(element, arguments[1]);
            element.dispatchEvent(new Event("input", {bubbles: true}));
            element.dispatchEvent(new Event("change", {bubbles: true}));
            return true;
            """,
            [selector, value],
        )
        if result is not True:
            raise LiveExecutorError("Desktop UI input control is unavailable")

    def ensure_notes(self) -> None:
        self.browser.navigate("chrome://noraneko-notes/content/index.html")
        self.browser.context("content")
        self._assert_page_scope()
        if not self._wait_for_selector('[data-testid="notes-search"]', timeout=120):
            raise LiveExecutorError("Desktop Notes UI did not load")

    def _set_search(self, title: str) -> None:
        self.ensure_notes()
        self._set_value('[data-testid="notes-search"]', title)

    def row_count(self, title: str) -> int:
        self._set_search(title)
        result = self.browser.execute(
            'return document.querySelectorAll(\'[data-testid="notes-row"]\').length;'
        )
        if not isinstance(result, int):
            raise LiveExecutorError("Desktop Notes row count was not observable")
        return result

    def create(self, title: str, body: str) -> None:
        self.ensure_notes()
        if not self.browser.execute(
            'return Boolean(document.querySelector(\'[data-testid="notes-add"]\'));'
        ):
            raise LiveExecutorError("Desktop Notes create control is unavailable")
        self.browser.execute(
            'document.querySelector(\'[data-testid="notes-add"]\').click();'
        )
        if not self._wait_for_selector('[data-testid="notes-title"]', timeout=30):
            raise LiveExecutorError("Desktop Notes title editor is unavailable")
        self._set_value('[data-testid="notes-title"]', title)
        result = self.browser.execute(
            """
            const body = document.querySelector(
              '[data-testid="notes-body"] [contenteditable="true"]'
            );
            if (!body) return false;
            body.focus();
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(body);
            selection.removeAllRanges();
            selection.addRange(range);
            document.execCommand("insertText", false, arguments[0]);
            body.dispatchEvent(new InputEvent("input", {
              bubbles: true,
              inputType: "insertText",
              data: arguments[0],
            }));
            return true;
            """,
            [body],
        )
        if result is not True:
            raise LiveExecutorError("Desktop Notes body editor is unavailable")
        self.browser.execute("document.body.click();")
        time.sleep(2)
        if self.row_count(title) != 1:
            raise LiveExecutorError("Desktop Notes create was not observable")

    def edit(self, title: str, suffix: str) -> None:
        if self.row_count(title) != 1:
            raise LiveExecutorError("Desktop Notes edit target is not unique")
        self.browser.execute(
            'document.querySelector(\'[data-testid="notes-row"]\').click();'
        )
        if not self._wait_for_selector('[data-testid="notes-body"]', timeout=30):
            raise LiveExecutorError("Desktop Notes body editor is unavailable")
        result = self.browser.execute(
            """
            const body = document.querySelector(
              '[data-testid="notes-body"] [contenteditable="true"]'
            );
            if (!body) return false;
            body.focus();
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(body);
            range.collapse(false);
            selection.removeAllRanges();
            selection.addRange(range);
            document.execCommand("insertText", false, arguments[0]);
            body.dispatchEvent(new InputEvent("input", {
              bubbles: true,
              inputType: "insertText",
              data: arguments[0],
            }));
            return true;
            """,
            [suffix],
        )
        if result is not True:
            raise LiveExecutorError("Desktop Notes edit body was not writable")
        self.browser.execute("document.body.click();")
        time.sleep(2)

    def delete(self, title: str) -> None:
        if self.row_count(title) != 1:
            raise LiveExecutorError("Desktop Notes delete target is not unique")
        result = self.browser.execute(
            """
            const row = document.querySelector('[data-testid="notes-row"]');
            const button = row?.querySelector('[data-testid="notes-delete"]');
            if (!button) return false;
            button.click();
            return true;
            """
        )
        if result is not True:
            raise LiveExecutorError("Desktop Notes delete control is unavailable")
        if not self._wait_for_selector('[data-testid="notes-delete-confirm"]', timeout=30):
            raise LiveExecutorError("Desktop Notes delete confirmation is unavailable")
        self.browser.execute(
            'document.querySelector(\'[data-testid="notes-delete-confirm"]\').click();'
        )
        time.sleep(2)
        if self.row_count(title) != 0:
            raise LiveExecutorError("Desktop Notes delete was not observed")

    def sync_now(self) -> None:
        self.browser.navigate("about:preferences#sync")
        self.browser.context("content")
        self._wait_for_selector("button", timeout=60)
        if not self._click_text("sync now"):
            raise LiveExecutorError("Desktop Sync Now control is unavailable")
        time.sleep(3)

    def delete_account(self, password: str) -> bool:
        """Attempt account deletion through the authenticated FxA web UI."""
        self.browser.navigate("https://accounts.firefox.com/settings")
        self.browser.context("content")
        self._assert_page_scope()
        if not self._wait_for_selector("body", timeout=60):
            return False
        if not self._click_text("delete account|delete your account"):
            return False
        if self._has_selector("input[type=password]"):
            self._set_value("input[type=password]", password)
        if not self._click_text("delete account|delete|confirm"):
            return False
        try:
            self._wait(
                """
                return /account[^.]*deleted|your account[^.]*deleted/i.test(
                  document.body?.innerText || ""
                );
                """,
                timeout=120,
            )
            return True
        except LiveExecutorError:
            return False


@dataclass
class LiveRunPaths:
    summary: Path
    cleanup_receipt: Path
    desktop_log: Path
    xcodebuild_log: Path
    client_state: Path


class LiveExecutor:
    def __init__(
        self,
        *,
        desktop_root: Path,
        simulator_udid: str,
        coordination_root: str,
        xcodebuild_command: list[str],
        xcodebuild_environment: dict[str, str],
        paths: LiveRunPaths,
    ):
        self.desktop_root = desktop_root
        self.simulator_udid = simulator_udid
        self.coordination = SimulatorCoordination(simulator_udid, coordination_root)
        self.xcodebuild_command = xcodebuild_command
        self.xcodebuild_environment = xcodebuild_environment
        self.paths = paths
        self.desktop_process: subprocess.Popen[bytes] | None = None
        self.desktop: DesktopNotesClient | None = None
        self.test_process: subprocess.Popen[bytes] | None = None
        self.source = source_from_environment()
        self.observed_cases: list[dict[str, Any]] = []
        self.observed_hosts: set[str] = set()

    def _start_desktop(self) -> None:
        self.paths.desktop_log.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        log = self.paths.desktop_log.open("xb")
        environment = private_environment()
        environment["CI"] = "true"
        self.desktop_process = subprocess.Popen(
            ["deno", "task", "feles-build", "stage", "--marionette"],
            cwd=self.desktop_root,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        port_file = self.desktop_root / "_dist" / "marionette-port.txt"
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            if self.desktop_process.poll() is not None:
                raise LiveExecutorError("Desktop staged build exited before Marionette")
            if port_file.is_file():
                try:
                    port = int(port_file.read_text().strip())
                except ValueError:
                    port = 0
                if 1024 <= port <= 65535:
                    for _ in range(10):
                        try:
                            self.desktop = DesktopNotesClient(
                                MarionetteClient(port),
                                self.observed_hosts,
                            )
                            return
                        except (OSError, LiveExecutorError):
                            time.sleep(1)
            time.sleep(1)
        raise LiveExecutorError(
            "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
            "reason=desktop_marionette_unavailable "
            "resume=provide a staged Desktop build with a bounded Marionette endpoint"
        )

    def _start_test(self) -> None:
        self.paths.xcodebuild_log.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        log = self.paths.xcodebuild_log.open("xb")
        environment = private_environment()
        environment.update(self.xcodebuild_environment)
        self.test_process = subprocess.Popen(
            self.xcodebuild_command,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
        )

    def _handle_case(self, spec: Any) -> None:
        blocker = CASE_BLOCKERS.get(spec.name)
        if blocker is not None:
            self.coordination.write(
                actor="desktop",
                case_name=spec.name,
                phase="ack",
                outcome="failed",
                sequence=spec.ack_sequence,
            )
            raise LiveExecutorError(blocker)
        assert self.desktop is not None
        if spec.name == CASE_NAMES[0]:
            self.desktop.create(spec.seed, f"desktop-create-{spec.seed}")
            self.desktop.sync_now()
            outcome = "present"
        elif spec.name == CASE_NAMES[9]:
            if not self.desktop.sign_out():
                raise LiveExecutorError("Desktop account switch did not sign out")
            self.desktop.sign_in(
                os.environ["FLOORP_NOTES_SYNC_ACCOUNT_B_EMAIL"],
                os.environ["FLOORP_NOTES_SYNC_ACCOUNT_B_PASSWORD"],
            )
            outcome = "ready"
        else:
            outcome = "ready"
        self.coordination.write(
            actor="desktop",
            case_name=spec.name,
            phase="ack",
            outcome=outcome,
            sequence=spec.ack_sequence,
        )

    def _finish_case(self, spec: Any) -> None:
        assert self.desktop is not None
        if spec.name in {
            CASE_NAMES[0],
            CASE_NAMES[1],
            CASE_NAMES[6],
            CASE_NAMES[10],
            CASE_NAMES[11],
        }:
            if spec.name != CASE_NAMES[0]:
                self.desktop.sync_now()
            if self.desktop.row_count(spec.seed) != 1:
                raise LiveExecutorError("Desktop postcondition did not retain one record")
        elif spec.name == CASE_NAMES[2]:
            # The mobile actor uploaded the seed before making its local
            # edit. Pull that revision into the Desktop UI before editing the
            # same record so this is a real cross-client race, not a missing
            # row assertion.
            self.desktop.sync_now()
            self.desktop.edit(spec.seed, f"desktop-edit-{spec.seed}")
            self.desktop.sync_now()
            if self.desktop.row_count(spec.seed) != 1:
                raise LiveExecutorError("Desktop concurrent-edit result was not unique")
        elif spec.name == CASE_NAMES[3]:
            # The mobile actor uploaded the record before the delete/update
            # race. The Desktop side must observe that upload before issuing
            # the delete through its normal Notes UI.
            self.desktop.sync_now()
            self.desktop.delete(spec.seed)
            self.desktop.sync_now()
        elif spec.name == CASE_NAMES[4]:
            # The mobile actor reconnects and retries after its offline edit;
            # observe the resulting revision on Desktop as well.
            self.desktop.sync_now()
            if self.desktop.row_count(spec.seed) != 1:
                raise LiveExecutorError("Desktop offline-retry result was not unique")
        elif spec.name == CASE_NAMES[8]:
            self.desktop.sync_now()
            if any(
                self.desktop.row_count(seed) != 1
                for seed in (spec.seed, f"{spec.seed}-empty", f"{spec.seed}-second")
            ):
                raise LiveExecutorError("Desktop multi-record result was incomplete")
        elif spec.name == CASE_NAMES[9]:
            self.desktop.sync_now()
            if self.desktop.row_count(spec.seed) != 0:
                raise LiveExecutorError("Desktop account isolation was not observed")
        self.coordination.write(
            actor="desktop",
            case_name=spec.name,
            phase="complete",
            outcome="confirmed",
            sequence=spec.final_sequence,
        )
        self.observed_cases.append({"name": spec.name, "passed": True})

    def _run_matrix(self) -> None:
        for index, name in enumerate(CASE_NAMES):
            spec = type(
                "CaseSpec",
                (),
                {
                    "name": name,
                    "index": index,
                    "seed": f"T20-{index + 1:02d}",
                    "ready_sequence": index * 4 + 1,
                    "ack_sequence": index * 4 + 2,
                    "complete_sequence": index * 4 + 3,
                    "final_sequence": index * 4 + 4,
                },
            )()
            mobile_ready = self.coordination.wait(
                actor="mobile",
                sequence=spec.ready_sequence,
            )
            if mobile_ready["case_name"] != name:
                raise LiveExecutorError("mobile case order is not canonical")
            self._handle_case(spec)
            mobile_complete = self.coordination.wait(
                actor="mobile",
                sequence=spec.complete_sequence,
            )
            if mobile_complete["phase"] != "complete" or mobile_complete["outcome"] != "passed":
                raise LiveExecutorError(
                    "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
                    "reason=mobile_case_not_completed "
                    "resume=provide the missing live fault/client capability"
                )
            if mobile_complete["case_name"] != name:
                raise LiveExecutorError("mobile completion case order is not canonical")
            self._finish_case(spec)

    def _delete_disposable_accounts(self) -> bool:
        assert self.desktop is not None
        account_a_password = os.environ["FLOORP_NOTES_SYNC_ACCOUNT_A_PASSWORD"]
        account_b_password = os.environ["FLOORP_NOTES_SYNC_ACCOUNT_B_PASSWORD"]
        if not self.desktop.sign_out():
            return False
        try:
            self.desktop.sign_in(
                os.environ["FLOORP_NOTES_SYNC_ACCOUNT_B_EMAIL"],
                account_b_password,
            )
        except LiveExecutorError:
            return False
        deleted_b = self.desktop.delete_account(account_b_password)
        if not deleted_b:
            return False
        self.desktop.sign_out()
        try:
            self.desktop.sign_in(
                os.environ["FLOORP_NOTES_SYNC_ACCOUNT_A_EMAIL"],
                account_a_password,
            )
        except LiveExecutorError:
            return False
        return self.desktop.delete_account(account_a_password)

    def _cleanup(self) -> None:
        account_cleanup = False
        if self.desktop is not None:
            account_cleanup = self._delete_disposable_accounts()
            self.desktop.browser.close()
            self.desktop = None
        if self.desktop_process is not None:
            try:
                os.killpg(self.desktop_process.pid, signal.SIGTERM)
                self.desktop_process.wait(timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.desktop_process.pid, signal.SIGKILL)
                except OSError:
                    pass
            self.desktop_process = None
        local_cache = True
        try:
            dist = self.desktop_root / "_dist"
            if dist.exists() or dist.is_symlink():
                if dist.is_symlink() or not dist.is_dir():
                    local_cache = False
                else:
                    subprocess.run(
                        ["/bin/rm", "-rf", str(dist)],
                        env=private_environment(),
                        check=True,
                    )
        except (OSError, subprocess.CalledProcessError):
            local_cache = False
        simulator_keychain = (
            subprocess.run(
                ["xcrun", "simctl", "erase", self.simulator_udid],
                env=private_environment(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            ).returncode
            == 0
        )
        coordination_root = self.coordination.remove()
        runner_temp = True
        if self.paths.client_state.exists() or self.paths.client_state.is_symlink():
            if self.paths.client_state.is_symlink() or not self.paths.client_state.is_dir():
                runner_temp = False
            else:
                try:
                    subprocess.run(
                        ["/bin/rm", "-rf", str(self.paths.client_state)],
                        env=private_environment(),
                        check=True,
                    )
                except (OSError, subprocess.CalledProcessError):
                    runner_temp = False
        if not all((account_cleanup, local_cache, runner_temp, simulator_keychain, coordination_root)):
            raise LiveExecutorError(
                "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
                "reason=disposable_account_or_client_cleanup_unproven "
                "resume=complete the FxA account deletion UI and cleanup boundary"
            )
        receipt = {
            "accounts": True,
            "coordination_root": True,
            "environment": ENVIRONMENT,
            "local_cache": True,
            "phase": "production-qa",
            "runner_temp": True,
            "schema_version": 1,
            "simulator_keychain": True,
            "source": {
                "head_sha": self.source["head_sha"],
                "repository": REPOSITORY,
                "workflow_run_attempt": self.source["workflow_run_attempt"],
                "workflow_run_id": self.source["workflow_run_id"],
            },
        }
        self.paths.cleanup_receipt.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.paths.cleanup_receipt.open("xb") as handle:
            handle.write(canonical_bytes(receipt))
            handle.flush()
            os.fsync(handle.fileno())

    def _write_summary(self) -> None:
        if [case["name"] for case in self.observed_cases] != list(CASE_NAMES):
            raise LiveExecutorError("not all live cases were observed")
        observed_names = {case["name"] for case in self.observed_cases if case["passed"] is True}
        invariant_results = {
            name: required_cases <= observed_names
            for name, required_cases in INVARIANT_CASES.items()
        }
        if not all(invariant_results.values()):
            raise LiveExecutorError("not all data-integrity invariants were observed")
        raise LiveExecutorError(
            "[blocked] UPSTREAM_ARTIFACT_MISSING owner=Operations "
            "reason=network_transport_observation_missing "
            "resume=provide metadata-only client or transport observation for approved FxA/Sync hosts and TLS"
        )
        cleanup_raw = self.paths.cleanup_receipt.read_bytes()
        summary = {
            "accounts": 2,
            "cases": self.observed_cases,
            "cleanup": {
                "accounts": True,
                "local_cache": True,
                "runner_temp": True,
                "simulator_keychain": True,
            },
            "cleanup_receipt_sha256": hashlib.sha256(cleanup_raw).hexdigest(),
            "clients": ["desktop", "mobile"],
            "environment": ENVIRONMENT,
            "invariants": invariant_results,
            "network": {
                "direct_rest_used": False,
                "hosts": sorted(self.observed_hosts | set(APPROVED_HOSTS)),
                "metadata_only": True,
                "tls_verified": True,
                "wire_protocol": "sync15",
            },
            "phase": "production-qa",
            "phase_2_enablement_ready": True,
            "public_release": False,
            "schema_version": 1,
            "self_attestation": {
                "approved": True,
                "environment": ENVIRONMENT,
                "operator_id": os.environ["GITHUB_ACTOR"],
                "roles": ["owner", "operations", "executor"],
            },
            "source": self.source,
        }
        self.paths.summary.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.paths.summary.open("xb") as handle:
            handle.write(canonical_bytes(summary))
            handle.flush()
            os.fsync(handle.fileno())

    def run(self) -> None:
        self.coordination.prepare()
        try:
            self._start_desktop()
            assert self.desktop is not None
            self.desktop.sign_in(
                os.environ["FLOORP_NOTES_SYNC_ACCOUNT_A_EMAIL"],
                os.environ["FLOORP_NOTES_SYNC_ACCOUNT_A_PASSWORD"],
            )
            self._start_test()
            self._run_matrix()
            if self.test_process is not None:
                exit_code = self.test_process.wait(timeout=120)
                if exit_code != 0:
                    raise LiveExecutorError("iOS XCTest did not pass")
            self._cleanup()
            self._write_summary()
        finally:
            if self.test_process is not None and self.test_process.poll() is None:
                self.test_process.terminate()
                try:
                    self.test_process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    self.test_process.kill()
            if self.desktop is not None or self.desktop_process is not None:
                try:
                    self._cleanup()
                except LiveExecutorError:
                    pass
