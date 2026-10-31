# eider-doc

`eider-doc` makes a documentation site for Eider code, like rustdoc or `go doc`: an API page
for every module of your packages, written from your doc comments, plus any Markdown pages
you list, with navigation, search and checked links. It also runs the code examples in all
of them as tests, so the documentation can't drift from the code.

It is a plain Eider program (`packages/doc`). The compiler does the language part:
`eiderc doc --json` describes a package's API, and eider-doc turns that into HTML.

## Quick start

In a package directory (the one with `eider.toml`):

```sh
eider-doc build .
```

Then open `target/site/index.html` in a browser. Nothing else is needed: the site is plain
files (one stylesheet, a small script, no fonts or CDNs), so it works from disk and from any
static file server. `eider-doc test .` runs the examples in your doc comments.

eider-doc runs the compiler named by `$EIDERC`, else `eiderc` on your `PATH`. In the Eider
repository, `scripts/docs.sh` builds the whole site (core, std, every package and the pages
in `docs/site`) into `target/site`, and `scripts/docs.sh test` runs every doc test.

To build eider-doc itself:

```sh
eiderc build packages/doc/main.ei -o eider-doc
```

## Writing doc comments

A `///` comment directly above an item documents it. The item can be a function, a type, a
trait, a constant or an impl, and also a method, a field or a variant that starts its own
line. The text is Markdown. Its first sentence is the item's summary in the module's index
and in search results, so make it say what the item is or does.

```eider,ignore
/// The distance between two points, in the units of their coordinates.
///
/// Rounded down, since there are no floating-point numbers here.
pub fn distance(a: Point, b: Point) -> i64 { ... }

pub type Point = {
    /// Horizontal, growing to the right.
    x: i64,
    y: i64,
}
```

(That block is `eider,ignore` because it's only a sketch: `...` isn't Eider.)

The module's own documentation is its `//!` lines (each starting in column 1), normally at
the top of the file:

```eider,ignore
//! Points and the distances between them.
//!
//! Everything here is pure: no capabilities.
```

Only `pub` items are documented. Impls go with their type, and methods take the
visibility of their type. `eiderc doc --private` shows the rest too.

### Markdown

The Markdown is CommonMark with GFM tables. You can use headings, emphasis, inline code,
links, local images, lists, block quotes, rules, fenced code and tables. Raw HTML is never
passed through: it shows up as text. A block quote whose first line is `**Note:**`,
`**Warning:**` or `**Tip:**` becomes a callout.

> **Tip:** link to any documented item with `api:`, for example `[BufReader](api:std/stream#BufReader)`,
> or to a module (`api:std/stream`) or a package (`api:std`). An `api:` link to something
> that wasn't documented fails the build, so links can't silently rot. That first link
> renders as [BufReader](api:std/stream#BufReader), and [std/stream](api:std/stream) is
> its module.

Anchors are stable. An item's anchor is its name. A field, variant or method is
`Owner.name`, and a trait impl is `impl-Trait-for-Type`. When a name is taken twice in a
module, the second one gets `-2`.

## Doc tests

Every fenced code block whose info string starts with `eider` is a test. The info string
says what is checked:

| Info string | Test |
|---|---|
| `eider` | a whole program: it must build and run. If the next code block is `output`, stdout must equal it exactly; otherwise the program must exit 0 |
| `eider,fragment` | the lines are put inside `fn main() uses io { ... }` (their `import` lines go above it), then tested as `eider` |
| `eider,compile_fail` | it must fail to compile; `eider,compile_fail=E0401` also checks that the first error has that code |
| `eider,trap` | it must build, and running it must trap (exit 101) |
| `eider,ignore` | shown, not tested: say why in the text |
| `sh`, `toml`, `json`, `c`, `text`, `output` | shown, not tested |

A whole program, with the output it must print:

```eider
fn main() uses io {
    let mut xs: List[i32] = List.new()
    xs.push(3)
    xs.push(4)
    print(xs.len())
}
```

```output
2
```

A fragment:

```eider,fragment
let greeting = "hello"
print(greeting)
```

```output
hello
```

A program the compiler must reject, with the error code it must give first:

```eider,compile_fail=E0401
fn main() {
    let n: i32 = true
}
```

And one that must trap at run time:

```eider,trap
fn main() {
    assert 1 + 1 == 3
}
```

Each test is built and run by the toolchain's compiler in a fresh temporary directory, and
stopped after 30 seconds. A failure names the file and the line of its fence: for a doc
comment, the line in the `.ei` file. The run ends with a summary such as
`doc tests: 41 passed, 0 failed, 3 ignored`, and exits 1 when anything failed.

## A site with pages

Besides the API, a site can have pages of its own: a directory of Markdown files and a
`SUMMARY.md` that lists them. Only listed pages are built, in this order:

```text
# Summary

## Getting started

- [Installing](guide/install.md)
- [Hello, world](guide/hello.md)
  - [Explained](guide/hello-explained.md)

## API

- [mylib](api:mylib)
```

Each `## Section` is a group in the navigation. An entry is `- [Title](page.md)`, or
`- [Title](api:<package>)` for a package's generated API. Two more spaces of indentation
nest an entry under the one above it. A page's title is its `#` heading.

A page can also live next to the site's directory. For example, `- [Roadmap](../design/roadmap.md)`
in `docs/site/SUMMARY.md` puts `docs/design/roadmap.md` on the site as `design/roadmap.html`.
Such pages are shown but not doc-tested: they are notes, not written for the test rules.

Links between pages are written to the `.md` files (`[the tour](../guide/tour.md#modules)`)
and become links to the `.html` pages. A link to any other file that exists, such as
`[the example](../../../examples/todo/todo.ei)`, goes to `<repo url>/<its path>` when
`--repo-url` is given (`scripts/docs.sh` gives the GitHub repository), and stays as written
otherwise. These links fail the build:

- a link to a file that doesn't exist;
- a link to a `.md` page in the site's directory that `SUMMARY.md` doesn't list;
- a link to a heading that doesn't exist;
- a remote image. Images must be files of the site, and they are copied into it.

```sh
eider-doc build --site docs --out public --title "My library" .
eider-doc test --site docs .
```

## Options

| Option | Meaning |
|---|---|
| `--out <dir>` | where the site goes (default `target/site`) |
| `--site <dir>` | the directory with `SUMMARY.md` and the pages (default `docs/site` when it has a `SUMMARY.md`; `--site ''` for an API-only site) |
| `--title <name>` | the site's name (default: the first package's name) |
| `--version` | print the toolchain's version (eider-doc ships with the toolchain; read from `$EIDER_ROOT/VERSION`), which the site's footer also shows |
| `--repo-url <url>` | where links to files that aren't pages go: `<url>/<path from the current directory>` (for example `https://github.com/you/lib/blob/main`) |
| `<package dirs...>` | the packages to document (default: the current directory; in the Eider repository, core, std and every package) |

