#!/bin/sh
# The LLVM backend against the C backend (docs/compiler.md, "Backends"): for each
# tests/bench/*.ei and for the compiler itself (compiler/main.ei),
#
#   front   `eiderc emit-c` vs `eiderc emit-llvm` (the Eider part of a build: front end and
#           lowering; emit-llvm also writes the C half)
#   build   `eiderc build` vs `eiderc build --backend=llvm` at -O0 and -O2 (EIDER_CFLAGS=-O0
#           applies to both halves), with CC=clang for both, so the same compiler does the work
#   run     the -O2 binaries, REPS times each; their output must be identical
#
#   sh scripts/llvm-bench.sh            REPS=5; EIDERC (default target/eiderc-next)
#
# Median wall times in ms (`date +%s%N`), EIDER_CACHE=off. `self` runs the built compilers on
# `emit-c compiler/main.ei`.
cd "$(dirname "$0")/.." || exit 1
REPS=${REPS:-5}
E=${EIDERC:-target/eiderc-next}
EIDER_CACHE=off; export EIDER_CACHE
EIDER_ROOT=$(pwd); export EIDER_ROOT
CC=${LLVM_BENCH_CC:-clang}; export CC
tmp=target/tmp/llvm-bench
rm -rf "$tmp"; mkdir -p "$tmp"
now() { date +%s%N; }
median() {
  : > "$tmp/times"
  r=0
  while [ $r -lt "$REPS" ]; do
    t0=$(now)
    "$@" > "$tmp/out" 2>&1 || echo FAIL >> "$tmp/times"
    t1=$(now)
    echo $(( (t1 - t0) / 1000000 )) >> "$tmp/times"
    r=$((r + 1))
  done
  if grep -q FAIL "$tmp/times"; then echo failed; return; fi
  sort -n "$tmp/times" | sed -n "$(( (REPS + 1) / 2 ))p"
}
fail=0
echo "compile time (ms; median of $REPS)"
printf '%-14s %8s %8s %10s %10s %10s %10s\n' program emit-c emit-ll "C -O0" "LLVM -O0" "C -O2" "LLVM -O2"
for f in tests/bench/*.ei compiler/main.ei; do
  n=$(basename "$f" .ei); [ "$f" = compiler/main.ei ] && n=self
  a=$(median "$E" emit-c "$f")
  b=$(median "$E" emit-llvm "$f")
  c0=$(median env EIDER_CFLAGS=-O0 "$E" build "$f" -o "$tmp/$n.c0")
  l0=$(median env EIDER_CFLAGS=-O0 "$E" build --backend=llvm "$f" -o "$tmp/$n.l0")
  c2=$(median "$E" build "$f" -o "$tmp/$n.c2")
  l2=$(median "$E" build --backend=llvm "$f" -o "$tmp/$n.l2")
  printf '%-14s %8s %8s %10s %10s %10s %10s\n' "$n" "$a" "$b" "$c0" "$l0" "$c2" "$l2"
done
echo
echo "run time of the -O2 binaries (ms; median of $REPS)"
printf '%-14s %10s %10s %8s\n' program C LLVM "LLVM/C"
for f in tests/bench/*.ei compiler/main.ei; do
  n=$(basename "$f" .ei); [ "$f" = compiler/main.ei ] && n=self
  if [ $n = self ]; then
    tc=$(median "$tmp/self.c2" emit-c compiler/main.ei); cp "$tmp/out" "$tmp/self.c.out"
    tl=$(median "$tmp/self.l2" emit-c compiler/main.ei); cp "$tmp/out" "$tmp/self.l.out"
    cmp -s "$tmp/self.c.out" "$tmp/self.l.out" || { tl="$tl (differs)"; fail=1; }
  else
    tc=$(median "$tmp/$n.c2"); cp "$tmp/out" "$tmp/$n.c.out"
    tl=$(median "$tmp/$n.l2"); cp "$tmp/out" "$tmp/$n.l.out"
    cmp -s "$tmp/$n.c.out" "$tmp/$n.l.out" || { tl="$tl (differs)"; fail=1; }
  fi
  ratio=$(awk -v a="$tc" -v b="${tl%% *}" 'BEGIN { if (a > 0) printf "%.2f", b / a; else print "-" }')
  printf '%-14s %10s %10s %8s\n' "$n" "$tc" "$tl" "$ratio"
done
exit $fail
