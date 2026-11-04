# Patterns

A pattern describes the shape of a value: it can test the value (is it `Some`? is it 3?)
and bind names to its parts. Patterns appear in `match` arms, `if let`, `while let`,
`let (...) =` and `for`. This page lists every pattern form, where each may be used, and
the rules for exhaustiveness.

```text
pattern = int_literal | "-" int_literal | string_literal | "true" | "false"
        | "_" | ["mut"] name
        | [qualifier "."] name "(" [pattern {"," pattern} [","]] ")"
        | "(" ")" | "(" pattern "," ")" | "(" pattern {"," pattern} [","] ")"
arm     = pattern {"|" pattern} "=>" (expr | return_stmt | break_stmt | continue_stmt | assert_stmt)
```

## Pattern forms

| Pattern | Matches | Binds |
|---|---|---|
| `_` | anything | nothing |
| `x` | anything (when `x` isn't a unit variant or a constant in scope) | `x` |
| `mut x` | anything | `x`, mutable |
| `3`, `-1`, `0xff` | that integer (of the scrutinee's type) | nothing |
| `0..=9`, `-5..=-1` | an integer in that range, both ends included | nothing |
| `MAX` | a value equal to that constant | nothing |
| `"text"` | a `str` or `String` equal to it | nothing |
| `true`, `false` | that `bool` | nothing |
| `()` | the unit value | nothing |
| `None`, `Red` | that unit variant | nothing |
| `Some(p)`, `Rect(w, h)` | that variant, with each payload field matching its sub-pattern | what the sub-patterns bind |
| `Point(x, y)` | a record, field by field in declaration order | what the sub-patterns bind |
| `Point { x, y: 0, .. }`, `Circle { r }` | a record or variant, by field name | what the sub-patterns bind; `x` alone binds field `x` |
| `(p, q)`, `(p,)` | a tuple, element by element | what the sub-patterns bind |

**Names.** A bare name is a unit variant when one with that name is in scope (`None`,
`Less`, a variant of your enum), a constant when one is in scope, and otherwise a new
binding that matches anything.

**Constants.** `match x { MAX => ... }` compares `x` with the constant `MAX` (of the same
type, E0401 otherwise), and it counts like the literal it holds for exhaustiveness and
reachability. (Constants are integers, `bool` and `str`.)

**Literals.** An integer literal takes the scrutinee's type and must fit in it (E0501:
`-1` against a `u8`). A string literal pattern matches a `str` or a `String` with that text.

**Ranges.** `lo..=hi` matches integers from `lo` to `hi`, both included; the bounds are
integer literals that fit the scrutinee's type (E0501), and `lo` can't be above `hi` (E0118).
Ranges count for exhaustiveness: `0..=127` and `128..=255` cover a `u8`.

**Variants and records.** Sub-patterns are positional, one per field, in the order the
fields are declared; named payload fields (`Some(value: T)`) are still matched by position.
The count must be exact (E0410), and a payload variant can't be written without its
parentheses (E0410 "variant `Circle` has 1 field(s); write `Circle(...)`"). A variant may
be qualified by its enum or by a module alias: `Shape.Circle(r)`, `geo.North`. A name that
is neither a variant nor a constructor of the matched type is E0114.

**Field patterns.** `Point { x, y: 0, .. }` names fields instead of counting them: `x` alone
binds the field to that name, `y: 0` matches the field against a sub-pattern, and a trailing
`..` leaves the other fields out, so adding a field doesn't break the pattern. Without `..`
every field must be named (E0410); an unknown field is E0113, one named twice E0107. It works
for records and for variants with named fields (`Circle { r }`).

**Tuples.** `(p, q)` matches a tuple of two elements; the count must match the tuple's
(E0410). `(p,)` is a one-element tuple; `(p)` is just `p` in parentheses.

**Or-patterns.** In a `match` arm (only there), several patterns separated by `|` match
when any of them does. Every alternative must bind the same names with the same types (E0117);
each binding holds a copy of the part that matched, also when the scrutinee is a place, so
`mut` isn't allowed in one (E0117).

```eider
type Shape = | Circle(r: i32) | Rect(w: i32, h: i32) | Dot

fn area(s: Shape) -> i32 {
    match s {
        Circle(r) => 3 * r * r
        Rect(w, h) => w * h
        Dot => 0
    }
}

fn size(n: i32) -> str {
    match n {
        0 => "none"
        1 | 2 | 3 => "few"
        -1 => "minus one"
        _ => "many"
    }
}

fn main() uses io {
    print(area(Rect(2, 3)))
    print(area(Circle(1)))
    print(size(2))
    print(size(-1))
    match (1, Some(true)) {
        (1, Some(b)) => print(b)
        (_, _) => print("no")
    }
}
```

```output
6
3
few
minus one
true
```

## Where patterns appear

| Construct | Patterns | Must be irrefutable |
|---|---|---|
| `match e { p => ... }` | any, `|` allowed | no; the arms together must be exhaustive |
| `if let p = e { } else { }` | any | no |
| `while let p = e { }` | any | no |
| `let (p, q) = e` | a tuple pattern (the `let` form starts with `(`) | yes (E0101) |
| `let p = e else { }` | any (starts with a variant or record name, or `(`) | no; the `else` block must leave the scope |
| `for x in e`, `for (p, q) in e` | a name, or a pattern in parentheses | yes (E0101) |

A plain `let` destructures only tuples: there is no `let Point(x, y) = p` or
`let Some(x) = o`; use `match` or `if let` for records and variants, or
[`let ... else`](statements.md#let-else) when the rest of the block needs the bindings and
the other case leaves the scope.

`if let p = e { A } else { B }` is the same as `match e { p => { A } _ => { B } }`, and
`while let` is described in [Statements](statements.md#while). An `else` may be followed by
another `if` or `if let`.

```eider
fn main() uses io {
    let o: Option[i32] = Some(3)
    if let Some(n) = o { print(n) }
    let r: Result[i32, str] = Err("bad")
    if let Ok(v) = r {
        print(v)
    } else if let Err(e) = r {
        print(e)
    }
    let (a, (b, c)) = (1, (2, 3))
    print(a + b + c)
}
```

```output
3
bad
6
```

## `match`

```text
match_expr = "match" expr "{" { arm (newline | ",") } "}"
arm        = pattern { "|" pattern } [ "if" expr ] "=>" body
```

The scrutinee is evaluated once; the arms are tried in order and the first that matches
runs. Arms are separated by newlines or commas. An arm's body is an expression (a block
for several statements), or one of `return`, `break`, `continue` and `assert`; an
assignment needs a block (`Some(mut v) => { v += 1 }`).

As an expression, every arm's value must have the same type (E0401), and the `match` is
subject to the positions rule for `if`, `match` and blocks (E0103, see
[Expressions](expressions.md#if)).

**Guards.** `pattern if cond =>` runs the arm only when the pattern matches and `cond`, a
`bool` that can use the pattern's bindings, holds; otherwise the next arms are tried. A guarded
arm doesn't count for exhaustiveness or reachability of the arms after it, so a `match` still
needs arms for what its guards may leave out.

```eider
type Reading = | Temp(c: i32) | Off

fn describe(r: Reading) -> str {
    match r {
        Temp(c) if c > 30 => "hot"
        Temp(0..=30) => "fine"
        Temp(_) => "cold"
        Off => "off"
    }
}

fn main() uses io {
    print(describe(Temp(35)))
    print(describe(Temp(20)))
    print(describe(Temp(-4)))
    print(describe(Off))
}
```

```output
hot
fine
cold
off
```

### Exhaustiveness and reachability

The arms of a `match` must together match every possible value (E0101 "non-exhaustive
match: `None` is not handled", which names a missing case). The compiler knows every value
of `bool`, of enums (including nested payloads and tuples of them) and of `()`, and with
range patterns those of an integer type. Other integer matches and text have too many values
to list, so they need a `_` arm or a binding arm. Guarded arms cover nothing.
A `match` with no arms is E0101 too.

An arm that can never run because the arms above it already match everything it does is
E0102 (a repeated literal or variant, anything after `_` or a binding).

```eider,compile_fail=E0101
fn main() uses io {
    let o: Option[i32] = Some(1)
    match o {
        Some(v) => print(v)
    }
}
```

```eider,compile_fail=E0102
fn main() uses io {
    match 1 {
        _ => print("any")
        1 => print("one")
    }
}
```

## Bindings

What a binding holds depends on the scrutinee (see [Memory model](memory.md#pattern-bindings)):

- When the scrutinee is a place (a variable, field or element), a plain binding `x` is a
  read-only reference into it, and `mut x` a mutable alias: writes through it change the
  place. The place must be writable for `mut` (E0307).
- When the scrutinee is a fresh value (a call, a literal, a constructor), each binding owns
  its part; `mut` makes it a mutable local.
- In `for` patterns each binding owns a copy of its part.

```eider
fn main() uses io {
    let mut slots: List[Option[i32]] = List.new()
    slots.push(Some(1))
    slots.push(None)
    match slots[0] {
        Some(mut v) => { v += 10 }
        None => {}
    }
    print(slots)
}
```

```output
[Some(11), None]
```

Bindings are scoped to their arm (or to the `if let` / `while let` body). A binding can
shadow a variable of the enclosing scope.

```eider
const LIMIT: i32 = 10

type Point = { x: i32, y: i32, name: String }
type Event = | Key(code: i32) | Click(code: i32) | Quit

fn point(p: Point) -> String {
    match p {
        Point { x: 0, y: 0, .. } => String.from("origin")
        Point { x, name, .. } if x < 0 => "{name} is left of it"
        Point { name, .. } => "{name} is elsewhere"
    }
}

fn event(e: Event) -> String {
    match e {
        Key(c) | Click(c) => "code {c}"
        Quit => String.from("quit")
    }
}

fn size(n: i32) -> str {
    match n {
        LIMIT => "exactly the limit"
        0..=9 => "under it"
        _ => "something else"
    }
}

fn command(s: String) -> i32 {
    match s {
        "up" => 1
        "down" => -1
        _ => 0
    }
}

fn main() uses io {
    print(point(Point(0, 0, String.from("a"))))
    print(point(Point(-1, 5, String.from("b"))))
    print(point(Point(2, 5, String.from("c"))))
    print(event(Click(7)))
    print(size(10))
    print(size(3))
    print(command(String.from("down")))
}
```

```output
origin
b is left of it
c is elsewhere
code 7
exactly the limit
under it
-1
```
