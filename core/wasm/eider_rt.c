// eider_rt for WebAssembly: the language runtime (core/RUNTIME.md) as a backend for wasm32,
// over the freestanding libc in core/wasm/libc.c. Contract and limits: core/wasm/README.md.
//
// The same functions as core/eider_rt.c, declared by the same core/eider_rt.h. What differs:
//   - one thread: no trap lock, ei_mutex_* do nothing, and ei_thread_* / ei_chan_* trap
//     (E0806 rejects programs that use threads, so generated code never calls them);
//   - a trap prints its message through env.eider_write and executes `unreachable`, which
//     the host sees as a trap (a RuntimeError in JavaScript) instead of exit(101);
//   - ei_now_ms is the host's clock (env.eider_now_ms), not processor time.
// Allocation, String, hashing and print are the text of core/eider_rt.c.
#include "../eider_rt.h"

#include <stdio.h>

#include "host.h"

// ---- traps

static const char *trap_file;
static jmp_buf *trap_jmp;

void ei_set_file(const char *file) { trap_file = file; }
void ei_set_trap_jmp(jmp_buf *jb) { trap_jmp = jb; }

_Noreturn void ei_trap(const char *msg, int32_t line) {
  const char *file = trap_file ? trap_file : "";
  if (trap_jmp) {
    printf("FAILED\n    %s (%s:%" PRId32 ")\n", msg, file, line);
    longjmp(*trap_jmp, 1);
  }
  fprintf(stderr, "eider: runtime error: %s (%s:%" PRId32 ")\n", msg, file, line);
  ei_wasm_trap();
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

// ---- String

ei_String ei_str_from(const char *s) {
  ei_String r;
  r.len = (uint64_t)strlen(s);
  r.p = ei_alloc(r.len + 1);
  memcpy(r.p, s, (size_t)r.len + 1);
  return r;
}

ei_String ei_str_from_i64(int64_t v) {
  char buf[32];
  snprintf(buf, sizeof buf, "%" PRId64, v);
  return ei_str_from(buf);
}

void ei_drop_String(ei_String *s) {
  ei_free(s->p);
  s->p = NULL;
  s->len = 0;
}

ei_String ei_clone_String(const ei_String *s) {
  ei_String r;
  r.len = s->len;
  r.p = ei_alloc(r.len + 1);
  memcpy(r.p, s->p, (size_t)r.len + 1);
  return r;
}

/* Appends t[0..tl). Builds a new buffer before freeing the old one, so t may point into s. */
void ei_str_cat(ei_String *s, const char *t, uint64_t tl) {
  if (tl > UINT64_MAX - 1 - s->len) ei_trap("out of memory", 0);
  char *n = ei_alloc(s->len + tl + 1);
  if (s->len) memcpy(n, s->p, (size_t)s->len);
  if (tl) memcpy(n + s->len, t, (size_t)tl);
  n[s->len + tl] = 0;
  ei_free(s->p);
  s->p = n;
  s->len += tl;
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

ei_String ei_str_from_n(const char *s, uint64_t n) {
  ei_String r;
  if (n > UINT64_MAX - 1) ei_trap("out of memory", 0);
  r.len = n;
  r.p = ei_alloc(n + 1);
  if (n) memcpy(r.p, s, (size_t)n);
  r.p[n] = 0;
  return r;
}

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
  int64_t ms = eider_now_ms();
  return ms > 0 ? (uint64_t)ms : 0;
}

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
