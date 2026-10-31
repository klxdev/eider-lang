#!/bin/sh
# Self-hosting (docs/compiler.md, C6 and "Bootstrap chain").
#
#   scripts/selfhost.sh              seed -> stage1 -> stage2 -> stage3, check the fixed point
#                                    (stage2 and stage3 emit byte-identical C for compiler/), that
#                                    stage3 frees everything it allocates while compiling
#                                    compiler/ (-DEI_RT_COUNT_ALLOCS), then run
#                                    scripts/test-compiler.sh against stage3
#   scripts/selfhost.sh --seed       ...and write that C to seed/eiderc.c
#   scripts/selfhost.sh --from-seed  build eiderc from seed/eiderc.c with only a C compiler, and
#                                    check it reproduces the seed exactly (a stale seed fails)
#
# The seed is seed/eiderc.c compiled by $CC; every later stage is compiler/ built by the stage
# before it, each with only $CC and the C core. Outputs go to target/selfhost/.
cd "$(dirname "$0")/.." || exit 1
root=$(pwd)
out=target/selfhost
mkdir -p "$out"
EIDER_ROOT=$root; export EIDER_ROOT
EIDER_CACHE=off; export EIDER_CACHE
CC=${CC:-cc}
src=compiler/main.ei
mkdir -p target

step() { printf '%-40s' "$1"; }
die() { echo "FAIL"; [ -n "$2" ] && sed 's/^/    /' "$2" | head -40; echo "selfhost: $1"; exit 1; }

# a compiler built from C: the seed plus the C core, nothing else ($3: extra flags)
from_c() {
  # the same warning bar eiderc holds its output to (driver.ei), as errors
  "$CC" -std=c11 -O2 $3 -pedantic -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable \
    -Wno-unused-but-set-variable -Wno-unused-parameter -pthread -I core -o "$2" "$1" core/eider_rt.c core/eider_core.c \
    2>"$out/cc.log" || die "cc failed on $1" "$out/cc.log"
}

if [ "$1" = "--from-seed" ]; then
  [ -f seed/eiderc.c ] || { echo "selfhost: no seed/eiderc.c (run scripts/selfhost.sh --seed first)"; exit 1; }
  step "build eiderc from seed/eiderc.c"; from_c seed/eiderc.c "$out/seeded"; echo ok
  step "seeded compiler reproduces the seed"
  "$out/seeded" emit-c "$src" > "$out/seeded.c" 2>"$out/err.log" || die "emit-c failed" "$out/err.log"
  cmp -s "$out/seeded.c" seed/eiderc.c || die "seed/eiderc.c is stale (re-run scripts/selfhost.sh --seed)"
  echo ok
  exit 0
fi

step "seed: cc builds seed/eiderc.c"
from_c seed/eiderc.c "$out/seeded"
echo ok
step "stage1: the seed builds compiler/"
"$out/seeded" emit-c "$src" > "$out/stage1.c" 2>"$out/err.log" || die "the seed could not compile compiler/" "$out/err.log"
from_c "$out/stage1.c" "$out/stage1"
echo ok
step "stage2: stage1 builds compiler/"
"$out/stage1" emit-c "$src" > "$out/stage2.c" 2>"$out/err.log" || die "stage1 could not compile compiler/" "$out/err.log"
from_c "$out/stage2.c" "$out/stage2"
echo ok
step "stage3: stage2 builds compiler/"
"$out/stage2" emit-c "$src" > "$out/stage3.c" 2>"$out/err.log" || die "stage2 could not compile compiler/" "$out/err.log"
from_c "$out/stage3.c" "$out/stage3"
echo ok
step "fixed point: stage2.c == stage3.c"
cmp -s "$out/stage2.c" "$out/stage3.c" || { diff "$out/stage2.c" "$out/stage3.c" > "$out/fixed-point.diff"; die "stage2 and stage3 emit different C" "$out/fixed-point.diff"; }
echo ok
step "stage3 leaks nothing (compiler/)"
# the runtime's allocation counter (core/RUNTIME.md, ei_check_leaks)
from_c "$out/stage3.c" "$out/stage3-count" -DEI_RT_COUNT_ALLOCS
"$out/stage3-count" emit-c "$src" > "$out/count.c" 2>"$out/count.log" || die "the counting stage3 could not compile compiler/" "$out/count.log"
cmp -s "$out/count.c" "$out/stage3.c" || die "the counting stage3 emits different C"
grep -qx 'eider: outstanding allocations: 0' "$out/count.log" || die "allocations left over" "$out/count.log"
echo ok
step "stage3 passes scripts/test-compiler.sh"
EIDERC="$root/$out/stage3" sh scripts/test-compiler.sh > "$out/tests.log" 2>&1 || die "test failures" "$out/tests.log"
grep -q FAIL "$out/tests.log" && die "test failures" "$out/tests.log"
echo ok
if [ "$1" = "--seed" ]; then
  mkdir -p seed
  cp "$out/stage3.c" seed/eiderc.c
  echo "wrote seed/eiderc.c ($(wc -l < seed/eiderc.c) lines)"
fi
echo "SELF-HOSTED"
