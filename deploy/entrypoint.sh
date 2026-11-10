#!/bin/sh
# Container entrypoint. It does not pair and does not listen unless asked.
set -eu

transport=${WA_MCP_TRANSPORT:-}
bridge=${WA_RUN_BRIDGE:-0}

# WA_PAIR defaults to off. An explicit 1 reaches the bridge, which writes the
# code only into the instance directory. This script never prints that code.
if [ "$bridge" = "1" ] && [ "$transport" = "stdio" ]; then
  echo "stdio cannot share container stdin with the bridge" >&2
  exit 2
fi

if [ "$bridge" = "1" ]; then
  if [ -z "${WA_INSTANCE_DIR:-}" ]; then
    echo "WA_INSTANCE_DIR is required before the bridge can start" >&2
    exit 2
  fi
  /app/whatsapp-bridge &
fi

case "$transport" in
  streamable-http|stdio)
    if [ "$bridge" = "1" ]; then
      python3 /app/whatsapp-mcp-server/main.py &
      mcp_pid=$!
      wait "$mcp_pid"
      status=$?
      if [ -n "${WA_INSTANCE_DIR:-}" ] && [ -f "$WA_INSTANCE_DIR/bridge.pid" ]; then
        kill -TERM "$(tr -cd 0123456789 < "$WA_INSTANCE_DIR/bridge.pid")" 2>/dev/null || true
      fi
      exit "$status"
    fi
    exec python3 /app/whatsapp-mcp-server/main.py
    ;;
  "")
    echo "WA_MCP_TRANSPORT is required; refusing to listen or pair" >&2
    exit 2
    ;;
  *)
    echo "unsupported WA_MCP_TRANSPORT" >&2
    exit 2
    ;;
esac
