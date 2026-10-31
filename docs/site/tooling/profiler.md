# Profiler

Eider has a built-in profiler for CPU time, memory and waits. You build a program with
`--profile`, it writes a profile file, and the eider-profiler tool turns the file into
reports, flame graphs and diffs. It has two uses: profiling the language itself (the
compiler, std, the runtime) and profiling applications such as web services while they run.

## Quick start

```sh
eiderc run prog.ei --profile            # writes eider.prof when the program ends
eider-profiler report eider.prof        # top functions, allocations, copies, waits, leaks
eider-profiler flame eider.prof -o flame.html
```

Or in one step, with the tool building the program:

```sh
eider-profiler record -o prog.prof -- prog.ei arg1 arg2
```

`--profile` takes what to record: `--profile=cpu` (sampled time), `mem` (every allocation,
copy-on-write unshare, `.copy()`, List growth, Map rehash and Drop call, counted at its
source line, plus the live heap and leaks), `conc` (lock and channel waits, spawns). A bare
`--profile` is all three. A build without the flag is exactly the build you had: the
generated C and the runtime don't change.

## What a report shows

| Section | Read it as |
|---|---|
| Top functions by self / total time | self: the function was running; total: it was on the stack |
| Hot lines | the innermost positions, `file:line` |
| CPU by label | the share of each value of a label (`--by route`) |
| Allocation sites | allocations and bytes per line, and what is still live |
| Copy-on-write unshares | a shared String, List, Map or Box copied before a write: a value kept in two places and then changed |
| `.copy()` calls | where explicit copies are made, how often |
| List growth and Map rehashes | containers growing one doubling at a time |
| Drop calls | types with their own Drop being dropped |
| Lock waits, channel receive waits | contended Mutexes (and `sync.Lock`, which is a channel) with the time waited |
| Leaks at exit | blocks never freed after `main` returned |

A function that is straight-line code and calls nothing has no frame of its own: its time
and allocations count for its caller, at the line of the call.

## Profiling a service

Build the service with `--profile=cpu` (about 4% on a busy HTTP service; `mem` counts every
allocation exactly and costs more) and leave it on. Then capture when you need to:

- stop it: the profile is written at exit (`EIDER_PROF` names the file);
- `kill -USR2 <pid>`: the profile so far, while it keeps running;
- from the program: `profile.snapshot(path)`, `profile.reset()`, `profile.start()` and
  `profile.stop()` in [std/profile](api:std/profile);
- over HTTP, if you turn it on: packages/http's `profiling.mount(inout router, opts)` with
  `opts.enabled = true` serves `GET /debug/profile?seconds=N` and `GET /debug/heap`, to the
  local host only unless `opts.remote` is set.

Labels split a profile by request. `profiling.label_routes(inout router)` runs each route
under the labels `method` and `route` (the pattern, such as `/todos/:id`), on whichever pool
worker serves it; JSON-RPC calls get `rpc` with the method name. Your own code can add labels:

```eider,ignore
// needs a program built with --profile to record anything; without it this just runs the closure
let n = profile.with_label("job", "resize", || -> i64 { resize_all(images) })
```

Then `eider-profiler report svc.prof --by route` shows CPU per endpoint, and
`eider-profiler flame svc.prof --label route=/todos/:id -o todos.html` draws one endpoint.
`examples/kvstore` does all of this (`KVSTORE_PROFILING=1` turns the endpoints on), and
eider-profiler's `eider-loadgen` puts it under load.

> **Warning:** a profile names every function and file of the program. Keep the debug
> endpoints on the local host or behind authentication.

## Profiling the language

In an eider-lang checkout:

```sh
sh scripts/profile-compiler.sh                  # eiderc compiling itself, with a report and a flame graph
sh scripts/profile-compiler.sh --save-baseline  # before a change
sh scripts/profile-compiler.sh --check          # after it: fails if allocations or copies grew
PROFILE=1 sh scripts/bench.sh                   # a profile per benchmark in target/bench-prof
```

Allocation, copy and growth counts are deterministic for a deterministic input, so
`eider-profiler diff --check` can gate them with no tolerance; time is shown, never gated.

## Settings

| Variable | Meaning |
|---|---|
| `EIDER_PROF` | the profile file (default `eider.prof`), or `off` |
| `EIDER_PROF_HZ` | samples per second (default 99) |
| `EIDER_PROF_CLOCK` | `cpu` (default) or `wall` (also samples threads that are waiting) |
| `EIDER_PROF_START` | `0` to start with sampling off, for `profile.start()` |
| `EIDER_PROF_MEM_RATE` | bytes between sampled allocation stacks (default 524288) |

## The tool

| Command | What |
|---|---|
| `eider-profiler report <file> [--top N] [--label k=v] [--by key] [--json]` | the tables above |
| `eider-profiler flame <file> -o out.html [--kind K]` | an interactive flame graph in one self-contained file, for `cpu`, `alloc`, `cow`, `lock` and `recv` stacks |
| `eider-profiler folded <file> [--kind K] [--lines]` | folded stacks for other flame graph tools |
| `eider-profiler diff <a> <b> [--check] [--tolerance PCT]` | what changed; `--check` exits 1 on more allocations or copies |
| `eider-profiler record -- <prog.ei> [args]` | build with `--profile`, run, write the profile |
| `eider-profiler --version` | the tool's version: it goes with the Eider release of the same major.minor |

The file format (versioned JSON lines, documented so other tools can read it) and how the
profiler works inside are in the repository's `docs/runtime.md`, "Profiler".
