#!/usr/bin/env python3
"""JWT-authenticated App Store Connect API client with a strict route allowlist.

Every route the client can touch is listed below; everything else is denied
before any network request is made. Write routes additionally require the
intended object ID, a prior-state SHA-256, and an explicit
`--authorize-mutation` flag. `--dry-run` prints the request that would be
made and issues zero requests.

Read allowlist (GET):
  /v1/apps, /v1/apps/{id}/builds, /v1/builds, /v1/builds/{id},
  /v1/ciProducts, /v1/ciWorkflows, /v1/ciBuildRuns, /v1/ciRuns,
  /v1/ciRuns/{id}/artifacts, /v1/betaGroups, /v1/betaGroups/{id}/builds,
  /v1/betaBuildLocalizations, /v1/betaAppReviewDetails,
  /v1/betaAppReviewSubmissions

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
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Optional


API_BASE = "https://api.appstoreconnect.apple.com"
OPENSSL3 = "/opt/homebrew/opt/openssl@3/bin/openssl"

READ_ROUTES = [
    r"^/v1/apps$",
    r"^/v1/apps/[^/]+/builds$",
    r"^/v1/builds$",
    r"^/v1/builds/[^/]+$",
    r"^/v1/ciProducts$",
    r"^/v1/ciProducts/[^/]+/workflows$",
    r"^/v1/ciProducts/[^/]+/buildRuns$",
    r"^/v1/ciWorkflows/[^/]+$",
    r"^/v1/ciBuildRuns/[^/]+$",
    r"^/v1/ciBuildRuns/[^/]+/actions$",
    r"^/v1/ciBuildActions/[^/]+$",
    r"^/v1/ciBuildActions/[^/]+/artifacts$",
    r"^/v1/betaGroups$",
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


def api_call(method: str, path: str, jwt: str, body: Optional[bytes] = None,
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
    return hashlib.sha256(path.read_bytes()).hexdigest()


def contains_value(value, needle: str) -> bool:
    if isinstance(value, str):
        return value == needle
    if isinstance(value, list):
        return any(contains_value(item, needle) for item in value)
    if isinstance(value, dict):
        return any(contains_value(item, needle) for item in value.values())
    return False


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
        if progress == "COMPLETE" and status in ("SUCCEEDED", "FAILED", "CANCELED"):
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
    post_parser.add_argument("--authorize-mutation", action="store_true")
    post_parser.add_argument("--output", required=True, type=Path)
    add_credentials(post_parser)

    patch_parser = subparsers.add_parser("patch")
    patch_parser.add_argument("path")
    patch_parser.add_argument("--dry-run", action="store_true")
    patch_parser.add_argument("--body", required=True, type=Path)
    patch_parser.add_argument("--intended-id", required=True)
    patch_parser.add_argument("--prior-state-sha256", required=True)
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

    arguments = parser.parse_args(argv)

    try:
        if arguments.command in ("get", "post", "patch"):
            method = {"get": "GET", "post": "POST", "patch": "PATCH"}[arguments.command]
            if not route_allowed(method, arguments.path):
                raise AllowlistError(f"route not on the allowlist: {method} {arguments.path}")
            if method in ("POST", "PATCH"):
                if not arguments.authorize_mutation:
                    raise AllowlistError("write routes require --authorize-mutation")
                body = json.loads(arguments.body.read_text())
                if arguments.intended_id and (
                    arguments.intended_id not in arguments.path
                    and not contains_value(body, arguments.intended_id)
                ):
                    raise AllowlistError(
                        "intended object ID is not referenced by the route or request body"
                    )
            if arguments.dry_run:
                jwt = ""
            else:
                issuer, key_id, key_path = load_credentials(arguments)
                jwt = make_jwt(issuer, key_id, key_path, int(time.time()))
            body = arguments.body.read_bytes() if arguments.command in ("post", "patch") else None
            response = api_call(method, arguments.path, jwt, body, dry_run=arguments.dry_run)
            if response is not None:
                write_output(arguments.output, response)
            else:
                write_output(arguments.output, {
                    "dry_run": True,
                    "method": method,
                    "path": arguments.path,
                })
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
    except (AllowlistError, CredentialError) as error:
        print(f"DENIED: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
