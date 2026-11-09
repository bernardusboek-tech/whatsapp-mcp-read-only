#!/bin/bash
# Proves the diagnostic's own deadlines. A planted environment value must not appear.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
diag=$root/net-diag.sh
work=$(mktemp -d)
cleanup() {
  podman kill wa-readonly-2 >/dev/null 2>&1 || true
  podman rm -f wa-readonly-2 >/dev/null 2>&1 || true
  podman unshare rm -rf "$work" >/dev/null 2>&1 || rm -rf "$work" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$work/bin"
cat > "$work/bin/timeout" << 'EOF'
#!/bin/sh
printf 'TIMEOUT_CALLED\n' >> "${TIMEOUT_TRAP_LOG:?}"
exit 99
EOF
chmod +x "$work/bin/timeout"
export TIMEOUT_TRAP_LOG=$work/timeout-trap
export PATH="$work/bin:$PATH"
: > "$TIMEOUT_TRAP_LOG"

cat > "$work/stub-docker" << 'EOF'
#!/usr/bin/env python3
import os
import subprocess
import sys
import time

log = os.environ["STUB_LOG"]
orphan_path = os.environ["STUB_ORPHAN"]
mode = os.environ.get("STUB_MODE", "orphan")


def note(text):
    handle = open(log, "a", encoding="ascii")
    handle.write(text + "\n")
    handle.close()


if len(sys.argv) < 2:
    sys.exit(2)
if sys.argv[1] == "inspect":
    note("inspect")
    if mode == "inspect-hang":
        time.sleep(30)
    sys.stdout.write("true\n")
    sys.stdout.flush()
    sys.exit(0)
if sys.argv[1] != "exec":
    note("unexpected")
    sys.exit(2)
data = sys.stdin.buffer.read()
if b"wa-netdiag-kill" in data:
    pgid = sys.argv[-1]
    alive = os.path.exists("/proc/" + pgid)
    note("kill alive=%s" % ("yes" if alive else "no"))
    proc = subprocess.run([sys.executable, "-u", "-", pgid], input=data)
    sys.exit(proc.returncode)
note("diag")
read_fd, write_fd = os.pipe()
pid = os.fork()
if pid == 0:
    os.setsid()
    os.close(write_fd)
    os.dup2(read_fd, 0)
    os.execv(sys.executable, [sys.executable, "-u", "-"])
os.close(read_fd)
os.write(write_fd, b"import time\nwhile True:\n    time.sleep(0.5)\n")
os.close(write_fd)
for _ in range(50):
    try:
        raw = open("/proc/%d/cmdline" % pid, "rb").read()
    except OSError:
        raw = b""
    if b"-u" in raw:
        break
    time.sleep(0.05)
handle = open(orphan_path, "w", encoding="ascii")
handle.write(str(pid))
handle.close()
sys.stdout.write("diag_pgid=%d\n" % pid)
sys.stdout.flush()
time.sleep(30)
EOF
chmod +x "$work/stub-docker"

seconds() {
  python3 -c 'import time; print("%.3f" % time.time())'
}

echo "=== inspect deadline ==="
start=$(seconds)
set +e
STUB_LOG=$work/inspect.log STUB_ORPHAN=$work/orphan STUB_MODE=inspect-hang \
  DOCKER=$work/stub-docker NETDIAG_INSPECT_SECONDS=1 NETDIAG_OVERALL_SECONDS=5 \
  bash "$diag" > "$work/inspect.out"
inspect_rc=$?
set -e
inspect_elapsed=$(python3 -c 'import sys; print("%.3f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$start" "$(seconds)")
echo "elapsed=$inspect_elapsed exit=$inspect_rc"
cat "$work/inspect.out"
if [ "$inspect_rc" -ne 124 ]; then
  echo "inspect deadline did not abort" >&2
  exit 1
fi
grep -qx 'container=inspect_timeout' "$work/inspect.out"
python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) < 4 else 1)' "$inspect_elapsed"
if grep -q '^exec' "$work/inspect.log" 2>/dev/null; then
  echo "inspect deadline still started exec" >&2
  exit 1
fi

echo "=== orphan survives client kill ==="
: > "$work/stub.log"
start=$(seconds)
set +e
STUB_LOG=$work/stub.log STUB_ORPHAN=$work/orphan STUB_MODE=orphan \
  DOCKER=$work/stub-docker NETDIAG_EXEC_SECONDS=2 NETDIAG_OVERALL_SECONDS=10 NETDIAG_KILL_SECONDS=3 \
  bash "$diag" > "$work/orphan.out"
