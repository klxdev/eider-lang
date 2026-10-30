// eider_core: the only hand-written C under Eider's standard library.
//
// Rule: no logic lives here. Each function is one OS call with its error mapped to -errno.
// Pointers never cross into Eider. Data moves through two byte buffers: Eider fills `in`
// a byte at a time (arguments are NUL-separated), calls an op, then reads `out` a byte at
// a time. Everything else (parsing, paths, recursion, formatting) is Eider in std/.
#define _POSIX_C_SOURCE 200809L
#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned char *in_p, *out_p;
static size_t in_len, in_cap, out_len, out_cap;

static void reserve(unsigned char **p, size_t *cap, size_t need) {
  if (need <= *cap) return;
  size_t n = *cap ? *cap * 2 : 256;
  while (n < need) n *= 2;
  unsigned char *q = realloc(*p, n);
  if (!q) { fputs("eider_core: out of memory\n", stderr); exit(101); }
  *p = q; *cap = n;
}

static void out_put(const void *d, size_t n) {
  reserve(&out_p, &out_cap, out_len + n + 1);
  memcpy(out_p + out_len, d, n);
  out_len += n;
  out_p[out_len] = 0;
}

/* in[k]: the k-th NUL-separated argument (NULL if absent). */
static const char *arg(int k) {
  size_t i = 0;
  for (; k > 0; k--) {
    while (i < in_len && in_p[i]) i++;
    if (i >= in_len) return NULL;
    i++;
  }
  return i <= in_len ? (const char *)in_p + i : NULL;
}

// ---- buffers
void ec_in_clear(void) { in_len = 0; reserve(&in_p, &in_cap, 1); in_p[0] = 0; }
void ec_in_push(int32_t b) { reserve(&in_p, &in_cap, in_len + 2); in_p[in_len++] = (unsigned char)b; in_p[in_len] = 0; }
int64_t ec_out_len(void) { return (int64_t)out_len; }
int32_t ec_out_byte(int64_t i) { return i >= 0 && (uint64_t)i < out_len ? out_p[i] : -1; }
/* The input buffer as a C string (Eider pushes a final NUL first). */
const char *ec_in_cstr(void) { reserve(&in_p, &in_cap, 1); return (const char *)in_p; }
/* Byte i of a string literal; Eider bounds-checks against strlen first. */
int32_t ec_str_byte(const char *s, int64_t i) { return (unsigned char)s[i]; }

// ---- files: path is in[0]
int64_t ec_read_file(void) {
  out_len = 0;
  FILE *f = fopen(arg(0), "rb");
  if (!f) return -errno;
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) out_put(buf, n);
  int bad = ferror(f);
  fclose(f);
  return bad ? -EIO : (int64_t)out_len;
}

/* in = path NUL data... */
int64_t ec_write_file(int32_t append) {
  const char *path = arg(0);
  size_t off = strlen(path) + 1, n = in_len > off ? in_len - off : 0;
  FILE *f = fopen(path, append ? "ab" : "wb");
  if (!f) return -errno;
  size_t w = n ? fwrite(in_p + off, 1, n, f) : 0;
  if (fclose(f) != 0 || w != n) return -EIO;
  return 0;
}

/* out = entry names, each followed by NUL ("." and ".." skipped). */
int64_t ec_list_dir(void) {
  out_len = 0;
  DIR *d = opendir(arg(0));
  if (!d) return -errno;
  struct dirent *e;
  while ((e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    out_put(e->d_name, strlen(e->d_name) + 1);
  }
  closedir(d);
  return 0;
}

/* 0 missing, 1 file, 2 directory, 3 other. Follows symlinks. */
int32_t ec_kind(void) {
  struct stat st;
  if (stat(arg(0), &st) != 0) return 0;
  return S_ISREG(st.st_mode) ? 1 : S_ISDIR(st.st_mode) ? 2 : 3;
}

int64_t ec_mkdir(void) { return mkdir(arg(0), 0777) == 0 ? 0 : -errno; }
int64_t ec_remove(void) { return remove(arg(0)) == 0 ? 0 : -errno; }
int64_t ec_rename(void) { return rename(arg(0), arg(1)) == 0 ? 0 : -errno; }

/* getenv(in[0]) -> out; 1 if set, 0 if not. */
int32_t ec_getenv(void) {
  out_len = 0;
  const char *v = getenv(arg(0));
  if (!v) return 0;
  out_put(v, strlen(v));
  return 1;
}

/* Write in[] to fd 1 or 2, after flushing Eider's buffered `print` output. */
int64_t ec_write_fd(int32_t fd) {
  fflush(stdout);
  size_t i = 0;
  while (i < in_len) {
    ssize_t w = write(fd, in_p + i, in_len - i);
    if (w < 0) { if (errno == EINTR) continue; return -errno; }
    i += (size_t)w;
  }
  return 0;
}

/* Run argv = in[0..] (searched on PATH). capture: child stdout -> out.
   Returns the exit code, 128+signal, or -errno if it could not start. */
int64_t ec_run(int32_t capture) {
  if (in_len == 0) return -EINVAL;
  int argc = 0;
  while (arg(argc)) argc++;
  char **argv = calloc((size_t)argc + 1, sizeof *argv);
  if (!argv) return -ENOMEM;
  for (int k = 0; k < argc; k++) argv[k] = (char *)arg(k);
  int fds[2] = {-1, -1}, errp[2];
  if ((capture && pipe(fds) != 0) || pipe(errp) != 0) { free(argv); return -errno; }
  fflush(stdout);
  fflush(stderr);
  pid_t pid = fork();
  if (pid < 0) { free(argv); return -errno; }
  if (pid == 0) {
    close(errp[0]);
    if (capture) { dup2(fds[1], 1); close(fds[0]); close(fds[1]); }
    execvp(argv[0], argv);
    int e = errno;
    (void)!write(errp[1], &e, sizeof e);  /* tell the parent exec failed */
    _exit(127);
  }
  free(argv);
  close(errp[1]);
  out_len = 0;
  if (capture) {
    close(fds[1]);
    char buf[65536];
    ssize_t n;
    while ((n = read(fds[0], buf, sizeof buf)) != 0) {
      if (n < 0) { if (errno == EINTR) continue; break; }
      out_put(buf, (size_t)n);
    }
    close(fds[0]);
  }
  int e = 0, status = 0;
  ssize_t got = read(errp[0], &e, sizeof e);
  close(errp[0]);
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  if (got == (ssize_t)sizeof e) return -e;
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
