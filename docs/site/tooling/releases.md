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
| `eider`, the command ([eider](eider.md)) | eider-lang (`packages/eider`) | `VERSION` | `eider 0.1.0` |
| the language server | eider-analyzer | its `VERSION` | `eider-analyzer 0.1.0 (eider 0.1.0)` |
| the tree-sitter grammar | tree-sitter-eider | its `VERSION` | (no binary) |
| the profiler | eider-profiler | its `VERSION` | `eider-profiler 0.1.0` |

Library packages keep their own `version` in their `eider.toml`, and eider-pkg selects them
by that version. The libraries and frameworks in repositories of their own (eider-toml,
eider-json, eider-markdown, eider-logging, eider-command, eider-http, eider-rpc, eider-openapi, eider-compression, eider-tls) follow the tools' rule
until 1.0: their MAJOR.MINOR is the toolchain's, their PATCH their own, so `scripts/version.sh
check-siblings` and `bump` treat them as siblings. A package you write needs only
`eider = "<MAJOR.MINOR>"`.

## The version in code

The compiler reads no file to know its version: `core/version.ei` is the Eider copy of
`VERSION`, compiled into eiderc, eider-pkg and eider-doc, and into the seed
(`seed/eiderc.wasm`). A version bump is therefore an ordinary source change followed by a seed
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
0.7.2
0.7
```

`version.MAJOR`, `version.MINOR` and `version.PATCH` are the numbers.

## Packages say which toolchain they need

A package's `eider.toml` can name the toolchain MAJOR.MINOR it is written for:

```toml
[package]
name = "warehouse"
version = "1.4.2"   # the package's own version
eider = "0.7"       # the toolchain it needs: MAJOR.MINOR
```

The compiler checks it on every build. A package whose `eider` isn't the running
toolchain's MAJOR.MINOR is error E0811:

```text
error[E0811]: package `newer` needs Eider 9.9 (`eider = "9.9"` in <dir>/lib/newer/eider.toml), but this toolchain is 0.7
  --> e0811_toolchain_series.ei:3:1
  |
3 | import lib.newer.newer
  | ^
  help: build it with an Eider 9.9.x toolchain, or port it to 0.7 and set `eider = "0.7"` in <dir>/lib/newer/eider.toml
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

A bump does the rest of the release prep itself (#205), in eider-lang and in every sibling
found:

- a sibling's own version: each `[package]` `version` that was its old `VERSION` in its
  eider.toml files, whether or not it has a `scripts/version.sh` (eider-profiler has none; the
  cli package of eider-rpc and of eider-openapi follow their repository);
- on a minor or major bump, the dependency pins: every `[deps.*]` table whose `git` is a
  sibling's repository (`eider-json`, `eider-http`, ...) gets that sibling's new `version`, in
  the siblings and the shopping example. A pin is a minimum version (eider-pkg), so a patch
  bump rewrites none;
- the series and version text: `eider = "<series>"` (also inside a quoted string of a test
  script), `this toolchain is <series>`, `port it to <series>`, `eider toolchain install
  <series>`, the `"toolchain"` of the `eiderc doc` goldens, the analyzer's session goldens
  (`serverInfo`), `eider add ... --version` lines for the libraries and the version/series
  output block of this page. Changelogs, `docs/decisions.md`, `docs/compiler.md`, the research
  and design notes and the seed are history and stay as they are.

It fails (exit 1, every place named) where it cannot finish: a sibling with no valid
`VERSION`, one whose own `version` line was not that `VERSION`, or text of the old series that
remains. `check` also fails while `vendor.lock` pins a release of another series. The commands
that need a commit come last, in the order to run them: the seed and the oracle, a commit per
repository, `git tag` and `git push` for the libraries and the shopping example (the
tools' tags are printed by `release.sh`), `scripts/vendor.sh` for eider-toml, eider-json and
eider-markdown at their new commits, and `eider-pkg update` in each directory with an
`eider.lock`, whose pins name the new tags. Prose that names a released version ("built with
the published toolchain 0.7.0") is not rewritten.

## Releasing

A release is published as a GitHub Release of klxdev/eider-lang, tagged `v<version>`. The
repository is private, so a release is visible only to people with access to it, and
downloading one needs a GitHub token ([eider](eider.md#installing-eider)). One command does
it:

```sh
sh scripts/publish.sh 0.1.0 --dry-run    # everything but the tag, the push and GitHub
sh scripts/publish.sh 0.1.0              # and then those
```

`scripts/publish.sh <version>`:

1. **Checks** that `<version>` is `VERSION`, the tree is clean, `CHANGELOG.md` has a
   `## <version>` section, the release key exists (mode 0600) and is the key embedded in
   `eider` and `install.sh`, and the tag doesn't exist yet.
