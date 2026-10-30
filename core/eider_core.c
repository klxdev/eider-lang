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

#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
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

static unsigned char *in_p, *out_p;
static size_t in_len, in_cap, out_len, out_cap;

static void reserve(unsigned char **p, size_t *cap, size_t need) {
  if (need <= *cap) return;
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

/* Run argv = in[0..] (searched on PATH). capture != 0: the child's stdout goes into out.
   Returns the exit code, 128+signal, or -errno if the program could not be started. */
EC_FN(int64_t, ec_run, (int32_t capture)) {
  if (in_len == 0) return -EINVAL;
  int argc = 0;
  while (arg(argc)) argc++;
  char **argv = calloc((size_t)argc + 1, sizeof *argv);
  if (!argv) return -ENOMEM;
  for (int k = 0; k < argc; k++) argv[k] = (char *)arg(k);
  int fds[2] = {-1, -1}, errp[2] = {-1, -1};
  if ((capture && pipe(fds) != 0) || pipe(errp) != 0) {
    int64_t r = fail();
    free(argv);
    return r;
  }
  /* the exec-error pipe closes on a successful exec; otherwise reading it waits for the child */
  fcntl(errp[1], F_SETFD, FD_CLOEXEC);
  fflush(stdout);
  fflush(stderr);
  pid_t pid = fork();
  if (pid < 0) {
    int64_t r = fail();
    free(argv);
    return r;
  }
  if (pid == 0) {
    close(errp[0]);
    if (capture) {
      dup2(fds[1], 1);
      close(fds[0]);
      close(fds[1]);
    }
    execvp(argv[0], argv);
    int e = errno;
    (void)!write(errp[1], &e, sizeof e);
    _exit(127);
  }
  free(argv);
  close(errp[1]);
  out_len = 0;
  if (capture) {
    close(fds[1]);
    char buf[65536];
    for (;;) {
      ssize_t n = read(fds[0], buf, sizeof buf);
      if (n == 0) break;
      if (n < 0) {
        if (errno == EINTR) continue;
        break;
      }
      out_put(buf, (size_t)n);
    }
    close(fds[0]);
  }
  int e = 0, status = 0;
  ssize_t got;
  do got = read(errp[0], &e, sizeof e); while (got < 0 && errno == EINTR);
  close(errp[0]);
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  if (got == (ssize_t)sizeof e) return -(int64_t)e;
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
