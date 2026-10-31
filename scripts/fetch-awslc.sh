#!/bin/sh
# Fetch the pinned AWS-LC libcrypto sources into target/crypto/awslc-src (the default crypto
# backend's sources; core/crypto/README.md, "AWS-LC").
#
#   sh scripts/fetch-awslc.sh            download the release in core/crypto/awslc/PIN, check
#                                        its SHA-256 and commit, and extract exactly the files
#                                        in core/crypto/awslc/files.sha256, each hash-checked
#   sh scripts/fetch-awslc.sh --check    only re-check an existing target/crypto/awslc-src
#   sh scripts/fetch-awslc.sh --repin    after editing PIN for a new release: recompute the
#                                        source lists and files.sha256, then fetch, build and
#                                        run the vectors (review the diff of core/crypto/awslc/)
#
# EIDER_AWSLC_TARBALL=<file> uses a local copy of the release tarball (offline builds); its
# hash is checked like a download's. Nothing is trusted on first use: a hash that doesn't
# match stops the script before anything is extracted.
#
# --repin:
#   1. takes the per-platform libcrypto source lists from aws-lc-sys's CMake-free "cc
#      builder" (builder/cc_builder/*.rs in the crate named in PIN, hash-checked, whose bundled
#      AWS-LC must be the pinned one);
#   2. preprocesses every listed file (x86-64 with assembly, portable with OPENSSL_NO_ASM,
#      and the aarch64 lists with clang when it has the target) to find exactly the files a
#      build reads, adds include/openssl/ and the licenses;
#   3. writes sources/*.txt and files.sha256.
#   It needs curl, tar, gzip, sha256sum, GNU realpath and cc, on x86-64 Linux.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
dir=$root/core/crypto/awslc
dest=$root/target/crypto/awslc-src
fetch=$root/target/crypto/fetch
mode=${1:-fetch}

check_src() {
  [ -d "$dest" ] || { echo "fetch-awslc: $dest is missing" >&2; exit 1; }
  (cd "$dest" && sha256sum --quiet -c "$dir/files.sha256") || { echo "fetch-awslc: $dest does not match files.sha256" >&2; exit 1; }
  echo "ok   target/crypto/awslc-src: $(wc -l < "$dir/files.sha256") files match core/crypto/awslc/files.sha256"
}
if [ "$mode" = --check ]; then check_src; exit 0; fi

. "$dir/PIN"   # TAG COMMIT TARBALL_SHA256 CRATE CRATE_VERSION CRATE_SHA256
mkdir -p "$fetch"
tarball=${EIDER_AWSLC_TARBALL:-$fetch/aws-lc-$TAG.tar.gz}
if [ ! -f "$tarball" ]; then
  command -v curl >/dev/null || { echo "fetch-awslc: needs curl (or EIDER_AWSLC_TARBALL=<file>)" >&2; exit 2; }
  curl -fsSL -o "$tarball.part" "https://github.com/aws/aws-lc/archive/refs/tags/$TAG.tar.gz"
  mv "$tarball.part" "$tarball"
