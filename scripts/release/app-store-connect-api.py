#!/usr/bin/env python3
"""JWT-authenticated App Store Connect API client with a strict route allowlist.

Every route the client can touch is listed below; everything else is denied
before any network request is made. Write routes additionally require the
intended object ID, a canonical prior-state SHA-256, its guarded GET route,
and an explicit
`--authorize-mutation` flag. `--dry-run` prints the request that would be
made and issues zero requests.

Read allowlist (GET):
  /v1/apps, /v1/apps/{id}, /v1/apps/{id}/builds, /v1/builds,
  /v1/builds/{id},
  /v1/preReleaseVersions/{id},
  /v1/ciProducts, /v1/ciProducts/{id}, /v1/ciWorkflows,
  /v1/ciBuildRuns, /v1/ciRuns,
  /v1/ciRuns/{id}/artifacts, /v1/betaGroups, /v1/betaGroups/{id},
  /v1/betaGroups/{id}/builds,
  /v1/betaBuildLocalizations, /v1/betaAppReviewDetails,
  /v1/betaAppReviewSubmissions, /v1/scmRepositories/{id},
  /v1/scmRepositories/{id}/gitReferences

Write allowlist (exact):
  POST /v1/ciBuildRuns
  POST /v1/betaBuildLocalizations
  PATCH /v1/betaBuildLocalizations/{id}
  PATCH /v1/betaAppReviewDetails/{id}
  POST /v1/betaAppReviewSubmissions
  POST /v1/betaGroups/{id}/relationships/builds

Group creation and every other write route are denied.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional


API_BASE = "https://api.appstoreconnect.apple.com"
_OPENSSL_CANDIDATES = (
    os.environ.get("FLOORP_OPENSSL3"),
    "/opt/homebrew/opt/openssl@3/bin/openssl",
    "/usr/local/opt/openssl@3/bin/openssl",
    shutil.which("openssl"),
)
OPENSSL3 = next(
    (candidate for candidate in _OPENSSL_CANDIDATES if candidate and Path(candidate).is_file()),
    "openssl",
)

READ_ROUTES = [
    r"^/v1/apps$",
    r"^/v1/apps/[^/]+$",
    r"^/v1/apps/[^/]+/builds$",
    r"^/v1/builds$",
    r"^/v1/builds/[^/]+$",
    r"^/v1/preReleaseVersions/[^/]+$",
    r"^/v1/ciProducts$",
    r"^/v1/ciProducts/[^/]+$",
    r"^/v1/ciProducts/[^/]+/workflows$",
    r"^/v1/ciProducts/[^/]+/buildRuns$",
    r"^/v1/ciWorkflows/[^/]+$",
    r"^/v1/ciBuildRuns/[^/]+$",
    r"^/v1/ciBuildRuns/[^/]+/relationships/builds$",
    r"^/v1/ciBuildRuns/[^/]+/actions$",
    r"^/v1/ciBuildActions/[^/]+$",
    r"^/v1/ciBuildActions/[^/]+/artifacts$",
    r"^/v1/scmRepositories/[^/]+$",
    r"^/v1/scmRepositories/[^/]+/gitReferences$",
    r"^/v1/betaGroups$",
    r"^/v1/betaGroups/[^/]+$",
    r"^/v1/betaGroups/[^/]+/builds$",
    r"^/v1/betaBuildLocalizations$",
    r"^/v1/betaAppReviewDetails$",
    r"^/v1/betaAppReviewSubmissions$",
]

WRITE_ROUTES = {
    ("POST", r"^/v1/ciBuildRuns$"),
    ("POST", r"^/v1/betaBuildLocalizations$"),
    ("PATCH", r"^/v1/betaBuildLocalizations/[^/]+$"),
    ("PATCH", r"^/v1/betaAppReviewDetails/[^/]+$"),
    ("POST", r"^/v1/betaAppReviewSubmissions$"),
    ("POST", r"^/v1/betaGroups/[^/]+/relationships/builds$"),
}


class AllowlistError(Exception):
    pass


class CredentialError(Exception):
    pass


def route_allowed(method: str, path: str) -> bool:
    path = path.split("?", 1)[0]
    if method == "GET":
        return any(re.fullmatch(pattern, path) for pattern in READ_ROUTES)
    if method in ("POST", "PATCH"):
        return any(method == allowed_method and re.fullmatch(pattern, path)
                   for allowed_method, pattern in WRITE_ROUTES)
    return False


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_to_raw_signature(der: bytes) -> bytes:
    """Converts a DER ECDSA signature to the raw r||s form used by JWT."""
    if der[0] != 0x30:
        raise CredentialError("unexpected DER signature prefix")
    index = 2
    # Skip the sequence length (long form supported for safety).
    if der[1] & 0x80:
        index = 2 + (der[1] & 0x7F)

    def read_integer(start):
        # Each INTEGER is encoded as 0x02 <len> <value>.
        if der[start] != 0x02:
            raise CredentialError("unexpected DER integer tag")
        start += 1
        length = der[start]
        start += 1
        if length & 0x80:
            length_bytes = length & 0x7F
            length = int.from_bytes(der[start:start + length_bytes], "big")
            start += length_bytes
        value = der[start:start + length]
        if len(value) > 1 and value[0] == 0:
            value = value[1:]
        return value, start + length

    r, index = read_integer(index)
    s, index = read_integer(index)
    if len(r) > 32 or len(s) > 32:
        raise CredentialError("signature integer exceeds 32 bytes")
    return r.rjust(32, b"\x00") + s.rjust(32, b"\x00")


def make_jwt(issuer_id: str, key_id: str, private_key_path: Path, now: int) -> str:
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 20 * 60,
        "aud": "appstoreconnect-v1",
    }
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    result = subprocess.run(
        [
            OPENSSL3, "pkeyutl", "-sign", "-rawin", "-digest", "sha256",
            "-inkey", str(private_key_path),
        ],
        input=signing_input.encode("ascii"),
        capture_output=True,
    )
    if result.returncode != 0:
        raise CredentialError(f"ES256 signing failed: {result.stderr.decode()}")
    raw = der_to_raw_signature(result.stdout)
    return signing_input + "." + b64url(raw)


def _http_request(method: str, url: str, headers: dict, body: bytes) -> dict:
    request = urllib.request.Request(url, method=method, headers=headers, data=body or None)
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read()
        if not raw:
            return {}
        return json.loads(raw)


def _api_call(method: str, path: str, jwt: str, body: Optional[bytes] = None,
              dry_run: bool = False) -> Optional[dict]:
    if not route_allowed(method, path):
        raise AllowlistError(f"route not on the allowlist: {method} {path}")
    if dry_run:
        print(f"DRY_RUN {method} {path}")
        return None
    headers = {
        "Authorization": f"Bearer {jwt}",
        "Content-Type": "application/json",
    }
    return _http_request(method, f"{API_BASE}{path}", headers, body)


def api_call(method: str, path: str, jwt: str, body: Optional[bytes] = None,
             dry_run: bool = False) -> Optional[dict]:
    """Perform an allowlisted read.

    Writes deliberately have a separate entry point so an importing caller
    cannot bypass the object binding and compare-and-swap precondition.
    """
    if method != "GET":
        raise AllowlistError("write routes require guarded_write")
    return _api_call(method, path, jwt, body, dry_run=dry_run)


def load_credentials(arguments) -> tuple[str, str, Path]:
    issuer = arguments.issuer_id or os.environ.get("APP_STORE_CONNECT_ISSUER_ID", "")
    key_id = arguments.key_id or os.environ.get("APP_STORE_CONNECT_KEY_ID", "")
    key_path = arguments.private_key or os.environ.get("APP_STORE_CONNECT_PRIVATE_KEY_PATH", "")
    if arguments.private_key is None and os.environ.get("APP_STORE_CONNECT_PRIVATE_KEY"):
        raise CredentialError("APP_STORE_CONNECT_PRIVATE_KEY content is not supported; use a path")
    if not issuer or not key_id or not key_path:
        raise CredentialError(
            "missing App Store Connect credentials (issuer id, key id, private key path)"
        )
    path = Path(key_path)
    if not path.is_file():
        raise CredentialError(f"private key not found: {key_path}")
    return issuer, key_id, path


def prior_state_sha256(path: Path) -> str:
    return canonical_state_sha256(json.loads(path.read_text(encoding="utf-8")))


def canonical_state_sha256(response: dict) -> str:
    """Fingerprint JSON:API state without transport-only metadata.

    Collection ordering and JSON formatting are not state. Nested array order is
    preserved, while top-level and included resource collections are sorted
    canonically, so repeated GETs with a different server order compare equal.
    Included resources are covered when present so an expanded workflow guard
    also detects repository or product changes.
    """
    if not isinstance(response, dict) or "data" not in response:
        raise AllowlistError("guard response must contain JSON:API data")
    links = response.get("links")
    if links is not None and not isinstance(links, dict):
        raise AllowlistError("guard response pagination metadata is malformed")
    if isinstance(links, dict) and links.get("next") not in (None, ""):
        raise AllowlistError("guard response is paginated; refusing partial-state hash")
    data = response["data"]
    if isinstance(data, list):
        if not all(isinstance(item, dict) for item in data):
            raise AllowlistError("guard response collection must contain resource objects")
        data = sorted(
            data,
            key=lambda item: json.dumps(
                item, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            ),
        )
    elif data is not None and not isinstance(data, dict):
        raise AllowlistError("guard response data must be an object, array, or null")
    state = data
    if "included" in response:
        included = response["included"]
        if not (
            isinstance(included, list)
            and all(isinstance(item, dict) for item in included)
        ):
            raise AllowlistError("guard response included resources must be an array")
        state = {
            "data": data,
            "included": sorted(
                included,
                key=lambda item: json.dumps(
                    item, ensure_ascii=False, separators=(",", ":"), sort_keys=True
                ),
            ),
        }
    encoded = json.dumps(
        state, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def guard_route_allowed(method: str, write_path: str, guard_path: str,
                        intended_id: str) -> bool:
    """Bind each write family to the collection/resource whose state it changes."""
    if not route_allowed("GET", guard_path):
        return False
    write_resource = write_path.split("?", 1)[0]
    parsed_guard = urllib.parse.urlsplit(guard_path)
    guard_resource = parsed_guard.path
    query = urllib.parse.parse_qs(parsed_guard.query, keep_blank_values=True)

    if method == "POST" and write_resource == "/v1/ciBuildRuns":
        include = query.get("include")
        return (
            guard_resource == f"/v1/ciWorkflows/{intended_id}"
            and set(query) == {"include"}
            and isinstance(include, list)
            and len(include) == 1
            and set(include[0].split(",")) == {"product", "repository"}
        )
    if write_resource == "/v1/betaBuildLocalizations" or (
        method == "PATCH"
        and re.fullmatch(r"/v1/betaBuildLocalizations/[^/]+", write_resource)
    ):
        build_filter = query.get("filter[build]")
        return (
            guard_resource == "/v1/betaBuildLocalizations"
            and set(query) == {"filter[build]", "limit"}
            and query.get("limit") == ["200"]
            and isinstance(build_filter, list)
            and len(build_filter) == 1
            and bool(build_filter[0])
            and (method != "POST" or build_filter == [intended_id])
        )
    if method == "PATCH" and re.fullmatch(
        r"/v1/betaAppReviewDetails/[^/]+", write_resource
    ):
        return (
            guard_resource == "/v1/betaAppReviewDetails"
            and set(query) == {"filter[app]", "limit"}
            and query.get("limit") == ["200"]
            and len(query.get("filter[app]", [])) == 1
            and bool(query["filter[app]"][0])
        )
    if method == "POST" and write_resource == "/v1/betaAppReviewSubmissions":
        return (
            guard_resource == "/v1/betaAppReviewSubmissions"
            and query.get("filter[build]") == [intended_id]
            and query.get("limit") == ["200"]
            and set(query) == {"filter[build]", "limit"}
        )
    group_match = re.fullmatch(
        r"/v1/betaGroups/([^/]+)/relationships/builds", write_resource
    )
    if method == "POST" and group_match:
        return (
            guard_resource == f"/v1/betaGroups/{group_match.group(1)}/builds"
            and query == {"limit": ["200"]}
        )
    return False


def guard_response_matches_write(method: str, write_path: str, response: dict,
                                 intended_id: str) -> bool:
    """Ensure a PATCH guard snapshot actually contains its target resource."""
    if method != "PATCH":
        return True
    resource = write_path.split("?", 1)[0]
    if not (
        re.fullmatch(r"/v1/betaBuildLocalizations/[^/]+", resource)
        or re.fullmatch(r"/v1/betaAppReviewDetails/[^/]+", resource)
    ):
        return True
    data = response.get("data") if isinstance(response, dict) else None
    return (
        isinstance(data, list)
        and sum(
            1
            for item in data
            if isinstance(item, dict) and item.get("id") == intended_id
        ) == 1
    )


def _require_exact_keys(value: dict, expected: set[str], context: str) -> None:
    if set(value) != expected:
        raise AllowlistError(
            f"{context} must contain exactly {sorted(expected)}"
        )


def _require_linkage(value, resource_type: str, resource_id: str,
                     context: str) -> None:
    if value != {"data": {"type": resource_type, "id": resource_id}}:
        raise AllowlistError(
            f"{context} must target exactly {resource_type} {resource_id}"
        )


def validate_write_body(method: str, path: str, body: dict,
                        intended_id: str) -> None:
    """Require each write body to name exactly its guarded target resource."""
    if not intended_id:
        raise AllowlistError("intended object ID must not be empty")
    if not isinstance(body, dict):
        raise AllowlistError("write body must be a JSON object")
    _require_exact_keys(body, {"data"}, "write body")
    resource = path.split("?", 1)[0]

    if method == "POST" and resource == "/v1/ciBuildRuns":
        data = body["data"]
        if not isinstance(data, dict):
            raise AllowlistError("ciBuildRuns data must be an object")
        _require_exact_keys(
            data, {"type", "attributes", "relationships"}, "ciBuildRuns data"
        )
        if data["type"] != "ciBuildRuns" or data["attributes"] != {}:
            raise AllowlistError("ciBuildRuns data type or attributes are invalid")
        relationships = data["relationships"]
        if not isinstance(relationships, dict):
            raise AllowlistError("ciBuildRuns relationships must be an object")
        _require_exact_keys(
            relationships, {"workflow", "sourceBranchOrTag"},
            "ciBuildRuns relationships",
        )
        _require_linkage(
            relationships["workflow"], "ciWorkflows", intended_id,
            "ciBuildRuns workflow relationship",
        )
        source = relationships["sourceBranchOrTag"]
        source_data = source.get("data") if isinstance(source, dict) else None
        if not (
            isinstance(source, dict)
            and set(source) == {"data"}
            and isinstance(source_data, dict)
            and set(source_data) == {"type", "id"}
            and source_data.get("type") == "scmGitReferences"
            and isinstance(source_data.get("id"), str)
            and bool(source_data["id"])
        ):
            raise AllowlistError(
                "ciBuildRuns sourceBranchOrTag must target exactly one Git reference"
            )
        return

    if method == "POST" and resource == "/v1/betaBuildLocalizations":
        data = body["data"]
        if not isinstance(data, dict):
            raise AllowlistError("betaBuildLocalizations data must be an object")
        _require_exact_keys(
            data, {"type", "attributes", "relationships"},
            "betaBuildLocalizations data",
        )
        attributes = data["attributes"]
        if data["type"] != "betaBuildLocalizations" or not isinstance(attributes, dict):
            raise AllowlistError("betaBuildLocalizations data type or attributes are invalid")
        _require_exact_keys(
            attributes, {"locale", "whatsNew"},
            "betaBuildLocalizations attributes",
        )
        if not (
            isinstance(attributes["locale"], str) and attributes["locale"]
            and isinstance(attributes["whatsNew"], str)
        ):
            raise AllowlistError("betaBuildLocalizations attributes are invalid")
        relationships = data["relationships"]
        if not isinstance(relationships, dict):
            raise AllowlistError("betaBuildLocalizations relationships must be an object")
        _require_exact_keys(
            relationships, {"build"}, "betaBuildLocalizations relationships"
        )
        _require_linkage(
            relationships["build"], "builds", intended_id,
            "betaBuildLocalizations build relationship",
        )
        return

    localization_match = re.fullmatch(
        r"/v1/betaBuildLocalizations/([^/]+)", resource
    )
    if method == "PATCH" and localization_match:
        data = body["data"]
        if not isinstance(data, dict):
            raise AllowlistError("betaBuildLocalizations data must be an object")
        _require_exact_keys(
            data, {"type", "id", "attributes"}, "betaBuildLocalizations data"
        )
        if not (
            localization_match.group(1) == intended_id
            and data["type"] == "betaBuildLocalizations"
            and data["id"] == intended_id
            and isinstance(data["attributes"], dict)
        ):
            raise AllowlistError(
                "betaBuildLocalizations path, body, and intended ID must match"
            )
        _require_exact_keys(
            data["attributes"], {"whatsNew"},
            "betaBuildLocalizations patch attributes",
        )
        if not isinstance(data["attributes"]["whatsNew"], str):
            raise AllowlistError("betaBuildLocalizations whatsNew must be a string")
        return

    review_match = re.fullmatch(r"/v1/betaAppReviewDetails/([^/]+)", resource)
    if method == "PATCH" and review_match:
        data = body["data"]
        if not isinstance(data, dict):
            raise AllowlistError("betaAppReviewDetails data must be an object")
        _require_exact_keys(
            data, {"type", "id", "attributes"}, "betaAppReviewDetails data"
        )
        if not (
            review_match.group(1) == intended_id
            and data["type"] == "betaAppReviewDetails"
            and data["id"] == intended_id
            and isinstance(data["attributes"], dict)
        ):
            raise AllowlistError(
                "betaAppReviewDetails path, body, and intended ID must match"
            )
        _require_exact_keys(
            data["attributes"], {"notes"}, "betaAppReviewDetails patch attributes"
        )
        if not (
            isinstance(data["attributes"]["notes"], str)
            and data["attributes"]["notes"].strip()
        ):
            raise AllowlistError("betaAppReviewDetails notes must be non-empty")
        return

    if method == "POST" and resource == "/v1/betaAppReviewSubmissions":
        data = body["data"]
        if not isinstance(data, dict):
            raise AllowlistError("betaAppReviewSubmissions data must be an object")
        _require_exact_keys(
            data, {"type", "relationships"}, "betaAppReviewSubmissions data"
        )
        if data["type"] != "betaAppReviewSubmissions":
            raise AllowlistError("betaAppReviewSubmissions data type is invalid")
        relationships = data["relationships"]
        if not isinstance(relationships, dict):
            raise AllowlistError("betaAppReviewSubmissions relationships must be an object")
        _require_exact_keys(
            relationships, {"build"}, "betaAppReviewSubmissions relationships"
        )
        _require_linkage(
            relationships["build"], "builds", intended_id,
            "betaAppReviewSubmissions build relationship",
        )
        return

    group_match = re.fullmatch(
        r"/v1/betaGroups/([^/]+)/relationships/builds", resource
    )
    if method == "POST" and group_match:
        data = body["data"]
        if not (
            isinstance(data, list)
            and len(data) == 1
            and data[0] == {"type": "builds", "id": intended_id}
        ):
            raise AllowlistError(
                "beta group relationship must contain exactly the intended build"
            )
        return

    raise AllowlistError("write body validator is missing for allowlisted route")


def guarded_write(method: str, path: str, jwt: str, body: bytes,
                  intended_id: str, expected_state_sha256: str,
                  guard_get: str, dry_run: bool = False) -> Optional[dict]:
    if method not in {"POST", "PATCH"} or not route_allowed(method, path):
        raise AllowlistError(f"route not on the write allowlist: {method} {path}")
    if re.fullmatch(r"[0-9a-f]{64}", expected_state_sha256) is None:
        raise AllowlistError("prior-state SHA-256 must be 64 lowercase hex characters")
    if not guard_route_allowed(method, path, guard_get, intended_id):
        raise AllowlistError("guard GET route does not match the intended write")
    decoded = json.loads(body)
    validate_write_body(method, path, decoded, intended_id)
    if dry_run:
        return _api_call(method, path, "", body, dry_run=True)
    current = api_call("GET", guard_get, jwt)
    if not guard_response_matches_write(method, path, current, intended_id):
        raise AllowlistError(
            "guarded App Store Connect state does not uniquely contain the write target"
        )
    current_sha256 = canonical_state_sha256(current)
    if not hmac.compare_digest(current_sha256, expected_state_sha256):
        raise AllowlistError(
            "guarded App Store Connect state changed; refusing stale write"
        )
    return _api_call(method, path, jwt, body)


def write_output(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def wait_ci_run(client, run_id: str, expected_head: str, output: Path,
                dry_run: bool) -> None:
    path = f"/v1/ciBuildRuns/{run_id}"
    deadline = time.time() + 180 * 60
    while True:
        response = client("GET", path, dry_run=dry_run)
        if dry_run:
            write_output(output, {"dry_run": True, "run_id": run_id})
            return
        attributes = response.get("data", {}).get("attributes", {})
        progress = attributes.get("executionProgress")
        status = attributes.get("completionStatus")
        if progress == "COMPLETE" and status in (
            "SUCCEEDED",
            "FAILED",
            "ERRORED",
            "CANCELED",
            "SKIPPED",
        ):
            source_commit = attributes.get("sourceCommit") or {}
            commit_sha = source_commit.get("commitSha") if isinstance(source_commit, dict) else None
            if expected_head and commit_sha != expected_head:
                raise AllowlistError(
                    f"CI run head {commit_sha} != expected {expected_head}"
                )
            write_output(output, response)
            if status != "SUCCEEDED":
                raise AllowlistError(f"CI run finished with status {status}")
            return
        if time.time() > deadline:
            raise AllowlistError(f"CI run {run_id} did not finish within 180 minutes")
        time.sleep(30)


def build_polling_client(issuer_id: str, key_id: str, private_key_path: Path,
                         dry_run: bool):
    """Returns an API client that mints a fresh JWT on every request.

    wait-ci-run polls can run up to 180 minutes while JWTs expire after 20,
    so the token must be refreshed per request rather than minted once.
    """

    def client(method: str, path: str, dry_run: bool = dry_run):
        if dry_run:
            jwt = ""
        else:
            jwt = make_jwt(issuer_id, key_id, private_key_path, int(time.time()))
        return api_call(method, path, jwt, dry_run=dry_run)

    return client


def download_ci_artifact(client, run_id: str, relationship: str, output: Path,
                         sha256_output: Path, dry_run: bool) -> None:
    actions_response = client("GET", f"/v1/ciBuildRuns/{run_id}/actions", dry_run=dry_run)
    if dry_run:
        write_output(sha256_output, {"dry_run": True})
        return
    actions = actions_response.get("data", [])
    if not actions:
        raise AllowlistError(f"no ciBuildActions on run {run_id}")
    action_id = actions[0].get("id")
    response = client("GET", f"/v1/ciBuildActions/{action_id}/artifacts", dry_run=dry_run)
    artifacts = response.get("data", [])
    wanted = relationship.rstrip("s").lower()
    match = next(
        (item for item in artifacts
         if (item.get("attributes", {}).get("fileType") or "").lower().rstrip("s") == wanted),
        None,
    )
    if match is None:
        raise AllowlistError(
            f"no artifact with fileType {relationship} on run {run_id} "
            f"(found {[a.get('attributes', {}).get('fileType') for a in artifacts]})"
        )
    download_url = match.get("attributes", {}).get("downloadUrl")
    if not download_url:
        raise AllowlistError("artifact has no downloadUrl")
    request = urllib.request.Request(download_url, method="GET")
    with urllib.request.urlopen(request, timeout=300) as response_handle:
        data = response_handle.read()
    output.write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    sha256_output.write_text(digest + "\n")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_credentials(subparser) -> None:
        subparser.add_argument("--issuer-id", default=None)
        subparser.add_argument("--key-id", default=None)
        subparser.add_argument("--private-key", default=None)

    get_parser = subparsers.add_parser("get")
    get_parser.add_argument("path")
    get_parser.add_argument("--dry-run", action="store_true")
    get_parser.add_argument("--output", required=True, type=Path)
    add_credentials(get_parser)

    post_parser = subparsers.add_parser("post")
    post_parser.add_argument("path")
    post_parser.add_argument("--dry-run", action="store_true")
    post_parser.add_argument("--body", required=True, type=Path)
    post_parser.add_argument("--intended-id", required=True)
    post_parser.add_argument("--prior-state-sha256", required=True)
    post_parser.add_argument("--guard-get", required=True)
    post_parser.add_argument("--authorize-mutation", action="store_true")
    post_parser.add_argument("--output", required=True, type=Path)
    add_credentials(post_parser)

    patch_parser = subparsers.add_parser("patch")
    patch_parser.add_argument("path")
    patch_parser.add_argument("--dry-run", action="store_true")
    patch_parser.add_argument("--body", required=True, type=Path)
    patch_parser.add_argument("--intended-id", required=True)
    patch_parser.add_argument("--prior-state-sha256", required=True)
    patch_parser.add_argument("--guard-get", required=True)
    patch_parser.add_argument("--authorize-mutation", action="store_true")
    patch_parser.add_argument("--output", required=True, type=Path)
    add_credentials(patch_parser)

    wait_parser = subparsers.add_parser("wait-ci-run")
    wait_parser.add_argument("--dry-run", action="store_true")
    wait_parser.add_argument("--run-id", required=True)
    wait_parser.add_argument("--expected-head", required=True)
    wait_parser.add_argument("--output", required=True, type=Path)
    add_credentials(wait_parser)

    download_parser = subparsers.add_parser("download-ci-artifact")
    download_parser.add_argument("--dry-run", action="store_true")
    download_parser.add_argument("--run-id", required=True)
    download_parser.add_argument("--relationship", required=True)
    download_parser.add_argument("--output", required=True, type=Path)
    download_parser.add_argument("--sha256-output", required=True, type=Path)
    add_credentials(download_parser)

    fingerprint_parser = subparsers.add_parser("fingerprint-state")
    fingerprint_parser.add_argument("--input", required=True, type=Path)

    arguments = parser.parse_args(argv)

    try:
        if arguments.command in ("get", "post", "patch"):
            method = {"get": "GET", "post": "POST", "patch": "PATCH"}[arguments.command]
            if not route_allowed(method, arguments.path):
                raise AllowlistError(f"route not on the allowlist: {method} {arguments.path}")
            if method in ("POST", "PATCH"):
                if not arguments.authorize_mutation:
                    raise AllowlistError("write routes require --authorize-mutation")
            if arguments.dry_run:
                jwt = ""
            else:
                issuer, key_id, key_path = load_credentials(arguments)
                jwt = make_jwt(issuer, key_id, key_path, int(time.time()))
            body = arguments.body.read_bytes() if arguments.command in ("post", "patch") else None
            if method == "GET":
                response = api_call(
                    method, arguments.path, jwt, dry_run=arguments.dry_run
                )
            else:
                response = guarded_write(
                    method,
                    arguments.path,
                    jwt,
                    body,
                    arguments.intended_id,
                    arguments.prior_state_sha256,
                    arguments.guard_get,
                    dry_run=arguments.dry_run,
                )
            if response is not None:
                write_output(arguments.output, response)
            else:
                write_output(arguments.output, {
                    "dry_run": True,
                    "method": method,
                    "path": arguments.path,
                    "precondition_status": (
                        "not_checked_dry_run" if method in ("POST", "PATCH") else "not_applicable"
                    ),
                })
            return 0
        if arguments.command == "fingerprint-state":
            print(prior_state_sha256(arguments.input))
            return 0
        if arguments.command == "wait-ci-run":
            if arguments.dry_run:
                client = build_polling_client("", "", Path("."), dry_run=True)
            else:
                issuer, key_id, key_path = load_credentials(arguments)
                client = build_polling_client(
                    issuer, key_id, key_path, dry_run=arguments.dry_run
                )
            wait_ci_run(client, arguments.run_id, arguments.expected_head,
                        arguments.output, arguments.dry_run)
            return 0
        if arguments.command == "download-ci-artifact":
            issuer, key_id, key_path = load_credentials(arguments)
            jwt = make_jwt(issuer, key_id, key_path, int(time.time()))
            download_ci_artifact(
                lambda method, path, dry_run=arguments.dry_run: api_call(
                    method, path, jwt, dry_run=dry_run
                ),
                arguments.run_id,
                arguments.relationship,
                arguments.output,
                arguments.sha256_output,
                arguments.dry_run,
            )
            return 0
    except (AllowlistError, CredentialError, json.JSONDecodeError, ValueError) as error:
        print(f"DENIED: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
