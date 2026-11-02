# Comptime reflection

Reflection lets generic code look at a type's fields, variants and
[attributes](attributes.md) while the compiler specializes it, and generate code from them:
a JSON codec, a schema, a pretty-printer, written once for every record. It is typed and
read-only. A reflected field is not a string to look up: `x.[f]` is a typed access that the
compiler checks like `x.name`. Nothing is generated as text, so the code is ordinary Eider
that the checker, the analyzer and the backends already understand.

```text
stmt     = ... | "comptime" "for" IDENT "in" ("fields" | "variants") "(" type ")" block
expr     = ... | "comptime" if_expr
             | expr ".[" IDENT "]"
             | ("attr" | "has_attr") "[" type "]" "(" type ")"
argument = ... | "comptime" "for" IDENT "in" "fields" "(" type ")" block
```

## Going over fields and variants

`comptime for f in fields(T) { ... }` checks its body once per field of record type `T`, in
declaration order, with `f` naming that field. `comptime for v in variants(T)` does the same
per variant of enum `T`, and `fields(v)` inside it goes over the payload fields of the
variant `v` names. `T` may be a concrete type or a type parameter: a generic function is
specialized per type it is called with, and its reflection is resolved per specialization,
so every type parameter is a comptime one.

```eider
type Point = { x: i64, y: i64, label: String }

fn describe[T](x: T) uses io {
    comptime for f in fields(T) {
        print(f.name)
    }
}

fn main() uses io {
    describe(Point(1, 2, String.from("p")))
}
```

```output
x
y
label
```

What a reflected name gives:

| Expression | Value |
|---|---|
| `f.name` | the field's name, a `str` (a positional payload field: its index, `"0"`) |
| `f.index` | its position, a `usize` |
| `x.[f]` | field f of x: a place of the field's type (read it, assign it, pass it `inout`) |
| `v.name`, `v.index` | the variant's name and position |
| `v.matches(x)` | whether enum value x is variant v |
| `v(...)` | variant v, built from its payload |
| `attr[A](f)` | the values of attribute A on f, as a value of A's record type (the declared defaults when f doesn't have it) |
| `has_attr[A](f)` | whether f has attribute A |

`attr[A]` and `has_attr[A]` also take a type (`attr[json](T)`) for the attributes on its
declaration. A reflected name exists only while the compiler checks the body: using `f`
itself as a value is E0831. `x.[f]` with x of another type than f's record is E0830, and so
is `fields(...)` of something that isn't a record or a variant, or `variants(...)` of
something that isn't an enum. A payload field read with `x.[f]` from a value of another
variant is a trap, not a read of the wrong payload; test `v.matches(x)` first.

Each iteration is a loop that runs once: `continue` goes to the next field. `break` is E0832
(the body is not a loop at run time). Errors found while checking an iteration say which
field or variant it was for (`in the comptime for iteration over field b of P`).

## Choosing code at compile time

`comptime if c { ... } else { ... }` checks only the branch that `c` selects. The condition
is evaluated while the code is checked. It may use literals, constants, `f.name`, `f.index`,
`v.name`, `v.index`, attribute values (`attr[A](f).key`), `has_attr[A](f)`, `+ - *`, `!`,
`&&`, `||`, comparisons and `is_enum_type[T]` (whether a type is an enum, not a record; a
[derived trait's](traits.md) default body tells the two apart with it); anything else is E0832. The branch that isn't taken can be code
that wouldn't type-check for this field, which is what lets a codec skip a field whose type
can't be encoded.

```eider
attr show { skip: bool = false, name: str = "" }

trait Text { fn text(self) -> String }

impl Text for i64 {
    fn text(self) -> String { String.from_int(self) }
}

impl Text for String {
    fn text(self) -> String { self.copy() }
}

type Job = {
    id: i64,
    @show(name = "title") name: String,
    @show(skip) lock: Mutex[i64],
}

fn line[T](x: T) -> String {
    let mut out = String.from("")
    comptime for f in fields(T) {
        comptime if !attr[show](f).skip {
            comptime if attr[show](f).name == "" { out.push_str(f.name) } else { out.push_str(attr[show](f).name) }
            out.push_str("=")
            out.append(x.[f].text())
            out.push_str(" ")
        }
    }
    out
}

fn main() uses io {
    print(line(Job(7, String.from("build"), Mutex.new(0))))
}
```

```output
id=7 title=build 
```

`lock` is a `Mutex`, which has no `text`: the skipped branch is never checked for it. A
`continue` inside a `comptime if` would not have helped. The statements after it would
still be checked for every field, so a field that can't be handled needs the rest of the
body in the `else` branch.

## Building values

A record or variant can be built from one value per field: a `comptime for` over its fields
is the argument list, and its body's value is each argument.

```eider
trait Zero { fn zero() -> Self }

impl Zero for i64 {
    fn zero() -> i64 { 0 }
}

impl Zero for bool {
    fn zero() -> bool { false }
}

fn zero_of[F: Zero]() -> F { F.zero() }

fn blank[T]() -> T {
    T(comptime for f in fields(T) { zero_of() })
}

type Flags = { count: i64, on: bool }

fn main() uses io {
    let f: Flags = blank()
    print(f.count)
    print(f.on)
}
```

```output
0
false
```

`T(...)` constructs the record a type parameter stands for; `v(...)` builds variant v. In
the body, `?` may return an error from the enclosing function, and an expression whose type
comes from what is expected (`zero_of()` above, or `decode(inout r)?`) gets the field's type.

## Cost and limits

Reflection costs what writing the code by hand would: each specialization is checked and
compiled like any other generic instance. It runs no code at compile time; a `comptime`
constant that calls reflective code is evaluated by the interpreter like any other (see
[Compile-time evaluation](comptime.md)). Reflection reads types; it doesn't create them.
`fields(...)` has no tuples. `comptime if` conditions can't call functions, and `break` can't
leave a `comptime for`.

## Errors

| Code | When |
|---|---|
| E0830 | `fields` of a non-record, `variants` of a non-enum, `x.[f]` on a value of another type, a member other than `name`, `index`, `matches`, a `comptime for` argument list that doesn't go over the fields it builds |
| E0831 | a reflected name used as a value, `x.[e]` where e isn't a `comptime for` variable |
| E0832 | a `comptime if` condition that isn't known while checking, `break` in a `comptime for` |
