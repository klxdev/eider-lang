// Tests for core/eider_rt.{h,c}: every function, every trap edge. Run by tests/core/run.sh.
// Traps are caught with the runtime's own test hook (ei_set_trap_jmp), and their output is
// captured and compared byte for byte; the exit path (no hook) runs in a forked child.
#define _POSIX_C_SOURCE 200809L

#include "../../core/eider_rt.h"

#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures, checks;
static jmp_buf jb;

static void check(int ok, const char *what, int line) {
  checks++;
  if (!ok) {
    failures++;
    fprintf(stderr, "FAIL rt_test.c:%d: %s\n", line, what);
  }
}

#define CHECK(c) check((c) ? 1 : 0, #c, __LINE__)
#define EQI(e, want) check((int64_t)(e) == (int64_t)(want), #e " == " #want, __LINE__)
#define EQU(e, want) check((uint64_t)(e) == (uint64_t)(want), #e " == " #want, __LINE__)
#define EQS(got, want) check(strcmp((got), (want)) == 0, #got " is \"" want "\"", __LINE__)

// ---- capturing stdout (fd 1) into a buffer

static char cap[8192];
static FILE *cap_file;
static int cap_saved = -1;

static void cap_begin(void) {
  fflush(stdout);
  cap_file = tmpfile();
  if (!cap_file) { perror("tmpfile"); exit(2); }
  cap_saved = dup(1);
  dup2(fileno(cap_file), 1);
}

static const char *cap_end(void) {
  fflush(stdout);
  dup2(cap_saved, 1);
  close(cap_saved);
  rewind(cap_file);
  size_t n = fread(cap, 1, sizeof cap - 1, cap_file);
  cap[n] = 0;
  fclose(cap_file);
  return cap;
}

