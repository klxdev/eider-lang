// Tests for ec_run and ec_read_fd in core/eider_core.c (contract: core/ABI.md).
// Run by tests/core/run.sh. The children are this binary re-executed with `child <mode>`, so
// each test controls exactly what the child does.
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* the core functions under test (raw ec_* names, as Eider binds them) */
void ec_in_clear(void);
void ec_in_push(int32_t b);
int64_t ec_out_len(void);
int32_t ec_out_byte(int64_t i);
int64_t ec_run(int32_t out_mode, int32_t err_mode, int64_t timeout_ms);
int64_t ec_read_fd(int32_t fd, int64_t max);
void ec_in_set(const uint8_t *p, uint64_t n);
void ec_in_append(const uint8_t *p, uint64_t n);
const char *ec_in_cstr(void);
void ec_errstr(int64_t e);
int64_t ec_out_copy(uint8_t *dst, uint64_t n, int64_t from);

static int failures, checks;
static char self[4096];

static void check(int ok, const char *what, int line) {
  checks++;
  if (!ok) {
    failures++;
    fprintf(stderr, "FAIL core_test.c:%d: %s\n", line, what);
  }
}

#define CHECK(c) check((c) ? 1 : 0, #c, __LINE__)
#define EQI(e, want) check((int64_t)(e) == (int64_t)(want), #e " == " #want, __LINE__)

// ---- the child side

static void write_all(int fd, const char *p, size_t n) {
  while (n > 0) {
    ssize_t w = write(fd, p, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      _exit(90);
    }
    p += w;
    n -= (size_t)w;
  }
}

static void fill(int fd, char c, size_t n) {
  char b[4096];
  memset(b, c, sizeof b);
  while (n > 0) {
    size_t k = n < sizeof b ? n : sizeof b;
    write_all(fd, b, k);
    n -= k;
  }
}

static int open_fd(int fd) { return fcntl(fd, F_GETFD) != -1; }

/* The open descriptors above 2, space-separated (only non-close-on-exec ones if `inherit`). */
static void list_fds(char *s, size_t cap, int inherit) {
  s[0] = 0;
  for (int fd = 3; fd < 1024; fd++) {
    int fl = fcntl(fd, F_GETFD);
    if (fl == -1 || (inherit && (fl & FD_CLOEXEC))) continue;
    size_t l = strlen(s);
    snprintf(s + l, cap - l, "%d ", fd);
  }
}

static int child(const char *mode, const char *arg) {
  size_t n = arg ? (size_t)strtoul(arg, NULL, 10) : 0;
  if (!strcmp(mode, "both")) { /* fill stderr first: a reader blocked on stdout deadlocks */
    fill(2, 'e', n);
    fill(1, 'o', n);
    fill(2, 'E', n);
    return 0;
  }
  if (!strcmp(mode, "exit")) return (int)n;
  if (!strcmp(mode, "signal")) {
    signal(SIGTERM, SIG_DFL);
    raise(SIGTERM);
    return 1;
  }
  if (!strcmp(mode, "fds")) {
    char s[8192];
    list_fds(s, sizeof s, 0);
    write_all(1, s, strlen(s));
    return 0;
  }
  if (!strcmp(mode, "stdio")) { /* are 0..2 open and without close-on-exec? */
    for (int fd = 0; fd <= 2; fd++)
      if (!open_fd(fd) || (fcntl(fd, F_GETFD) & FD_CLOEXEC)) return 1;
    write_all(1, "ok", 2);
    return 0;
  }
  if (!strcmp(mode, "sleep")) {
    write_all(1, "started", 7);
    for (;;) pause();
  }
  if (!strcmp(mode, "ignore-term")) {
    signal(SIGTERM, SIG_IGN);
    write_all(1, "x", 1);
    for (;;) pause();
  }
  if (!strcmp(mode, "grandchild")) { /* a grandchild holds the pipes; the child exits */
    if (fork() == 0)
      for (;;) pause();
    return 0;
  }
  if (!strcmp(mode, "close")) { /* close the pipes but keep running */
    close(1);
    close(2);
    for (;;) pause();
  }
  return 99;
}

// ---- the parent side

static void push_str(const char *s) {
  for (; *s; s++) ec_in_push((unsigned char)*s);
}

/* in = self child mode [arg] */
static void set_child(const char *mode, const char *arg) {
  ec_in_clear();
  push_str(self);
  ec_in_push(0);
  push_str("child");
  ec_in_push(0);
  push_str(mode);
  if (arg) {
    ec_in_push(0);
    push_str(arg);
  }
}

static void set_argv1(const char *prog) {
  ec_in_clear();
  push_str(prog);
}

typedef struct {
  char *out, *err;
  size_t out_len, err_len;
} Captured;

