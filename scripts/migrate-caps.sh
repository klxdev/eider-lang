#!/bin/sh
# Remove the `ffi` that `uses` clauses carried only to call std, core or another package
# (docs/compiler.md, "C8.5: capabilities per package": `ffi` no longer crosses a package
# boundary, the real capabilities still do):
#
#   scripts/migrate-caps.sh <file or directory>...
#
# For every .ei file (directories are searched, skipping deps/, .vendor/ and target/), unless
# it has unmanaged code itself (an `extern "c"` declaration or `unsafe` outside comments and
# strings) or path-imports a file that has (a wrapper in the same package, whose `uses ffi`
# still propagates): `uses ffi` is removed from every signature, and `ffi` from every longer
# `uses` list (`uses io, ffi` -> `uses io`). Comment lines, and lines where the clause is inside
# a string literal, are left alone. Prints each
# rewritten file.
#
# The seed asks for `ffi` along call chains, so this runs after the next seed: on compiler/,
# std/, packages/, tests/ and examples/ (core/sys.ei and the FFI tests keep theirs).
# scripts/test-compiler.sh ("migration") runs it on a copy and checks the result.
[ $# -gt 0 ] || { echo "usage: scripts/migrate-caps.sh <file or directory>..." >&2; exit 2; }

# unmanaged <file>: whether it declares an extern or uses `unsafe` (comments and strings
# stripped first)
unmanaged() {
  grep -q '^[[:space:]]*\(pub[[:space:]]\{1,\}\)\{0,1\}extern[[:space:]]\{1,\}"c"' "$1" && return 0
  sed -e 's|//.*||' -e 's/"\([^"\\]\|\\.\)*"//g' "$1" | grep -q '\(^\|[^A-Za-z0-9_]\)unsafe\([^A-Za-z0-9_]\|$\)'
}

# imports_unmanaged <file>: whether a file it path-imports has unmanaged code
imports_unmanaged() {
  d=$(dirname "$1")
  for p in $(sed -n 's/^import "\([^"]*\.ei\)".*/\1/p' "$1"); do
    [ -f "$d/$p" ] && unmanaged "$d/$p" && return 0
  done
  return 1
}

migrate() {
  f=$1
  grep -q 'uses[[:space:]].*ffi' "$f" || return 0
  unmanaged "$f" && return 0
  imports_unmanaged "$f" && return 0
  sed -e '/^[[:space:]]*\/\//b' \
      -e '/"[^"]*uses [a-z, ]*ffi[^"]*"/b' \
      -e 's/\(uses [a-z, ]*\), ffi\([^A-Za-z0-9_]\)/\1\2/' \
      -e 's/\(uses [a-z, ]*\), ffi$/\1/' \
      -e 's/uses ffi, /uses /' \
      -e 's/ uses ffi\([^A-Za-z0-9_,]\)/\1/' \
      -e 's/ uses ffi$//' \
      "$f" >"$tmp/out"
  if ! cmp -s "$tmp/out" "$f"; then
    cat "$tmp/out" >"$f"
    echo "migrated $f"
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for a in "$@"; do
  if [ -d "$a" ]; then
    find "$a" \( -name deps -o -name .vendor -o -name target \) -prune -o -name '*.ei' -print | sort >"$tmp/files"
    while read -r f; do migrate "$f"; done <"$tmp/files"
  else
    migrate "$a"
  fi
done
