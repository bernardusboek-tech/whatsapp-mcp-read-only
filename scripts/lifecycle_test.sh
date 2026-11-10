#!/usr/bin/env bash
# Synthetic lifecycle checks. They start sleep stand-ins, never the bridge.
set -euo pipefail
unset WA_INSTANCE_DIR WA_PAIR WA_DENY_INSTANCE_DIRS BRIDGE_BIN
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib=$root/scripts/instance-lib.sh
# shellcheck disable=SC1090
source "$lib"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
helper=$tmp/fake-bridge
cat > "$helper" <<'EOF'
#!/bin/sh
echo $$ > "$WA_INSTANCE_DIR/bridge.pid"
sleep 60
EOF
chmod 700 "$helper"

repo=$(repo_root)
if instance_validate "relative/nope" >/dev/null 2>&1; then
  echo "relative directory was accepted" >&2
  exit 1
fi
if WA_DENY_INSTANCE_DIRS= instance_validate "$repo/nested-instance" >/dev/null 2>&1; then
  echo "repository path was accepted" >&2
  exit 1
fi
denied=$tmp/denied
mkdir -p "$denied"
if WA_DENY_INSTANCE_DIRS="$denied" instance_validate "$denied" >/dev/null 2>&1; then
  echo "denied directory was accepted" >&2
  exit 1
fi

a=$(instance_validate "$tmp/instance-a")
b=$(instance_validate "$tmp/instance-b")
BRIDGE_BIN=$helper "$root/scripts/start-bridge.sh" "$a"
BRIDGE_BIN=$helper "$root/scripts/start-bridge.sh" "$b"
pida=$(tr -cd '0-9' < "$a/bridge.pid")
pidb=$(tr -cd '0-9' < "$b/bridge.pid")
kill -0 "$pida"
kill -0 "$pidb"
"$root/scripts/stop-bridge.sh" "$a"
if kill -0 "$pida" 2>/dev/null; then
  echo "stopped instance is still running" >&2
  exit 1
fi
if ! kill -0 "$pidb" 2>/dev/null; then
  echo "other instance was stopped" >&2
  exit 1
fi

stray=$tmp/stray
mkdir -p "$stray"
sleep 60 &
stray_pid=$!
echo "$stray_pid" > "$stray/bridge.pid"
set +e
"$root/scripts/stop-bridge.sh" "$stray"
code=$?
set -e
if [[ "$code" -eq 0 ]]; then
  echo "stop signaled an unrelated pid" >&2
  kill -TERM "$stray_pid" 2>/dev/null || true
  exit 1
fi
if ! kill -0 "$stray_pid" 2>/dev/null; then
  echo "unrelated pid was killed" >&2
  exit 1
fi
kill -TERM "$stray_pid" 2>/dev/null || true
"$root/scripts/stop-bridge.sh" "$b"
env_out=$("$root/scripts/run-mcp.sh" "$a" --print-env)
printf '%s\n' "$env_out" | grep -Fxq "WA_INSTANCE_DIR=$a"
printf '%s\n' "$env_out" | grep -Fxq "WHATSAPP_DB_PATH=$a/messages.db"
printf '%s\n' "$env_out" | grep -Fxq "WA_MCP_TRANSPORT=stdio"
echo "lifecycle checks passed"
