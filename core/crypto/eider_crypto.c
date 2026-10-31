// eider_crypto: the core's crypto operations (eider_crypto.h; contract in core/ABI.md,
// "Crypto", and core/crypto/README.md), written once against the OpenSSL libcrypto API.
//
// The backend is whichever libcrypto this file is compiled and linked against: AWS-LC (the
// default, core/crypto/awslc/), OpenSSL 3, LibreSSL or BoringSSL. Only the subset of the API
// listed in core/crypto/README.md is used, and every function used there exists in all four
// unless an #if below says otherwise (each one is listed in the README too).
//
// Like eider_core.c this is glue, not crypto: each operation unpacks `in`, makes one call
// sequence into libcrypto and packs `out`. No primitive is implemented here.
//
// Portability: C11 and the libcrypto headers; no OS calls.

/* OpenSSL 3 marks the EC_KEY functions deprecated. They are the only P-256 key import that
   all four libraries share (OpenSSL 3's replacement, EVP_PKEY_fromdata, is OpenSSL-only),
   so keep them visible without warnings. Must come before any OpenSSL header. */
#define OPENSSL_SUPPRESS_DEPRECATED 1

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/kdf.h>
#include <openssl/obj_mac.h>
#include <openssl/rand.h>

#include "eider_core_ext.h"
#include "eider_crypto.h"

#if defined(OPENSSL_IS_AWSLC)
#define FAMILY EC_CRYPTO_AWSLC
#define FAMILY_NAME "aws-lc"
#elif defined(OPENSSL_IS_BORINGSSL)
#define FAMILY EC_CRYPTO_BORINGSSL
#define FAMILY_NAME "boringssl"
#elif defined(LIBRESSL_VERSION_NUMBER)
#define FAMILY EC_CRYPTO_LIBRESSL
#define FAMILY_NAME "libressl"
#elif OPENSSL_VERSION_NUMBER >= 0x30000000L
#define FAMILY EC_CRYPTO_OPENSSL
#define FAMILY_NAME "openssl"
#else
#error "eider_crypto: needs OpenSSL >= 3.0, AWS-LC, BoringSSL or LibreSSL"
#endif

/* Which optional digests the library has (README, "Coverage"). */
#if FAMILY == EC_CRYPTO_AWSLC || FAMILY == EC_CRYPTO_BORINGSSL
#define HAVE_BLAKE2B_256 1 /* EVP_blake2b256 */
#elif FAMILY == EC_CRYPTO_OPENSSL
#define HAVE_BLAKE2B_512 1 /* EVP_blake2b512 */
#endif
#if FAMILY != EC_CRYPTO_BORINGSSL
#define HAVE_SHA3 1 /* EVP_sha3_256/384/512 */
#endif
/* BoringSSL has ChaCha20-Poly1305 only as an EVP_AEAD, not as an EVP_CIPHER. EIDER_CRYPTO_EVP_AEAD
   forces that path on AWS-LC too, so it can be tested there. */
#if FAMILY == EC_CRYPTO_BORINGSSL || defined(EIDER_CRYPTO_EVP_AEAD)
#include <openssl/aead.h>
#define USE_EVP_AEAD_CHACHA 1
#endif

/* Eider binds externs by raw symbol name; pin it where the platform decorates C names
   (Mach-O), as eider_core.c does. */
#if defined(__APPLE__)
#define EC_SYM(n) __asm__(#n)
#else
#define EC_SYM(n)
#endif
#define EC_FN(ret, name, params) ret name params EC_SYM(name); ret name params

/* Inputs larger than this are refused (ELENGTH): the EVP_CIPHER and HMAC key interfaces
   take `int` lengths. */
#define MAX_INPUT ((size_t)INT_MAX - 64)

/* ---------------------------------------------------------------- helpers */

/* End of every operation: zero `in` (it may have held a key); on failure empty `out`. */
static int64_t done(int64_t r) {
  ec_ext_in_wipe();
  if (r < 0) {
    (void)ec_ext_out(0);
    ERR_clear_error();
  }
  return r;
}

