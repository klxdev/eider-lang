# Eider compiler learnings

- Checker and emitter are one pass (`check.rs`). Any expression whose operand emits hoisted statements must call `fix_order` so earlier operands are evaluated first; a missing call shows up as wrong evaluation order, not a crash (found via `tests/run/order.ei`).
- Compile-fail headers (`// expect: CODE LINE:COL`) count the header as line 1. Verify positions against the source by hand before blessing.
- Constant folding runs before codegen, so deliberately-bad runtime-trap tests must use variables, not literals (`(300 as i64) as u8` is a compile error).
- Statements on one line need `;`. Newline is the separator; `{` must follow the signature (same or next line).
- Generated C uses `INTn_C`/casts for literals and `_Noreturn`; keep it C11 with no builtins so any `$CC` works.
- Name lists live in `diag.rs::ALL_CODES`; add new codes there or the coverage line goes stale.
# Language design learnings (from design phase)

- Name: Eider. Extension `.ei`. CLI `eider`. Code-fence tag `eider`.
- `.ei` is only partly verified (truncated FileInfo page). GitHub Linguist is unchecked.
- Don't rename with broad `sed` on `tern`/`Tern`: it retags real `rust` fences, and case-insensitive passes mangle comments ("AUTO-generated"). Use `\b` and check `extern` is untouched.
- WebFetch only accepts URLs that already appeared in a search result. Search first, then fetch.
- N-API exposes Eider to Node. Calling JS from Eider means embedding QuickJS.
- `interop_examples.md` is stale: it still shows TOML annotation files and `project.toml`. The decided design is in-language `extern c "..." as name { ... }` blocks plus a declarative `project.x` manifest, with an opt-in `build.x`.
- Competing agent-oriented languages: Edda, Vera, Keel.
- Top-level `uses` is not valid; capabilities are per-fn. `for i in 0..4` with literal bounds gives i32 (cast to index).
- Type decl variants need a leading `|`. Prelude (Option/Result) is Eider source in prelude.rs, parsed before user items.
- unparen() must be string-literal aware; clang warns on `if ((a == b))`.
- Ownership model (S2): value semantics. Reading owned data out of a place clones; fresh rvalues (registered temps in `fresh`) move via `take()`. Params are borrowed. Frames = per-block drop lists; return/break/continue/`?` drop outer frames. Pattern bindings clone (no aliasing).
- A mutating method receiver (push/insert/...) must stay a place; never let `fix_order` hoist it into a by-value temp (that leaked a List in the first draft).
- Closures capture a snapshot (clone) in a heap env; can't mutate captured vars. Value-form closure bodies (`if`/`match`/block) need a return type from context or `-> T`.
- Prelude is a raw string; a `"` inside Eider prelude code needs r#"..."#.
- Modules (S4, namespaced in S7): `import "x.ei" [as y]`; items are private unless `pub` (E0801). Module prefix = file stem; its top-level names are renamed `stem__Name` (eider-bootstrap src/ns.rs) and the parser turns `alias.Name` into the same identifier, so the checker still sees one flat table. Two files with the same stem conflict (E0808). `extern` fns stay global (C symbols). A local named like an import alias breaks `alias.x`. Compile-fail runner must pass the real path so imports resolve; helper modules live in tests/checks/{fail,pass}/lib/ (runner doesn't recurse).
- extern "c" fns are declared as `extern T f_name(..) __asm__("name")` to dodge clashes with libc headers (ELF-only: Mach-O would need the `_` prefix). Need `uses ffi` + `unsafe`.
- `export fn` => non-static `eider_<name>` wrapper + header (`eider build --lib`); traps in a library exit(101).
- Threads (S5): Task/Mutex/Chan are refcounted heap handles; closures hold snapshots so threads share only via Mutex/Chan. `spawn` needs `uses threads`; `Chan.new()` needs a type annotation (E0409). Build with `-pthread`. Verified under TSan.
- WASM (S6): `build --wasm` compiles generated C with clang --target=wasm32 against a tiny freestanding libc shim (eider-bootstrap src/wasm_shim.rs: bump/free-list malloc, printf, host imports `env.eider_write/eider_now_ms`). Exports are ints/bool only (E0806); threads rejected. `exit`/traps become wasm `unreachable`. Needs clang+wasm-ld (`WASM_CC` overrides).
- WASM in eiderc (C7): `core/wasm/` replaces the pasted shim (README there). Gotchas: clang turns 64-bit overflow checks (`__builtin_mul_overflow`, and the `n > MAX / size` idiom) into `__multi3` calls, which `-nostdlib` leaves as an unresolved `env` import that fails at instantiation, so libc.c defines it. The stage-0 loader breaks for an export parameter named `x` (it shadows `const x = inst.exports`), returns unsigned values above the signed range as negative numbers/BigInts, and its shim cut printf output at 511 bytes; eiderc keeps the loader byte-identical and fixes the shim.
- Comptime: `const X: T = comptime expr` compiles the program minus main/tests with a synthetic `main` printing the value, runs it, splices a literal back. Evaluator has no capabilities (E0201 with the fix stripped), ints/bool only (E0807). Evaluated sequentially, so later comptime consts can use earlier ones.
- Build cache: `run`/`build` key binaries on fnv64(cc, flags, libs, generated C) in `$EIDER_CACHE` (default ~/.cache/eider; `off` disables). Whole-program front end is not incremental; only the C compile is skipped.
- `scripts/verify.sh` (skill: .claude/skills/eider-verify) is the full matrix; run it after any compiler change.
- `run`/`test` compile C at -O0 (gcc ~4x faster than -O2 on a 3k-line program); `build` and `run --release` use -O2. Every non-unit function (and closure body) ends in `ei_unreachable()` or gcc -O0 warns `-Wreturn-type` and pollutes test output.
- eiderc's run tests check drops with a counting allocator (`EIDER_CFLAGS=-DEI_RT_COUNT_ALLOCS`: generated `main` reports `eider: outstanding allocations: <n>`), because ASan's runtime isn't installed everywhere. To test eiderc on its own source before FFI lands, stub core/sys.ei's `extern "c"` fns in a scratch copy (docs/compiler.md, "C5: lowering").
- Self-hosting (C6): `scripts/selfhost.sh` reached the fixed point on its first run because lowering was already deterministic (no index-based names, no map iteration, no paths in the C) and tested with a stubbed-FFI copy first. Scripts that run a compiler from another directory must take an absolute path (`EIDERC=` is one). After any `compiler/` change: `sh scripts/selfhost.sh --seed` and commit seed/eiderc.c.
- Compile-time benchmark (3,000-line synthetic, 150 record types, 2 cores, no cache): front end ~50 ms; gcc -O2 4.9 s, -O0 1.3 s; clang -O2 ~19 s, -O0 0.5 s. The C is ~3.7x the Eider line count because every type gets its own glue; shrinking that is the main lever.

# Bootstrap bugs (frozen compiler; work around them, and give eiderc a regression test)

- Owned temporaries in an `else if` condition (e.g. `else if bytes.eq(x, sys.lit("a"))`) are declared inside the generated `else { }` block but dropped after it, so the C fails to compile (`tN undeclared`). Bind the value first or compare through a helper function.
- A match arm binding with the same name as the `let` it initializes (`let p = match r { Ok(p) => p ... }`) gets the same C name as the outer variable, so the arm assigns its own copy and the outer variable stays uninitialized (garbage, or a crash later). Use a different binding name.
- `len(e)` on an array folds to the length and never evaluates `e` (expr.rs builtin `len`), so side effects in `e` are lost; eiderc's IR keeps them.
- Folding `u64 * u64` constants overflows i128 and the checker panics (expr.rs binary fold). eiderc computes in 128 bits and has no test for it, since the bootstrap gives no answer.
- Checker quirks eiderc reproduces for diagnostic parity (docs/compiler.md, "C3: checking"): `Enum.Variant` on an imported module's enum is E0114; some errors in imported modules name the importer's file; a module's test block doesn't let locals shadow the module's item names.
- String literals are pasted into the C with only `"`, `\`, newline and tab escaped, so `??(` and the other trigraphs turn into `[` etc. under `-std=c11` (plus a `-Wtrigraphs` warning on stderr). eiderc escapes `?` (regression test `compiler/tests/run/bug_trigraph.ei`).
- `?` in a closure whose body is an expression (`|x| f(x)?`) is checked against the *enclosing* function's return type: closure.rs lambda_body checks the body (line 257) before it sets `self.ret` (line 268), and the C it emits returns the wrong type. eiderc answers `unsupported` there; block-bodied closures (`|x| -> T { ... }`) are fine.
- Checker quirks found while porting S1–S3, kept for parity: check.rs unify_ast (lines 644-655) lets a name that isn't a type parameter match any type, so a bound is met by any type once some `impl Trait for Name` exists, and `impl W[i32]` methods apply to every `W`; register_impl (lines 961, 965) replaces `Self` textually, also inside `MySelf`.
- At -O2 gcc reports `-Wmaybe-uninitialized` on temporaries the bootstrap declares before a branch that always assigns them. Harmless, but eiderc's C must be warning-free.
- A match-arm binding with the same name as the `let` it initialises (`let p = match r { Ok(p) => p ... }`) is emitted as a second C variable `v_p` inside the arm's block, so the outer `p` is never assigned and reads garbage (eiderc's `main.ei` crashed in `ast.at`). Give the binding another name.
- An `extern "c"` or `unsafe fn` used as a function value (`let f: fn(i32) -> i32 = abs`) passes the bootstrap's checker with neither `unsafe` nor `uses ffi` (closure.rs fn_as_value checks only the declared capabilities), and the value can then be called anywhere. eiderc answers `unsupported` there until the language decides (an unsafe fn type, or an error).
- `emit-header` gives only parameter and return records a typedef (ffi.rs header), so a header whose record has a record field doesn't compile. eiderc typedefs every record (compiler/tests/export/nested.ei).
- Comptime quirks eiderc keeps for parity (docs/compiler.md, "C7: comptime"): each comptime constant's evaluator program lacks every comptime constant not yet evaluated, so a plain `const` naming a comptime constant always fails (E0110), and so does any function naming a later one; any error in the rest of the program is found by the first evaluator, and an E0201 there loses its fix wherever it is. Traps during evaluation name the file `program`.
