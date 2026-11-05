#!/bin/sh
# `eider` end to end (packages/eider, docs/site/tooling/eider.md), against fake releases in a
# scratch directory: no network, no real toolchain. A test key signs them (eider-sign, with
# EIDER_RELEASE_PUBKEY pointing eider at it); each fake toolchain's eiderc, eider-pkg and
# eider-doc are shell scripts that print their arguments, so selection and dispatch can be
# read off their output.
#
#   sh tests/eider/run.sh
#
# Covers: installing from a release directory (EIDER_RELEASES=file://) and through a fake
# GitHub API (tests/eider/fake_github.py: the token, the redirect to storage that the token
# must not follow; needs python3, else skipped); list, use, remove, show, version, self
# update; the selection order (+version, EIDER_TOOLCHAIN, eider.toml's `eider`, the default),
# a missing toolchain's message and auto-install; dispatch to eiderc, eider-pkg (new, add,
# ...) and eider-doc; and refusing tampered releases (a changed archive, changed SHA256SUMS,
# another key, another release's signature, a changed trusted comment, an archive with an
# entry outside its directory or a link, a wrong toolchain.toml). `ok`/`FAIL`/`skip` lines,
# exit 1 on any failure. Needs what scripts/eider needs (a crypto backend: skip without it).
cd "$(dirname "$0")/../.." || exit 1
root=$(pwd)
ver=$(head -1 "$root/VERSION")   # eider reports the toolchain version it was built from
if ! why=$(sh scripts/crypto-build.sh --check 2>&1); then echo "skip eider: needs a crypto backend (${why#crypto-build: }; sh scripts/fetch-awslc.sh)"; exit 0; fi
sh scripts/eider --build-only >/dev/null 2>&1 || { echo "FAIL eider: scripts/eider --build-only"; sh scripts/eider --build-only 2>&1 | tail -10; exit 1; }
E=$root/target/eider
SIGN=$root/target/eider-sign
T=$(mktemp -d)
trap 'kill $srv 2>/dev/null; rm -rf "$T"' EXIT
srv=
fail=0
n=0
ok() { n=$((n + 1)); }
bad() { echo "FAIL eider: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -8 | sed 's/^/  /'; fail=1; }
# check <name> <expected substring> <output>
check() { case $3 in *"$2"*) ok ;; *) bad "$1: expected \`$2\`" "$3" ;; esac; }

case $(uname -s):$(uname -m) in
  Linux:x86_64|Linux:amd64) TGT=linux-x86_64 ;;
  Linux:aarch64|Linux:arm64) TGT=linux-aarch64 ;;
  Darwin:arm64|Darwin:aarch64) TGT=darwin-aarch64 ;;
  *) echo "skip eider: unsupported host $(uname -sm)"; exit 0 ;;
esac
# Leave EIDER_TARGET unset: test native detection in eider and install.sh together.
unset EIDER_TARGET
"$SIGN" keygen "$T/test.key" "$T/test.pub" >/dev/null || { echo "FAIL eider: keygen"; exit 1; }
"$SIGN" keygen "$T/other.key" "$T/other.pub" >/dev/null
REL=$T/releases
mkdir -p "$REL" "$T/bin"
tab=$(printf '\t')

# mkrel <version> [<key>] [<release named in the signature>]: a release with a fake toolchain
mkrel() {
  v=$1; key=${2:-$T/test.key}; says=${3:-$1}
  d=$REL/v$v; s=$T/stage-$v/eider-$v-$TGT
  mkdir -p "$d" "$s/bin" "$s/core" "$s/std"
  for p in eiderc eider-pkg eider-doc; do
    printf '#!/bin/sh\necho "%s %s root=$EIDER_ROOT eiderc=$EIDERC args: $*"\n' "$p" "$v" > "$s/bin/$p"
    chmod 755 "$s/bin/$p"
  done
  printf '#!/bin/sh\necho "fake eider %s"\n' "$v" > "$s/bin/eider"; chmod 755 "$s/bin/eider"
  echo "$v" > "$s/VERSION"
  printf '[toolchain]\nversion = "%s"\ntarget = "%s"\nbackend = "llvm"\n' "$v" "$TGT" > "$s/toolchain.toml"
  tar -C "$T/stage-$v" -czf "$d/eider-$v-$TGT.tar.gz" "eider-$v-$TGT"
  cp "$s/bin/eider" "$d/eider-$v-$TGT"
  sums "$v"
  sign "$v" "$key" "$says"
}
sums() { (cd "$REL/v$1" && sha256sum $(ls | grep -v '^SHA256SUMS')) > "$REL/v$1/SHA256SUMS"; }
sign() { "$SIGN" sign "$2" "$REL/v$1/SHA256SUMS" "timestamp:1${tab}file:SHA256SUMS${tab}release:eider ${3:-$1}" >/dev/null; }

