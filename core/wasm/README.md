# core/wasm: the WebAssembly backend of the core

`eiderc build --wasm` (and `--wasm-core`) builds a program for `wasm32` against this
directory instead of the native core: the LLVM backend's IR for wasm32. It is the second backend of the language runtime contract
(`core/RUNTIME.md`) and carries the few C library functions the runtime and generated code
need, because a WebAssembly module has no libc. WebAssembly is an optional target
(LAYERS.md, "Dependencies"): nothing here is needed to build the compiler or a native
program, and only `build --wasm` needs clang (with the wasm32 target) and `wasm-ld`.

| File | Role |
|---|---|
| `eider_rt.c` | `core/RUNTIME.md` for wasm32: the functions `core/eider_rt.h` declares (the header is shared, unchanged) |
| `libc.c` | the freestanding C library: exactly the functions in `include/`, plus `__multi3` |
| `include/*.h` | the C library headers generated code and `eider_rt.h` include: `stdio.h`, `stdlib.h`, `string.h`, `setjmp.h`, `inttypes.h`, and a types-only `pthread.h` |
| `host.h` | the host imports, shared by the two C files (not for generated code) |

Build (wasm.ei): `clang <features> -O2 -c -o prog_ll.o prog.ll`, then `clang <features>
-std=c11 -O2 -ffreestanding -nostdlib -fno-builtin -w -isystem core/wasm/include -I core
-Wl,--no-entry -Wl,--allow-undefined -o <name>.wasm prog.c prog_ll.o core/wasm/eider_rt.c
core/wasm/libc.c`, where `<features>` is `--target=wasm32-unknown-unknown -mcpu=mvp
-msign-ext -mbulk-memory -mmutable-globals`: the MVP plus sign extension, bulk memory
(memory.copy and memory.fill: libc's mem* functions are those instructions) and mutable
globals, nothing else (no SIMD, threads, multi-value or reference types). `stdint.h`, `stddef.h`, `stdarg.h`,
`stdbool.h` and `stdatomic.h` are the compiler's own freestanding headers.

Both C files build warning-free with `-std=c11 -pedantic -Wall -Wextra -Wconversion
-Wshadow` for wasm32, and with the host C compiler as `-fsyntax-only -nostdinc` against only
`include/` (`-DEI_WASM_SYNTAX_CHECK` stands in for the wasm builtins). `tests/wasm/core.sh`
checks both, and the emitted C of the wasm tests the same way.

## Host interface

Imports, all from module `env`. The JS loader `build --wasm` writes (`<name>.js`) supplies
both; a host that instantiates the module itself must too.

| Import | Signature (wasm) | Meaning |
|---|---|---|
| `eider_write(p, n)` | `(i32, i32) -> ()` | write bytes `[p, p+n)` of the exported memory. stdout and stderr both come here (the loader: `process.stdout.write`, else `console.log`) |
| `eider_now_ms()` | `() -> i64` | milliseconds on the host's clock (the loader: `Date.now()`) |

Every other function the module calls but does not define (an `extern "c"` function, or a
native core function `ec_*` reached through `std`) is also an import from `env`
(`--allow-undefined`), to be passed in the loader's `imports`. There is no wasm backend of
`core/ABI.md`: a module has no files, processes or environment of its own, nor sockets,
pollers, signals, OS randomness or clocks beyond `eider_now_ms`. A module that reaches one
fails to instantiate with a `LinkError` naming the `env.ec_*` import (core/ABI.md,
"WebAssembly").

Exports: `memory`, and `eider_<name>` for each `export fn`, whose parameters and result are
integers or `bool` (E0806). `i64`/`u64`/`usize` cross as `i64` (JavaScript `BigInt`), the
other integers and `bool` as `i32`.

## Memory model

- One linear memory, exported as `memory`. The heap starts at `__heap_base` (after the data
  and the stack, as `wasm-ld` lays them out) and grows with `memory.grow`.
- `malloc` hands out 16-byte aligned blocks with a 16-byte header, their sizes rounded up to
  a power of two (16 bytes to 2 GiB). Each size class has a free list, so `malloc` and
  `free` take constant time and at most half of a block goes unused; blocks are never split
  or merged and memory is never returned to the host. `realloc` keeps a block that is big
  enough, else moves it.
- Allocation failure (`memory.grow` refused, or a size that overflows) returns `NULL`; the
  runtime turns that into the `out of memory` trap, as natively.
- Single-threaded: there is no locking anywhere.

## Core modules

`eiderc build --wasm-core <file.ei> [-o out.wasm]` builds an ordinary program (with `main`)
as a *core module*: one whose only imports are the C core's functions, `env.ec_*` under
their core/ABI.md names. A host that links `core/eider_core.c` gives it files, arguments,
the environment, stdio, process spawning and clocks exactly as a native program has them;
`seed/wasm2c.c` is that host for the compiler's seed (seed/README.md). The same files,
with `-DEI_WASM_CORE`:

- `_start` (exported) runs the C `main` and exits through `ec_exit` with its result.
- Output (`printf`, traps) goes to `ec_write_fd` (1 or 2) through `ec_in_clear` and
  `ec_in_push`; exit and abort are `ec_exit`; a trap prints its message and exits with 101,
  as natively; `ei_now_ms` is `ec_time_mono_ns` in ms.
- The ABI functions that take or return pointers are defined in the module, not imported
  (a pointer into the module's memory means nothing to the host): `ec_str_len` and
  `ec_str_byte` read a literal in the module, and `ec_in_cstr` returns the module's copy of
  what `ec_in_clear`/`ec_in_push` sent to the host.
- 32 MiB of stack, placed first in memory (`--stack-first`), so an overflow is an
  out-of-bounds access, not corrupted data; the heap grows with `memory.grow` up to 4 GiB.
- Threads aren't available (as in any module); `test` blocks aren't run.

## Runtime behaviour (differences from core/eider_rt.c)

- **Traps**: `ei_trap` writes `eider: runtime error: <msg> (lib:<line>)` through
  `eider_write`, then executes `unreachable`: the call into the module throws (a
  `WebAssembly.RuntimeError` in JavaScript) instead of the process exiting with 101. The
  instance stays usable for further calls; memory a trapped call allocated is not freed.
  `exit`, `abort` and `longjmp` are `unreachable` too.
- **Clock**: `ei_now_ms` is the host clock in ms (`eider_now_ms`), not processor time.
- **Threads**: none. `ei_rc_*` count references and `ei_mutex_*` do nothing; `ei_thread_*`
  and `ei_chan_*` trap. The checker rejects every program that uses `spawn`, `Task`, `Mutex`
  or `Chan` (E0806), so generated code never calls them.
- **Output** is unbuffered: each `printf` reaches the host in 256-byte chunks, whatever its
  length. `fflush` does nothing.
- `printf` and friends implement only `%d %i %u %s %c %%` with the length modifiers `l`, `ll`
  and `z` (what the runtime uses).

## Unsupported

- `test` blocks: there is no `setjmp` (it returns 0 and `longjmp` traps), so `test --wasm`
  is not offered (`eiderc test` ignores `--wasm`).
- Strings, records, lists and other non-integer values across the boundary (E0806).
- Threads (E0806), files, processes, environment, arguments (no ABI.md backend; see above).
- Unsigned results above the signed range come back negative in JavaScript (`u32` as a
  negative number, `u64`/`usize` as a negative BigInt): the loader passes the raw wasm values
  through (kept for byte-identity with the recorded oracle; a C8 candidate,
  docs/compiler.md).
- An export parameter named `x` breaks the loader (`x.eider_<name>(...)` inside an arrow
  function whose parameter shadows `x`). The loader text is kept byte-identical
  with the recorded oracle; fixing it is a C8 candidate (docs/compiler.md).

## Compared with the recorded behaviour

The recorded oracle (`tests/oracle/compiler/tests/wasm/`) was produced with a smaller shim
pasted into every build. Differences, all fixes:

- printf formatted into a 512-byte buffer and silently dropped the rest of longer output
  (`compiler/tests/wasm/long.ei`).
- `%l`/`%z` always read a 64-bit argument; on wasm32 `long` and `size_t` are 32-bit.
- `clock()` returned the host's `Date.now()` as a 32-bit `long`, which overflows, so
  `now_ms()` was garbage; the runtime now reads `eider_now_ms` as 64 bits.
- `malloc` rounded the size up without an overflow check (a huge request wrapped to a tiny
  block), and did not check the bump pointer for overflow.
- New: `inttypes.h`, a types-only `pthread.h` (the self-hosted compiler's generated C
  includes `eider_rt.h`, which needs both), and `__multi3`, which clang calls for 64-bit
  overflow checks and `-nostdlib` would otherwise leave as an unresolved import.
