# Pending signals in a guarded macOS main

This is a diagnostic regression, not a runtime fix. Run:

```sh
sh tests/core/signal-mask.sh
```

On the tested Apple Silicon Mac, the original C main thread delivers a self-sent USR1
after unblocking it. The same core calls inside `ei_main`'s guarded worker time out.
A standalone pthread C reproducer shows the same difference; the failure also occurs
outside the Codex sandbox. Linux validation of this focused regression is pending.

`ei_main` blocks signals in the original main thread while the guarded worker runs with
the caller's original mask. If all threads block a process-directed signal, Darwin appears
to associate its pending delivery with the original main thread. Unblocking only the worker
then does not deliver it there. That interpretation needs confirmation against Darwin's
signal contract before choosing a fix.

Keep both cases in the test: a fix must preserve deferred delivery, the portable signal
number, guarded-stack overflow handling and process-directed signal behavior. Replacing
`kill(getpid(), ...)` with `pthread_kill(pthread_self(), ...)` changes the delivery contract;
running the body directly on the original main thread changes its stack guarantees.
Neither is included as an unverified workaround here.
