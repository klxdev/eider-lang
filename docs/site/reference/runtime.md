# Runtime behaviour

This page covers what a compiled Eider program does at run time: how it starts and ends,
which exit code it ends with, how runtime errors (traps) are reported, what `print`,
`panic` and `assert` do, and how test blocks run. The runtime is a small C library
(`core/eider_rt.c`) linked into every program; its contract is `core/RUNTIME.md`.

## The entry point

A program's entry module must define `fn main`. It takes no parameters and returns one of:

| Result type | The process exits with |
|---|---|
| `()` (no `->`) | 0 |
| `i32` | the returned value, which must be in 0..255; anything else traps `exit code out of range` |
| `Result[(), E]`, any `E` | 0 for `Ok(())`; 1 for `Err(e)`, after printing `error: <e>` to stderr |

Any other signature is [E0111](errors.md#e0111). Like every function, `main` declares the
[capabilities](capabilities.md) it uses (`fn main() uses io`).

For `Err(e)`, the error is printed when `E` is an integer type, `bool`, `str`, `String` or an
enum without payloads (its variant name); for any other `E` the line is
`error: main returned Err`. Standard output is flushed first, and the `Result` is dropped
before the process exits.

```eider
fn code(n: i32) -> i32 { n * 7 }

fn main() -> i32 uses io {
    print("exiting with 42")
    code(6)
}
```

```output
exiting with 42
```

```eider,trap
fn main() -> i32 {
    let big = 256
    big                        // the OS keeps only the low byte, so this traps
}
```

```eider
fn parse(s: str) -> Result[i32, String] {
    if s == "7" { return Ok(7) }
    let mut m = String.from("not a number: ")
    m.push_str(s)
    Err(m)
}

fn main() -> Result[(), String] uses io {
    print(parse("7")?)
    Ok(())
}
```

```output
7
```

With `parse("x")?` instead, the program prints `error: not a number: x` to stderr and exits
with 1.

A library (`eiderc build --lib`, `--wasm`) has no `main`; see [FFI](ffi.md).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | `main` returned `()` or `Ok(())` |
| 0..255 | the `i32` `main` returned |
| 1 | `main` returned `Err(e)` |
| 101 | a trap (runtime error, `panic`, failed `assert`) |

`eiderc run` exits with the program's code, or 128 + the signal number when the program is
killed by a signal. The driver's own codes: 1 when the program doesn't compile, 2 for a usage
error (unknown command or option, missing file), 3 when the generated C fails to compile
(the C is kept), which is a compiler bug.

## Traps

A trap is the only way a program stops on a runtime error. Eider has no exceptions and no
unwinding: a trap flushes standard output, prints one line to stderr and ends the process
with exit code 101:

```text
eider: runtime error: <message> (<file>:<line>)
```

`<file>` is the source file containing the operation as the compiler was given it for the
entry module; a module of a package is named `<package>/<path in it>` (`std/fs.ei`,
`core/prelude.ei`), and another imported file by its path relative to the entry file's
directory. `<line>` is the line of the operation, or 0 where there is no source line
(allocation failures, thread and channel errors). A trap does not run any drops: values are
not cleaned up and locks held by the trapping thread stay held, which doesn't matter when the
process ends.

If several threads trap at once, exactly one report is printed and the process exits once.

Every trap the language raises:

| Message | Raised by |
|---|---|
| `integer overflow in +`, `-`, `*`, `/`, `%` | checked arithmetic on any integer type, including `+=` etc. (`/` and `%`: `MIN / -1`) |
| `integer overflow in negation` | `-x` of a signed type's minimum |
| `division by zero`, `remainder by zero` | `/` and `%` by zero |
| `integer conversion out of range` | an `as` cast whose value doesn't fit the target type |
| `index out of bounds` | indexing a List, an array, or `byte(i)` on `String`/`str` |
| `shift count out of range` | `<<`, `>>` with a count that is negative or not below the type's width |
| `slice out of bounds` | `slice(a, b)` unless `a <= b <= len` |
| `slice not on a character boundary` | `slice` cutting inside a UTF-8 sequence |
| `push_byte needs an ASCII byte (1 to 127)` | `String.push_byte` |
| `exit code out of range` | `main` returning an `i32` outside 0..255 |
| `out of memory` (line 0) | a failed allocation, or a size computation that overflows |
| `send on a closed channel` (line 0) | `Chan.send` after `close` |
| `cannot create a thread` (line 0) | `spawn` when the OS refuses |
| `cannot lock a mutex` (line 0) | a `Mutex.update` closure using the same Mutex |
| `cannot join a thread` (line 0) | the last handle of a Task dropped on that task's own thread |
| `stack overflow` (line 0) | unbounded recursion, on any thread (`main`'s too) |
| `Ref read while it is being updated`, `Ref updated while it is being read`, `Ref updated while it is already being updated` | overlapping access to one `Ref` ([memory model](memory.md#access-conflicts)) |
| `a Ref can't be sent to another thread` (line 0) | a closure capturing a Ref, stored first and then spawned or sent |
| `called `unwrap` on a None value`, `called `unwrap` on an Err value` | `Option.unwrap`, `Result.unwrap` (from `core/prelude.ei`) |
| the given text | `panic(msg)`; `assert cond, "msg"` |
| `assertion failed` | `assert cond` without a message |

Failures the runtime reports but no correct program should reach: `cannot create a mutex`,
`cannot unlock a mutex`, `cannot create a channel`.

An operation whose operands are all constants is evaluated by the compiler, so a trap it
would raise is a compile error instead ([E0501](errors.md#e0501), E0502, E0505, E0506). The
traps above are for values known only at run time; a variable is never folded, even when it
was bound to a literal.

```eider,compile_fail=E0501
fn main() {
    let b: u8 = 200 * 2        // 400 doesn't fit in u8
}
```

```eider,trap
fn main() uses io {
    let x: u8 = 255
    print("before")            // printed: stdout is flushed before the report
    print(x + 1)
}
```

```eider,trap
fn main() uses io {
    let xs = [1, 2, 3]
    let i: usize = 3
    print(xs[i])
}
```

```eider,trap
fn main() {
    let n: i64 = 300
    let b = n as u8
}
```

### Stack overflow

Every thread of a program runs on an 8 MiB stack with a guard region, `main` included (it
runs on a runtime thread of its own, not on the process's initial stack); overflowing it is
reported as the trap `stack overflow` (exit 101), after what `print` buffered is written.

## `panic` and `assert`

`panic(msg)` traps with the message `msg` (a `str`). It never returns, so it can stand where
any type is expected, for example as a `match` arm.

`assert cond` and `assert cond, "message"` are statements: when `cond` is `false` they trap
with the message, or `assertion failed` without one. They are checked in every build.

```eider,trap
fn check(n: u8) uses io {
    assert n < 3, "n is too big"
    print(n)
}

fn main() uses io {
    for i in 0..10 {
        check(i as u8)
    }
}
```

```eider
fn sign(n: i32) -> str {
    match n > 0 {
        true => "positive"
        false => if n == 0 { "zero" } else { panic("negative") }
    }
}

fn main() uses io {
    print(sign(5))
    print(sign(0))
}
```

```output
positive
zero
```

## `print`

`print(x)` writes the text of one value followed by a newline to standard output. It needs
the `io` capability ([E0201](errors.md#e0201)) and takes exactly one argument (E0405) of any
type with `Show` ([traits](traits.md)): integers, `bool`, `str` and `String` print as they
are; other values print in their derived or own `Show` form, with text inside them quoted.
Function values, `Ref`s and thread handles have no text (E0401).

```eider
type P = { x: i32, name: String }
type Shape = | Dot | Circle(i32)

fn main() uses io {
    print(-5)
    print(true)
    print("raw text")
    print(P(1, String.from("n")))
    print(Circle(2))
    print(Dot)
    print([1, 2])
    print((1, "a"))
    print(Some(3))
}
```

```output
-5
true
raw text
P { x: 1, name: "n" }
Circle(2)
Dot
[1, 2]
(1, "a")
Some(3)
```

Standard output is buffered. It is flushed when the program ends, before a trap's report,
and before anything that writes to a file descriptor directly (the `std/io` streams, a
child process).

## Test blocks

`test "name" { ... }` items are compiled only by `eiderc test`; `eiderc run` and
`eiderc build` ignore them (see [items](items.md)). A test block is checked with every
capability. `eiderc test <file>` builds the program in test mode (no `main` is required) and
runs each test block in program order, printing for each:

```text
test <name> ... ok
```

or, when the test traps (a failed `assert`, a `panic`, any runtime error):

```text
test <name> ... FAILED
    <message> (<file>:<line>)
```

Anything the test prints appears between `...` and the verdict. A trap ends only the test it
happens in; the next test runs. After the last test it prints a blank line and
`<n> tests, <k> failed`, and exits with 1 when any test failed, else 0.

```eider
fn step(n: u32) -> u32 { n + 1 }

test "steps" {
    assert step(1) == 2
    assert step(2) == 3, "second step"
}

fn main() uses io {
    print(step(0))             // `eiderc run` runs only main
}
```

```output
1
```

Under `eiderc test`, this program prints:

```text
test steps ... ok

1 tests, 0 failed
```

Because a trap doesn't unwind, a failed test's values are never dropped and a lock it held
stays held, so a later test using the same `Mutex` deadlocks. A trap on a thread spawned by
a test ends the whole test binary with 101.

## Leak checking

Built with `EIDER_CFLAGS=-DEI_RT_COUNT_ALLOCS`, a program counts its live allocations and,
when it ends normally, prints `eider: outstanding allocations: <n>` to stderr. The
compiler's tests use it to check that every value is dropped on every path.
