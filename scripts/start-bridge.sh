#!/usr/bin/env bash
# Start one bridge in an explicit instance directory.
# Usage: scripts/start-bridge.sh /absolute/instance-dir
# Optional: WA_DENY_INSTANCE_DIRS, WA_PAIR=1, BRIDGE_BIN for a prebuilt command.
set -euo pipefail
source "$(dirname -- "$0")/instance-lib.sh"
dir=$(instance_validate "${1:-}")
repo=$(repo_root)
if [[ -f "$dir/bridge.pid" ]]; then
  old=$(tr -cd '0-9' < "$dir/bridge.pid" || true)
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    echo "instance already has a live pid" >&2
    exit 1
  fi
fi
if [[ -n "${BRIDGE_BIN:-}" ]]; then
  bin=$BRIDGE_BIN
else
  bin=$dir/bridge
  (cd "$repo/whatsapp-bridge" && go build -o "$bin" .)
fi
rm -f -- "$dir/bridge.pid"
WA_INSTANCE_DIR="$dir" \
WA_REPO_ROOT="$repo" \
WA_DENY_INSTANCE_DIRS="${WA_DENY_INSTANCE_DIRS:-}" \
WA_PAIR="${WA_PAIR:-}" \
  "$bin" >>"$dir/bridge.out" 2>>"$dir/bridge.err" &
launcher=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [[ -s "$dir/bridge.pid" ]]; then
    exit 0
  fi
  if ! kill -0 "$launcher" 2>/dev/null; then
    echo "bridge exited before writing a pid file" >&2
    exit 1
  fi
  sleep 0.1
done
echo "bridge did not write a pid file" >&2
exit 1
