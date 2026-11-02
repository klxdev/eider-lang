# Eider memory model

Status: **the charter, mostly implemented**. Shared doc for iterating:
https://claude.ai/artifact/92bM8TX24tgdviTuHrNJ6L (this file is the source of truth; synced
from it). Decisions marked ✅ are agreed; ❓ are open. Each section says what is implemented
and where (docs/compiler.md's C8 sections); what is not yet is listed in
[Open items](#open-items), each with its issue.

| Part | State |
|---|---|
| Copy-on-write heap values | implemented (C8.1) |
| Operation traits | implemented (C8.4; `Default` added as an eighth, C8.23) |
| `let` references, `let mut` aliases, `.copy()`, the protection rule | implemented (C8.6); a read-only reference through heap memory is a pointer, other references are re-derived places (C8.54, [#1](https://github.com/klxdev/eider-lang/issues/1)); `var` deprecated, not yet retired ([#2](https://github.com/klxdev/eider-lang/issues/2)) |
| `Ref[T]` | implemented (C8.7; inout fn values at the export boundary: [#3](https://github.com/klxdev/eider-lang/issues/3)) |
| `for` over a List, an array or a Map | implemented: a snapshot taken before the loop (C8.20, C303) |
| Closures | implemented: a closure that is run before its call returns (the argument of a List combinator, `Ref.read`/`update`, `Mutex.update`) captures by **reference**; every other closure captures a **snapshot** (by value, copy-on-write), C8.53 |
| Threads: `Mutex`, `Chan`, `select` | implemented (C7 threads; std/chan's channels with deadlines and `select`, docs/runtime.md) |
| Projections, copy and cycle lints | open ([#11](https://github.com/klxdev/eider-lang/issues/11)) |

## Goal ✅

Simple like Go and Zig, with the memory-safety and correctness guarantees of Rust.

- No lifetimes, no borrow annotations, no garbage collector, no raw pointers above the core.
- Safety comes from a small model the compiler can check completely, not from a large type
  system the programmer has to satisfy.

## The model in six rules ✅ (wording to refine)

1. Everything is a value. Binding or passing something does not copy it: `let x = place`
   refers to the place.
2. To change something through a binding, declare it `let mut` (a mutable alias of the place)
   or pass it `inout`. To get an independent value, call `.copy()`.
3. A reference lives inside its scope. When it escapes (returned, stored, sent to a thread),
   it becomes a value: cheap, because large values are copy-on-write.
4. To share mutable state beyond a scope, use `Ref[T]`, or `Mutex[T]` across threads.
5. Errors are `Result`, absence is `Option`, every case is handled in `match`, side effects
   are declared with `uses`.
6. Every operation on values (copy, equality, ordering, hashing, printing, iteration, cleanup)
   is a trait that any type can implement; ordinary types get it derived automatically.

## Guarantees and how they are met

| Guarantee | How Eider gets it | What the programmer must know |
|---|---|---|
| No use-after-free / dangling references | references cannot escape their scope, so their whole life is visible to the compiler | "a reference lives inside its scope" |
| No mutation behind a reader's back | the protection rule (below), inferred, never written | "you can't change something while you're reading it" |
| No data races | threads share only through `Mutex`/`Chan`; values crossing threads are moved or copy-on-write | "threads share through Mutex or Chan" |
| No null | `Option` | same as today |
| Errors can't be ignored | `Result` + `?` | same as today |
| Every case handled | exhaustive `match` | same as today |
| No silent overflow | trap in every build; `+% -% *%` to wrap | same as today |
| No unchecked unsafe code | `extern` only in a package granted `ffi`; no pointers in Eider | "C lives in core" |
| No hidden side effects | capabilities (`uses io`, `fs`, ...), per function and per dependency | `uses ...` on functions that do I/O |

## Bindings: `let` and `let mut`

### `let` ✅

Implemented by C8.6 (docs/compiler.md, "C8.6: references by default", which records the
details decided there: the protection rule is E0308 with a `.copy()` fix, a mutable alias of
a read-only place is E0307, `var` is rewritten by `eiderc migrate-var`, and `eiderc
audit-refs` lists the writes whose meaning changed when `let` stopped copying).

**What a reference is.** A reference is its *place* (root variable, fields, element indices,
payloads), with every index evaluated once at the binding (and bounds-checked there); the
protection rule is what keeps the place meaning the same thing. A place that goes through heap
memory (a List element, a Box, a record with its own Drop) is cached in a pointer when the
reference is read-only (C8.54): set at the binding and again after each write that may move a
buffer on its path while the reference is alive (a copy-on-write un-share), so it always
points at the variable's current data. Mutable aliases and references that stay inside
the variable's own storage are re-derived at each use, which costs the same there.

```eider
let o = orders[i]      // a read-only reference to orders[i]; nothing is copied
let n = count(xs)      // a fresh value: owned by n, nothing is copied either
print(o.qty)
```

- `let` of a place (variable, field, element) binds a read-only reference to it.
- `let` of a fresh value (call result, literal, constructor) owns it.
- A `let` binding can't be assigned to and can't be mutated through.

### `let mut` ✅ (a mutable alias)

`let mut x = place` binds a mutable reference to the place: writes through `x` change the
original, and other code in the scope may also write the place. Both always see the same value.

```eider
let mut o = orders[i]
o.qty += 1             // orders[i].qty changes too
orders[i].qty = 0      // o sees 0
let mut total = 0      // of a fresh value: an ordinary mutable variable
total += 1
```

- `let mut` of a fresh value owns it (an ordinary mutable local).
- `let mut` of a read-only place (a parameter, a `let` binding) is an error: an alias can't add
  write access. Take a `.copy()` instead.
- An invalidating write while any reference into the place is alive stays forbidden (the
  protection rule, below).

### Pattern bindings ✅ (like `let` / `let mut`)

```eider
match orders[i] {                 // the scrutinee is a place
    Pending(o) => print(o.qty)    // o: a read-only reference into the payload
    Held(mut h) => h.days += 1    // h: a mutable alias into the payload
}
match load() {                    // the scrutinee is a fresh value
    Some(cfg) => use(cfg)         // cfg owns it
}
```

The protection rule covers the risky case: replacing `orders[i]` inside the arm while `o` is
still used is rejected (type confusion).

### `x.copy()` ✅ (a full clone, through the `Copy` trait)

`x.copy()` returns an independent clone of `x`: it never shares anything with `x`. It is the
method of the `Copy` trait (see "Operations are traits" below). `let mut o = orders[i].copy()`
changes `o` only. With copy-on-write a value copy costs a reference-count increment until one
side is written.

Sharing is ordinary binding and passing: binding, passing or storing a handle gives another
holder of the same value. `.copy()` is how you get your own.

| Type | `Copy`? |
|---|---|
| Integers, `bool`, `str`, records, enums, tuples, arrays, `String`, `List`, `Map`, `Box` | Yes, derived automatically when every part is `Copy` (a lazy copy through copy-on-write) |
| `Ref[T]` | Yes when `T` is: a new `Ref` holding a copy of the contents |
| `Mutex[T]` | Yes when `T` is: locks, copies the contents into a new `Mutex`, unlocks |
| `Chan[T]`, `Task[T]` | No: a running thread can't be cloned and a cloned queue has no clear meaning, so `.copy()` on them, or on anything containing them, is a compile error |

Implicit copies still happen at escapes (rule 3); `.copy()` is for when you want your own value
inside the scope.

## Operations are traits ✅

Implemented by C8.4 (docs/compiler.md, "C8.4: operation traits", which records the details
decided there: `Show` appends to a String and `to_string` builds one, Map equality ignores slot
order, `Drop` is for records and copies a shared value through `Copy` when it is written).

Every operation the language performs on values of any type is a trait in the core prelude, so
std and other libraries implement it for their own types exactly as the built-in types do.
Nothing is special-cased in the compiler beyond calling the trait.

- **Derived automatically.** A record, enum or tuple gets the trait when all its parts have it,
  with no annotation, so ordinary types need no code (the Go/Zig feel). A type with a part that
  lacks the trait doesn't get it, which is how `Chan`, `Task` and OS resources stay
  non-copyable.
- **Overridable by the type's owner.** `impl Copy for Image { fn copy(self) -> Image { ... } }`
  replaces the derived version: for example a library type that must copy an external resource,
  or one that keeps a cache it shouldn't copy. Only the package that defines the type may
  implement a language trait for it (orphan rule), so behaviour can't change depending on
  imports.
- **Generic code states what it needs.** Calling `.copy()` on a `T` in a generic function needs
  `T: Copy`; the compiler suggests the bound as a fix.

| Operation | Trait | Notes |
|---|---|---|
| `x.copy()` | `Copy` | Full clone; `Chan`, `Task` don't implement it |
| `==`, `!=` | `Eq` | Replaces today's built-in equality (which excludes Maps) |
| `<`, `<=`, `>`, `>=`, sorting | `Ord` | Needs `Eq` |
| Map keys, hashing | `Hash` | Lifts today's limit to ints, `bool`, `str`, `String`; needs `Eq` |
| `print`, string formatting | `Show` | |
| `for x in e` | `Iter` | Ranges, `List`, arrays and `Map` built in; any type that implements it (the loop runs on its own copy of `e`); see [Iteration](#iteration) |
| Cleanup at end of life | `Drop` | Resource types close files and sockets; runs once, when the last holder of a shared buffer goes |

All seven shipped together as the first set, since they share the derive and orphan-rule
machinery; `Default` (C8.23) is the eighth.
A type can't opt out of a derived trait: it lacks one only when one of its parts does, so there is
one way to make a type non-copyable.

Arithmetic operators (`+`, `*`, ...) stay built in for numbers only: no operator overloading.

## The protection rule ✅ (revised for `let mut` aliases)

While a reference is alive (until its last use), no write may free, move or reinterpret memory
it points into. Plain writes are allowed; invalidating writes are compile errors with a
machine-applicable fix ("take a `.copy()` first", or "use the reference before the change").

- **Allowed** while references into a place are alive: writing a scalar field or element,
  writing through `let mut` aliases, calling methods that don't resize or replace.
- **Invalidating (error):** resizing a container the reference points into (`push`, `insert`,
  `remove`, `pop`, `clear`); assigning a new value over a place that owns heap memory a
  reference points into (a `String`, `List` or `Box`); replacing an enum value whose payload a
  reference points into (type confusion); moving or dropping the place.

```eider
let o = orders[0]
orders[0].qty = 5          // fine: o sees 5
orders.push(new_order)     // error: may move the buffer `o` points into
print(o.qty)               //        o is used here
```

The check works on place paths (root, fields, elements) and needs no lifetimes, because
references never outlive their scope; it generalises today's `inout` exclusivity check (E0301).
Element indices are not tracked one by one: a reference into `orders[i]` and a resize of
`orders` conflict whatever `i` is.

## Iteration ✅

Implemented: C8.20 for Maps, C303 for Lists (docs/compiler.md, "C8.20: iterating a Map").

`for x in e` runs over a **snapshot** of `e` taken when the loop starts, whatever `e` is: a
List, an array, a Map (its entries) or a type with its own `Iter` (the loop's own copy of the
iterator). The body may write, push to or clear the sequence it walks; the loop still sees
each element from before the loop exactly once, and its writes are in the sequence
afterwards.

```eider
for x in xs {
    if x == 1 { xs[2] = 30 }   // xs changes; the loop still sees the old xs[2]
    xs.push(x)                 // and it doesn't walk the new elements
}
```

With copy-on-write the snapshot is a reference count: the loop shares the buffer, and only
a write to the sequence inside the body makes the real copy (one per loop, the first write).
The alternative, a protection rule for loops (no invalidating write to the sequence while it
is walked), was rejected: it would make every worklist-style push an E0308, and it would
treat a List differently from an array and a Map, which already iterated a copy (C303).
A worklist that grows while it is walked is written with an index: `while i < xs.len()`.

Each loop variable owns a copy of its element (not a reference into the sequence), as
before.

## Crossing boundaries

### Escaping a scope ✅

A reference that is returned, stored into a field or collection, captured by an escaping
closure, or sent to another thread becomes a value at that point. Because of copy-on-write
(below) this costs a reference-count increment, not a copy.

```eider
fn first(orders: List[Order]) -> Order {
    let o = orders[0]
    o                      // escapes: the caller gets a value
}
```

✅ Decided: escapes that force a real copy are silent; a lint may point them out later.

### Copy-on-write values ✅

`String`, `List`, `Map`, `Box` (and records/enums containing them) share their heap buffer
with a reference count. A "copy" bumps the count; the first mutation of a buffer whose count is
greater than one makes the real copy. Semantics are unchanged (still values), so existing code
and tests are unaffected. Counts are non-atomic: a value is made unique (every buffer it reaches
its own) before it crosses to another thread, so no count is ever shared by two threads (C8.1;
docs/compiler.md, "C8.1: copy-on-write", has the scheme and why it beat atomic counts).

This is what makes large lists, parsed files and configuration cheap to pass, store and
return.

### Shared mutable state: `Ref[T]` ✅

Implemented by C8.7 (docs/compiler.md, "C8.7: `Ref[T]`", which records the details decided
there: `Ref.new`, `read`, `update`, `get`, `set`; closures with `inout` parameters for
`update`; the trap messages; E0411 for a Ref that would cross threads).

For state several owners must see change: caches, memo tables, graphs, observer lists. (A
plain reference is a binding inside a scope; a `Ref[T]` is the handle that outlives scopes.)

```eider
type Ctx = { cache: Ref[Map[String, Answer]], rows: List[Row] }   // rows: copy-on-write

fn lookup(ctx: Ctx, key: String) -> Option[Answer] {
    ctx.cache.read(|m| m.get(key))                  // no copy of the map
}

fn remember(ctx: Ctx, key: String, a: Answer) {
    ctx.cache.update(|inout m| m.insert(key, a))    // every holder of ctx sees it
}
```

- Binding, passing or storing a `Ref` shares the same value (handle semantics, like `Mutex`
  today); `r.copy()` makes a new `Ref` with a copy of the contents.
- Access is scoped (`read`, `update`), so no reference to the inside escapes.
- Overlapping access (an `update` inside a `read` of the same `Ref`) traps at run time, like
  Rust's `RefCell`.
- Not sendable to another thread: use `Mutex[T]`, which has the same scoped shape.
- Cycles of `Ref` leak (as `Rc` cycles do in Rust): not a safety issue; a lint later.

### Threads ✅

- Values sent to a thread (`spawn` captures, `Chan.send`) are moved, or made unique before
  they cross (every copy-on-write buffer they reach their own, C8.1), so no reference count
  is shared by two threads.
- Mutable state crosses threads only inside `Mutex[T]` / `Chan[T]` (the built-in handles,
  C7 threads) and std's layer above them (docs/runtime.md): std/chan's bounded channels with
  deadlines and **`select`** over channel cases, timers and deadlines (cancel-safe: a case
  that isn't chosen never loses a value), std/sync's `Lock` and `Parker`, std/atomic, and
  std/task's tasks, groups and cancellation.
- References never cross threads (rule 3), and neither does a `Ref` (E0411).

## Functions and closures

✅ Implemented:

- Parameters are read-only references; `inout` parameters are mutable references with
  exclusivity (E0301).
- No `mut` parameters for now. `let mut x = x` on a read-only parameter is an error (E0307:
  an alias can't add write access); write `let mut x = x.copy()`.
- Return values are always values (owned). Returning a reference into an argument is not
  possible; accessors that return a reference ("projections") are a later, std-only feature
  ([#11](https://github.com/klxdev/eider-lang/issues/11)).
- **Closures that are run before their call returns capture by reference** (C8.53): a
  closure written as the argument of a List combinator (`map`, `filter`, `fold`, `for_each`,
  `any`, `all`), of `Ref.read` or `update`, or of `Mutex.update` holds the address of each
  variable it uses; nothing is copied, and it reads the variable as it is when it runs.
- **Every other closure captures a snapshot**: when the closure is made, each captured
  variable is copied into its environment (a copy-on-write share, so a count, not a deep
  copy), and the body sees that value however the variable changes afterwards. That
  holds for a closure that is stored, returned, passed to a function of your own or spawned.
- Closures change captured state only through their own `inout` parameters (`|inout m|`,
  C8.7) or a `Ref`; no implicit mutable captures.

✅ Non-escaping closures capture by reference (C8 item 8.8, [#4](https://github.com/klxdev/eider-lang/issues/4)):
the sites are the ones the compiler runs to completion before the call returns, so nothing
can write a captured variable while the closure runs (the closure itself can't, and the one
write a combinator could make, to its receiver, is a resize the protection rule rejects).
The visible difference from a snapshot is therefore small: no copy, and a closure that
captures a reference (`let o = orders[0]`) counts as a use of it where it is written.
Escaping closures (stored, returned, passed to your own functions, spawned) keep
capturing by value.

## What we will not add ✅

Lifetimes; raw pointers above the core; garbage collection; inheritance; exceptions; null;
implicit conversions; macros (`comptime` covers code generation); multiple ways to do one
thing. Test for any new feature: would Go or Zig add this, and does it keep the six rules
true?

## What it costs, honestly

- Aliasing inside a scope is visible: a `let mut` alias changes the original, so a reader of a
  function must follow its aliases. Reasoning stays local to the scope.
- Two kinds of write to learn: plain writes are fine under live references, invalidating ones
  are not.
- No structures built from references (self-referential structs, intrusive lists): use indices
  or `Ref` handles, as the compiler already does with its arenas.
- Run-time checks remain where Rust has them too: bounds, overflow, and `Ref` access conflicts.
- `Ref` cycles leak.

## Build order

1. ✅ Copy-on-write for heap types: runtime and lowering only, no semantic change (C8.1).
2. ✅ References by default, `let mut` aliases, `.copy()` and the protection rule: checker
   analysis on place paths, new errors with fixes, lowering (a reference is its place,
   re-derived at each use: no clone, no drop; C8.6). `var` keeps working as a deprecated
   spelling with an automatic fix: `var x = place` becomes `let mut x = place.copy()`,
   `var x = fresh` becomes `let mut x = fresh` (`eiderc migrate-var`). Read-only references
   through heap memory are pointers (C8.54); open: pointers for mutable aliases, migrating the repository
   off `var` and retiring it ([#2](https://github.com/klxdev/eider-lang/issues/2)).
3. ✅ `Ref[T]` on the existing handle machinery (C8.7).
4. ✅ Non-escaping closures capture by reference (C8.53).
5. ❓ Later: projections for std accessors; lints for real copies and `Ref` cycles
   ([#11](https://github.com/klxdev/eider-lang/issues/11)).

## Decisions

| Question | Decision |
|---|---|
| `let mut` | A mutable alias of the place (Reading A) |
| Independent values | `x.copy()`, a full clone that never shares |
| `copy` of a handle | A clone of the contents (`r.copy()` is a new `Ref`); sharing is ordinary binding and passing |
| Name | `copy` |
| `.copy()` on `Chan`, `Task` | A compile error: they don't implement `Copy` |
| Pattern bindings | Like `let` / `let mut`: a place gives a reference, `mut` an alias, a fresh scrutinee is owned |
| Language operations | Traits in the core prelude, derived automatically, overridable by the type's own package |
| First set of operation traits | All seven: `Copy`, `Eq`, `Ord`, `Hash`, `Show`, `Iter`, `Drop` |
| `Drop` with copy-on-write | Runs once, when the last holder of a shared buffer goes |
| Opting out of a derived trait | Not allowed: a type lacks a trait only when one of its parts does |
| Warn when an escape forces a real copy | No: silent; a lint later |
| Name of the shared handle | `Ref[T]` |
| `mut` parameters | Not now; `let mut x = x.copy()` |
| Closure captures | Non-escaping by reference, escaping by value (implemented, C8.53) |
| What a reference is | Its place (C8.6); a pointer to it when it is read-only and goes through heap memory, refreshed after writes that may move that memory (C8.54, [#1](https://github.com/klxdev/eider-lang/issues/1)) |
| `for` over a sequence | A snapshot taken before the loop, for Lists as for arrays and Maps (C303) |

## Open items

No design question is open. Work still to do on the model:

- [#1](https://github.com/klxdev/eider-lang/issues/1) C pointer variables for references (done for read-only references; mutable aliases remain).
- [#2](https://github.com/klxdev/eider-lang/issues/2) Retire `var`.
- [#3](https://github.com/klxdev/eider-lang/issues/3) `Ref[T]`: inout fn values and the export boundary.
- [#4](https://github.com/klxdev/eider-lang/issues/4) Closures capture by reference (non-escaping ones).
- [#11](https://github.com/klxdev/eider-lang/issues/11) Projections and copy/cycle lints.
- [#90](https://github.com/klxdev/eider-lang/issues/90) std/sync's `Lock` copies the whole guarded value on every use.
