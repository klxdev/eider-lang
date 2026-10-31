# Core runtime

`core/eider_rt.h` + `core/eider_rt.c` are the language runtime: the C that generated code
calls for traps, checked arithmetic, allocation, `String`, `print`, the clock, and the
type-independent half of threads. The self-hosted compiler emits `#include "eider_rt.h"`
and links `eider_rt.c`. This file is its contract. Its observable behaviour (trap messages,
exit code 101, print formats) is fixed by the recorded expectations (`tests/oracle/`),
because the language contract tests compare program output.

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

Messages generated code relies on, all byte-identical to the recorded expectations:

| Message | Raised by |
|---|---|
| `integer overflow in +` / `-` / `*` / `/` / `%` | checked arithmetic |
| `integer overflow in negation` | `ei_neg_*` |
| `division by zero`, `remainder by zero` | `ei_div_*`, `ei_rem_*` |
| `integer conversion out of range` | `ei_s2s`, `ei_s2u`, `ei_u2s`, `ei_u2u` |
| `index out of bounds` | `ei_idx` |
| `out of memory` (line 0) | `ei_alloc`, `ei_alloc_n`, `ei_buf_alloc`, `ei_buf_grow`, `ei_grow_cap`, `ei_str_*`, `ei_chan_send` |
| `send on a closed channel` (line 0) | `ei_chan_send` |
| `cannot create a thread` (line 0) | `ei_thread_start` |
| any `panic` / `assert` text | generated code calls `ei_trap` directly |

Also reported (failures the recorded expectations never exercise): `cannot create a mutex`,
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
with 101. A `longjmp` out of a failed test does not run drops, so values owned
by the failed test leak, and a lock held at the moment of the trap stays held (for example a
trap inside a `Mutex.update` closure). Tests after it that use the same Mutex deadlock.

## Inline (in the header) vs out of line (in the .c)

| In `eider_rt.h`, `static inline` | In `eider_rt.c` |
|---|---|
| `ei_idx`, all checked/wrapping arithmetic, `ei_bits_*`, conversions, `ei_hash_u64`, the buffer counts (`ei_buf_h/inc/dec/shared/count`), `ei_unreachable()` (macro) | `ei_trap`, `ei_set_file`, `ei_set_trap_jmp`, allocation (`ei_alloc`, `ei_alloc_n`, `ei_free`, `ei_check_leaks`, `ei_buf_alloc/grow/free`, `ei_grow_cap`), `String`, `ei_hash_str`, print, clock, threads |

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
| `ei_String` | `{ char *p; uint64_t len; uint64_t cap; }`, NUL-terminated, `len` excludes the NUL; `p` is a shared buffer (below) of `cap + 1` bytes |
| `ei_str_from(const char *)`, `ei_str_from_i64(int64_t)` | new String (decimal, `-` for negatives), `cap == len` |
| `ei_share_String(const ei_String *)` | a copy that shares the buffer (one more holder; O(1)); generated code calls this |
| `ei_clone_String(const ei_String *)` | a copy with a buffer of its own (`cap == len`). Code from an eiderc before copy-on-write calls it, so such programs (and the seed until it is regenerated) stay correct against this core |
| `ei_drop_String(ei_String *)` | one holder fewer, freed by the last (sets `p = NULL`, `len = cap = 0`; a second drop is harmless) |
| `ei_str_unique(ei_String *)` | gives the String a buffer of its own: copies it only when it is shared |
| `ei_str_cat(s, t, tl)`, `ei_str_push(s, cstr)`, `ei_str_append(s, const ei_String *)` | append: in place when the buffer is `s`'s own and has room, else into a new buffer of amortised capacity (at least double, at least 15 bytes), built before the old one is let go, so `t` may point into `s` (self-append works); traps if the length overflows |
| `uint64_t ei_hash_u64(uint64_t)`, `uint64_t ei_hash_str(const char *)` | Map key hashes: murmur3 finalizer; FNV-1a up to the NUL, then the finalizer. Bit-identical to the recorded expectations. |

Strings never contain NUL (they are built from literals and decimal numbers), so `print`,
`==` (`strcmp`) and `ei_hash_str` all agree on where a String ends.

## Shared buffers (copy-on-write)

