# Debugging

An Eider program built with `-g` has DWARF debug information that names your `.ei` files,
lines, variables and types, so gdb and lldb work on it directly. Printer scripts in the
toolchain's `debug/` directory make `String`, `List`, `Map` and enums print the way you wrote
them. Sanitizers are one flag.

> The scripts are tested against values shaped like the debug information, and
> `tests/debug/session.sh` drives real gdb (18) and lldb (22) sessions: breakpoints on `.ei`
> lines in a closure, a generic function, an enum-taking function and `main`, locals,
> backtraces, and the printing of every kind of value below. The sessions are skipped, with the
> reason, where a debugger is not installed.

## Build for the debugger

```sh,ignore
$ eiderc build -g prog.ei -o prog          # -O2 with line tables and variables
$ EIDER_CFLAGS=-O0 eiderc build -g prog.ei -o prog   # nothing optimized away: best for stepping
$ eiderc run -g prog.ei                    # run is -O0 already
```

## gdb

```sh,ignore
$ gdb prog
(gdb) source <toolchain>/debug/eider_gdb.py
(gdb) break prog.ei:12
(gdb) run
(gdb) info locals
(gdb) bt
#0  main.closure1 (v=40) at prog.ei:32
#1  twice[i64] (x=40, f=...) at prog.ei:20
#2  main () at prog.ei:31
(gdb) print shape_arg
$1 = Circle = {centre = {px = 4, py = 5}, radius = 2}
(gdb) print names_list
$2 = List[String] of length 1 = {"a"}
(gdb) print ages_map
$3 = Map[String, i64] of length 1 = {["a"] = 7}
```

Frames carry the Eider names (`main`, `twice[i64]`, `main.closure1`), and `bt` leaves out the
runtime's own frames (`ei_main_body`, `main_run`, `thread_main`, ...); `set eider-hide-runtime off`
or `bt -no-filters` shows them.

To load the script in every session, add the line to `~/.gdbinit`:
`source <toolchain>/debug/eider_gdb.py`. `<toolchain>` is the directory with `core/` and `std/`
(`$EIDER_HOME/toolchains/<version>` for an installed release, the checkout for a source tree).

## lldb

```sh,ignore
$ lldb prog
(lldb) command script import <toolchain>/debug/eider_lldb.py
(lldb) breakpoint set -f prog.ei -l 12
(lldb) run
(lldb) frame variable
(lldb) frame variable names_list
(List[String]) names_list = length = 1 {
  [0] = "a"
}
(lldb) frame variable ages_map
(Map[String, i64]) ages_map = length = 1 {
  [0].key = "a"
  [0].value = 7
}
```

lldb shows the runtime's frames under yours in a backtrace (`bt 3` stops early; its frame
recognizers could not hide them).

For every session, put the `command script import` line in `~/.lldbinit`.

## What the debugger sees

| Eider | In the debug information |
|---|---|
| `String` | a struct `{p, len, cap}`: the text is `p[0..len)` |
| `List[T]` | `{d, len, cap}`: the elements are `d[0..len)` |
| `Map[K, V]` | `{k, v, s, len, cap, used}`: slot `i` holds an entry when `s[i] == 1` |
| a record | a struct with its fields |
| an enum | a struct `{tag, <Variant>...}`: `tag` is an enumeration of the variants (`Circle`), and each variant with fields has a member of that name |

Without the scripts you still see all of that, as the raw structs. A variable that was
optimized away (`<optimized out>`) needs `EIDER_CFLAGS=-O0`.

## Sanitizers

```sh,ignore
$ eiderc run --sanitize prog.ei            # AddressSanitizer + UndefinedBehaviorSanitizer
$ eiderc run --sanitize=thread prog.ei     # ThreadSanitizer (also --race)
$ eiderc build --race -g prog.ei -o prog
```

The program, the runtime and the link are built with the sanitizer (they need a C compiler
that links it: clang or gcc). Add `-g` so that reports name `.ei` lines. `--sanitize` takes
`address`, `undefined` or `thread` (not `thread` with the others), separated by commas.
Eider's own checks (overflow, bounds, `unwrap`) still trap first; the sanitizers find what
they can't: memory errors in `extern "c"` and `unsafe` code, data races in threads.

## Tests

`tests/debug/run.sh` runs the printers against fake values, and `tests/debug/session.sh`
runs real gdb and lldb sessions; each is skipped, with the reason, if the debugger is not
installed.
