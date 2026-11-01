#!/bin/sh
# The crypto vectors against every available backend, plus the cross-backend checks.
#
#   sh tests/crypto/run.sh [--san] [backend...]
#
# Backends (default: all four): awslc, awslc-noasm (AWS-LC without assembly), openssl,
# libressl. A backend that isn't available here is reported as `skip` with the reason
# (scripts/crypto-build.sh --check); no backend is downloaded: fetch first with
# scripts/fetch-awslc.sh, scripts/crypto-build.sh libressl or fetch-openssl-headers.
# wycheproof.ei and cross.ei read JSON with eider-json, the pinned release in .vendor/json
# (fetched on first use by scripts/vendor.sh); they are `skip` when it can't be fetched.
# --san: also run the RFC vectors with the glue and the program under ASan+UBSan.
#
# For each backend: rfc.ei (RFC 8439, 7748, 8032, 5869, 4231 and the package's misuse
# checks), cavp.ei (NIST CAVP), wycheproof.ei. Then cross.ei: every pair of backends must
# give byte-identical results for each deterministic operation both provide, and each one
# verifies the others' fresh P-256 (random k) and Ed25519 signatures.
# Output: `ok`, `FAIL` and `skip` lines; exit 1 on any failure.
cd "$(dirname "$0")/../.." || exit 1
EIDER_CACHE=off; export EIDER_CACHE
san=0
if [ "${1:-}" = --san ]; then san=1; shift; fi
want=${*:-awslc awslc-noasm awslc-aead openssl libressl}
out=target/crypto/test
mkdir -p "$out"
fail=0
have=
json=
for b in $want; do
  why=$(sh scripts/crypto-build.sh --check "$b" 2>&1) || { echo "skip crypto ($b): ${why#crypto-build: }"; continue; }
  if [ "$b" = libressl ] && [ ! -f target/crypto/libressl/libeider_crypto.a ]; then
    echo "skip crypto ($b): not built (sh scripts/crypto-build.sh libressl fetches LibreSSL and builds it)"; continue
  fi
  if ! sh scripts/crypto-build.sh "$b" > "$out/$b.build" 2>&1; then
    echo "FAIL crypto ($b): backend did not build ($out/$b.build)"; fail=1; continue
  fi
  if [ -z "$json" ]; then
    jwhy=$(sh scripts/vendor.sh fetch json 2>&1)
    case $? in
      0) json=yes ;;
      3) json=no; jwhy=$(printf '%s\n' "$jwhy" | grep 'cannot fetch' | head -1 | sed 's/^vendor.sh: //; s/, no source has it.*//') ;;
      *) echo "FAIL crypto: sh scripts/vendor.sh fetch json"; printf '%s\n' "$jwhy" | sed 's/^/  /'; exit 1 ;;
    esac
  fi
  have="$have $b"
  for t in rfc cavp wycheproof; do
    if [ $t = wycheproof ] && [ $json = no ]; then echo "skip crypto wycheproof ($b): needs .vendor/json ($jwhy; sh scripts/vendor.sh fetch json)"; continue; fi
    start=$(date +%s)
    if scripts/ei-crypto --crypto "$b" run "tests/crypto/$t.ei" > "$out/$b.$t" 2>&1; then
      echo "ok   crypto $t ($b): $(tail -1 "$out/$b.$t" | sed 's/^[a-z]*: //') [$(($(date +%s) - start)) s]"
    else
      echo "FAIL crypto $t ($b): see $out/$b.$t"; grep FAIL "$out/$b.$t" | head -5; tail -2 "$out/$b.$t"; fail=1
    fi
  done
  if [ $json = no ]; then :
  elif scripts/ei-crypto --crypto "$b" run tests/crypto/cross.ei > "$out/$b.cross" 2>&1; then :; else
    echo "FAIL crypto cross emit ($b): see $out/$b.cross"; fail=1
  fi
  if [ $san = 1 ]; then
    if EIDER_CFLAGS="-fsanitize=address,undefined -fno-sanitize-recover=undefined" scripts/ei-crypto --san --crypto "$b" run tests/crypto/rfc.ei > "$out/$b.san" 2>&1; then
      echo "ok   crypto rfc under ASan+UBSan ($b, glue and program instrumented)"
    else
      echo "FAIL crypto rfc under ASan+UBSan ($b): see $out/$b.san"; fail=1
    fi
  fi
done

# every pair: identical deterministic outputs, and each verifies the other's signatures
if [ "$json" = no ] && [ -n "$have" ]; then
  echo "skip crypto cross: needs .vendor/json ($jwhy; sh scripts/vendor.sh fetch json)"; have=
fi
set -- $have
for a in "$@"; do
  for b in "$@"; do
    [ "$a" = "$b" ] && continue
    if [ "$a" \< "$b" ]; then
      r=$(awk '
        $1 == "p256sig" || $1 == "ed25519sig" { next }
        NR == FNR { v[$1] = $2; next }
        ($1 in v) { if (v[$1] == "unsupported" || $2 == "unsupported") { skip++ } else if (v[$1] == $2) { same++ } else { diff++; print "differs: " $1 > "/dev/stderr" } }
        END { printf "%d %d %d", same, diff, skip }' "$out/$a.cross" "$out/$b.cross" 2>"$out/$a-$b.diff")
      set -- $r
      if [ "$2" = 0 ] && [ "$1" -gt 0 ]; then
        echo "ok   crypto cross $a = $b: $1 deterministic outputs identical ($3 not compared: unsupported by one)"
      else
        echo "FAIL crypto cross $a vs $b: $2 differ ($out/$a-$b.diff)"; head -5 "$out/$a-$b.diff"; fail=1
      fi
      set -- $have
    fi
    if CRYPTO_CROSS=verify CRYPTO_CROSS_FILE="$out/$a.cross" scripts/ei-crypto --crypto "$b" run tests/crypto/cross.ei > "$out/$a-by-$b.verify" 2>&1; then
      echo "ok   crypto cross: $b verifies $a's signatures ($(tail -1 "$out/$a-by-$b.verify" | sed 's/^[a-z-]*: //'))"
    else
      echo "FAIL crypto cross: $b verifying $a's signatures ($out/$a-by-$b.verify)"; fail=1
    fi
  done
done
exit $fail
