# The self-hosted compiler (`eiderc`)

Status: approved direction; C1 to C6 done (eiderc is self-hosted; seed/eiderc.c committed). C7 (parity) has FFI and driver parity done. This file owns the plan; update it as stages land.

Progress: **C1 done** (lexer, interner, diagnostics rendering; `scripts/test-compiler.sh`).
**C2 done** (parser to the AST arena, `eiderc parse` dump, parse-error corpus and AST goldens).
**C3 done** for v0 plus non-generic payload enums (`resolve.ei`, `types.ei`, `fold.ei`,
`pats.ei`, `check.ei`, `ir.ei`; see "C3: checking" below).
**C4 done** for the same language (`lower.ei`, `driver.ei`; `eiderc emit-c/build/run/test`;
see "C4: lowering" below). **C5 done** for S1–S3: checking (see "C5: checking S1–S3") and
lowering (see "C5: lowering"). **C6 done**: eiderc builds itself to a fixed point and the
seed is committed (see "C6: self-hosting"). From C7, **FFI is done** (`extern "c"`, `unsafe`, `export fn`,
`emit-header`, `build --lib`, `-l`; see "C7: FFI"), since `compiler/` reaches the OS only
through core/sys.ei's externs. **Driver parity is done** (`test --compile-fail`, the binary
and core-object cache, work directories, `--help`; see "C7: driver").

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
seed:   that C is committed as seed/eiderc.c (done, C6); eider-bootstrap is retired at C7
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
- **Out of scope** (threads, comptime, WebAssembly; since C5 and C7 everything else) ends checking
  with an `unsupported` diagnostic at the point where the bootstrap would start handling the
  feature; everything reported before it is exact, and the test script counts such files as
  out of scope.
- **The IR** (node table at the top of `ir.ei`) is what C4 lowers: per function a table of
  locals and a tree of blocks; every intermediate value is a single-assignment temporary in
  source evaluation order, variable reads are explicit `read`s of places (local, field,
  bounds-checked element, enum payload), `&&`/`||` and `match` are lowered to `if`, `for`
  loops to `loop` with a `step` block (what `continue` runs). Constants are folded values.
- **Tests.** `scripts/test-compiler.sh` compares `check --json` with the bootstrap on
  tests/checks (51/74 in scope at C3, 64/74 since C5, 69/74 since FFI, all agree),
  tests/run (3/11, then 8/11, then 9/11), and eiderc's own cases (229 at C3, 418 since C5,
  456 since FFI) in
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
  not a compile error although `x / 0` is. Since C5: a name in an impl target that isn't
  a type parameter matches every type (check.rs unify_ast), so `impl Area for Sq` meets
  `T: Area` for any T (the instance body then fails) and `impl W[i32]`'s methods apply to
  every `W`; register_impl compares signatures as text after replacing every `Self`, also
  inside names like `MySelf`; impls on fn types never match a receiver (head_of spells
  the whole type).

## C5: checking S1–S3

`check.ei` covers the rest of the bootstrap's checker that `compiler/`, std and the
packages use: everything in them checks `ok` in both compilers once core/sys.ei's `extern`
fns are replaced by stubs (and, since "C7: FFI", without stubs).

- **S1.** Tuples (types, literals, `.0`, patterns, `let (a, b) =`); generic types and
  functions, monomorphized on demand: a generic type is a template definition and each
  instance its own definition (types.ei; type lists are interned so instances compare as
  ids), a generic function or method one IR function per instance (`swap[i32, bool]`,
  `Option[u32].unwrap`), with the bootstrap's inference (unify_ast from the expected type,
  the receiver, then argument by argument; E0409). Traits, impls and bounds (E0601, E0602,
  E0603), inherent and generic methods, `Self`, `?` (E0406), `if let`, nested patterns.
  Bodies are checked from a stack of instances like the bootstrap's `pending`, so the first
  error is the same one. Option and Result come from **`core/prelude.ei`**, the
  bootstrap's EIDER_PRELUDE verbatim, which `resolve.load` reads from the toolchain root:
  `$EIDER_ROOT`, else the parent of the directory holding the eiderc binary (argv[0]),
  else the current directory.
