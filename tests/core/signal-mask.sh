#!/bin/sh
# A focused diagnostic gate; expected to expose the current Darwin guarded-main bug.
set -eu
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror -pthread \
  tests/core/signal_mask_test.c core/eider_rt.c core/eider_core.c -lm -o "$T/signal-mask"
echo 'original C main thread:'
"$T/signal-mask" direct
echo 'Eider guarded main worker:'
"$T/signal-mask" guarded
