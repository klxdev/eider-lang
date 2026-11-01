#!/bin/sh
# Cut a release of the Eider toolchain and the tools shipped with it
# (docs/site/tooling/releases.md). scripts/publish.sh runs it, then signs and publishes.
#
#   scripts/release.sh [--skip-verify] [--targets "<target>..."] [--no-binaries]
#
# 1. Checks: eider-lang and every sibling (eider-analyzer, tree-sitter-eider, eider-profiler;
#    EIDER_ANALYZER, TREE_SITTER_EIDER, EIDER_PROFILER, default $EIDER_SIBLINGS/<name> with
#    EIDER_SIBLINGS defaulting to ..) is present and clean (no uncommitted or untracked
#    files); the versions agree (scripts/version.sh check and check-siblings: one
#    MAJOR.MINOR); each CHANGELOG.md has a section for its version; the seed's eiderc and
#    eider-pkg print `<tool> <VERSION>`; scripts/verify.sh ends with ALL GREEN (its tools leg
#    builds and tests the siblings against this checkout) and scripts/selfhost.sh prints
#    SELF-HOSTED. --skip-verify leaves out verify and selfhost, to try the script: the
#    release then says `verified = false` and is not a release.
# 2. Writes target/release/eider-<VERSION>/RELEASE.toml: each component's exact version and
#    commit and the tag it gets, the targets and how they were built, the release key's id.
# 3. Writes target/release/eider-<VERSION>.tar.gz, the source bundle: RELEASE.toml, a README
#    (building all of it with only a C compiler, plus node for regenerating the grammar), and
#    each repository's committed files at that commit (`git archive`; eider-lang without its
#    tests): the seed, core, std, the compiler, scripts, eider-pkg, eider-doc, the packages
#    and the docs, and the siblings' sources.
# 4. For each target (default linux-x86_64 linux-aarch64), builds static binaries with
#    `zig cc -target <arch>-linux-musl` (zig from $ZIG, PATH, or `mise where zig`): eiderc
#    from the seed, eider-pkg, eider-doc, and eider with AWS-LC (its portable build, for the
#    signature checks; sh scripts/fetch-awslc.sh). Only this release tooling uses zig: the
#    language and the toolchain need just a C compiler. The toolchain archive
#    eider-<VERSION>-<target>.tar.gz holds eider-<VERSION>-<target>/: bin/{eiderc, eider-pkg,
#    eider-doc, eider}, core/, std/, VERSION, toolchain.toml and README.md; `eider` alone is
#    eider-<VERSION>-<target>. Smoke tests: `file` and `readelf` (static, the right machine)
#    on every binary; on a machine of the target's architecture also each --version, and a
#    program built and run with the unpacked toolchain, through eiderc and through eider.
#    linux-aarch64 is cross-built, and untested beyond file and readelf until an arm64
#    machine or CI exists (RELEASE.toml says `tested = false`).
# 5. Collects the release's files in target/release/assets/v<VERSION>/, what publish.sh
#    uploads and a release directory `eider` installs from (EIDER_RELEASES=file://<assets>):
#    the archives, the eider binaries, the source bundle, RELEASE.toml, install.sh, and
#    SHA256SUMS over all of them. publish.sh adds SHA256SUMS.minisig.
# Every archive is reproducible: sorted, owner 0, normalized modes, every mtime the
# eider-lang commit's time, gzip -n (GNU tar). --no-binaries stops after step 3.
cd "$(dirname "$0")/.." || exit 1
here=$(pwd -P)
skip_verify=
binaries=1
TARGETS="linux-x86_64 linux-aarch64"
while [ $# -gt 0 ]; do
  case $1 in
    --skip-verify) skip_verify=1; shift ;;
    --no-binaries) binaries=; shift ;;
    --targets) [ $# -ge 2 ] || { echo "release: --targets needs a list" >&2; exit 2; }; TARGETS=$2; shift 2 ;;
    *) echo "usage: scripts/release.sh [--skip-verify] [--targets \"linux-x86_64 linux-aarch64\"] [--no-binaries]" >&2; exit 2 ;;
  esac
done
for t in $TARGETS; do
  case $t in linux-x86_64|linux-aarch64) ;; *) echo "release: unknown target $t (linux-x86_64, linux-aarch64)" >&2; exit 2 ;; esac
