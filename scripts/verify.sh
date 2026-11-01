#!/bin/sh
# Full verification matrix: compile-fail suite, run tests on gcc/clang/ASan+UBSan/TSan, std, export, wasm, the vendored libraries, and the sibling repositories (the editor tooling, eider-analyzer and tree-sitter-eider, and the libraries and frameworks, eider-json, eider-http, ...) when they are next to this one.
# The compiler is target/eiderc (scripts/ei: the WebAssembly seed translated to C and built with
# only a C compiler, stage0, which with clang builds compiler/ natively; seed/README.md). The
# toolchain's own tools (eider-pkg, eider-doc, tests/crypto) need the pinned libraries in
# .vendor/, fetched on first use (scripts/vendor.sh: from the sibling checkouts, a mirror,
# the network or a tarball, hash-checked); without them their legs are skipped, with the reason.
cd "$(dirname "$0")/.." || exit 1
EIDER_CACHE=off; export EIDER_CACHE
scripts/ei --help >/dev/null || { echo "FAIL build target/eiderc from seed/eiderc.wasm"; exit 3; }
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
# vendor: the releases vendor.lock pins, fetched into .vendor/<name> and hash-checked
# (scripts/vendor.sh fetch; a hash mismatch fails), then scripts/vendor.sh check: the pins are
# well formed, each copy has its content hash and, when the library's checkout is there, the
# pinned commit has that hash and equals the copy byte for byte (else that comparison is a
# skipped leg). When no source has a pin (a fresh clone with no siblings and no network), the
# legs that need .vendor/ (docs, pkg, parts of packages, compiler, crypto and tools) are
# skipped with that reason.
novendor=
sh scripts/vendor.sh fetch > $S/vfetch 2>&1
case $? in
  0) ;;
  3) novendor="needs .vendor/, which can't be fetched: $(grep 'cannot fetch' $S/vfetch | sed 's/^vendor.sh: cannot fetch //; s/ (.*//' | paste -sd, - | sed 's/,/, /g') (no checkout, mirror or tarball, and no network; sh scripts/vendor.sh fetch)"
     skip "vendor fetch: $(grep 'cannot fetch' $S/vfetch | head -1 | sed 's/^vendor.sh: //')" ;;
  *) echo "FAIL vendor: sh scripts/vendor.sh fetch"; sed 's/^/  /' $S/vfetch | head -10; fail=1; novendor="needs .vendor/ (the fetch failed, above)" ;;
esac
sh scripts/vendor.sh check > $S/vendor 2>&1; vrc=$?
while IFS= read -r l; do case $l in "skip "*) skip "${l#skip }" ;; esac; done < $S/vendor
if [ $vrc != 0 ]; then echo "FAIL vendor: sh scripts/vendor.sh check"; grep -A4 "^FAIL" $S/vendor | head -20; fail=1
else echo "ok   vendor ($(grep -c '^ok' $S/vendor) pinned libraries: $(sed -n 's/^ok   vendor [a-z0-9_]*: \([^(]*\) (.*/\1/p' $S/vendor | sed 's/ *$//' | paste -sd, - | sed 's/,/, /g'); $(grep -c 'has the pinned hash\|byte-identical to' $S/vendor) hash-checked in .vendor/, $(grep -c 'byte-identical to\|pinned commit in' $S/vendor) against their repositories)"; fi
sh tests/packages.sh > $S/packages 2>&1
while IFS= read -r l; do case $l in "skip packages"*) skip "${l#skip }" ;; esac; done < $S/packages
grep -q FAIL $S/packages && { echo "FAIL packages"; grep -A6 '^FAIL' $S/packages | head -20; fail=1; } || echo "ok   packages (pkg with semver and sha256, doc, fuzz; the pinned toml, json, markdown)"
# the documentation site (target/site) and its doc tests: scripts/docs.sh, docs/site/CONTRACT.md
if [ -n "$novendor" ]; then skip "docs: eider-doc $novendor"
elif sh scripts/docs.sh >$S/docs.log 2>&1 && sh scripts/docs.sh test >>$S/docs.log 2>&1; then echo "ok   docs (the site in target/site; $(tail -1 $S/docs.log))"; else echo "FAIL docs: sh scripts/docs.sh; sh scripts/docs.sh test"; tail -20 $S/docs.log; fail=1; fi
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
# eider, the Eider command, end to end against fake signed releases (tests/eider/run.sh; it
# links a crypto backend and needs .vendor/: skipped without them)
if [ -n "$novendor" ]; then skip "eider: the eider command $novendor"
else
  sh tests/eider/run.sh > $S/eider 2>&1; erc=$?
  while IFS= read -r l; do case $l in "skip "*) skip "${l#skip }" ;; esac; done < $S/eider
  if [ $erc != 0 ]; then echo "FAIL eider: sh tests/eider/run.sh"; grep -A3 "^FAIL" $S/eider | head -20; fail=1
  else grep "^ok" $S/eider; fi
