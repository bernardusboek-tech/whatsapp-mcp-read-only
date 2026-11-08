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
if ! "$TAILSCALE" serve --https=44443 --set-path=/mcp off; then
  if "$TAILSCALE" serve status --json | grep -q '44443'; then
    abort "44443 is still served and was not removed"
  fi
fi

if ! "$DOCKER" compose -f "$KIT/compose.yaml" --project-directory "$KIT" down; then
  abort "could not remove project wa-readonly-2"
fi
if ! names=$("$DOCKER" ps -a --format '{{.Names}}'); then
  abort "docker ps failed during rollback"
fi
if printf '%s\n' "$names" | grep -qx 'wa-readonly-2'; then
  "$DOCKER" rm -f wa-readonly-2
fi
if ! netnames=$("$DOCKER" network ls --format '{{.Name}}'); then
  abort "docker network ls failed during rollback"
fi
if printf '%s\n' "$netnames" | grep -qx 'wa_readonly_2'; then
  "$DOCKER" network rm wa_readonly_2
fi

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
