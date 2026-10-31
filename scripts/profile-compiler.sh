#!/bin/sh
# Profile eiderc compiling a program (default: itself, `emit-c compiler/main.ei`) with the
# profiler (docs/runtime.md "Profiler"), and write a report and a flame graph.
#
#   sh scripts/profile-compiler.sh [eiderc args...]     default args: emit-c compiler/main.ei
#   sh scripts/profile-compiler.sh --save-baseline      ... and keep the profile as the baseline
#   sh scripts/profile-compiler.sh --check              ... and compare with the baseline:
#                                                        exit 1 if a deterministic count grew
#
# Writes target/prof/eiderc.prof, and with eider-profiler (the separate eider-profiler
# repository; $EIDER_PROFILER, else ../eider-profiler/target/bin/eider-profiler next to this
# checkout) target/prof/eiderc.report.txt and target/prof/eiderc.flame.html.
#
# The compiler profiled is compiler/ as built by target/eiderc-next (made with scripts/ei if
# missing), built again with `--profile`. The perf-regression check is optional and not a
# verify.sh gate (docs/decisions.md C205): `--save-baseline` on the revision to compare
# against, then `--check` after the change runs `eider-profiler diff --check` with
# TOLERANCE percent (default 0) on what is deterministic for a deterministic input
# (allocations, bytes allocated, copy-on-write unshares and bytes, .copy() calls, List
# growth, Map rehashes, Drop calls); time is shown but never gated.
cd "$(dirname "$0")/.." || exit 1
root=$(pwd)
mode=
case $1 in
  --save-baseline) mode=save; shift ;;
  --check) mode=check; shift ;;
esac
[ $# -gt 0 ] || set -- emit-c compiler/main.ei
mkdir -p target/prof
if [ ! -x target/eiderc-next ] || [ -n "$(find compiler core std -newer target/eiderc-next \( -name '*.ei' -o -name '*.c' -o -name '*.h' \) | head -1)" ]; then
  EIDER_CACHE=off scripts/ei build compiler/main.ei -o target/eiderc-next || exit 3
fi
EIDER_CACHE=off target/eiderc-next build compiler/main.ei --profile -o target/prof/eiderc-profiled || exit 3
EIDER_ROOT=$root EIDER_PROF=$root/target/prof/eiderc.prof target/prof/eiderc-profiled "$@" > target/prof/eiderc.out || { echo "profile-compiler: eiderc $* failed (output in target/prof/eiderc.out)"; exit 1; }
echo "profile: target/prof/eiderc.prof"
prof=${EIDER_PROFILER:-$root/../eider-profiler/target/bin/eider-profiler}
if [ ! -x "$prof" ]; then
  echo "profile-compiler: no eider-profiler (set EIDER_PROFILER); the profile is written, the report is not"
  [ -z "$mode" ] || exit 2
  exit 0
fi
"$prof" report target/prof/eiderc.prof > target/prof/eiderc.report.txt
"$prof" flame target/prof/eiderc.prof -o target/prof/eiderc.flame.html
echo "report: target/prof/eiderc.report.txt"
echo "flame graph: target/prof/eiderc.flame.html"
sed -n '1,20p' target/prof/eiderc.report.txt
case $mode in
  save) cp target/prof/eiderc.prof target/prof/baseline.prof; echo "baseline: target/prof/baseline.prof" ;;
  check)
    [ -f target/prof/baseline.prof ] || { echo "profile-compiler: no baseline (run with --save-baseline on the revision to compare with)"; exit 2; }
    "$prof" diff target/prof/baseline.prof target/prof/eiderc.prof --check --tolerance "${TOLERANCE:-0}" ;;
esac
