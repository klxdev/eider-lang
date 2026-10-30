// usage: node long.mjs <dir with long.js and long.wasm>
import { readFileSync } from 'fs';
const dir = process.argv[2];
const { load } = await import(dir + '/long.js');
const m = await load(readFileSync(dir + '/long.wasm'));
const n = m.long_line(100);
console.log('returned', n);
