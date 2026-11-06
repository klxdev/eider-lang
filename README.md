# Eider

A compiled, type-safe language that compiles through LLVM IR. The repository is layered (see
`LAYERS.md`): a small C core (`core/`, contract in `core/ABI.md`), a standard library in
Eider (`std/`), and the ecosystem's tooling as packages in Eider (`packages/`: eider-pkg,
eider-doc, the fuzzer, crypto). Libraries and frameworks (eider-json, eider-http, eider-rpc,
eider-openapi, ...) live in repositories of their own (LAYERS.md, "Where code lives"). The
compiler, `eiderc` (`compiler/`), is written in Eider and self-hosted: it is committed as
WebAssembly (`seed/eiderc.wasm`) with a small translator to C (`seed/wasm2c.c`), so building
the compiler needs only a C11 compiler; programs are built through LLVM IR and need clang 17
or newer (tested with 17, 20, 22 and 23: `scripts/clang-matrix.sh`, docs/site/tooling/llvm.md).

```
cc -o wasm2c seed/wasm2c.c && ./wasm2c seed/eiderc.wasm -o eiderc.c && cc -pthread -o eiderc eiderc.c core/eider_core.c   # the bootstrap
scripts/ei run examples/warehouse.ei      # build + run (scripts/ei builds target/eiderc from the seed)
scripts/ei test examples/warehouse.ei     # run `test` blocks
scripts/ei check file.ei --json           # machine-readable diagnostics for agents
scripts/ei emit-llvm file.ei              # inspect the generated LLVM IR
scripts/ei test --compile-fail tests/checks   # compile-fail / compile-pass suite
tests/run.sh                              # run-and-compare suite (CC=clang works too)
scripts/verify.sh                         # everything
scripts/selfhost.sh                       # seed -> stage1 -> stage2 -> stage3, fixed point
```

## What exists

| Area | Status |
|---|---|
| Types | `i32`, `i64`, `u8`, `u32`, `u64`, `usize` (checked `as`), `bool`, `str`, `()`, records, payload enums, tuples, fixed arrays, type aliases, generics (monomorphized, with trait bounds), traits with static dispatch |
| Operation traits | `Copy`, `Eq`, `Ord`, `Hash`, `Show`, `Iter`, `Drop`, `Default` in the prelude, derived automatically, overridable by the type's own package (`.copy()`, `==`, `<`, Map keys, `print`, `for`, cleanup, `T.default()` / `x.take()`) |
| Heap | `String`, `List[T]`, `Map[K,V]`, `Box[T]` with value semantics and copy-on-write buffers; drops on every exit path; no GC, no borrow annotations |
| References | `let x = place` is a read-only reference, `let mut x = place` a mutable alias, fresh values are owned, `.copy()` takes an independent value; the protection rule (E0308) rejects invalidating writes while a reference is alive; `Ref[T]` for shared mutable state on one thread (docs/design/memory-model.md) |
| Control | `match` with nested patterns + exhaustiveness/reachability, `if let`, `while let`, labeled loops (`outer: for`, `break outer`), `for x in` a range, List, array, Map (`for (k, v) in m`) or own `Iter` type (over a snapshot taken before the loop), `Option`/`Result` and `?` (with `From` conversion), `panic` |
| Closures | `\|a, b\| -> T body`, `fn(A) -> R` types, capture by snapshot, `inout` parameters (`\|inout m\|`), named fns as values, `map/filter/fold/any/all/sum` |
| Modules and packages | dotted imports (`import std.fs`, `import std.{bytes, fs as f}`, `import json.stream`, own modules as `pkg.module`, the lazily loaded `import std` namespace) with qualified access (`fs.Name`), dependencies through eider.lock, `pub` visibility (E0801), module identity (package, path), alias clashes caught (E0813); eider-pkg (`packages/pkg`) |
| Interop | `extern "c" fn` in a package granted `ffi` (core), `export fn` -> C/C++-safe header, `build --lib` (.a/.so/.h), `build --wasm` (.wasm + .d.ts + JS loader) |
| Concurrency | `spawn`, `Task[T].join`, `Mutex[T]` (`get/set/update`), `Chan[T]` (`send/recv/close`); std's atomics, locks, bounded channels with `select`, task groups, thread pool, event loop (docs/runtime.md); guarded thread stacks; `uses threads`; no shared mutable state except through these |
| Comptime | `const X: T = comptime expr` (evaluated by a generated program with no capabilities) |
| Safety | no null, no implicit conversions, checked `as`, overflow traps (`+% -% *%` wrap), bounds checks, stack overflow reported as a trap, immutable by default, `inout` exclusivity, capabilities per function and per package (`uses io, fs, net, clock, threads`; grants in eider.toml) |
| Diagnostics | 58 stable codes (`diag.all_codes()`), every independent error reported, exact spans, `--json`, machine-applicable `fix` (round-trip verified) |
| Back end | standard C11; strict left-to-right evaluation; clean under `-pedantic`, ASan, UBSan, TSan; gcc and clang agree; `--profile` builds with the sampling profiler (eider-profiler) |
| Tools | object and link cache with parallel units and a size limit (`EIDER_CACHE`, `-j`, `eiderc cache`), `eiderc ide` (eider-analyzer), `eiderc doc` (eider-doc, the site in docs/site), `audit-refs` |

## Verification

`scripts/verify.sh`: the compile-fail/pass suite (tests/checks: 93 files, 56/56 codes), run tests on gcc, clang, ASan+UBSan and TSan, the C core, std, packages and the package manager, the pinned libraries (fetched into `.vendor/` on first use and hash-checked against `vendor.lock`: `scripts/vendor.sh`), the docs site and its doc tests, the crypto backends that are present, the compiler against its recorded oracle (`scripts/test-compiler.sh`), the compiler and run tests with the other clang versions (17, 20, 23; the `llvms` leg), the seed reproducing itself, C and C++ consumers of an exported library, the sibling repositories (editor tooling, libraries) when checked out next to this one, and a Node check of the WebAssembly build. It ends with `ALL GREEN` (naming the legs skipped for a missing toolchain).

## Known limits

- `test` stops at a test's first failed assert. (Compile errors: every independent one is reported, at most `--max-errors N`, default 100.)
- Closures can't mutate captured variables (use an `inout` parameter or a `Ref`); recursion needs `Box`; references are re-derived places, not C pointers (docs/design/memory-model.md, "Open items").
- Trait dispatch is static only (no `dyn`); no default method bodies.
- WASM exports are scalars only (no strings/records across the boundary yet); no threads on WASM. FFI to `extern "c"` uses an ELF `asm` label (Mach-O would need a prefix).
- `comptime` re-runs the whole front end per constant.
- The front end is whole-program every time; the cache only skips the C compiler.
- Exercised on x86-64 Linux only.

## Layout

`compiler/` (docs/compiler.md): `lex.ei` -> `parse.ei` (AST arena, `ast.ei`) -> `resolve.ei` (modules) -> `check.ei` (types, typed IR in `ir.ei`) -> `lower.ei` (C) -> `driver.ei` (cc, cache); `diag.ei` holds codes, fixes, JSON. The expected results of its tests are recorded in `tests/oracle/` (`BLESS=1 sh scripts/test-compiler.sh` updates them).
