# Eider handoff

Eider is a compiled, type-safe language that emits C11. The compiler is a Rust crate with no dependencies (~7.8k lines). Source files use `.ei`, the CLI is `eider`.

## Get running

Needs: Rust (built with 1.97), a C11 compiler (`$CC`, default `cc`; gcc and clang both tested). For the WebAssembly path also: clang with the wasm32 target, `wasm-ld`, and Node (tests only).

```
tar xzf eider.tar.gz && cd eider
cargo build --release
./target/release/eider run examples/warehouse.ei
scripts/verify.sh          # full matrix; must end with ALL GREEN
```

Commands: `check [--json]`, `emit-c`, `emit-header`, `build [--lib|--wasm] [-o name] [-l lib]`, `run [--release]`, `test`, `test --compile-fail <dir>`.
Env: `CC`, `WASM_CC`, `EIDER_CACHE` (dir or `off`), `EIDER_RELEASE`.

## What is built

| Stage | Contents |
|---|---|
| v0 | ints/bool/str, records, enums, arrays, overflow/bounds traps, immutable by default, `inout` exclusivity, capabilities (`uses io, clock, threads, ffi`), const folding, exhaustiveness, JSON diagnostics with machine-applicable fixes |
| S1 | payload enums, monomorphized generics, traits (static dispatch), `Option`/`Result`/`?`, tuples, nested patterns, `if let`, `panic` |
| S2 | `String`, `List`, `Map`, `Box` with value semantics and drops on every exit path |
| S3 | closures (snapshot capture), `fn(A)->R` types, List combinators |
| S4 | modules, `extern "c"`/`unsafe`, `export fn` + C/C++ header, `build --lib` |
| S5 | `spawn`, `Task`, `Mutex`, `Chan` (pthreads; checked under TSan) |
| S6 | `build --wasm` (.wasm + .d.ts + JS loader), `comptime` consts, binary cache |
| S7 | namespaced imports (`import "x.ei" as y`, `y.Name`), E0808, `run`/`test` at -O0 |

42 error codes (E0001...E0808), all with a compile-fail test.

## Layout

`lexer.rs` -> `parser.rs` (AST `ast.rs`) -> `ns.rs` (module name mangling) -> `check.rs` + `expr.rs` + `stmt.rs` + `heap.rs` + `closure.rs` + `ffi.rs` (checker and C emitter are one pass) -> `prelude.rs` (C runtime and Option/Result in Eider source). `wasm_shim.rs` is the freestanding libc for WASM. `main.rs` is the CLI, module loader, comptime evaluator, build/cache.

Tests: `tests/checks/{fail,pass}` (header `// expect: CODE LINE:COL`, header counts as line 1; `// mode: wasm|test|build`), `tests/run/*.ei` + `.out`, `tests/export/`, `tests/wasm/`. `LEARNINGS.md` has the gotchas; read it before changing the checker.

## Known limits

- Only the first error is reported.
- Closures can't mutate captured variables; recursion needs `Box`; values are cloned on read from a place (no references).
- No `dyn` traits; Map keys are ints/bool/str/String.
- WASM exports are ints/bool only, no threads.
- `comptime` is ints/bool only and re-runs the front end per constant.
- Front end is whole-program; the cache only skips the C compiler.
- A local variable named like an import alias breaks `alias.x`. `extern` fns are global, not namespaced.
- Only x86-64 Linux was exercised.

## Measured compile time (3,000-line synthetic program, 150 types, 2 cores, no cache)

Front end ~50 ms. C compile: gcc -O2 4.9 s, gcc -O0 1.3 s, clang -O2 ~19 s, clang -O0 0.5 s. Generated C is ~3.7x the source line count (per-type glue); reducing that is the main speed lever.

## Next: packages (designed, not built)

- Store: `~/.eider/pkg/<name>-<hash>/` (immutable, shared); per-project manifest + `eider.lock`; `eider vendor` copies into `./vendor/` for offline builds. Only `add`/`fetch` touch the network.
- Bare `import "json"` resolves through manifest and lockfile; namespace is `json.Name`.
- Change module prefix from file stem to `package_path` so two packages' `util.ei` don't clash.
- Capability grants per dependency in the manifest (compile error if a dep exceeds them); minimal version selection; `eider api-diff` for semver; each package resolves only its own dependencies.
- Order: manifest/lockfile/store/bare-name resolution -> capability grants -> api-diff -> registry.

## Other ideas on the list

Multiple errors per run, mutable closure captures, `dyn` traits, strings/records across the WASM boundary, smaller generated C, incremental front end.
