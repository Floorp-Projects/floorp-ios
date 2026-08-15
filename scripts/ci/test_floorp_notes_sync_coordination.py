#!/usr/bin/python3 -I

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from floorp_notes_sync_coordination import (
    CASE_NAMES,
    CoordinationChannel,
    CoordinationError,
    validate_event,
)


class CoordinationChannelTests(unittest.TestCase):
    def test_event_is_canonical_append_only_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            channel = CoordinationChannel.create(Path(temporary) / "coordination")
            path = channel.write_event(
                actor="mobile",
                case_name=CASE_NAMES[0],
                phase="complete",
                outcome="passed",
                sequence=1,
            )
            self.assertEqual(
                channel.read_event(actor="mobile", sequence=1)["outcome"],
                "passed",
            )
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                channel.write_event(
                    actor="mobile",
                    case_name=CASE_NAMES[0],
                    phase="complete",
                    outcome="passed",
                    sequence=1,
                )

    def test_payload_and_secret_fields_are_rejected(self) -> None:
        event = {
            "actor": "desktop",
            "case_name": CASE_NAMES[0],
            "outcome": "passed",
            "phase": "complete",
            "schema_version": 1,
            "sequence": 1,
            "payload": "forbidden",
        }
        with self.assertRaises(CoordinationError):
            validate_event(event)

    def test_noncanonical_event_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            channel = CoordinationChannel.create(Path(temporary) / "coordination")
            path = channel.write_event(
                actor="desktop",
                case_name=CASE_NAMES[0],
                phase="ack",
                outcome="ready",
                sequence=1,
            )
            path.write_text(json.dumps(json.loads(path.read_text()), indent=2) + "\n")
            with self.assertRaises(CoordinationError):
                channel.read_event(actor="desktop", sequence=1)


if __name__ == "__main__":
    unittest.main()
