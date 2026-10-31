# The self-hosted compiler (`eiderc`)

Status: C1 to C7 done: eiderc is self-hosted (seed/eiderc.c committed), its observable behaviour is recorded in `tests/oracle/` ("C7: recording the oracle"), and everything builds from the seed with only a C compiler ("History"). Next is C8 (the language work and the parity quirks listed in "C8 candidates"). This file owns the plan; update it as stages land.

Progress: **C1 done** (lexer, interner, diagnostics rendering; `scripts/test-compiler.sh`).
**C2 done** (parser to the AST arena, `eiderc parse` dump, parse-error corpus and AST goldens).
**C3 done** for v0 plus non-generic payload enums (`resolve.ei`, `types.ei`, `fold.ei`,
`pats.ei`, `check.ei`, `ir.ei`; see "C3: checking" below).
**C4 done** for the same language (`lower.ei`, `driver.ei`; `eiderc emit-c/build/run/test`;
see "C4: lowering" below). **C5 done** for S1–S3: checking (see "C5: checking S1–S3") and
lowering (see "C5: lowering"). **C6 done**: eiderc builds itself to a fixed point and the
seed is committed (see "C6: self-hosting"). From C7, **FFI is done** (`extern "c"`, `unsafe`, `export fn`,
`emit-header`, `build --lib`, `-l`; see "C7: FFI"), since `compiler/` reaches the OS only
through core/sys.ei's externs. **Comptime is done** (`const X: T = comptime expr`; see
"C7: comptime"). **Threads are done** (`spawn`, Task, Mutex, Chan, the `threads`
capability; see "C7: threads"). **Driver parity is done** (`test --compile-fail`, the binary
and core-object cache, work directories, `--help`; see "C7: driver"). **C7 done**: the tests'
expected results are recorded in `tests/oracle/`, and everything builds from the seed (see
"C7: recording the oracle").

## Goal

A compiler for Eider written in Eider, so that the only non-Eider code in the toolchain is
the C core (`core/`) and building Eider from nothing needs only a C11 compiler. Done at C7.

Non-goals for the first version: a new back end (we keep emitting portable C11), an
interpreter, incremental compilation, an LSP. The design leaves room for all of them.

## Why this order

Every missing language feature (byte access on `String`, bitwise operators, capability
encapsulation, package-qualified modules, `Ok(())`, exit codes) currently forces workarounds
into `std/` and packages. Those workarounds would harden into APIs. So the compiler came
first, reaching parity with the language as the tests specify it; the language gains those
features in the compiler, and then std and packages are reworked on a correct base. The
compiler is the one program that has to live with the language's current limits.

## Bootstrap chain

Since C7 (`scripts/selfhost.sh`):

```
seed    cc seed/eiderc.c core/eider_rt.c core/eider_core.c  ->  a working eiderc
stage1  compiler/ built by the seed   compiles compiler/ -> stage2
stage2  compiler/ built by stage1     compiles compiler/ -> stage3
fixed point: the C that stage2 and stage3 emit for compiler/ is byte-identical
new seed: stage3's C is written to seed/eiderc.c (`--seed`) with every compiler change
```

Every stage is built with only `$CC` and the C core (`-Werror`, the driver's warning flags).
`scripts/ei` (the compiler every script and test runner uses) is the seed compiled by `$CC`
into `target/eiderc`. The seed is regenerated (and the fixed point re-checked) whenever the
compiler changes. The rule: the compiler may only use language features that the previous
seed supports (seed/README.md).

## History

eiderc was bootstrapped from an earlier implementation of the language, written in Rust and
kept in a separate repository. Until C7 it was the first stage of the chain (it built stage1;
the first seed, committed at C6, came out of that chain) and the differential oracle of the
compiler tests: `compiler/` had to build with it, and eiderc was ported pass by pass to
reproduce its observable behaviour. At C7, once eiderc reached parity, that behaviour
(diagnostics, dumps, program output, headers, wasm loaders) was recorded once into
`tests/oracle/` by a one-off script (`scripts/record-oracle.sh`, commit 8446756, deleted
afterwards) and the earlier implementation was retired; nothing in this repository builds or
runs it. Where eiderc still reproduces one of its quirks for compatibility with those
recordings, the quirk is listed under "C8 candidates"; the bugs eiderc fixed deliberately have
regression tests with hand-written expected output (LEARNINGS.md, `compiler/tests/run/bug_*`).
The progress numbers in the sections below were measured against it at the time.

## Unmanaged code inventory

| Code | Today | Target |
|---|---|---|
| OS interop | `core/eider_core.c` (ABI in `core/ABI.md`) | unchanged; one backend file per OS |
| Language runtime (traps, checked arithmetic, allocation, string/list helpers, thread glue) | `core/eider_rt.{h,c}` (once C text pasted into every program) | `core/eider_rt.h` + `core/eider_rt.c` (done; contract and inventory in `core/RUNTIME.md`, tested by `tests/core/run.sh`), included by code from the self-hosted compiler |
| Per-type glue (drop/clone/equality/hash for each concrete type) | generated C | generated C (compiler output; trusted because the compiler is) |
| WASM libc shim | `core/wasm/` (written for eiderc, `core/wasm/README.md`): `eider_rt.c`, the runtime contract for wasm32, and `libc.c`, the freestanding C library | unchanged |

Moving the runtime into `core/` makes it reviewable, testable under sanitizers on its own,
and portable per target, instead of being a string inside a compiler.

## Language contract

The language is what the test suites specify, with the expected results recorded in
`tests/oracle/`:

- `tests/checks/fail` and `tests/checks/pass`: every diagnostic code with its exact position.
- `tests/run/*.ei` + `.out`: runtime behaviour, including evaluation order and traps.
- `tests/std`, `packages/*/tests`: library behaviour on top of the core.
- `LEARNINGS.md`: semantics that the tests don't pin down well (value semantics, drops on
  every exit path, left-to-right evaluation, snapshot captures).

`eiderc` must pass all of them. Generated C is not part of
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
| `driver` | CLI, `cc`, cache | uses `std/fs` and `std/proc` |

A compiler that fuses checking and C emission pays for it with evaluation-order and hoisting
bugs (every operand that hoists statements has to be reordered by hand). Keeping a typed IR
between `check` and `lower` removes that class of bug and is where later work (optimisation,
another back end) attaches.

Diagnostics: one list of codes (`diag.all_codes()`), human and `--json` rendering,
machine-applicable fixes. Every independent error is reported, the first exactly as a
compiler stopping at the first error reports it ("Front-end recovery", "Several errors").

## Writing the compiler in today's Eider

`compiler/` must compile with the current seed (seed/README.md), so it uses the language the
seed supports:

- Text is `List[u8]`; symbols are interned `u32`. `String` only for messages.
- No owned data in hot loops' reads: index into arenas, keep records small and flat.
- `Map` keys are integers (symbol ids, type ids). No `Map[List[u8], _]`.
- No threads, no closures in hot paths (closures copy their captures).
- `uses ffi` everywhere is accepted in the compiler for now (it sits on std).

## C3: checking

`eiderc check` runs lex, parse, `resolve.load` (module graph) and `check.check`, and prints
`ok` or the diagnostics exactly as tests/oracle records them (`--json` byte for byte);
`eiderc ir` dumps the typed IR.

- **Fixed passes, fixed order.** `check.ei` runs: type templates, non-generic types,
  function names, constants, every signature, test bodies, then function bodies in *reverse*
  order (popped from a stack). This order decides which error (and which file) comes first
  in a program with several errors, as tests/oracle records it, and the order of the rest
  ("Several errors").
