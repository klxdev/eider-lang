# Compile-time evaluation

A constant whose initializer is marked `comptime` is computed by running ordinary Eider code
while the program is compiled. The result is spliced into the program as a literal, so at
run time the constant costs nothing. Plain constants (see [Items](items.md#constants)) are
limited to literals and folded integer expressions; `comptime` lifts that limit for the
expression, but not for the type.

```text
const_item = ["pub"] "const" name ":" type "=" "comptime" expr
```

```eider
fn fib(n: u64) -> u64 { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }

fn table_sum() -> i32 {
    let mut xs: List[i32] = List.new()
    for i in 0..10 { xs.push(i * i) }
    let mut s = 0
    for x in xs { s += x }
    s
}

const F20: u64 = comptime fib(20)
const SQUARES: i32 = comptime table_sum()
const LARGE: bool = comptime F20 > 1000

fn main() uses io {
    print(F20)
    print(SQUARES)
    print(LARGE)
}
```

```output
6765
285
true
```

## Types

The constant's type must be an integer type, `bool` or `str`; anything else (`String`, a
tuple, a record) is E0807 ("`comptime` constants must be integers, bool or str"), reported
at the constant's name. The expression itself may use any part of the language that needs
no capability: owned data, records, enums, generics, closures, `match`, `Map`, `Ref`,
functions of imported modules. Negative results are fine.

```eider
const GREETING: str = comptime pick(3)

fn pick(n: i32) -> str {
    if n > 2 { "many" } else { "few" }
}

fn main() uses io { print(GREETING) }
```

```output
many
```

```eider,compile_fail=E0807
const PAIR: (i32, i32) = comptime (1, 2)

fn main() {}
```

## How a constant is evaluated

The comptime constants of a program are evaluated before the program is checked. For each
one the compiler checks an *evaluator program*: the whole program without any `main` and
without test blocks, plus a function that returns the expression. That function is then
run by the compiler's interpreter of its typed IR: no C compiler, no linker and no files
are involved, and the interpreter can reach nothing outside the program. Its value replaces
the expression as a literal, so the rest of the program sees an ordinary constant.

What follows from that:

- **No capabilities.** The evaluator declares none, so calling anything that uses `io`,
  `fs`, `clock` or another capability is E0201, with the help "`comptime` evaluation can't
  use capabilities" (and no fix).
- **Any order.** A comptime constant may use plain constants and comptime constants
  declared before or after it, and so may plain constants and functions. A constant that
  needs another one's value is evaluated after it; while constants are still unevaluated,
  the functions and constants that name them are left out of the evaluator. Constants
  that need each other's values (a cycle) are E0110 ("unknown name"), with a help that says
  so.
- **Errors anywhere surface early.** An error elsewhere in the program is found by the
  evaluator and reported as it is.

```eider,compile_fail=E0201
fn noisy() -> i32 uses io {
    print("hi")
    1
}

const N: i32 = comptime noisy()

fn main() {}
```

```eider
const A: i32 = comptime C / 10 - 1
const B: i32 = A * 2

fn scaled() -> i32 { B + C }

fn main() uses io {
    print(A)
    print(scaled())
}

const C: i32 = comptime 3 * 10
```

```output
2
34
```

```eider,compile_fail=E0110
const A: i32 = comptime B + 1
const B: i32 = comptime A * 2

fn main() {}
```

## Traps and failures

If the evaluation traps (overflow, a bounds check, division by zero, `panic`, a failed
`assert`, `unwrap` of `None`), the constant is E0807 "comptime evaluation of `N` failed:"
followed by the message the built program would print; the file is named `program` when
the trap is in the file being evaluated:

```eider,compile_fail=E0807
fn check(n: i32) -> i32 {
    if n > 3 { panic("too big") }
    n
}

const N: i32 = comptime check(5)

fn main() {}
```

(The message is "comptime evaluation of `N` failed: eider: runtime error: too big
(program:2)".) A literal that doesn't fit the constant's type, or a constant expression
that overflows while it is folded, is reported before evaluation, as for a plain constant
(E0501).

Calls nest at most 1,000 deep during evaluation; deeper recursion is the runtime's stack
overflow message ("eider: runtime error: stack overflow (program:0)"). An evaluation that
runs more than a billion IR statements stops with E0807 too. A value of a type with its own
`Drop` can't be made during evaluation (`Drop` doesn't run at compile time), and neither can
threads.

When a constant fails, the program's other comptime constants are still evaluated and
every error is reported; uses of the failed constant report nothing more.

## Cost

Each comptime constant costs one check of the program and an interpretation of its
expression: tens of microseconds for most constants (`tests/run/comptime.ei`'s four
constants check in about 10 ms, against 0.8 s when every constant was built with the C
compiler). Comptime evaluation needs no C compiler, so `eiderc check` works without one.

> **Note:** Comptime reflection over types, for code generation from a type's fields and
> attributes, is planned. See the [roadmap](../../design/roadmap.md) (P0.9).
