# The Eider command: eider

`eider` is the one command you run: it installs Eider toolchains from the published
releases, picks the right one for the directory you are in, and runs that toolchain's
compiler (`eiderc`), package manager (`eider-pkg`) and documentation tool (`eider-doc`).
It is written in Eider (`packages/eider` in eider-lang).

```sh
eider toolchain install          # the latest release, which becomes the default
eider run hello.ei               # eiderc run, with the selected toolchain
eider new warehouse              # a new package (eider-pkg init)
eider +0.1.0 test lib.ei         # one command with another installed version
```

## Installing eider

The releases are on the private repository klxdev/eider-lang, so downloading them needs a
GitHub token with read access to it: `GH_TOKEN`, else `GITHUB_TOKEN`, else the one
`gh auth token` prints (after `gh auth login`). With one of those in place, download
`install.sh` from the latest release (or take it from an eider-lang checkout) and run it:

```sh
gh release download --repo klxdev/eider-lang --pattern install.sh
sh install.sh                    # eider into ~/.eider/bin
sh install.sh --toolchain        # ... and then `eider toolchain install`
sh install.sh --modify-path      # ... and add ~/.eider/bin to PATH in ~/.profile (and
                                 #     ~/.bashrc, ~/.zshrc when they exist)
```

`install.sh` downloads `eider-<version>-linux-<arch>` with `SHA256SUMS` and
`SHA256SUMS.minisig`, checks the signature with the release key it carries (with OpenSSL 3,
else minisign) and the checksum, and only then installs. Without `--modify-path` it prints
the line to add to your shell's profile:

```sh
export PATH="$HOME/.eider/bin:$PATH"
```

Releases exist for linux-x86_64 and linux-aarch64 (the aarch64 build is cross-compiled
and, until an arm64 machine or CI exists, untested beyond static checks). Elsewhere, build
from source: [Getting started](../guide/getting-started.md).

## Commands

| Command | Does |
|---|---|
| `eider toolchain install [<version> \| <MAJOR.MINOR> \| latest] [--force] [--json]` | download, check and install a release (default `latest`); a series installs its newest patch; the first toolchain installed becomes the default |
| `eider toolchain list [--json]` | the installed toolchains (and the default), and the releases available |
| `eider toolchain use <version>` | make an installed toolchain the default |
| `eider toolchain remove <version>` | remove an installed toolchain (if it was the default, there is none after) |
| `eider toolchain show [--json]` | the toolchain a command here would use, and why |
| `eider self update [--force] [--json]` | replace `~/.eider/bin/eider` with the latest release's, checked like a toolchain |
| `eider version [--json]`, `eider --version` | eider's version (and the selected toolchain's) |
| `eider build\|run\|test\|check\|emit-c\|emit-header\|caps\|ir\|... <args>` | the toolchain's `eiderc` with these arguments ([eiderc](compiler.md)) |
| `eider doc <args>` | the toolchain's `eider-doc` ([eider-doc](eider-doc.md)) |
| `eider new <name>` | a new package in `<name>/` (`eider-pkg -C <name> init <name>`) |
| `eider init\|add\|remove\|fetch\|update\|vendor\|tree <args>` | the toolchain's `eider-pkg` ([eider-pkg](eider-pkg.md)) |
| `eider eiderc\|eider-pkg\|eider-doc <args>` | that program, with any arguments (`eider eiderc doc --json lib.ei`) |
| `eider help` | the commands |

Any other command goes to eiderc, so `eider lex`, `eider ide` and the rest work too. The
programs run with `EIDER_ROOT` set to the toolchain and `EIDERC` to its compiler, and
`eider` exits with their status. eider's own failures are exit 1, usage errors exit 2, and
with `--json` a failure is one line `{"error":"..."}` on stdout.

## Which toolchain

The first of these that applies:

1. **`eider +<version> <command>`**: that version (`+0.1.0`), or the newest installed patch
   of a series (`+0.1`).
2. **`EIDER_TOOLCHAIN=<path>`**: a toolchain directory, or an eider-lang checkout (one with
   `scripts/ei` and `seed/eiderc.c`, whose compiler `scripts/ei` builds from the seed when
   needed). This is how eider-lang itself is developed: point it at your checkout.
3. **The project's `eider.toml`**: the nearest one at or above the working directory, if
   it says `eider = "MAJOR.MINOR"` under `[package]` ([Versions and
   releases](releases.md)): the newest installed patch of that series.
