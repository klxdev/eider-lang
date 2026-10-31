// eider_prof: the profiling half of the language runtime (core/RUNTIME.md "Profiling"). It is
// compiled only into programs built with `eiderc build|run --profile`: eider_rt.c includes this
// file at its end under `#ifdef EI_RT_PROFILE`, and the driver passes -DEI_RT_PROFILE when the
// generated C asks for it. A program built without the flag contains none of it.
//
// What is here is what can't be Eider: the SIGPROF handler and the per-thread sample rings it
// writes (async-signal-safe: atomics and plain stores only), the per-thread timers, the
// allocation and wait hooks the rest of the runtime calls, the tables they count into, and
// the writer of the profile file (JSON lines, docs/runtime.md "Profile format"). Analysis
// (names, self/total time, flame graphs, diffs) is the eider-profiler tool, in Eider.
//
// Pieces:
// - shadow stack: generated code pushes `{fn, line}` frames (eider_rt.h); the handler copies
//   the innermost PROF_SDEPTH of them into the interrupted thread's ring.
// - rings: one per runtime thread, single producer (the handler, on that thread) and single
//   consumer (the collector thread, which drains every 20 ms into the stack table).
// - stack table: aggregated stacks per kind (cpu, alloc, lock, recv, cow) and label, under
//   one mutex; never touched from a signal handler.
// - site table: per (kind, function, line) counts and bytes or nanoseconds, lock-free (open
//   addressing with a CAS on the key), relaxed atomic counters; allocations also count live.
// - heap: allocations carry a 16-byte prefix (site, size) so a free knows what it frees.
// - timeline: live and peak heap every 100 ms (collector).
// - control: the std/profile calls arrive through eider_core's ec_prof (core/ABI.md
//   "Profiling"), which forwards to prof_ctl once ei_prof_init has registered it.
// The file is written at exit (atexit), on SIGUSR2 (by the collector, not in the handler) and
// on demand (std/profile.snapshot).

#include <errno.h>
#include <sys/time.h>
#if defined(__linux__)
#include <sys/syscall.h>
#define PROF_THREAD_TIMERS 1
#endif

_Thread_local ei_prof_frame ei_prof_stack[EI_PROF_DEPTH];
_Thread_local volatile uint16_t ei_prof_depth;
_Thread_local ei_prof_frame ei_prof_spill;

#define PROF_SDEPTH 128
#define PROF_RING 128
#define PROF_TRUNC 0xFFFFFFFFu /* fn id of the frame that marks a truncated stack */
#define PROF_SITES ((size_t)1 << 16)

/* stack kinds */
#define PK_CPU 0
#define PK_ALLOC 1
#define PK_LOCK 2
#define PK_RECV 3
#define PK_COW 4
#define PK_KINDS 5
static const char *const prof_kind_names[PK_KINDS] = {"cpu", "alloc", "lock", "recv", "cow"};
static const char *const prof_ev_names[EI_PEV_KINDS] = {"", "cow", "copy", "drop", "grow", "rehash", "ref", "alloc", "lock", "recv", "spawn"};

/* a frame as samples and the stack table keep it */
typedef struct { uint32_t fn; int32_t line; } prof_fr;

typedef struct {
  uint32_t n; /* frames used; the high bit: truncated */
  uint32_t label;
  prof_fr f[PROF_SDEPTH];
} prof_sample;

typedef struct prof_thr {
  struct prof_thr *next;
  uint32_t id;
  atomic_uint head, tail;
  prof_sample *ring;
  atomic_bool done;
  uint64_t start_ns, end_ns;
  atomic_uint_least64_t dropped, taken;
#if PROF_THREAD_TIMERS
  timer_t timer;
  bool timed;
#endif
  struct prof_slot *cache; /* this thread's counts per site (prof_slot_of) */
  /* this thread's allocations, bytes and frees (written by it alone), and the live bytes and
     blocks not yet added to the global heap counters */
  atomic_int_least64_t allocs, bytes, frees, live_pending, live_n_pending;
} prof_thr;

/* configuration (set once by ei_prof_init) */
static const ei_prof_table *prof_tab;
static atomic_bool prof_inited;
static bool prof_off;           /* EIDER_PROF=off: nothing is recorded or written */
static bool prof_mem;           /* allocation tracking (never changes after init) */
static bool prof_conc;          /* waits */
static bool prof_cpu;           /* sampling */
static bool prof_wall;          /* EIDER_PROF_CLOCK=wall */
static long prof_hz = 99;
static int64_t prof_rate = 512 * 1024; /* bytes between allocation stack samples */
static char prof_path[4096] = "eider.prof";
static atomic_bool prof_running;
static atomic_bool prof_clean;   /* main returned normally: what is live now leaked */
static uint64_t prof_t0;         /* monotonic ns at the start (or the last reset) */
static atomic_uint_least64_t prof_t0_atomic;

static _Thread_local prof_thr *prof_me;
static _Thread_local uint32_t prof_label;
static _Thread_local int64_t prof_alloc_left, prof_cow_left;

static pthread_mutex_t prof_reg_mu = PTHREAD_MUTEX_INITIALIZER; /* threads, timers */
static prof_thr *prof_threads;
static uint32_t prof_nthreads;
static atomic_uint_least64_t prof_started, prof_exited;

