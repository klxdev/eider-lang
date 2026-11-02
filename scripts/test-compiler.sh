#!/bin/sh
# Tests for the self-hosted compiler (compiler/). Differential against a recorded oracle:
# tests/oracle/ holds the expected output for every input below (tests/oracle/README.md;
# docs/compiler.md, "Testing"), one file per (command, input) at
# tests/oracle/<source path without .ei>.<kind>. Output is compared with the checkout's
# root written `<root>`. BLESS=1 rewrites the oracle (and the goldens) from eiderc's output:
# that is how expected behaviour changes from now on, after reviewing the diff.
#
#   front:    for every .ei in the repo and in compiler/tests/{lex,parse}, eiderc's lex or
#             parse error (if any) must be the recorded one (X.front; no file: none).
#   lex_ok:   token dumps of compiler/tests/lex_ok/*.ei match their .tokens goldens
#   parse_ok: AST dumps of compiler/tests/parse_ok/*.ei match their .ast goldens
#   recover:  the recovering front end (lex.lex_all, parse.parse_all), run by
#             `eiderc parse --all-errors`: for compiler/tests/recover/*.src (programs
#             with several syntax errors; not .ei, so the front-end loop above skips them) every
#             diagnostic as JSON lines, then the AST dump with its error nodes, matches the
#             .recover golden; and for every file of the front-end loop its first diagnostic
#             is `eiderc parse`'s error, or with none the dump is `eiderc parse`'s.
#   ir:       IR dumps of compiler/tests/ir/*.ei match their .ir goldens.
#   multi:    compiler/tests/check/multi/*.ei have several independent errors: `check --json`
#             (one JSON line per diagnostic) and `check` (rendered diagnostics, the summary,
#             the --max-errors note) equal the oracle (X.check.json, X.check.err).
#   check:    for every compile-fail/pass test (tests/checks/{fail,pass}) whose features eiderc
#             supports (it doesn't answer `unsupported`), `eiderc check --json` must equal the
#             oracle (X.check.json) byte for byte; the same for tests/run/*.ei. eiderc's own
#             cases in compiler/tests/check/{fail,pass} must all be in scope and agree.
#   run:      every tests/run/*.ei and compiler/tests/run/*.ei that eiderc checks without
#             `unsupported` must give the recorded stdout, stderr and exit code under
#             `eiderc run` (X.run), and, if it has test blocks, under `eiderc test` (X.test).
#             (EIDER_CFLAGS=-Werror: the C core compiles warning-free too). Exception: a compiler/tests/run file with an X.out (and
#             X.test.out) next to it is a regression test for behaviour eiderc deliberately
#             fixed (LEARNINGS.md); it is compared with that hand-written
#             expected stdout instead (and must exit 0 with empty stderr).
#   sanitize: every run again at -O2 (the IR and the core) under UBSan in trap mode (-fsanitize=undefined
#             -fsanitize-undefined-trap-on-error, no runtime library needed); the output must
#             equal the plain run's. ASan and TSan run too when their runtimes are installed
#             (a test with `// nosan: thread` skips TSan: compiler/tests/run/stack_overflow_main.ei).
#   leaks:    every run again with -DEI_RT_COUNT_ALLOCS (the runtime counts live allocations
#             and generated main reports them when the program ends normally): a run that
#             exits 0 must report `eider: outstanding allocations: 0`, and apart from that
#             line the output must equal the plain run's.
#   determinism: `emit-llvm` of every run test twice, and once from a copy of the test
#             directory at another path (same relative file name), must be byte-identical.
#   names:    two functions with one C name (compiler/tests/lower/clash.ei) stop `emit-llvm`
#             with an internal error (exit 3) naming both.
#   export:   libraries from `eiderc build --lib`: tests/export/run.sh (C and C++ consumers)
#             with EIDER=eiderc, compiler/tests/export/run.sh (eiderc's own: more types,
#             nested records, two libraries, traps), and `check --lib --json`
#             (X.check-lib.json) and `emit-header` (X.emit-header) equal to the oracle.
#   wasm:     `check --wasm --json` and `emit-header --wasm` equal to the oracle
#             (X.check-wasm.json, X.emit-header-wasm) for tests/wasm and
#             compiler/tests/wasm{,/check} (`// mode: wasm` check tests use --wasm in the check
#             section); compiler/tests/wasm/run.sh: core/wasm is strict freestanding C, and
#             `build --wasm` modules give the recorded node output and
#             .d.ts/.js (skipped, with the reason, without clang's wasm32 target, wasm-ld or
#             node: WebAssembly is optional).
#   unit:     programs in compiler/tests/unit that drive a compiler module (sha256.ei) must
#             print their .out.
#   migration: the staged rewrites (scripts/migrate-imports.sh, migrate-caps.sh,
#             migrate-var.sh, migrate-imports-dotted.sh) on a copy of core, std, packages and
#             compiler check, pass the package tests, and give a compiler that emits the same
#             C (and whose own C, with every import dotted, is compiler/'s);
#             `eiderc migrate-var` of compiler/tests/migrate/*.ei equals the hand-checked .out;
#             `eiderc migrate-strings` of compiler/tests/migrate_strings/*.src likewise.
#   meaning:  tests/std, packages/*/tests and examples/*/tests give their .out when built by this
#             compiler (references by default) as well as by the seed (verify.sh); an
#             X.next.out is this compiler's expected output where it deliberately differs
#             from the seed's (it replaces X.out with the next seed).
#   audit-refs: `eiderc audit-refs --json` of compiler/tests/audit/*.ei equals the hand-checked
#             .out (the writes that change what a `let` reference sees).
#   packages: compiler/tests/pkgs, packages with eider.toml and eider.lock (two packages
#             with a util.ei, a dependency chain, vendored (.vendor/) and store dependencies, the
#             package-import errors E0808/E0809/E0810, capability grants and E0204, `eiderc
#             caps`): each `// pkgtest: <cmd>` file's
#             `eiderc <cmd>` output equals its X.out (BLESS=1 rewrites them; review by
#             hand), and the C of the app is the same from a copy at another path.
#   ide:      `eiderc ide` (ide.ei, the analysis API for language servers) of
#             compiler/tests/ide/*.ei matches the .ide goldens (BLESS=1 rewrites them; review
#             them by hand); a `// overlay: <path> <text file>` line in the file adds
#             `--overlay <path> <text file>`.
#   compile-fail: `eiderc test --compile-fail` prints exactly the recorded runner output, and
#             exits the same (<dir>.compile-fail), for compiler/tests/check and
#             compiler/tests/suite (the runner's own failure cases); for tests/checks it
#             reports 0 failed and every line but the `skip`s (features eiderc doesn't have)
#             and the coverage summary is the recorded one.
#   profile-off: without --profile, `emit-llvm` of every run test (also --test) and of the
#             compiler is byte-identical to that of the compiler of $PROFILE_OFF_REF (default:
#             the merge base with main) and has no profiler in it (zero cost).
#   profile:  compiler/tests/profile/*.ei built with --profile write the profile they should:
#             CPU samples under labels, allocation, copy-on-write, .copy(), growth, rehash and
#             Drop sites, lock and channel waits, spawns, a Ref conflict's trap, EIDER_PROF=off;
#             also under ASan+UBSan and TSan when they are installed.
#   cache:    EIDER_CACHE=<dir>: unit objects and linked programs, hits and misses, what the
#             keys cover, -j, concurrent runs and parallel builds into one cache, no work
#             directories left over, eviction (LRU trim, the automatic trim, clean, size).
#   doc:      `eiderc doc` of compiler/tests/doc/shapes (JSON, text, --private) and of one of
#             its files equals the goldens there; core, std and packages/* document cleanly.
#   usage:    `--help` lists every command and equals the oracle (X.help); unknown
#             options/commands, stray arguments, a bad `-j` or `cache` subcommand exit 2; `--version` and `version` print
#             `eiderc <VERSION>`; `run <file> [--] args...` passes the arguments to the program
#             (compiler/tests/driver/args.ei); an eiderc at <root>/bin/x/eiderc finds its
#             toolchain (toolchain.ei).
cd "$(dirname "$0")/.." || exit 1
mkdir -p target
# EIDERC=<binary> tests that compiler instead of target/eiderc-next, compiler/ as built by
# scripts/ei; scripts/selfhost.sh uses it for its stage 2.
if [ -n "$EIDERC" ]; then
  new=$EIDERC
else
  EIDER_CACHE=off scripts/ei build compiler/main.ei -o target/eiderc-next >/dev/null 2>target/eiderc.build.log || { cat target/eiderc.build.log; echo "FAIL build eiderc"; exit 1; }
  new=./target/eiderc-next
fi
# .vendor/: the pinned libraries packages/pkg and packages/doc depend on by path, fetched by
# scripts/vendor.sh (LAYERS.md, "Vendored libraries"). Without them (no checkout, mirror or
# tarball, and no network) the parts that build those packages are `skip` lines.
novendor=
sh scripts/vendor.sh fetch >target/vendor-fetch.log 2>&1
case $? in
  0) ;;
  3) novendor="needs .vendor/, and the pinned libraries can't be fetched (no checkout, mirror or tarball of $(grep 'cannot fetch' target/vendor-fetch.log | sed 's/^vendor.sh: cannot fetch //; s/ (.*//' | paste -sd, - | sed 's/,/, /g'), and no network; sh scripts/vendor.sh fetch)" ;;
  *) cat target/vendor-fetch.log; echo "FAIL vendor: sh scripts/vendor.sh fetch"; exit 1 ;;
