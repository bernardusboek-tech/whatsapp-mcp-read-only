#!/bin/bash
# Fail-closed installer checks. Stubs record mutations and must not be asked to create anything.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bin=$tmp/bin
mkdir -p "$bin"
MUT=$tmp/mutations
: >"$MUT"

cat > "$bin/docker" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$MUT"
if [ "$1" = "ps" ]; then
  printf '%s\n' "${FAKE_CONTAINERS-}"
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "ls" ]; then
  if [ "${3:-}" = "-q" ]; then
    printf 'netid\n'
  else
    printf 'bridge\nwebserver_default\ncrm_default\n'
  fi
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "inspect" ]; then
  if [ "${FAKE_INSPECT_RC:-0}" != "0" ]; then
    exit "$FAKE_INSPECT_RC"
  fi
  cat "$FAKE_INSPECT"
  exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then
  exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "ls" ]; then
  printf '%s\n' "$FAKE_PROJECTS"
  exit 0
fi
printf 'mutation %s\n' "$*" >> "$MUT"
exit 99
EOF
cat > "$bin/tailscale" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$MUT"
if [ "$1" = "serve" ] && [ "$2" = "status" ]; then
  if [ "${FAKE_SERVE_RC:-0}" != "0" ]; then
    exit "$FAKE_SERVE_RC"
  fi
  cat "$FAKE_SERVE"
  exit 0
fi
printf 'mutation %s\n' "$*" >> "$MUT"
exit 99
EOF
cat > "$bin/netstat" << 'EOF'
#!/bin/bash
set -euo pipefail
if [ "${FAKE_NETSTAT_RC:-0}" != "0" ]; then
  exit "$FAKE_NETSTAT_RC"
fi
if [ "$1" = "-rn" ]; then
  printf '%s\n' "$FAKE_ROUTE"
  exit 0
fi
printf '%s\n' "$FAKE_NETSTAT"
EOF
cat > "$bin/ip" << 'EOF'
#!/bin/bash
set -euo pipefail
if [ "${FAKE_IP_RC:-0}" != "0" ]; then
  exit "$FAKE_IP_RC"
fi
printf '%s\n' "$FAKE_IP"
EOF
cat > "$bin/id" << 'EOF'
#!/bin/bash
set -euo pipefail
if [ "${FAKE_ID_RC:-0}" != "0" ]; then
  exit "$FAKE_ID_RC"
fi
if [ "$1" = "-u" ] && [ "$2" = "boekbe" ]; then
  printf '1026\n'
  exit 0
fi
if [ "$1" = "-g" ] && [ "$2" = "boekbe" ]; then
  printf '100\n'
  exit 0
fi
exit 1
EOF
chmod 755 "$bin/docker" "$bin/tailscale" "$bin/netstat" "$bin/ip" "$bin/id"

export PATH="$bin:$PATH" MUT
export DOCKER=docker TAILSCALE=tailscale NETSTAT=netstat IP_BIN="$bin/ip" ID_BIN="$bin/id"
export WA_BASE="$tmp/wa-readonly-2" WA_ALLOW_NONROOT=1 PY_BIN=python3 PY_MODE=host
# shellcheck source=lib.sh
source "$root/lib.sh"

GOOD_SERVE='{"TCP":{"443":{"HTTPS":true}},"Web":{"nas-2021.tailba1801.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8088"}}}},"AllowFunnel":{"nas-2021.tailba1801.ts.net:443":true}}'
GOOD_INSPECT='[{"Name":"bridge","IPAM":{"Config":[{"Subnet":"172.17.0.0/16"}]}},{"Name":"webserver_default","IPAM":{"Config":[{"Subnet":"172.19.0.0/16"}]}},{"Name":"crm_default","IPAM":{"Config":[{"Subnet":"172.25.0.0/16"}]}},{"Name":"none","IPAM":{"Config":null}}]'
GOOD_NETSTAT='Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN
tcp        0      0 127.0.0.1:8088          0.0.0.0:*               LISTEN'
GOOD_IP='default via 10.200.1.1 dev eth0
10.200.1.0/24 dev eth0 scope link
172.17.0.0/16 dev docker0
172.19.0.0/16 dev docker1
172.25.0.0/16 dev docker2'
export FAKE_SERVE="$tmp/serve.json" FAKE_INSPECT="$tmp/inspect.json"
printf '%s\n' "$GOOD_SERVE" > "$FAKE_SERVE"
printf '%s\n' "$GOOD_INSPECT" > "$FAKE_INSPECT"
export FAKE_NETSTAT="$GOOD_NETSTAT" FAKE_IP="$GOOD_IP" FAKE_PROJECTS='[]' FAKE_CONTAINERS=''