static uint64_t prof_now(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return 0;
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

// ---- the stack table (cpu samples, sampled allocations and copies, waits)

typedef struct {
  uint64_t h;
  uint32_t kind, label, nf, trunc;
  size_t off;
  uint64_t count, weight;
} prof_stack;

static pthread_mutex_t prof_agg_mu = PTHREAD_MUTEX_INITIALIZER;
static prof_stack *agg;
static size_t agg_len, agg_cap;
static uint32_t *agg_idx; /* entry + 1 by hash, 0 empty */
static size_t agg_icap;
static prof_fr *pool;
static size_t pool_len, pool_cap;
static uint64_t prof_agg_lost;

static uint64_t prof_hash(uint32_t kind, uint32_t label, const prof_fr *f, uint32_t n, uint32_t trunc) {
  uint64_t h = UINT64_C(1469598103934665603);
  uint64_t parts[3] = {kind, label, ((uint64_t)n << 1) | trunc};
  for (int i = 0; i < 3; i++) {
    h ^= parts[i];
    h *= UINT64_C(1099511628211);
  }
  for (uint32_t i = 0; i < n; i++) {
    h ^= f[i].fn;
    h *= UINT64_C(1099511628211);
    h ^= (uint32_t)f[i].line;
    h *= UINT64_C(1099511628211);
  }
  return ei_hash_u64(h);
}

static bool agg_rehash(size_t ncap) {
  uint32_t *ni = calloc(ncap, sizeof *ni);
  if (!ni) return false;
  for (size_t e = 0; e < agg_len; e++) {
    size_t i = (size_t)agg[e].h & (ncap - 1);
    while (ni[i]) i = (i + 1) & (ncap - 1);
    ni[i] = (uint32_t)(e + 1);
  }
  free(agg_idx);
  agg_idx = ni;
  agg_icap = ncap;
  return true;
}

/* Adds a stack (innermost last) with count and weight; the caller holds prof_agg_mu. */
static void agg_add(uint32_t kind, uint32_t label, const prof_fr *f, uint32_t n, uint32_t trunc, uint64_t count, uint64_t weight) {
  uint64_t h = prof_hash(kind, label, f, n, trunc);
  if (agg_icap == 0 || (agg_len + 1) * 2 > agg_icap) {
    if (!agg_rehash(agg_icap ? agg_icap * 2 : 1024)) {
      prof_agg_lost += count;
      return;
    }
  }
  size_t i = (size_t)h & (agg_icap - 1);
  while (agg_idx[i]) {
    prof_stack *s = &agg[agg_idx[i] - 1];
    if (s->h == h && s->kind == kind && s->label == label && s->nf == n && s->trunc == trunc &&
        memcmp(pool + s->off, f, n * sizeof *f) == 0) {
      s->count += count;
      s->weight += weight;
      return;
    }
    i = (i + 1) & (agg_icap - 1);
  }
  if (agg_len == agg_cap) {
    size_t nc = agg_cap ? agg_cap * 2 : 1024;
    prof_stack *na = realloc(agg, nc * sizeof *na);
    if (!na) {
      prof_agg_lost += count;
      return;
    }
    agg = na;
    agg_cap = nc;
  }
  if (pool_len + n > pool_cap) {
    size_t nc = pool_cap ? pool_cap * 2 : 16384;
    while (nc < pool_len + n) nc *= 2;
    prof_fr *np = realloc(pool, nc * sizeof *np);
    if (!np) {
      prof_agg_lost += count;
      return;
    }
    pool = np;
    pool_cap = nc;
  }
  if (n) memcpy(pool + pool_len, f, n * sizeof *f);
  prof_stack *s = &agg[agg_len];
  s->h = h;
  s->kind = kind;
  s->label = label;
  s->nf = n;
  s->trunc = trunc;
  s->off = pool_len;
  s->count = count;
  s->weight = weight;
  pool_len += n;
  agg_idx[i] = (uint32_t)(++agg_len);
}

static void prof_fr_of(prof_fr *r, const ei_prof_frame *f) {
  float fn = f->fn, line = f->line;
  r->fn = fn >= 0.0f && fn < 16777216.0f ? (uint32_t)fn : 0;
  r->line = line >= 0.0f && line < 16777216.0f ? (int32_t)line : 0;
}

/* The calling thread's shadow stack (at most PROF_SDEPTH innermost frames) into f. */
static uint32_t prof_capture(prof_fr *f, uint32_t *trunc) {
  uint32_t d = ei_prof_depth;
  uint32_t real = d > EI_PROF_DEPTH ? EI_PROF_DEPTH : d;
  uint32_t k = real > PROF_SDEPTH ? PROF_SDEPTH : real;
  *trunc = real > k || d > EI_PROF_DEPTH;
  for (uint32_t i = 0; i < k; i++) prof_fr_of(&f[i], &ei_prof_stack[real - k + i]);
  if (d > EI_PROF_DEPTH && k > 0) prof_fr_of(&f[k - 1], &ei_prof_spill);
  return k;
}

/* A stack sample of the calling thread (not in a signal handler). */
static void prof_stack_now(uint32_t kind, uint64_t weight) {
  prof_fr f[PROF_SDEPTH];
  uint32_t trunc;
  uint32_t n = prof_capture(f, &trunc);
  pthread_mutex_lock(&prof_agg_mu);
  agg_add(kind, prof_label, f, n, trunc, 1, weight);
  pthread_mutex_unlock(&prof_agg_mu);
}

// ---- the site table

typedef struct {
  atomic_uint_least64_t key; /* kind << 56 | fn << 32 | line; 0: empty */
  atomic_uint_least64_t n, w, live_n, live_w;
} prof_site;

static prof_site *sites;
static atomic_uint_least64_t prof_sites_lost;

static uint64_t prof_site_key(uint32_t kind) {
  uint32_t d = ei_prof_depth;
  uint32_t fn = 0;
  int32_t line = 0;
  if (d > 0) {
    prof_fr r;
    prof_fr_of(&r, d <= EI_PROF_DEPTH ? &ei_prof_stack[d - 1] : &ei_prof_spill);
    fn = r.fn;
    line = r.line;
  }
  return ((uint64_t)kind << 56) | ((uint64_t)(fn & 0xFFFFFF) << 32) | (uint32_t)line;
}

/* The site of `kind` at the current position (NULL when the table is full). */
static prof_site *prof_site_at(uint32_t kind) {
  if (!sites) return NULL;
  uint64_t key = prof_site_key(kind);
  size_t i = (size_t)ei_hash_u64(key) & (PROF_SITES - 1);
  for (size_t c = 0; c < PROF_SITES; c++) {
    prof_site *s = &sites[i];
    uint64_t k = atomic_load_explicit(&s->key, memory_order_acquire);
    if (k == key) return s;
    if (k == 0) {
      uint64_t zero = 0;
      if (atomic_compare_exchange_strong(&s->key, &zero, key)) return s;
      if (zero == key) return s;
    }
    i = (i + 1) & (PROF_SITES - 1);
  }
  atomic_fetch_add_explicit(&prof_sites_lost, 1, memory_order_relaxed);
  return NULL;
}

/* Each thread counts into a small cache of its own sites (slots), and a slot's counts go to
   the shared site when the slot is taken for another site or the thread ends; the writer adds
   up the shared sites and every thread's slots. So the hot paths (an allocation, a free, a
   copy) are plain stores to memory only this thread writes, not atomic read-modify-writes
   on lines every thread shares, which cost kvstore under load two thirds of its throughput.
   A thread the runtime didn't start (no prof_me) counts into the shared sites directly. */
#define PROF_CACHE 1024
typedef struct prof_slot {
  _Atomic(prof_site *) s;
  atomic_int_least64_t n, w, live_n, live_w;
} prof_slot;

/* x += d for a counter only this thread writes (others only read it) */
static void own_add(atomic_int_least64_t *x, int64_t d) {
  atomic_store_explicit(x, atomic_load_explicit(x, memory_order_relaxed) + d, memory_order_relaxed);
}

static void slot_flush(prof_slot *c) {
  prof_site *g = atomic_load_explicit(&c->s, memory_order_relaxed);
  if (!g) return;
  int64_t n = atomic_load_explicit(&c->n, memory_order_relaxed), w = atomic_load_explicit(&c->w, memory_order_relaxed);
  int64_t ln = atomic_load_explicit(&c->live_n, memory_order_relaxed), lw = atomic_load_explicit(&c->live_w, memory_order_relaxed);
  atomic_store_explicit(&c->n, 0, memory_order_relaxed);
  atomic_store_explicit(&c->w, 0, memory_order_relaxed);
  atomic_store_explicit(&c->live_n, 0, memory_order_relaxed);
  atomic_store_explicit(&c->live_w, 0, memory_order_relaxed);
  if (n) atomic_fetch_add_explicit(&g->n, (uint64_t)n, memory_order_relaxed);
  if (w) atomic_fetch_add_explicit(&g->w, (uint64_t)w, memory_order_relaxed);
  if (ln) atomic_fetch_add_explicit(&g->live_n, (uint64_t)ln, memory_order_relaxed);
  if (lw) atomic_fetch_add_explicit(&g->live_w, (uint64_t)lw, memory_order_relaxed);
}

/* This thread's slot for site g (NULL: count into g itself). */
static prof_slot *slot_of(prof_site *g) {
  prof_thr *t = prof_me;
  if (!t || !t->cache) return NULL;
  prof_slot *c = &t->cache[((uintptr_t)g / sizeof *g) & (PROF_CACHE - 1)];
  if (atomic_load_explicit(&c->s, memory_order_relaxed) != g) {
    slot_flush(c);
    atomic_store_explicit(&c->s, g, memory_order_relaxed);
  }
  return c;
}

/* n events of weight w, and dn/dw live, at site g */
static void prof_add(prof_site *g, int64_t n, int64_t w, int64_t dn, int64_t dw) {
  if (!g) return;
  prof_slot *c = slot_of(g);
  if (c) {
    if (n) own_add(&c->n, n);
    if (w) own_add(&c->w, w);
    if (dn) own_add(&c->live_n, dn);
    if (dw) own_add(&c->live_w, dw);
    return;
  }
  if (n) atomic_fetch_add_explicit(&g->n, (uint64_t)n, memory_order_relaxed);
  if (w) atomic_fetch_add_explicit(&g->w, (uint64_t)w, memory_order_relaxed);
  if (dn) atomic_fetch_add_explicit(&g->live_n, (uint64_t)dn, memory_order_relaxed);
  if (dw) atomic_fetch_add_explicit(&g->live_w, (uint64_t)dw, memory_order_relaxed);
}

static void prof_count(prof_site *g, uint64_t w) { prof_add(g, 1, (int64_t)w, 0, 0); }

void ei_prof_ev(int32_t kind, uint64_t n) {
  if (prof_off || !atomic_load_explicit(&prof_inited, memory_order_relaxed) || kind <= 0 || kind >= EI_PEV_KINDS) return;
  /* the memory events only when memory is profiled; Ref conflicts and spawns always */
  if (!prof_mem && kind != EI_PEV_REF && kind != EI_PEV_SPAWN) return;
  prof_count(prof_site_at((uint32_t)kind), n);
  if (kind == EI_PEV_COW) {
    prof_cow_left -= (int64_t)(n ? n : 1);
    if (prof_cow_left <= 0) {
      prof_stack_now(PK_COW, (uint64_t)(prof_rate - prof_cow_left));
      prof_cow_left = prof_rate;
    }
  }
}

/* A wait of ns nanoseconds (kind EI_PEV_LOCK or EI_PEV_RECV) at the current position. */
/* Every wait is counted at its site; a stack is taken once per PROF_WAIT_RATE ns waited by
   the thread (weighted by the time since the last one), because the stack table's lock would
   otherwise serialize threads that wait often (a busy sync.Lock waits on every call). */
#define PROF_WAIT_RATE 1000000
static _Thread_local int64_t prof_wait_left[2] = {PROF_WAIT_RATE, PROF_WAIT_RATE};
static void prof_wait(int32_t kind, uint64_t ns) {
  if (prof_off) return;
  prof_count(prof_site_at((uint32_t)kind), ns);
  int k = kind == EI_PEV_LOCK ? 0 : 1;
  prof_wait_left[k] -= (int64_t)ns;
  if (prof_wait_left[k] <= 0) {
    prof_stack_now(k == 0 ? PK_LOCK : PK_RECV, (uint64_t)(PROF_WAIT_RATE - prof_wait_left[k]));
    prof_wait_left[k] = PROF_WAIT_RATE;
  }
}

// ---- the heap: each allocation carries its site and size in a 16-byte prefix

typedef struct {
  prof_site *site;
  uint64_t size;
} prof_hdr;
_Static_assert(sizeof(prof_hdr) == 16, "the prefix keeps malloc's alignment");

/* The shared heap counters; a thread's own allocations are counted in its prof_thr, and its
   live bytes reach heap_live in steps of PROF_LIVE_STEP (so the peak is exact to within that
   much per thread). */
#define PROF_LIVE_STEP (256 * 1024)
static atomic_int_least64_t heap_live, heap_live_n, heap_peak;
static atomic_uint_least64_t heap_allocs, heap_bytes, heap_frees;

static void heap_live_add(int64_t dw, int64_t dn) {
  if (dn) atomic_fetch_add_explicit(&heap_live_n, dn, memory_order_relaxed);
  if (!dw) return;
  int64_t live = atomic_fetch_add_explicit(&heap_live, dw, memory_order_relaxed) + dw;
  int64_t peak = atomic_load_explicit(&heap_peak, memory_order_relaxed);
  while (live > peak && !atomic_compare_exchange_weak_explicit(&heap_peak, &peak, live, memory_order_relaxed, memory_order_relaxed)) {
  }
}

/* this thread's pending live bytes into the shared counters */
static void heap_flush(prof_thr *t) {
  int64_t w = atomic_load_explicit(&t->live_pending, memory_order_relaxed), n = atomic_load_explicit(&t->live_n_pending, memory_order_relaxed);
  atomic_store_explicit(&t->live_pending, 0, memory_order_relaxed);
  atomic_store_explicit(&t->live_n_pending, 0, memory_order_relaxed);
  heap_live_add(w, n);
}

static void heap_count(int64_t n, int64_t dw, int64_t dn, bool alloc) {
  prof_thr *t = prof_me;
  if (!t) {
    if (alloc) {
      atomic_fetch_add_explicit(&heap_allocs, 1, memory_order_relaxed);
      atomic_fetch_add_explicit(&heap_bytes, (uint64_t)n, memory_order_relaxed);
    } else {
      atomic_fetch_add_explicit(&heap_frees, 1, memory_order_relaxed);
    }
    heap_live_add(dw, dn);
    return;
  }
  if (alloc) {
    own_add(&t->allocs, 1);
    own_add(&t->bytes, n);
  } else {
    own_add(&t->frees, 1);
  }
  own_add(&t->live_pending, dw);
  own_add(&t->live_n_pending, dn);
  int64_t p = atomic_load_explicit(&t->live_pending, memory_order_relaxed);
  if (p >= PROF_LIVE_STEP || p <= -PROF_LIVE_STEP) heap_flush(t);
}

static void prof_on_alloc(prof_hdr *h, uint64_t n) {
  prof_site *s = prof_site_at(EI_PEV_ALLOC);
  h->site = s;
  h->size = n;
  prof_add(s, 1, (int64_t)n, 1, (int64_t)n);
  heap_count((int64_t)n, (int64_t)n, 1, true);
  prof_alloc_left -= (int64_t)(n ? n : 1);
  if (prof_alloc_left <= 0) {
    prof_stack_now(PK_ALLOC, (uint64_t)(prof_rate - prof_alloc_left));
    prof_alloc_left = prof_rate;
  }
}

static void prof_on_free(const prof_hdr *h) {
  prof_add(h->site, 0, 0, -1, -(int64_t)h->size);
  heap_count(0, -(int64_t)h->size, -1, false);
}

static void *prof_alloc(uint64_t n) {
  if (n > SIZE_MAX - sizeof(prof_hdr)) ei_trap("out of memory", 0);
  prof_hdr *h = malloc((size_t)n + sizeof *h);
  if (!h) ei_trap("out of memory", 0);
  prof_on_alloc(h, n);
  return h + 1;
}

static void prof_free(void *p) {
  prof_hdr *h = (prof_hdr *)p - 1;
  prof_on_free(h);
  free(h);
}

/* realloc of an ei_alloc block p to b bytes: a free of the old size and an allocation of the
   new one at the current site. */
static void *prof_realloc(void *p, uint64_t b) {
  if (b > SIZE_MAX - sizeof(prof_hdr)) ei_trap("out of memory", 0);
  prof_hdr *h = (prof_hdr *)p - 1;
  prof_hdr old = *h;
  prof_hdr *nh = realloc(h, (size_t)b + sizeof *nh);
  if (!nh) ei_trap("out of memory", 0);
  prof_on_free(&old);
  prof_on_alloc(nh, b);
  return nh + 1;
}

/* The heap totals: the shared counters plus every thread's own (prof_reg_mu held). */
typedef struct { int64_t allocs, bytes, frees, live, live_n; } prof_heap;
static prof_heap heap_totals(void) {
  prof_heap h;
  h.allocs = (int64_t)atomic_load(&heap_allocs);
  h.bytes = (int64_t)atomic_load(&heap_bytes);
  h.frees = (int64_t)atomic_load(&heap_frees);
  h.live = atomic_load(&heap_live);
  h.live_n = atomic_load(&heap_live_n);
  for (prof_thr *t = prof_threads; t; t = t->next) {
    h.allocs += atomic_load_explicit(&t->allocs, memory_order_relaxed);
    h.bytes += atomic_load_explicit(&t->bytes, memory_order_relaxed);
    h.frees += atomic_load_explicit(&t->frees, memory_order_relaxed);
    h.live += atomic_load_explicit(&t->live_pending, memory_order_relaxed);
    h.live_n += atomic_load_explicit(&t->live_n_pending, memory_order_relaxed);
  }
  return h;
}

// ---- timeline (collector)

typedef struct { uint64_t ns; int64_t live, peak; uint64_t allocs; uint32_t threads; } prof_point;
static pthread_mutex_t prof_tl_mu = PTHREAD_MUTEX_INITIALIZER;
static prof_point *tl;
static size_t tl_len, tl_cap = 2048, tl_every = 5, tl_tick;

static void tl_add(void) {
  pthread_mutex_lock(&prof_tl_mu);
  if (!tl) tl = malloc(tl_cap * sizeof *tl);
  if (tl) {
    if (tl_len == tl_cap) {
      /* keep every other point and sample half as often */
      for (size_t i = 0; i < tl_len / 2; i++) tl[i] = tl[2 * i + 1];
      tl_len /= 2;
      tl_every *= 2;
    }
    prof_point *pt = &tl[tl_len++];
    pt->ns = prof_now() - atomic_load(&prof_t0_atomic);
    pthread_mutex_lock(&prof_reg_mu);
    prof_heap hp = heap_totals();
    pthread_mutex_unlock(&prof_reg_mu);
    pt->live = hp.live;
    pt->peak = atomic_load_explicit(&heap_peak, memory_order_relaxed);
    if (pt->peak < pt->live) pt->peak = pt->live;
    pt->allocs = (uint64_t)hp.allocs;
    pt->threads = (uint32_t)(atomic_load(&prof_started) - atomic_load(&prof_exited));
  }
  pthread_mutex_unlock(&prof_tl_mu);
}

// ---- sampling: the signal handler and the timers

static void prof_on_sigprof(int sig) {
  (void)sig;
  int e = errno;
  prof_thr *t = prof_me;
  if (t && t->ring && atomic_load_explicit(&prof_running, memory_order_relaxed)) {
    unsigned tail = atomic_load_explicit(&t->tail, memory_order_relaxed);
    unsigned head = atomic_load_explicit(&t->head, memory_order_acquire);
    if (tail - head >= PROF_RING) {
      atomic_fetch_add_explicit(&t->dropped, 1, memory_order_relaxed);
    } else {
      prof_sample *s = &t->ring[tail % PROF_RING];
      uint32_t trunc;
      uint32_t n = prof_capture(s->f, &trunc);
      s->n = n | (trunc ? 0x80000000u : 0);
      s->label = prof_label;
      atomic_store_explicit(&t->tail, tail + 1, memory_order_release);
    }
  }
  errno = e;
}

static atomic_bool prof_usr2;
static void prof_on_sigusr2(int sig) {
  (void)sig;
  atomic_store(&prof_usr2, true);
}

static long prof_period_ns(void) { return 1000000000L / prof_hz; }

#if PROF_THREAD_TIMERS
/* One timer_create: a timer for this thread on its CPU clock (or the monotonic clock for wall
   time) that sends SIGPROF to this thread only. */
static void prof_timer_create(prof_thr *t) {
  struct sigevent ev;
  memset(&ev, 0, sizeof ev);
  ev.sigev_notify = SIGEV_THREAD_ID;
  ev.sigev_signo = SIGPROF;
#if defined(sigev_notify_thread_id)
  ev.sigev_notify_thread_id = (pid_t)syscall(SYS_gettid);
#else
  ev._sigev_un._tid = (pid_t)syscall(SYS_gettid); /* glibc spells the member only this way */
#endif
  t->timed = timer_create(prof_wall ? CLOCK_MONOTONIC : CLOCK_THREAD_CPUTIME_ID, &ev, &t->timer) == 0;
}
/* One timer_settime: on at the profiling rate, or off. */
static void prof_timer_set(prof_thr *t, bool on) {
  if (!t->timed) return;
  struct itimerspec it;
  memset(&it, 0, sizeof it);
  if (on) {
    it.it_interval.tv_nsec = prof_period_ns();
    it.it_value.tv_nsec = prof_period_ns();
  }
  timer_settime(t->timer, 0, &it, NULL);
}
static void prof_timer_delete(prof_thr *t) {
  if (t->timed) timer_delete(t->timer);
  t->timed = false;
}
#else
/* Elsewhere one process-wide interval timer (ITIMER_PROF: CPU time), whose SIGPROF lands on a
   running thread. */
static void prof_itimer_set(bool on) {
  struct itimerval it;
  memset(&it, 0, sizeof it);
  if (on) {
    it.it_interval.tv_usec = (suseconds_t)(prof_period_ns() / 1000);
    it.it_value.tv_usec = (suseconds_t)(prof_period_ns() / 1000);
  }
  setitimer(ITIMER_PROF, &it, NULL);
}
#endif

static void prof_set_running(bool on) {
  pthread_mutex_lock(&prof_reg_mu);
  atomic_store(&prof_running, on);
  if (prof_cpu) {
#if PROF_THREAD_TIMERS
    for (prof_thr *t = prof_threads; t; t = t->next)
      if (!atomic_load(&t->done)) prof_timer_set(t, on);
#else
    prof_itimer_set(on);
#endif
  }
  pthread_mutex_unlock(&prof_reg_mu);
}

/* This thread starts being profiled (the main thread at init, each runtime thread first). */
static void prof_thread_begin(void) {
  if (prof_off || !atomic_load(&prof_inited) || prof_me) return;
  prof_thr *t = calloc(1, sizeof *t);
  if (!t) return;
  if (prof_cpu) t->ring = malloc(PROF_RING * sizeof *t->ring);
  if (prof_mem || prof_conc) t->cache = calloc(PROF_CACHE, sizeof *t->cache);
  t->start_ns = prof_now();
  prof_alloc_left = prof_rate;
  prof_cow_left = prof_rate;
  pthread_mutex_lock(&prof_reg_mu);
  t->id = prof_nthreads++;
  t->next = prof_threads;
  prof_threads = t;
#if PROF_THREAD_TIMERS
  if (prof_cpu) {
    prof_timer_create(t);
    if (atomic_load(&prof_running)) prof_timer_set(t, true);
  }
#endif
  pthread_mutex_unlock(&prof_reg_mu);
  atomic_fetch_add(&prof_started, 1);
  prof_me = t;
}

/* This thread is ending: no more samples; the collector drains what is left. */
static void prof_thread_end(void) {
  prof_thr *t = prof_me;
  if (!t) return;
  pthread_mutex_lock(&prof_reg_mu);
#if PROF_THREAD_TIMERS
  prof_timer_delete(t);
#endif
  if (t->cache)
    for (size_t i = 0; i < PROF_CACHE; i++) slot_flush(&t->cache[i]);
  heap_flush(t);
  prof_me = NULL;
  atomic_signal_fence(memory_order_seq_cst);
  t->end_ns = prof_now();
  atomic_store(&t->done, true);
  pthread_mutex_unlock(&prof_reg_mu);
  atomic_fetch_add(&prof_exited, 1);
}

/* The rings into the stack table; rings of ended threads are freed. */
static void prof_drain(void) {
  uint64_t w = (uint64_t)prof_period_ns();
  pthread_mutex_lock(&prof_reg_mu);
  pthread_mutex_lock(&prof_agg_mu);
  for (prof_thr *t = prof_threads; t; t = t->next) {
    if (!t->ring) continue;
    unsigned head = atomic_load_explicit(&t->head, memory_order_relaxed);
    unsigned tail = atomic_load_explicit(&t->tail, memory_order_acquire);
    while (head != tail) {
      const prof_sample *s = &t->ring[head % PROF_RING];
      agg_add(PK_CPU, s->label, s->f, s->n & 0x7FFFFFFFu, s->n >> 31, 1, w);
      head++;
      atomic_fetch_add_explicit(&t->taken, 1, memory_order_relaxed);
    }
    atomic_store_explicit(&t->head, head, memory_order_release);
    if (atomic_load(&t->done)) {
      free(t->ring);
      t->ring = NULL;
    }
  }
  pthread_mutex_unlock(&prof_agg_mu);
  pthread_mutex_unlock(&prof_reg_mu);
}

// ---- labels: a tree of (key, value) under a parent; a thread's label is a node id

typedef struct { uint32_t parent; char *key, *value; } prof_lab;
static pthread_mutex_t prof_lab_mu = PTHREAD_MUTEX_INITIALIZER;
static prof_lab *plabs;
static uint32_t nplabs = 1, plabs_cap; /* id 0: no label */

static char *prof_strndup(const unsigned char *s, size_t n) {
  char *r = malloc(n + 1);
  if (!r) return NULL;
  if (n) memcpy(r, s, n);
  r[n] = 0;
  return r;
}

/* The node (parent, key, value), made if new. */
static uint32_t prof_label_node(uint32_t parent, const unsigned char *k, size_t kl, const unsigned char *v, size_t vl) {
  pthread_mutex_lock(&prof_lab_mu);
  for (uint32_t i = 1; i < nplabs; i++) {
    if (plabs[i].parent == parent && strlen(plabs[i].key) == kl && strlen(plabs[i].value) == vl &&
        memcmp(plabs[i].key, k, kl) == 0 && memcmp(plabs[i].value, v, vl) == 0) {
      pthread_mutex_unlock(&prof_lab_mu);
      return i;
    }
  }
  uint32_t id = 0;
  if (nplabs >= plabs_cap) {
    uint32_t nc = plabs_cap ? plabs_cap * 2 : 64;
    prof_lab *nl = realloc(plabs, nc * sizeof *nl);
    if (nl) {
      plabs = nl;
      plabs_cap = nc;
    }
  }
  if (nplabs < plabs_cap && nplabs < 65536) {
    char *ks = prof_strndup(k, kl), *vs = prof_strndup(v, vl);
    if (ks && vs) {
      id = nplabs++;
      plabs[id].parent = parent;
      plabs[id].key = ks;
      plabs[id].value = vs;
    } else {
      free(ks);
      free(vs);
    }
  }
  pthread_mutex_unlock(&prof_lab_mu);
  return id;
}

// ---- the profile file (docs/runtime.md "Profile format")

static void pj_str(FILE *f, const char *s) {
  fputc('"', f);
  for (; s && *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') {
      fputc('\\', f);
      fputc(c, f);
    } else if (c < 0x20) {
      fprintf(f, "\\u%04x", c);
    } else {
      fputc(c, f);
    }
  }
  fputc('"', f);
}

