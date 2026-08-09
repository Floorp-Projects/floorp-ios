"""Fixture tests for scripts/release/submit-floorp-external-beta.sh."""

import json
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


RELEASE_DIR = Path(__file__).parent.parent
SCRIPT = RELEASE_DIR / "submit-floorp-external-beta.sh"


class SubmitExternalBetaScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def stub_client(self):
        # A recording stub: GETs return canned responses, writes record argv.
        stub = self.root / "stub-client.py"
        stub.write_text(textwrap.dedent("""
            import json, sys, os
            record = os.environ["STUB_RECORD"]
            with open(record, "a") as handle:
                handle.write(json.dumps(sys.argv[1:]) + "\\n")
            command = sys.argv[1]
            path = sys.argv[2]
            if command == "get":
                canned = {
                    "/v1/betaAppReviewDetails?filter[app]=6796708699": {"data": [{"id": "rev-1", "type": "betaAppReviewDetails"}]},
                    "/v1/betaAppReviewSubmissions?filter[build]=bld-1": {"data": []},
                    "/v1/betaBuildLocalizations?filter[build]=bld-1": {"data": []},
                    "/v1/betaGroups/grp-1/builds": {"data": []},
                    "/v1/builds/bld-1": {"data": {"id": "bld-1", "type": "builds"}},
                }
                output = sys.argv[sys.argv.index("--output") + 1]
                json.dump(canned.get(path, canned.get(path.split("?", 1)[0], {"data": []})), open(output, "w"))
            else:
                if "--authorize-mutation" not in sys.argv:
                    sys.stderr.write("write routes require --authorize-mutation\\n")
                    sys.exit(1)
                output = sys.argv[sys.argv.index("--output") + 1]
                json.dump({"data": {"id": "new-1"}}, open(output, "w"))
        """))
        return stub

    def run_script(self, *extra_args):
        record = self.root / "record.jsonl"
        stub = self.stub_client()
        metadata = self.root / "metadata.json"
        metadata.write_text(json.dumps({
            "app": {"primary_locales": ["en-US", "ja-JP"]},
            "privacy": {"data_types": []},
            "export_compliance": {"uses_encryption": True},
        }))
        review = self.root / "review.json"
        review.write_text(json.dumps({
            "contactEmail": "release@floorp.app",
            "contactFirstName": "Ryosuke",
            "contactLastName": "Asano",
            "contactPhone": "+81-00-0000-0000",
            "notes": "Internal 0.2.0 acceptance passed; external beta gated.",
        }))
        wte = self.root / "WhatToTest.en-US.txt"
        wte.write_text("Test the 0.2.0 (4) candidate.")
        wtj = self.root / "WhatToTest.ja-JP.txt"
        wtj.write_text("0.2.0 (4) 候補をテストしてください。")
        before = self.root / "before.json"
        after = self.root / "after.json"
        result = self.root / "result.json"
        env = {"STUB_RECORD": str(record), "PATH": "/usr/bin:/bin"}
        proc = subprocess.run(
            [
                "bash", str(SCRIPT),
                "--client", str(stub),
                "--app-id", "6796708699",
                "--build-id", "bld-1",
                "--external-group-id", "grp-1",
                "--localization", str(metadata),
                "--review-details", str(review),
                "--before", str(before),
                "--after", str(after),
                "--what-to-test-en", str(wte),
                "--what-to-test-ja", str(wtj),
                *extra_args,
                "--output", str(result),
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        return proc, record, before, after, result

    def test_dry_run_uses_only_allowed_routes_and_zero_mutations(self):
        proc, record, before, after, result = self.run_script(
            "--dry-run", "--authorize-mutation"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        writes = []
        for line in record.read_text().splitlines():
            argv = json.loads(line)
            if argv[0] in ("post", "patch"):
                writes.append((argv[0], argv[1]))
        self.assertEqual(
            writes,
            [
                ("post", "/v1/betaBuildLocalizations"),
                ("post", "/v1/betaBuildLocalizations"),
                ("patch", "/v1/betaAppReviewDetails/rev-1"),
                ("post", "/v1/betaAppReviewSubmissions"),
                ("post", "/v1/betaGroups/grp-1/relationships/builds"),
            ],
        )
        self.assertEqual(json.loads(before.read_text()), json.loads(after.read_text()))
        self.assertEqual(json.loads(result.read_text())["build_id"], "bld-1")

    def test_writes_require_authorize_mutation(self):
        proc, record, before, after, result = self.run_script()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("write routes require --authorize-mutation", proc.stderr)

    def test_review_details_gate_blocks_without_record(self):
        # A missing betaAppReviewDetails record is an agreement/permission gate.
        record = self.root / "record2.jsonl"
        stub = self.root / "stub2.py"
        stub.write_text(textwrap.dedent("""
            import json, sys, os
            with open(os.environ["STUB_RECORD"], "a") as handle:
                handle.write(json.dumps(sys.argv[1:]) + "\\n")
            output = sys.argv[sys.argv.index("--output") + 1]
            json.dump({"data": []}, open(output, "w"))
        """))
        metadata = self.root / "metadata2.json"
        metadata.write_text(json.dumps({"app": {"primary_locales": ["en-US"]}}))
        review = self.root / "review2.json"
        review.write_text(json.dumps({"contactEmail": "a@b.c"}))
        wte = self.root / "wte2.txt"
        wte.write_text("notes")
        proc = subprocess.run(
            [
                "bash", str(SCRIPT),
                "--client", str(stub),
                "--app-id", "6796708699",
                "--build-id", "bld-1",
                "--external-group-id", "grp-1",
                "--localization", str(metadata),
                "--review-details", str(review),
                "--before", str(self.root / "b2.json"),
                "--after", str(self.root / "a2.json"),
                "--what-to-test-en", str(wte),
                "--authorize-mutation",
                "--output", str(self.root / "r2.json"),
            ],
            capture_output=True,
            text=True,
            env={"STUB_RECORD": str(record), "PATH": "/usr/bin:/bin"},
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no betaAppReviewDetails record", proc.stderr)


if __name__ == "__main__":
    unittest.main()
