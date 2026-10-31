# Research track 1: metaprogramming and data mapping

Issue klxdev/eider-lang#97, track 1. Draft, 2026-10-31.

This document covers four topics: metaprogramming (macros, comptime, reflection, codegen), serialization and type mapping, database access, and validation/schema derivation. Each topic has a comparison table and lessons, and the document ends with a recommendation for Eider and a ranked list of features.

**Evidence markers.** Claims backed by a page fetched or searched for this draft cite it in [Sources](#sources). Claims marked **[k]** come from general knowledge of the language or library as of 2026 and weren't re-checked in this session. Check them before quoting them as fact. User sentiment ("love/hate") comes from forums, blog posts and issue trackers, so it's anecdotal.

**Eider constraints this must respect** (README, memory-model.md, roadmap.md, decisions C8):
- simplicity and no hidden control flow;
- capabilities checked per function and package, with comptime having none;
- compile speed: the front end is whole-program, and comptime currently costs a check plus a C compile per constant;
- LSP-friendliness (eider-analyzer);
- value semantics with copy-on-write;
- operation traits derived automatically;
- attributes `@name(k = v)` already decided (C8);
- comptime reflection planned (#20) on an IR interpreter (#7).

---

## 1. Macros and metaprogramming

### Comparison

| Language | Mechanism | Power | Main costs users report |
|---|---|---|---|
| Rust | `macro_rules!` (pattern macros, partly hygienic); proc macros (derive, attribute, function-like) are separate crates that run token-stream → token-stream, usually via `syn`/`quote` | Very high. Proc macros are arbitrary code over tokens | Compile time has four sources: building the macro crate, building its deps (syn, quote, proc-macro2), running it, and compiling the code it emits. How much it emits is invisible; `-Zmacro-stats` is still unstable (Nethercote 2025). Polkadot cached macro expansion in rustc and got 35% faster incremental builds. rust-analyzer has to run proc macros, and false errors or slowness around them are a common complaint. Proc macros see tokens only, not types **[k]**. |
| Zig | `comptime`: ordinary Zig runs at compile time; types are values; `@typeInfo(T)` reflects; per-kind constructors (`@Struct`, `@Enum`, …) build types since 0.16 | High for type-driven code (std.json, fmt and hash maps are all reflection). No syntax extension | No per-field metadata, so std.json can't do Go-style tags: you get parse options or a full custom `jsonParse`, which is "a lot more complicated" than a stringify hook. Errors surface at instantiation, deep in generic code **[k]**. Lazy analysis means unused code isn't checked **[k]**. |
| Nim | `template` (hygienic substitution) < `macro` (AST → AST, run in a compile-time VM) | Very high | The community rule is "use the least powerful construct". Untyped macros make DSLs that the IDE can't follow **[k]**. |
| Scala 3 | `inline def` / `inline if` / `inline match` for guaranteed inlining; macros as quotes `'{…}` and splices `${…}` over typed `Expr[T]`; `quotes.reflect` for trees; `derives` clause with `Mirror` for typeclass derivation | High and typed | Two tiers: inline is easy, macros are "way more complex to write". Scala 2 macros were dropped wholesale for Scala 3, which shows the cost of exposing compiler internals **[k]**. |
| Swift | Macros (5.9+): separate executables on swift-syntax, sandboxed, expanded at type-checked declarations; attached and freestanding roles | High, typed attachment points; output visible in Xcode ("expand macro") | Building swift-syntax made clean builds very slow: one report went from 4.3 min to 33 min, about 7.8x. Apple acknowledged it and later shipped prebuilt swift-syntax **[k]**. The sandbox blocks linking dynamic libraries. |
| Elixir | `quote`/`unquote`, hygienic by default (variables carry context), `var!` to escape | High; Phoenix and Ecto DSLs depend on it | The official guide says macros "should only be used as a last resort" and "macros are not your API". |
| Lisp / Racket | `syntax-rules`, `syntax-case`, `syntax-parse`; hygiene by sets of scopes; `#lang` for whole languages | Highest | Each project grows its own dialect. The power is real but hard to apply in a team **[k]**. |
| Kotlin | KSP (symbol processing that generates new files, can't modify existing code); K2 compiler plugins (kotlinx.serialization, Compose) | KSP is medium; compiler plugins are full power with an unstable API | KSP is up to 2x faster than kapt, which had to generate Java stubs first. kotlinx.serialization is its own compiler plugin, not KSP. Plugin APIs break between compiler versions **[k]**. |
| C# | Incremental source generators (`IIncrementalGenerator`): add-only, typed Roslyn model, cached pipeline; `ForAttributeWithMetadataName` is the fast path | Medium-high; add-only keeps code readable | The original `ISourceGenerator` regenerated on every keystroke. In large solutions the IDE may cancel generation and IntelliSense breaks. Cache hits depend on value equality of the models you build. |
| Go | `go generate` runs arbitrary commands (stringer, mockgen, sqlc); output is committed; reflection plus struct tags at runtime | Low inside the language, unbounded outside it | Generated files go stale. Tags are unchecked strings; a typo is silently ignored **[k]**. Runtime reflection is slow, and v1 json is reflection-based **[k]**. |
| D | Templates, CTFE, `static foreach`, `__traits` reflection, string `mixin` | Very high | String mixins are code-as-strings, so tooling can't see through them. A Nim discussion called Nim macros more capable than string mixins. |
| Jai | `#run` (arbitrary compile-time execution), `#insert` (splice code strings), compile-time access to the compiler's message loop | Very high, deliberately unrestricted | `#run` can do anything, I/O included. That is the opposite of a capability model, and inserted strings are opaque to tools **[k]**. |

### What to learn

1. **Most real-world metaprogramming is "derive an implementation from a type's shape".** Serde, Codable, kotlinx.serialization, System.Text.Json, clap, thiserror and utoipa all do it. Arbitrary syntax extension (DSLs, new control flow) is a minority use, and it costs the most to tool.
2. **Typed reflection beats token manipulation.**
   - Proc macros and Swift macros pay to parse tokens with a library (syn, swift-syntax) and still can't see types.
   - Zig's `@typeInfo` and Scala's `Mirror`, by contrast, give the type checker's own view, at no extra parsing cost.
3. **Separate macro executables are a build-time tax.** Rust and Swift both paid it, through syn and swift-syntax. An in-compiler interpreter (Zig, Nim, Jai, D CTFE) avoids it.
4. **Add-only generation keeps code legible.** C# generators and KSP can't rewrite user code, and IDE expansion views help (Swift, C#).
5. **Metadata needs a home.** Zig's lack of field attributes is its biggest serialization gap. Go's string tags are the opposite failure: they're unchecked.
6. **Incrementality must be designed in.** C# moved to incremental generators because the first API froze IDEs, and Rust is still adding expansion caching.
7. **Hygiene matters only if you splice syntax.** If code is generated by typed comptime evaluation over reflected types, not by token splicing, hygiene problems don't arise.

**Most power for least complexity: Zig-style typed comptime reflection plus declared attributes, used by library traits with a reflective default implementation.** This covers the derive use cases with no second language, no macro crates, no token parsing and no new hygiene rules. The code it produces is ordinary monomorphized Eider that the analyzer already understands. Syntax macros (Nim, Elixir, Racket, Rust function-like) should stay out, at least until a concrete need appears that comptime can't meet.

---

## 2. Serialization and type mapping

### Comparison

| System | How a type opts in | Renames / defaults / skip | Flatten | Enums / tagged unions | Validation | Speed / zero-copy |
|---|---|---|---|---|---|---|
| Rust serde | `#[derive(Serialize, Deserialize)]` against a format-neutral **data model**: 29 types, `Serializer`/`Deserializer` traits, `Visitor` for decode | `rename`, `rename_all`, `alias`, `default` / `default = "fn"`, `skip`, `skip_serializing_if`, `with` | `flatten` (slow path: buffers into a map **[k]**) | External (default), internal `tag`, adjacent `tag` + `content`, `untagged` (tries in order) | None built in (`validator` crate **[k]**) | Fast (monomorphized); `#[serde(borrow)]` gives `&str` borrowed from input |
| Go encoding/json (v1, v2 exp. in 1.25) | Reflection plus struct tags `json:"name,omitempty"` | Tag name, `omitempty`; v2 adds `omitzero` (uses `IsZero()`), `string`, `inline` | v2 `inline` (struct embedding) | None: interfaces plus custom `UnmarshalJSON` **[k]** | None | Reflection is slow in v1 **[k]**. v2 is behind `GOEXPERIMENT=jsonv2` and is faster and stricter **[k]**: case-sensitive and rejects duplicates |
| Kotlin serialization | `@Serializable` (compiler plugin generates a serializer) | `@SerialName`; default values from constructor defaults; `@Transient`; `explicitNulls` | No (custom serializer) **[k]** | Sealed classes → polymorphic with a `type` discriminator (configurable `classDiscriminator`) **[k]** | Via `init` blocks **[k]** | No reflection; multiplatform; formats JSON, protobuf, CBOR **[k]** |
| Swift Codable | Conformance synthesized by the compiler; `CodingKeys` enum for keys | Renames by `CodingKeys` raw values. **Defaults are a known gap**: a declared default is ignored on decode, so missing keys mean a hand-written `init(from:)` or macro packages (CodableDefault, CodableKit) | No **[k]** | Enums with associated values synthesized since 5.5 in one fixed shape **[k]** | Hand-written | Existential containers make it slower than serde **[k]** |
| C# System.Text.Json | Runtime reflection, or a **source-generated** `JsonSerializerContext` with `[JsonSerializable(typeof(T))]` | `[JsonPropertyName]`, `[JsonIgnore(Condition=…)]`, naming policies | `[JsonExtensionData]` for unknowns **[k]** | `[JsonPolymorphic]` + `[JsonDerivedType(typeof(D), "d")]` discriminator (.NET 7+) **[k]** | DataAnnotations, separate **[k]** | Source generation is required for trimming/Native AOT. Users dislike having to register every root type; C# 14 interceptors are proposed to make it automatic |
| Pydantic v2 | Python class with type hints; core in Rust (pydantic-core) | `Field(alias=…, default=…)` | No (nesting) **[k]** | Discriminated unions `Field(discriminator="kind")` **[k]** | **Central**: types, constraints, validators, strict mode | 4–50x faster than v1; parses JSON straight into the model; JSON Schema from the model |
| Zod (TS) | Schema value first; `z.infer<typeof S>` gives the type | `.default()`, `.optional()`, transforms **[k]** | `.merge`/`.extend` **[k]** | `z.discriminatedUnion("kind", […])` **[k]** | Central: `.parse` throws, `.safeParse` returns a result **[k]** | Runtime only. Schema-first inverts the usual "type first" **[k]** |
| Protobuf (prost, protoc-gen-*) | `.proto` IDL → codegen | Field numbers, not names, are the contract; `reserved` | n/a | `oneof`; **open enums** keep unknown values (prost) | proto-validate / buf **[k]** | Parse step builds objects. Cap'n Proto/FlatBuffers read in place (FlatBuffers zero-alloc in a 2019 benchmark); rkyv validates once, then reads unchecked |

### What to learn

1. **A format-neutral data model is serde's key idea.** Each type derives once, then every format crate (JSON, TOML, YAML, bincode, CBOR) works. Without it, every format needs its own derive and its own attributes. Eider will want JSON (P0.10), TOML config (P0.13), protobuf (#32), SQL rows (#36), CLI args and env, and OpenAPI schemas (eider-openapi#1). That is at least five consumers of the same field metadata.
2. **Keep the attribute vocabulary small and format-neutral, with per-format overrides.** Kotlin's `@SerialName` and serde's `rename` apply to every format. Go's per-format tags (`json:` `yaml:` `db:`) multiply.
3. **Defaults must be first-class.** Swift's gap is its most-cited Codable complaint. Eider already derives `Default` (C8.23), so `@data(default)` can use `T.default()`, and `@data(default = expr)` can use a comptime-checked constant.
4. **Tagged unions need a chosen default, with a few options.** Users hit serde's `untagged` performance and ambiguity traps **[k]**. Kotlin, C# and Pydantic all converged on an internal **discriminator field** (`"type": "…"`), which also maps directly to OpenAPI's `discriminator`. Eider's payload enums should default to it.
5. **Flatten is popular but costly.** serde's `flatten` buffers. Go v2 `inline` works because embedding is structural. Eider should offer it only for records, resolved at comptime into one field list, so there is no buffering.
6. **Secure decoding needs defaults.** Set limits on depth, total size, string length and collection length. Reject duplicate keys (Go v2 made that the default **[k]**). Treat unknown fields with an explicit policy. The current package has a nesting limit of 512 (eider-json#1).
7. **Versioning favours numbered or named fields plus tolerant readers.** Protobuf ignores unknown fields and keeps unknown enum values, and forward compatibility comes from that. JSON APIs usually ignore unknown fields too, while request validation (OpenAPI) wants to reject them. So the policy belongs per type, not per format.
8. **Zero-copy is two different things.**
   - Borrowing strings from the input buffer (serde `borrow`). This maps to Eider COW substrings and views (#16) and is worth having.
   - Formats readable in place (FlatBuffers, Cap'n Proto, rkyv). These are niche and belong to a library, not the language.
9. **Parse, don't validate.** Pydantic and Zod are loved because decoding *is* validation, and the result type proves it. Eider decoders should return `Result[T, DecodeError]` with a path (`$.items[3].qty`).

---

## 3. Database access

### Comparison

| Tool | Style | Type-checking of queries | Migrations | Relations / N+1 | Users love / hate |
|---|---|---|---|---|---|
| Diesel (Rust) | Query builder over a generated `schema.rs` | Compile time via Rust types; complex generic errors **[k]** | Built in (`diesel migration`, `embed_migrations!`) | Explicit joins / `belonging_to` **[k]** | Love: safety. Hate: error messages, async story, a DSL to learn **[k]** |
| sqlx (Rust) | Raw SQL with `query!` macros | **Connects to a dev database at compile time** to check SQL and infer types; offline mode uses cached `.sqlx` metadata | Built in (`sqlx migrate`) **[k]** | Hand-written SQL | Love: real SQL. Hate: a DB needed to build, dynamic SQL (IN lists, batches) unchecked, macro build cost |
| sqlc (Go, plugins for Kotlin/Python/TS) | Write `.sql` schema + queries, generate typed functions | Generation time, by **parsing the schema DDL** (Postgres parser), no live DB; a changed column type breaks the build | Reads migration files from common tools **[k]** | Hand-written; `sqlc.embed` for joins **[k]** | Love: plain SQL, fast, no runtime magic. Hate: dynamic queries, codegen step, MySQL support experimental |
| jOOQ (JVM) | Typed SQL DSL over classes generated from the live schema | Java compiler checks syntax, columns, types | External (Flyway/Liquibase); schema-first | Explicit joins, `MULTISET` nesting **[k]** | Love: full SQL power, dialect translation. Hate: commercial licence for some DBs **[k]** |
| SeaORM (Rust) | Async ActiveRecord-ish ORM on sea-query **[k]** | Partly typed | sea-orm-cli **[k]** | Loader APIs **[k]** | Easier than Diesel; more runtime **[k]** |
| Ecto (Elixir) | Repo pattern + query DSL + **changesets** (cast / validate / constrain) | Macro-time checks on fields **[k]** | Built in | **Explicit `preload`**, no lazy loading at all; batched per association | Widely loved: explicit, no hidden queries, changesets unify validation **[k]** |
| Prisma (TS) | Schema file → generated client | Generated types | `prisma migrate` from schema diff **[k]** | Nested `include`; since 5.8 `relationLoadStrategy` (`join` via lateral JSON vs `query`) | Love: DX. Hate: query engine was a Rust binary (removed in v6/7 **[k]**), less SQL control |
| Drizzle (TS) | SQL-like builder, schema in TS | Type inference | drizzle-kit **[k]** | Relational queries API, one SQL statement **[k]** | "If you know SQL you know Drizzle" **[k]** |
| GORM (Go) | Reflection ORM with struct tags | Runtime only | `AutoMigrate` **[k]** | `Preload`; lazy pitfalls **[k]** | Hate: silent zero-value updates, magic, runtime errors **[k]** |
| Exposed (Kotlin) | DSL plus DAO layers **[k]** | Typed DSL | Basic **[k]** | DAO lazy refs **[k]** | Two APIs in one library is confusing **[k]** |
| SQLAlchemy 2 | Core (SQL expression) + ORM; 2.0 unified `select()` and typed `Mapped[]` **[k]** | Type hints | Alembic **[k]** | Explicit loader strategies (`selectinload`), `raise` to forbid lazy **[k]** | Love: power. Hate: learning curve, session state **[k]** |
| Hibernate / JPA | Full ORM with identity map, dirty checking, lazy proxies | Runtime / JPQL strings | Flyway etc. | **N+1 is the classic failure.** Lazy `@OneToMany` defaults vs EAGER `@ManyToOne` defaults; `LazyInitializationException` on detached objects; fixes are join fetch, `@BatchSize`, entity graphs | The "object-relational impedance mismatch" debate (Ted Neward's "Vietnam of computer science" essay **[k]**) |

### What to learn

1. **Hidden queries are hidden control flow.** Lazy loading, dirty checking and identity maps cause N+1 and detached-object errors, and they conflict with Eider's "no hidden control flow" and value semantics. Eider records are values, not live proxies, so an ActiveRecord or Hibernate ORM doesn't fit. Ecto shows that explicit preloads and changesets satisfy users.
2. **Checked plain SQL is the best ratio of safety to complexity.**
   - sqlc's model fits Eider best: schema DDL plus queries go in, typed functions come out, no live DB, and the check is deterministic and hermetic. Eider's comptime runs with **no capabilities**, so sqlx's "connect at compile time" is out by construction, which is good.
   - The sqlc approach needs comptime (or a tool) to read the package's own `.sql` files: a hermetic, declared input, not a capability.
3. **Dynamic queries need an escape hatch.** sqlc and sqlx both struggle with optional filters, IN lists and batch inserts. A small typed query builder for those cases, or array parameters (`= ANY($1)` in Postgres), covers most of them.
4. **Migrations:**
   - Use forward-only, numbered SQL files with checksums recorded in a table and a lock (advisory lock in Postgres), embedded in the binary (Diesel `embed_migrations!`, sqlx) and run explicitly at start-up.
   - The schema the checker uses must be *derived from the same migration files*. sqlc does this, and it prevents schema drift.
5. **Pools and transactions:**
   - A pool with a max size, acquire timeout, health check and max lifetime **[k]**.
   - Transactions as a scoped call, `db.transaction(|tx| …) -> Result`: commit on `Ok`, roll back on `Err` or trap. This is explicit and fits `Result` and `?` with no hidden control flow. A `tx` value that must be consumed is the alternative, and Eider has no linear types, so the closure form is simpler.
6. **Row mapping is just decoding.** Row → record should use the same data-model derive as JSON (sqlx `FromRow`, sqlc generated structs).
7. **The "ORM vs SQL" debate has a mainstream answer in 2026:** typed SQL or SQL-shaped builders (sqlc, sqlx, jOOQ, Drizzle, Kysely **[k]**), with explicit relation loading. Full ORMs remain popular for CRUD speed (Prisma, Django **[k]**) but draw the performance complaints.

---

## 4. Validation and schema derivation

| System | Source of truth | Output | Notes |
|---|---|---|---|
| FastAPI + Pydantic | Python types + `Field` constraints | OpenAPI 3.1 (JSON Schema 2020-12) at `/openapi.json`, request validation from the same types | The model case of "types in, schema and validation out" |
| utoipa (Rust) | `#[derive(ToSchema)]`, `#[utoipa::path]` | OpenAPI 3.1 | Only partial understanding of serde attributes, so attributes are duplicated and drift (docs/research/rust.md) |
| aide + schemars (Rust) | `JsonSchema` derive; extractor traits document themselves | OpenAPI 3.1 | Moved away from macros toward functions and builders (rust.md) |
| C# / ASP.NET | Types + DataAnnotations | OpenAPI via `Microsoft.AspNetCore.OpenApi` **[k]** | Built in since .NET 9 **[k]** |
| Zod | Schema value | Type + validation; JSON Schema via zod-to-json-schema / v4 native **[k]** | Schema first |
| Protobuf + protovalidate | `.proto` with constraint options **[k]** | Validators in each language | Constraints live with the contract |

**Lessons.**
- One source of truth: the encoder, decoder, validator and schema must read the *same* attributes, or they drift (utoipa vs serde).
- Constraint attributes (`min`, `max`, `len`, `pattern`, `format`) should be checked at decode time *and* emitted as JSON Schema keywords.
- Schemas for enums should use the same discriminator the codec uses.

---

## Recommendation for Eider

### 1. Metaprogramming: comptime reflection plus declared attributes plus reflective trait defaults; no macro system

- **Attributes (#19) are inert data with a declared shape.** A package declares the attributes it owns, for example `attr json { name: str, skip: bool, default: bool }` in eider-json. Then `@json(name = "user_id")` is type-checked against that declaration, and unknown attributes or keys are errors with spans. This fixes Go's typo problem and gives the analyzer completion for attribute keys. Attributes never run code by themselves.
- **Comptime reflection (#20) is typed and read-only**, on the IR interpreter (#7). Planned API:
  - `comptime fields(T)` returns a List of `Field { name: str, index: usize, attrs: … }`;
  - `variants(T)`;
  - `attr[json](f)` returns `Option[json]`;
  - `comptime for f in fields(T) { … }` unrolls in a generic function;
  - `@field(x, f)` gives typed field access.

  Code is *specialized* (monomorphized), never *emitted as text*. There is no `#insert`, string mixin or token stream, so generated code needs no hygiene rules, and the analyzer only needs to understand comptime loops, not arbitrary expansions.
- **Library "derive" is a reflective default implementation.** For example, a trait `Encode` in std has a default body written with `comptime for` over `fields(Self)`. Every record whose fields are `Encode` gets it automatically, exactly like the C8.4 operation traits, and the type's own package can override it. This needs default methods in traits (#45). There is no `#[derive]` list and no separate macro crate. Cost model: it's just generic instantiation, so it shares the monomorphization cache and costs no extra process (unlike Rust and Swift).
- **No syntax macros for now.** Revisit only with a concrete case comptime can't express (e.g. embedded DSLs). If one comes, prefer Nim-style hygienic templates over AST macros.
- **Hermetic comptime inputs.** `comptime embed("queries.sql")` reads a file inside the package, recorded as a build input for the cache. It isn't a capability: it's read-only, confined to the package and deterministic. This enables checked SQL, embedded migrations, templates and test fixtures without `go generate`.
- **Visibility.** `eiderc expand T.encode` (or an analyzer "show specialization" action) prints the specialized body. That gives what Swift's and C#'s expansion views give users.

How this fits Eider's rules:
- **No hidden control flow:** derived code is ordinary calls that return `Result`.
- **Capabilities:** comptime has none, and derived code needs none unless the trait method declares `uses`.
- **Compile speed:** no extra processes. Needs #7 so a comptime evaluation doesn't cost a C compile.
- **LSP:** attributes are typed, and reflection results are ordinary values.

### 2. Serialization: a serde-like data model, smaller, with one attribute vocabulary

- **std/data**: `Encode` / `Decode` traits over `Encoder` / `Decoder` traits. The kinds are:
  - bool, the int widths, f64 (after #43), str, bytes;
  - option, seq, map;
  - record (named fields), variant (tag + payload), unit.

  That's about 12 kinds, not serde's 29. Decode is a streaming pull: `next_key`, `read_i64` and so on. That is simpler than serde's Visitor inversion and enough for JSON, TOML, protobuf and SQL rows.
- **One format-neutral attribute, `@data(…)`, with per-format overrides like `@json(name = …)`.** Keys:
  - `name`, `rename_all = "snake_case"`;
  - `default` (uses `Default`) or `default = CONST`;
  - `skip`, `omit_if = "zero"`, `flatten` (records only, resolved at comptime);
  - for enums, `tag = "type"` (default internal discriminator), `content = "value"` (adjacent), `untagged` (opt-in, warned);
  - `unknown = "ignore" | "deny"` per type.
- **Secure defaults** in every decoder: depth/size/string/collection limits, duplicate keys rejected, errors with a JSON path, no panics on hostile input (fuzzed by eider-fuzz).
- **Zero-copy:** decoded `str` fields can be COW views into the input buffer when the input outlives the value (#16). In-place binary formats go to a library if ever needed.
- **Validation:** `@check(min = 1, max = 100, len = 1..64, pattern = "…", format = "email")`. It is applied in `Decode` and emitted by `Schema`, so decoding is validation (Pydantic and Zod model). Refinement newtypes (`type Email = str @check(format = "email")`) belong to track 2.

### 3. Database: sqlc-style checked SQL in an eider-sql library, no ORM

- **eider-sql** (new repo) on the Postgres client (#36):
  - Schema = the package's migration files. Queries are `.sql` files with sqlc-style annotations (`-- name: GetUser :one`).
  - At comptime, `embed` reads both, a pure-Eider Postgres DDL/DML parser builds the schema, and each query is checked: columns exist, parameter and result types are inferred, nullability is tracked (`Option[T]` for nullable columns).
  - It generates typed functions `get_user(db, id: i64) -> Result[Option[User], SqlError] uses net`. The result records use the data model (`Decode`), so a row and a JSON body share one mapping.
- **No live DB at build time** (comptime has no capabilities). An optional `eider-sql verify` command (with `uses net`) checks against a real DB in CI for things the parser can't infer.
- **Dynamic queries:** array parameters (`= ANY($1)`), plus a small typed builder for optional filters and sorting. Values are always bound, and identifiers come from a whitelist checked against the schema.
- **Relations are explicit:** no lazy loading, identity map or dirty tracking. Batch-loading helpers (`load_many(ids)`) avoid N+1 the Ecto way.
- **Migrations:** numbered forward SQL, embedded, checksummed in a table, run under an advisory lock, run explicitly (`migrate.up(db)`).
- **Pool:** `Pool` with max size, acquire timeout, idle and lifetime limits, and health check, safe across tasks (#14).
- **Transactions:** `db.transaction(|tx| … ) -> Result`, which commits on Ok and rolls back on Err or trap (#54). Isolation level is a parameter. Retries on serialization failure are explicit, through a `retry` helper.

### 4. Schema: `Schema` derive from the same reflection

- eider-openapi#1 should derive JSON Schema 2020-12 / OpenAPI 3.1 from the same `@data` and `@check` attributes. Enums use the same discriminator as `Decode` (OpenAPI `discriminator` + `oneOf`).
- eider-rpc#1 uses it for method signatures.
- No duplicate attribute sets anywhere.

### Avoid

- Token/AST proc macros and separate macro executables (Rust and Swift build-time cost).
- String mixins and `#insert` (opaque to tools).
- Unchecked string tags (Go).
- Runtime reflection as the main mechanism (slow; blocks dead-code elimination; no WASM/AOT story).
- Compile-time database connections (sqlx).
- Lazy-loading ORMs (Hibernate N+1).
- `go generate`-style committed outputs as the main path. This one is still fine as a fallback for eider-openapi's spec → code (eider-openapi#2), where the input is external.

---

## Ranked proposed features

| # | Feature | Impact | Effort | Depends on | Repo |
|---|---|---|---|---|---|
| 1 | Typed, declared attributes | H | M | #19 (this refines it) | eider-lang |
| 2 | Typed comptime reflection on the IR interpreter | H | H | #7, #20, 1 | eider-lang |
| 3 | Reflective default implementations ("derive without macros") | H | M | #45, 2 | eider-lang |
| 4 | std data model: `Encode`/`Decode` over `Encoder`/`Decoder` | H | M | 3, #43, #16 | eider-lang (std) |
| 5 | JSON on the data model with secure defaults | H | M | eider-json#1, 4 | eider-json |
| 6 | Validation attributes and `Schema` derive (JSON Schema / OpenAPI) | H | M | eider-openapi#1, eider-rpc#1, 4 | eider-openapi (+ `@check` in std) |
| 7 | Hermetic comptime file embedding | M | L | #7 | eider-lang |
| 8 | eider-sql: checked SQL from migrations, sqlc-style | H | H | #36, 2, 4, 7 | new repo eider-sql |
| 9 | Migrations, pool and transactions | H | M | #36, #14, #54, #22 | eider-sql (pool may sit in the Postgres client) |
| 10 | Seeing generated code: `eiderc expand` and analyzer support | M | L | #9, 2 | eider-lang + eider-analyzer |
| 11 | Zero-copy decode views | M | M | #16, 4 | eider-lang (std) + eider-json |
| 12 | Typed query builder for dynamic SQL (not an ORM) | L | M | 8 | eider-sql |

1. **Typed, declared attributes.** Extend #19 so every attribute is declared by the package that owns it (`attr json { name: str = "", skip: bool = false }`).
   - Attribute arguments are type-checked comptime constants, and unknown attributes or keys are errors with spans and fix-its.
   - The analyzer completes attribute keys.
   - Attributes are inert data that only comptime reflection reads.

   This avoids Go's silently ignored tag typos, and it gives the attribute vocabulary of features 4–6 one checked home.
2. **Typed comptime reflection on the IR interpreter.** `fields(T)`, `variants(T)`, `attr[A](f)`, `comptime for`, typed field access by reflected field, and `comptime` type parameters in generic functions.
   - Read-only: it inspects types but doesn't construct new ones (Zig's `@Struct` can come later if needed).
   - Code is specialized, never emitted as text, so there are no hygiene problems and nothing opaque to the LSP.
   - Running on the IR interpreter (#7) is required, or each instantiation would cost a C compile.
3. **Reflective default implementations ("derive without macros").** A trait's default method body may use comptime reflection over `Self`. Types whose parts implement the trait get it automatically, the way C8.4 operation traits are derived today, and the owning package can override it.
   - This replaces `#[derive(…)]` lists and proc-macro crates with ordinary generic code.
   - Only types that implement the trait get the method, and only when they use it, so compile-time cost follows use.
   - A compile-time error explains which field doesn't implement the trait.
4. **std data model: `Encode`/`Decode` over `Encoder`/`Decoder`.** About 12 kinds, a pull-style decoder, and decode errors with paths.
   - Uses the format-neutral `@data(name, rename_all, default, skip, omit_if, flatten, tag, content, untagged, unknown)` attribute.
   - Payload enums default to an internal `"type"` discriminator.
   - JSON, TOML config (#24), protobuf (#32), SQL rows and CLI/env decoding then share one mapping and one attribute vocabulary, as with serde, but without macros.
5. **JSON on the data model with secure defaults.** eider-json#1 implements `Encoder`/`Decoder`.
   - It streams, enforces depth/size/string/collection limits by default, rejects duplicate keys, and returns errors with a JSON path.
   - Per-type unknown-field policy; `@json(…)` overrides on top of `@data`.
   - Fuzzed. This is P0.10.
6. **Validation attributes and `Schema` derive (JSON Schema / OpenAPI).**
   - `@check(min, max, len, pattern, format, one_of)` is enforced inside `Decode`.
   - A `Schema` trait, derived the same way, emits JSON Schema 2020-12 / OpenAPI 3.1 components, with discriminators that match the codec.
   - One source of truth for codec, validation and docs (FastAPI's model, without utoipa's attribute drift).
   - Feeds eider-rpc#1 and request validation in eider-http#1.
7. **Hermetic comptime file embedding.** `comptime embed("path")` returns the bytes or `str` of a file inside the declaring package. Paths can't escape the package, the file is recorded as a cache input, and it needs no capability.
   - It enables checked SQL, embedded migrations, templates and golden test data, without `go generate` or committed outputs.
   - It's the Zig `@embedFile` / Rust `include_str!` equivalent, and keeps comptime deterministic.
8. **eider-sql: checked SQL from migrations, sqlc-style.**
   - Queries live in `.sql` files with `-- name: X :one|:many|:exec`.
   - At comptime, eider-sql parses the migration DDL and the queries (Postgres dialect first), checks columns and types, infers parameter and result types (nullable → `Option`), and generates typed functions that `uses net` and return records decoded through feature 4.
   - No database at build time (comptime has no capabilities); an optional `eider-sql verify` runs against a live DB in CI.
   - Gives safety without an ORM or a DSL to learn.
9. **Migrations, pool and transactions.**
   - Migrations are forward-only numbered SQL, embedded (7), checksummed and run under an advisory lock by an explicit `migrate.up(db)`.
   - `Pool` has bounded size, acquire timeout, lifetime and idle limits, and health checks, and is safe across tasks.
   - `db.transaction(|tx| …) -> Result` commits on Ok and rolls back on Err or trap; isolation is a parameter, and retry is an explicit helper.
   - No lazy loading, no identity map. `load_many` helpers prevent N+1.
10. **Seeing generated code: `eiderc expand` and analyzer support.**
    - `eiderc expand <fn or type.method>` prints the specialized body of a reflective implementation.
    - The analyzer offers the same view as a hover or "show specialization" action, and puts go-to-definition from a derived method to the trait's reflective body.
    - Errors inside a specialization name the type and field that triggered them (instantiation backtraces, which Zig users miss **[k]**).
    - Cheap, and it removes most of the opacity that people hold against macros.
11. **Zero-copy decode views.** Let `Decode` return `str` fields that share the input buffer copy-on-write, so decoding a large request body doesn't copy every string. Builds on #16's views and the COW buffers in C8.1. In-place binary formats (FlatBuffers-style) stay out of std.
12. **Typed query builder for dynamic SQL (not an ORM).**
    - Covers what static queries can't: optional WHERE clauses, sort columns from a whitelist checked against the schema, and batch inserts.
    - Values are always bound parameters, so there's no string concatenation.
    - Deliberately small, with Drizzle and Kysely as the models. No relations or entity state.

**Not proposed:** a token or AST macro system, an ActiveRecord/Hibernate-style ORM, runtime reflection, and compile-time DB connections. Each conflicts with simplicity, explicit control flow, capability-free comptime or compile speed (see "Avoid").

**Suggested issue mapping** (for review before filing, per #97):
- 1 → comment on/extend #19;
- 2 → extend #20;
- 3 → new eider-lang issue, depends on #45 and #20;
- 4 → new eider-lang issue (std/data);
- 5 → eider-json#1 (update dependencies to 4);
- 6 → eider-openapi#1 plus a std `@check` sub-issue;
- 7 → new eider-lang issue;
- 8, 9, 12 → new repo eider-sql (refines #36's "typed queries from records");
- 10 → new issue under #9;
- 11 → extend #16.

---

## Sources

Metaprogramming
- https://nnethercote.github.io/2025/06/26/how-much-code-does-that-proc-macro-generate.html
- https://forum.polkadot.network/t/i-reduced-polkadot-sdk-incremental-compile-times-by-35/6900
- https://forums.swift.org/t/swift-macros-build-time-overhead-concerns/70443
- https://forums.swift.org/t/macros-and-xcframeworks/68122
- https://mjtsai.com/blog/2024/02/27/slow-swift-macro-compilation
- https://tuist.dev/blog/2024/08/26/swift-macros
- https://scala-lang.org/api/docs/metaprogramming/macros.html
- https://softwaremill.com/scala-3-macros-tips-and-tricks/
- https://virtuslab.com/blog/scala/metaprogramming-in-scala-2-3/
- https://hexdocs.pm/elixir/macros.html
- https://hookrace.net/blog/introduction-to-metaprogramming-in-nim
- https://www.digitalmars.com/d/archives/digitalmars/D/Nim_Nuggets_Nim_talk_at_Strange_Loop_2021_353806.html
- https://developer.android.com/build/migrate-to-ksp
- https://github.com/google/ksp/blob/main/docs/why-ksp.md
- https://slack-chats.kotlinlang.org/t/18770791/how-does-kotlinx-serialization-v-1-6-3-work-with-the-new-k2-
- https://www.thinktecture.com/net/roslyn-source-generators-performance/
- https://www.devleader.ca/2026/03/26/incremental-source-generators-in-c-the-right-way-to-build-them
- https://github.com/BSVino/JaiPrimer/wiki/Metaprogramming
- https://github-wiki-see.page/m/Jai-Community/Jai-Community-Library/wiki/Metaprogramming
- docs/research/zig.md (comptime, @typeInfo, std.json) and docs/research/rust.md (serde, utoipa, aide) in this repository

Serialization
- https://serde.rs/data-model.html
- https://serde.rs/attributes.html, https://serde.rs/field-attrs.html, https://serde.rs/enum-representations.html
- https://pkg.go.dev/encoding/json/v2
- https://forums.swift.org/t/revisit-synthesized-init-from-decoder-for-structs-with-default-property-values/12296
- https://www.swiftbysundell.com/posts/customizing-codable-types-in-swift
- https://github.com/tomisacat/CodableDefault
- https://github.com/Zechiax/Modrinth.Net/issues/134
- https://startdebugging.net/de/2026/02/csharp-14-interceptors-system-text-json-source-generation-ergonomics/
- https://learn.microsoft.com/en-us/dotnet/standard/serialization/system-text-json/source-generation (official docs; not fetched)
- https://docs.pydantic.dev/2.0/blog/pydantic-v2/
- https://pydantic.dev/articles/pydantic-v2
- https://zod.dev (not fetched)
- https://kotlinlang.org/docs/serialization.html (not fetched)
- https://openmymind.net/Custom-String-Formatting-And-JSON-in-Zig
- https://ziggit.dev/t/how-to-parse-stringify-json-value-with-custom-tag-like-golang/12787
- https://cloudstreet-dev.github.io/Binary-Serialization-Survey/ch15-rkyv.html
- https://git.speice.io/mirror-github-bspeice/speice.io/src/branch/master/blog/2019-09-28-binary-format-shootout/_article.md

Database
- https://github.com/sqlc-dev/sqlc and https://pkg.go.dev/github.com/sqlc-dev/sqlc
- https://github.com/launchbadge/sqlx (not fetched; behaviour per search results)
- https://users.rust-lang.org/t/which-one-to-use-postgres-vs-sqlx/63680
- https://docs.diesel.rs/main/diesel_migrations/index.html
- https://www.jooq.org/
- https://www.petrikainulainen.net/programming/jooq/using-jooq-with-spring-code-generation/
- https://www.prisma.io/blog/prisma-orm-now-lets-you-choose-the-best-join-strategy-preview
- https://github.com/prisma/prisma/releases/tag/5.8.0
- https://elixirforum.com/t/advantages-of-ecto-preloads-with-without-joins/21751/1
- https://hexdocs.pm/ecto/Ecto.Changeset.html (not fetched)
- https://weblogs.asp.net/ricardoperes/nhibernate-pitfalls-select-n-1
- https://medium.com/free-code-camp/hibernate-deep-dive-relations-lazy-loading-n-1-problem-common-mistakes-aff1fa390446
- https://orm.drizzle.team/docs/rqb, https://gorm.io/docs/, https://docs.sqlalchemy.org/en/20/orm/queryguide/relationships.html, https://github.com/JetBrains/Exposed, https://www.sea-ql.org/SeaORM/ (official docs; not fetched)
- https://blog.codinghorror.com/object-relational-mapping-is-the-vietnam-of-computer-science/ (Neward's essay as discussed by Atwood; not fetched)

Schema
- https://scalar.com/blog/posts/2026-10-08-openapi-with-fastapi
- https://fastapi.tiangolo.com/features/
- https://docs.rs/utoipa, https://docs.rs/aide, https://docs.rs/schemars (via docs/research/rust.md)
- https://json-schema.org/draft/2020-12 and https://spec.openapis.org/oas/v3.1.0 (specifications; not fetched)
