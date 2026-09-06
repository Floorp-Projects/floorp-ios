#!/usr/bin/env bash
#
# Orchestrates the gated external TestFlight beta submission for Floorp
# (Todo 15). The wrapper only ever uses the Todo-12 client's localization,
# review-detail, review-submission and group/build relationship routes; group
# creation and every other write route remain denied by the client.
#
# Usage:
#   submit-floorp-external-beta.sh \
#     --client scripts/release/app-store-connect-api.py \
#     --build-receipt "$ATTEMPT_DIR/floorp-xcode-cloud-build-receipt.json" \
#     --xcode-cloud-run-id "$RUN_ID" --xcode-cloud-workflow-id "$WORKFLOW_ID" \
#     --expected-source-sha "$SOURCE_SHA" --app-id 6796708699 \
#     --build-id "$BUILD_ID" --expected-build-number "$BUILD_NUMBER" \
#     --expected-bundle-id app.floorp.Floorp \
#     --expected-marketing-version 0.3.0 --expected-platform IOS \
#     --expected-min-os-version 18.4 \
#     --external-group-id "$EXTERNAL_GROUP_ID" \
#     --localization docs/app-store-connect-metadata.json \
#     --review-details "$ATTEMPT_DIR/beta-review-details.json" \
#     --before "$ATTEMPT_DIR/asc-before.json" \
#     --after "$ATTEMPT_DIR/asc-after.json" \
#     [--what-to-test-en firefox-ios/TestFlight/WhatToTest.en-US.txt] \
#     [--what-to-test-ja firefox-ios/TestFlight/WhatToTest.ja-JP.txt] \
#     [--dry-run] [--authorize-mutation] \
#     --output "$ATTEMPT_DIR/task-15-result.json"

set -euo pipefail

CLIENT=""
BUILD_RECEIPT=""
RUN_ID=""
WORKFLOW_ID=""
SOURCE_SHA=""
APP_ID=""
BUILD_ID=""
BUILD_NUMBER=""
BUNDLE_ID=""
MARKETING_VERSION=""
PLATFORM=""
MIN_OS_VERSION=""
GROUP_ID=""
LOCALIZATION=""
REVIEW_DETAILS=""
BEFORE=""
AFTER=""
OUTPUT=""
WHAT_TO_TEST_EN=""
WHAT_TO_TEST_JA=""
AUTHORIZE=""
DRY_RUN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --client) CLIENT="$2"; shift 2 ;;
        --build-receipt) BUILD_RECEIPT="$2"; shift 2 ;;
        --xcode-cloud-run-id) RUN_ID="$2"; shift 2 ;;
        --xcode-cloud-workflow-id) WORKFLOW_ID="$2"; shift 2 ;;
        --expected-source-sha) SOURCE_SHA="$2"; shift 2 ;;
        --app-id) APP_ID="$2"; shift 2 ;;
        --build-id) BUILD_ID="$2"; shift 2 ;;
        --expected-build-number) BUILD_NUMBER="$2"; shift 2 ;;
        --expected-bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --expected-marketing-version) MARKETING_VERSION="$2"; shift 2 ;;
        --expected-platform) PLATFORM="$2"; shift 2 ;;
        --expected-min-os-version) MIN_OS_VERSION="$2"; shift 2 ;;
        --external-group-id) GROUP_ID="$2"; shift 2 ;;
        --localization) LOCALIZATION="$2"; shift 2 ;;
        --review-details) REVIEW_DETAILS="$2"; shift 2 ;;
        --before) BEFORE="$2"; shift 2 ;;
        --after) AFTER="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --what-to-test-en) WHAT_TO_TEST_EN="$2"; shift 2 ;;
        --what-to-test-ja) WHAT_TO_TEST_JA="$2"; shift 2 ;;
        --authorize-mutation) AUTHORIZE="--authorize-mutation"; shift ;;
        --dry-run) DRY_RUN="--dry-run"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for required in \
    CLIENT BUILD_RECEIPT RUN_ID WORKFLOW_ID SOURCE_SHA APP_ID BUILD_ID BUILD_NUMBER \
    BUNDLE_ID MARKETING_VERSION PLATFORM MIN_OS_VERSION GROUP_ID LOCALIZATION \
    REVIEW_DETAILS BEFORE AFTER OUTPUT; do
    if [[ -z "${!required}" ]]; then
        echo "missing required argument --${required,,}" >&2
        exit 2
    fi
