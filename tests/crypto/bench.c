/* Throughput of each crypto operation through the core ABI (eider_crypto.h), for one backend.
   Built and run by scripts/crypto-bench.sh. The input is pushed into `in` outside the timed
   region (Eider pushes a byte per call today, which is a separate cost: README "Throughput");
   the timed part is the ec_crypto_* call itself, including unpacking `in`, the library call,
   packing `out` and wiping `in`. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "eider_crypto.h"

void ec_in_clear(void);
void ec_in_push(int32_t b);
int32_t ec_out_byte(int64_t i);
int64_t ec_out_len(void);

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void push(const unsigned char *p, size_t n) {
  for (size_t i = 0; i < n; i++) ec_in_push(p[i]);
}

static unsigned char buf[1 << 15], key[32], nonce[12], aad[13], sk[32], pk[65], sig[80], peer[65];
static size_t siglen;

typedef int64_t (*op_fn)(void);
static double timed;

/* run `setup` (untimed) and `op` (timed) repeatedly for about 0.4 s; operations per second */
static double rate(void (*setup)(void), op_fn op) {
  timed = 0;
  long n = 0;
  double start = now();
  while (now() - start < 0.4 || n < 20) {
    setup();
    double a = now();
    if (op() < 0) { fprintf(stderr, "bench: operation failed\n"); exit(1); }
    timed += now() - a;
    n++;
  }
  return (double)n / timed;
}

#define MSG 16384
static void s_hash(void) { ec_in_clear(); push(buf, MSG); }
static int64_t o_sha256(void) { return ec_crypto_hash(EC_CRYPTO_SHA256); }
static void s_aead(void) { ec_in_clear(); push(key, 32); push(nonce, 12); push(aad, 13); push(buf, MSG); }
static void s_aead16(void) { ec_in_clear(); push(key, 16); push(nonce, 12); push(aad, 13); push(buf, MSG); }
static int64_t o_chacha(void) { return ec_crypto_aead_seal(EC_CRYPTO_CHACHA20_POLY1305, 32, 12, 13); }
static int64_t o_aes128(void) { return ec_crypto_aead_seal(EC_CRYPTO_AES_128_GCM, 16, 12, 13); }
static int64_t o_aes256(void) { return ec_crypto_aead_seal(EC_CRYPTO_AES_256_GCM, 32, 12, 13); }
static void s_x(void) { ec_in_clear(); push(sk, 32); push(peer, 32); }
static int64_t o_x(void) { return ec_crypto_x25519(); }
static void s_eds(void) { ec_in_clear(); push(sk, 32); push(buf, 64); }
static int64_t o_eds(void) { return ec_crypto_ed25519_sign(); }
static void s_edv(void) { ec_in_clear(); push(pk, 32); push(sig, 64); push(buf, 64); }
static int64_t o_edv(void) { return ec_crypto_ed25519_verify(); }
static void s_ps(void) { ec_in_clear(); push(sk, 32); push(buf, 64); }
static int64_t o_ps(void) { return ec_crypto_p256_sign(); }
static void s_pv(void) { ec_in_clear(); push(pk, 65); push(sig, siglen); push(buf, 64); }
static int64_t o_pv(void) { return ec_crypto_p256_verify((int64_t)siglen); }
static void s_pe(void) { ec_in_clear(); push(sk, 32); push(peer, 65); }
static int64_t o_pe(void) { return ec_crypto_p256_ecdh(); }

static void take(unsigned char *dst, size_t *n) {
  *n = (size_t)ec_out_len();
  for (size_t i = 0; i < *n; i++) dst[i] = (unsigned char)ec_out_byte((int64_t)i);
}

int main(void) {
  for (size_t i = 0; i < sizeof buf; i++) buf[i] = (unsigned char)(i * 7);
  memset(key, 3, sizeof key);
  memset(nonce, 4, sizeof nonce);
  memset(aad, 5, sizeof aad);
  memset(sk, 0, sizeof sk);
  sk[31] = 0x42; sk[0] = 0x11;
  size_t n;
  ec_crypto_provider();
  char name[256];
  take((unsigned char *)name, &n);
  name[n < 255 ? n : 255] = 0;
  printf("backend: %s\n", name);
  double mb = MSG / 1e6;
  printf("SHA-256            %8.0f MB/s\n", rate(s_hash, o_sha256) * mb);
  printf("ChaCha20-Poly1305  %8.0f MB/s\n", rate(s_aead, o_chacha) * mb);
  printf("AES-128-GCM        %8.0f MB/s\n", rate(s_aead16, o_aes128) * mb);
  printf("AES-256-GCM        %8.0f MB/s\n", rate(s_aead, o_aes256) * mb);
  /* X25519 against a peer public key */
  ec_in_clear(); push(key, 32);
  if (ec_crypto_x25519_public() < 0) return 1;
  take(peer, &n);
  printf("X25519             %8.0f ops/s\n", rate(s_x, o_x));
  ec_in_clear(); push(sk, 32);
  if (ec_crypto_ed25519_public() < 0) return 1;
  take(pk, &n);
  ec_in_clear(); push(sk, 32); push(buf, 64);
  if (ec_crypto_ed25519_sign() < 0) return 1;
  take(sig, &n);
  printf("Ed25519 sign       %8.0f ops/s\n", rate(s_eds, o_eds));
  printf("Ed25519 verify     %8.0f ops/s\n", rate(s_edv, o_edv));
  ec_in_clear(); push(sk, 32);
  if (ec_crypto_p256_public() < 0) return 1;
  take(pk, &n);
  memcpy(peer, pk, 65);
  ec_in_clear(); push(sk, 32); push(buf, 64);
  if (ec_crypto_p256_sign() < 0) return 1;
  take(sig, &siglen);
  printf("ECDSA P-256 sign   %8.0f ops/s\n", rate(s_ps, o_ps));
  printf("ECDSA P-256 verify %8.0f ops/s\n", rate(s_pv, o_pv));
  printf("ECDH P-256         %8.0f ops/s\n", rate(s_pe, o_pe));
  return 0;
}
