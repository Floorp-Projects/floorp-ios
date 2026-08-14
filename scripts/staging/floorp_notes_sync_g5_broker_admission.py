"""Fail-closed bridge from fixed owner trust to driver-admission verification.

This is a metadata-only library boundary for a future root-owned broker.  It
always reloads the fixed owner-pinned trust source, verifies one canonical
driver-admission envelope against that source, and returns no execution
capability.  It never starts a runner or client, accesses credentials, or
contacts any service.
"""

from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from typing import Any, Mapping

from scripts.staging.floorp_notes_sync_g5_driver_admission import (
    DriverAdmissionError as _DriverAdmissionError,
    validate_driver_admission as _validate_driver_admission,
)
from scripts.staging.floorp_notes_sync_g5_owner_trust import (
    OwnerTrustError as _OwnerTrustError,
    load_owner_pinned_driver_trust as _load_owner_pinned_driver_trust,
)


PINNED_SSH_KEYGEN = Path("/usr/bin/ssh-keygen")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_OWNER_TRUST_KEYS = frozenset(
    {
        "driver_key_fingerprint",
        "driver_login",
        "execution_authorization",
        "g5_result",
        "status",
        "trust_bundle",
        "trust_manifest_sha256",
        "trust_version",
    }
)
_DRIVER_DECISION_KEYS = frozenset(
    {
        "admission_digest_sha256",
        "driver_binary_sha256",
        "execution_authorization",
        "g5_result",
        "release_binding",
        "run_binding",
        "status",
    }
)
_TRUST_BUNDLE_KEYS = frozenset({"allowed_signers", "driver_registry", "revocations"})


class BrokerAdmissionError(ValueError):
    """Owner-pinned broker admission is unavailable, invalid, or noncanonical."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise BrokerAdmissionError(message)


def _load_fixed_owner_trust(*, trusted_now: datetime) -> Mapping[str, object]:
    try:
        loaded = _load_owner_pinned_driver_trust(trusted_now=trusted_now)
    except _OwnerTrustError as error:
        raise BrokerAdmissionError("owner-pinned driver trust was rejected") from error
    _require(type(loaded) is dict, "owner-pinned driver trust result is malformed")
    _require(set(loaded) == _OWNER_TRUST_KEYS, "owner-pinned driver trust result has unexpected fields")
    _require(
        loaded["status"] == "owner-pinned-driver-trust-valid",
        "owner-pinned driver trust result is not valid",
    )
    _require(
        loaded["execution_authorization"] == "not-granted",
        "owner-pinned driver trust must not grant execution",
    )
    _require(loaded["g5_result"] == "not-assessed", "owner-pinned driver trust must not claim G5")
    _require(type(loaded["driver_login"]) is str and bool(loaded["driver_login"]), "driver login is invalid")
    _require(
        type(loaded["driver_key_fingerprint"]) is str and bool(loaded["driver_key_fingerprint"]),
        "driver key fingerprint is invalid",
    )
    _require(
        type(loaded["trust_manifest_sha256"]) is str
        and SHA256.fullmatch(loaded["trust_manifest_sha256"]) is not None,
        "owner-pinned trust manifest digest is invalid",
    )
    _require(
        type(loaded["trust_version"]) is int and loaded["trust_version"] > 0,
        "owner-pinned trust version is invalid",
    )
    bundle = loaded["trust_bundle"]
    _require(type(bundle) is dict and set(bundle) == _TRUST_BUNDLE_KEYS, "owner-pinned trust bundle is malformed")
    _require(all(type(value) is bytes and bool(value) for value in bundle.values()), "owner-pinned trust bytes are invalid")
    return loaded


def verify_broker_admission(
    raw_admission: bytes,
    *,
    expected_run_binding: Mapping[str, Any],
    expected_release_binding: Mapping[str, Any],
    trusted_now: datetime,
) -> dict[str, str]:
    """Verify a canonical admission against freshly loaded fixed owner trust.

    No caller may provide a trust bundle, path, signature verifier, or callback.
    A valid metadata check still leaves execution and G5 assessment unavailable.
    """

    owner_trust = _load_fixed_owner_trust(trusted_now=trusted_now)
    bundle = owner_trust["trust_bundle"]
    assert type(bundle) is dict
    try:
        decision = _validate_driver_admission(
            raw_admission,
            trust_bundle=bundle,
            expected_run_binding=expected_run_binding,
            expected_release_binding=expected_release_binding,
            trusted_now=trusted_now,
            ssh_keygen=PINNED_SSH_KEYGEN,
        )
    except _DriverAdmissionError as error:
        raise BrokerAdmissionError("driver admission was rejected") from error
    _require(type(decision) is dict and set(decision) == _DRIVER_DECISION_KEYS, "driver admission result is malformed")
    _require(decision["status"] == "driver-admission-valid", "driver admission result is not valid")
    _require(decision["execution_authorization"] == "not-granted", "driver admission must not grant execution")
    _require(decision["g5_result"] == "not-assessed", "driver admission must not claim G5")
    return {
        "execution_authorization": "not-granted",
        "g5_result": "not-assessed",
    }
