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
