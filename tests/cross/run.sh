#!/bin/sh
# `eiderc build --target` (docs/site/tooling/cross.md): a program that uses std net, fs, child and
# threads is built as a static executable for x86_64-linux-musl and runs. Usage: sh tests/cross/run.sh <eiderc>
# The musl headers and libraries of the target are the build host's to provide: $EIDER_SYSROOT
# (a sysroot with usr/include and usr/lib) or a clang that finds them itself ($EIDER_CROSS_NOSYSROOT=1).
# Without them the build leg is skipped with the reason (exit 2 when nothing ran), never a pass.
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
eiderc=${1:-$root/target/eiderc}
case $eiderc in /*) ;; *) eiderc=$(pwd)/$eiderc ;; esac
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
fail=0
export EIDER_CACHE=off EIDER_ROOT=$root

# an unsupported target is a usage error (exit 2), before anything is built; no toolchain needed
"$eiderc" build "$here/probe.ei" --target riscv64-linux-musl -o "$work/x" > "$work/err" 2>&1; rc=$?
if [ $rc = 2 ] && grep -q "unsupported target" "$work/err"; then echo "ok   cross: an unsupported target is a usage error"
else echo "FAIL cross: --target riscv64-linux-musl: exit $rc"; head -3 "$work/err"; fail=1; fi
"$eiderc" run "$here/probe.ei" --target x86_64-linux-musl > "$work/err" 2>&1; rc=$?
if [ $rc = 2 ] && grep -q "goes with" "$work/err"; then echo "ok   cross: --target is for build and emit-llvm only"
else echo "FAIL cross: run --target: exit $rc"; head -3 "$work/err"; fail=1; fi

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
  echo "skip cross: the x86_64 run needs an x86_64 Linux host"; [ $fail = 0 ] && exit 0; exit 1
fi
if [ -z "${EIDER_SYSROOT:-}" ] && [ "${EIDER_CROSS_NOSYSROOT:-}" != 1 ]; then
  echo "skip cross: set EIDER_SYSROOT to an x86_64 musl sysroot (usr/include, usr/lib) to build and run"; [ $fail = 0 ] && exit 0; exit 1
fi
if ! "$eiderc" build "$here/probe.ei" --target x86_64-linux-musl -o "$work/probe" > "$work/build" 2>&1; then
  echo "FAIL cross: build --target x86_64-linux-musl"; tail -8 "$work/build"; exit 1
fi
if readelf -l "$work/probe" 2>/dev/null | grep -q INTERP || readelf -d "$work/probe" 2>&1 | grep -q NEEDED; then
  echo "FAIL cross: the executable is dynamically linked"; fail=1
elif ! "$work/probe" > "$work/out" 2>&1 || ! cmp -s "$work/out" "$here/probe.out"; then
  echo "FAIL cross: the static executable's output differs from tests/cross/probe.out"; diff "$work/out" "$here/probe.out" | head -5; fail=1
else
  echo "ok   cross: x86_64-linux-musl is a static executable (no interpreter, no NEEDED) that uses net, fs, child and threads"
fi
[ $fail = 0 ]
