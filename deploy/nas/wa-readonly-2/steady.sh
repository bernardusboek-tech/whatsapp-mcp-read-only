#!/bin/bash
# Return to pairing-off after the phone has accepted the device.
set -euo pipefail

KIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
source "$KIT/lib.sh"

if [ "${WA_ALLOW_NONROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
  abort "run as root from DSM Task Scheduler"
fi

resolve_tools
if ! logs=$("$DOCKER" logs wa-readonly-2 2>&1); then
  abort "docker logs failed; the container was left unchanged"
fi
if ! printf '%s\n' "$logs" | grep -q 'pairing finished'; then
  abort "pairing finished was not in the container log; left the container unchanged"
fi

if "$DOCKER" compose version >/dev/null 2>&1; then
  compose() { "$DOCKER" compose "$@"; }
else
  compose() { docker-compose "$@"; }
fi

compose -f "$KIT/compose.yaml" -f "$KIT/compose.steady.yaml" --project-directory "$KIT" up -d --force-recreate
rm -f -- "$WA_BASE/pairing-qr.png" "$WA_BASE/instance/pairing-qr.png" "$WA_BASE/instance/pairing.payload"
printf 'pairing is off and the qr image was removed. Mail connector URL is https://nas-2021.tailba1801.ts.net:44443/mcp\n'
