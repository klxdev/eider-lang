# Language reference

This reference describes the Eider language as the compiler (`eiderc`, in `compiler/`)
implements it: the syntax, the types, what each construct means, and every error the
compiler reports. It is meant to be precise; the getting-started guide and the tour are
the places to learn the language from.

Every example on these pages is a test: programs are compiled and run and their output
compared, and the examples that must not compile are checked to fail with the error code
shown.

## Contents

| Page | Covers |
|---|---|
| [Lexical structure](lexical.md) | source text, newlines, comments, identifiers, keywords, literals, escapes, operators |
| [Types](types.md) | integers, `bool`, text, tuples, arrays, `List`, `Map`, `Box`, fn types, `Option`/`Result`, aliases, overflow, `as` |
| [Items](items.md) | functions, records, enums, traits, impls, constants, `pub`, tests, `main` |
| [Expressions](expressions.md) | operators and precedence, calls, methods, fields, indexing, closures, `if`, `match`, blocks, `?` |
| [Statements](statements.md) | `let`, `let mut`, `var`, assignment, `while`, `while let`, `for`, labels, `return`, `assert` |
| [Patterns](patterns.md) | every pattern form, `mut` bindings, exhaustiveness |
| [Memory model](memory.md) | places and references, `inout`, the protection rule, copy-on-write, `.copy()`, `take`/`replace`, `Ref[T]`, drops |
| [Traits and generics](traits.md) | user traits, generics and bounds, the operation traits, `From`, `Default`, the orphan rule |
| [Capabilities](capabilities.md) | `uses`, propagation, `ffi` per package, grants |
| [Concurrency](concurrency.md) | `spawn`, `Task`, `Mutex`, `Chan`, what can cross threads |
| [C interop (FFI)](ffi.md) | `extern "c"`, `unsafe`, `export fn`, libraries and headers, WebAssembly |
| [Compile-time evaluation](comptime.md) | `comptime` constants |
| [Modules and packages](modules.md) | imports, visibility, `eider.toml`, `eider.lock`, eider-pkg |
| [Runtime behaviour](runtime.md) | `main`, exit codes, traps, `panic`, `print`, test blocks |
| [Error codes](errors.md) | every error code, with an example and the fix |
| [Grammar](grammar.md) | the whole syntax in EBNF |

## The language in brief

- **Values.** Everything is a value; there are no pointers and no null. Binding a place
  with `let` refers to it, `let mut` aliases it mutably, and `.copy()` makes an independent
  value. Heap types (`String`, `List`, `Map`, `Box`) are copied on write, so passing and
  returning them is cheap.
- **Safety.** Integer overflow, out-of-bounds indexing and failed conversions trap in every
  build. A write that would invalidate a live reference is a compile error. Threads share
  data only through `Mutex` and `Chan`.
- **Errors and absence** are `Result` and `Option`, with `?` to propagate; every `match` is
  exhaustive.
- **Effects** are declared: a function that does I/O says `uses io`, and dependencies are
  granted the capabilities they may use.
- **Generics** are monomorphized and traits are statically dispatched; the operations the
  language performs (copy, equality, ordering, hashing, printing, iteration, cleanup,
  defaults) are traits, derived automatically.
- **Output** is portable C11, compiled by the system C compiler.

## Not yet in the language

These are designed or planned, not implemented; each page notes what it is missing. See
the [roadmap](../../design/roadmap.md) and the [memory model](../../design/memory-model.md)
design.

- floating-point types and literals, `char`, the integer widths `i8`, `i16`, `u16`, `i128`,
  `u128`, `isize`;
- `dyn Trait` (dynamic dispatch), associated types, default method bodies in traits;
- closures that capture by reference (today every closure captures a snapshot);
- lightweight (stackless) tasks, `select` in the language, structured concurrency;
- `defer`/`errdefer`, attributes, comptime reflection, string interpolation;
- a comptime interpreter (comptime constants are computed by compiling and running C, and
  only integers and `bool` are allowed);
- strings and records across the WebAssembly boundary.

## Compiler versions

The repository builds `eiderc` from a committed seed (`seed/eiderc.c`), which lags behind
`compiler/` between regenerations. These pages describe `compiler/`; a few features
(`Ref[T]`, closures with `inout` parameters, labeled loops, `Default`, method chains
across lines) are newer than the current seed.
