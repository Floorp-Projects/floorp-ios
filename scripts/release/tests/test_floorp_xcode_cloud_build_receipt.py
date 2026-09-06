"""Tests for the source-bound Xcode Cloud/App Store Connect build receipt."""

import copy
import importlib.util
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).parent.parent / "floorp_xcode_cloud_build_receipt.py"
    spec = importlib.util.spec_from_file_location("floorp_build_receipt", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


receipt_module = load_module()

APP_ID = "6796708699"
BUNDLE_ID = "app.floorp.Floorp"
WORKFLOW_ID = "workflow-1"
RUN_ID = "run-1"
BUILD_ID = "build-96"
SOURCE_SHA = "a" * 40
GROUP_ID = "external-group"


def run_response(source_sha=SOURCE_SHA, workflow_id=WORKFLOW_ID):
    return {
        "data": {
            "type": "ciBuildRuns",
            "id": RUN_ID,
            "attributes": {
                "executionProgress": "COMPLETE",
                "completionStatus": "SUCCEEDED",
                "sourceCommit": {"commitSha": source_sha},
            },
            "relationships": {
                "workflow": {
                    "data": {"type": "ciWorkflows", "id": workflow_id}
                }
            },
        }
    }


def linkage_response(*ids, next_link=None, resource_type="builds"):
    return {
        "data": [{"type": resource_type, "id": value} for value in ids],
        "links": {"next": next_link},
    }


def build_response(**overrides):
    attributes = {
        "version": "96",
        "processingState": "VALID",
        "buildAudienceType": "APP_STORE_ELIGIBLE",
        "expired": False,
        "usesNonExemptEncryption": False,
        "minOsVersion": "18.4",
    }
    attributes.update(overrides.pop("attributes", {}))
    app_id = overrides.pop("app_id", APP_ID)
    bundle_id = overrides.pop("bundle_id", BUNDLE_ID)
    marketing_version = overrides.pop("marketing_version", "0.3.0")
    platform = overrides.pop("platform", "IOS")
    build_id = overrides.pop("build_id", BUILD_ID)
    if overrides:
        raise AssertionError(f"unused overrides: {overrides}")
    return {
        "data": {
            "type": "builds",
            "id": build_id,
            "attributes": attributes,
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "preReleaseVersion": {
                    "data": {"type": "preReleaseVersions", "id": "train-1"}
                },
            },
        },
        "included": [
            {
                "type": "apps",
                "id": app_id,
                "attributes": {"bundleId": bundle_id},
            },
            {
                "type": "preReleaseVersions",
                "id": "train-1",
                "attributes": {
                    "version": marketing_version,
                    "platform": platform,
                },
            },
        ],
    }


def group_response(app_id=APP_ID, bundle_id=BUNDLE_ID, internal=False):
    return {
        "data": {
            "type": "betaGroups",
            "id": GROUP_ID,
            "attributes": {"name": "External Beta", "isInternalGroup": internal},
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}}
            },
        },
        "included": [
            {
                "type": "apps",
                "id": app_id,
                "attributes": {"bundleId": bundle_id},
            }
        ],
    }


def baseline_response():
    return {
        "data": [
            {
                "type": "builds",
                "id": "build-95",
                "attributes": {"version": "95"},
            }
        ],
        "links": {"next": None},
    }


def make_receipt():
    baseline = receipt_module.capture_build_baseline(baseline_response(), APP_ID)
    run = receipt_module.validate_run(
        run_response(),
        run_id=RUN_ID,
        expected_source_sha=SOURCE_SHA,
        expected_workflow_id=WORKFLOW_ID,
    )
    build = receipt_module.validate_build(
        build_response(),
        build_id=BUILD_ID,
        expected_app_id=APP_ID,
        expected_bundle_id=BUNDLE_ID,
        expected_marketing_version="0.3.0",
        expected_platform="IOS",
        expected_min_os_version="18.4",
    )
    return receipt_module.make_receipt(
        workflow_id=WORKFLOW_ID,
        workflow_name="Floorp TestFlight Manual",
        product_id="product-1",
        source_name=f"floorp-catalog-{SOURCE_SHA}",
        source_kind="tag",
        source_reference_id="tag-reference",
        run=run,
        baseline=baseline,
        build=build,
    )