- **Names.** An imported module's items are named `stem__Name`, and the checker sees one
  flat table. `resolve.ei` keys every name as (module prefix, symbol) in a u64 and applies
  the renaming rules (own items, function locals, patterns, tests), so a lookup hits exactly
  what the mangled name would; messages spell keys mangled and `diag.demangle` turns `a__B`
  into `a.B` for the report. Modules are identified by real path (`fs.canonical`, i.e. the
  core's `ec_realpath`), so the deps/ link farm's paths to one file are one module.
- **Folding** (`fold.ei`) computes in a sign + 128-bit magnitude, enough for every value an
  i128 computation over in-range operands gives (E0501 messages print them).
- **Out of scope** (nothing language-level since C7; earlier, threads, comptime, WebAssembly and FFI until their C7 sections) ends checking
  with an `unsupported` diagnostic at the point where the feature would start being handled;
  everything reported before it is exact, and the test script counts such files as out of
  scope.
- **The IR** (node table at the top of `ir.ei`) is what C4 lowers: per function a table of
  locals and a tree of blocks; every intermediate value is a single-assignment temporary in
  source evaluation order, variable reads are explicit `read`s of places (local, field,
  bounds-checked element, enum payload), `&&`/`||` and `match` are lowered to `if`, `for`
  loops to `loop` with a `step` block (what `continue` runs). Constants are folded values.
- **Tests.** `scripts/test-compiler.sh` compares `check --json` with the oracle on
  tests/checks (51/74 in scope at C3, 64/74 since C5, 69/74 since FFI, 72/74 since comptime,
  all agree), tests/run (3/11, then 8/11, then 9/11, then 10/11), and eiderc's own cases
  (229 at C3, 418 since C5, 456 since FFI, 503 since comptime) in
  `compiler/tests/check` (fail cases carry `// expect:` headers for the compile-fail runner,
  `eiderc test --compile-fail`; helper modules in `lib/`); IR goldens live in
  `compiler/tests/ir`. `scripts/fuzz-check.sh` (packages/fuzz) mutates v0 programs; it holds
  eiderc to crash and consistency invariants and compares `check --json` with the seed ("C7:
  recording the oracle"); run it after checker changes.
- **Quirks kept for compatibility with the recorded expectations** (C8 candidates, see "C8
  candidates"):
  `Enum.Variant` fails (E0114) for an enum of an imported module, or inside one, because
  variant names are prefixed but the field name isn't; errors in an imported module's test
  blocks, and E0801 for a private field type checked while constructing from another module,
  name the wrong file; that E0801 itself (a public record with a private field type can't be
  built outside its module) is checked against the constructing module; in a module's test
  block, a local named like one of the module's items is shadowed by the item; `x /= 0` is
  not a compile error although `x / 0` is. Since C5: a name in an impl target that isn't
  a type parameter matches every type (check.ei `unify_ast`), so `impl Area for Sq` meets
  `T: Area` for any T (the instance body then fails) and `impl W[i32]`'s methods apply to
  every `W`; registering an impl compares signatures as text after replacing every `Self`,
  also inside names like `MySelf`; impls on fn types never match a receiver (the receiver's
  head is spelled as the whole type).

## C5: checking S1–S3

`check.ei` covers the rest of the language that `compiler/`, std and the packages use:
everything in them checks `ok`, as tests/oracle records, once core/sys.ei's `extern` fns are
replaced by stubs (and, since "C7: FFI", without stubs).

- **S1.** Tuples (types, literals, `.0`, patterns, `let (a, b) =`); generic types and
  functions, monomorphized on demand: a generic type is a template definition and each
  instance its own definition (types.ei; type lists are interned so instances compare as
  ids), a generic function or method one IR function per instance (`swap[i32, bool]`,
  `Option[u32].unwrap`), inferred in a fixed order (`unify_ast` from the expected type,
  the receiver, then argument by argument; E0409). Traits, impls and bounds (E0601, E0602,
  E0603), inherent and generic methods, `Self`, `?` (E0406), `if let`, nested patterns.
  Bodies are checked from a stack of pending instances, which fixes which error comes
  first. Option and Result come from **`core/prelude.ei`** (its text fixes the positions
  tests/oracle records for prelude items), which `resolve.load` reads from the toolchain root:
  `$EIDER_ROOT`, else the parent of the directory holding the eiderc binary (argv[0]),
  else the current directory.
- **S2.** String, List, Map, Box with their associated functions and methods, `len`,
  `for x in list`, list indexing, E0303 (mutating methods need an assignable receiver),
  E0409 (`List.new()`/`Map.new()` need an annotation), E0701 (Map keys), E0504 (owned
  constants), `==` without Maps. Ownership: reads borrow, storing a borrow clones, fresh values are registered in their block's frame and moved out by `take`,
  frames are dropped on every exit; it is explicit in the IR: S_CLONE, S_DROP, S_MOVE,
  S_BUILTIN; `lower` only prints it (ir.ei, "Ownership").
- **S3.** fn types, closures with snapshot captures (each body an IR function whose
  L_CAPTURE locals hold the environment; S_CLOSURE builds it), named functions as values
  (S_FNREF), calls of fn values (S_CALLV), map/filter/for_each/any/all/fold as IR loops,
  and the closure cases of E0405/E0409. `?` in an expression-bodied closure stays
  `unsupported`: checking it against the enclosing function's return type would be wrong
  (LEARNINGS.md, "C8 candidates").
- **Tests.** Every new rule has cases in `compiler/tests/check` (`s1_*`, `s2_*`, `s3_*`
  pass files, and fail files by code); IR goldens `generics`, `heap` and `closures` in
  `compiler/tests/ir` show where clones and drops go.

## C5: lowering

`lower.ei` lowers every IR node of S1–S3. The checker already placed every clone, move and
drop (ir.ei, "Ownership"), so lowering only prints them: S_READ is a bitwise copy (a borrow
of owned data), S_CLONE calls the type's clone, S_DROP its drop, S_MOVE is a bitwise copy
whose source is dead. (Since C8.1 a clone of a String, List, Map or Box shares its buffer; see "C8.1: copy-on-write".)

- **Layout** (fixed where it is observable; Map behaviour is what tests/oracle records): tuples are structs `f<n>`; String is the
  runtime's `ei_String`; List[T] `{ T *d; uint64_t len, cap; }` (grows by doubling from 4);
  Map[K, V] an open-addressing table `{ K *k; V *v; uint8_t *s; uint64_t len, cap,
  used; }` (slot states empty/used/deleted, capacity a power of two from 8, grows when
  `(used + 1) * 4 > cap * 3`, keys hashed with `ei_hash_u64`/`ei_hash_str` and probed
  linearly, so lookups behave exactly as recorded; Maps have no iteration, so their order is
  not observable); Box[T] `{ T *p; }`; a fn value `{ void *env; R (*call)(void *, ...);
  void (*drop)(void *); void *(*clone)(void *); }`. A closure body is a C function taking
  the environment first; its L_CAPTURE locals are copies (borrows) of the environment's
  fields. S_CLOSURE allocates the environment struct `env_<f>` and moves the captured values
  in; S_FNREF points at a thunk `k_<f>` with no environment; S_CALLV is
  `f.call(f.env, args)`.
- **Builtins** call the runtime for String (`ei_str_from`, `ei_str_push`, `ei_str_append`,
  ...) and generated glue for the rest: `push_`, `has_` (List), `find_`, `get_`, `ins_`,
  `rem_` (Map), `new_` (Box); `pop`, `sum`, `len`, `is_empty` and `Map.get`'s Option are
  written inline; `clear` is the List's drop (which leaves it empty).
- **Glue** (`eq_`, `drop_`, `clone_`, `name_` and the above, plus `env_`/`edrop_`/`eclone_`
  per closure body and `k_` per function used as a value) is requested while the functions
  are lowered and generated afterwards from a work list, each item once, keyed by kind and
  type; only what is used is emitted, in one shared section. Every size computation goes
  through `ei_alloc_n` (overflow-checked); memory is freed with `ei_free`.
- **Stable names.** C names depend only on what they name, never on arena indexes or
  declaration order. Module identity is today's module prefix (the file stem, unique per
  program by E0808; none for the entry module), which the checker spells into every item's
  name (`stem__name`). `<h>` is 8 hex digits of a 64-bit hash of the spelled name or type:
  `t_<key>` for records and enums (`t_<key>_<h>` for instances such as `Pair[i32, bool]`),
  `ta_<h>`, `tt_<h>`, `tl_<h>`, `tm_<h>`, `tb_<h>`, `tf_<h>` for arrays, tuples, Lists,
  Maps, Boxes and fn types, `f_<name>` for functions with `.` spelled `__` (`f_Sq__area`,
  `f_geo__area`) and `_<h>` replacing the type arguments of instances
  (`f_Option__unwrap_or_<h>`), closures numbered per enclosing function
  (`f_main__closure2`, not the checker's program-wide counter), `x_<name>_<h>` for test
  blocks (`_2`, ... for repeated names), and glue `<op>_<type>`. Every global name is
  registered with what it names; two things with one C name stop `emit-c` with
  `eiderc: internal error: C name clash ...` and exit 3 (`compiler/tests/lower/clash.ei`:
  `Sq.area` and a function `Sq__area`).
- **Output order** (the per-module boundary): includes, extern prototypes (`extern_protos`:
  `extern <ret> xc_<name>(<params>) __asm__("<symbol>");`, the names registered by `name_all`
  like every other), types, prototypes, shared glue, then functions per module (entry module
  first, then the others in order of first appearance), generic instances sorted by C name,
  tests, `main` (a library build has no `main` but the `eider_<name>` export wrappers, also
  registered names; its header keeps the recorded spelling, see "C7: FFI"). Nothing in the C
  depends on paths except the trap file name, which is the
  path as given on the command line.
- **Leak check.** The runtime built with `-DEI_RT_COUNT_ALLOCS` counts live allocations, and
  generated `main` calls `ei_check_leaks()` when the program ends normally (in test mode only
  if no test failed, since a trap does not unwind), which then prints
  `eider: outstanding allocations: <n>` to stderr. ASan isn't installed here, so this is how
  drops on every exit path are checked.
- **Tests** (`scripts/test-compiler.sh`): tests/run's adt, closures, heap and heap2 now pass,
  and compiler/tests/run adds `strings`, `lists`, `maps`, `owned`, `exits`, `generics` and
  `closures2` (String building and comparison; every List and Map operation with int, bool,
  str and String keys, including rehashing; Box; nested owned data in records, enums, tuples,
  arrays and Lists; copies that don't share; drops on return/break/continue/`?`/match arms;
  generic functions, types and methods with several instances; closures capturing owned
  values, stored, copied and returned; `?` on Option and Result): 31/31 in-scope run tests
  agree with the oracle, every run is clean under UBSan at -O2 and ends with 0
  outstanding allocations ("leaks"), and `emit-c` of every run test is byte-identical twice
  and from a copy of the test directory at another path ("determinism").
- **Self-hosting** before FFI landed: with core/sys.ei's extern fns stubbed in a scratch
  copy, eiderc already compiled its own source to C that reached a fixed point and agreed
  with the first eiderc build on all 541 test programs; with FFI merged that became C6.

## C6: self-hosting

`scripts/selfhost.sh` (2026-10-30, 16 cores, gcc; at C6 the chain still started from the
earlier implementation, "History"): it builds stage1 from `compiler/` (8.3 s, mostly gcc -O2); stage1 emits C for `compiler/main.ei` (0.12 s) that is compiled into
stage2 with the driver's warning flags as errors (`-Werror`, -O2: ~10 s), stage2 does the same
for stage3, and stage2's and stage3's C are byte-identical (the fixed point; it was on the
first run, as the stubbed experiment in "C5: lowering" predicted). Then stage3 rebuilt with
`-DEI_RT_COUNT_ALLOCS` must emit the same C and report 0 outstanding allocations, and stage3
must pass the whole `scripts/test-compiler.sh` (`EIDERC=`): 756 files agree on lex/parse,
69/69 + 9/9 + 456/456 check cases, 33/33 run tests (39 runs under UBSan, 39 leak-free),
33/33 deterministic, the clash test, and all export tests. The only problem it found was in
the test script: the determinism check ran `$OLDPWD/$new`, which breaks when `EIDERC` is
an absolute path.

- **The seed.** `sh scripts/selfhost.sh --seed` writes stage3's C to `seed/eiderc.c`
  (76,780 lines, 2.1 MB, from 11.7k lines of Eider in `compiler/`); see `seed/README.md`.
  `sh scripts/selfhost.sh --from-seed` builds eiderc from it with only `cc` (10 s at -O2,
  2.9 s at -O0) and checks that it emits the seed again; `scripts/verify.sh` runs that leg.
- **The rule** from now on: `compiler/` may use only features the current seed supports, and
  the seed is regenerated with every compiler change; the chain starts from the seed
  ("Bootstrap chain").

## C7: FFI

Done ahead of the rest of C7 because eiderc's own source reaches the OS only through
core/sys.ei's `extern "c"` functions. Externs, exports, `unsafe` and the library header;
capability encapsulation ("Language work" item 5) is not
started, so callers of std still write `uses ffi`.

- **Checking.** An `extern "c" fn` is a free function without a body, named globally
  (never module-prefixed), and `unsafe` (the parser marks it). When its signature is
  resolved (with every other concrete signature, in item order) it must be C-safe, else
  E0803: each parameter in order is not `inout` and is an integer, `bool` or `str`; the
  return type is one of those or `()`. An `export fn` must not be generic (E0805, when
  function names are registered) and gets the same E0803 check, where records made only of
  C-safe types (recursively) are allowed too. A call to an extern needs, after the callee's
  own `uses` capabilities, the `ffi` capability (E0201, with the usual fix), then an
  `unsafe` block or `unsafe fn` around it (E0802, "call to C function"); an `unsafe fn` only
  the latter. `unsafe` is lexical: a closure created inside `unsafe { }` may call externs.
  With `--lib` (and for `emit-header`) the program is a library: `main` is not required and
  at least one `export fn` is (E0805 at 1:1).
- **Not supported** (`unsupported`): an extern or
  `unsafe fn` used as a function value: checking only declared capabilities would accept it
  without `unsafe` or `ffi` (a hole; the value can then be called anywhere), so it waits for
  a language decision ("C8 candidates").
- **IR.** `Ir.externs` ({function, C symbol, parameter types}; the function has no body and
  carries the return type) and `Ir.exports` ({function, `stem__name`}), shown first by
  `eiderc ir` (golden `compiler/tests/ir/ffi`). Calls to externs are ordinary `S_CALL`s.
- **Lowering.** `extern_protos`: `extern <ret> <C name>(<params>) __asm__("<symbol>");`,
  under eiderc's own function name so it never clashes with libc headers or other
  declarations of the symbol (core/ABI.md rule 5; ELF only, Mach-O would need the `_`).
  `program_for(.., lib = true)` drops `main` and adds one non-static entry point per export,
  `<ret> eider_<stem__name>(<params>) { ei_set_file("lib"); return f(..); }`; a trap inside
  exits the process with 101 and names `lib`. `header` is the recorded header byte for byte
  (records `R_<mangled name>` with fields `f_<name>`, `extern "C"` for C++), except that
  every record gets a typedef: giving one only to parameter and return types, as recorded,
  makes a header that doesn't compile when a record is a field of another (a deliberate fix,
  compiler/tests/export/nested.ei).
- **Driver.** `emit-header <f>`; `build --lib <f> [-o name]` compiles the library C,
  `core/eider_rt.c` and `core/eider_core.c` at -O2 -fPIC, makes `lib<name>.a` (ar rcs) and
  `lib<name>.so` (cc -shared, with the `-l` libraries) next to `-o`'s path (else in the
  working directory) plus `<name>.h`, and prints `built <a>, <so>, <h>`. The
  library carries the runtime and the core, so a consumer links only it (the runtime
  symbols `ei_*` / `ec_*` are global, not static functions pasted into the C, which static
  linking resolves to one copy and which two shared Eider libraries share). `-l <lib>` (repeatable) links C libraries into `build`, `run` and `test`.
- **Tests.** The suite's four FFI files and `tests/run/ffi.ei` are in scope; 38 cases in
  `compiler/tests/check` (`*_ffi_*`: every E0803 shape for externs and exports, nested and
  imported cases, the E0201/E0802 order, unsafe scoping, E0107 between externs); run test
  `compiler/tests/run/ffi_libc.ei` (every C-safe type, unit and `str` results, an extern
  behind a module's wrapper); "export" in `scripts/test-compiler.sh`: `tests/export/run.sh`
  with `EIDER=eiderc` (C and C++ consumers, static and shared, trap exit code),
  `compiler/tests/export/run.sh` (more types, nested records, an imported module's export,
  two libraries in one program, headers as C11 and C++ with -Werror), and `check --lib` and
  `emit-header` against the oracle. `eiderc check` accepts core/sys.ei, std and
  `compiler/main.ei` (no `unsupported` left in them).

## C7: comptime

`const X: T = comptime expr` (`compiler/comptime.ei`; imported as `consteval`, since
`comptime` is a keyword). Comptime constants are evaluated between loading the module
graph and checking: `comptime.eval`, called by main.ei between
`resolve.load` and `check.check_mode` (check.ei still answers `unsupported` for a comptime
constant it is handed, so a caller that skips `eval` finds out).

- **Semantics** (as tests/oracle records them). Each comptime constant in item order: if its type isn't
  spelled as an integer type or `bool`, E0807 at the constant's name. Otherwise an
  evaluator program is checked: the program without any `main` (imported modules' too),
  test blocks or comptime constants not yet evaluated, plus `fn __ct() -> T { return expr }`
  and `fn main() uses io { print(__ct()) }` in the constant's module. Any error is reported
  as it is (so an unrelated error elsewhere in the program can surface here), except that
  E0201 with a fix loses the fix and gets the help "`comptime` evaluation can't use
  capabilities". The program is run; a nonzero exit is E0807 "comptime evaluation of `X`
  failed: <first stderr line>" (traps name the file `program`), more than one line of
  output E0807 too, and the printed value replaces the expression as a literal (`-(n)` for a
  negative value), so later comptime constants see an ordinary constant. Consequences kept
  for compatibility with the recorded expectations (C8 candidates): a comptime constant can't use a later one, and nothing outside comptime
  constants may name a comptime constant that comes later (a plain `const` naming any
  comptime constant always fails, E0110), because the item is missing from the evaluator
  of every earlier one.
- **How.** In process, with eiderc's own passes: `evaluator` copies the resolved program
  and rewrites each module's item list (the stub nodes are built in the constant's module's
  AST arena, at the recorded stub positions: `__ct` at 1:4 for E0107), `checked` runs check.ei on it, and
  `run_evaluator` lowers the IR with `lower.program_for`, compiles it with the driver's
  `cc_argv` (-O0, `$CC`, `$EIDER_CFLAGS`) against `core/eider_rt.c` and `core/eider_core.c`
  compiled once per program into a temporary directory, runs it with stdout and stderr
  captured and returns an `Outcome` (`Printed`, `Failed`, `NoBuild`). The literal is spliced
  into the original program (a new token and AST node, the constant's `comptime` flag
  cleared). A comptime constant costs a check of the program plus a C compile and link
  (~50 ms each for tests/run/comptime.ei's 4 constants).
- **Deliberate choices.** The stub is appended to the constant's module, not after the
  last item of the whole program; that is the same for the entry file, while for an imported
  module's constant only the order in which two independent errors are found can differ from
  the recording. The evaluator is built with the driver's flags (not `-O1 -w`), so
  `$EIDER_CFLAGS` applies to it too.
- **Later (C8): an IR interpreter.** Evaluating by compiling C needs a C compiler at
  compile time and keeps the evaluator off capabilities only by checking. An interpreter of
  eiderc's IR (ints, bool, and whatever the called functions use: records, enums, Lists,
  closures) would need neither, and no temporary files; it can then lift the
  restrictions above with a design note (forward references, other constant types). The swap is
  local: replace `run_evaluator(c: check.C) -> Outcome` in comptime.ei; selection of
  constants, the evaluator program, error mapping and splicing stay.
- **Tests.** tests/checks' e0201_comptime_io, e0807_comptime_str and e0807_comptime_trap
  and tests/run/comptime.ei are in scope; 47 cases in `compiler/tests/check` (`*comptime*`:
  E0807 for each non-int type and for traps in every arithmetic op, casts, indexing,
  `panic`, `assert`, `unwrap` in the prelude, a failure in the second of two constants;
  E0201 for io, clock, ffi and a builtin; the evaluator's own errors (E0110 forward
  references, E0401, E0501, E0502, E0107 for `__ct` and for an imported `main`, E0112);
  helper modules `lib/ct_*.ei` for imported constants), and run test
  `compiler/tests/run/comptime.ei` (chains, negative values, bool, the range edges of every
  integer type, owned data, records, generics, closures and match during evaluation, an
  imported module's constants, test blocks using them).

## C7: WebAssembly

- **Checking.** `--wasm` (`check`, `emit-c`, `emit-header`, `build`, `run`; `test` ignores
  it like `--lib`) checks the program as a library (`check.check_wasm`: no `main`, E0805)
  whose exports take only integer and bool parameters (E0806 at the parameter) and return an
  integer, bool or `()` (E0806 at the function), checked before the E0803 rules, which then
  allow no records. A program that uses a thread type (`Task`, `Mutex`, `Chan`, so also
  `spawn`) gets E0806 at 1:1 after everything else is checked (as tests/oracle records:
  the thread type is noted while checking, the error reported at the end). Until eiderc
  checks threads, `spawn` stops checking with `unsupported`, which `check_wasm` turns into
  that E0806. The compile-fail runner reads `// mode: wasm` and
  passes `--wasm` (as `scripts/test-compiler.sh` does).
- **Lowering.** `lower.program_wasm`: the library C, with each `eider_<name>` entry point
  marked `__attribute__((export_name("eider_<name>")))`.
- **Driver** (`wasm.ei`). `build --wasm` (and `run --wasm`, which also only builds) compiles that C
  with `core/wasm/eider_rt.c` and `core/wasm/libc.c` by `$WASM_CC` (default clang) for
  wasm32 (the command is at the top of wasm.ei), and writes `<name>.wasm`, `<name>.d.ts` and
  `<name>.js` (`-o`'s path, else the source's stem), printing `built <wasm>, <d.ts>, <js>`;
  a failed compile is exit 3 with the recorded message. The `.d.ts` and the loader are the
  recorded text byte for byte (`emit-header --wasm` prints both: declarations, `\x01`,
  loader naming the module `@WASM@`). Only this command needs clang and wasm-ld.
- **Tests.** The two `e0806_*` compile-fail tests; "wasm" in `scripts/test-compiler.sh`:
  `check --wasm` and `emit-header --wasm` against the oracle, then
  `compiler/tests/wasm/run.sh`: `tests/wasm/core.sh` (core/wasm warning-free for wasm32 and
  as `-fsyntax-only -nostdinc` freestanding C on the host; the emitted C of the wasm tests
  likewise), `tests/wasm/run.sh` with `EIDER=eiderc`, and `compiler/tests/wasm/*.ei` (every
  integer type and bool both ways, `()` results, output through `eider_write`, traps becoming
  `unreachable` with the message printed, a line over 511 bytes) run under node against
  hand-checked `.out` files and against the recorded module (same output, same `.d.ts` and
  `.js`). Without clang's wasm32 target, wasm-ld or node the module legs print `skip`.

## C7: threads

Task, Mutex, Chan and `spawn`. Threads share data only through
these handles: everything else a closure captures is a snapshot (a copy; since C8.1 a copy-on-write one, made unique before the thread starts), and values
cross threads only by move (the spawned closure, `send`) or by copy under the lock
(`Mutex.get`, `Task.join`).

- **Checking** (`check.ei`: `spawn`, `thread_static`, `thread_method`, kept apart from the
  rest). Types `Task[T]` (T may be `()`), `Mutex[T]`, `Chan[T]` (E0111 for `()`, arity,
  bare names); `owns` is true for them, `==` is not supported (E0401, also inside Lists,
  records, ...), they can't be Map keys (E0701) or printed. `spawn(f)` needs `threads`
  (E0201, checked before anything else), exactly one argument (E0405), a closure with no
  parameters (E0401) that returns (E0401 for `!`); the closure gets no hint, so a
  value-form body needs `-> T` (E0409). `Mutex.new(v)` (E0405, hint from the annotation,
  E0401 for `()`), `Chan.new()` (E0409 without a `Chan` annotation, then E0405), `Task`
  has no associated functions (E0115). Methods: `join`, `get`, `set`, `update` (E0405
  "`update` takes exactly one closure"; the closure is checked against `fn(T) -> T` with
  that hint), `send`, `recv` (-> `Option[T]`), `close`; anything else is E0115, also a
  method a user `impl` adds to `Mutex[i32]` (the built-in methods are tried first).
  None needs an assignable receiver or a capability. Diagnostics match tests/oracle byte for byte.
- **IR** (ir.ei): types T_TASK/T_MUTEX/T_CHAN (types.ei; `task_of` also interns
  `fn() -> T`); builtins B_SPAWN, B_TASK_JOIN, B_MUTEX_NEW/GET/SET/UPDATE,
  B_CHAN_NEW/SEND/RECV/CLOSE (no new statement kinds). Receivers are borrowed operands;
  spawn's closure and the values given to `Mutex.new`, `set` and `send` are moved in;
  `join`, `get` and `recv` give owned results; `update` borrows its closure, which its
  owner drops (golden `compiler/tests/ir/threads`).
- **Lowering** (`lower.ei`, "threads"). A handle is `{ struct <name>_c *p; }` (`tk_`,
  `tx_`, `tc_` names); the shared object starts with the runtime's `ei_rc` and embeds an
  `ei_thread` + the closure + the result (Task), an `ei_mutex` + the value (Mutex) or an
  `ei_chan` of `sizeof(T)` elements (Chan); those structs are emitted after every type, so
  `type Node = { next: Option[Mutex[Node]] }` works. Glue per type only (`spawn_`/`run_`/
  `join_`, `new_`/`get_`/`set_`/`upd_`, `new_`/`send_`/`recv_`, plus drop and clone):
  every lock, wait, thread start and join is a call into core/eider_rt.c. Copying a handle
  is `ei_rc_inc`; the last drop frees the object: a Task joins its thread first (so no
  thread outlives its last handle, and the leak check at the end of `main` runs with no
  thread left), then drops its closure and result; a Mutex drops its value; a Chan drops
  the values still queued (`ei_chan_len`/`ei_chan_at`).
- **Deliberate fixes.** `Mutex.update` borrows its closure: dropping it inside the update
  as well as in the caller would free a capturing closure twice (regression test
  `bug_update_capture`). `set` and `update` drop the old value after unlocking, not under
  the lock: dropping a value can join a thread (a Task inside the Mutex), and that thread may
  need the same lock, which would deadlock. Channels, locks and reference counts are the
  core's `ei_chan`, checked pthread calls and a 64-bit atomic `ei_rc`. The core's mutex is
  error-checking, so an `update` closure that uses the same Mutex traps (`cannot lock a
  mutex`, exit 101) instead of relocking a default pthread mutex (undefined; glibc
  deadlocks). Kept: a trap inside an `update` closure in
  test mode longjmps with the lock held (core/RUNTIME.md); `contains` on a List of handles
  compares them as equal (a C8 candidate); reference cycles through handles (a
  channel sent into itself) leak, as with any reference count; a Task whose last handle is
  dropped on its own thread traps (`cannot join a thread`).
- **Tests.** tests/run/threads.ei, and the threads cases of tests/checks (except
  `e0806_wasm_threads`, WebAssembly); 38 fail and 3 pass cases `*_thr_*` in
  `compiler/tests/check`; run tests `threads_chan` (8/1/16 producers x consumers with exact
  sums, `close` waking blocked receivers, queued owned values dropped, a 6-stage pipeline),
  `threads_mutex` (16 x 2000 increments, String/record/List values under the lock, racing
  `set`/`get`), `threads_task` (owned results, joins from many threads, Tasks dropped
  unjoined, nested and recursive spawns, snapshots, 200 Tasks), `threads_handles` (handles
  in records, enums, Box, Option, Lists, channels of Tasks and reply channels, a recursive
  type through a Mutex, one fn value spawned many times), `trap_threads` (send on a closed
  channel from another thread, threads in test blocks), and the regressions
  `bug_update_capture` and `bug_get_method_arg` (`String.from_int(m.get().len() as i64)`
  once compiled to the invalid C `void tN = ;`). Each also ran 50 times under UBSan (trap mode,
  -O2), the allocation counter, clang's and gcc's TSan, and clang's ASan+UBSan, with no
  report: 8 programs x 5 builds x 50 runs, twice (before and after the error-checking
  mutex). In the suite: 41/41 run tests, 144/144 sanitizer runs, 48/48 leak-free.

## C7: driver

The rest of the driver, so every command the tests use exists in eiderc.

- **`eiderc test --compile-fail [<dir>]`** (`suite.ei`; default `tests/checks`): the
  compile-fail runner, with the lines and exit code tests/oracle records. Each `<dir>/fail/*.ei` starts with
  `// expect: CODE LINE:COL` (the header is line 1 of the file as compiled) and must fail
  with exactly that code and position; if the diagnostic carries a fix, `diag.apply_fix`
  applies it (columns in Unicode scalar values) and the fixed source must compile
  (`(fix compiles)`) or fail with another code or position (`(fix resolves it; next: X)`),
  never with the same error. `<dir>/pass/*.ei` must compile. A file containing
  `// mode: test` is checked as a test build (no `main` needed: the checker reports a
  missing `main` last, so that error alone counts as success), `// mode: wasm` as a
  WebAssembly build. The last line is the error-code coverage against
  **`diag.all_codes()`**, the one list of the language's codes (in the recorded order; a new
  code is added there with its test). eiderc's extra: a file it answers
  `unsupported` for is a `skip` line, counted in `<n> skipped (not yet supported by
  eiderc)` before the summary, neither passed nor failed. **WebAssembly mode is not in
  eiderc yet** (being added in parallel as `check --wasm`): until then `// mode: wasm` files
  are checked as programs and any mismatch is reported as `skip` (TODO in suite.ei).
  The runner runs main.ei's sequence: lex, parse, `resolve.load`, `consteval.eval`
  (comptime), `check.check_mode`. Results: `compiler/tests/check` is byte-identical to
  the recorded output (503 passed, 0 failed, coverage 38/42). `tests/checks`: 71 passed, 0
  failed, 3 skipped, coverage 41/42 against the recorded 74 passed and 42/42; the one missing
  code is E0806 (e0806_wasm_str needs WebAssembly mode, e0806_wasm_threads threads), and
  the third skip, e0409_chan (threads), has a code that other files cover. `compiler/tests/suite` holds the
  runner's own cases (wrong code, wrong position, missing header, a file that compiles, a
  rejected pass file, a fix after non-ASCII text, a fix that leads to the next error, test
  mode), whose output (5 failed, exit 1) must equal the recorded output too.
