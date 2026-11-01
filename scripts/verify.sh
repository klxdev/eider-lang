#!/bin/sh
# Full verification matrix: compile-fail suite, run tests on gcc/clang/ASan+UBSan/TSan, std, export, wasm, the vendored libraries, and the sibling repositories (the editor tooling, eider-analyzer and tree-sitter-eider, and the libraries and frameworks, eider-json, eider-http, ...) when they are next to this one.
# The compiler is target/eiderc, built from the seed by scripts/ei (only a C compiler).
cd "$(dirname "$0")/.." || exit 1
EIDER_CACHE=off; export EIDER_CACHE
scripts/ei --help >/dev/null || { echo "FAIL build target/eiderc from seed/eiderc.c"; exit 3; }
EIDER=$(pwd)/target/eiderc; export EIDER
fail=0
"$EIDER" test --compile-fail tests/checks | tail -1 | grep -q " 0 failed" && echo "ok   compile-fail suite (eiderc)" || { echo "FAIL compile-fail"; fail=1; }
S=$(mktemp -d)
# sanitizer wrappers: gcc when its sanitizer runtimes are installed, otherwise clang's
san_cc() {
  for c in gcc clang; do
    printf 'int main(void){return 0;}\n' > $S/san.c
    command -v $c >/dev/null && $c -fsanitize=$1 -o $S/san $S/san.c 2>/dev/null && $S/san && { echo $c; return; }
  done
  echo gcc
}
printf '#!/bin/sh\nexec %s -fsanitize=address,undefined -fno-sanitize-recover=undefined -Wpedantic "$@"\n' "$(san_cc address,undefined)" > $S/asan.sh
printf '#!/bin/sh\nexec %s -fsanitize=thread -Wpedantic "$@"\n' "$(san_cc thread)" > $S/tsan.sh
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
sh tests/packages.sh | grep -q FAIL && { echo "FAIL packages"; fail=1; } || echo "ok   packages (pkg with semver and sha256, doc, fuzz; the vendored toml, json, markdown)"
# vendor: each vendor/<name> is the release vendor/vendor.lock pins (content hash), and is
# byte-identical to that commit of its repository when the checkout is there (else that
# comparison is a skipped leg): scripts/vendor.sh check
sh scripts/vendor.sh check > $S/vendor 2>&1; vrc=$?
while IFS= read -r l; do case $l in "skip "*) skip "${l#skip }" ;; esac; done < $S/vendor
if [ $vrc != 0 ]; then echo "FAIL vendor: sh scripts/vendor.sh check"; grep -A4 "^FAIL" $S/vendor | head -20; fail=1
else echo "ok   vendor ($(grep -c '^ok' $S/vendor) pinned libraries: $(sed -n 's/^ok   vendor\/\([a-z0-9_]*\): \([^,(]*\).*/\2/p' $S/vendor | sed 's/ *$//' | paste -sd, - | sed 's/,/, /g'); $(grep -c 'byte-identical to' $S/vendor) compared with their repositories)"; fi
# the documentation site (target/site) and its doc tests: scripts/docs.sh, docs/site/CONTRACT.md
if sh scripts/docs.sh >$S/docs.log 2>&1 && sh scripts/docs.sh test >>$S/docs.log 2>&1; then echo "ok   docs (the site in target/site; $(tail -1 $S/docs.log))"; else echo "FAIL docs: sh scripts/docs.sh; sh scripts/docs.sh test"; tail -20 $S/docs.log; fail=1; fi
# crypto: the vectors on every backend available here (and the RFC vectors under ASan+UBSan),
# then the cross-backend checks. Each backend that isn't fetched or built is a skipped leg:
# a plain checkout has none (sh scripts/fetch-awslc.sh fetches the default; core/crypto/README.md).
sh tests/crypto/run.sh --san > $S/crypto 2>&1; crc=$?
while IFS= read -r l; do case $l in "skip "*) skip "${l#skip }" ;; esac; done < $S/crypto
nok=$(grep -c "^ok" $S/crypto)
if [ $crc != 0 ]; then
  echo "FAIL crypto: sh tests/crypto/run.sh"; grep "^FAIL" $S/crypto | head -5; fail=1
elif [ "$nok" -gt 0 ]; then
  echo "ok   crypto ($(grep -c '^ok   crypto rfc (' $S/crypto) backend(s): RFC/CAVP/Wycheproof vectors, ASan+UBSan, $(grep -c '^ok   crypto cross' $S/crypto) cross-backend checks)"
fi
sh tests/pkg/run.sh | grep -q FAIL && { echo "FAIL pkg"; fail=1; } || echo "ok   pkg (eider-pkg end to end, local git repos)"
# imports: no quoted imports are left but the tests of the quoted form (docs/compiler.md "C8.26")
sh scripts/check-imports.sh > $S/imports 2>&1 && cat $S/imports || { head -20 $S/imports; fail=1; }
sh scripts/version.sh check > $S/version 2>&1 && cat $S/version || { echo "FAIL version: sh scripts/version.sh check"; sed 's/^/  /' $S/version; fail=1; }
sh scripts/test-compiler.sh | grep -q FAIL && { echo "FAIL compiler (eiderc)"; fail=1; } || echo "ok   compiler (eiderc vs the recorded oracle, tests/oracle)"
sh scripts/selfhost.sh --from-seed >/dev/null 2>&1 && echo "ok   seed (seed/eiderc.c rebuilds itself with only a C compiler)" || { echo "FAIL seed: sh scripts/selfhost.sh --from-seed"; fail=1; }
bash tests/export/run.sh | tail -1 | grep -q "^ok" && echo "ok   export (C and C++ consumers)" || { echo "FAIL export"; fail=1; }
# tools: the sibling repositories (scripts/check-tools.sh; EIDER_<NAME>, else
# $EIDER_SIBLINGS/<name>, default ../<name>): the editor tooling (eider-analyzer,
# tree-sitter-eider) and the libraries and frameworks (eider-toml, eider-json,
# eider-markdown, eider-http, eider-rpc, eider-openapi), built and tested against this
# checkout, and every sibling's VERSION has this MAJOR.MINOR (the `ok   versions:` line). A
# part whose repository or tool is missing is a skipped leg, so a plain checkout stays green.
sh scripts/check-tools.sh > $S/tools 2>&1; trc=$?
while IFS= read -r l; do case $l in "skip: "*) skip "tools: ${l#skip: }" ;; esac; done < $S/tools
if [ $trc != 0 ]; then
  echo "FAIL tools: sh scripts/check-tools.sh"; grep -A6 "^FAIL" $S/tools | head -20; fail=1
elif grep -q "^ok" $S/tools; then
  built=$(grep "^ok" $S/tools | grep -v "^ok   versions:" | sed -E 's/^ok +([a-z-]+).*/\1/' | paste -sd, - | sed 's/,/, /g')
  [ -n "$built" ] && echo "ok   tools: $built against this checkout"
  grep "^ok   versions:" $S/tools
fi
printf 'int x;\n' > $S/wasm.c
if "${WASM_CC:-clang}" --target=wasm32 -c -o $S/wasm.o $S/wasm.c 2>/dev/null && command -v wasm-ld >/dev/null && command -v node >/dev/null; then
  sh tests/wasm/run.sh || fail=1
else
  skip "wasm: needs clang with the wasm32 target, wasm-ld and node"
fi
rm -rf $S
if [ $fail = 0 ]; then
  if [ $skipped = 0 ]; then echo "ALL GREEN"; else echo "ALL GREEN ($skipped leg(s) skipped: install the missing toolchains for a full run)"; fi
fi
exit $fail
