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
| `eider_core.c` | OS ABI: one OS operation per function, errors as `-errno`, data through byte buffers | Eider code, through `extern "c"` bindings in `core/sys.ei` and `core/os.ei` | `core/ABI.md` |
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
   fixed `print` formats, no OS interop beyond stdio, `malloc`, `clock`, POSIX threads, and
   the thread stacks (anonymous `mmap`/`mprotect`/`munmap`, `sigaltstack`, `sigaction`;
   "Stack overflow" below), each of those in a function of its own.
2. **Per-type code stays generated.** Anything that depends on a concrete Eider type is
   compiler output (see the inventory below). The runtime offers type-independent pieces
   (allocation with overflow checks, a byte-sized channel queue, a reference count) that the
   generated glue builds on.
3. **Fixed-width types only:** `int32_t`, `int64_t`, `uint8_t`, `uint32_t`, `uint64_t`,
   `bool`, `const char *`. Sizes are `uint64_t` (Eider `usize` is `uint64_t` on every
   target). Source lines are `int32_t`.
4. **No undefined or implementation-defined integer behaviour.** No signed overflow; no
   out-of-range conversion to a signed type (wrapping results go through `ei_bits_i32` /
   `ei_bits_i64`); float-to-integer conversion is generated code, not the runtime's: it traps on NaN or out of range (docs/decisions.md C660).
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
A trap in an imported module passes `f * 2^20 + line` (0 < f < 2048): after `ei_set_file`,
generated code calls `void ei_set_files(const char *const *files, int32_t n)` with a table
of file names by index, and `ei_trap` reports `files[f]` and the line for such a value
(f < n, `files[f]` not NULL); any other value is the entry file's line, so programs built by
compilers before docs/compiler.md "C8.16" (which never set the table) trap as they did.

Messages generated code relies on, all byte-identical to the recorded expectations:

| Message | Raised by |
|---|---|
| `integer overflow in +` / `-` / `*` / `/` / `%` | checked arithmetic |
| `integer overflow in negation` | `ei_neg_*` |
| `division by zero`, `remainder by zero` | `ei_div_*`, `ei_rem_*` |
| `integer conversion out of range` | `ei_s2s`, `ei_s2u`, `ei_u2s`, `ei_u2u` |
| `index out of bounds` | `ei_idx`, `ei_str_byte` |
| `shift count out of range` | `ei_shl_*`, `ei_shr_*` |
| `slice out of bounds`, `slice not on a character boundary` | `ei_str_slice` |
| `push_byte needs an ASCII byte (1 to 127)` | `ei_str_push_byte` |
| `exit code out of range` | generated `main` when the Eider `main` returns an i32 outside 0..255 |
| `out of memory` (line 0) | `ei_alloc`, `ei_alloc_n`, `ei_buf_alloc`, `ei_buf_grow`, `ei_grow_cap`, `ei_str_*`, `ei_chan_send` |
| `send on a closed channel` (line 0) | `ei_chan_send` |
| `cannot create a thread` (line 0) | `ei_thread_start` |
| any `panic` / `assert` text | generated code calls `ei_trap` directly |

| `stack overflow` (line 0) | the fault handler of a runtime thread ("Stack overflow") |
| `Ref read while it is being updated`, `Ref updated while it is being read`, `Ref updated while it is already being updated` | `ei_ref_read_begin`, `ei_ref_update_begin` ("Ref") |
| `a Ref can't be sent to another thread` (line 0) | generated `own_` glue meeting a Ref (a closure capturing one sent to a thread) |

Also reported (failures the recorded expectations never exercise): `cannot create a mutex`,
`cannot lock a mutex`, `cannot unlock a mutex`, `cannot join a thread`,
`cannot create a channel` (all line 0).

Several threads trapping at once: the first one without a hook takes a process-wide lock that
is never released, reports, and exits; the others block on it until the process ends. So
there is exactly one report and `exit` never runs concurrently with itself.

### The test hook

`void ei_set_trap_jmp(jmp_buf *jb)` sets this thread's hook (`NULL` clears it). The test
driver the compiler generates calls `int32_t ei_test(const char *name, void (*fn)(void))` for
each test block: it prints `test <name> ... `, sets the hook, runs `fn` under `setjmp` (which
has to run in this frame), prints `ok` (or the trap prints `FAILED` and its message), clears
the hook and returns 1 when the test failed; `int32_t ei_tests_done(int32_t total, int32_t
failed)` prints the summary, reports leaks when none failed, and returns the exit code. In a
`--profile` build a failed test is unwound in the shadow stack (`ei_prof_unwind(0)`).

