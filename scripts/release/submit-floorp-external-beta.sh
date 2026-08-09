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
#     --app-id 6796708699 --build-id "$BUILD_ID" \
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
APP_ID=""
BUILD_ID=""
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
        --app-id) APP_ID="$2"; shift 2 ;;
        --build-id) BUILD_ID="$2"; shift 2 ;;
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

for required in CLIENT APP_ID BUILD_ID GROUP_ID LOCALIZATION REVIEW_DETAILS BEFORE AFTER OUTPUT; do
    if [[ -z "${!required}" ]]; then
        echo "missing required argument --${required,,}" >&2
        exit 2
    fi
done

CLIENT="$(cd "$(dirname "$CLIENT")" && pwd)/$(basename "$CLIENT")"

# Read-only preflight gate: capture the five collections this wrapper may read.
asc_get() {
    local path="$1" output="$2"
    python3 "$CLIENT" get "$path" --output "$output" $DRY_RUN
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

asc_get "/v1/betaAppReviewDetails" "$TMP_DIR/review-details-before.json"
asc_get "/v1/betaAppReviewSubmissions" "$TMP_DIR/submissions-before.json"
asc_get "/v1/betaBuildLocalizations" "$TMP_DIR/localizations-before.json"
asc_get "/v1/betaGroups/$GROUP_ID/builds" "$TMP_DIR/group-builds-before.json"
asc_get "/v1/builds/$BUILD_ID" "$TMP_DIR/build-before.json"

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

cat > "$TMP_DIR/before.json" <<EOF
{
  "betaAppReviewDetails": "$(sha256_of "$TMP_DIR/review-details-before.json")",
  "betaAppReviewSubmissions": "$(sha256_of "$TMP_DIR/submissions-before.json")",
  "betaBuildLocalizations": "$(sha256_of "$TMP_DIR/localizations-before.json")",
  "betaGroups": "$(sha256_of "$TMP_DIR/group-builds-before.json")",
  "builds": "$(sha256_of "$TMP_DIR/build-before.json")"
}
EOF

REVIEW_DETAILS_ID=""
if [[ -f "$TMP_DIR/review-details-before.json" ]]; then
    REVIEW_DETAILS_ID="$(python3 -c "
import json, sys
try:
    data = json.load(open('$TMP_DIR/review-details-before.json'))
    rows = data.get('data', [])
    print(rows[0]['id'] if rows else '')
except Exception:
    print('')
")"
fi

if [[ -z "$REVIEW_DETAILS_ID" ]]; then
    echo "preflight failed: no betaAppReviewDetails record for the app (agreement/permission gate)" >&2
    exit 1
fi

LOCALE_JSON="$(python3 -c "
import json
data = json.load(open('$LOCALIZATION'))
print(json.dumps(data.get('app', {}).get('primary_locales', ['en-US'])))
")"

EN_TEXT="$(cat "${WHAT_TO_TEST_EN:-firefox-ios/TestFlight/WhatToTest.en-US.txt}")"
JA_TEXT="$(cat "${WHAT_TO_TEST_JA:-firefox-ios/TestFlight/WhatToTest.ja-JP.txt}" 2>/dev/null || true)"

LOCALIZATIONS_BEFORE_SHA="$(sha256_of "$TMP_DIR/localizations-before.json")"

# 1. Localization (create or patch the en-US/ja-JP beta build localizations).
upsert_localization() {
    local locale="$1" text="$2"
    local existing_id
    existing_id="$(python3 -c "
import json
data = json.load(open('$TMP_DIR/localizations-before.json'))
rows = [r for r in data.get('data', []) if r.get('attributes', {}).get('locale') == '$locale']
print(rows[0]['id'] if rows else '')
")"
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
            --prior-state-sha256 "$LOCALIZATIONS_BEFORE_SHA" \
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
            --prior-state-sha256 "$LOCALIZATIONS_BEFORE_SHA" \
            $AUTHORIZE $DRY_RUN \
            --output "$TMP_DIR/localization-patched-$locale.json"
    fi
}

upsert_localization "en-US" "$EN_TEXT"
if [[ -n "$JA_TEXT" ]]; then
    upsert_localization "ja-JP" "$JA_TEXT"
fi

# 2. Review details (contact + notes for Beta App Review).
python3 - "$REVIEW_DETAILS_ID" "$REVIEW_DETAILS" > "$TMP_DIR/review-details-body.json" <<'PYEOF'
import json, sys
review_id, path = sys.argv[1], sys.argv[2]
details = json.load(open(path))
attrs = {k: details[k] for k in (
    "contactEmail", "contactFirstName", "contactLastName", "contactPhone",
    "demoAccountName", "demoAccountPassword", "notes",
) if k in details}
print(json.dumps({"data": {"type": "betaAppReviewDetails", "id": review_id,
                           "attributes": attrs}}))
PYEOF
python3 "$CLIENT" patch "/v1/betaAppReviewDetails/$REVIEW_DETAILS_ID" \
    --body "$TMP_DIR/review-details-body.json" \
    --intended-id "$REVIEW_DETAILS_ID" \
    --prior-state-sha256 "$(sha256_of "$TMP_DIR/review-details-before.json")" \
    $AUTHORIZE $DRY_RUN \
    --output "$TMP_DIR/review-details-patched.json"

# 3. Beta App Review submission for the exact build.
python3 - "$BUILD_ID" > "$TMP_DIR/submission-body.json" <<'PYEOF'
import json, sys
print(json.dumps({"data": {"type": "betaAppReviewSubmissions", "relationships": {
    "build": {"data": {"type": "builds", "id": sys.argv[1]}}}}}))
PYEOF
python3 "$CLIENT" post /v1/betaAppReviewSubmissions \
    --body "$TMP_DIR/submission-body.json" \
    --intended-id "$BUILD_ID" \
    --prior-state-sha256 "$(sha256_of "$TMP_DIR/submissions-before.json")" \
    $AUTHORIZE $DRY_RUN \
    --output "$TMP_DIR/submission-created.json"

# 4. Assign the build to the external group (idempotent relationship).
python3 - "$BUILD_ID" > "$TMP_DIR/group-body.json" <<'PYEOF'
import json, sys
print(json.dumps({"data": [{"type": "builds", "id": sys.argv[1]}]}))
PYEOF
python3 "$CLIENT" post "/v1/betaGroups/$GROUP_ID/relationships/builds" \
    --body "$TMP_DIR/group-body.json" \
    --intended-id "$BUILD_ID" \
    --prior-state-sha256 "$(sha256_of "$TMP_DIR/group-builds-before.json")" \
    $AUTHORIZE $DRY_RUN \
    --output "$TMP_DIR/group-assigned.json"

# 5. After-state capture and diff.
asc_get "/v1/betaAppReviewDetails" "$TMP_DIR/review-details-after.json"
asc_get "/v1/betaAppReviewSubmissions" "$TMP_DIR/submissions-after.json"
asc_get "/v1/betaBuildLocalizations" "$TMP_DIR/localizations-after.json"
asc_get "/v1/betaGroups/$GROUP_ID/builds" "$TMP_DIR/group-builds-after.json"
asc_get "/v1/builds/$BUILD_ID" "$TMP_DIR/build-after.json"

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

SUBMISSION_ID="$(python3 -c "
import json
try:
    data = json.load(open('$TMP_DIR/submission-created.json'))
    print(data.get('data', {}).get('id', ''))
except Exception:
    print('')
")"

python3 - "$OUTPUT" "$APP_ID" "$BUILD_ID" "$GROUP_ID" "$SUBMISSION_ID" \
    "$BEFORE" "$AFTER" <<'PYEOF'
import json, sys
output, app_id, build_id, group_id, submission_id, before, after = sys.argv[1:]
result = {
    "app_id": app_id,
    "build_id": build_id,
    "external_group_id": group_id,
    "submission_id": submission_id,
    "before": json.load(open(before)),
    "after": json.load(open(after)),
    "review_state": "submitted",
}
with open(output, "w") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(output)
PYEOF

echo "External beta submission orchestrated: build ${BUILD_ID} -> group ${GROUP_ID}"
