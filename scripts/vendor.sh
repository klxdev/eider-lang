#!/bin/sh
# The pinned libraries the toolchain's own tools use (LAYERS.md, "Vendored libraries"): each
# is a release of github.com/klxdev/eider-<name>, pinned in vendor.lock (its version, git
# source and commit, and content hash, in eider.lock's format; the only part that is
# committed) and fetched on first use into .vendor/<name> (gitignored), byte for byte the
# pinned commit, its content hash checked. eider-pkg (packages/pkg) uses .vendor/toml,
# eider-doc (packages/doc) .vendor/json and .vendor/markdown, tests/crypto .vendor/json; they
# import them as path dependencies. The compiler needs none of them: eiderc still builds from
# the seed with only a C compiler and no network.
#
#   sh scripts/vendor.sh fetch [<name>...]     make .vendor/<name> the pinned release (all by
#                                              default), fetching it when it is missing or
#                                              vendor.lock pins another release
#   sh scripts/vendor.sh check                 vendor.lock is well formed; every fetched copy
#                                              has its pinned content hash; and where the
#                                              library's checkout is here, its pinned commit
#                                              has that hash and equals the copy byte for byte
#   sh scripts/vendor.sh list                  name, version and commit of each pin
#   sh scripts/vendor.sh <name> <commit|tag>   pin that commit of the checkout of eider-<name>
#                                              (a release) and fetch it into .vendor/<name>
#
# Where a pinned commit comes from, in this order (the first that has it):
#   1. the library's checkout: $EIDER_<NAME> (e.g. EIDER_JSON), else
#      $EIDER_SIBLINGS/eider-<name> (EIDER_SIBLINGS: the directory holding the sibling
#      repositories, default ..), when it has the commit;
#   2. a git mirror: $EIDER_VENDOR_SOURCES/eider-<name>.git (or eider-<name>), else
#      eider-pkg's mirror of the pinned URL in its store ($EIDER_HOME/git/..., default
#      ~/.eider), else that mirror cloned or updated from the pinned URL over the network;
#   3. a release tarball: $EIDER_VENDOR_SOURCES/eider-<name>-<version>.tar.gz (or
#      eider-<name>-<commit>.tar.gz), else GitHub's archive of the commit, downloaded.
# EIDER_VENDOR_SOURCES names a directory of offline mirrors and tarballs;
# EIDER_VENDOR_OFFLINE=1 never uses the network (1 and 2 and 3 from local files only).
#
# Nothing is trusted on first use: every source's files must have the content hash vendor.lock
# pins (eider-pkg's: sha256 over `path NUL hex(sha256(content)) LF` in sorted path order,
# `eider-pkg hash`, the one an eider.lock records for the same release), and a tarball that
# records its commit (GitHub's and git archive's do) must record the pinned one. A mismatch is
# a hard error: exit 1, nothing is written to .vendor/. So is a copy in .vendor/ that was
# modified. When no source has the commit the exit status is 3 and the message says what was
# tried (the tools that need .vendor/ then stop; scripts/verify.sh skips their legs).
#
# Never edit .vendor/: change the library in its repository, release it, and pin the release.
# `check` is a leg of scripts/verify.sh.
cd "$(dirname "$0")/.." || exit 1
here=$(pwd -P)
LOCK=vendor.lock
DIR=.vendor