/* Split `in` into parts of the given lengths; the last part is the rest. */
static int split(const unsigned char **base, size_t *total, const int64_t *lens, int n, const unsigned char **parts, size_t *last) {
  size_t len;
  const unsigned char *p = ec_ext_in(&len);
  if (len > MAX_INPUT) return 0;
  size_t at = 0;
  for (int i = 0; i < n; i++) {
    if (lens[i] < 0 || (uint64_t)lens[i] > len - at) return 0;
    parts[i] = p + at;
    at += (size_t)lens[i];
  }
  parts[n] = p + at;
  *last = len - at;
  if (base) *base = p;
  if (total) *total = len;
  return 1;
}

static const EVP_MD *md_for(int32_t alg) {
  switch (alg) {
  case EC_CRYPTO_SHA256: return EVP_sha256();
  case EC_CRYPTO_SHA384: return EVP_sha384();
  case EC_CRYPTO_SHA512: return EVP_sha512();
#if defined(HAVE_SHA3)
  case EC_CRYPTO_SHA3_256: return EVP_sha3_256();
  case EC_CRYPTO_SHA3_384: return EVP_sha3_384();
  case EC_CRYPTO_SHA3_512: return EVP_sha3_512();
#endif
#if defined(HAVE_BLAKE2B_256)
  case EC_CRYPTO_BLAKE2B_256: return EVP_blake2b256();
#endif
#if defined(HAVE_BLAKE2B_512)
  case EC_CRYPTO_BLAKE2B_512: return EVP_blake2b512();
#endif
  default: return NULL;
  }
}

/* HMAC and HKDF take only the SHA-2 hashes. */
static const EVP_MD *mac_md(int32_t hash) {
  return hash == EC_CRYPTO_SHA256 || hash == EC_CRYPTO_SHA384 || hash == EC_CRYPTO_SHA512 ? md_for(hash) : NULL;
}

/* A non-NULL pointer for a possibly empty input (some libraries treat NULL specially). */
static const unsigned char *nz(const unsigned char *p) {
  static const unsigned char zero[1] = {0};
  return p ? p : zero;
}

/* ---------------------------------------------------------------- operations on pointers
   (also used by ec_crypto_supports to run each algorithm once) */

static int64_t op_hash(int32_t alg, const unsigned char *m, size_t n, unsigned char *out) {
  const EVP_MD *md = md_for(alg);
  if (!md) return EC_CRYPTO_EUNSUPPORTED;
  unsigned int len = 0;
  if (EVP_Digest(nz(m), n, out, &len, md, NULL) != 1) return EC_CRYPTO_EBACKEND;
  return (int64_t)len;
}

static int64_t op_hmac(int32_t hash, const unsigned char *k, size_t kn, const unsigned char *m, size_t n, unsigned char *out) {
  const EVP_MD *md = mac_md(hash);
  if (!md) return EC_CRYPTO_EUNSUPPORTED;
  unsigned int len = 0;
  if (!HMAC(md, nz(k), (int)kn, nz(m), n, out, &len)) return EC_CRYPTO_EBACKEND;
  return (int64_t)len;
}

/* HKDF through the EVP_PKEY_HKDF interface: mode extract-only (salt, ikm -> PRK) or
   expand-only (PRK, info -> okm). */
static int64_t op_hkdf(int extract, int32_t hash, const unsigned char *a, size_t an, const unsigned char *b, size_t bn, unsigned char *out, size_t outn) {
  const EVP_MD *md = mac_md(hash);
  if (!md) return EC_CRYPTO_EUNSUPPORTED;
  size_t hl = (size_t)EVP_MD_size(md);
  if (extract) outn = hl;
  else if (outn == 0 || outn > 255 * hl || an < hl) return EC_CRYPTO_ELENGTH;
  int64_t r = EC_CRYPTO_EBACKEND;
  EVP_PKEY_CTX *c = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, NULL);
  if (!c) return r;
  size_t got = outn;
  if (EVP_PKEY_derive_init(c) == 1 &&
      EVP_PKEY_CTX_hkdf_mode(c, extract ? EVP_PKEY_HKDEF_MODE_EXTRACT_ONLY : EVP_PKEY_HKDEF_MODE_EXPAND_ONLY) == 1 &&
      EVP_PKEY_CTX_set_hkdf_md(c, md) == 1) {
    int ok;
    if (extract) /* a = salt, b = ikm */
      ok = EVP_PKEY_CTX_set1_hkdf_salt(c, nz(a), (int)an) == 1 && EVP_PKEY_CTX_set1_hkdf_key(c, nz(b), (int)bn) == 1;
    else /* a = PRK, b = info */
      ok = EVP_PKEY_CTX_set1_hkdf_key(c, nz(a), (int)an) == 1 && (bn == 0 || EVP_PKEY_CTX_add1_hkdf_info(c, b, (int)bn) == 1);
    if (ok && EVP_PKEY_derive(c, out, &got) == 1 && got == outn) r = (int64_t)outn;
  }
  EVP_PKEY_CTX_free(c);
  return r;
}

