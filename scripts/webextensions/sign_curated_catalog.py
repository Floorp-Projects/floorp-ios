#!/usr/bin/env python3
"""Sign a curated catalog only after source-provenance review succeeds.

This is the managed-signing handoff for the checked-in curated catalog. It is
not an iOS runtime component and never fetches source material. The signer
must pass review-quarantined archives explicitly; they are matched to pinned
digests before root/leaf signing authority is invoked. The only app-bound outputs are
the public signed catalog and root public key. The provenance evidence is a
separate, review-only audit record and is rejected if placed under Artifacts/.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from ingest_extension import canonical_json, sha256, strict_json_loads
from sign_catalog import (
    CatalogSigningError,
    ManagedEd25519Signer,
    base64url,
    build_parser as build_catalog_parser,
    load_catalog_signer,
    load_records_bytes,
    signed_catalog,
)
from verify_curated_source_provenance import SourceProvenanceError, verify_archive


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG_ROOT = REPOSITORY_ROOT / "firefox-ios/Floorp/WebExtensions/CuratedCatalog"
CURATED_CATALOG_RELATIVE_PATH = Path("firefox-ios/Floorp/WebExtensions/CuratedCatalog")


class CuratedCatalogSigningError(RuntimeError):
    """The managed signing preconditions are incomplete or inconsistent."""


def _atomic_write(path: Path, data: bytes) -> None:
    """Create a durable output atomically, refusing to replace any file.

    Managed signing must never turn an operator typo or a concurrent writer
    into a replacement of a prior catalog, root key, or external audit record.
    A same-directory hard link makes the no-overwrite guarantee atomic on the
    supported macOS signing filesystem.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary_name, path)
        except FileExistsError:
            raise CuratedCatalogSigningError(f"managed signing refuses to overwrite output: {path}") from None
        os.unlink(temporary_name)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def _parse_source_archives(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        source_id, separator, raw_path = value.partition("=")
        if not separator or not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,46}", source_id):
            raise CuratedCatalogSigningError("source archive must use source-id=/absolute/archive/path")
        archive = Path(raw_path)
        if not archive.is_absolute() or not archive.is_file():
            raise CuratedCatalogSigningError(f"source archive for {source_id} must be an existing absolute path")
        if source_id in result:
            raise CuratedCatalogSigningError(f"source archive was specified twice: {source_id}")
        result[source_id] = archive
    return result


def _load_sources(catalog_root: Path) -> list[dict[str, Any]]:
    try:
        value = strict_json_loads((catalog_root / "catalog-sources.json").read_bytes(), label="catalog sources")
    except (OSError, ValueError) as error:
        raise CuratedCatalogSigningError(f"cannot read curated source manifest: {error}") from error
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise CuratedCatalogSigningError("curated source manifest must be a list of objects")
    return value


