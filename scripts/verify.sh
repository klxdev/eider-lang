#!/bin/sh
# Full verification matrix: compile-fail suite, run tests on gcc/clang/ASan+UBSan/TSan, std, export, wasm, the vendored libraries, and the sibling repositories (the editor tooling, eider-analyzer and tree-sitter-eider, and the libraries and frameworks, eider-json, eider-http, ...) when they are next to this one.
# The compiler is target/eiderc (scripts/ei: the WebAssembly seed translated to C and built with
# only a C compiler, stage0, which with clang builds compiler/ natively; seed/README.md). The
# toolchain's own tools (eider-pkg, eider-doc, tests/crypto) need the pinned libraries in
# .vendor/, fetched on first use (scripts/vendor.sh: from the sibling checkouts, a mirror,
# the network or a tarball, hash-checked); without them their legs are skipped, with the reason.
#
# The legs run in parallel (#134): each is `sh scripts/verify.sh --leg <name>`, with a scratch
# directory of its own, and at most $VERIFY_JOBS run at once (default: the CPUs, at most 8;
# VERIFY_JOBS=1 is the serial run). Their output is printed in the fixed order of $LEGS below, so
# a parallel run reads like a serial one, and each leg's wall time is in the `legs:` line at the
# end. Legs that share a fixed directory under target/ (compiler -> llvm -> wasm: eiderc-next;
# docs -> packages: eider-doc) are one leg each. `VERIFY_ONLY="std core"` runs just those legs.
# A failing leg keeps its output under target/verify/ (#210): <leg>.out is everything the leg
# printed, and the legs that print only a summary line for a suite (run tests, core, std, pkg,
# export) keep the suite's full output in target/verify/<leg>.log, named in the FAIL line, so a
# failure that does not come back can still be diagnosed. A leg that passes removes its files.
# A green run (ALL GREEN) is recorded for this commit, the siblings' commits and the toolchain
# (scripts/verify-stamp.sh), so that scripts/release.sh and publish.sh don't repeat it.
cd "$(dirname "$0")/.." || exit 1
EIDER_CACHE=off; export EIDER_CACHE
LEGS="compiler llvms seed tools tsan asan gcc clang docs eider crypto pkg std core misc export"

