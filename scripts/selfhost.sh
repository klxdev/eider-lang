#!/bin/sh
# Self-hosting (docs/compiler.md, "Bootstrap chain"; seed/README.md).
#
#   scripts/selfhost.sh              stage0 -> stage1 -> stage2; check the fixed points (stage1
#                                    and stage2 emit byte-identical LLVM IR for compiler/, and
#                                    build byte-identical seeds), that stage2 frees everything
#                                    it allocates while compiling compiler/
#                                    (-DEI_RT_COUNT_ALLOCS), then run scripts/test-compiler.sh
#                                    against stage2
#   scripts/selfhost.sh --seed       ...and write stage2's seed to seed/eiderc.wasm (and the
#                                    clang that built it to seed/eiderc.wasm.clang)
#   scripts/selfhost.sh --from-seed  build stage0 from the seed with only a C compiler and check
#                                    it (`check compiler/main.ei`); with clang 17+, check that
#                                    the seed is current: stage0 and the compiler it builds
#                                    emit the same LLVM IR for compiler/, which rebuilds the
#                                    seed byte for byte when clang is the one that built it
#
# stage0 is the seed: cc seed/wasm2c.c, wasm2c seed/eiderc.wasm -> C, cc that C with
# core/eider_core.c (only a C compiler). stage1 is compiler/ built natively by stage0, stage2
# compiler/ built by stage1 (they need clang 17+: the floor stays 17; clang 17, 20, 22 and 23
# are tested, scripts/clang-matrix.sh). The seed is `build --wasm-core
# compiler/main.ei`. Outputs go to target/selfhost/; each step prints its time.
cd "$(dirname "$0")/.." || exit 1
root=$(pwd)
out=target/selfhost
mkdir -p "$out"
EIDER_ROOT=$root; export EIDER_ROOT
EIDER_CACHE=off; export EIDER_CACHE
CC=${CC:-cc}
LCC=${EIDER_LLVM_CC:-clang}
src=compiler/main.ei

now() { date +%s%N; }
t0=0
step() { printf '%-48s' "$1"; t0=$(now); }
ok() { echo "ok ($(( ($(now) - t0) / 1000000 )) ms)"; }
die() { echo "FAIL"; [ -n "$2" ] && sed 's/^/    /' "$2" | head -40; echo "selfhost: $1"; exit 1; }
has_clang() {
  major=$("$LCC" --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9]*\)\..*/\1/p' | head -1)
  [ -n "$major" ] && [ "$major" -ge 17 ]
}
clang_id() { "$LCC" --version 2>/dev/null | head -1; }

stage0() {
  [ -f seed/eiderc.wasm ] || { echo "selfhost: no seed/eiderc.wasm (run scripts/selfhost.sh --seed first)"; exit 1; }
  step "stage0: cc seed/wasm2c.c"
  "$CC" -std=c11 -O2 -pedantic -Wall -Wextra -Werror -o "$out/wasm2c" seed/wasm2c.c 2>"$out/cc.log" || die "cc failed on seed/wasm2c.c" "$out/cc.log"
  ok
  step "stage0: wasm2c seed/eiderc.wasm"
  "$out/wasm2c" seed/eiderc.wasm -o "$out/stage0.c" 2>"$out/err.log" || die "wasm2c failed" "$out/err.log"
  ok
  step "stage0: cc the C with core/eider_core.c"
  "$CC" -std=c11 -O1 -w -pthread -o "$out/stage0" "$out/stage0.c" core/eider_core.c 2>"$out/cc.log" || die "cc failed on the seed's C" "$out/cc.log"
  ok
  step "stage0 checks compiler/"
  "$out/stage0" check "$src" >"$out/check.log" 2>&1 || die "stage0 could not check compiler/" "$out/check.log"
  ok
}

# a stage: compiler/ built natively by the compiler $1, into $2
native() {
  "$1" build "$src" -o "$2" >"$out/err.log" 2>&1 || die "$1 could not build compiler/" "$out/err.log"
}

