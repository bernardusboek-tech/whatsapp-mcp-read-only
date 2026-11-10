#!/bin/bash
# Existing-install fixture: 44443 is already present, and the selected image must survive pair and steady.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bin=$tmp/bin
mkdir -p "$bin" "$tmp/base/instance"
printf 'localhost/wa-readonly-private:t277\n' > "$tmp/base/selected-image"
chmod 755 "$tmp/base"
chmod 700 "$tmp/base/instance"
MUT=$tmp/mutations
: >"$MUT"

cat > "$bin/docker" << 'EOF'
#!/bin/bash
set -euo pipefail
if [ "$1" = "inspect" ]; then
  printf '%s\n' "$FAKE_RUNNING_IMAGE"
  exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then
  exit 0
fi
if [ "$1" = "compose" ]; then
  printf 'compose %s\n' "$*" >> "$MUT"
  exit 0
fi
printf 'mutation %s\n' "$*" >> "$MUT"
exit 99
EOF
chmod 755 "$bin/docker"
export PATH="$bin:$PATH" MUT DOCKER=docker
export WA_BASE="$tmp/base" KIT="$root" PY_BIN=python3 PY_MODE=host WA_ALLOW_NONROOT=1
# shellcheck source=lib.sh
source "$root/lib.sh"

installed=$tmp/installed.json
cat > "$installed" << 'EOF'
{"TCP":{"443":{"HTTPS":true},"44443":{"HTTPS":true}},"Web":{"nas-2021.tailba1801.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8088"}}},"nas-2021.tailba1801.ts.net:44443":{"Handlers":{"/mcp":{"Proxy":"http://127.0.0.1:12789/mcp"}}}},"AllowFunnel":{"nas-2021.tailba1801.ts.net:443":true}}
EOF
if python3 "$root/serve_check.py" serve-before "$installed"; then
  echo "fresh-install check accepted an existing 44443" >&2
  exit 1
fi
python3 "$root/serve_check.py" serve-installed "$installed"
python3 "$root/serve_check.py" serve-same "$installed" "$installed"
python3 - "$installed" "$tmp/changed.json" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["Web"]["nas-2021.tailba1801.ts.net:443"]["Handlers"]["/"]["Proxy"] = "http://127.0.0.1:9"
json.dump(data, open(sys.argv[2], "w"))
PY
if python3 "$root/serve_check.py" serve-same "$installed" "$tmp/changed.json"; then
  echo "changed 443 was treated as unchanged" >&2
  exit 1
fi

export FAKE_RUNNING_IMAGE=localhost/wa-readonly-private:t277
: >"$MUT"
compose_up "$root/compose.pair.yaml"
compose_up "$root/compose.steady.yaml"
compose_up "$root/compose.pair.yaml"
grep -F "compose.pair.yaml" "$MUT" >/dev/null || { echo 'pair compose missing'; cat "$MUT"; exit 1; }
grep -F 'compose.steady.yaml' "$MUT" >/dev/null || { echo 'steady compose missing'; cat "$MUT"; exit 1; }
grep -q 'image: localhost/wa-readonly-private:t277' "$tmp/base/image.override.yaml"
if grep -q 'image: localhost/wa-readonly-private:t276' "$tmp/base/image.override.yaml"; then
  echo "pair or steady wrote the old image" >&2
  exit 1
fi
count=$(grep -c 'compose.pair.yaml' "$MUT")
[ "$count" -eq 2 ]

printf 'localhost/wa-readonly-private:t276\n' > "$tmp/base/selected-image"
export FAKE_RUNNING_IMAGE=localhost/wa-readonly-private:t277
if ( compose_up "$root/compose.pair.yaml" ) >/dev/null 2>"$tmp/err"; then
  echo "image mismatch was accepted" >&2
  echo "file=$(cat "$tmp/base/selected-image")" >&2
  echo "err=$(cat "$tmp/err")" >&2
  exit 1
fi
grep -q 'does not match' "$tmp/err"

echo "lifecycle guards passed"
