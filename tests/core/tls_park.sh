#!/bin/sh
# No function of the task runtime may read the thread pointer and use it after a context switch
# (#204, docs/design/lightweight-tasks.md "Thread-locals across a park"). A task that parks
# resumes on another worker thread, so a thread-local address computed before the switch is
# another thread's afterwards. x86-64 addresses thread-locals through %fs on every access, so
# nothing can go stale there; AArch64 reads TPIDR_EL0 once and the compiler keeps it in a
# callee-saved register across the whole function, loops included. This compiles core/eider_rt.c
# for aarch64-linux-gnu (zig's clang carries the headers; it only compiles, nothing runs) and
# fails when a function that calls swapcontext also reads TPIDR_EL0. Skipped without zig.
cd "$(dirname "$0")/../.." || exit 1
zig=
if [ -n "${ZIG:-}" ]; then zig=$ZIG
elif command -v zig >/dev/null 2>&1 && zig version >/dev/null 2>&1; then zig=$(command -v zig)
elif command -v mise >/dev/null 2>&1 && [ -x "$(mise where zig 2>/dev/null)/zig" ]; then zig=$(mise where zig)/zig
fi
if [ -z "$zig" ]; then echo "skip tls across a park (aarch64): needs zig (ZIG, PATH, or mise)"; exit 0; fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
for flags in "-O1" "-O2" "-O3"; do
  if ! "$zig" cc -target aarch64-linux-gnu $flags -S -I core -o "$T/rt.s" core/eider_rt.c 2>"$T/log"; then
    echo "skip tls across a park (aarch64): zig cannot compile for aarch64-linux-gnu"; cat "$T/log"; exit 0
  fi
  bad=$(awk '
    /^[A-Za-z_][A-Za-z0-9_.]*:/ { fn = $1 }
    /bl[ \t]+swapcontext|b[ \t]+swapcontext/ { sw[fn] = 1 }
    /[Tt][Pp][Ii][Dd][Rr]_[Ee][Ll]0/ { tp[fn] = 1 }
    END { for (f in sw) if (tp[f] && f != "worker_main:") print f }' "$T/rt.s")
  if [ -n "$bad" ]; then
    echo "FAIL tls across a park (aarch64 $flags): reads the thread pointer in a function that switches: $bad"; fail=1
  fi
done
[ $fail = 0 ] && echo "ok   tls across a park (aarch64 -O1/-O2/-O3: no thread pointer kept across a switch)"
exit $fail
