#!/bin/sh
# PostgreSQL for the verify VM, from hatchd (docs: README.md "PostgreSQL"). The verify VM cannot call hatchd, so the servers are
# started here, on the host, before it, with the real eider-postgres scripts/pg-up.sh through podman-hatchd, and the VM reaches
# them with podman-forward (its `podman`).
#   sh scripts/release-env/pg-hatchd.sh up <workspace>     the plain server (10.89.3.10) and the TLS one (10.89.3.11) of PostgreSQL 17
#   sh scripts/release-env/pg-hatchd.sh down
# <workspace> holds the clones (eider-postgres/, eider-tls/ ...): the TLS certificates go to <workspace>/eider-postgres/target/pg/pki,
# which the VM sees when it is given the workspace.
here=$(cd "$(dirname "$0")" && pwd -P)
shimdir=$(mktemp -d); trap 'rm -rf "$shimdir"' EXIT
ln -s "$here/podman-hatchd" "$shimdir/podman"
export PATH="$shimdir:$PATH"
case "$1" in
  up)
    ws=$(cd "$2" && pwd -P) || exit 1
    sh "$ws/eider-postgres/scripts/pg-up.sh" || exit $?
    EIDER_PG_NAME=eider-pg-tls sh "$ws/eider-postgres/scripts/pg-up.sh" --tls || exit $?
    # the certificates the TLS server uses: the VM's podman-forward puts them back after its own pg-up.sh --tls regenerates them
    rm -rf "$ws/.pg-pki"; mkdir -p "$ws/.pg-pki" && cp -a "$ws/eider-postgres/target/pg/pki/." "$ws/.pg-pki/" ;;
  down)
    hatchd rm -f eider-pg-test eider-pg-tls >/dev/null 2>&1 ;;
  *) echo "usage: pg-hatchd.sh up <workspace> | down" >&2; exit 2 ;;
esac
