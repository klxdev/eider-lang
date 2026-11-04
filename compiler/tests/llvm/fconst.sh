#!/bin/sh
# Float constants in the IR, in both spellings (compiler/llvm.ei "floating point"; #168):
# the hex double and `bitcast (i32 .. to float)` every LLVM since 17 reads, and LLVM 23's
# `f0x<bits>`. The driver picks from the clang that builds the IR (driver.llvm_f0x), and
# EIDER_LLVM_FLOAT=hex|f0x forces one.
#   1. fconst.ei (zeros, subnormals, extremes, f32 values, the 2^n a float-to-integer
#      conversion compares with) is built and run with the hex spelling: fconst.out. With a
#      clang of LLVM 23 or newer the f0x spelling runs too and must print the same, and the
#      default (no EIDER_LLVM_FLOAT) must pick f0x; with an older clang the default must pick
#      hex, and the f0x text must be rejected (the version the choice is made from is right).
#   2. With clang 23 or newer, one module of hand-written constants (inf, NaN with payloads,
#      -0, subnormals, f64 and f32) in each spelling must be read by clang as the same module.
# usage: fconst.sh <eiderc>; exits 2 (a skip) without clang.
cd "$(dirname "$0")/../../.." || exit 1
E=${1:-target/eiderc-next}
LCC=${EIDER_LLVM_CC:-clang}
command -v "$LCC" >/dev/null 2>&1 || { echo "skip: no clang"; exit 2; }
major=$("$LCC" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9]*\)\..*/\1/p' | head -1)
T=target/llvmfloat
rm -rf $T
mkdir -p $T
F=compiler/tests/llvm/fconst.ei
EIDER_LLVM_FLOAT=hex EIDER_CACHE=off $E run $F > $T/hex.out 2>&1
cmp -s $T/hex.out compiler/tests/llvm/fconst.out || { echo "FAIL llvm floats: fconst.ei with the hex spelling:"; diff compiler/tests/llvm/fconst.out $T/hex.out | head; exit 1; }
$E emit-llvm $F > $T/default.ll 2>&1
EIDER_LLVM_FLOAT=hex $E emit-llvm $F > $T/hex.ll 2>&1
EIDER_LLVM_FLOAT=f0x $E emit-llvm $F > $T/f0x.ll 2>&1
grep -q "f0x" $T/f0x.ll && ! grep -q "f0x" $T/hex.ll || { echo "FAIL llvm floats: EIDER_LLVM_FLOAT=f0x/hex do not pick their spelling"; exit 1; }
if [ "${major:-0}" -ge 23 ]; then
  grep -q "f0x" $T/default.ll || { echo "FAIL llvm floats: clang $major reads f0x, but the default is the old spelling"; exit 1; }
  EIDER_LLVM_FLOAT=f0x EIDER_CACHE=off $E run $F > $T/f0x.out 2>&1
  cmp -s $T/f0x.out compiler/tests/llvm/fconst.out || { echo "FAIL llvm floats: fconst.ei with the f0x spelling:"; diff compiler/tests/llvm/fconst.out $T/f0x.out | head; exit 1; }
  # the same constants, written by hand, read as one module
  : > $T/c_hex.ll
  : > $T/c_f0x.ll
  n=0
  for b in 3FF0000000000000 7FF0000000000000 FFF0000000000000 7FF8000000000000 7FF8000000000001 FFF4000000000000 8000000000000000 0000000000000000 0000000000000001 000FFFFFFFFFFFFF 7FEFFFFFFFFFFFFF 3FB999999999999A; do
    n=$((n + 1))
    echo "define double @d$n() { ret double 0x$b }" >> $T/c_hex.ll
    echo "define double @d$n() { ret double f0x$b }" >> $T/c_f0x.ll
  done
  for b in 3F800000 7F800000 FF800000 7FC00000 7FC00001 80000000 00000000 00000001 007FFFFF 7F7FFFFF 3DCCCCCD; do
    n=$((n + 1))
    echo "define float @f$n() { ret float bitcast (i32 $((0x$b)) to float) }" >> $T/c_hex.ll
    echo "define float @f$n() { ret float f0x$b }" >> $T/c_f0x.ll
  done
  "$LCC" -S -emit-llvm -O1 -Wno-override-module -x ir $T/c_hex.ll -o $T/c_hex.out.ll 2> $T/c_hex.err || { echo "FAIL llvm floats: clang $major rejects the hex spelling"; cat $T/c_hex.err; exit 1; }
  "$LCC" -S -emit-llvm -O1 -Wno-override-module -x ir $T/c_f0x.ll -o $T/c_f0x.out.ll 2> $T/c_f0x.err || { echo "FAIL llvm floats: clang $major rejects the f0x spelling"; cat $T/c_f0x.err; exit 1; }
  grep -v '^; ModuleID\|^source_filename' $T/c_hex.out.ll > $T/a.txt
  grep -v '^; ModuleID\|^source_filename' $T/c_f0x.out.ll > $T/b.txt
  cmp -s $T/a.txt $T/b.txt || { echo "FAIL llvm floats: clang $major reads the two spellings as different constants:"; diff $T/a.txt $T/b.txt | head; exit 1; }
  rm -rf $T
  echo "ok   llvm floats: clang $major picks f0x; fconst.ei runs the same in both spellings; inf, NaN payloads, -0, subnormals, f64 and f32 constants read the same"
else
  if grep -q "f0x" $T/default.ll; then echo "FAIL llvm floats: the default spelling for clang $major is f0x"; exit 1; fi
  if "$LCC" -c -O0 -Wno-override-module -x ir $T/f0x.ll -o $T/f0x.o > /dev/null 2>&1; then
    echo "FAIL llvm floats: clang $major reads f0x, so F0X_LLVM (compiler/llvm.ei) is too high"; exit 1
  fi
  rm -rf $T
  echo "ok   llvm floats: clang $major gets the hex spelling and rejects f0x (LLVM 23 and newer take it: tested by clang-matrix.sh); fconst.ei runs"
fi
