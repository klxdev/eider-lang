# Getting started

This page takes you from a fresh checkout to a running program and a first package. It
takes about five minutes, most of which is your C compiler building the Eider compiler once.

## What Eider is

Eider is a compiled, statically typed language for systems, services and everyday programs.
Its aim is to be as simple to write as Go or Zig while giving the memory-safety and
correctness guarantees of Rust:

- **No garbage collector, no lifetimes, no null.** Values have value semantics; `let` binds
  a read-only reference, `let mut` a mutable one, and the compiler checks that nothing a
  reference points into is freed or moved while it is in use ([Memory](memory.md)).
- **Errors are values.** `Result`, `Option` and `?`, with every `match` checked for
  exhaustiveness ([Errors](errors.md)).
- **Side effects are declared.** A function that does I/O says so (`uses io`, `fs`, `net`,
  `clock`, `threads`), and a dependency can only do what your manifest grants it
  ([Capabilities](capabilities.md)).
- **No silent mistakes at run time.** Integer overflow, out-of-bounds indexing and failed
  assertions stop the program with a message and exit code 101, in every build.

The compiler, `eiderc`, is written in Eider and emits portable C11, which your C compiler
turns into a native binary. Its own C output is committed to the repository as
`seed/eiderc.c`, so building Eider needs nothing but a C compiler.

## Requirements

- A C11 compiler: `cc`, gcc or clang (set `CC` to choose one).
- A POSIX system with threads (`-pthread`). Development happens on x86-64 Linux, which is
  the only platform tested so far.

Optional:

- For WebAssembly output: clang with the `wasm32` target and `wasm-ld` ([WebAssembly](wasm.md)).
- For the package manager's git dependencies: `git`.

There is no other dependency: no Python, no make, no third-party C libraries.

## Build the toolchain

From the root of an eider-lang checkout:

```sh
scripts/ei --help
```

The first run compiles `seed/eiderc.c` and the C core into `target/eiderc` (about 20
seconds) and then prints the compiler's usage. Afterwards `scripts/ei` runs that binary
directly, and rebuilds it only when the seed or `core/` changes. Every command on this site
is written as `scripts/ei <command>`.

If you prefer to see the bootstrap step itself, this is all `scripts/ei` does:

```sh
mkdir -p target
cc -std=c11 -O2 -pthread -I core -o target/eiderc seed/eiderc.c core/eider_rt.c core/eider_core.c
```

The compiler finds the toolchain (`core/` and `std/`) in `$EIDER_ROOT` or, when that isn't
set, in the parent of the directory that holds its binary (`target/eiderc` finds the
checkout). To call it from anywhere, put the checkout's `scripts/` directory on your `PATH`
(`export PATH="$PWD/scripts:$PATH"`) and run `ei`.

> **Tip:** `sh scripts/verify.sh` runs the whole test matrix (compile-fail suite, run tests
> under gcc, clang and the sanitizers, std, packages, the seed, C/C++ export, WebAssembly).
> It ends with `ALL GREEN` when everything passes; legs whose tools are missing are
> reported as skipped.

## Hello, world

Save this as `hello.ei`:

```eider
fn main() uses io {
    print("Hello, Eider!")
}
```

```output
Hello, Eider!
```

and run it:

```sh
scripts/ei run hello.ei
```

`fn main()` is the entry point. `uses io` declares that `main` writes to standard output:
`print` needs the `io` capability, and the compiler rejects a call that needs a capability
its caller hasn't declared (error E0201, with a fix that adds it).

`print` takes any printable value and adds a newline. Records, enums, lists and tuples
print themselves without any code:

```eider
type Point = { x: i32, y: i32 }

fn main() uses io {
    let p = Point(3, -4)
    print(p)
    print([1, 2, 3])
    print((p.x + p.y, "sum"))
}
```

```output
Point { x: 3, y: -4 }
[1, 2, 3]
(-1, "sum")
```

## Run, build and test

