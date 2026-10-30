#!/bin/sh
# The WebAssembly core (core/wasm/) compiles warning-free as freestanding C under the same
# strict flags as the native core (core/RUNTIME.md):
#   - with the host C compiler, -fsyntax-only, against nothing but core/wasm/include and the
#     compiler's own freestanding headers (-nostdinc), so no libc header can leak in;
#   - with $WASM_CC (default clang) for wasm32, when it has the target (else: skip).
# EIDER=<compiler>: also checks that compiler's `emit-c --wasm` of tests/wasm/*.ei the same way.
cd "$(dirname "$0")/../.." || exit 1
strict="-std=c11 -pedantic -Wall -Wextra -Wconversion -Wshadow -Werror"
gen="-std=c11 -pedantic -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter"
CC=${CC:-cc}
WASM_CC=${WASM_CC:-clang}
T=$(mktemp -d)
fail=0
inc=$($CC -print-file-name=include)
host() { $CC -ffreestanding -nostdlib -fsyntax-only -nostdinc -isystem "$inc" -isystem core/wasm/include -I core -DEI_WASM_SYNTAX_CHECK "$@"; }
if host $strict core/wasm/libc.c core/wasm/eider_rt.c 2>$T/e; then
  echo "ok   core/wasm: freestanding C, strict warnings ($CC -fsyntax-only -nostdinc)"
else
  echo "FAIL core/wasm with $CC:"; cat $T/e; fail=1
fi
printf 'int x;\n' >$T/p.c
if $WASM_CC --target=wasm32 -c -o $T/p.o $T/p.c 2>/dev/null; then
  ok=1
  for f in libc eider_rt; do
    $WASM_CC --target=wasm32 $strict -O2 -ffreestanding -nostdlib -fno-builtin -isystem core/wasm/include -I core \
      -c -o $T/$f.o core/wasm/$f.c 2>$T/e || { echo "FAIL core/wasm/$f.c with $WASM_CC --target=wasm32:"; cat $T/e; ok=0; fail=1; }
  done
  [ $ok = 1 ] && echo "ok   core/wasm: wasm32, strict warnings ($WASM_CC)"
else
  echo "skip core/wasm with $WASM_CC: no wasm32 target"
fi
if [ -n "$EIDER" ]; then
  for f in tests/wasm/*.ei compiler/tests/wasm/*.ei; do
    $EIDER emit-c --wasm "$f" >$T/gen.c 2>$T/e || { echo "FAIL emit-c --wasm $f:"; cat $T/e; fail=1; continue; }
    # export_name is a wasm-only attribute the host compiler does not know
    if host $gen -Wno-attributes $T/gen.c 2>$T/e; then
      echo "ok   emit-c --wasm $f: freestanding C ($CC -fsyntax-only -nostdinc)"
    else
      echo "FAIL emit-c --wasm $f with $CC:"; head -20 $T/e; fail=1
    fi
  done
fi
rm -rf $T
exit $fail
