#!/bin/sh
# The LLVM backend's ABI and debug-info tests (docs/compiler.md, "Backends"): abi.ei as a
# library (`build --lib`, every function native, checked with `emit-llvm --coverage`), linked
# into abi_consumer.c by $CC, must print abi.out. Exercises the System V x86-64 classifier
# (llvm_abi.ei) on records of mixed field types passed and returned by value, from C into LLVM
# IR (the export wrappers) and from LLVM IR into C (eq_ glue). Then every function of the run
# tests and of the compiler itself must be native (no fallback to C), and -g must describe
# dwarf.ei's variables and types.
# usage: run.sh <eiderc>; exits 2 (a skip) without clang 17+.
cd "$(dirname "$0")/../../.." || exit 1
E=${1:-target/eiderc-next}
CC=${CC:-cc}
LCC=${EIDER_LLVM_CC:-clang}
command -v "$LCC" >/dev/null 2>&1 || { echo "skip: no clang"; exit 2; }
T=target/llvmabi
rm -rf $T
mkdir -p $T
# all_native <what> <emit-llvm args...>: `native N/N functions`
all_native() {
  what=$1; shift
  cov=$($E emit-llvm --coverage "$@" 2>&1 | head -1)
  case "$cov" in "native "*) n=${cov#native }; n=${n% functions}; [ "${n%/*}" = "${n#*/}" ] || { echo "FAIL $what is not all native: $cov"; exit 1; } ;; *) echo "FAIL emit-llvm --coverage $*: $cov"; exit 1 ;; esac
}
all_native abi.ei --lib compiler/tests/llvm/abi.ei
nabi=$n
EIDER_CACHE=off $E build --lib compiler/tests/llvm/abi.ei -o $T/abi >$T/build.log 2>&1 || { echo "FAIL build --lib abi.ei"; cat $T/build.log; exit 1; }
$CC -std=c11 -Wall -Werror -I$T -o $T/consumer compiler/tests/llvm/abi_consumer.c $T/libabi.a || { echo "FAIL link abi_consumer.c"; exit 1; }
$T/consumer >$T/abi.out 2>&1 || { echo "FAIL run abi_consumer"; cat $T/abi.out; exit 1; }
cmp -s $T/abi.out compiler/tests/llvm/abi.out || { echo "FAIL abi:"; diff compiler/tests/llvm/abi.out $T/abi.out; exit 1; }
echo "ok   llvm abi: records of mixed field types by value between C and LLVM IR ($nabi functions native; registers, coercion, byval, sret)"
# coverage: nothing falls back to C, in the run tests (also with their test drivers) and in
# the compiler
tot=0; files=0
for f in tests/run/*.ei compiler/tests/run/*.ei; do
  case "$($E check --json "$f" 2>&1)" in *'"error":"unsupported"'*) continue ;; esac
  all_native "$f" "$f"; tot=$((tot + ${n%/*}))
  if grep -q '^test ' "$f"; then all_native "$f (--test)" --test "$f"; tot=$((tot + ${n%/*})); fi
  files=$((files + 1))
done
all_native compiler/main.ei compiler/main.ei
echo "ok   llvm coverage: every function native ($files run tests, $tot functions; compiler/main.ei, $n)"
# DWARF variables and types (-g, at -O0 so nothing is optimized away): every parameter, local,
# member and type name of dwarf.ei in the debug info (llvm-dwarfdump, else readelf)
EIDER_CACHE=off EIDER_CFLAGS=-O0 $E build -g compiler/tests/llvm/dwarf.ei -o $T/dwarf >$T/dwarf.log 2>&1 || { echo "FAIL build -g dwarf.ei"; cat $T/dwarf.log; exit 1; }
[ "$($T/dwarf | tr "\n" " ")" = "48 true " ] || { echo "FAIL run dwarf.ei"; exit 1; }
if command -v llvm-dwarfdump >/dev/null 2>&1; then
  llvm-dwarfdump --debug-info $T/dwarf >$T/dwarf.txt 2>&1
elif command -v readelf >/dev/null 2>&1; then
  readelf --debug-dump=info $T/dwarf >$T/dwarf.txt 2>/dev/null
else
  echo "skip llvm dwarf: no llvm-dwarfdump or readelf"; rm -rf $T; exit 0
fi
for v in shape_arg scale_arg acc_total origin_pt names_list flag_ok Point px py Shape Circle centre radius len cap; do
  grep -Eq "(: |\")$v(\"|\$)" $T/dwarf.txt || { echo "FAIL llvm dwarf: no '$v' in the debug info"; exit 1; }
done
grep -q "DW_TAG_formal_parameter" $T/dwarf.txt && grep -q "DW_OP_fbreg" $T/dwarf.txt || { echo "FAIL llvm dwarf: no parameter with a frame location"; exit 1; }
rm -rf $T
echo "ok   llvm dwarf: -g describes parameters, locals and their types (records, enums, List, String) with frame locations"
