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
# MAJOR.MINOR and their own PATCH; they are released together (scripts/release.sh). So,
# before 1.0, are the libraries and frameworks in repositories of their own (eider-toml,
# eider-json, eider-markdown, eider-logging, eider-command, eider-http, eider-rpc, eider-openapi; LAYERS.md, U19): their
# VERSION keeps the toolchain's MAJOR.MINOR, with their own PATCH. Before 1.0 a MINOR bump
# may break compatibility, so packages name the MAJOR.MINOR they need (`eider = "0.1"` in
# eider.toml; the compiler refuses another, E0811). So is eider-example-shopping-service, the
# example application (a VERSION, and `eider = "<MAJOR.MINOR>"` in its server/, shared/ and
# shared-wasm/ manifests; its `version =` lines are its own packages', and verify does not
# build it). eider-http-testclient is not one: ~/workplace/eider-http-testclient is an old
# working copy of eider-http's repository (same origin, package `http`), not a repository of
# its own; the test client is eider-http's `http/testing`.
#
# Copies of VERSION in this checkout, held equal by `check`:
#   core/version.ei            VERSION, MAJOR, MINOR, PATCH, SERIES (what eiderc --version,
#                              eider-pkg --version and eider-doc --version print)
#   `version` in core/, std/, compiler/, packages/pkg/ (eider-pkg) and packages/doc/
#   (eider-doc) eider.toml
#   `eider` (MAJOR.MINOR) in the eider.toml of core, std, compiler, packages/* and examples/*
# (.vendor/<name>, the pinned releases of eider-toml, eider-json and eider-markdown, are their
# repositories' files and are not rewritten here: pin a new release, scripts/vendor.sh.)
#
# bump: `major` or `minor` moves every component (this checkout and every sibling found) to
# the next MAJOR.MINOR with PATCH 0, and rewrites every `eider = "<old MAJOR.MINOR>"` in the
# eider.toml files here and in the siblings; `patch` bumps one component's PATCH (default
# eider-lang). A sibling's own copies of its VERSION are rewritten by its
# `scripts/version.sh sync`. Nothing is committed; the command prints what to do next (an
# eider-lang bump changes core/version.ei, which the seed embeds: regenerate it).
#
# What a bump rewrites besides VERSION (#205), so that the release prep needs no hand edits:
#   - in every sibling, each `[package]` `version = "<its old VERSION>"` in its eider.toml
#     files (a library's own version line, also where it has no scripts/version.sh);
#   - (minor, major) each `[deps.*]` pin `version = "..."` of a dependency whose repository
#     is a sibling's (eider-json, eider-http, ...), to that sibling's new version;
#   - the series and version text of docs, tests and goldens, in eider-lang and the siblings:
#     `eider = "<old series>"` (also inside a quoted string), `toolchain is <old series>`,
#     `port it to <old series>`, `asks for Eider <old series>`, `toolchain install <old
#     series>`, `"toolchain":"<old version>"` (the `eiderc doc` goldens), `--version <old>` of
#     `eider add` for a sibling library, and the version/series output block of
#     docs/site/tooling/releases.md. CHANGELOGs, docs/decisions.md, docs/compiler.md,
#     docs/research, docs/design and the seed are history and are left alone.
# It FAILS (exit 1, each place named) where it cannot finish by itself: a sibling with no valid
# VERSION, or whose own `version` line was not the old VERSION, text of the old series that is
# left after the rewrite. `check` also fails while vendor.lock pins a release of another
# series (scripts/vendor.sh needs the sibling's committed release, so the bump prints that
# step). At the end it prints the steps that need commits: the seed, the oracle, the tag
# commands for the siblings publish.sh and release.sh do not tag (the libraries and the
# shopping example), vendor.sh for eider-toml, eider-json and eider-markdown, and the
# directories whose eider.lock needs `eider-pkg update`.
#
# Siblings: EIDER_ANALYZER, TREE_SITTER_EIDER, EIDER_PROFILER, EIDER_TOML, EIDER_JSON,
# EIDER_MARKDOWN, EIDER_LOGGING, EIDER_COMMAND, EIDER_HTTP, EIDER_RPC, EIDER_OPENAPI, EIDER_EXAMPLE_SHOPPING_SERVICE name the repositories (default
# $EIDER_SIBLINGS/<name>, EIDER_SIBLINGS defaulting to .., the directory holding this
# checkout); one that is absent is skipped and said so.
cd "$(dirname "$0")/.." || exit 1
here=$(pwd -P)
SIBLINGS="eider-analyzer tree-sitter-eider eider-profiler eider-toml eider-json eider-markdown eider-logging eider-command eider-http eider-rpc eider-openapi eider-example-shopping-service"

