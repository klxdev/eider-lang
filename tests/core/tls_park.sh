#!/bin/sh
# No function of the task runtime may read the thread pointer and use it after a context switch
# (#204, docs/design/lightweight-tasks.md "Thread-locals across a park"). A task that parks
# resumes on another worker thread, so a thread-local address computed before the switch is
# another thread's afterwards. x86-64 addresses thread-locals through %fs on every access, so
# nothing can go stale there; AArch64 reads TPIDR_EL0 once and the compiler keeps it in a
# callee-saved register across the whole function, loops included. This compiles core/eider_rt.c
# for aarch64-linux-gnu (zig's clang carries the headers; it only compiles, nothing runs) and
# fails when a function that calls swapcontext also reads TPIDR_EL0, for the runtime as a
# profile build uses it too (-DEI_RT_PROFILE: the shadow stack), and when ei_try, which calls a
# function that may park, reads it. The code the compiler generates is checked the same way
# (#209): `emit-llvm --profile` of tests/core/tls_park.ei, compiled for AArch64, must not read
# the thread pointer anywhere, because generated code reaches the shadow stack only through
# the runtime's out-of-line ei_prof_enter/ei_prof_leave (a thread-local address of its own,
# computed once per function, would be kept across a park: 191 reads in this program before
# the fix). Skipped without zig.
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
# the runtime, plain and as a profile build
for prof in "" "-DEI_RT_PROFILE"; do
  for flags in "-O1" "-O2" "-O3"; do
    if ! "$zig" cc -target aarch64-linux-gnu $flags $prof -S -I core -o "$T/rt.s" core/eider_rt.c 2>"$T/log"; then
      echo "skip tls across a park (aarch64): zig cannot compile for aarch64-linux-gnu"; cat "$T/log"; exit 0
    fi
    bad=$(awk '
      /^[A-Za-z_][A-Za-z0-9_.]*:/ { fn = $1 }
      /bl[ \t]+swapcontext|b[ \t]+swapcontext/ { sw[fn] = 1 }
      /[Tt][Pp][Ii][Dd][Rr]_[Ee][Ll]0/ { tp[fn] = 1 }
      END { for (f in sw) if (tp[f] && f != "worker_main:") print f; if (tp["ei_try:"]) print "ei_try:" }' "$T/rt.s")
    if [ -n "$bad" ]; then
      echo "FAIL tls across a park (aarch64 $flags $prof): reads the thread pointer in a function that switches or calls one that may: $bad"; fail=1
    fi
  done
done
[ $fail = 0 ] && echo "ok   tls across a park (aarch64 -O1/-O2/-O3, plain and profile runtime: no thread pointer kept across a switch)"
# the generated code of a profile build
ei=${EIDERC:-}
[ -z "$ei" ] && ei="sh scripts/ei"
if ! $ei emit-llvm --profile tests/core/tls_park.ei >"$T/gen.ll" 2>"$T/log"; then
  echo "FAIL tls across a park (generated code): emit-llvm --profile tests/core/tls_park.ei"; head -5 "$T/log"; exit 1
fi
if ! grep -q 'call ptr @ei_prof_enter' "$T/gen.ll"; then echo "FAIL tls across a park (generated code): the program has no profile frames"; exit 1; fi
gfail=0
for flags in "-O1" "-O2" "-O3"; do
  if ! "$zig" cc -target aarch64-linux-gnu $flags -Wno-override-module -S -o "$T/gen.s" "$T/gen.ll" 2>"$T/log"; then
    echo "FAIL tls across a park (generated code, aarch64 $flags): zig cannot compile the program"; head -5 "$T/log"; exit 1
  fi
  n=$(grep -ci 'tpidr_el0' "$T/gen.s")
  if [ "$n" != 0 ]; then
    echo "FAIL tls across a park (generated code, aarch64 $flags): $n reads of the thread pointer in the program's own code"; gfail=1
  fi
done
[ $gfail = 0 ] && echo "ok   tls across a park (generated code of --profile, aarch64 -O1/-O2/-O3: no thread pointer read in it)"
[ $gfail = 0 ] || fail=1
exit $fail
