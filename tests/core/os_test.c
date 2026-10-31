// Tests for the OS primitives in core/eider_core.c (contract: core/ABI.md): descriptors,
// sockets, name resolution, readiness, time, signals, randomness and processes. Run by
// tests/core/run.sh, like core_test.c. Children are this binary re-executed with
// `child <mode>`.
#if defined(__linux__)
#define _GNU_SOURCE 1
#elif defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#elif !defined(__FreeBSD__) && !defined(__OpenBSD__) && !defined(__NetBSD__) && !defined(__DragonFly__)
#define _POSIX_C_SOURCE 200809L
#endif

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

/* the core functions under test (raw ec_* names, as Eider binds them) */
void ec_in_clear(void);
void ec_in_push(int32_t b);
int64_t ec_out_len(void);
int32_t ec_out_byte(int64_t i);
void ec_errstr(int64_t e);
int64_t ec_read_fd(int32_t fd, int64_t max);
int64_t ec_fd_open(int32_t flags, int32_t mode);
int64_t ec_fd_close(int32_t fd);
int64_t ec_fd_write(int32_t fd);
int64_t ec_fd_pread(int32_t fd, int64_t max, int64_t off);
int64_t ec_fd_pwrite(int32_t fd, int64_t off);
int64_t ec_fd_seek(int32_t fd, int64_t off, int32_t whence);
int64_t ec_fd_sync(int32_t fd, int32_t data_only);
int64_t ec_fd_truncate(int32_t fd, int64_t len);
int64_t ec_fd_stat(int32_t fd);
int64_t ec_stat(int32_t follow);
int64_t ec_fd_chmod(int32_t fd, int32_t mode);
int64_t ec_fd_lock(int32_t fd, int32_t op);
int64_t ec_fd_nonblock(int32_t fd, int32_t on);
int64_t ec_fd_dup(int32_t fd);
int64_t ec_pipe(void);
int64_t ec_sock_open(int32_t family, int32_t type, int32_t nonblock);
int64_t ec_sock_pair(int32_t type);
int64_t ec_sock_bind(int32_t fd);
int64_t ec_sock_listen(int32_t fd, int32_t backlog);
int64_t ec_sock_accept(int32_t fd, int32_t nonblock);
int64_t ec_sock_connect(int32_t fd);
int64_t ec_sock_error(int32_t fd);
int64_t ec_sock_shutdown(int32_t fd, int32_t how);
int64_t ec_sock_send(int32_t fd);
int64_t ec_sock_recv(int32_t fd, int64_t max, int32_t peek);
int64_t ec_sock_sendto(int32_t fd, int32_t addr_len);
int64_t ec_sock_recvfrom(int32_t fd, int64_t max);
int64_t ec_sock_name(int32_t fd, int32_t peer);
int64_t ec_sock_setopt(int32_t fd, int32_t opt, int64_t value);
int64_t ec_sock_getopt(int32_t fd, int32_t opt);
int64_t ec_dns_lookup(int32_t family, int32_t socktype, int32_t flags);
int64_t ec_dns_reverse(int32_t flags);
int64_t ec_poll_new(void);
int64_t ec_poll_ctl(int32_t pfd, int32_t op, int32_t fd, int32_t interest, int64_t token);
int64_t ec_poll_wait(int32_t pfd, int32_t max, int64_t timeout_ms);
int64_t ec_waker_new(void);
int64_t ec_waker_wake(int32_t wfd);
int64_t ec_time_mono_ns(void);
int64_t ec_time_wall_ns(void);
int64_t ec_sleep_ns(int64_t ns);
int64_t ec_signal_fd(void);
int64_t ec_signal_set(int32_t sig, int32_t how);
int64_t ec_signal_mask(int32_t sig, int32_t block);
int64_t ec_random(int64_t n, int32_t nonblock);
int64_t ec_spawn(int32_t in_mode, int32_t out_mode, int32_t err_mode);
int64_t ec_wait(int32_t pid, int32_t nohang);
int64_t ec_kill(int32_t pid, int32_t sig);
int64_t ec_getpid(void);

static int failures, checks;
static char self[4096], tmpdir[4096];

static void check(int ok, const char *what, int line) {
  checks++;
  if (!ok) {
    failures++;
    fprintf(stderr, "FAIL os_test.c:%d: %s\n", line, what);
  }
}

#define CHECK(c) check((c) ? 1 : 0, #c, __LINE__)
#define EQI(e, want) check((int64_t)(e) == (int64_t)(want), #e " == " #want, __LINE__)

// ---- buffer helpers

static void push_bytes(const void *p, size_t n) {
  const unsigned char *b = p;
  for (size_t i = 0; i < n; i++) ec_in_push(b[i]);
}

static void push_str(const char *s) { push_bytes(s, strlen(s)); }
static void set_str(const char *s) { ec_in_clear(); push_str(s); }

/* out copied into buf (NUL-terminated); its length */
static size_t take(unsigned char *buf, size_t cap) {
  size_t n = (size_t)ec_out_len();
  if (n >= cap) n = cap - 1;
  for (size_t i = 0; i < n; i++) buf[i] = (unsigned char)ec_out_byte((int64_t)i);
  buf[n] = 0;
  return n;
}

static int out_is(const char *want) {
  size_t n = strlen(want);
  if (ec_out_len() != (int64_t)n) return 0;
  for (size_t i = 0; i < n; i++)
    if (ec_out_byte((int64_t)i) != (unsigned char)want[i]) return 0;
  return 1;
}

static uint64_t out_u64(int64_t at) {
  uint64_t v = 0;
  for (int i = 7; i >= 0; i--) v = v * 256 + (uint64_t)ec_out_byte(at + i);
  return v;
}