if [ "$1" = "--from-seed" ]; then
  stage0
  if ! has_clang; then echo "skip: no clang 17+ ($LCC): stage0 can't build compiler/, so the seed's currency is not checked"; exit 0; fi
  step "stage1: stage0 builds compiler/"
  native "$out/stage0" "$out/stage1"
  ok
  step "the seed is current: stage0.ll == stage1.ll"
  "$out/stage0" emit-llvm "$src" >"$out/stage0.ll" 2>"$out/err.log" || die "stage0 emit-llvm failed" "$out/err.log"
  "$out/stage1" emit-llvm "$src" >"$out/stage1.ll" 2>"$out/err.log" || die "stage1 emit-llvm failed" "$out/err.log"
  cmp -s "$out/stage0.ll" "$out/stage1.ll" || die "seed/eiderc.wasm is stale: it emits other IR than compiler/ (re-run scripts/selfhost.sh --seed)"
  ok
  if [ "$(clang_id)" = "$(cat seed/eiderc.wasm.clang 2>/dev/null)" ]; then
    step "stage1 rebuilds seed/eiderc.wasm byte for byte"
    "$out/stage1" build --wasm-core "$src" -o "$out/seed.wasm" >"$out/err.log" 2>&1 || die "stage1 build --wasm-core failed" "$out/err.log"
    cmp -s "$out/seed.wasm" seed/eiderc.wasm || die "stage1 builds another seed/eiderc.wasm with the same clang (re-run scripts/selfhost.sh --seed)"
    ok
  else
    echo "skip: rebuilding seed/eiderc.wasm byte for byte needs $(cat seed/eiderc.wasm.clang 2>/dev/null || echo 'the clang in seed/eiderc.wasm.clang'), not $(clang_id)"
  fi
  exit 0
fi

stage0
has_clang || die "stage1 needs clang 17 or newer ($LCC; set EIDER_LLVM_CC)"
step "stage1: stage0 builds compiler/"
native "$out/stage0" "$out/stage1"
ok
step "stage2: stage1 builds compiler/"
native "$out/stage1" "$out/stage2"
ok
step "fixed point: stage1.ll == stage2.ll"
"$out/stage1" emit-llvm "$src" >"$out/stage1.ll" 2>"$out/err.log" || die "stage1 emit-llvm failed" "$out/err.log"
"$out/stage2" emit-llvm "$src" >"$out/stage2.ll" 2>"$out/err.log" || die "stage2 emit-llvm failed" "$out/err.log"
cmp -s "$out/stage1.ll" "$out/stage2.ll" || { diff "$out/stage1.ll" "$out/stage2.ll" > "$out/fixed-point.diff"; die "stage1 and stage2 emit different LLVM IR" "$out/fixed-point.diff"; }
ok
step "the seed: stage1 and stage2 build the same"
"$out/stage1" build --wasm-core "$src" -o "$out/stage1.wasm" >"$out/err.log" 2>&1 || die "stage1 build --wasm-core failed" "$out/err.log"
"$out/stage2" build --wasm-core "$src" -o "$out/stage2.wasm" >"$out/err.log" 2>&1 || die "stage2 build --wasm-core failed" "$out/err.log"
cmp -s "$out/stage1.wasm" "$out/stage2.wasm" || die "stage1 and stage2 build different seeds"
ok
step "stage2 leaks nothing (compiler/)"
# the runtime's allocation counter (core/RUNTIME.md, ei_check_leaks)
EIDER_CFLAGS=-DEI_RT_COUNT_ALLOCS "$out/stage1" build "$src" -o "$out/stage2-count" >"$out/err.log" 2>&1 || die "could not build the counting stage2" "$out/err.log"
"$out/stage2-count" emit-llvm "$src" > "$out/count.ll" 2>"$out/count.log" || die "the counting stage2 could not compile compiler/" "$out/count.log"
cmp -s "$out/count.ll" "$out/stage2.ll" || die "the counting stage2 emits different LLVM IR"
grep -qx 'eider: outstanding allocations: 0' "$out/count.log" || die "allocations left over" "$out/count.log"
ok
step "stage2 passes scripts/test-compiler.sh"
EIDERC="$root/$out/stage2" sh scripts/test-compiler.sh > "$out/tests.log" 2>&1 || die "test failures" "$out/tests.log"
grep -q FAIL "$out/tests.log" && die "test failures" "$out/tests.log"
ok
if [ "$1" = "--seed" ]; then
  cp "$out/stage2.wasm" seed/eiderc.wasm
  clang_id > seed/eiderc.wasm.clang
  echo "wrote seed/eiderc.wasm ($(wc -c < seed/eiderc.wasm) bytes, built by $(clang_id))"
fi
echo "SELF-HOSTED"