# ---- one leg: prints its `ok`/`FAIL`/`skip` lines. Legs never touch each other's files.
if [ "$1" = "--leg" ]; then
  leg=$2
  EIDER=$(pwd)/target/eiderc; export EIDER
  S=$(mktemp -d)
  trap 'rm -rf "$S"' EXIT
  # A missing toolchain is reported as `skip` with the reason, never as a pass.
  skip() { echo "skip $1"; }
  # keep FILE NAME: FILE (a suite's full output) as target/verify/NAME.log; says where
  keep() { mkdir -p target/verify && cp "$1" "target/verify/$2.log" && echo "     full output: target/verify/$2.log"; }
  # sanitizers are clang flags (EIDER_CFLAGS reaches clang for the IR and $CC for the core and the
  # link): clang links them when it has their runtimes, else gcc's
  san_cc() {
    for c in clang gcc; do
      printf 'int main(void){return 0;}\n' > $S/san.c
      command -v $c >/dev/null && $c -fsanitize=$1 -o $S/san $S/san.c 2>/dev/null && $S/san && { echo $c; return; }
    done
    echo clang
  }
  # can this C compiler build and run a trivial program with these flags?
  works() { printf 'int main(void){return 0;}\n' > $S/probe.c && $1 $2 -o $S/probe $S/probe.c 2>/dev/null && $S/probe; }
  # the run tests with $CC linking (gcc, clang), then under ASan+UBSan and TSan; the
  # sanitizer legs run the programs at -O0 (the `run` default): the sanitizers find the same
  # bugs, and the programs build faster
  runtests() {
    case $1 in
      gcc|clang) cc=$1; fl= ;;
      asan) cc=$(san_cc address,undefined); fl="-fsanitize=address,undefined -fno-sanitize-recover=undefined" ;;
      tsan) cc=$(san_cc thread); fl="-fsanitize=thread" ;;
    esac
    if ! works $cc "$fl"; then skip "run tests ($1): toolchain not available"; return; fi
    CC=$cc EIDER_CFLAGS="$fl" bash tests/run.sh > $S/runtests 2>&1
    n=$(grep -vc "^ok" $S/runtests)
    [ "$n" = 0 ] && echo "ok   run tests ($1)" || { echo "FAIL run tests ($1: CC=$cc EIDER_CFLAGS=$fl)"; keep $S/runtests run-$1; }
  }
  # the vendored libraries: set by the caller (the parallel driver fetches them once)
  novendor=${VERIFY_NOVENDOR:-}
  case $leg in
  compiler)
    "$EIDER" test --compile-fail tests/checks | tail -1 | grep -q " 0 failed" && echo "ok   compile-fail suite (eiderc)" || echo "FAIL compile-fail"
    EIDERC=$(pwd)/target/eiderc-next sh scripts/test-compiler.sh > $S/compiler 2>&1; crc=$?
    while IFS= read -r l; do case $l in "skip "*".vendor/"*) skip "compiler: ${l#skip }" ;; esac; done < $S/compiler
    if grep -q FAIL $S/compiler || [ $crc != 0 ]; then echo "FAIL compiler (eiderc; exit $crc)"; grep -A6 '^FAIL' $S/compiler | head -20; tail -3 $S/compiler; else echo "ok   compiler (eiderc vs the recorded oracle, tests/oracle)"; fi
    # lint: the compiler's own package is held to its [lints] (eiderc lint, compiler/eider.toml:
    # a declared capability the code never needs is denied), by the compiler just built
    if target/eiderc-next lint compiler/main.ei > $S/lint 2>&1; then echo "ok   lint (compiler/: unused_uses denied)"; else echo "FAIL lint: target/eiderc-next lint compiler/main.ei"; grep -B1 -A4 '^error' $S/lint | head -20; fi
    # llvm: the backend's C ABI test, its AArch64 signatures and its debug info
    # (compiler/tests/llvm/run.sh; docs/compiler.md "Backends"); the run tests' outputs are checked
    # against the oracle by the compiler leg; and
    # the units through the cache (tests/units/run.sh, with the compiler built from compiler/;
    # docs/compiler.md "C8.27: incremental builds"). Both use target/eiderc-next, which
    # test-compiler.sh builds, so they follow it.
    sh compiler/tests/llvm/run.sh target/eiderc > $S/llvm 2>&1; lrc=$?
    if [ $lrc = 2 ]; then
      skip "llvm: $(sed -n 's/^skip: //p' $S/llvm | head -1)"
    elif [ $lrc != 0 ]; then
      echo "FAIL llvm: sh compiler/tests/llvm/run.sh"; grep "^FAIL" $S/llvm | head -5
    elif ! sh tests/units/run.sh target/eiderc-next > $S/llvmunits 2>&1; then
      echo "FAIL llvm: sh tests/units/run.sh"; tail -5 $S/llvmunits
    else
      echo "ok   llvm ($(grep '^ok' $S/llvm | sed 's/^ok   llvm //; s/:.*//' | paste -sd, - | sed 's/,/, /g'); $(sed 's/^ok   llvm units: /units: /' $S/llvmunits))"
    fi
    # eiderc fmt: idempotent over every .ei file, tokens and diagnostics unchanged, a layout fuzz
    sh tests/fmt/run.sh target/eiderc-next > $S/fmt 2>&1 && grep "^ok" $S/fmt || { echo "FAIL fmt: sh tests/fmt/run.sh"; grep -v "^fmt:" $S/fmt | head -12; }
    # eiderc run --watch and test --watch: restart on a change, stop the program, a build error, signals
    sh tests/watch/run.sh target/eiderc-next > $S/watch 2>&1 && grep "^ok" $S/watch || { echo "FAIL watch: sh tests/watch/run.sh"; cat $S/watch | head -12; }
    printf 'int x;\n' > $S/wasm.c
    if "${WASM_CC:-clang}" --target=wasm32 -c -o $S/wasm.o $S/wasm.c 2>/dev/null && command -v wasm-ld >/dev/null && command -v node >/dev/null; then
      sh tests/wasm/run.sh || echo "FAIL tests/wasm"
    else
      skip "wasm: needs clang with the wasm32 target, wasm-ld and node"
    fi ;;
  gcc|clang|asan|tsan) runtests $leg ;;
  llvms)
    # llvms: the compiler built, the compile-fail suite and the run tests with the other clang
    # versions the documentation claims (17, 20, 22, 23; the one on PATH is every other leg's):
    # scripts/clang-matrix.sh --quick --except-default (#169). The full matrix, with the oracle,
    # is `sh scripts/clang-matrix.sh` (about 14 minutes a version; 3 run before a release). A
    # version that isn't installed (sh scripts/clang-matrix.sh --fetch downloads them) is a
    # skipped leg with that reason, never a pass; EIDER_CLANG_VERIFY=0 leaves the leg out.
    if [ "${EIDER_CLANG_VERIFY:-1}" = 0 ]; then skip "llvms: EIDER_CLANG_VERIFY=0"; exit 0; fi
    sh scripts/clang-matrix.sh --quick --except-default > $S/llvms 2>&1; mrc=$?
    while IFS= read -r l; do case $l in "skip "*) skip "llvms: ${l#skip }" ;; "ok "*) echo "$l" ;; esac; done < $S/llvms
    if [ $mrc = 1 ] || grep -q "^FAIL" $S/llvms; then echo "FAIL llvms: sh scripts/clang-matrix.sh --quick"; grep -v "^ok\|^skip" $S/llvms | head -20
    elif [ $mrc != 0 ] && [ $mrc != 2 ]; then echo "FAIL llvms: sh scripts/clang-matrix.sh exit $mrc"; tail -5 $S/llvms; fi ;;
  core)
    sh tests/core/run.sh > $S/core 2>&1; crc=$?
    if grep -q FAIL $S/core || [ $crc != 0 ]; then echo "FAIL core (exit $crc): sh tests/core/run.sh"; grep -A3 FAIL $S/core | head -12; keep $S/core core
    else echo "ok   core (eider_rt + eider_core, strict warnings, sanitizers when available)"; fi ;;
  std)
    sh tests/std/run.sh > $S/std 2>&1
    if grep -q FAIL $S/std; then echo "FAIL std: sh tests/std/run.sh"; grep -A3 FAIL $S/std | head -12; keep $S/std std
    else echo "ok   std (C core + Eider std)"; fi ;;
  misc)
    # vendor: the releases vendor.lock pins, fetched into .vendor/<name> and hash-checked
    # (scripts/vendor.sh fetch, by the driver; a hash mismatch fails), then scripts/vendor.sh check: the pins are
    # well formed, each copy has its content hash and, when the library's checkout is there, the
    # pinned commit has that hash and equals the copy byte for byte (else that comparison is a
    # skipped leg). When no source has a pin (a fresh clone with no siblings and no network), the
    # legs that need .vendor/ (docs, pkg, parts of packages, compiler, crypto and tools) are
    # skipped with that reason.
    sh scripts/vendor.sh check > $S/vendor 2>&1; vrc=$?
    while IFS= read -r l; do case $l in "skip "*) skip "${l#skip }" ;; esac; done < $S/vendor
    if [ $vrc != 0 ]; then echo "FAIL vendor: sh scripts/vendor.sh check"; grep -A4 "^FAIL" $S/vendor | head -20
    else echo "ok   vendor ($(grep -c '^ok' $S/vendor) pinned libraries: $(sed -n 's/^ok   vendor [a-z0-9_]*: \([^(]*\) (.*/\1/p' $S/vendor | sed 's/ *$//' | paste -sd, - | sed 's/,/, /g'); $(grep -c 'has the pinned hash\|byte-identical to' $S/vendor) hash-checked in .vendor/, $(grep -c 'byte-identical to\|pinned commit in' $S/vendor) against their repositories)"; fi
    sh tests/packages.sh > $S/packages 2>&1
    while IFS= read -r l; do case $l in "skip packages"*) skip "${l#skip }" ;; esac; done < $S/packages
    grep -q FAIL $S/packages && { echo "FAIL packages"; grep -A6 '^FAIL' $S/packages | head -20; } || echo "ok   packages (pkg with semver and sha256, doc, fuzz; the pinned toml, json, markdown)"
    # imports: no quoted imports are left but the tests of the quoted form (docs/compiler.md "C8.26")
    sh scripts/check-imports.sh > $S/imports 2>&1 && cat $S/imports || { echo "FAIL imports"; head -20 $S/imports; }
    # vendor-layout: vendored copies are in .vendor/ only; nothing mentions the layout before it (#130, C400)
    sh scripts/check-vendor-layout.sh > $S/vlayout 2>&1 && cat $S/vlayout || { echo "FAIL vendor-layout"; head -24 $S/vlayout; }
    sh scripts/version.sh check > $S/version 2>&1 && cat $S/version || { echo "FAIL version: sh scripts/version.sh check"; sed 's/^/  /' $S/version; }
    # version bump (#205), against a copy of this checkout and fake siblings
    sh tests/version/run.sh > $S/versionbump 2>&1 && cat $S/versionbump || { echo "FAIL version bump: sh tests/version/run.sh"; head -20 $S/versionbump; }
    # the gdb and lldb printers (debug/), against fake values
    sh tests/debug/run.sh target/eiderc-next > $S/debug 2>&1 && cat $S/debug || { echo "FAIL debug printers: sh tests/debug/run.sh"; cat $S/debug; } ;;
  docs)
    # the documentation site (target/site) and its doc tests: scripts/docs.sh, docs/site/CONTRACT.md
    if [ -n "$novendor" ]; then skip "docs: eider-doc $novendor"
    elif sh scripts/docs.sh >$S/docs.log 2>&1 && sh scripts/docs.sh test >>$S/docs.log 2>&1; then echo "ok   docs (the site in target/site; $(tail -1 $S/docs.log))"; else echo "FAIL docs: sh scripts/docs.sh; sh scripts/docs.sh test"; tail -20 $S/docs.log; fi ;;
  crypto)
    # crypto: the vectors on every backend available here (and the RFC vectors under ASan+UBSan),
    # then the cross-backend checks. Each backend that isn't fetched or built is a skipped leg:
    # a plain checkout has none (sh scripts/fetch-awslc.sh fetches the default; core/crypto/README.md).
    sh tests/crypto/run.sh --san > $S/crypto 2>&1; crc=$?
    while IFS= read -r l; do case $l in "skip "*) skip "${l#skip }" ;; esac; done < $S/crypto
    nok=$(grep -c "^ok" $S/crypto)
    if [ $crc != 0 ]; then
      echo "FAIL crypto: sh tests/crypto/run.sh"; grep "^FAIL" $S/crypto | head -5
    elif [ "$nok" -gt 0 ]; then
      echo "ok   crypto ($(grep -c '^ok   crypto rfc (' $S/crypto) backend(s): RFC/CAVP/Wycheproof vectors, ASan+UBSan, $(grep -c '^ok   crypto cross' $S/crypto) cross-backend checks)"
    fi ;;
  eider)
    # eider, the Eider command, end to end against fake signed releases (tests/eider/run.sh; it
    # links a crypto backend and needs .vendor/: skipped without them)
    if [ -n "$novendor" ]; then skip "eider: the eider command $novendor"
    else
      sh tests/eider/run.sh > $S/eider 2>&1; erc=$?
      while IFS= read -r l; do case $l in "skip "*) skip "${l#skip }" ;; esac; done < $S/eider
      if [ $erc != 0 ]; then echo "FAIL eider: sh tests/eider/run.sh"; grep -A3 "^FAIL" $S/eider | head -20
      else grep "^ok" $S/eider; fi
    fi ;;
  pkg)
    if [ -n "$novendor" ]; then skip "pkg: eider-pkg $novendor"
    else
      EIDERC=$(pwd)/target/eiderc-next sh tests/pkg/run.sh > $S/pkg 2>&1
      if grep -q FAIL $S/pkg; then echo "FAIL pkg: sh tests/pkg/run.sh"; grep -A3 FAIL $S/pkg | head -12; keep $S/pkg pkg
      else echo "ok   pkg (eider-pkg end to end, local git repos)"; fi
    fi ;;
  seed)
    # seed: stage0 from seed/eiderc.wasm with only a C compiler, the seed current (it emits compiler/'s
    # LLVM IR) and, with the clang that built it, rebuilt byte for byte (scripts/selfhost.sh
    # --from-seed); seed/wasm2c.c's own tests (strict warnings, ASan+UBSan, instructions, a core
    # module, fuzzing: seed/tests/run.sh)
    sh scripts/selfhost.sh --from-seed > $S/seed 2>&1; src=$?
    while IFS= read -r l; do case $l in "skip: "*) skip "seed: ${l#skip: }" ;; esac; done < $S/seed
    if [ $src != 0 ]; then echo "FAIL seed: sh scripts/selfhost.sh --from-seed"; tail -5 $S/seed
    else echo "ok   seed (stage0 from seed/eiderc.wasm with only a C compiler, $(wc -c < seed/eiderc.wasm) bytes; current, $(grep -q 'byte for byte.*ok' $S/seed && echo 'rebuilt byte for byte' || echo 'IR-identical'))"; fi
    sh seed/tests/run.sh target/eiderc > $S/w2c 2>&1; wrc=$?
    while IFS= read -r l; do case $l in "skip "*) skip "${l#skip }" ;; esac; done < $S/w2c
    if [ $wrc != 0 ]; then echo "FAIL wasm2c: sh seed/tests/run.sh"; grep -A5 "^FAIL" $S/w2c | head -12
    else echo "ok   wasm2c ($(grep -c '^ok' $S/w2c) checks: $(grep '^ok' $S/w2c | sed 's/^ok   wasm2c \([a-z ]*\):.*/\1/' | paste -sd, - | sed 's/,/, /g'))"; fi ;;
  export)
    bash tests/export/run.sh > $S/export 2>&1
    if tail -1 $S/export | grep -q "^ok"; then echo "ok   export (C and C++ consumers)"; else echo "FAIL export: bash tests/export/run.sh"; tail -5 $S/export; keep $S/export export; fi ;;
  tools)
    # tools: the sibling repositories (scripts/check-tools.sh; EIDER_<NAME>, else
    # $EIDER_SIBLINGS/<name>, default ../<name>): the editor tooling (eider-analyzer,
    # tree-sitter-eider) and the libraries and frameworks (eider-toml, eider-json,
    # eider-markdown, eider-logging, eider-command, eider-http, eider-rpc, eider-openapi, eider-compression, eider-tls, eider-postgres), built and tested against this
    # checkout, and every sibling's VERSION has this MAJOR.MINOR (the `ok   versions:` line). A
    # part whose repository or tool is missing is a skipped leg, so a plain checkout stays green.
    sh scripts/check-tools.sh > $S/tools 2>&1; trc=$?
    while IFS= read -r l; do case $l in "skip: "*) skip "tools: ${l#skip: }" ;; esac; done < $S/tools
    if [ $trc != 0 ]; then
      echo "FAIL tools: sh scripts/check-tools.sh"; grep -A6 "^FAIL" $S/tools | head -20
    elif grep -q "^ok" $S/tools; then
      built=$(grep "^ok" $S/tools | grep -v "^ok   versions:" | sed -E 's/^ok +([a-z-]+).*/\1/' | paste -sd, - | sed 's/,/, /g')
      [ -n "$built" ] && echo "ok   tools: $built against this checkout"
      grep "^ok   versions:" $S/tools
    fi ;;
  *) echo "FAIL verify: no leg $leg"; exit 2 ;;
  esac
  exit 0
