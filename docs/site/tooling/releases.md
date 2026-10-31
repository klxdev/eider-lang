# Versions and releases

Eider has one version number, for the language and everything that ships with it. It lives
in `VERSION` at the root of eider-lang, as `MAJOR.MINOR.PATCH` (`0.1.0`).

## The rule

Every tool shipped with Eider has the language's MAJOR.MINOR, and they are released
together. Each tool has its own PATCH, so a tool can get a fix between releases without
the others changing.

Eider follows semantic versioning before 1.0: while MAJOR is 0, a MINOR release may break
compatibility (a language change, a std API change, a new compiler error for code that
compiled), and a PATCH release doesn't. So `0.1.x` tools work with every `0.1.y` toolchain,
and a `0.2` toolchain needs `0.2` tools.

| Component | Repository | Version | `--version` prints |
|---|---|---|---|
| the language, the compiler `eiderc` | eider-lang | `VERSION` | `eiderc 0.1.0` |
| core and std | eider-lang | `VERSION` | (programs: `import core.version`) |
| `eider-pkg`, the package manager | eider-lang (`packages/pkg`) | `VERSION` | `eider-pkg 0.1.0` |
| `eider-doc`, the docs generator | eider-lang (`packages/doc`) | `VERSION` | `eider-doc 0.1.0` |
| the language server | eider-analyzer | its `VERSION` | `eider-analyzer 0.1.0 (eider 0.1.0)` |
| the tree-sitter grammar | tree-sitter-eider | its `VERSION` | (no binary) |
| the profiler | eider-profiler | its `VERSION` | `eider-profiler 0.1.0` |

Library packages keep their own `version` in their `eider.toml`, and eider-pkg selects them
by that version. The libraries and frameworks in repositories of their own (eider-toml,
eider-json, eider-markdown, eider-http, eider-rpc, eider-openapi) follow the tools' rule
until 1.0: their MAJOR.MINOR is the toolchain's, their PATCH their own, so `scripts/version.sh
check-siblings` and `bump` treat them as siblings. A package you write needs only
`eider = "<MAJOR.MINOR>"`.

## The version in code

The compiler reads no file to know its version: `core/version.ei` is the Eider copy of
`VERSION`, compiled into eiderc, eider-pkg and eider-doc, and into the seed
(`seed/eiderc.c`). A version bump is therefore an ordinary source change followed by a seed
regeneration, and the seed stays reproducible.

Programs can use it too:

```eider
import core.version

fn main() uses io {
    print(version.VERSION)
    print(version.SERIES)
}
```

```output
0.1.0
0.1
```

`version.MAJOR`, `version.MINOR` and `version.PATCH` are the numbers.

## Packages say which toolchain they need

A package's `eider.toml` can name the toolchain MAJOR.MINOR it is written for:

```toml
[package]
name = "warehouse"
version = "1.4.2"   # the package's own version
eider = "0.1"       # the toolchain it needs: MAJOR.MINOR
```

The compiler checks it on every build. A package whose `eider` isn't the running
toolchain's MAJOR.MINOR is error E0811:

```text
error[E0811]: package `newer` needs Eider 9.9 (`eider = "9.9"` in <dir>/lib/newer/eider.toml), but this toolchain is 0.1
  --> e0811_toolchain_series.ei:3:1
  |
3 | import lib.newer.newer
  | ^
  help: build it with an Eider 9.9.x toolchain, or port it to 0.1 and set `eider = "0.1"` in <dir>/lib/newer/eider.toml
```

`eider-pkg init` writes the field, and eider-pkg checks its form (`"0.1"`, not `"0.1.0"`).
A package without it isn't checked. Every eider.toml in eider-lang has it, and so do the
sibling tools' manifests.

## Checking the versions

```sh
scripts/version.sh                   # every component's version
scripts/version.sh check             # this checkout's copies of VERSION agree
scripts/version.sh check-siblings    # each sibling's VERSION has this MAJOR.MINOR
```

`scripts/verify.sh` runs both. `check` holds these equal to `VERSION`: the constants in
`core/version.ei`; `version` in the eider.toml of core, std, compiler, packages/pkg and
packages/doc; and `eider` (MAJOR.MINOR) in the eider.toml of core, std, compiler,
packages/* and examples/*. `check-siblings` is part of the tools leg
(`scripts/check-tools.sh`): it reads eider-analyzer's, tree-sitter-eider's and
eider-profiler's `VERSION` (from `EIDER_ANALYZER`, `TREE_SITTER_EIDER`, `EIDER_PROFILER`,
default `../<name>` next to the checkout), fails when one has another MAJOR.MINOR, runs the
sibling's own `scripts/version.sh check` when it has one, and reports each component's
version on one line:

```text
ok   versions: eider-lang 0.1.0, eider-analyzer 0.1.0, tree-sitter-eider 0.1.0, eider-profiler 0.1.0 (same MAJOR.MINOR)
```

A sibling that isn't there is named as absent, not failed.

## Bumping

```sh
scripts/version.sh bump minor                    # 0.1.3 -> 0.2.0, every component
scripts/version.sh bump major                    # 0.4.1 -> 1.0.0, every component
scripts/version.sh bump patch                    # eider-lang only: 0.1.0 -> 0.1.1
scripts/version.sh bump patch eider-analyzer     # one sibling only
```

A MINOR or MAJOR bump moves every component to the new MAJOR.MINOR with PATCH 0, and
rewrites every `eider = "<old MAJOR.MINOR>"` in eider-lang and the siblings. A PATCH bump
moves one component. The script writes `VERSION` and its copies (in a sibling, through the
sibling's `scripts/version.sh sync`) and commits nothing; it prints what comes next:

```sh
sh scripts/selfhost.sh --seed          # the seed embeds core/version.ei
BLESS=1 sh scripts/test-compiler.sh    # E0811's message names the MAJOR.MINOR: review the diff
```

then a section for the new version in each bumped repository's `CHANGELOG.md`, and a commit
in each.

## Releasing

```sh
scripts/release.sh
```

1. **Checks.** eider-lang and the three siblings are present and clean (no uncommitted or
   untracked files); `scripts/version.sh check` and `check-siblings` pass; each
   `CHANGELOG.md` has a `## <version>` section; the seed's `eiderc --version` and
   `eider-pkg --version` print the version; `scripts/verify.sh` ends with ALL GREEN, its
   tools leg having built and tested the siblings; `scripts/selfhost.sh` prints
   SELF-HOSTED.
