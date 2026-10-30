# Core runtime

`core/eider_rt.h` + `core/eider_rt.c` are the language runtime: the C that generated code
calls for traps, checked arithmetic, allocation, `String`, `print`, the clock, and the
type-independent half of threads. The self-hosted compiler emits `#include "eider_rt.h"`
and links `eider_rt.c`. The retired stage-0 compiler pasted an equivalent runtime into every
program as string literals (`eider-bootstrap/src/prelude.rs`, plus runtime C in `src/heap.rs`
and `src/closure.rs`); this file is the contract that replaced it, with the same observable
behaviour (trap messages, exit code 101, print formats), because the language contract tests
compare program output.

## How the two core files relate

| File | Role | Called by | Contract |
|---|---|---|---|
| `eider_core.c` | OS ABI: one OS operation per function, errors as `-errno`, data through byte buffers | Eider code, through `extern "c"` bindings in `core/sys.ei` | `core/ABI.md` |
| `eider_rt.h` / `eider_rt.c` | Language runtime: what the semantics of the language need | generated C only, never Eider source | this file |

They are independent (neither includes the other) and share only the process's `stdout`:
`print` is buffered by stdio and `ec_write_fd` / `ec_exit` flush it first, so the two kinds
of output stay in program order. Both build warning-free with
`-std=c11 -pedantic -Wall -Wextra -Wconversion -Wshadow` (checked by `tests/core/run.sh`).
Runtime symbols are ordinary C names called from C, so they need none of the raw-symbol
pinning (`EC_SYM`) that the OS ABI uses for `extern "c"`.

## Rules

1. **Only what the semantics need.** Each function is one language operation (a checked add,
   a bounds check, a String append, a channel send). No policy, no formatting beyond the
   fixed `print` formats, no OS interop beyond stdio, `malloc`, `clock` and POSIX threads.
2. **Per-type code stays generated.** Anything that depends on a concrete Eider type is
   compiler output (see the inventory below). The runtime offers type-independent pieces
   (allocation with overflow checks, a byte-sized channel queue, a reference count) that the
   generated glue builds on.
3. **Fixed-width types only:** `int32_t`, `int64_t`, `uint8_t`, `uint32_t`, `uint64_t`,
   `bool`, `const char *`. Sizes are `uint64_t` (Eider `usize` is `uint64_t` on every
   target). Source lines are `int32_t`.
4. **No undefined or implementation-defined integer behaviour.** No signed overflow; no
   out-of-range conversion to a signed type (wrapping results go through `ei_bits_i32` /
   `ei_bits_i64`); no out-of-range float-to-integer conversion.
5. **Builtins only behind feature checks.** `__builtin_*_overflow` is used when
   `__has_builtin` reports it, `__builtin_unreachable` under `__GNUC__`; `-DEI_RT_PORTABLE`
   forces the portable code. Both paths are tested.
6. **Errors trap.** Runtime functions do not return error codes: a failed check or a failed
   allocation calls `ei_trap`.

## Traps

`_Noreturn void ei_trap(const char *msg, int32_t line)` is the only way a program stops on a
runtime error. It flushes `stdout`, then:

| This thread | Output | Then |
|---|---|---|
| has a test hook | `FAILED\n    <msg> (<file>:<line>)\n` on stdout, flushed | `longjmp(*hook, 1)` |
| has no hook | `eider: runtime error: <msg> (<file>:<line>)\n` on stderr | `exit(101)` |

`<file>` is set by `void ei_set_file(const char *)` (generated `main`, and every exported
library entry point; an atomic pointer, so concurrent entries are not a data race). It is
`""` until set. Line `0` means "no source line" (allocation and thread failures).

Messages generated code relies on, all byte-identical to stage 0:

