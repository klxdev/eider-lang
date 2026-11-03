# Attributes

An attribute is a piece of typed data attached to an item, a record field or a variant:
`@[json(name = "user_id")]`. Attributes do nothing by themselves. The compiler checks them
against the attribute's declaration and keeps their values, and only code that reads them
with [comptime reflection](reflection.md) gives them a meaning: a JSON codec renames a field,
a schema generator documents it.

```text
attr_decl = ["pub"] "attr" name "{" { key ":" type ["=" literal] "," } "}"
attribute_group = "@" "[" attribute { "," attribute } [","] "]"
attribute       = name ["." name] ["(" { key ["=" expr] "," } ")"]
```

## Declaring an attribute

The package that gives an attribute its meaning declares it, with `attr`:

```eider
pub attr json { name: str = "", skip: bool = false, depth: i32 = 0 }

fn main() {}
```

The declaration is a record type named like the attribute (here `json`, with the fields
`name`, `skip` and `depth`), whose fields are the attribute's keys. A key's type is an integer
type, `bool` or `str`; anything else is E0822. A key with a default (`= literal`) may be left
out where the attribute is used; one without must be given. `attr` is a word with this
meaning only at the start of an item followed by a name and `{`, so it stays usable as a name
everywhere else.

## Using an attribute

`@[` opens a group, a comma-separated list of attributes that ends at `]`; it is the only
way to write an attribute. A group goes inline before the thing it applies to, or alone on
the line above it (the list may span lines, and groups may follow one another). It applies to
an item (`type`, `fn`, `const`, `trait`, `impl`, `attr`), a record field, a variant (after
its `|`) or a function parameter (before `inout`):

```eider
attr json { name: str = "", skip: bool = false }
attr doc { text: str }

@[doc(text = "A registered user.")]
type User = {
    @[json(name = "user_id")] id: u64,
    name: String,
    @[json(skip), doc(text = "computed, never sent")]
    score: i64,
}

type Event =
    | @[json(name = "joined")] Joined(id: u64)
    | Left

fn main() uses io {
    let u = User(7, String.from("ada"), 0)
    print(u.id)
}
```

```output
7
```

The arguments are `key = value`, or a bare `key` for `key = true` (bool keys only). Each
value is a literal or a constant of the key's type, checked like a constant (E0401 for a
value of the wrong type, E0822 for anything that isn't a constant); a `comptime` constant
counts. Leaving out the
parentheses (`@[json]`) gives every key its default. `@` not followed by `[` is a syntax error;
`eiderc migrate-attrs` rewrites code written with the bare `@name(...)` of earlier versions.

Which attribute `name` in a group means:

- an attribute `name` declared in the same module;
- else, when `name` is an import alias, the attribute `name` of the module it names: after
  `import json` (a package whose entry module declares `attr json`), `json(...)` is that
  attribute, which is how a package names its attribute after itself;
- `alias.name(...)` is the attribute `name` of the module `alias` names (it must be `pub`,
  else E0801).

## Errors

| Code | When |
|---|---|
| E0820 | no attribute of that name (the fix renames a close one) |
| E0821 | the attribute has no such key (the fix renames a close one) |
| E0822 | a key type that isn't an integer, bool or str; a value that isn't a constant; a key or an attribute given twice; a bare non-bool key; a required key left out |
| E0401 | a value of the wrong type |
| E0801 | an attribute that is private to its module |

```eider,compile_fail=E0821
attr json { name: str = "", skip: bool = false }

type User = {
    @[json(nmae = "user_id")] id: u64,
}

fn main() {}
```

The fix here renames `nmae` to `name`. Go's struct tags are the counter-example: a
misspelled tag key is a string nothing checks, and the field is silently encoded under its
own name.

## The built-in attributes

Two attributes need no declaration. `@[derive]` marks a trait whose reflective default methods
implement it for types (see [Traits](traits.md)). `@[allow(lint, ...)]` silences lints of
`eiderc lint` (see the [compiler tooling](../tooling/compiler.md#lints)) in the function,
`impl` or `trait` it precedes: it takes lint names, groups or `all` and nothing else (E0821
for an unknown name, E0822 for `key = value`).

```eider
@[allow(unused_uses)]
fn reserved() uses io {
    // the capability is declared for the callers that will need it
}

fn main() uses io { reserved() }
```

## Reading attributes

`attr[A](x)` gives the values of attribute `A` on a reflected field or variant, or on a type,
and `has_attr[A](x)` whether it is there; see [Comptime reflection](reflection.md).
[Deriving JSON](../guide/json.md) shows a package built on them.