esac
# needs_vendor <dir>: the package at <dir> depends on a pinned library and .vendor/ is missing
needs_vendor() { [ -n "$novendor" ] && grep -q '^path = "\.\./\.\./\.vendor/' "$1/eider.toml" 2>/dev/null; }
# the oracle (see the top): `oracle <source> <kind>` is the expected file of that (input,
# command); norm writes the checkout's root as <root>
O=tests/oracle
oracle() { echo "$O/${1%.ei}.$2"; }
rootre=$(pwd | sed 's/[]\/.[*^$|]/\\&/g')
norm() { sed "s|$rootre/|<root>/|g"; }
# want_of <source> <kind>: the expected text (a placeholder that never matches if there is
# no oracle file; BLESS=1 records one)
want_of() { p=$(oracle "$1" "$2"); if [ -f "$p" ]; then cat "$p"; else echo "(no oracle file $p)"; fi; }
# bless <source> <kind> <file>: under BLESS=1, make <file> the expected output
bless() {
  [ -n "$BLESS" ] || return 0
  p=$(oracle "$1" "$2")
  mkdir -p "$(dirname "$p")"
  cp "$3" "$p"
}
mkdir -p target/runtest
# the front end's diagnostics: E0001, E0002 (bitwise operators mixed without parentheses), plus the parser's E0302 for `inout` in a type and E0402
# for `null`, in the entry file
frontmsg='"error":"(E0001|E0002|E0402)"|"error":"E0302".*"message":"`inout` is only valid on function parameters'
front() {
  case "$1" in *"\"file\":\"$2\""*) ;; *) return ;; esac
  echo "$1" | grep -E "$frontmsg"
}
fail=0
n=0
for f in $(find . -name '*.ei' -not -path './target/*' -not -path './.claude/*' -not -path '*/deps/*' | sort); do
  n=$((n + 1))
  # no .front file: no lex or parse error expected
  p=$(oracle "${f#./}" front)
  want=""
  [ -f "$p" ] && want=$(cat "$p")
  got=$(front "$($new check --json "$f" 2>/dev/null | head -1 | norm)" "$f")
  if [ -n "$BLESS" ]; then
    if [ -n "$got" ]; then mkdir -p "$(dirname "$p")"; echo "$got" >"$p"; else rm -f "$p"; fi
    want=$got
  fi
  if [ "$want" != "$got" ]; then
    echo "FAIL front end $f"
    echo "  oracle: $want"
    echo "  eiderc: $got"
    fail=1
  fi
