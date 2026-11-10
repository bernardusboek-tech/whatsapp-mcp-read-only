#!/bin/bash
# Create only the new read-only instance and its private Serve port.
# Run as root from DSM Task Scheduler. Do not run pair.sh in the same task.
# Usage: install.sh /path/to/wa-readonly-private-t276.docker.tar.gz
set -euo pipefail

KIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
source "$KIT/lib.sh"
export KIT

if [ "${WA_ALLOW_NONROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
  abort "run as root from DSM Task Scheduler"
fi

archive=${1:-}
[ -n "$archive" ] || abort "pass the image archive path"
[ -f "$archive" ] || abort "image archive is missing"
sums="$KIT/SHA256SUMS"
[ -f "$sums" ] || abort "SHA256SUMS is missing"
(
  cd -- "$(dirname -- "$archive")"
  grep -F -- "$(basename -- "$archive")" "$sums" | sha256sum -c -
) || abort "image hash does not match"

require_base_path
if [ -e "$WA_BASE" ]; then
  abort "${WA_BASE} already exists"
fi
resolve_tools
resolve_boekbe

load_image() {
  gzip -dc -- "$archive" | "$DOCKER" load
  "$DOCKER" image inspect "$IMAGE" >/dev/null
  IMAGE_LOADED=1
}

if ! ensure_python; then
  load_image
  PY_MODE=image
  export PY_MODE IMAGE_LOADED
fi

preflight

install -d -m 0755 "$WA_BASE"
install -d -m 0700 -o 65532 -g 65532 "$WA_BASE/instance"
umask 077
if ! command -v openssl >/dev/null 2>&1; then
  abort "openssl is not available"
fi
openssl rand -hex 32 | tr -d '\n' > "$WA_BASE/mcp-token"
printf '\n' >> "$WA_BASE/mcp-token"
chown 65532:65532 "$WA_BASE/mcp-token"
chmod 0600 "$WA_BASE/mcp-token"
mode=$(stat -c '%a %u' "$WA_BASE/mcp-token")
[ "$mode" = "600 65532" ] || abort "token is not mode 0600 owned by uid 65532"
mode=$(stat -c '%a' "$WA_BASE")
[ "$mode" = "755" ] || abort "new directory is not mode 0755"

if [ "${IMAGE_LOADED:-0}" != "1" ]; then
  load_image
fi

compose() {
  if "$DOCKER" compose version >/dev/null 2>&1; then
    "$DOCKER" compose "$@"
  else
    docker-compose "$@"
  fi
}

if ! compose -f "$KIT/compose.yaml" --project-directory "$KIT" up -d; then
  compose -f "$KIT/compose.yaml" --project-directory "$KIT" down
  abort "compose up failed; the new project was removed"
fi
if ! "$TAILSCALE" serve --bg --https=44443 --set-path=/mcp http://127.0.0.1:12789/mcp; then
  "$TAILSCALE" serve --https=44443 --set-path=/mcp off
  abort "serve add failed; only the new 44443 route was removed"
fi
assert_serve_after
printf 'installed. Pairing has not started. Token file stays on the NAS.\n'
printf 'When the phone is in hand, run pair.sh as the next task. Then steady.sh.\n'
