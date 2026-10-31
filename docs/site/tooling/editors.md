# Editors

Two projects next to eider-lang give editors Eider support:

- **eider-analyzer**, a language server (LSP 3.17 over stdio) written in Eider. It asks the
  compiler itself for its analysis (`compiler/ide.ei`, the same code as `eiderc ide`), so
  diagnostics, positions and types are exactly the compiler's.
- **tree-sitter-eider**, a tree-sitter grammar with highlighting, folding, indentation and
  text-object queries.

The paths below are placeholders: `/path/to/eider-lang`, `/path/to/eider-analyzer` and
`/path/to/tree-sitter-eider` are wherever you cloned the three repositories.

## The language server: eider-analyzer

### What it does

| LSP feature | What you get |
|---|---|
| diagnostics | the compiler's errors (code, message, `help:`), for the open file and for an imported module that has the error |
| code actions | the compiler's machine-applicable fix as a quick fix |
| document symbols | types with their fields, variants and methods; functions, constants, traits, tests |
| go to definition, references | every name the checker resolved, across modules: locals, parameters, items, fields, methods, variants, module aliases |
| hover | the symbol's signature or type, and the type at the cursor |
| folding ranges | multi-line items and runs of imports |
| semantic tokens | namespaces, types, variants, fields, functions, methods, parameters, variables, constants, traits |
| completion | names in scope; after `.`, a module's public items or the fields and methods of the receiver's type |

Unsaved buffers are analysed from memory (the compiler's overlays). Edits are debounced, so
a burst of typing costs one analysis. When a buffer doesn't parse, a lexical fallback
keeps the outline, completion and navigation working. A file's workspace root is the
nearest directory with an `eider.toml`.

### Build it

It needs an eider-lang checkout and a C11 compiler, nothing else:

```sh
cd /path/to/eider-analyzer
EIDER_LANG=/path/to/eider-lang sh scripts/build.sh
```

`EIDER_LANG` defaults to `../eider-lang`, a checkout next to the analyzer. The script runs
`eider-pkg fetch` if `eider.lock` is missing, builds a compiler from the checkout's
`compiler/` sources (the analyzer imports the compiler as a package, which needs a
compiler newer than the committed seed), and writes `target/bin/eider-analyzer`. The
analyzer's `eider.toml` refers to the checkout by relative path (`../eider-lang/...`); with
the checkout elsewhere, edit those two paths and run `eider-pkg fetch` again.

```text
eider-analyzer [--sync] [--verbose]   serve LSP on stdin/stdout (logs on stderr)
eider-analyzer --dump <file.ei>       print the analysis of a file
```

At run time it needs the toolchain (the prelude and the C core): set `EIDER_ROOT` to the
eider-lang checkout, or leave the binary in `target/bin/`, where the build links the
toolchain's `core/` and `std/` next to it.

### Neovim

Neovim 0.11 or later, with the built-in LSP client:

```text
vim.filetype.add({ extension = { ei = "eider" } })
vim.lsp.config("eider_analyzer", {
  cmd = { "/path/to/eider-analyzer/target/bin/eider-analyzer" },
  cmd_env = { EIDER_ROOT = "/path/to/eider-lang" },
  filetypes = { "eider" },
  root_markers = { "eider.toml", ".git" },
})
vim.lsp.enable("eider_analyzer")
```

With LazyVim this can go in any plugin spec file; LazyVim's LSP keymaps and completion
apply to every client.

### Other editors

Any editor that can run a stdio language server for `*.ei` files works:

- **Helix**: a `[language-server.eider-analyzer]` entry with `command` set to the binary
  and `environment = { EIDER_ROOT = "/path/to/eider-lang" }`, and a `[[language]]` entry
  for `eider` with `file-types = ["ei"]` that uses it.
- **VS Code** needs a small extension that starts the binary as a language client; none is
  published yet.

### Claude Code

The analyzer repository is also a Claude Code plugin marketplace (named `eider`) with one
plugin, `eider-lsp`, which gives Claude Code diagnostics after edits, go to definition,
references and hover for `.ei` files:

```sh
claude plugin marketplace add /path/to/eider-analyzer
claude plugin install eider-lsp@eider
```

The server is declared in the repository's `.claude-plugin/marketplace.json`, under
`lspServers`: its `command` is the absolute path of the built binary and its `env` sets
`EIDER_ROOT`. Both are machine-specific, so set them to your paths before installing, then
restart Claude Code.

```json
"lspServers": {
  "eider-analyzer": {
    "command": "/path/to/eider-analyzer/target/bin/eider-analyzer",
    "args": [],
    "env": { "EIDER_ROOT": "/path/to/eider-lang" },
    "extensionToLanguage": { ".ei": "eider" }
  }
}
```

## Syntax highlighting: tree-sitter-eider

The grammar follows the compiler's recursive-descent parser, with node names taken from the
compiler's AST (`function_declaration`, `method_call_expression`, `variant_pattern`, ...).
An external scanner handles Eider's newline-terminated statements the way the parser does.
Queries: `highlights.scm`, `locals.scm`, `folds.scm`, `indents.scm`, `injections.scm` and
`textobjects.scm` (functions, types, parameters, calls, blocks, loops, ... for
nvim-treesitter-textobjects).

The tree-sitter CLI is a pinned development dependency:

```sh
cd /path/to/tree-sitter-eider
npm install                  # the pinned tree-sitter CLI, into node_modules/
npx tree-sitter generate     # grammar.js -> src/parser.c
npx tree-sitter test         # the corpus in test/corpus
npx tree-sitter parse FILE.ei
```

`scripts/check-repo.sh /path/to/eider-lang` parses every `.ei` file in a checkout and
reports any that don't parse cleanly.

### Neovim

With nvim-treesitter on its `main` branch, register the parser and the filetype:

```text
vim.filetype.add({ extension = { ei = "eider" } })

vim.api.nvim_create_autocmd("User", {
  pattern = "TSUpdate",
  callback = function()
    require("nvim-treesitter.parsers").eider = {
      install_info = { path = "/path/to/tree-sitter-eider", queries = "queries" },
      tier = 2,
    }
  end,
})
```

Then `:TSInstall eider` (the tree-sitter CLI must be on `PATH`, for example the
repository's `node_modules/.bin`); `:TSInstall! eider` rebuilds after a grammar change.
Enable the features for the filetype:

```text
vim.api.nvim_create_autocmd("FileType", {
  pattern = "eider",
  callback = function()
    vim.treesitter.start()
    vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
    vim.wo[0][0].foldmethod = "expr"
    vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
    vim.bo.commentstring = "// %s"
  end,
})
```

(LazyVim does the `FileType` part itself for every installed parser.)

### Known gaps

The grammar can't know which names are import aliases, so `alias.f(x)` parses as a method
call; and it trails the compiler on the newest syntax: bitwise operators, `let mut` and
`mut` patterns, `while let`, labeled loops, type aliases, `for (k, v)` patterns, string
escapes beyond `\n \t \" \\`, and method chains across lines are described in the
compiler's design notes ("Syntax changes" in each section of the repository's
`docs/compiler.md`) for the grammar to follow. Check the grammar's README for what it
covers today.

## From the command line

Tools that want the compiler's view without an editor can call it directly:

- `scripts/ei check --json file.ei`: diagnostics with fixes, one JSON object per line;
- `scripts/ei ide file.ei`: symbols, references and types (what the analyzer uses);
- `scripts/ei caps file.ei`: each package's capability use.

See [the compiler CLI](compiler.md).