done

CLIENT="$(cd "$(dirname "$CLIENT")" && pwd)/$(basename "$CLIENT")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPT_VALIDATOR="$SCRIPT_DIR/floorp_xcode_cloud_build_receipt.py"
test -f "$BUILD_RECEIPT"
test -f "$RECEIPT_VALIDATOR"

# Read-only preflight gate: capture every resource that identifies the run,
# build, external group, review state, and localization state before any write.
asc_get() {
    local path="$1" output="$2"
    python3 "$CLIENT" get "$path" --output "$output"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

asc_get "/v1/betaAppReviewDetails?filter[app]=$APP_ID&limit=200" "$TMP_DIR/review-details-before.json"
asc_get "/v1/betaAppReviewSubmissions?filter[build]=$BUILD_ID&limit=200" "$TMP_DIR/submissions-before.json"
asc_get "/v1/betaBuildLocalizations?filter[build]=$BUILD_ID&limit=200" "$TMP_DIR/localizations-before.json"
asc_get "/v1/betaGroups/$GROUP_ID/builds?limit=200" "$TMP_DIR/group-builds-before.json"
asc_get "/v1/ciBuildRuns/$RUN_ID?include=workflow" "$TMP_DIR/xcode-cloud-run-before.json"
asc_get "/v1/ciBuildRuns/$RUN_ID/relationships/builds?limit=200" "$TMP_DIR/xcode-cloud-build-linkage-before.json"
asc_get "/v1/builds/$BUILD_ID?include=app,preReleaseVersion" "$TMP_DIR/build-before.json"
asc_get "/v1/betaGroups/$GROUP_ID?include=app" "$TMP_DIR/group-before.json"

python3 "$RECEIPT_VALIDATOR" verify-submission \
    --receipt "$BUILD_RECEIPT" \
    --run "$TMP_DIR/xcode-cloud-run-before.json" \
    --linkage "$TMP_DIR/xcode-cloud-build-linkage-before.json" \
    --build "$TMP_DIR/build-before.json" \
    --group "$TMP_DIR/group-before.json" \
    --expected-run-id "$RUN_ID" \
    --expected-workflow-id "$WORKFLOW_ID" \
    --expected-source-sha "$SOURCE_SHA" \
    --expected-build-id "$BUILD_ID" \
    --expected-build-number "$BUILD_NUMBER" \
    --expected-app-id "$APP_ID" \
    --expected-bundle-id "$BUNDLE_ID" \
    --expected-marketing-version "$MARKETING_VERSION" \
    --expected-platform "$PLATFORM" \
    --expected-min-os-version "$MIN_OS_VERSION" \
    --expected-group-id "$GROUP_ID" \
    --output "$TMP_DIR/source-bound-build-preflight.json"

# Group membership drives both idempotency and review eligibility. Validate the
# complete relationship collection before any localization or review write, so
# a paginated, malformed, or duplicate snapshot always results in zero writes.
GROUP_HAS_BUILD="$(python3 - "$TMP_DIR/group-builds-before.json" "$BUILD_ID" <<'PYEOF'
import json, sys

path, build_id = sys.argv[1:]
payload = json.load(open(path))
if not isinstance(payload, dict):
    raise SystemExit("preflight failed: external group builds payload is malformed")
links = payload.get("links")
if links is not None and not isinstance(links, dict):
    raise SystemExit("preflight failed: external group builds pagination is malformed")
if isinstance(links, dict) and links.get("next") not in (None, ""):
    raise SystemExit("preflight failed: external group builds response is paginated")
rows = payload.get("data")
if not isinstance(rows, list):
    raise SystemExit("preflight failed: external group builds payload is missing a data array")
ids = []
for row in rows:
    if not isinstance(row, dict) or row.get("type") != "builds":
        raise SystemExit("preflight failed: external group builds contains a malformed resource")
    row_id = row.get("id")
    if not isinstance(row_id, str) or not row_id:
        raise SystemExit("preflight failed: external group build ID is missing")
    ids.append(row_id)
if len(ids) != len(set(ids)):
    raise SystemExit("preflight failed: external group builds contains duplicate resources")
print("yes" if build_id in ids else "no")
PYEOF
)"

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

