# A tour of Eider

This tour shows the whole language through small programs. Every program on this page is
complete: paste it into a file and run it with `scripts/ei run file.ei`. The output under
each one is what it prints. The language reference has the precise rules.

## Values and types

```eider
fn main() uses io {
    let answer = 42                 // i32 by default
    let big: u64 = 10_000_000_000
    let ratio = 7 / 2               // integer division
    let ok = answer > 40 && ratio == 3
    let name = "Eider"              // str: a string literal
    let mut greeting = String.from("Hello, ")
    greeting.push_str(name)
    print(greeting)
    print(big / 1_000)
    print(ok)
    print(255 as u8)
    print(-7 % 3)
}
```

```output
Hello, Eider
10000000
true
255
-1
```

- Integers: `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64` and `usize` (sizes and indices). There are
  no implicit conversions: `as` converts, and a conversion whose value doesn't fit traps
  (`integer conversion out of range`).
- `bool`, `str` (string literals), `String` (owned UTF-8 text), `()` (the unit value).
- Floats: `f32` and `f64`, IEEE 754 (`1.5`, `1e-3`, `2.5f32`). They never trap, they mix with
  nothing without `as` (`n as f64`), and `NaN != NaN`; see below and [Numbers](numbers.md).
- `let` bindings can't be changed; `let mut` ones can. Newlines end statements.
- Bitwise operators `& | ^ ~ << >>` work on integers; mixing them with comparisons or
  arithmetic needs parentheses (`(a & b) == c`), and the compiler offers them.
- `const LIMIT: usize = 64` declares a constant; `const X: u64 = comptime f(10)` runs
  `f` at compile time (integer and `bool` constants).

```eider
fn main() uses io {
    let radius = 2.5
    let area = 3.14159 * radius * radius
    print(area)
    print("{area:.1}")
    let n = 7
    print((n as f64) / 2.0)
    print(0.1 + 0.2)
    print(10.9 as i32)
}
```

```output
19.6349375
19.6
3.5
0.30000000000000004
10
```

A float prints as the shortest text that reads back as the same value; `as` to an integer
truncates and traps on a NaN or a value that doesn't fit.

