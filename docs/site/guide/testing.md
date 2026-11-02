# Testing

Tests in Eider are ordinary code next to the code they test. This page covers `test`
blocks, std/testing's assertions and test doubles, test programs with recorded output, and
compile-fail tests, which check that code is *rejected* with the right error.

## `test` blocks

A `test "name" { ... }` block can sit anywhere among a file's items. `scripts/ei run`
ignores them; `scripts/ei test file.ei` compiles the file with a test driver and runs each
block in order:

```eider
type Stack = { items: List[i32] }

fn push(inout s: Stack, x: i32) { s.items.push(x) }

fn pop(inout s: Stack) -> Option[i32] { s.items.pop() }

fn main() uses io {
    let mut s = Stack(List.new())
    push(inout s, 1)
    push(inout s, 2)
    print(pop(inout s))
}

test "pop returns the last value pushed" {
    let mut s = Stack(List.new())
    push(inout s, 1)
    push(inout s, 2)
    assert pop(inout s) == Some(2)
    assert pop(inout s) == Some(1)
}

test "pop on an empty stack is None" {
    let mut s = Stack(List.new())
    assert pop(inout s).is_none(), "an empty stack has nothing to pop"
}
```

```output
Some(2)
```

```text
$ scripts/ei test stack.ei
test pop returns the last value pushed ... ok
test pop on an empty stack is None ... ok

2 tests, 0 failed
```

- `assert cond` and `assert cond, "message"` fail the test with the message (or
  `assertion failed`) and the file and line.
- Any trap fails the test too (an overflow, an index out of bounds, `unwrap` on `None`,
  `panic`), and the other tests still run.
- A test stops at its first failure. `scripts/ei test` exits 1 when any test failed.
- Test blocks have every capability, so they can print, read files or start threads
  without declaring it.
- A file with only tests, or a library module with no `main` at all, can be run:
  `scripts/ei test stack.ei` (and `check stack.ei` type-checks it). Only `build` and `run`
  need a `main`.
- `scripts/ei test` with no file, in a package directory (one with an `eider.toml`), runs the
  `test` blocks of every module and of `tests/*.ei` (not `target/`, `deps/`, `examples/`,
  `bench/`, `scripts/`, `docs/`, hidden directories or nested packages) and ends with one
  summary: `2 files, 3 tests, 0 failed`. A module's tests run once for each file that
  imports it, and each run counts.

## Assertions with a diff: `std/testing`

`testing.assert_eq(got, want)` compares two values (any type with `Eq` and `Show`) and,
when they differ, prints both and where their text first differs before failing:

```eider
import std.testing

fn slugify(title: String) -> String {
    let mut out = String.from("")
    for c in title.bytes() {
        if c >= 65 && c <= 90 {
            out.push_byte(c + 32)
        } else if c == 32 {
            out.push_byte(45)
        } else {
            out.push_byte(c)
        }
    }
    out
}

fn main() uses io {
    print(slugify(String.from("Hello World")))
}

test "slugify" {
    testing.assert_eq(slugify(String.from("Hello World")), String.from("hello-world"))
    testing.assert_eq(slugify(String.from("A B C")), String.from("a-b-c"))
}
```

```output
hello-world
```

If `slugify` forgot the hyphen, the test would report:

```text
test slugify ... assertion failed: values differ
   got: hello world
  want: hello-world
  (first difference at byte 5)
FAILED
    assert_eq failed (std/testing.ei:65)
```

The location is the line in std/testing that stops the test, not your call (there is no
caller location yet); the test's name and the two values tell you which check failed.
For text with several lines it adds a line diff (`- got`, `+ want`). `assert_ne(got, avoid)`
and `assert_ok(result)` (the value of an `Ok`, or a failure that prints the `Err`) work the
same way.

## Test programs with recorded output

For larger behaviour, a test is a program whose output is compared with a recorded file.
That is how std, the packages and the examples in this repository are tested
(`tests/std/run.sh`, `tests/packages.sh`): `tests/<name>_test.ei` next to
`tests/<name>_test.out`. `testing.suite(name)` collects many checks, reports every
failure (not just the first) on stderr, and gives `main` its exit code:

```eider
import std.testing

fn main() -> i32 uses io {
    let mut t = testing.suite("arithmetic")
    t.eq("addition", 2 + 2, 4)
    t.eq("division rounds toward zero", -7 / 2, -3)
    t.check("remainder sign follows the dividend", -7 % 2 == -1)
    print("checked")
    t.done()
}
```

```output
checked
```

`t.done()` prints `arithmetic: 3 checks, 0 failed` to stderr and returns 0, or 1 when a
check failed. stdout keeps only what the program itself prints, so it can be compared with
a recorded `.out` file.

## Test doubles