static int32_t out_i32(int64_t at) {
  uint32_t v = 0;
  for (int i = 3; i >= 0; i--) v = v * 256 + (uint32_t)ec_out_byte(at + i);
  return (int32_t)v;
}

/* an Eider address in buf: family, port (big-endian), address bytes */
static size_t addr4(unsigned char *a, int port, unsigned b0, unsigned b1, unsigned b2, unsigned b3) {
  a[0] = 4; a[1] = (unsigned char)(port >> 8); a[2] = (unsigned char)port;
  a[3] = (unsigned char)b0; a[4] = (unsigned char)b1; a[5] = (unsigned char)b2; a[6] = (unsigned char)b3;
  return 7;
}

static size_t addr6_loopback(unsigned char *a, int port) {
  memset(a, 0, 23);
  a[0] = 6; a[1] = (unsigned char)(port >> 8); a[2] = (unsigned char)port;
  a[18] = 1;
  return 23;
}

static size_t addr_unix(unsigned char *a, const char *path) {
  a[0] = 1; a[1] = 0; a[2] = 0;
  memcpy(a + 3, path, strlen(path));
  return 3 + strlen(path);
}

static void set_addr(const unsigned char *a, size_t n) {
  ec_in_clear();
  push_bytes(a, n);
}

static int out_port(void) { return ec_out_byte(1) * 256 + ec_out_byte(2); }

static void set_data(const char *s) { set_str(s); }

/* in = argv: self child mode */
static void set_child(const char *mode) {
  ec_in_clear();
  push_str(self);
  ec_in_push(0);
  push_str("child");
  ec_in_push(0);
  push_str(mode);
}

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

// ---- children

static int child(const char *mode) {
  if (!strcmp(mode, "echo")) { /* stdin to stdout, then "done" to stderr */
    char b[4096];
    ssize_t r;
    while ((r = read(0, b, sizeof b)) > 0) write_all(1, b, (size_t)r);
    write_all(2, "done", 4);
    return 0;
  }
  if (!strcmp(mode, "sigstate")) { /* SIGPIPE at its default and nothing blocked? */
    struct sigaction sa;
    sigset_t m;
    sigaction(SIGPIPE, NULL, &sa);
    sigprocmask(SIG_SETMASK, NULL, &m);
    int ok = sa.sa_handler == SIG_DFL && !sigismember(&m, SIGTERM) && !sigismember(&m, SIGUSR1);
    struct sigaction t;
    sigaction(SIGTERM, NULL, &t);
    ok = ok && t.sa_handler == SIG_DFL;
    write_all(1, ok ? "clean" : "dirty", 5);
    return 0;
  }
  if (!strcmp(mode, "sleep")) {
    for (;;) pause();
  }
  if (!strcmp(mode, "exit3")) return 3;
  return 99;
}

// ---- file descriptors

static void path_in(char *buf, size_t cap, const char *name) { snprintf(buf, cap, "%s/%s", tmpdir, name); }

