# The LLVM backend

`eiderc build`, `run`, `test`, `build --lib`, `build --wasm` and `--profile` builds emit
[LLVM IR](https://llvm.org/docs/LangRef.html) and build it with clang. It is Eider's only
backend (decision U23): there is no flag, and no C is generated. Building eiderc itself, and
bootstrapping from the seed, still need only a C compiler (see [the bootstrap](compiler.md#the-bootstrap)).

## Requirements

- clang 17 or newer (LLVM 17 introduced the opaque pointers the IR uses). eiderc runs
  `clang --version` first and stops with exit code 3 and a message when clang is missing or
  older. `EIDER_LLVM_CC` names another clang. The versions the suites run against are
  listed under [Clang versions](#clang-versions).
- Only clang's driver is used (`clang -c prog.ll`). `llc`, `opt` and the LLVM libraries are
  not needed.
- Linux on x86-64 or AArch64: the target is the one clang builds for (`clang -dumpmachine`),
  so a clang for another target (`zig cc -target aarch64-linux-musl`, say) cross-builds.
  The C calling convention is System V x86-64 or AAPCS64; WebAssembly modules use wasm32's.

## Commands

| Command | What it does |
|---|---|
| `build <file> [-o out] [-g]` | An `-O2` executable. |
| `run <file> [--release] [-g]` | `-O0`, or `-O2` with `--release`. |
| `test <file> [-g]` | The test blocks. |
| `build --lib <file> [-o name]` | The static and shared library, with a C header for the `export fn`s (`emit-header`). |
| `emit-llvm <file> [--test] [--lib] [--wasm]` | Prints the LLVM IR. |

`-g` adds DWARF debug information that points at the `.ei` files, so a debugger can stop on
an Eider line and show parameters and named locals with their types (records and tuples by
member, enums by tag and variant, `String` and `List` by pointer, `len` and `cap`). With
optimization (`build`, `run --release`) the variables of inlined functions are optimized
away; `EIDER_CFLAGS=-O0` keeps them.

`EIDER_CFLAGS` applies to the C core and the link; its `-O<n>`, `-g` and `-fsanitize=...`
flags are also passed to clang for the IR, so `EIDER_CFLAGS=-fsanitize=address` instruments
everything (sanitizers are clang flags: use a `CC` that links them, clang or gcc).

The module is built as units: one per Eider module, the generic instances in 16 shards, and
one for the per-type operations and the entry points. Each unit is compiled on its own (in
parallel, `-j N`) and its object cached by its text, so after an edit only the edited
module's unit is compiled again, and an unchanged program is neither compiled nor linked
(the cache: docs/site/tooling/compiler.md, "The cache"). `EIDER_LLVM_UNITS=0` builds the
module as one unit; `-g` and `build --lib` always do.

A release build (`build`, `run --release`) uses ThinLTO when clang can link with lld (eiderc
checks that by linking a one-line probe): every unit is compiled to bitcode, lld optimizes
them in parallel with cross-module inlining, and keeps its own cache of optimized modules in
the cache's `lto/` directory, so after an edit only the edited module and those that inline
from it are optimized again. `EIDER_LLVM_LTO=0` turns that off, and without lld the units
are linked as plain objects, as at -O0.

```sh
scripts/ei build -g examples/fib.ei -o fib
```

## How it works

Every function becomes LLVM IR, and so do the operations each type needs (drop, clone,
`.copy()`, copy-on-write, `==`, ordering, hashing, `Show`, the List and Map operations,
closure environments, the thread handles, `Default`), `main` and the test driver. They call
the language runtime and the C core (`core/`, C) through the C ABI; calls between Eider
functions use a faster internal convention (large records by reference). Every run test's
output, trap messages (with file and line) and exit code are recorded in tests/oracle, and
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
sh compiler/tests/llvm/run.sh       # the C ABI, AArch64 signatures, DWARF
sh scripts/llvm-bench.sh            # compile and run times
```

`scripts/verify.sh` runs compiler/tests/llvm/run.sh as its "llvm" leg when clang 17+ is
installed, and otherwise skips that leg with the reason.

## Clang versions

The floor is clang 17, and a release is tested against four versions, not only the clang of
the machine it is built on: the oldest the documentation claims (17), one between (20), the
current release (22) and the next (23). `scripts/clang-matrix.sh` builds the compiler with
each, then runs the compile-fail suite, the run tests and the oracle (`scripts/test-compiler.sh`:
every run test again at `-O2`, under UBSan, with the allocation counter, and so on) with that
clang as `EIDER_LLVM_CC`:

```sh
sh scripts/clang-matrix.sh --list    # which clang each version would use
sh scripts/clang-matrix.sh --fetch   # download what is missing (linux-x86_64), then run all four
sh scripts/clang-matrix.sh 17 23     # just these (about 14 minutes a version)
```

The clangs come from `$EIDER_CLANG_<N>`, the cache `~/.cache/eider/clang/<X.Y.Z>/` (only
`bin/clang` and `lib/clang` of the upstream release tarball, whose SHA-256 is pinned in the
script), or the `clang` on `PATH` when it is that version. A version that can't be found is
skipped with the reason and never reported as tested. `scripts/verify.sh` runs the same as
its `llvms` leg with `--quick` (the build, the compile-fail suite and the run tests; the
oracle is the full run's) for the versions other than the `PATH` clang, which every other
leg covers.

What differs between the versions, and where the compiler handles it:

- **Float constants** (#168): LLVM 23 deprecates the old spellings (a hex double and `bitcast
  (i32 .. to float)`) for `f0x<bits>`, 16 hex digits for an f64 and 8 for an f32. The compiler
  writes `f0x` when the clang that builds the IR is 23 or newer and the old form otherwise
  (`driver.llvm_f0x`, the one place; `EIDER_LLVM_FLOAT=f0x` or `=hex` forces either).
  `emit-llvm` follows the clang it finds. compiler/tests/llvm/fconst.sh builds a program of
  float edge cases (zeros, subnormals, extremes, f32 values, the powers of two a
  float-to-integer conversion compares with) in each spelling and compares the output, and
  with clang 23 or newer has clang read hand-written `inf`, NaN-with-payload, `-0`, subnormal
  and f32 constants in both spellings as the same module. clang 22 and older reject `f0x`,
  and the test checks that too.
- **Linking** (#169): an upstream clang links a position-independent executable by default,
  while the C core is compiled by `$CC`, which may not be (Fedora's gcc is not). The ThinLTO
  link of a release build therefore passes `-no-pie`; without it lld refused the core's
  absolute relocations with every upstream clang from 17 to 23 (Fedora's clang links non-PIE
  and hid it).

