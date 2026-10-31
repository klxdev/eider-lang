# Zig as a reference for Eider's services primitives (research, 2026-10-30)

**Versions.** The latest stable release is **Zig 0.17.0 (2026-10-01)**, and master is 0.18.0-dev (ziglang.org/download). The changes that matter here came in three releases:

- **0.15** brought "Writergate", the new `std.Io.Reader`/`Writer`, and removed `async`/`await` and `usingnamespace`.
- **0.16** made "I/O as an Interface" (`std.Io`), passed explicitly like an `Allocator`.
- **0.17** brought `SafeAllocator`, removed `@cImport`, and renamed `std.builtin` to `std.lang`.

Zig changes quickly before 1.0, so names below are taken from master or 0.17 source where I could check them.

**Confidence labels.** **[V]** means I checked it on an official page or source file I opened. **[K]** means it comes from long-standing background knowledge and I did not re-check it this session.

---

## 1. The language

| Feature | Zig's answer | Notes for Eider |
|---|---|---|
| comptime | Any expression or function can run at compile time. `comptime` parameters give generics. Generic types are functions that return `type`, e.g. `fn List(comptime T: type) type { return struct {...}; }` [K] | One mechanism covers generics, constants, and conditional compilation. There is no separate macro or template language ("no preprocessor, no macros") [V overview]. |
| Reflection | `@typeInfo(T)` returns a `std.lang.Type` union. In 0.16, `@Type` was replaced by per-kind constructors: `@Int`, `@Struct`, `@Union`, `@Enum`, `@Pointer`, `@Fn`, `@Tuple`, `@EnumLiteral` [V 0.16]. In 0.17, struct and union info is "struct-of-arrays": `field_names`, `field_types` [V 0.17]. `std.meta.fieldNames` and similar are deprecated in favour of `@typeInfo` [V 0.17]. | Reflection drives json, zon, fmt, and the hash-map `AutoContext`. This is the mechanism for OpenAPI and RPC codegen without a separate IDL compiler. |
| Errors | Error sets (`error{A,B}`), inferred sets (`!T`), and the global `anyerror`. Error unions are `E!T`. Propagate with `try`, handle with `catch`/`catch |e|`, use `if (x) |v| ... else |e|`, and `switch` on errors. `defer` and `errdefer` clean up. The `errdefer |e|` capture was removed in 0.17 [V 0.17]. Error return traces exist in debug and safe modes [K]. | "Errors are values, and may not be ignored" [V overview]. Error codes are plain integers with no payload, so diagnostics travel out of band (e.g. `json.Diagnostics`). |
| Optionals | `?T`, `orelse`, `.?`, `if (opt) |v|`. "Unadorned Zig pointers cannot be null" [V overview]. `?*T` has the same size as a pointer [K]. | |
| Arrays, slices, pointers | `[N]T` is an array value. `[]T` is a slice (ptr+len). `*T` points to one item. `[*]T` points to many items with unknown length. `[*c]T` is a C pointer. Sentinel-terminated forms: `[N:0]T`, `[:0]T`, `[*:0]T` (e.g. `[_:0]u8{1,2,3,4}` has type `[4:0]u8`) [V langref]. In 0.16, returning `&local` became a compile error, and explicitly aligned pointer types became distinct [V 0.16]. | Zig is not memory-safe. Use-after-free and dangling slices are only caught by allocator tooling. |
| packed/extern structs | `extern struct` uses the C ABI layout. `packed struct(uN)` is a bit-packed struct with an explicit backing integer. In 0.16, pointers were forbidden in packed types and packed unions got explicit backing integers. Inferred backing ints are banned in `extern` [V 0.16]. 0.17 added `@backingInt`/`@fromBackingInt` [V 0.17]. | Useful for wire formats and protocol headers. |
| Tagged unions | `union(enum)` with exhaustive `switch`. Payload capture covers all prongs (0.16) [V 0.16]. | The basis of sum types. |
| Allocators | `std.mem.Allocator` is a fat pointer (ptr + vtable). There is no default allocator: "functions that allocate take an Allocator parameter" [V langref]. Allocators in `std.heap` (master): `ArenaAllocator` (lock-free and thread-safe since 0.16), `SafeAllocator` (0.17; replaces the deprecated `DebugAllocator`/GPA; reports leaks, catches double free, uses canaries), `FixedBufferAllocator`, `BufferFirstAllocator` (formerly `StackFallbackAllocator`), `SmpAllocator`/`smp_allocator`, `page_allocator`, `c_allocator`, `wasm_allocator`, `brk_allocator`, `MemoryPool` [V heap.zig, 0.17]. `ThreadSafeAllocator` was removed as an "anti-pattern" [V 0.16]. | Containers are now *unmanaged*: they hold no allocator, and each call takes one [V 0.15, 0.16]. |
| Safety modes | `Debug`: safety on, unoptimized. `ReleaseSafe`: optimized, safety on. `ReleaseFast`: optimized, safety off. `ReleaseSmall`: size-optimized, safety off [V langref]. In 0.17 the `std.lang.Optimize` tags are `debug/safe/fast/small` [V 0.17]. `@setRuntimeSafety` overrides per scope [V langref TOC]. | The checks that "safe" keeps are listed in the next row. In fast and small modes, Illegal Behavior is UB. The compiler still rejects it at comptime [V langref]. |
| Safety-checked Illegal Behavior | Each of these is checked in debug and safe builds [V langref]:<br>• unreachable<br>• index out of bounds<br>• negative-to-unsigned cast<br>• truncating cast<br>• integer overflow<br>• exact shift overflow<br>• divide or remainder by zero<br>• inexact exact-division<br>• unwrap of null or error<br>• invalid error code, enum cast, or error-set cast<br>• misaligned pointer<br>• wrong union field access<br>• out-of-range float-to-int<br>• null pointer cast<br>• (0.17) `@bitCast` to an enum with an invalid tag [V 0.17]<br>Undefined memory is filled with `0xaa` in debug and safe [V]. | Use-after-free, data races, and lifetimes are *not* checked. Eider's value semantics should cover these statically. |
| `@import` | `@import("std")`, `@import("builtin")` (the build target; `cpu`/`os` fields deprecated for `target.*` in 0.17 [V]), files, and named modules from build.zig [K]. | Each file is a struct, so a module is a value. |
| Builtins of note | Casts: `@intCast`, `@truncate`, `@bitCast`, `@ptrCast`, `@as`. 0.16 changed float rounding: `@floor`, `@ceil`, `@round` and `@trunc` now convert floats straight to ints, and `@intFromFloat` is deprecated [V 0.16]. Overflow: `@addWithOverflow`/`sub`/`mul`/`shl` return a tuple `{result, u1}`. Wrapping operators `+% -% *%`, saturating `+| -| *| <<|` [V langref]. 0.17 added `@divCeil` [V]. SIMD: `@Vector(n,T)` with element-wise operators, `@splat`, `@reduce`, `@shuffle`. Runtime vector indexing has been forbidden since 0.16 [V]. `a ** n` was removed for `@splat` [V 0.17]. Also `@fieldParentPtr` and `@embedFile` [K]. | Eider should have explicit overflow operators and checked casts by default. |
| async | The `async`/`await` keywords and `@frameSize` were removed in 0.15. Async moved into the library [V 0.15]. Since 0.16, concurrency goes through the `std.Io` interface: `io.async` returns a `Future(T)`, then `await` or `cancel`. `io.concurrent` asks for real parallelism. `Io.Group`, `Select`, `Batch`, and `Queue` are covered in §2 [V 0.16]. | A function is "colorless" because the `Io` value is passed in. The same code runs threaded or evented. |
| C interop | `extern` functions and types, `c_int` and friends, C variadics, `export` (C calling convention by default) [V langref]. `zig translate-c` converts headers [V langref]. `@cImport` was deprecated in 0.16 and **removed in 0.17**. Translation now happens through the build system (`b.addTranslateC`) or the external `translate-c` package [V 0.16, 0.17]. | C translation moved out of the language and into the build system. That is worth copying. |
| Cross-compilation / `zig cc` | "Zig builds for all supported targets independently of the host." It ships libc for many targets: "`-lc` … does not depend on any system files" [V overview]. 0.17 ships LLVM 22, musl 1.2.5, glibc 2.44 and its own "zig libc" [V 0.17]. `zig cc` is a drop-in clang that can cross-compile C [V 0.17 TOC]. | Eider compiles to C11, so `zig cc` is a strong candidate as a portable cross-C backend. |

