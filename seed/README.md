# seed/

`eiderc.c` is the self-hosted compiler (`compiler/`, entry `compiler/main.ei`) translated to
C by itself: the C that stage 3 emits in `scripts/selfhost.sh`, which is byte-identical to the
C stage 2 emits (the fixed point). With it, building Eider needs only a C11 compiler:

```sh
cc -std=c11 -O2 -pthread -I core -o eiderc seed/eiderc.c core/eider_rt.c core/eider_core.c
```

The binary finds the toolchain (`core/`, `core/prelude.ei`) from `$EIDER_ROOT` or the
directories above it (docs/compiler.md, "C4: lowering", Driver).

## Regenerating

Whenever `compiler/` changes, run

```sh
sh scripts/selfhost.sh --seed
```

It builds stage1 with the previous compiler, stage2 with stage1, stage3 with stage2, checks
that stage2 and stage3 emit the same C, that stage3 leaks nothing while compiling
`compiler/`, and that stage3 passes `scripts/test-compiler.sh`, then writes stage3's C here.
Commit the new `eiderc.c` together with the compiler change.

`sh scripts/selfhost.sh --from-seed` must always pass: it builds eiderc from this file with
only a C compiler (no stage 0) and checks that the result emits exactly this file again for
`compiler/main.ei`. A stale seed fails it.

## The rule

`compiler/` may only use language features that the **current seed** supports: the seed is
what builds the next compiler. A new feature lands in the compiler first (implemented, not
used), the seed is regenerated, and only then may `compiler/` start using it. Until the
Rust stage 0 (`eider-bootstrap`) is retired, `compiler/` must also still build with stage 0
(`scripts/selfhost.sh` starts from it).
