#!/bin/sh
# Link deps/core and deps/std into every package under packages/, so they build before the
# package manager exists. After bootstrap, eider-pkg maintains deps/ itself.
root="$(cd "$(dirname "$0")/.." && pwd)"
for p in "$root"/packages/*/; do
  mkdir -p "$p/deps"
  for l in core std; do
    [ -e "$p/deps/$l" ] || ln -s "$root/$l" "$p/deps/$l"
  done
done