orphan_rc=$?
set -e
orphan_elapsed=$(python3 -c 'import sys; print("%.3f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$start" "$(seconds)")
orphan_pid=$(cat "$work/orphan")
echo "elapsed=$orphan_elapsed exit=$orphan_rc"
cat "$work/stub.log"
cat "$work/orphan.out"
if [ "$orphan_rc" -ne 124 ]; then
  echo "orphan case did not hit the host deadline" >&2
  exit 1
fi
grep -qx 'kill alive=yes' "$work/stub.log"
grep -qx 'diag=timeout' "$work/orphan.out"
grep -qx 'container_child=killed' "$work/orphan.out"
if [ -d "/proc/$orphan_pid" ]; then
  echo "orphan diagnostic child still running" >&2
  exit 1
fi
echo "child_after=dead"
python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) < 8 else 1)' "$orphan_elapsed"
if grep -q 'diag_pgid=' "$work/orphan.out"; then
  echo "process id leaked into the report" >&2
  exit 1
fi

echo "=== container normal, phase, and host deadline ==="
mkdir -p "$work/instance"
printf 'synthetic-offline-fixture\n' > "$work/secret"
chmod 700 "$work/instance"
chmod 600 "$work/secret"
podman unshare chown -R 65532:65532 "$work/instance" "$work/secret"
podman kill wa-readonly-2 >/dev/null 2>&1 || true
podman rm -f wa-readonly-2 >/dev/null 2>&1 || true
podman run -d --name wa-readonly-2 --network none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  -v "$work/instance:/var/lib/wa-instance" \
  -v "$work/secret:/run/secrets/mcp-token:ro" \
  -e WA_MCP_TRANSPORT=streamable-http -e WA_MCP_BIND=127.0.0.1 -e WA_MCP_PORT=12789 \
  -e MCP_AUTH_TOKEN_FILE=/run/secrets/mcp-token -e WA_RUN_BRIDGE=1 -e WA_PAIR=0 \
  -e WA_INSTANCE_DIR=/var/lib/wa-instance -e SECRET_SHOULD_NOT_PRINT=supersecretvalue \
  localhost/wa-readonly-private:t276 >/dev/null
ready=0
for _ in $(seq 1 40); do
  if podman exec wa-readonly-2 python3 -c 'import socket; s=socket.create_connection(("127.0.0.1",12789),2); s.close()' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.3
done
if [ "$ready" -ne 1 ]; then
  echo "listener did not start" >&2
  exit 1
