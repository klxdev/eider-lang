# A build environment for verifying and releasing Eider

`scripts/verify.sh` runs every sanitizer, several clang versions, the debuggers and the Postgres tests; a release
(`scripts/publish.sh`) refuses to run unless every leg runs. That needs a toolchain whose ThreadSanitizer works.
**Fedora 45's glibc breaks TSan's `longjmp`** (`ThreadSanitizer: can't find longjmp buf`; a six-line C program
reproduces it), so on Fedora 45 the TSan legs are skipped (and a release is refused). Fedora 44, which made 0.7.6,
works. `Containerfile` is that environment, with everything the matrix and the release need (including Lean 4 for the
proofs, `scripts/proofs.sh`). It is kept in the repository so the same environment can be rebuilt for testing and releasing.

## Running a job with hatchd (the preferred way; podman below is the fallback)

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
