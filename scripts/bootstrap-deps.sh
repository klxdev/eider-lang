#!/bin/sh
# Link deps/core, deps/std and each `[deps.<name>] path = "..."` into every package under
# packages/, so they build before the package manager exists. After bootstrap,
# eider-pkg maintains deps/ itself.
root="$(cd "$(dirname "$0")/.." && pwd)"
for p in "$root"/packages/*/; do
  mkdir -p "$p/deps"
  for l in core std; do
    [ -e "$p/deps/$l" ] || ln -s "$root/$l" "$p/deps/$l"
  done
  # path dependencies: a `[deps.x]` header followed by `path = "..."`
  awk '/^\[deps\./ { n = substr($0, 7, length($0) - 7) } /^path *= *"/ && n != "" { sub(/^path *= *"/, ""); sub(/".*/, ""); print n, $0; n = "" }' "$p/eider.toml" |
  while read -r name rel; do
    [ -e "$p/deps/$name" ] || ln -s "$(cd "$p" && cd "$rel" && pwd)" "$p/deps/$name"
  done
done