state_sha256_of() {
    python3 "$CLIENT" fingerprint-state --input "$1"
}

validate_submission_snapshot() {
    local input="$1" cardinality="$2" phase="$3" output="$4"
    python3 - "$input" "$cardinality" "$phase" "$output" <<'PYEOF'
import json, sys

input_path, cardinality, phase, output_path = sys.argv[1:]
allowed_states = {"WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"}

payload = json.load(open(input_path))
if not isinstance(payload, dict):
    raise SystemExit(f"{phase} failed: Beta App Review submissions payload is malformed")
links = payload.get("links")
if links is not None and not isinstance(links, dict):
    raise SystemExit(f"{phase} failed: Beta App Review submission pagination is malformed")
if isinstance(links, dict) and links.get("next") not in (None, ""):
    raise SystemExit(
        f"{phase} failed: Beta App Review submissions are paginated; "
        "refusing an incomplete duplicate check"
    )
rows = payload.get("data")
if not isinstance(rows, list):
    raise SystemExit(
        f"{phase} failed: Beta App Review submissions payload is missing a data array"
    )
if cardinality == "optional":
    if len(rows) > 1:
        raise SystemExit(
            f"{phase} failed: expected at most one Beta App Review submission; "
            f"found {len(rows)} duplicate records"
        )
    if not rows:
        with open(output_path, "w") as handle:
            json.dump({"id": "", "betaReviewState": None}, handle)
        raise SystemExit(0)
elif cardinality == "required":
    if not rows:
        raise SystemExit(f"{phase} failed: Beta App Review submission is missing")
    if len(rows) > 1:
        raise SystemExit(
            f"{phase} failed: expected exactly one Beta App Review submission; "
            f"found {len(rows)} duplicate records"
        )
else:
    raise SystemExit(f"internal error: unsupported submission cardinality {cardinality}")

row = rows[0]
if not isinstance(row, dict):
    raise SystemExit(f"{phase} failed: Beta App Review submission is malformed")
submission_id = row.get("id")
if not isinstance(submission_id, str) or not submission_id.strip():
    raise SystemExit(f"{phase} failed: Beta App Review submission id is missing")
attributes = row.get("attributes")
state = attributes.get("betaReviewState") if isinstance(attributes, dict) else None
if not isinstance(state, str) or not state.strip():
    raise SystemExit(f"{phase} failed: betaReviewState is missing")
if state not in allowed_states:
    raise SystemExit(
        f"{phase} failed: betaReviewState {json.dumps(state)} is not releasable"
    )

with open(output_path, "w") as handle:
    json.dump({"id": submission_id, "betaReviewState": state}, handle)
PYEOF
}

# Reject ambiguous or terminally failed existing review submissions before the
# first mutation. Only these states are safe to treat as an idempotent submit.
validate_submission_snapshot \
    "$TMP_DIR/submissions-before.json" optional preflight \
    "$TMP_DIR/submission-before-validated.json"
EXISTING_SUBMISSION_ID="$(python3 - "$TMP_DIR/submission-before-validated.json" <<'PYEOF'
import json, sys
print(json.load(open(sys.argv[1]))["id"])
PYEOF
)"

# App Review contact information is required. Demo credentials are required only
# when App Store Connect explicitly says a demo account is needed. Validate this
# and the notes-only patch payload before localization or review mutations.
python3 - \
    "$TMP_DIR/review-details-before.json" \
    "$REVIEW_DETAILS" \
    "$TMP_DIR/review-details-validated.json" <<'PYEOF'
import json, sys

current_path, desired_path, output_path = sys.argv[1:]
payload = json.load(open(current_path))
if not isinstance(payload, dict):
    raise SystemExit("preflight failed: betaAppReviewDetails payload is malformed")
