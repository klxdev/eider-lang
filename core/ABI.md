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
   another thread's. A thread's buffers are freed when the thread exits (a pthread key
   destructor); the main thread's when the process ends. The core therefore needs POSIX
   threads (`-pthread`), which every Eider program links anyway.

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
| `int64_t ec_realpath(void)` | `in[0]` path | canonical absolute path (symlinks resolved) in `out`; the path must exist |
| `int64_t ec_args(void)` | | argv in `out`, each NUL-terminated |
| `int32_t ec_getenv(void)` | `in[0]` name | `1` and the value in `out`, or `0` if unset |
| `int64_t ec_write_fd(int32_t fd)` | `in` = bytes | `0`; flushes buffered `print` output first; `fd` is 1 or 2 |
| `int64_t ec_read_fd(int32_t fd, int64_t max)` | | reads up to `max` bytes (at most 1 MiB per call) from `fd` into `out`; returns the count, `0` at end of file; `EINTR` is retried; `-EINVAL` for `fd < 0` or `max <= 0`. One `read(2)`: fewer bytes than `max` is not end of file |
| `int64_t ec_run(int32_t out_mode, int32_t err_mode, int64_t timeout_ms)` | `in` = argv (PATH lookup) | see [Running a program](#running-a-program) |
| `void ec_errstr(int64_t status)` | | message for `-errno` in `out` |
| `void ec_exit(int32_t code)` | | flush and exit |

## Running a program

`ec_run(out_mode, err_mode, timeout_ms)` is one operation: fork, exec `in` as argv (searched
on `PATH`), collect what was asked for, and reap the child. stdin is always inherited.

- `out_mode`, `err_mode`: `0` the child inherits our stdout / stderr, `1` it is captured.
  Anything else is `-EINVAL`.
- `timeout_ms`: `<= 0` no limit. Otherwise a wall-clock deadline measured from the start
  (`CLOCK_MONOTONIC`). The child is put in its own process group (so the deadline reaches
  `sh -c` pipelines and other grandchildren); at the deadline the group gets `SIGTERM`, and
  `SIGKILL` 200 ms later if the child has not been reaped. After the kill the core waits at
  most another 200 ms for the pipes to close (a descendant that left the group can hold them
  open), then stops reading and reaps the child. Without a timeout the child stays in our
  process group, so terminal job control works as usual.

Result:

| Value | Meaning |
|---|---|
| `0..255` | the child exited with this code |
| `128 + n` | the child was killed by signal `n` (indistinguishable from exiting with `128 + n`, as in a shell) |
| `256` | timed out: the deadline passed and the child was killed (whatever it exited with) |
| `< 0` | `-errno`: the program could not be started (e.g. `-ENOENT`), or the core failed (fork, pipe, poll) after killing and reaping the child |

`out` holds, whenever the result is `>= 0`:

```
bytes 0..7    n = length of the captured stdout, unsigned 64-bit little-endian
bytes 8..8+n  captured stdout
the rest      captured stderr
```

A stream that is not captured contributes nothing (`n = 0` when stdout is inherited). On a
timeout `out` holds whatever was read before the kill.

Why one buffer with a header rather than a second `err` buffer: it adds no functions to the
ABI (Eider already reads `out` with `ec_out_len`/`ec_out_byte`), keeps the "results flow
through `out`" rule, and splitting at a length is trivial Eider. A decimal header or a
separator would need escaping or parsing; 8 bytes is a fixed, binary-safe prefix.

Guarantees a backend must keep:

- Both pipes are drained concurrently (`poll(2)`), so a child that fills one pipe while we
  wait on the other cannot deadlock.
- `EINTR` from `poll`, `read` and `waitpid` is retried; the deadline is recomputed after each.
- The child is reaped on every path that forked, including core errors and the timeout.
- The exec-failure report travels on a close-on-exec pipe: if exec succeeds the pipe closes
  and the child's exit status is the result; otherwise the child writes `errno` there and the
  result is `-errno`.
- No descriptor of ours leaks into the child: every pipe end is close-on-exec (atomically with
  `pipe2(O_CLOEXEC)` on Linux; with `fcntl` right after `pipe` elsewhere, which leaves a window
  where a concurrent `fork` in another thread can inherit them), and the child's stdout /
  stderr are `dup2` copies, which do not carry the flag.

## Backends

| Target | Status |
|---|---|
| Linux (glibc), x86-64 | exercised by `tests/core` (`ec_run`, `ec_read_fd`), `tests/std` and the package tests |
| Linux, other architectures (aarch64, riscv64, 32-bit) | expected to work (C11 + POSIX only, fixed-width ABI); not yet run |
| macOS | written (`_NSGetArgv`, `EC_SYM` names); not yet run |
| FreeBSD / OpenBSD / NetBSD | written (args via an init-array constructor); not yet run |
| Windows | not written; `eider_core.c` refuses to compile there |
| WebAssembly (wasm32) | none: a module has no OS. The runtime has a wasm backend (`core/wasm/`); `ec_*` calls become host imports (`core/wasm/README.md`) |

The compiler itself (`seed/eiderc.c` and its self-hosting chain) is also only exercised on x86-64 Linux.