mkrel 1.2.0
mkrel 1.2.3
mkrel 1.3.0

H=$T/home
P=$T/proj
mkdir -p "$P/sub"
# the environment of every run: a scratch EIDER_HOME, the releases, the test key; none of
# the caller's toolchain settings
e() { (cd "${CWD:-$T}" && env -u EIDER_TOOLCHAIN -u EIDER_AUTO_INSTALL -u EIDER_ROOT EIDER_HOME="$H" EIDER_RELEASES="file://$REL" EIDER_RELEASE_PUBKEY="$T/test.pub" "$E" "$@" 2>&1); }

# ---- version, help
out=$(e --version); check "--version" "eider $ver" "$out"
out=$(e help); check "help" "eider toolchain install" "$out"
out=$(e version); check "version without a toolchain" "toolchain: none (no toolchain is installed" "$out"
out=$(e build x.ei); rc=$?
check "a command without a toolchain" "run \`eider toolchain install\`" "$out"; [ $rc = 1 ] && ok || bad "exit status without a toolchain: $rc"

# ---- install, list
out=$(e toolchain list --json); check "list --json, nothing installed" '{"installed":[],"available":["1.3.0","1.2.3","1.2.0"]}' "$out"
out=$(e toolchain install 1.2.0); check "install 1.2.0" "installed eider 1.2.0 in $H/toolchains/1.2.0 (checksum and signature verified)" "$out"
check "the first install is the default" "1.2.0 is the default toolchain" "$out"
[ -x "$H/toolchains/1.2.0/bin/eiderc" ] && ok || bad "1.2.0 is not unpacked into toolchains/1.2.0"
[ -z "$(ls "$H/downloads/" 2>/dev/null | grep -v '^\.')" ] && ok || bad "the download was not removed: $(ls "$H/downloads")"
out=$(e toolchain install 1.2.0); check "install twice" "eider 1.2.0 is already installed" "$out"
out=$(e toolchain install 1.2 --json); check "install a series: its newest patch" '"version":"1.2.3"' "$out"
check "install --json" '"already_installed":false,"default":false' "$out"
out=$(e toolchain install 9.9); rc=$?
check "install a version no release has" "no release matches 9.9 in the release directory $REL (there are: 1.2.0, 1.2.3, 1.3.0)" "$out"; [ $rc = 1 ] && ok || bad "exit status of a failed install: $rc"
out=$(e toolchain list); check "list" "$(printf 'installed:\n  1.2.3\n  1.2.0 (default)\navailable (the release directory %s):\n  1.3.0\n  1.2.3 (installed)\n  1.2.0 (installed)' "$REL")" "$out"
out=$(EIDER_LLVM_CC=$T/no-clang e toolchain install 1.2.0 --force); check "no clang: install works, with a warning" "eider: warning: building programs with this toolchain needs clang from LLVM 17 or newer ($T/no-clang was not found)" "$out"
check "no clang: still installed" "installed eider 1.2.0" "$out"
printf '#!/bin/sh\necho "clang version 15.0.7"\n' > "$T/bin/clang15"; chmod 755 "$T/bin/clang15"
out=$(EIDER_LLVM_CC=$T/bin/clang15 e version); check "clang too old" "is LLVM 15)" "$out"
grep -q '^default = "1.2.0"$' "$H/config.toml" && ok || bad "config.toml has no default" "$(cat "$H/config.toml")"

