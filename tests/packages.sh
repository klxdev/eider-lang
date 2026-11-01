#!/bin/sh
# Runs packages/*/tests/*.ei (the toolchain's packages: pkg, with its semver and sha256
# modules, doc and fuzz) and .vendor/*/tests/*.ei (the pinned libraries they use, as released,
# fetched by scripts/vendor.sh) through scripts/ei and compares output with the .out next to it.
# When the pinned libraries can't be fetched (no checkout, mirror or tarball, and no network),
# their tests and those of the packages that depend on them are `skip` lines with the reason.
# Libraries and frameworks with repositories of their own (eider-json, eider-http, ...) are
# tested there, and against this checkout by scripts/check-tools.sh.
cd "$(dirname "$0")/.." || exit 1
fail=0
novendor=
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
sh scripts/vendor.sh fetch > "$T/fetch" 2>&1
case $? in
  0) ;;
  3) novendor="the pinned libraries can't be fetched (no checkout, mirror or tarball of $(grep 'cannot fetch' "$T/fetch" | sed 's/^vendor.sh: cannot fetch //; s/ (.*//' | paste -sd, - | sed 's/,/, /g'), and no network; sh scripts/vendor.sh fetch)"
     echo "skip packages: the pinned libraries' own tests: $novendor" ;;
  *) echo "FAIL packages: sh scripts/vendor.sh fetch"; sed 's/^/  /' "$T/fetch"; fail=1 ;;
esac
for f in packages/*/tests/*.ei .vendor/*/tests/*.ei; do
  [ -f "$f" ] && [ -f "${f%.ei}.out" ] || continue
  got=$(scripts/ei run "$f" 2>&1)
  if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f"
  # a test that loads a pinned library which isn't there (E0810 at .vendor/<name>)
  elif [ -n "$novendor" ] && printf '%s\n' "$got" | grep -q 'E0810.*/\.vendor/'; then echo "skip packages: $f loads a pinned library: $novendor"
  else echo "FAIL $f"; echo "$got" | diff "${f%.ei}.out" - | head -10; fail=1; fi
done

# packages/crypto needs a crypto backend linked in, so its tests live in tests/crypto and run
# through scripts/ei-crypto: here on the default backend (verify.sh's crypto leg runs every
# backend and the cross-backend checks); `skip` when it isn't available (AWS-LC not fetched).
sh tests/crypto/run.sh "${EIDER_CRYPTO:-awslc}" > "$T/crypto" 2>&1 || fail=1
cat "$T/crypto"
exit $fail
