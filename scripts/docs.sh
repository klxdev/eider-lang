#!/bin/sh
# The documentation site (docs/site/CONTRACT.md, docs/site/tooling/eider-doc.md):
#   sh scripts/docs.sh [eider-doc build options]   builds it into target/site
#   sh scripts/docs.sh test                       runs the doc tests of the pages and of
#                                                 the doc comments of core, std and packages/*
# Needs only a C compiler: the compiler comes from the seed (scripts/ei) and eider-doc is
# built with it. The seed's compiler has no `eiderc doc` until the seed is regenerated after
# docs/compiler.md "Documentation: `eiderc doc`", so until then this uses compiler/ as the
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
if [ ! -x $bin ] || [ -n "$(find packages/doc packages/markdown packages/json std core -name '*.ei' -newer $bin 2>/dev/null | head -1)" ]; then
  scripts/ei build packages/doc/main.ei -o $bin >target/eider-doc.log 2>&1 || { cat target/eider-doc.log; echo "docs: cannot build eider-doc"; exit 3; }
fi
if [ "$1" = test ]; then
  shift
  exec $bin test "$@"
fi
exec $bin build --out target/site "$@"
