#!/bin/sh
# Real debugger sessions on compiler/tests/llvm/dwarf.ei built with -g at -O0: gdb with
# debug/eider_gdb.py and lldb with debug/eider_lldb.py break on .ei lines (marked BREAK-* in
# the file) in a closure, a generic function, a function taking an enum and main, list the
# locals, print a backtrace and print a String, a List, a Map, an enum and a record. Each
# debugger is skipped, with the reason, when it is not installed.
# usage: session.sh <eiderc>
cd "$(dirname "$0")/../.." || exit 1
E=$1
case "$E" in /*) ;; *) E=$(pwd)/$E ;; esac
T=target/debugtest
rm -rf $T
mkdir -p $T
fail=0
have_gdb=0; have_lldb=0
command -v gdb >/dev/null 2>&1 && have_gdb=1
command -v lldb >/dev/null 2>&1 && have_lldb=1
[ $have_gdb = 0 ] && echo "skip debug gdb: gdb is not installed"
[ $have_lldb = 0 ] && echo "skip debug lldb: lldb is not installed"
[ $have_gdb = 0 ] && [ $have_lldb = 0 ] && exit 0
EIDER_CACHE=off EIDER_CFLAGS=-O0 $E build -g compiler/tests/llvm/dwarf.ei -o $T/dwarf >$T/build.log 2>&1 || { echo "FAIL debug sessions: build -g dwarf.ei"; cat $T/build.log; exit 1; }
F=compiler/tests/llvm/dwarf.ei
line() { grep -n "BREAK-$1" $F | head -1 | cut -d: -f1; }
LA=$(line AREA); LG=$(line GENERIC); LC=$(line CLOSURE); LM=$(line MAIN)
# what the stops must show: the closure (v, next), the generic (once, and twice in the
# backtrace), area (the enum and the record inside it) and main (List, Map, record, String)
check() { # name out want...
  name=$1; out=$2; shift 2
  ok=1
  for want in "$@"; do
    grep -q -- "$want" $out || { echo "FAIL debug $name: no '$want' in the session ($out)"; ok=0; fail=1; }
  done
  [ $ok = 1 ] && echo "ok   debug $name: .ei breakpoints in a closure, a generic, an enum and main; locals, bt, String, List, Map, enum, record"
}
if [ $have_gdb = 1 ]; then
  gdb -batch -nx -ex "set debuginfod enabled off" \
    -ex "source debug/eider_gdb.py" \
    -ex "break $F:$LC" -ex "break $F:$LG" -ex "break $F:$LA" -ex "break $F:$LM" \
    -ex run -ex "info locals" -ex bt \
    -ex continue -ex "info locals" -ex bt \
    -ex continue -ex "info locals" \
    -ex continue -ex "info locals" -ex "print shape_arg" -ex "print acc_total" -ex "up" -ex "print origin_pt" \
    -ex continue -ex "info locals" -ex "print names_list" -ex "print ages_map" -ex "print origin_pt" \
    $T/dwarf >$T/gdb.out 2>&1
  check gdb $T/gdb.out "next" "v=40" "once = 41" "twice" "Circle = " "px = 4" "List\[String\] of length 1 = {\"a\"}" "Map\[String, i64\] of length 1"
fi
if [ $have_lldb = 1 ]; then
  lldb -b -o "command script import debug/eider_lldb.py" \
    -o "breakpoint set -f dwarf.ei -l $LC" -o "breakpoint set -f dwarf.ei -l $LG" -o "breakpoint set -f dwarf.ei -l $LA" -o "breakpoint set -f dwarf.ei -l $LM" \
    -o run -o "frame variable" -o bt \
    -o continue -o "frame variable" -o bt \
    -o continue -o "frame variable" \
    -o continue -o "frame variable shape_arg" -o "frame variable acc_total" -o "up" -o "frame variable origin_pt" \
    -o continue -o "frame variable names_list" -o "frame variable ages_map" -o "frame variable origin_pt" \
    $T/dwarf >$T/lldb.out 2>&1
  check lldb $T/lldb.out "next" "v = 40" "once = 41" "twice" "Circle" "px = 4" "length = 1" "\"a\""
fi
[ $fail = 0 ] && rm -rf $T
exit $fail