done
[ $fail = 0 ] && echo "ok   front end (lex+parse): $n files agree with the oracle"
for f in compiler/tests/lex_ok/*.ei; do
  g="${f%.ei}.tokens"
  if [ -n "$BLESS" ]; then $new lex "$f" > "$g"; fi
  if $new lex "$f" | cmp -s - "$g"; then echo "ok   lex_ok $f"; else echo "FAIL lex_ok $f"; $new lex "$f" | diff "$g" - | head -10; fail=1; fi
done
for f in compiler/tests/parse_ok/*.ei; do
  g="${f%.ei}.ast"
  if [ -n "$BLESS" ]; then $new parse "$f" > "$g"; fi
  if $new parse "$f" | cmp -s - "$g"; then echo "ok   parse_ok $f"; else echo "FAIL parse_ok $f"; $new parse "$f" | diff "$g" - | head -10; fail=1; fi
done
# recover: every syntax error at once (see the top)
for f in compiler/tests/recover/*.src; do
  g="${f%.src}.recover"
  $new parse --all-errors "$f" >target/runtest/recover 2>&1
  if [ -n "$BLESS" ]; then cp target/runtest/recover "$g"; fi
  if cmp -s target/runtest/recover "$g"; then echo "ok   recover $f"; else echo "FAIL recover $f"; diff "$g" target/runtest/recover | head -10; fail=1; fi
done
rn=0
rbad=""
for f in $(find . -name '*.ei' -not -path './target/*' -not -path './.claude/*' -not -path '*/deps/*' | sort); do
  rn=$((rn + 1))
  $new parse --json "$f" >target/runtest/rp 2>/dev/null
  $new parse --all-errors "$f" >target/runtest/ra 2>&1
  if head -1 target/runtest/rp | grep -q '^{"error"'; then
    [ "$(head -1 target/runtest/rp)" = "$(head -1 target/runtest/ra)" ] || rbad="$rbad $f"
  else
    cmp -s target/runtest/rp target/runtest/ra || rbad="$rbad $f"
  fi
done
if [ -z "$rbad" ]; then
  echo "ok   recover: $rn files: the first of all the front-end errors is eiderc's, and without one the dump is eiderc's"
else
  echo "FAIL recover: first error or dump differs from eiderc parse:$rbad"
  fail=1
fi
for f in compiler/tests/ir/*.ei; do
  g="${f%.ei}.ir"
  if [ -n "$BLESS" ]; then $new ir "$f" > "$g"; fi
  if $new ir "$f" | cmp -s - "$g"; then echo "ok   ir $f"; else echo "FAIL ir $f"; $new ir "$f" | diff "$g" - | head -10; fail=1; fi
done

# check: `check --json` against the oracle
# usage: check_set <must-be-in-scope: 0|1> files...; sets total, inscope, agree, outside
check_set() {
  strict=$1
  shift
  total=0
  inscope=0
  agree=0
  outside=""
  for f in "$@"; do
    total=$((total + 1))
    # `// mode: wasm` (as the compile-fail runner reads it): check as a WebAssembly module
    wf=""
    if grep -q '// mode: wasm' "$f"; then wf=--wasm; fi
    $new check --json $wf "$f" 2>&1 | norm >target/runtest/check
    got=$(cat target/runtest/check)
    case "$got" in
      *'"error":"unsupported"'*)
        outside="$outside $(basename "$f")"
        if [ "$strict" = 1 ]; then echo "FAIL check $f is out of scope: $got"; fail=1; fi
        continue
        ;;
    esac
    inscope=$((inscope + 1))
    bless "$f" check.json target/runtest/check
    want=$(want_of "$f" check.json)
    if [ "$want" = "$got" ]; then
      agree=$((agree + 1))
    else
      echo "FAIL check $f"
      echo "  oracle: $want"
      echo "  eiderc: $got"
      fail=1
    fi
  done
}
verdict() { if [ "$agree" = "$inscope" ] && [ "$1" = "$inscope" ]; then echo "ok  "; else echo "FAIL"; fi; }
check_set 0 tests/checks/fail/*.ei tests/checks/pass/*.ei
echo "$(verdict $inscope) check: $agree/$inscope check tests in scope agree ($total tests, $((total - inscope)) out of scope)"
echo "     out of scope:$outside"
check_set 0 tests/run/*.ei
echo "$(verdict $inscope) check: $agree/$inscope run tests in scope agree ($total tests)"
check_set 1 compiler/tests/check/fail/*.ei compiler/tests/check/pass/*.ei
echo "$(verdict $total) check: $agree/$inscope eiderc check cases agree (compiler/tests/check)"

# multi: programs with several independent errors (compiler/tests/check/multi): everything
# `check --json` and `check` print, against the oracle (X.check.json, X.check.err: every
# diagnostic in order, the summary, the --max-errors note); a first line `// args: <options>`
# adds options
mtotal=0
magree=0
for f in compiler/tests/check/multi/*.ei; do
  mtotal=$((mtotal + 1))
  args=$(sed -n '1s|^// args: ||p' "$f")
  $new check --json $args "$f" 2>&1 | norm >target/runtest/m_json
  $new check $args "$f" 2>&1 | norm >target/runtest/m_err
  bless "$f" check.json target/runtest/m_json
  bless "$f" check.err target/runtest/m_err
  ok=1
  for k in check.json check.err; do
    p=$(oracle "$f" $k)
    if [ ! -f "$p" ] || ! cmp -s "$p" "target/runtest/m_${k#check.}"; then
      echo "FAIL multi $f ($k)"
      if [ -f "$p" ]; then diff "$p" "target/runtest/m_${k#check.}" | head -10; else echo "  (no oracle file $p)"; fi
      ok=0
      fail=1
    fi
  done
  [ $ok = 1 ] && magree=$((magree + 1))
done
if [ "$magree" = "$mtotal" ]; then echo "ok   multi: $magree/$mtotal programs with several errors report them all (compiler/tests/check/multi)"; else echo "FAIL multi: $magree/$mtotal programs with several errors agree"; fi

# run: `run` / `test` (stdout, stderr, exit code) against the oracle
tmp=target/runtest
mkdir -p $tmp
# usage: outcome <command...>: writes stdout, stderr and the exit code of the command to $tmp/out
outcome() {
  "$@" >$tmp/o 2>$tmp/e
  code=$?
  { cat $tmp/o; echo "--- stderr"; cat $tmp/e; echo "--- exit $code"; } | norm >$tmp/out
}
has_tests() { grep -q '^test ' "$1"; }
# ASan/TSan need runtime libraries that may not be installed; UBSan in trap mode needs none
sans="undefined"
printf 'int main(void){return 0;}\n' >$tmp/probe.c
for s in address thread; do
  if ${CC:-cc} -fsanitize=$s -o $tmp/probe $tmp/probe.c 2>/dev/null; then
    sans="$sans $s"
  else
    echo "     skip $s sanitizer: its runtime library is not installed"
  fi
done
rtotal=0
rscope=0
ragree=0
rexpected=0
rsan=0
rsan_ok=0
rleak=0
rleak_ok=0
routside=""
for f in tests/run/*.ei compiler/tests/run/*.ei; do
  rtotal=$((rtotal + 1))
  case "$($new check --json "$f" 2>&1)" in
    *'"error":"unsupported"'*)
      routside="$routside $(basename "$f")"
      continue
      ;;
  esac
  rscope=$((rscope + 1))
  ok=1
  for cmd in run test; do
    if [ $cmd = test ] && ! has_tests "$f"; then continue; fi
    exp=""
    case "$f" in compiler/tests/run/*) exp="${f%.ei}.out" ;; esac
    [ $cmd = test ] && exp="${exp%.out}.test.out"
    outcome env EIDER_CFLAGS=-Werror $new $cmd "$f"
    cp $tmp/out $tmp/got
    if [ -n "$exp" ] && [ -f "$exp" ]; then
      # a regression for a deliberate fix: hand-written expected output, not the oracle's
      { cat "$exp"; echo "--- stderr"; echo "--- exit 0"; } >$tmp/want
    else
      bless "$f" $cmd $tmp/got
      if [ -f "$(oracle "$f" $cmd)" ]; then cp "$(oracle "$f" $cmd)" $tmp/want; else echo "(no oracle file $(oracle "$f" $cmd))" >$tmp/want; fi
    fi
    if ! cmp -s $tmp/want $tmp/got; then
      echo "FAIL run: eiderc $cmd $f"
      diff $tmp/want $tmp/got | head -10
      ok=0
      fail=1
    fi
    # the same program at -O2 under each available sanitizer
    for s in $sans; do
      # `// nosan: thread` in a test: not under that sanitizer (TSan runs out of stack inside
      # its own runtime before a stack overflow reaches the runtime's guard; core/RUNTIME.md)
      case " $(sed -n 's|^// nosan: ||p' "$f") " in *" $s "*) continue ;; esac
      rsan=$((rsan + 1))
      flags="-Werror -O2 -fsanitize=$s"
      [ $s = undefined ] && flags="$flags -fsanitize-undefined-trap-on-error"
      outcome env EIDER_CFLAGS="$flags" $new $cmd "$f"
      if cmp -s $tmp/got $tmp/out; then
        rsan_ok=$((rsan_ok + 1))
      else
        echo "FAIL sanitize ($s): eiderc $cmd $f"
        diff $tmp/got $tmp/out | head -10
        fail=1
      fi
    done
    # no allocation may be left when the program ends normally
    rleak=$((rleak + 1))
    outcome env EIDER_CFLAGS="-Werror -DEI_RT_COUNT_ALLOCS" $new $cmd "$f"
    leakline=$(grep '^eider: outstanding allocations: ' $tmp/e)
    grep -v '^eider: outstanding allocations: ' $tmp/out >$tmp/out2
    if ! cmp -s $tmp/got $tmp/out2; then
      echo "FAIL leaks: eiderc $cmd $f (output differs)"
      diff $tmp/got $tmp/out2 | head -10
      fail=1
    elif grep -q '^--- exit 0$' $tmp/out && [ "$leakline" != "eider: outstanding allocations: 0" ]; then
      echo "FAIL leaks: eiderc $cmd $f: ${leakline:-no allocation report}"
      fail=1
    else
      rleak_ok=$((rleak_ok + 1))
    fi
  done
  if [ $ok = 1 ]; then
    ragree=$((ragree + 1))
    case "$f" in compiler/tests/run/*) [ -f "${f%.ei}.out" ] && rexpected=$((rexpected + 1)) ;; esac
  fi
done
if [ "$ragree" = "$rscope" ]; then v="ok  "; else v="FAIL"; fi
echo "$v run: $ragree/$rscope run tests in scope agree ($rtotal tests; $rexpected compared with hand-written expected output)"
echo "     out of scope:$routside"
if [ "$rsan_ok" = "$rsan" ]; then v="ok  "; else v="FAIL"; fi
echo "$v sanitize: $rsan_ok/$rsan runs at -O2 under -fsanitize={$sans} match"
if [ "$rleak_ok" = "$rleak" ]; then v="ok  "; else v="FAIL"; fi
echo "$v leaks: $rleak_ok/$rleak runs end with no outstanding allocation (-DEI_RT_COUNT_ALLOCS)"

# determinism: the same input gives byte-identical LLVM IR, also from another directory
det=target/determinism
rm -rf $det
mkdir -p $det/a $det/b/tests
cp -R tests/run $det/a/run
# compiler/tests/run is in package eiderc: the copy is too (module names come from the package)
cp compiler/eider.toml $det/b/eider.toml
cp -R compiler/tests/run $det/b/tests/run
dtotal=0
dok=0
# the compiler by absolute path, so it runs from the test directories
case "$new" in /*) anew=$new ;; *) anew=$(pwd)/$new ;; esac
for f in tests/run/*.ei compiler/tests/run/*.ei; do
  case " $routside " in *" $(basename "$f") "*) continue ;; esac
  dtotal=$((dtotal + 1))
  case "$f" in tests/*) dir=tests ;; *) dir=compiler/tests ;; esac
  case "$f" in tests/*) copy=$det/a ;; *) copy=$det/b/tests ;; esac
  rel="run/$(basename "$f")"
  (cd $dir && "$anew" emit-llvm "$rel" --test) >$tmp/c1 2>&1
  (cd $dir && "$anew" emit-llvm "$rel" --test) >$tmp/c2 2>&1
  (cd $copy && "$anew" emit-llvm "$rel" --test) >$tmp/c3 2>&1
  if cmp -s $tmp/c1 $tmp/c2 && cmp -s $tmp/c1 $tmp/c3; then
    dok=$((dok + 1))
  else
    echo "FAIL determinism: emit-llvm $f"
    diff $tmp/c1 $tmp/c3 | head -10
    fail=1
  fi
done
if [ "$dok" = "$dtotal" ]; then v="ok  "; else v="FAIL"; fi
echo "$v determinism: $dok/$dtotal programs give byte-identical LLVM IR twice and from a copy at another path"
# the C name clash check stops lowering loudly (exit 3 and both names)
$new emit-llvm compiler/tests/lower/clash.ei >$tmp/o 2>$tmp/e
code=$?
if [ $code = 3 ] && grep -q 'C name clash: `f_Sq__area` names both `Sq__area` and `Sq.area`' $tmp/e; then
  echo "ok   names: a C name clash is an internal error (compiler/tests/lower/clash.ei)"
else
  echo "FAIL names: compiler/tests/lower/clash.ei exited $code: $(cat $tmp/e)"
  fail=1
fi

# export: `eiderc build --lib`, its header, and checking as a library
if out=$(EIDER=$new sh tests/export/run.sh 2>&1); then echo "$out (eiderc)"; else echo "FAIL tests/export with eiderc: $out"; fail=1; fi
if out=$(sh compiler/tests/export/run.sh $new 2>&1); then echo "$out"; else echo "$out"; fail=1; fi
lagree=0
ltotal=0
for f in tests/export/mathlib.ei compiler/tests/export/shapes.ei compiler/tests/export/nested.ei tests/run/ffi.ei tests/checks/pass/pass_import_and_ffi.ei; do
  ltotal=$((ltotal + 1))
  $new check --lib --json "$f" 2>&1 | norm >$tmp/l_got
  bless "$f" check-lib.json $tmp/l_got
  want=$(want_of "$f" check-lib.json)
  got=$(cat $tmp/l_got)
  if [ "$want" != "$got" ]; then
    echo "FAIL check --lib $f"
    echo "  oracle: $want"
    echo "  eiderc: $got"
    fail=1
    continue
  fi
  # nested.ei: the recorded header lacked the inner record's typedef, so there is no
  # oracle for it (compiler/tests/export/run.sh compiles eiderc's)
  case "$f" in tests/export/*|*/shapes.ei)
    $new emit-header "$f" 2>&1 | norm >$tmp/h_got
    bless "$f" emit-header $tmp/h_got
    if ! cmp -s "$(oracle "$f" emit-header)" $tmp/h_got; then
      echo "FAIL emit-header $f"
      fail=1
      continue
    fi
  esac
  lagree=$((lagree + 1))
done
if [ "$lagree" = "$ltotal" ]; then v="ok  "; else v="FAIL"; fi
echo "$v export: $lagree/$ltotal files agree on check --lib and emit-header"

