# Memory model

Eider has value semantics without a garbage collector, lifetimes or pointers. Every value has
one meaning: what it holds. Binding a name to a value does not copy it, writes are visible
only where the program says they are, and the compiler checks that no write invalidates
something still being read. This page gives the rules precisely; the design rationale is in
the [memory model design note](../../design/memory-model.md).

The rules in short:

1. `let x = place` names that place (a read-only reference); `let x = fresh` owns the value.
2. To change something through a name, bind it `let mut` (a mutable alias) or pass it
   `inout`. For an independent value, call `.copy()`.
3. A reference lives inside its scope. When it escapes (returned, stored, captured, sent to a
   thread) the value is copied, cheaply, because heap data is shared copy-on-write.
4. While a reference is alive, no write may free, move or replace the memory it points into
   (the protection rule, checked at compile time).
5. To share mutable state beyond a scope use [`Ref[T]`](#reft) (one thread) or
   [`Mutex[T]`](concurrency.md#mutext) (threads).

## Places and fresh values

A **place** is a variable in scope, or a field or element chain rooted at one: `x`, `p.name`,
`orders[i]`, `orders[i].items[j].qty`, `pair.0`. Parameters (including `self`) are places.
The rule is syntactic: a field or element of anything else is not a place.

Every other expression produces a **fresh value**: literals, constructor calls, function and
method calls, operators, `if`, `match` and block expressions, closures, and fields or
elements of any of those (`make().x`, `load()[0]`).

## `let`: references and owned values

`let x = e` where `e` is a place binds `x` as a **read-only reference** to that place. `x` has
no storage of its own: every use of `x` reads the place as it is at that use, so `x` sees
every later write to the place. Index expressions in the place are evaluated once, when `x`
is bound (and bounds-checked then, even if `x` is never read).

`let x = e` where `e` is fresh binds `x` as the **owner** of the value.

A `let` binding can't be assigned to and can't be changed through (E0303).

```eider
type Order = { id: i32, qty: i32 }

fn main() uses io {
    let mut orders: List[Order] = List.new()
    orders.push(Order(1, 5))
    orders.push(Order(2, 7))

    let o = orders[0]          // a reference to orders[0]
    orders[0].qty = 6          // a plain write to the place
    print(o.qty)               // o sees it

    let mut i: usize = 1
    let p = orders[i]          // the index is evaluated here, once
    i = 0
    print(p.id)

    let n = orders.len()       // a fresh value, owned by n
    print(n)
}
```

```output
6
2
2
```

## `let mut`: mutable aliases and mutable locals

`let mut x = e` where `e` is a place binds `x` as a **mutable alias** of the place: writes
through `x` change the place, and writes to the place are seen through `x`. The place's root
variable must itself be writable: a `let mut` binding, an `inout` parameter, a mutable alias
(or a deprecated `var`). An alias can't add write access, so a `let mut` of a read-only
place (a parameter, a `let` binding, a `for` variable, a captured variable) is
[E0307](errors.md#e0307); the fix is to take a `.copy()`.

`let mut x = e` where `e` is fresh is an ordinary mutable local that owns its value.

```eider
type Order = { id: i32, qty: i32 }

fn main() uses io {
    let mut orders: List[Order] = List.new()
    orders.push(Order(1, 5))

    let mut m = orders[0]      // a mutable alias
    m.qty += 1
    print(orders[0].qty)
    orders[0].qty = 0
    print(m.qty)

    let mut total = 0          // a mutable local owning a fresh value
    total += 10
    print(total)
}
```

```output
6
0
10
```

```eider,compile_fail=E0307
fn grow(xs: List[i32]) -> List[i32] {
    let mut ys = xs            // xs is a read-only parameter
    ys.push(1)
    ys
}

fn main() {}
```

The fix is `let mut ys = xs.copy()`, an owned copy that can be changed without affecting the
caller. `mut` is a contextual word, not a keyword: it means a mutable binding only when a
name follows it, so `let mut = 1` declares a variable named `mut`.

## Pattern bindings

Bindings in `match`, `if let`, `while let` and `let (..) =` patterns follow the same rule as
`let`. When the scrutinee is a place, each binding is a read-only reference into it (into the
payload of an enum variant, a tuple element, ...). A binding written `mut x` is a mutable
alias into the place, which must be writable (E0307 otherwise). When the scrutinee is fresh,
each binding owns its part, and `mut` makes it a mutable local. See
[patterns](patterns.md).

```eider
type Job = | Pending(i32) | Done

fn main() uses io {
    let mut jobs: List[Job] = List.new()
    jobs.push(Pending(1))
    match jobs[0] {
        Pending(mut n) => { n += 41 }   // an alias into the payload
        Done => {}
    }
    if let Pending(n) = jobs[0] { print(n) }

    let (a, mut b) = (1, 2)            // a fresh tuple: both own their parts
    b += a
    print(b)
}
```

```output
42
3
```

## `for` loop variables

The variable (or pattern bindings) of a `for` loop is a read-only copy of each element, not a
reference, so the body may change the sequence while the loop runs. The loop itself runs over
a **snapshot** of the sequence taken when it starts, whatever the sequence is (a List, an
array, a Map's entries, an `Iter` value): elements the body pushes are not visited, writes to
later elements are not seen by the loop, and a `pop` or `clear` doesn't end it sooner. The
changes are in the sequence once the loop is done. The snapshot is cheap: it shares the
List's buffer (copy-on-write), and the body's first write to the List makes the copy. A
worklist that must see what it adds is written with an index (`while i < xs.len()`).

See [statements](statements.md).

```eider
fn main() uses io {
    let mut xs: List[i32] = List.new()
    xs.push(1)
    xs.push(2)
    for x in xs {
        if x < 10 { xs.push(x + 10) }  // not visited: the loop walks [1, 2]
    }
    print(xs)
    let mut arr = [1, 2, 3]
    for a in arr {
        arr[2] = 9                     // not seen by the loop either
        print(a)
    }
}
```

```output
[1, 2, 11, 12]
1
2
3
```

## Parameters and `inout`

A parameter is a read-only reference to the caller's argument: passing a place copies
nothing, and the callee can't change it (E0303). A parameter declared `inout` is a mutable
reference: writes in the callee change the caller's place. The argument must be written
`inout place` at the call ([E0304](errors.md#e0304) when the `inout` is missing; the fix
inserts it), and the place must be writable (E0303 for a `let` binding, a literal or any
fresh value).

```eider
type Counter = { n: u32 }

fn step(inout c: Counter) -> u32 {
    c.n += 1
    c.n
}

fn main() uses io {
    let mut c = Counter(0)
    step(inout c)
    print(step(inout c))
    let mut xs = [1, 2, 3]
    bump(inout xs[1])
    print(xs[1])
}

fn bump(inout x: i32) { x += 100 }
```

```output
2
102
```

```eider,compile_fail=E0304
fn bump(inout n: i32) { n += 1 }

fn main() {
    let mut x = 1
    bump(x)
}
```

`inout` can't appear in a type: a record field, a List element or a return value can't hold
a reference (E0302).

### Exclusivity

An `inout` argument is exclusive for the duration of the call: the same variable can't be
passed `inout` twice, or passed `inout` and also read by another argument of the same call
([E0301](errors.md#e0301)). The check works on the root variable of each place, so
`f(inout p.x, p.y)` conflicts too. A reference counts as the variable its place is rooted
at: with `let o = xs[0]`, `f(inout xs, o)` is E0301 (fix: bind `o` with `.copy()`).

An argument that is a call (or a `?` or `as` of one) is evaluated first, to a new value,
before the `inout` access begins, so it may use the variable that is passed `inout`:
`reg.add(name, reg.count())` and `xs.push(xs.len())` are fine, and so is
`svc.add("Cart", schema(svc.add("Line", line())))` (the inner call finishes before the outer
one starts). A place (`xs[0]`, a field, a variable) and an operator (`-p.x`) may carry a
reference or a read, and still conflict.

```eider,compile_fail=E0301
fn both(inout a: i32, inout b: i32) { a += b }

fn main() {
    let mut x = 1
    both(inout x, inout x)
}
```

## The protection rule

While a reference is alive (from its binding to its last use, on any path), no write may
free, move or replace memory it points into. Violations are [E0308](errors.md#e0308), at the
write.

A write to place `P` **invalidates** a live reference to place `R` when `P` is a prefix of
`R` (any two indices compare as equal: `orders[i]` and `orders[j]` are the same for this
rule) and the rest of `R`'s path, after `P`, passes through heap memory (a List element, a
field of a record that has its own `Drop`) or an enum payload. The writes considered are:

- an assignment or compound assignment to `P`;
- passing `P` as an `inout` argument (also as the `inout self` of a method, or a closure's
  `inout` parameter);
- a resizing method on `P`: `push`, `pop`, `clear`, `insert`, `remove`, `push_str`,
  `append`, `push_byte`, and `take`/`replace`.

**Allowed** while references are alive:

- plain writes to scalar fields and elements (`orders[0].qty = 5`);
- writes through mutable aliases;
- a write that replaces exactly the referenced value (`orders[0] = o2` while
  `o = orders[0]`: `o` then sees `o2`);
- resizing a container the reference names rather than points into (`let all = orders;
  orders.push(x)`: `all` sees the new length);
- any write after the reference's last use, or on a path that never reaches a later use
  (`if done { xs.clear(); return }`);
- a loop whose body binds a fresh reference each iteration.

**Rejected:** `xs.push(..)` while a reference into `xs[..]` is alive; assigning a new List
or record over a place a reference points into; replacing an enum value while a binding
refers into its payload (`j = Done` inside `match j { Pending(name) => .. }`); passing
`inout xs` while a reference points into its elements; and the next iteration of a loop
reaching a write while a reference from before the loop is still used.

```eider,compile_fail=E0308
type Order = { qty: i32 }

fn main() uses io {
    let mut orders: List[Order] = List.new()
    orders.push(Order(1))
    let o = orders[0]
    orders.push(Order(2))      // may move the buffer o points into
    print(o.qty)               // o is used after the change
}
```

The error's fix appends `.copy()` to the reference's initializer (or to the scrutinee of the
pattern that bound it), so the binding owns a value. There is no fix when the type has no
`Copy` (a `Chan` inside it) or in a generic body, where `.copy()` would also need a `T: Copy`
bound. The other way out is to use the reference before the change:

```eider
type Order = { qty: i32 }

fn main() uses io {
    let mut orders: List[Order] = List.new()
    orders.push(Order(1))
    let o = orders[0]
    print(o.qty)               // last use of o
    orders.push(Order(2))      // fine: o is no longer alive
    let all = orders           // a reference to the List itself
    orders.push(Order(3))
    print(all.len())           // sees the push
}
```

```output
1
3
```

Map values and Box contents are never places (`get` returns a value), so nothing refers into
a Map or a Box.

## Escapes are values

When a reference escapes its scope it becomes a value at that point: returning it, storing
it in a field or collection, capturing it in a closure, sending it to a thread, or passing it
to a parameter that takes ownership (a constructor argument, `push`). The value is copied
silently; for heap data that copy is a reference-count increment (copy-on-write, below).
Passing a reference as an ordinary argument is a borrow, as for any place.

```eider
type Order = { qty: i32 }

fn first(orders: List[Order]) -> Order {
    let o = orders[0]
    o                          // the caller gets a value
}

fn main() uses io {
    let mut orders: List[Order] = List.new()
    orders.push(Order(1))
    let f = first(orders)
    let mut kept: List[Order] = List.new()
    kept.push(orders[0])       // stored: a copy
    orders[0].qty = 9
    print(f.qty)
    print(kept[0].qty)
}
```

```output
1
1
```

## Closures capture snapshots

A closure captures each variable it uses by copying its value when the closure is created
(a copy-on-write share for heap data). Later writes to the variable are not seen by the
closure, and a closure can't assign to a captured variable (E0303). A closure changes state
only through its own `inout` parameters or a [`Ref`](#reft).

The exception is a closure written as the argument of a call that runs it before returning:
`map`, `filter`, `fold`, `for_each`, `any` and `all` on a List, `Ref.read` and `update`, and
`Mutex.update`. It captures **by reference**: it uses the variables themselves, and nothing
is copied. A closure that is stored, returned, passed to a function of your own or spawned
captures a snapshot, as below.

```eider
fn main() uses io {
    let mut x = 1
    let f = || x * 10
    x = 2
    print(f())
    print(x)
}
```

```output
10
2
```

## Copy-on-write

`String`, `List`, `Map` and `Box` (and records, enums, tuples and arrays holding them) share
their heap buffer between copies. A copy increments a count; the first write to a buffer
whose count is above one copies it first. This is invisible: values behave exactly as if
every copy were deep. It makes passing, returning, storing and capturing large values cost
O(1). The counts are not atomic; a value is made unique (every buffer it reaches its own)
before it crosses to another thread ([concurrency](concurrency.md#sendability)).

```eider
fn main() uses io {
    let mut a: List[String] = List.new()
    a.push(String.from("x"))
    let mut b = a.copy()       // shares a's buffer
    b.push(String.from("y"))   // b gets a buffer of its own first
    b[0].push_str("!")
    print(a)
    print(b)
}
```

```output
["x"]
["x!", "y"]
```

## `.copy()`

`x.copy()` returns an independent value equal to `x`, through the `Copy` trait
([traits](traits.md)). It is derived for every type whose parts have it; `Task` and `Chan`
don't, so `.copy()` on them or anything holding them is E0601. A `Mutex` inside is copied
into a new Mutex (locked while it is read), a `Ref` into a new Ref holding a copy, and a
type's own `Copy` impl runs where it has one. Implicit copies (binding, passing, storing,
escapes) never run user code; `.copy()` is how a scope gets its own value.

## `take` and `replace`

`x.replace(v)` moves the value out of the writable place `x`, moves `v` in, and returns the
old value: no copy, not even a copy-on-write share. It works for every type, including types
without `Copy` and type parameters. `x.take()` is `x.replace(T.default())` and needs the type
to have a `Default` ([traits](traits.md)): `""` for strings, empty Lists and Maps, `None`,
`0`, `false`, derived records. A type's own method named `take` or `replace` wins over these.

`x` must be a writable place (E0303 for a read-only binding or a fresh value), and the write
counts for the protection rule.

```eider
type Node = { name: String, kids: List[String] }

fn main() uses io {
    let mut n = Node(String.from("root"), List.new())
    n.kids.push(String.from("a"))
    let kids = n.kids.take()           // n.kids is empty now
    let old = n.name.replace(String.from("top"))
    print(kids)
    print(n.kids.len())
    print(old)
    print(n.name)
}
```

```output
["a"]
0
root
top
```

## `var` (deprecated)

`var x = e` declares a mutable variable that always owns its own copy of the value, even when
`e` is a place: it is the meaning `let` had before references. It still works, without a
warning. `eiderc migrate-var <file>` rewrites `var x = place` as `let mut x = place.copy()`
and `var x = fresh` as `let mut x = fresh`, leaving the few cases where `.copy()` would mean
something else (a Mutex inside, an own `Copy` or `Drop`, generic bodies).

```eider
type Order = { qty: i32 }

fn main() uses io {
    let mut orders: List[Order] = List.new()
    orders.push(Order(1))
    var v = orders[0]          // an independent copy
    v.qty = 1000
    print(orders[0].qty)
}
```

```output
1
```

## `Ref[T]`

`Ref[T]` is a shared mutable cell for one thread: for state several owners must see change
(caches, graphs, observer lists). Binding, passing, storing and capturing a Ref share the
same cell; a change through any holder is seen by all. Access is scoped through closures, so
no reference into the cell outlives the call.

| Call | Type | Does |
|---|---|---|
| `Ref.new(v)` | `Ref[T]` | a new cell holding `v` (moved in); `T` comes from `v` or the expected type |
| `r.read(f)` | `f: fn(T) -> R`, result `R` | runs `f` on a borrow of the value, no copy |
| `r.update(f)` | `f: fn(inout T) -> R`, result `R` | runs `f` on the value itself |
| `r.get()` | `T` | a copy of the value (copy-on-write) |
| `r.set(v)` | `()` | replaces the value (`v` moved in, the old one dropped) |
| `r.copy()` | `Ref[T]` | a new cell holding a copy, when `T` has `Copy` |

The closure's result type `R` comes from an expression body, from the expected type, or from
`-> R` written on the closure; a block body with none of those is `()`. A Ref has no `==`,
order, hash or text (E0401; compare what it holds inside `read`). Any other method is
E0115. The value is dropped once, when the last holder goes. Cycles of Refs are never freed.

```eider
type Ctx = { hits: Ref[i32], log: Ref[List[String]] }

fn record(ctx: Ctx, what: str) {
    ctx.hits.update(|inout n| { n += 1 })
    ctx.log.update(|inout l| l.push(String.from(what)))
}

fn main() uses io {
    let ctx = Ctx(Ref.new(0), Ref.new(List.new()))
    let other = ctx                    // shares both cells
    record(ctx, "a")
    record(other, "b")
    print(ctx.hits.get())
    print(other.log.read(|l| l.len()))
    let old = ctx.hits.update(|inout n| n.replace(100))
    print(old)
    let snap = ctx.hits.copy()         // a new cell
    snap.set(5)
    print(ctx.hits.get())
}
```

```output
2
2
2
100
```

### Access conflicts

A cell tracks the accesses in progress. Nested reads of one Ref are fine, and different Refs
never conflict. Any other overlap traps (exit 101) at the access that conflicts:

| In progress | `read`, `get`, `.copy()` | `update`, `set` |
|---|---|---|
| nothing | ok | ok |
| reads | ok | trap `Ref updated while it is being read` |
| an update | trap `Ref read while it is being updated` | trap `Ref updated while it is already being updated` |

```eider,trap
fn main() uses io {
    let r = Ref.new(1)
    let alias = r
    r.update(|inout x| {
        x += alias.get()       // a read while r is being updated
    })
}
```

### Not sendable

A Ref is counted without atomics and accessed without a lock, so it can't reach another
thread. A `Task[T]`, `Mutex[T]` or `Chan[T]` whose `T` holds a Ref anywhere in its parts, a
`Mutex.new` of such a value, a spawned closure returning one, and a closure written at
`spawn(...)` that captures one are [E0411](errors.md#e0411). A closure stored first and
spawned later can't be seen by the checker; it traps `a Ref can't be sent to another thread`
when it crosses. Use a `Mutex[T]` holding the value itself to share state across threads.

```eider,compile_fail=E0411
fn main() uses threads {
    let r = Ref.new(1)
    let t = spawn(|| r.get())
}
```

### Closures with `inout` parameters

`update` takes a closure that changes its argument, so fn types and closures may have `inout`
parameters: `fn(inout T, U) -> R` is a fn type whose first parameter is passed by reference,
and `|inout x| ...` or `|inout x: T| ...` declares one. Where the expected fn type is known,
the closure must say `inout` exactly where the type does (E0304, with a fix). Calling such a
fn value takes `inout place` at that argument, with the same rules as a named function
(E0304, E0303, E0301). A named function with `inout` parameters can't be used as a fn value
yet (E0304).

```eider
fn apply(f: fn(inout i32, i32), inout v: i32) { f(inout v, 10) }

fn main() uses io {
    let inc = |inout x: i32| -> () { x += 1 }
    let mut k = 1
    inc(inout k)
    apply(|inout x, by| { x += by }, inout k)
    print(k)
}
```

```output
12
```

## Drop order

A value's resources are released when its last holder goes: at the end of the scope that
owns it, or when it is overwritten, on every exit path (falling off the end, `return`,
`break` and `continue` including labeled ones, `?`, a `match` arm). Within one scope, values
are dropped in reverse order of creation. A record or enum drops its fields in declaration
order. A record with its own [`Drop`](traits.md) impl runs `drop` exactly once, when the last
holder of the (shared) value goes, and then drops its fields. `drop` can't declare
capabilities (E0606) because it runs wherever the last holder goes; the example below logs
through a Ref instead of printing.

```eider
type Log = { l: Ref[List[String]] }
type Res = { name: str, log: Log }

impl Drop for Res {
    fn drop(inout self) {
        let n = self.name
        self.log.l.update(|inout xs| xs.push(String.from(n)))
    }
}

type Pair = { first: Res, second: Res }

fn early(log: Log, stop: bool) -> i32 {
    let a = Res("early a", log)
    if stop { return 1 }
    let b = Res("early b", log)
    2
}

fn main() uses io {
    let log = Log(Ref.new(List.new()))
    {
        let a = Res("a", log)
        let b = Res("b", log)
        let shared = b
        let p = Pair(Res("p.first", log), Res("p.second", log))
    }
    early(log, true)
    for s in log.l.get() { print(s) }
}
```

```output
p.first
p.second
b
a
early a
```

A trap does not unwind: no drops run, no `defer` runs, and the process ends
([runtime](runtime.md#traps)). A [`defer`](statements.md#defer-and-errdefer) runs with the
drops of its block, before the values declared ahead of it are dropped.
In test mode a failed test's values leak and a lock it held stays held.

> **Note:** planned and not implemented: std accessors that
> return references ("projections", 8.15), and lints for silent copies at escapes and for
> `Ref` cycles. See the [roadmap](../../design/roadmap.md).
