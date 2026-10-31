#!/bin/sh
# Cut a release bundle of the Eider toolchain and the tools shipped with it
# (docs/site/tooling/releases.md).
#
#   scripts/release.sh [--skip-verify]
#
# 1. Checks: eider-lang and every sibling (eider-analyzer, tree-sitter-eider, eider-profiler;
#    EIDER_ANALYZER, TREE_SITTER_EIDER, EIDER_PROFILER, default ../<name>) is present and
#    clean (no uncommitted or untracked files); the versions agree (scripts/version.sh check
#    and check-siblings: one MAJOR.MINOR); each CHANGELOG.md has a section for its version;
#    the seed's eiderc and eider-pkg print `<tool> <VERSION>`; scripts/verify.sh ends with
#    ALL GREEN (its tools leg builds and tests the siblings against this checkout) and
#    scripts/selfhost.sh prints SELF-HOSTED. --skip-verify leaves out verify and selfhost, to
#    try the script: the bundle then says `verified = false` and is not a release.
# 2. Writes target/release/eider-<VERSION>/RELEASE.toml: each component's exact version and
#    commit, and the tag it gets.
# 3. Writes target/release/eider-<VERSION>.tar.gz: RELEASE.toml, a README (building all of it
#    with only a C compiler, plus node for regenerating the grammar), and each repository's
#    committed files at that commit (`git archive`; eider-lang without its tests): the seed,
#    core, std, the compiler, scripts, eider-pkg, eider-doc, the packages and the docs, and the
#    siblings' sources. The tarball is reproducible: sorted, owner 0, every mtime the
#    eider-lang commit's time, gzip -n (GNU tar).
# 4. Prints the `git tag` commands for each repository, without running them: tags and their
#    push happen when the user asks to release.
cd "$(dirname "$0")/.." || exit 1
here=$(pwd -P)
skip_verify=
for a in "$@"; do
  case $a in
    --skip-verify) skip_verify=1 ;;
    *) echo "usage: scripts/release.sh [--skip-verify]" >&2; exit 2 ;;
  esac
done
die() { echo "release: $*" >&2; exit 1; }
V=$(tr -d ' \n' < VERSION)
S=${V%.*}

# ---- the components
dir_of() {
  case $1 in
    eider-lang) echo "$here" ;;
    eider-analyzer) d=${EIDER_ANALYZER:-$here/../eider-analyzer} ;;
    tree-sitter-eider) d=${TREE_SITTER_EIDER:-$here/../tree-sitter-eider} ;;
    eider-profiler) d=${EIDER_PROFILER:-$here/../eider-profiler} ;;
  esac
  [ "$1" = eider-lang ] || { [ -d "$d" ] && (cd "$d" && pwd -P); }
}
COMPONENTS="eider-lang eider-analyzer tree-sitter-eider eider-profiler"
for c in $COMPONENTS; do
  d=$(dir_of $c)
  [ -n "$d" ] && [ -f "$d/VERSION" ] || die "$c: no repository with a VERSION (set EIDER_ANALYZER, TREE_SITTER_EIDER, EIDER_PROFILER); the tools are released together"
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
  echo "release: --skip-verify: not running verify.sh and selfhost.sh; this bundle is not a release"
  verified=false
fi

# ---- RELEASE.toml
out=target/release
name=eider-$V
B=$out/$name
rm -rf "$B" "$B.tar.gz"
mkdir -p "$B"
epoch=$(git log -1 --format=%ct HEAD)
{
  echo "# RELEASE.toml: the components of Eider $V, released together (docs/site/tooling/releases.md)."
  echo "# Every component has the toolchain's MAJOR.MINOR; PATCH versions are each component's own."
  echo
  echo "[release]"
  echo "version = \"$V\""
  echo "series = \"$S\""
  echo "date = \"$(git log -1 --format=%cs HEAD)\""
  echo "verified = $verified"
  for c in $COMPONENTS; do
    d=$(dir_of $c); cv=$(tr -d ' \n' < "$d/VERSION")
    echo
    echo "[component.$c]"
    echo "version = \"$cv\""
    echo "commit = \"$(git -C "$d" rev-parse HEAD)\""
    echo "tag = \"v$cv\""
    case $c in
      eider-lang) echo "contains = [\"eiderc\", \"core\", \"std\", \"eider-pkg\", \"eider-doc\", \"docs\"]" ;;
    esac
  done
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
| eider-lang/ | $V | the language: the compiler (eiderc; its C in seed/eiderc.c), core, std, eider-pkg, eider-doc, the packages, scripts, docs |
| eider-analyzer/ | $(tr -d ' \n' < "$B/eider-analyzer/VERSION") | the language server (LSP) |
| tree-sitter-eider/ | $(tr -d ' \n' < "$B/tree-sitter-eider/VERSION") | the tree-sitter grammar (Neovim and others) |
| eider-profiler/ | $(tr -d ' \n' < "$B/eider-profiler/VERSION") | profiles of Eider programs |

## Building

Needs a C11 compiler (\`cc\`, or \`\$CC\`) and a POSIX system with threads; nothing else,
except node for regenerating or testing the grammar. Keep the directories side by side: the
tools find the toolchain at ../eider-lang.

\`\`\`sh
cd eider-lang
scripts/ei --version              # builds target/eiderc from seed/eiderc.c with cc: eiderc $V
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

\`scripts/ei\` builds the compiler from the seed, the compiler's own C output, with only
the C compiler: the bundle needs no earlier Eider. The compiler from its Eider sources:
\`scripts/ei build compiler/main.ei -o target/eiderc-next\`, and \`sh scripts/selfhost.sh\`
rebuilds it from itself until it reproduces itself.

The tests are not in the bundle: develop and verify from the repositories at the tags in
RELEASE.toml (eider-lang's docs/site/tooling/releases.md).
EOF

# ---- the tarball
tar -C "$out" --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cf - "$name" | gzip -n > "$B.tar.gz" || die "tar failed (GNU tar is needed)"
sum=$(sha256sum "$B.tar.gz" 2>/dev/null || shasum -a 256 "$B.tar.gz")
echo "release: $B.tar.gz ($(wc -c < "$B.tar.gz" | tr -d ' ') bytes)"
echo "release: sha256 ${sum%% *}"
echo "release: $B/RELEASE.toml"
cat "$B/RELEASE.toml" | sed -n '/^\[component/,$p' | sed 's/^/  /'
echo
if [ "$verified" = true ]; then
  echo "To tag the release (when the user asks; not done by this script):"
else
  echo "Not verified (--skip-verify): do not tag. A verified run would print:"
fi
for c in $COMPONENTS; do
  d=$(dir_of $c); cv=$(tr -d ' \n' < "$d/VERSION")
  echo "  git -C $d tag -a v$cv $(git -C "$d" rev-parse --short=12 HEAD) -m \"$c $cv (Eider $V)\""
done
echo "and to publish the tags:"
for c in $COMPONENTS; do
  d=$(dir_of $c); cv=$(tr -d ' \n' < "$d/VERSION")
  echo "  git -C $d push origin v$cv"
done
