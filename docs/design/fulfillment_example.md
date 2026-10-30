# Example: Order Fulfillment Engine

A warehouse fulfillment module showing types, traits, generics, a state machine, value semantics, capabilities, concurrency, FFI, and tests.

## 1. Domain types

```eider
module warehouse.fulfillment

import std.collections.{List, Map}
import std.sync.{Shared, Mutex}
import std.time.Instant

type Sku = distinct str              // newtype: a plain str won't typecheck as Sku

type Money = { cents: i64 }

type Item = {
  sku: Sku,
  name: str,
  price: Money,
  grams: u32,
}

type Line = { sku: Sku, qty: u32 }

type BoxSize = | Small | Medium | Large

type OrderStatus =
  | Pending
  | Picking(picker: u32, started: Instant)
  | Packed(box: BoxSize)
  | Shipped(tracking: str)
  | Cancelled(reason: str)

type Order = {
  id: u64,
  lines: List[Line],
  status: OrderStatus = Pending,     // default field value
  priority: u8 = 0,
}

type FulfillError =
  | UnknownSku(Sku)
  | OutOfStock(sku: Sku, wanted: u32, have: u32)
  | TooHeavy(grams: u32)
  | InvalidTransition(from: OrderStatus, event: str)
```

## 2. Traits and generics

```eider
trait Weighted {
  fn grams(self) -> u32
}

type Picked = { item: Item, qty: u32 }

impl Weighted for Picked {
  fn grams(self) -> u32 { self.item.grams * self.qty }   // overflow traps
}

// Monomorphized at compile time: zero runtime cost
fn total_grams[T: Weighted](things: List[T]) -> u32 {
  return things.map(|t| t.grams()).sum()
}
```

## 3. Objects with methods (value semantics)

```eider
type Inventory = {
  items: Map[Sku, Item],
  stock: Map[Sku, u32],
}

impl Inventory {
  // `self` = read-only access
  fn lookup(self, sku: Sku) -> Result[Item, FulfillError] {
    return self.items.get(sku).ok_or(UnknownSku(sku))
  }

  // `inout self` = exclusive mutable access for this call only
  fn reserve(inout self, line: Line) -> Result[(), FulfillError] {
    let have = self.stock.get(line.sku) ?? 0
    if have < line.qty {
      return Err(OutOfStock(line.sku, line.qty, have))
    }
    self.stock[line.sku] = have - line.qty
    return Ok(())
  }

  // All-or-nothing reservation with rollback
  fn reserve_all(inout self, lines: List[Line]) -> Result[(), FulfillError] {
    let snapshot = self.stock         // logical copy, copy-on-write underneath
    for line in lines {
      if let Err(e) = self.reserve(line) {
        self.stock = snapshot
        return Err(e)
      }
    }
    return Ok(())
  }
}
```

## 4. Compile-time evaluation

```eider
comptime fn box_limit(b: BoxSize) -> u32 {
  match b {
    Small  => 2_000
    Medium => 10_000
    Large  => 25_000
  }
}

fn choose_box(grams: u32) -> Result[BoxSize, FulfillError] {
  for b in BoxSize.variants() {       // list generated at compile time
    if grams <= box_limit(b) { return Ok(b) }
  }
  return Err(TooHeavy(grams))
}
```

## 5. State machine with exhaustive matching

```eider
type Event =
  | StartPick(picker: u32)
  | Pack
  | Ship(tracking: str)
  | Cancel(reason: str)

fn advance(inout order: Order, event: Event, inv: Inventory)
  -> Result[(), FulfillError]
  uses clock
{
  let next = match (order.status, event) {
    (Pending, StartPick(p)) => Picking(p, clock.now())

    (Picking(_, _), Pack) => {
      var picked = List[Picked].new()
      for line in order.lines {
        picked.push(Picked(inv.lookup(line.sku)?, line.qty))
      }
      Packed(choose_box(total_grams(picked))?)
    }

    (Packed(_), Ship(t)) => Shipped(t)

    (Shipped(_), Cancel(_)) =>
      return Err(InvalidTransition(order.status, "cancel"))

    (_, Cancel(r)) => Cancelled(r)

    (s, e) => return Err(InvalidTransition(s, e.name()))
  }
  order.status = next
  return Ok(())
}
```

## 6. Iterators and closures

```eider
fn next_up(orders: List[Order], n: usize) -> List[Order] {
  return orders
    .filter(|o| o.status is Pending)
    .sort_by(|a, b| b.priority.cmp(a.priority).then(a.id.cmp(b.id)))
    .take(n)
}
```

## 7. Safe concurrency

```eider
fn process_batch(orders: List[Order], inv: Shared[Mutex[Inventory]])
  -> List[Result[u64, FulfillError]]
  uses clock, threads
{
  let tasks = orders.map(|order| spawn {
    var o = order                                  // each task owns its copy
    inv.lock(|inout stock| stock.reserve_all(o.lines))?
    let view = inv.lock(|stock| stock)             // read-only snapshot
    advance(inout o, StartPick(1), view)?
    advance(inout o, Pack, view)?
    return Ok(o.id)
  })
  return tasks.map(|t| t.join())
}
```

## 8. FFI (the only unsafe zone)

```eider
extern "C" fn label_print(data: *u8, len: usize) -> i32

fn print_label(tracking: str) -> Result[(), str] uses ffi {
  let rc = unsafe { label_print(tracking.ptr(), tracking.len()) }
  return if rc == 0 { Ok(()) } else { Err(fmt"printer error {rc}") }
}
```

## 9. Built-in tests

```eider
test "reserve_all rolls back on shortage" {
  var inv = Inventory.with_stock([(Sku("A"), 5), (Sku("B"), 1)])
  let r = inv.reserve_all([Line(Sku("A"), 3), Line(Sku("B"), 2)])
  assert r == Err(OutOfStock(Sku("B"), 2, 1))
  assert inv.stock[Sku("A")] == 5
}

test "heavy order rejected" {
  assert choose_box(30_000) == Err(TooHeavy(30_000))
}
```

## 10. What the compiler rejects

```eider
// Storing a reference: rejected, inout cannot escape the call
type Cache = { inv: inout Inventory }

// Missing capability: rejected, advance() needs `clock`
fn run(inout o: Order, inv: Inventory) {
  advance(inout o, StartPick(1), inv)
}

// Non-exhaustive match: rejected, `Large` not handled
match box { Small => 1, Medium => 2 }

// Two mutable accesses at once: rejected
swap(inout inv, inout inv)
```

Diagnostic output for agents:

```json
{
  "error": "missing_capability",
  "span": { "file": "fulfillment.ei", "line": 3, "col": 3 },
  "message": "call to `advance` requires capability `clock`",
  "fix": { "insert": " uses clock", "at": { "line": 2, "col": 38 } }
}
```
