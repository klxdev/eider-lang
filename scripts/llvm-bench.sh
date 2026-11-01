#!/bin/sh
# Compile and run times of the LLVM backend (docs/compiler.md, "Backends"): for each
# tests/bench/*.ei and for the compiler itself (compiler/main.ei),
#
#   emit    `eiderc emit-llvm` (the Eider part of a build: front end and lowering)
#   build   `eiderc build` at -O0 (EIDER_CFLAGS=-O0) and at -O2 (with LTO when clang has lld)
#   run     the -O2 binary, REPS times (`self` runs the built compiler on
#           `emit-llvm compiler/main.ei`)
#
#   sh scripts/llvm-bench.sh            REPS=5; EIDERC (default target/eiderc-next)
#
# Median wall times in ms (`date +%s%N`), EIDER_CACHE=off.
cd "$(dirname "$0")/.." || exit 1
REPS=${REPS:-5}
E=${EIDERC:-target/eiderc-next}
EIDER_CACHE=off; export EIDER_CACHE
EIDER_ROOT=$(pwd); export EIDER_ROOT
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
echo "times in ms (median of $REPS)"
printf '%-14s %8s %10s %10s %10s\n' program emit "build -O0" "build -O2" "run -O2"
for f in tests/bench/*.ei compiler/main.ei; do
  n=$(basename "$f" .ei); [ "$f" = compiler/main.ei ] && n=self
  a=$(median "$E" emit-llvm "$f")
  b0=$(median env EIDER_CFLAGS=-O0 "$E" build "$f" -o "$tmp/$n.o0")
  b2=$(median "$E" build "$f" -o "$tmp/$n.o2")
  if [ $n = self ]; then r=$(median "$tmp/self.o2" emit-llvm compiler/main.ei); else r=$(median "$tmp/$n.o2"); fi
  printf '%-14s %8s %10s %10s %10s\n' "$n" "$a" "$b0" "$b2" "$r"
done
