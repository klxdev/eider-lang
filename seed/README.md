# seed/

`eiderc.c` is the self-hosted compiler (`compiler/`, entry `compiler/main.ei`) translated to
C by itself: the C that stage 3 emits in `scripts/selfhost.sh`, which is byte-identical to the
C stage 2 emits (the fixed point). With it, building Eider needs only a C11 compiler:

```sh
cc -std=c11 -O2 -pthread -I core -o eiderc seed/eiderc.c core/eider_rt.c core/eider_core.c
```

The binary finds the toolchain (`core/`, `core/prelude.ei`) from `$EIDER_ROOT` or the
directories above it (docs/compiler.md, "C4: lowering", Driver). `scripts/ei` does exactly
this into `target/eiderc` (whenever the seed or `core/` is newer) and runs it; every script
and test runner in the repository uses it.

## Regenerating

Whenever `compiler/` changes, run

```sh
sh scripts/selfhost.sh --seed
```

It builds the current seed with `cc`, stage1 (`compiler/`) with the seed, stage2 with
stage1, stage3 with stage2, checks
that stage2 and stage3 emit the same C, that stage3 leaks nothing while compiling
`compiler/`, and that stage3 passes `scripts/test-compiler.sh`, then writes stage3's C here.
Commit the new `eiderc.c` together with the compiler change.

`sh scripts/selfhost.sh --from-seed` must always pass: it builds eiderc from this file with
only a C compiler and checks that the result emits exactly this file again for
`compiler/main.ei`. A stale seed fails it.

## The rule

`compiler/` may only use language features that the **current seed** supports: the seed is
what builds the next compiler. A new feature lands in the compiler first (implemented, not
used), the seed is regenerated, and only then may `compiler/` start using it.

History: the first seed (C6) was emitted by a chain that started from the Rust stage-0
bootstrap (the separate `eider-bootstrap` repository); until C7 retired it, `compiler/` also
had to build with stage 0. Since C7 the chain starts from this file and nothing needs Rust.
