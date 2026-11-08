#!/bin/bash
# Create only the new read-only instance and its private Serve port.
# Run as root from DSM Task Scheduler after the phone is NOT yet being linked.
# Usage: install.sh /path/to/wa-readonly-private-t276.docker.tar.gz
set -euo pipefail

KIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
source "$KIT/lib.sh"
KIT_DIR="$KIT"

if [ "${WA_ALLOW_NONROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
  abort "run as root from DSM Task Scheduler"
fi

archive=${1:-}
[ -n "$archive" ] || abort "pass the image archive path"
[ -f "$archive" ] || abort "image archive is missing"
sums="$KIT_DIR/SHA256SUMS"
[ -f "$sums" ] || abort "SHA256SUMS is missing"
(
  cd -- "$(dirname -- "$archive")"
  grep -F "$(basename -- "$archive")" "$sums" | sha256sum -c -
) || abort "image hash does not match"

preflight

install -d -m 0755 "$WA_BASE"
install -d -m 0700 -o 65532 -g 65532 "$WA_BASE/instance"
umask 077
if command -v openssl >/dev/null 2>&1; then
  openssl rand -hex 32 | tr -d '\n' > "$WA_BASE/mcp-token"
  printf '\n' >> "$WA_BASE/mcp-token"
else
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$WA_BASE/mcp-token"
  printf '\n' >> "$WA_BASE/mcp-token"
fi
chown 65532:65532 "$WA_BASE/mcp-token"
chmod 0600 "$WA_BASE/mcp-token"
mode=$(stat -c '%a' "$WA_BASE/mcp-token")
[ "$mode" = "600" ] || abort "token mode is not 0600"

gzip -dc -- "$archive" | "$DOCKER" load
"$DOCKER" image inspect localhost/wa-readonly-private:t276 >/dev/null

if "$DOCKER" compose version >/dev/null 2>&1; then
  compose() { "$DOCKER" compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
  compose() { docker-compose "$@"; }
else
  abort "docker compose is not installed"
fi

compose -f "$KIT_DIR/compose.yaml" --project-directory "$KIT_DIR" up -d
"$TAILSCALE" serve --bg --https=44443 --set-path=/mcp http://127.0.0.1:12789/mcp
printf 'installed. Pairing has not started. Token file stays on the NAS.\n'
printf 'When the phone is in hand, run pair.sh. Then steady.sh after the link.\n'
