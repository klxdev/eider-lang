# core/crypto: cryptography through an OpenSSL-compatible libcrypto

Eider never implements cryptographic primitives. It calls a vetted library through one narrow
C file, `eider_crypto.c`, written once against the OpenSSL libcrypto API. Any library that
implements the subset of that API listed below is a backend, chosen when the program is
linked:

| Backend | Where it comes from | Status here (x86-64 Fedora 44) |
|---|---|---|
| **AWS-LC** (`awslc`, default) | v5.12.0, pinned and hash-checked, fetched by `scripts/fetch-awslc.sh` into `target/crypto/awslc-src`, compiled with `$CC` only (no CMake, Go or Perl) | tested: all vectors, cross checks, ASan+UBSan |
| AWS-LC without assembly (`awslc-noasm`) | the same sources with `OPENSSL_NO_ASM` (the portable build every other platform gets) | tested |
| AWS-LC, EVP_AEAD path (`awslc-aead`) | the glue's BoringSSL path for ChaCha20-Poly1305, run on AWS-LC | tested |
| **OpenSSL 3** (`openssl`) | the system's libcrypto, linked dynamically; headers from pkg-config, `$EIDER_OPENSSL_INCLUDE`, or `scripts/crypto-build.sh fetch-openssl-headers` | tested against the installed 3.5.8 (headers of 3.5.9 from Fedora's openssl-devel, fetched with `dnf download`, since openssl-devel isn't installed) |
| LibreSSL (`libressl`) | 4.4.0, pinned, fetched and built into `target/` by `scripts/crypto-build.sh libressl` (its configure + make) | tested |
| BoringSSL | not built by the scripts | the glue supports it (`OPENSSL_IS_BORINGSSL`: no SHA-3, ChaCha20-Poly1305 through EVP_AEAD, BLAKE2b-256); the EVP_AEAD branch is exercised by `awslc-aead`, the rest is the same code as AWS-LC's; not compiled against BoringSSL itself. BoringSSL is not the default because Google states it has no API/ABI stability guarantees and isn't meant for general use; AWS-LC is its maintained, versioned, FIPS-capable fork (and the rustls default) |

The rustls model (docs/research/rust.md, section 3): protocols (TLS 1.3, X.509) are written in
Eider, where they are memory-safe; only the primitives are unmanaged code, and they come from a
provider. Here the provider interface is the OpenSSL API itself, so a provider is a library
already deployed and audited elsewhere, and a new one needs no new C.

## Layers

```
packages/crypto/crypto.ei     typed, misuse-resistant API (keys, nonces, Result, constant-time compare)
core/crypto.ei                Eider bindings: one function per ec_crypto_* call, bytes in and out
core/crypto/eider_crypto.h    the crypto ABI (fixed-width, buffer-based; core/ABI.md "Crypto")
core/crypto/eider_crypto.c    the glue: one call sequence into libcrypto per operation
libcrypto                     AWS-LC | OpenSSL 3 | LibreSSL | BoringSSL
```

`core/crypto.ei` is in the `core` package, which holds `ffi` (docs/compiler.md "C8.5"), so
callers outside core need no `ffi`. Capabilities: everything is pure computation and needs
nothing, except what reads the outside world's randomness: `random`, the `*_generate`
functions, `random_nonce`, `p256_sign`, `ec_sign` (random k) and `rsa_pss_sign`, `rsa_pkcs1_sign` (blinding and the PSS salt draw from it) declare `io`, as core/os.ei's OS
randomness does (decision C11).

Why `packages/crypto` and not `std/crypto`: LAYERS.md puts in std only what most programs
need, and a program that imports crypto must link a backend (a 5.7 MB archive by default),
which most programs shouldn't pay for; services will depend on the package explicitly. The
bindings are in core because they are unmanaged code; everything with logic is in the
package.

Why a package *of the toolchain* and not a repository of its own (decision C898): the package is a thin
layer over the bindings in `core/crypto.ei` and the backend `libeider_crypto.a`, which are
versioned with the toolchain (the ABI between them changes in lockstep, `core/ABI.md`), and a
backend is built per target with the toolchain's own release tooling. A repository of its own
would need a second release train and a compatibility matrix between a crypto tag and a
toolchain, for one package that cannot work with another toolchain. So a toolchain ships
`packages/crypto` and the backend built for its target, and a manifest declares it as
`[deps.crypto]` with `toolchain = true` (docs/site/tooling/eider-pkg.md); libraries on it
(eider-tls, eider-postgres, eider-sql) are ordinary git dependencies.

