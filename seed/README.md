# seed/

The compiler builds from a fresh checkout with only a C compiler (decision U24, the approach
Zig takes): the seed is eiderc itself compiled to WebAssembly, plus a small translator from
WebAssembly to C.

| File | What it is |
|---|---|
| `eiderc.wasm` | the self-hosted compiler (`compiler/`, entry `compiler/main.ei`) as a WebAssembly *core module*: `eiderc build --wasm-core compiler/main.ei` (core/wasm/README.md "Core modules"). Its only imports are the C core's functions (`env.ec_*`, core/ABI.md), so files, arguments, the environment, stdio and processes come from `core/eider_core.c` exactly as for a native program |
| `eiderc.wasm.clang` | the `clang --version` line of the clang that built it |
| `wasm2c.c` | the translator: one C11 file, no dependencies. It reads only what the seed needs (the MVP integer instructions, sign-ext, memory.copy/fill, one memory and table, active segments, `ec_*` imports) and validates it; anything else is an error, never undefined behaviour. The C it writes checks every memory access, division, table call and the call depth |
| `tests/` | `run.sh` (strict warnings, the seed under ASan+UBSan, an instruction test against a native build, a core module end to end, fuzzing) and `fuzz.sh` |

## The bootstrap

```sh
cc -std=c11 -O2 -o wasm2c seed/wasm2c.c
./wasm2c seed/eiderc.wasm -o eiderc.c
cc -std=c11 -O1 -pthread -o eiderc eiderc.c core/eider_core.c     # stage0
```

stage0 is a complete eiderc: it checks programs (`eiderc check`) and emits LLVM IR. Building
programs needs clang 17 or newer (LAYERS.md, "Dependencies"); with it, stage0 builds
`compiler/` natively and that compiler builds itself. `scripts/ei` does all of this into
`target/eiderc-stage0` and `target/eiderc` (the native build when clang is there, else stage0
itself) whenever the seed or `core/` is newer, and every script and test runner uses it. The
compiler finds the toolchain (`core/`, `std/`) from `$EIDER_ROOT` or the directories above it.

## Regenerating

Whenever `compiler/` changes, run

```sh
sh scripts/selfhost.sh --seed
```

It builds stage0 from the current seed (cc only), stage1 (`compiler/` built natively by stage0),
stage2 (by stage1), checks that stage1 and stage2 emit the same LLVM IR for `compiler/` and
build the same seed, that stage2 leaks nothing while compiling `compiler/`, and that stage2
passes `scripts/test-compiler.sh`, then writes stage2's `build --wasm-core` to `eiderc.wasm`
(and its clang to `eiderc.wasm.clang`). Commit both with the compiler change.

After a MAJOR or MINOR bump (`scripts/version.sh bump`) the current seed refuses `core/`,
`std/` and `compiler/`, which now say the new `eider = "X.Y"` (E0811). Bootstrap once: build
stage0 (`--seed` does, then stops), set aside the `eider = ` line of `core/eider.toml`,
`std/eider.toml` and `compiler/eider.toml` (no line means any toolchain), let
`target/selfhost/stage0 build compiler/main.ei -o target/selfhost/bump` build the new
compiler, restore the three lines, write `target/selfhost/bump build --wasm-core
compiler/main.ei -o seed/eiderc.wasm`, then run `--seed` again. Its test leg fails on the
version in E0811's text until `BLESS=1 EIDERC=$PWD/target/selfhost/stage2 sh
scripts/test-compiler.sh` records it; review that diff (the version only) and commit with
the seed (`--from-seed` then passes). 0.2.0 was bumped this way.

`sh scripts/selfhost.sh --from-seed` must always pass: it builds stage0 from the seed with only
a C compiler and checks `compiler/main.ei` with it; with clang it also checks that the seed is
current (stage0 emits the same LLVM IR for `compiler/` as the compiler it builds) and, when
clang is the one in `eiderc.wasm.clang`, that the seed is rebuilt byte for byte. A stale seed
fails it.

## The rule

`compiler/` may only use language features that the **current seed** supports: the seed is
what builds the next compiler. A new feature lands in the compiler first (implemented, not
used), the seed is regenerated, and only then may `compiler/` start using it.

### Bootstrapping a change in what source means

A change that gives existing source a new meaning (U29: every plain string literal
interpolates, so a `{` in one stopped meaning itself) can't land the way a new feature does:
the seed reads `compiler/`, and what it compiles of `core/` and `std/`, by the old rule, and
the new compiler by the new one. Two steps: first make that source mean the same under both
rules (for U29, `scripts/migrate-strings.sh --portable`: raw strings, which an earlier seed
already has, or `\x7b`/`\x7d`), land the change, and regenerate the seed; then migrate the
rest with the new rule (packages, tests, examples, docs, the sibling repositories).

Until #127 the seed was `eiderc.c`, the compiler's own C output; the chain is in
docs/compiler.md, "Bootstrap chain" and "History".
