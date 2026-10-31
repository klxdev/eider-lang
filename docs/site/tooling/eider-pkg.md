# The package manager: eider-pkg

`eider-pkg` creates packages, edits their dependencies, resolves the dependency graph,
checks every dependency's capabilities against its grant, and writes `eider.lock`. It is
written in Eider (`packages/pkg`). In a checkout, run it as `scripts/eider-pkg`, which
builds `target/eider-pkg` when its sources change and sets `EIDER_ROOT` to the checkout.

The compiler doesn't need eider-pkg to build: it reads `eider.toml` and `eider.lock`
itself and finds each dependency's directory from the lock. eider-pkg is what writes the
lock and fetches git packages.

## Commands

```text
eider-pkg [-C dir] init [name]
eider-pkg [-C dir] add <name> --path <dir> [--uses a,b]
eider-pkg [-C dir] add <name> --git <url> (--version <v> | --rev <r>) [--uses a,b]
eider-pkg [-C dir] remove <name>
eider-pkg [-C dir] fetch [--offline]
eider-pkg [-C dir] update [--offline]
eider-pkg [-C dir] vendor
eider-pkg [-C dir] tree
eider-pkg hash <dir>
eider-pkg --version
```

`-C dir` runs the command in `dir` (default: the working directory); paths in other
arguments are relative to it.

