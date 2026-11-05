// Tests for the task scheduler (core/eider_rt.c "tasks", docs/design/lightweight-tasks.md): many
// tasks, parking on channels, joins, sleeps and descriptors, work spread over workers, the
// starvation guard, a trap contained across a park, a stack overflow reported from a task's
// guard. Built with eider_rt.c and eider_core.c; run by tests/core/run.sh.
#define _POSIX_C_SOURCE 200809L

#include "../../core/eider_rt.h"

#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
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

static const char *self_path;

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
    execl(self_path, "task_test", "overflow", (char *)NULL);
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

// ---- parkers (core "Parkers"): handles, permits, races, tasks, fork; the poller of an Eider Loop

int64_t ec_parker_new(void);
int64_t ec_parker_park(int64_t h, int64_t timeout_ms);
int64_t ec_parker_unpark(int64_t h);
int64_t ec_parker_clear(int64_t h);
int64_t ec_parker_close(int64_t h);
int64_t ec_fd_wait_ev(int32_t fd, int32_t interest, int64_t h, int64_t timeout_ms);
int64_t ec_poll_new(void);
int64_t ec_poll_ctl(int32_t pfd, int32_t op, int32_t fd, int32_t interest, int64_t token);
int64_t ec_poll_wait(int32_t pfd, int32_t max, int64_t timeout_ms);

static int count_dir(const char *path) {
  DIR *d = opendir(path);
  int n = 0;
  if (!d) return -1;
  while (readdir(d)) n++;
  closedir(d);
  return n;
}

static void *parker_basic_body(void *arg) {
  int64_t p = ec_parker_new();
  int64_t bad = 0;
  if (p <= 0) bad++;
  if (ec_parker_park(p, 0) != 0) bad++;
  ec_parker_unpark(p);
  if (ec_parker_park(p, 0) != 1) bad++; /* the permit */
  if (ec_parker_park(p, 0) != 0) bad++; /* taken */
  ec_parker_unpark(p);
  ec_parker_unpark(p);
  if (ec_parker_park(p, 10) != 1) bad++; /* two unparks are one */
  int64_t t0 = now_ms();
  if (ec_parker_park(p, 25) != 0) bad++;
  if (now_ms() - t0 < 24) bad++;
  ec_parker_unpark(p);
  ec_parker_clear(p);
  if (ec_parker_park(p, 0) != 0) bad++; /* cleared */
  if (ec_parker_close(p) != 0) bad++;
  if (ec_parker_close(p) != -EBADF) bad++;
  if (ec_parker_unpark(p) != -EBADF) bad++;
  if (ec_parker_park(p, 0) != -EBADF) bad++;
  *(int64_t *)arg = bad;
  return NULL;
}

static void test_parker_basic(void) {
  int64_t bad = -1;
  parker_basic_body(&bad); /* on this thread */
  EQI(bad, 0);
  bad = -1;
  ei_thread t; /* in a task (or thread: EIDER_TASKS=threads) */
  ei_thread_start(&t, parker_basic_body, &bad);
  ei_thread_join(&t);
  ei_thread_destroy(&t);
  EQI(bad, 0);
}

static void test_parker_stale_and_many(void) {
  int64_t p = ec_parker_new();
  ec_parker_close(p);
  int64_t q = ec_parker_new(); /* the same slot, another generation */
  CHECK(q != p);
  EQI(ec_parker_unpark(p), -EBADF); /* a stale handle does not reach q */
  EQI(ec_parker_park(q, 0), 0);
  ec_parker_close(q);
  enum { N = 200000 };
  static int64_t hs[N];
  int before = count_dir("/proc/self/fd");
  for (int i = 0; i < N; i++) hs[i] = ec_parker_new();
  int all = 1;
  for (int i = 0; i < N; i++) all &= hs[i] > 0;
  CHECK(all);
  CHECK(count_dir("/proc/self/fd") == before); /* no descriptor each */
  for (int i = 0; i < N; i++) ec_parker_unpark(hs[i]);
  for (int i = 0; i < N; i += 997) EQI(ec_parker_park(hs[i], 0), 1);
  for (int i = 0; i < N; i++) ec_parker_close(hs[i]);
}

// ---- many tasks parked on their own parker: no descriptors, all wake

enum { PKN = 20000 };
static int64_t pk_h[PKN];
static atomic_int pk_ready;

static void *pk_waiter(void *arg) {
  int64_t i = (int64_t)(intptr_t)arg;
  int64_t p = ec_parker_new();
  pk_h[i] = p;
  atomic_fetch_add(&pk_ready, 1);
  int64_t r = ec_parker_park(p, -1);
  ec_parker_close(p);
  return (void *)(intptr_t)r;
}

