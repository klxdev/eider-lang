# The runtime layer (layer/runtime)

What a concurrent Eider program builds on, below the stackless tasks of decision C4: atomics,
a way for a thread to wait with a deadline, bounded channels and `select`, cancellation
tokens, task groups, a thread pool, and an event loop with timers. Everything is Eider in
std except four things in the C core, each one operation per function (core/ABI.md,
core/RUNTIME.md):

| Piece | Where | Why it is C |
|---|---|---|
| `ec_fd_wait` | core/eider_core.c (ABI "Readiness") | one `poll(2)` on one descriptor: how a thread blocks on its waker until a deadline |
| atomic cells `ec_atomic_*` | core/eider_core.c (ABI "Atomic cells") | Eider can't name shared memory; the core owns the cells, Eider holds handles |
| `ei_atomic_*` | core/eider_rt.h (RUNTIME "Atomics") | the same operations for generated code (the compiler's built-in atomic type, next) |
| guarded thread stacks | core/eider_rt.c (RUNTIME "Stack overflow") | mappings, a guard and a fault handler on an alternate signal stack |
| the profiler (`--profile` builds only) | core/eider_prof.c (RUNTIME "Profiling"), `ec_prof` (ABI "Profiling") | a SIGPROF handler, per-thread timers and rings, allocation and wait hooks ("Profiler" below) |

The std modules, bottom up:

| Module | What | Capabilities |
|---|---|---|
| `std/time` | `Duration`, `Deadline` (and the clocks, sleeping) | `clock` where the clock is read |
| `std/atomic` | `Atomic`: shared 64-bit integers with orderings | none |
| `std/sync` | `Lock[T]` (state changed under a lock, with a result), `Parker` (wait with a deadline, woken from any thread) | `io` for Parkers (descriptors), `clock` for deadlines |
| `std/chan` | `Channel[T]` (bounded by default), `select` over channels, timers and tokens | `io, clock` to wait; `io` to wake |
| `std/task` | `Token` (cancellation and deadlines), `Group[T]` (structured task groups), `Pool` (worker threads) | `threads` to start threads; `io, clock` to wait |
| `std/event` | `Loop`: a poller, a waker and a timer heap | `io`, `clock` |
| `std/fd` | `wait_ready`, `read_by`: one descriptor with a deadline | `io, clock` |
| `std/profile` | the profiler from inside the program: start, stop, reset, snapshots, labels ("Profiler") | `fs` to write a snapshot, `io, clock` to capture one |

Each function declares exactly the capabilities it reaches (C8.5): atomics and Locks need
none (they are memory, like the built-in Mutex), waiting needs `clock` (a deadline) and `io`
(a waker is a descriptor), starting a thread `threads`. Closures take the capabilities of the
function that writes them, so a job given to a pool can do what its author's function may.

## Deadlines, not timeouts (C5)

Every operation that can block takes a `time.Deadline`: a point on the monotonic clock, or
`time.never()`. A deadline, unlike a timeout, can be passed down a chain of calls unchanged,
so the whole chain shares one budget. `time.after(d)`, `time.after_ms(n)`, `time.now()` (don't
wait at all), `dl.expired()`, `dl.remaining()`, `dl.earlier(other)`, `dl.timeout_ms()` (for a
poll: rounded up, so a wait never ends early). `Duration` is nanoseconds: `time.millis(n)`,
`seconds`, `plus`/`minus` (saturating), `as_ms_ceil`. A token's deadline bounds a call with
`tok.bound(dl)`.

## Atomics (`std/atomic`)

```
let hits = atomic.new(0)
let h = hits                                  // copies name the same cell
spawn(|| -> i32 { h.add(1, atomic.Relaxed); 0 })
print(hits.load(atomic.Acquire))
hits.free()
```

`load`, `store`, `swap`, `add` and `sub` (checked: overflow traps, as `+` does),
`wrapping_add` (one hardware operation), `compare_exchange(expected, new) -> Result[i64,
i64]` (strong), `update(o, f)` (a compare-and-swap loop), `free`. Orderings are the enum
`atomic.Order`: `Relaxed`, `Acquire`, `Release`, `AcqRel`, `SeqCst`, as in C11; a load with
`Release`/`AcqRel` or a store with `Acquire`/`AcqRel` is a runtime error. Nothing blocks, so
nothing needs cancel-safety.

Why handles to core cells: the language shares state between threads only through its
handles (Task, Mutex, Chan); any other value that crosses to a thread is copied (C8.1, C8.4).
A record holding an atomic would arrive as a separate atomic. The cell lives in the core, so
the handle (an integer) can be copied freely and still name one cell. The price is an explicit
`free`, as for a descriptor, until the compiler has a built-in `Atomic` handle type
(reference-counted like a Mutex; "Next" below). A freed handle can't corrupt memory: it ends
the program with a runtime error (core/ABI.md "Atomic cells").

## Waiting: `Lock` and `Parker` (`std/sync`)

The built-in `Mutex[T]` can't express "change the state and tell me what happened" (`update`
returns nothing; `get` then `set` isn't atomic). `sync.Lock[T]` can: it is a `Chan[T]` that
always holds exactly one value. Taking the lock receives the value (moved, not copied);
`with(f)` runs `f(value) -> (new value, result)` and sends the new value back.

`sync.Parker` is a thread's wake-up handle: an OS waker. `park(dl)` waits on it with
`ec_fd_wait` until another thread calls `unpark` or the deadline passes; an unpark that came
first is not lost. Every blocking structure here is a Lock whose state holds lists of the
Parkers waiting on it, with two rules (std/sync's module comment):

1. Wake under the lock, and leave every list (under its lock) before closing a Parker, so a
   closed Parker (whose descriptor number may be reused) is never woken.
2. Check the state and register in one critical section; everything that changes the state
   wakes the list afterwards. No wake-up is lost.

A Parker is made only when an operation actually has to wait (the fast path makes no system
call), and closed when the operation ends.

## Channels and select (`std/chan`)

```
let jobs: chan.Channel[Job] = chan.bounded(64)    // chan.unbounded() only by name (C5)
match jobs.send(j, time.after_ms(100)) {
    chan.Sent => {}
    chan.Full(j) => ...                          // still full at the deadline: j is back
    chan.Rejected(j) => ...                      // closed
}
match jobs.recv(tok.deadline()) {
    chan.Value(j) => ...
    chan.Empty => ...                            // nothing by the deadline
    chan.Closed => ...                           // closed and drained
}
```

Also `try_send`, `try_recv` (no waiting), `close` (idempotent; wakes everyone), `len`,
`is_closed`. Any number of senders and receivers, FIFO. Values are moved, never copied. A
value sent before `close` is still received.

`select(cases, dl) -> Option[U]` waits for the first ready case and returns what it
produces, or None at the deadline. Cases (`chan.Case[U]`) come from `ch.recv_case(f)` (ready
with `f(Some(v))`, or `f(None)` once closed and drained), `chan.timer_case(dl, u)`,
`tok.cancel_case(u)`, or by hand (a `poll` that takes the event or registers a Parker in one
critical section, a `leave`, and a time at which the case becomes ready by itself). Channels of
different element types meet in one select by mapping to a common type (an enum). When several
cases are ready the first one tried rotates, so none starves.

**Cancel-safety.** A send queues the value or hands it back; a receive takes one value or
none; a select takes exactly one case's event and leaves the others untouched. So each can be
abandoned at its deadline, or lose a select, without losing data. (This is the property
tokio documents case by case; here it holds for every operation.)

How: a channel is a built-in `Chan[T]` for the values and a `Lock` for the count, the
capacity, the closed flag and the waiting Parkers. A send reserves a place under the lock,
then moves the value into the queue; a receive reserves a value, then takes it. So the queue
is touched only for values already counted.

## Tasks (`std/task`)

**Tokens.** `task.root()`, `root_until(dl)`; `tok.child()`, `child_until(dl)` (a child's
deadline is the earlier of its own and its parent's); `cancel()` (this token and every token
made from it, waking whoever waits; never upwards); `is_cancelled()` (cancelled, or past the
deadline), `reason()` (`"cancelled"` / `"deadline exceeded"`), `check()?`, `deadline()`,
`bound(dl)`, `wait(dl)`, `cancel_case(u)`, `detach(kid)`. Cancellation is cooperative: code
checks the token, or waits with its deadline or its case; nothing is interrupted from outside.
Deadlines need no timer thread: they are fixed when a token is made and every wait is bounded
by them.

**Groups** (structured concurrency). A child cannot outlive its group:

```
var g: task.Group[Reply] = task.group_until(tok, time.after_ms(500))
for b in backends { g.spawn(|t: task.Token| -> Result[Reply, String] { ask(b, t) }) }
let replies = g.wait()?          // every result in start order, or the first error
```

`spawn` starts a thread per child, `spawn_on(pool, f)` a pool job. Each child gets the group's
token; a child that is cancelled before it starts doesn't run (its result is the reason); the
first child to fail records its error and cancels the group, so its siblings see it. `wait`
waits for every child whatever happens (structured), then returns Ok(results) or Err(first
error) and detaches the group's token from its parent. Dropping a group without `wait` still
joins its threads (a Task's last drop joins it).

**Pool.** `task.pool(workers, queue)`; `submit(job, dl)` (Err if the queue stays full until
`dl`, or after shutdown: then the job never runs), `run(f, dl) -> Future[T]` with `fut.get(dl)`
(cancel-safe: giving up leaves the result for a later `get`), `size`, `queued`, `shutdown`
(no new jobs; the queued ones finish; waits for the workers). Back-pressure is the bounded
queue.

## Event loop and timers (`std/event`)

```
var lp = event.new()?
lp.watch(sock, poll.READ, 1)?
let t = lp.timer_after(time.seconds(5))
while running {
    for e in lp.poll(time.never())? {
        match e {
            event.Ready(token, ev) => ...
            event.Timer(id) => ...                // fires once
            event.Woken => ...                    // lp.wake() / poll.wake(lp.waker()) from another thread
        }
    }
}
```

A Loop belongs to one thread. Each `poll(dl)` round waits until a descriptor is ready, the
earliest timer is due, the loop is woken, or `dl` passes, and returns descriptor events, then
the due timers earliest first, then `Woken`. Timers are a binary min-heap keyed by (deadline,
id): add and fire O(log n), cancel O(1) (a cancelled timer is dropped when it reaches the
top). Resolution is the poller's millisecond: a timer fires at its deadline or up to 1 ms
later, never early. Cancel-safe: a round consumes only what it returns (descriptors are
level-triggered unless watched with `poll.EDGE`; a due timer stays due).

## Profiler

`eiderc build|run|test <file.ei> --profile[=cpu,mem,conc]` builds the program with the
profiler: where its time goes (sampled), what it allocates and copies (counted), and where its
threads wait (timed). A bare `--profile` is all three. The program writes its profile when it
ends; the tool that reads it is eider-profiler (a separate repository, written in Eider:
`report`, `flame`, `folded`, `diff`, `record`; docs/site/tooling/profiler.md). Without the
flag nothing changes: the generated C is byte-identical to a build by a compiler without the
profiler, and the runtime is compiled without its profiling part (scripts/test-compiler.sh
"profile-off", tests/core/run.sh).

### What is recorded

| Kind | What | Where it comes from |
|---|---|---|
| `cpu` stacks | a sample of every thread's shadow stack at 99 Hz of CPU time (or wall time) | SIGPROF, per-thread timers |
| `alloc` sites | allocations and bytes per position, the live ones (heap snapshot, leaks at exit) | `ei_alloc`/`ei_free`/`ei_buf_grow` |
| `alloc` stacks | one stack per 512 KiB allocated (`EIDER_PROF_MEM_RATE`), weighted by the bytes | the same |
| `cow` sites and stacks | copy-on-write unshares: a shared String/List/Map/Box copied before a write, with the bytes copied | generated `uniq_` glue, `ei_str_unique`, `ei_str_cat` |
| `copy` sites | `.copy()` calls (and the size of what was copied) | generated code at each `.copy()` |
| `grow`, `rehash` sites | List growth and Map rehashes, with the new size | generated `push_`/`ins_` glue, `ei_str_cat` |
| `drop` sites | calls of a type's own `Drop` | generated `drop_` glue |
| `lock` sites and stacks | waits for a contended lock (built-in `Mutex`, and the runtime's locks under Chan and Task), in ns | `ei_mutex_lock` |
| `recv` sites and stacks | waits in `Chan.recv` (so `sync.Lock`, which is a one-value channel), in ns | `ei_chan_recv` |
| `ref` sites | Ref access conflicts (each one traps; the profile is still written) | `ei_ref_*_begin` |
| `spawn` sites, threads | spawns per position; each runtime thread's start and end | `ei_thread_start` |
| heap timeline | live and peak heap, allocations, threads, every 100 ms | the collector thread |
| labels | the (key, value) pairs std/profile set on the thread, on every stack | `std/profile.with_label` |

A position is a function and a line. Each Eider function that calls a function or loops
pushes a frame (its id and the line of its current call or allocation) on a per-thread shadow
stack when it starts and pops it on every return, so stacks are Eider names, files and lines,
portable, and need no frame pointers or unwinding. Straight-line code that calls nothing gets
no frame (as if the C compiler inlined it): its time and events count for its caller, at the
line of the call. Lines are set before the statements that call or allocate, so time in code
between calls counts at the line of the last call. The site of an allocation or a copy is the
innermost frame's position: the statement that allocates, in its function.

### Using it

| Environment | Meaning |
|---|---|
| `EIDER_PROF` | the profile file (default `eider.prof` in the working directory); `off` turns the profiler off at run time (no samples, no counts, no file) |
| `EIDER_PROF_HZ` | samples per second (default 99) |
| `EIDER_PROF_CLOCK` | `cpu` (default: CPU time; a thread that waits isn't sampled) or `wall` (every thread at that rate whether it runs or waits; on Linux a blocking system call can return early with EINTR when the sample arrives, which the core retries) |
| `EIDER_PROF_START` | `0`: start with sampling off, for `std/profile.start()` (counting is always on, so the live heap stays exact) |
| `EIDER_PROF_MEM_RATE` | bytes between allocation and copy-on-write stack samples (default 524288) |

The file is written at exit (also after a trap and after `env.exit`), on `SIGUSR2` (by the
collector thread, not in the signal handler), and whenever the program calls
`profile.snapshot(path)`. It is written aside and renamed, so a reader never sees half a file.

`std/profile` (in every program; it does nothing without `--profile`):

| Function | What |
|---|---|
| `enabled()`, `running()` | whether there is a profiler, whether it samples now |
| `start()`, `stop()` | sampling on and off |
| `reset()` | forget what was recorded so far (not the live heap) |
| `snapshot(path)` | write the profile now (`""`: the profile path) |
| `capture()` | the profile as bytes (written to a temporary file and read back) |
| `with_label(key, value, f)`, `with_label_bytes` | run `f` with a label added to the thread's labels |

packages/http has the service side (`http/profiling`): `label_routes(inout router)` runs every
route under the labels `method` and `route` (the pattern, `/kv/:key`), so a report or flame
graph can be split per endpoint, on any worker thread of the server's pool; `jsonrpc` labels
each call with `rpc` (the method); and `mount(inout router, opts)` adds `GET
/debug/profile?seconds=N` (reset, sample for N seconds, answer the profile) and `GET
/debug/heap` (the profile as it is now: live heap by site), only when `opts.enabled`, only for
the local host unless `opts.remote`, 501 in a program built without `--profile`, 409 while a
recording runs. examples/kvstore turns them on with `KVSTORE_PROFILING=1`.

### Profile format

Version 1, JSON lines (one object per line, UTF-8). The first line is the header; then records
whose `"t"` says what they are, in this order: `file`, `fn`, `label`, `thread`, `stack`,
`site`, `heap`, `summary`. A reader ignores record kinds and fields it doesn't know; a header
with a higher `eider_prof` is a format it can't read. Times are nanoseconds from the start of
the profile (or its last reset), sizes bytes.

| Record | Fields |
|---|---|
| header | `eider_prof` (1), `program` (the entry file), `pid`, `reason` (`exit`, `signal`, `snapshot`), `what` (`cpu,mem,conc`), `clock` (`cpu`/`wall`), `hz`, `period_ns`, `mem_rate`, `duration_ns`, `running`, `clean_exit` (main returned normally: what is live is a leak) |
| `file` | `id`, `path` (as trap messages name files: `std/bytes.ei`, `json/json.ei`, the entry's path) |
| `fn` | `id` (from 1), `name` (the compiler's: `bytes__0std__append`; `module.name` for people), `file` |
| `label` | `id` (from 1), `parent` (0: none), `key`, `value`: a label set is a node and its ancestors |
| `thread` | `id`, `start_ns`, `end_ns` (-1: still running), `samples`, `dropped` (a full ring) |
| `stack` | `kind` (`cpu`, `alloc`, `cow`, `lock`, `recv`), `label`, `n` (samples or events), `w` (ns of CPU or wait, or bytes), `frames`: `[[fn, line], ...]` outermost first; fn 4294967295 first means the stack was deeper than 128 frames and only the innermost are kept; fn 0 is "no Eider frame" |
| `site` | `kind` (`alloc`, `cow`, `copy`, `grow`, `rehash`, `drop`, `lock`, `recv`, `ref`, `spawn`), `fn`, `line`, `n`, `w` (bytes; ns for `lock`/`recv`), and for `alloc` `live_n`, `live_w` |
| `heap` | `ns`, `live`, `peak`, `allocs`, `threads` |
| `summary` | `samples`, `dropped`, `stacks_lost`, `sites_lost` (tables full), `allocs`, `alloc_bytes`, `frees`, `live`, `live_n`, `peak`, `threads_started`, `threads_exited` |

### How it works

| Piece | Where | Why |
|---|---|---|
| shadow stack: `ei_prof_enter`/`leave`, `ei_pf->line = N` | generated C, inline in core/eider_rt.h | portable stacks with Eider names and lines; volatile float stores (alias nothing the program has) |
| signal handler, per-thread rings | core/eider_prof.c | async-signal-safe: atomics and plain stores only; one ring per thread (single producer: the handler on that thread; single consumer: the collector) |
| per-thread timers | core/eider_prof.c | Linux: `timer_create` on the thread's CPU clock (or the monotonic clock) with `SIGEV_THREAD_ID`, so each thread is sampled for its own time; elsewhere one `ITIMER_PROF`, whose SIGPROF lands on a running thread |
| collector thread | core/eider_prof.c | drains the rings every 20 ms into the stack table, samples the heap every 100 ms, writes the file on SIGUSR2; it blocks every signal |
| stack table | core/eider_prof.c | aggregated stacks (one entry per distinct stack, kind and label), under a mutex never taken in a signal handler |
| site table | core/eider_prof.c | 65,536 (kind, fn, line) counters, lock-free (a CAS claims a slot), relaxed atomic counts |
| allocation prefix | core/eider_prof.c | 16 bytes before each block (its site and size), so a free knows what it frees: live heap per site, peak, leaks |
| control | `ec_prof` in core/eider_core.c (ABI "Profiling"), core/prof.ei, std/profile | the profiler registers itself with the core at start; without it every call is -ENOSYS |
| analysis | eider-profiler (Eider) | names, self/total, labels, flame graphs and diffs are not the runtime's business |

### Overhead

Measured 2026-10-31 (16 cores, gcc -O2) on eiderc itself (`emit-c compiler/main.ei`, 22.5k
lines of Eider: the worst case, very many small functions; median of 9 runs) and on
examples/kvstore under eider-loadgen (8 keep-alive connections, a mix of JSON-RPC and GET
requests, 4 s, three runs each, mean):

| Program | Build | Result | Cost |
|---|---|---|---|
| eiderc `emit-c` | plain | 213 ms | |
| | `--profile=cpu` | 307 ms; 306 ms with sampling off (`EIDER_PROF_START=0`) | +44%, of which sampling at 99 Hz < 1% |
| | `--profile=cpu,mem` and `--profile` | 367 ms | +72% (2.1 M allocations, 1.7 M `.copy()`, 2.1 M growths counted) |
| | `--profile`, `EIDER_PROF=off` | 291 ms | +37% (the shadow stack alone) |
| kvstore | plain | 22,080 req/s; p50 408 us, p99 888 us | |
| | `--profile=cpu` | 21,290 req/s; p50 434 us, p99 938 us | -3.6% throughput |
| | `--profile=cpu,mem` | 14,300 req/s; p50 657 us | -35% (16 M allocations a second: ~1,600 per request, see below) |
| | `--profile` | 13,980 req/s; p50 668 us | -37% |

So `--profile=cpu` (and `cpu,conc`) is the setting to leave on in a service; `mem` counts
every allocation and copy exactly, and costs in proportion to how many there are (kvstore
allocates ~1,600 blocks per request because its store is copied on every call: the profile's
own top finding). Memory: 16 bytes per live block (with `mem`), per thread a 4 KiB shadow
stack, a 132 KiB sample ring (with `cpu`) and a 40 KiB counting cache (with `mem` or `conc`),
and per process a 2.6 MiB site table plus the stack table (about 0.5 KiB per distinct stack).

The cost is the shadow stack, not the sampling: a frame push and pop per call and a store per
call statement, plus with `mem` a 16-byte prefix and a few relaxed atomic adds per allocation
(and a contended cache line on the global live-heap counter when many threads allocate). The
signal handler copies at most 128 frames 99 times a second per busy thread, and the collector
wakes 50 times a second. A service that does I/O pays little; a compiler-like program of tiny
calls pays most. `EIDER_PROF=off` leaves only the shadow stack.

## Design choices (for review)

| Choice | Why | Alternatives |
|---|---|---|
| Atomics for Eider as handles to core-owned cells, freed explicitly | the language has no shared memory outside its handles, and a copied record would be a second atomic; handles are safe (generation-checked, cells never freed) and need no compiler change | a built-in `Atomic` handle type (the next step: reference-counted, no `free`); atomics on Mutex (not atomics) |
| Checked `add`/`sub` by compare-and-swap; `wrapping_add` separately | Eider arithmetic traps on overflow; hardware fetch-add wraps | wrapping only (Rust's choice) |
| A thread waits on an OS waker with `poll(2)` (`ec_fd_wait`), not a condition variable | the waker already exists (ABI "Readiness"), works with a deadline on the monotonic clock, and is what tasks will park on in an event loop | `pthread_cond_timedwait` in the runtime with a per-thread condvar (needs thread-locals or a new handle type) |
| `Lock[T]` as a one-value channel | atomic read-modify-write of any state with a result and no copy, on the existing seed | a compiler change to `Mutex.update` |
| Wake every waiter of a channel side on a change | always correct with select and deadlines (a woken waiter may take another case or have timed out) | wake one and hand the wake on when unused (fewer wake-ups; later) |
| Bounded channels need capacity >= 1 | rendezvous channels need a different protocol | capacity 0 later |
| Deadlines fixed in tokens at creation, no timer thread | every wait is bounded by the token's deadline anyway | a timer thread cancelling tokens |
| Pool: one shared bounded queue | simplest correct back-pressure on OS threads | per-worker deques with stealing (with stackless tasks, where spawn-from-task makes local queues pay off) |
| Thread stacks: 8 MiB + 64 KiB guard + 64 KiB alternate stack, mapped by the runtime | an exact guard range lets the handler tell an overflow from any other fault, and a guard larger than a page catches big frames | `pthread_attr_setguardsize` (bounds need the non-POSIX `pthread_getattr_np`) |
| Overflow handler flushes stdout with `ftrylockfile` | a trap flushes `print` output; trylock never waits in a handler | no flush (output before the overflow lost) |

## Next (needs the compiler)

1. **A built-in `Atomic` handle type** (like `Mutex[i64]`: `ei_rc` + `ei_atomic_i64`, glue
   generated, methods `load`/`store`/`swap`/`add`/`compare_exchange` lowered to the inline
   `ei_atomic_*`). Then std/atomic keeps its API, loses `free`, and needs no core cells.
   It touches types/check/lower in the thread-handle code, so it waits for 8.6 to land.
2. **The main thread's stack**: generated `main` calls a runtime entry (`ei_main`) that runs
   the Eider `main` on a guarded runtime thread, so an overflow there is reported too.
3. **Stackless tasks (C4).** The pieces here are what they run on: a task that would `park`
   instead returns to its worker; `Parker.unpark` becomes "make the task runnable"; the
   `event.Loop` is the reactor that wakes tasks blocked on descriptors and timers; `Pool`
   gains per-worker queues with stealing; `Group` and `Token` stay as they are (a task group
   is the same API on tasks instead of threads). Until then each blocked thread holds an OS
   thread, and a pool job that waits for other jobs of the same pool can deadlock it once
   every worker waits (as with any fixed thread pool).
4. Optional, smaller: `Chan.try_recv` and a timed `recv` on the built-in channel would let
   std/chan drop the reserve-then-move indirection; `Mutex.update` returning a value would
   let `Lock` be a Mutex.

## Known limits

- An `Atomic` must be freed by hand; a forgotten `free` leaks one cell (16 bytes).
- A `Pool` must be shut down: its workers hold the queue open, and the last drop of a worker
  Task joins it, so a program that drops a running pool waits forever at the end.
- Blocking on a Lock (`with`) has no deadline: critical sections are short and never wait
  for anything else.
- Channel wake-ups wake every waiter of the side that can proceed (a thundering herd with
  many idle receivers); each wait makes one OS waker (an eventfd on Linux) for its duration.
- Timers have millisecond resolution.
