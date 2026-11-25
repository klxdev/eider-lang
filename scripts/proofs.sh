#!/bin/sh
# The machine-checked proofs of the memory-safety model (docs/design/formal-model.md, #246 workstream G): builds the Lean 4
# project in proofs/ and counts the unfinished proofs (`sorry`). Prints `ok`, `FAIL` or `skip <reason>`; needs `lake` (the
# Fedora 44 release image, scripts/release-env/, has Lean 4.36.0 in /opt/lean; so does a host with elan).
cd "$(dirname "$0")/.." || exit 1
if ! command -v lake >/dev/null 2>&1; then echo "skip proofs: no Lean 4 (lake) on PATH; the release image has it (scripts/release-env/)"; exit 0; fi
out=$(cd proofs && lake build 2>&1); rc=$?
if [ $rc != 0 ]; then echo "FAIL proofs: lake build"; echo "$out" | tail -20; exit 1; fi
left=$(grep -rn "sorry" proofs/Eider proofs/Eider.lean 2>/dev/null | grep -v "^[^:]*:[0-9]*:\s*--" | grep -vc "^[^:]*:[0-9]*:.*\`sorry\`")
# an unfinished proof is a failure: a release claims only what is proved
if [ "$left" != 0 ] || grep -rqw "axiom" proofs/Eider; then echo "FAIL proofs: builds, but $left sorry (or an axiom) is left"; exit 1; fi
n=$(grep -rhc "^theorem " proofs/Eider | awk '{ s += $1 } END { print s }')
echo "ok   proofs: builds, no sorry, no axiom${n:+ ($n theorems)}"
exit 0
