# The standard library (layer/std)

std is the Eider code almost every program needs, on top of the C core (LAYERS.md). It is
pure Eider: it imports only `core/sys`, `core/os` and other std modules, and its functions
declare exactly the capabilities they reach (docs/compiler.md, "C8.5"). This page is the
overview; each module's doc comments are the reference. The runtime layer (atomics,
channels, tasks, the event loop) has its own page, docs/runtime.md.

| Module | What | Capabilities |
|---|---|---|
| `bytes` | text as `List[u8]`: compare, find, split, trim, decimal conversion | none |
| `fs`, `io`, `env`, `proc` | files and directories by path; stdout/stderr/stdin as raw bytes; the environment; running a program to completion | `fs`; `io`; `io`; `io, fs, net` |
| `fd`, `net`, `poll`, `time`, `random`, `signal`, `child` | the thin OS layer over core/ABI.md (descriptors, sockets and DNS, readiness, clocks and `Duration`/`Deadline`, the CSPRNG, signals, child processes) | as each call |
| `atomic`, `sync`, `chan`, `task`, `event` | the runtime layer (docs/runtime.md) | as each call |
| **`stream`** | `Reader`/`Writer`, typed `Error`s, `BufReader`/`BufWriter`, streams over descriptors (files, pipes, sockets, child streams, stdin/stdout/stderr) and memory; deadlines on everything | `io` (+ `clock` for deadlines); `fs` to open files, `net` to connect and accept |
| **`path`** | POSIX paths as bytes: join, parent, file_name, extension, stem, normalize, components, relative_to | none |
| **`strings`** | String operations over `str` or `String`: find, split, fields, lines, trim, replace, case, integer parsing with errors | none |
| **`utf8`** | validation, decoding with U+FFFD replacement, iteration, encoding, lossy conversion | none |
| **`fmt`** | integers in any radix with width, fill, alignment, sign, prefix and zero padding; padding text; a String `Builder` | none |
| **`sort`** | stable merge sort, `sort_by`, `sort_by_key`, binary search, bounds, dedup, min/max | none |
| **`deque`**, **`set`**, **`heap`** | `Deque[T]`; `Set[T: Hash + Eq]`; `Heap[T: Ord]` (min or max) and a stable priority `Queue[T]` | none |
| **`encoding`** | hex, base64 (standard and URL-safe, padded or not, strict decoding), little/big-endian integers | none |
| **`testing`** | `assert_eq` with a diff, `Suite`, `diff_lines`; test doubles: `FakeClock`, scripted Reader and Writer, an in-memory pipe | `io` to print |

The modules in bold are layer/std's first wave (decisions C23 to C29, C36 and C37). Their tests are in
tests/std (one program and its expected output per module group; tests/std/run.sh, part of
scripts/verify.sh), and each passes under gcc, clang and ASan+UBSan.

## Streams (`std/stream`)

```eider
import "std/stream"
import "std/net"
import "std/time"

fn handle(conn: stream.Fd) -> Result[(), stream.Error] uses io, clock {
    var r = stream.buffered(conn)
    var w = stream.buffered_writer(conn)
    let dl = time.after_ms(5000)                    // one budget for the whole exchange
    while true {
        let line = match r.read_line_by(8192, dl)? { // limit and deadline, both explicit
            Some(l) => l
            None => break                            // the peer closed
        }
        stream.write_all(inout w, line)?
        stream.write_str(inout w, "\n")?
    }
    w.flush_by(dl)
}
```

**The traits.** `Reader` has `read(max)` (between 1 and `max` bytes; none at end of stream)
and `read_by(max, dl)`. `Writer` has `write(data)` (the count written, at least 1 byte),
`write_by`, `flush` and `flush_by`. Everything else is a generic function over them
(`read_all`, `read_exact`, `read_text`, `write_all`, `write_str`, `copy`, each with a `_by`
form), because traits have no default methods yet.

**Errors** are values of `stream.Error = { kind: Kind, message: String }`. `Kind` is the
core's portable error kinds (core/ABI.md "Error kinds": WouldBlock, NotFound,
ConnectionReset, TimedOut, ...) plus the stream layer's own: UnexpectedEof, InvalidData,
WriteZero. Code acts on the kind (`e.kind == stream.TimedOut`) and shows the message
(`print(e)`: "read: Connection reset by peer"). `stream.plain(r)` turns a result into one
with a String error, for code written against the String-error APIs of `fs`, `net`, ...

