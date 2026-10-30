// usage: node imports.mjs <dir with imports.js and imports.wasm>
import { readFileSync } from 'fs';
const dir = process.argv[2];
const { load } = await import(dir + '/imports.js');
const wasm = readFileSync(dir + '/imports.wasm');
console.log('imports:', WebAssembly.Module.imports(new WebAssembly.Module(wasm)).map((i) => `${i.module}.${i.name}`).sort().join(' '));
const m = await load(wasm, { host_scale: (v) => v * 10 });
console.log('scaled_sum', m.scaled_sum(5));
try { await load(wasm); console.log('no imports: loaded'); } catch (e) { console.log('no imports:', e.constructor.name); }
