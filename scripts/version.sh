#!/bin/sh
# Versions of the Eider toolchain and the tools shipped with it (docs/site/tooling/releases.md).
#
#   scripts/version.sh                       print every component's version
#   scripts/version.sh check                 this checkout's copies of VERSION agree (a verify leg)
#   scripts/version.sh check-siblings        each sibling tool's VERSION has this MAJOR.MINOR,
#                                            and agrees with its own files (scripts/check-tools.sh)
#   scripts/version.sh bump <major|minor|patch> [component]
#
# eider-lang's VERSION (MAJOR.MINOR.PATCH) is the version of the language, the compiler
# (eiderc), core, std, eider-pkg and eider-doc. The sibling tools, eider-analyzer,
# tree-sitter-eider and eider-profiler, each have their own VERSION, with the same
# MAJOR.MINOR and their own PATCH; they are released together (scripts/release.sh). Before
# 1.0 a MINOR bump may break compatibility, so packages name the MAJOR.MINOR they need
# (`eider = "0.1"` in eider.toml; the compiler refuses another, E0811).
#
# Copies of VERSION in this checkout, held equal by `check`:
#   core/version.ei            VERSION, MAJOR, MINOR, PATCH, SERIES (what eiderc --version,
#                              eider-pkg --version and eider-doc --version print)
#   `version` in core/, std/, compiler/, packages/pkg/ (eider-pkg) and packages/doc/
#   (eider-doc) eider.toml
#   `eider` (MAJOR.MINOR) in the eider.toml of core, std, compiler, packages/* and examples/*
# Library packages (packages/json, http, ...) keep their own `version`.
#
# bump: `major` or `minor` moves every component (this checkout and every sibling found) to
# the next MAJOR.MINOR with PATCH 0, and rewrites every `eider = "<old MAJOR.MINOR>"` in the
# eider.toml files here and in the siblings; `patch` bumps one component's PATCH (default
# eider-lang). A sibling's own copies of its VERSION are rewritten by its
# `scripts/version.sh sync`. Nothing is committed; the command prints what to do next (an
# eider-lang bump changes core/version.ei, which the seed embeds: regenerate it).
#
# Siblings: EIDER_ANALYZER, TREE_SITTER_EIDER, EIDER_PROFILER name the repositories (default
# ../<name> next to this checkout); one that is absent is skipped and said so.
cd "$(dirname "$0")/.." || exit 1
here=$(pwd -P)
SIBLINGS="eider-analyzer tree-sitter-eider eider-profiler"

die() { echo "version.sh: $*" >&2; exit 2; }
valid() { echo "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; }
read_version() { [ -f "$1/VERSION" ] && tr -d ' \n' < "$1/VERSION"; }
series_of() { echo "${1%.*}"; }
# sibling_dir <name>: its repository, or nothing when absent
sibling_dir() {
  case $1 in
    eider-analyzer) d=${EIDER_ANALYZER:-$here/../eider-analyzer} ;;
    tree-sitter-eider) d=${TREE_SITTER_EIDER:-$here/../tree-sitter-eider} ;;
    eider-profiler) d=${EIDER_PROFILER:-$here/../eider-profiler} ;;
    *) return ;;
  esac
  [ -d "$d" ] && (cd "$d" && pwd -P)
}
sibling_var() {
  case $1 in eider-analyzer) echo EIDER_ANALYZER ;; tree-sitter-eider) echo TREE_SITTER_EIDER ;; eider-profiler) echo EIDER_PROFILER ;; esac
}

V=$(read_version "$here")
valid "$V" || die "VERSION must be MAJOR.MINOR.PATCH, not \`$V\`"
S=$(series_of "$V")

# The eider.toml files that must carry `eider = "<series>"`.
manifests() {
  for f in core/eider.toml std/eider.toml compiler/eider.toml packages/*/eider.toml examples/*/eider.toml; do
    [ -f "$f" ] && echo "$f"
  done
}
# The eider.toml files whose `version` is the toolchain's.
toolchain_manifests() {
  for f in core/eider.toml std/eider.toml compiler/eider.toml packages/pkg/eider.toml packages/doc/eider.toml; do
    [ -f "$f" ] && echo "$f"
  done
}
toml_value() { sed -n "s/^$2 = \"\(.*\)\"\$/\1/p" "$1" | head -1; }
ei_const() { sed -n "s/^pub const $1: [a-z0-9]* = \"*\([^\"]*\)\"*\$/\1/p" core/version.ei; }

