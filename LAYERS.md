# Layers

Anything that is not Eider is unmanaged code: it is outside the language's safety checks and
is a security and performance risk. The goal is that the only unmanaged code is the C core,
and that the core is as small as it can be.

Eider code is partitioned into three layers. Dependencies only point down.

| Layer | Where | Language | What belongs here |
|---|---|---|---|
| core | `core/` | C (`eider_core.c`, `eider_rt.{h,c}`; `wasm/`, the runtime's optional WebAssembly backend; `crypto/eider_crypto.c`, the glue to a crypto library) + Eider (`sys.ei`, `os.ei`, `crypto.ei`, `prelude.ei`) | `eider_rt` is the language runtime generated C calls (traps, checked arithmetic, allocation, String, print, thread primitives with guarded stacks, atomics; `core/RUNTIME.md`). `prelude.ei` is the language's own Eider source that every program sees (Option, Result and their methods, and the operation traits `Copy`, `Eq`, `Ord`, `Hash`, `Show`, `Iter`, `Drop` with `Ordering`, docs/compiler.md "C8.4: operation traits"; its text is fixed, since positions recorded in `tests/oracle/` depend on it, so additions go at its end); it stays that tiny. Otherwise the OS interop boundary and nothing else, specified in `core/ABI.md` so each OS or architecture is one backend file. One OS call per C function, errors as `-errno`, no logic, no pointers exposed to Eider (data crosses a byte at a time through the core's buffers). `sys.ei`, `os.ei` and `crypto.ei` are the only modules allowed to use `extern`/`unsafe`, and they bind only `ec_*` core symbols (`crypto.ei` only `ec_crypto_*`, core/crypto/README.md); core is the one package the toolchain grants `ffi`, and each wrapper declares the real capability of its call (`fs`, `io`, `net`, `clock`) next to it (docs/compiler.md, "C8.5"). `sys.ei` has the buffers, files, environment and `ec_run`; `os.ei` the Layer 0 OS primitives (descriptors, sockets, DNS, readiness, time, signals, randomness, processes) and the atomic cells std/atomic holds by handle (core/ABI.md "Atomic cells": CPU operations, not OS ones, under the same rules). They are separate so the compiler, which imports `sys` (and `std/proc`), does not carry the OS bindings: everything the compiler imports is part of `seed/eiderc.c`. |
| std | `std/` | Eider | What almost every program needs: `bytes` (text as `List[u8]`), `fs`, `io`, `env`, `proc`, and the thin OS layer over core/ABI.md's primitives: `fd` (descriptors), `net` (sockets, DNS), `poll` (readiness), `time`, `random` (OS CSPRNG), `signal`, `child` (processes as streams); and the runtime layer (docs/runtime.md): `atomic`, `sync` (Lock, Parker), `chan` (bounded channels, select), `task` (cancellation tokens, task groups, a thread pool), `event` (event loop and timers), with `Duration`/`Deadline` (and the `Clock` trait) in `time`; and the foundation (docs/std.md): `stream` (Reader/Writer, typed I/O errors, buffered streams, deadlines), `path`, `strings`, `utf8`, `fmt`, `sort`, `deque`, `set`, `heap`, `encoding`, `testing` (assertions and deterministic test doubles). Imports only core and other std modules. The compiler imports `bytes`, `fs`, `io`, `env` and `proc`, so those are part of the seed and change only with a seed regeneration. | |
| packages | `packages/<name>/` | Eider | Everything else, as ordinary packages with an `eider.toml`: `toml`, `semver`, `sha256`, `json`, `http` (HTTP/1.1 server, client, router and JSON-RPC 2.0; docs/services.md), the package manager itself, `fuzz` (the compiler's crash and consistency fuzzer, `scripts/fuzz-check.sh`), `markdown` (a CommonMark subset to HTML) and `doc` (eider-doc, the documentation site generator and doc-test runner, `scripts/docs.sh`). A package imports `"core/<module>"`, `"std/<module>"` and its declared dependencies by name (`"toml"`, `"json/<module>"`), located through its eider.lock (docs/compiler.md, "C8.3: packages and modules"). Until the seed knows package imports, the packages in this repository import the toolchain and each other by relative path (`"../../std/fs.ei"`, `"../toml/toml.ei"`). |

The compiler (`compiler/`, docs/compiler.md) is a program on top of these layers, but it may
depend only on core and std: it builds itself from the seed with nothing else, and packages
are resolved by a package manager that the compiler builds. So when the compiler needs an
algorithm that lives in a package, it carries a small module of its own rather than pulling
the algorithm into std. Such cases are `compiler/lock.ei` (the compiler's reader for
eider.toml and eider.lock, the TOML subset of packages/toml) and `compiler/sha256.ei`, the hash of the driver's
binary and core-object cache (a copy of `packages/sha256`, made faster with an XOR table and
by not copying the input). Moving sha256 into std was rejected: std is for what most
programs need, and a hash is a package by the rule below. The copy can go once the seed
knows package imports (docs/compiler.md, "C8.3: packages and modules"): then the compiler
can take a pinned package from the repository as a path dependency.

## Dependencies

Building Eider must stay cheap to bootstrap and audit. The rule:

- **To build the compiler from the seed, and to build any Eider program:** a C11 compiler and a
  POSIX.1-2008 C library with threads (`-pthread`). Nothing else: no other language toolchain (no Python), no make,
  no third-party C libraries, no particular C compiler (gcc and clang both work; anything C11
  should). `cc -std=c11 -O2 -pthread -I core -o eiderc seed/eiderc.c core/eider_rt.c core/eider_core.c`
  is the whole bootstrap.
- **The language runtime (`core/`) and the compiler (`compiler/`)** may only depend on that. New
  C in core must use only C11 + POSIX; a new dependency for the runtime or the compiler needs a
  design decision recorded here first. The driver also runs the POSIX utilities `ar` (for
  `build --lib`) and `cp` (to copy a cached binary out for `build`), and asks `$CC --version`
  for the cache key (a compiler without it just gets an empty part).
- **Optional targets** may need more, and stay optional: `build --wasm` needs clang with the
  wasm32 target and `wasm-ld`.
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
- `compiler/` self-hosts and its generated C is committed as `seed/eiderc.c`, so building Eider needs only a C compiler (`scripts/ei` does it; `scripts/selfhost.sh --from-seed` checks that the seed reproduces itself). The tests' expected results are recorded in `tests/oracle/` (docs/compiler.md, "History").

Tooling:

- `scripts/ei <eiderc args>`: the compiler, `target/eiderc`, built from `seed/eiderc.c` with `$CC` when it is missing or older than the seed or `core/` (eiderc links the C core into every program itself).
- `scripts/ei-crypto [--crypto <backend>] <eiderc args>`: scripts/ei with a crypto backend linked (built by `scripts/crypto-build.sh` when needed); `scripts/fetch-awslc.sh` fetches the pinned AWS-LC sources (`--repin` moves to a new release), `scripts/fetch-crypto-vectors.sh` re-creates tests/crypto/vectors from upstream, `scripts/crypto-bench.sh` measures each backend (core/crypto/README.md).
- `scripts/migrate-imports.sh <dirs>`: rewrites path imports that cross into another package (core, std, a declared dependency) into package imports; run on compiler/, std/, core/, packages/ and tests/ once the seed knows package imports (docs/compiler.md, "C8.3"). (`scripts/bootstrap-deps.sh`, which linked a `deps/` farm into each package, is retired: nothing needs it.)
- `scripts/migrate-caps.sh <dirs>`: removes the `ffi` that `uses` clauses carried only to call another package (`ffi` stays inside the package with the unmanaged code since C8.5); already run on compiler/, std/, packages/, tests/ and examples/, and kept for code written before C8.5 (docs/compiler.md, "C8.5: capabilities per package").
- `scripts/migrate-var.sh <dirs>`: rewrites the deprecated `var` as `let mut` (`.copy()` after a place) through `eiderc migrate-var`, leaving the cases where that would change the meaning; run on compiler/, std/, core/, packages/, tests/ and examples/ once the seed knows `let mut` (docs/compiler.md, "C8.6: references by default").
- `tests/std/run.sh`, `tests/packages.sh`: suites for std and packages (both run by `scripts/verify.sh`).
- `scripts/docs.sh [test]`: builds the documentation site into `target/site` with eider-doc (docs/site, docs/site/tooling/eider-doc.md), or runs its doc tests (both run by `scripts/verify.sh`).
- `tests/pkg/run.sh`: eider-pkg end to end against local git repositories under `target/tmp/pkgtest/` (no network; also run by `scripts/verify.sh`).
- `scripts/check-tools.sh`: the editor tooling, which lives in its own repositories next to this one (`EIDER_ANALYZER`, `TREE_SITTER_EIDER`; default `../eider-analyzer`, `../tree-sitter-eider`): eider-analyzer (the language server, written in Eider, with `compiler/` as a path dependency) is built and tested against this checkout, and tree-sitter-eider's `scripts/check-eider-lang.sh` must parse every `.ei` file here without ERROR or MISSING nodes. It is the "tools" leg of `scripts/verify.sh`; a missing repository or tool (the tree-sitter CLI needs `node`) is a skipped leg, so a plain checkout stays green.

**A syntax or IDE-visible change updates the grammar and analyzer in the same wave.** A new token, keyword, operator, item, statement, pattern or literal form, or a change to what the IDE shows (prelude items, built-in types and methods, symbols, diagnostics with fixes), lands together with the matching change to tree-sitter-eider (grammar.js, the queries, a `test/corpus` case) and to eider-analyzer (the lexical stand-in, completion and hover, a session test), committed in their repositories in the same wave. The "Syntax changes (for the tree-sitter grammar)" paragraph of each docs/compiler.md section says what the grammar needs. `scripts/verify.sh` is not ALL GREEN with the tools leg failing: before C152 the two drifted from C8.2 to C8.25 unnoticed, and editors showed false errors such as "expected `=`" on `let mut`.

Known limits of this arrangement (all need compiler work):

- `str` has no byte access, so literals become bytes through `sys.lit` (an ffi call). (C8.2
  adds `str.bytes()`/`byte(i)`; std switches with 8.9, after the seed has them.)
- No bitwise operators: `sha256` uses arithmetic and a byte table. (C8.2 adds them; the
  packages and `compiler/sha256.ei` can use them once the seed is regenerated.)

Known gaps in core/std (fix in core, not by working around them in packages):

- None open. (`proc` capturing only stdout with no timeout was closed by `ec_run`'s capture modes and deadline, core/ABI.md "Running a program".)
