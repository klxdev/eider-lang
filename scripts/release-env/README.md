# The Eider verify and release environment

`scripts/verify.sh` runs every sanitizer, several clang versions, the debuggers, the Lean proofs, CBMC and the Postgres tests; a
release (`scripts/publish.sh`) refuses to run unless every leg runs. That needs a toolchain whose ThreadSanitizer works.
**Fedora 45's glibc breaks TSan's `longjmp`** (`ThreadSanitizer: can't find longjmp buf`; a six-line C program reproduces it),
so on Fedora 45 the TSan legs skip. Fedora 44 works. This directory is that environment, as one package list
(`packages.txt`) shared by three things, with no Dockerfile at the repository root (it would be a fourth copy to keep in step):

| File | What |
|---|---|
| `packages.txt` | the dnf packages (clang 22, the sanitizers, gdb, lldb, CBMC, a musl sysroot, node, git, gh, minisign ...) |
| `eider-release.yaml` | the hatchd image recipe (preferred): `hatchd image build scripts/release-env/eider-release.yaml --name eider-release` |
| `Containerfile` | the same for podman or docker: `podman build -t eider-release:44 -f scripts/release-env/Containerfile scripts/release-env` |
| `vm-run.sh`, `vm-job.sh` | run a command in a hatchd VM from that image (below) |
| `pg-hatchd.sh`, `podman-hatchd`, `podman-forward`, `tcp-forward.py` | PostgreSQL 17 as hatchd VMs for the database tests (below) |
| `check-sync.sh` | fails if the two recipes stop sharing `packages.txt` or pin different Lean versions |

Lean 4.36.0 (`/opt/lean`, hash-checked) and CBMC are in the image; so is everything `verify.sh` calls.

## For agents: run a command in the environment

```sh
W=/tmp/ws; mkdir -p $W
for r in eider-lang eider-analyzer tree-sitter-eider eider-profiler eider-toml eider-json eider-markdown eider-logging \
         eider-command eider-http eider-rpc eider-openapi eider-compression eider-tls eider-postgres eider-sql \
         eider-example-shopping-service; do git clone --branch main ../$r $W/$r; done      # clean clones: no host-built target/
cp -r target/crypto/awslc-src $W/eider-lang/target/crypto/ 2>/dev/null   # sh scripts/fetch-awslc.sh first (hash-checked)
cp -r ../tree-sitter-eider/node_modules ../tree-sitter-eider/parser.so $W/tree-sitter-eider/

sh scripts/release-env/vm-run.sh $W sh scripts/proofs.sh                       # one thing
WITH_PG=1 sh scripts/release-env/vm-run.sh $W env VERIFY_JOBS=4 sh scripts/verify.sh   # the full matrix, with PostgreSQL
```

`vm-run.sh` copies the workspace onto the VM's disk, runs the command in `eider-lang/` as an unprivileged user and prints
`vm-job: exit <n>`. What `vm-job.sh` sets that a bare VM lacks (each one found by a failing run): `vm.max_map_count=1048576` (the
default makes the core `task (tsan)` tests fail with ENOMEM), the loopback interface up (the server tests connect to 127.0.0.1),
`ulimit -n 1048576` (1024 descriptors are too few) kept with `setpriv` (`runuser` resets it), and a copy of the workspace on the VM's
own disk (a 9P bind is root-owned and read-only). A build step cannot start Lean in the image build VM (too little memory), so the
recipe does not check it; `vm-run.sh $W lean --version` does. Run long jobs in the background and read their log; never remove a VM
you did not start (`hatchd list`).

## PostgreSQL

The verify VM cannot call hatchd and cannot reach the host's loopback, so `WITH_PG=1` starts the servers on the host first:
`pg-hatchd.sh up <workspace>` runs eider-postgres's real `scripts/pg-up.sh` (plain, then `--tls`) through `podman-hatchd`, a `podman`
that translates `run -d`, `exec`, `logs`, `rm -f`, `pull` and `image exists` to hatchd, so the two servers are hatchd VMs at fixed
addresses on the network `eiderpg` (10.89.3.10 plain, 10.89.3.11 TLS), with their roles and `pg_hba.conf` made by the unchanged script.
The verify VM joins that network, and inside it `podman-forward` stands in for `podman`: starting a server forwards
`127.0.0.1:55432` to the right address (`tcp-forward.py`), and the role setup is skipped because the host did it. `vm-run.sh` stops
the servers when it ends (`pg-hatchd.sh down`).