| Command | What it does |
|---|---|
| `init [name]` | Write `eider.toml` (name from the argument or the directory, version `0.1.0`, `main = "main.ei"`, `eider` the toolchain's MAJOR.MINOR) and, if there is none, a `main.ei` that prints a line. Refuses if `eider.toml` exists. |
| `add <name> ...` | Append a `[deps.<name>]` table, resolve, check grants and write `eider.lock`. If resolution or a grant check fails, `eider.toml` is restored. `--uses io,fs` writes the grant. |
| `remove <name>` | Delete the `[deps.<name>]` table (an inline `name = { ... }` entry must be removed by hand) and re-resolve. |
| `fetch` | Resolve, keeping the commits `eider.lock` pins, fetch what is missing into the store, check grants and write `eider.lock`. |
| `update` | The same, ignoring the pins: re-resolve every git dependency from its tags and refresh the mirrors (tags can move). |
| `vendor` | Copy every git package into `vendor/<name>`, drop vendored packages the graph no longer has, and check that resolving from `vendor/` alone gives the same lock. The compiler then reads `vendor/` before the store, so the project builds offline with no store. |
| `tree` | Print the locked graph, each package with its version and grants; a package seen before is marked `(*)`. |
| `hash <dir>` | Print the content hash of a directory, as the lock records it. |
| `--version` | Print `eider-pkg <version>`: the toolchain's version (VERSION; see [Releases](releases.md)). Only before a command: `add --version` is a dependency's version. |

`--offline` makes `fetch` and `update` fail instead of touching the network. Only `add`,
`remove`, `fetch`, `update` and `vendor` ever do, and `fetch` only when a pinned commit
isn't already in the local mirror. Errors are printed as `eider-pkg: <message>` with exit
code 1 (on stdout, not stderr, for now).

## eider.toml

```toml
[package]
name = "warehouse"          # lowercase letters, digits and `_`, starting with a letter; not `core` or `std`
version = "0.1.0"           # MAJOR.MINOR.PATCH
entry = "warehouse.ei"      # what `import "warehouse"` loads (default: <name>.ei)
main = "main.ei"            # the program, for packages that are one (optional)
eider = "0.1"               # the toolchain MAJOR.MINOR it needs (optional; the compiler checks it, E0811)
description = "What it is"  # optional

[deps.json]                 # one table per dependency; the key is the package's own name
git = "https://example.com/json.git"
version = "1.2.0"           # a minimum version: the tag v1.2.0 (or 1.2.0)
uses = ["io"]               # the capabilities granted to it (default: none)

[deps.geom]
path = "../geom"            # a local directory

[deps.edge]
git = "https://example.com/edge.git"
rev = "main"                # a branch, tag or commit instead of a version
```

Unknown keys are errors (a typo like `verison` is caught). A dependency needs exactly one of
`path` and `git`; a git dependency exactly one of `version` and `rev`; a path dependency
neither. `uses` takes `io`, `fs`, `net`, `clock`, `threads` and `ffi`. `eider` must be a
MAJOR.MINOR (`"0.1"`, not `"0.1.0"`); eider-pkg checks its form, the compiler checks it
against the toolchain on every build.

A package's modules import their own files by relative path (`import "util.ei"`), and the
toolchain and their direct dependencies by name: `import "json"` loads the entry module,
`import "json/a/b"` the file `a/b.ei`. Importing a package that isn't a direct dependency
is E0809.

## eider.lock

Written by eider-pkg; commit it, and don't edit it:

```toml
# eider.lock: written by `eider-pkg`. Do not edit.
version = 1

[[package]]
name = "geom"
version = "0.2.0"
source = "path+../geom"
deps = []
grants = []

[[package]]
name = "json"
version = "1.2.0"
source = "git+https://example.com/json.git#<commit>"
hash = "sha256-<hex>"
deps = []
grants = []
```

Every package in the graph is listed once: its version, where it comes from (a path, or a
git URL and the exact commit), for git packages the SHA-256 content hash of its files, the
names of its dependencies, and the capabilities it was granted. A package whose directory,
lock entry or files are missing when the compiler needs it is E0810, with the fix
`run eider-pkg fetch in <dir>`.

## Resolution

- **Minimal version selection**, as in Go: every requirement reachable from the root is
  visited, and for each package the highest *required* version wins (not the newest
  available). A version changes only when some requirement in the graph asks for a
  higher minimum, never because a newer release appeared.
- A version `1.2.0` is the tag `v1.2.0` (or `1.2.0`) in the repository, whose
  `eider.toml` must say `version = "1.2.0"`.
- A git package may only depend on other git packages (a path in a published package
  would mean nothing elsewhere).
- **Grants are the intersection** of what every depender grants a package, and after
  resolving, eider-pkg asks the compiler what each package really uses (`eiderc caps` on
  its entry module) and refuses the graph if a package uses more than its grant:

```text
eider-pkg: package `notes` uses capability `fs` (notes.ei:4) but is only granted []; to allow it, add "fs" to `uses` in its [deps.notes] table
```

The compiler checks the same thing on every build (E0204). See
[Capabilities](../guide/capabilities.md).

## The store

Git packages live in a shared, immutable store, `$EIDER_HOME` (default `~/.eider`):

```text
~/.eider/
  git/<url-as-name>/        a bare mirror of each git source (the only network use)
  pkg/<name>-<hash16>/      an exported commit; immutable; re-hashed when used
  index/<commit>            the content hash of that commit's export
  tmp/                      staging
```

A store directory whose files no longer match their hash is an error, never silently
used. The compiler finds a git package in `vendor/<name>` next to the lock when that
exists, else in `pkg/<name>-<first 16 hex digits of its hash>`.

## Environment

| Variable | Meaning |
|---|---|
| `EIDER_ROOT` | the toolchain checkout (with `core/` and `std/`); `scripts/eider-pkg` sets it |
| `EIDERC` | the compiler eider-pkg asks about capabilities (default `$EIDER_ROOT/target/eiderc`) |
| `EIDER_HOME` | the store (default `~/.eider`) |
| `EIDER_PKG_OVERRIDE` | local checkouts standing in for git dependencies (below) |

`git` must be on the `PATH` for git dependencies.

## Overriding a git dependency

`EIDER_PKG_OVERRIDE` names local directories that stand in for git dependencies, for
working offline or on a checkout of a dependency with changes of your own:

```sh
EIDER_PKG_OVERRIDE=json=../eider-json,http=/src/eider-http eider-pkg fetch
```

Each entry is `<name>=<dir>` (separated by commas or spaces; a relative directory is relative
to the current directory). A git dependency with that name, anywhere in the graph, is taken
from the directory instead of its repository: no network, no tag needed, and uncommitted
edits count. The files are the ones git would commit (`git ls-files --cached --others
--exclude-standard`, so `target/` and other ignored files stay out) when git knows the
directory's `eider.toml`, else every file but `.git`, `deps`, `vendor` and `target`. They are
copied into the store under their content hash, where the compiler finds them through
`eider.lock` as for any git package, so the lock keeps the git source: with a checkout of
exactly the locked release, the lock is the one a fetch from the network writes (the same
commit and hash). Otherwise the lock records the checkout's `HEAD` and the new hash; fetch
again without the override before committing it. The checkout's `version` must be at least
the one required.

The library repositories' `scripts/build.sh` set it for the sibling checkouts next to them
(eider-lang's `scripts/check-tools.sh` builds them that way), and fall back to the
toolchain's pinned copies in `vendor/` (`scripts/vendor.sh`).

## Not yet

A package registry with a public checksum log, `eider-pkg audit` against advisories, and
semver checks of a package's API (`api-diff`) are planned (repository
`docs/design/roadmap.md`, P1.8).
