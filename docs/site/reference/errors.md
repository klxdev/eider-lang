# Error codes

Every error the compiler reports has a code. This page lists all of them, in the order the
compiler's own list (`diag.all_codes()` in `compiler/diag.ei`) gives them: what each one
means, every situation that raises it, a minimal program that triggers it, and the fix.

## Reading a diagnostic

`eiderc check`, `build`, `run` and `test` print each error with its code, its message, the
source line and a caret under the column (columns count Unicode scalar values), then a help
line or a machine-applicable fix when there is one, and finally a count:

```text
error[E0201]: call to `print` requires capability `io`
  --> main.ei:2:5
  |
2 |     print(1)
  |     ^
  fix: at 1:10 delete 0 insert " uses io"
error[E0401]: expected i32, found bool
  --> main.ei:3:18
  |
3 |     let x: i32 = true
  |                  ^
error: 2 errors
```

With `--json` each diagnostic is one JSON object per line on stdout, with the fix (if any)
as data an editor or tool can apply:

```json
{"error":"E0201","span":{"file":"main.ei","line":2,"col":5},"message":"call to `print` requires capability `io`","fix":{"at":{"line":1,"col":10},"delete":0,"insert":" uses io"}}
{"error":"E0401","span":{"file":"main.ei","line":3,"col":18},"message":"expected i32, found bool"}
```

- **Several errors per run.** Every independent error is reported, in the order found. The
  first one is always exactly what a compiler stopping at the first error would report; the
  rest follow. Consequences of an earlier error (a use of a name that failed to resolve, an
  expression of a type that failed) are not reported again.
- **`--max-errors N`** shows at most N diagnostics (default 100; `0` shows all). When some
  are left out, a final note says so: `note: only the first 1 of 2 errors are shown;
  `--max-errors N` shows N (0: all)` (with `--json`, a `{"note":"..."}` line).
- **Exit codes.** A program that doesn't compile exits with 1; nothing is built.
- **Fixes.** A `fix:` says: at line:col, delete that many bytes and insert the text. The
  compile-fail test runner (`eiderc test --compile-fail`) applies each fix and requires the
  result to compile, or to fail with a different error.

The codes are grouped by their first digits: `E00xx` syntax, `E01xx` names, types and
matches, `E02xx` capabilities, `E03xx` mutation, `inout` and references, `E04xx` type
checking, `E05xx` constants, `E06xx` traits, `E07xx` Map keys, `E08xx` modules, packages,
FFI, WebAssembly and comptime.

## E0001

