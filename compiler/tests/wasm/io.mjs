// usage: node io.mjs <dir with io.js and io.wasm>
import { readFileSync } from 'fs';
const dir = process.argv[2];
const { load } = await import(dir + '/io.js');
const m = await load(readFileSync(dir + '/io.wasm'));
console.log('hello ->', m.hello(5));
const traps = [['idx', () => m.idx(3)], ['boom', () => m.boom(1)], ['add', () => m.add(2147483647, 1)]];
for (const [name, f] of traps) {
  try { f(); console.log(name, 'no trap'); } catch (e) { console.log(name, e.constructor.name, e.message); }
}
// a trap leaves the instance usable for further calls
console.log('after traps', m.add(1, 2), m.idx(2), m.boom(0));
