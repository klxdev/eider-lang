#!/bin/sh
# `eiderc run --watch` and `eiderc test --watch` (compiler/watch.ei, docs/site/tooling/compiler.md "Watching"):
#   run:  the program starts; changing a module it imports stops it (SIGTERM: the old process is gone) and starts the
#         new build; a build error waits for the next change, which fixes it; SIGTERM to the watch ends it (143)
#         and the program with it;
#   test: the tests run, a change runs them again (FAILED, then ok), SIGINT ends the watch (130).
# The fixtures are copied to target/watchtest first, since the test edits them.
# usage: run.sh <eiderc>
cd "$(dirname "$0")/../.." || exit 1
E=$1
case "$E" in /*) ;; *) E=$(pwd)/$E ;; esac
T=$(pwd)/target/watchtest
rm -rf "$T"
mkdir -p "$T"
cp -R tests/watch/app.ei tests/watch/t.ei tests/watch/sub "$T/"
fail=0
# wait (up to 120 s) until file $1 contains the text $2
await() {
  i=0
  while [ $i -lt 600 ]; do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.2
    i=$((i + 1))
  done
  echo "FAIL watch: timed out waiting for '$2' in $1:"
  sed 's/^/    /' "$1" | head -20
  fail=1
  return 1
}
cd "$T" || exit 1

# ---- run --watch
"$E" run --watch app.ei -- pidfile > out.txt 2> err.txt &
W=$!
await out.txt v1
p1=$(cat pidfile 2>/dev/null)
[ -n "$p1" ] || { echo "FAIL watch: no pid file"; fail=1; }
# a change in an imported module: the old program is stopped, the new one runs
sleep 1
printf 'pub fn msg() -> str { "v2" }\n' > sub/msg.ei
await out.txt v2
await err.txt "msg.ei changed"
if [ -n "$p1" ] && kill -0 "$p1" 2>/dev/null; then echo "FAIL watch: the old program ($p1) is still running"; fail=1; fi
p2=$(cat pidfile 2>/dev/null)
[ "$p1" != "$p2" ] || { echo "FAIL watch: the pid did not change"; fail=1; }
# a build error: reported, the watch waits, the next change fixes it
sleep 1
printf 'pub fn msg() -> str { 1 + }\n' > sub/msg.ei
await err.txt "the build failed; waiting for a change"
if [ -n "$p2" ] && kill -0 "$p2" 2>/dev/null; then echo "FAIL watch: the program is still running during a failed build"; fail=1; fi
sleep 1
printf 'pub fn msg() -> str { "v3" }\n' > sub/msg.ei
await out.txt v3
# SIGTERM ends the watch with 143, and the program
p3=$(cat pidfile 2>/dev/null)
kill -TERM $W
wait $W
code=$?
[ $code = 143 ] || { echo "FAIL watch: SIGTERM to the watch exits $code, not 143"; fail=1; }
sleep 0.5
if [ -n "$p3" ] && kill -0 "$p3" 2>/dev/null; then echo "FAIL watch: the program ($p3) outlived the watch"; fail=1; kill -9 "$p3" 2>/dev/null; fi
echo "watch: run --watch (restart on a change in an import, build error, SIGTERM)"

# ---- test --watch
"$E" test --watch t.ei > tout.txt 2> terr.txt &
W=$!
await tout.txt FAILED
await terr.txt "waiting for a change"
sleep 1
printf 'pub fn answer() -> i32 { 42 }\n' > sub/answer.ei
await tout.txt "1 tests, 0 failed"
kill -INT $W
wait $W
code=$?
[ $code = 130 ] || { echo "FAIL watch: SIGINT to the test watch exits $code, not 130"; fail=1; }
echo "watch: test --watch (rerun on a change, SIGINT)"

# ---- the options
"$E" run --watch --lib t.ei > /dev/null 2>&1; [ $? = 2 ] || { echo "FAIL watch: --watch --lib is not a usage error"; fail=1; }
"$E" check --watch t.ei > /dev/null 2>&1; [ $? = 2 ] || { echo "FAIL watch: check --watch is not a usage error"; fail=1; }
"$E" run --no-opt t.ei > /dev/null 2>&1; [ $? = 2 ] || { echo "FAIL watch: run --no-opt is not a usage error"; fail=1; }
cd "$OLDPWD" || exit 1
[ $fail = 0 ] && { echo "ok   watch (run --watch, test --watch)"; rm -rf "$T"; }
exit $fail
