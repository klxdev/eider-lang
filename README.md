# Eider

A compiled, type-safe language that emits portable C11. The repository is layered (see
`LAYERS.md`): a small C core (`core/`, contract in `core/ABI.md`), a standard library in
Eider (`std/`), and packages in Eider (`packages/`). `bootstrap/` holds the temporary Rust
compiler that turns Eider into C until the compiler is rewritten in Eider.

```
cargo build --manifest-path bootstrap/Cargo.toml --target-dir target
scripts/ei run tests/std/std.ei        # any eider command, with the C core linked
scripts/verify.sh                      # everything
eider run examples/warehouse.ei        # build + run (target/debug/eider)
eider test examples/warehouse.ei       # run `test` blocks
eider check file.ei --json             # machine-readable diagnostics for agents
eider emit-c file.ei                   # inspect the generated C
eider test --compile-fail tests/checks # compile-fail / compile-pass suite
tests/run.sh                           # run-and-compare suite (CC=clang works too)
```

## What exists

| Area | Status |
|---|---|
| Types | ints, `bool`, `str`, `()`, records, payload enums, tuples, fixed arrays, generics (monomorphized), traits with static dispatch |
| Heap | `String`, `List[T]`, `Map[K,V]`, `Box[T]` with value semantics; drops on every exit path; no GC, no borrow annotations |
| Control | `match` with nested patterns + exhaustiveness/reachability, `if let`, `Option`/`Result` and `?`, `for x in list`, `panic` |
| Closures | `\|a, b\| -> T body`, `fn(A) -> R` types, capture by snapshot, named fns as values, `map/filter/fold/any/all/sum` |
| Modules | `import "x.ei" [as y]` with namespaced access (`y.Name`), `pub` visibility (E0801), name clashes caught (E0808) |
| Interop | `extern "c" fn` (needs `unsafe` + `uses ffi`), `export fn` -> C/C++-safe header, `build --lib` (.a/.so/.h), `build --wasm` (.wasm + .d.ts + JS loader) |
| Concurrency | `spawn`, `Task[T].join`, `Mutex[T]` (`get/set/update`), `Chan[T]` (`send/recv/close`); `uses threads`; no shared mutable state except through these |
| Comptime | `const X: T = comptime expr` (ints/bool; evaluator runs with no capabilities) |
| Safety | no null, no implicit conversions, checked `as`, overflow traps (`+% -% *%` wrap), bounds checks, immutable by default, `inout` exclusivity, capabilities |
| Diagnostics | 42 stable codes, exact spans, `--json`, machine-applicable `fix` (round-trip verified) |
| Back end | standard C11; strict left-to-right evaluation; clean under `-pedantic`, ASan, UBSan, TSan; gcc and clang agree |
| Build | binary cache keyed on the generated C (`EIDER_CACHE`) |

## Verification

`scripts/verify.sh`: compile-fail/pass suite (74 files, 42/42 codes), run tests on gcc, clang, ASan+UBSan and TSan, C and C++ consumers of an exported library, and a Node check of the WebAssembly build.

## Known limits

- Only the first error is reported; `test` stops at a test's first failed assert.
- Closures can't mutate captured variables; recursion needs `Box`; no references, so no zero-copy views (values are cloned on read from a place).
- Map keys are ints, bool, `str`, `String`. Trait dispatch is static only (no `dyn`).
- WASM exports are scalars only (no strings/records across the boundary yet); no threads on WASM. FFI to `extern "c"` uses an ELF `asm` label (Mach-O would need a prefix).
- `comptime` re-runs the whole front end per constant and handles only ints/bool.
- The front end is whole-program every time; the cache only skips the C compiler.
- Exercised on x86-64 Linux only.

## Layout

Bootstrap compiler (`bootstrap/src/`): `lexer.rs` -> `parser.rs` (AST in `ast.rs`) -> `check.rs` (type check and C emit in one pass) -> `prelude.rs` (C runtime) ; `diag.rs` holds codes, fixes, JSON.
