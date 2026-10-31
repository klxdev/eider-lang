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

## Backends

| Target | Status |
|---|---|
| Linux (glibc), x86-64 | exercised by `tests/core` (`core_test.c`: `ec_run`, `ec_read_fd`; `os_test.c`: every OS primitive, with epoll), `tests/std` and the package tests, with gcc and clang, under ASan+UBSan and TSan |
| Linux, other architectures (aarch64, riscv64, 32-bit) | expected to work (C11 + POSIX only, fixed-width ABI); not yet run |
| macOS | written (`_NSGetArgv`, `EC_SYM` names, kqueue, `arc4random_buf`, `F_FULLFSYNC`, `SO_NOSIGPIPE`); not yet compiled or run |
| FreeBSD / OpenBSD / NetBSD / DragonFly | written (args via an init-array constructor, kqueue, `accept4`, `arc4random_buf`); not yet compiled or run |
| other POSIX systems | compiles (checked on glibc with the Linux branches turned off): the poller is `-ENOSYS` and randomness `-ENOSYS` (no fallback); everything else is POSIX |
| Windows | not written; `eider_core.c` refuses to compile there |
| WebAssembly (wasm32) | none: a module has no OS. The runtime has a wasm backend (`core/wasm/`); `ec_*` calls become host imports (`core/wasm/README.md`) |

The compiler itself (`seed/eiderc.c` and its self-hosting chain) is also only exercised on x86-64 Linux.
