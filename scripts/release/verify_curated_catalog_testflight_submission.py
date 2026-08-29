#!/usr/bin/env python3
"""Bind a curated-catalog TestFlight submission to its Xcode Cloud build.

This verifier is read-only.  A caller must run it after the checked-in signed
catalog is verified and before it updates Beta App Review details, submits a
build, or assigns an external group.  It rejects a supplied App Store Connect
build unless it is the sole build produced by the exact completed Xcode Cloud
tag run for the current curated-catalog candidate.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable


SHA = re.compile(r"[0-9a-f]{40}\Z")
RESOURCE_ID = re.compile(r"[A-Za-z0-9._-]+\Z")
CATALOG_TAG = re.compile(r"floorp-catalog-([0-9a-f]{40})\Z")


class CuratedCatalogSubmissionError(RuntimeError):
    """The pending TestFlight operation is not bound to this candidate."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CuratedCatalogSubmissionError(message)


def _load_module(filename: str, name: str):
    path = Path(__file__).with_name(filename)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise CuratedCatalogSubmissionError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _resource(response: dict[str, Any], expected_type: str, expected_id: str, label: str) -> dict[str, Any]:
    data = response.get("data")
    _require(isinstance(data, dict), f"{label} has no resource data")
    _require(data.get("type") == expected_type and data.get("id") == expected_id, f"{label} identity is invalid")
    return data


def _relationship_id(resource: dict[str, Any], name: str, expected_type: str, label: str) -> str:
    relationships = resource.get("relationships")
    relationship = relationships.get(name) if isinstance(relationships, dict) else None
    data = relationship.get("data") if isinstance(relationship, dict) else None
    _require(
        isinstance(data, dict)
        and data.get("type") == expected_type
        and isinstance(data.get("id"), str)
        and RESOURCE_ID.fullmatch(data["id"]) is not None,
        f"{label} relationship is invalid",
    )
    return data["id"]


