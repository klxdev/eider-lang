#!/bin/sh
# Tests for the self-hosted compiler (compiler/). Differential: the bootstrap is the oracle.
#
#   front:    for every .ei in the repo and in compiler/tests/{lex,parse}, whenever either
#             compiler reports a lex or parse error, both must report the same JSON diagnostic.
#   lex_ok:   token dumps of compiler/tests/lex_ok/*.ei match their .tokens goldens
#   parse_ok: AST dumps of compiler/tests/parse_ok/*.ei match their .ast goldens
#             (BLESS=1 rewrites the goldens; review the diff).
#   ir:       IR dumps of compiler/tests/ir/*.ei match their .ir goldens (BLESS=1 too).
#   check:    for every compile-fail/pass test (tests/checks/{fail,pass}) whose features eiderc
#             supports (it doesn't answer `unsupported`), `eiderc check --json` must equal the
#             bootstrap's byte for byte; the same for tests/run/*.ei. eiderc's own cases in
#             compiler/tests/check/{fail,pass} must all be in scope and agree.
#   run:      every tests/run/*.ei and compiler/tests/run/*.ei that eiderc checks without
#             `unsupported` must give the same stdout, stderr and exit code under `eiderc run`
#             as under the bootstrap's `eider run`, and, if it has test blocks, under
#             `eiderc test` and `eider test`. eiderc compiles its C with -Werror (on top of the
#             driver's -std=c11 -pedantic -Wall -Wextra). Exception: a compiler/tests/run file
#             with an X.out (and X.test.out) next to it is a regression test for a bootstrap
#             bug (LEARNINGS.md), where the bootstrap's output is wrong; it is compared with
#             that hand-written expected stdout instead (and must exit 0 with empty stderr).
#   sanitize: every run again with its C at -O2 -Werror (so -Wmaybe-uninitialized is
#             checked) under UBSan in trap mode (-fsanitize=undefined
#             -fsanitize-undefined-trap-on-error, no runtime library needed); the output must
#             equal the plain run's. ASan and TSan run too when their runtimes are installed.
#   leaks:    every run again with -DEI_RT_COUNT_ALLOCS (the runtime counts live allocations
#             and generated main reports them when the program ends normally): a run that
#             exits 0 must report `eider: outstanding allocations: 0`, and apart from that
#             line the output must equal the plain run's.
#   determinism: `emit-c` of every run test twice, and once from a copy of the test
#             directory at another path (same relative file name), must be byte-identical.
#   names:    two functions with one C name (compiler/tests/lower/clash.ei) stop `emit-c`
#             with an internal error (exit 3) naming both.
#   export:   libraries from `eiderc build --lib`: tests/export/run.sh (the C and C++
#             consumers of the bootstrap's suite) with EIDER=eiderc, compiler/tests/export/run.sh
#             (eiderc's own: more types, nested records, two libraries, traps), and
#             `emit-header` and `check --lib --json` equal to the bootstrap's.
#   unit:     programs in compiler/tests/unit that drive a compiler module (sha256.ei) must
#             print their .out.
#   compile-fail: `eiderc test --compile-fail` prints exactly what stage 0's runner prints
#             (and exits the same) for compiler/tests/check and compiler/tests/suite (the
#             runner's own failure cases); for tests/checks it reports 0 failed and every
#             line but the `skip`s (features eiderc doesn't have yet) and the coverage
#             summary is stage 0's.
#   cache:    EIDER_CACHE=<dir>: hits, what the key covers, core objects built once per
#             toolchain, concurrent runs on an empty cache, no work directories left over.
#   usage:    `--help` lists every command; unknown options/commands and stray arguments
#             exit 2.
cd "$(dirname "$0")/.." || exit 1
scripts/bootstrap-deps.sh
boot=$(scripts/stage0.sh) || exit 3
# EIDERC=<binary> tests that compiler instead of building target/eiderc with stage 0
# (scripts/selfhost.sh uses it to put the self-built compiler through the same tests).
if [ -n "$EIDERC" ]; then
  new=$EIDERC
