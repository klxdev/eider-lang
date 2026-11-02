#!/bin/sh
# `eiderc fmt` (compiler/fmt.ei): over every .ei file in the repository,
#   - it either prints a formatted file or refuses with a reason (a `"""` string);
#     "internal error" (the tokens changed, or a second pass changed the text) is a failure;
#   - the output is a fixed point: formatting it again prints it unchanged (checked here with
#     a separate run, besides fmt's own check);
#   - `eiderc check` says the same about the original and the formatted file for the files in
#     compiler/tests/{parse_ok,check} (so formatting changes no diagnostics).
# Then a fuzz: each of a sample of files is mangled (indentation replaced by random
# indentation or tabs, trailing white space and extra blank lines added, CRLF line ends) and
# must format to exactly what the original formats to.
# usage: run.sh <eiderc> [fuzz seed]   (the seed is printed; a failure keeps the mangled file
# in target/fmttest/)
cd "$(dirname "$0")/../.." || exit 1
E=$1
case "$E" in /*) ;; *) E=$(pwd)/$E ;; esac
seed=${2:-$$}
T=target/fmttest
rm -rf $T
mkdir -p $T
fail=0
n=0
refused=0
changed=0
for f in $(find . -name '*.ei' -not -path './target/*' -not -path './.vendor/*' -not -path './.git/*' | sort); do
  n=$((n + 1))
  if ! $E fmt "$f" > $T/a.ei 2> $T/err; then
    if grep -q "multi-line string" $T/err; then refused=$((refused + 1)); continue; fi
    # a file that does not lex (tests of lexing errors) is refused with the lexer's message
    if $E lex "$f" >/dev/null 2>&1; then echo "FAIL fmt $f: $(cat $T/err)"; fail=1; fi
    refused=$((refused + 1))
    continue
  fi
  $E fmt $T/a.ei > $T/b.ei 2> $T/err || { echo "FAIL fmt $f: the output does not format: $(cat $T/err)"; fail=1; continue; }
  cmp -s $T/a.ei $T/b.ei || { echo "FAIL fmt $f: not idempotent"; diff $T/a.ei $T/b.ei | head -5; fail=1; continue; }
  cmp -s "$f" $T/a.ei || changed=$((changed + 1))
done
echo "fmt: $n files, $refused refused (multi-line strings, lexing errors), $changed would change"

# diagnostics are the same before and after
c=0
for f in compiler/tests/parse_ok/*.ei compiler/tests/check/pass/*.ei compiler/tests/check/fail/*.ei; do
  [ -f "$f" ] || continue
  $E fmt "$f" > $T/a.ei 2>/dev/null || continue
  # (next to the original, so that its imports still resolve)
  side="$(dirname "$f")/zz_fmtcheck_$$.ei"
  cp $T/a.ei "$side"
  $E check --json "$f" 2>&1 | sed 's/"line":[0-9]*,"col":[0-9]*//g; s/"file":"[^"]*"//g; s/"fix":{[^}]*}//g' > $T/c1
  $E check --json "$side" 2>&1 | sed 's/"line":[0-9]*,"col":[0-9]*//g; s/"file":"[^"]*"//g; s/"fix":{[^}]*}//g' > $T/c2
  rm -f "$side"
  cmp -s $T/c1 $T/c2 || { echo "FAIL fmt $f: diagnostics differ after formatting"; diff $T/c1 $T/c2 | head -4; fail=1; }
  c=$((c + 1))
done
echo "fmt: diagnostics equal before and after on $c files"

# fuzz: layout-only mangling must not change the result
awk_mangle='
BEGIN { srand(seed) }
{
  line = $0
  sub(/^[ \t]+/, "", line)
  r = int(rand() * 6)
  if (line == "") { print ""; if (rand() < 0.3) print ""; next }
  if (r == 0) ind = "\t"
  else if (r == 1) ind = ""
  else if (r == 2) ind = "   "
  else if (r == 3) ind = "\t\t  "
  else if (r == 4) ind = "          "
  else ind = "  "
  tail = ""
  if (rand() < 0.3) tail = "   \t"
  printf "%s%s%s\r\n", ind, line, tail
}'
k=0
for f in $(find . -name '*.ei' -not -path './target/*' -not -path './.vendor/*' -not -path './.git/*' | sort | awk -v s="$seed" 'BEGIN { srand(s) } rand() < 0.08'); do
  $E fmt "$f" > $T/a.ei 2>/dev/null || continue
  # (lines inside a block comment are left as they are, so files with one are not mangled)
  grep -q '/\*' "$f" && continue
  awk -v seed="$seed" "$awk_mangle" "$f" > $T/m.ei
  if ! $E fmt $T/m.ei > $T/b.ei 2> $T/err; then echo "FAIL fmt fuzz $f (seed $seed): $(cat $T/err)"; cp $T/m.ei $T/fail_$k.ei; fail=1; continue; fi
  if ! cmp -s $T/a.ei $T/b.ei; then echo "FAIL fmt fuzz $f (seed $seed): the mangled file formats differently"; diff $T/a.ei $T/b.ei | head -6; cp $T/m.ei $T/fail_$k.ei; fail=1; fi
  k=$((k + 1))
done
echo "fmt: fuzz seed $seed: $k mangled files format like their originals"
[ $fail = 0 ] && { echo "ok   fmt (idempotent, tokens unchanged, diagnostics unchanged, layout fuzz)"; rm -rf $T; }
exit $fail