static void test_fd(void) {
  char path[4200];
  unsigned char b[256];
  path_in(path, sizeof path, "fd.txt");
  set_str(path);
  int64_t fd = ec_fd_open(2 | 4 | 16, 0640); /* read-write, create, truncate */
  CHECK(fd >= 3);
  set_data("hello world");
  EQI(ec_fd_write((int32_t)fd), 11);
  EQI(ec_fd_seek((int32_t)fd, 0, 1), 11);
  EQI(ec_fd_seek((int32_t)fd, 0, 0), 0);
  EQI(ec_read_fd((int32_t)fd, 5), 5);
  CHECK(out_is("hello"));
  /* positioned I/O does not move the offset */
  EQI(ec_fd_pread((int32_t)fd, 100, 6), 5);
  CHECK(out_is("world"));
  set_data("W");
  EQI(ec_fd_pwrite((int32_t)fd, 6), 1);
  EQI(ec_fd_seek((int32_t)fd, 0, 1), 5);
  EQI(ec_fd_pread((int32_t)fd, 100, 0), 11);
  CHECK(out_is("hello World"));
  EQI(ec_fd_pread((int32_t)fd, 100, 50), 0); /* past the end */
  EQI(ec_fd_pread((int32_t)fd, 0, 0), -EINVAL);
  EQI(ec_fd_pread((int32_t)fd, 10, -1), -EINVAL);
  EQI(ec_fd_seek((int32_t)fd, -2, 2), 9);
  EQI(ec_fd_seek((int32_t)fd, 0, 7), -EINVAL);
  /* stat: size, kind, mode, mtime */
  EQI(ec_fd_stat((int32_t)fd), 0);
  EQI(ec_out_len(), 32);
  EQI(out_u64(0), 11);
  EQI(out_u64(8), 1);
  EQI(out_u64(16), 0640); /* the umask (022) leaves 0640 alone */
  int64_t now = ec_time_wall_ns(), mt = (int64_t)out_u64(24);
  CHECK(mt > now - (int64_t)60 * 1000000000 && mt <= now + 1000000000);
  EQI(ec_fd_chmod((int32_t)fd, 0600), 0);
  EQI(ec_fd_stat((int32_t)fd), 0);
  EQI(out_u64(16), 0600);
  EQI(ec_fd_truncate((int32_t)fd, 5), 0);
  EQI(ec_fd_stat((int32_t)fd), 0);
  EQI(out_u64(0), 5);
  EQI(ec_fd_truncate((int32_t)fd, -1), -EINVAL);
  EQI(ec_fd_sync((int32_t)fd, 0), 0);
  EQI(ec_fd_sync((int32_t)fd, 1), 0);
  /* path stat; a directory; a symlink without following */
  set_str(path);
  EQI(ec_stat(1), 0);
  EQI(out_u64(0), 5);
  set_str(tmpdir);
  EQI(ec_stat(1), 0);
  EQI(out_u64(8), 2);
  char link[4200];
  path_in(link, sizeof link, "fd.link");
  CHECK(symlink(path, link) == 0);
  set_str(link);
  EQI(ec_stat(0), 0);
  EQI(out_u64(8), 4);
  EQI(ec_stat(1), 0);
  EQI(out_u64(8), 1);
  unlink(link);
  set_str("/nonexistent/eider");
  EQI(ec_stat(1), -ENOENT);
  /* flock: per open file, so a second open of the same file conflicts */
  set_str(path);
  int64_t fd2 = ec_fd_open(0, 0);
  CHECK(fd2 >= 3);
  EQI(ec_fd_lock((int32_t)fd, 2), 0);
  int64_t busy = ec_fd_lock((int32_t)fd2, 2 | 4);
  CHECK(busy == -EWOULDBLOCK || busy == -EAGAIN);
  EQI(ec_fd_lock((int32_t)fd2, 1 | 4), busy);
  EQI(ec_fd_lock((int32_t)fd, 0), 0);
  EQI(ec_fd_lock((int32_t)fd2, 1 | 4), 0);
  EQI(ec_fd_lock((int32_t)fd, 1 | 4), 0); /* shared locks coexist */
  EQI(ec_fd_lock((int32_t)fd, 3), -EINVAL);
  /* dup shares the offset and is close-on-exec */
  int64_t d = ec_fd_dup((int32_t)fd);
  CHECK(d >= 3 && d != fd);
  CHECK(fcntl((int)d, F_GETFD) & FD_CLOEXEC);
  CHECK(fcntl((int)fd, F_GETFD) & FD_CLOEXEC);
  EQI(ec_fd_seek((int32_t)d, 1, 0), 1);
  EQI(ec_fd_seek((int32_t)fd, 0, 1), 1);
  EQI(ec_fd_close((int32_t)d), 0);
  EQI(ec_fd_close((int32_t)fd2), 0);
  EQI(ec_fd_close((int32_t)fd), 0);
  EQI(ec_fd_close((int32_t)fd), -EBADF);
  /* open flags */
  set_str(path);
  EQI(ec_fd_open(1 | 4 | 8, 0600), -EEXIST);
  EQI(ec_fd_open(3, 0), -EINVAL);
  EQI(ec_fd_open(1 << 12, 0), -EINVAL);
  fd = ec_fd_open(1 | 32, 0); /* write-only, append */
  set_data("++");
  EQI(ec_fd_write((int32_t)fd), 2);
  ec_fd_close((int32_t)fd);
  set_str(path);
  fd = ec_fd_open(0, 0);
  EQI(ec_read_fd((int32_t)fd, 100), 7);
  CHECK(out_is("hello++"));
  ec_fd_close((int32_t)fd);
  set_str(path);
  EQI(ec_fd_open(128, 0), -ENOTDIR);
  set_str("/nonexistent/eider");
  EQI(ec_fd_open(0, 0), -ENOENT);
  unlink(path);
  /* pipes, and non-blocking reads */
  EQI(ec_pipe(), 0);
  EQI(ec_out_len(), 8);
  int r = out_i32(0), w = out_i32(4);
  CHECK(r >= 3 && w >= 3 && (fcntl(r, F_GETFD) & FD_CLOEXEC));
  EQI(ec_fd_nonblock(r, 1), 0);
  CHECK(fcntl(r, F_GETFL) & O_NONBLOCK);
  int64_t again = ec_read_fd(r, 10);
  CHECK(again == -EAGAIN || again == -EWOULDBLOCK);
  set_data("x");
  EQI(ec_fd_write(w), 1);
  EQI(ec_read_fd(r, 10), 1);
  EQI(ec_fd_nonblock(r, 0), 0);
  CHECK(!(fcntl(r, F_GETFL) & O_NONBLOCK));
  /* a write to a pipe with no reader is -EPIPE, not a fatal SIGPIPE */
  ec_fd_close(r);
  set_data("y");
  EQI(ec_fd_write(w), -EPIPE);
  ec_fd_close(w);
  (void)b;
}

// ---- sockets and readiness

typedef struct {
  uint64_t token;
  uint32_t flags;
} Event;

/* wait on poller p; events into ev; their count */
static int wait_events(int p, Event *ev, int max, int64_t timeout_ms) {
  int64_t n = ec_poll_wait(p, max, timeout_ms);
  if (n < 0) return -1;
  CHECK(ec_out_len() == n * 16);
  for (int i = 0; i < n; i++) {
    ev[i].token = out_u64(i * 16);
    ev[i].flags = (uint32_t)out_i32(i * 16 + 8);
  }
  return (int)n;
}

