# Compiler Check Tests (compile-fail suite)

Each safety rule gets a `compile_fail` test: a program that must be rejected, with the exact diagnostic expected. A paired `compile_pass` test guards against over-rejection. The compiler's own test suite runs these on every change, so a rule can't silently stop being enforced.

```
eider test --compile-fail            # run the whole suite
eider test --compile-fail --rule E0301
```

## Test syntax

```eider
compile_fail "name" expect E0301 at 4:3 {
  // program that must be rejected
}

compile_pass "name" {
  // twin that must be accepted
}
```

`expect` checks the code and the span. The message text and fix suggestion are compared against a snapshot (`--bless` updates snapshots).

## 1. Exhaustive match (E0101)

```eider
compile_fail "missing variant" expect E0101 at 3:3 {
  type Box = | Small | Medium | Large
  fn limit(b: Box) -> u32 {
    match b { Small => 1, Medium => 2 }
  }
}
// error[E0101]: non-exhaustive match, `Large` not handled
// fix: insert "  Large => _," before line 4
```

```eider
compile_pass "all variants handled" {
  type Box = | Small | Medium | Large
  fn limit(b: Box) -> u32 {
    match b { Small => 1, Medium => 2, Large => 3 }
  }
}
```

## 2. Missing capability (E0201)

```eider
compile_fail "clock not declared" expect E0201 at 2:3 {
  fn stamp() -> Instant {
    clock.now()
  }
}
// error[E0201]: call to `clock.now` requires capability `clock`
// fix: insert " uses clock" after the return type
```

```eider
compile_fail "capability not propagated" expect E0201 at 5:3 {
  fn stamp() -> Instant uses clock { clock.now() }
  fn caller() {
    stamp()
  }
}
```

## 3. Exclusive access (E0301)

```eider
compile_fail "two inout of same value" expect E0301 at 3:20 {
  fn swap[T](inout a: T, inout b: T) { ... }
  fn f(inout inv: Inventory) { swap(inout inv, inout inv) }
}
// error[E0301]: `inv` is borrowed mutably twice in one call
```

```eider
compile_fail "inout while read-borrowed" expect E0301 at 4:3 {
  fn f(inout inv: Inventory) {
    inv.stock.for_each(|sku, qty| {
      inv.reserve(Line(sku, 1))
    })
  }
}
// error[E0301]: `inv.stock` is being read by the closure's caller
```

## 4. No stored references (E0302)

```eider
compile_fail "inout in a field" expect E0302 at 1:22 {
  type Cache = { inv: inout Inventory }
}
// error[E0302]: `inout` is only valid on parameters; values can't hold references
// help: store a `Shared[Mutex[Inventory]]` or an index into a List

compile_fail "inout escapes in closure" expect E0302 at 3:12 {
  fn f(inout o: Order) -> fn() -> u8 {
    return || o.priority
  }
}
```

## 5. Mutability (E0303)

```eider
compile_fail "assign to let" expect E0303 at 3:3 {
  fn f() {
    let n = 1
    n = 2
  }
}
// fix: replace "let" with "var" on line 2

compile_fail "mutate through read-only self" expect E0303 at 2:5 {
  impl Inventory {
    fn bump(self, sku: Sku) { self.stock[sku] += 1 }
  }
}
// fix: change `self` to `inout self`
```

## 6. Types: no implicit conversions (E0401)

```eider
compile_fail "narrowing" expect E0401 at 2:18 {
  fn f(x: i64) -> i32 {
    let y: i32 = x
    return y
  }
}
// error[E0401]: expected i32, found i64
// help: use `x.try_into[i32]()?` or `x.trunc[i32]()`

compile_fail "distinct newtype" expect E0401 at 2:14 {
  fn f(inv: Inventory) { inv.lookup("A-100") }
}
// error[E0401]: expected Sku, found str
// fix: wrap with Sku("A-100")

compile_fail "mixed int widths" expect E0401 at 2:12 {
  fn f(a: u8, b: u32) -> u32 { a + b }
}
```

## 7. No null, results must be handled (E0402, E0403)

