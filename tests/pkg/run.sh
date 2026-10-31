#!/bin/sh
# End-to-end test of eider-pkg. Never touches the network: every git package is a local
# repository under target/tmp/pkgtest/repos, fetched through file:// URLs, and the store
# is a fresh $EIDER_HOME. Programs are built by the compiler from compiler/ (bare imports
# through eider.lock; no deps/ link farm). Prints `ok   <step>` or `FAIL <step>` plus a diff per step.
cd "$(dirname "$0")/../.." || exit 1
R=$(pwd)
T="$R/target/tmp/pkgtest"
rm -rf "$T"
mkdir -p "$T/repos" "$T/home"
EIDER_HOME="$T/home"; export EIDER_HOME
EIDER_CACHE=off; export EIDER_CACHE
# reproducible commits, and no user git config (signing, hooks, default branch)
GIT_CONFIG_GLOBAL=/dev/null; GIT_CONFIG_NOSYSTEM=1; export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
GIT_AUTHOR_NAME=t; GIT_AUTHOR_EMAIL=t@example.com; GIT_COMMITTER_NAME=t; GIT_COMMITTER_EMAIL=t@example.com
GIT_AUTHOR_DATE="2026-01-01T00:00:00Z"; GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_DATE

# build the tool once, up front, so compiler noise stays out of the comparisons
scripts/eider-pkg >/dev/null 2>&1
[ -x target/eider-pkg ] || { echo "FAIL build eider-pkg"; exit 1; }
# the programs import their dependencies by name (`import "util"`), which the compiler
# resolves through eider.lock (docs/compiler.md, "C8.3: packages and modules"), and eider-pkg
# asks it what each package uses (`eiderc caps`, "C8.5"): a compiler newer than the seed,
# compiler/ as the seed builds it (EIDERC=<binary> to use another), until the seed knows
# `caps` and the per-package `ffi`
if [ -n "$EIDERC" ]; then
  EC=$EIDERC
else
  EC="$R/target/eiderc-next"
  newest=$(find "$R/compiler" "$R/std" "$R/core" -name '*.ei' -newer "$EC" 2>/dev/null | head -1)
  if [ ! -x "$EC" ] || [ -n "$newest" ]; then
    scripts/ei build compiler/main.ei -o "$EC" >/dev/null 2>"$T/eiderc.build.log" || { cat "$T/eiderc.build.log"; echo "FAIL build eiderc"; exit 1; }
  fi
fi
EIDERC=$EC; export EIDERC

fail=0
# check <step> <expected> <got>: compare after replacing $T with <T>
check() {
  got=$(printf '%s\n' "$3" | sed "s|$T|<T>|g")
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1"; printf '%s\n' "$2" > "$T/exp"; printf '%s\n' "$got" | diff "$T/exp" - | head -20; fail=1; fi
}
# pkg <project> <args...>: run eider-pkg in a project; output plus `exit N`
pkg() { p=$1; shift; scripts/eider-pkg -C "$T/$p" "$@" 2>&1; echo "exit $?"; }
# run <project> [file]: build and run its main.ei (or file); imports go through eider.lock
run() { (cd "$T/$1" && "$EC" run "${2:-main.ei}" >"$T/out" 2>&1; s=$?; cat "$T/out"; echo "exit $s"); }
# store_dir <project> <name>: where the compiler finds a locked git package in the store
# ($EIDER_HOME/pkg/<name>-<first 16 hex digits of its locked content hash>)
store_dir() { h=$(grep -A4 "^name = \"$2\"" "$T/$1/eider.lock" | sed -n 's/^hash = "sha256-\(.\{16\}\).*/\1/p'); echo "$EIDER_HOME/pkg/$2-$h"; }
# mask: hide commit ids and content hashes, which depend on where the checkout lives
mask() { sed -e "s|$T|<T>|g" -e 's/sha256-[0-9a-f]\{64\}/sha256-<hash>/g' -e 's/[0-9a-f]\{40\}/<commit>/g' -e 's|pkg/\([a-z0-9_]*\)-[0-9a-f]\{16\}|pkg/\1-<hash16>|g'; }
# tree_hash <dir>: the store's content hash, recomputed independently with sha256sum
tree_hash() {
  (cd "$1" && find . -type f ! -path './.git/*' ! -path './deps/*' ! -path './vendor/*' | sed 's|^\./||' | LC_ALL=C sort |
    while read -r f; do printf '%s\000%s\n' "$f" "$(sha256sum < "$f" | cut -d' ' -f1)"; done | sha256sum | sed 's/^/sha256-/; s/ .*//')
}

