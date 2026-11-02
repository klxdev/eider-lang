#!/bin/sh
# Stress run of the thread-using std tests: each is built once (plain, or under
# ThreadSanitizer with EIDER_STRESS_TSAN=1) and then run JOBS copies at a time, RUNS runs in
# each copy, optionally pinned to the cores in PIN (e.g. PIN=0,1 to force contention).
# A failing run keeps its whole output in target/std-fail/. Defaults: JOBS=32 RUNS=4.
#   sh tests/std/stress.sh [test ...]        (default: the thread tests)
cd "$(dirname "$0")/../.." || exit 1
mkdir -p target/tmp target/std-fail
jobs=${JOBS:-32}; runs=${RUNS:-4}
tests=${*:-"atomic sync chan chan_wake task event deadline time"}
flags=""
[ "${EIDER_STRESS_TSAN:-}" = 1 ] && flags="-fsanitize=thread -g"
bad=0
for t in $tests; do
  exe=target/tmp/stress_$t
  if ! EIDER_CACHE=off EIDER_CFLAGS="$flags" scripts/ei build "tests/std/$t.ei" -o "$exe" >"target/tmp/stress_$t.log" 2>&1; then
    echo "FAIL $t: build"; cat "target/tmp/stress_$t.log"; bad=1; continue
  fi
  want=$(cat "tests/std/$t.out")
  rm -f target/std-fail/"$t".*.got
  k=0
  while [ $k -lt "$jobs" ]; do
    (
      i=0
      while [ $i -lt "$runs" ]; do
        got=$(TSAN_OPTIONS="halt_on_error=1 exitcode=66" EIDER_STD_TEST=set ${PIN:+taskset -c "$PIN"} "$exe" </dev/null 2>&1; echo "exit $?")
        if [ "$got" != "$want" ]; then printf '%s\n' "$got" > "target/std-fail/$t.$k.$i.got"; fi
        i=$((i + 1))
      done
    ) &
    k=$((k + 1))
  done
  wait
  n=$(ls target/std-fail 2>/dev/null | grep -c "^$t\.[0-9]*\.[0-9]*\.got$")
  if [ "$n" = 0 ]; then echo "ok   $t ($((jobs * runs)) runs)"; else echo "FAIL $t: $n of $((jobs * runs)) runs differ (target/std-fail/$t.*.got)"; bad=1; fi
done
exit $bad