A **syntax error**: the lexer or the parser can't read the text. The message says what was
expected. The lexer reports an unexpected character, an unterminated string literal or
block comment, an unknown or refused string escape (`\0`, `\x80`, `\u{d800}`, ...; see
[Lexical structure](lexical.md)), an integer literal that is too large or `0x` without
digits. The parser reports a missing token (`expected `)``, `expected `}``), a keyword
used as a name, a missing newline or `;` between two statements on one line, `pub` on a
`test` or an `impl`, bounds on a type declaration's parameters, an `extern "c"` function
with a body, and a call of something that isn't a name (`only named functions can be
called`). The checker also reports one E0001: an or-pattern (`A(x) | B(x)`) that binds
names.

```eider,compile_fail=E0001
fn main() uses io {
    let x = 1 let y = 2
    print(x + y)
}
```

Fix: put each statement on its own line, or separate them with `;`.

```eider
fn main() uses io {
    let x = 1; let y = 2
    print(x + y)
}
```

```output
3
```

## E0002

**Bitwise operators mixed without parentheses.** Eider doesn't rank `&`, `|`, `^`, `<<`
and `>>` against comparisons, arithmetic or each other, so an operand of one of them can't be
an unparenthesized operation of another group, and an operand of a comparison can't be an
unparenthesized `&`, `|` or `^`. A shift may be an operand of `& | ^`, a comparison may
compare shifts, and chains of one operator (`a | b | c`) are fine (see
[Expressions](expressions.md)). The compiler offers a machine-applicable fix that adds the
parentheses C and Rust would imply.

```eider,compile_fail=E0002
fn is_even(x: u32) -> bool {
    x & 1 == 0
}
fn main() uses io { print(is_even(4)) }
```

Fix (the one the compiler suggests):

```eider
fn is_even(x: u32) -> bool {
    (x & 1) == 0
}
fn main() uses io { print(is_even(4)) }
```

```output
true
```

## E0101

A **non-exhaustive match or refutable pattern**. Raised for a `match` that doesn't handle
every value (`non-exhaustive match: `Medium` is not handled`; integers, strings and other
open-ended types need a `_` arm), a `match` with no arms, and a pattern that can fail where
only an irrefutable one is allowed: in `let (...) = e` and in `for PATTERN in e`.

```eider,compile_fail=E0101
type Size = | Small | Medium | Large
fn limit(s: Size) -> u32 {
    match s {
        Small => 1
        Large => 3
    }
}
fn main() uses io { print(limit(Small)) }
```

Fix: add an arm for each missing case, or a `_` arm.

```eider
type Size = | Small | Medium | Large
fn limit(s: Size) -> u32 {
    match s {
        Small => 1
        Medium => 2
        Large => 3
    }
}
fn main() uses io { print(limit(Medium)) }
```

```output
2
```

## E0102

An **unreachable match arm**: everything the arm matches is already handled by the arms
above it (a repeated variant, a pattern after `_`, a literal already matched).

```eider,compile_fail=E0102
fn name(n: i32) -> str {
    match n {
        0 => "zero"
        _ => "many"
        1 => "one"
    }
}
fn main() uses io { print(name(1)) }
```

Fix: remove the arm, or move it above the arm that covers it.

```eider
fn name(n: i32) -> str {
    match n {
        0 => "zero"
        1 => "one"
        _ => "many"
    }
}
fn main() uses io { print(name(1)) }
```

```output
one
```

## E0103

**`if`, `match` or a block used inside a larger expression.** They are expressions, but
only in these positions: as a statement, as a function's (or block's) final expression, and
as the right side of `let`, `=` or `return`. Elsewhere (an operand of `+`, a call argument)
bind the result first.

```eider,compile_fail=E0103
fn sign(n: i32) -> i32 {
    return 10 * if n < 0 { -1 } else { 1 }
}
fn main() uses io { print(sign(-4)) }
```

Fix:

```eider
fn sign(n: i32) -> i32 {
    let s = if n < 0 { -1 } else { 1 }
    return 10 * s
}
fn main() uses io { print(sign(-4)) }
```

```output
-10
```

## E0107

A **duplicate definition**: two items with one name in a module (functions, types,
constants, traits), two fields of one record or variant, two variants with one name
(variant names must be unique across the enums of a module, since they are used without
the enum's name), a method defined twice for a type (inherent, or in impls of one trait) or in one impl, a trait implemented
twice for a type (`From` once per source type), and a loop label already used by an
enclosing loop.

```eider,compile_fail=E0107
type Light = | Red | Green
type Signal = | Red | Stop
fn main() {}
```

Fix: rename one of them.

```eider
type Light = | Red | Green
type Signal = | Halt | Stop
fn main() uses io {
    let l = Red
    print(l)
}
```

```output
Red
```

## E0108

A **type that contains itself by value**, directly or through other records, enums,
tuples or arrays, so it would have infinite size. Recursion goes through a heap type:
`Box[T]`, `List[T]`, `Map[K, V]` or `Option[Box[T]]`.

```eider,compile_fail=E0108
type Node = { value: i32, next: Option[Node] }
fn main() {}
```

Fix:

```eider
type Node = { value: i32, next: Option[Box[Node]] }
fn main() uses io {
    let n = Node(1, Some(Box.new(Node(2, None))))
    print(n.value)
}
```

```output
1
```

## E0110

An **unknown name** in an expression or a place: a variable, constant or function that
isn't in scope (`unknown name `total``). A function named without a call is reported as
"`f` is a function; call it with `f(...)`" when it can't be used as a value there.

```eider,compile_fail=E0110
fn main() uses io {
    let count = 3
    print(cuont)
}
```

Fix: spell the name as declared, or declare it before the use.

```eider
fn main() uses io {
    let count = 3
    print(count)
}
```

```output
3
```

## E0111

An **invalid type**. Raised for an unknown type name, an associated type (`T.Item`) that
the type has none of, a generic type without its type
arguments or with the wrong number of them, an array of length 0, a record with no fields,
`()` where a value type is needed (a parameter of type `()`, `List[()]`), a type alias that
refers to itself or names an unknown type, an `impl` that names an alias instead of the
type, and a `main` whose signature isn't one of `fn main()`, `fn main() -> i32` or
`fn main() -> Result[(), E]` (see [Runtime behaviour](runtime.md)).

```eider,compile_fail=E0111
fn total(xs: List) -> i32 {
    0
}
fn main() {}
```

Fix: give the type its arguments.

```eider
fn total(xs: List[i32]) -> i32 {
    let mut t = 0
    for x in xs { t += x }
    t
}
fn main() uses io {
    let mut xs: List[i32] = List.new()
    xs.push(1)
    xs.push(5)
    print(total(xs))
}
```

```output
6
```

## E0112

**Not a function**: a call of an unknown function (`unknown function `launch``), a call of
a value whose type isn't a function type, and a program without `main` (`no `main`
function`, reported at 1:1). A library (`--lib`) and a test build (`eiderc test`) need no
`main`.

```eider,compile_fail=E0112
fn main() uses io {
    print(sqaure(3))
}
fn square(n: i32) -> i32 { n * n }
```

Fix:

```eider
fn main() uses io {
    print(square(3))
}
fn square(n: i32) -> i32 { n * n }
```

```output
9
```

## E0113

An **unknown field**: `x.f` where the record has no field `f`, `t.3` past the end of a
tuple, or a field access on a type that has none.

```eider,compile_fail=E0113
type Point = { x: i32, y: i32 }
fn main() uses io {
    let p = Point(1, 2)
    print(p.z)
}
```

Fix:

```eider
type Point = { x: i32, y: i32 }
fn main() uses io {
    let p = Point(1, 2)
    print(p.y)
}
```

```output
2
```

## E0114

An **unknown variant**: `Enum.Variant` where the enum has no such variant, or a pattern
naming a variant or constructor the matched type doesn't have.

```eider,compile_fail=E0114
type Color = | Red | Green
fn main() uses io {
    let c = Color.Blue
    print(c)
}
```

Fix:

```eider
type Color = | Red | Green
fn main() uses io {
    let c = Color.Green
    print(c)
}
```

```output
Green
```

## E0115

**No such method or associated function**: `x.m()` where x's type has no method `m` (no
built-in one, no impl, no language-trait method), `T.f()` where T has no associated
function `f`, a call of an associated function as a method (`x.default()`), a call of
`.drop()` (it runs by itself), `x.take()` on a type without a `Default` value, and a method
of a thread handle or `Ref` that doesn't exist. A field that holds a function is called
like a method only when no method has its name.

```eider,compile_fail=E0115
fn main() uses io {
    let name = String.from("eider")
    print(name.length())
}
```

Fix:

```eider
fn main() uses io {
    let name = String.from("eider")
    print(name.len())
}
```

```output
5
```

## E0116

An **impl method named like a built-in method** of a built-in type (`len` on `String`,
`new` on `List`, `keys` on `Map`, ...): the built-in one is always found first, so the
method could never be called.

```eider,compile_fail=E0116
impl String {
    fn len(self) -> usize { 0 }
}
fn main() {}
```

Fix: give the method another name.

```eider
impl String {
    fn shout(self) -> String {
        let mut s = self.copy()
        s.push_str("!")
        s
    }
}
fn main() uses io { print(String.from("hi").shout()) }
```

```output
hi!
```

## E0117

**An or-pattern whose alternatives bind differently.** Every alternative of `p | q` binds the
same names with the same types, and not as `mut` (each binding holds a copy of the part that
matched).

```eider,compile_fail=E0117
type M = | A(x: i32) | B(y: i32)

fn f(m: M) -> i32 {
    match m {
        A(x) | B(y) => x
    }
}

fn main() {}
```

Fix: bind the same name in each alternative.

```eider
type M = | A(x: i32) | B(y: i32)

fn f(m: M) -> i32 {
    match m {
        A(v) | B(v) => v
    }
}

fn main() uses io { print(f(B(2))) }
```

```output
2
```

## E0118

**A range pattern that matches nothing:** its start is above its end.

```eider,compile_fail=E0118
fn f(n: i32) -> i32 {
    match n {
        9..=0 => 1
        _ => 0
    }
}

fn main() {}
```

Fix: write the smaller bound first, `0..=9`.

```eider
fn f(n: i32) -> i32 {
    match n {
        0..=9 => 1
        _ => 0
    }
}