static void test_parker_many_tasks(void) {
  if (getenv("EIDER_TASKS")) return; /* 20,000 threads: not what is tested */
  static ei_thread th[PKN];
  atomic_store(&pk_ready, 0);
  int before = count_dir("/proc/self/fd");
  for (int64_t i = 0; i < PKN; i++) ei_thread_start(&th[i], pk_waiter, (void *)(intptr_t)i);
  for (int spin = 0; atomic_load(&pk_ready) < PKN && spin < 20000; spin++) {
    struct timespec ts = {0, 1000000};
    nanosleep(&ts, NULL);
  }
  EQI(atomic_load(&pk_ready), PKN);
  struct timespec ts = {0, 50 * 1000 * 1000};
  nanosleep(&ts, NULL); /* let them all park */
  int during = count_dir("/proc/self/fd");
  CHECK(during <= before + 4); /* tasks: no eventfd each; threads would have one each (here the same: 0) */
  for (int i = 0; i < PKN; i++) ec_parker_unpark(pk_h[i]);
  int ok = 1;
  for (int i = 0; i < PKN; i++) {
    ei_thread_join(&th[i]);
    ei_thread_destroy(&th[i]);
  }
  CHECK(ok);
}

// ---- a timed park races an unpark: exactly one permit is accounted for

typedef struct {
  int64_t p;
  int64_t ms;
  int64_t r;
} race_ctx;

static void *timed_parker(void *arg) {
  race_ctx *c = arg;
  c->r = ec_parker_park(c->p, c->ms);
  return NULL;
}

static void test_parker_timer_race(void) {
  int bad = 0, woke = 0, timed = 0;
  for (int i = 0; i < 1500; i++) {
    race_ctx c = {ec_parker_new(), 1, -1};
    ei_thread t;
    ei_thread_start(&t, timed_parker, &c);
    /* around the 1 ms deadline: before, at, and after it */
    struct timespec ts = {0, (long)(i % 40) * 50 * 1000};
    nanosleep(&ts, NULL);
    ec_parker_unpark(c.p);
    ei_thread_join(&t);
    ei_thread_destroy(&t);
    int64_t again = ec_parker_park(c.p, 0);
    if (c.r == 1) woke++;
    else timed++;
    if (c.r + again != 1) bad++; /* the one unpark is either taken by the park or still there */
    ec_parker_close(c.p);
  }
  EQI(bad, 0);
  CHECK(woke > 0 && timed > 0);
}

// ---- a descriptor wait races an unpark, and the unpark of a closed parker is harmless

typedef struct {
  int rfd;
  int64_t p;
  int64_t r;
} fdrace_ctx;

static void *ev_waiter(void *arg) {
  fdrace_ctx *c = arg;
  c->r = ec_fd_wait_ev(c->rfd, 1, c->p, 2000);
  return NULL;
}

static void test_fd_wait_ev_race(void) {
  int fds[2];
  CHECK(pipe(fds) == 0);
  int bad = 0, both = 0, only_fd = 0, only_pk = 0;
  for (int i = 0; i < 3000; i++) {
    fdrace_ctx c = {fds[0], ec_parker_new(), -1};
    ei_thread t;
    ei_thread_start(&t, ev_waiter, &c);
    struct timespec ts = {0, (long)(i % 30) * 20 * 1000};
    nanosleep(&ts, NULL);
    if (i & 1) {
      ec_parker_unpark(c.p);
      if (write(fds[1], "x", 1) != 1) bad++;
    } else {
      if (write(fds[1], "x", 1) != 1) bad++;
      ec_parker_unpark(c.p);
    }
    ei_thread_join(&t);
    ei_thread_destroy(&t);
    int64_t again = ec_parker_park(c.p, 0);
    if (c.r <= 0) bad++;
    if ((c.r & 1) && (c.r & 0x100)) both++;
    else if (c.r & 1) only_fd++;
    else if (c.r & 0x100) only_pk++;
    else bad++;
    /* the permit: taken by the wait (then none left), or still there */
    if (((c.r & 0x100) ? 1 : 0) + again != 1) bad++;
    char b[8];
    if (read(fds[0], b, sizeof b) != 1) bad++; /* the byte is still there: a wait doesn't read */
    ec_parker_close(c.p);
  }
  EQI(bad, 0);
  CHECK(both + only_fd + only_pk == 3000);
  close(fds[0]);
  close(fds[1]);
}

// ---- unpark and park alternate between two tasks with long timers: the timers are removed

