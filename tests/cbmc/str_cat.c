/* CBMC harness (invariant I1): ei_str_cat keeps a String well formed (len <= cap, a NUL after the last byte, a null
   buffer only when empty) for a String of N bytes and an appended text of K bytes (tests/cbmc/run.sh runs every N and K
   from 0 to 2; the bytes are nondeterministic) (appending a String to itself was too large for the solver; the runtime tests cover it under ASan). One case per run: all cases in one formula make the solver run out of memory. */
#include <stdint.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "../../core/eider_rt.h"

#ifndef N
#define N 1
#endif
#ifndef K
#define K 1
#endif

static void well_formed(const ei_String *s) {
  assert(s->p != NULL || (s->len == 0 && s->cap == 0));
  assert(s->len <= s->cap);
  assert(s->p == NULL || s->p[s->len] == 0);
}

void harness(void) {
  char src[N + 1], t[K + 1];
  for (int i = 0; i < N; i++) { src[i] = (char)nondet_char(); __CPROVER_assume(src[i] != 0); }
  src[N] = 0;
  for (int i = 0; i < K; i++) t[i] = (char)nondet_char();
  t[K] = 0;
  ei_String s = ei_str_from(src);
  well_formed(&s);
  ei_str_cat(&s, t, K);
  well_formed(&s);
  assert(s.len == N + K);
  ei_drop_String(&s);
}
