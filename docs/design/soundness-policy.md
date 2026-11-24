# Soundness bugs

A **soundness bug** is a program in the safe subset (no `unsafe`, no package granted `ffi`) that the compiler
accepts and that has undefined behaviour or breaks a rule of `memory-safety.md`: an out-of-bounds access, a use
after free, a double free, a data race, a type confusion, a read of uninitialised memory. It does not matter whether
the cause is the checker, the backend, the C core or the standard library: the claim is about what a user can write.

## Reporting and triage

- Open an issue with the label **`soundness`** (private security reports: say so in the issue and give the
  reproduction by other means). Give the smallest program, the compiler version, and what you saw (a sanitizer
  report is ideal; `EIDER_CFLAGS="-fsanitize=address,undefined" eiderc run prog.ei`).
- Severity: **S0** memory corruption reachable from safe code without a trap; **S1** a data race, or a use after free
  that needs unusual input; **S2** a rule that is too weak but not (yet) exploitable; **S3** a program that is
  rejected although it is safe (a completeness bug: not soundness, but filed here to keep the corpus honest).
- An S0 or S1 fix is the next release's first item.

## What a fix must contain

1. The fix.
2. A regression test in `tests/safety/` (a program that must now be rejected in `fail/`, or whose behaviour is
   pinned in `run/`), named for the rule it concerns. If no rule covers it, add one to `memory-safety.md`.
3. A line under a **Soundness** heading of that release's section in `CHANGELOG.md`: what was wrong, the first
   version that had it if known, the fix.

## Evidence

Every release states the sanitizer legs that ran and, when the fuzzing budget exists (#246), how much fuzzing the
accepted-program corpus received and with what result. A release that skipped a sanitizer leg says which.
