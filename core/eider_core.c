// eider_core: the only hand-written C under Eider. Contract: core/ABI.md.
//
// Rules: no logic lives here. Each function is one OS operation with errors returned as
// -errno. Pointers never cross into Eider: data moves through two byte buffers. Eider fills
// `in` a byte at a time (arguments NUL-separated), calls an op, then reads `out` a byte at a
// time. Parsing, paths, recursion and formatting are Eider (std/).
//
// Portability: C11 + POSIX.1-2008, no compiler extensions except where marked. Exercised on
// Linux (glibc, x86-64); written for macOS and the BSDs (argument access differs per OS, see
// ec_args). Windows needs its own backend implementing ABI.md and is refused at compile time
// rather than half-supported.
#if defined(_WIN32)
#error "eider_core: no Windows backend yet (write eider_core_win32.c against core/ABI.md)"
#endif

/* Feature macros: each system's own "everything" switch. On the BSDs the default environment
   already exposes POSIX plus the BSD calls the core needs (flock, kqueue, accept4,
   arc4random_buf); defining _POSIX_C_SOURCE there would hide them. */
#if defined(__linux__)
#define _GNU_SOURCE 1 /* pipe2, accept4, epoll, eventfd, getrandom, MSG_NOSIGNAL */
#define _FILE_OFFSET_BITS 64 /* 64-bit off_t on 32-bit Linux too */
#elif defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
#define EC_BSD 1
#if defined(__NetBSD__)
#define _NETBSD_SOURCE 1
#endif
#else
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700 /* realpath (XSI) */
#endif

#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#endif
#if defined(__linux__) || defined(__APPLE__) || defined(EC_BSD)
#include <sys/file.h> /* flock: not POSIX, but on every system with a backend here */
#define EC_HAVE_FLOCK 1
#endif
#if defined(__linux__)
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/random.h>
#define EC_EPOLL 1
#elif defined(__APPLE__) || defined(EC_BSD)
#include <sys/event.h>
#define EC_KQUEUE 1
#endif

/* Eider declares externs as `T f(...) __asm__("f")`, i.e. by raw symbol name. Where the
   platform decorates C names (Mach-O prefixes `_`), pin the raw name (GNU C extension). */
#if defined(__APPLE__)
#define EC_SYM(n) __asm__(#n)
#else
#define EC_SYM(n)
#endif
#define EC_FN(ret, name, params) ret name params EC_SYM(name); ret name params

/* Per-thread, so Eider threads (spawn) can do I/O independently. */
static _Thread_local unsigned char *in_p, *out_p;
static _Thread_local size_t in_len, in_cap, out_len, out_cap;

/* A thread's buffers are freed when it exits: the first allocation registers the thread with
   a pthread key whose destructor runs at thread exit (thread-local storage is still valid
   then). The main thread's buffers live until the process ends. */
static pthread_key_t buf_key;
static pthread_once_t buf_once = PTHREAD_ONCE_INIT;
static _Thread_local int buf_registered;

static void free_bufs(void *unused) {
  (void)unused;
  free(in_p);
  free(out_p);
  in_p = out_p = NULL;
  in_len = in_cap = out_len = out_cap = 0;
}

static void make_buf_key(void) {
  if (pthread_key_create(&buf_key, free_bufs) != 0) { fputs("eider_core: cannot create a thread key\n", stderr); exit(101); }
}

static void register_bufs(void) {
  if (buf_registered) return;
  pthread_once(&buf_once, make_buf_key);
  /* any non-NULL value makes the destructor run */
  if (pthread_setspecific(buf_key, &buf_registered) != 0) { fputs("eider_core: cannot register thread buffers\n", stderr); exit(101); }
  buf_registered = 1;
}

static void reserve(unsigned char **p, size_t *cap, size_t need) {
  if (need <= *cap) return;
  register_bufs();
  size_t n = *cap ? *cap : 256;
  while (n < need) {
    if (n > SIZE_MAX / 2) { fputs("eider_core: buffer too large\n", stderr); exit(101); }
    n *= 2;
  }
  unsigned char *q = realloc(*p, n);
  if (!q) { fputs("eider_core: out of memory\n", stderr); exit(101); }
  *p = q;
  *cap = n;
}

static void out_put(const void *d, size_t n) {
  reserve(&out_p, &out_cap, out_len + n + 1);
  if (n) memcpy(out_p + out_len, d, n);
  out_len += n;
  out_p[out_len] = 0;
}

/* in[k]: the k-th NUL-separated argument, or NULL past the last one. */
static const char *arg(int k) {
  reserve(&in_p, &in_cap, 1);
  in_p[in_len] = 0;
  size_t i = 0;
  for (; k > 0; k--) {
    while (i < in_len && in_p[i]) i++;
    if (i >= in_len) return NULL;
    i++;
  }
  return (const char *)in_p + i;
}

static int64_t fail(void) { return errno ? -(int64_t)errno : -EIO; }

/* Little-endian fields into out (the layouts in ABI.md). */
static void out_u32(uint32_t v) {
  unsigned char b[4];
  for (int i = 0; i < 4; i++) b[i] = (unsigned char)(v >> (8 * i));
  out_put(b, 4);
}

static void out_u64(uint64_t v) {
  unsigned char b[8];
  for (int i = 0; i < 8; i++) b[i] = (unsigned char)(v >> (8 * i));
  out_put(b, 8);
}

/* The whole of `in` as bytes (never NULL). */
static const unsigned char *in_bytes(void) {
  reserve(&in_p, &in_cap, 1);
  return in_p;
}

/* ---- signal numbers

   Eider uses one numbering on every system: the traditional numbers, which are also
   Linux's (HUP 1, INT 2, QUIT 3, ABRT 6, KILL 9, USR1 10, USR2 12, PIPE 13, ALRM 14, TERM 15,
   CHLD 17, CONT 18, STOP 19, TSTP 20, WINCH 28). Other systems translate here. */
static const int sig_map[][2] = {
  {1, SIGHUP}, {2, SIGINT}, {3, SIGQUIT}, {6, SIGABRT}, {9, SIGKILL}, {10, SIGUSR1},
  {12, SIGUSR2}, {13, SIGPIPE}, {14, SIGALRM}, {15, SIGTERM}, {17, SIGCHLD}, {18, SIGCONT},
  {19, SIGSTOP}, {20, SIGTSTP},
#if defined(SIGWINCH)
  {28, SIGWINCH},
#endif
};
#define SIG_COUNT (sizeof sig_map / sizeof sig_map[0])

/* Native number for Eider number `s` (0 stays 0, for kill's existence check); -1 if unknown. */
static int sig_native(int32_t s) {
  if (s == 0) return 0;
  for (size_t i = 0; i < SIG_COUNT; i++)
    if (sig_map[i][0] == s) return sig_map[i][1];
  return -1;
}

/* Eider number for native signal `n`; 0 if it has none. Async-signal-safe. */
static int sig_portable(int n) {
  for (size_t i = 0; i < SIG_COUNT; i++)
    if (sig_map[i][1] == n) return sig_map[i][0];
  return 0;
}

/* The signal pipe (ec_signal_fd): created once, never closed. The handler writes one byte,
   the signal's Eider number, per delivery. */
static int sig_pipe[2] = {-1, -1};
static int sig_pipe_err;
static pthread_once_t sig_pipe_once = PTHREAD_ONCE_INIT;

static void on_signal(int n) {
  int e = errno;
  unsigned char b = (unsigned char)sig_portable(n);
  (void)!write(sig_pipe[1], &b, 1); /* full pipe: the delivery is dropped, never blocks */
  errno = e;
}

/* SIGPIPE is ignored from the first socket, pipe or piped spawn on (ABI.md "SIGPIPE"). */
static pthread_once_t sigpipe_once = PTHREAD_ONCE_INIT;
static void ignore_sigpipe(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = SIG_IGN;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGPIPE, &sa, NULL);
}
static void ignore_sigpipe_once(void) { pthread_once(&sigpipe_once, ignore_sigpipe); }

/* Around fork: every signal blocked in the forking thread, so no handler of ours runs in the
   child before it has reset them. */
static void block_signals(sigset_t *old) {
  sigset_t all;
  sigfillset(&all);
  pthread_sigmask(SIG_SETMASK, &all, old);
}

static void restore_signals(const sigset_t *old) { pthread_sigmask(SIG_SETMASK, old, NULL); }

/* In a forked child, before exec (async-signal-safe calls only): signals the core delivers
   to the signal pipe, and SIGPIPE, go back to their defaults, and the mask is emptied, so the
   new program starts as it would from a shell. */
static void child_reset_signals(void) {
  struct sigaction dfl, cur;
  memset(&dfl, 0, sizeof dfl);
  dfl.sa_handler = SIG_DFL;
  sigemptyset(&dfl.sa_mask);
  for (size_t i = 0; i < SIG_COUNT; i++) {
    int n = sig_map[i][1];
    if (n == SIGKILL || n == SIGSTOP) continue;
    if (sigaction(n, NULL, &cur) == 0 && (cur.sa_handler == on_signal || n == SIGPIPE))
      sigaction(n, &dfl, NULL);
  }
  sigset_t none;
  sigemptyset(&none);
  sigprocmask(SIG_SETMASK, &none, NULL);
}

// ---- buffers

EC_FN(void, ec_in_clear, (void)) {
  in_len = 0;
  reserve(&in_p, &in_cap, 1);
  in_p[0] = 0;
}

EC_FN(void, ec_in_push, (int32_t b)) {
  reserve(&in_p, &in_cap, in_len + 2);
  in_p[in_len++] = (unsigned char)b;
  in_p[in_len] = 0;
}

/* The input buffer as a C string (always NUL-terminated). */
EC_FN(const char *, ec_in_cstr, (void)) {
  reserve(&in_p, &in_cap, 1);
  in_p[in_len] = 0;
  return (const char *)in_p;
}

EC_FN(int64_t, ec_out_len, (void)) { return (int64_t)out_len; }

EC_FN(int32_t, ec_out_byte, (int64_t i)) {
  return i >= 0 && (uint64_t)i < out_len ? out_p[i] : -1;
}

/* Length and bytes of a string literal (Eider bounds-checks i against ec_str_len). */
EC_FN(int64_t, ec_str_len, (const char *s)) { return (int64_t)strlen(s); }
EC_FN(int32_t, ec_str_byte, (const char *s, int64_t i)) { return (unsigned char)s[i]; }

