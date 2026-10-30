#!/bin/sh
# Tests for the self-hosted compiler (compiler/). Differential: the bootstrap is the oracle.
#
#   front:    for every .ei in the repo and in compiler/tests/{lex,parse}, whenever either
#             compiler reports a lex or parse error, both must report the same JSON diagnostic.
#   lex_ok:   token dumps of compiler/tests/lex_ok/*.ei match their .tokens goldens
#             (BLESS=1 rewrites the goldens; review the diff).
#   ir:       IR dumps of compiler/tests/ir/*.ei match their .ir goldens (BLESS=1 too).
#   check:    for every compile-fail/pass test (tests/checks/{fail,pass}) whose features eiderc
#             supports (it doesn't answer `unsupported`), `eiderc check --json` must equal the
#             bootstrap's byte for byte; the same for tests/run/*.ei. eiderc's own cases in
#             compiler/tests/check/{fail,pass} must all be in scope and agree.
cd "$(dirname "$0")/.." || exit 1
scripts/bootstrap-deps.sh
boot=$(scripts/stage0.sh) || exit 3
EIDER_CACHE=off scripts/ei build compiler/main.ei -o target/eiderc >/dev/null 2>target/eiderc.build.log || { cat target/eiderc.build.log; echo "FAIL build eiderc"; exit 1; }
new=./target/eiderc
# the front end's diagnostics: E0001, plus the parser's E0302 for `inout` in a type and E0402
# for `null`, in the entry file
frontmsg='"error":"(E0001|E0402)"|"error":"E0302".*"message":"`inout` is only valid on function parameters'
front() {
  case "$1" in *"\"file\":\"$2\""*) ;; *) return ;; esac
  echo "$1" | grep -E "$frontmsg"
}
fail=0
n=0
for f in $(find . -name '*.ei' -not -path './target/*' -not -path '*/deps/*' | sort); do
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
check_set 0 tests/checks/fail/*.ei tests/checks/pass/*.ei
echo "ok   check: $agree/$inscope check tests in scope agree ($total tests, $((total - inscope)) out of scope)"
echo "     out of scope:$outside"
check_set 0 tests/run/*.ei
echo "ok   check: $agree/$inscope run tests in scope agree ($total tests)"
check_set 1 compiler/tests/check/fail/*.ei compiler/tests/check/pass/*.ei
echo "ok   check: $agree/$inscope eiderc check cases agree (compiler/tests/check)"
exit $fail