# ---- selection and dispatch
out=$(e build x.ei -o y); check "the default" "eiderc 1.2.0 root=$H/toolchains/1.2.0 eiderc=$H/toolchains/1.2.0/bin/eiderc args: build x.ei -o y" "$out"
out=$(e +1.2.3 run a.ei -- 1); check "+1.2.3" "eiderc 1.2.3 root=$H/toolchains/1.2.3" "$out"; check "+1.2.3 args" "args: run a.ei -- 1" "$out"
out=$(e +1.2 check a.ei); check "+1.2: the newest installed patch" "eiderc 1.2.3 " "$out"
out=$(e +1.3.0 check a.ei); rc=$?
check "+ a version not installed" "+1.3.0 asks for Eider 1.3.0, which is not installed. Run \`eider toolchain install 1.3.0\`" "$out"; [ $rc = 1 ] && ok || bad "exit status: $rc"
out=$(e +nope check); check "+ not a version" "\`+nope\` is not a version" "$out"
printf '[package]\nname = "p"\nversion = "0.1.0"\neider = "1.2"\n' > "$P/eider.toml"
out=$(CWD=$P/sub e test t.ei); check "eider.toml's eider, from a subdirectory" "eiderc 1.2.3 " "$out"
out=$(CWD=$P/sub e toolchain show --json); check "show --json" "{\"version\":\"1.2.3\",\"path\":\"$H/toolchains/1.2.3\",\"kind\":\"install\",\"why\":\"$P/eider.toml (eider = \\\"1.2\\\")\"}" "$out"
out=$(CWD=$P e +1.2.0 test t.ei); check "+ beats eider.toml" "eiderc 1.2.0 " "$out"
out=$(cd "$P" && env EIDER_TOOLCHAIN="$H/toolchains/1.2.0" EIDER_HOME="$H" "$E" test t.ei 2>&1); check "EIDER_TOOLCHAIN beats eider.toml" "eiderc 1.2.0 " "$out"
out=$(cd "$P" && env -u EIDER_AUTO_INSTALL EIDER_TOOLCHAIN="$H/toolchains/1.2.0" EIDER_HOME="$H" EIDER_RELEASES="file://$REL" "$E" +1.2.3 test 2>&1); check "+ beats EIDER_TOOLCHAIN" "eiderc 1.2.3 " "$out"
out=$(cd "$P" && env EIDER_TOOLCHAIN="$root" EIDER_HOME="$H" "$E" toolchain show 2>&1); check "EIDER_TOOLCHAIN: a checkout" "chosen by EIDER_TOOLCHAIN=$root" "$out"
out=$(cd "$P" && env EIDER_TOOLCHAIN="$T/nothing" EIDER_HOME="$H" "$E" build 2>&1); check "EIDER_TOOLCHAIN: neither" "is neither a toolchain (bin/eiderc) nor an eider-lang checkout" "$out"
printf '[package]\nname = "p"\nversion = "0.1.0"\neider = "1.3"\n' > "$P/eider.toml"
out=$(CWD=$P e build); rc=$?
check "eider.toml asks for a series that is not installed" "$P/eider.toml (eider = \"1.3\") asks for Eider 1.3, which is not installed. Run \`eider toolchain install 1.3\`" "$out"; [ $rc = 1 ] && ok || bad "exit status: $rc"
out=$(cd "$P" && env -u EIDER_TOOLCHAIN EIDER_AUTO_INSTALL=1 EIDER_HOME="$H" EIDER_RELEASES="file://$REL" EIDER_RELEASE_PUBKEY="$T/test.pub" "$E" build 2>&1)
check "auto-install" "installing it (auto-install)" "$out"; check "auto-install, then run" "eiderc 1.3.0 " "$out"
printf '[package]\nname = "p"\nversion = "0.1.0"\n' > "$P/eider.toml"
out=$(CWD=$P e build); check "an eider.toml without eider: the default" "eiderc 1.2.0 " "$out"

