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
run_check serve-before "$WORK/serve-before.json" || abort "443 serve config is not the expected handler"
gzip -dc -- "$archive" | "$DOCKER" load
"$DOCKER" image inspect localhost/wa-readonly-private:t277 >/dev/null
if ! "$DOCKER" compose -f "$KIT/compose.yaml" -f "$KIT/compose.upgrade.yaml" --project-directory "$KIT" up -d --force-recreate; then
  abort "recreate failed; instance data was not deleted"
fi
if ! "$TAILSCALE" serve status --json >"$WORK/serve-after.json"; then
  abort "tailscale serve status failed after recreate"
fi
run_check serve-before "$WORK/serve-after.json" || abort "443 serve config changed; it was not reset"
printf 'recreated with pairing off. Instance data and port 443 were kept.\n'
printf 'When the phone is in hand, run pair.sh. If no image appears, the log line bridge_not_started class= names the failure.\n'
