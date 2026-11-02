/* Float text for the runtimes (core/eider_rt.c and core/wasm/eider_rt.c include this file after their
   fmt_fill, fmt_pad and ei_print_s): not a translation unit of its own. */

// ---- floats: text (docs/decisions.md C660)
//
// Printing is exact and locale-free, in integer arithmetic only (no libm, no printf, so the
// same code runs in a WebAssembly module). Show writes the shortest digits that read back as
// the same float (Burger and Dybvig's free-format algorithm: Steele and White's / dragon4
// with an exact big integer; the digits are the closest to the value among the shortest, a
// tie going up); `{x:.N}` writes the exact binary value rounded to N places, half to even
// (what printf and Rust do). It is a small big integer rather than Ryu's tables: print is
// not a hot path of programs, and the code is short enough to audit.

#define EI_FBIG 100 /* 32-bit limbs: 3200 bits, the largest value is about 2^2500 */
typedef struct {
  uint32_t n;
  uint32_t d[EI_FBIG];
} ei_big;

static void big_set(ei_big *a, uint64_t v) {
  a->n = 0;
  while (v) {
    a->d[a->n++] = (uint32_t)v;
    v >>= 32;
  }
}

static void big_mul_small(ei_big *a, uint32_t m) {
  uint64_t c = 0;
  for (uint32_t i = 0; i < a->n; i++) {
    uint64_t t = (uint64_t)a->d[i] * m + c;
    a->d[i] = (uint32_t)t;
    c = t >> 32;
  }
  if (c) a->d[a->n++] = (uint32_t)c;
}

static void big_add_small(ei_big *a, uint32_t v) {
  uint64_t c = v;
  for (uint32_t i = 0; i < a->n && c; i++) {
    uint64_t t = (uint64_t)a->d[i] + c;
    a->d[i] = (uint32_t)t;
    c = t >> 32;
  }
  if (c) a->d[a->n++] = (uint32_t)c;
}

static void big_shl(ei_big *a, unsigned s) {
  if (a->n == 0) return;
  unsigned w = s / 32, b = s % 32;
  if (b) {
    uint32_t c = 0;
    for (uint32_t i = 0; i < a->n; i++) {
      uint32_t x = a->d[i];
      a->d[i] = (x << b) | c;
      c = x >> (32 - b);
    }
    if (c) a->d[a->n++] = c;
  }
  if (w) {
    for (uint32_t i = a->n; i > 0; i--) a->d[i - 1 + w] = a->d[i - 1];
    for (uint32_t i = 0; i < w; i++) a->d[i] = 0;
    a->n += w;
  }
}

static int big_cmp(const ei_big *a, const ei_big *b) {
  if (a->n != b->n) return a->n < b->n ? -1 : 1;
  for (uint32_t i = a->n; i > 0; i--) {
    if (a->d[i - 1] != b->d[i - 1]) return a->d[i - 1] < b->d[i - 1] ? -1 : 1;
  }
  return 0;
}

static void big_add(ei_big *a, const ei_big *b) {
  uint64_t c = 0;
  uint32_t n = a->n > b->n ? a->n : b->n;
  for (uint32_t i = 0; i < n; i++) {
    uint64_t t = c + (i < a->n ? a->d[i] : 0) + (i < b->n ? b->d[i] : 0);
    a->d[i] = (uint32_t)t;
    c = t >> 32;
  }
  a->n = n;
  if (c) a->d[a->n++] = (uint32_t)c;
}

/* a -= b (a >= b) */
static void big_sub(ei_big *a, const ei_big *b) {
  int64_t br = 0;
  for (uint32_t i = 0; i < a->n; i++) {
    int64_t t = (int64_t)a->d[i] - (i < b->n ? (int64_t)b->d[i] : 0) - br;
    br = t < 0;
    a->d[i] = (uint32_t)(t + (br ? 4294967296LL : 0));
  }
  while (a->n && a->d[a->n - 1] == 0) a->n--;
}

static void big_pow10(ei_big *a, unsigned k) {
  while (k >= 9) {
    big_mul_small(a, 1000000000u);
    k -= 9;
  }
  uint32_t p = 1;
  while (k--) p *= 10;
  if (p > 1) big_mul_small(a, p);
}

