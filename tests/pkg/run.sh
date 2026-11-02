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
# the programs import their dependencies by name (`import util`), which the compiler
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
  (cd "$1" && find . -type f ! -path './.git/*' ! -path './deps/*' ! -path './.vendor/*' | sed 's|^\./||' | LC_ALL=C sort |
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
printf 'import util\n\npub fn value() -> i64 { util.level() * 10 }\n' > "$T/repos/alpha/alpha.ei"
commit alpha v1.0.0

newrepo beta
manifest "$T/repos/beta" beta 1.0.0 "
[deps.util]
git = \"$U/util\"
version = \"1.2.0\"
"
printf 'import util\n\npub fn value() -> i64 { util.level() + 100 }\n' > "$T/repos/beta/beta.ei"
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
eider = "0.4"' "$(cat "$T/app/eider.toml")"
check "init writes a program with package imports" 'import core.sys
import std.io' "$(head -2 "$T/app/main.ei")"
check "init twice" "eider-pkg: eider.toml already exists
exit 1" "$(pkg app init)"
# streams: an error is one line on stderr and nothing on stdout, exit 1; a usage error the
# same; what a command reports when it succeeds goes to stdout, nothing to stderr, exit 0
streams() { p=$1; shift; scripts/eider-pkg -C "$T/$p" "$@" >"$T/so" 2>"$T/se"; s=$?; printf 'stdout: [%s]\nstderr: [%s]\nexit %s\n' "$(cat "$T/so")" "$(cat "$T/se")" $s; }
check "an error goes to stderr" "stdout: []
stderr: [eider-pkg: eider.toml already exists]
exit 1" "$(streams app init)"
check "a usage error goes to stderr" "stdout: []
stderr: [eider-pkg: usage: eider-pkg [-C dir] (init [name] | add <name> --path P | add <name> --git URL --version V|--rev R [--uses a,b | --confirm | --no-grant] | remove <name> | grant|revoke <name> <cap,...> | fetch|update [--offline] [--grant a,b | --grant-all] | vendor | tree | hash <dir> | --version)]
exit 1" "$(streams app frobnicate)"
check "a missing eider.toml goes to stderr" "stdout: []
stderr: [eider-pkg: cannot read <T>/nowhere/eider.toml: No such file or directory]
exit 1" "$(mkdir -p "$T/nowhere" && streams nowhere tree)"
check "fetch with no deps" "locked 0 package(s)
exit 0" "$(pkg app fetch)"
check "success goes to stdout" "stdout: [locked 0 package(s)]
stderr: []
exit 0" "$(streams app fetch)"
check "run the init program" "hello from eider
exit 0" "$(run app)"

# ---- add

check "add path dep" "added geom 0.2.0 — it uses nothing
locked 1 package(s)
exit 0" "$(pkg app add geom --path ../geom)"
check "add git dep by version (util 1.0.0 brings legacy)" "added alpha 1.0.0 — it uses nothing
locked 4 package(s)
exit 0" "$(pkg app add alpha --git "$U/alpha" --version 1.0.0)"
check "add second git dep (diamond)" "added beta 1.0.0 — it uses nothing
locked 4 package(s)
exit 0" "$(pkg app add beta --git "$U/beta" --version 1.0.0)"
check "add git dep by rev" "added gamma 0.3.0 — it uses nothing
locked 5 package(s)
exit 0" "$(pkg app add gamma --git "$U/gamma" --rev "$GAMMA")"
check "eider.toml after add" "[package]
name = \"app\"
version = \"0.1.0\"
main = \"main.ei\"
eider = \"0.3\"

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
import core.sys
import std.io
import geom
import alpha
import beta
import gamma

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
printf 'import util\n\nfn main() uses io { print(util.level()) }\n' > "$T/app/indirect.ei"
got=$(run app indirect.ei)
check "the root can't import an indirect dep" "1
1
exit 1" "$(printf '%s\n' "$got" | grep -c "E0809.*\`util\` is neither this package (\`app\`) nor one of its dependencies"; printf '%s\n' "$got" | grep -c "eider-pkg add util"; printf '%s\n' "$got" | tail -1)"
printf 'import "deps/geom/geom.ei"\n\nfn main() uses io { print(geom.area(1, 1)) }\n' > "$T/app/old.ei"
got=$(run app old.ei)
check "an import through the old link farm says what changed" "1
exit 1" "$(printf '%s\n' "$got" | grep -c "no longer links dependencies into deps/"; printf '%s\n' "$got" | tail -1)"

# ---- a dependency can only import what it declared

mkdir -p "$T/sneaky" "$T/sneakyapp"
manifest "$T/sneaky" sneaky 0.1.0
printf 'import geom\n\npub fn value() -> i64 { geom.area(2, 3) }\n' > "$T/sneaky/sneaky.ei"
manifest "$T/sneakyapp" sneakyapp 0.1.0 '
[deps.geom]
path = "../geom"

[deps.sneaky]
path = "../sneaky"
'
printf 'import sneaky\n\nfn main() uses io { print(sneaky.value()) }\n' > "$T/sneakyapp/main.ei"
check "fetch (sneaky)" "locked 2 package(s)
exit 0" "$(pkg sneakyapp fetch)"
got=$(run sneakyapp)
check "an undeclared import fails to compile" "1
exit 1" "$(printf '%s\n' "$got" | grep -c "E0809.*\`geom\` is neither this package (\`sneaky\`) nor one of its dependencies"; printf '%s\n' "$got" | tail -1)"
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
printf 'import late\n\nfn main() uses io { print(late.value()) }\n' > "$T/sneakyapp/late.ei"
got=$(run sneakyapp late.ei)
check "a dependency not in eider.lock fails to compile" "1
exit 1" "$(printf '%s\n' "$got" | grep -c "E0810.*package \`late\` is not in .*/sneakyapp/eider.lock"; printf '%s\n' "$got" | tail -1)"
pkg sneakyapp fetch >/dev/null
check "fetched, it compiles" "9
exit 0" "$(run sneakyapp late.ei)"

# ---- capability grants: eider-pkg asks the compiler what each package uses (`eiderc caps`
# on every module of the package, docs/compiler.md "C8.5: capabilities per package") and
# writes the grant itself: `add` grants what the package uses, fetch/update narrow a grant
# that shrank and stop on one that grew until it is accepted; the compiler checks the grants
# again when it builds (E0204)

mkdir -p "$T/fsdep" "$T/ffidep" "$T/plain" "$T/clockdep" "$T/capsapp"
manifest "$T/fsdep" fsdep 0.1.0
printf '// uses net (in a comment: ignored)\npub fn noop() -> i64 { 0 }\n\npub fn save()\n    uses fs {\n}\n' > "$T/fsdep/fsdep.ei"
manifest "$T/ffidep" ffidep 0.1.0
printf 'extern "c" fn abs(x: i32) -> i32 uses clock\nimport ffidep.helper\n\npub fn magnitude(x: i32) -> i32 uses clock, ffi { unsafe { abs(x) } }\n' > "$T/ffidep/ffidep.ei"
# what the entry module reaches counts: helper.ei's `uses net`
printf 'pub fn f()\n    uses net {\n}\n' > "$T/ffidep/helper.ei"
# and so does a module the entry doesn't import (a depender may `import ffidep.extra.side`)
mkdir -p "$T/ffidep/extra"
printf 'pub fn start() uses threads {\n}\n' > "$T/ffidep/extra/side.ei"
# a test program is not part of the package (nor are words that aren't capabilities, which
# are compile errors: compile-fail tests have them)
mkdir -p "$T/ffidep/tests"
printf 'fn f() uses fs {\n}\nfn g() uses telepathy {\n}\n' > "$T/ffidep/tests/bad.ei"
# `uses ffi` with no unmanaged code means nothing outside the package, and core (whose
# externs back sys.lit) is the toolchain's: plain needs no grant
manifest "$T/plain" plain 0.1.0
printf 'import core.sys\n\npub fn hello() -> u64 uses ffi { sys.lit("hi").len() as u64 }\n' > "$T/plain/plain.ei"
manifest "$T/clockdep" clockdep 0.1.0
printf 'pub fn now() uses clock {\n}\n' > "$T/clockdep/clockdep.ei"
check "init (caps)" "created package \`capsapp\`
exit 0" "$(pkg capsapp init)"
check "add grants what the package uses" "added fsdep 0.1.0 — it uses: fs (granted)
locked 1 package(s)
exit 0" "$(pkg capsapp add fsdep --path ../fsdep)"
check "the grant is in eider.toml" '[deps.fsdep]
path = "../fsdep"
uses = ["fs"]' "$(sed -n '/^\[deps.fsdep\]/,$p' "$T/capsapp/eider.toml")"
cp "$T/capsapp/eider.toml" "$T/caps.toml"
check "--uses is an explicit grant: all of it must be covered" "eider-pkg: more capabilities than granted (eider.lock is not written):
  ffidep 0.1.0 uses: clock, ffi, net, threads (granted: io)
    first used: clock (ffidep.ei:1), ffi (ffidep.ei:1, \`extern\` functions: unmanaged code), net (helper.ei:2), threads (extra/side.ei:1)
to grant it what it uses, add it without --uses
exit 1" "$(pkg capsapp add ffidep --path ../ffidep --uses io)"
cmp -s "$T/caps.toml" "$T/capsapp/eider.toml" && echo "ok   a rejected add leaves eider.toml alone" || { echo "FAIL a rejected add leaves eider.toml alone"; fail=1; }
check "--uses broader than the use is narrowed" "note: ffidep 0.1.0 doesn't use: io; its grant is narrowed to: clock, ffi, net, threads
added ffidep 0.1.0 — it uses: clock, ffi, net, threads (granted)
locked 2 package(s)
exit 0" "$(pkg capsapp add ffidep --path ../ffidep --uses clock,ffi,net,threads,io)"
check "the narrowed grant is sorted" 'uses = ["clock", "ffi", "net", "threads"]' "$(grep -A2 '^\[deps.ffidep\]' "$T/capsapp/eider.toml" | tail -1)"
check "uses ffi without extern, and core, need no grant" "added plain 0.1.0 — it uses nothing
locked 3 package(s)
exit 0" "$(pkg capsapp add plain --path ../plain --no-grant)"
check "grants in the tree" "capsapp 0.1.0
  fsdep 0.1.0 uses fs
  ffidep 0.1.0 uses clock,ffi,net,threads
  plain 0.1.0
exit 0" "$(pkg capsapp tree)"
check "unknown capability" "eider-pkg: <T>/capsapp/eider.toml:20:1: unknown capability \`disk\` (known: io, clock, fs, net, threads, ffi)
exit 1" "$(pkg capsapp add other --path ../plain --uses disk)"
cp "$T/capsapp/eider.lock" "$T/caps.lock"
check "--no-grant keeps the dependency ungranted and the lock unwritten" "eider-pkg: added \`clockdep\` to eider.toml with no grant; more capabilities than granted (eider.lock is not written):
  clockdep 0.1.0 uses: clock (granted: nothing)
    first used: clock (clockdep.ei:1)
to accept: eider fetch --grant clockdep
exit 1" "$(pkg capsapp add clockdep --path ../clockdep --no-grant)"
check "--no-grant: no uses" '[deps.clockdep]
path = "../clockdep"' "$(sed -n '/^\[deps.clockdep\]/,$p' "$T/capsapp/eider.toml")"
cmp -s "$T/caps.lock" "$T/capsapp/eider.lock" && echo "ok   --no-grant: eider.lock unchanged" || { echo "FAIL --no-grant: eider.lock unchanged"; fail=1; }
check "fetch stops on the ungranted dependency" "eider-pkg: more capabilities than granted (eider.lock is not written):
  clockdep 0.1.0 now also uses: clock (granted: nothing)
    first used: clock (clockdep.ei:1)
to accept: eider fetch --grant clockdep (or --grant-all)
exit 1" "$(pkg capsapp fetch)"
check "grant" "clockdep: uses = [\"clock\"] (granted clock)
exit 0" "$(pkg capsapp grant clockdep clock)"
check "grant writes uses" '[deps.clockdep]
path = "../clockdep"
uses = ["clock"]' "$(sed -n '/^\[deps.clockdep\]/,$p' "$T/capsapp/eider.toml")"
check "granted, it fetches" "locked 4 package(s)
exit 0" "$(pkg capsapp fetch)"
check "grant again" "clockdep is already granted: clock (uses = [\"clock\"])
exit 0" "$(pkg capsapp grant clockdep clock)"
check "revoke" "clockdep: uses = [] (revoked clock)
exit 0" "$(pkg capsapp revoke clockdep clock)"
check "revoked, fetch stops" "1
exit 1" "$(pkg capsapp fetch | grep -c 'clockdep 0.1.0 now also uses: clock (granted: nothing)'; pkg capsapp fetch | tail -1)"
check "fetch --grant accepts" "locked 4 package(s)
exit 0
uses = [\"clock\"]" "$(pkg capsapp fetch --grant clockdep; grep -A2 '^\[deps.clockdep\]' "$T/capsapp/eider.toml" | tail -1)"
check "grant an unknown capability" "eider-pkg: unknown capability \`disk\` (known: io, clock, fs, net, threads, ffi)
exit 1" "$(pkg capsapp grant clockdep disk)"
check "grant to a package that isn't a dependency" "eider-pkg: \`nope\` is not a dependency in eider.toml
exit 1" "$(pkg capsapp grant nope io)"
check "--grant for a package that isn't a dependency" "eider-pkg: --grant nope: not a dependency in eider.toml
exit 1" "$(pkg capsapp fetch --grant nope)"
# --confirm reads the answer from standard input (a terminal, or a pipe)
check "--confirm, declined" "plain2 0.1.0 uses: clock. Grant it? [y/N] eider-pkg: not added: \`plain2\` would need clock
exit 1" "$(cp -r "$T/clockdep" "$T/plain2" && manifest "$T/plain2" plain2 0.1.0 && mv "$T/plain2/clockdep.ei" "$T/plain2/plain2.ei" && echo n | pkg capsapp add plain2 --path ../plain2 --confirm)"
check "--confirm, declined: eider.toml unchanged" "0" "$(grep -c plain2 "$T/capsapp/eider.toml")"
check "--confirm, accepted" "plain2 0.1.0 uses: clock. Grant it? [y/N] added plain2 0.1.0 — it uses: clock (granted)
locked 5 package(s)
exit 0" "$(echo y | pkg capsapp add plain2 --path ../plain2 --confirm)"
check "one way to grant" "eider-pkg: add takes one of --uses, --confirm and --no-grant
exit 1" "$(pkg capsapp add x --path ../plain --no-grant --uses io)"
# the program calls them without `uses ffi` (it stays inside ffidep and core), but with the
# real capabilities they declare (magnitude: clock)
printf 'import std.io\nimport fsdep\nimport ffidep\nimport plain\n\nfn main() uses io, clock {\n    print(fsdep.noop())\n    print(ffidep.magnitude(-7))\n    print(plain.hello())\n}\n' > "$T/capsapp/use.ei"
check "granted packages run without \`uses ffi\`" "0
7
2
exit 0" "$(run capsapp use.ei)"
# a grant taken away after the fetch: the compiler holds the import to eider.toml (E0204),
# and its help names the command that grants it
pkg capsapp revoke fsdep fs >/dev/null
got=$(run capsapp use.ei)
check "the compiler rejects an ungranted capability (E0204)" "error[E0204]: package \`fsdep\` uses capability \`fs\` in \`save\` (fsdep.ei:5) but is only granted []
  help: to allow it, run \`eider grant fsdep fs\` in <T>/capsapp (it adds \"fs\" to \`uses\` in [deps.fsdep] of its eider.toml)
exit 1" "$(printf '%s\n' "$got" | grep -e '^error\[E0204\]' -e '^  help:'; printf '%s\n' "$got" | tail -1)"
check "eider grant, as the help says, and it builds" "fsdep: uses = [\"fs\"] (granted fs)
0
7
2
exit 0" "$(pkg capsapp grant fsdep fs | grep -v '^exit'; run capsapp use.ei)"

# a dependency's dependency is held to its depender's grant for what the entry module reaches
# (extra/side.ei's threads is the library's business); every missing capability is named
mkdir -p "$T/wrapdep" "$T/wrapapp"
manifest "$T/wrapdep" wrapdep 0.1.0 '
[deps.ffidep]
path = "../ffidep"
uses = ["clock"]
'
printf 'pub fn w() -> i64 { 1 }\n' > "$T/wrapdep/wrapdep.ei"
manifest "$T/wrapapp" wrapapp 0.1.0
check "a library's grant short of what its program reaches names everything missing" "eider-pkg: package \`ffidep\` uses ffi (ffidep.ei:1, \`extern\` functions: unmanaged code), net (helper.ei:2) but is only granted [clock]; its dependers must grant it \`uses = [\"clock\", \"ffi\", \"net\"]\` in their [deps.ffidep] table
exit 1" "$(pkg wrapapp add wrapdep --path ../wrapdep)"

# ---- growth and shrinking: fetch/update narrow a grant automatically, and stop with a diff
# when a dependency's use grows, until it is accepted; eider.toml keeps its layout

mkdir -p "$T/growdep" "$T/growdep2" "$T/growapp"
manifest "$T/growdep" growdep 0.1.0
printf 'pub fn say() uses io {\n}\n' > "$T/growdep/growdep.ei"
manifest "$T/growdep2" growdep2 0.1.0
manifest "$T/growapp" growapp 0.1.0 '
# reviewed by the team
[deps.growdep]
path = "../growdep"   # local
uses = [
    "io",
]   # reviewed

# a pure helper
[deps.growdep2]
path = "../growdep2"
'
check "fetch (growth)" "locked 2 package(s)
exit 0" "$(pkg growapp fetch)"
cp "$T/growapp/eider.lock" "$T/grow.lock"
printf 'pub fn say() uses io {\n}\n\npub fn keep() uses fs {\n}\n' > "$T/growdep/growdep.ei"
check "growth stops update with a diff" "eider-pkg: more capabilities than granted (eider.lock is not written):
  growdep 0.1.0 now also uses: fs (granted: io)
    first used: fs (growdep.ei:4)
to accept: eider update --grant growdep (or --grant-all)
exit 1" "$(pkg growapp update)"
cmp -s "$T/grow.lock" "$T/growapp/eider.lock" && echo "ok   growth: eider.lock unchanged" || { echo "FAIL growth: eider.lock unchanged"; fail=1; }
check "update --grant accepts it" "locked 2 package(s)
exit 0" "$(pkg growapp update --grant growdep)"
check "the grant is rewritten in place" '
# reviewed by the team
[deps.growdep]
path = "../growdep"   # local
uses = ["fs", "io"]   # reviewed

# a pure helper
[deps.growdep2]
path = "../growdep2"' "$(sed -n '4,$p' "$T/growapp/eider.toml")"
printf 'pub fn keep() uses fs {\n}\n' > "$T/growdep/growdep.ei"
check "a shrinking use narrows the grant" "note: growdep 0.1.0 no longer uses: io; its grant is narrowed to: fs
locked 2 package(s)
exit 0
uses = [\"fs\"]   # reviewed" "$(pkg growapp fetch; grep '^uses' "$T/growapp/eider.toml")"
printf 'pub fn keep() uses fs, net {\n}\n' > "$T/growdep/growdep.ei"
printf 'pub fn tick() uses clock {\n}\n' > "$T/growdep2/growdep2.ei"
check "two grow: both in the diff" "eider-pkg: more capabilities than granted (eider.lock is not written):
  growdep 0.1.0 now also uses: net (granted: fs)
    first used: net (growdep.ei:1)
  growdep2 0.1.0 now also uses: clock (granted: nothing)
    first used: clock (growdep2.ei:1)
to accept: eider update --grant growdep,growdep2 (or --grant-all)
exit 1" "$(pkg growapp update)"
check "update --grant-all" "locked 2 package(s)
exit 0
uses = [\"fs\", \"net\"]   # reviewed
uses = [\"clock\"]" "$(pkg growapp update --grant-all; grep '^uses' "$T/growapp/eider.toml")"

# ---- [policy]: what a package may grant at all

mkdir -p "$T/netdep" "$T/sock" "$T/polapp"
manifest "$T/netdep" netdep 0.1.0
printf 'pub fn get() uses net {\n}\n' > "$T/netdep/netdep.ei"
manifest "$T/sock" sock 0.1.0
printf 'pub fn open() uses net {\n}\n' > "$T/sock/sock.ei"
manifest "$T/polapp" polapp 0.1.0 '
[policy]
deny = ["ffi"]

[policy.allow]
net = ["netdep"]
'
cp "$T/polapp/eider.toml" "$T/pol.toml"
check "policy: deny" "eider-pkg: cannot grant \`ffi\` to \`ffidep\`: the policy denies it to every dependency ([policy] deny = [\"ffi\"] in <T>/polapp/eider.toml)
exit 1" "$(pkg polapp add ffidep --path ../ffidep)"
check "policy: allow names who may have it" "eider-pkg: cannot grant \`net\` to \`sock\`: the policy allows it only to netdep ([policy.allow] net = [\"netdep\"] in <T>/polapp/eider.toml)
exit 1" "$(pkg polapp add sock --path ../sock)"
check "policy: an explicit --uses is held to it too" "eider-pkg: cannot grant \`net\` to \`sock\`: the policy allows it only to netdep ([policy.allow] net = [\"netdep\"] in <T>/polapp/eider.toml)
exit 1" "$(pkg polapp add sock --path ../sock --uses net)"
cmp -s "$T/pol.toml" "$T/polapp/eider.toml" && echo "ok   policy: eider.toml unchanged" || { echo "FAIL policy: eider.toml unchanged"; fail=1; }
check "policy: allowed" "added netdep 0.1.0 — it uses: net (granted)
locked 1 package(s)
exit 0" "$(pkg polapp add netdep --path ../netdep)"
check "policy: grant" "eider-pkg: cannot grant \`ffi\` to \`netdep\`: the policy denies it to every dependency ([policy] deny = [\"ffi\"] in <T>/polapp/eider.toml)
exit 1" "$(pkg polapp grant netdep ffi)"
printf '\n[deps.sock]\npath = "../sock"\nuses = ["net"]\n' >> "$T/polapp/eider.toml"
check "policy: a hand-written grant is held to it at fetch" "eider-pkg: cannot grant \`net\` to \`sock\`: the policy allows it only to netdep ([policy.allow] net = [\"netdep\"] in <T>/polapp/eider.toml)
exit 1" "$(pkg polapp fetch)"
check "policy: an unknown capability" "eider-pkg: <T>/polapp/eider.toml:6:1: unknown capability \`disk\` in [policy.allow] (known: io, clock, fs, net, threads, ffi)
exit 1" "$(manifest "$T/polapp" polapp 0.1.0 '
[policy.allow]
disk = ["netdep"]
'; pkg polapp fetch)"

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

# ---- content hashes: a modified store or .vendor dir is detected

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

check "vendor" "vendored git packages into .vendor/
exit 0" "$(pkg app vendor)"
check ".vendor/ holds the git packages" "alpha
beta
gamma
util" "$(ls "$T/app/.vendor")"
cp "$T/app/eider.lock" "$T/lock3"
chmod -R u+w "$EIDER_HOME"
rm -rf "$EIDER_HOME"
check "fetch --offline from .vendor/" "locked 5 package(s)
exit 0" "$(pkg app fetch --offline)"
cmp -s "$T/lock3" "$T/app/eider.lock" && echo "ok   vendoring doesn't change eider.lock" || { echo "FAIL vendoring doesn't change eider.lock"; diff "$T/lock3" "$T/app/eider.lock"; fail=1; }
check "the store is gone" "no store" "$(ls "$EIDER_HOME/pkg" 2>/dev/null || echo "no store")"
check "runs from .vendor/" "app
42
40
104
7
exit 0" "$(run app)"
cp "$T/app/.vendor/util/util.ei" "$T/util.ei.bak"
printf 'pub fn level() -> i64 { 666 }\n' > "$T/app/.vendor/util/util.ei"
check "a tampered vendor dir is detected" "eider-pkg: .vendor/ doesn't match eider.lock for \`util\`: sha256-<hash> vs sha256-<hash>
exit 1" "$(pkg app fetch --offline | mask)"
cp "$T/util.ei.bak" "$T/app/.vendor/util/util.ei"
mv "$T/app/.vendor" "$T/vendor.off"
check "offline with no .vendor/ and no store fails" "eider-pkg: offline: file://<T>/repos/alpha has no local copy of 1.0.0
exit 1" "$(pkg app fetch --offline)"
check "online, a locked commit is fetched again" "locked 5 package(s)
exit 0" "$(pkg app fetch)"
cmp -s "$T/lock3" "$T/app/eider.lock" && echo "ok   refetching doesn't change eider.lock" || { echo "FAIL refetching doesn't change eider.lock"; diff "$T/lock3" "$T/app/eider.lock"; fail=1; }
mv "$T/vendor.off" "$T/app/.vendor"

# ---- remove

check "remove" "locked 4 package(s)
exit 0" "$(pkg app remove gamma)"
check "remove drops the table" "0" "$(grep -c gamma "$T/app/eider.toml")"
check "vendor again drops what's gone" "vendored git packages into .vendor/
exit 0
alpha
beta
util" "$(pkg app vendor; ls "$T/app/.vendor")"
printf 'pub fn level() -> i64 { 666 }\n' > "$T/app/.vendor/util/util.ei"
check "vendor repairs a modified .vendor/" "vendored git packages into .vendor/
exit 0
pub fn level() -> i64 { 4 }" "$(pkg app vendor; cat "$T/app/.vendor/util/util.ei")"
check "remove drops it from eider.lock" "0" "$(grep -c gamma "$T/app/eider.lock")"
got=$(run app)
check "a removed dependency can't be imported" "1
exit 1" "$(printf '%s\n' "$got" | grep -c "E0809.*\`gamma\` is neither this package (\`app\`) nor one of its dependencies"; printf '%s\n' "$got" | tail -1)"
check "remove an unknown dep" "eider-pkg: no [deps.nope] table in eider.toml (inline \`name = { ... }\` entries must be removed by hand)
exit 1" "$(pkg app remove nope)"

# ---- EIDER_PKG_OVERRIDE: a local checkout stands in for a git package (override.ei)

# a project on a repository that doesn't exist: only the override can satisfy it
mkdir -p "$T/ov" "$T/ovutil/target"
manifest "$T/ov" ov 0.1.0 "main = \"main.ei\"

[deps.util]
git = \"file://$T/repos/no-such-util\"
version = \"1.2.0\"
"
printf 'import util\n\nfn main() uses io { print(util.level()) }\n' > "$T/ov/main.ei"
manifest "$T/ovutil" util 1.3.0
printf 'pub fn level() -> i64 { 13 }\n' > "$T/ovutil/util.ei"
printf 'build output\n' > "$T/ovutil/target/junk"
check "without the override the repository is needed" "eider-pkg: offline: file://<T>/repos/no-such-util has no local copy of 1.2.0
exit 1" "$(pkg ov fetch --offline)"
check "override: fetch offline from a plain directory" "locked 1 package(s)
exit 0" "$(EIDER_PKG_OVERRIDE="util=$T/ovutil" pkg ov fetch --offline)"
check "override: the lock keeps the git source" "version = \"1.3.0\"
source = \"git+file://<T>/repos/no-such-util#override\"" "$(grep -E '^(source|version) = "' "$T/ov/eider.lock" | mask)"
check "override: the program runs on the checkout" "13
exit 0" "$(run ov)"
check "override: target/ stays out of the store" "util.ei" "$(cd "$(store_dir ov util)" && find . -type f ! -name eider.toml | sed 's|^\./||')"
printf 'pub fn level() -> i64 { 14 }\n' > "$T/ovutil/util.ei"
check "override: an edit is picked up by the next fetch" "14
exit 0" "$(EIDER_PKG_OVERRIDE="util=$T/ovutil" pkg ov fetch --offline >/dev/null; run ov)"
manifest "$T/ovutil" util 1.1.0
check "override: an older checkout is refused" "eider-pkg: EIDER_PKG_OVERRIDE: the checkout of \`util\` has version 1.1.0, but 1.2.0 or later is required
exit 1" "$(EIDER_PKG_OVERRIDE="util=$T/ovutil" pkg ov fetch --offline)"
check "override: a malformed entry" "eider-pkg: EIDER_PKG_OVERRIDE: \`util\` is not <name>=<dir>
exit 1" "$(EIDER_PKG_OVERRIDE="util" pkg ov fetch --offline)"

# a git checkout at the locked release gives the lock a network fetch gives; only what git
# would commit is taken (not ignored files), and uncommitted edits count
newrepo ovgit
manifest "$T/repos/ovgit" ovgit 0.4.0
printf 'pub fn value() -> i64 { 40 }\n' > "$T/repos/ovgit/ovgit.ei"
printf 'target/\n' > "$T/repos/ovgit/.gitignore"
commit ovgit v0.4.0
mkdir -p "$T/repos/ovgit/target" && printf 'x\n' > "$T/repos/ovgit/target/junk"
mkdir -p "$T/ov2"
manifest "$T/ov2" ov2 0.1.0 "main = \"main.ei\"

[deps.ovgit]
git = \"$U/ovgit\"
version = \"0.4.0\"
"
printf 'import ovgit\n\nfn main() uses io { print(ovgit.value()) }\n' > "$T/ov2/main.ei"
pkg ov2 fetch > /dev/null
cp "$T/ov2/eider.lock" "$T/ov2.lock"
rm -rf "$EIDER_HOME/pkg"/ovgit-* "$EIDER_HOME/index"
check "override: a clean checkout of the release" "locked 1 package(s)
exit 0" "$(EIDER_PKG_OVERRIDE="ovgit=$T/repos/ovgit" pkg ov2 update --offline)"
cmp -s "$T/ov2.lock" "$T/ov2/eider.lock" && echo "ok   override: the lock is the network fetch's" || { echo "FAIL override: the lock is the network fetch's"; diff "$T/ov2.lock" "$T/ov2/eider.lock"; fail=1; }
check "override: runs from the store copy" "40
exit 0" "$(run ov2)"
printf 'pub fn value() -> i64 { 41 }\n' > "$T/repos/ovgit/ovgit.ei"
check "override: an uncommitted edit counts" "41
exit 0" "$(EIDER_PKG_OVERRIDE="ovgit=$T/repos/ovgit" pkg ov2 fetch --offline >/dev/null; run ov2)"
git -C "$T/repos/ovgit" checkout -q -- ovgit.ei
check "override off again: back to the locked release" "locked 1 package(s)
exit 0
40
exit 0" "$(cp "$T/ov2.lock" "$T/ov2/eider.lock"; pkg ov2 fetch; run ov2)"

# ---- private git dependencies: a token for github.com URLs, through a one-off credential
# helper (store.ei auth_args). A fake git records its arguments and fails, so nothing is
# fetched; the helper itself is real git's business, and reads the token from the environment.

mkdir -p "$T/fakebin" "$T/authapp"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$AUTHLOG"\nexit 1\n' > "$T/fakebin/git"
printf '#!/bin/sh\n[ -n "$FAKE_GH_TOKEN" ] || exit 1\necho "$FAKE_GH_TOKEN"\n' > "$T/fakebin/gh"
chmod +x "$T/fakebin/git" "$T/fakebin/gh"
AUTHLOG="$T/auth.log"; export AUTHLOG
manifest "$T/authapp" authapp 0.1.0
# auth <url> [VAR=value...]: the arguments git got for a first fetch of <url>
auth() {
  u=$1; shift; : > "$AUTHLOG"; rm -rf "$EIDER_HOME/git"
  env -u GH_TOKEN -u GITHUB_TOKEN "$@" PATH="$T/fakebin:$PATH" EIDER_ROOT="$R" EIDERC="$EC" target/eider-pkg -C "$T/authapp" add secret --git "$u" --version 1.0.0 >/dev/null 2>&1
  cat "$AUTHLOG"
}
GH=https://github.com/o/secret.git
check "auth: GH_TOKEN: a helper for github.com, the other helpers dropped" "1
1" "$(got=$(auth $GH GH_TOKEN=s3cret); printf '%s\n' "$got" | grep -c '^-c credential.https://github.com.helper= -c credential.https://github.com.helper=!f() .* clone --mirror'; printf '%s\n' "$got" | grep -c 'password=\$t')"
check "auth: the token is not on git's command line" "0" "$(auth $GH GH_TOKEN=s3cret | grep -c s3cret)"
check "auth: GITHUB_TOKEN" "1" "$(auth $GH GITHUB_TOKEN=s3cret | grep -c 'helper=!f()')"
check "auth: gh auth token" "1" "$(auth $GH FAKE_GH_TOKEN=s3cret | grep -c 'helper=!f()')"
check "auth: no token: git's own setup" "0" "$(auth $GH | grep -c credential)"
check "auth: another host: git's own setup" "0" "$(auth https://example.com/o/secret.git GH_TOKEN=s3cret | grep -c credential)"
check "auth: nothing is written to the manifest" "0" "$(grep -c secret "$T/authapp/eider.toml")"

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
check "core can't be declared" "eider-pkg: <T>/bad/eider.toml:6:1: \`core\` is part of the toolchain: import its modules (\`import core.<module>\`) without declaring it
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
