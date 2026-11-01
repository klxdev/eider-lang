#!/bin/sh
# seed/wasm2c.c's tests (seed/README.md; verify.sh's seed leg):
#   strict    wasm2c builds with -std=c11 -pedantic -Wall -Wextra -Werror ($CC, and clang)
#   seed      wasm2c built with ASan+UBSan translates seed/eiderc.wasm to the same C as the plain
#             build; that C compiles warning-free (-pedantic -Wall -Wextra -Werror), and stage0
#             built from it with ASan+UBSan checks compiler/main.ei and emits the same LLVM IR
#             as the plain stage0 (no undefined behaviour in the translation on that run)
#   ops       (clang with wasm32) seed/tests/ops.c as a module and natively print the same, and
#             its traps are reported as `wasm trap: ...`, exit 134
#   core      (clang with wasm32, and eiderc $1, default target/eiderc) compiler/tests/wasm/core/
#             prog.ei as a core module (`build --wasm-core`) through wasm2c gives prog.out:
#             arguments, environment, files, a child process, stdout and stderr, a trap's 101
#   fuzz      seed/tests/fuzz.sh with N=${FUZZ_N:-300} mutants of the seed
# Each line is ok/FAIL/skip; exit 1 on a FAIL.
cd "$(dirname "$0")/../.." || exit 1
root=$(pwd)
E=${1:-target/eiderc}
case "$E" in /*) ;; *) E=$root/$E ;; esac
CC=${CC:-cc}
T=target/seedtest
rm -rf $T
mkdir -p $T
fail=0
f() { echo "FAIL $1"; [ -n "$2" ] && head -20 "$2"; fail=1; }
strict="-std=c11 -pedantic -Wall -Wextra -Werror"
"$CC" $strict -O2 -o $T/wasm2c seed/wasm2c.c 2>$T/e || f "wasm2c with $CC $strict" $T/e
if command -v clang >/dev/null 2>&1; then
  clang $strict -O2 -o $T/wasm2c-clang seed/wasm2c.c 2>$T/e || f "wasm2c with clang $strict" $T/e
fi
[ $fail = 0 ] && echo "ok   wasm2c: $(wc -l < seed/wasm2c.c) lines of C11, warning-free under $strict"
# sanitizers: the C compiler that links ASan+UBSan here
san=""
printf 'int main(void){return 0;}\n' >$T/p.c
for c in "$CC" clang gcc; do
  if command -v $c >/dev/null 2>&1 && $c -fsanitize=address,undefined -o $T/p $T/p.c 2>/dev/null && $T/p; then san=$c; break; fi
done
"$T/wasm2c" seed/eiderc.wasm -o $T/stage0.c 2>$T/e || f "wasm2c seed/eiderc.wasm" $T/e
"$CC" $strict -fsyntax-only $T/stage0.c 2>$T/e || f "the seed's C is not warning-free ($strict)" $T/e
"$CC" -std=c11 -O1 -w -pthread -o $T/stage0 $T/stage0.c core/eider_core.c 2>$T/e || f "cc the seed's C" $T/e
EIDER_ROOT=$root $T/stage0 emit-llvm compiler/main.ei >$T/plain.ll 2>$T/e || f "stage0 emit-llvm compiler/main.ei" $T/e
if [ -n "$san" ]; then
  sf="-fsanitize=address,undefined -fno-sanitize-recover=all"
  $san -std=c11 -O1 -g $sf -o $T/wasm2c-san seed/wasm2c.c 2>$T/e || f "wasm2c with $sf" $T/e
  ASAN_OPTIONS=detect_leaks=0 $T/wasm2c-san seed/eiderc.wasm -o $T/stage0-san.c 2>$T/e || f "wasm2c under $sf" $T/e
  cmp -s $T/stage0.c $T/stage0-san.c || f "wasm2c under $sf translates differently"
  $san -std=c11 -O1 -w $sf -pthread -o $T/stage0-san $T/stage0.c core/eider_core.c 2>$T/e || f "cc the seed's C with $sf" $T/e
  EIDER_ROOT=$root ASAN_OPTIONS=detect_leaks=0 $T/stage0-san check compiler/main.ei >$T/o 2>&1 || f "stage0 under $sf: check compiler/main.ei" $T/o
  EIDER_ROOT=$root ASAN_OPTIONS=detect_leaks=0 $T/stage0-san emit-llvm compiler/main.ei >$T/san.ll 2>$T/e || f "stage0 under $sf: emit-llvm" $T/e
  cmp -s $T/plain.ll $T/san.ll || f "stage0 under $sf emits other IR"
  [ $fail = 0 ] && echo "ok   wasm2c seed: seed/eiderc.wasm ($(wc -c < seed/eiderc.wasm) bytes) -> $(wc -c < $T/stage0.c) bytes of warning-free C; wasm2c and stage0 clean under ASan+UBSan (check and emit-llvm of compiler/main.ei)"
else
  echo "skip wasm2c seed under sanitizers: no C compiler here links ASan+UBSan"
fi
# modules built here: clang with the wasm32 target and wasm-ld
WCC=${WASM_CC:-clang}
printf 'int x;\n' >$T/w.c
if $WCC --target=wasm32 -c -o $T/w.o $T/w.c 2>/dev/null && command -v wasm-ld >/dev/null 2>&1; then
  feats="--target=wasm32-unknown-unknown -mcpu=mvp -msign-ext -mbulk-memory -mmutable-globals"
  $WCC $feats -O2 -nostdlib -Wl,--no-entry -Wl,--allow-undefined -Wl,-z,stack-size=1048576 -o $T/ops.wasm seed/tests/ops.c 2>$T/e || f "clang ops.c for wasm32" $T/e
  $T/wasm2c $T/ops.wasm -o $T/ops.c 2>$T/e || f "wasm2c ops.wasm" $T/e
  "$CC" -std=c11 -O1 -pthread -o $T/ops $T/ops.c core/eider_core.c 2>$T/e || f "cc ops.c's translation" $T/e
  "$CC" -std=c11 -O1 -w -pthread -o $T/ops-native seed/tests/ops.c core/eider_core.c 2>$T/e || f "cc ops.c natively" $T/e
  $T/ops >$T/w.out 2>&1 || f "ops (translated) exits $?" $T/w.out
  $T/ops-native >$T/n.out 2>&1
  cmp -s $T/w.out $T/n.out || { f "ops: the translation prints other values than the native build"; diff $T/n.out $T/w.out | head; }
  nt=0
  for t in div0:"integer divide by zero" rem0:"integer divide by zero" ovf:"integer overflow" oob:"out of bounds memory access" stack:"out of bounds memory access" calls:"call stack exhausted" unreachable:unreachable; do
    $T/ops "${t%%:*}" >$T/o 2>&1
    code=$?
    if [ $code = 134 ] && grep -qx "wasm trap: ${t#*:}" $T/o; then nt=$((nt + 1)); else f "ops ${t%%:*}: exit $code, $(head -1 $T/o)"; fi
  done
  [ $fail = 0 ] && echo "ok   wasm2c ops: i32/i64 arithmetic, comparisons, shifts, rotations, bit counts, sign extension, br_table, call_indirect, memory.copy/fill/grow, unaligned access agree with the native build; $nt traps reported"
  if [ -x "$E" ]; then
    mkdir -p $T/d
    "$E" build --wasm-core compiler/tests/wasm/core/prog.ei -o $T/prog.wasm >$T/e 2>&1 || f "build --wasm-core prog.ei" $T/e
    $T/wasm2c $T/prog.wasm -o $T/prog.c 2>$T/e || f "wasm2c prog.wasm" $T/e
    "$CC" -std=c11 -O1 -w -pthread -o $T/prog $T/prog.c core/eider_core.c 2>$T/e || f "cc prog's translation" $T/e
    EIDER_CORE_TEST=yes $T/prog $T/d a b >$T/o 2>&1
    echo "exit $?" >>$T/o
    if cmp -s $T/o compiler/tests/wasm/core/prog.out; then
      echo "ok   wasm2c core module: compiler/tests/wasm/core/prog.ei (args, env, files, a child process, stdout/stderr, a trap) gives prog.out"
    else
      f "core module prog.ei:"; diff compiler/tests/wasm/core/prog.out $T/o | head -20
    fi
  else
    echo "skip wasm2c core module: no compiler at $E"
  fi
else
  echo "skip wasm2c ops and core module: needs $WCC with the wasm32 target and wasm-ld"
fi
if [ -n "$san" ] && command -v python3 >/dev/null 2>&1; then
  N=${FUZZ_N:-300} M=${FUZZ_M:-3} CC=$san sh seed/tests/fuzz.sh >$T/fuzz 2>&1 || f "fuzz" $T/fuzz
  grep "^ok" $T/fuzz
else
  echo "skip wasm2c fuzz: needs python3 and a C compiler with ASan+UBSan"
fi
exit $fail
