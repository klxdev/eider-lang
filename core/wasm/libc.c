// core/wasm libc: the freestanding C library subset a WebAssembly module of Eider needs,
// and nothing more. Contract and limits: core/wasm/README.md.
//
// Exactly the functions declared in core/wasm/include/: allocation (power-of-two size
// classes with a free list each, over a bump pointer into linear memory), the mem*/str*
// functions, printf/fprintf/snprintf (%d %i %u %s %c %%, length modifiers l ll z), fflush,
// exit/abort/longjmp (`unreachable`; in a core module exit and abort end the process through
// ec_exit). Output goes to the host import env.eider_write (in a core module ec_write_fd).
// Single-threaded, like the module.
#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "host.h"

// ---- streams: all output is unbuffered and goes to the host

struct ei_wasm_file { int fd; };
static struct ei_wasm_file out_file = {1}, err_file = {2};
FILE *stdout = &out_file, *stderr = &err_file;

int fflush(FILE *f) {
  (void)f;
  return 0;
}

void ei_host_write(int fd, const char *p, uint32_t n) {
#if defined(EI_WASM_CORE)
  ei_host_in_clear();
  for (uint32_t i = 0; i < n; i++) ei_host_in_push((unsigned char)p[i]);
  ei_host_write_fd(fd == 2 ? 2 : 1);
#else
  (void)fd;
  eider_write(p, n);
#endif
}

// ---- termination

_Noreturn void ei_host_leave(int code) {
#if defined(EI_WASM_CORE)
  ei_host_exit(code);
#else
  (void)code;
#endif
  ei_wasm_trap();
}

_Noreturn void exit(int code) { ei_host_leave(code); }
_Noreturn void abort(void) { ei_host_leave(134); }
_Noreturn void longjmp(jmp_buf b, int v) {
  (void)b;
  (void)v;
  ei_wasm_trap();
}

// ---- allocation. A block is a 16-byte header (its size class) and the memory after it.
// Sizes are rounded up to a power of two (at least 16 bytes); each class has a free list,
// so malloc and free take constant time and a block is reused only by its own class (at
// most half of a block is unused; blocks are never split, merged or returned to the host).

#define EI_WASM_PAGE ((uintptr_t)65536)
#define EI_WASM_ALIGN ((size_t)16)
#define EI_WASM_CLASSES 28 /* 16 B .. 2 GiB */

typedef struct blk { size_t cls; struct blk *next; } blk;
_Static_assert(sizeof(blk) <= EI_WASM_ALIGN, "block header fits the alignment");

extern unsigned char __heap_base; /* first free byte after the data and stack (wasm-ld) */
static uintptr_t brk_ptr;
static blk *free_list[EI_WASM_CLASSES];

static blk *header(void *p) { return (blk *)(void *)((unsigned char *)p - EI_WASM_ALIGN); }
static size_t class_size(size_t c) { return EI_WASM_ALIGN << c; }

void *malloc(size_t n) {
  size_t c = 0;
  while (c < EI_WASM_CLASSES && class_size(c) < n) c++;
  if (c == EI_WASM_CLASSES) return NULL;
  if (free_list[c]) {
    blk *b = free_list[c];
    free_list[c] = b->next;
    return (unsigned char *)b + EI_WASM_ALIGN;
  }
  n = class_size(c);
  if (!brk_ptr) brk_ptr = ((uintptr_t)&__heap_base + EI_WASM_ALIGN - 1) / EI_WASM_ALIGN * EI_WASM_ALIGN;
  if (n + EI_WASM_ALIGN > UINTPTR_MAX - brk_ptr) return NULL;
  uintptr_t need = brk_ptr + EI_WASM_ALIGN + n;
  uintptr_t have = (uintptr_t)ei_wasm_pages() * EI_WASM_PAGE;
  if (need > have) {
    size_t pages = (size_t)((need - have + EI_WASM_PAGE - 1) / EI_WASM_PAGE);
    if (ei_wasm_grow(pages) == SIZE_MAX) return NULL;
  }
  blk *b = (blk *)brk_ptr;
  b->cls = c;
  brk_ptr = need;
  return (unsigned char *)b + EI_WASM_ALIGN;
}

void free(void *p) {
  if (!p) return;
  blk *b = header(p);
  b->next = free_list[b->cls];
  free_list[b->cls] = b;
}

void *realloc(void *p, size_t n) {
  if (!p) return malloc(n);
  blk *b = header(p);
  size_t have = class_size(b->cls);
  if (have >= n) return p;
  void *q = malloc(n);
  if (!q) return NULL;
  memcpy(q, p, have);
  free(p);
  return q;
}

// ---- memory and strings (byte loops: -fno-builtin keeps the compiler from turning them
// back into calls to themselves)

void *memcpy(void *restrict d, const void *restrict s, size_t n) {
#if defined(__wasm_bulk_memory__)
  /* memory.copy (the intrinsic is an instruction with bulk memory, never a call) */
  if (n) __builtin_memcpy(d, s, n);
  return d;
#endif
  unsigned char *a = d;
  const unsigned char *b = s;
  while (n--) *a++ = *b++;
  return d;
}

void *memmove(void *d, const void *s, size_t n) {
#if defined(__wasm_bulk_memory__)
  if (n) __builtin_memmove(d, s, n);
  return d;
#endif
  unsigned char *a = d;
  const unsigned char *b = s;
  if (a < b) {
    while (n--) *a++ = *b++;
  } else {
    a += n;
    b += n;
    while (n--) *--a = *--b;
  }
  return d;
}

void *memset(void *d, int c, size_t n) {
#if defined(__wasm_bulk_memory__)
  if (n) __builtin_memset(d, c, n);
  return d;
#endif
  unsigned char *a = d;
  while (n--) *a++ = (unsigned char)c;
  return d;
}