# ---- fixtures: git repositories with tagged versions

# commit <repo> <tag-or-empty>: commit everything in the repo, then tag it
commit() {
  git -C "$T/repos/$1" add -A
  git -C "$T/repos/$1" commit -q -m "${2:-change}" --allow-empty
  [ -n "$2" ] && git -C "$T/repos/$1" tag -f "$2" >/dev/null
}
newrepo() { mkdir -p "$T/repos/$1"; git -C "$T/repos/$1" init -q -b main; }
# manifest <dir> <name> <version> [extra toml]
manifest() { printf '[package]\nname = "%s"\nversion = "%s"\n%s' "$2" "$3" "$4" > "$1/eider.toml"; }
U="file://$T/repos"

# legacy: only required by util 1.0.0, so it must drop out once util 1.2.0 is selected
newrepo legacy
manifest "$T/repos/legacy" legacy 1.0.0
printf 'pub fn old() -> i64 { 0 }\n' > "$T/repos/legacy/legacy.ei"
commit legacy v1.0.0

newrepo util
manifest "$T/repos/util" util 1.0.0 "
[deps.legacy]
git = \"$U/legacy\"
version = \"1.0.0\"
"
printf 'pub fn level() -> i64 { 1 }\n' > "$T/repos/util/util.ei"
commit util v1.0.0
manifest "$T/repos/util" util 1.1.0
printf 'pub fn level() -> i64 { 2 }\n' > "$T/repos/util/util.ei"
commit util v1.1.0
manifest "$T/repos/util" util 1.2.0
printf 'pub fn level() -> i64 { 3 }\n' > "$T/repos/util/util.ei"
commit util v1.2.0

# alpha needs util >= 1.0.0, beta needs util >= 1.2.0: the diamond
newrepo alpha
manifest "$T/repos/alpha" alpha 1.0.0 "
[deps.util]
git = \"$U/util\"
version = \"1.0.0\"
"
printf 'import "util"\n\npub fn value() -> i64 { util.level() * 10 }\n' > "$T/repos/alpha/alpha.ei"
commit alpha v1.0.0

newrepo beta
manifest "$T/repos/beta" beta 1.0.0 "
[deps.util]
git = \"$U/util\"
version = \"1.2.0\"
"
printf 'import "util"\n\npub fn value() -> i64 { util.level() + 100 }\n' > "$T/repos/beta/beta.ei"
commit beta v1.0.0

# gamma is added by rev; its later commit must not be picked up
newrepo gamma
manifest "$T/repos/gamma" gamma 0.3.0
printf 'pub fn value() -> i64 { 7 }\n' > "$T/repos/gamma/gamma.ei"
commit gamma ""
GAMMA=$(git -C "$T/repos/gamma" rev-parse HEAD)
printf 'pub fn value() -> i64 { 8 }\n' > "$T/repos/gamma/gamma.ei"
commit gamma ""

# geom: a path dependency
mkdir -p "$T/geom"
manifest "$T/geom" geom 0.2.0
printf 'pub fn area(w: i64, h: i64) -> i64 { w * h }\n' > "$T/geom/geom.ei"

# ---- init

check "init" "created package \`app\`
exit 0" "$(pkg app init)"
check "init writes eider.toml" '[package]
name = "app"
version = "0.1.0"
main = "main.ei"
eider = "0.1"' "$(cat "$T/app/eider.toml")"
check "init writes a program with package imports" 'import "core/sys"
import "std/io"' "$(head -2 "$T/app/main.ei")"
check "init twice" "eider-pkg: eider.toml already exists
exit 1" "$(pkg app init)"
check "fetch with no deps" "locked 0 package(s)
exit 0" "$(pkg app fetch)"
check "run the init program" "hello from eider
exit 0" "$(run app)"

# ---- add

