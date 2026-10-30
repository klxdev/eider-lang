# Layers

Anything that is not Eider is unmanaged code: it is outside the language's safety checks and
is a security and performance risk. The goal is that the only unmanaged code is the C core,
and that the core is as small as it can be.

Eider code is partitioned into three layers. Dependencies only point down.

| Layer | Where | Language | What belongs here |
|---|---|---|---|
| core | `core/` | C (`eider_core.c`, `eider_rt.{h,c}`) + Eider (`sys.ei`) | `eider_rt` is the language runtime generated C calls (traps, checked arithmetic, allocation, String, print, thread primitives; `core/RUNTIME.md`). Otherwise the OS interop boundary and nothing else, specified in `core/ABI.md` so each OS or architecture is one backend file. One OS call per C function, errors as `-errno`, no logic, no pointers exposed to Eider (data crosses a byte at a time through the core's buffers). `sys.ei` is the only module allowed to use `extern`/`unsafe`, and it binds only `ec_*` core symbols. |
| std | `std/` | Eider | What almost every program needs: `bytes` (text as `List[u8]`), `fs`, `io`, `env`, `proc`. Imports only core and other std modules. |
| packages | `packages/<name>/` | Eider | Everything else, as ordinary packages with an `eider.toml`: `toml`, `semver`, `sha256`, the package manager itself, and `fuzz` (the compiler differential fuzzer, `scripts/fuzz-check.sh`). They import `deps/core/...`, `deps/std/...` and `deps/<dep>/...`. |

Rules of thumb:

- New C goes in core only if it is an OS call Eider cannot make otherwise. Anything that can be written in Eider is.
- A module goes in std only if most programs would use it. Formats, algorithms and tools are packages.
- This repository contains no Rust. The stage-0 compiler (Eider to C) is the temporary Rust bootstrap in the separate `eider-bootstrap` repository, located by `scripts/stage0.sh` (default `../eider-bootstrap`). It is frozen: fixes only. It is retired when `compiler/` self-hosts and its generated C is committed as the seed; then building Eider needs only a C compiler (docs/compiler.md).

Tooling:

- `scripts/ei <eider args>`: the compiler with the C core linked (`-l eider_core`).
- `scripts/bootstrap-deps.sh`: links `deps/core` and `deps/std` into each package so the package manager can be built before it exists.
- `tests/std/run.sh`, `tests/packages.sh`: suites for std and packages (both run by `scripts/verify.sh`).
- `tests/pkg/run.sh`: eider-pkg end to end against local git repositories under `target/tmp/pkgtest/` (no network; also run by `scripts/verify.sh`).

Known limits of this arrangement (all need compiler work):

- Every caller of std needs `uses ffi`, because capabilities propagate and std sits on `extern` calls.
- `str` has no byte access, so literals become bytes through `sys.lit` (an ffi call).
- Module names are file stems, so two packages can't both contain `util.ei` (E0808).
- No bitwise operators: `sha256` uses arithmetic and a byte table.
