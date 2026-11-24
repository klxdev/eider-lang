#!/bin/sh
# The FFI guard canary (docs/design/memory-safety.md S12, workstream F): builds tests/safety/ffi/bugs.c, a C library with
# deliberate overruns, links the Eider program against it and compares its output with overrun.out.
# Usage: sh tests/safety/ffi/run.sh [eiderc]   (default: scripts/ei)
cd "$(dirname "$0")/../../.." || exit 1
E=${1:-scripts/ei}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CC=${CC:-cc}
$CC -c -O1 -fPIC -o "$T/bugs.o" tests/safety/ffi/bugs.c && ar rcs "$T/libbugs.a" "$T/bugs.o" || { echo "FAIL safety ffi: cannot build bugs.c"; exit 1; }
if EIDER_CACHE=off EIDER_CFLAGS="-L$T" $E build tests/safety/ffi/overrun.ei -l bugs -o "$T/overrun" > "$T/build.log" 2>&1; then
  got=$("$T/overrun" 2>&1)
  if [ "$got" = "$(cat tests/safety/ffi/overrun.out)" ]; then echo "ok   safety ffi: an overrun by C is caught, correct C is not disturbed"; exit 0; fi
  echo "FAIL safety ffi: output differs"; echo "$got" | diff tests/safety/ffi/overrun.out - | head -12; exit 1
fi
echo "FAIL safety ffi: does not build"; head -8 "$T/build.log"; exit 1