static const char *resolver_text(int64_t e);

/* The text for status -errno `e`, or a resolver status (ec_dns_lookup), into out. */
EC_FN(void, ec_errstr, (int64_t e)) {
  out_len = 0;
  const char *m = e < 0 && e > -100000 ? strerror((int)-e) : resolver_text(e);
  out_put(m, strlen(m));
}

/* A portable kind for status e (errno values differ between systems; ABI.md "Error kinds"). */
EC_FN(int32_t, ec_err_kind, (int64_t e)) {
  if (e >= 0) return 0;
  if (e <= -1000001) return e == -1000001 ? 4 : e == -1000002 ? 17 : 18; /* resolver */
  if (e < -100000) return 0;
  int n = (int)-e;
  if (n == EAGAIN || n == EWOULDBLOCK) return 1;
  if (n == EINPROGRESS || n == EALREADY) return 2;
  if (n == EINTR) return 3;
  if (n == ENOENT) return 4;
  if (n == EEXIST) return 5;
  if (n == EPIPE) return 6;
  if (n == ECONNRESET || n == ECONNABORTED) return 7;
  if (n == ECONNREFUSED) return 8;
  if (n == ETIMEDOUT) return 9;
  if (n == EACCES || n == EPERM) return 10;
  if (n == EADDRINUSE) return 11;
  if (n == EADDRNOTAVAIL) return 12;
  if (n == ENOTCONN) return 13;
  if (n == EINVAL) return 14;
  if (n == ECHILD) return 15;
  if (n == ENOSYS || n == EAFNOSUPPORT || n == EPROTONOSUPPORT || n == ENOPROTOOPT || n == EOPNOTSUPP) return 16;
  return 0;
}

EC_FN(void, ec_exit, (int32_t code)) {
  fflush(stdout);
  exit(code);
}

// ---- process: arguments and environment

#if !defined(__APPLE__) && !defined(__linux__)
/* The BSDs pass (argc, argv, envp) to init_array functions (GNU C extension). */
static int saved_argc;
static char **saved_argv;
__attribute__((constructor)) static void save_args(int argc, char **argv) {
  saved_argc = argc;
  saved_argv = argv;
}
#endif

/* argv into out, each argument followed by NUL. */
EC_FN(int64_t, ec_args, (void)) {
  out_len = 0;
#if defined(__APPLE__)
  int n = *_NSGetArgc();
  char **v = *_NSGetArgv();
  for (int i = 0; i < n; i++) out_put(v[i], strlen(v[i]) + 1);
  return 0;
#elif defined(__linux__)
  FILE *f = fopen("/proc/self/cmdline", "rb");
  if (!f) return fail();
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) out_put(buf, n);
  fclose(f);
  return 0;
#else
  if (!saved_argv) return -ENOSYS;
  for (int i = 0; i < saved_argc; i++) out_put(saved_argv[i], strlen(saved_argv[i]) + 1);
  return 0;
#endif
}

/* getenv(in[0]) into out; 1 if set, 0 if not. */
EC_FN(int32_t, ec_getenv, (void)) {
  out_len = 0;
  const char *v = getenv(arg(0));
  if (!v) return 0;
  out_put(v, strlen(v));
  return 1;
}

/* The current directory into out. */
EC_FN(int64_t, ec_cwd, (void)) {
  size_t cap = 256;
  for (;;) {
    char *buf = malloc(cap);
    if (!buf) return -ENOMEM;
    if (getcwd(buf, cap)) {
      out_len = 0;
      out_put(buf, strlen(buf));
      free(buf);
      return 0;
    }
    int e = errno;
    free(buf);
    if (e != ERANGE) return -(int64_t)e;
    cap *= 2;
  }
}

/* The canonical absolute path of in[0] (every symlink, `.` and `..` resolved) into out. */
EC_FN(int64_t, ec_realpath, (void)) {
  char *r = realpath(arg(0), NULL);
  if (!r) return fail();
  out_len = 0;
  out_put(r, strlen(r));
  free(r);
  return 0;
}

/* Write in[] to fd 1 or 2, after flushing Eider's buffered `print` output. */
EC_FN(int64_t, ec_write_fd, (int32_t fd)) {
  fflush(stdout);
  size_t i = 0;
  while (i < in_len) {
    ssize_t w = write(fd, in_p + i, in_len - i);
    if (w < 0) {
      if (errno == EINTR) continue;
      return fail();
    }
    i += (size_t)w;
  }
  return 0;
}

#define EC_READ_MAX ((int64_t)1 << 20)

/* Read up to max bytes (at most EC_READ_MAX per call) from fd into out, replacing it.
   Returns the count, 0 at end of file, -errno on error; EINTR is retried. */
EC_FN(int64_t, ec_read_fd, (int32_t fd, int64_t max)) {
  out_len = 0;
  if (fd < 0 || max <= 0) return -EINVAL;
  size_t n = (size_t)(max < EC_READ_MAX ? max : EC_READ_MAX);
  reserve(&out_p, &out_cap, n + 1);
  ssize_t r;
  do r = read(fd, out_p, n); while (r < 0 && errno == EINTR);
  if (r < 0) {
    out_p[0] = 0;
    return fail();
  }
  out_len = (size_t)r;
  out_p[out_len] = 0;
  return (int64_t)r;
}

/* A pipe with both ends close-on-exec (atomically where the OS has pipe2). */
static int cloexec_pipe(int p[2]) {
#if defined(__linux__)
  return pipe2(p, O_CLOEXEC);
#else
  if (pipe(p) != 0) return -1;
  if (fcntl(p[0], F_SETFD, FD_CLOEXEC) == 0 && fcntl(p[1], F_SETFD, FD_CLOEXEC) == 0) return 0;
  int e = errno;
  close(p[0]);
  close(p[1]);
  errno = e;
  return -1;
#endif
}

static void close_fd(int *fd) {
  if (*fd >= 0) close(*fd);
  *fd = -1;
}

static int64_t now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000 + (int64_t)t.tv_nsec / 1000000;
}

/* In the child: a close-on-exec copy of `fd` above 0..2, so the dup2s onto 1 and 2 can't
   overwrite it (our pipes only land on 0..2 if the parent had closed its stdio). */
static int above_stdio(int fd) {
  return fd >= 0 && fd <= 2 ? fcntl(fd, F_DUPFD_CLOEXEC, 3) : fd;
}

#define EC_RUN_TIMEOUT 256
#define EC_RUN_GRACE_MS 200

/* Run argv = in[0..] (searched on PATH); contract in ABI.md "Running a program".
   out_mode / err_mode: 0 inherit, 1 capture. timeout_ms > 0: SIGTERM the child's process
   group at the deadline, SIGKILL after EC_RUN_GRACE_MS. Returns the exit code, 128+signal,
   EC_RUN_TIMEOUT, or -errno. out = 8-byte little-endian stdout length, stdout, stderr. */
EC_FN(int64_t, ec_run, (int32_t out_mode, int32_t err_mode, int64_t timeout_ms)) {
  if (in_len == 0 || out_mode < 0 || out_mode > 1 || err_mode < 0 || err_mode > 1) return -EINVAL;
  int limited = timeout_ms > 0;
  if (timeout_ms > 1000000000000) timeout_ms = 1000000000000; /* ~31 years: no overflow */
  int argc = 0;
  while (arg(argc)) argc++;
  char **argv = calloc((size_t)argc + 1, sizeof *argv);
  if (!argv) return -ENOMEM;
  for (int k = 0; k < argc; k++) argv[k] = (char *)arg(k);
  /* op: stdout, ep: stderr, xp: exec errno (closes on a successful exec) */
  int op[2] = {-1, -1}, ep[2] = {-1, -1}, xp[2] = {-1, -1};
  if ((out_mode && cloexec_pipe(op) != 0) || (err_mode && cloexec_pipe(ep) != 0) ||
      cloexec_pipe(xp) != 0) {
    int64_t r = fail();
    close_fd(&op[0]); close_fd(&op[1]); close_fd(&ep[0]); close_fd(&ep[1]);
    free(argv);
    return r;
  }
  int64_t deadline = limited ? now_ms() + timeout_ms : 0;
  fflush(stdout);
  fflush(stderr);
  sigset_t oldmask;
  block_signals(&oldmask);
  pid_t pid = fork();
  if (pid != 0) restore_signals(&oldmask);
  if (pid < 0) {
    int64_t r = fail();
    close_fd(&op[0]); close_fd(&op[1]); close_fd(&ep[0]); close_fd(&ep[1]);
    close_fd(&xp[0]); close_fd(&xp[1]);
    free(argv);
    return r;
  }
  if (pid == 0) {
    /* only async-signal-safe calls until exec */
    child_reset_signals();
    if (limited) setpgid(0, 0);
    int x = above_stdio(xp[1]), o = above_stdio(op[1]), e = above_stdio(ep[1]);
    if (x < 0) _exit(127);
    if ((out_mode && (o < 0 || dup2(o, 1) < 0)) || (err_mode && (e < 0 || dup2(e, 2) < 0))) {
      int en = errno;
      (void)!write(x, &en, sizeof en);
      _exit(127);
    }
    execvp(argv[0], argv);
    int en = errno;
    (void)!write(x, &en, sizeof en);
    _exit(127);
  }
  free(argv);
  if (limited) setpgid(pid, pid); /* also here, so the group exists whichever runs first */
  close_fd(&op[1]);
  close_fd(&ep[1]);
  close_fd(&xp[1]);
  int xe = 0, status = 0, reaped = 0, stage = 0; /* stage: 0 running, 1 TERM sent, 2 KILL sent */
  int64_t err = 0;
  ssize_t got;
  do got = read(xp[0], &xe, sizeof xe); while (got < 0 && errno == EINTR);
  close_fd(&xp[0]);
  if (got == (ssize_t)sizeof xe) { /* exec failed; the child has exited */
    close_fd(&op[0]);
    close_fd(&ep[0]);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return xe > 0 ? -(int64_t)xe : -EIO;
  }
  out_len = 0;
  out_put("\0\0\0\0\0\0\0\0", 8);
  unsigned char *eb = NULL;
  size_t elen = 0, ecap = 0;
  char buf[65536];
  for (;;) {
    struct pollfd pf[2];
    nfds_t n = 0;
    if (op[0] >= 0) { pf[n].fd = op[0]; pf[n].events = POLLIN; pf[n].revents = 0; n++; }
    if (ep[0] >= 0) { pf[n].fd = ep[0]; pf[n].events = POLLIN; pf[n].revents = 0; n++; }
    if (n == 0 && !limited) break; /* both pipes closed: the blocking reap below */
    if (n == 0) {                   /* the child closed its pipes; it may still be running */
      pid_t w = waitpid(pid, &status, WNOHANG);
      if (w == pid) { reaped = 1; break; }
      if (w < 0 && errno != EINTR) { err = fail(); break; }
    }
    int wait_ms = -1;
    if (limited) {
      int64_t now = now_ms(), left = deadline - now;
      if (left <= 0) {
        if (stage == 2) break; /* give up on the pipes; the child got SIGKILL */
        int sig = stage == 0 ? SIGTERM : SIGKILL;
        if (kill(-pid, sig) != 0) kill(pid, sig);
        stage++;
        deadline = now + EC_RUN_GRACE_MS;
        continue;
      }
      int64_t cap = n == 0 ? 10 : 1000000; /* without pipes, poll the child every 10 ms */
      wait_ms = (int)(left < cap ? left : cap);
    }
    if (n == 0) {
      if (poll(pf, 0, wait_ms) < 0 && errno != EINTR) { err = fail(); break; }
      continue;
    }
    if (poll(pf, n, wait_ms) < 0) {
      if (errno == EINTR) continue;
      err = fail();
      break;
    }
    for (nfds_t i = 0; i < n; i++) {
      if (!pf[i].revents) continue;
      ssize_t r = read(pf[i].fd, buf, sizeof buf);
      if (r < 0 && (errno == EINTR || errno == EAGAIN)) continue;
      int *fd = pf[i].fd == op[0] ? &op[0] : &ep[0];
      if (r <= 0) { close_fd(fd); continue; }
      if (fd == &op[0]) {
        out_put(buf, (size_t)r);
      } else {
        reserve(&eb, &ecap, elen + (size_t)r);
        memcpy(eb + elen, buf, (size_t)r);
        elen += (size_t)r;
      }
    }
  }
  close_fd(&op[0]);
  close_fd(&ep[0]);
  if (!reaped) {
    if (err && (!limited || kill(-pid, SIGKILL) != 0)) kill(pid, SIGKILL);
    pid_t w;
    while ((w = waitpid(pid, &status, 0)) < 0 && errno == EINTR) {}
    if (w < 0 && !err) err = fail();
  }
  if (err) {
    free(eb);
    return err;
  }
  uint64_t olen = (uint64_t)(out_len - 8);
  for (int i = 0; i < 8; i++) out_p[i] = (unsigned char)(olen >> (8 * i));
  out_put(eb, elen);
  free(eb);
  if (stage > 0) return EC_RUN_TIMEOUT;
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

// ---- files: the path is in[0]

EC_FN(int64_t, ec_read_file, (void)) {
  out_len = 0;
  FILE *f = fopen(arg(0), "rb");
  if (!f) return fail();
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) out_put(buf, n);
  int bad = ferror(f);
  fclose(f);
  return bad ? -EIO : (int64_t)out_len;
}