/* Decodes out: 8-byte LE stdout length, stdout, stderr. */
static int take(Captured *c) {
  int64_t n = ec_out_len();
  if (n < 8) return 0;
  uint64_t ol = 0;
  for (int i = 7; i >= 0; i--) ol = ol * 256 + (uint64_t)ec_out_byte(i);
  if (ol > (uint64_t)(n - 8)) return 0;
  c->out_len = (size_t)ol;
  c->err_len = (size_t)(n - 8) - c->out_len;
  c->out = malloc(c->out_len + 1);
  c->err = malloc(c->err_len + 1);
  if (!c->out || !c->err) exit(2);
  for (size_t i = 0; i < c->out_len; i++) c->out[i] = (char)ec_out_byte((int64_t)(8 + i));
  for (size_t i = 0; i < c->err_len; i++)
    c->err[i] = (char)ec_out_byte((int64_t)(8 + c->out_len + i));
  c->out[c->out_len] = 0;
  c->err[c->err_len] = 0;
  return 1;
}

static void release(Captured *c) {
  free(c->out);
  free(c->err);
}

static int all(const char *p, size_t n, char c) {
  for (size_t i = 0; i < n; i++)
    if (p[i] != c) return 0;
  return 1;
}

static int64_t now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000 + (int64_t)t.tv_nsec / 1000000;
}

/* Every child ec_run started has been reaped. */
static int no_zombies(void) { return waitpid(-1, NULL, WNOHANG) == -1 && errno == ECHILD; }

#define MB (1024 * 1024)

static void test_both_large(void) {
  Captured c;
  set_child("both", "1048576");
  EQI(ec_run(1, 1, 0), 0);
  CHECK(take(&c));
  EQI(c.out_len, MB);
  EQI(c.err_len, 2 * MB);
  CHECK(all(c.out, MB, 'o'));
  CHECK(all(c.err, MB, 'e') && all(c.err + MB, MB, 'E'));
  release(&c);
  CHECK(no_zombies());
}

static void test_modes(void) {
  Captured c;
  /* inherit stdout (sent to a temp file), capture stderr */
  fflush(stdout);
  FILE *f = tmpfile();
  if (!f) exit(2);
  int saved = dup(1);
  dup2(fileno(f), 1);
  set_child("both", "10");
  int64_t r = ec_run(0, 1, 0);
  fflush(stdout);
  dup2(saved, 1);
  close(saved);
  EQI(r, 0);
  CHECK(take(&c));
  EQI(c.out_len, 0);
  CHECK(c.err_len == 20 && all(c.err, 10, 'e') && all(c.err + 10, 10, 'E'));
  release(&c);
  char got[64] = {0};
  rewind(f);
  size_t k = fread(got, 1, sizeof got - 1, f);
  fclose(f);
  CHECK(k == 10 && all(got, 10, 'o'));
  /* capture stdout only; stderr inherited (nothing written) */
  set_child("exit", "0");
  EQI(ec_run(1, 0, 0), 0);
  CHECK(take(&c));
  CHECK(c.out_len == 0 && c.err_len == 0);
  release(&c);
  /* the child's 0..2 are open and survive exec */
  set_child("stdio", NULL);
  EQI(ec_run(1, 1, 0), 0);
  CHECK(take(&c));
  CHECK(!strcmp(c.out, "ok"));
  release(&c);
  /* bad arguments */
  set_child("exit", "0");
  EQI(ec_run(2, 0, 0), -EINVAL);
  EQI(ec_run(0, -1, 0), -EINVAL);
  ec_in_clear();
  EQI(ec_run(1, 1, 0), -EINVAL);
  CHECK(no_zombies());
}

static void test_exit_and_signal(void) {
  set_child("exit", "42");
  EQI(ec_run(1, 1, 0), 42);
  set_child("exit", "0");
  EQI(ec_run(1, 1, 5000), 0); /* a timeout that doesn't fire */
  set_child("signal", NULL);
  EQI(ec_run(1, 1, 0), 128 + SIGTERM);
  set_child("signal", NULL);
  EQI(ec_run(0, 0, 5000), 128 + SIGTERM);
  CHECK(no_zombies());
}

static void test_exec_failure(void) {
  set_argv1("/nonexistent/eider-no-such-program");
  EQI(ec_run(1, 1, 0), -ENOENT);
  set_argv1("eider-no-such-program-on-path");
  EQI(ec_run(0, 0, 1000), -ENOENT);
  set_argv1("/dev/null"); /* exists, not executable */
  EQI(ec_run(1, 1, 0), -EACCES);
  CHECK(no_zombies());
}

