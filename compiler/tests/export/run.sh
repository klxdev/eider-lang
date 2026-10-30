#!/bin/sh
# eiderc's library tests (scripts/test-compiler.sh, "export"): `eiderc build --lib` of
# shapes.ei and nested.ei, linked statically into consumer.c; both headers compile as C11
# and as C++; a trap inside a library exits 101; and the headers' prototypes agree with
# the functions the libraries define. usage: run.sh <eiderc>
cd "$(dirname "$0")/../../.." || exit 1
E=$1
CC=${CC:-cc}
T=target/exporttest
rm -rf $T
mkdir -p $T
for l in shapes nested; do
  $E build --lib compiler/tests/export/$l.ei -o $T/$l >$T/$l.log 2>&1 || { echo "FAIL build --lib $l"; cat $T/$l.log; exit 1; }
  [ "$(cat $T/$l.log)" = "built $T/lib$l.a, $T/lib$l.so, $T/$l.h" ] || { echo "FAIL build --lib $l message: $(cat $T/$l.log)"; exit 1; }
  for x in c c++; do
    if [ $x = c ]; then cmd="$CC -std=c11 -pedantic -Wall -Wextra -Werror -x c"; else command -v c++ >/dev/null || continue; cmd="c++ -Wall -Wextra -Werror -x c++"; fi
    printf '#include "%s.h"\nint main(void) { return 0; }\n' $l >$T/h_$l.src
    $cmd -I$T -o $T/h_$l $T/h_$l.src || { echo "FAIL $l.h is not valid $x"; exit 1; }
  done
done
want="12
1 12 1
7
shapes
0 42
4 3 5"
$CC -std=c11 -Wall -Werror -I$T -o $T/consumer compiler/tests/export/consumer.c $T/libshapes.a $T/libnested.a || { echo "FAIL static link"; exit 1; }
got=$($T/consumer)
[ "$got" = "$want" ] || { echo "FAIL consumer output:"; echo "$got"; exit 1; }
$CC -std=c11 -Wall -Werror -I$T -o $T/consumer_so compiler/tests/export/consumer.c -L$T -lshapes -lnested || { echo "FAIL shared link"; exit 1; }
got=$(LD_LIBRARY_PATH=$T $T/consumer_so)
[ "$got" = "$want" ] || { echo "FAIL shared consumer output:"; echo "$got"; exit 1; }
printf '#include <stdint.h>\nint32_t eider_crash(int32_t);\nint main(void) { return eider_crash(0); }\n' >$T/trap.c
$CC -o $T/trap $T/trap.c $T/libnested.a || { echo "FAIL trap link"; exit 1; }
$T/trap 2>$T/trap.err
code=$?
[ $code -eq 101 ] || { echo "FAIL trap exit code $code"; exit 1; }
grep -q 'division by zero (lib:' $T/trap.err || { echo "FAIL trap message: $(cat $T/trap.err)"; exit 1; }
rm -rf $T
echo "ok   export: eiderc build --lib (records, nested records, an imported module's export, externs inside exports; C and C++ headers; static + shared; traps exit 101)"
