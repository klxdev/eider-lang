// eider_rt for WebAssembly: the language runtime (core/RUNTIME.md) as a backend for wasm32,
// over the freestanding libc in core/wasm/libc.c. Contract and limits: core/wasm/README.md.
//
// The same functions as core/eider_rt.c, declared by the same core/eider_rt.h. What differs:
//   - one thread: no trap lock, ei_mutex_* do nothing, and ei_thread_* / ei_chan_* trap
//     (E0806 rejects programs that use threads, so generated code never calls them);
//   - a trap prints its message through env.eider_write and executes `unreachable`, which
//     the host sees as a trap (a RuntimeError in JavaScript) instead of exit(101);
//   - ei_now_ms is the host's clock (env.eider_now_ms), not processor time.
// A core module (-DEI_WASM_CORE: `eiderc build --wasm-core`, README.md "Core modules") is a
// program instead: its imports are the C core's ABI (env.ec_*), a trap exits with 101 through
// ec_exit, ei_now_ms is ec_time_mono_ns, and `_start` runs main.
// Allocation, String, hashing and print are the text of core/eider_rt.c.
#include "../eider_rt.h"

#include <stdio.h>

#include "host.h"

// ---- traps

static const char *trap_file;
static jmp_buf *trap_jmp;

static const char *const *trap_files;
static int32_t trap_nfiles;

void ei_set_file(const char *file) { trap_file = file; }
void ei_set_files(const char *const *files, int32_t n) {
  trap_files = files;
  trap_nfiles = n;
}
void ei_set_trap_jmp(jmp_buf *jb) { trap_jmp = jb; }

_Noreturn void ei_trap(const char *msg, int32_t line) {
  const char *file = trap_file ? trap_file : "";
  int32_t f = line > 0 ? line >> 20 : 0;
  if (f > 0 && f < trap_nfiles && trap_files && trap_files[f]) {
    file = trap_files[f];
    line &= 0xFFFFF;
  }
  if (trap_jmp) {
    printf("FAILED\n    %s (%s:%" PRId32 ")\n", msg, file, line);
    longjmp(*trap_jmp, 1);
  }
  fprintf(stderr, "eider: runtime error: %s (%s:%" PRId32 ")\n", msg, file, line);
  ei_host_leave(101);
}

// ---- allocation

#ifdef EI_RT_COUNT_ALLOCS
static int_least64_t live_allocs;
#endif

void *ei_alloc(uint64_t n) {
#if SIZE_MAX < UINT64_MAX
  if (n > SIZE_MAX) ei_trap("out of memory", 0);
#endif
  void *p = malloc(n ? (size_t)n : 1);
  if (!p) ei_trap("out of memory", 0);
#ifdef EI_RT_COUNT_ALLOCS
  live_allocs++;
#endif
  return p;
}

void ei_free(void *p) {
  if (!p) return;
#ifdef EI_RT_COUNT_ALLOCS
  live_allocs--;
#endif
  free(p);
}

void ei_check_leaks(void) {
#ifdef EI_RT_COUNT_ALLOCS
  fprintf(stderr, "eider: outstanding allocations: %" PRIdLEAST64 "\n", live_allocs);
#endif
}

void *ei_alloc_n(uint64_t n, uint64_t size) {
  if (size != 0 && n > UINT64_MAX / size) ei_trap("out of memory", 0);
  return ei_alloc(n * size);
}

// ---- shared buffers (copy-on-write; the counts are in eider_rt.h)

void *ei_buf_alloc(uint64_t n, uint64_t size) {
  if (size != 0 && n > (UINT64_MAX - sizeof(ei_buf_hdr)) / size) ei_trap("out of memory", 0);
  ei_buf_hdr *h = ei_alloc(sizeof *h + n * size);
  h->n = 1;
  h->unused = 0;
  return h + 1;
}

void *ei_buf_grow(void *d, uint64_t n, uint64_t size) {
  if (!d) return ei_buf_alloc(n, size);
  if (size != 0 && n > (UINT64_MAX - sizeof(ei_buf_hdr)) / size) ei_trap("out of memory", 0);
  uint64_t b = sizeof(ei_buf_hdr) + n * size;
#if SIZE_MAX < UINT64_MAX
  if (b > SIZE_MAX) ei_trap("out of memory", 0);
#endif
  /* still one allocation, so the allocation counter does not change */
  ei_buf_hdr *h = realloc(ei_buf_h(d), b ? (size_t)b : 1);
  if (!h) ei_trap("out of memory", 0);
  return h + 1;
}

