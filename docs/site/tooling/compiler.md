# The compiler: eiderc

`eiderc` compiles Eider to LLVM IR and builds it with clang (17 or newer; see
[The LLVM backend](llvm.md)). In a checkout, run it as
`scripts/ei`, which builds `target/eiderc` from the seed (`seed/eiderc.wasm`) when needed and passes every
argument on. This page lists every command, option and environment variable, as
`compiler/main.ei` defines them (`scripts/ei --help` prints the same list).

## Usage

```text
eiderc <command> <file.ei> [options]
```

Options may come before or after the command and the file. The first word that isn't an
option is the command, the second the file; a third is an error. An unknown option, an
unknown command, a missing file argument, an option missing its value, or a file that
can't be read is a usage error: a one-line `eiderc:` message (plus a pointer to `--help`)
and exit code 2. With no arguments at all, eiderc prints its usage to stderr and exits 2.

## Commands

### Building and running

| Command | What it does |
|---|---|
| `check <file>` | Type-check the program (the file and everything it imports). Prints `ok`, or the errors and exits 1. With `--json`, prints nothing on success. |
| `build <file> [-o out] [-l lib] [-g]` | Compile to a native executable at `-O2`. The output is `-o`'s path, by default the file's stem in the working directory. Prints nothing on success. |
| `build --lib <file> [-o name]` | Build `lib<name>.a`, `lib<name>.so` and `<name>.h` from the file's `export fn`s (in `-o`'s directory, else the working directory; `name` defaults to the file's stem) and print `built <a>, <so>, <h>`. The library contains the Eider runtime and the C core. See [FFI](../guide/ffi.md). |
| `build --wasm <file> [-o name]` | Build `<name>.wasm`, `<name>.d.ts` and `<name>.js` and print `built <wasm>, <d.ts>, <js>`. Needs clang with the wasm32 target and `wasm-ld`. See [WebAssembly](../guide/wasm.md). |
| `build --wasm-core <file> [-o out.wasm]` | Build a program (with `main`) as a WebAssembly *core module*: it exports `_start` and imports only the C core's functions (`env.ec_*`), so a host linking `core/eider_core.c` runs it with files, arguments, the environment and processes as a native program has them. This is how the compiler's seed is made (`seed/README.md`). |
| `run <file> [--release] [-l lib] [--] [args...]` | Build (`-O0`, or `-O2` with `--release`) and run the program with `args`; exits with the program's exit code (128 + n if it was killed by signal n). Words after the file that aren't options go to the program, and so does everything after `--` (`eiderc run server.ei -- --port 80`). `run --lib` and `run --wasm` only build, like `build`. |
| `test <file> [--release] [-l lib]` | Build the file with a test driver and run its `test` blocks: one `test <name> ... ok` or `FAILED` line each, then `N tests, M failed`; exits 1 if any failed. `--lib` and `--wasm` are ignored. |
| `test --compile-fail [<dir>]` | Run a compile-fail suite: every `<dir>/fail/*.ei` must fail with the code and position in its `// expect: CODE LINE:COL` header (and its fix, if any, must not lead back to the same error), every `<dir>/pass/*.ei` must compile. Default `<dir>`: `tests/checks`. Exits 1 if any case failed. See [Testing](../guide/testing.md#compile-fail-tests). |

### Inspecting

| Command | Prints |
|---|---|
| `emit-header <file> [--wasm]` | The C header for the file's `export fn`s (the file is checked as a library). With `--wasm`, the `.d.ts` and the JavaScript loader, separated by a `\x01` byte. |
| `lex <file>` | The tokens, one per line: `line:col-endcol kind [value]`. |
| `parse <file> [--all-errors]` | The syntax tree. With `--all-errors`, every syntax error as a JSON line, then the tree with its error nodes (exit 1 if there were errors). |
| `ir <file>` | The typed intermediate representation the LLVM IR (and the C) is generated from. |
| `emit-llvm <file> [--test] [--lib] [--wasm]` | The LLVM IR that `build`, `run` and `test` compile (`--test`: with the test driver, as `test` builds it; `--lib`: as a library, with entry points for the exports; `--wasm`: as a WebAssembly module). See [The LLVM backend](llvm.md). |
| `caps <file>` | Each package's capability use, one JSON line per (package, capability), with the first function that uses it: `{"package":..., "dir":..., "cap":"fs", "kind":"uses", "fn":"save", "file":"notes.ei", "line":4, "col":70}`; `kind` is `uses`, `extern` or `unsafe`. Imports that can't be loaded are left out silently. See [Capabilities](../guide/capabilities.md). |
| `expand <file> [<name>]` | The specialized typed IR of the function instances whose body used comptime reflection (`comptime for`, `comptime if`): for a `@derive`d method, what it became for each type, with the loops over the fields unrolled. With `<name>`, every function whose name contains it (`expand file.ei Point.enc`). Exits 1 when nothing matches. An error inside such a specialization names the iteration and the specialization (`help: in the comptime for iteration over field y of Point; while specializing Point.enc`). See [Reflection](../reference/reflection.md#reading-a-specialization). |
| `lint [<file>] [--json] [--deny\|--warn\|--allow <lint\|group\|all>]... [--list]` | The lints of the file's package, in the form of diagnostics (`warning[unused_uses]: ...`, `error[...]` for a denied lint), with machine-applicable fixes where there is one; `--json` prints one JSON object per finding (`lint`, `level`, `span`, `message`, `help`, `fix`). With no file it lints the package in the current directory (its entry module). Levels come from `[lints]` in the package's `eider.toml` and the options, which are applied after it; `--list` prints every lint with its group and default level. Exits 1 if a denied lint was hit, 2 for an unusable `[lints]`. The code must check first. See [Lints](#lints). |
| `ide <file> [--overlay <path> <text>]...` | The analysis an editor uses (`compiler/ide.ei`): files, diagnostics, symbols with their spans and types, references, and the type at each expression. `--overlay <path> <text>` (repeatable) analyses `<path>` as if it contained the contents of the file `<text>`, for unsaved buffers. |

### Migrating code

| Command | What it does |
|---|---|
| `migrate-var <file>` | Print the file with each deprecated `var` rewritten as `let mut` (with `.copy()` where `var` copied a place), leaving the few cases where that would change the meaning. `scripts/migrate-var.sh` runs it over directories. |
| `migrate-strings <file> [--json] [--portable]` | Print the file (`.ei`, or a `.md`'s eider code blocks) with each string literal that has a brace rewritten to mean what it meant before literals interpolated: a raw string when it has no backslash, else with its braces doubled; `--json` prints the fixes, `--portable` writes the braces as `\x7b`/`\x7d`. `scripts/migrate-strings.sh` runs it over files and directories |
| `audit-refs <file> [--json]` | For code written when `let` copied: every write that changes what a live `let` or pattern reference sees, as a `note[audit]` with the `.copy()` that keeps the old meaning (with `--json`, a JSON object per line with `"audit":"reference"`); then `audit-refs: N write(s) change what a reference sees`. Exits 1 if the program has errors. |

### Help and version

`help`, `--help` and `-h` print the usage to stdout and exit 0. `version` and `--version`
print `eiderc <version>` (`eiderc 0.1.0`) and exit 0: the toolchain's version, from
`VERSION` at the root of eider-lang, which also versions core, std, eider-pkg and eider-doc
(see [Releases](releases.md)). Programs can read it too: `import core.version` has
`version.VERSION` (`"0.1.0"`), `MAJOR`, `MINOR`, `PATCH` and `SERIES` (`"0.1"`).

## Options

| Option | Commands | Meaning |
|---|---|---|
| `-o <path>` | `build` | the output file (for `--lib` and `--wasm`, the output name: files are made next to it) |
| `-l <lib>` | `build`, `run`, `test` | link the C library `<lib>` (repeatable) |
| `--release` | `run`, `test` | compile at `-O2` instead of `-O0` |
| `-j <n>` | `build`, `run`, `test` | compile at most `n` units at once (default `$EIDER_JOBS`, else one per CPU the process may use) |
| `--lib` | `check`, `emit-llvm`, `build`, `run` | treat the file as a library: no `main`, at least one `export fn` |
| `--wasm` | `check`, `emit-header`, `build`, `run`, `emit-llvm` | treat the file as a WebAssembly module (implies `--lib`; exports take and return integers and `bool`; no threads) |
| `--wasm-core` | `build`, `check`, `emit-llvm` | build the program as a WebAssembly core module (see `build --wasm-core`) |
| `--test` | `emit-llvm` | include the test driver |
| `--compile-fail` | `test` | run a compile-fail suite (`<dir>` instead of a file) |
| `--json` | every command that reports errors; `audit-refs` | diagnostics as JSON, one object per line on stdout |
| `--max-errors <n>` | every command that reports errors | show at most `n` errors (default 100; `0` shows all) |
| `--all-errors` | `parse` | every syntax error, then the tree |
| `--overlay <path> <text>` | `ide` | read `<path>` from the file `<text>` |
| `-g` | `build`, `run`, `test` | DWARF debug information for the `.ei` files |
| `--sanitize[=address,undefined\|thread]`, `--race` | `build`, `run`, `test` | build with AddressSanitizer and UBSan (the default), the listed sanitizers, or ThreadSanitizer (`--race`); see [Debugging](#debugging) |
| `--` | `run` | every argument after it goes to the program, even one that looks like an option |
| `--help`, `-h` | | print the usage and exit |
| `--version` | | print `eiderc <version>` and exit |

## Lints

`eiderc lint` runs checks that are not errors: code that is legal but probably not what was
meant, or more than it needs. A lint has a name, a group and a default level.

| Lint | Group | Default | Finds |
|---|---|---|---|
| `unused_uses` | `caps` | warn | a capability in a function's `uses` that its body never needs (a closure counts for the function that makes it; methods of trait impls are not checked, since the trait fixes their signatures). The fix rewrites the `uses` clause without it: least privilege, in the editor |
| `unused_result` | `correctness` | warn | a `Result` computed in a statement and dropped; write `let _ = f()` to drop it on purpose |
| `needless_copy` | `perf` | warn | `.copy()` of a value that is already fresh (a call's result or a literal) |

A level is `allow` (not reported), `warn` or `deny` (reported; the exit code is 1). A package
sets them in `eider.toml`; a setting names a lint, a group, or `all`, a lint beats its group
and a group beats `all`, and `--deny`, `--warn` and `--allow` on the command line come after
the file:

```toml
[lints]
all = "warn"
unused_uses = "deny"
needless_copy = "allow"
```

`@allow(unused_uses)` before a function, an `impl` or a `trait` silences a lint (or a group,
or `all`) inside it; an unknown name is E0821. Only the modules of the entry file's package
are reported, not its dependencies. The compiler's own package denies `unused_uses`
(`compiler/eider.toml`), and `scripts/verify.sh` runs it. The analyzer shows the findings as
hints through the `lints` of `eiderc ide`, with the same fixes.

## Formatting

`eiderc fmt <file.ei>` prints the file in the one canonical layout; it has no options (the
file is not rewritten: `eiderc fmt f.ei > f.new && mv f.new f.ei`). It fixes layout that has no
meaning and nothing else: the indentation (four spaces per open bracket, four more on a
continuation line), runs of spaces between tokens, trailing white space, tabs, CRLF, blank
lines (at most one in a row), the newline at the end. Tokens, comments and strings are copied
byte for byte and no space is added or removed between tokens, so line breaks and the spacing
inside a line stay yours.

It checks its own work: the output must lex to the same tokens as the input and formatting it
again must change nothing, else it prints an error (`internal error: ...`, exit 1) and no text.
A file with a lexing error, or with a `"""` multi-line string (its lines are text, which a
layout pass must not touch), is refused. `tests/fmt/run.sh` runs it over every `.ei` file of the
repository, compares diagnostics before and after, and fuzzes the layout (random indentation,
tabs, CRLF, trailing white space).

## Debugging

See [Debugging](../guide/debugging.md) for sessions; in short:

`-g` gives gdb and lldb the `.ei` files and lines, with the types of your variables (records,
enums, `String`, `List`, `Map`). A `-g` build is best run at `-O0` (`run` is).

The debug information describes a `String` as `{p, len, cap}`, a `List[T]` as `{d, len, cap}`
and a `Map` as `{k, v, s, len, cap, used}`; an enum's `tag` is an enumeration of its variants,
so `print shape` says `Circle`, not `1`. The toolchain's `debug/` directory has scripts that
print them the way you wrote them:

```text
(gdb) source <toolchain>/debug/eider_gdb.py
(gdb) print names_list
$1 = List[String] of length 1 = {"a"}
(gdb) print shape_arg
$2 = Circle = {centre = {px = 4, py = 5}, radius = 2}

(lldb) command script import <toolchain>/debug/eider_lldb.py
```

(The scripts are tested against values shaped like the debug information; the repository's
tests don't run gdb or lldb.)

`--sanitize` builds the program, the runtime and the link with AddressSanitizer and
UndefinedBehaviorSanitizer; `--sanitize=thread` or `--race` with ThreadSanitizer (it can't be
combined with address). They are the same as `EIDER_CFLAGS="-fsanitize=address,undefined"`
(`-fsanitize=thread`) with `-g` and `-fno-omit-frame-pointer`, and need a compiler that links the
sanitizer (clang or gcc: `CC`). Add `-g` for reports that name `.ei` lines.

## Diagnostics

The compiler reports every independent error it finds, in the order found, each with a
stable code (`E0001` to `E0811`), its position (line and column, columns counting Unicode
scalar values), a message, often a `help:` line and often a machine-applicable `fix:`:

```text
error[E0201]: call to `print` requires capability `io`
  --> main.ei:2:5
  |
2 |     print("hi")
  |     ^
  fix: at 1:11 delete 0 insert " uses io"
error: 1 error
```

Human output goes to stderr and ends with `error: N errors`; when more than
`--max-errors` were found, a final note says how many were left out. With `--json` each
diagnostic is one line on stdout:

```json
{"error":"E0308","span":{"file":"e1.ei","line":7,"col":12},"message":"can't call `push` on `orders` while `o` refers into it","help":"`o` is used after this change, which may free, move or replace what it refers to; use it before the change, or bind a copy with `.copy()`","fix":{"at":{"line":6,"col":22},"delete":0,"insert":".copy()"}}
```

A fix is an insertion and a deletion at one position; applying it never produces the same
error again (the compile-fail suite checks every fix). Nothing is compiled to C after an
error.

At run time, a trap prints `eider: runtime error: <what> (<file>:<line>)` to stderr and
exits 101.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | the program has errors (`check`, `build`, ...), a test failed, or a compile-fail case failed |
| 2 | usage error, a file that can't be read, or no toolchain found |
| 3 | the C compiler failed (the C is kept in the work directory), or another internal failure |
| other | `run` and `test` pass on the program's own exit code (101 for a trap) |

## Environment

| Variable | Meaning |
|---|---|
| `CC` | the C compiler (default `cc`); gcc and clang are both tested |
| `EIDER_CFLAGS` | extra C compiler flags, split at spaces (for example `-fsanitize=address,undefined`) |
| `EIDER_CACHE` | `off`, or the cache directory (default `$XDG_CACHE_HOME/eider`, else `~/.cache/eider`) |
| `EIDER_CACHE_MAX` | the cache's size limit: bytes, or with `K`, `M` or `G` (powers of 1024); default `5G`, `0` for none |
| `EIDER_JOBS` | parallel compile jobs when there is no `-j` |
| `EIDER_LLVM_UNITS` | `0`: build the LLVM module as one unit instead of one per module |
| `EIDER_ROOT` | the toolchain, the directory holding `core/` and `std/` (default: the nearest directory above the eiderc binary, symlinks resolved, that holds `core/eider_rt.h`, else the same search from the working directory) |
| `WASM_CC` | the clang used by `build --wasm` and `--wasm-core` (default `clang`) |
| `EIDER_LLVM_CC` | the clang that compiles the LLVM IR of `build`, `run` and `test` (default `clang`; LLVM 17 or newer) |
| `EIDER_HOME` | where package imports find git packages fetched by eider-pkg (default `~/.eider`) |
| `TMPDIR` | work directories when neither the cache nor `<root>/target/tmp` is writable |

## The cache

`build`, `run` and `test` compile a program as units: one per module of the LLVM IR, the
generic instances in 16 shards, one for the per-type glue and `main` and the C core's two
sources, in parallel (`-j`); each unit's object is cached by a SHA-256 of everything that
affects it: its text, the headers it includes, the compiler (clang or `$CC`) and its version,
the flags and `EIDER_CFLAGS`. After an edit only the edited module's unit is compiled again.
The linked program is cached too, by its objects and the `-l` libraries, so running an
unchanged program again runs neither the compiler nor the linker. Entries appear atomically,
so concurrent builds into one cache are safe. External libraries' contents and system headers
are not part of the key: after changing one, run with `EIDER_CACHE=off` or `eiderc cache
clean`. The front end (parsing and checking) runs every time; it is whole-program.

The cache stays under `EIDER_CACHE_MAX` (default 5 GiB): after a build that added entries
(at most every 15 minutes), the least recently used entries are removed until it is under
90% of the limit; nothing used in the last 10 minutes is removed. `eiderc cache size` prints
what each kind of entry takes, `eiderc cache trim` applies the limit now, and `eiderc cache
clean` removes every entry.

## Compile times

The front end takes about 50 ms for a 3,000-line program; clang dominates a build. That is
why `run` and `test` use `-O0` and `build` uses `-O2`, and why the IR is built in cached,
parallel units ([the LLVM backend](llvm.md)).

## The bootstrap

eiderc is written in Eider (`compiler/`). It is committed compiled to WebAssembly,
`seed/eiderc.wasm`, with `seed/wasm2c.c`, a small translator from WebAssembly to C, so
building it needs only a C11 compiler:

```sh
cc -std=c11 -O2 -o wasm2c seed/wasm2c.c
./wasm2c seed/eiderc.wasm -o eiderc.c
cc -std=c11 -O1 -pthread -o eiderc eiderc.c core/eider_core.c
```

That compiler (stage0) checks programs and emits LLVM IR; with clang it builds `compiler/`
natively, which is what `scripts/ei` does. `sh scripts/selfhost.sh` builds stage0, then the
compiler with it, then with itself, and checks that the last two emit identical LLVM IR and
build identical seeds (`SELF-HOSTED`); `--seed` writes the new seed after a compiler change,
and `--from-seed` checks that the seed is current. The compiler may only use language features the committed seed supports, so a feature
lands in `compiler/` first and is used there only after the seed is regenerated. That is
why a few features (`Ref[T]`, labeled loops, `Default`, method chains across lines) are in
the compiler sources but not yet in the compiler `scripts/ei` builds.
