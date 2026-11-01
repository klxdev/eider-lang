# Changelog

Eider's versions: the language, the compiler (eiderc), core, std, eider-pkg and eider-doc
share `VERSION`. eider-analyzer, tree-sitter-eider and eider-profiler have the same
MAJOR.MINOR and their own PATCH, and are released together with it. Before 1.0 a MINOR
may break compatibility. The release process: docs/site/tooling/releases.md.

## Unreleased

- **Comptime without a C compiler**: `comptime` constants are evaluated by an interpreter of
  the compiler's typed IR (compiler/interp.ei, #7), with the built program's results and
  trap messages, no C compiler, files or processes, and no way to reach a capability.
  Checking a program with comptime constants is 50-150 times faster (tests/run/comptime.ei:
  823 ms to 10 ms). Constants may be declared in any order, plain constants and functions
  may name comptime constants, and `str` is a comptime constant type; a cycle is E0110 with
  a help. A value of a type with its own `Drop` can't be made during evaluation, and calls
  nest at most 1,000 deep.

- **Attributes** (#19): `attr json { name: str = "", skip: bool = false }` declares an
  attribute, a record type the package that owns it defines; `@json(name = "id")`,
  `@json(skip)` and `@alias.name(...)` put one on an item, a record field or a variant.
  Arguments are checked constants; an unknown attribute or key is an error with a fix
  (E0820, E0821), a bad argument E0822. Attributes are inert: only comptime reflection
  reads them.

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
