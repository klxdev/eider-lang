#!/bin/sh
# The repositories next to this one, against this checkout: the editor tooling
# (eider-analyzer, the language server; tree-sitter-eider, the grammar Neovim highlights
# with), which must keep up with the language (a syntax or IDE-visible change updates them
# in the same wave: LAYERS.md, "Tooling"), and the libraries and frameworks that left this
# repository (LAYERS.md, "Where code lives"; eider-toml, eider-json, eider-markdown, eider-logging, eider-command,
# eider-http, eider-rpc, eider-openapi, eider-compression, eider-tls, eider-postgres), which must keep building and passing their tests
# on it. This is the "tools" leg of scripts/verify.sh.
#
#   scripts/check-tools.sh
#
# Where the repositories are: EIDER_<NAME> for each (EIDER_ANALYZER, TREE_SITTER_EIDER,
# EIDER_TOML, EIDER_JSON, EIDER_MARKDOWN, EIDER_LOGGING, EIDER_COMMAND, EIDER_HTTP, EIDER_RPC, EIDER_OPENAPI, EIDER_COMPRESSION, EIDER_TLS, EIDER_POSTGRES, EIDER_TLS), else
# $EIDER_SIBLINGS/<repository> (EIDER_SIBLINGS: default .., the directory holding this
# checkout). One that is absent is `skip`, so a plain checkout stays green.
#
# - versions: the tools ship with the toolchain (docs/site/tooling/releases.md), and before
#   1.0 the libraries keep its MAJOR.MINOR too: each sibling's VERSION must have
#   eider-lang's MAJOR.MINOR (VERSION) and agree with its own files (its scripts/version.sh
#   check, when it has one); `scripts/version.sh check-siblings`. One line, `ok   versions:
#   <each component's version>`, naming the repositories that are absent, or `FAIL ...` per
#   sibling that differs.
# - eider-analyzer: a copy of the repository (its sources, without target/) is built (its
#   scripts/build.sh, with EIDER_TOOLCHAIN this checkout: its eider.toml's eiderc dependency is
#   the toolchain's compiler/, which build.sh links as target/toolchain) and tested
#   (tests/run.sh: the scripted sessions, and tests/clean.sh, no diagnostics on any file of
#   examples/ and std/). Its json dependency comes from the eider-json checkout, else this
#   checkout's .vendor/json, the pinned release (EIDER_PKG_OVERRIDE). The repository itself
#   is left alone.
# - tree-sitter-eider: its scripts/check-eider-lang.sh on this checkout (every .ei file parses
#   without ERROR or MISSING nodes, apart from the fixtures meant not to parse).
# - each library: its VERSION must have this checkout's MAJOR.MINOR (before 1.0 they move
#   together), then a copy of it is built and tested (scripts/test.sh, with EIDER_TOOLCHAIN
#   this checkout) with its git dependencies taken from the sibling checkouts (EIDER_PKG_OVERRIDE,
#   through the EIDER_<NAME> its scripts/env.sh reads), json from .vendor/json when there is
#   no eider-json checkout. One whose dependency has no checkout is skipped (it would need
#   the network). The store is a fresh $EIDER_HOME.
# eider-pkg (for the analyzer and the libraries) needs .vendor/toml, and json's fallback
# .vendor/json: both are fetched by scripts/vendor.sh (from the checkouts when they are here);
# what needs one that can't be fetched is skipped.
#
# The siblings' scripts find their toolchain as `eider` does, EIDER_TOOLCHAIN first (else the
# installed release `eider toolchain show` names), so EIDER_TOOLCHAIN=<this checkout> is what
# makes them build and test against it; they run eiderc and eider-pkg through `eider` when it
# is on the PATH, else this checkout's scripts/ei and scripts/eider-pkg directly.
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
# falls back to .vendor/json, the release this checkout pins).
LIBS="toml json markdown logging command http rpc openapi compression tls postgres"
for n in $LIBS; do
  var=EIDER_$(echo "$n" | tr 'a-z' 'A-Z')
  if d=$(repo_dir "eider-$n" "$var"); then eval "$var=\$d"; export "$var"; else unset "$var"; fi
