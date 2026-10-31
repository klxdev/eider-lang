# Concurrency

Eider programs run code in parallel on OS threads. The language has one way to start a
thread, `spawn`, and three built-in handle types: `Task[T]` (a running thread and its
result), `Mutex[T]` (a value behind a lock) and `Chan[T]` (a queue). Threads share data only
through these handles; everything else a thread gets is its own value. That rules out data
races without a borrow checker: there is no way to name the same memory from two threads
except through a lock or a queue.

Starting a thread needs the `threads` [capability](capabilities.md). The handles' methods
need none.

## `spawn` and `Task[T]`

`spawn(f)` starts a new thread that runs `f` and returns a `Task[T]` for it, where `T` is
`f`'s result type (it may be `()`). `f` must be a closure with no parameters (E0401 for one
that takes parameters or never returns, E0405 for anything but exactly one argument). The
closure is checked without an expected type, so a block body needs its result type written
(`|| -> i32 { ... }`, `|| -> () { ... }`; E0409 otherwise); an expression body is inferred
(`|| n * 2`).

The closure's captures are copied into it when it is created, as for every closure
([memory model](memory.md#closures-capture-snapshots)), and made unique before the thread
starts, so the new thread shares no buffer with the spawning one.

`t.join()` waits for the thread to finish and returns a copy of its result. It may be called
any number of times, from any thread holding the handle; each call gets its own copy. `Task`
has no other methods and no associated functions (E0115).

```eider
fn work(n: i32) -> i32 uses threads {
    let t = spawn(|| n * 2)
    t.join()
}

fn main() uses io, threads {
    let a = spawn(|| -> i32 {
        let mut s = 0
        for i in 0..10 { s += i }
        s
    })
    print(a.join())
    print(a.join())                    // joining again gives the result again
    print(work(21))
    let done = spawn(|| -> () { let x = 1 })
    done.join()
}
```

```output
45
45
42
```

```eider,compile_fail=E0201
fn main() {
    let t = spawn(|| 1)                // needs `uses threads`
}
```

A thread is joined when the last handle to its Task is dropped, so no thread outlives the
last handle to it, and `main` never returns with a spawned thread still running. Dropping
the last handle on the task's own thread traps (`cannot join a thread`).

## `Mutex[T]`

A `Mutex[T]` holds one value of type `T` behind a lock. Copies of the handle share the same
Mutex.

| Call | Type | Does |
|---|---|---|
| `Mutex.new(v)` | `Mutex[T]` | a new Mutex holding `v` (moved in; `T` can't be `()`) |
| `m.get()` | `T` | locks, copies the value out, unlocks |
| `m.set(v)` | `()` | locks, replaces the value, unlocks; the old value is dropped after unlocking |
| `m.update(f)` | `()` | locks, replaces the value with `f(value)`, unlocks |

`update` takes exactly one closure of type `fn(T) -> T` (E0405 otherwise); it runs under the
lock, so the read and the write are one atomic step. The closure receives the old value and
returns the new one, and `update` returns nothing to the caller. The parameter is read-only like any parameter: to change the old value, bind a `.copy()` of it (a copy-on-write share; the first write to it copies the buffer). Using the same Mutex inside its own
`update` closure traps (`cannot lock a mutex`) instead of deadlocking.

```eider
fn main() uses io, threads {
    let m = Mutex.new(0)
    let mut ts: List[Task[i32]] = List.new()
    for i in 0..4 {
        let mm = m                     // shares the Mutex
        ts.push(spawn(|| -> i32 {
            for j in 0..1000 { mm.update(|x| x + 1) }
            0
        }))
    }
    for t in ts { t.join() }
    print(m.get())

    let names: Mutex[List[String]] = Mutex.new(List.new())
    names.update(|l| -> List[String] {
        let mut l2 = l.copy()          // l is read-only; the copy shares its buffer
        l2.push(String.from("a"))
        l2
    })
    names.set(List.new())
    print(names.get().len())
}
```

```output
4000
0
```

```eider,trap
fn main() uses threads {
    let m = Mutex.new(1)
    m.update(|x| x + m.get())          // relocks m on the same thread
}
```

[`std/sync`](api:std/sync#Lock)'s `Lock[T]` is a lock whose closure also returns a result, for
read-modify-write operations that need to report something: `l.modify(|inout s: T| -> R
{ ... })` changes the value in place (nothing of it is copied), `l.with(|s: T| -> (T, R)
...)` builds a new value, `l.update(f)` and `l.get()` are as for a Mutex.

## `Chan[T]`

A `Chan[T]` is an unbounded FIFO queue shared by every copy of the handle: any number of
threads may send and receive. `Chan.new()` takes no arguments and needs its type from the
context (`let c: Chan[i32] = Chan.new()`; E0409 otherwise). `T` can't be `()` (E0111).

| Call | Type | Does |
|---|---|---|
| `Chan.new()` | `Chan[T]` | a new, empty, open channel |
| `c.send(v)` | `()` | queues `v` (moved in) and wakes a receiver; traps `send on a closed channel` if closed |
| `c.recv()` | `Option[T]` | waits for a value: `Some(v)` with the oldest one, or `None` once the channel is closed and empty |
| `c.close()` | `()` | closes the channel; blocked receivers wake up |

Values still queued when the last handle goes are dropped.

```eider
fn main() uses io, threads {
    let c: Chan[i32] = Chan.new()
    let tx = c
    let p = spawn(|| -> () {
        for k in 0..5 { tx.send(k * k) }
        tx.close()
    })
    let mut sum = 0
    while let Some(v) = c.recv() {
        sum += v
    }
    p.join()
    print(sum)
}
```

```output
30
```

```eider,trap
fn main() {
    let c: Chan[i32] = Chan.new()
    c.close()
    c.send(1)
}
```

For bounded channels, deadlines on every blocking operation and `select` over channels,
timers and cancellation, use [`std/chan`](api:std/chan).

## Handles

`Task`, `Mutex` and `Chan` are handles: binding, passing, storing, capturing and sending one
gives another holder of the same thread, lock or queue, and the object is freed when the
last holder goes. They can be stored anywhere a value can (records, enums, Lists, `Option`,
`Box`, other channels), so a recursive type through a `Mutex` works.

Handles have no equality, order, hash or text: `==`, `<`, Map keys and `print` on them (or on
anything holding them) are E0401 / E0701. `Task` and `Chan` have no `Copy`, so `.copy()` on
them or on anything holding them is E0601; `Mutex[T]` has `Copy` when `T` does, and
`m.copy()` is a new Mutex holding a copy of the value (locked while it is read).

```eider,compile_fail=E0401
fn main() uses io, threads {
    let a = Mutex.new(1)
    let b = a
    print(a == b)
}
```

## Sendability

A value crosses to another thread in exactly these ways:

- captured by the closure given to `spawn` (moved into the new thread);
- `Mutex.new(v)`, `m.set(v)`, the result of an `update` closure, `c.send(v)` (moved in);
- `m.get()`, `t.join()`, `c.recv()` (an owned result for the receiving thread).

Heap buffers are shared copy-on-write with non-atomic counts, so every buffer such a value
reaches is made the value's own (copied if shared) as it crosses. A value captured by a
spawned closure, sent while still held, or handed out by `get` therefore crosses as an
independent value. A record with its own `Drop` that crosses while shared becomes a copy, so
a resource meant to be shared between threads belongs in a Mutex.

`Ref[T]` is the one type that can't cross ([memory model](memory.md#reft)): it is counted
without atomics and accessed without a lock. A `Task[T]`, `Mutex[T]` or `Chan[T]` whose `T`
holds a Ref anywhere, `Mutex.new` of such a value, a spawned closure returning one, and a
closure written at `spawn(...)` that captures one are [E0411](errors.md#e0411). A fn value's
type doesn't show its captures, so a closure stored in a variable first and spawned later is
checked when it crosses: it traps `a Ref can't be sent to another thread`.

```eider,compile_fail=E0411
type State = { hits: Ref[i32] }

fn main() uses threads {
    let m = Mutex.new(State(Ref.new(0)))
}
```

## Traps on other threads

A trap on any thread ends the whole process with exit code 101 and one report
([runtime](runtime.md#traps)). In test mode a trap on a spawned thread ends the test binary,
not just the test.

## WebAssembly

`eiderc build --wasm` targets a single thread: a program that uses `Task`, `Mutex`, `Chan`
or `spawn` is [E0806](errors.md#e0806) there.

## Library support

`std` builds structured concurrency on these primitives, on OS threads:

- [`std/task`](api:std/task): cancellation tokens with deadlines, task groups that wait for
  all their children and cancel siblings on failure, a fixed worker pool;
- [`std/chan`](api:std/chan): bounded channels, deadlines, `select`;
- [`std/sync`](api:std/sync): `Lock[T]` and `Parker`;
- [`std/atomic`](api:std/atomic): 64-bit atomic integers with explicit memory orderings;
- [`std/event`](api:std/event): an event loop with timers over the OS poller.

> **Note:** `spawn` starts an OS thread today. Lightweight stackless tasks, where the
> compiler turns functions that use a blocking capability into resumable state machines
> scheduled on a pool over the event loop (roadmap P0.2), are planned and not implemented;
> `std/task`'s API is meant to run on them unchanged. A `select` built into the language is
> part of the same item. See the [roadmap](../../design/roadmap.md).