fn main() uses io { print(f(5)) }
```

```output
1
```

## E0119

An **ambiguous method**: a type implements two traits that each define the method called
(or inherit a default of that name), and the type has no method of its own with the name.
`value.name()` can't tell which is meant. The help names the way out, calling the method by
its trait. (An associated function without `self` can't be called by its trait; rename one.)
The same code is raised for an associated type name (`X.Item`) that two traits implemented
for `X` both define.

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

Fix: name the trait.

```eider
trait Greeter { fn hello(self) -> str }
trait Waver { fn hello(self) -> str }
type Cat = { n: i32 }
impl Greeter for Cat { fn hello(self) -> str { "g" } }
impl Waver for Cat { fn hello(self) -> str { "w" } }
fn main() uses io {
    let c = Cat(1)
    print(Greeter.hello(c))
    print(Waver.hello(c))
}
```

```output
g
w
```

## E0201

A **missing capability**. A call to a function that `uses` a capability (`print` needs
`io`, `spawn` needs `threads`, an `extern "c"` function needs `ffi`) is allowed only in a
function that declares it too. Capabilities propagate up call chains; within a package
`ffi` does too, but not across a package boundary (see [Capabilities](capabilities.md)).
In a `comptime` initializer no capability is available at all (the help says so). The
compiler offers a machine-applicable fix that adds the capability to the enclosing
function's `uses` clause. Calling a fn value whose type lists a capability
(`f: fn() uses io`) needs it too, and so does passing such a value for a plain fn
parameter, which calls it unchecked; a call of a function with a capability parameter
(`uses E`) needs what `E` stands for at that call.

```eider,compile_fail=E0201
fn log(n: i32) uses io { print(n) }
fn work() {
    log(1)
}
fn main() { work() }
```

Fix: declare the capability on every function on the path (the compiler fixes one at a
time).

```eider
fn log(n: i32) uses io { print(n) }
fn work() uses io {
    log(1)
}
fn main() uses io { work() }
```

```output
1
```

## E0203

An **unknown capability** in a `uses` clause. The help lists the known ones: `io`, `clock`,
`fs`, `net`, `threads`, `ffi`, `python`, `js`, `wasm`.

```eider,compile_fail=E0203
fn main() uses console {}
```

Fix:

```eider
fn main() uses io { print("hello") }
```

```output
hello
```

## E0204

A **capability not granted to a package**. Every package other than the program's own,
`core` and `std` must be granted, in the `uses` list of its `[deps.<name>]` table in the
importing package's `eider.toml`, each capability it uses (a `uses` clause anywhere in the
modules the program loads from it, and `ffi` when it has `extern` functions, an `unsafe fn`
or an `unsafe` block). Reported at the import, once per (importing package, package,
capability); the help names the command that grants it (`eider grant <pkg> <cap>`) and the table it changes. It needs packages, so it can't be shown
in a single file; see [`tests/checks/fail/e0204_ungranted_fs.ei`](../../../tests/checks/fail/e0204_ungranted_fs.ei) and its packages under
[`tests/checks/fail/lib/grants/`](../../../tests/checks/fail/lib/grants/).

```text
error[E0204]: package `fsdep` uses capability `fs` in `here` (fsdep.ei:5) but is only granted []
  --> lib/grants/grantee/grantee.ei:2:1
  |
2 | import fsdep
  | ^
  help: to allow it, run `eider grant fsdep fs` in <dir>/lib/grants/grantee (it adds "fs" to `uses` in [deps.fsdep] of its eider.toml)
```

Fix: grant it, after checking that the dependency should have it: `eider grant fsdep fs` in
the grantee package (or `eider fetch --grant fsdep`, which grants what it uses), which writes

```toml
# grantee/eider.toml
[deps.fsdep]
path = "../fsdep"
uses = ["fs"]
```

## E0301

**Exclusivity of `inout`**: a variable passed `inout` to a call can't be passed again in
the same call, neither `inout` nor as an ordinary argument, since the callee could see it
change while reading it. A reference (a `let` of a place) counts as the variable it is
rooted at, so passing `xs` `inout` and a reference into `xs` in one call is E0301 too
(with a `.copy()` fix at the reference's binding).

```eider,compile_fail=E0301
fn add_to(inout total: i32, n: i32) { total += n }
fn main() uses io {
    let mut t = 1
    add_to(inout t, t)
    print(t)
}
```

Fix: copy the value first.

```eider
fn add_to(inout total: i32, n: i32) { total += n }
fn main() uses io {
    let mut t = 1
    let n = t.copy()
    add_to(inout t, n)
    print(t)
}
```

```output
2
```

## E0302

**`inout` outside a parameter**: in a field type, a return type, a type argument. `inout`
is a way of passing an argument, not a type; values can't hold references. The help
suggests storing the value itself, an index into a List, or a `Ref[T]` or `Mutex[T]` to share.

```eider,compile_fail=E0302
type Cache = { items: inout List[i32] }
fn main() {}
```

Fix: store the value (or a `Ref[T]` when several holders must see changes, see
[Memory model](memory.md)).

```eider
type Cache = { items: List[i32] }
fn main() uses io {
    let mut c = Cache(List.new())
    c.items.push(7)
    print(c.items.len())
}
```

```output
1
```

## E0303

**Writing something that isn't writable**: assigning to a `let` binding, a parameter or a
constant, calling a mutating method (`push`, `insert`, `clear`, ...) on one, passing it as
`inout`, `take`/`replace` on a fresh value (they need a place to move the value out of),
and passing a read-only place to a closure's `inout` parameter. The help and the
machine-applicable fix declare the variable `let mut`. Assigning to a variable a closure
captured has its own help: the closure works on a copy, so it takes an `inout` parameter or
captures a `Ref[T]` instead.

```eider,compile_fail=E0303
fn main() uses io {
    let xs: List[i32] = List.new()
    xs.push(1)
    print(xs.len())
}
```

Fix:

```eider
fn main() uses io {
    let mut xs: List[i32] = List.new()
    xs.push(1)
    print(xs.len())
}
```

```output
1
```

## E0304

**`inout` missing or misplaced at a call.** An argument for an `inout` parameter must be
written `inout place`, and `inout` is not allowed for an ordinary parameter. The same holds
for fn values with `inout` parameters and for closures: where the expected fn type has an
`inout` parameter the closure must write `|inout x|`, and the reverse. A named function
with `inout` parameters can't be used as a value. The compiler offers a fix where it adds
or removes the word.

```eider,compile_fail=E0304
fn bump(inout n: i32) { n += 1 }
fn main() uses io {
    let mut n = 1
    bump(n)
    print(n)
}
```

Fix:

```eider
fn bump(inout n: i32) { n += 1 }
fn main() uses io {
    let mut n = 1
    bump(inout n)
    print(n)
}
```

```output
2
```

## E0305

A **name declared twice in one scope**. Shadowing a name of an outer scope is allowed;
declaring it again in the same block is not.

```eider,compile_fail=E0305
fn main() uses io {
    let n = 1
    let n = 2
    print(n)
}
```

Fix: assign to it (declared `let mut`), or pick another name.

```eider
fn main() uses io {
    let mut n = 1
    n = 2
    print(n)
}
```

```output
2
```

## E0306

**`break` or `continue` with no loop to leave**: outside any loop (a closure's body is a
function of its own, so a loop around the closure doesn't count), or with a label that no
enclosing loop of the same function has (`no enclosing loop is labeled `outer``).

```eider,compile_fail=E0306
fn main() uses io {
    for i in 0..3 {
        for j in 0..3 {
            if j == 1 { continue rows }
            print(i * 10 + j)
        }
    }
}
```

Fix: label the loop.

```eider
fn main() uses io {
    rows: for i in 0..2 {
        for j in 0..3 {
            if j == 1 { continue rows }
            print(i * 10 + j)
        }
    }
}
```

```output
0
10
```

## E0307

A **mutable alias of a read-only place**: `let mut x = p` (or a `mut x` pattern binding into
`p`) where `p` is a parameter, a `let` binding or a reference that can't be written. An
alias can't add write access. The compiler offers the fix `.copy()` after the initializer,
which makes `x` an independent value (writes then change only the copy).

```eider,compile_fail=E0307
type P = { x: i32 }
fn bumped(p: P) -> i32 {
    let mut q = p
    q.x += 1
    q.x
}
fn main() uses io { print(bumped(P(1))) }
```

Fix:

```eider
type P = { x: i32 }
fn bumped(p: P) -> i32 {
    let mut q = p.copy()
    q.x += 1
    q.x
}
fn main() uses io { print(bumped(P(1))) }
```

```output
2
```

## E0308

The **protection rule**: while a reference (a `let` or pattern binding of a place) is still
used later, no write may free, move or replace memory it points into: `push`, `pop`,
`clear`, `insert`, `remove`, `push_str`, `append` or `push_byte` on a List or String it
points into, assigning over the place that holds it (or the enum value whose payload it
binds), `take`/`replace`, and passing that place `inout`. Plain writes to scalar fields and
elements are allowed. The compiler offers the fix `.copy()` at the reference's binding
(none in a generic body or for a type without `Copy`); the other fix is to use the
reference before the write. See [Memory model](memory.md).

```eider,compile_fail=E0308
fn main() uses io {
    let mut names: List[String] = List.new()
    names.push(String.from("a"))
    let first = names[0]
    names.push(String.from("b"))
    print(first)
}
```

Fix:

```eider
fn main() uses io {
    let mut names: List[String] = List.new()
    names.push(String.from("a"))
    let first = names[0].copy()
    names.push(String.from("b"))
    print(first)
}
```

```output
a
```

## E0309

**Deferred code that would leave itself.** The statement of a `defer` or `errdefer` runs
while its block is being left, so it can't leave again: a `return`, a `?`, or a `break` or
`continue` of a loop outside the deferred statement is refused (a loop inside it may use
them). See [Statements](statements.md#defer-and-errdefer).

```eider,compile_fail=E0309
fn first(xs: List[i32]) -> i32 {
    defer { return 0 }
    xs[0]
}

