#!/bin/sh
# Build an Eider library, link a C program against it (static and shared), compare output.
# EIDER=<compiler> picks the compiler (default: scripts/ei, the seed's eiderc).
cd "$(dirname "$0")/../.." || exit 1
E=${EIDER:-scripts/ei}
T=$(mktemp -d)
cp tests/export/mathlib.ei tests/export/driver.c "$T/"
$E build --lib "$T/mathlib.ei" -o "$T/mathlib" >/dev/null || { echo "FAIL build --lib"; exit 1; }
CC=${CC:-cc}
want="42
11
1
hello from eider
3"
$CC -std=c11 -Wall -I"$T" -o "$T/d_static" "$T/driver.c" "$T/libmathlib.a" || { echo "FAIL static link"; exit 1; }
got=$("$T/d_static")
[ "$got" = "$want" ] || { echo "FAIL static output: $got"; exit 1; }
$CC -std=c11 -Wall -I"$T" -o "$T/d_shared" "$T/driver.c" -L"$T" -lmathlib || { echo "FAIL shared link"; exit 1; }
got=$(LD_LIBRARY_PATH="$T" "$T/d_shared")
[ "$got" = "$want" ] || { echo "FAIL shared output: $got"; exit 1; }
# the header must also be valid C++
if command -v c++ >/dev/null; then
  printf '#include "mathlib.h"\nint main(){return eider_add(1,2)==3?0:1;}\n' > "$T/t.cpp"
  c++ -I"$T" -o "$T/d_cpp" "$T/t.cpp" "$T/libmathlib.a" || { echo "FAIL c++ link"; exit 1; }
  "$T/d_cpp" || { echo "FAIL c++ run"; exit 1; }
fi
# a trap inside the library terminates the process with exit code 101
cat > "$T/trap.c" <<'EOT'
#include "mathlib.h"
int main(void) { return eider_checked_div(1, 0); }
EOT
$CC -I"$T" -o "$T/d_trap" "$T/trap.c" "$T/libmathlib.a" && "$T/d_trap" 2>/dev/null
[ $? -eq 101 ] || { echo "FAIL trap exit code"; exit 1; }
echo "ok   tests/export (C and C++ consumers, static + shared)"
rm -rf "$T"