void ei_buf_free(void *d) {
  if (d) ei_free(ei_buf_h(d));
}

uint64_t ei_grow_cap(uint64_t cap, uint64_t len, uint64_t extra, uint64_t min) {
  if (extra > UINT64_MAX - len) ei_trap("out of memory", 0);
  uint64_t need = len + extra;
  uint64_t c = cap <= UINT64_MAX / 2 ? cap * 2 : UINT64_MAX;
  if (c < need) c = need;
  if (c < min) c = min;
  return c;
}

/* In-place List operations (docs/compiler.md "C8.49"). The caller owns the buffer (it made it
   unique). ei_list_open opens a gap of n elements at index `at` (<= *len): grows the buffer
   if needed, moves the tail up and adds n to *len; the gap is uninitialised. ei_list_close
   removes the n elements at `at` (already moved out or dropped) and moves the tail down. */
void ei_list_open(void **data, uint64_t *len, uint64_t *cap, uint64_t at, uint64_t n, uint64_t size) {
  if (n > *cap - *len) {
    uint64_t nc = ei_grow_cap(*cap, *len, n, 4);
    *data = ei_buf_grow(*data, nc, size);
    *cap = nc;
  }
  if (size != 0 && at < *len) memmove((char *)*data + (size_t)((at + n) * size), (char *)*data + (size_t)(at * size), (size_t)((*len - at) * size));
  *len += n;
}

void ei_list_close(void *data, uint64_t *len, uint64_t at, uint64_t n, uint64_t size) {
  if (size != 0 && at + n < *len) memmove((char *)data + (size_t)(at * size), (char *)data + (size_t)((at + n) * size), (size_t)((*len - at - n) * size));
  *len -= n;
}

// ---- String

/* A new String holding t[0..tl) with room for cap bytes (cap >= tl). */
static ei_String str_new(const char *t, uint64_t tl, uint64_t cap) {
  if (cap == UINT64_MAX) ei_trap("out of memory", 0);
  ei_String r;
  r.p = ei_buf_alloc(cap + 1, 1);
  if (tl) memcpy(r.p, t, (size_t)tl);
  r.p[tl] = 0;
  r.len = tl;
  r.cap = cap;
  return r;
}

ei_String ei_str_from(const char *s) {
  uint64_t n = (uint64_t)strlen(s);
  return str_new(s, n, n);
}

ei_String ei_str_from_i64(int64_t v) {
  char buf[32];
  snprintf(buf, sizeof buf, "%" PRId64, v);
  return ei_str_from(buf);
}

void ei_drop_String(ei_String *s) {
  if (ei_buf_dec(s->p)) ei_buf_free(s->p);
  s->p = NULL;
  s->len = 0;
  s->cap = 0;
}

ei_String ei_share_String(const ei_String *s) {
  ei_String r = *s;
  ei_buf_inc(r.p);
  return r;
}

ei_String ei_clone_String(const ei_String *s) { return str_new(s->p, s->len, s->len); }

void ei_str_unique(ei_String *s) {
  if (!ei_buf_shared(s->p)) return;
  ei_String n = str_new(s->p, s->len, s->cap);
  ei_drop_String(s);
  *s = n;
}

/* Appends t[0..tl): in place when s's buffer is its own and has room, otherwise into a new
   buffer of amortised capacity, made before the old one is let go (so t may point into s). */
void ei_str_cat(ei_String *s, const char *t, uint64_t tl) {
  uint64_t cap = tl <= s->cap - s->len ? s->cap : ei_grow_cap(s->cap, s->len, tl, 15);
  if (s->p && cap == s->cap && !ei_buf_shared(s->p)) {
    if (tl) memmove(s->p + s->len, t, (size_t)tl);
  } else {
    ei_String n = str_new(s->p, s->len, cap);
    if (tl) memcpy(n.p + s->len, t, (size_t)tl);
    ei_drop_String(s);
    *s = n;
  }
  s->len += tl;
  s->p[s->len] = 0;
}