static void test_timeout(void) {
  Captured c;
  int64_t t0 = now_ms();
  set_child("sleep", NULL);
  EQI(ec_run(1, 1, 300), 256);
  int64_t dt = now_ms() - t0;
  CHECK(dt >= 300 && dt < 2000);
  CHECK(take(&c));
  CHECK(!strcmp(c.out, "started")); /* what was read before the kill is kept */
  release(&c);
  /* SIGTERM ignored: SIGKILL after the 200 ms grace */
  t0 = now_ms();
  set_child("ignore-term", NULL);
  EQI(ec_run(1, 1, 200), 256);
  dt = now_ms() - t0;
  CHECK(dt >= 400 && dt < 2000);
  /* the child exits but a grandchild holds the pipes: the whole group is killed */
  t0 = now_ms();
  set_child("grandchild", NULL);
  EQI(ec_run(1, 1, 300), 256);
  dt = now_ms() - t0;
  CHECK(dt >= 300 && dt < 2000);
  /* pipes closed, child still running; and with nothing captured */
  t0 = now_ms();
  set_child("close", NULL);
  EQI(ec_run(1, 1, 300), 256);
  set_child("sleep", NULL);
  fflush(stdout);
  int saved = dup(1), dn = open("/dev/null", O_WRONLY);
  dup2(dn, 1);
  int64_t r = ec_run(0, 0, 300);
  dup2(saved, 1);
  close(saved);
  close(dn);
  EQI(r, 256);
  dt = now_ms() - t0;
  CHECK(dt >= 600 && dt < 4000);
  CHECK(no_zombies());
}

/* The child sees exactly the descriptors we have without close-on-exec. */
static void test_no_fd_leak(void) {
  char want[8192];
  Captured c;
  int extra = open("/dev/null", O_RDONLY); /* not close-on-exec: legitimately inherited */
  list_fds(want, sizeof want, 1);
  for (int mode = 0; mode < 3; mode++) {
    set_child("fds", NULL);
    EQI(ec_run(1, mode == 0 ? 0 : 1, mode == 2 ? 5000 : 0), 0);
    CHECK(take(&c));
    check(!strcmp(c.out, want), "child fds match the parent's inheritable fds", __LINE__);
    if (strcmp(c.out, want)) fprintf(stderr, "  want: %s\n  got:  %s\n", want, c.out);
    release(&c);
  }
  close(extra);
  CHECK(no_zombies());
}

/* Concurrent runs from several threads: no thread's pipes reach another thread's child (the
   in/out buffers are thread-local). Only where the core has atomic close-on-exec pipes
   (pipe2, Linux); elsewhere ABI.md documents the pipe/fcntl window, which this would hit. */
#if defined(__linux__)
static char thread_want[8192];
static void *runner(void *p) {
  intptr_t bad = 0;
  (void)p;
  for (int i = 0; i < 25; i++) {
    Captured c;
    set_child("fds", NULL);
    if (ec_run(1, 1, i % 2 ? 5000 : 0) != 0 || !take(&c)) { bad++; continue; }
    if (strcmp(c.out, thread_want)) bad++;
    release(&c);
  }
  return (void *)bad;
}

static void test_threads(void) {
  list_fds(thread_want, sizeof thread_want, 1);
  pthread_t t[4];
  for (int i = 0; i < 4; i++) pthread_create(&t[i], NULL, runner, NULL);
  intptr_t bad = 0;
  for (int i = 0; i < 4; i++) {
    void *r;
    pthread_join(t[i], &r);
    bad += (intptr_t)r;
  }
  EQI(bad, 0);
  CHECK(no_zombies());
}

#endif

static void on_alarm(int s) { (void)s; }

/* A 1 ms interval timer interrupts poll, read and waitpid constantly (no SA_RESTART). */
static void test_eintr(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_alarm;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGALRM, &sa, NULL);
  struct itimerval it = {{0, 1000}, {0, 1000}}, off = {{0, 0}, {0, 0}};
  setitimer(ITIMER_REAL, &it, NULL);
  Captured c;
  set_child("both", "1048576");
  EQI(ec_run(1, 1, 0), 0);
  CHECK(take(&c));
  CHECK(c.out_len == MB && c.err_len == 2 * MB);
  release(&c);
  set_child("exit", "5");
  EQI(ec_run(1, 1, 0), 5);
  set_child("sleep", NULL);
  EQI(ec_run(1, 1, 100), 256);
  set_argv1("/nonexistent/x");
  EQI(ec_run(1, 1, 0), -ENOENT);
  setitimer(ITIMER_REAL, &off, NULL);
  signal(SIGALRM, SIG_DFL);
  CHECK(no_zombies());
}

// ---- ec_read_fd

/* out holds exactly `want` */
static int out_is(const char *want) {
  size_t n = strlen(want);
  if (ec_out_len() != (int64_t)n) return 0;
  for (size_t i = 0; i < n; i++)
    if (ec_out_byte((int64_t)i) != (unsigned char)want[i]) return 0;
  return 1;
}

