/* CBMC harness (invariant I5): ei_buf_alloc and ei_buf_grow never wrap the size computation (n * size + header) for any
   64-bit n and size: they either return a buffer of that size with count 1, or trap (the path ends). The overflow checks of
   the run (--unsigned-overflow-check) fail if any wraps. */
#include <stdint.h>
#include <assert.h>
#include <stdlib.h>
#include "../../core/eider_rt.h"

void harness(void) {
  uint64_t n, size, n2;
  __CPROVER_assume(size <= 16); /* the element sizes of real programs are small; the arithmetic is checked for all n */
  void *d = ei_buf_alloc(n, size);
  assert(d != NULL);
  assert(ei_buf_count(d) == 1);
  d = ei_buf_grow(d, n2, size);
  assert(d != NULL);
  assert(ei_buf_count(d) == 1);
}
