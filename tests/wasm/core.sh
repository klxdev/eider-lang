#!/bin/sh
# The WebAssembly core (core/wasm/) compiles warning-free as freestanding C under the same
# strict flags as the native core (core/RUNTIME.md):
#   - with the host C compiler, -fsyntax-only, against nothing but core/wasm/include and the
#     compiler's own freestanding headers (-nostdinc), so no libc header can leak in;
#   - with $WASM_CC (default clang) for wasm32, when it has the target (else: skip).
cd "$(dirname "$0")/../.." || exit 1
strict="-std=c11 -pedantic -Wall -Wextra -Wconversion -Wshadow -Werror"
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
rm -rf $T
exit $fail
