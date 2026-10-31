# Eider roadmap: services, RPC and OpenAPI

Draft, 2026-10-30. Shared doc for iterating: https://claude.ai/artifact/U4zrMr137oc4USojKdLgHi (this file is the copy agents work from; keep them in sync).

To build real RPC and OpenAPI services, Eider needs networking, a concurrency model for many connections, HTTP, JSON with derive, interfaces, and TLS, in that order; everything else follows.

## What Rust, Zig and Go teach

Each language is strongest in a different place; Eider can take the best of each without their main costs. (From knowledge of the languages as of 2026; no sources were fetched for this draft.)

| Area | Go | Rust | Zig | Eider takes |
| --- | --- | --- | --- | --- |
| Concurrency for services | Goroutines (M:N green threads) and channels; blocking code everywhere, the runtime multiplexes | `async`/`await` state machines on Tokio: fast, but "function colouring" splits every library in two | Explicit `Io` interface (event loop or threads chosen by the caller) | Go's feel (write blocking code) with compiled, stackless tasks, so no GC and no colouring |
| HTTP and RPC | `net/http` in std; gRPC via protobuf codegen | axum/hyper, tonic for gRPC; all third-party | Small std HTTP; little ecosystem | HTTP in std, RPC and OpenAPI as packages generated from types |
| Serialization | Reflection plus struct tags (`json:"name"`), slow but easy | `serde` derive macros: fast and flexible, macro-heavy | `comptime` reflection (`@typeInfo`) writes serializers with no macros | Derived traits like 8.4, driven by comptime reflection and field attributes |
| Interfaces | Structural interfaces, dynamic dispatch | Traits; `dyn Trait` for dynamic | `anytype` and vtables by hand | Traits plus `dyn Trait` for handlers and plugins |
| Errors | `error` values, `if err != nil`; wrapping with `%w` | `Result` + `?` with `From` conversions | Error unions, `try`, `errdefer` | `Result` + `?` (have), conversions, context, `defer`/`errdefer` |
| Cleanup | `defer` | `Drop` | `defer`, `errdefer` | `Drop` (8.4) plus `defer`/`errdefer` |
| Safety | Memory-safe by GC; data races possible (race detector) | Memory-safe and race-free by the borrow checker | Not memory-safe; safety checks in debug builds | Rust's guarantees by the simpler memory model (8.6) |
| Tooling | `gofmt`, `go test` (tests, benchmarks, fuzzing), race detector, pprof | cargo, clippy, rustfmt, doc tests | `zig build`, cross-compilation built in | Formatter, test/bench/fuzz in the driver, profiling, cross-compilation through C |
| Supply chain | Module checksums and a checksum database (sumdb) | crates.io, `cargo audit` | Package hashes | Lockfile hashes and capability grants (have); a registry with a checksum log |
| Build and deploy | One static binary, fast compiles | One binary, slow compiles | One binary, fast compiles, any target | One binary from C; cross-compile with a target C compiler |

## The four big choices

### 1. Concurrency: capability-driven tasks (recommended)

Services need tens of thousands of connections. Threads per connection don't scale; Rust-style `async` splits the language in two. Eider has an advantage no other language has: **capabilities already mark which functions can block** (`uses net`, `io`, `fs`, `clock`).