out=$(CWD=$P e add json --path ../json); check "add -> eider-pkg" "eider-pkg 1.2.0 root=$H/toolchains/1.2.0 eiderc=$H/toolchains/1.2.0/bin/eiderc args: add json --path ../json" "$out"
for c in init remove grant revoke fetch update vendor tree; do out=$(CWD=$P e $c x); check "$c -> eider-pkg" "eider-pkg 1.2.0 " "$out"; done
# the grants (#135): `eider grant http fs`, as E0204's help says, and accepting growth
out=$(CWD=$P e grant http fs,io); check "grant -> eider-pkg" "eider-pkg 1.2.0 root=$H/toolchains/1.2.0 eiderc=$H/toolchains/1.2.0/bin/eiderc args: grant http fs,io" "$out"
out=$(CWD=$P e revoke http fs); check "revoke -> eider-pkg" "eider-pkg 1.2.0 root=$H/toolchains/1.2.0 eiderc=$H/toolchains/1.2.0/bin/eiderc args: revoke http fs" "$out"
out=$(CWD=$P e update --grant http); check "update --grant -> eider-pkg" "eider-pkg 1.2.0 root=$H/toolchains/1.2.0 eiderc=$H/toolchains/1.2.0/bin/eiderc args: update --grant http" "$out"
out=$(CWD=$P e update --grant-all); check "update --grant-all -> eider-pkg" "args: update --grant-all" "$out"
out=$(CWD=$P e add http --git u --version 0.2.0 --confirm); check "add --confirm -> eider-pkg" "args: add http --git u --version 0.2.0 --confirm" "$out"
out=$(e new demo); check "new" "eider-pkg 1.2.0 root=$H/toolchains/1.2.0 eiderc=$H/toolchains/1.2.0/bin/eiderc args: -C demo init demo" "$out"
mkdir -p "$T/exists"; out=$(e new exists); check "new: the directory exists" "exists already" "$out"
out=$(e doc build --out site); check "doc -> eider-doc" "eider-doc 1.2.0 root=$H/toolchains/1.2.0 eiderc=$H/toolchains/1.2.0/bin/eiderc args: build --out site" "$out"
out=$(e eiderc --help); check "eiderc --help" "eiderc 1.2.0 root=" "$out"
out=$(e eider-pkg --version); check "eider-pkg --version" "eider-pkg 1.2.0 " "$out"
out=$(e version); check "version" "$(printf 'eider %s\ntoolchain 1.2.0 (%s/toolchains/1.2.0; the default' "$ver" "$H")" "$out"

# ---- use, remove
out=$(e toolchain use 1.3.0); check "use" "the default toolchain is 1.3.0" "$out"
out=$(e build); check "use changes the default" "eiderc 1.3.0 " "$out"
out=$(e toolchain use 7.7.7); check "use a version not installed" "eider 7.7.7 is not installed (eider toolchain install 7.7.7)" "$out"
out=$(e toolchain remove 1.3.0); check "remove the default" "it was the default, so there is none now" "$out"
[ ! -e "$H/toolchains/1.3.0" ] && ok || bad "remove left toolchains/1.3.0"
out=$(e build); check "no default after remove" "no toolchain is installed" "$out"
out=$(e toolchain use 1.2.3 && e build); check "use again" "eiderc 1.2.3 " "$out"

# ---- self update
out=$(e self update); check "self update" "eider: updated $H/bin/eider to 1.3.0 (checksum and signature verified)" "$out"
out=$("$H/bin/eider"); check "the new eider" "fake eider 1.3.0" "$out"
out=$(e self update --json); check "self update: up to date only when not older" '"updated":true' "$out"

