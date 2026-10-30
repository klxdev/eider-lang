# The self-hosted compiler (`eiderc`)

Status: approved direction; C1 to C4 done. This file owns the plan; update it as stages land.

Progress: **C1 done** (lexer, interner, diagnostics rendering; `scripts/test-compiler.sh`).
**C2 done** (parser to the AST arena, `eiderc parse` dump, parse-error corpus and AST goldens).
**C3 done** for v0 plus non-generic payload enums (`resolve.ei`, `types.ei`, `fold.ei`,
`pats.ei`, `check.ei`, `ir.ei`; see "C3: checking" below).
**C4 done** for the same language (`lower.ei`, `driver.ei`; `eiderc emit-c/build/run/test`;
see "C4: lowering" below). Next: C5.

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
| Language runtime (traps, checked arithmetic, allocation, string/list helpers, thread glue) | C text inside the stage-0 compiler (`src/prelude.rs`), pasted into every program | `core/eider_rt.h` + `core/eider_rt.c` (written; contract and inventory in `core/RUNTIME.md`, tested by `tests/core/run.sh`), included by code from the self-hosted compiler |
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

## C3: checking

`eiderc check` runs lex, parse, `resolve.load` (module graph) and `check.check`, and prints
`ok` or the first diagnostic exactly as the bootstrap does (`--json` byte for byte);
`eiderc ir` dumps the typed IR.

- **Same passes, same order.** `check.ei` is a port of the bootstrap's checker without its C
  emission: type templates, non-generic types, function names, constants, every signature,
  test bodies, then function bodies in *reverse* order (the bootstrap pops a stack). The
  first error is therefore the bootstrap's first error, including which file it names.