```eider
compile_fail "null literal" expect E0402 at 2:16 {
  fn f() -> Item {
    var x: Item = null
    return x
  }
}
// error[E0402]: `null` doesn't exist; use Option[Item]

compile_fail "ignored Result" expect E0403 at 2:3 {
  fn f(inout inv: Inventory) {
    inv.reserve(Line(Sku("A"), 1))
  }
}
// error[E0403]: unused `Result[(), FulfillError]`
// fix: append `?`, or bind with `let _ =` to discard explicitly
```

## 8. Integer overflow (E0501)

Runtime arithmetic traps. A constant expression that provably overflows is a compile error.

```eider
compile_fail "constant overflow" expect E0501 at 1:15 {
  const BIG: u8 = 200 + 100
}
// error[E0501]: 300 doesn't fit in u8

compile_fail "comptime overflow" expect E0501 at 4:5 {
  comptime fn f() -> u32 {
    var n: u32 = 4_000_000_000
    n + n
  }
  const X = f()
}

compile_pass "explicit wrapping" {
  fn h(a: u32, b: u32) -> u32 { a +% b }
}
```

## 9. Unsafe boundary (E0601)

```eider
compile_fail "raw call outside unsafe" expect E0601 at 3:10 {
  import c "mathx.h" as raw
  fn f(a: List[f64]) -> f64 uses ffi {
    return raw.mathx_dot(a.ptr(), a.ptr(), a.len())
  }
}
// error[E0601]: calling a C function requires `unsafe { }`

compile_fail "ffi capability" expect E0201 at 3:3 {
  fn f(a: List[f64]) -> f64 {
    unsafe { raw.mathx_dot(a.ptr(), a.ptr(), a.len()) }
  }
}
// unsafe doesn't grant `ffi`; both are required
```

## 10. Thread safety (E0701)

```eider
compile_fail "non-Send value into spawn" expect E0701 at 3:5 {
  fn f(ptr: *u8) uses threads {
    spawn {
      unsafe { *ptr }
    }
  }
}
// error[E0701]: `*u8` is not Send; it can't enter a spawned task

compile_fail "shared mutable without lock" expect E0701 at 4:7 {
  fn f(inv: Shared[Inventory]) uses threads {
    spawn {
      inv.stock[Sku("A")] = 0
    }
  }
}
// error[E0701]: Shared[T] is read-only; wrap in Mutex[T] to mutate

compile_fail "task outlives scope" expect E0702 at 4:3 {
  fn f() -> Task[u32] uses threads {
    return spawn { 1 }
  }
}
// error[E0702]: spawned tasks must be joined inside their `scope`
```

## 11. Module boundaries (E0801)

These keep incremental compilation sound, so they're checked like any other rule.

```eider
compile_fail "missing signature" expect E0801 at 1:8 {
  export fn total(xs: List[Line]) {      // return type omitted
    xs.map(|l| l.qty).sum()
  }
}
// error[E0801]: exported functions need an explicit return type
// fix: insert " -> u32"

compile_fail "orphan impl" expect E0802 at 1:1 {
  impl Display for List[u8] { ... }      // both from std, neither is yours
}
```

## How the suite is enforced

| Mechanism | What it catches |
|---|---|
| `compile_fail` with exact code and span | A rule that stops firing, or fires on the wrong line |
| `compile_pass` twin per rule | A rule that starts rejecting valid code |
| Snapshot of message and fix | Diagnostics regress for agents that apply fixes automatically |
| Fix round-trip: apply `fix`, recompile | A suggested fix that doesn't actually fix the error |
| Coverage gate in CI | Every `E` code in the compiler has at least one `compile_fail` test |
| Fuzzing with rustc-style mutation (delete a match arm, drop `uses`, widen an int) | Holes no one wrote a test for |

The fix round-trip is the important one for agents: for every `compile_fail` that carries a `fix`, the harness applies it and requires the result to compile (or to fail with a different, expected error). That is what makes "the diagnostic tells the agent how to fix it" a tested guarantee instead of a hope.

## Running in CI

```
$ eider test --compile-fail
  E0101 non-exhaustive match ........ 2 fail-tests, 1 pass-test  ok
  E0201 missing capability .......... 3 fail-tests, 1 pass-test  ok
  E0301 exclusive access ............ 2 fail-tests, 1 pass-test  ok
  ...
  47 rules, 118 tests, 0 failed
  coverage: 47/47 error codes have a compile_fail test
```
