#!/bin/sh
# Print the path of the stage-0 compiler (the temporary Rust bootstrap, kept outside this
# repository), building it first if needed. Retired once compiler/ self-hosts (docs/compiler.md).
#   EIDER_STAGE0=<binary>     use a prebuilt stage-0 compiler
#   EIDER_BOOTSTRAP=<dir>     checkout of eider-bootstrap (default: ../eider-bootstrap)
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "$EIDER_STAGE0" ]; then echo "$EIDER_STAGE0"; exit 0; fi
src="${EIDER_BOOTSTRAP:-$root/../eider-bootstrap}"
bin="$root/target/stage0/debug/eider"
if [ ! -f "$src/Cargo.toml" ]; then
  echo "stage0: no bootstrap compiler at $src (clone eider-bootstrap there, or set EIDER_BOOTSTRAP / EIDER_STAGE0)" >&2
  exit 3
fi
if [ ! -x "$bin" ] || [ -n "$(find "$src/src" "$src/Cargo.toml" -newer "$bin" 2>/dev/null | head -1)" ]; then
  cargo build --quiet --manifest-path "$src/Cargo.toml" --target-dir "$root/target/stage0" 2>&1 | grep -E '^error' -A6 >&2
  [ -x "$bin" ] || exit 3
fi
echo "$bin"
