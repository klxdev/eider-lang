# The LLVM backend

`eiderc build`, `run`, `test` and `build --lib` emit
[LLVM IR](https://llvm.org/docs/LangRef.html) and build it with clang. There is no flag: the
LLVM backend is the only way programs are built (decision U23). Building eiderc itself, and
bootstrapping from the seed, still need only a C compiler. WebAssembly modules (`--wasm`) and
`--profile` builds still go through the C lowering for now, and `emit-c` prints it (it is the
form the seed is in).

## Requirements

- clang 17 or newer (LLVM 17 introduced the opaque pointers the IR uses). eiderc runs
  `clang --version` first and stops with exit code 3 and a message when clang is missing or
  older. `EIDER_LLVM_CC` names another clang.
- Only clang's driver is used (`clang -c prog.ll`). `llc`, `opt` and the LLVM libraries are
  not needed.
- x86-64 Linux. The calling convention is System V x86-64. arm64 is a later step.

## Commands

| Command | What it does |
|---|---|
| `build <file> [-o out] [-g]` | An `-O2` executable. |
| `run <file> [--release] [-g]` | `-O0`, or `-O2` with `--release`. |
| `test <file> [-g]` | The test blocks. |
| `build --lib <file> [-o name]` | The static and shared library, with a C header for the `export fn`s. |
| `emit-llvm <file> [--test] [--lib]` | Prints the LLVM IR. |
| `emit-llvm --coverage <file>` | Prints `native N/M functions`, then one `fallback <function>: <reason>` line for each function that would be compiled as C (none today). |

`-g` adds DWARF debug information that points at the `.ei` files, so a debugger can stop on
an Eider line and show parameters and named locals with their types (records and tuples by
member, enums by tag and variant, `String` and `List` by pointer, `len` and `cap`). With
optimization (`build`, `run --release`) the variables of inlined functions are optimized
away; `EIDER_CFLAGS=-O0` keeps them.

`EIDER_CFLAGS` applies to the C half (the runtime glue and `main`). Its `-O<n>`, `-g` and
`-fsanitize=...` flags are also passed to clang for the IR, so
`EIDER_CFLAGS=-fsanitize=address` instruments both.

The module is built as units: one per Eider module, and the generic instances in 16 shards.
Each unit is compiled on its own (in parallel, `-j N`) and its object cached by its text, so
after an edit only the edited module's unit is compiled again, and an unchanged program is
neither compiled nor linked (the cache: docs/site/tooling/compiler.md, "The cache").
`EIDER_LLVM_UNITS=0` builds the module as one unit; `-g` and `build --lib` always do.

A release build (`build`, `run --release`) uses ThinLTO when clang can link with lld (eiderc
checks that by linking a one-line probe): every unit and the C half are compiled to bitcode,
lld optimizes them in parallel with cross-module inlining, and keeps its own cache of
optimized modules in the cache's `lto/` directory, so after an edit only the edited module and
those that inline from it are optimized again. `EIDER_LLVM_LTO=0` turns that off, and without
lld the units are linked as plain objects, as at -O0.

```sh
scripts/ei build -g examples/fib.ei -o fib
```

## How it works

The backend works one function at a time. Each function it can lower becomes LLVM IR. Any
other function falls back to the C backend, and `emit-llvm --coverage` reports the reason.
Today every function in the run tests, and in the compiler itself, is native, and
compiler/tests/llvm/run.sh keeps it so.

The C half holds any fallback functions, the per-type glue (drop, clone, `==`, ordering,
`Show`, the List and Map operations, closure environments, the thread handles) and `main`.
The C half calls into the IR half through the C ABI, and calls between Eider functions use
a faster internal convention (large records by reference). Every run test's output, trap
messages (with file and line) and exit code are recorded in tests/oracle, and
`scripts/test-compiler.sh` checks them at -O0, at -O2 under UBSan, with ASan and TSan, and
with the runtime's allocation count.

The IR has no undefined behaviour. Overflow checks use `llvm.*.with.overflow`, bounds and
shift checks are explicit branches to the runtime's `ei_trap`. The optimizer hints in the IR
(`nsw`/`nuw` after an overflow check, `inbounds` addresses, `noalias` on `inout`
parameters) only restate what a check or a language rule has already proved, so every trap
happens where the language says it does.

## Testing it

```sh
sh scripts/test-compiler.sh         # every run test against tests/oracle (and much more)
sh compiler/tests/llvm/run.sh       # the C ABI, coverage (nothing falls back), DWARF
sh scripts/llvm-bench.sh            # compile and run times
```

`scripts/verify.sh` runs compiler/tests/llvm/run.sh as its "llvm" leg when clang 17+ is
installed, and otherwise skips that leg with the reason.
