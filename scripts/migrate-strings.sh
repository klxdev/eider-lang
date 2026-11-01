#!/bin/sh
# Rewrite string literals for interpolation (docs/compiler.md, "C8.28: string literals";
# decision U29): every plain literal interpolates `{expr}`, so a literal written before that
# with a brace in it would change meaning. For every .ei file and every ```eider code block of
# a .md file (directories are searched, skipping .git/, target/, deps/, .vendor/ and
# node_modules/), `eiderc migrate-strings` rewrites each such literal to mean what it meant: a
# raw string (`r"..."`, `r"""`) when it has no backslash, else with its braces doubled; and
# drops the `f` of an `f"..."`. Comments and raw strings are left alone. Meaning is unchanged;
# the files are rewritten in place and each one changed is named.
#
#   scripts/migrate-strings.sh [--portable] <file or directory>...
#
# --portable writes the braces as `\x7b`/`\x7d`, which mean a brace to a compiler from before
# the change as well (compiler/ and what the seed compiles: seed/README.md, "Bootstrapping a
# change in what source means").
#
# EIDERC is the compiler (default target/eiderc; it must know `migrate-strings`).
[ $# -gt 0 ] || { echo "usage: scripts/migrate-strings.sh [--portable] <file or directory>..." >&2; exit 2; }
EIDERC=${EIDERC:-target/eiderc}
[ -x "$EIDERC" ] || { echo "migrate-strings: no compiler at $EIDERC (set EIDERC)" >&2; exit 2; }
flag=
if [ "$1" = "--portable" ]; then flag=--portable; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

migrate() {
  f=$1
  grep -q '[{}]\|f"' "$f" || return 0
  if ! "$EIDERC" migrate-strings "$f" $flag >"$tmp/out" 2>"$tmp/err"; then
    echo "migrate-strings: $f: $(head -1 "$tmp/err")" >&2
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
