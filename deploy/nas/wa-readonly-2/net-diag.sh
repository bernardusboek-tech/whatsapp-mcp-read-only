#!/bin/bash
# Read-only network class check inside the already running container.
# Host Python enforces the deadlines. No coreutils timeout is required.
# The diagnostic process is a separate session. A deadline SIGKILLs that
# session inside the container and does not signal the container's pid 1.
set -eu

name=wa-readonly-2
if ! command -v python3 >/dev/null 2>&1; then
  printf 'tool=python3_missing\n'
  exit 1
fi
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

exec python3 -u - "$docker_bin" "$@" << 'NETDIAG_SUPERVISOR'
import os
import re
import select
import signal
import subprocess
import sys
import time

NAME = "wa-readonly-2"
ALLOW = {
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
}
LINE_RE = re.compile(r"^[A-Za-z0-9_]+=[A-Za-z0-9._+-]{1,60}$")
PGID_RE = re.compile(r"^diag_pgid=([1-9][0-9]{0,8})$")

KILL_SCRIPT = """# wa-netdiag-kill
import os
import sys

pgid = int(sys.argv[1])
if pgid <= 1:
    sys.exit(3)
try:
    raw = open("/proc/%d/cmdline" % pgid, "rb").read()
    leader = open("/proc/%d/stat" % pgid, "r", encoding="ascii", errors="replace").read()
    init = open("/proc/1/stat", "r", encoding="ascii", errors="replace").read()
except OSError:
    sys.exit(4)
parts = [part for part in raw.split(bytes([0])) if part]
base = parts[0].rsplit(b"/", 1)[-1] if parts else b""
if base != b"python3" or parts[1:] != [b"-u", b"-"]:
    sys.exit(3)

def fields(text):
    rest = text[text.rfind(")") + 2 :].split()
    return int(rest[2]), int(rest[3])

pgrp, session = fields(leader)
_, init_session = fields(init)
if pgrp != pgid or session <= 0 or session == init_session:
    sys.exit(3)
os.killpg(pgid, 9)
"""

