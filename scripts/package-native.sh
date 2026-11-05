#!/bin/sh
# Build, package and run a self-contained Apple Silicon toolchain on an Apple Silicon Mac.
# --check DIR checks an artifact from that build before a Linux publisher includes it.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd -P)
V=$(tr -d ' \n' < VERSION)
target=darwin-aarch64
name=eider-$V-$target
out=$root/target/release
check() (
  dir=$1
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT HUP INT TERM
  archive=$dir/$name.tar.gz
  [ -f "$archive" ] && [ -f "$dir/$name" ] || { echo "native: missing $name artifacts" >&2; exit 1; }
  # Only the named directory, no traversal or links; this also rejects sibling entries.
  tar -tzf "$archive" > "$work/list"
  if grep -Ev "^$name(/|$)" "$work/list" | grep -q . || grep -E '(^|/)\.\.(/|$)' "$work/list" | grep -q .; then
    echo "native: unsafe archive paths" >&2; exit 1
  fi
  tar -tvzf "$archive" | grep -E '^[lh]' > "$work/links" || true
  [ ! -s "$work/links" ] || { echo "native: archive has links" >&2; exit 1; }
  tar -xzf "$archive" -C "$work"
  tc=$work/$name
  grep -qx "version = \"$V\"" "$tc/toolchain.toml"
  grep -qx "target = \"$target\"" "$tc/toolchain.toml"
  grep -qx "commit = \"$(git rev-parse HEAD)\"" "$tc/toolchain.toml"
  grep -qx 'tested = true' "$tc/toolchain.toml"
  for bin in eiderc eider-pkg eider-doc eider; do
    [ -x "$tc/bin/$bin" ]
    file "$tc/bin/$bin" | grep -q 'Mach-O 64-bit executable arm64'
  done
  cmp "$tc/bin/eider" "$dir/$name"
  if [ "$(uname -sm)" = 'Darwin arm64' ]; then
    printf 'fn main() uses io { print("unpacked release smoke") }\n' > "$work/main.ei"
    got=$(cd "$work" && env -u EIDER_ROOT EIDER_TOOLCHAIN="$tc" EIDER_HOME="$work/home" EIDER_CACHE=off "$tc/bin/eider" run main.ei)
    [ "$got" = 'unpacked release smoke' ]
  fi
  echo "native: $name matches this commit and contains native-tested arm64 tools"
)
if [ "${1:-}" = --check ]; then check "$2"; exit; fi
git diff --quiet HEAD || { echo "native: commit tracked changes before packaging" >&2; exit 1; }
[ "$(uname -sm)" = 'Darwin arm64' ] || { echo 'native: needs an Apple Silicon macOS runner' >&2; exit 2; }
TAR=${TAR:-gtar}
"$TAR" --version | grep -q 'GNU tar' || { echo 'native: needs GNU tar (brew install gnu-tar)' >&2; exit 2; }
# AWS-LC is linked into eider: release downloads never depend on a Homebrew libcrypto.
sh scripts/vendor.sh fetch json toml markdown
sh scripts/fetch-awslc.sh
export EIDER_CRYPTO=awslc-noasm
export EIDER_ROOT=$root
export EIDER_CACHE=${EIDER_CACHE:-$root/target/cache}
sh scripts/crypto-build.sh awslc-noasm
mkdir -p "$out/$name/bin" "$out/assets/v$V"
tc=$out/$name
for pair in eiderc:compiler/main.ei eider-pkg:packages/pkg/main.ei eider-doc:packages/doc/main.ei eider:packages/eider/main.ei; do
  scripts/ei build "${pair#*:}" -o "$tc/bin/${pair%%:*}"
done
# Ship the committed runtime, library and compiler sources, never build output or .vendor/.
git archive HEAD -- core std compiler debug VERSION ':(exclude)compiler/tests' | tar -x -C "$tc"
{
  printf '[toolchain]\nversion = "%s"\ntarget = "%s"\ncommit = "%s"\n' "$V" "$target" "$(git rev-parse HEAD)"
  printf 'backend = "llvm"\nbuilt_with = "native clang; bundled AWS-LC"\ntested = true\n'
} > "$tc/toolchain.toml"
printf '# Eider %s for %s\n\nBuild programs with clang 17+ and a C compiler. Crypto is bundled; no Homebrew runtime is needed.\n' "$V" "$target" > "$tc/README.md"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
printf 'fn main() uses io { print("native release smoke") }\n' > "$work/main.ei"
# Test the shipped paths with caller overrides cleared, including the package manager.
for bin in eiderc eider-pkg eider-doc eider; do
  got=$(env -u EIDER_ROOT -u EIDER_TOOLCHAIN "$tc/bin/$bin" --version)
  [ "$got" = "$bin $V" ]
done
(cd "$work" && env -u EIDER_ROOT EIDER_TOOLCHAIN="$tc" EIDER_HOME="$work/home" EIDER_CACHE=off "$tc/bin/eider" build main.ei -o main)
[ "$("$work/main")" = 'native release smoke' ]
# Fail if any executable depends on a developer's Homebrew or build directory.
for bin in "$tc"/bin/*; do
  if otool -L "$bin" | tail -n +2 | grep -vE '^[[:space:]]*(/usr/lib/|/System/Library/)' | grep -q .; then
    echo "native: external runtime dependency in $bin" >&2; otool -L "$bin" >&2; exit 1
  fi
done
epoch=$(git log -1 --format=%ct HEAD)
"$TAR" -C "$out" --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner --format=gnu --mode='u+rwX,go+rX,go-w' -cf - "$name" | gzip -n -9 > "$out/assets/v$V/$name.tar.gz"
cp "$tc/bin/eider" "$out/assets/v$V/$name"
# Check the unpacked artifact, then run it (not just the staging directory).
check "$out/assets/v$V"