2. **Runs `scripts/release.sh`** (below), which builds every file of the release into
   `target/release/assets/v<version>/` after verify is ALL GREEN.
3. **Signs** `SHA256SUMS` with the release key (`SHA256SUMS.minisig`), checks the signature,
   and installs the release from that directory into a scratch `EIDER_HOME` with the
   release's own `eider`, then builds and runs a program with it.
4. **Publishes** (not with `--dry-run`): tags `v<version>` (annotated) in eider-lang at
   HEAD, pushes the tag, and creates the release with `gh release create v<version>
   --verify-tag`, its notes taken from the CHANGELOG section, with every file of the assets
   directory.

The siblings (eider-analyzer, tree-sitter-eider, eider-profiler) keep their own versions:
`RELEASE.toml` records the commit of each, and `release.sh` prints the commands to tag
them too.

### What scripts/release.sh builds

```sh
scripts/release.sh [--skip-verify] [--targets "linux-x86_64 linux-aarch64"] [--no-binaries]
```

1. **Checks.** eider-lang and the three siblings are present and clean (no uncommitted or
   untracked files; `EIDER_SIBLINGS` or `EIDER_ANALYZER`, `TREE_SITTER_EIDER`,
   `EIDER_PROFILER` find them, default next to the checkout); `scripts/version.sh check`
   and `check-siblings` pass; each `CHANGELOG.md` has a `## <version>` section; the seed's
   `eiderc --version` and `eider-pkg --version` print the version; `scripts/verify.sh`
   ends with ALL GREEN, its tools leg having built and tested the siblings;
   `scripts/selfhost.sh` prints SELF-HOSTED.
2. **The manifest.** `RELEASE.toml` lists each component's exact version, commit and tag,
   the targets and how they were built, and the release key's id:

   ```toml
   [release]
   version = "0.1.0"
   series = "0.1"
   date = "2026-10-31"
   verified = true
   backend = "c"
   clang_tested = ["17.0.6", "20.1.8", "22.1.8", "23.1.5"]
   release_key = "51439F1DFD014199"

   [component.eider-lang]
   version = "0.1.0"
   commit = "<40 hex digits>"
   tag = "v0.1.0"
   contains = ["eiderc", "core", "std", "eider-pkg", "eider-doc", "eider", "docs"]

   [component.eider-analyzer]
   version = "0.1.0"
   commit = "<40 hex digits>"
   tag = "v0.1.0"

   [target.linux-aarch64]
   archive = "eider-0.1.0-linux-aarch64.tar.gz"
   eider = "eider-0.1.0-linux-aarch64"
   built_with = "zig 0.13.0 cc -target aarch64-linux-musl (static)"
   tested = false   # cross-built; untested until an aarch64 machine or CI exists
   ```

3. **The source bundle.** `eider-<version>.tar.gz` holds RELEASE.toml, a README, and each
   repository's committed files at its commit, side by side: `eider-lang/` (the seed, core,
   std, the compiler, scripts, eider-pkg, eider-doc, eider, the packages and the docs; not
   the tests), `eider-analyzer/`, `tree-sitter-eider/` and `eider-profiler/`. The README
   says how to build all of it with only a C compiler, plus node for regenerating the
   grammar.
