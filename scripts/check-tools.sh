#!/bin/sh
# The repositories next to this one, against this checkout: the editor tooling
# (eider-analyzer, the language server; tree-sitter-eider, the grammar Neovim highlights
# with), which must keep up with the language (a syntax or IDE-visible change updates them
# in the same wave: LAYERS.md, "Tooling"), and the libraries and frameworks that left this
# repository (LAYERS.md, "Where code lives"; eider-toml, eider-json, eider-markdown,
# eider-http, eider-rpc, eider-openapi), which must keep building and passing their tests
# on it. This is the "tools" leg of scripts/verify.sh.
#
#   scripts/check-tools.sh
#
# Where the repositories are: EIDER_<NAME> for each (EIDER_ANALYZER, TREE_SITTER_EIDER,
# EIDER_TOML, EIDER_JSON, EIDER_MARKDOWN, EIDER_HTTP, EIDER_RPC, EIDER_OPENAPI), else
# $EIDER_SIBLINGS/<repository> (EIDER_SIBLINGS: default .., the directory holding this
# checkout). One that is absent is `skip`, so a plain checkout stays green.
#
# - versions: the tools ship with the toolchain (docs/site/tooling/releases.md), and before
#   1.0 the libraries keep its MAJOR.MINOR too: each sibling's VERSION must have
#   eider-lang's MAJOR.MINOR (VERSION) and agree with its own files (its scripts/version.sh
#   check, when it has one); `scripts/version.sh check-siblings`. One line, `ok   versions:
#   <each component's version>`, naming the repositories that are absent, or `FAIL ...` per
#   sibling that differs.
# - eider-analyzer: a copy of the repository (its sources, without target/) whose eider.toml
#   points at this checkout is fetched (`eider-pkg fetch`), built (its scripts/build.sh, which
#   builds the compiler from this checkout's compiler/) and tested (tests/run.sh: the scripted
#   sessions, and tests/clean.sh, no diagnostics on any file of examples/ and std/). Its json
#   dependency comes from the eider-json checkout, else this checkout's vendor/json
#   (EIDER_PKG_OVERRIDE). The repository itself is left alone.
# - tree-sitter-eider: its scripts/check-eider-lang.sh on this checkout (every .ei file parses
#   without ERROR or MISSING nodes, apart from the fixtures meant not to parse).
# - each library: its VERSION must have this checkout's MAJOR.MINOR (before 1.0 they move
#   together), then a copy of it is built and tested (scripts/test.sh, with EIDER_ROOT this
#   checkout) with its git dependencies taken from the sibling checkouts (EIDER_PKG_OVERRIDE,
#   through the EIDER_<NAME> its scripts/env.sh reads), json from vendor/json when there is
#   no eider-json checkout. One whose dependency has no checkout is skipped (it would need
#   the network). The store is a fresh $EIDER_HOME.
#
# Each prints `ok   ...`, `FAIL ...` (with the failures under it) or `skip: <reason>`. Exits 1
# if one fails, else 0.
cd "$(dirname "$0")/.." || exit 1
here=$(pwd -P)
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
sib=${EIDER_SIBLINGS:-$here/..}
series=$(sed -n '1s/^\([0-9]*\.[0-9]*\)\..*/\1/p' VERSION)
EIDER_HOME=$T/home
export EIDER_HOME

# copy <repo> <dir>: the repository's files, without target/ and .git
copy() {
  mkdir -p "$2"
  (cd "$1" && find . -path ./target -prune -o -path ./.git -prune -o -type f -print -o -type l -print) |
    while read -r f; do mkdir -p "$2/$(dirname "$f")"; cp -P "$1/$f" "$2/$f"; done
}
# repo_dir <repository> <VAR>: where it is, or nothing
repo_dir() {
  eval "d=\${$2:-$sib/$1}"
  [ -f "$d/eider.toml" ] || [ -f "$d/grammar.js" ] || return 1
  (cd "$d" && pwd -P)
}

# ---- versions
sh "$here/scripts/version.sh" check-siblings > "$T/versions" 2>&1
vrc=$?
if [ $vrc = 0 ]; then
  have="eider-lang $(tr -d ' \n' < "$here/VERSION")"
  for c in $(sed -n 's/^ok   \([a-z-]*\) \([^ ]*\) .*/\1:\2/p' "$T/versions"); do have="$have, ${c%%:*} ${c#*:}"; done
  absent=$(sed -n 's/^skip: \([a-z-]*\):.*/\1/p' "$T/versions" | paste -sd, - | sed 's/,/, /g')
  if [ -n "$absent" ]; then echo "ok   versions: $have (same MAJOR.MINOR; absent: $absent)"; else echo "ok   versions: $have (same MAJOR.MINOR)"; fi
else
  grep -v '^ok\|^skip' "$T/versions"
  fail=1
fi

# The libraries' checkouts, exported as the EIDER_<NAME> their scripts/env.sh reads (json
# falls back to vendor/json, the release this checkout pins).
LIBS="toml json markdown http rpc openapi"
for n in $LIBS; do
  var=EIDER_$(echo "$n" | tr 'a-z' 'A-Z')
  if d=$(repo_dir "eider-$n" "$var"); then eval "$var=\$d"; export "$var"; else unset "$var"; fi
