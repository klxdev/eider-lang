#!/bin/sh
# Full verification matrix: compile-fail suite, run tests on gcc/clang/ASan+UBSan/TSan, std, export, wasm.
cd "$(dirname "$0")/.." || exit 1
EIDER=$(scripts/stage0.sh) || exit 3; export EIDER
EIDER_CACHE=off; export EIDER_CACHE
fail=0
"$EIDER" test --compile-fail tests/checks | tail -1 | grep -q " 0 failed" && echo "ok   compile-fail suite (stage 0)" || { echo "FAIL compile-fail"; fail=1; }
S=$(mktemp -d)
printf '#!/bin/sh\nexec gcc -fsanitize=address,undefined -fno-sanitize-recover=undefined -Wpedantic "$@"\n' > $S/asan.sh
printf '#!/bin/sh\nexec gcc -fsanitize=thread -Wpedantic "$@"\n' > $S/tsan.sh
chmod +x $S/*.sh
# A missing toolchain is reported as `skip` with the reason, never as a pass; the final line
# says how many legs were skipped so a partial run can't be mistaken for a full one.
skipped=0
skip() { echo "skip $1"; skipped=$((skipped + 1)); }
# can this C compiler (wrapper) build and run a trivial program?
works() { printf 'int main(void){return 0;}\n' > $S/probe.c && $1 -o $S/probe $S/probe.c 2>/dev/null && $S/probe; }
for cc in gcc clang $S/asan.sh $S/tsan.sh; do
  name=$(basename $cc .sh)
  if ! works $cc; then skip "run tests ($name): toolchain not available"; continue; fi
  n=$(CC=$cc bash tests/run.sh 2>&1 | grep -vc "^ok")
  [ "$n" = 0 ] && echo "ok   run tests ($name)" || { echo "FAIL run tests ($cc)"; fail=1; }
done
sh tests/core/run.sh | grep -q FAIL && { echo "FAIL core"; fail=1; } || echo "ok   core (eider_rt + eider_core, strict warnings, sanitizers when available)"
sh tests/std/run.sh | grep -q FAIL && { echo "FAIL std"; fail=1; } || echo "ok   std (C core + Eider std)"
sh tests/packages.sh | grep -q FAIL && { echo "FAIL packages"; fail=1; } || echo "ok   packages (toml, semver, sha256)"
sh tests/pkg/run.sh | grep -q FAIL && { echo "FAIL pkg"; fail=1; } || echo "ok   pkg (eider-pkg end to end, local git repos)"
sh scripts/test-compiler.sh | grep -q FAIL && { echo "FAIL compiler (eiderc)"; fail=1; } || echo "ok   compiler (eiderc vs bootstrap)"
bash tests/export/run.sh | tail -1 | grep -q "^ok" && echo "ok   export (C and C++ consumers)" || { echo "FAIL export"; fail=1; }
if command -v "${WASM_CC:-clang}" >/dev/null && command -v wasm-ld >/dev/null && command -v node >/dev/null; then
  sh tests/wasm/run.sh || fail=1
else
  skip "wasm: needs clang with the wasm32 target, wasm-ld and node"
fi
rm -rf $S
if [ $fail = 0 ]; then
  if [ $skipped = 0 ]; then echo "ALL GREEN"; else echo "ALL GREEN ($skipped leg(s) skipped: install the missing toolchains for a full run)"; fi
fi
exit $fail