| Message | Raised by |
|---|---|
| `integer overflow in +` / `-` / `*` / `/` / `%` | checked arithmetic |
| `integer overflow in negation` | `ei_neg_*` |
| `division by zero`, `remainder by zero` | `ei_div_*`, `ei_rem_*` |
| `integer conversion out of range` | `ei_s2s`, `ei_s2u`, `ei_u2s`, `ei_u2u` |
| `index out of bounds` | `ei_idx` |
| `out of memory` (line 0) | `ei_alloc`, `ei_alloc_n`, `ei_str_*`, `ei_chan_send` |
| `send on a closed channel` (line 0) | `ei_chan_send` |
| `cannot create a thread` (line 0) | `ei_thread_start` |
| any `panic` / `assert` text | generated code calls `ei_trap` directly |

New in the core (stage 0 ignored these failures): `cannot create a mutex`,
`cannot lock a mutex`, `cannot unlock a mutex`, `cannot join a thread`,
`cannot create a channel` (all line 0).

Several threads trapping at once: the first one without a hook takes a process-wide lock that
is never released, reports, and exits; the others block on it until the process ends. So
there is exactly one report and `exit` never runs concurrently with itself.

### The test hook

`void ei_set_trap_jmp(jmp_buf *jb)` sets this thread's hook (`NULL` clears it). `setjmp` has
to run in the caller's frame, so generated test `main` does:

```c
jmp_buf jb;
ei_set_trap_jmp(&jb);
ei_set_file("tests/x.ei");
/* per test */
printf("test %s ... ", name); fflush(stdout);
if (setjmp(jb) == 0) { t_1(); printf("ok\n"); } else { failed++; }
```

The hook is thread-local: a trap on a thread spawned by a test exits the whole test binary
with 101 (as in stage 0). A `longjmp` out of a failed test does not run drops, so values owned
by the failed test leak, and a lock held at the moment of the trap stays held (for example a
trap inside a `Mutex.update` closure). Tests after it that use the same Mutex deadlock.

## Inline (in the header) vs out of line (in the .c)

| In `eider_rt.h`, `static inline` | In `eider_rt.c` |
|---|---|
| `ei_idx`, all checked/wrapping arithmetic, `ei_bits_*`, conversions, `ei_hash_u64`, `ei_unreachable()` (macro) | `ei_trap`, `ei_set_file`, `ei_set_trap_jmp`, allocation (`ei_alloc`, `ei_alloc_n`, `ei_free`, `ei_check_leaks`), `String`, `ei_hash_str`, print, clock, threads |

The inline set is what sits on every arithmetic expression and index. Each takes the
fast path in a compare and a branch to the out-of-line `ei_trap`.

## Integer arithmetic

For `N` in `i32 i64 u8 u32 u64` (Eider `usize` uses the `u64` functions), with `T` the C type:

| Function | Result |
|---|---|
| `T ei_add_N(T a, T b, int32_t line)`, `ei_sub_N`, `ei_mul_N` | exact result, or trap `integer overflow in +/-/*` |
| `T ei_div_N(T a, T b, int32_t line)` | `a / b` truncated toward zero; traps on `b == 0`, and on `MIN / -1` for signed |
| `T ei_rem_N(T a, T b, int32_t line)` | `a % b` (sign of `a`); traps on `b == 0`, and on `MIN % -1` for signed |
| `T ei_neg_N(T a, int32_t line)` (signed only) | `-a`, traps on `MIN` |
| `T ei_wadd_N(T a, T b)`, `ei_wsub_N`, `ei_wmul_N` | result modulo 2^bits, two's complement for signed |
| `int32_t ei_bits_i32(uint32_t)`, `int64_t ei_bits_i64(uint64_t)` | two's-complement reinterpretation, defined for every input |

i32, u8 and u32 compute exactly in 64 bits and range-check. i64 and u64 use the overflow
builtins when present, else pre-checks that cannot overflow themselves.

## Conversions and bounds