die() { echo "version.sh: $*" >&2; exit 2; }
valid() { echo "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; }
read_version() { [ -f "$1/VERSION" ] && tr -d ' \n' < "$1/VERSION"; }
series_of() { echo "${1%.*}"; }
# sibling_dir <name>: its repository, or nothing when absent
sibling_dir() {
  case " $SIBLINGS " in *" $1 "*) ;; *) return ;; esac
  eval "d=\${$(sibling_var "$1"):-${EIDER_SIBLINGS:-$here/..}/$1}"
  [ -d "$d" ] && (cd "$d" && pwd -P)
}
# sibling_var <name>: the variable naming it (tree-sitter-eider -> TREE_SITTER_EIDER,
# eider-json -> EIDER_JSON)
sibling_var() { echo "$1" | tr 'a-z-' 'A-Z_'; }

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
  # vendor.lock pins releases of the libraries eider-lang's tools use: the toolchain's series
  if [ -f vendor.lock ]; then
    vn=0
    for pv in $(sed -n 's/^version = "\([0-9][^"]*\)"$/\1/p' vendor.lock); do
      vn=$((vn + 1)); want "vendor.lock package #$vn series" "$(series_of "$pv")" "$S"
    done
  fi
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
    if [ ! -f "$d/scripts/version.sh" ]; then
      # no check of its own: every `eider = "..."` in its manifests is this series
      for f in $(cd "$d" && find . -name eider.toml -not -path '*/target/*' -not -path './.git/*' -not -path '*/node_modules/*'); do
        if grep -q '^eider = "' "$d/$f" && ! grep -q "^eider = \"$S\"\$" "$d/$f"; then
          echo "FAIL $name $sv: \`$(sed -n 's/^eider = //p' "$d/$f" | head -1)\` in $f, not \`\"$S\"\`"; bad=1; continue 2
        fi
      done
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
  # (paths are matched relative to <dir>: a checkout that is itself under .claude/worktrees/ is
  # searched, and the repository's own .claude/, which holds other worktrees, is not)
  (cd "$1" && find . -name eider.toml -not -path '*/target/*' -not -path './.claude/*' -not -path '*/node_modules/*' -not -path './.git/*') |
    while read -r f; do
      f="$1/${f#./}"
      grep -q "^eider = \"$OLDS\"\$" "$f" && rewrite "$f" '$0 == "eider = \"" o "\"" { print "eider = \"" s "\""; next } { print }'
    done
}

# ---- #205: the text a bump rewrites besides the manifests ----

# text_files <dir>: the files of <dir> whose series and version text a bump rewrites (not
# history: changelogs, decisions, the compiler's design log, research, the seed, vendored copies)
text_files() {
  (cd "$1" && find . \( -path ./.git -o -path ./.claude -o -path ./.vendor -o -path ./seed -o -path ./docs/research -o -path ./docs/design \
        -o -path '*/target' -o -path '*/node_modules' -o -path '*/.vendor' \) -prune -o -type f \
      \( -name '*.md' -o -name '*.sh' -o -name '*.json' -o -name '*.out' -o -name '*.ei' -o -name '*.toml' -o -name '*.txt' \) \
      -not -name 'CHANGELOG*.md' -not -name decisions.md -not -name compiler.md -not -name package-lock.json \
      -not -name tree-sitter.json -print) | sed 's|^\./||' | sort
}
dots() { printf '%s' "$1" | sed 's/\./\\./g'; }

