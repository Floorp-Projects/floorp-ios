#!/usr/bin/env python3
"""Validate and bind one Xcode Cloud run to one App Store Connect build.

The module is deliberately network-free.  Callers fetch the allowlisted JSON:API
resources, then use these functions (or the ``verify-submission`` command) to
enforce the release identity before performing any App Store Connect write.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
_BUILD_NUMBER = re.compile(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){0,2}")


class ReceiptError(ValueError):
    """A release resource is missing, ambiguous, or does not match policy."""


def _require_object(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReceiptError(f"{context} must be an object")
    return value


def _require_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise ReceiptError(f"{context} must be a non-empty string")
    return value


def _require_identifier(value: Any, context: str) -> str:
    value = _require_string(value, context)
    if re.fullmatch(r"[A-Za-z0-9._-]+", value) is None:
        raise ReceiptError(f"{context} contains unsafe characters")
    return value


def _reject_pagination(response: dict[str, Any], context: str) -> None:
    links = response.get("links")
    if links is not None and not isinstance(links, dict):
        raise ReceiptError(f"{context} pagination metadata is malformed")
    if isinstance(links, dict) and links.get("next") not in (None, ""):
        raise ReceiptError(f"{context} is paginated")


def resource(
    response: dict[str, Any], resource_type: str, resource_id: str, context: str
) -> dict[str, Any]:
    response = _require_object(response, f"{context} response")
    value = _require_object(response.get("data"), f"{context} data")
    if value.get("type") != resource_type or value.get("id") != resource_id:
        raise ReceiptError(
            f"{context} identity mismatch: expected {resource_type} {resource_id}"
        )
    return value


def included_resource(
    response: dict[str, Any], resource_type: str, resource_id: str, context: str
) -> dict[str, Any]:
    included = response.get("included")
    if not isinstance(included, list):
        raise ReceiptError(f"{context} included resources are missing")
    matches = [
        row
        for row in included
        if isinstance(row, dict)
        and row.get("type") == resource_type
        and row.get("id") == resource_id
    ]
    if len(matches) != 1:
        raise ReceiptError(
            f"{context} expected exactly one included {resource_type} {resource_id}; "
            f"found {len(matches)}"
        )
    return matches[0]


def relationship_id(
    value: dict[str, Any], name: str, resource_type: str, context: str
) -> str:
    relationships = _require_object(
        value.get("relationships"), f"{context} relationships"
    )
    relationship = _require_object(
        relationships.get(name), f"{context} {name} relationship"
    )
    linkage = _require_object(
        relationship.get("data"), f"{context} {name} relationship data"
    )
    if linkage.get("type") != resource_type:
        raise ReceiptError(
            f"{context} {name} relationship must target {resource_type}"
        )
    return _require_identifier(
        linkage.get("id"), f"{context} {name} relationship ID"
    )


def collection_rows(
    response: dict[str, Any], resource_type: str, context: str
) -> list[dict[str, Any]]:
    response = _require_object(response, f"{context} response")
    _reject_pagination(response, context)
    rows = response.get("data")
    if not isinstance(rows, list):
        raise ReceiptError(f"{context} data must be an array")
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict) or row.get("type") != resource_type:
            raise ReceiptError(f"{context} contains a non-{resource_type} resource")
        row_id = _require_identifier(row.get("id"), f"{context} resource ID")
        if row_id in seen:
            raise ReceiptError(f"{context} contains duplicate resource ID {row_id}")
        seen.add(row_id)
        result.append(row)
    return result


def parse_build_number(value: Any, context: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or _BUILD_NUMBER.fullmatch(value) is None:
        raise ReceiptError(f"{context} must be a canonical numeric build number")
    parts = [int(part) for part in value.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))  # type: ignore[return-value]


def capture_build_baseline(response: dict[str, Any], app_id: str) -> dict[str, Any]:
    rows = collection_rows(response, "builds", "pre-trigger app builds")
    numbers: list[tuple[tuple[int, int, int], str]] = []
    ids: list[str] = []
    for row in rows:
        ids.append(row["id"])
        attributes = _require_object(
            row.get("attributes"), "pre-trigger build attributes"
        )
        number = _require_string(
            attributes.get("version"), "pre-trigger build version"
        )
        numbers.append((parse_build_number(number, "pre-trigger build version"), number))
    max_number = max(numbers)[1] if numbers else None
    encoded_ids = json.dumps(sorted(ids), separators=(",", ":")).encode("utf-8")
    return {
        "app_id": app_id,
        "build_count": len(ids),
        "build_ids_sha256": hashlib.sha256(encoded_ids).hexdigest(),
        "max_build_number": max_number,
        "build_ids": sorted(ids),
    }


def validate_run(
    response: dict[str, Any],
    *,
    run_id: str,
    expected_source_sha: str,
    expected_workflow_id: str,
) -> dict[str, Any]:
    value = resource(response, "ciBuildRuns", run_id, "Xcode Cloud run")
    attributes = _require_object(value.get("attributes"), "Xcode Cloud run attributes")
    if attributes.get("executionProgress") != "COMPLETE":
        raise ReceiptError("Xcode Cloud run is not complete")
    if attributes.get("completionStatus") != "SUCCEEDED":
        raise ReceiptError("Xcode Cloud run did not succeed")
    source_commit = _require_object(
        attributes.get("sourceCommit"), "Xcode Cloud source commit"
    )
    if source_commit.get("commitSha") != expected_source_sha:
        raise ReceiptError("Xcode Cloud run source commit does not match")
    workflow_id = relationship_id(
        value, "workflow", "ciWorkflows", "Xcode Cloud run"
    )
    if workflow_id != expected_workflow_id:
        raise ReceiptError("Xcode Cloud run workflow does not match")
    return {
        "id": run_id,
        "execution_progress": "COMPLETE",
        "completion_status": "SUCCEEDED",
        "source_commit": expected_source_sha,
        "workflow_id": workflow_id,
    }


def validate_product(
    response: dict[str, Any],
    *,
    product_id: str,
    expected_app_id: str,
    expected_bundle_id: str,
) -> dict[str, Any]:
    value = resource(response, "ciProducts", product_id, "Xcode Cloud product")
    attributes = _require_object(value.get("attributes"), "Xcode Cloud product attributes")
    if attributes.get("productType") != "APP":
        raise ReceiptError("Xcode Cloud product is not an app product")
    app_id = relationship_id(value, "app", "apps", "Xcode Cloud product")
    if app_id != expected_app_id:
        raise ReceiptError("Xcode Cloud product belongs to a different app")
    app = included_resource(response, "apps", app_id, "Xcode Cloud product")
    app_attributes = _require_object(app.get("attributes"), "Xcode Cloud product app attributes")
    if app_attributes.get("bundleId") != expected_bundle_id:
        raise ReceiptError("Xcode Cloud product app bundle ID does not match")
    return {
        "id": product_id,
        "app_id": app_id,
        "bundle_id": expected_bundle_id,
        "product_type": "APP",
    }


def linked_build_id(response: dict[str, Any], *, allow_empty: bool = False) -> str | None:
    rows = collection_rows(response, "builds", "Xcode Cloud run build linkage")
    if not rows and allow_empty:
        return None
    if len(rows) != 1:
        raise ReceiptError(
            "Xcode Cloud run must link exactly one App Store Connect build; "
            f"found {len(rows)}"
        )
    return rows[0]["id"]


def _normalized_version(value: Any, context: str) -> tuple[int, ...]:
    if not isinstance(value, str) or re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value) is None:
        raise ReceiptError(f"{context} must be a numeric dotted version")
    parts = [int(part) for part in value.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def validate_build(
    response: dict[str, Any],
    *,
    build_id: str,
    expected_app_id: str,
    expected_bundle_id: str,
    expected_marketing_version: str,
    expected_platform: str,
    expected_min_os_version: str,
) -> dict[str, Any]:
    value = resource(response, "builds", build_id, "App Store Connect build")
    attributes = _require_object(
        value.get("attributes"), "App Store Connect build attributes"
    )
    number = _require_string(attributes.get("version"), "build number")
    parse_build_number(number, "build number")
    if attributes.get("processingState") != "VALID":
        raise ReceiptError("App Store Connect build processing state is not VALID")
    if attributes.get("buildAudienceType") != "APP_STORE_ELIGIBLE":
        raise ReceiptError("App Store Connect build is not APP_STORE_ELIGIBLE")
    if attributes.get("expired") is not False:
        raise ReceiptError("App Store Connect build is expired or expiry is unknown")
    if attributes.get("usesNonExemptEncryption") is not False:
        raise ReceiptError(
            "App Store Connect build uses non-exempt encryption or encryption status is unknown"
        )
    min_os = _require_string(attributes.get("minOsVersion"), "minimum OS version")
    if _normalized_version(min_os, "minimum OS version") != _normalized_version(
        expected_min_os_version, "expected minimum OS version"
    ):
        raise ReceiptError(
            f"minimum OS version mismatch: expected {expected_min_os_version}, got {min_os}"
        )

    app_id = relationship_id(value, "app", "apps", "App Store Connect build")
    if app_id != expected_app_id:
        raise ReceiptError("App Store Connect build belongs to a different app")
    app = included_resource(response, "apps", app_id, "App Store Connect build")
    app_attributes = _require_object(app.get("attributes"), "app attributes")
    bundle_id = app_attributes.get("bundleId")
    if bundle_id != expected_bundle_id:
        raise ReceiptError(
            f"bundle ID mismatch: expected {expected_bundle_id}, got {bundle_id}"
        )

    prerelease_id = relationship_id(
        value, "preReleaseVersion", "preReleaseVersions", "App Store Connect build"
    )
    prerelease = included_resource(
        response,
        "preReleaseVersions",
        prerelease_id,
        "App Store Connect build",
    )
    prerelease_attributes = _require_object(
        prerelease.get("attributes"), "prerelease version attributes"
    )
    marketing_version = prerelease_attributes.get("version")
    if marketing_version != expected_marketing_version:
        raise ReceiptError(
            "App Store Connect build marketing version does not match"
        )
    platform = prerelease_attributes.get("platform")
    if platform != expected_platform:
        raise ReceiptError("App Store Connect build platform does not match")

    return {
        "id": build_id,
        "number": number,
        "app_id": app_id,
        "bundle_id": bundle_id,
        "marketing_version": marketing_version,
        "platform": platform,
        "processing_state": "VALID",
        "build_audience_type": "APP_STORE_ELIGIBLE",
        "expired": False,
        "uses_non_exempt_encryption": False,
        "min_os_version": min_os,
    }


def ensure_new_build(
    build: dict[str, Any], baseline: dict[str, Any]
) -> None:
    if build.get("app_id") != baseline.get("app_id"):
        raise ReceiptError("build and baseline app IDs do not match")
    build_id = _require_string(build.get("id"), "build ID")
    build_ids = baseline.get("build_ids")
    if not isinstance(build_ids, list) or not all(
        isinstance(value, str) and value for value in build_ids
    ):
        raise ReceiptError("baseline build IDs are invalid")
    if build_id in build_ids:
        raise ReceiptError("Xcode Cloud linked a build that existed before this run")
    number = _require_string(build.get("number"), "build number")
    current = parse_build_number(number, "build number")
    prior_number = baseline.get("max_build_number")
    if prior_number is not None:
        prior = parse_build_number(prior_number, "baseline max build number")
        if current <= prior:
            raise ReceiptError(
                f"build number {number} is not newer than baseline {prior_number}"
            )


def make_receipt(
    *,
    workflow_id: str,
    workflow_name: str,
    product_id: str,
    source_name: str,
    source_kind: str,
    source_reference_id: str,
    run: dict[str, Any],
    baseline: dict[str, Any],
    build: dict[str, Any],
) -> dict[str, Any]:
    ensure_new_build(build, baseline)
    return {
        "schema_version": SCHEMA_VERSION,
        "workflow": {
            "id": workflow_id,
            "name": workflow_name,
            "product_id": product_id,
        },
        "source": {
            "name": source_name,
            "kind": source_kind,
            "reference_id": source_reference_id,
            "commit_sha": run["source_commit"],
        },
        "run": run,
        "baseline": {
            key: baseline[key]
            for key in (
                "app_id",
                "build_count",
                "build_ids_sha256",
                "max_build_number",
            )
        },
        "build": build,
    }


def validate_receipt(
    receipt: dict[str, Any],
    *,
    expected_run_id: str,
    expected_workflow_id: str,
    expected_source_sha: str,
    expected_build_id: str,
    expected_build_number: str,
    expected_app_id: str,
    expected_bundle_id: str,
    expected_marketing_version: str,
    expected_platform: str,
    expected_min_os_version: str,
) -> dict[str, Any]:
    receipt = _require_object(receipt, "build receipt")
    if set(receipt) != {
        "schema_version", "workflow", "source", "run", "baseline", "build"
    }:
        raise ReceiptError("build receipt top-level fields are invalid")
    if receipt.get("schema_version") != SCHEMA_VERSION:
        raise ReceiptError("build receipt schema version is unsupported")
    workflow = _require_object(receipt.get("workflow"), "build receipt workflow")
    source = _require_object(receipt.get("source"), "build receipt source")
    run = _require_object(receipt.get("run"), "build receipt run")
    baseline = _require_object(receipt.get("baseline"), "build receipt baseline")
    build = _require_object(receipt.get("build"), "build receipt build")
    if set(workflow) != {"id", "name", "product_id"}:
        raise ReceiptError("build receipt workflow fields are invalid")
    if set(source) != {"name", "kind", "reference_id", "commit_sha"}:
        raise ReceiptError("build receipt source fields are invalid")
    if set(run) != {
        "id", "execution_progress", "completion_status", "source_commit", "workflow_id"
    }:
        raise ReceiptError("build receipt run fields are invalid")
    if set(baseline) != {
        "app_id", "build_count", "build_ids_sha256", "max_build_number"
    }:
        raise ReceiptError("build receipt baseline fields are invalid")
    if set(build) != {
        "id", "number", "app_id", "bundle_id", "marketing_version", "platform",
        "processing_state", "build_audience_type", "expired",
        "uses_non_exempt_encryption", "min_os_version",
    }:
        raise ReceiptError("build receipt build fields are invalid")
    if re.fullmatch(r"[0-9a-f]{40}", expected_source_sha) is None:
        raise ReceiptError("expected source SHA must be 40 lowercase hexadecimal characters")
    if source.get("kind") != "tag" or source.get("name") != (
        f"floorp-catalog-{expected_source_sha}"
    ):
        raise ReceiptError("build receipt source tag is not commit-bound")
    _require_identifier(source.get("reference_id"), "build receipt source reference ID")
    _require_identifier(workflow.get("product_id"), "build receipt product ID")
    _require_string(workflow.get("name"), "build receipt workflow name")
    count = baseline.get("build_count")
    digest = baseline.get("build_ids_sha256")
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        raise ReceiptError("build receipt baseline count is invalid")
    if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise ReceiptError("build receipt baseline digest is invalid")
    expected = {
        "workflow.id": (workflow.get("id"), expected_workflow_id),
        "source.commit_sha": (source.get("commit_sha"), expected_source_sha),
        "run.id": (run.get("id"), expected_run_id),
        "run.source_commit": (run.get("source_commit"), expected_source_sha),
        "run.workflow_id": (run.get("workflow_id"), expected_workflow_id),
        "run.execution_progress": (run.get("execution_progress"), "COMPLETE"),
        "run.completion_status": (run.get("completion_status"), "SUCCEEDED"),
        "baseline.app_id": (baseline.get("app_id"), expected_app_id),
        "build.id": (build.get("id"), expected_build_id),
        "build.number": (build.get("number"), expected_build_number),
        "build.app_id": (build.get("app_id"), expected_app_id),
        "build.bundle_id": (build.get("bundle_id"), expected_bundle_id),
        "build.marketing_version": (
            build.get("marketing_version"),
            expected_marketing_version,
        ),
        "build.platform": (build.get("platform"), expected_platform),
        "build.processing_state": (build.get("processing_state"), "VALID"),
        "build.build_audience_type": (
            build.get("build_audience_type"),
            "APP_STORE_ELIGIBLE",
        ),
        "build.expired": (build.get("expired"), False),
        "build.uses_non_exempt_encryption": (
            build.get("uses_non_exempt_encryption"),
            False,
        ),
    }
    mismatches = [name for name, (actual, wanted) in expected.items() if actual != wanted]
    if mismatches:
        raise ReceiptError(
            "build receipt does not match expected release identity: "
            + ", ".join(mismatches)
        )
    for value, context in (
        (expected_run_id, "expected run ID"),
        (expected_workflow_id, "expected workflow ID"),
        (expected_build_id, "expected build ID"),
        (expected_app_id, "expected app ID"),
    ):
        _require_identifier(value, context)
    parse_build_number(expected_build_number, "expected build number")
    if _normalized_version(build.get("min_os_version"), "receipt minimum OS version") != _normalized_version(
        expected_min_os_version, "expected minimum OS version"
    ):
        raise ReceiptError("build receipt minimum OS version does not match")
    max_number = baseline.get("max_build_number")
    if max_number is not None and parse_build_number(
        expected_build_number, "expected build number"
    ) <= parse_build_number(max_number, "receipt baseline max build number"):
        raise ReceiptError("build receipt does not prove a newer build number")
    return build


def validate_group(
    response: dict[str, Any],
    *,
    group_id: str,
    expected_app_id: str,
    expected_bundle_id: str,
) -> dict[str, Any]:
    value = resource(response, "betaGroups", group_id, "TestFlight beta group")
    attributes = _require_object(value.get("attributes"), "beta group attributes")
    if attributes.get("isInternalGroup") is not False:
        raise ReceiptError("TestFlight beta group is not an external group")
    app_id = relationship_id(value, "app", "apps", "TestFlight beta group")
    if app_id != expected_app_id:
        raise ReceiptError("TestFlight beta group belongs to a different app")
    app = included_resource(response, "apps", app_id, "TestFlight beta group")
    app_attributes = _require_object(app.get("attributes"), "beta group app attributes")
    if app_attributes.get("bundleId") != expected_bundle_id:
        raise ReceiptError("TestFlight beta group app bundle ID does not match")
    return {"id": group_id, "app_id": app_id, "is_internal_group": False}


def verify_submission(
    *,
    receipt: dict[str, Any],
    run_response: dict[str, Any],
    linkage_response: dict[str, Any],
    build_response: dict[str, Any],
    group_response: dict[str, Any],
    expected_run_id: str,
    expected_workflow_id: str,
    expected_source_sha: str,
    expected_build_id: str,
    expected_build_number: str,
    expected_app_id: str,
    expected_bundle_id: str,
    expected_marketing_version: str,
    expected_platform: str,
    expected_min_os_version: str,
    expected_group_id: str,
) -> dict[str, Any]:
    receipt_build = validate_receipt(
        receipt,
        expected_run_id=expected_run_id,
        expected_workflow_id=expected_workflow_id,
        expected_source_sha=expected_source_sha,
        expected_build_id=expected_build_id,
        expected_build_number=expected_build_number,
        expected_app_id=expected_app_id,
        expected_bundle_id=expected_bundle_id,
        expected_marketing_version=expected_marketing_version,
        expected_platform=expected_platform,
        expected_min_os_version=expected_min_os_version,
    )
    run = validate_run(
        run_response,
        run_id=expected_run_id,
        expected_source_sha=expected_source_sha,
        expected_workflow_id=expected_workflow_id,
    )
    live_build_id = linked_build_id(linkage_response)
    if live_build_id != expected_build_id:
        raise ReceiptError("Xcode Cloud run now links a different build")
    build = validate_build(
        build_response,
        build_id=expected_build_id,
        expected_app_id=expected_app_id,
        expected_bundle_id=expected_bundle_id,
        expected_marketing_version=expected_marketing_version,
        expected_platform=expected_platform,
        expected_min_os_version=expected_min_os_version,
    )
    if build != receipt_build:
        raise ReceiptError("live App Store Connect build no longer matches the receipt")
    group = validate_group(
        group_response,
        group_id=expected_group_id,
        expected_app_id=expected_app_id,
        expected_bundle_id=expected_bundle_id,
    )
    return {
        "status": "source-bound-build-verified",
        "run_id": run["id"],
        "build_id": build["id"],
        "build_number": build["number"],
        "group_id": group["id"],
    }


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    return _require_object(value, str(path))


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("verify-submission",))
    for name in ("receipt", "run", "linkage", "build", "group", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--expected-run-id", required=True)
    parser.add_argument("--expected-workflow-id", required=True)
    parser.add_argument("--expected-source-sha", required=True)
    parser.add_argument("--expected-build-id", required=True)
    parser.add_argument("--expected-build-number", required=True)
    parser.add_argument("--expected-app-id", required=True)
    parser.add_argument("--expected-bundle-id", required=True)
    parser.add_argument("--expected-marketing-version", required=True)
    parser.add_argument("--expected-platform", required=True)
    parser.add_argument("--expected-min-os-version", required=True)
    parser.add_argument("--expected-group-id", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        result = verify_submission(
            receipt=_read_json(arguments.receipt),
            run_response=_read_json(arguments.run),
            linkage_response=_read_json(arguments.linkage),
            build_response=_read_json(arguments.build),
            group_response=_read_json(arguments.group),
            expected_run_id=arguments.expected_run_id,
            expected_workflow_id=arguments.expected_workflow_id,
            expected_source_sha=arguments.expected_source_sha,
            expected_build_id=arguments.expected_build_id,
            expected_build_number=arguments.expected_build_number,
            expected_app_id=arguments.expected_app_id,
            expected_bundle_id=arguments.expected_bundle_id,
            expected_marketing_version=arguments.expected_marketing_version,
            expected_platform=arguments.expected_platform,
            expected_min_os_version=arguments.expected_min_os_version,
            expected_group_id=arguments.expected_group_id,
        )
        arguments.output.write_text(
            json.dumps(result, separators=(",", ":"), sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(json.dumps(result, separators=(",", ":"), sort_keys=True))
        return 0
    except (ReceiptError, json.JSONDecodeError, OSError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