- `spawn` starts a lightweight task, not an OS thread. Tasks run on a small pool of OS threads over an event loop (epoll on Linux, kqueue on macOS/BSD) in the C core.
- The compiler turns every function that `uses` a blocking capability into a resumable state machine (stackless, like Rust's `async` lowering) automatically. Code is written as ordinary blocking code, as in Go; there is no `async`/`await` and no colouring, because the capability is already in the signature.
- Pure functions stay plain C functions: zero overhead where nothing can block.
- Structured concurrency: tasks live in a scope (a task group); the scope waits for them, cancellation and deadlines flow down (Go's `context`, built in), and a failed task cancels its siblings.
- `select` over channels and timers.

Alternative: stackful green threads (Go's model) need per-task stacks and stack switching in assembly per architecture, which is unmanaged code and stack-size tuning; recommended against.

### 2. Serialization: derive from types

`Json` (and later `Proto`) become derived traits, like the operation traits in 8.4: a record or enum is serializable when its parts are, with no code. Field attributes rename or skip fields (`@json(name = "user_id")`). This needs two language features: **attributes** on items and fields, and **comptime reflection** over types (Zig's `@typeInfo`), so libraries, not the compiler, write the serializers. The same reflection generates OpenAPI schemas from handler types.

### 3. Interfaces: `dyn Trait`

Routers, middleware and plugin points need values of "any type implementing `Handler`". Static generics stay the default; `dyn Trait` adds a boxed value plus a vtable for these cases, with the operation traits working through it.

### 4. TLS: in Eider, in phases

Linking OpenSSL would add a large third-party C dependency, against the core rules. Plan: services run behind a TLS-terminating proxy at first (P0); then TLS 1.3 written in Eider (P1): X25519, Ed25519/ECDSA verify, ChaCha20-Poly1305 and AES-GCM, SHA-2, HKDF, X.509 parsing, with constant-time arithmetic checked by tests. Crypto primitives are the one place where a small, audited C or assembly core module for speed may be justified later; that needs a recorded decision.

## P0: a first JSON/HTTP service

Goal of P0: a JSON-over-HTTP service written in Eider that handles thousands of concurrent connections behind a TLS proxy, with clean shutdown, logs and config. In order of dependency:

| # | Feature | What it is | Layer | Depends on |
| --- | --- | --- | --- | --- |
| P0.1 | Sockets and an event loop in core | TCP listen/accept/connect/read/write, non-blocking, epoll/kqueue readiness, DNS lookup, socket options, timeouts; OS calls only, per core/ABI.md | core (C) + std/net | — |
| P0.2 | Lightweight tasks | `spawn` on a task scheduler; compiler-generated resumable functions for anything that `uses` a blocking capability; task groups, cancellation, deadlines; `select` | compiler + core | P0.1, 8.6 |
| P0.3 | `defer` / `errdefer` | Run at scope exit / on the error path, in reverse order | compiler | — |
| P0.4 | Readers and writers | `Read`/`Write` traits, buffered I/O, a growable byte buffer, zero-copy views (with 8.6 references) | std | 8.4, 8.6 |
| P0.5 | String formatting | `"{name} has {n} items"` interpolation through `Show`; width/precision; `format` into a buffer | compiler + std | 8.4 |
| P0.6 | Errors with context | `From` conversions for `?`, an `Error` trait, wrapping with context, error values that print a chain | std + compiler | 8.4 |
| P0.7 | `dyn Trait` | Dynamic dispatch through a vtable, for handlers and middleware | compiler | 8.4 |
| P0.8 | Attributes | `@name(args)` on items and fields, readable by comptime code | compiler | — |
| P0.9 | Comptime reflection | Inspect a type's fields, variants and attributes at compile time; generate code from it | compiler | 8.11, P0.8 |
| P0.10 | JSON with derive | `Json` trait derived for records and enums; renames/skips/defaults via attributes; streaming encode/decode with size limits | eider-json | P0.9 |
| P0.11 | Time | Monotonic clock and wall clock, `Duration`, `Instant`, RFC 3339 parse/format, timers | std | P0.1 |
| P0.12 | HTTP/1.1 server and client | Routing, request/response types, keep-alive, chunked bodies, header/body/time limits by default, graceful shutdown. **Started** in eider-http (then `packages/http`) on OS threads (eider-http's docs/services.md; decision C40), with JSON-RPC 2.0 (the first step of P1.1, now eider-rpc) | eider-http | P0.1–P0.7, P0.11 |
| P0.13 | Service basics | Structured logging (JSON lines), config from env/files (TOML), signals (SIGTERM drain), process exit codes | std | P0.5, P0.11 |
| P0.14 | Debugging through Eider source | Emit `#line` directives in generated C so gdb/lldb, sanitizers and crashes point at `.ei` lines | compiler | — |

Also required from the planned C8 waves: 8.6 references (no copies on the request path), 8.7 `Ref[T]` (caches, connection pools), 8.9 std on the new base, 8.13 `eiderc fmt`.

## P1: production RPC and OpenAPI services

Goal of P1: typed RPC and OpenAPI services ready for production, with TLS, observability and a supply-chain story.

| # | Feature | What it is | Depends on |
| --- | --- | --- | --- |
| P1.1 | RPC framework | A service is a trait (`trait Billing { fn charge(req: Charge) -> Result[Receipt, BillingError] uses net }`); server and client generated from it. Wire formats: JSON-RPC over HTTP first, then Connect (HTTP/1.1 + JSON or protobuf) | P0.7, P0.9, P0.10, P0.12 |
| P1.2 | OpenAPI from code | OpenAPI 3.1 document generated from routes and types (reflection), served at `/openapi.json`; request validation from the same types | P0.9, P0.12 |
| P1.3 | Code from OpenAPI | `eider-openapi` generates typed server stubs and clients from a spec | P1.2 |
| P1.4 | TLS 1.3 in Eider | Server and client; the primitives listed in "The four big choices"; constant-time tests; certificate verification | P0.1, P0.4 |
| P1.5 | Testing for services | Table tests, fixtures, test filters, benchmarks and fuzz targets per package in `eiderc test`; an HTTP test client; coverage | P0.12 |
| P1.6 | Observability | Metrics (counters, histograms; Prometheus text), tracing spans with context propagation (W3C traceparent), a sampling profiler | P0.2, P0.13 |
| P1.7 | Protobuf and gRPC | Protobuf derive (like Json), HTTP/2, gRPC server and client | P0.10, P1.4 |
| P1.8 | Supply chain | A package registry with a public checksum log (like Go's sumdb), reproducible builds, `eider-pkg audit` against advisories | 8.14 |
| P1.9 | Cross-compilation | `--target <triple>` with a target C compiler; static binaries | — |
| P1.10 | WebSockets and server-sent events | On the HTTP server | P0.12 |

## P2 and later

- Database: a PostgreSQL wire-protocol client in Eider, connection pooling, typed queries from records.
- Compression (gzip/deflate, zstd) and a regex engine (linear-time, RE2-style), both in Eider.
- Unicode utilities (normalization, segmentation) and locale-aware formatting.
- A direct debug backend (no C compiler in the edit-run loop).
- Async file I/O on io\_uring where available.
- Embedded and freestanding targets beyond wasm.

## Order with the C8 waves, and decisions needed

The C8 waves stay first because P0 builds on them; P0 items without C8 dependencies run alongside.

| When | Work |
| --- | --- |
| Now (wave 2, running) | 8.4 operation traits, 8.5 capability encapsulation |
| Wave 3 | 8.6 references, 8.7 `Ref[T]`; alongside: P0.1 sockets + event loop, P0.3 `defer`, P0.14 `#line` debugging |
| Wave 4 | 8.8 closures, 8.9 std on the new base, 8.10 parity quirks; alongside: P0.5 formatting, P0.6 errors, P0.7 `dyn Trait`, P0.8 attributes, P0.11 time |
| Wave 5 | 8.11 comptime interpreter (needed by P0.9), 8.12 performance, 8.13 tooling; P0.2 lightweight tasks, P0.4 readers/writers, P0.9 reflection |
| Wave 6 | P0.10 JSON derive, P0.12 HTTP, P0.13 service basics: **first service runs** |
| Wave 7+ | P1 in order, starting with P1.1 RPC and P1.2 OpenAPI |

Decisions needed:

- [ ] Concurrency: capability-driven stackless tasks (recommended) or stackful green threads?
- [ ] TLS: proxy first, then TLS 1.3 in Eider (recommended), or bind a system TLS library now as an exception to the core rules?
- [ ] RPC wire format first: JSON-RPC over HTTP (recommended for P1.1), Connect, or gRPC?
- [ ] Attribute syntax: `@json(name = "x")` (recommended) or another form?

## Layers and their branches

The primitives are built bottom-up in six categories. Each category has a long-lived branch;
work on it merges to main as each piece is green (the C8 rules apply: oracle diffs reviewed,
the seed regenerated by the integrator after merges, verify.sh ALL GREEN).

| Branch | Category | Contents | Starts |
|---|---|---|---|
| `layer/core-os` | Layer 0: OS interop (C core) | file descriptors, positioned I/O, sockets (TCP/UDP/Unix), DNS, epoll/kqueue event loop, monotonic and wall clocks, timers, signals, OS randomness, process pipes | now |
| `layer/core-crypto` | Layer 0: crypto | an OpenSSL-compatible libcrypto behind one glue file in `core/crypto/` (AWS-LC pinned and built with plain cc by default; OpenSSL 3, LibreSSL), narrow ABI, an Eider binding package, upstream test vectors, the recorded exception in LAYERS.md | now |
| `layer/runtime` | Layer 1: runtime | atomics for Eider, task scheduler integrated with the event loop, timer heap, cancellation tokens, stack-overflow detection (foundations on OS threads done, docs/runtime.md: atomics, deadlines, bounded channels and select, tokens, task groups, a pool, the event loop, guarded thread stacks, the main thread's too; the scheduler for stackless tasks waits for the compiler) | after core-os |
| `layer/language` | Layer 2: language | f32/f64, defer/errdefer, dyn Trait, attributes, labeled break/continue, while let, type aliases, Default/From/Into/Error, comptime reflection, select, lightweight tasks from capabilities | after C8 wave 2 |
| `layer/std` | Layer 3: std foundation | Bytes + endian codecs, Read/Write/BufRead streams, String APIs, Set/Deque/Heap/BTreeMap, time types, formatting/parsing, error chains, seeded SipHash Map, CSPRNG, RwLock/Once/bounded Chan, Path, Command, logging, config | after language and 8.6 |
| `layer/services` | Layer 4: services | net on tasks, TLS 1.3 in Eider over the crypto provider, HTTP/1.1, JSON derive, RPC, OpenAPI, metrics/tracing, Postgres | last |

Crypto decision (U12, C1, C2, C140-C146): primitives come from an OpenSSL-compatible
libcrypto, AWS-LC by default (pinned, built with plain cc, FIPS-capable), swappable at link
time for OpenSSL 3 or LibreSSL behind one glue file (core/crypto/README.md). HACL* was the
first plan and was dropped: it doesn't implement the OpenSSL API. The TLS 1.3 protocol, X.509
and everything above the primitives are written in Eider.