static const EVP_CIPHER *aead_cipher(int32_t alg, size_t *key_len) {
  switch (alg) {
  case EC_CRYPTO_AES_128_GCM: *key_len = 16; return EVP_aes_128_gcm();
  case EC_CRYPTO_AES_256_GCM: *key_len = 32; return EVP_aes_256_gcm();
#if !defined(USE_EVP_AEAD_CHACHA)
  case EC_CRYPTO_CHACHA20_POLY1305: *key_len = 32; return EVP_chacha20_poly1305();
#endif
  default: return NULL;
  }
}

#define TAG_LEN 16
#define NONCE_LEN 12

/* seal: out = ct || tag (n + 16 bytes). open: in = ct || tag, out = pt (n - 16 bytes); on
   a tag mismatch the partial plaintext is zeroed and EAUTH returned. */
static int64_t op_aead(int seal, int32_t alg, const unsigned char *key, size_t kn, const unsigned char *nonce, size_t nn,
                       const unsigned char *aad, size_t an, const unsigned char *m, size_t n, unsigned char *out) {
  if (!seal && n < TAG_LEN) return EC_CRYPTO_ELENGTH;
  size_t body = seal ? n : n - TAG_LEN;
#if defined(USE_EVP_AEAD_CHACHA)
  if (alg == EC_CRYPTO_CHACHA20_POLY1305) {
    if (kn != 32 || nn != NONCE_LEN) return EC_CRYPTO_ELENGTH;
    EVP_AEAD_CTX *a = EVP_AEAD_CTX_new(EVP_aead_chacha20_poly1305(), key, kn, TAG_LEN);
    if (!a) return EC_CRYPTO_EBACKEND;
    size_t got = 0;
    int ok = seal ? EVP_AEAD_CTX_seal(a, out, &got, n + TAG_LEN, nonce, nn, nz(m), n, nz(aad), an)
                  : EVP_AEAD_CTX_open(a, out, &got, body, nonce, nn, m, n, nz(aad), an);
    EVP_AEAD_CTX_free(a);
    if (ok == 1) return (int64_t)got;
    OPENSSL_cleanse(out, body);
    return seal ? EC_CRYPTO_EBACKEND : EC_CRYPTO_EAUTH;
  }
#endif
  size_t want = 0;
  const EVP_CIPHER *ci = aead_cipher(alg, &want);
  if (!ci) return EC_CRYPTO_EUNSUPPORTED;
  if (kn != want || nn != NONCE_LEN) return EC_CRYPTO_ELENGTH;
  EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
  if (!c) return EC_CRYPTO_EBACKEND;
  int64_t r = EC_CRYPTO_EBACKEND;
  int len = 0, fin = 0;
  if (seal) {
    if (EVP_EncryptInit_ex(c, ci, NULL, key, nonce) == 1 &&
        (an == 0 || EVP_EncryptUpdate(c, NULL, &len, aad, (int)an) == 1) &&
        (body == 0 || EVP_EncryptUpdate(c, out, &len, m, (int)body) == 1) &&
        EVP_EncryptFinal_ex(c, out + (body ? (size_t)len : 0), &fin) == 1 &&
        EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_GET_TAG, TAG_LEN, out + body) == 1)
      r = (int64_t)(body + TAG_LEN);
  } else {
    /* the tag is set before any ciphertext; DecryptFinal checks it */
    unsigned char tag[TAG_LEN];
    memcpy(tag, m + body, TAG_LEN);
    if (EVP_DecryptInit_ex(c, ci, NULL, key, nonce) == 1 &&
        EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_SET_TAG, TAG_LEN, tag) == 1 &&
        (an == 0 || EVP_DecryptUpdate(c, NULL, &len, aad, (int)an) == 1) &&
        (body == 0 || EVP_DecryptUpdate(c, out, &len, m, (int)body) == 1)) {
      if (EVP_DecryptFinal_ex(c, out + (body ? (size_t)len : 0), &fin) == 1) r = (int64_t)body;
      else r = EC_CRYPTO_EAUTH;
    }
    if (r < 0) OPENSSL_cleanse(out, body);
  }
  EVP_CIPHER_CTX_free(c);
  return r;
}

