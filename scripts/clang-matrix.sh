#!/bin/sh
# Builds the compiler and runs the compile-fail, run and oracle suites against several clang
# versions (#169): programs are built by clang from LLVM (the backend writes textual IR,
# docs/compiler.md "Backends"), and the verify run otherwise sees only the clang installed on
# the development machine.
#
#   sh scripts/clang-matrix.sh [--fetch] [--list] [--quick] [17 20 22 23]
#
# The versions tested by default are MATRIX below: the oldest clang the documentation claims
# (17), one in between (20), the current release (22) and the next one (23). For each, in order:
#   1. compiler/ is built with that clang (EIDER_LLVM_CC) into a scratch directory, by target/eiderc
#      (or $EIDER_MATRIX_BUILDER),
#   2. the compile-fail and pass suite (tests/checks) runs with that compiler,
#   3. tests/run.sh: every run test, built and run with that clang,
#   4. scripts/test-compiler.sh: that compiler against the recorded oracle (tests/oracle),
#      which builds and runs the run tests again at -O2, under UBSan, with the allocation
#      counter, and so on, all with that clang. --quick leaves this step out.
# --except-default leaves out the version of the clang on PATH ($EIDER_LLVM_CC), which every
# other leg of scripts/verify.sh already builds and runs programs with (the llvms leg).
# A summary line per version, `ok   clang N (X.Y.Z): ...`, goes to stdout; a failure is
# `FAIL clang N ...` with the first lines of the failing step, and the exit status is 1.
#
# Where a version's clang comes from, in order: $EIDER_CLANG_<N> (a path to its clang); an
# unpacked LLVM release in $EIDER_CLANG_DIR/<X.Y.Z>/ (default ~/.cache/eider/clang; the cache
# holds only bin/clang and lib/clang, the part needed to compile IR); the clang on PATH (or
# clang-<N>) when its major version is N; else, with --fetch (or EIDER_CLANG_FETCH=1), the LLVM
# release downloaded from github.com/llvm/llvm-project, its SHA-256 checked against the one
# pinned below, and unpacked into the cache (linux-x86_64 only). A version that can't be found
# is `skip`ped with the reason and is never reported as tested; the exit status is 2 when
# every version was skipped (and 0 when at least one ran and all of those passed).
# `--list` prints, per version, which clang would be used and exits.
#
# scripts/verify.sh runs this as its `llvms` leg for the versions other than the one on PATH
# (the other legs cover that one), unless EIDER_CLANG_VERIFY=0.
cd "$(dirname "$0")/.." || exit 1
root=$(pwd -P)
MATRIX="17 20 22 23"
CACHE=${EIDER_CLANG_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/eider/clang}

# release <major>: the LLVM release tested for it, its tarball name and SHA-256
release_of() {
  case $1 in
    17) echo "17.0.6 clang+llvm-17.0.6-x86_64-linux-gnu-ubuntu-22.04.tar.xz 884ee67d647d77e58740c1e645649e29ae9e8a6fe87c1376be0f3a30f3cc9ab3" ;;
    20) echo "20.1.8 LLVM-20.1.8-Linux-X64.tar.xz 1ead36b3dfcb774b57be530df42bec70ab2d239fbce9889447c7a29a4ddc1ae6" ;;
    22) echo "22.1.8 LLVM-22.1.8-Linux-X64.tar.xz df0e1ecf16caf3489a272a5eea4eec9b0d82878f6477fa309504f918a0006384" ;;
    23) echo "23.1.5 LLVM-23.1.5-Linux-X64.tar.xz f72edb0b36580ece7f52e23858f00c18fad4e87395ea7ad05d7e55c39f8fc78a" ;;
  esac
}
major_of() { "$1" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9]*\)\..*/\1/p' | head -1; }
full_of() { "$1" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9.]*\).*/\1/p' | head -1; }

