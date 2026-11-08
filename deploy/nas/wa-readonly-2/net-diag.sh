#!/bin/bash
# Read-only network class check inside the already running container.
# It does not recreate the container, change Serve, or read the instance directory.
set -eu

name=wa-readonly-2
if [ -n "${DOCKER:-}" ] && [ -x "${DOCKER:-}" ]; then
  docker_bin=$DOCKER
elif [ -x /usr/local/bin/docker ]; then
  docker_bin=/usr/local/bin/docker
elif command -v docker >/dev/null 2>&1; then
  docker_bin=$(command -v docker)
else
  printf 'tool=docker_missing\n'
  exit 1
fi

if ! running=$("$docker_bin" inspect -f '{{.State.Running}}' "$name"); then
  printf 'container=inspect_failed\n'
  exit 1
fi
if [ "$running" != "true" ]; then
  printf 'container=not_running\n'
  exit 1
fi

"$docker_bin" exec -i --user 65532:65532 "$name" python3 - << 'PY'
import errno
import os
import socket
import ssl

HOST = "web.whatsapp.com"
PORT = 443
KEYS = (
    "WA_PAIR",
    "bridge_process",
    "http_process",
    "default_route",
    "route_iface",
    "resolver_count",
    "resolver_literal",
    "dns",
    "dns_error",
    "tcp443",
    "tcp_error",
    "tls",
    "tls_error",
    "tls_version",
    "local_listener",
)


def emit(key, value):
    if key not in KEYS:
        return
    text = str(value)
    cleaned = []
    for char in text:
        if char.isalnum() or char in "._+-":
            cleaned.append(char)
        else:
            cleaned.append("?")
    print(key + "=" + "".join(cleaned)[:60], flush=True)


def pair_class(value):
    if value == "0":
        return "0"
    if value == "1":
        return "1"
    if value == "":
        return "unset"
    return "other"


def error_class(exc):
    name = type(exc).__name__
    number = getattr(exc, "errno", None)
    if isinstance(number, int) and number in errno.errorcode:
        return name + "_" + errno.errorcode[number]
    return name


def proc_has(fragment):
    try:
        pids = os.listdir("/proc")
    except OSError:
        return False
    for pid in pids:
        if not pid.isdigit():
            continue
        try:
            raw = open("/proc/" + pid + "/cmdline", "rb").read()
        except OSError:
            continue
        if fragment in raw:
            return True
    return False


def default_route():
    try:
        lines = open("/proc/net/route", "r", encoding="utf-8").read().splitlines()
    except OSError:
        return "unknown", "unknown"
    for line in lines[1:]:
        fields = line.split()
        if len(fields) < 2:
            continue
        iface, destination = fields[0], fields[1]
        if destination != "00000000":
            continue
        if iface and all(char.isalnum() or char in "._-" for char in iface):
            return "yes", iface
        return "yes", "unparsed"
    return "no", "none"


def resolvers():
    count = 0
    literal = "yes"
    try:
        lines = open("/etc/resolv.conf", "r", encoding="utf-8").read().splitlines()
    except OSError:
        return "0", "no"
    for line in lines:
        parts = line.split()
        if len(parts) < 2 or parts[0] != "nameserver":
            continue
        count += 1
        server = parts[1]
        octets = server.split(".")
        ipv4 = len(octets) == 4 and all(part.isdigit() and 0 <= int(part) <= 255 for part in octets)
        ipv6 = ":" in server and all(char in "0123456789abcdefABCDEF:" for char in server)
        if not ipv4 and not ipv6:
            literal = "no"
    return str(count), literal


emit("WA_PAIR", pair_class(os.environ.get("WA_PAIR", "")))
emit("bridge_process", "yes" if proc_has(b"whatsapp-bridge") else "no")
emit("http_process", "yes" if proc_has(b"whatsapp-mcp-server/main.py") else "no")
route, iface = default_route()
emit("default_route", route)
emit("route_iface", iface)
count, literal = resolvers()
emit("resolver_count", count)
emit("resolver_literal", literal)

socket.setdefaulttimeout(5)
infos = []
try:
    infos = socket.getaddrinfo(HOST, PORT, type=socket.SOCK_STREAM)
    emit("dns", "ok")
except Exception as exc:
    emit("dns", "fail")
    emit("dns_error", error_class(exc))

if not infos:
    emit("tcp443", "skip")
    emit("tls", "skip")
else:
    sock = socket.socket(infos[0][0], infos[0][1], infos[0][2])
    sock.settimeout(5)
    try:
        sock.connect(infos[0][4])
        emit("tcp443", "ok")
        try:
            tls = ssl.create_default_context().wrap_socket(sock, server_hostname=HOST)
            version = tls.version() or "none"
            if version not in ("TLSv1.2", "TLSv1.3"):
                version = "other"
            emit("tls", "ok")
            emit("tls_version", version)
            tls.close()
        except Exception as exc:
            emit("tls", "fail")
            emit("tls_error", error_class(exc))
    except Exception as exc:
        emit("tcp443", "fail")
        emit("tcp_error", error_class(exc))
        emit("tls", "skip")
    finally:
        try:
            sock.close()
        except OSError:
            pass

probe = socket.socket()
probe.settimeout(2)
try:
    probe.connect(("127.0.0.1", 12789))
    emit("local_listener", "ok")
except Exception as exc:
    emit("local_listener", error_class(exc))
finally:
    probe.close()
PY
