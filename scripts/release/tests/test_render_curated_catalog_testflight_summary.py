"""Tests for the non-secret curated-catalog TestFlight summary renderer."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


def load_module():
    module_path = Path(__file__).parent.parent / "render-curated-catalog-testflight-summary.py"
    spec = importlib.util.spec_from_file_location("render_curated_catalog_testflight_summary", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


summary = load_module()


def evidence():
    return {
        "buildID": "build-1",
        "buildNumber": "4",
        "catalogID": "floorp-ios-curated-testflight",
        "catalogSHA256": "a" * 64,
        "catalogSequence": 1,
        "marketingVersion": "0.3.0",
        "status": "verified",
        "xcodeCloudRunID": "run-1",
    }


class CuratedCatalogSummaryTests(unittest.TestCase):
    def test_renders_expected_verified_evidence(self):
        result = summary.render_submission_summary(evidence())

        self.assertIn("`build-1` (0.3.0 (4))", result)
        self.assertIn("`run-1`", result)
        self.assertIn("sequence `1`", result)

    def test_rejects_unverified_or_malformed_evidence(self):
        unverified = evidence()
        unverified["status"] = "pending"
        with self.assertRaises(summary.CuratedCatalogSummaryError):
            summary.render_submission_summary(unverified)

        malformed = evidence()
        malformed["catalogSequence"] = []
        with self.assertRaises(summary.CuratedCatalogSummaryError):
            summary.render_submission_summary(malformed)
