#!/bin/sh
# Benchmarks for the compiler and the code it generates (docs/compiler.md, "C8.1:
# copy-on-write"). For each compiler given (default: target/eiderc-next, the compiler built
# from compiler/ by scripts/test-compiler.sh; give a baseline first to compare against it):
#
#   tests/bench/*.ei   built with `eiderc build` (-O2), run REPS times; the median wall time
#                      is printed, and every compiler's program must print the same output
#   self               `eiderc emit-llvm compiler/main.ei` (the compiler's own front end and
#                      lowering, the part of a build that is Eider code), median of REPS
#
#   sh scripts/bench.sh [eiderc[:root] ...]        REPS=5 by default
#   PROFILE=1 sh scripts/bench.sh [...]             also one profile per benchmark and compiler
#
# PROFILE=1 builds each benchmark (and the compiler, for `self`) again with `--profile`
# (docs/runtime.md "Profiler"), runs it once and writes $PROFILE_DIR/<benchmark>.<n>.prof
# (default target/bench-prof; n is the compiler's position in the arguments), for
# `eider-profiler report` and, with a baseline compiler first, `eider-profiler diff`. The
# times above are of the unprofiled builds. A compiler without --profile (the seed) is skipped.
#
# `root` is the toolchain directory the compiler takes its core from (EIDER_ROOT; default
# the checkout), so a baseline compiler is measured with the core it was built for, e.g.
# the core of an older revision extracted (`git archive`) under target/before:
#   sh scripts/bench.sh target/eiderc-before:target/before target/eiderc-next
#
# Wall time is from `date +%s%N` (GNU date; development tooling, LAYERS.md). Programs are
# built with EIDER_CACHE=off so no cache is involved.
cd "$(dirname "$0")/.." || exit 1
REPS=${REPS:-5}
EIDER_CACHE=off
export EIDER_CACHE
if [ $# -eq 0 ]; then set -- target/eiderc-next; fi
here=$(pwd)
bin() { echo "${1%%:*}"; }
root() { case $1 in *:*) (cd "${1#*:}" && pwd) ;; *) echo "$here" ;; esac; }
# ec SPEC ARGS...: runs compiler SPEC (binary[:root]) with its toolchain root
ec() { s=$1; shift; EIDER_ROOT=$(root "$s") "$(bin "$s")" "$@"; }
for c in "$@"; do
  [ -x "$(bin "$c")" ] || { echo "bench: no compiler at $(bin "$c") (build one: sh scripts/test-compiler.sh)"; exit 1; }
done
case $(date +%N) in
  *N*|'') echo "bench: needs a date with %N (nanoseconds)"; exit 1 ;;
esac
tmp=target/tmp/bench
rm -rf "$tmp"
mkdir -p "$tmp"

now() { date +%s%N; }

# median CMD...: runs CMD REPS times (output to $tmp/out), prints the median in ms
median() {
  : > "$tmp/times"
  r=0
  while [ $r -lt "$REPS" ]; do
    t0=$(now)
    "$@" > "$tmp/out" 2>&1 || echo "FAIL" >> "$tmp/times"
    t1=$(now)
    echo $(( (t1 - t0) / 1000000 )) >> "$tmp/times"
    r=$((r + 1))
  done
  if grep -q FAIL "$tmp/times"; then echo "failed"; return; fi
  sort -n "$tmp/times" | sed -n "$(( (REPS + 1) / 2 ))p"
}

printf '%-16s' "benchmark"
for c in "$@"; do printf ' %16s' "$(basename "$(bin "$c")")"; done
echo
fail=0
for f in tests/bench/*.ei; do
  n=$(basename "$f" .ei)
  printf '%-16s' "$n"
  i=0
  for c in "$@"; do
    i=$((i + 1))
    if ! ec "$c" build "$f" -o "$tmp/$n.$i" > "$tmp/build.log" 2>&1; then
      printf ' %16s' "build failed"; fail=1; continue
    fi
    ms=$(median "$tmp/$n.$i")
    cp "$tmp/out" "$tmp/$n.$i.out"
    if [ $i -gt 1 ] && ! cmp -s "$tmp/$n.1.out" "$tmp/$n.$i.out"; then
      ms="$ms (output differs)"; fail=1
    fi
    printf ' %13s ms' "$ms"
  done
  echo
done
printf '%-16s' "self (emit-llvm)"
for c in "$@"; do
  ms=$(median ec "$c" emit-llvm compiler/main.ei)
  printf ' %13s ms' "$ms"
done
echo
lines=$(ec "$1" emit-llvm compiler/main.ei | wc -l)
echo "(self: $(cat compiler/*.ei | wc -l) lines of Eider -> $lines lines of LLVM IR; $REPS runs each, median wall time)"
if [ -n "$PROFILE" ]; then
  pdir=${PROFILE_DIR:-target/bench-prof}
  mkdir -p "$pdir"
  i=0
  for c in "$@"; do
    i=$((i + 1))
    if ! ec "$c" build "$(ls tests/bench/*.ei | head -1)" --profile -o "$tmp/probe" > "$tmp/build.log" 2>&1; then
      echo "profile: $(bin "$c") can't build with --profile, skipped"; continue
    fi
    for f in tests/bench/*.ei; do
      n=$(basename "$f" .ei)
      ec "$c" build "$f" --profile -o "$tmp/$n.p$i" > "$tmp/build.log" 2>&1 && EIDER_PROF="$pdir/$n.$i.prof" "$tmp/$n.p$i" > /dev/null 2>&1 || { echo "profile: $n failed with $(bin "$c")"; fail=1; }
    done
    ec "$c" build compiler/main.ei --profile -o "$tmp/eiderc.p$i" > "$tmp/build.log" 2>&1 && EIDER_ROOT=$(root "$c") EIDER_PROF="$pdir/self.$i.prof" "$tmp/eiderc.p$i" emit-llvm compiler/main.ei > /dev/null 2>&1 || { echo "profile: self failed with $(bin "$c")"; fail=1; }
  done
  echo "profiles: $pdir/<benchmark>.<n>.prof (eider-profiler report <file>; eider-profiler diff <a> <b>)"
fi
exit $fail
