#!/bin/sh
# Builds the C core strictly (warnings are errors) and runs tests/core/rt_test.c against
# core/eider_rt.c: with and without compiler builtins, then under ASan+UBSan and TSan when
# the toolchain has the sanitizer runtimes (skipped with a message otherwise). UBSan in trap
# mode needs no runtime library, so undefined behaviour is checked on every toolchain.
cd "$(dirname "$0")/../.." || exit 1
CC=${CC:-cc}
STRICT="-std=c11 -pedantic -Wall -Wextra -Wconversion -Wshadow -Werror"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

# huge allocations must fail (and trap), not abort inside the sanitizer
ASAN_OPTIONS=allocator_may_return_null=1; export ASAN_OPTIONS
TSAN_OPTIONS="allocator_may_return_null=1 halt_on_error=1"; export TSAN_OPTIONS
UBSAN_OPTIONS=halt_on_error=1; export UBSAN_OPTIONS

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

# sanitizer NAME FLAGS...: run under FLAGS if a trivial program builds and runs with them
sanitizer() {
  name=$1; shift
  printf 'int main(void) { return 0; }\n' > "$T/probe.c"
  if $CC "$@" -o "$T/probe" "$T/probe.c" -pthread >/dev/null 2>&1 && "$T/probe" >/dev/null 2>&1; then
    run "$name" -O1 -g "$@"
  else
    echo "skip rt ($name): $CC cannot build or run with $*"
  fi
}

run O2 -O2
run portable -O0 -DEI_RT_PORTABLE
sanitizer ubsan-trap -fsanitize=undefined -fsanitize-trap=undefined
sanitizer ubsan-trap,portable -fsanitize=undefined -fsanitize-trap=undefined -DEI_RT_PORTABLE
sanitizer asan+ubsan -fsanitize=address,undefined -fno-sanitize-recover=undefined
sanitizer tsan -fsanitize=thread
exit $fail