2. **The manifest.** `target/release/eider-<version>/RELEASE.toml` lists each component's
   exact version, commit and tag:

   ```toml
   [release]
   version = "0.1.0"
   series = "0.1"
   date = "2026-10-31"
   verified = true

   [component.eider-lang]
   version = "0.1.0"
   commit = "<40 hex digits>"
   tag = "v0.1.0"
   contains = ["eiderc", "core", "std", "eider-pkg", "eider-doc", "docs"]

   [component.eider-analyzer]
   version = "0.1.0"
   commit = "<40 hex digits>"
   tag = "v0.1.0"
   ```

3. **The bundle.** `target/release/eider-<version>.tar.gz` holds RELEASE.toml, a README,
   and each repository's committed files at its commit, side by side: `eider-lang/` (the
   seed, core, std, the compiler, scripts, eider-pkg, eider-doc, the packages and the docs;
   not the tests), `eider-analyzer/`, `tree-sitter-eider/` and `eider-profiler/`. The README
   says how to build all of it with only a C compiler, plus node for regenerating the
   grammar. The tarball is reproducible: the same commits give the same bytes.
4. **The tags.** The script prints a `git tag -a v<version>` command for each repository,
   at the commit it bundled, and the `git push origin v<version>` commands. It runs neither:
   tagging and pushing the tags happen when a release is decided.

`scripts/release.sh --skip-verify` does everything but the verify and selfhost runs, to try
the script; its RELEASE.toml says `verified = false` and it prints no tag commands to run.

## What every shipped tool provides

A tool in its own repository (eider-analyzer, tree-sitter-eider, eider-profiler, and any
future one) is part of a release when it has:

- **`VERSION`** at its root: `MAJOR.MINOR.PATCH`, with the toolchain's MAJOR.MINOR.
- **`--version`** printing `<tool> <VERSION>` on stdout, exit 0 (more after it is allowed,
  such as the toolchain it was built with: `eider-analyzer 0.1.0 (eider 0.1.0)`). An Eider
  tool keeps an Eider copy of VERSION (eider-analyzer's `lsp_version.ei`) and imports
  `core/version` for the toolchain's.
- **`eider = "<MAJOR.MINOR>"`** in its eider.toml, if it is written in Eider.
- **A build check**: its build script reads the toolchain checkout's `VERSION` and stops,
  with a message naming both versions, when the MAJOR.MINOR differs or there is none.
- **`scripts/version.sh check` and `sync`** (optional, recommended): `check` exits 1 when a
  file that repeats the version (package.json, a plugin manifest, the Eider constant)
  disagrees with `VERSION`; `sync` writes `VERSION` into them. eider-lang's `version.sh`
  calls them.
- **`CHANGELOG.md`** with a `## <version>` section per release.

### eider-profiler

eider-profiler is built in its own repository and must have: `VERSION` (`0.1.0`);
`eider-profiler --version` printing `eider-profiler 0.1.0`; `eider = "0.1"` in its
eider.toml; `scripts/build.sh` refusing an eider-lang checkout whose `VERSION` has another
MAJOR.MINOR (or none) with a clear message and a nonzero exit; `CHANGELOG.md` with a
`## 0.1.0` section; and preferably `scripts/version.sh check|sync` as above. Until then
check-siblings checks only its `VERSION`.

### eider-doc

eider-doc lives in eider-lang (`packages/doc`) and has the toolchain's version, not one of
its own: `packages/doc/eider.toml` says `version = "<VERSION>"` and `eider = "<MAJOR.MINOR>"`
(`scripts/version.sh check` holds both, and `bump` rewrites them), and `eider-doc
--version` prints `eider-doc <VERSION>` with `VERSION` from `core/version`, as eiderc and
eider-pkg do:

```eider,ignore
import core.sys
import core.version
import std.bytes
import std.io

// in the argument loop, before the commands
if is(a, "--version") {
    let mut l = sys.lit("eider-doc ")
    bytes.append(inout l, sys.lit(version.VERSION))
    io.outln(l)                                // eider-doc 0.1.0
    env.exit(0)
}
```

(`eider,ignore`: a fragment of eider-doc's `main`.)
