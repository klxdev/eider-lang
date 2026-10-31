#!/bin/sh
# The documentation site (docs/site/CONTRACT.md, docs/site/tooling/eider-doc.md):
#   sh scripts/docs.sh [eider-doc build options]   builds it into target/site
#   sh scripts/docs.sh test                       runs the doc tests of the pages and of
#                                                 the doc comments of core, std and packages/*
# Needs only a C compiler: the compiler comes from the seed (scripts/ei) and eider-doc is
# built with it. When the seed's compiler has no `eiderc doc` (a compiler change that hasn't
# reached the seed yet), this uses compiler/ as the
# seed builds it (target/eiderc-next, rebuilt when compiler/, std/ or core/ is newer).
cd "$(dirname "$0")/.." || exit 1
mkdir -p target
scripts/ei --help >/dev/null || { echo "docs: cannot build target/eiderc from the seed"; exit 3; }
if ./target/eiderc doc --json core/sys.ei >/dev/null 2>&1; then
  EIDERC=$(pwd)/target/eiderc
else
  next=target/eiderc-next
  if [ ! -x $next ] || [ -n "$(find compiler std core -name '*.ei' -newer $next 2>/dev/null | head -1)" ]; then
    EIDER_CACHE=off scripts/ei build compiler/main.ei -o $next >target/eiderc-next.log 2>&1 || { cat target/eiderc-next.log; echo "docs: cannot build compiler/"; exit 3; }
  fi
  EIDERC=$(pwd)/$next
fi
export EIDERC
bin=target/eider-doc
if [ ! -x $bin ] || [ -n "$(find packages/doc vendor/markdown vendor/json std core -name '*.ei' -newer $bin 2>/dev/null | head -1)" ]; then
  scripts/ei build packages/doc/main.ei -o $bin >target/eider-doc.log 2>&1 || { cat target/eider-doc.log; echo "docs: cannot build eider-doc"; exit 3; }
fi
if [ "$1" = test ]; then
  shift
  # with the cache off (verify.sh) every test would compile the C core again: give the run
  # a fresh cache of its own instead, removed afterwards
  if [ "$EIDER_CACHE" = off ]; then
    EIDER_CACHE=$(mktemp -d); export EIDER_CACHE
    $bin test "$@"; code=$?
    rm -rf "$EIDER_CACHE"
    exit $code
  fi
  exec $bin test "$@"
fi
exec $bin build --out target/site --repo-url "${EIDER_REPO_URL:-https://github.com/klxdev/eider-lang/blob/main}" "$@"