---

## 2. The standard library, module by module (master/0.17)

OS = talks to the OS (through `std.Io` since 0.16). Pure = no OS access.

| Module | Key primitives (one line) | OS? |
|---|---|---|
| `std.Io` interface | `Io` is a vtable value passed explicitly. The VTable covers:<br>• tasks: `async`, `concurrent`, `await`, `cancel`, `group*`, `recancel`, `swapCancelProtection`, `checkCancel`<br>• futex<br>• `operate`/batch<br>• about 60 dir/file/process ops<br>• `now`, `sleep`, `random`, `randomSecure`<br>• `netListenIp`/`ConnectIp`/`Lookup` …<br>[V Io.zig] | OS |
| `std.Io` implementations | `Io.Threaded` is the default and feature-complete, with cancellation via EINTR signalling. `Io.Evented` (green threads, M:N, work stealing) is **experimental, no networking yet**. `Io.Uring` and `Io.Kqueue` are proofs of concept. `Io.Dispatch` uses GCD on macOS. `Io.failing` supports nothing. Use `std.testing.io` in tests [V 0.16]. | OS |
| `std.Io` concurrency | `Future(T)` (`await`/`cancel`), `Group` (O(1) spawn), `Select`, `Batch` over `Operation` with `operateTimeout`, `Queue(T)` (MPMC, bounded), plus `Mutex`, `Condition`, `RwLock`, `Semaphore` (with `waitTimeout` in 0.17), `Event`, `Futex` [V 0.16, 0.17, Io.zig]. | OS-ish |
| `std.Io` cancellation | A cancel request makes I/O return `error.Canceled`. A task can propagate it, `recancel()`, or shield itself with `swapCancelProtection()`. `checkCancel()` adds a cancel point for CPU-bound work [V 0.16]. | |
| `std.Io` time and entropy | `Clock`, `Duration`, `Timestamp`, `Timeout` replace `time.Instant`/`Timer`. `io.random(buf)` may use in-process CSPRNG state. `io.randomSecure(buf)` always fetches fresh OS entropy and returns `error.EntropyUnavailable` rather than falling back [V 0.16]. | OS |
| `std.Io.Reader` / `Writer` | Non-generic, with **the buffer inside the interface**. The vtable is called only when the buffer is full or empty, via `stream`/`drain`. Supports peek, splat, discard and file-to-file transfer. Has precise error sets. Variants: `Reader.fixed`, `Writer.fixed`, `Writer.Allocating`, `Writer.Discarding`, `takeLeb128` [V 0.15, 0.16]. | Pure (the interface) |
| `std.Io.Dir` / `File` (old `std.fs`) | `Dir.cwd`, `createDirPath`, `openFile`, `readStreaming`/`readPositional`, `writeStreamingAll`, `length`/`setLength`, atomic and temp files, locks, `File.MemoryMap`, `Dir.Reader` walking. `fs.path` is deprecated [V 0.16, Io.zig]. | OS |
| `std.Io.net` (old `std.net`) | `IpAddress`/`Ip4Address`/`Ip6Address`/`UnixAddress`, `HostName` lookup and connect (concurrent DNS, racing connects), `Server`/`Stream`/`Socket`. UDP via `send`/`receive`/`sendMany`/`receiveManyTimeout`. No generic setsockopt, only `reuse_address`, `ip6_only`, `allow_broadcast`, `timeout` [V net.zig, 0.16]. Windows uses AFD directly, without ws2_32 [V 0.16]. | OS |
| `std.http` | **HTTP/1.0 and 1.1 only** (`Version`) [V http.zig].<br>• `Client`: connection pool, keep-alive, redirects, compression, TLS through `std.crypto.tls.Client`. API: `request`/`sendBodiless`/`receiveHead` [V 0.15, 0.16].<br>• `Server`: "Handles a single connection lifecycle". It is `init(*Reader, *Writer)`, then `receiveHead`, `respond`/`respondStreaming`, `Expect: 100-continue`, keep-alive, and `respondWebSocket` (small, unfragmented messages). It has **no accept loop, no concurrency, no TLS** [V Server.zig]. | Pure (works over Reader/Writer) |
| `std.json` | RFC 8259. Pieces:<br>• `Scanner` (token stream), and `Reader` connecting a `std.Io.Reader` to it<br>• `parseFromSlice`/`parseFromTokenSource`/`parseFromValue` (plus `*Leaky` arena variants) into any Zig type by reflection<br>• dynamic `Value`, and `Stringify` with `writeStream`<br>• user hooks `jsonParse`/`jsonParseFromValue`/`jsonStringify`<br>`ParseOptions` fields: `ignore_unknown_fields`, `duplicate_field_behavior`, `max_value_len`, `allocate`, `parse_numbers` [V json.zig, static.zig]. | Pure |
| `std.crypto` | Pure-Zig primitives (list below) plus `tls` (**Client only**), `Certificate` (X.509 and a CA bundle scan), `timing_safe`, `secureZero`, `side_channels_mitigations` (none/basic/medium/full, default medium) [V crypto.zig, tls.zig, 0.11]. | Pure (the CA bundle and randomness use the OS) |
| `std.Thread` | Now only `spawn`/`join`/`detach`, `SpawnConfig`, `getCpuCount`, `yield`, `setName`/`getName`, `Id`. Changes since 0.16 [V Thread.zig, 0.16]:<br>• **`Thread.Pool` was removed** in favour of `Io.async`/`concurrent`/`Group`.<br>• `Mutex`, `RwLock`, `Condition`, `WaitGroup` (now `Io.Group`), `ResetEvent` (now `Io.Event`) and `Semaphore` moved to `std.Io`.<br>• `std.once` was removed. | OS |
| `std.atomic` | `atomic.Value(T)` with `load`, `store`, `rmw`, `cmpxchg` and orderings; `spinLoopHint`; cache-line constant [K]. Lock-free code needs no `Io` [V 0.16]. | Pure/CPU |
| `std.time` | Now just unit constants (`ns_per_s` …) and `epoch` calendar helpers. Clocks moved to `std.Io` [V time.zig, 0.16]. | Pure |
| `std.process` | `process.Init` ("Juicy Main": `main(init)` receives `gpa`, `arena`, `io`, `environ_map`, `preopens`, `minimal.args`). `spawn(io, .{argv, stdin=.pipe,…})`, `run(alloc, io, …)` (capture output), `replace` (exec), `executablePath`. **Environment and args are no longer global** [V 0.16]. | OS |
| `std.hash` / `hash_map` | `Wyhash` (default), plus `XxHash`, `Crc32`, `Fnv`, `Murmur`, `CityHash`, `SipHash` in crypto.auth [K]. `HashMap` (managed and unmanaged), `AutoHashMap`, `StringHashMap`, with an 80% default load factor. **The default context hashes with `Wyhash.hash(0, …)`, a fixed seed of 0. There is no random seeding and no mention of HashDoS** [V hash_map.zig]. | Pure |
| Containers | `ArrayList` (unmanaged by default since 0.15; `last()`/`lastPtr` in 0.17), `array_hash_map.Auto/String/Custom` (insertion-ordered; the managed variants were removed in 0.16), `MultiArrayList` (SoA), `PriorityQueue`/`PriorityDequeue` (`push`/`pop`), `Deque`, `SinglyLinkedList`/`DoublyLinkedList` (intrusive), `Treap`, `BitStack`, `bit_set.*`, `Enum{Set,Map,Array}`, `StaticStringMap`, `BufMap`/`BufSet` [V std.zig, 0.16, 0.17]. **`SegmentedList` is not in master's `std`** [V std.zig]. `BoundedArray` was removed in 0.15 in favour of `ArrayList.initBuffer` [V 0.15]. | Pure |
| `std.fmt` | Formatting goes to a `*Io.Writer`. A custom `format(self, w)` must be invoked with `{f}`. Specifiers include `{t}` (tag name), `{b64}`, `{q}`/`{qf}` (0.17). `allocPrint` moved to `Allocator.print` [V 0.15, 0.17]. Float output uses **Ryu** (shortest round-trip, f16–f128) [V fmt/float.zig]. There are `parseInt` and `parseFloat` [K]. | Pure |
| `std.mem` | `eql`, `indexOf`/`find*`, `split`/`tokenize` iterators, `cut*` (0.16), `readInt`/`writeInt` with endianness, `Alignment`, `Allocator` [V 0.16, 0.17, K]. | Pure |
| `std.unicode` | UTF-8 validate, decode, encode and view/iterator; UTF-16LE and WTF-8/16 conversion. Formatting is byte-based, with no Unicode width [V 0.15, K]. | Pure |
| `std.compress` | `flate` (deflate, zlib, gzip containers; **compression re-added in 0.16** after its 0.15 removal), `zstd` (decompress), `lzma`, `lzma2`, `xz` [V compress.zig, 0.15, 0.16]. Also `std.tar`, `std.zip` [V std.zig]. | Pure |
| `std.zon` | Zig Object Notation, used for `build.zig.zon` and config. `zon.parse` (arena-backed in 0.17, `fromSlice`/`fromSliceNoAlloc`) and `stringify` [V 0.17]. | Pure |
| `std.Build` | `build.zig` is Zig code that builds a DAG of steps: modules, artifacts, `addTranslateC`, Run/Fmt steps, options, lazy dependencies. Package manager uses `build.zig.zon` with hash-pinned deps. 0.17 splits configurer and maker into separate processes and adds a Build Server Protocol [V 0.17]. | OS |
| Other | `std.Uri`, `std.base64`, `std.Random`, `std.log`, `std.testing` (allocator, io, fuzz), `std.Progress`, `std.DynLib`, `std.Tz` [V std.zig]. | mixed |

