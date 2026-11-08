#!/usr/bin/env bash
# Stop only the pid recorded for this instance, and only when its environment
# names the same directory. This script never matches processes by name.
# Usage: scripts/stop-bridge.sh /absolute/instance-dir
set -euo pipefail
source "$(dirname -- "$0")/instance-lib.sh"
dir=$(instance_validate "${1:-}")
pidfile=$dir/bridge.pid
if [[ ! -f "$pidfile" ]]; then
  echo "no pid file"
  exit 0
fi
pid=$(tr -cd '0-9' < "$pidfile")
if [[ -z "$pid" ]]; then
  echo "pid file is invalid" >&2
  exit 2
fi
if ! kill -0 "$pid" 2>/dev/null; then
  rm -f -- "$pidfile"
  echo "not running"
  exit 0
fi
if [[ ! -r "/proc/$pid/environ" ]]; then
  echo "cannot verify pid; refusing to signal" >&2
  exit 3
fi
if ! tr '\0' '\n' < "/proc/$pid/environ" | grep -Fxq "WA_INSTANCE_DIR=$dir"; then
  echo "pid does not belong to this instance; refusing to signal" >&2
  exit 3
fi
kill -TERM "$pid"
echo "stopped $pid"
