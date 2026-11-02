// usage: node text.mjs <dir with text.js and text.wasm>
import { readFileSync } from 'fs';
const dir = process.argv[2];
const { load } = await import(dir + '/text.js');
const m = await load(readFileSync(dir + '/text.wasm'));
console.log(m.lit_len(), m.utf8_len(), m.round_trip(), m.lit_sum());
m.shout();
