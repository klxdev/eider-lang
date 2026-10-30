# tests/oracle/

The expected results of the compiler's differential tests (`scripts/test-compiler.sh`,
`compiler/tests/wasm/run.sh`): one file per (command, input), at
`tests/oracle/<source path without .ei>.<kind>`. They were recorded from the stage-0
bootstrap at C7, just before it was retired, by `scripts/record-oracle.sh` (added in commit
8446756, deleted with stage 0), so eiderc is still held to stage 0's observable
behaviour. docs/compiler.md, "C7: retiring stage 0", lists the kinds.

The checkout's absolute path is written `<root>`. A missing `.front` file means "no lex or
parse error"; any other missing file is a failure.

To change expected behaviour: change the compiler, run `BLESS=1 sh scripts/test-compiler.sh`
(it rewrites these files, and the lex/parse/IR goldens, from eiderc's output), review
`git diff tests/oracle`, and commit the files with the change. Hand-written expectations
(`compiler/tests/run/bug_*.out`, `compiler/tests/wasm/*.out`) are never blessed.
