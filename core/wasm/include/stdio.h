/* core/wasm libc: the stdio subset generated C and the runtime use (core/wasm/README.md).
   Every stream writes through the host import env.eider_write; nothing is buffered. */
#ifndef EI_WASM_STDIO_H
#define EI_WASM_STDIO_H
#include <stddef.h>
typedef struct ei_wasm_file FILE;
extern FILE *stdout, *stderr;
/* Conversions: %d %i %u %s %c %% with the length modifiers l, ll, z. */
int printf(const char *fmt, ...);
int fprintf(FILE *f, const char *fmt, ...);
int snprintf(char *buf, size_t n, const char *fmt, ...);
int fflush(FILE *f);
#endif
