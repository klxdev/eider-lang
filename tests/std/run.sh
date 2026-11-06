#!/bin/sh
# Runs every tests/std/*.ei through scripts/ei (C core linked) and compares stdout+stderr
# and the exit code with the .out file (last line `exit N`). stdin is the .in file next to
# the test when there is one, else /dev/null.
# Then the runtime-layer tests that use threads (atomics, channels, tasks, the event loop)
# are built once under ThreadSanitizer and run $EIDER_TSAN_RUNS times each
# (default 3), when the C compiler can build and run a TSan program (else `skip`). Not
# stack_overflow.ei: under TSan a thread can run out of stack inside the sanitizer's own
# code, which then dies of SIGSEGV before our handler runs (tests/core checks the handler
# under TSan, in C).
cd "$(dirname "$0")/../.." || exit 1
mkdir -p target/tmp target/std-fail
fail=0
# A failing test keeps its whole output in target/std-fail/<name>.got (and the expected in
# .want), so a flake under load is diagnosable afterwards; the diff is printed in full.
keep() { # name want got
  printf '%s\n' "$3" > "target/std-fail/$1.got"; cp "$2" "target/std-fail/$1.want"
  echo "  output kept in target/std-fail/$1.got"
}
for f in tests/std/*.ei; do
  exp="${f%.ei}.out"
  in="${f%.ei}.in"
  [ -f "$in" ] || in=/dev/null
  got=$(EIDER_STD_TEST=set scripts/ei run "$f" <"$in" 2>&1; echo "exit $?")
  if [ "$got" = "$(cat "$exp")" ]; then echo "ok   $f"; else echo "FAIL $f"; echo "$got" | diff "$exp" -; keep "$(basename "${f%.ei}")" "$exp" "$got"; fail=1; fi
done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf 'int main(void) { return 0; }\n' > "$T/probe.c"
if ${CC:-cc} -fsanitize=thread -o "$T/probe" "$T/probe.c" 2>/dev/null && "$T/probe"; then
  runs=${EIDER_TSAN_RUNS:-3}
  for t in atomic sync chan chan_wake task task_trap lock_trap event service tasks cancel_fd; do
    f=tests/std/$t.ei
    if ! EIDER_CACHE=off EIDER_CFLAGS="-fsanitize=thread -g" scripts/ei build "$f" -o "$T/$t" >"$T/log" 2>&1; then
      echo "FAIL $f (tsan): build"; cat "$T/log"; fail=1; continue
    fi
    bad=0
    i=0
    while [ $i -lt "$runs" ]; do
      got=$(TSAN_OPTIONS="halt_on_error=1 exitcode=66" EIDER_STD_TEST=set "$T/$t" </dev/null 2>&1; echo "exit $?")
      if [ "$got" != "$(cat "${f%.ei}.out")" ]; then
        bad=1; echo "$got" | diff "${f%.ei}.out" -; keep "$t.tsan" "${f%.ei}.out" "$got"
      fi
      i=$((i + 1))
    done
    if [ $bad = 0 ]; then echo "ok   $f (tsan, $runs runs)"; else echo "FAIL $f (tsan)"; fail=1; fi
  done
else
  echo "skip tsan runs of the runtime tests: ${CC:-cc} cannot build a -fsanitize=thread program"
fi
exit $fail
