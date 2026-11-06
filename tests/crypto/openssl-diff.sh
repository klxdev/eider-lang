#!/bin/sh
# Differential test against the system `openssl` command, in both directions, for one backend:
#   openssl signs -> Eider (this backend) verifies;  Eider signs -> openssl verifies;
#   ECDH P-384/P-256: both sides derive the same secret.
# Fresh keys on every run (RSA 2048, 3072, 4096, 2048 with e = 3, P-256, P-384).
#
#   sh tests/crypto/openssl-diff.sh <backend>        (called by tests/crypto/run.sh)
#
# Output: one `ok` / `FAIL` / `skip` line; exit 1 on a failure. `skip` (exit 0) when there is
# no openssl command.
cd "$(dirname "$0")/../.." || exit 1
b=${1:-awslc}
command -v openssl >/dev/null 2>&1 || { echo "skip crypto openssl-diff ($b): no openssl command"; exit 0; }
d=target/crypto/test/diff
keys=target/crypto/test/diff-keys
mkdir -p "$d" "$keys"
hex() { od -An -v -tx1 "$1" | tr -d ' \n'; }

# keys are made once per run of run.sh (the first backend) and shared
if [ ! -f "$keys/done" ] || [ -n "$(find "$keys/done" -mmin +30 2>/dev/null)" ]; then
  rm -rf "$keys"; mkdir -p "$keys"
  rsa() { # name bits [exponent]
    if [ -n "${3:-}" ]; then openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:$2 -pkeyopt rsa_keygen_pubexp:$3 -out "$keys/$1.pem" 2>/dev/null
    else openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:$2 -out "$keys/$1.pem" 2>/dev/null; fi
    openssl pkcs8 -topk8 -nocrypt -in "$keys/$1.pem" -outform DER -out "$keys/$1.pkcs8"
    openssl pkey -in "$keys/$1.pem" -pubout -outform DER -out "$keys/$1.spki"
    openssl pkey -in "$keys/$1.pem" -pubout -out "$keys/$1.pub.pem"
  }
  ec() { # name curve
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:$2 -pkeyopt ec_param_enc:named_curve -out "$keys/$1.pem" 2>/dev/null
    openssl ec -in "$keys/$1.pem" -outform DER -out "$keys/$1.sec1" 2>/dev/null
    openssl pkey -in "$keys/$1.pem" -pubout -outform DER -out "$keys/$1.spki"
    openssl pkey -in "$keys/$1.pem" -pubout -out "$keys/$1.pub.pem"
  }
  rsa rsa2048 2048; rsa rsa3072 3072; rsa rsa4096 4096; rsa rsa2048e3 2048 3
  ec p256 prime256v1; ec p256b prime256v1; ec p384 secp384r1; ec p384b secp384r1
  printf 'eider differential test message, %s\n' "$(date +%s)" > "$keys/msg.bin"
  touch "$keys/done"
fi

# the plan: "<n> <key> <scheme> <hash> <salt>"
rm -rf "$d"; mkdir -p "$d"
cp "$keys"/* "$d"/ 2>/dev/null
n=0
plan="$d/plan.txt"; : > "$plan"
add() { n=$((n + 1)); echo "$n $1 $2 $3 $4" >> "$plan"; }
for h in sha256 sha384 sha512; do add rsa2048 pkcs1 $h 0; done
add rsa3072 pkcs1 sha256 0; add rsa4096 pkcs1 sha384 0; add rsa2048e3 pkcs1 sha256 0
add rsa2048 pss sha256 32; add rsa2048 pss sha384 48; add rsa2048 pss sha512 64
add rsa2048 pss sha256 0; add rsa2048 pss sha256 20; add rsa2048 pss sha512 32
add rsa3072 pss sha384 48; add rsa4096 pss sha256 32; add rsa2048e3 pss sha256 32
for h in sha256 sha384 sha512; do add p256 ecdsa $h 0; add p384 ecdsa $h 0; done

# openssl signs
while read -r i key sc h salt; do
  case $sc in
    pkcs1|ecdsa) openssl dgst -$h -sign "$d/$key.pem" -out "$d/$i.openssl.sig" "$d/msg.bin" ;;
    pss) openssl dgst -$h -sign "$d/$key.pem" -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:$salt -sigopt rsa_mgf1_md:$h -out "$d/$i.openssl.sig" "$d/msg.bin" ;;
  esac || { echo "FAIL crypto openssl-diff ($b): openssl could not sign plan line $i"; exit 1; }
done < "$plan"

# Eider verifies openssl's, signs its own
if ! PUBKEY_DIFF="$d" EIDER_CACHE=off scripts/ei-crypto --crypto "$b" run tests/crypto/pubkey.ei > "$d/eider.out" 2>&1; then
  echo "FAIL crypto openssl-diff ($b): see $d/eider.out"; grep FAIL "$d/eider.out" | head -5; tail -2 "$d/eider.out"; exit 1
fi
res=$(tail -1 "$d/eider.out" | sed 's/^[a-z ]*: //')

# openssl verifies Eider's
fail=0; nv=0
while read -r i key sc h salt; do
  nv=$((nv + 1))
  case $sc in
    pkcs1|ecdsa) out=$(openssl dgst -$h -verify "$d/$key.pub.pem" -signature "$d/$i.eider.sig" "$d/msg.bin" 2>&1) ;;
    pss) out=$(openssl dgst -$h -verify "$d/$key.pub.pem" -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:$salt -sigopt rsa_mgf1_md:$h -signature "$d/$i.eider.sig" "$d/msg.bin" 2>&1) ;;
  esac
  case $out in *"Verified OK"*) ;; *) echo "FAIL crypto openssl-diff ($b): openssl rejects Eider's $sc/$h signature by $key (plan line $i): $out"; fail=1 ;; esac
done < "$plan"
# ECDH: openssl derives from the other direction
for pair in "p384 p384b" "p256 p256b"; do
  set -- $pair
  mine=$(cat "$d/$1.eider.ecdh")
  theirs=$(openssl pkeyutl -derive -inkey "$d/$2.pem" -peerkey "$d/$1.pub.pem" 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
  if [ "$mine" != "$theirs" ] || [ -z "$mine" ]; then echo "FAIL crypto openssl-diff ($b): ECDH $1/$2 differs: eider $mine, openssl $theirs"; fail=1; fi
done
[ $fail = 0 ] || exit 1
echo "ok   crypto openssl-diff ($b): $(openssl version | cut -d' ' -f1-2): openssl signatures verified by Eider and $nv Eider signatures (RSA PKCS#1, PSS, ECDSA) by openssl, ECDH P-256/P-384 equal ($res)"
