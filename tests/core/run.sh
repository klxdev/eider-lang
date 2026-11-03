#!/bin/sh
# Builds the C core strictly (warnings are errors) and runs tests/core/rt_test.c against
# core/eider_rt.c: with and without compiler builtins, then under ASan+UBSan and TSan when
# the toolchain has the sanitizer runtimes (skipped with a message otherwise). UBSan in trap
# mode needs no runtime library, so undefined behaviour is checked on every toolchain.
# tests/core/core_test.c (ec_run, ec_read_fd) and tests/core/os_test.c (descriptors, sockets,
# DNS, readiness, time, signals, randomness, processes) run against core/eider_core.c the same
# way. tests/core/prof_test.c runs against the profiling runtime (core/eider_prof.c, eider_rt.c
# built with -DEI_RT_PROFILE) and eider_core.c, plain and under the same sanitizers; and the
# runtime built without the flag must contain none of the profiler.
cd "$(dirname "$0")/../.." || exit 1
CC=${CC:-cc}
STRICT="-std=c11 -pedantic -Wall -Wextra -Wconversion -Wshadow -Werror"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

# huge allocations must fail (and trap), not abort inside the sanitizer
ASAN_OPTIONS=allocator_may_return_null=1; export ASAN_OPTIONS
TSAN_OPTIONS="allocator_may_return_null=1 halt_on_error=1 die_after_fork=0"; export TSAN_OPTIONS
UBSAN_OPTIONS=halt_on_error=1; export UBSAN_OPTIONS

if $CC $STRICT -DEI_RT_COUNT_ALLOCS -c core/eider_rt.c -o "$T/o.o" 2>"$T/log"; then echo "ok   strict core/eider_rt.c (-DEI_RT_COUNT_ALLOCS)"; else echo "FAIL strict core/eider_rt.c (-DEI_RT_COUNT_ALLOCS)"; cat "$T/log"; fail=1; fi
if $CC $STRICT -DEI_RT_PROFILE -c core/eider_rt.c -o "$T/o.o" 2>"$T/log"; then echo "ok   strict core/eider_rt.c (-DEI_RT_PROFILE)"; else echo "FAIL strict core/eider_rt.c (-DEI_RT_PROFILE)"; cat "$T/log"; fail=1; fi
# without the flag the profiler is not there at all (docs/runtime.md "Profiler": zero cost)
if $CC -std=c11 -E -P core/eider_rt.c 2>/dev/null | grep -q 'prof_\|EI_PEV'; then echo "FAIL core/eider_rt.c without -DEI_RT_PROFILE still has profiler code"; fail=1; else echo "ok   core/eider_rt.c without -DEI_RT_PROFILE has no profiler code"; fi
for f in core/eider_core.c core/eider_rt.c; do
  if $CC $STRICT -c "$f" -o "$T/o.o" 2>"$T/log"; then echo "ok   strict $f"; else echo "FAIL strict $f"; cat "$T/log"; fail=1; fi
done

# run NAME FLAGS...: build rt_test with FLAGS and run it
run() {
  name=$1; shift
  if ! $CC $STRICT "$@" -o "$T/rt_$name" tests/core/rt_test.c core/eider_rt.c -pthread 2>"$T/log"; then
    echo "FAIL rt ($name): build"; cat "$T/log"; fail=1; return
  fi
  if "$T/rt_$name" >"$T/out" 2>&1; then
    echo "ok   rt ($name): $(tail -1 "$T/out")"
  else
    echo "FAIL rt ($name)"; cat "$T/out"; fail=1
  fi
}

# core NAME FLAGS...: build core_test and os_test with FLAGS and run them (each re-executes
# itself as the child)
core() {
  name=$1; shift
  for t in core os; do
    if ! $CC $STRICT "$@" -o "$T/${t}_$name" tests/core/${t}_test.c core/eider_core.c -pthread 2>"$T/log"; then
      echo "FAIL $t ($name): build"; cat "$T/log"; fail=1; continue
    fi
    if "$T/${t}_$name" >"$T/out" 2>&1; then
      echo "ok   $t ($name): $(tail -1 "$T/out")"
    else
      echo "FAIL $t ($name)"; cat "$T/out"; fail=1
    fi
  done
}

# task NAME FLAGS...: build task_test (the scheduler) with FLAGS against the runtime and the core
task() {
  name=$1; shift
  if ! $CC $STRICT "$@" -o "$T/task_$name" tests/core/task_test.c core/eider_rt.c core/eider_core.c -pthread 2>"$T/log"; then
    echo "FAIL task ($name): build"; cat "$T/log"; fail=1; return
  fi
  if "$T/task_$name" >"$T/out" 2>&1; then
    echo "ok   task ($name): $(tail -1 "$T/out")"
  else
    echo "FAIL task ($name)"; cat "$T/out"; fail=1
  fi
}

# prof NAME FLAGS...: build prof_test with FLAGS against the profiling runtime and run it
prof() {
  name=$1; shift
  if ! $CC $STRICT -DEI_RT_PROFILE "$@" -I core -o "$T/prof_$name" tests/core/prof_test.c core/eider_rt.c core/eider_core.c -pthread 2>"$T/log"; then
    echo "FAIL prof ($name): build"; cat "$T/log"; fail=1; return
  fi
  if EIDER_PROF="$T/prof_$name.prof" EIDER_PROF_HZ=1000 "$T/prof_$name" "$T/prof_$name.snap" >"$T/out" 2>&1 && grep -q '"reason":"exit"' "$T/prof_$name.prof"; then
    echo "ok   prof ($name): $(tail -1 "$T/out")"
  else
    echo "FAIL prof ($name)"; cat "$T/out"; fail=1
  fi
}

# sanitizer NAME FLAGS...: run under FLAGS if a trivial program builds and runs with them
sanitizer() {
  name=$1; shift
  printf 'int main(void) { return 0; }\n' > "$T/probe.c"
  if $CC "$@" -o "$T/probe" "$T/probe.c" -pthread >/dev/null 2>&1 && "$T/probe" >/dev/null 2>&1; then
    run "$name" -O1 -g "$@"
    core "$name" -O1 -g "$@"
    prof "$name" -O1 -g "$@"
    task "$name" -O1 -g "$@" -DEI_TEST_SANITIZED
  else
    echo "skip rt ($name): $CC cannot build or run with $*"
  fi
}

run O2 -O2
run portable -O0 -DEI_RT_PORTABLE
run count-allocs -O0 -DEI_RT_COUNT_ALLOCS
core O2 -O2
prof O2 -O2
task O2 -O2
task ucontext -O2 -DEI_TASK_UCONTEXT
prof count-allocs -O0 -DEI_RT_COUNT_ALLOCS
sanitizer ubsan-trap -fsanitize=undefined -fsanitize-trap=undefined
sanitizer ubsan-trap,portable -fsanitize=undefined -fsanitize-trap=undefined -DEI_RT_PORTABLE
sanitizer asan+ubsan -fsanitize=address,undefined -fno-sanitize-recover=undefined
sanitizer tsan -fsanitize=thread
exit $fail
