/* Pending process-directed signals must be delivered after the Eider main unblocks
   them, including when ei_main runs on a guarded worker. Run via signal-mask.sh. */
#define _POSIX_C_SOURCE 200809L
#include "../../core/eider_rt.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

int64_t ec_signal_fd(void);
int64_t ec_signal_set(int32_t sig, int32_t how);
int64_t ec_signal_mask(int32_t sig, int32_t block);
int64_t ec_getpid(void);
int64_t ec_kill(int32_t pid, int32_t sig);
int64_t ec_fd_wait(int32_t fd, int32_t interest, int64_t timeout_ms);
int64_t ec_read_fd(int32_t fd, int64_t max);
int32_t ec_out_byte(int64_t i);

static int body(void) {
  const int32_t usr1 = 10; /* Eider numbering, translated by the core. */
  int64_t fd = ec_signal_fd();
  if (fd < 0 || ec_signal_set(usr1, 2) < 0 || ec_signal_mask(usr1, 1) < 0 ||
      ec_kill((int32_t)ec_getpid(), usr1) < 0 || ec_signal_mask(usr1, 0) < 0) {
    fputs("signal setup failed\n", stderr);
    return 2;
  }
  /* A signal may interrupt the readiness wait; keep the total timeout bounded. */
  for (int i = 0; i < 20; i++) {
    if ((ec_fd_wait((int32_t)fd, 1, 25) & 1) != 0 &&
        ec_read_fd((int32_t)fd, 1) == 1 && ec_out_byte(0) == usr1) {
      puts("pending signal delivered");
      return 0;
    }
  }
  fputs("pending USR1 was not delivered after unblocking\n", stderr);
  return 1;
}

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  if (strcmp(argv[1], "direct") == 0) return body();
  if (strcmp(argv[1], "guarded") == 0) return ei_main(body);
  return 2;
}