`String`, `List[T]`, `Map[K, V]` and `Box[T]` share their heap buffer between copies. A
buffer is an allocation with a 16-byte header `ei_buf_hdr { uint64_t n; uint64_t unused; }`
(the count of holders; 16 bytes keep malloc's alignment for the data) followed by the data;
values point at the data, so a NULL pointer is an empty buffer with no holders. A copy is
`ei_buf_inc`; a value whose buffer is shared (`ei_buf_shared`) copies it before any change
(per-type `uniq_` glue, `ei_str_unique`, inside `ei_str_cat`); a drop is `ei_buf_dec`, and the
caller that gets `true` (the last holder) drops the elements once and calls `ei_buf_free`.

| Function | Contract |
|---|---|
| `void *ei_buf_alloc(uint64_t n, uint64_t size)` | a buffer of `n * size` bytes, count 1; traps `out of memory` if the size overflows |
| `void *ei_buf_grow(void *d, uint64_t n, uint64_t size)` | resizes a buffer with one holder (or `NULL`: a new one) to `n * size` bytes, keeping the contents (`realloc`: still one allocation for the counter) |
| `void ei_buf_free(void *d)` | frees it whatever the count (`NULL` is a no-op) |
| `ei_buf_inc(d)`, `bool ei_buf_dec(d)`, `bool ei_buf_shared(d)`, `uint64_t ei_buf_count(d)` (inline) | one more holder; one fewer, `true` when it was the last; more than one holder; the count (0 for `NULL`; tests) |
| `uint64_t ei_grow_cap(uint64_t cap, uint64_t len, uint64_t extra, uint64_t min)` | the amortised capacity for `len + extra` elements: `max(2 * cap, len + extra, min)` (doubling saturates at `UINT64_MAX`, which then fails to allocate); traps `out of memory` if `len + extra` overflows. List and Map growth and `ei_str_cat` use it |

**Counts are not atomic**, which is sound because a buffer is reachable from one thread at a
time: before a value crosses to another thread the generated glue makes every buffer it
reaches its own (`own_` glue: `uniq` at every level). That happens to `spawn`'s closure
(through the fn value's `own` hook, which owns the captures), to the value given to
`Mutex.new`, `Mutex.set` and `Chan.send`, to the result of a `Mutex.update` closure (under the
lock), and to the copies `Mutex.get` and `Task.join` hand out (made and owned under the
Mutex's lock, or the Task's own lock, since joins may run on several threads at once). The
shared handles themselves (`ei_rc`) stay atomic.

## Print and clock

| Function | Output on stdout |
|---|---|
| `ei_print_i(int64_t)`, `ei_print_u(uint64_t)` | decimal, then `\n` |
| `ei_print_b(bool)` | `true` / `false`, then `\n` |
| `ei_print_s(const char *)` | the bytes up to the NUL, then `\n` |
| `uint64_t ei_now_ms(void)` | processor time used by the process in ms (`clock()`); `0` if unavailable |

`now_ms` is CPU time, not wall-clock time: it does not advance while the program sleeps or
blocks, and it sums over threads. Keeping it is a compatibility decision (the recorded behaviour); a monotonic
wall clock belongs in `eider_core.c` if the language wants one.

## Threads

Generated per-type structs embed these and add the typed payload. All functions trap on
failure of the underlying primitive.

| Type / function | Contract |
|---|---|
| `ei_rc` (`atomic_uint_least64_t`), `ei_rc_init` (=1), `ei_rc_inc`, `bool ei_rc_dec` | shared-handle count (`Task`, `Mutex`, `Chan`); `ei_rc_dec` returns `true` for the last reference, and only that caller frees. Sequentially consistent. |
| `ei_mutex`, `ei_mutex_init/lock/unlock/destroy` | an error-checking `pthread_mutex_t`: locking it again on the thread that holds it (a `Mutex.update` closure using the same Mutex) traps `cannot lock a mutex` instead of being undefined (a plain mutex would deadlock) |
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
must not drop what it sent. That is the language's move semantics.

Shape of the generated glue for `Chan[T]`:

```c
struct CH_T_c { ei_rc rc; ei_chan ch; };
CH_T ei_chnew_T(void) { CH_T c; c.p = ei_alloc(sizeof *c.p); ei_rc_init(&c.p->rc); ei_chan_init(&c.p->ch, sizeof(T)); return c; }
void ei_chsend_T(const CH_T *c, T v) { ei_chan_send(&c->p->ch, &v); }
void ei_drop_CH_T(CH_T *x) { if (x->p && ei_rc_dec(&x->p->rc)) { for (uint64_t i = 0; i < ei_chan_len(&x->p->ch); i++) ei_drop_T(ei_chan_at(&x->p->ch, i)); ei_chan_destroy(&x->p->ch); free(x->p); } x->p = NULL; }
```

## What is core and what is generated

The rule: anything that does not depend on a concrete type is in the core; anything that
walks or is parameterised by a concrete type stays compiler output.

### Core (`eider_rt`)

| Piece | Core |
|---|---|
| traps, the test hook, the source file name | `ei_trap`, `ei_set_trap_jmp`, `ei_set_file` |
| unreachable code | the `ei_unreachable` macro |
| index checks, integer conversions | `ei_idx`, `ei_s2s/s2u/u2s/u2u` |
| allocation | `ei_alloc`, plus `ei_alloc_n` for the `n * sizeof(T)` call sites |
| shared buffers (copy-on-write) | `ei_buf_hdr`, `ei_buf_alloc/grow/free`, `ei_buf_inc/dec/shared/count`, `ei_grow_cap` |
| `String` | `ei_String`, `ei_str_from`, `ei_str_from_i64`, `ei_drop_String`, `ei_share_String`, `ei_clone_String`, `ei_str_unique`, `ei_str_cat/push/append` |
| Map key hashes | `ei_hash_u64`, `ei_hash_str` |
| `print` | `ei_print_i/u/b/s` (`int64_t`/`uint64_t`) |
| the clock | `ei_now_ms` |
| checked arithmetic | written out per integer type; usize uses the u64 functions |
| reference counts (Mutex, Task, Chan handles) | `ei_rc` |
| locks in Mutex/Task/Chan | `ei_mutex` |
| Task thread start/join-once/destroy | `ei_thread` |
| Chan queue: ring buffer, cond var, closed flag, send/recv/close | `ei_chan` (type-erased by element size) |

### Generated (stays compiler output)

| Generated | Why it is per type |
|---|---|
| `ei_drop_X` / `ei_clone_X` for records, tuples, enums, arrays, List, Map, Box, Fn, Task/Mutex/Chan handles | walks the fields of a concrete type (a List, Map or Box clone is one `ei_buf_inc`) |
| `uniq_X` (List, Map, Box), `own_X` (any type that owns heap data) | copy-on-write: copy a shared buffer's elements; own every buffer before a thread crossing |
| `ei_eq_X` and the inline `==` for String/str (`strcmp`) | structural equality per type |
| `ei_push_X`, `ei_has_X` (List); `pop`, `get`, `map`/`filter`/`fold`/`sum` loops | monomorphized element type |
| `ei_mfind/mget/minsert/mremove_X` (Map), hash dispatch | key/value types; calls `ei_hash_*`, `ei_alloc_n` |
| `ei_bnew_X` (Box) | element type |
| `ei_mxnew/mxget/mxset/mxupd_X` (Mutex) | typed value + clone/drop; uses `ei_mutex`, `ei_rc` |
| `ei_chnew/chsend/chrecv/chclose_X` (Chan) | thin typed wrappers over `ei_chan` |
| `ei_spawn_X`, `ei_tkmain_X`, `ei_tkjoin_X` (Task) | typed closure and result; uses `ei_thread`, `ei_rc` |
| closure environments `ei_envdrop_N`, `ei_envclone_N`, `F_X` structs | captured variables per closure |
| unit-enum name tables `T_names[]` (printed with `ei_print_s`) | per enum |
| `main`, the test driver loop, exported `eider_*` entry points | per program |

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

## Known gaps

- Traps do not unwind: no drops run (irrelevant when exiting; a leak and possibly a held lock
  in `test` mode, see above).
- `ei_trap` called while a runtime lock is held (an allocation failure during `ei_chan_send`
  growth) leaves that lock held. Only reachable on out-of-memory.
