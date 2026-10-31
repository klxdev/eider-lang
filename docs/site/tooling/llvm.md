# The LLVM backend (experimental)

`eiderc` normally compiles Eider to C11 and hands the C to a C compiler. With
`--backend=llvm` it emits [LLVM IR](https://llvm.org/docs/LangRef.html) instead and builds it
with clang. The C backend stays the default. Building eiderc itself, and bootstrapping from
the seed, still need only a C compiler. The LLVM backend is an experiment on the
`experiment/llvm-backend` branch: whether it replaces part of the C path will be decided
from its measurements (docs/compiler.md, "Backends").

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
| `build --backend=llvm <file> [-o out] [-g]` | Like `build`: an `-O2` executable. |
| `run --backend=llvm <file> [--release] [-g]` | Like `run`: `-O0`, or `-O2` with `--release`. |
| `test --backend=llvm <file> [-g]` | Like `test`: the test blocks, with the same output. |
| `build --lib --backend=llvm <file> [-o name]` | Like `build --lib`. The library has the same C header and ABI. |
| `emit-llvm <file> [--test] [--lib]` | Prints the LLVM IR half. |
| `emit-llvm --coverage <file>` | Prints `native N/M functions`, then one `fallback <function>: <reason>` line for each function that is still compiled as C. |
| `emit-c --backend=llvm <file>` | Prints the C half. |

`-g` adds DWARF line information that points at the `.ei` files, so a debugger can stop on
an Eider line. Variables and types are not described yet.

`EIDER_CFLAGS` still applies to the C half. Its `-O<n>`, `-g` and `-fsanitize=...` flags
are also passed to clang for the IR half, so `EIDER_CFLAGS=-fsanitize=address` instruments
both halves. The binary cache is not used with `--backend=llvm` (the C core's objects still
are).

```sh
EIDER_CACHE=off target/eiderc-next build --backend=llvm -g examples/fib.ei -o fib
```

(`scripts/ei` runs the seed compiler, which doesn't have the flag: `target/eiderc-next` is the
compiler built from this branch by `scripts/test-compiler.sh` or `scripts/llvm-diff.sh`.)

## How it works

The backend works one function at a time. Each function it can lower becomes LLVM IR. Any
other function falls back to the C backend, and `emit-llvm --coverage` reports the reason.
Today every function in the run tests, and in the compiler itself, is native.

The C half holds the fallback functions, the per-type glue (drop, clone, `==`, ordering,
`Show`, the List and Map operations, closure environments, the thread handles) and `main`.
The two halves call each other through the C ABI. A program behaves the same under both
backends: the same output, the same trap messages with the same file and line, the same exit
codes. That is tested on every run test (`scripts/llvm-diff.sh`).

The IR has no undefined behaviour. Overflow checks use `llvm.*.with.overflow`, bounds and
shift checks are explicit branches to the runtime's `ei_trap`, and the IR never uses `nsw`,
`nuw`, `exact` or `inbounds`.

## Testing it

```sh
sh scripts/llvm-diff.sh             # every run test, both backends, -O0/-O2/leaks/ASan+UBSan
sh compiler/tests/llvm/run.sh       # records of mixed field types across the C ABI
sh scripts/llvm-bench.sh            # compile and run time against the C backend
```

`scripts/verify.sh` runs the first two as its "llvm (--backend=llvm)" leg when clang 17+ is
installed, and otherwise skips that leg with the reason.
