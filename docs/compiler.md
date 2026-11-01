# The self-hosted compiler (`eiderc`)

Status: C1 to C7 done: eiderc is self-hosted (since #127 the seed is `seed/eiderc.wasm`, the compiler as WebAssembly, with the translator `seed/wasm2c.c`), its observable behaviour is recorded in `tests/oracle/` ("C7: recording the oracle"), and the compiler builds from the seed with only a C compiler ("Bootstrap chain"). Next is C8 (the language work and the parity quirks listed in "C8 candidates"). This file owns the plan; update it as stages land.

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
the C core (`core/`) and building the compiler from nothing needs only a C11 compiler. Done at
C7; since #127 that path goes through a WebAssembly seed, and building programs needs clang
17+ (U23, U24).

Non-goals for the first version were a new back end (it emitted portable C11 until #128,
when LLVM IR replaced it), an interpreter, incremental compilation and an LSP; the design left
room for all of them.

## Why this order

Every missing language feature (byte access on `String`, bitwise operators, capability
encapsulation, package-qualified modules, `Ok(())`, exit codes) currently forces workarounds
into `std/` and packages. Those workarounds would harden into APIs. So the compiler came
first, reaching parity with the language as the tests specify it; the language gains those
features in the compiler, and then std and packages are reworked on a correct base. The
compiler is the one program that has to live with the language's current limits.

## Bootstrap chain

Since #127 (`scripts/selfhost.sh`, seed/README.md; decision U24, Zig's approach):

```
stage0  cc seed/wasm2c.c; wasm2c seed/eiderc.wasm -> C; cc that C with core/eider_core.c
        -> a working eiderc (only a C compiler): it checks programs and emits LLVM IR
stage1  compiler/ built natively by stage0 (clang 17+ from here on)
stage2  compiler/ built by stage1
fixed points: stage1 and stage2 emit byte-identical LLVM IR for compiler/, and build
              byte-identical seeds (`build --wasm-core compiler/main.ei`)
new seed: stage2's module is written to seed/eiderc.wasm (`--seed`) with every compiler
          change, the clang that built it to seed/eiderc.wasm.clang
```

`seed/eiderc.wasm` (1.7 MB, committed as it is: no decompressor is needed) is a core module
("C7: WebAssembly"): its only imports are the C core's functions, so the translated C links
with `core/eider_core.c` and calls it directly. `seed/wasm2c.c` is one C11 file of about 1,200
lines that validates what it translates (only the MVP integer instructions, sign-ext,
memory.copy/fill, one memory and table, active segments, `ec_*` imports) and writes C that
checks every memory access, division, table call and the call depth, with no undefined or
implementation-defined behaviour; it is tested under ASan+UBSan, fuzzed, and against a native
build of an instruction test (seed/tests/run.sh). stage0 is about ten times slower than a
native compiler (emit-llvm of compiler/main.ei: 2.2 s against 0.3 s), which is fine for
building stage1 once. `scripts/ei` (the compiler every script and test runner uses) builds
stage0 into `target/eiderc-stage0` with `$CC`, and with clang 17+ builds compiler/ natively
with it into `target/eiderc`; without clang `target/eiderc` is stage0 itself, which checks
programs and emits IR but can't build them. `--from-seed` checks that the seed is current:
stage0 emits the same IR for compiler/ as the compiler it builds, and with the clang in
seed/eiderc.wasm.clang the seed is rebuilt byte for byte (another clang makes another, equally
valid, module). The rule: the compiler may only use language features that the previous seed
supports (seed/README.md).

Until #127 the seed was `seed/eiderc.c`, the C that the C backend emitted for compiler/, built
by `cc` with the C core; the chain was seed -> stage1 -> stage2 -> stage3 with a fixed point on
the C of stages 2 and 3.

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
| Per-type glue (drop/clone/equality/hash for each concrete type) | generated LLVM IR (generated C until #128) | generated (compiler output; trusted because the compiler is) |
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

`eiderc` must pass all of them. Generated code (LLVM IR, before #128 C) is not part of
the contract: `eiderc` can name and lay out it differently. Diagnostic codes, messages'
meaning, positions (line, column in Unicode scalar values) and `--json` output are part of
it.

## Architecture

Separate passes over flat, index-based data. Eider has value semantics with no references:
reading owned data out of a place copies it. So trees of owned nodes would be copied on every
visit. Instead every pass works on arenas of small records that hold integer ids, as in
data-oriented compilers.

```
files ──lex──> tokens ──parse──> AST arena ──resolve──> scopes, module graph
      ──check──> types arena + typed IR ──llvm──> LLVM IR ──clang──> binary
```

| Pass | Input → output | Notes |
|---|---|---|
| `source` | paths → `List[u8]` per file, file ids | spans are (file, byte offset); line/col computed only for diagnostics |
| `lex` | bytes → tokens `{kind, start, end}` | no token owns text; identifiers are interned |
| `intern` | identifier bytes → `u32` symbol | open-addressing hash table written in Eider |
| `parse` | tokens → AST arena | nodes are `{kind, a, b, c, span}`; variable-length children live in a shared `extra: List[u32]` |
| `resolve` | AST → module graph + scopes | module identity is (package, path); dotted imports (`import json`, C8.26) go through `eider.lock`; visibility (E0801), clashes |
| `check` | AST → typed IR | types interned in a type arena; monomorphization on demand; capabilities; `inout` exclusivity; exhaustiveness; const folding |
| `llvm` | typed IR → LLVM IR | ownership: clones, moves and drops are explicit IR ops before IR is printed, so order-of-evaluation and drop placement are decided once, not while printing text (`lower.ei` names the symbols and lays out the types) |
| `driver` | CLI, `cc`, cache | uses `std/fs` and `std/proc` |
| `consteval` + `interp` | resolved program → program with comptime constants as literals | each constant's evaluator program is checked, then its `__ct` runs on `interp.ei`, an interpreter of the typed IR ("C8.11") |

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
- `uses ffi` everywhere stays in the compiler until the next seed: the seed asks for `ffi`
  along call chains, the compiler it builds no longer does ("C8.5: capabilities per
  package"; scripts/migrate-caps.sh removes it then).
- `var`, not `let mut`, until a seed has 8.6 ("C8.6: references by default";
  scripts/migrate-var.sh rewrites it then). compiler/ is built by the seed with the old
  meaning of `let` (a copy) and by itself with the new one (a reference), so a `let` of a
  place whose place is written while the binding is used later takes `.copy()`, which means
  the same under both.
- None of wave 4's language (C8.15 `take`/`replace`, C8.17 escapes, C8.18 aliases, C8.20 Map
  iteration and `for` patterns, C8.21 `From`, C8.22 `while let`) until a seed has it; the
  same holds for std and packages, which verify.sh builds with the seed.

## C3: checking

`eiderc check` runs lex, parse, `resolve.load` (module graph) and `check.check`, and prints
`ok` or the diagnostics exactly as tests/oracle records them (`--json` byte for byte);
`eiderc ir` dumps the typed IR.

- **Fixed passes, fixed order.** `check.ei` runs: type templates, non-generic types,
  function names, constants, every signature, test bodies, then function bodies in *reverse*
  order (popped from a stack). This order decides which error (and which file) comes first
  in a program with several errors, as tests/oracle records it, and the order of the rest
  ("Several errors").
- **Names.** An imported module's items are named `<module name>__Name` (the stem, or since
  C8.3 `<stem>__0<package>...` for a module in a package: "C8.3: packages and modules"), and the checker sees one
  flat table. `resolve.ei` keys every name as (module prefix, symbol) in a u64 and applies
  the renaming rules (own items, function locals, patterns, tests), so a lookup hits exactly
  what the mangled name would; messages spell keys mangled and `diag.demangle` turns `a__B`
  into `a.B` for the report. Files are told apart by real path (`fs.canonical`, i.e. the
  core's `ec_realpath`), so every path to one file is one module; a module's identity is
  (package, path) ("C8.3: packages and modules").
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

*History: this section describes the C backend, removed in #128 (U23); the LLVM backend
lowers the same IR with the same semantics ("Backends").*

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
capability encapsulation ("Language work" item 5) came with
"C8.5: capabilities per package": `ffi` no longer crosses a package boundary.

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

`const X: T = comptime expr` (`compiler/consteval.ei`, `import eiderc.consteval`; named
consteval since `comptime` is a keyword and no module path can name a comptime.ei). Comptime constants are evaluated between loading the module
graph and checking: `consteval.eval`, called by main.ei between
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
- **Since C8.11: an IR interpreter.** The evaluator is no longer built and run: its `__ct`
  is run by compiler/interp.ei, and the order and the restrictions above changed ("C8.11:
  the comptime interpreter").
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

- **Checking.** `--wasm` (`check`, `emit-llvm`, `emit-header`, `build`, `run`; `test` ignores
  it like `--lib`) checks the program as a library (`check.check_wasm`: no `main`, E0805)
  whose exports take only integer and bool parameters (E0806 at the parameter) and return an
  integer, bool or `()` (E0806 at the function), checked before the E0803 rules, which then
  allow no records. A program that uses a thread type (`Task`, `Mutex`, `Chan`, so also
  `spawn`) gets E0806 at 1:1 after everything else is checked (as tests/oracle records:
  the thread type is noted while checking, the error reported at the end). Until eiderc
  checks threads, `spawn` stops checking with `unsupported`, which `check_wasm` turns into
  that E0806. The compile-fail runner reads `// mode: wasm` and
  passes `--wasm` (as `scripts/test-compiler.sh` does).
- **Lowering** (#126). The LLVM backend for wasm32 (`llvm.program(..., wasm)`): the module
  says `target triple = "wasm32-unknown-unknown"`, llvm_abi.ei lays values out with 4-byte
  pointers (Map 40 bytes, fn values 20; String and List stay 24, `usize` stays 64 bits on
  every target) and uses clang's WebAssembly C ABI towards C (a single scalar leaf direct,
  other aggregates byval / sret); `strlen` is a 32-bit `size_t`. The `eider_<name>` entry
  points carry `"wasm-export-name"="eider_<name>"`.
- **Driver** (`wasm.ei`). `build --wasm` (and `run --wasm`, which also only builds) compiles
  the IR with `core/wasm/eider_rt.c` and `core/wasm/libc.c` by `$WASM_CC`
  (default clang) for wasm32 with an explicit feature set (`wasm.features`: MVP, sign-ext,
  bulk-memory, mutable-globals; the commands are at the top of wasm.ei), and writes
  `<name>.wasm`, `<name>.d.ts` and `<name>.js` (`-o`'s path, else the source's stem),
  printing `built <wasm>, <d.ts>, <js>`; a failed compile is exit 3 with the recorded
  message.
- **Core modules** (`build --wasm-core`, #126): a program with `main` built the same way with
  `-DEI_WASM_CORE` (core/wasm/README.md "Core modules"): it exports `_start` and imports only
  the C core's functions (`env.ec_*`, core/ABI.md), so a host that links core/eider_core.c
  provides files, arguments, the environment, stdio and process spawning through the same
  functions a native program calls; the ABI functions that take or return pointers
  (`ec_str_len`, `ec_str_byte`, `ec_in_cstr`) are defined inside the module. The compiler
  built this way imports 20 of them (ec_args, ec_run, ec_read_file, ...: every OS operation
  it does, process spawning included, goes through `ec_*`); it is the seed (#127). The `.d.ts` and the loader are the
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
- **Cache** (top of `driver.ei`; since C8.27 the layout is build.ei's: "C8.27: incremental
  builds"). `EIDER_CACHE=off` disables it, `EIDER_CACHE=<dir>` moves it, the default is
  `$XDG_CACHE_HOME/eider`, else `~/.cache/eider`. A build compiles units (the program's C and
  the C core's two sources) to objects cached under `obj/`, each keyed by its text, included
  headers, the whole cc argv and `$CC --version`, and links them into a program cached under
  `bin/` by the objects' keys, the link command and the `-l` libraries. `run` executes a cached
  binary in place, `build` copies it to `-o`'s path (removing the old file first, so a running
  binary isn't rewritten). `EIDER_CACHE_MAX` bounds the size (LRU; `eiderc cache
  size|clean|trim`). Not in any key: the contents of external `-l` libraries and of system
  headers beyond what `--version` identifies. With the cache off the objects are made in the
  work directory.
- **Work directories.** Each compile gets its own `eiderc-<ms>-<n>` directory made with an
  exclusive mkdir, under `<cache>/tmp/`, else (cache off) `<root>/target/tmp/`, else
  `$TMPDIR` or `/tmp` if neither is writable; it is removed afterwards (kept, with the C, when
  the C fails to compile). Entries are made there and renamed into the cache, so they appear
  atomically, one file each (two processes making the same entry both succeed; the files are
  identical). Twelve concurrent `eiderc run`s on an empty cache all succeed with one object
  for the program and one build of the core ("cache" in test-compiler.sh).
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
  plus a pointer to `--help`, exit 2 (unknown flags are not silently ignored). The text is
  recorded (tests/oracle/compiler/main.help, the version written `<VERSION>`).
- **Program arguments** (C300). `eiderc run <file> [options] [--] args...`: a word after the
  file that isn't an option goes to the program, and after `--` every word does, options
  included (`eiderc run server.ei --release -- --port 80`); the program sees them after its
  own path in `env.args()`. Program arguments or `--` with another command are a usage
  error (a stray second file of `check` still is one). `run --lib` and `run --wasm` only
  build and ignore them, as before.
- **Toolchain root** (C301, `toolchain.ei`). One lookup for the driver (the core it compiles)
  and resolve (the prelude, `std/...` and `core/...` imports): `$EIDER_ROOT`, else the
  nearest directory above the eiderc binary (argv[0], symlinks resolved) holding
  `core/eider_rt.h`, else the same search from the working directory (resolve then uses
  `.`, so the E0804 names `./core/prelude.ei`). Before, resolve took the directory two
  levels above argv[0] unresolved, so an eiderc at `<root>/bin/x/eiderc` failed with E0804
  for the prelude while the driver found the core.
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
(eider-analyzer, which imports `"eiderc/ide"` through a path dependency on
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
- **Labels** (C304, #83). A loop label (`outer: for ...`, "C8.22") is a symbol of kind
  `SK_LABEL` (12) in the enclosing function, its detail `outer: for` / `outer: while`;
  `break outer` and `continue outer` are refs to the nearest enclosing loop with that label,
  found from the AST while the bodies' locals are walked (labels are their own namespace,
  and sibling loops may share one, so a label is resolved lexically, not by name).
  compiler/tests/ide/labels.ei; eider-analyzer shows them in the outline (under their
  function) and finds their references.
- **Overlays.** `resolve.load_from` reads sources through `resolve.Files`: fs.read, except
  for files whose canonical path is an overlay's (`resolve.disk()` has none). Module
  identity (packages, paths in them) is unchanged by an overlay.
- **Never exits.** Comptime constants are evaluated as in `check`; where the driver would
  exit (no toolchain, no work directory) `analyze` reports a `toolchain` diagnostic instead
  (`driver.find_root`, `driver.try_work_dir`).
- **Cost.** `eiderc ide compiler/main.ei` (the whole compiler, 27 files) takes about 0.25 s
  against 0.16 s for `check`.

## Documentation: `eiderc doc`

`eiderc doc <package dir | file.ei> [--json] [--private]` (`doc.ei`) describes an API. The
JSON form is what eider-doc reads (packages/doc; docs/site/tooling/eider-doc.md documents the
format for users). Without `--json` it prints a text listing like `go doc`.

- **What is documented.** For a directory: every `.ei` file under it, skipping `tests`,
  `examples`, `target`, `deps` and hidden directories. The files are loaded as one
  program through an entry that exists only in memory (`<dir>/__eiderc_doc__.ei`, with one
  `import "<file>" as __docN` per file, as migrate-var does). So every module's imports
  resolve as in a build, and module identity is the usual (package, path). For the
  toolchain's `core`, the prelude is one of the modules (`core/prelude`). For a file: the
  modules of the file's package that its program loads.
- **Only resolution.** It runs `resolve.load_from`, with no comptime and no checking. So no C
  compiler is needed, code that doesn't type-check is still documented, and `eiderc doc std`
  takes 20 ms.
  - Signatures are rendered from the syntax tree as Eider source: one line, canonical
    spacing, `self` without its implicit type, and `pub`, `unsafe`, `extern "c"` or `export`
    from the flags.
  - A type or trait name in a signature links to the item it resolves to. An unqualified
    name resolves to the module's own public types and traits, then to the prelude's;
    `alias.Name` resolves through the module's import aliases (as ide.ei resolves
    qualifiers). Type parameters and built-in types don't link.
  - A constant's value is its source text up to the end of its line, cut at 100 bytes.
- **Docs.** An item's doc is the run of `///` lines directly above its first line, verbatim
  after the marker and one space. A member (field, variant or method) has one when it starts
  its own line. A module's doc is every `//!` line in column 1; separate runs are joined with
  a blank line, and `doc_line` is the first line. Module docs use `//!` rather than a leading
  `//` block, so a licence header or a commented-out line never becomes a module doc. The
  file headers of std, core and the packages are now `//!` comments. The prelude's positions
  are fixed, so it got its `//!` lines in place and at its end.
- **Visibility and anchors.** Only `pub` items are documented (everything in the prelude),
  unless `--private` is given. An impl is shown unless its type or trait is a private item of
  the module.
  - An anchor is the item's name, or `Owner.member` for a member.
  - A trait impl is `impl-<Trait>-for-<Type>`, and an inherent impl is `impl-<Type>`, whose
    methods are `Type.method`.
  - A name taken twice in a module gets `-2`, `-3`, ... in item order. Public items come
    first, so `--private` doesn't change public anchors.
- **Version.** The JSON's `toolchain` is the first line of `<toolchain root>/VERSION` (empty
  without one), so a site can say which toolchain it documents.
- **Problems** in the documented modules, such as syntax errors or imports that can't be
  found, are warnings on stderr (`eiderc doc: warning: <file>:<line>:<col>: <code>
  <message>`), and the rest is still documented. A target that can't be read or loaded exits
  2.

**Tests** (test-compiler.sh "doc"):

- compiler/tests/doc/shapes is a package with two modules. It is compared with `shapes.json`,
  `shapes.txt` and `shapes.private.json`, and one of its files with `geo.json`. It has:
  - module docs in two runs;
  - an enum with variant docs, a one-line record and a multi-line record, an alias, a const
    and a trait;
  - trait and inherent impls, and a method named like a field;
  - generics with bounds, capabilities, and qualified links into std and into another module;
  - an unsafe fn, private items and a test block.
- core, std and every package under packages/ must document with no warning, and core must
  have the prelude.

**Seed.** The seed was regenerated with `doc`, so scripts/docs.sh uses `target/eiderc`. When
a compiler change hasn't reached the seed yet and `target/eiderc doc` fails, docs.sh falls
back to compiler/ as the seed builds it (`target/eiderc-next`).

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
- **Comptime** (`consteval.eval_all`). A constant whose evaluation fails is reported (the
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
- Checker (S1–S3): registering an impl replaces `Self` textually, also inside `MySelf`;
  impls on fn types never match a receiver. (A name in an impl target or a generic signature
  that isn't a type parameter no longer matches every type: "C8.16".)
- Comptime: any error in the rest of the program is found by the first evaluator, and an
  E0201 there loses its fix; traps during evaluation in the evaluated file name the file
  `program` ("C7: comptime"; a trap in an imported module or the prelude names its file
  since "C8.16"). (Constants in any order, and plain constants and functions naming comptime
  constants, are fixed: "C8.11: the comptime interpreter".)
- Threads: `contains` on a List of handles compares them as equal ("C7: threads").
- Library header: header type names keep the recorded spelling (`R_<mangled name>`, "C7:
  FFI"), so two libraries exporting records of one name can't be included together. (The
  shared include guard `EIDER_EXPORTS_H` is fixed: each header's guard is
  `EIDER_<NAME>_H`, from the library's name, C302; compiler/tests/export/consumer.c
  includes two headers.)
- WebAssembly loader (kept byte-identical to `tests/oracle/compiler/tests/wasm/*.js`,
  core/wasm/README.md): an export
  parameter named `x` shadows the loader's `const x = inst.exports`, so calling that export
  breaks; `u32` results above the signed range come back as negative numbers and
  `u64`/`usize` results as negative BigInts, because the loader passes the raw wasm values
  through.
- Runtime: `ei_now_ms` is the monotonic clock in ms (it was processor time, `clock()`, until layer/core-os; core/RUNTIME.md).
- Answered `unsupported` where the recorded behaviour is wrong, waiting for a language
  decision: `?` in an expression-bodied closure (recorded: checked against the enclosing
  function's return type), and an `extern "c"` or `unsafe fn` used as a function value
  (recorded: accepted with neither `unsafe` nor `uses ffi`).

## C4: lowering

*History: this section describes the C backend, removed in #128 (U23); the LLVM backend
lowers the same IR with the same semantics ("Backends").*

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
  checkout, and an installed eiderc needs `EIDER_ROOT` (or a `core/` above it). resolve finds
  the prelude and std the same way (`toolchain.ei`, C301; before, it took the directory two
  levels above argv[0]).
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

## Backends

The LLVM backend (issues #92, #96, #125 and #128, U21, U23, C260-C269, C340-C346, C440,
C447-C452) is Eider's only backend: `llvm.ei` lowers the typed IR to textual LLVM IR, which
clang builds, for `build`, `run`, `test`, `build --lib`, `--wasm`, `--wasm-core`, `--profile`
and comptime evaluators (`emit-llvm` prints it; user documentation in
docs/site/tooling/llvm.md). It is ordinary compiler code built by the seed, so building eiderc
needs no LLVM; eiderc checks before every build that clang is LLVM 17 or newer
(`driver.llvm_cc`; exit 3 with a message otherwise). Until #128 a C backend (`lower.ei`
writing C11) was the default and the seed's form, and this backend wrote only the functions
it could lower, leaving the rest, the glue, `main` and the test driver to a "C half"; that is
all gone. `lower.ei` keeps the C names and layouts (llvm.ei's symbols, and `emit-header`'s C
header for `export fn`s, which is interop, not a backend) and the facts about types the
backend asks.

**The module.** Every function with a body becomes a `define`; a construct the backend can't
lower is an internal error naming the function. The per-type operations are glue functions in
the module (`glue_all`, C447): drop, clone, `.copy()`, copy-on-write `uniq_`, `own_` (before a
value crosses threads), `==`, Ord, Hash, Show (with `ei_str_push_quoted` for text inside a
value), variant names (a constant table), the List and Map operations, Box/Ref/record buffers
(the shared-buffer counts inline), closure environments (`edrop_`/`eclone_`/`eown_`) and
thunks, Default, and the thread handles over the runtime's handle objects (`ei_h_*`: a count,
a lock, a thread and a channel the runtime lays out, with the program's data after them, so
the IR never depends on `pthread_mutex_t`'s size). Each is asked for where it is used
(`gneed`) with the C convention of that call, defined `internal`, and built until no new glue
is needed. `main` hands `ei_main_body` (the trap file table, the profiler's start, the Eider
`main` and its result as an exit code or `error: ...`) to the runtime's `ei_main`; the test
driver runs each block through the runtime's `ei_test` (which owns the setjmp) and ends with
`ei_tests_done`; a library's `eider_<name>` entry points have the header's C convention. The
module comes back in parts (`Out.head`, the type definitions, then each function's text,
`Out.owner` its IR function or GLUE), which llvm_units.ei cuts into units.

**Build.** Since C8.27 the module is cut into units (one per module, the generic instances in
16 shards, and one for the glue and the entry points; llvm_units.ei), each compiled by clang
(the sanitizer, `-g` and `-O` flags of `EIDER_CFLAGS` too) in parallel and cached; the C core's
two sources are compiled by `$CC`; a release build uses ThinLTO with lld and lld's cache
(C396). `EIDER_LLVM_LTO=0`, no lld, and `build --lib` link plain objects; `-g` and `build
--lib` build the module as one unit. The program is cached by its objects ("C8.27:
incremental builds"). A `--profile` build compiles the core with -DEI_RT_PROFILE.

**Targets** (C448). The target is the one clang builds for (`$EIDER_LLVM_CC -dumpmachine`;
x86-64 without clang), or wasm32 for `--wasm`/`--wasm-core`; it chooses llvm_abi.ei's C
convention: System V x86-64, AAPCS64 for aarch64 (a scalar direct and not extended, a
composite of up to 16 bytes as an integer of its size or `[2 x i64]`, a larger one as a pointer
to a copy the caller makes, a larger result through `sret`), or clang's WebAssembly ABI. The
layouts are the same on x86-64 and AArch64 (LP64). compiler/tests/llvm/a64.sh compares the
AArch64 signatures of abi.ei's exports with clang's for the same C prototypes, so a
cross-built tool (zig cc -target aarch64-linux-musl as clang, scripts/release.sh) calls the C
core correctly; there is no AArch64 machine here to run one.

**Calling conventions.** A call from Eider to Eider uses an internal convention (C340):
every native function is `define internal @<name>.i`. Its parameters are classified as the
System V ABI classifies them, except that an aggregate the C ABI would copy onto the stack
(byval: over 16 bytes, or out of registers) is passed by reference, and registers are not
counted. The callee never writes through that reference; a function that writes such a
parameter copies it first. Glue calls a trait `impl` through the internal convention too;
the C convention is for the C core and runtime, `extern "c"` functions, exports, and closure
bodies and thunks, which are only called through fn values.
This reverses part of C262. The profile of round one showed why: a borrowed record such as
check's 3 KB context was copied byval on every call, and external linkage stopped clang from
doing what it does with the C backend's static functions (argument promotion, inlining a
function called once, dropping the copies). `llvm_abi.ei` still holds the C layout of every
type, the same layout `lower.ei` declares: records and tuples are structs, an enum is
`{ i32 tag, [n x iA] }` with a struct per variant, String/List/Map/Box/fn values/handles
are the C structs. It also holds the System V x86-64 classifier, memoized per type. A type
is flattened into scalar leaves, and anything over 16 bytes is MEMORY. Each eightbyte gets
the merge of its leaves' classes (the general psABI merge, unit-tested with SSE leaves,
although Eider has no floating-point type yet). An INTEGER eightbyte is passed as an
integer of its bytes (`i64`, or `i8`..`i56` for the last one, as clang does). MEMORY
arguments go `byval`, and MEMORY results go through `sret`. An aggregate that needs more of
the six integer registers than are left goes `byval` as a whole. bool and u8 are
`zeroext`. compiler/tests/llvm checks this against the C compiler: records of 2 to 24
bytes with padding, nesting, a str, register exhaustion, and both directions (C export
wrappers into LLVM IR, and the runtime's functions); AAPCS64 and wasm32 are above ("Targets").

**Semantics.** One IR statement lowers to the same operations the C backend performs, in the
same order: bounds checks first (outermost index first), then copy-on-write `uniq_` calls,
then the operation. Locals (C341): a definite-assignment walk over the structured IR finds
the locals that may be read before the whole local is assigned, and only those are zeroed at
entry, as C's `= {0}`; a scalar local that one statement assigns, that no place is rooted
at, and that is read only after that assignment, is an SSA value with no alloca. The walk
was checked by filling every unzeroed alloca with 0xAA (a volatile memset): the differential
suite, and the compiler built that way reproducing its own C and IR, were unchanged. Scalars
are SSA values between statements (bool is `i1` in registers and `i8` in memory),
aggregates are copied with `llvm.memcpy`, and the IR's structured S_IF and S_LOOP become
labelled blocks. Nothing is undefined behaviour. Checked `+ - *` use
`llvm.{s,u}{add,sub,mul}.with.overflow`, and `/ %` check zero and MIN / -1. Shifts check the
count with one unsigned compare, conversions check the source widened to 64 bits, and
indices are an `icmp uge`. Each check branches to a call of the runtime's `ei_trap` with the
C runtime's message and the same encoded line (file index * 2^20 + line, "C8.16"), so traps
print, exit 101 and longjmp under `test` exactly as in C. Flags only restate what a check or
a language rule proved (C342): past its trap branch a checked operation is `add`/`sub`/`mul
nsw` (signed) or `nuw` (unsigned), a negation `sub nsw`; every GEP is `inbounds` (a field of
a value of its type, an element after its bounds check), except an element address among a
closure call's `inout` arguments, which neither backend checks; the builtins' own loop
counters are `add nuw nsw`. The internal convention's parameters say what the language
guarantees: scalars are `noundef` (nothing is read before it is written), an `inout` pointer
is `noalias` (C8.6: E0301 makes it exclusive, and the caller makes its path unique first)
and `dereferenceable`, a by-reference record is `noalias nocapture readonly` (call_internal
copies it to a temporary of its own if the same local is also an `inout` root or the
destination), and `sret` is `noalias`. No `exact`, no flags on shifts, and none of LLVM 18's
newer flags while the minimum is LLVM 17. compiler/tests/run/llvm_opt*.ei trap in loops
whose induction variables the flags describe, with the C backend's messages and lines.
Per-type operations call the module's glue. The hot helpers are inline IR: `ei_idx`, checked
arithmetic, the conversions and shifts, `ei_hash_u64`, the shared-buffer counts and the Ref
access checks.

**Debug info** (`-g`): a DICompileUnit (`DW_LANG_C11`, since DWARF has no code for Eider),
a DIFile per module, a DISubprogram per function (its Eider name, and its C name as
the linkage name), a DILocation per statement from the IR's line, and a DILocalVariable for
every parameter and named local that has an address (`llvm.dbg.declare`). Types are
described from the C layouts: integers, bool and str as base and pointer types, arrays,
records and tuples with their members' names and offsets, an enum as its tag plus one member
per variant with a payload (at the union's offset), String and List with their pointer,
`len` and `cap`; other handles are sized structures. The line table names the `.ei` files,
so a debugger can break on an Eider line. compiler/tests/llvm/run.sh builds
compiler/tests/llvm/dwarf.ei at -O0 with `-g` and finds every parameter, local, member and
type name with a frame location (llvm-dwarfdump, else `readelf --debug-dump=info`; gdb and
lldb are not installed here). At -O2 the variables of inlined functions are optimized away.

**Tests.** Until it became the default (C440), `scripts/llvm-diff.sh` ran every
run test through both backends and required byte-identical stdout, stderr and exit codes at
-O0, -O2 (with LTO), with `-DEI_RT_COUNT_ALLOCS` and under ASan+UBSan; it is gone (C440).
The reference is now the recorded oracle: scripts/test-compiler.sh's run, sanitize and leaks
legs build every run test with the LLVM backend and compare it with tests/oracle's `.run` and
`.test` files. compiler/tests/llvm/run.sh (verify.sh's "llvm" leg, skipped with the reason
when clang 17+ is missing) checks the C ABI, the AArch64 signatures (a64.sh) and the DWARF;
scripts/selfhost.sh checks that two stages emit byte-identical IR for compiler/main.ei.

**Measurements** (taken with the comparison scripts/llvm-bench.sh had then; it now times
the LLVM backend alone. 2026-10-31, x86-64, clang 22.1.8 for both backends, median of 7 runs, EIDER_CACHE=off, a shared and busy machine: compare within a
row, not across days).

Round two (#96): compile time in ms. `emit` is the front end plus lowering (emit-llvm also
writes the C half). `build` adds clang on the `.ll` and `$CC` on the C, or `$CC` on the whole
C; LLVM -O2 includes LTO.

| program | emit-c | emit-llvm | C -O0 | LLVM -O0 | C -O2 | LLVM -O2 |
|---|---|---|---|---|---|---|
| tests/bench/list_copies | 4 | 4 | 194 | 232 | 442 | 461 |
| tests/bench/state | 4 | 4 | 194 | 234 | 499 | 510 |
| tests/bench/str_append | 3 | 3 | 187 | 223 | 418 | 436 |
| compiler/main.ei (1378 functions) | 309 | 428 | 2345 | 1640 | 23235 | 24185 |

Run time of the -O2 binaries in ms. `self` is the built compiler running `emit-c
compiler/main.ei`. The three bench programs finish in a few ms, too fast to compare.

| program | C | LLVM | LLVM/C |
|---|---|---|---|
| list_copies | 4 | 3 | 0.75 |
| state | 3 | 3 | 1.00 |
| str_append | 5 | 5 | 1.00 |
| self | 335 | 254 | 0.76 |

What each step bought (the compiler's run time, `emit-c compiler/main.ei`, medians of 7-15
interleaved runs on the same machine; round one: C 258-305, LLVM 369-428):

| step | LLVM/C |
|---|---|
| round one | 1.40-1.43 |
| internal convention alone (locals still zeroed) | 1.56 (no gain: the memsets kept the copies alive) |
| definite assignment alone (C convention) | 1.16 |
| both (C340, C341), no LTO | 0.95 |
| plus nsw/nuw/inbounds (C342), no LTO | 0.95 (under 1% on the compiler) |
| plus SSA scalars, no LTO | 0.94 |
| plus LTO in the driver (C343) | 0.76-0.79 |

The profile behind it (a SIGPROF sampler with frame-pointer stacks, since perf isn't
installed): in round one the LLVM build spent twice the C build's time in libc, nearly all
of it memcpy called from check.expr, check.call_decl and their kin, which copied the 3 KB
checker context byval on every borrowed call, inside 35 KB frames whose locals were all
zeroed at entry; with LTO alone (round one's 1.37) push/clone/drop of List[u8] still were
not inlined into lower.emit.

emit-llvm against emit-c (the same -O2 compiler, interleaved): 3.4x in round one, then 1.99
with the internal convention and SSA scalars (the IR shrank from 16.3 to 10.8 MB), 1.70 once
the C half stopped lowering the native bodies (C344), 1.61 with instructions written in place,
1.53 with the module in parts, 1.42 with the conventions memoized, and 1.39 in the table
above (9.6 MB of IR against 5.3 MB of C; writing it to stdout is a tenth of emit-llvm).

LLVM -O0 builds the compiler in 70% of the C time (clang -O0 on 9.6 MB of IR is faster than
on 5.3 MB of C, and the C half is small); at -O2 with LTO the two take about the same time
(LTO's link is single-threaded; without LTO the LLVM build takes about 60% of the C time).
The recommendation on graduating (C346) was an opt-in backend; the user made it the default
and the only one (U23, C440). Still to do: arm64, `--profile` through the LLVM backend, TBAA (clang's type-based aliasing,
which the IR doesn't give LLVM yet), and DWARF for SSA values and inlined frames.

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

Where eiderc's own time goes, from its profile (`sh scripts/profile-compiler.sh`: eiderc built
with `--profile`, `emit-c compiler/main.ei`, 2026-10-31; docs/runtime.md "Profiler"). Of the 36
CPU samples at 99 Hz (few: the shares are rough; EIDER_PROF_HZ=999 for more), about a third is checking (`check.check_all`), two fifths lowering
(`lower.emit`), a fifth loading and parsing (`resolve.load_from`); the hottest single
functions are `check.expr`, `lower.put` and `sys.lit` (about a tenth each). The memory profile
is the more useful one, since its counts are exact and the same on every run (`--check` gates
them): 2.13 M allocations and 145 MiB for one compile, peak heap 47.5 MiB.

| Hot spot | Count | Why |
|---|---|---|
| `sys.lit` (core/sys.ei:43) | 1.36 M allocations, 27 MiB | every `str` literal turned into a `List[u8]` one byte at a time through the C core (the push loop also grows the List); lowering calls it for each piece of C text |
| List growth of the big buffers (`parse.add`, `lex.run`, `bytes.append` for the output) | 21 MiB, 19 MiB, 27 MiB in a few hundred doublings each | arenas and the output grow by doubling with a copy each time; reserving from the input size would remove most |
| `.copy()` | 1.7 M calls, 25 MiB | mostly the lexer's and parser's `let x = place.copy()` (lex.run:376, parse.bit_expr), each a shallow copy, plus `bytes.from_u64` |
| `bytes.from_u64` | 441 k allocations | `putn` of numbers in the C text |
| copy-on-write unshares | 4,515, 0.7 MiB | small: `intern.intern` (the interner's table, twice, 0.5 MiB) and the checker's `lv_loop`; C8.1 did its job |

So the next compile-speed work is in the text output (a `str` append that doesn't go through
`sys.lit`, and numbers written without a temporary) and in sizing the arenas, not in the
checker's copies.

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
| One unit per module, compiled in parallel (needs constraint 3; "C8.27: incremental builds": the infrastructure is built, the split comes with the LLVM backend) | uses the idle cores; most of the compile time for large programs |
| -O0 for the edit/run loop by default (already), -O2 only for `build` | 4x faster gcc on large programs |
| Incremental front end: cache per-module check results keyed by source hash and the interfaces of imports | measured in "C8.27" ("The front-end cache"): a parse cache would be slower than parsing; a whole-program manifest and per-module lowering by interface hashes are the designs kept |
| A direct debug back end (no C compiler in the loop) | edit/run latency independent of gcc |

## C8 plan: the backlog

The services roadmap (P0: a first JSON/HTTP service, P1: production RPC and OpenAPI) that
follows these waves is in docs/design/roadmap.md.

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
| 1 | **8.3 Package-qualified modules** (done: "C8.3: packages and modules"; package imports in compiler/, std/, packages/ after the next seed) | module identity = (package, path) instead of file stem (no more E0808 for two packages' `util.ei`); bare `import "json"` resolved through `eider.lock`; the `deps/` link farm retired | — |
| 2 | **8.4 Operation traits** (done: "C8.4: operation traits") | `Copy`, `Eq`, `Ord`, `Hash`, `Show`, `Iter`, `Drop` in the core prelude; automatic derive; orphan rule; generic bounds with suggested fixes; Map keys any `Hash + Eq`; `for` over any `Iter` | 8.1, 8.2 |
| 2 | **8.5 Capability encapsulation** (done: "C8.5: capabilities per package"; `uses ffi` removed from the repository after the next seed) | `ffi` becomes a property of a package (granted in eider.toml); std callers stop writing `uses ffi`; the compiler reports each package's real capability use and eider-pkg checks grants from that instead of scanning text | 8.3 |
| 3 | **8.6 References by default** (done but for C pointer variables: "C8.6: references by default"; `var` migrated after the next seed) | `let` binds a read-only reference to a place, `let mut` a mutable alias, fresh values are owned; `.copy()`; pattern bindings the same; the protection rule (no invalidating write while a reference is alive) with fixes; references are C pointers; `var` deprecated with a mechanical fix | 8.1, 8.4 |
| 3 | **8.7 `Ref[T]`** (done: "C8.7: `Ref[T]`") | shared mutable handle with scoped `read`/`update`, run-time conflict check, not sendable | 8.4 |
| 4 | **8.8 Closures by reference** | non-escaping closures capture by reference | 8.6 |
| 4 | **8.9 Std on the new base** | std speaks `String`, uses traits and references; `List[u8]` workarounds and `sys.lit` byte loops go | 8.2, 8.4, 8.5, 8.6 |
| 4 | **8.10 Parity quirks** | fix each item in "C8 candidates" deliberately (wasm loader bugs, checker quirks), re-blessing the oracle per item | — |
| 5 | **8.11 Comptime interpreter** (#7; done: "C8.11: the comptime interpreter") | evaluate `comptime` by interpreting the IR: no C compiler at compile time, no capabilities by construction | — |
| 5 | **8.12 Performance** | smaller generated C, one C file per module compiled in parallel, incremental front end keyed by module hash | 8.3 |
| 5 | **8.13 Tooling** | `eiderc fmt` (formatter); analyzer: rename, workspace symbols, signature help, inlay hints, formatting; tree-sitter grammar generated from the compiler grammar | 8.9 |
| 5 | **8.14 Package manager on bare imports** | eider-pkg reworked for 8.3/8.5 (no link farm, compiler-reported grants), registry design | 8.3, 8.5 |
| later | 8.15 Projections, lints (`take`/`replace` done: "C8.15: take and replace") | std accessors returning references; lints for real copies at escapes and `Ref` cycles | 8.6, 8.7 |
| 4 | **8.16 Seed bugs from std** (done: "C8.16: the seed bugs std found") | the four bugs of docs/std.md "Compiler bugs found": `()` in a generic match arm, a type name in a generic signature matching any type, traps naming the entry file, derived Show printing C names | — |
| 4 | **8.17 String escapes** (done: "C8.17: string escapes") | `\r`, `\0` (refused), `\xNN`, `\u{...}`, adjacent literals | — |
| 4 | **8.18 Type aliases** (done: "C8.18: type aliases") | `type Handler = fn(Request) -> Response`, generic aliases, `pub` across modules | — |
| 4 | **8.19 Calling a fn field** (done: "C8.19: calling a function stored in a field") | `self.handler(req)`, with the rule for a clash with a method | — |
| 4 | **8.20 Iterating a Map** (done: "C8.20: iterating a Map") | `for (k, v) in m`, `m.keys()`, `m.values()` in slot order | 8.4 |
| 4 | **8.21 Error conversion for `?`** (P0.6; "C8.21: error conversion for `?`") | `From[E]` in the prelude; `?` converts `Err(e)` through an impl | 8.4 |
| 4 | **8.22 `while let`, labeled loops** (done: "C8.22: `while let` and labeled loops") | `while let p = e`, `outer: for`, `break outer`, `continue outer` | — |
| 5 | **8.23 `Default`** (done: "C8.23: `Default`") | the eighth operation trait: derived for records, built in for scalars, text, containers and Option; `T.default()`; `take()` for every `T: Default` | 8.4, 8.15 |
| 5 | **8.24 `Error` and context** (P0.6; done: "C8.24: `Error`, `Failure` and context (std/error)") | `error.Error` (message, source), `error.Failure` (a chain), `.context`/`.with_context` on Result and Option, `?` into a Failure through `From` | 8.21 |
| 5 | **8.25 Method chains across lines** (N13; done: "C8.25: method chains across lines") | a line starting with `.` continues the expression before it | — |
| 5 | **8.26 Dotted imports** (#91; done: "C8.26: dotted imports"; compiler/, std/{bytes,fs,io,env,proc} and core/{sys,version} migrated after the next seed, #95) | `import core.sys`, groups `std.{bytes, fs}`, `as`, `import json.stream`, own modules as `pkg.module`, siblings by name outside packages, the lazily loaded `import std` namespace; E0812, E0813; the quoted form deprecated silently with `eiderc migrate-imports` fixes | 8.3 |

## C8.3: packages and modules

Backlog item 8.3 (wave 1): module identity is (package, path) instead of the file stem, a
package is imported by name through `eider.lock`, and the `deps/` link farm is gone. Code:
`resolve.ei` (loading, identity, module names), `lock.ei` (eider.toml and eider.lock as the
compiler reads them), `diag.demangle`; eider-pkg in `packages/pkg`.

**Packages.** A file's package is the nearest `eider.toml` above its canonical path (symlinks
resolved); its `[package] name` names it. A file with no `eider.toml` above it is in no
package. The toolchain's `core/` and `std/` are the packages `core` and `std` (each has an
`eider.toml`); the names are reserved (eider-pkg rejects a package or a dependency called
either).

**Module identity** is (package, the file's path inside the package without its
extension): `compiler/lex.ei` is (eiderc, lex), `packages/json/json.ei` (json, json). A file in
no package keeps the identity it always had, its canonical path, and two such files with one
stem still clash (E0808), so every existing program means what it meant. Two different files
with one identity are E0808 too: outside packages, the same stem (message unchanged, new
help: "rename one of the files, or put them in packages"); inside packages, two copies of one
package loaded from different directories ("two different copies of package `base` have
module `base` (A and B)"), which only a path import of a second copy can cause, since a
program locates each package once, through one eider.lock. Two packages may each have a
`util.ei`; a package and a file in no package may share a stem.

**Module names, C names.** A module's items are keyed by its *module name*, the prefix the
checker spells into every name (`<module name>__Name`) and lowering into every C name
(`t_`, `f_`, ...; "C4: lowering"). Outside packages it is the stem (so the C for every
existing test is unchanged); inside a package it is `<stem>__0<package>`, or
`<stem>__0<package>_s<path>` when the path is not just the stem (a directory, or bytes that
are not identifier bytes): `lex__0eiderc`, `util__0shapes_ssrc_sutil`. The package and path
are escaped (letters and digits as is, `_` `_u`, `/` `_s`, `-` `_d`, `.` `_p`, others `_x`
and two hex digits), so module names are identifier bytes, contain no `__` after the
marker, and decode back to (package, path): distinct identities give distinct C names.
They depend only on the package's name and the path inside it, never on where the package
sits on disk, so the C is byte-identical from another checkout (test-compiler.sh,
"packages"). What users see shows the stem only: `diag.demangle` drops `__0...` (messages
say `util.Point`, as before), and so does `resolve.shown` where text reaches a program or a C
interface (the variant names a program prints, `geo__South`; `export fn` symbols,
`eider_units__twice`; header record names). A known corner: a file in no package whose name
contains `__0` displays oddly.

**Imports.** (This is the quoted form, deprecated silently since "C8.26: dotted imports",
which maps `import a.b.c` onto the package imports below.) An import string is a *path
import* if it contains a `.` or starts with `/`
(`"util.ei"`, `"../lib/geo.ei"`, `"lib/broken_mod.txt"`): a file relative to the importing
file, as before. Otherwise it is a *package import*: `"<package>"` or
`"<package>/<path>"`, the package name lowercase letters, digits and `_` starting with a
letter, the path one or more non-empty segments. (So a path import without its extension,
`"lib/geometry"`, which nothing in the repository used, is now a package import.)

- `"std/fs"`, `"core/sys"`: the toolchain's, `<toolchain root>/std/fs.ei` (the root that holds
  the prelude, resolve.ei `toolchain_root`), from any file. `"std"` alone is E0809 (no entry).
- `"json"`: package json's entry module (`entry` in its eider.toml, default `json.ei`);
  `"json/a/b"`: its file `a/b.ei`. Allowed when json is the importing file's own package or a
  direct dependency of it (`[deps.json]` in its eider.toml). Anything else is **E0809**
  ("package `util` is not a dependency of `app` (<dir>/eider.toml)", help: `eider-pkg add util
  --path <dir>` or `--git <url> --version <v>`), also for a file in no package and for a
  malformed import (`"Geo"`, `"geo//util"`).
- The default alias is the last segment: `json`, `util` for `"json/util"`, `fs` for `"std/fs"`.
- A dependency's directory comes from **eider.lock**: the lock of the program's root package
  (the entry file's; when the entry file is in no package, the importing package's own). A
  `path+<dir>` source is `<dir>` relative to the lock; a `git+` source is `.vendor/<name>`
  beside the lock when that directory exists, else the store's `$EIDER_HOME/pkg/<name>-<the
  first 16 hex digits of the locked content hash>` (`EIDER_HOME` defaults to `~/.eider`):
  exactly where `eider-pkg fetch` and `eider-pkg vendor` put it. No lock, no entry for the
  package, a directory that doesn't exist, or an eider.toml or eider.lock that doesn't parse
  is **E0810**, with the fix `run eider-pkg fetch in <dir>`. No other directory is looked
  at (C400). The compiler does not re-hash
  store directories: eider-pkg checks the hash whenever it fetches.
- The toolchain series (C220, docs/site/tooling/releases.md). `eider = "0.1"` under
  [package] names the toolchain MAJOR.MINOR a package needs (lock.ei `Manifest.eider`).
  resolve.ei `check_series` compares it with core/version.ei's `SERIES` (the compiler's
  own, from when it was built) once per package: another value, or one that isn't a
  MAJOR.MINOR, is **E0811**, at 1:1 of the entry file for the entry file's package and at
  the first import that loads a module of any other package; absent, nothing is checked.
  `eiderc --version` (and `eiderc version`) prints `eiderc <core/version.ei VERSION>`; that
  file is the Eider copy of VERSION (scripts/version.sh check), so the seed embeds the
  version and a bump is a source change plus a seed regeneration.
- So visibility is per package: app sees its dependencies, each dependency sees its own
  (from its own eider.toml, read in the store or .vendor copy), and the lock, written for the
  whole graph by `eider-pkg fetch`, says where each one is.
- A module's `path` (Diag.file, ide Span.file) is the package's directory joined with the
  module's path: absolute for a package import, since the directory comes from canonical
  paths and the lock. Relative imports inside a package go on from there.
- The old link-farm spelling `import "deps/json/json.ei"` is a path import that now fails with
  E0804; when the path has a `deps/` segment the help says to import the package by name.

`lock.ei` is the compiler's own reader (the compiler depends only on core and std, LAYERS.md):
the TOML subset packages/toml reads, flattened the same way, keeping what the compiler needs
(the package name, entry and dependency names; per lock entry the name, path or git source
and hash).

**eider-pkg.** `fetch` (and `add`, `remove`, `update`, `vendor`) resolves and writes
eider.lock and fills the store or .vendor/; it no longer makes `deps/` (compatibility: a
`deps/` holding the `.all` directory an earlier eider-pkg made is removed). `init` writes a
program that imports `"core/sys"` and `"std/io"`, and no `.gitignore`. The lock format is
unchanged. `scripts/bootstrap-deps.sh` is retired (a no-op that removes old links; nothing
calls it).

**Migration, staged.** compiler/ must build with the current seed, which knows only path
imports, and so must std/ and core/ (which compiler/ imports) and everything verify.sh builds
with the seed (packages/, eider-pkg, the tests). So:

1. Now (this item): nothing in the repository needs `deps/`. compiler/ imports
   `../core/sys.ei` and `../std/fs.ei`, packages/ import `../../std/fs.ei` and each other as
   `../toml/toml.ei`, std/ already imported `../core/sys.ei`: path imports, which every
   compiler understands, and module identity comes from the packages either way.
   packages/pkg declares its dependencies with the grants their tests need and has a
   committed eider.lock (path sources, so it is the same on every machine). Package imports
   are used where only the new compiler builds: compiler/tests/pkgs, tests/pkg/run.sh (which
   builds its programs with `target/eiderc-next`, or `EIDERC`), and eider-analyzer.
2. After the next seed: `scripts/migrate-imports.sh compiler std core packages tests` rewrites
   every path import that crosses into another package (core and std, or a declared
   dependency) into a package import, keeping aliases (`as <old alias>` where the default
   would change); imports within a package stay relative. test-compiler.sh ("migration")
   already runs it on a copy of core, std, packages and compiler and holds the result to
   checking and to the package tests, so stage 2 is the mechanical rewrite plus a BLESS for
   the tests whose diagnostics quote an import line, and the new codes' cases join
   tests/checks (until then they are in compiler/tests/check, which only the new compiler
   runs: the seed would report E0804 for them).

**Tests.** compiler/tests/pkgs: app, geo, shapes and base packages with eider.lock, a
vendored git package (`.vendor/`) and one in a store (`home/`), in `// pkgtest: run|check|ide` files with
hand-checked `X.out`: three `util` modules in one program, a chain (app -> geo -> base),
an entry that isn't `<name>.ei`, self-import by package name, std and core, then the errors:
an undeclared package, an indirect one, one missing from eider.lock, a locked directory that
is gone, no eider.lock, malformed imports, two copies of a package, and a file in no package;
plus the same C from a copy of the layout at another path. compiler/tests/check/fail has
E0809 and E0810 cases, compiler/tests/unit/lock.ei the reader; compiler/tests/pkgs/series
and seriesbad E0811 at 1:1 (another MAJOR.MINOR, a full version), app and geo a matching
`eider`, tests/checks/fail/e0811_toolchain_series.ei E0811 at an import. tests/pkg/run.sh builds and
runs its projects through eider.lock: no `deps/` after fetch, the locked git packages in the
store, an indirect or undeclared or removed dependency is E0809, one added by hand before a
fetch E0810, a run from .vendor/ with the store deleted, and `core`/`std` refused as names.

**IDE.** ide.analyze is unchanged in shape: Span.file is a module's path as above (absolute
for package imports), files are told apart by canonical path as before, and module refs come
from `Module.aliases` (one per import, also for one that failed). eider-analyzer imports the
compiler as `"eiderc/ide"` (a path dependency on compiler/) and json as `"json"`, finds them
through its eider.lock, and builds with a compiler that knows package imports.

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

## C8.4: operation traits

Wave 2, item 8.4 (docs/design/memory-model.md, "Operations are traits"): every operation the
language performs on values is a trait of the core prelude, derived when a type's parts have
it, and implementable by the type's own package. Code: check.ei's "Operation traits" and
"Bounds of generic code" sections, lower.ei's "operation traits" glue, ir.Ir.impls. `compiler/`
uses none of it until the next seed.

**The prelude** gains, after Option and Result (so every position tests/oracle records for
prelude items is unchanged):

```eider
type Ordering = | Less | Equal | Greater
trait Copy { fn copy(self) -> Self }
trait Eq { fn eq(self, other: Self) -> bool }
trait Ord { fn compare(self, other: Self) -> Ordering }
trait Hash { fn hash(self) -> u64 }
trait Show { fn show(self, inout out: String) }
trait Iter { fn next(inout self) -> Option[Item] }
trait Drop { fn drop(inout self) }
```

`Ordering`, `Less`, `Equal` and `Greater` are prelude names like `Some`. `Iter`'s `next` returns
`Option[...]` of whatever item type the impl chooses (the language has no associated types;
the item type is read off the impl, and an impl whose `next` returns anything else is E0602).
A trait the entry module defines with one of these names **shadows** it in the program's names
(`trait Show` in compiler/tests/run/generics.ei is that program's own trait, and `impl Show
for bool` implements it); the language goes on using the prelude's, which that program then
can't implement. `Ordering` is resolved when a program first uses it, so a program that
doesn't has the types, and the C, it had before.

**Which types have which trait.** A record, enum, tuple, array, List, Box (and Map, where
noted) has a trait when every part has it ("derived"; no annotation and no opt-out: a type
lacks a trait only when a part does). A record or enum may instead implement one itself,
which replaces the derived one everywhere: in the operator, and inside the derived operations
of every type that contains it (`==` on a `List[Name]` uses Name's own `eq`).

| | Copy | Eq | Ord | Hash | Show | Iter | Drop |
|---|---|---|---|---|---|---|---|
| integers, bool, str, String | yes | yes | yes | yes | yes | | |
| `()` (as a part: `Ok(())`) | yes | yes | yes | yes | yes | | |
| records, enums, tuples, arrays, List, Box | derived | derived | derived | derived | derived | List, arrays | |
| Map[K, V] | derived | K, V | no | no | K, V | | |
| fn values | yes | no | no | no | no | | |
| Mutex[T] | if T | no | no | no | no | | |
| Task, Chan, `!` | no | no | no | no | no | | |
| own impl (records, enums) | any of the seven; Drop for records only | | | | | | |

`Ord` and `Hash` promise `Eq` (an own `Ord` or `Hash` on a type without `Eq` is E0601). Comparing
two `()`s directly stays E0401 ("cannot compare values of type ()").

**The operations.**

- **Copy**: `x.copy()` is a full clone: heap buffers are shared copy-on-write as by every copy,
  a Mutex inside gets a new Mutex holding a copy of the contents (locked while it is read), a
  part with its own `copy` is copied by it, and a record with its own Drop gets a buffer of its
  own. Task and Chan have no Copy, so `.copy()` on them or on anything holding them is E0601
  ("a running thread can't be cloned and a copied queue has no clear meaning; share the
  handle instead"). Implicit copies (binding, passing, storing: value semantics) stay the
  copy-on-write share and never run user code.
- **Eq**: `==`, `!=`, `x.eq(y)` and `List.contains`. Derived structurally. **Map equality**:
  two Maps are equal when they have the same keys, each with an equal value; the slots' order
  (which depends on the insertion history) is not part of the value. So Map[K, V] has Eq when V
  has it (K always does).
- **Ord**: `<` `<=` `>` `>=` and `x.compare(y) -> Ordering`. Integers by value, `false < true`,
  str and String by bytes (Unicode scalar order), records and tuples lexicographically by
  field, arrays and Lists lexicographically then by length, Box by contents, enums by variant
  order then payload. Maps have no order. Sorting is ordinary code over `T: Ord`
  (compiler/tests/run/traits_derived.ei sorts Strings, records and enums).
- **Hash**: Map keys are any type with Hash and Eq (E0701 says which part lacks which). The key
  types of before (integers, bool, str, String) hash bit for bit as before (`ei_hash_u64`,
  `ei_hash_str`), so lookups and probing are unchanged; other keys hash by combining their parts'
  hashes (`h = ei_hash_u64(h ^ part)`, from a fixed seed, with the tag for enums and the length
  for Lists). A key type with a part that has its own `==` but a derived hash is E0701 (equal
  keys must hash alike). `x.hash() -> u64`. Maps have no hash.
- **Show**: `fn show(self, inout out: String)` appends a value's text; `x.to_string() ->
  String` and `print(x)` go through it. Everything that printed before prints exactly as
  before (integers, bool, str, String, enums without payloads: same C, same text); the rest is
  derived: `P { x: 1, y: -2 }`, `Circle(3)`, `Dot`, `Some(Pair { a: 1, b: "x" })`, `(1, "one",
  true)`, `(5,)`, `[1, 2]`, `{"k": 1}` (slot order), `Box(...)`, `Ok(())`. Text inside another
  value is quoted, with `\"`, `\\`, `\n`, `\t`, `\r` escaped; on its own it is printed raw. Type
  and variant names are spelled as `print` spells variants (resolve.shown). An own Show is
  used wherever the value appears (`[#2!9, #1!5]` for a List of Jobs).
- **Iter**: `for x in e` over a type with its own Iter runs on a copy of e, owned by the loop
  (`it := e; loop { r := it.next(); if r is None break; x := r's item; body }`), so the
  original is unchanged; break, continue, return and `?` drop what they leave. Ranges, Lists
  and arrays keep their own loops (same IR, same C; since C303 a List's loop also runs over
  its own share of the List, "C8.20"). `I: Iter` is met by List, arrays and own impls.
- **Drop**: a record's own `drop` runs exactly once per value, when its last holder goes. A
  record with its own Drop is laid out as a pointer to a shared buffer holding its fields
  (`struct t_R { struct td_R *p; }`, made by `rnew_R`): every copy shares it (a count, as for
  Box), and the last drop runs `drop` and then drops the fields in declaration order (a holder
  that `drop` hands the value to keeps it alive; values in one scope go in reverse order of
  creation, as before). A write to a shared value first makes a copy of its own, through the
  type's own Copy if it has one (a resource type can make a new resource there), else field by
  field as any copy makes them; from then on there are two values, each dropped once. Across
  threads, every buffer a value reaches is made unique when it crosses (C8.1), so a value
  captured by a spawned closure, sent while still held, or handed out by `Mutex.get` crosses
  as a value of its own; a value created on a thread, sent without being kept, or kept in a
  Mutex is one value, dropped once. Drop is for records only, for all of their instances
  (`impl[T] Drop for R[T]`, no bounds), and `drop` can't declare capabilities, because it
  runs wherever the last holder goes (a closure's environment, another thread, a container's
  glue), where no `uses` could be checked (E0606); calling `.drop()` is E0115; such records
  can't cross the C boundary (E0803).

**Own impls and the orphan rule.** `impl Eq for Name { ... }` (or any of the seven) is allowed
only in the package that defines the type; a file in no package counts as the program's own
(so the tests' single files and their lib/ modules can). Anything else is **E0604**: a built-in
type ("defined by the language core"), a prelude type (Option, Result, Ordering), a type of
another package ("defined by package `geo`"), or a type parameter (`impl[T] Eq for T`). The
impl is then left out. A generic impl may have bounds (`impl[T: Show] Show for Tagged[T]`); it
applies to the instances that meet them. Lowering finds an own impl through ir.Ir.impls: after
every pending body, `scan_impls` instantiates the impl's method for every concrete record and
enum type the program made that has one (and the bodies that brings in), and the glue
(`eq_`, `cmp_`, `hash_`, `show_`, `copy_`, `drop_`, `uniq_`) calls it.

**Bounds in generic code.** A generic body may use an operation on a type parameter only when
its bounds promise it: `==` needs `T: Eq`, `<` and `compare` `T: Ord`, `print`/`show` `T:
Show`, `.copy()` `T: Copy`, `for` `T: Iter`, `List[T].contains` `T: Eq`, and `Map[K, V]`, also
in a signature, `K: Hash + Eq`; a call to a function with bounds passes them on. Otherwise
**E0605** "`==` needs `T: Eq`", with a fix that adds the bound (`: Eq` after the parameter, or ` +
Eq` after its last bound; the compile-fail runner holds every fix to compile). Instances are
checked with concrete types, which can't tell a T from the type it stands for, so the check is
a pass of its own (`abstract_bodies`): after every body, each generic declaration that has an
instance (prelude ones aside) is checked once more with its type parameters as `T_PARAM`
types, which have exactly what their bounds say (Ord and Hash promise Eq). The pass works on
a copy of the checker (a copy-on-write share of its state), keeps only its E0605s (everything
else it could find, the instances found, or will find, with real types) and is skipped
entirely in a program without generic instances (compiler/ itself). So E0605s come after
every other diagnostic of the program, each bound once per body, and a generic declaration
that is never used is still not checked.

**Codes.** New: E0604 (orphan rule), E0605 (missing bound, with a fix), E0606 (a Drop impl
that doesn't qualify). Changed messages (E0401, E0601, E0701): an operation on a type that
lacks the trait says which trait and which part, e.g. "`==` needs `Eq`, which List[Chan[i32]]
doesn't implement (its part Chan[i32] doesn't)", with a help for handles and fn values;
"Map[...] can't be a Map key: it doesn't implement `Hash`"; `for` over a type without Iter keeps
its message and its help now mentions Iter.

**Zero cost.** Derived operations are the glue there was (eq_, drop_, clone_, the Map glue,
print's own code), plus glue for what had none (cmp_, hash_ for new key types, show_, copy_).
The C of every program that compiled before is byte for byte the C it had: all 65 run tests,
examples and benchmarks, and eiderc's own (123,423 lines), compared against the seed with the
old prelude. Map equality, ordering, printing and copying of other types is new code; own
impls are calls. Benchmarks (`REPS=11 sh scripts/bench.sh target/eiderc-before:target/before
target/eiderc-next`, before = eiderc at 722b20e, 16 cores, gcc -O2, median wall time):
list_copies 3 ms / 3 ms, state 4 ms / 4 ms, str_append 4 ms / 4 ms, eiderc `emit-c
compiler/main.ei` (19,456 lines) 179 ms / 179 ms. The bounds pass costs nothing there (eiderc
has no generic instances); in a program with them it rechecks each used generic body once.

**Known limits.** A program that shadows a language trait can't implement that trait. Drop
and threads: a shared value that crosses to another thread becomes a copy (above), so a
resource meant to be shared across threads belongs in a Mutex. The order of a Map's printed
entries follows its slots (fixed for a given insertion history, not sorted). `main`'s `Err` is still printed only for the types C8.2 lists.

**Oracle changes** (`BLESS=1`, reviewed): only messages, positions unchanged. Tests whose
program became valid were changed to keep failing with the same code at the same place,
with a type that still lacks the trait (a Mutex, Chan, Task or fn value inside): e0401_*
for `==` on Maps, Lists of Maps and records holding Maps, `<` on Lists, tuples and bools,
printing records, payload enums, Lists and Options; e0701_* for List and record keys;
tests/checks' e0401_map_equality and e0701_list_as_key. e0603_bound_on_fn names traits that
don't exist (`Display`, `Order`), since `Show` and `Eq` now do; the pass test
s2_heap_generic_map_unify adds the `K: Hash + Eq` its `Map[K, V]` parameter now needs. The
IDE goldens count 28 more prelude symbols. The compile-fail coverage lines count 51 codes.

**Tests.** Run (compiler/tests/run, recorded output checked by hand): `traits_derived`
(printing, `==`, Map equality, ordering, sorting, `compare`, Map keys of records, enums,
tuples and Lists, hashing, `to_string`/`show`, `.copy()` with a Mutex inside), `traits_custom`
(own Eq + Hash as Map keys, own Ord sorting, own Show inside derived text, own Copy, a
generic impl with a bound), `traits_iter` (user iterators, owned items, break, continue,
return and `?` in the loop, nested loops, a generic iterator), `traits_drop` (once under
sharing, reverse order, `drop` before fields, copy on write with and without an own Copy, in
Lists, Maps, Boxes and Options, `?`/return/break/continue, threads: created there, sent
through a channel, replaced in a shared Mutex, captured), `traits_generic` (bounds met by
derived and own impls); every run is also leak-checked and run under the sanitizers.
Compile-fail: `e0604_*`, `e0605_*` (each fix compiles), `e0606_*`, `e0601_copy_*`,
`e0601_ord_without_eq`, `e0701_custom_eq_no_hash`, `e0115_drop_call`,
`e0602_iter_next_not_option`, `e0401_contains_no_eq`, `e0401_for_record_no_iter` in
compiler/tests/check/fail and one per new code in tests/checks; pass: `c84_traits_ok`,
`c84_shadow_ok`; several errors: compiler/tests/check/multi/traits.ei; packages:
compiler/tests/pkgs/app/orphan.ei (an impl for another package's type).

## C8.5: capabilities per package

Wave 2, item 8.5 ("Language work" item 5): `ffi` stops being a property of call chains and
becomes one of packages, so std callers write `uses fs`, never `uses ffi`, and the package
manager learns what a package can do from the compiler instead of scanning its text. Code:
check.ei (`needs_cap`, used by the capability checks of `call_decl` and `fn_as_value`),
resolve.ei ("capabilities per package": `package_caps`, `grant_diags`, `caps_json`), lock.ei
(`Manifest.grants`), main.ei (`eiderc caps`), core/sys.ei; eider-pkg's `caps.ei`.

**`ffi` stays inside its package.** A package is a module's package as resolve.ei knows it
(`Module.pkg`, "C8.3"); the files in no package and the prelude count as one package.

- Calling an `extern` function needs `ffi` in the caller's `uses` (E0201) and an `unsafe`
  block or `unsafe fn` (E0802), as before ("C7: FFI"): the function that crosses into C says
  so. Inside a package `ffi` propagates like any capability: a wrapper with `uses ffi` asks
  its callers in the same package for it (compiler/tests/check/fail/e0201_ffi_via_wrapper.ei
  is unchanged).
- Across a package boundary it doesn't: calling a function of another package (or using it
  as a value) needs the callee's capabilities **except** `ffi`. `unsafe` stays local: an
  `unsafe fn` of another package still needs `unsafe` at the call (E0802).
- The real capabilities (`io`, `fs`, `net`, `clock`, `threads`, ...) propagate across
  packages as before. So every function that reaches the OS declares what it does, down to
  core: core/sys.ei's wrappers declare their real capability next to `ffi` (`read_file`,
  `write_file`, `list_dir`, `kind`, `mkdir`, `remove`, `rename`, `symlink`, `cwd`,
  `realpath`: `fs`; `write_fd`, `read_fd`, `args`, `getenv`, `exit_now`: `io`; `run`: `io, fs,
  net`), and the buffer and text helpers (`lit`, `to_string`, `send`, `send_all`, `take`,
  `take_all`, `error_text`) only `ffi`, so they cost their callers nothing (without the real
  ones, `sys.read_file()` would have become callable with no capability at all). std was
  reviewed function by function and already declared the real ones: `fs` for files, `io` for
  the standard streams, the environment, the arguments and exiting, `io, fs, net` for running
  a program (a child can do anything); `bytes`, `fs.join`, `fs.normalize`, `fs.sort`,
  `proc.captured` and the like declare nothing.
- A `uses ffi` on a function of a package with no unmanaged code is accepted and means
  nothing outside its package (code written for the earlier rule; the migration below
  removes it). `comptime` may now call core's text helpers (`sys.lit`), which ask for nothing;
  the wrappers that reach the OS still need a capability, which comptime never has.

**A package's capability use** (`resolve.package_caps`), computed from the loaded program
after resolution (no checking needed, so it works on programs with errors): over the modules
of the package that the program loads, every capability named in the `uses` clause of a
function (free functions, methods, trait methods; not `test` blocks, which are checked with
every capability) other than `ffi`, plus `ffi` when the package has unmanaged code: an
`extern` function, an `unsafe fn` or an `unsafe` block. A word that isn't a capability is
E0203 where it is written and adds nothing. Each capability is kept with its first use
(function, file, line, column), in module load order, then item order (a method before its
impl); for an extern, `ffi` comes before the extern's own `uses`.

**Grants** (`resolve.grant_diags`, at the end of loading, after the import errors, so they
come before any checking error). The entry file's package is granted everything; `core` and
`std` are the toolchain's and need no grant (core is the one package the toolchain grants
`ffi`; std has no unmanaged code, and its real capabilities reach every caller through its
functions' `uses`). For every other package P that a module of package D imports (by name or
by path; D's first import of P in load order; D a package other than P), each capability P
uses must be in D's grant to P, the `uses = [...]` of `[deps.P]` in D's eider.toml (absent:
none). Otherwise **E0204**, at that import in D's file, once per (D, P, capability):

```
error[E0204]: package `fsdep` uses capability `fs` in `save` (fsdep.ei:5) but is only granted []
  --> app/main.ei:2:1
  help: to allow it, add "fs" to `uses` in [deps.fsdep] of <dir>/eider.toml
```

For `ffi` the message names the extern, the `unsafe fn` or the function holding the `unsafe`
block, and the help adds "(it declares `extern` functions: unmanaged code)" or "(it has
`unsafe` code: unmanaged code)". The help is text, not a machine-applicable fix: the edit is
in another file. Grants are per edge, so a dependency's dependency is held to the grant its
own eider.toml gives (in the store or .vendor copy). Imports from files in no package are not
held to grants (such a file is a program of its own; it can import packages only by path).

**`eiderc caps <file>`** loads the program as `check` does (an import that can't be loaded,
such as a dependency of a package checked on its own without a lock, is left out and not
reported: the command answers for what it can see) and prints one JSON line per (package,
capability) in the order above:
`{"package":"fsdep","dir":"<dir>","cap":"fs","kind":"uses","fn":"save","file":"fsdep.ei","line":5,"col":5}`,
where `kind` is `uses`, `extern` or `unsafe`, `fn` is `name` or `Type.name`, `file` is
relative to the package's directory, and a file in no package has `"package":""` and
`"dir":""` (and its path as `file`). It exits 0, or 2 when the file can't be read.

**eider-pkg** (`packages/pkg/caps.ei`) no longer scans text. After resolving, for every
locked package it runs `$EIDERC caps <dir>/<entry>` (its `main` when it has no entry module,
like the compiler's package; `EIDERC` defaults to `$EIDER_ROOT/target/eiderc`) and holds that
package's lines to its grant, with the messages it had (`package \`fsdep\` uses capability
\`fs\` (fsdep.ei:5) but is only granted []; to allow it, add "fs" to \`uses\` in its
[deps.fsdep] table`, plus the unmanaged-code note for `ffi`, now also for `unsafe`). What it
checks is what the compiler loads from that module, not every file in the directory: a
`tests/` program, a comment or a stray word no longer counts, and a module the entry imports
does. A package with neither file is left to the compiler, which checks every import at build
time anyway. `scripts/eider-pkg` sets `EIDERC` to the seed's compiler (`target/eiderc`),
which has `caps`.

**Migration, staged.** The seed still asks for `ffi` along call chains, and it builds
compiler/, std/, core/ and everything verify.sh builds with it (packages/, eider-pkg,
tests/run, tests/std, tests/checks). So:

1. Now (this item): the compiler has the rule, `eiderc caps` and E0204; core/sys.ei's
   wrappers declare their real capabilities (every caller already did, so the seed builds
   everything as before); the package fixtures grant what they use; eider-pkg asks the
   compiler. compiler/, std/, packages/, tests/ and examples/ keep their `uses ffi`, which the
   new compiler accepts. What only the new compiler builds is written without it: the new
   tests (compiler/tests/{check,run,pkgs}, tests/pkg/run.sh's programs) and eider-analyzer
   (built by compiler/ as the seed builds it), whose grants are now what the compiler reports
   (eiderc `io, fs, net, clock`, json nothing).
2. After the next seed: run `sh scripts/migrate-caps.sh compiler std packages tests` (it
   removes `ffi` from every `uses` clause of files without `extern` or `unsafe` and without a
   path import of such a file; core/sys.ei and the FFI tests keep theirs), fix the comments
   that quote a signature (ide.ei's `analyze`), BLESS the diagnostics whose fix columns move,
   change eider-pkg's `init` template to `uses io`, drop the `EIDERC` default from
   scripts/eider-pkg, the "`uses ffi` everywhere" rule from "Writing the compiler in today's
   Eider" and the known limit from LAYERS.md. test-compiler.sh ("migration") already runs the
   script on a copy of core, std, packages and compiler and holds the result to checking
   (compiler/main.ei, eider-pkg, the fuzzer) and to the package tests. The three tests/checks
   cases below need that seed to pass verify.sh's compile-fail leg: the seed doesn't check
   grants and asks for `ffi` where they have none.

**Tests.** compiler/tests/check/fail: `e0204_method_fs` (a grant of `io` to a package whose
method uses `fs`), `e0204_unsafe_fn` (an `unsafe fn` without an `ffi` grant),
`e0201_std_needs_fs_not_ffi`, `e0201_core_wrapper_needs_fs` and `e0201_core_os_needs_net`
(core/os.ei's `sock_open` from another package needs `net`; the fix adds the real
capability and then compiles); compiler/tests/check/pass/c85_std_without_ffi.ei (std's
bytes, env, fs, io and proc with the real capabilities only); tests/checks/fail:
`e0204_ungranted_fs`, `e0204_ungranted_ffi` (an extern granted only `io`) and
`e0802_unsafe_fn_other_package`; compiler/tests/run/caps_std.ei (files, streams and
arguments with `uses io, fs`); compiler/tests/pkgs: `grants_ok` (an extern package and an
`unsafe`-block package granted `ffi`, called without `uses ffi`), `grants_fs` (one E0204 per
capability, a method named `Log.show`), `grants_chain` (E0204 in a dependency, against its own
eider.toml) and `caps` (`eiderc caps` of a program); compiler/tests/unit/lock.ei (grants read
from eider.toml); tests/pkg/run.sh ("capability grants": an ungranted `fs` dependency is
refused by `add`, an extern package needs `ffi`, a module the entry imports counts and a test
program doesn't, `uses ffi` without unmanaged code and core need no grant, the granted
packages run without `uses ffi`, and a grant removed from eider.toml after the fetch is E0204
when building).

## C8.6: references by default

Wave 3, item 8.6 (docs/design/memory-model.md, "Bindings", "The protection rule", "Build
order" 2): `let` of a place refers to it, `let mut` is a mutable alias, fresh values are
owned, pattern bindings do the same, invalidating writes while a reference is alive are
errors with a fix, and `var` is deprecated with a mechanical rewrite. Code: check.ei's
"References" and "Migration of `var`" sections (and `let_ref`, `let_pat`, `compile_match`,
`arm_body`, `call_decl`'s exclusivity), parse.ei (`at_mut`), ir.ei (S_NOTE, S_CHECK),
lower.ei (S_CHECK), main.ei (`eiderc migrate-var`), scripts/migrate-var.sh. `compiler/`
uses none of the new syntax until the next seed.

**Bindings.**

- `let x = e` where e is a place rooted at a variable in scope (a variable, a field, an
  element, any chain of them: `orders[i].items[j]`) binds a read-only reference: x has no
  storage of its own; it names that place, whose indices are evaluated once, when x is bound
  (and bounds-checked then: S_CHECK). Every use of x reads the place as it is at that use,
  so x sees every write to it. Anything else (a call, a literal, a constructor, an
  operation, `if`/`match`/block, a field of a call's result) is fresh and owned, as before.
- `let mut x = place` is a mutable alias (Reading A): writes through x write the place, and
  writes to the place are seen through x. The place's variable must be writable (`var`,
  `let mut`, an `inout` parameter, a mutable alias); otherwise **E0307** "`let mut x` would
  be a mutable alias of `p`, which is read-only", with the fix `.copy()` after the
  initializer (when the type has Copy), and checking goes on as if the fix were there.
  `let mut x = fresh` is an ordinary mutable local.
- Pattern bindings: a `match`/`if let`/`let (..)` whose scrutinee is such a place binds
  references into it (into the payload of an enum: `Pending(o)`); `mut x` (a new pattern
  form: the contextual word `mut` before a binding) is a mutable alias into it, with E0307
  when the scrutinee's variable is read-only (fix: `.copy()` after the scrutinee). A fresh
  scrutinee's bindings own their parts, as before; `mut` makes them mutable.
- `mut` is a contextual word, not a keyword: it means `let mut` or `mut x` only when a name
  follows it, so `let mut = 1` still declares a variable named `mut`.
- Escapes are values: storing, returning, capturing (closures, `spawn`) or passing a
  reference into an owned position clones what it refers to, through the ordinary `take`
  (a copy-on-write share), silently. Passing a reference as an ordinary argument is a borrow
  as for any place.
- `for x in xs` keeps its own copy of each element (unchanged: the charter names `let` and
  pattern bindings only, and the body may still write or push to the List). Since C303 the
  loop runs over a snapshot of the List taken when it starts (as over an array or a Map,
  "C8.20"); before, it read the List place again at each iteration, so it saw the body's
  writes and pushes.
- `var` (deprecated) keeps making its own copy, so every existing `var` means what it did.
- Exclusivity (E0301) counts a reference as the variable its place is rooted at: `f(inout
  xs, o)` with `o = xs[0]` is E0301 "`o` refers into `xs`, which is borrowed mutably by
  another argument of this call" (fix: `.copy()` at o's binding), and `f(inout ys, inout
  xs)` with `ys` an alias of `xs` is E0301 too.
- Assigning to a `let` reference is E0303 as for any `let` (message, help and fix unchanged:
  the fix still says `var`, whose copy is what the old program meant).

**The protection rule** (E0308). While a reference is alive, until its last use on any
path, no write may free, move or reinterpret memory it points into. The checker notes in
the IR (S_NOTE, a checker-only statement) every reference's binding and use, and every
write that may invalidate one: an assignment (S_STORE), an `inout` argument (of a call, of
a method's `inout self`, of `show`), a resizing builtin (`push`, `pop`, `clear`, `insert`,
`remove`, `push_str`, `append`, `push_byte`); writes are noted only while a reference is in
scope, and never for temporaries. After every body, `protect` runs a backward liveness pass
over each function that has references (structured: both branches of an `if`, loops to a
fixed point, `break`/`continue`/`return`/`panic` cut the paths) and checks each noted write
against the references live after it. A write to place P invalidates a live reference to R
when P is a prefix of R, comparing any two indices as equal (the charter: `orders[i]` and a
resize of `orders` conflict whatever `i` is), and the rest of R's path goes through heap
memory (a List element, the fields of a record with its own Drop) or an enum payload. So:

- allowed: plain writes to scalar fields and elements, writes through aliases, a write that
  replaces the referenced value itself (`orders[0] = o2` while `o = orders[0]`: o then sees
  o2), a resize of a container a reference names rather than points into (`let all =
  orders; orders.push(x)`: all sees it), any write after the last use, a write on a path
  that never reaches a use (`if ... { xs.clear(); return }`), a loop body binding a new
  reference each iteration;
- errors: `xs.push` while a reference into `xs[..]` is alive; `xs = ...` or `inv = ...`
  while one points into their elements; `j = Done` while a binding refers into j's payload;
  `f(inout xs)` while one points into xs's elements.

E0308 "can't call `push` on `orders` while `o` refers into it" / "can't assign to `j`
while `name` refers into it" / "can't pass `xs` as `inout` while `a` refers into it", at the
write; help: "`o` is used after this change, which may free, move or replace what it refers
to; use it before the change, or bind a copy with `.copy()`"; fix: `.copy()` after the
reference's initializer (or its pattern's scrutinee), which makes the binding own a value.
No fix when the type lacks Copy (a Chan inside) or in a generic body (`.copy()` would also
need a `Copy` bound; the help says so). The E0308s come after every other diagnostic of the
program (they need every body), in source order per function, once per write.

**Lowering.** A reference is its place: lowering emits the place's C lvalue
(`orders.d[t3].qty`) at each use, with the index temporaries computed at the binding, and
copy-on-write uniqueness on the path before each write through an alias, exactly as for a
write to the place itself. No clone, no drop, no storage. A `let` of a place, a pattern
binding of a place and a `match` on a place no longer copy anything, so programs that used
`let` and `match` on places get smaller C with fewer clones and drops (below). Notes are
removed from the IR before checking ends; S_CHECK lowers to the place's bounds checks only.

**Choices the charter left open** (the simplest sound one each time):

1. A reference is the place re-derived at each use, not a C pointer variable. A pointer into
   a List's buffer would go stale when a plain write elsewhere on the path makes a shared
   buffer unique (copy-on-write moves it; the charter allows plain writes while references
   live), and refreshing pointers after every such write needs liveness in lowering. The
   re-derived place has the same cost as a pointer for paths through locals, fields and
   arrays (the C compiler computes the same address), and costs a bounds check per use
   through a List (one that never fails: the protection rule forbids the resize). C pointer
   variables for heap paths are the remaining step (below).
2. "Place" is syntactic: a variable, field or element chain rooted at a variable in scope.
   A field or element of a fresh value (`f().x`, `make()[0]`) is fresh.
3. The liveness is flow-sensitive but path-insensitive per structured block: a use on any
   path after the write counts; loops iterate to a fixed point.
4. A reference *to* a container (not into it) is not invalidated by resizing it, and a
   write that replaces exactly the referenced place is plain: the reference sees the new
   value. Only a heap or payload step between the write's place and the reference counts.
5. Records with their own Drop live in a shared buffer (C8.4), so their fields count as
   heap memory for the rule.
6. Fixes: always `.copy()` at the binding (the charter's "take a `.copy()` first"); never a
   fix in generic bodies or for types without Copy. For a mutable alias the help adds that
   writes then change only the copy.
7. E0303 keeps its message, help and fix (`var`) byte for byte (first-diagnostic rule; the
   fix keeps the old meaning).
8. `mut` is contextual, and per binding in patterns (`let (mut a, b)`), with no `let mut
   (a, b)` form (one way to do one thing).
9. `for` loop variables stay copies; Map values are never places (`get` returns a value),
   so nothing refers into a Map; Box contents are reached only through methods, so nothing
   refers into a Box either.
10. `var` is deprecated without a diagnostic: a warning would change the output of every
    program that uses it (and the first-diagnostic contract). The deprecation is the
    documented rewrite, `eiderc migrate-var` and scripts/migrate-var.sh.
11. Migration: `var x = place` becomes `let mut x = place.copy()` and `var x = fresh`
    `let mut x = fresh` (the charter), `var (a, b) = e` becomes `let (mut a, mut b) = e`
    (`.copy()` when e is a place). Not rewritten (left as `var`, which still works): a place
    whose `.copy()` differs from the implicit copy `var` made (a Mutex inside: `.copy()`
    makes a new one; a record with its own Drop: `.copy()` gives it a buffer of its own; an
    own Copy: `.copy()` runs it), a `var` of a place in a generic body (`.copy()` could need a bound; a fresh value there is rewritten),
    and code no concrete body checks.

**Migration of `var`.** `eiderc migrate-var <file>` prints the file with its rewrites; the
file is checked as the entry (a module without `main` is fine), else as the module a
one-line entry in its directory imports (a module whose names clash with the entry's
builtins, like compiler/lower.ei's `fn print`). scripts/migrate-var.sh runs it over files
and directories (EIDER_ROOT, EIDERC as for the other migrations). compiler/ keeps `var`
until the seed has 8.6 (the seed must build compiler/); test-compiler.sh ("migration")
runs the script on a copy of core, std, packages and compiler: no `var` is left in them,
compiler/main.ei, eider-pkg and the fuzzer check, the package tests pass, and the migrated
compiler, built by this one, emits byte-identical C for compiler/ (its meaning is
unchanged). compiler/tests/migrate/var.ei has the hand-checked expected rewrite (var.out).

**Existing code under the new meaning.** A `let` of a place whose place is written while the
binding is still used later now sees the write; under the old meaning it kept its copy. The
audit (`eiderc audit-refs`, below; first a throwaway build of the same check) found every
such site in the repository:
in compiler/ (114 bindings: `let start = l` before `step(inout l)`, `let d = c.t.defs[i]`
before `f(inout c, d)`, ...), std/fs.ei, packages (json, toml, pkg, fuzz) and the tests
(compiler/tests/run/{closures2,cow,inout,lists,maps,owned,text_cow,traits_*}.ei,
compiler/tests/check/pass/v0_language.ei, tests/run/order.ei). Each got `.copy()` at the
binding, which the seed also understands (8.4), so those programs mean what they meant under
both compilers; the sorts in compiler/tests/run/traits_{custom,derived,generic}.ei, whose
`let t = xs[j]` swap is generic, got the `+ Copy` bound E0605 asks for, and
compiler/tests/run/traits_drop.ei's "written while shared" cases use `var` (their point is
the implicit share, which `.copy()` of a record with its own Drop doesn't make). The recorded
outputs are unchanged. After that the audit reports only the new tests.

**Audit: `eiderc audit-refs <file> [--json]`.** For code written when `let` copied (other
branches, old packages): every write that changes what a live `let` or pattern reference
sees without invalidating it (an invalidating one is E0308), where the binding used to keep
its own copy and now sees the change. A write overlaps a reference when they have the same
root and one's path is a prefix of the other's (indices compared as equal); `let mut` and
`mut` aliases are left out (new code means the alias). Each finding is a `note[audit]`
(stderr, rendered like a diagnostic, then `audit-refs: N write(s) change what a reference
sees`) or, with `--json`, a JSON object per line on stdout like a diagnostic's, with
`"audit":"reference"` in place of `"error"` and the machine-applicable `.copy()` fix at
the binding (none in a generic body or for a type without Copy). The program's errors
follow (exit 1); findings alone exit 0. Applying every fix gives the old meaning back, under
both the seed and the new compiler. Test: compiler/tests/audit/refs.ei (a swap, a counter, a
record snapshot, a tuple pattern; a `.copy()` and a binding not used after the write are not
reported), and loop.ei (a push to the List a `for` runs over through a reference), against their hand-checked .out. Run on the whole repository after the merge of
layer/runtime (std/{time,atomic,sync,chan,task,event}.ei, std/fd, std/poll, tests/std,
tests/core, examples/ and the rest): 4 sites, all in std/event.ei (the timer heap's two
swaps and two ids read before `self` changes); and after the merge of layer/services
(packages/http, examples/kvstore): 3 sites in packages/http/parse.ei (`let m = p.m` before
`p.m = empty_msg()`, and two positions read before the parser moves on). All got `.copy()`;
nothing else, and nothing in examples/kvstore. After the merge of layer/std (stream, path,
strings, utf8, fmt, sort, deque, set, heap, encoding, testing): 4 findings and 3 E0301s in
generic code, which has no machine-applicable fix (`.copy()` of a `T` would need a bound):
swaps in std/heap.ei and std/sort.ei and a moved element in std/set.ei now bind with `var`
(the implicit share `let` made, no bound needed), and integer positions in std/heap.ei,
std/strings.ei and std/stream.ei got `.copy()`. One finding had no fix because the type has
no Copy: std/task.ei's `let k = t.kids` before `t.kids = List.new()` (a List of Tokens,
which hold a Chan) silently became the empty list, so cancelling a token no longer cancelled
its children and http's server test hung under this compiler; it binds with `var` now, and
the audit's help says to for such types. That finding was missed by the first sweep, which
only applied fixes, and is the reason for test-compiler.sh's "meaning" leg: tests/std, the
packages' and the examples' tests must give their .out under this compiler as well as the
seed. The `for x in r` over a reference r to a List kept r alive for the whole loop (the List
was read again each iteration), so a push to it in the body was reported too; since C303 the
loop takes a snapshot when it starts, which is r's last use there.

There is no way in 8.6 other than the deprecated `var` to take a share of a value without
Copy out of a place before replacing the place (`let k = t.kids; t.kids = List.new()`): a
`take`/`replace` accessor (8.15, projections) is the natural successor.

**Codes.** New: E0307 (a mutable alias of a read-only place), E0308 (the protection rule).
Changed: none of the existing messages; E0301 gains the two reference cases above.

**Oracle changes** (`BLESS=1`, reviewed): only additions: the new compile-fail cases and the
pass case in the runner outputs (tests/checks, compiler/tests/check), the coverage lines
(52 to 54 codes), the new cases' check.json and the multi case refs.check.{json,err}. No
recorded output of an existing program changed. The IR goldens (compiler/tests/ir: forms,
generics, heap, threads) lost the copies and drops of `let` and `match` on places (for
example `label` in heap.ir: one clone instead of two and a drop).

**Tests.** Run (hand-checked expected output, leak-free, sanitizers): compiler/tests/run/
refs.ei (references seeing writes, an index evaluated once, `let mut` aliases both ways,
fresh `let mut`, `.copy()` independence, escapes by return, push, closure capture, a
reference to the list itself, nested places through `inout`, `mut` payload aliases in
`match`, `if let`, tuple patterns of a place and of a fresh tuple, references bound again in
a loop that grows the list, `var` still copying); compiler/tests/run/traps.ei now also traps
an out-of-bounds reference that is never read (S_CHECK). Compile-fail (compiler/tests/check/
fail): `e0307_*` (parameter, `let` binding, reference, pattern binding, `let` pattern,
closure capture, `for` variable; every fix compiles), `e0308_*` (push, clear, pop,
assigning the list and the enclosing record, an enum payload in `match` and `if let`, an
`inout` argument and `inout self`, the next loop iteration, a mutable alias, a record with
its own Drop, through an alias of the list, no fix for a Chan and in a generic body),
`e0301_alias_read`, `e0301_alias_two_inout`, `e0303_assign_ref`; tests/checks:
`e0307_mut_alias_of_param`, `e0308_push_while_referenced`; pass: `c86_refs_ok` (what the
rule allows); several errors: compiler/tests/check/multi/refs.ei; parse:
compiler/tests/parse_ok/refs.ei (`let mut`, `mut` patterns, a variable named `mut`);
migration: compiler/tests/migrate/var.ei and test-compiler.sh's migration leg.

**Benchmarks** (`REPS=15 sh scripts/bench.sh target/eiderc-before:target/before target/eiderc-after`, before =
eiderc at b1aae4c, after = eiderc built by itself with C8.6, 16 cores, gcc -O2, median
wall time): list_copies 3 ms / 3 ms, state 4 ms / 4 ms, str_append 4 ms / 4 ms, eiderc
`emit-c compiler/main.ei` (20,570 lines) 178 ms / 181 ms. The compiler is 1.7% slower on
itself: compiler/ binds references almost everywhere, so the notes and the liveness pass run
for nearly every function (programs without references skip the pass).

The generated C is the same or smaller for every benchmark, tests/run program, example and
the compiler (19 programs, 7 byte-identical: those with no `let` or `match` of an owned
place): 137,817 to 137,518 lines in all, clone and drop call sites 7,750 to 7,486
(compiler/main.ei: 131,152 to 131,073 lines, 7,253 to 7,024; tests/run/heap.ei 147 to 134;
tests/bench/state.ei 76 to 74).

**Remaining.** C pointer variables for references through heap memory (re-derived on each
use today, choice 1): a pointer stays valid while the protection rule holds except across a
copy-on-write un-share, so it needs a refresh after each write on the reference's root while
it is alive (liveness in lowering), or a deep copy at the clones that share that root while
it is alive. Then, after the next seed: run scripts/migrate-var.sh on compiler/, std/,
core/, packages/, tests/ and examples/, drop `var` from "Writing the compiler in today's
Eider", and decide when `var` becomes an error.

## C8.7: `Ref[T]`

Item 8.7 (docs/design/memory-model.md, "Shared mutable state: `Ref[T]`", rule 4):
the shared mutable handle for one thread. Code: types.ei (T_REF, T_INOUT), check.ei's
"Ref[T]" section (`ref_new`, `ref_method`, `ref_in`, `not_sent`) and `lambda`/`call_value`
(closures with `inout` parameters), parse.ei (`fn(inout T)`, `|inout x|`), ir.ei
(B_REF_*), lower.ei's "Ref[T]" section (`ref_builtin`, `ref_new_glue`, and the Ref cases of
the drop, clone, copy and own glue), core/eider_rt.h (`ei_ref_*`). `compiler/` uses none of
it until the next seed.

**The API** (decision C120):

| Call | Type | Does |
|---|---|---|
| `Ref.new(v)` | `Ref[T]` | a new cell holding v (moved in); the type comes from v or the expected type |
| `r.read(f)` | `f: fn(T) -> R`, result R | runs f on a borrow of the value (no copy) |
| `r.update(f)` | `f: fn(inout T) -> R`, result R | runs f on the value itself; every holder sees the change |
| `r.get()` | T | a copy of the value (copy-on-write: a count, not a deep copy) |
| `r.set(v)` | () | replaces the value (v moved in; the old one dropped) |

```eider
type Ctx = { cache: Ref[Map[String, Answer]], rows: List[Row] }

fn lookup(ctx: Ctx, key: String) -> Option[Answer] { ctx.cache.read(|m| m.get(key)) }
fn remember(ctx: Ctx, key: String, a: Answer) { ctx.cache.update(|inout m| m.insert(key, a)) }
```

R is the closure's result type: from an expression body, or the call's expected type, or
`-> R` written on the closure; a block body with none of those is `()` (so
`r.update(|inout n| { n += 1 })` needs no annotation). `read` and `update` are the charter's
scoped access: nothing the closure is given outlives the call, so no reference into the cell
escapes. `get` and `set` are the two scoped accesses everyone writes by hand
(`read(|v| v)`, `update(|inout v| { v = x })`); they cost the same.

**Sharing.** Binding, passing, storing and capturing a Ref share it: the copies are holders
of one cell, and a change through any is seen by all. `r.copy()` (the `Copy` trait) is a new
Ref holding a copy of the value, when T has Copy (the charter's table: E0601 for a
`Ref[Chan[i32]]`). The value is dropped exactly once, when the last holder goes (a record
with its own Drop inside runs its `drop` then). A Ref has no `==`, order, hash or text (E0401
"`==` needs `Eq`, which Ref[i32] doesn't implement", with a help that says to compare what it
holds inside `read`). Cycles of Refs leak, as the charter says; a lint is 8.15's.

**Run-time conflict check.** A cell keeps an access state: the number of `read`s/`get`s in
progress, or "being updated" while an `update` or `set` runs. Overlaps trap (exit 101, the
usual `eider: runtime error: ... (file:line)`, line = the access that conflicts):

| In progress | `read`, `get`, `.copy()` | `update`, `set` |
|---|---|---|
| nothing | ok | ok |
| reads | ok (nested reads of one Ref are fine) | `Ref updated while it is being read` |
| an update | `Ref read while it is being updated` | `Ref updated while it is already being updated` |

This is Rust's `RefCell` rule, and the only one that keeps `update`'s `inout T` exclusive: a
read during an update would see the value half-changed, an update during a read would
change (or free, `l.clear()`) what the reader is looking at. Different Refs never conflict,
so `p.update(|inout x| { x += q.read(|y| y) })` is fine. A trap inside a test block leaves
the state set, as it leaves a Mutex locked (core/RUNTIME.md, "The test hook").

**Not sendable** (**E0411**, new): a Ref is counted without atomics and accessed without a
lock, so it can't reach another thread. The checker rejects, wherever the type is written
or inferred, a `Task[T]`, `Mutex[T]` or `Chan[T]` whose T holds a Ref anywhere in its parts
(records, enums, tuples, arrays, List, Map, Box: "Mutex can't hold State (its part
Ref[List[i32]]): a Ref is shared without a lock, so it can't cross to another thread", help:
"state that threads share goes in a `Mutex[T]` holding the value itself, not a Ref of it"), a
`Mutex.new` of such a value, a spawned closure returning one, and a closure written at
`spawn(...)` that captures a variable holding one. A fn value's type doesn't show its
captures, so a closure stored first and spawned later, or put in a `Mutex[fn() -> T]`, is
caught at run time instead: the glue that makes a value its own before it crosses a thread
(`own_`, C8.1) traps "a Ref can't be sent to another thread" when it meets a Ref. Mutex is the
cross-thread tool, with the same scoped shape.

**Closures with `inout` parameters.** `update` needs a closure that changes its argument, so
fn types and closures gain `inout` parameters (the charter's "closures change captured state
only through their own `inout` parameters or a `Ref`"):

- `fn(inout T, U) -> R` is a fn type whose first parameter is passed by reference
  (types.ei T_INOUT wraps the parameter type in the fn type's parameter list only);
  `|inout x| ...` and `|inout x: T| ...` declare such a parameter. Where the expected fn type
  is known, the closure must say `inout` exactly where it does (**E0304** "closure parameter
  `x` is `inout` here; write `|inout ...|`", with a fix, and the reverse).
- Calling a fn value with an `inout` parameter takes `inout place` there, as a named
  function does: E0304 with the fix when it is missing, E0303 for a read-only place, E0301
  for the same variable twice or read by another argument. The write counts for the
  protection rule (S_CALLV now notes its place arguments).
- In C the parameter is a pointer (`T *`), in the fn value's `call` and in the closure body,
  which accesses it like a named function's `inout` parameter.
- A named function with `inout` parameters still can't be used as a value (E0304, as
  before): only closures make such fn values for now.

**Lowering.** `Ref[T]` is `struct tr_<h> { struct tr_<h>_c *p; }`; p points at a shared
buffer of the core (core/RUNTIME.md, "Shared buffers": the holder count in the header, not
atomic) holding `struct tr_<h>_c { int64_t st; T v; }`. A copy is `ei_buf_inc`, a drop
`ei_buf_dec` and, at zero, the value's drop and `ei_buf_free`: the same cost as a Box, and no
atomics. Each access is inline C, no call:

```c
{ ei_ref_update_begin(&(r).p->st, 7); f.call(f.env, &(r).p->v); ei_ref_update_end(&(r).p->st); }
```

with `ei_ref_read_begin/end` (st counts reads) and `ei_ref_update_begin/end` (st = -1)
inline in eider_rt.h: one compare and an increment around the closure call. `set` drops
the old value after the access ends (its drop may use the Ref). `.copy()` is a `copy_` glue
that reads the value into a new cell. Nothing changes for a program without a Ref: no glue,
no runtime code is reached, and the C of every existing test, example and benchmark and of
eiderc itself is byte-identical (only the tests that print the error-code list change).

**Codes.** New: E0411. Messages of existing codes: E0304 (closure parameters and arguments,
above), E0306 (labels, "C8.22"), E0115 for an unknown method of a Ref lists its four.

**Syntax changes** (for the tree-sitter grammar): `function_type` parameters may start with
`inout`; `closure_parameter` may start with `inout`. `Ref` is a built-in generic type name
like `Box`.

**Tests.** Run: compiler/tests/run/refs_shared.ei (sharing, read/update/get/set, update's
result, `.copy()`, a record of Refs threaded by value, Lists and Strings in Refs, Drop once
at the last holder through a Ref log, nested access of different Refs and nested reads of
one, a graph of Refs, a List of Refs, closures with `inout` parameters called directly,
through a fn type and through a function; hand-checked .out, leak-free, sanitizers);
refs_conflict.ei and refs_conflict_{update,set,get,read}.ei (each overlap traps with its
message and line; the oracle records them). Compile-fail (compiler/tests/check/fail):
`e0411_mutex_of_ref`, `e0411_mutex_new_ref`, `e0411_chan_record_ref`,
`e0411_task_result_ref`, `e0411_spawn_captures_ref`, `e0304_closure_param_inout`,
`e0304_closure_param_not_inout`, `e0304_closure_arg_needs_inout`,
`e0303_closure_inout_read_only`, `e0301_closure_inout_twice`, `e0401_ref_equality`,
`e0401_ref_print`, `e0401_ref_update_type`, `e0401_ref_new_unit`, `e0401_ref_set_type`,
`e0115_ref_unknown_method`, `e0601_ref_copy_chan`; tests/checks/fail/e0411_ref_in_mutex.

**Benchmarks** (C8.7 to C8.25 together; `REPS=15 sh scripts/bench.sh target/eiderc-next
target/eiderc:target/before`, before = the seed at be17f87 with its core, gcc -O2, median wall
time): list_copies 3 / 3 ms, state 3 / 4 ms, str_append 4 / 4 ms (the generated C of every
benchmark is byte-identical, so these differ by noise only), eiderc `emit-c
compiler/main.ei` (22,356 lines) 200 / 197 ms.

**Remaining.** A named function with `inout` parameters as a fn value; `Ref` across the C
and WebAssembly export boundary (E0803/E0806 as for other handles); a cycle lint (8.15).

## C8.16: the seed bugs std found

Wave 4, item 8.16: the four bugs docs/std.md ("Compiler bugs found") reported against the
seed, each with a regression test. Code: lower.ei (`op`, `put_line`, `files_table`,
`shown_name`), check.ei (`name_fits`, `trap_file`), resolve.ei (`shown_path`), ir.ei
(`Fn.file`, `Ir.files`), core/eider_rt.{h,c} and core/wasm/eider_rt.c (`ei_set_files`).

1. **`()` read out of a payload.** A `()` local has no C variable (it is never declared or
   assigned), but an operand naming one was still printed as the variable, so a generic
   `T = ()` read out of a payload in a match arm (`Ok(v) => Ok(v)`) referred to an undeclared
   `lN`. An operand of type `()` or `!` now lowers to `0`, as the `()` literal does.
   Test: compiler/tests/run/bug_unit_generic.ei (generic match arms, `if let`, nested
   instances with `()` in either parameter).
2. **A type name in a generic signature matches only its type.** When a call's argument was
   unified with a parameter type written with type parameters (`Result[T, E]`), a name that
   isn't a type parameter (`E`) matched any type, so `plain(Ok(1): Result[i32, String])` was
   accepted and the C didn't compile. `unify_ast` now asks `name_fits`: a built-in type name
   must be that type, a non-generic record or enum must be that record or enum; a name that
   names nothing concrete there (`Self`, an unknown name, reported elsewhere) still fits
   anything. The error is the existing **E0401** "argument of type Result[i32, String] doesn't
   match parameter type `Result[T, E]`" (no new code: it is the mismatch E0401 already
   reports for the other shapes). The same function matches impl targets, so the parity
   quirk "a name in an impl target matches every type" is fixed with it: `impl Area for Sq`
   meets `T: Area` only for Sq (a call `total(5)` is now E0601 "type i32 doesn't implement
   trait `Area`" at the call, where it was E0115 inside the instance), and `impl W[i32]`'s
   methods apply to W[i32] only (E0115 on `W(true).twice()`). Tests:
   `e0401_generic_record_name`, `e0601_bound_name_target`, `e0601_bound_unmet_impl` (was
   e0115_bound_unmet_impl), `e0115_impl_args_name`; the two compile-pass tests that
   recorded the quirk (`s1_quirk_impl_concrete_args`, `s1_trait_quirk_name_target`) are gone.
3. **Traps name their own file.** The runtime knew one file (`ei_set_file`, the entry's), so
   a trap in an imported module named the entry file with the module's line. Every IR
   function now records its module (`ir.Fn.file`, set from the checker's module), and in a
   function of an imported module lowering passes the runtime `f * 2^20 + line` instead of
   the line (`put_line`), where f is the module's index. Generated `main` (and test `main`,
   and each exported library entry point) hands the runtime a table of file names after
   `ei_set_file` (`static const char *const ei_files[] = { 0, "lib/geo.ei", ... }`,
   `ei_set_files(ei_files, n)`), emitted only when some imported module has a trap line, so
   single-file programs get the C they had. `ei_trap` decodes the index; a line without one
   (and anything a program built by an older compiler passes) names the entry file as before,
   so core stays compatible with the seed. Names (`resolve.shown_path`) carry no machine
   path: a module of a package, found under the package's directory, is `<package>/<path in
   it>` (`std/testing.ei`, `core/prelude.ei`, `geo/util.ei`: std and core are packages), else
   a file under the toolchain root is relative to it, and anything else is the path
   diagnostics use (relative to the entry's directory). Limits:
   2047 modules and 2^20 lines per module; past them a trap names the entry file. Tests:
   compiler/tests/run/trap_module.ei (run: the module's panic), modules.ei's test of a
   module's failing test block (`lib/geo.ei:46`), tests/std/atomic_overflow (an overflow in
   std/atomic.ei; its seed output stays in .out, this compiler's is the new .next.out, which
   test-compiler.sh's meaning leg reads until the next seed), and the comptime cases below.
4. **Printing spells Eider names.** Derived Show (and `print` of a unit enum, `main`'s `Err`)
   printed a type or variant of an imported module by its C-level key (`stream__TimedOut`,
   `geo__South`). It now prints the name as its own module writes it (`TimedOut`, `South`;
   `shown_name`), as it always did for the entry module's types: printing is the value, not
   where it was declared (decision C61). Test: compiler/tests/run/bug_show_module.ei
   (variants with and without payloads, records, Lists, generics, Option and Result of them,
   `to_string`).

**Oracle changes** (`BLESS=1`, reviewed): compiler/tests/run/modules.run prints `South`,
`West`, `North`, `East` (was `geo__South` ...); modules.test names `compiler/tests/run/lib/
geo.ei:46` (was the entry's `modules.ei:46`); the comptime evaluator's trap in an imported
module names that module (e0807_comptime_mod_trap: `(compiler/tests/check/fail/../lib/
ct_trap.ei:2)`, was `(program:2)`) and a trap in the prelude names it (e0807_comptime_unwrap:
`(core/prelude.ei:26)`, was `(program:26)`); compiler/tests/pkgs/app/main.out prints `High`,
`Foot`, `Edge` (was `base__High` ...); the compile-fail runner output follows the renamed,
added and removed cases above. Nothing else changed.

## C8.17: string escapes

Wave 4, item 8.17 (docs/std.md "Needs the compiler", docs/services.md N2). Code: lex.ei
(`string`, `hex_escape`, `unicode_escape`, `utf8_push`, and the join in `run`).

**Escapes** in string literals, besides `\n`, `\t`, `\"` and `\\`:

| Escape | Means | Refused (E0001, at the backslash) |
|---|---|---|
| `\r` | carriage return (13) | |
| `\xNN` | the ASCII character NN: exactly two hex digits, either case, 01 to 7f | fewer than two digits; 80 to ff ("write a non-ASCII character as `\u{...}`"); 00 |
| `\u{H...}` | the Unicode scalar value H (one to six hex digits), UTF-8 encoded | no braces, no or more than six digits, a surrogate (d800 to dfff), above 10ffff, 0 |
| `\0` | | always: "a string can't contain NUL" |

NUL is refused in every spelling (`\0`, `\x00`, `\u{0}`) because a `str` is a NUL-terminated
C string (its length is `strlen`) and a String is UTF-8 text without NUL (std/strings and
`String.from_bytes` rely on it): a NUL would silently cut the text. Bytes that include 0
belong in a `List[u8]` (decision C60). `\xNN` stops at 7f for the same reason a String is
always valid UTF-8: a lone byte above 7f isn't (Rust's rule too).

**Adjacent literals** separated only by spaces on one line are one literal (`"GET / HTTP/1.1\r\n"
"Host: x\r\n"` is one token): it was a syntax error before, so no program changes meaning.
Literals on different lines are not joined: a string literal statement followed by another
on the next line is valid today (the last is the block's value), so joining across lines
would change programs; a continuation rule (inside parentheses, or a leading operator) is
left for a later decision.

**Syntax changes** (for the tree-sitter grammar, a separate repository): in the string
token, the escape alternatives become `\\[nrt"\\]`, `\\x[0-7][0-9a-fA-F]` and
`\\u\{[0-9a-fA-F]{1,6}\}` (`\0` stays an error); the grammar's string node may repeat
(`string: $ => repeat1($._string_literal)` on one line), or keep one literal per node and
leave joining to the compiler.

**Tests.** Run: compiler/tests/run/escapes.ei (`\r\n`, `\x41\x7f\x1b`, `\u{...}` of one to four
UTF-8 bytes up to 10FFFF, joined literals, a String built from joined literals, escaped
backslashes; hand-checked .out); lexer: compiler/tests/lex/escape_*.ei (each refusal, with
its position; the oracle records them) and compiler/tests/lex_ok/escapes.ei (the tokens: one
literal for three joined ones, two for literals on two lines). No oracle file changed.

## C8.18: type aliases

Wave 4, item 8.18 (docs/services.md N1). Code: parse.ei (`type_decl`), ast.ei (IType's `g`),
check.ei's "Type aliases" section (`alias_ty`, `alias_of`, `unify_alias`; pass 1 and 2 of
`run`, `resolve_ty`, `unify_ast`, `register_impl`), dump.ei.

`type Name = <type>` and `type Name[T, ...] = <type>` (any type but a record body `{...}`
or variants `| ...`, which keep their meaning) declare an alias: another name for the type,
not a new type. It is **transparent**: `type Id = u64` makes `Id` and `u64` the same type
everywhere (assignable both ways, the same methods, the same C), and a mismatch names the
type itself ("expected i32, found u64"). A generic alias is resolved at each use with its
parameters bound to the use's arguments (`type Table[T] = List[(String, T)]`); in a generic
signature its arguments take part in inference like any type's (`fn second[T](p: Pair[T])`
infers T from a `(i32, i32)`). `pub type` exports an alias like any type (E0801 for a
private one used from another module); it may name private types of its module (as a pub
function's signature may). Rules, each the simplest sound one (decision C62):

- An alias names a type only: it is not a constructor (`Pt(1)` for `type Pt = Point` is
  "unknown function"), it brings no variant names, and an `impl` can't name it (**E0111**
  "`Pt` is a type alias; an impl names the type itself": methods belong to the type).
- A non-generic alias's type is checked at its declaration (an unknown type in it is E0111
  there, in its own file); a generic one where it is used, like a generic type's fields.
- An alias can't refer to itself, directly or through other aliases (`type A = List[A]`,
  E0111 "type alias `A` refers to itself", with the help that a recursive type needs a record
  or an enum); recursion through a record or enum is fine.
- Type declarations still take no bounds, so `type M[K, V] = Map[K, List[V]]` is checked where
  it is applied (a key type parameter of a generic function needs `K: Hash + Eq` as for
  `Map` itself, E0605).

**Syntax changes** (for the tree-sitter grammar): `type_item` gains an alternative
`'type' name generics? '=' type` where `type` doesn't start with `{` or `|`. `type A = X | Y`
(an enum missing its first `|`) stays the E0001 "expected `|`" it was.

**Tests.** Run: compiler/tests/run/aliases.ei with lib/handlers.ei (scalar, tuple, List,
fn and Option aliases, generic aliases with one and two parameters, an alias inside a record
field, pub aliases and a generic alias of another module, a private alias in a pub
signature; hand-checked .out). Compile-fail (compiler/tests/check/fail): `e0111_alias_cycle`,
`e0111_alias_mutual_cycle`, `e0111_alias_needs_args`, `e0111_alias_unknown_target`,
`e0111_alias_impl_target`, `e0107_alias_duplicate`, `e0801_alias_private` (with
lib/alias_lib.ei), `e0401_alias_transparent`, `e0401_alias_generic_arg`. Parse:
compiler/tests/parse_ok/aliases.ei. compiler/tests/parse/enum_missing_pipe.ei became
`type A = X | Y` (same error, same position; `type A = X` is now an alias).

## C8.19: calling a function stored in a field

Wave 4, item 8.19 (docs/services.md N10). `x.f(args)` where x's type has a field `f` holding a
function calls it; this was already accepted (since S3, `method_call_in`), so the item is the
rule for a name that is both a field and a method, now stated and made consistent:

**A method wins.** `x.f(...)` is the method f when x's type has one: its own (an `impl`,
inherent or of a trait, that applies to the type), a built-in method, or a method of a
language trait the type has, derived ones included (`copy`, `eq`, `compare`, `hash`, `show`,
`to_string`). Only when there is none is a field f of function type called. The field of a
clashing name is called through a binding: `let h = x.f; h(args)` (decision C63). Before,
a derived trait method lost to a field of its name (`x.copy()` called a field `copy`), the
one inconsistency, now fixed; nothing in the repository relied on it. A field that isn't a
function stays E0115 ("type R has no method `v`"). Methods winning keeps every existing call
meaning what it meant (fields could already be named like methods, e.g. a `len` field with a
`len()` method), and a field never changes what a method call resolves to.

Test: compiler/tests/run/fn_fields.ei (a handler field of an alias type called from a method
and through a List element, a generic record's fn field, a field and a method of one name, a
field named like the derived `copy`; hand-checked .out).

## C8.20: iterating a Map

Wave 4, item 8.20 (docs/std.md "Iterating a Map", docs/services.md N9). Code: check.ei
(`for_each`, `for_pat`, `map_list_type`, `heap_method`'s Map part), parse.ei (`for (...)`),
ir.ei (B_MAP_KEYS, B_MAP_VALUES, B_MAP_ENTRIES), lower.ei (`map_lists`).

- `m.keys() -> List[K]`, `m.values() -> List[V]` and `m.entries() -> List[(K, V)]` are built-in
  Map methods: new Lists of copies (copy-on-write shares for heap data, so O(n) small copies).
- `for (k, v) in m` and `for e in m` (e a `(K, V)` tuple) iterate the pairs. The loop runs over
  `m.entries()` taken before it starts (owned by the loop, dropped after it, on every exit),
  so the body may insert into or remove from `m` and the loop still sees each pair from
  before exactly once (value semantics; a live view would make every resize during the loop
  an E0308).
- **Lists too** (C303, #81). `for x in xs` over a List runs over a snapshot of `xs` taken
  before the loop, like an array (copied) and a Map (its entries): the loop owns a share of
  the List (`take`, a copy-on-write count), reads its length and elements from that share,
  and drops it after the loop on every exit. A write, push, pop or clear of `xs` in the body
  changes `xs` (the first one un-shares it: one copy per loop that writes, none otherwise)
  and not what the loop walks. Before, the loop read the List place again at each
  iteration, so it saw later elements written and visited elements pushed (the language
  reference described that, while "C8.4"'s Iter said the loop runs on a copy); the snapshot is what the
  memory model's value semantics and the two other sequences mean, and a protection rule
  (no invalidating write to a List while it is walked) would have made every such push an
  E0308. A `for` over a reference now uses the reference once, at the start (the protection
  rule no longer keeps it alive through the loop). The audit for code that relied on the
  old behaviour (every write to the walked List inside the body, through a temporary
  audit-refs variant over every .ei file here and in the sibling repositories) found none
  outside compiler/tests/audit/loop.ei, whose finding is gone (C303). Tests:
  compiler/tests/run/for_snapshot.ei (element writes, push, pop, clear, an `inout` argument,
  a reference, a mutable alias, a List of records with break and continue, nested loops over
  one List; hand-checked .out, leak-free, sanitizers). The IR and C of a loop over a List
  place gain the share and its drop.
- `for` takes any irrefutable pattern, over every sequence (`for (n, (name, on)) in pairs`,
  `for (mut n, _) in ps`): each binding owns a copy of its part, as a `for` variable does
  (C8.6); a pattern that can fail is **E0101** "refutable pattern in `for`", a wrong shape
  the pattern errors `let` gives (E0410 ...).

**Order.** All four walk the slots in index order, so they agree with each other and with
`print` of the Map. The slot of a key depends only on its hash and the Map's insertion and
removal history, and hashing is unseeded today (`ei_hash_u64`, FNV-1a for text; C8.4), so the
order is the same on every run, build and platform for the same history (tests can pin it). It
is not sorted, and it is not insertion order. When Maps get a per-process random seed (the
C6 hardening, seeded SipHash: docs/std.md "Next"), the order will differ from run to run:
code that needs a stable order sorts the keys (std/sort), as compiler/tests/run/map_iter.ei
does, and nothing in the language promises more than "each pair once, in one order shared by
keys/values/entries/for/print of the same Map value" (decision C64).

`keys`, `values` and `entries` become built-in names, so an `impl Map[...]` method with one of
those names is E0116, as for `len` or `get` (no program in the repository has one).

**Syntax changes** (for the tree-sitter grammar): `for_statement` takes a pattern in
parentheses where it took a name: `'for' (identifier | tuple_pattern) 'in' expression block`.

**Tests.** Run: compiler/tests/run/map_iter.ei (`for (k, v)`, `for e`, the three methods and
their common order, a body that removes and inserts, an empty Map, Maps of records, tuple
patterns over a List, nested and with `mut`; hand-checked .out, leak-free, sanitizers).
Compile-fail: `e0101_for_refutable`, `e0410_for_pattern_shape`, `e0405_map_keys_args`,
`e0116_impl_map_keys`; e0401_heap_for_map (a Map wasn't iterable) became
`e0401_heap_for_box`. The `for` E0401 help now lists a Map: "iterate over a List, an array, a
Map, a range ..." (oracle: the three cases with that help).

## C8.15: take and replace

Wave 4, the `take`/`replace` part of item 8.15 (C8.6 "Choices the charter left open": the
successor of `var` for values without Copy). Code: check.ei (`take_replace`, reached from
`method_call_in`).

- `x.replace(v) -> T` moves the value out of the place x (a variable, field or element: no
  copy, not even a copy-on-write share) and moves v in; the result is the old value. Any
  type, including types without Copy (a record holding a Chan or a Task) and type parameters
  (`fn swap_out[T](inout slot: T, v: T) -> T { slot.replace(v) }`).
- `x.take() -> T` is `x.replace(empty)` for the types with an empty value: String (`""`),
  List and Map (empty), Option (`None`). On any other type it is E0115 "type P has no method
  `take`", with the help that names the four and `replace`. (C8.23 widened it to every type
  with a `Default`; on a type parameter it needs `T: Default`.)
- They are methods of every type that has no method of that name: a type's own `take` or
  `replace` (std/stream's BufReader has a `take`) wins, as C8.19 decides for every method
  name. They are not free functions, because `take` and `replace` are common function names
  (compiler/tests name functions `take` in entry files, where a built-in function name is
  reserved).
- x must be a writable place: a read-only binding is E0303 as for any write (`cannot modify
  `s``), a fresh value is E0303 "`List[i32].take` needs a place to move the value out of".
  The write is an assignment for the protection rule (E0308 while a reference points into
  x, compiler/tests/check/fail/e0308_take_while_referenced.ei).
- IR: `old := S_MOVE x; S_STORE x := new` (no S_DROP: the old value moved out, so nothing is
  dropped or copied); lowering un-shares the containers on x's path first, as for any write,
  so taking from a copy-on-write share leaves the other holder intact.

The pattern `let k = t.kids; t.kids = List.new()` that needed `var` (a copy) is now `let k =
t.kids.take()`. After the seed learned take/replace, std's 106 `var`s (none were left in
packages/ or examples/) moved to `let mut` with `take`/`replace` or `.copy()` case by case
(decision C100); 6 remain, shares of generic or Copy-less values out of read-only parameters
(std/sort's `var a = xs`, std/task's `var t = s` in its Lock closures).

Tests: compiler/tests/run/take_replace.ei (a List field of a recursive record, a String, a
Chan inside a List element, an `inout self` method, Option, Map, an integer, an own `take`
winning, a generic `replace` through `inout`, copy-on-write independence; hand-checked .out,
leak-free, sanitizers); compile-fail `e0115_take_no_empty`, `e0303_take_fresh`,
`e0303_replace_read_only`, `e0401_replace_type`, `e0308_take_while_referenced`.

## C8.21: error conversion for `?`

Wave 4, item 8.21 (roadmap P0.6, its compiler part; docs/std.md "Error conversions for `?`").
Code: core/prelude.ei (`trait From`), parse.ei (`impl_decl`), check.ei's "Error conversion"
section (`register_from`, `find_from`, `from_instance`, `from_call`) and `try_op`,
`instantiate` (instance names).

**The trait.** The prelude ends with `trait From { fn from(value: Source) -> Self }` (after
the operation traits, so no recorded prelude position moves; `Source` is a placeholder read
off each impl, as `Iter`'s `Item` is). It is the one trait that takes a type argument in an
impl: `impl From[E1] for E2 { fn from(value: E1) -> E2 { ... } }` (`-> Self` too; generic:
`impl[T] From[T] for Tagged[T]`). A target may convert from any number of sources, one impl
per source (E0107 for a second). As for the operation traits (C8.4):

- the orphan rule: only the package that defines the target implements `From` for it
  (**E0604**, "only the package that defines `String` can implement `From` for it"); the
  source may be any type;
- the method is exactly `fn from(value: Source) -> Target` (**E0602** otherwise, saying the
  expected signature), and it declares no capabilities (E0602 "`from` can't declare
  capabilities": `?` converts wherever it is written, as C8.4's `drop` runs wherever its
  value goes);
- `impl From for X` without the source is **E0603**; type arguments on any other trait are
  E0603 "trait `Show` takes no type arguments";
- a program whose entry module defines its own `From` trait shadows the prelude's (C8.4).

**`?`.** In a function returning `Result[T2, E2]`, `x?` on a `Result[T1, E1]` with E1 not E2
returns `Err(E2.from(e))` when some impl converts E1 into E2 (its type parameters bound by
both); the error value is moved out, borrowed by `from`, then dropped. Without one it stays
E0401 "`?` can't convert the error type A into B", which now has the help "implement
`From[A]` for B (in its package), or convert with `match`" when B is a record or enum (no
recorded case has one). Option's `?` is unchanged.

**Calls.** `E2.from(x)` checks x first and picks the impl whose source fits x's type (and the
expected type, for a generic target); none is E0401 "`E` has no `From` conversion from bool".
`from` is not an ordinary method of E2 (it isn't in the method table, so several impls never
clash), and its instances are named by source (`AppError.from[IoError]`).

No `Into`, no blanket conversions (`impl[T] From[T] for T`), no `Error` trait or context
chains yet: those are the std half of P0.6 (decision C66).

**Tests.** Run: compiler/tests/run/from_try.ei (two sources into one enum, `?` through both in
one function, no conversion when the types agree, explicit `AppError.from(...)` choosing by
argument, a generic target `Tagged[T]`; hand-checked .out, leak-free, sanitizers).
Compile-fail: `e0604_from_orphan`, `e0602_from_signature`, `e0602_from_caps`,
`e0603_from_no_source`, `e0603_trait_type_args`, `e0107_from_twice`, `e0401_from_call_no_impl`,
`e0401_try_no_from`. Oracle: the IDE goldens' prelude symbol count (90 to 93: the trait, its
method and its parameter), and compiler/tests/parse/impl_trait_not_name.ei, which named
`List[i32]` as a trait and now uses a tuple (`impl (i32, i32) for A`; same error, column 21)
since a generic trait name parses.

## C8.22: `while let` and labeled loops

Wave 4, item 8.22, first half (labeled loops below). `while let PAT = EXPR { body }` runs the body while EXPR (checked
again before each iteration) matches PAT, with PAT's bindings in scope; `break` and
`continue` are the loop's. Like `if let`, it is sugar the parser expands (parse.ei
`while_let`): `while true { match EXPR { PAT => { body } _ => { break } } }`, so the checker,
the protection rule, drops and lowering need nothing new, and a scrutinee that is a place
binds references into it as `match` does (C8.6). A value that doesn't match is consumed
like any match scrutinee (`while let Some((1, s)) = xs.pop()` drops the first pair that
isn't `(1, _)`).

**Syntax changes** (for the tree-sitter grammar): `while_statement` gains `'while' 'let'
pattern '=' expression block`.

Tests: compiler/tests/run/while_let.ei (popping a stack, `continue` and `break`, walking a
linked list through a Box, a refutable tuple pattern inside Some; hand-checked .out,
leak-free, sanitizers); parse: compiler/tests/parse_ok/while_let.ei (the expansion).

**Labeled loops** (the second half; decision C124). A `for` or `while` (also `while let`)
may be labeled with a name and a colon before its keyword; `break name` and `continue name`
leave or continue that loop from anywhere inside it, nested loops included:

```eider
rows: for i in 0..grid.len() {
    for j in 0..grid[i].len() {
        if grid[i][j] == want {
            found = Some((i, j))
            break rows
        }
        if grid[i][j] < 0 { continue rows }
    }
}
```

- **Syntax.** Go's and Zig's shape, not Rust's `'outer`: a label is an ordinary identifier, so
  the lexer needs no new token. `name: for` / `name: while` at the start of a statement is a
  label exactly when an identifier, a `:` and the keyword `for` or `while` follow each other
  (no statement could start that way before, so every valid program keeps its meaning);
  `break name` / `continue name` take the identifier on the same line (before, an
  identifier after `break` was a syntax error). Labels are their own namespace: a variable
  may have a label's name.
- **Rules.** The label must be one of an enclosing loop of the same function: otherwise
  E0306 "no enclosing loop is labeled `x`" (at the label; a closure is a function, so a
  closure's body can't leave a loop around the closure: E0306 as for a plain `break` there).
  A loop can't reuse the label of a loop around it (E0107 "label `outer` is already the label
  of an enclosing loop"); loops that don't enclose each other may share one. An unused label
  is fine. Without a label, `break`/`continue` are the innermost loop's, as before.
- **Drops.** A labeled exit drops everything the loops it leaves own, innermost first (the
  frames from the target loop's base), as `return` does for the function.
- **Checker.** `loop_labels` runs in step with `loop_bases`; `loop_exit` finds the target
  and emits S_BREAK/S_CONTINUE with `a` = how many loops it leaves besides the innermost
  (0 for every unlabeled exit and for a label naming the innermost loop, so the IR of every
  existing program is unchanged). The protection rule's liveness (`lv_block`, `lv_loop`)
  carries a stack of the live sets at each enclosing loop's `break` and `continue`, so a
  labeled exit continues where it really goes (compiler/tests/check/pass/
  c822_label_liveness.ei is accepted only because of that).
- **Lowering.** A loop that a nested loop continues gets the step label it already had for
  `continue` (`s<n>:` before its step; also when its step is empty), and the nested
  `continue name` is `goto s<n>`; a loop that a nested loop breaks out of gets a label right
  after it (`b<n>:;`) and the nested `break name` is `goto b<n>`. Labels are numbered per
  function; loops without labeled exits are emitted as before (`exits_to`).

**Syntax changes** (for the tree-sitter grammar): `labeled_statement: identifier ':'
(for_statement | while_statement)`; `break_statement` and `continue_statement` take an
optional `identifier`.

Tests: compiler/tests/run/labels.ei (`break` out of two loops in a search, `continue` of a
range loop and of a `while` (no step) from a nested loop, three levels with exits to the
middle and outer loops, a labeled `while let`, owned values in the loops left; hand-checked
.out, leak-free, sanitizers); compile-fail `e0306_unknown_label`, `e0306_label_of_sibling`,
`e0306_label_across_closure`, `e0107_label_shadowed`, `e0308_label_continue_inner`
(compiler/tests/check/fail) and tests/checks/fail/e0306_unknown_label; pass
`c822_label_reused`, `c822_label_liveness`; parse: compiler/tests/parse_ok/labels.ei.

## C8.23: `Default`

Wave 5 (roadmap "Default/From/Into/Error"; the successor C8.15 left for `take`). Code:
core/prelude.ei (`trait Default`), check.ei's "Operation traits" (TR_DEFAULT,
`lacks_default`), `take_replace`, `default_op`, `default_call`, `static_head_ty` and the
type-parameter branch of `method_call_in`; ir.ei (B_DEFAULT); lower.ei's "Default" section
(`default_expr`, `default_glue`).

**The trait.** The prelude ends with `trait Default { fn default() -> Self }` (after
`From`, so no recorded prelude position moves). It is the eighth operation trait (C8.4's
machinery: derived when the parts have it, an own impl replaces the derived one everywhere,
the orphan rule E0604, the exact signature E0602, a program's own `trait Default` shadows
it), and the only one whose method is an associated function (no `self`):

| Type | Default |
|---|---|
| integers, bool | `0`, `false` |
| str, String | `""` |
| `()` | `()` |
| List, Map | empty, whatever they hold |
| Option | `None`, whatever it holds |
| records | derived when every field has one: each field's default |
| tuples, arrays, Box | derived from the parts |
| other enums, Result | only an own `impl Default for E` (which variant is the default is a choice) |
| a record with its own Drop | only an own impl (a resource isn't made from nothing) |
| fn values, Task, Mutex, Chan, Ref | none |

**Calls.** `T.default()` with `T` a type name: `Config.default()`, `i32.default()`,
`Level.default()` (an own impl), and a generic type when the expected type gives its
arguments (`let xs: List[i32] = List.default()`; E0409 otherwise). In a generic body,
`T.default()` on a type parameter T needs `T: Default` (E0605 with the fix that adds the
bound), and a call of a function with that bound needs a type that has it (E0601 "type
Chan[i32] doesn't implement trait `Default` (required by `fresh`)"). A type without it is
E0601 at the call, naming the part that lacks it. `x.default()` is no call (E0115), as for
any associated function. This also makes associated functions of type parameters callable in
general: `T.make()` in a body generic over T calls the `make` of the type T stands for
(found the way `Type.make()` is), where it was E0110 "unknown name `T`" before.

**`take`.** `x.take()` is `x.replace(T.default())` for every type with a Default (decision
C126): it was String, List, Map and Option only. Those four keep exactly the IR and C they
had; the other types get their default from B_DEFAULT or their own `default`. On a type
without one it stays E0115, with the help "`take()` leaves the type's `Default` value
behind (...), and this type has none; implement `Default` for it, or use `x.replace(v)`".
On a type parameter it needs `T: Default` (E0605): before, `take` in a generic body
compiled for the instances whose type had an empty value and failed inside the others (the
hole C8.15 noted); now the body states the bound.

**Lowering.** `default_expr` writes the built-in defaults inline (`0`, `false`, `""`,
`ei_str_from("")`, `(T){0}` for an empty List or Map, the None literal), calls an own impl,
and otherwise a `default_T()` glue that fills each part (`T r = {0}; r.f0 = ...`). Nothing
changes for a program that doesn't call `default` or `take` on a new type: no glue, the same
C (checked for every run test, benchmark, example and eiderc itself).

**Oracle changes** (`BLESS=1`, reviewed): the IDE goldens' prelude symbol count (two more:
the trait and its method); compiler/tests/check/fail/e0115_take_no_empty.ei used a record of
an i32, which has a Default now, so it holds a Chan instead (same error, same position), and
its help is the new one.

**Tests.** Run: compiler/tests/run/defaults.ei (every built-in default, a derived record of
all of them, an own impl for an enum and for a record used inside a derived one, generic
`T.default()`, `take` in generic code with the bound, `take` of records, enums, integers and
tuples, the four of before; hand-checked .out, leak-free, sanitizers). Compile-fail
(compiler/tests/check/fail): `e0605_take_needs_default`, `e0605_default_needs_bound`,
`e0601_default_enum`, `e0601_default_part`, `e0601_default_bound_unmet`,
`e0601_default_drop_record`, `e0115_default_as_method`, `e0115_take_enum_no_default`,
`e0604_default_orphan`, `e0602_default_signature`, `e0409_default_generic_head`;
tests/checks/fail/e0605_take_type_param.

## C8.24: `Error`, `Failure` and context (std/error)

Roadmap P0.6, the language half after C8.21's `From` for `?`: an `Error` trait with a
message and a cause, error values that print their chain, and `.context(...)` that works
with `?` and `From`. Code: std/error.ei (new module); no compiler change.

```eider
import std.error

type ParseError = { line: u32, what: String }

impl error.Error for ParseError {
    fn message(self) -> String { self.what.copy() }
    fn source(self) -> Option[error.Failure] { None }
}

fn settings(text: String) -> Result[Config, error.Failure] {
    let port = parse_port(text)?                          // From: ParseError -> Failure
    let cfg = parse(text).context("parsing the config")?  // context around any Error
    Ok(cfg)
}
// an Err prints as `parsing the config: expected a number`
```

- **`trait Error { fn message(self) -> String  fn source(self) -> Option[Failure] }`**: what
  an error type implements to be reported and wrapped. `source` is the error under it, as a
  Failure: without dynamic types (P0.7) a cause can't be "any Error", so a chain is a chain
  of Failures, and `Failure.of(e)` turns any Error (with its sources) into one.
- **`type Failure = { message: String, cause: Option[Box[Failure]] }`**: an error as a chain
  of messages, outermost first. `Failure.new(msg)`, `f.wrap(msg)` (a new outer message),
  `f.chain()` (every message), `f.root()` (the innermost), `f.source()`; it implements
  Error itself, and Show prints `outer: inner: root`.
- **Context.** `r.context("...")` on a `Result[T, E]` with `E: Error` (E0601 "type bool
  doesn't implement trait `error.Error` (required by `Result.context`)" otherwise) is
  `Result[T, Failure]` with the message around the error; `r.with_context(|| ...)` makes
  the message only on an error (nothing runs on success); `o.context("...")` on an Option
  makes None a Failure. Wrapping a Failure in context keeps its chain (it is an Error).
- **`?` and From.** `impl[E: Error] From[E] for Failure`, so in a function returning
  `Result[T, Failure]` every `x?` on a `Result[_, E: Error]` converts (C8.21; a Failure
  passes unchanged). An application error converts from a Failure with its own
  `impl From[error.Failure] for AppError`, and then `?` goes on working across layers.

**Why std, not the prelude** (decision C127). (1) The prelude is compiled by the seed
whenever anything is built (scripts/ei builds the compiler with it), and the impls a
prelude Failure needs (its Show, its `From`) are impls of language traits for a prelude
type, which the orphan rule rejects in the prelude itself, so the prelude can't hold them
until a seed that exempts it; std/error compiles with the seed as it is (tests: it builds
with both). (2) Layering (LAYERS.md): the language part of P0.6, `?` converting through
`From`, is in the prelude (C8.21); how an error is reported (a chain of messages, the `: `
text) is library policy, which std owns and can change without a compiler release. (3) Zero
cost: a program that doesn't import std/error doesn't parse it, and one that does pays only
for what it calls (generic methods are instantiated on use; `with_context` builds nothing on
success).

Tests: compiler/tests/run/errors_context.ei (an Error impl with and without a source, `?`
through `From`, `.context` and `.with_context` on Results, `.context` on Options, the
chain, the root, a Failure into an application error by `From`, printing; hand-checked .out,
leak-free, sanitizers); compile-fail `e0601_context_needs_error`, `e0401_failure_no_from`.

**Remaining.** `dyn Error` causes (P0.7); `main` returning `Result[(), Failure]` printing
the chain (C8.2's list of printable `Err`s). (std's own errors implement `error.Error`
since C322: String, the errors of fs/io/proc, through an impl in std/error, and
stream.Error, strings.ParseError and encoding.DecodeError in their modules; docs/std.md
"Errors and std/error".)

## C8.25: method chains across lines

docs/services.md N13. Code: parse.ei (`at_chain_line`, `postfix`).

A line whose first token is `.` continues the expression of the line before it: the
newline (and any blank or comment-only lines between) is not a separator there.

```eider
let op = openapi.op("GET", "/users/:id")
    .summary("Get a user")
    .param(openapi.path("id", openapi.string()))
    // the success response
    .response(200, "the user", user_schema)
```

**The rule, precisely** (decision C128): in a postfix chain (after an operand, a call, an
index, a field or a method call), when the next token is a newline and the first token
after the run of newlines is `.`, the newlines are skipped and the chain goes on with that
`.`. Nothing else changes: a line ending with `.` is still an error (the field name must
follow on the same line), operators at the start of a line still start a new statement (a
line starting with `-` or `+` is a statement of its own today, so continuing there would
change programs), and `..` (a range) is another token. **No valid program changes
meaning**: no statement or expression can start with `.`, so before this a line starting
with `.` was always E0001 "expected an expression" (the seed reports exactly that for
compiler/tests/run/chains.ei).

**Syntax changes** (for the tree-sitter grammar): the newline is an extra (skipped) before
a `.` that continues a `field_expression`/`call_expression`, e.g. with an external scanner
that drops a newline whose next non-blank line starts with `.`.

Tests: compiler/tests/run/chains.ei (builder methods over several lines with a blank and a
comment line between, fields and tuple fields, a chain as a block's value and inside call
arguments, a line not starting with `.` ending the statement; hand-checked .out);
compiler/tests/parse_ok/chains.ei (the AST: one chain).

## C8.26: dotted imports

Issue #91 (decided with the user on 2026-10-31; C280-C287). Code: parse.ei ("dotted imports":
`dotted_import`, `qualified`), resolve.ei ("dotted imports": `locate_dotted`, `bind_alias`,
`import_fixes`, `migrate_imports`), ide.ei (`module_refs`, `use_tok`, `ns_at`), dump.ei.

Imports name modules by dotted paths instead of quoted file paths:

```eider
import core.sys
import std.{bytes, encoding, fs}   // a group
import std.encoding as enc         // an alias
import json                        // a dependency's entry module
import json.stream                 // a module inside a dependency
import std                         // the package namespace: std.bytes.split(...)
import pkg.manifest                // a module of your own package, by the package's name
```

**Syntax** (parse.ei). `import` followed by a string is the quoted form, as before.
Otherwise a module path: identifiers (not keywords) joined by `.`, then either `as name`,
or `.{ member, ... }` with each member a module path with its own optional `as` (newlines
and a trailing comma allowed inside the braces; a group is one IImport per member, at the
member's position), or nothing. The default alias is the last segment. `import std` and
`import core` (one segment, the toolchain packages) are namespaces. `*` where a segment or
the path should be (`import std.*`, `import * from std`) and `from` after a path (`import
bytes from std`) are E0001 with the help "name each module, or group them: `import
std.{bytes, fs}`; or import the package namespace, `import std`, and write
`std.bytes.eq(...)`". `from` stays an ordinary identifier (it is a method name: `From.from`).
An IImport's slot c is the form (IMPORT_QUOTED 0, IMPORT_DOTTED 1, IMPORT_NAMESPACE 2,
IMPORT_IMPLIED 3); a is the path with `/` between segments (`std/bytes`, the spelling of a
package import, so the resolver reuses `locate`); d/e where the path starts (for the quoted
form, the string token: the fix's position).

**Resolution, precisely** (resolve.ei `locate_dotted`), for `import s1.s2...sn` in module m:

1. `s1` is `std` or `core`: the toolchain's file `<root>/s1/s2/.../sn.ei`; one segment is
   the namespace.
2. m is in a package P (its eider.toml parses): `s1` must be P's own name or one of P's
   direct dependencies; then it is the package import `"s1/s2/.../sn"` of C8.3 (one
   segment: the entry module; through eider.lock for a dependency). `s1` both P's name and
   a dependency's is **E0812**. Anything else is E0809 "unknown module `a.b`: `a` is
   neither this package (`P`) nor one of its dependencies (<eider.toml>)"; when `a/b.ei`
   exists beside m or at P's top, the help is "this package's own modules are imported by
   its name: `import P.<path>`", else the `eider-pkg add` help.
3. m is in no package: the file `s1/s2/.../sn.ei` relative to m's directory (a sibling
   module by its name, `import util`; below it, `import lib.geo`). There is no way up
   (`"../lib/geo.ei"` stays quoted) and no package but std and core. The module's identity
   and name are those the path import of that file has (its stem), so nothing changes in C.

A missing file is **E0804** "unknown module `std.nope`" (help: there is no file <path>; in
no package, which file `import x.y` names). Module identity, names and C names are C8.3's:
the import form never enters them, so a program's C is byte-identical whichever form loads
its modules (test-compiler.sh "migration" holds the whole compiler to that).

**Aliases.** Two imports of one module with different aliases are fine, and so is one alias
for one module twice. A dotted import whose alias already names another module, or a
namespace (`import std` and `import foo.std`), is **E0813** at the second import ("the
alias `fs` already names another module (imported on line 3)"; help: `as`). The quoted form
keeps its old meaning (the later import wins), so no existing program breaks.

**Namespaces, loaded lazily.** `import std` binds `std` to no module (its Alias has prefix 0).
In an expression, type or pattern, `std . m . Name` (the parser's `qualified`, only when the
first identifier is a namespace alias of the file) is a qualified name whose qualifier is
the symbol `std.m` (a name no identifier can spell), and the first such use adds an implied
IImport of `std/m` with alias `std.m`, after the file's items; its Alias takes effect from
the namespace's import, its diagnostics are at the use. So a module behind a namespace is
loaded only when a use names it, and everything downstream (checking, `eiderc caps` and the
E0204 grants, `eiderc doc`'s links, ide.ei's refs, the modules a program loads) sees exactly
the modules used, through the ordinary import machinery. A namespace use names one module,
then an item: `std.encoding.base64` is not a module path in code (import it). Importing both
`std` and `std.bytes` is allowed: one module. Messages show the module's stem as before
(`strings.Builder`).

**The quoted form, deprecated silently.** It works as before and nothing reports it.
`import_fixes` computes, per quoted import, the dotted path that loads the same canonical
file (`dotted_of`: std/core, the importer's own package by its name, a declared
dependency by its name, or in no package the file below the importer's directory), checks
it through `locate_dotted`, and gives a machine-applicable fix (diag.Fix over the string
token; `as <old alias>` added when the default alias would change). `eiderc migrate-imports
<file>` prints the file with the fixes applied; `--json` prints them, one line each, in
diagnostics' fix format: `{"deprecated":"quoted-import","span":...,"message":"the quoted
import is deprecated: `import std.fs`","fix":{"at":...,"delete":N,"insert":"std.fs"}}`.
An import with no dotted form has no fix: a file outside the importer's package and its
dependencies, `..` from a file in no package, and a path segment that isn't an identifier or
is a keyword (compiler/comptime.ei).

**Migration** (`scripts/migrate-imports-dotted.sh [--keep-seed] <file or dir>...`, which runs
`eiderc migrate-imports` on every .ei with a quoted import and lists what stays quoted).
First with `--keep-seed` (#91): core, std, packages, tests and examples of eider-lang, every
sibling repository (eider-toml, eider-json, eider-markdown, eider-http, eider-rpc,
eider-openapi, eider-profiler, eider-analyzer), re-vendored (into what is now .vendor/, pinned by vendor.lock), the docs'
code blocks and tests/pkg/run.sh's generated programs, leaving quoted what the seed then built
the compiler from: compiler/, std/{bytes,fs,io,env,proc}.ei and core/{sys,version}.ei, with
scripts/eider-pkg and scripts/docs.sh building with compiler/ as the seed built it
(target/eiderc-next) while the seed had no `migrate-imports`. Then, after the seed that
knows dotted imports (#95): `sh scripts/migrate-imports-dotted.sh compiler std core`, the
compiler's tests with them; compiler/comptime.ei renamed consteval.ei (`comptime` is a
keyword, so no module path names it; it was only ever imported as `consteval`), now `import
eiderc.consteval`, which changed that module's C names once; the fallbacks in
scripts/eider-pkg and docs.sh's `migrate-imports` probe dropped (docs.sh still falls back to
target/eiderc-next when the seed's `eiderc doc` fails); the goldens that quote an import or
point at its span blessed (compiler/tests/parse_ok/*.ast, ide/*.ide, pkgs/app/grants_fs.out
and ide.out); the seed regenerated.

Kept on purpose, and listed in `scripts/check-imports.sh` (verify's "imports" leg, which fails
on any other quoted import in an .ei file or a page, and on a listed file that has none
left): the compiler's tests of the quoted form (compiler/tests: its parse, the diagnostics
reached through it, IDE spans, package imports the migration can't rewrite), tests/checks's
e0804_missing_module and e0809_not_a_dependency, errors.md's E0809 example, and
tests/crypto's imports from a file in no package upward (`"../../packages/crypto/crypto.ei"`).
The entry eiderc doc and migrate-var generate stays quoted (internal).

**When the quoted form becomes an error** (C361): it stays accepted with no warning through
0.1.x; from 0.2.0 eiderc warns on each quoted import, with the `migrate-imports` fix attached
(an analyzer quick fix); it is an error (E0001 with the fix) from 0.3.0, and the parser's
quoted path, `import_fixes` and E0809's quoted-only cases go then.

**Style** (docs/site/reference/modules.md): import the modules a file uses heavily directly
(`import std.{bytes, fs}`), and reach occasional ones through the namespace
(`std.time.mono_ms()`).

**Tests.** tests/checks: e0001_import_wildcard, e0001_import_from, e0804_unknown_module,
e0804_unknown_module_namespace (a use through the namespace), e0812_ambiguous_package (with
lib/selfdep, a package that depends on itself), e0813_alias_clash, and
pass/pass_dotted_imports (group across lines, alias, sibling module, namespace, a type and a
pattern through it). compiler/tests/pkgs/app: dotted (run: entry and inner modules of
dependencies, own module by name, vendored and stored git packages, namespace),
dotted_caps (`eiderc caps` reports only the std modules a namespace use loads),
dotted_own and dotted_unknown (E0809's two helps). compiler/tests/ide/dotted (refs from
import segments and aliases, group members, and the module segment of a namespace use;
compiler/tests is in package eiderc, so it imports `eiderc.tests.ide.lib.shapes`).
compiler/tests/doc/shapes/util/ns.ei (a signature through the namespace links to
std/time#Duration). compiler/tests/parse/import_no_path.ei is now `import 42` (`import
util` is valid). test-compiler.sh "migration": the dotted rewrite of the copy of core,
std, packages and compiler leaves only the comptime import quoted, and this compiler's C for
the migrated compiler equals its C for compiler/.

**Syntax changes** (for the grammar and the analyzer): tree-sitter-eider 0.1.1
(`import_declaration` with `path: (module_path (identifier)+)`, `alias:`, `group:
(import_group (import_member path: alias:)+)`; `scoped_type_identifier` with several
`path:` qualifiers for `std.bytes.Buf`); eider-analyzer 0.1.1 (the stand-in, completion of
module paths after `import` and in `{}`, hover and definition on path segments).

## C8.27: incremental builds

Issue #129 (U25, decided with the user on 2026-10-31; C380-C397). Code: build.ei (units, the
object and link caches, the job runner, eviction), llvm_units.ei (the LLVM module cut into
units), driver.ei (each backend's units, ThinLTO), main.ei (`-j`, `eiderc cache`), sha256.ei
(streaming, with bitwise operators). LLVM is the only backend from #125/#128 on (U23), so the
units are LLVM's; the C backend, until #128 removes it, builds as three units (its program's
C and the C core's two sources) through the same cache.

Before: the front end is whole-program and its output is one translation unit, compiled by
one `cc` and cached as one binary (`bin/<key>`, key over the whole generated text). Any
edit anywhere recompiles everything; building eiderc at -O2 is one 30 s gcc process on 4.7 MB
of C while 15 cores idle, and even a no-op rebuild hashed the 4.7 MB at 50 ns a byte (0.23 s
of its 0.52 s).

### Units

A **unit** is the smallest thing compiled and cached on its own: a text the backend produced,
the command that compiles it, and the extra key parts its object depends on (build.ei
`Unit`). The backend decides the boundaries; build.ei never looks inside a unit. The
boundaries are chosen so that a unit's text changes only when something its object really
depends on changes. For the LLVM backend (llvm_units.split; `run`, `test` and `build`):

| unit | contains | its text changes when |
|---|---|---|
| `mod.<n>` (one per module) | the functions whose body comes from module n (`Ir.fns[f].file`), its closures and the C-convention wrappers of its functions | that module's source changes, or the layout or signature of something it uses |
| `inst.<k>` (16 shards) | the monomorphized generic instances (an IR name with `[`), shard `hash(IR name) mod 16`, whatever module instantiated them | an instance of that shard is added, removed or changes |
| `glue` | the per-type glue, `main`, the test driver, the exports (llvm.GLUE, since #128) | the set of glue, tests or exports changes |
| `eider_rt`, `eider_core` | the C core | the core or the flags change (so: almost never) |

For eiderc that is 44 LLVM units (27 modules with functions, 16 shards, the glue) and the
core: 46 objects. Why shards for instances rather than "with the module that uses them": an
instance such as `List[String].push` is used by many modules; put with its user it would be
compiled once per user and invalidated by every edit to any user, and a unit of its own per
instance would be thousands of compiler processes. Hash shards keep each instance in exactly
one unit whatever uses it, so editing `diag.ei` recompiles `mod.<diag>` and nothing else,
unless the edit adds an instance (its shard changes) or changes a type's layout (the units
that use the type change, as they must). 16 shards (C383): eiderc has ~1,400 functions, and
16 keeps 16 cores busy on a cold build. Since #128 the per-type glue is IR, in one `glue`
unit (sharding it like the instances, by the type's stable name, is a later step).

The split works on the module's text (llvm.ei records which IR function each part of
`Out.ll` is, `Out.owner`; C392). Each unit is a complete module: `source_filename` (the unit's
name), the named types it uses closed over the types they mention, its functions, the private
constants it uses (copied into every unit that uses them: they are `private unnamed_addr`),
and a declaration of every function it calls that is defined elsewhere: from that
function's own `define` line (`declare hidden ...`) for another unit's, the module's
`declare` lines for the core's and the intrinsics. A constant can name others (a table of
names, the trap files): the unit gets them too. A function another unit calls
becomes `define hidden` (external in its object, invisible outside the program); the rest
stay `internal`, so -O2 still sees most functions as local. So that an edit stays local, a
unit's text holds nothing numbered program-wide: the types (`%t<type id>`, numbered by the
program's type table, which an edit anywhere can renumber) become `%T<k>` and the constants
(`@.s<string index>`, `@.m<n>`) `@.c<k>`, both numbered by first use in the unit (C393).
Function names are already stable (constraint 1 of "Compile speed"). What remains numbered:
trap lines encode `file index * 2^20 + line` with the module's position in the program
("C8.16"), so an edit that adds or removes a module renumbers the units of the modules after
it (C394; a per-module file symbol would fix it, with #128's trap table).

The units are the whole module's text rearranged, every function unchanged but for those
names and its linkage, so the program is the same: the 407 runs of scripts/llvm-diff.sh
(-O0, -O2 with ThinLTO, allocation counts, ASan+UBSan) are byte-identical to the C backend
through units, and the eiderc built from units emits byte-identical C and LLVM IR for
compiler/main.ei. Not split: `-g` (one DWARF compile unit; splitting the metadata is later),
`build --lib`, and `EIDER_LLVM_UNITS=0` (the whole module as one unit, for comparison).

An object must not depend on where it was compiled, or ThinLTO's output (which reads every
module's identifier) would differ between two caches: build.compile writes each generated
text to a directory of its own (`u<n>/<name><ext>`) and compiles it from there by relative
names (C395). `-j 1` and `-j 8`, and two caches, give byte-identical programs (tested).

### The cache key and layout

Keys are SHA-256 (sha256.ei) over length-prefixed parts (`build.key`: `<len>:<bytes>` for each
part, streamed, so a key over large parts concatenates nothing). sha256.ei now uses the
bitwise operators (C8.2, which the seed has): 4.7 ms per MB instead of 52 ms (C381).

```
<cache>/                     $EIDER_CACHE, else $XDG_CACHE_HOME/eider, else ~/.cache/eider
  obj/<k2>/<key>.o           a unit's object
  bin/<k2>/<key>             a linked program
  lto/                       lld's ThinLTO cache (release builds; lld prunes it)
  tmp/eiderc-<ms>-<n>/       one work directory per process
  trimmed                    stamp: when the size limit was last applied
```

`<k2>` is the key's first two hex digits, so no directory grows past a few hundred entries
(fs.list sorts its listing). The unit key covers, in order: the format tag `eiderc unit 2`,
the compiler's identity (`build.tool_id`: `<cc> --version` and `LIBRARY_PATH`, `CPATH`,
`C_INCLUDE_PATH`), the whole compile command (compiler, every flag, `EIDER_CFLAGS`, `-I`
path, target and `-O` level), the unit's extra parts (the bytes of the headers it includes:
`eider_rt.h`, `eider_core_ext.h`, `eider_prof.c` when profiling), its extension and its text.
The text already holds everything else the object depends on (the target triple and data
layout in LLVM IR; file names for traps), so the eiderc version is not a part: two eiderc
versions that emit the same text share the object. The link key covers `eiderc link 2`, the
linker's identity, the link command, every object's key in link order and the arguments after
the objects (`-l` libraries). Not in any key, as before: the contents of `-l` libraries and of
system headers beyond what `--version` identifies.

A hit costs a stat and a `fd.touch` (the entry's time is its last use, for eviction); a
no-op rebuild of eiderc (three units with the C backend) hashes 4.7 MB in ~25 ms and links
nothing.

### Parallel compilation

`build.compile` computes every unit's key, takes the hits, writes the misses' texts to the
work directory and gives their commands to `build.run_jobs`, which keeps at most `-j N`
running (child processes through std/child: start, `try_wait` with a back-off of 1 to 8 ms,
`wait` for the last one; the compiler has no threads, "Writing the compiler in today's
Eider"). The default is `$EIDER_JOBS`, else the CPUs this process may run on: Linux's
`Cpus_allowed_list` (so `taskset` counts), capped by a cgroup v2 quota (`cpu.max`, so a
container's limit counts), else the online CPUs, else 1 (`build.cpus`). Each object is renamed
into the cache as soon as all compiles succeeded; the first failing unit (in unit order, not
completion order, so the message doesn't depend on timing) is reported, its source kept in the
work directory. Compilers' output goes to eiderc's stdout and stderr (interleaved when
several fail), or to /dev/null for comptime evaluators. `-j 1` and `-j 8` make byte-identical
objects and programs (tested).

### Linking

`build.link` links the objects (in unit order) with the compile command's compiler and flags
and then the `-l` libraries; with the cache on, the program is a cache entry (`bin/`), keyed
as above, so a no-op rebuild runs no compiler and no linker. `build` copies it out, `run`
executes it in place, as before. Debug builds link with `$CC`'s default linker: linking
eiderc's 48 objects is ~0.1 s of its 0.9 s edit (lld would save part of that; later). A library (`build --lib`) archives the same objects (`ar`) and links them
`-shared`; it is not cached as a whole (it is written next to `-o`).

### Release builds: ThinLTO and lld's cache

Before #129 a release LLVM build was full LTO over one module (`-flto`, with lld or gold):
single-threaded, ~30 s for eiderc, and every edit redid all of it. Now (C396) a release build
compiles each LLVM unit with `-flto=thin` (the unit object is bitcode with a
summary, still cached by its text) and links with

```
clang <cc flags> -flto=thin -fuse-ld=lld \
  -Wl,--thinlto-jobs=<-j> \
  -Wl,--thinlto-cache-dir=<cache>/lto \
  -Wl,--thinlto-cache-policy=prune_interval=15m:prune_after=168h:cache_size_bytes=<limit/4>
```

ThinLTO optimizes every module in parallel, importing across modules what the summaries say
is worth inlining (the glue into the modules' functions); lld's cache keys each
module's optimized object by the module's hash and everything imported into it, so after an
edit only the edited module and the modules that import from it are optimized again; the rest
come from `lto/`. The job count and the cache flags are not part of the link key (build.link
`nokey`): they don't change the program. lld prunes `lto/` itself under the policy above;
`eiderc cache trim` counts its size but leaves it to lld, `clean` removes it. Without lld
(probed with a one-line `-flto=thin -fuse-ld=lld` link; gold is no longer used), with
`EIDER_LLVM_LTO=0` or when EIDER_CFLAGS ends with -O0, a release build links native -O2
objects. The C core stays native objects.

### Eviction and size limits

`EIDER_CACHE_MAX` (bytes, or with `K`, `M`, `G`, powers of 1024; default 5 GiB, `0`: no limit)
bounds the cache. After a build that added entries, `build.maybe_trim` applies it when the
stamp `<cache>/trimmed` is missing or older than 15 minutes (it touches the stamp first, so
concurrent builds don't all walk the cache): the least recently used objects and programs
(oldest `mtime`; every hit touches its entry) are removed until the cache is under 90% of the
limit, so the next builds don't trim again at once. Work directories older than a day (left by
a process that was killed) go too, and entries of the layout before C8.27 (`core/<key>/`)
always. `eiderc cache size` prints each kind's files and bytes, the total and the limit;
`eiderc cache trim` applies the limit now; `eiderc cache clean` removes every entry (work
directories of running builds stay). A cold -O2 build of eiderc adds ~2.5 MB of objects and
~2 MB of program with the C backend, so 5 GiB holds well over a thousand builds' distinct
entries (phase 2 measures the LLVM units' sizes).

### Concurrency

Every entry is made in the process's own work directory (an exclusive mkdir) and renamed into
place, as the driver already did: a concurrent eiderc sees no entry or a complete one, two
processes making the same entry both succeed and the last rename wins (the files are
identical, the key being their content). Eviction can't make that safe by renaming alone,
because it removes what another build may be about to link: so `trim` never removes an entry
used in the last 10 minutes (`GRACE_MS`; a hit touches the entry before the link reads it),
re-stats each candidate just before removing it, and a link that fails while one of its
objects has vanished (a `cache clean` at the wrong moment) compiles the missing units again and
links once more (`driver.build_units`). Tested: twelve concurrent runs of one program on an
empty cache, eight parallel builds of four programs into one cache (one object per program
plus the core's two, no work directory left), and the LRU and automatic trims.

### The front-end cache

The front end is whole-program (resolve, check and lower see every module). The issue asks
for a per-module cache of parse and resolve results keyed by file hash first. Measured with
`scripts/frontend-bench.sh` (compiler/tests/bench/frontend.ei; 2026-10-31, 16 cores, medians
of 5 runs, -O2 eiderc), against the lower bound of reading a parse back: every module's AST
nodes, extra words and tokens as little-endian u32s, read and decoded into the same Lists, with
no symbol remapping, kinds or strings (so a real cache can only be slower):

| program | modules | source | load (lex, parse, resolve) | lex+parse alone | SHA-256 of the sources | consteval+check | cached parse: bytes | read+decode |
|---|---|---|---|---|---|---|---|---|
| compiler/main.ei | 38 | 1.05 MB | 66 ms | 49 ms | 3.5 ms | 85 ms | 19.3 MB | 109 ms |
| every std module (compiler/tests/bench/allstd.ei) | 35 | 0.25 MB | 16 ms | 8 ms | 0.8 ms | 12 ms | 3.8 MB | 20 ms |

The lexer and parser run at ~45 ns a byte; a parse is ~18 bytes per source byte (an AST node
is 15 words, a token 8), and decoding it in Eider costs more than making it. A parse cache
would be 2.2-2.4 times slower than parsing again, before symbol remapping (the interner is
program-wide, so a cached module's symbol ids would have to be renumbered by node kind),
which is also where it would be fragile. Not built (C389); file hashing (3.5 ms per MB) is
cheap and is what the next step uses.

What would pay instead, kept for later:

1. **A whole-program manifest** (the no-op build). Key: the command, its flags, the entry's
   canonical path, the eiderc binary's identity and the variables resolve reads (`EIDER_ROOT`,
   `EIDER_HOME`). Value: every file resolve read (path, SHA-256: modules, the prelude,
   eider.toml, eider.lock) and every path it probed and found missing (a new `eider.toml` above
   a module, a module that would now shadow another), plus the backend's unit keys and the
   link key. On a hit with every file unchanged and every probe still missing, the build is the
   link-cache entry: no front end at all (today a no-op build of eiderc is ~0.25 s of front end
   and lowering, 0.03 s of hashing). The hard part is recording the probes: resolve's file
   access would go through `resolve.Files` everywhere (it does for module texts already) so
   the manifest sees every probe.
2. **Per-module lowering by interface hashes** (the clean interface-hash design the issue
   asks about). A module's *interface* is what other modules can see of it: its public types
   with their layouts, function signatures (with capabilities), traits and impls, constant
   values (comptime included) and its public generic templates' source. Its interface hash is
   the hash of that, plus the interface hashes of the modules its interface mentions. Checking
   stays whole-program (instances and coherence are global, and the diagnostics' order is the
   whole program's), but the backend text of `mod.<m>` is a function of m's typed IR, which is
   a function of m's source and its imports' interfaces: key `mod.<m>`'s *text* by (m's
   source hash, its imports' interface hashes, the eiderc identity) and skip lowering it
   when the key is known (the unit key then follows from the cached text). That saves lowering
   and LLVM emission for unchanged modules (two thirds of a no-op front end) and keeps check
   as it is. It needs the type ids in the IR to stop being program-wide (a unit's text names
   types by stable name already; the IR would need to as well, or lowering to be per module
   from stable keys). For checking itself the same interface hashes would allow caching a
   module's typed IR, but the decode cost measured above makes that unattractive until the IR
   has a compact form.

### Measurements

Phase 1 (the C backend; 2026-10-31, 16 cores, gcc, wall clock). `scripts/build-bench.sh
<eiderc>...` builds compiler/main.ei from a copy of the tree on an empty cache per row: cold,
no-op (median of 3), then an edit to a message in compiler/diag.ei, then one in std/proc.ei;
`release` is `build` (-O2), `debug` is `run -- --version` (-O0). `main` is main's compiler,
`#129` this one, both built at -O2 by the seed's eiderc. Seconds, one run each (a shared
machine: differences under ~10% are noise):

| compiler | build | cold | no-op | edit compiler/diag.ei | edit std/proc.ei |
|---|---|---|---|---|---|
| main | release | 35.33 | 0.57 | 37.87 | 34.23 |
| main | debug | 8.00 | 0.57 | 7.75 | 7.52 |
| #129 | release | 34.67 | 0.31 | 32.19 | 31.60 |
| #129 | debug | 6.94 | 0.28 | 6.80 | 6.84 |

Small programs (`eiderc run tests/run/adt.ei`, median of 5): cold 0.30 s before, 0.18 s now
(the core's two sources and the program compile in parallel); no-op 0.021 s, 0.008 s. SHA-256
(sha256.ei) of 1 MB: 52 ms before, 4.7 ms now.

Cold builds and edits of eiderc barely change: its C is one 4.7 MB unit, so any edit
recompiles all of it and gcc on it is the whole time. No-op builds halve: they are now the
front end and lowering (0.25 s) plus hashing (0.03 s). Edits become cheap in phase 2, when an
edit changes one unit of many.

Phase 2 (2026-10-31, 16 cores, gcc and clang 22, wall clock, one session; measured just
before #128 made LLVM the default backend, when `--backend=llvm` still selected it):
`scripts/build-bench.sh` on eiderc for five configurations; after each time, in parentheses,
the unit objects that step compiled (main's compiler has the old cache layout: not counted).
`main-c`: main's compiler, C backend, the whole-program binary cache (one cc per build, binary
keyed by the whole C). `main-llvm`: main's `--backend=llvm` (one module, full LTO, no binary
cache). `c`: this compiler, C backend. `llvm-whole`: this compiler, `--backend=llvm` with
`EIDER_LLVM_UNITS=0` (one LLVM unit through the new cache, ThinLTO). `llvm-units`: this
compiler, `--backend=llvm`, the default. Release is `build` (-O2), debug `run -- --version`
(-O0):

| configuration | build | cold | no-op | edit compiler/diag.ei | edit std/proc.ei |
|---|---|---|---|---|---|
| main-c | release | 42.57 | 0.69 | 42.11 | 42.31 |
| main-c | debug | 9.42 | 0.69 | 9.23 | 9.11 |
| main-llvm | release | 30.82 | 30.73 | 30.94 | 30.31 |
| main-llvm | debug | 2.27 | 2.05 | 2.03 | 2.04 |
| c | release | 41.51 (3) | 0.36 | 42.80 (1) | 38.81 (1) |
| c | debug | 8.43 (3) | 0.36 | 8.86 (1) | 8.91 (1) |
| llvm-whole | release | 33.83 (4) | 0.69 | 30.84 (1) | 29.86 (1) |
| llvm-whole | debug | 1.69 (4) | 0.58 | 1.66 (1) | 1.69 (1) |
| llvm-units | release | 12.77 (48) | 0.88 | 8.53 (1) | 1.75 (1) |
| llvm-units | debug | 1.88 (48) | 0.80 | 0.88 (1) | 0.89 (1) |

Against the whole-program cache (main-c): a release build of eiderc after an edit goes from 42 s
to 1.8-8.5 s, a debug one from 9 s to 0.9 s; a cold release build from 43 s to 13 s. Against
the LLVM build without units (main-llvm, and llvm-whole through the new cache), the units make
the release build parallel (31-34 s to 13 s cold) and the edits cheap: one unit compiles, and
ThinLTO re-optimizes only what imports from it. An edit to diag.ei costs 8.5 s in release
because diag is imported by nearly every module (its functions are inlined into them, so lld
optimizes those again); proc.ei, used by the driver alone, 1.75 s. The debug edit is 0.9 s:
the front end and emission (0.5 s), the split (~0.1 s), one clang -O0 and the link. A no-op is
0.8-0.9 s against 0.6-0.7 s for one unit: the split and hashing 10 MB of IR; it is the front
end that remains, and the front-end manifest above is what would remove it.

After #128 (LLVM the default backend, with main's whole-IR binary cache, C440), the same
benchmark on the same day: `main` is main's compiler (one LLVM module, full LTO, the program
cached by the whole IR), `whole` this compiler with `EIDER_LLVM_UNITS=0`, `units` this
compiler's default:

| configuration | build | cold | no-op | edit compiler/diag.ei | edit std/proc.ei |
|---|---|---|---|---|---|
| main | release | 28.83 | 0.93 | 28.78 | 29.09 |
| main | debug | 2.57 | 0.93 | 2.32 | 2.33 |
| whole | release | 27.90 (4) | 0.62 | 28.44 (1) | 27.77 (1) |
| whole | debug | 1.66 (4) | 0.55 | 1.62 (1) | 1.63 (1) |
| units | release | 10.71 (48) | 0.81 | 7.31 (1) | 1.55 (1) |
| units | debug | 1.66 (48) | 0.73 | 1.00 (1) | 0.84 (1) |

So against today's whole-program cache: a release build after an edit 29 s to 1.6-7.3 s, a
debug one 2.3 s to 0.8-1.0 s, a cold release build 29 s to 11 s; a no-op 0.93 s to 0.73-0.81 s
(main hashes the whole IR with the old SHA-256).

The unit objects of a debug and a release build of eiderc take 8 MB, lld's ThinLTO cache 4 MB
and each linked program 2.4 MB, so the 5 GiB default holds hundreds of builds.

## C8.11: the comptime interpreter

Wave 5 (#7; decisions C500-C503). Code: compiler/interp.ei (the interpreter),
compiler/consteval.ei (`eval_all`, `eval_one`, `mentions`/`gone`, `run_evaluator`); tests:
compiler/tests/run/comptime_interp.ei, the `*comptime*` cases of compiler/tests/check and
tests/checks, compiler/tests/run/comptime.ei and tests/run/comptime.ei.

**What runs.** Each comptime constant's evaluator program is checked as in "C7: comptime";
then, instead of lowering it to LLVM IR, building it with clang and running it,
`run_evaluator` hands the checked IR (`check.C`'s `ir`, `t`, `names`, as a `lower.P`) and the
IR function of `__ct` to `interp.run`, which returns the value (`interp.Val`) or the line
the built program would have written to stderr. The value is spliced in as before (an
integer as `EInt`, negative as `-(magnitude)`; a bool as `EBool`; a str as `EStr`, a new
string of the module). Nothing is written, no process starts, and no C compiler or
toolchain directory is needed: `eiderc check` and the IDE analysis (`ide.ei` no longer
reports a `toolchain` diagnostic for a program with comptime constants) work without one.

**The interpreter.** A value is `Val { k, n, b, xs }` (an integer as 64-bit two's complement
with signed kinds sign-extended, bool, text bytes, the parts of a record, tuple, array or
Box, a variant and its payload, List elements, a Map, a fn value with its captures, a cell
handle). Its Lists are copy-on-write, so a copy is a share: S_READ, S_CLONE and S_MOVE copy,
S_DROP only checks its place's bounds. A frame holds the function's locals, unassigned ones
reading as their type's zero (the backend's zeroed allocas). A place is resolved to its
root local and child indexes, bounds checked like `paddr`/`checks`; a write takes the value
out of its owner, changes it and puts it back, so a List with one owner is never copied by
a push. Calls pass `inout` arguments by copy-in, copy-out (exclusivity, E0301, makes that
the same as passing the place). Ref, Mutex and Chan are cells of the interpreter's heap.
Everything follows llvm.ei's lowering and glue, so results and trap messages are the built
program's:

- integer `+ - *` checked in 128 bits (fold.ei's `Wide`), `/ %` checking zero and MIN / -1,
  wrapping `+% -% *%`, shifts checking the count unsigned at the type's width, `as` checking
  the target's range, each with the backend's message and the statement's line;
- `==`, `<`, `compare`, `hash`, Show (`print`, `to_string`, `show`), `.copy()` and `Default`
  derived per type exactly as `g_eq`, `g_cmp`, `g_hash` (FNV-1a and `ei_hash_u64` for text,
  the same mixing per part), `g_show` (quoting), `g_copy` and `default_to` do, calling a
  type's own impl (Ir.impls) where the glue would;
- a Map keeps the runtime's table: slots by hash and linear probing, growth at 3/4 full to
  `ei_grow_cap`'s capacity, removed slots, an existing key keeping its slot; so `for (k, v)
  in m`, `keys()`, Show and `==` see the slot order the built program sees;
- Ref accesses keep the run-time state (reads nest, an update excludes) with the runtime's
  messages; Mutex `get`/`set`/`update` and Chan `send`/`recv`/`close` work on one thread (a
  `recv` that would block forever stops the evaluation);
- core/sys.ei's `ec_str_len`, `ec_str_byte`, `ec_in_*` and `ec_out_*` are emulated (so
  `sys.lit` and `sys.to_string` work), and every other extern is refused.

Refused, as E0807 "comptime evaluation of `X` failed: comptime evaluation can't ...": a
value of a record with its own Drop (C503; the built program would run `drop` when the last
share goes, which the interpreter doesn't track), threads, the clock, other externs, and
more than 10^9 IR statements. Calls nest at most 1,000 deep (`MAX_DEPTH`): deeper is the
runtime's own stack overflow message, `eider: runtime error: stack overflow (program:0)`.
The bound comes from the interpreter's own stack: each interpreted call costs about 4 KB of
the compiler's 8 MiB stack (measured with `-fstack-usage`), which is why `stmt` keeps only
the control flow and the builtins are split into groups (`value_op`, `text_op`, `list_op`,
`map_op`, `trait_op`, `cell_op`, `ref_op`): a call made from a builtin (a closure, a user
impl) then adds a small frame.

**Order and what an evaluator leaves out (C501).** `eval_all` tries the constants in item
order. An evaluator leaves out the pending constants (as in C7) and now also every function,
impl and plain constant that names one of them, and then whatever names those, to a fixed
point (`mentions` records what each item names and defines, a method by its name; `gone`
closes over it; a local named like an item counts too, which only defers). A constant whose
evaluator has a check error while other constants are pending is retried after them; a
round that makes no progress evaluates the rest in item order with only the pending
constants left out, which is C7's evaluator and so reports C7's errors. A check error that
is reported is the one of that evaluator too (an evaluator is rebuilt without the extra
items left out first). The diagnostics are sorted into item order. Consequences: a comptime
constant may use one declared later; a plain constant, and any function, may name a comptime
constant; an E0110 for a constant that is still pending (a cycle, or a constant naming
itself) gets the help "it is a comptime constant whose value depends on this one (a cycle of
comptime constants)". Any error in the rest of the program is still found by the first
evaluator, an E0201 there still loses its fix, and in the common case (no constant uses a
later one) each constant still costs one check.

**Types (C502).** `str` joins the integers and bool as a comptime constant type, judged by
spelling as before; the message for the others is now "`comptime` constants must be
integers, bool or str". Aggregates (records, tuples, arrays) stay out: plain constants can't
hold them (E0504).

**Cost.** `eiderc check tests/run/comptime.ei` (4 constants): 823 ms before, 10 ms after;
compiler/tests/run/comptime.ei (35 constants): 2,846 ms before, 18 ms after (medians of 7
and 5 runs, `EIDER_CACHE=off`; most of the old time was clang and the link per constant).
`scripts/bench.sh` is unchanged (it has no comptime constants): list_copies 4/3 ms, state
3/3 ms, str_append 5/5 ms, self (emit-llvm of compiler/main.ei) 398/381 ms.

**Tests.** compiler/tests/run/comptime_interp.ei computes ten cases twice, once as comptime
constants and once at run time, and prints whether they agree: Map slot order after inserts,
removals and growth (integer, text and own-Eq/Hash keys), derived and own Show with quoting,
hashes, wrapping and checked arithmetic, shifts, casts, comparisons and own Ord, closures and
List combinators, Ref/Mutex/Chan and `inout`, text bytes and UTF-8 checks, labeled loops and
`while let`, `Default`, `replace` and `take`. The C7 cases are unchanged except: E0110 for a
forward reference, a function naming a later constant, an imported module's forward
reference and late constant, and a plain constant naming a comptime one now pass
(compiler/tests/check/pass/comptime_{forward,later_in_fn,mod_forward,mod_late,plain_const}.ei),
an imported str constant passes (comptime_mod_str.ei), the E0807 message names str, and new
cases cover a cycle and a self-reference (E0110 with the help), Drop and runaway recursion
(E0807).

## C8.28: attributes

Wave 5 (#19, research #97; decisions C8, C510-C513). Code: lex.ei (`At`), parse.ei
("attributes": `attribute`, `attributes`, `attach`, `at_attr_decl`, `attr_decl`; fields and
variants), ast.ei (`Attr`, `AttrArg`, `Ast.attrs`, `attrs_of`, IType h=1, Field c), dump.ei,
check.ei ("Attributes": `check_attrs`, pass 6b); tests: compiler/tests/check/{fail,pass}
`*attr*`, compiler/tests/parse_ok/attrs.ei, tests/checks `*attribute*`; docs:
docs/site/reference/attributes.md.

**Syntax.** `@name`, `@name(key = value, flag)`, `@alias.name(...)`, before an item (the
newlines after an attribute are skipped), before a record field and after a variant's `|`.
`attr name { key: T = default, ... }` declares one: `attr` is an identifier, and a word only
where an item starts with `attr`, a name and `{` (no keyword, so `attr` stays a name; the
reflection call `attr[A](x)` is another place it is read). The lexer's `@` was a bad
character before: compiler/tests/lex/bad_char_at.ei became bad_char_dollar.ei.

**Tree.** An attribute is an `Attr` node (name, qualifier, `AttrArg` list, whether it had
parentheses) and an argument an `AttrArg` (key, value+1; 0 for a bare key). Which node an
attribute belongs to is a side table, `Ast.attrs` (node id -> its Attr nodes in `extra`),
rather than a slot: IFn has none free, and no other pass needs to see them. A declaration is
an IType record with h=1 whose Field nodes have c = default+1. `eiderc parse` prints both
(`attr` flag, `default`, `attribute` children).

**Checking (pass 6b, after constants).** A declaration is a record type like any other (the
type passes register and fill it, so `json(...)` constructs one); 6b checks its keys
(integer types, bool, str: E0822) and defaults (constants of the key's type: E0401, E0822),
then every attribute use of every module, in source order: the name (the module's own
attribute; else, unqualified, the attribute named like an import alias in the module the
alias names, which is how `import json` gives `@json`; else qualified; E0820 with a fix to
the closest name within a third of its length, E0801 for a private one), each key (E0821
with a fix, E0822 twice), each value (a literal or a constant: E0401, E0822; a bare key is
`true` for a bool key, else E0822), required keys (E0822) and the attribute given twice on
one node (E0822). Values are folded like constants into the scratch IR function and kept as
`ALit`s in `Reflect.found` (module, owner node, attribute, values in key order with the
defaults filled in). Nothing else in the checker or the backends reads them: attributes
change no IR and no output, only what comptime reflection ("C8.29") makes of them.

## Profiling: `--profile`

`eiderc build|run|test <file> --profile[=cpu,mem,conc]` (main.ei: `profile`, parsed by
`lower.prof_what`; a bare `--profile` is all three; with `--lib` or `--wasm` it is a usage
error) lowers the program through `llvm.program_prof` with `E.prof` set. Everything below is
emitted only then (`e.prof > 0`), so without the flag the IR has none of it
(scripts/test-compiler.sh "profile-off" checks `emit-llvm` of every run test and of the
compiler). The runtime side, the file format and the overhead are docs/runtime.md
"Profiler"; decisions C200 to C206, C449.

- **The runtime.** The driver compiles the core with `-DEI_RT_PROFILE` (`prof`), so eider_rt.c
  includes core/eider_prof.c (and the core objects are cached apart: the argv and
  eider_prof.c's bytes are in the key).
- **Shadow frames** (`function`, `lower.framed`, `prof_enter`). A function whose body calls
  (S_CALL, S_CALLV) or loops takes the next frame of the runtime's thread-local shadow stack
  (`ei_prof_stack`, `ei_prof_depth`, `ei_prof_spill`, through `llvm.threadlocal.address`, with
  volatile float stores as eider_rt.h's `ei_prof_enter` does) at entry, and pops it
  (`prof_leave`) before every `ret`. Straight-line code that calls nothing gets no frame: it
  counts for its caller, as if inlined.
- **Lines** (`lower.prof_marks`, `prof_line`): the frame's line is stored before a statement
  that calls, runs a builtin, makes a closure, builds a record with its own Drop, drops an
  owned value or prints, unless the line last stored is the same (`E.pline`).
- **Events** in glue (`prof_ev`): `EI_PEV_COW` in `uniq_` when the buffer is shared (bytes of
  the buffer), `EI_PEV_GROW` in `push_` when it grows, `EI_PEV_REHASH` in `ins_` when it
  rehashes, `EI_PEV_DROP` before a type's own Drop in `drop_`, `EI_PEV_COPY` at each
  `.copy()`, `EI_PEV_REF` when a Ref access overlaps another.
- **The name table** (`prof_init`): `@ei_prof_names` (every IR function's name, index + 1),
  `@ei_prof_file_of`, `@ei_prof_files` (the entry file, then the module files as `ir.files`
  names them), and `@ei_prof_tab` with the selection, the program and the toolchain version
  (`driver.version`: the first line of `<root>/VERSION`). `ei_main_body` calls
  `ei_prof_init(&ei_prof_tab)` after the trap file table; a failed test is unwound by the
  runtime's `ei_test` (`ei_prof_unwind(0)`).

Tests: compiler/tests/profile (memory events at their lines, waits and labels on threads,
CPU samples under labels with a snapshot, a Ref conflict's trap, `EIDER_PROF=off`; also under
ASan+UBSan and TSan), tests/core/prof_test.c (the runtime alone), tests/std/profile.ei
(std/profile without a profiler).

## Language work that lands in `eiderc` (after parity)

Each with a design note, compile-fail tests and new codes:

1. `String` byte access and slicing, `str` byte access; std switches to `String`.
2. Bitwise operators `& | ^ << >> ~` (checked shifts).
3. Unit values `()` / `Ok(())`; `main` returning an exit code; `impl` on built-in types.
4. Package-qualified modules: identity (package, path) instead of file stem; bare imports
   resolved from `eider.lock`; the `deps/` link farm goes away. Done ("C8.3: packages and
   modules").
5. Capability encapsulation. Proposal: `ffi` becomes a property of a *package*, not of call
   chains. A package that declares `extern` functions must be granted `ffi` by its dependers
   in `eider.toml`. Its functions don't propagate `uses ffi` to callers, but they still
   declare and propagate the real capabilities (`fs`, `io`, ...). `core` is the one package
   granted `ffi` by the toolchain. Result: std callers write `uses fs`, never `uses ffi`, and
   the package manager's text scan is replaced by the compiler reporting each package's
   capability use. Done ("C8.5: capabilities per package").
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
- Every run test built through the LLVM backend at -O0, at -O2 under UBSan, with ASan and
  TSan and with the runtime's allocation count, against the oracle; the emitted IR is
  deterministic (also from another directory).

## Layout

```
compiler/
  eider.toml          package `eiderc`
  main.ei             CLI (`eiderc --help`)
  source.ei  lex.ei  intern.ei  ast.ei  parse.ei  resolve.ei  types.ei  fold.ei  pats.ei
  check.ei  ir.ei  lower.ei (C names and layouts)  diag.ei  driver.ei  consteval.ei  suite.ei  sha256.ei
  build.ei            units, the object and link caches, the job runner, eviction ("C8.27")
  lock.ei             eider.toml and eider.lock for package imports ("C8.3")
  ide.ei              the IDE analysis API (`eiderc ide`; "IDE analysis")
  front.ei            every syntax error at once ("Front-end recovery")
  doc.ei              the API description (`eiderc doc`; "Documentation: `eiderc doc`")
  llvm.ei llvm_abi.ei the backend, and its C layouts and C conventions (x86-64, AArch64, wasm32; "Backends")
  llvm_units.ei       the module cut into units ("C8.27")
  wasm.ei             `build --wasm` and `--wasm-core` ("C7: WebAssembly")
  tests/              pass-level golden tests (lex, lex_ok, check, ir, run, wasm, export, ide, pkgs, ...)
tests/oracle/         the recorded expected results (scripts/test-compiler.sh, BLESS=1)
```

`compiler/` depends on `core` and `std` only.