void ei_str_push(ei_String *s, const char *t) { ei_str_cat(s, t, (uint64_t)strlen(t)); }
void ei_str_append(ei_String *s, const ei_String *t) { ei_str_cat(s, t->p, t->len); }

/* FNV-1a, then the ei_hash_u64 finalizer. */
uint64_t ei_hash_str(const char *s) {
  uint64_t h = UINT64_C(1469598103934665603);
  while (*s) {
    h ^= (unsigned char)*s++;
    h *= UINT64_C(1099511628211);
  }
  return ei_hash_u64(h);
}

// ---- String bytes (String.byte/slice/from_bytes/push_byte, str.byte/slice)

uint8_t ei_str_byte(const char *s, uint64_t n, uint64_t i, int32_t line) {
  if (i >= n) ei_trap("index out of bounds", line);
  return (uint8_t)s[i];
}

/* A UTF-8 continuation byte (10xxxxxx): not the start of a character. */
static bool ei_cont(const char *s, uint64_t n, uint64_t i) {
  return i < n && ((uint8_t)s[i] & 0xC0) == 0x80;
}

ei_String ei_str_slice(const char *s, uint64_t n, uint64_t a, uint64_t b, int32_t line) {
  if (a > b || b > n) ei_trap("slice out of bounds", line);
  if (ei_cont(s, n, a) || ei_cont(s, n, b)) ei_trap("slice not on a character boundary", line);
  return ei_str_from_n(s + a, b - a);
}

uint64_t ei_utf8_check(const uint8_t *d, uint64_t n) {
  uint64_t i = 0;
  while (i < n) {
    uint8_t c = d[i];
    if (c == 0) return i;
    if (c < 0x80) {
      i++;
      continue;
    }
    uint64_t len;
    uint8_t lo = 0x80, hi = 0xBF; /* the range of the second byte */
    if (c >= 0xC2 && c <= 0xDF) {
      len = 2;
    } else if (c >= 0xE0 && c <= 0xEF) {
      len = 3;
      if (c == 0xE0) lo = 0xA0; /* no overlong forms */
      if (c == 0xED) hi = 0x9F; /* no surrogates */
    } else if (c >= 0xF0 && c <= 0xF4) {
      len = 4;
      if (c == 0xF0) lo = 0x90; /* no overlong forms */
      if (c == 0xF4) hi = 0x8F; /* nothing past U+10FFFF */
    } else {
      return i;
    }
    if (n - i < len || d[i + 1] < lo || d[i + 1] > hi) return i;
    for (uint64_t k = 2; k < len; k++)
      if ((d[i + k] & 0xC0) != 0x80) return i;
    i += len;
  }
  return n;
}

ei_String ei_str_from_n(const char *s, uint64_t n) { return str_new(s, n, n); }

/* ei_str_cat copies a shared buffer first (copy-on-write). */
void ei_str_push_byte(ei_String *s, uint8_t b, int32_t line) {
  if (b == 0 || b > 127) ei_trap("push_byte needs an ASCII byte (1 to 127)", line);
  char c = (char)b;
  ei_str_cat(s, &c, 1);
}

// ---- print

void ei_print_i(int64_t v) { printf("%" PRId64 "\n", v); }
void ei_print_u(uint64_t v) { printf("%" PRIu64 "\n", v); }
void ei_print_b(bool v) { printf("%s\n", v ? "true" : "false"); }
void ei_print_s(const char *v) { printf("%s\n", v); }

// ---- clock: the host's milliseconds (0 if it reports a negative time)

uint64_t ei_now_ms(void) {
#if defined(EI_WASM_CORE)
  int64_t ms = ei_host_mono_ns() / 1000000;
#else
  int64_t ms = eider_now_ms();
#endif
  return ms > 0 ? (uint64_t)ms : 0;
}