fi

# ---- the driver
scripts/ei --help >/dev/null || { echo "FAIL build target/eiderc from seed/eiderc.wasm"; exit 3; }
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT
fail=0
skipped=0
T0=$(date +%s)
# the pinned libraries, fetched once here (the legs that need them read $VERIFY_NOVENDOR)
VERIFY_NOVENDOR=
sh scripts/vendor.sh fetch > $R/vfetch 2>&1
case $? in
  0) ;;
  3) VERIFY_NOVENDOR="needs .vendor/, which can't be fetched: $(grep 'cannot fetch' $R/vfetch | sed 's/^vendor.sh: cannot fetch //; s/ (.*//' | paste -sd, - | sed 's/,/, /g') (no checkout, mirror or tarball, and no network; sh scripts/vendor.sh fetch)"
     echo "skip vendor fetch: $(grep 'cannot fetch' $R/vfetch | head -1 | sed 's/^vendor.sh: //')" > $R/prefix; skipped=$((skipped + 1)) ;;
  *) echo "FAIL vendor: sh scripts/vendor.sh fetch" > $R/prefix; sed 's/^/  /' $R/vfetch | head -10 >> $R/prefix
     VERIFY_NOVENDOR="needs .vendor/ (the fetch failed, above)"; fail=1 ;;