| Function | Result |
|---|---|
| `int64_t ei_s2s(int64_t v, int64_t lo, int64_t hi, int32_t line)` | `v` if `lo <= v <= hi`, else trap |
| `uint64_t ei_s2u(int64_t v, uint64_t hi, int32_t line)` | `v` if `0 <= v <= hi`, else trap |
| `int64_t ei_u2s(uint64_t v, int64_t hi, int32_t line)` | `v` if `v <= hi`, else trap (`hi >= 0`) |
| `uint64_t ei_u2u(uint64_t v, uint64_t hi, int32_t line)` | `v` if `v <= hi`, else trap |
| `uint64_t ei_idx(uint64_t i, uint64_t n, int32_t line)` | `i` if `i < n`, else trap `index out of bounds` |

Generated code widens the source to 64 bits, passes the target type's limits, and casts the
in-range result: `(uint8_t)ei_s2u((int64_t)x, UINT8_MAX, 12)`.

## Allocation and String

| Function | Contract |
|---|---|
| `void *ei_alloc(uint64_t n)` | never `NULL`; `n == 0` allocates 1 byte; traps `out of memory` (also when `n` does not fit `size_t`). Free with `free`. |
| `void *ei_alloc_n(uint64_t n, uint64_t size)` | `n * size` bytes; traps if the product overflows. Generated List/Map/clone growth uses this. |
| `void ei_free(void *p)` | frees memory from `ei_alloc`/`ei_alloc_n` (`NULL` is a no-op); generated glue and the runtime free through it |
| `void ei_check_leaks(void)` | built with `-DEI_RT_COUNT_ALLOCS`, the runtime counts live allocations (atomically) and this prints `eider: outstanding allocations: <n>` to stderr; otherwise it does nothing. Generated `main` calls it when the program ends normally (test mode: only if no test failed). A leak check for test suites where ASan is not available. |
| `ei_String` | `{ char *p; uint64_t len; }`, NUL-terminated, `len` excludes the NUL |
| `ei_str_from(const char *)`, `ei_str_from_i64(int64_t)` | new String (decimal, `-` for negatives) |
| `ei_clone_String(const ei_String *)`, `ei_drop_String(ei_String *)` | deep copy; free (sets `p = NULL`, `len = 0`; a second drop is harmless) |
| `ei_str_cat(s, t, tl)`, `ei_str_push(s, cstr)`, `ei_str_append(s, const ei_String *)` | append; `t` may point into `s` (self-append works); traps if the length overflows |
| `uint64_t ei_hash_u64(uint64_t)`, `uint64_t ei_hash_str(const char *)` | Map key hashes: murmur3 finalizer; FNV-1a up to the NUL, then the finalizer. Bit-identical to stage 0. |

Strings never contain NUL (they are built from literals and decimal numbers), so `print`,
`==` (`strcmp`) and `ei_hash_str` all agree on where a String ends.

## Print and clock

| Function | Output on stdout |
|---|---|
| `ei_print_i(int64_t)`, `ei_print_u(uint64_t)` | decimal, then `\n` |
| `ei_print_b(bool)` | `true` / `false`, then `\n` |
| `ei_print_s(const char *)` | the bytes up to the NUL, then `\n` |
| `uint64_t ei_now_ms(void)` | processor time used by the process in ms (`clock()`, as in stage 0); `0` if unavailable |

`now_ms` is CPU time, not wall-clock time: it does not advance while the program sleeps or
blocks, and it sums over threads. Keeping it is a stage-0 compatibility decision; a monotonic
wall clock belongs in `eider_core.c` if the language wants one.

## Threads

Generated per-type structs embed these and add the typed payload. All functions trap on
failure of the underlying primitive.