fetch=${EIDER_CLANG_FETCH:-0}; list=0; quick=0; except=0; versions=
for a in "$@"; do
  case $a in
    --fetch) fetch=1 ;;
    --list) list=1 ;;
    --quick) quick=1 ;;
    --except-default) except=1 ;;
    -*) echo "usage: sh scripts/clang-matrix.sh [--fetch] [--list] [--quick] [--except-default] [major ...]" >&2; exit 2 ;;
    *) versions="$versions $a" ;;
  esac
done
[ -n "$versions" ] || versions=$MATRIX
if [ $except = 1 ]; then
  dm=$(major_of "${EIDER_LLVM_CC:-clang}")
  keep=
  for n in $versions; do [ "$n" = "$dm" ] || keep="$keep $n"; done
  versions=$keep
fi

# quiet <clang>: its path, or a wrapper's when the dynamic loader complains on stderr about
# the release's libtinfo (LLVM 17's Ubuntu build on a distribution whose libtinfo has no symbol
# versions: "no version information available", one line per run, which fails the tests that
# compare stderr). The wrapper (bash) drops those lines and execs the clang.
quiet() {
  if "$1" --version 2>&1 >/dev/null | grep -q "no version information"; then
    w=$(dirname "$1")/clang-quiet
    printf '#!/bin/bash\nexec "%s" "$@" 2> >(grep -v "no version information available" >&2)\n' "$1" > "$w"
    chmod +x "$w"
    echo "$w"
  else
    echo "$1"
  fi
}

# find_clang <major>: prints the clang's path, or nothing; sets WHY to the reason when none
find_clang() {
  WHY=
  n=$1
  rel=$(release_of "$n")
  [ -n "$rel" ] || { WHY="no release is pinned for clang $n (MATRIX in scripts/clang-matrix.sh)"; return; }
  set -- $rel; full=$1; tarball=$2; sum=$3
  eval "e=\${EIDER_CLANG_$n:-}"
  if [ -n "$e" ]; then
    [ "$(major_of "$e")" = "$n" ] && { echo "$e"; return; }
    WHY="EIDER_CLANG_$n=$e is not clang $n"; return
  fi
  if [ -x "$CACHE/$full/bin/clang" ] && [ "$(major_of "$CACHE/$full/bin/clang")" = "$n" ]; then quiet "$CACHE/$full/bin/clang"; return; fi
  for c in clang clang-$n; do
    p=$(command -v "$c" 2>/dev/null) && [ "$(major_of "$p")" = "$n" ] && { echo "$p"; return; }
  done
  if [ "$fetch" != 1 ]; then
    WHY="clang $n ($full) is not installed (sh scripts/clang-matrix.sh --fetch downloads it into $CACHE; EIDER_CLANG_$n names one)"
    return
  fi
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) ;;
    *) WHY="clang $n can't be downloaded here: the releases are fetched for linux-x86_64 only (EIDER_CLANG_$n names one)"; return ;;
  esac
  command -v curl >/dev/null && command -v tar >/dev/null && command -v sha256sum >/dev/null || { WHY="fetching clang $n needs curl, tar (with xz) and sha256sum"; return; }
  mkdir -p "$CACHE/dl" || { WHY="cannot create $CACHE"; return; }
  if [ ! -f "$CACHE/dl/$tarball" ]; then
    echo "clang-matrix: downloading $tarball" >&2
    curl -fsSL -o "$CACHE/dl/$tarball.part" "https://github.com/llvm/llvm-project/releases/download/llvmorg-$full/$tarball" || { rm -f "$CACHE/dl/$tarball.part"; WHY="cannot download $tarball from github.com/llvm/llvm-project"; return; }
    mv "$CACHE/dl/$tarball.part" "$CACHE/dl/$tarball"
  fi
  got=$(sha256sum "$CACHE/dl/$tarball" | sed 's/ .*//')
  [ "$got" = "$sum" ] || { WHY="$tarball has SHA-256 $got, not the pinned $sum (delete $CACHE/dl/$tarball)"; return; }
  rm -rf "$CACHE/$full.part"; mkdir -p "$CACHE/$full.part"
  tar -xf "$CACHE/dl/$tarball" -C "$CACHE/$full.part" --strip-components=1 --wildcards '*/bin/clang' '*/bin/clang-[0-9]*' '*/lib/clang' >&2 || { rm -rf "$CACHE/$full.part"; WHY="cannot unpack $tarball"; return; }
  rm -rf "$CACHE/$full"; mv "$CACHE/$full.part" "$CACHE/$full"
  [ "$(major_of "$CACHE/$full/bin/clang")" = "$n" ] && { quiet "$CACHE/$full/bin/clang"; return; }
  WHY="the unpacked $tarball does not run here ($CACHE/$full/bin/clang --version)"
}

