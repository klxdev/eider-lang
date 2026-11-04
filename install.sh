#!/bin/sh
# install.sh: install `eider`, the Eider command, into ~/.eider/bin (docs/site/tooling/eider.md).
#
#   sh install.sh [--version <version>] [--toolchain] [--modify-path]
#
# Downloads `eider-<version>-linux-<arch>` from the latest release of klxdev/eider-lang (or
# --version's), with SHA256SUMS and SHA256SUMS.minisig, and checks before installing:
#   1. SHA256SUMS.minisig is a minisign signature (legacy `Ed`: Ed25519 over the file) of
#      SHA256SUMS by the release key below, including its global signature over the trusted
#      comment, and the trusted comment names this release (`release:eider <version>`);
#   2. the binary's SHA-256 is the one SHA256SUMS lists.
# The signature is checked with OpenSSL 3 (`openssl pkeyutl -rawin`), else with minisign.
# Anything that doesn't match stops the script, and nothing is installed.
#
#   --version V      a release other than the latest (0.1.0)
#   --toolchain      then run `eider toolchain install` (the latest toolchain, as default)
#   --modify-path    append the PATH line to ~/.profile (and ~/.bashrc, ~/.zshrc when they
#                    exist); without it the script only prints the line
#
# The repository is private: a GitHub token with read access to it is needed, from GH_TOKEN,
# else GITHUB_TOKEN, else `gh auth token`. EIDER_HOME (default ~/.eider) is where eider goes;
# EIDER_RELEASES=file:///<dir> installs from a directory of releases (v<version>/...) instead
# of GitHub, and EIDER_RELEASE_PUBKEY overrides the key (both for testing).
set -eu

# The release key (minisign public key; scripts/release-key.sh writes this line).
EIDER_PUBKEY=RWSZQQH9HZ9DUczdsxRctXcTuoj372VcNm6IrijiVqJ8sj3Dbrb3nzrl

die() { echo "install.sh: $*" >&2; exit 1; }
version=latest
toolchain=
modify_path=
while [ $# -gt 0 ]; do
  case $1 in
    --version) [ $# -ge 2 ] || die "--version needs a version"; version=${2#v}; shift 2 ;;
    --toolchain) toolchain=1; shift ;;
    --modify-path) modify_path=1; shift ;;
    -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (--version V, --toolchain, --modify-path)" ;;
  esac
done

home=${EIDER_HOME:-$HOME/.eider}
releases=${EIDER_RELEASES:-github:klxdev/eider-lang}
api=${EIDER_GITHUB_API:-https://api.github.com}
key=${EIDER_RELEASE_PUBKEY:-$EIDER_PUBKEY}
[ -f "$key" ] && key=$(sed -n 2p "$key")

case $(uname -s):$(uname -m) in
  Linux:x86_64|Linux:amd64) target=linux-x86_64 ;;
  Linux:aarch64|Linux:arm64) target=linux-aarch64 ;;
  Darwin:aarch64|Darwin:arm64) target=darwin-aarch64 ;;
  *) die "there are no Eider releases for $(uname -sm) yet (linux-x86_64, linux-aarch64, darwin-aarch64)" ;;