expect_abort() {
  local label="$1"
  : >"$MUT"
  if ( preflight ) >"$tmp/out" 2>"$tmp/err"; then
    echo "$label was accepted" >&2
    cat "$tmp/err" >&2
    exit 1
  fi
  if grep -q 'mutation ' "$MUT"; then
    echo "$label mutated resources" >&2
    cat "$MUT" >&2
    exit 1
  fi
}

preflight
if grep -q 'mutation ' "$MUT"; then
  echo "successful preflight mutated resources" >&2
  exit 1
fi

FAKE_NETSTAT_RC=1
export FAKE_NETSTAT_RC
expect_abort "netstat failure"
unset FAKE_NETSTAT_RC

FAKE_NETSTAT='not a table'
export FAKE_NETSTAT
expect_abort "malformed netstat"
export FAKE_NETSTAT="$GOOD_NETSTAT"

FAKE_NETSTAT='Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 0.0.0.0:12789           0.0.0.0:*               LISTEN'
export FAKE_NETSTAT
expect_abort "listening 12789"
export FAKE_NETSTAT="$GOOD_NETSTAT"

FAKE_IP_RC=1
export FAKE_IP_RC
expect_abort "ip route failure"
unset FAKE_IP_RC

printf '%s\n' '[{"Name":"bridge","IPAM":{"Config":[{"Subnet":"172.30.240.0/24"}]}}]' > "$FAKE_INSPECT"
expect_abort "subnet overlap"
printf '%s\n' "$GOOD_INSPECT" > "$FAKE_INSPECT"

FAKE_INSPECT_RC=1
export FAKE_INSPECT_RC
expect_abort "docker inspect failure"
unset FAKE_INSPECT_RC

printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"nas-2021.tailba1801.ts.net:443":{"Handlers":{"/":{"Proxy":"http://10.200.1.58:8088"}}}},"AllowFunnel":{"nas-2021.tailba1801.ts.net:443":true}}' > "$FAKE_SERVE"
expect_abort "wrong 443 proxy"
printf '%s\n' "$GOOD_SERVE" > "$FAKE_SERVE"

printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"nas-2021.tailba1801.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8088"},"/extra":{"Proxy":"http://127.0.0.1:8088"}}}},"AllowFunnel":{"nas-2021.tailba1801.ts.net:443":true}}' > "$FAKE_SERVE"
expect_abort "extra 443 handler"
printf '%s\n' "$GOOD_SERVE" > "$FAKE_SERVE"

printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"nas-2021.tailba1801.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8088"}}}},"AllowFunnel":{"nas-2021.tailba1801.ts.net:443":false}}' > "$FAKE_SERVE"
expect_abort "funnel false"
printf '%s\n' 'not-json' > "$FAKE_SERVE"
expect_abort "malformed serve json"
printf '%s\n' "$GOOD_SERVE" > "$FAKE_SERVE"

FAKE_CONTAINERS='wa-readonly-2'
export FAKE_CONTAINERS
expect_abort "container collision"
FAKE_CONTAINERS='other-app'
export FAKE_CONTAINERS

