#!/bin/sh
# Runs every tests/run/*.ei and compares stdout with the .out file next to it.
# Extra flags for the C compiler (e.g. sanitizers) come from $EIDER_CFLAGS via a CC wrapper.
cd "$(dirname "$0")/.." || exit 1
E=${EIDER:-./target/debug/eider}
fail=0
for f in tests/run/*.ei; do
  exp="${f%.ei}.out"
  got=$($E run "$f" 2>&1)
  if [ "$got" = "$(cat "$exp")" ]; then echo "ok   $f"; else echo "FAIL $f"; fail=1; fi
done
exit $fail