### What `std.crypto` implements in pure Zig [V crypto.zig]

| Category | Implemented |
|---|---|
| Hashes | SHA-1, SHA-2 (with HW acceleration), SHA-3/SHAKE/TurboSHAKE, BLAKE2, BLAKE3, MD5, Ascon-Hash256/XOF |
| AEADs | AES-GCM, AES-GCM-SIV, AES-SIV, AES-OCB, AES-CCM, ChaCha20/12/8-Poly1305 and X-variants, XSalsa20-Poly1305, AEGIS-128L/256 (incl. X2/X4), Ascon-AEAD128, ISAP |
| MAC / KDF | HMAC, CMAC, CBC-MAC, SipHash, AEGIS-MAC, Poly1305, GHASH, POLYVAL; HKDF |
| Key exchange (DH) / KEM | X25519; ML-KEM, Kyber, hybrid KEMs |
| Signatures | Ed25519, ECDSA (P-256, P-384, secp256k1), ML-DSA |
| Curves | Curve25519, Edwards25519, Ristretto255, P-256, P-384, secp256k1 |
| Password hashing | argon2, bcrypt (incl. the OpenSSH KDF), scrypt, pbkdf2, PHC/crypt encodings |
| Other | NaCl `Box`/`SecretBox`/`SealedBox`; `ff` constant-time field arithmetic (lets RSA verify without an allocator) [V 0.11] |
| Not offered | General RSA signing, X448/Ed448 primitives |

