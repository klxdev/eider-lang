# Traits and generics

A *trait* is a named set of method signatures. Types implement traits in `impl` blocks;
generic functions, types and impls take type parameters whose *bounds* say which traits
they need. Every operation the language performs on values (copying, equality, ordering,
hashing, printing, iteration, cleanup, default values, error conversion) is a trait of the
prelude, derived automatically for ordinary types. Dispatch is static: generic code is
compiled once per set of type arguments (monomorphization).

> **Note:** There are no trait objects (`dyn Trait`) and no associated types yet; a trait
> is only usable as a bound. Both are planned: see the [roadmap](../../design/roadmap.md)
> (P0.7).

## Declaring a trait

```text
trait_item = ["pub"] "trait" name "{" {fn_signature | fn_item} "}"
```

A trait lists method signatures, and a method may have a body: a default. A method takes `self` (read-only receiver), `inout self`
(a receiver it changes) or no receiver (an associated function, called on a type). `Self`
in a signature stands for the implementing type.

```eider
trait Shape {
    fn area(self) -> i32
    fn name(self) -> str
    fn unit() -> Self
}

type Square = { side: i32 }

impl Shape for Square {
    fn area(self) -> i32 { self.side * self.side }
    fn name(self) -> str { "square" }
    fn unit() -> Square { Square(1) }
}

fn main() uses io {
    let s = Square(3)
    print(s.area())
    print(s.name())
    print(Square.unit().area())
}
```

```output
9
square
1
```

Rules for a trait impl, all E0602:

