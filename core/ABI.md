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
   `str`), and, for the math functions below, `double` and `float` (`f64`, `f32`). Results never depend on `int`/`long`/pointer width, so the ABI is the same on
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
| `void ec_in_set(const uint8_t *p, uint64_t n)` | Replace `in` with the `n` bytes at `p` (`p` may be NULL when `n` is 0). |
| `void ec_in_append(const uint8_t *p, uint64_t n)` | Append the `n` bytes at `p` to `in`. |
| `int64_t ec_out_copy(uint8_t *dst, uint64_t n, int64_t from)` | Copy `out[from, from + n)`, clipped to `out`, to `dst`; the number of bytes copied (0 when `from` is outside `out`). |
| `int64_t ec_str_len(const char *s)` | Length of a literal. |
| `int32_t ec_str_byte(const char *s, int64_t i)` | Byte `i` of a literal; the caller checks `i < ec_str_len(s)`. |

### Bulk transfer

The last three rows of the table take a pointer, which Eider never holds: they are bound with
a parameter of type `List[u8]`, and the compiler passes the list's bytes and its length as the
pointer and the count (docs/compiler.md "C8.50", decision C801):

```eider,ignore
extern "c" fn ec_in_set(b: List[u8])
extern "c" fn ec_out_copy(inout dst: List[u8], from: i64) -> i64
```