/* raw 32-byte keys (X25519, Ed25519) */
static EVP_PKEY *raw_key(int type, int priv, const unsigned char *k) {
  return priv ? EVP_PKEY_new_raw_private_key(type, NULL, k, 32) : EVP_PKEY_new_raw_public_key(type, NULL, k, 32);
}

static int64_t op_raw_public(int type, const unsigned char *sk, unsigned char *out) {
  EVP_PKEY *k = raw_key(type, 1, sk);
  if (!k) return EC_CRYPTO_EKEY;
  size_t len = 32;
  int ok = EVP_PKEY_get_raw_public_key(k, out, &len) == 1 && len == 32;
  EVP_PKEY_free(k);
  return ok ? 32 : EC_CRYPTO_EBACKEND;
}

/* key agreement on two EVP_PKEYs (X25519, P-256); out gets `want` bytes */
static int64_t derive(EVP_PKEY *mine, EVP_PKEY *peer, unsigned char *out, size_t want) {
  int64_t r = EC_CRYPTO_EKEY;
  EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(mine, NULL);
  size_t len = want;
  if (c && EVP_PKEY_derive_init(c) == 1 && EVP_PKEY_derive_set_peer(c, peer) == 1 &&
      EVP_PKEY_derive(c, out, &len) == 1 && len == want)
    r = (int64_t)want;
  EVP_PKEY_CTX_free(c);
  return r;
}

static int64_t op_x25519(const unsigned char *sk, const unsigned char *pk, unsigned char *out) {
  static const unsigned char zero[32] = {0};
  EVP_PKEY *a = raw_key(EVP_PKEY_X25519, 1, sk), *b = raw_key(EVP_PKEY_X25519, 0, pk);
  int64_t r = a && b ? derive(a, b, out, 32) : EC_CRYPTO_EKEY;
  EVP_PKEY_free(a);
  EVP_PKEY_free(b);
  /* RFC 7748 section 6.1: an all-zero result means a small-order peer key; refuse it even if
     the library didn't */
  if (r == 32 && CRYPTO_memcmp(out, zero, 32) == 0) r = EC_CRYPTO_EKEY;
  return r;
}

static int64_t op_ed25519_sign(const unsigned char *seed, const unsigned char *m, size_t n, unsigned char *out) {
  EVP_PKEY *k = raw_key(EVP_PKEY_ED25519, 1, seed);
  if (!k) return EC_CRYPTO_EKEY;
  EVP_MD_CTX *c = EVP_MD_CTX_new();
  size_t len = 64;
  int ok = c && EVP_DigestSignInit(c, NULL, NULL, NULL, k) == 1 && EVP_DigestSign(c, out, &len, nz(m), n) == 1 && len == 64;
  EVP_MD_CTX_free(c);
  EVP_PKEY_free(k);
  return ok ? 64 : EC_CRYPTO_EBACKEND;
}

/* 1 valid, 0 not. A public key the library can't decode is "not valid" too, whether the
   library rejects it at import or at verification, so every backend answers alike. */
static int64_t op_ed25519_verify(const unsigned char *pk, const unsigned char *sig, const unsigned char *m, size_t n) {
  EVP_PKEY *k = raw_key(EVP_PKEY_ED25519, 0, pk);
  if (!k) return 0;
  EVP_MD_CTX *c = EVP_MD_CTX_new();
  int ok = c && EVP_DigestVerifyInit(c, NULL, NULL, NULL, k) == 1 && EVP_DigestVerify(c, sig, 64, nz(m), n) == 1;
  EVP_MD_CTX_free(c);
  EVP_PKEY_free(k);
  return ok ? 1 : 0;
}

