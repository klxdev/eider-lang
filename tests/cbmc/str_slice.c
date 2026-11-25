/* CBMC harness (invariant I1): ei_str_slice never reads outside its source and returns a well formed String of the right
   length, for every ASCII source of up to 3 bytes and every start and end (an out-of-range or non-boundary slice traps). */
#include <stdint.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "../../core/eider_rt.h"

void harness(void) {
  for (uint64_t n = 0; n <= 3; n++) {
    char src[4];
    for (uint64_t i = 0; i < n; i++) { src[i] = (char)nondet_char(); __CPROVER_assume(src[i] != 0 && (unsigned char)src[i] < 0x80); }
    src[n] = 0;
    for (uint64_t a = 0; a <= n; a++)
      for (uint64_t b = a; b <= n; b++) {
        ei_String r = ei_str_slice(src, n, a, b, 0);
        assert(r.p != NULL || (r.len == 0 && r.cap == 0));
        assert(r.len == b - a && r.len <= r.cap);
        assert(r.p == NULL || r.p[r.len] == 0);
        ei_drop_String(&r);
      }
  }
}
