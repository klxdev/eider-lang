#!/bin/sh
# Full verification matrix: compile-fail suite, run tests on gcc/clang/ASan+UBSan/TSan, std, export, wasm.
cd "$(dirname "$0")/.." || exit 1
cargo build --quiet --manifest-path bootstrap/Cargo.toml --target-dir target 2>&1 | grep -E "^error" -A6
EIDER_CACHE=off; export EIDER_CACHE
fail=0
./target/debug/eider test --compile-fail tests/checks | tail -1 | grep -q " 0 failed" || { echo "FAIL compile-fail"; fail=1; }
S=$(mktemp -d)
printf '#!/bin/sh\nexec gcc -fsanitize=address,undefined -fno-sanitize-recover=undefined -Wpedantic "$@"\n' > $S/asan.sh
printf '#!/bin/sh\nexec gcc -fsanitize=thread -Wpedantic "$@"\n' > $S/tsan.sh
chmod +x $S/*.sh
for cc in gcc clang $S/asan.sh $S/tsan.sh; do
  n=$(CC=$cc bash tests/run.sh 2>&1 | grep -vc "^ok")
  [ "$n" = 0 ] && echo "ok   run tests ($(basename $cc))" || { echo "FAIL run tests ($cc)"; fail=1; }
done
sh tests/std/run.sh | grep -q FAIL && { echo "FAIL std"; fail=1; } || echo "ok   std (C core + Eider std)"
sh tests/packages.sh | grep -q FAIL && { echo "FAIL packages"; fail=1; } || echo "ok   packages (toml, semver, sha256)"
sh scripts/test-compiler.sh | grep -q FAIL && { echo "FAIL compiler (eiderc)"; fail=1; } || echo "ok   compiler (eiderc vs bootstrap)"
bash tests/export/run.sh | tail -1 | grep -q "^ok" || { echo "FAIL export"; fail=1; }
sh tests/wasm/run.sh || fail=1
rm -rf $S
[ $fail = 0 ] && echo "ALL GREEN"
exit $fail
