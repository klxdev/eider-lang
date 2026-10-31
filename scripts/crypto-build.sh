#!/bin/sh
# Build a crypto backend: core/crypto/eider_crypto.c (the glue, core/ABI.md "Crypto") linked
# against one OpenSSL-compatible libcrypto, as target/crypto/<backend>/libeider_crypto.a.
# A program that imports "core/crypto" (or packages/crypto) links it with
#   LIBRARY_PATH=<dir> eiderc run prog.ei -l eider_crypto [-l crypto]
# which scripts/ei-crypto does for you. (core/crypto/README.md, "Choosing a backend".)
#
# Usage: sh scripts/crypto-build.sh [options] [backend]
#   backend    awslc (default): AWS-LC (pinned sources fetched by scripts/fetch-awslc.sh into target/crypto/awslc-src, or $EIDER_AWSLC_SRC), compiled with $CC only
#              awslc-noasm: the same without assembly (OPENSSL_NO_ASM; the portable build)
#              awslc-aead: awslc with the glue's EVP_AEAD path for ChaCha20-Poly1305 (BoringSSL's)
#              openssl: the system's OpenSSL 3 libcrypto (pkg-config, $EIDER_OPENSSL_INCLUDE,
#                       or headers from `fetch-openssl-headers`)
#              libressl: a pinned LibreSSL release fetched into target/ (needs make)
#              fetch-openssl-headers: put the openssl-devel headers matching the installed
#                       libcrypto into target/crypto/openssl-devel (dnf download; no root)
#   --san      compile the glue with -fsanitize=address,undefined (target/crypto/<backend>-san)
#   --libdir   only print the directory to put on LIBRARY_PATH (building first if needed)
#   --libs     only print the eiderc -l options
#   --check    exit 0 if the backend can be built here, else print why and exit 2
# The backend is the argument, else $EIDER_CRYPTO, else `provider` in the [crypto] table of
# ./eider.toml, else awslc. Exit 2 means "not available here" (missing tool or headers).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
CC=${CC:-cc}
san=0; mode=build; backend=
for a in "$@"; do
  case $a in
    --san) san=1 ;;
    --libdir) mode=libdir ;;
    --libs) mode=libs ;;
    --check) mode=check ;;
    -*) echo "crypto-build: unknown option $a" >&2; exit 1 ;;
    *) backend=$a ;;
  esac
done
if [ -z "$backend" ]; then backend=${EIDER_CRYPTO:-}; fi
if [ -z "$backend" ] && [ -f eider.toml ]; then
  # provider = "..." inside [crypto]
  backend=$(sed -n '/^\[crypto\]/,/^\[/s/^provider *= *"\([a-z0-9-]*\)".*/\1/p' eider.toml | head -1)
