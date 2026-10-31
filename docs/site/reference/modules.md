# Modules and packages

Every `.ei` file is a module. A module uses another with `import`, and sees only the items
the other declares `pub`. A *package* is a directory with an `eider.toml`: its modules can
be imported by the package's name, its dependencies are declared and locked, and each
dependency is granted the capabilities it may use. The toolchain's `core` and `std` are
packages too.

## Imports

```text
import = "import" path ["as" name]
       | "import" path "." "{" member {"," member} [","] "}"
       | "import" string ["as" name]                      (deprecated)
member = path ["as" name]
path   = name {"." name}
```

An import names a module by its *path*: identifiers joined by `.`. Paths name modules, never
files:

| Import | Names |
|---|---|
| `import std.fs`, `import core.sys` | a module of the toolchain's `std` or `core` |
| `import json` | the entry module of the package `json` (a dependency, or this package) |
| `import json.stream` | the module `stream.ei` of the package `json` (`a.b.c`: its file `b/c.ei`) |
| `import app.util` | in the package `app`: its own module `util.ei`, by the package's name |
| `import util`, `import lib.geo` | in a file that is in no package: the file `util.ei` (`lib/geo.ei`) beside it |
| `import std` | the package namespace (below) |

The module is then named by its *alias*: the name after `as`, or by default the path's last
segment (`fs` for `std.fs`, `json` for `json`, `stream` for `json.stream`). A module's public
items are used as `alias.Name`: `fs.read(path)`, `geo.Point(1, 2)`, `geo.North`, and in
types and patterns (`geo.Shape`, `geo.Circle(r) => ...`). A local variable may have an
alias's name; inside its scope `x.f` then means the variable's field. Use sites always stay
qualified: no import brings a module's names in unqualified, so no import can make two
names collide.

A group imports several modules that share a prefix, each with its own alias; it may span
lines:

```eider
import std.{
    strings,
    fs as files,
}

fn main() uses io, fs {
    print(strings.repeat("ab", 3))
    print(files.exists("no-such-file".bytes()))
}
```

```output
ababab
false
```

Imports may appear anywhere among the items of a file and may form cycles: two modules may
import each other. A module imported several times, by different files, paths or aliases,
is loaded once. Package and module names are identifiers (and not keywords).

**The package namespace.** `import std` (or `import core`) binds one name, `std`, to the
whole package: `std.strings.repeat(...)`, `std.time.Duration` in a type. A module behind the
namespace is loaded on its first use, so a program loads, and `eiderc caps` and the editor
report, only the modules it actually uses. Importing `std` and `std.strings` both is fine:
they name the same module. A namespace use names exactly one module, then an item of it.

```eider
import std

fn main() uses io {
    print(std.strings.repeat("-", 5))
}
```

```output
-----
```

**Style.** Import the modules a file uses heavily directly (`import std.{bytes, fs}`, then
`bytes.eq(...)`), and reach occasional ones through the namespace (`std.time.mono_ms()`), so the
import list stays a short, honest inventory.

**Errors.** A module that doesn't exist is E0804 ("unknown module `std.nope`"), also when
the namespace names it; a first segment that is neither this package nor one of its
dependencies is E0809 (its help says `import app.util` when you meant one of your own
modules); a package that names itself as a dependency is E0812; an alias that already names
another module is E0813:

```eider,compile_fail=E0804
import std.nope

fn main() {}
```

```eider,compile_fail=E0813
import std.fs
import std.io as fs

fn main() {}
```

There are no wildcard imports (`import std.*`) and no `from` forms (`import bytes from
std`): name the modules, group them, or import the namespace (E0001, whose help says so).

**The quoted form** `import "std/fs"`, `import "lib/geo.ei"` still works, deprecated
silently: a string with a `.` or a leading `/` is a file relative to the importing file;
anything else is a package path (`"json/stream"`), with the default alias the file's stem.
`eiderc migrate-imports <file>` prints the file with each quoted import rewritten in the
dotted form that loads the same module (`--json`: the fixes), and
`scripts/migrate-imports-dotted.sh` applies it to whole directories. An import with no
dotted form (`"../lib/geo.ei"` from a file in no package) stays quoted.

## Visibility