## The ABI

`eider_crypto.h` has the full contract. The core rules hold (core/ABI.md): fixed-width types,
no pointer crosses into Eider, inputs in the core's `in` buffer (several parts concatenated,
every length but the last passed as an argument), results in `out`, status codes `< 0`. Every
operation zeroes `in` before returning and empties `out` on failure; `ec_crypto_wipe` zeroes
both after Eider has copied a result (core/crypto.ei does that after every call). The core
buffers are wiped when they grow, when a thread exits, and by these calls (only the part
written since the last wipe, so it stays cheap).

| Function | `in` | `out` / result |
|---|---|---|
| `ec_crypto_backend()` | | 1 OpenSSL, 2 AWS-LC, 3 BoringSSL, 4 LibreSSL |
| `ec_crypto_provider()` | | name and version text |
| `ec_crypto_supports(alg)` | | 1 if the algorithm works here (it is run once on fixed inputs) |
| `ec_crypto_random(n)` | | n bytes from `RAND_bytes` (n <= 1 MiB) |
| `ec_crypto_hash(alg)` | message | digest |
| `ec_crypto_hmac(hash, key_len)` | key, message | tag |
| `ec_crypto_hkdf_extract(hash, salt_len)` | salt, IKM | PRK |
| `ec_crypto_hkdf_expand(hash, prk_len, len)` | PRK, info | `len` bytes |
| `ec_crypto_aead_seal(alg, key_len, nonce_len, aad_len)` | key, nonce, aad, plaintext | ciphertext ‖ 16-byte tag |
| `ec_crypto_aead_open(...)` | key, nonce, aad, ciphertext ‖ tag | plaintext, or `EAUTH` and nothing |
| `ec_crypto_x25519_public()` / `ec_crypto_x25519()` | private / private, peer | public / shared (`EKEY` if all zero) |
| `ec_crypto_ed25519_public()` / `_sign()` / `_verify()` | seed / seed, msg / public, sig, msg | public / signature / 1 or 0 |
| `ec_crypto_p256_public()` / `_sign()` / `_verify(sig_len)` / `_ecdh()` | d / d, msg / public, DER sig, msg / d, peer | 65-byte point / DER signature / 1 or 0 / 32-byte x |
| `ec_crypto_ec_public(curve)` / `_ec_sign(curve, hash)` / `_ec_verify(curve, hash, sig_len)` / `_ec_ecdh(curve)` | d / d, msg / public, DER sig, msg / d, peer | point (65 or 97 bytes) / DER signature / 1 or 0 / x (32 or 48 bytes); `curve` 1 = P-256, 2 = P-384, `hash` SHA-256, SHA-384 or SHA-512 with either (the `p256_*` calls are these with curve 1 and SHA-256) |
| `ec_crypto_rsa_verify(scheme, hash, salt_len, key_len, sig_len)` | key blob, sig, msg | 1 or 0; `scheme` 1 = PKCS#1 v1.5, 2 = RSASSA-PSS (MGF1 of the same hash, exactly `salt_len` salt bytes) |
| `ec_crypto_rsa_sign(scheme, hash, salt_len, key_len)` | private key DER, msg | signature (modulus length) |
| `ec_crypto_spki_parse()` / `ec_crypto_priv_parse()` | DER SubjectPublicKeyInfo / DER private key (PKCS#8, PKCS#1, SEC1) | kind (1 RSA, 2 P-256, 3 P-384) followed by the RSA key blob or the point / the RSA public blob or the scalar |
| `ec_crypto_ct_equal(len)` | a, b | 1 if equal (`CRYPTO_memcmp`) |
| `ec_crypto_wipe()` | | zeroes and empties `in` and `out` |

Status codes: `EUNSUPPORTED` -5001, `ELENGTH` -5002, `EKEY` -5003, `EAUTH` -5004,
`EBACKEND` -5005 (disjoint from the core's `-errno`). Formats: AEAD nonces are 12 bytes and
tags 16 (the only sizes every backend takes for all three AEADs); P-256 keys are a 32-byte
big-endian scalar and a 65-byte uncompressed point, P-384 the same with 48-byte scalars and 97-byte
points; ECDSA signatures are DER (as TLS and X.509 carry them; packages/crypto converts to and from r ‖ s in
Eider). An RSA public key travels as a blob `n_len (4 bytes, big endian) ‖ n ‖ e`, a private key as its DER.
Ed25519 is pure Ed25519 with the 32-byte seed as the private key. A key the library can't
decode on a verify path is "not valid" (0), never an error, so backends that reject a key at
import and those that reject it at verification answer alike.

## Coverage

| Algorithm | AWS-LC | OpenSSL 3 | LibreSSL | BoringSSL (by the code) |
|---|---|---|---|---|
| SHA-256/384/512, HMAC and HKDF with them | yes | yes | yes | yes |
| SHA3-256/384/512 | yes | yes | yes | no |
| BLAKE2b-256 | yes | no | no | yes |
| BLAKE2b-512 | no | yes | no | no |
| AES-128-GCM, AES-256-GCM | yes | yes | yes | yes |
| ChaCha20-Poly1305 | yes (EVP_CIPHER; `awslc-aead`: EVP_AEAD) | yes | yes | yes (EVP_AEAD) |
| X25519, Ed25519, ECDSA P-256 (SHA-256), ECDH P-256 | yes | yes | yes | yes |
| ECDSA P-384 and P-256 with SHA-256/384/512, ECDH P-384 | yes | yes | yes | yes (by the code) |
| RSA PKCS#1 v1.5 and RSASSA-PSS (SHA-256/384/512) verify and sign, 2048-8192 bits; keys from SPKI, PKCS#8, PKCS#1, SEC1 | yes | yes | yes | yes (by the code) |
| `RAND_bytes`, `CRYPTO_memcmp` | yes | yes | yes | yes |

`ec_crypto_supports` reports this at run time; packages/crypto returns `Err(Unsupported)` for
the gaps, never a fallback.

## The OpenSSL API subset

Every function and macro `eider_crypto.c` uses, so a new backend can be checked against it:

- **Digests:** `EVP_Digest`, `EVP_sha256`, `EVP_sha384`, `EVP_sha512`, `EVP_sha3_256`,
  `EVP_sha3_384`, `EVP_sha3_512` (not BoringSSL), `EVP_blake2b256` (AWS-LC, BoringSSL),
  `EVP_blake2b512` (OpenSSL), `EVP_MD_size`, `EVP_MAX_MD_SIZE`.
- **MAC / KDF:** `HMAC` (the one-shot function, not deprecated in OpenSSL 3; HKDF-Extract
  uses it too, see below); `EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF)`, `EVP_PKEY_derive_init`,
  `EVP_PKEY_CTX_hkdf_mode(EVP_PKEY_HKDEF_MODE_EXPAND_ONLY)`, `EVP_PKEY_CTX_set_hkdf_md`,
  `EVP_PKEY_CTX_set1_hkdf_key`, `EVP_PKEY_CTX_add1_hkdf_info`, `EVP_PKEY_derive` (the
  `EVP_PKEY_HKDF` interface is the one all four share; the `HKDF()` function is
  BoringSSL-family only).
- **AEAD:** `EVP_CIPHER_CTX_new`/`_free`, `EVP_EncryptInit_ex`, `EVP_EncryptUpdate`,
  `EVP_EncryptFinal_ex`, `EVP_DecryptInit_ex`, `EVP_DecryptUpdate`, `EVP_DecryptFinal_ex`,
  `EVP_CIPHER_CTX_ctrl` with `EVP_CTRL_GCM_GET_TAG` / `EVP_CTRL_GCM_SET_TAG` (the same values
  as `EVP_CTRL_AEAD_*`, used for ChaCha20-Poly1305 too), `EVP_aes_128_gcm`,
  `EVP_aes_256_gcm`, `EVP_chacha20_poly1305`. BoringSSL only (`#if`): `EVP_AEAD_CTX_new`,
  `_seal`, `_open`, `_free`, `EVP_aead_chacha20_poly1305`.
- **Keys and signatures:** `EVP_PKEY_new_raw_private_key`, `EVP_PKEY_new_raw_public_key`,
  `EVP_PKEY_get_raw_public_key` (`EVP_PKEY_X25519`, `EVP_PKEY_ED25519`), `EVP_PKEY_CTX_new`,
  `EVP_PKEY_derive_set_peer`, `EVP_PKEY_free`, `EVP_MD_CTX_new`/`_free`,
  `EVP_DigestSignInit`, `EVP_DigestSign`, `EVP_DigestVerifyInit`, `EVP_DigestVerify`.
- **P-256 key import** (the one deprecated corner, `OPENSSL_SUPPRESS_DEPRECATED` for OpenSSL
  3: `EVP_PKEY_fromdata`, its replacement, is OpenSSL-only): `EC_KEY_new_by_curve_name
  (NID_X9_62_prime256v1)`, `EC_KEY_get0_group`, `EC_KEY_set_private_key`,
  `EC_KEY_set_public_key`, `EC_KEY_get0_public_key`, `EC_KEY_check_key`, `EC_KEY_free`,
  `EC_GROUP_get_order`, `EC_POINT_new`, `EC_POINT_mul`, `EC_POINT_oct2point`,
  `EC_POINT_point2oct(POINT_CONVERSION_UNCOMPRESSED)`, `EC_POINT_free`, `EVP_PKEY_new`,
  `EVP_PKEY_set1_EC_KEY`, `EVP_PKEY_get0_EC_KEY`, `BN_bin2bn`, `BN_new`, `BN_is_zero`,
  `BN_cmp`, `BN_free`, `BN_clear_free`.
- **P-384 and the generic curve code:** the same `EC_KEY` functions with `NID_secp384r1`; `EVP_PKEY_base_id`,
  `EC_GROUP_get_curve_name`, `BN_bn2binpad`, `BN_num_bits`, `BN_num_bytes`, `BN_is_odd`.
- **RSA:** `RSA_new`, `RSA_set0_key`, `RSA_get0_key`, `RSA_size`, `RSA_free`, `EVP_PKEY_set1_RSA`,
  `EVP_PKEY_get0_RSA` (the deprecated legacy accessors, as for EC), `EVP_PKEY_CTX_set_rsa_padding`
  (`RSA_PKCS1_PADDING`, `RSA_PKCS1_PSS_PADDING`), `EVP_PKEY_CTX_set_rsa_pss_saltlen`,
  `EVP_PKEY_CTX_set_rsa_mgf1_md`, with `EVP_DigestSignInit`/`EVP_DigestSign` and `EVP_DigestVerifyInit`/
  `EVP_DigestVerify`; keys from DER with `d2i_PUBKEY` (SubjectPublicKeyInfo) and `d2i_AutoPrivateKey`
  (PKCS#8, PKCS#1 and SEC1 in one call).
- **Other:** `RAND_bytes`, `CRYPTO_memcmp`, `OPENSSL_cleanse`, `OpenSSL_version
  (OPENSSL_VERSION)`, `ERR_clear_error`.
- **Family detection:** `OPENSSL_IS_AWSLC`, `OPENSSL_IS_BORINGSSL`, `LIBRESSL_VERSION_NUMBER`,
  `OPENSSL_VERSION_NUMBER >= 0x30000000L`.

Differences found by the tests and absorbed in the glue: `EC_GROUP_get0_order` is missing in
LibreSSL (`EC_GROUP_get_order` is used); `EVP_PKEY_HKDF` extract with an empty IKM succeeds in
OpenSSL 3 and fails in AWS-LC and LibreSSL, so HKDF-Extract is computed as what RFC 5869
defines it to be, `HMAC(salt, IKM)` (an empty salt is HashLen zeros, which HMAC's key padding
makes identical); an all-zero X25519 result is refused by the glue whatever the library does.

## RSA, P-384 and the key policy

Verification and signing are what X.509 chains and TLS servers need; nothing else of RSA is offered
(no encryption or key transport, no key generation: keys come from files and certificates).

- **Schemes:** RSASSA-PKCS1-v1_5 and RSASSA-PSS with SHA-256, SHA-384 or SHA-512; PSS uses MGF1 with the
  same hash and the trailer 0xbc, and the salt length is an argument, exactly: `rsa_pss_verify_tls` and
  `rsa_pss_sign_tls` use the hash length (TLS 1.3 and RFC 4055), the general forms any length up to what
  fits. A PSS signature is no PKCS#1 signature and the other way round; a signature is exactly as long
  as the modulus (the glue checks this itself: the libraries differ on short ones).
- **Key policy (the same on every backend, checked by the glue):** modulus 2048 to 8192 bits and odd;
  public exponent odd, 3 <= e < 2^33, e < n. The hard cap of 8192 bits is what the 2^33 exponent
  bound and the verification cost allow without a denial-of-service lever (verification time is quadratic
  in the size); 3 and 65537 are accepted because certificates in the wild carry them (e = 3 is not unsafe
  for verification); 1024-bit keys are refused on purpose (the NIST CAVP vectors with 1024-bit keys are
  checked to be refused). A key outside the policy is `EKEY` from the key calls and "not valid" from the
  package's verify functions. RSASSA-PSS-typed keys (the `id-RSASSA-PSS` key OID) are not accepted by
  `ec_crypto_spki_parse`; certificates signed with RSASSA-PSS by an `rsaEncryption` key are fine.
- **Side channels:** private-key operations are the library's: RSA blinding is on by default in OpenSSL 3,
  LibreSSL and AWS-LC (and BoringSSL), the CRT result is verified before it is returned (a fault in one
  half does not leak a factor), and ECDSA signing draws k from the library's CSPRNG (`RAND_bytes`; the
  libraries' own constant-time scalar multiplication for P-256 and P-384: AWS-LC's s2n-bignum/fiat code,
  OpenSSL's `ecp_nistz256` / `ecp_nistp`, LibreSSL's generic code with its blinding of the scalar). The
  glue and the package branch only on lengths and public data. The tests do not measure timing.
- **P-384:** `ec_crypto_ec_*` with curve 2; the hash is independent of the curve, so ECDSA with SHA-384 on
  P-256 (`ecdsa_secp256r1_sha384` of X.509) and SHA-256 on P-384 work too.

## Choosing a backend

A backend is a static library, `target/crypto/<backend>/libeider_crypto.a` (the glue plus, for
AWS-LC and LibreSSL, every libcrypto object, so one `-l` is enough). The driver links it by
itself: when a program imports `core/crypto` (so does `packages/crypto`), `eiderc build|run|test`
picks the provider, runs `scripts/crypto-build.sh` (which builds the backend when the archive is
missing or older than the glue, and prints its progress on stderr), appends `-L<dir>` and the
words of the backend.s `libs` file to the cc argv (a shared libcrypto outside the loader.s default
paths also gets an rpath), and puts the SHA-256 of the archive in the program.s cache key, so a
rebuilt backend relinks. A program that does not import it is untouched (no script is run).
Decision C802.

An installed toolchain has no `scripts/`: it ships AWS-LC's portable build for its target,
`lib/crypto/awslc-noasm/libeider_crypto.a` with its `libs` file (decision C898), and the driver
links that when there is no `scripts/crypto-build.sh` next to `core/`. There `awslc` and
`awslc-noasm` name it; `openssl`, `libressl`, `awslc-aead` and the sanitizer build
(`EIDER_CRYPTO_SAN`) need an eider-lang checkout. The archive is built for the release's target
with zig against musl and links into programs built with the host's libc.

```sh
sh scripts/fetch-awslc.sh                  # once: the pinned AWS-LC sources (offline: EIDER_AWSLC_TARBALL=<file>)
scripts/ei run prog.ei                  # builds the backend if needed, links it, runs
EIDER_CRYPTO=openssl scripts/ei build prog.ei
scripts/ei run prog.ei --crypto libressl
scripts/ei-crypto --san run prog.ei       # the sanitizer build of the backend (a wrapper over the above)
```

The backend is `--crypto <name>` (an `eiderc` option), else `$EIDER_CRYPTO`, else `provider` in the `[crypto]` table of
the program's `eider.toml` (`[crypto]` / `provider = "awslc"`), else `awslc`.
`scripts/crypto-build.sh [--san] <backend>` builds one (`--check` says whether it can, exit 2
and the reason if not; `--libdir`, `--libs` print what to link).

**In the driver** (`driver.crypto_libs`): the module graph contains core/crypto.ei; the provider is
chosen as above (the `[crypto]` table of the nearest `eider.toml` above the entry file); the build
is the script.s (`--libdir`, `--libs`; `EIDER_CRYPTO_SAN=1` adds `--san`); `-L`, the library names
and an `@eider-crypto:<sha256 of the archive>` entry (key only) join the `-l` list. A backend that
is not available here (`crypto-build.sh --check` says why) ends the build with exit 3.

## AWS-LC: the default

**Provenance** (core/crypto/awslc/PIN): github.com/aws/aws-lc tag `v5.12.0` (2026-10-23),
commit `cd481c207e38f06aeb5766f4a1cdfce10a4c0af8`, release tarball
`https://github.com/aws/aws-lc/archive/refs/tags/v5.12.0.tar.gz`, SHA-256
`52c7f98ffd296d267cc015ad4653d1ffae399db65b14421da4f5f7efc44becd2`; the commit is checked
against the archive's pax header. The source lists come from aws-lc-sys 0.47.0 (aws-lc-rs
v1.19.0), whose CMake-free "cc builder" builds exactly this commit:
`https://static.crates.io/crates/aws-lc-sys/aws-lc-sys-0.47.0.crate`, SHA-256
`8bfbe32ac36b3c428696ce315464181bc4029d689fd58e3f2a4e58c252242f52`.

**Fetched, not vendored.** The files a build reads (found by preprocessing every listed source
for x86-64 with assembly, portable, and aarch64) are 901 files, 23.3 MB (`files.sha256` lists
each with its hash; about 3 MB compressed). They are not committed: 23 MB and 900 files of
third-party code would dominate the repository's history and every merge, while the pin plus
per-file hashes give the same reproducibility. `scripts/fetch-awslc.sh` downloads the release
once (~150 MB, cached in `target/crypto/fetch/`), checks it, and extracts exactly those files,
each hash-checked; `EIDER_AWSLC_TARBALL=<file>` builds offline from a saved tarball. A plain
checkout therefore needs only `cc`: without the fetched sources the crypto legs of verify.sh
print `skip` with the reason. `scripts/fetch-awslc.sh --repin` moves to a new release
(recomputes the lists and hashes from the release and the matching aws-lc-sys, then rebuilds
and re-runs the vectors).

**Build with plain cc** (scripts/crypto-build.sh, flags in core/crypto/awslc/cflags.sh, as
aws-lc-sys's cc builder sets them for a default, non-FIPS, unprefixed build:
`-D_XOPEN_SOURCE=700 -DDISABLE_CPU_JITTER_ENTROPY=1 -DAWS_LC_STDALIGN_AVAILABLE=1`, the
`__builtin_bswap` and `<linux/random.h>` probes, `-DS2N_BN_HIDE_SYMBOLS=1` for s2n-bignum,
`-Wa,--noexecstack` for assembly): 387 files (250 portable C, 137 x86-64 assembly), no CMake,
Go or Perl, no warnings. Time on this machine (Ryzen 7 PRO 6850U, gcc 15, -O2): **11-12 s with
16 parallel jobs, 34 s with one** (`EIDER_CRYPTO_JOBS=1`). `libcrypto.a` is 5.7 MB (text
3.47 MB, data 73 KB, bss 50 KB). Linked statically, a program takes the members it reaches:
tests/crypto/rfc.ei builds to 3.1 MB with AWS-LC (150 KB against the shared system OpenSSL).
Rebuilt only when the sources, flags or compiler change.

**Assembly on x86-64 Linux** (`sources/linux_x86_64.txt`, AWS-LC's pre-generated perlasm in
`generated-src/linux-x86_64/` and the formally verified s2n-bignum): AES-NI, VAES/AVX-512 and
AVX2 AES-GCM (`aesni-gcm-x86_64.S`, `aesni-gcm-avx512.S`, `aesni-x86_64.S`, `vpaes-x86_64.S`,
`ghash-x86_64.S`, `ghash-ssse3-x86_64.S`, `aesni-xts-avx512.S`, `aes128gcmsiv-x86_64.S`),
ChaCha20 and ChaCha20-Poly1305 (`chacha-x86_64.S`, `chacha20_poly1305_x86_64.S`), SHA-1/256/512
with SHA-NI/AVX2 (`sha*-x86_64.S`, `aesni-sha*-x86_64.S`), P-256 (`p256-x86_64-asm.S`,
`p256_beeu-x86_64-asm.S`, s2n-bignum `p256_montjscalarmul`), X25519/Ed25519 (s2n-bignum
`curve25519_x25519*`, `edwards25519_*`), P-384/P-521 and SHA-3 (s2n-bignum), RSA
(`x86_64-mont*.S`, `rsaz-*.S`), ML-KEM/ML-DSA AVX2, `rdrand-x86_64.S`, MD5. The CPU is probed
at run time (AWS-LC's cpucap), so one build runs on any x86-64. aarch64 Linux uses
`sources/linux_aarch64.txt` (fetched too, not run here); every other platform builds the
portable `awslc-noasm` configuration, which is what `awslc-noasm` tests.

**FIPS.** The FIPS 140-3 validated module (AWS-LC-FIPS) needs CMake and Go for its
integrity-check build and is not wired into these scripts: build it with AWS-LC's own CMake
(`-DFIPS=1`) and point the `openssl` backend at it (`EIDER_OPENSSL_INCLUDE`,
`EIDER_OPENSSL_LIB`), since the glue compiles against its headers unchanged; it stays opt-in.

## Tests

`tests/crypto/run.sh [--san] [backend...]` (from `tests/packages.sh` for the default backend
and from `scripts/verify.sh` for all of them, with `--san`):

| Program | Vectors | Checks per backend |
|---|---|---|
| `rfc.ei` | RFC 8439 2.8.2 and A.5, RFC 7748 5.2 (incl. 1 and 1000 iterations) and 6.1, RFC 8032 7.1 (tests 1, 2, 3, SHA(abc)), RFC 5869 A.1-A.3, RFC 4231 4.2-4.8 (SHA-256/384/512), plus the package's misuse checks (tampered ciphertext/tag/AAD/nonce give `AuthFailed` and no plaintext, wrong lengths, out-of-range P-256 scalars, HKDF limits, constant-time compare, DER conversion, empty inputs) | 110 |
| `cavp.ei` | NIST CAVP: SHA-256/384/512 and SHA3-256/384/512 ShortMsg, SHA-256 LongMsg (3), HMAC SHA-256/384/512 (20 per tag size), AES-128/256-GCM encrypt and decrypt (96-bit IV, 128-bit tag, incl. tag failures), ECDSA P-256 KeyPair, SigVer, SigGen, sign-then-verify, ECDH P-256 (KAS ECC CDH); P-384 with SHA-256/384/512 and P-256 with SHA-384/512 (SigVer, SigGen, KeyPair), ECDH P-384, FIPS 186-3 RSA SigVer PKCS#1 v1.5 and PSS (SHA-256/384/512, moduli 1024 (must be refused), 2048, 3072; 162 records each) | 1781 |
| `wycheproof.ei` | Wycheproof (C2SP, commit d17cc89): X25519, Ed25519, ECDSA P-256/SHA-256, ECDH P-256, AES-GCM, ChaCha20-Poly1305, HKDF-SHA-256/384, HMAC-SHA-256/384, RSA PKCS#1 v1.5 (`rsa_signature_{2048,3072,4096,8192}_sha{256,384,512}`: 8 files, each key built from its SPKI and from (n, e), which must agree), RSA-PSS (`rsa_pss_*`: 7 files + `rsa_pss_misc`, groups with SHA-1 or a different MGF1 hash skipped), ECDSA P-384 (`ecdsa_secp384r1_sha384`, `_sha512`, `_sha384_p1363`), ECDH P-384 (`ecdh_secp384r1_ecpoint`); valid must pass, invalid must fail, acceptable may go either way (counted; identical on every backend: X25519 223 of 254 accepted, the rest are all-zero shared secrets, which the glue refuses; every acceptable RSA and P-384 case is refused) | 10987 (+324 skipped: IV/tag sizes the package doesn't offer, SHA-1, MGF1 with another hash) |
| `pubkey.ei` | RSA and EC keys and signatures made by the system `openssl` (`vectors/openssl_pubkey.rsp`, `gen-pubkey-fixtures.sh`: 7 keys incl. 1024-bit, e = 3 and P-384; 20 signatures: PKCS#1 v1.5 (Eider must reproduce openssl's bytes), PSS with salt 0, 20 and the hash length, ECDSA with three hashes on two curves), the key policy (2047/2048/8192/8193 bits, e = 1, 2, 3, 65537, 2^32+1, 2^33+1, even n, tiny n), key parsing from SPKI, PKCS#8, PKCS#1 and SEC1 (trailing bytes, truncation, wrong kinds), and per signature the negatives: altered message, signature or key, short, long, leading-zero, all-zero and above-the-modulus signatures, hash mismatch, PKCS#1 vs PSS, salt length off by one, wrong curve; signing every scheme (random salt and k), message sizes up to 100 kB, ECDH P-384 | 461 |
| `openssl-diff.sh` | the system `openssl` command, both directions, fresh keys each run (RSA 2048/3072/4096/e = 3, P-256, P-384): it signs 21 combinations (PKCS#1 with 3 hashes, PSS with 5 salt and hash pairs, ECDSA with 3 hashes on 2 curves) and Eider verifies them; Eider signs the same and `openssl dgst -verify` checks; PKCS#1 signatures must be byte-identical; ECDH P-256/P-384 secrets compared with `openssl pkeyutl -derive` | 29 per backend (`skip` without an openssl command) |
| `cross.ei` | every pair of backends: byte-identical output for each deterministic operation both provide (hashes, HMAC, HKDF, AEAD seal, Ed25519 sign, X25519, P-256 public and ECDH over 7 message sizes: 147-154 outputs per pair), and each backend verifies the others' fresh P-256 (random k) and Ed25519 signatures | 24 per pair |

The vectors are committed in `tests/crypto/vectors/` (`scripts/fetch-crypto-vectors.sh`
re-creates them from pinned upstream files: Wycheproof JSON unmodified, NIST files whole or
whole sections, the RFC vectors transcribed by program from the RFC texts). (RSA and P-384 vectors: `scripts/fetch-crypto-vectors.sh` also fetches the Wycheproof `rsa_*` and `*_secp384r1_*` files and NIST's `186-3rsatestvectors.zip`.) The glue builds
with `-Wall -Wextra -Wpedantic -Wshadow -Wstrict-prototypes -Wmissing-prototypes -Werror`
against every backend's headers; `--san` runs the RFC vectors with the glue and the program
under ASan+UBSan.

## Throughput

`sh scripts/crypto-bench.sh --eider` on this machine (AMD Ryzen 7 PRO 6850U, gcc -O2): through
the ABI (16 KiB messages; the timed part is the `ec_crypto_*` call: unpacking, the library,
packing, wiping), and end to end from Eider (`tests/crypto/bench.ei`, 1 MiB messages).

| Operation | AWS-LC | AWS-LC no asm | OpenSSL 3.5.8 | LibreSSL 4.4.0 |
|---|---|---|---|---|
| SHA-256 | 2055 MB/s | 360 MB/s | 2000 MB/s | 2026 MB/s |
| ChaCha20-Poly1305 seal | 1998 MB/s | 453 MB/s | 2533 MB/s | 540 MB/s |
| AES-128-GCM seal | 4897 MB/s | 201 MB/s | 4498 MB/s | 3172 MB/s |
| AES-256-GCM seal | 4354 MB/s | 159 MB/s | 3983 MB/s | 2712 MB/s |
| X25519 | 36 859 ops/s | 12 445 | 17 255 | 7 136 |
| Ed25519 sign | 74 988 ops/s | 22 810 | 15 948 | 16 604 |
| Ed25519 verify | 32 143 ops/s | 13 896 | 11 313 | 10 774 |
| ECDSA P-256 sign | 51 151 ops/s | 10 204 | 25 361 | 1 273 |
| ECDSA P-256 verify | 23 161 ops/s | 6 372 | 14 353 | 1 509 |
| ECDH P-256 | 22 463 ops/s | 5 356 | 12 751 | 899 |
| from Eider: SHA-256, 1 MiB | 1829 MB/s | n/a | n/a | n/a |
| from Eider: ChaCha20-Poly1305, 1 MiB | 1439 MB/s | n/a | n/a | n/a |
| from Eider: X25519 | 36 578 ops/s | 12 669 | 16 587 | 7 012 |

The "from Eider" rows cross the core ABI in bulk (`ec_in_set` and `ec_out_copy`, one call for
a whole `List[u8]`; core/ABI.md "Bulk transfer"). Before that each byte was a call, which held
SHA-256 at about 316 MB/s and ChaCha20-Poly1305 at about 72 MB/s for every backend; now a
1 MiB message runs at 85% and 70% of the library's own speed (the rest is the copy into `in`,
the copy out of `out`, and the bounds-checked loops of the benchmark). Only the AWS-LC column
was remeasured after the change (`n/a`: not rerun); the others were byte-limited at
about 190-320 MB/s and 65-75 MB/s.

## Files

| Path | What |
|---|---|
| `eider_crypto.h`, `eider_crypto.c` | the ABI and the glue (the only C written for crypto) |
| `awslc/PIN`, `awslc/files.sha256`, `awslc/sources/*.txt`, `awslc/cflags.sh` | the AWS-LC pin, per-file hashes, source lists, compile flags |
| `../eider_core_ext.h` | the core buffers seen from C linked into the same program |
| `../crypto.ei` | the Eider bindings |
| `scripts/fetch-awslc.sh`, `scripts/crypto-build.sh`, `scripts/ei-crypto`, `scripts/crypto-bench.sh`, `scripts/fetch-crypto-vectors.sh` | fetch, build, run, benchmark, vectors |
| `packages/crypto/` | the package |
| `tests/crypto/pubkey.ei`, `openssl-diff.sh`, `gen-pubkey-fixtures.sh`, `vectors/openssl_pubkey.rsp` | RSA/P-384 tests and their openssl-made fixtures |
| `tests/crypto/` | vectors and tests |