fn main() {}
```

Fix: decide before the `defer`, and leave from the function's own code.

```eider
fn first(xs: List[i32]) -> i32 {
    if xs.len() == 0 { return 0 }
    xs[0]
}

fn main() uses io {
    print(first(List.new()))
}
```

```output
0
```

## E0310

**`errdefer` in a function that can't fail.** An `errdefer` runs when its function returns
an `Err` or a `None` (also through `?`), so the function must return a `Result` or an
`Option`. The fix makes it a `defer`.

```eider,compile_fail=E0310
fn work() uses io {
    errdefer print("undo")
    print("work")
}

fn main() uses io { work() }
```

Fix:

```eider
fn work() uses io {
    defer print("undo")
    print("work")
}

fn main() uses io { work() }
```

```output
work
undo
```

## E0401

A **type mismatch**, the general type error. Raised for, among others: a value of the wrong
type (`expected i32, found u64`; there are no implicit conversions, use `as`), operands of
different types (`u8 + u32`), a function whose body ends without a value of its return type,
`return` without a value or with one in a function returning `()`, branches of an `if` or
`match` with different types, binding a `()` value, an operation the type doesn't support
(`==` on a type without `Eq`, `<` without `Ord`, printing without `Show`, iterating
something that isn't iterable, indexing a non-array, negating an unsigned integer), a
pattern of the wrong shape for the value, `[x; n]` of a type that owns heap memory, an
argument that doesn't match a generic parameter type, `?` that can't convert an error type
(no `From` impl), a closure whose body has the wrong type, and a fn value whose capabilities
the expected fn type doesn't list (`expected fn() uses fs, found fn() uses io`; add the
capability to the type's `uses`).

```eider,compile_fail=E0401
fn area(w: u32, h: u64) -> u64 {
    w * h
}
fn main() uses io { print(area(2, 3)) }
```

Fix: convert explicitly.

```eider
fn area(w: u32, h: u64) -> u64 {
    (w as u64) * h
}
fn main() uses io { print(area(2, 3)) }
```

```output
6
```

## E0402

**`null`**: the word is reserved and there is no null value. Absence is `Option[T]`.

```eider,compile_fail=E0402
fn find(n: i32) -> i32 {
    if n > 0 { return n }
    null
}
fn main() {}
```

Fix:

```eider
fn find(n: i32) -> Option[i32] {
    if n > 0 { return Some(n) }
    None
}
fn main() uses io { print(find(-1).is_none()) }
```

```output
true
```

## E0405

**Wrong number of arguments**: to a function, method, constructor, fn value or built-in
(`Box.new`, `Mutex.new`, `Chan.new`, `spawn`, `fold`, ...), and a closure with a different
number of parameters than the fn type expected where it is passed.

```eider,compile_fail=E0405
fn add(a: i32, b: i32) -> i32 { a + b }
fn main() uses io {
    print(add(1, 2, 3))
}
```

Fix:

```eider
fn add(a: i32, b: i32) -> i32 { a + b }
fn main() uses io {
    print(add(add(1, 2), 3))
}
```

```output
6
```

## E0406

**`?` where it can't apply**: on a value that is neither a `Result` nor an `Option`, or in a
function whose return type isn't the same kind (`?` on a `Result` needs the function to
return a `Result`, on an `Option` an `Option`).

```eider,compile_fail=E0406
fn half(n: u32) -> Result[u32, str] {
    if n % 2 == 1 { return Err("odd") }
    Ok(n / 2)
}
fn main() uses io {
    let h = half(4)?
    print(h)
}
```

Fix: handle the error with `match`, or return a `Result` from the function (`main` may return
`Result[(), E]`).

```eider
fn half(n: u32) -> Result[u32, str] {
    if n % 2 == 1 { return Err("odd") }
    Ok(n / 2)
}
fn main() -> Result[(), str] uses io {
    let h = half(4)?
    print(h)
    Ok(())
}
```

```output
2
```

## E0409

**Can't infer a type**: `None`, `List.new()`, `Map.new()`, `Chan.new()` or `T.default()`
without an annotation or another use that fixes the type, a closure parameter or result
type that nothing determines, a generic function used as a value, and the target of a
`From` conversion.

```eider,compile_fail=E0409
fn main() uses io {
    let xs = List.new()
    print(xs.len())
}
```

Fix: annotate the binding.

```eider
fn main() uses io {
    let xs: List[i32] = List.new()
    print(xs.len())
}
```

```output
0
```

## E0410

A **pattern with the wrong number of parts**: a variant pattern with more or fewer
sub-patterns than the variant has fields (a payload variant written without its
parentheses too), or a tuple pattern with a different number of elements than the tuple.

```eider,compile_fail=E0410
type Shape = | Rect(w: u32, h: u32) | Empty
fn width(s: Shape) -> u32 {
    match s {
        Rect(w) => w
        Empty => 0
    }
}
fn main() {}
```

Fix: one sub-pattern per field (`_` for the ones not needed).

```eider
type Shape = | Rect(w: u32, h: u32) | Empty
fn width(s: Shape) -> u32 {
    match s {
        Rect(w, _) => w
        Empty => 0
    }
}
fn main() uses io { print(width(Rect(3, 4))) }
```

```output
3
```

## E0411

A **`Ref` that would cross to another thread**. A `Ref[T]` is shared without a lock, so the
compiler rejects a `Task[T]`, `Mutex[T]` or `Chan[T]` whose `T` holds a `Ref` anywhere in
its parts, a `Mutex.new` of such a value, a spawned closure returning one, and a closure
written at `spawn(...)` that captures one. (A closure stored first and spawned later is
caught at run time: it traps.) See [Concurrency](concurrency.md).

```eider,compile_fail=E0411
fn main() {
    let counts = Ref.new(0)
    let m = Mutex.new(counts)
}
```

Fix: state that threads share goes in a `Mutex` holding the value itself.

```eider
fn main() uses io {
    let m = Mutex.new(0)
    m.update(|n| n + 1)
    print(m.get())
}
```

```output
1
```

## E0412

A **format spec that applies only to integers**, used in an [interpolated string](lexical.md#interpolation)
on a value of another type: `+` (a sign on non-negative numbers), `#` (a radix prefix), `0`
(zero padding) and the radix letters `x`, `X`, `b` and `o`. A width, a fill and an
alignment apply to any type. The fix deletes the spec.