links = payload.get("links")
if links is not None and not isinstance(links, dict):
    raise SystemExit("preflight failed: betaAppReviewDetails pagination is malformed")
if isinstance(links, dict) and links.get("next") not in (None, ""):
    raise SystemExit("preflight failed: betaAppReviewDetails response is paginated")
rows = payload.get("data")
if not isinstance(rows, list) or len(rows) != 1:
    raise SystemExit("preflight failed: expected exactly one betaAppReviewDetails record")
row = rows[0]
if not isinstance(row, dict) or row.get("type") != "betaAppReviewDetails":
    raise SystemExit("preflight failed: betaAppReviewDetails resource is malformed")
review_id = row.get("id")
if not isinstance(review_id, str) or not review_id:
    raise SystemExit("preflight failed: betaAppReviewDetails ID is missing")
attributes = row.get("attributes")
if not isinstance(attributes, dict):
    raise SystemExit("preflight failed: betaAppReviewDetails attributes are missing")
contact_fields = (
    "contactEmail", "contactFirstName", "contactLastName", "contactPhone",
)
if any(
    not isinstance(attributes.get(name), str) or not attributes[name].strip()
    for name in contact_fields
):
    raise SystemExit("preflight failed: live betaAppReviewDetails contact fields are incomplete")
demo_required = attributes.get("demoAccountRequired")
if not isinstance(demo_required, bool):
    raise SystemExit("preflight failed: demoAccountRequired must be a boolean")
if demo_required:
    demo_fields = ("demoAccountName", "demoAccountPassword")
    if any(
        not isinstance(attributes.get(name), str) or not attributes[name].strip()
        for name in demo_fields
    ):
        raise SystemExit(
            "preflight failed: demo account is required but its credentials are incomplete"
        )
desired = json.load(open(desired_path))
if not isinstance(desired, dict) or set(desired) != {"notes"}:
    raise SystemExit("preflight failed: review details payload must contain only notes")
notes = desired.get("notes")
if not isinstance(notes, str) or not notes.strip():
    raise SystemExit("preflight failed: release review notes are missing")
if len(notes.encode("utf-8")) > 4000:
    raise SystemExit("preflight failed: release review notes exceed 4,000 bytes")
json.dump({"id": review_id, "demoAccountRequired": demo_required}, open(output_path, "w"))
PYEOF

cat > "$TMP_DIR/before.json" <<EOF
{
  "betaAppReviewDetails": "$(sha256_of "$TMP_DIR/review-details-before.json")",
  "betaAppReviewSubmissions": "$(sha256_of "$TMP_DIR/submissions-before.json")",
  "betaBuildLocalizations": "$(sha256_of "$TMP_DIR/localizations-before.json")",
  "betaGroups": "$(sha256_of "$TMP_DIR/group-builds-before.json")",
  "builds": "$(sha256_of "$TMP_DIR/build-before.json")"
}
EOF

REVIEW_DETAILS_ID="$(python3 - "$TMP_DIR/review-details-validated.json" <<'PYEOF'
import json, sys
print(json.load(open(sys.argv[1]))["id"])
PYEOF
)"

LOCALE_JSON="$(python3 -c "
import json
data = json.load(open('$LOCALIZATION'))
print(json.dumps(data.get('app', {}).get('primary_locales', ['en-US'])))
")"

EN_TEXT="$(cat "${WHAT_TO_TEST_EN:-firefox-ios/TestFlight/WhatToTest.en-US.txt}")"
JA_TEXT="$(cat "${WHAT_TO_TEST_JA:-firefox-ios/TestFlight/WhatToTest.ja-JP.txt}" 2>/dev/null || true)"

# 1. Localization (create or patch the en-US/ja-JP beta build localizations).
asc_beta_locale() {
    # betaBuildLocalizations uses the ASC beta locale set ("ja", not "ja-JP").
    case "$1" in
        ja-JP|ja) echo "ja" ;;
        *) echo "$1" ;;
    esac
}

