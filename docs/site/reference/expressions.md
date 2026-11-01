# Expressions

An expression computes a value. This page gives the operators with their precedence, then
each kind of expression: literals, names, calls, methods, fields, indexing, closures,
`if`, `match`, blocks and `?`. Statements (`let`, assignment, loops) are in
[Statements](statements.md); the types the operators work on are in [Types](types.md).

## Evaluation order

Operands, arguments and elements are evaluated left to right, each exactly once: in
`f(a(), b())`, `a()` runs before `b()`; in `a() + b() * c()`, the three calls run in that
order, then the multiplication, then the addition. `&&` and `||` evaluate their right
operand only when needed.

```eider
fn note(n: i32) -> i32 uses io {
    print(n)
    n
}

fn main() uses io {
    let v = note(1) + note(2) * note(3)
    print(v)
}
```

```output
1
2
3
7
```

## Operator precedence

From tightest to loosest:

| Level | Operators | Associativity |
|---|---|---|
| 1 | postfix: call `f(...)`, method `.m(...)`, field `.f`, tuple element `.0`, index `[i]`, `?` | left to right |
| 2 | prefix `-` `!` `~` | right (`--x`, `!!b`) |
| 3 | `as` | left (`x as u32 as u64`) |
| 4 | `*` `/` `%` `*%` | left |
| 5 | `+` `-` `+%` `-%` | left |
| 6 | `<<` `>>` | left |
| 7 | `&` | left |
| 8 | `^` | left |
| 9 | `\|` | left |
| 10 | `==` `!=` `<` `<=` `>` `>=` | left |
| 11 | `&&` | left |
| 12 | `\|\|` | left |

So `-x as i64` is `(-x) as i64`, `a + b as u64` is `a + (b as u64)`, `!a == b` is
`(!a) == b`, and `a < b && c < d` groups as expected. Comparisons don't chain in a useful
way: `a < b < c` compares the `bool` `a < b` with `c`, which is E0401 unless `c` is a
`bool`.

### Bitwise operators need parentheses

Levels 6 to 9 follow C and Rust, but Eider doesn't *rank* the bitwise operators against
arithmetic, comparisons or each other. An operand of `&`, `|`, `^`, `<<` or `>>` can't be an
unparenthesized operation of another group, and an operand of a comparison can't be an
unparenthesized `&`, `|` or `^`. The exceptions, where languages agree:

- a shift may be an operand of `&`, `|` and `^`: `x >> 4 & 15`;
- a comparison may compare shifts: `1 << n == m`;
- a chain of one operator is fine: `a | b | c`, `a << 1 << 2`.

Everything else is E0002, a syntax error naming both operators, with a machine-applicable
fix that adds the parentheses C would imply. This rules out C's `a & b == c` (C reads
`a & (b == c)`), Go's `a + b & c` (Go reads `a + (b & c)`) and `1 << n - 1`.

```eider,compile_fail=E0002
fn main() uses io {
    let flags: u32 = 6
    print(flags & 3 == 2)
}
```

```eider
fn main() uses io {
    let flags: u32 = 6
    let n: u32 = 3
    print((flags & 3) == 2)
    print(flags >> 1 & 3)
    print(1 << n == 8)
    print(flags | 1 | 8)
    print((1 << n) - 1)
}
```

```output
true
3
true
15
7
```

## Operators

### Arithmetic

