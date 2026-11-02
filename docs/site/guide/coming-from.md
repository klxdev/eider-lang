# Coming from another language

Short notes for programmers who know Rust, Go, Zig, C or TypeScript: what carries over,
what is different, and what to look up first. The [tour](tour.md) shows everything in
running code.

## From Rust

What carries over: `Result`, `Option` and `?`; exhaustive `match` with nested patterns;
traits with static dispatch and monomorphized generics; `impl` blocks; no null; overflow
checks; `From` conversions for `?`; a lock file with hashes.

What is different:

- **No lifetimes and no borrow checker annotations.** `let x = place` is a reference that
  can't outlive its scope, so its whole life is visible to the compiler; the only rule to
  learn is the [protection rule](memory.md#the-protection-rule) (no write that frees or
  moves what a live reference points into). There is no `&`, `&mut` or `'a`.
- **Value semantics everywhere.** Assigning or passing a `String`, `List` or `Map` never
  moves it away from you; copies are lazy (copy-on-write). There is no move error to fix:
  the cost of a copy is a reference-count increment until someone writes.
- `let mut x = place` is a mutable *alias* (like `&mut` without the annotation);
  `inout` parameters are `&mut` parameters, written `inout` at the call site too.
  `.copy()` is `clone()`.
- `Ref[T]` is `Rc<RefCell<T>>` (same run-time conflict check); `Mutex[T]` is
  `Arc<Mutex<T>>`. Neither needs wrapping in another type.
- **Operation traits are derived without `#[derive]`**: a type has `Eq`, `Ord`, `Hash`,
  `Show` (Debug/Display in one) and `Copy` when its parts do. No opt-out. (`Default` joins
  them with the next seed regeneration.)
- **Capabilities**: a function that does I/O says `uses io, fs, ...`, and a dependency gets
  only the capabilities your `eider.toml` grants. Rust has no equivalent.
- Missing today: `dyn Trait`, macros (by design: `comptime` instead), `async`
  (by design: blocking code on threads; stackless tasks planned without colouring),
  closures that mutate captures (pass `inout` or use a `Ref`), slices and views.
- Records are built positionally, `Point(1, 2)`; enum variants are in scope unqualified
  (`Some`, `Circle(r)`).

## From Go

What carries over: a small language, fast to read; blocking code instead of `async`;
channels; HTTP and JSON-RPC packages for services; one native binary; a
newline-terminated syntax; errors as values.

What is different:

- **Errors are `Result[T, E]`**, and `?` replaces `if err != nil { return err }`.
  `std/error`'s `.context("...")` is `fmt.Errorf("...: %w", err)`, and the chain prints the
  same way (`outer: inner`).
- **No nil.** Absence is `Option[T]`; every `match` handles both cases.
- **No garbage collector**: values are freed when their last holder goes, at a known
  point. You don't manage memory, but you can predict it.
- **No data races.** Goroutines can share memory; Eider threads share only `Mutex`,
  `Chan` and std's channels and locks, and everything else crosses by value. There is no
  race detector because there is nothing for it to find.
- **Generics with bounds** (`fn max[T: Ord](...)`), compiled per type.
- `spawn` starts an OS thread today, not a goroutine; std/task's groups and tokens are
  `errgroup` and `context` (cancellation and deadlines flowing down). Lightweight tasks
  are planned with the same APIs.
- `std/chan`'s channels are bounded by default, take a deadline on every operation, and
  have `select` (a function over cases, not a statement).
- Overflow traps instead of wrapping; use `+%` to wrap.
- Capabilities (`uses net`) and per-dependency grants have no Go equivalent; a module's
  reach is in its signatures.

## From Zig

What carries over: no hidden control flow, no hidden allocations you have to free, no
garbage collector, `comptime` (for constants, for now), errors as values, integer overflow
checks, cross-language interop through C, a self-hosted compiler that builds from a C
seed.

What is different:

- **Memory safety is checked, in every build**, not only in debug builds: bounds,
  overflow and the reference rules hold in `--release` too. There are no raw pointers above
  the small C core.
- **No allocators to pass around.** Heap values (`String`, `List`, `Map`, `Box`) free
  themselves; copies are copy-on-write.
- **Errors are `Result[T, E]`** with any error type, rather than error sets; `?` is `try`.
  `defer` and `errdefer` work as in Zig (`errdefer` runs when the function returns `Err` or
  `None`), and `Drop` cleans up when the last holder goes.
- **Traits and bounded generics** instead of `anytype` and duck typing.
- `comptime` evaluates integer and `bool` constants only; comptime reflection (for
  serializers) is planned.
- Capabilities: functions declare their effects, and dependencies are granted them.
- Labeled loops use Zig's `name: for` / `break name` shape (in the compiler sources; the
  committed seed doesn't have them yet).

## From C

What carries over: the output is C11, so anything that runs C runs Eider, and the
generated code is readable (`scripts/ei emit-llvm file.ei`); `extern "c"` calls C functions
directly and `export fn` builds `.a`/`.so` libraries with a header ([FFI](ffi.md)).

What is different:

- **No undefined behaviour in Eider code.** Out-of-bounds indexing, overflow, division by
  zero, shift counts and conversions are checked and trap with a message (exit 101).
  Evaluation order is strictly left to right.
- **No pointers, no `malloc`/`free`.** Values are freed exactly once, on every exit path.
  Use-after-free and double free can't be written.
- **Strings are values**: `String` is UTF-8 text with a length; `str` is a literal. Text
  from outside comes in as `List[u8]` and is checked (`String.from_bytes`).
- Strong types with no implicit conversions: `x as u64` is explicit and checked.
- Enums carry data, and `match` must cover every case.
- Calling C needs `unsafe` and the `ffi` capability, and a package that does it must be
  granted `ffi`: the unchecked parts of a program are always visible.
- No preprocessor, no headers to write: modules import each other.

## From TypeScript

What carries over: union-style enums with data and exhaustive matching (like
discriminated unions with `never` checks); generics; closures; `Option` instead of
`undefined`; a strict compiler that catches mistakes before running.

What is different:

- **Compiled to native code**, no runtime or VM. A program is one binary.
- **Nominal types**, not structural: two records with the same fields are different types.
- **Integers, not `number`**: `i32`, `i64`, `u64`, `usize`, ... with overflow checks and
  explicit `as` conversions. Floats are `f32` and `f64`, IEEE (`NaN != NaN`, no `Ord`, `as` to an
  integer traps on NaN); see [Numbers](numbers.md).
- **Values, not references**: assigning a record or List gives an independent value
  (copy-on-write); there is no shared mutable object graph unless you ask for one
  (`Ref[T]`).
- **Errors are values** (`Result`, `?`), not exceptions; there is no `try`/`catch`.
- **No `async`/`await`**: concurrency is threads with channels and locks.
- Side effects are declared: a function that prints or reads files says `uses io` or
  `uses fs`.
- To run Eider in a JavaScript runtime, build a WebAssembly module: `build --wasm` writes a
  `.wasm`, a `.d.ts` and a loader ([WebAssembly](wasm.md)). Exports take numbers and
  booleans today.
