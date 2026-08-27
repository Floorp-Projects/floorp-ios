#!/usr/bin/env python3
"""Verify review-only source lineage for constrained curated packages.

This tool is intentionally for build/review machines only. It consumes a
locally supplied, digest-pinned upstream archive, never fetches a URL, and
never forms part of the iOS installation path. The first use binds the reduced
Very Good AdBlock DNR package to exact upstream static-rule seeds.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import tarfile
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG_ROOT = REPOSITORY_ROOT / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
HEX_DIGEST = re.compile(r"[0-9a-f]{64}")
UPSTREAM_RULE = re.compile(
    r"\{\s*id:\s*(?P<id>\d+),[^\n]*?urlFilter:\s*'(?P<url>[^']+)',"
    r"\s*resourceTypes:\s*blockedHostTypes\s*\}",
    re.MULTILINE,
)
PROVENANCE_KEYS = {
    "archiveRoot",
    "archiveSHA256",
    "archiveURL",
    "artifactRuleMappings",
    "licenseMember",
    "licenseMemberSHA256",
    "packageLicense",
    "packagePatch",
    "packageRules",
    "requiredResourceTypes",
    "schema",
    "sourceMember",
    "sourceMemberSHA256",
}
MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
# These limits apply before any archive member is materialized.  They keep the
# review-only verifier bounded even if a future, otherwise digest-pinned source
# archive is unexpectedly highly compressed.
MAX_ARCHIVE_MEMBERS = 1_024
MAX_ARCHIVE_EXPANDED_BYTES = 64 * 1024 * 1024
MAX_ARCHIVE_MEMBER_BYTES = 512 * 1024


class SourceProvenanceError(RuntimeError):
    """A review-source binding is absent, malformed, or does not match."""


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _require_string(value: Any, label: str, maximum: int = 512) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise SourceProvenanceError(f"{label} must be a bounded non-empty string")
    return value


def _require_digest(value: Any, label: str) -> str:
    value = _require_string(value, label, maximum=64)
    if not HEX_DIGEST.fullmatch(value):
        raise SourceProvenanceError(f"{label} must be a SHA-256 digest")
    return value


def _relative_file(catalog_root: Path, value: Any, label: str) -> Path:
    raw = _require_string(value, label)
    candidate = Path(raw)
    if candidate.is_absolute() or any(part in {"", ".", ".."} for part in candidate.parts):
        raise SourceProvenanceError(f"{label} must be a safe relative path")
    resolved_root = catalog_root.resolve()
    resolved = (resolved_root / candidate).resolve()
    try:
        resolved.relative_to(resolved_root)
    except ValueError as error:
        raise SourceProvenanceError(f"{label} escapes catalog root") from error
    if not resolved.is_file():
        raise SourceProvenanceError(f"{label} is missing: {raw}")
    return resolved


def _load_provenance(catalog_root: Path, source: dict[str, Any]) -> tuple[dict[str, Any], Path]:
    provenance_path = _relative_file(catalog_root, source.get("sourceProvenance"), "sourceProvenance")
    try:
        value = json.loads(provenance_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SourceProvenanceError(f"invalid sourceProvenance: {error}") from error
    if not isinstance(value, dict) or set(value) != PROVENANCE_KEYS:
        raise SourceProvenanceError("sourceProvenance has unexpected or missing fields")
    if value.get("schema") != 1:
        raise SourceProvenanceError("sourceProvenance has an unsupported schema")
    _require_string(value["archiveRoot"], "archiveRoot", maximum=128)
    archive_url = _require_string(value["archiveURL"], "archiveURL")
    if not archive_url.startswith("https://api.github.com/repos/"):
        raise SourceProvenanceError("archiveURL must be a fixed GitHub archive endpoint")
    for field in ("archiveSHA256", "licenseMemberSHA256", "sourceMemberSHA256"):
        _require_digest(value[field], field)
    for field in ("licenseMember", "sourceMember"):
        relative = Path(_require_string(value[field], field))
        if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
            raise SourceProvenanceError(f"{field} must be a safe archive-relative path")
    resource_types = value["requiredResourceTypes"]
    if resource_types != ["script", "image", "stylesheet", "xmlhttprequest"]:
        raise SourceProvenanceError("requiredResourceTypes must be the approved static DNR subset")
    mappings = value["artifactRuleMappings"]
    if not isinstance(mappings, list) or len(mappings) != 16:
        raise SourceProvenanceError("artifactRuleMappings must contain exactly sixteen entries")
    artifact_ids: set[int] = set()
    upstream_ids: set[int] = set()
    for mapping in mappings:
        if not isinstance(mapping, dict) or set(mapping) != {"artifactRuleID", "upstreamRuleID"}:
            raise SourceProvenanceError("artifactRuleMappings contain an invalid entry")
        artifact_id = mapping["artifactRuleID"]
        upstream_id = mapping["upstreamRuleID"]
        if not isinstance(artifact_id, int) or artifact_id < 1:
            raise SourceProvenanceError("artifact rule ID is invalid")
        if not isinstance(upstream_id, int) or upstream_id < 1:
            raise SourceProvenanceError("upstream rule ID is invalid")
        artifact_ids.add(artifact_id)
        upstream_ids.add(upstream_id)
    if artifact_ids != set(range(1, 17)) or len(upstream_ids) != 16:
        raise SourceProvenanceError("artifactRuleMappings are not one-to-one")
    if value["archiveSHA256"] != source.get("originalArtifactSHA256"):
        raise SourceProvenanceError("source archive digest is not bound to catalog source metadata")
    if source.get("package") != "Packages/thirdparty-very-good-adblock":
        raise SourceProvenanceError("Very Good AdBlock source package path changed unexpectedly")
    expected_archive_url = (
        "https://api.github.com/repos/chrisbbreuer/very-good-adblock/tarball/"
        f"{source.get('upstreamRevision', '')}"
    )
    if archive_url != expected_archive_url:
        raise SourceProvenanceError("archiveURL is not bound to the pinned upstream revision")
    return value, provenance_path


def _read_package_rules(catalog_root: Path, provenance: dict[str, Any]) -> list[dict[str, Any]]:
    rules_path = _relative_file(catalog_root, provenance["packageRules"], "packageRules")
    try:
        rules = json.loads(rules_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SourceProvenanceError(f"invalid packageRules: {error}") from error
    if not isinstance(rules, list) or len(rules) != 16 or not all(isinstance(rule, dict) for rule in rules):
        raise SourceProvenanceError("packageRules must be the fixed sixteen-rule DNR list")
    return rules


def _assert_patch_and_license(catalog_root: Path, provenance: dict[str, Any]) -> None:
    license_path = _relative_file(catalog_root, provenance["packageLicense"], "packageLicense")
    if sha256(license_path.read_bytes()) != provenance["licenseMemberSHA256"]:
        raise SourceProvenanceError("package LICENSE no longer matches the pinned upstream license")
    patch_path = _relative_file(catalog_root, provenance["packagePatch"], "packagePatch")
    patch_text = patch_path.read_text(encoding="utf-8")
    required_lines = (
        f"Source archive SHA-256: {provenance['archiveSHA256']}",
        f"Source member: {provenance['sourceMember']}",
        f"Source member SHA-256: {provenance['sourceMemberSHA256']}",
        "Selected upstream rule IDs: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 18, 19, 22, 23, 24, 27.",
    )
    if any(line not in patch_text for line in required_lines):
        raise SourceProvenanceError("PATCH.txt does not bind the reduced rules to the pinned source")


def validate_declared_provenance(catalog_root: Path, source: dict[str, Any]) -> dict[str, Any] | None:
    """Validate the local, review-only provenance declaration without network IO."""
    if source.get("sourceProvenance") is None:
        return None
    provenance, provenance_path = _load_provenance(catalog_root, source)
    _read_package_rules(catalog_root, provenance)
    _assert_patch_and_license(catalog_root, provenance)
    return {
        "path": provenance_path.relative_to(catalog_root.resolve()).as_posix(),
        "sha256": sha256(provenance_path.read_bytes()),
    }


def _read_archive_members(
    archive: Path,
    provenance: dict[str, Any],
    member_names: list[str],
) -> dict[str, bytes]:
    """Read exact, bounded regular files from one immutable archive snapshot.

    This deliberately uses tarfile's stream mode rather than building a full
    member index.  It bounds both the number of members and their declared
    expanded size before advancing through each payload, so the managed
    signing workstation cannot be made to process an unbounded tar stream.
    """
    if not archive.is_file():
        raise SourceProvenanceError("upstream archive is missing or exceeds the review size limit")
    try:
        with archive.open("rb") as stream:
            archive_bytes = stream.read(MAX_ARCHIVE_BYTES + 1)
    except OSError as error:
        raise SourceProvenanceError(f"cannot read upstream archive: {error}") from error
    if len(archive_bytes) > MAX_ARCHIVE_BYTES:
        raise SourceProvenanceError("upstream archive is missing or exceeds the review size limit")
    if sha256(archive_bytes) != provenance["archiveSHA256"]:
        raise SourceProvenanceError("upstream archive SHA-256 does not match the recorded source")
    expected = {
        f"{provenance['archiveRoot']}/{member_name}": member_name
        for member_name in member_names
    }
    if len(expected) != len(member_names):
        raise SourceProvenanceError("upstream archive member request contains duplicates")
    found: dict[str, bytes] = {}
    member_count = 0
    expanded_bytes = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r|*") as tar:
            for member in tar:
                member_count += 1
                if member_count > MAX_ARCHIVE_MEMBERS:
                    raise SourceProvenanceError("upstream archive exceeds the member limit")
                if member.size < 0 or member.size > MAX_ARCHIVE_EXPANDED_BYTES - expanded_bytes:
                    raise SourceProvenanceError("upstream archive exceeds the expanded size limit")
                expanded_bytes += member.size
                requested_name = expected.get(member.name)
                if requested_name is None:
                    continue
                if requested_name in found:
                    raise SourceProvenanceError(f"upstream archive member appears more than once: {requested_name}")
                if not member.isfile() or member.size > MAX_ARCHIVE_MEMBER_BYTES:
                    raise SourceProvenanceError(
                        f"upstream archive member is not a bounded regular file: {requested_name}"
                    )
                member_stream = tar.extractfile(member)
                if member_stream is None:
                    raise SourceProvenanceError(f"cannot read upstream archive member: {requested_name}")
                contents = member_stream.read(member.size + 1)
                if len(contents) != member.size:
                    raise SourceProvenanceError(f"cannot read complete upstream archive member: {requested_name}")
                found[requested_name] = contents
    except (OSError, tarfile.TarError) as error:
        raise SourceProvenanceError(f"cannot read upstream archive: {error}") from error
    missing = sorted(set(member_names) - set(found))
    if missing:
        raise SourceProvenanceError(f"upstream archive member is missing: {missing[0]}")
    return found


def _upstream_rule_filters(source_text: str) -> dict[int, str]:
    parsed = {int(match["id"]): match["url"] for match in UPSTREAM_RULE.finditer(source_text)}
    if len(parsed) < 16:
        raise SourceProvenanceError("pinned source does not contain enough block-only curated rule seeds")
    return parsed


def verify_archive(catalog_root: Path, source: dict[str, Any], archive: Path) -> dict[str, Any]:
    """Bind the local compatibility package to an independently supplied archive."""
    provenance, provenance_path = _load_provenance(catalog_root, source)
    archive_members = _read_archive_members(
        archive,
        provenance,
        [provenance["sourceMember"], provenance["licenseMember"]],
    )
    source_bytes = archive_members[provenance["sourceMember"]]
    if sha256(source_bytes) != provenance["sourceMemberSHA256"]:
        raise SourceProvenanceError("upstream static-rule source digest does not match")
    license_bytes = archive_members[provenance["licenseMember"]]
    if sha256(license_bytes) != provenance["licenseMemberSHA256"]:
        raise SourceProvenanceError("upstream LICENSE digest does not match")
    try:
        source_text = source_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SourceProvenanceError("upstream static-rule source is not UTF-8") from error
    upstream_filters = _upstream_rule_filters(source_text)
    rules = _read_package_rules(catalog_root, provenance)
    rule_by_id = {rule.get("id"): rule for rule in rules}
    for mapping in provenance["artifactRuleMappings"]:
        artifact_id = mapping["artifactRuleID"]
        upstream_id = mapping["upstreamRuleID"]
        if upstream_id not in upstream_filters:
            raise SourceProvenanceError(f"mapped upstream rule is absent: {upstream_id}")
        rule = rule_by_id.get(artifact_id)
        if not isinstance(rule, dict):
            raise SourceProvenanceError(f"mapped artifact rule is absent: {artifact_id}")
        if rule.get("priority") != 1 or rule.get("action") != {"type": "block"}:
            raise SourceProvenanceError(f"artifact rule is not a supported static block rule: {artifact_id}")
        condition = rule.get("condition")
        if not isinstance(condition, dict) or set(condition) != {"urlFilter", "resourceTypes"}:
            raise SourceProvenanceError(f"artifact rule has an unsupported condition: {artifact_id}")
        if condition.get("urlFilter") != upstream_filters[upstream_id]:
            raise SourceProvenanceError(f"artifact rule filter diverges from upstream rule: {artifact_id}")
        if condition.get("resourceTypes") != provenance["requiredResourceTypes"]:
            raise SourceProvenanceError(f"artifact rule resource types diverge from the reviewed subset: {artifact_id}")
    _assert_patch_and_license(catalog_root, provenance)
    return {
        "archiveSHA256": provenance["archiveSHA256"],
        "provenanceSHA256": sha256(provenance_path.read_bytes()),
        "ruleCount": len(rules),
        "status": "accepted",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog-root", type=Path, default=DEFAULT_CATALOG_ROOT)
    parser.add_argument("--source-id", default="thirdparty-very-good-adblock")
    parser.add_argument("--archive", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        sources = json.loads((arguments.catalog_root / "catalog-sources.json").read_text(encoding="utf-8"))
        source = next(item for item in sources if item.get("id") == arguments.source_id)
        result = verify_archive(arguments.catalog_root, source, arguments.archive)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, StopIteration, SourceProvenanceError) as error:
        print(f"source provenance rejected: {error}", file=__import__("sys").stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