esac
for t in base64 dd od; do command -v $t >/dev/null || die "needs $t"; done
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "needs sha256sum or shasum"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# ---- the release's files: fetch <asset name> <dest>
case $releases in
  github:*)
    repo=${releases#github:}
    command -v curl >/dev/null || die "needs curl"
    token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
    if [ -z "$token" ] && command -v gh >/dev/null; then token=$(gh auth token 2>/dev/null || true); fi
    [ -n "$token" ] || die "no GitHub token: $repo is private. Set GH_TOKEN (or GITHUB_TOKEN), or log in with \`gh auth login\`"
    # the token goes to curl in a header file only this user can read, not on its command line
    printf 'Authorization: Bearer %s\nX-GitHub-Api-Version: 2022-11-28\nUser-Agent: eider-install.sh\n' "$token" > "$work/headers"
    # https only, unless EIDER_GITHUB_API itself is http (a local test server)
    proto="--proto =https"
    case $api in http:*) proto= ;; esac
    get() { # get <url> <accept> <out>: the HTTP status on stdout
      curl -sS -L $proto --retry 2 -H "@$work/headers" -H "Accept: $2" -o "$3" -w '%{http_code}' "$1"
    }
    if [ "$version" = latest ]; then url=$api/repos/$repo/releases/latest; else url=$api/repos/$repo/releases/tags/v$version; fi
    code=$(get "$url" application/vnd.github+json "$work/release.json") || die "curl failed for $url"
    case $code in
      200) ;;
      401) die "GitHub rejected the token (401): check GH_TOKEN, GITHUB_TOKEN or \`gh auth status\`" ;;
      404) die "no release $version in $repo, or the token cannot see it (404; the repository is private: the token needs read access)" ;;
      *) die "GitHub answered $code for $url" ;;
    esac
    tag=$(tr ',' '\n' < "$work/release.json" | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    # each asset's API URL and name: the "url" of an asset (…/releases/assets/<id>) comes
    # just before its "name"
    tr ',{}' '\n\n\n' < "$work/release.json" |
      awk -F '"' '$2 == "url" { u = ($4 ~ /\/releases\/assets\/[0-9]+$/) ? $4 : "" } $2 == "name" && u != "" { print $4, u; u = "" }' > "$work/assets"
    fetch() {
      u=$(awk -v n="$1" '$1 == n { print $2 }' "$work/assets")
      [ -n "$u" ] || die "release $tag has no $1"
      code=$(get "$u" application/octet-stream "$2") || die "curl failed for $1"
      [ "$code" = 200 ] || die "GitHub answered $code for $1"
    }
    ;;
  file://*|/*)
    dir=${releases#file://}
    if [ "$version" = latest ]; then
      tag=$(ls "$dir" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
      [ -n "$tag" ] || die "no releases in $dir"
      tag=v$tag
    else
      tag=v$version
    fi
    [ -d "$dir/$tag" ] || die "no release $tag in $dir"
    fetch() { [ -f "$dir/$tag/$1" ] || die "release $tag has no $1"; cp "$dir/$tag/$1" "$2"; }
    ;;
  *) die "EIDER_RELEASES: github:<owner>/<repo> or file:///<dir>" ;;
esac
v=${tag#v}
name=eider-$v-$target
echo "install.sh: eider $v for $target from $releases"
fetch SHA256SUMS "$work/SHA256SUMS"
fetch SHA256SUMS.minisig "$work/SHA256SUMS.minisig"

# ---- 1. the signature
b64() { printf '%s' "$1" | base64 -d 2>/dev/null; }
slice() { dd bs=1 skip="$2" count="$3" if="$1" 2>/dev/null; }
hexof() { od -An -tx1 -v "$1" | tr -d ' \n'; }
sig=$work/SHA256SUMS.minisig
[ "$(wc -l < "$sig" | tr -d ' ')" = 4 ] || die "SHA256SUMS.minisig is not minisign's four lines"
b64 "$key" > "$work/key.bin" || die "the release key is not base64"
b64 "$(sed -n 2p "$sig")" > "$work/sig.raw" || die "the signature is not base64"
b64 "$(sed -n 4p "$sig")" > "$work/global.bin" || die "the global signature is not base64"
[ "$(wc -c < "$work/key.bin" | tr -d ' ')" = 42 ] || die "the release key is not a minisign Ed25519 key"
[ "$(wc -c < "$work/sig.raw" | tr -d ' ')" = 74 ] || die "the signature line is not 74 bytes"
[ "$(wc -c < "$work/global.bin" | tr -d ' ')" = 64 ] || die "the global signature is not 64 bytes"
slice "$work/sig.raw" 0 2 > "$work/alg"
[ "$(cat "$work/alg")" = Ed ] || die "the signature's algorithm is not the legacy Ed (Ed25519 over the file)"
slice "$work/key.bin" 2 8 > "$work/kid"; slice "$work/sig.raw" 2 8 > "$work/sid"
[ "$(hexof "$work/kid")" = "$(hexof "$work/sid")" ] || die "SHA256SUMS was signed by another key than the release key"
slice "$work/key.bin" 10 32 > "$work/pk"
slice "$work/sig.raw" 10 64 > "$work/sig.bin"
trusted=$(sed -n 3p "$sig")
case $trusted in "trusted comment: "*) ;; *) die "the signature's third line is not a trusted comment" ;; esac
trusted=${trusted#trusted comment: }
{ cat "$work/sig.bin"; printf '%s' "$trusted"; } > "$work/global.msg"
verified=
if command -v openssl >/dev/null && openssl pkeyutl -help 2>&1 | grep -q -- -rawin; then
  # the raw key in an Ed25519 SubjectPublicKeyInfo (RFC 8410): 302a300506032b6570032100 || key
  { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; cat "$work/pk"; } > "$work/pk.der"
  osslv() { openssl pkeyutl -verify -pubin -keyform DER -inkey "$work/pk.der" -rawin -in "$1" -sigfile "$2" >/dev/null 2>&1; }
  osslv "$work/SHA256SUMS" "$work/sig.bin" || die "refusing: SHA256SUMS.minisig does not verify (SHA256SUMS was changed, or not signed by the release key)"
  osslv "$work/global.msg" "$work/global.bin" || die "refusing: the trusted comment's signature does not verify"
  verified=openssl
elif command -v minisign >/dev/null; then
  minisign -V -q -P "$key" -m "$work/SHA256SUMS" -x "$sig" || die "refusing: minisign rejects SHA256SUMS.minisig"
  verified=minisign
else
  die "cannot check the signature: needs OpenSSL 3 (openssl pkeyutl -rawin) or minisign"
fi
case "	$trusted	" in
  *"	release:eider $v	"*) ;;
  *) die "refusing: the signed SHA256SUMS is not for eider $v (trusted comment: $trusted)" ;;
