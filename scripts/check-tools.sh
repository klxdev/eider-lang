#!/bin/sh
# The editor tooling against this checkout: eider-analyzer (the language server) and
# tree-sitter-eider (the grammar Neovim highlights with) live in their own repositories and
# must keep up with the language. A syntax or IDE-visible change updates them in the same
# wave (LAYERS.md, "Tooling"); this script is the check that they did, and the "tools" leg
# of scripts/verify.sh.
#
#   scripts/check-tools.sh
#
# EIDER_ANALYZER and TREE_SITTER_EIDER name the repositories (default: ../eider-analyzer and
# ../tree-sitter-eider next to this checkout).
#
# - eider-analyzer: a copy of the repository (its sources, without target/) whose eider.toml
#   points at this checkout is fetched (`eider-pkg fetch`), built (its scripts/build.sh, which
#   builds the compiler from this checkout's compiler/) and tested (tests/run.sh: the scripted
#   sessions, and tests/clean.sh, no diagnostics on any file of examples/ and std/). The
#   repository itself is left alone.
# - tree-sitter-eider: its scripts/check-eider-lang.sh on this checkout (every .ei file parses
#   without ERROR or MISSING nodes, apart from the fixtures meant not to parse).
#
# Each half prints `ok   ...`, `FAIL ...` (with the failures under it) or `skip: <reason>` when
# its repository or a tool it needs is missing. Exits 1 if a half fails, else 0.
cd "$(dirname "$0")/.." || exit 1
here=$(pwd -P)
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---- eider-analyzer
an=${EIDER_ANALYZER:-$here/../eider-analyzer}
if [ ! -f "$an/eider.toml" ] || [ ! -f "$an/scripts/build.sh" ] || [ ! -f "$an/tests/run.sh" ]; then
  echo "skip: eider-analyzer: no repository at $an (set EIDER_ANALYZER)"
elif ! command -v "${CC:-cc}" >/dev/null 2>&1; then
  echo "skip: eider-analyzer: no C compiler (${CC:-cc})"
else
  an=$(cd "$an" && pwd -P)
  w=$T/eider-analyzer
  mkdir -p "$w"
  (cd "$an" && find . -path ./target -prune -o -path ./.git -prune -o -type f -print -o -type l -print) |
    while read -r f; do mkdir -p "$w/$(dirname "$f")"; cp -P "$an/$f" "$w/$f"; done
  # its path dependencies point into this checkout, whatever its eider.toml says
  sed -E "s#^(path = \")[^\"]*eider-lang/#\1$here/#" "$an/eider.toml" > "$w/eider.toml"
  rm -f "$w/eider.lock"
  if ! "$here/scripts/eider-pkg" -C "$w" fetch > "$T/an.log" 2>&1; then
    echo "FAIL eider-analyzer: eider-pkg fetch"
    tail -5 "$T/an.log" | sed 's/^/  /'
    fail=1
  elif ! EIDER_LANG=$here sh "$w/scripts/build.sh" > "$T/an.log" 2>&1; then
    echo "FAIL eider-analyzer: build ($an against $here)"
    grep -E '^error|-->' "$T/an.log" | head -10 | sed 's/^/  /'
    fail=1
  elif EIDER_LANG=$here NOBUILD=1 sh "$w/tests/run.sh" > "$T/an.log" 2>&1; then
    echo "ok   eider-analyzer ($(grep -c '^ok' "$T/an.log") test groups: sessions, no diagnostics on examples/ and std/, stand-in, perf)"
  else
    echo "FAIL eider-analyzer: tests/run.sh ($an against $here)"
    grep -A8 '^FAIL' "$T/an.log" | head -30 | sed 's/^/  /'
    fail=1
  fi
fi

# ---- tree-sitter-eider
ts=${TREE_SITTER_EIDER:-$here/../tree-sitter-eider}
if [ ! -f "$ts/grammar.js" ] || [ ! -f "$ts/scripts/check-eider-lang.sh" ]; then
  echo "skip: tree-sitter-eider: no repository with scripts/check-eider-lang.sh at $ts (set TREE_SITTER_EIDER)"
else
  sh "$ts/scripts/check-eider-lang.sh" "$here" > "$T/ts.log" 2>&1
  code=$?
  if [ $code = 0 ]; then
    grep '^ok' "$T/ts.log"
  elif [ $code = 2 ]; then
    # no tree-sitter CLI (or no C compiler to build the parser)
    echo "skip: tree-sitter-eider: $(sed 's/^check-eider-lang: //' "$T/ts.log" | head -1)"
  else
    sed -n '1p' "$T/ts.log"
    sed -n '2,31p' "$T/ts.log"
    fail=1
  fi
fi
exit $fail