# wasm: `check --wasm` and `emit-header --wasm` (the .d.ts and the loader) equal the
# oracle; core/wasm and the emitted C compile as strict freestanding C; and, when clang
# has the wasm32 target and wasm-ld and node are installed, `build --wasm` modules behave
# as recorded (compiler/tests/wasm/run.sh; it skips with the reason otherwise)
wagree=0
wtotal=0
for f in tests/wasm/*.ei compiler/tests/wasm/*.ei compiler/tests/wasm/check/*.ei; do
  wtotal=$((wtotal + 1))
  $new check --wasm --json "$f" 2>&1 | norm >$tmp/w_got
  $new emit-header --wasm "$f" 2>&1 | norm >$tmp/h_got
  bless "$f" check-wasm.json $tmp/w_got
  bless "$f" emit-header-wasm $tmp/h_got
  want=$(want_of "$f" check-wasm.json)
  got=$(cat $tmp/w_got)
  if [ "$want" != "$got" ] || ! cmp -s "$(oracle "$f" emit-header-wasm)" $tmp/h_got; then
    echo "FAIL check --wasm / emit-header --wasm $f"
    fail=1
    continue
  fi
  wagree=$((wagree + 1))
done
if [ "$wagree" = "$wtotal" ]; then v="ok  "; else v="FAIL"; fi
echo "$v wasm: $wagree/$wtotal files agree on check --wasm and emit-header --wasm"
if out=$(sh compiler/tests/wasm/run.sh $new 2>&1); then echo "$out"; else echo "$out"; fail=1; fi
# unit: compiler modules driven by a program in compiler/tests/unit, compared with the .out
# (hand-checked: sha256.out against FIPS 180-4 and sha256sum)
for f in compiler/tests/unit/*.ei; do
  outcome env EIDER_CFLAGS=-Werror $new run "$f"
  { cat "${f%.ei}.out"; echo "--- stderr"; echo "--- exit 0"; } >$tmp/want
  if cmp -s $tmp/want $tmp/out; then echo "ok   unit $f"; else echo "FAIL unit $f"; diff $tmp/want $tmp/out | head -10; fail=1; fi
done

# ide: the IDE analysis against its goldens
for f in compiler/tests/ide/*.ei; do
  g="${f%.ei}.ide"
  ov=$(sed -n 's|^// overlay: \([^ ]*\) \([^ ]*\)$|--overlay \1 \2|p' "$f")
  # (absolute, so toolchain files are <root>/... however $new is spelled)
  $anew ide "$f" $ov 2>&1 | norm >$tmp/ide
  if [ -n "$BLESS" ]; then cp $tmp/ide "$g"; fi
  if cmp -s $tmp/ide "$g"; then echo "ok   ide $f"; else echo "FAIL ide $f"; diff "$g" $tmp/ide | head -10; fail=1; fi
done

# packages: package-qualified modules and bare imports in the multi-package layout of
# compiler/tests/pkgs (docs/compiler.md, "C8.3: packages and modules"). Each file starting
# `// pkgtest: <run|check|ide>` gives X.out (stdout, stderr, exit; `ide`: its dump), with
# git dependencies from the store compiler/tests/pkgs/home. The program's LLVM IR is the same
# from a copy of the layout at another path.
pk_total=0
pk_ok=0
for f in $(grep -rl '^// pkgtest: ' compiler/tests/pkgs --include='*.ei' | sort); do
  pk_total=$((pk_total + 1))
  how=$(sed -n '1s|^// pkgtest: ||p' "$f")
  if [ "$how" = ide ]; then
    EIDER_HOME=$(pwd)/compiler/tests/pkgs/home $new ide "$f" 2>&1 | norm >$tmp/out
  else
    outcome env EIDER_HOME=$(pwd)/compiler/tests/pkgs/home EIDER_CFLAGS=-Werror $new $how "$f"
  fi
  g="${f%.ei}.out"
  if [ -n "$BLESS" ]; then cp $tmp/out "$g"; fi
  if cmp -s $tmp/out "$g"; then pk_ok=$((pk_ok + 1)); else echo "FAIL packages $f"; diff "$g" $tmp/out | head -10; fail=1; fi
done
# a file in no package (copied out of compiler/, which is package eiderc)
mkdir -p target/pkgloose
cp compiler/tests/pkgs/loose.src target/pkgloose/loose.ei
pk_total=$((pk_total + 1))
outcome $new check target/pkgloose/loose.ei
if [ -n "$BLESS" ]; then cp $tmp/out compiler/tests/pkgs/loose.out; fi
if cmp -s $tmp/out compiler/tests/pkgs/loose.out; then pk_ok=$((pk_ok + 1)); else echo "FAIL packages compiler/tests/pkgs/loose.src"; diff compiler/tests/pkgs/loose.out $tmp/out | head -10; fail=1; fi
pkc=target/pkgcopy
rm -rf $pkc
mkdir -p $pkc
cp -R compiler/tests/pkgs $pkc/pkgs
(cd compiler/tests/pkgs/app && EIDER_HOME=$(pwd)/../home "$anew" emit-llvm main.ei) >$tmp/c1 2>&1
(cd $pkc/pkgs/app && EIDER_HOME=$(pwd)/../home "$anew" emit-llvm main.ei) >$tmp/c2 2>&1
if cmp -s $tmp/c1 $tmp/c2 && grep -q 'f_util__0geo__name' $tmp/c1; then pk_ok=$((pk_ok + 1)); else echo "FAIL packages: emit-llvm of compiler/tests/pkgs/app/main.ei differs from a copy's (or lacks the package names)"; diff $tmp/c1 $tmp/c2 | head -10; fail=1; fi
pk_total=$((pk_total + 1))
if [ "$pk_ok" = "$pk_total" ]; then v="ok  "; else v="FAIL"; fi
echo "$v packages: $pk_ok/$pk_total multi-package cases (compiler/tests/pkgs) give their .out, and the same LLVM IR from a copy"
# migration: the staged rewrites to package imports (scripts/migrate-imports.sh) and away
# from `uses ffi` outside core (scripts/migrate-caps.sh), on a copy of core, std, packages
# and compiler, give a toolchain this compiler checks, whose package tests pass (what the
# next seed makes possible in the checkout itself)
mig=$(pwd)/target/migrate
rm -rf $mig
mkdir -p $mig
if [ -n "$novendor" ]; then echo "skip migration: $novendor"; else
# .vendor/: the pinned libraries packages/pkg and packages/doc depend on by path
cp -R core std packages compiler .vendor $mig/
sh scripts/migrate-imports.sh $mig/core $mig/std $mig/packages $mig/compiler >$tmp/mig 2>&1
# and the staged removal of `uses ffi` (scripts/migrate-caps.sh, docs/compiler.md "C8.5")
sh scripts/migrate-caps.sh $mig/core $mig/std $mig/packages $mig/compiler >$tmp/migc 2>&1
# and the deprecated `var` rewritten as `let mut` (scripts/migrate-var.sh, docs/compiler.md
# "C8.6"): none is left in core or the compiler (std and the packages keep the `var`s of
# places in generic bodies, which `.copy()` could need a bound for), and the migrated
# compiler, built by this one, emits the same LLVM IR for compiler/ as this one (meaning unchanged)
EIDER_ROOT=$mig EIDERC=$new sh scripts/migrate-var.sh $mig/core $mig/std $mig/packages $mig/compiler/*.ei >$tmp/migv 2>&1
mig_ok=1
grep -n '^[[:space:]]*var[[:space:]]' $mig/core/*.ei $mig/compiler/*.ei >$tmp/migvl && { echo "FAIL migration: \`var\` is left in"; sed "s|$mig/||" $tmp/migvl | head -10; cat $tmp/migv | grep -v '^migrated' | head -5; mig_ok=0; }
# and every quoted import in the dotted form (scripts/migrate-imports-dotted.sh, docs/compiler.md
# "C8.26"), compiler/ and what the seed builds included: none is left outside compiler/tests
# (which keeps the quoted form's own tests), and this compiler's IR for the migrated compiler is
# byte-identical to its IR for compiler/
EIDER_ROOT=$mig EIDERC=$new sh scripts/migrate-imports-dotted.sh $mig/core $mig/std $mig/packages $mig/compiler >$tmp/migd 2>$tmp/migde
grep -h '^kept ' $tmp/migde | grep -v '/compiler/tests/' >$tmp/migdk
[ -s $tmp/migdk ] && { echo "FAIL migration: quoted imports are left"; sed "s|$mig/||" $tmp/migdk | head -10; mig_ok=0; }
grep -v '^kept ' $tmp/migde | head -5 | grep . && { echo "FAIL migration: migrate-imports-dotted.sh failed on a file (above)"; mig_ok=0; }
EIDER_CACHE=off EIDER_ROOT=$mig $new build $mig/compiler/main.ei -o $tmp/eiderc-mig >$tmp/mo 2>&1 || { echo "FAIL migration: build the migrated compiler"; head -10 $tmp/mo; mig_ok=0; }
$new emit-llvm compiler/main.ei >$tmp/mc1 2>&1
[ -x $tmp/eiderc-mig ] && EIDER_ROOT=$(pwd) $tmp/eiderc-mig emit-llvm compiler/main.ei >$tmp/mc2 2>&1
cmp -s $tmp/mc1 $tmp/mc2 || { echo "FAIL migration: the migrated compiler's IR for compiler/ differs"; mig_ok=0; }
(cd $mig && EIDER_ROOT=$mig $anew emit-llvm compiler/main.ei) >$tmp/mc3 2>&1
cmp -s $tmp/mc1 $tmp/mc3 || { echo "FAIL migration: the IR of the compiler with dotted imports differs from compiler/'s"; diff $tmp/mc1 $tmp/mc3 | head -10; mig_ok=0; }
grep -q '^import "\.\./' $mig/compiler/main.ei $mig/packages/pkg/manifest.ei && { echo "FAIL migration: path imports into other packages are left"; mig_ok=0; }
grep -l '^[[:space:]]*[^/[:space:]][^/]*uses [^/]*ffi' $mig/std/*.ei $mig/compiler/*.ei $mig/packages/*/*.ei >$tmp/migl && { echo "FAIL migration: \`uses ffi\` is left in $(sed "s|$mig/||" $tmp/migl | tr '\n' ' ')"; mig_ok=0; }
grep -q 'uses .*ffi' $mig/core/sys.ei || { echo "FAIL migration: core/sys.ei lost its \`uses ffi\`"; mig_ok=0; }
for f in compiler/main.ei packages/pkg/main.ei packages/fuzz/main.ei; do
  EIDER_ROOT=$mig $new check $mig/$f >$tmp/mo 2>&1 || { echo "FAIL migration: check $f"; head -10 $tmp/mo; mig_ok=0; }
