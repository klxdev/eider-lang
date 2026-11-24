# A formal model of the safe subset

Part of #246 (workstream G). Nothing here is proved yet. This is the plan for the proof, with the calculus fixed
enough to start: what is modelled, what the theorem says, how the proof is staged, and what tool checks it. It is
written against the rules S1 to S13 of `memory-safety.md`.

## What is proved, and why it is not everything

The theorem is the claim of `memory-safety.md` for a **core calculus** of the safe subset, not for the compiler. A proof about
a calculus does not show that `eiderc` implements the calculus. That gap is closed by the other workstreams (the corpus,
the differential fuzzing against an executable semantics, the C-core checks). The proof's job is narrower and still the one
no test can do: show that **the rules, as stated, are sufficient** (no program they accept can get stuck on a memory
error), including the unusual ones: the protection rule, aliases that write the original, and copy-on-write.

## The calculus (λ-Eider)

Values and places, as in `memory-model.md`:

- **Heap buffers** with a count: a `String`, `List` or `Map` is a pair (buffer id, length) over a store `σ : id → (count, cells)`.
- **Places**: a variable, a field `p.f`, an index `p[i]`, a payload. A place denotes a path from a variable through
  buffers.
- **Bindings**: `let x = e` (a read-only reference to the place `e` when `e` is a non-scalar place, else a copy);
  `let mut x = p` (a mutable alias of the place `p`); `x.copy()` (a fresh deep copy).
- **Calls**: `inout p` borrows the place `p` for the call (S7); closures capture a snapshot, or by reference when they
  run before their call returns (S10).
- **Threads**: `spawn`, `Chan`, `Mutex`, with the crossing rule of S11 (a value is made deeply unique when it crosses).
- **Traps**: bounds, overflow, `Ref` conflicts step to the terminal state `trap`, which is safe.

Out of the first model: `Map` iteration snapshots, `defer`, generics and traits (a monomorphised program is a program
of the calculus), `Ref` and `unsafe`/`ffi`. They are added after the core is proved.

## The theorem, in stages

Each stage is a theorem with its own proof, so the work can stop at any of them with something real.

1. **Typing and progress/preservation without aliases and threads.** Well-typed programs do not get stuck and never read
   out of bounds; every owned buffer is dropped exactly once. (Establishes S1, S5 for the single-threaded, alias-free
   fragment. Standard.)
2. **Copy-on-write is a refinement of value semantics.** A program run with shared buffers and counts is observationally
   equal to one run where every copy is eager. (Justifies the count-based store; the load-bearing invariant is "a buffer is
   written only when its count is 1 after `ensure_unique`".)
3. **The protection rule and `let` references (S6 to S9).** If the checker accepts the program, then at every step the places
   named by a live read-only reference are unchanged and still allocated. This is the novel part: references are *re-derived
   places*, not pointers, so the statement is about paths, not addresses.
4. **Mutable aliases and `inout` exclusivity (S7, S8).** Two live names for overlapping places never allow a write through one
   while the other is read, except through the alias's declared write path.
5. **Threads (S11).** If every crossing deep-uniques, then no buffer reachable from a thread is reachable from another,
   so there is no data race on a count or a cell; `Mutex` and `Chan` are the only shared cells. (Needs the *complete list of
   crossing points* as an input; the corpus and TSan check that list against the implementation.)

## The tool

Lean 4 (mathlib for the finite-map and relation lemmas), because the proof is mostly structural induction over a small
operational semantics and Lean's tactic and automation story is the most maintainable for a small team. Coq is the
alternative if the maintainer prefers it; the statement does not change. **Neither is installed on the build machine** (checked
2026-11-23: no `lean`, `lake`, `coqc`), so the first step of this workstream is a decision and an installation.

## The executable semantics (the "Miri mode")

In parallel, and sooner than the proofs: `compiler/interp.ei` is an IR interpreter that already runs comptime programs. Giving it
a **checked store** (every buffer has an owner count, every access is range-checked against the live allocation, every
reference carries the path it names, and the protection rule is re-checked on each write) makes it an executable version of the
calculus above. Running the whole test corpus and the fuzzer's accepted programs through it, and comparing with the LLVM
backend, gives the differential test of workstream C and the evidence that the calculus and the compiler agree.

## Work, in order

1. Fix the grammar and the store of λ-Eider in this file (the part above is the sketch); get it reviewed.
2. Decide the tool; install it; set up `scripts/proofs.sh` and a verify leg that skips with a reason when it is absent.
3. Stage 1, then 2 (they are routine), then 3 (the contribution). Each stage lands with its theorem statement even before
   the proof is complete, marked `sorry`/`admit`, and the leg reports how many are left.
4. The checked-store interpreter, in parallel with 2 to 3.
5. Stages 4 and 5, then the extensions listed under "Out of the first model".

Estimated effort for stages 1 to 3 by someone fluent in a proof assistant: a few months; by someone learning it, a year.
That is why the plan is staged, and why the executable semantics comes first.
