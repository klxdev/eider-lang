# Numbers: integers and floats

Eider has six integer types and two float types. This page is about choosing between them and
about the places where floats surprise people. The precise rules are in the
[types reference](../reference/types.md#floating-point-f32-and-f64).

## Which one

- Counts, sizes, indices, money in cents, identifiers: **integers**. They are exact, they trap
  on overflow, and they have `Ord` and `Hash`, so they sort and key maps.
- Measurements, ratios, coordinates, durations in seconds, anything from JSON that has a
  fractional part: **`f64`**. Use **`f32`** when memory or a C/GPU interface asks for it.
- Money in a float is a bug waiting to happen (`0.1 + 0.2` is not `0.3`). Keep cents in an
  `i64`. (`Decimal` and `BigInt` are not in the language yet.)

```eider
import std.math

fn main() uses io {
    let cents: i64 = 1999
    let price = (cents as f64) / 100.0
    print("{price:.2}")
    let a = 0.1 + 0.2
    print(a == 0.3)
    print((a - 0.3).abs() < 1e-9)
}
```

```output
19.99
false
true
```

A float is compared with a tolerance, not with `==`, unless it is a value you stored and
compare unchanged.

## No mixing, and no surprises on conversion

`1.5 * n` with an integer `n` is an error, and so is `let x: f64 = 1`: write `n as f64` and
`1.0`. `as` between integers and floats is checked like every conversion in Eider: a float that
is a NaN or too large for the integer type **traps** (`float conversion out of range`) instead
of saturating, as Rust's `as` does, or being undefined, as C's cast is. When the value comes
from outside, ask first:

```eider
import std.math

fn main() uses io {
    let inputs = [3.9, -2.5, 1e20, 0.0 / 0.0]
    for x in inputs {
        match x.to_i32() {
            Some(n) => print("{x} -> {n}")
            None => print("{x} does not fit")
        }
    }
}
```

```output
3.9 -> 3
-2.5 -> -2
1e20 does not fit
NaN does not fit
```

## NaN, and why floats do not sort

Every comparison with a NaN is false, so `NaN != NaN`, and no order is total. That is why
floats have `==`, `<` and the rest, but no `Ord` and no `Hash`: `sort` on a `List[f64]` and a
`Map[f64, _]` are compile errors that say so, rather than quietly misbehaving. Sort with the
total order (`NaN` last), and ignore NaN in a maximum with `max`:

```eider
import std.math
import std.sort

fn main() uses io {
    var xs: List[f64] = List.new()
    xs.push(2.5)
    xs.push(0.0 / 0.0)
    xs.push(-1.0)
    xs.push(7.0)
    let sorted = sort.sort_by(xs, |a: f64, b: f64| -> Ordering a.total_cmp(b))
    print(sorted)
    var best = xs[0]
    for x in xs { best = best.max(x) }
    print(best)
}
```

```output
[-1.0, 2.5, 7.0, NaN]
7.0
```

## Printing and parsing

`print` writes the shortest text that reads back as the same number (`0.1`, `1e16`,
`1.5e-7`), the same on every machine and in every locale. `{x:.2}` fixes the number of places
(rounded half to even, from the exact value): `{x:.2}`, `{x:8.3}`, `{x:+.1}`, `{x:08.2}`.
`strings.parse_f64("1.5e3")` goes the other way and is exact: the nearest `f64`, whatever the
digits.

## Math

`import std.math` adds methods (`sqrt`, `pow`, `sin`, `ln`, `floor`, `round`, `abs`, `min`,
`max`, `clamp`, `is_nan`, `to_bits`, ...) and constants (`math.PI`). They call libm through the
core and need no capability. In a WebAssembly module `sqrt` and `floor` are instructions and
the rest come from JavaScript's `Math`.
