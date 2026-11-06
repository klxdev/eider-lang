#!/bin/sh
# A package that imports crypto builds with only an installed toolchain (docs/decisions.md
# C898): the layout of a release's toolchain archive (bin/, core/, std/, packages/crypto and
# lib/crypto/awslc-noasm/, and no scripts/, no sources of AWS-LC, no checkout) is made here
# from this checkout's files and the compiler from compiler/, and a project, and a library
# fetched from a local git repository, depend on crypto with `[deps.crypto] toolchain = true`.
# The grants rules (`uses`) hold for it like for any dependency. No network.
# Prints `ok   <step>` or `FAIL <step>`; EIDERC=<binary> names the compiler (tests/pkg/run.sh).
cd "$(dirname "$0")/../.." || exit 1
R=$(pwd)
T="$R/target/tmp/tctest"
rm -rf "$T"
mkdir -p "$T/home" "$T/repos"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
EC=${EIDERC:-$R/target/eiderc-next}
[ -x "$EC" ] || { echo "FAIL toolchain: no compiler at $EC"; exit 1; }
scripts/eider-pkg >/dev/null 2>&1
[ -x target/eider-pkg ] || { echo "FAIL toolchain: no target/eider-pkg"; exit 1; }
sh scripts/crypto-build.sh --check awslc-noasm >/dev/null 2>&1 || { echo "skip: toolchain package: no AWS-LC sources (sh scripts/fetch-awslc.sh)"; exit 0; }
sh scripts/crypto-build.sh awslc-noasm >"$T/crypto.log" 2>&1 || { cat "$T/crypto.log"; echo "FAIL toolchain: awslc-noasm did not build"; exit 1; }

# the toolchain, as the release lays it out
TC=$T/eider-toolchain
mkdir -p "$TC/bin" "$TC/packages/crypto" "$TC/lib/crypto/awslc-noasm"
cp "$EC" "$TC/bin/eiderc"
cp target/eider-pkg "$TC/bin/eider-pkg"
cp -R core std "$TC/"
cp VERSION "$TC/"
cp packages/crypto/eider.toml packages/crypto/crypto.ei "$TC/packages/crypto/"
cp target/crypto/awslc-noasm/libeider_crypto.a target/crypto/awslc-noasm/libs "$TC/lib/crypto/awslc-noasm/"
[ ! -e "$TC/scripts" ] || bad "the toolchain layout has no scripts/"
unset EIDER_TOOLCHAIN EIDER_CRYPTO
EIDER_HOME="$T/home"; EIDER_CACHE=off; EIDER_ROOT="$TC"; EIDERC="$TC/bin/eiderc"
export EIDER_HOME EIDER_CACHE EIDER_ROOT EIDERC
GIT_CONFIG_GLOBAL=/dev/null; GIT_CONFIG_NOSYSTEM=1; GIT_AUTHOR_NAME=t; GIT_AUTHOR_EMAIL=t@example.com
GIT_COMMITTER_NAME=t; GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
pkg() { p=$1; shift; "$TC/bin/eider-pkg" -C "$T/$p" "$@" 2>&1; echo "exit $?"; }
# contains <step> <text> <needle>
contains() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1"; printf '%s\n' "$2" | head -12 ;; esac }

# a library that uses crypto, in a git repository (what eider-tls is)
mkdir -p "$T/repos/hashlib"
cat > "$T/repos/hashlib/eider.toml" <<'EOF'
[package]
name = "hashlib"
version = "0.1.0"
eider = "0.7"

[deps.crypto]
toolchain = true
uses = ["io"]
EOF
cat > "$T/repos/hashlib/hashlib.ei" <<'EOF'
import std.encoding
import crypto

pub fn digest_hex(msg: str) -> String {
    encoding.hex(crypto.sha256(msg.bytes()))
}

pub fn token() -> usize uses io {
    match crypto.random_bytes(16) {
        Ok(b) => b.len()
        Err(_) => 0
    }
}
EOF
git -C "$T/repos/hashlib" init -q -b main
git -C "$T/repos/hashlib" add -A
git -C "$T/repos/hashlib" commit -q -m init
git -C "$T/repos/hashlib" tag v0.1.0

# an application: depends on the library by git (not on crypto itself)
mkdir -p "$T/app"
cat > "$T/app/eider.toml" <<EOF
[package]
name = "app"
version = "0.1.0"
eider = "0.7"

[deps.hashlib]
git = "file://$T/repos/hashlib"
version = "0.1.0"
uses = ["io"]
EOF
cat > "$T/app/main.ei" <<'EOF'
import hashlib

fn main() uses io {
    print(hashlib.digest_hex("abc"))
    print(hashlib.token())
}
EOF
out=$(pkg app fetch)
contains "a git package with a toolchain dependency on crypto resolves" "$out" "locked 2 package(s)"
grep -q '^source = "toolchain+packages/crypto"' "$T/app/eider.lock" && ok "eider.lock records crypto as a toolchain package" || { bad "eider.lock records crypto as a toolchain package"; cat "$T/app/eider.lock"; }
got=$(cd "$T/app" && "$EC" run main.ei 2>&1)
want="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
16"
[ "$got" = "$want" ] && ok "a program importing crypto builds and runs with only the toolchain (no scripts/, no AWS-LC sources)" || { bad "a program importing crypto builds and runs with only the toolchain"; printf '%s\n' "$got" | head; }

