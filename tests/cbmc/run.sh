#!/bin/sh
# Bounded model checking of the C core's buffer code with CBMC (docs/design/c-core-audit.md, plan item 2): each harness in
# tests/cbmc/ is checked for every input within its stated bound, with pointer, bounds and overflow checks on. A harness
# with cases (str_cat) runs once per case: every case in one formula exhausts the solver's memory.
# Skips, with the reason, where cbmc is absent (the Fedora 44 release image has it, scripts/release-env/).
cd "$(dirname "$0")/../.." || exit 1
if ! command -v cbmc >/dev/null 2>&1; then echo "skip cbmc: cbmc is not installed (the release image has it, scripts/release-env/)"; exit 0; fi
fail=0
OPTS="-DEI_RT_PORTABLE --object-bits 14 --bounds-check --pointer-check --signed-overflow-check --unsigned-overflow-check --unwind 40 --unwinding-assertions"
check() { # name file [extra flags]
  name=$1; f=$2; shift 2
  out=$(cbmc core/eider_rt.c "tests/cbmc/$f.c" --function harness $OPTS "$@" 2>&1)
  if echo "$out" | grep -q "^VERIFICATION SUCCESSFUL"; then
    echo "ok   cbmc $name: $(echo "$out" | grep -o '[0-9]* of [0-9]* failed')"
  else
    echo "FAIL cbmc $name"; echo "$out" | grep -E "FAILURE|failed|ERROR|too many" | head -8; fail=1
  fi
}
# a harness that includes core/eider_rt.c itself (to reach its static functions) is checked alone
check_alone() { # name file [extra flags]
  name=$1; f=$2; shift 2
  out=$(cbmc "tests/cbmc/$f.c" --function harness $OPTS "$@" 2>&1)
  if echo "$out" | grep -q "^VERIFICATION SUCCESSFUL"; then
    echo "ok   cbmc $name: $(echo "$out" | grep -o '[0-9]* of [0-9]* failed')"
  else
    echo "FAIL cbmc $name"; echo "$out" | grep -E "FAILURE|failed|ERROR|too many" | head -8; fail=1
  fi
}
check_alone timer_heap timer_heap --unwind 5
for h in grow_cap buf_alloc list_open_close str_slice; do check $h $h; done
for n in 0 1 2; do for k in 0 1 2; do check "str_cat n=$n k=$k" str_cat -DN=$n -DK=$k; done; done
exit $fail
