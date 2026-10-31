#!/bin/sh
# Retired (docs/compiler.md, "C8.3: packages and modules"). This script used to link deps/core,
# deps/std and each path dependency into every package under packages/ and into compiler/,
# so they built before the package manager existed. Nothing needs that link farm any more:
# compiler/ and packages/ import the toolchain and each other by relative path until the seed
# knows bare imports (then scripts/migrate-imports.sh turns them into `import "std/fs"` and
# `import "toml"`), and eider-pkg fetch no longer makes deps/. Kept so old callers keep
# working; it removes the links it once made and does nothing else.
root="$(cd "$(dirname "$0")/.." && pwd)"
for d in "$root"/packages/*/deps "$root"/compiler/deps; do
  [ -L "$d/core" ] && [ -L "$d/std" ] && rm -rf "$d"
done
exit 0
