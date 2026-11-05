#!/bin/sh
# Dependency-free native regression gate, used on Linux and Apple Silicon macOS.
set -eu
cd "$(dirname "$0")/.."
scripts/ei --version
scripts/ei test --compile-fail tests/checks
bash tests/run.sh
if [ "$(uname -s)" = Linux ]; then
  sh tests/std/run.sh
else
  # Known macOS failures are documented in tooling/platforms.md; do not label this a
  # full runtime verification. Keep the useful platform-independent/std I/O gate.
  for source in tests/std/*.ei; do
    case $source in */math.ei|*/profile.ei|*/signal.ei) echo "skip macOS baseline: $source"; continue ;; esac
    input=${source%.ei}.in; [ -f "$input" ] || input=/dev/null
    got=$(status=0; EIDER_STD_TEST=set scripts/ei run "$source" < "$input" 2>&1 || status=$?; printf 'exit %s\n' "$status")
    [ "$got" = "$(cat "${source%.ei}.out")" ] || { printf '%s\n' "$got"; echo "FAIL $source"; exit 1; }
    echo "ok $source"
  done
fi
sh tests/wasm/run.sh
# The complete C runtime suite currently has Linux-specific /proc and errno assertions.
if [ "$(uname -s)" = Linux ]; then sh tests/core/run.sh; fi
mkdir -p target/platform
cat > target/platform/smoke.ei <<'EI'
fn main() uses io { print("platform smoke") }
test "arithmetic" { assert 6 * 7 == 42 }
EI
scripts/ei test target/platform/smoke.ei
# Optimized multi-unit link: a Mach-O linker must fall back without ELF-only options.
scripts/ei build target/platform/smoke.ei -o target/platform/smoke
[ "$(target/platform/smoke)" = 'platform smoke' ]
