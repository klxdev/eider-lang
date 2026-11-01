#!/bin/sh
# No quoted imports are left (docs/compiler.md, "C8.26: dotted imports"; the quoted form,
# `import "std/fs"`, is deprecated): every .ei file and every documentation page of this
# checkout uses dotted imports (`import std.fs`), apart from the files listed below, which
# are tests of the quoted form itself or imports that have no dotted form. A leg of
# scripts/verify.sh.
#
#   sh scripts/check-imports.sh
#
# A quoted import outside the list is a FAIL (rewrite it with
# scripts/migrate-imports-dotted.sh <file>), and so is a listed file that has none left (drop
# it from the list). Searched: every .ei and .md file but target/, .vendor/ (the
# pinned releases, scripts/vendor.sh), .git/, .claude/ and node_modules/.
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The files allowed to keep a quoted import, one per line.
cat > "$T/allowed" <<'EOF'
compiler/tests/check/fail/e0204_method_fs.ei
compiler/tests/check/fail/e0204_unsafe_fn.ei
compiler/tests/check/fail/e0804_mod_missing_nested.ei
compiler/tests/check/fail/e0809_not_a_dependency.ei
compiler/tests/check/fail/e0810_no_lock.ei
compiler/tests/check/fail/e0811_series_import.ei
compiler/tests/check/lib/pkgs/granter/granter.ei
compiler/tests/check/lib/pkgs/granter/unsafe_user.ei
compiler/tests/check/lib/pkgs/nolock/nolock.ei
compiler/tests/check/multi/after_resolution.ei
compiler/tests/export/shapes.ei
compiler/tests/ide/partial_parse.ei
compiler/tests/parse/import_alias_keyword.ei
compiler/tests/parse/import_alias_utf8.ei
compiler/tests/pkgs/app/badnames.ei
compiler/tests/pkgs/app/dup.ei
compiler/tests/pkgs/app/indirect.ei
compiler/tests/pkgs/app/main.ei
compiler/tests/pkgs/app/missing.ei
compiler/tests/pkgs/app/undeclared.ei
compiler/tests/pkgs/app/unlocked.ei
compiler/tests/pkgs/geo/geo.ei
compiler/tests/pkgs/nolock/main.ei
compiler/tests/pkgs/ublock/ublock.ei
compiler/tests/pkgs/wrap/wrap.ei
docs/site/reference/errors.md
tests/checks/fail/e0804_missing_module.ei
tests/checks/fail/e0809_not_a_dependency.ei
tests/crypto/bench.ei
tests/crypto/cavp.ei
tests/crypto/cross.ei
tests/crypto/rfc.ei
tests/crypto/wycheproof.ei
EOF
# Why: compiler/tests/** and tests/checks/fail/** are the compiler's tests of the quoted form
# (its parse, its diagnostics E0204/E0804/E0809/E0810/E0811 through it, IDE spans, and package
# imports the migration can't rewrite: undeclared, unlocked or malformed names); errors.md's
# E0809 example is the quoted form's own error; tests/crypto/*.ei are files in no package that
# import upward (`"../../packages/crypto/crypto.ei"`, `"../../.vendor/json/json.ei"`), which
# no dotted path can name (C280).

find . \( -path ./target -o -path ./.vendor -o -path ./.git -o -path ./.claude -o -name node_modules \) -prune -o \
  \( -name '*.ei' -o -name '*.md' \) -type f -print | sed 's|^\./||' | LC_ALL=C sort > "$T/files"
: > "$T/found"
while IFS= read -r f; do
  grep -q '^[[:space:]]*import[[:space:]]*"' "$f" && echo "$f" >> "$T/found"
done < "$T/files"
LC_ALL=C sort -o "$T/allowed" "$T/allowed"
fail=0
LC_ALL=C comm -23 "$T/found" "$T/allowed" > "$T/new"
LC_ALL=C comm -13 "$T/found" "$T/allowed" > "$T/stale"
if [ -s "$T/new" ]; then
  echo "FAIL imports: quoted imports (deprecated; sh scripts/migrate-imports-dotted.sh <file> rewrites them):"
  while IFS= read -r f; do grep -n '^[[:space:]]*import[[:space:]]*"' "$f" | sed "s|^|  $f:|"; done < "$T/new" | head -20
  fail=1
fi
if [ -s "$T/stale" ]; then
  echo "FAIL imports: listed in scripts/check-imports.sh but without a quoted import (drop them):"
  sed 's/^/  /' "$T/stale"
  fail=1
fi
[ $fail = 0 ] && echo "ok   imports: no quoted imports in $(wc -l < "$T/files" | tr -d ' ') .ei and .md files but the $(wc -l < "$T/allowed" | tr -d ' ') tests of the quoted form and imports with no dotted form"
exit $fail
