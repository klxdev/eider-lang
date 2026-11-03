# Changelog

Eider's versions: the language, the compiler (eiderc), core, std, eider-pkg and eider-doc
share `VERSION`. eider-analyzer, tree-sitter-eider and eider-profiler have the same
MAJOR.MINOR and their own PATCH, and are released together with it. Before 1.0 a MINOR
may break compatibility. The release process: docs/site/tooling/releases.md.

## 0.6.0 (unreleased)

**Breaking, read before upgrading** (before 1.0 a MINOR may break):

- **Attributes are written `@[a, b(key = value)]`, and only so** (#155): the bare `@name(...)` is a
  syntax error. A group goes inline or on its own lines above an item, a record field, a variant or
  (new) a fn parameter. `eiderc migrate-attrs <file>` and `scripts/migrate-attrs.sh <dir>...` rewrite
  code and Markdown; eider-analyzer and tree-sitter-eider follow (`attribute_list` node). An
  attribute's diagnostics now point at its name, not at the `@`.

- **Derivation is opt-in** (#156): a `@[derive]` trait is derived only for the records and enums that
  say `@[derive(Trait)]`, and every part of such a type must have the trait (E0833, with the path).
  Libraries with a derivable trait (eider-json, eider-openapi) are updated: see their changelogs.

- **eider-json is a format for std/serial** (#156): `json.Encode`, `Decode`, `Reader`, `DecodeError`,
  `to_json` and `from_json` are gone. A type is `@[derive(Serialize, Deserialize)]` (or has its own
  impls), goes to JSON with `json.to_bytes`/`to_string` and comes back with
  `json.from_bytes`/`from_string` (the type to read is the expected one). Errors are `serial.Error`
  (`path: message`, with no `$.`), `@[json(...)]` keeps its keys and `@[serial(...)]` is the neutral
  form. eider-rpc (`serial.Serialize` methods) and eider-openapi (`Schematic` is opted into,
  an enum without `tag` is keyed by the variant's name) follow. A record with a `json(flatten)` field
  accepts unknown members for now.

**New:**

- **std/serial** (#100): the data model and the traits of format-neutral serialization: `Serialize`
  and `Deserialize` for types, `Serializer` and `Deserializer` for formats, implementations for the
  built-in types, errors that name the path, and `Value` with `to_value`/`from_value`. See
  docs/compiler.md "C8.61".
- **`@[derive(Serialize, Deserialize)]`** (#156): serialization for your records and enums from one
  attribute vocabulary, `serial(name, skip, default, rename_all, tag)`, with `json(...)` and
  `toml(...)` overriding it per format (unknown keys are E0821). docs/compiler.md "C8.62".

## 0.5.0

The runtime and the standard library grow up for services: a trap can be contained, Maps hash
with a secret seed, byte transfer across the C ABI is bulk, closures and references stop copying
what they only read, and the tools gain a linter, `expand`, test options and a command-line
library. A package needs `eider = "0.5"` (E0811 otherwise; the seed needed the bootstrap in
seed/README.md after a MINOR bump). Siblings: every tool and library moves to 0.5.0.

**Breaking, read before upgrading** (before 1.0 a MINOR may break):

- **The iteration order of a Map is unspecified** (#55): Maps hash with SipHash-1-3 under a random
  per-Map key, so the order differs between Maps and between runs. Code and tests that printed a
  Map in slot order must sort or aggregate (`Map.deterministic()` for tests).
- **`extern "c"` parameters of type `List[u8]` cross as a pointer and a length** (#63): a C
  function declared with one takes two C parameters now. `core/sys` and the core's `ec_*` ABI use
  it (`ec_in_set`, `ec_in_append`, `ec_out_copy`).
- **Closures run before their call returns capture by reference** (#4) and read-only references
  through heap memory are pointers (#1): a program that relied on the snapshot (a closure given to
  a List combinator, `Ref.read`/`update` or `Mutex.update` that sees later writes) behaves as the
  variable, not its copy.
- **eider-http**: `Request`, `Response` and `Msg` gained fields and `Config` gained `plan`; code
  that builds them by position must use field names (see its CHANGELOG).
- **New lints** (#113): `eiderc lint` is separate from `check`, but the compiler package denies
  `unused_uses`, and a package's `[lints]` table is now read (an unknown lint name in `@allow` is
  E0821).
- **`std/cli`** (#114) is new std API; `std/testing`, `std/time` and `std/task` gained functions
  (no removals).
- **Map and SipHash**: Maps run slower on the Map benchmark (1.8 times), the compiler itself no
  slower.

- **Tools and services** (#102, #103, #113, #85, #114, #30, #5; partly): `comptime embed("path")`
  embeds a package file as a `str` constant (C807); `eiderc lint` with groups, `[lints]` in
  eider.toml, the built-in `@allow(...)`, and `unused_uses`, `unused_result` and `needless_copy`
  (C808; the compiler package denies `unused_uses`); `eiderc expand` prints the specialized IR of
  reflective bodies and errors inside one name the specialization (C809); `eiderc test --filter`,
  `--bench`, `--fuzz N` and std/testing's `table`, `bench`, `fuzz`, `temp_dir` (C810); `std/cli`,
  flags and subcommands derived from a record and an enum (C811). eider-pkg accepts `[lints]`.
- **Containing a trap** (#54): `Task.catch(f)` runs a closure and gives `Ok(result)` or `Err(text
  of the trap)`; std/task has `catch`, `spawn_caught`, pools that survive a job's trap
  (`Pool.traps()`, `Future.result`) and groups whose child can trap. No unwinding: the frames the
  trap leaves are abandoned without their drops. Decisions C803, C804; docs/runtime.md "What is
  safe afterwards".
- **Seeded Map hashing** (#55): Maps hash keys with SipHash-1-3 under a key of their own made from
  OS randomness; `Map.deterministic()` for tests. **The iteration order of a Map is unspecified**
  (it differs between Maps and runs); programs and tests that printed a Map in slot order must sort
  or aggregate. Decision C805; the Map benchmark runs 1.8 times slower, the compiler itself no slower.
- **Bulk byte transfer** (#63): an `extern "c"` parameter of type `List[u8]` crosses as a pointer
  and a length; the core's `ec_in_set`, `ec_in_append` and `ec_out_copy` use it, and `core.sys`
  moves its data with them. Decision C801.
- **The driver links the crypto backend** (#64): a program that imports `core/crypto` needs no
  wrapper; `--crypto <name>`, `$EIDER_CRYPTO` or `[crypto] provider`. Decision C802.
- **Time** (#22): `Timestamp`, `DateTime` and RFC 3339 parse and format in std/time. Decision C806.
- **In-place List operations** (#16): `sort.sort_in_place`, `sort_in_place_by` and `reverse_in_place`, `insert`, `remove`, `truncate`, `remove_range`, `extend`,
  `swap`, `slice` and `List.filled`; stream buffers compact in place. Views that share a buffer
  are not done. Decision C800.
- **Closures by reference** (#4): a closure that is the argument of a call that runs it before
  returning captures the variable's address instead of a copy. Decision C763.
- **References as pointers** (#1; partly): a read-only `let` reference through a List element, a Box
  or a record with its own Drop is a pointer, refreshed after a write that may move its buffer.
  Mutable aliases are not (follow-up #157). Decision C764.

**Not done, filed as follow-ups** (the items stay open): #16 views that share a buffer (zero-copy
slices); #54 turning a handler's trap into a 500 in eider-http (only the std side is done); #1 pointers for mutable
aliases (#157); #102 embedding binary files as `List[u8]` (#160); #103 printing a specialization as
Eider source and naming the asking call (#159); #113 the copy and cycle lints (#11), lints for dependencies and a fix for `needless_copy`; #30 coverage report for
`eiderc test` (#158); #114 a reflective `std/config` (#161), shell completions and flag groups; #5 std on the new base (`sys.lit` outside the
core is gone from proc, profile and testing; the rest remains, LAYERS.md "Known limits"). Libraries:
eider-http #5 (tracing, partly), eider-rpc #1 (typed services; Connect and trait reflection for
stubs remain), eider-openapi #1 (partly).

## 0.4.0

The language gains floating point, trait objects, associated types, capability polymorphism and
automatic derive; the tools gain a formatter, sanitizer and debugger support, and the standard
library gains logging, configuration and service basics. A package needs
`eider = "0.4"` (E0811 otherwise; the seed needed the bootstrap in
seed/README.md after a MINOR bump). Siblings: every tool and library moves to 0.4.0, and
eider-json 0.4.0 has `@derive` codecs (its 0.3.1, never tagged, is folded into it).

- **Floating point** (#43): `f32` and `f64`, IEEE 754. Literals (`1.5`, `1e-3`, `2.5f32`),
  operators and comparisons that never trap (`NaN != NaN`), no mixing with integers without
  `as`, no `Ord` and no `Hash` (use `total_cmp`), float-to-int `as` traps on NaN or out of range,
  `{x:.2}` in string literals, the shortest round-trip text on print, exact parsing
  (`strings.parse_f64`), `std/math` over libm (no capability), SSE and AArch64 HFA classes in the
  C ABI, `f32`/`f64` in WebAssembly exports and imports. `Decimal` and `BigInt` are not in it.
  Programs link `-lm`. Decisions C660 to C668; guide/numbers.md.
- **Automatic derive** (#99): a trait declared `@derive` gives its default methods to every record
  and enum with no impl of it, and `is_enum_type[T]` is a `comptime if` condition. Decision C600.
- **Associated types** (#107): `type Item` in a trait, `type Item = T` in an impl, `Self.Item` and
  `C.Item` in signatures (E0602). Decision C622.
- **Calling a method by its trait** (#50): `Trait.m(x, args)`, module-qualified too; two traits
  with a method of one name no longer clash until a plain call is ambiguous (E0119, whose help
  names the qualified call). Decision C621.
- **`dyn Trait`** (#18): trait objects with a vtable, in every container and field; one printed
  dyn-compatibility rule (E0607) and E0608 for an impl method needing a capability its trait's
  doesn't declare. Decisions C643 to C646.
- **Capability polymorphism** (#46): a fn type may end in `uses cap + cap`, and a generic function
  may declare `uses E` and have it inferred from its arguments. Decisions C640 to C642.
- **`main` returns `Result`** (#12): `Result[(), E]` for any `E`; an Err is printed through `Show`
  (a `Failure` prints its chain), exit code 1. Decision C620.
- **Record fields without commas** (#76): newlines separate fields.
- **Better diagnostics** (#78): E0302 suggests `Ref[T]` or `Mutex[T]`, E0303 and E0305 suggest
  `let mut`, and an assignment to a captured variable gets its own help.
- **`eider check` and `eider test` without a `main`** (#140): a library module checks and tests;
  `eiderc test` with no file runs a package's tests. Decision C705.
- **`eiderc fmt <file.ei>`** (#9): prints the canonical layout, no options. Decision C709.
- **Debugging and sanitizers** (#25): `-g` names enum variants and describes Map members,
  gdb and lldb printers, Eider names in frames, `--sanitize[=address,undefined|thread]` and
  `--race` for `build`, `run` and `test`; the Debugging guide. Decisions C706, C707, C710.
- **Services** (#24): `std/log` (JSON lines), `std/config` (defaults, flat TOML, environment,
  flags) and `std/service` (drain on SIGTERM, sysexits-style exit codes). Decision C708.
- **WebAssembly** (#136 to #138): exports may take and return `String` and `List[u8]`, modules
  define core.sys's text helpers themselves, and the generated loader returns the module's
  `memory` and passes it to an `eider_write` override. Decisions C701 to C703.
- **Faster verify** (#134): `scripts/verify.sh` runs its legs in parallel (`VERIFY_JOBS`), and a
  green run is recorded (`scripts/verify-stamp.sh`) for the exact commits of eider-lang and the
  siblings, so a release does not repeat it. Decision C704.
- **Release**: optional crypto backends (openssl, libressl) may be skipped by `release.sh`,
  nothing else.
- **Flaky tests fixed** (#148): the timing assumptions behind the intermittent std-leg failures
  are gone; the std test runner keeps failing output and a stress script repeats the leg.

## 0.3.0

The language's metaprogramming and string release: comptime runs on an interpreter, attributes
and reflection derive code without macros, every string literal interpolates. Not compatible
with 0.2 at the source level: a plain string literal with a brace in it changes meaning
(`scripts/migrate-strings.sh` or `eiderc migrate-strings` rewrites it), and `f"..."` is gone.
Siblings: eider-json 0.3.0 has derived JSON codecs, and every sibling moves to 0.3.0.

- **Every string literal interpolates** (U29, #17): `"{name} has {n:>4} items"` formats through
  `Show`; `{{` and `}}` are braces. The seed's source was made to mean the same under both rules
  first (seed/README.md, "Bootstrapping a change in what source means"), then the packages,
  tests, docs and siblings were migrated.
- **Raw and multi-line strings** (#13): `r"..."` and `r#"..."#` have no escapes and don't
  interpolate; `"""` strings span lines and strip their indentation.
- **`defer` and `errdefer`** (#15): run a statement at every exit of the block (end, `return`,
  `?`, `break`, `continue`), in reverse order; `errdefer` only when the function returns an `Err`
  or `None`. They are contextual words.
- **Pattern matching** (#98, #105): a constant's name in a pattern compares against the constant,
  guards (`p if cond`), or-patterns that bind, field patterns (`OutOfStock(..)`), ranges, and
  `String` against a `str` literal.
- **Default methods in traits** (#45, #75): a trait method with a body is inherited by each impl
  that doesn't define it, and is checked per implementing type.
- **Automatic capability grants** (U28, #135, #141): `eider add` grants a package what it uses
  and prints it (`--confirm` asks, `--no-grant`, `--uses`); `fetch` and `update` compute each
  direct dependency's set again over every module a depender could import, narrow a grant that
  holds more, and stop on growth with a diff until `--grant <pkg>` or `--grant-all`; `eider grant`
  and `eider revoke` edit one `uses` line; `[policy]` bounds every grant. The compiler still holds
  each dependency to its grant (E0204, whose help names the command).
- **Private git dependencies** (#142): eider-pkg authenticates github.com fetches with
  `GH_TOKEN`, `GITHUB_TOKEN` or `gh auth token`, through a one-off credential helper.

- **Comptime without a C compiler**: `comptime` constants are evaluated by an interpreter of
  the compiler's typed IR (compiler/interp.ei, #7), with the built program's results and
  trap messages, no C compiler, files or processes, and no way to reach a capability.
  Checking a program with comptime constants is about 60-100 times faster
  (tests/run/comptime.ei: 561 ms to 9 ms). Constants may be declared in any order, plain constants and functions
  may name comptime constants, and `str` is a comptime constant type; a cycle is E0110 with
  a help. A value of a type with its own `Drop` can't be made during evaluation, and calls
  nest at most 1,000 deep.

- **Attributes** (#19): `attr json { name: str = "", skip: bool = false }` declares an
  attribute, a record type the package that owns it defines; `@json(name = "id")`,
  `@json(skip)` and `@alias.name(...)` put one on an item, a record field or a variant.
  Arguments are checked constants; an unknown attribute or key is an error with a fix
  (E0820, E0821), a bad argument E0822. Attributes are inert: only comptime reflection
  reads them.

- **Comptime reflection** (#20): `comptime for f in fields(T)`, `comptime for v in
  variants(T)` and `fields(v)` expand their body per field or variant while a generic
  function is specialized; `x.[f]` is the typed field, `f.name`/`f.index`, `v.matches(x)`,
  `attr[A](f)` and `has_attr[A](f)` read the rest; `comptime if` keeps one branch;
  `T(comptime for f in fields(T) { ... })` and `v(...)` build values. Errors E0830-E0832,
  and errors inside an expansion name its field. docs/site/reference/reflection.md.
  docs/site/guide/json.md shows eider-json 0.3.0's codecs, derived this way.

## 0.2.0

LLVM is Eider's only backend, and the compiler bootstraps from WebAssembly (U23, U24). Not
compatible with 0.1 at the command line: `emit-c`, `--backend` and `emit-llvm --coverage`
are gone, and building programs needs clang 17 or newer.

- **The LLVM backend** builds everything: `build`, `run`, `test`, `build --lib`, `--wasm`,
  `--profile` and comptime evaluators; no C is generated (#128). The per-type operations,
  `main`, the test driver and the exports are LLVM IR; `emit-header` still writes the C
  header of a library's `export fn`s. The target is clang's (`-dumpmachine`): x86-64
  (System V) or AArch64 (AAPCS64, new), or wasm32 for WebAssembly. Sanitizers are clang
  flags (`EIDER_CFLAGS`). Incremental builds: per-module units, an object and link cache,
  ThinLTO, `-j`, `eiderc cache` (#129).
- **WebAssembly** modules are built by the LLVM backend for wasm32 with an explicit feature
  set; `build --wasm-core` builds a program as a module whose only imports are the C core's
  functions (#126).
- **The seed** is `seed/eiderc.wasm`, the compiler as WebAssembly, with `seed/wasm2c.c`, a
  small validating translator to C: the compiler still builds from a fresh checkout with only
  a C compiler (stage0 checks programs and emits IR), and builds itself natively with clang
  (#127). `seed/eiderc.c` is gone.
- **The runtime** gains what the IR can't spell portably: handle objects for Task, Mutex and
  Chan (`ei_h_*`), the test driver (`ei_test`), `main`'s error text, Show's numbers and quoted
  text (core/RUNTIME.md). The WebAssembly libc's allocator is size-classed.
- **Libraries and tools** move to 0.2.0 with it (`eider = "0.2"`).

## 0.1.0

The first version.

- **The language** (docs/site/reference/): integers, `bool`, `str`, `()`, records, payload
  enums, tuples, fixed arrays, type aliases; monomorphized generics and traits with static
  dispatch; the operation traits (`Copy`, `Eq`, `Ord`, `Hash`, `Show`, `Iter`, `Drop`,
  `Default`) derived automatically; `Option`/`Result` with `?` and `From`; `match` with
  nested patterns, exhaustiveness and reachability, `if let`, `while let`, labeled loops;
  closures, `fn` types, `inout` parameters; `let` references and `let mut` aliases with
  exclusivity checks, `Ref[T]`; value-semantics `String`, `List`, `Map`, `Box` with
  copy-on-write and drops on every exit path; overflow and bounds traps; capabilities
  (`uses io, fs, net, clock, threads, ffi`) checked per package; `spawn`, `Task`, `Mutex`,
  `Chan`; `comptime` constants; modules and packages (`import "json"` through eider.lock);
  `extern "c"`, `unsafe`, `export fn` with C/C++ headers; WebAssembly modules. Through
  docs/compiler.md C8.25.
- **The compiler**, eiderc, written in Eider and self-hosted from `seed/eiderc.c` with only
  a C11 compiler: check, build (native, `--lib`, `--wasm`), run, test, compile-fail suites,
  lex/parse/ir dumps, caps, migrate-var, audit-refs, ide (the analysis eider-analyzer uses);
  every independent error with a stable code (E0001 to E0811), JSON diagnostics and
  machine-applicable fixes; a binary cache; tests against a recorded oracle.
- **core**: the C runtime and core (eider_rt, eider_core: buffers, OS primitives, threads,
  crypto glue against libcrypto backends), the prelude, `core/sys`, `core/os`,
  `core/crypto`, `core/version`.
- **std**: bytes, strings, utf8, fmt, encoding, io, fs, path, env, proc, child, fd, net,
  poll, event, stream, time, random, signal, sync, atomic, chan, task, heap, deque, set,
  sort, error, testing.
- **eider-pkg**: init, add, remove, fetch, update, vendor, tree, hash; path and git
  dependencies, minimal version selection, eider.lock, a content-addressed store,
  capability grants per dependency.
- **eider**, the Eider command (docs/site/tooling/eider.md; U26): `eider toolchain
  install|list|use|remove|show`, `eider self update`, `eider version`, and the selected
  toolchain's eiderc, eider-pkg and eider-doc behind `eider build|run|test|doc|new|add|...`;
  selection by `+<version>`, `EIDER_TOOLCHAIN`, eider.toml's `eider`, the default; every
  download checked against the signed SHA256SUMS before it is unpacked.
- **Releases** (docs/site/tooling/releases.md; U27): prebuilt static toolchains for
  linux-x86_64 and linux-aarch64 (cross-built, untested) on the private GitHub Releases,
  SHA256SUMS signed with minisign's Ed25519 format (release key 51439F1DFD014199);
  `scripts/publish.sh`, `scripts/release-key.sh`, `install.sh`.
- **Packages**: toml, semver, sha256, json, fuzz, http, openapi, crypto; examples kvstore
  and todo.
- **Docs**: the docs site sources (docs/site: getting started, tour, guides, the language
  reference, tooling), the design notes and decision log.
- **Versions** (C220 to C226): `VERSION`, `eiderc --version`, `eider-pkg --version`,
  `core/version`, `eider = "0.1"` in eider.toml checked by the compiler (E0811),
  `scripts/version.sh` (show, check, check-siblings, bump), the versions check in
  `scripts/check-tools.sh`, and `scripts/release.sh` (RELEASE.toml and the bundle).
