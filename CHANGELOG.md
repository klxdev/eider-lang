# Changelog

Eider's versions: the language, the compiler (eiderc), core, std, eider-pkg and eider-doc
share `VERSION`. eider-analyzer, tree-sitter-eider and eider-profiler have the same
MAJOR.MINOR and their own PATCH, and are released together with it. Before 1.0 a MINOR
may break compatibility. The release process: docs/site/tooling/releases.md.

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
