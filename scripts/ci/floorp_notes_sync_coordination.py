#!/usr/bin/python3 -I
"""Metadata-only coordination channel for the Todo 20 client pair.

The desktop controller and the iOS XCTest exchange only case/phase/outcome
metadata.  Note identifiers, titles, contents, credentials, tokens, request
bodies, and response bodies are intentionally not representable by this
protocol.
"""

from __future__ import annotations

import json
import os
import stat
import time
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
ACTORS = frozenset({"desktop", "mobile"})
PHASES = frozenset({"request", "ack", "complete", "failed"})
OUTCOMES = frozenset({"ready", "passed", "failed", "present", "absent", "confirmed"})
CASE_NAMES = (
    "desktop-create-mobile-sync-desktop-recheck",
    "mobile-create-desktop-sync-mobile-recheck",
    "same-record-concurrent-edit",
    "update-delete-conflict",
    "offline-edit-reconnect-retry",
    "upload-save-commit-failure",
    "restart-preserves-unsynced-local-data",
    "old-new-client-mixed",
    "large-empty-multiple-records",
    "account-switch-isolation",
    "retry-idempotence",
    "base-revision-confirmation-gate",
)

_CASE_SET = frozenset(CASE_NAMES)
_EVENT_KEYS = frozenset(
    {"actor", "case_name", "outcome", "phase", "schema_version", "sequence"}
)
_SENSITIVE_KEYS = frozenset(
    {
        "access_token",
        "authorization",
        "cookie",
        "credential",
        "email",
        "key",
        "note_content",
        "note_title",
        "password",
        "payload",
        "refresh_token",
        "request_body",
        "response_body",
        "secret",
        "session",
        "sync_key",
        "token",
    }
)


class CoordinationError(ValueError):
    """The coordination root or event is unsafe or malformed."""


def _canonical_bytes(value: dict[str, Any]) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=True)
        .encode("utf-8")
        + b"\n"
    )


def _reject_sensitive(value: Any) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in _SENSITIVE_KEYS:
                raise CoordinationError(f"sensitive coordination field: {key}")
            _reject_sensitive(child)
    elif isinstance(value, list):
        for child in value:
            _reject_sensitive(child)


def validate_event(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != _EVENT_KEYS:
        raise CoordinationError("coordination event fields are not exact")
    if value["schema_version"] != SCHEMA_VERSION:
        raise CoordinationError("coordination schema is unsupported")
    if value["actor"] not in ACTORS:
        raise CoordinationError("coordination actor is invalid")
    if value["case_name"] not in _CASE_SET:
        raise CoordinationError("coordination case is invalid")
    if value["phase"] not in PHASES:
        raise CoordinationError("coordination phase is invalid")
    if value["outcome"] not in OUTCOMES:
        raise CoordinationError("coordination outcome is invalid")
    sequence = value["sequence"]
    if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence <= 0:
        raise CoordinationError("coordination sequence is invalid")
    _reject_sensitive(value)
    return value


def _ensure_private_directory(path: Path, *, create: bool) -> Path:
    if create:
        path.mkdir(mode=0o700, parents=False, exist_ok=False)
    try:
        metadata = path.lstat()
    except OSError as error:
        raise CoordinationError("coordination root is unavailable") from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise CoordinationError("coordination root must be a real directory")
    if metadata.st_uid != os.getuid() or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise CoordinationError("coordination root must be private and owner-controlled")
    return path


class CoordinationChannel:
    """Append-only event files under a private runner-local directory."""

    def __init__(self, root: Path):
        self.root = _ensure_private_directory(root, create=False)
        self.events = _ensure_private_directory(self.root / "events", create=False)

    @classmethod
    def create(cls, root: Path) -> "CoordinationChannel":
        root = Path(root).resolve(strict=False)
        root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        _ensure_private_directory(root, create=True)
        events = root / "events"
        events.mkdir(mode=0o700, exist_ok=False)
        return cls(root)

    def _event_path(self, actor: str, sequence: int) -> Path:
        if actor not in ACTORS or sequence <= 0:
            raise CoordinationError("invalid event path")
        return self.events / f"{actor}-{sequence:04d}.json"

    def write_event(
        self,
        *,
        actor: str,
        case_name: str,
        phase: str,
        outcome: str,
        sequence: int,
    ) -> Path:
        event = validate_event(
            {
                "actor": actor,
                "case_name": case_name,
                "outcome": outcome,
                "phase": phase,
                "schema_version": SCHEMA_VERSION,
                "sequence": sequence,
            }
        )
        destination = self._event_path(actor, sequence)
        temporary = self.events / f".{destination.name}.tmp-{os.getpid()}"
        payload = _canonical_bytes(event)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        descriptor = os.open(temporary, flags, 0o600)
        try:
            with os.fdopen(descriptor, "wb", closefd=True) as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            # Link-then-unlink publishes without replacing an existing event.
            # os.replace would silently permit a retry to rewrite history.
            os.link(temporary, destination)
            temporary.unlink()
        except BaseException:
            try:
                temporary.unlink()
            except OSError:
                pass
            raise
        return destination

    def read_event(self, *, actor: str, sequence: int) -> dict[str, Any]:
        path = self._event_path(actor, sequence)
        try:
            raw = path.read_bytes()
        except OSError as error:
            raise CoordinationError("coordination event is unavailable") from error
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CoordinationError("coordination event is not JSON") from error
        if raw != _canonical_bytes(value):
            raise CoordinationError("coordination event is not canonical")
        return validate_event(value)

    def wait_for_event(
        self,
        *,
        actor: str,
        sequence: int,
        timeout_seconds: float = 120.0,
        poll_seconds: float = 0.1,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        path = self._event_path(actor, sequence)
        while time.monotonic() < deadline:
            if path.exists() and not path.is_symlink():
                return self.read_event(actor=actor, sequence=sequence)
            time.sleep(poll_seconds)
        raise CoordinationError("coordination event timed out")


__all__ = [
    "CASE_NAMES",
    "CoordinationChannel",
    "CoordinationError",
    "SCHEMA_VERSION",
    "validate_event",
]