if [ $list = 1 ]; then
  for n in $versions; do
    c=$(find_clang "$n")
    if [ -n "$c" ]; then echo "clang $n: $c ($(full_of "$c"))"; else echo "clang $n: missing: $WHY"; fi
  done
  exit 0
fi

sh scripts/ei --help >/dev/null || { echo "FAIL clang-matrix: build target/eiderc from seed/eiderc.wasm"; exit 1; }
# the compiler that builds compiler/ for each clang: the seed's (target/eiderc, which is what a clone has);
# EIDER_MATRIX_BUILDER=<eiderc> uses another, e.g. a compiler/ built since the seed was regenerated
BUILDER=${EIDER_MATRIX_BUILDER:-target/eiderc}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fail=0; ran=0; skipped=0
for n in $versions; do
  c=$(find_clang "$n")
  if [ -z "$c" ]; then echo "skip clang $n: $WHY"; skipped=$((skipped + 1)); continue; fi
  v=$(full_of "$c"); d=$W/$n; mkdir -p "$d"
  t0=$(date +%s)
  export EIDER_LLVM_CC=$c EIDER_CACHE=off
  # 1. the compiler, built by this clang
  if ! $BUILDER build compiler/main.ei -o "$d/eiderc" > "$d/build.log" 2>&1; then
    echo "FAIL clang $n ($v): building compiler/ with $c"; grep -v "libtinfo" "$d/build.log" | head -12; fail=1; continue
  fi
  # 2. the compile-fail and pass suite
  "$d/eiderc" test --compile-fail tests/checks > "$d/cf.log" 2>&1
  if ! tail -1 "$d/cf.log" | grep -q " 0 failed"; then
    echo "FAIL clang $n ($v): compile-fail suite (eiderc test --compile-fail tests/checks)"; tail -5 "$d/cf.log"; fail=1; continue
  fi
  # 3. the run tests
  EIDER="$d/eiderc" bash tests/run.sh > "$d/run.log" 2>&1
  nrun=$(grep -c "^ok" "$d/run.log"); nbad=$(grep -vc "^ok" "$d/run.log")
  if [ "$nbad" != 0 ]; then
    echo "FAIL clang $n ($v): run tests ($nbad of $((nrun + nbad)) failed)"; grep -v "^ok" "$d/run.log" | head -8; fail=1; continue
  fi
  # 4. the oracle
  steps="compiler built, compile-fail suite, $nrun run tests"
  if [ $quick = 0 ]; then
    EIDERC="$d/eiderc" sh scripts/test-compiler.sh > "$d/oracle.log" 2>&1; orc=$?
    if grep -q "^FAIL" "$d/oracle.log" || [ $orc != 0 ]; then
      echo "FAIL clang $n ($v): the oracle (scripts/test-compiler.sh; exit $orc)"; grep -A6 "^FAIL" "$d/oracle.log" | head -24; tail -3 "$d/oracle.log"; fail=1; continue
    fi
    steps="$steps, oracle ($(grep -c '^ok' "$d/oracle.log") groups ok)"
  fi
  echo "ok   clang $n ($v): $steps; $(( $(date +%s) - t0 ))s"
  ran=$((ran + 1))
done
[ $fail = 0 ] || exit 1
[ $ran -gt 0 ] || exit 2
exit 0
