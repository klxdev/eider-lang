# Errors

Eider has no exceptions and no null. A function that can fail says so in its type, by
returning a `Result`, and the caller decides what to do: handle the error, pass it on with
`?`, or add context. This page goes from the basics to error chains with std/error.

## `Result` and `Option`

Both are ordinary enums in the prelude:

```text
type Option[T] = | Some(value: T) | None
type Result[T, E] = | Ok(value: T) | Err(error: E)
```

`match` must handle every case, so an error can't be ignored by accident:

```eider
fn divide(a: i64, b: i64) -> Result[i64, String] {
    if b == 0 { return Err(String.from("division by zero")) }
    Ok(a / b)
}

fn main() uses io {
    match divide(10, 2) {
        Ok(q) => print(q)
        Err(e) => print(e)
    }
    match divide(1, 0) {
        Ok(q) => print(q)
        Err(e) => print(e)
    }
    print(divide(9, 3).unwrap_or(-1))
    print(divide(9, 0).is_err())
}
```

```output
5
division by zero
3
true
```

The helpers, all defined in Eider in `core/prelude.ei`:

| On `Option[T]` | On `Result[T, E]` | Does |
|---|---|---|
| `is_some`, `is_none` | `is_ok`, `is_err` | test the case |
| `unwrap_or(v)` | `unwrap_or(v)` | the value, or `v` |
| `unwrap()` | `unwrap()` | the value, or a trap (exit 101) |
| `map(f)` | `map(f)`, `map_err(f)` | transform the value (or the error) |
| `and_then(f)` | `and_then(f)` | chain a step that can itself fail |
| `ok_or(e)` | `ok()` | convert between the two |

Use `unwrap` only where failure is a bug: it stops the program.

## `?`: pass the error on

`x?` on a `Result` gives the `Ok` value, or returns the `Err` from the enclosing function.
On an `Option` it returns `None`. The function's return type must be a `Result` (or an
`Option`) for that:

```eider
fn parse_digit(c: u8) -> Result[u64, String] {
    if c < 48 || c > 57 { return Err(String.from("expected a digit")) }
    Ok((c - 48) as u64)
}

fn parse(s: String) -> Result[u64, String] {
    if s.len() == 0 { return Err(String.from("empty")) }
    let mut n: u64 = 0
    for c in s.bytes() {
        n = n * 10 + parse_digit(c)?
    }
    Ok(n)
}

fn sum(a: String, b: String) -> Result[u64, String] {
    Ok(parse(a)? + parse(b)?)
}

fn main() uses io {
    print(sum(String.from("40"), String.from("2")))
    print(sum(String.from("40"), String.from("x")))
    print(sum(String.from(""), String.from("2")))
}
```

```output
Ok(42)
Err("expected a digit")
Err("empty")
```

Every value owned by the function is dropped on the early return, as on any other exit.

## Undo on failure: `errdefer`

