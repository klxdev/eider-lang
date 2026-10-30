# Layers

Eider code is partitioned into three layers. Dependencies only point down.

| Layer | Where | Language | What belongs here |
|---|---|---|---|
| core | `core/` | C (`eider_core.c`) + Eider (`sys.ei`) | The OS boundary and nothing else. One OS call per C function, errors as `-errno`, no logic, no pointers exposed to Eider (data crosses a byte at a time through the core's buffers). `sys.ei` is the only module allowed to use `extern`/`unsafe`. |
| std | `std/` | Eider | What almost every program needs: `bytes` (text as `List[u8]`), `fs`, `io`, `env`, `proc`. Imports only core and other std modules. |
| packages | `packages/<name>/` | Eider | Everything else, as ordinary packages with an `eider.toml`: `toml`, `semver`, `sha256`, and the package manager itself. They import `deps/core/...`, `deps/std/...` and `deps/<dep>/...`. |

Rules of thumb:

- New C goes in core only if it is an OS call Eider cannot make otherwise. Anything that can be written in Eider is.
- A module goes in std only if most programs would use it. Formats, algorithms and tools are packages.
- The Rust compiler in `src/` is the bootstrap: it compiles Eider to C and is not extended. Language features wait for the self-hosted compiler.

Tooling:

- `scripts/ei <eider args>`: the compiler with the C core linked (`-l eider_core`).
- `scripts/bootstrap-deps.sh`: links `deps/core` and `deps/std` into each package so the package manager can be built before it exists.
- `tests/std/run.sh`, `tests/packages.sh`: suites for std and packages (both run by `scripts/verify.sh`).

Known limits of this arrangement (all need compiler work):

- Every caller of std needs `uses ffi`, because capabilities propagate and std sits on `extern` calls.
- `str` has no byte access, so literals become bytes through `sys.lit` (an ffi call).
- Module names are file stems, so two packages can't both contain `util.ei` (E0808).
- No bitwise operators: `sha256` uses arithmetic and a byte table.