done
for f in packages/*/tests/*.ei; do
  EIDER_ROOT=$mig $new run $mig/$f >$tmp/mo 2>&1
  cmp -s $tmp/mo "${f%.ei}.out" || { echo "FAIL migration: run $f"; diff "${f%.ei}.out" $tmp/mo | head -10; mig_ok=0; }
done
if [ $mig_ok = 1 ]; then echo "ok   migration: $(wc -l <$tmp/mig) files rewritten to package imports, $(grep -c '^migrated' $tmp/migd) to dotted imports (the compiler's IR unchanged), $(wc -l <$tmp/migc) without \`uses ffi\` and $(grep -c '^migrated' $tmp/migv) without \`var\` ($(cat $mig/std/*.ei $mig/packages/*/*.ei | grep -c '^[[:space:]]*var[[:space:]]') generic ones left) check and pass their package tests; the migrated compiler emits the same IR"; else fail=1; fi
fi
# meaning: std's, the packages' and the examples' tests (run by verify.sh with the seed, where
# `let` copies) give their .out with this compiler too, where `let` of a place is a reference
# (docs/compiler.md, "C8.6"); a difference is code that relied on the copy (`eiderc audit-refs`)
m_ok=0; m_n=0; m_skip=
for f in tests/std/*.ei packages/*/tests/*.ei examples/*/tests/*.ei; do
  [ -f "${f%.ei}.out" ] || continue
  m_n=$((m_n + 1))
  in="${f%.ei}.in"; [ -f "$in" ] || in=/dev/null
  case $f in
    tests/std/*) got=$(EIDER_STD_TEST=set $new run "$f" <"$in" 2>&1; echo "exit $?") ;;
    *) got=$($new run "$f" </dev/null 2>&1) ;;
  esac
  # X.next.out: what this compiler prints where it deliberately differs from the seed (a
  # fix the seed doesn't have yet; it replaces X.out when the seed is regenerated)
  want="${f%.ei}.out"; [ -f "${f%.ei}.next.out" ] && want="${f%.ei}.next.out"
  if [ "$got" = "$(cat "$want")" ]; then m_ok=$((m_ok + 1))
  # a package test that loads a pinned library which isn't there (E0810 at .vendor/<name>)
  elif [ -n "$novendor" ] && printf '%s\n' "$got" | grep -q 'E0810.*/\.vendor/'; then m_n=$((m_n - 1)); m_skip="$m_skip $f"
  else echo "FAIL meaning: $f"; echo "$got" | diff "$want" - | head -10; fail=1; fi