/* in = path NUL data... ; append != 0 appends instead of replacing. */
EC_FN(int64_t, ec_write_file, (int32_t append)) {
  const char *path = arg(0);
  size_t off = strlen(path) + 1, n = in_len > off ? in_len - off : 0;
  FILE *f = fopen(path, append ? "ab" : "wb");
  if (!f) return fail();
  size_t w = n ? fwrite(in_p + off, 1, n, f) : 0;
  if (fclose(f) != 0 || w != n) return -EIO;
  return 0;
}

/* Entry names into out, each followed by NUL ("." and ".." skipped; order unspecified). */
EC_FN(int64_t, ec_list_dir, (void)) {
  out_len = 0;
  DIR *d = opendir(arg(0));
  if (!d) return fail();
  struct dirent *e;
  while ((e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    out_put(e->d_name, strlen(e->d_name) + 1);
  }
  closedir(d);
  return 0;
}

/* 0 missing, 1 file, 2 directory, 3 other, 4 symlink (only when follow == 0). */
EC_FN(int32_t, ec_kind, (int32_t follow)) {
  struct stat st;
  if ((follow ? stat(arg(0), &st) : lstat(arg(0), &st)) != 0) return 0;
  if (S_ISLNK(st.st_mode)) return 4;
  return S_ISREG(st.st_mode) ? 1 : S_ISDIR(st.st_mode) ? 2 : 3;
}

EC_FN(int64_t, ec_mkdir, (void)) { return mkdir(arg(0), 0777) == 0 ? 0 : fail(); }
/* Removes a file, a symlink (never its target) or an empty directory. */
EC_FN(int64_t, ec_remove, (void)) { return remove(arg(0)) == 0 ? 0 : fail(); }
/* in = from NUL to */
EC_FN(int64_t, ec_rename, (void)) { return rename(arg(0), arg(1)) == 0 ? 0 : fail(); }
/* in = target NUL linkpath */
EC_FN(int64_t, ec_symlink, (void)) { return symlink(arg(0), arg(1)) == 0 ? 0 : fail(); }

// ---- file descriptors (ABI.md "File descriptors")

/* Eider open flags (the same on every system) -> O_* flags. Always close-on-exec. */
#define EC_O_ACCESS 3
#define EC_O_CREATE 4
#define EC_O_EXCL 8
#define EC_O_TRUNC 16
#define EC_O_APPEND 32
#define EC_O_NONBLOCK 64
#define EC_O_DIRECTORY 128
#define EC_O_NOFOLLOW 256
#define EC_O_ALL 511

/* in[0] path. Returns the new descriptor. */
EC_FN(int64_t, ec_fd_open, (int32_t flags, int32_t mode)) {
  if (flags < 0 || (flags & ~EC_O_ALL) || (flags & EC_O_ACCESS) == 3) return -EINVAL;
  int acc = flags & EC_O_ACCESS;
  int f = (acc == 0 ? O_RDONLY : acc == 1 ? O_WRONLY : O_RDWR) | O_CLOEXEC;
  if (flags & EC_O_CREATE) f |= O_CREAT;
  if (flags & EC_O_EXCL) f |= O_EXCL;
  if (flags & EC_O_TRUNC) f |= O_TRUNC;
  if (flags & EC_O_APPEND) f |= O_APPEND;
  if (flags & EC_O_NONBLOCK) f |= O_NONBLOCK;
  if (flags & EC_O_DIRECTORY) f |= O_DIRECTORY;
  if (flags & EC_O_NOFOLLOW) f |= O_NOFOLLOW;
  int fd;
  do fd = open(arg(0), f, (mode_t)(mode & 07777)); while (fd < 0 && errno == EINTR);
  return fd < 0 ? fail() : fd;
}

/* close(2). EINTR counts as closed (on Linux and the BSDs the descriptor is gone). */
EC_FN(int64_t, ec_fd_close, (int32_t fd)) {
  if (close(fd) == 0 || errno == EINTR) return 0;
  return fail();
}

/* One write(2) of in: the count written (may be short). EINTR is retried. */
EC_FN(int64_t, ec_fd_write, (int32_t fd)) {
  const unsigned char *b = in_bytes();
  ssize_t w;
  do w = write(fd, b, in_len); while (w < 0 && errno == EINTR);
  return w < 0 ? fail() : (int64_t)w;
}

/* One pread(2) of up to max bytes (at most EC_READ_MAX) at offset off into out. */
EC_FN(int64_t, ec_fd_pread, (int32_t fd, int64_t max, int64_t off)) {
  out_len = 0;
  if (fd < 0 || max <= 0 || off < 0) return -EINVAL;
  size_t n = (size_t)(max < EC_READ_MAX ? max : EC_READ_MAX);
  reserve(&out_p, &out_cap, n + 1);
  ssize_t r;
  do r = pread(fd, out_p, n, (off_t)off); while (r < 0 && errno == EINTR);
  if (r < 0) {
    out_p[0] = 0;
    return fail();
  }
  out_len = (size_t)r;
  out_p[out_len] = 0;
  return (int64_t)r;
}

/* One pwrite(2) of in at offset off: the count written. */
EC_FN(int64_t, ec_fd_pwrite, (int32_t fd, int64_t off)) {
  if (off < 0) return -EINVAL;
  const unsigned char *b = in_bytes();
  ssize_t w;
  do w = pwrite(fd, b, in_len, (off_t)off); while (w < 0 && errno == EINTR);
  return w < 0 ? fail() : (int64_t)w;
}

/* lseek(2); whence 0 start, 1 current, 2 end. The new offset. */
EC_FN(int64_t, ec_fd_seek, (int32_t fd, int64_t off, int32_t whence)) {
  int w = whence == 0 ? SEEK_SET : whence == 1 ? SEEK_CUR : whence == 2 ? SEEK_END : -1;
  if (w < 0) return -EINVAL;
  off_t r = lseek(fd, (off_t)off, w);
  return r < 0 ? fail() : (int64_t)r;
}

/* Flush to stable storage: data_only != 0 is fdatasync (metadata only as needed to read the
   data back). On macOS both are fcntl(F_FULLFSYNC): its fsync does not reach the disk. */
EC_FN(int64_t, ec_fd_sync, (int32_t fd, int32_t data_only)) {
  int r;
#if defined(__APPLE__)
  (void)data_only;
  do r = fcntl(fd, F_FULLFSYNC); while (r < 0 && errno == EINTR);
#else
  do r = data_only ? fdatasync(fd) : fsync(fd); while (r < 0 && errno == EINTR);
#endif
  return r < 0 ? fail() : 0;
}

EC_FN(int64_t, ec_fd_truncate, (int32_t fd, int64_t len)) {
  if (len < 0) return -EINVAL;
  int r;
  do r = ftruncate(fd, (off_t)len); while (r < 0 && errno == EINTR);
  return r < 0 ? fail() : 0;
}

/* stat layout into out: size, kind, mode, mtime (ns since the epoch), 8 bytes LE each. */
static void stat_put(const struct stat *st) {
  int64_t kind = S_ISREG(st->st_mode) ? 1 : S_ISDIR(st->st_mode) ? 2 : S_ISLNK(st->st_mode) ? 4
               : S_ISFIFO(st->st_mode) ? 5 : S_ISSOCK(st->st_mode) ? 6 : S_ISCHR(st->st_mode) ? 7
               : S_ISBLK(st->st_mode) ? 8 : 3;
#if defined(__APPLE__)
  const struct timespec *m = &st->st_mtimespec;
#else
  const struct timespec *m = &st->st_mtim;
#endif
  out_len = 0;
  out_u64((uint64_t)(int64_t)st->st_size);
  out_u64((uint64_t)kind);
  out_u64((uint64_t)(st->st_mode & 07777));
  out_u64((uint64_t)((int64_t)m->tv_sec * 1000000000 + (int64_t)m->tv_nsec));
}

EC_FN(int64_t, ec_fd_stat, (int32_t fd)) {
  struct stat st;
  out_len = 0;
  if (fstat(fd, &st) != 0) return fail();
  stat_put(&st);
  return 0;
}

/* in[0] path; follow == 0 describes a final symlink itself (kind 4). */
EC_FN(int64_t, ec_stat, (int32_t follow)) {
  struct stat st;
  out_len = 0;
  if ((follow ? stat(arg(0), &st) : lstat(arg(0), &st)) != 0) return fail();
  stat_put(&st);
  return 0;
}

EC_FN(int64_t, ec_fd_chmod, (int32_t fd, int32_t mode)) {
  return fchmod(fd, (mode_t)(mode & 07777)) == 0 ? 0 : fail();
}

/* flock(2): op 0 unlock, 1 shared, 2 exclusive; +4 don't wait (-EWOULDBLOCK if held). */
EC_FN(int64_t, ec_fd_lock, (int32_t fd, int32_t op)) {
#if defined(EC_HAVE_FLOCK)
  int kind = op & 3, o = kind == 0 ? LOCK_UN : kind == 1 ? LOCK_SH : kind == 2 ? LOCK_EX : -1;
  if (o < 0 || op < 0 || op > 7) return -EINVAL;
  if (op & 4) o |= LOCK_NB;
  int r;
  do r = flock(fd, o); while (r < 0 && errno == EINTR);
  return r < 0 ? fail() : 0;
#else
  (void)fd;
  (void)op;
  return -ENOSYS;
#endif
}

/* O_NONBLOCK on (on != 0) or off. */
EC_FN(int64_t, ec_fd_nonblock, (int32_t fd, int32_t on)) {
  int fl = fcntl(fd, F_GETFL);
  if (fl < 0) return fail();
  fl = on ? fl | O_NONBLOCK : fl & ~O_NONBLOCK;
  return fcntl(fd, F_SETFL, fl) == 0 ? 0 : fail();
}

/* A close-on-exec duplicate (the lowest free descriptor). */
EC_FN(int64_t, ec_fd_dup, (int32_t fd)) {
  int r = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  return r < 0 ? fail() : r;
}

/* Two descriptors into out (4 bytes LE each). */
static void two_fds(int a, int b) {
  out_len = 0;
  out_u32((uint32_t)a);
  out_u32((uint32_t)b);
}

/* A close-on-exec pipe: out = read end, write end. */
EC_FN(int64_t, ec_pipe, (void)) {
  int p[2];
  out_len = 0;
  ignore_sigpipe_once();
  if (cloexec_pipe(p) != 0) return fail();
  two_fds(p[0], p[1]);
  return 0;
}

// ---- sockets (ABI.md "Sockets" and "Addresses")

#if defined(__APPLE__) || defined(EC_BSD)
#define EC_SA_LEN 1 /* sockaddrs carry their length */
#endif

/* An Eider address (bytes [0, n) of `a`) as a sockaddr; its length, or 0 if malformed. */
static socklen_t addr_get(const unsigned char *a, size_t n, struct sockaddr_storage *ss) {
  memset(ss, 0, sizeof *ss);
  if (n < 3) return 0;
  uint16_t port = (uint16_t)((a[1] << 8) | a[2]);
  if (a[0] == 4 && n == 7) {
    struct sockaddr_in *s = (struct sockaddr_in *)ss;
    s->sin_family = AF_INET;
    s->sin_port = htons(port);
    memcpy(&s->sin_addr, a + 3, 4);
#if defined(EC_SA_LEN)
    s->sin_len = sizeof *s;
#endif
    return sizeof *s;
  }
  if (a[0] == 6 && n == 23) {
    struct sockaddr_in6 *s = (struct sockaddr_in6 *)ss;
    s->sin6_family = AF_INET6;
    s->sin6_port = htons(port);
    memcpy(&s->sin6_addr, a + 3, 16);
    s->sin6_scope_id = (uint32_t)a[19] | (uint32_t)a[20] << 8 | (uint32_t)a[21] << 16 | (uint32_t)a[22] << 24;
#if defined(EC_SA_LEN)
    s->sin6_len = sizeof *s;
#endif
    return sizeof *s;
  }
  if (a[0] == 1) {
    struct sockaddr_un *s = (struct sockaddr_un *)ss;
    size_t plen = n - 3;
    if (plen >= sizeof s->sun_path) return 0;
    s->sun_family = AF_UNIX;
    memcpy(s->sun_path, a + 3, plen);
    /* a pathname gets its NUL; an abstract name (Linux, leading NUL) is exactly its bytes;
       an empty path is the unnamed address */
    size_t len = offsetof(struct sockaddr_un, sun_path) + plen + (plen > 0 && a[3] != 0 ? 1 : 0);
#if defined(EC_SA_LEN)
    s->sun_len = (unsigned char)len;
#endif
    return (socklen_t)len;
  }
  return 0;
}

/* A sockaddr as an Eider address, appended to out. */
static void addr_put(const struct sockaddr_storage *ss, socklen_t len) {
  unsigned char h[3] = {0, 0, 0};
  if (ss->ss_family == AF_INET && len >= (socklen_t)sizeof(struct sockaddr_in)) {
    const struct sockaddr_in *s = (const struct sockaddr_in *)ss;
    uint16_t port = ntohs(s->sin_port);
    h[0] = 4; h[1] = (unsigned char)(port >> 8); h[2] = (unsigned char)port;
    out_put(h, 3);
    out_put(&s->sin_addr, 4);
  } else if (ss->ss_family == AF_INET6 && len >= (socklen_t)sizeof(struct sockaddr_in6)) {
    const struct sockaddr_in6 *s = (const struct sockaddr_in6 *)ss;
    uint16_t port = ntohs(s->sin6_port);
    h[0] = 6; h[1] = (unsigned char)(port >> 8); h[2] = (unsigned char)port;
    out_put(h, 3);
    out_put(&s->sin6_addr, 16);
    out_u32(s->sin6_scope_id);
  } else if (ss->ss_family == AF_UNIX) {
    const struct sockaddr_un *s = (const struct sockaddr_un *)ss;
    size_t off = offsetof(struct sockaddr_un, sun_path), plen = 0;
    if ((size_t)len > off) plen = (size_t)len - off;
    if (plen > sizeof s->sun_path) plen = sizeof s->sun_path;
    if (plen > 0 && s->sun_path[0] != 0) plen = strnlen(s->sun_path, plen); /* pathname */
    h[0] = 1;
    out_put(h, 3);
    out_put(s->sun_path, plen);
  } else {
    out_put(h, 3); /* unknown family */
  }
}

static int set_cloexec_nonblock(int fd, int nonblock) {
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) return -1;
  if (nonblock) {
    int fl = fcntl(fd, F_GETFL);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) != 0) return -1;
  }
  return 0;
}

