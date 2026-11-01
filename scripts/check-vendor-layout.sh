#!/bin/sh
# Nothing mentions the old vendoring layout (#130, C400): `eider-pkg vendor` writes
# `.vendor/<name>`, and a `vendor/` directory is not looked at by the compiler, eider-pkg,
# eider-doc or this checkout's scripts. Before #122 the copies were in `vendor/`; the
# compatibility kept for it then (an E0810 for a package found only there, eider-pkg's note
# and migration, `vendor` among the names a content hash skips) is gone, with no fallback. A
# leg of scripts/verify.sh.
#
#   sh scripts/check-vendor-layout.sh
#
# Searched: every text file but target/, .vendor/, .git/, .claude/, node_modules/ and seed/
# (generated from compiler/, which is searched). Allowed to keep the history:
# docs/decisions.md and the CHANGELOGs. What counts as a mention: a `vendor/` path (not
# `.vendor/`, nor a `vendor/` under another directory such as `target/vendor/`), `./vendor`,
# `$toolchain/vendor` or `$EIDER_ROOT/vendor`, `vendor` as a skipped name (`"vendor")` or
# `-name vendor`), `mv vendor` and the old fixture's name.
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pat='(^|[^./A-Za-z0-9_-])vendor/|\./vendor([^A-Za-z0-9_.-]|$)|(toolchain|EIDER_ROOT|ROOT)\}?/vendor([^A-Za-z0-9_.-]|$)|\("vendor"\)|-name vendor([^A-Za-z0-9_.-]|$)|mv vendor|oldvend'

find . \( -path ./target -o -path ./.vendor -o -path ./.git -o -path ./.claude -o -path ./seed -o -name node_modules \) -prune -o \
  -type f -print | sed 's|^\./||' | LC_ALL=C sort > "$T/files"
: > "$T/found"
while IFS= read -r f; do
  case $f in
    docs/decisions.md|CHANGELOG*|*/CHANGELOG*|scripts/check-vendor-layout.sh) continue ;;
  esac
  grep -I -n -E "$pat" "$f" 2>/dev/null | sed "s|^|$f:|" >> "$T/found"
done < "$T/files"
if [ -s "$T/found" ]; then
  echo "FAIL vendor-layout: the old vendor/ layout is mentioned (vendored packages are in .vendor/; #130):"
  head -20 "$T/found" | cut -c1-200 | sed 's/^/  /'
  exit 1
fi
echo "ok   vendor-layout (no code or doc mentions the old vendor/ layout; $(wc -l < "$T/files" | tr -d ' ') files)"
