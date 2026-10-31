# Capabilities

Every Eider function that reaches outside the program says so in its signature, and every
package can do only what the package that depends on it allows. This page explains why,
how the rule works inside a program, and how grants work across packages.

## Why

Most supply-chain attacks and many bugs come from code doing something nobody expected it
to do: a logging library that opens sockets, a parser that reads files, a test helper that
sleeps. In most languages you find out by reading every line of every dependency.

In Eider the answer is in the signatures. `fn parse(text: String) -> Result[Doc, Error]`
can't touch the file system, the network, the clock or other threads, and neither can
anything it calls. A dependency's reach is written in your `eider.toml`, and the compiler
holds it to that on every build.

## The capabilities

| Capability | What it covers |
|---|---|
| `io` | standard input, output and error (`print` too), the environment, command-line arguments, exiting, reading and writing descriptors |
| `fs` | opening, reading, writing, listing and removing files and directories |
| `net` | sockets: listening, accepting, connecting, DNS |
| `clock` | reading the clocks, sleeping, deadlines |
| `threads` | starting threads (`spawn`, pools, task groups) |
| `ffi` | calling C (`extern "c"` functions) |

Running a child process needs `io, fs, net` (it can do anything). A word in `uses` that
isn't one of these is E0203.

## Inside a program

A function lists what it uses after its result type: `fn f() -> T uses io, clock`. The
rule is simple: **a call needs the callee's capabilities**. If `save` uses `fs`, every
function that calls `save` must declare `fs` too, up to `main`:

```eider,compile_fail=E0201
import "std/fs"

fn save(path: String, data: String) -> Result[bool, String] uses fs {
    fs.write(path.bytes(), data.bytes())
}

fn remember(note: String) -> bool {
    save(String.from("notes.txt"), note).is_ok()
}

fn main() uses io {
    print(remember(String.from("buy milk")))
}
```

```text
error[E0201]: call to `save` requires capability `fs`
  --> main.ei:8:5
  |
8 |     save(String.from("notes.txt"), note).is_ok()
  |     ^
  fix: at 7:34 delete 0 insert " uses fs"
```

Applying the fix moves the error to `main`'s call of `remember`, and so on up. That is the
point: the capability is visible at every level that can cause the effect.

**Closures** carry the capabilities of the function that writes them. A function without
`uses` that calls a closure it was given runs whatever that closure's author was allowed to
do, which is how a pure `map` or a handler table can take effectful closures:

```eider
fn twice(f: fn(i32) -> i32) -> i32 { f(f(1)) }

fn main() uses io {
    let r = twice(|x| -> i32 {
        print(x)
        x + 1
    })
    print(r)
}
```

```output
1
2
3
```

Some more details:

- **Methods and trait methods** declare `uses` like functions. A generic body is checked
  for every type it is instantiated with, so a generic function over a trait must declare
  the capabilities of the most demanding implementation (std's stream functions declare
  `io` for that reason). Capabilities that follow type parameters are not in the language
  yet.
- **`test` blocks** run with every capability.
- **`comptime` evaluation** has none, so a constant can't depend on the environment.
- **`Drop` and `From` impls** can't declare capabilities (E0606, E0602): they run wherever a
  value goes out of scope or a `?` converts, where nothing could check them.

## Across packages: grants

A dependency is granted capabilities in the depender's `eider.toml`:

```toml
[deps.http]
git = "https://github.com/klxdev/eider-http.git"
version = "0.1.0"
uses = ["net", "io", "clock", "threads"]

[deps.json]
git = "https://github.com/klxdev/eider-json.git"
version = "0.1.0"                # no `uses`: granted nothing
```

The rules:

1. **Your own package** (the one with the program's entry file) is granted everything.
2. **`core` and `std`**, the toolchain's packages, need no grant. std has no unmanaged code
   and its functions declare what they reach, so their capabilities show up in your
   signatures anyway.
3. **Every other package** may use only what the package that imports it grants in its
   `[deps.<name>]` table. A package's use is everything named in the `uses` clauses of
   the functions and methods the program loads from it, plus `ffi` if it has `extern`
   functions, `unsafe fn`s or `unsafe` blocks.
4. **Grants are per edge.** If your app depends on `http` and `http` depends on `json`,
   `json` is held to the grant in `http`'s `eider.toml`, not yours. When several packages
   depend on one, eider-pkg locks the intersection of their grants.
5. **The compiler checks on every build** (E0204, at the import, with the help that names
   the table to edit), and **eider-pkg checks when it resolves** (`add`, `fetch`, `update`
   refuse a graph whose grants don't hold).

```text
error[E0204]: package `notes` uses capability `fs` in `save` (notes.ei:4) but is only granted []
  --> main.ei:1:1
  |
1 | import "notes"
  | ^
  help: to allow it, add "fs" to `uses` in [deps.notes] of <dir>/eider.toml
```

[Getting started](getting-started.md#capability-grants) walks through adding a dependency
that needs a grant.

### `ffi`: unmanaged code stays in its package

Calling C is the one thing the compiler can't check, so it is fenced in twice:

- The function that calls an `extern "c"` function declares `uses ffi` and wraps the call
  in `unsafe { }` (E0201, E0802).
- `ffi` **doesn't propagate across a package boundary**. Callers in other packages declare
  the real capabilities the wrapper reaches (`fs`, `io`, ...), and instead the package
  itself must be granted `ffi` by whoever depends on it.

So `ffi` in a grant means "this dependency contains code the compiler can't check", and
it is the line a reviewer should read first. The toolchain grants `ffi` to exactly one
package, `core`, whose C is the small OS layer every program runs on. A package
granted `ffi` can still only use the other capabilities it is granted.

### Seeing what a program uses

`scripts/ei caps file.ei` prints one JSON line per package and capability, with the first
function that uses it:

```text
{"package":"greet","dir":"<dir>/greet","cap":"fs","kind":"uses","fn":"main","file":"main.ei","line":3,"col":20}
{"package":"notes","dir":"<dir>/notes","cap":"fs","kind":"uses","fn":"save","file":"notes.ei","line":4,"col":70}
{"package":"core","dir":"<root>/core","cap":"ffi","kind":"extern","fn":"ec_in_clear","file":"sys.ei","line":11,"col":15}
```

`kind` is `uses`, `extern` or `unsafe`. eider-pkg uses this to check grants, so what it
checks is exactly what the compiler loads, not a text search.

## Known limits

- A grant is checked against everything the program loads of a package, not per imported
  module: eider-openapi, which is pure, grants http `net, io, clock, threads` because
  programs that use it load http's server too.
- Capabilities don't follow type parameters (see "Inside a program" above).
- Capabilities say *which kind* of effect, not *which* file or host. Narrower grants
  (paths, hosts) are not designed yet.