# the application imports crypto itself
mkdir -p "$T/direct"
cat > "$T/direct/eider.toml" <<'EOF'
[package]
name = "direct"
version = "0.1.0"
eider = "0.7"
EOF
out=$(pkg direct add crypto --toolchain)
contains "add --toolchain declares crypto and grants what it uses" "$out" "added crypto"
grep -q '^toolchain = true' "$T/direct/eider.toml" && grep -q '^uses = \["io"\]' "$T/direct/eider.toml" && ok "the table says toolchain = true and uses = [\"io\"]" || { bad "the table says toolchain = true and uses"; cat "$T/direct/eider.toml"; }
printf 'import std.encoding\nimport crypto\n\nfn main() uses io {\n    print(encoding.hex(crypto.sha256("abc".bytes())))\n}\n' > "$T/direct/main.ei"
got=$(cd "$T/direct" && "$EC" run main.ei 2>&1)
[ "$got" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ] && ok "a root package imports crypto from the toolchain" || { bad "a root package imports crypto from the toolchain"; printf '%s\n' "$got" | head; }
# the compile-time grant check (E0204) holds: take the grant away and the build stops
sed -i 's/^uses = .*/uses = []/' "$T/direct/eider.toml"
out=$(cd "$T/direct" && "$EC" build main.ei -o "$T/direct/out" 2>&1)
contains "without its grant crypto is held to E0204" "$out" "E0204"
out=$(pkg direct fetch)
contains "eider-pkg fetch stops when crypto uses more than granted" "$out" "more capabilities than granted"

# crypto is a package of the toolchain only under its own name
mkdir -p "$T/other"
printf '[package]\nname = "other"\nversion = "0.1.0"\n\n[deps.json]\ntoolchain = true\n' > "$T/other/eider.toml"
out=$(pkg other fetch)
contains "only the packages a toolchain ships can be toolchain dependencies" "$out" "is not a package this toolchain ships (crypto)"
printf '[package]\nname = "other"\nversion = "0.1.0"\n\n[deps.crypto]\ntoolchain = true\ngit = "file:///nowhere"\nversion = "1.0.0"\n' > "$T/other/eider.toml"
out=$(pkg other fetch)
contains "a toolchain dependency takes no git or path" "$out" "takes no \`path\`, \`git\`, \`version\` or \`rev\`"

# a library that points at crypto by path cannot be fetched through git, and the error says what to write
mkdir -p "$T/repos/pathlib"
printf '[package]\nname = "pathlib"\nversion = "0.1.0"\n\n[deps.crypto]\npath = "../crypto"\n' > "$T/repos/pathlib/eider.toml"
printf 'import crypto\n' > "$T/repos/pathlib/pathlib.ei"
git -C "$T/repos/pathlib" init -q -b main
git -C "$T/repos/pathlib" add -A
git -C "$T/repos/pathlib" commit -q -m init
git -C "$T/repos/pathlib" tag v0.1.0
mkdir -p "$T/pathapp"
printf '[package]\nname = "pathapp"\nversion = "0.1.0"\n\n[deps.pathlib]\ngit = "file://%s/repos/pathlib"\nversion = "0.1.0"\n' "$T" > "$T/pathapp/eider.toml"
out=$(pkg pathapp fetch)
contains "a git package with a path dependency on crypto is refused, naming the fix" "$out" "[deps.crypto] toolchain = true"

# a toolchain without the package says so
mv "$TC/packages/crypto" "$TC/packages/crypto.off"
out=$(pkg direct fetch)
contains "a toolchain without packages/crypto says so" "$out" "is a package of the toolchain, but this one"
mv "$TC/packages/crypto.off" "$TC/packages/crypto"

# the backend: a toolchain without a shipped one, and one asked for another provider
mv "$TC/lib/crypto" "$TC/lib/crypto.off"
sed -i 's/^uses = .*/uses = ["io"]/' "$T/direct/eider.toml"
out=$(cd "$T/direct" && "$EC" build main.ei -o "$T/direct/out" 2>&1)
contains "a toolchain with neither scripts/crypto-build.sh nor lib/crypto says so" "$out" "has neither scripts/crypto-build.sh nor lib/crypto/awslc-noasm/libeider_crypto.a"
mv "$TC/lib/crypto.off" "$TC/lib/crypto"
out=$(cd "$T/direct" && "$EC" build main.ei -o "$T/direct/out" --crypto openssl 2>&1)
contains "an installed toolchain ships awslc only" "$out" "this toolchain has no crypto backend \`openssl\`"
out=$(cd "$T/direct" && "$EC" build main.ei -o "$T/direct/out" --crypto awslc 2>&1) && ok "awslc names the shipped backend" || { bad "awslc names the shipped backend"; printf '%s\n' "$out" | head; }

exit $fail
