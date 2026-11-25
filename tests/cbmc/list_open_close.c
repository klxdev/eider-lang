/* CBMC harness (invariants I2, I5): ei_list_open opens a gap inside the buffer (growing it when needed) and ei_list_close
   closes one, for EVERY length, position and gap size within the bound below (enumerated, so every case is concrete: a
   symbolic memmove length makes the solver run out of memory), with CBMC checking each access, including memmove, and
   len <= cap after each call. */
#include <stdint.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "../../core/eider_rt.h"

void harness(void) {
  const uint64_t size = 2, cap0 = 3;
  for (uint64_t len0 = 0; len0 <= cap0; len0++)
    for (uint64_t at = 0; at <= len0; at++)
      for (uint64_t n = 0; n <= 4; n++) {
        void *data = ei_buf_alloc(cap0, size);
        memset(data, 0, (size_t)(cap0 * size));
        uint64_t len = len0, cap = cap0;
        ei_list_open(&data, &len, &cap, at, n, size);
        assert(len == len0 + n);
        assert(len <= cap);
        if (len > 0) { /* the whole live range is addressable */
          ((char *)data)[len * size - 1] = 1;
          ((char *)data)[0] = 1;
        }
        for (uint64_t at2 = 0; at2 <= len; at2++)
          for (uint64_t n2 = 0; n2 <= len - at2; n2++) {
            uint64_t l2 = len;
            ei_list_close(data, &l2, at2, n2, size);
            assert(l2 == len - n2);
          }
        ei_buf_free(data);
      }
}
