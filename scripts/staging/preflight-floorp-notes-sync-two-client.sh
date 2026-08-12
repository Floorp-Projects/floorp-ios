#!/bin/bash -p
set -euo pipefail

case "$-" in
    *p*) ;;
    *)
        echo "preflight-floorp-notes-sync-two-client: invoke with /bin/bash -p" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec /usr/bin/python3 -I "$SCRIPT_DIR/floorp_notes_sync_two_client.py" preflight "$@"
