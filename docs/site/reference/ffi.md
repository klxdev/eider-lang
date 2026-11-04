# C interop (FFI)

Eider compiles to C11, and talks to C in both directions: it can call C functions
declared with `extern "c"`, and it can export functions to C (and C++) as a static and a
shared library with a header. Everything that crosses the boundary is restricted to types
C can represent without Eider's ownership rules: integers, `bool` and `str`, plus records
of those for exports.

## Declaring C functions

```text
extern_fn = ["pub"] "extern" "\"c\"" "fn" name "(" params ")" ["->" type] ["uses" caps]
```

An `extern "c"` function is declared without a body (a body is E0001). The ABI string must
be `"c"`. The function's name is the C symbol it calls; extern names are global, not
qualified by their module, so two declarations of one symbol in a program are E0107.

The parameter and result types must be *C-safe* (E0803 otherwise):

- each parameter is an integer type, `f32`, `f64`, `bool` or `str`, and not `inout`
  (`f32` is `float`, `f64` is `double`);
- the result is one of those, or `()` (no `->`);
- a parameter may also be a `List[u8]`, plain or `inout`: C receives a pointer to the bytes
  and the length, two parameters (`const uint8_t *p, uint64_t n`; for `inout`, `uint8_t *p,
  uint64_t n`, which C may write). Eider never sees the pointer, and an `inout` list is first
  made the caller's own, so the bytes C writes are nobody else's. An `export` can't take a
  List (E0803). It is what the core uses to move data across in one call (core/ABI.md "Bulk
  transfer").

The program is linked with the C library; other libraries are added with `-l <lib>` on
`eiderc build`, `run` and `test` (repeatable). A declared function that nothing defines is a
link error, reported by the C toolchain.

## Calling C: `uses ffi` and `unsafe`

A call to an extern function needs both:

1. the `ffi` capability in the calling function's `uses` (E0201, with a fix), and
2. an `unsafe` context: an `unsafe { ... }` block around the call, or an `unsafe fn` (E0802).

`unsafe` is lexical: it covers the calls written inside the block, including inside a
closure written in the block. An `unsafe { ... }` block is an expression whose value is its
last expression, subject to the same positions rule as other blocks (as a statement, a final
expression, a call argument, or the right side of `let`, `=` or `return`; E0103 elsewhere).

```eider
extern "c" fn abs(n: i32) -> i32
extern "c" fn strlen(s: str) -> usize
extern "c" fn atoi(s: str) -> i32

fn main() uses io, ffi {
    let a = unsafe { abs(-42) }
    let n = unsafe { strlen("eider") }
    let v = unsafe { atoi("1234") }
    print(a)
    print(n)
    print(v + 1)
}
```

```output
42
5
1235
```

```eider,compile_fail=E0802
extern "c" fn abs(n: i32) -> i32

fn main() uses io, ffi {
    print(abs(-1))
}
```

### `unsafe fn`

`unsafe fn` declares a function whose body is an `unsafe` context; calling it needs an
`unsafe` context in turn (E0802), in every package (unlike `ffi`, `unsafe` doesn't stop at
a package boundary). Use it for a wrapper whose safety depends on its caller; otherwise
wrap the call in a safe function with an `unsafe` block inside, as std and core do.

```eider
extern "c" fn toupper(c: i32) -> i32

unsafe fn upper(c: u8) -> u8 uses ffi {
    toupper(c as i32) as u8
}

fn shout(c: u8) -> u8 uses ffi {
    unsafe { upper(c) }
}

fn main() uses io, ffi {
    print(shout(97))
}
```

```output
65
```

### `ffi` across packages

Inside a package, `ffi` propagates like any capability: `shout` above makes `main` declare
`ffi`. Across a package boundary it doesn't: a program calling core's or std's wrappers
needs only their real capabilities (`fs`, `io`, ...). A package with unmanaged code (an
`extern`, an `unsafe fn` or an `unsafe` block) must instead be granted `ffi` by the packages
that depend on it, in their `eider.toml` (E0204). See
[Capabilities](capabilities.md#ffi-stays-inside-its-package).

> **Note:** An extern function or an `unsafe fn` can't be used as a function value yet
> (`let f: fn(i32) -> i32 = abs` is reported as not supported): checking only declared
> capabilities would let the value be called with neither `unsafe` nor `ffi`. It waits for
> a language decision; see the [roadmap](../../design/roadmap.md).

## Exporting functions

```text
export_fn = ["pub"] "export" fn_item
```

`export fn` makes a function callable from C. An exported function:

- can't be generic (E0805);
- takes and returns C-safe types: integers, `f32`, `f64`, `bool`, `str`, `()` as the result, and records
  whose fields are C-safe (recursively), passed by value (E0803 otherwise). A record with
  its own `Drop` can't cross (E0803);
- is otherwise an ordinary function, callable from Eider as well.

`eiderc emit-header <file.ei>` prints the C header; `eiderc build --lib <file.ei> -o name`
builds `libname.a`, `libname.so` and `name.h`, printing `built libname.a, libname.so,
name.h`. A library has no `main` (one is not required, and is ignored) and needs at least
one `export fn` (E0805 at 1:1). The library contains the Eider runtime and the C core, so a
consumer links only it.

```eider
type Vec2 = { x: i32, y: i32 }

export fn add(a: i32, b: i32) -> i32 { a + b }

export fn dot(a: Vec2, b: Vec2) -> i64 {
    (a.x as i64) * (b.x as i64) + (a.y as i64) * (b.y as i64)
}

export fn is_even(n: u32) -> bool { n % 2 == 0 }

export fn greeting() -> str { "hello from eider" }

fn main() uses io {
    print(dot(Vec2(1, 2), Vec2(3, 4)))
}
```

```output
11
```

`eiderc emit-header` prints for it:

```c
/* generated by eider: C interface */
#ifndef EIDER_MATHLIB_H
#define EIDER_MATHLIB_H
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct R_Vec2 R_Vec2;
struct R_Vec2 { int32_t f_x; int32_t f_y; };
int32_t eider_add(int32_t a, int32_t b);
int64_t eider_dot(R_Vec2 a, R_Vec2 b);
bool eider_is_even(uint32_t n);
const char* eider_greeting(void);
#ifdef __cplusplus
}
#endif
#endif
```

and a C program uses it as:

```c
#include <stdio.h>
#include "mathlib.h"

int main(void) {
    R_Vec2 a = { 1, 2 }, b = { 3, 4 };
    printf("%d %lld\n", eider_add(40, 2), (long long)eider_dot(a, b));
    return 0;
}
```

The full example, with C and C++ consumers linked statically and dynamically, is in
`tests/export/` (`mathlib.ei`, `driver.c`, `run.sh`).

### Names and the type mapping

The C function for `export fn f` in the entry module is `eider_f`; for a function of an
imported module it is `eider_<module>__f` (`eider_units__twice`). A record `R` becomes
`struct R_R` with a typedef `R_R`, and its fields `f_<name>`.

| Eider | C |
|---|---|
| `i32`, `i64` | `int32_t`, `int64_t` |
| `u8`, `u32`, `u64` | `uint8_t`, `uint32_t`, `uint64_t` |
| `usize` | `uint64_t` |
| `bool` | `bool` (`<stdbool.h>`) |
| `str` | `const char *` (NUL-terminated; neither side frees it) |
| `()` result | `void` |
| record of C-safe fields | `struct R_<name>`, by value |

A trap inside an exported function (an overflow, a failed bounds check, a `panic`) prints
`eider: runtime error: <msg> (lib:<line>)` and exits the process with 101, as in an Eider
program; there is no unwinding into C.

> **Note:** A header's include guard is `EIDER_<NAME>_H`, from the library's name (`-o`'s
> file name, else the source's stem; upper case, other bytes than letters and digits as `_`),
> so the headers of two Eider libraries can be included in one C file; two libraries that
> export records of the same name still clash (`R_<name>`). The symbol declarations work on ELF
> platforms (Linux); Mach-O needs a leading `_` and is untested.

## WebAssembly

`eiderc build --wasm <file.ei> [-o name]` compiles the program as a library to WebAssembly
(with clang's wasm32 target and wasm-ld) and writes `name.wasm`, `name.d.ts` and a JS
loader `name.js`. `check --wasm` and `emit-header --wasm` check and describe it. Exports
are more restricted (E0806, checked only with `--wasm`):

- parameters are integers or `bool`; the result is an integer, `bool` or `()`;
- the program may not use threads (`spawn`, `Task`, `Mutex`, `Chan`; reported at 1:1).

Output goes through the host (`print` calls the loader's write function), and a trap
becomes a wasm `unreachable` after its message is printed.

> **Note:** Strings and records across the WebAssembly boundary are not supported yet. The
> generated loader passes `u32` results above the signed range back as negative numbers and
> `u64`/`usize` ones as negative BigInts, and an export parameter named `x` breaks it.
