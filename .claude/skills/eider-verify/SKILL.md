---
name: eider-verify
description: Run the full Eider verification matrix (compile-fail suite, run tests on gcc/clang/ASan/TSan, C/C++ export, WebAssembly). Use after any compiler change.
---
Run `scripts/verify.sh` from the repo root. It must end with `ALL GREEN`.
New error codes need an entry in `ALL_CODES` (eider-bootstrap `src/diag.rs`, and `compiler/diag.ei` once the self-hosted compiler checks) and a `tests/checks/fail/*.ei` file (`// expect: CODE LINE:COL`; the header is line 1).
