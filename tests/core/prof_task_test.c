// Shadow stack of a profiled program across a task's park (#209, decisions C875 and C894): a
// task that parks resumes on any worker, and what it holds from before the park (the address of
// its frame) and what the runtime reads for it afterwards (the depth, the top frame) must still
// be its own. Built with -DEI_RT_PROFILE and run by tests/core/run.sh in task mode, against
// eider_rt.c and eider_core.c.
#define _POSIX_C_SOURCE 200809L

#include "../../core/eider_rt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int64_t ec_sleep_ns(int64_t ns);

static int failures, checks;
static void check(int ok, const char *what, int line) {
  checks++;
  if (!ok) {
    failures++;
    fprintf(stderr, "FAIL prof_task_test.c:%d: %s\n", line, what);
  }
}
#define CHECK(c) check((c) ? 1 : 0, #c, __LINE__)

static const char *const names[] = {"", "main", "outer", "inner", "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"};
static const uint32_t file_of[] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
static const char *const files[] = {"prof_task_test.ei"};
static const ei_prof_table tab = {names, file_of, 20, files, 1, EI_PROF_CPU | EI_PROF_MEM | EI_PROF_CONC, "prof_task_test.ei", "0.1.0"};

enum { N = 16, ROUNDS = 40 };
static int bad[N];

/* the running position as ei_prof_here tokens it: kind 0, fn, line */
static int here_is(uint32_t fn, uint32_t line) {
  uint64_t h = ei_prof_here();
  return (uint32_t)(h & 0xFFFFFFFFu) == line && (uint32_t)((h >> 32) & 0xFFFFFFu) == fn;
}

/* two frames deep, parked between line stores: after every park the frame it holds must be the
   one the runtime sees on top, at the depth it entered */
static void *task(void *arg) {
  int id = (int)(intptr_t)arg;
  uint32_t outer_fn = 4 + (uint32_t)id;
  ei_prof_frame *a = ei_prof_enter(outer_fn);
  ei_prof_frame *b = ei_prof_enter(3);
  for (int r = 0; r < ROUNDS; r++) {
    uint32_t line = (uint32_t)(100 + r);
    b->line = (float)line;
    ec_sleep_ns(200000 + 50000 * (id % 5)); /* a park: another worker may resume it */
    if (ei_prof_depth_get() != 2) bad[id]++;
    if (!here_is(3, line)) bad[id]++;
    b->line = (float)(line + 1000);
    ec_sleep_ns(100000);
    if (!here_is(3, line + 1000)) bad[id]++;
  }
  ei_prof_leave();
  a->line = 7;
  if (!here_is(outer_fn, 7) || ei_prof_depth_get() != 1) bad[id]++;
  ei_prof_leave();
  if (ei_prof_depth_get() != 0) bad[id]++;
  return NULL;
}

int main(void) {
  ei_set_file("prof_task_test.ei");
  ei_prof_init(&tab);
  static ei_thread th[N];
  for (int i = 0; i < N; i++) ei_thread_start(&th[i], task, (void *)(intptr_t)i);
  for (int i = 0; i < N; i++) {
    ei_thread_join(&th[i]);
    ei_thread_destroy(&th[i]);
  }
  int total = 0;
  for (int i = 0; i < N; i++) total += bad[i];
  CHECK(total == 0);
  CHECK(ei_prof_depth_get() == 0);
  ei_check_leaks();
  printf("%d checks, %d failures (%d wrong reads after a park)\n", checks, failures, total);
  return failures ? 1 : 0;
}
