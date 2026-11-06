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
#include <openssl/rsa.h>
#include <openssl/x509.h>

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

/* HKDF (RFC 5869): extract (a = salt, b = IKM -> PRK) or expand (a = PRK, b = info -> outn
   bytes of OKM, through EVP_PKEY_HKDF in expand-only mode). */
static int64_t op_hkdf(int extract, int32_t hash, const unsigned char *a, size_t an, const unsigned char *b, size_t bn, unsigned char *out, size_t outn) {
  const EVP_MD *md = mac_md(hash);
  if (!md) return EC_CRYPTO_EUNSUPPORTED;
  /* Extract is HMAC-Hash(salt, IKM) by definition (RFC 5869 2.2; an empty salt is HashLen
     zero bytes, which HMAC's key padding makes the same thing). It goes through HMAC()
     rather than EVP_PKEY_HKDF because the libraries disagree on an empty IKM there:
     OpenSSL 3 accepts it, AWS-LC and LibreSSL refuse it (found by tests/crypto/cross.ei). */
  if (extract) return op_hmac(hash, a, an, b, bn, out);
  size_t hl = (size_t)EVP_MD_size(md);
  if (outn == 0 || outn > 255 * hl || an < hl) return EC_CRYPTO_ELENGTH;
  int64_t r = EC_CRYPTO_EBACKEND;
  EVP_PKEY_CTX *c = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, NULL);
  if (!c) return r;
  size_t got = outn;
  if (EVP_PKEY_derive_init(c) == 1 &&
      EVP_PKEY_CTX_hkdf_mode(c, EVP_PKEY_HKDEF_MODE_EXPAND_ONLY) == 1 &&
      EVP_PKEY_CTX_set_hkdf_md(c, md) == 1) {
    int ok = EVP_PKEY_CTX_set1_hkdf_key(c, nz(a), (int)an) == 1 && (bn == 0 || EVP_PKEY_CTX_add1_hkdf_info(c, b, (int)bn) == 1);
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

/* A fixed 2048-bit RSA key (PKCS#1 RSAPrivateKey), generated once for this file, only for ec_crypto_supports to
   sign and verify with once. It protects nothing. */
static const unsigned char SELFTEST_RSA_KEY[] = {
  0x30, 0x82, 0x04, 0xa2, 0x02, 0x01, 0x00, 0x02, 0x82, 0x01, 0x01, 0x00,
  0x8d, 0x7c, 0x6a, 0xf3, 0x8f, 0xb7, 0xa3, 0x94, 0x31, 0xc3, 0x54, 0xf8,
  0x62, 0x7b, 0x0f, 0x6b, 0xc4, 0xfd, 0xb7, 0x69, 0xe8, 0x54, 0x45, 0x5f,
  0x12, 0xea, 0xd0, 0xc5, 0xd9, 0xbf, 0xf8, 0xc0, 0x57, 0x11, 0x83, 0x40,
  0xcd, 0xe0, 0x67, 0xcf, 0xec, 0xa5, 0x36, 0xb0, 0xb6, 0xa6, 0x9a, 0x2f,
  0x1a, 0xb9, 0x0f, 0x42, 0x34, 0x4f, 0x05, 0x17, 0x8e, 0x63, 0x85, 0xe0,
  0x26, 0xe5, 0xdb, 0xd2, 0x63, 0x00, 0x1c, 0xaa, 0xee, 0x3a, 0x2e, 0x5d,
  0x3e, 0xa5, 0xd9, 0x80, 0x49, 0x35, 0x9d, 0xf7, 0x9f, 0xb3, 0xe7, 0xdb,
  0x63, 0xf7, 0xd7, 0x56, 0x31, 0x3f, 0x66, 0x90, 0x16, 0xf3, 0xbe, 0x9c,
  0x24, 0xfc, 0xc7, 0x86, 0x4a, 0x90, 0x34, 0x71, 0x7e, 0x1e, 0xdf, 0xfe,
  0xe5, 0xb8, 0x4a, 0x48, 0x3d, 0x1b, 0x4c, 0x04, 0x36, 0xa4, 0xbb, 0x2d,
  0x27, 0x19, 0x62, 0xbc, 0x3e, 0xe6, 0xf8, 0x14, 0x09, 0x74, 0xe2, 0x58,
  0x88, 0x50, 0x0e, 0x0d, 0x91, 0x5f, 0xaa, 0xcf, 0xb8, 0x9b, 0x5b, 0x7d,
  0xb1, 0x6d, 0x0a, 0x07, 0xc3, 0x93, 0xa2, 0x6d, 0x84, 0x1e, 0x3e, 0x32,
  0x80, 0x5d, 0xcd, 0x24, 0xa6, 0xfa, 0x1c, 0x03, 0x68, 0x75, 0xbf, 0x3f,
  0x53, 0xb1, 0x70, 0xdb, 0x44, 0x10, 0x3c, 0x38, 0x4d, 0xb0, 0x3a, 0x14,
  0x36, 0xc0, 0x0d, 0x46, 0xab, 0xfa, 0x7c, 0xfa, 0x1c, 0x31, 0x35, 0x54,
  0x89, 0xc6, 0x8f, 0xb0, 0x5d, 0x22, 0xd6, 0x3c, 0x9a, 0xd5, 0x87, 0xa7,
  0xd9, 0x2e, 0x2c, 0x3f, 0x8a, 0xf8, 0xe3, 0xb6, 0x0b, 0x36, 0xe1, 0xb6,
  0xb2, 0xdb, 0xce, 0xcd, 0x92, 0x24, 0x06, 0x07, 0xf0, 0xb9, 0x48, 0x1a,
  0x07, 0x37, 0xd4, 0x57, 0xcb, 0x5f, 0xaa, 0x49, 0xdb, 0xc4, 0x46, 0x6e,
  0xf5, 0x1e, 0x65, 0x8c, 0xde, 0x94, 0x73, 0x9e, 0x17, 0x7d, 0x85, 0x18,
  0xb4, 0xe0, 0x02, 0xf5, 0x02, 0x03, 0x01, 0x00, 0x01, 0x02, 0x82, 0x01,
  0x00, 0x13, 0x0e, 0xb4, 0xab, 0x3c, 0xea, 0xfb, 0xe6, 0x1c, 0xb3, 0xd6,
  0x50, 0xa4, 0x97, 0x35, 0xd3, 0x0a, 0xd4, 0x2f, 0xed, 0xdc, 0x84, 0xe9,
  0x59, 0x2e, 0x87, 0xa1, 0x7a, 0x5c, 0xe3, 0xae, 0x42, 0x5e, 0x17, 0xf6,
  0x49, 0x76, 0xd1, 0xa8, 0xba, 0x09, 0x82, 0x91, 0x74, 0xc9, 0x0d, 0x74,
  0xcc, 0x2e, 0x79, 0xc9, 0xd3, 0xdd, 0x8e, 0xdd, 0x3d, 0x38, 0x89, 0x30,
  0x41, 0xaa, 0x8b, 0xa0, 0x89, 0xdc, 0x9a, 0xe9, 0xc1, 0x9e, 0x58, 0x08,
  0xe1, 0xb7, 0x6c, 0x08, 0x79, 0x6e, 0xa3, 0x01, 0xb5, 0x96, 0x75, 0xd9,
  0x9f, 0xa3, 0xfe, 0x00, 0xab, 0xd3, 0xf3, 0x59, 0xc1, 0xc3, 0xcd, 0xae,
  0x19, 0x83, 0x23, 0xe7, 0x4e, 0x2f, 0xe1, 0xef, 0xa6, 0x6f, 0xda, 0x01,
  0xca, 0xe8, 0x2f, 0x64, 0x16, 0x09, 0xe1, 0x10, 0xe2, 0xaa, 0x67, 0x92,
  0xec, 0xb8, 0x8d, 0x03, 0x4f, 0x1e, 0xdb, 0xe6, 0x83, 0x3d, 0x19, 0x67,
  0xdb, 0x9c, 0x89, 0x23, 0x10, 0xdc, 0x28, 0xaf, 0xfd, 0x66, 0xe5, 0x65,
  0x78, 0xd9, 0x48, 0x1c, 0xd7, 0x6d, 0x50, 0x66, 0x3a, 0x65, 0xb3, 0xb7,
  0xbf, 0xdc, 0xcf, 0xc3, 0xfd, 0x7b, 0xba, 0xa1, 0x19, 0x79, 0xdc, 0x52,
  0xad, 0x10, 0x2d, 0x82, 0x05, 0xeb, 0x12, 0x73, 0x0b, 0xe3, 0xde, 0x48,
  0xae, 0xdb, 0xb7, 0x04, 0xdf, 0xbb, 0xa8, 0xc3, 0x24, 0xf6, 0x5f, 0x78,
  0x8e, 0xee, 0x09, 0x88, 0x96, 0x5b, 0xd0, 0xe4, 0x68, 0xe4, 0x72, 0x01,
  0x47, 0x13, 0xd9, 0xc4, 0x6a, 0x09, 0x4f, 0x44, 0x07, 0x80, 0xd0, 0x0d,
  0xa1, 0x2b, 0xb1, 0x37, 0x68, 0xad, 0x24, 0x50, 0x45, 0x17, 0xf3, 0xd0,
  0x64, 0x9c, 0x63, 0xbb, 0x82, 0xce, 0xf1, 0x43, 0x98, 0x33, 0xab, 0xd1,
  0xc7, 0xdb, 0x33, 0xf5, 0x94, 0x5d, 0x2f, 0x48, 0xbf, 0x00, 0x68, 0x38,
  0x88, 0xe3, 0xc7, 0xc8, 0xd1, 0x02, 0x81, 0x81, 0x00, 0xc6, 0x00, 0x64,
  0xb9, 0x7d, 0x30, 0xa7, 0x00, 0xba, 0x15, 0x6d, 0x9b, 0xa6, 0x6f, 0x49,
  0x1b, 0xc7, 0xd3, 0x39, 0xbf, 0x35, 0x26, 0x64, 0x34, 0x06, 0xb9, 0x9b,
  0x3c, 0xb9, 0xd9, 0x89, 0xca, 0x12, 0x14, 0x6c, 0xf1, 0x85, 0x8a, 0x95,
  0xa5, 0x25, 0xad, 0x35, 0xcf, 0xec, 0x5e, 0x80, 0x3a, 0x67, 0x16, 0x38,
  0x96, 0x34, 0x91, 0x26, 0xa1, 0x16, 0x59, 0x03, 0xa7, 0x6d, 0xfc, 0x76,
  0xa5, 0x24, 0x55, 0x9d, 0xf9, 0x5a, 0xef, 0x3a, 0xe0, 0x1b, 0x0c, 0x62,
  0x09, 0x34, 0x95, 0xb5, 0x9e, 0x3c, 0xdb, 0x1f, 0x1e, 0xec, 0x74, 0x09,
  0x26, 0xf5, 0x37, 0xbd, 0x88, 0xfb, 0xbe, 0xed, 0xc1, 0x86, 0x60, 0x96,
  0x22, 0x38, 0xd9, 0x0d, 0x50, 0x8a, 0xf9, 0x45, 0x18, 0x03, 0xba, 0xed,
  0xa3, 0x1a, 0x6a, 0xd6, 0x37, 0xc4, 0x3d, 0x81, 0xcc, 0x64, 0x75, 0xcb,
  0x4d, 0x9b, 0xbf, 0xc9, 0xc9, 0x02, 0x81, 0x81, 0x00, 0xb6, 0xee, 0x13,
  0x5d, 0x1d, 0x48, 0xbd, 0x4f, 0xc4, 0x61, 0x64, 0x38, 0x7f, 0x30, 0xa8,
  0x5d, 0x65, 0x46, 0x0e, 0xa5, 0xba, 0xd1, 0x13, 0x47, 0xf2, 0xcf, 0xda,
  0x1d, 0xc3, 0xdc, 0x02, 0x5b, 0x63, 0x24, 0xd9, 0xf9, 0x05, 0x12, 0x80,
  0x15, 0x9b, 0xf4, 0x5c, 0x95, 0xd4, 0xa5, 0x55, 0x52, 0x29, 0xe0, 0x8f,
  0xe1, 0x26, 0x21, 0xf3, 0x23, 0x7c, 0xfe, 0xc2, 0x4f, 0x67, 0x28, 0x43,
  0x21, 0xdf, 0x42, 0x08, 0x5a, 0x4c, 0x28, 0xd7, 0x5a, 0xca, 0xd7, 0x68,
  0x9b, 0xa3, 0x40, 0x65, 0x77, 0xb6, 0x55, 0xa4, 0x42, 0xfe, 0xb3, 0x1d,
  0x6e, 0x40, 0x28, 0xf1, 0x9e, 0x02, 0x25, 0x4f, 0xae, 0xcb, 0xa5, 0x24,
  0xf8, 0x85, 0xdf, 0xc2, 0x54, 0x3f, 0xa8, 0x8b, 0x3a, 0xc4, 0xad, 0x9e,
  0xcf, 0xf9, 0x0a, 0x82, 0x51, 0x01, 0x95, 0x66, 0x12, 0xaf, 0x3d, 0x3b,
  0xa3, 0x8f, 0xc6, 0x85, 0xcd, 0x02, 0x81, 0x80, 0x23, 0xde, 0xf4, 0x60,
  0x8a, 0x66, 0xa3, 0x0a, 0xc5, 0xab, 0x96, 0x24, 0xe9, 0xbd, 0x25, 0x90,
  0x8b, 0xde, 0x1f, 0x8b, 0x1d, 0x74, 0xec, 0x18, 0x64, 0xd3, 0x81, 0x65,
  0x3a, 0x02, 0x48, 0x2d, 0x3c, 0xa3, 0x48, 0xad, 0x64, 0xd5, 0x1b, 0x91,
  0x44, 0xc7, 0x21, 0x85, 0x9e, 0xbb, 0xec, 0x1d, 0x28, 0x89, 0xe5, 0x0c,
  0x89, 0x4f, 0x76, 0xa1, 0x1e, 0x6c, 0x57, 0xf6, 0x20, 0x3d, 0xe9, 0xbc,
  0xb7, 0x5d, 0x6f, 0x76, 0x3a, 0x5c, 0x36, 0xdd, 0x5c, 0xe9, 0x1c, 0x65,
  0xb0, 0x8a, 0x22, 0xd2, 0x1d, 0x12, 0x51, 0x8c, 0x07, 0xa8, 0x69, 0xf4,
  0x0d, 0xde, 0xe0, 0x4e, 0x8d, 0xd5, 0x24, 0x3b, 0xb8, 0x3d, 0x8d, 0x55,
  0x7b, 0xd9, 0x0e, 0xc9, 0x75, 0xb3, 0xfd, 0x29, 0x81, 0x9b, 0x7e, 0xeb,
  0xda, 0xa0, 0x5a, 0x58, 0xd6, 0x0b, 0x92, 0x95, 0x55, 0xe9, 0xe5, 0x40,
  0x15, 0x24, 0x64, 0xc9, 0x02, 0x81, 0x80, 0x44, 0xbc, 0xbd, 0x05, 0xf6,
  0x25, 0x09, 0x0d, 0xda, 0x2b, 0x06, 0x6f, 0xbc, 0x4b, 0x5a, 0x58, 0x8d,
  0xdf, 0x7f, 0x4d, 0x83, 0x1f, 0x60, 0xf1, 0x5e, 0x2a, 0x00, 0x39, 0xc3,
  0x08, 0xfe, 0xd1, 0xbc, 0x35, 0x72, 0xba, 0x81, 0xcf, 0x6b, 0xd5, 0xb2,
  0xde, 0x65, 0x93, 0xdf, 0x6d, 0xa8, 0xdb, 0xd0, 0xe4, 0x92, 0xeb, 0xf5,
  0x5a, 0x38, 0x74, 0x93, 0x59, 0x5f, 0x46, 0x5a, 0xea, 0xe4, 0x1e, 0xec,
  0x37, 0x71, 0xd0, 0x0c, 0x62, 0x24, 0x59, 0xf7, 0x72, 0x6d, 0xda, 0x5d,
  0xc3, 0xaa, 0xdd, 0x0a, 0xe4, 0xaf, 0x6e, 0x85, 0x2a, 0x64, 0xda, 0xb2,
  0xbd, 0x2f, 0xdd, 0x41, 0xcd, 0x27, 0x5d, 0xf5, 0x23, 0xbe, 0xfa, 0xab,
  0xc3, 0x62, 0xd0, 0x29, 0x83, 0x79, 0x9d, 0xc1, 0x9d, 0xc3, 0xd9, 0x3e,
  0x29, 0x56, 0xc2, 0x7d, 0xa7, 0xd7, 0xcd, 0x19, 0x90, 0x16, 0xc2, 0xe5,
  0x19, 0xa1, 0xd9, 0x02, 0x81, 0x80, 0x6d, 0xb6, 0x22, 0x30, 0xda, 0x91,
  0x95, 0x8c, 0x92, 0x9d, 0xe7, 0xa6, 0xdd, 0x98, 0x7d, 0xe3, 0x5f, 0x2b,
  0x11, 0x8b, 0xf9, 0xc6, 0x6c, 0xad, 0x87, 0x24, 0x46, 0xcd, 0x26, 0x12,
  0x37, 0xb0, 0xe4, 0x15, 0x6c, 0x9c, 0xfa, 0x1a, 0x1d, 0x16, 0x68, 0x53,
  0xd5, 0x25, 0x27, 0x5b, 0x8a, 0x6c, 0xc8, 0x06, 0x64, 0xf5, 0xca, 0x27,
  0xc7, 0x54, 0x3b, 0x18, 0x57, 0xd7, 0x6d, 0xf6, 0x3d, 0x72, 0x2d, 0xb7,
  0x1a, 0xd4, 0x15, 0x36, 0xbe, 0xff, 0xd7, 0xed, 0xb3, 0x23, 0x47, 0x9d,
  0xe3, 0x2b, 0x53, 0xc9, 0x72, 0xce, 0xf4, 0xd8, 0xf5, 0x30, 0x29, 0xf7,
  0xdb, 0xf7, 0x35, 0xd4, 0x56, 0x4f, 0x23, 0x96, 0x54, 0x2b, 0x94, 0xf7,
  0x11, 0xd5, 0x5e, 0x7d, 0x95, 0xbf, 0x07, 0xbf, 0x6f, 0x8d, 0x2e, 0xd5,
  0xfa, 0xae, 0x7c, 0x0e, 0xdf, 0xec, 0x3b, 0x46, 0x61, 0xa6, 0x9d, 0xaf,
  0x0e, 0x9a,
};

/* ---- elliptic curves (ECDSA, ECDH): P-256 and P-384 through one code path */

typedef struct {
  int nid;
  size_t scalar, point, sig_max; /* private scalar bytes; uncompressed point bytes; DER ECDSA-Sig-Value maximum */
} curve_t;

static const curve_t *curve_for(int32_t c) {
  static const curve_t p256 = {NID_X9_62_prime256v1, 32, 65, 72}, p384 = {NID_secp384r1, 48, 97, 104};
  return c == EC_CRYPTO_CURVE_P256 ? &p256 : c == EC_CRYPTO_CURVE_P384 ? &p384 : NULL;
}

#define EC_SCALAR_MAX 48
#define EC_POINT_MAX 97
#define EC_SIG_MAX 104

/* ECDSA hashes: SHA-256, SHA-384, SHA-512 (any with either curve, as TLS 1.2 and X.509 combine them) */
static const EVP_MD *ecdsa_md(int32_t hash) {
  return hash == EC_CRYPTO_SHA256 || hash == EC_CRYPTO_SHA384 || hash == EC_CRYPTO_SHA512 ? md_for(hash) : NULL;
}

/* An EVP_PKEY on `cv` from a private scalar (the public point is computed) or from an
   uncompressed public point (checked to be on the curve). NULL and *bad = 1 for an invalid
   key; NULL and *bad = 0 if the library failed. */
static EVP_PKEY *ec_key(const curve_t *cv, const unsigned char *d, const unsigned char *pub, int *bad) {
  *bad = 0;
  EVP_PKEY *pk = NULL;
  BIGNUM *bn = NULL, *order = NULL;
  EC_POINT *pt = NULL;
  EC_KEY *k = EC_KEY_new_by_curve_name(cv->nid);
  if (!k) goto out;
  const EC_GROUP *g = EC_KEY_get0_group(k);
  pt = EC_POINT_new(g);
  if (!pt) goto out;
  if (d) {
    bn = BN_bin2bn(d, (int)cv->scalar, NULL);
    order = BN_new();
    if (!bn || !order || EC_GROUP_get_order(g, order, NULL) != 1) goto out;
    if (BN_is_zero(bn) || BN_cmp(bn, order) >= 0) { *bad = 1; goto out; }
    if (EC_KEY_set_private_key(k, bn) != 1 || EC_POINT_mul(g, pt, bn, NULL, NULL, NULL) != 1) goto out;
  } else {
    if (pub[0] != 4 || EC_POINT_oct2point(g, pt, pub, cv->point, NULL) != 1) { *bad = 1; goto out; }
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

static int64_t op_ec_public(const curve_t *cv, const unsigned char *d, unsigned char *out) {
  if (!cv) return EC_CRYPTO_EUNSUPPORTED;
  int64_t r = EC_CRYPTO_EBACKEND;
  int bad = 0;
  EVP_PKEY *pk = ec_key(cv, d, NULL, &bad);
  if (!pk) return bad ? EC_CRYPTO_EKEY : r;
  const EC_KEY *k = EVP_PKEY_get0_EC_KEY(pk);
  if (k && EC_POINT_point2oct(EC_KEY_get0_group(k), EC_KEY_get0_public_key(k), POINT_CONVERSION_UNCOMPRESSED, out, cv->point, NULL) == cv->point)
    r = (int64_t)cv->point;
  EVP_PKEY_free(pk);
  return r;
}

/* DER ECDSA-Sig-Value over hash(m), k random from the library */
static int64_t op_ec_sign(const curve_t *cv, int32_t hash, const unsigned char *d, const unsigned char *m, size_t n, unsigned char *out) {
  const EVP_MD *md = ecdsa_md(hash);
  if (!cv || !md) return EC_CRYPTO_EUNSUPPORTED;
  int bad = 0;
  EVP_PKEY *pk = ec_key(cv, d, NULL, &bad);
  if (!pk) return bad ? EC_CRYPTO_EKEY : EC_CRYPTO_EBACKEND;
  EVP_MD_CTX *c = EVP_MD_CTX_new();
  unsigned char sig[EC_SIG_MAX + 16];
  size_t len = sizeof sig;
  int ok = c && EVP_DigestSignInit(c, NULL, md, NULL, pk) == 1 && EVP_DigestSign(c, sig, &len, nz(m), n) == 1 && len <= cv->sig_max;
  EVP_MD_CTX_free(c);
  EVP_PKEY_free(pk);
  if (!ok) return EC_CRYPTO_EBACKEND;
  memcpy(out, sig, len);
  return (int64_t)len;
}

static int64_t op_ec_verify(const curve_t *cv, int32_t hash, const unsigned char *pub, const unsigned char *sig, size_t sn, const unsigned char *m, size_t n) {
  const EVP_MD *md = ecdsa_md(hash);
  if (!cv || !md) return EC_CRYPTO_EUNSUPPORTED;
  int bad = 0;
  EVP_PKEY *pk = ec_key(cv, NULL, pub, &bad);
  if (!pk) return bad ? EC_CRYPTO_EKEY : EC_CRYPTO_EBACKEND;
  EVP_MD_CTX *c = EVP_MD_CTX_new();
  int ok = c && sn > 0 && EVP_DigestVerifyInit(c, NULL, md, NULL, pk) == 1 && EVP_DigestVerify(c, sig, sn, nz(m), n) == 1;
  EVP_MD_CTX_free(c);
  EVP_PKEY_free(pk);
  return ok ? 1 : 0;
}

static int64_t op_ec_ecdh(const curve_t *cv, const unsigned char *d, const unsigned char *pub, unsigned char *out) {
  if (!cv) return EC_CRYPTO_EUNSUPPORTED;
  int bad1 = 0, bad2 = 0;
  EVP_PKEY *a = ec_key(cv, d, NULL, &bad1), *b = ec_key(cv, NULL, pub, &bad2);
  int64_t r = a && b ? derive(a, b, out, cv->scalar) : (bad1 || bad2 ? EC_CRYPTO_EKEY : EC_CRYPTO_EBACKEND);
  EVP_PKEY_free(a);
  EVP_PKEY_free(b);
  return r;
}

/* ---- RSA (verification and signing; PKCS#1 v1.5 and RSASSA-PSS with MGF1 of the same hash)
   A public key travels as a blob: n_len (4 bytes, big endian) || n || e, both unsigned big
   endian. A private key travels as DER (PKCS#8 or PKCS#1 RSAPrivateKey). */

#define RSA_MIN_BITS 2048
#define RSA_MAX_BITS 8192
#define RSA_MAX_E_BITS 33 /* AWS-LC and BoringSSL refuse a larger e; the glue makes OpenSSL and LibreSSL agree */
#define RSA_BLOB_MAX (4 + RSA_MAX_BITS / 8 + 8)

/* the size policy, identical on every backend: 2048..8192 bits, odd modulus, odd e >= 3 of at most 33 bits, e < n */
static int rsa_params_ok(const BIGNUM *n, const BIGNUM *e) {
  int nb = BN_num_bits(n), eb = BN_num_bits(e);
  return nb >= RSA_MIN_BITS && nb <= RSA_MAX_BITS && BN_is_odd(n) && BN_is_odd(e) && eb >= 2 && eb <= RSA_MAX_E_BITS && BN_cmp(e, n) < 0;
}

/* blob from the n and e of an RSA key; returns its length or a status */
static int64_t rsa_blob(const BIGNUM *n, const BIGNUM *e, unsigned char *out) {
  if (!n || !e || !rsa_params_ok(n, e)) return EC_CRYPTO_EKEY;
  int nl = BN_num_bytes(n), el = BN_num_bytes(e);
  out[0] = (unsigned char)(nl >> 24);
  out[1] = (unsigned char)(nl >> 16);
  out[2] = (unsigned char)(nl >> 8);
  out[3] = (unsigned char)nl;
  BN_bn2bin(n, out + 4);
  BN_bn2bin(e, out + 4 + nl);
  return (int64_t)(4 + nl + el);
}

/* the public EVP_PKEY of a blob (NULL: not a valid RSA public key by the policy above) and its modulus size in bytes */
static EVP_PKEY *rsa_pub_key(const unsigned char *b, size_t len, size_t *modlen) {
  if (len < 6 || len > RSA_BLOB_MAX) return NULL;
  size_t nl = ((size_t)b[0] << 24) | ((size_t)b[1] << 16) | ((size_t)b[2] << 8) | b[3];
  if (nl == 0 || nl > RSA_MAX_BITS / 8 || len - 4 <= nl || len - 4 - nl > 8) return NULL;
  EVP_PKEY *pk = NULL;
  BIGNUM *n = BN_bin2bn(b + 4, (int)nl, NULL), *e = BN_bin2bn(b + 4 + nl, (int)(len - 4 - nl), NULL);
  RSA *r = RSA_new();
  if (!n || !e || !r || !rsa_params_ok(n, e)) goto out;
  if (RSA_set0_key(r, n, e, NULL) != 1) goto out;
  n = e = NULL; /* now owned by r */
  pk = EVP_PKEY_new();
  if (pk && EVP_PKEY_set1_RSA(pk, r) != 1) {
    EVP_PKEY_free(pk);
    pk = NULL;
  }
  if (pk) *modlen = (size_t)RSA_size(r);
out:
  BN_free(n);
  BN_free(e);
  RSA_free(r);
  return pk;
}

/* digest, padding and salt on a signing or verifying context */
static int rsa_setup(EVP_MD_CTX *c, int sign, EVP_PKEY *pk, int32_t scheme, const EVP_MD *md, int salt) {
  EVP_PKEY_CTX *pc = NULL;
  if ((sign ? EVP_DigestSignInit(c, &pc, md, NULL, pk) : EVP_DigestVerifyInit(c, &pc, md, NULL, pk)) != 1 || !pc) return 0;
  if (scheme == EC_CRYPTO_RSA_PKCS1) return EVP_PKEY_CTX_set_rsa_padding(pc, RSA_PKCS1_PADDING) > 0;
  return EVP_PKEY_CTX_set_rsa_padding(pc, RSA_PKCS1_PSS_PADDING) > 0 && EVP_PKEY_CTX_set_rsa_pss_saltlen(pc, salt) > 0 &&
         EVP_PKEY_CTX_set_rsa_mgf1_md(pc, md) > 0;
}

static const EVP_MD *rsa_md(int32_t scheme, int32_t hash, int64_t salt) {
  if (scheme != EC_CRYPTO_RSA_PKCS1 && scheme != EC_CRYPTO_RSA_PSS) return NULL;
  if (scheme == EC_CRYPTO_RSA_PSS && (salt < 0 || salt > 1024)) return NULL;
  return ecdsa_md(hash); /* the SHA-2 hashes */
}

/* 1 valid, 0 not (also for a bad key, a signature of the wrong length, a salt that doesn't fit) */
static int64_t op_rsa_verify(int32_t scheme, int32_t hash, int64_t salt, const unsigned char *key, size_t kn, const unsigned char *sig, size_t sn,
                             const unsigned char *m, size_t n) {
  const EVP_MD *md = rsa_md(scheme, hash, salt);
  if (!md) return EC_CRYPTO_EUNSUPPORTED;
  size_t modlen = 0;
  EVP_PKEY *pk = rsa_pub_key(key, kn, &modlen);
  if (!pk) return EC_CRYPTO_EKEY;
  /* the signature is exactly the modulus size (RFC 8017 8.1.2 step 1; the libraries differ on short ones) */
  EVP_MD_CTX *c = sn == modlen ? EVP_MD_CTX_new() : NULL;
  int ok = c && rsa_setup(c, 0, pk, scheme, md, (int)salt) && EVP_DigestVerify(c, sig, sn, nz(m), n) == 1;
  EVP_MD_CTX_free(c);
  EVP_PKEY_free(pk);
  return ok ? 1 : 0;
}

/* the RSA EVP_PKEY of a private key DER (PKCS#8 or PKCS#1), by the same size policy; its blob into `blob` if not NULL */
static EVP_PKEY *rsa_priv_key(const unsigned char *der, size_t len, unsigned char *blob, int64_t *blob_len) {
  const unsigned char *q = der;
  if (len > 8192) return NULL;
  EVP_PKEY *pk = d2i_AutoPrivateKey(NULL, &q, (long)len);
  if (!pk) return NULL;
  const RSA *r = EVP_PKEY_base_id(pk) == EVP_PKEY_RSA && (size_t)(q - der) == len ? EVP_PKEY_get0_RSA(pk) : NULL;
  const BIGNUM *n = NULL, *e = NULL, *d = NULL;
  if (r) RSA_get0_key(r, &n, &e, &d);
  int64_t bl = r && d ? rsa_blob(n, e, blob) : EC_CRYPTO_EKEY;
  if (bl < 0) {
    EVP_PKEY_free(pk);
    return NULL;
  }
  if (blob_len) *blob_len = bl;
  return pk;
}

static int64_t op_rsa_sign(int32_t scheme, int32_t hash, int64_t salt, const unsigned char *der, size_t dn, const unsigned char *m, size_t n, unsigned char *out, size_t cap) {
  const EVP_MD *md = rsa_md(scheme, hash, salt);
  if (!md) return EC_CRYPTO_EUNSUPPORTED;
  unsigned char blob[RSA_BLOB_MAX];
  EVP_PKEY *pk = rsa_priv_key(der, dn, blob, NULL);
  if (!pk) return EC_CRYPTO_EKEY;
  EVP_MD_CTX *c = EVP_MD_CTX_new();
  size_t len = cap;
  int ok = c && rsa_setup(c, 1, pk, scheme, md, (int)salt) && EVP_DigestSign(c, out, &len, nz(m), n) == 1 && len <= cap;
  EVP_MD_CTX_free(c);
  EVP_PKEY_free(pk);
  return ok ? (int64_t)len : EC_CRYPTO_EBACKEND;
}

/* ---- key import: SubjectPublicKeyInfo and private key DER -> the glue's own key forms */

static int curve_kind(const EC_GROUP *g) {
  int nid = EC_GROUP_get_curve_name(g);
  return nid == NID_X9_62_prime256v1 ? EC_CRYPTO_KEY_P256 : nid == NID_secp384r1 ? EC_CRYPTO_KEY_P384 : 0;
}

/* out (>= 1 + RSA_BLOB_MAX): kind || RSA blob, or kind || uncompressed point */
static int64_t op_spki(const unsigned char *der, size_t len, unsigned char *out) {
  const unsigned char *q = der;
  if (len > 8192) return EC_CRYPTO_ELENGTH;
  EVP_PKEY *pk = d2i_PUBKEY(NULL, &q, (long)len);
  if (!pk) return EC_CRYPTO_EKEY;
  int64_t r = EC_CRYPTO_EKEY;
  if ((size_t)(q - der) == len) {
    int id = EVP_PKEY_base_id(pk);
    if (id == EVP_PKEY_RSA) {
      const RSA *rsa = EVP_PKEY_get0_RSA(pk);
      const BIGNUM *n = NULL, *e = NULL;
      if (rsa) RSA_get0_key(rsa, &n, &e, NULL);
      int64_t bl = rsa_blob(n, e, out + 1);
      if (bl > 0) { out[0] = EC_CRYPTO_KEY_RSA; r = 1 + bl; }
    } else if (id == EVP_PKEY_EC) {
      const EC_KEY *k = EVP_PKEY_get0_EC_KEY(pk);
      const EC_GROUP *g = k ? EC_KEY_get0_group(k) : NULL;
      int kind = g ? curve_kind(g) : 0;
      const curve_t *cv = curve_for(kind == EC_CRYPTO_KEY_P256 ? EC_CRYPTO_CURVE_P256 : EC_CRYPTO_CURVE_P384);
      if (kind && EC_KEY_get0_public_key(k) &&
          EC_POINT_point2oct(g, EC_KEY_get0_public_key(k), POINT_CONVERSION_UNCOMPRESSED, out + 1, cv->point, NULL) == cv->point) {
        out[0] = (unsigned char)kind;
        r = (int64_t)(1 + cv->point);
      }
    }
  }
  EVP_PKEY_free(pk);
  return r;
}

/* out: kind || RSA blob (the public half), or kind || scalar */
static int64_t op_priv(const unsigned char *der, size_t len, unsigned char *out) {
  const unsigned char *q = der;
  if (len > 8192) return EC_CRYPTO_ELENGTH;
  EVP_PKEY *pk = d2i_AutoPrivateKey(NULL, &q, (long)len);
  if (!pk) return EC_CRYPTO_EKEY;
  int64_t r = EC_CRYPTO_EKEY;
  if ((size_t)(q - der) == len) {
    int id = EVP_PKEY_base_id(pk);
    if (id == EVP_PKEY_RSA) {
      int64_t bl = 0;
      EVP_PKEY *k = rsa_priv_key(der, len, out + 1, &bl);
      if (k) { out[0] = EC_CRYPTO_KEY_RSA; r = 1 + bl; }
      EVP_PKEY_free(k);
    } else if (id == EVP_PKEY_EC) {
      const EC_KEY *k = EVP_PKEY_get0_EC_KEY(pk);
      const EC_GROUP *g = k ? EC_KEY_get0_group(k) : NULL;
      int kind = g ? curve_kind(g) : 0;
      const curve_t *cv = curve_for(kind == EC_CRYPTO_KEY_P256 ? EC_CRYPTO_CURVE_P256 : EC_CRYPTO_CURVE_P384);
      const BIGNUM *d = kind ? EC_KEY_get0_private_key(k) : NULL;
      if (d && (int)BN_num_bytes(d) <= (int)cv->scalar && BN_bn2binpad(d, out + 1, (int)cv->scalar) == (int)cv->scalar) {
        out[0] = (unsigned char)kind;
        r = (int64_t)(1 + cv->scalar);
      }
    }
  }
  EVP_PKEY_free(pk);
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
  unsigned char k[32] = {0}, kk[EC_SCALAR_MAX] = {0}, out[256], o2[256], m[1] = {0};
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
  case EC_CRYPTO_ECDSA_P256_SHA256: case EC_CRYPTO_ECDSA_P256_SHA384: case EC_CRYPTO_ECDSA_P384_SHA384: {
    int32_t curve = alg == EC_CRYPTO_ECDSA_P384_SHA384 ? EC_CRYPTO_CURVE_P384 : EC_CRYPTO_CURVE_P256;
    int32_t h = alg == EC_CRYPTO_ECDSA_P256_SHA256 ? EC_CRYPTO_SHA256 : EC_CRYPTO_SHA384;
    const curve_t *cv = curve_for(curve);
    kk[cv->scalar - 1] = 1;
    r = op_ec_public(cv, kk, out);
    if (r > 0) r = op_ec_sign(cv, h, kk, m, 1, o2);
    if (r > 0) r = op_ec_verify(cv, h, out, o2, (size_t)r, m, 1) == 1 ? 1 : -1;
    break;
  }
  case EC_CRYPTO_ECDH_P256: case EC_CRYPTO_ECDH_P384: {
    const curve_t *cv = curve_for(alg == EC_CRYPTO_ECDH_P384 ? EC_CRYPTO_CURVE_P384 : EC_CRYPTO_CURVE_P256);
    kk[cv->scalar - 1] = 1;
    r = op_ec_public(cv, kk, out);
    if (r > 0) r = op_ec_ecdh(cv, kk, out, o2);
    break;
  }
  case EC_CRYPTO_RSA_PKCS1_SHA256: case EC_CRYPTO_RSA_PSS_SHA256: {
    /* sign with the fixed key, verify with the public half taken from the same DER */
    int32_t sc = alg == EC_CRYPTO_RSA_PSS_SHA256 ? EC_CRYPTO_RSA_PSS : EC_CRYPTO_RSA_PKCS1;
    unsigned char sig[RSA_MAX_BITS / 8], pub[1 + RSA_BLOB_MAX];
    int64_t pl = op_priv(SELFTEST_RSA_KEY, sizeof SELFTEST_RSA_KEY, pub);
    r = pl > 1 ? op_rsa_sign(sc, EC_CRYPTO_SHA256, 32, SELFTEST_RSA_KEY, sizeof SELFTEST_RSA_KEY, m, 1, sig, sizeof sig) : -1;
    if (r > 0) r = op_rsa_verify(sc, EC_CRYPTO_SHA256, 32, pub + 1, (size_t)pl - 1, sig, (size_t)r, m, 1) == 1 ? 1 : -1;
    break;
  }
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

/* the curve-generic forms; ec_crypto_p256_* below are the same with P-256 (and SHA-256) fixed */
static int64_t ec_public(int32_t curve) {
  const curve_t *cv = curve_for(curve);
  const unsigned char *p[2];
  size_t n;
  if (!cv) return done(EC_CRYPTO_EUNSUPPORTED);
  int64_t l[1] = {(int64_t)cv->scalar};
  if (!fixed(l, 1, 0, p, &n)) return done(EC_CRYPTO_ELENGTH);
  return done(op_ec_public(cv, p[0], ec_ext_out(cv->point)));
}

static int64_t ec_sign(int32_t curve, int32_t hash) {
  const curve_t *cv = curve_for(curve);
  const unsigned char *p[2];
  size_t n;
  if (!cv) return done(EC_CRYPTO_EUNSUPPORTED);
  int64_t l[1] = {(int64_t)cv->scalar};
  if (!fixed(l, 1, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out(cv->sig_max);
  int64_t r = op_ec_sign(cv, hash, p[0], p[1], n, o);
  if (r >= 0) ec_ext_out_truncate((size_t)r);
  return done(r);
}

static int64_t ec_verify(int32_t curve, int32_t hash, int64_t sig_len) {
  const curve_t *cv = curve_for(curve);
  const unsigned char *p[3];
  size_t n;
  if (!cv) return done(EC_CRYPTO_EUNSUPPORTED);
  int64_t l[2] = {(int64_t)cv->point, sig_len};
  if (sig_len < 0 || !fixed(l, 2, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  (void)ec_ext_out(0);
  return done(op_ec_verify(cv, hash, p[0], p[1], (size_t)sig_len, p[2], n));
}

static int64_t ec_ecdh(int32_t curve) {
  const curve_t *cv = curve_for(curve);
  const unsigned char *p[3];
  size_t n;
  if (!cv) return done(EC_CRYPTO_EUNSUPPORTED);
  int64_t l[2] = {(int64_t)cv->scalar, (int64_t)cv->point};
  if (!fixed(l, 2, 0, p, &n)) return done(EC_CRYPTO_ELENGTH);
  return done(op_ec_ecdh(cv, p[0], p[1], ec_ext_out(cv->scalar)));
}

EC_FN(int64_t, ec_crypto_ec_public, (int32_t curve)) { return ec_public(curve); }
EC_FN(int64_t, ec_crypto_ec_sign, (int32_t curve, int32_t hash)) { return ec_sign(curve, hash); }
EC_FN(int64_t, ec_crypto_ec_verify, (int32_t curve, int32_t hash, int64_t sig_len)) { return ec_verify(curve, hash, sig_len); }
EC_FN(int64_t, ec_crypto_ec_ecdh, (int32_t curve)) { return ec_ecdh(curve); }

EC_FN(int64_t, ec_crypto_p256_public, (void)) { return ec_public(EC_CRYPTO_CURVE_P256); }
EC_FN(int64_t, ec_crypto_p256_sign, (void)) { return ec_sign(EC_CRYPTO_CURVE_P256, EC_CRYPTO_SHA256); }
EC_FN(int64_t, ec_crypto_p256_verify, (int64_t sig_len)) { return ec_verify(EC_CRYPTO_CURVE_P256, EC_CRYPTO_SHA256, sig_len); }
EC_FN(int64_t, ec_crypto_p256_ecdh, (void)) { return ec_ecdh(EC_CRYPTO_CURVE_P256); }

/* in = public key blob (n_len || n || e), signature, message; 1 valid, 0 not */
EC_FN(int64_t, ec_crypto_rsa_verify, (int32_t scheme, int32_t hash, int64_t salt_len, int64_t key_len, int64_t sig_len)) {
  const unsigned char *p[3];
  size_t n;
  int64_t l[2] = {key_len, sig_len};
  if (key_len < 0 || sig_len < 0 || !fixed(l, 2, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  (void)ec_ext_out(0);
  return done(op_rsa_verify(scheme, hash, salt_len, p[0], (size_t)key_len, p[1], (size_t)sig_len, p[2], n));
}

/* in = private key DER, message; out = signature (the modulus size) */
EC_FN(int64_t, ec_crypto_rsa_sign, (int32_t scheme, int32_t hash, int64_t salt_len, int64_t key_len)) {
  const unsigned char *p[2];
  size_t n;
  int64_t l[1] = {key_len};
  if (key_len < 0 || !fixed(l, 1, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out(RSA_MAX_BITS / 8);
  int64_t r = op_rsa_sign(scheme, hash, salt_len, p[0], (size_t)key_len, p[1], n, o, RSA_MAX_BITS / 8);
  if (r >= 0) ec_ext_out_truncate((size_t)r);
  return done(r);
}

/* in = DER SubjectPublicKeyInfo; out = kind || RSA blob or uncompressed point */
EC_FN(int64_t, ec_crypto_spki_parse, (void)) {
  size_t n;
  const unsigned char *p[1];
  if (!fixed(NULL, 0, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out(1 + RSA_BLOB_MAX);
  int64_t r = op_spki(p[0], n, o);
  if (r >= 0) ec_ext_out_truncate((size_t)r);
  return done(r);
}

/* in = private key DER (PKCS#8, PKCS#1 or SEC1); out = kind || RSA public blob, or kind || scalar */
EC_FN(int64_t, ec_crypto_priv_parse, (void)) {
  size_t n;
  const unsigned char *p[1];
  if (!fixed(NULL, 0, 1, p, &n)) return done(EC_CRYPTO_ELENGTH);
  unsigned char *o = ec_ext_out(1 + RSA_BLOB_MAX);
  int64_t r = op_priv(p[0], n, o);
  if (r >= 0) ec_ext_out_truncate((size_t)r);
  return done(r);
}

EC_FN(int64_t, ec_crypto_ct_equal, (int64_t len)) {
  const unsigned char *p[2];
  size_t n;
  if (len < 0 || !split(NULL, NULL, &len, 1, p, &n) || n != (size_t)len) return done(EC_CRYPTO_ELENGTH);
  (void)ec_ext_out(0);
  return done(CRYPTO_memcmp(nz(p[0]), nz(p[1]), (size_t)len) == 0 ? 1 : 0);
}