// ---- the text helpers of core/sys.ei (core/ABI.md): `lit` and `to_string` reach the core
// by symbol name. Those that hand out or take pointers are defined here, not imported,
// because a pointer into the module's memory means nothing to the host: the bytes of a
// literal (ec_str_len, ec_str_byte: the literal is in this module's memory), and the `in`
// buffer (ec_in_clear, ec_in_push, ec_in_cstr), kept in the module. A core module
// (-DEI_WASM_CORE) also sends what is pushed on to the host (the C core's `in` buffer, which
// its other functions read); a plain `--wasm` module has no such functions, so the buffer is
// all there is, and the loader needs to supply nothing for these five.

static char *in_copy;
static size_t in_len, in_cap;

void ec_in_clear(void);
void ec_in_push(int32_t b);
const char *ec_in_cstr(void);
int64_t ec_str_len(const char *s);
int32_t ec_str_byte(const char *s, int64_t i);

void ec_in_clear(void) {
  in_len = 0;
#if defined(EI_WASM_CORE)
  ei_host_in_clear();
#endif
}
void ec_in_push(int32_t b) {
  if (in_len + 1 >= in_cap) {
    size_t c = in_cap ? in_cap * 2 : 256;
    char *p = realloc(in_copy, c);
    if (!p) ei_trap("out of memory", 0);
    in_copy = p;
    in_cap = c;
  }
  in_copy[in_len++] = (char)(b & 0xff);
#if defined(EI_WASM_CORE)
  ei_host_in_push(b);
#endif
}
const char *ec_in_cstr(void) {
  if (!in_copy) return "";
  in_copy[in_len] = 0;
  return in_copy;
}
int64_t ec_str_len(const char *s) { return (int64_t)strlen(s); }
int32_t ec_str_byte(const char *s, int64_t i) { return (unsigned char)s[i]; }

#if defined(EI_WASM_CORE)
// the entry the host runs (seed/wasm2c.c's main): the program's C main, then exit with
// what it returned
int main(void);
EI_WASM_EXPORT("_start") void ei_wasm_start(void);
void ei_wasm_start(void) { ei_host_leave(main()); }
#endif

// ---- threads: there is one. Shared handles still count references; the rest traps.

void ei_rc_init(ei_rc *rc) { atomic_init(rc, 1); }
void ei_rc_inc(ei_rc *rc) { atomic_fetch_add(rc, 1); }
bool ei_rc_dec(ei_rc *rc) { return atomic_fetch_sub(rc, 1) == 1; }

void ei_mutex_init(ei_mutex *m) { (void)m; }
void ei_mutex_lock(ei_mutex *m) { (void)m; }
void ei_mutex_unlock(ei_mutex *m) { (void)m; }
void ei_mutex_destroy(ei_mutex *m) { (void)m; }

#define EI_WASM_NO_THREADS "threads aren't available in WebAssembly"

void ei_thread_start(ei_thread *t, void *(*run)(void *), void *arg) {
  (void)t;
  (void)run;
  (void)arg;
  ei_trap("cannot create a thread", 0);
}
void ei_thread_join(ei_thread *t) {
  (void)t;
  ei_trap(EI_WASM_NO_THREADS, 0);
}
void ei_thread_destroy(ei_thread *t) {
  (void)t;
  ei_trap(EI_WASM_NO_THREADS, 0);
}
/* One thread and no signals: the body runs on the module's own stack (modules are libraries,
   so generated code doesn't call this today). */
int ei_main(int (*body)(void)) { return body(); }

void ei_chan_init(ei_chan *c, uint64_t elem_size) {
  (void)c;
  (void)elem_size;
  ei_trap(EI_WASM_NO_THREADS, 0);
}
void ei_chan_send(ei_chan *c, const void *elem) {
  (void)c;
  (void)elem;
  ei_trap(EI_WASM_NO_THREADS, 0);
}
bool ei_chan_recv(ei_chan *c, void *out) {
  (void)c;
  (void)out;
  ei_trap(EI_WASM_NO_THREADS, 0);
}
void ei_chan_close(ei_chan *c) {
  (void)c;
  ei_trap(EI_WASM_NO_THREADS, 0);
}
uint64_t ei_chan_len(const ei_chan *c) {
  (void)c;
  ei_trap(EI_WASM_NO_THREADS, 0);
}
void *ei_chan_at(ei_chan *c, uint64_t i) {
  (void)c;
  (void)i;
  ei_trap(EI_WASM_NO_THREADS, 0);
}
void ei_chan_destroy(ei_chan *c) {
  (void)c;
  ei_trap(EI_WASM_NO_THREADS, 0);
}