/* a /= m, returns the remainder */
static uint32_t big_divmod_small(ei_big *a, uint32_t m) {
  uint64_t r = 0;
  for (uint32_t i = a->n; i > 0; i--) {
    uint64_t t = (r << 32) | a->d[i - 1];
    a->d[i - 1] = (uint32_t)(t / m);
    r = t % m;
  }
  while (a->n && a->d[a->n - 1] == 0) a->n--;
  return (uint32_t)r;
}

static int big_bit(const ei_big *a, unsigned i) {
  if (i / 32 >= a->n) return 0;
  return (int)((a->d[i / 32] >> (i % 32)) & 1);
}

/* whether the bits below position i are all zero */
static int big_low_zero(const ei_big *a, unsigned i) {
  for (unsigned w = 0; w < i / 32 && w < a->n; w++) {
    if (a->d[w]) return 0;
  }
  if (i % 32 && i / 32 < a->n && (a->d[i / 32] & (((uint32_t)1 << (i % 32)) - 1))) return 0;
  return 1;
}

static void big_shr(ei_big *a, unsigned s) {
  unsigned w = s / 32, b = s % 32;
  if (w >= a->n) {
    a->n = 0;
    return;
  }
  for (uint32_t i = 0; i + w < a->n; i++) {
    uint32_t lo = a->d[i + w] >> b;
    uint32_t hi = (b && i + w + 1 < a->n) ? a->d[i + w + 1] << (32 - b) : 0;
    a->d[i] = lo | hi;
  }
  a->n -= w;
  while (a->n && a->d[a->n - 1] == 0) a->n--;
}

/* The pieces of a finite float: v = m * 2^e (m < 2^p), asym when the lower neighbour is
   closer (m is a power of two above the smallest normal). */
typedef struct {
  uint64_t m;
  int e;
  int asym;
  int neg;
  int kind; /* 0 finite, 1 infinity, 2 NaN */
} ei_fparts;

static ei_fparts fparts(uint64_t bits, int single) {
  ei_fparts f;
  int p = single ? 24 : 53;
  int eb = single ? 8 : 11;
  uint64_t frac = bits & (((uint64_t)1 << (p - 1)) - 1);
  uint32_t ex = (uint32_t)((bits >> (p - 1)) & (((uint64_t)1 << eb) - 1));
  f.neg = (int)((bits >> (p - 1 + eb)) & 1);
  f.kind = 0;
  f.asym = 0;
  f.m = 0;
  f.e = 0;
  if (ex == ((uint32_t)1 << eb) - 1) {
    f.kind = frac ? 2 : 1;
    return f;
  }
  if (ex == 0) {
    f.m = frac;
    f.e = single ? -149 : -1074;
  } else {
    f.m = frac | ((uint64_t)1 << (p - 1));
    f.e = (int)ex - (single ? 150 : 1075);
    f.asym = frac == 0 && ex > 1;
  }
  return f;
}

static unsigned bitlen64(uint64_t x) {
  unsigned n = 0;
  while (x) {
    n++;
    x >>= 1;
  }
  return n;
}

/* The shortest digits of m * 2^e (m > 0): digits[0..n) as values 0..9, returns n and sets
   *k so that the value is 0.d1d2...dn * 10^k. */
