/* seed/wasm2c.c's instruction test (seed/tests/run.sh): built for wasm32 with the seed's
   features and translated by wasm2c, and built natively, it must print the same lines; with an
   argument it executes a trap instead (div0, rem0, ovf, oob, stack, calls, unreachable), which
   the translation must report as `wasm trap: ...` with exit code 134. Only the C core's
   functions are imported (core/ABI.md), as in the seed. */
#include <stdint.h>
#if defined(__wasm__)
#define IMP(n) __attribute__((import_module("env"), import_name(#n)))
#define EXPORT(n) __attribute__((export_name(n)))
#else
#define IMP(n)
#define EXPORT(n)
#endif
IMP(ec_in_clear) void ec_in_clear(void);
IMP(ec_in_push) void ec_in_push(int32_t);
IMP(ec_write_fd) int64_t ec_write_fd(int32_t);
IMP(ec_args) int64_t ec_args(void);
IMP(ec_out_len) int64_t ec_out_len(void);
IMP(ec_out_byte) int32_t ec_out_byte(int64_t);
IMP(ec_exit) void ec_exit(int32_t);

static void out(const char *s) {
  ec_in_clear();
  while (*s) ec_in_push((unsigned char)*s++);
  ec_write_fd(1);
}
static void hex(const char *label, uint64_t v) {
  char b[64];
  int n = 0;
  while (*label) b[n++] = *label++;
  b[n++] = ' ';
  for (int i = 15; i >= 0; i--) b[n++] = "0123456789abcdef"[(v >> (i * 4)) & 15];
  b[n++] = '\n';
  b[n] = 0;
  out(b);
}

/* volatile: the values reach the instructions at run time, not as folded constants */
static volatile uint32_t U[] = {0, 1, 2, 7, 31, 32, 33, 0x7fffffffu, 0x80000000u, 0x80000001u, 0xfffffffeu, 0xffffffffu, 0x12345678u};
static volatile uint64_t L[] = {0, 1, 3, 63, 64, 65, 0x7fffffffffffffffull, 0x8000000000000000ull, 0xfffffffffffffffeull, 0xffffffffffffffffull, 0x123456789abcdef0ull};
#define NU (sizeof U / sizeof U[0])
#define NL (sizeof L / sizeof L[0])

static int64_t sdiv64(int64_t a, int64_t b) { return (a == INT64_MIN && b == -1) ? 0 : a / b; }
static int32_t sdiv32(int32_t a, int32_t b) { return (a == INT32_MIN && b == -1) ? 0 : a / b; }

typedef uint32_t (*fn32)(uint32_t);
static uint32_t inc(uint32_t x) { return x + 1; }
static uint32_t dbl(uint32_t x) { return x * 2; }
static uint32_t neg(uint32_t x) { return 0u - x; }
static volatile fn32 FNS[3] = {inc, dbl, neg};
/* recursion through a function pointer: no shadow stack, only the translation's call depth */
typedef uint32_t (*recf)(uint32_t);
static uint32_t rec(uint32_t n);
static volatile recf REC = rec;
static uint32_t rec(uint32_t n) { return n == 0 ? 0 : REC(n - 1) + 1; }

static uint32_t sw(uint32_t x) {
  switch (x) {
  case 0: return 10;
  case 1: return 11;
  case 2: return 12;
  case 3: return 13;
  case 5: return 15;
  case 8: return 18;
  default: return 99;
  }
}
static int depth(int n) { volatile char pad[64]; pad[n & 63] = (char)n; return n == 0 ? pad[0] : depth(n - 1) + pad[n & 63]; }

static char buf[4096];

static int arg_is(const char *s) {
  /* argv[1] (the core's ec_args: each argument NUL-terminated) */
  if (ec_args() < 0) return 0;
  int64_t n = ec_out_len(), i = 0;
  while (i < n && ec_out_byte(i) != 0) i++;
  i++;
  for (; *s; s++, i++)
    if (i >= n || ec_out_byte(i) != (unsigned char)*s) return 0;
  return i < n && ec_out_byte(i) == 0;
}

static volatile int32_t zero = 0, minus1 = -1;
static volatile uint32_t far = 0xfffffff0u;

