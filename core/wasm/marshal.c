// core/wasm/marshal.c: Strings and List[u8] across a WebAssembly export (README.md, "Values
// across the boundary"). Built into a module only when an export takes or returns one.
//
// The loader copies an argument into the module with `eider_alloc`, passes (address, length),
// and frees it with `eider_free` after the call; the generated wrapper makes a String or
// List[u8] of its own from those bytes and drops it when the function returns (Eider
// functions borrow their arguments). A result is kept here, the call returns its address,
// the loader reads `eider_ret_len()` bytes and calls `eider_ret_release()`, which drops it.

#include "wasm/marshal.h"

#include "wasm/host.h"

static char *ret_p;
static uint64_t ret_len;

EI_WASM_EXPORT("eider_alloc") void *eider_alloc(uint32_t n);
EI_WASM_EXPORT("eider_free") void eider_free(void *p);
EI_WASM_EXPORT("eider_ret_len") uint32_t eider_ret_len(void);
EI_WASM_EXPORT("eider_ret_release") void eider_ret_release(void);

void *eider_alloc(uint32_t n) {
  void *p = malloc(n ? n : 1);
  if (!p) ei_trap("out of memory", 0);
  return p;
}

void eider_free(void *p) { free(p); }

uint32_t eider_ret_len(void) { return (uint32_t)ret_len; }

void eider_ret_release(void) {
  if (ret_p) {
    if (ei_buf_dec(ret_p)) ei_buf_free(ret_p);
  }
  ret_p = NULL;
  ret_len = 0;
}

ei_String ei_wasm_in_string(const char *p, uint32_t n) {
  if (ei_utf8_check((const uint8_t *)p, n) != n) {
    ei_trap("String argument isn't valid UTF-8 without NUL bytes", 0);
  }
  return ei_str_from_n(p, n);
}

ei_Bytes ei_wasm_in_bytes(const uint8_t *p, uint32_t n) {
  ei_Bytes b = {NULL, 0, 0};
  if (n > 0) {
    b.p = (uint8_t *)ei_buf_alloc(n, 1);
    memcpy(b.p, p, n);
    b.len = n;
    b.cap = n;
  }
  return b;
}

void ei_wasm_drop_bytes(ei_Bytes *b) {
  if (ei_buf_dec(b->p)) ei_buf_free(b->p);
  b->p = NULL;
  b->len = 0;
  b->cap = 0;
}

const char *ei_wasm_out_string(ei_String s) {
  eider_ret_release();
  ret_p = s.p;
  ret_len = s.len;
  return s.len ? s.p : NULL;
}

const uint8_t *ei_wasm_out_bytes(ei_Bytes b) {
  eider_ret_release();
  ret_p = (char *)b.p;
  ret_len = b.len;
  return b.len ? b.p : NULL;
}
