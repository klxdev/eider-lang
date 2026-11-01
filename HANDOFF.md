# Eider handoff

Eider is a compiled, type-safe language that compiles through LLVM IR. Source files use `.ei`, the compiler is `eiderc`. The compiler (`compiler/`) is written in Eider and self-hosted; it is committed compiled to WebAssembly as `seed/eiderc.wasm`, with the translator `seed/wasm2c.c`, so building the compiler needs only a C11 compiler, nothing else (programs need clang 17+); the compiler tests' expected results are recorded in `tests/oracle/` (docs/compiler.md, "History"). Everything is Eider on top of a small C core. Read `LAYERS.md` first.

## Get running

Needs: a C11 compiler (`$CC`, default `cc`; gcc and clang both tested), a POSIX libc with threads, and clang 17+ to build programs. For the WebAssembly path also: clang with the wasm32 target, `wasm-ld`, and Node (tests only).

```
scripts/ei run examples/warehouse.ei   # scripts/ei builds target/eiderc from seed/eiderc.wasm, then runs it
scripts/ei run tests/std/std.ei
scripts/verify.sh          # full matrix; must end with ALL GREEN
scripts/selfhost.sh        # seed -> stage1 -> stage2 -> stage3; must print SELF-HOSTED
```

Commands: `check [--json]`, `emit-llvm`, `emit-header`, `build [--lib|--wasm] [-o name] [-l lib]`, `run [--release] [--] [args...]`, `test`, `test --compile-fail <dir>`, `lex`, `parse`, `ir`, `caps`, `ide`, `doc`, `audit-refs`, `migrate-var`, `cache size|clean|trim`, and `--profile` and `-j N` on build/run/test (`scripts/ei --help`).
Version: `VERSION` (`scripts/ei --version`, `scripts/version.sh`); the sibling tools share its MAJOR.MINOR and ship with it (docs/site/tooling/releases.md, `scripts/release.sh`).
Env: `CC`, `WASM_CC`, `EIDER_CFLAGS`, `EIDER_CACHE` (dir or `off`), `EIDER_CACHE_MAX` (size limit, default 5G), `EIDER_JOBS`, `EIDER_ROOT`, `EIDER_HOME` (eider-pkg's store), `EIDER_PROF`.

## What is built

| Stage | Contents |
|---|---|
| v0 | ints/bool/str, records, enums, arrays, overflow/bounds traps, immutable by default, `inout` exclusivity, capabilities (`uses io, clock, threads, ...`), const folding, exhaustiveness, JSON diagnostics with machine-applicable fixes |
| S1 | payload enums, monomorphized generics, traits (static dispatch), `Option`/`Result`/`?`, tuples, nested patterns, `if let`, `panic` |
| S2 | `String`, `List`, `Map`, `Box` with value semantics and drops on every exit path |
| S3 | closures (snapshot capture), `fn(A)->R` types, List combinators |
| S4 | modules, `extern "c"`/`unsafe`, `export fn` + C/C++ header, `build --lib` |
| S5 | `spawn`, `Task`, `Mutex`, `Chan` (pthreads; checked under TSan) |
| S6 | `build --wasm` (.wasm + .d.ts + JS loader), `comptime` consts, binary cache |
| S7 | namespaced imports (`import "x.ei" as y`, `y.Name`), E0808, `run`/`test` at -O0 |
| C6-C7 | self-hosting (`seed/eiderc.c`), the recorded oracle, FFI, threads, the driver, every independent error per run, IDE analysis (`eiderc ide`) |
| C8 waves 1-2 | copy-on-write buffers (8.1); bitwise operators, byte access, `()` values, `main` exit codes (8.2); packages and package imports through eider.lock (8.3); operation traits `Copy`, `Eq`, `Ord`, `Hash`, `Show`, `Iter`, `Drop` (8.4); capabilities per package with grants (8.5) |
| C8 waves 3-4 | references by default: `let` references, `let mut` aliases, `.copy()`, the protection rule E0308 (8.6); `Ref[T]` (8.7); `take`/`replace` (8.15); string escapes (8.17); type aliases (8.18); calling a fn stored in a field (8.19); iterating a Map (8.20); `From` for `?` (8.21); `while let` and labeled loops (8.22); `Default` (8.23); std/error (8.24); method chains across lines (8.25) |
| Tooling | eider-pkg, eider-doc and the docs site, the fuzzer, crypto over AWS-LC, `--profile` (eider-profiler), toolchain versions (`VERSION`); the libraries and frameworks in repositories of their own (LAYERS.md, "Where code lives") |

Integer types: `i32`, `i64`, `u8`, `u32`, `u64`, `usize`. 56 error codes (E0001...E0811, `diag.all_codes()` in compiler/diag.ei), all with a compile-fail test.

## Layout

`compiler/` (docs/compiler.md, "Architecture"): `lex.ei` -> `parse.ei` (AST arena) -> `resolve.ei` (module graph; `toolchain.ei` finds the toolchain) -> `check.ei` (typed IR, `ir.ei`) -> `llvm.ei` (LLVM IR; `lower.ei` keeps the C names and layouts) -> `driver.ei` (clang, units, cache), with `main.ei` the CLI; `consteval.ei` (comptime), `wasm.ei`, `suite.ei` (compile-fail runner), `ide.ei` (the analyzer's API), `doc.ei`. The runtime is `core/eider_rt.{h,c}` (core/RUNTIME.md); `core/eider_core.c` is the OS ABI (core/ABI.md); `core/wasm/` is the runtime and freestanding libc for WASM. After a compiler change: `sh scripts/selfhost.sh --seed` and commit `seed/eiderc.wasm`.

Tests: `tests/checks/{fail,pass}` (header `// expect: CODE LINE:COL`, header counts as line 1; `// mode: wasm|test|build`), `tests/run/*.ei` + `.out`, `tests/std`, `tests/export/`, `tests/wasm/`, `tests/pkg`, and the compiler's own in `compiler/tests/` (`scripts/test-compiler.sh`, against the recorded `tests/oracle/`; `BLESS=1` rewrites the expectations, review the diff). `LEARNINGS.md` has the gotchas; read it before changing the checker.

## Known limits

- Every independent error is reported (at most `--max-errors`, default 100; docs/compiler.md, "Several errors"); the first is the one a first-error compiler would report.
- Closures capture by snapshot and can't mutate captured variables (use an `inout` parameter or a `Ref`); recursion needs `Box`; references are re-derived places, not C pointers (docs/design/memory-model.md, "Open items").
- No `dyn` traits, no default method bodies. Map keys are any `Hash + Eq` type (docs/compiler.md, "C8.4: operation traits").
- WASM exports are ints/bool only, no threads.
- `comptime` re-runs the front end per constant.
- Front end is whole-program; the cache skips the C compiler per unit and the linker (docs/compiler.md, "C8.27: incremental builds"; the per-module split comes with the LLVM backend, #129).
- Only x86-64 Linux was exercised.

The backlog is the GitHub issues of klxdev/eider-lang (#89 is the roadmap); docs/compiler.md, "C8 plan: the backlog", lists the language items.

## Measured compile time (3,000-line synthetic program, 150 types, 2 cores, no cache)

Front end ~50 ms. C compile: gcc -O2 4.9 s, gcc -O0 1.3 s, clang -O2 ~19 s, clang -O0 0.5 s. Generated C is ~3.7x the source line count (per-type glue); reducing that is the main speed lever.
