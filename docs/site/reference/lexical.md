# Lexical structure

The lexer turns a source file into tokens: identifiers, keywords, integer literals, string
literals, operators and punctuation, and newlines. This page defines each of them. The
grammar built on the tokens is in [Grammar](grammar.md).

## Source files

A source file has the extension `.ei` and is UTF-8 text. Outside string literals and
comments, only ASCII is allowed; any other character is E0001 "unexpected character".
Spaces, tabs and carriage returns separate tokens and are otherwise ignored. Diagnostics
give positions as line and column, where columns count Unicode scalar values, not bytes.

## Newlines

A newline is a token: it ends a statement, as `;` does. A run of blank lines is one
newline. The parser skips newlines where a statement can't end:

- after a binary operator (`a +` newline `b`), after `=` in `let` and in assignments, after
  `=>` in a match arm, and after `->` and `uses` clauses that start on the next line;
- inside `( )` and `[ ]`: between call arguments, parameters, tuple and array elements,
  type arguments and the elements of a type;
- before `{` of a function body, before `else`, and around match arms;
- before a line that starts with `.`, which continues the expression of the line before it
  (a method chain; comment-only and blank lines may come between).

A line that starts with any other operator starts a new statement: `+ 2` on its own line is
E0001, and `-x` on its own line is a statement of its own. Put the operator at the end of
the line instead.

```eider
fn main() uses io {
    let total = 1 +
        2 +
        3
    let text = String.from("eider")
        .slice(0, 3)
        // a comment between the lines of a chain
        .len()
    print(total)
    print(text)
}
```

```output
6
3
```

## Comments

- `//` starts a line comment, to the end of the line.
- `/* ... */` is a block comment. Block comments don't nest: the first `*/` ends it. An
  unterminated block comment is E0001.
- `///` is a line comment to the compiler. By convention a `///` comment before an item is
  its documentation, read by eider-doc; its first sentence is the item's summary, and code
  blocks in it are tests (`docs/site/CONTRACT.md`).

```eider
/// The answer, computed slowly.
fn answer() -> i32 {
    /* six times
       seven */
    6 * 7 // the product
}

fn main() uses io {
    print(answer())
}
```

```output
42
```

## Identifiers

An identifier starts with an ASCII letter or `_` and continues with ASCII letters, digits
and `_`: `count`, `_tmp`, `Point3`, `max_len`. Identifiers are case-sensitive. Types,
functions, variables, fields, variants, modules and labels are all identifiers, and so are
the segments of a module path (`import std.encoding`): a module whose file name is a keyword
or not an identifier (`comptime.ei`, `my-mod.ei`) has no dotted path.

`_` alone is not a name: in a pattern or a `let` it discards the value (`let _ = f()`), and
it can't be read.

## Keywords

These 31 words are reserved and can't be used as names (E0001 "`fn` is a keyword and can't
be used as a name"):

```text
as        assert    break     comptime  const     continue  else      export
extern    false     fn        for       if        impl      import    in
inout     let       match     module    null      pub       return    test
trait     true      type      unsafe    uses      var       while
```

`null` is reserved so that it can't mean anything: using it is E0402 ("absence is modelled
with Option[T]").

Some words have a meaning only in one position and are ordinary identifiers elsewhere:

| Word | Meaning |
|---|---|
| `mut` | before a name in `let mut x` and in a pattern `mut x` (`let mut = 1` declares a variable named `mut`) |
| `self` | the receiver parameter of a method, written without a type |
| `Self` | in a trait or impl, the type being implemented |
| `_` | the wildcard pattern |
| capability names | `io`, `fs`, `net`, `clock`, `threads`, `ffi`, ... after `uses` (see [Capabilities](capabilities.md)) |
| type names | `i32`, `String`, `List`, `Option`, ... are names, not keywords |
| `from` | an ordinary name; after an import path it is E0001 ("`from` imports are not supported") |
| `std`, `core` | ordinary names, but `import std` and `import core` import the toolchain's package namespaces |

## Integer literals

```text
int_literal = digit {digit | "_"}
            | ("0x" | "0X") hex_digit_or_underscore {hex_digit_or_underscore}
```