# rewrite_text <dir> <kind> <old version> <old series> <new version> <new series>: the
# series and version text, in place; prints the files it changed
rewrite_text() {
  rt_d=$1; rt_kind=$2; rt_ov=$3; rt_os=$4; rt_nv=$5; rt_ns=$6
  ov=$(dots "$rt_ov"); os=$(dots "$rt_os")
  tl='($|[^.0-9]|\.($|[^0-9]))'
  sedf=$here/target/version-sh-sed.$$
  mkdir -p "$here/target"; : > "$sedf"
  if [ "$rt_os" != "$rt_ns" ]; then
    {
      echo "s/eider = (\\\\?\")$os(\\\\?\")/eider = \\1$rt_ns\\2/g"
      echo "s/(toolchain is )$os$tl/\\1$rt_ns\\2/g"
      echo "s/(port it to )$os$tl/\\1$rt_ns\\2/g"
      echo "s/(asks for Eider )$os$tl/\\1$rt_ns\\2/g"
      echo "s/(toolchain install )$os$tl/\\1$rt_ns\\2/g"
    } >> "$sedf"
  fi
  if [ "$rt_ov" != "$rt_nv" ]; then
    echo "s/(\"toolchain\": ?\")$ov(\")/\\1$rt_nv\\2/g" >> "$sedf"
    # the language server's session goldens: serverInfo of the initialize reply
    echo "s/(\"name\": ?\"eider-analyzer\", ?\"version\": ?\")$ov(\")/\\1$rt_nv\\2/g" >> "$sedf"
  fi
  # `eider add json --git .../eider-json.git --version 0.6.0`: a library follows the toolchain on a minor/major bump.
  # Its version is the library's, not eider-lang's: after a patch release (0.7.1) the docs still name 0.7.0, so
  # any patch of the old series is rewritten
  [ "$rt_kind" = patch ] || [ "$rt_os" = "$rt_ns" ] || echo "/klxdev\\/eider-[a-z]+\\.git/ s/(--version )$os\\.[0-9]+( |\$)/\\1$rt_nv\\2/g" >> "$sedf"
  for f in $(text_files "$rt_d"); do
    f="$rt_d/$f"
    sed -E -f "$sedf" "$f" > "$f.tmp" || { rm -f "$f.tmp"; continue; }
    # the releases page prints version.VERSION and version.SERIES: an output block of the two lines
    # (only a file that has the line: awk would add a missing final newline to the others)
    if [ "$rt_ov" != "$rt_nv" ] && grep -qxF "$rt_ov" "$f.tmp"; then
      awk -v ov="$rt_ov" -v os="$rt_os" -v nv="$rt_nv" -v ns="$rt_ns" '
        held != "" { if ($0 == os) { print nv; print ns; held = ""; next } print held; held = "" }
        $0 == ov { held = $0; next }
        { print }
        END { if (held != "") print held }' "$f.tmp" > "$f.tmp2" && mv "$f.tmp2" "$f.tmp"
    fi
    if cmp -s "$f" "$f.tmp"; then rm -f "$f.tmp"; else cat "$f.tmp" > "$f"; rm -f "$f.tmp"; echo "  text: ${f#$rt_d/}"; fi
  done
  rm -f "$sedf"
}

# audit_text <dir> <old version> <old series>: places that still say the old series in the
# shapes rewrite_text knows; prints them; fails when there is one
audit_text() {
  at_bad=0; ov=$(dots "$2"); os=$(dots "$3")
  for f in $(text_files "$1"); do
    out=$(grep -nE "eider = (\\\\?\")$os(\\\\?\")|toolchain is $os([^.0-9]|\\.?\$)|port it to $os([^.0-9]|\\.?\$)|\"toolchain\": ?\"$ov\"|\"name\": ?\"eider-analyzer\", ?\"version\": ?\"$ov\"" "$1/$f" 2>/dev/null)
    [ -z "$out" ] || { printf '%s\n' "$out" | sed "s|^|FAIL left over: $f:|"; at_bad=1; }
  done
  return $at_bad
}

# manifests_of <dir>: the eider.toml files under <dir>
manifests_of() {
  (cd "$1" && find . \( -path ./.git -o -path ./.claude -o -path '*/target' -o -path '*/node_modules' -o -path '*/.vendor' \) -prune -o -name eider.toml -print) | sed 's|^\./||'
}

# set_own_versions <dir> <old> <new>: `[package]` `version = "<old>"` in the eider.toml files
# under <dir> (a library's own version, the cli package that ships with it)
set_own_versions() {
  manifests_of "$1" | while read -r f; do
    f="$1/$f"
    awk -v o="$2" -v n="$3" '/^\[/ { pk = ($0 == "[package]") } pk && $0 == "version = \"" o "\"" { print "version = \"" n "\""; next } { print }' "$f" > "$f.tmp"
    if cmp -s "$f" "$f.tmp"; then rm -f "$f.tmp"; else cat "$f.tmp" > "$f"; rm -f "$f.tmp"; echo "  own version: ${f#$1/}"; fi
  done
}

