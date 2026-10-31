# Rust as a reference for Eider's service primitives

Researched 2026-10-30 against current docs: std 1.99.1 (2026-10-13), tokio 1.54.1, tokio-util 0.7.20, hyper 1.12.0, axum 0.8.9, tower 0.5.3, tonic 0.14.9, prost 0.14.4, rustls 0.23.46, rustls-webpki 0.103.16, aws-lc-rs 1.19.0, reqwest 0.13.5, sqlx 0.9.0, utoipa 6.0.0, aide 0.15.1, bytes 1.12.1, mio 1.2.4, futures 0.3.34, tracing 0.1.44, opentelemetry 0.33.1, metrics 0.24.6, clap 4.6.7, thiserror 2.0.21, anyhow 1.0.104, criterion 0.8.2.

Each row is marked **[doc]** when it comes from a page I opened, and **[gk]** when it comes from general knowledge that I did not re-check on a page this session. Rows with no mark are [doc].

---

## 0. The layer split: core, alloc and std

| Layer | Contains | Needs |
|---|---|---|
| `core` | Primitives, `Option`/`Result`, `fmt`, `iter`, `ops`, `cmp`, `mem`, `ptr`, `num`, `char`, `str`, `marker`, `cell`, `any`, `hash` traits, `future`/`task` (Future, Poll, Context, Waker), `sync::atomic`, `time::Duration` | Nothing: no allocator and no OS **[gk]** |
| `alloc` | `Box`, `Vec`, `String`, `Rc`/`Arc`, `BTreeMap`, `VecDeque`, `BinaryHeap`, `format!`, `task::Wake` | Only a global allocator **[gk]** |
| `std` | Re-exports core and alloc, then adds `io`, `fs`, `net`, `thread`, `process`, `env`, `time::{Instant,SystemTime}`, `sync` locks/channels, `HashMap` (it needs OS randomness), `panic` hooks, `backtrace`, `os::*` | The OS |

The std index says `core` and `alloc` "are most likely to work" outside a normal `main()`, though hookable behaviour (panics, OOM, allocators) still depends on the hooks. The prelude is a small set, mostly traits, that is imported into every module.

**Takeaway for Eider:** keep the same three tiers. `HashMap` lives in std rather than alloc for one reason: its default hasher needs OS entropy.

---

## 1. Rust std, module by module

The OS column is **Y** when the module calls the OS, **N** when it is pure computation, and **hook** when it is pure apart from runtime hooks.

