// usage: node bits.mjs <dir with bits.js and bits.wasm>
import { readFileSync } from 'fs';
const dir = process.argv[2];
const { load } = await import(dir + '/bits.js');
const m = await load(readFileSync(dir + '/bits.wasm'));
const show = (v) => `${typeof v} ${v}`;
console.log(show(m.mix(0x1234, 3)), show(m.sar(-9n, 2n)), show(m.flip(15)));
console.log(show(m.text_sum()));
try { m.sar(1n, 64n); console.log('sar no trap'); } catch (e) { console.log('sar', e.constructor.name); }
