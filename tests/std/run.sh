#!/bin/sh
# Runs every tests/std/*.ei through scripts/ei (C core linked) and compares stdout+stderr
# and the exit code with the .out file (last line `exit N`). stdin is the .in file next to
# the test when there is one, else /dev/null.
cd "$(dirname "$0")/../.." || exit 1
mkdir -p target/tmp
fail=0
for f in tests/std/*.ei; do
  exp="${f%.ei}.out"
  in="${f%.ei}.in"
  [ -f "$in" ] || in=/dev/null
  got=$(EIDER_STD_TEST=set scripts/ei run "$f" <"$in" 2>&1; echo "exit $?")
  if [ "$got" = "$(cat "$exp")" ]; then echo "ok   $f"; else echo "FAIL $f"; echo "$got" | diff "$exp" - | head -20; fail=1; fi
done
exit $fail
