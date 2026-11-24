#!/bin/sh
# The tests written for docs/design/memory-safety.md: programs that must be rejected (tests/safety/fail: the
# compile-fail suite), programs that must be accepted (tests/safety/pass), run-time behaviour (tests/safety/run,
# stdout compared with the .out), and a check that every rule of the specification has tests where it says.
# Usage: sh tests/safety/run.sh [eiderc]   (default: scripts/ei)
cd "$(dirname "$0")/../.." || exit 1
E=${1:-scripts/ei}
fail=0
export EIDER_CACHE=${EIDER_CACHE:-off}

out=$($E test --compile-fail tests/safety 2>&1); last=$(printf '%s\n' "$out" | grep ' passed, ' | tail -1 | sed 's/;.*//')
if printf '%s' "$last" | grep -q " 0 failed"; then echo "ok   safety: compile-fail and compile-pass corpus ($last)"
else echo "FAIL safety: compile-fail corpus"; printf '%s\n' "$out" | grep -v "^  ok" | head -12; fail=1; fi

for f in tests/safety/run/*.ei; do
  got=$($E run "$f" 2>&1)
  if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   safety: $f"; else echo "FAIL safety: $f"; echo "$got" | diff "${f%.ei}.out" - | head -8; fail=1; fi
done

# S11 under ThreadSanitizer, where TSan works (the release container; Fedora 45's TSan cannot follow longjmp, so it skips there):
# every crossing point of a value to another thread, run several times, must report nothing and give the recorded output
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '#include <setjmp.h>\nstatic jmp_buf j;\nstatic void jump(void) { longjmp(j, 1); }\nint main(void) { if (setjmp(j) == 0) jump(); return 0; }\n' > "$T/probe.c"
if ${CC:-cc} -fsanitize=thread -o "$T/probe" "$T/probe.c" 2>/dev/null && "$T/probe" >/dev/null 2>&1; then
  f=tests/safety/run/s11_crossing_points
  if EIDER_CFLAGS="-fsanitize=thread -g" $E build $f.ei -o "$T/s11" > "$T/build.log" 2>&1; then
    bad=0
    for i in 1 2 3 4 5 6; do
      got=$(TSAN_OPTIONS="halt_on_error=1 exitcode=66" "$T/s11" 2>&1)
      [ "$got" = "$(cat $f.out)" ] || { bad=1; echo "$got" | diff $f.out - | head -6; }
    done
    if [ $bad = 0 ]; then echo "ok   safety: $f under ThreadSanitizer (6 runs, no report)"; else echo "FAIL safety: $f under ThreadSanitizer"; fail=1; fi
  else echo "FAIL safety: $f does not build with -fsanitize=thread"; cat "$T/build.log" | head -5; fail=1; fi
else
  echo "skip safety: the thread crossing points under ThreadSanitizer: ${CC:-cc} cannot run a TSan program that uses longjmp"
fi

# rule -> where its tests must be (fail, pass, run); S3 (the type system) and S13 (compiler/tests/run/stack_overflow*.ei,
# core/RUNTIME.md "Stack overflow") are tested elsewhere
need() { # rule dirs...
  r=$1; shift
  for d in "$@"; do
    if ! ls tests/safety/$d/${r}_* >/dev/null 2>&1; then echo "FAIL safety: rule $r has no test in tests/safety/$d"; fail=1; fi
  done
}
need s1 fail run; need s2 fail run; need s4 fail pass; need s5 run; need s6 fail pass; need s7 fail pass
need s8 fail pass; need s9 fail pass; need s10 fail pass; need s11 fail pass; need s12 fail pass
[ $fail = 0 ] && echo "ok   safety: every rule S1, S2, S4 to S12 has the tests the specification promises"
exit $fail