fi
if [ -n "$novendor" ]; then skip "pkg: eider-pkg $novendor"
else sh tests/pkg/run.sh | grep -q FAIL && { echo "FAIL pkg"; fail=1; } || echo "ok   pkg (eider-pkg end to end, local git repos)"; fi
# imports: no quoted imports are left but the tests of the quoted form (docs/compiler.md "C8.26")
sh scripts/check-imports.sh > $S/imports 2>&1 && cat $S/imports || { head -20 $S/imports; fail=1; }
# vendor-layout: vendored copies are in .vendor/ only; nothing mentions the layout before it (#130, C400)
sh scripts/check-vendor-layout.sh > $S/vlayout 2>&1 && cat $S/vlayout || { head -24 $S/vlayout; fail=1; }
sh scripts/version.sh check > $S/version 2>&1 && cat $S/version || { echo "FAIL version: sh scripts/version.sh check"; sed 's/^/  /' $S/version; fail=1; }
sh scripts/test-compiler.sh > $S/compiler 2>&1
while IFS= read -r l; do case $l in "skip "*".vendor/"*) skip "compiler: ${l#skip }" ;; esac; done < $S/compiler
grep -q FAIL $S/compiler && { echo "FAIL compiler (eiderc)"; grep -A6 '^FAIL' $S/compiler | head -20; fail=1; } || echo "ok   compiler (eiderc vs the recorded oracle, tests/oracle)"
# llvm: the backend's C ABI test, its coverage (no function of the run tests or of the compiler
# falls back to C) and its debug info (compiler/tests/llvm/run.sh; docs/compiler.md
# "Backends"); the run tests' outputs are checked against the oracle by the compiler leg; and
# the units through the cache (tests/units/run.sh, with the compiler built from compiler/;
# docs/compiler.md "C8.27: incremental builds").
sh compiler/tests/llvm/run.sh target/eiderc > $S/llvm 2>&1; lrc=$?
if [ $lrc = 2 ]; then
  skip "llvm: $(sed -n 's/^skip: //p' $S/llvm | head -1)"
elif [ $lrc != 0 ]; then
  echo "FAIL llvm: sh compiler/tests/llvm/run.sh"; grep "^FAIL" $S/llvm | head -5; fail=1
elif ! sh tests/units/run.sh target/eiderc-next > $S/llvmunits 2>&1; then
  echo "FAIL llvm: sh tests/units/run.sh"; tail -5 $S/llvmunits; fail=1
else
  echo "ok   llvm ($(grep '^ok' $S/llvm | sed 's/^ok   llvm //; s/:.*//' | paste -sd, - | sed 's/,/, /g'): $(sed -n 's/^ok   llvm coverage: //p' $S/llvm); $(sed 's/^ok   llvm units: /units: /' $S/llvmunits))"
fi
# seed: stage0 from seed/eiderc.wasm with only a C compiler, the seed current (it emits compiler/'s
# LLVM IR) and, with the clang that built it, rebuilt byte for byte (scripts/selfhost.sh
# --from-seed); seed/wasm2c.c's own tests (strict warnings, ASan+UBSan, instructions, a core
# module, fuzzing: seed/tests/run.sh)
sh scripts/selfhost.sh --from-seed > $S/seed 2>&1; src=$?
while IFS= read -r l; do case $l in "skip: "*) skip "seed: ${l#skip: }" ;; esac; done < $S/seed
if [ $src != 0 ]; then echo "FAIL seed: sh scripts/selfhost.sh --from-seed"; tail -5 $S/seed; fail=1
else echo "ok   seed (stage0 from seed/eiderc.wasm with only a C compiler, $(wc -c < seed/eiderc.wasm) bytes; current, $(grep -q 'byte for byte.*ok' $S/seed && echo 'rebuilt byte for byte' || echo 'IR-identical'))"; fi
sh seed/tests/run.sh target/eiderc > $S/w2c 2>&1; wrc=$?
while IFS= read -r l; do case $l in "skip "*) skip "${l#skip }" ;; esac; done < $S/w2c
if [ $wrc != 0 ]; then echo "FAIL wasm2c: sh seed/tests/run.sh"; grep -A5 "^FAIL" $S/w2c | head -12; fail=1
else echo "ok   wasm2c ($(grep -c '^ok' $S/w2c) checks: $(grep '^ok' $S/w2c | sed 's/^ok   wasm2c \([a-z ]*\):.*/\1/' | paste -sd, - | sed 's/,/, /g'))"; fi
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