# network name collision is the ls --format output
# The stub prints fixed names for network ls. Swap by a flag.
cat > "$bin/docker" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$MUT"
if [ "$1" = "ps" ]; then printf '%s\n' "${FAKE_CONTAINERS-}"; exit 0; fi
if [ "$1" = "network" ] && [ "$2" = "ls" ]; then
  if [ "${3:-}" = "-q" ]; then printf 'netid\n'; else printf 'bridge\nwa_readonly_2\n'; fi
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "inspect" ]; then cat "$FAKE_INSPECT"; exit 0; fi
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then exit 0; fi
if [ "$1" = "compose" ] && [ "$2" = "ls" ]; then printf '%s\n' "$FAKE_PROJECTS"; exit 0; fi
printf 'mutation %s\n' "$*" >> "$MUT"
exit 99
EOF
expect_abort "network collision"

# restore docker stub without the colliding network
cat > "$bin/docker" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$MUT"
if [ "$1" = "ps" ]; then printf '%s\n' "${FAKE_CONTAINERS-}"; exit 0; fi
if [ "$1" = "network" ] && [ "$2" = "ls" ]; then
  if [ "${3:-}" = "-q" ]; then printf 'netid\n'; else printf 'bridge\n'; fi
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "inspect" ]; then cat "$FAKE_INSPECT"; exit 0; fi
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then exit 0; fi
if [ "$1" = "compose" ] && [ "$2" = "ls" ]; then printf '%s\n' "$FAKE_PROJECTS"; exit 0; fi
printf 'mutation %s\n' "$*" >> "$MUT"
exit 99
EOF
chmod 755 "$bin/docker"
FAKE_PROJECTS='[{"Name":"wa-readonly-2","Status":"running(1)"}]'
export FAKE_PROJECTS
expect_abort "project collision"
FAKE_PROJECTS='[]'
export FAKE_PROJECTS

FAKE_ID_RC=1
export FAKE_ID_RC
expect_abort "missing boekbe"
unset FAKE_ID_RC

python3 "$root/serve_check.py" serve-before "$FAKE_SERVE"
after=$tmp/after.json
python3 - << PY
import json
before=json.load(open("$FAKE_SERVE"))
after=json.loads(json.dumps(before))
after["TCP"]["44443"]={"HTTPS": True}
after["Web"]["nas-2021.tailba1801.ts.net:44443"]={"Handlers":{"/mcp":{"Proxy":"http://127.0.0.1:12789/mcp"}}}
json.dump(after, open("$after","w"))
PY
python3 "$root/serve_check.py" serve-after "$FAKE_SERVE" "$after"
python3 - << PY
import json
after=json.load(open("$after"))
after["AllowFunnel"]["nas-2021.tailba1801.ts.net:44443"]=True
json.dump(after, open("$after","w"))
PY
if python3 "$root/serve_check.py" serve-after "$FAKE_SERVE" "$after"; then
  echo "public 44443 was accepted" >&2
  exit 1
fi

cat > "$bin/stat" << 'EOF'
#!/bin/bash
path="${@: -1}"
case "$path" in
  */instance) printf '700 65532\n' ;;
  */mcp-token) printf '600 65532\n' ;;
  */pairing-qr.png) printf '600 1026 100\n' ;;
  *) printf '755\n' ;;
esac
EOF
cat > "$bin/chown" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MUT"
exit 0
EOF
cat > "$bin/chmod" << 'EOF'
#!/bin/bash
exit 0
EOF
cat > "$bin/install" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MUT"
exit 0
EOF
chmod 755 "$bin/stat" "$bin/chown" "$bin/chmod" "$bin/install"
hash -r
base=$tmp/qrbase
mkdir -p "$base/instance"
printf 'png' > "$base/instance/pairing-qr.png"
printf 'secret\n' > "$base/mcp-token"
export WA_BASE="$base"
: >"$MUT"
publish_qr "$base/instance/pairing-qr.png"
grep -qx '1026:100 '"$base/pairing-qr.png" "$MUT"
grep -q '0600' "$MUT"
if grep -q "$base/instance " "$MUT" || grep -q "$base/mcp-token" "$MUT"; then
  echo "qr copy changed instance or token" >&2
  exit 1
fi

echo "preflight guards passed"
