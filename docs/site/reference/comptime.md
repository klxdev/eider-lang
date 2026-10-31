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

The constant's type must be an integer type or `bool`; anything else (`str`, `String`, a
tuple, a record) is E0807 ("`comptime` constants must be integers or bool"), reported at the
constant's name. The expression itself may use any part of the language that needs no
capability: owned data, records, enums, generics, closures, `match`, functions of imported
modules. Negative results are fine.

```eider,compile_fail=E0807
const NAME: str = comptime "eider"

fn main() {}
```

## How a constant is evaluated

The comptime constants of a program are evaluated one at a time, in item order (imported
modules' in load order), before the program is checked. For each one the compiler builds an
*evaluator program*: the whole program without any `main`, without test blocks and without
the comptime constants not yet evaluated, plus a function that returns the expression and a
`main` that prints it. The evaluator is checked, compiled with the C compiler and run; its
output replaces the expression as a literal, so later constants and the rest of the program
see an ordinary constant.

What follows from that:

- **No capabilities.** The evaluator's `main` declares none, so calling anything that uses
  `io`, `fs`, `clock` or another capability is E0201, with the help "`comptime` evaluation
  can't use capabilities" (and no fix).
- **Earlier constants only.** A comptime constant may use plain constants and the comptime
  constants declared before it. Naming a later comptime constant is E0110 ("unknown name"),
  and so is naming it in *any* function of the program that is included in an earlier
  constant's evaluator, even one the constant doesn't call. `main` and test blocks are left
  out of evaluators, so they may name any comptime constant.
- **Plain constants can't use comptime constants.** A `const` without `comptime` whose
  initializer names a comptime constant is E0110: plain constants are checked inside every
  evaluator, where the comptime constants are missing. Mark it `comptime` too.
- **Errors anywhere surface early.** An error elsewhere in the program is found by the first
  evaluator and reported as it is.

```eider,compile_fail=E0201
fn noisy() -> i32 uses io {
    print("hi")
    1
}

const N: i32 = comptime noisy()

fn main() {}
```

```eider,compile_fail=E0110
const A: i32 = comptime 2
const B: i32 = A + 1

fn main() {}
```

```eider
const A: i32 = comptime 2
const B: i32 = comptime A + 1

fn main() uses io {
    print(B)
    print(C)
}

const C: i32 = comptime B * 10
```

```output
3
30
```

## Traps and failures

If the evaluator traps (overflow, a bounds check, division by zero, `panic`, a failed
`assert`, `unwrap` of `None`), the constant is E0807 "comptime evaluation of `N` failed:"
followed by the trap's message; the file is named `program` when the trap is in the file
being evaluated:

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

When a constant fails, the program's other comptime constants are still evaluated and
every error is reported; uses of the failed constant report nothing more.

## Cost

Each comptime constant costs one check of the whole program plus a C compile and link of
its evaluator (tens of milliseconds each). The evaluator is built with the same `$CC` and
`$EIDER_CFLAGS` as the program, so a C compiler is needed at compile time; with the build
cache on, an unchanged constant's evaluator is a cache hit.

> **Note:** Evaluation by an interpreter of the compiler's IR, which would need no C
> compiler at compile time and could lift the restrictions above (other constant types,
> forward references), and comptime reflection over types for code generation are planned.
> See the [roadmap](../../design/roadmap.md) (8.11, P0.9).