done
# fetched: vendor_ok <name>: .vendor/<name> is the pinned release (else $novendor says why)
vendor_ok() {
  sh "$here/scripts/vendor.sh" fetch "$1" > "$T/vendor-$1" 2>&1 && return 0
  novendor="no checkout of eider-$1 here, and .vendor/$1 can't be fetched ($(grep 'cannot fetch' "$T/vendor-$1" | head -1 | sed 's/^vendor.sh: //; s/, no source has it.*//'): sh scripts/vendor.sh fetch $1)"
  grep -q 'cannot fetch' "$T/vendor-$1" || { echo "FAIL vendor: sh scripts/vendor.sh fetch $1"; sed 's/^/  /' "$T/vendor-$1"; fail=1; }
  return 1
}
nopkg=
vendor_ok toml || nopkg="eider-pkg can't be built: $novendor"
nojson=
if [ -z "$EIDER_JSON" ]; then
  if vendor_ok json; then EIDER_JSON=$here/.vendor/json; export EIDER_JSON; json_from=".vendor/json"; else nojson=$novendor; fi
fi
json_from=${json_from:-$EIDER_JSON}

# ---- eider-analyzer
if ! an=$(repo_dir eider-analyzer EIDER_ANALYZER) || [ ! -f "$an/scripts/build.sh" ] || [ ! -f "$an/tests/run.sh" ]; then
  echo "skip: eider-analyzer: no repository at ${EIDER_ANALYZER:-$sib/eider-analyzer} (set EIDER_ANALYZER or EIDER_SIBLINGS)"
elif ! command -v "${CC:-cc}" >/dev/null 2>&1; then
  echo "skip: eider-analyzer: no C compiler (${CC:-cc})"
elif [ -n "$nopkg" ] || [ -n "$nojson" ]; then
  echo "skip: eider-analyzer: ${nopkg:-$nojson}"
else
  w=$T/eider-analyzer
  copy "$an" "$w"
  rm -f "$w/eider.lock"
  if ! EIDER_TOOLCHAIN=$here EIDER_PKG_OVERRIDE="json=$EIDER_JSON" sh "$w/scripts/build.sh" > "$T/an.log" 2>&1; then
    echo "FAIL eider-analyzer: build ($an against $here; json from $json_from)"
    grep -E '^error|-->|build.sh|FAIL' "$T/an.log" | head -10 | sed 's/^/  /'
    fail=1
  elif EIDER_TOOLCHAIN=$here NOBUILD=1 sh "$w/tests/run.sh" > "$T/an.log" 2>&1; then
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
needs() { case $1 in http) echo "logging" ;; rpc|openapi) echo "http logging" ;; *) echo "" ;; esac; }
for n in $LIBS; do
  var=EIDER_$(echo "$n" | tr 'a-z' 'A-Z')
  eval "d=\${$var:-}"
  if [ -z "$d" ] || [ "$d" = "$here/.vendor/$n" ]; then
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
  if [ -n "$nopkg" ]; then echo "skip: eider-$n: $nopkg"; continue; fi
  if [ -n "$nojson" ] && grep -q '^\[deps\.json\]' "$d/eider.toml"; then echo "skip: eider-$n: $nojson"; continue; fi
  v=$(tr -d ' \n' < "$d/VERSION" 2>/dev/null)
  if [ "${v%.*}" != "$series" ]; then
    echo "FAIL eider-$n: VERSION is \`$v\`, but this checkout is Eider $(cat VERSION): libraries keep the toolchain's MAJOR.MINOR before 1.0 (LAYERS.md)"
    fail=1
    continue
  fi
  w=$T/eider-$n
  copy "$d" "$w"
  # without a sibling next to the copy, scripts/env.sh takes each dependency from EIDER_<NAME>
  if EIDER_TOOLCHAIN=$here sh "$w/scripts/test.sh" > "$T/$n.log" 2>&1; then
    echo "ok   eider-$n $v ($(grep -c '^ok' "$T/$n.log") tests against this checkout)"
  else
    echo "FAIL eider-$n $v: scripts/test.sh ($d against $here)"
    grep -B2 -A10 '^FAIL\|: ' "$T/$n.log" | head -30 | sed 's/^/  /'
    fail=1
  fi
done
exit $fail