class BuildReceiptTests(unittest.TestCase):
    def test_happy_path_binds_new_build_and_external_group(self):
        result = receipt_module.verify_submission(
            receipt=make_receipt(),
            run_response=run_response(),
            linkage_response=linkage_response(BUILD_ID),
            build_response=build_response(),
            group_response=group_response(),
            expected_run_id=RUN_ID,
            expected_workflow_id=WORKFLOW_ID,
            expected_source_sha=SOURCE_SHA,
            expected_build_id=BUILD_ID,
            expected_build_number="96",
            expected_app_id=APP_ID,
            expected_bundle_id=BUNDLE_ID,
            expected_marketing_version="0.3.0",
            expected_platform="IOS",
            expected_min_os_version="18.4",
            expected_group_id=GROUP_ID,
        )
        self.assertEqual(result["status"], "source-bound-build-verified")
        self.assertEqual(result["build_number"], "96")

    def test_linkage_must_be_exactly_one_nonpaginated_build(self):
        cases = (
            (linkage_response(), "exactly one"),
            (linkage_response(BUILD_ID, "other"), "exactly one"),
            (
                linkage_response(BUILD_ID, next_link="https://example.invalid/next"),
                "paginated",
            ),
            (linkage_response(BUILD_ID, resource_type="apps"), "non-builds"),
        )
        for response, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(receipt_module.ReceiptError, message):
                    receipt_module.linked_build_id(response)

    def test_new_build_must_not_be_old_or_reuse_an_old_number(self):
        baseline = receipt_module.capture_build_baseline(baseline_response(), APP_ID)
        build = receipt_module.validate_build(
            build_response(build_id="build-95", attributes={"version": "95"}),
            build_id="build-95",
            expected_app_id=APP_ID,
            expected_bundle_id=BUNDLE_ID,
            expected_marketing_version="0.3.0",
            expected_platform="IOS",
            expected_min_os_version="18.4",
        )
        with self.assertRaisesRegex(receipt_module.ReceiptError, "existed before"):
            receipt_module.ensure_new_build(build, baseline)

        reused = dict(build)
        reused["id"] = "new-id"
        with self.assertRaisesRegex(receipt_module.ReceiptError, "not newer"):
            receipt_module.ensure_new_build(reused, baseline)

    def test_build_rejects_each_wrong_release_identity(self):
        cases = (
            ({"app_id": "other-app"}, "different app"),
            ({"bundle_id": "other.bundle"}, "bundle ID mismatch"),
            ({"marketing_version": "0.2.0"}, "marketing version"),
            ({"platform": "MAC_OS"}, "platform"),
            ({"attributes": {"processingState": "PROCESSING"}}, "processing state"),
            ({"attributes": {"buildAudienceType": "INTERNAL_ONLY"}}, "APP_STORE_ELIGIBLE"),
            ({"attributes": {"expired": True}}, "expired"),
            ({"attributes": {"usesNonExemptEncryption": True}}, "non-exempt encryption"),
            ({"attributes": {"minOsVersion": "18.5"}}, "minimum OS version mismatch"),
        )
        for overrides, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(receipt_module.ReceiptError, message):
                    receipt_module.validate_build(
                        build_response(**overrides),
                        build_id=BUILD_ID,
                        expected_app_id=APP_ID,
                        expected_bundle_id=BUNDLE_ID,
                        expected_marketing_version="0.3.0",
                        expected_platform="IOS",
                        expected_min_os_version="18.4",
                    )

    def test_run_rejects_wrong_source_status_or_workflow(self):
        cases = (
            (run_response(source_sha="b" * 40), "source commit"),
            (run_response(workflow_id="other"), "workflow"),
        )
        failed = run_response()
        failed["data"]["attributes"]["completionStatus"] = "FAILED"
        cases += ((failed, "did not succeed"),)
        for response, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(receipt_module.ReceiptError, message):
                    receipt_module.validate_run(
                        response,
                        run_id=RUN_ID,
                        expected_source_sha=SOURCE_SHA,
                        expected_workflow_id=WORKFLOW_ID,
                    )

    def test_receipt_tampering_is_rejected(self):
        for path, value in (
            (("run", "id"), "other-run"),
            (("source", "commit_sha"), "b" * 40),
            (("build", "id"), "other-build"),
            (("build", "number"), "95"),
            (("build", "bundle_id"), "other.bundle"),
        ):
            with self.subTest(path=path):
                receipt = copy.deepcopy(make_receipt())
                receipt[path[0]][path[1]] = value
                with self.assertRaises(receipt_module.ReceiptError):
                    receipt_module.validate_receipt(
                        receipt,
                        expected_run_id=RUN_ID,
                        expected_workflow_id=WORKFLOW_ID,
                        expected_source_sha=SOURCE_SHA,
                        expected_build_id=BUILD_ID,
                        expected_build_number="96",
                        expected_app_id=APP_ID,
                        expected_bundle_id=BUNDLE_ID,
                        expected_marketing_version="0.3.0",
                        expected_platform="IOS",
                        expected_min_os_version="18.4",
                    )

    def test_group_must_be_external_and_belong_to_same_app(self):
        with self.assertRaisesRegex(receipt_module.ReceiptError, "not an external"):
            receipt_module.validate_group(
                group_response(internal=True),
                group_id=GROUP_ID,
                expected_app_id=APP_ID,
                expected_bundle_id=BUNDLE_ID,
            )
        with self.assertRaisesRegex(receipt_module.ReceiptError, "different app"):
            receipt_module.validate_group(
                group_response(app_id="other-app"),
                group_id=GROUP_ID,
                expected_app_id=APP_ID,
                expected_bundle_id=BUNDLE_ID,
            )


if __name__ == "__main__":
    unittest.main()