/* A TCP echo over loopback, everything non-blocking, driven by the poller. family 4 or 6. */
static void echo_round(int family) {
  unsigned char a[64];
  size_t an = family == 4 ? addr4(a, 0, 127, 0, 0, 1) : addr6_loopback(a, 0);
  int64_t ls = ec_sock_open(family, 1, 1);
  if (family == 6 && (ls == -EAFNOSUPPORT || ls == -EPROTONOSUPPORT)) {
    printf("skip tcp echo over IPv6: no IPv6 sockets\n");
    return;
  }
  CHECK(ls >= 3);
  CHECK(fcntl((int)ls, F_GETFL) & O_NONBLOCK);
  CHECK(fcntl((int)ls, F_GETFD) & FD_CLOEXEC);
  EQI(ec_sock_setopt((int32_t)ls, 1, 1), 0);
  CHECK(ec_sock_getopt((int32_t)ls, 1) != 0);
  if (family == 6) {
    EQI(ec_sock_setopt((int32_t)ls, 7, 1), 0);
    CHECK(ec_sock_getopt((int32_t)ls, 7) != 0);
  }
  set_addr(a, an);
  int64_t bound = ec_sock_bind((int32_t)ls);
  if (family == 6 && bound == -EADDRNOTAVAIL) {
    printf("skip tcp echo over IPv6: no ::1\n");
    ec_fd_close((int32_t)ls);
    return;
  }
  EQI(bound, 0);
  EQI(ec_sock_listen((int32_t)ls, 16), 0);
  EQI(ec_sock_name((int32_t)ls, 0), 0);
  EQI(ec_out_byte(0), family);
  EQI(ec_out_len(), (int64_t)an);
  int port = out_port();
  CHECK(port > 0);
  int64_t none = ec_sock_accept((int32_t)ls, 1);
  CHECK(none == -EAGAIN || none == -EWOULDBLOCK);

  int64_t p = ec_poll_new();
  CHECK(p >= 3);
  CHECK(fcntl((int)p, F_GETFD) & FD_CLOEXEC);
  int64_t cs = ec_sock_open(family, 1, 1);
  CHECK(cs >= 3);
  EQI(ec_sock_setopt((int32_t)cs, 3, 1), 0);
  CHECK(ec_sock_getopt((int32_t)cs, 3) != 0);
  EQI(ec_sock_setopt((int32_t)cs, 4, 1), 0);
  CHECK(ec_sock_getopt((int32_t)cs, 4) != 0);
  EQI(ec_sock_setopt((int32_t)cs, 5, 65536), 0);
  CHECK(ec_sock_getopt((int32_t)cs, 5) >= 65536);
  CHECK(ec_sock_getopt((int32_t)cs, 6) > 0);
  EQI(ec_sock_setopt((int32_t)cs, 9, 1500), 0);
  EQI(ec_sock_getopt((int32_t)cs, 9), 1500);
  EQI(ec_sock_setopt((int32_t)cs, 9, 0), 0);
  int64_t rp = ec_sock_setopt((int32_t)cs, 2, 1);
  CHECK(rp == 0 || rp == -ENOPROTOOPT);
  EQI(ec_sock_setopt((int32_t)cs, 99, 1), -EINVAL);
  a[1] = (unsigned char)(port >> 8);
  a[2] = (unsigned char)port;
  set_addr(a, an);
  int64_t c = ec_sock_connect((int32_t)cs);
  CHECK(c == 0 || c == -EINPROGRESS);
  EQI(ec_poll_ctl((int32_t)p, 0, (int32_t)ls, 1, 100), 0);
  EQI(ec_poll_ctl((int32_t)p, 0, (int32_t)cs, 2, 200), 0);
  EQI(ec_poll_ctl((int32_t)p, 0, (int32_t)cs, 2, 200), -EEXIST);
  int64_t conn = -1;
  int sent = 0, echoed = 0, got = 0, closed = 0, peer_closed_seen = 0;
  unsigned char buf[64];
  for (int round = 0; round < 50 && !closed; round++) {
    Event ev[8];
    int n = wait_events((int)p, ev, 8, 2000);
    CHECK(n > 0);
    if (n <= 0) break;
    for (int i = 0; i < n; i++) {
      if (ev[i].token == 100 && (ev[i].flags & 1) && conn < 0) {
        conn = ec_sock_accept((int32_t)ls, 1);
        CHECK(conn >= 3);
        EQI(ec_out_byte(0), family); /* the peer's address */
        CHECK(fcntl((int)conn, F_GETFL) & O_NONBLOCK);
        EQI(ec_poll_ctl((int32_t)p, 0, (int32_t)conn, 1, 300), 0);
      } else if (ev[i].token == 200 && (ev[i].flags & 2) && !sent) {
        EQI(ec_sock_error((int32_t)cs), 0); /* the connect succeeded */
        set_data("hello");
        EQI(ec_sock_send((int32_t)cs), 5);
        sent = 1;
        EQI(ec_poll_ctl((int32_t)p, 1, (int32_t)cs, 1, 201), 0); /* now wait to read */
      } else if (ev[i].token == 300 && (ev[i].flags & 1)) {
        int64_t k = ec_sock_recv((int32_t)conn, 64, 0);
        if (k > 0) {
          take(buf, sizeof buf);
          ec_in_clear();
          push_bytes(buf, (size_t)k);
          EQI(ec_sock_send((int32_t)conn), k);
          echoed = 1;
        } else if (k == 0) { /* the client shut down its side */
          if (ev[i].flags & 16) peer_closed_seen = 1;
          EQI(ec_poll_ctl((int32_t)p, 2, (int32_t)conn, 0, 0), 0);
          ec_fd_close((int32_t)conn);
          closed = 1;
        }
      } else if (ev[i].token == 201 && (ev[i].flags & 1) && !got) {
        EQI(ec_sock_recv((int32_t)cs, 64, 1), 5); /* peek leaves the data */
        EQI(ec_sock_recv((int32_t)cs, 64, 0), 5);
        CHECK(out_is("hello"));
        got = 1;
        EQI(ec_sock_name((int32_t)cs, 1), 0);
        EQI(out_port(), port);
        EQI(ec_sock_shutdown((int32_t)cs, 1), 0);
      }
    }
  }
  CHECK(sent && echoed && got && closed);
  CHECK(peer_closed_seen);
  /* the server closed: the client reads end of stream */
  Event ev[8];
  int n = wait_events((int)p, ev, 8, 2000);
  CHECK(n >= 1 && ev[0].token == 201);
  EQI(ec_sock_recv((int32_t)cs, 64, 0), 0);
  EQI(ec_sock_shutdown((int32_t)cs, 5), -EINVAL);
  EQI(ec_poll_ctl((int32_t)p, 2, (int32_t)cs, 0, 0), 0);
  EQI(ec_poll_wait((int32_t)p, 8, 0), 0); /* nothing left registered */
  EQI(ec_poll_wait((int32_t)p, 0, 0), -EINVAL);
  ec_fd_close((int32_t)cs);
  ec_fd_close((int32_t)ls);
  ec_fd_close((int32_t)p);
}