4. **The default**: `eider toolchain use <version>`, kept in `~/.eider/config.toml`.

When the version asked for isn't installed, eider stops and names the command that
installs it:

```text
eider: /home/me/warehouse/eider.toml (eider = "0.2") asks for Eider 0.2, which is not installed. Run `eider toolchain install 0.2` (or set EIDER_AUTO_INSTALL=1, or `auto_install = true` in config.toml, to install it when needed)
```

With `EIDER_AUTO_INSTALL=1` (or `auto_install = true` in config.toml) it installs the
toolchain instead, with the same checks, and carries on. `eider toolchain show` says what
was chosen and why:

```text
0.1.0 (/home/me/.eider/toolchains/0.1.0)
  chosen by /home/me/warehouse/eider.toml (eider = "0.1")
```

## Where things go

```text
~/.eider/                     EIDER_HOME
  bin/eider                   this command (install.sh, eider self update)
  toolchains/<version>/       an installed toolchain:
    bin/eiderc  bin/eider-pkg  bin/eider-doc  bin/eider
    core/  std/  VERSION  toolchain.toml  README.md
  downloads/                  a release's files while they are checked (removed after)
  config.toml                 default = "0.1.0", auto_install = false, releases = "..."
  git/  pkg/  index/  tmp/    eider-pkg's package store (eider-pkg.md)
```

A toolchain's binaries are static executables; the compiler builds programs with your C
compiler (`cc`, or `$CC`), as it always does. `toolchain.toml` records the version, the
target, the commit and how it was built.

## Verification

Before anything is unpacked or installed, eider checks, and refuses on any mismatch:

1. `SHA256SUMS.minisig` is a valid [minisign](https://jedisct1.github.io/minisign/)
   signature of `SHA256SUMS` by the Eider release key, which is embedded in eider: the
   legacy `Ed` algorithm (Ed25519 over the file), made by that key's id, with a valid
   global signature over the trusted comment; and the trusted comment names the release
   being installed (`release:eider 0.1.0`), so one release's signed checksums can't be
   passed off as another's.
2. The download's SHA-256 is the one `SHA256SUMS` lists for its name.
3. A toolchain archive holds only regular files and directories, all under
   `eider-<version>-<target>/` (no absolute paths, no `..`, no links), and its
   `toolchain.toml` names the version and target asked for.

The signatures are checked with Ed25519 and SHA-256 from the [crypto](api:crypto)
package (AWS-LC). The release key, its id and how releases are signed are in [Versions
and releases](releases.md#keys-and-verification).

```text
eider: refusing eider-0.1.0-linux-x86_64.tar.gz: its SHA-256 is 3f1c..., but the signed SHA256SUMS says 9a2e... (a damaged or altered download)
```

## Downloads

eider talks to the GitHub API through `curl`. The token reaches curl in a header file
inside a directory only you can read, never on a command line, and curl drops it when
GitHub redirects the download to its storage host. `curl`, `tar`, `uname`, `chmod` and
`env` are the programs eider runs; it needs no other library at run time.

| Variable | Default | |
|---|---|---|
| `EIDER_HOME` | `~/.eider` | everything above |
| `EIDER_TOOLCHAIN` | | a toolchain directory or eider-lang checkout to use |
| `EIDER_AUTO_INSTALL` | | `1`: install a missing toolchain when a command needs it |
| `GH_TOKEN`, `GITHUB_TOKEN` | `gh auth token` | the GitHub token |
| `EIDER_RELEASES` | `github:klxdev/eider-lang` | where releases come from: `github:<owner>/<repo>`, or `file://<dir>`, a directory with one `v<version>/` per release holding its files (offline machines, tests: `scripts/publish.sh --dry-run` leaves one in `target/release/assets`) |
| `EIDER_GITHUB_API` | `https://api.github.com` | the API's address |
| `EIDER_RELEASE_PUBKEY` | the embedded key | another minisign public key (a `.pub` file or its key line), for testing |
| `EIDER_TARGET` | from `uname -sm` | `linux-x86_64` or `linux-aarch64` |

## Developing eider

In an eider-lang checkout, `scripts/eider <args>` builds `target/eider` (with the seed's
eiderc, the pinned eider-json and eider-toml, and the AWS-LC backend: `sh
scripts/fetch-awslc.sh`) and runs it. `sh tests/eider/run.sh` tests it end to end against
fake signed releases, a fake GitHub API and tampered downloads (verify.sh's eider leg), and
`packages/eider/tests/` has the format and version tests (the packages leg).