| Module | Key primitives (one line) | OS? |
|---|---|---|
| `io` | Traits `Read`, `Write`, `BufRead` (`read_line`, `lines`), `Seek`, `IsTerminal`. Types `BufReader`, `BufWriter` (flushes on drop), `Cursor` (in-memory `Seek`), `IoSlice`/`IoSliceMut` (vectored I/O), `Take` (from `Read::take`, which caps how many bytes are read), `Empty`, `Sink`, `Repeat`, `Stdin`/`Stdout`/`Stderr`. Functions `copy`, `read_to_string`, `pipe`. Errors: `io::Error`, `ErrorKind`, `io::Result` | Y (the traits themselves are pure) |
| `fs` | `File`, `OpenOptions`, `metadata`, `read`/`write`/`read_to_string`, `create_dir_all`, `remove_*`, `rename`, `read_dir`/`DirEntry`, `Permissions`, `canonicalize`, `hard_link`, `File::sync_all`/`sync_data` **[gk]** | Y |
| `net` | `TcpListener`, `TcpStream`, `UdpSocket`, `SocketAddr`/`IpAddr`/`Ipv4Addr`/`Ipv6Addr`, `ToSocketAddrs` (a blocking DNS lookup), `Shutdown`. Everything is blocking, and there is no TLS or async **[gk]** | Y |
| `time` | `Duration` (in core). `Instant` is monotonic: `CLOCK_MONOTONIC` on Unix, `CLOCK_UPTIME_RAW` on Darwin, `QueryPerformanceCounter` on Windows. `duration_since`, `elapsed` and `-` saturate to zero, while `checked_duration_since` returns `None`. `SystemTime` and `UNIX_EPOCH` are wall clock, and `SystemTime::duration_since` returns a `Result` **[gk]**. There is no calendar or timezone support | Y |
| `sync` | `Arc`/`Weak`, `Mutex`/`MutexGuard` (RAII guards), `RwLock`, `Condvar` with `wait_timeout`, `Barrier`, `Once`, `OnceLock` (write once), `LazyLock` (initialised on first access), `PoisonError`/`LockResult`, `TryLockError`. Modules `atomic`, `mpsc`, plus experimental `mpmc`, `oneshot`, `nonpoison`, `poison`, `ReentrantLock` and `UniqueArc`. Locks poison when a holder panics | Y (futex) |
| `sync::atomic` | `AtomicBool`, `AtomicI*`/`AtomicU*`/`AtomicUsize`, `AtomicPtr`, `Ordering` (Relaxed, Acquire, Release, AcqRel, SeqCst), `fence`, `compiler_fence` **[gk]** | N |
| `sync::mpsc` | `channel` (unbounded), `sync_channel(n)` (bounded, blocks when full, and `0` means rendezvous), `Sender`, `SyncSender`, `Receiver` with `recv_timeout` and `try_recv` **[gk]** | Y |
| `thread` | `spawn`, `Builder` (name, stack size), `JoinHandle::join` (returns `Err` when the thread panicked), `sleep`, `park`/`unpark`, `yield_now`, `current`, `available_parallelism`, `thread_local!`/`LocalKey`. **`thread::scope`** (stable since 1.63) joins every thread before it returns, so threads may borrow non-`'static` data, and the scope panics if an auto-joined thread panicked | Y |
| `process` | `Command` (args, env, cwd, `Stdio` piped/inherit/null), `Child` (`wait`, `kill`, `stdin`/`stdout`), `Output`, `ExitStatus`, `exit`, `abort`, `id`, `ExitCode`/`Termination` (what `main` returns) **[gk]** | Y |
| `env` | `args`/`args_os`, `var`/`vars`/`var_os`, `set_var` (now `unsafe`, because changing the environment races with other threads), `current_dir`, `current_exe`, `temp_dir`, `home_dir`, `consts::OS`/`ARCH` **[gk]** | Y |
| `path` | `Path` (borrowed) and `PathBuf` (owned), wrapping `OsStr`/`OsString` (not guaranteed UTF-8), `join`, `parent`, `extension`, `components`, `display()`, `MAIN_SEPARATOR` **[gk]** | N (but OS-dependent) |
| `ffi` | `OsStr`/`OsString`, `CStr`/`CString`, `c_char`, `c_int` and the other C types **[gk]** | N |
| `collections` | `Vec`, `VecDeque`, `LinkedList`, `HashMap`/`HashSet`, `BTreeMap`/`BTreeSet` (ordered, with ranges), `BinaryHeap`, and the `entry` API **[gk]** | HashMap seeding only |
| `fmt` | `Display`, `Debug` (and `{:#?}`), `LowerHex`/`UpperHex`, `Octal`, `Binary`, `LowerExp`/`UpperExp`, `Pointer`. `Formatter`, whose `width`, `precision`, `align` and `pad` give `{:>10.3}`. `format_args!` builds `Arguments` with no allocation. `write!`, `fmt::Write`. Output is **locale-independent** and rounds half to even at a given precision. A `fmt` impl may return `Err` only when the Formatter did | N |
| `hash` | `Hash`, `Hasher`, `BuildHasher`, `BuildHasherDefault`, `DefaultHasher`, `RandomState`. The default algorithm is **SipHash 1-3**, "subject to change". It is **seeded randomly per map** from secure host randomness without blocking, which is "resistance against HashDoS attacks". `with_hasher` warns that setting the seed by hand "can expose a DoS attack vector", and because of the seed `HashMap::new` cannot appear in a `const`/`static` (use `LazyLock`). Hash values are not stable across runs or releases. The contract is `k1 == k2` implies `hash(k1) == hash(k2)` | Y (seed) |
| `error` | `trait Error: Debug + Display` with `source()` for the cause chain; `description` and `cause` are deprecated. `downcast_ref`/`is` work on `dyn Error`. `Box<dyn Error + Send + Sync>` converts `From` any `E: Error` and from `&str`/`String`. `provide` and `sources()` are nightly-only. Style rule: messages are lowercase with no trailing punctuation, and a cause goes in **either** `source()` or `Display`, never both | N |
| `convert` | `From`/`Into` (infallible; implementing `From` gives you `Into`), `TryFrom`/`TryInto` (fallible, with an associated `Error`), `AsRef`/`AsMut`, `Infallible`. The `?` operator converts errors through `From` **[gk]** | N |
| `ops` | Operator traits (`Add`, `Sub`, `Mul`, `Index`, `Neg`, `Not`, `BitAnd`, `Shl` and the rest), `Deref`/`DerefMut`, `Drop`, `Fn`/`FnMut`/`FnOnce`, `Range*`, `ControlFlow`, `Try` (unstable) **[gk]** | N |
| `iter` | `Iterator` (`next`, plus about 75 adapters: `map`, `filter`, `fold`, `zip`, `chain`, `take`, `skip`, `enumerate`, `flat_map`, `collect`, `sum`), `IntoIterator`, `FromIterator`, `DoubleEndedIterator`, `ExactSizeIterator`, `FusedIterator`, `Peekable`, `from_fn`, `successors`, `repeat`, `once`, `empty`. Adapters are lazy **[gk]** | N |
| `str` / `string` | `str` is always valid UTF-8 and is indexed by byte. Methods include `chars`, `bytes`, `char_indices`, `split*`, `trim*`, `find`, `parse::<T>()` (via `FromStr`), `from_utf8` (checked), `from_utf8_lossy`, `is_char_boundary`. `String` is growable with `push_str` and `format!`. `ToString` comes free from any `Display` **[gk]** | N |
| `num` (integers) | Plain `+ - *` **panic on overflow when compiled in debug mode** (controlled by `-C overflow-checks`) and wrap in release **[gk for release]**. Integer division by zero always panics. Method families: `checked_*` returns `Option`, `wrapping_*` wraps, `saturating_*` clamps, `overflowing_*` returns `(T, bool)`, `strict_*` always panics, and `unchecked_*` makes overflow UB. Types `Wrapping<T>`, `Saturating<T>`, `NonZero<T>` (enables niche optimisation). Also `from_str_radix`, `to_be_bytes`/`from_le_bytes` (endianness), `leading_zeros`, `pow`, `isqrt`, `ParseIntError`/`IntErrorKind` | N |
| `num` (floats) | `f32`/`f64` are IEEE 754 binary32/binary64. They have only `PartialEq`/`PartialOrd` (no `Eq` or `Ord`); `total_cmp` gives the IEEE `totalOrder`. `to_bits`/`from_bits` reinterpret bits, which differs from `as`. `NAN` is a quiet NaN with arbitrary payload and sign. `mul_add` is the fused multiply-add. `FromStr` returns the **closest representable** value, rejects surrounding whitespace, and accepts `inf`/`nan`. `Display` prints the **shortest digits that round-trip**, in positional notation (Grisu with a Dragon fallback in `core::fmt::float`/`flt2dec`), while `Debug` switches to exponent form for large and small magnitudes **[std source, via search]**. `as` casts from float to int saturate and send NaN to 0 **[gk]** | N |
| `char` | A Unicode scalar value (4 bytes, surrogates excluded). `is_alphabetic`, `is_ascii_*`, `to_digit`, `from_u32` (checked), `to_uppercase` (returns an iterator), `len_utf8`, `encode_utf8` **[gk]** | N |
| `mem` | `size_of`, `align_of`, `swap`, `replace`, `take`, `drop`, `forget`, `transmute` (unsafe), `MaybeUninit`, `ManuallyDrop`, `discriminant`, `offset_of!` **[gk]** | N |
| `ptr` / unsafe | `*const T`/`*mut T`, `NonNull`, `null`, `read`/`write`, `copy`/`copy_nonoverlapping`, `drop_in_place`, `addr_of!`/`&raw`, the provenance APIs. `unsafe` blocks and functions; `unsafe extern` blocks for FFI **[gk]** | N |
| `panic` | `panic!`, `catch_unwind` (`UnwindSafe`), `set_hook`/`take_hook`, `PanicHookInfo`, `resume_unwind`. With `panic=abort` vs `unwind`, a panic unwinds only its own thread, and its locks poison. `Location`/`#[track_caller]` **[gk]** | hook |
| `backtrace` | `Backtrace::capture()` (honours `RUST_BACKTRACE`/`RUST_LIB_BACKTRACE`), `force_capture`, `status` **[gk + anyhow doc]** | Y (reads symbols) |
| `any` | `Any` with `type_id`, `downcast_ref`/`downcast` on `dyn Any` and `Box<dyn Any>`, `TypeId`, `type_name` **[gk]** | N |
| `marker` | `Send` and `Sync` are **unsafe auto traits**: `&T: Send` exactly when `T: Sync`. `Rc`, raw pointers, `NonNull` and `MutexGuard` are `!Send`; `Mutex<T>` is `Send` when `T: Send`; `Arc<T>` is `Send` when `T: Send + Sync`. A type opts in with `unsafe impl Send`. Also `Copy`, `Sized`, `Unpin`, `PhantomData`, `PhantomPinned` | N |
| `future` / `task` / `pin` | See §2 | N |
| Others | `cell` (`Cell`, `RefCell`, `OnceCell`, `LazyCell`), `rc`, `borrow` (`Cow`), `cmp` (`Ord`, `Ordering`, `Reverse`), `default`, `clone`, `option`, `result`, `os::{unix,windows,fd}` (raw handles), `arch` (SIMD), `hint` (`black_box`, `spin_loop`). The experimental `random` module shows std still has **no stable RNG**: the `rand`/`getrandom` crates fill that gap | mixed |

