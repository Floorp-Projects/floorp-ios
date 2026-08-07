#!/usr/bin/env bash
# Captures FloorpRelease runtime network flows through a local mitmproxy.
#
# The recorder addon writes host/URL metadata only (never bodies, headers,
# cookies, tokens, or key material). The simulator's HTTP/HTTPS proxy is
# pointed at mitmdump for the duration of the capture and restored afterwards.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  capture-floorp-release-network.sh \
    --app PATH --device UDID --mitmdump PATH \
    --flow scripts/release/floorp-release-flow.py \
    --output OUT.mitm --json OUT.json [--seconds N]
EOF
}

APP=""
DEVICE=""
MITMDUMP=""
FLOW=""
OUTPUT=""
JSON_OUTPUT=""
SECONDS="${FLOORP_CAPTURE_SECONDS:-30}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --mitmdump) MITMDUMP="$2"; shift 2 ;;
        --flow) FLOW="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --json) JSON_OUTPUT="$2"; shift 2 ;;
        --seconds) SECONDS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for required in "$APP" "$DEVICE" "$MITMDUMP" "$FLOW" "$OUTPUT" "$JSON_OUTPUT"; do
    if [[ -z "$required" ]]; then
        echo "Missing required argument." >&2
        usage >&2
        exit 2
    fi
done
if [[ ! -d "$APP" ]]; then
    echo "App bundle does not exist: $APP" >&2
    exit 2
fi

PORT=8899
PREFERENCES="$HOME/Library/Developer/CoreSimulator/Devices/$DEVICE/data/Library/Preferences/SystemConfiguration/preferences.plist"

configure_proxy() {
    local enable="$1"
    if [[ ! -f "$PREFERENCES" ]]; then
        echo "Simulator preferences not found at $PREFERENCES" >&2
        return 1
    fi
    local service=""
    service="$(plutil -convert json -o - "$PREFERENCES" | python3 -c "
import json, sys
prefs = json.load(sys.stdin)
services = prefs.get('NetworkServices', {})
for key, service in services.items():
    interface = service.get('Interface', {})
    if interface.get('Type') == 'Ethernet':
        print(key)
        break
")"
    if [[ -z "$service" ]]; then
        echo "No Ethernet network service found in simulator preferences" >&2
        return 1
    fi
    local path="NetworkServices:$service:Proxies"
    if [[ "$enable" == "1" ]]; then
        plutil -replace "$path:HTTPEnable" -integer 1 "$PREFERENCES"
        plutil -replace "$path:HTTPProxy" -string "127.0.0.1" "$PREFERENCES"
        plutil -replace "$path:HTTPPort" -integer "$PORT" "$PREFERENCES"
        plutil -replace "$path:HTTPSEnable" -integer 1 "$PREFERENCES"
        plutil -replace "$path:HTTPSProxy" -string "127.0.0.1" "$PREFERENCES"
        plutil -replace "$path:HTTPSPort" -integer "$PORT" "$PREFERENCES"
    else
        plutil -remove "$path" "$PREFERENCES" 2>/dev/null || true
    fi
    return 0
}

reboot_simulator() {
    xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
    xcrun simctl boot "$DEVICE"
    xcrun simctl bootstatus "$DEVICE" -b
}

if [[ ! -f "$PREFERENCES" ]]; then
    echo "Booted simulator data not found; booting device first." >&2
    xcrun simctl boot "$DEVICE" 2>/dev/null || true
    xcrun simctl bootstatus "$DEVICE" -b
fi

if ! configure_proxy 1; then
    echo "Unable to configure simulator proxy; capture will proceed without proxy." >&2
fi
reboot_simulator

MITM_PID=""
if command -v "$MITMDUMP" >/dev/null 2>&1; then
    FLOORP_OUTPUT="$JSON_OUTPUT" "$MITMDUMP" \
        --listen-port "$PORT" \
        --set confdir="$(mktemp -d)" \
        --scripts "$FLOW" \
        --set block_global=false \
        > "$OUTPUT" 2>&1 &
    MITM_PID=$!
    sleep 2
fi

if [[ -n "$MITM_PID" ]] && kill -0 "$MITM_PID" 2>/dev/null; then
    xcrun simctl install "$DEVICE" "$APP" 2>/dev/null || true
    xcrun simctl launch "$DEVICE" app.floorp.Floorp 2>/dev/null || true
    sleep "$SECONDS"
    xcrun simctl terminate "$DEVICE" app.floorp.Floorp 2>/dev/null || true
    kill "$MITM_PID" 2>/dev/null || true
    wait "$MITM_PID" 2>/dev/null || true
else
    echo "mitmdump failed to start; no capture performed." >&2
fi

configure_proxy 0 || true
reboot_simulator

if [[ ! -f "$JSON_OUTPUT" ]]; then
    echo '{"schema_version": 1, "flows": [], "error": "no flows captured"}' > "$JSON_OUTPUT"
fi
echo "Network metadata written to $JSON_OUTPUT"