fi
got=$(sha256sum "$tarball" | cut -d' ' -f1)
[ "$got" = "$TARBALL_SHA256" ] || { echo "fetch-awslc: $tarball has SHA-256 $got, PIN says $TARBALL_SHA256" >&2; exit 1; }
# GitHub records the commit in the archive's pax header ("52 comment=<sha>")
c=$(gzip -dc "$tarball" | head -c 1024 | tr '\0' '\n' | sed -n 's/^52 comment=//p')
[ "$c" = "$COMMIT" ] || { echo "fetch-awslc: archive records commit '$c', PIN says $COMMIT" >&2; exit 1; }
top=aws-lc-${TAG#v}

if [ "$mode" = fetch ]; then
  rm -rf "$dest" "$dest.tmp"; mkdir -p "$dest.tmp"
  sed "s|^[0-9a-f]*  |$top/|" "$dir/files.sha256" > "$fetch/members.txt"
  tar -xzf "$tarball" -C "$dest.tmp" -T "$fetch/members.txt"
  mv "$dest.tmp/$top" "$dest"; rmdir "$dest.tmp"
  check_src
  echo "fetched aws-lc $TAG ($COMMIT): $(du -sh "$dest" | cut -f1) in target/crypto/awslc-src"
  exit 0
fi
[ "$mode" = --repin ] || { echo "usage: sh scripts/fetch-awslc.sh [--check | --repin]" >&2; exit 1; }

# ---------------------------------------------------------------- --repin
src=$fetch/src/$top
rm -rf "$fetch/src" "$fetch/crate"; mkdir -p "$fetch/src" "$fetch/crate"
tar -xzf "$tarball" -C "$fetch/src"
crate=$fetch/$CRATE-$CRATE_VERSION.crate
[ -f "$crate" ] || curl -fsSL -o "$crate" "https://static.crates.io/crates/$CRATE/$CRATE-$CRATE_VERSION.crate"
got=$(sha256sum "$crate" | cut -d' ' -f1)
[ "$got" = "$CRATE_SHA256" ] || { echo "fetch-awslc: $crate has SHA-256 $got, PIN says $CRATE_SHA256" >&2; exit 1; }
tar -xzf "$crate" -C "$fetch/crate"
cdir=$fetch/crate/$CRATE-$CRATE_VERSION
cmp -s "$cdir/aws-lc/include/openssl/base.h" "$src/include/openssl/base.h" ||
  { echo "fetch-awslc: $CRATE $CRATE_VERSION does not bundle the pinned AWS-LC (include/openssl/base.h differs)" >&2; exit 1; }

# source lists: the quoted paths in builder/cc_builder/<platform>.rs (jitterentropy is the
# FIPS build's entropy source, which the default build leaves out)
mkdir -p "$dir/sources"
for p in universal linux_x86_64 linux_aarch64; do
  grep -o '"[^"]*"' "$cdir/builder/cc_builder/$p.rs" | tr -d '"' | grep -v jitterentropy > "$dir/sources/$p.txt"
done

deps=$fetch/deps
rm -rf "$deps"; mkdir -p "$deps"
. "$dir/cflags.sh"   # AWSLC_DEFS, awslc_includes
inc=$(awslc_includes "$src")
# the probe defines as on Linux (they only add includes), so their headers are listed too
defs="$AWSLC_DEFS -DAWS_LC_BUILTIN_SWAP_SUPPORTED=1 -DHAVE_LINUX_RANDOM_H=1"
n=0
while read -r f; do
  for extra in "" -DOPENSSL_NO_ASM=1; do
    n=$((n + 1))
    ${CC:-cc} -std=c11 $defs $extra $inc -MM -MF "$deps/$n.d" -MT x "$src/$f" >/dev/null ||
      { echo "fetch-awslc: cannot preprocess $f" >&2; exit 1; }
  done
done < "$dir/sources/universal.txt"
while read -r f; do
  n=$((n + 1))
  ${CC:-cc} $defs $inc -MM -MF "$deps/$n.d" -MT x "$src/$f" >/dev/null || { echo "fetch-awslc: cannot preprocess $f" >&2; exit 1; }
done < "$dir/sources/linux_x86_64.txt"
if clang --target=aarch64-linux-gnu -E -x assembler-with-cpp /dev/null >/dev/null 2>&1; then
  # aarch64 as its compiler sees the files (-MG: no aarch64 system headers needed here)
  for l in universal linux_aarch64; do
    while read -r f; do
      n=$((n + 1))
      clang --target=aarch64-linux-gnu -std=c11 $defs $inc -MM -MG -MF "$deps/$n.d" -MT x "$src/$f" >/dev/null 2>&1 || echo "$src/$f" > "$deps/$n.d"
    done < "$dir/sources/$l.txt"
  done
else
  echo "note: no clang aarch64 target; listing the aarch64 files without their include closure"
fi
{
  cat "$deps"/*.d | tr ' \\' '\n\n' | grep "^$src/" | xargs realpath --relative-to="$src"
  cat "$dir/sources/universal.txt" "$dir/sources/linux_x86_64.txt" "$dir/sources/linux_aarch64.txt"
  (cd "$src" && find include/openssl -type f)
  printf '%s\n' LICENSE NOTICE third_party/s2n-bignum/s2n-bignum-imported/LICENSE third_party/s2n-bignum/s2n-bignum-imported/NOTICE
} | LC_ALL=C sort -u > "$fetch/files.txt"
(cd "$src" && xargs sha256sum < "$fetch/files.txt") > "$dir/files.sha256"
echo "repinned aws-lc $TAG ($COMMIT): $(wc -l < "$dir/files.sha256") files"
sh "$0"
sh scripts/crypto-build.sh awslc
sh tests/crypto/run.sh awslc
