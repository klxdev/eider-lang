#!/bin/sh
# Remembers a green verify, so that releasing doesn't repeat it (#134).
#
#   sh scripts/verify-stamp.sh write <log>   verify.sh ended ALL GREEN: record it (target/verify-green.*)
#   sh scripts/verify-stamp.sh check         exit 0 when the recorded run is for this very state
#   sh scripts/verify-stamp.sh key           print the state a run is recorded for
#   sh scripts/verify-stamp.sh write-selfhost / check-selfhost    the same for scripts/selfhost.sh
#
# The state: the eider-lang commit (the tree must be clean: a dirty tree has no state, so
# nothing is recorded or accepted), the commit of each sibling (EIDER_SIBLINGS, default ..;
# dirty or absent is part of the state), and the versions of the toolchain that matters (cc,
# clang, gcc, wasm-ld, node, zig). A stamp that doesn't match, or a log that doesn't end in
# `ALL GREEN`, means verify runs again.
cd "$(dirname "$0")/.." || exit 1
here=$(pwd -P)
sibs=${EIDER_SIBLINGS:-$here/..}
key() {
  if [ -n "$(git status --porcelain)" ]; then echo dirty; return 1; fi
  echo "eider-lang $(git rev-parse HEAD)"
  for r in eider-analyzer tree-sitter-eider eider-profiler eider-toml eider-json eider-markdown eider-http eider-rpc eider-openapi; do
    case $r in
      eider-analyzer) d=${EIDER_ANALYZER:-$sibs/$r} ;;
      tree-sitter-eider) d=${TREE_SITTER_EIDER:-$sibs/$r} ;;
      eider-profiler) d=${EIDER_PROFILER:-$sibs/$r} ;;
      eider-toml) d=${EIDER_TOML:-$sibs/$r} ;;
      eider-json) d=${EIDER_JSON:-$sibs/$r} ;;
      eider-markdown) d=${EIDER_MARKDOWN:-$sibs/$r} ;;
      eider-http) d=${EIDER_HTTP:-$sibs/$r} ;;
      eider-rpc) d=${EIDER_RPC:-$sibs/$r} ;;
      eider-openapi) d=${EIDER_OPENAPI:-$sibs/$r} ;;
    esac
    if [ ! -d "$d" ]; then echo "$r absent"; continue; fi
    if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then echo "$r dirty"; continue; fi
    echo "$r $(git -C "$d" rev-parse HEAD 2>/dev/null || echo none)"
  done
  for c in "${CC:-cc}" clang gcc; do
    echo "$c $("$c" --version 2>/dev/null | head -1)"
  done
  echo "wasm-ld $(wasm-ld --version 2>/dev/null | head -1)"
  echo "node $(node --version 2>/dev/null)"
  echo "zig $(zig version 2>/dev/null)"
}
mkdir -p target
case $1 in
  key) key ;;
  write)
    [ -f "$2" ] || { echo "verify-stamp: write needs the log" >&2; exit 2; }
    k=$(key) || { echo "verify-stamp: the tree is dirty: not recorded"; rm -f target/verify-green.key; exit 0; }
    printf '%s\n' "$k" > target/verify-green.key
    cp "$2" target/verify-green.log ;;
  check)
    k=$(key) || exit 1
    [ -f target/verify-green.key ] && [ "$(cat target/verify-green.key)" = "$k" ] && tail -1 target/verify-green.log 2>/dev/null | grep -q "^ALL GREEN$" ;;
  write-selfhost)
    k=$(key) || exit 0
    printf '%s\n' "$k" > target/selfhost-green.key ;;
  check-selfhost)
    k=$(key) || exit 1
    [ -f target/selfhost-green.key ] && [ "$(cat target/selfhost-green.key)" = "$k" ] ;;
  *) echo "usage: sh scripts/verify-stamp.sh write <log> | check | key | write-selfhost | check-selfhost" >&2; exit 2 ;;
esac
