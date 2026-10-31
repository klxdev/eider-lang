# Eider memory model (draft for iteration)

Status: **draft**. Shared doc for iterating: https://claude.ai/artifact/92bM8TX24tgdviTuHrNJ6L (this file is the source of truth; synced from it). Decisions marked ✅ are agreed; ❓ are open. Nothing here is implemented
yet beyond what Eider already does (value semantics, `inout`, `Mutex`/`Chan`). Iterate on
this file; when a section settles, it becomes a C8 work item (docs/compiler.md).

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
details decided there: a reference is its place re-derived at each use, the protection rule
is E0308 with a `.copy()` fix, a mutable alias of a read-only place is E0307, `var` is
rewritten by `eiderc migrate-var`).

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
| `for x in e` | `Iter` | Ranges and `List` today; any type that implements it after |
| Cleanup at end of life | `Drop` | Resource types close files and sockets; runs once, when the last holder of a shared buffer goes |

All seven ship together as the first set, since they share the derive and orphan-rule machinery.
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

- Values sent to a thread (`spawn` captures, `Chan.send`) are moved, or shared read-only via
  copy-on-write.
- Mutable state crosses threads only inside `Mutex[T]` / `Chan[T]`.
- References never cross threads (rule 3).

## Functions and closures ✅

- Parameters are read-only references; `inout` parameters are mutable references with
  exclusivity (both as today).
- No `mut` parameters for now. `let mut x = x` on a read-only parameter is an error (an alias
  can't add write access); write `let mut x = x.copy()`.
- Return values are always values (owned). Returning a reference into an argument is not
  possible; accessors that return a reference ("projections") are a later, std-only feature.
- Non-escaping closures (passed straight to `map`, `filter`, `fold`, `read`, `update`) capture
  by reference, so they cost nothing and see current values; escaping closures (stored,
  returned, spawned) capture by value, cheap with copy-on-write.
- Closures change captured state only through their own `inout` parameters or a `Ref`; no
  implicit mutable captures.

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

1. Copy-on-write for heap types: runtime and lowering only, no semantic change.
2. References by default, `let mut` aliases, `.copy()` and the protection rule: checker analysis on
   place paths, new errors with fixes, lowering (a reference is a C pointer: no clone, no drop).
   `var` keeps working as a deprecated spelling with an automatic fix: `var x = place` becomes
   `let mut x = place.copy()` (today's `var` makes its own value), `var x = fresh` becomes
   `let mut x = fresh`, so existing code migrates mechanically with unchanged meaning.
3. `Ref[T]` on the existing handle machinery.
4. Non-escaping closures capture by reference.
5. Later: projections for std accessors; lints for real copies and `Ref` cycles.

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
| Closure captures | Non-escaping by reference, escaping by value |

## Open questions

None open. Next: turn the design into C8 work items (docs/compiler.md), starting with
copy-on-write.