esac

# ---- 2. the checksum
want=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$work/SHA256SUMS")
[ -n "$want" ] || die "SHA256SUMS does not list $name"
fetch "$name" "$work/eider"
got=$(sha256 "$work/eider")
[ "$got" = "$want" ] || die "refusing $name: its SHA-256 is $got, but the signed SHA256SUMS says $want"

# ---- install
mkdir -p "$home/bin"
cp "$work/eider" "$home/bin/eider.new"
chmod 755 "$home/bin/eider.new"
mv -f "$home/bin/eider.new" "$home/bin/eider"
echo "install.sh: installed $home/bin/eider ($("$home/bin/eider" --version); signature checked with $verified, SHA-256 checked)"
line="export PATH=\"$home/bin:\$PATH\""
if [ -n "$modify_path" ]; then
  for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ "$rc" = "$HOME/.profile" ] || [ -f "$rc" ] || continue
    grep -qF "$line" "$rc" 2>/dev/null || { printf '\n# eider (install.sh)\n%s\n' "$line" >> "$rc"; echo "install.sh: added the PATH line to $rc"; }
  done
else
  echo "install.sh: add eider to your PATH (install.sh --modify-path does it for you):"
  echo "  $line"
fi
# building programs with the LLVM backend needs clang from LLVM 17 or newer: warn only
cc=${EIDER_LLVM_CC:-clang}
major=$("$cc" --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9]*\).*/\1/p' | head -1)
if [ -z "$major" ] || [ "$major" -lt 17 ]; then
  echo "install.sh: warning: building Eider programs needs clang from LLVM 17 or newer ($cc: ${major:+LLVM $major}${major:-not found}); install it (Fedora: dnf install clang; Debian/Ubuntu: apt install clang-17 or newer), or set EIDER_LLVM_CC" >&2
fi
if [ -n "$toolchain" ]; then
  EIDER_HOME=$home "$home/bin/eider" toolchain install
else
  echo "install.sh: then install a toolchain: eider toolchain install"
fi
