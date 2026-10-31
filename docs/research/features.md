# Features to adopt: combined recommendation (research #97)

Three research tracks (2026-10-31) surveyed leading languages and ecosystems:
[metaprogramming and data mapping](metaprogramming-data.md),
[type system and ergonomics](types-ergonomics.md) and
[developer experience and ecosystem](dx-ecosystem.md). Each has comparison tables, sources
(claims not re-checked in that session are marked) and a ranked list. This page is the
combined priority order; every item is a GitHub issue (new ones say "Status: proposal" until
reviewed) on the board https://github.com/users/klxdev/projects/6.

## Principles the research converged on

- **No macro system.** Typed, read-only comptime reflection plus typed, declared attributes,
  and "derive" through reflective trait default methods: ordinary generic code, visible to the
  analyzer, no hygiene problems, compile cost only where used.
- **One data model** (serde-like, smaller) shared by JSON, TOML, protobuf, SQL rows and CLI/env,
  with validation attributes that also generate JSON Schema / OpenAPI: one source of truth.
- **No ORM.** sqlc-style SQL checked at compile time against the migrations, no database at
  build time (comptime has no capabilities).
- **Keep the language small.** Not adding: exceptions, async/await, actors, lifetimes, linear or
  reference capabilities, higher-kinded types, specialization, operator or function overloading,
  varargs, refinement types with SMT, units of measure.
- **Capabilities must reach generic code** (capability polymorphism), or they turn into Java's
  checked exceptions.
- **Tooling is the product**: zero-config formatter, one test tool, real debugging through
  Eider source, a lint framework, and a supply chain that uses capabilities as a defence.

## Priority order

### P1 (do next)

| Issue | What |
|---|---|
| #17 (+#13) | String interpolation with format specs, raw and multiline strings |
| #105 | Pattern-matching finish: guards, or-patterns, field patterns, ranges, constants (with bug #98) |
| #45, #107, #50 (+bug #75) | Default trait methods, associated types, calling by trait |
| #15 | `defer` / `errdefer` |
| #43 | f64/f32 with honest equality and checked conversion |
| #46 | Capability polymorphism |
| #19, #20, #7 | Typed attributes, typed comptime reflection on the IR interpreter |
| #99 | Reflective default implementations (derive without macros) |
| #100 | std data model (Encode/Decode) |
| eider-json#1 | JSON on the data model, secure by default |
| #9 | `eiderc fmt`, zero config |
| #25 | Debugging through Eider source, pretty-printers, sanitizer flags |
| #30 | `eiderc test` as the one test tool |
| #113 | `eiderc lint` with groups (unused `uses` #85, needless `.copy()`, unused `Result`) |
| #114, #24 | std/cli, std/log, std/config |
| #115, #33 | Supply chain: capability diff on update, MVS, checksum log |
| #116 | Onboarding: install script, pinned toolchain, templates |
| eider-analyzer#1 | Rename, signature help, inlay hints, fill match arms, test lenses |
| eider-http#6 | Production defaults: health, drain, rate limit, pprof |
| #104 | eider-sql: checked SQL, migrations, pool, transactions |
| #18, #14 | `dyn Trait`; structured cancellable tasks from capabilities |

### P2 (later)

#101 validation attributes and Schema derive, #102 `comptime embed`, #103 `eiderc expand`,
#106 `let ... else`, #108 error traces at `?`, #109 lazy iterators then generators, #110 named
and default arguments, #111 distinct types and range subtypes, #112 `pub(pkg)`, #44 integer
completeness, #16 zero-copy views, #117 playground, #118 property testing, #119 audit/vet,
#120 editions and `eiderc migrate`, #121 eider-auth and eider-template, #34 cross-compilation.