esac
export VERIFY_NOVENDOR
# build the tools several legs start from, once, before they run side by side
scripts/eider-pkg --version >/dev/null 2>&1
# target/eider and target/eider-sign (the eider leg, and tools through it), rebuilt when std/ or core/
# changed: not by two legs at once (a failure here is the eider leg's to report)
[ -z "$VERIFY_NOVENDOR" ] && sh scripts/eider --build-only >/dev/null 2>&1
# compiler/ built by the seed's compiler, target/eiderc-next: the compiler, llvm and pkg legs
# use it (test-compiler.sh would otherwise rebuild it under the others)
case " ${VERIFY_ONLY:-$LEGS} " in
  *" compiler "*|*" pkg "*)
    scripts/ei build compiler/main.ei -o target/eiderc-next >$R/next.log 2>&1 || { cat $R/next.log; echo "FAIL build target/eiderc-next from compiler/"; exit 3; } ;;
esac
JOBS=${VERIFY_JOBS:-$(n=$(nproc 2>/dev/null || echo 4); [ "$n" -gt 8 ] && n=8; echo "$n")}
RUN=${VERIFY_ONLY:-$LEGS}
# the files a failure of a leg of this run keeps (see the top); the stale ones of a pass go
mkdir -p target/verify
for l in $RUN; do rm -f target/verify/$l.out target/verify/$l.log target/verify/$l-*.log; done
# the longest legs first, so the shorter ones fill in behind them
for l in $RUN; do echo "$l"; done > $R/queue
cat > $R/one <<'EOF'
#!/bin/sh
# usage: one <scratch dir> <leg>: runs the leg, writing <dir>/<leg>.out, .rc and .secs
r=$1; l=$2
a=$(date +%s)
# a session of its own: some tests signal a whole process group, which must be the leg's
if command -v setsid >/dev/null 2>&1; then setsid sh scripts/verify.sh --leg "$l" > "$r/$l.out" 2>&1; else sh scripts/verify.sh --leg "$l" > "$r/$l.out" 2>&1; fi
echo $? > "$r/$l.rc"
b=$(date +%s)
echo $((b - a)) > "$r/$l.secs"
EOF
xargs -P "$JOBS" -I{} sh $R/one $R {} < $R/queue
[ -f $R/prefix ] && cat $R/prefix
times=
for l in $RUN; do
  cat $R/$l.out
  if [ "$(cat $R/$l.rc)" != 0 ]; then echo "FAIL verify leg $l did not finish (exit $(cat $R/$l.rc))"; fail=1; fi
  # a failing leg keeps what it printed (and, from inside the leg, the suite's full output)
  if [ "$(cat $R/$l.rc)" != 0 ] || grep -q "^FAIL" $R/$l.out; then cp $R/$l.out target/verify/$l.out; echo "     the leg's output: target/verify/$l.out"; fi
  times="$times $l=$(cat $R/$l.secs)s"
  grep -q "^FAIL" $R/$l.out && fail=1
  skipped=$((skipped + $(grep -c "^skip" $R/$l.out)))
done
T1=$(date +%s)
echo "legs:$times; $JOBS at a time, $((T1 - T0))s in all"
if [ $fail = 0 ]; then
  if [ $skipped = 0 ]; then echo "ALL GREEN"; else echo "ALL GREEN ($skipped leg(s) skipped: install the missing toolchains for a full run)"; fi
  # remember it for this commit (a partial VERIFY_ONLY run is not a verify)
  if [ -z "$VERIFY_ONLY" ]; then
    { for l in $RUN; do cat $R/$l.out; done; echo "ALL GREEN"; } > $R/green.log
    sh scripts/verify-stamp.sh write $R/green.log
  fi
fi
exit $fail
