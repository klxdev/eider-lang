#!/bin/sh
# Rewrite quoted imports in the dotted form (docs/compiler.md, "C8.26: dotted imports"):
#
#   scripts/migrate-imports-dotted.sh [--keep-seed] <file or directory>...
#
# For every .ei file (directories are searched, skipping deps/, target/, node_modules/,
# .git/ and .claude/; vendor/ only when it is named itself) with a quoted import, `eiderc
# migrate-imports <file>` prints the file with the compiler's fixes applied: each quoted
# import becomes the dotted import that loads the same module, keeping its alias (`as <old
# alias>` where the default would change):
#
#   import "std/fs"             ->  import std.fs
#   import "core/sys"           ->  import core.sys
#   import "json/stream"        ->  import json.stream     (a dependency's module)
#   import "lex.ei"             ->  import eiderc.lex      (in package eiderc: its own module)
#   import "../../intern.ei" as names  ->  import eiderc.intern as names
#   import "lib/util.ei"        ->  import lib.util        (in no package: a file below it)
#
# The compiler rewrites an import only when the dotted form loads the same file, so the
# program means what it meant and its C is unchanged; the rest are left quoted (a file outside
# the importer's package and its dependencies, `"../x.ei"` from a file in no package, a path
# that isn't made of identifiers). `eiderc migrate-imports --json <file>` prints the fixes
# themselves. A file whose imports can't be resolved is left alone. Prints each rewritten
# file; the files left with a quoted import are listed on stderr as `kept <file>: <import>`.
#
# --keep-seed leaves alone what the current seed must build to build the compiler (until the
# next seed knows dotted imports): compiler/, std/{bytes,fs,io,env,proc}.ei and
# core/{sys,version}.ei. Without it, everything named is rewritten.
#
# EIDERC is the compiler (default: target/eiderc when it has `migrate-imports`, else
# target/eiderc-next, compiler/ as the seed builds it, rebuilt when compiler/ is newer).
cd_root=$(cd "$(dirname "$0")/.." && pwd -P)
keep=0
if [ "$1" = --keep-seed ]; then keep=1; shift; fi
[ $# -gt 0 ] || { echo "usage: scripts/migrate-imports-dotted.sh [--keep-seed] <file or directory>..." >&2; exit 2; }
if [ -z "$EIDERC" ]; then
  if "$cd_root/scripts/ei" --help 2>/dev/null | grep -q migrate-imports; then
    EIDERC=$cd_root/target/eiderc
  else
    EIDERC=$cd_root/target/eiderc-next
    if [ ! -x "$EIDERC" ] || [ -n "$(find "$cd_root/compiler" "$cd_root/std" "$cd_root/core" -name '*.ei' -newer "$EIDERC" 2>/dev/null | head -1)" ]; then
      EIDER_CACHE=off "$cd_root/scripts/ei" build "$cd_root/compiler/main.ei" -o "$EIDERC" >/dev/null || { echo "migrate-imports: cannot build compiler/" >&2; exit 3; }
    fi
  fi
fi
[ -x "$EIDERC" ] || { echo "migrate-imports: no compiler at $EIDERC (set EIDERC)" >&2; exit 2; }

# seed_file <file>: whether the seed needs it to build the compiler
seed_file() {
  a=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  case "$a" in
    "$cd_root"/compiler/*) return 0 ;;
    "$cd_root"/std/bytes.ei|"$cd_root"/std/fs.ei|"$cd_root"/std/io.ei|"$cd_root"/std/env.ei|"$cd_root"/std/proc.ei) return 0 ;;
    "$cd_root"/core/sys.ei|"$cd_root"/core/version.ei) return 0 ;;
  esac
  return 1
}

migrate() {
  f=$1
  grep -q '^[[:space:]]*import[[:space:]]*"' "$f" || return 0
  if [ $keep = 1 ] && seed_file "$f"; then return 0; fi
  if ! EIDER_ROOT=${EIDER_ROOT:-$cd_root} "$EIDERC" migrate-imports "$f" >"$tmp/out" 2>"$tmp/err"; then
    echo "migrate-imports: $f: $(head -1 "$tmp/err"); left as it is" >&2
    return 0
  fi
  if ! cmp -s "$tmp/out" "$f"; then
    cat "$tmp/out" >"$f"
    echo "migrated $f"
  fi
  grep '^[[:space:]]*import[[:space:]]*"' "$f" | while IFS= read -r l; do echo "kept $f: $l" >&2; done
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for a in "$@"; do
  if [ -d "$a" ]; then
    find "$a" \( -name deps -o -name target -o -name node_modules -o -name .git -o -name .claude -o \( -name vendor ! -path "$a" \) \) -prune -o -name '*.ei' -print | sort >"$tmp/files"
    while read -r f; do migrate "$f"; done <"$tmp/files"
  else
    migrate "$a"
  fi
done
