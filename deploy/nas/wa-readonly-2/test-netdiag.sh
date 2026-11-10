#!/bin/bash
# Two bounds: a Docker client that never reads a payload larger than the pipe,
# and a kill that accepts only this invocation's marker and start time.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
diag=$root/net-diag.sh
work=$(mktemp -d)
cleanup() {
  if [ -f "$work/pids" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill -9 "$pid" >/dev/null 2>&1 || true
    done < "$work/pids"
  fi
  rm -rf "$work"
}
trap cleanup EXIT

python3 - "$diag" << 'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('DIAG_TEMPLATE = r"""') + len('DIAG_TEMPLATE = r"""')
end = text.index('\n"""', start)
body = text[start:end]
print("payload_bytes=%d" % len(body.encode("utf-8")))
if len(body.encode("utf-8")) <= 4096:
    raise SystemExit("diagnostic payload fits in one pipe page")
PY

python3 - << 'PY'
import fcntl
import os
import signal

read_fd, write_fd = os.pipe()
fcntl.fcntl(write_fd, fcntl.F_SETPIPE_SZ, 4096)
pid = os.fork()
if pid == 0:
    signal.signal(signal.SIGALRM, lambda *_args: os._exit(0))
    signal.alarm(1)
    payload = b"x" * 8192
    sent = 0
    try:
        while sent < len(payload):
            sent += os.write(write_fd, payload[sent:])
    except InterruptedError:
        os._exit(0)
    os._exit(1)
os.close(write_fd)
_wpid, status = os.waitpid(pid, 0)
os.close(read_fd)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    raise SystemExit("blocking write of a full pipe returned")
print("blocking_write_blocked=yes")
PY

cat > "$work/stub" << 'EOF'
#!/usr/bin/env python3
import fcntl
import os
import subprocess
import sys
import time

mode = os.environ["STUB_MODE"]
state = os.environ["STUB_DIR"]


def stat_start(pid):
    raw = open("/proc/%d/stat" % pid, encoding="ascii", errors="replace").read()
    rest = raw[raw.rfind(")") + 2 :].split()
    return int(rest[19])


def spawn(argv_tail):
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.dup2(read_fd, 0)
        os.close(write_fd)
        os.execv(sys.executable, [sys.executable] + argv_tail)
    os.close(read_fd)
    os.write(write_fd, b"import time\nwhile True:\n    time.sleep(1)\n")
    os.close(write_fd)
    return pid


def alive(pid):
    return os.path.exists("/proc/%d" % pid)


if len(sys.argv) < 2:
    sys.exit(2)
if sys.argv[1] == "inspect":
    sys.stdout.write("true\n")
    sys.stdout.flush()
    sys.exit(0)
if sys.argv[1] != "exec":
    sys.exit(2)

if mode == "noread":
    size = 0
    deadline = time.time() + 0.5
    while time.time() < deadline:
        size = fcntl.fcntl(0, fcntl.F_GETPIPE_SZ)
        if size <= 4096:
            break
        time.sleep(0.01)
    handle = open(os.path.join(state, "pipe"), "w", encoding="ascii")
    handle.write(str(size))
    handle.close()
    time.sleep(30)
    sys.exit(0)

data = sys.stdin.buffer.read()
if b"wa-netdiag-kill" in data:
    record = {}
    for name in ("real", "decoy", "generic", "http"):
        record[name] = open(os.path.join(state, name), encoding="ascii").read().strip()
    marker = open(os.path.join(state, "marker"), encoding="ascii").read().strip()
    real_pid, real_start = record["real"].split()
    decoy_pid, decoy_start = record["decoy"].split()
    generic_pid, generic_start = record["generic"].split()
    http_pid, http_start = record["http"].split()
    host_pgid, host_start, host_marker = sys.argv[-3], sys.argv[-2], sys.argv[-1]
    log = open(os.path.join(state, "kill-log"), "w", encoding="ascii")

    def attempt(pid, start, mark):
        proc = subprocess.run(
            [sys.executable, "-u", "-", str(pid), str(start), mark],
            input=data,
        )
        return proc.returncode

    checks = (
        ("decoy", decoy_pid, decoy_start, marker),
        ("generic", generic_pid, generic_start, marker),
        ("http", http_pid, http_start, marker),
        ("wrong_start", real_pid, str(int(real_start) + 1), marker),
    )
    for label, pid, start, mark in checks:
        code = attempt(pid, start, mark)
        log.write("%s=%s alive=%s\n" % (label, code, "yes" if alive(int(pid)) else "no"))
        if code == 0 or not alive(int(pid)):
            log.write("unexpected_kill=%s\n" % label)
            log.close()
            sys.exit(9)
    if host_pgid != real_pid or host_start != real_start or host_marker != marker:
        log.write("host_target_mismatch=yes\n")
        log.close()
        sys.exit(9)
    code = attempt(host_pgid, host_start, host_marker)
    log.write("real=%s alive=%s\n" % (code, "yes" if alive(int(real_pid)) else "no"))
    log.close()
    sys.exit(code)

marker = sys.argv[-1]
real = spawn(["-u", "-", marker])
decoy = spawn(["-u", "-", "0123456789abcdef"])
generic = spawn(["-u", "-"])
http = spawn(["-c", "import time\nwhile True:\n    time.sleep(1)\n"])
for pid in (real, decoy, generic, http):
    handle = open(os.path.join(state, "pids"), "a", encoding="ascii")
    handle.write("%d\n" % pid)
    handle.close()
open(os.path.join(state, "marker"), "w", encoding="ascii").write(marker)
open(os.path.join(state, "real"), "w", encoding="ascii").write("%d %d\n" % (real, stat_start(real)))
open(os.path.join(state, "decoy"), "w", encoding="ascii").write("%d %d\n" % (decoy, stat_start(decoy)))
open(os.path.join(state, "generic"), "w", encoding="ascii").write("%d %d\n" % (generic, stat_start(generic)))
open(os.path.join(state, "http"), "w", encoding="ascii").write("%d %d\n" % (http, stat_start(http)))
sys.stdout.write("diag_pgid=%d\n" % real)
sys.stdout.write("diag_start=%d\n" % stat_start(real))
sys.stdout.flush()
time.sleep(30)
EOF
chmod +x "$work/stub"

run_bounded() {
  local limit=$1
  shift
  python3 - "$limit" "$diag" "$@" << 'PY'
import os
import subprocess
import sys
import time

limit = float(sys.argv[1])
diag = sys.argv[2]
env = os.environ.copy()
env.update(
    {
        "DOCKER": sys.argv[3],
        "STUB_MODE": sys.argv[4],
        "STUB_DIR": sys.argv[5],
        "NETDIAG_INSPECT_SECONDS": sys.argv[6],
        "NETDIAG_EXEC_SECONDS": sys.argv[7],
        "NETDIAG_KILL_SECONDS": sys.argv[8],
        "NETDIAG_OVERALL_SECONDS": sys.argv[9],
        "PYTHONUNBUFFERED": "1",
    }
)
out_path = sys.argv[10]
started = time.monotonic()
proc = subprocess.Popen(
    ["bash", diag],
    stdout=open(out_path, "w", encoding="ascii"),
    stderr=subprocess.DEVNULL,
    env=env,
    start_new_session=True,
)
code = 99
while time.monotonic() - started < limit:
    if proc.poll() is not None:
        code = proc.returncode
        break
    time.sleep(0.05)
else:
    os.killpg(proc.pid, 9)
    proc.wait(timeout=2)
    print("elapsed=hung")
    raise SystemExit(1)
print("elapsed=%.3f" % (time.monotonic() - started))
print("exit=%d" % code)
raise SystemExit(0 if code == 124 else 1)
PY
}

echo "=== stdin deadline ==="
mkdir -p "$work/noread"
run_bounded 5 "$work/stub" noread "$work/noread" 1 1 1 4 "$work/noread.out"
echo "pipe=$(cat "$work/noread/pipe")"
cat "$work/noread.out"
test "$(cat "$work/noread/pipe")" = "4096"
grep -qx 'diag=timeout' "$work/noread.out"

echo "=== invocation identity ==="
mkdir -p "$work/id"
run_bounded 12 "$work/stub" identity "$work/id" 1 2 4 10 "$work/id.out"
echo "kill_log:"
cat "$work/id/kill-log"
echo "output:"
cat "$work/id.out"
grep -qx 'decoy=3 alive=yes' "$work/id/kill-log"
grep -qx 'generic=3 alive=yes' "$work/id/kill-log"
grep -qx 'http=3 alive=yes' "$work/id/kill-log"
grep -qx 'wrong_start=3 alive=yes' "$work/id/kill-log"
grep -qx 'real=0 alive=no' "$work/id/kill-log"
grep -qx 'diag=timeout' "$work/id.out"
grep -qx 'container_child=killed' "$work/id.out"
marker=$(cat "$work/id/marker")
if grep -q "$marker" "$work/id.out" || grep -q 'diag_pgid=' "$work/id.out" || grep -q 'diag_start=' "$work/id.out"; then
  echo "identity leaked into the report" >&2
  exit 1
fi
real=$(awk '{print $1}' "$work/id/real")
decoy=$(awk '{print $1}' "$work/id/decoy")
generic=$(awk '{print $1}' "$work/id/generic")
http=$(awk '{print $1}' "$work/id/http")
if [ -d "/proc/$real" ]; then
  echo "matching diagnostic child still running" >&2
  exit 1
fi
for pid in "$decoy" "$generic" "$http"; do
  if [ ! -d "/proc/$pid" ]; then
    echo "unrelated process $pid was killed" >&2
    exit 1
  fi
done
echo "marker_in_output=no unrelated_alive=yes matching_child=dead"
echo "PASS"
