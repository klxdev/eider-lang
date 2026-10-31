#!/bin/sh
# Runs packages/*/tests/*.ei and examples/*/tests/*.ei through scripts/ei and compares output
# with the .out next to it. Then the tests that serve over loopback with threads (http's
# server test and the kvstore example's end-to-end test) are built once under
# ThreadSanitizer and run once each, when the C compiler can build a TSan program (else
# `skip`).
cd "$(dirname "$0")/.." || exit 1
fail=0
for f in packages/*/tests/*.ei examples/*/tests/*.ei; do
  [ -f "$f" ] || continue
  got=$(scripts/ei run "$f" 2>&1)
  if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f"; else echo "FAIL $f"; echo "$got" | diff "${f%.ei}.out" - | head -10; fail=1; fi
done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf 'int main(void) { return 0; }\n' > "$T/probe.c"
if ${CC:-cc} -fsanitize=thread -o "$T/probe" "$T/probe.c" 2>/dev/null && "$T/probe"; then
  for f in packages/http/tests/server_test.ei examples/kvstore/tests/e2e_test.ei; do
    if ! EIDER_CACHE=off EIDER_CFLAGS="-fsanitize=thread -g" scripts/ei build "$f" -o "$T/t" >"$T/log" 2>&1; then
      echo "FAIL $f (tsan): build"; cat "$T/log"; fail=1; continue
    fi
    got=$(TSAN_OPTIONS="halt_on_error=1 exitcode=66" "$T/t" </dev/null 2>&1)
    if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f (tsan)"; else echo "FAIL $f (tsan)"; echo "$got" | diff "${f%.ei}.out" - | head -20; fail=1; fi
  done
else
  echo "skip tsan runs of the http tests: ${CC:-cc} cannot build a -fsanitize=thread program"
fi
exit $fail