---

## 2. The async and service stack

### 2.1 Language and core

| Piece | What it provides |
|---|---|
| `core::future::Future` | `fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Output>`. Futures are lazy and do nothing until polled |
| `Poll<T>` | `Ready(T)` or `Pending` |
| `Context` / `Waker` | A future that returns `Pending` must store `cx.waker()` and later call `wake()` or `wake_by_ref()`. `Waker` is `Send + Sync + Clone`. A wake guarantees at least one later poll, and several wakes may coalesce. `will_wake` and `clone_from` avoid redundant clones. `RawWaker` with a 4-function vtable (unsafe), or the safe `alloc::task::Wake` on `Arc<Self>`. `Waker::noop()` |
| `Pin` | Lets a compiler-generated state machine hold references into itself **[gk]** |
| `async fn` / `.await` | The compiler builds a state-machine `Future`. **Cancellation is a drop**: dropping a future stops it at its last `.await`. Async fns in traits have been stable since 1.75 **[gk]** |
| Not in std | No executor, reactor, timers, async I/O traits or `Stream` (`async_iter` is experimental). This is the main "runtime gap" a services language must decide to fill or leave open |

### 2.2 Ecosystem crates

| Crate | Layer / role | Key primitives |
|---|---|---|
| **mio** 1.2 | OS readiness abstraction | `Poll`, `Registry`, `Token`, `Interest`, `Events`, `Waker` (cross-thread wakeup), non-blocking `net` types. Backends: **epoll** (Linux, Android, illumos), **kqueue** (macOS, iOS, BSDs), **event ports** (Solaris), **IOCP** (Windows, adapted to readiness). Semantics are edge-like, so you must retry "until it returns WouldBlock" |
| **tokio** 1.54 | Runtime | Modules `runtime` (Builder; `current_thread` under the `rt` feature, or the **multi-threaded work-stealing** scheduler under `rt-multi-thread`; `#[tokio::main]`), `task` (`spawn`, `spawn_blocking`, `JoinHandle`, `JoinSet`, `yield_now`, `LocalSet`), `net` (TCP, UDP, Unix), `io` (`AsyncRead`, `AsyncWrite`, `AsyncBufRead` + `*Ext`), `time`, `sync`, `fs` (on a blocking pool), `process`, `signal` (`ctrl_c`, unix signals). No feature is on by default, and `full` enables them all. `io-uring` is unstable |
| tokio `time` | Timers | `sleep`/`sleep_until`, **`timeout`/`timeout_at`** (cancels the inner future and returns `Elapsed`), `interval` (first tick fires immediately; `MissedTickBehavior` defaults to `Burst`), a monotonic `Instant`, and `pause`/`advance` (the `test-util` feature) for deterministic tests |
| tokio `sync` | Async coordination | `mpsc` (bounded `channel(n)` **gives backpressure** because send waits when full; `unbounded_channel` never waits), `oneshot`, `broadcast` (multiple consumers; lagging receivers lose messages), `watch` (latest value, `changed()`), `Mutex` (async, safe to hold across `.await`), `RwLock`, `Semaphore` (concurrency limits and permits), `Notify`, `Barrier`, `OnceCell` |
| `tokio::select!` | Racing | Polls branches concurrently and **drops the losers**. Branch order is random unless `biased;`. The docs list **cancel-safe** operations (`mpsc`/`broadcast` `recv`, `watch::changed`, `accept`, `read`, `write`, `Stream::next`) and unsafe ones (`read_exact`, `read_to_end`, `write_all` lose data; `Mutex::lock`, `Semaphore::acquire` and `Notify::notified` lose their queue position) |
| `JoinSet` | Structured task groups | `spawn` returns an `AbortHandle`; `join_next` yields results in completion order and is cancel-safe; `abort_all`; `shutdown` aborts and waits. **Dropping the set aborts every task.** This is the closest Rust gets to structured concurrency |
| **tokio-util** 0.7 | Glue | **`CancellationToken`**: `cancel`, `cancelled()` (cancel-safe), `is_cancelled`, `child_token` (cancellation flows down only), `drop_guard`, `run_until_cancelled`. **`TaskTracker`**: `close` then `wait` for graceful shutdown. Also `codec` (`Framed`, `Encoder`/`Decoder`) **[gk]** |
| Graceful shutdown (tokio guide) | Pattern | (1) detect the signal (`signal::ctrl_c`, or an mpsc channel combined with `select!`); (2) broadcast with `CancellationToken`; (3) wait with `TaskTracker`. axum adds `serve(...).with_graceful_shutdown(fut)` **[gk]** |
| **bytes** 1.12 | Zero-copy buffers | `Bytes` (immutable, refcounted, cheap `clone` and `slice` over shared memory), `BytesMut` (unique and mutable; `split()` hands off a frozen `Bytes`), `Buf`/`BufMut` (cursor-based and possibly non-contiguous, as in a rope; **infallible**, unlike io traits, because they make no syscalls), `TryGetError` |
| **futures** 0.3 | Async vocabulary | `Stream`/`TryStream`, `Sink`, `StreamExt`/`FutureExt`/`SinkExt` combinators, `join!`, `select!`/`select_biased!` (needs `FusedFuture` + `Unpin`), `executor::block_on`, `ThreadPool`, `channel::{mpsc, oneshot}`, `lock`, `io`, `AsyncRead`/`AsyncWrite` traits that differ from tokio's |
| **tower** 0.5 | Middleware abstraction | `trait Service<Req> { type Response; type Error; type Future; fn poll_ready(&mut self, cx) -> Poll<Result<(), Error>>; fn call(&mut self, req) -> Future; }`. **Backpressure is signalled through `poll_ready`**: callers must see `Ready(Ok)` before `call`, and `Pending` means the service is at capacity. `Layer` wraps one Service in another, and `ServiceBuilder` stacks them. Middleware: `timeout`, `limit` (rate and concurrency), `load_shed`, `retry`, `buffer` (an mpsc in front of a service), `balance`. Shared by hyper, tonic and axum |
| **hyper** 1.12 | HTTP/1 + HTTP/2 engine | `client` and `server` `conn` modules (low level: you drive one connection yourself), `body` (streaming through the `http-body` trait), `service`, `upgrade` (WebSocket and CONNECT). Features `http1`, `http2`, `client`, `server` (none on by default). Dropping a future cancels it, which closes the connection on h1 and resets only the stream on h2. Executors, pooling and graceful helpers live in **hyper-util** **[gk]**. The `http` crate supplies the `Request`, `Response`, `HeaderMap`, `Method`, `StatusCode` and `Uri` types **[gk]** |
| **axum** 0.8 | HTTP framework | `Router` with `.route("/p/{id}", get(h).post(h2))`. Handlers are async fns whose **extractors** implement `FromRequestParts`/`FromRequest` (`Path`, `Query`, `Json`, `State` (with `FromRef` substates), `Extension`, `HeaderMap`, `Form`, `Multipart`, `WebSocketUpgrade`) and whose return values implement **`IntoResponse`**. It has no middleware system of its own and uses tower layers (via tower-http: trace, cors, compression, timeout). `axum::serve(listener, app)` |
| **reqwest** 0.13 | HTTP client | An async `Client` to reuse (it pools connections), a `blocking` module, `json`/`form`/`multipart` bodies, `timeout`, proxies from `HTTP(S)_PROXY`, redirects (10 by default), an opt-in cookie store, HTTP/2 on by default, HTTP/3 unstable. **0.13 made rustls the default TLS** (aws-lc provider, rustls-platform-verifier for roots) **[changelog excerpts via search]** |
| **tonic** 0.14 + **prost** 0.14 | gRPC | tonic: gRPC over HTTP/2 on hyper and tower; `transport::{Channel, Server}` (load balancing, TLS, timeouts); `Request`/`Response`/`Streaming<T>`; `Status` + `Code`; interceptors; `gzip`/`zstd` compression; a 4 MB default decode limit; TLS features `tls-ring`/`tls-aws-lc` with webpki or native roots; codegen through `tonic-build`. prost: `#[derive(Message)]`, encodes and decodes over `bytes::Buf`/`BufMut`, `prost-build` (needs `protoc`) turns `.proto` into Rust modules, proto2 and proto3, **open enums** that keep unknown values, `prost-types` for the well-known types, no runtime reflection |
| **serde** + **serde_json** | Serialization | `#[derive(Serialize, Deserialize)]` over a data model, with each format (json, yaml, bincode and others) as a separate crate. **Field attrs:** `rename`, `alias`, `default`/`default="fn"`, `flatten`, `skip`, `skip_serializing`, `skip_deserializing`, `skip_serializing_if="fn"`, `with`/`serialize_with`/`deserialize_with`, `borrow` (zero-copy), `bound`. **Container attrs** include `rename_all`, `deny_unknown_fields`, `transparent` **[gk for the latter two]**. **Enum representations:** externally tagged (default), internally tagged `tag="type"`, adjacently tagged `tag="t", content="c"`, `untagged` (tries each variant in order). serde_json provides `Value`, `json!`, `from_str`/`to_string` and `RawValue`, and has an `arbitrary_precision` feature **[gk]** |
| **tracing** 0.1 + **tracing-subscriber** | Structured diagnostics | **Spans** (cover a period, nest, `#[instrument]`) and **events** (`info!`, `warn!` and the rest, with `key = value`, `?` for Debug and `%` for Display fields). The `Subscriber` trait, installed with `set_global_default` (libraries must not call it). `Instrument` attaches a span to a future; holding an `enter()` guard across `.await` gives wrong traces. tracing-subscriber provides the `fmt` subscriber, `EnvFilter`, and `Registry` + `Layer` composition **[gk]**. The `log` feature bridges to the log crate in both directions |
| **metrics** 0.24 | Metrics facade | `counter!`, `gauge!`, `histogram!` (plus `describe_*`). The `Recorder` trait is installed once globally and is a no-op until then. Key = name + labels. Exporters: `metrics-exporter-prometheus`, tcp |
| **opentelemetry** 0.33 | OTel API | Traces, metrics and logs (the logs bridge API is for appender authors). The SDK lives in `opentelemetry_sdk`, the exporter in `opentelemetry-otlp`. Context propagation, `propagation` (Propagator), `baggage`, `opentelemetry-http` for headers. `tracing-opentelemetry` bridges spans **[gk]** |
| **utoipa** 6 | OpenAPI, macro and code first | Derives `ToSchema`, `IntoParams`, `IntoResponses`/`ToResponse` and `OpenApi`; `#[utoipa::path(...)]` on handlers; OpenAPI 3.1 (module docs mention 3.2); partial implicit support for serde attributes; `utoipa-axum`, `utoipa-swagger-ui`; runtime changes through `Modify` |
| **aide** 0.15 | OpenAPI, builder and type-inferred | OpenAPI 3.1.0 only; schemas from **schemars** `JsonSchema`; `OperationInput`/`OperationOutput` traits on extractors and responses, so `Json<T>` documents itself; `aide::axum` (ApiRouter **[gk]**). It moved away from macro and global state toward functions and builders |
| **sqlx** 0.9 | Database | Async and pure Rust. Compile-time-checked `query!`/`query_as!`/`query_scalar!` (they check against a live DB, or against an offline `.sqlx` cache **[gk]**). Postgres, MySQL, SQLite. `Pool`/`PgPool`, `migrate!` + `Migrator`, `QueryBuilder`, `#[sqlx::test]`, runtime `tokio`, TLS through rustls or native-tls |
| **clap** 4.6 | CLI | Derive API (`Parser`, `Subcommand`, `Args`, `ValueEnum` with `#[arg]`/`#[command]`) or builder API (`Command`, `Arg`, `ArgGroup`, `ArgMatches`). `#[arg(env = "X")]` **[gk]**. `clap_complete` for shell completions, `clap_mangen` for man pages |
| **thiserror** 2 | Library errors | `#[derive(Error)]`, `#[error("msg {field}")]` for Display, `#[from]` (generates `From` and sets the source), `#[source]`, a `Backtrace` field, `#[error(transparent)]`. It stays out of your public API |
| **anyhow** 1 | Application errors | `anyhow::Error`/`Result` (a boxed trait object), `.context()`/`.with_context()`, `anyhow!`, `bail!`, `ensure!`, downcasting, automatic backtrace capture (`RUST_BACKTRACE`/`RUST_LIB_BACKTRACE`) |

