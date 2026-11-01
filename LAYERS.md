# Layers

Anything that is not Eider is unmanaged code: it is outside the language's safety checks and
is a security and performance risk. The goal is that the only unmanaged code is the C core,
and that the core is as small as it can be.

Eider code is partitioned into three layers. Dependencies only point down.

| Layer | Where | Language | What belongs here |
|---|---|---|---|
| core | `core/` | C (`eider_core.c`, `eider_rt.{h,c}`, `eider_prof.c` (the runtime's profiling part, compiled in only for `--profile` builds); `wasm/`, the runtime's optional WebAssembly backend; `crypto/eider_crypto.c`, the glue to a crypto library) + Eider (`sys.ei`, `os.ei`, `crypto.ei`, `prof.ei`, `prelude.ei`) | `eider_rt` is the language runtime generated code calls (traps, checked arithmetic, allocation, String, print, thread primitives with guarded stacks, atomics, and in `--profile` builds the profiler; `core/RUNTIME.md`). `prelude.ei` is the language's own Eider source that every program sees (Option, Result and their methods, and the operation traits `Copy`, `Eq`, `Ord`, `Hash`, `Show`, `Iter`, `Drop` with `Ordering`, docs/compiler.md "C8.4: operation traits"; its text is fixed, since positions recorded in `tests/oracle/` depend on it, so additions go at its end); it stays that tiny. Otherwise the OS interop boundary and nothing else, specified in `core/ABI.md` so each OS or architecture is one backend file. One OS call per C function, errors as `-errno`, no logic, no pointers exposed to Eider (data crosses a byte at a time through the core's buffers). `sys.ei`, `os.ei`, `crypto.ei` and `prof.ei` (the profiler's control call, `ec_prof`, core/ABI.md "Profiling") are the only modules allowed to use `extern`/`unsafe`, and they bind only `ec_*` core symbols (`crypto.ei` only `ec_crypto_*`, core/crypto/README.md); core is the one package the toolchain grants `ffi`, and each wrapper declares the real capability of its call (`fs`, `io`, `net`, `clock`) next to it (docs/compiler.md, "C8.5"). `sys.ei` has the buffers, files, environment and `ec_run`; `os.ei` the Layer 0 OS primitives (descriptors, sockets, DNS, readiness, time, signals, randomness, processes) and the atomic cells std/atomic holds by handle (core/ABI.md "Atomic cells": CPU operations, not OS ones, under the same rules). They are separate so the compiler, which imports `sys` (and `std/proc`), does not carry the OS bindings: everything the compiler imports is part of `seed/eiderc.wasm`. |
| std | `std/` | Eider | What almost every program needs: `bytes` (text as `List[u8]`), `fs`, `io`, `env`, `proc`, and the thin OS layer over core/ABI.md's primitives: `fd` (descriptors), `net` (sockets, DNS), `poll` (readiness), `time`, `random` (OS CSPRNG), `signal`, `child` (processes as streams); and the runtime layer (docs/runtime.md): `atomic`, `sync` (Lock, Parker), `chan` (bounded channels, select), `task` (cancellation tokens, task groups, a thread pool), `event` (event loop and timers), `profile` (the profiler's control, a no-op without `--profile`), with `Duration`/`Deadline` (and the `Clock` trait) in `time`; and the foundation (docs/std.md): `stream` (Reader/Writer, typed I/O errors, buffered streams, deadlines), `path`, `strings`, `utf8`, `fmt`, `sort`, `deque`, `set`, `heap`, `encoding`, `testing` (assertions and deterministic test doubles). Imports only core and other std modules. The compiler imports `bytes`, `fs`, `io`, `env` and `proc`, so those are part of the seed and change only with a seed regeneration. | |
| packages | `packages/<name>/` | Eider | The ecosystem's tooling, as ordinary packages with an `eider.toml`: `eider` (the eider command: toolchains, and dispatch to eiderc, eider-pkg, eider-doc; docs/site/tooling/eider.md), `pkg` (eider-pkg, the package manager, with its `semver` and `sha256` modules), `doc` (eider-doc, the documentation site generator and doc-test runner, `scripts/docs.sh`), `fuzz` (the compiler's crash and consistency fuzzer, `scripts/fuzz-check.sh`) and `crypto` (the primitives over the core's crypto provider). Everything else is a package in a repository of its own ("Where code lives" below); the ones the tools here need are pinned in `vendor.lock` and fetched into `.vendor/<name>/` ("Vendored libraries" below). A package imports `core.<module>`, `std.<module>` and its declared dependencies by name (`toml`, `json.<module>`), located through its eider.lock (docs/compiler.md, "C8.3: packages and modules"). |

The compiler (`compiler/`, docs/compiler.md) is a program on top of these layers, but it may
depend only on core and std: it builds itself from the seed with nothing else, and packages
are resolved by a package manager that the compiler builds. So when the compiler needs an
algorithm that lives in a package, it carries a small module of its own rather than pulling
the algorithm into std. Such cases are `compiler/lock.ei` (the compiler's reader for
eider.toml and eider.lock, the TOML subset of eider-toml, .vendor/toml) and `compiler/sha256.ei`, the hash of the driver's
binary and core-object cache (a copy of eider-pkg's `packages/pkg/sha256.ei`, made faster with an XOR table and
by not copying the input). Moving sha256 into std was rejected: std is for what most
programs need, and a hash is a package by the rule below. The copy can go once the seed
knows package imports (docs/compiler.md, "C8.3: packages and modules"): then the compiler
can take a pinned package from the repository as a path dependency.

## Where code lives

eider-lang is the core language and what is needed to build an ecosystem on it (U19): the
compiler, core, std, and the tools every Eider user needs from the toolchain itself:
eider-pkg, eider-doc, the fuzzer, the crypto package over the core's provider, the scripts
and the docs. Frameworks and general libraries live in repositories of their own, next to
this one, as ordinary packages that depend on each other by git (`[deps.json] git = ...,
version = ...`) with grants:

| Repository | Package | From |
|---|---|---|
| eider-toml | `toml` | packages/toml |
| eider-json | `json` | packages/json |
| eider-markdown | `markdown` | packages/markdown |
| eider-http | `http` (server, client, router, middleware, metrics, problem, profiling) | packages/http |
| eider-rpc | `rpc` (`rpc/jsonrpc`; examples/kvstore) | packages/http's jsonrpc, examples/kvstore |
| eider-openapi | `openapi` (examples/todo) | packages/openapi, examples/todo |

The editor tooling and the profiler (eider-analyzer, tree-sitter-eider, eider-profiler) are
sibling repositories too. Each sibling builds against an eider-lang checkout (`EIDER_ROOT`,
default `../eider-lang`), keeps the toolchain's MAJOR.MINOR before 1.0 with its own PATCH
(`scripts/version.sh check-siblings`), and is built and tested against this checkout by
`scripts/check-tools.sh` (verify's tools leg) when it is checked out. A new library goes in a
repository of its own, not under packages/; a package belongs here only if the toolchain's
own tools need it, or it is one of those tools.

**Vendored libraries.** The tools here may use a library only as a pinned release: a tagged
commit of its repository, pinned in **`vendor.lock`** at the root (name, version, git source
and commit, and eider-pkg's content hash, in eider.lock's entry format; written by
`scripts/vendor.sh <name> <commit>`), the only part that is committed. The files live in
**`.vendor/<name>/`**, hidden and gitignored, a byte-for-byte copy of that commit, imported as
a path dependency (`path = "../../.vendor/toml"`). Today: `toml` (eider-pkg), `json` and
`markdown` (eider-doc; `json` also tests/crypto). A tool that needs them fetches each pin on
first use (`sh scripts/vendor.sh fetch`, which scripts/eider-pkg, scripts/docs.sh,
tests/crypto/run.sh, tests/packages.sh, scripts/test-compiler.sh and scripts/check-tools.sh
run), as `scripts/fetch-awslc.sh` does for AWS-LC, from the first of:

1. the library's checkout: `EIDER_<NAME>` (e.g. `EIDER_JSON`), else
   `$EIDER_SIBLINGS/eider-<name>` (default `../eider-<name>`), when it has the commit;
2. a git mirror: `$EIDER_VENDOR_SOURCES/eider-<name>.git`, else eider-pkg's mirror of the
   pinned URL in its store (`$EIDER_HOME/git/`), else that mirror cloned or updated from the
   URL over the network;
3. a release tarball: `$EIDER_VENDOR_SOURCES/eider-<name>-<version>.tar.gz` (or
   `-<commit>.tar.gz`), else GitHub's archive of the commit, downloaded.

`EIDER_VENDOR_SOURCES` is a directory of mirrors and tarballs for offline machines, and
`EIDER_VENDOR_OFFLINE=1` keeps the fetch off the network. Nothing is trusted on first use:
whatever the source, the files must have the pinned content hash (and a tarball that records
a commit, the pinned commit), else the fetch stops with exit 1 and writes nothing; a copy in
.vendor/ that was edited is an error too, and one left from an older pin is fetched again.
When no source has a pin the exit status is 3 and the message names what was tried: the tool
stops, and scripts/verify.sh skips the legs that need .vendor/ with that reason (a fresh clone
with neither the siblings nor the network). The compiler needs none of this: eiderc builds
from the seed with only a C compiler and no network (U2, U22). .vendor/ is never edited here:
a change is made, tested and released in the library's repository and then pinned
(`scripts/vendor.sh check`, a verify leg, holds the pins to their format, every fetched copy to
its hash, and, when the checkout is present, the pinned commit to the hash and the copy to the
commit byte for byte). A library pinned here has no dependencies of its own (they would be git
dependencies of a path package, outside the pins).

## Dependencies

Building Eider must stay cheap to bootstrap and audit. The rule:

- **To build the compiler from the seed:** a C11 compiler and a POSIX.1-2008 C library with
  threads (`-pthread`). Nothing else: no other language toolchain (no Python), no make,
  no third-party C libraries, no particular C compiler (gcc and clang both work; anything C11
  should). The compiler builds from its WebAssembly seed with only that: `cc seed/wasm2c.c`,
  translate `seed/eiderc.wasm`, `cc` the result with `core/eider_core.c` (seed/README.md)
  is the whole bootstrap.
- **The language runtime (`core/`) and the compiler (`compiler/`)** may only depend on that. New
  C in core must use only C11 + POSIX; a new dependency for the runtime or the compiler needs a
  design decision recorded here first. The driver also runs the POSIX utilities `ar` (for
  `build --lib`) and `cp` (to copy a cached binary out for `build`), and asks `$CC --version`
  for the cache key (a compiler without it just gets an empty part).
- **The ecosystem tools here (eider-pkg, eider-doc, the crypto tests)** may fetch pinned
  sources once (U22): the libraries in `vendor.lock`, into `.vendor/`, each checked against its
  content hash ("Vendored libraries" above), from a sibling checkout, a mirror or tarball, or
  the network. The compiler never does: it needs only the C compiler.
- **Building programs** needs clang 17 or newer: `build`, `run`, `test` and `build --lib` go
  through the LLVM backend (compiler/llvm.ei; docs/compiler.md, "Backends"), whose IR clang
  compiles (U23). Building the compiler itself from the seed still needs only the C compiler,
  and so do `check`, `emit-llvm` and the other commands that build nothing. `build --wasm` needs
  clang with the wasm32 target and `wasm-ld`.
- **Cryptography is the one scoped exception to "no third-party C libraries"** (decisions U12,
  C1, C2, C140-C146; core/crypto/README.md). Eider never implements primitives: hashes,
  MACs, KDFs, AEADs, key agreement and signatures come from an **OpenSSL-compatible
  libcrypto** reached through one glue file, `core/crypto/eider_crypto.c`, written once
  against the subset of the OpenSSL API listed in the README; protocols above the primitives
  (TLS 1.3, X.509) are written in Eider. The backend is swappable at link time behind that one
  ABI: **AWS-LC is the default**, pinned (tag, commit, tarball SHA-256, per-file SHA-256s in
  core/crypto/awslc/) and compiled from its C and pre-generated assembly by the same `$CC`, with
  no CMake, Go or Perl, so a crypto-using program still needs only a C compiler once the pinned
  sources are fetched (`scripts/fetch-awslc.sh`; they are fetched rather than committed: 23 MB).
  OpenSSL 3 (system, dynamic) and LibreSSL (fetched and built into target/) are optional
  backends; BoringSSL is supported by the code but not built. The FIPS build of AWS-LC (CMake
  + Go) is opt-in. Only programs that import `core/crypto` link a backend, so the bootstrap
  and every other program are unchanged, and a plain checkout's verify.sh skips the crypto
  legs with the reason. Upstream vectors (RFCs, NIST CAVP, Wycheproof) gate every backend,
  and every pair of backends must agree byte for byte (tests/crypto/run.sh).
- **Development and test tooling** may use more: `sh` for the scripts, `git` (package-manager
  tests), a second C compiler (clang), sanitizer runtimes (ASan/UBSan/TSan) and `node` (the
  wasm test, and the tree-sitter CLI of the grammar check, `scripts/check-tools.sh`). The differential oracle is the recorded `tests/oracle/` (docs/compiler.md, "C7:
  recording the oracle"), not a second compiler. `scripts/verify.sh` skips a leg, with the reason,
  when its tool is missing.

Rules of thumb:

- New C goes in core only if it is an OS call Eider cannot make otherwise. Anything that can be written in Eider is.
- A module goes in std only if most programs would use it. Formats, algorithms and tools are packages.
- `compiler/` self-hosts and is committed compiled to WebAssembly as `seed/eiderc.wasm` (with the translator `seed/wasm2c.c`), so building the compiler needs only a C compiler (`scripts/ei` does it; `scripts/selfhost.sh --from-seed` checks that the seed reproduces itself). The tests' expected results are recorded in `tests/oracle/` (docs/compiler.md, "History").

Tooling:

- `scripts/ei <eiderc args>`: the compiler, `target/eiderc`: stage0 (the seed through wasm2c, built with `$CC`) builds compiler/ natively with clang 17+, else it is stage0 itself; rebuilt when missing or older than the seed or `core/` (eiderc links the C core into every program itself).
- `scripts/ei-crypto [--crypto <backend>] <eiderc args>`: scripts/ei with a crypto backend linked (built by `scripts/crypto-build.sh` when needed); `scripts/fetch-awslc.sh` fetches the pinned AWS-LC sources (`--repin` moves to a new release), `scripts/fetch-crypto-vectors.sh` re-creates tests/crypto/vectors from upstream, `scripts/crypto-bench.sh` measures each backend (core/crypto/README.md).
- `scripts/migrate-imports.sh <dirs>`: rewrites path imports that cross into another package (core, std, a declared dependency) into package imports; run on compiler/, std/, core/, packages/ and tests/ once the seed knows package imports (docs/compiler.md, "C8.3"). (`scripts/bootstrap-deps.sh`, which linked a `deps/` farm into each package, is retired: nothing needs it.)
- `scripts/migrate-caps.sh <dirs>`: removes the `ffi` that `uses` clauses carried only to call another package (`ffi` stays inside the package with the unmanaged code since C8.5); already run on compiler/, std/, packages/, tests/ and examples/, and kept for code written before C8.5 (docs/compiler.md, "C8.5: capabilities per package").
- `scripts/migrate-var.sh <dirs>`: rewrites the deprecated `var` as `let mut` (`.copy()` after a place) through `eiderc migrate-var`, leaving the cases where that would change the meaning; run on compiler/, std/, core/, packages/, tests/ and examples/ once the seed knows `let mut` (docs/compiler.md, "C8.6: references by default").
- `tests/std/run.sh`, `tests/packages.sh`: suites for std, and for the packages and the pinned libraries in .vendor/ (both run by `scripts/verify.sh`).
- `scripts/vendor.sh fetch [<name>...] | check | list | <name> <commit>`: the pinned libraries, `vendor.lock` and `.vendor/` ("Vendored libraries" above); `fetch` and `check` are the vendor leg of `scripts/verify.sh`.
- `scripts/docs.sh [test]`: builds the documentation site into `target/site` with eider-doc (docs/site, docs/site/tooling/eider-doc.md), or runs its doc tests (both run by `scripts/verify.sh`).
- `tests/pkg/run.sh`: eider-pkg end to end against local git repositories under `target/tmp/pkgtest/` (no network; also run by `scripts/verify.sh`).
- `scripts/check-tools.sh`: the sibling repositories against this checkout (`EIDER_<NAME>` for each, else `$EIDER_SIBLINGS/<repository>`, default `..`): eider-analyzer (the language server, written in Eider, with `compiler/` as a path dependency) is built and tested, tree-sitter-eider's `scripts/check-eider-lang.sh` must parse every `.ei` file here without ERROR or MISSING nodes, and each library repository (eider-toml, eider-json, eider-markdown, eider-http, eider-rpc, eider-openapi) is built and tested (its `scripts/test.sh`) with its git dependencies taken from the sibling checkouts (`EIDER_PKG_OVERRIDE`, docs/site/tooling/eider-pkg.md) and json from .vendor/json when eider-json is absent. It is the "tools" leg of `scripts/verify.sh`; a missing repository or tool (the tree-sitter CLI needs `node`) is a skipped leg, so a plain checkout stays green.
- `scripts/version.sh [check | check-siblings | bump <major, minor or patch> [component]]` and `scripts/release.sh`: the one version (`VERSION`, its Eider copy `core/version.ei`) of the language, eiderc, core, std, eider-pkg and eider-doc, which eider-analyzer, tree-sitter-eider, eider-profiler and (before 1.0) the library repositories share at MAJOR.MINOR with their own PATCH, released together as one bundle (docs/site/tooling/releases.md; U18, C220-C226). `check` is a leg of `scripts/verify.sh`, `check-siblings` part of its tools leg.

**A syntax or IDE-visible change updates the grammar and analyzer in the same wave.** A new token, keyword, operator, item, statement, pattern or literal form, or a change to what the IDE shows (prelude items, built-in types and methods, symbols, diagnostics with fixes), lands together with the matching change to tree-sitter-eider (grammar.js, the queries, a `test/corpus` case) and to eider-analyzer (the lexical stand-in, completion and hover, a session test), committed in their repositories in the same wave. The "Syntax changes (for the tree-sitter grammar)" paragraph of each docs/compiler.md section says what the grammar needs. `scripts/verify.sh` is not ALL GREEN with the tools leg failing: before C152 the two drifted from C8.2 to C8.25 unnoticed, and editors showed false errors such as "expected `=`" on `let mut`.

Known limits of this arrangement (all need compiler work):

- `str` has no byte access, so literals become bytes through `sys.lit` (an ffi call). (C8.2
  adds `str.bytes()`/`byte(i)`; std switches with 8.9, after the seed has them.)
- No bitwise operators: eider-pkg's `sha256` uses arithmetic and a byte table. (C8.2 adds
  them; it and `compiler/sha256.ei` can use them once the seed is regenerated.)

Known gaps in core/std (fix in core, not by working around them in packages):

- None open. (`proc` capturing only stdout with no timeout was closed by `ec_run`'s capture modes and deadline, core/ABI.md "Running a program".)