static void no_sigpipe(int fd) {
#if defined(SO_NOSIGPIPE)
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#else
  (void)fd;
#endif
}

#if defined(MSG_NOSIGNAL)
#define EC_MSG_NOSIGNAL MSG_NOSIGNAL
#else
#define EC_MSG_NOSIGNAL 0
#endif

static int sock_type(int32_t type) { return type == 1 ? SOCK_STREAM : type == 2 ? SOCK_DGRAM : -1; }

/* family 4 IPv4, 6 IPv6, 1 Unix; type 1 stream, 2 datagram. Close-on-exec, and
   non-blocking when nonblock != 0. */
EC_FN(int64_t, ec_sock_open, (int32_t family, int32_t type, int32_t nonblock)) {
  int dom = family == 4 ? AF_INET : family == 6 ? AF_INET6 : family == 1 ? AF_UNIX : -1;
  int ty = sock_type(type);
  if (dom < 0) return -EAFNOSUPPORT;
  if (ty < 0) return -EINVAL;
  ignore_sigpipe_once();
#if defined(SOCK_CLOEXEC) && defined(SOCK_NONBLOCK)
  int fd = socket(dom, ty | SOCK_CLOEXEC | (nonblock ? SOCK_NONBLOCK : 0), 0);
  if (fd < 0) return fail();
#else
  int fd = socket(dom, ty, 0);
  if (fd < 0) return fail();
  if (set_cloexec_nonblock(fd, nonblock) != 0) {
    int64_t r = fail();
    close(fd);
    return r;
  }
#endif
  no_sigpipe(fd);
  return fd;
}

/* A connected pair of Unix-domain sockets: out = two descriptors. */
EC_FN(int64_t, ec_sock_pair, (int32_t type)) {
  int ty = sock_type(type), p[2];
  out_len = 0;
  if (ty < 0) return -EINVAL;
  ignore_sigpipe_once();
#if defined(SOCK_CLOEXEC)
  if (socketpair(AF_UNIX, ty | SOCK_CLOEXEC, 0, p) != 0) return fail();
#else
  if (socketpair(AF_UNIX, ty, 0, p) != 0) return fail();
  if (set_cloexec_nonblock(p[0], 0) != 0 || set_cloexec_nonblock(p[1], 0) != 0) {
    int64_t r = fail();
    close(p[0]);
    close(p[1]);
    return r;
  }
#endif
  no_sigpipe(p[0]);
  no_sigpipe(p[1]);
  two_fds(p[0], p[1]);
  return 0;
}

/* in = address */
EC_FN(int64_t, ec_sock_bind, (int32_t fd)) {
  struct sockaddr_storage ss;
  socklen_t len = addr_get(in_bytes(), in_len, &ss);
  if (!len) return -EINVAL;
  return bind(fd, (struct sockaddr *)&ss, len) == 0 ? 0 : fail();
}

