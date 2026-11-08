#!/bin/bash
# Exercise the installer guards with fake docker and tailscale. No NAS calls.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bin=$tmp/bin
mkdir -p "$bin"
cat > "$bin/docker" << 'EOF'
#!/bin/bash
set -euo pipefail
if [ "$1" = "network" ] && [ "$2" = "ls" ]; then
  printf 'net1\n'
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "inspect" ]; then
  printf '%s\n' "$FAKE_NETWORKS"
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "create" ]; then
  echo "docker network create was called" >&2
  exit 99
fi
echo "unexpected docker $*" >&2
exit 99
EOF
cat > "$bin/tailscale" << 'EOF'
#!/bin/bash
set -euo pipefail
if [ "$1" = "serve" ] && [ "$2" = "status" ]; then
  printf '%s\n' "$FAKE_SERVE"
  exit 0
fi
echo "unexpected tailscale $*" >&2
exit 99
EOF
cat > "$bin/netstat" << 'EOF'
#!/bin/bash
printf '%s\n' "$FAKE_NETSTAT"
EOF
cat > "$bin/ip" << 'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$bin/docker" "$bin/tailscale" "$bin/netstat" "$bin/ip"

export PATH="$bin:$PATH"
export DOCKER=docker
export TAILSCALE=tailscale
export IP_BIN="$bin/ip"
export WA_BASE="$tmp/wa-readonly-2"
export WA_ALLOW_NONROOT=1
# shellcheck source=lib.sh
source "$root/lib.sh"

FAKE_NETWORKS='[{"IPAM":{"Config":[{"Subnet":"172.17.0.0/16"},{"Subnet":"172.19.0.0/16"},{"Subnet":"172.25.0.0/16"}]}}]'
FAKE_SERVE='{"TCP":{"443":{"HTTPS":true}},"Web":{"nas-2021.tailba1801.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8088"}}}},"AllowFunnel":{"nas-2021.tailba1801.ts.net:443":true}}'
FAKE_NETSTAT='tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN
tcp 0 0 127.0.0.1:8088 0.0.0.0:* LISTEN'
export FAKE_NETWORKS FAKE_SERVE FAKE_NETSTAT
preflight

if cidrs_overlap 172.30.240.0/29 172.17.0.0/16; then
  echo "172.17 was treated as overlapping" >&2
  exit 1
fi
if ! cidrs_overlap 172.30.240.0/29 172.30.240.0/24; then
  echo "contained subnet was not treated as overlapping" >&2
  exit 1
fi

FAKE_NETWORKS='[{"IPAM":{"Config":[{"Subnet":"172.30.240.0/24"}]}}]'
export FAKE_NETWORKS
if ( preflight ); then
  echo "overlap was accepted" >&2
  exit 1
fi

FAKE_NETWORKS='[{"IPAM":{"Config":[{"Subnet":"172.17.0.0/16"}]}}]'
FAKE_SERVE='{"Web":{"nas-2021.tailba1801.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8088"}}},"nas-2021.tailba1801.ts.net:44443":{"Handlers":{"/mcp":{"Proxy":"http://127.0.0.1:12789/mcp"}}}}}'
export FAKE_NETWORKS FAKE_SERVE
if ( preflight ); then
  echo "existing 44443 was accepted" >&2
  exit 1
fi

FAKE_SERVE='{"Web":{"nas-2021.tailba1801.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}'
export FAKE_SERVE
if ( preflight ); then
  echo "changed 443 proxy was accepted" >&2
  exit 1
fi

mkdir -p "$WA_BASE"
FAKE_SERVE='{"Web":{"nas-2021.tailba1801.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8088"}}}}}'
export FAKE_SERVE
if ( preflight ); then
  echo "existing directory was accepted" >&2
  exit 1
fi

echo "preflight guards passed"