| Command | What it does |
|---|---|
| `scripts/ei run file.ei` | compile (C at `-O0`, fast) and run |
| `scripts/ei run --release file.ei` | the same at `-O2` |
| `scripts/ei build file.ei -o name` | a native binary at `-O2` (default name: the file's stem) |
| `scripts/ei test file.ei` | compile and run the file's `test` blocks |
| `scripts/ei check file.ei` | type-check only; prints `ok` or the errors (`--json` for tools) |

`run` doesn't pass arguments to the program; to give it arguments, `build` it and run the
binary. Compiled binaries are cached (by default under `~/.cache/eider`), so running an
unchanged program again skips the C compiler. [The compiler CLI](../tooling/compiler.md)
lists every command and option.

Tests live next to the code they test, in `test` blocks:

```eider
fn fizz(n: i32) -> String {
    if n % 15 == 0 { return String.from("FizzBuzz") }
    if n % 3 == 0 { return String.from("Fizz") }
    if n % 5 == 0 { return String.from("Buzz") }
    String.from_int(n as i64)
}

fn main() uses io {
    for i in 1..16 { print(fizz(i)) }
}

test "multiples of three and five" {
    assert fizz(3) == String.from("Fizz")
    assert fizz(10) == String.from("Buzz")
    assert fizz(30) == String.from("FizzBuzz"), "30 is a multiple of both"
}

test "other numbers" {
    assert fizz(7) == String.from("7")
}
```

`scripts/ei test fizz.ei` runs every test block and reports each one:

```text
test multiples of three and five ... ok
test other numbers ... ok

2 tests, 0 failed
```

A failing `assert` prints its message (or `assertion failed`) with the file and line, a trap
inside a test fails only that test, and the run exits 1 when any test failed.
[Testing](testing.md) covers std/testing's assertions and test doubles, and compile-fail
tests.

When something is wrong, the compiler reports every independent error it finds, each with
a stable code, the exact position, and often a fix. For this `main.ei`:

```eider,compile_fail=E0201
fn greet() {
    print("hi")
}

fn main() uses io {
    greet()
}
```

```text
error[E0201]: call to `print` requires capability `io`
  --> main.ei:2:5
  |
2 |     print("hi")
  |     ^
  fix: at 1:11 delete 0 insert " uses io"
error: 1 error
```

## A first package

A package is a directory with an `eider.toml`. The package manager, `eider-pkg`, creates
one, adds dependencies and writes the lock file. It is itself an Eider program, which
`scripts/eider-pkg` builds on first use.

```sh
scripts/eider-pkg -C greet init
```

```text
created package `greet`
```

This makes `greet/eider.toml` and a `greet/main.ei` that prints a line:

```toml
[package]
name = "greet"
version = "0.1.0"
main = "main.ei"
```

Run it like any file: `scripts/ei run greet/main.ei`. (`-C dir` runs eider-pkg in `dir`; you
can also `cd greet` and leave it out. The examples below run inside `greet/`, with
`$EIDER` standing for the path of your eider-lang checkout.)

### Add a dependency

Add [eider-json](https://github.com/klxdev/eider-json) as a git dependency (its release
0.1.0, the tag `v0.1.0`):

```sh
$EIDER/scripts/eider-pkg add json --git https://github.com/klxdev/eider-json.git --version 0.1.0
```

```text
locked 1 package(s)
```

`add` appends a `[deps.json]` table to `eider.toml`, resolves the graph and writes
`eider.lock`. Import the package by name and use it:

```eider,ignore
import "json"

fn main() uses io {
    let text = String.from("{\"name\": \"Eider\", \"year\": 2026}").bytes()
    match json.parse(text) {
        Ok(doc) => {
            let name = json.field(doc, doc.root, "name").and_then(|id| json.as_str(doc, id))
            print(String.from_bytes(name.unwrap()).unwrap())
        }
        Err(e) => print(String.from_bytes(json.error_text(e)).unwrap())
    }
}
```

```text
Eider
```

(This block isn't run by the docs' tests, which have no package directory; it was run in
the `greet` package above.) The compiler finds `json` through `eider.lock`; `import
"json/a/b"` would load the package's file `a/b.ei`. Git dependencies take a URL and a
minimum version or a commit (`--rev <commit>`); a local directory is a path dependency,
`eider-pkg add geom --path ../geom`. Only `add`, `remove`, `fetch`, `update` and `vendor`
touch the network; to work offline, or on a checkout of a dependency with your own changes,
name it in `EIDER_PKG_OVERRIDE` (`EIDER_PKG_OVERRIDE=json=../eider-json eider-pkg fetch`;
[eider-pkg](../tooling/eider-pkg.md#overriding-a-git-dependency)).

### Capability grants

A dependency can only use the capabilities you grant it. Suppose a package `notes` has a
function that writes files (`pub fn save(...) uses fs`). Adding it without a grant fails:

```sh
$EIDER/scripts/eider-pkg add notes --path ../notes
```

```text
eider-pkg: package `notes` uses capability `fs` (notes.ei:4) but is only granted []; to allow it, add "fs" to `uses` in its [deps.notes] table
```

Grant it explicitly:

```sh
$EIDER/scripts/eider-pkg add notes --path ../notes --uses fs
```

```toml
[deps.notes]
path = "../notes"
uses = ["fs"]
```

The compiler checks the same thing on every build (E0204 if the grant is missing), and your
own function that calls `notes.save` must still declare `uses fs` itself. So a
dependency's reach is visible twice: in your manifest and in your signatures.
[Capabilities](capabilities.md) explains the rules.

### Project layout

```text
greet/
  eider.toml        # the manifest: name, version, entry, main, [deps.*] with grants
  eider.lock        # written by eider-pkg: every package's source, hash and grants
  main.ei           # `main = "main.ei"`: the program
  greet.ei          # the library entry, what `import "greet"` loads (`entry` changes it)
  util.ei           # other modules, imported by path: `import "util.ei"`
  tests/
    greet_test.ei   # test programs, run with `scripts/ei test` or `run`
  vendor/           # optional: `eider-pkg vendor` copies git dependencies here
```

Inside a package, files import each other by relative path (`import "util.ei"`) and the
toolchain and dependencies by name (`import "std/fs"`, `import "json"`). Commit
`eider.lock`. `eider-pkg tree` prints the locked graph with each package's grants.
[eider-pkg](../tooling/eider-pkg.md) documents every command and manifest field.

## Next steps

- [A tour of Eider](tour.md): the whole language in small runnable programs.
- [Memory](memory.md): references, `let mut`, `.copy()` and the errors you will meet first.
- [Errors](errors.md), [Capabilities](capabilities.md), [Concurrency](concurrency.md),
  [Testing](testing.md).
- [Building services](services.md): HTTP, JSON-RPC and OpenAPI services with the
  libraries in their own repositories (eider-http, eider-rpc, eider-openapi).
- [Coming from another language](coming-from.md): Rust, Go, Zig, C and TypeScript.
- [Editors](../tooling/editors.md): the language server and tree-sitter grammar.
