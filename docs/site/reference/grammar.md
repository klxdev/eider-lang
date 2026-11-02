# Grammar

This is the syntax of Eider as the parser (`compiler/parse.ei`) accepts it, in EBNF:
`{ x }` is zero or more, `[ x ]` optional, `|` alternatives, `"..."` a token. Tokens are
defined in [Lexical structure](lexical.md). Rules the parser enforces beyond the grammar
(and the checker's rules) are noted after each part and described on the other pages.

## Newlines

`NL` is a newline token (a run of blank lines is one). Statements and items are separated
by `sep`. The parser skips newlines in these places, which the grammar below doesn't
repeat: after a binary operator, after `=` in `let`, assignments and `type` (not in
`const`), after `=>`, after `,` and after the opening bracket in every comma-separated list
and in record bodies, before the closing bracket of such a list, before `->` and `uses` in a
function signature, before the `{` of a function, `impl` or `trait` body, before `else`,
between match arms, after `|...|` of a closure and after `unsafe`, and before a line that
starts with `.` in a postfix chain. The `{` of `if`, `while`, `for` and `match` must be on
the line of the condition or scrutinee.

```text
sep = NL | ";"
```

## Items

```text
file        = { sep } { attrs item { sep } }
attrs       = { attribute { NEWLINE } }
attribute   = "@" IDENT ["." IDENT] [ "(" [ attr_arg { "," attr_arg } [","] ] ")" ]
attr_arg    = IDENT ["=" expr]
item        = import | module_line
            | ["pub"] type_item
            | ["pub"] attr_item
            | ["pub"] fn_item
            | ["pub"] "unsafe" fn_item
            | ["pub"] "extern" "\"c\"" fn_signature
            | ["pub"] "export" fn_item
            | ["pub"] const_item
            | ["pub"] trait_item
            | impl_item
            | test_item

import      = "import" mpath ["as" IDENT]
            | "import" mpath "." "{" member { "," member } [","] "}"
            | "import" string ["as" IDENT]                    (deprecated)
member      = mpath ["as" IDENT]
mpath       = IDENT { "." IDENT }
module_line = "module" IDENT { "." IDENT }

generics    = "[" gparam { "," gparam } "]"
gparam      = IDENT [":" path { "+" path }]
path        = IDENT ["." IDENT]

type_item   = "type" IDENT [generics] "=" ( record_body | variants | type )
record_body = "{" [ field { fsep field } [fsep] ] "}"     fsep = "," | NL
field       = attrs IDENT ":" type
variants    = variant { "|" variant }
variant     = "|" attrs IDENT [ "(" [ vfield { "," vfield } [","] ] ")" ]
attr_item   = "attr" IDENT "{" [ attr_key { "," attr_key } [","] ] "}"
attr_key    = IDENT ":" type ["=" expr]
vfield      = [IDENT ":"] type

fn_item      = fn_signature block
fn_signature = "fn" IDENT [generics] "(" [ param { "," param } [","] ] ")"
               ["->" type] ["uses" IDENT { "," IDENT }]
param        = ["inout"] "self" | ["inout"] IDENT ":" type

const_item  = "const" IDENT ":" type "=" ["comptime"] expr
trait_item  = "trait" IDENT "{" { sep } { fn_signature [block] { sep } } "}"
impl_item   = "impl" [generics] type ["for" type] "{" { sep } { fn_item { sep } } "}"
test_item   = "test" string block
```

- `comptime for x in fields(T) { ... }` and `comptime for v in variants(T) { ... }` are
  statements (and, over `fields`, the only argument of a constructor call: one argument per
  field); `comptime if` is an `if` whose condition is evaluated while checking; `x.[f]`
  reads the field a `comptime for` variable names; `attr[A](x)` and `has_attr[A](x)` read
  attributes (`attr` and `has_attr` followed by `[`); see [Comptime reflection](reflection.md).
- `attr` is not a keyword: it starts an `attr_item` only when an identifier and `{` follow
  it at the start of an item. Attributes go before `type`, `attr`, `fn`, `const`, `trait`
  and `impl` items (not `import`, `module` or `test`); see [Attributes](attributes.md).
- `variants` is written with a leading `|` before every variant, the first included
  (`type A = X | Y` is E0001 "expected `|`"; `type A = X` is an alias of `X`). Variants may
  be on separate lines.
- In a `type_item` the generics take no bounds (E0001). The `type` alternative is a type
  alias; it can't start with `{` or `|`.
- In `impl T for U`, `T` is the trait: a name, or a name with type arguments
  (`From[E]`); `impl` without `for` is inherent. `pub` doesn't apply to `impl` or `test`
  (E0001).
- `extern "c"` declares a function without a body (a body is E0001); the ABI string must be
  exactly `"c"`. In a trait, a method may have a body, which is parsed but not used as a
  default (an impl must define every method).
- The `self` parameter has no type; it is the receiver (`Self`).
- `export fn` is always public (`pub export fn` is accepted and means the same).
- Methods in an `impl` or `trait` are written without `pub`: they have their type's
  visibility.

## Types

```text
type     = "fn" "(" [ ["inout"] type { "," ["inout"] type } [","] ] ")" ["->" type]
         | "[" type ";" INT "]"
         | "(" ")"
         | "(" type "," ")"
         | "(" type { "," type } [","] ")"
         | path [ "[" type { "," type } "]" ]
```

- `(T)` is `T`; a tuple of one element needs the trailing comma.
- The array length is an integer literal.
- `inout` is a parameter mode, not a type: anywhere else in a type it is E0302.
- At most 31 parameters of a fn type can be `inout`.

## Statements

```text
block      = "{" { sep } [ stmt { sep { sep } stmt } ] { sep } "}"
stmt       = let_stmt
           | [label] while_stmt
           | [label] for_stmt
           | "return" [expr]
           | "break" [IDENT]
           | "continue" [IDENT]
           | "assert" expr ["," string]
           | ("defer" | "errdefer") stmt
           | expr [assign_op expr]

label      = IDENT ":"
let_stmt   = ("let" ["mut"] | "var") IDENT [":" type] "=" expr
           | ("let" ["mut"] | "var") "(" pattern_list ")" "=" expr
assign_op  = "=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&=" | "|=" | "^=" | "<<=" | ">>="

while_stmt = "while" expr block
           | "while" "let" pattern "=" expr block
for_stmt   = "for" IDENT "in" expr ".." expr block
           | "for" IDENT "in" expr block
           | "for" "(" pattern_list ")" "in" expr block
```

- Two statements on one line need `;` between them.
- `mut` after `let` is a contextual word: it is read as "mutable" only when a name follows
  (`let mut x = 1`); `let mut = 1` declares `mut`. In the tuple form, `let mut (a, b)` is
  not accepted: write `let (mut a, mut b)`.
- A label is recognized only when an identifier, `:` and `for` or `while` follow each other
  at the start of a statement. The identifier after `break`/`continue` must be on the same
  line.
- `return` takes a value unless a newline, `;` or `}` follows it.
- `while let P = e { A }` is parsed as `while true { match e { P => { A } _ => { break } } }`.
- The assignment target must be a place (checked later, E0303); assignment is not an
  expression.

## Expressions

One rule per precedence level, loosest first.

```text
expr      = or_expr
or_expr   = and_expr { "||" and_expr }
and_expr  = cmp_expr { "&&" cmp_expr }
cmp_expr  = bor_expr { ("==" | "!=" | "<" | "<=" | ">" | ">=") bor_expr }
bor_expr  = bxor_expr { "|" bxor_expr }
bxor_expr = band_expr { "^" band_expr }
band_expr = shift_expr { "&" shift_expr }
shift_expr = add_expr { ("<<" | ">>") add_expr }
add_expr  = mul_expr { ("+" | "-" | "+%" | "-%") mul_expr }
mul_expr  = cast_expr { ("*" | "/" | "%" | "*%") cast_expr }
cast_expr = unary { "as" type }
unary     = ("-" | "!" | "~") unary | postfix

postfix   = primary { call_args | "." (IDENT | INT) [call_args] | "[" expr "]" | "?" }
call_args = "(" [ ["inout"] expr { "," ["inout"] expr } [","] ] ")"

primary   = INT | string | "true" | "false"
          | "(" ")" | "(" expr ")" | "(" expr "," [ expr { "," expr } [","] ] ")"
          | "[" "]" | "[" expr { "," expr } [","] "]" | "[" expr ";" INT "]"
          | block
          | "unsafe" block
          | closure
          | if_expr
          | match_expr
          | path

closure    = "|" [ cparam { "," cparam } ] "|" ["->" type] expr
           | "||" ["->" type] expr
cparam     = ["inout"] IDENT [":" type]

if_expr    = "if" expr block ["else" (block | if_expr)]
           | "if" "let" pattern "=" expr block ["else" (block | if_expr)]
match_expr = "match" expr "{" { NL | "," } { arm { NL | "," } } "}"
arm        = pattern { "|" pattern } "=>"
             ( expr | "return" [expr] | "break" [IDENT] | "continue" [IDENT] | "assert" expr ["," string] )
```

- The bitwise levels are not ranked against the others: an operand of `|`, `^`, `&`, `<<`
  or `>>` that is an unparenthesized operation of another group, and an operand of a
  comparison that is an unparenthesized `|`, `^` or `&`, are E0002. A shift may be an
  operand of `|`, `^`, `&`, and a comparison may compare shifts (see
  [Expressions](expressions.md#bitwise-operators-need-parentheses)).
- A call `( ... )` may only follow a `path` (a name or `alias.name`): any other callee is
  E0001 "only named functions can be called". After `.`, a name followed by `(` is a
  method call; otherwise a field. An `INT` after `.` is a tuple element (`t.0`).
- In a postfix chain, a newline followed by a line starting with `.` continues the chain.
- `path` is `IDENT`, `alias.IDENT` when `alias` is an import alias of the file, or
  `ns.module.IDENT` when `ns` is a package namespace the file imports (`import std`); any
  other `a.b` is a field access. Inside an import's `{ }`, newlines are skipped. `import
  std.*` and `from` after an import path are E0001 (no wildcard or `from` imports). `null` in an expression is E0402.
- `[x; N]` needs an integer literal N of at least 1.
- `if let P = e { A } else { B }` is parsed as `match e { P => { A } _ => { B } }` (with an
  empty `B` when there is no `else`).
- `if`, `match`, blocks and `unsafe` blocks parse anywhere a primary does; the checker
  allows them only as a statement, a final expression, or the right side of `let`, `=` and
  `return` (E0103).

## Patterns

```text
pattern      = INT | "-" INT | string | "true" | "false"
             | int_bound "..=" int_bound
             | "_"
             | "mut" IDENT
             | path { "." IDENT } [ "(" [ pattern_list ] ")" ]
             | path { "." IDENT } "{" [ field_pat { "," field_pat } [","] ] [ ".." ] "}"
             | "(" [ pattern_list ] ")"
pattern_list = pattern { "," pattern } [","]
int_bound    = INT | "-" INT
field_pat    = IDENT [ ":" pattern ]
```

- `(p)` is `p`; `()` is the unit pattern; `(p,)` a one-element tuple.
- `mut` is contextual here too: `mut` followed by a name.
- In `a.b.C`, only the last segment is kept (`Shape.Circle(r)` is `Circle(r)`).
- Or-patterns (`p | q`) and guards (`p if cond`) exist only at the top of a match arm.

## Item recognition and error recovery

After a syntax error, the parser skips to the next statement or item and goes on, so every
syntax error of a file is reported. A token starts an item when it is `fn` followed by a
name, `unsafe` followed by `fn`, or one of `type`, `const`, `trait`, `impl`, `import`,
`test`, `pub`, `extern`, `export`, `module`. Anything else at the top level is E0001
"expected `fn`, `type`, `const`, `trait`, `impl`, `import` or `test`".
