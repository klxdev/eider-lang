# Cross-compiling: static Linux executables

```
eider build app.ei --target x86_64-linux-musl      # a static executable
eiderc build app.ei --target aarch64-linux-musl    # see "AArch64" below
```

`--target <triple>` builds the program for another Linux target as a **static executable**: no
interpreter and no shared libraries, so it runs on a host without the build machine's libc.
The supported triples are `x86_64-linux-musl` and `aarch64-linux-musl` (`x86_64-unknown-linux-musl`
and `aarch64-unknown-linux-musl` are accepted). It goes with `build` and `emit-llvm`; a program
built for another machine is not run by `run` or `test`, and `--lib`, `--wasm` and `--wasm-core`
have targets of their own.

## What the build host provides

Eider adds no tool of its own for this. `--target` is a pass-through to the clang that already
builds your programs:

- the IR is built with `clang --target=<triple>`, the C runtime with `$CC` (else `clang`, since
  `cc` may be gcc, which has no `--target`) and the same flags, and everything is linked with
  `-static -fuse-ld=lld`;
- `--sysroot=$EIDER_SYSROOT` is added when `$EIDER_SYSROOT` is set;
- the target is part of the build cache key (the flags are in the command line of each unit).

So the build host needs **clang 17 or newer, lld, and the musl libc for the target**: its headers
(`<sysroot>/usr/include`) and static libraries and start files (`<sysroot>/usr/lib`: `libc.a`,
`crt1.o`, `crti.o`, `crtn.o`). Any source works: a distribution's musl packages (`musl-devel`
and `musl-libc-static` on Fedora, `musl-dev` on Alpine, `musl-tools` on Debian), a musl.cc or
Zig sysroot, or a clang whose musl is installed where it looks. zig is one way to get a toolchain
(`CC="zig cc -target x86_64-linux-musl" EIDER_LLVM_CC=...`, as `scripts/release.sh` does), not a
requirement.

A program that imports `core/crypto` links a crypto backend built for the host, which `--target`
does not rebuild; build it for the target and pass it with `-l` and `EIDER_CFLAGS` (`-L...`) until
the backends are built per target.

## What differs in a static musl binary

- `getaddrinfo` reads `/etc/hosts` and `/etc/resolv.conf` and asks DNS: there is no NSS (no
  `nsswitch.conf`, no mDNS, LDAP or other modules). `net.lookup` is affected.
- A thread's default stack is small (128 KiB in musl), and `malloc` is slower under several threads.
  Raise a thread's stack where a program needs it (the probe in `tests/cross` runs a task with the
  defaults).
- `dlopen` does not work in a static executable.

## AArch64

The compiler and the C runtime build and link for `aarch64-linux-musl` against musl's aarch64
headers and libraries. The link then needs the target's compiler runtime (the `__fixtfsi`-style
long-double helpers that musl's `printf` calls): LLVM's `compiler-rt` builtins for aarch64
(`--rtlib=compiler-rt`) or libgcc for the target, which clang does not ship for foreign targets,
so a plain clang on an x86-64 host fails with `unable to find library -lgcc` until you provide it
(through `EIDER_CFLAGS`, or a cross toolchain that includes it). A built aarch64 binary has not
been run by this repository's tests (there is no aarch64 machine or emulator in them).

On non-x86-64 targets the task runtime uses `ucontext`, which musl does not have; per #226 a musl
AArch64 program therefore runs its tasks as OS threads (not checked here). An AArch64 assembly
context switch (shared with the macOS/ARM work, #179) would remove that.

## Testing

`sh tests/cross/run.sh target/eiderc` (part of `scripts/verify.sh`) builds
`tests/cross/probe.ei`, which uses a thread, a TCP connection, a file and a child process, for
`x86_64-linux-musl`, checks that the executable has no interpreter and no `NEEDED` entries, and
runs it. It needs a musl sysroot in `$EIDER_SYSROOT` and is skipped, with that reason, without one.