EC_FN(int64_t, ec_sock_listen, (int32_t fd, int32_t backlog)) {
  return listen(fd, backlog) == 0 ? 0 : fail();
}

/* The new connection's descriptor (close-on-exec, non-blocking if nonblock != 0); its peer
   address in out. EINTR is retried. */
EC_FN(int64_t, ec_sock_accept, (int32_t fd, int32_t nonblock)) {
  struct sockaddr_storage ss;
  socklen_t len;
  int c;
  out_len = 0;
  do {
    len = sizeof ss;
    memset(&ss, 0, sizeof ss);
#if defined(__linux__) || defined(EC_BSD)
    c = accept4(fd, (struct sockaddr *)&ss, &len, SOCK_CLOEXEC | (nonblock ? SOCK_NONBLOCK : 0));
#else
    c = accept(fd, (struct sockaddr *)&ss, &len);
#endif
  } while (c < 0 && errno == EINTR);
  if (c < 0) return fail();
#if !defined(__linux__) && !defined(EC_BSD)
  if (set_cloexec_nonblock(c, nonblock) != 0) {
    int64_t r = fail();
    close(c);
    return r;
  }
#endif
  no_sigpipe(c);
  addr_put(&ss, len);
  return c;
}

/* in = address. 0 when connected; -EINPROGRESS on a non-blocking socket (wait for
   writability, then ec_sock_error). A blocking connect interrupted by a signal is waited
   for here (it cannot be restarted). */
EC_FN(int64_t, ec_sock_connect, (int32_t fd)) {
  struct sockaddr_storage ss;
  socklen_t len = addr_get(in_bytes(), in_len, &ss);
  if (!len) return -EINVAL;
  if (connect(fd, (struct sockaddr *)&ss, len) == 0) return 0;
  if (errno != EINTR) return fail();
  struct pollfd pf = {fd, POLLOUT, 0};
  while (poll(&pf, 1, -1) < 0)
    if (errno != EINTR) return fail();
  int e = 0;
  socklen_t el = sizeof e;
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &el) != 0) return fail();
  return e ? -(int64_t)e : 0;
}

/* The socket's pending error (SO_ERROR, which clears it): 0 or -errno. How a non-blocking
   connect reports its outcome. */
EC_FN(int64_t, ec_sock_error, (int32_t fd)) {
  int e = 0;
  socklen_t el = sizeof e;
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &el) != 0) return fail();
  return e ? -(int64_t)e : 0;
}

/* how: 0 reading, 1 writing, 2 both */
EC_FN(int64_t, ec_sock_shutdown, (int32_t fd, int32_t how)) {
  int h = how == 0 ? SHUT_RD : how == 1 ? SHUT_WR : how == 2 ? SHUT_RDWR : -1;
  if (h < 0) return -EINVAL;
  return shutdown(fd, h) == 0 ? 0 : fail();
}

/* One send(2) of in (never raises SIGPIPE): the count sent. */
EC_FN(int64_t, ec_sock_send, (int32_t fd)) {
  const unsigned char *b = in_bytes();
  ssize_t w;
  do w = send(fd, b, in_len, EC_MSG_NOSIGNAL); while (w < 0 && errno == EINTR);
  return w < 0 ? fail() : (int64_t)w;
}

/* One recv(2) of up to max bytes (at most EC_READ_MAX) into out; peek != 0 leaves them
   queued. 0 at end of stream. */
EC_FN(int64_t, ec_sock_recv, (int32_t fd, int64_t max, int32_t peek)) {
  out_len = 0;
  if (fd < 0 || max <= 0) return -EINVAL;
  size_t n = (size_t)(max < EC_READ_MAX ? max : EC_READ_MAX);
  reserve(&out_p, &out_cap, n + 1);
  ssize_t r;
  do r = recv(fd, out_p, n, peek ? MSG_PEEK : 0); while (r < 0 && errno == EINTR);
  if (r < 0) {
    out_p[0] = 0;
    return fail();
  }
  out_len = (size_t)r;
  out_p[out_len] = 0;
  return (int64_t)r;
}

/* in = address (addr_len bytes) then the datagram. The count sent. */
EC_FN(int64_t, ec_sock_sendto, (int32_t fd, int32_t addr_len)) {
  if (addr_len < 0 || (size_t)addr_len > in_len) return -EINVAL;
  const unsigned char *b = in_bytes();
  struct sockaddr_storage ss;
  socklen_t len = addr_get(b, (size_t)addr_len, &ss);
  if (!len) return -EINVAL;
  ssize_t w;
  do w = sendto(fd, b + addr_len, in_len - (size_t)addr_len, EC_MSG_NOSIGNAL, (struct sockaddr *)&ss, len);
  while (w < 0 && errno == EINTR);
  return w < 0 ? fail() : (int64_t)w;
}

/* One recvfrom(2) of up to max bytes: the count; out = 1 byte A, the sender's address (A
   bytes), the data. A datagram longer than max is truncated (the rest is dropped). */
EC_FN(int64_t, ec_sock_recvfrom, (int32_t fd, int64_t max)) {
  out_len = 0;
  if (fd < 0 || max <= 0) return -EINVAL;
  size_t n = (size_t)(max < EC_READ_MAX ? max : EC_READ_MAX);
  unsigned char *buf = malloc(n);
  if (!buf) return -ENOMEM;
  struct sockaddr_storage ss;
  socklen_t len;
  ssize_t r;
  do {
    len = sizeof ss;
    memset(&ss, 0, sizeof ss);
    r = recvfrom(fd, buf, n, 0, (struct sockaddr *)&ss, &len);
  } while (r < 0 && errno == EINTR);
  if (r < 0) {
    int64_t e = fail();
    free(buf);
    return e;
  }
  out_put("", 1);
  addr_put(&ss, len);
  out_p[0] = (unsigned char)(out_len - 1);
  out_put(buf, (size_t)r);
  free(buf);
  return (int64_t)r;
}

/* getsockname (peer == 0) or getpeername: the address into out. */
EC_FN(int64_t, ec_sock_name, (int32_t fd, int32_t peer)) {
  struct sockaddr_storage ss;
  socklen_t len = sizeof ss;
  memset(&ss, 0, sizeof ss);
  out_len = 0;
  if ((peer ? getpeername(fd, (struct sockaddr *)&ss, &len) : getsockname(fd, (struct sockaddr *)&ss, &len)) != 0)
    return fail();
  addr_put(&ss, len);
  return 0;
}

/* Eider option numbers -> (level, name). 0 if the system lacks the option. */
static int sockopt(int32_t opt, int *level, int *name) {
  *level = SOL_SOCKET;
  switch (opt) {
  case 1: *name = SO_REUSEADDR; return 1;
#if defined(SO_REUSEPORT)
  case 2: *name = SO_REUSEPORT; return 1;
#endif
  case 3: *level = IPPROTO_TCP; *name = TCP_NODELAY; return 1;
  case 4: *name = SO_KEEPALIVE; return 1;
  case 5: *name = SO_RCVBUF; return 1;
  case 6: *name = SO_SNDBUF; return 1;
  case 7: *level = IPPROTO_IPV6; *name = IPV6_V6ONLY; return 1;
  case 8: *name = SO_BROADCAST; return 1;
  case 9: *name = SO_RCVTIMEO; return 1;
  case 10: *name = SO_SNDTIMEO; return 1;
  default: return 0;
  }
}

/* Set option opt (ABI.md table) to value; 9/10 (timeouts) take milliseconds, 0 = none. */
EC_FN(int64_t, ec_sock_setopt, (int32_t fd, int32_t opt, int64_t value)) {
  int level, name;
  if (!sockopt(opt, &level, &name)) return opt == 2 ? -ENOPROTOOPT : -EINVAL;
  if (opt == 9 || opt == 10) {
    if (value < 0) return -EINVAL;
    struct timeval tv;
    tv.tv_sec = (time_t)(value / 1000);
    tv.tv_usec = (suseconds_t)((value % 1000) * 1000);
    return setsockopt(fd, level, name, &tv, sizeof tv) == 0 ? 0 : fail();
  }
  if (value < INT_MIN || value > INT_MAX) return -EINVAL;
  int v = (int)value;
  return setsockopt(fd, level, name, &v, sizeof v) == 0 ? 0 : fail();
}

/* The option's value (booleans 0/1 as the system reports them, sizes in bytes, timeouts in
   ms). */
EC_FN(int64_t, ec_sock_getopt, (int32_t fd, int32_t opt)) {
  int level, name;
  if (!sockopt(opt, &level, &name)) return opt == 2 ? -ENOPROTOOPT : -EINVAL;
  if (opt == 9 || opt == 10) {
    struct timeval tv;
    socklen_t l = sizeof tv;
    if (getsockopt(fd, level, name, &tv, &l) != 0) return fail();
    return (int64_t)tv.tv_sec * 1000 + (int64_t)tv.tv_usec / 1000;
  }
  int v = 0;
  socklen_t l = sizeof v;
  if (getsockopt(fd, level, name, &v, &l) != 0) return fail();
  return v;
}

// ---- DNS (ABI.md "Name resolution")

/* Resolver failures are -(EC_EAI_BASE + k), k indexing this table (0 unused). */
#define EC_EAI_BASE 1000000
static const int eai_codes[] = {0, EAI_NONAME, EAI_AGAIN, EAI_FAIL, EAI_FAMILY, EAI_SOCKTYPE,
                                EAI_SERVICE, EAI_MEMORY, EAI_BADFLAGS, EAI_OVERFLOW};
#define EAI_COUNT (sizeof eai_codes / sizeof eai_codes[0])

static const char *resolver_text(int64_t e) {
  int64_t k = -e - EC_EAI_BASE;
  return k >= 1 && k < (int64_t)EAI_COUNT ? gai_strerror(eai_codes[k]) : "unknown error";
}

static int64_t eai_status(int e) {
  if (e == EAI_SYSTEM) return fail();
#if defined(EAI_NODATA) && EAI_NODATA != EAI_NONAME
  if (e == EAI_NODATA) e = EAI_NONAME;
#endif
#if defined(EAI_ADDRFAMILY) && EAI_ADDRFAMILY != EAI_NONAME
  if (e == EAI_ADDRFAMILY) e = EAI_NONAME;
#endif
  for (size_t k = 1; k < EAI_COUNT; k++)
    if (eai_codes[k] == e) return -(int64_t)(EC_EAI_BASE + k);
  return -(int64_t)(EC_EAI_BASE + 3); /* EAI_FAIL */
}

