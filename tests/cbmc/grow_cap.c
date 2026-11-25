/* CBMC harness (docs/design/c-core-audit.md, invariant I5): ei_grow_cap never overflows and returns a capacity that holds
   len + extra, for every 64-bit input. A request that would wrap traps (ei_trap, modelled as an assertion-free abort). */
#include <stdint.h>
#include <assert.h>
#include <stdlib.h>
#include "../../core/eider_rt.h"

void harness(void) {
  uint64_t cap, len, extra, min;
  __CPROVER_assume(len <= cap); /* the List invariant I2 */
  uint64_t c = ei_grow_cap(cap, len, extra, min);
  assert(c >= len);                 /* no wrap */
  assert(c - len >= extra);         /* room for the request */
  assert(c >= min);
}
