/* core/wasm libc: the <inttypes.h> format macros the runtime uses (no functions). */
#ifndef EI_WASM_INTTYPES_H
#define EI_WASM_INTTYPES_H
#include <stdint.h>
#if __SIZEOF_LONG__ == 8
#define EI_WASM_P64 "l"
#else
#define EI_WASM_P64 "ll"
#endif
#define PRId32 "d"
#define PRIu32 "u"
#define PRId64 EI_WASM_P64 "d"
#define PRIu64 EI_WASM_P64 "u"
#define PRIdLEAST64 PRId64
#endif
