/* CBMC harness (reactor timer heap): heap_push and heap_remove keep the min-heap order, every wait's hidx equal to its
   slot (or -1 once removed), and hn equal to the number of waits in it, for EVERY deadline (any int64, ties included) of
   up to N waits and every one removed. The functions are static, so the harness includes the file; run it alone
   (without core/eider_rt.c). */
#include "../../core/eider_rt.c"
#include <assert.h>
#include <stdint.h>

#ifndef N
#define N 4
#endif

int64_t nondet_i64(void);
unsigned nondet_uint(void);

static void check(struct reactor *r, ei_wait **ws, int n) {
  int live = 0;
  for (int k = 0; k < n; k++)
    if (ws[k]->hidx >= 0) {
      live++;
      assert((size_t)ws[k]->hidx < r->hn);
      assert(r->heap[ws[k]->hidx] == ws[k]);
    }
  assert((size_t)live == r->hn);
  for (size_t i = 1; i < r->hn; i++) assert(r->heap[(i - 1) / 2]->dl <= r->heap[i]->dl);
  assert(atomic_load(&r->next_dl) == (r->hn ? r->heap[0]->dl : INT64_MAX));
}

void harness(void) {
  struct reactor r;
  ei_wait w[N];
  ei_wait *ws[N];
  ei_wait *slots[N];
  memset(&r, 0, sizeof r);
  r.heap = slots; /* big enough: hcap = N, so no realloc */
  r.hcap = N;
  for (int k = 0; k < N; k++) {
    memset(&w[k], 0, sizeof w[k]);
    w[k].hidx = -1;
    w[k].dl = nondet_i64();
    ws[k] = &w[k];
  }
  for (int k = 0; k < N; k++) {
    assert(heap_push(&r, ws[k]));
    check(&r, ws, N);
  }
  /* remove in an arbitrary order */
  for (int step = 0; step < N; step++) {
    unsigned which = nondet_uint();
    __CPROVER_assume(which < N);
    heap_remove(&r, ws[which]);
    check(&r, ws, N);
    heap_remove(&r, ws[which]); /* a second removal is a no-op */
    check(&r, ws, N);
  }
  assert(r.hn == 0);
}