static void pj_frames(FILE *f, const prof_fr *fr, uint32_t n, uint32_t trunc) {
  /* outermost first */
  fputs("[", f);
  bool first = true;
  if (trunc) {
    fprintf(f, "[%" PRIu32 ",0]", PROF_TRUNC);
    first = false;
  }
  for (uint32_t i = 0; i < n; i++) {
    fprintf(f, "%s[%" PRIu32 ",%" PRId32 "]", first ? "" : ",", fr[i].fn, fr[i].line);
    first = false;
  }
  fputs("]", f);
}

static pthread_mutex_t prof_write_mu = PTHREAD_MUTEX_INITIALIZER;

static const char *prof_what_text(void) {
  static char b[32];
  b[0] = 0;
  if (prof_cpu) strcat(b, "cpu,");
  if (prof_mem) strcat(b, "mem,");
  if (prof_conc) strcat(b, "conc,");
  size_t n = strlen(b);
  if (n) b[n - 1] = 0;
  return b;
}

/* Writes the profile to `path` (through `path`.tmp and a rename, so a reader never sees half
   a file); 0 or -errno. */
static int64_t prof_write(const char *path, const char *reason) {
  if (prof_off || !prof_tab) return -ENOSYS;
  pthread_mutex_lock(&prof_write_mu);
  prof_drain();
  char tmp[4200];
  snprintf(tmp, sizeof tmp, "%s.tmp", path);
  FILE *f = fopen(tmp, "w");
  if (!f) {
    int e = errno;
    pthread_mutex_unlock(&prof_write_mu);
    return -(int64_t)e;
  }
  uint64_t now = prof_now();
  uint64_t t0 = atomic_load(&prof_t0_atomic);
  fputs("{\"eider_prof\":1,\"program\":", f);
  pj_str(f, prof_tab->program);
  fprintf(f, ",\"pid\":%ld,\"reason\":", (long)getpid());
  pj_str(f, reason);
  fputs(",\"version\":", f);
  pj_str(f, prof_tab->version ? prof_tab->version : "");
  fputs(",\"what\":", f);
  pj_str(f, prof_what_text());
  fprintf(f, ",\"clock\":\"%s\",\"hz\":%ld,\"period_ns\":%ld,\"mem_rate\":%" PRId64 ",\"duration_ns\":%" PRIu64 ",\"running\":%s,\"clean_exit\":%s}\n",
          prof_wall ? "wall" : "cpu", prof_hz, prof_period_ns(), prof_rate, now - t0,
          atomic_load(&prof_running) ? "true" : "false", atomic_load(&prof_clean) ? "true" : "false");
  for (uint32_t i = 0; i < prof_tab->nfiles; i++) {
    fprintf(f, "{\"t\":\"file\",\"id\":%" PRIu32 ",\"path\":", i);
    pj_str(f, prof_tab->files[i] ? prof_tab->files[i] : "");
    fputs("}\n", f);
  }
  for (uint32_t i = 1; i < prof_tab->nfns; i++) {
    fprintf(f, "{\"t\":\"fn\",\"id\":%" PRIu32 ",\"name\":", i);
    pj_str(f, prof_tab->names[i]);
    fprintf(f, ",\"file\":%" PRIu32 "}\n", prof_tab->file_of[i]);
  }
  pthread_mutex_lock(&prof_lab_mu);
  for (uint32_t i = 1; i < nplabs; i++) {
    fprintf(f, "{\"t\":\"label\",\"id\":%" PRIu32 ",\"parent\":%" PRIu32 ",\"key\":", i, plabs[i].parent);
    pj_str(f, plabs[i].key);
    fputs(",\"value\":", f);
    pj_str(f, plabs[i].value);
    fputs("}\n", f);
  }
  pthread_mutex_unlock(&prof_lab_mu);
  uint64_t samples = 0, dropped = 0;
  pthread_mutex_lock(&prof_reg_mu);
  for (prof_thr *t = prof_threads; t; t = t->next) {
    uint64_t taken = atomic_load(&t->taken), dr = atomic_load(&t->dropped);
    samples += taken;
    dropped += dr;
    bool done = atomic_load(&t->done);
    fprintf(f, "{\"t\":\"thread\",\"id\":%" PRIu32 ",\"start_ns\":%" PRId64 ",\"end_ns\":%" PRId64 ",\"samples\":%" PRIu64 ",\"dropped\":%" PRIu64 "}\n",
            t->id, (int64_t)(t->start_ns - t0), done ? (int64_t)(t->end_ns - t0) : -1, taken, dr);
  }
  pthread_mutex_unlock(&prof_reg_mu);
  pthread_mutex_lock(&prof_agg_mu);
  for (size_t i = 0; i < agg_len; i++) {
    const prof_stack *s = &agg[i];
    fprintf(f, "{\"t\":\"stack\",\"kind\":\"%s\",\"label\":%" PRIu32 ",\"n\":%" PRIu64 ",\"w\":%" PRIu64 ",\"frames\":",
            prof_kind_names[s->kind], s->label, s->count, s->weight);
    pj_frames(f, pool + s->off, s->nf, s->trunc);
    fputs("}\n", f);
  }
  uint64_t lost = prof_agg_lost;
  pthread_mutex_unlock(&prof_agg_mu);
  /* the shared sites plus what every thread has in its slots */
  int64_t (*acc)[4] = sites ? calloc(PROF_SITES, sizeof *acc) : NULL;
  pthread_mutex_lock(&prof_reg_mu);
  prof_heap hp = heap_totals();
  for (prof_thr *t = prof_threads; acc && t; t = t->next) {
    if (!t->cache) continue;
    for (size_t k = 0; k < PROF_CACHE; k++) {
      prof_slot *c = &t->cache[k];
      prof_site *g = atomic_load_explicit(&c->s, memory_order_relaxed);
      if (!g) continue;
      size_t i = (size_t)(g - sites);
      acc[i][0] += atomic_load_explicit(&c->n, memory_order_relaxed);
      acc[i][1] += atomic_load_explicit(&c->w, memory_order_relaxed);
      acc[i][2] += atomic_load_explicit(&c->live_n, memory_order_relaxed);
      acc[i][3] += atomic_load_explicit(&c->live_w, memory_order_relaxed);
    }
  }
  pthread_mutex_unlock(&prof_reg_mu);
  for (size_t i = 0; sites && i < PROF_SITES; i++) {
    uint64_t key = atomic_load(&sites[i].key);
    if (key == 0) continue;
    uint32_t kind = (uint32_t)(key >> 56);
    uint64_t n = atomic_load(&sites[i].n), w = atomic_load(&sites[i].w);
    uint64_t ln = atomic_load(&sites[i].live_n), lw = atomic_load(&sites[i].live_w);
    if (acc) {
      n += (uint64_t)acc[i][0];
      w += (uint64_t)acc[i][1];
      ln += (uint64_t)acc[i][2];
      lw += (uint64_t)acc[i][3];
    }
    if (n == 0 && ln == 0) continue;
    fprintf(f, "{\"t\":\"site\",\"kind\":\"%s\",\"fn\":%" PRIu32 ",\"line\":%" PRId32 ",\"n\":%" PRIu64 ",\"w\":%" PRIu64,
            kind < EI_PEV_KINDS ? prof_ev_names[kind] : "?", (uint32_t)((key >> 32) & 0xFFFFFF), (int32_t)(uint32_t)key, n, w);
    if (kind == EI_PEV_ALLOC) fprintf(f, ",\"live_n\":%" PRIu64 ",\"live_w\":%" PRIu64, ln, lw);
    fputs("}\n", f);
  }
  free(acc);
  int64_t peak = atomic_load(&heap_peak);
  if (peak < hp.live) peak = hp.live;
  pthread_mutex_lock(&prof_tl_mu);
  for (size_t i = 0; i < tl_len; i++)
    fprintf(f, "{\"t\":\"heap\",\"ns\":%" PRIu64 ",\"live\":%" PRId64 ",\"peak\":%" PRId64 ",\"allocs\":%" PRIu64 ",\"threads\":%" PRIu32 "}\n",
            tl[i].ns, tl[i].live, tl[i].peak, tl[i].allocs, tl[i].threads);
  pthread_mutex_unlock(&prof_tl_mu);
  fprintf(f, "{\"t\":\"summary\",\"samples\":%" PRIu64 ",\"dropped\":%" PRIu64 ",\"stacks_lost\":%" PRIu64 ",\"sites_lost\":%" PRIu64
             ",\"allocs\":%" PRIu64 ",\"alloc_bytes\":%" PRIu64 ",\"frees\":%" PRIu64 ",\"live\":%" PRId64 ",\"live_n\":%" PRId64 ",\"peak\":%" PRId64
             ",\"threads_started\":%" PRIu64 ",\"threads_exited\":%" PRIu64 "}\n",
          samples, dropped, lost, (uint64_t)atomic_load(&prof_sites_lost), (uint64_t)hp.allocs, (uint64_t)hp.bytes,
          (uint64_t)hp.frees, hp.live, hp.live_n, peak,
          (uint64_t)atomic_load(&prof_started), (uint64_t)atomic_load(&prof_exited));
  int bad = ferror(f);
  int e = errno;
  if (fclose(f) != 0 && !bad) {
    bad = 1;
    e = errno;
  }
  if (!bad && rename(tmp, path) != 0) {
    bad = 1;
    e = errno;
  }
  if (bad) remove(tmp);
  pthread_mutex_unlock(&prof_write_mu);
  return bad ? -(int64_t)(e ? e : EIO) : 0;
}