- **Cache** (top of `driver.ei`). `EIDER_CACHE=off` disables it, `EIDER_CACHE=<dir>` moves
  it, the default is `$XDG_CACHE_HOME/eider`, else `~/.cache/eider`, with
  eiderc's entries in subdirectories (`core/`, `bin/`, `tmp/`). Keys are SHA-256 (`sha256.ei`,
  see LAYERS.md for why the compiler has its own) over length-prefixed parts:
  `core/<key>/{eider_rt.o,eider_core.o}`, the C core compiled once per toolchain, keyed by
  the whole cc argv (cc, warning and -O flags, `$EIDER_CFLAGS`, `-I <root>/core`, `-fPIC`
  for libraries), `$CC --version`, `LIBRARY_PATH`/`CPATH`/`C_INCLUDE_PATH` and the bytes of
  eider_rt.h, eider_rt.c and eider_core.c; and `bin/<key>`, an executable, keyed by the same
  toolchain parts, the core objects (their path holds their key), the `-l` libraries and the
  generated C. `run` executes a cached binary in place, `build` copies it to `-o`'s path
  (removing the old file first, so a running binary isn't rewritten). Not in any key: the
  contents of external `-l` libraries and of system headers beyond what `--version`
  identifies. With the cache off the
  core sources are compiled into each program, as before.
- **Work directories.** Each compile gets its own `eiderc-<ms>-<n>` directory made with an
  exclusive mkdir, under `<cache>/tmp/`, else (cache off) `<root>/target/tmp/`, else
  `$TMPDIR` or `/tmp` if neither is writable; it is removed afterwards (kept, with the C, when
  the C fails to compile). Entries are made there and renamed into the cache, so they appear
  atomically: the core objects as one directory (a rename onto an existing one fails, and
  the loser uses the winner's), a binary as one file. Twelve concurrent `eiderc run`s on an
  empty cache all succeed with one binary and one core build ("cache" in test-compiler.sh).
- **Reusable entry points** for C built by the compiler itself (comptime): `driver.executable(c,
  file, release, libs)` returns an `Exe` (the binary's path, cached or in its work
  directory) for the caller to run, `driver.try_executable` the same for C that may not
  compile (output captured, None on failure), `driver.discard(e)` removes the work
  directory; `build`, `build_lib` and `run` keep their signatures, and `temp_dir` (now a
  work directory) and `cc_argv` stay public. With the cache on, comptime builds each
  evaluator through `try_executable`, so it links the cached core objects and an unchanged
  constant's evaluator is a cache hit: `eiderc check tests/run/comptime.ei` takes 0.29 s
  with the cache off (the core compiled once per program, as comptime did before), 0.24 s
  with only the core cached, 0.03 s when nothing changed.
- **Usage.** `eiderc --help` (also `-h`, `help`) prints every command, option and
  environment variable to stdout and exits 0; no arguments prints it to stderr and exits 2;
  an unknown option, an unknown command, a missing source file, a stray second file, `-o`/`-l`
  without a value, or `--compile-fail` with another command is a one-line `eiderc:` error
  plus a pointer to `--help`, exit 2 (unknown flags are not silently ignored).
- **Tests** (`scripts/test-compiler.sh`): "unit" (compiler/tests/unit/sha256.ei: the FIPS
  180-4 vectors, the padding edges, 100 KB), "compile-fail", "cache" (hits; the -O level,
  `EIDER_CFLAGS` and the core in the key; concurrency; no work directory left; `off`) and
  "usage".

## C7: recording the oracle

With parity reached (tests/checks 74/74, the compile-fail runner at 42/42 coverage, every
run, wasm, export and thread test), the tests' expected results were recorded and the build
moved to the seed alone ("History"), in three steps.

- **The oracle.** A one-off script recorded, for every input the differential tests compare
  eiderc against, each observable result to
  `tests/oracle/<source path without .ei>.<kind>`: 840 text files, 182 KB. Kinds:
  `.front` (the lex/parse diagnostic of a file, filtered as test-compiler.sh's front end
  does; written only when there is one: 117 files, every other .ei in the repository must
  have none), `.check.json` (`check --json`, `--wasm` for `// mode: wasm` files; 648 with the
  wasm and lib kinds), `.run`/`.test` (stdout, `--- stderr`, stderr, `--- exit <code>`; not
  for the regressions of deliberately fixed bugs, which keep their hand-written `X.out`), `.check-lib.json`,
  `.emit-header`, `.check-wasm.json`, `.emit-header-wasm`, `.node`/`.d.ts`/`.js` (the wasm
  modules of compiler/tests/wasm: node output and the files `build --wasm` writes), and
  `<dir>.compile-fail` (the runner's output for compiler/tests/check, compiler/tests/suite
  and tests/checks, then `--- exit <code>`). The checkout's absolute path (in one E0808
  message) is written `<root>`, and the tests write eiderc's output the same way before
  comparing.
- **The tests read it.** `scripts/test-compiler.sh` and `compiler/tests/wasm/run.sh` compare
  with the oracle (same commands, same comparisons, same in-scope rules as the live
  differential tests they replaced, which the whole script was checked against before the
  switch), so the tests kept their strength. A compiler/tests/wasm
  file whose first line is `// oracle differs: <why>` (long.ei: the recorded output cut
  lines at 511 bytes) must differ from its recorded node output, and is checked against its
  hand-written `X.out`. **`BLESS=1 sh scripts/test-compiler.sh`** rewrites every oracle file
  (and the lex/parse/IR goldens) from eiderc's output: that is how expected behaviour changes
  from now on, after reviewing the diff (`git diff tests/oracle`). It never rewrites a
  hand-written `X.out` or an `oracle differs` file's `.node`.
- **Everything builds with eiderc.** `scripts/ei` builds `target/eiderc` from
  `seed/eiderc.c` with `$CC` when it is missing or older than the seed or anything in
  `core/`, then runs it; eiderc links the C core itself (the old `-l eider_core` archive and
  `LIBRARY_PATH` are gone). Every runner (tests/run.sh, tests/export/run.sh,
  tests/wasm/run.sh, tests/std, tests/packages.sh, tests/pkg, scripts/eider-pkg) uses it;
  the first three still take `EIDER=<binary>`. `scripts/test-compiler.sh` tests
  `target/eiderc-next`, `compiler/` built by the seed (or `EIDERC=`), so a compiler
  change is tested before the seed is regenerated. `scripts/selfhost.sh` starts the chain
  from the seed ("Bootstrap chain"). `scripts/verify.sh`'s compile-fail leg is
  `eiderc test --compile-fail tests/checks`.
- **The fuzzer** (`packages/fuzz`, `scripts/fuzz-check.sh`) needed a second compiler. The
  previous seed is no independent oracle (it is the same source until the compiler changes),
  so the fuzzer became a crash and consistency fuzzer that needs none: per mutant, `check
  --json` ends in 30 s with exit 0 and no output or exit 1 and one diagnostic, nothing on
  stderr; `emit-c` succeeds exactly when `check` does and fails with the same code; a program
  `check` accepts builds (unless it declares an `extern "c"` fn, which may name a symbol
  nothing defines); and the built program, run for up to 10 s, is not killed by a signal
  (SIGSEGV is counted apart: unbounded recursion overflows the stack, which has no guard
  yet). The differential half stays as a regression check: `check --json` must equal a
  reference compiler's, by default `target/eiderc` (the seed), so after a compiler change
  every diagnostic the change moves shows up (`REF=none` turns it off). 2,000 semantic
  mutants (SEED 1 and 3) and 1,000 wild ones (SEED 7) pass; its first run found only
  programs with undefined externs, which led to the `extern` rule.

## IDE analysis (`ide.ei`)

`ide.analyze(entry, overlay_paths, overlay_texts)` is the API a language server
(eider-analyzer, which imports `deps/eiderc/ide.ei` through a path dependency on
`compiler/`) builds on; the contract is at the top of `ide.ei`. It runs the passes of
`eiderc check` and returns the diagnostic `check` reports, plus symbols, refs (use ->
symbol) and types gathered, also after errors (every diagnostic `check` reports, "Several
errors"). `eiderc ide <file.ei>
[--overlay <path> <text>]` prints the result for the goldens in `compiler/tests/ide`.

- **No second resolver.** Symbols come from the ASTs of every module that parsed
  (`resolve.load_from` returns the program without the imports that failed). Refs and types are
  what the checker computed: with `C.rec.on` (only `check.check_ide`) it notes each
  resolved use (node position -> declaration position) and the types of bindings and of
  identifiers, fields, calls and method calls ("IDE recording" in check.ei). Off, a note
  is one bool test and nothing else reads the recording, so check, build and the C are
  unchanged. Module refs (import paths and aliases, `alias.` qualifiers) come from the
  ASTs and `Module.aliases`.
- **Overlays.** `resolve.load_from` reads sources through `resolve.Files`: fs.read, except
  for files whose canonical path is an overlay's (`resolve.disk()` has none). Module
  identity (canonical paths, stems) is unchanged.
- **Never exits.** Comptime constants are evaluated as in `check`; where the driver would
  exit (no toolchain, no work directory) `analyze` reports a `toolchain` diagnostic instead
  (`driver.find_root`, `driver.try_work_dir`).
- **Cost.** `eiderc ide compiler/main.ei` (the whole compiler, 27 files) takes about 0.25 s
  against 0.16 s for `check`.

## Front-end recovery

The lexer and parser can go on after an error, so every syntax error of a file can be
reported at once. The first-error APIs are unchanged: `lex.lex` and `parse.parse` report the
same error, at the same position, as before (`parse.parse` is now `parse_all` returning its
first diagnostic).

- **`lex.lex_all(src, inout names) -> Lexed2`** (`{ lexed: Lexed, diags: List[diag.Diag] }`)
  never stops. A bad character is reported and skipped (a run of adjacent ones once); an
  unterminated string ends at the end of its line; an unknown escape is reported and dropped
  (one error per string literal); an unterminated block comment runs to the end of the file;
  a too-large literal lexes as 0 with `big` set, `0x` with no digits as 0. `lex` and
  `lex_all` share one scanner (`run`), which `lex` stops at the first error.
- **`parse.parse_all(lx, names) -> Parsed`** (`{ p: P, diags: List[diag.Diag] }`) never
  stops. Errors still unwind with `?` to the nearest recovery point: a statement of a
  block, an arm of a match, or an item. There the error is recorded, the nodes the failed
  part added are dropped (the arena keeps no unreachable nodes), tokens are skipped to a
  resynchronisation point and an error node takes the part's place: `SError` for a
  statement, an `Arm` with no patterns and an `EError` body for an arm, `IError` (with the
  item's keyword and name when they parsed) for an item (ast.ei). A statement resumes after
  the next newline or `;` at its own bracket depth (tracked as a stack, so a stray `)` is
  passed over), or at a statement keyword starting a line outside any `{`; an arm after the
  next newline or `,`; both stop at the `}` that closes their block or match. An item
  resumes at the next token that starts an item (`fn` before a name, `unsafe` before `fn`,
  `type const trait impl import test pub extern export module`) at depth 0, or in column 1
  at the start of a line past unbalanced brackets. A token starting an item at the start of
  a line also ends every block and match being skipped through, so after an unclosed brace
  the next item parses as an item.
- **No cascades.** No two errors at one position (`note`); skipped tokens are never parsed,
  so they report nothing. `front.merge` drops a parser error that a lexer error explains:
  on the line of a lexer error, at or after it, or anywhere after an unterminated block
  comment.
- **`front.ei`**: `analyze(src)` runs both and returns the parse and the diagnostics (the
  lexer's, then the parser's, so the first is the one `eiderc check` reports today);
  `report(file, src)` prints them as JSON lines, then the AST dump: `eiderc parse
  --all-errors <file>` (exit 1 when there is an error). `eiderc check` and the other
  commands, `resolve.load_from` for imports and `ide.analyze` use the recovered tree, so
  checking goes on after syntax errors ("Several errors").
- **Tests.** scripts/test-compiler.sh's `recover` section: compiler/tests/recover/*.src
  (several independent errors each; `.src`, not `.ei`, so the front-end loop and the oracle
  don't see them) against their `.recover` goldens (BLESS=1 rewrites them), and for every
  `.ei` in the repository the first diagnostic of `front.report` equals `eiderc parse
  --json`'s error, and without one the dump is `eiderc parse`'s.

## Several errors

A run reports every independent error, not only the first. The rule that keeps this
honest: the first diagnostic of every program is byte for byte the one a compiler stopping
at the first error reports (code, position, message, help, fix), because nothing changes
until an error has been found; the passes only go on afterwards, and what they find is
appended in the order found. The compile-fail runner (suite.ei) still judges a file by its
first diagnostic, so its output, tests/checks' 74/74 and the 42/42 coverage are unchanged.

- **Syntax errors** ("Front-end recovery"). The entry file and every import are lexed and
  parsed with `lex_all`/`parse_all` (their diagnostics first, `front.merge`), and the
  recovered tree is loaded and checked. Error nodes are skipped without a report: `EError`
  has the error type, `SError` is no statement (and a block containing one has the error
  type, since it may have lost its last expression), an arm without patterns keeps its
  match from being judged. Nothing the checker finds on the line of a syntax error is
  reported (the parser may have misread it), nor are a missing return value or a match's
  exhaustiveness in a body or match with a syntax error, nor an unknown name in a body
  with a syntax error or a skipped statement, in a module where an item was skipped before its name, or when it is the name
  of a skipped item (`IError`'s b), nor a missing `main` or export when an entry item was
  skipped.
- **Loading** (`resolve.load_from` -> `Loaded { p, diags, fatal }`). An import that can't be
  read, or that clashes with another module's name (E0804, E0808), is
  reported and left out, and loading goes on; its prefix goes into `Program.broken`, and a
  diagnostic naming `alias.X` of such a module is a consequence (never reported). Only a
  missing prelude is fatal.
- **Comptime** (`comptime.eval_all`). A constant whose evaluation fails is reported (the
  evaluator's first diagnostic) and its `comptime` flag becomes 2: check.ei makes it a
  constant of the error type, so its uses are silent; the next constants are still
  evaluated. An error elsewhere in the program found by an evaluator is found again by the
  checker; the copy is dropped (`diag.dedup`: same code, file, position and message).
- **Checking** (check.ei, "Recovery"; `check.check_all` -> `Checked { c, diags }`, with
  `check_mode`/`check_wasm` giving the first). An error is an `Err` that stops at the
  nearest recovery point instead of ending the run: there it is recorded (naming the file
  the end of the run would name) and checking resumes with the state from before the
  failed part. Recovery points: every expression (`expr`: the failed expression stands for
  a value of the error type), every statement (a failed `let` still binds its names, to the
  error type), every function and test body, every item of each pass, every field of a
  type and every part of a signature (a field, parameter or return type that doesn't
  resolve is the error type; an unknown capability is left out). Some errors are recorded
  where they are found and checking goes on as if they weren't there: a missing capability,
  a missing `unsafe`, assigning to or borrowing something immutable, a private item (used
  as if visible), a call to an unknown or misused function or method (its arguments are
  still checked), a duplicate definition (the first is used), an impl's mismatches (its
  methods are still registered).
- **No cascades.** The error type (`types.poison`, shown `{error}`, interned on first use so
  a program without errors never has it and lowering never sees it) is compatible with
  every type (`same`), and every operation on it gives it again silently: operators, fields,
  indexing, methods, calls (no instance of a generic function is made for it, nothing is
  inferred from it), conditions, loops over it (the body is checked with an error-typed
  variable), matches (its patterns bind error-typed names and the match isn't judged for
  reachability or exhaustiveness), `?`, casts, closures where an error value is expected.
  A diagnostic that still mentions `{error}` is a consequence and is dropped, as are the
  `cascade` diagnostics produced where only a consequence is known. An "unknown ..." name
  and a missing capability (one fix) are reported once per body; a generic body is
  reported for its first instance with errors only. `unsupported` still ends checking and is
  reported only when nothing else was. A failed statement that ends a block makes its type
  the error type, so "must return" doesn't follow a failed `return`.
- **Output** (main.ei `fail`). Human: each diagnostic rendered as before, then
  `error: N errors` (one line, stderr). `--json`: one JSON object per line (JSON Lines), the
  first line the single line of a first-error compiler. At most `--max-errors N`
  diagnostics (default 100, 0: all); when some are left out a final note says so
  (`note: only the first 100 of 250 errors are shown; ...` on stderr, or a
  `{"note":"..."}` line with --json). Exit codes are unchanged (1), and nothing is lowered or
  built after an error. `ide.analyze` returns every diagnostic (no cap), and the IDE
  recording goes on after errors.
- **Tests.** The oracle (tests/oracle, `BLESS=1`) gained lines only after the first: for
  every changed file the recorded text is a prefix of the new one. compiler/tests/check/multi
  holds programs with several errors (across functions, unknown names used repeatedly, an
  error value used in later statements, errors after resolution errors, items, generics,
  comptime, the `--max-errors` cap); `scripts/test-compiler.sh` compares everything `check
  --json` and `check` print for them with the oracle (X.check.json, X.check.err). The
  fuzzer holds every line of `check --json` to be a diagnostic, none repeated, and only the
  first line to equal the reference compiler's.

## C8 candidates: parity quirks to fix deliberately

eiderc keeps these behaviours for compatibility with the recorded expectations in
`tests/oracle/`. Each can
now be fixed on purpose: change the compiler, regenerate the expectations with `BLESS=1`,
review the oracle diff, add a test, and regenerate the seed.

- Checker: `Enum.Variant` is E0114 for an enum of an imported module, or inside one; errors in
  an imported module's test blocks, and E0801 for a private field type checked while
  constructing from another module, name the wrong file, and that E0801 is checked against
  the constructing module; in a module's test block a local named like one of the module's
  items is shadowed by the item; `x /= 0` is not a compile error although `x / 0` is
  ("C3: checking").
- Checker (S1–S3): a name in an impl target that isn't a type parameter matches every type
  (`impl Area for Sq` meets `T: Area` for any T; `impl W[i32]`'s methods apply to every `W`);
  registering an impl replaces `Self` textually, also inside `MySelf`; impls on fn types never
  match a receiver (`compiler/tests/check/fail/e0115_quirk_bound_name_target.ei`).
- Comptime: an evaluator lacks every comptime constant not yet evaluated, so a plain `const`
  naming a comptime constant always fails (E0110) and so does any function naming a later
  one; any error in the rest of the program is found by the first evaluator, and an E0201
  there loses its fix; traps during evaluation name the file `program` ("C7: comptime").
- Lowering: an imported module's unit enum prints its mangled name (`geo__South`); trap
  messages always name the entry file, even for a trap in an imported module ("C4:
  lowering").
- Threads: `contains` on a List of handles compares them as equal ("C7: threads").
- Library header: every header has the include guard `EIDER_EXPORTS_H`, so two libraries'
  headers can't be included together (compiler/tests/export/consumer.c declares by hand);
  header type names keep the recorded spelling (`R_<mangled name>`, "C7: FFI").
- WebAssembly loader (kept byte-identical to `tests/oracle/compiler/tests/wasm/*.js`,
  core/wasm/README.md): an export
  parameter named `x` shadows the loader's `const x = inst.exports`, so calling that export
  breaks; `u32` results above the signed range come back as negative numbers and
  `u64`/`usize` results as negative BigInts, because the loader passes the raw wasm values
  through.
- Runtime: `ei_now_ms` is processor time (`clock()`), not a wall clock (core/RUNTIME.md).
- Answered `unsupported` where the recorded behaviour is wrong, waiting for a language
  decision: `?` in an expression-bodied closure (recorded: checked against the enclosing
  function's return type), and an `extern "c"` or `unsafe fn` used as a function value
  (recorded: accepted with neither `unsafe` nor `uses ffi`).

## C4: lowering

`lower.ei` turns the IR into one C11 file; `driver.ei` compiles and runs it.

- **One C statement per IR statement.** The IR already fixes evaluation order, so lowering
  never hoists or reorders. Bounds checks are separate statements before the statement that
  uses a place (`(void)ei_idx(i, n, line);`, outermost index first), so nested indices check
  left to right. Every trapping operation calls the runtime (`ei_add_i32(a, b, line)`,
  `ei_s2u(...)`, `ei_trap(msg, line)`); the generated C defines no runtime functions of its
  own, only per-type glue (since C5: generated once per type and only when used; see
  "C5: lowering").
- **Names** cannot collide with each other, C keywords, reserved identifiers or the runtime
  (`ei_*`, `ec_*`), and since C5 depend only on what they name ("C5: lowering", "Stable
  names"; at C4 they were arena indexes, `t<id>_`/`f<i>_`). Locals are `l<i>[_<name>]` for
  local `i` of the current function (parameters first), `s<n>` is a loop's `continue` label.
  Members are `f<n>` (fields) and `v<n>` (variant structs).
- **Layout.** Records are structs; arrays are `struct { T a[N]; }` so they copy by value;
  every enum is `struct { uint32_t tag; union { struct { ... } v<n>; ... } u; }` (no union
  when no variant has fields); `str` is `const char *`; `bool` is C `bool`; integers are the
  `<stdint.h>` types (`usize` = `uint64_t`); `inout` parameters are pointers. Every struct
  type is forward-declared, then defined after the types it contains by value. Every local is declared at the top of its function with a zero
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
  `\n<n> tests, <k> failed`, exit 1 if any failed (the recorded format).
- **Driver.** `emit-c <f> [--test]` prints the C; `build <f> [-o out]` writes an -O2
  executable (default: the source's stem in the working directory); `run <f> [--release]`
  (-O0, or -O2) and `test <f>` (-O0) build in a fresh work directory (since C7 under the
  cache or `target/`, see "C7: driver"), run the program with inherited stdio, remove the
  directory and exit with the program's code. The C is compiled with `$CC` (default `cc`),
  `-pthread`, extra flags from `$EIDER_CFLAGS` (split at spaces), and linked with the C core
  (`core/eider_rt.c` and `core/eider_core.c`, since C7 as cached objects). If it does not compile, the
  C is kept and eiderc exits 3. **Toolchain root** (the directory holding `core/`):
  `$EIDER_ROOT`, else the nearest directory above the eiderc binary (argv[0], symlinks
  resolved) that contains `core/eider_rt.h`, else the same search from the working
  directory. That needs no build-time configuration: `target/eiderc` in a checkout finds the
  checkout, and an installed eiderc needs `EIDER_ROOT` (or a `core/` above it).
- **Tests** (`scripts/test-compiler.sh`, "run" and "sanitize"): every in-scope program in
  tests/run and compiler/tests/run (19 of 27 at C4, 31 of 34 since C5) must match the
  recorded stdout, stderr and exit code under `run`, and under `test` when it has test
  blocks, with `-Werror`; then again at `-O2 -Werror` under UBSan in trap mode. eiderc's
  own run tests cover every operator per int type with every trap and the wrapping edges
  (`arith.ei`, `traps.ei` with 109 trapping test blocks, `limits.ei`), evaluation order,
  payload-enum matches, `inout`, constants, modules, control flow, test blocks, and traps
  in `run` (stderr, exit 101).
- **Deliberate fixes**: the bugs in LEARNINGS.md are fixed and
  have regression tests with hand-written expected output (`compiler/tests/run/bug_*.ei` +
  `.out`): `len(e)` evaluates `e`; `let p = match r { V(p) => p }` assigns `p`; `else if`
  conditions with temporaries; `??(` in strings
  stays `??(`. A program killed by a signal makes `eiderc run` exit 128 + signal (not 1);
  `build` without `-o` writes to the working directory (not to a temporary directory); the binary cache keys with SHA-256 over more inputs and lives in subdirectories
  of the cache directory ("C7: driver"); driver messages start with `eiderc:`. Kept for compatibility with the recorded expectations: an imported module's unit enum prints its mangled name
  (`geo__South`), and trap messages always name the entry file, even for a trap in an
  imported module.

## Compile speed

Measured 2026-10-30 (16 cores, gcc, one run each). The front end is cheap: about 1 ms per 100
lines for lex+parse+check+emit (a 527-line program checks in 4 ms; parsing the 2,026-line
check.ei takes 17 ms). End to end the C compiler dominates: building eiderc itself (7.5k lines
of Eider -> 17.4k lines of C) is 0.23 s front end + ~5 s gcc -O2 (1.2 s at -O0); `eiderc
build` of a 76-line program takes 313 ms (with the core compiled into every program; see below).

Since C8.1 (copy-on-write, measured 2026-10-30 with `scripts/bench.sh`): eiderc's own front
end and lowering (`emit-c compiler/main.ei`, 16.6k lines of Eider -> 105k lines of C) take
144 ms instead of 212 ms, a third less: every copy the checker places (an S_CLONE of a
String, List, Map or Box, or of a record holding them) used to be deep and is now a count
increment. gcc still dominates a build of eiderc.

Core objects and the binary cache (C7, "C7: driver"), measured 2026-10-30 on
`tests/run/adt.ei` (84 lines; 16 cores, gcc; each the median of 4 runs, wall clock):

| | `eiderc build` (-O2) | `eiderc run` (-O0) |
|---|---|---|
| before (core sources compiled into every program; = `EIDER_CACHE=off` now) | 0.31 s | 0.14 s |
| after, first ever (empty cache: also compiles and caches the core) | 0.34 s | 0.16 s |
| after, program changed (core objects cached, program not) | 0.07 s | 0.06 s |
| after, program unchanged (binary cache hit: no cc) | 0.01 s | 0.01 s |

So the core was ~80% of a small build; with it cached, a small program's edit-and-build
loop takes ~0.06 s. A hit costs one `cc --version` (part of the key) and hashing the generated C
and the core sources (sha256.ei at -O2: ~40 ms per MB; a small program's C is ~100 KB).

### Constraints to keep now (cheap today, expensive to retrofit)

1. **Stable C names** (done in C5 lowering). Generated names must depend only on what they
   name (module identity, symbol, and for instances the type arguments), never on arena
   indexes or declaration order, or editing one module renames symbols everywhere: that
   defeats per-module caching, parallel translation units and readable diffs of generated
   C, and makes the self-host fixed point fragile. See "C5: lowering", "Stable names"; the
   clash check stays.
2. **Deterministic output** (done; tested by "determinism" in test-compiler.sh). Same
   input, byte-identical C (no hash-map iteration order, no temp paths or timestamps in the
   C). Needed for caching and the fixed point.
3. **Per-module boundaries in lowering** (done). Each module's functions are emitted as a
   unit, per-type glue and generic instances in one place keyed by stable name, so the
   output can later be split into one C file per module (plus one for shared glue) compiled
   in parallel. Don't let lowering interleave modules arbitrarily. (Type definitions are one
   shared section too.)
4. **The IR stays the only input to lowering**, so a second back end (a fast non-C debug
   path) can be added without touching check.

### Optimisations to do later (no architectural impact)

| What | Expected effect |
|---|---|
| ✅ (C7) Build `core/eider_rt.c` and `core/eider_core.c` once per (CC, flags) and link the cached objects | measured above: build 0.31 s -> 0.07 s, run 0.14 s -> 0.06 s |
| ✅ (C7) Binary cache keyed on (generated C, CC, flags, core objects), controlled by `EIDER_CACHE` | unchanged programs skip gcc: 0.01 s |
| Smaller C: declare temporaries in the narrowest scope that still avoids `-Wmaybe-uninitialized`; share glue between identical layouts (only used glue is emitted since C5); eiderc's own C is 74k lines | less C for gcc, whose time is roughly linear in it |
| One C file per module, compiled in parallel (needs constraint 3) | uses the idle cores; most of the gcc time for large programs |
| -O0 for the edit/run loop by default (already), -O2 only for `build` | 4x faster gcc on large programs |
| Incremental front end: cache per-module check results keyed by source hash and the interfaces of imports | matters once programs are large; the front end is not the bottleneck today |
| A direct debug back end (no C compiler in the loop) | edit/run latency independent of gcc |

## C8 plan: the backlog

Goal: the easiest, most secure and most performant language for systems, services and general
development (docs/design/memory-model.md is the charter for the memory model). Work runs in
waves. Within a wave, items touch different files and run in parallel; a wave starts when the
previous one is merged, the seed regenerated and `scripts/verify.sh` is ALL GREEN.

Rules for every item: diagnostics keep the first-error contract; oracle changes only through
reviewed `BLESS=1` runs with the diff explained; no item commits `seed/eiderc.c` (the seed is
regenerated once per wave after the merge); `compiler/` uses a new feature only after the
seed that supports it is committed; each item adds compile-fail and run tests, a docs section,
and leaves the analyzer building.

| Wave | Item | Scope | Depends on |
|---|---|---|---|
| 1 | **8.1 Copy-on-write** | heap types share buffers with a refcount, copy on first write; non-atomic counts, values made unique before they cross threads; drops once at the last holder; quadratic `String` append fixed (capacity) | — |
| 1 | **8.2 Small language gaps** | bitwise operators `& \| ^ << >> ~` (checked shifts); `String`/`str` byte access, slicing, building from bytes; `()` values (`Ok(())`); `main` returning an exit code; `impl` on built-in types | — |
| 1 | **8.3 Package-qualified modules** | module identity = (package, path) instead of file stem (no more E0808 for two packages' `util.ei`); bare `import "json"` resolved through `eider.lock`; the `deps/` link farm retired | — |
| 2 | **8.4 Operation traits** | `Copy`, `Eq`, `Ord`, `Hash`, `Show`, `Iter`, `Drop` in the core prelude; automatic derive; orphan rule; generic bounds with suggested fixes; Map keys any `Hash + Eq`; `for` over any `Iter` | 8.1, 8.2 |
| 2 | **8.5 Capability encapsulation** | `ffi` becomes a property of a package (granted in eider.toml); std callers stop writing `uses ffi`; the compiler reports each package's real capability use and eider-pkg checks grants from that instead of scanning text | 8.3 |
| 3 | **8.6 References by default** | `let` binds a read-only reference to a place, `let mut` a mutable alias, fresh values are owned; `.copy()`; pattern bindings the same; the protection rule (no invalidating write while a reference is alive) with fixes; references are C pointers; `var` deprecated with a mechanical fix | 8.1, 8.4 |
| 3 | **8.7 `Ref[T]`** | shared mutable handle with scoped `read`/`update`, run-time conflict check, not sendable | 8.4 |
| 4 | **8.8 Closures by reference** | non-escaping closures capture by reference | 8.6 |
| 4 | **8.9 Std on the new base** | std speaks `String`, uses traits and references; `List[u8]` workarounds and `sys.lit` byte loops go; std callers need no `uses ffi` | 8.2, 8.4, 8.5, 8.6 |
| 4 | **8.10 Parity quirks** | fix each item in "C8 candidates" deliberately (wasm loader bugs, checker quirks), re-blessing the oracle per item | — |
| 5 | **8.11 Comptime interpreter** | evaluate `comptime` by interpreting the IR: no C compiler at compile time, no capabilities by construction | — |
| 5 | **8.12 Performance** | smaller generated C, one C file per module compiled in parallel, incremental front end keyed by module hash | 8.3 |
| 5 | **8.13 Tooling** | `eiderc fmt` (formatter); analyzer: rename, workspace symbols, signature help, inlay hints, formatting; tree-sitter grammar generated from the compiler grammar | 8.9 |
| 5 | **8.14 Package manager on bare imports** | eider-pkg reworked for 8.3/8.5 (no link farm, compiler-reported grants), registry design | 8.3, 8.5 |
| later | 8.15 Projections, lints | std accessors returning references; lints for real copies at escapes and `Ref` cycles | 8.6, 8.7 |

## C8.1: copy-on-write

`String`, `List[T]`, `Map[K, V]` and `Box[T]` share their heap buffer between copies
(docs/design/memory-model.md, "Copy-on-write values"). Semantics are unchanged: values are
still values, and every test and oracle file behaves byte for byte as before. The checker
already decided every clone, move and drop (ir.ei, "Ownership"); only what they cost changed.

- **Layout.** The core's shared buffer (core/RUNTIME.md, "Shared buffers"): a 16-byte header
  `{ uint64_t n; uint64_t unused; }` (the count of holders) before the data, and values point
  at the data, so a NULL pointer is the empty buffer. The value layouts are the same as before
  except String, which gains a capacity: `ei_String { char *p; uint64_t len, cap; }`. The
  buffers are the String bytes, a List's `d`, a Box's `p`, and a Map's three arrays, counted
  together on the slot states `s` (the keys and values are freed with it).
- **Clone, drop, write.** A clone (S_CLONE, and so every copy inside a record, enum, tuple,
  array, closure environment) is `ei_buf_inc` / `ei_share_String`: O(1). A drop is
  `ei_buf_dec`; the last holder drops the elements once and frees. A write makes the buffer
  its own first: `uniq_<T>` (List, Map, Box; generated, since copying the elements is per
  type) and `ei_str_unique` copy only when the count is above one, cloning the elements, so
  they in turn share their own buffers, and let go of the shared one. Lowering calls it
  (`uniqs`) for every List and Box on the path to a place that a statement stores to, drops,
  moves out of, passes `inout` (S_CALL/S_CALLV place arguments) or hands to a mutating
  builtin (push, pop, clear, insert, remove, push_str, append), outermost first and after the
  bounds checks: `a.items[i].tags[j] = s` makes `a.items`, then `a.items[i].tags`, unique. The
  place itself is made unique by whatever changes it: `push_`, `ins_`, `rem_` glue,
  `ei_str_cat`, inline `pop`, or the callee's own writes through its `inout` pointer (`clear`
  is a drop, so it needs nothing). Borrows (S_READ) stay bitwise copies; they stay valid
  because a write never frees a buffer another holder still counts, and the checker already
  keeps a place unchanged while a borrow of it is used.
- **Growth.** Every growth is amortised through the core's checked `ei_grow_cap`: String
  appends double the capacity (at least 15 bytes; in place when the buffer is its own and has
  room), which fixes the quadratic `push_str`; List push (doubling from 4, `ei_buf_grow` =
  realloc) and Map rehash (powers of two from 8, so probing is unchanged) as before, now with
  overflow checks. All sizes go through `ei_buf_alloc`/`ei_alloc_n`.
- **Threads: counts are not atomic.** A buffer is reachable from one thread at a time: before
  a value can be seen by another thread, `own_<T>` glue makes every buffer it reaches its own
  (uniq at every level; handles are skipped, since `ei_rc` is atomic and their contents are
  behind their own locks). That is done to `spawn`'s closure (a fn value gained a fifth member,
  `own`, the environment's `eown_<f>`, which owns the captures), the values given to
  `Mutex.new`, `Mutex.set` and `Chan.send`, the result of a `Mutex.update` closure (under the
  lock: it may share with the old value or with the closure's captures), and the copies
  `Mutex.get` hands out (cloned and owned under the lock). `Task.join` may run on several
  threads at once, so a Task whose result owns heap data has a lock of its own (`mu`) and
  each join clones and owns its copy under it. The old value a Mutex replaces then shares
  nothing with the new one, and is dropped after the unlock, as before.

  Why not atomic counts: they need nothing at the crossings, but every clone and drop pays an
  atomic read-modify-write, while crossings are rare and already copied (deeply) before C8.1.
  Measured with the same compiler and the counts made atomic (`__atomic_fetch_add`/
  `__atomic_sub_fetch` in the header; not committed): eiderc's own `emit-c` 149 ms vs 144 ms
  (+3.5%), the benchmarks below unchanged within noise. Making values unique costs only at the
  crossings, where the old deep copies were.
- **Old generated code.** `ei_clone_String` stays a copy with a buffer of its own and the
  copy-on-write glue is all generated, so a program generated by an eiderc from before C8.1
  (the seed until it is regenerated) never shares a buffer and stays correct against this
  core, threads included.
- **Tests.** `compiler/tests/run/cow` (hand-written expected output, also produced by the
  pre-C8.1 compiler): copies of Strings, Lists, Maps, Boxes, records, tuples, Options and
  closure captures changed on either side; a List of Strings shared then one element changed
  in place and replaced; Lists of Lists changed two levels down; a record changed through
  `inout`; Map values replaced, inserted and removed in a copy; pop, clear and push on copies;
  self-append of a shared String; a 20,000-byte String built by appends.
  `compiler/tests/run/cow_threads`: 8 threads capturing one shared List of Strings and changing
  their copies; a Mutex of a List of Strings with `get`/`update`/`set` from 8 threads, with
  update results shared with captures; 4 producers sending values they keep changing; one
  Task joined from 8 threads at once. In the suite (gcc and clang, -O2): 45/45 run tests,
  159/159 sanitizer runs (UBSan, ASan, TSan), 53/53 leak-free. `cow_threads` also ran 20 times
  each under gcc TSan, clang TSan, clang ASan+UBSan, UBSan (trap) and the allocation counter
  with no report, and with the `own_` calls deleted from its C TSan reports races on the
  counts at once (`ei_buf_dec`), so the test does catch a missing crossing. tests/core: the
  buffer primitives, `ei_grow_cap` limits and traps, sharing and unsharing of Strings, and
  100,000 one-byte appends moving the text fewer than 20 times.
- **Benchmarks** (`sh scripts/bench.sh target/eiderc-before:target/before target/eiderc-cow`,
  2026-10-30, 16 cores, gcc -O2, median of 5 runs, wall time; before = eiderc and core at
  a9d1d77, after = eiderc built by itself with C8.1; `tests/bench/`):

  | Benchmark | Before | After |
  |---|---|---|
  | `list_copies`: 3,000 copies of a List of 3,000 Strings, every 500th changed | 691 ms | 3 ms |
  | `state`: a record of a Map (2,000 Strings) and Lists threaded through 20,000 calls by value, 200 snapshots kept | 3,269 ms | 4 ms |
  | `str_append`: a String built by 200,000 `push_str` (was quadratic) | 3,889 ms | 4 ms |
  | eiderc `emit-c compiler/main.ei` (16.6k lines of Eider) | 212 ms | 144 ms |

  The generated C for eiderc grew from 104,523 to 105,023 lines (the `uniq_`/`own_` glue
  and the calls before writes).

## C8.2: small language gaps

Wave 1, item 8.2: five small features the rest of the backlog (std on `String`, traits, the
`sha256` copy) needs. `compiler/` doesn't use any of them until a seed that has them is
committed. Tests: `compiler/tests/run/{bitwise,traps_bits,text_bytes,text_cow,trap_text,trap_push_byte,units,impl_builtin,main_*}.ei`, `compiler/tests/wasm/bits.ei`, the `bitwise` lex/parse/IR goldens, `tests/checks` cases for each new code,
compile-fail cases `e0002_*`, `e0505_*`, `e0506_*`, `e0116_*`, `e0111_main_*` and the new
E0401/E0115/E0303/E0405 cases in `compiler/tests/check/fail`, `c8_*_ok.ei` in
`compiler/tests/check/pass`, and `compiler/tests/check/multi/bitwise.ei`.

- **Bitwise operators** `&` `|` `^` `<<` `>>`, unary `~`, and `&=` `|=` `^=` `<<=` `>>=`, on
  every integer type. As with the other operators both operands have one type (no implicit
  widening, so the shift count has the operand's type too: `x << n` with `x: u64` needs
  `n: u64`; E0401 otherwise), and literals take the other operand's type. `& | ^ ~` act on the
  two's-complement bits and never trap. `>>` is arithmetic on signed types (it copies the
  sign bit, so `-7 >> 1 == -4`) and logical on unsigned ones. `<<` drops the bits shifted out
  and doesn't trap on them: it is an operation on bits, not on numbers (use `*` for a checked
  multiplication by a power of two). A shift count that is negative or not below the type's
  width traps (`shift count out of range`, exit 101), and is E0505 when it is a constant
  (also in `<<=`/`>>=`, unlike the `x /= 0` quirk). Constants fold (fold.ei `bitwise`, written
  with arithmetic because the seed has no bitwise operators); the runtime does the rest
  (`ei_band_N` ... `ei_shr_N`, computed on unsigned types so no C shift or conversion is
  undefined or implementation-defined).
- **Precedence.** From loosest: `||`, `&&`, comparisons, `|`, `^`, `&`, shifts, `+ -`,
  `* / %`, `as`, unary `- ! ~`. Those levels are C's and Rust's, but the bitwise operators
  are not *ranked* against comparisons, arithmetic or each other: an operand of `&`, `|`, `^`,
  `<<` or `>>` can't be an unparenthesized operation of another group, and an operand of a
  comparison can't be an unparenthesized `&`, `|` or `^`. Exceptions, where every language
  agrees: a shift may be an operand of `& | ^` (`x >> 4 & 15`), a comparison may compare
  shifts (`1 << n == m`), and chains of one operator (`a | b | c`, `a << 1 << 2`) are
  fine. So C's trap `a & b == c` (C: `a & (b == c)`), Go's `a + b & c` (Go: `a + (b & c)`)
  and `1 << n - 1` are E0002, a syntax error that names both operators and carries a fix
  adding the parentheses the levels above imply (`(a & b) == c`); E0002 is recorded and
  parsing goes on, since the tree is whole. The lexer knows `& ^ ~ << >> &= |= ^= <<= >>=`;
  `&&`, `||` and `|` keep their meaning (`|` starts a closure in an operand position and
  separates patterns in a match arm; as an operator it only appears between operands).
- **Bytes of text.** `String` and `str` both have `len() -> usize` (`len(x)` too),
  `is_empty()`, `byte(i: usize) -> u8` (`index out of bounds` past the end), `slice(a: usize,
  b: usize) -> String` (byte offsets; traps `slice out of bounds` unless `a <= b <= len`, and
  `slice not on a character boundary` if `a` or `b` falls inside a UTF-8 sequence) and
  `bytes() -> List[u8]`; `String` also has `push_byte(b: u8)` and `String.from_bytes(bytes:
  List[u8]) -> Result[String, usize]`. `<`, `<=`, `>` and `>=` compare two Strings or two
  strs by their bytes, which for UTF-8 is Unicode scalar order. **A String is always valid
  UTF-8 and has no NUL byte** (the runtime ends it with one, and `==`, hashing and `print`
  rely on that): `from_bytes` checks the bytes (RFC 3629: no overlong forms, surrogates or
  values past U+10FFFF) and its Err is the offset of the first byte that isn't valid or is
  NUL; `slice` cuts only at character boundaries; `push_byte` appends only ASCII (1 to 127;
  anything else traps `push_byte needs an ASCII byte (1 to 127)`, and is E0506 when it is a
  constant), since a lone byte of a longer sequence would leave the String invalid; longer
  text goes in with `push_str`, `append` or `from_bytes`. `str.slice` returns a `String`, not
  a `str` view: a `str` is a NUL-terminated C string (`const char *`), which has no room for
  a length, so a view could only be a suffix; an owned copy is what both types can give,
  and when references land (8.6) `String.slice` can become a view. On a `str`, `len`, `byte`
  and `slice` find its end first (O(n), `strlen`); convert to a `String` (or take `bytes()`)
  once before a loop over a long `str`. Lowering: builtins B_STR_BYTE, B_STR_SLICE,
  B_STR_BYTES, B_STR_FROM_BYTES, B_STR_PUSH_BYTE (ir.ei, "Bytes of text"), calling
  `ei_str_byte`, `ei_str_slice`, `ei_utf8_check` + `ei_str_from_n` and `ei_str_push_byte`
  (core/RUNTIME.md) and glue `bytes_<List[u8]>` and `utf8_<Result>`.
- **Unit values.** `()` is an expression (the unit value) and a pattern (matching it; it is
  irrefutable), so `Ok(())`, `Some(())`, `Result[(), E]` with `?`, `match r { Ok(()) => ... }`
  and `return ()` (the same as `return`) work. In the tree `()` is an empty ETuple/PTuple.
  The other rules about `()` are unchanged: a `let` can't bind it, a parameter or tuple
  element can't have type `()`.
- **`main`'s result.** `main` takes no parameters and returns `()`, `i32` or `Result[(), E]`
  for any `E` (anything else is E0111, now reported where the signature is resolved). With
  `()` the program exits 0 (as before). An `i32` is the exit code: the generated C `main`
  returns it after the leak check; outside 0..255 it traps `exit code out of range` at
  `main`'s line (exit 101), because the OS keeps only the low byte and 256 would read as
  success. With `Result[(), E]`, `Ok(())` exits 0; an `Err(e)` flushes stdout, prints
  `error: <e>` to stderr when `E` is printable by `print` (an integer, `bool`, `str`, `String`
  or an enum without payloads; its variant name), else `error: main returned Err`, drops the
  Result, and exits 1. Traps still exit 101 and `eiderc run` passes every exit code on.
- **`impl` on built-in types**: `impl String`, `impl str`, `impl i32` (any integer), `impl
  bool`, `impl[T] List[T]`, `impl Map[K, V]`, `impl Box[T]`, `impl Mutex[T]` and so on, with
  methods, associated functions (`String.make()`, `str.greet()`) and trait impls (`impl Show
  for String`, so a String meets `T: Show`). A method call on a built-in type looks for the
  built-in method first and then for impls; a method or associated function in such an impl
  that has a built-in one's name (`len` on String, `new` on List, `from_bytes` on String) is
  E0116, since it could never be called. Handles (Task, Mutex, Chan) used to ignore impls;
  they now follow the same rule. Before this, `impl String` was accepted but its methods
  were never found (E0115 at the call).
- **Codes**: E0002 (bitwise operators mixed without parentheses, with a fix), E0116 (an impl
  method named like a built-in one), E0505 (a constant shift count out of range), E0506
  (`push_byte` of a constant that isn't ASCII); E0111's message now lists `main`'s results.
- **Syntax changes** (for the tree-sitter grammar): new tokens `&`, `^`, `~`, `<<`, `>>`,
  `&=`, `|=`, `^=`, `<<=`, `>>=`; binary `|` `^` `&` `<<` `>>` at the levels above, between
  comparisons and `+ -`; prefix `~` with `-` and `!`; the compound assignments with the
  others; `()` as an expression and a pattern.

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
| C1 ✅ | `lex`, `intern`, `diag`; `eiderc lex` dumps tokens | every `.ei` in the repo plus `compiler/tests/lex` agrees with the oracle on lexer errors (JSON); golden dump in `compiler/tests/lex_ok` |
| C2 ✅ | `parse` to the AST arena; `eiderc parse` dumps the AST | every `.ei` in the repo parses; parse errors (E0001) match the recorded positions, including the one-file-per-error-path corpus in `compiler/tests/parse`; golden dumps in `compiler/tests/parse_ok` |
| C3 ✅ | `resolve` + `check` for the v0 language (ints, bool, str, records, enums, arrays, control flow, `inout`, capabilities, const folding), producing the typed IR (`eiderc ir`) | v0 compile-fail and compile-pass tests match |
| C4 ✅ | `lower` + C for v0 (plus non-generic payload enums) against `core/eider_rt.*`; driver (`emit-c`, `build`, `run`, `test`) | v0 run tests match (stdout, stderr, exit code, for `run` and `test`); C is `-pedantic -Wall -Wextra -Werror` clean at -O0 and -O2 and clean under UBSan (ASan/TSan when their runtimes exist) |
| C5 ✅ | S1–S3: payload enums, generics, traits, Option/Result/`?`, tuples, patterns, String/List/Map/Box, closures | all the features `compiler/` itself uses; their tests match (checking ✅, lowering ✅) |
| C6 ✅ | Self-host: stage1 builds stage2 builds stage3; fixed point; commit the seed | `scripts/selfhost.sh` green (stages compile `-Werror`, stage3 passes `scripts/test-compiler.sh`), `scripts/selfhost.sh --from-seed` reproduces the seed with only a C compiler |
| C7 ✅ | Parity: modules/namespaces, FFI/export/`--lib`, threads, WASM, comptime, driver (`test --compile-fail`, cache, `--help`); then record the oracle in `tests/oracle/` and build everything from the seed ("History") | in a clean clone with only a C toolchain `verify.sh` ends ALL GREEN and `selfhost.sh` prints SELF-HOSTED |
| C8+ | See "C8 plan: the backlog" (waves 1–5). Language work above, the parity quirks in "C8 candidates", then std and package-manager rework; comptime by an IR interpreter instead of a C compiler ("C7: comptime") | per feature |

## Testing

- Golden dumps per pass (`lex`, `parse`, `ir`), regenerated with a bless flag and
  reviewed in diffs.
- Differential testing against the recorded oracle: the observable behaviour (diagnostics,
  stdout, stderr, exit code, headers, wasm loaders) of every program in the suites must match
  `tests/oracle/` ("C7: recording the oracle"). Expected
  behaviour changes only through `BLESS=1 sh scripts/test-compiler.sh` and a reviewed diff.
- Unit tests in Eider `test` blocks inside `compiler/`.
- Fixed-point check in `scripts/selfhost.sh`.
- Deliberately fixed bugs (listed in `LEARNINGS.md`) each have a run test in eiderc's suite
  with hand-written expected output, so the compiler is held to the correct behaviour rather
  than the recorded one.
- `scripts/fuzz-check.sh`: crash and consistency fuzzing, plus `check --json` against the seed.
- Generated C compiled with `-Wall -Wextra -pedantic` and run under ASan/UBSan/TSan in CI.
  `eiderc`'s C must not trip `-Wmaybe-uninitialized` at `-O2`.

## Layout

```
compiler/
  eider.toml          package `eiderc`
  main.ei             CLI (`eiderc --help`)
  source.ei  lex.ei  intern.ei  ast.ei  parse.ei  resolve.ei  types.ei  fold.ei  pats.ei
  check.ei  ir.ei  lower.ei  emit.ei  diag.ei  driver.ei  comptime.ei  suite.ei  sha256.ei
  ide.ei              the IDE analysis API (`eiderc ide`; "IDE analysis")
  front.ei            every syntax error at once ("Front-end recovery")
  tests/              pass-level golden tests (lex, lex_ok, check, ir, run, wasm, export, ide, ...)
tests/oracle/         the recorded expected results (scripts/test-compiler.sh, BLESS=1)
```

`compiler/` depends on `core` and `std` only.
