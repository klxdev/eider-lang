# Changelog

eider-markdown's versions (semver). Before 1.0 the MAJOR.MINOR is the Eider toolchain's it goes
with (`eider` in eider.toml), the PATCH its own.

## 0.1.0

The first release as a repository of its own, for Eider 0.1. The code is eider-lang's
`packages/markdown` as of the split (its history is kept): eider-lang now vendors this
release in `vendor/markdown` for its own tools.

- `VERSION`, `eider = "0.1"`, `scripts/build.sh` and `scripts/test.sh` against an eider-lang
  checkout (`EIDER_ROOT`), refusing a toolchain of another MAJOR.MINOR.
- `scripts/version.sh` (`check`, `sync`): eider.toml agrees with VERSION; eider-lang's
  `scripts/version.sh check-siblings` and `bump` drive it.