done
[ "$m_ok" = "$m_n" ] && echo "ok   meaning: $m_ok/$m_n std, package and example tests give their .out with references by default"
[ -n "$m_skip" ] && echo "skip meaning: $(printf '%s\n' $m_skip | paste -sd, - | sed 's/,/, /g') (they load a pinned library): $novendor"
# audit-refs: `eiderc audit-refs --json` of compiler/tests/audit/*.ei gives the hand-checked .out
for f in compiler/tests/audit/*.ei; do
  $new audit-refs --json "$f" >$tmp/ar 2>&1
  if cmp -s $tmp/ar "${f%.ei}.out"; then echo "ok   audit-refs $f"; else echo "FAIL audit-refs $f"; diff "${f%.ei}.out" $tmp/ar | head -10; fail=1; fi
done
# migrate-strings: `eiderc migrate-strings` of compiler/tests/migrate_strings/*.src gives the
# hand-checked .out (and the result checks), --portable the .portable, --json the .json
for f in compiler/tests/migrate_strings/*.src; do
  g=${f%.src}
  $new migrate-strings "$f" >$tmp/ms 2>&1
  $new migrate-strings "$f" --portable >$tmp/msp 2>&1
  $new migrate-strings "$f" --json >$tmp/msj 2>&1
  if [ -n "$BLESS" ] && [ ! -f "$g.out" ]; then cp $tmp/ms "$g.out"; cp $tmp/msp "$g.portable"; cp $tmp/msj "$g.json"; fi
  cp $tmp/ms $tmp/migrated.ei
  if cmp -s $tmp/ms "$g.out" && cmp -s $tmp/msp "$g.portable" && cmp -s $tmp/msj "$g.json" && $new check $tmp/migrated.ei >/dev/null 2>&1; then echo "ok   migrate-strings $f"; else echo "FAIL migrate-strings $f"; diff "$g.out" $tmp/ms | head -10; fail=1; fi
done
# migrate-var: `eiderc migrate-var` of compiler/tests/migrate/*.ei gives the hand-checked .out,
# which checks
for f in compiler/tests/migrate/*.ei; do
  $new migrate-var "$f" >$tmp/mv 2>&1
  cp $tmp/mv $tmp/migrated.ei
  if cmp -s $tmp/mv "${f%.ei}.out" && $new check $tmp/migrated.ei >/dev/null 2>&1; then echo "ok   migrate-var $f"; else echo "FAIL migrate-var $f"; diff "${f%.ei}.out" $tmp/mv | head -10; fail=1; fi
done

# compile-fail: `eiderc test --compile-fail` against the recorded runner output (the oracle's
# <dir>.compile-fail: the output, then `--- exit <code>`)
for d in compiler/tests/check compiler/tests/suite; do
  $new test --compile-fail $d >$tmp/cf_o 2>&1
  gcode=$?
  { norm <$tmp/cf_o; echo "--- exit $gcode"; } >$tmp/cf_got
  [ -n "$BLESS" ] && cp $tmp/cf_got $O/$d.compile-fail
  if cmp -s $O/$d.compile-fail $tmp/cf_got; then
    echo "ok   compile-fail: test --compile-fail $d equals the oracle ($(grep 'error-code coverage' $tmp/cf_got))"
  else
    echo "FAIL compile-fail: test --compile-fail $d (exit $gcode)"
    diff $O/$d.compile-fail $tmp/cf_got | head -10
    fail=1
  fi
done
# tests/checks: files eiderc can't check (`unsupported`) are `skip`; every other line is the
# oracle's
$new test --compile-fail tests/checks >$tmp/cf_o 2>&1
gcode=$?
norm <$tmp/cf_o >$tmp/cf_got
[ -n "$BLESS" ] && { cat $tmp/cf_got; echo "--- exit $gcode"; } >$O/tests/checks.compile-fail
sed '$d' $O/tests/checks.compile-fail >$tmp/cf_want
grep '^  skip ' $tmp/cf_got | awk '{print "  ok   " $2 " "}' >$tmp/cf_skipped
grep -v -F -f $tmp/cf_skipped $tmp/cf_want | grep -v 'passed, .* failed; error-code coverage' | grep -v '^codes without' >$tmp/cf_w
grep -v '^  skip ' $tmp/cf_got | grep -v 'skipped (not yet supported by eiderc)' | grep -v 'passed, .* failed; error-code coverage' | grep -v '^codes without' >$tmp/cf_g
# the skipped-count line is followed by a blank line of its own
uniq $tmp/cf_w >$tmp/cf_w2
uniq $tmp/cf_g >$tmp/cf_g2
summary=$(grep 'error-code coverage' $tmp/cf_got)
if [ $gcode = 0 ] && cmp -s $tmp/cf_w2 $tmp/cf_g2 && echo "$summary" | grep -q ' 0 failed'; then
  echo "ok   compile-fail: tests/checks: $summary; skipped:$(grep '^  skip ' $tmp/cf_got | awk '{printf " %s", $2}')"
  grep '^codes without' $tmp/cf_got | sed 's/^/     /'
else
  echo "FAIL compile-fail: tests/checks (exit $gcode): $summary"
  diff $tmp/cf_w2 $tmp/cf_g2 | head -10
  fail=1
fi

# profile-off: without --profile the IR has no trace of the profiler (docs/runtime.md
# "Profiler": zero cost): `emit-llvm` of every run test (also with --test) and of the compiler
# itself calls nothing of it and declares none of its globals
pototal=0
pook=0
for f in tests/run/*.ei compiler/tests/run/*.ei compiler/main.ei; do
  case " $routside " in *" $(basename "$f") "*) continue ;; esac
  for mode in "" --test; do
    [ "$f" = compiler/main.ei ] && [ -n "$mode" ] && continue
    pototal=$((pototal + 1))
    $new emit-llvm "$f" $mode >$tmp/p1 2>&1
    # (the compiler's string constants name the profiler: only calls and its globals count)
    if grep -q '^define' $tmp/p1 && ! grep -q 'call [^"]*@ei_prof\|^@ei_prof' $tmp/p1; then
      pook=$((pook + 1))
    else
      echo "FAIL profile-off: emit-llvm $f $mode has the profiler in it (or failed)"
      grep -m3 'ei_prof' $tmp/p1
      fail=1
    fi
  done
done
if [ "$pook" = "$pototal" ]; then v="ok  "; else v="FAIL"; fi
echo "$v profile-off: $pook/$pototal emit-llvm outputs without --profile have no profiler in them"

# profile: programs built with --profile write the profile they should
# (compiler/tests/profile/*.ei; docs/runtime.md "Profile format"). `fnid NAME FILE` is the id of
# function NAME in profile FILE, `at TEXT SRC` the line of TEXT in source SRC; a check is a
# grep of the profile.
pdir=$(pwd)/target/proftest
rm -rf $pdir
mkdir -p $pdir
fnid() { sed -n "s/^{\"t\":\"fn\",\"id\":\([0-9]*\),\"name\":\"$1\",.*/\1/p" "$2" | head -1; }
at() { grep -n -F "$1" "$2" | head -1 | cut -d: -f1; }
pfail=0
pcheck() { if ! grep -q -- "$1" "$2"; then echo "FAIL profile: $3 (no \`$1\` in $2)"; pfail=1; fi; }
pbuild() { EIDER_CACHE=off $new build compiler/tests/profile/$1.ei --profile -o $pdir/$1 >$pdir/$1.build 2>&1 || { echo "FAIL profile: build $1"; cat $pdir/$1.build; pfail=1; }; }
for t in cow conc cpu ref_trap; do pbuild $t; done
# memory events
(cd $pdir && EIDER_PROF=$pdir/cow.prof ./cow >cow.out 2>&1)
src=compiler/tests/profile/cow.ei
p=$pdir/cow.prof
pcheck '"clean_exit":true' $p "cow: main returned"
# (edit is straight-line code that calls nothing, so it has no frame of its own: its
# unshares count for main, at the call)
pcheck "\"kind\":\"cow\",\"fn\":$(fnid main $p),\"line\":$(at 'kept.push(edit(d))' $src),\"n\":50," $p "cow: 50 unshares by edit, at main's call"
pcheck "\"kind\":\"copy\",\"fn\":$(fnid snap $p),\"line\":$(at 't += d.copy()' $src),\"n\":30," $p "cow: 30 .copy() in snap"
pcheck "\"kind\":\"grow\",\"fn\":$(fnid fill $p),\"line\":$(at 'l.push(i)' $src)," $p "cow: List growth in fill"
pcheck "\"kind\":\"rehash\",\"fn\":$(fnid index $p),\"line\":$(at 'm.insert(i' $src)," $p "cow: Map rehashes in index"
pcheck "\"kind\":\"drop\",\"fn\":$(fnid guarded $p),\"line\":$(at 'let g = Guard(i)' $src),\"n\":20," $p "cow: 20 Drop calls in guarded"
pcheck '"live":0,"live_n":0' $p "cow: nothing live at the end"
# waits and labels on threads
(cd $pdir && EIDER_PROF=$pdir/conc.prof ./conc >conc.out 2>&1)
p=$pdir/conc.prof
src=compiler/tests/profile/conc.ei
pcheck "\"kind\":\"lock\",\"fn\":$(fnid bump $p),\"line\":$(at 'm.update(' $src)," $p "conc: lock waits in bump"
pcheck "\"kind\":\"recv\",\"fn\":$(fnid main $p),\"line\":$(at 'c.recv()' $src)," $p "conc: receive waits in main"
pcheck "\"kind\":\"spawn\",\"fn\":$(fnid main $p),\"line\":$(at 'ts.push(spawn(' $src),\"n\":8," $p "conc: 8 spawns"
pcheck '"key":"work","value":"bump"' $p "conc: the label"
# (9 threads: main and 8 spawns; main ends too, since it runs on a runtime thread: ei_main)
pcheck '"threads_started":9,"threads_exited":9' $p "conc: threads"
grep -q '^320$' $pdir/conc.out || { echo "FAIL profile: conc output"; pfail=1; }
# cpu samples, labels, a snapshot and the file at exit
(cd $pdir && EIDER_PROF=$pdir/cpu.prof EIDER_PROF_HZ=500 ./cpu >cpu.out 2>&1)
p=$pdir/cpu.prof
pcheck '"reason":"exit"' $p "cpu: the profile at exit"
hot=$(fnid hot $p)
pcheck "\"kind\":\"cpu\",\"label\":1,.*\[$hot,[0-9]*\]\]}" $p "cpu: samples in hot under its label"
pcheck '"key":"phase","value":"hot"' $p "cpu: the label"
grep -q '^snapshot$' $pdir/cpu.out || { echo "FAIL profile: cpu snapshot ($(cat $pdir/cpu.out))"; pfail=1; }
# EIDER_PROF=off: no file
(cd $pdir && EIDER_PROF=off ./cpu >off.out 2>&1)
grep -q '^false$' $pdir/off.out || { echo "FAIL profile: EIDER_PROF=off still profiles"; pfail=1; }
# a trap still writes the profile, with the Ref conflict
(cd $pdir && EIDER_PROF=$pdir/ref.prof ./ref_trap >ref.out 2>&1)
[ $? = 101 ] || { echo "FAIL profile: ref_trap exit"; pfail=1; }
pcheck '"kind":"ref",' $pdir/ref.prof "ref_trap: the conflict"
# under the sanitizers the toolchain has (ASan+UBSan, TSan), the waits program again
for san in "address,undefined" thread; do
  printf 'int main(void){return 0;}\n' > $pdir/probe.c
  ${CC:-cc} -fsanitize=$san -o $pdir/probe $pdir/probe.c 2>/dev/null && $pdir/probe || { echo "skip profile: no -fsanitize=$san"; continue; }
  for t in conc cow; do
    EIDER_CACHE=off EIDER_CFLAGS="-fsanitize=$san -fno-sanitize-recover=all -g" $new build compiler/tests/profile/$t.ei --profile -o $pdir/$t.san >$pdir/san.log 2>&1 || { echo "FAIL profile: build $t (-fsanitize=$san)"; pfail=1; continue; }
    (cd $pdir && TSAN_OPTIONS="halt_on_error=1 exitcode=66" EIDER_PROF=$pdir/$t.san.prof ./$t.san >$t.san.out 2>&1) || { echo "FAIL profile: $t under -fsanitize=$san"; head -20 $pdir/$t.san.out; pfail=1; }
  done
done
if [ $pfail = 0 ]; then echo "ok   profile: --profile programs record CPU, labels, allocation, copy-on-write, .copy(), growth, Drop, lock, channel, thread and Ref events at their sites (also under the sanitizers)"; else fail=1; fi

