/* eider_core_ext: the core's byte buffers as seen from C that is linked into the same program
   and implements more of the ABI over them (today only core/crypto). Contract: core/ABI.md,
   "Core extensions". Eider never binds these: they hand out pointers. */
#ifndef EIDER_CORE_EXT_H
#define EIDER_CORE_EXT_H

#include <stddef.h>

/* The calling thread's `in` buffer: its bytes and length. Valid until the next call that
   changes `in` (ec_in_push, ec_in_clear, ec_ext_wipe). */
const unsigned char *ec_ext_in(size_t *len);

/* Make `out` exactly n bytes (contents unspecified until written) and return them for
   writing. Whatever `out` held before is zeroed first. */
unsigned char *ec_ext_out(size_t n);

/* Shorten `out` to n bytes (no-op if it is already shorter); the dropped bytes are zeroed. */
void ec_ext_out_truncate(size_t n);

/* Zero everything written to `in` since its last wipe and empty it (`out` is untouched). */
void ec_ext_in_wipe(void);

/* Zero everything written to `in` and `out` since their last wipe and empty both. */
void ec_ext_wipe(void);

#endif