- **Names.** The bootstrap renames an imported module's items `stem__Name` and its checker
  sees one flat table (src/ns.rs). `resolve.ei` keys every name as (module prefix, symbol)
  in a u64 and reproduces ns.rs's rewriting rules (own items, function locals, patterns,
  tests), so a lookup hits exactly what the mangled string would; messages spell keys the
  bootstrap's way and `diag.demangle` turns `a__B` into `a.B` like its report. Modules are
  identified by real path (`fs.canonical`, i.e. the core's `ec_realpath`), as
  std::fs::canonicalize does, so the deps/ link farm's paths to one file are one module.
- **Folding** (`fold.ei`) computes in a sign + 128-bit magnitude, enough for every value the
  bootstrap computes in i128 from in-range operands (its E0501 messages print them).
- **Out of scope** (generics, traits, impls, tuples, closures, String/List/Map, `?`, threads,
  FFI/export, comptime) ends checking with an `unsupported` diagnostic at the point where the
  bootstrap would start handling the feature; everything reported before it is exact, and
  the test script counts such files as out of scope.
- **The IR** (node table at the top of `ir.ei`) is what C4 lowers: per function a table of
  locals and a tree of blocks; every intermediate value is a single-assignment temporary in
  source evaluation order, variable reads are explicit `read`s of places (local, field,
  bounds-checked element, enum payload), `&&`/`||` and `match` are lowered to `if`, `for`
  loops to `loop` with a `step` block (what `continue` runs). Constants are folded values.
- **Tests.** `scripts/test-compiler.sh` compares `check --json` with the bootstrap on
  tests/checks (51/74 in scope, all agree), tests/run, and eiderc's own 229 cases in
  `compiler/tests/check` (fail cases carry `// expect:` headers that also pass the bootstrap's
  compile-fail runner; helper modules in `lib/`); IR goldens live in `compiler/tests/ir`.
  `scripts/fuzz-check.sh` (packages/fuzz) mutates v0 programs and compares both compilers
  (thousands of mutants agree; run it after checker changes).
- **Bootstrap quirks kept for parity** (fix them after the bootstrap is retired, with tests):
  `Enum.Variant` fails (E0114) for an enum of an imported module, or inside one, because
  variant names are prefixed but the field name isn't; errors in an imported module's test
  blocks, and E0801 for a private field type checked while constructing from another module,
  name the wrong file; that E0801 itself (a public record with a private field type can't be
  built outside its module) is checked against the constructing module; in a module's test
  block, a local named like one of the module's items is shadowed by the item; `x /= 0` is
  not a compile error although `x / 0` is.

## C4: lowering

`lower.ei` turns the IR into one C11 file; `driver.ei` compiles and runs it.

- **One C statement per IR statement.** The IR already fixes evaluation order, so lowering
  never hoists or reorders. Bounds checks are separate statements before the statement that
  uses a place (`(void)ei_idx(i, n, line);`, outermost index first), so nested indices check
  left to right. Every trapping operation calls the runtime (`ei_add_i32(a, b, line)`,
  `ei_s2u(...)`, `ei_trap(msg, line)`); the generated C defines no runtime functions of its
  own, only per-type glue: `t<id>_eq` (structural `==`) for every record, enum and array type,
  and `t<id>_name` (variant names for `print`) for every enum, all `static inline`.
- **Names** cannot collide with each other, C keywords, reserved identifiers or the runtime
  (`ei_*`, `ec_*`): `t<id>_<Name>` for type `<id>` of the type arena (arrays: `t<id>`),
  `f<i>_<stem__name>` for function `i` (tests: `f<i>_test`), `l<i>[_<name>]` for local `i`
  of the current function (parameters first), `s<n>` for a loop's `continue` label. Members
  are `f<n>` (fields) and `v<n>` (variant structs).
- **Layout.** Records are structs; arrays are `struct { T a[N]; }` so they copy by value;
  every enum is `struct { uint32_t tag; union { struct { ... } v<n>; ... } u; }` (no union
  when no variant has fields); `str` is `const char *`; `bool` is C `bool`; integers are the
  `<stdint.h>` types (`usize` = `uint64_t`); `inout` parameters are pointers. Types are
  defined in dependency order. Every local is declared at the top of its function with a zero
  initializer, so there is no uninitialized read and nothing for `-Wmaybe-uninitialized`.
  Loops are `for (;;)`; `continue` is `goto s<n>` when the loop has a step block (a `for`
  loop's increment), else C `continue`. Non-unit functions end in `ei_unreachable()`.
- **Warnings.** The C compiles with `-std=c11 -pedantic -Wall -Wextra -Werror` except the
  unused-function/variable/parameter warnings. Comparisons whose result the type's range
  fixes (`x >= 0` on an unsigned type, `x <= MAX`) are written as constants (gcc's
  `-Wtype-limits`); `?` in string literals is escaped (`\?`), so no trigraph forms.
- **`main`.** `ei_set_file("<path as given>")`, then the Eider `main`. With `--test` (and for
  `eiderc test`) the test driver instead: `ei_set_trap_jmp`, then for each test block in
  program order `test <name> ... ok` or `FAILED` plus the trap text, then
  `\n<n> tests, <k> failed`, exit 1 if any failed (stage 0's format).
- **Driver.** `emit-c <f> [--test]` prints the C; `build <f> [-o out]` writes an -O2
  executable (default: the source's stem in the working directory); `run <f> [--release]`
  (-O0, or -O2) and `test <f>` (-O0) build in a fresh directory under `$TMPDIR` (else
  `/tmp`), run the program with inherited stdio, remove the directory and exit with the
  program's code. The C is compiled with `$CC` (default `cc`), `-pthread`, extra flags from
  `$EIDER_CFLAGS` (split at spaces), and linked with `core/eider_rt.c` and `core/eider_core.c`
  (so programs that use std link once `extern` is supported). If it does not compile, the
  C is kept and eiderc exits 3. **Toolchain root** (the directory holding `core/`):
  `$EIDER_ROOT`, else the nearest directory above the eiderc binary (argv[0], symlinks
  resolved) that contains `core/eider_rt.h`, else the same search from the working
  directory. That needs no build-time configuration: `target/eiderc` in a checkout finds the
  checkout, and an installed eiderc needs `EIDER_ROOT` (or a `core/` above it).
- **Tests** (`scripts/test-compiler.sh`, "run" and "sanitize"): every in-scope program in
  tests/run and compiler/tests/run (19 of 27; the rest need C5 features) must match the
  bootstrap's stdout, stderr and exit code under `run`, and under `test` when it has test
  blocks, with `-Werror`; then again at `-O2 -Werror` under UBSan in trap mode. eiderc's
  own run tests cover every operator per int type with every trap and the wrapping edges
  (`arith.ei`, `traps.ei` with 109 trapping test blocks, `limits.ei`), evaluation order,
  payload-enum matches, `inout`, constants, modules, control flow, test blocks, and traps
  in `run` (stderr, exit 101).
- **Differences from stage 0** (deliberate): the bootstrap bugs in LEARNINGS.md are fixed and
  have regression tests with hand-written expected output (`compiler/tests/run/bug_*.ei` +
  `.out`): `len(e)` evaluates `e`; `let p = match r { V(p) => p }` assigns `p`; `else if`
  conditions with temporaries (the owned-value case needs String/List, C5); `??(` in strings
  stays `??(`. A program killed by a signal makes `eiderc run` exit 128 + signal (stage 0
  exits 1); `build` without `-o` writes to the working directory (stage 0 writes to its temp
  directory); there is no binary cache (`EIDER_CACHE` is ignored); driver messages start
  with `eiderc:`. Kept for parity: an imported module's unit enum prints its mangled name
  (`geo__South`), and trap messages always name the entry file, even for a trap in an
  imported module.

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
| C2 ✅ | `parse` to the AST arena; `eiderc parse` dumps the AST | every `.ei` in the repo parses; parse errors (E0001) match the bootstrap's positions, including the one-file-per-error-path corpus in `compiler/tests/parse`; golden dumps in `compiler/tests/parse_ok` |
| C3 ✅ | `resolve` + `check` for the v0 language (ints, bool, str, records, enums, arrays, control flow, `inout`, capabilities, const folding), producing the typed IR (`eiderc ir`) | v0 compile-fail and compile-pass tests match |
| C4 ✅ | `lower` + C for v0 (plus non-generic payload enums) against `core/eider_rt.*`; driver (`emit-c`, `build`, `run`, `test`) | v0 run tests match (stdout, stderr, exit code, for `run` and `test`); C is `-pedantic -Wall -Wextra -Werror` clean at -O0 and -O2 and clean under UBSan (ASan/TSan when their runtimes exist) |
| C5 | S1–S3: payload enums, generics, traits, Option/Result/`?`, tuples, patterns, String/List/Map/Box, closures | all the features `compiler/` itself uses; their tests match |
| C6 | Self-host: stage1 builds stage2 builds stage3; fixed point; commit the seed | `scripts/selfhost.sh` green |
| C7 | Parity: modules/namespaces, FFI/export/`--lib`, threads, WASM, comptime, cache | the full `scripts/verify.sh` passes with `eiderc` in place of the bootstrap; retire eider-bootstrap |
| C8+ | Language work above, then std and package-manager rework | per feature |

## Testing

- Golden dumps per pass (`lex`, `parse`, `ir`), regenerated with a bless flag and
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
  main.ei             CLI (lex / parse / check / ir / emit-c / build / run / test)
  source.ei  lex.ei  intern.ei  ast.ei  parse.ei  resolve.ei  types.ei  fold.ei  pats.ei
  check.ei  ir.ei  lower.ei  emit.ei  diag.ei  driver.ei
  tests/              pass-level golden tests (lex, lex_ok, check, ir)
```

`compiler/` depends on `core` and `std` only.