upsert_localization() {
    local source_locale="$1" text="$2"
    local locale
    locale="$(asc_beta_locale "$source_locale")"
    local guard_path="/v1/betaBuildLocalizations?filter[build]=$BUILD_ID&limit=200"
    local snapshot="$TMP_DIR/localizations-before-$locale.json"
    asc_get "$guard_path" "$snapshot"
    local existing_id
    existing_id="$(python3 -c "
import json
data = json.load(open('$snapshot'))
rows = [r for r in data.get('data', []) if r.get('attributes', {}).get('locale') == '$locale']
print(rows[0]['id'] if rows else '')
")"
    local prior_state
    prior_state="$(state_sha256_of "$snapshot")"
    if [[ -z "$existing_id" ]]; then
        python3 - "$BUILD_ID" "$locale" "$text" > "$TMP_DIR/localization-body-$locale.json" <<'PYEOF'
import json, sys
build_id, locale, text = sys.argv[1], sys.argv[2], sys.argv[3]
body = {"data": {"type": "betaBuildLocalizations", "attributes": {
    "locale": locale,
    "whatsNew": text[:4000],
}, "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}}
print(json.dumps(body))
PYEOF
        python3 "$CLIENT" post /v1/betaBuildLocalizations \
            --body "$TMP_DIR/localization-body-$locale.json" \
            --intended-id "$BUILD_ID" \
            --prior-state-sha256 "$prior_state" \
            --guard-get "$guard_path" \
            $AUTHORIZE $DRY_RUN \
            --output "$TMP_DIR/localization-created-$locale.json"
    else
        python3 - "$existing_id" "$text" > "$TMP_DIR/localization-patch-$locale.json" <<'PYEOF'
import json, sys
localization_id, text = sys.argv[1], sys.argv[2]
print(json.dumps({"data": {"type": "betaBuildLocalizations", "id": localization_id,
                           "attributes": {"whatsNew": text[:4000]}}}))
PYEOF
        python3 "$CLIENT" patch "/v1/betaBuildLocalizations/$existing_id" \
            --body "$TMP_DIR/localization-patch-$locale.json" \
            --intended-id "$existing_id" \
            --prior-state-sha256 "$prior_state" \
            --guard-get "$guard_path" \
            $AUTHORIZE $DRY_RUN \
            --output "$TMP_DIR/localization-patched-$locale.json"
    fi
}

upsert_localization "en-US" "$EN_TEXT"
if [[ -n "$JA_TEXT" ]]; then
    upsert_localization "ja-JP" "$JA_TEXT"
fi

# 2. Review details (contact + notes for Beta App Review).
python3 - \
    "$REVIEW_DETAILS_ID" \
    "$TMP_DIR/review-details-before.json" \
    "$REVIEW_DETAILS" > "$TMP_DIR/review-details-body.json" <<'PYEOF'
import json, sys
review_id, current_path, desired_path = sys.argv[1:]
desired = json.load(open(desired_path))
notes = desired.get("notes")
if not isinstance(notes, str) or not notes.strip():
    raise SystemExit("preflight failed: release review notes are missing")
attrs = {"notes": notes}
print(json.dumps({"data": {"type": "betaAppReviewDetails", "id": review_id,
                           "attributes": attrs}}))
PYEOF
REVIEW_GUARD_PATH="/v1/betaAppReviewDetails?filter[app]=$APP_ID&limit=200"
python3 "$CLIENT" patch "/v1/betaAppReviewDetails/$REVIEW_DETAILS_ID" \
    --body "$TMP_DIR/review-details-body.json" \
    --intended-id "$REVIEW_DETAILS_ID" \
    --prior-state-sha256 "$(state_sha256_of "$TMP_DIR/review-details-before.json")" \
    --guard-get "$REVIEW_GUARD_PATH" \
    $AUTHORIZE $DRY_RUN \
    --output "$TMP_DIR/review-details-patched.json"

# 3. Assign the build to the external group (idempotent relationship).
# Apple only accepts an external Beta App Review submission after the build is
# part of an external tester group, so this relationship must be committed first.
if [[ "$GROUP_HAS_BUILD" == "yes" ]]; then
    # Idempotency: the build is already assigned to the external group.
    python3 - "$BUILD_ID" "$GROUP_ID" > "$TMP_DIR/group-assigned.json" <<'PYEOF'
import json, sys
print(json.dumps({"idempotent": True, "build_id": sys.argv[1], "group_id": sys.argv[2]}))
PYEOF
else
    python3 - "$BUILD_ID" > "$TMP_DIR/group-body.json" <<'PYEOF'
import json, sys
print(json.dumps({"data": [{"type": "builds", "id": sys.argv[1]}]}))
PYEOF
    python3 "$CLIENT" post "/v1/betaGroups/$GROUP_ID/relationships/builds" \
        --body "$TMP_DIR/group-body.json" \
        --intended-id "$BUILD_ID" \
        --prior-state-sha256 "$(state_sha256_of "$TMP_DIR/group-builds-before.json")" \
        --guard-get "/v1/betaGroups/$GROUP_ID/builds?limit=200" \
        $AUTHORIZE $DRY_RUN \
        --output "$TMP_DIR/group-assigned.json"
fi

# A successful relationship POST is not enough to prove that App Store Connect
# will accept the subsequent review submission. Require the assigned build to be
# visible from the external group before submitting. A dry run can only verify
# the planned write order because it deliberately does not mutate remote state.
if [[ -z "$DRY_RUN" ]]; then
    asc_get "/v1/betaGroups/$GROUP_ID/builds?limit=200" "$TMP_DIR/group-builds-ready.json"
    python3 - "$TMP_DIR/group-builds-ready.json" "$BUILD_ID" <<'PYEOF'
import json, sys

path, build_id = sys.argv[1:]
rows = json.load(open(path)).get("data")
if not isinstance(rows, list):
    raise SystemExit("readback failed: external group builds payload is missing a data array")
matches = [row for row in rows if isinstance(row, dict) and row.get("id") == build_id]
if not matches:
    raise SystemExit("readback failed: build is not assigned to the external group")
if len(matches) > 1:
    raise SystemExit("readback failed: external group contains duplicate build assignments")
PYEOF
fi

# 4. Beta App Review submission for the exact, externally assigned build.
if [[ -n "$EXISTING_SUBMISSION_ID" ]]; then
    # Idempotency: the build already has a Beta App Review submission.
    python3 - "$EXISTING_SUBMISSION_ID" "$BUILD_ID" > "$TMP_DIR/submission-created.json" <<'PYEOF'
import json, sys
print(json.dumps({"idempotent": True, "submission_id": sys.argv[1], "build_id": sys.argv[2]}))
PYEOF
else
    python3 - "$BUILD_ID" > "$TMP_DIR/submission-body.json" <<'PYEOF'
import json, sys
print(json.dumps({"data": {"type": "betaAppReviewSubmissions", "relationships": {
    "build": {"data": {"type": "builds", "id": sys.argv[1]}}}}}))
PYEOF
    python3 "$CLIENT" post /v1/betaAppReviewSubmissions \
        --body "$TMP_DIR/submission-body.json" \
        --intended-id "$BUILD_ID" \
        --prior-state-sha256 "$(state_sha256_of "$TMP_DIR/submissions-before.json")" \
        --guard-get "/v1/betaAppReviewSubmissions?filter[build]=$BUILD_ID&limit=200" \
        $AUTHORIZE $DRY_RUN \
        --output "$TMP_DIR/submission-created.json"
fi

# 5. After-state capture and diff.
asc_get "/v1/betaAppReviewDetails?filter[app]=$APP_ID&limit=200" "$TMP_DIR/review-details-after.json"
asc_get "/v1/betaAppReviewSubmissions?filter[build]=$BUILD_ID&limit=200" "$TMP_DIR/submissions-after.json"
asc_get "/v1/betaBuildLocalizations?filter[build]=$BUILD_ID&limit=200" "$TMP_DIR/localizations-after.json"
asc_get "/v1/betaGroups/$GROUP_ID/builds?limit=200" "$TMP_DIR/group-builds-after.json"
asc_get "/v1/builds/$BUILD_ID?include=app,preReleaseVersion" "$TMP_DIR/build-after.json"

if [[ -z "$DRY_RUN" ]]; then
    validate_submission_snapshot \
        "$TMP_DIR/submissions-after.json" required readback \
        "$TMP_DIR/submission-after-validated.json"
    python3 - \
        "$TMP_DIR/review-details-after.json" \
        "$TMP_DIR/localizations-after.json" \
        "$TMP_DIR/group-builds-after.json" \
        "$REVIEW_DETAILS" \
        "$EN_TEXT" \
        "$JA_TEXT" \
        "$BUILD_ID" <<'PYEOF'
import json, sys
review_path, localizations_path, groups_path, desired_path, en_text, ja_text, build_id = sys.argv[1:]
desired_notes = json.load(open(desired_path))["notes"]
review_rows = json.load(open(review_path)).get("data", [])
if not review_rows or review_rows[0].get("attributes", {}).get("notes") != desired_notes:
    raise SystemExit("readback failed: Beta App Review notes do not match")
localizations = {
    row.get("attributes", {}).get("locale"): row.get("attributes", {}).get("whatsNew")
    for row in json.load(open(localizations_path)).get("data", [])
}
expected = {"en-US": en_text[:4000]}
if ja_text:
    expected["ja"] = ja_text[:4000]
for locale, text in expected.items():
    if localizations.get(locale) != text:
        raise SystemExit(f"readback failed: {locale} beta localization does not match")
group_builds = json.load(open(groups_path)).get("data", [])
group_matches = [
    row for row in group_builds
    if isinstance(row, dict) and row.get("id") == build_id
]
if not group_matches:
    raise SystemExit("readback failed: build is not assigned to the external group")
if len(group_matches) > 1:
    raise SystemExit("readback failed: external group contains duplicate build assignments")
PYEOF
fi

cat > "$TMP_DIR/after.json" <<EOF
{
  "betaAppReviewDetails": "$(sha256_of "$TMP_DIR/review-details-after.json")",
  "betaAppReviewSubmissions": "$(sha256_of "$TMP_DIR/submissions-after.json")",
  "betaBuildLocalizations": "$(sha256_of "$TMP_DIR/localizations-after.json")",
  "betaGroups": "$(sha256_of "$TMP_DIR/group-builds-after.json")",
  "builds": "$(sha256_of "$TMP_DIR/build-after.json")"
}
EOF

cp "$TMP_DIR/before.json" "$BEFORE"
cp "$TMP_DIR/after.json" "$AFTER"

if [[ -z "$DRY_RUN" ]]; then
    SUBMISSION_ID="$(python3 - "$TMP_DIR/submission-after-validated.json" <<'PYEOF'
import json, sys
print(json.load(open(sys.argv[1]))["id"])
PYEOF
)"
else
    SUBMISSION_ID="$EXISTING_SUBMISSION_ID"
fi

REVIEW_STATE="submitted"
if [[ -n "$DRY_RUN" ]]; then
    REVIEW_STATE="planned"
fi

python3 - "$OUTPUT" "$APP_ID" "$BUILD_ID" "$BUILD_NUMBER" "$GROUP_ID" \
    "$RUN_ID" "$WORKFLOW_ID" "$SOURCE_SHA" "$SUBMISSION_ID" "$REVIEW_STATE" \
    "$BEFORE" "$AFTER" <<'PYEOF'
import json, sys
(
    output, app_id, build_id, build_number, group_id, run_id, workflow_id,
    source_sha, submission_id, review_state, before, after,
) = sys.argv[1:]
result = {
    "app_id": app_id,
    "build_id": build_id,
    "build_number": build_number,
    "external_group_id": group_id,
    "source_sha": source_sha,
    "xcode_cloud_run_id": run_id,
    "xcode_cloud_workflow_id": workflow_id,
    "submission_id": submission_id,
    "before": json.load(open(before)),
    "after": json.load(open(after)),
    "review_state": review_state,
}
with open(output, "w") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(output)
PYEOF

echo "External beta submission orchestrated: build ${BUILD_ID} -> group ${GROUP_ID}"
