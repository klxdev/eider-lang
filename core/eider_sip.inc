/* SipHash-1-3 for Map keys (decision C6, docs/decisions.md C805; core/RUNTIME.md "Map hashing").
   Shared by the native and the WebAssembly runtime (included into both eider_rt.c files).

   A Map carries a 128-bit key, two words `key[0]`, `key[1]` in the map itself. `ei_sip13_w` is
   SipHash-1-3 of the 8 little-endian bytes of a word, `ei_sip13_w2` of the 16 bytes of two words,
   `ei_sip13_str` of the bytes of a C string up to its NUL, and `ei_sip13` of any bytes under an
   explicit key (tests/core checks it against reference vectors). Integer arithmetic only. */

static uint64_t ei_sip_rotl(uint64_t x, int b) { return (x << b) | (x >> (64 - b)); }

#define EI_SIPROUND(v0, v1, v2, v3) \
  do { \
    v0 += v1; v1 = ei_sip_rotl(v1, 13); v1 ^= v0; v0 = ei_sip_rotl(v0, 32); \
    v2 += v3; v3 = ei_sip_rotl(v3, 16); v3 ^= v2; \
    v0 += v3; v3 = ei_sip_rotl(v3, 21); v3 ^= v0; \
    v2 += v1; v1 = ei_sip_rotl(v1, 17); v1 ^= v2; v2 = ei_sip_rotl(v2, 32); \
  } while (0)

typedef struct { uint64_t v0, v1, v2, v3; } ei_sip_state;

static void ei_sip_init(ei_sip_state *s, uint64_t k0, uint64_t k1) {
  s->v0 = k0 ^ UINT64_C(0x736f6d6570736575);
  s->v1 = k1 ^ UINT64_C(0x646f72616e646f6d);
  s->v2 = k0 ^ UINT64_C(0x6c7967656e657261);
  s->v3 = k1 ^ UINT64_C(0x7465646279746573);
}

/* absorbs one 8-byte word: one compression round (the "1" of SipHash-1-3) */
static void ei_sip_word(ei_sip_state *s, uint64_t m) {
  s->v3 ^= m;
  EI_SIPROUND(s->v0, s->v1, s->v2, s->v3);
  s->v0 ^= m;
}

/* the last block (the length in the top byte, then the tail bytes) and three finalization rounds */
static uint64_t ei_sip_final(ei_sip_state *s, uint64_t b) {
  ei_sip_word(s, b);
  s->v2 ^= 0xff;
  EI_SIPROUND(s->v0, s->v1, s->v2, s->v3);
  EI_SIPROUND(s->v0, s->v1, s->v2, s->v3);
  EI_SIPROUND(s->v0, s->v1, s->v2, s->v3);
  return s->v0 ^ s->v1 ^ s->v2 ^ s->v3;
}

uint64_t ei_sip13(uint64_t k0, uint64_t k1, const uint8_t *p, uint64_t n) {
  ei_sip_state s;
  ei_sip_init(&s, k0, k1);
  uint64_t i = 0;
  for (; i + 8 <= n; i += 8) {
    uint64_t m;
#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    memcpy(&m, p + i, 8);
#else
    m = 0;
    for (int j = 7; j >= 0; j--) m = (m << 8) | p[i + (uint64_t)j];
#endif
    ei_sip_word(&s, m);
  }
  uint64_t b = n << 56;
  for (uint64_t j = 0; i + j < n; j++) b |= (uint64_t)p[i + j] << (8 * j);
  return ei_sip_final(&s, b);
}

uint64_t ei_sip13_w(const uint64_t *key, uint64_t w) {
  ei_sip_state s;
  ei_sip_init(&s, key[0], key[1]);
  ei_sip_word(&s, w);
  return ei_sip_final(&s, UINT64_C(8) << 56);
}

uint64_t ei_sip13_w2(const uint64_t *key, uint64_t a, uint64_t b) {
  ei_sip_state s;
  ei_sip_init(&s, key[0], key[1]);
  ei_sip_word(&s, a);
  ei_sip_word(&s, b);
  return ei_sip_final(&s, UINT64_C(16) << 56);
}

uint64_t ei_sip13_str(const uint64_t *key, const char *t) {
  return ei_sip13(key[0], key[1], (const uint8_t *)t, (uint64_t)strlen(t));
}
