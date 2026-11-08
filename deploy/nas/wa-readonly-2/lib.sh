#!/bin/bash
# Shared checks for the new read-only instance. No existing service is changed here.
set -euo pipefail

WA_BASE="${WA_BASE:-/volume1/docker/wa-readonly-2}"
WA_SUBNET="${WA_SUBNET:-172.30.240.0/29}"
DOCKER="${DOCKER:-docker}"
TAILSCALE="${TAILSCALE:-tailscale}"
KIT="${KIT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"

abort() {
  printf 'abort: %s\n' "$1" >&2
  exit 1
}

require_base_path() {
  case "$WA_BASE" in
    /volume1/docker/wa-readonly-2|/tmp/*)
      ;;
    *)
      abort "refusing unexpected base path"
      ;;
  esac
  case "$WA_BASE" in
    *"/webserver"*|*"whatsapp2-synthetic"*)
      abort "refusing the website or synthetic directory"
      ;;
  esac
}

cidrs_overlap() {
  # Exit 0 when the ranges overlap, 1 when they do not, 2 when a CIDR is invalid.
  awk -v left="$1" -v right="$2" 'BEGIN {
    if (end_of(left) < 0 || end_of(right) < 0) exit 2
    if (end_of(left) < start_of(right) || end_of(right) < start_of(left)) exit 1
    exit 0
  }
  function num(ip, p) {
    split(ip, p, ".")
    if (p[1] == "" || p[4] == "") return -1
    return p[1] * 16777216 + p[2] * 65536 + p[3] * 256 + p[4]
  }
  function bits_of(cidr, p) {
    split(cidr, p, "/")
    return p[2] + 0
  }
  function start_of(cidr, ip, bits, size) {
    ip = num(substr(cidr, 1, index(cidr, "/") - 1))
    bits = bits_of(cidr)
    if (ip < 0 || bits < 0 || bits > 32) return -1
    size = 2 ^ (32 - bits)
    return int(ip / size) * size
  }
  function end_of(cidr, start, size) {
    start = start_of(cidr)
    if (start < 0) return -1
    size = 2 ^ (32 - bits_of(cidr))
    return start + size - 1
  }'
}

collect_subnets() {
  "$DOCKER" network ls -q | while read -r id; do
    [ -n "$id" ] || continue
    "$DOCKER" network inspect "$id"
  done | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' || true
  if [ -n "${IP_BIN:-}" ]; then
    "$IP_BIN" -4 route show 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || true
  elif command -v ip >/dev/null 2>&1; then
    ip -4 route show 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -rn 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+\./ && $3 ~ /^[0-9]+\./ {
      split($3, m, ".")
      bits = 0
      for (i = 1; i <= 4; i++) {
        v = m[i] + 0
        while (v > 0) { bits += v % 2; v = int(v / 2) }
      }
      print $1 "/" bits
    }' || true
  fi
}

assert_subnet_free() {
  local cidr
  while read -r cidr; do
    [ -n "$cidr" ] || continue
    set +e
    cidrs_overlap "$WA_SUBNET" "$cidr"
    overlap=$?
    set -e
    if [ "$overlap" -eq 0 ]; then
      abort "subnet ${WA_SUBNET} overlaps ${cidr}"
    fi
    if [ "$overlap" -ne 1 ]; then
      abort "could not compare ${cidr}"
    fi
  done < <(collect_subnets | sort -u)
}

assert_ports_free() {
  local listing
  listing=$(netstat -ln 2>/dev/null || netstat -an 2>/dev/null || true)
  if printf '%s\n' "$listing" | grep -E '[:.]12789([^0-9]|$)|[:.]44443([^0-9]|$)' >/dev/null; then
    abort "12789 or 44443 is already listening"
  fi
}

assert_serve_untouched() {
  local status
  status=$("$TAILSCALE" serve status --json)
  printf '%s' "$status" | grep -q '127\.0\.0\.1:8088' || abort "443 proxy is not the existing 127.0.0.1:8088 handler"
  printf '%s' "$status" | grep -q 'nas-2021\.tailba1801\.ts\.net:443' || abort "443 serve name is not the existing tailnet name"
  if printf '%s' "$status" | grep -q '44443'; then
    abort "44443 is already present in serve status"
  fi
}

preflight() {
  require_base_path
  if [ -e "$WA_BASE" ]; then
    abort "${WA_BASE} already exists"
  fi
  assert_subnet_free
  assert_ports_free
  assert_serve_untouched
  printf 'preflight accepted\n'
}