/* Runs `stmt`, which must trap with `msg` at `line`; checks the hook's exact output. */
#define TRAPS(stmt, msg, line)                                                               \
  do {                                                                                       \
    volatile int hit_ = 0;                                                                   \
    cap_begin();                                                                             \
    ei_set_trap_jmp(&jb);                                                                    \
    if (setjmp(jb) == 0) {                                                                   \
      stmt;                                                                                  \
    } else {                                                                                 \
      hit_ = 1;                                                                              \
    }                                                                                        \
    ei_set_trap_jmp(NULL);                                                                   \
    const char *out_ = cap_end();                                                            \
    char want_[256];                                                                         \
    snprintf(want_, sizeof want_, "FAILED\n    %s (rt_test:%d)\n", msg, line);               \
    check(hit_ && strcmp(out_, want_) == 0, #stmt " traps with \"" msg "\"", __LINE__);      \
    if (hit_ && strcmp(out_, want_) != 0) fprintf(stderr, "  got: %s", out_);                \
  } while (0)

#define L 7 /* the source line passed to every checked operation */
#define OVF_ADD "integer overflow in +"
#define OVF_SUB "integer overflow in -"
#define OVF_MUL "integer overflow in *"
#define DIV0 "division by zero"
#define REM0 "remainder by zero"
#define CONV "integer conversion out of range"

// ---- arithmetic

static void test_bits(void) {
  EQI(ei_bits_i32(0), 0);
  EQI(ei_bits_i32(0x7fffffffu), INT32_MAX);
  EQI(ei_bits_i32(0x80000000u), INT32_MIN);
  EQI(ei_bits_i32(0xffffffffu), -1);
  EQI(ei_bits_i64(UINT64_C(0x7fffffffffffffff)), INT64_MAX);
  EQI(ei_bits_i64(UINT64_C(0x8000000000000000)), INT64_MIN);
  EQI(ei_bits_i64(UINT64_MAX), -1);
}

static void test_i32(void) {
  EQI(ei_add_i32(INT32_MAX - 1, 1, L), INT32_MAX);
  EQI(ei_add_i32(INT32_MIN, INT32_MAX, L), -1);
  EQI(ei_add_i32(INT32_MIN + 1, -1, L), INT32_MIN);
  TRAPS((void)ei_add_i32(INT32_MAX, 1, L), OVF_ADD, L);
  TRAPS((void)ei_add_i32(INT32_MIN, -1, L), OVF_ADD, L);
  EQI(ei_sub_i32(-1, INT32_MIN, L), INT32_MAX);
  EQI(ei_sub_i32(INT32_MIN + 1, 1, L), INT32_MIN);
  TRAPS((void)ei_sub_i32(INT32_MIN, 1, L), OVF_SUB, L);
  TRAPS((void)ei_sub_i32(INT32_MAX, -1, L), OVF_SUB, L);
  TRAPS((void)ei_sub_i32(0, INT32_MIN, L), OVF_SUB, L);
  EQI(ei_mul_i32(46340, 46340, L), 2147395600);
  EQI(ei_mul_i32(-65536, 32768, L), INT32_MIN);
  EQI(ei_mul_i32(INT32_MIN, 1, L), INT32_MIN);
  EQI(ei_mul_i32(INT32_MIN, 0, L), 0);
  TRAPS((void)ei_mul_i32(46341, 46341, L), OVF_MUL, L);
  TRAPS((void)ei_mul_i32(65536, 32768, L), OVF_MUL, L);
  TRAPS((void)ei_mul_i32(INT32_MIN, -1, L), OVF_MUL, L);
  TRAPS((void)ei_mul_i32(-1, INT32_MIN, L), OVF_MUL, L);
  EQI(ei_div_i32(-7, 2, L), -3);
  EQI(ei_div_i32(INT32_MIN, 1, L), INT32_MIN);
  EQI(ei_div_i32(INT32_MAX, -1, L), -INT32_MAX);
  TRAPS((void)ei_div_i32(1, 0, L), DIV0, L);
  TRAPS((void)ei_div_i32(INT32_MIN, -1, L), "integer overflow in /", L);
  EQI(ei_rem_i32(-7, 2, L), -1);
  EQI(ei_rem_i32(7, -2, L), 1);
  EQI(ei_rem_i32(INT32_MIN, 2, L), 0);
  TRAPS((void)ei_rem_i32(1, 0, L), REM0, L);
  TRAPS((void)ei_rem_i32(INT32_MIN, -1, L), "integer overflow in %", L);
  EQI(ei_neg_i32(INT32_MAX, L), -INT32_MAX);
  EQI(ei_neg_i32(0, L), 0);
  TRAPS((void)ei_neg_i32(INT32_MIN, L), "integer overflow in negation", L);
  EQI(ei_wadd_i32(INT32_MAX, 1), INT32_MIN);
  EQI(ei_wadd_i32(INT32_MIN, -1), INT32_MAX);
  EQI(ei_wadd_i32(-1, -1), -2);
  EQI(ei_wsub_i32(INT32_MIN, 1), INT32_MAX);
  EQI(ei_wsub_i32(INT32_MAX, -1), INT32_MIN);
  EQI(ei_wmul_i32(INT32_MIN, -1), INT32_MIN);
  EQI(ei_wmul_i32(65536, 65536), 0);
  EQI(ei_wmul_i32(INT32_MAX, 2), -2);
  EQI(ei_wmul_i32(-1, -1), 1);
  EQI(ei_wmul_i32(INT32_MIN, INT32_MIN), 0);
}

static void test_i64(void) {
  EQI(ei_add_i64(INT64_MAX - 1, 1, L), INT64_MAX);
  EQI(ei_add_i64(INT64_MIN, INT64_MAX, L), -1);
  EQI(ei_add_i64(INT64_MIN + 1, -1, L), INT64_MIN);
  TRAPS((void)ei_add_i64(INT64_MAX, 1, L), OVF_ADD, L);
  TRAPS((void)ei_add_i64(INT64_MIN, -1, L), OVF_ADD, L);
  TRAPS((void)ei_add_i64(INT64_MAX, INT64_MAX, L), OVF_ADD, L);
  EQI(ei_sub_i64(-1, INT64_MIN, L), INT64_MAX);
  EQI(ei_sub_i64(INT64_MIN + 1, 1, L), INT64_MIN);
  TRAPS((void)ei_sub_i64(INT64_MIN, 1, L), OVF_SUB, L);
  TRAPS((void)ei_sub_i64(INT64_MAX, -1, L), OVF_SUB, L);
  TRAPS((void)ei_sub_i64(0, INT64_MIN, L), OVF_SUB, L);
  EQI(ei_mul_i64(INT64_C(3037000499), INT64_C(3037000499), L), INT64_C(9223372030926249001));
  EQI(ei_mul_i64(INT64_C(4294967296), -INT64_C(2147483648), L), INT64_MIN);
  EQI(ei_mul_i64(INT64_MIN, 1, L), INT64_MIN);
  EQI(ei_mul_i64(1, INT64_MIN, L), INT64_MIN);
  EQI(ei_mul_i64(0, INT64_MIN, L), 0);
  EQI(ei_mul_i64(INT64_MIN, 0, L), 0);
  EQI(ei_mul_i64(-1, -INT64_MAX, L), INT64_MAX);
  EQI(ei_mul_i64(-3, -5, L), 15);
  TRAPS((void)ei_mul_i64(INT64_C(3037000500), INT64_C(3037000500), L), OVF_MUL, L);
  TRAPS((void)ei_mul_i64(-INT64_C(3037000500), INT64_C(3037000500), L), OVF_MUL, L);
  TRAPS((void)ei_mul_i64(INT64_C(3037000500), -INT64_C(3037000500), L), OVF_MUL, L);
  TRAPS((void)ei_mul_i64(-INT64_C(4294967296), -INT64_C(2147483648), L), OVF_MUL, L);
  TRAPS((void)ei_mul_i64(INT64_MIN, -1, L), OVF_MUL, L);
  TRAPS((void)ei_mul_i64(-1, INT64_MIN, L), OVF_MUL, L);
  TRAPS((void)ei_mul_i64(-2, -INT64_C(4611686018427387904), L), OVF_MUL, L);
  EQI(ei_div_i64(-7, 2, L), -3);
  EQI(ei_div_i64(INT64_MIN, 1, L), INT64_MIN);
  TRAPS((void)ei_div_i64(1, 0, L), DIV0, L);
  TRAPS((void)ei_div_i64(INT64_MIN, -1, L), "integer overflow in /", L);
  EQI(ei_rem_i64(-7, 2, L), -1);
  EQI(ei_rem_i64(INT64_MIN, 3, L), -2);
  TRAPS((void)ei_rem_i64(1, 0, L), REM0, L);
  TRAPS((void)ei_rem_i64(INT64_MIN, -1, L), "integer overflow in %", L);
  EQI(ei_neg_i64(INT64_MAX, L), -INT64_MAX);
  TRAPS((void)ei_neg_i64(INT64_MIN, L), "integer overflow in negation", L);
  EQI(ei_wadd_i64(INT64_MAX, 1), INT64_MIN);
  EQI(ei_wadd_i64(INT64_MIN, -1), INT64_MAX);
  EQI(ei_wsub_i64(INT64_MIN, 1), INT64_MAX);
  EQI(ei_wsub_i64(0, INT64_MIN), INT64_MIN);
  EQI(ei_wmul_i64(INT64_MIN, -1), INT64_MIN);
  EQI(ei_wmul_i64(INT64_MAX, 2), -2);
  EQI(ei_wmul_i64(INT64_C(4294967296), INT64_C(4294967296)), 0);
  EQI(ei_wmul_i64(-1, -1), 1);
}

static void test_u8(void) {
  EQU(ei_add_u8(254, 1, L), 255);
  TRAPS((void)ei_add_u8(255, 1, L), OVF_ADD, L);
  TRAPS((void)ei_add_u8(255, 255, L), OVF_ADD, L);
  EQU(ei_sub_u8(5, 5, L), 0);
  EQU(ei_sub_u8(255, 0, L), 255);
  TRAPS((void)ei_sub_u8(0, 1, L), OVF_SUB, L);
  EQU(ei_mul_u8(15, 17, L), 255);
  EQU(ei_mul_u8(0, 255, L), 0);
  TRAPS((void)ei_mul_u8(16, 16, L), OVF_MUL, L);
  TRAPS((void)ei_mul_u8(255, 255, L), OVF_MUL, L);
  EQU(ei_div_u8(255, 2, L), 127);
  TRAPS((void)ei_div_u8(1, 0, L), DIV0, L);
  EQU(ei_rem_u8(255, 7, L), 3);
  TRAPS((void)ei_rem_u8(1, 0, L), REM0, L);
  EQU(ei_wadd_u8(255, 1), 0);
  EQU(ei_wadd_u8(255, 255), 254);
  EQU(ei_wsub_u8(0, 1), 255);
  EQU(ei_wmul_u8(16, 16), 0);
  EQU(ei_wmul_u8(255, 255), 1);
}

static void test_u32(void) {
  EQU(ei_add_u32(UINT32_MAX - 1, 1, L), UINT32_MAX);
  TRAPS((void)ei_add_u32(UINT32_MAX, 1, L), OVF_ADD, L);
  TRAPS((void)ei_add_u32(UINT32_MAX, UINT32_MAX, L), OVF_ADD, L);
  EQU(ei_sub_u32(UINT32_MAX, UINT32_MAX, L), 0);
  TRAPS((void)ei_sub_u32(0, 1, L), OVF_SUB, L);
  TRAPS((void)ei_sub_u32(1, UINT32_MAX, L), OVF_SUB, L);
  EQU(ei_mul_u32(65535, 65537, L), UINT32_MAX);
  TRAPS((void)ei_mul_u32(65536, 65536, L), OVF_MUL, L);
  TRAPS((void)ei_mul_u32(UINT32_MAX, UINT32_MAX, L), OVF_MUL, L);
  EQU(ei_div_u32(UINT32_MAX, 2, L), 2147483647);
  TRAPS((void)ei_div_u32(1, 0, L), DIV0, L);
  EQU(ei_rem_u32(UINT32_MAX, 10, L), 5);
  TRAPS((void)ei_rem_u32(1, 0, L), REM0, L);
  EQU(ei_wadd_u32(UINT32_MAX, 1), 0);
  EQU(ei_wsub_u32(0, 1), UINT32_MAX);
  EQU(ei_wmul_u32(65536, 65536), 0);
  EQU(ei_wmul_u32(UINT32_MAX, UINT32_MAX), 1);
}

static void test_u64(void) {
  EQU(ei_add_u64(UINT64_MAX - 1, 1, L), UINT64_MAX);
  EQU(ei_add_u64(UINT64_MAX, 0, L), UINT64_MAX);
  TRAPS((void)ei_add_u64(UINT64_MAX, 1, L), OVF_ADD, L);
  TRAPS((void)ei_add_u64(1, UINT64_MAX, L), OVF_ADD, L);
  EQU(ei_sub_u64(UINT64_MAX, UINT64_MAX, L), 0);
  TRAPS((void)ei_sub_u64(0, 1, L), OVF_SUB, L);
  TRAPS((void)ei_sub_u64(1, UINT64_MAX, L), OVF_SUB, L);
  EQU(ei_mul_u64(UINT64_C(4294967295), UINT64_C(4294967297), L), UINT64_MAX);
  EQU(ei_mul_u64(0, UINT64_MAX, L), 0);
  EQU(ei_mul_u64(UINT64_MAX, 0, L), 0);
  EQU(ei_mul_u64(UINT64_MAX, 1, L), UINT64_MAX);
  TRAPS((void)ei_mul_u64(UINT64_C(4294967296), UINT64_C(4294967296), L), OVF_MUL, L);
  TRAPS((void)ei_mul_u64(UINT64_MAX, 2, L), OVF_MUL, L);
  EQU(ei_div_u64(UINT64_MAX, 2, L), INT64_MAX);
  TRAPS((void)ei_div_u64(1, 0, L), DIV0, L);
  EQU(ei_rem_u64(UINT64_MAX, 10, L), 5);
  TRAPS((void)ei_rem_u64(1, 0, L), REM0, L);
  EQU(ei_wadd_u64(UINT64_MAX, 1), 0);
  EQU(ei_wsub_u64(0, 1), UINT64_MAX);
  EQU(ei_wmul_u64(UINT64_C(4294967296), UINT64_C(4294967296)), 0);
  EQU(ei_wmul_u64(UINT64_MAX, UINT64_MAX), 1);
}

static void test_conv(void) {
  EQI(ei_s2s(INT32_MIN, INT32_MIN, INT32_MAX, L), INT32_MIN);
  EQI(ei_s2s(INT32_MAX, INT32_MIN, INT32_MAX, L), INT32_MAX);
  EQI(ei_s2s(INT64_MIN, INT64_MIN, INT64_MAX, L), INT64_MIN);
  TRAPS((void)ei_s2s((int64_t)INT32_MAX + 1, INT32_MIN, INT32_MAX, L), CONV, L);
  TRAPS((void)ei_s2s((int64_t)INT32_MIN - 1, INT32_MIN, INT32_MAX, L), CONV, L);
  EQU(ei_s2u(0, UINT8_MAX, L), 0);
  EQU(ei_s2u(255, UINT8_MAX, L), 255);
  EQU(ei_s2u(INT64_MAX, UINT64_MAX, L), INT64_MAX);
  TRAPS((void)ei_s2u(-1, UINT8_MAX, L), CONV, L);
  TRAPS((void)ei_s2u(256, UINT8_MAX, L), CONV, L);
  TRAPS((void)ei_s2u(INT64_MIN, UINT64_MAX, L), CONV, L);
  TRAPS((void)ei_s2u((int64_t)UINT32_MAX + 1, UINT32_MAX, L), CONV, L);
  EQI(ei_u2s(INT64_MAX, INT64_MAX, L), INT64_MAX);
  EQI(ei_u2s(INT32_MAX, INT32_MAX, L), INT32_MAX);
  TRAPS((void)ei_u2s((uint64_t)INT32_MAX + 1, INT32_MAX, L), CONV, L);
  TRAPS((void)ei_u2s(UINT64_MAX, INT64_MAX, L), CONV, L);
  TRAPS((void)ei_u2s((uint64_t)INT64_MAX + 1, INT64_MAX, L), CONV, L);
  EQU(ei_u2u(255, UINT8_MAX, L), 255);
  EQU(ei_u2u(UINT64_MAX, UINT64_MAX, L), UINT64_MAX);
  TRAPS((void)ei_u2u(256, UINT8_MAX, L), CONV, L);
  TRAPS((void)ei_u2u(UINT64_MAX, UINT32_MAX, L), CONV, L);
}

static void test_idx(void) {
  EQU(ei_idx(0, 1, L), 0);
  EQU(ei_idx(UINT64_MAX - 1, UINT64_MAX, L), UINT64_MAX - 1);
  TRAPS((void)ei_idx(1, 1, L), "index out of bounds", L);
  TRAPS((void)ei_idx(0, 0, L), "index out of bounds", L);
  TRAPS((void)ei_idx(UINT64_MAX, UINT64_MAX, L), "index out of bounds", L);
}

static int classify(int x) {
  switch (x & 1) {
    case 0: return 0;
    case 1: return 1;
  }
  ei_unreachable();
  return -1;
}

static void test_trap(void) {
  TRAPS(ei_trap("called `unwrap` on a None value", 42), "called `unwrap` on a None value", 42);
  TRAPS(ei_trap("", 0), "", 0);
  TRAPS(ei_trap("negative line", -1), "negative line", -1);
  EQI(classify(3), 1);
  /* stdout written before a trap is flushed before the report */
  cap_begin();
  ei_set_trap_jmp(&jb);
  if (setjmp(jb) == 0) {
    printf("partial ");
    ei_trap("boom", 1);
  }
  ei_set_trap_jmp(NULL);
  EQS(cap_end(), "partial FAILED\n    boom (rt_test:1)\n");
  /* a module's file index in the line (docs/compiler.md, "C8.16") */
  static const char *const files[3] = {0, "lib/m.ei", 0};
  ei_set_files(files, 3);
  cap_begin();
  ei_set_trap_jmp(&jb);
  if (setjmp(jb) == 0) ei_trap("in m", 1 * 1048576 + 12);
  ei_set_trap_jmp(NULL);
  EQS(cap_end(), "FAILED\n    in m (lib/m.ei:12)\n");
  /* no name for index 2, an index past the table, a plain line: the entry file as given */
  TRAPS(ei_trap("unnamed", 2 * 1048576 + 5), "unnamed", 2 * 1048576 + 5);
  TRAPS(ei_trap("past", 3 * 1048576 + 5), "past", 3 * 1048576 + 5);
  TRAPS(ei_trap("plain", 9), "plain", 9);
  ei_set_files(NULL, 0);
}

// ---- allocation and String

static void test_alloc(void) {
  unsigned char *p = ei_alloc(0);
  CHECK(p != NULL);
  free(p);
  uint64_t *q = ei_alloc_n(4, sizeof *q);
  for (int i = 0; i < 4; i++) q[i] = (uint64_t)i;
  EQU(q[3], 3);
  free(q);
  p = ei_alloc_n(3, 0);
  CHECK(p != NULL);
  free(p);
  p = ei_alloc_n(0, UINT64_MAX);
  CHECK(p != NULL);
  free(p);
  TRAPS((void)ei_alloc(UINT64_MAX), "out of memory", 0);
  TRAPS((void)ei_alloc_n(UINT64_MAX / 2 + 1, 2), "out of memory", 0);
  TRAPS((void)ei_alloc_n(2, UINT64_MAX), "out of memory", 0);
}

static void test_buf(void) {
  uint64_t *d = ei_buf_alloc(4, sizeof *d);
  EQU(ei_buf_count(d), 1);
  CHECK(!ei_buf_shared(d));
  CHECK((uintptr_t)d % sizeof(uint64_t) == 0);
  for (int i = 0; i < 4; i++) d[i] = (uint64_t)i * 10;
  ei_buf_inc(d);
  EQU(ei_buf_count(d), 2);
  CHECK(ei_buf_shared(d));
  CHECK(!ei_buf_dec(d));
  CHECK(!ei_buf_shared(d));
  d = ei_buf_grow(d, 1000, sizeof *d);
  EQU(d[3], 30);
  EQU(ei_buf_count(d), 1);
  d[999] = 7;
  CHECK(ei_buf_dec(d));
  ei_buf_free(d);
  /* NULL is an empty buffer: no holders, never shared */
  ei_buf_inc(NULL);
  CHECK(!ei_buf_dec(NULL));
  CHECK(!ei_buf_shared(NULL));
  EQU(ei_buf_count(NULL), 0);
  ei_buf_free(NULL);
  d = ei_buf_grow(NULL, 2, sizeof *d);
  EQU(ei_buf_count(d), 1);
  CHECK(ei_buf_dec(d));
  ei_buf_free(d);
  void *z = ei_buf_alloc(0, 8);
  CHECK(z != NULL);
  ei_buf_free(z);
  TRAPS((void)ei_buf_alloc(UINT64_MAX / 8, 8), "out of memory", 0);
  TRAPS((void)ei_buf_alloc(UINT64_MAX, 1), "out of memory", 0);
  z = ei_buf_alloc(1, 1);
  TRAPS((void)ei_buf_grow(z, UINT64_MAX / 2, 4), "out of memory", 0);
  ei_buf_free(z);
  /* amortised capacity */
  EQU(ei_grow_cap(0, 0, 1, 4), 4);
  EQU(ei_grow_cap(4, 4, 1, 4), 8);
  EQU(ei_grow_cap(8, 8, 1, 8), 16);
  EQU(ei_grow_cap(8, 5, 100, 4), 105);
  EQU(ei_grow_cap(UINT64_MAX / 2 + 1, 10, 1, 4), UINT64_MAX); /* doubling saturates (and then cannot be allocated) */
  EQU(ei_grow_cap(UINT64_MAX - 1, UINT64_MAX - 1, 1, 0), UINT64_MAX);
  TRAPS((void)ei_grow_cap(0, UINT64_MAX, 1, 0), "out of memory", 0);
  TRAPS((void)ei_grow_cap(0, 5, UINT64_MAX - 4, 0), "out of memory", 0);
}

static void test_string(void) {
  ei_String s = ei_str_from("");
  EQU(s.len, 0);
  EQS(s.p, "");
  ei_str_push(&s, "ab");
  ei_str_push(&s, "");
  ei_str_cat(&s, "cdXYZ", 2);
  EQU(s.len, 4);
  EQS(s.p, "abcd");
  ei_String t = ei_share_String(&s);
  CHECK(t.p == s.p); /* a copy shares the buffer */
  EQU(ei_buf_count(s.p), 2);
  ei_str_append(&t, &s); /* ...until one side changes */
  CHECK(t.p != s.p);
  EQU(ei_buf_count(s.p), 1);
  EQU(ei_buf_count(t.p), 1);
  EQS(s.p, "abcd");
  EQS(t.p, "abcdabcd");
  EQU(t.len, 8);
  ei_str_append(&t, &t); /* self-append: the source is read before the old buffer is freed */
  EQS(t.p, "abcdabcdabcdabcd");
  EQU(t.len, 16);
  ei_str_cat(&t, t.p + 14, 2);
  EQS(t.p, "abcdabcdabcdabcdcd");
  ei_drop_String(&t);
  CHECK(t.p == NULL);
  EQU(t.len, 0);
  TRAPS(ei_str_cat(&s, "x", UINT64_MAX), "out of memory", 0);
  TRAPS(ei_str_cat(&s, "x", UINT64_MAX - 4), "out of memory", 0);
  EQS(s.p, "abcd"); /* unchanged by the failed appends */
  ei_drop_String(&s);
  ei_drop_String(&s); /* dropping twice is harmless (free(NULL)) */

  /* appends grow the capacity geometrically: n appends of one byte move the text O(log n) times */
  ei_String g = ei_str_from("");
  uint64_t moves = 0;
  for (int i = 0; i < 100000; i++) {
    const char *before = g.p;
    ei_str_push(&g, "x");
    if (g.p != before) moves++;
  }
  EQU(g.len, 100000);
  CHECK(g.cap >= g.len);
  CHECK(moves < 20);
  CHECK(g.p[g.len] == 0);
  /* a shared String is copied on its first change, then changed in place */
  ei_String h = ei_share_String(&g);
  ei_str_push(&h, "y");
  EQU(g.len, 100000);
  EQU(h.len, 100001);
  CHECK(g.p[g.len] == 0 && h.p[h.len - 1] == 'y');
  ei_String u = ei_share_String(&h);
  ei_str_unique(&u);
  CHECK(u.p != h.p && strcmp(u.p, h.p) == 0);
  ei_str_unique(&u); /* already its own: no copy */
  EQU(ei_buf_count(u.p), 1);
  ei_drop_String(&u);
  /* ei_clone_String is a copy with its own buffer (what code from before C8.1 calls) */
  ei_String v = ei_clone_String(&h);
  CHECK(v.p != h.p && strcmp(v.p, h.p) == 0 && v.len == h.len);
  EQU(ei_buf_count(h.p), 1);
  EQU(ei_buf_count(v.p), 1);
  ei_drop_String(&v);
  ei_drop_String(&h);
  ei_drop_String(&g);
  /* appending to a dropped (empty) String allocates */
  ei_str_push(&g, "");
  EQS(g.p, "");
  ei_drop_String(&g);

  const int64_t vals[] = {0, -1, 42, INT64_MAX, INT64_MIN};
  const char *want[] = {"0", "-1", "42", "9223372036854775807", "-9223372036854775808"};
  for (int i = 0; i < 5; i++) {
    ei_String n = ei_str_from_i64(vals[i]);
    check(strcmp(n.p, want[i]) == 0 && n.len == strlen(want[i]), want[i], __LINE__);
    ei_drop_String(&n);
  }
}

static void test_hash(void) {
  EQU(ei_hash_u64(0), 0);
  /* recorded hash values: Map layout must not change */
  EQU(ei_hash_u64(1), UINT64_C(0xb456bcfc34c2cb2c));
  EQU(ei_hash_u64(UINT64_MAX), UINT64_C(0x64b5720b4b825f21));
  EQU(ei_hash_str(""), UINT64_C(0xd725c98e9509182e));
  EQU(ei_hash_str("eider"), UINT64_C(0xe8e45c916e9fea30));
  EQU(ei_hash_str("\xff"), UINT64_C(0x37e2aaefca88ac51));
  EQU(ei_hash_str("ab\0cd"), ei_hash_str("ab"));
}

static void test_print(void) {
  cap_begin();
  ei_print_i(0);
  ei_print_i(-42);
  ei_print_i(INT64_MIN);
  ei_print_i(INT64_MAX);
  ei_print_u(0);
  ei_print_u(UINT64_MAX);
  ei_print_b(true);
  ei_print_b(false);
  ei_print_s("");
  ei_print_s("hi there %d");
  EQS(cap_end(),
      "0\n-42\n-9223372036854775808\n9223372036854775807\n0\n18446744073709551615\n"
      "true\nfalse\n\nhi there %d\n");
}


/* Floats (docs/decisions.md C660): the printer is exact. For hundreds of thousands of bit
   patterns the text reads back (strtod, exact) as the same value, and no shorter text does;
   {x:.N} is the exact value rounded like printf's. */
static void fstr(char *b, size_t cap_, double v) {
  ei_String s = ei_str_from("");
  ei_str_push_f64(&s, v);
  snprintf(b, cap_, "%s", s.p);
  ei_drop_String(&s);
}

static uint64_t rng_state = 88172645463325252ull;
static uint64_t rng(void) {
  rng_state ^= rng_state << 13;
  rng_state ^= rng_state >> 7;
  rng_state ^= rng_state << 17;
  return rng_state;
}

static int sig_digits(const char *b) {
  int digits = 0, started = 0, last_nz = 0;
  for (const char *c = b; *c && *c != 'e'; c++) {
    if (*c < '0' || *c > '9') continue;
    if (*c != '0') started = 1;
    if (started) {
      digits++;
      if (*c != '0') last_nz = digits;
    }
  }
  return last_nz > 0 ? last_nz : 1;
}

static void test_float_text(void) {
  char b[64];
  struct {
    double v;
    const char *t;
  } fixed[] = {
      {0.0, "0.0"},
      {-0.0, "-0.0"},
      {1.0, "1.0"},
      {1.5, "1.5"},
      {0.1, "0.1"},
      {0.3, "0.3"},
      {100.0, "100.0"},
      {1e15, "1000000000000000.0"},
      {1e16, "1e16"},
      {1.5e300, "1.5e300"},
      {1e-5, "0.00001"},
      {1e-6, "1e-6"},
      {123456.789, "123456.789"},
      {5e-324, "5e-324"},
      {1.7976931348623157e308, "1.7976931348623157e308"},
      {0.1 + 0.2, "0.30000000000000004"},
      {9007199254740993.0, "9007199254740992.0"},
      {-2.5, "-2.5"},
      {1.0 / 3.0, "0.3333333333333333"},
      {2.2250738585072014e-308, "2.2250738585072014e-308"},
  };
  for (size_t i = 0; i < sizeof fixed / sizeof fixed[0]; i++) {
    fstr(b, sizeof b, fixed[i].v);
    CHECK(strcmp(b, fixed[i].t) == 0);
  }
  fstr(b, sizeof b, 1.0 / 0.0);
  CHECK(strcmp(b, "inf") == 0);
  fstr(b, sizeof b, -1.0 / 0.0);
  CHECK(strcmp(b, "-inf") == 0);
  fstr(b, sizeof b, 0.0 / 0.0);
  CHECK(strcmp(b, "NaN") == 0);
  /* round trip and shortest, over random bit patterns (finite ones) */
  int bad = 0;
  for (int n = 0; n < 200000; n++) {
    uint64_t bits = rng();
    if (n % 4 == 0) bits = (bits & ~(0x7ffull << 52)) | ((uint64_t)(1000 + rng() % 48) << 52);
    double v;
    memcpy(&v, &bits, 8);
    if (v != v || v - v != 0) continue;
    fstr(b, sizeof b, v);
    if (strtod(b, NULL) != v) {
      bad++;
      continue;
    }
    int digits = sig_digits(b);
    if (digits > 1) {
      char t[64];
      snprintf(t, sizeof t, "%.*e", digits - 2, v);
      if (strtod(t, NULL) == v) bad++;
    }
  }
  CHECK(bad == 0);
  bad = 0;
  for (int n = 0; n < 100000; n++) {
    uint32_t bits = (uint32_t)rng();
    float v;
    memcpy(&v, &bits, 4);
    if (v != v || v - v != 0) continue;
    ei_String s = ei_str_from("");
    ei_str_push_f32(&s, v);
    snprintf(b, sizeof b, "%s", s.p);
    ei_drop_String(&s);
    if (strtof(b, NULL) != v) bad++;
  }
  CHECK(bad == 0);
  /* {x:.N}: the exact value rounded half to even, as printf does */
  bad = 0;
  for (int n = 0; n < 50000; n++) {
    uint64_t bits = rng();
    if (n % 2) bits = (bits & ~(0x7ffull << 52)) | ((uint64_t)(1023 - 10 + rng() % 40) << 52);
    double v;
    memcpy(&v, &bits, 8);
    if (v != v || v - v != 0) continue;
    unsigned prec = (unsigned)(rng() % 20);
    ei_String s = ei_str_from("");
    ei_str_fmt_f64(&s, v, (1ull << 63) | ((uint64_t)prec << 52) | (1ull << 40));
    char want[512];
    snprintf(want, sizeof want, "%.*f", (int)prec, v);
    if (strcmp(s.p, want) != 0) {
      bad++;
      if (bad < 4) fprintf(stderr, "fixed: %s vs %s\n", s.p, want);
    }
    ei_drop_String(&s);
  }
  CHECK(bad == 0);
}

static void test_clock(void) {
  uint64_t a = ei_now_ms();
  volatile uint64_t spin = 0;
  for (uint64_t i = 0; i < 20000000; i++) spin = spin + i;
  uint64_t b = ei_now_ms();
  CHECK(b >= a);
  /* a wall-clock (monotonic) measure: it advances while the program sleeps */
  struct timespec t = {0, 60 * 1000000};
  nanosleep(&t, NULL);
  uint64_t c = ei_now_ms();
  CHECK(c - b >= 50);
}

// ---- the exit path (no hook), in forked children

/* Runs fn in a child with stdout+stderr on a pipe; returns its exit status, output in buf. */
static int in_child(void (*fn)(void), char *buf, size_t cap_n) {
  int fds[2];
  if (pipe(fds) != 0) { perror("pipe"); exit(2); }
  fflush(stdout);
  fflush(stderr);
  pid_t pid = fork();
  if (pid < 0) { perror("fork"); exit(2); }
  if (pid == 0) {
    close(fds[0]);
    dup2(fds[1], 1);
    dup2(fds[1], 2);
    close(fds[1]);
    fn();
    _exit(0);
  }
  close(fds[1]);
  size_t n = 0;
  ssize_t r;
  while (n < cap_n - 1 && (r = read(fds[0], buf + n, cap_n - 1 - n)) > 0) n += (size_t)r;
  buf[n] = 0;
  close(fds[0]);
  int status = 0;
  waitpid(pid, &status, 0);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static void child_trap(void) {
  printf("out ");
  ei_trap("boom", 3);
}

static void child_overflow(void) { (void)ei_add_i32(INT32_MAX, 1, 12); }

static void *trap_worker(void *arg) {
  (void)arg;
  ei_trap("from a thread", 5);
}

/* Several threads trap at once: exactly one report, exit 101. */
static void child_many(void) {
  pthread_t th[8];
  for (int i = 0; i < 8; i++) pthread_create(&th[i], NULL, trap_worker, NULL);
  for (int i = 0; i < 8; i++) pthread_join(th[i], NULL);
}

/* The hook is per thread: a trap on a thread without one exits even inside a test. */
static void child_hook_is_per_thread(void) {
  jmp_buf mine;
  ei_set_trap_jmp(&mine);
  if (setjmp(mine) == 0) {
    pthread_t th;
    pthread_create(&th, NULL, trap_worker, NULL);
    pthread_join(th, NULL);
  }
  printf("main thread caught it\n");
}

static void test_exit_path(void) {
  char buf[4096];
  EQI(in_child(child_trap, buf, sizeof buf), 101);
  EQS(buf, "out eider: runtime error: boom (rt_test:3)\n");
  EQI(in_child(child_overflow, buf, sizeof buf), 101);
  EQS(buf, "eider: runtime error: integer overflow in + (rt_test:12)\n");
  EQI(in_child(child_many, buf, sizeof buf), 101);
  EQS(buf, "eider: runtime error: from a thread (rt_test:5)\n");
  EQI(in_child(child_hook_is_per_thread, buf, sizeof buf), 101);
  EQS(buf, "eider: runtime error: from a thread (rt_test:5)\n");
}

// ---- threads

static void test_rc(void) {
  ei_rc rc;
  ei_rc_init(&rc);
  ei_rc_inc(&rc);
  CHECK(!ei_rc_dec(&rc));
  CHECK(ei_rc_dec(&rc));
}

typedef struct {
  ei_mutex *mu;
  ei_rc *rc;
  int64_t *counter;
  int lasts;
} shared;

static void *bump(void *arg) {
  shared *s = arg;
  for (int i = 0; i < 20000; i++) {
    ei_mutex_lock(s->mu);
    *s->counter += 1;
    ei_mutex_unlock(s->mu);
    ei_rc_inc(s->rc);
    if (ei_rc_dec(s->rc)) s->lasts++;
  }
  return NULL;
}

static void test_mutex_and_threads(void) {
  ei_mutex mu;
  ei_mutex_init(&mu);
  ei_rc rc;
  ei_rc_init(&rc);
  int64_t counter = 0;
  shared s[8];
  ei_thread th[8];
  for (int i = 0; i < 8; i++) {
    s[i] = (shared){&mu, &rc, &counter, 0};
    ei_thread_start(&th[i], bump, &s[i]);
  }
  for (int i = 0; i < 8; i++) {
    if (i % 2) ei_thread_join(&th[i]); /* odd ones joined explicitly, all destroyed */
    ei_thread_destroy(&th[i]);
  }
  EQI(counter, 8 * 20000);
  int lasts = 0;
  for (int i = 0; i < 8; i++) lasts += s[i].lasts;
  EQI(lasts, 0);
  CHECK(ei_rc_dec(&rc));
  /* relocking a mutex this thread holds traps (error-checking mutex), it doesn't hang */
  ei_mutex_lock(&mu);
  TRAPS(ei_mutex_lock(&mu), "cannot lock a mutex", 0);
  ei_mutex_unlock(&mu);
  ei_mutex_destroy(&mu);
}

static ei_chan *wait_chan;

static void *slow(void *arg) {
  int64_t got = 0;
  if (ei_chan_recv(wait_chan, &got)) *(int64_t *)arg = got;
  return NULL;
}

static void *joiner(void *arg) {
  ei_thread_join(arg);
  return NULL;
}

/* Two threads join the same thread concurrently; it is joined once. */
static void test_concurrent_join(void) {
  ei_chan c;
  ei_chan_init(&c, sizeof(int64_t));
  wait_chan = &c;
  int64_t result = 0;
  ei_thread worker, j1, j2;
  ei_thread_start(&worker, slow, &result);
  ei_thread_start(&j1, joiner, &worker);
  ei_thread_start(&j2, joiner, &worker);
  int64_t v = 99;
  ei_chan_send(&c, &v);
  ei_thread_destroy(&j1);
  ei_thread_destroy(&j2);
  CHECK(worker.joined);
  ei_thread_destroy(&worker);
  EQI(result, 99);
  ei_chan_destroy(&c);
}

typedef struct { uint32_t id; int64_t seq; char tag[13]; } msg;
static ei_chan *mpsc;

static void *producer(void *arg) {
  uint32_t id = *(uint32_t *)arg;
  for (int64_t i = 0; i < 5000; i++) {
    msg m = {id, i, "payload"};
    ei_chan_send(mpsc, &m);
  }
  return NULL;
}

static void test_chan_threads(void) {
  ei_chan c;
  ei_chan_init(&c, sizeof(msg));
  mpsc = &c;
  uint32_t ids[4] = {0, 1, 2, 3};
  ei_thread th[4];
  for (int i = 0; i < 4; i++) ei_thread_start(&th[i], producer, &ids[i]);
  int64_t next[4] = {0, 0, 0, 0};
  int in_order = 1;
  for (int n = 0; n < 4 * 5000; n++) {
    msg m;
    if (!ei_chan_recv(&c, &m) || m.id > 3) { in_order = 0; break; }
    if (m.seq != next[m.id] || strcmp(m.tag, "payload") != 0) in_order = 0;
    next[m.id]++;
  }
  CHECK(in_order); /* FIFO per producer, nothing lost or torn */
  for (int i = 0; i < 4; i++) ei_thread_destroy(&th[i]);
  ei_chan_close(&c);
  msg m;
  CHECK(!ei_chan_recv(&c, &m));
  ei_chan_destroy(&c);

  /* close wakes a blocked receiver */
  ei_chan w;
  ei_chan_init(&w, sizeof(int64_t));
  wait_chan = &w;
  int64_t result = -5;
  ei_thread r;
  ei_thread_start(&r, slow, &result);
  ei_chan_close(&w);
  ei_thread_destroy(&r);
  EQI(result, -5);
  ei_chan_destroy(&w);
}

static void test_chan_single(void) {
  ei_chan c;
  ei_chan_init(&c, sizeof(int64_t));
  int64_t v, got = 0;
  /* wrap around, then grow while wrapped: order is kept */
  for (v = 1; v <= 3; v++) ei_chan_send(&c, &v);
  CHECK(ei_chan_recv(&c, &got) && got == 1);
  CHECK(ei_chan_recv(&c, &got) && got == 2);
  for (v = 4; v <= 9; v++) ei_chan_send(&c, &v);
  EQU(ei_chan_len(&c), 7);
  EQU(c.cap, 8);
  int ok = 1;
  for (uint64_t i = 0; i < ei_chan_len(&c); i++) ok &= *(int64_t *)ei_chan_at(&c, i) == (int64_t)i + 3;
  CHECK(ok);
  for (int64_t want = 3; want <= 9; want++) ok &= ei_chan_recv(&c, &got) && got == want;
  CHECK(ok);
  EQU(ei_chan_len(&c), 0);
  /* send after close traps (and leaves the channel usable for draining) */
  v = 10;
  ei_chan_send(&c, &v);
  ei_chan_close(&c);
  ei_chan_close(&c);
  TRAPS(ei_chan_send(&c, &v), "send on a closed channel", 0);
  CHECK(ei_chan_recv(&c, &got) && got == 10);
  CHECK(!ei_chan_recv(&c, &got));
  ei_chan_destroy(&c);

  /* zero-size elements (Chan of an empty record) */
  ei_chan z;
  ei_chan_init(&z, 0);
  char dummy = 0;
  for (int i = 0; i < 10; i++) ei_chan_send(&z, &dummy);
  EQU(ei_chan_len(&z), 10);
  for (int i = 0; i < 10; i++) ok &= ei_chan_recv(&z, &dummy);
  CHECK(ok);
  ei_chan_close(&z);
  CHECK(!ei_chan_recv(&z, &dummy));
  ei_chan_destroy(&z);

  /* destroying a channel that still holds elements (the caller drops them via ei_chan_at) */
  ei_chan d;
  ei_chan_init(&d, sizeof(char *));
  for (int i = 0; i < 5; i++) {
    char *p = ei_alloc(16);
    ei_chan_send(&d, &p);
  }
  for (uint64_t i = 0; i < ei_chan_len(&d); i++) free(*(char **)ei_chan_at(&d, i));
  ei_chan_destroy(&d);
}

// ---- atomics

static ei_atomic_i64 counter;

static void *adder(void *arg) {
  int32_t order = *(int32_t *)arg;
  for (int i = 0; i < 20000; i++) ei_atomic_add(&counter, 1, order);
  return NULL;
}

/* counts with compare-and-swap only: every failure returns the value seen, retried */
static void *cas_adder(void *arg) {
  (void)arg;
  for (int i = 0; i < 20000; i++) {
    int64_t seen = ei_atomic_load(&counter, 0);
    for (;;) {
      int64_t got = ei_atomic_cas(&counter, seen, seen + 1, 3);
      if (got == seen) break;
      seen = got;
    }
  }
  return NULL;
}

/* message passing: the release store publishes `payload`, the acquire load sees it */
static ei_atomic_i64 flag;
static int64_t payload;

static void *publisher(void *arg) {
  (void)arg;
  payload = 42;
  ei_atomic_store(&flag, 1, 2);
  return NULL;
}

static void test_atomics(void) {
  ei_atomic_i64 a;
  ei_atomic_init(&a, 5);
  for (int32_t o = -1; o <= 6; o++) EQI(ei_atomic_load(&a, o), 5); /* every number is valid */
  ei_atomic_store(&a, -7, 2);
  EQI(ei_atomic_load(&a, 1), -7);
  ei_atomic_store(&a, 9, 1); /* acquire on a store: strengthened, not undefined */
  EQI(ei_atomic_swap(&a, 11, 4), 9);
  EQI(ei_atomic_add(&a, 4, 0), 11);
  EQI(ei_atomic_add(&a, -20, 3), 15);
  EQI(ei_atomic_load(&a, 4), -5);
  EQI(ei_atomic_cas(&a, -5, 100, 4), -5); /* success: returns expected */
  EQI(ei_atomic_load(&a, 4), 100);
  EQI(ei_atomic_cas(&a, -5, 200, 1), 100); /* failure: returns what was there, no change */
  EQI(ei_atomic_load(&a, 4), 100);
  ei_atomic_store(&a, INT64_MAX, 4);
  EQI(ei_atomic_add(&a, 1, 4), INT64_MAX); /* wraps (defined for atomic types) */
  EQI(ei_atomic_load(&a, 4), INT64_MIN);

  for (int32_t order = 0; order <= 4; order++) {
    ei_atomic_init(&counter, 0);
    int32_t ords[8];
    ei_thread th[8];
    for (int i = 0; i < 8; i++) {
      ords[i] = order;
      ei_thread_start(&th[i], i % 2 ? adder : cas_adder, &ords[i]);
    }
    for (int i = 0; i < 8; i++) ei_thread_destroy(&th[i]);
    EQI(ei_atomic_load(&counter, 4), 8 * 20000);
  }
  for (int round = 0; round < 50; round++) {
    ei_atomic_init(&flag, 0);
    payload = 0;
    ei_thread p;
    ei_thread_start(&p, publisher, NULL);
    while (ei_atomic_load(&flag, 1) == 0) {}
    EQI(payload, 42);
    ei_thread_destroy(&p);
  }
}

// ---- stack overflow on a runtime thread

static volatile int64_t sink;
static volatile int64_t depth_limit = INT64_MAX;

/* recursion that no compiler turns into a loop: each frame keeps a buffer alive */
static int64_t deep(int64_t n) {
  volatile char buf[512];
  if (n >= depth_limit) return 0;
  buf[n % 512] = (char)n;
  int64_t r = deep(n + 1) + buf[(n + 1) % 512];
  sink = r;
  return r;
}

static void *overflow_worker(void *arg) {
  (void)arg;
  sink = deep(0);
  return NULL;
}

static void child_stack_overflow(void) {
  printf("before\n"); /* buffered (stdout is a pipe): the handler flushes it */
  ei_thread t;
  ei_thread_start(&t, overflow_worker, NULL);
  ei_thread_join(&t);
}

static void *small_frames(void *arg) {
  /* half a megabyte of frames is well within the stack */
  int64_t *n = arg;
  volatile char buf[4096];
  buf[0] = (char)*n;
  if (*n > 0) {
    int64_t m = *n - 1;
    small_frames(&m);
  }
  sink = buf[0];
  return NULL;
}

/* a segfault that is not a stack overflow is left alone: the handler that was there before
   (a sanitizer's), else the default action, SIGSEGV. Address 16, not NULL: UBSan would
   catch a null write itself. */
static void *bad_write(void *arg) {
  (void)arg;
  volatile int *volatile p = (volatile int *)(uintptr_t)16;
  *p = 1;
  return NULL;
}

static void child_bad_write(void) {
  ei_thread t;
  ei_thread_start(&t, bad_write, NULL);
  ei_thread_join(&t);
}

/* ei_main, the program entry: the body runs on a guarded runtime thread, with the signal
   mask of the caller, and its result is the exit code; an overflow there is a trap too. */
static sigset_t main_mask;
static int main_body_ok(void) {
  sigset_t now;
  pthread_sigmask(SIG_SETMASK, NULL, &now);
  /* the caller blocked SIGUSR1 (and nothing else): the body has the same mask */
  if (sigismember(&now, SIGUSR1) != 1 || sigismember(&now, SIGUSR2) != 0) return 1;
  int64_t n = 120;
  small_frames(&n);
  return 42;
}
static int main_body_deep(void) {
  printf("before\n");
  sink = deep(0);
  return 0;
}
static void child_main_overflow(void) { exit(ei_main(main_body_deep)); }

static void test_main_entry(void) {
  sigset_t one;
  sigemptyset(&one);
  sigaddset(&one, SIGUSR1);
  pthread_sigmask(SIG_BLOCK, &one, &main_mask);
  EQI(ei_main(main_body_ok), 42);
  /* and the caller's mask is back */
  sigset_t now;
  pthread_sigmask(SIG_SETMASK, NULL, &now);
  EQI(sigismember(&now, SIGUSR1), 1);
  EQI(sigismember(&now, SIGUSR2), 0);
  pthread_sigmask(SIG_SETMASK, &main_mask, NULL);
  char buf[8192];
  EQI(in_child(child_main_overflow, buf, sizeof buf), 101);
  EQS(buf, "before\neider: runtime error: stack overflow (rt_test:0)\n");
}

static void test_stack_overflow(void) {
  /* deep but bounded recursion works, and a thread's stack is released at the join */
  for (int i = 0; i < 20; i++) {
    int64_t n = 120;
    ei_thread t;
    ei_thread_start(&t, small_frames, &n);
    ei_thread_destroy(&t);
    CHECK(t.map == NULL);
  }
#if defined(__SANITIZE_ADDRESS__) || defined(__SANITIZE_THREAD__)
#define EI_TEST_SANITIZED 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer) || __has_feature(thread_sanitizer)
#define EI_TEST_SANITIZED 1
#endif
#endif
  /* the overflow is ours even under the sanitizers (their SIGSEGV handler was installed
     first, so it is the one a foreign fault is passed on to) */
  char buf[8192];
  EQI(in_child(child_stack_overflow, buf, sizeof buf), 101);
  EQS(buf, "before\neider: runtime error: stack overflow (rt_test:0)\n");
  int st = in_child(child_bad_write, buf, sizeof buf);
#if defined(EI_TEST_SANITIZED)
  CHECK(st != 0 && st != 101 && strstr(buf, "SEGV") != NULL); /* the sanitizer's report */
#else
  EQI(st, 128 + SIGSEGV);
  EQS(buf, "");
#endif
}

int main(void) {
  ei_set_file("rt_test");
  test_bits();
  test_i32();
  test_i64();
  test_u8();
  test_u32();
  test_u64();
  test_conv();
  test_idx();
  test_trap();
  test_alloc();
  test_buf();
  test_string();
  test_hash();
  test_print();
  test_float_text();
  test_clock();
  test_exit_path();
  test_rc();
  test_mutex_and_threads();
  test_concurrent_join();
  test_chan_threads();
  test_chan_single();
  test_atomics();
  test_stack_overflow();
  test_main_entry();
  printf("%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