**Deadlines (C5).** Every blocking operation has a `_by(..., dl: time.Deadline)` form, and
when the deadline passes it returns `Err` with kind `TimedOut`, so it composes with `?`
like any other error. A deadline (not a timeout) is what is passed down, so a chain of calls
shares one budget.

**Cancel-safety**, per operation:

| Operation | On TimedOut |
|---|---|
| `read_by`, `write_by` of any stream | nothing consumed or written |
| `BufReader`'s `read_line_by`, `read_until_by`, `read_exact_by`, `peek_by`, `read_to_end_by` | every byte received stays buffered: call again |
| `BufWriter.flush_by` (and a `write_by` that has to flush) | what wasn't written stays buffered |
| `write_all_by` | partial: the message says how many bytes were written |
| `read_exact_by`, `read_all_by` on an unbuffered stream | what was read is lost: use a BufReader |

**Limits.** `read_line(max)` and `read_until(delim, max)` take the longest line they accept;
past it they fail with InvalidData and leave the bytes buffered. `stream.UNLIMITED` is there
for input you trust; a server should always pass a number (the HTTP header-size lesson of
docs/research/zig.md).

**The streams.**

- `Fd`: any descriptor. `stream.open(path, flags, mode)` (std/fd's flags), `open_read`,
  `create`, `open_append`, `pipe()`, `stdin()`/`stdout()`/`stderr()`, `fd(n)` for anything
  else (a std/net socket, a std/child stream). It works in either mode: on a non-blocking
  descriptor `read` and `write` wait for readiness rather than failing with WouldBlock, so
  the deadline forms are exact. Writes to stdout and stderr flush `print`'s buffer first, so
  the two stay in order. Reading and writing is `io` whatever the descriptor is (a socket is
  read with read(2), like any descriptor); opening a file is `fs`.
- Sockets: `connect_by(addr, dl)` connects with a deadline and `accept_by(listener, dl)`
  accepts with one (both `net`); the connections they return are non-blocking, so a deadline
  on them is never overrun by a long write. `shutdown_write` half-closes.
- Memory: `reader(bytes)` / `reader_str(text)` (a `Bytes`, which also reads lines itself,
  needing no BufReader), `buffer()` (a `Buffer` collecting what is written), `discard()`.
- `BufReader[R]` (`buffered`, `buffered_with(r, cap)`): `read_line`, `read_until`, `peek`,
  `read_exact`, `read_to_end`, `consume`, `available`; a read bigger than the buffer bypasses
  it. `BufWriter[W]` (`buffered_writer`): collects small writes; **call `flush`**: nothing
  flushes it when it goes away (C26). Both are Readers/Writers themselves, so they nest.

**Capabilities and generic code.** The traits declare `uses io` (and `io, clock` for the
deadline forms). An in-memory stream called directly needs nothing, but through generic
code (`BufReader[Bytes]`, `read_all`) it needs `io` too: a generic body is checked with the
capabilities of every type it could be given, so it must declare the most any stream needs
(see "Needs the compiler").

## Text (`std/strings`, `std/utf8`, `std/fmt`)

`strings` works on Strings (which are always valid UTF-8 without NUL); every text argument
is a `Text`, a `str` literal or a `String`, so `strings.split(line, ",")` needs no
conversions. Offsets are bytes; a needle found in valid UTF-8 always falls on character
boundaries, so every result is a valid String. Case mapping and whitespace are ASCII only.
Integer parsing (`parse_i64`, `parse_u64`, `parse_i32`, `parse_u32`, `parse_u8`,
`parse_usize`, and `parse_int_radix`/`parse_uint_radix` with limits) is strict (an
optional sign, digits, nothing else) and returns a `ParseError` saying what was wrong
(Empty, InvalidDigit at a byte offset, OutOfRange).

`utf8` works on bytes from outside (sockets, files): `valid`, `first_invalid`, `decode`
(one scalar value, with its length and validity), `chars` (an iterator), `count`,
`encode`/`push`, `lossy`. Invalid input decodes as U+FFFD once per maximal subpart (Unicode
and WHATWG's rule, so every conforming decoder counts the same), and validity is exactly
`String.from_bytes`'s (RFC 3629).

`fmt` formats integers: `fmt.int(n)`, `fmt.hex(n)`, and with a `Spec` built by chaining,
`fmt.uint_with(255, fmt.spec().hex().prefix().width(8).zero())` is "0x0000ff". Widths count
characters. `put_*` forms append to a String, and a `Builder` collects pieces (`add`,
`add_int`, `add_show` for any Show value, `add_pad`). Floats wait for f64 (C9); string
interpolation is roadmap P0.5.

## Collections (`std/sort`, `std/deque`, `std/set`, `std/heap`)

All are values (copies don't share) over any element type with the operation traits they
need (docs/compiler.md "C8.4"): `sort[T: Ord]`, `Set[T: Hash + Eq]`, `Heap[T: Ord]`. `sort`
is a stable bottom-up merge sort (insertion sort on runs of 16) that returns a new List;
`sort_by` takes a comparison closure, `sort_by_key` a key closure. `Deque` is two Lists back
to back (amortized O(1) at both ends, O(1) indexing). `Set` keeps a Map from element to
position plus a List of elements, so it can list them (`items()`); removal swaps the last
element in. `Heap` pops the smallest (`heap.min()`) or largest (`heap.max()`) first;
`Queue[T]` is a priority queue for any `T`, FIFO among equal priorities.

## Encoding (`std/encoding`)

`hex`/`unhex`, `base64`/`unbase64` (standard, padded), `base64_url`/`unbase64_url` (URL-safe,
unpadded; padding accepted when decoding), and `base64_encode`/`base64_decode` with an
`Alphabet` and a `Padding` rule. Decoders are strict: whitespace, wrong padding and
non-canonical trailing bits are errors (`DecodeError` with a kind and an offset), so a value
has one encoding. Integers: `push_u32_le(inout out, v)` ... and `u32_le(bytes, at) ->
Option[u32]` ..., for 16 (in a u32), 32 and 64 bits, unsigned and signed, both byte orders;
`bits64`/`signed64` convert two's complement.

## Testing (`std/testing`, `time.Clock`)

Decision C10: since I/O goes through interfaces, tests can replace it.

- `time.Clock` (in std/time) is a trait with `mono_ns`, `wall_ns` and `sleep`;
  `time.system()` is the real clock, `testing.fake_clock(mono, wall)` one that moves only
  when the test calls `advance` (or the code under test sleeps on it). Copies of a FakeClock
  share their time. `time.deadline_on(c, d)`, `expired_on`, `remaining_on` do deadline
  arithmetic on any clock. Code that wants testable time takes a `C: time.Clock`.
- `testing.script(steps, chunk)`: a Reader that plays back `Data(bytes)` (at most `chunk`
  bytes per read, to exercise short reads), `Pause` (a deadline read times out there),
  `Fail(kind)` and `End`. `testing.chunks(data, n)` is the common case.
- `testing.sink(per_write)` and `failing_sink(per_write, fail_at, kind)`: a Writer that
  takes short writes, fails after so many bytes (TimedOut for a deadline write) until
  `heal`, and counts flushes.
- `testing.pipe()`: an in-memory pipe (`r`, `w`); an empty open pipe doesn't wait (WouldBlock,
  or TimedOut at once for a deadline read), so a single-threaded test is deterministic.
- `testing.assert_eq(got, want)` traps after printing both values, the first differing byte
  and, for multi-line text, a line diff (`diff_lines`). `testing.suite(name)` collects
  checks (`eq`, `check`) and reports every failure; `done()` is the exit code.

tests/std/testing.ei tests a small line-protocol service (timeouts mid-line, short reads,
short writes, a reset connection) and a rate limiter on a fake clock this way.

## Needs the compiler

Gaps found while building these modules. Each is worked around as described, never hacked
around in core.

| Gap | Effect today | Wanted |
|---|---|---|
| **Capability polymorphism.** A generic body is checked per instance, so it must declare the union of the capabilities of every type it may be given | `BufReader[Bytes]` and `read_all` on memory need `uses io`; a user Reader that needs `net` can't go through std's generic code (so std's own streams use `io` only: sockets are read with read(2)) | capabilities that follow type parameters (`uses io + R`), or checking a generic body against its bounds' declared capabilities |
| **Default methods in traits** | `stream.read_all(inout r)` rather than `r.read_all()` | trait methods with bodies |
| **Error conversions for `?`** (roadmap P0.6) | `?` can't turn a `stream.Error` into a String or another error type; `stream.plain(r)` converts by hand | `From`, or an `Error` trait |
| **`Drop` that may do I/O** (E0606 forbids capabilities in `drop`) | `BufWriter` can't flush on drop and `Fd` can't close on drop: call `flush`/`close` | a scoped `defer` (P0.3) or a drop with checked capabilities |
| **Iterating a Map** | `Set` keeps its elements in a List beside the Map | `for (k, v) in map`, or `keys()` |
| **In-place List operations and views** (`insert`/`remove` at an index, `truncate`, `extend`, `swap`, slices) | stream buffers copy their unread tail when compacting, `bytes.slice`-style copies everywhere; merge sort builds new Lists | the built-ins, and zero-copy views with 8.6 references |
| **16-bit integers** | `encoding.u16_le` returns a u32 | `u16`/`i16` |
| **String literal escapes** `\r`, `\0`, `\xNN`, `\u{...}` | tests build CRLF input from bytes | the escapes |
| **`panic` with a computed message** (`panic` takes only a `str`) | `assert_eq` prints its diff to stderr, then panics with a fixed text | `panic(String)` |
| **`if`/`match` as a call argument** (E0103) | values are bound to a `let` first | expression-position `if` |
| **Floats** (C9) | no float formatting or parsing in `fmt`/`strings` | f64 |
| **Calling a trait method by its trait** (`time.Clock.sleep(c, d)`) | method syntax only (`c.sleep(d)`), which is ambiguous if a type has an own method of that name | qualified calls |

### Compiler bugs found (seed eiderc)

Reproductions are small enough to inline; none is worked around in std beyond avoiding
the construct. All four are fixed in compiler/ (docs/compiler.md, "C8.16"), so they go
away for std with the next seed; until then std keeps avoiding them (verify.sh builds std
with the seed).

1. **A generic `T` instantiated with `()` inside a match arm produces C that doesn't
   compile** (`'l4' undeclared`):
   ```eider
   type E = { m: String }
   fn plain[T](r: Result[T, E]) -> Result[T, String] {
       match r {
           Ok(v) => Ok(v)
           Err(e) => Err(e.m)
       }
   }
   fn main() uses io {
       let a: Result[(), E] = Ok(())
       print(plain(a).is_ok())
   }
   ```
   So `stream.plain` can't be used on a `Result[(), stream.Error]` yet.
2. **A record name in a generic signature unifies with any type** (the known "a name that
   isn't a type parameter matches any type" quirk, LEARNINGS.md), and the result is C that
   doesn't compile rather than E0401: `plain` above accepts a `Result[i32, String]`.
3. **A trap in an imported module names the entry file**: a program `p.ei` whose `main`
   calls `testing.assert_eq(1, 2)` reports `assert_eq failed (p.ei:65)`, line 65 being
   std/testing.ei's `panic`. (tests/std/testing.ei avoids pinning a trap's location.)
4. **A derived Show of another module's enum prints the mangled name** (`stream__TimedOut`);
   `stream.Kind` has its own Show to print `TimedOut`.

## Why std/stream and not std/io

The compiler imports `std/bytes`, `fs`, `io`, `env` and `proc`, so their text is compiled
into `seed/eiderc.c`: adding even an unused type to std/io makes `selfhost.sh --from-seed`
fail (the seed is stale). Layer branches don't regenerate the seed (the integrator does), so
the stream layer is a new module, and those five modules are unchanged. When the seed is
next regenerated (8.9, "std on the new base"), `stream`'s Reader/Writer and `Error` can move
into std/io and the String-error functions of fs/io can return `stream.Error`.

## Next

- After 8.6 (references): zero-copy reads (`read` into a caller's buffer, views into
  BufReader's buffer), in-place sorting.
- After P0.2 (lightweight tasks): `Fd` waits park the task instead of the thread; the API
  stays.
- P0.6: `stream.Error` implements the error trait, with context chains.
- Seeded SipHash Map (C6), `BTreeMap`, RwLock/Once, logging and config (roadmap layer/std).
