# eider-json

RFC 8259 JSON for [Eider](https://github.com/klxdev/eider-lang): an arena-based value tree, strict parsing with byte offsets, lines and columns in errors, building documents and writing them. Pure Eider; it needs no capability.

- `json.parse(bytes)` returns a `Doc` or an `Error` (`error_text` formats it); nodes are
  `u32` ids into the arena: `kind`, `as_bool`, `as_int`, `num_text`, `as_str`, `len`, `at`,
  `get`, `field`, `path`.
- `new_doc`, `new_null`, `new_int`, `new_string`, `new_array`, `new_object`, ... build a
  document (children before parents); `write` prints one, `quote` one JSON string (invalid
  UTF-8 becomes U+FFFD, so the output is always valid JSON).
- Numbers keep their exact text; integers that fit in i64 are also values.

The module documentation (`//!` at the top of json.ei) has the details and limits.

Used by: eider-lang (eider-doc), eider-http, eider-rpc, eider-openapi, eider-analyzer, eider-profiler.

## Using it

In your package's `eider.toml`:

```toml
[deps.json]
git = "https://github.com/klxdev/eider-json.git"
version = "0.1.0"
# pure: granted nothing (no `uses`)
```

then `eider-pkg fetch` (eider-lang's `scripts/eider-pkg`) and `import "json"`.

## Developing

```sh
sh scripts/build.sh     # fetch the dependencies, check every module
sh scripts/test.sh      # build, then run tests/*.ei against their .out files
```

The toolchain is the eider-lang checkout `$EIDER_ROOT` (default `../eider-lang`); its
`VERSION` must have this package's MAJOR.MINOR (the `eider` field of `eider.toml`), else the
scripts stop with exit 2 and say which release to use. It has no dependencies beyond the toolchain's `core` and `std`. eider-lang keeps a pinned copy of it in `vendor/json` for its own tools (`scripts/vendor.sh`); that copy must stay byte-identical to a tagged release here.

eider-lang's `scripts/verify.sh` builds and tests this repository against its own checkout
when it is next to it (`scripts/check-tools.sh`).

## Versions

`VERSION` and `eider.toml` hold this package's version (semver). Before 1.0 its MAJOR.MINOR
follows the Eider toolchain it goes with (`eider = "0.1"`) and its PATCH is its own;
CHANGELOG.md lists the releases. A release is tagged `v<version>`, which is what
`version = "..."` in a dependent's `eider.toml` resolves to.