The hook is thread-local: a trap on a thread spawned by a test exits the whole test binary
with 101. A `longjmp` out of a failed test does not run drops, so values owned
by the failed test leak, and a lock held at the moment of the trap stays held (for example a
trap inside a `Mutex.update` closure). Tests after it that use the same Mutex deadlock.

### Containing a trap

`int32_t ei_try(void (*fn)(void *, void *), void *a, void *b, ei_String *msg)` runs `fn(a, b)`.
It returns 0 when `fn` returns. If a trap ends `fn` on this thread (overflow, bounds, `panic`,
`assert`, out of memory, a failed lock), `ei_trap` does not report or exit: it keeps the text
(`<msg> (<file>:<line>)`, the report without `eider: runtime error: `), and `ei_try` returns
1 with that text in `*msg` (a String the caller owns). Generated code reaches it through
`Task.catch(f)` (docs/compiler.md "C8.51"; the glue `catch_R` makes `Result[T, String]`).
Frames nest (the innermost catches), and a trap inside a test block that is inside a `catch`
is the catch's. The design (decision C803) and its limits:

- **No unwinding.** The trap is a `longjmp` to the `setjmp` in `ei_try`, so the frames
  between are abandoned **without their drops**: memory they owned is not freed (a leak,
  reported by the counting allocator), a `Drop` impl does not run, counts of shared handles
  they held stay up (a `Task` never joins, a `Chan` is never freed). The leak is bounded by
  what one contained call built. Stack unwinding is not available in C, and cleanup code on
  every call would cost the code that does not trap; so containment is at a call you choose.
