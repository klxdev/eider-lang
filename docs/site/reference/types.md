# Types

Every value has one static type, known at compile time. There are no implicit conversions
between types: an `i32` is never silently widened to an `i64`, and a `str` is never
silently turned into a `String`. This page describes every type the language has, the
built-in operations on each, and the `as` conversion.

| Kind | Types |
|---|---|
| Integers | `i32`, `i64`, `u8`, `u32`, `u64`, `usize` |
| Booleans | `bool` |
| Text | `str` (literals), `String` (owned, growable) |
| Unit | `()` |
| Composite | records, enums (see [Items](items.md)), tuples `(A, B)`, arrays `[T; N]` |
| Containers | `List[T]`, `Map[K, V]`, `Box[T]` |
| Functions | `fn(A, B) -> R`, `fn(inout A) -> R` |
| Prelude | `Option[T]`, `Result[T, E]`, `Ordering` |
| Handles | `Ref[T]` ([Memory model](memory.md#reft)), `Task[T]`, `Mutex[T]`, `Chan[T]` ([Concurrency](concurrency.md)) |

Type names are ordinary identifiers, not keywords: `i32`, `String` and `List` are names the
compiler knows. A type with parameters is written with square brackets: `List[i32]`,
`Map[String, List[u8]]`.

> **Note:** There are no floating-point types (`f32`, `f64`), no `i8`, `i16`, `u16`, `i128`,
> `u128` or `isize`, no `char` type and no `dyn Trait`. Floats and `dyn Trait` are planned;
> see the [roadmap](../../design/roadmap.md) (`layer/language`, P0.7).

## Integer types

| Type | Range | C type |
|---|---|---|
| `i32` | -2147483648 to 2147483647 | `int32_t` |
| `i64` | -9223372036854775808 to 9223372036854775807 | `int64_t` |
| `u8` | 0 to 255 | `uint8_t` |
| `u32` | 0 to 4294967295 | `uint32_t` |
| `u64` | 0 to 18446744073709551615 | `uint64_t` |
| `usize` | 0 to 18446744073709551615 | `uint64_t` (64 bits on every target) |

`usize` is the type of lengths and indices: `len()` returns a `usize` and `xs[i]` needs
`i: usize`.

### Integer literals

An integer literal has no suffix; its type comes from where it is used:

1. the expected type, when there is one: the annotation of a `let`, the parameter type of a
   call, the field type of a constructor, the return type, the target of `as`;
2. otherwise, as an operand of a binary operator, the type of the other operand;
3. otherwise `i32`.

A literal that doesn't fit the type it gets is an error (E0501), not a wrap:

```eider
fn main() uses io {
    let a = 7               // i32
    let b: u8 = 200         // u8 from the annotation
    let c: u64 = 1 << 40    // both operands u64
    let n: usize = 3
    let d = n + 1           // 1 takes n's type, usize
    print(a)
    print(b)
    print(c)
    print(d)
}
```

```output
7
200
1099511627776
4
```

```eider,compile_fail=E0501
fn main() uses io {
    let big = 3000000000    // doesn't fit in i32
    print(big)
}
```

Hexadecimal and `_` separators are described in [Lexical structure](lexical.md).

### Arithmetic and overflow

The operators are listed in [Expressions](expressions.md). Both operands of a binary
arithmetic, bitwise or comparison operator must have the same type (E0401 otherwise, with a
help suggesting `as`).

Arithmetic is checked in every build, debug and release alike:

- `+`, `-`, `*` trap with `integer overflow in +` (`-`, `*`) when the exact result doesn't
  fit the type.
- `/` truncates toward zero; `%` has the sign of the left operand. Both trap on a zero
  divisor (`division by zero`, `remainder by zero`) and, for signed types, on `MIN / -1`
  and `MIN % -1` (`integer overflow in /`, `%`).
- Unary `-` exists only for signed types (E0401 on an unsigned one) and traps on `MIN`
  (`integer overflow in negation`).
- `+%`, `-%`, `*%` wrap: the result is the exact result modulo 2^bits, in two's complement.
  There is no wrapping division and no compound form `+%=`.
- Bitwise `&`, `|`, `^`, `~` act on the two's-complement bits and never trap. `<<` drops the
  bits shifted out (it doesn't trap on them); `>>` is arithmetic (sign-filling) on signed
  types and logical on unsigned ones. A shift count must be at least 0 and less than the
  width in bits; otherwise it traps (`shift count out of range`). The count has the same
  type as the shifted value.

When every operand is a constant, the operation is folded at compile time, and an overflow,
a zero divisor or a bad shift count is a compile error instead (E0501, E0502, E0505).

```eider
fn main() uses io {
    let a: u8 = 250
    print(a +% 10)      // 260 mod 256
    let b: i32 = -7
    print(b / 2)
    print(b % 2)
    print(b >> 1)       // arithmetic shift
    print(~b)
}
```

```output
4
-3
-1
-4
6
```

```eider,trap
fn main() uses io {
    let a: u8 = 3
    let b: u8 = 5
    print(a - b)        // integer overflow in -
}
```

See [Runtime behaviour](runtime.md#traps) for what a trap does.

### Comparison

All integer types have `==`, `!=`, `<`, `<=`, `>`, `>=`, by value. Comparisons don't chain:
`a < b < c` compares a `bool` with `c` and is E0401.

## `bool`

`true` and `false`. The operators are `!`, `&&` and `||` (short-circuiting) and the
comparisons; `false < true`. Conditions of `if`, `while` and `assert` must be `bool`: there
is no truthiness. `bool` doesn't convert to an integer with `as` (E0401); write
`if b { 1 } else { 0 }`.

## Text: `str` and `String`

Both hold UTF-8 text without NUL bytes.

- `str` is the type of string literals. It is an immutable, NUL-terminated C string
  (`const char *`), cheap to pass around. Its length is computed when asked for (O(n)).
- `String` is owned, growable text with a length and a capacity, copied on write (see
  [Copy-on-write](memory.md#copy-on-write)).

A `str` is not a `String`: `let s: String = "x"` is E0401. Convert with `String.from("x")`
or `"x".to_string()`.

**A String is always valid UTF-8 and never contains a NUL byte.** Every operation keeps
that true: `String.from_bytes` checks the bytes, `slice` only cuts at character boundaries,
`push_byte` only appends ASCII, and string literals can't contain NUL (see
[Lexical structure](lexical.md#string-literals)). Bytes that may include 0 belong in a
`List[u8]`.

Methods (`s` a `String`, `t` a `str`; byte offsets are `usize`):

| Call | Type | On | Does |
|---|---|---|---|
| `String.from(t)` | `String` | | a new String from a str |
| `String.from_int(n)` | `String` | | decimal text of an `i64` |
| `String.from_bytes(bytes)` | `Result[String, usize]` | | `bytes: List[u8]`; `Err(i)` is the offset of the first byte that isn't valid UTF-8 or is 0 |
| `x.len()`, `len(x)` | `usize` | both | length in bytes |
| `x.is_empty()` | `bool` | both | |
| `x.byte(i)` | `u8` | both | byte i; traps `index out of bounds` |
| `x.slice(a, b)` | `String` | both | bytes a to b (exclusive) as a new String; traps `slice out of bounds` unless `a <= b <= len`, `slice not on a character boundary` inside a UTF-8 sequence |
| `x.bytes()` | `List[u8]` | both | a copy of the bytes |
| `x.to_string()` | `String` | both | (the `Show` text: the text itself) |
| `s.push_str(t)` | `()` | String | appends a `str` |
| `s.append(u)` | `()` | String | appends a `String` |
| `s.push_byte(b)` | `()` | String | appends an ASCII byte (1 to 127); traps otherwise, E0506 for a constant |

The mutating methods need a writable place (a `let mut` variable, a field of one, an
`inout` parameter; E0303 otherwise). There is no `+` on text (E0401): build text with
`push_str` and `append`, or std's [strings](api:std/strings) and [fmt](api:std/fmt).

`==` and `!=` compare the bytes; `<`, `<=`, `>`, `>=` compare bytes lexicographically,
which for UTF-8 is Unicode scalar value order. Both operands have the same type: compare a
`str` with a `String` by converting one.

```eider
fn main() uses io {
    let mut s = String.from("caf")
    s.push_str("\u{e9}")
    s.push_byte(33)
    print(s)
    print(s.len())
    print(s.byte(0))
    print(s.slice(0, 3))
    print("abc" < "abd")
    print(s == String.from("café!"))
    match String.from_bytes(s.bytes()) {
        Ok(t) => print(t)
        Err(at) => print(at)
    }
}
```

```output
café!
6
99
caf
true
true
café!
```

```eider,trap
fn main() uses io {
    let s = String.from("é")
    print(s.slice(0, 1))    // inside the two bytes of é
}
```

## The unit type `()`

`()` is the type with one value, also written `()`. A function without `->` returns `()`;
`return` and `return ()` are the same. `()` is a value where a type parameter needs one:
`Ok(())`, `Some(())`, `Result[(), E]`, `Task[()]`.

`()` is not an ordinary value type, though: a `let` can't bind it (`cannot bind a value of
type ()`, E0401), a parameter can't have it (E0111), and `List[()]` or `Box[()]` are
refused. Two `()` values can't be compared directly (E0401).

```eider
fn check(n: i32) -> Result[(), String] {
    if n < 0 { return Err(String.from("negative")) }
    Ok(())
}

fn main() uses io {
    print(check(1))
    print(check(-1))
}
```

```output
Ok(())
Err("negative")
```

## Tuples

`(A, B, ...)` groups values of fixed types. A one-element tuple is written `(A,)` (type and
value); `(A)` is just `A` in parentheses. Elements are read with `.0`, `.1`, ...; an index
past the end is E0113. Tuples are taken apart with patterns (`let (a, b) = t`, see
[Patterns](patterns.md)).

```eider
fn divmod(a: i32, b: i32) -> (i32, i32) { (a / b, a % b) }

fn main() uses io {
    let t = divmod(17, 5)
    print(t.0)
    let (q, r) = t
    print(q * 5 + r)
    print((5,))
    print((1, "one", true))
}
```

```output
3
17
(5,)
(1, "one", true)
```

## Arrays

`[T; N]` is a fixed-size sequence of N values of type T, stored inline (copied by value).
N is an integer literal, at least 1 (E0111 for 0). Array literals are `[a, b, c]` and
`[x; N]` (N copies of x; x can't own heap memory, E0401). An array literal is never a
`List`: `let l: List[i32] = [1, 2]` is E0401.

Indexing `a[i]` needs `i: usize` and is bounds-checked: a constant index out of range is
E0503, a variable one traps `index out of bounds`. Elements of a writable array can be
assigned (`a[i] = v`). `len(a)` gives N (arrays have no methods besides the trait ones: no `.len()`). `for x in a` iterates the elements.
Arrays have none of the List methods (`push`, `map`, `fold`, ...).

```eider
fn main() uses io {
    let mut a = [10, 20, 30]
    a[0] = 5
    print(a)
    print(len(a))
    let z: [u8; 4] = [0; 4]
    print(z)
}
```

```output
[5, 20, 30]
3
[0, 0, 0, 0]
```

## `List[T]`

A growable sequence, stored on the heap and copied on write. `List.new()` makes an empty
List; its element type must be known from the context (E0409 otherwise). Indexing `xs[i]`
(`i: usize`) is bounds-checked at run time; elements of a writable List can be assigned.

| Call | Type | Does |
|---|---|---|
| `List.new()` | `List[T]` | an empty List (needs an annotation or another use that fixes T) |
| `xs.len()`, `len(xs)` | `usize` | |
| `xs.is_empty()` | `bool` | |
| `xs.get(i)` | `T` | a copy of element i (traps out of bounds), the same as `xs[i]` |
| `xs.contains(x)` | `bool` | needs `T: Eq` |
| `xs.push(x)` | `()` | appends |
| `xs.pop()` | `Option[T]` | removes the last element |
| `xs.clear()` | `()` | removes every element |
| `xs.map(f)` | `List[U]` | `f: fn(T) -> U` |
| `xs.filter(f)` | `List[T]` | `f: fn(T) -> bool` |
| `xs.for_each(f)` | `()` | `f: fn(T)` |
| `xs.any(f)`, `xs.all(f)` | `bool` | `f: fn(T) -> bool` |
| `xs.fold(init, f)` | `A` | `f: fn(A, T) -> A` |
| `xs.sum()` | `T` | integers only; traps on overflow |

`push`, `pop` and `clear` need a writable place. Two Lists are equal when they have equal
elements in the same order; Lists compare lexicographically, then by length; they print as
`[1, 2]`. Sorting is in std ([sort](api:std/sort)), as are other
collections ([deque](api:std/deque), [set](api:std/set), [heap](api:std/heap)).

```eider
fn main() uses io {
    let mut xs: List[i32] = List.new()
    xs.push(3)
    xs.push(4)
    xs.push(5)
    print(xs.map(|x| x * 2))
    print(xs.filter(|x| x > 3))
    print(xs.fold(0, |acc, x| acc + x))
    print(xs.pop())
    print(xs)
}
```

```output
[6, 8, 10]
[4, 5]
12
Some(5)
[3, 4]
```

## `Map[K, V]`

A hash table from keys to values, on the heap and copied on write. The key type must have
`Hash` and `Eq` (E0701 otherwise): integers, `bool`, `str`, `String`, and records, enums,
tuples, arrays and Lists made of them. Maps, fn values, handles and `Ref`s can't be keys.

| Call | Type | Does |
|---|---|---|
| `Map.new()` | `Map[K, V]` | an empty Map (needs an annotation) |
| `m.len()`, `len(m)`; `m.is_empty()` | `usize`; `bool` | |
| `m.insert(k, v)` | `()` | adds or replaces |
| `m.get(k)` | `Option[V]` | a copy of the value |
| `m.contains(k)` | `bool` | |
| `m.remove(k)` | `bool` | whether the key was there |
| `m.keys()`, `m.values()`, `m.entries()` | `List[K]`, `List[V]`, `List[(K, V)]` | copies |

`for (k, v) in m` iterates the pairs (see [Statements](statements.md#for)). Keys, values,
entries, `for` and printing all visit the pairs in one order: the order of the table's
slots. It is the same on every run for the same history of inserts and removes, but it is
neither sorted nor insertion order; sort the keys when the order matters. Two Maps are
equal when they have the same keys with equal values, whatever their order. Maps have no
`<` and no hash.

Values in a Map are not places: `m.get(k)` returns a copy, and the way to change a value is
`m.insert(k, new)`.

```eider
fn main() uses io {
    let mut ages: Map[String, i32] = Map.new()
    ages.insert(String.from("ada"), 36)
    print(ages.get(String.from("ada")))
    print(ages.get(String.from("bob")))
    print(ages.contains(String.from("ada")))
    print(ages.remove(String.from("ada")))
    print(ages.len())
}
```

```output
Some(36)
None
true
true
0
```

## `Box[T]`

A single value on the heap, copied on write. Its use is recursive types: a record can't
contain itself by value (E0108), but it can contain a `Box` of itself, or a `List` or
`Option[Box[...]]`.

| Call | Type | Does |
|---|---|---|
| `Box.new(v)` | `Box[T]` | |
| `b.get()` | `T` | a copy of the contents |
| `b.set(v)` | `()` | replaces the contents (needs a writable place) |

Box compares, hashes and prints by its contents (`Box(6)`).

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

## Function types

`fn(A, B) -> R` is the type of a function value taking an A and a B and returning an R;
`fn(A)` returns `()`. Named functions and closures (see
[Expressions](expressions.md#closures)) are function values. A parameter of a fn type may be
`inout` (`fn(inout List[i32])`); only closures make such values (a named function with
`inout` parameters can't be used as a value, E0304).

A fn type can list the capabilities calling it needs, `fn(A) -> R uses io + fs`, and a
generic function can be polymorphic over them; see
[Capabilities](capabilities.md#function-types-and-capability-parameters).

Function values can be copied, stored and passed, but have no `==`, order, hash or text
(E0401).

```eider
fn twice(f: fn(i32) -> i32, x: i32) -> i32 { f(f(x)) }
fn inc(x: i32) -> i32 { x + 1 }

fn main() uses io {
    print(twice(inc, 1))
    print(twice(|x| x * 3, 1))
    let add: fn(inout i32, i32) = |inout n, k| { n += k }
    let mut total = 1
    add(inout total, 41)
    print(total)
}
```

```output
3
9
42
```

## `Option[T]` and `Result[T, E]`

The prelude ([core/prelude.ei](../../../core/prelude.ei)) defines them as ordinary generic
enums:

```eider,ignore
type Option[T] = | Some(value: T) | None
type Result[T, E] = | Ok(value: T) | Err(error: E)
```

(Shown, not tested: it is the prelude's own text, which a program can't redefine.)

`Some`, `None`, `Ok` and `Err` are in scope everywhere. There is no `null` (`null` is
reserved, E0402): absence is `None`. `None` alone needs its type from the context (E0409).
`?` returns early from a function on `None` or `Err` (see [Expressions](expressions.md#the-question-mark-operator)).

| Method | Option[T] | Result[T, E] |
|---|---|---|
| `is_some()` / `is_none()` | `bool` | |
| `is_ok()` / `is_err()` | | `bool` |
| `unwrap()` | `T`, traps on None | `T`, traps on Err |
| `unwrap_or(d)` | `T` | `T` |
| `map(f)` | `Option[U]` | `Result[U, E]` |
| `and_then(f)` | `f: fn(T) -> Option[U]` | `f: fn(T) -> Result[U, E]` |
| `ok_or(e)` | `Result[T, E]` | |
| `map_err(f)` | | `Result[T, F]` |
| `ok()` | | `Option[T]` |

std/error adds `.context(...)` and `.with_context(...)` ([error](api:std/error); see
[Traits](traits.md)).

```eider
fn half(n: i32) -> Option[i32] {
    if n % 2 == 0 { Some(n / 2) } else { None }
}

fn main() uses io {
    print(half(8))
    print(half(7).unwrap_or(0))
    print(half(8).map(|x| x + 1))
    let r: Result[i32, str] = half(3).ok_or("odd")
    print(r)
}
```

```output
Some(4)
0
Some(5)
Err("odd")
```

## `Ordering`

`type Ordering = | Less | Equal | Greater`, from the prelude; `x.compare(y)` returns one
for any type with `Ord`. See [Traits](traits.md#eq-ord-and-ordering).

## Handles

`Ref[T]`, `Task[T]`, `Mutex[T]` and `Chan[T]` are handles: copying one gives another holder
of the same object, which lives until the last holder goes. `Ref[T]` is described in
[Memory model](memory.md#reft), the thread types in [Concurrency](concurrency.md). Handles
have no `==`, order, hash or text (E0401).

## Type aliases

`type Name = T` (and `type Name[A, B] = T`) gives another name to a type. The alias is
transparent: `Name` and `T` are the same type everywhere, and messages name the type
itself.

- The right side is any type except a record body `{ ... }` or variants `| ...`, which
  declare new types instead (see [Items](items.md)).
- An alias names a type only: it is not a constructor and brings no variant names, and an
  `impl` can't name it (E0111).
- An alias can't refer to itself, directly or through other aliases (E0111); recursion
  through a record or enum is fine.
- Type parameters of an alias take no bounds; a generic alias is checked where it is used.
- `pub type` exports an alias like any type.

```eider
type Id = u64
type Pair[T] = (T, T)
type Handler = fn(i32) -> i32

fn first[T](p: Pair[T]) -> T { p.0 }

fn main() uses io {
    let a: Id = 5
    let b: u64 = a + 1      // the same type
    let h: Handler = |x| x * 2
    print(b)
    print(first((3, 4)))
    print(h(21))
}
```

```output
6
3
42
```

## Conversions: `as`

`e as T` converts an integer to another integer type. It is the only conversion operator,
and it converts integers only: `bool`, text and every other type are refused (E0401).

The conversion is checked: when the value doesn't fit in T it traps with `integer
conversion out of range` (exit 101). It never truncates or reinterprets bits; for that use
the bitwise operators (`(x & 255) as u8`). A constant that doesn't fit is a compile error
(E0501). A literal operand takes T as its type (`255 as u8`).

`as` binds tighter than the binary operators and looser than unary operators:
`-x as i64` is `(-x) as i64`, and `a + b as u64` is `a + (b as u64)`.

```eider
fn main() uses io {
    let n: usize = 7
    let small = n as u32
    let neg: i64 = -1
    print(small)
    print(neg as i32)
    print(255 as u8)
}
```

```output
7
-1
255
```

```eider,trap
fn main() uses io {
    let neg: i32 = -1
    print(neg as u32)       // integer conversion out of range
}
```

## Type inference

Types are inferred locally, from initializers and from the expected type:

- a `let` without an annotation takes its initializer's type;
- generic functions infer their type arguments from the expected type, the receiver and
  the arguments, in that order (see [Traits and generics](traits.md#inference)); there is
  no syntax for explicit type arguments at a call;
- closure parameters take their types from the fn type the closure is passed as;
- `List.new()`, `Map.new()`, `Chan.new()`, `None` and `T.default()` need an expected type.

When a type can't be inferred, the error is E0409, usually with an example annotation in
its help:

```eider,compile_fail=E0409
fn main() uses io {
    let xs = List.new()
    print(len(xs))
}
```