DIAG_TEMPLATE = r"""
import ctypes
import errno
import os
import re
import signal
import socket
import ssl
import time

HOST = "web.whatsapp.com"
PORT = 443
HANG = %%HANG%%
STUCK = %%STUCK%%
DNS_LIMIT = %%DNS_LIMIT%%
NET_LIMIT = %%NET_LIMIT%%
SOCKET_LIMIT = %%SOCKET_LIMIT%%
LISTEN_LIMIT = %%LISTEN_LIMIT%%
ALARM = %%ALARM%%
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
current = {"pid": 0}


def emit(key, value):
    if key not in KEYS:
        return
    cleaned = []
    for char in str(value):
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


def session_fields(pid):
    raw = open("/proc/%d/stat" % pid, "r", encoding="ascii", errors="replace").read()
    rest = raw[raw.rfind(")") + 2 :].split()
    return int(rest[2]), int(rest[3])


def isolate():
    try:
        os.setsid()
    except OSError:
        pass
    pid = os.getpid()
    if os.getpgid(0) != pid or pid <= 1:
        os._exit(2)
    try:
        pgrp, session = session_fields(pid)
        _, init_session = session_fields(1)
    except (OSError, IndexError, ValueError):
        os._exit(2)
    if pgrp != pid or session <= 0 or session == init_session:
        os._exit(2)
    return pid


def on_alarm(signum, frame):
    pid = current["pid"]
    if pid > 1:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    os._exit(124)


def arm_parent_death():
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    if libc.prctl(1, signal.SIGKILL) != 0:
        os._exit(1)
    if os.getppid() <= 1:
        os._exit(1)


def run_child(limit, fn):
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        arm_parent_death()
        try:
            text = fn()
        except Exception as exc:
            text = "err:" + error_class(exc)
        if not isinstance(text, str):
            text = "err:bad_result"
        try:
            os.write(write_fd, (text[:80] + "\n").encode("ascii", "replace"))
        except OSError:
            pass
        os.close(write_fd)
        os._exit(0)
    os.close(write_fd)
    current["pid"] = pid
    os.set_blocking(read_fd, False)
    deadline = time.monotonic() + limit
    status = None
    while time.monotonic() < deadline:
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            break
        time.sleep(0.05)
    else:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        current["pid"] = 0
        os.close(read_fd)
        return "timeout"
    current["pid"] = 0
    data = b""
    while len(data) < 120:
        try:
            chunk = os.read(read_fd, 120)
        except BlockingIOError:
            break
        if not chunk:
            break
        data += chunk
    os.close(read_fd)
    if status is not None and os.WIFEXITED(status) and os.WEXITSTATUS(status) != 0 and not data.strip():
        return "err:isolate_failed"
    return data.decode("ascii", "replace").strip()[:80]


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
        if len(fields) < 2 or fields[1] != "00000000":
            continue
        iface = fields[0]
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


def class_token(text):
    if re.fullmatch(r"[A-Za-z0-9_]{1,40}", text or ""):
        return text
    return "bad_result"


def do_dns():
    if HANG:
        try:
            handle = open("/tmp/wa-netdiag-hang", "w", encoding="ascii")
            handle.write("1")
            handle.close()
        except OSError:
            pass
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(30)
    infos = socket.getaddrinfo(HOST, PORT, type=socket.SOCK_STREAM)
    for info in infos:
        address = info[4][0]
        if info[0] == socket.AF_INET:
            try:
                socket.inet_pton(socket.AF_INET, address)
            except OSError:
                continue
            return "ipv4:" + address
        if info[0] == socket.AF_INET6:
            try:
                socket.inet_pton(socket.AF_INET6, address)
            except OSError:
                continue
            return "ipv6:" + address
    return "err:no_address"


def do_net(kind, address):
    family = socket.AF_INET if kind == "ipv4" else socket.AF_INET6
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.settimeout(SOCKET_LIMIT)
    try:
        sock.connect((address, PORT))
    except Exception as exc:
        return "tcp_err:" + error_class(exc)
    try:
        tls = ssl.create_default_context().wrap_socket(sock, server_hostname=HOST)
        version = tls.version() or "none"
        tls.close()
    except Exception as exc:
        return "tcp_ok tls_err:" + error_class(exc)
    finally:
        try:
            sock.close()
        except OSError:
            pass
    if version not in ("TLSv1.2", "TLSv1.3"):
        version = "other"
    return "tcp_ok tls_ok " + version


def do_listen():
    probe = socket.socket()
    probe.settimeout(1)
    try:
        probe.connect(("127.0.0.1", 12789))
        return "ok"
    except Exception as exc:
        return "err:" + error_class(exc)
    finally:
        probe.close()


def take_ip(result):
    if result.startswith("ipv4:"):
        address = result[5:]
        try:
            socket.inet_pton(socket.AF_INET, address)
        except OSError:
            return None, None
        return "ipv4", address
    if result.startswith("ipv6:"):
        address = result[5:]
        try:
            socket.inet_pton(socket.AF_INET6, address)
        except OSError:
            return None, None
        return "ipv6", address
    return None, None


pgid = isolate()
print("diag_pgid=%d" % pgid, flush=True)
signal.signal(signal.SIGALRM, on_alarm)
signal.alarm(ALARM)
if STUCK:
    try:
        handle = open("/tmp/wa-netdiag-stuck", "w", encoding="ascii")
        handle.write(str(os.getpid()))
        handle.close()
    except OSError:
        pass
    signal.signal(signal.SIGALRM, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    time.sleep(30)

emit("WA_PAIR", pair_class(os.environ.get("WA_PAIR", "")))
emit("bridge_process", "yes" if proc_has(b"whatsapp-bridge") else "no")
emit("http_process", "yes" if proc_has(b"whatsapp-mcp-server/main.py") else "no")
route, iface = default_route()
emit("default_route", route)
emit("route_iface", iface)
count, literal = resolvers()
emit("resolver_count", count)
emit("resolver_literal", literal)

dns_result = run_child(DNS_LIMIT, do_dns)
kind = None
address = None
if dns_result == "timeout":
    emit("dns", "timeout")
    emit("dns_error", "deadline")
elif dns_result.startswith("err:"):
    emit("dns", "fail")
    emit("dns_error", class_token(dns_result[4:]))
else:
    kind, address = take_ip(dns_result)
    if kind is None:
        emit("dns", "fail")
        emit("dns_error", "bad_result")
    else:
        emit("dns", "ok")

if kind is None:
    emit("tcp443", "skip")
    emit("tls", "skip")
else:
    net_result = run_child(NET_LIMIT, lambda: do_net(kind, address))
    if net_result == "timeout":
        emit("tcp443", "timeout")
        emit("tcp_error", "deadline")
        emit("tls", "skip")
    elif net_result.startswith("tcp_err:"):
        emit("tcp443", "fail")
        emit("tcp_error", class_token(net_result[8:]))
        emit("tls", "skip")
    elif net_result.startswith("tcp_ok tls_err:"):
        emit("tcp443", "ok")
        emit("tls", "fail")
        emit("tls_error", class_token(net_result[15:]))
    elif net_result.startswith("tcp_ok tls_ok "):
        version = net_result[14:]
        if version not in ("TLSv1.2", "TLSv1.3", "other"):
            version = "other"
        emit("tcp443", "ok")
        emit("tls", "ok")
        emit("tls_version", version)
    else:
        emit("tcp443", "fail")
        emit("tcp_error", "bad_result")
        emit("tls", "skip")

listen_result = run_child(LISTEN_LIMIT, do_listen)
if listen_result == "timeout":
    emit("local_listener", "deadline")
elif listen_result == "ok":
    emit("local_listener", "ok")
elif listen_result.startswith("err:"):
    emit("local_listener", class_token(listen_result[4:]))
else:
    emit("local_listener", "bad_result")
"""