// ---- for generated code (the LLVM backend): what C glue once did inline

void ei_str_push_u64(ei_String *s, uint64_t v) {
  char b[24];
  int i = 23;
  b[23] = 0;
  do {
    b[--i] = (char)(48 + v % 10);
    v /= 10;
  } while (v);
  ei_str_cat(s, b + i, (uint64_t)(23 - i));
}

void ei_str_push_i64(ei_String *s, int64_t v) {
  if (v < 0) {
    char m = 45;
    ei_str_cat(s, &m, 1);
    ei_str_push_u64(s, (uint64_t)0 - (uint64_t)v);
  } else {
    ei_str_push_u64(s, (uint64_t)v);
  }
}

void ei_str_push_quoted(ei_String *o, const char *t) {
  char e[2];
  e[0] = 34;
  ei_str_cat(o, e, 1);
  for (; *t; t++) {
    unsigned char ch = (unsigned char)*t;
    e[0] = 92;
    if (ch == 34 || ch == 92) {
      e[1] = (char)ch;
      ei_str_cat(o, e, 2);
    } else if (ch == 10) {
      e[1] = 110;
      ei_str_cat(o, e, 2);
    } else if (ch == 9) {
      e[1] = 116;
      ei_str_cat(o, e, 2);
    } else if (ch == 13) {
      e[1] = 114;
      ei_str_cat(o, e, 2);
    } else {
      ei_str_cat(o, t, 1);
    }
  }
  e[0] = 34;
  ei_str_cat(o, e, 1);
}

void ei_main_error(const char *text) {
  fflush(stdout);
  fprintf(stderr, "error: %s\n", text);
}
void ei_main_error_i(int64_t v) {
  fflush(stdout);
  fprintf(stderr, "error: %" PRId64 "\n", v);
}
void ei_main_error_u(uint64_t v) {
  fflush(stdout);
  fprintf(stderr, "error: %" PRIu64 "\n", v);
}

int32_t ei_test(const char *name, void (*fn)(void)) {
  /* static: a failing test's trap longjmps back here, while ei_test runs */
  static jmp_buf jb;
  printf("test %s ... ", name);
  fflush(stdout);
  ei_set_trap_jmp(&jb);
  if (setjmp(jb) == 0) {
    fn();
    ei_set_trap_jmp(NULL);
    printf("ok\n");
    return 0;
  }
  ei_set_trap_jmp(NULL);
#ifdef EI_RT_PROFILE
  /* a failed test longjmps past its frames' pops */
  ei_prof_unwind(0);
#endif
  return 1;
}

int32_t ei_tests_done(int32_t total, int32_t failed) {
  printf("\n%" PRId32 " tests, %" PRId32 " failed\n", total, failed);
  if (!failed) ei_check_leaks();
  return failed ? 1 : 0;
}

// handle objects: one thread, so a count, the data, and threads and channels that trap
typedef struct {
  uint64_t rc;
  uint64_t pad;
} ei_h_head;
#define EI_H_DATA ((uint64_t)16)
void *ei_h_new(uint64_t size, uint64_t chan_elem) {
  if (chan_elem > 0) ei_trap(EI_WASM_NO_THREADS, 0);
  if (size > UINT64_MAX - EI_H_DATA) ei_trap("out of memory", 0);
  ei_h_head *h = ei_alloc(EI_H_DATA + size);
  memset(h, 0, (size_t)(EI_H_DATA + size));
  h->rc = 1;
  return h;
}
void *ei_h_data(void *h) { return (unsigned char *)h + EI_H_DATA; }
void ei_h_inc(void *h) {
  if (h) ((ei_h_head *)h)->rc++;
}
bool ei_h_dec(void *h) { return h && --((ei_h_head *)h)->rc == 0; }
void ei_h_lock(void *h) { (void)h; }
void ei_h_unlock(void *h) { (void)h; }
void ei_h_start(void *h, void *(*run)(void *)) {
  (void)h;
  (void)run;
  ei_trap("cannot create a thread", 0);
}
void ei_h_join(void *h) { (void)h; }
ei_chan *ei_h_chan(void *h) {
  (void)h;
  ei_trap(EI_WASM_NO_THREADS, 0);
}
void ei_h_free(void *h) { ei_free(h); }