static void test_tcp(void) {
  echo_round(4);
  echo_round(6);
  /* a blocking connect to a closed port is refused */
  unsigned char a[16];
  int64_t s = ec_sock_open(4, 1, 0);
  set_addr(a, addr4(a, 0, 127, 0, 0, 1));
  EQI(ec_sock_bind((int32_t)s), 0);
  EQI(ec_sock_name((int32_t)s, 0), 0);
  int port = out_port();
  ec_fd_close((int32_t)s); /* bound, never listened: the port refuses */
  s = ec_sock_open(4, 1, 0);
  set_addr(a, addr4(a, port, 127, 0, 0, 1));
  EQI(ec_sock_connect((int32_t)s), -ECONNREFUSED);
  EQI(ec_sock_name((int32_t)s, 1), -ENOTCONN);
  ec_fd_close((int32_t)s);
  /* malformed addresses and arguments */
  s = ec_sock_open(4, 1, 0);
  set_addr(a, 6);
  EQI(ec_sock_bind((int32_t)s), -EINVAL);
  ec_in_clear();
  EQI(ec_sock_connect((int32_t)s), -EINVAL);
  ec_fd_close((int32_t)s);
  EQI(ec_sock_open(5, 1, 0), -EAFNOSUPPORT);
  EQI(ec_sock_open(4, 3, 0), -EINVAL);
}

static void test_udp(void) {
  unsigned char a[16], b[16];
  int64_t s1 = ec_sock_open(4, 2, 0), s2 = ec_sock_open(4, 2, 0);
  CHECK(s1 >= 3 && s2 >= 3);
  set_addr(a, addr4(a, 0, 127, 0, 0, 1));
  EQI(ec_sock_bind((int32_t)s1), 0);
  EQI(ec_sock_bind((int32_t)s2), 0);
  EQI(ec_sock_name((int32_t)s1, 0), 0);
  size_t n1 = take(a, sizeof a);
  EQI(ec_sock_name((int32_t)s2, 0), 0);
  size_t n2 = take(b, sizeof b);
  EQI(ec_sock_setopt((int32_t)s1, 8, 1), 0);
  /* s1 -> s2, with a NUL byte in the datagram */
  ec_in_clear();
  push_bytes(b, n2);
  push_bytes("ping\0!", 6);
  EQI(ec_sock_sendto((int32_t)s1, (int32_t)n2), 6);
  EQI(ec_sock_recvfrom((int32_t)s2, 100), 6);
  EQI(ec_out_byte(0), (int64_t)n1);
  int same = 1;
  for (size_t i = 0; i < n1; i++) same = same && ec_out_byte((int64_t)(1 + i)) == a[i];
  CHECK(same); /* the sender is s1 */
  EQI(ec_out_len(), (int64_t)(1 + n1 + 6));
  EQI(ec_out_byte((int64_t)(1 + n1 + 4)), 0);
  /* reply, and a datagram longer than max is truncated */
  ec_in_clear();
  push_bytes(a, n1);
  push_str("pong-pong");
  EQI(ec_sock_sendto((int32_t)s2, (int32_t)n1), 9);
  EQI(ec_sock_recvfrom((int32_t)s1, 4), 4);
  EQI(ec_out_len(), (int64_t)(1 + n2 + 4));
  /* sendto with an address length past the input */
  set_data("x");
  EQI(ec_sock_sendto((int32_t)s1, 50), -EINVAL);
  /* connected UDP: send/recv */
  set_addr(b, n2);
  EQI(ec_sock_connect((int32_t)s1), 0);
  set_data("abc");
  EQI(ec_sock_send((int32_t)s1), 3);
  EQI(ec_sock_recv((int32_t)s2, 100, 0), 3);
  CHECK(out_is("abc"));
  ec_fd_close((int32_t)s1);
  ec_fd_close((int32_t)s2);
}