/* Forget what was recorded (the live heap stays: it is the state, not a count). */
static void prof_reset(void) {
  pthread_mutex_lock(&prof_write_mu);
  prof_drain();
  pthread_mutex_lock(&prof_agg_mu);
  agg_len = 0;
  pool_len = 0;
  if (agg_idx) memset(agg_idx, 0, agg_icap * sizeof *agg_idx);
  prof_agg_lost = 0;
  pthread_mutex_unlock(&prof_agg_mu);
  for (size_t i = 0; sites && i < PROF_SITES; i++) {
    atomic_store(&sites[i].n, 0);
    atomic_store(&sites[i].w, 0);
  }
  pthread_mutex_lock(&prof_tl_mu);
  tl_len = 0;
  pthread_mutex_unlock(&prof_tl_mu);
  atomic_store(&heap_peak, atomic_load(&heap_live));
  pthread_mutex_lock(&prof_reg_mu);
  for (prof_thr *t = prof_threads; t; t = t->next) {
    atomic_store(&t->taken, 0);
    atomic_store(&t->dropped, 0);
    /* (a count its thread adds at the same moment can survive the reset: snapshots are
       approximate while threads run) */
    for (size_t k = 0; t->cache && k < PROF_CACHE; k++) {
      atomic_store_explicit(&t->cache[k].n, 0, memory_order_relaxed);
      atomic_store_explicit(&t->cache[k].w, 0, memory_order_relaxed);
    }
  }
  pthread_mutex_unlock(&prof_reg_mu);
  atomic_store(&prof_t0_atomic, prof_now());
  pthread_mutex_unlock(&prof_write_mu);
}

