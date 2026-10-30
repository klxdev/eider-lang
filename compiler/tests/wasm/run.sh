#!/bin/sh
# eiderc's WebAssembly tests (scripts/test-compiler.sh, "wasm"). For each X.ei here:
# `eiderc build --wasm` gives X.wasm, X.d.ts and X.js; `node X.mjs` against them must print
# X.out, and the recorded oracle (scripts/test-compiler.sh): the node output must equal
# tests/oracle/compiler/tests/wasm/X.node and X.d.ts and X.js must equal the oracle's byte for
# byte (unless line 1 is `// oracle differs: <why>`, for a bug of the bootstrap's shim that
# eiderc fixes: then only X.out counts, and the recorded output must really differ).
# BLESS=1 rewrites the oracle files from eiderc's (X.node not for `oracle differs` files).
# Also: tests/wasm/core.sh (core/wasm and the emitted C compile as strict freestanding C) and
# tests/wasm/run.sh (calc.ei) with EIDER=eiderc.
# WebAssembly is optional (LAYERS.md, "Dependencies"): without clang's wasm32 target,
# wasm-ld or node this prints `skip` with the reason and succeeds.
# usage: run.sh <eiderc>
cd "$(dirname "$0")/../../.." || exit 1
E=$1
O=tests/oracle/compiler/tests/wasm
case "$E" in /*) ;; *) E=$(pwd)/$E ;; esac
WASM_CC=${WASM_CC:-clang}
fail=0
if ! out=$(EIDER=$E sh tests/wasm/core.sh 2>&1); then fail=1; fi
echo "$out"
printf 'int x;\n' >target/wasmprobe.c
if ! $WASM_CC --target=wasm32 -c -o target/wasmprobe.o target/wasmprobe.c 2>/dev/null || ! command -v wasm-ld >/dev/null || ! command -v node >/dev/null; then
  rm -f target/wasmprobe.c target/wasmprobe.o
  echo "skip wasm: build --wasm needs $WASM_CC with the wasm32 target, wasm-ld and node"
  exit $fail
fi
rm -f target/wasmprobe.c target/wasmprobe.o
if out=$(EIDER=$E sh tests/wasm/run.sh 2>&1); then echo "$out (eiderc)"; else echo "$out (eiderc)"; fail=1; fi
T=$(pwd)/target/wasmtest
rm -rf $T
# the loaders are ES modules: say so, so a package.json above the checkout (say one with
# "type": "commonjs") can't make node read them as CommonJS
mkdir -p $T
printf '{ "type": "module" }\n' >$T/package.json
n=0
ok=0
for f in compiler/tests/wasm/*.ei; do
  x=$(basename "$f" .ei)
  n=$((n + 1))
  mkdir -p $T/new
  $E build --wasm "$f" -o $T/new/$x >$T/log 2>&1 || { echo "FAIL build --wasm $f:"; cat $T/log; fail=1; continue; }
  [ "$(cat $T/log)" = "built $T/new/$x.wasm, $T/new/$x.d.ts, $T/new/$x.js" ] || { echo "FAIL build --wasm $f message: $(cat $T/log)"; fail=1; continue; }
  node compiler/tests/wasm/$x.mjs $T/new >$T/new.out 2>&1
  if ! cmp -s compiler/tests/wasm/$x.out $T/new.out; then
    echo "FAIL wasm $f:"; diff compiler/tests/wasm/$x.out $T/new.out | head -20; fail=1; continue
  fi
  # `// oracle differs:` on line 1: the recorded module had a shim bug, so X.out alone is
  # the reference
  differs=0
  if head -1 "$f" | grep -q '^// oracle differs:'; then differs=1; fi
  if [ -n "$BLESS" ]; then
    [ $differs = 0 ] && cp $T/new.out $O/$x.node
    cp $T/new/$x.d.ts $O/$x.d.ts
    cp $T/new/$x.js $O/$x.js
  fi
  if [ $differs = 1 ]; then
    if cmp -s $O/$x.node $T/new.out; then echo "FAIL wasm $f: says the oracle differs, but it agrees"; fail=1; continue; fi
  elif ! cmp -s $O/$x.node $T/new.out; then
    echo "FAIL wasm $f: the node output differs from the oracle's:"; diff $O/$x.node $T/new.out | head -20; fail=1; continue
  fi
  if ! cmp -s $O/$x.d.ts $T/new/$x.d.ts || ! cmp -s $O/$x.js $T/new/$x.js; then
    echo "FAIL wasm $f: .d.ts or .js differ from the oracle's"; fail=1; continue
  fi
  ok=$((ok + 1))
done
rm -rf $T
if [ "$ok" = "$n" ]; then v="ok  "; else v="FAIL"; fi
echo "$v wasm: $ok/$n eiderc build --wasm modules give the expected node output, and the oracle's node output and .d.ts/.js"
exit $fail
