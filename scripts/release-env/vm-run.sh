#!/bin/sh
# Run a command in the Eider verify/release environment as a hatchd Firecracker VM (docs: README.md).
#
#   sh scripts/release-env/vm-run.sh <workspace> <command...>
#
# <workspace> is a directory holding clean clones: eider-lang/ (the command runs there) and, for the verify legs that build the
# libraries, its siblings next to it (see README.md). It is copied onto the VM's disk (a clean clone: a host-built target/ with
# a newer glibc must not be reused). The command runs as an unprivileged user with the settings in vm-job.sh. Needs the image
# `eider-release` (hatchd image build scripts/release-env/eider-release.yaml --name eider-release).
#   VM_CPUS=8 VM_MEM=16384 VM_DISK=40G   resources (defaults)
#   WITH_PG=1    first start PostgreSQL 17 (plain and TLS) as hatchd VMs (pg-hatchd.sh), put this VM on their network and forward
#                127.0.0.1:55432 to them, so eider-postgres's tests run: the real scripts/pg-up.sh works unchanged
#   VM_ID=name   the VM's id (default evm-<pid>)
#   VM_COLLECT="seed/eiderc.wasm target/x"   files (paths relative to eider-lang/) copied back to <workspace>/.vm-out/ when the command ends
#   VM_RELEASE=1   for publish.sh --dry-run: zig (read-only) and the release key go to the VM. The key is copied into the VM's RAM (/dev/shm,
#                  readable by the job's user only) and removed when the job ends; it is never written to the VM's disk
#   VM_IMAGE=name   another image than eider-release (to try a new recipe)
# Examples:
#   sh scripts/release-env/vm-run.sh /tmp/ws sh scripts/proofs.sh
#   WITH_PG=1 sh scripts/release-env/vm-run.sh /tmp/ws env VERIFY_JOBS=4 sh scripts/verify.sh
here=$(cd "$(dirname "$0")" && pwd -P)
[ $# -ge 2 ] || { sed -n 2,23p "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ws=$(cd "$1" && pwd -P) || exit 2; shift
command -v hatchd >/dev/null 2>&1 || { echo "vm-run: no hatchd on the PATH (podman fallback: README.md)" >&2; exit 3; }
hatchd image list 2>/dev/null | awk '{print $1}' | grep -qx "${VM_IMAGE:-eider-release}" || { echo "vm-run: no hatchd image eider-release (hatchd image build $here/eider-release.yaml --name eider-release)" >&2; exit 3; }
net=; pre=; out=; rel=
mkdir -p "$ws/.vm-out"
if [ -n "$WITH_PG" ]; then
  sh "$here/pg-hatchd.sh" up "$ws" || { echo "vm-run: cannot start PostgreSQL" >&2; exit 3; }
  net="--network eiderpg:10.89.3.20"; pre="env EIDER_PG_FORWARD=1"
  trap 'sh "$here/pg-hatchd.sh" down' EXIT
fi
if [ -n "$VM_RELEASE" ]; then
  zdir=$(mise where zig 2>/dev/null); [ -x "$zdir/zig" ] || { echo "vm-run: VM_RELEASE needs zig (mise where zig)" >&2; exit 3; }
  kdir=${EIDER_RELEASE_KEY:+$(dirname "$EIDER_RELEASE_KEY")}; kdir=${kdir:-${XDG_CONFIG_HOME:-$HOME/.config}/eider}
  [ -f "$kdir/release.key" ] || { echo "vm-run: no release key at $kdir/release.key" >&2; exit 3; }
  rel="--bind $zdir:/zig:ro --bind $kdir:/k:ro"; pre="$pre env VM_RELEASE=1"
fi
id=${VM_ID:-evm-$$}
# shellcheck disable=SC2086
hatchd run "$id" --image "${VM_IMAGE:-eider-release}" --vcpus "${VM_CPUS:-8}" --mem "${VM_MEM:-16384}" --disk "${VM_DISK:-40G}" $net --bind "$ws:/w:ro" --bind "$ws/.vm-out:/out" --bind "$here:/je:ro" $rel --rm \
  -- env VM_COLLECT="$VM_COLLECT" $pre sh /je/vm-job.sh "$@"
