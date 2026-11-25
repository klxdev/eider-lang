#!/bin/sh
# Differential check of the compile-time interpreter against the compiled code (workstream C of #246): gen.ei writes
# programs of total integer functions that main evaluates both ways (`const C = comptime f(..)` and `f(..)`) and
# compares. Usage: sh tests/safety/diff/run.sh [eiderc-or-scripts/ei] [programs] [functions per program] [first seed]
cd "$(dirname "$0")/../../.." || exit 1
E=${1:-scripts/ei}
N=${2:-5}
K=${3:-60}
S0=${4:-1}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
$E build tests/safety/diff/gen.ei -o "$T/gen" >"$T/log" 2>&1 || { echo "FAIL safety diff: cannot build gen.ei"; head -5 "$T/log"; exit 1; }
bad=0; i=0
while [ $i -lt "$N" ]; do
  seed=$((S0 + i)); i=$((i + 1))
  "$T/gen" "$seed" "$K" > "$T/p.ei"
  got=$($E run "$T/p.ei" 2>&1)
  if [ "$got" != "done" ]; then
    bad=1; cp "$T/p.ei" "diff_fail_$seed.ei"; echo "FAIL safety diff: seed $seed: $(echo "$got" | head -3 | tr '\n' ' ') (kept diff_fail_$seed.ei)"
  fi
done
[ $bad = 0 ] && echo "ok   safety diff: $N programs x $K functions: the compile-time interpreter and the compiled code agree"
exit $bad
