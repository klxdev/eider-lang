/* core/wasm libc: allocation and termination (core/wasm/README.md). */
#ifndef EI_WASM_STDLIB_H
#define EI_WASM_STDLIB_H
#include <stddef.h>
void *malloc(size_t n);
void *realloc(void *p, size_t n);
void free(void *p);
/* Both execute `unreachable`: the host sees a trap (a RuntimeError in JavaScript). */
_Noreturn void exit(int code);
_Noreturn void abort(void);
#endif