def _require_clean_source_commit(repository_root: Path, source_commit: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise CuratedCatalogSigningError("source commit must be a full lowercase Git SHA-1")
    try:
        current = subprocess.run(
            ["git", "-C", str(repository_root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        status = subprocess.run(
            ["git", "-C", str(repository_root), "status", "--porcelain=v1", "--untracked-files=all"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise CuratedCatalogSigningError(f"cannot verify signing checkout: {error}") from error
    if current != source_commit:
        raise CuratedCatalogSigningError("source commit does not match the signing checkout HEAD")
    if status:
        raise CuratedCatalogSigningError("managed signing requires a clean source checkout")


def _require_catalog_checkout(repository_root: Path, catalog_root: Path) -> None:
    """Bind the catalog to the exact Git checkout being approved for signing."""

    expected_catalog_root = (repository_root / CURATED_CATALOG_RELATIVE_PATH).resolve()
    if catalog_root != expected_catalog_root:
        raise CuratedCatalogSigningError("catalog root must be the curated catalog in the signing checkout")
    try:
        actual_repository_root = Path(
            subprocess.run(
                ["git", "-C", str(catalog_root), "rev-parse", "--show-toplevel"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        ).resolve()
    except (OSError, subprocess.CalledProcessError) as error:
        raise CuratedCatalogSigningError(f"cannot verify curated catalog checkout: {error}") from error
    if actual_repository_root != repository_root:
        raise CuratedCatalogSigningError("catalog root does not belong to the signing checkout")


def _require_output_contract(
    *,
    repository_root: Path,
    catalog_root: Path,
    catalog_output: Path,
    root_public_key_output: Path,
    evidence_path: Path,
) -> None:
    """Accept exactly the two app-bound output paths and external audit evidence."""

    expected_catalog_output = (catalog_root / "Artifacts/Signed/catalog.json").resolve()
    expected_root_output = (catalog_root / "Artifacts/Signed/root-public-key.txt").resolve()
    resolved_catalog_output = catalog_output.resolve()
    resolved_root_output = root_public_key_output.resolve()
    resolved_evidence = evidence_path.resolve()
    if resolved_catalog_output != expected_catalog_output:
        raise CuratedCatalogSigningError("signed catalog output must use the curated shipped output path")
    if resolved_root_output != expected_root_output:
        raise CuratedCatalogSigningError("root public key output must use the curated shipped output path")
    if len({resolved_catalog_output, resolved_root_output, resolved_evidence}) != 3:
        raise CuratedCatalogSigningError("catalog, root public key, and provenance evidence outputs must be distinct")
    if resolved_catalog_output.exists() or resolved_root_output.exists() or resolved_evidence.exists():
        raise CuratedCatalogSigningError("managed signing refuses to overwrite an existing output or evidence file")
    if not evidence_path.is_absolute():
        raise CuratedCatalogSigningError("provenance evidence output must be an absolute path outside the source checkout")
    try:
        resolved_evidence.relative_to(repository_root)
    except ValueError:
        return
    raise CuratedCatalogSigningError("provenance evidence must be outside the signing checkout")


def verify_release_inputs(
    *,
    catalog_root: Path,
    records_path: Path,
    source_archives: dict[str, Path],
) -> tuple[bytes, list[dict[str, Any]]]:
    catalog_root = catalog_root.resolve()
    expected_records = (catalog_root / "catalog-input.json").resolve()
    if records_path.resolve() != expected_records:
        raise CuratedCatalogSigningError("curated signing must use this checkout's exact catalog-input.json")
    records_bytes = expected_records.read_bytes()
    sources = _load_sources(catalog_root)
    expected_source_ids = {
        source["id"]
        for source in sources
        if source.get("sourceProvenance") is not None
    }
    if set(source_archives) != expected_source_ids:
        raise CuratedCatalogSigningError("source archive inputs do not exactly match provenance-bound catalog sources")
    verification = []
    for source in sorted(sources, key=lambda item: item["id"]):
        if source.get("sourceProvenance") is None:
            continue
        try:
            result = verify_archive(catalog_root, source, source_archives[source["id"]])
        except SourceProvenanceError as error:
            raise CuratedCatalogSigningError(f"source provenance rejected for {source['id']}: {error}") from error
        verification.append({"sourceID": source["id"], **result})
    return records_bytes, verification


def build_parser() -> argparse.ArgumentParser:
    result = build_catalog_parser()
    result.description = __doc__
    result.add_argument("--catalog-root", type=Path, default=DEFAULT_CATALOG_ROOT)
    result.add_argument("--repository-root", type=Path)
    result.add_argument("--source-commit", required=True)
    result.add_argument(
        "--source-archive",
        action="append",
        default=[],
        metavar="SOURCE_ID=ABSOLUTE_ARCHIVE_PATH",
        help="review-quarantined archive for each sourceProvenance-bound source",
    )
    result.add_argument("--provenance-evidence-output", required=True, type=Path)
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        catalog_root = arguments.catalog_root.resolve()
        repository_root = (arguments.repository_root or catalog_root.parents[3]).resolve()
        _require_catalog_checkout(repository_root, catalog_root)
        _require_clean_source_commit(repository_root, arguments.source_commit)
        source_archives = _parse_source_archives(arguments.source_archive)
        records_bytes, source_verification = verify_release_inputs(
            catalog_root=catalog_root,
            records_path=arguments.records,
            source_archives=source_archives,
        )
        _require_output_contract(
            repository_root=repository_root,
            catalog_root=catalog_root,
            catalog_output=arguments.output,
            root_public_key_output=arguments.root_public_key_output,
            evidence_path=arguments.provenance_evidence_output,
        )
        records = load_records_bytes(records_bytes, schema=arguments.schema)
        # The catalog bytes and provenance declaration were read from this
        # checkout. Re-check immediately before any signing authority is
        # invoked so a concurrent source-tree modification cannot be signed
        # unnoticed.
        _require_catalog_checkout(repository_root, catalog_root)
        _require_clean_source_commit(repository_root, arguments.source_commit)
        root_signer = load_catalog_signer(arguments, "root")
        leaf_signer = load_catalog_signer(arguments, "leaf")
        for signer in (root_signer, leaf_signer):
            if isinstance(signer, ManagedEd25519Signer):
                signer.require_outside(repository_root)
        catalog, root_public = signed_catalog(
            records=records,
            root_key=root_signer,
            leaf_key=leaf_signer,
            root_key_id=arguments.root_key_id,
            leaf_key_id=arguments.leaf_key_id,
            catalog_id=arguments.catalog_id,
            app_bundle_id=arguments.app_bundle_id,
            minimum_app_version=arguments.minimum_app_version,
            channel=arguments.channel,
            sequence=arguments.sequence,
            issued_at=arguments.issued_at,
            expires_at=arguments.expires_at,
            leaf_not_before=arguments.leaf_not_before,
            leaf_not_after=arguments.leaf_not_after,
            schema=arguments.schema,
        )
    except (CatalogSigningError, CuratedCatalogSigningError, OSError, ValueError) as error:
        print(f"curated catalog signing failed: {error}", file=__import__("sys").stderr)
        return 2

    evidence = {
        "catalogID": arguments.catalog_id,
        "catalogInputSHA256": sha256(records_bytes),
        "catalogSHA256": sha256(catalog),
        "channel": arguments.channel,
        "expiresAt": arguments.expires_at,
        "issuedAt": arguments.issued_at,
        "leafKeyID": arguments.leaf_key_id,
        "rootKeyID": arguments.root_key_id,
        "rootPublicKeySHA256": sha256(root_public),
        "schema": 1,
        "sequence": arguments.sequence,
        "sourceCommit": arguments.source_commit,
        "sourceProvenance": source_verification,
        "status": "signed",
    }
    try:
        _atomic_write(arguments.output, catalog)
        _atomic_write(arguments.root_public_key_output, (base64url(root_public) + "\n").encode("ascii"))
        _atomic_write(arguments.provenance_evidence_output, canonical_json(evidence))
    except OSError as error:
        print(f"curated catalog signing failed: cannot write public output: {error}", file=__import__("sys").stderr)
        return 2
    print(json.dumps({
        "catalog_sha256": evidence["catalogSHA256"],
        "catalog_input_sha256": evidence["catalogInputSHA256"],
        "root_public_key_sha256": evidence["rootPublicKeySHA256"],
        "source_commit": evidence["sourceCommit"],
        "source_provenance_count": len(source_verification),
        "status": "signed",
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