# set_pins <dir> "<repo>=<version> ...": every `[deps.*]` table whose `git` names one of those
# repositories gets `version = "<version>"`
set_pins() {
  manifests_of "$1" | while read -r f; do
    f="$1/$f"
    awk -v map="$2" '
      BEGIN { n = split(map, kv, " "); for (i = 1; i <= n; i++) { split(kv[i], p, "="); nv[p[1]] = p[2] } }
      function flush(   i, l) {
        for (i = 1; i <= k; i++) {
          l = buf[i]
          if (repo in nv && l ~ /^version = "/) l = "version = \"" nv[repo] "\""
          print l
        }
        k = 0; repo = ""
      }
      /^\[/ { flush(); insec = ($0 ~ /^\[deps\./) }
      { buf[++k] = $0 }
      insec && /^git = "/ { r = $0; sub(/^git = ".*\//, "", r); sub(/\.git".*$/, "", r); repo = r }
      END { flush() }' "$f" > "$f.tmp"
    if cmp -s "$f" "$f.tmp"; then rm -f "$f.tmp"; else cat "$f.tmp" > "$f"; rm -f "$f.tmp"; echo "  pins: ${f#$1/}"; fi
  done
}

# bump_sibling <name> <dir> <old version> <kind>: its VERSION, its own version lines, its text;
# fails (BUMPBAD) where it cannot
bump_sibling() {
  name=$1; d=$2; old=$3; kind=$4
  if [ -z "$old" ] || ! valid "$old"; then echo "FAIL $name: VERSION in $d is \`$old\`, not MAJOR.MINOR.PATCH"; BUMPBAD=1; return; fi
  echo "$NEWV" > "$d/VERSION"
  [ "$kind" = patch ] || rewrite_series "$d"
  set_own_versions "$d" "$old" "$NEWV"
  if [ -f "$d/scripts/version.sh" ]; then
    sh "$d/scripts/version.sh" sync >/dev/null || { echo "FAIL $name: scripts/version.sh sync"; BUMPBAD=1; }
    sh "$d/scripts/version.sh" check >/dev/null 2>&1 || { echo "FAIL $name: scripts/version.sh check after sync"; BUMPBAD=1; }
  fi
  if [ -f "$d/eider.toml" ] && ! grep -q "^version = \"$NEWV\"\$" "$d/eider.toml"; then
    echo "FAIL $name: no \`version = \"$NEWV\"\` in $d/eider.toml after the bump (its own line was not \`$old\`): edit it"
    BUMPBAD=1
  fi
}

# tag_command <dir> <name> <version> <toolchain version>
tag_command() {
  printf '  git -C %s tag -a v%s -m "%s %s (Eider %s)" && git -C %s push origin v%s\n' "$1" "$3" "$2" "$3" "$4" "$1" "$3"
}

bump() {
  kind=$1; comp=${2:-eider-lang}
  case $kind in major|minor|patch) ;; *) die "bump <major|minor|patch> [component]" ;; esac
  BUMPBAD=0; found=
  if [ "$kind" != patch ]; then
    [ -z "$2" ] || [ "$2" = eider-lang ] || die "a $kind bump moves every component together; name no component"
    NEWV=$(next "$V" "$kind"); NEWS=$(series_of "$NEWV"); OLDS=$S
    write_here
    rewrite_series "$here"
    echo "eider-lang         $V -> $NEWV"
    pins=
    for name in $SIBLINGS; do [ -n "$(sibling_dir "$name")" ] && pins="$pins $name=$NEWV"; done
    set_pins "$here" "$pins"
    rewrite_text "$here" "$kind" "$V" "$S" "$NEWV" "$NEWS"
    audit_text "$here" "$V" "$S" || BUMPBAD=1
    for name in $SIBLINGS; do
      d=$(sibling_dir "$name")
      if [ -z "$d" ]; then echo "skip $name: no repository (set $(sibling_var "$name"))"; continue; fi
      old=$(read_version "$d")
      printf '%-18s %s -> %s\n' "$name" "${old:-?}" "$NEWV"
      bump_sibling "$name" "$d" "$old" "$kind"
      set_pins "$d" "$pins"
      rewrite_text "$d" "$kind" "$old" "$S" "$NEWV" "$NEWS"
      audit_text "$d" "$old" "$S" || BUMPBAD=1
      found="$found $name"
    done
  elif [ "$comp" = eider-lang ]; then
    NEWV=$(next "$V" patch); NEWS=$S; OLDS=$S
    write_here
    rewrite_text "$here" patch "$V" "$S" "$NEWV" "$NEWS"
    echo "eider-lang         $V -> $NEWV"
  else
    case " $SIBLINGS " in *" $comp "*) ;; *) die "unknown component \`$comp\` (eider-lang $SIBLINGS)" ;; esac
    d=$(sibling_dir "$comp")
    [ -n "$d" ] || die "$comp: no repository (set $(sibling_var "$comp"))"
    old=$(read_version "$d"); valid "$old" || die "$comp: VERSION is \`$old\`"
    [ "$(series_of "$old")" = "$S" ] || die "$comp $old: MAJOR.MINOR differs from eider-lang's $V; bump minor first"
    NEWV=$(next "$old" patch); NEWS=$S
    bump_sibling "$comp" "$d" "$old" patch
    rewrite_text "$d" patch "$old" "$S" "$NEWV" "$NEWS"
    printf '%-18s %s -> %s\n' "$comp" "$old" "$NEWV"
    found=$comp
    echo "(dependency pins are minimums, so nothing that depends on $comp is rewritten; raise a pin when it needs this fix)"
  fi
  if [ $BUMPBAD != 0 ]; then
    echo
    echo "version.sh: the bump is NOT complete (the FAIL lines above): fix those, then \`sh scripts/version.sh check-siblings\`" >&2
    exit 1
  fi
  echo
  echo "next:"
  if [ "$kind" != patch ] || [ "$comp" = eider-lang ]; then
    echo "  sh scripts/selfhost.sh --seed           # the seed embeds core/version.ei (eiderc --version);"
    echo "                                          # after major/minor, bootstrap first: seed/README.md"
    echo "  BLESS=1 sh scripts/test-compiler.sh     # E0811 messages name the MAJOR.MINOR; review the diff"
  fi
  echo "  add the new version's section to CHANGELOG.md in each repository bumped, then commit each"
  echo "  (prose that names a RELEASED version, like a README's \"built with the published toolchain 0.7.0\", is not rewritten)"
  if [ "$kind" != patch ]; then
    echo "  then, once each library is committed (vendor.lock and the lock files pin their commits):"
    echo "  tag the siblings that publish.sh and release.sh do not (the libraries and the example; release.sh prints the three tools'):"
    for name in eider-toml eider-json eider-markdown eider-logging eider-command eider-http eider-rpc eider-openapi eider-example-shopping-service; do
      d=$(sibling_dir "$name"); [ -n "$d" ] && tag_command "$d" "$name" "$NEWV" "$NEWV"
    done
    echo "  sh scripts/vendor.sh toml <commit of eider-toml's $NEWV>   # likewise json, markdown: vendor.lock names $S releases"
    echo "  re-lock after the tags are pushed (their pins name tags): eider-pkg update, in"
    for name in $found; do
      d=$(sibling_dir "$name")
      (cd "$d" && find . -name eider.lock -not -path '*/target/*' -not -path '*/node_modules/*' -not -path '*/.vendor/*') | sed 's|^\./||' | while read -r l; do
        case $l in */*) echo "    $d/${l%/*}" ;; *) echo "    $d" ;; esac
      done
    done
  elif [ "$comp" != eider-lang ]; then
    case " eider-toml eider-json eider-markdown eider-logging eider-command eider-http eider-rpc eider-openapi eider-example-shopping-service " in
      *" $comp "*) echo "  tag it (publish.sh and release.sh do not):"; tag_command "$(sibling_dir "$comp")" "$comp" "$NEWV" "$V" ;;
    esac
  fi
  echo "  sh scripts/release.sh                   # when the user asks to release"
}

case "${1:-}" in
  ""|show) show ;;
  check) check_here ;;
  check-siblings) check_siblings ;;
  bump) shift; bump "$@" ;;
  *) echo "usage: scripts/version.sh [show | check | check-siblings | bump <major|minor|patch> [component]]" >&2; exit 2 ;;
esac
