/* core/wasm/marshal.h: Strings and List[u8] across a WebAssembly export (README.md,
   "Values across the boundary"). The wrappers wasm.ei generates for exports that take or
   return them (`eider_<name>` over the inner `eider_raw_<name>`) use these; nothing else
   does. */
#ifndef EIDER_WASM_MARSHAL_H
#define EIDER_WASM_MARSHAL_H

#include "eider_rt.h"

/* List[u8] as the compiler lays it out (the same three words as ei_String). */
typedef struct { uint8_t *p; uint64_t len; uint64_t cap; } ei_Bytes;

/* A String of the n bytes at p; traps "String argument isn't valid UTF-8 without NUL bytes"
   otherwise. The caller drops it (ei_drop_String) when the call returns. */
ei_String ei_wasm_in_string(const char *p, uint32_t n);
/* A List[u8] holding the n bytes at p; drop it with ei_wasm_drop_bytes. */
ei_Bytes ei_wasm_in_bytes(const uint8_t *p, uint32_t n);
void ei_wasm_drop_bytes(ei_Bytes *b);

/* A result: kept until the loader has copied it out (`eider_ret_release`), its address
   returned and its length behind `eider_ret_len`. An empty one is address 0. */
const char *ei_wasm_out_string(ei_String s);
const uint8_t *ei_wasm_out_bytes(ei_Bytes b);

#endif
