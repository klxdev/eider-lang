// Tests for the task scheduler (core/eider_rt.c "tasks", docs/design/lightweight-tasks.md): many
// tasks, parking on channels, joins, sleeps and descriptors, work spread over workers, the
// starvation guard, a trap contained across a park, a stack overflow reported from a task's
// guard. Built with eider_rt.c and eider_core.c; run by tests/core/run.sh.
#define _POSIX_C_SOURCE 200809L

#include "../../core/eider_rt.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int64_t ec_sleep_ns(int64_t ns);
int64_t ec_fd_wait(int32_t fd, int32_t interest, int64_t timeout_ms);
int64_t ec_fd_wait2(int32_t fd, int32_t interest, int32_t fd2, int32_t interest2, int64_t timeout_ms);

static int failures, checks;
static void check(int ok, const char *what, int line) {
  checks++;
  if (!ok) {
    failures++;
    fprintf(stderr, "FAIL task_test.c:%d: %s\n", line, what);
  }
}
#define CHECK(c) check((c) ? 1 : 0, #c, __LINE__)
#define EQI(e, want) check((int64_t)(e) == (int64_t)(want), #e " == " #want, __LINE__)

static int64_t now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

// ---- many tasks blocked on one channel, released by sends

static ei_chan *shared_chan;

static void *recv_one(void *arg) {
  int64_t v = 0;
  if (!ei_chan_recv(shared_chan, &v)) v = -1;
  *(int64_t *)arg = v;
  return NULL;
}

static void test_many_blocked(void) {
  enum { N = 5000 };
  ei_chan c;
  ei_chan_init(&c, sizeof(int64_t));
  shared_chan = &c;
  static ei_thread th[N];
  static int64_t out[N];
  for (int i = 0; i < N; i++) ei_thread_start(&th[i], recv_one, &out[i]);
  struct timespec ts = {0, 50 * 1000 * 1000};
  nanosleep(&ts, NULL);
  for (int64_t i = 1; i <= N; i++) ei_chan_send(&c, &i);
  int64_t sum = 0;
  for (int i = 0; i < N; i++) {
    ei_thread_join(&th[i]);
    sum += out[i];
    ei_thread_destroy(&th[i]);
  }
  EQI(sum, (int64_t)N * (N + 1) / 2);
  ei_chan_destroy(&c);
}

// ---- a task starts tasks and joins them; yield

typedef struct {
  int depth;
  int64_t result;
} node;

static void *tree(void *arg) {
  node *n = arg;
  if (n->depth == 0) {
    n->result = 1;
    return NULL;
  }
  node kids[2] = {{n->depth - 1, 0}, {n->depth - 1, 0}};
  ei_thread th[2];
  for (int i = 0; i < 2; i++) ei_thread_start(&th[i], tree, &kids[i]);
  ec_sleep_ns(0); /* a yield */
  for (int i = 0; i < 2; i++) {
    ei_thread_join(&th[i]);
    ei_thread_destroy(&th[i]);
  }
  n->result = kids[0].result + kids[1].result + 1;
  return NULL;
}

static void test_tree(void) {
  node root = {10, 0};
  ei_thread t;
  ei_thread_start(&t, tree, &root);
  ei_thread_join(&t);
  ei_thread_destroy(&t);
  EQI(root.result, 2047); /* 2^11 - 1 */
}

// ---- sleeping tasks overlap, a descriptor wait wakes on data and on the deadline

static void *sleeper(void *arg) {
  ec_sleep_ns(100 * 1000 * 1000);
  *(int *)arg = 1;
  return NULL;
}

static void test_sleep_overlaps(void) {
  enum { N = 2000 };
  static ei_thread th[N];
  static int done[N];
  int64_t t0 = now_ms();
  for (int i = 0; i < N; i++) ei_thread_start(&th[i], sleeper, &done[i]);
  int all = 1;
  for (int i = 0; i < N; i++) {
    ei_thread_join(&th[i]);
    all &= done[i];
    ei_thread_destroy(&th[i]);
  }
  int64_t took = now_ms() - t0;
  CHECK(all);
  CHECK(took >= 100);
  CHECK(took < 1500); /* 2000 sleeps of 100 ms, not 200 s */
}

typedef struct {
  int rfd, wfd;
  int64_t got;
  int64_t timed_out;
} pipe_ctx;

static void *pipe_reader(void *arg) {
  pipe_ctx *p = arg;
  p->timed_out = ec_fd_wait(p->rfd, 1, 30); /* nothing yet: 0 at the deadline */
  p->got = ec_fd_wait(p->rfd, 1, 5000);     /* readable once the writer ran */
  return NULL;
}

static void *pipe_writer(void *arg) {
  pipe_ctx *p = arg;
  ec_sleep_ns(120 * 1000 * 1000);
  if (write(p->wfd, "x", 1) != 1) p->got = -99;
  return NULL;
}

static void test_fd_wait(void) {
  int fds[2];
  CHECK(pipe(fds) == 0);
  pipe_ctx p = {fds[0], fds[1], -1, -1};
  ei_thread r, w;
  ei_thread_start(&r, pipe_reader, &p);
  ei_thread_start(&w, pipe_writer, &p);
  ei_thread_join(&r);
  ei_thread_join(&w);
  ei_thread_destroy(&r);
  ei_thread_destroy(&w);
  EQI(p.timed_out, 0);
  EQI(p.got, 1);
  close(fds[0]);
  close(fds[1]);
}

static void *pair_waiter(void *arg) {
  pipe_ctx *p = arg; /* rfd: the first pipe's read end, wfd: the second's */
  p->timed_out = ec_fd_wait2(p->rfd, 1, p->wfd, 1, 30);
  p->got = ec_fd_wait2(p->rfd, 1, p->wfd, 1, 5000);
  return NULL;
}

