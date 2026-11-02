// usage: node strings.mjs <dir with strings.js and strings.wasm>
import { readFileSync } from 'fs';
const dir = process.argv[2];
const { load } = await import(dir + '/strings.js');
const m = await load(readFileSync(dir + '/strings.wasm'));
console.log(m.greet('world'), m.greet('héllo \u{1F600}'), JSON.stringify(m.greet('')));
console.log(m.byte_sum(new Uint8Array([1, 2, 3, 250])), m.byte_sum(new Uint8Array([])));
console.log(m.reverse(new Uint8Array([1, 2, 3])), m.reverse(new Uint8Array([])));
console.log(m.repeat('ab', 3, true), JSON.stringify(m.repeat('ab', 0, false)));
console.log(m.text_len('héllo'), JSON.stringify(m.empty()), m.nothing(new Uint8Array([9])).length);
const before = m.memory.buffer.byteLength;
for (let i = 0; i < 2000; i++) m.greet('x'.repeat(100));
console.log('no leak', m.memory.buffer.byteLength === before);
for (const [name, f] of [['number', () => m.greet(5)], ['nul', () => m.greet('a\0b')], ['bytes', () => m.byte_sum('abc')]]) {
  try { f(); console.log(name, 'no error'); } catch (e) { console.log(name, e.constructor.name); }
}
let seen = '';
const w = await load(readFileSync(dir + '/strings.wasm'), { eider_write(p, n, memory) { seen += new TextDecoder().decode(new Uint8Array(memory.buffer, p, n)); } });
w.say(7);
console.log(typeof w.memory.buffer, JSON.stringify(seen));
console.log(m.x_named(41));
