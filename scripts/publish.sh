#!/bin/sh
# Publish a release of Eider on GitHub (docs/site/tooling/releases.md, "Publishing").
#
#   sh scripts/publish.sh <version> [--dry-run] [--skip-verify]
#
# 1. Checks: <version> is VERSION; the eider-lang tree is clean (no uncommitted or untracked
#    files); CHANGELOG.md has a `## <version>` section; the release key exists
#    ($EIDER_RELEASE_KEY, default ~/.config/eider/release.key, mode 0600) and is the key
#    embedded in eider (packages/eider/release_key.ei) and install.sh; the tag v<version>
#    doesn't exist yet (or is at HEAD, from an interrupted run).
# 2. Runs scripts/release.sh, which checks the versions, the siblings and the CHANGELOGs,
#    runs scripts/verify.sh (it must be ALL GREEN) and selfhost, and builds the release's
#    files in target/release/assets/v<version>/.
# 3. Signs SHA256SUMS: SHA256SUMS.minisig, a minisign signature (legacy `Ed`) whose trusted
#    comment is `timestamp:<unix time>	file:SHA256SUMS	release:eider <version>`; checks it
#    with eider-sign, then installs the release from the assets directory into a scratch
#    EIDER_HOME with the release's own eider (EIDER_RELEASES=file://...) and runs a program.
# 4. Unless --dry-run: tags v<version> (annotated) in eider-lang at HEAD, pushes the tag to
#    origin, and creates the GitHub release on klxdev/eider-lang (`gh release create
#    v<version> --verify-tag`, notes from CHANGELOG.md's section) with every file of the
#    assets directory. The repository is private, so the release is visible only to those
#    with access to it. The siblings (eider-analyzer, tree-sitter-eider, eider-profiler) keep
#    their own versions: RELEASE.toml records their commits, and release.sh prints the
#    commands to tag them.
# --dry-run does everything but step 4, and prints what step 4 would run.
# --skip-verify (only with --dry-run) passes --skip-verify to release.sh: a quick try.
cd "$(dirname "$0")/.." || exit 1
die() { echo "publish: $*" >&2; exit 1; }
want=
dry=
skip=
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    --skip-verify) skip=--skip-verify ;;
    -*) die "unknown option $a (--dry-run, --skip-verify)" ;;
    *) [ -z "$want" ] || die "one version only"; want=${a#v} ;;
  esac
done
[ -n "$want" ] || { echo "usage: sh scripts/publish.sh <version> [--dry-run] [--skip-verify]" >&2; exit 2; }
[ -n "$skip" ] && [ -z "$dry" ] && die "--skip-verify is only for --dry-run: a published release is verified"
REPO=${EIDER_PUBLISH_REPO:-klxdev/eider-lang}
V=$(tr -d ' \n' < VERSION)
[ "$want" = "$V" ] || die "VERSION is $V, not $want (scripts/version.sh bump, then commit)"
[ -z "$(git status --porcelain)" ] || { git status --short | head -10 >&2; die "the tree is not clean: commit or remove these first"; }
grep -q "^## $V\$" CHANGELOG.md || die "CHANGELOG.md has no \`## $V\` section"
key=${EIDER_RELEASE_KEY:-${XDG_CONFIG_HOME:-$HOME/.config}/eider/release.key}
[ -f "$key" ] || die "no release key at $key (sh scripts/release-key.sh makes one; EIDER_RELEASE_KEY names another)"
perm=$(stat -c %a "$key" 2>/dev/null || stat -f %Lp "$key")
[ "$perm" = 600 ] || die "$key has mode $perm; it must be 600"
head=$(git rev-parse HEAD)
if git rev-parse -q --verify "refs/tags/v$V" >/dev/null; then
  [ "$(git rev-parse "v$V^{commit}")" = "$head" ] || die "the tag v$V exists at another commit"
fi

# ---- 2. the release's files (release.sh: versions, siblings, verify, selfhost, binaries)
sh scripts/eider --build-only || die "cannot build target/eider-sign"
"target/eider-sign" pubkey "$key" > target/publish-key.pub || die "cannot read the release key $key"
line=$(sed -n 2p target/publish-key.pub)
id=$(sed -n '1s/.*minisign public key //p' target/publish-key.pub)
grep -q "PUBLIC_KEY: str = \"$line\"" packages/eider/release_key.ei || die "$key is not the key embedded in packages/eider/release_key.ei (sh scripts/release-key.sh --embed, then commit)"
grep -q "^EIDER_PUBKEY=$line\$" install.sh || die "$key is not the key in install.sh (sh scripts/release-key.sh --embed, then commit)"
echo "publish: release key $id ($key)"
sh scripts/release.sh $skip || die "scripts/release.sh failed"
A=target/release/assets/v$V
[ -f "$A/SHA256SUMS" ] || die "release.sh wrote no $A/SHA256SUMS"
grep -q "^verified = true" target/release/eider-$V/RELEASE.toml || [ -n "$skip" ] || die "RELEASE.toml does not say verified = true"

# ---- 3. sign, check the signature, install the release and run a program with it
tab=$(printf '\t')
trusted="timestamp:$(date +%s)${tab}file:SHA256SUMS${tab}release:eider $V"
target/eider-sign sign "$key" "$A/SHA256SUMS" "$trusted" "signature from the Eider release key $id" || die "signing failed"
target/eider-sign verify packages/eider/release.pub "$A/SHA256SUMS" >/dev/null || die "the signature does not verify with packages/eider/release.pub"
echo "publish: signed $A/SHA256SUMS (SHA256SUMS.minisig, key $id)"
arch=$(uname -m); case $arch in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; esac
eider=$(pwd -P)/$A/eider-$V-linux-$arch
if [ -x "$eider" ]; then
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT
  printf 'fn main() uses io {\n    print("published")\n}\n' > "$T/p.ei"
  EIDER_HOME=$T/home EIDER_RELEASES=file://$(pwd)/target/release/assets "$eider" toolchain install "$V" || die "the release's eider could not install the release"
  got=$(cd "$T" && env -u EIDER_TOOLCHAIN -u EIDER_ROOT EIDER_HOME=$T/home EIDER_CACHE=off "$eider" run p.ei 2>&1) || true
  [ "$got" = published ] || die "the installed release did not run a program: $got"
  echo "publish: installed $V from $A with its own eider, and ran a program with it"
else
  echo "publish: no eider for linux-$arch in the release: the install check is skipped"
fi

# ---- 4. the tag, the push, the GitHub release
notes=target/release/notes-$V.md
awk -v v="## $V" '$0 == v { on = 1; next } on && /^## / { exit } on' CHANGELOG.md > "$notes"
{ echo; echo "Install: \`sh install.sh\` (needs a GitHub token with access to $REPO), then \`eider toolchain install $V\`. SHA256SUMS is signed with the Eider release key $id (minisign; packages/eider/release.pub)."; } >> "$notes"
files=$(cd "$A" && ls | sort | sed "s|^|$A/|" | tr '\n' ' ')
if [ -n "$dry" ]; then
  echo "publish: --dry-run: not tagging, pushing or creating the release. It would run:"
  echo "  git tag -a v$V $head -m \"Eider $V\""
  echo "  git push origin v$V"
  echo "  gh release create v$V --repo $REPO --verify-tag --title \"Eider $V\" --notes-file $notes \\"
  echo "    $files"
  echo "publish: dry run done: $A"
  exit 0
fi
command -v gh >/dev/null || die "needs gh (the GitHub CLI), logged in with access to $REPO"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
gh release view "v$V" --repo "$REPO" >/dev/null 2>&1 && die "the release v$V exists on $REPO already"
git rev-parse -q --verify "refs/tags/v$V" >/dev/null || git tag -a "v$V" "$head" -m "Eider $V" || die "git tag failed"
git push origin "v$V" || die "git push origin v$V failed"
# shellcheck disable=SC2086
gh release create "v$V" --repo "$REPO" --verify-tag --title "Eider $V" --notes-file "$notes" $files || die "gh release create failed (the tag v$V is pushed; rerun after fixing)"
echo "publish: released v$V on $REPO ($(echo $files | wc -w | tr -d ' ') files)"