def positive(name, default, cap):
    raw = os.environ.get(name, "")
    if not raw or not raw.isdigit():
        return default
    value = int(raw)
    if value < 1:
        return default
    return min(value, cap)


def kill_group(proc):
    if proc.pid <= 1 or proc.pid == os.getpid():
        return
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except OSError:
            pass
        proc.wait(timeout=2)


def allowed(line):
    if not LINE_RE.fullmatch(line):
        return False
    key = line.split("=", 1)[0]
    return key in ALLOW


def launch(args, script, deadline, capture_pgid):
    proc = subprocess.Popen(
        args,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    proc.stdin.write(script.encode("utf-8"))
    proc.stdin.close()
    fd = proc.stdout.fileno()
    os.set_blocking(fd, False)
    buf = b""
    lines = []
    pgid = None
    end = time.monotonic() + deadline
    overflow = False
    while time.monotonic() < end:
        if proc.poll() is not None:
            break
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 1024)
        except BlockingIOError:
            continue
        if chunk == b"":
            break
        buf += chunk
        if len(buf) > 4096:
            overflow = True
            break
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            text = raw.decode("ascii", "replace").strip()
            matched = PGID_RE.fullmatch(text) if capture_pgid and pgid is None else None
            if matched:
                pgid = int(matched.group(1))
            elif allowed(text) and len(lines) < 24:
                lines.append(text)
    else:
        kill_group(proc)
        return "timeout", proc.returncode, lines, pgid
    if overflow or proc.poll() is None:
        kill_group(proc)
        return "timeout", proc.returncode, lines, pgid
    while len(buf) <= 4096:
        try:
            chunk = os.read(fd, 1024)
        except BlockingIOError:
            break
        if not chunk:
            break
        buf += chunk
    if buf.strip():
        text = buf.decode("ascii", "replace").strip()
        matched = PGID_RE.fullmatch(text) if capture_pgid and pgid is None else None
        if matched:
            pgid = int(matched.group(1))
        elif allowed(text) and len(lines) < 24:
            lines.append(text)
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        kill_group(proc)
        return "timeout", proc.returncode, lines, pgid
    return "ok", proc.returncode, lines, pgid


def emit_result(lines, status, child):
    for line in lines:
        print(line, flush=True)
    print("diag=" + status, flush=True)
    if child:
        print("container_child=" + child, flush=True)


def container_kill(docker, pgid, deadline):
    if pgid is None or pgid <= 1:
        return "unidentified"
    args = [
        docker,
        "exec",
        "-i",
        "--user",
        "65532:65532",
        NAME,
        "python3",
        "-u",
        "-",
        str(pgid),
    ]
    kind, code, _, _ = launch(args, KILL_SCRIPT, deadline, False)
    if kind == "timeout":
        return "kill_unconfirmed"
    if code == 0:
        return "killed"
    if code == 4:
        return "absent"
    if code == 3:
        return "kill_refused"
    return "kill_unconfirmed"