done
[ -n "$EIDER_JSON" ] || { EIDER_JSON=$here/vendor/json; export EIDER_JSON; json_from="vendor/json"; }
json_from=${json_from:-$EIDER_JSON}

# ---- eider-analyzer
if ! an=$(repo_dir eider-analyzer EIDER_ANALYZER) || [ ! -f "$an/scripts/build.sh" ] || [ ! -f "$an/tests/run.sh" ]; then
  echo "skip: eider-analyzer: no repository at ${EIDER_ANALYZER:-$sib/eider-analyzer} (set EIDER_ANALYZER or EIDER_SIBLINGS)"
elif ! command -v "${CC:-cc}" >/dev/null 2>&1; then
  echo "skip: eider-analyzer: no C compiler (${CC:-cc})"
else
  w=$T/eider-analyzer
  copy "$an" "$w"
  # its path dependencies point into this checkout, whatever its eider.toml says
  sed -E "s#^(path = \")[^\"]*eider-lang/#\1$here/#" "$an/eider.toml" > "$w/eider.toml"
  rm -f "$w/eider.lock"
  if ! EIDER_PKG_OVERRIDE="json=$EIDER_JSON" "$here/scripts/eider-pkg" -C "$w" fetch > "$T/an.log" 2>&1; then
    echo "FAIL eider-analyzer: eider-pkg fetch (json from $json_from)"
    tail -5 "$T/an.log" | sed 's/^/  /'
    fail=1
  elif ! EIDER_LANG=$here EIDER_ROOT=$here sh "$w/scripts/build.sh" > "$T/an.log" 2>&1; then
    echo "FAIL eider-analyzer: build ($an against $here)"
    grep -E '^error|-->|build.sh' "$T/an.log" | head -10 | sed 's/^/  /'
    fail=1
  elif EIDER_LANG=$here EIDER_ROOT=$here NOBUILD=1 sh "$w/tests/run.sh" > "$T/an.log" 2>&1; then
    echo "ok   eider-analyzer ($(grep -c '^ok' "$T/an.log") test groups: sessions, no diagnostics on examples/ and std/, stand-in, perf; json from $json_from)"
  else
    echo "FAIL eider-analyzer: tests/run.sh ($an against $here)"
    grep -A8 '^FAIL' "$T/an.log" | head -30 | sed 's/^/  /'
    fail=1
  fi
fi

# ---- tree-sitter-eider
if ! ts=$(repo_dir tree-sitter-eider TREE_SITTER_EIDER) || [ ! -f "$ts/scripts/check-eider-lang.sh" ]; then
  echo "skip: tree-sitter-eider: no repository with scripts/check-eider-lang.sh at ${TREE_SITTER_EIDER:-$sib/tree-sitter-eider} (set TREE_SITTER_EIDER or EIDER_SIBLINGS)"
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

# ---- the libraries and frameworks
# needs <name>: the git dependencies (other than json) it can't build without
needs() { case $1 in http) echo "" ;; rpc|openapi) echo "http" ;; *) echo "" ;; esac; }
for n in $LIBS; do
  var=EIDER_$(echo "$n" | tr 'a-z' 'A-Z')
  eval "d=\${$var:-}"
  if [ -z "$d" ] || [ "$d" = "$here/vendor/$n" ]; then
    echo "skip: eider-$n: no repository at $sib/eider-$n (set $var or EIDER_SIBLINGS)"
    continue
  fi
  missing=
  for dep in $(needs "$n"); do
    dv=EIDER_$(echo "$dep" | tr 'a-z' 'A-Z')
    eval "dd=\${$dv:-}"
    [ -n "$dd" ] || missing="$missing eider-$dep"
  done
  if [ -n "$missing" ]; then
    echo "skip: eider-$n: needs a checkout of$missing (else it fetches it from its repository)"
    continue
  fi
  v=$(tr -d ' \n' < "$d/VERSION" 2>/dev/null)
  if [ "${v%.*}" != "$series" ]; then
    echo "FAIL eider-$n: VERSION is \`$v\`, but this checkout is Eider $(cat VERSION): libraries keep the toolchain's MAJOR.MINOR before 1.0 (LAYERS.md)"
    fail=1
    continue
  fi
  w=$T/eider-$n
  copy "$d" "$w"
  # without a sibling next to the copy, scripts/env.sh takes each dependency from EIDER_<NAME>
  if EIDER_ROOT=$here EIDER_LANG= sh "$w/scripts/test.sh" > "$T/$n.log" 2>&1; then
    echo "ok   eider-$n $v ($(grep -c '^ok' "$T/$n.log") tests against this checkout)"
  else
    echo "FAIL eider-$n $v: scripts/test.sh ($d against $here)"
    grep -B2 -A10 '^FAIL\|: ' "$T/$n.log" | head -30 | sed 's/^/  /'
    fail=1
  fi
done
exit $fail