fi
http_pid=$(podman exec wa-readonly-2 python3 -c 'import os
me=str(os.getpid())
found=[]
needle=b"whatsapp-mcp-server/main.py"
for name in os.listdir("/proc"):
    if not name.isdigit() or name == me:
        continue
    try:
        raw=open("/proc/"+name+"/cmdline","rb").read()
    except OSError:
        continue
    if needle in raw:
        found.append(name)
print(",".join(sorted(found)))')
if [ -z "$http_pid" ]; then
  echo "http process missing before diagnostic" >&2
  exit 1
fi

assert_http_same() {
  current=$(podman exec wa-readonly-2 python3 -c 'import os
me=str(os.getpid())
found=[]
needle=b"whatsapp-mcp-server/main.py"
for name in os.listdir("/proc"):
    if not name.isdigit() or name == me:
        continue
    try:
        raw=open("/proc/"+name+"/cmdline","rb").read()
    except OSError:
        continue
    if needle in raw:
        found.append(name)
print(",".join(sorted(found)))')
  if [ "$current" != "$http_pid" ]; then
    echo "http process changed" >&2
    exit 1
  fi
  podman exec wa-readonly-2 python3 -c 'import socket; s=socket.create_connection(("127.0.0.1",12789),2); s.close()'
}

assert_clean() {
  if grep -q 'supersecretvalue' "$1"; then
    echo "planted environment value appeared" >&2
    exit 1
  fi
  if grep -q 'diag_pgid=' "$1"; then
    echo "process id leaked into the report" >&2
    exit 1
  fi
}

echo "--- normal ---"
start=$(seconds)
DOCKER=$(command -v podman) bash "$diag" > "$work/normal.out"
normal_elapsed=$(python3 -c 'import sys; print("%.3f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$start" "$(seconds)")
echo "elapsed=$normal_elapsed"
cat "$work/normal.out"
grep -qx 'WA_PAIR=0' "$work/normal.out"
grep -qx 'http_process=yes' "$work/normal.out"
grep -qx 'local_listener=ok' "$work/normal.out"
grep -qx 'diag=ok' "$work/normal.out"
grep -qx 'container_child=exited' "$work/normal.out"
assert_clean "$work/normal.out"
assert_http_same
python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) < 12 else 1)' "$normal_elapsed"
echo "normal_http_same=yes listener_after=yes planted_absent=yes"

echo "--- phase deadline ---"
start=$(seconds)
DOCKER=$(command -v podman) NETDIAG_DNS_SECONDS=2 NETDIAG_EXEC_SECONDS=10 NETDIAG_OVERALL_SECONDS=16 \
  bash "$diag" --self-test-hang > "$work/hang.out"
hang_elapsed=$(python3 -c 'import sys; print("%.3f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$start" "$(seconds)")
echo "elapsed=$hang_elapsed"
cat "$work/hang.out"
grep -qx 'dns=timeout' "$work/hang.out"
grep -qx 'dns_error=deadline' "$work/hang.out"
grep -qx 'local_listener=ok' "$work/hang.out"
grep -qx 'diag=ok' "$work/hang.out"
assert_clean "$work/hang.out"
assert_http_same
python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) < 8 else 1)' "$hang_elapsed"
podman exec wa-readonly-2 python3 -c 'import os; raise SystemExit(0 if os.path.exists("/tmp/wa-netdiag-hang") else 1)'
leftover=$(podman exec wa-readonly-2 python3 -c 'import os
count=0
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    try:
        raw=open("/proc/"+name+"/cmdline","rb").read().split(bytes([0]))
    except OSError:
        continue
    parts=[part for part in raw if part]
    if len(parts) >= 3 and parts[0].rsplit(b"/",1)[-1]==b"python3" and parts[1:]==[b"-u", b"-"]:
        count += 1
print(count)')
if [ "$leftover" != "0" ]; then
  echo "phase child still running inside the container" >&2
  exit 1
fi
echo "hang_marker=yes leftover_diag_process=0 http_same=yes"

echo "--- host deadline inside container ---"
start=$(seconds)
set +e
DOCKER=$(command -v podman) NETDIAG_EXEC_SECONDS=3 NETDIAG_OVERALL_SECONDS=12 NETDIAG_KILL_SECONDS=4 \
  bash "$diag" --self-test-stuck > "$work/stuck.out" &
stuck_job=$!
set -e
stuck_pid=""
for _ in $(seq 1 50); do
  if podman exec wa-readonly-2 python3 -c 'print(open("/tmp/wa-netdiag-stuck").read().strip())' > "$work/stuck-pid" 2>/dev/null; then
    stuck_pid=$(cat "$work/stuck-pid")
    break
  fi
  if ! kill -0 "$stuck_job" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [ -z "$stuck_pid" ]; then
  echo "stuck diagnostic child was not visible" >&2
  wait "$stuck_job" || true
  cat "$work/stuck.out" >&2 || true
  exit 1
fi
podman exec wa-readonly-2 python3 -c 'import os,sys; raise SystemExit(0 if os.path.exists("/proc/"+sys.argv[1]) else 1)' "$stuck_pid"
echo "child_was_alive=yes"
podman exec wa-readonly-2 python3 -c 'import socket; s=socket.create_connection(("127.0.0.1",12789),2); s.close()'
echo "listener_during=yes"
set +e
wait "$stuck_job"
stuck_rc=$?
set -e
stuck_elapsed=$(python3 -c 'import sys; print("%.3f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$start" "$(seconds)")
echo "elapsed=$stuck_elapsed exit=$stuck_rc"
cat "$work/stuck.out"
if [ "$stuck_rc" -ne 124 ]; then
  echo "stuck case did not hit the host deadline" >&2
  exit 1
fi
grep -qx 'diag=timeout' "$work/stuck.out"
if ! grep -Eq '^container_child=(killed|absent)$' "$work/stuck.out"; then
  echo "container child was not confirmed gone" >&2
  exit 1
fi
assert_clean "$work/stuck.out"
if podman exec wa-readonly-2 python3 -c 'import os,sys; raise SystemExit(0 if os.path.exists("/proc/"+sys.argv[1]) else 1)' "$stuck_pid"; then
  echo "stuck diagnostic child still running" >&2
  exit 1
fi
echo "child_after=dead"
assert_http_same
python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) < 10 else 1)' "$stuck_elapsed"
echo "stuck_http_same=yes listener_after=yes"

echo "--- parent death signal ---"
podman exec --user 65532:65532 wa-readonly-2 python3 - << 'PY'
import ctypes
import os
import time

libc = ctypes.CDLL("libc.so.6")
ready_read, ready_write = os.pipe()
id_read, id_write = os.pipe()
middle = os.fork()
if middle == 0:
    me = os.getpid()
    os.close(id_read)
    os.close(ready_read)
    child = os.fork()
    if child == 0:
        os.close(id_write)
        if libc.prctl(1, 9) != 0 or os.getppid() != me:
            os._exit(2)
        os.write(ready_write, b"ready\n")
        time.sleep(30)
        os._exit(3)
    os.close(ready_write)
    os.read(ready_read, 8)
    os.write(id_write, str(child).encode("ascii") + b"\n")
    os.close(id_write)
    os._exit(0)
os.close(id_write)
os.close(ready_read)
os.close(ready_write)
os.waitpid(middle, 0)
child = int(os.read(id_read, 64).strip())
deadline = time.time() + 2
while time.time() < deadline:
    if not os.path.exists("/proc/%d" % child):
        os._exit(0)
    time.sleep(0.05)
os._exit(1)
PY
podman exec wa-readonly-2 python3 -c 'import os; raise SystemExit(0 if os.path.exists("/proc/1") else 1)'
assert_http_same
echo "grandchild_dead=yes pid1_alive=yes http_same=yes"

if [ -s "$TIMEOUT_TRAP_LOG" ]; then
  echo "external timeout command was used" >&2
  exit 1
fi
echo "external_timeout_used=no"
echo "PASS"