The site has `index.html`, the pages, `api/<package>/<module>.html` for each module,
`api/<package>/index.html` for each package, `src/<package>/<file>.html` for the sources
the API pages link to (each line has an anchor, `#L12`), `search-index.json` (and
`search-index.js`, the same data for pages opened from disk) and `style.css`. Press `/` to
search. The theme follows your system's light or dark setting, and the button in the top
right switches it.

## `eiderc doc`

`eiderc doc <package dir | file.ei>` prints the API as text, one signature per line with its
summary, like `go doc`:

```text
$ eiderc doc std/path.ei
module std/path (path.ei)
    std/path: POSIX paths as bytes (List[u8], like std/fs), purely textual: nothing here looks at the file system (std/fs.canonical does).

pub fn is_absolute(p: List[u8]) -> bool
...
```

For a directory, it documents every `.ei` file in it. It skips `tests`, `examples`, `vendor`,
`target`, `deps` and hidden directories. For a file, it documents the modules of that file's
package that the file's program loads. It needs no C compiler and doesn't type-check, so it
also works on code that doesn't compile yet. Problems in the documented files, such as a
syntax error or an import it can't find, are warnings on stderr.

`eiderc doc --json` prints the same as one JSON document, which is what eider-doc reads:

```json
{"format":1,"toolchain":"0.1.0",
"packages":[{"name":"std","dir":"/path/to/std","version":"0.1.0","description":"..."}],
"modules":[
{"package":"std","path":"stream","file":"stream.ei","doc":"...","doc_line":1,"items":[
{"kind":"fn","name":"read_all","anchor":"read_all","sig":"pub fn read_all[R: Reader](inout r: R) -> Result[List[u8], Error] uses io","line":160,"public":true,"doc":"Everything up to end of stream.","generics":[{"name":"R","bounds":["Reader"]}],"uses":["io"],"links":[{"start":18,"end":24,"to":"std/stream#Reader"}]}
]}]}
```

- **The document** has `format` (1) and `toolchain`, the version of the toolchain that wrote
  it (its `VERSION` file).
- **Packages** have `name`, `dir` (absolute), and `version` and `description` from
  `eider.toml`.
- **Modules** have `package`, `path` (the module's path in its package, without `.ei`;
  `api:<package>/<path>` names it), `file` (relative to the package's `dir`), `doc` (the
  `//!` text), `doc_line` (its first line, 0 when there is none) and `items`. The prelude is
  module `core/prelude`.
- **Items** have:
  - `kind`: `fn`, `record`, `enum`, `alias`, `trait`, `impl` or `const`;
  - `name` and `anchor`;
  - `sig`: the signature as Eider source. A type's signature is its head (`pub type
    Kind[T]`), and its fields or variants are members;
  - `line`, `public` and `doc` (the `///` text, verbatim);
  - when they apply: `generics` (name and bounds), `uses` (the capabilities), `links` and
    `members`.

  A link's `start`..`end` are byte offsets into `sig`, and `to` is the item there, as
  `<package>/<path>#<anchor>`. Members are items of kind `field`, `variant` or `method`.
  Impls also have `trait` (empty for an inherent impl), `for` (the type's name) and
  `for_link` (the type, when it is in the same module). Constants have `type`, and unsafe,
  extern and exported functions have `flags`.

Strings are UTF-8 and escaped as JSON, and the output is the same for the same input. Every
package, module header and item starts a new line, so diffs stay readable.
