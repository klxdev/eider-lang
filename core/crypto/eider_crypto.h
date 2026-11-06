/* eider_crypto: the crypto half of the core ABI (core/ABI.md, "Crypto"; core/crypto/README.md).
 *
 * One C file, core/crypto/eider_crypto.c, implements these functions once, against the
 * subset of the OpenSSL libcrypto API listed in core/crypto/README.md. Any library that
 * implements that subset is a backend, chosen when the program is linked: AWS-LC (the
 * default, vendored in core/crypto/awslc/), the system's OpenSSL 3, LibreSSL, BoringSSL.
 *
 * The rules are the core's (core/ABI.md): fixed-width types only; no pointer crosses into
 * Eider; inputs arrive in the core's `in` buffer and results leave in `out`. Several inputs
 * are concatenated in `in` in the order given, with the length of every part but the last
 * passed as an argument. Every function:
 *   - returns >= 0 on success (the number of bytes now in `out`, or 1/0 for a check), or
 *     one of the EC_CRYPTO_E* codes below (< 0);
 *   - leaves `out` empty when it fails;
 *   - zeroes `in` before it returns (it may have held a key), and zeroes every temporary
 *     copy of secret material it made (OPENSSL_cleanse).
 * `out` keeps the result (a shared secret, a plaintext) until Eider has copied it; Eider then
 * calls ec_crypto_wipe().
 */
#ifndef EIDER_CRYPTO_H
#define EIDER_CRYPTO_H

#include <stdint.h>

/* status codes (negative; disjoint from the core's -errno range, which stays above -4096) */
#define EC_CRYPTO_EUNSUPPORTED (-5001) /* this backend doesn't provide the algorithm */
#define EC_CRYPTO_ELENGTH (-5002)      /* a key, nonce, tag or argument has the wrong length */
#define EC_CRYPTO_EKEY (-5003)         /* an invalid private key, public key or point */
#define EC_CRYPTO_EAUTH (-5004)        /* AEAD open: the tag does not match */
#define EC_CRYPTO_EBACKEND (-5005)     /* the library reported an error */

/* algorithm ids (ec_crypto_supports, and the `alg`/`hash` arguments) */
#define EC_CRYPTO_SHA256 1
#define EC_CRYPTO_SHA384 2
#define EC_CRYPTO_SHA512 3
#define EC_CRYPTO_SHA3_256 4
#define EC_CRYPTO_SHA3_384 5
#define EC_CRYPTO_SHA3_512 6
#define EC_CRYPTO_BLAKE2B_256 7
#define EC_CRYPTO_BLAKE2B_512 8
#define EC_CRYPTO_HMAC_SHA256 10
#define EC_CRYPTO_HMAC_SHA384 11
#define EC_CRYPTO_HMAC_SHA512 12
#define EC_CRYPTO_HKDF_SHA256 13
#define EC_CRYPTO_HKDF_SHA384 14
#define EC_CRYPTO_HKDF_SHA512 15
#define EC_CRYPTO_AES_128_GCM 20
#define EC_CRYPTO_AES_256_GCM 21
#define EC_CRYPTO_CHACHA20_POLY1305 22
#define EC_CRYPTO_X25519 30
#define EC_CRYPTO_ED25519 31
#define EC_CRYPTO_ECDSA_P256_SHA256 32
#define EC_CRYPTO_ECDH_P256 33
#define EC_CRYPTO_ECDSA_P256_SHA384 34
#define EC_CRYPTO_ECDSA_P384_SHA384 35
#define EC_CRYPTO_ECDH_P384 36
#define EC_CRYPTO_RSA_PKCS1_SHA256 37 /* RSA verify and sign, PKCS#1 v1.5 (the SHA-384/512 forms are the same code) */
#define EC_CRYPTO_RSA_PSS_SHA256 38   /* RSASSA-PSS with MGF1 of the same hash */
#define EC_CRYPTO_RANDOM 40

/* curves (ec_crypto_ec_*) */
#define EC_CRYPTO_CURVE_P256 1
#define EC_CRYPTO_CURVE_P384 2

/* RSA signature schemes (ec_crypto_rsa_*) */
#define EC_CRYPTO_RSA_PKCS1 1
#define EC_CRYPTO_RSA_PSS 2

/* key kinds returned by ec_crypto_spki_parse and ec_crypto_priv_parse */
#define EC_CRYPTO_KEY_RSA 1
#define EC_CRYPTO_KEY_P256 2
#define EC_CRYPTO_KEY_P384 3

/* backend families (ec_crypto_backend) */
#define EC_CRYPTO_OPENSSL 1
#define EC_CRYPTO_AWSLC 2
#define EC_CRYPTO_BORINGSSL 3
#define EC_CRYPTO_LIBRESSL 4

/* ---- the provider */
int32_t ec_crypto_backend(void);           /* one of the backend families above */
int64_t ec_crypto_provider(void);          /* out = the library's version text, e.g. "OpenSSL 3.5.8 ..." */
int32_t ec_crypto_supports(int32_t alg);   /* 1 if this backend provides `alg` (it ran it once), else 0 */
void ec_crypto_wipe(void);                 /* zero and empty `in` and `out` */

/* ---- randomness: out = n bytes from the library's CSPRNG (RAND_bytes; seeded by the OS), n <= 1 MiB */
int64_t ec_crypto_random(int64_t n);

/* ---- hashing: in = message; out = digest (SHA-*, BLAKE2b-*) */
int64_t ec_crypto_hash(int32_t alg);