- **S2.** String, List, Map, Box with heap.rs's associated functions and methods, `len`,
  `for x in list`, list indexing, E0303 (mutating methods need an assignable receiver),
  E0409 (`List.new()`/`Map.new()` need an annotation), E0701 (Map keys), E0504 (owned
  constants), `==` without Maps. Ownership follows heap.rs (reads borrow, storing a borrow
  clones, fresh values are registered in their block's frame and moved out by `take`,
  frames are dropped on every exit) and is explicit in the IR: S_CLONE, S_DROP, S_MOVE,
  S_BUILTIN; `lower` only prints it (ir.ei, "Ownership").
- **S3.** fn types, closures with snapshot captures (each body an IR function whose
  L_CAPTURE locals hold the environment; S_CLOSURE builds it), named functions as values
  (S_FNREF), calls of fn values (S_CALLV), map/filter/for_each/any/all/fold as IR loops,
  and the closure cases of E0405/E0409. `?` in an expression-bodied closure stays
  `unsupported`: the bootstrap checks it against the enclosing function (LEARNINGS.md).
- **Tests.** Every new rule has cases in `compiler/tests/check` (`s1_*`, `s2_*`, `s3_*`
  pass files, and fail files by code); IR goldens `generics`, `heap` and `closures` in
  `compiler/tests/ir` show where clones and drops go.

## C5: lowering

`lower.ei` lowers every IR node of S1–S3. The checker already placed every clone, move and
drop (ir.ei, "Ownership"), so lowering only prints them: S_READ is a bitwise copy (a borrow
of owned data), S_CLONE calls the type's clone, S_DROP its drop, S_MOVE is a bitwise copy
whose source is dead.

