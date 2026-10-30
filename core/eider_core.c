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

#if defined(__linux__)
#define _GNU_SOURCE 1 /* pipe2 (close-on-exec pipes without a fork race) */
#endif
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700 /* realpath (XSI) */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif

#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
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

/* The text for status -errno `e`, into out. */
EC_FN(void, ec_errstr, (int64_t e)) {
  out_len = 0;
  const char *m = e < 0 && e > -100000 ? strerror((int)-e) : "unknown error";
  out_put(m, strlen(m));
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
  pid_t pid = fork();
  if (pid < 0) {
    int64_t r = fail();
    close_fd(&op[0]); close_fd(&op[1]); close_fd(&ep[0]); close_fd(&ep[1]);
    close_fd(&xp[0]); close_fd(&xp[1]);
    free(argv);
    return r;
  }
  if (pid == 0) {
    /* only async-signal-safe calls until exec */
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
