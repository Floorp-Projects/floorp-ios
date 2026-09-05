"""Fixture tests for scripts/release/submit-floorp-external-beta.sh."""

import json
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


RELEASE_DIR = Path(__file__).parent.parent
SCRIPT = RELEASE_DIR / "submit-floorp-external-beta.sh"
APP_ID = "6796708699"
BUNDLE_ID = "app.floorp.Floorp"
WORKFLOW_ID = "workflow-1"
RUN_ID = "run-1"
BUILD_ID = "bld-1"
BUILD_NUMBER = "96"
SOURCE_SHA = "a" * 40


def receipt_value():
    return {
        "schema_version": 1,
        "workflow": {
            "id": WORKFLOW_ID,
            "name": "Floorp TestFlight Manual",
            "product_id": "product-1",
        },
        "source": {
            "name": f"floorp-catalog-{SOURCE_SHA}",
            "kind": "tag",
            "reference_id": "tag-1",
            "commit_sha": SOURCE_SHA,
        },
        "run": {
            "id": RUN_ID,
            "execution_progress": "COMPLETE",
            "completion_status": "SUCCEEDED",
            "source_commit": SOURCE_SHA,
            "workflow_id": WORKFLOW_ID,
        },
        "baseline": {
            "app_id": APP_ID,
            "build_count": 95,
            "build_ids_sha256": "f" * 64,
            "max_build_number": "95",
        },
        "build": {
            "id": BUILD_ID,
            "number": BUILD_NUMBER,
            "app_id": APP_ID,
            "bundle_id": BUNDLE_ID,
            "marketing_version": "0.3.0",
            "platform": "IOS",
            "processing_state": "VALID",
            "build_audience_type": "APP_STORE_ELIGIBLE",
            "expired": False,
            "uses_non_exempt_encryption": False,
            "min_os_version": "18.4",
        },
    }


class SubmitExternalBetaScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def stub_client(self):
        # A recording, stateful stub: GETs expose server state and writes mutate it.
        stub = self.root / "stub-client.py"
        stub.write_text(textwrap.dedent("""
            import hashlib, json, sys, os
            record = os.environ["STUB_RECORD"]
            command = sys.argv[1]
            recorded = list(sys.argv[1:])
            if command in ("post", "patch") and "--body" in sys.argv:
                body_path = sys.argv[sys.argv.index("--body") + 1]
                recorded += ["--recorded-body-json", json.dumps(json.load(open(body_path)), sort_keys=True)]
            with open(record, "a") as handle:
                handle.write(json.dumps(recorded) + "\\n")
            if command == "fingerprint-state":
                value = json.load(open(sys.argv[sys.argv.index("--input") + 1]))
                data = value["data"]
                if isinstance(data, list):
                    data = sorted(data, key=lambda item: json.dumps(item, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
                encoded = json.dumps(data, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
                print(hashlib.sha256(encoded).hexdigest())
                raise SystemExit(0)
            state_path = os.environ["STUB_STATE"]
            state = json.load(open(state_path))
            path = sys.argv[2]
            if command == "get":
                submissions = {"data": state["submissions"]}
                if "submission_links" in state:
                    submissions["links"] = state["submission_links"]
                review_rows = [] if state.get("review") is None else [state["review"]]
                canned = {
                    "/v1/betaAppReviewDetails?filter[app]=6796708699&limit=200": {"data": review_rows},
                    "/v1/betaAppReviewSubmissions?filter[build]=bld-1&limit=200": submissions,
                    "/v1/betaBuildLocalizations?filter[build]=bld-1&limit=200": {"data": state["localizations"]},
                    "/v1/betaGroups/grp-1/builds?limit=200": {
                        "data": state["group_builds"],
                        **({"links": state["group_build_links"]} if "group_build_links" in state else {}),
                    },
                    "/v1/ciBuildRuns/run-1?include=workflow": state["run"],
                    "/v1/ciBuildRuns/run-1/relationships/builds?limit=200": state["linkage"],
                    "/v1/builds/bld-1?include=app,preReleaseVersion": state["build"],
                    "/v1/betaGroups/grp-1?include=app": state["group"],
                }
                output = sys.argv[sys.argv.index("--output") + 1]
                json.dump(canned.get(path, canned.get(path.split("?", 1)[0], {"data": []})), open(output, "w"))
            else:
                if "--authorize-mutation" not in sys.argv:
                    sys.stderr.write("write routes require --authorize-mutation\\n")
                    sys.exit(1)
                output = sys.argv[sys.argv.index("--output") + 1]
                if "--dry-run" in sys.argv:
                    json.dump({"dry_run": True}, open(output, "w"))
                    raise SystemExit(0)
                body = json.load(open(sys.argv[sys.argv.index("--body") + 1]))
                response = {"data": {"id": "new-1"}}
                if path == "/v1/betaBuildLocalizations":
                    row = body["data"]
                    row["id"] = "loc-" + row["attributes"]["locale"]
                    state["localizations"].append(row)
                    response = {"data": row}
                elif path.startswith("/v1/betaBuildLocalizations/"):
                    row = next(item for item in state["localizations"] if item["id"] == body["data"]["id"])
                    row["attributes"].update(body["data"]["attributes"])
                    response = {"data": row}
                elif path == "/v1/betaAppReviewDetails/rev-1":
                    state["review"]["attributes"].update(body["data"]["attributes"])
                    response = {"data": state["review"]}
                elif path == "/v1/betaAppReviewSubmissions":
                    row = {"id": "submission-1", "type": "betaAppReviewSubmissions"}
                    new_state = state.get("new_submission_state", "WAITING_FOR_REVIEW")
                    if new_state is not None:
                        row["attributes"] = {"betaReviewState": new_state}
                    if not state.get("suppress_submission_creation"):
                        state["submissions"].append(row)
                        if state.get("duplicate_new_submission"):
                            duplicate = dict(row)
                            duplicate["id"] = "submission-2"
                            state["submissions"].append(duplicate)
                    response = {"data": row}
                elif path == "/v1/betaGroups/grp-1/relationships/builds":
                    if not state.get("suppress_group_assignment"):
                        state["group_builds"].extend(body["data"])
                    response = {"data": body["data"]}
                json.dump(state, open(state_path, "w"))
                json.dump(response, open(output, "w"))
        """))
        return stub

    def run_script(self, *extra_args, state_overrides=None, receipt_overrides=None):
        record = self.root / "record.jsonl"
        record.write_text("")
        stub = self.stub_client()
        metadata = self.root / "metadata.json"
        metadata.write_text(json.dumps({
            "app": {"primary_locales": ["en-US", "ja-JP"]},
            "privacy": {"data_types": []},
            "export_compliance": {"uses_encryption": True},
        }))
        review = self.root / "review.json"
        review.write_text(json.dumps({
            "notes": "Internal 0.2.0 acceptance passed; external beta gated.",
        }))
        wte = self.root / "WhatToTest.en-US.txt"
        wte.write_text("Test the 0.2.0 (4) candidate.")
        wtj = self.root / "WhatToTest.ja-JP.txt"
        wtj.write_text("0.2.0 (4) 候補をテストしてください。")
        before = self.root / "before.json"
        after = self.root / "after.json"
        result = self.root / "result.json"
        receipt = self.root / "build-receipt.json"
        receipt_data = receipt_value()
        if receipt_overrides:
            for key, value in receipt_overrides.items():
                if isinstance(value, dict) and isinstance(receipt_data.get(key), dict):
                    receipt_data[key].update(value)
                else:
                    receipt_data[key] = value
        receipt.write_text(json.dumps(receipt_data))
        state = self.root / "state.json"
        state_value = {
            "review": {
                "id": "rev-1",
                "type": "betaAppReviewDetails",
                "attributes": {
                    "contactEmail": "fresh@floorp.app",
                    "contactFirstName": "Fresh",
                    "contactLastName": "Reviewer",
                    "contactPhone": "+81-00-0000-0000",
                    "demoAccountRequired": False,
                    "demoAccountName": None,
                    "demoAccountPassword": None,
                },
            },
            "submissions": [],
            "localizations": [],
            "group_builds": [],
            "run": {
                "data": {
                    "type": "ciBuildRuns",
                    "id": RUN_ID,
                    "attributes": {
                        "executionProgress": "COMPLETE",
                        "completionStatus": "SUCCEEDED",
                        "sourceCommit": {"commitSha": SOURCE_SHA},
                    },
                    "relationships": {
                        "workflow": {
                            "data": {"type": "ciWorkflows", "id": WORKFLOW_ID}
                        }
                    },
                }
            },
            "linkage": {
                "data": [{"type": "builds", "id": BUILD_ID}],
                "links": {"next": None},
            },
            "build": {
                "data": {
                    "type": "builds",
                    "id": BUILD_ID,
                    "attributes": {
                        "version": BUILD_NUMBER,
                        "processingState": "VALID",
                        "buildAudienceType": "APP_STORE_ELIGIBLE",
                        "expired": False,
                        "usesNonExemptEncryption": False,
                        "minOsVersion": "18.4",
                    },
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": APP_ID}},
                        "preReleaseVersion": {
                            "data": {"type": "preReleaseVersions", "id": "train-1"}
                        },
                    },
                },
                "included": [
                    {"type": "apps", "id": APP_ID, "attributes": {"bundleId": BUNDLE_ID}},
                    {
                        "type": "preReleaseVersions",
                        "id": "train-1",
                        "attributes": {"version": "0.3.0", "platform": "IOS"},
                    },
                ],
            },
            "group": {
                "data": {
                    "type": "betaGroups",
                    "id": "grp-1",
                    "attributes": {"name": "External", "isInternalGroup": False},
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": APP_ID}}
                    },
                },
                "included": [
                    {"type": "apps", "id": APP_ID, "attributes": {"bundleId": BUNDLE_ID}}
                ],
            },
        }
        if state_overrides:
            state_value.update(state_overrides)
        state.write_text(json.dumps(state_value))
        env = {
            "STUB_RECORD": str(record),
            "STUB_STATE": str(state),
            "PATH": "/usr/bin:/bin",
        }
        proc = subprocess.run(
            [
                "bash", str(SCRIPT),
                "--client", str(stub),
                "--build-receipt", str(receipt),
                "--xcode-cloud-run-id", RUN_ID,
                "--xcode-cloud-workflow-id", WORKFLOW_ID,
                "--expected-source-sha", SOURCE_SHA,
                "--app-id", "6796708699",
                "--build-id", "bld-1",
                "--expected-build-number", BUILD_NUMBER,
                "--expected-bundle-id", BUNDLE_ID,
                "--expected-marketing-version", "0.3.0",
                "--expected-platform", "IOS",
                "--expected-min-os-version", "18.4",
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
                ("post", "/v1/betaGroups/grp-1/relationships/builds"),
                ("post", "/v1/betaAppReviewSubmissions"),
            ],
        )
        self.assertEqual(json.loads(before.read_text()), json.loads(after.read_text()))
        result_value = json.loads(result.read_text())
        self.assertEqual(result_value["build_id"], "bld-1")
        self.assertEqual(result_value["review_state"], "planned")
        for line in record.read_text().splitlines():
            argv = json.loads(line)
            if argv[0] in ("post", "patch"):
                self.assertIn("--guard-get", argv)
                self.assertIn("--prior-state-sha256", argv)

    def test_review_patch_contains_notes_only_and_never_replays_credentials(self):
        proc, record, _, _, result = self.run_script("--authorize-mutation")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(result.read_text())["review_state"], "submitted")
        calls = [json.loads(line) for line in record.read_text().splitlines()]
        review_patch = next(
            argv for argv in calls
            if argv[0:2] == ["patch", "/v1/betaAppReviewDetails/rev-1"]
        )
        body = json.loads(
            review_patch[review_patch.index("--recorded-body-json") + 1]
        )
        self.assertEqual(
            body["data"]["attributes"],
            {"notes": "Internal 0.2.0 acceptance passed; external beta gated."},
        )
        body_text = json.dumps(body)
        for sensitive_field in (
            "contactEmail", "contactFirstName", "contactLastName", "contactPhone",
            "demoAccountName", "demoAccountPassword",
        ):
            self.assertNotIn(sensitive_field, body_text)

    def test_each_localization_uses_a_fresh_guard_snapshot(self):
        proc, record, _, _, _ = self.run_script("--authorize-mutation")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = [json.loads(line) for line in record.read_text().splitlines()]
        localization_gets = [
            argv for argv in calls
            if argv[0:2] == ["get", "/v1/betaBuildLocalizations?filter[build]=bld-1&limit=200"]
        ]
        self.assertGreaterEqual(len(localization_gets), 4)

    def test_group_assignment_is_observed_before_review_submission(self):
        proc, record, _, _, _ = self.run_script("--authorize-mutation")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = [json.loads(line) for line in record.read_text().splitlines()]
        group_post = next(
            index for index, argv in enumerate(calls)
            if argv[0:2] == ["post", "/v1/betaGroups/grp-1/relationships/builds"]
        )
        submission_post = next(
            index for index, argv in enumerate(calls)
            if argv[0:2] == ["post", "/v1/betaAppReviewSubmissions"]
        )
        group_readbacks = [
            index for index, argv in enumerate(calls)
            if argv[0:2] == ["get", "/v1/betaGroups/grp-1/builds?limit=200"]
        ]
        self.assertLess(group_post, submission_post)
        self.assertTrue(
            any(group_post < index < submission_post for index in group_readbacks),
            "external group membership was not read back before submission",
        )

    def test_submission_is_blocked_when_group_assignment_is_not_observable(self):
        proc, record, _, _, _ = self.run_script(
            "--authorize-mutation",
            state_overrides={"suppress_group_assignment": True},
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("build is not assigned to the external group", proc.stderr)
        calls = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertTrue(any(
            argv[0:2] == ["post", "/v1/betaGroups/grp-1/relationships/builds"]
            for argv in calls
        ))
        self.assertFalse(any(
            argv[0:2] == ["post", "/v1/betaAppReviewSubmissions"]
            for argv in calls
        ))

    def test_existing_submission_accepts_only_releasable_review_states(self):
        for review_state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"):
            with self.subTest(review_state=review_state):
                proc, record, _, _, result = self.run_script(
                    "--authorize-mutation",
                    state_overrides={
                        "submissions": [{
                            "id": "existing-submission",
                            "type": "betaAppReviewSubmissions",
                            "attributes": {"betaReviewState": review_state},
                        }],
                        "group_builds": [{"id": "bld-1", "type": "builds"}],
                    },
                )
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(
                    json.loads(result.read_text())["submission_id"],
                    "existing-submission",
                )
                calls = [json.loads(line) for line in record.read_text().splitlines()]
                self.assertFalse(any(
                    argv[0:2] == ["post", "/v1/betaAppReviewSubmissions"]
                    for argv in calls
                ))

    def test_existing_submission_rejects_bad_or_missing_review_state_before_writes(self):
        cases = (
            ("REJECTED", {"betaReviewState": "REJECTED"}, "is not releasable"),
            ("unknown", {"betaReviewState": "READY_FOR_REVIEW"}, "is not releasable"),
            ("missing", {}, "betaReviewState is missing"),
        )
        for name, attributes, expected_error in cases:
            with self.subTest(name=name):
                proc, record, _, _, _ = self.run_script(
                    "--authorize-mutation",
                    state_overrides={
                        "submissions": [{
                            "id": "existing-submission",
                            "type": "betaAppReviewSubmissions",
                            "attributes": attributes,
                        }],
                    },
                )
                self.assertEqual(proc.returncode, 1)
                self.assertIn(expected_error, proc.stderr)
                calls = [json.loads(line) for line in record.read_text().splitlines()]
                self.assertFalse(any(argv[0] in ("post", "patch") for argv in calls))

    def test_existing_submission_rejects_duplicates_before_writes(self):
        submissions = [
            {
                "id": f"existing-{index}",
                "type": "betaAppReviewSubmissions",
                "attributes": {"betaReviewState": "WAITING_FOR_REVIEW"},
            }
            for index in (1, 2)
        ]
        proc, record, _, _, _ = self.run_script(
            "--authorize-mutation",
            state_overrides={"submissions": submissions},
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("duplicate records", proc.stderr)
        calls = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertFalse(any(argv[0] in ("post", "patch") for argv in calls))

    def test_existing_submission_rejects_an_incomplete_paginated_snapshot(self):
        proc, record, _, _, _ = self.run_script(
            "--authorize-mutation",
            state_overrides={
                "submissions": [{
                    "id": "existing-submission",
                    "type": "betaAppReviewSubmissions",
                    "attributes": {"betaReviewState": "WAITING_FOR_REVIEW"},
                }],
                "submission_links": {"next": "https://example.invalid/page/2"},
            },
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("refusing an incomplete duplicate check", proc.stderr)
        calls = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertFalse(any(argv[0] in ("post", "patch") for argv in calls))

    def test_final_submission_rejects_bad_or_missing_review_state(self):
        cases = (
            ("REJECTED", "REJECTED", "is not releasable"),
            ("unknown", "READY_FOR_REVIEW", "is not releasable"),
            ("missing", None, "betaReviewState is missing"),
        )
        for name, review_state, expected_error in cases:
            with self.subTest(name=name):
                proc, _, _, _, _ = self.run_script(
                    "--authorize-mutation",
                    state_overrides={"new_submission_state": review_state},
                )
                self.assertEqual(proc.returncode, 1)
                self.assertIn(expected_error, proc.stderr)

    def test_final_submission_requires_exactly_one_record(self):
        cases = (
            ("missing", {"suppress_submission_creation": True}, "submission is missing"),
            ("duplicate", {"duplicate_new_submission": True}, "duplicate records"),
        )
        for name, overrides, expected_error in cases:
            with self.subTest(name=name):
                proc, _, _, _, _ = self.run_script(
                    "--authorize-mutation",
                    state_overrides=overrides,
                )
                self.assertEqual(proc.returncode, 1)
                self.assertIn(expected_error, proc.stderr)

    def test_writes_require_authorize_mutation(self):
        proc, record, before, after, result = self.run_script()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("write routes require --authorize-mutation", proc.stderr)

    def test_review_details_gate_blocks_without_record(self):
        proc, record, _, _, _ = self.run_script(
            "--authorize-mutation", state_overrides={"review": None}
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("exactly one betaAppReviewDetails", proc.stderr)
        calls = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertFalse(any(argv[0] in ("post", "patch") for argv in calls))

    def test_demo_credentials_are_conditional_and_checked_before_writes(self):
        # The default fixture has demoAccountRequired=false and null credentials.
        proc, _, _, _, _ = self.run_script("--authorize-mutation")
        self.assertEqual(proc.returncode, 0, proc.stderr)

        for attributes in (
            {
                "contactEmail": "fresh@floorp.app",
                "contactFirstName": "Fresh",
                "contactLastName": "Reviewer",
                "contactPhone": "+81-00-0000-0000",
                "demoAccountRequired": True,
                "demoAccountName": "",
                "demoAccountPassword": "secret",
            },
            {
                "contactEmail": "fresh@floorp.app",
                "contactFirstName": "Fresh",
                "contactLastName": "Reviewer",
                "contactPhone": "+81-00-0000-0000",
                "demoAccountRequired": True,
                "demoAccountName": "demo",
                "demoAccountPassword": None,
            },
        ):
            with self.subTest(attributes=attributes):
                review = {
                    "id": "rev-1",
                    "type": "betaAppReviewDetails",
                    "attributes": attributes,
                }
                proc, record, _, _, _ = self.run_script(
                    "--authorize-mutation", state_overrides={"review": review}
                )
                self.assertEqual(proc.returncode, 1)
                self.assertIn("credentials are incomplete", proc.stderr)
                calls = [json.loads(line) for line in record.read_text().splitlines()]
                self.assertFalse(any(argv[0] in ("post", "patch") for argv in calls))

        valid_required = {
            "id": "rev-1",
            "type": "betaAppReviewDetails",
            "attributes": {
                "contactEmail": "fresh@floorp.app",
                "contactFirstName": "Fresh",
                "contactLastName": "Reviewer",
                "contactPhone": "+81-00-0000-0000",
                "demoAccountRequired": True,
                "demoAccountName": "demo",
                "demoAccountPassword": "secret",
            },
        }
        proc, _, _, _, _ = self.run_script(
            "--authorize-mutation", state_overrides={"review": valid_required}
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_contact_fields_and_boolean_demo_flag_are_mandatory_before_writes(self):
        base = {
            "contactEmail": "fresh@floorp.app",
            "contactFirstName": "Fresh",
            "contactLastName": "Reviewer",
            "contactPhone": "+81-00-0000-0000",
            "demoAccountRequired": False,
            "demoAccountName": None,
            "demoAccountPassword": None,
        }
        cases = (
            ({**base, "contactPhone": ""}, "contact fields are incomplete"),
            ({**base, "demoAccountRequired": "false"}, "must be a boolean"),
        )
        for attributes, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                review = {
                    "id": "rev-1",
                    "type": "betaAppReviewDetails",
                    "attributes": attributes,
                }
                proc, record, _, _, _ = self.run_script(
                    "--authorize-mutation", state_overrides={"review": review}
                )
                self.assertEqual(proc.returncode, 1)
                self.assertIn(expected_error, proc.stderr)
                calls = [json.loads(line) for line in record.read_text().splitlines()]
                self.assertFalse(any(argv[0] in ("post", "patch") for argv in calls))

    def test_source_bound_preflight_failures_perform_zero_writes(self):
        run = {
            "data": {
                "type": "ciBuildRuns",
                "id": RUN_ID,
                "attributes": {
                    "executionProgress": "COMPLETE",
                    "completionStatus": "SUCCEEDED",
                    "sourceCommit": {"commitSha": "b" * 40},
                },
                "relationships": {
                    "workflow": {
                        "data": {"type": "ciWorkflows", "id": WORKFLOW_ID}
                    }
                },
            }
        }
        cases = (
            ({"run": run}, None, "source commit"),
            ({"linkage": {"data": [], "links": {"next": None}}}, None, "exactly one"),
            (
                {
                    "linkage": {
                        "data": [
                            {"type": "builds", "id": BUILD_ID},
                            {"type": "builds", "id": "other-build"},
                        ],
                        "links": {"next": None},
                    }
                },
                None,
                "exactly one",
            ),
            (
                {
                    "linkage": {
                        "data": [{"type": "builds", "id": BUILD_ID}],
                        "links": {"next": "https://example.invalid/next"},
                    }
                },
                None,
                "paginated",
            ),
            (
                {"group_build_links": {"next": "https://example.invalid/next"}},
                None,
                "external group builds response is paginated",
            ),
            (
                {"group_builds": [
                    {"type": "builds", "id": BUILD_ID},
                    {"type": "builds", "id": BUILD_ID},
                ]},
                None,
                "duplicate resources",
            ),
            (
                {"group": {
                    "data": {
                        "type": "betaGroups",
                        "id": "grp-1",
                        "attributes": {"isInternalGroup": True},
                        "relationships": {
                            "app": {"data": {"type": "apps", "id": APP_ID}}
                        },
                    },
                    "included": [{
                        "type": "apps", "id": APP_ID,
                        "attributes": {"bundleId": BUNDLE_ID},
                    }],
                }},
                None,
                "not an external",
            ),
            (
                {"group": {
                    "data": {
                        "type": "betaGroups",
                        "id": "grp-1",
                        "attributes": {"isInternalGroup": False},
                        "relationships": {
                            "app": {"data": {"type": "apps", "id": "other-app"}}
                        },
                    },
                    "included": [{
                        "type": "apps", "id": "other-app",
                        "attributes": {"bundleId": "other.bundle"},
                    }],
                }},
                None,
                "different app",
            ),
            ({}, {"build": {"number": "95"}}, "receipt"),
        )
        for state_overrides, receipt_overrides, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                proc, record, _, _, _ = self.run_script(
                    "--authorize-mutation",
                    state_overrides=state_overrides,
                    receipt_overrides=receipt_overrides,
                )
                self.assertEqual(proc.returncode, 1)
                self.assertIn(expected_error, proc.stderr)
                calls = [json.loads(line) for line in record.read_text().splitlines()]
                self.assertFalse(any(argv[0] in ("post", "patch") for argv in calls))


if __name__ == "__main__":
    unittest.main()
