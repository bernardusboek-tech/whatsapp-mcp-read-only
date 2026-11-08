#!/bin/bash
# Read-only checks fail closed. They do not create networks, containers, or Serve routes.
set -euo pipefail

WA_BASE="${WA_BASE:-/volume1/docker/wa-readonly-2}"
WA_SUBNET="${WA_SUBNET:-172.30.240.0/29}"
KIT="${KIT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
IMAGE="localhost/wa-readonly-private:t276"
SERVE_HOST="nas-2021.tailba1801.ts.net"
BOEKBE_USER="${BOEKBE_USER:-boekbe}"

abort() {
  printf 'abort: %s\n' "$1" >&2
  exit 1
}

find_exec() {
  local override="$1"
  shift
  if [ -n "$override" ]; then
    if [ -x "$override" ]; then
      printf '%s\n' "$override"
      return 0
    fi
    if command -v "$override" >/dev/null 2>&1; then
      command -v "$override"
      return 0
    fi
    return 1
  fi
  local candidate
  for candidate in "$@"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_tools() {
  DOCKER=$(find_exec "${DOCKER:-}" docker /usr/local/bin/docker /usr/bin/docker) || abort "docker is not available"
  TAILSCALE=$(find_exec "${TAILSCALE:-}" tailscale /var/packages/Tailscale/target/bin/tailscale /usr/local/bin/tailscale /usr/bin/tailscale) || abort "tailscale is not available"
  NETSTAT=$(find_exec "${NETSTAT:-}" netstat /usr/bin/netstat /bin/netstat) || abort "netstat is not available"
  if IP_BIN=$(find_exec "${IP_BIN:-}" ip /sbin/ip /usr/sbin/ip /bin/ip); then
    ROUTE_KIND=ip
  else
    ROUTE_KIND=netstat
    IP_BIN=""
  fi
  ID_BIN=$(find_exec "${ID_BIN:-}" id /usr/bin/id /bin/id) || abort "id is not available"
  export DOCKER TAILSCALE NETSTAT IP_BIN ROUTE_KIND ID_BIN
}

require_base_path() {
  case "$WA_BASE" in
    /volume1/docker/wa-readonly-2|/tmp/*) ;;
    *) abort "refusing unexpected base path" ;;
  esac
  case "$WA_BASE" in
    *"/webserver"*|*"whatsapp2-synthetic"*) abort "refusing the website or synthetic directory" ;;
  esac
}

run_check() {
  if [ "${PY_MODE:-host}" = "image" ]; then
    local args=() arg
    args+=("$1")
    shift
    for arg in "$@"; do
      case "$arg" in
        "$WORK"/*) args+=("/work/${arg#"$WORK"/}") ;;
        *) args+=("$arg") ;;
      esac
    done
    "$DOCKER" run --rm --network none --user 0 --entrypoint python3 \
      -v "$KIT:/kit:ro" -v "$WORK:/work:ro" "$IMAGE" \
      /kit/serve_check.py "${args[@]}"
  else
    "$PY_BIN" "$KIT/serve_check.py" "$@"
  fi
}

ensure_python() {
  if [ -n "${PY_BIN:-}" ] && "$PY_BIN" -c 'import json' >/dev/null 2>&1; then
    PY_MODE=host
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
    PY_BIN=$(command -v python3)
    PY_MODE=host
    return 0
  fi
  return 1
}

resolve_boekbe() {
  if ! BOEKBE_UID=$("$ID_BIN" -u "$BOEKBE_USER"); then
    abort "DSM account ${BOEKBE_USER} does not exist"
  fi
  if ! BOEKBE_GID=$("$ID_BIN" -g "$BOEKBE_USER"); then
    abort "DSM account ${BOEKBE_USER} has no primary group"
  fi
  case "$BOEKBE_UID" in
    ''|*[!0-9]*) abort "boekbe uid is not numeric" ;;
  esac
  case "$BOEKBE_GID" in
    ''|*[!0-9]*) abort "boekbe gid is not numeric" ;;
  esac
  export BOEKBE_UID BOEKBE_GID
}

capture_file() {
  local destination="$1"
  shift
  if ! "$@" >"$destination"; then
    abort "$* failed"
  fi
  if [ ! -s "$destination" ]; then
    abort "$* returned no output"
  fi
}

publish_qr() {
  local source="$1"
  local dest="$WA_BASE/pairing-qr.png"
  local mode
  resolve_tools
  resolve_boekbe
  [ -d "$WA_BASE/instance" ] || abort "instance directory is missing"
  [ -s "$source" ] || abort "pairing image is missing"
  mode=$(stat -c '%a' "$WA_BASE")
  [ "$mode" = "755" ] || abort "new directory is not mode 0755; existing permissions were not changed"
  mode=$(stat -c '%a %u' "$WA_BASE/instance")
  [ "$mode" = "700 65532" ] || abort "instance directory permissions were not changed"
  if [ -e "$WA_BASE/mcp-token" ]; then
    mode=$(stat -c '%a %u' "$WA_BASE/mcp-token")
    [ "$mode" = "600 65532" ] || abort "token permissions were not changed"
  fi
  install -m 0600 "$source" "$dest"
  chown "${BOEKBE_UID}:${BOEKBE_GID}" "$dest"
  chmod 0600 "$dest"
  mode=$(stat -c '%a %u %g' "$dest")
  [ "$mode" = "600 ${BOEKBE_UID} ${BOEKBE_GID}" ] || abort "qr copy is not owned by ${BOEKBE_USER} mode 0600"
  mode=$(stat -c '%a %u' "$WA_BASE/instance")
  [ "$mode" = "700 65532" ] || abort "instance directory changed while copying the qr"
  if [ -e "$WA_BASE/mcp-token" ]; then
    mode=$(stat -c '%a %u' "$WA_BASE/mcp-token")
    [ "$mode" = "600 65532" ] || abort "token permissions changed while copying the qr"
  fi
}

assert_names_free() {
  local names networks projects
  names="$WORK/containers.txt"
  networks="$WORK/networks.txt"
  projects="$WORK/projects.json"
  if ! "$DOCKER" ps -a --format '{{.Names}}' >"$names"; then
    abort "docker ps failed"
  fi
  if ! "$DOCKER" network ls --format '{{.Name}}' >"$networks"; then
    abort "docker network ls failed"
  fi
  if [ ! -s "$networks" ]; then
    abort "docker network ls returned no networks"
  fi
  if "$DOCKER" compose version >/dev/null 2>&1; then
    if ! "$DOCKER" compose ls --format json >"$projects"; then
      abort "docker compose ls failed"
    fi
  elif command -v docker-compose >/dev/null 2>&1; then
    abort "docker compose json listing is unavailable"
  else
    abort "docker compose is not available"
  fi
  if [ ! -s "$projects" ]; then
    printf '[]\n' >"$projects"
  fi
  run_check names "$names" wa-readonly-2 || abort "container name check failed"
  run_check names "$networks" wa_readonly_2 || abort "network name check failed"
  run_check projects "$projects" || abort "compose project check failed"
}

assert_ports_free() {
  if ! "$NETSTAT" -lnt >"$WORK/netstat.txt"; then
    abort "netstat -lnt failed"
  fi
  run_check ports "$WORK/netstat.txt" || abort "port check failed"
}

assert_subnet_free() {
  local ids id
  if ! ids=$("$DOCKER" network ls -q); then
    abort "docker network ls failed"
  fi
  if [ -z "$ids" ]; then
    abort "docker network ls returned no networks"
  fi
  # One inspect of every id. A failure of any id fails the command.
  if ! "$DOCKER" network inspect $ids >"$WORK/networks.json"; then
    abort "docker network inspect failed"
  fi
  if [ "$ROUTE_KIND" = "ip" ]; then
    if ! "$IP_BIN" -4 route show >"$WORK/routes.txt"; then
      abort "ip route failed"
    fi
  else
    if ! "$NETSTAT" -rn >"$WORK/routes.txt"; then
      abort "netstat -rn failed"
    fi
  fi
  if [ ! -s "$WORK/routes.txt" ]; then
    abort "route table is empty"
  fi
  run_check subnets "$WORK/networks.json" "$WORK/routes.txt" "$ROUTE_KIND" || abort "subnet check failed"
}

assert_serve_before() {
  if ! "$TAILSCALE" serve status --json >"$WORK/serve-before.json"; then
    abort "tailscale serve status failed"
  fi
  run_check serve-before "$WORK/serve-before.json" || abort "443 serve config is not the expected handler"
  cp -f "$WORK/serve-before.json" "$WORK/serve-snapshot.json"
}

assert_serve_after() {
  if ! "$TAILSCALE" serve status --json >"$WORK/serve-after.json"; then
    abort "tailscale serve status failed after adding 44443"
  fi
  if ! run_check serve-after "$WORK/serve-snapshot.json" "$WORK/serve-after.json"; then
    "$TAILSCALE" serve --https=44443 --set-path=/mcp off || abort "new serve route could not be removed"
    abort "serve config changed more than the new 44443 route; that route was removed"
  fi
}

preflight() {
  require_base_path
  resolve_tools
  resolve_boekbe
  if [ -e "$WA_BASE" ]; then
    abort "${WA_BASE} already exists"
  fi
  WORK=$(mktemp -d)
  if [ "${PY_MODE:-}" != "image" ]; then
    ensure_python || abort "python3 is not available"
  fi
  assert_names_free
  assert_ports_free
  assert_subnet_free
  assert_serve_before
  printf 'preflight accepted\n'
}

publish_qr() {
  local source="$1"
  local dest="$WA_BASE/pairing-qr.png"
  resolve_tools
  resolve_boekbe
  [ -d "$WA_BASE/instance" ] || abort "instance directory is missing"
  [ -s "$source" ] || abort "pairing image is missing"
  set -- $("$ID_BIN" -u "$BOEKBE_USER")
  local mode owner
  mode=$(stat -c '%a' "$WA_BASE")
  [ "$mode" = "755" ] || abort "new directory is not mode 0755; existing permissions were not changed"
  mode=$(stat -c '%a %u' "$WA_BASE/instance")
  [ "$mode" = "700 65532" ] || abort "instance directory permissions were not changed"
  if [ -e "$WA_BASE/mcp-token" ]; then
    mode=$(stat -c '%a %u' "$WA_BASE/mcp-token")
    [ "$mode" = "600 65532" ] || abort "token permissions were not changed"
  fi
  install -m 0600 "$source" "$dest"
  chown "${BOEKBE_UID}:${BOEKBE_GID}" "$dest"
  chmod 0600 "$dest"
  owner=$(stat -c '%a %u %g' "$dest")
  [ "$owner" = "600 ${BOEKBE_UID} ${BOEKBE_GID}" ] || abort "qr copy is not owned by boekbe mode 0600"
  mode=$(stat -c '%a %u' "$WA_BASE/instance")
  [ "$mode" = "700 65532" ] || abort "instance directory changed while copying the qr"
}