/* ---- MAC and KDF. `hash` is EC_CRYPTO_SHA256, _SHA384 or _SHA512. */
int64_t ec_crypto_hmac(int32_t hash, int64_t key_len);             /* in = key, message; out = tag */
int64_t ec_crypto_hkdf_extract(int32_t hash, int64_t salt_len);    /* in = salt, ikm; out = PRK (RFC 5869) */
int64_t ec_crypto_hkdf_expand(int32_t hash, int64_t prk_len, int64_t len); /* in = PRK, info; out = len bytes */

/* ---- AEAD (EC_CRYPTO_AES_128_GCM, _AES_256_GCM, _CHACHA20_POLY1305): 16-byte tags,
   12-byte nonces (the only size every backend accepts for all three), explicit nonce and
   associated data. */
int64_t ec_crypto_aead_seal(int32_t alg, int64_t key_len, int64_t nonce_len, int64_t aad_len);
/*   in = key, nonce, aad, plaintext; out = ciphertext || tag */
int64_t ec_crypto_aead_open(int32_t alg, int64_t key_len, int64_t nonce_len, int64_t aad_len);
/*   in = key, nonce, aad, ciphertext || tag; out = plaintext, or EC_CRYPTO_EAUTH and nothing */

/* ---- X25519 (RFC 7748): 32-byte scalars and u-coordinates */
int64_t ec_crypto_x25519_public(void);     /* in = private; out = public */
int64_t ec_crypto_x25519(void);            /* in = private, peer public; out = shared secret (EKEY if all zero) */

/* ---- Ed25519 (RFC 8032, pure): 32-byte seed as the private key, 32-byte public, 64-byte signature */
int64_t ec_crypto_ed25519_public(void);    /* in = seed; out = public */
int64_t ec_crypto_ed25519_sign(void);      /* in = seed, message; out = signature */
int64_t ec_crypto_ed25519_verify(void);    /* in = public, signature, message; 1 valid, 0 not */

/* ---- P-256: 32-byte big-endian private scalar, 65-byte uncompressed public (04 || x || y),
   ECDSA signatures DER-encoded (ECDSA-Sig-Value, as TLS and X.509 carry them), SHA-256. */
int64_t ec_crypto_p256_public(void);               /* in = private; out = public (EKEY unless 0 < d < n) */
int64_t ec_crypto_p256_sign(void);                 /* in = private, message; out = DER signature (random k) */
int64_t ec_crypto_p256_verify(int64_t sig_len);    /* in = public, signature, message; 1 valid, 0 not */
int64_t ec_crypto_p256_ecdh(void);                 /* in = private, peer public; out = x-coordinate (32) */

/* ---- ECDSA and ECDH on P-256 (curve 1) and P-384 (curve 2). Private key: big-endian scalar of 32 or
   48 bytes; public key: uncompressed point 04 || x || y (65 or 97 bytes); signature: DER
   ECDSA-Sig-Value. `hash` is EC_CRYPTO_SHA256, _SHA384 or _SHA512 with either curve; k is random
   (RAND_bytes through the library). The p256 functions above are these with curve 1 and SHA-256. */
int64_t ec_crypto_ec_public(int32_t curve);                              /* in = private; out = public (EKEY unless 0 < d < n) */
int64_t ec_crypto_ec_sign(int32_t curve, int32_t hash);                  /* in = private, message; out = DER signature */
int64_t ec_crypto_ec_verify(int32_t curve, int32_t hash, int64_t sig_len); /* in = public, signature, message; 1 valid, 0 not */
int64_t ec_crypto_ec_ecdh(int32_t curve);                                /* in = private, peer public; out = x-coordinate */

/* ---- RSA (PKCS#1 v1.5 and RSASSA-PSS, hash EC_CRYPTO_SHA256/384/512, PSS with MGF1 of the same hash).
   A public key is a blob n_len (4 bytes big endian) || n || e (unsigned big endian); a private key is
   DER (PKCS#8 or PKCS#1). Key policy, the same on every backend: 2048..8192 bits, odd modulus, odd e
   with 3 <= e < 2^33 and e < n. Verification takes the message (hashed inside) and a signature of exactly
   the modulus size; a key outside the policy is EKEY (the package says "not valid"). */
int64_t ec_crypto_rsa_verify(int32_t scheme, int32_t hash, int64_t salt_len, int64_t key_len, int64_t sig_len);
/*   in = key blob, signature, message; 1 valid, 0 not. salt_len: the PSS salt length that must be present (ignored for PKCS#1) */
int64_t ec_crypto_rsa_sign(int32_t scheme, int32_t hash, int64_t salt_len, int64_t key_len);
/*   in = private key DER, message; out = signature. PSS uses a random salt of salt_len bytes */

/* ---- key import. in = DER SubjectPublicKeyInfo; out = kind || key: for EC_CRYPTO_KEY_RSA the RSA
   public blob, for _P256/_P384 the uncompressed point. EKEY if it is anything else (other curves,
   explicit curve parameters, RSASSA-PSS-restricted keys, Ed25519), outside the RSA policy, or has
   trailing bytes. */
int64_t ec_crypto_spki_parse(void);
/*   in = DER private key (PKCS#8, PKCS#1 RSAPrivateKey or SEC1 ECPrivateKey); out = kind || the RSA
     public blob (the private key stays in the caller's DER), or kind || the 32/48-byte scalar */
int64_t ec_crypto_priv_parse(void);

/* ---- constant time: in = a, b (len bytes each); 1 if equal. Time depends only on len. */
int64_t ec_crypto_ct_equal(int64_t len);

#endif