Items are private to their module unless declared `pub`: functions, types (records, enums,
aliases), constants and traits. Using a private item from another module is E0801 ("mark
it `pub` in its own file"). What `pub` makes visible:

- `pub type` makes the type, its fields and, for an enum, its variants usable;
- `pub fn`, `pub const`, `pub trait`, `pub extern "c" fn`, `pub unsafe fn`;
- methods in an `impl` follow the visibility of their type (an `impl` takes no `pub`);
- `export fn` is always public.

A public function's signature may mention private types of its module, and a public alias
may name private types.

```eider,compile_fail=E0801
import std.strings

fn main() uses io {
    print(strings.empty())
}
```

(`strings.empty` is a private helper of std/strings.)

> **Note:** Two quirks are kept for now, for compatibility with recorded test output:
> `alias.Enum.Variant` is E0114 for an enum of an imported module (write `alias.Variant`),
> and a private field type checked while constructing a record from another module is
> reported against the constructing file.

## The `module` line

A file may start with `module name` or `module a.b.c`. The line is accepted for
compatibility and ignored: a module's name is its file (or its path in its package), not
what the line says.

## Module identity

Every module of a program has one identity, and two different files may not share one
(E0808):

- A file in a package is identified by (package name, path inside the package without
  `.ei`), which is also how it is imported: `json.encode` and `app.encode` are different
  modules, so two packages may each have a `util.ei`.
- A file in no package is identified by its file stem. Two such files with one stem in a
  program, `a/util.ei` and `b/util.ei`, are E0808 (rename one, or put them in packages).

Files are told apart by their real path (symlinks resolved), so different paths to one
file are one module.

## Packages: `eider.toml`

A file belongs to the package of the nearest `eider.toml` in its directory or above it. The
manifest names the package and its dependencies:

```toml
[package]
name = "warehouse"        # lowercase letters, digits, _; not `core` or `std`
version = "0.1.0"         # MAJOR.MINOR.PATCH
entry = "warehouse.ei"    # what `import warehouse` loads (default: <name>.ei)
main = "main.ei"          # the program entry for eider-pkg (optional)
eider = "0.1"             # the toolchain MAJOR.MINOR it needs (optional)

[deps.json]               # one table per dependency, named like the package
path = "../json"          # a local directory ...
uses = []                 # capabilities granted to it (default: none)

[deps.http]
git = "https://example.com/http.git"   # ... or a git repository
version = "1.2.0"                      # minimum version (tag v1.2.0 or 1.2.0), or rev = "<commit>"
uses = ["net", "io"]
```

An import `P` or `P.path` is allowed when P is the importing file's own package or a direct
dependency of it (`[deps.P]` in its `eider.toml`); otherwise it is E0809, whose help gives
the `eider-pkg add` command (or `import P.<module>` when you named one of your own modules
without the package's name). A file in no package imports no packages but `std` and
`core`: there `import json` is the file `json.ei` beside it. A first segment that is both
the package's own name and a dependency's is E0812.

`std.*` and `core.*` are always available: they are the toolchain's own modules (found
through `EIDER_ROOT` or next to the compiler); `std` and `core` alone are their
namespaces.

Visibility is per package: a program sees its own dependencies, and each dependency sees
its own (from its own `eider.toml`). The capability grants in `uses` are checked at each
import edge (E0204, see [Capabilities](capabilities.md#grants-to-packages)).

## Resolution: `eider.lock`

Where each dependency lives is in `eider.lock`, which `eider-pkg fetch` writes for the
whole dependency graph next to the root package's `eider.toml` (the root is the entry
file's package):

```toml
# eider.lock: written by `eider-pkg`. Do not edit.
version = 1

[[package]]
name = "json"
version = "0.1.0"
source = "path+../json"
deps = []
grants = []

[[package]]
name = "http"
version = "1.2.0"
source = "git+https://example.com/http.git#89abcdef0123456789abcdef0123456789abcdef"
hash = "sha256-aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
deps = ["json"]
grants = ["net", "io"]
```

The compiler reads it to find a package's directory:

- a `path+<dir>` source is `<dir>`, relative to the lock file;
- a `git+` source is `vendor/<name>` beside the lock when that directory exists, else the
  package store, `$EIDER_HOME/pkg/<name>-<the first 16 hex digits of the hash>`
  (`EIDER_HOME` defaults to `~/.eider`).

No lock, no entry for the package, a missing directory, or an `eider.toml`/`eider.lock`
that doesn't parse is E0810, whose fix is to run `eider-pkg fetch`. The compiler never
touches the network and doesn't re-hash the store; eider-pkg checks hashes when it fetches.

`eider = "0.1"` says which toolchain MAJOR.MINOR the package is written for. Before 1.0 a
MINOR release may break compatibility, so the compiler checks it on every build: a package
whose `eider` is not the running toolchain's MAJOR.MINOR (`eiderc --version`), or is not a
MAJOR.MINOR at all, is E0811, reported at 1:1 of the entry file for the entry file's own
package and at the first import that loads a module of any other package. A package without
the field is not checked. See [Releases](../tooling/releases.md).

## eider-pkg

The package manager (`scripts/eider-pkg`, the program in `packages/pkg`) edits the
manifest, resolves versions and fills the store. Only `add`, `remove`, `fetch`, `update` and
`vendor` may use the network.

| Command | Does |
|---|---|
| `eider-pkg init [name]` | a new package: `eider.toml` and a `main.ei` |
| `eider-pkg add <name> --path P [--uses a,b]` | adds a path dependency |
| `eider-pkg add <name> --git URL (--version V \| --rev R) [--uses a,b]` | adds a git dependency |
| `eider-pkg remove <name>` | removes a dependency |
| `eider-pkg fetch [--offline]` | resolves (keeping the lock's pins), writes `eider.lock`, fills the store |
| `eider-pkg update [--offline]` | resolves again, ignoring the lock |
| `eider-pkg vendor` | copies the git packages into `vendor/` for offline builds |
| `eider-pkg tree` | prints the locked graph |
| `eider-pkg hash <dir>` | the content hash of a directory |

`-C <dir>` runs in another directory. Versions are resolved by minimal version selection.
After resolving, eider-pkg asks the compiler what each package uses (`eiderc caps`) and
refuses a dependency whose use exceeds its grant.

`compiler/tests/pkgs` in the repository covers every rule above (three `util` modules in one program, a vendored and a stored git package, and every
error).

> **Note:** A package registry, `eider api-diff` for semantic versioning and per-module
> incremental compilation are planned; see the [roadmap](../../design/roadmap.md)
> (P1.8, 8.12, 8.14).
