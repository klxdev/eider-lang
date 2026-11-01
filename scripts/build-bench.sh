#!/bin/sh
# Build times of eiderc itself through the cache (docs/compiler.md, "C8.27: incremental builds",
# "Measurements"). For each configuration, in a copy of this tree (target/build-bench/tree,
# its own EIDER_ROOT) and on an empty cache per mode: a cold build, a no-op rebuild (median of
# 3), an edit to one compiler module (a message in compiler/diag.ei) and then an edit to one
# std module (a message in std/proc.ei), with `build` (-O2, the release build) and with
# `run -- --version` (-O0, the debug build). Prints a markdown table: seconds (wall clock),
# and after each the number of unit objects that step compiled (new entries in obj/).
#
#   sh scripts/build-bench.sh <label>:<eiderc>[:<flags>[:<VAR=value>]] ...
#
# e.g. `units:target/eiderc-next  whole:target/eiderc-next::EIDER_LLVM_UNITS=0
# j4:target/eiderc-next:-j 4` (flags split at spaces).
cd "$(dirname "$0")/.." || exit 1
[ $# -gt 0 ] || { echo "usage: scripts/build-bench.sh <label>:<eiderc>[:<flags>[:<VAR=value>]] ..."; exit 2; }
here=$(pwd)
B=$here/target/build-bench
rm -rf "$B"
mkdir -p "$B/tree"
cp -R compiler core std VERSION "$B/tree/"
EIDER_ROOT=$B/tree; export EIDER_ROOT
now() { date +%s.%N; }
nobj() { find "$EIDER_CACHE/obj" -type f 2>/dev/null | wc -l | tr -d ' '; }
# step <command...>: "<seconds> (<objects compiled>)"; exits on failure
step() {
  before=$(nobj)
  s=$(now)
  env $xenv "$@" >"$B/out" 2>&1 || { echo "build-bench: failed: $*" >&2; cat "$B/out" >&2; exit 1; }
  e=$(now)
  awk -v s="$s" -v e="$e" -v n=$(($(nobj) - before)) 'BEGIN { printf "%.2f (%d)", e - s, n }'
}
secs() { echo "$1" | sed 's/ .*//'; }
med3() { printf '%s\n%s\n%s\n' "$1" "$2" "$3" | sort -n | sed -n 2p; }
restore() {
  cp compiler/diag.ei "$B/tree/compiler/diag.ei"
  cp std/proc.ei "$B/tree/std/proc.ei"
}
echo "| configuration | build | cold | no-op | edit compiler/diag.ei | edit std/proc.ei |"
echo "|---|---|---|---|---|---|"
for cfg in "$@"; do
  label=$(echo "$cfg" | cut -d: -f1)
  E=$(echo "$cfg" | cut -d: -f2)
  flags=$(echo "$cfg" | cut -d: -f3)
  xenv=$(echo "$cfg" | cut -d: -f4)
  [ -n "$xenv" ] || xenv=EIDER_BENCH=1
  case $E in /*) ;; *) E=$here/$E ;; esac
  for mode in release debug; do
    restore
    EIDER_CACHE=$B/cache-$mode; export EIDER_CACHE
    rm -rf "$EIDER_CACHE"
    if [ $mode = release ]; then
      set -- "$E" build "$B/tree/compiler/main.ei" -o "$B/eiderc.out" $flags
    else
      set -- "$E" run "$B/tree/compiler/main.ei" $flags -- --version
    fi
    cold=$(step "$@") || exit 1
    n1=$(step "$@"); n2=$(step "$@"); n3=$(step "$@")
    sed 's/"only the first "/"only the first  "/' compiler/diag.ei >"$B/tree/compiler/diag.ei"
    ed1=$(step "$@") || exit 1
    sed 's/"proc: empty command"/"proc: empty command!"/' std/proc.ei >"$B/tree/std/proc.ei"
    ed2=$(step "$@") || exit 1
    echo "| $label | $mode | $cold | $(med3 "$(secs "$n1")" "$(secs "$n2")" "$(secs "$n3")") | $ed1 | $ed2 |"
    rm -rf "$EIDER_CACHE"
  done
done
rm -rf "$B"
