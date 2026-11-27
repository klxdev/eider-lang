# The C core: inventory, first audit, what to prove

Part of #246 (workstream D). The C core is the largest part of the trusted base that no language rule covers
(`memory-safety.md`): **5,724 lines** in `core/eider_core.c` (2,856: the OS) and `core/eider_rt.c` (2,868: the language
runtime), plus `eider_prof.c`, `eider_float.inc`, `eider_sip.inc` and `core/wasm/`. This is where a bug in S1, S5, S11
or S13 would live without any compiler diagnostic. Sizes below are lines per section marker, counted on 2026-11-23.

## Inventory, ranked by risk

Risk is judged by: raw buffer arithmetic, manual reference counts, code that runs in a signal handler or after `fork`,
hand-written assembly, parsing of data that came from outside, and concurrency without locks.

| Rank | Area | Lines | Why | Rules |
|---|---|---|---|---|
| R1 | shared buffers (copy-on-write), `String`, `String` bytes, allocation (`eider_rt.c`) | 94 + 82 + 59 + 55 | every `String`, `List` and `Map` buffer; manual counts; growth arithmetic | S1, S5 |
| R1 | the in/out buffers every `ec_*` call uses (`eider_core.c` "buffers", `arg`, `out_put`) | 54 | the boundary between Eider and the C core: NUL-separated strings, growing buffers | S1, S12 |
| R1 | what generated code calls inline (`eider_rt.c` "for generated code") | 317 | glue the backend emits calls to; wrong bounds here are wrong everywhere | S1, S5 |
| R2 | threads, thread stacks, tasks, context switch, stacks, run queues, worker loop, registry, parking, task start/end | 148 + 169 + 162 + 54 + 42 + 132 + 190 + 94 + 42 + 114 | `mmap`ed stacks with guard pages, an assembly context switch, signal handlers on an alternate stack, work stealing | S11, S13 |
| R3 | the reactor (descriptors and timers) | 744 | the biggest single section; shared tables under locks, wake-ups | S11 |
| R3 | parkers, atomic cells | 393 + 249 | lock-free and futex-style code | S11 |
| R4 | sockets and addresses, DNS | 360 + 248 | encodes and decodes addresses into byte buffers; `getaddrinfo` results and `recv` data copied into the out buffer | S1 |
| R5 | processes (`ec_spawn`, `ec_spawn_ex`, `ec_run_ex`, `ec_wait`) | 404 | `fork`; after it only async-signal-safe calls are allowed; pipe and descriptor ownership on every error path | S5, S12 |
| R6 | files, descriptors, time, signals, randomness, arguments and environment | 86 + 203 + 37 + 49 + 57 + 143 | thin wrappers over system calls | S12 |
| R6 | profiler (`eider_prof.c`), float printing (`eider_float.inc`), hashing (`eider_sip.inc`) | | optional or pure arithmetic | |

## What was run, and what it found (2026-11-23)

| Check | Result |
|---|---|
| `clang --analyze` (all default checkers) over `eider_rt.c` and `eider_core.c` | 6 warnings, **no real memory bug**: 4 `unix.Stream` reports on the `while ((n = fread(...)) > 0)` idiom (false positives: the read loop stops at the first short read); 1 `unix.MallocSizeof` (`calloc` of `uint64_t` assigned to `_Atomic(uint64_t)*`: same size, harmless); 1 `NonNullParamChecker` in `fmt_int` → `ei_str_cat` → `str_new`: the analyzer assumes a `String` with a null buffer and a nonzero length, which the invariant I1 below forbids. The invariant is the reason the warning cannot happen, and it is not written down in the code |
| Strict build (`-std=c11 -pedantic -Wall -Wextra -Wconversion -Wshadow -Werror`) | clean |
| ASan+UBSan builds of the runtime, core, OS and task tests | clean (`tests/core/run.sh`) |
| **Hardened build** (`-O2 -D_FORTIFY_SOURCE=3 -fstack-protector-strong -fstack-clash-protection`), now a configuration of `tests/core/run.sh` | 444 runtime, 92 core, 637 OS checks pass |
| TSan builds | pass on Fedora 44 (the release container); Fedora 45's TSan cannot follow `longjmp`, so they are skipped there |
| Programs the checker accepts, run under ASan+UBSan (the fuzzer, `SAN=1 scripts/fuzz-check.sh`) | no report so far; see the campaign numbers in #246 |

