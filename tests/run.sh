#!/bin/sh
# Runs every tests/run/*.ei and compares stdout with the .out file next to it.
# Extra flags for the C compiler (e.g. sanitizers) come from $EIDER_CFLAGS via a CC wrapper.
# EIDER=<compiler> picks the compiler (default: scripts/ei, the seed's eiderc).
cd "$(dirname "$0")/.." || exit 1
E=${EIDER:-scripts/ei}
fail=0
for f in tests/run/*.ei; do
  exp="${f%.ei}.out"
  got=$($E run "$f" 2>&1)
  if [ "$got" = "$(cat "$exp")" ]; then echo "ok   $f"; else echo "FAIL $f"; fail=1; fi
done
exit $fail