```eider,compile_fail=E0412
fn main() uses io {
    let name = "Ada"
    print("{name:x}")
}
```

Fix: format integers with those, and pad anything with a width.

```eider
fn main() uses io {
    let name = "Ada"
    print("[{name:>5}] [{255:#x}]")
}
```

```output
[  Ada] [0xff]
```

## E0501

A **constant out of range**: an integer literal that doesn't fit its type (`let x: u8 =
256`), a pattern literal that doesn't fit the matched type, and a constant expression whose
result overflows (`200 + 100` as `u8`), folded at compile time.

```eider,compile_fail=E0501
fn main() uses io {
    let level: u8 = 300
    print(level)
}
```

Fix: use a type that holds the value.

```eider
fn main() uses io {
    let level: u32 = 300
    print(level)
}
```

```output
300
```

## E0502

**Division or remainder by a constant zero** (`x / 0`, `x % 0`). (`x /= 0` is not detected
at compile time; it traps at run time.)

```eider,compile_fail=E0502
fn per_item(total: i32) -> i32 {
    total / 0
}
fn main() {}
```

Fix: divide by the intended value, or check a variable divisor before dividing.

```eider
fn per_item(total: i32, n: i32) -> i32 {
    if n == 0 { return 0 }
    total / n
}
fn main() uses io { print(per_item(10, 0)) }
```

```output
0
```

## E0503

A **constant index out of bounds of an array**: the array's length is part of its type,
so `a[3]` on a `[i32; 3]` is caught at compile time. (Lists, and variable indices, are
checked at run time.)

```eider,compile_fail=E0503
fn main() uses io {
    let a = [1, 2, 3]
    print(a[3])
}
```

Fix:

```eider
fn main() uses io {
    let a = [1, 2, 3]
    print(a[2])
}
```

```output
3
```

## E0504

An **invalid constant initializer**: a `const` must be a literal or a compile-time integer
or bool expression over other constants, and can't own heap memory (`String`, `List`, ...).
Call a function at compile time with `comptime` (integers and `bool` only, see
[Compile-time evaluation](comptime.md)), or build the value in a function.

```eider,compile_fail=E0504
fn base() -> i32 { 40 }
const ANSWER: i32 = base() + 2
fn main() uses io { print(ANSWER) }
```

Fix:

```eider
fn base() -> i32 { 40 }
const ANSWER: i32 = comptime base() + 2
fn main() uses io { print(ANSWER) }
```

```output
42
```

## E0505

A **constant shift count out of range**: a count that is negative or not below the
operand's width, in `<<`, `>>`, `<<=` or `>>=`. A variable count out of range traps at run
time.

```eider,compile_fail=E0505
fn high_bit(x: u32) -> u32 {
    x >> 32
}
fn main() {}
```

Fix:

```eider
fn high_bit(x: u32) -> u32 {
    x >> 31
}
fn main() uses io { print(high_bit(4294967295)) }
```

```output
1
```

## E0506

**`push_byte` of a constant that isn't ASCII** (1 to 127). A String is always valid UTF-8,
so a single byte of a longer sequence can't be appended; build other text with `push_str`,
`append` or `String.from_bytes`.

```eider,compile_fail=E0506
fn main() uses io {
    let mut s = String.from("caf")
    s.push_byte(233)
    print(s)
}
```

Fix:

```eider
fn main() uses io {
    let mut s = String.from("caf")
    s.push_str("\u{e9}")
    print(s)
}
```

```output
café
```

## E0601

A **trait not implemented**: a type passed where a bound requires a trait it lacks
(`type i32 doesn't implement trait `Area` (required by `total`)`), `.copy()` on a type
without `Copy` (anything holding a `Task` or `Chan`), `T.default()` or `take()` on a type
without `Default`, an own `Ord` or `Hash` impl on a type without `Eq`, and `.context(...)`
of std/error on an error type that isn't an `error.Error`, and a value that becomes a
`dyn Trait` whose type doesn't implement the trait. The message names the part of
the type that lacks the trait.

