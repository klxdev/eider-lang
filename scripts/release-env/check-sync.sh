#!/bin/sh
# The Containerfile and eider-release.yaml take their packages from packages.txt and pin the same Lean: fail if either stops.
cd "$(dirname "$0")" || exit 1
fail=0
grep -q 'packages.txt' Containerfile && grep -q 'packages.txt' eider-release.yaml || { echo "FAIL release-env: a recipe does not use packages.txt"; fail=1; }
cv=$(sed -n 's/^ARG LEAN_VERSION=//p' Containerfile); cs=$(sed -n 's/^ARG LEAN_SHA256=//p' Containerfile)
grep -q "v$cv/lean-$cv-linux" eider-release.yaml && grep -q "$cs" eider-release.yaml || { echo "FAIL release-env: the Lean version or hash differs between Containerfile and eider-release.yaml"; fail=1; }
[ $fail = 0 ] && echo "ok   release-env: Containerfile and eider-release.yaml agree (packages.txt, Lean $cv)"
exit $fail