static unsigned shortest(unsigned char *digits, int *kout, ei_fparts f) {
  ei_big r, s, mp, mm, t;
  int e = f.e;
  int high_ok = (f.m & 1) == 0;
  if (e >= 0) {
    big_set(&r, f.m);
    big_shl(&r, (unsigned)e + (f.asym ? 2 : 1));
    big_set(&s, f.asym ? 4 : 2);
    big_set(&mp, 1);
    big_shl(&mp, (unsigned)e + (f.asym ? 1 : 0));
    big_set(&mm, 1);
    big_shl(&mm, (unsigned)e);
  } else {
    big_set(&r, f.m);
    big_shl(&r, f.asym ? 2 : 1);
    big_set(&s, 1);
    big_shl(&s, (unsigned)(-e) + (f.asym ? 2 : 1));
    big_set(&mp, f.asym ? 2 : 1);
    big_set(&mm, 1);
  }
  /* estimate k = ceil(log10(v)); the loops below make it exact */
  int l2 = e + (int)bitlen64(f.m) - 1;
  int k = l2 >= 0 ? (int)(((int64_t)l2 * 78913) >> 18) : -(int)(((int64_t)(-l2) * 78913 + 262143) >> 18);
  if (k >= 0) {
    big_pow10(&s, (unsigned)k);
  } else {
    big_pow10(&r, (unsigned)(-k));
    big_pow10(&mp, (unsigned)(-k));
    big_pow10(&mm, (unsigned)(-k));
  }
  for (;;) {
    t = r;
    big_add(&t, &mp);
    int c = big_cmp(&t, &s);
    if (high_ok ? c >= 0 : c > 0) {
      big_mul_small(&s, 10);
      k++;
    } else {
      break;
    }
  }
  for (;;) {
    t = r;
    big_add(&t, &mp);
    big_mul_small(&t, 10);
    int c = big_cmp(&t, &s);
    if (high_ok ? c >= 0 : c > 0) break;
    big_mul_small(&r, 10);
    big_mul_small(&mp, 10);
    big_mul_small(&mm, 10);
    k--;
  }
  unsigned n = 0;
  for (;;) {
    big_mul_small(&r, 10);
    big_mul_small(&mp, 10);
    big_mul_small(&mm, 10);
    unsigned d = 0;
    while (big_cmp(&r, &s) >= 0) {
      big_sub(&r, &s);
      d++;
    }
    int c1 = big_cmp(&r, &mm);
    int tc1 = high_ok ? c1 <= 0 : c1 < 0;
    t = r;
    big_add(&t, &mp);
    int c2 = big_cmp(&t, &s);
    int tc2 = high_ok ? c2 >= 0 : c2 > 0;
    if (!tc1 && !tc2) {
      digits[n++] = (unsigned char)d;
      continue;
    }
    if (tc1 && tc2) {
      t = r;
      big_shl(&t, 1);
      if (big_cmp(&t, &s) >= 0) d++;
    } else if (tc2) {
      d++;
    }
    digits[n++] = (unsigned char)d;
    break;
  }
  *kout = k;
  return n;
}

/* The text of a float: the shortest round-trip form, without a sign. Positional for decimal
   exponents -5..15 (`0.00001`, `123456.789`, always with a `.`), else `d.ddde-7` / `1e16`.
   NaN, `inf`. Returns the length (b has room for 40 bytes). */
static unsigned ftext(char *b, ei_fparts f) {
  unsigned n = 0;
  if (f.kind == 2) {
    b[0] = 'N';
    b[1] = 'a';
    b[2] = 'N';
    return 3;
  }
  if (f.kind == 1) {
    b[0] = 'i';
    b[1] = 'n';
    b[2] = 'f';
    return 3;
  }
  if (f.m == 0) {
    b[0] = '0';
    b[1] = '.';
    b[2] = '0';
    return 3;
  }
  unsigned char dg[40];
  int k;
  unsigned nd = shortest(dg, &k, f);
  int x = k - 1; /* the decimal exponent of the first digit */
  if (x >= -5 && x < 16) {
    if (x >= 0) {
      for (int i = 0; i <= x; i++) b[n++] = (char)('0' + ((unsigned)i < nd ? dg[i] : 0));
      b[n++] = '.';
      if ((unsigned)x + 1 < nd) {
        for (unsigned i = (unsigned)x + 1; i < nd; i++) b[n++] = (char)('0' + dg[i]);
      } else {
        b[n++] = '0';
      }
    } else {
      b[n++] = '0';
      b[n++] = '.';
      for (int i = 0; i < -x - 1; i++) b[n++] = '0';
      for (unsigned i = 0; i < nd; i++) b[n++] = (char)('0' + dg[i]);
    }
    return n;
  }
  b[n++] = (char)('0' + dg[0]);
  if (nd > 1) {
    b[n++] = '.';
    for (unsigned i = 1; i < nd; i++) b[n++] = (char)('0' + dg[i]);
  }
  b[n++] = 'e';
  int ax = x;
  if (x < 0) {
    b[n++] = '-';
    ax = -x;
  }
  char eb[8];
  int h = 0;
  do {
    eb[h++] = (char)('0' + ax % 10);
    ax /= 10;
  } while (ax);
  while (h) b[n++] = eb[--h];
  return n;
}