- **Locks.** Each thread remembers the `ei_mutex` locks it holds (32, innermost last); a
  contained trap unlocks those taken since the `ei_try` began. So a built-in `Mutex` whose
  `update` closure trapped, a channel, and a Task's lock are usable again, with the value as
  the closure left it (it may be logically inconsistent: the traps are checked operations,
  none leaves a half-built buffer except an out-of-memory in the middle of a `Chan` send).
  A lock that is a channel holding the value (std/sync's `Lock`) is not an `ei_mutex`: its
  `modify` took the value out, so a trap in `f` loses it and the lock stays empty.
- **Not contained.** Stack overflow (the fault handler ends the process with 101 from the
  signal handler: it cannot `longjmp` off a stack that is exhausted), `env.exit`, `_exit`, a
  signal that kills the process, and a trap in a thread that has no `ei_try` around it (as before:
  report on stderr, exit 101; the main thread is such a thread unless the program catches).
  In a WebAssembly module a trap is `unreachable` and cannot be caught: `ei_try` just
  calls `fn`.
- A profiled build (`--profile`) restores the shadow stack depth like a failed test.

## Map hashing

A `Map` is `{ K *keys; V *vals; uint8_t *state; len, cap, used, key0, key1 }` (the last two
words are its hash key, 0 until the first insert). The slot of a key is `hash & (cap - 1)`,
with the hash computed by SipHash-1-3 (core/eider_sip.inc, shared with the WebAssembly runtime)
under `(key0, key1)`:

| Function | Contract |
|---|---|
| `uint64_t ei_sip13_w(const uint64_t *key, uint64_t w)`, `ei_sip13_w2(key, a, b)` | SipHash-1-3 of the 8 little-endian bytes of `w`, or of the 16 bytes of `a`, `b` (integers, bool and `()` widen to a word; a record, tuple, enum, array or List folds its parts: `h = ei_sip13_w2(key, h, part)` from a fixed start, each part hashed the same way) |
| `uint64_t ei_sip13_str(const uint64_t *key, const char *t)` | SipHash-1-3 of the bytes of text up to its NUL |
| `uint64_t ei_sip13(k0, k1, p, n)` | any bytes under an explicit key (tests/core/rt_test.c checks it against the reference vectors) |
| `void ei_map_seed(uint64_t *key)` | the key of a Map at its first insert: two words from a per-thread SipHash-1-3 counter whose own key is 128 bits of OS randomness (`ec_random_fill` in eider_core.c, read once per thread; the runtime linked without the core uses the fixed key), `key[0]` never 0 |
| `EI_MAP_DET_K0`, `EI_MAP_DET_K1` | the key of `Map.deterministic()` |

The key is copied with the Map (a copy shares the buffers, whose slots depend on it), kept
by `uniq_` and by growth, and never changes. `hash` of a value (the `Hash` trait, `x.hash()`,
`ei_hash_u64`, `ei_hash_str`) is not seeded and is unchanged. The order of a Map's slots, so of
`keys`, `values`, `entries`, `for` and Show, is **unspecified**: it differs between Maps and runs.
The WebAssembly runtime has no OS randomness: every Map there takes the fixed key.

## Inline (in the header) vs out of line (in the .c)

| In `eider_rt.h`, `static inline` | In `eider_rt.c` |
|---|---|
| `ei_idx`, all checked/wrapping arithmetic, `ei_bits_*`, conversions, `ei_hash_u64`, the buffer counts (`ei_buf_h/inc/dec/shared/count`), the atomics (`ei_atomic_*`, `ei_mo_*`), `ei_unreachable()` (macro) | `ei_trap`, `ei_set_file`, `ei_set_trap_jmp`, allocation (`ei_alloc`, `ei_alloc_n`, `ei_free`, `ei_check_leaks`, `ei_buf_alloc/grow/free`, `ei_grow_cap`), `String`, `ei_hash_str`, print, clock, threads |

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
| `T ei_band_N(T a, T b)`, `ei_bor_N`, `ei_bxor_N`, `T ei_bnot_N(T a)` | `& \| ^ ~` on the two's-complement bits |
| `T ei_shl_N(T a, T n, int32_t line)`, `ei_shr_N` | `a << n` (bits shifted out are dropped), `a >> n` (arithmetic for signed `N`); trap `shift count out of range` unless `0 <= n < bits` |
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
| `uint8_t ei_str_byte(s, n, i, line)` | byte `i` of text `s` of length `n` (a String's `p, len` or a str and its `strlen`); traps `index out of bounds` |
| `ei_str_from(const char *)`, `ei_str_from_i64(int64_t)` | new String (decimal, `-` for negatives), `cap == len` |
| `uint64_t ei_hash_u64(uint64_t)`, `uint64_t ei_hash_str(const char *)` | Map key hashes: murmur3 finalizer; FNV-1a up to the NUL, then the finalizer. Bit-identical to the recorded expectations. |

Strings never contain NUL and are always valid UTF-8 (they are built from literals, decimal
numbers, checked bytes and ASCII `push_byte`), so `print`, `==` and `<` (`strcmp`) and
`ei_hash_str` all agree on where a String ends.

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
| `void ei_list_open(void **data, uint64_t *len, uint64_t *cap, uint64_t at, uint64_t n, uint64_t size)`, `ei_list_close(data, len, at, n, size)` | the in-place List operations (docs/compiler.md "C8.49"), on a List whose buffer the caller made unique: open a gap of `n` elements at index `at` (growing the buffer: `ei_grow_cap`, `ei_buf_grow`), or close one (the elements already moved out or dropped). The element copies and drops are generated |
| `uint64_t ei_grow_cap(uint64_t cap, uint64_t len, uint64_t extra, uint64_t min)` | the amortised capacity for `len + extra` elements: `max(2 * cap, len + extra, min)` (doubling saturates at `UINT64_MAX`, which then fails to allocate); traps `out of memory` if `len + extra` overflows. List and Map growth and `ei_str_cat` use it |

**Counts are not atomic**, which is sound because a buffer is reachable from one thread at a
time: before a value crosses to another thread the generated glue makes every buffer it
reaches its own (`own_` glue: `uniq` at every level). That happens to `spawn`'s closure
(through the fn value's `own` hook, which owns the captures), to the value given to
`Mutex.new`, `Mutex.set` and `Chan.send`, to the result of a `Mutex.update` closure (under the
lock), and to the copies `Mutex.get` and `Task.join` hand out (made and owned under the
Mutex's lock, or the Task's own lock, since joins may run on several threads at once). The
shared handles themselves (`ei_rc`) stay atomic.

### Ref

A `Ref[T]` (docs/compiler.md, "C8.7") is a shared buffer of one `{ int64_t st; T v; }`
(generated struct): the buffer's count is the number of holders (not atomic: a Ref never
crosses threads; the checker rejects it, E0411, and `own_` glue traps if one is reached),
and `st` is the access state, `> 0` reads in progress, `-1` an update. Generated code
brackets each access with the inline functions below (no call when inlined):

| Function | Contract |
|---|---|
| `ei_ref_read_begin(int64_t *st, int32_t line)`, `ei_ref_read_end(int64_t *st)` | around `read`, `get` and `.copy()`; traps `Ref read while it is being updated` (line) when `*st < 0`, else counts one more read |
| `ei_ref_update_begin(int64_t *st, int32_t line)`, `ei_ref_update_end(int64_t *st)` | around `update` and `set`; traps `Ref updated while it is already being updated` when `*st < 0`, `Ref updated while it is being read` when `*st > 0`, else sets `-1`; the end sets `0` |

## Print and clock

| Function | Output on stdout |
|---|---|
| `ei_print_i(int64_t)`, `ei_print_u(uint64_t)` | decimal, then `\n` |
| `ei_print_b(bool)` | `true` / `false`, then `\n` |
| `ei_print_s(const char *)` | the bytes up to the NUL, then `\n` |
| `ei_print_f64(double)`, `ei_print_f32(float)` | the shortest decimal text that reads back as the same value, then `\n` (below) |
| `uint64_t ei_now_ms(void)` | milliseconds on the monotonic clock (`CLOCK_MONOTONIC`) from an arbitrary start; `0` if unavailable |

**Float text** (core/eider_float.inc, included by both runtimes; docs/decisions.md C660):
`ei_str_push_f64` / `ei_str_push_f32` (Show, `print`) append the shortest digits that read back
as the same float (Burger and Dybvig's free-format algorithm over a small big integer), positional
for decimal exponents -5 to 15 and always with a point (`100.0`, `0.00001`), else `1.5e-7` / `1e16`;
`NaN`, `inf`, `-inf`, `-0.0`. `ei_str_fmt_f64` / `ei_str_fmt_f32` append `{x:spec}`: width, fill,
alignment, `+`, `0` (the integers' bits in `ei_str_fmt_i64`'s spec) and the precision in bits 52-62
with bit 63 set when given: the exact value rounded half to even, up to 400 places. Integer
arithmetic only: no libm, no printf, no locale. tests/core/rt_test.c checks the text against
strtod and printf over random bit patterns.

`now_ms` measures elapsed time: it advances while the program sleeps or blocks and never jumps
when the system clock is set. It used to be processor time (`clock()`), which did neither; no
test depended on that (`tests/` only checks `now_ms() >= 0`, and `eiderc` uses it as a unique
stamp for temporary directories, which a monotonic clock serves better). Nanosecond monotonic
and wall clocks for std are `ec_time_mono_ns` / `ec_time_wall_ns` (core/ABI.md, "Time").

## Threads

Generated per-type structs embed these and add the typed payload. All functions trap on
failure of the underlying primitive.

| Type / function | Contract |
|---|---|
| `ei_rc` (`atomic_uint_least64_t`), `ei_rc_init` (=1), `ei_rc_inc`, `bool ei_rc_dec` | shared-handle count (`Task`, `Mutex`, `Chan`); `ei_rc_dec` returns `true` for the last reference, and only that caller frees. Sequentially consistent. |
| `ei_mutex`, `ei_mutex_init/lock/unlock/destroy` | an error-checking `pthread_mutex_t`: locking it again on the thread that holds it (a `Mutex.update` closure using the same Mutex) traps `cannot lock a mutex` instead of being undefined (a plain mutex would deadlock) |
| `ei_thread`, `ei_thread_start(t, run, arg)` | starts `run(arg)` on a guarded stack of its own ("Stack overflow"); `t` must stay where it is until `ei_thread_destroy` (it is the new thread's argument) |
| `ei_thread_join(t)` | waits once; safe from several threads at once and repeatedly (`Task.join` on shared handles); frees the thread's stack |
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

## Tasks

`ei_thread_start` makes a **task** (decision C830, docs/design/lightweight-tasks.md) wherever the
platform has them (`EI_TASKS`: Linux on x86-64 with the assembly switch, Linux with glibc with
`ucontext`); elsewhere, and with `EIDER_TASKS=threads`, it starts an OS thread as above. The
`ei_thread` is the same handle (`task` is set for a task); `ei_h_start`, `ei_h_join`, the
generated glue and the compiler don't know the difference.

| Piece | Contract |
|---|---|
| `ei_task` (heap, freed by `ei_thread_destroy`) | saved context, a stack mapping (guard page + 8 MiB, `EIDER_TASK_STACK`; fresh mappings are `MAP_NORESERVE`; ended tasks' stacks are cached, 4096 of them, with all but the top 16 KiB returned to the system), a state word, links, the try-frame list of `ei_try` |
| workers | `EIDER_WORKERS` threads (default CPUs, 4 to 64), started with the first spawn, each with a queue; an idle worker takes half of another's; a task made runnable by a worker goes on its queue, by another thread on a worker's chosen round robin |
| `task_park` | switch to the worker's loop; state `RUNNING` -> `PARKED` there; `task_unpark` makes it `READY` and queues it, or, if it has not parked yet, leaves a permit (`NOTIFIED`) so the park returns at once. Every wait registers where it waits, releases that lock, parks, and re-checks (a permit can be left over) |
| `ei_chan_recv` in a task | the task joins the channel's wait list (a send wakes one, close wakes all) and parks; threads still wait on the condition variable |
| `ei_thread_join` in a task | the task joins the target's joiner list and parks; the worker publishes the end after leaving the dead task's stack |
| `ec_fd_wait`, `ec_fd_wait2` (two descriptors, one record linked into both), `ec_sleep_ns` in a task | through `ec_block_hook` (set by the scheduler; core/eider_core.c knows nothing else about tasks): a record on the task's stack goes into the reactor (up to eight reactors, each an epoll set with one-shot registrations, a timer heap and a thread; a descriptor belongs to the reactor its number selects), the task parks, the reactor completes it. `ec_sleep_ns(0)` yields |
| a Parker (`ec_parker_*`, core/ABI.md "Parkers") in a task | the wait is the same reactor record as a descriptor wait, with a timer and no descriptor, attached to the parker through `ec_pk_attach`/`ec_pk_detach`; an unpark completes the record under the parker's stripe lock, then the reactor's (that order everywhere), and the waiter detaches under the same lock before its record goes, so a wake never meets a dead record. `ec_fd_wait_ev` adds a descriptor to the same record (cancelling a descriptor wait). A thread waits with `poll(2)` on a waker of its own (one eventfd per thread that ever parks) |
| `ec_poll_wait` in a task | the task waits for the poller's own descriptor to be readable (an epoll set is readable while events are pending), then collects them without waiting: a `Loop` costs the task, not a worker |
| the starvation guard | the reactor ticks every 10 ms while tasks are queued and no worker is idle; if no worker has switched tasks since the last tick, it starts one more worker, up to `EIDER_WORKERS_MAX` (256) |

Thread-local state moves with the task: the `ei_try` frame list (a trap after a park is
contained by the `catch` that was running, on whichever worker), the guard range of the stack
overflow handler, and, in a profiling build, the shadow stack (copied out at park, back at
resume). A task never parks holding an `ei_mutex` (`cannot wait while holding a Mutex`). The
thread-local variables the runtime uses across a park are read through out-of-line functions,
so no cached thread pointer is used after the task resumed on another thread. Under
AddressSanitizer and ThreadSanitizer the switches are annotated (fiber API).

Limits: a blocked task costs its touched stack pages (about 5 KiB) and a 100-byte record; one
mapping pair per live task (`vm.max_map_count`); no preemption; descriptor waits need the
descriptor to stay open; the reactor is Linux's epoll (kqueue is follow-up work).

## Atomics

`ei_atomic_i64` (`_Atomic(int64_t)`) and inline operations on it, for generated code (the
built-in atomic type that is the compiler's next step, and the runtime's own pieces of the
task scheduler). `order` is a number: `0` relaxed, `1` acquire, `2` release, `3`
acquire-release, `4` sequentially consistent.

| Function | Result |
|---|---|
| `ei_atomic_init(a, v)` | initializes (not atomic: before the value is shared) |
| `int64_t ei_atomic_load(a, order)` | the value |
| `ei_atomic_store(a, v, order)` | stores `v` |
| `int64_t ei_atomic_swap(a, v, order)` | the previous value; stores `v` |
| `int64_t ei_atomic_add(a, n, order)` | the previous value; adds `n`, wrapping (C11 defines atomic signed arithmetic as two's complement; checked addition is a compare-and-swap loop in the caller) |
| `int64_t ei_atomic_cas(a, expected, desired, order)` | the previous value; stores `desired` if it was `expected` (strong) |

No combination of operation and number is undefined: an ordering that doesn't apply (release
on a load, acquire on a store) or an unknown number is strengthened to sequentially consistent
(`ei_mo_load`, `ei_mo_store`, `ei_mo_rmw`), and a failed compare-and-swap uses the success
ordering without its release half (`ei_mo_fail`). A checker that knows the orderings
statically rejects the inapplicable ones instead (std/atomic does at run time).

Eider code reaches atomics today through **atomic cells** in eider_core.c (core/ABI.md
"Atomic cells"): integer handles to cells the core owns, which every copy of a handle shares
across threads, freed explicitly. The two halves are kept separate because eider_rt and
eider_core don't include each other; the cells repeat the four ordering functions.

## Stack overflow

Every thread `ei_thread_start` starts (each `spawn`) runs on one anonymous mapping of the
runtime's own, lowest address first: a 64 KiB alternate signal stack (or `SIGSTKSZ` if that
is larger), a 64 KiB guard with no access, then an 8 MiB stack (`EI_THREAD_STACK`,
`EI_THREAD_GUARD`, `EI_THREAD_ALTSTACK` in eider_rt.h; sizes rounded up to whole pages). The
stack grows down into the guard, so an overflow, even by a frame larger than a page, faults
there rather than in some other mapping. (Before, threads had the C library's default stack,
whose guard on glibc is one page.)

On the first thread start the runtime installs, once, a handler for `SIGSEGV` and `SIGBUS`
that runs on the alternate stack (`SA_ONSTACK`), keeping the handlers that were there before.
Each runtime thread sets its alternate stack and records its guard range (thread-local)
before running its function. The handler:

- fault address inside this thread's guard: flushes stdout if no other thread is in stdio
  (`ftrylockfile`: it never waits), writes `eider: runtime error: stack overflow (<file>:0)`
  to stderr with `write(2)` and ends the process with `_exit(101)`, like a trap. The test hook
  doesn't apply (spawned threads never have one).
- anywhere else: not ours. It calls the previous handler (a sanitizer's, which then reports
  as usual), or restores the default action and returns, so the faulting access repeats and
  the process ends with `SIGSEGV` exactly as without the runtime.

The stack is unmapped when the thread is joined. Mapping or protecting fails: `cannot create
a thread`, as before. A system without anonymous mappings or `SA_ONSTACK` (none that the core
targets) starts threads with the C library's default stack and no handler.

### The main thread: `ei_main`

The Eider `main` has a stack of 512 MiB (`EI_MAIN_STACK`; `EIDER_MAIN_STACK` bytes to change it,
at least 64 KiB), not the 8 MiB of a spawned thread: the mapping is `MAP_NORESERVE`, so it costs
address space and only the pages a program touches. The compiler's checker recurses once per
call of a method chain with frames of a few hundred KiB, and a chain of 300 calls needs most of
100 MiB (eider-lang#153). If the system refuses the mapping, `main` gets the usual 8 MiB; so does a
program built with AddressSanitizer (which warns about every trap, a no-return call, on a stack over
64 MiB) or ThreadSanitizer (which shadows the stack deep recursion touches), unless
`EIDER_MAIN_STACK` is set.

| Function | Contract |
|---|---|
| `int ei_main(int (*body)(void))` | the program entry: generated C `main` is `return ei_main(ei_main_body);`, where `ei_main_body` is what `main` used to be (`ei_set_file`, the file and profiler tables, the Eider `main` or the test driver, the leak check, the exit code). Runs `body` on a runtime thread with a guarded stack and returns its result |

The Eider `main` runs on a runtime thread like every spawned one: the same mapping
(alternate stack, guard, 512 MiB stack, see above) and the same fault handler, so overflowing it is the
trap `eider: runtime error: stack overflow (<file>:0)`, exit 101, with what `print`
buffered flushed first (compiler/tests/run/stack_overflow_main.ei; tests/core's
`test_main_entry`). Before, the Eider `main` ran on the kernel's stack, which has no guard
the runtime knows, and an overflow was a bare `SIGSEGV` (exit 139). `ei_main`:

1. blocks every signal on the C main thread (`pthread_sigmask`), keeping the old mask;
2. installs the fault handler (once, as `ei_thread_start` does) and starts the thread; the
   thread inherits the full mask and restores the old one before it calls `body`;
3. joins it, releases its mapping, restores the mask and returns `body`'s result, which
   C `main` returns, so `exit` and the `atexit` handlers (the profiler's writer) run on the C
   main thread as before. A `body` that ends the process itself (`env.exit`, a trap) does so
   from its thread, as any thread can.

Where no guarded thread can be started (no anonymous mappings or `SA_ONSTACK`, or the
system refuses the mapping or the thread), `body` runs on the C main thread itself, as
before: correct, but an overflow there is again a bare `SIGSEGV`.

Why a thread rather than a guard and alternate stack on the kernel's main stack (C305):

- **Soundness of the guard.** A thread stack is the runtime's own mapping, so the guard is
  a known range and "the fault address is in this thread's guard" is exact. The kernel's
  main stack grows on demand up to `RLIMIT_STACK` (possibly unlimited) with a gap below it
  whose size is the kernel's (`stack_guard_gap`), and POSIX has no call that says where it
  ends: the handler would have to guess from the fault address and the stack pointer
  (architecture-specific), and could take an unrelated fault near the stack for an overflow.
- **Signals.** With the C main thread blocking every signal, a process-directed signal
  (`kill`, Ctrl-C, `SIGTERM`) is delivered to a thread that doesn't block it: the Eider main
  thread or one it spawned, exactly the threads that could receive it before. A signal the
  Eider `main` blocks with `ec_signal_mask` stays pending as before; core's signal pipe
  (core/ABI.md "Signals") works from any thread anyway. The thread starts with the caller's
  mask, so a program started with signals blocked keeps them blocked.
- **The profiler's per-thread timers.** `ei_prof_init` runs inside `body`, so it registers
  the Eider main thread (thread 0, with its `timer_create` timer on Linux), and the idle C
  main thread is never registered: it takes no samples (it also blocks `SIGPROF`, so the
  `ITIMER_PROF` fallback never lands there). When `body` returns, the thread unregisters
  like any runtime thread, then `exit` writes the profile.
- **Exit codes.** Unchanged: `body`'s result (0, an i32 from `main`, 1 for an `Err`, the test
  driver's 1 for a failure) is `main`'s; traps exit 101 from whichever thread traps.
- **WebAssembly.** One thread and no signals: core/wasm's `ei_main` calls `body` directly
  (modules are libraries and have no generated `main` today), so nothing changes there.
- **Cost.** One `mmap`, one thread start and one join per program run (tens of
  microseconds); the stack is the runtime's 512 MiB (address space; since 0.7: it was 8 MiB,
  like a spawned thread's) instead of the kernel's `ulimit -s`, so a program that relied on a
  larger `ulimit -s` for deep recursion on the main thread has room for it.

Sanitizers: under ASan and TSan the handler sees overflows in instrumented C (tests/core,
the main entry too), but TSan can itself run out of stack inside its own runtime when Eider
code overflows, which then dies of `SIGSEGV` first (so tests/std doesn't run its overflow test
under TSan, and compiler/tests/run/stack_overflow_main.ei says `// nosan: thread`).

## Profiling

Only in programs built with `eiderc build|run|test --profile` (docs/runtime.md "Profiler"):
their C starts with `#define EI_RT_PROFILE 1`, and the driver then compiles eider_rt.c (and
eider_core.c) with `-DEI_RT_PROFILE`, a separate core-object cache entry. eider_rt.c includes
`core/eider_prof.c` at its end under that flag, and its hooks are `#ifdef EI_RT_PROFILE`
blocks: compiled without the flag, eider_rt.c preprocesses to the same text and object as
before the profiler existed (tests/core/run.sh checks that no profiler code is left).

| In `eider_rt.h` (inline, generated code) | Contract |
|---|---|
| `ei_prof_frame` `{ volatile float fn, line; }`, `ei_prof_stack[EI_PROF_DEPTH]`, `ei_prof_depth` (thread-local) | the shadow stack: 512 frames per thread, deeper ones write `ei_prof_spill`; floats so the stores alias none of the program's data, volatile so they happen where written and in order (the signal handler reads them on the same thread) |
| `ei_prof_frame *ei_prof_enter(uint32_t fn)`, `ei_prof_leave(void)`, `ei_prof_unwind(depth)` | push (line 0), pop, and reset after a test's longjmp |
| `ei_prof_ev(kind, n)` | an event at the current position: `EI_PEV_COW`, `COPY`, `DROP`, `GROW`, `REHASH` from glue (n bytes), `REF` before a Ref conflict's trap |
| `ei_prof_init(const ei_prof_table *)` | generated `main` (and test `main`), after `ei_set_file`: the name table (`names[fn]`, `file_of[fn]`, `files`), what to profile (`EI_PROF_CPU`, `MEM`, `CONC`) and the program |

| Hook in `eider_rt.c` (under `EI_RT_PROFILE`) | What it records |
|---|---|
| `ei_alloc`, `ei_free`, `ei_buf_grow` | with `mem`: a 16-byte prefix (site, size) on every block; counts and bytes per site, live counts per site, live and peak heap; a stack every `EIDER_PROF_MEM_RATE` bytes |
| `ei_str_unique`, `ei_str_cat` | copy-on-write unshares and String growth |
| `ei_mutex_lock` | with `conc`: a trylock; when it fails, the wait is timed (site and stack) |
| `ei_chan_recv` | with `conc`: a wait for a value, timed, recorded after the unlock |
| `ei_thread_start`, the thread's start routine | a spawn at the caller's site; the thread registers (ring, timer) before running and unregisters after |
| `ei_check_leaks` | the program returned from `main`: live blocks at exit are leaks |

`core/eider_prof.c` itself: the SIGPROF handler (async-signal-safe: atomics and stores only;
it copies the innermost 128 frames and the thread's label into the thread's ring, or counts
a drop when the ring is full), per-thread timers (Linux `timer_create` with
`SIGEV_THREAD_ID` on `CLOCK_THREAD_CPUTIME_ID` or `CLOCK_MONOTONIC`; elsewhere
`ITIMER_PROF`), a collector thread (blocks every signal; drains the rings every 20 ms into the
stack table, takes the heap timeline every 100 ms, writes the profile on SIGUSR2), the
lock-free site table, the label tree, the writer (to `<path>.tmp`, renamed) and the atexit
hook that writes the profile at exit. It uses malloc, pthreads, stdio, `sigaction`,
`timer_*`/`setitimer` and `clock_gettime`, each from ordinary code except the handler; the
runtime's own allocations are never counted. The control calls arrive from Eider through
eider_core's `ec_prof` (core/ABI.md "Profiling"): `ei_prof_init` stores its control function
in `ec_prof_hook`, the one symbol eider_core defines for eider_rt.

Under ASan+UBSan and TSan: tests/core/prof_test.c and the profiled programs of
scripts/test-compiler.sh ("profile") run clean.

## What is core and what is generated

The rule: anything that does not depend on a concrete type is in the core; anything that
walks or is parameterised by a concrete type stays compiler output.

### Core (`eider_rt`)

| Piece | Core |
|---|---|
| traps, the test hook, the source file names | `ei_trap`, `ei_set_trap_jmp`, `ei_set_file`, `ei_set_files` |
| unreachable code | the `ei_unreachable` macro |
| index checks, integer conversions | `ei_idx`, `ei_s2s/s2u/u2s/u2u` |
| allocation | `ei_alloc`, plus `ei_alloc_n` for the `n * sizeof(T)` call sites |
| shared buffers (copy-on-write) | `ei_buf_hdr`, `ei_buf_alloc/grow/free`, `ei_buf_inc/dec/shared/count`, `ei_grow_cap` |
| `Ref` access checks | `ei_ref_read_begin/end`, `ei_ref_update_begin/end` |
| `String` | `ei_String`, `ei_str_from`, `ei_str_from_i64`, `ei_drop_String`, `ei_share_String`, `ei_clone_String`, `ei_str_unique`, `ei_str_cat/push/append` |
| Map key hashes | `ei_hash_u64`, `ei_hash_str` |
| `print` | `ei_print_i/u/b/s` (`int64_t`/`uint64_t`) |
| the clock | `ei_now_ms` |
| checked arithmetic | written out per integer type; usize uses the u64 functions |
| reference counts (Mutex, Task, Chan handles) | `ei_rc` |
| locks in Mutex/Task/Chan | `ei_mutex` |
| Task thread start/join-once/destroy, guarded stacks | `ei_thread` |
| atomics on 64-bit integers | `ei_atomic_i64`, `ei_atomic_*` |
| the profiler (`--profile` builds only) | `ei_prof_*` ("Profiling"; core/eider_prof.c) |
| Chan queue: ring buffer, cond var, closed flag, send/recv/close | `ei_chan` (type-erased by element size) |

Also in the core, for the LLVM backend's IR (#128), which can't name C types or macros:

| Piece | Core |
|---|---|
| derived Show of numbers and quoted text | `ei_str_push_i64`, `ei_str_push_u64`, `ei_str_push_quoted` |
| `main` returning `Err` | `ei_main_error(text)`, `ei_main_error_i`, `ei_main_error_u`: flush stdout, then `error: ...` on stderr |
| the test driver | `ei_test`, `ei_tests_done` (above) |
| `eiderc test --coverage` | `ei_cov_hit(id)`: a relaxed atomic increment of probe `id`'s counter (up to `EI_COV_MAX`); at exit the nonzero counters are written to the file `$EIDER_COVERAGE` names, as `<id> <count>` lines |
| handle objects (Task, Mutex, Chan) | `ei_h_new(size, chan_elem)` (a thread-safe count, a lock, a thread, a channel of `chan_elem`-byte elements when it is above 0, and `size` bytes of the program's data, 16-byte aligned), `ei_h_data`, `ei_h_inc`, `ei_h_dec` (true when that was the last holder), `ei_h_lock`/`unlock`, `ei_h_start(h, run)` (runs `run(h)` on a runtime thread), `ei_h_join`, `ei_h_chan`, `ei_h_free` (joins a started thread, destroys the lock and the channel, frees; the program drops its data first) |

The buffer counts and the Ref checks are inline in the IR as they are in the header.

### Generated (stays compiler output)

Since #128 the per-type operations below are LLVM IR (llvm.ei's glue), with these names; the
handles keep their data in `ei_h_*` objects.


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
  in `test` mode, see above; with `ei_try`, a leak of what the abandoned frames owned,
  "Containing a trap").
- `ei_trap` called while a runtime lock is held (an allocation failure during `ei_chan_send`
  growth) leaves that lock held. Only reachable on out-of-memory.