`errdefer s` runs `s` only when the function fails: it returns through `?`, or returns an
`Err` (or `None`). Put it right after a step that needs undoing, and every later failure
undoes it; `defer` runs on every exit. See
[Statements](../reference/statements.md#defer-and-errdefer).

```eider
fn reserve(stock: i32, n: i32) -> Result[i32, str] {
    if n > stock { return Err("not enough stock") }
    Ok(stock - n)
}

fn order(stock: i32, a: i32, b: i32) -> Result[i32, str] uses io {
    let left = reserve(stock, a)?
    errdefer print(f"released {a}")
    let rest = reserve(left, b)?
    Ok(rest)
}

fn main() uses io {
    print(order(10, 3, 4))
    print(order(10, 3, 9))
}
```

```output
Ok(3)
released 3
Err("not enough stock")
```

## Error types of your own

A String says what went wrong; an enum also lets the caller act on it. Give each failure
its own variant, with the data the caller needs:

```eider
type ConfigError =
    | Missing(key: String)
    | OutOfRange(key: String, value: i64)

fn port(value: Option[i64]) -> Result[i64, ConfigError] {
    let v = match value {
        Some(v) => v
        None => return Err(Missing(String.from("port")))
    }
    if v < 1 || v > 65535 { return Err(OutOfRange(String.from("port"), v)) }
    Ok(v)
}

fn main() uses io {
    print(port(Some(8080)))
    print(port(None))
    match port(Some(70000)) {
        Ok(p) => print(p)
        Err(Missing(k)) => print(k)
        Err(OutOfRange(k, v)) => print(v)
    }
}
```

```output
Ok(8080)
Err(Missing("port"))
70000
```

Error values print themselves (derived `Show`), so `print(e)` is useful while you develop.

## Converting errors: `From`

When a function calls code with different error types, `?` can convert them. Implement
`From[Source]` for your error type, and `?` on a `Result[_, Source]` returns
`Err(YourError.from(e))`:

```eider
type ParseError = { at: usize }
type IoError = { path: String }

type AppError =
    | Parse(at: usize)
    | Io(path: String)

impl From[ParseError] for AppError {
    fn from(value: ParseError) -> AppError { Parse(value.at) }
}

impl From[IoError] for AppError {
    fn from(value: IoError) -> AppError { Io(value.path) }
}

fn read(path: str) -> Result[String, IoError] {
    if path == "missing.txt" { return Err(IoError(String.from(path))) }
    Ok(String.from("12a"))
}

fn check(text: String) -> Result[i32, ParseError] {
    for i in 0..text.len() {
        let c = text.byte(i)
        if c < 48 || c > 57 { return Err(ParseError(i)) }
    }
    Ok(text.len() as i32)
}

fn load(path: str) -> Result[i32, AppError] {
    let text = read(path)?          // IoError -> AppError
    let n = check(text)?            // ParseError -> AppError
    Ok(n)
}

fn main() uses io {
    print(load("missing.txt"))
    print(load("config.txt"))
}
```

```output
Err(Io("missing.txt"))
Err(Parse(2))
```

The rules:

- Only the package that defines the target type may implement `From` for it (the orphan
  rule, E0604), so a conversion can't appear or change depending on what you import.
- `from` takes exactly one parameter and declares no capabilities (E0602): it runs wherever
  a `?` is written.
- One impl per source type. You can call a conversion directly, `AppError.from(e)`.
- Without a matching impl, `?` is E0401 "`?` can't convert the error type A into B", with
  a help that suggests the impl.

There is no `Into` and no blanket conversion.

## Error chains with std/error

Real failures happen in layers: a config couldn't be loaded *because* a file couldn't be
read *because* it doesn't exist. `std/error` represents that as a chain of messages:

- the trait `error.Error` (`fn message(self) -> String`, `fn source(self) ->
  Option[error.Failure]`): what an error type implements to be reported and wrapped;
- `error.Failure`: an error as a chain of messages, outermost first, printed as
  `outer: inner: root`. `Failure.new("...")`, `f.wrap(msg)`, `f.chain()`, `f.root()`;
- `.context("...")` on a `Result[T, E]` with `E: error.Error`, or on an `Option`, gives a
  `Result[T, error.Failure]` with the message around the error;
  `.with_context(|| ...)` builds the message only when there is an error;
- every `error.Error` converts into a `Failure` through `From`, so in a function that
  returns `Result[T, error.Failure]`, `?` works on all of them.

```eider
import std.error

type ParseError = { line: u32, what: String }

impl error.Error for ParseError {
    fn message(self) -> String {
        let mut m = String.from("line ")
        m.append(String.from_int(self.line as i64))
        m.push_str(": ")
        m.append(self.what.copy())
        m
    }
    fn source(self) -> Option[error.Failure] { None }
}

fn parse_port(text: String) -> Result[i64, ParseError] {
    if text.len() == 0 { return Err(ParseError(1, String.from("expected a number"))) }
    Ok(8080)
}

fn settings(text: String) -> Result[i64, error.Failure] {
    let port = parse_port(text).context("parsing the config")?
    Ok(port)
}

fn start(text: String) -> Result[i64, error.Failure] {
    let port = settings(text).context("starting the server")?
    let name: Option[String] = None
    let n = name.context("no server name")?
    Ok(port)
}

fn main() uses io {
    match start(String.from("")) {
        Ok(p) => print(p)
        Err(f) => {
            print(f)
            print(f.chain().len())
            print(f.root())
        }
    }
    print(start(String.from("port = 8080")).is_err())
}
```

```output
starting the server: parsing the config: line 1: expected a number
3
line 1: expected a number
true
```

Every error the standard library returns is an `error.Error`, so `.context` and `?` work
on them as they are: the `String` errors of `std/fs`, `std/io` and `std/proc` (std/error
implements `error.Error` for `String`: the message is the text, with no source), and the
typed `stream.Error`, `strings.ParseError` and `encoding.DecodeError`:

```eider
import std.error
import std.fs
import std.strings

fn load(path: str) -> Result[List[u8], error.Failure] uses fs {
    let text = fs.read(String.from(path).bytes()).context("reading the config")?
    Ok(text)
}

fn port(text: str) -> Result[i64, error.Failure] {
    let n = strings.parse_i64(text)?            // a ParseError, through From
    Ok(n)
}

fn main() uses io, fs {
    match load("/nonexistent/app.toml") {
        Ok(_) => print("loaded")
        Err(f) => print(f)
    }
    match port("80x") {
        Ok(n) => print(n)
        Err(f) => print(f)
    }
}
```

```output
reading the config: cannot read /nonexistent/app.toml: No such file or directory
invalid digit at byte 2
```

A Failure keeps messages only. To act on what kind of I/O error it was, use `std/stream`'s
typed errors (`e.kind == stream.TimedOut`) before wrapping them.

An application error can take a `Failure` too (`impl From[error.Failure] for AppError`), so
`?` keeps working across layers.

## Errors from `main`

`main` may return `Result[(), E]`. `Ok(())` exits 0. An `Err(e)` prints `error: <e>` to
stderr and exits 1, when `E` is an integer, `bool`, `str`, `String` or an enum without
payloads; for other error types it prints `error: main returned Err`.

```eider
fn main() -> Result[(), String] uses io {
    print("working")
    Ok(())
}
```

```output
working
```

`main` may also return an `i32`, the exit code (0 to 255; anything else traps).

## Traps are not errors

Some failures are bugs, not conditions to handle: an index out of bounds, an integer
overflow, `unwrap` on `None`, a failed `assert`, `panic("...")`. These stop the program
with a message naming the file and line, and exit code 101:

```eider,trap
fn main() uses io {
    let xs = [1, 2, 3]
    let i: usize = 3
    print(xs[i])
}
```

`eider: runtime error: index out of bounds (main.ei:4)`. A trap can't be caught. In a
service that means one bad request could stop the process, so validate input before
arithmetic or indexing (eider-rpc's examples/kvstore checks for overflow before adding);
containing traps is planned.
