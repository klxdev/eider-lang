# Concurrency

Eider programs run work in parallel on OS threads. Threads share data only through
handles made for it (`Mutex`, `Chan`, and std's channels and locks built on them), and
every other value a thread receives is its own copy, so a data race can't be written.
Blocking operations in std take a deadline, cancellation is a token that flows down a tree
of work, and task groups make sure no thread outlives the code that started it.

This page starts with the language's built-in handles, then the std modules:
`std/chan` (bounded channels, `select`), `std/task` (tokens, groups, a pool) and `std/time`
(deadlines).

> **Note:** Every task here is an OS thread. Lightweight stackless tasks, which would let
> one process serve tens of thousands of connections with the same code, are planned (see
> the repository's `docs/design/roadmap.md`, P0.2); the std APIs on this page are designed
> to stay the same when they arrive.

## `spawn` and `Task`

`spawn(f)` starts a thread running the closure `f` (no parameters) and returns a
`Task[T]`, where `T` is what `f` returns. `t.join()` waits for the thread and gives the
result. Starting a thread needs the `threads` capability.

```eider
fn fib(n: u64) -> u64 {
    if n < 2 { return n }
    fib(n - 1) + fib(n - 2)
}

fn main() uses io, threads {
    let mut tasks: List[Task[u64]] = List.new()
    for n in 20..24 {
        let k = n as u64
        tasks.push(spawn(|| -> u64 fib(k)))
    }
    for t in tasks {
        print(t.join())
    }
}
```

```output
6765
10946
17711
28657
```

What the closure captures is copied into the thread (cheaply: large values are
copy-on-write and made unique before they cross). A spawned closure needs its result type
written (`|| -> u64 ...`). When the last handle to a Task is dropped, the program waits
for its thread, so `main` never returns with a thread still running.

## `Mutex[T]`: shared state

A `Mutex[T]` holds one value. Copies of the handle are the same mutex, so give each thread
a copy:

```eider
type Stats = { requests: i64, errors: i64 }

fn main() uses io, threads {
    let stats = Mutex.new(Stats(0, 0))
    let mut workers: List[Task[i32]] = List.new()
    for w in 0..4 {
        let s = stats
        workers.push(spawn(|| -> i32 {
            for i in 0..250 {
                s.update(|st: Stats| -> Stats {
                    let failed: i64 = if i % 50 == 0 { 1 } else { 0 }
                    Stats(st.requests + 1, st.errors + failed)
                })
            }
            0
        }))
    }
    for t in workers { let r = t.join() }
    print(stats.get())
    stats.set(Stats(0, 0))
    print(stats.get().requests)
}
```

```output
Stats { requests: 1000, errors: 20 }
0
```

- `m.get()` returns a copy of the value, `m.set(v)` replaces it, and `m.update(f)` runs
  `f(old) -> new` under the lock.
- An `update` closure that locks the same mutex again traps (`cannot lock a mutex`) instead
  of deadlocking.
- `std/sync`'s `Lock[T]` adds `with(f)`, which returns a result along with the new value:
  "change the state and tell me what happened" in one critical section. The example services
  of eider-rpc and eider-openapi ([Building services](services.md)) keep their state in one.

## `Chan[T]`: sending values

A `Chan[T]` is an unbounded FIFO queue between threads. `send(v)` moves a value in,
`recv()` waits for one and returns `Some(v)`, or `None` once the channel is closed and
empty:

```eider
fn main() uses io, threads {
    let jobs: Chan[i64] = Chan.new()
    let results: Chan[i64] = Chan.new()
    let (jin, rout) = (jobs, results)
    let worker = spawn(|| -> i32 {
        while let Some(n) = jin.recv() { rout.send(n * n) }
        rout.close()
        0
    })
    for n in 1..6 { jobs.send(n as i64) }
    jobs.close()
    let mut total: i64 = 0
    while let Some(sq) = results.recv() { total += sq }
    print(total)
    let w = worker.join()
}
```

```output
55
```

Sending on a closed channel traps. The built-in `Chan` has no capacity limit and no
timeout; for those, use std/chan.

## Deadlines

Every blocking operation in std takes a `time.Deadline`, a point on the monotonic clock,
rather than a timeout. A deadline can be handed down a chain of calls unchanged, so the
whole chain shares one budget:

```eider
import "std/time"

fn main() uses io, clock {
    let dl = time.after_ms(50)
    print(dl.expired())
    print(dl.remaining().as_ms() <= 50)
    time.sleep_until(dl)
    print(dl.expired())
    print(time.never().is_never())
    let soon = time.after(time.millis(10))
    print(soon.earlier(dl).mono_ns() == dl.mono_ns())
}
```

```output
false
true
true
true
true
```

`time.after(d)`, `time.after_ms(n)`, `time.now()` (don't wait at all) and `time.never()`
make deadlines; `Duration` values come from `time.millis`, `time.seconds` and friends.
Reading the clock needs `clock`.

## Bounded channels and `select` (`std/chan`)

`chan.bounded(n)` makes a channel that holds at most `n` values: a sender waits while it is
full, which pushes back on a producer that is faster than its consumers. Every send and
receive takes a deadline and says what happened:

```eider
import "std/chan"
import "std/time"

fn main() uses io, clock {
    let ch: chan.Channel[String] = chan.bounded(1)
    match ch.send(String.from("first"), time.after_ms(10)) {
        chan.Sent => print("sent")
        chan.Full(v) => print("full")
        chan.Rejected(v) => print("closed")
    }
    match ch.send(String.from("second"), time.after_ms(10)) {
        chan.Sent => print("sent")
        chan.Full(v) => print(v)            // still full at the deadline: the value comes back
        chan.Rejected(v) => print("closed")
    }
    match ch.recv(time.after_ms(10)) {
        chan.Value(v) => print(v)
        chan.Empty => print("nothing yet")
        chan.Closed => print("closed")
    }
    match ch.try_recv() {
        chan.Value(v) => print(v)
        chan.Empty => print("nothing yet")
        chan.Closed => print("closed")
    }
    ch.close()
    match ch.recv(time.never()) {
        chan.Value(v) => print(v)
        chan.Empty => print("nothing yet")
        chan.Closed => print("closed")
    }
}
```

```output
sent
second
first
nothing yet
closed
```

Nothing is ever lost: a send that gives up hands the value back (`Full(v)`,
`Rejected(v)`), and a receive takes one value or none. So every operation can be abandoned
at its deadline. `chan.unbounded()` exists, by name only.

`chan.select(cases, dl)` waits for the first of several cases and returns what it
produces, or `None` at the deadline. Cases come from `ch.recv_case(f)`, `chan.timer_case(dl,
v)` and a token's `cancel_case(v)`; channels of different types meet in one select by
mapping to a common type, usually an enum:

```eider
import "std/chan"
import "std/time"

type Event = | Job(n: i64) | Note(text: String) | Tick | Stopped

fn main() uses io, clock {
    let jobs: chan.Channel[i64] = chan.bounded(8)
    let notes: chan.Channel[String] = chan.bounded(8)
    let r = notes.send(String.from("hello"), time.never())
    let mut seen = 0
    while seen < 2 {
        let mut cases: List[chan.Case[Event]] = List.new()
        cases.push(jobs.recv_case(|v: Option[i64]| -> Event {
            match v {
                Some(n) => Job(n)
                None => Stopped
            }
        }))
        cases.push(notes.recv_case(|v: Option[String]| -> Event {
            match v {
                Some(t) => Note(t)
                None => Stopped
            }
        }))
        cases.push(chan.timer_case(time.after_ms(20), Tick))
        match chan.select(cases, time.after_ms(1000)) {
            Some(e) => print(e)
            None => print("deadline")
        }
        seen += 1
    }
}
```

```output
Note("hello")
Tick
```

When several cases are ready, which is tried first rotates, so no case starves the others.

## Cancellation tokens (`std/task`)

A `task.Token` says "stop": explicitly, with `cancel()`, or when its deadline passes.
Tokens form a tree. Cancelling one cancels every token made from it, never its parent, and
a child's deadline is never later than its parent's:

```eider
import "std/task"
import "std/time"

fn main() uses io, clock {
    let root = task.root()
    let request = root.child()
    let db_call = request.child_until(time.after_ms(5))
    print(db_call.is_cancelled())
    time.sleep_ms(10)
    print(db_call.reason())
    print(request.is_cancelled())
    request.cancel()
    print(request.reason())
    print(root.is_cancelled())
}
```

```output
false
Some("deadline exceeded")
false
Some("cancelled")
false
```

Cancellation is cooperative: code checks `tok.is_cancelled()` or `tok.check()?` between
steps, waits with `tok.deadline()` (or `tok.bound(dl)`, the earlier of the two), or puts
`tok.cancel_case(v)` in a select. Nothing is interrupted from outside, so a thread never
stops in the middle of a critical section.

## Task groups: structured concurrency

`task.group(tok)` (or `task.group_until(tok, dl)`) is a parent for a set of children. Each
child gets the group's token; `wait()` waits for every child, whatever happens, and gives
all their results in start order, or the first error. The first child to fail cancels the
group, so its siblings can stop early:

```eider
import "std/task"
import "std/time"

fn lookup(id: i64, tok: task.Token) -> Result[String, String] uses clock {
    if id == 3 { return Err(String.from("backend 3 is down")) }
    let mut waited = 0
    while waited < 20 {
        tok.check()?                          // stop early once a sibling failed
        time.sleep_ms(5)
        waited += 5
    }
    let mut s = String.from("reply ")
    s.append(String.from_int(id))
    Ok(s)
}

fn fan_out(ids: List[i64]) -> Result[List[String], String] uses io, clock, threads {
    let mut g: task.Group[String] = task.group_until(task.root(), time.after_ms(1000))
    for id in ids {
        g.spawn(|t: task.Token| -> Result[String, String] { lookup(id, t) })
    }
    g.wait()
}

fn main() uses io, clock, threads {
    let mut ok: List[i64] = List.new()
    ok.push(1)
    ok.push(2)
    print(fan_out(ok))
    let mut bad = ok.copy()
    bad.push(3)
    print(fan_out(bad))
}
```

```output
Ok(["reply 1", "reply 2"])
Err("backend 3 is down")
```

No child outlives its group: even a group dropped without `wait` joins its threads. A child
that is cancelled before it starts doesn't run.

## A thread pool

`task.pool(workers, queue)` starts a fixed set of worker threads with a bounded queue of
jobs. `run(f, dl)` queues a job and returns a `Future`; `fut.get(dl)` waits for its result
(giving up leaves the result for a later `get`). `submit(job, dl)` queues a job with no
result. Shut a pool down when you are done with it: its workers keep it alive.

```eider
import "std/task"
import "std/time"

fn main() uses io, clock, threads {
    let pool = task.pool(2, 16)
    let mut futures: List[task.Future[i64]] = List.new()
    for n in 1..5 {
        let k = n as i64
        match pool.run(|| -> i64 k * 100, time.after_ms(1000)) {
            Ok(f) => futures.push(f)
            Err(e) => print(e)
        }
    }
    for f in futures { print(f.get(time.never())) }
    pool.shutdown()
}
```

```output
Some(100)
Some(200)
Some(300)
Some(400)
```

`task.Group.spawn_on(pool, f)` runs a group's children on a pool instead of new threads.
A pool job that waits for other jobs of the same pool can deadlock it once every worker
waits, as with any fixed pool.

## Atomics and the event loop

For counters and flags shared between threads without a lock, `std/atomic` has 64-bit
atomics with C11 orderings (handles to cells that must be freed with `free()`). For
programs that wait on many descriptors and timers on one thread, `std/event` has an event
loop (epoll on Linux) with a timer heap. Both are documented in their modules' API pages.

## The rules, in short

- Threads share only `Mutex`, `Chan` and what std builds on them (Locks, Channels, tokens,
  atomics). Everything else crosses by value.
- A `Ref[T]` (single-thread shared state) can't cross to another thread: putting one in a
  `Mutex`, `Chan` or `Task`, or capturing one in a spawned closure, is E0411.
- `Task`, `Chan` and `Mutex` have no `==` and can't be printed; `Task` and `Chan` have no
  `.copy()` (share the handle instead).
- WebAssembly builds have no threads (E0806).
- Deadlines, not timeouts; cancellation is cooperative; groups wait for their children.
