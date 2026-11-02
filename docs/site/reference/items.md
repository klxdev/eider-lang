# Items

A source file is a sequence of *items*: functions, types, traits, impls, constants, tests,
imports and the C interop declarations. Items may appear in any order, with the one
exception noted under [Constants](#constants). This page gives the syntax and the rules of
each kind; the exact grammar is in [Grammar](grammar.md).

```text
item = import | module_line
     | ["pub"] fn_item | ["pub"] type_item | ["pub"] const_item | ["pub"] trait_item
     | impl_item | test_item
     | ["pub"] "extern" "\"c\"" fn_signature | "export" fn_item | ["pub"] "unsafe" fn_item
```

Items are separated by newlines (or `;`). A keyword can't be used as the name of an item
(E0001 "`fn` is a keyword and can't be used as a name"; the keywords are listed in
[Lexical structure](lexical.md)).

## Functions

```text
fn_item = "fn" name [generics] "(" [params] ")" ["->" type] ["uses" cap {"," cap}] block
param   = ["inout"] name ":" type | ["inout"] "self"
```

A function has a name, optional type parameters (see [Traits and generics](traits.md)),
parameters, an optional result type, an optional capability list and a body.

```eider
fn sign(x: i32) -> i32 {
    if x < 0 { return -1 }
    if x == 0 { 0 } else { 1 }
}

fn greet(name: str) uses io {
    print(name)
}

fn main() uses io {
    print(sign(-5))
    greet("eider")
}
```

```output
-1
eider
```

### Parameters

A parameter is a name and a type, separated by `:`. Parameters can't be assigned to
(E0303 "parameters are immutable; declare it `inout` to modify the caller's value"): an
ordinary parameter is a read-only view of the argument (see [Memory model](memory.md)).

An `inout` parameter is passed by reference: the function reads and writes the caller's
variable. The caller writes `inout` before the argument too, and the argument must be a
writable place (a `let mut` variable, a field or element of one, or another `inout`
parameter).

```eider
fn bump(inout n: i32) { n += 1 }

fn main() uses io {
    let mut k = 1
    bump(inout k)
    bump(inout k)
    print(k)
}
```

```output
3
```

Leaving out `inout` at the call is E0304 (with a fix that adds it); passing a read-only
place is E0303; passing the same variable twice, or reading a variable in one argument
while another passes it `inout`, is E0301 (exclusivity, see [Memory model](memory.md)).

```eider,compile_fail=E0304
fn bump(inout n: i32) { n += 1 }

fn main() {
    let mut k = 1
    bump(k)
}
```

`inout` is only valid on parameters: a type can't contain a reference (E0302).

### Result type and body

`-> T` gives the result type; without it the result is `()`, the unit type. The body is a
block. A function returns the value of `return e`, or the value of the block's last
statement when that is an expression. A function with a non-unit result whose body can end
without producing a value is an error (E0401 "function `f` must return i32, but its body
ends without producing one"):

```eider,compile_fail=E0401
fn f(x: i32) -> i32 {
    if x > 0 { return 1 }
}

fn main() {}
```

A body that ends in a call of a function that never returns (`panic`) needs no value
after it. `return` alone and `return ()` both return from a unit function.

```eider
fn check(x: i32) -> i32 {
    if x >= 0 { return x }
    panic("negative")
}

fn log(x: i32) uses io {
    if x == 0 { return }
    print(x)
}

fn main() uses io {
    log(check(7))
}
```

```output
7
```

Only some positions may hold an `if`, `match` or block used for its value: a statement, a
function's final expression, and the right side of `let`, `=` and `return` (E0103; see
[Expressions](expressions.md)).

### Capabilities

`uses io, fs` after the signature lists the capabilities the function needs. Calling a
function that uses a capability requires the caller to declare it too (E0201, with a fix
that adds it); an unknown name is E0203. See [Capabilities](capabilities.md).

```eider,compile_fail=E0201
fn tick() uses io, clock { print(1) }

fn main() uses io { tick() }
```

### Methods and associated functions

Functions inside an `impl` block are *methods* when their first parameter is `self` (the
receiver, written without a type: its type is the impl's type, `Self`), or `inout self`
when the method changes the receiver. Without `self` they are *associated functions*,
called on the type name. See [Impls](#impls).

### Generic functions

`fn name[T, U: Bound + Other](...)` declares type parameters, with optional trait bounds.
The type arguments are always inferred; there is no syntax to write them at a call. See
[Traits and generics](traits.md).

## Records

```text
type_item = "type" name [type_params] "=" (record_body | variants | type)
record_body = "{" field {sep field} [sep] "}"      (sep = "," | NL)
field = name ":" type
```

A record type is a named product of fields. Fields are separated by a comma or a
newline (a trailing comma is allowed, and the two may be mixed). A record needs at least one field
(E0111 "records need at least one field").

```eider
type Account = {
    id: u32
    owner: String
    balance: i64,
}

fn main() uses io {
    let a = Account(1, String.from("ada"), 250)
    print(a.owner)
}
```

A record is constructed by calling its name with one value per field, in declaration
order; there is no named-field constructor. The wrong number of values is E0405. Fields are
read with `.name` and written through a mutable binding.

```eider
type Point = { x: i32, y: i32 }

type Line = {
    from: Point,
    to: Point,
}

fn main() uses io {
    let mut p = Point(1, 2)
    p.x = 5
    print(p.x + p.y)
    let l = Line(Point(0, 0), p)
    print(l)
}
```

```output
7
Line { from: Point { x: 0, y: 0 }, to: Point { x: 5, y: 2 } }
```

A record can't contain itself by value (E0108 "type `Node` contains itself and would have
infinite size"); recursion goes through `Box[T]` or a `List`:

```eider,compile_fail=E0108
type Node = { value: i32, next: Option[Node] }

fn main() {}
```

```eider
type Node = { value: i32, next: Option[Box[Node]] }

fn sum(n: Node) -> i32 {
    match n.next {
        Some(b) => n.value + sum(b.get())
        None => n.value
    }
}

fn main() uses io {
    let list = Node(1, Some(Box.new(Node(2, Some(Box.new(Node(3, None)))))))
    print(sum(list))
}
```

```output
6
```

Duplicate field names are E0107.

## Enums

```text
variants = "|" variant {"|" variant}
variant  = name ["(" [payload {"," payload}] ")"]
payload  = [name ":"] type
```

An enum type is a set of variants, each written after a `|` (the first `|` is required; a
missing one is E0001 "expected `|`"). The variants may be on one line or one per line. A
variant has no payload or a parenthesized list of payload types; each payload may be given
a name, which documents it (payloads are only reached by [patterns](patterns.md), never by
`.name`: E0113 "type Tok has no fields").

```eider
type Tok =
    | Num(i64)
    | Op(sym: str, prec: u8)
    | End

fn describe(t: Tok) -> str {
    match t {
        Num(_) => "number"
        Op(s, _) => s
        End => "end"
    }
}

fn main() uses io {
    print(describe(Op("+", 1)))
    print(describe(Tok.End))
    print(Num(42))
}
```

```output
+
end
Num(42)
```

Variant names belong to the module's value namespace: a variant is constructed by its bare
name (`Num(42)`, `End`), and two enums of one module can't have a variant of the same name,
nor can a variant share its name with a function (E0107 "variant `X` is already
defined (variant names must be unique)"). A unit variant may also be written qualified,
`Tok.End`; an unknown one is E0114. A payload variant can't be qualified: `Tok.Num(1)` is
read as a method call (E0115 "type Tok has no method `Num`").

```eider,compile_fail=E0107
type Color = | Red | Green
type Light = | Red | Off

fn main() {}
```

`Option[T]` and `Result[T, E]` are enums of the prelude (core/prelude.ei); their variants
`Some`, `None`, `Ok` and `Err` are in scope everywhere. See [Types](types.md).

## Generic types

Records and enums may take type parameters: `type Pair[A, B] = { first: A, second: B }`,
`type Tree[T] = | Leaf | Node(Box[Tree[T]], T, Box[Tree[T]])`. The type arguments of a
construction are inferred from the values, or from the expected type when the values don't
fix them (`let t: Tree[i32] = Leaf`; E0409 otherwise). Type parameters of a type
declaration can't have bounds (E0001 "type parameters can't have bounds on a type
declaration; put them on impls and functions").

```eider
type Pair[A, B] = { first: A, second: B }

impl[A, B] Pair[A, B] {
    fn swap(self) -> Pair[B, A] { Pair(self.second, self.first) }
}

fn main() uses io {
    print(Pair(1, "one").swap())
}
```

```output
Pair { first: "one", second: 1 }
```

## Type aliases

`type Name = T` (where `T` doesn't start with `{` or `|`) declares another name for a type,
optionally generic: `type Table[T] = List[(String, T)]`. An alias is transparent: it is the
same type as `T` everywhere. An alias is not a constructor and an `impl` can't name it
(E0111 "`Id` is a type alias; an impl names the type itself"). See
[Types](types.md#type-aliases).

## Traits

```text
trait_item = "trait" name "{" {fn_signature} "}"
```

A trait declares method signatures that types implement. See
[Traits and generics](traits.md).

## Impls

```text
impl_item = "impl" [generics] type "{" {fn_item} "}"
          | "impl" [generics] trait_name ["[" type "]"] "for" type "{" {fn_item} "}"
```

An *inherent* impl adds methods and associated functions to a type; a *trait impl*
implements a trait for it. Generic impls declare their type parameters after `impl`:
`impl[T] Stack[T] { ... }`, `impl[T: Show] Show for Tagged[T] { ... }`. An impl for one
instance (`impl W[i32] { ... }`) applies to that instance only.

Inside an impl, `Self` names the impl's type. A method is called with `value.name(args)`,
an associated function with `Type.name(args)`; calling an associated function on a value is
E0115 ("`C.zero` is an associated function; call it as `Type.zero(...)`").

```eider
type Counter = { n: i32 }

impl Counter {
    fn new() -> Self { Counter(0) }
    fn get(self) -> i32 { self.n }
    fn inc(inout self) { self.n += 1 }
}

fn main() uses io {
    let mut c = Counter.new()
    c.inc()
    c.inc()
    print(c.get())
}
```

```output
2
```

A method that takes `inout self` needs a writable receiver (E0303). Rules for impls:

- A name defined in two inherent impls of one type, or twice for one trait, is E0107
  ("method `go` is already defined for `T`"), and so is the same trait implemented twice. An
  inherent method and a trait's, or two traits' methods, of one name can coexist: a call
  picks the type's own, and `Trait.go(x)` names the trait (see
  [Traits and generics](traits.md#calling-a-method-by-its-trait)); two traits tie in E0119.
- `pub` doesn't apply to an impl (E0001); methods are visible wherever their type is.
- The impl's type must exist (E0111) and can't be an alias (E0111).
- Built-in types take impls too: `impl String`, `impl i32`, `impl[T] List[T]`,
  `impl Map[K, V]`, `impl Box[T]`, and so on. A method with the name of a built-in method of
  that type (`len` on String, `push` on List) is E0116, since the built-in one would always
  be found first. Trait impls of the operation traits on built-in types are refused by the
  orphan rule (E0604, see [Traits and generics](traits.md#the-orphan-rule)).

```eider
impl[T] List[T] {
    fn second(self) -> Option[T] {
        if self.len() > 1 { Some(self[1]) } else { None }
    }
}

impl i32 {
    fn double(self) -> i32 { self * 2 }
}

fn main() uses io {
    let mut xs: List[i32] = List.new()
    xs.push(4)
    xs.push(5)
    print(xs.second())
    print(21.double())
}
```

```output
Some(5)
42
```

```eider,compile_fail=E0116
impl String {
    fn len(self) -> usize { 0 }
}

fn main() {}
```

When a value has both a method and a field of function type with one name, `x.f(...)`
calls the method; see [Expressions](expressions.md).

## Constants

```text
const_item = "const" name ":" type "=" ["comptime"] expr
```

A constant has an explicit type, which must be an integer type, `bool` or `str`, and an
initializer that is a literal or an integer expression the compiler can fold (arithmetic,
bitwise operators, casts and earlier constants). The value is computed at compile time:
overflow is an error there (E0501), as is a constant shift count out of range (E0505).

```eider
const WIDTH: i32 = 2
const AREA: i32 = WIDTH * (1 << 4)
const NAME: str = "eider"
const DEBUG: bool = false
const MASK: u64 = 0xffff_ffff

fn main() uses io {
    print(AREA)
    print(NAME)
    print(MASK)
}
```

```output
32
eider
4294967295
```

- A constant that names another constant must come after it in the file (E0110 "unknown
  name"); functions may use constants declared anywhere.
- A type that owns heap memory (`String`, `List`, `Map`, `Box`, records holding them) can't
  be a constant's type (E0504 "constants can't own heap memory; build the value in a
  function instead"); any other initializer than a literal or folded integer expression (a
  call, a tuple, a record) is E0504 too.

```eider,compile_fail=E0504
fn two() -> i32 { 2 }
const X: i32 = two()

fn main() {}
```

```eider,compile_fail=E0501
const X: u8 = 200 + 100

fn main() {}
```

`const X: T = comptime expr` evaluates any expression of an integer or `bool` type by
running it at compile time. See [Compile-time evaluation](comptime.md).

## Visibility: `pub`

Items are private to their module (file). `pub` before `fn`, `type`, `const`, `trait`,
`extern` or `unsafe fn` makes the item visible to modules that import this one; an `export
fn` is always public. Using a private item of another module is E0801 ("mark it `pub` in its
own file to use it from other modules"). Methods have the visibility of their type; `pub`
doesn't apply to `impl` or `test` (E0001).

```eider,compile_fail=E0801
import std.strings

fn main() {
    let s = strings.empty()
}
```

See [Modules and packages](modules.md).

## Tests

```text
test_item = "test" string block
```

A `test` block is a named unit test. `eiderc test file.ei` builds the program in test mode
and runs every test block of the entry module in order, printing `test <name> ... ok` or
`FAILED` with the trap message, then `<n> tests, <k> failed`; it exits 1 if any failed.
`eiderc run` and `eiderc build` leave test blocks out. A test body may use every capability
without declaring it. `assert cond` (message `assertion failed`) and `assert cond,
"message"` trap when `cond` is false; any other trap fails the test too. `assert` is an
ordinary statement and works outside tests as well (see [Statements](statements.md)).

```eider
fn add(a: i32, b: i32) -> i32 { a + b }

test "adds" {
    assert add(1, 2) == 3
    assert add(-1, 1) == 0, "inverse"
    print("tests may print")
}

fn main() uses io {
    print(add(2, 2))
}
```

```output
4
```

A test run of that file prints:

```text
test adds ... tests may print
ok

1 tests, 0 failed
```

The program still needs a `main` (E0112) for `eiderc test`.

## The `main` function

Every program has a function `fn main()`, taking no parameters and returning `()`, `i32` (the
exit code) or `Result[(), E]`. A missing `main` is E0112 ("no `main` function"); another
signature is E0111. Libraries built with `--lib` or `--wasm` have no `main`. See
[Runtime behaviour](runtime.md).

```eider,compile_fail=E0111
fn main() -> bool { true }
```

## C interop items

`extern "c" fn name(params) -> T` declares a C function (no body); `export fn` makes a
function callable from C; `unsafe fn` declares a function that may only be called inside
`unsafe { }` or another `unsafe fn` (E0802). See [C interop](ffi.md).

```eider,compile_fail=E0802
unsafe fn raw() -> i32 { 1 }

fn main() uses io {
    print(raw())
}
```

## Attributes

`attr name { key: type = default, ... }` declares an attribute, which is also a record type,
and `@name(key = value)` before an item or field attaches one. They are inert data that
[comptime reflection](reflection.md) reads. See [Attributes](attributes.md).

## Imports and module lines

`import a.b`, `import a.b as name` and `import a.{b, c as d}` bring another module's public
items into scope under a qualifier (`b.Item`, `name.Item`), and `import std` the toolchain's
namespace (`std.b.Item`). They are items like the others and may appear anywhere at
the top level. See [Modules and packages](modules.md).

`module a.b.c` (a dotted name) is accepted at the top level and has no effect.

## Names and order

All items of a module share one namespace for functions, constants and variant names, and
one for types and traits; a name defined twice in one of them is E0107 ("`f` is already
defined"). Items can be used before they are declared, except constants in other constants'
initializers (above):

```eider
fn main() uses io {
    print(Line(Pt(0, 0), Pt(1, 1)))
    print(later())
}

type Line = { a: Pt, b: Pt }
type Pt = { x: i32, y: i32 }

fn later() -> str { "declared after main" }
```

```output
Line { a: Pt { x: 0, y: 0 }, b: Pt { x: 1, y: 1 } }
declared after main
```

```eider,compile_fail=E0107
fn f() {}
fn f() {}

fn main() {}
```
