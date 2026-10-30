#!/bin/sh
# Tests for the self-hosted compiler (compiler/). Differential: the bootstrap is the oracle.
#
#   front:    for every .ei in the repo and in compiler/tests/{lex,parse}, whenever either
#             compiler reports a lex or parse error, both must report the same JSON diagnostic.
#   lex_ok:   token dumps of compiler/tests/lex_ok/*.ei match their .tokens goldens
#   parse_ok: AST dumps of compiler/tests/parse_ok/*.ei match their .ast goldens
#             (BLESS=1 rewrites both kinds of golden; review the diff).
cd "$(dirname "$0")/.." || exit 1
scripts/bootstrap-deps.sh
boot=$(scripts/stage0.sh) || exit 3
EIDER_CACHE=off scripts/ei build compiler/main.ei -o target/eiderc >/dev/null 2>target/eiderc.build.log || { cat target/eiderc.build.log; echo "FAIL build eiderc"; exit 1; }
new=./target/eiderc
# eiderc implements lexing and parsing so far: compare the diagnostics those passes produce
# (E0001, plus the parser's E0302 for `inout` in a type and E0402 for `null`)
frontmsg='"error":"(E0001|E0402)"|"error":"E0302".*"message":"`inout` is only valid on function parameters'
fail=0
n=0
for f in $(find . -name '*.ei' -not -path './target/*' -not -path '*/deps/*' | sort); do
  n=$((n + 1))
  want=$($boot check --json "$f" 2>/dev/null | head -1)
  got=$($new check --json "$f" 2>/dev/null | head -1)
  # the bootstrap also parses, type-checks and follows imports; compare lexer errors only,
  # and only those in the entry file
  case "$want" in *"\"file\":\"$f\""*) ;; *) want="" ;; esac
  echo "$want" | grep -qE "$frontmsg" || want=""
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
exit $fail
