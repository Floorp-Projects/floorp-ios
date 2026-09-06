#!/usr/bin/env python3
"""Start one approved Xcode Cloud workflow for a specific Git reference.

This is the small control-plane used by GitHub Actions. Xcode Cloud remains
responsible for the Apple build, signing, archive, and App Store Connect
distribution. The script validates the workflow and repository before it
performs the sole write: POST /v1/ciBuildRuns.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable


CLIENT_PATH = Path(__file__).with_name("app-store-connect-api.py")
RECEIPT_PATH = Path(__file__).with_name("floorp_xcode_cloud_build_receipt.py")


def load_client():
    spec = importlib.util.spec_from_file_location("floorp_app_store_connect_api", CLIENT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load App Store Connect client: {CLIENT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_receipt_validator():
    spec = importlib.util.spec_from_file_location(
        "floorp_xcode_cloud_build_receipt", RECEIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load Xcode Cloud build receipt validator: {RECEIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resource_data(response: dict[str, Any], expected_type: str, expected_id: str) -> dict[str, Any]:
    value = response.get("data")
    if not isinstance(value, dict):
        raise ValueError("App Store Connect response has no resource data")
    if value.get("type") != expected_type or value.get("id") != expected_id:
        raise ValueError(
            f"unexpected resource identity: type={value.get('type')!r} id={value.get('id')!r}"
        )
    return value


def relationship_id(resource: dict[str, Any], *names: str) -> str | None:
    relationships = resource.get("relationships")
    if not isinstance(relationships, dict):
        return None
    for name in names:
        relationship = relationships.get(name)
        data = relationship.get("data") if isinstance(relationship, dict) else None
        if isinstance(data, dict) and isinstance(data.get("id"), str) and data.get("id"):
            return data["id"]
    return None


def normalize_repository_url(value: str) -> str:
    normalized = value.strip().lower().rstrip("/")
    if normalized.endswith(".git"):
        normalized = normalized[:-4]
    return normalized


def verify_workflow(
    api: Callable[..., dict[str, Any]],
    workflow_id: str,
    expected_name: str,
    expected_repository: str,
    expected_app_id: str,
    expected_bundle_id: str,
) -> tuple[
    dict[str, Any], dict[str, Any], str, dict[str, Any], str, dict[str, Any]
]:
    receipt_validator = load_receipt_validator()
    # This exact expanded representation is also the guarded-write snapshot.
    # Including the relationships makes product/repository retargeting visible
    # to the compare-and-swap check immediately before the build starts.
    response = api(
        "GET", f"/v1/ciWorkflows/{workflow_id}?include=product,repository"
    )
    workflow = resource_data(response, "ciWorkflows", workflow_id)
    attributes = workflow.get("attributes")
    if not isinstance(attributes, dict):
        raise ValueError("Xcode Cloud workflow has no attributes")
    if attributes.get("name") != expected_name:
        raise ValueError(
            f"workflow name mismatch: expected {expected_name!r}, got {attributes.get('name')!r}"
        )
    if attributes.get("isEnabled") is not True:
        raise ValueError("Xcode Cloud workflow is disabled")

    repository_id = relationship_id(workflow, "repository", "primaryRepository")
    if repository_id is None:
        raise ValueError("Xcode Cloud workflow has no repository relationship")
    repository = receipt_validator.included_resource(
        response, "scmRepositories", repository_id, "Xcode Cloud workflow"
    )
    repository_attributes = repository.get("attributes")
    if not isinstance(repository_attributes, dict):
        raise ValueError("Xcode Cloud repository has no attributes")
    actual_url = repository_attributes.get("httpCloneUrl")
    if not isinstance(actual_url, str) or normalize_repository_url(actual_url) != normalize_repository_url(expected_repository):
        raise ValueError(
            f"repository mismatch: expected {expected_repository!r}, got {actual_url!r}"
        )
    product_id = relationship_id(workflow, "product")
    if product_id is None:
        raise ValueError("Xcode Cloud workflow has no product relationship")
    product_response = api("GET", f"/v1/ciProducts/{product_id}?include=app")
    receipt_validator.validate_product(
        product_response,
        product_id=product_id,
        expected_app_id=expected_app_id,
        expected_bundle_id=expected_bundle_id,
    )
    return response, workflow, repository_id, repository, product_id, product_response


def resolve_source_reference(
    api: Callable[..., dict[str, Any]], repository_id: str, reference_name: str, reference_kind: str
) -> dict[str, Any]:
    """Resolve exactly one live Xcode Cloud branch or tag reference.

    A candidate release may use only an immutable, protected tag.  The generic
    deployment route remains restricted to ``main``; resolving the reference
    kind here prevents a same-named branch and tag from being confused.
    """
    if reference_kind not in {"branch", "tag"}:
        raise ValueError(f"unsupported Git reference kind {reference_kind!r}")
    response = api(
        "GET",
        f"/v1/scmRepositories/{repository_id}/gitReferences"
        f"?include=repository&limit=200",
    )
    links = response.get("links")
    if links is not None and not isinstance(links, dict):
        raise ValueError("App Store Connect Git reference pagination is malformed")
    if isinstance(links, dict) and links.get("next") not in (None, ""):
        raise ValueError(
            "App Store Connect Git references are paginated; refusing a partial lookup"
        )
    rows = response.get("data")
    if not isinstance(rows, list):
        raise ValueError("App Store Connect returned no Git references")
    canonical_prefix = "heads" if reference_kind == "branch" else "tags"
    canonical = f"refs/{canonical_prefix}/{reference_name}"
    matches = []
    for row in rows:
        if not isinstance(row, dict) or row.get("type") != "scmGitReferences":
            continue
        attributes = row.get("attributes")
        if not isinstance(attributes, dict) or attributes.get("isDeleted") is True:
            continue
        actual_kind = attributes.get("kind")
        if not isinstance(actual_kind, str) or actual_kind.lower() != reference_kind:
            continue
        # A source reference is a security boundary for the curated candidate:
        # the short display name is not enough.  Require both the API's name
        # and its canonical Git namespace to agree, so a malformed or
        # same-looking reference cannot be passed as the protected tag.
        if (
            attributes.get("name") == reference_name
            and attributes.get("canonicalName") == canonical
        ):
            matches.append(row)
    if len(matches) != 1:
        raise ValueError(
            f"expected one live {reference_kind} reference for {reference_name!r}, found {len(matches)}"
        )
    return matches[0]


def resolve_branch(
    api: Callable[..., dict[str, Any]], repository_id: str, branch: str
) -> dict[str, Any]:
    """Compatibility wrapper for the ordinary main-branch deployment route."""
    return resolve_source_reference(api, repository_id, branch, "branch")


def resolve_tag(
    api: Callable[..., dict[str, Any]], repository_id: str, tag: str
) -> dict[str, Any]:
    """Resolve a protected catalog-candidate tag without accepting a branch."""
    return resolve_source_reference(api, repository_id, tag, "tag")


def build_request(workflow_id: str, reference_id: str) -> dict[str, Any]:
    return {
        "data": {
            "type": "ciBuildRuns",
            "attributes": {},
            "relationships": {
                "workflow": {
                    "data": {"type": "ciWorkflows", "id": workflow_id}
                },
                "sourceBranchOrTag": {
                    "data": {"type": "scmGitReferences", "id": reference_id}
                },
            },
        }
    }


def credentials(client) -> tuple[str, str, Path]:
    arguments = SimpleNamespace(issuer_id=None, key_id=None, private_key=None)
    return client.load_credentials(arguments)


def run(arguments: argparse.Namespace) -> dict[str, Any]:
    if not arguments.authorize_mutation:
        raise ValueError("refusing to start a build without --authorize-mutation")
    if not re.fullmatch(r"[0-9a-f]{40}", arguments.expected_head):
        raise ValueError("expected source head must be a lowercase 40-character Git SHA")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", arguments.app_id):
        raise ValueError("App Store Connect app ID is invalid")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", arguments.expected_bundle_id):
        raise ValueError("expected bundle ID is invalid")

    if arguments.branch is not None:
        if arguments.branch != "main":
            raise ValueError("the ordinary release workflow only permits the main branch")
        source_name = arguments.branch
        source_kind = "branch"
    else:
        source_name = arguments.source_tag
        if not isinstance(source_name, str) or not re.fullmatch(
            r"floorp-catalog-[0-9a-f]{40}", source_name
        ):
            raise ValueError("catalog release tags must match floorp-catalog-<40 lowercase Git SHA>")
        source_kind = "tag"
        if not arguments.wait:
            raise ValueError("catalog-tag builds must wait for source-commit verification")

    client = load_client()
    receipt_validator = load_receipt_validator()
    issuer_id, key_id, private_key = credentials(client)

    def api(method: str, path: str) -> dict[str, Any]:
        token = client.make_jwt(issuer_id, key_id, private_key, int(time.time()))
        return client.api_call(method, path, token)

    (
        workflow_response,
        workflow,
        repository_id,
        repository,
        product_id,
        _product_response,
    ) = verify_workflow(
        api,
        arguments.workflow_id,
        arguments.expected_workflow_name,
        arguments.expected_repository,
        arguments.app_id,
        arguments.expected_bundle_id,
    )
    reference = resolve_source_reference(api, repository_id, source_name, source_kind)
    reference_id = reference.get("id")
    if not isinstance(reference_id, str) or not reference_id:
        raise ValueError("resolved Git reference has no ID")

    app_filter = urllib.parse.quote(arguments.app_id, safe="")
    baseline_response = api(
        "GET", f"/v1/builds?filter[app]={app_filter}&sort=-version&limit=200"
    )
    baseline = receipt_validator.capture_build_baseline(
        baseline_response, arguments.app_id
    )

    body = json.dumps(
        build_request(arguments.workflow_id, reference_id), separators=(",", ":")
    ).encode()
    guard_get = (
        f"/v1/ciWorkflows/{arguments.workflow_id}?include=product,repository"
    )
    prior_state = client.canonical_state_sha256(workflow_response)
    token = client.make_jwt(issuer_id, key_id, private_key, int(time.time()))
    start_response = client.guarded_write(
        "POST",
        "/v1/ciBuildRuns",
        token,
        body,
        arguments.workflow_id,
        prior_state,
        guard_get,
    )
    start_data = start_response.get("data")
    start_id = start_data.get("id") if isinstance(start_data, dict) else None
    run_resource = resource_data(start_response, "ciBuildRuns", str(start_id or ""))
    run_id = run_resource["id"]
    terminal_response = None
    receipt = None
    if arguments.wait:
        with tempfile.TemporaryDirectory(prefix="floorp-xcode-cloud-") as temporary:
            terminal_path = Path(temporary) / "terminal.json"
            polling_client = client.build_polling_client(
                issuer_id, key_id, private_key, dry_run=False
            )
            client.wait_ci_run(
                polling_client,
                run_id,
                arguments.expected_head,
                terminal_path,
                dry_run=False,
            )
            terminal_response = json.loads(terminal_path.read_text(encoding="utf-8"))

        # Re-read the terminal run with its workflow linkage, then wait for the
        # exact App Store Connect build produced by this run to finish processing.
        run_response = api(
            "GET", f"/v1/ciBuildRuns/{run_id}?include=workflow"
        )
        run_identity = receipt_validator.validate_run(
            run_response,
            run_id=run_id,
            expected_source_sha=arguments.expected_head,
            expected_workflow_id=arguments.workflow_id,
        )
        build_deadline = time.time() + 60 * 60
        while True:
            linkage_response = api(
                "GET",
                f"/v1/ciBuildRuns/{run_id}/relationships/builds?limit=200",
            )
            build_id = receipt_validator.linked_build_id(
                linkage_response, allow_empty=True
            )
            if build_id is not None:
                build_response = api(
                    "GET",
                    f"/v1/builds/{build_id}?include=app,preReleaseVersion",
                )
                build_resource = resource_data(
                    build_response, "builds", build_id
                )
                build_attributes = build_resource.get("attributes")
                processing_state = (
                    build_attributes.get("processingState")
                    if isinstance(build_attributes, dict)
                    else None
                )
                if processing_state == "VALID":
                    build_identity = receipt_validator.validate_build(
                        build_response,
                        build_id=build_id,
                        expected_app_id=arguments.app_id,
                        expected_bundle_id=arguments.expected_bundle_id,
                        expected_marketing_version=arguments.expected_marketing_version,
                        expected_platform=arguments.expected_platform,
                        expected_min_os_version=arguments.expected_min_os_version,
                    )
                    receipt_validator.ensure_new_build(build_identity, baseline)
                    receipt = receipt_validator.make_receipt(
                        workflow_id=arguments.workflow_id,
                        workflow_name=arguments.expected_workflow_name,
                        product_id=product_id,
                        source_name=source_name,
                        source_kind=source_kind,
                        source_reference_id=reference_id,
                        run=run_identity,
                        baseline=baseline,
                        build=build_identity,
                    )
                    break
                if processing_state in {"FAILED", "INVALID"}:
                    raise ValueError(
                        f"linked App Store Connect build processing state is {processing_state}"
                    )
                if processing_state != "PROCESSING":
                    raise ValueError(
                        "linked App Store Connect build has an unknown processing state"
                    )
            if time.time() > build_deadline:
                raise ValueError(
                    "Xcode Cloud run did not produce one valid App Store Connect build within 60 minutes"
                )
            time.sleep(30)

    final_resource = (
        terminal_response.get("data") if isinstance(terminal_response, dict) else run_resource
    )
    report = {
        "workflow": {
            "id": arguments.workflow_id,
            "name": arguments.expected_workflow_name,
        },
        "repository": {
            "id": repository_id,
            "http_clone_url": repository.get("attributes", {}).get("httpCloneUrl"),
        },
        "source": {
            "name": source_name,
            "kind": source_kind,
            "reference_id": reference_id,
            "expected_head": arguments.expected_head,
        },
        "run": final_resource,
        "receipt": receipt,
        "build_url": (
            f"https://appstoreconnect.apple.com/teams/{arguments.team_id}/apps/"
            f"{arguments.app_id}/ci/builds/{run_id}/summary"
        ),
    }
    return report


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow-id", required=True)
    parser.add_argument("--expected-workflow-name", required=True)
    parser.add_argument("--expected-repository", required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--branch")
    source.add_argument("--source-tag")
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--expected-bundle-id", required=True)
    parser.add_argument("--expected-marketing-version", required=True)
    parser.add_argument("--expected-platform", required=True, choices=("IOS",))
    parser.add_argument("--expected-min-os-version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--receipt-output", type=Path)
    parser.add_argument("--authorize-mutation", action="store_true")
    parser.add_argument("--wait", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        report = run(arguments)
        arguments.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        if arguments.receipt_output is not None:
            receipt = report.get("receipt")
            if not isinstance(receipt, dict):
                raise ValueError("a standalone receipt requires a completed linked build")
            arguments.receipt_output.write_text(
                json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        run_data = report.get("run") if isinstance(report.get("run"), dict) else {}
        attributes = run_data.get("attributes") if isinstance(run_data, dict) else {}
        status = attributes.get("completionStatus") if isinstance(attributes, dict) else None
        progress = attributes.get("executionProgress") if isinstance(attributes, dict) else None
        print(f"Xcode Cloud build run {run_data.get('id')} progress={progress} status={status}")
        receipt = report.get("receipt") if isinstance(report.get("receipt"), dict) else {}
        build = receipt.get("build") if isinstance(receipt, dict) else {}
        if isinstance(build, dict) and build:
            print(
                f"App Store Connect build {build.get('id')} number={build.get('number')}"
            )
        print(f"Build URL: {report['build_url']}")
        return 0
    except Exception as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