```eider,compile_fail=E0601
trait Area { fn area(self) -> u32 }
type Sq = { s: u32 }
impl Area for Sq { fn area(self) -> u32 { self.s * self.s } }
fn total[T: Area](a: T) -> u32 { a.area() }
fn main() uses io {
    print(total(5))
}
```

Fix: pass a type that implements the trait, or implement it for the type (in its own
package).

```eider
trait Area { fn area(self) -> u32 }
type Sq = { s: u32 }
impl Area for Sq { fn area(self) -> u32 { self.s * self.s } }
fn total[T: Area](a: T) -> u32 { a.area() }
fn main() uses io {
    print(total(Sq(5)))
}
```

```output
25
```

## E0602

An **impl that doesn't match its trait**: a method whose signature differs from the
trait's, a method the trait doesn't have, a missing method, an `Iter` impl whose `next`
doesn't return an `Option`, an associated type the impl doesn't define (or one the trait
doesn't declare, or one in an inherent impl), and for `From`: a signature other than
`fn from(value: Source) -> Target`, or a `from` that declares capabilities.

```eider,compile_fail=E0602
trait Area { fn area(self) -> u32 }
type Sq = { s: u32 }
impl Area for Sq {
    fn area(self) -> u64 { 0 }
}
fn main() {}
```

Fix: use the trait's signature.

```eider
trait Area { fn area(self) -> u32 }
type Sq = { s: u32 }
impl Area for Sq {
    fn area(self) -> u32 { self.s * self.s }
}
fn main() uses io { print(Sq(3).area()) }
```

```output
9
```

## E0603

An **unknown trait**, in a bound (`T: Printable`) or an `impl ... for`, or a trait used with
type arguments it doesn't take: only `From` takes one (`impl From[E1] for E2`), and
`impl From for X` without it is E0603 too.

```eider,compile_fail=E0603
fn twice[T: Printable](x: T) -> T { x }
fn main() {}
```

Fix: name an existing trait (here the prelude's `Show`), or declare it.

```eider
fn show_twice[T: Show](x: T) uses io {
    print(x)
    print(x)
}
fn main() uses io { show_twice(7) }
```

```output
7
7
```

## E0604

The **orphan rule**: a language trait (`Copy`, `Eq`, `Ord`, `Hash`, `Show`, `Iter`, `Drop`,
`Default`, `From`) may be implemented for a type only by the package that defines the type.
Built-in types (integers, `String`, `List`, ...), prelude types (`Option`, `Result`,
`Ordering`), types of other packages and bare type parameters (`impl[T] Eq for T`) are
refused, so a type's behaviour can't depend on which modules were imported. A file in no
package counts as the program's own package.

```eider,compile_fail=E0604
impl Show for i32 {
    fn show(self, inout out: String) { out.push_str("an int") }
}
fn main() {}
```

Fix: wrap the type in a record of your own.

```eider
type Count = { n: i32 }
impl Show for Count {
    fn show(self, inout out: String) {
        out.push_str("count ")
        out.append(self.n.to_string())
    }
}
fn main() uses io { print(Count(3)) }
```

```output
count 3
```

## E0605

A **missing bound in generic code**: a generic body may use an operation on a type parameter
only when its bounds promise it: `==` needs `T: Eq`, `<` and `compare` `T: Ord`, printing
`T: Show`, `.copy()` `T: Copy`, `for` over it `T: Iter`, `contains` on a `List[T]` `T: Eq`,
`T.default()` and `take()` `T: Default`, and a `Map[K, V]` (also in a signature)
`K: Hash + Eq`, and an associated type `T.Item` needs a bound of `T` that declares `Item`.
The compiler offers a machine-applicable fix that adds the bound. These
errors are found after every other check, so they come last.

```eider,compile_fail=E0605
fn same[T](a: T, b: T) -> bool { a == b }
fn main() uses io { print(same(1, 2)) }
```

Fix (the one the compiler suggests):

```eider
fn same[T: Eq](a: T, b: T) -> bool { a == b }
fn main() uses io { print(same(1, 2)) }
```

```output
false
```

## E0606

A **`Drop` impl that doesn't qualify**: `Drop` is for records only (not enums, tuples or
other types), for all instances of a generic record (`impl[T] Drop for R[T]`, no bounds),
and `drop` can't declare capabilities, because it runs wherever the value's last holder
goes.

```eider,compile_fail=E0606
type Handle = | Open(fd: i32) | Closed
impl Drop for Handle {
    fn drop(inout self) {}
}
fn main() {}
```

Fix: put the resource in a record.

```eider
type Handle = { fd: i32 }
impl Drop for Handle {
    fn drop(inout self) { self.fd = -1 }
}
fn main() uses io {
    let h = Handle(3)
    print(h.fd)
}
```

```output
3
```

## E0607

A **trait that can't be `dyn`**. `dyn Trait` is one table of methods that works for any
implementing type, so the trait must qualify: every method takes `self` or `inout self`, has no
type parameters and mentions `Self` only as its receiver, no method has another `inout`
parameter, and the trait has no associated types. The message names the method and the clause
it breaks and the help prints the rule; the language traits (`Show`, `Eq`, `Drop`, ...) are
never `dyn`.

```eider,compile_fail=E0607
trait Pick {
    fn pick[T](self, a: T, b: T) -> T
}

fn first(p: dyn Pick) {}

fn main() {}
```

Fix: take the generic part out of the trait (a method without type parameters, or a generic
function that takes the trait as a bound).

```eider
trait Pick {
    fn pick(self, first: bool) -> i32
}

type Two = { a: i32, b: i32 }

impl Pick for Two {
    fn pick(self, first: bool) -> i32 { if first { self.a } else { self.b } }
}

fn first_of(p: dyn Pick) -> i32 { p.pick(true) }

fn main() uses io {
    print(first_of(Two(1, 2)))
}
```

```output
1
```

## E0608

A **method that needs a capability its trait doesn't declare**, where a value becomes a
`dyn Trait`. A call through `dyn Trait` is checked against the trait's declaration, because the
caller cannot see which implementation runs; so each method of the type's impl may declare only
capabilities the trait's method declares. (Called on the concrete type, an impl may declare
more.) The help names the `uses` to add to the trait.