| CBMC 6.8 (`tests/cbmc/run.sh`, the release image) | **proved within the stated bounds, with pointer, bounds and overflow checks:** `ei_grow_cap` for all 64-bit inputs (no wrap, room for the request); `ei_buf_alloc`/`ei_buf_grow` size arithmetic for all 64-bit `n` (element size up to 16); `ei_list_open`/`ei_list_close` for every length, position and gap up to the bound (no access outside the buffer, `len <= cap`); `ei_str_cat` for every String and appended text of up to 2 bytes, `ei_str_slice` for every ASCII source of up to 3 bytes and every range (well formed result, I1). `heap_push`/`heap_remove` of the reactor's timer heap for every order of deadlines (ties included) of up to 4 waits (min-heap order, every wait's `hidx` its slot or -1, `hn` the live count, `next_dl` the earliest; `tests/cbmc/timer_heap.c`; a heap without the sift-down in `heap_remove` fails it). Not model-checked: appending a String to itself (too large for the solver; the runtime tests cover it under ASan), `out_put`/`arg` of the core (static functions of a large file), the rest of the reactor, the parkers and the process code |

Not available on this machine: `frama-c`, `clang-tidy`, `cppcheck`, `scan-build`. `valgrind` is.

## Invariants to write down and check

These are the facts the code relies on and no test states. Each becomes an `assert`-style check in the sanitizer
builds first (cheap, and it makes the analyzer warning above impossible to read as a bug), then a bounded model-checking
harness.

- **I1 (String).** `p == NULL` implies `len == 0` and `cap == 0`; `len <= cap`; when `p != NULL` the buffer has `cap + 1`
  bytes and `p[len] == 0`.
- **I2 (List, Map).** `len <= cap`; the buffer holds `cap` slots of the element size; slots below `len` are initialised.
- **I3 (counts).** A live buffer has count `>= 1`; a buffer is shared exactly when its count is `> 1`; `ei_buf_dec`
  returns true for exactly one holder; a count is never touched by two threads (S11).
- **I4 (in/out buffers).** `out_len <= out_cap` and `out_p[out_len] == 0`; the same for `in`; `arg(k)` returns a pointer
  inside `in_p` or NULL, never past `in_len`.
- **I5 (growth).** `ei_grow_cap`, `ei_buf_alloc` and `ei_buf_grow` never overflow `uint64_t` or `size_t`; a request that
  cannot be met traps ("out of memory") and never wraps.
- **I6 (task stacks).** A task's saved stack pointer is inside its mapping; the guard page is below it and has no access.

## R5 audit: `ec_spawn_ex`, `ec_run_ex`, `ec_wait` (2026-11-25)

Read line by line for descriptor ownership on every error path and for what runs after `fork`.

- **Ownership: correct.** Every pipe, `/dev/null` and file descriptor is closed on each path (open failure, `fork`
  failure, child failure before exec, success); `close_fd` sets the slot to -1, so a double close is not possible.
  The child's exec-failure pipe is close-on-exec, so a successful exec closes it and the parent reads end of file.
- **Fixed: `argc + envc` overflowed a signed `int`** (`nstr`) in `ec_spawn_ex` and `ec_run_ex` for counts near
  `INT32_MAX`: undefined behaviour reachable from the ABI. Both now refuse more than 100,000,000 of either
  (`SPAWN_MAX_STRINGS`) with `-EINVAL`; `tests/core/os_test.c` checks it.
- **Fixed: a silent failed start.** If the child could not lift its report pipe above descriptor 2 (`F_DUPFD_CLOEXEC`
  failed, for example `EMFILE`) it exited 127 without writing a report, so the parent saw end of file and returned the
  pid as a successful start. It now reports `SP_STDIO` and the errno on the pipe first.
- **Not a bug, noted: `execvp` after `fork`.** POSIX does not list `execvp` as async-signal-safe; glibc and musl
  implement it without `malloc` (it is what `posix_spawnp` does), and the environment is set up before it. Resolving
  `PATH` before the fork would remove the dependency; not done.
- The one remaining unsafe-looking write, `EC_ENVIRON = envp` in the child, only changes the child's copy of the
  address space.

## R2 audit: task stacks and the context switch (2026-11-25)

Read `stack_get`, `stack_put`, `ctx_make`, `ei_ctx_switch` and the guard-page logic.

