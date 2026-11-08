#!/usr/bin/env bash
# Launch the stdio MCP server against one instance database.
# Usage: scripts/run-mcp.sh /absolute/instance-dir
#        scripts/run-mcp.sh /absolute/instance-dir --print-env
set -euo pipefail
source "$(dirname -- "$0")/instance-lib.sh"
dir=$(instance_validate "${1:-}")
export WA_INSTANCE_DIR="$dir"
export WHATSAPP_DB_PATH="$dir/messages.db"
export WA_REPO_ROOT="$(repo_root)"
if [[ "${2:-}" == "--print-env" ]]; then
  printf 'WA_INSTANCE_DIR=%s\n' "$WA_INSTANCE_DIR"
  printf 'WHATSAPP_DB_PATH=%s\n' "$WHATSAPP_DB_PATH"
  exit 0
fi
cd "$(repo_root)/whatsapp-mcp-server"
exec uv run main.py