### TLS

- **`std.crypto.tls.Client` supports TLS 1.2 and 1.3.** Ciphers: AES-GCM, ChaCha20-Poly1305, AES-CCM and AEGIS suites. Groups include `x25519_ml_kem768` and `secp256r1_ml_kem256` hybrid post-quantum [V tls.zig].
- **There is no TLS server in std** (tls.zig exports only `Client`) [V].
- The community `ianic/tls.zig` offers a TLS 1.2/1.3 client and a basic 1.3 server [search result].

---

## 3. Service and networking ecosystem (as of Oct 2026)

| Project | What it is | Maturity |
|---|---|---|
| **http.zig (httpz)** (karlseguin) | HTTP/1.1 server. Workers on epoll/kqueue hand requests to an app thread pool; Windows falls back to thread-per-connection. Has a router, middleware, CORS, SSE, WebSocket (via websocket.zig), metrics, test helpers, and per-request arenas. Claims about 140K req/s on an M2. Targets 0.17. | The de facto base layer, about 1.6k stars. It assumes a reverse proxy in front: no TLS, timeouts off by default, "may never be fully HTTP/1.1 compliant". It calls `std.http.Server` "very slow and assumes well-behaved clients" [V]. |
| **Tokamak** | A framework on httpz built around **dependency injection** (handlers declare their deps). Has auto-JSON, nested-route middleware, and "basic Swagger support". Targets 0.17. | Active, about 645 stars, pre-1.0 with frequent breaking changes [V]. |
| **Jetzig** | A Rails-like framework on httpz. Has file-based routing, Zmpl templates, sessions, jobs, mail, cache, and DB integration. Tracks Zig nightly. | About 1.5k stars. Not formally released; alpha-ish [V repo, search]. |
| **Zap** | A wrapper over the C library facil.io. Gets TLS through system OpenSSL. No Windows support. | **Archived.** Its successor is "Baz (Bounded Async Zap)" for 0.16 [V]. |
| **libxev** (mitchellh) | A proactor event loop: io_uring/epoll, kqueue, WASI. Windows is on the roadmap. Zero runtime allocations, with a C API. | "Stable for most use cases". Used by Ghostty and zml. Requires 0.16, but **does not integrate with `std.Io`** [V]. |
| **zio** (lalinsky) | A Tokio/Go-style runtime with stackful coroutines and growable stacks. Work-stealing multi-threaded scheduler on io_uring/epoll, IOCP, kqueue or poll. Async DNS, task groups, cancellation, channels. **Implements `std.Io`**, so std-based code runs on it unmodified. HTTP lives in the sibling project "dusty". | About 688 stars, v0.19, active. Its author calls `Io.Evented` "very far from finished" [V]. |
| **pg.zig** (karlseguin) | Native PostgreSQL wire driver: pool, prepared statements with caching, LISTEN/NOTIFY. **TLS goes through OpenSSL and is "experimental"**. | It warns that connections "may get into invalid states", so use the pool. Numeric support is "half-baked" [V]. |
| Protobuf / gRPC | Options: `Arwalk/zig-protobuf` (proto3 codegen plugin), `mattnite/protobuf` (pure-Zig parser and codegen, transport-agnostic RPC stubs), `allyourcodebase/grpc` (packages the C gRPC core), `ziglana/grpc-zig` (pure-Zig, v0.1). | No official or mature gRPC. HTTP/2 is missing from std, which is the blocker [search]. |
| OpenAPI | `openapi2zig` (Christian Helle) generates models and a client from Swagger 2.0 and OpenAPI 3.0–3.2. Tokamak has basic Swagger output. | Client-side generation only. Nothing server-first or contract-first that is mature [search]. |