```eider,compile_fail=E0608
trait Run {
    fn go(self)
}

type Hello = { n: i32 }

impl Run for Hello {
    fn go(self) uses io { print(self.n) }
}

fn main() uses io {
    let r: dyn Run = Hello(1)
    r.go()
}
```

Fix: declare the capability in the trait, so every call through `dyn Run` needs it.

```eider
trait Run {
    fn go(self) uses io
}

type Hello = { n: i32 }

impl Run for Hello {
    fn go(self) uses io { print(self.n) }
}

fn main() uses io {
    let r: dyn Run = Hello(1)
    r.go()
}
```

```output
1
```

## E0701

An **invalid Map key type**: a key must implement `Hash` and `Eq`. Maps, fn values, thread
handles and `Ref`s can't be keys, nor can anything containing them; the message names the
part that lacks the trait. A key type with a part that has its own `Eq` but a derived `Hash`
is refused too (equal keys must hash alike).

```eider,compile_fail=E0701
fn main() {
    let m: Map[Map[i32, i32], i32] = Map.new()
}
```

Fix: key by a type that hashes (integers, `bool`, `str`, `String`, and records, enums,
tuples and Lists of them).

```eider
fn main() uses io {
    let mut m: Map[(i32, i32), str] = Map.new()
    m.insert((1, 2), "a")
    print(m.len())
}
```

```output
1
```

## E0801

A **private item used from another module**: functions, types, constants and traits are
private to their module unless declared `pub`. The help says to mark it `pub` in its own
file.

```eider,compile_fail=E0801
import std.strings
fn main() uses io {
    print(strings.empty())
}
```

Fix: use the module's public API (or, in your own module, add `pub`).

```eider
fn main() uses io {
    print(String.from("").len())
}
```

```output
0
```

## E0802

**A call to C outside `unsafe`**: calling an `extern "c"` function, or an `unsafe fn`, is
only allowed inside an `unsafe { ... }` block or an `unsafe fn`. This holds across packages
too (unlike `ffi`, `unsafe` doesn't stay inside a package). See [C interop](ffi.md).

```eider,compile_fail=E0802
extern "c" fn abs(n: i32) -> i32
fn main() uses io, ffi {
    print(abs(-3))
}
```

Fix:

```eider
extern "c" fn abs(n: i32) -> i32
fn main() uses io, ffi {
    let a = unsafe { abs(-3) }
    print(a)
}
```

```output
3
```

## E0803

A **type that can't cross the C boundary**: the parameters and result of an `extern "c"`
function must be integers, `bool` or `str` (or `()` as the result) and not `inout`; an
`export fn` may also use records made only of such types, but not records with their own
`Drop`.

```eider,compile_fail=E0803
extern "c" fn puts(s: String) -> i32
fn main() {}
```

Fix:

```eider
extern "c" fn puts(s: str) -> i32
fn main() uses ffi {
    let r = unsafe { puts("from C") }
}
```

```output
from C
```

## E0804

A **module that can't be loaded**: an unknown module (`import std.nothing`, or a use
`std.nothing.f()` through the namespace; in a file in no package, `import util` when there is
no `util.ei` beside it), a file that can't be read, and, in the deprecated quoted form, a
path that doesn't exist (`import "util.ei"`) or the old `deps/` spelling of a package import
(the help says to import the package by name).

```eider,compile_fail=E0804
import std.nothing
fn main() {}
```

Fix: correct the module path, or create the module.

## E0805

An **invalid export**: an `export fn` can't be generic (it needs a fixed C signature), and a
library (`build --lib`, `emit-header`, `--wasm`) needs at least one `export fn` (reported at
1:1).

```eider,compile_fail=E0805
export fn id[T](x: T) -> T { x }
fn main() {}
```

Fix: export a concrete wrapper.

```eider
fn id[T](x: T) -> T { x }
export fn id_i32(x: i32) -> i32 { id(x) }
fn main() uses io { print(id_i32(4)) }
```

```output
4
```

## E0806

**Not available on WebAssembly** (checked only with `--wasm`): an export with a parameter
other than an integer, `bool`, `String` or `List[u8]`, a result other than one of those or
`()`, and any use
of threads (`spawn`, `Task`, `Mutex`, `Chan`; reported at 1:1). It needs `--wasm`, so it
isn't shown as a test here; see [`tests/checks/fail/e0806_wasm_str.ei`](../../../tests/checks/fail/e0806_wasm_str.ei):

```eider,ignore
export fn greet(name: str) -> i32 { return 1 }
```

```text
$ eiderc check --wasm greet.ei
error[E0806]: parameter `name` has type str; WebAssembly exports take only integers, bool, String and List[u8]
```

Fix: pass integers, `bool`, a `String` or a `List[u8]` across the boundary.

## E0807

A **failed `comptime` evaluation**: the type of a `comptime` constant isn't an integer type
or `bool`, the evaluation traps (`comptime evaluation of `X` failed: <the trap>`), or it
prints more than one line. See [Compile-time evaluation](comptime.md).

```eider,compile_fail=E0807
fn ratio(n: i32) -> i32 { 100 / n }
const R: i32 = comptime ratio(0)
fn main() uses io { print(R) }
```

Fix:

```eider
fn ratio(n: i32) -> i32 { 100 / n }
const R: i32 = comptime ratio(4)
fn main() uses io { print(R) }
```

```output
25
```

## E0808

**Two modules with one identity**: two files in no package with the same file stem (their
items would get the same names), or two copies of one package loaded from different
directories. Reported at the second import. It needs several files; see
[`tests/checks/fail/e0808_module_name_clash.ei`](../../../tests/checks/fail/e0808_module_name_clash.ei), which imports `lib/geometry.ei` and
`lib2/geometry.ei`.

```eider,ignore
import lib.geometry as g1
import lib2.geometry as g2

fn main() {}
```

Fix: rename one of the files, or put them in packages (two packages may each have a module
of one name; see [Modules and packages](modules.md)).

## E0809

**Not a dependency**: in a package, an import (`import json`, `import json.util`) whose first
segment is neither the package itself nor a direct dependency declared in its
`eider.toml`. The help gives the `eider-pkg add` command, or, when the path names one of the
package's own modules without the package's name (`import util` for its `util.ei`), the
import to write (`import app.util`). In the deprecated quoted form, also a package import
from a file in no package (`import "json"`), a malformed import string (`"Geo"`,
`"geo//util"`), and `"std"` or `"core"` alone.

```eider,compile_fail=E0809
import "json"
fn main() {}
```

Fix: declare the dependency (`eider-pkg add json --path <dir>`, from inside a package),
import your own module by the package's name, or import a toolchain module (`import std.fs`).

## E0810

