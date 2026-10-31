# eider-toml

The TOML subset Eider manifests and lockfiles use (`eider.toml`, `eider.lock`), for [Eider](https://github.com/klxdev/eider-lang). Pure Eider; it needs no capability.

- Comments, `[a]` / `[a.b]` headers, `[[a]]` arrays of tables, bare, quoted and dotted keys,
  basic strings, integers, booleans, arrays of strings (across lines) and inline tables.
- `toml.parse(bytes)` flattens a document into `Entry` values keyed by their full dotted key
  (the n-th `[[a]]` table is the prefix `a.<n>`), with source lines; `get`, `children` and
  `quote` (a TOML basic string) work on that.

Errors carry the line and column.

Used by: eider-lang (eider-pkg).

## Using it

In your package's `eider.toml`:

```toml
[deps.toml]
git = "https://github.com/klxdev/eider-toml.git"
version = "0.1.0"
# pure: granted nothing (no `uses`)
```

then `eider-pkg fetch` (eider-lang's `scripts/eider-pkg`) and `import "toml"`.

## Developing

```sh
sh scripts/build.sh     # fetch the dependencies, check every module
sh scripts/test.sh      # build, then run tests/*.ei against their .out files
```

The toolchain is the eider-lang checkout `$EIDER_ROOT` (default `../eider-lang`); its
`VERSION` must have this package's MAJOR.MINOR (the `eider` field of `eider.toml`), else the
scripts stop with exit 2 and say which release to use. It has no dependencies beyond the toolchain's `core` and `std`. eider-lang keeps a pinned copy of it in `vendor/toml` for its own tools (`scripts/vendor.sh`); that copy must stay byte-identical to a tagged release here.

eider-lang's `scripts/verify.sh` builds and tests this repository against its own checkout
when it is next to it (`scripts/check-tools.sh`).

## Versions

`VERSION` and `eider.toml` hold this package's version (semver). Before 1.0 its MAJOR.MINOR
follows the Eider toolchain it goes with (`eider = "0.1"`) and its PATCH is its own;
CHANGELOG.md lists the releases. A release is tagged `v<version>`, which is what
`version = "..."` in a dependent's `eider.toml` resolves to.
