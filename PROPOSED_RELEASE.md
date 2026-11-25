# Proposed release: Eider 0.7.9

> **DELETE THIS FILE once `proposed/0.7.9` is integrated into `main` and 0.7.9 is released.** It is a hand-off note, not documentation.

Written 2026-11-25 for the eider-lang agent that is finishing the memory-safety work (#246). This branch (`proposed/0.7.9`) is based on the **`v0.7.8` tag**, not on `main`, so it carries none of that work. Integrate it when the safety work is done.

## Why

0.7.8 (released 2026-11-24) is marked a **pre-release** on GitHub, with a warning in its notes; 0.7.7 is "Latest". 0.7.8 made a latent runtime bug much more likely: programs that start and end many tasks crash (SIGSEGV). Found by running TSan in a Fedora 44 hatchd VM (see "Environment"); TSan itself did not detect it.

## The bug (found, fixed, validated)

`core/eider_rt.c` `stack_put` published a finished task's stack in the stack cache, unlocked, and **then** called `madvise(MADV_DONTNEED)` on everything below the top 16 KiB. In that window another worker's `stack_get` could take the stack for a new task; the late `madvise` then zeroed the new task's live frames. Symptoms: a parked task's wait record reading back as zeros, `rip = 0`, garbage frames in `Router.handle`, the reactor's poller dereferencing a "wait record" that was zeroed. Present in 0.7.7; far likelier with 0.7.8's per-worker reactor shards (faster task turnover). The fix is six lines: discard before publishing.

How it was found: an instrumented runtime (a magic number on each wait record, an event ring log) showed a record that was `start`ed and `heap_push`ed by a live task, never exited, and later read as zeros. The same call chain, `wait_complete` <- `reactor_event`/`shard_timers`, was the crash site. Not the scheduler change and not the std changes: bisect below.

| `tests/server_test.ei` of eider-http, Fedora 44 VM, runs that crashed | unoptimized (`ei run`) | optimized (`ei build`) |
|---|---|---|
| 0.7.7 + eider-http 0.7.4 | 5 of 20 | 0 of 20 |
| 0.7.8 + eider-http 0.7.5 (released) | 14 of 20 | 4 of 20 |
| 0.7.8 std changes with the original scheduler | | 0 of 20 |
| 0.7.8 scheduler with the original std | | 1 of 20 |
| **this branch (the fix)** | **0 of 40** | **0 of 40** |

Also with the fix, in the VM: eider-lang `tsan`, `std`, `core` legs ALL GREEN; eider-http's whole suite ALL OK (TSan runs, TLS interop). Throughput is unchanged (hello-world server, 64 connections: 374k req/s at 16.1 us CPU per request against 367k at 15.9 us for 0.7.8).

## What is in the branch

1. `core/eider_rt.c`: the `stack_put` fix.
2. `CHANGELOG.md`: an `Unreleased` section for it.
3. This file.

No version bump, no seed regeneration, no decision-log entry: do those when integrating (below).

## Integrating

- `git merge proposed/0.7.9` into `main`. Expect a conflict only in `core/eider_rt.c` if your safety work (its commits since v0.7.8 changed about 60 lines of it) touched `stack_put`; keep your changes and make sure the `madvise` comes **before** the stack goes into `stk_cache`.
- Add a decision-log entry with the next free number (C916 is taken on `main`; this branch has none).

## Releasing 0.7.9

1. `scripts/version.sh bump patch`; rename `## Unreleased` in `CHANGELOG.md` to `## 0.7.9`.
2. `sh scripts/selfhost.sh --seed`. Do it **in the Fedora 44 environment**: 0.7.8's seed was regenerated on Fedora 45 with clang 23.1.5, but `scripts/release-env/README.md` says the seed should be built by clang 22.1.8 (Fedora 44) so the byte-for-byte check runs.
3. Verify and publish from Fedora 44 (`scripts/release-env/`), where every verify leg runs (TSan works there, Fedora 45's glibc breaks its `longjmp`). `publish.sh --allow-skipped-legs` exists since 0.7.8 for a machine that cannot, but prefer a run with no skipped leg.
4. After the release: GitHub "Latest" moves to v0.7.9; leave v0.7.8 a pre-release. In **eider-http** (0.7.5 on `main`, needs Eider 0.7.8 or later): raise the minimum in `scripts/env.sh` to 0.7.9 (for example compare `${theirs##*.}` with 9 beside the existing `packages/crypto` check), bump to 0.7.6 with a CHANGELOG line saying why (earlier toolchains can crash), then tag `v0.7.6`. Do not tag it before 0.7.9 exists.

## Reproducing and validating (hatchd, Fedora 44)

```sh
hatchd network create tsannet --subnet 10.89.77.0/24
hatchd run tsan44 --image fedora:44 --exec --vcpus 8 --mem 12288 --disk 40G --network tsannet --rm -d -- sleep infinity
hatchd exec tsan44 -- dnf -y install gcc gcc-c++ make clang lld llvm compiler-rt libasan libubsan libtsan libatomic git openssl python3 gdb ...  # scripts/release-env/Containerfile has the list
hatchd exec tsan44 -- sysctl -w vm.max_map_count=1048576   # the default 65530 makes the core `task (tsan)` tests fail with ENOMEM
```

Copy clean clones in with `hatchd cp` (not a host `target/`), create an unprivileged user, then loop eider-http's `tests/server_test.ei` 20 to 40 times with `scripts/ei run` (unoptimized: about 25% to 70% crash before the fix) and with a `scripts/ei build` binary (optimized: 0% to 20%). Exit code 139 is the crash.

## Known gaps

- **No regression test in the repo.** Three stress tests (many tasks ending at once; relay chains where each task spawns the next and ends; long tasks with 48 KiB of locals parked meanwhile) found the bug in at best 1 of 10 runs on the unfixed runtime, so none was added: a test that almost never fails on the bug gives false assurance. The window is microseconds. A deterministic test needs a hook, for example an `EIDER_TEST_STACK_DISCARD_DELAY_US` that sleeps just before the `madvise` (harmless once the discard is before publishing, and widening the window if someone reorders them). The eider-http `server_test` loop above is the reliable reproducer.
- **TSan does not see this bug.** It passes with and without the fix.
- The earlier hand-off list of further CPU-per-request work (native head scan, buffer reuse, timer-heap avoidance, move instead of clone, edge-triggered epoll) is not part of this release.