static int late_fd;
static void *late_writer(void *p) {
  (void)p;
  struct timespec t = {0, 50 * 1000000};
  nanosleep(&t, NULL);
  write_all(late_fd, "late", 4);
  return NULL;
}

static void test_read_fd(void) {
  int p[2];
  CHECK(pipe(p) == 0);
  write_all(p[1], "abcdef", 6);
  EQI(ec_read_fd(p[0], 4), 4);
  CHECK(out_is("abcd"));
  EQI(ec_read_fd(p[0], (int64_t)1 << 40), 2); /* a huge max is capped, not allocated */
  CHECK(out_is("ef"));
  /* a NUL byte is data */
  write_all(p[1], "x\0y", 3);
  EQI(ec_read_fd(p[0], 16), 3);
  CHECK(ec_out_byte(1) == 0 && ec_out_byte(2) == 'y');
  close(p[1]);
  EQI(ec_read_fd(p[0], 16), 0); /* end of file */
  EQI(ec_out_len(), 0);
  close(p[0]);
  EQI(ec_read_fd(p[0], 16), -EBADF);
  EQI(ec_out_len(), 0);
  EQI(ec_read_fd(0, 0), -EINVAL);
  EQI(ec_read_fd(-1, 16), -EINVAL);
  /* a blocking read interrupted by signals (no SA_RESTART) is retried */
  CHECK(pipe(p) == 0);
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_alarm;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGALRM, &sa, NULL);
  struct itimerval it = {{0, 1000}, {0, 1000}}, off = {{0, 0}, {0, 0}};
  late_fd = p[1];
  pthread_t t;
  pthread_create(&t, NULL, late_writer, NULL);
  setitimer(ITIMER_REAL, &it, NULL);
  EQI(ec_read_fd(p[0], 16), 4);
  setitimer(ITIMER_REAL, &off, NULL);
  signal(SIGALRM, SIG_DFL);
  pthread_join(t, NULL);
  CHECK(out_is("late"));
  close(p[0]);
  close(p[1]);
}

// ---- bulk transfer (core/ABI.md "Buffers")

static void test_bulk(void) {
  uint8_t a[300];
  for (int i = 0; i < 300; i++) a[i] = (uint8_t)(i % 250 + 1);
  ec_in_set(a, 300);
  CHECK(strlen(ec_in_cstr()) == 300 && memcmp(ec_in_cstr(), a, 300) == 0);
  ec_in_append(a, 100);
  CHECK(strlen(ec_in_cstr()) == 400 && memcmp(ec_in_cstr() + 300, a, 100) == 0);
  ec_in_set(NULL, 0);
  CHECK(strlen(ec_in_cstr()) == 0);
  ec_in_append(NULL, 0);
  CHECK(strlen(ec_in_cstr()) == 0);
  /* a push after a bulk append continues it */
  ec_in_set(a, 2);
  ec_in_push(7);
  CHECK(strlen(ec_in_cstr()) == 3 && ec_in_cstr()[2] == 7);
  /* a large one grows the buffer */
  static uint8_t big[1 << 20];
  memset(big, 0x5a, sizeof big);
  ec_in_set(big, sizeof big);
  CHECK(strlen(ec_in_cstr()) == sizeof big);
  /* out -> bytes: the text of an errno, in pieces, clipped */
  ec_errstr(2);
  int64_t n = ec_out_len();
  CHECK(n > 4);
  uint8_t d[64];
  memset(d, 0xee, sizeof d);
  EQI(ec_out_copy(d, 3, 0), 3);
  CHECK(d[0] == (uint8_t)ec_out_byte(0) && d[2] == (uint8_t)ec_out_byte(2) && d[3] == 0xee);
  EQI(ec_out_copy(d, sizeof d, n - 2), 2);
  CHECK(d[0] == (uint8_t)ec_out_byte(n - 2) && d[1] == (uint8_t)ec_out_byte(n - 1));
  EQI(ec_out_copy(d, 8, n), 0);
  EQI(ec_out_copy(d, 8, -1), 0);
  EQI(ec_out_copy(NULL, 0, 0), 0);
}

int main(int argc, char **argv) {
  if (argc >= 3 && !strcmp(argv[1], "child")) return child(argv[2], argc > 3 ? argv[3] : NULL);
  snprintf(self, sizeof self, "%s", argv[0]);
  if (!strchr(self, '/')) {
    fprintf(stderr, "core_test: run with a path (it re-executes itself)\n");
    return 2;
  }
  test_both_large();
  test_modes();
  test_exit_and_signal();
  test_exec_failure();
  test_timeout();
  test_no_fd_leak();
#if defined(__linux__)
  test_threads();
#endif
  test_eintr();
  test_read_fd();
  test_bulk();
  printf("%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