| Type / function | Contract |
|---|---|
| `ei_rc` (`atomic_uint_least64_t`), `ei_rc_init` (=1), `ei_rc_inc`, `bool ei_rc_dec` | shared-handle count (`Task`, `Mutex`, `Chan`); `ei_rc_dec` returns `true` for the last reference, and only that caller frees. Sequentially consistent. |
| `ei_mutex`, `ei_mutex_init/lock/unlock/destroy` | an error-checking `pthread_mutex_t`: locking it again on the thread that holds it (a `Mutex.update` closure using the same Mutex) traps `cannot lock a mutex` instead of being undefined (stage 0 deadlocks) |
| `ei_thread`, `ei_thread_start(t, run, arg)` | starts `run(arg)` |
| `ei_thread_join(t)` | waits once; safe from several threads at once and repeatedly (`Task.join` on shared handles) |
| `ei_thread_destroy(t)` | joins if needed, then releases; last owner only |
| `ei_chan`, `ei_chan_init(c, elem_size)` | unbounded FIFO of `elem_size`-byte values (0 is allowed) |
| `ei_chan_send(c, const void *elem)` | copies the element in and wakes a receiver; traps `send on a closed channel` (the lock is released first) |
| `bool ei_chan_recv(c, void *out)` | blocks until a value (copied out, `true`) or closed and empty (`false`) |
| `ei_chan_close(c)` | wakes all receivers; idempotent |
| `ei_chan_len(c)`, `ei_chan_at(c, i)` | queued values, oldest first, so the drop glue can drop them; sole owner only |
| `ei_chan_destroy(c)` | frees the queue; does not drop queued values |

Values move through a channel by `memcpy`: ownership moves with the bytes, so the sender
must not drop what it sent. That is the same move semantics stage 0 has.

Shape of the generated glue for `Chan[T]`:

```c
struct CH_T_c { ei_rc rc; ei_chan ch; };
CH_T ei_chnew_T(void) { CH_T c; c.p = ei_alloc(sizeof *c.p); ei_rc_init(&c.p->rc); ei_chan_init(&c.p->ch, sizeof(T)); return c; }
void ei_chsend_T(const CH_T *c, T v) { ei_chan_send(&c->p->ch, &v); }
void ei_drop_CH_T(CH_T *x) { if (x->p && ei_rc_dec(&x->p->rc)) { for (uint64_t i = 0; i < ei_chan_len(&x->p->ch); i++) ei_drop_T(ei_chan_at(&x->p->ch, i)); ei_chan_destroy(&x->p->ch); free(x->p); } x->p = NULL; }
```

## Inventory of the stage-0 runtime

(History: the inventory made while porting.) Every piece of runtime C in stage 0, and where it goes (`P` = `src/prelude.rs`,
`H` = `src/heap.rs`, `C` = `src/closure.rs`, `K` = `src/check.rs`).

### Core (`eider_rt`)

| Stage 0 | Core |
|---|---|
| `ei_trap`, `ei_jb`, `ei_file` (P:13-30) | `ei_trap`, `ei_set_trap_jmp`, `ei_set_file` |
| `ei_unreachable` (P:14-18) | same macro |
| `ei_idx` (P:32) | same |
| `ei_s2s/s2u/u2s/u2u` (P:37-40) | same |
| `ei_alloc` (P:42) | same, plus `ei_alloc_n` for the `n * sizeof(T)` call sites (H:307, 366, 400, 437, 496) |
| `ei_String`, `ei_str_from`, `ei_str_from_i64`, `ei_drop_String`, `ei_clone_String`, `ei_str_cat/push/append` (P:48-67) | same |
| `ei_hash_u64`, `ei_hash_str` (P:68-75) | same |
| `ei_print_i/u/b/s` (P:77-80) | same (`int64_t`/`uint64_t` instead of `long long`) |
| `ei_now_ms` (P:81) | same |
| arithmetic templates `SMALL_SIGNED` (i32), `SMALL_UNSIGNED` (u8, u32), `I64`, `U64` (P:84-162) | written out per type; usize uses u64 (stage-0 `IntTy::h`) |
| refcount `atomic_int rc` + `atomic_fetch_*` (H:334-335, 418, 434, 456) | `ei_rc` |
| `pthread_mutex_*` in Mutex/Task/Chan (H:418-460) | `ei_mutex` |
| Task thread start/join-once/destroy (H:319, 456-460) | `ei_thread` |
| Chan queue: ring buffer, cond var, closed flag, send/recv/close (H:434-441, 330-331) | `ei_chan` (type-erased by element size) |

