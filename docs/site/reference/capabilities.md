# Capabilities

A function that has an effect on the world outside the program (printing, reading files,
the network, the clock, starting threads, calling C) says so in its signature with a
`uses` clause. The compiler checks that every function declares the capabilities of
everything it calls, so the signature of a function tells what it can do, and a dependency
can't do more than its importer allows.

```eider
fn greet(name: str) uses io {
    print(name)
}

fn main() uses io {
    greet("eider")
}
```

```output
eider
```

## The capabilities

| Capability | Covers |
|---|---|
| `io` | standard input, output and error (`print`, std/io), program arguments, the environment, exiting (std/env) |
| `fs` | the file system (std/fs) |
| `net` | sockets and DNS (std/net) |
| `clock` | the clock and sleeping (`now_ms()`, std/time) |
| `threads` | starting threads (`spawn`) |
| `ffi` | calling C (`extern "c"` functions); see [C interop](ffi.md) |
| `python`, `js`, `wasm` | reserved for interop with those runtimes; accepted in `uses`, but nothing in the toolchain uses them yet |

Running another program (std/proc, std/child) needs `io, fs, net`, since the child can do
anything. Functions that compute without effects (std/bytes, std/strings, std/sort, the
collections) need nothing.

A name in `uses` that isn't one of these is E0203, which lists the known ones.

## The `uses` clause

```text
fn_signature = "fn" name [generics] "(" params ")" ["->" type] ["uses" cap {"," cap}]
```

`uses` comes after the result type, before the body, and lists capabilities separated by
commas (a repeated one is harmless). It may start on the next line. It belongs to
functions only: methods in an `impl` have it too, trait method declarations may have it,
and there is no file-level or module-level `uses`.

## The rule

A call needs, in the calling function's `uses`, every capability the callee declares
(E0201 "call to `f` requires capability `fs`"). The same holds for:

- the built-ins: `print` needs `io`, `now_ms` needs `clock`, `spawn` needs `threads`;
- methods and associated functions (`log.write()` with `fn write(self) uses fs`);
- using a function as a value (`let f: fn() = hello` needs `hello`'s capabilities where the
  value is made);
- a call written inside a closure: the closure's body is checked with the capabilities of
  the function it is written in.

So capabilities propagate up the call graph to `main`, which declares everything the
program does. E0201 comes with a machine-applicable fix that adds the capability to the
enclosing function's `uses`; applying it moves the error up one level, to that function's
callers.

```eider,compile_fail=E0201
fn save() uses fs {}

fn main() uses io {
    save()
}
```

A fn type carries no capabilities: calling a fn value needs nothing, because the
capabilities were checked where the closure or function value was made. A function that
takes a callback can call it whatever it does:

```eider
fn twice(f: fn()) {
    f()
    f()
}

fn main() uses io {
    twice(|| print("hi"))
}
```

```output
hi
hi
```

A trait method's implementation may declare capabilities its trait declaration doesn't;
the capabilities are checked at each call with the concrete type (see
[Traits](traits.md)). A `Drop` or `From` implementation can't declare any (E0606, E0602),
since those run wherever the language calls them.

## Tests, `main` and `comptime`

- `main` declares its capabilities like any function (`fn main() uses io, fs`).
- A `test` block is checked with every capability, so a test may call anything.
- A `comptime` initializer has none: the help of its E0201 says "`comptime` evaluation
  can't use capabilities" (see [Compile-time evaluation](comptime.md)).

## `ffi` stays inside its package

`ffi` is special in one way: it describes code, not an effect, so it propagates only
inside a package.

- Calling an `extern "c"` function needs `ffi` in the caller's `uses` (and an `unsafe`
  block, E0802; see [C interop](ffi.md)).
- Inside one package, `ffi` propagates like any capability: a wrapper declared
  `uses ffi` asks its callers in the same package for it. The files of a program that are
  in no package count as one package.
- Across a package boundary it doesn't: calling a function of another package needs the
  callee's capabilities except `ffi`. A package's `ffi` is instead granted to it by the
  packages that depend on it (below). The real capabilities still cross: core's wrapper
  around reading a file declares `uses ffi, fs`, so its callers in other packages need `fs`.

So a program calls std and core with `uses io`, `uses fs`, ..., never `uses ffi`:

```eider
import "std/fs"

fn main() uses io, fs {
    print(fs.exists("no-such-file".bytes()))
}
```

```output
false
```

## Grants to packages

Every package a program depends on is held to the capabilities its importer grants it. In
the importing package's `eider.toml`, each dependency's table lists what it may use:

```toml
[deps.json]
path = "../json"

[deps.store]
git = "https://example.com/store.git"
version = "1.2.0"
uses = ["fs"]
```

A dependency's *capability use* is computed by the compiler from the modules the program
loads from it: every capability named in a `uses` clause of one of its functions (test
blocks excluded), plus `ffi` when it has unmanaged code: an `extern` function, an
`unsafe fn` or an `unsafe` block. Each capability it uses must be in its grant (absent
`uses`: nothing granted), else E0204 at the import:

```text
error[E0204]: package `fsdep` uses capability `fs` in `save` (fsdep.ei:5) but is only granted []
  --> app/main.ei:2:1
  help: to allow it, add "fs" to `uses` in [deps.fsdep] of <dir>/eider.toml
```

- Grants are per dependency edge: a dependency's own dependencies are held to the grants
  in its own `eider.toml`.
- The entry file's package is granted everything; `core` and `std` are the toolchain's and
  need no grant (core is the one package the toolchain grants `ffi`; std has no unmanaged
  code).
- A file in no package can import packages only by path, and isn't held to grants.

The cases are in `compiler/tests/pkgs` (`grants_ok`, `grants_fs`, `grants_chain`) and
`tests/checks/fail/e0204_*`. Packages and `eider.toml` are described in
[Modules and packages](modules.md).

## `eiderc caps`

`eiderc caps <file.ei>` loads a program as `check` does and prints one JSON line per
(package, capability), at its first use:

```json
{"package":"files","dir":"/src/files","cap":"fs","kind":"uses","fn":"here","file":"files.ei","line":14,"col":10}
```

`kind` is `uses`, `extern` or `unsafe`; `fn` is `name` or `Type.name`; `file` is relative
to the package's directory (a file in no package has `"package":""`). eider-pkg runs it to
check grants when it adds or fetches a dependency.