def _catalog_evidence(path: Path, marketing_version: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CuratedCatalogSubmissionError(f"cannot read signed catalog evidence: {error}") from error
    _require(isinstance(value, dict), "signed catalog evidence is not an object")
    _require(value.get("status") == "verified", "signed catalog evidence is not verified")
    _require(value.get("catalogID") == "floorp-ios-curated-testflight", "catalog identity is unexpected")
    _require(value.get("marketingVersion") == marketing_version, "catalog evidence marketing version is unexpected")
    _require(value.get("packageCount") == 17, "catalog evidence does not contain the fixed 17 packages")
    for field in ("catalogSHA256", "catalogInputSHA256", "rootPublicKeySHA256"):
        _require(isinstance(value.get(field), str) and re.fullmatch(r"[0-9a-f]{64}", value[field]) is not None, f"catalog evidence {field} is invalid")
    _require(isinstance(value.get("sequence"), int) and value["sequence"] > 0, "catalog evidence sequence is invalid")
    return value


def verify_submission(
    *,
    api: Callable[[str, str], dict[str, Any]],
    workflow_id: str,
    workflow_name: str,
    repository_url: str,
    candidate_tag: str,
    candidate_sha: str,
    xcode_cloud_run_id: str,
    build_id: str,
    app_id: str,
    marketing_version: str,
    catalog_evidence: dict[str, Any],
) -> dict[str, Any]:
    """Verify all source, build, and signed-catalog relationships read-only."""

    _require(SHA.fullmatch(candidate_sha) is not None, "candidate SHA is invalid")
    tag_match = CATALOG_TAG.fullmatch(candidate_tag)
    _require(tag_match is not None and tag_match.group(1) == candidate_sha, "candidate tag does not name the candidate SHA")
    for label, value in (("Xcode Cloud run", xcode_cloud_run_id), ("App Store build", build_id), ("app", app_id)):
        _require(RESOURCE_ID.fullmatch(value) is not None, f"{label} identifier is invalid")
    _require(catalog_evidence["marketingVersion"] == marketing_version, "catalog evidence is for a different release version")

    trigger = _load_module("trigger-xcode-cloud.py", "floorp_trigger_xcode_cloud")
    _workflow, repository_id, _repository = trigger.verify_workflow(
        api, workflow_id, workflow_name, repository_url
    )
    reference = trigger.resolve_tag(api, repository_id, candidate_tag)
    reference_id = reference.get("id")
    _require(isinstance(reference_id, str) and RESOURCE_ID.fullmatch(reference_id) is not None, "candidate tag has no valid App Store Connect reference")

    run = _resource(
        api(
            "GET",
            f"/v1/ciBuildRuns/{xcode_cloud_run_id}?include=workflow,sourceBranchOrTag",
        ),
        "ciBuildRuns",
        xcode_cloud_run_id,
        "Xcode Cloud run",
    )
    attributes = run.get("attributes")
    _require(isinstance(attributes, dict), "Xcode Cloud run attributes are missing")
    source_commit = attributes.get("sourceCommit")
    _require(isinstance(source_commit, dict) and source_commit.get("commitSha") == candidate_sha, "Xcode Cloud run source commit does not match the candidate")
    _require(attributes.get("executionProgress") == "COMPLETE", "Xcode Cloud run is not complete")
    _require(attributes.get("completionStatus") == "SUCCEEDED", "Xcode Cloud run did not succeed")
    _require(_relationship_id(run, "workflow", "ciWorkflows", "Xcode Cloud run") == workflow_id, "Xcode Cloud run uses an unexpected workflow")
    _require(_relationship_id(run, "sourceBranchOrTag", "scmGitReferences", "Xcode Cloud run") == reference_id, "Xcode Cloud run uses an unexpected source tag")

    linkage = api("GET", f"/v1/ciBuildRuns/{xcode_cloud_run_id}/relationships/builds")
    linked_builds = linkage.get("data")
    _require(isinstance(linked_builds, list) and len(linked_builds) == 1, "Xcode Cloud run must produce exactly one App Store build")
    linked = linked_builds[0]
    _require(isinstance(linked, dict) and linked.get("type") == "builds" and linked.get("id") == build_id, "selected App Store build is not the Xcode Cloud run output")

    build = _resource(
        api("GET", f"/v1/builds/{build_id}?include=preReleaseVersion"),
        "builds",
        build_id,
        "App Store build",
    )
    build_attributes = build.get("attributes")
    _require(isinstance(build_attributes, dict), "App Store build attributes are missing")
    _require(build_attributes.get("processingState") == "VALID", "App Store build has not processed successfully")
    build_number = build_attributes.get("version")
    _require(isinstance(build_number, str) and re.fullmatch(r"[1-9][0-9]*", build_number) is not None, "App Store build number is invalid")

    prerelease = _resource(
        api("GET", f"/v1/builds/{build_id}/preReleaseVersion"),
        "preReleaseVersions",
        _relationship_id(build, "preReleaseVersion", "preReleaseVersions", "App Store build"),
        "pre-release version",
    )
    prerelease_attributes = prerelease.get("attributes")
    _require(isinstance(prerelease_attributes, dict) and prerelease_attributes.get("version") == marketing_version, "App Store build marketing version does not match the signed catalog")
    _require(_relationship_id(prerelease, "app", "apps", "pre-release version") == app_id, "App Store build belongs to a different app")

    return {
        "appID": app_id,
        "buildID": build_id,
        "buildNumber": build_number,
        "candidateSHA": candidate_sha,
        "candidateTag": candidate_tag,
        "catalogID": catalog_evidence["catalogID"],
        "catalogSHA256": catalog_evidence["catalogSHA256"],
        "catalogSequence": catalog_evidence["sequence"],
        "marketingVersion": marketing_version,
        "packageCount": catalog_evidence["packageCount"],
        "status": "verified",
        "xcodeCloudRunID": xcode_cloud_run_id,
    }


def _write_new(path: Path, value: dict[str, Any]) -> None:
    _require(path.is_absolute(), "submission verification output must be an absolute path")
    _require(not path.exists(), "submission verification refuses to overwrite evidence")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow-id", required=True)
    parser.add_argument("--expected-workflow-name", required=True)
    parser.add_argument("--expected-repository", required=True)
    parser.add_argument("--candidate-tag", required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--xcode-cloud-run-id", required=True)
    parser.add_argument("--build-id", required=True)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--marketing-version", required=True)
    parser.add_argument("--catalog-evidence", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser


def run(arguments: argparse.Namespace) -> dict[str, Any]:
    catalog = _catalog_evidence(arguments.catalog_evidence, arguments.marketing_version)
    client = _load_module("app-store-connect-api.py", "floorp_app_store_connect_api")
    issuer_id, key_id, private_key = client.load_credentials(
        SimpleNamespace(issuer_id=None, key_id=None, private_key=None)
    )

    def api(method: str, path: str) -> dict[str, Any]:
        jwt = client.make_jwt(issuer_id, key_id, private_key, int(time.time()))
        value = client.api_call(method, path, jwt)
        if not isinstance(value, dict):
            raise CuratedCatalogSubmissionError("App Store Connect returned no JSON response")
        return value

    return verify_submission(
        api=api,
        workflow_id=arguments.workflow_id,
        workflow_name=arguments.expected_workflow_name,
        repository_url=arguments.expected_repository,
        candidate_tag=arguments.candidate_tag,
        candidate_sha=arguments.candidate_sha,
        xcode_cloud_run_id=arguments.xcode_cloud_run_id,
        build_id=arguments.build_id,
        app_id=arguments.app_id,
        marketing_version=arguments.marketing_version,
        catalog_evidence=catalog,
    )


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        evidence = run(arguments)
        _write_new(arguments.output, evidence)
    except (CuratedCatalogSubmissionError, OSError, ValueError) as error:
        print(f"curated catalog TestFlight submission verification failed: {error}", file=__import__("sys").stderr)
        return 2
    print(json.dumps(evidence, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
