#!/bin/bash
# The entrypoint must allow an explicit pair request and still default to not pairing.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/app"
cat > "$tmp/bin/whatsapp-bridge" << 'EOF'
#!/bin/sh
printf 'bridge-start pair=%s\n' "${WA_PAIR:-0}" >> "$RUNLOG"
exit 0
EOF
cat > "$tmp/bin/mcp" << 'EOF'
#!/bin/sh
printf 'mcp-start\n' >> "$RUNLOG"
exit 0
EOF
chmod 755 "$tmp/bin/whatsapp-bridge" "$tmp/bin/mcp"
sed \
  -e "s#/app/whatsapp-bridge#$tmp/bin/whatsapp-bridge#" \
  -e "s#python3 /app/whatsapp-mcp-server/main.py#$tmp/bin/mcp#" \
  "$root/deploy/entrypoint.sh" > "$tmp/entrypoint.sh"
chmod 755 "$tmp/entrypoint.sh"

RUNLOG=$tmp/default.log
export RUNLOG WA_INSTANCE_DIR=$tmp/instance
WA_MCP_TRANSPORT=streamable-http WA_RUN_BRIDGE=1 "$tmp/entrypoint.sh"
grep -qx 'bridge-start pair=0' "$RUNLOG"
grep -qx 'mcp-start' "$RUNLOG"

RUNLOG=$tmp/explicit.log
export RUNLOG
WA_MCP_TRANSPORT=streamable-http WA_RUN_BRIDGE=1 WA_PAIR=1 "$tmp/entrypoint.sh"
grep -qx 'bridge-start pair=1' "$RUNLOG"

if WA_MCP_TRANSPORT= WA_RUN_BRIDGE=1 "$tmp/entrypoint.sh" >"$tmp/empty.out" 2>"$tmp/empty.err"; then
  echo "missing transport was accepted" >&2
  exit 1
fi
grep -q 'WA_MCP_TRANSPORT is required' "$tmp/empty.err"

echo "entrypoint pair gate passed"