check "add path dep" "locked 1 package(s)
exit 0" "$(pkg app add geom --path ../geom)"
check "add git dep by version (util 1.0.0 brings legacy)" "locked 4 package(s)
exit 0" "$(pkg app add alpha --git "$U/alpha" --version 1.0.0)"
check "add second git dep (diamond)" "locked 4 package(s)
exit 0" "$(pkg app add beta --git "$U/beta" --version 1.0.0)"
check "add git dep by rev" "locked 5 package(s)
exit 0" "$(pkg app add gamma --git "$U/gamma" --rev "$GAMMA")"
check "eider.toml after add" "[package]
name = \"app\"
version = \"0.1.0\"
main = \"main.ei\"
eider = \"0.1\"

[deps.geom]
path = \"../geom\"

[deps.alpha]
git = \"file://<T>/repos/alpha\"
version = \"1.0.0\"

[deps.beta]
git = \"file://<T>/repos/beta\"
version = \"1.0.0\"

[deps.gamma]
git = \"file://<T>/repos/gamma\"
rev = \"<commit>\"" "$(mask < "$T/app/eider.toml")"

# ---- the lockfile: MVS picked util 1.2.0 (beta's minimum) and dropped legacy

LOCK="# eider.lock: written by \`eider-pkg\`. Do not edit.
version = 1

