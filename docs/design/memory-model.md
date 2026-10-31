# Eider memory model (draft for iteration)

Status: **draft**. Decisions marked ✅ are agreed; ❓ are open. Nothing here is implemented
yet beyond what Eider already does (value semantics, `inout`, `Mutex`/`Chan`). Iterate on
this file; when a section settles, it becomes a C8 work item (docs/compiler.md).

## Goal ✅

Simple like Go and Zig, with the memory-safety and correctness guarantees of Rust.

- No lifetimes, no borrow annotations, no garbage collector, no raw pointers above the core.
- Safety comes from a small model the compiler can check completely, not from a large type
  system the programmer has to satisfy.

## The model in five rules ✅ (wording to refine)

1. Everything is a value. Binding or passing something does not copy it.
2. To change something, mark it `mut` (or pass it `inout`).
3. A reference lives inside its scope. When it escapes (returned, stored, sent to a thread),
   it becomes a value: cheap, because large values are copy-on-write.
4. To share mutable state, use `Shared[T]`, or `Mutex[T]` across threads.
5. Errors are `Result`, absence is `Option`, every case is handled in `match`, side effects
   are declared with `uses`.

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

```eider
let o = orders[i]      // a read-only reference to orders[i]; nothing is copied
let n = count(xs)      // a fresh value: owned by n, nothing is copied either
print(o.qty)
```

- `let` of a place (variable, field, element) binds a read-only reference to it.
- `let` of a fresh value (call result, literal, constructor) owns it.
- A `let` binding can't be assigned to and can't be mutated through.

### `let mut` ❓ (the user's intent, to pin down)

User's statement: **"for mut, others in scope can update the reference."**

Two readings, with different consequences:

**Reading A: `let mut` is a mutable alias of the place.** Writes through the binding change
the original, and the original can still be changed by other code in the scope.

```eider
let mut o = orders[i]
o.qty += 1             // orders[i].qty changes too
orders[i].qty = 0      // and o sees it
```

Safe only if nothing can invalidate the place while `o` is alive. Changing `orders[i]`'s
fields is fine (same memory). But `orders.push(x)` may move the list's buffer, and
`orders = other` drops it: either would leave `o` dangling. So Reading A needs a rule such
as "while a `let mut` reference to an element is alive, the container it points into can't
be resized, replaced or dropped" (field and element *writes* stay allowed). That is still
checkable without lifetimes, but it is a new kind of rule ("structural" vs "content"
changes) that every programmer has to learn.

**Reading B: `let mut` is a mutable binding.** The binding can be reassigned and mutated, and
code in the same scope sees those updates through the binding. It starts as its own value
(a copy-on-write copy of a place, or the fresh value itself), so it never aliases the
original.

```eider
let mut total = 0
total += 1             // the binding is updatable
let mut o = orders[i]  // o is its own value
o.qty += 1             // orders[i] is unchanged
```

No new safety rule: this is today's `var` with the new spelling.

**Recommendation:** Reading B for `let mut`, and keep in-place changes to an element explicit
through `inout`, which already has the exclusivity rule:

```eider
bump(inout orders[i])          // changes orders[i] in place
```

If in-place local aliases (Reading A) are wanted, add them as a separate, explicit form
later (e.g. `let inout o = orders[i]`), with exclusivity: while `o` is alive, `orders` is
reachable only through `o`. That keeps "mutation through an alias" visible at the point it
happens, which is most of what makes Rust code easy to reason about.

**Decide:** A, B, or B plus an explicit in-place alias form.

## The protection rule ✅ (applies to every reference)