- every method of the trait without a default is implemented ("impl of `Area` is missing
  method `area`");
- each has exactly the trait's signature, with `Self` replaced by the type ("method `area`
  doesn't match the signature in trait `Area`");
- the impl adds no other methods ("trait `Area` has no method `other`").

An unknown trait name (in an impl or a bound) is E0603. A type implements a trait at most
once (E0107), and a method name is defined once per type within one trait's impl or its
inherent impls (E0107 "method `go` is already defined for `T`"). Two traits, or a trait and
the type itself, may each define a method of the same name: see
[Calling a method by its trait](#calling-a-method-by-its-trait).

```eider,compile_fail=E0602
trait Area { fn area(self) -> i32 }

type Sq = { s: i32 }

impl Area for Sq {}

fn main() {}
```

**Default methods.** A trait method with a body is inherited by every impl that doesn't
define it, and an impl that does overrides it (with the same signature, E0602 otherwise). The
body is the trait's: its names are those of the trait's module, `self` and `Self` are the
implementing type, and it can call the trait's other methods. It is checked for each type that
inherits it, like a generic function, so a default no impl inherits isn't checked. A method
of the type itself (of the type, or another trait's) with the same name wins over an
inherited default, which is then never called on that type.

```eider
trait Greet {
    fn name(self) -> String
    fn hello(self) -> String { "hello, {self.name()}" }
    fn twice(self) -> String {
        let h = self.hello()
        "{h} {h}"
    }
}

type En = { who: str }
type Fr = { who: str }

impl Greet for En {
    fn name(self) -> String { String.from(self.who) }
}

impl Greet for Fr {
    fn name(self) -> String { String.from(self.who) }
    fn hello(self) -> String { "bonjour, {self.name()}" }
}

fn main() uses io {
    print(En("Ada").twice())
    print(Fr("Zoe").twice())
}
```

```output
hello, Ada hello, Ada
bonjour, Zoe bonjour, Zoe
```

A trait method's `uses` clause is not part of the signature that is compared. Capabilities
are checked at each call with the concrete type: calling a method whose impl declares
`uses io` needs `io` in the caller, also through a generic function (the instance for that
type then needs it; see [Capabilities](capabilities.md)).

**Derived traits.** A trait declared `@derive` gives its methods to every record and enum
that has no impl of it, with the trait's default bodies, which usually go over the type's own
fields or variants with [comptime reflection](reflection.md) (`Self` is then the record or
enum, `is_enum_type[Self]` tells the two apart). This is how a library derives a codec, a printer
or a comparison without macros: it is ordinary generic code, instantiated per type.

```eider
@derive
trait Describe {
    fn describe(self, inout out: String) {
        comptime if is_enum_type[Self] {
            comptime for v in variants(Self) {
                if v.matches(self) { out.push_str(v.name) }
            }
        } else {
            out.push_str("{{")
            comptime for f in fields(Self) {
                out.push_str(f.name)
                out.push_str("=")
                self.[f].describe(inout out)
                out.push_str(" ")
            }
            out.push_str("}}")
        }
    }
}

impl Describe for i32 {
    fn describe(self, inout out: String) { out.append(String.from_int(self as i64)) }
}

type Point = { x: i32, y: i32 }
type Light = | Red | Green
type Pole = { at: Point, state: Light }

// the type's own package can still implement the trait
type Tag = { id: i32 }

impl Describe for Tag {
    fn describe(self, inout out: String) { out.push_str("#tag") }
}

fn show[T: Describe](x: T) -> String {
    let mut out = String.from("")
    x.describe(inout out)
    out
}

fn main() uses io {
    print(show(Pole(Point(1, 2), Light.Green)))
    print(show(Tag(5)))
}
```

```output
{at={x=1 y=2 } state=Green }
#tag
```

A type has the trait by derivation only when no impl of the trait names its type (any
`impl[T] Describe for Wrapper[T]` counts), and only a record or an enum does: integers,
`String`, `List` and the like need an impl, which the library provides. A part that lacks the
trait is an error where the default body uses it, and the help names the field: "in the
`comptime for` iteration over field `n` of Cache". `@derive` takes no keys and goes only on a
trait (E0820 elsewhere unless an `attr` of that name exists). The derived methods are the
trait's defaults checked for the type, so they cost what generic instantiation costs and
nothing more.

## Calling a method by its trait

A type may have several methods of one name: its own, and one from each trait it implements.
`value.name()` calls the type's own method if it has one, else the trait's, or the trait's
default only when no other method has the name. When two traits tie, the call is ambiguous
(E0119). `Trait.name(value, args)` names the trait, so it calls that trait's method (or its
default) whatever else the type has; the first argument is the receiver, written as it would
be before the dot (`inout x` when the method takes `inout self`). It works for a trait of
another module (`time.Clock.sleep(c, d)`) and for the language traits (`Show.show(x, inout
out)`), and inside a generic function it is how a bound says which trait it means.

```eider
trait Greeter { fn hello(self) -> str }
trait Waver { fn hello(self) -> str }

type Dog = { name: str }

impl Dog {
    fn hello(self) -> str { "own" }
}
impl Greeter for Dog {
    fn hello(self) -> str { "greeter" }
}
impl Waver for Dog {
    fn hello(self) -> str { "waver" }
}

type Cat = { n: i32 }
impl Greeter for Cat {
    fn hello(self) -> str { "cat greeter" }
}
impl Waver for Cat {
    fn hello(self) -> str { "cat waver" }
}

fn main() uses io {
    let d = Dog("rex")
    print(d.hello())
    print(Greeter.hello(d))
    print(Waver.hello(d))
    let c = Cat(1)
    print(Greeter.hello(c))
    print(Waver.hello(c))
}
```

```output
own
greeter
waver
cat greeter
cat waver
```

Without the type's own method, `c.hello()` is E0119; the help names the way out.

```eider,compile_fail=E0119
trait Greeter { fn hello(self) -> str }
trait Waver { fn hello(self) -> str }
type Cat = { n: i32 }
impl Greeter for Cat { fn hello(self) -> str { "g" } }
impl Waver for Cat { fn hello(self) -> str { "w" } }
fn main() uses io {
    let c = Cat(1)
    print(c.hello())
}
```

Fix: `print(Greeter.hello(c))`.

`Trait.name(...)` needs a method with `self` (E0115 for an associated function: call those on
a type, `Type.name()`, where two traits' functions of one name stay ambiguous), a first
argument (E0405), a type that implements the trait (E0115), and `inout` exactly where the
method's `self` is (E0304).

A trait is not a type: `fn f(x: Shape)` is E0111 ("unknown type `Shape`").

User-declared traits take no type arguments (`impl Shape[i32] for X` is E0603); only the
prelude's `From` does (see [From](#from-and-)).

## Generics

Functions, methods, records, enums, aliases and impls can have type parameters, written in
brackets after the name (after `impl` for impls):

```eider
type Stack[T] = { items: List[T] }

impl[T] Stack[T] {
    fn push(inout self, x: T) { self.items.push(x) }
    fn top(self) -> Option[T] {
        let n = self.items.len()
        if n == 0 { None } else { Some(self.items[n - 1]) }
    }
    fn map[U](self, f: fn(T) -> U) -> Stack[U] {
        let mut out: List[U] = List.new()
        for x in self.items { out.push(f(x)) }
        Stack(out)
    }
}

fn largest[T: Ord](a: T, b: T) -> T {
    if a > b { a } else { b }
}

fn main() uses io {
    let mut s: Stack[i32] = Stack(List.new())
    s.push(1)
    s.push(2)
    print(s.top())
    print(s.map(|x| x * 10).top())
    print(largest("pear", "apple"))
}
```

```output
Some(2)
Some(20)
pear
```

### Bounds

`T: A` requires T to implement trait A; `T: A + B` requires both. Bounds are written on the
type parameters of functions, methods and impls (not on type declarations, E0001). A trait
of another module is named qualified: `T: geo.Area`.

A generic body may use an operation on a value of type `T` only when T's bounds promise
it; otherwise it is E0605, with a fix that adds the bound:

| Operation in a generic body | Needs |
|---|---|
| `==`, `!=`, `x.eq(y)`, `List[T].contains` | `T: Eq` |
| `<`, `<=`, `>`, `>=`, `x.compare(y)` | `T: Ord` |
| `print(x)`, `x.show(inout s)`, `x.to_string()` | `T: Show` |
| `x.hash()` | `T: Hash` |
| `Map[T, V]` (also in a signature) | `T: Hash + Eq` |
| `x.copy()` | `T: Copy` |
| `for v in x` | `T: Iter` |
| `T.default()`, `x.take()` | `T: Default` |
| a method or associated function of trait `A` | `T: A` |
| calling a function whose parameter has bound `A` | `T: A` |

`Ord` and `Hash` also promise `Eq`, so `T: Ord` allows `==`.

```eider,compile_fail=E0605
fn same[T](a: T, b: T) -> bool { a == b }

fn main() uses io { print(same(1, 2)) }
```

At a call, each type argument must implement its bounds (E0601 "type i32 doesn't implement
trait `Area` (required by `total`)").

```eider,compile_fail=E0601
trait Area { fn area(self) -> i32 }

fn total[T: Area](x: T) -> i32 { x.area() }

fn main() uses io { print(total(5)) }
```

A generic impl with bounds applies only to the instances that meet them:
`impl[T: Eq] Desc for W[T]` gives `desc` to `W[i32]` but not to `W[fn(i32) -> i32]`
(E0601 at the call). An impl for one instance, `impl W[i32] { ... }`, applies to `W[i32]`
only (E0115 on `W(true).twice()`).

Associated functions of a type parameter are called on the parameter, `T.make()`, which
needs a bound providing them:

```eider
trait Zero { fn zero() -> Self }

type Money = { cents: i64 }

impl Zero for Money { fn zero() -> Money { Money(0) } }

fn zeros[T: Zero](n: i32) -> List[T] {
    let mut out: List[T] = List.new()
    for i in 0..n { out.push(T.zero()) }
    out
}

fn main() uses io {
    let xs: List[Money] = zeros(2)
    print(xs)
}
```

```output
[Money { cents: 0 }, Money { cents: 0 }]
```

### Inference

Type arguments are never written at a call (`make[i32]()` is a syntax error); they are
inferred in a fixed order: from the expected type of the call (an annotated `let`, a
parameter, a return type), then the receiver of a method call, then the arguments left to
right. A type parameter that none of them fixes is E0409 ("cannot infer type parameter `T`
of `make`"), whose help says to annotate the binding:

```eider,compile_fail=E0409
fn make[T]() -> List[T] { List.new() }

fn main() {
    let ys = make()
}
```

```eider
fn make[T]() -> List[T] { List.new() }

fn main() uses io {
    let ys: List[i32] = make()
    print(ys.len())
}
```

```output
0
```

A type argument must match exactly: there are no implicit conversions, and an array
`[1, 2]` is not a `List` (E0401 "argument of type [i32; 2] doesn't match parameter type
`List[T]`").

### Monomorphization

Each generic function, method and type is instantiated once per distinct list of type
arguments the program uses (`largest[str]`, `Stack[i32]`), and each instance is checked and
compiled with the concrete types. Consequences:

- Calls are static; generic code costs what the hand-written concrete code would.
- A generic declaration that is never instantiated is not checked beyond its signature.
- Errors inside a generic body are reported once, for the first instance that has them;
  the bounds check (E0605) is a separate pass over each instantiated generic declaration,
  reported after the program's other errors.

## The operation traits

The prelude (core/prelude.ei) declares these traits; their names, and `Ordering` with its
variants `Less`, `Equal`, `Greater`, are in scope in every module:

```eider,ignore
type Ordering = | Less | Equal | Greater

trait Copy { fn copy(self) -> Self }
trait Eq { fn eq(self, other: Self) -> bool }
trait Ord { fn compare(self, other: Self) -> Ordering }
trait Hash { fn hash(self) -> u64 }
trait Show { fn show(self, inout out: String) }
trait Iter { fn next(inout self) -> Option[Item] }
trait Drop { fn drop(inout self) }
trait From { fn from(value: Source) -> Self }
trait Default { fn default() -> Self }
```

(Shown, not tested: this is the prelude's own text. `Item` and `Source` are placeholders read
off each impl, since there are no associated types.)

| Operation | Trait |
|---|---|
| `x.copy()` | Copy |
| `==`, `!=`, `x.eq(y)`, `List.contains` | Eq |
| `<`, `<=`, `>`, `>=`, `x.compare(y)` | Ord |
| Map keys, `x.hash()` | Hash (and Eq) |
| `print(x)`, `x.to_string()`, `x.show(inout s)` | Show |
| `for v in x` | Iter |
| cleanup when the last holder of a value goes | Drop |
| `?` converting an error type | From |
| `T.default()`, `x.take()` | Default |

Arithmetic and bitwise operators are not traits: they work on integers only, and there is
no operator overloading.

### Which types have which trait

A record, enum, tuple, array, List or Box has a trait when all its parts have it: the trait
is *derived*, with no annotation and no way to opt out. A type lacks a trait only when one
of its parts does, which is how handles like `Chan` keep anything that holds them from
being copied.

| Type | Copy | Eq | Ord | Hash | Show | Iter | Default |
|---|---|---|---|---|---|---|---|
| integers, `bool`, `str`, `String` | yes | yes | yes | yes | yes | | yes (`0`, `false`, `""`) |
| `()` | yes | as a part | as a part | as a part | yes | | yes |
| records, tuples, arrays, Box | derived | derived | derived | derived | derived | arrays | derived |
| enums | derived | derived | derived | derived | derived | | own impl only |
| `Option[T]` | derived | derived | derived | derived | derived | | `None` |
| `Result[T, E]` | derived | derived | derived | derived | derived | | none |
| `List[T]` | derived | derived | derived | derived | derived | yes | empty |
| `Map[K, V]` | derived | if V | no | no | if K, V | | empty |
| fn values | yes | no | no | no | no | | no |
| `Mutex[T]` | if T | no | no | no | no | | no |
| `Ref[T]` | if T | no | no | no | no | | no |
| `Task[T]`, `Chan[T]` | no | no | no | no | no | | no |

Drop is never derived: a record has it only through its own impl. Comparing two `()`
values directly is E0401 ("cannot compare values of type ()").

An operation on a type that lacks the trait names the part responsible:

```eider,compile_fail=E0601
type Job = { id: i32, done: Chan[bool] }

fn main() {
    let c: Chan[bool] = Chan.new()
    let j = Job(1, c)
    let k = j.copy()
}
```

(E0601 "type Job doesn't implement trait `Copy` (required by `.copy()`): its part Chan[bool]
doesn't"; `==` on such a type is E0401 with the same explanation.)

### Own impls

The package that defines a record or enum may implement any of these traits for it; the
impl replaces the derived one everywhere: in the operator, in method calls, and inside the
derived operations of every type that contains it (`==` on a `List[Name]` uses Name's own
`eq`, printing a `List[Job]` uses Job's own `show`).

```eider
type Job = { id: i32, priority: i32 }

impl Show for Job {
    fn show(self, inout out: String) {
        out.push_str("#")
        out.append(self.id.to_string())
    }
}

impl Ord for Job {
    fn compare(self, other: Job) -> Ordering { other.priority.compare(self.priority) }
}

fn main() uses io {
    let a = Job(1, 5)
    let b = Job(2, 9)
    print([a, b])
    print(b < a)
    print(Some(a).to_string())
}
```

```output
[#1, #2]
true
Some(#1)
```

An own `Ord` or `Hash` on a type that has no `Eq` is E0601 (they promise `Eq`).

### Copy

`x.copy()` returns an independent value. Heap buffers are shared copy-on-write, so it costs
a count increment until one side is written; a `Mutex` or `Ref` inside is copied into a new
one holding a copy of the contents; a part with its own `copy` is copied by it. Implicit
copies (binding a fresh value, passing, storing, returning) never run user code. See
[Memory model](memory.md).

```eider
type Img = { id: i32 }

impl Copy for Img {
    fn copy(self) -> Img { Img(self.id + 100) }
}

fn main() uses io {
    let a = Img(1)
    print(a.copy())
    let mut xs: List[i32] = List.new()
    xs.push(1)
    let mut ys = xs.copy()
    ys.push(2)
    print(xs)
    print(ys)
}
```

```output
Img { id: 101 }
[1]
[1, 2]
```

### Eq, Ord and Ordering

Derived equality is structural. Two Maps are equal when they have the same keys, each with
an equal value, whatever the insertion order. Derived order: integers by value,
`false < true`, `str` and `String` by bytes (Unicode scalar order), records and tuples
field by field, arrays and Lists element by element and then by length, Box by its
contents, enums by variant order and then payload. Maps have no order.

`x.compare(y)` returns an `Ordering`:

```eider
type Shape = | Dot | Circle(i32)

fn main() uses io {
    print(1.compare(2))
    print("b".compare("a"))
    print(Dot < Circle(0))
    print(Circle(1) < Circle(2))
    print((1, "b") < (1, "c"))
}
```

```output
Less
Greater
true
true
true
```

### Hash and Map keys

A Map key type needs `Hash` and `Eq` (E0701 otherwise, naming the part that lacks one).
Equal keys must hash alike, so a key type with its own `Eq` but a derived `Hash` is E0701
("Name has its own `Eq` but a derived `Hash`"): implement both.

```eider
type Name = { text: String, note: i32 }

impl Eq for Name {
    fn eq(self, other: Name) -> bool { self.text == other.text }
}

impl Hash for Name {
    fn hash(self) -> u64 { self.text.hash() }
}

fn main() uses io {
    let mut m: Map[Name, i32] = Map.new()
    m.insert(Name(String.from("x"), 1), 10)
    print(m.get(Name(String.from("x"), 2)))
}
```

```output
Some(10)
```

```eider,compile_fail=E0701
type Name = { text: String, note: i32 }

impl Eq for Name {
    fn eq(self, other: Name) -> bool { self.text == other.text }
}

fn main() {
    let m: Map[Name, i32] = Map.new()
}
```

### Show

`show` appends a value's text to a String; `print(x)` and `x.to_string()` go through it.
Integers, `bool`, `str` and `String` print as themselves, unit variants by name. The rest is
derived:

| Value | Text |
|---|---|
| record | `P { x: 1, y: -2 }` |
| variant with payload | `Circle(3)`, `Op("+", 1)` |
| tuple | `(1, "one", true)`, `(5,)` |
| array, List | `[1, 2]` |
| Map | `{"k": 1}` (in slot order) |
| Box | `Box(3)` |
| unit | `()` |

Text inside another value is quoted, with `\"`, `\\`, `\n`, `\t` and `\r` escaped; on its
own it is printed raw. Type and variant names are spelled as their module writes them.

```eider
type P = { x: i32, label: str }

fn main() uses io {
    print(P(1, "a\"b"))
    print(Some((5,)))
    let r: Result[(), str] = Ok(())
    print(r)
    print(Box.new([1, 2]))
    print("raw\ttext")
}
```

```output
P { x: 1, label: "a\"b" }
Some((5,))
Ok(())
Box([1, 2])
raw	text
```

### Iter

`for x in e` over a type with its own `Iter` runs on a copy of `e` owned by the loop (the
original is unchanged), calling `next` until it returns `None`. The item type is whatever
the impl's `next` returns inside `Option`; a `next` that returns anything else is E0602.
Ranges, Lists, arrays and Maps have built-in loops. See [Statements](statements.md).

```eider
type Countdown = { n: i32 }

impl Iter for Countdown {
    fn next(inout self) -> Option[i32] {
        if self.n == 0 { return None }
        self.n -= 1
        Some(self.n + 1)
    }
}

fn main() uses io {
    let c = Countdown(3)
    for x in c { print(x) }
    print(c.n)
}
```

```output
3
2
1
3
```

### Drop

A record's own `drop` runs exactly once per value, when its last holder goes (copies made
by binding and passing share one value). Then its fields are dropped in declaration order.
Values of one scope are dropped in reverse order of creation. Rules (E0606 otherwise):

- `Drop` is for records only, and for all instances of a generic record: `impl[T] Drop for
  R[T]`, with no bounds (`impl Drop for G[i32]` and `impl Drop for SomeEnum` don't qualify);
- `drop` can't declare capabilities, because it runs wherever the last holder goes;
- `x.drop()` can't be called (E0115).

A record with its own Drop has no derived `Default`, and can't cross the C boundary
(E0803). Writing to a shared value of such a record first makes a copy of its own (through
its own `Copy`, if it has one); from then on there are two values, each dropped once.

```eider
type Res = { name: str, log: Ref[List[str]] }

impl Drop for Res {
    fn drop(inout self) {
        let n = self.name
        self.log.update(|inout l| l.push(n))
    }
}

fn work(log: Ref[List[str]]) {
    let a = Res("a", log)
    let b = Res("b", log)
    let c = b
}

fn main() uses io {
    let log: Ref[List[str]] = Ref.new(List.new())
    work(log)
    print(log.get())
}
```

```output
["b", "a"]
```

```eider,compile_fail=E0606
type File = { name: String }

impl Drop for File {
    fn drop(inout self) uses io { print(self.name) }
}

fn main() {}
```

### Default

`T.default()` makes a type's default value: `0`, `false`, `""`, `()`, an empty List or Map,
`None`, and for records, tuples, arrays and Box each part's default. Other enums (and
`Result`) have one only through an own `impl Default`, since which variant is the default is
a choice; a record with its own Drop has none (a resource isn't made from nothing). A type
without one is E0601 at the call. `x.default()` is not a call (E0115): `default` is an
associated function.

`x.take()` moves the value out of the writable place `x` and leaves `T.default()` behind;
`x.replace(v)` works for every type. See [Memory model](memory.md).

```eider
type Level = | Low | High

impl Default for Level { fn default() -> Level { High } }

type Cfg = { port: u32, name: String, tags: List[str], level: Level, extra: Option[i32] }

fn fresh[T: Default]() -> T { T.default() }

fn main() uses io {
    print(Cfg.default())
    let n: i64 = fresh()
    print(n)
    let mut c = Cfg(80, String.from("web"), List.new(), Low, Some(1))
    let old = c.take()
    print(old.port)
    print(c.port)
}
```

```output
Cfg { port: 0, name: "", tags: [], level: High, extra: None }
0
80
0
```

```eider,compile_fail=E0601
type Level = | Low | High

fn main() uses io { print(Level.default()) }
```

### From and `?`

`impl From[E1] for E2 { fn from(value: E1) -> E2 { ... } }` converts E1 into E2. In a
function returning `Result[T, E2]`, `x?` on a `Result[T1, E1]` returns `Err(E2.from(e))`.
Without an impl it is E0401 ("`?` can't convert the error type A into B"). A type may
convert from several sources, one impl each (E0107 for a second impl of one source).
`E2.from(x)` calls the conversion directly, chosen by the argument's type.

- `from` has exactly the signature `fn from(value: Source) -> Target` (E0602) and declares
  no capabilities (E0602);
- `impl From for X` without the source type is E0603;
- the orphan rule applies to the target (E0604); the source may be any type.

```eider
type IoError = { code: i32 }

type AppError = | Io(i32) | Parse(String)

impl From[IoError] for AppError {
    fn from(value: IoError) -> AppError { Io(value.code) }
}

fn read() -> Result[i32, IoError] { Err(IoError(5)) }

fn run() -> Result[i32, AppError] {
    let n = read()?
    Ok(n + 1)
}

fn main() uses io {
    print(run())
    print(AppError.from(IoError(7)))
}
```

```output
Err(Io(5))
Io(7)
```

There is no `Into` and no blanket conversion. The standard library's
[std/error](api:std/error) builds error chains on this: a type implements `error.Error`
(`message` and `source`), `.context("...")` wraps any such error into an `error.Failure`,
and `?` converts every `Error` into a `Failure`. The standard library's own errors are
`Error`s: `String` (std/error implements the trait for it, so the `Result[T, String]` of
std/fs, std/io and std/proc take `.context` as they are), `stream.Error`,
`strings.ParseError` and `encoding.DecodeError`.

```eider
import std.error

type ParseError = { line: u32, what: String }

impl error.Error for ParseError {
    fn message(self) -> String { self.what.copy() }
    fn source(self) -> Option[error.Failure] { None }
}

fn parse_port(text: str) -> Result[u32, ParseError] {
    if text == "80" { Ok(80) } else { Err(ParseError(1, String.from("expected a number"))) }
}

fn settings(text: str) -> Result[u32, error.Failure] {
    let port = parse_port(text).context("parsing the config")?
    Ok(port)
}

fn main() uses io {
    print(settings("80"))
    match settings("x") {
        Ok(_) => {}
        Err(f) => print(f)
    }
}
```

```output
Ok(80)
parsing the config: expected a number
```

## The orphan rule

An impl of a prelude trait (the operation traits and `From`) is allowed only in the package
that defines the type (for `From`, the target type). Files that are in no package count as
one package, the program's own. Anything else is E0604: a built-in type ("it is defined by
the language core"), a prelude type such as `Option`, `Result` or `Ordering`, a type of
another package, or a type parameter (`impl[T] Eq for T`). So a type's behaviour never
depends on which modules are imported. To add behaviour to a foreign type, wrap it in a
record of your own.

```eider,compile_fail=E0604
impl Show for i32 {
    fn show(self, inout out: String) {}
}

fn main() {}
```

User-declared traits have no orphan rule: `impl MyTrait for i32` (or for `String`,
`List[T]`, a type of another package) is fine anywhere.

## Shadowing a language trait

A trait that the entry module declares with the name of a prelude trait shadows it in the
program's names: `trait Show { ... }` is then that program's own trait, and `impl Show for
bool` implements it. The language goes on using the prelude's trait for `print`, `==` and
the rest, and that program can no longer implement it.

```eider
trait Show { fn show(self) -> str }

impl Show for bool { fn show(self) -> str { "a bool" } }

fn main() uses io {
    print(true.show())
    print(true)
}
```

```output
a bool
true
```
