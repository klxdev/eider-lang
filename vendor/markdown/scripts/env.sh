# Sourced by scripts/build.sh and scripts/test.sh (with `here` set to this repository): the
# Eider toolchain, the version check, and the local overrides of the git dependencies.
#
# The toolchain is the eider-lang checkout $EIDER_ROOT (else $EIDER_LANG; default
# ../eider-lang next to this repository). Its VERSION must have the MAJOR.MINOR that
# eider.toml's `eider` names, which is this package's own MAJOR.MINOR (VERSION): before 1.0 a
# MINOR may break compatibility, so each library release goes with one toolchain series
# (CHANGELOG.md). Anything else exits 2 with the reason.
#
# Dependencies are git packages (eider.toml). To work offline, against checkouts of them that
# may have uncommitted edits, eider-pkg takes a dependency from a local directory instead of
# its repository when EIDER_PKG_OVERRIDE names it (`name=dir`, comma separated; eider-lang's
# docs/site/tooling/eider-pkg.md). This sets it for each of DEPS (every git package in the
# graph, transitive ones included) that it doesn't name yet: EIDER_<NAME> when set (e.g.
# EIDER_JSON), else the sibling checkout ../eider-<name> when there is one, else the
# toolchain's vendored copy (eider-lang's vendor/<name>, a pinned release) when it has one.
# A dependency with none of these is fetched from its repository (network).
# DEPS: the git packages in this repository's dependency graph (transitive ones included).
DEPS=""

die() { echo "$(basename "$0"): $*" >&2; exit 2; }
toolchain=$(cd "${EIDER_ROOT:-${EIDER_LANG:-$here/../eider-lang}}" 2>/dev/null && pwd -P) || die "set EIDER_ROOT to the eider-lang checkout (no directory ${EIDER_ROOT:-${EIDER_LANG:-$here/../eider-lang}})"
[ -x "$toolchain/scripts/ei" ] || die "$toolchain is not an eider-lang checkout (no scripts/ei); set EIDER_ROOT"
toml_value() { sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" "$here/eider.toml" | head -1; }
pkg_name=$(toml_value name)
mine=$(tr -d ' \n' < "$here/VERSION")
series=$(toml_value eider)
[ "$(toml_value version)" = "$mine" ] || die "VERSION is $mine but eider.toml's version is $(toml_value version)"
[ "${mine%.*}" = "$series" ] || die "VERSION is $mine but eider.toml says eider = \"$series\" (they share MAJOR.MINOR)"
theirs=
[ -f "$toolchain/VERSION" ] && theirs=$(tr -d ' \n' < "$toolchain/VERSION")
[ -n "$theirs" ] || die "the toolchain at $toolchain has no VERSION (it is older than Eider 0.1.0); eider-$pkg_name $mine needs Eider $series.x"
[ "${theirs%.*}" = "$series" ] || die "eider-$pkg_name $mine needs an Eider $series.x toolchain, but $toolchain is Eider $theirs; use the eider-$pkg_name release made for Eider ${theirs%.*} (CHANGELOG.md) or a matching eider-lang"
EIDER_ROOT=$toolchain
export EIDER_ROOT

for d in $DEPS; do
  case ",$EIDER_PKG_OVERRIDE," in *",$d="*) continue ;; esac
  var=EIDER_$(echo "$d" | tr 'a-z' 'A-Z')
  eval "dir=\${$var:-}"
  if [ -z "$dir" ] && [ -f "$here/../eider-$d/eider.toml" ]; then dir=$here/../eider-$d; fi
  if [ -z "$dir" ] && [ -f "$toolchain/vendor/$d/eider.toml" ]; then dir=$toolchain/vendor/$d; fi
  if [ -n "$dir" ]; then
    dir=$(cd "$dir" && pwd -P) || die "$var: no directory $dir"
    EIDER_PKG_OVERRIDE="${EIDER_PKG_OVERRIDE:+$EIDER_PKG_OVERRIDE,}$d=$dir"
  fi
done
export EIDER_PKG_OVERRIDE

ei=$toolchain/scripts/ei
eider_pkg=$toolchain/scripts/eider-pkg
