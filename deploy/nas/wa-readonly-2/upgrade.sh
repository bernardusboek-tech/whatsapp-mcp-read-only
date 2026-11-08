#!/bin/bash
# Load t277 and recreate only wa-readonly-2. Keeps the instance directory and token.
# Does not start pairing and does not change Serve port 443.
# Usage: upgrade.sh /path/to/wa-readonly-private-t277.docker.tar.gz
set -euo pipefail

KIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
source "$KIT/lib.sh"
export KIT

if [ "${WA_ALLOW_NONROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
  abort "run as root from DSM Task Scheduler"
fi
archive=${1:-}
[ -f "$archive" ] || abort "image archive is missing"
(
  cd -- "$(dirname -- "$archive")"
  grep -F -- "$(basename -- "$archive")" "$KIT/SHA256SUMS" | sha256sum -c -
) || abort "image hash does not match"
require_base_path
[ -d "$WA_BASE/instance" ] || abort "instance directory is missing; refusing to create a new one"
mode=$(stat -c '%a %u' "$WA_BASE/instance")
[ "$mode" = "700 65532" ] || abort "instance ownership changed; refusing to continue"
if [ -e "$WA_BASE/mcp-token" ]; then
  mode=$(stat -c '%a %u' "$WA_BASE/mcp-token")
  [ "$mode" = "600 65532" ] || abort "token ownership changed; refusing to continue"
fi
resolve_tools
resolve_boekbe
if ! ensure_python; then
  abort "python3 is not available"
fi
WORK=$(mktemp -d)
if ! "$TAILSCALE" serve status --json >"$WORK/serve-before.json"; then
  abort "tailscale serve status failed"
fi
run_check serve-installed "$WORK/serve-before.json" || abort "installed 443 and 44443 routes are not the expected pair"
cp -f "$WORK/serve-before.json" "$WORK/serve-snapshot.json"
gzip -dc -- "$archive" | "$DOCKER" load
"$DOCKER" image inspect localhost/wa-readonly-private:t277 >/dev/null
previous=$("$DOCKER" inspect -f '{{.Config.Image}}' wa-readonly-2)
known_image "$previous" || abort "running image is not a known tag"
pin_selected_image localhost/wa-readonly-private:t277
if ! compose_up "$KIT/compose.upgrade.yaml" localhost/wa-readonly-private:t277; then
  pin_selected_image "$previous"
  abort "recreate failed; instance data was not deleted and Serve was not changed"
fi
if ! "$TAILSCALE" serve status --json >"$WORK/serve-after.json"; then
  abort "tailscale serve status failed after recreate"
fi
if ! run_check serve-same "$WORK/serve-snapshot.json" "$WORK/serve-after.json"; then
  pin_selected_image "$previous"
  compose_up "$KIT/compose.upgrade.yaml" "$previous" || abort "serve config changed and the previous image could not be restored"
  abort "serve config changed; previous image restored and Serve was not reset"
fi
printf 'recreated t277 with pairing off. Instance data, 443, and 44443 were kept.\n'
printf 'Run net-diag.sh before pair.sh. Pair only when the phone is in hand.\n'