- **Fixed: a race in the stack cache.** `stack_put` put a finished task's stack into the shared cache and only then called
  `madvise(MADV_DONTNEED)` on everything below its top 16 KiB. Another worker could take that stack from the cache for a new
  task meanwhile, and the `madvise` would zero the new task's live frames once they grew past the top 16 KiB (a silent
  corruption of a task's stack, rare because the window is a few instructions). The `madvise` now comes first, the stack is
  published after.
- **I6 asserted** (under `-DEI_RT_CHECK_INVARIANTS`): the guard is whole pages below a non-empty stack, the first frame of a
  new task fits in its stack, and its saved stack pointer is inside the mapping.
- The context switch saves exactly the System V callee-saved registers (`rbp rbx r12 r13 r14 r15`); the new task's first frame
  is 16-byte aligned for `ei_ctx_boot`'s `call`. Nothing else to report. The AArch64 path uses `ucontext`, which the task
  tests run (`task ucontext`).

## R3 audit: the reactor, parkers, atomic cells (2026-11-25)

Done by a read-only reviewer who traced each candidate to an interleaving; every finding below was re-read in the code and
fixed here. Ruled out after tracing: a lost wake-up in `task_wait` (`done` is checked under `r->mu`, an early `unpark` leaves a
permit), a waker touching a dead wait record, a double completion, `fds` table growth under the lock, the lock order (parker
stripe, then reactor, then `qmu`/`S.mu`/`mon_mu`: never reversed), the poll/poke double check, stale events with `ONESHOT`,
the signal handler, the parker handle generations.

| # | Sev | Finding | Fix |
|---|---|---|---|
| F1 | S0 | `task_wait`, `chan_wait` and `task_join` registered the waiting task (a stack record in the reactor's descriptor lists and timer heap, a node in a channel's wait queue, the joiner list) and only then called `task_park`, which traps when the task holds a `Mutex`. The trap longjmps out of the frame the reactor or queue still points at: a later timer or event writes into a live frame, or a freed task is woken | the check runs first (`park_precheck`; `chan_wait` releases its own lock and traps, `task_join` releases `join_mu`); `task_park` keeps it as a backstop. A wait that would have completed at once while a Mutex is held now traps too. `tests/run/wait_holding_mutex.ei` is a smoke test: it passes on the old runtime as well, since the damage depends on what the abandoned frame's memory is reused for; the defect is shown by the code, not by a failing test |
| F2 | S2 | the poller hand-over could be lost: a worker that saw `polling == 1` and had not yet counted itself in `nsleep` missed the outgoing poller's wake-up, then slept while nobody polled (timers and descriptors stall until a running task yields) | after counting itself as a sleeper the worker re-checks `polling` and takes the role when it is clear (a Dekker pair with the poller's clear-then-read of `nsleep`) |
| F3 | S2 | `task_wait` grew its descriptor table to `fd + 64` entries for any `i32` (`fd.wait_ready(2147483647, ...)`: a 34 GB `realloc` and `memset`) | a descriptor at or above `sysconf(_SC_OPEN_MAX)` is `-EBADF` |
| F4 | S3 | the thread-path deadline `mono_ms() + timeout_ms` overflowed for a timeout near `INT64_MAX` (`pk_wait`, `ec_fd_wait`, `ec_fd_wait2`) | clamped to 10^12 ms as the task path does; `tests/core/os_test.c` |
| F5 | S3 | an atomic cell handle with an even generation (a free slot, or generation 0) was accepted by `cell_of` and `ec_atomic_free`: freeing a forged handle put the slot on the free list twice, so two later `new` calls returned one cell | the generation must be odd; `tests/core/os_test.c` |

## Plan for this part

1. **Assert I1 to I5** in the C core under `-DEI_RT_CHECK_INVARIANTS` (on in the sanitizer and hardened builds); run the
   whole test matrix with it on. *(next)*
2. **Bounded model checking** of the R1 functions with CBMC (done for the buffer and String functions listed above; the rest is open): `ei_buf_alloc/grow`,
   `ei_grow_cap`, `ei_str_cat`, `ei_str_slice`, the list push/grow glue, `arg`, `out_put`. Proof of I1 to I5 for all
   lengths up to a bound and overflow-freedom for all 64-bit inputs.
3. **R5**: done, see the section above (two bugs fixed).
4. **R2**: done, see the section above (one race fixed). **R3**: done, see the section above (five findings, all fixed). A stress test that runs under
   TSan on a system where TSan works (the Fedora 44 container) is the standing check.
5. Move pieces into an audited `unsafe` Eider layer where the code is simple enough, so the C part shrinks.
