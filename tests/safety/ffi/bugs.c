/* Deliberately buggy C for tests/safety/ffi: each function is bound in Eider as `extern "c" fn name(inout buf: List[u8], ...)`,
   so C receives (uint8_t *p, uint64_t len, ...). */
#include <stdint.h>
#include <string.h>

/* correct: writes exactly len bytes */
void fill_ok(uint8_t *p, uint64_t len) { memset(p, 0x41, len); }

/* correct: writes only part of the buffer */
void fill_half(uint8_t *p, uint64_t len) { memset(p, 0x43, len / 2); }

/* BUG: writes `over` bytes past the end of the buffer it was given */
void fill_over(uint8_t *p, uint64_t len, int64_t over) { memset(p, 0x42, len + (uint64_t)over); }

/* BUG: writes one byte at len + at (a store that may skip a canary placed right after the buffer) */
void poke_after(uint8_t *p, uint64_t len, int64_t at) { p[len + (uint64_t)at] = 0x44; }

/* correct, read-only: sums the bytes (a non-inout List is passed the same way and is never guarded) */
uint64_t sum_bytes(const uint8_t *p, uint64_t len) {
  uint64_t s = 0;
  for (uint64_t i = 0; i < len; i++) s += p[i];
  return s;
}
