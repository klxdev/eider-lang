#!/bin/sh
# eiderc's WebAssembly tests (scripts/test-compiler.sh, "wasm"). For each X.ei here:
# `eiderc build --wasm` gives X.wasm, X.d.ts and X.js; `node X.mjs` against them must print
# X.out; with a second compiler (stage 0) the same program must give the same node output
# and byte-identical X.d.ts and X.js (unless line 1 is `// stage 0 differs: <why>`, for a
# stage-0 shim bug: then only X.out counts, and stage 0 must really differ). Also: tests/wasm/core.sh (core/wasm and the emitted C
# compile as strict freestanding C) and tests/wasm/run.sh (calc.ei) with EIDER=eiderc.
# WebAssembly is optional (LAYERS.md, "Dependencies"): without clang's wasm32 target,
# wasm-ld or node this prints `skip` with the reason and succeeds.
# usage: run.sh <eiderc> [<stage0>]
cd "$(dirname "$0")/../../.." || exit 1
E=$1
B=$2
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
n=0
ok=0
for f in compiler/tests/wasm/*.ei; do
  x=$(basename "$f" .ei)
  n=$((n + 1))
  mkdir -p $T/new $T/old
  $E build --wasm "$f" -o $T/new/$x >$T/log 2>&1 || { echo "FAIL build --wasm $f:"; cat $T/log; fail=1; continue; }
  [ "$(cat $T/log)" = "built $T/new/$x.wasm, $T/new/$x.d.ts, $T/new/$x.js" ] || { echo "FAIL build --wasm $f message: $(cat $T/log)"; fail=1; continue; }
  node compiler/tests/wasm/$x.mjs $T/new >$T/new.out 2>&1
  if ! cmp -s compiler/tests/wasm/$x.out $T/new.out; then
    echo "FAIL wasm $f:"; diff compiler/tests/wasm/$x.out $T/new.out | head -20; fail=1; continue
  fi
  if [ -n "$B" ]; then
    $B build --wasm "$f" -o $T/old/$x >$T/log 2>&1 || { echo "FAIL stage 0 build --wasm $f:"; cat $T/log; fail=1; continue; }
    node compiler/tests/wasm/$x.mjs $T/old >$T/old.out 2>&1
    # `// stage 0 differs:` on line 1: a stage-0 shim bug, so X.out alone is the reference
    if head -1 "$f" | grep -q '^// stage 0 differs:'; then
      if cmp -s $T/old.out $T/new.out; then echo "FAIL wasm $f: says stage 0 differs, but it agrees"; fail=1; continue; fi
    elif ! cmp -s $T/old.out $T/new.out; then
      echo "FAIL wasm $f: stage 0's module behaves differently:"; diff $T/old.out $T/new.out | head -20; fail=1; continue
    fi
    if ! cmp -s $T/old/$x.d.ts $T/new/$x.d.ts || ! cmp -s $T/old/$x.js $T/new/$x.js; then
      echo "FAIL wasm $f: .d.ts or .js differ from stage 0's"; fail=1; continue
    fi
  fi
  ok=$((ok + 1))
done
rm -rf $T
if [ "$ok" = "$n" ]; then v="ok  "; else v="FAIL"; fi
if [ -n "$B" ]; then vs=", same node output and byte-identical .d.ts/.js as stage 0"; else vs=""; fi
echo "$v wasm: $ok/$n eiderc build --wasm modules give the expected node output$vs"
exit $fail