While a reference is in use (until its last use in the scope), the place it refers to can't be
moved, dropped, or changed in a way that could invalidate it. Violations are compile errors
with a machine-applicable fix (usually "make it `let mut` to take your own value", or "use the
value before changing the original").

```eider
let o = orders[0]
orders.push(new_order)     // error: `orders` is changed while `o` (line 1) still refers into it
print(o.qty)               //        o is used here
```

This is the existing `inout` exclusivity check (E0301) extended to read references. No
lifetimes are needed because references never outlive their scope.

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

❓ Should the compiler warn when an escape forces a *real* copy (a shared buffer about to be
mutated)? Default proposal: silent; a lint later.

### Copy-on-write values ✅

`String`, `List`, `Map`, `Box` (and records/enums containing them) share their heap buffer
with a reference count. A "copy" bumps the count; the first mutation of a buffer whose count is
greater than one makes the real copy. Semantics are unchanged (still values), so existing code
and tests are unaffected. Counts are non-atomic for values that never leave their thread and
atomic once a value is sent to another thread.

This is what makes large lists, parsed files and configuration cheap to pass, store and
return.

### Shared mutable state: `Shared[T]` ✅ (API to refine)

For state that several owners must see change: caches, memo tables, graphs, observer lists.

```eider
type Ctx = { cache: Shared[Map[String, Answer]], rows: List[Row] }   // rows: copy-on-write

fn lookup(ctx: Ctx, key: String) -> Option[Answer] {
    ctx.cache.read(|m| m.get(key))                  // no copy of the map
}

fn remember(ctx: Ctx, key: String, a: Answer) {
    ctx.cache.update(|inout m| m.insert(key, a))    // every holder of ctx sees it
}
```

- Copying a `Shared` shares the same value (handle semantics, like `Mutex` today).
- Access is scoped (`read`, `update`), so no reference to the inside escapes.
- Overlapping access (an `update` inside a `read` of the same `Shared`) traps at run time,
  like Rust's `RefCell`.
- Not sendable to another thread: use `Mutex[T]`, which has the same scoped shape.
- Cycles of `Shared` leak (as `Rc` cycles do in Rust): not a safety issue; a lint later.

❓ Name: `Shared[T]`, `Cell[T]`, `Ref[T]`?

### Threads ✅

- Values sent to a thread (`spawn` captures, `Chan.send`) are moved, or shared read-only via
  copy-on-write.
- Mutable state crosses threads only inside `Mutex[T]` / `Chan[T]`.
- References never cross threads (rule 3).

## Functions

- Parameters are read-only references (as today); `inout` parameters are mutable references
  with exclusivity (as today). ✅
- ❓ `mut` parameters (`fn f(mut x: T)`): "give me my own value that I may change locally". Useful
  sugar for `let mut x = x`; add only if it carries its weight.
- Return values are always values (owned). Returning a reference into an argument is not
  possible; accessors that return a reference ("projections") are a later, std-only feature.

## Closures ❓

- Escaping closures (stored, returned, spawned) capture by value (cheap with copy-on-write).
- Proposal: non-escaping closures (passed straight to `map`, `filter`, `fold`, `read`,
  `update`) capture by reference, so they cost nothing and see the current values.
- Closures that change captured state: only through `inout` parameters of the closure or a
  `Shared`; no implicit mutable captures.

## What we will not add ✅

Lifetimes; raw pointers above the core; garbage collection; inheritance; exceptions; null;
implicit conversions; macros (`comptime` covers code generation); multiple ways to do one
thing. Test for any new feature: would Go or Zig add this, and does it keep the five rules
true?

## What it costs, honestly

- Can't build structures out of references (self-referential structs, intrusive lists): use
  indices or handles (`Shared`), as the compiler already does with its arenas.
- Run-time checks remain where Rust has them too: bounds, overflow, and `Shared` access
  conflicts.
- `Shared` cycles leak.

## Build order (once the open questions settle)

1. Copy-on-write for heap types: runtime and lowering only; no semantic change.
2. References by default + `let mut` + the protection rule: checker analysis, new errors with
   fixes, lowering (a reference is a C pointer; no clone, no drop). `var` keeps working as a
   deprecated spelling of `let mut` with an automatic fix, so existing code migrates mechanically.
3. `Shared[T]` on the existing handle machinery.
4. Non-escaping closure captures by reference.
5. Later: projections for std accessors; lints for real copies and `Shared` cycles.

## Open questions (summary)

1. `let mut`: Reading A (mutable alias), B (mutable binding, own value), or B plus an explicit
   in-place alias form (`let inout`)?
2. Warn on escapes that force a real copy?
3. Name for `Shared[T]`.
4. `mut` parameters: yes or no?
5. Closures: non-escaping capture by reference?