def diag_source():
    hang = "True" if "--self-test-hang" in sys.argv[2:] else "False"
    stuck = "True" if "--self-test-stuck" in sys.argv[2:] else "False"
    dns_limit = positive("NETDIAG_DNS_SECONDS", 3, 8)
    net_limit = positive("NETDIAG_NET_SECONDS", 6, 12)
    listen_limit = positive("NETDIAG_LISTEN_SECONDS", 2, 5)
    exec_limit = positive("NETDIAG_EXEC_SECONDS", 15, 20)
    socket_limit = 1 if net_limit <= 2 else min(3, net_limit - 1)
    alarm = max(1, exec_limit - 1)
    script = DIAG_TEMPLATE
    script = script.replace("%%HANG%%", hang)
    script = script.replace("%%STUCK%%", stuck)
    script = script.replace("%%DNS_LIMIT%%", str(dns_limit))
    script = script.replace("%%NET_LIMIT%%", str(net_limit))
    script = script.replace("%%SOCKET_LIMIT%%", str(socket_limit))
    script = script.replace("%%LISTEN_LIMIT%%", str(listen_limit))
    script = script.replace("%%ALARM%%", str(alarm))
    if "%%" in script:
        return None
    return script


def capture_plain(args, deadline):
    proc = subprocess.Popen(
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    fd = proc.stdout.fileno()
    os.set_blocking(fd, False)
    data = b""
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        if proc.poll() is not None:
            break
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 64)
        except BlockingIOError:
            continue
        if not chunk:
            break
        data += chunk
        if len(data) > 32:
            kill_group(proc)
            return "timeout", ""
    else:
        kill_group(proc)
        return "timeout", ""
    if proc.poll() is None:
        kill_group(proc)
        return "timeout", ""
    while len(data) <= 32:
        try:
            chunk = os.read(fd, 64)
        except BlockingIOError:
            break
        if not chunk:
            break
        data += chunk
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        kill_group(proc)
        return "timeout", ""
    if proc.returncode != 0:
        return "failed", ""
    text = data.decode("ascii", "replace").strip()
    if not re.fullmatch(r"[A-Za-z0-9_]{1,16}", text):
        return "failed", ""
    return "ok", text


def main2():
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        print("usage=invalid", flush=True)
        return 2
    mode = sys.argv[2] if len(sys.argv) == 3 else ""
    if mode not in ("", "--self-test-hang", "--self-test-stuck"):
        print("usage=invalid", flush=True)
        return 2
    docker = sys.argv[1]
    started = time.monotonic()
    overall = positive("NETDIAG_OVERALL_SECONDS", 26, 30)
    inspect_limit = positive("NETDIAG_INSPECT_SECONDS", 5, 10)
    exec_limit = positive("NETDIAG_EXEC_SECONDS", 15, 20)
    kill_limit = positive("NETDIAG_KILL_SECONDS", 3, 5)

    def clip(seconds):
        left = overall - (time.monotonic() - started)
        if left < 1:
            return 0
        return max(1, min(seconds, int(left)))

    budget = clip(inspect_limit)
    if budget == 0:
        print("container=inspect_timeout", flush=True)
        return 124
    kind, running = capture_plain(
        [docker, "inspect", "-f", "{{.State.Running}}", NAME],
        budget,
    )
    if kind == "timeout":
        print("container=inspect_timeout", flush=True)
        return 124
    if kind != "ok":
        print("container=inspect_failed", flush=True)
        return 1
    if running != "true":
        print("container=not_running", flush=True)
        return 1

    script = diag_source()
    if script is None:
        print("diag=failed", flush=True)
        return 1
    budget = clip(exec_limit)
    if budget == 0:
        print("diag=timeout", flush=True)
        print("container_child=unidentified", flush=True)
        return 124
    args = [
        docker,
        "exec",
        "-i",
        "--user",
        "65532:65532",
        NAME,
        "python3",
        "-u",
        "-",
    ]
    kind, code, lines, pgid = launch(args, script, budget, True)
    if kind == "timeout" or code == 124:
        child_budget = clip(kill_limit)
        child = container_kill(docker, pgid, child_budget) if child_budget else "kill_unconfirmed"
        emit_result(lines, "timeout", child)
        return 124
    if code == 2:
        emit_result(lines, "isolate_failed", "")
        return 2
    if code != 0:
        child_budget = clip(kill_limit)
        child = container_kill(docker, pgid, child_budget) if child_budget and pgid else ""
        emit_result(lines, "failed", child)
        return 1
    emit_result(lines, "ok", "exited")
    return 0


sys.exit(main2())
NETDIAG_SUPERVISOR
