# Changelog

eider-toml's versions (semver). Before 1.0 the MAJOR.MINOR is the Eider toolchain's it goes
with (`eider` in eider.toml), the PATCH its own.

## 0.1.1

Imports in the dotted form (eider-lang C8.26, issue #91): `import std.bytes` and `import
toml` instead of the quoted `import "std/bytes"` and `import "../toml.ei"`, in the code, the
tests, the README and the program scripts/build.sh generates to check every module.

Needs an Eider 0.1 toolchain whose compiler knows dotted imports (the eider-lang commit after
the next seed); an older 0.1 compiler stops at the first dotted import (E0001).

## 0.1.0

The first release as a repository of its own, for Eider 0.1. The code is eider-lang's
`packages/toml` as of the split (its history is kept): eider-lang now vendors this
release in `vendor/toml` for its own tools.

- `VERSION`, `eider = "0.1"`, `scripts/build.sh` and `scripts/test.sh` against an eider-lang
  checkout (`EIDER_ROOT`), refusing a toolchain of another MAJOR.MINOR.
- `scripts/version.sh` (`check`, `sync`): eider.toml agrees with VERSION; eider-lang's
  `scripts/version.sh check-siblings` and `bump` drive it.