else
  EIDER_CACHE=off scripts/ei build compiler/main.ei -o target/eiderc >/dev/null 2>target/eiderc.build.log || { cat target/eiderc.build.log; echo "FAIL build eiderc"; exit 1; }
  new=./target/eiderc
fi
# the front end's diagnostics: E0001, plus the parser's E0302 for `inout` in a type and E0402
# for `null`, in the entry file
frontmsg='"error":"(E0001|E0402)"|"error":"E0302".*"message":"`inout` is only valid on function parameters'
front() {
  case "$1" in *"\"file\":\"$2\""*) ;; *) return ;; esac
  echo "$1" | grep -E "$frontmsg"
}
fail=0
n=0
for f in $(find . -name '*.ei' -not -path './target/*' -not -path './.claude/*' -not -path '*/deps/*' | sort); do
  n=$((n + 1))
  want=$(front "$($boot check --json "$f" 2>/dev/null | head -1)" "$f")
  got=$(front "$($new check --json "$f" 2>/dev/null | head -1)" "$f")
  if [ "$want" != "$got" ]; then
    echo "FAIL front end $f"
    echo "  bootstrap: $want"
    echo "  eiderc:    $got"
    fail=1
  fi
done
[ $fail = 0 ] && echo "ok   front end (lex+parse): $n files agree with the bootstrap"
for f in compiler/tests/lex_ok/*.ei; do
  g="${f%.ei}.tokens"
  if [ -n "$BLESS" ]; then $new lex "$f" > "$g"; fi
  if $new lex "$f" | cmp -s - "$g"; then echo "ok   lex_ok $f"; else echo "FAIL lex_ok $f"; $new lex "$f" | diff "$g" - | head -10; fail=1; fi
done
for f in compiler/tests/parse_ok/*.ei; do
  g="${f%.ei}.ast"
  if [ -n "$BLESS" ]; then $new parse "$f" > "$g"; fi
  if $new parse "$f" | cmp -s - "$g"; then echo "ok   parse_ok $f"; else echo "FAIL parse_ok $f"; $new parse "$f" | diff "$g" - | head -10; fail=1; fi
done
for f in compiler/tests/ir/*.ei; do
  g="${f%.ei}.ir"
  if [ -n "$BLESS" ]; then $new ir "$f" > "$g"; fi
  if $new ir "$f" | cmp -s - "$g"; then echo "ok   ir $f"; else echo "FAIL ir $f"; $new ir "$f" | diff "$g" - | head -10; fail=1; fi
done

# check: differential against the bootstrap's `check --json`
# usage: check_set <must-be-in-scope: 0|1> files...; sets total, inscope, agree, outside
check_set() {
  strict=$1
  shift
  total=0
  inscope=0
  agree=0
  outside=""
  for f in "$@"; do
    total=$((total + 1))
    got=$($new check --json "$f" 2>&1)
    case "$got" in
      *'"error":"unsupported"'*)
        outside="$outside $(basename "$f")"
        if [ "$strict" = 1 ]; then echo "FAIL check $f is out of scope: $got"; fail=1; fi
        continue
        ;;
    esac
    inscope=$((inscope + 1))
    want=$($boot check --json "$f" 2>&1)
    if [ "$want" = "$got" ]; then
      agree=$((agree + 1))
    else
      echo "FAIL check $f"
      echo "  bootstrap: $want"
      echo "  eiderc:    $got"
      fail=1
    fi
  done
}
verdict() { if [ "$agree" = "$inscope" ] && [ "$1" = "$inscope" ]; then echo "ok  "; else echo "FAIL"; fi; }
check_set 0 tests/checks/fail/*.ei tests/checks/pass/*.ei
echo "$(verdict $inscope) check: $agree/$inscope check tests in scope agree ($total tests, $((total - inscope)) out of scope)"
echo "     out of scope:$outside"
check_set 0 tests/run/*.ei
echo "$(verdict $inscope) check: $agree/$inscope run tests in scope agree ($total tests)"
check_set 1 compiler/tests/check/fail/*.ei compiler/tests/check/pass/*.ei
echo "$(verdict $total) check: $agree/$inscope eiderc check cases agree (compiler/tests/check)"

# run: differential against the bootstrap's `run` / `test` (stdout, stderr, exit code)
tmp=target/runtest
mkdir -p $tmp
# usage: outcome <command...>: writes stdout, stderr and the exit code of the command to $tmp/out
outcome() {
  "$@" >$tmp/o 2>$tmp/e
  code=$?
  { cat $tmp/o; echo "--- stderr"; cat $tmp/e; echo "--- exit $code"; } >$tmp/out
}
has_tests() { grep -q '^test ' "$1"; }
# ASan/TSan need runtime libraries that may not be installed; UBSan in trap mode needs none
sans="undefined"
printf 'int main(void){return 0;}\n' >$tmp/probe.c
for s in address thread; do
  if ${CC:-cc} -fsanitize=$s -o $tmp/probe $tmp/probe.c 2>/dev/null; then
    sans="$sans $s"
  else
    echo "     skip $s sanitizer: its runtime library is not installed"
  fi
done
rtotal=0
rscope=0
ragree=0
rexpected=0
rsan=0
rsan_ok=0
rleak=0
rleak_ok=0
routside=""
for f in tests/run/*.ei compiler/tests/run/*.ei; do
  rtotal=$((rtotal + 1))
  case "$($new check --json "$f" 2>&1)" in
    *'"error":"unsupported"'*)
      routside="$routside $(basename "$f")"
      continue
      ;;
  esac
  rscope=$((rscope + 1))
  ok=1
  for cmd in run test; do
    if [ $cmd = test ] && ! has_tests "$f"; then continue; fi
    exp=""
    case "$f" in compiler/tests/run/*) exp="${f%.ei}.out" ;; esac
    [ $cmd = test ] && exp="${exp%.out}.test.out"
    outcome env EIDER_CFLAGS=-Werror $new $cmd "$f"
    cp $tmp/out $tmp/got
    if [ -n "$exp" ] && [ -f "$exp" ]; then
      # a bootstrap-bug regression: hand-written expected output, not the bootstrap's
      { cat "$exp"; echo "--- stderr"; echo "--- exit 0"; } >$tmp/want
    else
      outcome $boot $cmd "$f"
      cp $tmp/out $tmp/want
    fi
    if ! cmp -s $tmp/want $tmp/got; then
      echo "FAIL run: eiderc $cmd $f"
      diff $tmp/want $tmp/got | head -10
      ok=0
      fail=1
    fi
    # the same program at -O2 under each available sanitizer
    for s in $sans; do
      rsan=$((rsan + 1))
      flags="-Werror -O2 -fsanitize=$s"
      [ $s = undefined ] && flags="$flags -fsanitize-undefined-trap-on-error"
      outcome env EIDER_CFLAGS="$flags" $new $cmd "$f"
      if cmp -s $tmp/got $tmp/out; then
        rsan_ok=$((rsan_ok + 1))
      else
        echo "FAIL sanitize ($s): eiderc $cmd $f"
        diff $tmp/got $tmp/out | head -10
        fail=1
      fi
    done
    # no allocation may be left when the program ends normally
    rleak=$((rleak + 1))
    outcome env EIDER_CFLAGS="-Werror -DEI_RT_COUNT_ALLOCS" $new $cmd "$f"
    leakline=$(grep '^eider: outstanding allocations: ' $tmp/e)
    grep -v '^eider: outstanding allocations: ' $tmp/out >$tmp/out2
    if ! cmp -s $tmp/got $tmp/out2; then
      echo "FAIL leaks: eiderc $cmd $f (output differs)"
      diff $tmp/got $tmp/out2 | head -10
      fail=1
    elif grep -q '^--- exit 0$' $tmp/out && [ "$leakline" != "eider: outstanding allocations: 0" ]; then
      echo "FAIL leaks: eiderc $cmd $f: ${leakline:-no allocation report}"
      fail=1
    else
      rleak_ok=$((rleak_ok + 1))
    fi
  done
  if [ $ok = 1 ]; then
    ragree=$((ragree + 1))
    case "$f" in compiler/tests/run/*) [ -f "${f%.ei}.out" ] && rexpected=$((rexpected + 1)) ;; esac
  fi
done
if [ "$ragree" = "$rscope" ]; then v="ok  "; else v="FAIL"; fi
echo "$v run: $ragree/$rscope run tests in scope agree ($rtotal tests; $rexpected compared with expected output for bootstrap bugs)"
echo "     out of scope:$routside"
if [ "$rsan_ok" = "$rsan" ]; then v="ok  "; else v="FAIL"; fi
echo "$v sanitize: $rsan_ok/$rsan runs at -O2 under -fsanitize={$sans} match"
if [ "$rleak_ok" = "$rleak" ]; then v="ok  "; else v="FAIL"; fi
echo "$v leaks: $rleak_ok/$rleak runs end with no outstanding allocation (-DEI_RT_COUNT_ALLOCS)"

# determinism: the same input gives byte-identical C, also from another directory
det=target/determinism
rm -rf $det
mkdir -p $det/a $det/b
cp -R tests/run $det/a/run
cp -R compiler/tests/run $det/b/run
dtotal=0
dok=0
# the compiler by absolute path, so it runs from the test directories
case "$new" in /*) anew=$new ;; *) anew=$(pwd)/$new ;; esac
for f in tests/run/*.ei compiler/tests/run/*.ei; do
  case " $routside " in *" $(basename "$f") "*) continue ;; esac
  dtotal=$((dtotal + 1))
  case "$f" in tests/*) dir=tests ;; *) dir=compiler/tests ;; esac
  case "$f" in tests/*) copy=$det/a ;; *) copy=$det/b ;; esac
  rel="run/$(basename "$f")"
  (cd $dir && "$anew" emit-c "$rel" --test) >$tmp/c1 2>&1
  (cd $dir && "$anew" emit-c "$rel" --test) >$tmp/c2 2>&1
  (cd $copy && "$anew" emit-c "$rel" --test) >$tmp/c3 2>&1
  if cmp -s $tmp/c1 $tmp/c2 && cmp -s $tmp/c1 $tmp/c3; then
    dok=$((dok + 1))
  else
    echo "FAIL determinism: emit-c $f"
    diff $tmp/c1 $tmp/c3 | head -10
    fail=1
  fi
done
if [ "$dok" = "$dtotal" ]; then v="ok  "; else v="FAIL"; fi
echo "$v determinism: $dok/$dtotal programs give byte-identical C twice and from a copy at another path"
# the C name clash check stops lowering loudly (exit 3 and both names)
$new emit-c compiler/tests/lower/clash.ei >$tmp/o 2>$tmp/e
code=$?
if [ $code = 3 ] && grep -q 'C name clash: `f_Sq__area` names both `Sq__area` and `Sq.area`' $tmp/e; then
  echo "ok   names: a C name clash is an internal error (compiler/tests/lower/clash.ei)"
else
  echo "FAIL names: compiler/tests/lower/clash.ei exited $code: $(cat $tmp/e)"
  fail=1
fi

# export: `eiderc build --lib`, its header, and checking as a library
if out=$(EIDER=$new sh tests/export/run.sh 2>&1); then echo "$out (eiderc)"; else echo "FAIL tests/export with eiderc: $out"; fail=1; fi
if out=$(sh compiler/tests/export/run.sh $new 2>&1); then echo "$out"; else echo "$out"; fail=1; fi
lagree=0
ltotal=0
for f in tests/export/mathlib.ei compiler/tests/export/shapes.ei compiler/tests/export/nested.ei tests/run/ffi.ei tests/checks/pass/pass_import_and_ffi.ei; do
  ltotal=$((ltotal + 1))
  want=$($boot check --lib --json "$f" 2>&1)
  got=$($new check --lib --json "$f" 2>&1)
  if [ "$want" != "$got" ]; then
    echo "FAIL check --lib $f"
    echo "  bootstrap: $want"
    echo "  eiderc:    $got"
    fail=1
    continue
  fi
  # nested.ei: stage 0's header lacks the inner record's typedef (compiler/tests/export)
  case "$f" in tests/export/*|*/shapes.ei)
    $boot emit-header "$f" >$tmp/h_want 2>&1
    $new emit-header "$f" >$tmp/h_got 2>&1
    if ! cmp -s $tmp/h_want $tmp/h_got; then
      echo "FAIL emit-header $f"
      fail=1
      continue
    fi
  esac
  lagree=$((lagree + 1))