- **Layout** (stage 0's, heap.rs and closure.rs): tuples are structs `f<n>`; String is the
  runtime's `ei_String`; List[T] `{ T *d; uint64_t len, cap; }` (grows by doubling from 4);
  Map[K, V] stage 0's open-addressing table `{ K *k; V *v; uint8_t *s; uint64_t len, cap,
  used; }` (slot states empty/used/deleted, capacity a power of two from 8, grows when
  `(used + 1) * 4 > cap * 3`, keys hashed with `ei_hash_u64`/`ei_hash_str` and probed
  linearly, so lookups behave exactly as stage 0's; Maps have no iteration, so their order is
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
  registered names; its header keeps stage 0's spelling, see "C7: FFI"). Nothing in the C
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
  agree with the bootstrap, every run is clean under UBSan at -O2 and ends with 0
  outstanding allocations ("leaks"), and `emit-c` of every run test is byte-identical twice
  and from a copy of the test directory at another path ("determinism").
- **Self-hosting** before FFI landed: with core/sys.ei's extern fns stubbed in a scratch
  copy, eiderc already compiled its own source to C that reached a fixed point and agreed
  with the stage-0-built eiderc on all 541 test programs; with FFI merged that became C6.

## C6: self-hosting

`scripts/selfhost.sh` (2026-10-30, 16 cores, gcc): stage 0 builds stage1 from `compiler/`
(8.3 s, mostly gcc -O2); stage1 emits C for `compiler/main.ei` (0.12 s) that is compiled into
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
  the seed is regenerated with every compiler change. Stage 0 stays the start of the chain
  (and the differential oracle in test-compiler.sh) until C7 parity retires it.

## C7: FFI

Done ahead of the rest of C7 because eiderc's own source reaches the OS only through
core/sys.ei's `extern "c"` functions. A port of the bootstrap's ffi.rs and the extern/unsafe
parts of check.rs and expr.rs; capability encapsulation ("Language work" item 5) is not
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
- **Not supported** (`unsupported`): `--wasm` (E0806 is WebAssembly only), and an extern or
  `unsafe fn` used as a function value, which the bootstrap accepts without `unsafe` or
  `ffi` (a hole; the value can then be called anywhere).
- **IR.** `Ir.externs` ({function, C symbol, parameter types}; the function has no body and
  carries the return type) and `Ir.exports` ({function, `stem__name`}), shown first by
  `eiderc ir` (golden `compiler/tests/ir/ffi`). Calls to externs are ordinary `S_CALL`s.
- **Lowering.** `extern_protos`: `extern <ret> <C name>(<params>) __asm__("<symbol>");`,
  under eiderc's own function name so it never clashes with libc headers or other
  declarations of the symbol (core/ABI.md rule 5; ELF only, Mach-O would need the `_`).
  `program_for(.., lib = true)` drops `main` and adds one non-static entry point per export,
  `<ret> eider_<stem__name>(<params>) { ei_set_file("lib"); return f(..); }`; a trap inside
  exits the process with 101 and names `lib`. `header` is stage 0's header byte for byte
  (records `R_<mangled name>` with fields `f_<name>`, `extern "C"` for C++), except that
  every record gets a typedef: stage 0 gives one only to parameter and return types, so its
  header doesn't compile when a record is a field of another.
- **Driver.** `emit-header <f>`; `build --lib <f> [-o name]` compiles the library C,
  `core/eider_rt.c` and `core/eider_core.c` at -O2 -fPIC, makes `lib<name>.a` (ar rcs) and
  `lib<name>.so` (cc -shared, with the `-l` libraries) next to `-o`'s path (else in the
  working directory) plus `<name>.h`, and prints `built <a>, <so>, <h>` like stage 0. The
  library carries the runtime and the core, so a consumer links only it (stage 0 pasted its
  runtime into the C as static functions; eiderc's runtime symbols `ei_*` / `ec_*` are
  global, which static linking resolves to one copy and which two shared Eider libraries
  share). `-l <lib>` (repeatable) links C libraries into `build`, `run` and `test`.
- **Tests.** The suite's four FFI files and `tests/run/ffi.ei` are in scope; 38 cases in
  `compiler/tests/check` (`*_ffi_*`: every E0803 shape for externs and exports, nested and
  imported cases, the E0201/E0802 order, unsafe scoping, E0107 between externs); run test
  `compiler/tests/run/ffi_libc.ei` (every C-safe type, unit and `str` results, an extern
  behind a module's wrapper); "export" in `scripts/test-compiler.sh`: `tests/export/run.sh`
  with `EIDER=eiderc` (C and C++ consumers, static and shared, trap exit code),
  `compiler/tests/export/run.sh` (more types, nested records, an imported module's export,
  two libraries in one program, headers as C11 and C++ with -Werror), and `check --lib` and
  `emit-header` against the bootstrap. `eiderc check` accepts core/sys.ei, std and
  `compiler/main.ei` like the bootstrap (no `unsupported` left in them).

## C7: driver

The rest of stage 0's driver (its main.rs), so the bootstrap's commands all exist in eiderc.

- **`eiderc test --compile-fail [<dir>]`** (`suite.ei`; default `tests/checks`): stage 0's
  run_compile_fail, same lines, same exit code. Each `<dir>/fail/*.ei` starts with
  `// expect: CODE LINE:COL` (the header is line 1 of the file as compiled) and must fail
  with exactly that code and position; if the diagnostic carries a fix, `diag.apply_fix`
  applies it (columns in Unicode scalar values) and the fixed source must compile
  (`(fix compiles)`) or fail with another code or position (`(fix resolves it; next: X)`),
  never with the same error. `<dir>/pass/*.ei` must compile. A file containing
  `// mode: test` is checked as a test build (no `main` needed: the checker reports a
  missing `main` last, so that error alone counts as success), `// mode: wasm` as a
  WebAssembly build. The last line is the error-code coverage against
  **`diag.all_codes()`**, the one list of the language's codes (stage 0's ALL_CODES, same
  order; a new code is added there with its test). eiderc's extra: a file it answers
  `unsupported` for is a `skip` line, counted in `<n> skipped (not yet supported by
  eiderc)` before the summary, neither passed nor failed. **WebAssembly mode is not in
  eiderc yet** (being added in parallel as `check --wasm`): until then `// mode: wasm` files
  are checked as programs and any mismatch is reported as `skip` (TODO in suite.ei).
  Results: `compiler/tests/check` is byte-identical to stage 0's output (456 passed, 0
  failed, coverage 37/42). `tests/checks`: 68 passed, 0 failed, 6 skipped, coverage 40/42
  against stage 0's 74 passed and 42/42; the missing codes are E0806 (WebAssembly:
  e0806_wasm_str needs wasm mode, e0806_wasm_threads threads too) and E0807 (comptime:
  e0807_comptime_str, e0807_comptime_trap); the other skips, e0201_comptime_io (comptime) and
  e0409_chan (threads), have codes covered by other files. `compiler/tests/suite` holds the
  runner's own cases (wrong code, wrong position, missing header, a file that compiles, a
  rejected pass file, a fix after non-ASCII text, a fix that leads to the next error, test
  mode), whose output (6 failed, exit 1) must equal stage 0's too.
- **Cache** (top of `driver.ei`). `EIDER_CACHE=off` disables it, `EIDER_CACHE=<dir>` moves
  it, the default is `$XDG_CACHE_HOME/eider`, else `~/.cache/eider` (stage 0's), with
  eiderc's entries in subdirectories so the two never collide. Keys are SHA-256 (`sha256.ei`,
  see LAYERS.md for why the compiler has its own) over length-prefixed parts:
  `core/<key>/{eider_rt.o,eider_core.o}`, the C core compiled once per toolchain, keyed by
  the whole cc argv (cc, warning and -O flags, `$EIDER_CFLAGS`, `-I <root>/core`, `-fPIC`
  for libraries), `$CC --version`, `LIBRARY_PATH`/`CPATH`/`C_INCLUDE_PATH` and the bytes of
  eider_rt.h, eider_rt.c and eider_core.c; and `bin/<key>`, an executable, keyed by the same
  toolchain parts, the core objects (their path holds their key), the `-l` libraries and the
  generated C. `run` executes a cached binary in place, `build` copies it to `-o`'s path
  (removing the old file first, so a running binary isn't rewritten). Not in any key: the
  contents of external `-l` libraries and of system headers beyond what `--version`
  identifies (stage 0 keys on cc's name, flags, libs and the C only). With the cache off the
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
  directory) for the caller to run, `driver.discard(e)` removes the work directory;
  `build`, `build_lib` and `run` keep their signatures.
- **Usage.** `eiderc --help` (also `-h`, `help`) prints every command, option and
  environment variable to stdout and exits 0; no arguments prints it to stderr and exits 2;
  an unknown option, an unknown command, a missing source file, a stray second file, `-o`/`-l`
  without a value, or `--compile-fail` with another command is a one-line `eiderc:` error
  plus a pointer to `--help`, exit 2 (stage 0 ignores unknown flags).
- **Tests** (`scripts/test-compiler.sh`): "unit" (compiler/tests/unit/sha256.ei: the FIPS
  180-4 vectors, the padding edges, 100 KB), "compile-fail", "cache" (hits; the -O level,
  `EIDER_CFLAGS` and the core in the key; concurrency; no work directory left; `off`) and
  "usage".

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
  `\n<n> tests, <k> failed`, exit 1 if any failed (stage 0's format).
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
  bootstrap's stdout, stderr and exit code under `run`, and under `test` when it has test
  blocks, with `-Werror`; then again at `-O2 -Werror` under UBSan in trap mode. eiderc's
  own run tests cover every operator per int type with every trap and the wrapping edges
  (`arith.ei`, `traps.ei` with 109 trapping test blocks, `limits.ei`), evaluation order,
  payload-enum matches, `inout`, constants, modules, control flow, test blocks, and traps
  in `run` (stderr, exit 101).
- **Differences from stage 0** (deliberate): the bootstrap bugs in LEARNINGS.md are fixed and
  have regression tests with hand-written expected output (`compiler/tests/run/bug_*.ei` +
  `.out`): `len(e)` evaluates `e`; `let p = match r { V(p) => p }` assigns `p`; `else if`
  conditions with temporaries; `??(` in strings
  stays `??(`. A program killed by a signal makes `eiderc run` exit 128 + signal (stage 0
  exits 1); `build` without `-o` writes to the working directory (stage 0 writes to its temp
  directory); the binary cache keys with SHA-256 over more inputs and lives in subdirectories
  of the cache directory ("C7: driver"); driver messages start with `eiderc:`. Kept for parity: an imported module's unit enum prints its mangled name
  (`geo__South`), and trap messages always name the entry file, even for a trap in an
  imported module.

## Compile speed

Measured 2026-10-30 (16 cores, gcc, one run each). The front end is cheap: about 1 ms per 100
lines for lex+parse+check+emit (a 527-line program checks in 4 ms; parsing the 2,026-line
check.ei takes 17 ms). End to end the C compiler dominates: building eiderc itself (7.5k lines
of Eider -> 17.4k lines of C) is 0.23 s front end + ~5 s gcc -O2 (1.2 s at -O0); `eiderc
build` of a 76-line program takes 313 ms vs stage 0's 70 ms.

Core objects and the binary cache (C7, "C7: driver"), measured 2026-10-30 on
`tests/run/adt.ei` (84 lines; 16 cores, gcc; each the median of 4 runs, wall clock):

| | `eiderc build` (-O2) | `eiderc run` (-O0) |
|---|---|---|
| before (core sources compiled into every program; = `EIDER_CACHE=off` now) | 0.31 s | 0.14 s |
| after, first ever (empty cache: also compiles and caches the core) | 0.34 s | 0.16 s |
| after, program changed (core objects cached, program not) | 0.07 s | 0.06 s |
| after, program unchanged (binary cache hit: no cc) | 0.01 s | 0.01 s |
| stage 0 (its C pastes its runtime in; `EIDER_CACHE=off`) | 0.06 s | 0.06 s |

So the core was ~80% of a small build; with it cached, eiderc's edit-and-build loop is at
stage 0's speed. A hit costs one `cc --version` (part of the key) and hashing the generated C
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
| ✅ (C7) Binary cache keyed on (generated C, CC, flags, core objects), like stage 0's `EIDER_CACHE` | unchanged programs skip gcc: 0.01 s |
| Smaller C: declare temporaries in the narrowest scope that still avoids `-Wmaybe-uninitialized`; share glue between identical layouts (only used glue is emitted since C5); eiderc's own C is 74k lines | eiderc emits ~1.5x stage 0's C for the same program; gcc time is roughly linear in it |
| One C file per module, compiled in parallel (needs constraint 3) | uses the idle cores; most of the gcc time for large programs |
| -O0 for the edit/run loop by default (already), -O2 only for `build` | 4x faster gcc on large programs |
| Incremental front end: cache per-module check results keyed by source hash and the interfaces of imports | matters once programs are large; the front end is not the bottleneck today |
| A direct debug back end (no C compiler in the loop) | edit/run latency independent of gcc |

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
| C5 ✅ | S1–S3: payload enums, generics, traits, Option/Result/`?`, tuples, patterns, String/List/Map/Box, closures | all the features `compiler/` itself uses; their tests match (checking ✅, lowering ✅) |
| C6 ✅ | Self-host: stage1 builds stage2 builds stage3; fixed point; commit the seed | `scripts/selfhost.sh` green (stages compile `-Werror`, stage3 passes `scripts/test-compiler.sh`), `scripts/selfhost.sh --from-seed` reproduces the seed with only a C compiler |
| C7 | Parity: modules/namespaces, FFI/export/`--lib` (✅ ahead of C5 lowering), threads, WASM, comptime, driver (`test --compile-fail`, cache, `--help`: ✅) | the full `scripts/verify.sh` passes with `eiderc` in place of the bootstrap; retire eider-bootstrap |
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
  main.ei             CLI (`eiderc --help`)
  source.ei  lex.ei  intern.ei  ast.ei  parse.ei  resolve.ei  types.ei  fold.ei  pats.ei
  check.ei  ir.ei  lower.ei  emit.ei  diag.ei  driver.ei  suite.ei  sha256.ei
  tests/              pass-level golden tests (lex, lex_ok, check, ir)
```

`compiler/` depends on `core` and `std` only.
