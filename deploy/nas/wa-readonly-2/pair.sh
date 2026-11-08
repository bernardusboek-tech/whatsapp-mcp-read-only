#!/bin/bash
# Start the three-minute pairing window. Run only when the phone is ready.
# Does not print the pairing text. Open the PNG in File Station and scan it.
set -euo pipefail

KIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
source "$KIT/lib.sh"

if [ "${WA_ALLOW_NONROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
  abort "run as root from DSM Task Scheduler"
fi
[ -d "$WA_BASE/instance" ] || abort "instance directory is missing; run install.sh first"
resolve_tools

compose_up "$KIT/compose.pair.yaml"

qr=""
for _ in $(seq 1 30); do
  if [ -s "$WA_BASE/instance/pairing-qr.png" ]; then
    qr="$WA_BASE/instance/pairing-qr.png"
    break
  fi
  sleep 2
done
[ -n "$qr" ] || abort "pairing image was not written; the window may still be running"

publish_qr "$qr"
printf 'Scan this image within 3 minutes of the container start: %s\n' "$WA_BASE/pairing-qr.png"
printf 'Do not open pairing.payload. After the phone accepts the device, run steady.sh.\n'
