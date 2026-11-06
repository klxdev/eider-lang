# Statements

A function body is a block: a sequence of statements between `{` and `}`. This page
describes every statement. Expressions, including `if` and `match`, are described in
[Expressions](expressions.md); the bindings that `let` creates (references or owned values)
in [Memory model](memory.md).

## Blocks and separators

Statements are separated by newlines. Two statements on one line need a `;` between them
(E0001 "expected a newline or `;` after statement" otherwise). A `;` is only a separator:
it doesn't turn an expression into a statement, so `{ 5; }` has the value 5 just like
`{ 5 }`.

A statement may continue on the next line when the line ends with a binary operator, an
`=`, a `,` inside brackets, or an opening bracket, and when the next line starts with `.`
(see [Lexical structure](lexical.md#newlines)). A line starting with an operator such as `+`
starts a new statement.

```eider
fn add(a: i32, b: i32) -> i32 { a + b }

fn main() uses io {
    let a = 1 +
        2
    let b = add(a,
        4)
    print(a); print(b)
}
```

```output
3
7
```

**The value of a block** is the value of its last statement when that statement is an
expression; otherwise `()`. A block used as a value (a function body with a result type,
the right side of a `let`, a branch of an `if` used as a value) must end with an expression
of the right type, or with something that doesn't return normally (`return`, `break`,
`continue`, `panic(...)`). A function whose body can end without a value is E0401 "must
return i32, but its body ends without producing one".

```eider
fn sign(n: i32) -> i32 {
    if n < 0 { return -1 }
    if n == 0 { 0 } else { 1 }
}

fn main() uses io {
    let x = {
        let a = 2
        a * 3
    }
    print(x)
    print(sign(-9))
}
```

```output
6
-1
```

**Scopes.** Each block is a scope. A name declared in a block is visible from its
declaration to the end of the block. Declaring a name again in the same block is E0305;
declaring it in an inner block shadows the outer one until the inner block ends.

```eider
fn main() uses io {
    let x = 1
    if x > 0 {
        let x = 2
        print(x)
    }
    print(x)
}
```

```output
2
1
```

## `let`

```text
let_stmt = "let" ["mut"] name [":" type] "=" expr
         | "let" tuple_pattern "=" expr
         | "let" pattern "=" expr "else" block
```

`let` declares a variable and initializes it; every variable is initialized (there is no
`let x: i32` without a value). The type annotation is optional when the initializer's type
is known; it is needed for `List.new()`, `Map.new()`, `None` and the like (E0409).

- `let x = e` binds a name that can't be assigned to or mutated through (E0303). When `e`
  is a *place* (a variable, a field, an element: `orders[i].items`), `x` is a read-only
  reference to that place, and the place can't be written while `x` is still used later
  (E0308); but when its type is a scalar (a number, `bool`, `str` or an enum without payloads)
  `x` is a copy (`let start = i` keeps its value when `i += 1` follows); otherwise `x` owns
  the fresh value.
- `let mut x = e` declares a mutable variable. Of a fresh value, or of a scalar place, it is
  an ordinary mutable local. Of any other place it is a *mutable alias*: writes through `x`
  change the place. The place must be writable (E0307 otherwise; take a `.copy()`).
- `let (a, b) = e` destructures a tuple with an irrefutable pattern (E0101 for a refutable
  one; E0410 for the wrong number of elements). Each name may be `mut` on its own
  (`let (mut a, b) = e`); `let mut (a, b)` doesn't exist.

The full rules for references, aliases and the protection rule are in
[Memory model](memory.md). `mut` is a contextual word, not a keyword: it means mutable only
when a name follows, so `let mut = 1` declares a variable called `mut`.

```eider
fn main() uses io {
    let a = 1
    let mut b = a + 1
    b *= 10
    let (q, mut r) = (17 / 5, 17 % 5)
    r += 1
    let names: List[String] = List.new()
    print(b)
    print(q)
    print(r)
    print(names.len())
}
```

```output
20
3
3
0
```

```eider,compile_fail=E0303
fn main() uses io {
    let n = 1
    n = 2
    print(n)
}
```

A value of type `()` can't be bound (E0401).

### `let ... else`

`let PATTERN = e else { ... }` binds the names of a pattern that can fail, and leaves the
scope when it does. The pattern starts with a variant or record name (`Some(x)`,
`Ok(Point { x, y })`, `m.Some(x)`) or with `(`; the bindings are in scope for the rest of
the block, so there is no nesting. The `else` block must end the scope: `return`, `break`,
`continue`, `panic`, or a call that never returns (E0120 if it can fall through). A pattern
that matches every value has no use for an `else` (E0102). Put `mut` on a binding
(`let Some(mut n) = e else { ... }`), not after `let`.

`let P = e else { E }` followed by the rest `R` of the block is the same as
`match e { P => { R } _ => { E } }`, so the bindings follow the rules of `match`
([Memory model](memory.md)).

```eider
fn first_even(xs: List[i32]) -> Option[i32] {
    for x in xs {
        if x % 2 == 0 { return Some(x) }
    }
    None
}

fn halve(xs: List[i32]) -> Result[i32, str] {
    let Some(n) = first_even(xs) else { return Err("no even number") }
    Ok(n / 2)
}

fn main() uses io {
    let mut xs: List[i32] = List.new()
    print(halve(xs))
    xs.push(3)
    xs.push(8)
    print(halve(xs))
}
```

```output
Err("no even number")
Ok(4)
```

```eider,compile_fail=E0120
fn first_even(xs: List[i32]) -> Option[i32] {
    for x in xs {
        if x % 2 == 0 { return Some(x) }
    }
    None
}

fn main() uses io {
    let xs: List[i32] = List.new()
    let Some(n) = first_even(xs) else { print("none") }
    print(n)
}
```

### `var` (removed)

`var` is not a keyword any more (0.7.5): `var x = e` is the syntax error
[E0001](errors.md#e0001) whose help shows `let mut x = e` (a fresh value) and
`let mut x = e.copy()` (a copy of a place).

## Assignment

```text
assign_stmt = place assign_op expr
assign_op   = "=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&=" | "|=" | "^=" | "<<=" | ">>="
```

The left side is a place rooted at a writable variable: a `let mut` variable,
an `inout` parameter, or a mutable alias, followed by any chain of fields (`p.x`), tuple
elements (`t.0`) and indices (`xs[i]`, `grid[i][j]`). Anything else is E0303.

`x op= e` is `x = x op e` with `x`'s place evaluated once; the operator rules (same types,
overflow traps, shift counts) are those of the binary operator. There is no wrapping
compound assignment (`+%=`); write `x = x +% e`. Assignment is a statement, not an
expression: `(x = 1)` is a syntax error.

The right side is evaluated before the place is written. The old value of the place is
dropped after the new one is stored (see [Memory model](memory.md#drop-order)). A write
while a reference into the place is still used later can be refused by the protection rule
(E0308).

```eider
type Point = { x: i32, y: i32 }

fn main() uses io {
    let mut p = Point(1, 2)
    p.x = 9
    p.y += 1
    let mut grid = [[0, 0], [0, 0]]
    grid[1][0] = 5
    let mut t = (1, "a")
    t.0 -= 1
    let mut bits: u8 = 1
    bits <<= 3
    bits |= 1
    print(p)
    print(grid)
    print(t)
    print(bits)
}
```

```output
Point { x: 9, y: 3 }
[[0, 0], [5, 0]]
(0, "a")
9
```

## Expression statements

Any expression can be a statement; its value is dropped. Calls of functions returning `()`
are the common case. `if`, `match`, blocks and `unsafe { }` can be statements too (see
[Expressions](expressions.md#if)).

## `while`

```text
while_stmt = [label ":"] "while" expr block
           | [label ":"] "while" "let" pattern "=" expr block
```

`while cond { body }` runs the body as long as the `bool` condition is true, checking it
before each iteration. There is no `loop` keyword: an endless loop is `while true { ... }`.
The compiler doesn't treat `while true` specially, so a function with a result type whose
body ends with such a loop still needs a final expression after it (E0401 otherwise), even
when the loop is only left through `return`.

`while let PAT = e { body }` evaluates `e` before each iteration and runs the body while
the value matches PAT, with PAT's bindings in scope. It is the same as
`while true { match e { PAT => { body } _ => { break } } }`: a value that doesn't match ends
the loop (and is dropped).

```eider
fn main() uses io {
    let mut stack: List[i32] = List.new()
    stack.push(1)
    stack.push(2)
    stack.push(3)
    while let Some(top) = stack.pop() {
        print(top)
    }
    let mut n = 0
    while true {
        n += 1
        if n == 5 { break }
    }
    print(n)
}
```

```output
3
2
1
5
```

## `for`

```text
for_stmt = [label ":"] "for" name "in" expr ".." expr block
         | [label ":"] "for" name "in" expr block
         | [label ":"] "for" "(" pattern {"," pattern} ")" "in" expr block
```

### Ranges

`for i in a..b` counts from `a` up to `b`, excluding `b`; when `a >= b` the body doesn't
run. Both bounds have one integer type, which is the type of `i` (`i32` when both are
literals, so `for i in 0..3` can't index a List or array without `as usize`; give one
bound a type instead, as below). The bounds are evaluated once, before the loop. Ranges exist only in `for`:
`a..b` is not an expression elsewhere, and there is no inclusive `..=` or step.

```eider
fn main() uses io {
    for i in 0..3 { print(i) }
    let n: usize = 2
    for j in 0..n { print(j * 10) }
    for k in 5..5 { print(k) }
}
```

```output
0
1
2
0
10
```

### Sequences

`for x in e` iterates:

- a `List[T]` or an array `[T; N]`: `x` is each element, in order;
- a `Map[K, V]`: `x` is each `(K, V)` pair, in the Map's slot order (see
  [Types](types.md#mapk-v));
- any value whose type implements `Iter` (see [Traits](traits.md#iter)): the loop calls
  `next` on its own copy of the value until it returns `None`.

Anything else is E0401. The loop variable is a copy of the element (it owns its value; it
is not a reference into the sequence). Instead of a name, the loop may take an irrefutable
pattern in parentheses, usually a tuple: `for (k, v) in m`, `for (i, (a, b)) in pairs`;
a refutable pattern is E0101.

Every sequence is iterated over a snapshot taken when the loop starts: a List or an array as
it was then, a Map's entries. So the body may write, push, pop, insert and remove; the loop
still sees each element from before exactly once, and none it added (see
[Memory model](memory.md#for-loop-variables)).

```eider
fn main() uses io {
    let words = ["a", "b"]
    for w in words { print(w) }
    let mut ages: Map[str, i32] = Map.new()
    ages.insert("ada", 36)
    for (name, age) in ages {
        print(name)
        print(age)
    }
    let pairs = [(1, true), (2, false)]
    for (n, flag) in pairs {
        if flag { print(n) }
    }
}
```

```output
a
b
ada
36
1
```

## `break` and `continue`

`break` leaves the innermost enclosing loop; `continue` skips to its next iteration (for a
range, after the counter is advanced). Both are E0306 outside a loop. A closure's body is a
function of its own: a `break` inside a closure can't leave a loop around it.

### Labels

A `for` or `while` loop may be labeled with an identifier and a colon. `break label` and
`continue label` (the label on the same line) leave or continue that loop from anywhere
inside it. The label must belong to an enclosing loop of the same function (E0306
"no enclosing loop is labeled `x`"), and a loop can't reuse the label of a loop around it
(E0107). Labels are their own namespace: a variable may have a label's name. Loops that
don't enclose each other may share a label.

```eider
fn main() uses io {
    let grid = [[1, 2, 3], [4, -1, 6], [7, 8, 9]]
    let n: usize = 3
    let mut found = false
    rows: for i in 0..n {
        for j in 0..n {
            if grid[i][j] < 0 {
                found = true
                break rows
            }
            if grid[i][j] == 2 { continue rows }
            print(grid[i][j])
        }
    }
    print(found)
}
```

```output
1
4
true
```

Leaving loops with `break`, `continue`, `return` or `?` drops the values the loops own,
innermost first (see [Memory model](memory.md#drop-order)).

## `return`

`return e` ends the function with the value `e`; `return` alone (or `return ()`) ends a
function that returns `()`. A `return` with a value in a function returning `()`, or
without one in a function with a result type, is E0401. In a closure, `return` returns
from the closure.

`return` can also be the body of a `match` arm, like `break`, `continue` and `assert`:
`None => return`.

## `defer` and `errdefer`

```text
defer_stmt = ("defer" | "errdefer") stmt
```

`defer s` runs the statement `s` when the block it is in is left: at the block's end, and
on every exit that leaves the block early (`return`, `?`, `break` and `continue`, also of
a labeled loop further out). Several deferred statements run in reverse order of their
`defer`s, interleaved with the drops of the block's values: a `defer` runs before the
values declared before it are dropped, so it can still use them. A `defer` in a loop's
body runs at the end of each iteration.

```eider
fn work() uses io {
    defer print("cleanup 1")
    defer print("cleanup 2")
    for i in 0..3 {
        defer print("end of iteration {i}")
        if i == 1 { continue }
        print("iteration {i}")
    }
    print("done")
}

fn main() uses io {
    work()
}
```

```output
iteration 0
end of iteration 0
end of iteration 1
iteration 2
end of iteration 2
done
cleanup 2
cleanup 1
```

`errdefer s` runs only when the function **fails**: it returns through `?`, or it returns
(with `return` or as its last value) an `Err` of its `Result` or `None` of its `Option`.
That is the place to undo partial work. An `errdefer` in a function that returns neither is
E0310 (the fix makes it a `defer`).

```eider
fn step(ok: bool) -> Result[i32, str] {
    if ok { Ok(1) } else { Err("step failed") }
}

fn setup(first: bool, second: bool) -> Result[i32, str] uses io {
    print("open")
    errdefer print("close again")
    let a = step(first)?
    let b = step(second)?
    Ok(a + b)
}

fn main() uses io {
    print(setup(true, true))
    print(setup(true, false))
}
```

```output
open
Ok(2)
open
close again
Err("step failed")
```

The deferred statement is any statement: a call, an assignment, a block `defer { ... }`. It
sees the names visible where the `defer` is written, and is checked there (capabilities
too: `defer print(x)` needs `io`). It runs after a `return`'s value is computed, so
`defer` can't change what is returned. It can't leave itself: `return`, `?`, and a `break`
or `continue` of a loop outside it are E0309 (loops inside it are fine). `defer` and
`errdefer` are words only at the start of a statement, before a name or `{`: elsewhere they
are ordinary names.

A trap ends the program at once: deferred statements don't run then (see
[Runtime behaviour](runtime.md#panic-and-assert)).

```eider,compile_fail=E0309
fn first(xs: List[i32]) -> i32 {
    defer { return 0 }
    xs[0]
}

fn main() {}
```

## `assert`

```text
assert_stmt = "assert" expr ["," string]
```

`assert cond` checks a `bool` at run time and traps when it is false, with the message
`assertion failed` or the given string. It is a statement, available in every build, not
only in tests. See [Runtime behaviour](runtime.md#panic-and-assert).

```eider,trap
fn main() uses io {
    let xs = [1, 2, 3]
    assert len(xs) == 3, "three elements"
    assert xs[0] > 1, "the first element is small"
}
```

## Other statements

`let`, assignment, `while`, `for`, `return`, `break`, `continue`, `defer`, `errdefer` and
`assert` are the statement forms; everything else is an expression statement. Items (`fn`, `type`, ...)
can't be declared inside a block.
