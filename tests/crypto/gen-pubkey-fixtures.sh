#!/bin/sh
# Re-create tests/crypto/vectors/openssl_pubkey.rsp: RSA and EC keys and signatures made by the
# system `openssl` command (a second implementation, not Eider's), for tests/crypto/pubkey.ei.
# The result is committed; run this only to change the selection. Needs openssl 3.
#
# Keys: RSA 2048 (PKCS#8, PKCS#1, SPKI), 3072, 4096, 2048 with e = 3, 1024 (must be refused),
# P-256 and P-384 (PKCS#8, SEC1, SPKI). Signatures: PKCS#1 v1.5 (deterministic: Eider must
# produce the same bytes), PSS with several salt lengths and ECDSA with SHA-256/384/512.
set -eu
cd "$(dirname "$0")/../.."
out=tests/crypto/vectors/openssl_pubkey.rsp
tmp=target/crypto/fixtures-gen
rm -rf "$tmp"; mkdir -p "$tmp"
hex() { od -An -v -tx1 "$1" | tr -d ' \n'; }

rsa() { # name bits [exponent]
  if [ -n "${3:-}" ]; then openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:$2 -pkeyopt rsa_keygen_pubexp:$3 -out "$tmp/$1.pem" 2>/dev/null
  else openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:$2 -out "$tmp/$1.pem" 2>/dev/null; fi
  openssl pkcs8 -topk8 -nocrypt -in "$tmp/$1.pem" -outform DER -out "$tmp/$1.pkcs8"
  openssl rsa -in "$tmp/$1.pem" -traditional -outform DER -out "$tmp/$1.pkcs1" 2>/dev/null
  openssl pkey -in "$tmp/$1.pem" -pubout -outform DER -out "$tmp/$1.spki"
  printf '\nKind = key\nName = %s\nPkcs8 = %s\nPkcs1 = %s\nSpki = %s\n' "$1" "$(hex "$tmp/$1.pkcs8")" "$(hex "$tmp/$1.pkcs1")" "$(hex "$tmp/$1.spki")"
}
ec() { # name curve
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:$2 -pkeyopt ec_param_enc:named_curve -out "$tmp/$1.pem" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$tmp/$1.pem" -outform DER -out "$tmp/$1.pkcs8"
  openssl ec -in "$tmp/$1.pem" -outform DER -out "$tmp/$1.sec1" 2>/dev/null
  openssl pkey -in "$tmp/$1.pem" -pubout -outform DER -out "$tmp/$1.spki"
  printf '\nKind = key\nName = %s\nPkcs8 = %s\nSec1 = %s\nSpki = %s\n' "$1" "$(hex "$tmp/$1.pkcs8")" "$(hex "$tmp/$1.sec1")" "$(hex "$tmp/$1.spki")"
}
msg() { printf 'eider crypto 0.7.6 public-key fixture message %s' "$1" > "$tmp/m$1"; }

sig() { # key scheme hash salt msgid [opts...]
  k=$1; sc=$2; h=$3; salt=$4; id=$5
  msg "$id"
  case $sc in
    pkcs1) openssl dgst -$h -sign "$tmp/$k.pem" -out "$tmp/s" "$tmp/m$id" ;;
    pss) openssl dgst -$h -sign "$tmp/$k.pem" -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:$salt -sigopt rsa_mgf1_md:$h -out "$tmp/s" "$tmp/m$id" ;;
    ecdsa) openssl dgst -$h -sign "$tmp/$k.pem" -out "$tmp/s" "$tmp/m$id" ;;
  esac
  printf '\nKind = sig\nName = %s\nScheme = %s\nHash = %s\nSalt = %s\nMsg = %s\nSig = %s\n' "$k" "$sc" "$h" "$salt" "$(hex "$tmp/m$id")" "$(hex "$tmp/s")"
}

{
  echo "# Keys and signatures made by the system openssl ($(openssl version | cut -d' ' -f1-2)); tests/crypto/gen-pubkey-fixtures.sh"
  rsa rsa2048 2048
  rsa rsa3072 3072
  rsa rsa4096 4096
  rsa rsa2048e3 2048 3
  rsa rsa1024 1024
  ec p256 prime256v1
  ec p384 secp384r1
  for h in sha256 sha384 sha512; do sig rsa2048 pkcs1 $h 0 1; done
  sig rsa3072 pkcs1 sha256 0 2
  sig rsa4096 pkcs1 sha384 0 3
  sig rsa2048e3 pkcs1 sha256 0 4
  sig rsa2048 pss sha256 32 5
  sig rsa2048 pss sha384 48 6
  sig rsa2048 pss sha512 64 7
  sig rsa2048 pss sha256 0 8
  sig rsa2048 pss sha256 20 9
  sig rsa3072 pss sha384 48 10
  sig rsa4096 pss sha256 32 11
  sig rsa2048e3 pss sha256 32 12
  for h in sha256 sha384 sha512; do sig p384 ecdsa $h 0 13; sig p256 ecdsa $h 0 14; done
} > "$out"
echo "wrote $out"