// ---- the collector thread

static pthread_t prof_coll;
static atomic_bool prof_coll_stop;
static bool prof_coll_on;

static void *prof_collector(void *u) {
  (void)u;
  struct timespec ts = {0, 20000000L};
  while (!atomic_load(&prof_coll_stop)) {
    nanosleep(&ts, NULL);
    prof_drain();
    if (prof_mem && atomic_load(&prof_running) && ++tl_tick % tl_every == 0) tl_add();
    if (atomic_exchange(&prof_usr2, false)) prof_write(prof_path, "signal");
  }
  return NULL;
}

static void prof_at_exit(void) {
  if (prof_off) return;
  if (prof_cpu) {
    atomic_store(&prof_running, false);
#if !PROF_THREAD_TIMERS
    prof_itimer_set(false);
#endif
  }
  if (prof_coll_on) {
    atomic_store(&prof_coll_stop, true);
    pthread_join(prof_coll, NULL);
    prof_coll_on = false;
  }
  if (prof_mem) tl_add();
  int64_t r = prof_write(prof_path, "exit");
  if (r < 0) fprintf(stderr, "eider: cannot write the profile %s: %s\n", prof_path, strerror((int)-r));
}

// ---- control (std/profile through eider_core's ec_prof; core/ABI.md "Profiling")