/* in = host NUL service (either may be empty). family 0 any, 4, 6; socktype 0 any, 1 stream,
   2 datagram; flags 1 passive, 2 numeric host only, 4 address-config. The number of results;
   out = per result: 1 byte socktype (1/2/0 other), 1 byte A, the address (A bytes). */
EC_FN(int64_t, ec_dns_lookup, (int32_t family, int32_t socktype, int32_t flags)) {
  struct addrinfo hints, *res = NULL;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = family == 0 ? AF_UNSPEC : family == 4 ? AF_INET : family == 6 ? AF_INET6 : -1;
  hints.ai_socktype = socktype == 0 ? 0 : sock_type(socktype);
  if (hints.ai_family == -1 || hints.ai_socktype < 0 || flags < 0 || flags > 7) return -EINVAL;
  if (flags & 1) hints.ai_flags |= AI_PASSIVE;
  if (flags & 2) hints.ai_flags |= AI_NUMERICHOST;
  if (flags & 4) hints.ai_flags |= AI_ADDRCONFIG;
  const char *host = arg(0), *serv = arg(1);
  if (host && !*host) host = NULL;
  if (serv && !*serv) serv = NULL;
  out_len = 0;
  int e = getaddrinfo(host, serv, &hints, &res);
  if (e != 0) return eai_status(e);
  int64_t count = 0;
  for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
    if (ai->ai_family != AF_INET && ai->ai_family != AF_INET6) continue;
    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof ss);
    size_t l = (size_t)ai->ai_addrlen < sizeof ss ? (size_t)ai->ai_addrlen : sizeof ss;
    memcpy(&ss, ai->ai_addr, l);
    unsigned char h[2] = {(unsigned char)(ai->ai_socktype == SOCK_STREAM ? 1 : ai->ai_socktype == SOCK_DGRAM ? 2 : 0), 0};
    size_t at = out_len;
    out_put(h, 2);
    addr_put(&ss, (socklen_t)l);
    out_p[at + 1] = (unsigned char)(out_len - at - 2);
    count++;
  }
  freeaddrinfo(res);
  return count;
}

/* in = address. flags 1 numeric host, 2 numeric service, 4 name required, 8 datagram
   service. out = host NUL service. */
EC_FN(int64_t, ec_dns_reverse, (int32_t flags)) {
  struct sockaddr_storage ss;
  socklen_t len = addr_get(in_bytes(), in_len, &ss);
  out_len = 0;
  if (!len || flags < 0 || flags > 15) return -EINVAL;
  int f = 0;
  if (flags & 1) f |= NI_NUMERICHOST;
  if (flags & 2) f |= NI_NUMERICSERV;
  if (flags & 4) f |= NI_NAMEREQD;
  if (flags & 8) f |= NI_DGRAM;
  char host[1025], serv[32];
  int e = getnameinfo((struct sockaddr *)&ss, len, host, sizeof host, serv, sizeof serv, f);
  if (e != 0) return eai_status(e);
  out_put(host, strlen(host) + 1);
  out_put(serv, strlen(serv));
  return 0;
}

// ---- readiness (ABI.md "Readiness")

#define EC_POLL_MAX 1024

#if defined(EC_EPOLL) || defined(EC_KQUEUE)
/* One event record into out: token (8 bytes LE), flags (4), 4 zero bytes. */
static void event_put(uint64_t token, uint32_t flags) {
  out_u64(token);
  out_u32(flags);
  out_u32(0);
}
#endif

#if defined(EC_KQUEUE)
#if defined(__NetBSD__) && defined(__NetBSD_Version__) && __NetBSD_Version__ < 1000000000
#define EC_UDATA(t) ((intptr_t)(t))
#else
#define EC_UDATA(t) ((void *)(uintptr_t)(t))
#endif
#if defined(EV_DISPATCH)
#define EC_EV_ONESHOT EV_DISPATCH /* like EPOLLONESHOT: disabled, not deleted, after one event */
#else
#define EC_EV_ONESHOT EV_ONESHOT
#endif
#endif

/* A new poller (epoll or kqueue descriptor, close-on-exec). */
EC_FN(int64_t, ec_poll_new, (void)) {
#if defined(EC_EPOLL)
  int fd = epoll_create1(EPOLL_CLOEXEC);
  return fd < 0 ? fail() : fd;
#elif defined(EC_KQUEUE)
  int fd = kqueue();
  if (fd < 0) return fail();
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
    int64_t r = fail();
    close(fd);
    return r;
  }
  return fd;
#else
  return -ENOSYS;
#endif
}

/* op 0 add, 1 modify, 2 remove fd. interest: 1 readable, 2 writable, 4 edge-triggered,
   8 one-shot (disarmed after one event until modified). token comes back with its events. */
EC_FN(int64_t, ec_poll_ctl, (int32_t pfd, int32_t op, int32_t fd, int32_t interest, int64_t token)) {
  if (op < 0 || op > 2 || interest < 0 || interest > 15) return -EINVAL;
#if defined(EC_EPOLL)
  struct epoll_event ev;
  memset(&ev, 0, sizeof ev);
  if (interest & 1) ev.events |= EPOLLIN | EPOLLRDHUP;
  if (interest & 2) ev.events |= EPOLLOUT;
  if (interest & 4) ev.events |= EPOLLET;
  if (interest & 8) ev.events |= EPOLLONESHOT;
  ev.data.u64 = (uint64_t)token;
  int o = op == 0 ? EPOLL_CTL_ADD : op == 1 ? EPOLL_CTL_MOD : EPOLL_CTL_DEL;
  return epoll_ctl(pfd, o, fd, &ev) == 0 ? 0 : fail();
#elif defined(EC_KQUEUE)
  /* one filter per direction: added when wanted, deleted (if present) otherwise */
  struct kevent ch[2], res[2];
  unsigned short add = (unsigned short)(EV_ADD | EV_ENABLE | EV_RECEIPT | (interest & 4 ? EV_CLEAR : 0) |
                                        (interest & 8 ? EC_EV_ONESHOT : 0));
  const short filt[2] = {EVFILT_READ, EVFILT_WRITE};
  for (int i = 0; i < 2; i++) {
    int want = op != 2 && (interest & (1 << i));
    EV_SET(&ch[i], (uintptr_t)fd, filt[i], want ? add : (unsigned short)(EV_DELETE | EV_RECEIPT), 0, 0, EC_UDATA(token));
  }
  int n = kevent(pfd, ch, 2, res, 2, NULL);
  if (n < 0) return fail();
  for (int i = 0; i < n; i++) {
    if (!(res[i].flags & EV_ERROR) || res[i].data == 0) continue;
    int bit = res[i].filter == EVFILT_READ ? 1 : 2;
    int deleting = op == 2 || !(interest & bit);
    if (deleting && res[i].data == ENOENT) continue; /* a filter that wasn't there */
    return -(int64_t)res[i].data;
  }
  return 0;
#else
  (void)pfd; (void)fd; (void)token;
  return -ENOSYS;
#endif
}

/* Wait up to timeout_ms (< 0 forever, 0 don't wait) for at most max events: their number;
   out = that many 16-byte records (event_put). flags: 1 readable, 2 writable, 4 error,
   8 hang-up, 16 the peer finished sending. A signal ends the wait early: what is ready then
   (the signal pipe, if the signal is watched) is collected without waiting again. */
EC_FN(int64_t, ec_poll_wait, (int32_t pfd, int32_t max, int64_t timeout_ms)) {
  out_len = 0;
  if (max <= 0) return -EINVAL;
  int m = max < EC_POLL_MAX ? max : EC_POLL_MAX;
  int64_t t = timeout_ms < 0 ? -1 : timeout_ms > INT_MAX ? INT_MAX : timeout_ms;
#if defined(EC_EPOLL)
  struct epoll_event *ev = malloc((size_t)m * sizeof *ev);
  if (!ev) return -ENOMEM;
  int n = epoll_wait(pfd, ev, m, (int)t);
  if (n < 0 && errno == EINTR) n = epoll_wait(pfd, ev, m, 0); /* collect, don't wait again */
  if (n < 0) {
    int64_t r = errno == EINTR ? 0 : fail();
    free(ev);
    return r;
  }
  for (int i = 0; i < n; i++) {
    uint32_t e = ev[i].events, f = 0;
    if (e & EPOLLIN) f |= 1;
    if (e & EPOLLOUT) f |= 2;
    if (e & EPOLLERR) f |= 4;
    if (e & EPOLLHUP) f |= 8;
    if (e & EPOLLRDHUP) f |= 16;
    event_put(ev[i].data.u64, f);
  }
  free(ev);
  return n;
#elif defined(EC_KQUEUE)
  struct kevent *ev = malloc((size_t)m * sizeof *ev);
  if (!ev) return -ENOMEM;
  struct timespec ts = {(time_t)(t / 1000), (long)((t % 1000) * 1000000)};
  int n = kevent(pfd, NULL, 0, ev, m, t < 0 ? NULL : &ts);
  if (n < 0 && errno == EINTR) {
    struct timespec zero = {0, 0};
    n = kevent(pfd, NULL, 0, ev, m, &zero); /* collect, don't wait again */
  }
  if (n < 0) {
    int64_t r = errno == EINTR ? 0 : fail();
    free(ev);
    return r;
  }
  for (int i = 0; i < n; i++) {
    uint32_t f = 0;
    int eof = (ev[i].flags & EV_EOF) != 0;
    if (ev[i].filter == EVFILT_READ) f |= eof ? 1u | 16u : 1u;
    if (ev[i].filter == EVFILT_WRITE) f |= eof ? 2u | 8u : 2u;
    if (eof && ev[i].fflags != 0) f |= 4u; /* fflags: the socket error */
    if (ev[i].flags & EV_ERROR) f |= 4u;
    event_put((uint64_t)(uintptr_t)ev[i].udata, f);
  }
  free(ev);
  return n;
#else
  (void)pfd;
  (void)m;
  (void)t;
  return -ENOSYS;
#endif
}