`+`, `-`, `*`, `/`, `%` take two integers of the same type and give that type. They trap on
overflow, on a zero divisor and on `MIN / -1`; `+%`, `-%`, `*%` wrap instead. Unary `-`
negates a signed integer. The exact rules are in
[Types](types.md#arithmetic-and-overflow). When both operands are constants the result is
computed at compile time, and an overflow is E0501 (with a help suggesting the wrapping
operator), a zero divisor E0502.

There are no implicit conversions: `a + b` with `a: i64` and `b: i32` is E0401; write
`a + (b as i64)`. A literal operand takes the other operand's type. There is no operator
overloading: `+` doesn't apply to text or to your own types.

### Bitwise

`&`, `|`, `^` (and, or, exclusive or) and `~` (complement) work on every integer type and
never trap. `x << n` and `x >> n` need `n` of the same type as `x`, at least 0 and below the
width in bits (a trap at run time, E0505 for a constant). `>>` copies the sign bit on
signed types.

### Comparison

`==` and `!=` need the operand type to implement `Eq`; `<`, `<=`, `>`, `>=` need `Ord` (see
[Traits](traits.md#the-operation-traits)). Integers, `bool`, `str` and `String` have both;
records, enums, tuples, arrays, Lists and Boxes have them when their parts do (compared
field by field, lexicographically); Maps have `==` but no order; fn values, handles and
`Ref` have neither (E0401 says which part lacks the trait). Both operands have the same
type, and the result is `bool`. `()` can't be compared.

### Logical

`!b` negates a `bool`. `a && b` is true when both are; `b` is evaluated only when `a` is
true. `a || b` is true when either is; `b` is evaluated only when `a` is false. Operands
must be `bool`: integers are not conditions.

### `as`

`e as T` converts between integer types, checked: a value that doesn't fit traps with
`integer conversion out of range`. See [Types](types.md#conversions-as).

## Literals

| Expression | Type |
|---|---|
| `42`, `0xff` | an integer type, from the context (see [Types](types.md#integer-literals)) |
| `"text"` | `str` |
| `"n = {n}"`, `"{x:>8}"` | `String` ([interpolation](lexical.md#interpolation)) |
| `r"text"`, `r#"a "b""#` | `str` ([raw strings](lexical.md#raw-strings)) |
| `true`, `false` | `bool` |
| `()` | `()` |
| `(a, b)`, `(a,)` | a tuple |
| `[a, b, c]` | an array `[T; 3]`; every element has the first one's type |
| `[x; 4]` | an array of 4 copies of `x` (the length is an integer literal, at least 1) |

An empty array literal `[]` has no length to give a type to; there are no `List` literals
(build Lists with `List.new()` and `push`).

## Names

A name in an expression is, in order of lookup, a local variable or parameter of an
enclosing scope, a constant, or a unit variant (`None`, `Red`). A function name is not a
value on its own: `let f = add` is E0110 "`add` is a function; call it with `add(...)`".
Where a fn type is expected (an annotated `let`, a parameter of fn type), a function name
is a function value: `let f: fn(i32, i32) -> i32 = add`.

A name may be qualified by a module alias (`geo.area`, `geo.Point`), see
[Modules](modules.md), and a unit variant by its enum (`Color.Red`).

## Calls

```text
call = name "(" [arg {"," arg} [","]] ")"
arg  = ["inout"] expr
```

Only a name can be called: a function, a local variable or parameter holding a function
value, a qualified name (`geo.area(s)`), a record or variant constructor, or a built-in
function. Calling any other expression (`make()(3)`, `(f)(3)`) is E0001 "only named
functions can be called": bind the value to a name first. There is no syntax for explicit
type arguments; they are inferred (see [Traits and generics](traits.md#inference)).

The arguments must match the parameters in number (E0405) and type (E0401). An argument for
an `inout` parameter is written `inout place` (E0304 without it, with a fix) and must be a
writable place; a place passed `inout` can't appear again in the same call (E0301; see
[Memory model](memory.md#parameters-and-inout)). Ordinary arguments are passed as
read-only references: nothing is copied.

Calling a function that `uses` a capability needs the caller to declare it too (E0201, see
[Capabilities](capabilities.md)).

### Constructors

A record type's name called with one argument per field, in declaration order, builds a
record: `Point(1, 2)`. A payload variant is built the same way: `Circle(2)`, `Some(x)`,
`Ok(())`. Unit variants are plain names (`Dot`, `None`) or qualified by the enum
(`Shape.Dot`). There is no `Point { x: 1, y: 2 }` syntax and no named arguments.

### Built-in functions

| Call | Type | Notes |
|---|---|---|
| `print(x)` | `()` | writes `x` and a newline to stdout; needs `uses io` and `x: Show`; exactly one argument |
| `len(x)` | `usize` | an array (a constant), List, Map, String or str |
| `panic(msg)` | never returns | `msg: str`; traps with that message |
| `now_ms()` | `u64` | monotonic time in milliseconds; needs `uses clock` |
| `spawn(f)` | `Task[T]` | runs `f: fn() -> T` on a new thread; needs `uses threads` (see [Concurrency](concurrency.md)) |

Their names are reserved in the entry module: a program can't define a function called
`print`.

## Methods and associated functions

`x.m(args)` calls the method `m` of `x`'s type with `x` as the receiver `self`. The method
is looked up in this order:

1. a built-in method of the type (`len`, `push`, `get`, ... see [Types](types.md));
2. a method from an `impl` of the type, inherent or of a trait, including impls on
   built-in types (see [Items](items.md#impls));
3. a method of a language trait the type has, derived or its own: `copy`, `eq`, `compare`,
   `hash`, `show`, `to_string`, and `take`/`replace` (see [Memory model](memory.md));
4. otherwise, a field `m` holding a function is called: `handler.on_request(req)`.

So a method always wins over a field of the same name; to call such a field, bind it first
(`let h = x.f; h(args)`). A method whose receiver is `inout self` needs `x` to be a
writable place (E0303). A field that isn't a function, or no such method at all, is E0115.

`T.f(args)` calls the associated function `f` (one without `self`) of type `T`:
`P.origin()`, `String.from("x")`, `List.new()`, `i32.default()`. In a generic body, `T.f()`
on a type parameter calls the function of the type `T` stands for (with the bound it needs,
see [Traits](traits.md)).

```eider
type Point = { x: i32, y: i32 }

impl Point {
    fn origin() -> Point { Point(0, 0) }
    fn sum(self) -> i32 { self.x + self.y }
    fn shift(inout self, d: i32) { self.x += d }
}

type Handler = { on: fn(i32) -> i32 }

fn main() uses io {
    let mut p = Point.origin()
    p.shift(5)
    print(p.sum())
    print(Point(1, 2).sum())
    let h = Handler(|n| n * 2)
    print(h.on(21))
}
```

```output
5
3
42
```

## Fields and tuple elements

`e.f` reads field `f` of a record; `e.0`, `e.1`, ... read tuple elements (`t.0.1` reads
into a nested tuple). An unknown field or an index past the end is E0113. When `e` is a
place, `e.f` is a place too: it can be assigned (`p.x = 1`), passed `inout` and referenced
by `let`.

## Indexing

`e[i]` reads element `i` of an array or a List; `i` must be a `usize` (E0401 otherwise, with
a help suggesting `as usize`). The index is checked: out of bounds traps with `index out of
bounds` (E0503 for a constant index into an array). Indexing a place gives a place:
`grid[i][j] = 0`. Maps aren't indexed; use `m.get(k)`. Text is indexed with
`s.byte(i)`.

## Closures

```text
closure = "|" [cparam {"," cparam}] "|" ["->" type] expr
        | "||" ["->" type] expr
cparam  = ["inout"] name [":" type]
```

A closure is an anonymous function value. `|x| x + 1`, `|a: i32, b: i32| -> i32 { a + b }`,
`|| print("hi")`.

- **Types.** Parameter types come from the fn type the closure is passed as or assigned to;
  without one they must be written (E0409 "cannot infer the type of closure parameter").
  The result type is the body's type, or the expected fn type's result; a body that is a
  block, `if` or `match` needs one of those or an explicit `-> T` (E0409 "cannot infer the
  closure's return type").
- **Body.** One expression; use a block for statements. `return` in the body returns from
  the closure. `?` works in a block body with a known result type; `?` in a body that isn't
  a block is not supported yet (an `unsupported` error).
- **Captures.** A closure can read every variable in scope where it is written. It
  captures a snapshot: the values are copied (copy-on-write, so cheaply) when the closure is
  created, so later changes to the variables are not seen, and the closure can't assign to
  them (E0303). To change state from a closure, give it an `inout` parameter or capture a
  `Ref[T]` (see [Memory model](memory.md#closures-capture-snapshots)).
- **`inout` parameters.** `|inout x| ...` declares a parameter the closure may change; it
  must match an `inout` in the expected fn type, and the reverse (E0304).

```eider
fn apply(f: fn(i32) -> i32, x: i32) -> i32 { f(x) }

fn main() uses io {
    let k = 10
    let add_k = |x: i32| x + k
    print(apply(add_k, 1))
    let classify = |n: i32| -> str {
        if n < 0 { return "negative" }
        "non-negative"
    }
    print(classify(-3))
    let mut n = 1
    let snapshot = || n * 100
    n = 2
    print(snapshot())
    print(n)
}
```

```output
11
negative
100
2
```

A closure is a value of a fn type (see [Types](types.md#function-types)): it can be stored
in a variable, a field or a List, passed and returned. A closure written inside an
`unsafe { }` block may call C functions (see [C interop](ffi.md)).

> **Note:** Closures that don't escape will capture by reference in a later version
> (backlog item 8.8); today every closure captures a snapshot. See the
> [roadmap](../../design/roadmap.md).

## `if`

```text
if_expr = "if" expr block ["else" (block | if_expr)]
        | "if" "let" pattern "=" expr block ["else" (block | if_expr)]
```

The condition is a `bool`. `else if` chains. As a value, both branches must have the same
type (E0401 "branches have different types"); an `if` without `else` has type `()`.
`if let` matches a pattern (see [Patterns](patterns.md#where-patterns-appear)).

**Where `if`, `match` and blocks may be used as values.** `if`, `match`, a block `{ ... }`
and `unsafe { ... }` are expressions, but only in these positions:

- as a statement;
- as the last expression of a block or function body, or as a closure's or match arm's
  body;
- as the right side of `let`, of an assignment, or of `return`.

Anywhere else (an operand, a call argument, a field initializer) is E0103: bind the value
to a name first.

```eider
fn sign(n: i32) -> i32 {
    if n < 0 { -1 } else if n == 0 { 0 } else { 1 }
}

fn main() uses io {
    let n = 7
    let size = if n > 5 { "big" } else { "small" }
    print(size)
    let s = sign(-2)
    print(10 * s)
}
```

```output
big
-10
```

## `match`

`match e { arms }` is described in [Patterns](patterns.md#match). As a value, every arm
has the same type; the positions rule above applies.

## Blocks

`{ statements }` is an expression whose value is its last statement's value (see
[Statements](statements.md#blocks-and-separators)). Names declared inside are local to it.
`unsafe { ... }` is a block in which C functions may be called (see
[C interop](ffi.md)).

## The question mark operator

`e?` returns early from the enclosing function when `e` holds no value:

- On a `Result[T, E]`: `Ok(v)?` is `v`; `Err(x)?` returns `Err(x)` from the function, which
  must return a `Result[_, E2]`. When `E2` is not `E`, the error is converted with an
  `impl From[E] for E2` (see [Traits](traits.md#the-operation-traits)); without one it is E0401.
- On an `Option[T]`: `Some(v)?` is `v`; `None?` returns `None` from a function returning an
  `Option`.

Using `?` on another type, or in a function whose result isn't the same kind (an `Option`
`?` in a function returning a `Result`), is E0406. Before returning, `?` drops what the
function's scopes own, as `return` does. It is a postfix operator: `parse(s)?.len()`.

```eider
fn digit(s: str) -> Result[i32, str] {
    if s == "1" { Ok(1) } else { Err("not a digit") }
}

fn double(s: str) -> Result[i32, str] {
    let v = digit(s)?
    Ok(v * 2)
}

fn last_plus_one(xs: List[i32]) -> Option[i32] {
    let mut c = xs.copy()
    let v = c.pop()?
    Some(v + 1)
}

fn main() uses io {
    print(double("1"))
    print(double("x"))
    let empty: List[i32] = List.new()
    print(last_plus_one(empty))
}
```

```output
Ok(2)
Err("not a digit")
None
```

## Method chains across lines

A line whose first token is `.` continues the expression on the line before it, so a chain
of calls can be written one call per line (blank and comment lines may come between). A
line may not end with `.`. See [Lexical structure](lexical.md#newlines).
