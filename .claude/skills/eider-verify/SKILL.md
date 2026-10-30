---
name: eider-verify
description: Run the full Eider verification matrix (compile-fail suite, run tests on gcc/clang/ASan/TSan, the compiler against its recorded oracle, the seed, C/C++ export, WebAssembly). Use after any compiler change.
---
Run `scripts/verify.sh` from the repo root. It must end with `ALL GREEN`. It needs only a C compiler for the compiler itself (`scripts/ei` builds `target/eiderc` from `seed/eiderc.c`); clang, sanitizer runtimes, wasm-ld and node are needed for the legs that use them (a missing one is reported as `skip`).
After a change to `compiler/`, also run `sh scripts/selfhost.sh --seed` (must print `SELF-HOSTED`) and commit `seed/eiderc.c`.
If a change is meant to alter observable behaviour (diagnostics, run output, headers), run `BLESS=1 sh scripts/test-compiler.sh`, review `git diff tests/oracle` (and the goldens), and commit the expected files with the change.
New error codes need an entry in `diag.all_codes()` (`compiler/diag.ei`) and a `tests/checks/fail/*.ei` file (`// expect: CODE LINE:COL`; the header is line 1).
