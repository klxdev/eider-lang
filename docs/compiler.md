# The self-hosted compiler (`eiderc`)

Status: approved direction; C1 done. This file owns the plan; update it as stages land.

Progress: **C1 done** (lexer, interner, diagnostics rendering; `scripts/test-compiler.sh`). Next: C2.

## Goal

Replace the Rust stage-0 bootstrap (the separate `eider-bootstrap` repository; this
repository already contains no Rust) with a compiler written in Eider, then retire it. Afterwards the only non-Eider code in the toolchain is the C core (`core/`), and
building Eider from nothing needs only a C11 compiler.

Non-goals for the first version: a new back end (we keep emitting portable C11), an
interpreter, incremental compilation, an LSP. The design leaves room for all of them.

## Why this order

The bootstrap is frozen. Every missing language feature (byte access on `String`, bitwise
operators, capability encapsulation, package-qualified modules, `Ok(())`, exit codes)
currently forces workarounds into `std/` and packages. Those workarounds would harden into
APIs. So the compiler comes first, the language gains those features in the compiler, and
then std and packages are reworked on a correct base. The compiler is the one program that is
allowed to live with the bootstrap's limits, for one stage only.

## Bootstrap chain

```
stage0  eider-bootstrap (Rust, external) compiles compiler/ -> stage1 (a native binary)
stage1  compiler/ built by stage0    compiles compiler/ -> stage2
stage2  compiler/ built by stage1    compiles compiler/ -> stage3
fixed point: the C that stage2 and stage3 emit for compiler/ is byte-identical
seed:   that C is committed as seed/eiderc.c; eider-bootstrap is retired
later:  cc seed/eiderc.c core/*.c  ->  a working compiler, no Rust anywhere
```

The seed is regenerated (and the fixed point re-checked) whenever the compiler changes in a
way the seed can't compile. The rule from then on: the compiler may only use language
features that the previous seed supports.

## Unmanaged code inventory

| Code | Today | Target |
|---|---|---|
| OS interop | `core/eider_core.c` (ABI in `core/ABI.md`) | unchanged; one backend file per OS |
| Language runtime (traps, checked arithmetic, allocation, string/list helpers, thread glue) | C text inside the stage-0 compiler (`src/prelude.rs`), pasted into every program | `core/eider_rt.h` + `core/eider_rt.c`, specified like the OS ABI, included by generated code |
| Per-type glue (drop/clone/equality/hash for each concrete type) | generated C | generated C (compiler output; trusted because the compiler is) |
| WASM libc shim | C text in the stage-0 compiler (`src/wasm_shim.rs`) | `core/wasm/` as a separate backend of the same ABIs |

Moving the runtime into `core/` makes it reviewable, testable under sanitizers on its own,
and portable per target, instead of being a string inside a compiler.

## Language contract

The language is what the bootstrap accepts and the test suites specify:

- `tests/checks/fail` and `tests/checks/pass`: every diagnostic code with its exact position.
- `tests/run/*.ei` + `.out`: runtime behaviour, including evaluation order and traps.
- `tests/std`, `packages/*/tests`: library behaviour on top of the core.
- `LEARNINGS.md`: semantics that the tests don't pin down well (value semantics, drops on
  every exit path, left-to-right evaluation, snapshot captures).

`eiderc` must pass all of them before it replaces the bootstrap. Generated C is not part of
the contract: `eiderc` can name and lay out C differently. Diagnostic codes, messages'
meaning, positions (line, column in Unicode scalar values) and `--json` output are part of
it.

## Architecture

Separate passes over flat, index-based data. Eider has value semantics with no references:
reading owned data out of a place copies it. So trees of owned nodes would be copied on every
visit. Instead every pass works on arenas of small records that hold integer ids, as in
data-oriented compilers.

```
files ──lex──> tokens ──parse──> AST arena ──resolve──> scopes, module graph
      ──check──> types arena + typed IR ──lower──> C text ──cc──> binary
```

| Pass | Input → output | Notes |
|---|---|---|
| `source` | paths → `List[u8]` per file, file ids | spans are (file, byte offset); line/col computed only for diagnostics |
| `lex` | bytes → tokens `{kind, start, end}` | no token owns text; identifiers are interned |
| `intern` | identifier bytes → `u32` symbol | open-addressing hash table written in Eider |
| `parse` | tokens → AST arena | nodes are `{kind, a, b, c, span}`; variable-length children live in a shared `extra: List[u32]` |
| `resolve` | AST → module graph + scopes | module identity is (package, path); bare `import "json"` goes through `eider.lock`; visibility (E0801), clashes |
| `check` | AST → typed IR | types interned in a type arena; monomorphization on demand; capabilities; `inout` exclusivity; exhaustiveness; const folding |
| `lower` | typed IR → C | ownership: clones, moves and drops are explicit IR ops before C is printed, so order-of-evaluation and drop placement are decided once, not while printing text |
| `driver` | CLI, `cc`, cache | uses `std/fs` and `std/proc`; same commands as the bootstrap |