typedef struct {
  int64_t mine, other;
  int rounds;
  int64_t bad;
} pp_ctx;

static void *pp_body(void *arg) {
  pp_ctx *c = arg;
  for (int i = 0; i < c->rounds; i++) {
    if (ec_parker_park(c->mine, 3600 * 1000) != 1) c->bad++;
    ec_parker_unpark(c->other);
  }
  return NULL;
}

static void test_parker_ping_pong(void) {
  pp_ctx a = {ec_parker_new(), ec_parker_new(), 20000, 0};
  pp_ctx b = {a.other, a.mine, 20000, 0};
  ei_thread ta, tb;
  ei_thread_start(&ta, pp_body, &a);
  ei_thread_start(&tb, pp_body, &b);
  ec_parker_unpark(a.mine); /* start a */
  ei_thread_join(&ta);
  ei_thread_join(&tb);
  ei_thread_destroy(&ta);
  ei_thread_destroy(&tb);
  /* a's last unpark leaves a permit for b's... b ended: the numbers of parks match */
  EQI(a.bad + b.bad, 0);
  /* the reactor's timers are intact: a short timed wait still ends on time */
  int64_t p = ec_parker_new();
  int64_t t0 = now_ms();
  EQI(ec_parker_park(p, 20), 0);
  CHECK(now_ms() - t0 >= 19 && now_ms() - t0 < 1000);
  ec_parker_close(p);
  ec_parker_close(a.mine);
  ec_parker_close(a.other);
}

// ---- ec_poll_wait in a task parks the task: a worker is free, and no worker is added

typedef struct {
  int pfd, rfd, wfd;
  int64_t n;
} loop_ctx;

static void *loop_body(void *arg) {
  loop_ctx *c = arg;
  c->n = ec_poll_wait(c->pfd, 8, -1);
  return NULL;
}

static atomic_int probe_ran;
static void *probe_body(void *arg) {
  (void)arg;
  atomic_fetch_add(&probe_ran, 1);
  return NULL;
}

static void test_poll_wait_parks(void) {
  enum { L = 6 }; /* more than the 2 workers */
  loop_ctx lc[L];
  ei_thread th[L];
  int before = count_dir("/proc/self/task");
  for (int i = 0; i < L; i++) {
    int fds[2];
    CHECK(pipe(fds) == 0);
    lc[i].pfd = (int)ec_poll_new();
    lc[i].rfd = fds[0];
    lc[i].wfd = fds[1];
    lc[i].n = -1;
    EQI(ec_poll_ctl(lc[i].pfd, 0, fds[0], 1, 7), 0);
    ei_thread_start(&th[i], loop_body, &lc[i]);
  }
  struct timespec ts = {0, 100 * 1000 * 1000};
  nanosleep(&ts, NULL);
  ei_thread pr;
  atomic_store(&probe_ran, 0);
  ei_thread_start(&pr, probe_body, NULL);
  ei_thread_join(&pr);
  ei_thread_destroy(&pr);
  EQI(atomic_load(&probe_ran), 1);
  if (!getenv("EIDER_TASKS")) CHECK(count_dir("/proc/self/task") == before); /* no worker was added */
  for (int i = 0; i < L; i++) {
    CHECK(write(lc[i].wfd, "x", 1) == 1);
  }
  for (int i = 0; i < L; i++) {
    ei_thread_join(&th[i]);
    ei_thread_destroy(&th[i]);
    EQI(lc[i].n, 1);
    close(lc[i].pfd);
    close(lc[i].rfd);
    close(lc[i].wfd);
  }
}

// ---- parkers across fork: a parker is usable in the child; a waiter of the parent is not there

static void *fork_waiter(void *arg) {
  *(int64_t *)arg = ec_parker_park(*(int64_t *)arg, -1);
  return NULL;
}

static void *child_task(void *arg) {
  return (void *)(intptr_t)ec_parker_park(*(int64_t *)arg, 5000);
}

