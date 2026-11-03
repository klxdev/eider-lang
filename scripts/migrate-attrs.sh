#!/bin/sh
# Rewrite attributes to the one form (docs/compiler.md, "C8.60: grouped attributes"; #155):
# `@name(...)` becomes `@[name(...)]`, and attributes in a row on one line become one group,
# `@[a(...), b(...)]`. For every .ei file and every ```eider code block of a .md file
# (directories are searched, skipping .git/, target/, deps/, .vendor/ and node_modules/),
# `eiderc migrate-attrs` rewrites each bare attribute. Comments and strings are left alone
# (doc comments that show an attribute are edited by hand). Meaning is unchanged; the files
# are rewritten in place and each one changed is named.
#
#   scripts/migrate-attrs.sh <file or directory>...
#
# EIDERC is the compiler (default target/eiderc; it must know `migrate-attrs`).
[ $# -gt 0 ] || { echo "usage: scripts/migrate-attrs.sh <file or directory>..." >&2; exit 2; }
EIDERC=${EIDERC:-target/eiderc}
[ -x "$EIDERC" ] || { echo "migrate-attrs: no compiler at $EIDERC (set EIDERC)" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

migrate() {
  f=$1
  grep -q '@[A-Za-z_]' "$f" || return 0
  if ! "$EIDERC" migrate-attrs "$f" >"$tmp/out" 2>"$tmp/err"; then
    echo "migrate-attrs: $f: $(head -1 "$tmp/err")" >&2
    return 0
  fi
  if ! cmp -s "$tmp/out" "$f"; then
    cat "$tmp/out" >"$f"
    echo "migrated $f"
  fi
}

for a in "$@"; do
  if [ -d "$a" ]; then
    find "$a" \( -name .git -o -name target -o -name deps -o -name .vendor -o -name node_modules \) -prune -o \
      -type f \( -name '*.ei' -o -name '*.md' \) -print | sort > "$tmp/list"
    while IFS= read -r f; do migrate "$f"; done < "$tmp/list"
  else
    migrate "$a"
  fi
done