EXPORT("_start") void start(void);
void start(void) {
  if (arg_is("div0")) hex("div0", (uint64_t)(U[3] / (uint32_t)zero));
  if (arg_is("rem0")) hex("rem0", (uint64_t)(L[2] % (uint64_t)zero));
  if (arg_is("ovf")) hex("ovf", (uint64_t)(int64_t)((int32_t)INT32_MIN / minus1));
  if (arg_is("oob")) hex("oob", *(volatile uint32_t *)(uintptr_t)far);
  if (arg_is("calls")) hex("calls", rec(100000000));
  if (arg_is("stack")) hex("stack", (uint64_t)depth(10000000));
  if (arg_is("unreachable")) __builtin_trap();
  uint64_t h = 0;
  for (unsigned i = 0; i < NU; i++)
    for (unsigned j = 0; j < NU; j++) {
      uint32_t a = U[i], b = U[j];
      int32_t sa = (int32_t)a, sb = (int32_t)b;
      uint64_t r = 0;
      r = r * 31 + (a + b) + (a - b) + a * b;
      r = r * 31 + (a & b) + (a | b) + (a ^ b);
      r = r * 31 + (a << (b & 31)) + (a >> (b & 31)) + (uint32_t)(sa >> (b & 31));
      r = r * 31 + ((a << (b & 31)) | (a >> ((32 - (b & 31)) & 31))) + ((a >> (b & 31)) | (a << ((32 - (b & 31)) & 31)));
      if (b) r = r * 31 + a / b + a % b + (uint32_t)sdiv32(sa, sb) + (uint32_t)(sb == -1 ? 0 : sa % sb);
      r = r * 31 + (sa < sb) + 2 * (a < b) + 4 * (sa <= sb) + 8 * (a <= b) + 16 * (sa > sb) + 32 * (a > b) + 64 * (sa >= sb) + 128 * (a >= b) + 256 * (a == b) + 512 * (a != b);
      r = r * 31 + (a ? a : b);
      h = h * 1000003 + r;
    }
  hex("i32 binary", h);
  h = 0;
  for (unsigned i = 0; i < NL; i++)
    for (unsigned j = 0; j < NL; j++) {
      uint64_t a = L[i], b = L[j];
      int64_t sa = (int64_t)a, sb = (int64_t)b;
      uint64_t r = 0;
      r = r * 31 + (a + b) + (a - b) + a * b;
      r = r * 31 + (a & b) + (a | b) + (a ^ b);
      r = r * 31 + (a << (b & 63)) + (a >> (b & 63)) + (uint64_t)(sa >> (b & 63));
      r = r * 31 + ((a << (b & 63)) | (a >> ((64 - (b & 63)) & 63)));
      if (b) r = r * 31 + a / b + a % b + (uint64_t)sdiv64(sa, sb) + (uint64_t)(sb == -1 ? 0 : sa % sb);
      r = r * 31 + (sa < sb) + 2 * (a < b) + 4 * (sa <= sb) + 8 * (a <= b) + 16 * (sa > sb) + 32 * (a > b) + 64 * (sa >= sb) + 128 * (a >= b) + 256 * (a == b) + 512 * (a != b);
      h = h * 1000003 + r;
    }
  hex("i64 binary", h);
  h = 0;
  for (unsigned i = 0; i < NU; i++) {
    uint32_t a = U[i];
    h = h * 31 + (uint64_t)(a ? __builtin_clz(a) : 32) + (uint64_t)(a ? __builtin_ctz(a) : 32) + (uint64_t)__builtin_popcount(a);
    h = h * 31 + (uint64_t)(int64_t)(int32_t)a + (uint64_t)(int32_t)(int8_t)a + (uint64_t)(int32_t)(int16_t)a + (uint64_t)(int64_t)(int8_t)a + (uint64_t)(int64_t)(int16_t)a + (uint64_t)a;
    h = h * 31 + (a == 0);
  }
  for (unsigned i = 0; i < NL; i++) {
    uint64_t a = L[i];
    h = h * 31 + (uint64_t)(a ? __builtin_clzll(a) : 64) + (uint64_t)(a ? __builtin_ctzll(a) : 64) + (uint64_t)__builtin_popcountll(a);
    h = h * 31 + (uint32_t)a + (uint64_t)(int64_t)(int32_t)(uint32_t)a + (a == 0);
  }
  hex("unary", h);
  h = 0;
  for (uint32_t i = 0; i < 12; i++) h = h * 31 + sw(i) + FNS[i % 3](i * 1000);
  hex("br_table call_indirect", h);
  /* memory: bytes, halves, words and doublewords at every alignment, copies and fills */
  for (int i = 0; i < 4096; i++) buf[i] = (char)(i * 7);
  __builtin_memmove(buf + 3, buf, 1000);
  __builtin_memmove(buf, buf + 5, 1000);
  __builtin_memset(buf + 2000, 0xab, 333);
  h = 0;
  for (int i = 0; i < 64; i++) {
    volatile uint8_t *p = (volatile uint8_t *)buf + i;
    uint16_t a; uint32_t b; uint64_t c;
    __builtin_memcpy(&a, (const void *)p, 2);
    __builtin_memcpy(&b, (const void *)p, 4);
    __builtin_memcpy(&c, (const void *)p, 8);
    h = h * 31 + a + b + c + (uint64_t)(int64_t)(int8_t)p[0] + (uint64_t)(int64_t)(int16_t)a + (uint64_t)(int64_t)(int32_t)b;
  }
  for (int i = 0; i < 4096; i++) h = h * 31 + (uint8_t)buf[i];
  hex("memory", h);
#if defined(__wasm__)
  uint32_t pages = (uint32_t)__builtin_wasm_memory_size(0);
  uint32_t old = (uint32_t)__builtin_wasm_memory_grow(0, 2);
  hex("grow", (uint64_t)(old == pages) + 2 * (uint64_t)((uint32_t)__builtin_wasm_memory_size(0) == pages + 2) + 4 * (uint64_t)((uint32_t)__builtin_wasm_memory_grow(0, 70000) == 0xffffffffu));
#else
  hex("grow", 7);
#endif
  hex("depth", (uint64_t)depth(2000) + rec(20000));
  out("done\n");
  ec_exit(0);
}
#if !defined(__wasm__)
int main(void) { start(); return 0; }
#endif