**Overall:** HTTP/1.1 is adequate, there is no HTTP/2 or HTTP/3 in std or a mature library, and TLS termination is expected to happen at a reverse proxy. The databases and TLS layers that matter in production still lean on OpenSSL, as pg.zig and Zap do.

---

## 4. Lessons for Eider

### Pure-Zig crypto and TLS

- **Stated rationale (from the record):**
  - Mostly practical. The TLS 1.3 client arrived in 0.11 "as a dependency of the HTTP Client, which the package manager uses" [V 0.11]. Zig wanted a self-contained toolchain with no system-library dependencies, consistent with bundling libc and cross-compiling from any host [V overview].
  - Pure Zig also lets crypto use comptime, `@Vector` SIMD, hardware intrinsics, and `side_channels_mitigations` levels.
  - I found no single manifesto document.
- **Assurance:**
  - **No independent third-party audit of `std.crypto` or `std.crypto.tls` was found** [searches].
  - The 0.11 notes warned there was no automated TLS testing, no server, no fuzzing, and an RFC 8446 audit still on the to-do list [V 0.11].
  - Since then the code has had community conformance testing (`jacobly0/tls-conformance`) and Valgrind "secret" tagging for constant-time checks.
  - It is maintained largely by Frank Denis, the libsodium author, which is the main informal assurance.
