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
| `x` | anything (when `x` isn't a unit variant in scope) | `x` |
| `mut x` | anything | `x`, mutable |
| `3`, `-1`, `0xff` | that integer (of the scrutinee's type) | nothing |
| `"text"` | a `str` equal to it | nothing |
| `true`, `false` | that `bool` | nothing |
| `()` | the unit value | nothing |
| `None`, `Red` | that unit variant | nothing |
| `Some(p)`, `Rect(w, h)` | that variant, with each payload field matching its sub-pattern | what the sub-patterns bind |
| `Point(x, y)` | a record, field by field in declaration order | what the sub-patterns bind |
| `(p, q)`, `(p,)` | a tuple, element by element | what the sub-patterns bind |

**Names.** A bare name is a unit variant when one with that name is in scope (`None`,
`Less`, a variant of your enum), and otherwise a new binding that matches anything.
Constants are not looked up: in `match x { MAX => ... }`, `MAX` binds a new name, so the
arm matches every value (and an arm after it is E0102). Compare with a constant with `if`
instead.

**Literals.** An integer literal takes the scrutinee's type and must fit in it (E0501:
`-1` against a `u8`). String literal patterns match a `str` only; to match a `String`,
compare with `==` or match on a `str` you have.

**Variants and records.** Sub-patterns are positional, one per field, in the order the
fields are declared; named payload fields (`Some(value: T)`) are still matched by position.
The count must be exact (E0410), and a payload variant can't be written without its
parentheses (E0410 "variant `Circle` has 1 field(s); write `Circle(...)`"). A variant may
be qualified by its enum or by a module alias: `Shape.Circle(r)`, `geo.North`. A name that
is neither a variant nor a constructor of the matched type is E0114.

**Tuples.** `(p, q)` matches a tuple of two elements; the count must match the tuple's
(E0410). `(p,)` is a one-element tuple; `(p)` is just `p` in parentheses.

**Or-patterns.** In a `match` arm (only there), several patterns separated by `|` match
when any of them does. They can't bind names (E0001 "or-patterns can't bind names"): each
alternative may only use literals, variants, tuples of them and `_`.

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
| `for x in e`, `for (p, q) in e` | a name, or a pattern in parentheses | yes (E0101) |

A `let` destructures only tuples: there is no `let Point(x, y) = p` or
`let Some(x) = o`; use `match` or `if let` for records and variants.

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
```

The scrutinee is evaluated once; the arms are tried in order and the first that matches
runs. Arms are separated by newlines or commas. An arm's body is an expression (a block
for several statements), or one of `return`, `break`, `continue` and `assert`; an
assignment needs a block (`Some(mut v) => { v += 1 }`).

As an expression, every arm's value must have the same type (E0401), and the `match` is
subject to the positions rule for `if`, `match` and blocks (E0103, see
[Expressions](expressions.md#if)).

### Exhaustiveness and reachability

The arms of a `match` must together match every possible value (E0101 "non-exhaustive
match: `None` is not handled", which names a missing case). The compiler knows every value
of `bool`, of enums (including nested payloads and tuples of them) and of `()`. Integers and
text have too many values to list, so a `match` on them needs a `_` arm or a binding arm.
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