# rewrite <file> <awk program>: the file through awk (v: version, s: series, o: old series)
rewrite() { awk -v v="$NEWV" -v s="$NEWS" -v o="$OLDS" "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

check_here() {
  bad=0
  want() { [ "$2" = "$3" ] || { echo "FAIL version: $1 is \`$2\`, VERSION says $3"; bad=1; }; }
  want "core/version.ei VERSION" "$(ei_const VERSION)" "$V"
  want "core/version.ei MAJOR" "$(ei_const MAJOR)" "${V%%.*}"
  m=${V#*.}; want "core/version.ei MINOR" "$(ei_const MINOR)" "${m%%.*}"
  want "core/version.ei PATCH" "$(ei_const PATCH)" "${V##*.}"
  want "core/version.ei SERIES" "$(ei_const SERIES)" "$S"
  for f in $(toolchain_manifests); do want "\`version\` in $f" "$(toml_value "$f" version)" "$V"; done
  n=0
  for f in $(manifests); do want "\`eider\` in $f" "$(toml_value "$f" eider)" "$S"; n=$((n + 1)); done
  [ $bad = 0 ] && echo "ok   version $V: core/version.ei, $(toolchain_manifests | wc -l | tr -d ' ') toolchain eider.toml versions, \`eider = \"$S\"\` in $n eider.toml files"
  return $bad
}

check_siblings() {
  bad=0
  for name in $SIBLINGS; do
    d=$(sibling_dir "$name")
    if [ -z "$d" ]; then echo "skip: $name: no repository (set $(sibling_var "$name"))"; continue; fi
    sv=$(read_version "$d")
    if [ -z "$sv" ]; then echo "FAIL $name: no VERSION in $d"; bad=1; continue; fi
    if ! valid "$sv"; then echo "FAIL $name: VERSION in $d is \`$sv\`, not MAJOR.MINOR.PATCH"; bad=1; continue; fi
    if [ "$(series_of "$sv")" != "$S" ]; then
      echo "FAIL $name $sv: MAJOR.MINOR is not eider-lang's ($V): the tools ship together (scripts/version.sh bump)"
      bad=1; continue
    fi
    if [ -f "$d/scripts/version.sh" ]; then
      if ! out=$(sh "$d/scripts/version.sh" check 2>&1); then
        echo "FAIL $name $sv: its scripts/version.sh check"; printf '%s\n' "$out" | sed 's/^/  /'; bad=1; continue
      fi
    fi
    echo "ok   $name $sv (eider-lang $V)"
  done
  return $bad
}

show() {
  printf '%-18s %-8s %s\n' eider-lang "$V" "$here (eiderc, core, std, eider-pkg, eider-doc)"
  for name in $SIBLINGS; do
    d=$(sibling_dir "$name")
    if [ -z "$d" ]; then printf '%-18s %-8s %s\n' "$name" - "absent (set $(sibling_var "$name"))"; continue; fi
    sv=$(read_version "$d"); [ -n "$sv" ] || sv="(no VERSION)"
    note=$d
    valid "$sv" && [ "$(series_of "$sv")" != "$S" ] && note="$d  MAJOR.MINOR differs from eider-lang's"
    printf '%-18s %-8s %s\n' "$name" "$sv" "$note"
  done
}

# next <version> <major|minor|patch>
next() {
  ma=${1%%.*}; r=${1#*.}; mi=${r%%.*}; pa=${1##*.}
  case $2 in
    major) echo "$((ma + 1)).0.0" ;;
    minor) echo "$ma.$((mi + 1)).0" ;;
    patch) echo "$ma.$mi.$((pa + 1))" ;;
  esac
}

