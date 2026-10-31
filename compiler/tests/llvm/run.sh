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
rm -rf $T
echo "ok   llvm abi: records of mixed field types by value between C and LLVM IR ($n functions native; registers, coercion, byval, sret)"
