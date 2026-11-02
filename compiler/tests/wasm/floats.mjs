// usage: node floats.mjs <dir with floats.js and floats.wasm>
import { readFileSync } from 'fs';
const dir = process.argv[2];
const { load } = await import(dir + '/floats.js');
const wasm = readFileSync(dir + '/floats.wasm');
console.log('imports:', WebAssembly.Module.imports(new WebAssembly.Module(wasm)).map((i) => `${i.module}.${i.name}`).sort().join(' '));
const m = await load(wasm, { host_half: (v) => v / 2, host_third: (v) => v / 4 });
console.log('mean', m.mean(1.5, 2.25));
console.log('scale32', m.scale32(1.1, 3), Math.fround(Math.fround(1.1) * 3));
console.log('is_nan', m.is_nan(NaN), m.is_nan(1));
console.log('trunc_to', m.trunc_to(-3.99), m.trunc_to(2147483647.5));
try { m.trunc_to(NaN); } catch (e) { console.log('NaN traps:', e.constructor.name); }
console.log('widen', m.widen(0.1));
console.log('via_host', m.via_host(5, 2));
console.log('maths', m.maths(4.5).toFixed(9));
console.log('bits', m.bits(1.5));
console.log('text', m.text(2.0 / 3.0));
