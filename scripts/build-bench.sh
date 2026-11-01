#!/bin/sh
# Build times of eiderc itself through the cache (docs/compiler.md, "C8.27: incremental builds",
# "Measurements"). For each compiler given, in a copy of this tree (target/build-bench/tree,
# its own EIDER_ROOT) and on an empty cache per mode: a cold build, a no-op rebuild (median of
# 3), an edit to one compiler module (a message in compiler/diag.ei) and then an edit to one
# std module (a message in std/proc.ei), with `build` (-O2, the release build) and with
# `run -- --version` (-O0, the debug build). $BENCH_FLAGS are added to every eiderc command
# (e.g. `--backend=llvm`, `-j 8`). Prints a markdown table, times in seconds (wall clock).
#
#   sh scripts/build-bench.sh <eiderc> [<eiderc>...]
cd "$(dirname "$0")/.." || exit 1
[ $# -gt 0 ] || { echo "usage: scripts/build-bench.sh <eiderc> [<eiderc>...]"; exit 2; }
here=$(pwd)
B=$here/target/build-bench
rm -rf "$B"
mkdir -p "$B/tree"
cp -R compiler core std VERSION "$B/tree/"
EIDER_ROOT=$B/tree; export EIDER_ROOT
now() { date +%s.%N; }
# secs <command...>: the wall-clock seconds it took (exits on failure)
secs() {
  s=$(now)
  "$@" >"$B/out" 2>&1 || { echo "build-bench: failed: $*" >&2; cat "$B/out" >&2; exit 1; }
  e=$(now)
  awk -v s="$s" -v e="$e" 'BEGIN { printf "%.2f", e - s }'
}
med3() { printf '%s\n%s\n%s\n' "$1" "$2" "$3" | sort -n | sed -n 2p; }
restore() {
  cp compiler/diag.ei "$B/tree/compiler/diag.ei"
  cp std/proc.ei "$B/tree/std/proc.ei"
}
echo "| compiler | build | cold | no-op | edit compiler/diag.ei | edit std/proc.ei |"
echo "|---|---|---|---|---|---|"
for E in "$@"; do
  case $E in /*) ;; *) E=$here/$E ;; esac
  for mode in release debug; do
    restore
    EIDER_CACHE=$B/cache-$mode; export EIDER_CACHE
    rm -rf "$EIDER_CACHE"
    if [ $mode = release ]; then
      set -- build "$B/tree/compiler/main.ei" -o "$B/eiderc.out" $BENCH_FLAGS
    else
      set -- run "$B/tree/compiler/main.ei" $BENCH_FLAGS -- --version
    fi
    cold=$(secs "$E" "$@")
    n1=$(secs "$E" "$@"); n2=$(secs "$E" "$@"); n3=$(secs "$E" "$@")
    sed 's/"only the first "/"only the first  "/' compiler/diag.ei >"$B/tree/compiler/diag.ei"
    ed1=$(secs "$E" "$@")
    sed 's/"proc: empty command"/"proc: empty command!"/' std/proc.ei >"$B/tree/std/proc.ei"
    ed2=$(secs "$E" "$@")
    echo "| $(basename "$E") | $mode | $cold | $(med3 "$n1" "$n2" "$n3") | $ed1 | $ed2 |"
    rm -rf "$EIDER_CACHE"
  done
done
rm -rf "$B"