# write this checkout's copies of NEWV (NEWS, OLDS set)
# (refused while VERSION or core/version.ei has uncommitted changes: a bump on top of a bump)
write_here() {
  git diff --quiet HEAD -- VERSION core/version.ei 2>/dev/null || die "VERSION or core/version.ei has uncommitted changes (commit or revert the last bump first)"
  echo "$NEWV" > VERSION
  ma=${NEWV%%.*}; r=${NEWV#*.}; mi=${r%%.*}; pa=${NEWV##*.}
  rewrite core/version.ei "
    /^pub const VERSION: str = / { print \"pub const VERSION: str = \\\"\" v \"\\\"\"; next }
    /^pub const MAJOR: u64 = / { print \"pub const MAJOR: u64 = $ma\"; next }
    /^pub const MINOR: u64 = / { print \"pub const MINOR: u64 = $mi\"; next }
    /^pub const PATCH: u64 = / { print \"pub const PATCH: u64 = $pa\"; next }
    /^pub const SERIES: str = / { print \"pub const SERIES: str = \\\"\" s \"\\\"\"; next }
    { print }"
  for f in $(toolchain_manifests); do
    rewrite "$f" '!d && /^version = "/ { print "version = \"" v "\""; d = 1; next } { print }'
  done
}

# every `eider = "<OLDS>"` under <dir> becomes NEWS
rewrite_series() {
  find "$1" -name eider.toml -not -path '*/target/*' -not -path '*/.claude/*' -not -path '*/node_modules/*' -not -path '*/.git/*' |
    while read -r f; do
      grep -q "^eider = \"$OLDS\"\$" "$f" && rewrite "$f" '$0 == "eider = \"" o "\"" { print "eider = \"" s "\""; next } { print }'
    done
}

bump() {
  kind=$1; comp=${2:-eider-lang}
  case $kind in major|minor|patch) ;; *) die "bump <major|minor|patch> [component]" ;; esac
  if [ "$kind" != patch ]; then
    [ -z "$2" ] || [ "$2" = eider-lang ] || die "a $kind bump moves every component together; name no component"
    NEWV=$(next "$V" "$kind"); NEWS=$(series_of "$NEWV"); OLDS=$S
    write_here
    rewrite_series "$here"
    echo "eider-lang         $V -> $NEWV"
    for name in $SIBLINGS; do
      d=$(sibling_dir "$name")
      if [ -z "$d" ]; then echo "skip $name: no repository (set $(sibling_var "$name"))"; continue; fi
      old=$(read_version "$d")
      echo "$NEWV" > "$d/VERSION"
      rewrite_series "$d"
      if [ -f "$d/scripts/version.sh" ]; then sh "$d/scripts/version.sh" sync >/dev/null || echo "FAIL $name: scripts/version.sh sync"; fi
      printf '%-18s %s -> %s\n' "$name" "${old:-?}" "$NEWV"
    done
  elif [ "$comp" = eider-lang ]; then
    NEWV=$(next "$V" patch); NEWS=$S; OLDS=$S
    write_here
    echo "eider-lang         $V -> $NEWV"
  else
    case " $SIBLINGS " in *" $comp "*) ;; *) die "unknown component \`$comp\` (eider-lang $SIBLINGS)" ;; esac
    d=$(sibling_dir "$comp")
    [ -n "$d" ] || die "$comp: no repository (set $(sibling_var "$comp"))"
    old=$(read_version "$d"); valid "$old" || die "$comp: VERSION is \`$old\`"
    [ "$(series_of "$old")" = "$S" ] || die "$comp $old: MAJOR.MINOR differs from eider-lang's $V; bump minor first"
    NEWV=$(next "$old" patch)
    echo "$NEWV" > "$d/VERSION"
    if [ -f "$d/scripts/version.sh" ]; then sh "$d/scripts/version.sh" sync >/dev/null || echo "FAIL $comp: scripts/version.sh sync"; fi
    printf '%-18s %s -> %s\n' "$comp" "$old" "$NEWV"
  fi
  echo
  echo "next:"
  if [ "$kind" != patch ] || [ "$comp" = eider-lang ]; then
    echo "  sh scripts/selfhost.sh --seed           # the seed embeds core/version.ei (eiderc --version)"
    echo "  BLESS=1 sh scripts/test-compiler.sh     # E0811 messages name the MAJOR.MINOR; review the diff"
  fi
  echo "  add the new version's section to CHANGELOG.md in each repository bumped, then commit each"
  echo "  sh scripts/release.sh                   # when the user asks to release"
}

case "${1:-}" in
  ""|show) show ;;
  check) check_here ;;
  check-siblings) check_siblings ;;
  bump) shift; bump "$@" ;;
  *) echo "usage: scripts/version.sh [show | check | check-siblings | bump <major|minor|patch> [component]]" >&2; exit 2 ;;
esac
