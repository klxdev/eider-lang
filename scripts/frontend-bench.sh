#!/bin/sh
# The front end's costs and a parse cache's lower bound (compiler/tests/bench/frontend.ei;
# docs/compiler.md, "C8.27: incremental builds", "The front-end cache") on the compiler and on
# every std module (compiler/tests/bench/allstd.ei), each the median of $RUNS runs (default 5).
#
#   sh scripts/frontend-bench.sh [eiderc]     (default target/eiderc, built from the seed; needs gawk)
cd "$(dirname "$0")/.." || exit 1
E=${1:-}
if [ -z "$E" ]; then scripts/ei --version >/dev/null || exit 1; E=target/eiderc; fi
mkdir -p target
"$E" build compiler/tests/bench/frontend.ei -o target/frontend-bench >/dev/null || exit 1
runs=${RUNS:-5}
for f in compiler/main.ei compiler/tests/bench/allstd.ei; do
  echo "== $f"
  i=0
  while [ $i -lt $runs ]; do target/frontend-bench $f >target/frontend-bench.$i || exit 1; i=$((i + 1)); done
  # per line: the label and the median of the runs
  paste target/frontend-bench.[0-9]* | awk -F'\t' '{
    n = split($1, a, / +/); label = $1; sub(/ +[0-9]+$/, "", label)
    for (i = 1; i <= NF; i++) { m = split($i, b, / +/); v[i] = b[m] }
    asort(v); printf "%-22s %s\n", label, v[int((NF + 1) / 2)]; delete v }'
  rm -f target/frontend-bench.[0-9]*
done