/* A cross-thread wakeup: out = read end, write end (one eventfd on Linux, so both are the
   same descriptor; a pipe elsewhere). Both non-blocking and close-on-exec. Register the read
   end with a poller; ec_waker_wake makes it readable; drain it with ec_read_fd. */
EC_FN(int64_t, ec_waker_new, (void)) {
  out_len = 0;
#if defined(__linux__)
  int fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (fd < 0) return fail();
  two_fds(fd, fd);
#else
  int p[2];
  if (cloexec_pipe(p) != 0) return fail();
  if (set_cloexec_nonblock(p[0], 1) != 0 || set_cloexec_nonblock(p[1], 1) != 0) {
    int64_t r = fail();
    close(p[0]);
    close(p[1]);
    return r;
  }
  two_fds(p[0], p[1]);
#endif
  return 0;
}

/* Make the waker readable. Async-signal-safe; a wake already pending is not an error. */
EC_FN(int64_t, ec_waker_wake, (int32_t wfd)) {
#if defined(__linux__)
  uint64_t one = 1;
  ssize_t w;
  do w = write(wfd, &one, sizeof one); while (w < 0 && errno == EINTR);
#else
  unsigned char one = 1;
  ssize_t w;
  do w = write(wfd, &one, 1); while (w < 0 && errno == EINTR);
#endif
  if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK) return fail();
  return 0;
}

/* Milliseconds on the monotonic clock (for ec_fd_wait's deadline). */
static int64_t mono_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return 0;
  return (int64_t)t.tv_sec * 1000 + (int64_t)t.tv_nsec / 1000000;
}

/* One descriptor's readiness: poll(2) on fd for interest (1 readable, 2 writable), waiting at
   most timeout_ms (< 0 forever, 0 not at all). The flags that are set (1 readable,
   2 writable, 4 error, 8 hang-up), or 0 when the time ran out. A signal doesn't end the
   wait: it is resumed with the time that is left. */
EC_FN(int64_t, ec_fd_wait, (int32_t fd, int32_t interest, int64_t timeout_ms)) {
  if ((interest & 3) == 0 || (interest & ~3) != 0) return -EINVAL;
  struct pollfd p;
  p.fd = fd;
  p.events = (short)(((interest & 1) ? POLLIN : 0) | ((interest & 2) ? POLLOUT : 0));
  int64_t end = timeout_ms > 0 ? mono_ms() + timeout_ms : 0;
  for (;;) {
    int64_t left = timeout_ms < 0 ? -1 : timeout_ms == 0 ? 0 : end - mono_ms();
    if (timeout_ms > 0 && left < 0) left = 0;
    int t = left > INT_MAX ? INT_MAX : (int)left;
    p.revents = 0;
    int n = poll(&p, 1, t);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) return fail();
    if (n == 0) {
      if (left > INT_MAX) continue; /* only the first INT_MAX ms of a longer wait */
      return 0;
    }
    if (p.revents & POLLNVAL) return -EBADF;
    int64_t f = 0;
    if (p.revents & POLLIN) f |= 1;
    if (p.revents & POLLOUT) f |= 2;
    if (p.revents & POLLERR) f |= 4;
    if (p.revents & POLLHUP) f |= 8;
    return f;
  }
}

// ---- time (ABI.md "Time")

/* Nanoseconds on a clock that never goes backwards or jumps (not counting suspend), from an
   arbitrary start. */
EC_FN(int64_t, ec_time_mono_ns, (void)) {
  struct timespec t;
#if defined(__APPLE__) && defined(CLOCK_UPTIME_RAW)
  if (clock_gettime(CLOCK_UPTIME_RAW, &t) != 0) return fail();
#else
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return fail();
#endif
  return (int64_t)t.tv_sec * 1000000000 + (int64_t)t.tv_nsec;
}

/* Nanoseconds since 1970-01-01 UTC (CLOCK_REALTIME; it can jump). */
EC_FN(int64_t, ec_time_wall_ns, (void)) {
  struct timespec t;
  if (clock_gettime(CLOCK_REALTIME, &t) != 0) return fail();
  return (int64_t)t.tv_sec * 1000000000 + (int64_t)t.tv_nsec;
}

/* Sleep at least ns nanoseconds; a signal doesn't cut it short. */
EC_FN(int64_t, ec_sleep_ns, (int64_t ns)) {
  if (ns <= 0) return 0;
  struct timespec t = {(time_t)(ns / 1000000000), (long)(ns % 1000000000)}, rem;
  while (nanosleep(&t, &rem) != 0) {
    if (errno != EINTR) return fail();
    t = rem;
  }
  return 0;
}

// ---- signals (ABI.md "Signals")

static void make_sig_pipe(void) {
  int p[2];
  if (cloexec_pipe(p) != 0 || set_cloexec_nonblock(p[0], 1) != 0 || set_cloexec_nonblock(p[1], 1) != 0) {
    sig_pipe_err = errno ? errno : EIO;
    return;
  }
  sig_pipe[0] = p[0];
  sig_pipe[1] = p[1];
}

/* The read end of the process's signal pipe (created on first use; the same descriptor every
   time; never close it). Each delivery of a signal set to 2 by ec_signal_set is one byte,
   its Eider number. Non-blocking. */
EC_FN(int64_t, ec_signal_fd, (void)) {
  pthread_once(&sig_pipe_once, make_sig_pipe);
  return sig_pipe[0] >= 0 ? sig_pipe[0] : -(int64_t)sig_pipe_err;
}

/* how: 0 default action, 1 ignore, 2 deliver to the signal pipe (SA_RESTART). */
EC_FN(int64_t, ec_signal_set, (int32_t sig, int32_t how)) {
  int n = sig_native(sig);
  if (n <= 0 || how < 0 || how > 2) return -EINVAL;
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sigemptyset(&sa.sa_mask);
  if (how == 2) {
    int64_t p = ec_signal_fd();
    if (p < 0) return p;
    sa.sa_handler = on_signal;
    sa.sa_flags = SA_RESTART | (n == SIGCHLD ? SA_NOCLDSTOP : 0);
  } else {
    sa.sa_handler = how == 0 ? SIG_DFL : SIG_IGN;
  }
  return sigaction(n, &sa, NULL) == 0 ? 0 : fail();
}

/* Block (block != 0) or unblock sig in the calling thread's mask. */
EC_FN(int64_t, ec_signal_mask, (int32_t sig, int32_t block)) {
  int n = sig_native(sig);
  if (n <= 0) return -EINVAL;
  sigset_t s;
  sigemptyset(&s);
  sigaddset(&s, n);
  int e = pthread_sigmask(block ? SIG_BLOCK : SIG_UNBLOCK, &s, NULL);
  return e ? -(int64_t)e : 0;
}

// ---- randomness (ABI.md "Randomness")

/* n bytes (at most EC_READ_MAX) from the OS's CSPRNG into out. Linux: getrandom, which
   waits until the kernel pool is first seeded, or with nonblock != 0 returns -EAGAIN then.
   macOS and the BSDs: arc4random_buf (never fails, never blocks). */
EC_FN(int64_t, ec_random, (int64_t n, int32_t nonblock)) {
  out_len = 0;
  if (n < 0 || n > EC_READ_MAX) return -EINVAL;
  reserve(&out_p, &out_cap, (size_t)n + 1);
#if defined(__linux__)
  size_t got = 0;
  while (got < (size_t)n) {
    ssize_t r = getrandom(out_p + got, (size_t)n - got, nonblock ? GRND_NONBLOCK : 0);
    if (r < 0) {
      if (errno == EINTR) continue;
      return fail();
    }
    got += (size_t)r;
  }
#elif defined(__APPLE__) || defined(EC_BSD)
  (void)nonblock;
  arc4random_buf(out_p, (size_t)n);
#else
  (void)nonblock;
  return -ENOSYS; /* never a time-based fallback */
#endif
  out_len = (size_t)n;
  out_p[out_len] = 0;
  return n;
}

// ---- processes (ABI.md "Processes")

/* Start in = argv (searched on PATH). in_mode/out_mode/err_mode for the child's 0/1/2:
   0 inherit, 1 /dev/null, 2 a pipe. Returns the pid; out = our ends of the three pipes (4
   bytes LE each, -1 where not a pipe), close-on-exec and blocking. */
EC_FN(int64_t, ec_spawn, (int32_t in_mode, int32_t out_mode, int32_t err_mode)) {
  int32_t mode[3] = {in_mode, out_mode, err_mode};
  out_len = 0;
  if (in_len == 0) return -EINVAL;
  for (int k = 0; k < 3; k++)
    if (mode[k] < 0 || mode[k] > 2) return -EINVAL;
  int argc = 0;
  while (arg(argc)) argc++;
  char **argv = calloc((size_t)argc + 1, sizeof *argv);
  if (!argv) return -ENOMEM;
  for (int k = 0; k < argc; k++) argv[k] = (char *)arg(k);
  int p[3][2] = {{-1, -1}, {-1, -1}, {-1, -1}}, xp[2] = {-1, -1}, nul = -1;
  int64_t err = 0;
  if (in_mode == 2) ignore_sigpipe_once();
  for (int k = 0; k < 3 && !err; k++)
    if (mode[k] == 2 && cloexec_pipe(p[k]) != 0) err = fail();
  if (!err && (in_mode == 1 || out_mode == 1 || err_mode == 1)) {
    nul = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (nul < 0) err = fail();
  }
  if (!err && cloexec_pipe(xp) != 0) err = fail();
  pid_t pid = -1;
  if (!err) {
    fflush(stdout);
    fflush(stderr);
    sigset_t oldmask;
    block_signals(&oldmask);
    pid = fork();
    if (pid != 0) restore_signals(&oldmask);
    if (pid < 0) err = fail();
  }
  if (pid == 0) {
    /* only async-signal-safe calls until exec; every source lifted above 0..2 first, so no
       dup2 overwrites one still needed */
    child_reset_signals();
    int x = above_stdio(xp[1]);
    int src[3];
    for (int k = 0; k < 3; k++)
      src[k] = above_stdio(mode[k] == 2 ? p[k][k == 0 ? 0 : 1] : mode[k] == 1 ? nul : -1);
    if (x < 0) _exit(127);
    for (int k = 0; k < 3; k++) {
      if (mode[k] == 0) continue;
      if (src[k] < 0 || dup2(src[k], k) < 0) {
        int en = errno;
        (void)!write(x, &en, sizeof en);
        _exit(127);
      }
    }
    execvp(argv[0], argv);
    int en = errno;
    (void)!write(x, &en, sizeof en);
    _exit(127);
  }
  free(argv);
  close_fd(&nul);
  close_fd(&xp[1]);
  close_fd(&p[0][0]);
  close_fd(&p[1][1]);
  close_fd(&p[2][1]);
  if (!err) {
    int xe = 0;
    ssize_t got;
    do got = read(xp[0], &xe, sizeof xe); while (got < 0 && errno == EINTR);
    if (got == (ssize_t)sizeof xe) { /* exec failed; the child has exited */
      int st;
      while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
      err = xe > 0 ? -(int64_t)xe : -EIO;
    }
  }
  close_fd(&xp[0]);
  if (err) {
    close_fd(&p[0][1]);
    close_fd(&p[1][0]);
    close_fd(&p[2][0]);
    return err;
  }
  out_u32((uint32_t)p[0][1]);
  out_u32((uint32_t)p[1][0]);
  out_u32((uint32_t)p[2][0]);
  return pid;
}

