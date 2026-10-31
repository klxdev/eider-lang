#!/bin/sh
# The pinned copies of libraries the toolchain's own tools use (LAYERS.md, "Vendored
# libraries"): vendor/<name> is a release of github.com/klxdev/eider-<name>, byte for byte,
# recorded in vendor/vendor.lock (its git source, commit and content hash, in eider.lock's
# format). eider-pkg (packages/pkg) uses vendor/toml, eider-doc (packages/doc) vendor/json and
# vendor/markdown, tests/crypto vendor/json; they import them as path dependencies, so a fresh
# checkout builds everything with only a C compiler and no network.
#
#   sh scripts/vendor.sh <name> <commit|tag>   copy that commit of the checkout of eider-<name>
#                                              into vendor/<name> and record it
#   sh scripts/vendor.sh check                 every vendor/<name> has the content hash
#                                              vendor.lock records, and (when the checkout is
#                                              here) is byte-identical to the pinned commit
#   sh scripts/vendor.sh list                  name, version and commit of each copy
#
# The checkout is $EIDER_<NAME> (e.g. EIDER_JSON), default $EIDER_SIBLINGS/eider-<name>
# (EIDER_SIBLINGS: the directory holding the sibling repositories, default ..):
# the commit must be in it (fetch it first). The content hash is eider-pkg's (`eider-pkg
# hash`, the one eider.lock files record for a git package), so a program that depends on
# the same release by git locks the same hash. Never edit vendor/ by hand: change the library
# in its repository, release it, and vendor the release. `check` is a leg of
# scripts/verify.sh: the hash is always checked; the byte comparison needs the checkout and
# is a skipped leg without it.
cd "$(dirname "$0")/.." || exit 1
here=$(pwd -P)
LOCK=vendor/vendor.lock
URL_BASE=https://github.com/klxdev/eider-

die() { echo "vendor.sh: $*" >&2; exit 2; }
checkout_of() {
  var=EIDER_$(echo "$1" | tr 'a-z' 'A-Z')
  eval "d=\${$var:-${EIDER_SIBLINGS:-$here/..}/eider-$1}"
  [ -d "$d/.git" ] || [ -f "$d/.git" ] || return 1
  (cd "$d" && pwd -P)
}
# field <name> <key>: a value of package <name>'s entry in vendor.lock
field() {
  awk -v n="$1" -v k="$2" '
    /^\[\[package\]\]/ { cur = "" }
    /^name = / { v = $0; sub(/^name = "/, "", v); sub(/"$/, "", v); cur = v }
    cur == n && index($0, k " = ") == 1 { v = $0; sub(/^[a-z]+ = "/, "", v); sub(/"$/, "", v); print v; exit }
  ' "$LOCK"
}
names() { [ -f "$LOCK" ] && sed -n 's/^name = "\(.*\)"$/\1/p' "$LOCK"; }
hash_of() { scripts/eider-pkg hash "$1" 2>/dev/null | tail -1; }

# export <checkout> <commit> <dir>: the commit's files, as `git archive` gives them
export_to() { rm -rf "$3" && mkdir -p "$3" && git -C "$1" archive --format=tar "$2" | tar -x -C "$3"; }

write_lock() {
  {
    echo "# vendor/vendor.lock: the pinned copies in vendor/, written by scripts/vendor.sh. Do not edit."
    echo "version = 1"
    for wn in $(names_with "$1" | sort -u); do
      if [ "$wn" = "$1" ]; then wv=$2; wc=$3; wh=$4; else wv=$(field "$wn" version); ws=$(field "$wn" source); wc=${ws##*#}; wh=$(field "$wn" hash); fi
      printf '\n[[package]]\nname = "%s"\nversion = "%s"\nsource = "git+%s%s.git#%s"\nhash = "%s"\n' "$wn" "$wv" "$URL_BASE" "$wn" "$wc" "$wh"
    done
  } > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK"
}
names_with() { names; echo "$1"; }

case $1 in
  ""|-h|--help|help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  list)
    for n in $(names); do s=$(field "$n" source); echo "$n $(field "$n" version) ${s##*#}"; done
    exit 0 ;;
  check)
    bad=0
    [ -f "$LOCK" ] || { echo "FAIL vendor: no $LOCK"; exit 1; }
    for d in vendor/*/; do
      n=$(basename "$d")
      [ -n "$(field "$n" hash)" ] || { echo "FAIL vendor: vendor/$n is not in $LOCK (vendor it with scripts/vendor.sh)"; bad=1; }
    done
    T=$(mktemp -d)
    trap 'rm -rf "$T"' EXIT
    for n in $(names); do
      want=$(field "$n" hash); s=$(field "$n" source); c=${s##*#}; v=$(field "$n" version)
      if [ ! -d "vendor/$n" ]; then echo "FAIL vendor: vendor/$n is missing ($LOCK pins it)"; bad=1; continue; fi
      have=$(hash_of "vendor/$n")
      if [ "$have" != "$want" ]; then
        echo "FAIL vendor: vendor/$n has content hash $have, $LOCK says $want: it was edited; vendor a release instead (scripts/vendor.sh $n <commit>)"
        bad=1; continue
      fi
      if co=$(checkout_of "$n"); then
        if ! git -C "$co" cat-file -e "$c^{commit}" 2>/dev/null; then
          echo "FAIL vendor: $n $v: the checkout $co doesn't have the pinned commit $c (fetch it, or set EIDER_$(echo "$n" | tr 'a-z' 'A-Z'))"
          bad=1; continue
        fi
        export_to "$co" "$c" "$T/$n"
        if diff -r "$T/$n" "vendor/$n" > "$T/$n.diff" 2>&1; then
          echo "ok   vendor/$n: eider-$n $v (${c%"${c#????????????}"}), byte-identical to $co"
        else
          echo "FAIL vendor: vendor/$n differs from eider-$n $c in $co:"; head -20 "$T/$n.diff" | sed 's/^/  /'; bad=1
        fi
      else
        echo "ok   vendor/$n: eider-$n $v, content hash as pinned"
        echo "skip vendor/$n byte-identical check: no checkout of eider-$n (set EIDER_SIBLINGS or EIDER_$(echo "$n" | tr a-z A-Z))"
      fi
    done
    exit $bad ;;
esac

# vendor <name> <commit>
n=$1; rev=$2
[ -n "$rev" ] || die "usage: scripts/vendor.sh <name> <commit|tag> (or check, list)"
echo "$n" | grep -Eq '^[a-z][a-z0-9_]*$' || die "\`$n\` is not a package name"
co=$(checkout_of "$n") || die "no git checkout of eider-$n in ${EIDER_SIBLINGS:-$here/..} (set EIDER_SIBLINGS, or EIDER_$(echo "$n" | tr a-z A-Z))"
c=$(git -C "$co" rev-parse --verify --quiet "$rev^{commit}") || die "$co has no commit $rev"
v=$(git -C "$co" show "$c:eider.toml" 2>/dev/null | sed -n 's/^version = "\(.*\)"$/\1/p' | head -1)
[ -n "$v" ] || die "$co at $c has no eider.toml with a version"
mkdir -p vendor
export_to "$co" "$c" "vendor/$n"
h=$(hash_of "vendor/$n")
[ -n "$h" ] || die "eider-pkg hash vendor/$n failed"
write_lock "$n" "$v" "$c" "$h"
echo "vendored eider-$n $v ($c) into vendor/$n, $h"