## By hand with hatchd (what vm-run.sh does)

`eider-release.yaml` is the same environment as a hatchd image (Fedora 44, Lean 4.36.0, CBMC, a TSan-capable clang). Build it
once, then run any job in a Firecracker VM with the repository bound in:

```sh
hatchd image build scripts/release-env/eider-release.yaml --name eider-release   # about 3 minutes; needs the fedora-44 image (hatchd image pull docker.io/library/fedora:44 --name fedora-44)

W=/tmp/ws; mkdir -p $W; git clone . $W/eider-lang      # a clean clone: no host-built target/ with a newer glibc
hatchd run job1 --image eider-release --vcpus 4 --mem 12288 --bind $W:/w --rm -- sh -c '
  cd /w/eider-lang && export HOME=/w/home && mkdir -p $HOME &&
  sh scripts/proofs.sh && sh tests/cbmc/run.sh &&
  VERIFY_JOBS=3 VERIFY_ONLY="tsan asan gcc" sh scripts/verify.sh'
```

Verified 2026-11-25: the proofs (115 theorems), the CBMC suite and the tsan, asan and gcc run-test legs run this way in about
two minutes. Notes: the image build VM has too little memory to start Lean, so the recipe does not run `lean --version`
(check it in a normal job); a download goes to `/var/tmp` (disk), not `/tmp` (memory); a bind is 9P, so keep `target/`
trees on a path you can delete. The full `scripts/verify.sh` (every leg) and `scripts/publish.sh` need the sibling
repositories next to the clone and the podman API for the Postgres legs, as in the recipe below; not yet tried under hatchd.

## Running a job with podman (fallback)

```sh
podman build -t eider-release:44 scripts/release-env

# clean clones of eider-lang and its siblings (the clone has no host-built target/ with a newer glibc)
W=/tmp/relws; mkdir -p $W
for r in eider-lang eider-analyzer tree-sitter-eider eider-profiler eider-toml eider-json eider-markdown \
         eider-logging eider-command eider-http eider-rpc eider-openapi eider-compression eider-tls \
         eider-postgres eider-sql eider-example-shopping-service; do git clone ../$r $W/$r; done
cp -r target/crypto/awslc-src $W/eider-lang/target/crypto/   # sh scripts/fetch-awslc.sh first: hash-checked sources
cp -r ../tree-sitter-eider/node_modules ../tree-sitter-eider/parser.so $W/tree-sitter-eider/

# the Postgres legs start servers through podman: give the container the host's podman API (host network)
podman system service --time=0 unix://$W/podman.sock &

podman run --rm --network=host --userns=keep-id --user $(id -u):$(id -g) \
  --security-opt label=disable --security-opt seccomp=unconfined --cap-add=SYS_PTRACE \
  -e HOME=$W/home -e VERIFY_JOBS=4 -e CONTAINER_HOST=unix://$W/podman.sock \
  -e EIDER_RELEASE_KEY=/key/release.key -e ZIG=/zig/zig -e EIDER_CLANG_FETCH=1 -e EIDER_SYSROOT=/opt/musl-sysroot \
  -v $W:$W -v ~/.config/eider:/key:ro -v "$(mise where zig)":/zig:ro -w $W/eider-lang \
  eider-release:44 sh scripts/publish.sh X.Y.Z --dry-run
```

Notes: seccomp and ptrace are for lldb (the default profile blocks its `personality` call); `--network=host` and the
podman socket are for the Postgres tests; `VERIFY_JOBS=4` keeps load low enough that timing-sensitive tests do not
flake; the key is mounted read-only and never copied into the image. A seed regenerated in this image is built by
clang 22.1.8 (Fedora 44), which is what `seed/eiderc.wasm.clang` should say for the byte-for-byte check to run.
Commit what the clone produced to the real repositories, then tag and publish from there (the dry-run prints the
commands).