/* waitpid(pid) (pid -1: any child). 0..255 exit code, 256 + Eider signal number if a signal
   killed it, -EAGAIN if nohang != 0 and it is still running. out = the reaped pid (4 bytes
   LE). EINTR is retried. */
EC_FN(int64_t, ec_wait, (int32_t pid, int32_t nohang)) {
  int st = 0;
  pid_t r;
  out_len = 0;
  do r = waitpid((pid_t)pid, &st, nohang ? WNOHANG : 0); while (r < 0 && errno == EINTR);
  if (r < 0) return fail();
  if (r == 0) return -EAGAIN;
  out_u32((uint32_t)r);
  if (WIFEXITED(st)) return WEXITSTATUS(st);
  return 256 + sig_portable(WTERMSIG(st));
}

/* kill(2) with an Eider signal number (0: only check that pid exists). */
EC_FN(int64_t, ec_kill, (int32_t pid, int32_t sig)) {
  int n = sig_native(sig);
  if (n < 0) return -EINVAL;
  return kill((pid_t)pid, n) == 0 ? 0 : fail();
}

EC_FN(int64_t, ec_getpid, (void)) { return (int64_t)getpid(); }

// ---- atomic cells (ABI.md "Atomic cells")
//
// A cell is a 64-bit integer that every thread may read and change with atomic operations.
// Eider holds it by a handle, never a pointer: (generation << 32) | index, always > 0. Cells
// live in chunks that are allocated once and never freed or moved, so an operation on any
// handle touches valid memory; a handle whose generation doesn't match its cell (freed, or
// never made) ends the process with a runtime error rather than reading another cell.
// The generation is odd while the cell is in use and even while it is free; a slot whose
// generation would no longer fit 31 bits is retired instead of reused.

#define EC_CELL_CHUNK 4096
#define EC_CELL_CHUNKS 4096 /* at most 16M cells at once */

typedef struct {
  _Atomic(int64_t) v;
  _Atomic(uint32_t) gen;
  uint32_t next_free; /* under cell_mu, while free */
} ec_cell;

static ec_cell *_Atomic cell_chunks[EC_CELL_CHUNKS];
static pthread_mutex_t cell_mu = PTHREAD_MUTEX_INITIALIZER;
static uint32_t cell_used;           /* slots handed out so far (under cell_mu) */
static uint32_t cell_free = UINT32_MAX; /* free list head (under cell_mu) */

static memory_order cell_mo_rmw(int32_t o) {
  return o == 0 ? memory_order_relaxed : o == 1 ? memory_order_acquire : o == 2 ? memory_order_release
       : o == 3 ? memory_order_acq_rel : memory_order_seq_cst;
}
static memory_order cell_mo_load(int32_t o) {
  return o == 0 ? memory_order_relaxed : o == 1 ? memory_order_acquire : memory_order_seq_cst;
}
static memory_order cell_mo_store(int32_t o) {
  return o == 0 ? memory_order_relaxed : o == 2 ? memory_order_release : memory_order_seq_cst;
}
static memory_order cell_mo_fail(int32_t o) {
  return o == 0 || o == 2 ? memory_order_relaxed : o == 1 || o == 3 ? memory_order_acquire : memory_order_seq_cst;
}

static ec_cell *cell_slot(uint32_t i) {
  ec_cell *c = atomic_load_explicit(&cell_chunks[i / EC_CELL_CHUNK], memory_order_acquire);
  return c ? &c[i % EC_CELL_CHUNK] : NULL;
}

/* The cell of handle h, or the end of the process. */
static ec_cell *cell_of(int64_t h) {
  ec_cell *c = NULL;
  if (h > 0) {
    uint32_t i = (uint32_t)(h & 0xffffffff), g = (uint32_t)(h >> 32);
    if (i / EC_CELL_CHUNK < EC_CELL_CHUNKS) c = cell_slot(i);
    if (c && atomic_load_explicit(&c->gen, memory_order_acquire) != g) c = NULL;
  }
  if (!c) {
    fflush(stdout);
    fputs("eider: runtime error: invalid atomic handle (freed, or not made by atomic.new)\n", stderr);
    exit(101);
  }
  return c;
}

/* A new cell holding v: its handle (> 0), or -ENOMEM. */
EC_FN(int64_t, ec_atomic_new, (int64_t v)) {
  pthread_mutex_lock(&cell_mu);
  uint32_t i;
  ec_cell *c;
  if (cell_free != UINT32_MAX) {
    i = cell_free;
    c = cell_slot(i);
    cell_free = c->next_free;
  } else {
    if (cell_used == (uint32_t)EC_CELL_CHUNK * EC_CELL_CHUNKS) {
      pthread_mutex_unlock(&cell_mu);
      return -ENOMEM;
    }
    i = cell_used;
    c = cell_slot(i);
    if (!c) {
      ec_cell *chunk = calloc(EC_CELL_CHUNK, sizeof *chunk);
      if (!chunk) {
        pthread_mutex_unlock(&cell_mu);
        return -ENOMEM;
      }
      for (uint32_t k = 0; k < EC_CELL_CHUNK; k++) {
        atomic_init(&chunk[k].v, 0);
        atomic_init(&chunk[k].gen, 0);
      }
      atomic_store_explicit(&cell_chunks[i / EC_CELL_CHUNK], chunk, memory_order_release);
      c = &chunk[i % EC_CELL_CHUNK];
    }
    cell_used++;
  }
  atomic_store_explicit(&c->v, v, memory_order_relaxed);
  uint32_t g = atomic_load_explicit(&c->gen, memory_order_relaxed) + 1; /* even -> odd: in use */
  atomic_store_explicit(&c->gen, g, memory_order_release);
  pthread_mutex_unlock(&cell_mu);
  return (int64_t)((uint64_t)g << 32 | i);
}

/* Frees the cell of h: 0, or -EINVAL if h is not a cell in use (nothing changes). */
EC_FN(int64_t, ec_atomic_free, (int64_t h)) {
  if (h <= 0) return -EINVAL;
  uint32_t i = (uint32_t)(h & 0xffffffff), g = (uint32_t)(h >> 32);
  if (i / EC_CELL_CHUNK >= EC_CELL_CHUNKS) return -EINVAL;
  pthread_mutex_lock(&cell_mu);
  ec_cell *c = i < cell_used ? cell_slot(i) : NULL;
  if (!c || atomic_load_explicit(&c->gen, memory_order_relaxed) != g) {
    pthread_mutex_unlock(&cell_mu);
    return -EINVAL;
  }
  atomic_store_explicit(&c->gen, g + 1, memory_order_release); /* odd -> even: free */
  if (g + 1 < 0x7ffffffe) {                                   /* else retired */
    c->next_free = cell_free;
    cell_free = i;
  }
  pthread_mutex_unlock(&cell_mu);
  return 0;
}

/* order (here and below): 0 relaxed, 1 acquire, 2 release, 3 acquire-release, 4 sequentially
   consistent; one that doesn't apply to the operation, or an unknown number, is sequentially
   consistent. */
EC_FN(int64_t, ec_atomic_load, (int64_t h, int32_t order)) {
  return atomic_load_explicit(&cell_of(h)->v, cell_mo_load(order));
}

EC_FN(int64_t, ec_atomic_store, (int64_t h, int64_t v, int32_t order)) {
  atomic_store_explicit(&cell_of(h)->v, v, cell_mo_store(order));
  return 0;
}

/* The previous value; the cell becomes v. */
EC_FN(int64_t, ec_atomic_swap, (int64_t h, int64_t v, int32_t order)) {
  return atomic_exchange_explicit(&cell_of(h)->v, v, cell_mo_rmw(order));
}

/* The previous value; the cell becomes previous + n, wrapping (two's complement). */
EC_FN(int64_t, ec_atomic_add, (int64_t h, int64_t n, int32_t order)) {
  return atomic_fetch_add_explicit(&cell_of(h)->v, n, cell_mo_rmw(order));
}

/* If the cell holds expected it becomes desired. The value it held (== expected: done). */
EC_FN(int64_t, ec_atomic_cas, (int64_t h, int64_t expected, int64_t desired, int32_t order)) {
  int64_t e = expected;
  atomic_compare_exchange_strong_explicit(&cell_of(h)->v, &e, desired, cell_mo_rmw(order), cell_mo_fail(order));
  return e;
}

/* ---- profiling control (core/ABI.md "Profiling"). A program built with `--profile` links the
   runtime's profiler (core/eider_prof.c), which registers itself here when it starts; any
   other program has no profiler, and every call answers -ENOSYS. The core does no profiling
   itself: it forwards the call and the input buffer (a path, a label's key and value). */
typedef int64_t (*ec_prof_fn)(int32_t op, int64_t arg, const unsigned char *in, size_t len);
_Atomic(ec_prof_fn) ec_prof_hook;

EC_FN(int64_t, ec_prof, (int32_t op, int64_t arg)) {
  ec_prof_fn h = atomic_load(&ec_prof_hook);
  if (!h) return -ENOSYS;
  reserve(&in_p, &in_cap, 1);
  in_p[in_len] = 0;
  return h(op, arg, in_p, in_len);
}