# ---- tampering: nothing is installed, and the message says why
before=$(ls "$H/toolchains")
mkrel 2.0.0; printf 'x' >> "$REL/v2.0.0/eider-2.0.0-$TGT.tar.gz"
out=$(e toolchain install 2.0.0); rc=$?
check "a changed archive" "refusing eider-2.0.0-$TGT.tar.gz: its SHA-256 is" "$out"; [ $rc = 1 ] && ok || bad "exit status: $rc"
mkrel 2.0.1; printf 'x' >> "$REL/v2.0.1/eider-2.0.1-$TGT.tar.gz"; sums 2.0.1
out=$(e toolchain install 2.0.1); check "SHA256SUMS changed to match" "refusing release v2.0.1: SHA256SUMS.minisig does not verify with the release key" "$out"
check "SHA256SUMS changed: why" "the signature does not match the file" "$out"
mkrel 2.0.2 "$T/other.key"
out=$(e toolchain install 2.0.2); check "signed by another key" "the signature was made by key" "$out"
mkrel 2.0.3 "$T/test.key" 2.0.9
out=$(e toolchain install 2.0.3); check "another release's signed sums" "refusing release v2.0.3: its signed SHA256SUMS is for \`eider 2.0.9\`, not \`eider 2.0.3\`" "$out"
mkrel 2.0.4; sed -i 's/release:eider 2.0.4/release:eider 2.0.4 extra/' "$REL/v2.0.4/SHA256SUMS.minisig"
out=$(e toolchain install 2.0.4); check "a changed trusted comment" "the trusted comment's signature does not match" "$out"
mkrel 2.0.5; rm "$REL/v2.0.5/SHA256SUMS.minisig"
out=$(e toolchain install 2.0.5); check "no signature" "has no SHA256SUMS.minisig" "$out"
mkrel 2.0.6; mkdir -p "$T/stage-2.0.6/evil"; echo x > "$T/stage-2.0.6/evil/x"
tar -C "$T/stage-2.0.6" -czf "$REL/v2.0.6/eider-2.0.6-$TGT.tar.gz" "eider-2.0.6-$TGT" evil; sums 2.0.6; sign 2.0.6 "$T/test.key"
out=$(e toolchain install 2.0.6); check "an entry outside the archive's directory" "refusing the archive: the entry evil/ is outside eider-2.0.6-$TGT/" "$out"
[ ! -e "$H/toolchains/evil" ] && [ ! -e "$H/evil" ] && ok || bad "the outside entry was unpacked"
mkrel 2.0.7; ln -s /etc/passwd "$T/stage-2.0.7/eider-2.0.7-$TGT/link"
tar -C "$T/stage-2.0.7" -czf "$REL/v2.0.7/eider-2.0.7-$TGT.tar.gz" "eider-2.0.7-$TGT"; sums 2.0.7; sign 2.0.7 "$T/test.key"
out=$(e toolchain install 2.0.7); check "a link in the archive" "refusing the archive: it holds a link or a special file" "$out"
mkrel 2.0.8; printf '[toolchain]\nversion = "2.0.9"\ntarget = "%s"\n' "$TGT" > "$T/stage-2.0.8/eider-2.0.8-$TGT/toolchain.toml"
tar -C "$T/stage-2.0.8" -czf "$REL/v2.0.8/eider-2.0.8-$TGT.tar.gz" "eider-2.0.8-$TGT"; sums 2.0.8; sign 2.0.8 "$T/test.key"
out=$(e toolchain install 2.0.8); check "a toolchain.toml for another version" "its toolchain.toml names another version or target" "$out"
out=$(cd "$T" && env EIDER_HOME="$H" EIDER_RELEASES="file://$REL" EIDER_RELEASE_PUBKEY="$T/other.pub" "$E" toolchain install 1.2.3 --force 2>&1)
check "the wrong key (EIDER_RELEASE_PUBKEY)" "the signature was made by key" "$out"
out=$(cd "$T" && env -u EIDER_RELEASE_PUBKEY EIDER_HOME="$H" EIDER_RELEASES="file://$REL" "$E" toolchain install 1.2.3 --force 2>&1)
case $(sed -n 's/^pub const KEY_ID: str = "\(.*\)"$/\1/p' packages/eider/release_key.ei) in
  0000000000000000) check "the embedded key is a placeholder" "built without a release key" "$out" ;;
  *) check "the embedded release key refuses test-signed releases" "the signature was made by key" "$out" ;;
esac
[ "$(ls "$H/toolchains")" = "$before" ] && ok || bad "a refused release left something in toolchains/" "$(ls -a "$H/toolchains")"
[ -z "$(ls "$H/downloads/" 2>/dev/null | grep -v '^\.')" ] && ok || bad "a refused download was not removed: $(ls "$H/downloads")"

