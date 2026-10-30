#!/bin/sh
# Differential fuzzing of `eiderc check --json` against the bootstrap (packages/fuzz).
# Builds the fuzzer, and target/eiderc, when their sources changed, then runs it from the
# repository root. Disagreeing mutants are kept next to their seed as fuzz_<n>.ei.
#
#   scripts/fuzz-check.sh [count] [seed files...]     (default 500)
#   SEED=n MODE=semantic|wild EIDERC=<binary>
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1
bin="$root/target/fuzz-check"
newest=$(find "$root/packages/fuzz" "$root/std" "$root/core" -name '*.ei' -not -path '*/deps/*' -newer "$bin" 2>/dev/null | head -1)
if [ ! -x "$bin" ] || [ -n "$newest" ]; then
  "$root/scripts/bootstrap-deps.sh"
  mkdir -p "$root/target"
  EIDER_CACHE=off "$root/scripts/ei" build "$root/packages/fuzz/main.ei" -o "$bin" >/dev/null 2>"$root/target/fuzz-check.build.log" || { cat "$root/target/fuzz-check.build.log"; exit 3; }
fi
if [ -z "$EIDERC" ]; then
  eiderc="$root/target/eiderc"
  newest=$(find "$root/compiler" "$root/std" "$root/core" -name '*.ei' -not -path '*/deps/*' -newer "$eiderc" 2>/dev/null | head -1)
  if [ ! -x "$eiderc" ] || [ -n "$newest" ]; then
    "$root/scripts/bootstrap-deps.sh"
    EIDER_CACHE=off "$root/scripts/ei" build "$root/compiler/main.ei" -o "$eiderc" >/dev/null 2>"$root/target/eiderc.build.log" || { cat "$root/target/eiderc.build.log"; exit 3; }
  fi
fi
exec "$bin" "$@"