typedef int64_t (*ec_prof_fn)(int32_t op, int64_t arg, const unsigned char *in, size_t len);
extern _Atomic(ec_prof_fn) ec_prof_hook;

static int64_t prof_ctl(int32_t op, int64_t arg, const unsigned char *in, size_t len) {
  if (prof_off) return -ENOSYS;
  switch (op) {
  case 0: /* profiling? 1 + 2 * running */
    return 1 + (atomic_load(&prof_running) ? 2 : 0);
  case 1:
    prof_set_running(true);
    return 0;
  case 2:
    prof_set_running(false);
    return 0;
  case 3:
    prof_reset();
    return 0;
  case 4: { /* snapshot to the path in `in` (empty: the profile path) */
    char p[4096];
    if (len >= sizeof p) return -ENAMETOOLONG;
    if (len) memcpy(p, in, len);
    p[len] = 0;
    return prof_write(len ? p : prof_path, "snapshot");
  }
  case 5: { /* label: `in` is key NUL value; the previous label id */
    const unsigned char *z = memchr(in, 0, len);
    if (!z) return -EINVAL;
    size_t kl = (size_t)(z - in);
    uint32_t prev = prof_label;
    uint32_t id = prof_label_node(prev, in, kl, z + 1, len - kl - 1);
    if (id) prof_label = id;
    return prev;
  }
  case 6: /* restore label `arg` */
    if (arg >= 0 && arg < 65536) prof_label = (uint32_t)arg;
    return 0;
  case 7: /* the current label id */
    return prof_label;
  default:
    return -EINVAL;
  }
}