/* The exact value of f rounded to `prec` places after the point, half to even, as digits
   (no sign): returns the length; b has room for 1100 bytes. */
static unsigned ffixed(char *b, ei_fparts f, unsigned prec) {
  ei_big q;
  big_set(&q, f.m);
  if (f.e >= 0) {
    big_shl(&q, (unsigned)f.e);
    big_pow10(&q, prec);
  } else {
    big_pow10(&q, prec);
    unsigned sh = (unsigned)(-f.e);
    if (q.n > 0) {
      int half = big_bit(&q, sh - 1);
      int below = !big_low_zero(&q, sh - 1);
      int lsb = big_bit(&q, sh);
      big_shr(&q, sh);
      if (half && (below || lsb)) big_add_small(&q, 1);
    }
  }
  char tmp[1100];
  unsigned nt = 0;
  while (q.n) {
    uint32_t chunk = big_divmod_small(&q, 1000000000u);
    for (int i = 0; i < 9; i++) {
      tmp[nt++] = (char)('0' + chunk % 10);
      chunk /= 10;
    }
  }
  while (nt > 1 && tmp[nt - 1] == '0') nt--;
  if (nt == 0) tmp[nt++] = '0';
  while (nt < prec + 1) tmp[nt++] = '0';
  unsigned n = 0;
  for (unsigned i = nt; i > 0; i--) {
    b[n++] = tmp[i - 1];
    if (i - 1 == prec && prec > 0) b[n++] = '.';
  }
  return n;
}

void ei_str_push_f64(ei_String *s, double v) {
  uint64_t bits;
  memcpy(&bits, &v, 8);
  ei_fparts f = fparts(bits, 0);
  char b[48];
  unsigned n = 0;
  if (f.neg && f.kind != 2) b[n++] = '-';
  n += ftext(b + n, f);
  ei_str_cat(s, b, n);
}

void ei_str_push_f32(ei_String *s, float v) {
  uint32_t bits;
  memcpy(&bits, &v, 4);
  ei_fparts f = fparts(bits, 1);
  char b[48];
  unsigned n = 0;
  if (f.neg && f.kind != 2) b[n++] = '-';
  n += ftext(b + n, f);
  ei_str_cat(s, b, n);
}

void ei_print_f64(double v) {
  ei_String t = ei_str_from("");
  ei_str_push_f64(&t, v);
  ei_print_s(t.p);
  ei_drop_String(&t);
}

void ei_print_f32(float v) {
  ei_String t = ei_str_from("");
  ei_str_push_f32(&t, v);
  ei_print_s(t.p);
  ei_drop_String(&t);
}

/* {x:spec} for a float: width, fill, alignment, `+`, `0`, and the precision (bits 52-62,
   bit 63: given). */
static void fmt_float(ei_String *s, uint64_t bits, int single, uint64_t spec) {
  ei_fparts f = fparts(bits, single);
  char b[1200];
  unsigned n = 0;
  unsigned sign = 0;
  char sg = 0;
  if (f.kind != 2) {
    if (f.neg) sg = '-';
    else if ((spec >> 42) & 1) sg = '+';
  }
  if (sg) sign = 1;
  if (f.kind == 0 && (spec >> 63)) {
    n = ffixed(b + sign, f, (unsigned)((spec >> 52) & 2047));
  } else {
    n = ftext(b + sign, f);
  }
  if (sg) b[0] = sg;
  n += sign;
  if (((spec >> 44) & 1) && f.kind == 0) {
    uint64_t width = spec & 0xffffffffu;
    if (sign) ei_str_cat(s, b, 1);
    if (n < width) fmt_fill(s, '0', width - n);
    ei_str_cat(s, b + sign, n - sign);
    return;
  }
  fmt_pad(s, b, n, spec);
}

void ei_str_fmt_f64(ei_String *s, double v, uint64_t spec) {
  uint64_t bits;
  memcpy(&bits, &v, 8);
  fmt_float(s, bits, 0, spec);
}

void ei_str_fmt_f32(ei_String *s, float v, uint64_t spec) {
  uint32_t bits;
  memcpy(&bits, &v, 4);
  fmt_float(s, bits, 1, spec);
}
