# Memory

Eider has no garbage collector, no lifetimes and no pointers, and it is memory-safe: no
use-after-free, no dangling references, no data races. This page explains the model you
program against and the handful of errors that enforce it, each with its fix.

## The six rules

1. **Everything is a value.** Binding or passing something doesn't copy it: `let x = place`
   refers to the place.
2. **To change something through a binding, declare it `let mut`** (a mutable alias of the
   place) **or pass it `inout`.** To get an independent value, call `.copy()`.
3. **A reference lives inside its scope.** When it escapes (returned, stored, sent to a
   thread), it becomes a value: cheap, because large values are copy-on-write.
4. **To share mutable state beyond a scope, use `Ref[T]`, or `Mutex[T]` across threads.**
5. **Errors are `Result`, absence is `Option`,** every case is handled in `match`, side
   effects are declared with `uses`.
6. **Every operation on values** (copy, equality, ordering, hashing, printing, iteration,
   cleanup) **is a trait** that any type can implement; ordinary types get it derived.

The rest of this page is rules 1 to 4 in practice. Rule 5 is [Errors](errors.md) and
[Capabilities](capabilities.md); rule 6 is in the [tour](tour.md#operation-traits).

## Places, references and fresh values

A *place* is a variable, a field or an element, or any chain of them:
`orders`, `orders[i]`, `orders[i].items[j].name`. Everything else (a call's result, a
literal, a constructor, an arithmetic result) is a *fresh value*.

- `let x = place` binds a **read-only reference**. Nothing is copied; every use of `x`
  reads the place as it is at that moment, so `x` sees later writes to it.
- `let mut x = place` binds a **mutable alias**: writing through `x` writes the place.
- `let x = fresh` and `let mut x = fresh` **own** the value, as in any language.
- `x.copy()` is a fresh value: an independent clone that shares nothing with `x`.

```eider
type Account = { owner: String, balance: i64 }

fn main() uses io {
    let mut accounts: List[Account] = List.new()
    accounts.push(Account(String.from("ada"), 100))

    let view = accounts[0]             // read-only reference
    let mut acct = accounts[0]         // mutable alias
    let snapshot = accounts[0].copy()  // independent value

    acct.balance += 50
    print(view.balance)                // the reference sees the write
    print(accounts[0].balance)         // so does the place itself
    print(snapshot.balance)            // the copy doesn't
}
```

```output
150
150
100
```

Pattern bindings follow the same rule. Matching on a place binds references into it, and
`mut` in a pattern makes a mutable alias into the payload:

```eider
type Job = | Waiting(tries: i32) | Done

fn main() uses io {
    let mut jobs: List[Job] = List.new()
    jobs.push(Waiting(0))
    match jobs[0] {
        Waiting(mut tries) => { tries += 1 }
        Done => {}
    }
    print(jobs[0])
}
```

```output
Waiting(1)
```

## Copies are cheap

`String`, `List`, `Map` and `Box` keep their contents in a heap buffer shared with a
reference count. A copy (`.copy()`, storing a value, returning it, a closure capturing it)
increments the count; the first write to a shared buffer makes the real copy. So a large
list costs nothing to pass around until someone changes it, and value semantics still
hold: nobody else sees your writes.

```eider
fn with_extra(xs: List[i32]) -> List[i32] {
    let mut mine = xs.copy()       // shares xs's buffer until the push
    mine.push(99)
    mine
}

fn main() uses io {
    let mut base: List[i32] = List.new()
    base.push(1)
    let more = with_extra(base)
    print(base)
    print(more)
}
```

```output
[1]
[1, 99]
```

Values are freed exactly once, when their last holder goes away, on every path out of a
scope (`return`, `break`, `continue`, `?`). There is nothing to free by hand.

## Parameters and `inout`

Parameters are read-only references to the caller's values: passing a large record costs
nothing. To change the caller's variable, take it `inout`; the caller writes `inout` too:

```eider
fn add_tag(inout tags: List[String], t: str) {
    tags.push(String.from(t))
}

fn main() uses io {
    let mut tags: List[String] = List.new()
    add_tag(inout tags, "new")
    add_tag(inout tags, "urgent")
    print(tags)
}
```

```output
["new", "urgent"]
```

An `inout` argument is exclusive for the call: the same variable can't also be passed as
another argument (E0301). There are no `mut` parameters; to change a local copy of a
parameter, write `let mut x = x.copy()`.

## Escapes become values

A reference never outlives its scope. When one escapes (returned, stored in a field or a
collection, captured by a closure, sent to a thread), the value is copied at that point,
which with copy-on-write costs a count increment:

```eider
type Order = { item: String, qty: i32 }

fn first(orders: List[Order]) -> Order {
    let o = orders[0]
    o                              // escapes: the caller gets its own value
}

fn main() uses io {
    let mut orders: List[Order] = List.new()
    orders.push(Order(String.from("tea"), 1))
    let mut f = first(orders)
    f.qty = 9
    print(orders[0].qty)
}
```

```output
1
```

So you never return a reference into an argument, and you never have to think about how
long one lives.

## Shared mutable state

Values don't share. When several owners must see one changing value, use a handle:

- **`Ref[T]`** within a thread: copies of a Ref are the same cell; `r.read(|v| ...)` and
  `r.update(|inout v| ...)` give scoped access, `r.get()` and `r.set(v)` copy in and out.
  An `update` while the same Ref is being read traps (`Ref updated while it is being
  read`), as Rust's `RefCell` does. A Ref can't reach another thread (E0411).
- **`Mutex[T]`** across threads: `m.get()`, `m.set(v)`, `m.update(|v: T| -> T ...)`.
- **`Chan[T]`** to send values between threads.

> **Note:** `Ref[T]` is implemented in `compiler/` and arrives in `scripts/ei` with the next
> seed regeneration (see the [tour](tour.md#shared-mutable-state-reft)). `Mutex` and
> `Chan` work today ([Concurrency](concurrency.md)).

Cycles of Refs are never freed, as with any reference count. For structures with many
links (graphs, trees with parent pointers), the usual Eider shape is an arena: a List of
nodes and integer indices between them, which is how the compiler itself is written.

## The protection rule

References make one new kind of mistake possible: changing a place in a way that frees,
moves or reinterprets the memory a reference still points into. Eider forbids exactly that,
at compile time:

> While a reference is alive (until its last use), no write may free, move or replace the
> memory it points into.

Allowed while a reference is alive:

- writing a scalar field or element (`orders[0].qty = 5`; the reference sees it);
- writing through a `let mut` alias;
- replacing the very place a reference names (`orders[0] = other`; the reference then
  sees `other`);
- resizing a container you hold a reference *to* (not *into*);
- anything after the reference's last use, or on a path that never reaches it.

Rejected (E0308): resizing a List or String a reference points into (`push`, `pop`,
`clear`, `push_str`, `append`, `push_byte`), assigning over a String, List or record that contains what it points
into, replacing an enum whose payload it points into, or passing such a place `inout`.
Element indices aren't tracked: a reference to `orders[i]` and a `push` to `orders`
conflict whatever `i` is.

## Common errors and their fixes

Every one of these has a machine-applicable fix, which the compiler prints (`fix:`) and
`check --json` gives editors.

### E0308: a write while a reference is alive

```eider,compile_fail=E0308
fn main() uses io {
    let mut names: List[String] = List.new()
    names.push(String.from("ada"))
    let first = names[0]
    names.push(String.from("grace"))
    print(first)
}
```

```text
error[E0308]: can't call `push` on `names` while `first` refers into it
  --> main.ei:5:11
  |
5 |     names.push(String.from("grace"))
  |           ^
  help: `first` is used after this change, which may free, move or replace what it refers to; use it before the change, or bind a copy with `.copy()`
  fix: at 4:25 delete 0 insert ".copy()"
```

Two fixes, depending on what you mean. If `first` should keep the old value, own it:
`let first = names[0].copy()`. If the order doesn't matter, use the reference before the
write:

```eider
fn main() uses io {
    let mut names: List[String] = List.new()
    names.push(String.from("ada"))
    let first = names[0]
    print(first)
    names.push(String.from("grace"))
    print(names.len())
}
```

```output
ada
2
```

The same error covers an enum whose payload you are reading:

```eider,compile_fail=E0308
type Step = | Todo(title: String) | Finished

fn main() uses io {
    let mut t = Todo(String.from("write docs"))
    match t {
        Todo(title) => {
            t = Finished           // replaces the payload `title` points into
            print(title)
        }
        Finished => {}
    }
}
```

Read what you need first, or match on `t.copy()`.

### E0307: a mutable alias of something read-only

A `let mut` alias can't add write access to a place you may only read, such as a
parameter:

```eider,compile_fail=E0307
type Config = { retries: i32 }

fn tuned(c: Config) -> Config {
    let mut d = c
    d.retries += 1
    d
}

fn main() uses io {
    print(tuned(Config(3)).retries)
}
```

```text
error[E0307]: `let mut d` would be a mutable alias of `c`, which is read-only
  --> main.ei:4:17
  |
4 |     let mut d = c
  |                 ^
  help: an alias can't add write access; take an independent value with `.copy()`
  fix: at 4:18 delete 0 insert ".copy()"
```

The fix gives `let mut d = c.copy()`: a value of your own to change.

### E0303: assigning to a `let`

```eider,compile_fail=E0303
fn main() uses io {
    let total = 0
    total += 5
    print(total)
}
```

Declare it `let mut total = 0`.

### E0301: two arguments touching the same variable

An `inout` argument is exclusive for the call. Passing the same variable twice, or passing
it `inout` while another argument refers into it, is E0301:

```eider,compile_fail=E0301
fn move_all(inout from: List[i32], inout to: List[i32]) {
    for x in from { to.push(x) }
    from.clear()
}

fn main() uses io {
    let mut xs: List[i32] = List.new()
    xs.push(1)
    move_all(inout xs, inout xs)
    print(xs)
}
```

### E0601 and E0605: copying what can't be copied

`.copy()` needs the `Copy` trait. A running thread (`Task`) and a channel (`Chan`) have
none, and neither has anything that holds one: share the handle instead of copying it
(E0601). In generic code, `.copy()` on a `T` needs the bound `T: Copy` (E0605, with the fix
that adds it):

```eider,compile_fail=E0605
fn twice[T](x: T) -> (T, T) {
    (x.copy(), x.copy())
}

fn main() uses io {
    print(twice(1))
}
```

Write `fn twice[T: Copy](x: T)`.

## Moving a value out: `take` and `replace`

Sometimes you want the value out of a place and something else left behind, without a
copy. `x.take()` moves the value out and leaves the type's empty value (`""`, an empty
List or Map, `None`); `x.replace(v)` leaves `v`:

```eider
type Inbox = { pending: List[String], seen: i32 }

fn drain(inout box: Inbox) -> List[String] {
    box.seen += box.pending.len() as i32
    box.pending.take()
}

fn main() uses io {
    let mut box = Inbox(List.new(), 0)
    box.pending.push(String.from("hello"))
    box.pending.push(String.from("bye"))
    let got = drain(inout box)
    print(got)
    print(box.pending.len())
    let old = box.seen.replace(0)
    print(old)
}
```

```output
["hello", "bye"]
0
2
```

`replace` works for any type, including ones without `Copy` (a record holding a `Chan`).

## What it costs

The model is small, but it is not free of trade-offs:

- Aliasing inside a function is visible: a `let mut` alias changes the original, so read a
  function's aliases when you read its writes. Reasoning stays local to the function.
- There are two kinds of write to learn: plain writes are fine while references are alive,
  invalidating ones are not.
- No structures built from references (self-referential records, intrusive lists): use
  indices or Ref handles.
- Bounds, overflow and Ref conflicts are checked at run time, as in Rust.

The design and the decisions behind it are in the repository's
`docs/design/memory-model.md`.