static void test_unix(void) {
  unsigned char a[200], got[200];
  char path[4200];
  path_in(path, sizeof path, "sock");
  size_t an = addr_unix(a, path);
  int64_t ls = ec_sock_open(1, 1, 0);
  CHECK(ls >= 3);
  set_addr(a, an);
  EQI(ec_sock_bind((int32_t)ls), 0);
  EQI(ec_sock_listen((int32_t)ls, 4), 0);
  EQI(ec_sock_name((int32_t)ls, 0), 0);
  size_t gn = take(got, sizeof got);
  CHECK(gn == an && !memcmp(got, a, an));
  int64_t cs = ec_sock_open(1, 1, 0);
  set_addr(a, an);
  EQI(ec_sock_connect((int32_t)cs), 0); /* the backlog takes it before accept */
  int64_t ss = ec_sock_accept((int32_t)ls, 0);
  CHECK(ss >= 3);
  EQI(ec_out_byte(0), 1); /* an unnamed peer: family only */
  EQI(ec_out_len(), 3);
  set_data("over unix");
  EQI(ec_sock_send((int32_t)cs), 9);
  EQI(ec_sock_recv((int32_t)ss, 100, 0), 9);
  CHECK(out_is("over unix"));
  EQI(ec_sock_name((int32_t)cs, 1), 0);
  gn = take(got, sizeof got);
  CHECK(gn == an && !memcmp(got, a, an));
  /* the peer is gone: send fails with EPIPE, no SIGPIPE */
  ec_fd_close((int32_t)ss);
  set_data("late");
  int64_t e = ec_sock_send((int32_t)cs);
  CHECK(e == -EPIPE || e == -ECONNRESET);
  ec_fd_close((int32_t)cs);
  ec_fd_close((int32_t)ls);
  unlink(path);
  /* a path too long for sun_path */
  char lng[300];
  memset(lng, 'x', sizeof lng - 1);
  lng[sizeof lng - 1] = 0;
  ls = ec_sock_open(1, 1, 0);
  unsigned char big[400];
  set_addr(big, addr_unix(big, lng));
  EQI(ec_sock_bind((int32_t)ls), -EINVAL);
  ec_fd_close((int32_t)ls);
  /* socketpair */
  EQI(ec_sock_pair(1), 0);
  int x = out_i32(0), y = out_i32(4);
  CHECK(x >= 3 && y >= 3 && (fcntl(x, F_GETFD) & FD_CLOEXEC));
  set_data("pair");
  EQI(ec_sock_send(x), 4);
  EQI(ec_read_fd(y, 10), 4);
  CHECK(out_is("pair"));
  ec_fd_close(x);
  ec_fd_close(y);
  EQI(ec_sock_pair(7), -EINVAL);
}

static void test_dns(void) {
  /* localhost: every result is a loopback address with the asked-for port */
  ec_in_clear();
  push_str("localhost");
  ec_in_push(0);
  push_str("80");
  int64_t n = ec_dns_lookup(0, 1, 0);
  CHECK(n >= 1);
  int64_t at = 0, len = ec_out_len();
  int ok = 1, seen = 0;
  while (at < len) {
    int st = ec_out_byte(at), an = ec_out_byte(at + 1);
    int64_t ad = at + 2;
    int fam = ec_out_byte(ad), port = ec_out_byte(ad + 1) * 256 + ec_out_byte(ad + 2);
    if (st != 1 || port != 80) ok = 0;
    if (fam == 4 && (an != 7 || ec_out_byte(ad + 3) != 127)) ok = 0;
    if (fam == 6 && (an != 23 || ec_out_byte(ad + 18) != 1)) ok = 0;
    if (fam != 4 && fam != 6) ok = 0;
    at = ad + an;
    seen++;
  }
  CHECK(ok && at == len && seen == n);
  /* numeric lookups, by family */
  ec_in_clear();
  push_str("127.0.0.1");
  ec_in_push(0);
  push_str("8080");
  EQI(ec_dns_lookup(4, 2, 2), 1);
  EQI(ec_out_len(), 9);
  CHECK(ec_out_byte(0) == 2 && ec_out_byte(1) == 7 && ec_out_byte(2) == 4 && ec_out_byte(5) == 127);
  EQI(ec_out_byte(3) * 256 + ec_out_byte(4), 8080);
  ec_in_clear();
  push_str("::1");
  EQI(ec_dns_lookup(6, 1, 2), 1);
  CHECK(ec_out_byte(2) == 6 && ec_out_byte(20) == 1);
  /* a name with the numeric-only flag: a resolver error, with a message (no network used) */
  ec_in_clear();
  push_str("not-a-number");
  int64_t e = ec_dns_lookup(0, 1, 2);
  CHECK(e <= -1000001 && e >= -1000009);
  ec_errstr(e);
  CHECK(ec_out_len() > 0 && !out_is("unknown error"));
  /* passive with no host: the wildcard address */
  ec_in_clear();
  ec_in_push(0);
  push_str("9");
  EQI(ec_dns_lookup(4, 1, 1), 1);
  CHECK(ec_out_byte(5) == 0 && ec_out_byte(8) == 0);
  EQI(ec_dns_lookup(5, 0, 0), -EINVAL);
  /* reverse, numerically */
  unsigned char a[16];
  set_addr(a, addr4(a, 80, 127, 0, 0, 1));
  EQI(ec_dns_reverse(1 | 2), 0);
  unsigned char b[64];
  size_t bn = take(b, sizeof b);
  CHECK(bn == 12 && !memcmp(b, "127.0.0.1\0" "80", 12));
  ec_in_clear();
  EQI(ec_dns_reverse(1), -EINVAL);
}

static int wake_fd;
static void *waker_thread(void *p) {
  (void)p;
  ec_sleep_ns(20 * 1000000);
  ec_waker_wake(wake_fd);
  return NULL;
}

