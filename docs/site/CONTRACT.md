# Docs site: source contract

The site (`scripts/docs.sh` -> `target/site/`) is built by `eider-doc` (packages/doc) from
two inputs: the Markdown pages in this directory and the API description that
`eiderc doc --json` prints for core, std and the packages. This file fixes the shape of the
pages so the content and the generator can be written in parallel.

## Layout

- `docs/site/SUMMARY.md`: the navigation, as nested lists of links (`- [Title](path.md)`);
  pages not listed there are not built. Sections in this order:
  Getting started, Tour, Guides, Language reference, Standard library (generated API),
  Packages (generated API), Tooling, Design notes.
- `docs/site/guide/*.md`: getting started, the tour, guides (written for users).
- `docs/site/reference/*.md`: the language reference, one page per area.
- `docs/site/tooling/*.md`: the compiler CLI, eider-pkg, the LSP and editors, eider-doc.
- The generated API pages live under `/api/<package>/<module>.html` and are linked as
  `api:std/stream` or `api:std/stream#BufReader` (the generator resolves them; an unknown
  target is a build error).

## Markdown subset (CommonMark, plus GFM tables)

ATX headings (`#`..`####`; one `#` per page, its title), paragraphs, emphasis, strong, inline
code, links (relative `.md` links are rewritten to `.html`; `api:` links as above), images
(local files only), bullet and numbered lists (nested), block quotes, thematic breaks,
fenced code blocks, GFM tables. No raw HTML. Headings get stable anchors (lowercased, spaces
to `-`, other punctuation dropped).

Callouts: a block quote whose first line is `**Note:**`, `**Warning:**` or `**Tip:**`.

## Code blocks are tests

The info string of a fence decides what the doc test does (`eider-doc test`, run by
`scripts/verify.sh`):

| Info string | Test |
|---|---|
| `eider` | a whole program: compiled and run; if the next block is ```` ```output ````, stdout must equal it exactly, otherwise it must exit 0 |
| `eider,fragment` | lines inserted into `fn main() uses io { ... }` and then as `eider` |
| `eider,compile_fail` or `eider,compile_fail=E0308` | must fail to compile (with that code first) |
| `eider,trap` | compiles; running it must trap (exit 101) |
| `eider,ignore` | shown, not tested (use rarely: say why in the text) |
| `output` | expected stdout of the previous `eider` block |
| `sh`, `toml`, `json`, `c`, `text` | shown, not tested |

Each test runs in a fresh temporary directory, with the toolchain's std/core available and
no network. Programs that need packages say so with `eider,ignore` and link a real example
under `examples/`.

## `///` comments in code

The same fences inside `///` doc comments are doc tests too (`eider-doc test <package>`).
A doc comment's first sentence is its summary in indexes.