int memcmp(const void *x, const void *y, size_t n) {
  const unsigned char *a = x, *b = y;
  for (; n; n--, a++, b++)
    if (*a != *b) return *a < *b ? -1 : 1;
  return 0;
}

size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}

int strcmp(const char *a, const char *b) {
  while (*a && *a == *b) {
    a++;
    b++;
  }
  unsigned char x = (unsigned char)*a, y = (unsigned char)*b;
  return x < y ? -1 : x > y;
}

// ---- compiler support. -nostdlib leaves out compiler-rt, so the one routine clang calls
// for wasm32 code from eider_rt is here: __multi3, the 128-bit multiply it uses to check a
// 64-bit multiply for overflow (__builtin_mul_overflow, and the `n > MAX / size` idiom it
// recognises). Built from 32-bit halves, so it never calls itself.

#if defined(__SIZEOF_INT128__)
__extension__ typedef unsigned __int128 ei_u128;

static uint64_t mul_64x64(uint64_t a, uint64_t b, uint64_t *hi) {
  uint64_t a0 = a & 0xffffffffu, a1 = a >> 32, b0 = b & 0xffffffffu, b1 = b >> 32;
  uint64_t p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  uint64_t mid = (p00 >> 32) + (p01 & 0xffffffffu) + (p10 & 0xffffffffu);
  *hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
  return (mid << 32) | (p00 & 0xffffffffu);
}

ei_u128 __multi3(ei_u128 a, ei_u128 b);
ei_u128 __multi3(ei_u128 a, ei_u128 b) {
  uint64_t alo = (uint64_t)a, ahi = (uint64_t)(a >> 64), blo = (uint64_t)b, bhi = (uint64_t)(b >> 64);
  uint64_t hi;
  uint64_t lo = mul_64x64(alo, blo, &hi);
  hi += alo * bhi + ahi * blo;
  return ((ei_u128)hi << 64) | lo;
}
#endif

// ---- formatting. Output goes to a buffer (snprintf: truncated to its size, always counted)
// or, a chunk at a time, to the host (printf, fprintf: never truncated).

typedef struct {
  char *buf;
  size_t cap, len; /* len: bytes produced so far */
  int host;        /* flush full chunks to the host: 0 no, else the fd (1 or 2) */
  char chunk[256];
} out_t;

static void put(out_t *o, char c) {
  if (o->host) {
    o->chunk[o->len % sizeof o->chunk] = c;
    o->len++;
    if (o->len % sizeof o->chunk == 0) ei_host_write(o->host, o->chunk, (uint32_t)sizeof o->chunk);
    return;
  }
  if (o->len + 1 < o->cap) o->buf[o->len] = c;
  o->len++;
}

static void put_str(out_t *o, const char *s) {
  while (*s) put(o, *s++);
}

static void put_dec(out_t *o, unsigned long long v, int neg) {
  char t[24];
  int i = 0;
  do {
    t[i++] = (char)('0' + v % 10);
    v /= 10;
  } while (v);
  if (neg) put(o, '-');
  while (i) put(o, t[--i]);
}

static void format(out_t *o, const char *f, va_list ap) {
  for (; *f; f++) {
    if (*f != '%') {
      put(o, *f);
      continue;
    }
    f++;
    int longs = 0, sz = 0;
    for (;; f++) {
      if (*f == 'l') longs++;
      else if (*f == 'z') sz = 1;
      else break;
    }
    switch (*f) {
      case 's': {
        const char *s = va_arg(ap, const char *);
        put_str(o, s ? s : "(null)");
        break;
      }
      case 'c': put(o, (char)va_arg(ap, int)); break;
      case 'd':
      case 'i': {
        long long v = sz ? (long long)va_arg(ap, ptrdiff_t)
                      : longs >= 2 ? va_arg(ap, long long)
                      : longs ? (long long)va_arg(ap, long)
                      : (long long)va_arg(ap, int);
        put_dec(o, v < 0 ? 0ULL - (unsigned long long)v : (unsigned long long)v, v < 0);
        break;
      }
      case 'u': {
        unsigned long long v = sz ? (unsigned long long)va_arg(ap, size_t)
                               : longs >= 2 ? va_arg(ap, unsigned long long)
                               : longs ? (unsigned long long)va_arg(ap, unsigned long)
                               : (unsigned long long)va_arg(ap, unsigned);
        put_dec(o, v, 0);
        break;
      }
      case '%': put(o, '%'); break;
      case 0: return; /* a lone `%` at the end */
      default: put(o, '?');
    }
  }
}

int snprintf(char *b, size_t n, const char *f, ...) {
  out_t o;
  o.buf = b;
  o.cap = n;
  o.len = 0;
  o.host = 0;
  va_list ap;
  va_start(ap, f);
  format(&o, f, ap);
  va_end(ap);
  if (n) b[o.len < n ? o.len : n - 1] = 0;
  return o.len > INT32_MAX ? -1 : (int)o.len;
}

static int emit(int fd, const char *f, va_list ap) {
  out_t o;
  o.buf = NULL;
  o.cap = 0;
  o.len = 0;
  o.host = fd;
  format(&o, f, ap);
  size_t rest = o.len % sizeof o.chunk;
  if (rest) ei_host_write(fd, o.chunk, (uint32_t)rest);
  return o.len > INT32_MAX ? -1 : (int)o.len;
}

int printf(const char *f, ...) {
  va_list ap;
  va_start(ap, f);
  int r = emit(1, f, ap);
  va_end(ap);
  return r;
}

int fprintf(FILE *fp, const char *f, ...) {
  va_list ap;
  va_start(ap, f);
  int r = emit(fp == stderr ? 2 : 1, f, ap);
  va_end(ap);
  return r;
}