static void test_waker(void) {
  int64_t p = ec_poll_new();
  EQI(ec_waker_new(), 0);
  int r = out_i32(0), w = out_i32(4);
  CHECK(r >= 3 && w >= 3);
  EQI(ec_poll_ctl((int32_t)p, 0, r, 1, 7), 0);
  Event ev[4];
  EQI(wait_events((int)p, ev, 4, 0), 0);
  wake_fd = w;
  pthread_t t;
  pthread_create(&t, NULL, waker_thread, NULL);
  int n = wait_events((int)p, ev, 4, 5000);
  pthread_join(t, NULL);
  CHECK(n == 1 && ev[0].token == 7 && (ev[0].flags & 1));
  /* several wakes before a drain are one readiness; draining clears it */
  EQI(ec_waker_wake(w), 0);
  EQI(ec_waker_wake(w), 0);
  CHECK(ec_read_fd(r, 4096) > 0);
  int64_t again = ec_read_fd(r, 4096);
  CHECK(again == -EAGAIN || again == -EWOULDBLOCK);
  EQI(wait_events((int)p, ev, 4, 0), 0);
  /* one-shot: one event, then nothing until re-armed */
  EQI(ec_poll_ctl((int32_t)p, 1, r, 1 | 8, 8), 0);
  ec_waker_wake(w);
  EQI(wait_events((int)p, ev, 4, 1000), 1);
  EQI(ev[0].token, 8);
  EQI(wait_events((int)p, ev, 4, 0), 0);
  EQI(ec_poll_ctl((int32_t)p, 1, r, 1, 9), 0);
  EQI(wait_events((int)p, ev, 4, 1000), 1);
  EQI(ev[0].token, 9);
  ec_read_fd(r, 4096);
  /* timeouts: the wait lasts about as long as asked */
  int64_t t0 = ec_time_mono_ns();
  EQI(wait_events((int)p, ev, 4, 50), 0);
  int64_t dt = ec_time_mono_ns() - t0;
  CHECK(dt >= 45 * 1000000 && dt < 2000 * (int64_t)1000000);
  EQI(ec_poll_ctl((int32_t)p, 3, r, 1, 0), -EINVAL);
  EQI(ec_poll_ctl((int32_t)p, 2, r, 0, 0), 0);
  ec_fd_close(r);
  if (w != r) ec_fd_close(w);
  ec_fd_close((int32_t)p);
}

// ---- time

static void on_alarm(int s) { (void)s; }

static void test_time(void) {
  int64_t prev = ec_time_mono_ns();
  int mono = 1;
  for (int i = 0; i < 10000; i++) {
    int64_t t = ec_time_mono_ns();
    if (t < prev) mono = 0;
    prev = t;
  }
  CHECK(mono);
  CHECK(ec_time_wall_ns() > (int64_t)1577836800 * 1000000000); /* after 2020-01-01 */
  int64_t t0 = ec_time_mono_ns();
  EQI(ec_sleep_ns(30 * 1000000), 0);
  int64_t dt = ec_time_mono_ns() - t0;
  CHECK(dt >= 30 * 1000000 && dt < 2000 * (int64_t)1000000);
  EQI(ec_sleep_ns(0), 0);
  EQI(ec_sleep_ns(-5), 0);
  /* a 1 ms interval timer interrupts the sleep constantly: it still lasts the full time */
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_alarm;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGALRM, &sa, NULL);
  struct itimerval it = {{0, 1000}, {0, 1000}}, off = {{0, 0}, {0, 0}};
  setitimer(ITIMER_REAL, &it, NULL);
  t0 = ec_time_mono_ns();
  EQI(ec_sleep_ns(50 * 1000000), 0);
  dt = ec_time_mono_ns() - t0;
  setitimer(ITIMER_REAL, &off, NULL);
  signal(SIGALRM, SIG_DFL);
  CHECK(dt >= 50 * 1000000);
}

// ---- randomness

static void test_random(void) {
  unsigned char a[64], b[64];
  EQI(ec_random(64, 0), 64);
  EQI(ec_out_len(), 64);
  take(a, sizeof a + 0);
  EQI(ec_random(64, 1), 64);
  take(b, sizeof b);
  CHECK(memcmp(a, b, 63) != 0);
  int distinct = 0;
  for (int i = 1; i < 63; i++) distinct += a[i] != a[0];
  CHECK(distinct > 0);
  EQI(ec_random(0, 0), 0);
  EQI(ec_out_len(), 0);
  EQI(ec_random(-1, 0), -EINVAL);
  EQI(ec_random((int64_t)1 << 40, 0), -EINVAL);
  EQI(ec_random((int64_t)1 << 20, 0), (int64_t)1 << 20); /* the largest request */
}

// ---- signals

static int sig_read(int fd, int64_t p, int want) {
  Event ev[4];
  for (int tries = 0; tries < 50; tries++) {
    int64_t k = ec_read_fd(fd, 64);
    if (k > 0) {
      for (int64_t i = 0; i < k; i++)
        if (ec_out_byte(i) == want) return 1;
      continue;
    }
    wait_events((int)p, ev, 4, 100);
  }
  return 0;
}