fi
backend=${backend:-awslc}
jobs=${EIDER_CRYPTO_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
unavailable() { echo "crypto-build: backend $backend not available: $1" >&2; exit 2; }

suffix=; [ $san = 1 ] && suffix=-san
out=$root/target/crypto/$backend$suffix
GLUE_FLAGS="-std=c11 -O2 -fPIC -Wall -Wextra -Wpedantic -Wshadow -Wstrict-prototypes -Wmissing-prototypes -Werror"
[ $san = 1 ] && GLUE_FLAGS="$GLUE_FLAGS -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer"

# ---------------------------------------------------------------- AWS-LC (pinned, fetched)
awslc() {
  v=${EIDER_AWSLC_SRC:-$root/target/crypto/awslc-src}
  . "$root/core/crypto/awslc/cflags.sh"
  [ -f "$v/include/openssl/base.h" ] || unavailable "AWS-LC sources not fetched (sh scripts/fetch-awslc.sh: downloads the pinned release, about 150 MB, and keeps the 25 MB it builds from)"
  [ $mode = check ] && return 0
  lists=universal
  defs=$AWSLC_DEFS
  arch=portable
  # libcrypto's objects: awslc-aead (the glue's EVP_AEAD path, the one BoringSSL takes for
  # ChaCha20-Poly1305) reuses awslc's
  lc=$out
  if [ "$backend" = awslc-aead ]; then lc=$root/target/crypto/awslc$suffix; GLUE_FLAGS="$GLUE_FLAGS -DEIDER_CRYPTO_EVP_AEAD=1"; fi
  mkdir -p "$lc"
  if [ "$backend" != awslc-noasm ] && [ "$(uname -s)" = Linux ]; then
    case $(uname -m) in
      x86_64|amd64) lists="universal linux_x86_64"; arch=x86_64 ;;
      aarch64|arm64) lists="universal linux_aarch64"; arch=aarch64 ;;
    esac
  fi
  [ $arch = portable ] && defs="$defs -DOPENSSL_NO_ASM=1"
  # the feature probes aws-lc-sys's cc builder runs
  defs="$defs$(awslc_probes "$CC" "$lc/probe")"
  flags="-std=c11 -O2 -fPIC -pthread -Wno-unused-parameter $defs $(awslc_includes "$v")"
  # rebuild libcrypto's objects only when the sources, the flags or the compiler changed
  key=$( { cat "$root/core/crypto/awslc/files.sha256"; echo "$flags $lists"; $CC --version 2>/dev/null | head -1; } | cksum)
  if [ ! -f "$lc/libcrypto.a" ] || [ "$(cat "$lc/key" 2>/dev/null)" != "$key" ]; then
    rm -rf "$lc/obj"; mkdir -p "$lc/obj"
    start=$(date +%s)
    for l in $lists; do cat "$root/core/crypto/awslc/sources/$l.txt"; done |
      # $1 = output dir, $2 = cc, $3 = flags, $4 = source dir, $5 = the file (from xargs)
      xargs -P "$jobs" -n 1 sh -c '
        f=$5; o=$1/obj/$(echo "$f" | tr / _).o; extra=
        case $f in third_party/s2n-bignum/*) extra=-DS2N_BN_HIDE_SYMBOLS=1 ;; esac
        case $f in *.S) extra="$extra -Wa,--noexecstack" ;; esac
        $2 $3 $extra -c "$4/$f" -o "$o" || { echo "crypto-build: failed to compile $f" >&2; exit 255; }
      ' sh "$lc" "$CC" "$flags" "$v" 2>"$lc/build.log" ||
      { cat "$lc/build.log" >&2; echo "crypto-build: AWS-LC did not build (log: $lc/build.log)" >&2; exit 1; }
    rm -f "$lc/libcrypto.a"
    ar rcs "$lc/libcrypto.a" "$lc"/obj/*.o
    echo "$key" > "$lc/key"
    echo "crypto-build: AWS-LC $(sed -n 's/^TAG=//p' "$root/core/crypto/awslc/PIN") ($arch) compiled in $(($(date +%s) - start)) s with $jobs jobs" >&2
  fi
  glue "$(awslc_includes "$v")" "$lc/libcrypto.a"
  echo "-l eider_crypto" > "$out/libs"
}

# ---------------------------------------------------------------- system OpenSSL 3
openssl_inc() {
  if pkg-config --exists 'libcrypto >= 3.0' 2>/dev/null; then pkg-config --cflags libcrypto; return; fi
  if [ -n "${EIDER_OPENSSL_INCLUDE:-}" ]; then echo "-I$EIDER_OPENSSL_INCLUDE"; return; fi
  d=$root/target/crypto/openssl-devel/usr/include
  if [ -f "$d/openssl/evp.h" ]; then echo "-I$d"; return; fi
  printf '#include <openssl/evp.h>\n' | $CC -E -x c - >/dev/null 2>&1 && return
  return 1
}
openssl() {
  inc=$(openssl_inc) || unavailable "no OpenSSL 3 headers (install openssl-devel / libssl-dev, set EIDER_OPENSSL_INCLUDE, or run: sh scripts/crypto-build.sh fetch-openssl-headers)"
  # the library: pkg-config's, else libcrypto.so.3 in the usual places (linked through a
  # libcrypto.so symlink in the output directory when there's no development symlink)
  mkdir -p "$out"
  lib=
  if pkg-config --exists 'libcrypto >= 3.0' 2>/dev/null; then lib=$(pkg-config --variable=libdir libcrypto); fi
  if [ -z "$lib" ] || [ ! -e "$lib/libcrypto.so" ]; then
    for d in ${EIDER_OPENSSL_LIB:-} /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib /usr/local/lib64 /usr/local/lib; do
      if [ -e "$d/libcrypto.so.3" ]; then ln -sf "$d/libcrypto.so.3" "$out/libcrypto.so"; lib=$out; break; fi
    done
  fi
  [ -n "$lib" ] || unavailable "no libcrypto.so.3 found (set EIDER_OPENSSL_LIB)"
  [ $mode = check ] && return 0
  echo "$lib" > "$out/extra_libdir"
  glue "$inc" "-L$lib -lcrypto"
  echo "-l eider_crypto -l crypto" > "$out/libs"
}
fetch_openssl_headers() {
  command -v dnf >/dev/null && command -v rpm2cpio >/dev/null && command -v cpio >/dev/null ||
    unavailable "needs dnf, rpm2cpio and cpio (or install your distribution's OpenSSL headers)"
  d=$root/target/crypto/openssl-devel
  rm -rf "$d"; mkdir -p "$d"
  ver=$(rpm -q --qf '%{VERSION}' openssl-libs)
  # the exact build if the repositories still have it, else the newest of the same 3.x
  # series (OpenSSL keeps the ABI stable within 3.x)
  (cd "$d" && { dnf -q download --arch "$(uname -m)" "openssl-devel-$ver" 2>/dev/null || dnf -q download --arch "$(uname -m)" openssl-devel; })
  rpm=$(ls "$d"/openssl-devel-*.rpm)
  (cd "$d" && rpm2cpio "$rpm" | cpio -idm --quiet)
  echo "crypto-build: OpenSSL headers from $(basename "$rpm") (installed libcrypto: $ver) in $d/usr/include" >&2
}

# ---------------------------------------------------------------- LibreSSL (fetched, pinned)
# https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-4.4.0.tar.gz; the hash is the one in
# that directory's SHA256 file
LIBRESSL_VERSION=4.4.0
LIBRESSL_SHA256=7d02522ad5070b9adb32eb253ecabce181184a3750cf65abac0675ee908687c1
libressl() {
  command -v make >/dev/null || unavailable "needs make (LibreSSL's build)"
  command -v curl >/dev/null || unavailable "needs curl to fetch LibreSSL"
  [ $mode = check ] && return 0
  src=$root/target/crypto/fetch/libressl-$LIBRESSL_VERSION
  tgz=$src.tar.gz
  if [ ! -f "$out/inst/lib/libcrypto.a" ]; then
    mkdir -p "$root/target/crypto/fetch"
    [ -f "$tgz" ] || curl -fsSL -o "$tgz" "https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-$LIBRESSL_VERSION.tar.gz"
    got=$(sha256sum "$tgz" | cut -d' ' -f1)
    [ "$got" = "$LIBRESSL_SHA256" ] || { echo "crypto-build: $tgz has SHA-256 $got, expected $LIBRESSL_SHA256" >&2; exit 1; }
    rm -rf "$src"; tar -xzf "$tgz" -C "$root/target/crypto/fetch"
    mkdir -p "$out"
    (cd "$src" && ./configure --prefix="$out/inst" --disable-shared --with-pic CC="$CC" >"$out/build.log" 2>&1 &&
      make -j"$jobs" -C crypto >>"$out/build.log" 2>&1 && make -C crypto install >>"$out/build.log" 2>&1 &&
      make -C include install >>"$out/build.log" 2>&1) ||
      { tail -20 "$out/build.log" >&2; echo "crypto-build: LibreSSL did not build (log: $out/build.log)" >&2; exit 1; }
  fi
  glue "-I$out/inst/include" "$out/inst/lib/libcrypto.a"
  echo "-l eider_crypto" > "$out/libs"
}

# ---------------------------------------------------------------- the glue
# $1 = include flags for libcrypto's headers; $2 = libcrypto: a static archive whose objects
# go into libeider_crypto.a, or linker flags (shared library, linked by the program)
glue() {
  mkdir -p "$out"
  $CC $GLUE_FLAGS -I "$root/core" -I "$root/core/crypto" $1 -c "$root/core/crypto/eider_crypto.c" -o "$out/eider_crypto.o"
  rm -f "$out/libeider_crypto.a"
  case $2 in
    *.a)
      # one archive with the glue and every libcrypto object, so `-l eider_crypto` is enough
      rm -rf "$out/ar"; mkdir -p "$out/ar"
      (cd "$out/ar" && ar x "$2")
      ar rcs "$out/libeider_crypto.a" "$out/eider_crypto.o" "$out"/ar/*.o
      rm -rf "$out/ar" ;;
    *) ar rcs "$out/libeider_crypto.a" "$out/eider_crypto.o" ;;
  esac
}

case $backend in
  awslc|awslc-noasm|awslc-aead) step=awslc ;;
  openssl) step=openssl ;;
  libressl) step=libressl ;;
  fetch-openssl-headers) fetch_openssl_headers; exit 0 ;;
  boringssl) unavailable "not built by this script yet (the glue supports it: core/crypto/README.md, \"Backends\")" ;;
  *) echo "crypto-build: unknown backend $backend (awslc, awslc-noasm, openssl, libressl)" >&2; exit 1 ;;
esac
if [ $mode = check ]; then $step; exit 0; fi
if [ $mode = build ] || [ ! -f "$out/libeider_crypto.a" ] || [ "$root/core/crypto/eider_crypto.c" -nt "$out/libeider_crypto.a" ]; then
  if [ $mode = build ]; then $step; else $step >&2; fi
fi
case $mode in
  libdir) if [ -f "$out/extra_libdir" ]; then echo "$out:$(cat "$out/extra_libdir")"; else echo "$out"; fi ;;
  libs) cat "$out/libs" ;;
esac
