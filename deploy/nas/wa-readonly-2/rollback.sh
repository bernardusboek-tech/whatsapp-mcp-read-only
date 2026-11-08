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

"$TAILSCALE" serve --https=44443 --set-path=/mcp off || true

if "$DOCKER" compose version >/dev/null 2>&1; then
  "$DOCKER" compose -f "$KIT/compose.yaml" --project-directory "$KIT" down || true
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose -f "$KIT/compose.yaml" --project-directory "$KIT" down || true
fi
"$DOCKER" rm -f wa-readonly-2 >/dev/null 2>&1 || true
"$DOCKER" network rm wa-readonly-2 >/dev/null 2>&1 || true

if [ "${1:-}" = "--remove-data" ]; then
  case "$WA_BASE" in
    /volume1/docker/wa-readonly-2|/tmp/*) rm -rf -- "$WA_BASE" ;;
    *) abort "refusing to delete an unexpected path" ;;
  esac
  printf 'removed the new data directory\n'
else
  printf 'container and port 44443 removed. Data directory kept.\n'
fi
printf 'port 443 was not reset.\n'