---

## 3. Crypto and TLS

| Component | What it is |
|---|---|
| **rustls** 0.23 | TLS 1.2 and 1.3, client and server, in Rust. It is **sans-I/O**: no network, DNS or file access. `ClientConnection`/`ServerConnection` act as encrypted pipes (`read_tls`, `write_tls`, `process_new_packets`, `reader()`, `writer()`). Async integration through `tokio-rustls`. Certificate verification "cannot be turned off or disabled in the main API". There are no "unsafe features or obsolete cryptography by default". `tls12` is a default feature |
| **CryptoProvider** | A plug-in struct holding `cipher_suites`, `kx_groups`, `signature_verification_algorithms`, `secure_random` and `key_provider`. Built-in providers: **aws-lc-rs (the default)** and **ring (opt-in feature)**. Applications call `install_default()` early in `main` (once per process), while libraries use `get_default()`. You can also set one per config with `with_crypto_provider`, or use `custom-provider`, or a third-party provider (for example `rustls-rustcrypto`). The `prefer-post-quantum` feature (default) prefers **X25519MLKEM768** |
| **The split** | rustls code (handshake state machine, record layer, X.509 path validation via webpki) is memory-safe Rust. **Primitives** (AES-GCM, ChaCha20-Poly1305, X25519, ECDSA/RSA, SHA-2, HKDF, RNG) come from a provider whose core is **vetted C and assembly**. That is the model Eider could copy: the protocol in Eider, the primitives in an audited C/asm library behind a narrow FFI |
| **ring** | Brian Smith's crate. Most of its C and assembly **comes from BoringSSL** (an OpenSSL fork), with a Rust API on top. The README calls it "an experiment". Licensed Apache-2.0 + ISC + BoringSSL license. It was the historical rustls default |
| **aws-lc-rs** 1.19 | Wraps **AWS-LC** (AWS's BoringSSL-derived library) through `aws-lc-sys` and `aws-lc-fips-sys`. Its API is a **drop-in replacement for ring 0.16**. It needs std. The default build needs only a C compiler; the `fips` build also needs CMake and Go. **FIPS:** the `fips` feature uses AWS-LC-FIPS 4.x, which "completed validation testing" and is submitted to NIST for **FIPS 140-3** (check NIST's Modules-In-Progress list). The `fips` and `non-fips` features are mutually exclusive at compile time. In rustls, the `fips` feature routes through aws-lc-rs and changes the `require_ems` defaults |
| **rustls-webpki** 0.103 | The Web PKI X.509 validator rustls uses (a maintained fork of briansmith/webpki **[gk]**). Path building to trust anchors, name validation, EKU, **CRL revocation**, RFC 7250 raw public keys. Crypto backends (ring or aws-lc-rs) are features; `alloc`/`std` are features. Roots come from `webpki-roots` (a Mozilla bundle), `rustls-native-certs`, or **rustls-platform-verifier** (the OS verifier, now reqwest's default) **[gk + reqwest changelog]** |
| **RustCrypto** | Pure-Rust algorithm crates behind shared traits (`digest`, `cipher`, `aead`, `signature`, `password-hash`). hashes (SHA-2, SHA-3, BLAKE2), AEADs (`aes-gcm`, `chacha20poly1305`), elliptic-curves (P-256, P-384, k256), signatures (ECDSA, Ed25519, **ML-DSA**), `rsa`, password-hashes (Argon2, scrypt, PBKDF2), KEMs (**ML-KEM**), formats (DER, PEM, PKCS#8, X.509), `crypto-bigint`. The org page makes no audit or FIPS claims, and in my understanding individual crates vary in how much audit and constant-time assurance they have **[gk]** |
| **Current recommendation** | Default to rustls + aws-lc-rs (FIPS-capable, post-quantum key exchange). Use ring for simpler builds or wider target coverage. Use RustCrypto when you need pure Rust or no_std. Need FIPS? Turn on rustls `fips`; it switches to aws-lc-rs/FIPS. reqwest 0.13, tonic and sqlx all expose rustls feature flags |

---

## 4. Tooling for services

| Tool | What matters |
|---|---|
| Cargo features | The `[features]` table and `default`; `default-features = false`; optional deps with `dep:x`; `pkg/feat` and `pkg?/feat`. **Features must be additive** (prefer a `std` feature over a `no_std` one, and catch exclusive features with `compile_error!`). **Unification:** each crate is built once with the union of every requested feature. Resolver 2 stops unifying features for build-deps, proc-macros, dev-deps and inactive targets. `cargo tree -e features` shows who turned what on |
| Workspaces | `[workspace] members`, one shared `Cargo.lock` and `target/`, `workspace.dependencies` and `workspace.package` inheritance **[gk]** |
| Build scripts | `build.rs` runs before compilation and emits `cargo::rustc-link-lib`, `rerun-if-changed` and `rustc-cfg` directives. This is how `aws-lc-sys`, `prost-build`, `tonic-build` and the `cc` crate do their work, and it is also a supply-chain risk because it is arbitrary code at build time **[gk]** |
| Testing | `cargo test` runs `#[test]` unit tests, `tests/` integration tests, and **doc tests** (code blocks in `///` comments are compiled and run). `#[should_panic]`, `#[ignore]`, `#[tokio::test]`, `#[sqlx::test]`. `cargo bench` uses unstable built-in benches, so in practice **criterion** 0.8 is used (statistics-driven, `criterion_group!`/`criterion_main!`, `harness = false` **[gk]**, charts; its `black_box` is deprecated in favour of `std::hint::black_box`). cargo-nextest is the common faster runner **[gk]** |
| cargo-fuzz | Drives **libFuzzer** through `libfuzzer-sys` with `fuzz_target!`. It needs nightly and enables ASan by default; `arbitrary` gives structured input **[gk for those details]** |
| Miri | An interpreter that finds UB: out-of-bounds, use-after-free, uninitialised reads, misalignment, invalid values, **data races** (with some weak-memory emulation), Stacked/Tree Borrows aliasing (experimental), and leaks. It tests one execution at a time, has little FFI support and no networking, and finding no UB does not prove the code sound. Use loom for exhaustive atomic interleavings |
| clippy / rustfmt | Lint groups (correctness, suspicious, perf, pedantic, ...) and a single canonical formatter, both shipped with rustup **[gk]** |
| Supply chain | The crates.io index records a **SHA-256 `cksum`** per `.crate`, and `Cargo.lock` pins exact versions with checksums that Cargo verifies **[gk for the lockfile]**. Index entries are immutable except `yanked`. **RustSec** advisory DB → **cargo-audit** (scans `Cargo.lock`), **cargo-deny** (advisories, bans/duplicates, licenses, sources), **cargo-auditable** (embeds the dependency tree in the binary). Advisories export to OSV and GitHub Advisories. Also cargo-vet and cargo-crev **[gk]** |

---

## 5. Primitive → Rust's answer → layer

Layers: **OS** = a thin OS shim (Eider's C core); **RT** = an async runtime; **Lang** = the language or compiler; **std**; **Eco** = an ecosystem crate. ⚠ marks things an otherwise-complete language commonly forgets.

| Primitive | Rust's answer | Layer |
|---|---|---|
| Byte streams | `io::Read`/`Write`/`BufRead`/`Seek`, `copy`, `take`, vectored `IoSlice` | std (traits) + OS |
| Zero-copy shared buffers ⚠ | `bytes::Bytes`/`BytesMut`, `Buf`/`BufMut` | Eco |
| Monotonic time ⚠ | `Instant` (CLOCK_MONOTONIC / QPC), saturating arithmetic | OS + std |
| Wall-clock time | `SystemTime`, `UNIX_EPOCH` (calendar via `chrono`/`jiff`/`time` **[gk]**) | OS + std / Eco |
| Seeded, DoS-resistant hashing ⚠ | SipHash 1-3 with a per-map random seed from OS entropy (`RandomState`) | std + OS (entropy) |
| Secure RNG ⚠ | No stable std RNG; `getrandom`/`rand` crates | OS + Eco |
| Integer overflow policy ⚠ | Panic in debug, wrap in release; explicit `checked`/`wrapping`/`saturating`/`overflowing`/`strict` | Lang + std |
| Float parse and format round-trip ⚠ | `Display` gives shortest round-trip digits; `FromStr` gives the closest value; locale-independent | core |
| Float total order and NaN ⚠ | No `Ord`/`Eq`; `total_cmp`; `to_bits` | core |
| Endianness and wire ints | `to_be_bytes`/`from_le_bytes` | core |
| UTF-8 strings vs OS strings ⚠ | `str`/`String` (UTF-8) vs `OsStr`/`Path` (arbitrary bytes) | std |
| Error values and chaining | `Error` + `source()`, `?` via `From`, thiserror/anyhow | std + Eco |
| Backtraces | `std::backtrace`, env-gated | std + OS |
| Thread safety in the type system | `Send`/`Sync` auto traits | Lang |
| Locks, atomics, once-init | `Mutex`/`RwLock`/`Condvar`/atomics/`OnceLock`/`LazyLock` (poisoning) | std + OS (futex) |
| Structured threads | `thread::scope` | std |
| Future and poll protocol | `Future`, `Poll`, `Context`, `Waker`, `Pin`, `async`/`await` | Lang + core |
| Event loop and readiness | mio: epoll, kqueue, IOCP, event ports | OS + Eco |
| Scheduler | tokio work-stealing multi-thread or current-thread; `spawn_blocking` pool | RT |
| Timeouts ⚠ | `tokio::time::timeout`, tower `timeout`, reqwest/tonic timeouts | RT + Eco |
| Cancellation ⚠ | Drop the future, `select!`, `CancellationToken` (tree), JoinSet abort; documented **cancel-safety** | Lang + RT |
| Backpressure ⚠ | Bounded `mpsc` (send waits), `Semaphore`, tower `poll_ready`, `load_shed`, `buffer` | RT + Eco |
| Structured concurrency ⚠ | `JoinSet` (abort on drop), `TaskTracker` | RT |
| Graceful shutdown ⚠ | `signal::ctrl_c` → `CancellationToken` → `TaskTracker::wait`; `with_graceful_shutdown` | RT + Eco |
| Channels | std `mpsc`; tokio `mpsc`/`oneshot`/`broadcast`/`watch` | std / RT |
| Signals | `tokio::signal` | OS + RT |
| Subprocesses | `std::process::Command`, `tokio::process` | OS + std/RT |
| Middleware composition | tower `Service` + `Layer` | Eco |
| HTTP/1.1 and HTTP/2 | hyper (+ the `http` types, hyper-util) | Eco |
| Routing and extractors | axum `Router`, `FromRequest`, `IntoResponse` | Eco |
| HTTP client | reqwest (pooling, rustls default) | Eco |
| gRPC and protobuf | tonic + prost (`protoc` codegen in `build.rs`) | Eco |
| Serialization with schema control | serde derive + attributes (rename, default, flatten, skip_if, tag/content/untagged) | Lang (derive macros) + Eco |
| OpenAPI generation | utoipa (macros) or aide (schemars + types) | Eco |
| Logging, tracing, metrics ⚠ | tracing spans across `.await`, metrics facade, OpenTelemetry/OTLP, context propagation | Eco |
| TLS ⚠ | rustls (Rust protocol) + aws-lc-rs/ring (C/asm primitives) + webpki | Eco + vetted C |
| FIPS ⚠ | aws-lc-rs `fips` (AWS-LC-FIPS, FIPS 140-3 submission) | Eco + C |
| Post-quantum key exchange | X25519MLKEM768 by default in rustls/aws-lc-rs | Eco |
| Database | sqlx (async, compile-time-checked SQL, pools, migrations) | Eco |
| CLI and config | clap derive, `env` | Eco |
| Env and args | `std::env` (`set_var` is unsafe because it is thread-unsafe ⚠) | std + OS |
| Panics and process exit | `panic::set_hook`, `catch_unwind`, `ExitCode` | std |
| Test, bench, fuzz, UB check | `cargo test` + doc tests, criterion, cargo-fuzz, Miri, loom | Tooling |
| Supply chain ⚠ | Lockfile checksums, RustSec, cargo-audit/deny/auditable | Tooling |

### Lessons for Eider

1. **Rust leaves the async runtime, `Stream` and RNG out of std.** The cost is ecosystem fragmentation: tokio and futures have different `AsyncRead` traits. Eider can ship one blessed runtime, buffer type and `Stream` in its std.
2. **Cancellation-by-drop needs documented cancel-safety on every API.** Rust learned this late (see the tokio select! list). Eider should design it in, for example through a type-level or capability marker, or by making cancellation points explicit.
3. **Backpressure needs to be a protocol and not a convention.** tower's `poll_ready` exists for exactly this. Bounded channels should be the default, and unbounded ones should be explicit.
4. **Seed the hasher randomly by default**, with a deterministic hasher you have to ask for by name. Expose monotonic time separately from wall time. Make float Display round-trip and locale-free.
5. **Copy rustls's sans-I/O protocol, pluggable provider design:** write the TLS state machine in Eider and keep the primitives in AWS-LC or BoringSSL C/asm. That fits a "tiny C core" naturally, and you get FIPS for free from AWS-LC-FIPS.
6. **Make features additive and keep build scripts sandboxed.** Feature unification and arbitrary `build.rs` code are a recurring source of Rust supply-chain and build problems.

---

## Sources (pages opened)

- https://doc.rust-lang.org/std/index.html
- https://doc.rust-lang.org/std/io/index.html
- https://doc.rust-lang.org/std/sync/index.html
- https://doc.rust-lang.org/std/time/struct.Instant.html
- https://doc.rust-lang.org/std/thread/fn.scope.html
- https://doc.rust-lang.org/std/collections/hash_map/struct.HashMap.html
- https://doc.rust-lang.org/std/hash/index.html
- https://doc.rust-lang.org/std/fmt/index.html
- https://doc.rust-lang.org/std/primitive.f64.html
- https://doc.rust-lang.org/std/primitive.u32.html
- https://doc.rust-lang.org/std/error/trait.Error.html
- https://doc.rust-lang.org/std/task/struct.Waker.html
- https://doc.rust-lang.org/std/marker/trait.Send.html
- https://doc.rust-lang.org/reference/expressions/operator-expr.html
- https://doc.rust-lang.org/stable/src/core/fmt/float.rs.html (via search result; float Display uses Grisu `format_shortest`)
- https://doc.rust-lang.org/cargo/reference/features.html
- https://doc.rust-lang.org/cargo/reference/registry-index.html
- https://docs.rs/tokio/latest/tokio/
- https://docs.rs/tokio/latest/tokio/sync/mpsc/index.html
- https://docs.rs/tokio/latest/tokio/macro.select.html
- https://docs.rs/tokio/latest/tokio/task/struct.JoinSet.html
- https://docs.rs/tokio/latest/tokio/time/index.html
- https://docs.rs/tokio-util/latest/tokio_util/sync/struct.CancellationToken.html
- https://tokio.rs/tokio/topics/shutdown
- https://docs.rs/mio/latest/mio/ and https://docs.rs/mio/latest/mio/struct.Poll.html
- https://docs.rs/bytes/latest/bytes/
- https://docs.rs/futures/latest/futures/
- https://docs.rs/tower/latest/tower/ and https://docs.rs/tower-service/latest/tower_service/trait.Service.html
- https://docs.rs/hyper/latest/hyper/
- https://docs.rs/axum/latest/axum/
- https://docs.rs/reqwest/latest/reqwest/ (+ 0.13 changelog excerpts via search, e.g. https://dependabot.ecosyste.ms/hosts/GitHub/repositories/Shopify%2Ffunction-runner/issues/552)
- https://docs.rs/tonic/latest/tonic/
- https://docs.rs/prost/latest/prost/
- https://serde.rs/attributes.html, https://serde.rs/field-attrs.html, https://serde.rs/enum-representations.html
- https://docs.rs/tracing/latest/tracing/
- https://docs.rs/metrics/latest/metrics/
- https://docs.rs/opentelemetry/latest/opentelemetry/
- https://docs.rs/utoipa/latest/utoipa/
- https://docs.rs/aide/latest/aide/
- https://docs.rs/sqlx/latest/sqlx/
- https://docs.rs/clap/latest/clap/
- https://docs.rs/thiserror/latest/thiserror/
- https://docs.rs/anyhow/latest/anyhow/
- https://docs.rs/rustls/latest/rustls/ and https://docs.rs/rustls/latest/rustls/crypto/struct.CryptoProvider.html
- https://docs.rs/rustls-webpki/latest/webpki/
- https://docs.rs/aws-lc-rs/latest/aws_lc_rs/
- https://github.com/briansmith/ring
- https://github.com/RustCrypto
- https://github.com/rust-lang/miri
- https://rust-fuzz.github.io/book/cargo-fuzz.html
- https://docs.rs/criterion/latest/criterion/
- https://embarkstudios.github.io/cargo-deny/
- https://rustsec.org/
