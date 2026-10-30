# Layers

Anything that is not Eider is unmanaged code: it is outside the language's safety checks and
is a security and performance risk. The goal is that the only unmanaged code is the C core,
and that the core is as small as it can be.

Eider code is partitioned into three layers. Dependencies only point down.

| Layer | Where | Language | What belongs here |
|---|---|---|---|
| core | `core/` | C (`eider_core.c`, `eider_rt.{h,c}`; `wasm/`, the runtime's optional WebAssembly backend) + Eider (`sys.ei`, `prelude.ei`) | `eider_rt` is the language runtime generated C calls (traps, checked arithmetic, allocation, String, print, thread primitives; `core/RUNTIME.md`). `prelude.ei` is the language's own Eider source that every program sees (Option, Result and their methods; its text is fixed, since positions recorded in `tests/oracle/` depend on it); it stays that tiny. Otherwise the OS interop boundary and nothing else, specified in `core/ABI.md` so each OS or architecture is one backend file. One OS call per C function, errors as `-errno`, no logic, no pointers exposed to Eider (data crosses a byte at a time through the core's buffers). `sys.ei` is the only module allowed to use `extern`/`unsafe`, and it binds only `ec_*` core symbols. |
| std | `std/` | Eider | What almost every program needs: `bytes` (text as `List[u8]`), `fs`, `io`, `env`, `proc`. Imports only core and other std modules. |
| packages | `packages/<name>/` | Eider | Everything else, as ordinary packages with an `eider.toml`: `toml`, `semver`, `sha256`, the package manager itself, and `fuzz` (the compiler's crash and consistency fuzzer, `scripts/fuzz-check.sh`). They import `deps/core/...`, `deps/std/...` and `deps/<dep>/...`. |

The compiler (`compiler/`, docs/compiler.md) is a program on top of these layers, but it may
depend only on core and std: it builds itself from the seed with nothing else, and packages
are resolved by a package manager that the compiler builds. So when the compiler needs an
algorithm that lives in a package, it carries a small module of its own rather than pulling
the algorithm into std. The one such case is `compiler/sha256.ei`, the hash of the driver's
binary and core-object cache (a copy of `packages/sha256`, made faster with an XOR table and
by not copying the input). Moving sha256 into std was rejected: std is for what most
programs need, and a hash is a package by the rule below. The copy goes away when
package-qualified modules land (docs/compiler.md, "Language work" item 4) and the compiler
can take a pinned package from the repository.

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
- **Development and test tooling** may use more: `sh` for the scripts, `git` (package-manager
  tests), a second C compiler (clang), sanitizer runtimes (ASan/UBSan/TSan) and `node` (the
  wasm test). The differential oracle is the recorded `tests/oracle/` (docs/compiler.md, "C7:
  recording the oracle"), not a second compiler. `scripts/verify.sh` skips a leg, with the reason,
  when its tool is missing.

Rules of thumb:

- New C goes in core only if it is an OS call Eider cannot make otherwise. Anything that can be written in Eider is.
- A module goes in std only if most programs would use it. Formats, algorithms and tools are packages.
- `compiler/` self-hosts and its generated C is committed as `seed/eiderc.c`, so building Eider needs only a C compiler (`scripts/ei` does it; `scripts/selfhost.sh --from-seed` checks that the seed reproduces itself). The tests' expected results are recorded in `tests/oracle/` (docs/compiler.md, "History").

Tooling:

- `scripts/ei <eiderc args>`: the compiler, `target/eiderc`, built from `seed/eiderc.c` with `$CC` when it is missing or older than the seed or `core/` (eiderc links the C core into every program itself).
- `scripts/bootstrap-deps.sh`: links `deps/core` and `deps/std` into each package so the package manager can be built before it exists.
- `tests/std/run.sh`, `tests/packages.sh`: suites for std and packages (both run by `scripts/verify.sh`).
- `tests/pkg/run.sh`: eider-pkg end to end against local git repositories under `target/tmp/pkgtest/` (no network; also run by `scripts/verify.sh`).

Known limits of this arrangement (all need compiler work):

- Every caller of std needs `uses ffi`, because capabilities propagate and std sits on `extern` calls.
- `str` has no byte access, so literals become bytes through `sys.lit` (an ffi call).
- Module names are file stems, so two packages can't both contain `util.ei` (E0808).
- No bitwise operators: `sha256` uses arithmetic and a byte table.

Known gaps in core/std (fix in core, not by working around them in packages):

- None open. (`proc` capturing only stdout with no timeout was closed by `ec_run`'s capture modes and deadline, core/ABI.md "Running a program".)
