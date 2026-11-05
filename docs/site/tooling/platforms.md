# Native platform builds

The build targets are Linux x86-64, Linux AArch64, and macOS Apple Silicon
(`darwin-aarch64`). Intel macOS and Windows release artifacts are not provided.

On macOS, install the command-line developer tools, then LLVM and the WebAssembly linker:

```sh
xcode-select --install
brew install llvm lld
export PATH="$(brew --prefix llvm)/bin:$(brew --prefix lld)/bin:$PATH"
scripts/ei run examples/fib.ei
sh scripts/check-platform.sh
```

The bootstrap and LLVM backend use the platform C symbol convention. The ThinLTO probe
checks the actual ELF linker options used for a release build; a Mach-O linker that rejects
those options falls back to normal optimized objects automatically. No
`EIDER_LLVM_LTO=0` setting is required on macOS.

The optional OpenSSL backend accepts `libcrypto.dylib` and pkg-config library directories.
For Homebrew OpenSSL, set `EIDER_OPENSSL_INCLUDE=$(brew --prefix openssl@3)/include` and
`EIDER_OPENSSL_LIB=$(brew --prefix openssl@3)/lib`. Release binaries use bundled AWS-LC
instead, and packaging refuses a dependency on a Homebrew or build-directory library.

## CI and verification limits

`Native platforms` runs bootstrap, the compile-fail/pass suite, language run tests,
WebAssembly tests and optimized native compilation on Linux x86-64, Linux AArch64 and
macOS arm64. Linux also runs the complete C runtime and standard-library suites.

The macOS standard-library gate explicitly reports the existing `signal` failure as skipped. The full C runtime suite also has Linux-specific errno,
`/proc`, profiler and task-dump expectations. These are follow-up work: a successful
platform gate is **not** the full `scripts/verify.sh` result, and does not grant a release's
`verified = true`. The existing release verification requirement remains in force.

`macOS release candidate` is a manual workflow. It requires an `EIDER_READ_TOKEN` secret
with read access to the private klxdev library and shopping-service repositories. It builds
and runs an unpacked macOS toolchain, runs the signed-installer/tamper tests, then builds
and tests the shopping service, including its Chromium purchase flow. It uploads an
unsigned release candidate only after those steps succeed; no release signing key is
needed in CI.

## Packaging and signing

Build an Apple Silicon artifact on an Apple Silicon Mac, from a committed checkout:

```sh
brew install gnu-tar coreutils openssl@3
export PATH="$(brew --prefix openssl@3)/bin:$PATH"
sh scripts/package-native.sh
```

The output is `target/release/assets/v<VERSION>/eider-<VERSION>-darwin-aarch64` and the
matching `.tar.gz`. The archive includes the commit and records successful native smoke
tests. Signing remains a separate publishing step.

A Linux publisher can download the macOS workflow artifact for the **same commit** and
include it with its Linux artifacts:

```sh
sh scripts/publish.sh <VERSION> --dry-run \
  --targets "linux-x86_64 linux-aarch64 darwin-aarch64" \
  --native-assets /path/to/downloaded/macos-artifacts
```

The publisher checks the archive's version, target, commit, binary format and standalone
`eider` against the archived copy. It then generates one combined `SHA256SUMS`, signs it
with the existing release key and runs the install smoke test before publishing. Remove
`--dry-run` only when the existing full verification gate passes. `install.sh` and
`eider toolchain install` select `darwin-aarch64` automatically on Apple Silicon; the
installer accepts either `sha256sum` or macOS's `shasum`.