done
die() { echo "release: $*" >&2; exit 1; }
V=$(tr -d ' \n' < VERSION)
S=${V%.*}
sibs=${EIDER_SIBLINGS:-$here/..}

# ---- the components
dir_of() {
  case $1 in
    eider-lang) echo "$here" ;;
    eider-analyzer) d=${EIDER_ANALYZER:-$sibs/eider-analyzer} ;;
    tree-sitter-eider) d=${TREE_SITTER_EIDER:-$sibs/tree-sitter-eider} ;;
    eider-profiler) d=${EIDER_PROFILER:-$sibs/eider-profiler} ;;
  esac
  [ "$1" = eider-lang ] || { [ -d "$d" ] && (cd "$d" && pwd -P); }
}
COMPONENTS="eider-lang eider-analyzer tree-sitter-eider eider-profiler"
for c in $COMPONENTS; do
  d=$(dir_of $c)
  [ -n "$d" ] && [ -f "$d/VERSION" ] || die "$c: no repository with a VERSION (set EIDER_SIBLINGS, or EIDER_ANALYZER, TREE_SITTER_EIDER, EIDER_PROFILER); the tools are released together"
  git -C "$d" rev-parse --verify -q HEAD >/dev/null || die "$c: $d is not a git repository with a commit"
  [ -z "$(git -C "$d" status --porcelain)" ] || { git -C "$d" status --short | head -10 >&2; die "$c: $d has uncommitted or untracked files"; }
done
export EIDER_ANALYZER="$(dir_of eider-analyzer)" TREE_SITTER_EIDER="$(dir_of tree-sitter-eider)" EIDER_PROFILER="$(dir_of eider-profiler)"

# ---- versions
sh scripts/version.sh check || die "the versions in this checkout disagree (scripts/version.sh check)"
sh scripts/version.sh check-siblings || die "a sibling's version disagrees (scripts/version.sh check-siblings)"
for c in $COMPONENTS; do
  d=$(dir_of $c); cv=$(tr -d ' \n' < "$d/VERSION")
  grep -q "^## $cv\$" "$d/CHANGELOG.md" 2>/dev/null || die "$c: CHANGELOG.md has no \`## $cv\` section"
done
scripts/ei --help >/dev/null || die "cannot build target/eiderc from the seed"
got=$(target/eiderc --version)
[ "$got" = "eiderc $V" ] || die "the seed's eiderc prints \`$got\`, not \`eiderc $V\`: regenerate the seed (sh scripts/selfhost.sh --seed) and commit it"
got=$(scripts/eider-pkg --version)
[ "$got" = "eider-pkg $V" ] || die "eider-pkg prints \`$got\`, not \`eider-pkg $V\`"
key_id=$(sed -n 's/^pub const KEY_ID: str = "\(.*\)"$/\1/p' packages/eider/release_key.ei)
if [ -n "$binaries" ] && [ "$key_id" = 0000000000000000 ]; then
  die "packages/eider/release_key.ei has no release key yet: sh scripts/release-key.sh, then commit it"
fi

# ---- the build tools for the binaries (checked before the long verify run)
if [ -n "$binaries" ]; then
  if [ -n "${ZIG:-}" ]; then zig=$ZIG
  elif command -v zig >/dev/null 2>&1 && zig version >/dev/null 2>&1; then zig=$(command -v zig)
  elif command -v mise >/dev/null 2>&1 && [ -x "$(mise where zig 2>/dev/null)/zig" ]; then zig=$(mise where zig)/zig
  else die "the release binaries are built with zig (zig cc -target <arch>-linux-musl): install it (mise use -g zig@0.13), or set ZIG, or pass --no-binaries"
  fi
  zig_version=$("$zig" version)
  sh scripts/crypto-build.sh --check awslc-noasm >/dev/null 2>&1 || die "eider needs the AWS-LC sources: sh scripts/fetch-awslc.sh"
  for t in file readelf; do command -v $t >/dev/null || die "the smoke tests need $t"; done
  sh scripts/vendor.sh fetch >/dev/null || die "eider-pkg, eider-doc and eider need the pinned libraries: sh scripts/vendor.sh fetch"
fi