### Generated (stays compiler output)

| Stage 0 | Why it is per type |
|---|---|
| `ei_drop_X` / `ei_clone_X` for records, tuples, enums, arrays, List, Map, Box, Fn, Task/Mutex/Chan handles (H:239-378) | walks the fields of a concrete type |
| `ei_eq_X` (H:192-237) and the inline `==` for String/str (`strcmp`, K:1130) | structural equality per type |
| `ei_push_X`, `ei_has_X` (List, H:395-405); `pop`, `get`, `map`/`filter`/`fold`/`sum` loops (H:662-878) | monomorphized element type |
| `ei_mfind/mget/minsert/mremove_X` (Map, H:469-499), hash dispatch (H:380-386) | key/value types; calls `ei_hash_*`, `ei_alloc_n` |
| `ei_bnew_X` (Box, H:464-468) | element type |
| `ei_mxnew/mxget/mxset/mxupd_X` (Mutex, H:406-425) | typed value + clone/drop; uses `ei_mutex`, `ei_rc` |
| `ei_chnew/chsend/chrecv/chclose_X` (Chan, H:426-444) | thin typed wrappers over `ei_chan` |
| `ei_spawn_X`, `ei_tkmain_X`, `ei_tkjoin_X` (Task, H:445-463) | typed closure and result; uses `ei_thread`, `ei_rc` |
| closure environments `ei_envdrop_N`, `ei_envclone_N`, `F_X` structs (C:193-224) | captured variables per closure |
| unit-enum name tables `T_names[]` (printed with `ei_print_s`) | per enum |
| `main`, the test driver loop, exported `eider_*` entry points (K:1188-1217) | per program |

## Portability

- C11 with `<stdatomic.h>` (refused at compile time under `__STDC_NO_ATOMICS__`) and
  `_Thread_local`, plus POSIX threads (`-pthread`). Generated programs already link pthreads.
- Exact-width integer types are two's complement by definition in C11, so `ei_bits_*` is
  only there to avoid the implementation-defined *conversion*; it compiles to nothing.
- `ei_alloc` checks `n` against `SIZE_MAX`, so 32-bit targets trap instead of truncating.
- `ei_rc` is 64-bit atomic. On 32-bit targets that may not be lock-free, which is correct but
  slower.
- Exercised: Linux (glibc), x86-64, gcc, with and without builtins, and under
  UBSan in trap mode (`-fsanitize=undefined -fsanitize-trap=undefined`, needs no runtime
  library). ASan and TSan run when the toolchain has their runtimes (`tests/core/run.sh`
  probes and skips otherwise).
- WebAssembly: `core/wasm/eider_rt.c` is the wasm32 backend of this contract, over the
  freestanding C library `core/wasm/libc.c` (`core/wasm/README.md`). Same header, same
  functions; one thread (`ei_mutex_*` do nothing, `ei_thread_*`/`ei_chan_*` trap; programs
  with threads are rejected, E0806), traps end in `unreachable` instead of `exit(101)`, and
  `ei_now_ms` is the host clock.
- Windows: not written (needs a threads backend, like `eider_core`).

## Known gaps carried from stage 0

- `ei_str_cat` builds a new buffer on every append, so a loop of `push_str` is quadratic.
  Fixing that needs a capacity field in `ei_String`, which changes the generated layout.
- Traps do not unwind: no drops run (irrelevant when exiting; a leak and possibly a held lock
  in `test` mode, see above).
- `ei_trap` called while a runtime lock is held (an allocation failure during `ei_chan_send`
  growth) leaves that lock held. Only reachable on out-of-memory.
