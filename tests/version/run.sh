#!/bin/sh
# scripts/version.sh bump, against a COPY of this checkout and fake sibling repositories in a
# scratch directory (#205): the real tree and the real siblings are never touched.
#
#   sh tests/version/run.sh
#
# A minor bump must move, with no hand edit: VERSION and its copies, `eider` in every manifest,
# a library's own `version` line (also where it has no scripts/version.sh, and a second package
# of it), the `[deps.*]` pins on other siblings (git before or after version), the series text of
# docs, tests and goldens (including a quoted `eider = \"0.7\"`), the `eiderc doc` goldens'
# toolchain version, the releases page's version output block and `eider add --version` lines;
# leave history (CHANGELOG, decisions) and a package's own version alone; print the tag commands
# of the libraries and the example, vendor.sh and the re-lock directories; and FAIL (exit 1)
# where it cannot finish (a sibling with a bad VERSION, one whose own version line is another).
# `check` fails while vendor.lock pins another series. A patch bump of eider-lang moves the
# version text, one of a sibling its VERSION and tag command and nothing else.
cd "$(dirname "$0")/../.." || exit 1
root=$(pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
n=0
ok() { n=$((n + 1)); }
no() { echo "FAIL version: $1"; shift; [ $# = 0 ] || printf '%s\n' "$*" | head -12 | sed 's/^/  /'; fail=1; }
check() { # name want got
  if [ "$2" = "$3" ]; then ok; else no "$1" "want: $2" "got:  $3"; fi
}
has() { # name file text: the file contains the line/text
  if grep -qF -- "$3" "$2" 2>/dev/null; then ok; else no "$1" "$2 lacks: $3" "$(head -c 400 "$2" 2>/dev/null)"; fi
}
lacks() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then no "$1" "$2 still has: $3"; else ok; fi
}

OLD=$(tr -d ' \n' < VERSION)
case $OLD in 0.*) ;; *) echo "skip version: the test assumes a 0.x VERSION (it is $OLD)"; exit 0 ;; esac
LIB=${OLD%.*}.0  # the libraries and tools sit at the series .0 or at their own patch; the test fakes .0
OLDS=${OLD%.*}; m=${OLDS#0.}; NEWS=0.$((m + 1)); NEW=$NEWS.0

# a workspace: a copy of this checkout's files, as a repository (the bump wants a clean VERSION), and fakes
mkws() { # dir
  w=$1; mkdir -p "$w/eider-lang"
  (cd "$root" && git ls-files -z | tar --null -T - -cf -) | (cd "$w/eider-lang" && tar -xf -)
  (cd "$w/eider-lang" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t commit -q -m copy)
  # eider-json: no scripts/version.sh, a docs example, a changelog (history)
  mkdir -p "$w/eider-json/docs"
  echo "$LIB" > "$w/eider-json/VERSION"
  printf '[package]\nname = "json"\nversion = "%s"\neider = "%s"\n' "$LIB" "$OLDS" > "$w/eider-json/eider.toml"
  printf 'eider add json --git https://github.com/klxdev/eider-json.git --version %s\nsome other --version %s stays\n' "$LIB" "$LIB" > "$w/eider-json/docs/use.md"
  printf '## %s\n\nneeds `eider = "%s"`\n' "$LIB" "$OLDS" > "$w/eider-json/CHANGELOG.md"
  # eider-http: has scripts/version.sh (sync/check like the real ones), pins json (git first), a lock
  mkdir -p "$w/eider-http/scripts"
  echo "$LIB" > "$w/eider-http/VERSION"
  printf '[package]\nname = "http"\nversion = "%s"\neider = "%s"\n\n[deps.json]\ngit = "https://github.com/klxdev/eider-json.git"\nversion = "%s"\n' "$LIB" "$OLDS" "$LIB" > "$w/eider-http/eider.toml"
  printf '# eider.lock\nversion = 1\n\n[[package]]\nname = "json"\nversion = "%s"\n' "$LIB" > "$w/eider-http/eider.lock"
  cat > "$w/eider-http/scripts/version.sh" <<'EOS'
#!/bin/sh
cd "$(dirname "$0")/.." || exit 1
v=$(tr -d ' \n' < VERSION); series=${v%.*}
of_toml() { sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" eider.toml | head -1; }
case "${1:-}" in
  check) [ "$(of_toml version)" = "$v" ] && [ "$(of_toml eider)" = "$series" ] ;;
  sync) awk -v v="$v" -v s="$series" '!dv && /^version = "/ { print "version = \"" v "\""; dv = 1; next } !de && /^eider = "/ { print "eider = \"" s "\""; de = 1; next } { print }' eider.toml > eider.toml.tmp && mv eider.toml.tmp eider.toml ;;
esac
EOS
  # eider-analyzer's session goldens name the server version
  mkdir -p "$w/eider-analyzer/tests/sessions"
  echo "$LIB" > "$w/eider-analyzer/VERSION"
  printf '[package]\nname = "analyzer"\nversion = "%s"\neider = "%s"\n' "$LIB" "$OLDS" > "$w/eider-analyzer/eider.toml"
  printf '{"result":{"serverInfo":{"name":"eider-analyzer","version":"%s"}}}\n' "$LIB" > "$w/eider-analyzer/tests/sessions/a.out"
  # eider-profiler: no version.sh; its cli package follows its version; pins with version BEFORE git
  mkdir -p "$w/eider-profiler/cli"
  echo "$LIB" > "$w/eider-profiler/VERSION"
  printf '[package]\nname = "profiler"\nversion = "%s"\neider = "%s"\n\n[deps.json]\nversion = "%s"\ngit = "https://github.com/klxdev/eider-json.git"\n\n[deps.local]\npath = "../x"\nversion = "9.9.9"\n' "$LIB" "$OLDS" "$LIB" > "$w/eider-profiler/eider.toml"
  printf '[package]\nname = "cli"\nversion = "%s"\neider = "%s"\n' "$LIB" "$OLDS" > "$w/eider-profiler/cli/eider.toml"
  # the shopping example: no root manifest; its packages' own versions are theirs
  mkdir -p "$w/eider-example-shopping-service/server"
  echo "$LIB" > "$w/eider-example-shopping-service/VERSION"
  printf '[package]\nname = "server"\nversion = "0.1.0"\neider = "%s"\n\n[deps.http]\ngit = "https://github.com/klxdev/eider-http.git"\nversion = "%s"\n' "$OLDS" "$LIB" > "$w/eider-example-shopping-service/server/eider.toml"
  printf 'version = 1\n' > "$w/eider-example-shopping-service/server/eider.lock"
}
bump() { # ws args...: run the copy's script against the fakes
  w=$1; shift
  (cd "$w/eider-lang" && EIDER_SIBLINGS=$w sh scripts/version.sh "$@" 2>&1)
}

