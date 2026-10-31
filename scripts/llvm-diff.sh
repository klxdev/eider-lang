#!/bin/sh
# The LLVM backend's differential suite (docs/compiler.md, "Backends"; docs/site/tooling/llvm.md):
# every run test (tests/run, compiler/tests/run) through the C backend and through
# `--backend=llvm` must give byte-identical stdout, stderr and exit code, under `run` and,
# when the file has test blocks, under `test`; the LLVM build at -O0 and at -O2 (`--release`),
# with the runtime's allocation count (-DEI_RT_COUNT_ALLOCS: the same leak report), and again
# under ASan+UBSan (both halves built by clang) when clang has their runtimes.
# Then the coverage: functions emitted as LLVM IR vs. falling back to C, per test and overall.
#
#   sh scripts/llvm-diff.sh [files...]       default: every run test
#   EIDERC=<binary>                          the compiler (default: target/eiderc-next, built
#                                            from compiler/ by the seed when missing or older)
#   QUICK=1                                  skip the sanitizer leg
#
# Prints `ok`/`FAIL` per (file, mode), a coverage table, and a summary; exits 1 on any
# difference, 2 when clang is missing or older than LLVM 17 (the caller reports a skip).
cd "$(dirname "$0")/.." || exit 1
EIDER_CACHE=off; export EIDER_CACHE
LCC=${EIDER_LLVM_CC:-clang}
if ! command -v "$LCC" >/dev/null 2>&1; then echo "skip: no clang ($LCC; set EIDER_LLVM_CC)"; exit 2; fi
major=$("$LCC" --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9]*\)\..*/\1/p' | head -1)
if [ -z "$major" ] || [ "$major" -lt 17 ]; then echo "skip: $LCC is LLVM ${major:-?}; the LLVM backend needs 17 or newer"; exit 2; fi
if [ -n "$EIDERC" ]; then
  E=$EIDERC
else
  E=target/eiderc-next
  if [ ! -x "$E" ] || [ -n "$(find compiler std core -newer "$E" \( -name '*.ei' -o -name '*.c' -o -name '*.h' \) 2>/dev/null | head -1)" ]; then
    scripts/ei build compiler/main.ei -o "$E" >/dev/null 2>target/llvm-diff.build.log || { cat target/llvm-diff.build.log; echo "FAIL build eiderc"; exit 1; }
  fi
fi
T=target/llvm-diff
mkdir -p $T
files=$*
[ -n "$files" ] || files=$(ls tests/run/*.ei compiler/tests/run/*.ei)
# sanitizers: ASan+UBSan when clang links their runtimes
san=""
if [ -z "$QUICK" ]; then
  printf 'int main(void){return 0;}\n' > $T/probe.c
  if "$LCC" -fsanitize=address,undefined -o $T/probe $T/probe.c 2>/dev/null && $T/probe; then
    # -w: clang's warnings on the C (the whole program, or only the C half) are not output
    san="-w -fsanitize=address,undefined -fno-sanitize-recover=undefined"
  else
    echo "     skip sanitizers: clang has no ASan/UBSan runtime here"
  fi
fi
outcome() {
  "$@" >$T/o 2>$T/e
  code=$?
  { cat $T/o; echo "--- stderr"; cat $T/e; echo "--- exit $code"; } | sed 's|/eiderc-[0-9]*-[0-9]*/|/<work>/|g' >$T/out
}
fail=0; runs=0; agree=0; tot_n=0; tot_f=0
printf '' > $T/coverage
for f in $files; do
  case "$($E check --json "$f" 2>&1)" in *'"error":"unsupported"'*) continue ;; esac
  for cmd in run test; do
    if [ $cmd = test ] && ! grep -q '^test ' "$f"; then continue; fi
    topt=""; [ $cmd = test ] && topt="--test"
    cov=$($E emit-llvm --coverage $topt "$f" 2>&1 | head -1)
    n=$(echo "$cov" | sed -n 's/^native \([0-9]*\)\/\([0-9]*\) functions$/\1/p')
    m=$(echo "$cov" | sed -n 's/^native \([0-9]*\)\/\([0-9]*\) functions$/\2/p')
    [ -n "$n" ] || { n=0; m=0; }
    tot_n=$((tot_n + n)); tot_f=$((tot_f + m))
    echo "$f $cmd $n $m" >> $T/coverage
    outcome env CC=${CC:-cc} $E $cmd "$f"; cp $T/out $T/want
    for mode in O0 O2 leaks san; do
      if [ $mode = leaks ]; then
        # the runtime's allocation count (-DEI_RT_COUNT_ALLOCS): the same report from both
        outcome env EIDER_CFLAGS=-DEI_RT_COUNT_ALLOCS $E $cmd "$f"; cp $T/out $T/want_leaks
        outcome env EIDER_CFLAGS=-DEI_RT_COUNT_ALLOCS EIDER_LLVM_CC="$LCC" $E $cmd --backend=llvm "$f"
        cmp -s $T/want_leaks $T/out; same=$?
      elif [ $mode = san ]; then
        [ -n "$san" ] || continue
        outcome env CC="$LCC" EIDER_CFLAGS="$san" $E $cmd "$f"; cp $T/out $T/want_san
        outcome env CC="$LCC" EIDER_CFLAGS="$san" EIDER_LLVM_CC="$LCC" $E $cmd --backend=llvm "$f"
        cmp -s $T/want_san $T/out; same=$?
      else
        rel=""; [ $mode = O2 ] && rel="--release"
        outcome env EIDER_LLVM_CC="$LCC" $E $cmd --backend=llvm $rel "$f"
        cmp -s $T/want $T/out; same=$?
      fi
      runs=$((runs + 1))
      if [ $same = 0 ]; then
        agree=$((agree + 1))
        [ -n "$VERBOSE" ] && echo "ok   $f ($cmd, $mode)"
      else
        echo "FAIL $f ($cmd, $mode)"
        case $mode in san) diff $T/want_san $T/out | head -8 ;; leaks) diff $T/want_leaks $T/out | head -8 ;; *) diff $T/want $T/out | head -8 ;; esac
        fail=1
      fi
    done
  done
done
echo "coverage (functions emitted as LLVM IR / functions):"
awk '{ printf "  %-44s %-4s %4d/%-4d %5.1f%%\n", $1, $2, $3, $4, ($4 ? 100 * $3 / $4 : 100) }' $T/coverage
pct=$(awk -v n=$tot_n -v m=$tot_f 'BEGIN { printf "%.1f", (m ? 100 * n / m : 100) }')
if [ $fail = 0 ]; then v="ok  "; else v="FAIL"; fi
echo "$v llvm differential: $agree/$runs runs byte-identical to the C backend (-O0, -O2, allocation counts${san:+, ASan+UBSan}); coverage $tot_n/$tot_f functions native ($pct%)"
exit $fail
