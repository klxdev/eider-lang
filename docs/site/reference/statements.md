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
```

`let` declares a variable and initializes it; every variable is initialized (there is no
`let x: i32` without a value). The type annotation is optional when the initializer's type
is known; it is needed for `List.new()`, `Map.new()`, `None` and the like (E0409).

- `let x = e` binds a name that can't be assigned to or mutated through (E0303). When `e`
  is a *place* (a variable, a field, an element: `orders[i].items`), `x` is a read-only
  reference to that place and sees later writes to it; otherwise `x` owns the fresh value.
- `let mut x = e` declares a mutable variable. Of a fresh value it is an ordinary mutable
  local. Of a place it is a *mutable alias*: writes through `x` change the place. The place
  must be writable (E0307 otherwise; take a `.copy()`).
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

### `var` (deprecated)

`var x = e` declares a mutable variable that always holds its own copy of `e` (the meaning
`let` had before references). It still works; new code writes `let mut x = e` for a fresh
value and `let mut x = e.copy()` for a copy of a place. `eiderc migrate-var <file>` prints a
file with its `var`s rewritten that way. See [Memory model](memory.md#var-deprecated).

## Assignment

```text
assign_stmt = place assign_op expr
assign_op   = "=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&=" | "|=" | "^=" | "<<=" | ">>="
```

The left side is a place rooted at a writable variable: a `let mut` (or `var`) variable,
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

A Map is iterated over a snapshot of its entries taken when the loop starts, so the body
may insert and remove. A List is read again at each iteration: elements the body pushes are
visited too.

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

`let`, assignment, `while`, `for`, `return`, `break`, `continue` and `assert` are the
statement forms; everything else is an expression statement. Items (`fn`, `type`, ...)
can't be declared inside a block.