/* f-strings (docs/compiler.md, "C8.28"). The spec is one u64: width (bits 0-31), fill byte
   (32-39), alignment (40-41: 1 left, 2 right, 3 center), `+` (42), `#` (43), `0` (44), radix
   (45-50), upper-case digits (51). Widths count Unicode scalar values. */
static void fmt_fill(ei_String *s, char f, uint64_t n) {
  char b[64];
  memset(b, f, sizeof b);
  while (n > 0) {
    uint64_t k = n < sizeof b ? n : (uint64_t)sizeof b;
    ei_str_cat(s, b, k);
    n -= k;
  }
}

static uint64_t fmt_scalars(const char *p, uint64_t n) {
  uint64_t c = 0;
  for (uint64_t i = 0; i < n; i++) {
    unsigned char b = (unsigned char)p[i];
    if (b < 128 || b >= 192) c++;
  }
  return c;
}

/* Append t (tlen bytes) padded to the spec's width with its fill and alignment. */
static void fmt_pad(ei_String *s, const char *t, uint64_t tlen, uint64_t spec) {
  uint64_t width = spec & 0xffffffffu;
  char fill = (char)((spec >> 32) & 0xff);
  unsigned align = (unsigned)((spec >> 40) & 3);
  uint64_t n = fmt_scalars(t, tlen);
  uint64_t gap = n < width ? width - n : 0;
  uint64_t before = align == 1 ? 0 : align == 3 ? gap / 2 : gap;
  fmt_fill(s, fill, before);
  ei_str_cat(s, t, tlen);
  fmt_fill(s, fill, gap - before);
}

void ei_str_pad(ei_String *s, uint64_t mark, uint64_t spec) {
  if (mark > s->len) mark = s->len;
  uint64_t width = spec & 0xffffffffu;
  if (fmt_scalars(s->p + mark, s->len - mark) >= width) return;
  ei_String t = ei_str_from("");
  ei_str_cat(&t, s->p, mark);
  fmt_pad(&t, s->p + mark, s->len - mark, spec);
  ei_drop_String(s);
  *s = t;
}

static void fmt_int(ei_String *s, int neg, uint64_t mag, uint64_t spec) {
  unsigned base = (unsigned)((spec >> 45) & 63);
  int up = (int)((spec >> 51) & 1);
  char b[80];
  int h = 0;
  if (base < 2 || base > 36) base = 10;
  if (neg) b[h++] = '-';
  else if ((spec >> 42) & 1) b[h++] = '+';
  if ((spec >> 43) & 1) {
    char k = base == 16 ? 'x' : base == 2 ? 'b' : base == 8 ? 'o' : 0;
    if (k) {
      b[h++] = '0';
      b[h++] = up ? (char)(k - 32) : k;
    }
  }
  char d[66];
  int i = 66;
  do {
    unsigned x = (unsigned)(mag % base);
    d[--i] = (char)(x < 10 ? 48 + x : (up ? 55 : 87) + x);
    mag /= base;
  } while (mag);
  uint64_t nd = (uint64_t)(66 - i);
  if ((spec >> 44) & 1) {
    uint64_t width = spec & 0xffffffffu;
    ei_str_cat(s, b, (uint64_t)h);
    if ((uint64_t)h + nd < width) fmt_fill(s, '0', width - (uint64_t)h - nd);
    ei_str_cat(s, d + i, nd);
    return;
  }
  memcpy(b + h, d + i, (size_t)nd);
  fmt_pad(s, b, (uint64_t)h + nd, spec);
}

void ei_str_fmt_i64(ei_String *s, int64_t v, uint64_t spec) {
  fmt_int(s, v < 0, v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v, spec);
}

void ei_str_fmt_u64(ei_String *s, uint64_t v, uint64_t spec) { fmt_int(s, 0, v, spec); }

/* floats: print, Show and {x:spec} (core/eider_float.inc, shared with the native runtime) */
#include "../eider_float.inc"