done
if [ "$lagree" = "$ltotal" ]; then v="ok  "; else v="FAIL"; fi
echo "$v export: $lagree/$ltotal files agree on check --lib and emit-header"

# unit: compiler modules driven by a program in compiler/tests/unit, compared with the .out
# (hand-checked: sha256.out against FIPS 180-4 and sha256sum)
for f in compiler/tests/unit/*.ei; do
  outcome env EIDER_CFLAGS=-Werror $new run "$f"
  { cat "${f%.ei}.out"; echo "--- stderr"; echo "--- exit 0"; } >$tmp/want
  if cmp -s $tmp/want $tmp/out; then echo "ok   unit $f"; else echo "FAIL unit $f"; diff $tmp/want $tmp/out | head -10; fail=1; fi
done

# compile-fail: `eiderc test --compile-fail` against stage 0's runner
for d in compiler/tests/check compiler/tests/suite; do
  $boot test --compile-fail $d >$tmp/cf_want 2>&1
  wcode=$?
  $new test --compile-fail $d >$tmp/cf_got 2>&1
  gcode=$?
  if [ $wcode = $gcode ] && cmp -s $tmp/cf_want $tmp/cf_got; then
    echo "ok   compile-fail: test --compile-fail $d equals stage 0's ($(grep 'error-code coverage' $tmp/cf_got))"
  else
    echo "FAIL compile-fail: test --compile-fail $d (exit $gcode, stage 0 $wcode)"
    diff $tmp/cf_want $tmp/cf_got | head -10
    fail=1
  fi
done
# tests/checks: files eiderc can't check yet (comptime, threads, wasm mode) are `skip`; every
# other line is stage 0's
$boot test --compile-fail tests/checks >$tmp/cf_want 2>&1
$new test --compile-fail tests/checks >$tmp/cf_got 2>&1
gcode=$?
grep '^  skip ' $tmp/cf_got | awk '{print "  ok   " $2 " "}' >$tmp/cf_skipped
grep -v -F -f $tmp/cf_skipped $tmp/cf_want | grep -v 'passed, .* failed; error-code coverage' | grep -v '^codes without' >$tmp/cf_w
grep -v '^  skip ' $tmp/cf_got | grep -v 'skipped (not yet supported by eiderc)' | grep -v 'passed, .* failed; error-code coverage' | grep -v '^codes without' >$tmp/cf_g
# the skipped-count line is followed by a blank line of its own
uniq $tmp/cf_w >$tmp/cf_w2
uniq $tmp/cf_g >$tmp/cf_g2
summary=$(grep 'error-code coverage' $tmp/cf_got)
if [ $gcode = 0 ] && cmp -s $tmp/cf_w2 $tmp/cf_g2 && echo "$summary" | grep -q ' 0 failed'; then
  echo "ok   compile-fail: tests/checks: $summary; skipped:$(grep '^  skip ' $tmp/cf_got | awk '{printf " %s", $2}')"
  grep '^codes without' $tmp/cf_got | sed 's/^/     /'
else
  echo "FAIL compile-fail: tests/checks (exit $gcode): $summary"
  diff $tmp/cf_w2 $tmp/cf_g2 | head -10
  fail=1
fi

# cache: EIDER_CACHE=<dir> (driver.ei, "Cache")
cdir=$(pwd)/target/cachetest
rm -rf $cdir
cache_ok=1
cfail() { echo "FAIL cache: $1"; cache_ok=0; fail=1; }
EIDER_CACHE=$cdir $new build tests/run/adt.ei -o $tmp/adt1 || cfail "build"
EIDER_CACHE=$cdir $new build tests/run/adt.ei -o $tmp/adt2 || cfail "second build"
[ "$(ls $cdir/bin | wc -l)" = 1 ] || cfail "a second build of the same program made another binary"
[ "$(ls $cdir/core | wc -l)" = 1 ] || cfail "a second build compiled the core again"
$tmp/adt2 >$tmp/o 2>&1
cmp -s $tmp/o tests/run/adt.out || cfail "the binary copied out of the cache is wrong"
EIDER_CACHE=$cdir $new run tests/run/adt.ei >$tmp/o 2>&1
cmp -s $tmp/o tests/run/adt.out || cfail "run"
# -O0 for run: one more binary and one more set of core objects
[ "$(ls $cdir/bin | wc -l)" = 2 ] && [ "$(ls $cdir/core | wc -l)" = 2 ] || cfail "run should add one binary and one core build"
EIDER_CACHE=$cdir EIDER_CFLAGS=-DEI_RT_COUNT_ALLOCS $new run tests/run/adt.ei >$tmp/o 2>&1
grep -q '^eider: outstanding allocations: 0' $tmp/o || cfail "EIDER_CFLAGS is not part of the key (the counting runtime didn't run)"
[ "$(ls $cdir/core | wc -l)" = 3 ] || cfail "new flags should compile the core once more"
# twelve concurrent runs of a new program on that cache
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  (EIDER_CACHE=$cdir $new run tests/run/closures.ei >$tmp/conc$i 2>&1; echo "exit $?" >>$tmp/conc$i) &
done
wait
{ cat tests/run/closures.out; echo "exit 0"; } >$tmp/conc_want
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  cmp -s $tmp/conc_want $tmp/conc$i || cfail "concurrent run $i: $(head -3 $tmp/conc$i)"
done
[ -z "$(ls $cdir/tmp)" ] || cfail "work directories left in $cdir/tmp"
EIDER_CACHE=off $new run tests/run/adt.ei >/dev/null 2>&1
[ "$(ls $cdir/bin | wc -l)" = 4 ] || cfail "EIDER_CACHE=off still used the cache"
# comptime evaluators go through the cache too (twice: built, then cache hits)
for i in 1 2; do
  EIDER_CACHE=$cdir $new run tests/run/comptime.ei >$tmp/o 2>&1
  cmp -s $tmp/o tests/run/comptime.out || cfail "comptime with the cache (pass $i)"
done
rm -rf $cdir
[ $cache_ok = 1 ] && echo "ok   cache: hits, keys (flags, -O level), core objects once per toolchain, 12 concurrent runs, comptime evaluators, EIDER_CACHE=off"

# usage: --help lists every command; unknown options and commands are errors
$new --help >$tmp/o 2>&1
code=$?
uok=1
[ $code = 0 ] || uok=0
for c in check emit-c emit-header build "build --lib" "build --wasm" run test "test --compile-fail" lex parse ir help; do
  grep -q "^  eiderc $c " $tmp/o || { echo "FAIL usage: --help does not list \`$c\`"; uok=0; }
done
$new check --no-such-flag tests/run/adt.ei >/dev/null 2>&1
[ $? = 2 ] || { echo "FAIL usage: an unknown option is not an error"; uok=0; }
$new frobnicate tests/run/adt.ei >/dev/null 2>&1
[ $? = 2 ] || { echo "FAIL usage: an unknown command is not an error"; uok=0; }
$new check tests/run/adt.ei extra.ei >/dev/null 2>&1
[ $? = 2 ] || { echo "FAIL usage: a stray argument is not an error"; uok=0; }
if [ $uok = 1 ]; then echo "ok   usage: --help lists every command; unknown options, commands and stray arguments exit 2"; else fail=1; fi
exit $fail