static void test_parker_fork(void) {
  int64_t q = ec_parker_new(); /* a task of the parent waits on it */
  int64_t slot = q;
  ei_thread w;
  ei_thread_start(&w, fork_waiter, &slot);
  struct timespec ts = {0, 50 * 1000 * 1000};
  nanosleep(&ts, NULL);
  int64_t p = ec_parker_new();
  ec_parker_unpark(p); /* a permit crosses the fork */
  fflush(stdout);
  fflush(stderr);
  pid_t pid = fork();
  if (pid == 0) {
    int bad = 0;
    if (ec_parker_park(p, 0) != 1) bad |= 1;
    ec_parker_unpark(q); /* the parent's waiter is gone: this only leaves a permit */
    if (ec_parker_park(q, 0) != 1) bad |= 2;
    if (ec_parker_park(q, 10) != 0) bad |= 4;
    int64_t r = ec_parker_new();
    ei_thread t;
    ei_thread_start(&t, child_task, &r); /* the scheduler starts afresh */
    ts.tv_nsec = 30 * 1000 * 1000;
    nanosleep(&ts, NULL);
    ec_parker_unpark(r);
    ei_thread_join(&t);
    ei_thread_destroy(&t);
    _exit(bad);
  }
  int st = 0;
  waitpid(pid, &st, 0);
  CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0);
  ec_parker_unpark(q); /* the parent's own waiter wakes */
  ei_thread_join(&w);
  ei_thread_destroy(&w);
  EQI(slot, 1);
  ec_parker_close(p);
  ec_parker_close(q);
}


// ---- an idle program is idle: tasks blocked on descriptors and long timers use no CPU

static void *idle_fd_waiter(void *arg) {
  int *fds = arg;
  ec_fd_wait(fds[0], 1, -1);
  return NULL;
}

static void *idle_sleeper(void *arg) {
  (void)arg;
  ec_sleep_ns(3600LL * 1000000000LL);
  return NULL;
}