- **Performance:**
  - There is no official head-to-head against OpenSSL.
  - The AEGIS-128L commit claimed "on par with libsodium".
  - Release notes cite internal speedups (GHASH about 3x, SHA-256 HW acceleration, AVX2/AVX-512 ChaCha) [V 0.11].
  - Treat it as competitive for symmetric primitives and unknown for P-256/RSA versus hand-tuned assembly.
- **Contrast with Rust.** rustls is a Rust TLS state machine with the primitives in a pluggable "crypto provider": `aws-lc-rs` (recommended, post-quantum), `ring`, or third-party ones such as SymCrypt. Since rustls 0.24 the provider must be chosen explicitly [V rustls README]. Rust keeps the *protocol* memory-safe and outsources *primitives* to audited, often FIPS-validated C and assembly. Zig owns both layers.
- **Recommendation for Eider:**
  - Follow the rustls split behind a trait: an Eider-written TLS and protocol layer over a `CryptoProvider` capability.
  - Ship a small default provider in Eider (or vendored C such as libsodium, monocypher or BearSSL-style code) and allow aws-lc/BoringSSL for FIPS.
  - Eider compiles to C, so binding audited C primitives is cheap, while writing the state machine in Eider gets the memory-safety win.

### No hidden allocations and no hidden control flow

- **Zig's rule:** "no hidden control flow, no hidden memory allocations" [V overview]. In practice:
  - no operator overloading
  - no exceptions
  - no destructors or RAII, only `defer`
  - no getters or properties
  - the allocator is a parameter
  - the Io is a parameter
- **What Eider can adopt:**
  - **Allocators as explicit values or capabilities.** Containers take the allocator per call rather than storing it, which Zig moved to in 0.15–0.16. Provide per-request arenas (every Zig web framework does).
  - **I/O as an explicit capability value.** `std.Io` is exactly an object-capability for blocking and nondeterminism: files, net, time, random, sleep, spawn. It maps one-to-one onto Eider's `uses net`. Make the capability a passed value so the runtime can be swapped (threaded, evented, a deterministic test sim like `Io.failing` and `testing.io`). That gives colorless async and deterministic simulation testing in the TigerBeetle style.
  - **Explicit cancellation semantics.** Zig gives cancel points, `error.Canceled`, recancel, and cancel protection. Bake these into the type system early, not as an afterthought.
  - **Errors as values with `try`, and `defer`/`errdefer`.** In a value-semantics language with destructors, Eider must decide whether drop is "hidden control flow". Zig says yes. A compromise is deterministic, statically known drops (no user code in drop, or a lint).
  - **Buffer-in-interface streams.** Keep the fast path non-virtual and the slow path virtual (Writergate). This beats `anytype`/generic streams for code size and compile time.
  - **Process environment as a value.** Pass env, args, gpa and io to `main` (Juicy Main) rather than using globals.
- **Where Eider should differ:**
  - **HashDoS.** Zig's maps use seed 0. For a services language, use a keyed hash (SipHash or a seeded wyhash/rapidhash) for any map with untrusted keys, seeded per process from `randomSecure`.
  - **Safety in release builds.** Zig drops checks in fast mode. Eider should keep bounds and overflow checks by default.
  - **HTTP/2, HTTP/3 and a TLS server.** These are the gaps that block gRPC in Zig. Plan them from the start.

---

## 5. Primitive map for a services language