W=$T/a; mkws "$W"
# the copy has the old series text in the places a release prep used to edit by hand
L=$W/eider-lang
has "copy has the goldens" "$L/compiler/tests/doc/geo.json" "\"toolchain\":\"$OLD\""
has "copy has the series text" "$L/compiler/tests/pkgs/series/main.out" "this toolchain is $OLDS"
out=$(bump "$W" bump minor); rc=$?
check "minor bump exits 0" 0 $rc
[ $rc = 0 ] || printf '%s\n' "$out" | head -20

check "VERSION" "$NEW" "$(cat "$L/VERSION")"
has "core/version.ei" "$L/core/version.ei" "pub const VERSION: str = \"$NEW\""
has "core/version.ei series" "$L/core/version.ei" "pub const SERIES: str = \"$NEWS\""
has "manifest series" "$L/std/eider.toml" "eider = \"$NEWS\""
has "doc golden toolchain" "$L/compiler/tests/doc/geo.json" "\"toolchain\":\"$NEW\""
lacks "doc golden has no old toolchain" "$L/compiler/tests/doc/geo.json" "\"toolchain\":\"$OLD\""
has "oracle series text" "$L/compiler/tests/pkgs/series/main.out" "this toolchain is $NEWS"
has "oracle help text" "$L/compiler/tests/pkgs/series/main.out" "port it to $NEWS and set \`eider = \"$NEWS\"\`"
has "quoted eider = in a script" "$L/tests/pkg/run.sh" "eider = \\\"$NEWS\\\""
has "releases page output block" "$L/docs/site/tooling/releases.md" "$NEW"
awk -v v="$NEW" -v s="$NEWS" 'prev == v && $0 == s { f = 1 } { prev = $0 } END { exit !f }' "$L/docs/site/tooling/releases.md" && ok || no "releases page prints VERSION then SERIES"
has "toolchain install text" "$L/docs/site/tooling/eider.md" "eider toolchain install $NEWS"
has "eider add --version (docs)" "$L/docs/site/tooling/eider.md" "--version $NEW"
lacks "the changelog is history" "$L/CHANGELOG.md" "## $NEW"
has "decisions are history" "$L/docs/decisions.md" "| C874 |"