[[package]]
name = \"alpha\"
version = \"1.0.0\"
source = \"git+file://<T>/repos/alpha#<commit>\"
hash = \"sha256-<hash>\"
deps = [\"util\"]
grants = []

[[package]]
name = \"beta\"
version = \"1.0.0\"
source = \"git+file://<T>/repos/beta#<commit>\"
hash = \"sha256-<hash>\"
deps = [\"util\"]
grants = []

[[package]]
name = \"gamma\"
version = \"0.3.0\"
source = \"git+file://<T>/repos/gamma#<commit>\"
rev = \"<commit>\"
hash = \"sha256-<hash>\"
deps = []
grants = []

[[package]]
name = \"geom\"
version = \"0.2.0\"
source = \"path+../geom\"
deps = []
grants = []

[[package]]
name = \"util\"
version = \"1.2.0\"
source = \"git+file://<T>/repos/util#<commit>\"
hash = \"sha256-<hash>\"
deps = []
grants = []"
check "eider.lock" "$LOCK" "$(mask < "$T/app/eider.lock")"
UTIL12=$(git -C "$T/repos/util" rev-parse v1.2.0)
check "locked commits are the tag and the rev" "gamma#$GAMMA
util#$UTIL12" "$(grep -o -e "util#[0-9a-f]*" -e "gamma#[0-9a-f]*" "$T/app/eider.lock")"
UTILDIR=$(store_dir app util)
check "locked hash is the content hash of the export" "hash = \"$(tree_hash "$UTILDIR")\"" "$(grep -A1 "repos/util#" "$T/app/eider.lock" | tail -1)"
check "eider-pkg hash agrees" "$(tree_hash "$T/geom")
exit 0" "$(pkg app hash ../geom)"

cp "$T/app/eider.lock" "$T/lock1"
check "fetch" "locked 5 package(s)
exit 0" "$(pkg app fetch)"
cp "$T/app/eider.lock" "$T/lock2"
pkg app fetch >/dev/null
cmp -s "$T/lock1" "$T/lock2" && cmp -s "$T/lock2" "$T/app/eider.lock" && echo "ok   fetch keeps eider.lock byte-identical" || { echo "FAIL fetch keeps eider.lock byte-identical"; diff "$T/lock1" "$T/app/eider.lock"; fail=1; }

check "tree" "app 0.1.0
  geom 0.2.0
  alpha 1.0.0
    util 1.2.0
  beta 1.0.0
    util 1.2.0 (*)
  gamma 0.3.0
exit 0" "$(pkg app tree)"

# no deps/ link farm: the compiler reads eider.lock and finds each git package in the store
check "fetch makes no deps/" "no deps/" "$(ls -A "$T/app/deps" 2>/dev/null || echo "no deps/")"
check "every locked git package is in the store" "alpha ok
beta ok
gamma ok
util ok" "$(for n in alpha beta gamma util; do [ -f "$(store_dir app $n)/$n.ei" ] && echo "$n ok" || echo "$n missing"; done)"
mkdir -p "$T/app/deps/.all/old"
pkg app fetch >/dev/null
check "fetch removes the link farm of an earlier eider-pkg" "no deps/" "$(ls -A "$T/app/deps" 2>/dev/null || echo "no deps/")"

# ---- build and run: imports by package name, through eider.lock

cat > "$T/app/main.ei" <<'EOF'
import "core/sys"
import "std/io"
import "geom"
import "alpha"
import "beta"
import "gamma"

fn main() uses io {
    io.outln(sys.lit("app"))
    print(geom.area(6, 7))
    print(alpha.value())
    print(beta.value())
    print(gamma.value())
}
EOF
check "run the program" "app
42
30
103
7
exit 0" "$(run app)"
printf 'import "util"\n\nfn main() uses io { print(util.level()) }\n' > "$T/app/indirect.ei"
got=$(run app indirect.ei)
check "the root can't import an indirect dep" "1
1
exit 1" "$(printf '%s\n' "$got" | grep -c "E0809.*package \`util\` is not a dependency of \`app\`"; printf '%s\n' "$got" | grep -c "eider-pkg add util"; printf '%s\n' "$got" | tail -1)"
printf 'import "deps/geom/geom.ei"\n\nfn main() uses io { print(geom.area(1, 1)) }\n' > "$T/app/old.ei"
got=$(run app old.ei)
check "an import through the old link farm says what changed" "1
exit 1" "$(printf '%s\n' "$got" | grep -c "no longer links dependencies into deps/"; printf '%s\n' "$got" | tail -1)"

# ---- a dependency can only import what it declared

mkdir -p "$T/sneaky" "$T/sneakyapp"
manifest "$T/sneaky" sneaky 0.1.0
printf 'import "geom"\n\npub fn value() -> i64 { geom.area(2, 3) }\n' > "$T/sneaky/sneaky.ei"
manifest "$T/sneakyapp" sneakyapp 0.1.0 '
[deps.geom]
path = "../geom"

[deps.sneaky]
path = "../sneaky"
'
printf 'import "sneaky"\n\nfn main() uses io { print(sneaky.value()) }\n' > "$T/sneakyapp/main.ei"
check "fetch (sneaky)" "locked 2 package(s)
exit 0" "$(pkg sneakyapp fetch)"
got=$(run sneakyapp)
check "an undeclared import fails to compile" "1
exit 1" "$(printf '%s\n' "$got" | grep -c "E0809.*package \`geom\` is not a dependency of \`sneaky\`"; printf '%s\n' "$got" | tail -1)"
manifest "$T/sneaky" sneaky 0.1.0 '
[deps.geom]
path = "../geom"
'
pkg sneakyapp fetch >/dev/null
check "declared, it compiles" "6
exit 0" "$(run sneakyapp)"
# a dependency declared by hand is not locked until a fetch
mkdir -p "$T/late"
manifest "$T/late" late 0.1.0
printf 'pub fn value() -> i64 { 9 }\n' > "$T/late/late.ei"
printf '\n[deps.late]\npath = "../late"\n' >> "$T/sneakyapp/eider.toml"
printf 'import "late"\n\nfn main() uses io { print(late.value()) }\n' > "$T/sneakyapp/late.ei"
got=$(run sneakyapp late.ei)
check "a dependency not in eider.lock fails to compile" "1
exit 1" "$(printf '%s\n' "$got" | grep -c "E0810.*package \`late\` is not in .*/sneakyapp/eider.lock"; printf '%s\n' "$got" | tail -1)"
pkg sneakyapp fetch >/dev/null
check "fetched, it compiles" "9
exit 0" "$(run sneakyapp late.ei)"

# ---- capability grants: eider-pkg asks the compiler what each package uses (`eiderc caps`,
# docs/compiler.md "C8.5: capabilities per package"), and the compiler checks the grants
# again when it builds (E0204)

mkdir -p "$T/fsdep" "$T/ffidep" "$T/plain" "$T/capsapp"
manifest "$T/fsdep" fsdep 0.1.0
printf '// uses net (in a comment: ignored)\npub fn noop() -> i64 { 0 }\n\npub fn save()\n    uses fs {\n}\n' > "$T/fsdep/fsdep.ei"
manifest "$T/ffidep" ffidep 0.1.0
printf 'extern "c" fn abs(x: i32) -> i32 uses clock\nimport "helper.ei"\n\npub fn magnitude(x: i32) -> i32 uses clock, ffi { unsafe { abs(x) } }\n' > "$T/ffidep/ffidep.ei"
# what the entry module reaches counts: helper.ei's `uses net`
printf 'pub fn f()\n    uses net {\n}\n' > "$T/ffidep/helper.ei"
# a test program is not part of the package (nor are words that aren't capabilities, which
# are compile errors: compile-fail tests have them)
mkdir -p "$T/ffidep/tests"
printf 'fn f() uses fs {\n}\nfn g() uses telepathy {\n}\n' > "$T/ffidep/tests/bad.ei"
# `uses ffi` with no unmanaged code means nothing outside the package, and core (whose
# externs back sys.lit) is the toolchain's: plain needs no grant
manifest "$T/plain" plain 0.1.0
printf 'import "core/sys"\n\npub fn hello() -> u64 uses ffi { sys.lit("hi").len() as u64 }\n' > "$T/plain/plain.ei"
check "init (caps)" "created package \`capsapp\`
exit 0" "$(pkg capsapp init)"
cp "$T/capsapp/eider.toml" "$T/caps.toml"
check "ungranted fs is rejected" "eider-pkg: package \`fsdep\` uses capability \`fs\` (fsdep.ei:5) but is only granted []; to allow it, add \"fs\" to \`uses\` in its [deps.fsdep] table
exit 1" "$(pkg capsapp add fsdep --path ../fsdep)"
cmp -s "$T/caps.toml" "$T/capsapp/eider.toml" && echo "ok   a rejected add leaves eider.toml alone" || { echo "FAIL a rejected add leaves eider.toml alone"; fail=1; }
check "granted fs is accepted" "locked 1 package(s)
exit 0" "$(pkg capsapp add fsdep --path ../fsdep --uses fs)"
check "extern needs ffi" "eider-pkg: package \`ffidep\` uses capability \`ffi\` (ffidep.ei:1) but is only granted [io]; to allow it, add \"ffi\" to \`uses\` in its [deps.ffidep] table (it declares \`extern\` functions: unmanaged code)
exit 1" "$(pkg capsapp add ffidep --path ../ffidep --uses io)"
check "a module the entry imports counts, a test program doesn't" "eider-pkg: package \`ffidep\` uses capability \`net\` (helper.ei:2) but is only granted [clock, ffi]; to allow it, add \"net\" to \`uses\` in its [deps.ffidep] table
exit 1" "$(pkg capsapp add ffidep --path ../ffidep --uses clock,ffi)"
check "granted ffi is accepted" "locked 2 package(s)
exit 0" "$(pkg capsapp add ffidep --path ../ffidep --uses clock,ffi,net)"
check "uses ffi without extern, and core, need no grant" "locked 3 package(s)
exit 0" "$(pkg capsapp add plain --path ../plain)"
check "grants in the tree" "capsapp 0.1.0
  fsdep 0.1.0 uses fs
  ffidep 0.1.0 uses clock,ffi,net
  plain 0.1.0
exit 0" "$(pkg capsapp tree)"
check "unknown capability" "eider-pkg: <T>/capsapp/eider.toml:20:1: unknown capability \`disk\` (known: io, clock, fs, net, threads, ffi)
exit 1" "$(pkg capsapp add other --path ../plain --uses disk)"
# the program calls them without `uses ffi` (it stays inside ffidep and core), but with the
# real capabilities they declare (magnitude: clock)
printf 'import "std/io"\nimport "fsdep"\nimport "ffidep"\nimport "plain"\n\nfn main() uses io, clock {\n    print(fsdep.noop())\n    print(ffidep.magnitude(-7))\n    print(plain.hello())\n}\n' > "$T/capsapp/use.ei"
check "granted packages run without \`uses ffi\`" "0
7
2
exit 0" "$(run capsapp use.ei)"
# a grant taken away after the fetch: the compiler holds the import to eider.toml (E0204)
sed -i.bak '/^uses = \["fs"\]$/d' "$T/capsapp/eider.toml"
got=$(run capsapp use.ei)
check "the compiler rejects an ungranted capability (E0204)" "error[E0204]: package \`fsdep\` uses capability \`fs\` in \`save\` (fsdep.ei:5) but is only granted []
  help: to allow it, add \"fs\" to \`uses\` in [deps.fsdep] of <T>/capsapp/eider.toml
exit 1" "$(printf '%s\n' "$got" | grep -e '^error\[E0204\]' -e '^  help:'; printf '%s\n' "$got" | tail -1)"
mv "$T/capsapp/eider.toml.bak" "$T/capsapp/eider.toml"

# ---- lockfile pinning: a moved tag doesn't move a locked package

manifest "$T/repos/util" util 1.2.0
printf 'pub fn level() -> i64 { 4 }\n' > "$T/repos/util/util.ei"
commit util v1.2.0
UTIL12B=$(git -C "$T/repos/util" rev-parse v1.2.0)
[ "$UTIL12" != "$UTIL12B" ] || { echo "FAIL tag didn't move"; fail=1; }
check "fetch after the tag moved" "locked 5 package(s)
exit 0" "$(pkg app fetch)"
cmp -s "$T/lock1" "$T/app/eider.lock" && echo "ok   fetch keeps the locked commit" || { echo "FAIL fetch keeps the locked commit"; diff "$T/lock1" "$T/app/eider.lock"; fail=1; }
check "still runs the locked code" "app
42
30
103
7
exit 0" "$(run app)"
check "update" "locked 5 package(s)
exit 0" "$(pkg app update)"
check "update re-resolves the tag" "util#$UTIL12B" "$(grep -o "util#[0-9a-f]*" "$T/app/eider.lock")"
check "runs the new code" "app
42
40
104
7
exit 0" "$(run app)"
check "a rev stays put on update" "gamma#$GAMMA" "$(grep -o "gamma#[0-9a-f]*" "$T/app/eider.lock")"

# ---- content hashes: a modified store or vendor dir is detected

UTILDIR=$(store_dir app util)
chmod -R u+w "$UTILDIR"
cp "$UTILDIR/util.ei" "$T/util.ei.bak"
printf 'pub fn level() -> i64 { 666 }\n' > "$UTILDIR/util.ei"
check "a tampered store dir is detected" "eider-pkg: the store copy of \`util\` at <T>/home/pkg/util-<hash16> was modified (content hash sha256-<hash>, exported as sha256-<hash>); delete that directory and fetch again
exit 1" "$(pkg app fetch | mask)"
cp "$T/util.ei.bak" "$UTILDIR/util.ei"
check "restored, it fetches" "locked 5 package(s)
exit 0" "$(pkg app fetch)"

# ---- vendor, then build offline with no mirrors and no store

check "vendor" "vendored git packages into vendor/
exit 0" "$(pkg app vendor)"
check "vendor/ holds the git packages" "alpha
beta
gamma
util" "$(ls "$T/app/vendor")"
cp "$T/app/eider.lock" "$T/lock3"
chmod -R u+w "$EIDER_HOME"
rm -rf "$EIDER_HOME"
check "fetch --offline from vendor/" "locked 5 package(s)
exit 0" "$(pkg app fetch --offline)"
cmp -s "$T/lock3" "$T/app/eider.lock" && echo "ok   vendoring doesn't change eider.lock" || { echo "FAIL vendoring doesn't change eider.lock"; diff "$T/lock3" "$T/app/eider.lock"; fail=1; }
check "the store is gone" "no store" "$(ls "$EIDER_HOME/pkg" 2>/dev/null || echo "no store")"
check "runs from vendor/" "app
42
40
104
7
exit 0" "$(run app)"
cp "$T/app/vendor/util/util.ei" "$T/util.ei.bak"
printf 'pub fn level() -> i64 { 666 }\n' > "$T/app/vendor/util/util.ei"
check "a tampered vendor dir is detected" "eider-pkg: vendor/ doesn't match eider.lock for \`util\`: sha256-<hash> vs sha256-<hash>
exit 1" "$(pkg app fetch --offline | mask)"
cp "$T/util.ei.bak" "$T/app/vendor/util/util.ei"
mv "$T/app/vendor" "$T/vendor.off"
check "offline with no vendor/ and no store fails" "eider-pkg: offline: file://<T>/repos/alpha has no local copy of 1.0.0
exit 1" "$(pkg app fetch --offline)"
check "online, a locked commit is fetched again" "locked 5 package(s)
exit 0" "$(pkg app fetch)"
cmp -s "$T/lock3" "$T/app/eider.lock" && echo "ok   refetching doesn't change eider.lock" || { echo "FAIL refetching doesn't change eider.lock"; diff "$T/lock3" "$T/app/eider.lock"; fail=1; }
mv "$T/vendor.off" "$T/app/vendor"

# ---- remove

check "remove" "locked 4 package(s)
exit 0" "$(pkg app remove gamma)"
check "remove drops the table" "0" "$(grep -c gamma "$T/app/eider.toml")"
check "vendor again drops what's gone" "vendored git packages into vendor/
exit 0
alpha
beta
util" "$(pkg app vendor; ls "$T/app/vendor")"
printf 'pub fn level() -> i64 { 666 }\n' > "$T/app/vendor/util/util.ei"
check "vendor repairs a modified vendor/" "vendored git packages into vendor/
exit 0
pub fn level() -> i64 { 4 }" "$(pkg app vendor; cat "$T/app/vendor/util/util.ei")"
check "remove drops it from eider.lock" "0" "$(grep -c gamma "$T/app/eider.lock")"
got=$(run app)
check "a removed dependency can't be imported" "1
exit 1" "$(printf '%s\n' "$got" | grep -c "E0809.*package \`gamma\` is not a dependency of \`app\`"; printf '%s\n' "$got" | tail -1)"
check "remove an unknown dep" "eider-pkg: no [deps.nope] table in eider.toml (inline \`name = { ... }\` entries must be removed by hand)
exit 1" "$(pkg app remove nope)"

# ---- errors

mkdir -p "$T/bad"
manifest "$T/bad" bad 0.1.0 'verison = "1.0.0"
'
check "unknown key" "eider-pkg: <T>/bad/eider.toml:4:1: unknown key \`package.verison\`
exit 1" "$(pkg bad fetch)"
manifest "$T/bad" std 0.1.0
check "std is the toolchain's" "eider-pkg: <T>/bad/eider.toml:2:1: \`core\` and \`std\` are the toolchain's packages; pick another name
exit 1" "$(pkg bad fetch)"
manifest "$T/bad" bad 0.1.0 '
[deps.core]
path = "../geom"
'
check "core can't be declared" "eider-pkg: <T>/bad/eider.toml:6:1: \`core\` is part of the toolchain: import its modules (\`import \"core/<module>\"\`) without declaring it
exit 1" "$(pkg bad fetch)"
manifest "$T/bad" bad 0.1.0
cp "$T/bad/eider.toml" "$T/bad.toml"
check "bad version" "eider-pkg: <T>/bad/eider.toml:7:1: \`version\` must be MAJOR.MINOR.PATCH
exit 1" "$(pkg bad add util --git "$U/util" --version 1.2)"
check "missing path dep" "eider-pkg: path dependency \`nope\` not found at <T>/nope
exit 1" "$(pkg bad add nope --path ../nope)"
check "name mismatch" "eider-pkg: dependency \`shapes\` points at the package \`geom\` (the [deps.<name>] key must be the package's own name)
exit 1" "$(pkg bad add shapes --path ../geom)"
check "missing tag" "eider-pkg: file://<T>/repos/util has no tag \`v9.0.0\`
exit 1" "$(pkg bad add util --git "$U/util" --version 9.0.0)"
cmp -s "$T/bad.toml" "$T/bad/eider.toml" && echo "ok   failed adds leave eider.toml alone" || { echo "FAIL failed adds leave eider.toml alone"; fail=1; }
manifest "$T/bad" bad 1.0
check "bad package version" "eider-pkg: <T>/bad/eider.toml:3:1: \`version\` must be MAJOR.MINOR.PATCH, e.g. \"0.1.0\"
exit 1" "$(pkg bad fetch)"
manifest "$T/bad" bad 0.1.0 'eider = "0.1.0"
'
check "eider is a MAJOR.MINOR" "eider-pkg: <T>/bad/eider.toml:4:1: \`eider\` is the toolchain MAJOR.MINOR the package needs, e.g. \"0.1\"
exit 1" "$(pkg bad fetch)"

# ---- the version (VERSION, docs/site/tooling/releases.md)

check "--version" "eider-pkg $(cat VERSION)
exit 0" "$(scripts/eider-pkg --version 2>&1; echo "exit $?")"

exit $fail