Code that talks to the outside world through a trait can be tested without it. std's I/O
goes through the `std/stream` traits `Reader` and `Writer`, and time through the
`time.Clock` trait, and std/testing has deterministic implementations of each:

| Double | Stands in for | What it does |
|---|---|---|
| `testing.fake_clock(mono_ns, wall_ns)` | `time.Clock` | time moves only when the test calls `advance(d)`, or the code under test sleeps on it |
| `testing.script(steps, chunk)`, `testing.chunks(data, n)` | a `Reader` | plays back `Data(bytes)` in reads of at most `chunk` bytes, `Pause` (a deadline read times out), `Fail(kind)`, `End` |
| `testing.sink(n)`, `testing.failing_sink(n, at, kind)` | a `Writer` | takes at most `n` bytes per write, can fail after `at` bytes, counts flushes |
| `testing.pipe()` | both ends of a pipe | in memory; an empty pipe never waits |

A rate limiter that takes its clock as a type parameter, tested on a fake clock:

```eider
import std.time
import std.testing

type Limiter[C] = { clock: C, every_ns: i64, last_ns: i64 }

fn limiter[C: time.Clock](clock: C, every: time.Duration) -> Limiter[C] {
    Limiter(clock, every.as_ns(), -every.as_ns())
}

fn allow[C: time.Clock](inout l: Limiter[C]) -> bool uses clock {
    let now = l.clock.mono_ns()
    if now - l.last_ns < l.every_ns { return false }
    l.last_ns = now
    true
}

fn main() uses io, clock {
    let clock = testing.fake_clock(0, 0)
    let mut l = limiter(clock, time.millis(100))
    print(allow(inout l))
    print(allow(inout l))
    clock.advance(time.millis(99))
    print(allow(inout l))
    clock.advance(time.millis(1))
    print(allow(inout l))
}
```

```output
true
false
false
true
```

Copies of a FakeClock share their time, so the test keeps one copy to advance while the
limiter holds another. In production the same code takes `time.system()`.

A writer that accepts two bytes per call checks that the code under test copes with short
writes:

```eider
import std.stream
import std.testing

fn main() uses io {
    let mut w = testing.sink(2)
    match stream.write_str(inout w, "hello, world") {
        Ok(()) => print(w.text())
        Err(e) => print(e)
    }
}
```

```output
hello, world
```

`tests/std/testing.ei` in the repository tests a small line-protocol service this way:
timeouts in the middle of a line, short reads and writes, and a reset connection.

## Compile-fail tests

Some of the most important properties of a program are things that must *not* compile: a
capability that must be declared, a reference that must not outlive a write. The compiler
runs suites of such files:

```text
checks/
  fail/
    push_while_borrowed.ei
    save_needs_fs.ei
  pass/
    copy_first.ei
```

Each file in `fail/` starts with the error it must produce, as `// expect: CODE LINE:COL`
(the header is line 1 of the file):

```text
// expect: E0308 6:11
fn main() uses io {
    let mut names: List[String] = List.new()
    names.push(String.from("ada"))
    let first = names[0]
    names.push(String.from("grace"))
    print(first)
}
```

Every file in `pass/` must compile. Run the suite with `scripts/ei test --compile-fail
checks`:

```text
compile-fail tests (checks/fail)
  ok   push_while_borrowed.ei       E0308 at 6:11 (fix compiles)
  ok   save_needs_fs.ei             E0201 at 7:11 (fix compiles)

compile-pass tests (checks/pass)
  ok   copy_first.ei

3 passed, 0 failed; error-code coverage 2/54
codes without a compile-fail test: E0001 E0002 ...
```

When the diagnostic carries a fix, the runner applies it and checks that the fixed file
compiles, or fails with a different error: a fix must never lead back to the same error.
A file containing `// mode: test` is checked as a test build (no `main` needed), and
`// mode: wasm` as a WebAssembly module. The last lines count how many of the language's
error codes the suite covers; the repository's own suite, `tests/checks`, covers every
one.

In these docs, a code block marked `eider,compile_fail=E0308` is the same kind of test.

## Running everything

- `scripts/ei test file.ei`: one file's test blocks.
- `scripts/ei test --compile-fail dir`: a compile-fail suite.
- `sh tests/run.sh`, `sh tests/std/run.sh`, `sh tests/packages.sh`: the repository's run
  tests, std and packages, each comparing output with recorded files.
- `sh scripts/verify.sh`: everything, under gcc, clang, ASan+UBSan and TSan.

Programs built for the sanitizers use `EIDER_CFLAGS`, for example
`EIDER_CACHE=off EIDER_CFLAGS="-fsanitize=thread -g" scripts/ei build prog.ei`.
Test filters, benchmarks and fuzz targets in `eiderc test` are planned.