# ---- GitHub: the token, the API, the redirect to storage
printf '#!/bin/sh\nexit 1\n' > "$T/bin/gh"; chmod 755 "$T/bin/gh"
out=$(cd "$T" && env -u GH_TOKEN -u GITHUB_TOKEN PATH="$T/bin:$PATH" EIDER_HOME="$T/gh-home" EIDER_RELEASES=github:klxdev/eider-lang EIDER_RELEASE_PUBKEY="$T/test.pub" "$E" toolchain install 2>&1)
check "no token" "no GitHub token: klxdev/eider-lang is private" "$out"
if command -v python3 >/dev/null && command -v curl >/dev/null; then
  GREL=$T/gh-releases; mkdir -p "$GREL"; cp -R "$REL/v1.2.0" "$REL/v1.3.0" "$GREL/"
  python3 -I "$root/tests/eider/fake_github.py" "$GREL" klxdev/eider-lang secret-token "$T/port" &
  srv=$!
  i=0; while [ ! -f "$T/port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  api=http://127.0.0.1:$(cat "$T/port" 2>/dev/null)
  g() { (cd "$T" && env -u GITHUB_TOKEN PATH="$T/bin:$PATH" EIDER_HOME="$T/gh-home" EIDER_RELEASES=github:klxdev/eider-lang EIDER_GITHUB_API="$api" EIDER_RELEASE_PUBKEY="$T/test.pub" "$@" 2>&1); }
  out=$(g env GH_TOKEN=wrong "$E" toolchain install); check "GitHub: a rejected token" "GitHub answered 401 for the releases of klxdev/eider-lang: the token was rejected" "$out"
  out=$(g env GH_TOKEN=secret-token "$E" toolchain list --json); check "GitHub: list" '"available":["1.3.0","1.2.0"]' "$out"
  out=$(g env GH_TOKEN=secret-token "$E" toolchain install); check "GitHub: install latest" "installed eider 1.3.0 in $T/gh-home/toolchains/1.3.0 (checksum and signature verified)" "$out"
  out=$(g env -u GH_TOKEN GITHUB_TOKEN=secret-token "$E" toolchain install 1.2.0); check "GitHub: GITHUB_TOKEN" "installed eider 1.2.0" "$out"
  printf '#!/bin/sh\n[ "$1 $2" = "auth token" ] && echo secret-token\n' > "$T/bin/gh"
  out=$(g env -u GH_TOKEN "$E" self update); check "GitHub: the token from gh auth token" "updated $T/gh-home/bin/eider to 1.3.0" "$out"
  out=$(g env GH_TOKEN=secret-token EIDER_RELEASES=github:klxdev/other "$E" toolchain install); check "GitHub: a repository the token can't see" "GitHub answered 404 for the releases of klxdev/other: not found" "$out"
  # install.sh, through the same fake API and from the release directory
  out=$(g env GH_TOKEN=secret-token EIDER_HOME="$T/inst" sh "$root/install.sh" 2>&1); check "install.sh (GitHub)" "installed $T/inst/bin/eider (fake eider 1.3.0; signature checked with" "$out"
  check "install.sh prints the PATH line" "export PATH=\"$T/inst/bin:\$PATH\"" "$out"
else
  echo "skip eider: the fake GitHub API needs python3 and curl"
fi
out=$(cd "$T" && env EIDER_HOME="$T/inst2" EIDER_RELEASES="file://$REL" EIDER_RELEASE_PUBKEY="$T/test.pub" sh "$root/install.sh" --version 1.2.3 2>&1)
check "install.sh (a release directory)" "installed $T/inst2/bin/eider (fake eider 1.2.3" "$out"
out=$(cd "$T" && env EIDER_HOME="$T/inst3" EIDER_RELEASES="file://$REL" EIDER_RELEASE_PUBKEY="$T/test.pub" sh "$root/install.sh" --version 2.0.1 2>&1)
check "install.sh refuses changed SHA256SUMS" "refusing: SHA256SUMS.minisig does not verify" "$out"
out=$(cd "$T" && env EIDER_HOME="$T/inst3" EIDER_RELEASES="file://$REL" EIDER_RELEASE_PUBKEY="$T/test.pub" sh "$root/install.sh" --version 2.0.3 2>&1)
check "install.sh refuses another release's sums" "refusing: the signed SHA256SUMS is not for eider 2.0.3" "$out"
out=$(cd "$T" && env EIDER_HOME="$T/inst3" EIDER_RELEASES="file://$REL" EIDER_RELEASE_PUBKEY="$T/other.pub" sh "$root/install.sh" --version 1.2.3 2>&1)
check "install.sh refuses another key" "signed by another key than the release key" "$out"
mkrel 2.1.0; printf 'x' >> "$REL/v2.1.0/eider-2.1.0-$TGT"
out=$(cd "$T" && env EIDER_HOME="$T/inst3" EIDER_RELEASES="file://$REL" EIDER_RELEASE_PUBKEY="$T/test.pub" sh "$root/install.sh" --version 2.1.0 2>&1)
check "install.sh refuses a changed binary" "refusing eider-2.1.0-$TGT: its SHA-256 is" "$out"
[ ! -e "$T/inst3/bin/eider" ] && ok || bad "install.sh installed a refused eider"

if [ $fail = 0 ]; then echo "ok   eider ($n checks: install, selection, dispatch, self update, tampered releases, GitHub, install.sh)"; fi
exit $fail
