# Core ABI

`core/eider_core.c` is the only non-Eider code a program links. It is the interop layer
between Eider and an operating system. A port to a new OS or architecture is a new backend
file implementing exactly this contract. Nothing above the core changes.

## Rules

1. **No logic.** One OS operation per function. Parsing, paths, recursion, retries and
   formatting are Eider (`std/`).
2. **No pointers cross.** Eider passes data into the `in` buffer a byte at a time and reads
   results out of the `out` buffer a byte at a time. The only pointer-typed values are
   `str` literals (read-only, owned by the program image) and `ec_in_cstr`'s view of `in`,
   which Eider copies immediately.
3. **Fixed-width types only:** `int32_t`, `int64_t`, `const char *` (Eider `i32`, `i64`,
   `str`). Results never depend on `int`/`long`/pointer width, so the ABI is the same on
   32- and 64-bit targets.
4. **Errors are `-errno`** (`< 0`); success is `>= 0`. `ec_errstr` turns a status into text.
5. **Raw symbol names.** Eider binds `extern "c"` functions by raw symbol name
   (`__asm__("ec_x")`). Backends must export each function under exactly that name. On
   Mach-O, which decorates C names with `_`, `eider_core.c` pins the name with `EC_SYM`.
   Eider code never binds libc names directly.
6. **Per-thread buffers.** `in`/`out` are thread-local (C11 `_Thread_local`), so each Eider
   thread has its own and a sequence of push / call / read is never interleaved with
   another thread's. (A buffer is freed only at process exit; threads that do I/O keep
   their buffer's high-water mark until then.)

## Buffers

| Function | Meaning |
|---|---|
| `void ec_in_clear(void)` | Empty `in`. |
| `void ec_in_push(int32_t b)` | Append byte `b & 0xff` to `in`. Arguments are separated by a NUL byte. |
| `const char *ec_in_cstr(void)` | `in` as a NUL-terminated string (valid until the next `in` call). |
| `int64_t ec_out_len(void)` | Bytes in `out`. |
| `int32_t ec_out_byte(int64_t i)` | Byte `i` of `out`, or `-1` if out of range. |
| `int64_t ec_str_len(const char *s)` | Length of a literal. |
| `int32_t ec_str_byte(const char *s, int64_t i)` | Byte `i` of a literal; the caller checks `i < ec_str_len(s)`. |

## Operations

`in[k]` is the k-th NUL-separated argument.

| Function | Arguments | Result |
|---|---|---|
| `int64_t ec_read_file(void)` | `in[0]` path | file bytes in `out`; returns the length |
| `int64_t ec_write_file(int32_t append)` | `in` = path NUL data | `0` |
| `int64_t ec_list_dir(void)` | `in[0]` path | names in `out`, each NUL-terminated, unordered, no `.`/`..` |
| `int32_t ec_kind(int32_t follow)` | `in[0]` path | `0` missing, `1` file, `2` dir, `3` other, `4` symlink (only if `follow == 0`) |
| `int64_t ec_mkdir(void)` | `in[0]` path | `0` (mode 0777 before umask) |
| `int64_t ec_remove(void)` | `in[0]` path | `0`; removes a file, a symlink (never its target) or an empty dir |
| `int64_t ec_rename(void)` | `in[0]` from, `in[1]` to | `0` |
| `int64_t ec_symlink(void)` | `in[0]` target, `in[1]` link path | `0` |
| `int64_t ec_cwd(void)` | | current directory in `out` |
| `int64_t ec_args(void)` | | argv in `out`, each NUL-terminated |
| `int32_t ec_getenv(void)` | `in[0]` name | `1` and the value in `out`, or `0` if unset |
| `int64_t ec_write_fd(int32_t fd)` | `in` = bytes | `0`; flushes buffered `print` output first; `fd` is 1 or 2 |
| `int64_t ec_run(int32_t capture)` | `in` = argv (PATH lookup) | exit code, `128+signal`, or `-errno` if it could not start; with `capture`, the child's stdout is in `out` |
| `void ec_errstr(int64_t status)` | | message for `-errno` in `out` |
| `void ec_exit(int32_t code)` | | flush and exit |

## Backends

| Target | Status |
|---|---|
| Linux (glibc), x86-64 | exercised by `tests/std` and the package tests |
| Linux, other architectures (aarch64, riscv64, 32-bit) | expected to work (C11 + POSIX only, fixed-width ABI); not yet run |
| macOS | written (`_NSGetArgv`, `EC_SYM` names); not yet run |
| FreeBSD / OpenBSD / NetBSD | written (args via an init-array constructor); not yet run |
| Windows | not written; `eider_core.c` refuses to compile there |

The bootstrap compiler itself is also only exercised on x86-64 Linux.
