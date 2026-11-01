#!/bin/sh
# Rewrite the deprecated `var` as `let mut` (docs/compiler.md, "C8.6: references by default"):
#
#   scripts/migrate-var.sh <file or directory>...
#
# For every .ei file (directories are searched, skipping deps/, .vendor/ and target/) that
# mentions `var`, `eiderc migrate-var <file>` checks the file on its own (a module without
# `main` is fine) and prints it with each `var` it can rewrite: `var x = fresh` becomes
# `let mut x = fresh`, `var x = place` becomes `let mut x = place.copy()` (a `var` made its
# own value; a `let mut` of a place is an alias), `var (a, b) = e` becomes
# `let (mut a, mut b) = e` (with `.copy()` when e is a place). Meaning is unchanged. A `var`
# is left as it is where `.copy()` would differ from the copy `var` made (a type holding a
# Mutex, a record with its own Drop, an own Copy) or could need a bound (a place in a generic body),
# and in code no concrete body checks (an unused generic function). A file that doesn't
# check is left alone and named on stderr. Prints each rewritten file.
#
# EIDERC is the compiler (default target/eiderc, the seed's build: until a seed has
# `migrate-var`, set EIDERC=target/eiderc-next). scripts/test-compiler.sh ("migration") runs
# this on a copy of core, std, packages and compiler and checks the result; run it on the
# checkout once the seed that builds compiler/ knows `let mut`.
[ $# -gt 0 ] || { echo "usage: scripts/migrate-var.sh <file or directory>..." >&2; exit 2; }
EIDERC=${EIDERC:-target/eiderc}
[ -x "$EIDERC" ] || { echo "migrate-var: no compiler at $EIDERC (set EIDERC)" >&2; exit 2; }

migrate() {
  f=$1
  grep -q '\(^\|[^A-Za-z0-9_]\)var[[:space:]]' "$f" || return 0
  if ! "$EIDERC" migrate-var "$f" >"$tmp/out" 2>"$tmp/err"; then
    echo "migrate-var: $f does not check; left as it is" >&2
    return 0
  fi
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