static void test_signals(void) {
  int64_t sfd = ec_signal_fd();
  CHECK(sfd >= 3);
  EQI(ec_signal_fd(), sfd); /* the same pipe every time */
  CHECK(fcntl((int)sfd, F_GETFL) & O_NONBLOCK);
  int64_t p = ec_poll_new();
  EQI(ec_poll_ctl((int32_t)p, 0, (int32_t)sfd, 1, 42), 0);
  const int sigs[] = {15, 2, 1};
  for (int i = 0; i < 3; i++) {
    EQI(ec_signal_set(sigs[i], 2), 0);
    EQI(ec_kill((int32_t)ec_getpid(), sigs[i]), 0);
    Event ev[4];
    int n = wait_events((int)p, ev, 4, 2000);
    CHECK(n == 1 && ev[0].token == 42);
    check(sig_read((int)sfd, p, sigs[i]), "signal delivered as an event", __LINE__);
    EQI(ec_signal_set(sigs[i], 0), 0);
  }
  /* SIGCHLD when a child exits */
  EQI(ec_signal_set(17, 2), 0);
  set_child("exit3");
  int64_t pid = ec_spawn(0, 1, 1);
  CHECK(pid > 0);
  check(sig_read((int)sfd, p, 17), "SIGCHLD delivered as an event", __LINE__);
  EQI(ec_wait((int32_t)pid, 0), 3);
  EQI(out_i32(0), pid);
  /* the child does not inherit our handlers, our mask or an ignored SIGPIPE */
  EQI(ec_signal_set(15, 2), 0);
  EQI(ec_signal_mask(10, 1), 0);
  set_child("sigstate");
  pid = ec_spawn(1, 2, 0);
  CHECK(pid > 0);
  int out = out_i32(4);
  EQI(ec_read_fd(out, 64), 5);
  CHECK(out_is("clean"));
  ec_fd_close(out);
  EQI(ec_wait((int32_t)pid, 0), 0);
  EQI(ec_signal_set(15, 0), 0);
  EQI(ec_signal_set(17, 0), 0);
  while (ec_read_fd((int)sfd, 64) > 0) {}
  /* a blocked signal waits until it is unblocked */
  EQI(ec_signal_set(10, 2), 0);
  pthread_kill(pthread_self(), SIGUSR1);
  EQI(ec_read_fd((int)sfd, 64), -EAGAIN);
  EQI(ec_signal_mask(10, 0), 0);
  check(sig_read((int)sfd, p, 10), "unblocked signal delivered", __LINE__);
  EQI(ec_signal_set(10, 0), 0);
  /* ignore, and bad numbers */
  EQI(ec_signal_set(12, 1), 0);
  EQI(ec_kill((int32_t)ec_getpid(), 12), 0);
  EQI(ec_signal_set(12, 0), 0);
  EQI(ec_signal_set(9, 2), -EINVAL);
  EQI(ec_signal_set(99, 0), -EINVAL);
  EQI(ec_signal_set(15, 3), -EINVAL);
  EQI(ec_signal_mask(0, 1), -EINVAL);
  EQI(ec_kill((int32_t)ec_getpid(), 0), 0);
  EQI(ec_kill((int32_t)ec_getpid(), 77), -EINVAL);
  ec_fd_close((int32_t)p);
}

// ---- processes

static void test_spawn(void) {
  /* all three piped: write stdin, read stdout to the end, then stderr */
  set_child("echo");
  int64_t pid = ec_spawn(2, 2, 2);
  CHECK(pid > 0);
  EQI(ec_out_len(), 12);
  int in = out_i32(0), out = out_i32(4), err = out_i32(8);
  CHECK(in >= 3 && out >= 3 && err >= 3);
  CHECK((fcntl(in, F_GETFD) & FD_CLOEXEC) && (fcntl(out, F_GETFD) & FD_CLOEXEC));
  set_data("ping\npong\n");
  EQI(ec_fd_write(in), 10);
  ec_fd_close(in);
  char all[64] = {0};
  size_t at = 0;
  for (;;) {
    int64_t k = ec_read_fd(out, 64);
    if (k <= 0) break;
    for (int64_t i = 0; i < k && at < sizeof all - 1; i++) all[at++] = (char)ec_out_byte(i);
  }
  CHECK(!strcmp(all, "ping\npong\n"));
  EQI(ec_read_fd(err, 64), 4);
  CHECK(out_is("done"));
  ec_fd_close(out);
  ec_fd_close(err);
  EQI(ec_wait((int32_t)pid, 0), 0);
  /* stdin from /dev/null, stdout piped, stderr inherited */
  set_child("echo");
  pid = ec_spawn(1, 2, 1);
  CHECK(pid > 0);
  CHECK(out_i32(0) == -1 && out_i32(8) == -1);
  out = out_i32(4);
  EQI(ec_read_fd(out, 64), 0); /* /dev/null is empty */
  ec_fd_close(out);
  EQI(ec_wait((int32_t)pid, 0), 0);
  /* non-blocking wait, kill, and the signal in the result */
  set_child("sleep");
  pid = ec_spawn(1, 1, 1);
  CHECK(pid > 0);
  EQI(ec_wait((int32_t)pid, 1), -EAGAIN);
  EQI(ec_kill((int32_t)pid, 0), 0);
  EQI(ec_kill((int32_t)pid, 15), 0);
  EQI(ec_wait((int32_t)pid, 0), 256 + 15);
  EQI(ec_wait((int32_t)pid, 1), -ECHILD);
  /* exec failure is the spawn's result; nothing is left to reap */
  ec_in_clear();
  push_str("/nonexistent/eider-no-such-program");
  EQI(ec_spawn(0, 2, 2), -ENOENT);
  EQI(ec_out_len(), 0);
  ec_in_clear();
  push_str("eider-no-such-program-on-path");
  EQI(ec_spawn(2, 0, 0), -ENOENT);
  EQI(ec_wait(-1, 1), -ECHILD);
  set_child("echo");
  EQI(ec_spawn(3, 0, 0), -EINVAL);
  ec_in_clear();
  EQI(ec_spawn(0, 0, 0), -EINVAL);
  CHECK(ec_getpid() == (int64_t)getpid());
}

int main(int argc, char **argv) {
  if (argc >= 3 && !strcmp(argv[1], "child")) return child(argv[2]);
  snprintf(self, sizeof self, "%s", argv[0]);
  if (!strchr(self, '/')) {
    fprintf(stderr, "os_test: run with a path (it re-executes itself)\n");
    return 2;
  }
  const char *base = getenv("TMPDIR");
  snprintf(tmpdir, sizeof tmpdir, "%s/eider-os-test-XXXXXX", base && *base ? base : "/tmp");
  if (!mkdtemp(tmpdir)) {
    perror("mkdtemp");
    return 2;
  }
  umask(022);
  test_fd();
  test_tcp();
  test_udp();
  test_unix();
  test_dns();
  test_waker();
  test_time();
  test_random();
  test_signals();
  test_spawn();
  rmdir(tmpdir);
  printf("%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