static void test_fd_wait2(void) {
  int a[2], b[2];
  CHECK(pipe(a) == 0 && pipe(b) == 0);
  pipe_ctx p = {a[0], b[0], -1, -1};
  ei_thread t;
  ei_thread_start(&t, pair_waiter, &p);
  struct timespec ts = {0, 100 * 1000 * 1000};
  nanosleep(&ts, NULL);
  CHECK(write(b[1], "y", 1) == 1);
  ei_thread_join(&t);
  ei_thread_destroy(&t);
  EQI(p.timed_out, 0);
  EQI(p.got, 1 << 4); /* the second descriptor is readable */
  close(a[0]);
  close(a[1]);
  close(b[0]);
  close(b[1]);
}

// ---- the starvation guard: more tasks stuck in blocking reads than workers

static void *blocked_reader(void *arg) {
  pipe_ctx *p = arg;
  char c;
  p->got = read(p->rfd, &c, 1); /* blocks the worker: a plain system call */
  return NULL;
}

static void *late_writer(void *arg) {
  pipe_ctx *p = arg;
  if (write(p->wfd, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 32) != 32) p->got = -99;
  return NULL;
}

static void test_starvation_guard(void) {
  enum { N = 12 }; /* the workers are set to 2 in main */
  int fds[2];
  CHECK(pipe(fds) == 0);
  static pipe_ctx ps[N];
  static ei_thread th[N];
  ei_thread wt;
  for (int i = 0; i < N; i++) {
    ps[i] = (pipe_ctx){fds[0], fds[1], -1, 0};
    ei_thread_start(&th[i], blocked_reader, &ps[i]);
  }
  struct timespec ts = {0, 100 * 1000 * 1000};
  nanosleep(&ts, NULL);
  /* every worker is stuck in read(2); this one can only run if the runtime added a worker */
  pipe_ctx wp = {fds[0], fds[1], 0, 0};
  ei_thread_start(&wt, late_writer, &wp);
  int64_t sum = 0;
  for (int i = 0; i < N; i++) {
    ei_thread_join(&th[i]);
    sum += ps[i].got;
    ei_thread_destroy(&th[i]);
  }
  ei_thread_join(&wt);
  ei_thread_destroy(&wt);
  EQI(sum, N);
  EQI(wp.got, 0);
  close(fds[0]);
  close(fds[1]);
}

// ---- a trap contained by ei_try after the task parked and (likely) moved to another worker

static ei_chan go_chan, done_chan;

static void trapper(void *a, void *b) {
  (void)a;
  (void)b;
  int64_t v;
  ei_chan_recv(&go_chan, &v); /* parks */
  ec_sleep_ns(1000000);       /* parks again, maybe on another worker */
  ei_trap("boom after parking", 3);
}

static void *try_task(void *arg) {
  (void)arg;
  ei_String msg;
  int32_t r = ei_try(trapper, NULL, NULL, &msg);
  int64_t one = r == 1 && msg.len > 0 && strstr(msg.p, "boom after parking") != NULL;
  ei_drop_String(&msg);
  ei_chan_send(&done_chan, &one);
  return NULL;
}

static void test_trap_across_park(void) {
  ei_chan_init(&go_chan, sizeof(int64_t));
  ei_chan_init(&done_chan, sizeof(int64_t));
  ei_thread t;
  ei_thread_start(&t, try_task, NULL);
  struct timespec ts = {0, 20 * 1000 * 1000};
  nanosleep(&ts, NULL);
  int64_t go = 1, got = 0;
  ei_chan_send(&go_chan, &go);
  ei_chan_recv(&done_chan, &got);
  EQI(got, 1);
  ei_thread_join(&t);
  ei_thread_destroy(&t);
  ei_chan_destroy(&go_chan);
  ei_chan_destroy(&done_chan);
}

// ---- a stack overflow in a task is reported from its guard

static int64_t deep(int64_t n) {
  volatile char pad[512];
  pad[0] = (char)n;
  return n < 0 ? 0 : deep(n + 1) + pad[0];
}

static void *overflow(void *arg) {
  (void)arg;
  return (void *)(intptr_t)deep(0);
}

static void child_overflow(void) {
  ei_thread t;
  ei_thread_start(&t, overflow, NULL);
  ei_thread_join(&t);
  _exit(0);
}

static void test_overflow(void) {
  fflush(stdout);
  fflush(stderr);
  pid_t pid = fork();
  if (pid == 0) {
    /* a fresh process: a fork would have no workers */
    if (!freopen("/dev/null", "w", stderr)) _exit(3);
    execl("/proc/self/exe", "task_test", "overflow", (char *)NULL);
    _exit(3);
  }
  int st = 0;
  waitpid(pid, &st, 0);
#if defined(EI_TEST_SANITIZED)
  CHECK(!(WIFEXITED(st) && WEXITSTATUS(st) == 0));
#else
  CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 101);
#endif
}

#define RUN(f)                                      \
  do {                                              \
    if (getenv("TASK_TEST_V")) fprintf(stderr, "%s\n", #f); \
    f();                                            \
  } while (0)

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "overflow") == 0) child_overflow();
  setenv("EIDER_WORKERS", "2", 1);
  setenv("EIDER_WORKERS_MAX", "64", 1);
  ei_set_file("task_test");
  RUN(test_many_blocked);
  RUN(test_tree);
  RUN(test_sleep_overlaps);
  RUN(test_fd_wait);
  RUN(test_fd_wait2);
  RUN(test_trap_across_park);
  RUN(test_starvation_guard);
  RUN(test_overflow);
  printf("%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
