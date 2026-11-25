#!/bin/sh
# The part of vm-run.sh that runs INSIDE the hatchd VM, as root: the settings a verify or test run needs that a bare VM lacks,
# then the command as an unprivileged user in a copy of the workspace on the VM's own disk. Not meant to be run by hand.
#   vm-job.sh <command...>     (the command runs in /work/eider-lang)
sysctl -w vm.max_map_count=1048576 >/dev/null   # the default 65530 makes the core `task (tsan)` tests fail with ENOMEM
ip link set lo up                               # a bare VM has no loopback: the server tests cannot connect to themselves
ulimit -n 1048576                               # the default 1024 is too few descriptors for the server tests
id tester >/dev/null 2>&1 || useradd -m tester
# the host's workspace is a read-only 9P mount, root-owned: an unprivileged user (some tests need one) works on a copy
mkdir -p /work && cp -a /w/. /work/ && chown -R tester:tester /work
extra=
if [ -n "$EIDER_PG_FORWARD" ]; then # PostgreSQL servers started on the host by pg-hatchd.sh: a `podman` that forwards to them
  mkdir -p /usr/local/libexec/podman-shim
  cp /work/eider-lang/scripts/release-env/podman-forward /usr/local/libexec/podman-shim/podman
  cp /work/eider-lang/scripts/release-env/tcp-forward.py /usr/local/libexec/podman-shim/
  extra="PATH=/usr/local/libexec/podman-shim:$PATH"
fi
cd /work/eider-lang || exit 1
# build the crypto backend once, before any leg: the first use prints a "compiled in N s" line that fails tests comparing output
if [ -d target/crypto/awslc-src ]; then
  setpriv --reuid=tester --regid=tester --init-groups env HOME=/home/tester sh scripts/crypto-build.sh awslc >/dev/null 2>&1 || true
fi
# setpriv, not runuser: runuser's PAM resets the descriptor limit raised above
# EIDER_SYSROOT: the image's musl sysroot (the cross leg); EIDER_CLANG_FETCH: download the other clang versions of the llvms leg
# (17, 20, 23), which a release needs (a skipped leg stops release.sh)
setpriv --reuid=tester --regid=tester --init-groups env HOME=/home/tester EIDER_SYSROOT=/opt/musl-sysroot EIDER_CLANG_FETCH=1 $extra "$@"
rc=$?
# files the caller asked for go back to the host through the writable bind (root writes it)
for f in $VM_COLLECT; do mkdir -p "/out/$(dirname "$f")" && cp -a "/work/eider-lang/$f" "/out/$f" || echo "vm-job: cannot collect $f"; done
echo "vm-job: exit $rc"
exit $rc