**A package that can't be located**: the program's `eider.lock` is missing, has no entry
for the package, or points at a directory that doesn't exist, or an `eider.toml` or
`eider.lock` doesn't parse. The fix (as help) is to run `eider-pkg fetch` in the package's
directory.
It needs a package; see [`tests/checks/fail/e0810_no_lock.ei`](../../../tests/checks/fail/e0810_no_lock.ei) and
[`tests/checks/fail/lib/nolock/`](../../../tests/checks/fail/lib/nolock/), a package with a dependency and no `eider.lock`.

```toml
[package]
name = "nolock"
version = "0.1.0"

[deps.json]
path = "../json"
```

```text
error[E0810]: can't locate package `json`: there is no eider.lock in <dir>/lib/nolock
  --> lib/nolock/nolock.ei:2:1
  |
2 | import json
  | ^
  help: run `eider-pkg fetch` in <dir>/lib/nolock
```

Fix: run `eider-pkg fetch` in the package's directory, which resolves the dependencies,
writes `eider.lock` and puts each package where the lock says.

## E0811

**A package written for another toolchain**: a package's `eider.toml` says
`eider = "X.Y"`, the toolchain MAJOR.MINOR it needs, and that isn't this compiler's
(`eiderc --version`), or the value is not a MAJOR.MINOR (`"0.1.0"`, `"latest"`). Before 1.0
a MINOR release may break compatibility, so every build checks it. Reported at 1:1 of the
entry file for the entry file's own package, and at the first import that loads a module of
any other package; each package once. A package without `eider` is not checked. See
[`tests/checks/fail/e0811_toolchain_series.ei`](../../../tests/checks/fail/e0811_toolchain_series.ei),
which imports [`tests/checks/fail/lib/newer/`](../../../tests/checks/fail/lib/newer/), a package
that says `eider = "9.9"`.

```toml
[package]
name = "newer"
version = "0.1.0"
eider = "9.9"
```

```text
error[E0811]: package `newer` needs Eider 9.9 (`eider = "9.9"` in <dir>/lib/newer/eider.toml), but this toolchain is 0.3
  --> e0811_toolchain_series.ei:3:1
  |
3 | import lib.newer.newer
  | ^
  help: build it with an Eider 9.9.x toolchain, or port it to 0.3 and set `eider = "0.3"` in <dir>/lib/newer/eider.toml
```

Fix: build with a toolchain of the MAJOR.MINOR the package names (a release bundle has
matching versions of everything; see [Releases](../tooling/releases.md)), or update the
package for this toolchain and change its `eider`.

## E0812

**An ambiguous package name**: a package whose `eider.toml` declares a dependency with the
package's own name, so an import's first segment (`import selfdep.util`) could mean either.
Reported at the import. It needs a package; see
[`tests/checks/fail/e0812_ambiguous_package.ei`](../../../tests/checks/fail/e0812_ambiguous_package.ei)
and [`tests/checks/fail/lib/selfdep/`](../../../tests/checks/fail/lib/selfdep/).

```text
error[E0812]: `selfdep` is both this package and one of its dependencies (<dir>/lib/selfdep/eider.toml)
  --> lib/selfdep/selfdep.ei:2:1
  |
2 | import selfdep.util
  | ^
  help: an import's first segment names one package, and a package can't depend on one with its own name: rename this package (`[package] name`) or drop the dependency
```

Fix: rename the package or drop the dependency.

## E0813

**An alias that already names another module**: two imports of one file with one alias
(`import std.fs` and `import std.io as fs`, or `std` for a namespace and a module).
Reported at the second import (the quoted form keeps its old meaning: the later import
wins).

```eider,compile_fail=E0813
import std.fs
import std.io as fs
fn main() {}
```

Fix: give one of them another name with `as`:

```eider
import std.fs
import std.io as out
fn main() uses io, fs { out.outln(fs.join("a".bytes(), "b".bytes())) }
```

```output
a/b
```

## E0820

**An unknown attribute**: `@name` where no attribute `name` is declared in the module, by
the module an import alias `name` names, or (for `@alias.name`) by that module. Reported at
the `@`. When a declared attribute is close, the fix renames it. See
[Attributes](attributes.md).

```eider,compile_fail=E0820
attr json { name: str = "" }

@jsno(name = "id")
fn main() {}
```

Fix: use a declared attribute (`@json`), or import the package that declares it.

## E0821

**An unknown attribute key**: an argument names a key the attribute's declaration doesn't
have. Reported at the key, with a fix when a key is close (else the help lists the keys).

```eider,compile_fail=E0821
attr json { name: str = "" }

@json(nam = "id")
fn main() {}
```

Fix: use one of the declared keys.

## E0822

**A bad attribute declaration or argument**: a key whose type isn't an integer type, `bool`
or `str`; a value that isn't a literal or a constant; a key given twice, or an attribute
given twice on one item; a bare key (`@json(skip)`) that isn't a `bool`; a key without a
default that the use leaves out. Reported at the declaration's type, the value, the key or
the `@`.

```eider,compile_fail=E0822
attr route { path: str }

@route
fn main() {}
```

Fix: give the key (`@route(path = "/")`), or a default in the declaration
(`attr route { path: str = "/" }`).

## E0830

**A reflection on the wrong kind of thing**: `fields(...)` of a type that isn't a record (or
a variant binding), `variants(...)` of one that isn't an enum, `x.[f]` with x of another type
than f's record, a member of a reflected name other than `name`, `index` and (a variant's)
`matches`, a `comptime for` argument list that doesn't go over the fields of the record or
variant it builds. See [Comptime reflection](reflection.md).

```eider,compile_fail=E0830
type Shape = | Circle(r: i64) | Empty

fn f() {
    comptime for x in fields(Shape) {}
}

fn main() { f() }
```

Fix: `variants(Shape)`, then `fields(v)` for a variant's payload.

## E0831

**A comptime-only name used as a value**: a `comptime for` variable has no value at run
time, and `x.[e]` needs one.

```eider,compile_fail=E0831
type P = { a: i64 }

fn f() {
    comptime for x in fields(P) {
        let y = x
    }
}

fn main() { f() }
```

Fix: use `x.name`, `x.index`, `p.[x]` or `attr[A](x)`.

## E0832

**Not known at compile time**: a `comptime if` condition that uses something other than
literals, constants, reflected names and indexes, attribute values and operators on them;
or `break` directly inside a `comptime for`, whose body is not a loop at run time.

```eider,compile_fail=E0832
fn f(n: i64) {
    comptime if n > 2 {}
}

fn main() { f(1) }
```

Fix: an ordinary `if` for a value known only at run time.
