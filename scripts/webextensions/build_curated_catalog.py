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
from pathlib import Path
from typing import Any

from ingest_extension import IngestionError, canonical_json, ingest, sha256, strict_json_loads


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG_ROOT = REPOSITORY_ROOT / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
SOURCE_KEYS = {
    "id",
    "extensionID",
    "category",
    "displayName",
    "description",
    "license",
    "modificationStatus",
    "originalArtifactSHA256",
    "package",
    "privateProfileCapability",
    "sourceURL",
    "upstream",
    "upstreamRevision",
}


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
        missing = SOURCE_KEYS - set(value) - {"originalArtifactSHA256"}
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
        result.append(value)
    return sorted(result, key=lambda item: (item["extensionID"], item["id"]))


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
                    "noticesSHA256": notices_digest(
                        package,
                        modification_status=source["modificationStatus"],
                    ),
                    "permissions": metadata_permissions(result.manifest),
                    "hostPermissions": metadata_hosts(result.manifest),
                    "privateProfileCapability": source["privateProfileCapability"],
                    "modificationStatus": source["modificationStatus"],
                    "minimumFloorpBuild": "0.3.0",
                },
            }
            records.append(record)
            index.append({
                "id": source["id"],
                "extensionID": source["extensionID"],
                "artifact": f"Artifacts/{artifact_name}",
                "inspection": f"Review/{source['id']}/inspection.json",
                "originalArtifactSHA256": original_digest,
                "sourceURL": source["sourceURL"],
                "upstreamRevision": source["upstreamRevision"],
            })

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