An `inout` list is made the caller's own before the call (copy-on-write), so `ec_out_copy`
writes into a buffer nobody else holds, and it writes at most `len` bytes: the Eider side makes
the list as long as `ec_out_len` (core/sys.ei's `take`) and `ec_out_copy`s once. `core.sys`'s
`send`, `send_all` and `take` are these calls, so every operation that moves data through
`in` and `out` (files, sockets, processes, crypto) crosses once instead of once per byte. A
WebAssembly core module defines the three functions itself, over `ec_in_push` and `ec_out_byte`
(a pointer into the module's memory means nothing to the host).

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
| `void ec_errstr(int64_t status)` | | message for `-errno`, or for a resolver status (`<= -1000001`, [Name resolution](#name-resolution)), in `out` |
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
- The child starts with clean signals: every signal is blocked across `fork`, and the child
  resets the signals the core delivers to its signal pipe, and `SIGPIPE`, to their defaults and
  empties its mask before `exec` ([Signals](#signals), [SIGPIPE](#sigpipe)).
- No descriptor of ours leaks into the child: every pipe end is close-on-exec (atomically with
  `pipe2(O_CLOEXEC)` on Linux; with `fcntl` right after `pipe` elsewhere, which leaves a window
  where a concurrent `fork` in another thread can inherit them), and the child's stdout /
  stderr are `dup2` copies, which do not carry the flag.

## OS primitives: common rules

The sections below are the Layer 0 OS primitives (roadmap "Layers and their branches",
`layer/core-os`). Eider binds them in `core/os.ei` (not `core/sys.ei`, which the compiler
imports, so the seed does not carry them); std/fd, net, poll, time, random, signal and child
wrap them. They follow the rules above, plus:

- **Descriptors are `int32_t`.** Every descriptor the core creates is close-on-exec
  (atomically where the OS allows: `O_CLOEXEC`, `SOCK_CLOEXEC`, `accept4`, `pipe2`,
  `F_DUPFD_CLOEXEC`, `EPOLL_CLOEXEC`; with `fcntl` right after creation on macOS, the same
  window `ec_run` documents). A child gets only what `ec_spawn` / `ec_run` hand it.
- **`EINTR` is retried** inside every blocking call, except where a row says otherwise
  (`ec_fd_close`, and `ec_poll_wait`, which ends early). Signals reach Eider as events
  (Signals, below), never as interrupted calls.
- **One call, short counts.** `write`-like operations make one system call and return the
  count; fewer bytes than given is not an error. Reads return at most 1 MiB per call.
- **Fixed layouts.** Multi-value results go into `out` as little-endian fixed-width fields
  ("u32" = 4 bytes LE, "u64" = 8 bytes LE). A pair of descriptors is two u32.
- **Portable numbers.** Flags, option names, signal numbers and address families are Eider's
  own numbers, the same on every system; the backend translates them.
- **Capabilities** (docs/compiler.md, "C8.5": `ffi` doesn't leave core, so each `core/os.ei`
  wrapper declares the real capability next to it): `fs` for `fd_open`, `fd_stat`, `stat`,
  `fd_chmod`, `fd_truncate`, `fd_lock`, `fd_sync`; `io` for the other descriptor operations
  (close, write, pread, pwrite, seek, dup, non-blocking, `fd_wait`), `pipe`, `poll_*`, `waker_*`,
  `signal_*`, `random` and `getpid`; `net` for `sock_*` and `dns_*`; `clock` for
  `time_mono_ns`, `time_wall_ns`, `sleep_ns`; `io, fs, net` for `spawn`, `wait` and `kill`
  (a child, or a signal to a process, can do anything; as `sys.run`). `err_kind` and the
  `atomic_*` cells (memory shared between threads, like a Mutex, not the OS) take only
  `ffi`, the `le_*` readers nothing. The std modules on top declare the same real
  capabilities and no `ffi`.

## Error kinds

`-errno` values differ between systems (`EAGAIN` is 11 on Linux, 35 on macOS), so Eider never
compares them with numbers. `int32_t ec_err_kind(int64_t status)` names the ones a program
acts on:

| Kind | Errors |
|---|---|
| `0` | none of these, or not an error (`status >= 0`) |
| `1` would block | `EAGAIN`, `EWOULDBLOCK` |
| `2` in progress | `EINPROGRESS`, `EALREADY` |
| `3` interrupted | `EINTR` |
| `4` not found | `ENOENT`, and the resolver's "no such name" |
| `5` already exists | `EEXIST` |
| `6` broken pipe | `EPIPE` |
| `7` connection reset | `ECONNRESET`, `ECONNABORTED` |
| `8` connection refused | `ECONNREFUSED` |
| `9` timed out | `ETIMEDOUT` |
| `10` permission denied | `EACCES`, `EPERM` |
| `11` address in use | `EADDRINUSE` |
| `12` address not available | `EADDRNOTAVAIL` |
| `13` not connected | `ENOTCONN` |
| `14` invalid argument | `EINVAL` |
| `15` no child | `ECHILD` |
| `16` unsupported | `ENOSYS`, `EAFNOSUPPORT`, `EPROTONOSUPPORT`, `ENOPROTOOPT`, `EOPNOTSUPP` |
| `17` resolver: try again | `EAI_AGAIN` |
| `18` resolver: other failure | the other resolver statuses |

## File descriptors

| Function | Arguments | Result |
|---|---|---|
| `int64_t ec_fd_open(int32_t flags, int32_t mode)` | `in[0]` path | the descriptor. `flags`: access `0` read, `1` write, `2` read-write (`3` is `-EINVAL`), plus `4` create, `8` exclusive (with create), `16` truncate, `32` append, `64` non-blocking, `128` must be a directory, `256` don't follow a final symlink. `mode`: permission bits for a created file (before umask) |
| `int64_t ec_fd_close(int32_t fd)` | | `0`. `EINTR` counts as closed (Linux and the BSDs release the descriptor first; retrying could close someone else's) |
| `int64_t ec_read_fd(int32_t fd, int64_t max)` | | (above) one `read(2)`; also how to read any descriptor below: files, pipes, sockets, wakers, the signal pipe |
| `int64_t ec_fd_write(int32_t fd)` | `in` = bytes | the count written (one `write(2)`; may be short) |
| `int64_t ec_fd_pread(int32_t fd, int64_t max, int64_t off)` | | up to `max` bytes (at most 1 MiB) at offset `off` into `out`; the count, `0` past the end. The file offset doesn't move |
| `int64_t ec_fd_pwrite(int32_t fd, int64_t off)` | `in` = bytes | the count written at `off` (the file offset doesn't move; with append mode Linux appends anyway) |
| `int64_t ec_fd_seek(int32_t fd, int64_t off, int32_t whence)` | | the new offset; `whence` `0` from the start, `1` from the current offset, `2` from the end |
| `int64_t ec_fd_sync(int32_t fd, int32_t data_only)` | | `0` once the data (and with `data_only == 0` the metadata) is on stable storage: `fsync` / `fdatasync`; on macOS both are `fcntl(F_FULLFSYNC)`, because its `fsync` stops at the drive's cache |
| `int64_t ec_fd_truncate(int32_t fd, int64_t len)` | | `0`; the file is now `len` bytes (zero-filled if it grew) |
| `int64_t ec_fd_stat(int32_t fd)` | | `0`; `out` = the stat record (below) |
| `int64_t ec_stat(int32_t follow)` | `in[0]` path | `0`; `out` = the stat record. `follow == 0` describes a final symlink itself. Unlike `ec_kind`, a missing path is `-ENOENT` |
| `int64_t ec_touch(void)` | `in[0]` path | `0`; the file's access and modification times are now (`utimensat`, following a final symlink). The compiler's cache marks an entry used with it |
| `int64_t ec_fd_chmod(int32_t fd, int32_t mode)` | | `0`; permission bits `mode & 07777` |
| `int64_t ec_fd_lock(int32_t fd, int32_t op)` | | `flock(2)`: `op` `0` unlock, `1` shared, `2` exclusive, `+4` don't wait (`-EWOULDBLOCK` while another open file holds a conflicting lock). The lock belongs to the open file (all `dup`s of it), is advisory, and goes away when the last descriptor of that open file closes |
| `int64_t ec_fd_nonblock(int32_t fd, int32_t on)` | | `0`; `O_NONBLOCK` set (`on != 0`) or cleared. A non-blocking descriptor returns `-EAGAIN` instead of waiting |
| `int64_t ec_fd_dup(int32_t fd)` | | a new descriptor (lowest free, close-on-exec) for the same open file (shared offset and locks) |
| `int64_t ec_pipe(void)` | | `0`; `out` = read end, write end (u32 each). Blocking until `ec_fd_nonblock` |

Stat record (32 bytes): u64 size in bytes; u64 kind (`1` file, `2` directory, `3` other, `4`
symlink, `5` FIFO, `6` socket, `7` character device, `8` block device; the first four as in
`ec_kind`); u64 permission bits (`st_mode & 07777`); u64 modification time in nanoseconds
since the Unix epoch (signed; `st_mtim`, `st_mtimespec` on macOS).

## SIGPIPE

Writing to a pipe or socket whose reader has gone raises `SIGPIPE`, which by default kills the
process; servers must not die because a client disconnected. The choice here:

- Socket sends never raise it: `ec_sock_send` / `ec_sock_sendto` pass `MSG_NOSIGNAL`, and on
  macOS and the BSDs every socket the core creates or accepts has `SO_NOSIGPIPE`.
- Plain `write(2)` on a socket or pipe can still raise it, so the first `ec_sock_open`,
  `ec_sock_pair`, `ec_pipe`, or `ec_spawn` with a piped stdin sets `SIGPIPE` to *ignored* for
  the whole process, once. From then on such writes return `-EPIPE`. Programs that never
  touch sockets or pipes keep the default (so `prog | head` still ends `prog` quietly).
  `ec_signal_set(13, 0)` restores the default afterwards if a program wants it.
- Children never inherit it: `ec_spawn` and `ec_run` reset `SIGPIPE` to the default in the
  child before `exec` (an ignored signal would otherwise survive `exec`; this is the classic
  "`yes | head` never ends" bug).

Why not ignore it at startup in every program, as Rust does: the core has no startup hook, and
a program that only prints should still die quietly on a closed stdout.

## Addresses

Socket addresses cross the boundary as bytes, the same on every system:

| Bytes | IPv4 (7 bytes) | IPv6 (23 bytes) | Unix domain (3 + n bytes) |
|---|---|---|---|
| 0 | `4` | `6` | `1` |
| 1..3 | port, big-endian | port, big-endian | `0 0` |
| 3.. | 4 address bytes (network order) | 16 address bytes, then the scope id (u32 LE) | the path, n bytes, no NUL |

A Unix path must be shorter than the system's `sun_path` (104 or 108 bytes), else
`-EINVAL`. An empty path is the unnamed address (what an accepted or `socketpair` peer shows).
On Linux a path whose first byte is NUL is an abstract name, its bytes taken exactly. Any other
length or family byte is `-EINVAL`. An address of an unknown family in a result is `0 0 0`.
The IPv6 flow label is always 0.

## Sockets

| Function | Arguments | Result |
|---|---|---|
| `int64_t ec_sock_open(int32_t family, int32_t type, int32_t nonblock)` | | the socket. `family` `4` IPv4, `6` IPv6, `1` Unix (else `-EAFNOSUPPORT`); `type` `1` stream (TCP), `2` datagram (UDP) (else `-EINVAL`). Non-blocking when `nonblock != 0` |
| `int64_t ec_sock_pair(int32_t type)` | | `0`; `out` = two connected Unix-domain sockets (u32 each) |
| `int64_t ec_sock_bind(int32_t fd)` | `in` = address | `0`. Port `0` picks a free port (read it back with `ec_sock_name`) |
| `int64_t ec_sock_listen(int32_t fd, int32_t backlog)` | | `0`; `backlog` is a hint, capped by the system |
| `int64_t ec_sock_accept(int32_t fd, int32_t nonblock)` | | the connection's socket (non-blocking when `nonblock != 0`, whatever the listener is); `out` = the peer's address. `-EAGAIN` on a non-blocking listener with nothing pending; `-ECONNABORTED` (a connection reset before it was accepted) is worth retrying |
| `int64_t ec_sock_connect(int32_t fd)` | `in` = address | `0` when connected. A non-blocking socket returns `-EINPROGRESS`: wait until it is writable (`ec_poll_*`), then `ec_sock_error` says how it went. A blocking connect interrupted by a signal cannot be restarted, so the core waits for it to finish |
| `int64_t ec_sock_error(int32_t fd)` | | the pending error (`SO_ERROR`, which clears it): `0` or `-errno` (`-ECONNREFUSED`, `-ETIMEDOUT`, ...) |
| `int64_t ec_sock_shutdown(int32_t fd, int32_t how)` | | `0`; `how` `0` no more reading, `1` no more writing (the peer reads end of stream), `2` both |
| `int64_t ec_sock_send(int32_t fd)` | `in` = bytes | the count sent (one `send(2)`, never `SIGPIPE`); `-EPIPE` / `-ECONNRESET` once the peer is gone |
| `int64_t ec_sock_recv(int32_t fd, int64_t max, int32_t peek)` | | up to `max` bytes (at most 1 MiB) into `out`; the count, `0` at end of stream. `peek != 0` leaves them queued |
| `int64_t ec_sock_sendto(int32_t fd, int32_t addr_len)` | `in` = address (`addr_len` bytes), then the datagram | the count sent |
| `int64_t ec_sock_recvfrom(int32_t fd, int64_t max)` | | the datagram's length as received (at most `max`; a longer datagram is truncated and the rest dropped); `out` = u8 A, the sender's address (A bytes), the data |
| `int64_t ec_sock_name(int32_t fd, int32_t peer)` | | `0`; `out` = the local address (`peer == 0`, `getsockname`) or the peer's (`getpeername`; `-ENOTCONN` if none) |
| `int64_t ec_sock_setopt(int32_t fd, int32_t opt, int64_t value)` | | `0`; option table below |
| `int64_t ec_sock_getopt(int32_t fd, int32_t opt)` | | the option's value |

| `opt` | Option | Value |
|---|---|---|
| `1` | `SO_REUSEADDR` | `0`/`1`: rebind a listening port while old connections are in `TIME_WAIT` |
| `2` | `SO_REUSEPORT` | `0`/`1`; `-ENOPROTOOPT` where the system has none (semantics differ: Linux balances connections across the sockets, the BSDs and macOS let the newest one take over) |
| `3` | `TCP_NODELAY` | `0`/`1`: send small segments at once (no Nagle delay) |
| `4` | `SO_KEEPALIVE` | `0`/`1` |
| `5` | `SO_RCVBUF` | bytes (Linux doubles what it is given and reports the doubled size) |
| `6` | `SO_SNDBUF` | bytes (as above) |
| `7` | `IPV6_V6ONLY` | `0`/`1`, IPv6 sockets only: refuse IPv4-mapped peers (set it before `bind`) |
| `8` | `SO_BROADCAST` | `0`/`1`, datagram sockets |
| `9` | `SO_RCVTIMEO` | milliseconds, `0` none: a blocking receive returns `-EAGAIN` after this long |
| `10` | `SO_SNDTIMEO` | milliseconds, `0` none (as above, for sends) |

Booleans read back as the system reports them: non-zero is on. Any other `opt` is `-EINVAL`.

## Name resolution

| Function | Arguments | Result |
|---|---|---|
| `int64_t ec_dns_lookup(int32_t family, int32_t socktype, int32_t flags)` | `in[0]` host, `in[1]` service (a port number or a name from `/etc/services`); either may be empty | `getaddrinfo`: the number of results; `out` = for each, u8 socktype (`1` stream, `2` datagram, `0` other), u8 A, the address (A bytes), in the resolver's order (try them in turn). `family` `0` any, `4`, `6`; `socktype` `0` any (each address then comes once per socket type), `1`, `2`; `flags` `1` passive (an empty host is the wildcard address, for `bind`; without it, loopback), `2` the host must be numeric (no lookup at all), `4` only families the machine has addresses for |
| `int64_t ec_dns_reverse(int32_t flags)` | `in` = address | `getnameinfo`: `0`; `out` = host NUL service. `flags` `1` numeric host, `2` numeric service, `4` fail if the host has no name, `8` the service is a datagram one |

Resolver failures are not errno values, so they get their own range: `-1000001` no such name
(`EAI_NONAME`, also `EAI_NODATA` / `EAI_ADDRFAMILY`), `-1000002` temporary failure, try again
(`EAI_AGAIN`), `-1000003` permanent failure (`EAI_FAIL`, and any code not listed),
`-1000004` family, `-1000005` socket type, `-1000006` service, `-1000007` out of memory,
`-1000008` bad flags, `-1000009` buffer overflow. `EAI_SYSTEM` is the `-errno` it carries.
`ec_errstr` gives the resolver's message (`gai_strerror`) for these.

Resolution blocks the calling thread (it may read files and query DNS servers, with the
resolver's own timeouts); the runtime layer moves it off an event-loop thread. Results are
IPv4 and IPv6 only.

## Readiness

An event loop primitive: epoll on Linux, kqueue on macOS and the BSDs. One poller watches many
descriptors; each registration carries a 64-bit token that comes back with its events.

| Function | Arguments | Result |
|---|---|---|
| `int64_t ec_poll_new(void)` | | the poller's descriptor (close with `ec_fd_close`) |
| `int64_t ec_poll_ctl(int32_t pfd, int32_t op, int32_t fd, int32_t interest, int64_t token)` | | `0`. `op` `0` add (`-EEXIST` if already there), `1` modify (`-ENOENT` if not there, on epoll), `2` remove. `interest`: `1` readable, `2` writable, `+4` edge-triggered (report only changes), `+8` one-shot (after one event the registration is disarmed until the next modify) |
| `int64_t ec_poll_wait(int32_t pfd, int32_t max, int64_t timeout_ms)` | | the number of events (at most `max`, capped at 1024); `out` = that many 16-byte records. `timeout_ms` `< 0` wait forever, `0` don't wait. A signal ends the wait early (it is not resumed): the core then collects whatever is ready without waiting, so a watched signal shows up at once as its signal pipe's event. The result can be `0` events (a spurious wakeup, which a loop must tolerate anyway) |
| `int64_t ec_waker_new(void)` | | `0`; `out` = read end, write end (u32 each; on Linux one `eventfd`, so both are the same descriptor; a pipe elsewhere). Both non-blocking. Register the read end for reading |
| `int64_t ec_waker_wake(int32_t wfd)` | | `0`: the read end becomes readable. Safe from any thread and from a signal handler; waking an already-woken waker is not an error. Drain it with `ec_read_fd(r, 4096)` (until `-EAGAIN`) |
| `int64_t ec_fd_wait(int32_t fd, int32_t interest, int64_t timeout_ms)` | | one descriptor's readiness, without a poller (`poll(2)`): `interest` `1` readable, `2` writable, or both (anything else `-EINVAL`); waits at most `timeout_ms` (`< 0` forever, `0` not at all). The flags that are set (`1` readable, `2` writable, `4` error, `8` hang-up; error and hang-up are reported whatever the interest), or `0` when the time ran out; `-EBADF` for a descriptor that isn't open. A signal doesn't end the wait: it resumes with the time left (measured on the monotonic clock). This is how a thread blocks on its own waker with a deadline (std/sync's Parker) and how std/fd waits for one descriptor |
| `int64_t ec_fd_wait2(int32_t fd, int32_t interest, int32_t fd2, int32_t interest2, int64_t timeout_ms)` | | two descriptors' readiness at once (`poll(2)` on both), each with its own `interest` as in `ec_fd_wait`; the flags of `fd` in bits 0-3 and of `fd2` in bits 4-7, `0` when the time ran out, `-EBADF` if either is not open. How a connection waits for its socket and a server's stop signal without a poller of its own (std/fd `wait_ready2`). In a task it parks the task like `ec_fd_wait` (the descriptors must differ for that; equal ones block the thread) |
| `int64_t ec_fd_wait_ev(int32_t fd, int32_t interest, int64_t parker, int64_t timeout_ms)` | | `ec_fd_wait` that also ends when the parker (below) is unparked: the descriptor's flags, plus `256` if the parker's permit was taken (the permit is then gone); both can be set; `0` at the deadline; `-EBADF` for a handle that is not a parker. How a wait on a descriptor is cancelled (std/task `Token.wait_fd`) |

Event record: u64 token; u32 flags: `1` readable, `2` writable, `4` error (read `ec_sock_error`),
`8` hang-up (no more writing is possible), `16` the peer has finished sending (reads will hit
end of stream); u32 zero.

Differences a caller must allow for (the event loop in layer/runtime does):

- kqueue reports reading and writing as separate events with the same token; epoll reports one
  event with both bits. Merge by token if it matters.
- Level-triggered (the default) reports a ready descriptor on every wait until drained;
  edge-triggered only after a change, so drain until `-EAGAIN`.
- With kqueue a registration ends when its descriptor closes; with epoll, when the last
  descriptor of the open file closes (a `dup` keeps it alive). Remove before closing.
- On 32-bit macOS and BSD the token travels in a pointer-sized field, so only its low 32 bits
  survive.

## Parkers

A Parker is what one thread or task waits on and another wakes: a permit (an unpark leaves one,
a park takes it; several unparks before a park are one) and at most one waiter, named by a
handle. It is a small entry in a table of the core, not a descriptor, so a hundred thousand
tasks can each wait on one. A handle carries a generation: after `ec_parker_close` it is
refused (`-EBADF`), also when its slot has been reused. Safe from any thread; `ec_parker_unpark`
is not async-signal-safe (it takes a lock).

| Function | Arguments | Result |
|---|---|---|
| `int64_t ec_parker_new(void)` | | the handle (> 0), or `-ENOMEM` / `-EMFILE` (4 million parkers) |
| `int64_t ec_parker_park(int64_t h, int64_t timeout_ms)` | | waits until unparked or `timeout_ms` passes (`< 0` forever, `0` not at all): `1` unparked (the permit is taken), `0` the time ran out, `-EBADF`. In a task it parks the task (core/RUNTIME.md "Tasks"), else the thread waits on a waker of its own |
| `int64_t ec_parker_unpark(int64_t h)` | | `0`; wakes the waiter or leaves the permit; `-EBADF` for a closed handle (ignored by callers) |
| `int64_t ec_parker_clear(int64_t h)` | | `0`; takes the permit away without waiting |
| `int64_t ec_parker_close(int64_t h)` | | `0`; the handle is dead from now on. Close a parker only when nobody waits on it |

After `fork` the child's parkers keep their permits and have no waiters (the parent's threads and
tasks are not there). `ec_fd_wait_ev` (Readiness) waits for a descriptor and a parker at once.

## Time

| Function | Result |
|---|---|
| `int64_t ec_time_mono_ns(void)` | nanoseconds on the monotonic clock, from an arbitrary start: never goes backwards, unaffected by setting the time. `CLOCK_MONOTONIC` (Linux, BSD: does not count suspend on Linux); `CLOCK_UPTIME_RAW` on macOS (does not count sleep, as `mach_absolute_time`). For durations and deadlines |
| `int64_t ec_time_wall_ns(void)` | nanoseconds since 1970-01-01 00:00 UTC (`CLOCK_REALTIME`), negative before it. It jumps when the clock is set: for timestamps, never for durations |
| `int64_t ec_sleep_ns(int64_t ns)` | `0` after at least `ns` ns (`nanosleep`, resumed with the remaining time after each signal); `ns <= 0` returns at once |

The language's `now_ms()` (`ei_now_ms`, core/RUNTIME.md) is now monotonic milliseconds too; it
used to be processor time, which stood still while the program slept or waited.

## Signals

Signals arrive as bytes on a pipe, so they are just another readable descriptor for the poller
(the self-pipe pattern). One mechanism on every system: the handler only calls `write(2)`, which
is async-signal-safe, and it works whichever thread the kernel picks (signalfd would need the
signal blocked in every thread, including ones C libraries start).

| Function | Arguments | Result |
|---|---|---|
| `int64_t ec_signal_fd(void)` | | the read end of the process's signal pipe: created on first use, the same descriptor every time, non-blocking. Each delivery of a signal set to `2` is one byte, its number. Read it with `ec_read_fd`. Never close it |
| `int64_t ec_signal_set(int32_t sig, int32_t how)` | | `0`. `how` `0` the default action, `1` ignore, `2` deliver to the signal pipe (with `SA_RESTART`; `SIGCHLD` with `SA_NOCLDSTOP`). `-EINVAL` for an unknown number or `SIGKILL`/`SIGSTOP` |
| `int64_t ec_signal_mask(int32_t sig, int32_t block)` | | `0`; blocks (`block != 0`) or unblocks `sig` in the calling thread. A blocked signal stays pending until unblocked (then it is delivered) |

Signal numbers are the traditional ones, the same in Eider on every system (the core
translates): `1` HUP, `2` INT, `3` QUIT, `6` ABRT, `9` KILL, `10` USR1, `12` USR2, `13` PIPE,
`14` ALRM, `15` TERM, `17` CHLD, `18` CONT, `19` STOP, `20` TSTP, `28` WINCH. `ec_kill` and
`ec_wait` use them too. (`ec_run` still reports `128 + n` with the native number, as before.)

A graceful shutdown is: `ec_signal_set(15, 2)` and `ec_signal_set(2, 2)`, register
`ec_signal_fd()` with the poller, and on reading `15` or `2` stop accepting, drain, exit. If the
pipe is full (64 KiB of undelivered signals) further deliveries are dropped; signals of one kind
coalesce in the kernel anyway. Children start clean: `ec_spawn` / `ec_run` block signals across
`fork`, and the child resets every signal the core delivers (and `SIGPIPE`) to the default and
empties its mask before `exec`.

## Randomness

| Function | Result |
|---|---|
| `int64_t ec_random(int64_t n, int32_t nonblock)` | `n` (at most 1 MiB, else `-EINVAL`); `out` = `n` bytes from the operating system's CSPRNG |

Linux: `getrandom(2)` without `GRND_RANDOM`. It never returns predictable bytes: until the
kernel pool has been seeded once after boot it blocks, or with `nonblock != 0` returns
`-EAGAIN` (`GRND_NONBLOCK`; only early-boot programs ever see it). Partial reads and `EINTR`
are continued. Needs glibc 2.25 or musl 1.1.20. macOS and the BSDs: `arc4random_buf` (the
kernel's CSPRNG; it cannot fail or block; `nonblock` is ignored). There is no fallback: a
system with neither returns `-ENOSYS`, never bytes derived from the time or the pid. This is
what seeded hashing (SipHash keys) and the std CSPRNG build on.

`int64_t ec_random_fill(void *dst, uint64_t n)` is the same randomness for C that is linked into
the program, straight into `dst` (at most 256 bytes) and through no buffer, so it can run in the
middle of a sequence of core calls: 0, or `-errno`, and it blocks until the kernel pool is seeded
(no `nonblock`). The language runtime uses it, once per thread, for the hash key of `Map`s
(core/RUNTIME.md "Map hashing"). Eider does not bind it.

## Processes

| Function | Arguments | Result |
|---|---|---|
| `int64_t ec_spawn(int32_t in_mode, int32_t out_mode, int32_t err_mode)` | `in` = argv (NUL-separated; `argv[0]` searched on `PATH`) | the child's pid; `out` = our ends of its stdin, stdout and stderr pipes (u32 each, `-1` where not a pipe; close-on-exec, blocking). Each mode: `0` inherit ours, `1` `/dev/null`, `2` a pipe. Exec failure is the result (`-ENOENT`, `-EACCES`), with the child already reaped |
| `int64_t ec_wait(int32_t pid, int32_t nohang)` | | `waitpid` (`pid -1`: any child): `0..255` the exit code, `256 + n` killed by signal `n`; `-EAGAIN` with `nohang != 0` while it still runs; `-ECHILD` if there is no such child. `out` = the reaped pid (u32) |
| `int64_t ec_kill(int32_t pid, int32_t sig)` | | `0`; `sig 0` only checks that `pid` exists. A negative `pid` is a process group |
| `int64_t ec_getpid(void)` | | this process's id |

The child: signals reset as in Signals; no descriptor of ours except its 0..2 (everything the
core makes is close-on-exec); same environment, current directory and process group. Unlike
`ec_run`, nothing reaps a spawned child on its own: call `ec_wait` (a `SIGCHLD` event says
when) or it stays a zombie until this process ends. Pipe handling (and deadlines) belongs to the
caller's event loop.

## Atomic cells

64-bit integers that every thread may read and change with atomic operations (C11
`<stdatomic.h>`), for std/atomic until the language has a built-in atomic type
(core/RUNTIME.md "Atomics"). Not an OS operation, but the same rules: one atomic operation per
function, no pointers cross. Eider holds a cell by a **handle**: `(generation << 32) | index`,
always `> 0`. Cells sit in chunks of 4096 that are allocated on first use and never freed or
moved (at most 4096 chunks, 16M cells in use at once), so every operation on any handle
touches valid memory. A cell's generation is odd while it is in use and even while it is free;
a handle whose generation is not its cell's current one (the cell was freed, or the number was
never a handle) ends the process: `eider: runtime error: invalid atomic handle (freed, or not
made by atomic.new)` on stderr after flushing stdout, exit code `101`, like a trap (the
operations return values, so they have no error result to give). A slot whose generation would
no longer fit 31 bits is retired instead of reused, so a stale handle is never mistaken for a
new one.

`order` is the memory ordering: `0` relaxed, `1` acquire, `2` release, `3` acquire-release,
`4` sequentially consistent. One that doesn't apply to the operation (release on a load,
acquire on a store) or an unknown number is sequentially consistent (std/atomic refuses the
inapplicable ones before calling). A failed compare-and-swap is a load with the success
ordering minus its release half.

| Function | Result |
|---|---|
| `int64_t ec_atomic_new(int64_t v)` | a new cell holding `v`: its handle, or `-ENOMEM` (no memory for a chunk, or 16M cells in use). Takes a process-wide lock (allocation only) |
| `int64_t ec_atomic_free(int64_t h)` | `0`; the cell is free and every copy of `h` invalid. `-EINVAL` if `h` is not a cell in use (freed already, or not a handle): nothing changes |
| `int64_t ec_atomic_load(int64_t h, int32_t order)` | the value |
| `int64_t ec_atomic_store(int64_t h, int64_t v, int32_t order)` | `0`; the cell holds `v` |
| `int64_t ec_atomic_swap(int64_t h, int64_t v, int32_t order)` | the value it held; it holds `v` |
| `int64_t ec_atomic_add(int64_t h, int64_t n, int32_t order)` | the value it held; it holds that plus `n`, wrapping (two's complement, as C11 defines for atomic types; std/atomic's checked `add` is a compare-and-swap loop) |
| `int64_t ec_atomic_cas(int64_t h, int64_t expected, int64_t desired, int32_t order)` | the value it held; if that was `expected` it now holds `desired` (strong: never fails spuriously) |

Lock-freedom: the operations are lock-free where `_Atomic int64_t` is (every 64-bit target;
32-bit targets may use the C library's locks, which is correct but slower). Freeing a cell
while another thread still uses it is a bug in the program, not undefined behaviour: the other
thread's operation either fails the generation check (and ends the process) or, if it already
passed it, acts on the freed cell, which is still valid memory (and, if a later
`ec_atomic_new` has handed the slot out again in between, on that new cell's value: a logic
error, never memory corruption).

## Math

core/libm.ei binds these, and std/math is built on them. Each is one libm call on doubles: no
buffers, no state, no errors (a domain error is a NaN, an overflow an infinity, as IEEE says).
They are pure: the wrappers declare only `ffi`, which doesn't leave `core`, so a caller declares
no capability. libm is referenced weakly (`#pragma weak`) so a program that never calls them
(the seed's cc-only bootstrap, a C consumer of an Eider library's .a) links without `-lm`;
`eiderc build` links `-lm`. In a `--wasm` module `ec_m_sqrt`, `ec_m_floor`, `ec_m_ceil`,
`ec_m_trunc` and the bit casts are defined in core/wasm/libc.c, and the others are imports of
`env` that the generated loader fills in with JavaScript's `Math`.

| Function | Meaning |
|---|---|
| `double ec_m_f(double x)` | `f` is one of `sqrt cbrt exp exp2 expm1 log log2 log10 log1p sin cos tan asin acos atan sinh cosh tanh asinh acosh atanh floor ceil trunc round rint` (`round` half away from zero, `rint` half to even) |
| `double ec_m_f(double x, double y)` | `f` is one of `pow atan2 hypot fmod` |
| `double ec_m_fma(double x, double y, double z)` | `x * y + z` fused |
| `uint64_t ec_f64_bits(double x)`, `double ec_f64_from_bits(uint64_t b)` | the IEEE bits of an f64 and back |
| `uint32_t ec_f32_bits(float x)`, `float ec_f32_from_bits(uint32_t b)` | the same for f32 |

## Profiling

One call, for std/profile (through core/prof.ei). The core does no profiling itself: a
program built with `--profile` links the runtime's profiler (core/eider_prof.c,
core/RUNTIME.md "Profiling"), which registers its control function in the core's
`ec_prof_hook` when it starts; the core forwards the call and the input buffer to it.

| Function | Meaning |
|---|---|
| `int64_t ec_prof(int32_t op, int64_t arg)` | without a profiler: `-ENOSYS`. Otherwise op 0: `1 + 2 * sampling`; 1 start sampling; 2 stop; 3 reset what was recorded; 4 write a snapshot to the path in `in` (empty: the profile path), 0 or `-errno`; 5 add the label `key NUL value` in `in` to this thread's labels, returning the previous label set's id; 6 restore label set `arg`; 7 this thread's label set. Unknown ops: `-EINVAL` |

It is the one function here that isn't an OS call, and the exception is deliberate: Eider
can't reach the runtime (eider_rt has no `ec_*` symbols and binds to nothing), and this is
the smallest bridge that lets a program built with the profiler control it, while every
other program links the same core and gets `-ENOSYS`.

## WebAssembly

None of these functions exist in `core/wasm/`: a wasm module has no descriptors, sockets,
clocks of its own beyond `eider_now_ms`, signals or processes. As for every `ec_*` function, a
program built with `build --wasm` that reaches one through `std` imports it from the host
(`env.ec_sock_open` ...); unless the host supplies them, instantiating the module fails with a
link error naming the missing import, before any code runs (Node:
`LinkError: WebAssembly.instantiate(): Import #0 "env" "ec_time_mono_ns": function import
requires a callable`, for a module whose export calls `time.mono_ns()`). That is the clean
failure: no partial run, and the name says which primitive was wanted. A host that wants to
offer one (say, a clock) passes it in the loader's `imports`. Mirroring them in `core/wasm/`
would only be meaningful for the clocks, and `now_ms` already covers that.

## Core extensions

C that is linked into the same program and implements more of this ABI over the same buffers
(today only `core/crypto/eider_crypto.c`) reaches them through `core/eider_core_ext.h`:
`ec_ext_in` (the bytes and length of `in`), `ec_ext_out(n)` (make `out` n bytes and write
them), `ec_ext_out_truncate`, `ec_ext_in_wipe` and `ec_ext_wipe`. They hand out pointers, so
Eider never binds them; they are not `ec_*` operations.

Because `in` and `out` can hold keys and plaintext, the core zeroes a buffer's old block when
it grows (malloc, copy, wipe, free: never `realloc`), zeroes both when a thread's buffers are
freed, and the `ec_ext_*wipe` calls zero everything written since the last wipe (a high-water
mark, so a wipe costs what was written, not the capacity). The zeroing goes through a
volatile function pointer to `memset`, so it is not removed as a dead store.

## Crypto

`core/crypto/eider_crypto.h` is the crypto half of the ABI: `ec_crypto_*` operations
(hashes, HMAC, HKDF, AEAD, X25519, Ed25519, P-256, constant-time compare, randomness, and a
capability query), one call sequence into an OpenSSL-compatible libcrypto each, in the one
file `core/crypto/eider_crypto.c`. The rules above hold: fixed-width arguments, inputs
concatenated in `in` (every part's length but the last passed as an argument), results in
`out`, status codes `< 0` (`EC_CRYPTO_E*`, -5001..-5005, disjoint from `-errno`). In
addition every operation zeroes `in` before it returns and empties `out` when it fails;
`ec_crypto_wipe` zeroes both once Eider has copied a result. Eider binds them in
`core/crypto.ei` (core's second module with `extern`, binding only `ec_crypto_*`). The
backend library is chosen at link time; a program that doesn't import `core/crypto` links
none. Contract, backends, the API subset and tests: `core/crypto/README.md`.

## Backends

| Target | Status |
|---|---|
| Linux (glibc), x86-64 | exercised by `tests/core` (`core_test.c`: `ec_run`, `ec_read_fd`; `os_test.c`: every OS primitive, with epoll, and the atomic cells), `tests/std` and the package tests, with gcc and clang, under ASan+UBSan and TSan |
| Linux, other architectures (aarch64, riscv64, 32-bit) | expected to work (C11 + POSIX only, fixed-width ABI); not yet run |
| macOS | written (`_NSGetArgv`, `EC_SYM` names, kqueue, `arc4random_buf`, `F_FULLFSYNC`, `SO_NOSIGPIPE`); not yet compiled or run |
| FreeBSD / OpenBSD / NetBSD / DragonFly | written (args via an init-array constructor, kqueue, `accept4`, `arc4random_buf`); not yet compiled or run |
| other POSIX systems | compiles (checked on glibc with the Linux branches turned off): the poller is `-ENOSYS` and randomness `-ENOSYS` (no fallback); everything else is POSIX |
| Windows | not written; `eider_core.c` refuses to compile there |
| WebAssembly (wasm32) | none: a module has no OS. The runtime has a wasm backend (`core/wasm/`); `ec_*` calls become host imports (`core/wasm/README.md`) |

The compiler itself (`seed/eiderc.wasm` and its self-hosting chain) is also only exercised on x86-64 Linux.
