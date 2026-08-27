#!/usr/bin/env python3
"""Build reviewed Floorp WebExtensions into immutable FWEA1 artifacts.

This is a repository-side review build step. It accepts only the catalog
source manifest committed with the package sources, invokes the untrusted
ingestion boundary for every package, and emits a deterministic unsigned
catalog input. Signing is deliberately a separate operation performed with
the managed root/leaf keys; this script never handles a private key.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ingest_extension import IngestionError, canonical_json, ingest, sha256, strict_json_loads
from verify_curated_source_provenance import SourceProvenanceError, validate_declared_provenance


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG_ROOT = REPOSITORY_ROOT / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
SOURCE_REQUIRED_KEYS = {
    "id",
    "extensionID",
    "category",
    "displayName",
    "description",
    "license",
    "modificationStatus",
    "package",
    "privateProfileCapability",
    "sourceURL",
    "upstream",
    "upstreamRevision",
}
SOURCE_OPTIONAL_KEYS = {
    "originalArtifactSHA256",
    "sourceProvenance",
}
SOURCE_KEYS = SOURCE_REQUIRED_KEYS | SOURCE_OPTIONAL_KEYS
DISCLOSURE_ROOT_KEYS = {"schema", "packages"}
DISCLOSURE_KEYS = {
    "publisherDisplayName",
    "attribution",
    "privacySummary",
    "retentionPolicy",
    "reviewedAt",
    "supportRoute",
    "reportRoute",
}
DISCLOSURE_SUPPORT_ROUTES = {"floorp-github-issues"}
DISCLOSURE_REPORT_ROUTES = {"floorp-github-bug-report"}


class CuratedCatalogBuildError(RuntimeError):
    """A review manifest or generated artifact is invalid."""


def file_digest(path: Path) -> str:
    try:
        return sha256(path.read_bytes())
    except OSError as error:
        raise CuratedCatalogBuildError(f"cannot read {path}: {error}") from error


def require_string(value: Any, *, field: str, maximum_length: int = 512) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum_length:
        raise CuratedCatalogBuildError(f"{field} must be a bounded non-empty string")
    return value


def source_entries(path: Path) -> list[dict[str, Any]]:
    raw = strict_json_loads(path.read_bytes(), label="curated catalog sources")
    if not isinstance(raw, list) or len(raw) < 12 or len(raw) > 128:
        raise CuratedCatalogBuildError("curated catalog needs 12–128 source entries")
    result: list[dict[str, Any]] = []
    identifiers: set[str] = set()
    extension_ids: set[str] = set()
    for index, value in enumerate(raw):
        if not isinstance(value, dict):
            raise CuratedCatalogBuildError(f"source entry {index} must be an object")
        unknown = set(value) - SOURCE_KEYS
        missing = SOURCE_REQUIRED_KEYS - set(value)
        if unknown or missing:
            raise CuratedCatalogBuildError(
                f"source entry {index} has unexpected/missing fields: {sorted(unknown | missing)}"
            )
        identifier = require_string(value["id"], field=f"source entry {index}.id", maximum_length=47)
        extension_id = require_string(value["extensionID"], field=f"source entry {index}.extensionID", maximum_length=128)
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{2,127}", extension_id):
            raise CuratedCatalogBuildError(f"source entry {identifier} has invalid extensionID")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,46}", identifier):
            raise CuratedCatalogBuildError(f"source entry {identifier} has invalid id")
        if identifier in identifiers or extension_id in extension_ids:
            raise CuratedCatalogBuildError("curated catalog has duplicate source or extension IDs")
        identifiers.add(identifier)
        extension_ids.add(extension_id)
        if value["modificationStatus"] not in {"floorp-managed", "compatibility-patched"}:
            raise CuratedCatalogBuildError(f"source entry {identifier} has invalid modification status")
        if value["modificationStatus"] == "floorp-managed" and not re.fullmatch(
            r"[0-9a-f]{40}",
            value["upstreamRevision"],
        ):
            raise CuratedCatalogBuildError(
                f"floorp-managed source entry {identifier} must bind an immutable Git revision"
            )
        if value["privateProfileCapability"] not in {"not-supported", "opt-in", "supported"}:
            raise CuratedCatalogBuildError(f"source entry {identifier} has invalid private capability")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", value["category"]):
            raise CuratedCatalogBuildError(f"source entry {identifier} has invalid category")
        if not re.fullmatch(r"[A-Za-z0-9.+-]{1,128}", value["license"]):
            raise CuratedCatalogBuildError(f"source entry {identifier} has invalid license")
        for key in ("sourceURL",):
            if not re.fullmatch(r"https://[^\s?#]+(?:[?#][^\s]*)?", value[key]):
                raise CuratedCatalogBuildError(f"source entry {identifier} has invalid {key}")
        original = value.get("originalArtifactSHA256")
        if original is not None and (not isinstance(original, str) or not re.fullmatch(r"[0-9a-f]{64}", original)):
            raise CuratedCatalogBuildError(f"source entry {identifier} has invalid original artifact digest")
        source_provenance = value.get("sourceProvenance")
        if source_provenance is not None:
            if not isinstance(source_provenance, str) or not source_provenance.strip():
                raise CuratedCatalogBuildError(f"source entry {identifier} has invalid sourceProvenance")
        elif value["modificationStatus"] == "compatibility-patched":
            raise CuratedCatalogBuildError(
                f"compatibility-patched source entry {identifier} requires sourceProvenance"
            )
        result.append(value)
    return sorted(result, key=lambda item: (item["extensionID"], item["id"]))


def _strict_timestamp(value: Any, *, field: str) -> str:
    timestamp = require_string(value, field=field, maximum_length=20)
    try:
        datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise CuratedCatalogBuildError(f"{field} must use RFC3339 UTC seconds") from error
    return timestamp


def disclosure_entries(path: Path, sources: list[dict[str, Any]]) -> dict[str, dict[str, str]]:
    """Load signed, display-only disclosures for the exact curated source set.

    The review evidence digest is generated only after immutable artifact
    creation.  This input therefore contains only human-readable fields that
    Product/Privacy can review without depending on a mutable UI map.
    """
    try:
        raw = strict_json_loads(path.read_bytes(), label="curated catalog disclosures")
    except (OSError, ValueError) as error:
        raise CuratedCatalogBuildError(f"cannot read curated catalog disclosures: {error}") from error
    if not isinstance(raw, dict) or set(raw) != DISCLOSURE_ROOT_KEYS or raw.get("schema") != 1:
        raise CuratedCatalogBuildError("curated catalog disclosures have an unsupported schema")
    packages = raw["packages"]
    if not isinstance(packages, dict):
        raise CuratedCatalogBuildError("curated catalog disclosure packages must be an object")
    source_ids = {source["id"] for source in sources}
    if set(packages) != source_ids:
        raise CuratedCatalogBuildError("curated catalog disclosures do not exactly match source IDs")
    result: dict[str, dict[str, str]] = {}
    for source_id, value in packages.items():
        if not isinstance(value, dict) or set(value) != DISCLOSURE_KEYS:
            raise CuratedCatalogBuildError(f"curated catalog disclosure {source_id} has unexpected fields")
        disclosure = {
            "publisherDisplayName": require_string(
                value["publisherDisplayName"],
                field=f"curated catalog disclosure {source_id}.publisherDisplayName",
                maximum_length=256,
            ),
            "attribution": require_string(
                value["attribution"],
                field=f"curated catalog disclosure {source_id}.attribution",
                maximum_length=512,
            ),
            "privacySummary": require_string(
                value["privacySummary"],
                field=f"curated catalog disclosure {source_id}.privacySummary",
                maximum_length=1_024,
            ),
            "retentionPolicy": require_string(
                value["retentionPolicy"],
                field=f"curated catalog disclosure {source_id}.retentionPolicy",
                maximum_length=1_024,
            ),
            "reviewedAt": _strict_timestamp(
                value["reviewedAt"],
                field=f"curated catalog disclosure {source_id}.reviewedAt",
            ),
            "supportRoute": require_string(
                value["supportRoute"],
                field=f"curated catalog disclosure {source_id}.supportRoute",
                maximum_length=64,
            ),
            "reportRoute": require_string(
                value["reportRoute"],
                field=f"curated catalog disclosure {source_id}.reportRoute",
                maximum_length=64,
            ),
        }
        if disclosure["supportRoute"] not in DISCLOSURE_SUPPORT_ROUTES:
            raise CuratedCatalogBuildError(f"curated catalog disclosure {source_id} has invalid support route")
        if disclosure["reportRoute"] not in DISCLOSURE_REPORT_ROUTES:
            raise CuratedCatalogBuildError(f"curated catalog disclosure {source_id} has invalid report route")
        result[source_id] = disclosure
    return result


def source_review_digest(source: dict[str, Any], provenance: dict[str, str] | None) -> str:
    """Return a stable review-lineage fingerprint, never used for execution."""
    if provenance is not None:
        return provenance["sha256"]
    return sha256(canonical_json({
        "license": source["license"],
        "package": source["package"],
        "sourceURL": source["sourceURL"],
        "upstreamRevision": source["upstreamRevision"],
    }))


def notices_digest(package: Path, *, modification_status: str) -> str:
    names = ["LICENSE", "NOTICE"]
    if modification_status == "compatibility-patched":
        names.append("PATCH.txt")
    chunks: list[bytes] = []
    for name in names:
        path = package / name
        if not path.is_file():
            raise CuratedCatalogBuildError(f"{package.name} must contain {name}")
        chunks.extend((name.encode("ascii"), b"\0", path.read_bytes(), b"\0"))
    return sha256(b"".join(chunks))


def compatibility_profiles(manifest: dict[str, Any]) -> list[str]:
    profiles: list[str] = []
    if manifest.get("content_scripts"):
        profiles.append("content-script")
    if manifest.get("declarative_net_request"):
        profiles.append("dnr")
    if any(manifest.get(key) for key in ("action", "options_ui", "background")) or any(
        permission in {"alarms", "storage"} for permission in manifest.get("permissions", [])
    ):
        profiles.append("action-storage")
    if not profiles:
        raise CuratedCatalogBuildError("package has no supported compatibility profile")
    return profiles


def metadata_permissions(manifest: dict[str, Any]) -> list[str]:
    return sorted(set(manifest.get("permissions", [])) | set(manifest.get("optional_permissions", [])))


def metadata_hosts(manifest: dict[str, Any]) -> list[str]:
    return sorted(set(manifest.get("host_permissions", [])) | set(manifest.get("optional_host_permissions", [])))


def build(*, sources_path: Path, output_directory: Path, generation_prefix: str) -> list[dict[str, Any]]:
    sources = source_entries(sources_path)
    disclosures = disclosure_entries(sources_path.parent / "catalog-disclosures.json", sources)
    resolved_output = output_directory.resolve()
    unsafe_outputs = {Path("/").resolve(), REPOSITORY_ROOT.resolve(), Path.home().resolve()}
    if resolved_output in unsafe_outputs:
        raise CuratedCatalogBuildError("output directory must be a dedicated catalog directory")
    output_directory.mkdir(parents=True, exist_ok=True)
    artifacts_directory = output_directory / "Artifacts"
    review_directory = output_directory / "Review"
    artifacts_directory.mkdir(parents=True, exist_ok=True)
    review_directory.mkdir(parents=True, exist_ok=True)
    records: list[dict[str, Any]] = []
    index: list[dict[str, Any]] = []

    with tempfile.TemporaryDirectory(prefix="floorp-curated-catalog-", dir=output_directory.parent) as temporary:
        staging = Path(temporary)
        for source in sources:
            try:
                provenance = validate_declared_provenance(sources_path.parent, source)
            except SourceProvenanceError as error:
                raise CuratedCatalogBuildError(f"quarantined {source['id']} source provenance: {error}") from error
            package = (sources_path.parent / source["package"]).resolve()
            try:
                package.relative_to(sources_path.parent.resolve())
            except ValueError as error:
                raise CuratedCatalogBuildError(f"package {source['id']} escapes catalog root") from error
            if not package.is_dir():
                raise CuratedCatalogBuildError(f"package directory is missing: {package}")
            generation = f"{generation_prefix}-{source['id']}"
            if len(generation) > 47 or not re.fullmatch(r"[A-Za-z0-9_-]{1,47}", generation):
                raise CuratedCatalogBuildError(f"invalid generated immutable generation {generation}")
            build_directory = staging / source["id"]
            try:
                result = ingest(
                    package,
                    output_directory=build_directory,
                    extension_id=source["extensionID"],
                    generation=generation,
                    upstream=source["sourceURL"],
                    license_id=source["license"],
                    patch_path=None,
                )
            except (IngestionError, OSError) as error:
                raise CuratedCatalogBuildError(f"quarantined {source['id']}: {error}") from error
            artifact_name = f"{source['id']}.fwea1"
            artifact = build_directory / "artifact.fwea1"
            destination = artifacts_directory / artifact_name
            os.replace(artifact, destination)
            final_review = review_directory / source["id"]
            if final_review.exists():
                shutil.rmtree(final_review)
            os.replace(build_directory, final_review)
            original_digest = source.get("originalArtifactSHA256") or result.source_digest
            notices_sha256 = notices_digest(
                package,
                modification_status=source["modificationStatus"],
            )
            review_source_sha256 = source_review_digest(source, provenance)
            disclosure = disclosures[source["id"]]
            review_evidence_sha256 = sha256(canonical_json({
                "artifactSHA256": result.artifact_digest,
                "manifestSHA256": result.manifest_digest,
                "noticesSHA256": notices_sha256,
                "resourceInventorySHA256": result.inventory_digest,
                "source": {
                    "id": source["id"],
                    "sourceReviewSHA256": review_source_sha256,
                    "sourceURL": source["sourceURL"],
                    "upstreamRevision": source["upstreamRevision"],
                },
                "userDisclosure": disclosure,
            }))
            record = {
                "extensionID": source["extensionID"],
                "generation": generation,
                "version": result.manifest["version"],
                "artifactURL": f"https://catalog.floorp.invalid/fwea1/{artifact_name}",
                "artifactBytes": result.artifact_bytes,
                "artifactSHA256": result.artifact_digest,
                "manifestSHA256": result.manifest_digest,
                "resourceInventorySHA256": result.inventory_digest,
                "compatibilityProfiles": compatibility_profiles(result.manifest),
                "availability": "available",
                "metadata": {
                    "displayName": source["displayName"],
                    "description": source["description"],
                    "category": source["category"],
                    "upstream": source["upstream"],
                    "upstreamRevision": source["upstreamRevision"],
                    "originalArtifactSHA256": original_digest,
                    "sourceURL": source["sourceURL"],
                    "license": source["license"],
                    "noticesSHA256": notices_sha256,
                    "permissions": metadata_permissions(result.manifest),
                    "hostPermissions": metadata_hosts(result.manifest),
                    "privateProfileCapability": source["privateProfileCapability"],
                    "modificationStatus": source["modificationStatus"],
                    "minimumFloorpBuild": "0.3.0",
                    "disclosure": {
                        **disclosure,
                        "reviewEvidenceSHA256": review_evidence_sha256,
                        "sourceReviewSHA256": review_source_sha256,
                    },
                },
            }
            records.append(record)
            review_record = {
                "id": source["id"],
                "extensionID": source["extensionID"],
                "artifact": f"Artifacts/{artifact_name}",
                "inspection": f"Review/{source['id']}/inspection.json",
                "originalArtifactSHA256": original_digest,
                "sourceURL": source["sourceURL"],
                "upstreamRevision": source["upstreamRevision"],
            }
            if provenance is not None:
                review_record["sourceProvenance"] = provenance["path"]
                review_record["sourceProvenanceSHA256"] = provenance["sha256"]
            index.append(review_record)

    records.sort(key=lambda record: (record["extensionID"], record["generation"]))
    index.sort(key=lambda item: item["extensionID"])
    (output_directory / "catalog-input.json").write_bytes(canonical_json(records))
    (output_directory / "review-index.json").write_bytes(canonical_json({"packages": index, "schema": 1}))
    return records


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--sources", type=Path, default=DEFAULT_CATALOG_ROOT / "catalog-sources.json")
    result.add_argument("--output", type=Path, default=DEFAULT_CATALOG_ROOT)
    result.add_argument("--generation-prefix", default="g20260826")
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        records = build(
            sources_path=arguments.sources,
            output_directory=arguments.output,
            generation_prefix=arguments.generation_prefix,
        )
    except (CuratedCatalogBuildError, OSError, ValueError) as error:
        print(f"curated catalog build failed: {error}", file=__import__("sys").stderr)
        return 2
    print(json.dumps({
        "artifactCount": len(records),
        "catalogInputSHA256": sha256(canonical_json(records)),
        "status": "accepted",
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