4. **The toolchains.** For each target, static executables built with `zig cc -target
   <arch>-linux-musl`: `eiderc` from the seed, `eider-pkg`, `eider-doc`, and `eider` (with
   the AWS-LC backend's portable build, for its signature checks). zig is used by this
   release tooling only, because it cross-compiles against musl out of the box (`mise use
   -g zig@0.13`, or `ZIG=<path>`); the language and the toolchain still need only a C
   compiler. `eider-<version>-<target>.tar.gz` holds `eider-<version>-<target>/` with
   `bin/{eiderc,eider-pkg,eider-doc,eider}`, `core/`, `std/`, `VERSION`, `toolchain.toml`
   and a README; `eider-<version>-<target>` is `eider` alone, for `install.sh` and `eider
   self update`. Smoke tests: `file` and `readelf` check that every binary is a static
   executable for the target's machine, and on a machine of the target's architecture
   each `--version` is run and a program is built and run with the unpacked toolchain,
   through `eiderc` and through `eider`. **linux-aarch64 is cross-built and untested**
   beyond `file` and `readelf` until an arm64 machine or CI exists (`tested = false`).
5. **The assets.** `target/release/assets/v<version>/` collects the two toolchain archives,
   the two `eider` binaries, the source bundle, `RELEASE.toml`, `install.sh` and
   `SHA256SUMS` (the SHA-256 of each). It is also a release directory `eider` can install
   from: `EIDER_RELEASES=file://$PWD/target/release/assets eider toolchain install`.

Every archive is reproducible: entries sorted, owner and group 0, modes normalized, every
mtime the eider-lang commit's time, `gzip -n`; the same commits give the same bytes.
`--skip-verify` leaves out the verify and selfhost runs to try the script (RELEASE.toml
then says `verified = false`, and publish.sh accepts it only with `--dry-run`), and
`--no-binaries` stops after the source bundle.

## Keys and verification

Releases are signed with one Ed25519 key in [minisign](https://jedisct1.github.io/minisign/)'s
format. Its public key is in eider-lang as `packages/eider/release.pub`, compiled into
`eider` (`packages/eider/release_key.ei`) and written into `install.sh`:

```text
untrusted comment: minisign public key 51439F1DFD014199
RWSZQQH9HZ9DUczdsxRctXcTuoj372VcNm6IrijiVqJ8sj3Dbrb3nzrl
```

**The secret key** is `~/.config/eider/release.key` (or `$EIDER_RELEASE_KEY`) on the machine
that publishes, mode 0600 in a 0700 directory, and never in a repository. It is
**unencrypted**: minisign's key derivation is set to none (`minisign -G -W` writes the same
format), so publishing needs no passphrase, and the file's permissions are its only
protection. Back it up offline. It was made once with:

```sh
sh scripts/release-key.sh            # generate the keypair, embed the public key
sh scripts/release-key.sh --embed    # embed the existing key's public key again
sh scripts/release-key.sh --print    # print it
```

`release-key.sh` refuses to overwrite a key. A new key means a new `eider` for everyone
(the old one rejects releases signed by another key), so replace it only if it is lost or
exposed, and say so in the CHANGELOG.

**What is signed.** `SHA256SUMS` is signed with the legacy `Ed` algorithm (Ed25519 over
the file itself; eider and install.sh refuse minisign's prehashed `ED`). The trusted
comment is

```text
timestamp:<unix time>	file:SHA256SUMS	release:eider <version>
```

(tab-separated), and the global signature covers it. eider, install.sh and minisign
check the same things: the signature's key id is the release key's, the signature over
`SHA256SUMS` and the global signature over the trusted comment are valid, the trusted
comment names the release being installed, and each download's SHA-256 is the one
`SHA256SUMS` lists. To check a release by hand:

```sh
minisign -Vm SHA256SUMS -P RWSZQQH9HZ9DUczdsxRctXcTuoj372VcNm6IrijiVqJ8sj3Dbrb3nzrl
sha256sum -c SHA256SUMS
```

or with eider-lang's own tool, `target/eider-sign verify packages/eider/release.pub
SHA256SUMS` (built by `scripts/eider --build-only`; `eider-sign keygen | pubkey | sign |
verify | sha256`, packages/eider/signtool.ei).

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