/* A P-256 EVP_PKEY from a private scalar (the public point is computed) or from an
   uncompressed public point (checked to be on the curve). NULL and *bad = 1 for an invalid
   key; NULL and *bad = 0 if the library failed. */
static EVP_PKEY *p256_key(const unsigned char *d, const unsigned char *pub, int *bad) {
  *bad = 0;
  EVP_PKEY *pk = NULL;
  BIGNUM *bn = NULL, *order = NULL;
  EC_POINT *pt = NULL;
  EC_KEY *k = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
  if (!k) goto out;
  const EC_GROUP *g = EC_KEY_get0_group(k);
  pt = EC_POINT_new(g);
  if (!pt) goto out;
  if (d) {
    bn = BN_bin2bn(d, 32, NULL);
    order = BN_new();
    if (!bn || !order || EC_GROUP_get_order(g, order, NULL) != 1) goto out;
    if (BN_is_zero(bn) || BN_cmp(bn, order) >= 0) { *bad = 1; goto out; }
    if (EC_KEY_set_private_key(k, bn) != 1 || EC_POINT_mul(g, pt, bn, NULL, NULL, NULL) != 1) goto out;
  } else {
    if (pub[0] != 4 || EC_POINT_oct2point(g, pt, pub, 65, NULL) != 1) { *bad = 1; goto out; }
  }
  if (EC_KEY_set_public_key(k, pt) != 1) { *bad = !d; goto out; }
  if (!d && EC_KEY_check_key(k) != 1) { *bad = 1; goto out; }
  pk = EVP_PKEY_new();
  if (pk && EVP_PKEY_set1_EC_KEY(pk, k) != 1) {
    EVP_PKEY_free(pk);
    pk = NULL;
  }
out:
  BN_clear_free(bn);
  BN_free(order);
  EC_POINT_free(pt);
  EC_KEY_free(k);
  return pk;
}

static int64_t op_p256_public(const unsigned char *d, unsigned char *out) {
  int64_t r = EC_CRYPTO_EBACKEND;
  int bad = 0;
  EVP_PKEY *pk = p256_key(d, NULL, &bad);
  if (!pk) return bad ? EC_CRYPTO_EKEY : r;
  const EC_KEY *k = EVP_PKEY_get0_EC_KEY(pk);
  if (k && EC_POINT_point2oct(EC_KEY_get0_group(k), EC_KEY_get0_public_key(k), POINT_CONVERSION_UNCOMPRESSED, out, 65, NULL) == 65) r = 65;
  EVP_PKEY_free(pk);
  return r;
}

#define P256_SIG_MAX 72 /* DER: SEQUENCE { INTEGER r, INTEGER s }, each up to 33 bytes */

static int64_t op_p256_sign(const unsigned char *d, const unsigned char *m, size_t n, unsigned char *out) {
  int bad = 0;
  EVP_PKEY *pk = p256_key(d, NULL, &bad);
  if (!pk) return bad ? EC_CRYPTO_EKEY : EC_CRYPTO_EBACKEND;
  EVP_MD_CTX *c = EVP_MD_CTX_new();
  unsigned char sig[P256_SIG_MAX + 16];
  size_t len = sizeof sig;
  int ok = c && EVP_DigestSignInit(c, NULL, EVP_sha256(), NULL, pk) == 1 && EVP_DigestSign(c, sig, &len, nz(m), n) == 1 && len <= P256_SIG_MAX;
  EVP_MD_CTX_free(c);
  EVP_PKEY_free(pk);
  if (!ok) return EC_CRYPTO_EBACKEND;
  memcpy(out, sig, len);
  return (int64_t)len;
}

