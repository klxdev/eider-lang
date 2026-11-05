# Lightweight tasks (#14, decision C4, C830 to C838)

Status: M1, M2 and M3 implemented in 0.6.0, M4 open (measured: docs/runtime.md, "Tasks: measured") (see "Milestones").

## Goal

A service holds tens of thousands to a million connections. Today `spawn` starts an OS
thread (8 MiB of address space, a kernel object, 10 to 20 microseconds), a blocked thread
holds all of it, and a pool of workers caps the number of connections being served at the
number of threads. The goal of #14: `spawn` is cheap enough to be the unit of concurrency
(one task per connection, per request, per timer), blocking in a task costs the task and not
a thread, and nothing the program already says changes: `spawn`, `Task[T]`, `join`, channels,
`Lock`, `select`, tokens, groups, deadlines, the `std/stream` API.

## What the user sees

Kept: `spawn(f)`, `Task[T]`, `join`, `Chan`, `Mutex`, `sync.Lock`, `Parker`, `chan.select`,
`task.Token`/`Group`/`Pool`, `Task.catch` (#54), deadlines (C5), `uses threads` to spawn.
No `async`, no `await`, no coloured functions: any function can block, a blocking call parks
the task it runs in.

Changed:

| Before | After |
|---|---|
| `spawn` starts an OS thread with an 8 MiB stack | `spawn` starts a task: a stack of 8 MiB of address space, of which only the touched pages are memory, run by a pool of worker threads |
| a blocked thread holds a thread | a blocked task holds its stack pages (about 5 KiB) and a 100-byte record; the worker runs another task |
| a long CPU loop in a thread does not stop other threads | a long CPU loop in a task occupies a worker; the runtime adds a worker when all are stuck (C834); there is no preemption |
| a blocking system call (`read` on a blocking descriptor, `getaddrinfo`) blocks one thread | it blocks one worker; same guard (C834); use `Fd` waits (they park) instead |
| the thread count is the program's | the worker count is the runtime's (`EIDER_WORKERS`, default the CPU count, at least 4) |

New: `EIDER_TASKS=threads` makes `spawn` start OS threads again (debugging, bisecting a
suspected scheduler bug); `EIDER_TASK_STACK=<bytes>`, `EIDER_WORKERS`, `EIDER_WORKERS_MAX`,
`EIDER_TASK_MAX`. Not in this version: a dedicated-thread `spawn` (for code that needs its own
OS thread, FFI that blocks, thread-local C state); see "Open".

## Alternatives considered (C830)

The issue and C4 said: the compiler turns every function that `uses` a blocking capability
into a resumable state machine (stackless). We looked at three ways to make tasks:

1. **Stackless, compiler-generated state machines.**
   *LLVM coroutine intrinsics* (`llvm.coro.*`, presplit coroutines): LLVM computes the frame
   and the spills; the compiler marks suspension points. In LLVM 23 switch-resume functions
   use the C calling convention, so resume calls are plain C-ABI calls. Cost here: every
   function that may suspend must be a coroutine, including its callers up to the task root;
   a call of a suspending function becomes "create the callee's frame, run it, suspend
   ourselves if it did"; closures, `dyn Trait` calls and generic instances need a second
   calling convention for "may suspend", chosen by an effect analysis that the capability
   sets can't give (`io` and `clock` are used by `print` and `now`, which never suspend, so
   `uses` is far too coarse a marker); `Task.catch` (setjmp/longjmp, C803) cannot span a
   suspension (the jmp_buf is in a frame that is on no stack when the task is resumed
   elsewhere); the profiler's shadow stack, debuggers (gdb sees one frame, `resume`) and
   references that point into locals (C764's `L_REF`) all need new work; the `coro` passes
   run in the C++ pipeline and their cost at `-O0` in our text-IR driver is unmeasured.
   *A hand-written transform* (IR to states, every local in a heap frame): the same effect
   analysis, the same `catch` problem, no LLVM help with liveness, and a second code
   generator to keep correct for every statement kind (about the size of lower.ei).
   Memory per task would be 100 to 500 bytes and a switch a few nanoseconds.
2. **Stackful coroutines** (user-space stacks, a scheduler, a context switch of 20
   instructions). Everything that can call a blocking primitive can park, at any depth, in
   any closure or trait method, with the code unchanged; `catch`, the profiler, gdb and the
   stack-overflow guard work as they do on a thread because a task has a real stack. Cost: a
   task owns a stack, so memory is the touched pages (4.6 KiB for a parked task, measured in
   docs/runtime.md), 10 to 50 times a state machine, about twice a goroutine; a stack
   cannot grow, so its size is chosen at spawn; each stack is two kernel mappings (the stack
   and its guard), 65,530 per process by default on Linux (`vm.max_map_count`), so about
   32,000 live tasks per process unless the limit is raised (many distributions set it to 1
   million).
3. **Keep threads, add a pool and `async`-like APIs** (what eider-http does). No.

*Taken (C830): stackful tasks.* Reasons, in order of weight: the language's first goal is
easy, and "any function may block, nothing is coloured" is only true without a transform;
secure, because a task keeps the same guarded stack, the same trap containment and the same
capability checks as a thread, with no new class of "which function is a coroutine" bugs
for the compiler to get wrong; performant enough: spawn in about a microsecond, a switch in
tens of nanoseconds, 100,000 tasks in under half a gigabyte, which is the bar of Go and ahead
of every thread design. The decision is reversible in the direction that matters: the
user-visible model (`spawn`, `Task`, park/unpark, channels) does not mention the
representation, so a later stackless transform of *leaf* functions (a `fn` that parks only at
its top level) can run next to stackful tasks without a language change; M5 below records
when that would be worth doing (a million idle connections). C4's other half stands:
work-stealing scheduler over an event loop, structured groups, deadlines, `select`.

## How tasks are represented (C831)

A task is `ei_task` (core/eider_rt.c, "Tasks"): a saved stack pointer, a mapping (guard page
plus stack, from a cache of freed stacks), the function and argument, a state word, a link
for run queues, a link for wait queues, the worker that last ran it, and the results of the
last wait. The record is heap memory the `Task[T]` handle owns; the stack is returned when
the function returns. The Task handle (`ei_h_head`, unchanged in the compiler) points to it.

Context switch: 20 instructions of assembly on x86-64 (callee-saved registers and the stack
pointer), `ucontext` on other glibc Linux targets, threads elsewhere and in WebAssembly (no
change there). A task always switches to and from its worker's own scheduler context, never
directly to another task (two switches per park, simple ownership rules).

## Scheduling (C832)

M workers (OS threads, started with the first `spawn`), one local run queue each, one global
injection queue, stealing half of a victim's queue when the own and global queues are empty.
Spawning from a task pushes to the local queue (the child usually runs on the same core
later; an idle worker steals it). Readying from a non-worker thread (the reactor, `main`)
pushes to the global queue. A woken task goes to the queue of the worker that woke it, so a
channel hand-off between two tasks tends to stay on a core. Idle workers sleep on a condvar;
making a task runnable wakes one if none is searching. Every 61st pick takes from the global
queue first (fairness). FIFO order: a task that readies itself (a `yield`) runs after the
others.

*Park/unpark* (the primitive under everything): a task state is `RUNNING`, `PARKED`,
`NOTIFIED` or `READY`. `park` switches to the worker's loop; the loop, after the switch,
runs an optional release action (unlock the structure the task registered in), then changes
`RUNNING` to `PARKED`; `unpark` changes `PARKED` to `READY` and enqueues, or `RUNNING` to
`NOTIFIED` (the next park returns at once). So a wake that races with a park is never lost
and a task is never resumed while its stack is still in use.

## Suspension points (C833)

The blocking operations of the runtime are four, and all four park when called in a task,
block the thread otherwise:

| Operation | Where | In a task |
|---|---|---|
| `Chan.recv` (built-in channel; `Lock` is one) | `ei_chan_recv` | queue on the channel's waiter list, release the channel lock, park |
| `Task.join` (and the drop of a Task handle) | `ei_thread_join` | queue on the task's joiner list, park |
| waiting for a descriptor (`std/fd.wait_ready`, `stream`, `Parker`) | `ec_fd_wait` | register in the reactor (epoll, one-shot), park; the reactor readies the task |
| sleeping (`time.sleep`, deadlines) | `ec_sleep_ns` | put a timer in the reactor's heap, park |

Everything above them in std (Parker, Lock, bounded channels, `select`, tokens, groups,
`Pool`, the event loop) is Eider code that already blocks only through these, so it parks
without a change. The core (`eider_core.c`) learns about tasks only through one hook
(`ec_block_hook`, the pattern of `ec_prof_hook`), so it stays independent of the runtime.

A task must not park while holding a built-in `Mutex` (the pthread mutex belongs to the
worker thread, and the task may resume on another): that traps with `cannot wait while
holding a Mutex`. A `Mutex.update` closure that waits was already a deadlock hazard.

## The reactor and timers (C835)

A few reactor threads (up to 8, one per two workers; descriptors are assigned by number,
timers by task) each own an epoll set, an eventfd to interrupt it, and a binary min-heap of
timers keyed by deadline (O(log n) insert, O(log n) cancel by index). One reactor is a
bottleneck: an echo benchmark on 1,000 connections ran at 57,000 round trips a second with one
and 190,000 with eight (threads: 216,000). A waiting task puts a
record on its own stack and links it in: `{task, fd, interest, deadline, result}`. A
descriptor event or a due timer fills `result` and readies the task. Registrations are
one-shot (`EPOLLONESHOT`), re-armed per wait with one `epoll_ctl(MOD)`. Resolution of
timers is the poller's 1 ms, rounded up (never early), as `std/event` (C21). The reactor also
runs the starvation guard (C834). `std/event.Loop` stays what it is: a poller one thread
owns. A task using it blocks in `Loop.poll`, which is `ec_poll_wait` and parks the same way
(M2 routes it through the reactor).

## Cancellation (C836, M2)

Cancellation stays cooperative and structured (#97): a `Token`'s `cancel` wakes the Parkers
and select cases waiting on it, which is how a task parked in a `select`, `recv` with a
token's deadline, or `Group.wait` is interrupted today and keeps working on tasks. M2 adds
the missing half (N15: a late handler stuck in an `Fd` wait): `fd.wait_cancel(fd, interest,
tok)` and the stream equivalents register the descriptor *and* the token, so cancelling or
expiring the token readies the task with `Cancelled`. `defer`/`errdefer` run on the way out
as for any early return. A trap in a task is contained by `Task.catch` exactly as on a
thread (the `setjmp` frame is on the task's own stack, and the try-stack and the held-lock
list move with the task from worker to worker).

## Capabilities (C837)

`spawn` still needs `uses threads` (the right to start concurrent work; the name stays). A
task inherits only what its closure captured and what its function declares, as before. No
new capability for parking: blocking was always `io`/`clock`, and now costs a task, not a
thread. Limits: stack size and live task count are the runtime's (`EIDER_TASK_STACK`,
`EIDER_TASK_MAX`, default 1,000,000: past it `spawn` traps with `too many tasks`), so a
program that spawns without bound ends with a diagnosis, not the kernel's OOM killer.

## Debugging and profiling (C838)

A task has a real stack: gdb/lldb show it with `bt` after `info threads` finds the worker;
`EIDER_TASK_DUMP=1` plus `SIGQUIT` (or `task.dump()` from inside) prints every task's
number, state, what it waits for (`chan`, `join`, `fd 7`, `sleep`) and the function it
spawned. The profiler's shadow stack moves with the task (saved at park, restored at resume);
`spawn` sites are counted as before; the `recv`/`lock` waits keep their sites; worker threads
are `thread` records and tasks show in a `task` record (M2). The stack-overflow report is the
same message from the task's own guard.

## Thread-locals across a park (#204, C875)

A task that parks resumes on any worker, so after a park every `_Thread_local` is another
thread's, and a thread-local address computed before the park is stale. The runtime has five
kinds of thread-local that tasks touch: `cur_task`/`cur_worker`, `cur_batch` (the readied-task
batch), `try_top` (the `Task.catch` frames, saved to the task at a switch), `held_n`/`held_locks`
(the built-in `Mutex`es this thread holds), and `guard_lo`/`guard_hi` (the stack-overflow guard,
set by `switch_in`). The first three groups are read through `noinline` accessors (`task_self`,
`batch_get`, `try_get`), which is the rule: **a function that can park reads a thread-local only
through an out-of-line function**.

*The bug.* `task_park` read `held_n` directly (`if (held_n != 0) trap`), and the parking
callers (`Task.join`, `Chan.recv`, `task_wait`) call it in a loop: park, wake, re-check. On
x86-64 every thread-local access is `%fs:offset` and nothing can go stale. On AArch64 the thread
pointer is `mrs TPIDR_EL0`, which LLVM and gcc treat as a constant of the function and hoist out
of the loop (zig 0.13's clang at `-O1` to `-O3`: `ei_thread_join` keeps it in `x27` and reads
`held_n` as `[x27, x20]` on every iteration, `swapcontext` in between). The second iteration of
a task that was resumed on another worker therefore read the held-lock count of the thread it
ran on *before* the park, while that thread's current task was calling `held_add`/`held_del`
on it: a data race on `held_n`, between tasks, reported between "the sides of a park". It is also
a correctness bug (a task could read a stale non-zero count and trap `cannot wait while holding
a Mutex` without holding one, or read zero while holding one), not only a TSan report; the
x86-64 legs cannot see it.

*The same shape in `ei_try`.* After a trap's `longjmp` it released `held_locks[..]` and set
`held_n` directly in its own frame, on a thread pointer read before `fn` ran (`x21` in the
AArch64 code), and `fn` may have parked and moved. Fixed the same way (`held_unwind`, out of
line).

*The same class in `ec_poll_wait`, reproduced on x86-64.* It cleared the calling thread's output
buffer (`out_len = 0`), parked in the block hook, and after the wake-up wrote the events with
`out_put` in the same function: the compiler had computed the buffer's address before the park, so
a task that woke on another worker filled the buffer of the worker it had left (and left the
current worker's buffer, which the Eider caller reads, stale), and `errno` after the wake-up had
the same hazard. ThreadSanitizer reports it on x86-64 as soon as the context switch is the
`swapcontext` one (`-DEI_TASK_UCONTEXT`, which AArch64 uses; the hand-written x86-64 switch
shifts the timing enough to hide it): a data race in `out_put`, between two tasks on one worker,
in `tests/core/task_test.c` (`test_poll_wait_parks`). That is the signature of #204 (tasks on one
worker racing on a thread-local), and `tests/core/run.sh` now runs the task test with
`-DEI_TASK_UCONTEXT` under TSan and ASan. The wait is split: `ec_poll_wait` parks and calls the
out-of-line `poll_collect`, which resets the buffer on the thread it is on and collects.

*What was checked and is not a problem.* The fiber annotations: every switch of a task or a
worker (`switch_in`, `task_park`, `task_yield_now`, `task_main`'s exit) calls
`__tsan_switch_to_fiber(target, 0)` (with synchronisation) immediately before the context
switch, `__tsan_destroy_fiber` happens on the worker after the exit switch, and the fiber is
created in `task_create`, so each switch is a release/acquire pair and the fibers on one thread
are totally ordered; there is no resume path without it. `held_n`/`held_locks` being per-thread
while tasks interleave on a thread is sound because `task_park` refuses to park with
`held_n != 0`: at every switch the thread's list is empty, so the next task starts from zero.
`worker_main` and `switch_in` read thread-locals before and after a switch but always run on the
worker's own thread. `map_rng`, `trap_jmp` and the `eider_core.c` buffers are used between
calls that do not park. `ei_prof_depth` and the shadow stack (profile builds) are saved and
restored by `switch_in`; the generated code reads `ei_prof_depth` directly, which has the same
hazard in a function that parks between two uses and is open (profile builds only).

*Evidence, and its limits.* There is no AArch64 hardware or `qemu-user` here, and TSan does not
run under qemu, so the race was not reproduced. What is established is the assembly: compiling
`core/eider_rt.c` with `zig cc -target aarch64-linux-gnu -O2 -S` before the change shows
`TPIDR_EL0` read in `ei_thread_join`, `ei_chan_recv` and `task_wait` (each calls `swapcontext`)
with the register used by the `held_n` read in the loop; after the change none of them reads it.
`tests/core/tls_park.sh` (run by `tests/core/run.sh`, skipped without zig) compiles the runtime
that way at `-O1`, `-O2` and `-O3` and fails if a function that calls `swapcontext` reads
`TPIDR_EL0`, other than `worker_main`; it fails on the old source. Validated on x86-64: the
change is a no-op there (the TSan, ASan, gcc and clang legs, the task tests also with
`-DEI_TASK_UCONTEXT` under TSan and ASan, which is the context switch AArch64 uses). Not
validated until it runs on AArch64: that `tests/std/tasks.ei`, `sync.ei`, `chan.ei` and
`tests/core/task_test.c` pass under TSan there. If a race is left after this, it is not this
one.

## Costs and what proves them

Measured on this machine (Linux 7.2, 16 CPUs), reproducible with `sh scripts/task-bench.sh`,
`tests/bench/tasks.ei` and `tests/bench/scale/` (docs/runtime.md "Tasks: measured" has the
table). The claims the design makes, and what the numbers say:

| Claim | Measured |
|---|---|
| spawn is cheap enough to be the unit of concurrency | 1.4 to 7 us warm (40 us for a thread); 10 to 16 us with a cold stack (30 us for a thread) |
| a blocked task costs little | 4.6 KiB of memory (a page of stack, the record); a blocked thread 9 KiB and kernel structures |
| 100,000 tasks | 450 MiB, spawned in 1.1 s, released and joined in 1.2 s; threads fail before 5,000 |
| channel hand-off between two tasks | `tests/bench/tasks.ei` as a whole: 340 ms for tasks, 863 ms for threads |
| an echo server on loopback | 190,000 round trips/s at 1,000 connections (threads 216,000), 146,000 at 10,000 (threads cannot) |
| no regression elsewhere | the compiler's own `emit-llvm`: 377 ms (375 before); map, refs, list_copies, state, str_append unchanged |

What did not meet the design's hope: the echo server is 12% slower than threads at 1,000
connections, because each wake-up crosses a reactor thread and a worker (C835); the warm spawn
cost grows with the worker count (the spawner pays for waking sleepers).

## Milestones

| M | What | State |
|---|---|---|
| M1 | Runtime: tasks with guarded stacks, context switch, workers with stealing and a starvation guard, park/unpark, `Chan.recv`, `join`, `fd_wait` and `sleep` park (epoll reactors, timer heaps), fork safety, sanitizer support; `spawn` makes tasks; tests (tests/core/task_test.c, tests/std/tasks.ei), benches, docs | done in 0.6.0 |
| M2 | Waiting on two descriptors without a poller (`ec_fd_wait2`, N4), so a connection waits for its socket and the server's stop signal at once; eider-http serves a task per connection with the same `serve` API | done (eider-http: local commit) |
| M3 | Cancellation that reaches descriptor waits for tokens (`wait_cancel`), `Parker` as a core object (no eventfd per wait), `Loop` on the reactor, a task listing and `task` records in the profile, a worker that polls when idle | done (#175, #176, #177, #178) |
| M4 | Optional: a stackless transform for leaf waiters if a million idle connections must fit in a few hundred MB | only if measurements ask |

## Open (for the user)

1. ~~C830 replaces the stackless half of C4.~~ Confirmed by the user, 2026-11-04.
2. Dedicated OS threads: `spawn` always makes tasks; code that must have its own thread
   (a blocking C library, thread-local C state) has `EIDER_TASKS=threads` as a process-wide
   switch only. A per-spawn form (`thread.spawn`) needs a compiler builtin.
3. macOS/BSD: epoll is Linux; a kqueue reactor and aarch64 assembly are follow-ups; those
   targets keep OS threads for now.
