# Serialization and JSON

A type goes to a data format and back through two traits in `std/serial`, `Serialize` and
`Deserialize`, over a small data model (booleans, integers, floats, strings, bytes, times,
lists, maps, records and variants). A format is a package that implements the model's two
halves, `Serializer` and `Deserializer`; [eider-json](https://github.com/klxdev/eider-json)
is the JSON one. Your type does not know which format it is written in.

Serialization is opt-in. `Serialize` and `Deserialize` are [`@[derive]`
traits](../reference/traits.md) whose default methods go over a type's fields with [comptime
reflection](../reference/reflection.md); a type has them when it says so with
`@[derive(Serialize, Deserialize)]`, or only one of them. This guide builds a small API type,
then shows what reading rejects and why.

The examples need the json package (see [Building services](services.md) for adding a
dependency), so they are shown, not run here. eider-json's own tests
(tests/derive_test.ei) run all of them.

## A record

```eider,ignore
import std.serial
import json

@[derive(Serialize, Deserialize), serial(rename_all = "camelCase")]
type User = {
    @[serial(name = "id")] user_id: u64,
    display_name: String,
    email: Option[String],
    @[serial(default)] score: i32,
    @[serial(skip)] cache: List[u8],
}

fn main() uses io {
    let u = User(7, String.from("Ada"), None, 3, List.new())
    io.outln(json.to_bytes(u).unwrap())
    let back: Result[User, serial.Error] = json.from_string(String.from("{{\"id\": 9, \"displayName\": \"Bob\"}}"))
    match back {
        Ok(b) => print(b.display_name)
        Err(e) => io.outln(serial.error_text(e))
    }
}
```

```text
{"id":7,"displayName":"Ada","email":null,"score":3}
Bob
```

The type to read is the expected one, as in the `let` above. What the attributes say:

| On | Key | Effect |
|---|---|---|
| a field | `name = "id"` | the member's key |
| a field | `skip` | never written; reading gives it its `Default` |
| a field | `default` | a missing member is the field's `Default`, not an error |
| a field | `flatten` | (`json` only) a record field whose members are written into the outer object |
| a type | `rename_all = "camelCase"` | every key in that case (`snake_case`, `kebab-case`, `SCREAMING_SNAKE_CASE` too) |
| an enum | `tag = "kind"` | the discriminator's key; without it a variant is keyed by its name |
| a variant | `name = "box"` | the variant's name |
| a type | `unknown = "ignore"` | (`json` only) members no field takes are allowed (default: an error) |

`serial(...)` applies to every format. `json(...)` takes the same keys and wins for JSON, so a
type can be `@[serial(name = "email")]` everywhere and `@[json(name = "mail")]` in JSON
only (`toml(...)` is the same for TOML). An `Option` field may be missing (it reads as
`None`) and is written as `null` when it is `None`. Every other field is required unless it
says `default`.

A misspelled key is a compile error with a fix, because the attribute is declared by
`std/serial`: `@[serial(nmae = "id")]` is E0821, "attribute `serial` has no key `nmae`", fixed
to `name`.

## The whole tree must be serializable

`@[derive(Serialize)]` on a type checks every field's type at compile time. A field whose
type has no `Serialize` is an error that names the path:

```text
error[E0833]: Checkout.session: type Session is not Serialize
  help: mark Session with `@[derive(Serialize)]`, implement Serialize for it, or leave the
        field out (`@[serial(skip)]` for Serialize and Deserialize)
```

So a secret or a handle is never written by accident: it is left out with `@[serial(skip)]`
or its type is not given the trait.

## An enum

```eider,ignore
@[derive(Serialize, Deserialize), serial(tag = "kind", rename_all = "snake_case")]
type Shape =
    | Circle(radius: i64)
    | @[serial(name = "box")] Rect(w: i64, h: i64)
    | Empty
```

A variant with fields is an object with its tag first, a variant without fields is just its
name: `{"kind":"circle","radius":2}`, `{"kind":"box","w":3,"h":4}`, `"empty"`. This is the
internal discriminator OpenAPI's `discriminator` describes. Without `tag`, a variant with
fields is an object under its name, `{"Circle":{"radius":2}}`.

## What reading rejects

`json.from_bytes` is meant for input you don't control. It parses within `json.limits()`: at
most 8 MiB, nesting 64 deep, strings of 1 MiB, 100,000 elements or members per container, and
an object may not repeat a key (`from_bytes_with` takes other `Limits`). Then the reading is
strict, and every error says where:

```text
unknown field `admin`
missing field `displayName`
id: the number is out of range
tags[1]: expected a string, found an integer
a key repeated in an object at line 1, column 15 (byte 14)
shapes[0]: unknown variant `hexagon`
shapes[0]: missing the tag `kind`
```

A number must fit the field's type exactly (no rounding, no wrapping), a string with
`\u0000` can't become a `String`, and nothing traps. eider-json's fuzzer
(tests/fuzz_test.ei, `sh scripts/fuzz.sh`) runs mutated documents through the readers and
checks that each one reads or is rejected with a message, and that what reads round-trips.

A record that has a `flatten` field accepts members it does not know, because the flattened
record shares the object; that gap is tracked as an issue.

## Your own encoding

The derived code is a default, not a rule: a type that needs another representation (a date
as a string, an amount as a bare number) implements `Serialize` and `Deserialize` by hand. The
derived code of every type that contains it then uses that impl:

```eider,ignore
impl serial.Serialize for Money {
    fn serialize[S: serial.Serializer](self, inout s: S) -> Result[(), serial.Error] { s.int(self.cents) }
}

impl serial.Deserialize for Money {
    fn deserialize[D: serial.Deserializer](d: D) -> Result[Money, serial.Error] {
        let c = d.read_i64()?
        match of(c) {
            Ok(m) => Ok(m)
            Err(_) => Err(serial.fail(d, "not an amount"))
        }
    }
}
```

An impl can also branch on `s.format()` ("json", "toml") to write one shape for one format.

## In a service

eider-rpc's kvstore example reads the named parameters of its `math.add` method with a
derived `Deserialize`, so `{"a": 40, "b": 2, "c": 1}` is "Invalid params" with the data
``unknown field `c` ``, and writes `kv.stats`'s result with a derived `Serialize`
(examples/kvstore/kv.ei). eider-openapi derives a JSON Schema from the same attributes
(`@[derive(Schematic)]`).
