#!/bin/sh
# Rewrite path imports that cross a package boundary into package imports
# (docs/compiler.md, "C8.3: packages and modules"):
#
#   scripts/migrate-imports.sh <file or directory>...
#
# For every .ei file (directories are searched, skipping deps/, vendor/ and target/):
#   - `import "deps/<name>/<path>.ei"` (the retired deps/ link farm) becomes `import "<name>"`
#     for the default entry `<name>.ei`, else `import "<name>/<path>"`;
#   - a relative `import "<path>.ei"` whose file is in another package becomes `import
#     "<package>"` (its entry module) or `import "<package>/<path in it>"`, when that package
#     is the toolchain's (`core`, `std`) or a dependency the importer's eider.toml declares.
#     Imports inside one package, and imports from a file in no package into a package other
#     than core and std, are left alone.
# An import whose default alias would change (an entry module not named after its package)
# gets `as <old alias>`, so the code using it is unchanged. Prints each rewritten file.
#
# The compiler needs a seed that knows package imports before compiler/, std/ and core/ (and
# what the seed builds: packages/, the tests) can be rewritten; after that, each package
# with dependencies needs an eider.lock (`scripts/eider-pkg -C <dir> fetch`).
[ $# -gt 0 ] || { echo "usage: scripts/migrate-imports.sh <file or directory>..." >&2; exit 2; }

# pkg_of <dir>: "<package dir> <package name>" of the nearest eider.toml at or above <dir>
pkg_of() {
  d=$1
  while :; do
    if [ -f "$d/eider.toml" ]; then
      printf '%s %s\n' "$d" "$(sed -n 's/^name *= *"\([a-z0-9_]*\)".*/\1/p' "$d/eider.toml" | head -1)"
      return
    fi
    [ "$d" = / ] && return
    d=$(dirname "$d")
  done
}
# entry_of <package dir> <name>: its entry module's path in it
entry_of() {
  e=$(sed -n 's/^entry *= *"\([^"]*\)".*/\1/p' "$1/eider.toml" | head -1)
  [ -n "$e" ] && echo "$e" || echo "$2.ei"
}
# declares <package dir> <name>: whether its eider.toml has [deps.<name>]
declares() { grep -q "^\[deps\.$2\]" "$1/eider.toml" 2>/dev/null; }

migrate() {
  f=$1
  fdir=$(cd "$(dirname "$f")" && pwd -P)
  ip=$(pkg_of "$fdir")
  ipdir=${ip% *}
  [ -n "$ip" ] || ipdir=""
  : >"$tmp/sed"
  sed -n 's/^import "\([^"]*\.ei\)"\( as [A-Za-z_][A-Za-z0-9_]*\)\{0,1\} *$/\1|\2/p' "$f" >"$tmp/imports"
  while IFS='|' read -r p alias; do
    new=""
    case "$p" in
      deps/*|*/deps/*)
        rest=${p#*deps/}
        name=${rest%%/*}
        inner=${rest#*/}
        if [ "$inner" = "$name.ei" ] && [ "$name" != core ] && [ "$name" != std ]; then new=$name; else new="$name/${inner%.ei}"; fi
        ;;
      *)
        tdir=$(cd "$fdir/$(dirname "$p")" 2>/dev/null && pwd -P) || continue
        tp=$(pkg_of "$tdir")
        [ -n "$tp" ] || continue
        tpdir=${tp% *}
        tname=${tp#* }
        [ -n "$tname" ] && [ "$tpdir" != "$ipdir" ] || continue
        case "$tname" in
          core|std) ;;
          *) [ -n "$ipdir" ] && declares "$ipdir" "$tname" || continue ;;
        esac
        rel="${tdir#$tpdir}/$(basename "$p")"
        rel=${rel#/}
        if [ "$rel" = "$(entry_of "$tpdir" "$tname")" ]; then new=$tname; else new="$tname/${rel%.ei}"; fi
        ;;
    esac
    old_alias=$(basename "$p" .ei | sed 's/[^A-Za-z0-9_]/_/g')
    new_alias=${new##*/}
    suffix=$alias
    [ -z "$alias" ] && [ "$old_alias" != "$new_alias" ] && suffix=" as $old_alias"
    esc=$(printf '%s' "$p" | sed 's/[.[\*^$|]/\\&/g')
    printf 's|^import "%s"%s *$|import "%s"%s|\n' "$esc" "$alias" "$new" "$suffix" >>"$tmp/sed"
  done <"$tmp/imports"
  if [ -s "$tmp/sed" ]; then
    sed -f "$tmp/sed" "$f" >"$tmp/out" && cat "$tmp/out" >"$f"
    echo "migrated $f"
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for a in "$@"; do
  if [ -d "$a" ]; then
    find "$a" \( -name deps -o -name vendor -o -name target \) -prune -o -name '*.ei' -print | sort >"$tmp/files"
    while read -r f; do migrate "$f"; done <"$tmp/files"
  else
    migrate "$a"
  fi
done
