#!/bin/sh
# The debugger printers (debug/eider_gdb.py) against fake gdb values shaped like the debug
# information llvm.ei emits (tests/debug/test_printers.py). No gdb or lldb is needed, and none
# is run: a real session is not tested here.
cd "$(dirname "$0")/../.." || exit 1
command -v python3 >/dev/null 2>&1 || { echo "skip debug printers: no python3"; exit 0; }
python3 -I tests/debug/test_printers.py debug/eider_gdb.py || exit 1
python3 -I -m py_compile debug/eider_lldb.py && echo "ok   debug lldb script compiles" || exit 1
rm -rf debug/__pycache__
# real gdb and lldb sessions (skipped, with the reason, when absent) need the compiler
[ -n "$1" ] && { sh tests/debug/session.sh "$1" || exit 1; }