- Decimal: `0`, `42`, `1_000_000`. `_` may appear anywhere after the first digit and is
  ignored.
- Hexadecimal: `0xff`, `0XAB`, `0x_dead_beef`; the digits are case-insensitive. `0x` with
  no digits is E0001 "expected hex digits after 0x".
- There are no octal or binary literals, no type suffixes (`5u8` is the literal `5`
  followed by the name `u8`, a syntax error), and no floating-point literals.
- A literal is non-negative; `-5` is the negation operator applied to `5` (folded to a
  constant; see [Expressions](expressions.md)).
- A literal larger than the largest `i128` value is E0001 "integer literal too large". Any
  smaller literal lexes, and the checker then requires it to fit its type (E0501, see
  [Types](types.md#integer-literals)).

> **Note:** Floating-point literals and types are planned, not implemented
> ([roadmap](../../design/roadmap.md), `layer/language`).

## String literals

A string literal is text between double quotes, on one line. It has type `str`. Any UTF-8
text may appear in it except a newline, an unescaped `"` and an unescaped `\`; a literal
not closed on its line is E0001 "unterminated string literal".

| Escape | Means |
|---|---|
| `\n` | newline (10) |
| `\t` | tab (9) |
| `\r` | carriage return (13) |
| `\"` | `"` |
| `\\` | `\` |
| `\xNN` | the ASCII character NN: exactly two hex digits, either case, `01` to `7f` |
| `\u{H}` | the Unicode scalar value H, one to six hex digits, encoded as UTF-8 |

Refused escapes are E0001 at the backslash, with a message saying why:

- `\0`, `\x00`, `\u{0}`: a string can't contain NUL. A `str` is a NUL-terminated C string,
  and a `String` is UTF-8 text without NUL; bytes that include 0 belong in a `List[u8]`.
- `\x80` to `\xff`: a lone byte above 7f isn't valid UTF-8; write the character as
  `\u{...}`.
- `\x` with fewer than two hex digits; `\u` without braces, or with no or more than six
  digits; a surrogate (`\u{d800}` to `\u{dfff}`); a value above `\u{10ffff}`.
- any other character after `\` ("unknown escape sequence").

**Adjacent literals** separated only by spaces on one line are one literal:
`"GET / HTTP/1.1\r\n" "Host: x\r\n"` is a single token. Literals on different lines are
not joined.

There are no character literals (`'a'` is E0001), raw strings or string interpolation.
Formatting is done with std ([fmt](api:std/fmt)).

```eider
fn main() uses io {
    let s = "tab\there, quote \" and backslash \\"
    print(s)
    print("\x41\u{e9}\u{1F600}")
    print("one " "literal")
    print("\u{e9}".len())
}
```

```output
tab	here, quote " and backslash \
Aé😀
one literal
2
```

```eider,compile_fail=E0001
fn main() uses io {
    print("nul \0 inside")
}
```

## Operators and punctuation

Tokens are read longest first (`<<=` before `<<` before `<`).

| Token | Use |
|---|---|
| `+` `-` `*` `/` `%` | arithmetic (checked) |
| `+%` `-%` `*%` | wrapping arithmetic |
| `&` `\|` `^` `~` `<<` `>>` | bitwise operators; `\|` also separates or-patterns and delimits closure parameters |
| `==` `!=` `<` `<=` `>` `>=` | comparison |
| `&&` `\|\|` `!` | logical operators; `\|\|` also starts a closure with no parameters |
| `=` | binding and assignment |
| `+=` `-=` `*=` `/=` `%=` `&=` `\|=` `^=` `<<=` `>>=` | compound assignment |
| `->` | result type |
| `=>` | match arm |
| `..` | range, in `for` only |
| `?` | error propagation |
| `.` | field, method, tuple element, qualified name |
| `,` `:` `;` | separators; `:` before a type and after a loop label |
| `(` `)` `[` `]` `{` `}` | grouping, tuples, calls; indexing, arrays, type arguments; blocks, records |

Operator precedence is given in [Expressions](expressions.md#operator-precedence). Other
ASCII characters (`#`, `@`, `$`, `'`, the backquote) are not tokens and are E0001
"unexpected character".
