//! Freestanding libc subset for `--wasm`: just what the generated C uses.

pub const FILES: &[(&str, &str)] = &[
    ("stdio.h", r#"#ifndef SH_STDIO
#define SH_STDIO
typedef struct SH_FILE SH_FILE;
#define FILE SH_FILE
extern FILE *stdout, *stderr;
int printf(const char *, ...);
int fprintf(FILE *, const char *, ...);
int snprintf(char *, unsigned long, const char *, ...);
int fflush(FILE *);
#endif
"#),
    ("stdlib.h", r#"#ifndef SH_STDLIB
#define SH_STDLIB
#include <stddef.h>
void *malloc(size_t);
void *realloc(void *, size_t);
void free(void *);
_Noreturn void exit(int);
_Noreturn void abort(void);
#endif
"#),
    ("string.h", r#"#ifndef SH_STRING
#define SH_STRING
#include <stddef.h>
void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
void *memset(void *, int, size_t);
int memcmp(const void *, const void *, size_t);
size_t strlen(const char *);
int strcmp(const char *, const char *);
#endif
"#),
    ("setjmp.h", r#"#ifndef SH_SETJMP
#define SH_SETJMP
typedef int jmp_buf[1];
#define setjmp(b) 0
_Noreturn void longjmp(jmp_buf, int);
#endif
"#),
    ("time.h", r#"#ifndef SH_TIME
#define SH_TIME
typedef long clock_t;
#define CLOCKS_PER_SEC 1000
clock_t clock(void);
#endif
"#),
];

pub const SHIM_C: &str = r#"#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>
void *memcpy(void *, const void *, size_t);
__attribute__((import_module("env"), import_name("eider_write"))) void eider_write(const char *p, unsigned n);
__attribute__((import_module("env"), import_name("eider_now_ms"))) long long eider_now_ms(void);

struct SH_FILE { int fd; };
static struct SH_FILE so = {1}, se = {2};
struct SH_FILE *stdout = &so, *stderr = &se;

extern unsigned char __heap_base;
static uintptr_t brk_ptr = 0;
typedef struct blk { size_t size; struct blk *next; } blk;
static blk *freelist = 0;

void *malloc(size_t n) {
  n = (n + 15) & ~(size_t)15;
  for (blk **pp = &freelist; *pp; pp = &(*pp)->next)
    if ((*pp)->size >= n) { blk *b = *pp; *pp = b->next; return (char *)b + 16; }
  if (!brk_ptr) brk_ptr = ((uintptr_t)&__heap_base + 15) & ~(uintptr_t)15;
  uintptr_t need = brk_ptr + 16 + n, have = (uintptr_t)__builtin_wasm_memory_size(0) * 65536;
  if (need > have) {
    size_t pages = (need - have + 65535) / 65536;
    if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) return 0;
  }
  blk *b = (blk *)brk_ptr; b->size = n; brk_ptr = need;
  return (char *)b + 16;
}
void free(void *p) { if (!p) return; blk *b = (blk *)((char *)p - 16); b->next = freelist; freelist = b; }
void *realloc(void *p, size_t n) {
  if (!p) return malloc(n);
  blk *b = (blk *)((char *)p - 16);
  if (b->size >= n) return p;
  void *q = malloc(n); if (!q) return 0;
  memcpy(q, p, b->size); free(p); return q;
}
void *memcpy(void *d, const void *s, size_t n) { char *a = d; const char *b = s; while (n--) *a++ = *b++; return d; }
void *memmove(void *d, const void *s, size_t n) {
  char *a = d; const char *b = s;
  if (a < b) while (n--) *a++ = *b++; else { a += n; b += n; while (n--) *--a = *--b; }
  return d;
}
void *memset(void *d, int c, size_t n) { char *a = d; while (n--) *a++ = (char)c; return d; }
int memcmp(const void *x, const void *y, size_t n) {
  const unsigned char *a = x, *b = y;
  for (; n; n--, a++, b++) if (*a != *b) return *a - *b;
  return 0;
}
size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
int strcmp(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return (unsigned char)*a - (unsigned char)*b; }
_Noreturn void exit(int c) { (void)c; __builtin_trap(); }
_Noreturn void abort(void) { __builtin_trap(); }
_Noreturn void longjmp(int *b, int v) { (void)b; (void)v; __builtin_trap(); }
long clock(void) { return (long)eider_now_ms(); }
int fflush(struct SH_FILE *f) { (void)f; return 0; }

typedef struct { char *buf; size_t cap, len; } out_t;
static void put(out_t *o, char c) { if (o->len + 1 < o->cap) o->buf[o->len] = c; o->len++; }
static void puts_(out_t *o, const char *s) { while (*s) put(o, *s++); }
static void putu(out_t *o, unsigned long long v, int neg) {
  char t[24]; int i = 0;
  do { t[i++] = (char)('0' + v % 10); v /= 10; } while (v);
  if (neg) put(o, '-');
  while (i) put(o, t[--i]);
}
static void fmt(out_t *o, const char *f, va_list ap) {
  for (; *f; f++) {
    if (*f != '%') { put(o, *f); continue; }
    f++;
    int l = 0;
    while (*f == 'l' || *f == 'z') { l++; f++; }
    switch (*f) {
      case 's': { const char *s = va_arg(ap, const char *); puts_(o, s ? s : "(null)"); break; }
      case 'c': put(o, (char)va_arg(ap, int)); break;
      case 'd': case 'i': {
        long long v = l ? va_arg(ap, long long) : va_arg(ap, int);
        putu(o, v < 0 ? 0ULL - (unsigned long long)v : (unsigned long long)v, v < 0); break; }
      case 'u': putu(o, l ? va_arg(ap, unsigned long long) : va_arg(ap, unsigned), 0); break;
      case '%': put(o, '%'); break;
      default: put(o, '?');
    }
  }
}
int snprintf(char *b, unsigned long n, const char *f, ...) {
  out_t o = {b, n, 0}; va_list ap; va_start(ap, f); fmt(&o, f, ap); va_end(ap);
  if (n) b[o.len < n ? o.len : n - 1] = 0;
  return (int)o.len;
}
static int emit(const char *f, va_list ap) {
  char buf[512]; out_t o = {buf, sizeof buf, 0};
  fmt(&o, f, ap);
  eider_write(buf, (unsigned)(o.len < sizeof buf ? o.len : sizeof buf - 1));
  return (int)o.len;
}
int printf(const char *f, ...) { va_list ap; va_start(ap, f); int r = emit(f, ap); va_end(ap); return r; }
int fprintf(struct SH_FILE *fp, const char *f, ...) { (void)fp; va_list ap; va_start(ap, f); int r = emit(f, ap); va_end(ap); return r; }
"#;