# cache: EIDER_CACHE=<dir> (driver.ei "Cache", build.ei; docs/compiler.md "C8.27: incremental
# builds"): unit objects (obj/), linked programs (bin/), hits and misses, what the keys cover,
# -j, concurrent builds into one cache, LRU eviction (trim, the automatic trim, clean, size)
cdir=$(pwd)/target/cachetest
rm -rf $cdir $cdir.*
cache_ok=1
cfail() { echo "FAIL cache: $1"; cache_ok=0; fail=1; }
# n <kind> [cache]: the files under <cache>/<kind>
n() { find "${2:-$cdir}/$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
# units <name> <eiderc args...>: how many objects that build makes in an empty cache of its own
units() { u=$cdir.u.$1; shift; rm -rf $u; EIDER_CACHE=$u $new "$@" >/dev/null 2>&1; n obj $u; rm -rf $u; }
A2=$(units adt build tests/run/adt.ei -o $tmp/adt_u)
C2=$(units clo build tests/run/closures.ei -o $tmp/clo_u)
H2=$(units heap build tests/run/heap.ei -o $tmp/heap_u)
[ "$A2" -ge 3 ] || cfail "a build should make at least 3 objects (units and the core), not $A2"
EIDER_CACHE=$cdir $new build tests/run/adt.ei -o $tmp/adt1 || cfail "build"
[ "$(n obj)" = $A2 ] && [ "$(n bin)" = 1 ] || cfail "a first build should cache $A2 objects and 1 program, not $(n obj) and $(n bin)"
EIDER_CACHE=$cdir $new build tests/run/adt.ei -o $tmp/adt2 || cfail "second build"
[ "$(n obj)" = $A2 ] && [ "$(n bin)" = 1 ] || cfail "a second build of the same program compiled or linked again"
$tmp/adt2 >$tmp/o 2>&1
cmp -s $tmp/o tests/run/adt.out || cfail "the binary copied out of the cache is wrong"
# another program: its own units are misses, the ones it shares (the core, std's) are hits
EIDER_CACHE=$cdir $new build tests/run/closures.ei -o $tmp/clo || cfail "build of a second program"
d=$(($(n obj) - A2))
[ $d -gt 0 ] && [ $d -lt $C2 ] && [ "$(n bin)" = 2 ] || cfail "a second program should add fewer than its $C2 objects (some are shared) and 1 program, not $d and $(($(n bin) - 1))"
n1=$(n obj)
EIDER_CACHE=$cdir $new run tests/run/adt.ei >$tmp/o 2>&1
cmp -s $tmp/o tests/run/adt.out || cfail "run"
# -O0 for run: the -O level is in every unit's key, so all of adt's units again, and one program
[ "$(n obj)" = $((n1 + A2)) ] && [ "$(n bin)" = 3 ] || cfail "run should add $A2 objects and 1 program, not $(($(n obj) - n1)) and $(($(n bin) - 2))"
n1=$(n obj)
EIDER_CACHE=$cdir EIDER_CFLAGS=-DEI_RT_COUNT_ALLOCS $new run tests/run/adt.ei >$tmp/o 2>&1
grep -q '^eider: outstanding allocations: 0' $tmp/o || cfail "EIDER_CFLAGS is not part of the key (the counting runtime didn't run)"
# (a -D reaches the C units only, the core's two; clang gets EIDER_CFLAGS's -O, -g and
# sanitizer flags for the IR)
[ "$(n obj)" = $((n1 + 2)) ] || cfail "a new -D in EIDER_CFLAGS should compile the 2 C units again, not $(($(n obj) - n1))"
# -j 1 and -j 8 make the same program (the same cache entries)
EIDER_CACHE=$cdir.j1 $new build tests/run/adt.ei -o $tmp/adt_j1 -j 1 || cfail "build -j 1"
EIDER_CACHE=$cdir.j8 $new build tests/run/adt.ei -o $tmp/adt_j8 -j 8 || cfail "build -j 8"
cmp -s $tmp/adt_j1 $tmp/adt_j8 || cfail "-j 1 and -j 8 built different programs"
[ "$(cd $cdir.j1 && find obj bin -type f | sort)" = "$(cd $cdir.j8 && find obj bin -type f | sort)" ] || cfail "-j 1 and -j 8 made different cache entries"
EIDER_CACHE=off EIDER_JOBS=1 $new build tests/run/adt.ei -o $tmp/adt_off || cfail "build with the cache off"
$tmp/adt_off >$tmp/o 2>&1
cmp -s $tmp/o tests/run/adt.out || cfail "the program built with the cache off is wrong"
rm -rf $cdir.j1 $cdir.j8
# twelve concurrent runs of a new program on that cache: the same entries as one run makes
cp -R $cdir $cdir.seq
EIDER_CACHE=$cdir.seq $new run tests/run/heap.ei >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  (EIDER_CACHE=$cdir $new run tests/run/heap.ei >$tmp/conc$i 2>&1; echo "exit $?" >>$tmp/conc$i) &
done
wait
{ cat tests/run/heap.out; echo "exit 0"; } >$tmp/conc_want
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  cmp -s $tmp/conc_want $tmp/conc$i || cfail "concurrent run $i: $(head -3 $tmp/conc$i)"
done
[ "$(cd $cdir && find obj bin -type f | sort)" = "$(cd $cdir.seq && find obj bin -type f | sort)" ] || cfail "12 concurrent runs made other entries than one run"
rm -rf $cdir.seq
# parallel builds of different programs (sharing units) into one empty cache: the same entries
# as building them one after the other
for t in adt closures heap order; do EIDER_CACHE=$cdir.one $new run tests/run/$t.ei >/dev/null 2>&1; done
pdir=$cdir.par
for t in adt closures heap order adt closures heap order; do
  (EIDER_CACHE=$pdir $new run tests/run/$t.ei >/dev/null 2>&1 || echo "$t exit $?" >>$tmp/par_fail) &
done
wait
[ ! -f $tmp/par_fail ] || cfail "a parallel build failed: $(cat $tmp/par_fail)"
rm -f $tmp/par_fail
for t in adt closures heap order; do
  EIDER_CACHE=$pdir $new run tests/run/$t.ei >$tmp/o 2>&1
  cmp -s $tmp/o tests/run/$t.out || cfail "after parallel builds, $t gives the wrong output"
done
[ "$(cd $pdir && find obj bin -type f | sort)" = "$(cd $cdir.one && find obj bin -type f | sort)" ] || cfail "4 programs built in parallel made other entries than built one after the other"
[ -z "$(ls $pdir/tmp)" ] || cfail "parallel builds left work directories in $pdir/tmp"
rm -rf $pdir $cdir.one
[ -z "$(ls $cdir/tmp)" ] || cfail "work directories left in $cdir/tmp"
nb=$(n bin)
EIDER_CACHE=off $new run tests/run/adt.ei >/dev/null 2>&1
[ "$(n bin)" = $nb ] || cfail "EIDER_CACHE=off still used the cache"
# comptime evaluators go through the cache too (twice: built, then cache hits)
for i in 1 2; do
  EIDER_CACHE=$cdir $new run tests/run/comptime.ei >$tmp/o 2>&1
  cmp -s $tmp/o tests/run/comptime.out || cfail "comptime with the cache (pass $i)"
done
# eviction. `cache size` counts every kind
EIDER_CACHE=$cdir $new cache size >$tmp/o 2>&1 || cfail "cache size"
grep -q "^obj  *$(n obj) files" $tmp/o && grep -q "^bin  *$(n bin) files" $tmp/o && grep -q '^total .*(limit 5.0 GiB' $tmp/o || cfail "cache size: $(cat $tmp/o)"
# LRU: everything made two hours ago; then a build of closures.ei at -O2 uses (touches) its
# objects and its program; a trim to a tiny limit removes every other entry, never those
# (used within the grace period)
find $cdir/obj $cdir/bin -type f -exec touch -d '2 hours ago' {} +
EIDER_CACHE=$cdir $new build tests/run/closures.ei -o $tmp/clo2 || cfail "build before the trim"
mkdir -p $cdir/core/old && echo x >$cdir/core/old/eider_rt.o
EIDER_CACHE=$cdir EIDER_CACHE_MAX=1 $new cache trim >$tmp/o 2>&1 || cfail "cache trim: $(cat $tmp/o)"
[ "$(n obj)" = $C2 ] && [ "$(n bin)" = 1 ] || cfail "trim should keep the $C2 objects and 1 program used recently, not $(n obj) and $(n bin)"
[ ! -d $cdir/core ] || cfail "trim left the old core/ layout"
EIDER_CACHE=$cdir $new build tests/run/closures.ei -o $tmp/clo3 && cmp -s $tmp/clo2 $tmp/clo3 || cfail "the build after the trim (a hit) differs"
[ "$(n obj)" = $C2 ] && [ "$(n bin)" = 1 ] || cfail "the entries kept by trim were not hits"
# the limit is applied after a build that added entries, at most every 15 minutes (the stamp)
EIDER_CACHE=$cdir $new build tests/run/adt.ei -o $tmp/adt3 || cfail "build to fill"
find $cdir/obj $cdir/bin -type f -exec touch -d '2 hours ago' {} +
rm -f $cdir/trimmed
EIDER_CACHE=$cdir EIDER_CACHE_MAX=1 $new build tests/run/heap.ei -o $tmp/m1 || cfail "build with the automatic trim"
[ "$(n obj)" = $H2 ] && [ "$(n bin)" = 1 ] || cfail "the automatic trim should leave the $H2 objects and 1 program of the last build, not $(n obj) and $(n bin)"
find $cdir/obj $cdir/bin -type f -exec touch -d '2 hours ago' {} +
EIDER_CACHE=$cdir EIDER_CACHE_MAX=1 $new build tests/run/adt.ei -o $tmp/adt4 || cfail "build after a recent trim"
[ "$(n bin)" = 2 ] || cfail "a build within 15 minutes of the last trim trimmed again"
EIDER_CACHE=$cdir EIDER_CACHE_MAX=12Q $new cache trim >/dev/null 2>&1 && cfail "a bad EIDER_CACHE_MAX was accepted"
EIDER_CACHE=$cdir $new cache clean >$tmp/o 2>&1 || cfail "cache clean"
[ "$(n obj)" = 0 ] && [ "$(n bin)" = 0 ] || cfail "clean left entries"
EIDER_CACHE=$cdir $new cache size | grep -q '^total  *0 files' || cfail "size after clean"
EIDER_CACHE=off $new cache size >/dev/null 2>&1 && cfail "cache size with the cache off should fail"
rm -rf $cdir $cdir.*
[ $cache_ok = 1 ] && echo "ok   cache: objects and programs, hits and misses, keys (flags, -O level), -j, 12 concurrent runs, parallel builds into one cache, comptime evaluators, EIDER_CACHE=off, LRU trim, automatic trim, clean, size"

# doc: `eiderc doc` (doc.ei) of the fixture package compiler/tests/doc/shapes as JSON, as text,
# with --private, and of one file, against the goldens (BLESS=1 rewrites them; review them by
# hand); core (with the prelude), std and every package under packages/ give JSON with no
# warning; an unreadable target exits 2
d_ok=1
for v in "json:--json" "txt:" "private.json:--json --private"; do
  ext=${v%%:*}
  $new doc ${v#*:} compiler/tests/doc/shapes 2>&1 | norm >$tmp/doc
  [ -n "$BLESS" ] && cp $tmp/doc compiler/tests/doc/shapes.$ext
  cmp -s $tmp/doc compiler/tests/doc/shapes.$ext || { echo "FAIL doc: eiderc doc ${v#*:} compiler/tests/doc/shapes"; diff compiler/tests/doc/shapes.$ext $tmp/doc | head -10; d_ok=0; }
done
$new doc --json compiler/tests/doc/shapes/util/geo.ei 2>&1 | norm >$tmp/doc
[ -n "$BLESS" ] && cp $tmp/doc compiler/tests/doc/geo.json
cmp -s $tmp/doc compiler/tests/doc/geo.json || { echo "FAIL doc: eiderc doc --json compiler/tests/doc/shapes/util/geo.ei"; diff compiler/tests/doc/geo.json $tmp/doc | head -10; d_ok=0; }
for p in core std packages/*/; do
  case $p in packages/*) [ -f "${p}eider.toml" ] || continue ;; esac  # leftovers of removed packages
  needs_vendor "${p%/}" && { echo "skip doc: eiderc doc --json $p $novendor"; continue; }
  $new doc --json "$p" >$tmp/doc 2>$tmp/doc_err || { echo "FAIL doc: eiderc doc --json $p exits $?"; d_ok=0; }
  [ -s $tmp/doc_err ] && { echo "FAIL doc: eiderc doc --json $p warns"; head -5 $tmp/doc_err; d_ok=0; }
done
$new doc --json core | grep -q '^{"package":"core","path":"prelude"' || { echo "FAIL doc: core has no prelude module"; d_ok=0; }
$new doc compiler/tests/doc/no-such-dir >/dev/null 2>&1
[ $? = 2 ] || { echo "FAIL doc: a missing target does not exit 2"; d_ok=0; }
if [ $d_ok = 1 ]; then echo "ok   doc: eiderc doc of compiler/tests/doc (JSON, text, --private, one file) equals the goldens; core, std and packages/* document without warnings"; else fail=1; fi

# usage: --help lists every command; unknown options and commands are errors
$new --help >$tmp/o 2>&1
code=$?
uok=1
[ $code = 0 ] || uok=0
for c in check emit-llvm emit-header build "build --lib" "build --wasm" run test "test --compile-fail" lex parse ir caps ide doc help version; do
  grep -q "^  eiderc $c " $tmp/o || { echo "FAIL usage: --help does not list \`$c\`"; uok=0; }
done
$new check --no-such-flag tests/run/adt.ei >/dev/null 2>&1
[ $? = 2 ] || { echo "FAIL usage: an unknown option is not an error"; uok=0; }
$new frobnicate tests/run/adt.ei >/dev/null 2>&1
[ $? = 2 ] || { echo "FAIL usage: an unknown command is not an error"; uok=0; }
$new check tests/run/adt.ei extra.ei >/dev/null 2>&1
[ $? = 2 ] || { echo "FAIL usage: a stray argument is not an error"; uok=0; }
# -j N (build.ei's job runner) and `cache size|clean|trim`
for bad in "-j" "-j 0" "-j x"; do
  $new build tests/run/adt.ei $bad >/dev/null 2>&1
  [ $? = 2 ] || { echo "FAIL usage: \`build $bad\` is not a usage error"; uok=0; }
done
for bad in "" "frob"; do
  $new cache $bad >/dev/null 2>&1
  [ $? = 2 ] || { echo "FAIL usage: \`cache $bad\` is not a usage error"; uok=0; }
done
# the version (docs/site/tooling/releases.md): VERSION, through core/version.ei
want="eiderc $(tr -d ' \n' < VERSION)"
for v in --version version; do
  got=$($new $v 2>&1)
  [ $? = 0 ] && [ "$got" = "$want" ] || { echo "FAIL usage: \`eiderc $v\` prints \`$got\`, not \`$want\`"; uok=0; }
done
head -1 $tmp/o | grep -q "^$want " || { echo "FAIL usage: --help does not start with \`$want\`"; uok=0; }
# the whole --help text is the oracle's (tests/oracle/compiler/main.help, the version written
# <VERSION>): every option and environment variable (WASM_CC too) is listed
sed "1s/^$want /eiderc <VERSION> /" $tmp/o >$tmp/help
bless compiler/main.ei help $tmp/help
want_of compiler/main.ei help | cmp -s - $tmp/help || { echo "FAIL usage: --help differs from the oracle"; want_of compiler/main.ei help | diff - $tmp/help | head -10; uok=0; }
# `run <file> [--] args...`: the program gets every argument after the file; after `--` also
# the ones that look like options (driver.run); with another command they are an error
printf '1: [a]\n2: [-b]\n3: [c d]\n4: [--release]\n5: [--]\n5\n' >$tmp/args_want
EIDER_CACHE=off $new run compiler/tests/driver/args.ei a -- -b "c d" --release -- >$tmp/args_got 2>&1
cmp -s $tmp/args_want $tmp/args_got || { echo "FAIL usage: run args.ei a -- ... gives:"; head -5 $tmp/args_got; uok=0; }
printf '1: [x]\n2: [y]\n2\n' >$tmp/args_want
EIDER_CACHE=off $new run compiler/tests/driver/args.ei --release x y >$tmp/args_got 2>&1
cmp -s $tmp/args_want $tmp/args_got || { echo "FAIL usage: run --release args.ei x y gives:"; head -5 $tmp/args_got; uok=0; }
$new check compiler/tests/driver/args.ei -- x >/dev/null 2>&1
[ $? = 2 ] || { echo "FAIL usage: program arguments to check are not an error"; uok=0; }
# the toolchain root (toolchain.ei, shared by the driver and resolve): an eiderc two levels
# below the root (<root>/bin/x/eiderc) finds the prelude, std and the core without EIDER_ROOT
tc=$(pwd)/target/tctest
rm -rf $tc
mkdir -p $tc/bin/x
cp $new $tc/bin/x/eiderc
ln -s "$(pwd)/core" $tc/core
ln -s "$(pwd)/std" $tc/std
targs=$(pwd)/compiler/tests/driver/args.ei
(unset EIDER_ROOT; cd $tc && EIDER_CACHE=off ./bin/x/eiderc run "$targs" deep) >$tmp/tc_got 2>&1
printf '1: [deep]\n1\n' | cmp -s - $tmp/tc_got || { echo "FAIL usage: an eiderc at <root>/bin/x/eiderc gives:"; head -5 $tmp/tc_got; uok=0; }
rm -rf $tc
# a module with no `main` (#140): `check` and `test` take it; `build` and `run` still want a main;
# `test` with no file runs every module's tests of the package in the current directory
pk=$(pwd)/target/pkgtest
newabs=$(cd "$(dirname "$new")" && pwd)/$(basename "$new")
rm -rf $pk
mkdir -p $pk/tests $pk/target $pk/examples
printf '[package]\nname = "pk"\nversion = "0.1.0"\neider = "0.3"\n' >$pk/eider.toml
printf 'pub fn double(n: i32) -> i32 { n * 2 }\n\ntest "double" {\n    assert double(4) == 8\n}\n' >$pk/lib.ei
printf 'import pk.lib\n\ntest "uses the lib" {\n    assert lib.double(3) == 6\n}\n' >$pk/tests/more_test.ei
printf 'test "skipped: examples/ is not run" {\n    assert 1 == 2\n}\n' >$pk/examples/e.ei
printf 'test "skipped: target/ is not run" {\n    assert 1 == 2\n}\n' >$pk/target/t.ei
(cd $pk && EIDER_CACHE=off $newabs check lib.ei) >$tmp/pk_got 2>&1
[ "$(cat $tmp/pk_got)" = ok ] || { echo "FAIL usage: check of a module with no main gives:"; head -3 $tmp/pk_got; uok=0; }
(cd $pk && EIDER_CACHE=off $newabs test lib.ei) >$tmp/pk_got 2>&1
[ $? = 0 ] && grep -q "^1 tests, 0 failed" $tmp/pk_got || { echo "FAIL usage: test of a module with no main gives:"; head -5 $tmp/pk_got; uok=0; }
(cd $pk && EIDER_CACHE=off $newabs test) >$tmp/pk_got 2>&1
[ $? = 0 ] && grep -q "^2 files, 3 tests, 0 failed" $tmp/pk_got && ! grep -q skipped $tmp/pk_got || { echo "FAIL usage: test in a package gives:"; head -12 $tmp/pk_got; uok=0; }
(cd $pk && EIDER_CACHE=off $newabs run lib.ei) >$tmp/pk_got 2>&1
[ $? != 0 ] && grep -q "no .main. function" $tmp/pk_got || { echo "FAIL usage: run of a module with no main gives:"; head -3 $tmp/pk_got; uok=0; }
rm -rf $pk
if [ $uok = 1 ]; then echo "ok   usage: --help lists every command and equals the oracle; unknown options, commands and stray arguments exit 2; --version is VERSION; run passes program arguments; an eiderc below <root>/bin finds the toolchain"; else fail=1; fi
exit $fail