die() { echo "vendor.sh: $*" >&2; exit 2; }
upper() { echo "$1" | tr 'a-z' 'A-Z'; }
checkout_of() {
  var=EIDER_$(upper "$1")
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
short() { echo "$1" | cut -c1-12; }

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
# tree_hash <dir>: eider-pkg's content hash (packages/pkg/store.ei `tree_hash`): every file
# but those under .git, deps, vendor and .vendor, as `path NUL hex(sha256) LF` in byte order
tree_hash() {
  (cd "$1" && find . \( -name .git -o -name deps -o -name vendor -o -name .vendor \) -prune -o -type f -print |
    sed 's|^\./||' | LC_ALL=C sort |
    while IFS= read -r f; do printf '%s\000%s\n' "$f" "$(sha256 < "$f")"; done | sha256 | sed 's/^/sha256-/')
}

# pin <name>: sets n v url c h from vendor.lock (returns 1 when <name> isn't pinned)
pin() {
  n=$1; v=$(field "$n" version); s=$(field "$n" source); h=$(field "$n" hash)
  [ -n "$h" ] || return 1
  c=${s##*#}; url=${s%#*}; url=${url#git+}
}
# eider-pkg's mirror of a URL in its store (packages/pkg/store.ei `mirror_dir`)
store_mirror() {
  home=${EIDER_HOME:-${HOME:-/nonexistent}/.eider}
  echo "$home/git/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g')"
}
has_commit() { git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null; }
# export_to <git dir> <commit> <dir>: the commit's files, as `git archive` gives them
export_to() { rm -rf "$3" && mkdir -p "$3" && git -C "$1" archive --format=tar "$2" | tar -x -C "$3"; }

# untar <tarball> <dir>: its files into <dir> (a single top-level directory is stripped);
# fails (hard) when the archive records another commit than $c
untar() {
  rc=$(gzip -dc "$1" 2>/dev/null | head -c 1024 | tr '\0' '\n' | sed -n 's/^52 comment=//p')
  if [ -n "$rc" ] && [ "$rc" != "$c" ]; then
    echo "vendor.sh: $1 records commit $rc, vendor.lock pins eider-$n $v at $c" >&2; exit 1
  fi
  rm -rf "$2.x" && mkdir -p "$2.x" && tar -xzf "$1" -C "$2.x" || { rm -rf "$2.x"; return 1; }
  rm -rf "$2"
  set -- "$1" "$2" "$2.x"/*
  if [ $# = 3 ] && [ -d "$3" ] && [ -z "$(ls -A "$2.x" | grep -v "^$(basename "$3")\$")" ]; then mv "$3" "$2"; rmdir "$2.x"; else mv "$2.x" "$2"; fi
}

# get <name> <tmp dir>: the pinned commit's files into <tmp dir> from the first source that has
# them; sets `from`. Returns 3 (with $tried) when none does.
get() {
  t=$2; tried=""
  # 1. the sibling checkout
  if co=$(checkout_of "$n"); then
    if has_commit "$co" "$c"; then export_to "$co" "$c" "$t" && { from="the checkout $co"; return 0; }; fi
    tried="$tried; the checkout $co (no commit $c: fetch it there)"
  else
    tried="$tried; no checkout at ${EIDER_SIBLINGS:-..}/eider-$n (EIDER_SIBLINGS, EIDER_$(upper "$n"))"
  fi
  # 2. git mirrors, local first
  for m in ${EIDER_VENDOR_SOURCES:+"$EIDER_VENDOR_SOURCES/eider-$n.git" "$EIDER_VENDOR_SOURCES/eider-$n"} "$(store_mirror "$url")"; do
    if [ -d "$m" ] && has_commit "$m" "$c"; then export_to "$m" "$c" "$t" && { from="the mirror $m"; return 0; }; fi
  done
  if [ "${EIDER_VENDOR_OFFLINE:-0}" != 1 ] && command -v git >/dev/null 2>&1; then
    m=$(store_mirror "$url")
    if [ -d "$m" ]; then
      GIT_TERMINAL_PROMPT=0 git -C "$m" fetch --quiet --prune --force origin >/dev/null 2>&1
    else
      mkdir -p "$(dirname "$m")" && GIT_TERMINAL_PROMPT=0 git clone --quiet --mirror "$url" "$m" >/dev/null 2>&1 || rm -rf "$m"
    fi
    if [ -d "$m" ] && has_commit "$m" "$c"; then export_to "$m" "$c" "$t" && { from="$url"; return 0; }; fi
    tried="$tried; git from $url (not reachable, or no commit $c)"
  fi
  # 3. release tarballs, local first
  for f in ${EIDER_VENDOR_SOURCES:+"$EIDER_VENDOR_SOURCES/eider-$n-$v.tar.gz" "$EIDER_VENDOR_SOURCES/eider-$n-$c.tar.gz"}; do
    if [ -f "$f" ]; then untar "$f" "$t" && { from="$f"; return 0; }; fi
  done
  [ -n "$EIDER_VENDOR_SOURCES" ] && tried="$tried; no mirror or tarball of eider-$n in $EIDER_VENDOR_SOURCES"
  case $url in
    https://github.com/*)
      if [ "${EIDER_VENDOR_OFFLINE:-0}" != 1 ] && command -v curl >/dev/null 2>&1; then
        a=${url%.git}/archive/$c.tar.gz
        mkdir -p target/vendor
        if curl -fsSL --max-time 120 -o "target/vendor/eider-$n-$c.tar.gz.part" "$a" 2>/dev/null; then
          mv "target/vendor/eider-$n-$c.tar.gz.part" "target/vendor/eider-$n-$c.tar.gz"
          untar "target/vendor/eider-$n-$c.tar.gz" "$t" && { from="$a"; return 0; }
        fi
        rm -f "target/vendor/eider-$n-$c.tar.gz.part"
        tried="$tried; the tarball $a (not reachable)"
      fi ;;
  esac
  [ "${EIDER_VENDOR_OFFLINE:-0}" = 1 ] && tried="$tried; no network (EIDER_VENDOR_OFFLINE=1)"
  return 3
}

# fetch_one <name>: .vendor/<name> is the pinned release afterwards (0), or exit 1 / return 3
fetch_one() {
  pin "$1" || die "\`$1\` is not pinned in $LOCK (pinned: $(names | paste -sd' ' -))"
  d=$DIR/$n; stamp=$DIR/.$n.pin
  if [ -d "$d" ]; then
    have=$(tree_hash "$d")
    if [ "$have" = "$h" ]; then
      [ "$(cat "$stamp" 2>/dev/null)" = "$c $h" ] || echo "$c $h" > "$stamp"
      return 0
    fi
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$c $h" ]; then
      echo "vendor.sh: $d has content hash $have, but it was fetched as eider-$n $v ($c, $h): it was modified; never edit $DIR/ (change eider-$n, release it and pin the release); remove $d to fetch it again" >&2
      exit 1
    fi
    if [ ! -f "$stamp" ]; then
      echo "vendor.sh: $d has content hash $have, $LOCK pins eider-$n $v with $h, and nothing records where $d came from; remove it to fetch the pinned release" >&2
      exit 1
    fi
    echo "vendor.sh: $LOCK pins eider-$n $v ($(short "$c")) now; fetching it again" >&2
  fi
  mkdir -p "$DIR"
  t=$DIR/.tmp-$n-$$
  trap 'rm -rf "$DIR"/.tmp-*-$$ "$DIR"/.tmp-*-$$.x' EXIT
  get "$n" "$t"; g=$?
  if [ $g != 0 ]; then
    rm -rf "$t" "$t.x"
    echo "vendor.sh: cannot fetch eider-$n $v ($c), no source has it:${tried#;}. For an offline fetch, point EIDER_SIBLINGS (or EIDER_$(upper "$n")) at a checkout that has the commit, or EIDER_VENDOR_SOURCES at a directory with eider-$n.git or eider-$n-$v.tar.gz (LAYERS.md, \"Vendored libraries\")" >&2
    return 3
  fi
  got=$(tree_hash "$t")
  if [ "$got" != "$h" ]; then
    rm -rf "$t"
    echo "vendor.sh: eider-$n $v ($c) from $from has content hash $got, but $LOCK pins $h: refusing it (a changed release or a tampered source)" >&2
    exit 1
  fi
  rm -rf "$d" "$stamp"
  mv "$t" "$d" && echo "$c $h" > "$stamp"
  echo "fetched eider-$n $v ($(short "$c")) from $from into $d, $h" >&2
}

write_lock() {
  {
    echo "# vendor.lock: the pinned releases of the libraries eider-lang's own tools use, fetched"
    echo "# into .vendor/<name> (gitignored) on first use and hash-checked (LAYERS.md, \"Vendored"
    echo "# libraries\"). Written by scripts/vendor.sh <name> <commit>. Do not edit."
    echo "version = 1"
    for wn in $( (names; echo "$1") | sort -u); do
      if [ "$wn" = "$1" ]; then wv=$2; wu=$3; wc=$4; wh=$5; else wv=$(field "$wn" version); ws=$(field "$wn" source); wc=${ws##*#}; wu=${ws%#*}; wu=${wu#git+}; wh=$(field "$wn" hash); fi
      printf '\n[[package]]\nname = "%s"\nversion = "%s"\nsource = "git+%s#%s"\nhash = "%s"\n' "$wn" "$wv" "$wu" "$wc" "$wh"
    done
  } > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK"
}

case $1 in
  ""|-h|--help|help) sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  list)
    for n in $(names); do s=$(field "$n" source); echo "$n $(field "$n" version) ${s##*#}"; done
    exit 0 ;;
  fetch)
    shift
    [ -f "$LOCK" ] || die "no $LOCK"
    all=0
    if [ $# = 0 ]; then set -- $(names); all=1; fi
    worst=0
    for x in "$@"; do fetch_one "$x" || worst=3; done
    # with every pin fetched, a copy no pin names is left over from an older vendor.lock
    if [ $all = 1 ] && [ -d "$DIR" ]; then
      for d in "$DIR"/*/; do
        [ -d "$d" ] || continue
        x=$(basename "$d")
        [ -n "$(field "$x" hash)" ] || { rm -rf "$d" "$DIR/.$x.pin"; echo "vendor.sh: removed $DIR/$x ($LOCK no longer pins it)" >&2; }
      done
    fi
    exit $worst ;;
  check)
    bad=0
    [ -f "$LOCK" ] || { echo "FAIL vendor: no $LOCK"; exit 1; }
    T=$(mktemp -d)
    trap 'rm -rf "$T"' EXIT
    [ -z "$(names | sort | uniq -d)" ] || { echo "FAIL vendor: $LOCK pins $(names | sort | uniq -d | head -1) twice"; bad=1; }
    for n in $(names); do
      pin "$n" || { echo "FAIL vendor: $n in $LOCK has no hash"; bad=1; continue; }
      echo "$n" | grep -Eq '^[a-z][a-z0-9_]*$' || { echo "FAIL vendor: \`$n\` in $LOCK is not a package name"; bad=1; }
      echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "FAIL vendor: $n in $LOCK: version \`$v\` is not MAJOR.MINOR.PATCH"; bad=1; }
      echo "$c" | grep -Eq '^[0-9a-f]{40}$' || { echo "FAIL vendor: $n in $LOCK: \`$c\` is not a commit id"; bad=1; }
      echo "$h" | grep -Eq '^sha256-[0-9a-f]{64}$' || { echo "FAIL vendor: $n in $LOCK: \`$h\` is not a content hash"; bad=1; }
      case $url in https://*|file://*) ;; *) echo "FAIL vendor: $n in $LOCK: source \`$url\` is not an https or file URL"; bad=1 ;; esac
      d=$DIR/$n
      fetched=0
      if [ -d "$d" ]; then
        have=$(tree_hash "$d")
        if [ "$have" != "$h" ]; then
          echo "FAIL vendor: $d has content hash $have, $LOCK pins $h: it was edited, or is another release (sh scripts/vendor.sh fetch $n)"
          bad=1; continue
        fi
        fetched=1
      fi
      if co=$(checkout_of "$n"); then
        if ! has_commit "$co" "$c"; then
          echo "FAIL vendor: eider-$n $v: the checkout $co doesn't have the pinned commit $c (fetch it, or set EIDER_$(upper "$n"))"
          bad=1; continue
        fi
        export_to "$co" "$c" "$T/$n"
        have=$(tree_hash "$T/$n")
        if [ "$have" != "$h" ]; then
          echo "FAIL vendor: eider-$n $v: commit $c in $co has content hash $have, $LOCK pins $h"; bad=1; continue
        fi
        if [ $fetched = 0 ]; then
          echo "ok   vendor $n: eider-$n $v ($(short "$c")), pinned commit in $co has the pinned hash"
          echo "skip vendor $n: $d is not fetched (sh scripts/vendor.sh fetch), so not compared byte for byte"
        elif diff -r "$T/$n" "$d" > "$T/$n.diff" 2>&1; then
          echo "ok   vendor $n: eider-$n $v ($(short "$c")), $d byte-identical to $co"
        else
          echo "FAIL vendor: $d differs from eider-$n $c in $co:"; head -20 "$T/$n.diff" | sed 's/^/  /'; bad=1
        fi
      elif [ $fetched = 1 ]; then
        echo "ok   vendor $n: eider-$n $v ($(short "$c")), $d has the pinned hash"
        echo "skip vendor $n: no checkout of eider-$n to compare $d with (set EIDER_SIBLINGS or EIDER_$(upper "$n"))"
      else
        echo "ok   vendor $n: eider-$n $v ($(short "$c")), pin well formed"
        echo "skip vendor $n: $d is not fetched and there is no checkout of eider-$n (EIDER_SIBLINGS or EIDER_$(upper "$n")): its hash is unchecked"
      fi
    done
    exit $bad ;;
esac

# pin <name> <commit>
n=$1; rev=$2
[ -n "$rev" ] || die "usage: scripts/vendor.sh fetch [<name>...] | check | list | <name> <commit|tag>"
echo "$n" | grep -Eq '^[a-z][a-z0-9_]*$' || die "\`$n\` is not a package name"
co=$(checkout_of "$n") || die "no git checkout of eider-$n in ${EIDER_SIBLINGS:-$here/..} (set EIDER_SIBLINGS, or EIDER_$(upper "$n"))"
cc=$(git -C "$co" rev-parse --verify --quiet "$rev^{commit}") || die "$co has no commit $rev"
cv=$(git -C "$co" show "$cc:eider.toml" 2>/dev/null | sed -n 's/^version = "\(.*\)"$/\1/p' | head -1)
[ -n "$cv" ] || die "$co at $cc has no eider.toml with a version"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export_to "$co" "$cc" "$T/$n"
ch=$(tree_hash "$T/$n")
cu=$(field "$n" source); cu=${cu%#*}; cu=${cu#git+}
[ -n "$cu" ] || cu=https://github.com/klxdev/eider-$n.git
write_lock "$n" "$cv" "$cu" "$cc" "$ch"
echo "pinned eider-$n $cv ($cc), $ch, in $LOCK"
fetch_one "$n" || exit $?
