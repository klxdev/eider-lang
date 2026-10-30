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
#   export:   libraries from `eiderc build --lib`: tests/export/run.sh (the C and C++
#             consumers of the bootstrap's suite) with EIDER=eiderc, compiler/tests/export/run.sh
#             (eiderc's own: more types, nested records, two libraries, traps), and
#             `emit-header` and `check --lib --json` equal to the bootstrap's.
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
exit $fail