static int64_t op_p256_verify(const unsigned char *pub, const unsigned char *sig, size_t sn, const unsigned char *m, size_t n) {
  int bad = 0;
  EVP_PKEY *pk = p256_key(NULL, pub, &bad);
  if (!pk) return bad ? EC_CRYPTO_EKEY : EC_CRYPTO_EBACKEND;
  EVP_MD_CTX *c = EVP_MD_CTX_new();
  int ok = c && sn > 0 && EVP_DigestVerifyInit(c, NULL, EVP_sha256(), NULL, pk) == 1 && EVP_DigestVerify(c, sig, sn, nz(m), n) == 1;
  EVP_MD_CTX_free(c);
  EVP_PKEY_free(pk);
  return ok ? 1 : 0;
}

static int64_t op_p256_ecdh(const unsigned char *d, const unsigned char *pub, unsigned char *out) {
  int bad1 = 0, bad2 = 0;
  EVP_PKEY *a = p256_key(d, NULL, &bad1), *b = p256_key(NULL, pub, &bad2);
  int64_t r = a && b ? derive(a, b, out, 32) : (bad1 || bad2 ? EC_CRYPTO_EKEY : EC_CRYPTO_EBACKEND);
  EVP_PKEY_free(a);
  EVP_PKEY_free(b);
  return r;
}

/* ---------------------------------------------------------------- the ABI */

EC_FN(int32_t, ec_crypto_backend, (void)) { return FAMILY; }

EC_FN(int64_t, ec_crypto_provider, (void)) {
  const char *v = OpenSSL_version(OPENSSL_VERSION);
  size_t a = strlen(FAMILY_NAME), b = strlen(v);
  unsigned char *o = ec_ext_out(a + 2 + b);
  memcpy(o, FAMILY_NAME, a);
  memcpy(o + a, ": ", 2);
  memcpy(o + a + 2, v, b);
  return (int64_t)(a + 2 + b);
}

EC_FN(void, ec_crypto_wipe, (void)) { ec_ext_wipe(); }

/* Run the algorithm once on fixed inputs: a backend "provides" it only if that works (a
   library can be built or configured without an algorithm its headers declare). */
EC_FN(int32_t, ec_crypto_supports, (int32_t alg)) {
  /* 1 is a valid scalar for every curve here and its public key is the base point */
  unsigned char k[32] = {0}, out[256], o2[256], m[1] = {0};
  k[31] = 1;
  int64_t r;
  switch (alg) {
  case EC_CRYPTO_SHA256: case EC_CRYPTO_SHA384: case EC_CRYPTO_SHA512:
  case EC_CRYPTO_SHA3_256: case EC_CRYPTO_SHA3_384: case EC_CRYPTO_SHA3_512:
  case EC_CRYPTO_BLAKE2B_256: case EC_CRYPTO_BLAKE2B_512:
    r = op_hash(alg, m, 1, out); break;
  case EC_CRYPTO_HMAC_SHA256: case EC_CRYPTO_HMAC_SHA384: case EC_CRYPTO_HMAC_SHA512:
    r = op_hmac(EC_CRYPTO_SHA256 + (alg - EC_CRYPTO_HMAC_SHA256), k, 32, m, 1, out); break;
  case EC_CRYPTO_HKDF_SHA256: case EC_CRYPTO_HKDF_SHA384: case EC_CRYPTO_HKDF_SHA512: {
    int32_t h = EC_CRYPTO_SHA256 + (alg - EC_CRYPTO_HKDF_SHA256);
    r = op_hkdf(1, h, k, 32, k, 32, out, 0);
    if (r > 0) r = op_hkdf(0, h, out, (size_t)r, m, 1, o2, 42);
    break;
  }
  case EC_CRYPTO_AES_128_GCM: case EC_CRYPTO_AES_256_GCM: case EC_CRYPTO_CHACHA20_POLY1305: {
    size_t kn = alg == EC_CRYPTO_AES_128_GCM ? 16 : 32;
    r = op_aead(1, alg, k, kn, k, NONCE_LEN, m, 1, m, 1, out);
    if (r > 0) r = op_aead(0, alg, k, kn, k, NONCE_LEN, m, 1, out, (size_t)r, o2);
    break;
  }
  case EC_CRYPTO_X25519:
    r = op_raw_public(EVP_PKEY_X25519, k, out);
    if (r > 0) r = op_x25519(k, out, o2);
    break;
  case EC_CRYPTO_ED25519:
    r = op_raw_public(EVP_PKEY_ED25519, k, out);
    if (r > 0) r = op_ed25519_sign(k, m, 1, o2);
    if (r > 0) r = op_ed25519_verify(out, o2, m, 1) == 1 ? 1 : -1;
    break;
  case EC_CRYPTO_ECDSA_P256_SHA256: {
    r = op_p256_public(k, out);
    if (r > 0) r = op_p256_sign(k, m, 1, o2);
    if (r > 0) r = op_p256_verify(out, o2, (size_t)r, m, 1) == 1 ? 1 : -1;
    break;
  }
  case EC_CRYPTO_ECDH_P256:
    r = op_p256_public(k, out);
    if (r > 0) r = op_p256_ecdh(k, out, o2);
    break;
  case EC_CRYPTO_RANDOM:
    r = RAND_bytes(out, 16) == 1 ? 16 : -1;
    break;
  default:
    r = -1;
  }
  OPENSSL_cleanse(out, sizeof out);
  OPENSSL_cleanse(o2, sizeof o2);
  ERR_clear_error();
  return r > 0 ? 1 : 0;
}

