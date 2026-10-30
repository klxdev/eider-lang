#!/bin/sh
# Record the stage-0 oracle (docs/compiler.md, "Testing"): run the stage-0 bootstrap over
# every input that scripts/test-compiler.sh and compiler/tests/wasm/run.sh compared eiderc
# against, and write each observable result to tests/oracle/<source path without .ei>.<kind>:
#
#   .front               the lex/parse diagnostic (first line of `check --json`, filtered as
#                        test-compiler.sh's front end does); only written when non-empty
#   .check.json          `check --json` (`--wasm` for a `// mode: wasm` file), stdout+stderr
#   .run, .test          `run` / `test`: stdout, `--- stderr`, stderr, `--- exit <code>`
#                        (not for a compiler/tests/run file with a hand-written X.out / X.test.out)
#   .check-lib.json      `check --lib --json`
#   .emit-header         `emit-header`
#   .check-wasm.json     `check --wasm --json`
#   .emit-header-wasm    `emit-header --wasm` (declarations, \x01, the loader)
#   .node, .d.ts, .js    compiler/tests/wasm: the node output of the module `build --wasm` makes,
#                        and the .d.ts and .js it writes
#   <dir>.compile-fail   `test --compile-fail <dir>`: its output, then `--- exit <code>`
#
# The checkout's absolute path is written `<root>` (one E0808 message names module paths).
# Run once, while stage 0 still existed; from then on the expected files change only through
# BLESS=1 (scripts/test-compiler.sh), reviewed in the diff.
cd "$(dirname "$0")/.." || exit 1
scripts/bootstrap-deps.sh
boot=$(scripts/stage0.sh) || exit 3
EIDER_CACHE=off; export EIDER_CACHE
O=tests/oracle
rm -rf $O
# o <source> <kind>: the oracle file for that (input, command)
o() { p="$O/${1%.ei}.$2"; mkdir -p "$(dirname "$p")"; echo "$p"; }
tmp=target/oracle
rm -rf $tmp
mkdir -p $tmp
outcome() {
  "$@" >$tmp/o 2>$tmp/e
  code=$?
  { cat $tmp/o; echo "--- stderr"; cat $tmp/e; echo "--- exit $code"; } >$tmp/out
}

# front end: the same filter as test-compiler.sh
frontmsg='"error":"(E0001|E0402)"|"error":"E0302".*"message":"`inout` is only valid on function parameters'
front() {
  case "$1" in *"\"file\":\"$2\""*) ;; *) return ;; esac
  echo "$1" | grep -E "$frontmsg"
}
for f in $(find . -name '*.ei' -not -path './target/*' -not -path './.claude/*' -not -path '*/deps/*' | sort); do
  want=$(front "$($boot check --json "$f" 2>/dev/null | head -1)" "$f")
  if [ -n "$want" ]; then echo "$want" >"$(o "${f#./}" front)"; fi
done

for f in tests/checks/fail/*.ei tests/checks/pass/*.ei tests/run/*.ei compiler/tests/check/fail/*.ei compiler/tests/check/pass/*.ei; do
  wf=""
  if grep -q '// mode: wasm' "$f"; then wf=--wasm; fi
  $boot check --json $wf "$f" >"$(o "$f" check.json)" 2>&1
done

for f in tests/run/*.ei compiler/tests/run/*.ei; do
  case "$f" in compiler/tests/run/*) [ -f "${f%.ei}.out" ] && skiprun=1 || skiprun=0 ;; *) skiprun=0 ;; esac
  if [ $skiprun = 0 ]; then outcome $boot run "$f"; cp $tmp/out "$(o "$f" run)"; fi
  if grep -q '^test ' "$f"; then
    case "$f" in compiler/tests/run/*) [ -f "${f%.ei}.test.out" ] && continue ;; esac
    outcome $boot test "$f"; cp $tmp/out "$(o "$f" test)"
  fi
done

for f in tests/export/mathlib.ei compiler/tests/export/shapes.ei compiler/tests/export/nested.ei tests/run/ffi.ei tests/checks/pass/pass_import_and_ffi.ei; do
  $boot check --lib --json "$f" >"$(o "$f" check-lib.json)" 2>&1
done
# nested.ei: stage 0's header lacks the inner record's typedef, so it is not compared
for f in tests/export/mathlib.ei compiler/tests/export/shapes.ei; do
  $boot emit-header "$f" >"$(o "$f" emit-header)" 2>&1
done

for f in tests/wasm/*.ei compiler/tests/wasm/*.ei compiler/tests/wasm/check/*.ei; do
  $boot check --wasm --json "$f" >"$(o "$f" check-wasm.json)" 2>&1
  $boot emit-header --wasm "$f" >"$(o "$f" emit-header-wasm)" 2>&1
done
T=$(pwd)/$tmp/wasm
for f in compiler/tests/wasm/*.ei; do
  x=$(basename "$f" .ei)
  mkdir -p $T
  $boot build --wasm "$f" -o $T/$x >$tmp/log 2>&1 || { echo "record-oracle: stage 0 build --wasm $f failed"; cat $tmp/log; exit 1; }
  node compiler/tests/wasm/$x.mjs $T >"$(o "$f" node)" 2>&1
  cp $T/$x.d.ts "$(o "$f" d.ts)"
  cp $T/$x.js "$(o "$f" js)"
done

for d in compiler/tests/check compiler/tests/suite tests/checks; do
  $boot test --compile-fail $d >$tmp/o 2>&1
  code=$?
  { cat $tmp/o; echo "--- exit $code"; } >"$O/$d.compile-fail"
done
rm -rf $tmp
# no absolute paths: the checkout's root is written <root> (test-compiler.sh's norm)
rootre=$(pwd | sed 's/[]\/.[*^$|]/\\&/g')
find $O -type f | while read -r p; do
  if grep -q -F "$(pwd)/" "$p"; then sed "s|$rootre/|<root>/|g" "$p" >$O/.n && mv $O/.n "$p"; fi
done
echo "recorded $(find $O -type f | wc -l) files in $O ($(du -sk $O | cut -f1) KB)"
