# eider-markdown

A CommonMark subset plus GFM tables for [Eider](https://github.com/klxdev/eider-lang): a block tree and a safe HTML renderer (raw HTML never gets through). Pure Eider; it needs no capability.

- ATX and setext headings, paragraphs, emphasis, code spans, links, autolinks, images,
  lists, block quotes (with `**Note:**`/`**Warning:**`/`**Tip:**` callouts), thematic
  breaks, fenced code blocks and GFM tables.
- `markdown.to_html(bytes)` for a whole document; `parse` then `html` with `Options` to
  rewrite link destinations or highlight code; `links`, `headings`, `code_blocks`, `title`
  and `summary` list what a document has.
- Every `<`, `>`, `&`, `"` and `'` of the source is escaped; `javascript:`, `vbscript:` and
  `data:` destinations render as text.

It is the subset eider-lang's documentation site uses (its `docs/site/CONTRACT.md`).

Used by: eider-lang (eider-doc).

## Using it

In your package's `eider.toml`:

```toml
[deps.markdown]
git = "https://github.com/klxdev/eider-markdown.git"
version = "0.1.0"
# pure: granted nothing (no `uses`)
```

then `eider-pkg fetch` (eider-lang's `scripts/eider-pkg`) and `import markdown`.

## Developing

```sh
sh scripts/build.sh     # fetch the dependencies, check every module
sh scripts/test.sh      # build, then run tests/*.ei against their .out files
```

The toolchain is the eider-lang checkout `$EIDER_ROOT` (default `../eider-lang`); its
`VERSION` must have this package's MAJOR.MINOR (the `eider` field of `eider.toml`), else the
scripts stop with exit 2 and say which release to use. It has no dependencies beyond the toolchain's `core` and `std`. eider-lang keeps a pinned copy of it in `vendor/markdown` for its own tools (`scripts/vendor.sh`); that copy must stay byte-identical to a tagged release here.

eider-lang's `scripts/verify.sh` builds and tests this repository against its own checkout
when it is next to it (`scripts/check-tools.sh`).

## Versions

`VERSION` and `eider.toml` hold this package's version (semver). Before 1.0 its MAJOR.MINOR
follows the Eider toolchain it goes with (`eider = "0.1"`) and its PATCH is its own;
CHANGELOG.md lists the releases. A release is tagged `v<version>`, which is what
`version = "..."` in a dependent's `eider.toml` resolves to.