has "analyzer session golden" "$W/eider-analyzer/tests/sessions/a.out" "\"name\":\"eider-analyzer\",\"version\":\"$NEW\""
check "json VERSION" "$NEW" "$(cat "$W/eider-json/VERSION")"
has "json own version (no version.sh)" "$W/eider-json/eider.toml" "version = \"$NEW\""
has "json eider series" "$W/eider-json/eider.toml" "eider = \"$NEWS\""
has "json docs: eider add --version" "$W/eider-json/docs/use.md" "klxdev/eider-json.git --version $NEW"
has "json docs: another --version stays" "$W/eider-json/docs/use.md" "some other --version $LIB stays"
has "json changelog is history" "$W/eider-json/CHANGELOG.md" "needs \`eider = \"$OLDS\"\`"
has "http own version (version.sh sync)" "$W/eider-http/eider.toml" "version = \"$NEW\""
has "http pin on json (git first)" "$W/eider-http/eider.toml" "git = \"https://github.com/klxdev/eider-json.git\"
version = \"$NEW\""
check "profiler own version (no version.sh)" "$NEW" "$(sed -n 's/^version = "\(.*\)"$/\1/p' "$W/eider-profiler/eider.toml" | head -1)"
has "profiler's cli package follows" "$W/eider-profiler/cli/eider.toml" "version = \"$NEW\""
has "profiler pin on json (version first)" "$W/eider-profiler/eider.toml" "[deps.json]
version = \"$NEW\""
has "a path dependency's version stays" "$W/eider-profiler/eider.toml" "version = \"9.9.9\""
has "shopping pin on http" "$W/eider-example-shopping-service/server/eider.toml" "version = \"$NEW\""
has "shopping package's own version stays" "$W/eider-example-shopping-service/server/eider.toml" "version = \"0.1.0\""
has "shopping series" "$W/eider-example-shopping-service/server/eider.toml" "eider = \"$NEWS\""

for name in eider-json eider-http eider-example-shopping-service; do
  has "tag command $name" /dev/stdin "git -C $W/$name tag -a v$NEW" <<EOF
$out
EOF
done
printf '%s\n' "$out" | grep -q "git -C $W/eider-profiler tag" && no "release.sh tags the profiler, not version.sh" || ok
printf '%s\n' "$out" | grep -q "scripts/vendor.sh toml" && ok || no "prints the vendor.sh step" "$out"
printf '%s\n' "$out" | grep -q "$W/eider-http\$" && ok || no "prints the re-lock directory" "$out"

# check fails while vendor.lock pins the old series, and passes once it is re-pinned
chk=$(cd "$L" && sh scripts/version.sh check 2>&1); crc=$?
check "check fails on vendor.lock's old series" 1 $crc
printf '%s\n' "$chk" | grep -q 'vendor.lock' && ok || no "check names vendor.lock" "$chk"
sed "s/^version = \"$LIB\"/version = \"$NEW\"/" "$L/vendor.lock" > "$L/vendor.lock.new" && mv "$L/vendor.lock.new" "$L/vendor.lock"
chk=$(cd "$L" && sh scripts/version.sh check 2>&1); crc=$?
check "check passes once vendor.lock is re-pinned" 0 $crc
[ $crc = 0 ] || printf '%s\n' "$chk" | head

# nothing but the scratch workspace changed: the real tree has its VERSION
check "the real tree is untouched" "$OLD" "$(tr -d ' \n' < "$root/VERSION")"

# a patch bump of eider-lang: the version text only, the series text stays
W=$T/b; mkws "$W"; L=$W/eider-lang
PATCHV=$OLDS.$((${OLD##*.} + 1))
LPATCH=$OLDS.$((${LIB##*.} + 1))
out=$(bump "$W" bump patch); rc=$?
check "patch bump exits 0" 0 $rc
check "patch VERSION" "$PATCHV" "$(cat "$L/VERSION")"
has "patch doc golden" "$L/compiler/tests/doc/geo.json" "\"toolchain\":\"$PATCHV\""
has "patch keeps the series text" "$L/compiler/tests/pkgs/series/main.out" "this toolchain is $OLDS"
check "patch leaves a sibling" "$LIB" "$(cat "$W/eider-json/VERSION")"
out=$(bump "$W" bump patch eider-json); rc=$?
check "patch bump of a sibling exits 0" 0 $rc
check "sibling patch VERSION" "$LPATCH" "$(cat "$W/eider-json/VERSION")"
has "sibling patch own version" "$W/eider-json/eider.toml" "version = \"$LPATCH\""
has "sibling patch tag command" /dev/stdin "git -C $W/eider-json tag -a v$LPATCH" <<EOF
$out
EOF
has "a pin is a minimum: not rewritten" "$W/eider-http/eider.toml" "version = \"$LIB\""

# failing loudly: a sibling with no valid VERSION, and one whose own line is not its VERSION
W=$T/c; mkws "$W"
echo "oops" > "$W/eider-json/VERSION"
out=$(bump "$W" bump minor); rc=$?
check "a bad sibling VERSION fails" 1 $rc
printf '%s\n' "$out" | grep -q 'FAIL eider-json' && ok || no "names eider-json" "$out"
W=$T/d; mkws "$W"
sed "0,/^version = .*/s//version = \"0.0.1\"/" "$W/eider-profiler/eider.toml" > "$W/p.tmp" && mv "$W/p.tmp" "$W/eider-profiler/eider.toml"
out=$(bump "$W" bump minor); rc=$?
check "an own version line that is not VERSION fails" 1 $rc
printf '%s\n' "$out" | grep -q 'FAIL eider-profiler' && ok || no "names eider-profiler" "$out"

if [ $fail = 0 ]; then echo "ok   version bump ($n checks, against a copy and fake siblings)"; else exit 1; fi