static double cpu_s(void) {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return (double)ru.ru_utime.tv_sec + (double)ru.ru_stime.tv_sec + (double)(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6;
}

static void test_idle_cpu(void) {
  enum { W = 200, Z = 200 };
  static int pipes[W][2];
  static ei_thread wt[W], zt[Z];
  for (int i = 0; i < W; i++) {
    CHECK(pipe(pipes[i]) == 0);
    ei_thread_start(&wt[i], idle_fd_waiter, pipes[i]);
  }
  for (int i = 0; i < Z; i++) ei_thread_start(&zt[i], idle_sleeper, NULL);
  struct timespec ts = {0, 200 * 1000 * 1000};
  nanosleep(&ts, NULL); /* everything parks, the pool settles */
  double c0 = cpu_s();
  ts.tv_nsec = 0;
  ts.tv_sec = 1;
  nanosleep(&ts, NULL);
  double used = cpu_s() - c0;
  CHECK(used < 0.15); /* a second of waiting: a busy loop would be near 1.0 */
  for (int i = 0; i < W; i++) {
    CHECK(write(pipes[i][1], "x", 1) == 1);
    ei_thread_join(&wt[i]);
    ei_thread_destroy(&wt[i]);
    close(pipes[i][0]);
    close(pipes[i][1]);
  }
  /* the sleepers stay (an hour): their tasks are abandoned with the process */
}

// ---- the listing of live tasks: what each waits for

int64_t ec_task_dump(void);

static int dump_pipe[2];
static int64_t dump_parker;
static ei_chan dump_chan;
static ei_thread dump_sleeper_th;

static void *dump_fd_task(void *arg) {
  (void)arg;
  ec_fd_wait(dump_pipe[0], 1, -1);
  return NULL;
}
static void *dump_sleep_task(void *arg) {
  (void)arg;
  ec_sleep_ns(60LL * 1000000000LL);
  return NULL;
}
static void *dump_park_task(void *arg) {
  (void)arg;
  ec_parker_park(dump_parker, -1);
  return NULL;
}
static void *dump_chan_task(void *arg) {
  (void)arg;
  int64_t v;
  ei_chan_recv(&dump_chan, &v);
  return NULL;
}
static void *dump_join_task(void *arg) {
  (void)arg;
  ei_thread_join(&dump_sleeper_th);
  return NULL;
}

/* Runs f with stderr into a file; the text it printed (a static buffer). */
static char cap[16384];
static const char *capture(void (*f)(void)) {
  char path[] = "/tmp/task_dump_XXXXXX";
  int tmp = mkstemp(path);
  fflush(stderr);
  int saved = dup(2);
  dup2(tmp, 2);
  f();
  fflush(stderr);
  dup2(saved, 2);
  close(saved);
  lseek(tmp, 0, SEEK_SET);
  ssize_t n = read(tmp, cap, sizeof cap - 1);
  cap[n < 0 ? 0 : n] = 0;
  close(tmp);
  unlink(path);
  return cap;
}

static void do_dump(void) { ec_task_dump(); }

static void test_task_dump(void) {
  CHECK(pipe(dump_pipe) == 0);
  dump_parker = ec_parker_new();
  ei_chan_init(&dump_chan, sizeof(int64_t));
  ei_thread a, c, d, e;
  ei_thread_start(&a, dump_fd_task, NULL);
  ei_thread_start(&dump_sleeper_th, dump_sleep_task, NULL);
  ei_thread_start(&c, dump_park_task, NULL);
  ei_thread_start(&d, dump_chan_task, NULL);
  ei_thread_start(&e, dump_join_task, NULL);

  struct timespec ts = {0, 150 * 1000 * 1000};
  nanosleep(&ts, NULL);
  const char *out = capture(do_dump);
  CHECK(strstr(out, "== tasks:") != NULL);
  CHECK(strstr(out, "parked: fd ") != NULL && strstr(out, " read") != NULL);
  CHECK(strstr(out, "parked: sleep") != NULL);
  CHECK(strstr(out, "parked: unpark") != NULL);
  CHECK(strstr(out, "parked: channel ") != NULL);
  CHECK(strstr(out, "parked: join #") != NULL);
  CHECK(strstr(out, " run 0x") != NULL);
  /* the same listing on SIGQUIT (EIDER_TASK_DUMP=1 was set before the scheduler started) */
  char path[] = "/tmp/task_quit_XXXXXX";
  int tmp = mkstemp(path);
  fflush(stderr);
  int saved = dup(2);
  dup2(tmp, 2);
  kill(getpid(), SIGQUIT);
  int seen = 0;
  for (int i = 0; i < 200 && !seen; i++) {
    struct timespec w = {0, 10 * 1000 * 1000};
    nanosleep(&w, NULL);
    struct stat st;
    if (fstat(tmp, &st) == 0 && st.st_size > 20) seen = 1;
  }
  fflush(stderr);
  dup2(saved, 2);
  close(saved);
  lseek(tmp, 0, SEEK_SET);
  ssize_t n = read(tmp, cap, sizeof cap - 1);
  cap[n < 0 ? 0 : n] = 0;
  close(tmp);
  unlink(path);
  CHECK(seen && strstr(cap, "== tasks:") != NULL);
  /* release them: the sleeper is left (a minute), so the join task too */
  CHECK(write(dump_pipe[1], "x", 1) == 1);
  ec_parker_unpark(dump_parker);
  int64_t one = 1;
  ei_chan_send(&dump_chan, &one);
  ei_thread_join(&a);
  ei_thread_join(&c);
  ei_thread_join(&d);
  ei_thread_destroy(&a);
  ei_thread_destroy(&c);
  ei_thread_destroy(&d);
  close(dump_pipe[0]);
  close(dump_pipe[1]);
  ec_parker_close(dump_parker);
}

/* TASK_TEST_V=1 names each test as it starts; TASK_TEST_ONLY=parker runs those whose name has it */
#define RUN(f)                                                                  \
  do {                                                                          \
    const char *only_ = getenv("TASK_TEST_ONLY");                              \
    if (only_ && !strstr(#f, only_)) break;                                     \
    if (getenv("TASK_TEST_V")) fprintf(stderr, "%s\n", #f);                    \
    f();                                                                        \
  } while (0)

int main(int argc, char **argv) {
  self_path = argv[0];
  if (argc > 1 && strcmp(argv[1], "overflow") == 0) child_overflow();
  if (argc > 1 && strcmp(argv[1], "threads") == 0) {
    /* the same parker tests with OS threads (EIDER_TASKS=threads) */
    setenv("EIDER_TASKS", "threads", 1);
    ei_set_file("task_test");
    RUN(test_parker_basic);
    RUN(test_parker_stale_and_many);
    RUN(test_parker_many_tasks);
    RUN(test_parker_timer_race);
    RUN(test_fd_wait_ev_race);
    RUN(test_parker_ping_pong);
    RUN(test_parker_fork);
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
  }
  setenv("EIDER_WORKERS", "2", 1);
  setenv("EIDER_TASK_DUMP", "1", 1);
  setenv("EIDER_WORKERS_MAX", "64", 1);
  ei_set_file("task_test");
  RUN(test_many_blocked);
  RUN(test_tree);
  RUN(test_sleep_overlaps);
  RUN(test_fd_wait);
  RUN(test_fd_wait2);
  RUN(test_trap_across_park);
  RUN(test_starvation_guard);
  RUN(test_idle_cpu);
  RUN(test_task_dump);
  RUN(test_parker_basic);
  RUN(test_parker_stale_and_many);
  RUN(test_parker_many_tasks);
  RUN(test_parker_timer_race);
  RUN(test_fd_wait_ev_race);
  RUN(test_parker_ping_pong);
  RUN(test_poll_wait_parks);
  RUN(test_parker_fork);
  RUN(test_overflow);
  printf("%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
