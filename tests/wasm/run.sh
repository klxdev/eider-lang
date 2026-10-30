#!/bin/sh
# Builds calc.ei to WebAssembly and checks it from Node.
# EIDER=<compiler> picks the compiler (default: scripts/ei, the seed's eiderc).
set -e
case "$EIDER" in ""|/*) ;; */*) EIDER=$(pwd)/$EIDER ;; esac
cd "$(dirname "$0")"
EIDER=${EIDER:-$(cd ../.. && pwd)/scripts/ei}
T=$(mktemp -d)
$EIDER build --wasm calc.ei -o "$T/calc" >/dev/null
cat > "$T/t.mjs" <<JS
import { readFileSync } from 'fs';
import { load } from '$T/calc.js';
const m = await load(readFileSync('$T/calc.wasm'));
const got = [m.add(2,3), m.fib(50), m.is_even(4), m.is_even(3), m.sum_to(100)].join(' ');
let trap = 'none'; try { m.div(1,0) } catch (e) { trap = e.constructor.name }
console.log(got + ' ' + trap);
JS
out=$(node "$T/t.mjs" 2>/dev/null | tail -1)
rm -rf "$T"
[ "$out" = "5 12586269025 true false 4950 RuntimeError" ] && echo "ok   tests/wasm" || { echo "FAIL tests/wasm: $out"; exit 1; }
