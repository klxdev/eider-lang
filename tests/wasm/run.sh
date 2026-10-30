#!/bin/sh
# Builds calc.ei to WebAssembly and checks it from Node.
set -e
cd "$(dirname "$0")"
EIDER=${EIDER:-$(../../scripts/stage0.sh)} || exit 3
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
[ "$out" = "5 12586269025 true false 4950 RuntimeError" ] && echo "ok   tests/wasm" || { echo "FAIL tests/wasm: $out"; exit 1; }
