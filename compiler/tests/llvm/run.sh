#!/bin/sh
# The LLVM backend's ABI test (docs/compiler.md, "Backends"): abi.ei as a library, built by the
# C backend and by `--backend=llvm` (every function native, checked with `emit-llvm
# --coverage`), each linked into abi_consumer.c by $CC; both must print abi.out. Exercises the
# System V x86-64 classifier (llvm_abi.ei) on records of mixed field types passed and returned
# by value, from C into LLVM IR (the export wrappers) and from LLVM IR into C (eq_ glue).
# usage: run.sh <eiderc>; exits 2 (a skip) without clang 17+.
cd "$(dirname "$0")/../../.." || exit 1
E=${1:-target/eiderc-next}
CC=${CC:-cc}
LCC=${EIDER_LLVM_CC:-clang}
command -v "$LCC" >/dev/null 2>&1 || { echo "skip: no clang"; exit 2; }
T=target/llvmabi
rm -rf $T
mkdir -p $T
cov=$($E emit-llvm --lib --coverage compiler/tests/llvm/abi.ei | head -1)
case "$cov" in "native "*) n=${cov#native }; n=${n% functions}; [ "${n%/*}" = "${n#*/}" ] || { echo "FAIL abi.ei is not all native: $cov"; exit 1; } ;; *) echo "FAIL emit-llvm --coverage: $cov"; exit 1 ;; esac
for b in c llvm; do
  mkdir -p $T/$b
  EIDER_CACHE=off $E build --lib --backend=$b compiler/tests/llvm/abi.ei -o $T/$b/abi >$T/$b.log 2>&1 || { echo "FAIL build --lib --backend=$b"; cat $T/$b.log; exit 1; }
  $CC -std=c11 -Wall -Werror -I$T/$b -o $T/$b/consumer compiler/tests/llvm/abi_consumer.c $T/$b/libabi.a || { echo "FAIL link ($b)"; exit 1; }
  $T/$b/consumer >$T/$b.out 2>&1 || { echo "FAIL run ($b)"; cat $T/$b.out; exit 1; }
  cmp -s $T/$b.out compiler/tests/llvm/abi.out || { echo "FAIL abi ($b backend):"; diff compiler/tests/llvm/abi.out $T/$b.out; exit 1; }
done
echo "ok   llvm abi: records of mixed field types by value between C and LLVM IR ($n functions native; registers, coercion, byval, sret)"
# DWARF variables and types (-g, at -O0 so nothing is optimized away): every parameter, local,
# member and type name of dwarf.ei in the debug info (llvm-dwarfdump, else readelf)
EIDER_CACHE=off EIDER_CFLAGS=-O0 $E build --backend=llvm -g compiler/tests/llvm/dwarf.ei -o $T/dwarf >$T/dwarf.log 2>&1 || { echo "FAIL build -g dwarf.ei"; cat $T/dwarf.log; exit 1; }
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
