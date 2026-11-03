#!/bin/sh
# Memory of idle connections on tasks (docs/runtime.md "Tasks: measured", M4 of
# docs/design/lightweight-tasks.md):
#   sh scripts/idle-bench.sh [TARGET] [PORTS]        TARGET connections (default 100000)
# builds tests/bench/scale/idle_server.ei (a task per connection, parked on its socket) and
# idle_client.ei (opens the connections from another process and keeps them silent), connects
# TARGET of them over loopback and prints what the server process holds: resident memory,
# address space, mappings, threads, and the system's available memory before and after (which
# includes the kernel's sockets). The limits it can hit are printed with the numbers:
# RLIMIT_NOFILE (raised to its hard limit), vm.max_map_count (two mappings per task stack),
# the client's ephemeral ports (PORTS destination ports of 10,000 connections each).
cd "$(dirname "$0")/.." || exit 1
TARGET=${1:-100000}
PORTS=${2:-$(((TARGET + 9999) / 10000))}
[ "$PORTS" -lt 2 ] && PORTS=2
E=${EIDER:-scripts/ei}
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
$E build tests/bench/scale/idle_server.ei -o "$T/server" || exit 1
$E build tests/bench/scale/idle_client.ei -o "$T/client" || exit 1
ulimit -n "$(ulimit -Hn)" 2>/dev/null
echo "limits: nofile $(ulimit -n), vm.max_map_count $(cat /proc/sys/vm/max_map_count), $(nproc) CPUs"
avail() { awk '/^MemAvailable/ {print $2}' /proc/meminfo; }
status() { awk -v k="$2" '$1 == k ":" {print $2}' "/proc/$1/status"; }
mkfifo "$T/sin" "$T/cin"
export TARGET PORTS PORT=${PORT:-19000}
"$T/server" <"$T/sin" >"$T/server.out" 2>&1 &
server=$!
exec 8>"$T/sin"
sleep 1
a0=$(avail)
r0=$(status $server VmRSS)
v0=$(status $server VmSize)
m0=$(wc -l <"/proc/$server/maps")
f0=$(ls "/proc/$server/fd" | wc -l)
"$T/client" <"$T/cin" >"$T/client.out" 2>&1 &
client=$!
exec 9>"$T/cin"
t0=$(date +%s)
# (the programs' output is buffered until they exit, so progress is the server's descriptor count)
last=0
same=0
while :; do
  sleep 2
  if ! kill -0 $server 2>/dev/null; then echo "the server ended: $(cat "$T/server.out")"; exit 1; fi
  n=$(ls "/proc/$server/fd" | wc -l)
  [ -n "$VERBOSE" ] && echo "  $(($(date +%s) - t0)) s: $n descriptors"
  [ "$n" -ge $((TARGET + f0)) ] && break
  if [ "$n" = "$last" ]; then same=$((same + 1)); else same=0; fi
  last=$n
  if [ $same -ge 15 ]; then echo "stalled at $n descriptors for 30 s: the connections stopped coming"; break; fi
  if [ $(($(date +%s) - t0)) -gt 1500 ]; then echo "gave up after 1500 s at $n descriptors"; break; fi
done
t1=$(date +%s)
sleep 2
a1=$(avail)
echo "connected in $((t1 - t0)) s"
if kill -0 $server 2>/dev/null; then
  r1=$(status $server VmRSS)
  v1=$(status $server VmSize)
  th=$(status $server Threads)
  m1=$(wc -l <"/proc/$server/maps")
  fds=$(ls "/proc/$server/fd" | wc -l)
  echo "server idle (0 connections): RSS $((r0 / 1024)) MiB, address space $((v0 / 1024)) MiB, $m0 mappings"
  echo "server with $fds descriptors, $th threads: RSS $((r1 / 1024)) MiB, address space $((v1 / 1024)) MiB, $m1 mappings"
  conns=$((fds - f0))
  [ "$conns" -lt 1 ] && conns=1
  echo "per connection: $(((r1 - r0) * 1024 / conns)) bytes resident in the process, $(((m1 - m0) * 1000 / conns)) mappings per 1000"
  echo "system: MemAvailable fell by $(((a0 - a1) / 1024)) MiB (the process, the client's sockets and the kernel's: $(((a0 - a1) * 1024 / conns)) bytes per connection)"
fi
exec 8>&- 9>&-
wait 2>/dev/null
echo "client said: $(tr '\n' ' ' <"$T/client.out")"