The bootstrap fuses checking and C emission; its `LEARNINGS.md` shows the cost (`fix_order`
calls needed everywhere, hoisting bugs). Keeping a typed IR between `check` and `lower`
removes that class of bug and is where later work (optimisation, another back end) attaches.

Diagnostics: same codes (`ALL_CODES`), human and `--json` rendering, machine-applicable
fixes. The compiler should report multiple independent errors per run once the passes
support recovery (the bootstrap stops at the first).

## Writing the compiler in today's Eider

Until the fixed point, `compiler/` must compile with stage0, so it uses the bootstrap's
language as it is:

- Text is `List[u8]`; symbols are interned `u32`. `String` only for messages.
- No owned data in hot loops' reads: index into arenas, keep records small and flat.
- `Map` keys are integers (symbol ids, type ids). No `Map[List[u8], _]`.
- No threads, no closures in hot paths (closures copy their captures).
- `uses ffi` everywhere is accepted in the compiler for now (it sits on std).

## Language work that lands in `eiderc` (after parity)

Each with a design note, compile-fail tests and new codes:

1. `String` byte access and slicing, `str` byte access; std switches to `String`.
2. Bitwise operators `& | ^ << >> ~` (checked shifts).
3. Unit values `()` / `Ok(())`; `main` returning an exit code; `impl` on built-in types.
4. Package-qualified modules: identity (package, path) instead of file stem; bare imports
   resolved from `eider.lock`; the `deps/` link farm goes away.
5. Capability encapsulation. Proposal: `ffi` becomes a property of a *package*, not of call
   chains. A package that declares `extern` functions must be granted `ffi` by its dependers
   in `eider.toml`. Its functions don't propagate `uses ffi` to callers, but they still
   declare and propagate the real capabilities (`fs`, `io`, ...). `core` is the one package
   granted `ffi` by the toolchain. Result: std callers write `uses fs`, never `uses ffi`, and
   the package manager's text scan is replaced by the compiler reporting each package's
   capability use.
6. Multiple diagnostics per run.

## Milestones

| Id | Scope | Done when |
|---|---|---|
| C1 ✅ | `lex`, `intern`, `diag`; `eiderc lex` dumps tokens | every `.ei` in the repo plus `compiler/tests/lex` agrees with the bootstrap on lexer errors (JSON); golden dump in `compiler/tests/lex_ok` |
| C2 | `parse` to the AST arena; `eiderc parse` dumps the AST | every `.ei` in the repo parses; parse errors (E0001) match the bootstrap's positions |
| C3 | `resolve` + `check` for the v0 language (ints, bool, str, records, enums, arrays, control flow, `inout`, capabilities, const folding) | v0 compile-fail and compile-pass tests match |
| C4 | `lower` + C for v0; runtime moved to `core/eider_rt.*` | v0 run tests match, clean under ASan/UBSan |
| C5 | S1–S3: payload enums, generics, traits, Option/Result/`?`, tuples, patterns, String/List/Map/Box, closures | all the features `compiler/` itself uses; their tests match |
| C6 | Self-host: stage1 builds stage2 builds stage3; fixed point; commit the seed | `scripts/selfhost.sh` green |
| C7 | Parity: modules/namespaces, FFI/export/`--lib`, threads, WASM, comptime, cache | the full `scripts/verify.sh` passes with `eiderc` in place of the bootstrap; retire eider-bootstrap |
| C8+ | Language work above, then std and package-manager rework | per feature |

## Testing

- Golden dumps per pass (`lex`, `parse`, later `check`), regenerated with a bless flag and
  reviewed in diffs.
- Differential testing: every program in the suites is compiled by both stage0 and
  `eiderc`. Their observable behaviour (stdout, exit code, diagnostics) must match.
- Unit tests in Eider `test` blocks inside `compiler/`.
- Fixed-point check in `scripts/selfhost.sh`.
- Known bootstrap bugs (listed in `LEARNINGS.md`) each get a run test in eiderc's suite, so
  the new compiler is held to the correct behaviour rather than the bootstrap's.
- Generated C compiled with `-Wall -Wextra -pedantic` and run under ASan/UBSan/TSan in CI.
  The bootstrap's C trips `-Wmaybe-uninitialized` at `-O2`; `eiderc`'s C must not.

## Layout

```
compiler/
  eider.toml          package `eiderc`
  main.ei             CLI (lex / parse / check / emit-c / build / run / test)
  source.ei  lex.ei  intern.ei  ast.ei  parse.ei  resolve.ei  types.ei  check.ei
  ir.ei  lower.ei  emit.ei  diag.ei  driver.ei
  tests/              pass-level golden tests
```

`compiler/` depends on `core` and `std` only.
