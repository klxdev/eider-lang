// Tests for the profiling runtime (core/eider_prof.c, compiled into eider_rt.c with
// -DEI_RT_PROFILE; contract: core/RUNTIME.md "Profiling", the file format in docs/runtime.md
// "Profile format"). Run by tests/core/run.sh, linked with core/eider_core.c (the control
// call ec_prof), also under ASan+UBSan and TSan. It does what generated code does: a name
// table, shadow frames, allocations, events, contended locks and channel waits on runtime
// threads, labels, then writes a snapshot through ec_prof and checks what the file says.
#define _POSIX_C_SOURCE 200809L

#define EI_RT_PROFILE 1
#include "eider_rt.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

void ec_in_clear(void);
void ec_in_push(int32_t b);
int64_t ec_prof(int32_t op, int64_t arg);

static int failures, checks;

static void check(int ok, const char *what, int line) {
  checks++;
  if (!ok) {
    failures++;
    fprintf(stderr, "FAIL prof_test.c:%d: %s\n", line, what);
  }
}
#define CHECK(c) check((c) ? 1 : 0, #c, __LINE__)

static const char *const names[] = {"", "main", "worker", "leaf"};
static const uint32_t file_of[] = {0, 0, 1, 1};
static const char *const files[] = {"prof_test.ei", "lib/work.ei"};
static const ei_prof_table tab = {names, file_of, 4, files, 2, EI_PROF_CPU | EI_PROF_MEM | EI_PROF_CONC, "prof_test.ei", "0.1.0"};

static void send(const char *s, size_t n) {
  ec_in_clear();
  for (size_t i = 0; i < n; i++) ec_in_push((unsigned char)s[i]);
}

static volatile uint64_t sink;

/* about `ms` milliseconds of CPU in fn 3 at line 7 */
static void burn(uint64_t ms) {
  ei_prof_frame *f = ei_prof_enter(3);
  f->line = 7;
  struct timespec a, b;
  clock_gettime(CLOCK_MONOTONIC, &a);
  for (;;) {
    for (int i = 0; i < 100000; i++) sink += (uint64_t)i * 31u;
    clock_gettime(CLOCK_MONOTONIC, &b);
    uint64_t d = (uint64_t)(b.tv_sec - a.tv_sec) * 1000u + (uint64_t)(b.tv_nsec / 1000000) - (uint64_t)(a.tv_nsec / 1000000);
    if ((int64_t)d >= (int64_t)ms) break;
  }
  ei_prof_leave();
}

static ei_mutex mu;
static ei_chan ch;

/* a runtime thread: holds the mutex while burning (so the others wait), sends one value */
static void *worker(void *arg) {
  (void)arg;
  ei_prof_frame *f = ei_prof_enter(2);
  f->line = 20;
  ei_mutex_lock(&mu);
  burn(30);
  ei_mutex_unlock(&mu);
  f->line = 21;
  int64_t v = 1;
  ei_chan_send(&ch, &v);
  ei_prof_leave();
  return NULL;
}

static char *slurp(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return NULL;
  size_t cap = 1 << 16, n = 0;
  char *b = malloc(cap);
  int c;
  while (b && (c = fgetc(f)) != EOF) {
    if (n + 1 >= cap) {
      char *nb = realloc(b, cap *= 2);
      if (!nb) {
        free(b);
        b = NULL;
        break;
      }
      b = nb;
    }
    b[n++] = (char)c;
  }
  if (b) b[n] = 0;
  fclose(f);
  return b;
}