Layer key: core = OS core (Eider's tiny C core), rt = runtime, lang = language, std = standard library, eco = ecosystem.

**Easy to forget (marked ⚠):** cancellation, cancel-protection, bounded queues, timeouts on every op, entropy failure mode, keyed hashing, process env as a value, testing Io / deterministic simulation, HTTP header-size limits, CA-bundle loading, `Expect: 100-continue`, chunked encoding, DNS racing (Happy Eyeballs), monotonic vs wall clocks, constant-time compare, `secureZero`, atomic file write, socket pairs, signal/EINTR handling.

| Primitive | Zig's answer | Layer |
|---|---|---|
| Compile-time evaluation / generics | `comptime`, types as values | lang |
| Reflection for codecs | `@typeInfo` plus `@Struct`/`@Enum`/… | lang |
| Sum types / exhaustive match | `union(enum)` + `switch` | lang |
| Error propagation | error unions, `try`/`catch`, inferred sets | lang |
| Error *context* / diagnostics ⚠ | out-of-band (`Diagnostics` structs), error return traces | lang/std |
| Scoped cleanup | `defer`/`errdefer` | lang |
| Nullability | `?T` | lang |
| Checked arithmetic / casts | safety-checked by default; `+%`, `+|`, `@addWithOverflow`, `@intCast` | lang |
| Safety mode policy | debug/safe/fast/small, `@setRuntimeSafety` | lang |
| SIMD | `@Vector`, `@splat`, `@reduce` | lang |
| Bit-exact layout for wire formats | `packed struct(uN)`, `extern struct`, `@byteSwap`, `mem.readInt` | lang/std |
| Memory allocation strategy | explicit `Allocator`: arena, safe/debug, fixed-buffer, pool, smp | std |
| Per-request arena ⚠ | `ArenaAllocator` (lock-free), framework-provided | std/eco |
| Leak and double-free detection | `SafeAllocator`, `testing.allocator` | std |
| I/O capability object | `std.Io` vtable passed explicitly | std (rt behind it) |
| Threaded runtime | `Io.Threaded` | rt |
| Event-loop runtime (io_uring/kqueue/IOCP) | `Io.Evented`/`Uring`/`Kqueue` experimental; zio, libxev mature | rt / eco |
| Tasks / futures | `io.async` → `Future(T)`; `io.concurrent` | std |
| Structured concurrency | `Io.Group` | std |
| Cancellation ⚠ | `Future.cancel`, `error.Canceled`, `checkCancel`, `recancel`, `swapCancelProtection` | std/rt |
| Select / race ⚠ | `Io.Select`, `Batch`, `operateTimeout` | std |
| Timeouts on every operation ⚠ | `Timeout`, `*Timeout` variants on net ops | std |
| Channels / bounded queues ⚠ | `Io.Queue(T)` (MPMC, bounded; backpressure) | std |
| Mutex / RwLock / Condvar / Semaphore / Event | `std.Io.*` (Io-aware so they suspend under evented) | std |
| Atomics | `std.atomic.Value` | lang/std |
| OS threads | `std.Thread.spawn/join` | core |
| Thread pool | removed; use Io groups | rt |
| Clocks (monotonic vs wall) ⚠ | `Io.Clock` (`.awake`, `.real`, …), `Timestamp`, `Duration` | core/std |
| Sleep | `io.sleep(dur, clock)` | core |
| Calendar / epoch / tz | `time.epoch`, `std.Tz` | std |
| Secure entropy (and its failure mode) ⚠ | `io.randomSecure` → `error.EntropyUnavailable` | core |
| Fast PRNG | `std.Random`, `io.random` | std |
| Files / dirs | `Io.Dir`, `Io.File` | core/std |
| Atomic file write ⚠ | `dirCreateFileAtomic` | std |
| mmap | `File.MemoryMap` | core |
| File locks | `fileLock`/`tryLock` | core |
| TCP / UDP / Unix sockets | `Io.net.Socket`/`Server`/`Stream`, `UnixAddress` | core/std |
| Socket pairs ⚠ | `Socket.createPair` | core |
| Socket options | only a few (`reuse_address`, `ip6_only`, broadcast); no generic setsockopt | core (gap) |
| DNS resolution + Happy Eyeballs ⚠ | `HostName.lookup`, concurrent connect racing | std |
| Process spawn / pipes / exec | `process.spawn`/`run`/`replace` | core/std |
| Args / env as values ⚠ | `process.Init` (non-global) | rt/std |
| Signals / EINTR | used internally for cancellation; no high-level signal API found | core (gap) |
| Byte streams | `Io.Reader`/`Writer` (buffer in interface) | std |
| In-memory streams | `Reader.fixed`, `Writer.Allocating`/`Discarding` | std |
| URI parsing | `std.Uri`, `net.HostName.fromUri` | std |
| HTTP/1.1 parsing / server core | `std.http.Server` (per connection, no accept loop) | std |
| HTTP header-size limit ⚠ | reader buffer size → `HttpHeadersOversize` | std |
| Chunked, `Expect: 100-continue`, keep-alive ⚠ | handled in `std.http` | std |
| Production HTTP server (routing, middleware) | http.zig, Tokamak, Jetzig | eco |
| HTTP client (pool, redirects, gzip, TLS) | `std.http.Client` | std |
| HTTP/2, HTTP/3, gRPC transport | none in std; gRPC via C core | eco (gap) |
| WebSocket | `Server.respondWebSocket` (basic); websocket.zig | std/eco |
| TLS client | `crypto.tls.Client` (1.2/1.3, PQ hybrid) | std |
| TLS server ⚠ | none in std; tls.zig (basic) or OpenSSL | eco (gap) |
| X.509 + system CA bundle ⚠ | `crypto.Certificate`, `Certificate.Bundle` (OS scan) | std/core |
| Hashes, AEADs, X25519, Ed25519, ECDSA, ML-KEM/ML-DSA | `std.crypto` in pure Zig | std |
| Password hashing | argon2, bcrypt, scrypt, pbkdf2 | std |
| Constant-time compare / zeroize ⚠ | `timing_safe.eql`, `secureZero` | std |
| Side-channel policy knob | `std_options.side_channels_mitigations` | std |
| Hash maps (ordered and unordered) | `HashMap`, `array_hash_map.*` | std |
| HashDoS-resistant keyed hashing ⚠ | **not by default** (Wyhash seed 0); SipHash available | std (Eider should default it) |
| Other collections | ArrayList, MultiArrayList, PriorityQueue, Deque, bit sets, linked lists | std |
| JSON (reflection-driven, streaming) | `std.json` (`parseFromSlice`, `Stringify`, hooks, `ignore_unknown_fields`) | std |
| Config format | `std.zon` | std |
| Protobuf | zig-protobuf, mattnite/protobuf | eco |
| OpenAPI codegen | openapi2zig (client), Tokamak (basic Swagger) | eco (gap) |
| Base64 / hex / LEB128 | `std.base64`, `fmt` `{b64}`/`{x}`, `Reader.takeLeb128` | std |
| Number formatting / parsing | `std.fmt` (Ryu shortest round-trip), `parseInt`/`parseFloat` | std |
| Unicode | `std.unicode` (UTF-8/16/WTF validation and conversion) | std |
| Compression | flate/gzip/zlib (both ways), zstd, xz, lzma; tar, zip | std |
| Logging | `std.log` (scoped, compile-time level) | std |
| Database drivers | pg.zig (native; TLS via OpenSSL) | eco |
| Testing hooks | `testing.allocator`, `testing.io`, fuzzer | std |
| Deterministic simulation / fault injection ⚠ | swappable `Io` (`Io.failing`, custom vtables) | std/rt |
| C interop | `extern`, translate-c via build system (`@cImport` removed in 0.17) | lang/build |
| Build system / packages | `build.zig` + `build.zig.zon` (hash-pinned), lazy deps | std/tooling |
| Cross-compiling C | `zig cc` with bundled libcs | tooling |

---

## Sources (pages opened)

**Official releases and language docs**
- https://ziglang.org/download/ (versions: 0.17.0 stable, 0.18.0-dev master)
- https://ziglang.org/download/0.17.0/release-notes.html
- https://ziglang.org/download/0.16.0/release-notes.html
- https://ziglang.org/download/0.15.1/release-notes.html
- https://ziglang.org/download/0.11.0/release-notes.html (TLS/HTTP client origins, crypto notes)
- https://ziglang.org/documentation/master/ (build modes, Illegal Behavior, allocators, C interop, Zen)
- https://ziglang.org/learn/overview/
- https://ziglang.org/documentation/master/std/ (JS-rendered; the source files below were used instead)

**std source files (master)**
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/std.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/Io.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/Io/net.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/crypto.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/crypto/tls.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/http.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/http/Server.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/json.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/json/static.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/hash_map.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/heap.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/Thread.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/time.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/compress.zig
- https://codeberg.org/ziglang/zig/raw/branch/master/lib/std/fmt/float.zig

**Ecosystem repositories**
- https://github.com/karlseguin/http.zig
- https://github.com/cztomsik/tokamak
- https://github.com/jetzig-framework/jetzig
- https://github.com/zigzap/zap
- https://github.com/mitchellh/libxev
- https://github.com/lalinsky/zio
- https://github.com/karlseguin/pg.zig
- https://github.com/rustls/rustls

**Search results only (repositories not opened individually)**
- github.com/Arwalk/zig-protobuf
- mattnite/protobuf
- allyourcodebase/grpc
- ziglana/grpc-zig
- christianhelle/openapi2zig
- ianic/tls.zig
- jacobly0/tls-conformance
- the AEGIS-128L commit ("on par with libsodium")
- secondary write-ups on 0.16 (machineherald, youngju.dev)
