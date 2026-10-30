#!/bin/sh
# Tests for the self-hosted compiler (compiler/). Differential: the bootstrap is the oracle.
#
#   lex:      for every .ei in the repo and in compiler/tests/lex, whenever either compiler
#             reports a lexer error, both must report the same JSON diagnostic.
#   lex_ok:   token dumps of compiler/tests/lex_ok/*.ei match their .tokens goldens
#             (BLESS=1 rewrites the goldens; review the diff).
cd "$(dirname "$0")/.." || exit 1
scripts/bootstrap-deps.sh
boot=$(scripts/stage0.sh) || exit 3
EIDER_CACHE=off scripts/ei build compiler/main.ei -o target/eiderc >/dev/null 2>target/eiderc.build.log || { cat target/eiderc.build.log; echo "FAIL build eiderc"; exit 1; }
new=./target/eiderc
lexmsg='unexpected character|unterminated string literal|unknown escape sequence|unterminated block comment|integer literal too large|expected hex digits after 0x'
fail=0
n=0
for f in $(find . -name '*.ei' -not -path './target/*' -not -path '*/deps/*' | sort); do
  n=$((n + 1))
  want=$($boot check --json "$f" 2>/dev/null | head -1)
  got=$($new check --json "$f" 2>/dev/null | head -1)
  # the bootstrap also parses, type-checks and follows imports; compare lexer errors only,
  # and only those in the entry file
  case "$want" in *"\"file\":\"$f\""*) ;; *) want="" ;; esac
  echo "$want" | grep -qE "\"error\":\"E0001\".*\"message\":\"($lexmsg)" || want=""
  if [ "$want" != "$got" ]; then
    echo "FAIL lex $f"
    echo "  bootstrap: $want"
    echo "  eiderc:    $got"
    fail=1
  fi
done
[ $fail = 0 ] && echo "ok   lex: $n files agree with the bootstrap"
for f in compiler/tests/lex_ok/*.ei; do
  g="${f%.ei}.tokens"
  if [ -n "$BLESS" ]; then $new lex "$f" > "$g"; fi
  if $new lex "$f" | cmp -s - "$g"; then echo "ok   lex_ok $f"; else echo "FAIL lex_ok $f"; $new lex "$f" | diff "$g" - | head -10; fail=1; fi
done
exit $fail
