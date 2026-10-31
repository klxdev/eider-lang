#!/bin/sh
# Crash and consistency fuzzing of eiderc (packages/fuzz; its main.ei lists the invariants:
# check, emit-c, build and run agree with each other and never crash, and `check --json`
# equals a reference compiler's). Builds the fuzzer, and target/eiderc-next (compiler/ built
# by the seed's eiderc), when their sources changed, then runs it from the repository root.
# Failing mutants are kept next to their seed as fuzz_<n>.ei.
#
#   scripts/fuzz-check.sh [count] [seed files...]     (default 500)
#   SEED=n MODE=semantic|wild EIDERC=<binary> REF=<binary>|none   (REF default: target/eiderc,
#   the seed itself, so a compiler/ change shows every diagnostic it moves)
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1
# the mutants' builds get a cache of their own, removed afterwards
EIDER_CACHE=${EIDER_CACHE:-$root/target/fuzz-cache}; export EIDER_CACHE
bin="$root/target/fuzz-check"
newest=$(find "$root/packages/fuzz" "$root/std" "$root/core" -name '*.ei' -not -path '*/deps/*' -newer "$bin" 2>/dev/null | head -1)
if [ ! -x "$bin" ] || [ -n "$newest" ]; then
  mkdir -p "$root/target"
  EIDER_CACHE=off "$root/scripts/ei" build "$root/packages/fuzz/main.ei" -o "$bin" >/dev/null 2>"$root/target/fuzz-check.build.log" || { cat "$root/target/fuzz-check.build.log"; exit 3; }
fi
"$root/scripts/ei" --help >/dev/null || exit 3
if [ -z "$EIDERC" ]; then
  eiderc="$root/target/eiderc-next"
  newest=$(find "$root/compiler" "$root/std" "$root/core" -name '*.ei' -not -path '*/deps/*' -newer "$eiderc" 2>/dev/null | head -1)
  if [ ! -x "$eiderc" ] || [ -n "$newest" ]; then
    EIDER_CACHE=off "$root/scripts/ei" build "$root/compiler/main.ei" -o "$eiderc" >/dev/null 2>"$root/target/eiderc.build.log" || { cat "$root/target/eiderc.build.log"; exit 3; }
  fi
fi
"$bin" "$@"
code=$?
[ "$EIDER_CACHE" = "$root/target/fuzz-cache" ] && rm -rf "$root/target/fuzz-cache"
exit $code
