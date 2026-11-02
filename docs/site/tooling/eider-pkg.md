# The package manager: eider-pkg

`eider-pkg` creates packages, edits their dependencies, resolves the dependency graph,
checks every dependency's capabilities against its grant, and writes `eider.lock`. It is
written in Eider (`packages/pkg`). In a checkout, run it as `scripts/eider-pkg`, which
builds `target/eider-pkg` when its sources change and sets `EIDER_ROOT` to the checkout.
eider-pkg reads TOML with eider-toml, a release the checkout pins in `vendor.lock`: the first
run fetches it into `.vendor/toml` and checks its content hash, from a checkout of eider-toml
next to eider-lang (`../eider-toml`, or `EIDER_SIBLINGS`/`EIDER_TOML`), a local mirror or
tarball (`EIDER_VENDOR_SOURCES`), or GitHub; with none of them it stops with exit 3 and says
what it tried (the repository's `LAYERS.md`, "Vendored libraries").

The compiler doesn't need eider-pkg to build: it reads `eider.toml` and `eider.lock`
itself and finds each dependency's directory from the lock. eider-pkg is what writes the
lock and fetches git packages.

## Commands

```text
eider-pkg [-C dir] init [name]
eider-pkg [-C dir] add <name> --path <dir> [--uses a,b | --confirm | --no-grant]
eider-pkg [-C dir] add <name> --git <url> (--version <v> | --rev <r>) [--uses a,b | --confirm | --no-grant]
eider-pkg [-C dir] remove <name>
eider-pkg [-C dir] grant <name> <cap,...>
eider-pkg [-C dir] revoke <name> <cap,...>
eider-pkg [-C dir] fetch [--offline] [--grant a,b | --grant-all]
eider-pkg [-C dir] update [--offline] [--grant a,b | --grant-all]
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
| `add <name> ...` | Append a `[deps.<name>]` table, resolve, grant the package what it uses (`uses = [...]`, sorted; see [Grants](#grants)), check grants and write `eider.lock`, printing `added <name> <version> — it uses: <caps> (granted)`. If resolution or a grant check fails, `eider.toml` is restored. `--confirm` asks first (y/N, on standard input); `--no-grant` writes no grant, and when the package uses something keeps the table but stops before writing `eider.lock`; `--uses io,fs` is an explicit grant, which must cover what the package uses. |
| `remove <name>` | Delete the `[deps.<name>]` table (an inline `name = { ... }` entry must be removed by hand) and re-resolve. |
| `grant <name> <cap,...>` | Add capabilities to the `uses` of `[deps.<name>]`, in place (E0204's help names this). No resolving: the next build sees it; `eider.lock`'s copy of the grants follows at the next `fetch`. |
| `revoke <name> <cap,...>` | Take capabilities out of it, the same way. A package that still uses one fails to build (E0204), and `fetch` stops on it, until it is granted again. |
| `fetch` | Resolve, keeping the commits `eider.lock` pins, fetch what is missing into the store, hold every direct dependency's grant to what it uses (narrow one that shrank, stop on one that grew unless `--grant <name>,...` or `--grant-all` accepts it), check grants and write `eider.lock`. |
| `update` | The same, ignoring the pins: re-resolve every git dependency from its tags and refresh the mirrors (tags can move). |
| `vendor` | Copy every git package into `.vendor/<name>`, drop vendored packages the graph no longer has, and check that resolving from `.vendor/` alone gives the same lock. The compiler then reads `.vendor/` before the store, so the project builds offline with no store. `.vendor/` is hidden; commit it or ignore it, as you choose. |
| `tree` | Print the locked graph, each package with its version and grants; a package seen before is marked `(*)`. |
| `hash <dir>` | Print the content hash of a directory, as the lock records it. |
| `--version` | Print `eider-pkg <version>`: the toolchain's version (VERSION; see [Releases](releases.md)). Only before a command: `add --version` is a dependency's version. |

`--offline` makes `fetch` and `update` fail instead of touching the network. Only `add`,
`remove`, `fetch`, `update` and `vendor` ever do, and `fetch` only when a pinned commit
isn't already in the local mirror. Errors are printed as `eider-pkg: <message>` with exit
code 1 on stderr (one line, except the capability diff below); stdout carries only what a
command reports when it succeeds, notes included.

## Grants

A dependency may use only the capabilities its depender grants it (`uses = [...]` in
`[deps.<name>]`; [Capabilities](../guide/capabilities.md)). The grant is the recorded
consent, and eider-pkg writes it from what the compiler says the package uses
(`eiderc caps` over every module of the package):

```text
$ eider-pkg add http --git https://github.com/klxdev/eider-http.git --version 0.3.0
added http 0.3.0 — it uses: clock, fs, io, net, threads (granted)
locked 3 package(s)

$ eider-pkg update
eider-pkg: more capabilities than granted (eider.lock is not written):
  http 0.3.0 now also uses: fs (granted: clock, fs, io, net, threads)
    first used: fs (static.ei:12)
to accept: eider update --grant http (or --grant-all)

$ eider-pkg update --grant http
locked 3 package(s)

$ eider-pkg fetch
note: http 0.3.1 no longer uses: clock; its grant is narrowed to: fs, io, net, threads
locked 3 package(s)

$ eider-pkg grant json io
json: uses = ["io"] (granted io)
```

- **Only direct dependencies.** `fetch` and `update` compute each direct dependency's set
  and compare it with the grant. Growth stops the command before `eider.toml` or
  `eider.lock` is written, with every grown package in the diff; shrinking narrows the grant
  and prints a note. A dependency's own dependencies are granted by its own `eider.toml`
  (written the same way by its author), and held to the intersection of what their dependers
  grant: the error then names every missing capability and the `uses = [...]` that covers
  them.
- **Edits keep the file.** Only the `uses` of one `[deps.<name>]` table is rewritten (a
  multi-line array becomes one line; the indentation and a comment after it are kept), or a
  `uses` line is added after the table's last key. Comments, blank lines and other tables
  are left byte for byte.
- **Policy.** An optional `[policy]` bounds what this manifest may grant:

  ```toml
  [policy]
  deny = ["ffi"]            # never granted to any dependency

  [policy.allow]
  net = ["http", "rpc"]     # only these dependencies may be granted `net`
  ```

  An automatic grant, an accepted growth, `--uses`, `grant`, or a hand-written grant found by
  `fetch` that breaks it fails with the rule: ``cannot grant `ffi` to `cffi`: the policy
  denies it to every dependency ([policy] deny = ["ffi"] in <dir>/eider.toml)``.

## eider.toml

```toml
[package]
name = "warehouse"          # lowercase letters, digits and `_`, starting with a letter; not `core` or `std`
version = "0.1.0"           # MAJOR.MINOR.PATCH
entry = "warehouse.ei"      # what `import warehouse` loads (default: <name>.ei)
main = "main.ei"            # the program, for packages that are one (optional)
eider = "0.4"               # the toolchain MAJOR.MINOR it needs (optional; the compiler checks it, E0811)
description = "What it is"  # optional

[deps.json]                 # one table per dependency; the key is the package's own name
git = "https://example.com/json.git"
version = "1.2.0"           # a minimum version: the tag v1.2.0 (or 1.2.0)
uses = ["io"]               # the capabilities granted to it (default: none); `add` writes it

[deps.geom]
path = "../geom"            # a local directory

[deps.edge]
git = "https://example.com/edge.git"
rev = "main"                # a branch, tag or commit instead of a version

[policy]                    # optional: what this package may grant (see Grants)
deny = ["ffi"]
[policy.allow]
net = ["json"]

[lints]                     # optional: lint levels for `eiderc lint` ("allow", "warn" or "deny")
unused_uses = "deny"
```

Unknown keys are errors (a typo like `verison` is caught). A dependency needs exactly one of
`path` and `git`; a git dependency exactly one of `version` and `rev`; a path dependency
neither. `uses` takes `io`, `fs`, `net`, `clock`, `threads` and `ffi`. `eider` must be a
MAJOR.MINOR (`"0.1"`, not `"0.1.0"`); eider-pkg checks its form, the compiler checks it
against the toolchain on every build.

A package's modules import their own modules by the package's name (`import warehouse.util`),
and the toolchain and their direct dependencies by theirs: `import json` loads the entry
module, `import json.a.b` the file `a/b.ei`. Importing a package that isn't a direct
dependency is E0809.

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
  resolving, eider-pkg asks the compiler what each package really uses (`eiderc caps` on a
  probe program importing its modules: every one for a direct dependency, what the entry
  module reaches for the others, since which modules a library loads is its own business) and
  refuses the graph if a package uses more than its grant, naming everything missing:

```text
eider-pkg: package `notes` uses fs (notes.ei:4), io (log.ei:2) but is only granted []; its dependers must grant it `uses = ["fs", "io"]` in their [deps.notes] table
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
used. The compiler finds a git package in `.vendor/<name>` next to the lock when that
exists, else in `pkg/<name>-<first 16 hex digits of its hash>`.

## Environment

| Variable | Meaning |
|---|---|
| `EIDER_ROOT` | the toolchain checkout (with `core/` and `std/`); `scripts/eider-pkg` sets it |
| `EIDERC` | the compiler eider-pkg asks about capabilities (default `$EIDER_ROOT/target/eiderc`) |
| `EIDER_HOME` | the store (default `~/.eider`) |
| `EIDER_PKG_OVERRIDE` | local checkouts standing in for git dependencies (below) |
| `EIDER_SIBLINGS`, `EIDER_TOML` | where `scripts/eider-pkg` finds eider-toml's checkout to fetch `.vendor/toml` from (default `..`) |
| `EIDER_VENDOR_SOURCES`, `EIDER_VENDOR_OFFLINE` | a directory of mirrors and tarballs for that fetch, and `1` to keep it off the network |

`git` must be on the `PATH` for git dependencies.

## Private git dependencies

For a `https://github.com/` URL, eider-pkg authenticates git with a token when one is at
hand: `GH_TOKEN`, else `GITHUB_TOKEN`, else what `gh auth token` prints (the same order
`eider` uses for releases). It runs git with `-c credential.https://github.com.helper=` (which
drops any other helper for github.com, a broken one included) and a one-off helper that
answers `x-access-token` and the token, read by the helper itself from the environment or
`gh`. The token is never on a command line, and `git -c` writes nothing to your git config or
to the store's mirrors. With no token, git uses your own credential setup. Other hosts always
use your git setup (a credential helper, or an SSH URL).

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
directory's `eider.toml`, else every file but `.git`, `deps`, `.vendor` and `target`. They are
copied into the store under their content hash, where the compiler finds them through
`eider.lock` as for any git package, so the lock keeps the git source: with a checkout of
exactly the locked release, the lock is the one a fetch from the network writes (the same
commit and hash). Otherwise the lock records the checkout's `HEAD` and the new hash; fetch
again without the override before committing it. The checkout's `version` must be at least
the one required.

The library repositories' `scripts/build.sh` set it for the sibling checkouts next to them
(eider-lang's `scripts/check-tools.sh` builds them that way, with json from the toolchain's
pinned copy in `.vendor/json` when there is no eider-json checkout; `scripts/vendor.sh`).

## Not yet

A package registry with a public checksum log, `eider-pkg audit` against advisories, and
semver checks of a package's API (`api-diff`) are planned (repository
`docs/design/roadmap.md`, P1.8).
