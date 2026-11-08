#!/bin/bash
# Remove only the new Serve port and the new container. Does not reset port 443.
# Pass --remove-data to delete /volume1/docker/wa-readonly-2 as well.
set -euo pipefail

KIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
source "$KIT/lib.sh"
require_base_path

if [ "${WA_ALLOW_NONROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
  abort "run as root from DSM Task Scheduler"
fi

resolve_tools
if ! ensure_python; then
  abort "python3 is not available"
fi
if [ "${1:-}" = "t276" ] || [ "${1:-}" = "t277" ]; then
  pin_selected_image "localhost/wa-readonly-private:${1}"
fi
WORK=$(mktemp -d)
if ! "$TAILSCALE" serve status --json >"$WORK/serve-before.json"; then
  abort "tailscale serve status failed"
fi
run_check serve-installed "$WORK/serve-before.json" || abort "installed 443 and 44443 routes are not the expected pair"
if ! compose_up "$KIT/compose.upgrade.yaml"; then
  abort "recreate failed; Serve was not changed"
fi
if ! "$TAILSCALE" serve status --json >"$WORK/serve-after.json"; then
  abort "tailscale serve status failed after recreate"
fi
run_check serve-same "$WORK/serve-before.json" "$WORK/serve-after.json" || abort "serve config changed; 443 and 44443 were not reset"
if [ "${2:-}" = "--remove-data" ]; then
  abort "refusing to combine an image rollback with data deletion"
fi
printf 'container recreated with pairing off. Ports 443 and 44443 were not changed.\n'
