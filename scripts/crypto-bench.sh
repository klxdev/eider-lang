#!/bin/sh
# Throughput per crypto backend through the core ABI (tests/crypto/bench.c): MB/s for
# SHA-256 and the AEADs over 16 KiB messages, operations/s for X25519, Ed25519 and P-256.
# Usage: sh scripts/crypto-bench.sh [--eider] [backend...]   (default: every one that is built)
# --eider: also time the same operations end to end from Eider (tests/crypto/bench.ei), where
# the byte-at-a-time crossing of the core buffers dominates for large messages.
cd "$(dirname "$0")/.." || exit 1
CC=${CC:-cc}
eider=0
if [ "${1:-}" = --eider ]; then eider=1; shift; fi
mkdir -p target/crypto/bench
for b in ${*:-awslc awslc-noasm openssl libressl}; do
  sh scripts/crypto-build.sh --check "$b" >/dev/null 2>&1 || { echo "skip $b: not available here"; continue; }
  [ -f "target/crypto/$b/libeider_crypto.a" ] || { echo "skip $b: not built (sh scripts/crypto-build.sh $b)"; continue; }
  libs=$(cat "target/crypto/$b/libs" | sed 's/-l eider_crypto//')
  extra=
  [ -f "target/crypto/$b/extra_libdir" ] && extra="-L$(cat "target/crypto/$b/extra_libdir")"
  $CC -std=c11 -O2 -pthread -I core -I core/crypto -o "target/crypto/bench/$b" tests/crypto/bench.c core/eider_core.c \
    "target/crypto/$b/libeider_crypto.a" -L "target/crypto/$b" $extra $(echo $libs | sed 's/-l /-l/g') || exit 1
  "target/crypto/bench/$b"
  [ $eider = 1 ] && EIDER_CACHE=off scripts/ei-crypto --crypto "$b" run --release tests/crypto/bench.ei
  echo
done
