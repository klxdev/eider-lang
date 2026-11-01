#!/bin/sh
# The LLVM backend's units through the cache (compiler/llvm_units.ei, build.ei; docs/compiler.md,
# "C8.27: incremental builds"), on a copy of tests/units (app.ei and its modules units/shapes.ei,
# units/words.ei) and an empty cache:
#   - `run` gives app.out, with the cache on and off;
#   - a no-op rebuild compiles nothing; an edit to one function of shapes.ei recompiles exactly
#     one unit (mod.shapes), an edit to a string of words.ei one (mod.words);
#   - the units are the same at -j 1 and -j 8 (the same cache entries), and EIDER_LLVM_UNITS=0
#     builds the module as one unit with the same output;
#   - a release build (ThinLTO with lld's cache in <cache>/lto, when lld links) gives app.out,
#     and after an edit too.
# usage: run.sh <eiderc>; exits 2 (a skip) without clang 17+.
cd "$(dirname "$0")/../.." || exit 1
E=${1:-target/eiderc-next}
case $E in /*) ;; *) E=$(pwd)/$E ;; esac
LCC=${EIDER_LLVM_CC:-clang}
command -v "$LCC" >/dev/null 2>&1 || { echo "skip: no clang"; exit 2; }
v=$("$LCC" --version | sed -n 's/.*version \([0-9]*\).*/\1/p' | head -1)
[ -n "$v" ] && [ "$v" -ge 17 ] || { echo "skip: clang $v is older than 17"; exit 2; }
T=$(pwd)/target/unitstest
rm -rf $T
mkdir -p $T
cp -R tests/units $T/src
EIDER_CACHE=$T/cache; export EIDER_CACHE
ok=1
f() { echo "FAIL units: $1"; ok=0; }
nobj() { find $EIDER_CACHE/obj -type f 2>/dev/null | wc -l | tr -d ' '; }
want=tests/units/app.out
$E run $T/src/app.ei >$T/o 2>&1 || f "run: $(head -3 $T/o)"
cmp -s $T/o $want || f "run gives the wrong output"
EIDER_CACHE=off $E run $T/src/app.ei >$T/oc 2>&1
cmp -s $T/oc $want || f "with the cache off: wrong output"
n0=$(nobj)
[ "$n0" -ge 6 ] || f "only $n0 objects: the module was not split into units"
$E run $T/src/app.ei >$T/o 2>&1
[ "$(nobj)" = $n0 ] || f "a no-op rebuild compiled $(($(nobj) - n0)) units"
sed 's/b.w \* b.h/b.h * b.w/' tests/units/units/shapes.ei >$T/src/units/shapes.ei
$E run $T/src/app.ei >$T/o 2>&1
cmp -s $T/o $want || f "after the edit to shapes.ei: wrong output"
[ "$(nobj)" = $((n0 + 1)) ] || f "an edit to shapes.ei compiled $(($(nobj) - n0)) units, not 1"
sed 's/"!"/"?"/' tests/units/units/words.ei >$T/src/units/words.ei
$E run $T/src/app.ei >$T/o 2>&1
sed 's/!$/?/' $want | cmp -s - $T/o || f "after the edit to words.ei: wrong output"
[ "$(nobj)" = $((n0 + 2)) ] || f "an edit to words.ei compiled $(($(nobj) - n0 - 1)) units, not 1"
cp tests/units/units/*.ei $T/src/units/
# -j 1 and -j 8: the same entries
for j in 1 8; do
  EIDER_CACHE=$T/cache-j$j $E build -j $j $T/src/app.ei -o $T/app-j$j >$T/oj 2>&1 || f "build -j $j: $(head -3 $T/oj)"
done
cmp -s $T/app-j1 $T/app-j8 || f "-j 1 and -j 8 built different programs"
[ "$(cd $T/cache-j1 && find obj bin -type f | sort)" = "$(cd $T/cache-j8 && find obj bin -type f | sort)" ] || f "-j 1 and -j 8 made different cache entries"
EIDER_LLVM_UNITS=0 EIDER_CACHE=$T/cache-whole $E run $T/src/app.ei >$T/o 2>&1
cmp -s $T/o $want || f "EIDER_LLVM_UNITS=0 gives the wrong output"
[ "$(find $T/cache-whole/obj -type f | wc -l | tr -d ' ')" = 4 ] || f "EIDER_LLVM_UNITS=0 should make 4 objects (the module, the C half, the core's 2)"
# release: ThinLTO when lld links
$E build $T/src/app.ei -o $T/app2 >$T/ob 2>&1 || f "release build: $(head -3 $T/ob)"
$T/app2 >$T/o 2>&1
cmp -s $T/o $want || f "the release build gives the wrong output"
sed 's/b.w \* b.h/b.h * b.w/' tests/units/units/shapes.ei >$T/src/units/shapes.ei
$E build $T/src/app.ei -o $T/app3 >$T/ob 2>&1 || f "release build after an edit: $(head -3 $T/ob)"
$T/app3 >$T/o 2>&1
cmp -s $T/o $want || f "the release build after an edit gives the wrong output"
lto=$(find $EIDER_CACHE/lto -type f 2>/dev/null | wc -l | tr -d ' ')
rm -rf $T
[ $ok = 1 ] || exit 1
echo "ok   llvm units: split, no-op, one unit per edited module, -j, EIDER_LLVM_UNITS=0, release ($lto entries in lld's ThinLTO cache)"