# ---- green
if [ -z "$skip_verify" ]; then
  echo "release: sh scripts/verify.sh (the full matrix, with the siblings)"
  sh scripts/verify.sh > target/release-verify.log 2>&1
  tail -1 target/release-verify.log | grep -q "^ALL GREEN" || { grep "^FAIL" target/release-verify.log >&2; die "verify is not ALL GREEN (target/release-verify.log)"; }
  grep "^skip" target/release-verify.log | sed 's/^/release: verify skipped: /'
  grep -q "^ok   tools" target/release-verify.log || die "verify did not build and test the siblings (its tools leg)"
  echo "release: sh scripts/selfhost.sh"
  sh scripts/selfhost.sh > target/release-selfhost.log 2>&1
  grep -q SELF-HOSTED target/release-selfhost.log || die "selfhost did not print SELF-HOSTED (target/release-selfhost.log)"
  verified=true
else
  echo "release: --skip-verify: not running verify.sh and selfhost.sh; this is not a release"
  verified=false
fi

# ---- RELEASE.toml
out=target/release
name=eider-$V
B=$out/$name
rm -rf "$B" "$B.tar.gz"
mkdir -p "$B"
epoch=$(git log -1 --format=%ct HEAD)
# the backend programs are built with: LLVM, the only one (U23; the driver asks for clang,
# $EIDER_LLVM_CC); eider warns when clang 17+ is missing
backend=llvm
host_arch=$(uname -m); case $host_arch in amd64) host_arch=x86_64 ;; arm64) host_arch=aarch64 ;; esac
{
  echo "# RELEASE.toml: the components of Eider $V, released together (docs/site/tooling/releases.md)."
  echo "# Every component has the toolchain's MAJOR.MINOR; PATCH versions are each component's own."
  echo
  echo "[release]"
  echo "version = \"$V\""
  echo "series = \"$S\""
  echo "date = \"$(git log -1 --format=%cs HEAD)\""
  echo "verified = $verified"
  echo "backend = \"$backend\""
  echo "release_key = \"$key_id\"   # minisign key id of SHA256SUMS.minisig (packages/eider/release.pub)"
  for c in $COMPONENTS; do
    d=$(dir_of $c); cv=$(tr -d ' \n' < "$d/VERSION")
    echo
    echo "[component.$c]"
    echo "version = \"$cv\""
    echo "commit = \"$(git -C "$d" rev-parse HEAD)\""
    echo "tag = \"v$cv\""
    case $c in
      eider-lang) echo "contains = [\"eiderc\", \"core\", \"std\", \"eider-pkg\", \"eider-doc\", \"eider\", \"docs\"]" ;;
    esac
  done
  if [ -n "$binaries" ]; then
    for t in $TARGETS; do
      arch=${t#linux-}
      echo
      echo "[target.$t]"
      echo "archive = \"$name-$t.tar.gz\""
      echo "eider = \"$name-$t\""
      echo "built_with = \"zig $zig_version cc -target $arch-linux-musl (static)\""
      if [ "$arch" = "$host_arch" ]; then
        echo "tested = true    # smoke-tested on $(uname -sm): --version, a program built and run"
      else
        echo "tested = false   # cross-built on $(uname -sm); untested until an $arch machine or CI exists (file and readelf checks only)"
      fi
    done
  fi
} > "$B/RELEASE.toml"

# ---- the sources
for c in $COMPONENTS; do
  d=$(dir_of $c)
  if [ $c = eider-lang ]; then
    # everything but the tests (the bundle builds; development and verify use the repositories)
    git -C "$d" archive --format=tar --prefix="$c/" HEAD -- . ':(exclude)tests' ':(exclude)compiler/tests' ':(exclude).claude' | tar -C "$B" -xf -
  else
    git -C "$d" archive --format=tar --prefix="$c/" HEAD | tar -C "$B" -xf -
  fi
done

# ---- README
doc_line="eider-doc: not in this release (packages/doc is missing)"
if [ -f "$B/eider-lang/packages/doc/eider.toml" ]; then
  dm=$(sed -n 's/^main = "\(.*\)"$/\1/p' "$B/eider-lang/packages/doc/eider.toml" | head -1)
  doc_line="scripts/ei build packages/doc/${dm:-main.ei} -o target/eider-doc   # eider-doc; eider-doc --version"
fi
cat > "$B/README.md" <<EOF
# Eider $V

