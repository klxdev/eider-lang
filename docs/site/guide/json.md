# Deriving JSON

[eider-json](https://github.com/klxdev/eider-json) turns your records and enums into JSON
and back with codecs it derives from their fields. There is nothing to write and no
generator: `Encode` and `Decode` are [`@derive` traits](../reference/traits.md) whose
default methods go over a type's fields with [comptime
reflection](../reference/reflection.md), so every record and enum has them, and the
`@json(...)` [attribute](../reference/attributes.md) shapes the result. This guide builds a
small API type, then shows what decoding rejects and why.

The examples need the json package (see [Building services](services.md) for adding a
dependency), so they are shown, not run here. eider-json's own tests
(tests/derive_test.ei) run all of them.

## A record

```eider,ignore
import json

@json(rename_all = "camelCase")
type User = {
    @json(name = "id") user_id: u64,
    display_name: String,
    email: Option[String],
    @json(default) score: i32,
    @json(skip) cache: List[u8],
}

fn main() uses io {
    let u = User(7, String.from("Ada"), None, 3, List.new())
    io.outln(json.to_json(u))
    let back: Result[User, json.DecodeError] = json.from_json("{{\"id\": 9, \"displayName\": \"Bob\"}}".bytes())
    match back {
        Ok(b) => print(b.display_name)
        Err(e) => io.outln(json.decode_error_text(e))
    }
}
```

```text
{"id":7,"displayName":"Ada","email":null,"score":3}
Bob
```

There is no impl: a type that doesn't implement `Encode` or `Decode` itself has the traits'
default methods, which are `json.encode_record` / `json.encode_enum` and
`json.decode_record` / `json.decode_enum` (eider-json 0.3.1 and later; before it, a
one-line impl for each trait called them). What the attribute says:

| On | Key | Effect |
|---|---|---|
| a field | `name = "id"` | the member's key |
| a field | `skip` | never written; decoding gives it its `Default` |
| a field | `default` | a missing member is the field's `Default`, not an error |
| a field | `flatten` | a record field whose members are written into the outer object |
| a type | `rename_all = "camelCase"` | every key in that case (`snake_case`, `kebab-case`, `SCREAMING_SNAKE_CASE` too) |
| an enum | `tag = "kind"` | the discriminator's key (default `type`) |
| a variant | `name = "box"` | the variant's tag |
| a type | `unknown = "ignore"` | members no field takes are allowed (default: an error) |

An `Option` field may be missing (it decodes as `None`) and is written as `null` when it is
`None`. Every other field is required unless it says `default`.

A misspelled key is a compile error with a fix, because the attribute is declared by the
package: `@json(nmae = "id")` is E0821, "attribute `json` has no key `nmae`", fixed to
`name`.

## An enum

```eider,ignore
@json(tag = "kind", rename_all = "snake_case")
type Shape =
    | Circle(radius: i64)
    | @json(name = "box") Rect(w: i64, h: i64)
    | Empty
```

A variant with fields is an object with its tag first, a variant without fields is just
its name: `{"kind":"circle","radius":2}`, `{"kind":"box","w":3,"h":4}`, `"empty"`. This is
the internal discriminator OpenAPI's `discriminator` describes.

## What decoding rejects

`from_json` is meant for input you don't control. It parses within `json.limits()`: at most
8 MiB, nesting 64 deep, strings of 1 MiB, 100,000 elements or members per container, and an
object may not repeat a key (`from_json_with` takes other `Limits`). Then the decoder is
strict, and every error says where:

```text
$: unknown member "admin"
$: missing member "displayName"
$.id: not a u64 (out of range, or not an integer)
$.tags[1]: expected a string, found a number
$: a key repeated in an object at line 1, column 15 (byte 14)
$.shapes[0]: unknown variant "hexagon"
$.shapes[0]: missing the discriminator `kind`
```

A number must fit the field's type exactly (no rounding, no wrapping), a string with
`\u0000` can't become a `String`, and nothing traps. eider-json's fuzzer
(tests/fuzz_test.ei, `sh scripts/fuzz.sh`) runs mutated documents through the decoders and
checks that each one decodes or is rejected with a path, and that what decodes round-trips.

## Your own encoding

The derived codec is a default, not a rule: a type that needs another representation (a
date as a string, a set as a sorted array) implements `Encode` and `Decode` by hand (its own
package can; the impl replaces the derived one) with the
`Writer` (`string`, `int`, `begin_object`, `key`, ...) and the `Reader` (`kind`, `error`).
The derived code of every type that contains it then uses that impl.

## In a service

eider-rpc's kvstore example decodes the named parameters of its `math.add` method with a
derived decoder, so `{"a": 40, "b": 2, "c": 1}` is "Invalid params" with the data
`$: unknown member "c"`, and writes `kv.stats`'s result with a derived encoder
(examples/kvstore/kv.ei).
