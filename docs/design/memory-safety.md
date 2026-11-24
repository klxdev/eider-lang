# Memory safety: the claim, the rules, the trusted base

Status: **specification, first version** (#246). Nothing here is a proof. It says what Eider claims, which rule
enforces each part, what is checked today, and what is not yet. `memory-model.md` explains the design; this file is
what a reviewer or an auditor checks it against.

## The claim

> A program accepted by `eiderc` that contains no `unsafe` block and uses no package granted `ffi` cannot read or
> write out of bounds, use memory after it was freed or free it twice, reinterpret a value as another type, read
> uninitialised memory, or have a data race. Integer overflow, a failed bounds check and misuse of a `Ref` are
> *defined*: they trap.

This holds **unless the trusted base below is wrong**. A violation of the claim in the safe subset is a *soundness
bug*, whatever its cause, and is handled by `soundness-policy.md`.

### Outside the claim

- Code inside `unsafe` blocks or in a package granted `ffi`, and the C it calls.
- Memory leaks, stack and heap exhaustion (a defined crash: "Stack overflow" in `core/RUNTIME.md`), deadlock,
  starvation, logic errors, timing and other side channels.
- A trap that is *contained* (`Task.catch`, a pool job): the frames it abandons are not dropped (a leak, and a lock
  they held stays held, or is poisoned: C903). That is safe, not tidy.
- Bugs in clang, lld, libc or the kernel.

## The rules

Each rule has an ID, the mechanism that enforces it, and its tests (files in `tests/checks/fail` and
`compiler/tests/check/fail` that expect the code, counted on 2026-11-23; run-time rules cite their run tests).
`tests/safety/` (below) holds the tests written for this specification.

| ID | Rule | Enforced by | Tests today |
|---|---|---|---|
| S1 | Every index into an array, `List`, `String` or `str` is checked; a failed check traps | run time (`core/eider_rt.c`, "Conversions and bounds"); E0503 for a constant index into an array | 5 (E0503), `compiler/tests/run/traps*.ei`, ASan+UBSan legs |
| S2 | Arithmetic that overflows traps; `+% -% *%` wrap; `as` is checked; a constant shift out of range is rejected | run time ("Integer arithmetic"); E0501, E0502, E0505 | 6 (E0505), `tests/run/int16_overflow.ei` |
| S3 | There is no null: absence is `Option` | the type system | all of `std` |
| S4 | A binding is initialised where it is declared: there is no declaration without a value | the parser (E0001: `let x: i32` expects `=`) | `tests/safety/fail/s4_*` |
| S5 | Every owned value is dropped exactly once, on every exit path (end of block, `return`, `break`, `continue`, `?`); `defer` runs with the block's drops | the checker (`S_DROP` on every exit path); copy-on-write counts in the runtime ("Shared buffers") | the leak leg (`-DEI_RT_COUNT_ALLOCS`: every run test ends with no outstanding allocation) |
| S6 | A reference (`let x = place`) lives inside its scope: `inout` is not a type and cannot be a field, a result or a type argument | E0302 | 2 |
| S7 | A place passed `inout` cannot be borrowed again in the same call | E0301 | 16 |
| S8 | A write to a place requires `let mut`, a writable parameter or an `inout`; a mutable alias cannot be made of a read-only place | E0303, E0307 | 28 + 8 |
| S9 | The **protection rule**: while a read-only reference is used later, no write may change what it names | E0308 | 35 |
| S10 | A closure captures a snapshot; one that runs before its call returns captures by reference; a closure that would capture a reference and outlive it is rejected | E0308 (closure capture), the checker | `e0308_closure_captures_reference.ei` and others |
| S11 | Threads share mutable state only through `Mutex[T]` and `Chan[T]`; a value sent to a thread is moved or made unique first, so no reference count is shared by two threads; a `Ref` cannot cross (E0411) | the checker (E0411) + the runtime (uniqueness before crossing, `core/RUNTIME.md` "Threads") | 6 (E0411); `tests/safety/fail/s11_*`; `tests/safety/run/s11_crossing_points.ei` (every crossing point, under TSan where it works: 6 runs clean in the Fedora 44 container); `tests/run/threads.ei` |
| S12 | C is called only from a package granted `ffi`, inside `unsafe`, with C-safe types; a `List[u8]` goes to C as pointer and length | E0201, E0204, E0802, E0803 | 36 + 4 + 9 + 18 |
| S13 | A trap, a stack overflow and an out-of-memory failure end the process or the contained task in a defined way; none is undefined behaviour | `ei_trap`, the guard page, `"probe-stack"="inline-asm"` ("Stack overflow") | `compiler/tests/run/stack_overflow*.ei`; #196 |

## The trusted base

The claim depends on all of these being correct. Each has one line on how it is checked, and where it is weakest.

| Part | Size | How it is checked | Weakest point |
|---|---|---|---|
| The checker (`compiler/check.ei`) and the rules above | the largest file of the compiler | the compile-fail corpus, the fuzzer, the self-hosting fixed point | the rules are argued, not proved; 0.7.7 still changed them (#183, #198, #219) |
| The LLVM backend (`llvm.ei`, `llvm_abi.ei`) and clang/lld | | every run test through ASan+UBSan and TSan, the llvms leg (clang 17 to 23) | the backend writes IR by hand; a lowering bug breaks S5 or S11 without any checker rule firing |
| The C core (`core/eider_rt.c`, `eider_core.c`, `eider_prof.c`) | about 6,900 lines | `tests/core/` (rt_test, core_test, os_test: 637+ checks), ASan+UBSan and TSan builds | **it is C**: no language rule covers it; buffer and count code is the most sensitive (`ei_buf_*`, `ei_str_*`, list growth, map) |
| The comptime evaluator (`compiler/interp.ei`) | | compile-fail and run tests | an IR interpreter that implements the language a second time |
| The seed path (`seed/eiderc.wasm`, `wasm2c`) | | the self-host fixed point, byte-for-byte reproducibility | a miscompiled seed is a miscompiled compiler |
| `unsafe` and `ffi` code | about 180 mentions, **all in `core/`; none in `std/`** | review; per-package `ffi` grants | C can write past the end of a buffer it was given and nothing notices (workstream F) |
| libc, the kernel | | | |

## What is checked, and what is not

Checked today: the rules above by the corpus; every run test under ASan+UBSan, and under TSan where the system's TSan
works (Fedora 45's does not: `longjmp`; the Fedora 44 container in `scripts/release-env/` does); the C core under the
same sanitizers; a mutation fuzzer for the compiler (`packages/fuzz`).

**Not yet** (each is a workstream of #246): a differential check of the LLVM backend against the interpreter;
sanitizer runs of the programs the fuzzer's checker accepts; machine-checked buffer and count invariants in the C core;
a *proof* that the compiler's list of crossing points is complete (today: handle counts (`Task`, `Mutex`, `Chan`) are atomic;
buffer counts are not, and every crossing point applies a generated `own_` glue that makes the value deeply unique;
the crossing points are tested under TSan, `tests/safety/run/s11_crossing_points.ei`, but a point nobody thought of would
not be); a detector for an FFI overrun; a formal model of the protection rule and copy-on-write.

## Where the rules are tested for this specification

`tests/safety/fail` holds programs that **must be rejected** and `tests/safety/pass` programs that **must be
accepted**, each file named for its rule (`s9_*`). Run with `eiderc test --compile-fail tests/safety` (part of
`scripts/verify.sh`). A rule with no file in both directories is a gap, and the leg says so.