int main(int argc, char **argv) {
  const char *snap = argc > 1 ? argv[1] : "prof_test.snapshot";
  ei_set_file("prof_test.ei");
  CHECK(ec_prof(0, 0) == -38); /* no profiler before init: -ENOSYS */
  ei_prof_init(&tab);
  ei_prof_init(&tab); /* idempotent */
  CHECK(ec_prof(0, 0) == 3); /* profiling and sampling */
  ei_prof_frame *f = ei_prof_enter(1);
  f->line = 5;
  /* ten allocations at main:5, one kept */
  void *keep = NULL;
  for (int i = 0; i < 10; i++) {
    void *p = ei_alloc(100);
    if (i == 0) keep = p; else ei_free(p);
  }
  /* a buffer grown at main:6 and a shared String unshared */
  f->line = 6;
  void *d = ei_buf_alloc(4, 8);
  d = ei_buf_grow(d, 64, 8);
  ei_buf_free(d);
  ei_String s1 = ei_str_from("shared text");
  ei_String s2 = ei_share_String(&s1);
  ei_str_unique(&s2);
  ei_drop_String(&s1);
  ei_drop_String(&s2);
  ei_prof_ev(EI_PEV_COPY, 24);
  /* labels: phase=burn while burning */
  send("phase\0burn", 10);
  int64_t prev = ec_prof(5, 0);
  CHECK(prev == 0);
  CHECK(ec_prof(7, 0) > 0);
  f->line = 8;
  burn(200);
  ec_prof(6, prev);
  CHECK(ec_prof(7, 0) == 0);
  /* contention: four threads take the mutex in turn; main waits for their values */
  ei_mutex_init(&mu);
  ei_chan_init(&ch, sizeof(int64_t));
  ei_thread th[4];
  f->line = 9;
  for (int i = 0; i < 4; i++) ei_thread_start(&th[i], worker, NULL);
  int64_t v, got = 0;
  f->line = 10;
  for (int i = 0; i < 4; i++)
    if (ei_chan_recv(&ch, &v)) got += v;
  CHECK(got == 4);
  for (int i = 0; i < 4; i++) ei_thread_destroy(&th[i]);
  ei_chan_destroy(&ch);
  ei_mutex_destroy(&mu);
  /* stop, snapshot, read it back */
  CHECK(ec_prof(2, 0) == 0);
  CHECK(ec_prof(0, 0) == 1);
  send(snap, strlen(snap));
  CHECK(ec_prof(4, 0) == 0);
  char *t = slurp(snap);
  CHECK(t != NULL);
  if (t) {
    CHECK(strstr(t, "{\"eider_prof\":1,\"program\":\"prof_test.ei\"") == t);
    CHECK(strstr(t, "\"reason\":\"snapshot\",\"version\":\"0.1.0\"") != NULL);
    CHECK(strstr(t, "{\"t\":\"fn\",\"id\":3,\"name\":\"leaf\",\"file\":1}") != NULL);
    CHECK(strstr(t, "{\"t\":\"file\",\"id\":1,\"path\":\"lib/work.ei\"}") != NULL);
    CHECK(strstr(t, "{\"t\":\"site\",\"kind\":\"alloc\",\"fn\":1,\"line\":5,\"n\":10,\"w\":1000,\"live_n\":1,\"live_w\":100}") != NULL);
    CHECK(strstr(t, "{\"t\":\"site\",\"kind\":\"cow\",\"fn\":1,\"line\":6,\"n\":1,") != NULL);
    CHECK(strstr(t, "{\"t\":\"site\",\"kind\":\"copy\",\"fn\":1,\"line\":6,\"n\":1,\"w\":24}") != NULL);
    CHECK(strstr(t, "{\"t\":\"site\",\"kind\":\"spawn\",\"fn\":1,\"line\":9,\"n\":4,") != NULL);
    CHECK(strstr(t, "\"kind\":\"lock\",\"fn\":2,\"line\":20,") != NULL);
    CHECK(strstr(t, "\"kind\":\"recv\",\"fn\":1,\"line\":10,") != NULL);
    CHECK(strstr(t, "{\"t\":\"label\",\"id\":1,\"parent\":0,\"key\":\"phase\",\"value\":\"burn\"}") != NULL);
    /* cpu samples in leaf under the label, with main as the caller at line 8 */
    CHECK(strstr(t, "\"kind\":\"cpu\",\"label\":1,") != NULL);
    CHECK(strstr(t, "\"frames\":[[1,8],[3,7]]") != NULL);
    CHECK(strstr(t, "\"threads_started\":5,\"threads_exited\":4") != NULL);
    free(t);
  }
  remove(snap);
  ei_free(keep);
  ei_prof_leave();
  ei_check_leaks();
  printf("%d checks, %d failures\n", checks, failures);
  return failures ? 1 : 0;
}
