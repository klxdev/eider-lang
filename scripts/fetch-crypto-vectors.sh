#!/bin/sh
# Re-create tests/crypto/vectors/ from the upstream test-vector releases (pinned by SHA-256
# below). The files there are committed, so the tests need no network; run this only to
# check them against upstream or to change the selection. Each file is either an upstream
# file unmodified (Wycheproof JSON, NIST .rsp files) or a selection of whole sections and
# whole records of one (written by `pick` below; the header says which). Provenance:
# tests/crypto/vectors/SOURCES.
# Needs: curl, unzip, awk, sha256sum.
set -eu
cd "$(dirname "$0")/.."
out=tests/crypto/vectors
tmp=target/crypto/vectors-fetch
rm -rf "$tmp"; mkdir -p "$tmp" "$out"

get() { # url sha256 file
  curl -fsSL -o "$tmp/$3" "$1"
  got=$(sha256sum "$tmp/$3" | cut -d' ' -f1)
  [ "$got" = "$2" ] || { echo "fetch-crypto-vectors: $3 has SHA-256 $got, expected $2" >&2; exit 1; }
}

W=https://raw.githubusercontent.com/C2SP/wycheproof/d17cc89fa5c8f4f4d378b5385ebf75da5d0926c9/testvectors_v1
get $W/x25519_test.json 35c3f5231cf25cc640b524d403461deee9e49441d5d915a3a25b2c8ff5adbe7d x25519_test.json
get $W/ed25519_test.json ea80ffebac085e21cb9d3e903e7fa2b448d96702da5b31f061d0b83b430b74b3 ed25519_test.json
get $W/ecdsa_secp256r1_sha256_test.json 182db4f3e230f6f9fa9f800d2a614dede30284b8e8438bbfe1171905402e9332 ecdsa_secp256r1_sha256_test.json
get $W/ecdh_secp256r1_ecpoint_test.json 648f16d077caf2400d02331ca51f44744c72c799830c8d0595d0b18b6dd9f886 ecdh_secp256r1_ecpoint_test.json
get $W/aes_gcm_test.json 985e5ecc172e181eaf49e89508b9470dcf478002eb7e8559c707eb42dc97dfe7 aes_gcm_test.json
get $W/chacha20_poly1305_test.json fe61d25f90e1bde4461d00eafe61049e5f29bd999f36b766df9cda90906ad53d chacha20_poly1305_test.json
get $W/hkdf_sha256_test.json bb2b462a38b251cb52a2aede706d6d4b62b26864f4e80c95497507ddb07c5f1e hkdf_sha256_test.json
get $W/hkdf_sha384_test.json 69ff6ea3657bb9c1b8cdffbbb4e7832353d08fd15c0d9997b03f7a6b180e3678 hkdf_sha384_test.json
get $W/hmac_sha256_test.json 2d201cfa61d1bf95e6f5d07d96634b4a348b31e8eaa277ad7c8d09677b7a743f hmac_sha256_test.json
get $W/hmac_sha384_test.json 28b9776e979dd755d852ca471043ea6cedce8b15f7a28abdf6ea9efd982b43c0 hmac_sha384_test.json
for f in "$tmp"/*.json; do cp "$f" "$out/wycheproof_$(basename "$f")"; done

N=https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents
get $N/shs/shabytetestvectors.zip 929ef80b7b3418aca026643f6f248815913b60e01741a44bba9e118067f4c9b8 sha.zip
get $N/sha3/sha-3bytetestvectors.zip cd07701af2e47f5cc889d642528b4bf11f8b6eb55797c7307a96828ed8d8fc8c sha3.zip
get $N/mac/hmactestvectors.zip 418c3837d38f249d6668146bd0090db24dd3c02d2e6797e3de33860a387ae4bd hmac.zip
get $N/mac/gcmtestvectors.zip f9fc479e134cde2980b3bb7cddbcb567b2cd96fd753835243ed067699f26a023 gcm.zip
get $N/dss/186-4ecdsatestvectors.zip fe47cc92b4cee418236125c9ffbcd9bb01c8c34e74a4ba195d954bcb72824752 ecdsa.zip
get $N/components/ecccdhtestvectors.zip 5fff092551f2d72e89a3d9362711878708f9a14b502f0dfae819649105b0ea39 ecdh.zip
for z in sha sha3 hmac gcm ecdsa ecdh; do unzip -q -o -j -d "$tmp/$z" "$tmp/$z.zip"; done

# whole files
for f in SHA256ShortMsg SHA384ShortMsg SHA512ShortMsg; do tr -d '\r' < "$tmp/sha/$f.rsp" > "$out/cavp_$f.rsp"; done
for f in SHA3_256ShortMsg SHA3_384ShortMsg SHA3_512ShortMsg; do tr -d '\r' < "$tmp/sha3/$f.rsp" > "$out/cavp_$f.rsp"; done

# pick FILE SECTION-REGEX MAX-RECORDS: the sections whose [header] lines all match, with at
# most MAX records each (a record is a run of non-blank lines starting with "Count =" or
# "COUNT ="; 0 = all). Comment lines (#) are kept.
pick() {
  tr -d '\r' < "$1" | RE="$2" awk -v max="$3" -v src="$(basename "$1")" '
    BEGIN { re = ENVIRON["RE"]; print "# selected from " src " (scripts/fetch-crypto-vectors.sh): sections matching " re ", " (max ? "the first " max " records" : "all records") " of each" }
    /^#/ { next }
    /^\[/ { if (!inhdr) { hdr = ""; inhdr = 1 } hdr = hdr $0 "\n"; next }
    {
      if (inhdr && $0 == "") next
      if (inhdr) { inhdr = 0; keep = (hdr ~ re); n = 0; if (keep) printf "\n%s", hdr }
      if (!keep) next
      if ($0 ~ /^(Count|COUNT|Len) = /) { n++; if (max && n > max) skip = 1; else { skip = 0; print "" } }
      if ($0 == "") next
      if (!skip) print
    }'
}
pick "$tmp/sha/SHA256LongMsg.rsp" 'L = 32' 3 > "$out/cavp_SHA256LongMsg_first3.rsp"
pick "$tmp/hmac/HMAC.rsp" '\[L=(32|48|64)\]' 20 > "$out/cavp_HMAC_sha2.rsp"
for k in 128 256; do
  pick "$tmp/gcm/gcmEncryptExtIV$k.rsp" 'IVlen = 96\].*\[PTlen = (0|128|256|408)\].*\[AADlen = (0|128|160|720)\].*\[Taglen = 128\]' 3 > "$out/cavp_gcmEncryptExtIV${k}_iv96_tag128.rsp"
  pick "$tmp/gcm/gcmDecrypt$k.rsp" 'IVlen = 96\].*\[PTlen = (0|128|256|408)\].*\[AADlen = (0|128|160|720)\].*\[Taglen = 128\]' 5 > "$out/cavp_gcmDecrypt${k}_iv96_tag128.rsp"
done
pick "$tmp/ecdsa/SigVer.rsp" '\[P-256,SHA-256\]' 0 > "$out/cavp_ecdsa_SigVer_P256_SHA256.rsp"
pick "$tmp/ecdsa/SigGen.rsp" '\[P-256,SHA-256\]' 0 > "$out/cavp_ecdsa_SigGen_P256_SHA256.rsp"
pick "$tmp/ecdsa/KeyPair.rsp" '\[P-256\]' 0 > "$out/cavp_ecdsa_KeyPair_P256.rsp"
pick "$tmp/ecdh/KAS_ECC_CDH_PrimitiveTest.txt" '\[P-256\]' 0 > "$out/cavp_ecdh_P256.rsp"

# ---------------------------------------------------------------- RFC test vectors
# Transcribed by program from the RFC texts into one .rsp-style file: each record names
# its RFC section; values are hex exactly as printed there.
R=https://www.rfc-editor.org/rfc
get $R/rfc8439.txt 25bef70fbf7a07ff45c2fe4cb7c6ce954eac687413d8610603268b4e4415324c rfc8439.txt
get $R/rfc7748.txt 279ca0ecc5e92e2962e27b846986aeb74729d9dd34bd4a04a362f80dcb596ad3 rfc7748.txt
get $R/rfc8032.txt ed63657ff389301282b169b0abde9b5dd2c7e4d524fdfa5da6ff3094fc93c4c3 rfc8032.txt
get $R/rfc5869.txt 7a40eb3835b35fc947eb12a2ed614db079d43b26e50dbc537c31fba16397089c rfc5869.txt
get $R/rfc4231.txt 72178527ce93500e730bc8eb182b857e583096d652b64ece0879c52ba1df973b rfc4231.txt
# block FILE LINE: the hex printed after line LINE: an RFC hexdump ("  016  a4 ad ..."), a
# colon list ("1a:e1:0b:..."), or lines of bare hex; it ends at the first other line
block() {
  awk -v s="$2" '
    NR <= s { next }
    /^ *[0-9][0-9][0-9]  [0-9a-f][0-9a-f]( |$)/ { go = 1; for (i = 2; i <= 17 && i <= NF; i++) { if ($i !~ /^[0-9a-f][0-9a-f]$/) break; printf "%s", $i }; next }
    /^ *[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])+:? *$/ { go = 1; t = $1; gsub(":", "", t); printf "%s", t; next }
    /^ *[0-9a-f]+ *$/ && length($1) % 2 == 0 { go = 1; printf "%s", $1; next }
    /^ *$/ && !go { next }
    { exit }' "$tmp/$1"
}
# fields FILE START END SECTION-REGEX: "Name = value" fields of RFC 5869 / 4231 test cases
# (values may continue on deeper-indented lines; "0x" and "(n octets)" comments dropped)
fields() {
  awk -v a="$2" -v b="$3" -v sre="$4" '
    function flush() { if (k != "") print k " = " v; k = "" }
    NR < a || NR > b { next }
    $0 ~ sre { flush(); print ""; print "[" $0 "]"; next }
    /\[Page [0-9]+\]$/ || /^RFC [0-9]+ / || /^\f/ { next }
    /^   [A-Za-z][A-Za-z0-9-]*( [A-Za-z0-9-]+)* *= / {
      flush(); split($0, p, "="); k = p[1]; gsub(/^ +| +$/, "", k)
      t = p[2]; sub(/^ +/, "", t); split(t, w, " "); v = w[1]; sub(/^0x/, "", v); if (v ~ /^\(/) v = ""; next }
    /^   Key +[0-9a-f]+ *$/ { flush(); k = "Key"; v = $2; next }  # RFC 4231 4.4 prints "Key" without "="
    k != "" && /^          +[0-9a-f]+( |$)/ { split($0, w, " "); v = v w[1]; next }
    /^ *$/ { next }
    { flush() }
    END { flush() }' "$tmp/$1"
}
rfc=$out/rfc.rsp
{
  echo "# RFC test vectors (scripts/fetch-crypto-vectors.sh): RFC 8439 2.8.2 and A.5, RFC 7748 5.2 and 6.1,"
  echo "# RFC 8032 7.1 (TEST 1, 2, 3, SHA(abc)), RFC 5869 A.1-A.3, RFC 4231 4.2-4.8"
  echo; echo "[RFC 8439 2.8.2 AEAD_CHACHA20_POLY1305]"
  echo "PT = $(block rfc8439.txt 1263)"; echo "AAD = $(block rfc8439.txt 1273)"; echo "Key = $(block rfc8439.txt 1276)"
  echo "Nonce = $(block rfc8439.txt 1283)$(block rfc8439.txt 1280)"
  echo "CT = $(block rfc8439.txt 1324)"; echo "Tag = $(block rfc8439.txt 1366)"
  echo; echo "[RFC 8439 A.5 AEAD decryption]"
  echo "Key = $(block rfc8439.txt 2359)"; echo "CT = $(block rfc8439.txt 2363)"; echo "Nonce = $(block rfc8439.txt 2382)"
  echo "AAD = $(block rfc8439.txt 2385)"; echo "Tag = $(block rfc8439.txt 2388)"; echo "PT = $(block rfc8439.txt 2478)"
  for l in 577 590; do
    echo; echo "[RFC 7748 5.2 X25519]"
    echo "Scalar = $(block rfc7748.txt $l)"; echo "U = $(block rfc7748.txt $((l + 5)))"; echo "Out = $(block rfc7748.txt $((l + 10)))"
  done
  echo; echo "[RFC 7748 5.2 X25519 iterated]"
  echo "Iter1 = $(block rfc7748.txt 695)"; echo "Iter1000 = $(block rfc7748.txt 697)"
  echo; echo "[RFC 7748 6.1 X25519 Diffie-Hellman]"
  echo "A = $(block rfc7748.txt 768)"; echo "APub = $(block rfc7748.txt 770)"; echo "B = $(block rfc7748.txt 772)"
  echo "BPub = $(block rfc7748.txt 774)"; echo "K = $(block rfc7748.txt 776)"
  for l in 1306 1327 1356 1479; do
    echo; echo "[RFC 8032 7.1 Ed25519]"
    echo "Secret = $(block rfc8032.txt $l)"; echo "Public = $(block rfc8032.txt $((l + 4)))"
    m=$(awk -v s="$l" 'NR > s && /MESSAGE \(length/ { print NR; exit }' "$tmp/rfc8032.txt")
    g=$(awk -v s="$l" 'NR > s && /SIGNATURE:/ { print NR; exit }' "$tmp/rfc8032.txt")
    echo "Msg = $(block rfc8032.txt "$m")"; echo "Sig = $(block rfc8032.txt "$g")"
  done
  fields rfc5869.txt 516 622 '^A\.[1-3]\.  Test Case'
  fields rfc4231.txt 175 400 '^4\.[2-8]\.  Test Case'
} > "$rfc"
(cd "$out" && LC_ALL=C sha256sum wycheproof_* cavp_* rfc.rsp) > "$tmp/sums"
echo "vectors in $out:"; ls -la "$out" | tail -n +2
