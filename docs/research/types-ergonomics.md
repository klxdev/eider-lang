# Type system, safety and ergonomics: what Eider should take (research, track 2 of #97)

Draft, 2026-10-31. This is track 2 of issue #97. It surveys what leading languages do and what their users report about it, then recommends what fits Eider's rules: value semantics, capabilities, no UB, a C core, and simplicity, i.e. "simple like Go/Zig with Rust's guarantees".

**How it was researched.** Most of the comparison comes from knowledge of the languages as of 2026. A few claims were checked against the web in this session: Swift typed throws, Python t-strings, Rust let-chains, and the status of Scala capture checking. Those are marked [W]. Every other source in the list is a canonical page that was not re-fetched here, the same convention docs/design/roadmap.md uses. The Eider facts come from README.md, docs/design/memory-model.md, docs/design/roadmap.md and docs/site/reference/*.md.

**The test for every proposal.** memory-model.md asks: *"would Go or Zig add this, and does it keep the six rules true?"* This document adds a second question: *does it remove a thing users write by hand today, or a trap they fall into?*

---

## 0. Where Eider stands today (relevant facts)

| Area | Today | Gaps the reference pages list |
|---|---|---|
| Sum types / match | Payload enums, nested patterns, exhaustiveness and reachability, `if let`, `while let`, or-patterns | Or-patterns can't bind names. There are no guards, no range patterns and no named-field record patterns. **A bare name that matches a constant binds a new name** (`MAX => ...` matches everything); this is a known footgun. String patterns match `str` only, not `String`. |
| Null | None; `Option` and `?` | — |
| Generics | Monomorphized, trait bounds, inference | No associated types and no const generics (arrays have a literal N only). Default method bodies are parsed and silently ignored (#75, #45). |
| Traits | Static dispatch, operation traits derived (`Copy Eq Ord Hash Show Iter Drop Default`), `From`, orphan rule | No `dyn` (#18). Calling a method by its trait is not possible (#50). |
| Effects | `uses io, fs, net, clock, threads`, per function and per package grants | No capability polymorphism (#46). An unused-capability lint is #85. |
| Errors | `Result` + `?` + `From`, std/error | defer/errdefer (#15), `main -> Result` (#12), std errors are Strings (#70, closed) |
| Strings | `str` literals, `String`, std/fmt | No interpolation (#17), no raw or multiline strings (#13), no `char` |
| Numbers | i32 i64 u8 u32 u64 usize, overflow traps, `+% -% *%` | No floats (#43), no u16/i16 (#44), no i128, no saturating ops, no checked-op methods, no `+%=` |
| Concurrency | OS threads, `Task`, `Mutex`, `Chan`, std select and task groups | Stackless tasks (#14), structured concurrency |
| Closures | Snapshot capture, `inout` params | Capture by reference (#4) |
| Functions | Positional args, methods | No named or default args. No list literals (#49). `if`/`match` can't be used as call arguments (#48). |

Eider already has the best-practice core: no null, sum types with exhaustive match, `Result` plus `?`, checked arithmetic, immutable by default, and declared effects. What is missing is mostly **ergonomic finish** (patterns, interpolation, defer, defaults) plus three larger pieces that are already planned: floats, `dyn Trait` and tasks.

---

## 1. Sum types and pattern matching

| Language | Exhaustive | Guards | Or-patterns with bindings | Ranges | Record/struct patterns | String/slice patterns | Notes |
|---|---|---|---|---|---|---|---|
| Rust | yes | `if` guard | yes (same bindings in each alt) | `0..=9`, `'a'..='z'` | `Point { x, y: 0, .. }` | `&str` literals; slice patterns `[first, .., last]`, `[x, rest @ ..]` | `@` bindings; `matches!`; let-else (1.65); let-chains (1.88, edition 2024) [W]; `#[non_exhaustive]` |
| Swift | yes | `where` | yes | `0...9`, `..<` | tuple and enum payload labels | `case "x"` on String | `if case`, `guard case ... else`; `@unknown default` for library enums |
| Kotlin | `when` on sealed: yes | arbitrary conditions | `,` alternatives | `in 1..9` | destructuring via componentN only | — | Guards in `when` (2.1/2.2); no deep nested patterns |
| Java 21+ | sealed + record patterns: yes | `when` | partial | — | `case Point(var x, var y)` | — | Patterns added late; nested record deconstruction |
| OCaml / F# | yes (warnings) | `when` | yes | char ranges | records `{ x; y = 0 }` | string literals, list `h :: t` | F# active patterns (user-defined patterns) |
| Haskell | warning only (`-Wincomplete-patterns`) | guards | — | — | records with `NamedFieldPuns` | list and string patterns | View patterns |
| Zig | `switch` exhaustive on enums and unions | — | `a, b =>` | `1...9` | — | — | Payload capture `|x|` |
| Go | none (type switch only) | — | — | — | — | — | Users' top requested feature is sum types (Go survey; issue #57644 "sum types") |
| Gleam / Elixir | Gleam: yes | Gleam `if` guards (restricted) | yes | — | record field labels | `"prefix" <> rest` string prefix patterns | Gleam's string-prefix pattern is popular for parsers |

**What users report.**
- Exhaustiveness is the single most valued property. Rust, Swift and OCaml users cite "adding a variant shows me every place to update".
- Guards are needed constantly. Their cost is that guarded arms don't count toward exhaustiveness, which every language accepts.
- Or-patterns that can't bind lead to duplicated arms. Rust stabilized nested or-patterns with bindings in 1.53 for that reason.
- Rust's `Struct { field, .. }` with `..` is loved because adding a field doesn't break every match.
- Slice patterns are niche but excellent for parsers and argument handling.
- **The constant-versus-binding ambiguity is a known trap.** Rust has the same issue: an uppercase name that isn't in scope binds. Rust mitigates it with a lint (`non_upper_case_globals`, and the "unreachable pattern" warning). Swift and Kotlin avoid it by requiring `let` to bind in patterns.
- let-else (Rust) and `guard let` (Swift) are widely praised. They remove the "pyramid of doom" from early returns.

**Lessons for Eider.**
1. Eider has the hard part, exhaustiveness. The finish is cheap and high-value: guards, or-patterns with bindings, named-field patterns with `..`, range patterns and constant patterns.
2. **Fix the constant footgun** by refusing to let a pattern name shadow a constant or fn in scope, with a fix that suggests `== MAX` or a guard. Alternatively, treat in-scope constants as constant patterns. Both are local to the checker. The second is friendlier and matches what readers expect.
3. Let `String` scrutinees match `str` literal patterns; it is the same bytes. Add slice patterns on `List` and arrays later, when views exist (#16).
4. Add `let PATTERN = expr else { diverge }` (let-else). It is one small construct, and with `?` it covers almost every early-exit shape.

## 2. Null safety

| Language | Approach | Lesson |
|---|---|---|
| Rust, Swift, Zig, OCaml, Haskell, Gleam | No null; `Option`/`?T`/`Maybe` | The consensus winner |
| Kotlin | `T?` nullable types, `?.`, `?:`, `!!`; platform types from Java leak nulls | `!!` and Java interop are where NPEs come back |
| C#, TypeScript | Nullable reference types and `strictNullChecks` added late, opt-in | Retrofitting is painful. Warnings, not errors, so holes remain. |
| Go | nil pointers, nil maps and nil interfaces (typed nil != nil) | Tony Hoare's "billion-dollar mistake"; nil-interface confusion is a Go FAQ entry |
| Java | `Optional` in the library, null everywhere else | A library Option without language support doesn't fix null |

**Lesson.** Eider is already right. The remaining ergonomics are optional chaining and defaulting. Eider has `?` for propagation; add `Option` methods (`map`, `and_then`, `unwrap_or`, `ok_or`) if missing. Don't add `?.` or `?:` operators: methods and `?` cover them without new syntax. Add let-else (§1).

## 3. Generics

| Feature | Rust | Swift | Go (1.18+) | Zig | Haskell / OCaml | Users' experience |
|---|---|---|---|---|---|---|
| Implementation | Monomorphization | Witness tables + specialization in optimizer | GC-shape stenciling + dictionaries | comptime duck typing | Dictionary passing / functors | Monomorphization is fast at run time but slow to compile and large in code size (Rust compile-time complaints, top of annual survey) |
| Associated types | `type Item;` | `associatedtype` | none | via comptime | type families / module types | Essential for `Iter`, collections, readers. Swift's PATs ("protocol with associated type can only be used as a generic constraint") were a top pain until `some`/`any` (5.7). |
| Const generics | `const N: usize` (min_const_generics 1.51; full generic_const_exprs still unstable years later) | integer generic params (SE-0452, `InlineArray`, Swift 6.2) | none | natural with comptime | — | The minimal version (values as parameters, no arithmetic in types) gives most of the value. Full const-expression generics have been stuck in Rust for 5+ years. |
| Default methods | yes | protocol extensions | — | — | default methods in typeclasses | Needed for any rich trait (Iterator has 70+ provided methods on 1 required) |
| Associated functions / consts | `fn new() -> Self`, `const` | `static func`, `static let` | — | — | — | Common, simple |
| Variance | Inferred for lifetimes and types | Built-in for some std types | none | none | — | Only matters with subtyping. Eider has none, so **no variance is needed**. |
| Specialization | `specialization` unstable since 2015, unsound with lifetimes; `min_specialization` internal only | Optimizer-only | none | comptime `if` | overlapping instances (discouraged) | A cautionary tale: coherence + specialization is very hard to make sound |
| HKT | none (GATs instead, 1.65) | none | none | comptime | yes | GATs took ~6 years. Most systems programmers don't miss HKT. |

**Lessons for Eider.**
1. **Associated types** are the next generic feature that matters. `Iter` today infers its item type from `next`'s return. Lazy adapters, `Read`/`Write`, collections and `Map`-like traits need `type Item` in a trait.
2. **Default method bodies** (#45, and #75 where they are silently ignored, which is a correctness bug) unlock std design. They are worth more than any other generic feature.
3. **Const generics, minimal form.** Allow `fn sum[N: usize](a: [i32; N])` and `type Buf[N: usize] = { data: [u8; N] }`, with no arithmetic in types. Comptime already exists to compute values. This is what Rust's min_const_generics and Swift's integer generics did, and it was enough for most users.
4. **Never specialization, never HKT, never variance.** There is no subtyping, and the orphan rule keeps coherence simple.

## 4. Traits, typeclasses and interfaces

| Language | Mechanism | Dispatch | Conformance | Pain reported |
|---|---|---|---|---|
| Rust | Traits; `impl Trait`; `dyn Trait` | static by default, `dyn` vtables | Explicit `impl`, orphan rule | Object-safety rules ("dyn compatibility") are confusing. Orphan rule blocks "impl serde for crate X" (newtype workaround). |
| Swift | Protocols; `some P` / `any P` (5.7) | witness tables; existentials boxed | Explicit; retroactive conformance allowed (warns since 5.10) | Existential vs generic confusion was so bad they added `any` keyword |
| Go | Structural interfaces | dynamic (itab) | Implicit | Loved for decoupling ("accept interfaces, return structs"). Accidental satisfaction is rare. Nil-interface trap. No generics bound until 1.18. |
| Haskell | Typeclasses | dictionaries | Instances, orphans warned | Typeclass hierarchies (Monad/Applicative) are heavy. Extensions zoo. |
| OCaml | Modules, signatures, functors; first-class modules | static functors, runtime first-class | Structural | Powerful but verbose. Modular implicits never landed. |
| Zig | none; `anytype` + comptime duck typing; hand-written vtables (`Allocator`, `Io`) | static / manual | Implicit | Error messages at instantiation; no documented contract |

**Lessons for Eider.** Static traits plus a restricted `dyn Trait` (#18, roadmap P0.7) is the right pair. To keep `dyn` simple, make dyn-compatibility a documented, short rule: no generic methods, no `Self` by value in arguments, and receiver `self`/`inout self`. Report it with one diagnostic that names the offending method, which is Rust's 2024 improvement. Box `dyn` values by default with copy-on-write. They are values like everything else, so `dyn Show` in a `List` just works. Keep explicit `impl` (Rust/Swift) over Go's structural interfaces. Operation traits, derivation and the orphan rule all rely on explicit conformance, and explicit conformance gives better errors.

## 5. Effects and capabilities

| System | What is tracked | Polymorphism | Handlers / resumption | Users' experience |
|---|---|---|---|---|
| Koka | Row-typed effects (`<io,exn,div>`), inferred | effect-row variables | Algebraic effect handlers, multi-shot | Elegant; research language. Evidence-passing compiles to C efficiently (Perceus RC). |
| Unison | Abilities `{IO, Exception}` | ability variables, inferred | Handlers | Liked; ability inference keeps signatures light |
| OCaml 5 | Effects untyped (runtime handlers) | — | One-shot continuations | Used for direct-style concurrency (Eio). No static tracking, so unhandled effects are runtime errors. |
| Scala 3 capture checking | Which capabilities a value captures (`A^{io}`) | yes | — (capabilities are values) | Experimental; "quite mature", separation checking "still fluid" [W] |
| Pony | Reference capabilities (`iso val ref box trn tag`) | via generics | — | Data-race freedom without locks; steep learning curve is the main complaint |
| Austral | Linear types + capabilities as linear values (`Filesystem` root capability passed down) | — | — | Very explicit; good for auditing, verbose |
| Roc | Platforms supply all effects; app code is pure; `!` suffix for effectful fns (purity inference) | — | — | Easy sandboxing; host/platform split |
| Java checked exceptions | Exceptions as effects | none (lambdas break it) | — | The cautionary tale: no polymorphism means `Function<T,R>` can't throw, so people wrap everything |
| Eider | `uses io, fs, net, clock, threads`, per package grants | none yet (#46) | — | — |

**Lessons for Eider.**
1. Eider's model is close to Roc's and Austral's in intent, and simpler than all of them. It is coarse-grained, declared, granted per package and enforced at the boundary. Keep it.
2. **Capability polymorphism (#46) is the one missing piece**, and Java's checked exceptions show why. Without it, `List.map(f)` can't take an `f` that `uses io`, so people route around the system. The minimal design follows Koka and Unison, simplified: a function type carries its `uses` set (`fn(A) -> B uses io`), and a generic higher-order function can say `uses E` where `E` is inferred from its fn arguments. Infer it entirely for closures passed inline.
3. **Do not add algebraic effect handlers.** Resumable handlers are a control-flow feature, like exceptions with continuations, and they need either stack capture or CPS. That collides with the C core and the "no hidden control flow" principle. Tasks (#14) get Eio-like direct style from capabilities without handlers. Testing, the main use case for handlers ("mock the clock"), is better served by passing values: an `Io`/`Clock` parameter in the Zig 0.16 style, or a test grant that swaps implementations.
4. **Do not add Pony reference capabilities or Austral linearity.** Value semantics plus `Mutex`/`Chan` already gives race freedom, with one concept instead of six.

## 6. Typestate, units of measure, refinement and range types

| Feature | Who | How | Experience |
|---|---|---|---|
| Typestate | Rust (consuming `self` + phantom types, `PhantomData`), Plaid (research), session types | `Conn<Open>` → `fn close(self) -> Conn<Closed>` | Works when values are moved. Builder APIs and embedded HALs use it. Verbose generics are the cost. |
| Units of measure | F# `[<Measure>] type m`; `float<m/s>`; erased at runtime | Unit inference with exponents | Loved by the few who use it (science, finance). Inference interacts with generics. Not copied by any mainstream language since 2008. |
| Newtype units | Rust newtypes, Go `type Meters int64`, Haskell `newtype` | Distinct nominal type, explicit conversion | Popular, simple. 90% of the value of units for 5% of the cost. |
| Range types | Ada `type Day is range 1 .. 31`, subtypes with runtime checks; SPARK proves absence | Checked on assignment; SPARK proves statically | Ada users rate it highly; catches real bugs. Pascal subranges too. |
| Refinement types | Liquid Haskell, F*, Dafny (SMT) | `{v:Int | v > 0}` checked by SMT | Powerful; SMT timeouts and unpredictable errors make it a research/verification tool |
| Pattern types | Rust experimental `u32 is 1..` (pattern types, for niches) | — | In progress |

**Lessons for Eider.**
- **Typestate already works** with value semantics. A method that takes the value and returns a different type is a typestate transition. Document the pattern; add no feature.
- **Units**: take *distinct types*, not F# measures. Eider's `type X = Y` is an alias. Add a nominal form, for example `type Meters = distinct i64` or a one-field record `type Meters = { m: i64 }` with derived ops. With no operator overloading, a one-field record can't use `+`. The best fit is a *distinct type* that keeps its base type's arithmetic only with itself (Go's defined types, Ada's derived types), with `as` to cross. That gives units, IDs (`UserId` vs `OrderId`) and money-in-cents with almost no new machinery.
- **Ranges**: Ada-style range subtypes on integers (`type Port = u16 range 1..65535`) checked like overflow, with a trap on out-of-range assignment, a compile error for constants, and `Port.try_from(n) -> Option`. They fit "no UB, checks everywhere" exactly. Consider them after distinct types, because they are the same mechanism plus a check.
- **No refinement types / SMT.** Checks should be decidable, fast and explainable.

## 7. String interpolation, formatting, raw and multiline strings

| Language | Interpolation | Format spec | Raw strings | Multiline | Notes |
|---|---|---|---|---|---|
| Python | f-strings `f"{x!r:>10}"`, `{x=}` debug; **t-strings** (PEP 750, 3.14) give a `Template` for safe SQL/HTML [W] | `:>10.2f` mini-language | `r"..."` | `"""..."""` + `textwrap.dedent` | t-strings show the lesson: interpolation should be able to produce structured data, not just str |
| Rust | `format!("{x} {y:?} {z:>8.2}")`; inline captures only of identifiers (2021) | `{:?}` Debug vs `{}` Display | `r#"..."#` | literal newlines; `\` continuation; no auto-dedent | Compile-time checked; can't interpolate expressions (`{a.b}` not allowed) — common complaint |
| Swift | `"\(x)"`, custom `StringInterpolation` protocol | via `formatted()` API | `#"..."#` | `"""` with indentation stripped by closing delimiter | Closing-delimiter dedent is widely admired |
| Kotlin | `"$x ${a.b}"` | `.format()` | `"""..."""` + `trimIndent()` | yes | Multi-dollar interpolation (2.2) for `$`-heavy text |
| Go | none; `fmt.Sprintf("%d", x)` | printf verbs | backtick raw | backtick | Verbs checked by `go vet` only |
| Zig | none; `std.fmt.format("{d}", .{x})` comptime-checked | `{d:>8}` | none; `\\` line-prefix multiline | `\\` lines | Line-prefix multiline is unambiguous and easy to indent |
| C# / JS / Java | `$"{x}"` / `` `${x}` `` + tagged templates / string templates withdrawn (JEP 465 dropped in 23) | — | `"""` raw (C# 11) | — | Java withdrew its template design, a sign that the security/processor angle is hard |

**What users report.** People strongly prefer inline interpolation over printf-style. Expression interpolation is wanted, but simple identifiers and field paths cover most uses. A debug form (`{x=}`, `{x:?}`) is beloved for logging. Auto-dedent of multiline strings matters a lot for tests and embedded SQL/JSON.

**Lessons for Eider (#17, #13, roadmap P0.5).**
1. `"{name} has {items.len()} items"` in ordinary string literals, through `Show`. Allow any expression that contains no string literals and no braces (Rust's limit is too strict; Swift's `\(...)` allows anything). `{{` escapes. The result is a `String` (fresh, owned).
2. A small format spec: `{x:>8}`, `{x:08}`, `{x:.2}` (floats), `{x:x}` (hex), `{x:?}` (debug/quoted form via `Show`'s debug variant). Check it at compile time, with the error at the spec.
3. Raw strings `r"..."` / `r#"..."#`. Multiline `"""` with Swift's rule: indentation is stripped up to the closing delimiter's column. That is clearer than Kotlin's `trimIndent()`.
4. **Later**, and only if SQL/HTML libraries need it: a typed template (Python t-strings, JS tagged templates) as a std type built by `fmt.template("...")` through comptime. Don't make it core syntax now.

## 8. Error handling and `defer`

| Language | Mechanism | Context / chain | Cleanup | Users' experience |
|---|---|---|---|---|
| Rust | `Result<T,E>`, `?`, `From` | `anyhow::Context`, `thiserror` derive, `Error::source` | `Drop` | Loved, but needs two crates (anyhow for apps, thiserror for libs); `Box<dyn Error>` friction |
| Zig | Error sets `error{A,B}`, inferred `!T`, `try`, `catch`, `errdefer` | Error return traces (debug); no payload | `defer`, `errdefer` | Inferred error sets are praised. No payload forces out-of-band diagnostics (`Diagnostics` struct). `errdefer` loved. |
| Go | `error` interface, `if err != nil`, `%w` wrapping, `errors.Is/As` | Wrapping chain | `defer` | Verbose. The `try` proposal was rejected in 2019, and in 2025 the Go team said it will stop pursuing syntax changes for error handling (go.dev blog "[ On | No ] syntactic support for error handling"). |
| Swift | `throws`, `try`, `do/catch`; **typed throws** `throws(E)` (SE-0413, Swift 6) | — | `defer` | The proposal itself says untyped throws stays the default for most code; typed throws is for exhaustive handling and Embedded Swift [W]. |
| Java | Checked exceptions | causes | try-with-resources, finally | Checked exceptions don't compose with lambdas; widely seen as a failure |
| Kotlin | Unchecked exceptions; `Result`; `runCatching`; rich errors proposal (union error types, 2.x) | — | `use {}` | Exceptions not tracked |

**Lessons for Eider.**
1. **Keep `Result` + `?` + `From`.** That is the right core, and there should be no exceptions.
2. Make the std/error story one blessed path, so the anyhow/thiserror split doesn't happen. A library error is a payload enum with derived `Show` and `From`. An application uses std's `Failure` with `.context("reading config")` and a printed chain. `main -> Result` prints the chain (#12).
3. **`defer` and `errdefer` (#15).** `Drop` covers resources. `defer` covers the non-resource cases: unlock, log, restore a field, close a span. `errdefer` is the one Zig feature every Zig user cites: undo partial work only if the function returns `Err`. Define `errdefer` as "runs when the function returns through an `Err` or a `?`". Forbid `return` inside a defer block (Zig and Swift do).
4. **Don't add typed throws, error-set inference or exceptions.** Eider's `Result[T, E]` already *is* typed throws, without a second syntax. Zig-style inferred error sets would be convenient (`!T`), but they make public signatures depend on the body. That breaks Eider's "signatures say everything" stance, which `uses` also follows.
5. **Error return traces** (Zig) are cheap in a compiler that controls `?`. Record the source location at each `?` that converts or propagates, behind a debug flag or always, as a small fixed ring. Consider this together with `#line` debugging (#25).

## 9. Concurrency models

| Model | Language | Colouring | Structured | Data-race safety | Users' experience |
|---|---|---|---|---|---|
| Goroutines + channels (M:N, stackful) | Go | none | no (errgroup, context by convention) | race detector only | Easiest model in practice. Goroutine leaks and forgotten `context` are the common bugs. |
| async/await + Futures (stackless) | Rust | yes | no (tokio::spawn is unstructured) | `Send`/`Sync` | Most-cited Rust pain: colouring, `Pin`, cancel-safety, `Send` bounds on futures, runtime fragmentation; async fn in traits only in 1.75 |
| `Io` interface | Zig 0.16 | none (Io passed as a value) | `Io.Group`, `Select` | none | New. The same code runs threaded or evented. Colourless by parameter. |
| Coroutines + structured concurrency | Kotlin | `suspend` | yes (`coroutineScope`, cancellation propagates) | none | Structured concurrency is the praised part. `suspend` colouring is milder than Rust's. |
| Actors + async + Sendable | Swift 6 | `async` | task groups | strict concurrency checking | Swift 6 strict mode migration has been very painful (Sendable warnings everywhere). Actor reentrancy surprises. |
| Virtual threads | Java 21 | none | `StructuredTaskScope` (preview) | none | Very well received. Blocking code scales. Pinning on `synchronized` was fixed in 24. |
| Processes + messages | Erlang/Elixir | none | supervision trees | no shared memory | "Let it crash" + supervisors are the gold standard for reliability |
| Eider plan (#14) | capability-driven stackless tasks | none (the `uses` set already marks blocking fns) | task groups, cancellation, deadlines | value semantics: only `Mutex`/`Chan` share | — |

**Lessons for Eider.**
1. The roadmap's choice combines the best ideas: Go/Java direct style, Kotlin/Trio structured concurrency, Rust-style stackless compilation, and Zig's "colourless by explicit signature". The capability set is the colour, and it is already in every signature, so nothing new is written. Keep it.
2. **Structured by default.** `spawn` inside a scope, and the scope waits. A detached task needs an explicit long-lived group (Kotlin's `GlobalScope` lesson: make the escape hatch visible).
3. **Cancellation at blocking capability calls only.** That is cancel-safety by construction, which avoids Rust's `select!` cancel-safety hazard. A cancelled task sees `Err(Cancelled)` from the blocking call, and `defer`/`Drop` run.
4. **Don't add actors** or Swift's reentrancy. Don't add `async`/`await` keywords. **Don't add `Send`/`Sync` traits**: value semantics already says what can cross (values and handles), and Swift 6's migration shows the cost of a marker-trait wall.
5. Supervision (Erlang) as a std pattern: contain a trap in a task and turn it into `Err` (#54). This is the service-grade version of "let it crash".

## 10. Immutability defaults, contracts and design-by-contract

| Language | Default | Contracts |
|---|---|---|
| Rust | immutable `let`, `let mut` | `debug_assert!`; contracts crate; experimental `#[requires]` (contracts in nightly, 2025) |
| Swift | `let` / `var`; value types | `precondition`, `assert` |
| Kotlin | `val`/`var`; read-only collections (not immutable) | `require`, `check` functions |
| Ada 2012 / SPARK | — | `Pre`, `Post`, `Type_Invariant`, `Static_Predicate`; SPARK proves them |
| Eiffel | — | `require`/`ensure`/`invariant`, the origin of DbC |
| D | — | `in`/`out`/`invariant` blocks (rarely used; removed in release builds) |
| C++26 | — | Contracts (P2900) accepted into C++26 after ~20 years; controversy over evaluation semantics |
| Zig | `const`/`var` | `std.debug.assert` (UB in fast modes!) |

**Lessons.** Eider is immutable by default with value semantics, the strongest default in the table. For contracts, the experience is that Eiffel- and D-style blocks are rarely used, while `require`-as-a-function (Kotlin) is used constantly. C++26 took 20 years because of "what happens in release builds". Eider's answer is already settled: checks run in every build, like overflow. Recommendation:
- Keep `assert` and add an `assert` with a computed message (#47), always on.
- Add **record invariants via a validating constructor**, by documenting the pattern: private fields (`pub` on the type, not its fields) plus `fn new(...) -> Result[T, E]`. That is "parse, don't validate", with no new feature.
- Do **not** add `requires`/`ensures` syntax now. Revisit if a prover or fuzzer integration wants machine-readable pre/post conditions; the eider-fuzzer could use them as oracles.

## 11. Numeric tower: floats, decimal, bigints, saturating and wrapping

| Language | Floats | Total order / Eq | Decimal | Bigint | Overflow | Saturating/wrapping |
|---|---|---|---|---|---|---|
| Rust | f32, f64 (f16/f128 unstable) | `PartialEq`/`PartialOrd` only; `total_cmp` (1.62); can't be `HashMap` keys | crates (`rust_decimal`) | crates (`num-bigint`) | panic in debug, wrap in release | `wrapping_*`, `saturating_*`, `checked_*`, `overflowing_*`, `Wrapping<T>`, `Saturating<T>` |
| Zig | f16..f128 | `==` IEEE | none | `std.math.big.int` | illegal behavior (checked in safe) | `+% -% *%` wrap, `+| -| *| <<|` saturate, `@addWithOverflow` |
| Swift | Float, Double, Float16 | `Equatable` (IEEE ==); `Comparable` (NaN breaks sort) | `Decimal` (Foundation) | none in std | trap | `&+ &- &*` wrap; `addingReportingOverflow` |
| Go | float32/64 | `==` IEEE; NaN map keys are unreachable (documented quirk); `clear` added partly for this | none (`shopspring/decimal`) | `math/big` | wrap silently | none |
| C# / Java | float, double, **decimal** (128-bit) / `BigDecimal` | — | built-in (C#) | `BigInteger` | `checked` contexts (C#) / wrap (Java), `Math.addExact` | — |
| Python | float | — | `decimal` (std) | int is bigint | none | — |
| Ada | digits/delta fixed-point types | — | decimal fixed point `delta 0.01 digits 12` | — | Constraint_Error | modular types |

**What users report.**
- Rust's `PartialOrd` floats annoy everyone: `sort()` doesn't work on `Vec<f64>`, people wrap in `ordered-float`, and `max` needs `f64::max`. The trade-off is that it is honest about NaN.
- Money in floats is a classic bug. Languages with decimal in std (C#, Python) see far fewer such bugs.
- Rust's debug-only overflow check is criticised; Eider's always-on traps are better.
- Zig's saturating operators are liked in DSP and graphics code.

**Lessons for Eider (#43, #44).**
1. **f64 and f32, IEEE, never trapping on NaN or infinity** (they are values, not UB). Rules:
   - `==` is IEEE.
   - Floats implement `Eq` but **not `Hash` or derived `Ord`**. Use `x.total_cmp(y)` and std `sort_by`.
   - A record holding a float therefore isn't a Map key. That is fine, and it follows the existing rule that a type lacks a trait when a part does.
   - `as` from float to int is checked: it traps on NaN or out-of-range, which Rust saturates and C makes UB.
   - `Show` prints the shortest round-trip form, locale-free, per the Rust lessons in docs/research/rust.md.
   - Literals `1.5`, `1e9`; a literal needs the expected type or defaults to f64.
   - No implicit int/float mixing.
2. **Checked and saturating as methods, not new operators**:
   - `a.checked_add(b) -> Option[T]`, `a.saturating_add(b)`, `a.wrapping_add(b)` (aliases of `+%`), and `a.overflowing_add(b) -> (T, bool)`.
   - Add the compound `+%=`. The reference says it is missing.
   - Zig's `+|` is cute, but methods keep the operator set small and are discoverable in the IDE.
3. **i8, i16, u16 (#44); then i128/u128.** C11 has no portable i128, so u128 needs a core helper or a two-word struct. It matters for crypto, hashing and decimal, but can wait.
4. **Decimal and BigInt in std, as library types written in Eider.** A `Decimal` (i64 or i128 coefficient + scale, explicit rounding modes) and a `BigInt`. With no operator overloading they use methods (`a.add(b)`), the way Java's BigDecimal works. That is acceptable for money code, where the explicitness is a feature.

## 12. Calls, methods, slices, iterators, closures, tuples, visibility

| Feature | Who has it | Experience | Eider fit |
|---|---|---|---|
| Named arguments | Swift (labels mandatory), Kotlin, Python, C# | Swift labels are praised for readability (`move(from: a, to: b)`); Rust users ask regularly (RFC never accepted) | Good: optional labels at call sites, checked against parameter names; makes boolean args readable |
| Default arguments | Kotlin, Python (mutable default trap), C++, Swift | Python's evaluated-once trap; otherwise loved; Rust uses builder pattern instead (boilerplate) | Good with **constant-expression defaults only** (no evaluation surprises) |
| Varargs | Go `...T`, Java, Swift, C | Modest value; Go's `append(a, b...)` spread is confusing | Not needed: list literals (#49) |
| Method syntax / UFCS | Rust, Go, D/Nim (UFCS) | UFCS causes ambiguity and IDE issues in Nim/D | Keep Eider's methods; no UFCS |
| Extension methods | Kotlin, Swift, C# | Discoverability and conflicts; Kotlin users love them, Swift retroactive conformance warns | Eider already lets a package add an `impl` of its own trait for any type; that is enough |
| Operator overloading | Rust (traits), Swift, Kotlin, C++ | Abuse in C++ (`<<`); useful for math/vectors/money | **Eider forbids it; keep forbidding.** Exception already exists: operation traits (`==`, `<`) map to Eq/Ord. Decimal/BigInt use methods. |
| Slices / views | Rust `&[T]`, Go slices (aliasing bugs on append), Zig `[]T`, Swift `ArraySlice` (keeps whole buffer alive) | Go append aliasing is a known trap; Swift slice index-base confusion | Read-only views as *references* under the scope rule (#16): `xs[a..b]` is a `let`-like reference, escape copies |
| Iterators / lazy sequences | Rust iterator adapters (zero-cost, loved), Python generators, C# `yield`, Kotlin `Sequence`, Swift `lazy` | Rust's adapters are among its best-loved features. Generators (`gen` blocks) are still unstable in Rust. | Lazy adapters need associated types + default methods; generators fall out of the stackless-task transform (#14) later |
| Closures | universal | Rust's Fn/FnMut/FnOnce trio is a learning hurdle; Swift `@escaping` | Eider's snapshot capture + `inout` + #4 (non-escaping by reference) avoids the trio |
| Tuples | universal | Fine for 2-3 elements; named tuples (Swift, C#) improve readability | Eider has them; consider labeled tuple fields later, low priority |
| Visibility | Rust `pub`, `pub(crate)`; Go capitalization; Swift 5 levels (`open/public/package/internal/fileprivate/private`) | Swift's levels are seen as too many; Go's capitalization is controversial but simple; Rust `pub(crate)` very useful | Eider has `pub`; add one more level only: package-visible (`pub(pkg)`), matching Go's `internal/` and Swift's `package` (SE-0386) |

---

## 13. Recommendation for Eider

**The shape.** Eider's foundation already matches the 2026 consensus for safe systems languages: sum types plus exhaustive match, no null, `Result`/`?`, checked arithmetic, immutable values and declared effects. The highest-return work is not new type theory. It is three things:
- **finishing what exists**: patterns, defaults in traits, error context;
- **removing hand-written boilerplate**: interpolation, defer, named and default args, lazy iterators;
- **the planned big three**: floats, `dyn Trait`, tasks.

Each proposal below passes the memory-model test: Go or Zig would plausibly add it, and the six rules stay true.

**Do NOT add, and why:**

| Feature | Why not |
|---|---|
| Exceptions, checked or unchecked; typed `throws` syntax | Hidden control flow. `Result[T, E]` already is typed throws. Java's checked exceptions show that effects without polymorphism fail. |
| Algebraic effect handlers (Koka, OCaml 5, Unison) | Resumable continuations need stack capture or CPS. That is hidden control flow at odds with the C core. Capabilities + tasks + passing values cover the uses. |
| Inferred error sets (Zig `!T`) | They make public signatures depend on function bodies, and Eider signatures say everything. |
| `async`/`await`, `suspend`, actors, `Send`/`Sync` | Colouring and marker-trait walls (Rust, Swift 6 migration). The capability set is the colour, and value semantics decides what crosses threads. |
| Pony reference capabilities, Austral linear types, Rust lifetimes | Value semantics + the protection rule + `Mutex`/`Chan` give the guarantees with one concept |
| Specialization, HKT, variance annotations, GADTs, dependent types | Unsound or years-long in Rust. No subtyping means variance is moot. Too much for "simple like Go/Zig". |
| Refinement types with SMT (Liquid Haskell, F*) | Undecidable-in-practice errors and timeouts; checks must be fast and explainable |
| F#-style units of measure | Distinct types give most of the value with none of the unit inference |
| Operator overloading, user-defined operators | Already forbidden; decimals and bigints use methods |
| Function overloading, UFCS, implicit conversions, extension methods on foreign types beyond trait impls | Multiple ways to do one thing; ambiguous resolution |
| `?.`, `?:`, `!!` null operators | No null. `?` + Option methods + let-else cover them. |
| Varargs | List literals (#49) cover them |
| `requires`/`ensures` syntax (now) | Rarely used where available; always-on `assert` + validating constructors give the same guarantee |
| Structural (Go-style) interfaces | Explicit `impl` is what derivation, coherence and good diagnostics depend on |
| More than one extra visibility level | Swift's five levels are a cautionary tale |

---

## 14. Ranked proposed features

Ranking is by impact over effort, weighted toward the P0 service goal and daily ergonomics. "Roadmap" means docs/design/roadmap.md or an existing issue.

| # | Feature | Impact | Effort | Depends on | On roadmap? |
|---|---|---|---|---|---|
| 1 | String interpolation, format specs, raw and multiline strings | H | M | #17, #13 | Yes (P0.5, #17, #13) |
| 2 | Pattern-matching finish: guards, binding or-patterns, named-field patterns with `..`, ranges, constant patterns, `String` vs `str` literals | H | M | — | No (new) |
| 3 | `let ... else` | M | L | (2) | No (new) |
| 4 | Default method bodies + associated types + calling by trait | H | M | #45, #75, #50 | Partly (#45, #50) |
| 5 | `defer` / `errdefer` | H | L | #15 | Yes (P0.3, #15) |
| 6 | Floats f64/f32 with honest equality and checked conversion | H | M | #43 | Yes (#43, layer/language) |
| 7 | Capability polymorphism | H | M | #46 | Issue only (#46) |
| 8 | `dyn Trait` with a short dyn-compatibility rule | H | H | #18, (4) | Yes (P0.7, #18) |
| 9 | Structured, cancellable tasks from capabilities | H | H | #14, #15, #54 | Yes (P0.2, #14) |
| 10 | Error-handling finish: one blessed path, `main -> Result`, `?` traces | M | L | #12, #25, #47 | Partly (P0.6, #12) |
| 11 | Lazy iterator adapters, then generators | M | M | (4), #4, #14 | No (new) |
| 12 | Named arguments and constant default arguments | M | M | — | No (new) |
| 13 | Integer completeness: i8/i16/u16, checked/saturating/overflowing methods, `+%=`, later i128 | M | L | #44 | Partly (#44) |
| 14 | Distinct (nominal) types, then integer range subtypes | M | M | — | No (new) |
| 15 | Read-only slice views and `pub(pkg)` visibility | M | M | #16, #91 | Partly (#16, P0.4) |

### 1. String interpolation, format specs, raw and multiline strings (#17, #13)
`"{user.name} has {n} items"` in every string literal, rendered through `Show` and producing a fresh `String`. Holes allow any expression without nested braces or quotes. A compile-checked spec follows the colon: `{x:>8}`, `{x:08}`, `{x:x}`, `{x:.3}` (floats), `{x:?}` (debug form). `print` and `fmt` take the same form, and `{{` escapes. Raw strings are `r"..."` / `r#"..."#`. Multiline strings use `"""` with indentation stripped to the closing delimiter's column (Swift). This is the most frequently written thing in services (logs, errors, responses), and every language without it gets complaints (Go, Zig, pre-2021 Rust). A typed template form like Python's t-strings stays a later std/comptime option for SQL/HTML.

### 2. Pattern-matching finish (new issue)
- Guards: `Some(n) if n > 0 =>`. Guarded arms don't count for exhaustiveness.
- Or-patterns that bind, when each alternative binds the same names with the same types.
- Named record and variant patterns: `Point { x, y: 0, .. }` and `Rect { w, .. }`, so adding a field doesn't break every match.
- Inclusive range patterns `0..=9` on integers, included in the exhaustiveness check.
- **Constant patterns.** A name that resolves to a `const` matches its value instead of binding, which removes today's footgun where `MAX =>` matches everything and an arm after it is E0102.
- `str` literal patterns against `String` scrutinees.

Each piece is local to the parser and checker, and together they bring Eider to Rust/Swift parity in daily code. Slice patterns `[first, .., last]` follow later with views (#15 in this list).

### 3. `let ... else` (new issue)
`let Some(user) = find(id) else { return Err(NotFound) }`. The else block must diverge (return, break, continue, panic). This is Rust's let-else and Swift's `guard let`, and both communities rank it among the most-liked additions because it flattens early exits. It is small given (2) and the existing refutable-pattern machinery. Let-chains (`if let A = x && cond`) are a possible follow-up. Rust needed an edition for them [W], so wait for demand.

### 4. Default method bodies, associated types, calling by trait (#45, #75, #50; associated types new)
Trait methods with bodies are inherited by impls and can be overridden. Today such bodies are parsed and silently ignored (#75), which is a correctness bug in itself. `type Item` in a trait, bound in each impl (`type Item = i32`), usable as `T.Item` in signatures. `Trait.method(x)` disambiguates. Associated types and default methods together are what make rich std traits possible: `Iter` with 30 provided adapters, `Read`/`Write` with `read_all`/`write_str`, `Error` with `context`. They also improve `dyn` (8).

### 5. `defer` / `errdefer` (#15)
`defer { stmt }` runs at scope exit in reverse order. `errdefer` runs only when the function exits through `Err` (a `return Err` or a `?`). Neither may contain `return`, `break` or `?`. `Drop` stays the tool for resources. `defer` handles restore, unlock, logging and spans, and `errdefer` undoes partial work, which is Zig's most-praised error-handling feature. Lowering to C is straightforward: cleanup labels, which the compiler already generates for drops.

### 6. Floats f64/f32 with honest equality and checked conversion (#43)
- IEEE f64 and f32. NaN and infinity are values, never traps and never UB.
- `==` is IEEE. Floats get `Eq` and `Show` but no `Hash` and no derived `Ord`; `total_cmp` and `sort_by` cover ordering.
- `as` to an integer traps on NaN or out-of-range values.
- `Show` prints the shortest round-trip form, independent of locale.
- Literals are `1.0` and `1e-3`. No int/float mixing without `as`.
- std/math covers the libm functions (`sqrt`, `floor`, ...); the C core already links libc.

Floats are needed for JSON, metrics, histograms, timeouts in seconds and general use. A `Decimal` (and a `BigInt`) follow as std types with methods, for money.

### 7. Capability polymorphism (#46)
- Fn types carry their capabilities: `fn(A) -> B uses io`.
- A generic higher-order function declares a capability variable, `fn map[T, U, uses E](xs: List[T], f: fn(T) -> U uses E) -> List[U] uses E`, inferred at each call.
- Closures written inline infer their set.

Without this, every std higher-order function either refuses effectful callbacks or forces `uses` everything. That is the Java checked-exceptions failure, and it happens exactly when tasks, services and middleware start passing handlers around. It is Koka/Unison row polymorphism without handlers or rows, just sets. It is also a prerequisite for capability-typed `dyn Handler` (8).

### 8. `dyn Trait` with a short dyn-compatibility rule (#18)
A boxed, copy-on-write value plus a vtable, usable in Lists, Maps and fields. Operation traits work through it.
- **The rule for which traits can be `dyn`:** no generic methods, no `Self` by value in parameters or results, and receivers `self` or `inout self`.
- One diagnostic names the method that breaks the rule. Rust's object-safety rules are a known source of confusion, so keep them few and printed.
- The capability set is part of the type: `dyn Handler uses net`.

Routers, middleware, plugins and heterogeneous collections need it (roadmap P0.7).

### 9. Structured, cancellable tasks from capabilities (#14, with #15 and #54)
These are the roadmap's capability-driven stackless tasks, with three rules taken from the survey:
- **Scoped by default.** A task group waits for its children, and a failure cancels its siblings (Kotlin, Java `StructuredTaskScope`, Trio).
- **Cancellation only at blocking-capability calls.** A cancelled call returns `Err(Cancelled)`, then `defer`/`Drop` run. This makes cancel-safety follow from the rules, which avoids Rust's `select!` hazards.
- **Traps contained per task** and surfaced as `Err` (#54), Erlang-style.

No `async`/`await`, no `Send`/`Sync`.

### 10. Error-handling finish (#12, #25, #47, extends P0.6)
One blessed path, so Eider never has a thiserror/anyhow split:
- Library errors are payload enums with derived `Show` and `From`.
- Applications use std's `Failure` with `.context(...)` and a cause chain.
- `main` may return `Result` and prints the chain with exit code 1 (#12).
- `panic` and `assert` take computed messages (#47).

Also add **error return traces**: each `?` that propagates records its source location in a small per-task ring, printed with the chain. Zig does this, and users credit it for fast debugging. This is cheap because the compiler owns `?`, and it pairs with `#line` (#25).

### 11. Lazy iterator adapters, then generators (new)
- `Iter` gains provided, lazy methods via (4): `map`, `filter`, `take`, `skip`, `zip`, `enumerate`, `chain`, `flat_map`, `collect`, `sum`, `fold`.
- They are monomorphized, so they compile to a loop.
- `List.map` and friends stay eager, as today; `xs.iter().map(f)` is lazy.
- Later, `gen fn` produces an `Iter` through the same state-machine transform as stackless tasks (#14). Python, C# and JS users love generators; Rust still lacks stable ones.
- Non-escaping closures capturing by reference (#4) make the adapters free.

### 12. Named arguments and constant default arguments (new)
- Call sites may label arguments: `connect(host, port: 8080, tls: true)`. Labels are checked against parameter names, and labeled arguments may be reordered after the positional ones.
- Parameters may have defaults that are **constant expressions** (comptime-evaluable), which avoids Python's evaluated-once trap.
- Record constructors get the same treatment: `Config(port: 8080)` with field defaults.

This removes the builder-pattern boilerplate Rust users complain about, and the boolean-argument readability problem, without overloading.

### 13. Integer completeness (#44, new methods)
- i8, i16, u16 (#44).
- `checked_add/sub/mul -> Option[T]`, `saturating_*`, `overflowing_* -> (T, bool)`, and `wrapping_*` as named aliases of `+% -% *%`.
- The missing `+%=`.
- `T.MIN` and `T.MAX`.
- i128/u128 later, behind a core helper, for crypto, decimal and hashing.

Methods, not Zig's `+|` operators, keep the operator set small. This is cheap and removes hand-written overflow-checking code from parsers and protocol work.

### 14. Distinct (nominal) types, then integer range subtypes (new)
- `type UserId = distinct u64` is a new nominal type with its base type's operations only against itself, and with `as` to convert.
- It gives units (`Meters`, `Millis`), IDs that can't be mixed up, and money-in-cents. That is about 90% of F# units-of-measure for very little machinery (Go defined types, Ada derived types).
- Later, Ada-style range subtypes: `type Port = distinct u16 range 1..=65535`. Checked on construction like overflow: a trap at run time, E05xx for a constant, and `Port.try_from(n) -> Option`.
- Typestate needs nothing new. Document the "consume and return a new type" pattern.

### 15. Read-only slice views and `pub(pkg)` visibility (#16, new)
- `xs[a..b]` on List, array and String gives a view. A view is a read-only reference under the existing scope and protection rules: no escape, and copy-on-escape.
- `for` and the adapters work on views, and slice patterns (2) follow.
- One extra visibility level, `pub(pkg)`, is visible within the package only. Go's `internal/`, Rust's `pub(crate)` and Swift's `package` (SE-0386) all show this is the one level beyond `pub` that people need. It fits with dotted imports (#91).

**Proposed new issues for review** (not filed): 2, 3, 11, 12, 14, the associated-types part of 4, the methods part of 13, the error-trace part of 10, and `pub(pkg)` in 15.

---

## Sources

Checked in this session [W]:
- Swift SE-0413 Typed throws: https://github.com/apple/swift-evolution/blob/main/proposals/0413-typed-throws.md ; Hacking with Swift, typed throws: https://www.hackingwithswift.com/swift/6.0/typed-throws ; forum thread on closure inference: https://forums.swift.org/t/closure-property-that-throws-typed-error-in-swift-6-result-in-compiling-error/72433
- Python PEP 750 Template strings: https://peps.python.org/pep-0750/ ; Dave Peck, "Python's new t-strings": https://davepeck.org/2025/04/11/pythons-new-t-strings/
- Rust 1.88 let chains: https://www.phoronix.com/news/Rust-1.88-Released (and the Rust blog release post https://blog.rust-lang.org/2025/06/26/Rust-1.88.0/)
- Scala 3 capture checking: https://scala-lang.org/files/archive/api/3.x/docs/experimental/capture-checking/overview.html ; separation checking PR: https://github.com/scala/scala3/pull/23249

Canonical references, not re-fetched in this session:
- Rust Reference, patterns: https://doc.rust-lang.org/reference/patterns.html ; let-else RFC 3137: https://rust-lang.github.io/rfcs/3137-let-else.html ; min_const_generics (1.51): https://blog.rust-lang.org/2021/03/25/Rust-1.51.0.html ; GATs (1.65): https://blog.rust-lang.org/2022/10/28/gats-stabilization.html ; specialization tracking issue: https://github.com/rust-lang/rust/issues/31844 ; `f64::total_cmp`: https://doc.rust-lang.org/std/primitive.f64.html#method.total_cmp ; dyn compatibility: https://doc.rust-lang.org/reference/items/traits.html#dyn-compatibility ; async fn in traits (1.75): https://blog.rust-lang.org/2023/12/21/async-fn-rpit-in-traits.html ; Rust survey 2024: https://blog.rust-lang.org/2025/02/13/2024-State-Of-Rust-Survey-results.html
- Swift: patterns https://docs.swift.org/swift-book/documentation/the-swift-programming-language/patterns/ ; SE-0335 `any`: https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md ; SE-0386 `package` access: https://github.com/apple/swift-evolution/blob/main/proposals/0386-package-access-modifier.md ; SE-0452 integer generic parameters: https://github.com/apple/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md ; Swift 6 concurrency migration guide: https://www.swift.org/migration/documentation/migrationguide/ ; multiline string literals: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/stringsandcharacters/
- Kotlin: null safety https://kotlinlang.org/docs/null-safety.html ; coroutines and structured concurrency https://kotlinlang.org/docs/coroutines-basics.html ; guard conditions in `when` https://kotlinlang.org/docs/control-flow.html#guard-conditions-in-when-expressions ; multi-dollar interpolation https://kotlinlang.org/docs/strings.html
- Java: JEP 441 pattern matching for switch https://openjdk.org/jeps/441 ; JEP 444 virtual threads https://openjdk.org/jeps/444 ; JEP 491 synchronize without pinning https://openjdk.org/jeps/491 ; JEP 465 string templates (withdrawn) https://openjdk.org/jeps/465 ; structured concurrency JEP 505 https://openjdk.org/jeps/505
- Go: "[ On | No ] syntactic support for error handling" https://go.dev/blog/error-syntax ; sum types proposal https://github.com/golang/go/issues/57644 ; nil error FAQ https://go.dev/doc/faq#nil_error ; generics implementation https://github.com/golang/proposal/blob/master/design/generics-implementation-gcshape.md
- Zig: language reference (error sets, errdefer, saturating ops) https://ziglang.org/documentation/master/ ; 0.16 `Io` release notes (as summarised in docs/research/zig.md)
- Koka: https://koka-lang.github.io/koka/doc/book.html ; Unison abilities: https://www.unison-lang.org/docs/fundamentals/abilities/ ; OCaml 5 effects: https://ocaml.org/manual/5.2/effects.html ; Eio: https://github.com/ocaml-multicore/eio
- Pony reference capabilities: https://tutorial.ponylang.io/reference-capabilities/ ; Austral: https://austral-lang.org/spec/spec.html and https://borretti.me/article/introducing-austral ; Roc platforms and purity inference: https://www.roc-lang.org/platforms , https://www.roc-lang.org/tutorial
- F# units of measure: https://learn.microsoft.com/dotnet/fsharp/language-reference/units-of-measure ; Ada subtypes and contracts: https://learn.adacore.com/courses/intro-to-ada/chapters/contracts.html ; SPARK: https://learn.adacore.com/courses/intro-to-spark/ ; Liquid Haskell: https://ucsd-progsys.github.io/liquidhaskell/
- C++26 contracts P2900: https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2025/p2900r14.pdf ; Eiffel DbC: https://www.eiffel.org/doc/solutions/Design_by_Contract_and_Assertion
- Python f-strings PEP 498: https://peps.python.org/pep-0498/ ; Rust `std::fmt`: https://doc.rust-lang.org/std/fmt/ ; inline format args (2021): https://blog.rust-lang.org/2022/01/13/Rust-1.58.0.html
- Erlang supervision: https://www.erlang.org/doc/system/sup_princ.html ; Trio structured concurrency ("Notes on structured concurrency"): https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/
- Tony Hoare, "Null References: The Billion Dollar Mistake" (QCon 2009): https://www.infoq.com/presentations/Null-References-The-Billion-Dollar-Mistake-Tony-Hoare/

Eider sources: README.md; docs/design/memory-model.md; docs/design/roadmap.md; docs/research/rust.md; docs/research/zig.md; docs/site/reference/{index,types,patterns,traits,capabilities,lexical}.md; `gh issue list -R klxdev/eider-lang` (2026-10-31).