A string literal interpolates: `{expr}` inserts a value's text, and a spec after `:` pads
or formats it (`{n:>6}`, `{n:#x}`; `{{` is a brace; [Lexical
structure](../reference/lexical.md#interpolation)).
`r"..."` is a raw string and `"""` starts a multi-line one:

```eider
fn main() uses io {
    let name = "Eider"
    let n = 42
    print("{name} has {n} ({n:#x}) users, [{name:^9}]")
    let banner = """
        Hello,
          world
        """
    print(banner)
    print(r"no \escapes here")
}
```

```output
Eider has 42 (0x2a) users, [  Eider  ]
Hello,
  world
no \escapes here
```

Arithmetic is checked. Overflow stops the program with exit code 101, in every build. When
wrapping is what you want, say so with `+%`, `-%` or `*%`:

```eider,trap
fn main() uses io {
    let x: u8 = 250
    print(x +% 10)
    let y = x + 10
    print(y)
}
```

```output
4
```

The program prints `4` and then stops at `x + 10` with
`eider: runtime error: integer overflow in + (main.ei:4)` on stderr.

## Functions

```eider
fn add(a: i64, b: i64) -> i64 {
    a + b                           // the last expression is the result
}

fn sign(n: i64) -> str {
    if n < 0 { return "negative" }
    if n == 0 { "zero" } else { "positive" }
}

fn bump(inout counter: i32) {     // `inout`: the caller's variable, changed in place
    counter += 1
}

fn main() uses io {
    print(add(40, 2))
    print(sign(-5))
    let mut n = 0
    bump(inout n)
    bump(inout n)
    print(n)
}
```

```output
42
negative
2
```

Parameters are read-only. A function changes its caller's data only through an `inout`
parameter, and the call site says `inout` too, so every change is visible where it
happens.

## Records, enums and match

```eider
type Point = { x: i32, y: i32 }

type Shape =
    | Circle(center: Point, r: i32)
    | Rect(min: Point, max: Point)
    | Empty

fn area(s: Shape) -> i32 {
    match s {
        Circle(_, r) => 3 * r * r
        Rect(a, b) => (b.x - a.x) * (b.y - a.y)
        Empty => 0
    }
}

fn main() uses io {
    let origin = Point(0, 0)
    let shapes = [Circle(origin, 2), Rect(origin, Point(3, 4)), Empty]
    for s in shapes {
        print(area(s))
    }
    let mut p = Point(1, 2)
    p.x = 10
    print(p)
    print(shapes[1])
}
```

```output
12
12
0
Point { x: 10, y: 2 }
Rect(Point { x: 0, y: 0 }, Point { x: 3, y: 4 })
```

Records are built positionally (`Point(1, 2)`); fields are read and written with `.`. An
enum's variants start with `|` and may carry fields. `match` must cover every case: leave
one out and the compiler names it. Patterns nest, bind names, and match literals, tuples
and `_`:

```eider
fn describe(p: (i32, bool)) -> str {
    match p {
        (0, _) => "zero"
        (n, true) => if n > 0 { "positive, flagged" } else { "negative, flagged" }
        (_, false) => "unflagged"
    }
}

fn main() uses io {
    print(describe((0, true)))
    print(describe((5, true)))
    print(describe((5, false)))
}
```

```output
zero
positive, flagged
unflagged
```

## Option, Result and `?`

There is no null and there are no exceptions. A value that may be missing is an
`Option[T]` (`Some(v)` or `None`); an operation that may fail returns a `Result[T, E]`
(`Ok(v)` or `Err(e)`). `?` returns early with the `None` or the `Err`:

```eider
fn parse_digit(c: u8) -> Result[i32, String] {
    if c < 48 || c > 57 {
        let mut msg = String.from("not a digit: ")
        msg.push_byte(c)
        return Err(msg)
    }
    Ok((c - 48) as i32)
}

fn parse_number(s: String) -> Result[i32, String] {
    let mut n = 0
    for c in s.bytes() {
        n = n * 10 + parse_digit(c)?
    }
    Ok(n)
}

fn first_even(xs: List[i32]) -> Option[i32] {
    for x in xs {
        if x % 2 == 0 { return Some(x) }
    }
    None
}

fn main() uses io {
    print(parse_number(String.from("2026")))
    print(parse_number(String.from("20x6")))
    let mut xs: List[i32] = List.new()
    xs.push(3)
    xs.push(8)
    match first_even(xs) {
        Some(x) => print(x)
        None => print("no even number")
    }
    if let Some(x) = first_even(List.new()) { print(x) } else { print("empty") }
    print(first_even(xs).unwrap_or(0))
}
```

```output
Ok(2026)
Err("not a digit: x")
8
empty
8
```

`Option` and `Result` have the usual helpers (`is_some`, `unwrap_or`, `map`, `and_then`,
`ok_or`, `map_err`, ...). `unwrap` traps on `None` or `Err`. [Errors](errors.md) shows how
`?` converts error types with `From` and how std/error adds context.

`defer` runs a statement when its block is left, however it is left; `errdefer` only when
the function fails (through `?`, or by returning `Err` or `None`):

```eider
fn load(ok: bool) -> Result[i32, str] uses io {
    print("open")
    defer print("close")
    errdefer print("roll back")
    if !ok { return Err("bad input") }
    Ok(1)
}

fn main() uses io {
    print(load(true))
    print(load(false))
}
```

```output
open
close
Ok(1)
open
roll back
close
Err("bad input")
```

## Collections and loops

```eider
fn main() uses io {
    let mut xs: List[i32] = List.new()
    for i in 1..6 { xs.push(i * i) }
    print(xs)
    print(xs.len())
    print(xs[2])

    let mut ages: Map[String, i32] = Map.new()
    ages.insert(String.from("ada"), 36)
    ages.insert(String.from("linus"), 21)
    print(ages.get(String.from("ada")))
    print(ages.contains(String.from("grace")))

    let mut total = 0
    for (name, age) in ages {
        total += age
    }
    print(total)

    let mut stack = [10, 20, 30]
    let mut i: usize = 0
    while i < 3 {
        stack[i] += 1
        i += 1
    }
    print(stack)
}
```

```output
[1, 4, 9, 16, 25]
5
9
Some(36)
false
57
[11, 21, 31]
```

- `List[T]` grows (`push`, `pop`, `clear`, `contains`, indexing); `[a, b, c]` is a
  fixed-size array (`[i32; 3]`); `Map[K, V]` maps any key type with `Hash` and `Eq`
  (`insert`, `get` returning an `Option`, `remove`, `contains`, `keys`, `values`).
- `for x in xs` walks a List, an array, a range `a..b` (`b` excluded) or a Map's
  `(key, value)` pairs (a Map's order is the same on every run, but neither sorted nor
  insertion order). `while`, `while let`, `break` and `continue` work as usual; labeled
  loops (`outer: for ...`, `break outer`) are in the compiler sources and arrive with the
  next seed.
- Indexing out of bounds traps. Collections are values: assigning or passing one never
  shares mutable state, and the copies are cheap (copy-on-write).

## Generics and traits

```eider
type Pair[A, B] = { first: A, second: B }

trait Describe {
    fn describe(self) -> String
}

type Dog = { name: String }
type Robot = { serial: u32 }

impl Describe for Dog {
    fn describe(self) -> String {
        let mut s = String.from("dog ")
        s.append(self.name)
        s
    }
}

impl Describe for Robot {
    fn describe(self) -> String {
        let mut s = String.from("robot #")
        s.append(String.from_int(self.serial as i64))
        s
    }
}

fn introduce[T: Describe](x: T) uses io {
    print(x.describe())
}

fn swap[A, B](p: Pair[A, B]) -> Pair[B, A] {
    Pair(p.second, p.first)
}

fn largest[T: Ord + Copy](xs: List[T]) -> Option[T] {
    if xs.len() == 0 { return None }
    let mut best = xs[0].copy()
    for x in xs {
        if x > best { best = x }
    }
    Some(best)
}

fn main() uses io {
    introduce(Dog(String.from("Rex")))
    introduce(Robot(7))
    print(swap(Pair(1, "one")))
    let mut words: List[String] = List.new()
    words.push(String.from("pear"))
    words.push(String.from("apple"))
    words.push(String.from("zucchini"))
    print(largest(words))
}
```

```output
dog Rex
robot #7
Pair { first: "one", second: 1 }
Some("zucchini")
```

Generic functions and types are compiled once per type they are used with
(monomorphized), and trait calls are static: no boxes, no virtual calls. A bound such as
`T: Ord` says what a generic body may do with a `T`; leave it out and the compiler offers
to add it (E0605). Dynamic dispatch (`dyn Trait`) is planned.

### Operation traits

Everything the language does with a value is a trait in the prelude: `Copy` (`.copy()`),
`Eq` (`==`), `Ord` (`<`, `compare`), `Hash` (Map keys), `Show` (`print`, `to_string`),
`Iter` (`for`) and `Drop` (cleanup); `Default` (`T.default()`) follows with the next seed
regeneration. Records, enums, tuples, Lists and Maps get
them automatically when all their parts have them. A type's own package can implement one
instead:

```eider
type Celsius = { deg: i32 }

impl Show for Celsius {
    fn show(self, inout out: String) {
        out.append(String.from_int(self.deg as i64))
        out.push_str(" C")
    }
}

type Countdown = { n: i32 }

impl Iter for Countdown {
    fn next(inout self) -> Option[i32] {
        if self.n == 0 { return None }
        self.n -= 1
        Some(self.n + 1)
    }
}

fn main() uses io {
    let t = Celsius(21)
    print(t)
    print(t == Celsius(21))
    let mut readings: List[Celsius] = List.new()
    readings.push(t)
    print(readings)
    for i in Countdown(3) { print(i) }
}
```

```output
21 C
true
[21 C]
3
2
1
```

There is no operator overloading: `+` and friends are for numbers.

When two traits (or a trait and the type) define a method of one name, `value.name()` picks
the type's own, and a tie is an error (E0119). Name the trait to call one of them:

```eider
trait Pilot { fn fly(self) -> str }
trait Wizard { fn fly(self) -> str }

type Human = { name: str }

impl Pilot for Human {
    fn fly(self) -> str { "this is your captain" }
}
impl Wizard for Human {
    fn fly(self) -> str { "up!" }
}
impl Human {
    fn fly(self) -> str { "*waves arms*" }
}

fn main() uses io {
    let h = Human("Ada")
    print(h.fly())
    print(Pilot.fly(h))
    print(Wizard.fly(h))
}
```

```output
*waves arms*
this is your captain
up!
```

A trait can also declare a type that each impl chooses, an associated type: `type Item` in
the trait, `type Item = i32` in the impl, `Self.Item` in the signatures and `C.Item` for a type
parameter `C` with the bound.

```eider
trait Container {
    type Item
    fn get(self, i: usize) -> Self.Item
    fn size(self) -> usize
}

type Bag = { xs: List[i32] }

impl Container for Bag {
    type Item = i32
    fn get(self, i: usize) -> i32 { self.xs[i] }
    fn size(self) -> usize { self.xs.len() }
}

fn last[C: Container](c: C) -> C.Item { c.get(c.size() - 1) }

fn main() uses io {
    let mut xs: List[i32] = List.new()
    xs.push(3)
    xs.push(4)
    print(last(Bag(xs)))
}
```

```output
4
```

A generic function is instantiated once per type. When the type is only known while the
program runs, a list of shapes with circles and rectangles in it, a router's handlers, use
`dyn Trait`: a value of any type that implements the trait, called through a table of its
methods. Putting a value in one is a plain conversion, and a copy of it is a copy of the value:

```eider
trait Handler {
    fn handle(self, path: str) -> i32
}

type Fixed = { code: i32 }
type Prefix = { prefix: str, code: i32 }

impl Handler for Fixed {
    fn handle(self, path: str) -> i32 { self.code }
}

impl Handler for Prefix {
    fn handle(self, path: str) -> i32 {
        if path.len() >= self.prefix.len() { self.code } else { 404 }
    }
}

fn main() uses io {
    var routes: List[dyn Handler] = List.new()
    routes.push(Fixed(200))
    routes.push(Prefix("/api", 201))
    for r in routes { print(r.handle("/api/x")) }
}
```

```output
200
201
```

Not every trait can be `dyn`: the compiler needs one table of methods that works for any
implementing type, so the trait's methods must take `self` or `inout self`, have no type
parameters and not mention `Self` besides the receiver (the rule is printed in the error,
E0607). See [Traits](../reference/traits.md#dyn-trait).

## Closures

```eider
fn apply_twice(f: fn(i32) -> i32, x: i32) -> i32 { f(f(x)) }

fn adder(n: i32) -> fn(i32) -> i32 {
    |x| x + n
}

fn main() uses io {
    let mut xs: List[i32] = List.new()
    for i in 1..7 { xs.push(i) }
    let squares = xs.map(|x| x * x)
    let evens = xs.filter(|x| x % 2 == 0)
    let sum = xs.fold(0, |acc, x| acc + x)
    print(squares)
    print(evens)
    print(sum)
    print(apply_twice(adder(10), 1))
    print(xs.any(|x| x > 5))
}
```

```output
[1, 4, 9, 16, 25, 36]
[2, 4, 6]
21
21
true
```

A closure is `|params| body`; its type is `fn(A, B) -> R`, and named functions are values
of the same types. A closure captures a snapshot of the variables it uses (by reference when it is the argument of
`map`, `fold` and the like), so it can't change them; to change state, pass it an `inout` parameter or use a shared handle (below).
A closure whose body is a block or `if` needs its result type written: `|x| -> i32 { ... }`.

## References: `let`, `let mut` and `.copy()`

Binding something doesn't copy it. `let x = place` (a variable, a field, an element) makes
`x` a read-only reference to that place; `let mut x = place` a mutable alias; `.copy()` an
independent value. A fresh value (a call's result, a literal) is simply owned:

```eider
type Order = { item: String, qty: i32 }

fn main() uses io {
    let mut orders: List[Order] = List.new()
    orders.push(Order(String.from("tea"), 1))
    orders.push(Order(String.from("cake"), 2))

    let first = orders[0]           // a reference: nothing is copied
    orders[0].qty = 5
    print(first.qty)                // sees the change

    let mut second = orders[1]      // a mutable alias
    second.qty += 10
    print(orders[1].qty)

    let mut mine = orders[1].copy() // an independent value
    mine.qty = 0
    print(orders[1].qty)
}
```

```output
5
12
12
```

The one rule to remember: while a reference is still going to be used, you can't change
its place in a way that could free or move what it points into. That is checked at compile
time:

```eider,compile_fail=E0308
type Order = { item: String, qty: i32 }

fn main() uses io {
    let mut orders: List[Order] = List.new()
    orders.push(Order(String.from("tea"), 1))
    let first = orders[0]
    orders.push(Order(String.from("cake"), 2))   // may move the buffer `first` points into
    print(first.qty)
}
```

The error is E0308 "can't call `push` on `orders` while `first` refers into it", with a
fix: bind `orders[0].copy()` instead, or use `first` before the push.
[Memory](memory.md) explains the six rules behind this and the common errors.

### Shared mutable state: `Ref[T]`

To share state that several owners change (a cache, a graph), use a `Ref[T]`. Copies of a
Ref are handles to the same value; access is scoped to a closure, so no reference to the
inside escapes:

```eider,ignore
fn main() uses io {
    let hits = Ref.new(0)
    let counter = hits                      // the same cell
    counter.update(|inout n| { n += 1 })
    hits.update(|inout n| { n += 1 })
    print(hits.get())
    print(counter.read(|n| n * 10))
}
```

```output
2
20
```

> **Note:** `Ref[T]` (and closures with `inout` parameters) are implemented in the compiler
> sources (`compiler/`) but not yet in the committed seed that `scripts/ei` builds, so this
> example is not run by the docs' tests. It works with the compiler built from
> `compiler/` today, and with `scripts/ei` after the next seed regeneration.

A Ref is for one thread. Across threads, the same shape is `Mutex[T]`.

## Capabilities

A function that reaches outside the program declares it: `uses io` (standard streams,
environment, arguments, exit), `fs` (files), `net` (sockets), `clock` (time, sleeping),
`threads` (starting threads), `ffi` (calling C). Callers must declare what their callees
use, all the way up to `main`:

```eider
import std.time

fn elapsed_ms(start: i64) -> i64 uses clock {
    time.mono_ms() - start
}

fn main() uses io, clock {
    let start = time.mono_ms()
    let ms = elapsed_ms(start)
    print(ms >= 0)
}
```

```output
true
```

Forgetting one is E0201 with a fix that adds it. A function without `uses` can't do any
of those things, and neither can the functions it calls; a closure carries the
capabilities of the function that wrote it. Dependencies are held to the
capabilities their depender grants in `eider.toml` ([Capabilities](capabilities.md)).

## Threads and channels

```eider
fn main() uses io, threads {
    let total = Mutex.new(0)
    let mut workers: List[Task[i32]] = List.new()
    for w in 0..4 {
        let t = total                         // a handle to the same Mutex
        workers.push(spawn(|| -> i32 {
            for i in 0..1000 { t.update(|n: i32| -> i32 n + 1) }
            w
        }))
    }
    for task in workers { let id = task.join() }
    print(total.get())

    let ch: Chan[String] = Chan.new()
    let tx = ch
    let producer = spawn(|| -> i32 {
        for i in 0..3 { tx.send(String.from_int(i as i64)) }
        tx.close()
        0
    })
    while let Some(msg) = ch.recv() { print(msg) }
    let done = producer.join()
}
```

```output
4000
0
1
2
```

`spawn` starts a lightweight task running a closure and gives a `Task[T]`; `join` waits for its
result. Tasks share data only through `Mutex[T]` and `Chan[T]` handles; everything else a
task gets is its own copy, so data races can't be written. `std/chan` adds bounded
channels with deadlines and `select`, `std/task` cancellation tokens, task groups and a
worker pool ([Concurrency](concurrency.md)). A task that waits parks; it does not hold a thread.

## Modules and packages

A file is a module. `import geometry` loads the file `geometry.ei` next to the importer
(in a package, its modules are `<package>.geometry`) and its public names are reached
through the module's name: `geometry.Point`, `geometry.area(s)`.
Items are private unless marked `pub`:

```eider,ignore
// geometry.ei
pub type Point = { x: i32, y: i32 }
pub fn norm1(p: Point) -> i32 { abs(p.x) + abs(p.y) }
fn abs(n: i32) -> i32 { if n < 0 { -n } else { n } }

// main.ei
import geometry as geo

fn main() uses io {
    print(geo.norm1(geo.Point(3, -4)))
}
```

(Two files, so the docs' tests don't run it; it prints `7`.) The toolchain's modules are
`std.*` and `core.*`: `import std.strings`, or several at once, `import std.{bytes, fs}`;
a package's dependencies are imported by name, `import json`, `import json.stream`,
located through `eider.lock`. `import std` imports the whole namespace: `std.time.mono_ms()`
loads std's time module where it is first used. Import the modules a file uses a lot
directly and reach the occasional one through the namespace. The examples of eider-rpc and eider-openapi
([Building services](services.md)) are complete multi-module packages;
[Getting started](getting-started.md) shows eider-pkg.

## Tests

```eider
fn gcd(a: u64, b: u64) -> u64 {
    if b == 0 { return a }
    gcd(b, a % b)
}

fn main() uses io {
    print(gcd(84, 36))
}

test "gcd of coprime numbers is 1" {
    assert gcd(17, 5) == 1
}

test "gcd is symmetric" {
    assert gcd(84, 36) == gcd(36, 84), "order shouldn't matter"
}
```

```output
12
```

`scripts/ei test file.ei` runs every `test` block (`run` ignores them). Test blocks have
every capability. [Testing](testing.md) covers std/testing, compile-fail tests and test
doubles.

## C in one paragraph

An `extern "c" fn` declares a C function (integer, `bool` and `str` parameters and
results). Calling it needs `uses ffi` and an `unsafe` block, and a package that contains
one must be granted `ffi` by its users, so unmanaged code is always visible.
`export fn` goes the other way: `scripts/ei build --lib` makes a static and a shared
library plus a C header for C and C++ callers, and `build --wasm` makes a WebAssembly
module with TypeScript declarations ([FFI](ffi.md), [WebAssembly](wasm.md)).

```eider
extern "c" fn abs(n: i32) -> i32

fn main() uses io, ffi {
    let n = unsafe { abs(-42) }
    print(n)
}
```

```output
42
```
