#!/bin/sh
# Runs packages/*/tests/*.ei through scripts/ei and compares output with the .out next to it.
cd "$(dirname "$0")/.." || exit 1
scripts/bootstrap-deps.sh
fail=0
for f in packages/*/tests/*.ei; do
  got=$(scripts/ei run "$f" 2>&1)
  if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f"; else echo "FAIL $f"; echo "$got" | diff "${f%.ei}.out" - | head -10; fail=1; fi
done
exit $fail
