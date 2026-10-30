// usage: node ints.mjs <dir with ints.js and ints.wasm>
import { readFileSync } from 'fs';
const dir = process.argv[2];
const { load } = await import(dir + '/ints.js');
const m = await load(readFileSync(dir + '/ints.wasm'));
const show = (v) => `${typeof v} ${v}`;
console.log(show(m.i32_neg(7)), show(m.i32_neg(-2147483647)));
console.log(show(m.i64_twice(-4611686018427387904n)), show(m.i64_twice(21n)));
console.log(show(m.u8_next(254)));
console.log(show(m.u32_max()));
console.log(show(m.u64_big(18446744073n)));
console.log(show(m.usize_len(1000n)));
console.log(show(m.not(true)), show(m.not(false)));
console.log(show(m.mixed(200, -1n, true)), show(m.mixed(200, -1n, false)));
console.log(show(m.nothing(3)));
for (const [name, f] of [['u8_next', () => m.u8_next(255)], ['u64_big', () => m.u64_big(18446744074n)], ['i32_neg', () => m.i32_neg(-2147483648)]]) {
  try { f(); console.log(name, 'no trap'); } catch (e) { console.log(name, e.constructor.name); }
}