The Eider toolchain and the tools shipped with it, released together (RELEASE.toml has each
component's version and commit). Every component has the toolchain's MAJOR.MINOR ($S);
PATCH versions are each component's own. Before 1.0 a MINOR may break compatibility:
packages say \`eider = "$S"\` in their eider.toml, and the compiler refuses any other
(E0811).

| Directory | Version | What |
|---|---|---|
| eider-lang/ | $V | the language: the compiler (eiderc; its seed, seed/eiderc.wasm, with the translator seed/wasm2c.c), core, std, eider-pkg, eider-doc, eider, the packages, scripts, docs |
| eider-analyzer/ | $(tr -d ' \n' < "$B/eider-analyzer/VERSION") | the language server (LSP) |
| tree-sitter-eider/ | $(tr -d ' \n' < "$B/tree-sitter-eider/VERSION") | the tree-sitter grammar (Neovim and others) |
| eider-profiler/ | $(tr -d ' \n' < "$B/eider-profiler/VERSION") | profiles of Eider programs |

Prebuilt toolchains (linux-x86_64, linux-aarch64) are the release's
eider-$V-<target>.tar.gz files; \`eider toolchain install $V\` installs one
(eider-lang/docs/site/tooling/eider.md).

## Building

Needs a C11 compiler (\`cc\`, or \`\$CC\`) and a POSIX system with threads to build the
compiler, and clang 17 or newer to build programs with it (the tools are Eider programs);
node for regenerating or testing the grammar. Keep the directories side by side: the
tools find the toolchain at ../eider-lang.

\`\`\`sh
cd eider-lang
scripts/ei --version              # builds target/eiderc from seed/eiderc.wasm (cc, then clang): eiderc $V
scripts/eider-pkg --version       # builds target/eider-pkg (Eider, with that eiderc): eider-pkg $V
$doc_line
scripts/ei run examples/fib.ei    # a program
cd ../eider-analyzer
sh scripts/build.sh               # target/bin/eider-analyzer (checks ../eider-lang is Eider $S.x)
target/bin/eider-analyzer --version
cd ../eider-profiler
sh scripts/build.sh               # eider-profiler (checks ../eider-lang is Eider $S.x)
cd ../tree-sitter-eider
cc -shared -fPIC -O2 -I src -o eider.so src/parser.c src/scanner.c   # the parser: cc only
npm install && npx tree-sitter test                                    # node: regenerate, test
\`\`\`

\`scripts/ei\` builds the compiler from the seed, the compiler as WebAssembly, translated to
C by seed/wasm2c.c and compiled with only the C compiler (then, with clang, natively from
compiler/): the bundle needs no earlier Eider. The compiler from its Eider sources:
\`scripts/ei build compiler/main.ei -o target/eiderc-next\`, and \`sh scripts/selfhost.sh\`
rebuilds it from itself until it reproduces itself.

The tests are not in the bundle: develop and verify from the repositories at the tags in
RELEASE.toml (eider-lang's docs/site/tooling/releases.md).
EOF

# reproducible archives: tarball <dir under $out> <file>
tarball() {
  tar -C "$out" --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner --format=gnu \
    --mode='u+rwX,go+rX,go-w' -cf - "$1" | gzip -n -9 > "$2" || die "tar failed (GNU tar is needed)"
}
tarball "$name" "$B.tar.gz"
sum=$(sha256sum "$B.tar.gz" 2>/dev/null || shasum -a 256 "$B.tar.gz")
echo "release: $B.tar.gz ($(wc -c < "$B.tar.gz" | tr -d ' ') bytes, sha256 ${sum%% *})"

# ---- the binaries
A=$out/assets/v$V
if [ -n "$binaries" ]; then
  rm -rf "$out/assets" "$out/build"
  mkdir -p "$A"
  # the toolchain's own files at the commit: core/ and std/ (what eiderc reads: the runtime's
  # C, the prelude, the modules)
  mkdir -p "$out/build/src"
  git archive --format=tar HEAD -- core std VERSION | tar -C "$out/build/src" -xf -
  hello=$out/build/hello
  mkdir -p "$hello"
  printf 'import core.version\n\nfn main() uses io {\n    print("hello from eider")\n    print(version.VERSION)\n}\n' > "$hello/hello.ei"
  for t in $TARGETS; do
    arch=${t#linux-}
    W=$out/build/$t
    mkdir -p "$W/bin"
    printf '#!/bin/sh\nexec "%s" cc -target %s-linux-musl "$@"\n' "$zig" "$arch" > "$W/cc"
    chmod +x "$W/cc"
    echo "release: $t: eiderc, crypto, eider-pkg, eider-doc, eider with zig cc -target $arch-linux-musl"
    EIDER_CACHE=off target/eiderc emit-c compiler/main.ei >"$W/eiderc.c" 2>"$W/eiderc.log" &&
      "$W/cc" -std=c11 -O2 -pthread -s -I core -o "$W/bin/eiderc" "$W/eiderc.c" core/eider_rt.c core/eider_core.c >>"$W/eiderc.log" 2>&1 ||
      { cat "$W/eiderc.log" >&2; die "$t: eiderc did not build"; }
    CC="$zig cc -target $arch-linux-musl" AR="$zig ar" EIDER_CRYPTO_OUT=$here/$W/crypto sh scripts/crypto-build.sh awslc-noasm >"$W/crypto.log" 2>&1 ||
      { tail -20 "$W/crypto.log" >&2; die "$t: AWS-LC did not build"; }
    for p in pkg:packages/pkg/main.ei doc:packages/doc/main.ei eider:packages/eider/main.ei; do
      bin=${p%%:*}; [ $bin = eider ] || bin=eider-$bin
      # The tools are built from the compiler's portable C (emit-c) with the target's zig cc, as
      # eiderc is from the C seed: the LLVM backend emits IR for the host's C ABI (System V
      # x86-64; AAPCS64 is not done), which must not be cross-compiled to another target.
      EIDER_CACHE=off target/eiderc emit-c "${p#*:}" >"$W/$bin.c" 2>"$W/$bin.log" ||
        { tail -20 "$W/$bin.log" >&2; die "$t: $bin: emit-c failed"; }
      ldl=; [ $bin = eider ] && ldl="-L$here/$W/crypto/awslc-noasm -leider_crypto"
      "$W/cc" -std=c11 -O2 -pthread -s -I core -o "$W/bin/$bin" "$W/$bin.c" core/eider_rt.c core/eider_core.c $ldl >>"$W/$bin.log" 2>&1 ||
        { tail -20 "$W/$bin.log" >&2; die "$t: $bin did not build"; }
    done
    # smoke tests every target gets: static ELF executables for the right machine
    case $arch in x86_64) machine="Advanced Micro Devices X86-64"; filearch=x86-64 ;; aarch64) machine=AArch64; filearch="ARM aarch64" ;; esac
    for b in eiderc eider-pkg eider-doc eider; do
      f=$W/bin/$b
      file "$f" | grep -q "ELF 64-bit LSB executable, $filearch" || die "$t: $b: not an $arch executable: $(file "$f")"
      file "$f" | grep -q "statically linked" || die "$t: $b is not statically linked: $(file "$f")"
      readelf -h "$f" | grep -q "Machine: *$machine" || die "$t: $b: readelf says $(readelf -h "$f" | grep Machine)"
      readelf -l "$f" | grep -q INTERP && die "$t: $b asks for a dynamic loader (an INTERP header)"
    done
    echo "release: $t: file, readelf: 4 static $arch executables"
    # the toolchain directory
    T=$out/$name-$t
    rm -rf "$T"
    mkdir -p "$T/bin"
    cp "$W/bin/eiderc" "$W/bin/eider-pkg" "$W/bin/eider-doc" "$W/bin/eider" "$T/bin/"
    cp -R "$out/build/src/core" "$out/build/src/std" "$out/build/src/VERSION" "$T/"
    tested=$(sed -n "/^\[target.$t\]/,/^\[/s/^tested = \([a-z]*\).*/\1/p" "$B/RELEASE.toml")
    {
      echo "# toolchain.toml: an Eider toolchain, installed by \`eider toolchain install\` (docs/site/tooling/eider.md)."
      echo "[toolchain]"
      echo "version = \"$V\""
      echo "target = \"$t\""
      echo "commit = \"$(git rev-parse HEAD)\""
      echo "# llvm: building programs needs clang from LLVM 17+ (\$EIDER_LLVM_CC, default clang)"
      echo "backend = \"$backend\""
      echo "built_with = \"zig $zig_version cc -target $arch-linux-musl (static)\""
      echo "tested = $tested"
      echo
      echo "# bin/eiderc (the compiler; it builds programs with clang 17+, \$EIDER_LLVM_CC, and \$CC), bin/eider-pkg,"
      echo "# bin/eider-doc, bin/eider; core/ and std/ (eiderc finds them above its own directory)"
    } > "$T/toolchain.toml"
    cat > "$T/README.md" <<EOF
# Eider $V for $t

The Eider toolchain: \`bin/eiderc\` (the compiler), \`bin/eider-pkg\` (packages),
\`bin/eider-doc\` (documentation), \`bin/eider\` (the command that selects a toolchain and
runs these), with \`core/\` and \`std/\`. Static executables; building a program needs a C
compiler (\`cc\`, or \`\$CC\`). Usually installed and run through \`eider\`:

    eider toolchain install $V
    eider run hello.ei

See RELEASE.toml in the release and docs/site/tooling/eider.md in eider-lang.
EOF
    tarball "$name-$t" "$A/$name-$t.tar.gz"
    cp "$W/bin/eider" "$A/$name-$t"
    # smoke tests on a machine of this architecture: run the unpacked toolchain
    if [ "$arch" = "$host_arch" ]; then
      U=$out/build/unpack-$t
      rm -rf "$U"; mkdir -p "$U"
      tar -C "$U" -xzf "$A/$name-$t.tar.gz"
      UT=$U/$name-$t
      for b in eiderc eider-pkg eider-doc eider; do
        got=$(env -u EIDER_ROOT "$UT/bin/$b" --version 2>&1)
        [ "$got" = "$b $V" ] || die "$t: $b --version printed \`$got\`, not \`$b $V\`"
      done
      got=$(cd "$hello" && env -u EIDER_ROOT -u EIDER_TOOLCHAIN EIDER_CACHE=off "$here/$UT/bin/eiderc" run hello.ei 2>&1)
      [ "$got" = "$(printf 'hello from eider\n%s' "$V")" ] || die "$t: the unpacked eiderc did not build and run a program: $got"
      got=$(cd "$hello" && env -u EIDER_ROOT EIDER_TOOLCHAIN="$here/$UT" EIDER_HOME="$here/$U/home" EIDER_CACHE=off "$here/$UT/bin/eider" run hello.ei 2>&1)
      [ "$got" = "$(printf 'hello from eider\n%s' "$V")" ] || die "$t: the unpacked eider did not run a program: $got"
      echo "release: $t: --version of each, and a program built and run through eiderc and through eider"
    else
      echo "release: $t: cross-built, not run (no $arch machine here): untested beyond file and readelf"
    fi
  done
  cp "$B.tar.gz" "$B/RELEASE.toml" "$A/"
  cp install.sh "$A/install.sh"
  (cd "$A" && for f in $(ls | sort); do case $f in SHA256SUMS*) ;; *) sha256sum "$f" ;; esac; done) > "$out/SHA256SUMS" && mv "$out/SHA256SUMS" "$A/SHA256SUMS"
  echo "release: $A:"
  (cd "$A" && ls -l | sed -n '2,$p' | awk '{ printf "  %10s  %s\n", $5, $9 }')
fi

echo "release: $B/RELEASE.toml"
sed -n '/^\[component/,$p' "$B/RELEASE.toml" | sed 's/^/  /'
echo
if [ "$verified" != true ]; then
  echo "Not verified (--skip-verify): this is not a release; do not sign, tag or publish it."
else
  echo "Verified. scripts/publish.sh $V signs SHA256SUMS, tags v$V in eider-lang, pushes the tag"
  echo "and creates the GitHub release (--dry-run: everything but the tag, the push and GitHub)."
  echo "The siblings keep their own versions (RELEASE.toml records their commits); to tag them too:"
  for c in $COMPONENTS; do
    [ $c = eider-lang ] && continue
    d=$(dir_of $c); cv=$(tr -d ' \n' < "$d/VERSION")
    echo "  git -C $d tag -a v$cv $(git -C "$d" rev-parse --short=12 HEAD) -m \"$c $cv (Eider $V)\" && git -C $d push origin v$cv"
  done
fi