EC_FN(int64_t, ec_crypto_random, (int64_t n)) {
  if (n < 0 || n > (1 << 20)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out((size_t)n);
  if (n > 0 && RAND_bytes(o, (int)n) != 1) return done(EC_CRYPTO_EBACKEND);
  return done(n);
}

EC_FN(int64_t, ec_crypto_hash, (int32_t alg)) {
  const unsigned char *p[1];
  size_t n;
  if (!split(NULL, NULL, NULL, 0, p, &n)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out(EVP_MAX_MD_SIZE);
  int64_t r = op_hash(alg, p[0], n, o);
  if (r >= 0) ec_ext_out_truncate((size_t)r);
  return done(r);
}

EC_FN(int64_t, ec_crypto_hmac, (int32_t hash, int64_t key_len)) {
  const unsigned char *p[2];
  size_t n;
  if (!split(NULL, NULL, &key_len, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out(EVP_MAX_MD_SIZE);
  int64_t r = op_hmac(hash, p[0], (size_t)key_len, p[1], n, o);
  if (r >= 0) ec_ext_out_truncate((size_t)r);
  return done(r);
}

EC_FN(int64_t, ec_crypto_hkdf_extract, (int32_t hash, int64_t salt_len)) {
  const unsigned char *p[2];
  size_t n;
  if (!split(NULL, NULL, &salt_len, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out(EVP_MAX_MD_SIZE);
  int64_t r = op_hkdf(1, hash, p[0], (size_t)salt_len, p[1], n, o, 0);
  if (r >= 0) ec_ext_out_truncate((size_t)r);
  return done(r);
}

EC_FN(int64_t, ec_crypto_hkdf_expand, (int32_t hash, int64_t prk_len, int64_t len)) {
  const unsigned char *p[2];
  size_t n;
  if (len <= 0 || len > 255 * 64 || !split(NULL, NULL, &prk_len, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out((size_t)len);
  return done(op_hkdf(0, hash, p[0], (size_t)prk_len, p[1], n, o, (size_t)len));
}

static int64_t aead(int seal, int32_t alg, int64_t key_len, int64_t nonce_len, int64_t aad_len) {
  const unsigned char *p[4];
  size_t n;
  int64_t lens[3] = {key_len, nonce_len, aad_len};
  if (!split(NULL, NULL, lens, 3, p, &n)) return done(EC_CRYPTO_ELENGTH);
  if (!seal && n < TAG_LEN) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out(seal ? n + TAG_LEN : n - TAG_LEN);
  return done(op_aead(seal, alg, p[0], (size_t)key_len, p[1], (size_t)nonce_len, p[2], (size_t)aad_len, p[3], n, o));
}

EC_FN(int64_t, ec_crypto_aead_seal, (int32_t alg, int64_t key_len, int64_t nonce_len, int64_t aad_len)) {
  return aead(1, alg, key_len, nonce_len, aad_len);
}

EC_FN(int64_t, ec_crypto_aead_open, (int32_t alg, int64_t key_len, int64_t nonce_len, int64_t aad_len)) {
  return aead(0, alg, key_len, nonce_len, aad_len);
}

/* `in` must be exactly the given fixed-size parts, then (if rest) any number of bytes */
static int fixed(const int64_t *lens, int k, int rest, const unsigned char **p, size_t *n) {
  if (!split(NULL, NULL, lens, k, p, n)) return 0;
  return rest || *n == 0;
}

EC_FN(int64_t, ec_crypto_x25519_public, (void)) {
  const unsigned char *p[2];
  size_t n;
  int64_t l[1] = {32};
  if (!fixed(l, 1, 0, p, &n)) return done(EC_CRYPTO_ELENGTH);
  return done(op_raw_public(EVP_PKEY_X25519, p[0], ec_ext_out(32)));
}

EC_FN(int64_t, ec_crypto_x25519, (void)) {
  const unsigned char *p[3];
  size_t n;
  int64_t l[2] = {32, 32};
  if (!fixed(l, 2, 0, p, &n)) return done(EC_CRYPTO_ELENGTH);
  return done(op_x25519(p[0], p[1], ec_ext_out(32)));
}

EC_FN(int64_t, ec_crypto_ed25519_public, (void)) {
  const unsigned char *p[2];
  size_t n;
  int64_t l[1] = {32};
  if (!fixed(l, 1, 0, p, &n)) return done(EC_CRYPTO_ELENGTH);
  return done(op_raw_public(EVP_PKEY_ED25519, p[0], ec_ext_out(32)));
}

EC_FN(int64_t, ec_crypto_ed25519_sign, (void)) {
  const unsigned char *p[2];
  size_t n;
  int64_t l[1] = {32};
  if (!fixed(l, 1, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  return done(op_ed25519_sign(p[0], p[1], n, ec_ext_out(64)));
}

EC_FN(int64_t, ec_crypto_ed25519_verify, (void)) {
  const unsigned char *p[3];
  size_t n;
  int64_t l[2] = {32, 64};
  if (!fixed(l, 2, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  (void)ec_ext_out(0);
  return done(op_ed25519_verify(p[0], p[1], p[2], n));
}

EC_FN(int64_t, ec_crypto_p256_public, (void)) {
  const unsigned char *p[2];
  size_t n;
  int64_t l[1] = {32};
  if (!fixed(l, 1, 0, p, &n)) return done(EC_CRYPTO_ELENGTH);
  return done(op_p256_public(p[0], ec_ext_out(65)));
}

EC_FN(int64_t, ec_crypto_p256_sign, (void)) {
  const unsigned char *p[2];
  size_t n;
  int64_t l[1] = {32};
  if (!fixed(l, 1, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out(P256_SIG_MAX);
  int64_t r = op_p256_sign(p[0], p[1], n, o);
  if (r >= 0) ec_ext_out_truncate((size_t)r);
  return done(r);
}

EC_FN(int64_t, ec_crypto_p256_verify, (int64_t sig_len)) {
  const unsigned char *p[3];
  size_t n;
  int64_t l[2] = {65, sig_len};
  if (sig_len < 0 || !fixed(l, 2, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  (void)ec_ext_out(0);
  return done(op_p256_verify(p[0], p[1], (size_t)sig_len, p[2], n));
}

EC_FN(int64_t, ec_crypto_p256_ecdh, (void)) {
  const unsigned char *p[3];
  size_t n;
  int64_t l[2] = {32, 65};
  if (!fixed(l, 2, 0, p, &n)) return done(EC_CRYPTO_ELENGTH);
  return done(op_p256_ecdh(p[0], p[1], ec_ext_out(32)));
}

EC_FN(int64_t, ec_crypto_ct_equal, (int64_t len)) {
  const unsigned char *p[2];
  size_t n;
  if (len < 0 || !split(NULL, NULL, &len, 1, p, &n) || n != (size_t)len) return done(EC_CRYPTO_ELENGTH);
  (void)ec_ext_out(0);
  return done(CRYPTO_memcmp(nz(p[0]), nz(p[1]), (size_t)len) == 0 ? 1 : 0);
}