/* An integer from the environment, or `def` when it isn't set or isn't one in [lo, hi]. */
static long prof_env_long(const char *name, long def, long lo, long hi) {
  const char *v = getenv(name);
  if (!v || !*v) return def;
  char *end;
  long x = strtol(v, &end, 10);
  return *end == 0 && x >= lo && x <= hi ? x : def;
}

static void prof_handler(int sig, void (*h)(int)) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = h;
  sa.sa_flags = SA_RESTART;
  sigemptyset(&sa.sa_mask);
  sigaction(sig, &sa, NULL);
}

void ei_prof_init(const ei_prof_table *t) {
  if (atomic_load(&prof_inited)) return;
  prof_tab = t;
  const char *p = getenv("EIDER_PROF");
  if (p && (strcmp(p, "off") == 0 || strcmp(p, "0") == 0)) {
    prof_off = true;
    atomic_store(&prof_inited, true);
    return;
  }
  if (p && *p && strlen(p) < sizeof prof_path) strcpy(prof_path, p);
  const char *c = getenv("EIDER_PROF_CLOCK");
  prof_wall = c && strcmp(c, "wall") == 0;
  prof_hz = prof_env_long("EIDER_PROF_HZ", 99, 1, 10000);
  prof_rate = prof_env_long("EIDER_PROF_MEM_RATE", 512 * 1024, 1, 1L << 30);
  prof_cpu = (t->what & EI_PROF_CPU) != 0;
  prof_mem = (t->what & EI_PROF_MEM) != 0;
  prof_conc = (t->what & EI_PROF_CONC) != 0;
  sites = calloc(PROF_SITES, sizeof *sites);
  prof_t0 = prof_now();
  atomic_store(&prof_t0_atomic, prof_t0);
  atomic_store(&ec_prof_hook, prof_ctl);
  atomic_store(&prof_inited, true);
  if (prof_cpu) prof_handler(SIGPROF, prof_on_sigprof);
  prof_handler(SIGUSR2, prof_on_sigusr2);
  prof_thread_begin();
  /* the collector never takes the profiling signals */
  sigset_t all, old;
  sigfillset(&all);
  pthread_sigmask(SIG_SETMASK, &all, &old);
  prof_coll_on = pthread_create(&prof_coll, NULL, prof_collector, NULL) == 0;
  pthread_sigmask(SIG_SETMASK, &old, NULL);
  atexit(prof_at_exit);
  if (prof_env_long("EIDER_PROF_START", 1, 0, 1)) prof_set_running(true);
}

static bool prof_mem_on(void) { return prof_mem && !prof_off; }
static bool prof_conc_on(void) { return prof_conc && !prof_off && atomic_load_explicit(&prof_inited, memory_order_relaxed); }
static void prof_clean_exit(void) { atomic_store(&prof_clean, true); }

/* ei_mutex_lock when waits are profiled: a lock that is free costs a trylock; a wait is timed. */
static void prof_mutex_lock(ei_mutex *m) {
  int r = pthread_mutex_trylock(&m->mu);
  if (r == 0) return;
  if (r == EBUSY) {
    uint64_t t0 = prof_now();
    r = pthread_mutex_lock(&m->mu);
    if (r == 0) {
      prof_wait(EI_PEV_LOCK, prof_now() - t0);
      return;
    }
  }
  ei_trap("cannot lock a mutex", 0);
}
