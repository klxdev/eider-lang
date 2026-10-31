# Research track 3: developer experience, tooling, ecosystem and service essentials

Draft, 2026-10-31, for klxdev/eider-lang#97 (track 3). Proposed home: `docs/research/dx-ecosystem.md`.

**What this covers.** What leading ecosystems ship for formatting, linting, editors, REPLs, testing, packages and the supply chain, builds and deployment, docs, stability, diagnostics, debugging and observability. It also covers the libraries every service needs, and onboarding and governance. Each topic has a comparison table, the lessons from it, and what Eider should do and in which repository. The document ends with a ranked list of proposed features and the sources.

**Source markers.** [V] means the fact was checked against the source this session (web search on 2026-10-31). [gk] means it comes from general knowledge of the ecosystems as of 2026 and was not fetched; the canonical URL is listed under Sources so it can be checked before anything is filed. Users' "love/hate" claims summarise long-running community consensus (the Rust and Go annual surveys, the Stack Overflow survey, issue trackers). They are not quotes.

**Where Eider stands (from the repository, 2026-10-31).**
- `eiderc` has `check/build/run/test/emit-c/ide/caps/doc`, `--json` diagnostics with 56 stable codes and machine-applicable fixes, and a binary cache.
- `test` blocks and std/testing exist (`assert_eq`, `Suite`, fakes for the clock and for I/O). There is a compile-fail suite, a fuzzer package (`packages/fuzz`), and doc tests in eider-doc.
- eider-pkg has git dependencies, a lockfile with hashes, capability grants per dependency, `vendor` and `tree`. The registry design is #10, and the supply-chain work (registry, checksum log, audit) is #33.
- eider-analyzer has diagnostics, quick fixes, symbols, go-to-definition, references, hover, folding, semantic tokens and completion.
- Also present: tree-sitter-eider, eider-profiler (CPU, memory and concurrency profiles, flame graphs, diffs, labels), a single version number for the whole toolchain (`VERSION`), and an experimental LLVM backend (#92, #96).
- Missing, with the issues that track them:
  - formatter, and analyzer rename, signature help and inlay hints (#9);
  - linter (only #85, unused `uses`);
  - test filters, benchmarks and coverage (#30);
  - `#line` debugging (#25);
  - cross-compilation and static binaries (#34);
  - logging and config (#24);
  - observability (eider-http#5);
  - an installer, a version manager, a playground and project templates (no issue).

---

## 1. Formatter

| | gofmt | rustfmt | zig fmt | Prettier | ruff format / Black |
|---|---|---|---|---|---|
| Config | none | `rustfmt.toml`, about 70 options, many unstable | none | a few options (deliberately limited) | Black: almost none; ruff: a few |
| Shipped with toolchain | yes (`go fmt`) | yes (rustup component) | yes (`zig fmt`) | npm package | separate tool |
| Preserves | comments, blank lines | comments | comments; trailing comma decides one-line vs multi-line | comments | comments; "magic trailing comma" |
| Stability | output has barely changed since Go 1 | "style editions" tie style changes to the Rust edition (2024 style edition) | changes with the language, pre-1.0 | changes between major versions | Black "stable style" changes once a year |
| Speed | fast | moderate; gives up silently on long expressions and macros | fast | slow on huge files | ruff about 30x faster than Black |

**Lessons.**
- Go's line "gofmt's style is no one's favourite, yet gofmt is everyone's favourite" (Go Proverbs) is backed by everything since. Having no configuration ends style arguments, makes diffs and code review simpler, and lets tools such as `go fix` and refactorings rewrite code safely: print the tree, then format it.
- rustfmt's options add little value and plenty of complaints. Two complaints recur: it silently refuses to format some constructs (long chains, macro bodies), and the unstable options never stabilise.
- Two Zig and Black choices work well and need no configuration: the trailing comma lets the author pick multi-line layout, and blank lines are kept as written.
- The formatter must cover 100% of the grammar and never give up, and it must be idempotent. A formatter that reflows comments makes people angry.
- Formatting on save in the LSP (through `textDocument/formatting`) is what people actually use. The CLI is for CI (`--check`).

**Eider.** Build `eiderc fmt` into the compiler (#9), using the compiler's own parser with comments kept as trivia on the lossless token stream.
- No options at all. Line width is fixed at 100.
- A trailing comma means multi-line (Zig). Blank lines are kept, up to one.
- Version formatting styles with the toolchain's MAJOR.MINOR, so a style change only lands in a MINOR release.
- `--check` exits 1 for CI. Formatting must be idempotent on every `.ei` file in the repository, and the fuzzer checks it: parse(fmt(x)) gives the same AST as x, and fmt(fmt(x)) == fmt(x).
- eider-analyzer calls it for `textDocument/formatting` and range formatting.
- `eiderc migrate-*` and machine-applicable fixes print through fmt, so rewritten code is canonical.

## 2. Linters

| | clippy | go vet | staticcheck | golangci-lint | ruff |
|---|---|---|---|---|---|
| Shipped | rustup component | `go vet`, which `go test` runs on a subset | third-party | aggregator of about 100 linters | third-party, Rust-based |
| Lints | 750+ in groups (correctness = deny, suspicious, style, complexity, perf, pedantic, restriction, nursery) | about 30 high-precision analyzers | about 150, very low false-positive rate | everything | 800+ (re-implements flake8, isort, pyupgrade...) |
| Config | `#[allow]`/`#[warn]`, `[lints]` in Cargo.toml, `clippy.toml` | none | `staticcheck.conf` | big YAML | `pyproject.toml` |
| Fixes | `cargo clippy --fix` (machine-applicable suggestions) | some through `go fix` | some through gopls | some | `ruff check --fix`, "unsafe fixes" opt-in |
| Framework | rustc lint passes | `go/analysis`, shared with gopls | `go/analysis` | `go/analysis` | own |

**Lessons.**
- High precision matters more than many lints. go vet runs inside `go test` because its false positives are close to zero.
- Lint groups with a default level let a project raise strictness in one line, as clippy's `pedantic` does. Configuring each lint separately (golangci YAML) is the most-hated part of Go tooling.
- One analysis framework shared by the CLI, the LSP and the fixer (Go's `go/analysis`) means every lint shows in the editor with its fix for free.
- Speed changed the Python ecosystem: ruff replaced half a dozen tools in about two years because it is 10 to 100 times faster.
- Lints declared in the manifest, as in Cargo's `[lints]` table (Rust 1.74), beat attributes scattered through the code.

**Eider.** `eiderc lint` (expanding #85) on the checker's typed IR, sharing diagnostic codes, the JSON output and fix machinery (`diag.ei`) with the compiler. Lints get codes from their own range (`L0xxx`) and the same `fix` format, and the analyzer shows them as hints with quick fixes.
- Groups: `correctness` (deny), `suspicious`, `perf`, `style`, `pedantic`. Levels are set in `[lints]` in `eider.toml`; `@allow(name)` follows after attributes (#19).
- First lints, chosen because they come from things only Eider knows:
  - `unused_uses` (#85);
  - needless `.copy()` and copy-on-write unshare in a loop (#11; the profiler already counts these);
  - a `Result` dropped unused;
  - a capability broader than needed;
  - a shadowed `inout`;
  - unreachable code after `panic`;
  - a blocking capability inside a lock scope.
- `eiderc test` runs the correctness group, like go vet.

## 3. Language server (LSP)

| Feature | rust-analyzer | gopls | Users rank it |
|---|---|---|---|
| Diagnostics as you type | yes (own analysis + `cargo check` on save; mismatch is a top complaint) | yes (same analysis as the compiler) | essential |
| Completion (with auto-import) | yes, flyimport | yes, unimported packages | essential |
| Go to definition / references / rename | yes | yes | essential |
| Hover with docs | yes, rendered rustdoc | yes | essential |
| Inlay hints (types, parameter names, chained types) | yes, much loved | yes (off by default) | high |
| Signature help | yes | yes | high |
| Code actions / assists | 150+ assists (fill match arms, extract function, add missing impl members) | fill struct, extract, organize imports | high |
| Run/debug test lenses | yes | yes | high |
| Workspace symbols, call hierarchy, type hierarchy | yes | yes | medium |
| Format on save | via rustfmt | via gofmt/goimports | essential |
| Macro expansion view, syntax tree view | yes | n/a | niche |
| Memory/latency | large workspaces cost GBs of RAM; startup indexing slow (top complaint) | rewritten in 2023 (v0.12) for 75% less memory | hated when bad |

**Lessons.**
- Diagnostics must come from the compiler itself. rust-analyzer's split brain, with its own type inference beside rustc's, causes "the IDE says OK, cargo says no", the most-reported annoyance. Eider already avoids this (`compiler/ide.ei`).
- Latency and memory decide whether people keep a server installed. gopls 0.12 rewrote its cache around on-disk export data so that only open packages are held in memory.
- After the basics, the features people mention most are "fill match arms / missing cases", inlay hints, auto-import completion and the run-test lens.
- A failed parse must not kill the features; Eider already has a lexical fallback.

**Eider.** In eider-analyzer, in order (#9 already lists the first four):
1. formatting through `eiderc fmt`;
2. rename across modules;
3. signature help;
4. inlay hints for inferred `let` types and parameter names at call sites with literal arguments;
5. assists: fill `match` arms (exhaustiveness already knows the missing patterns), add missing trait methods, add an import, add a `uses` capability when E-code says missing (already a compiler fix);
6. code lenses: run/debug test, run benchmark, run fuzz target;
7. workspace symbols, call hierarchy.

The front end today is whole-program every time (README "Known limits"), so incremental analysis (#8) is the long-term latency fix. Until then, cache each module's checked interface keyed on content hash.

## 4. REPL, playground, notebooks, watch mode, hot reload

| | Rust | Go | Zig | Swift | Elixir | Python/JS |
|---|---|---|---|---|---|---|
| REPL | evcxr (third-party, slow) | none official (gore, yaegi) | none | `swift repl` (LLDB-based) | IEx, loved | built in, loved |
| Playground | play.rust-lang.org (share links, editions, MIR/asm view, clippy, rustfmt) | go.dev/play (share links, used in docs examples and issue reports) | none official (community) | Swift Playgrounds app | Livebook | many |
| Notebooks | evcxr Jupyter kernel | gophernotes | none | Playgrounds | Livebook, loved | Jupyter |
| Watch mode | bacon, cargo-watch (unmaintained, points to bacon) | air, reflex (third-party) | `zig build --watch` (built in, 0.14) | — | `mix test --stale` | vitest/jest watch, `node --watch` |
| Hot reload | subsecond (Dioxus, 2025) via hot-patching | none | incremental + hot-swap plan for the self-hosted backend | SwiftUI previews | BEAM hot code loading | HMR (Vite) |

**Lessons.**
- For a compiled language, a playground does more good than a REPL. Go's playground is in every doc example ("Run" on pkg.go.dev), in bug reports, and in the tour. Rust's has share links and shows asm, MIR and C views. Both are sandboxed servers.
- A REPL in a compiled language works only when compile-and-run is very fast. Otherwise people stop using it (evcxr).
- A built-in watch mode removes a third-party dependency that every project adds; Zig added `--watch` to `zig build` in 0.14.
- "Hot reload" in services mostly means restart-on-change plus a fast compile. Real hot-patching (subsecond, BEAM) matters for UI and games.

**Eider.**
- **Playground through WebAssembly.** `build --wasm` already exists, so the hard part is compiling eiderc itself to wasm. Its seed is C11, so `clang --target=wasm32-wasi seed/eiderc.c` plus a wasm C compiler is needed for the second step. That second step is heavy: shipping clang to the browser is about 30 MB (the Zig and Wasmer approach). Two alternatives:
  - (a) an interpreter of Eider's typed IR in wasm, which also gives a REPL and comptime (#7, comptime interpreter, is the same engine);
  - (b) a small sandboxed server running `eiderc run` with no capabilities.

  Recommendation: start with (b), with share links, in a new `eider-play` repository, and move to (a) when the comptime interpreter exists. Then eider-doc gets a "Run" button on every doc example.
- **`eiderc run --watch` / `test --watch`.** Re-run when any imported module changes; the driver already knows the module set. Use inotify/kqueue from core-os (`layer/core-os`).
- **REPL.** Wait for #7 and the direct debug backend (#40).
- **Hot reload.** Not before 1.0.

## 5. Testing

### 5a. Unit, table, fixtures, filters

| | Go `testing` | Rust `cargo test` / nextest | Zig `zig test` | pytest |
|---|---|---|---|---|
| Declaration | `func TestX(t *testing.T)` | `#[test]` | `test "name" {}` | `def test_x()` |
| Table tests | idiom: slice of structs + `t.Run(name, ...)` subtests | rstest/test-case crates | inline loop | `@pytest.mark.parametrize`, loved |
| Filters | `-run 'Regex/sub'` | name substring; nextest filtersets | `--test-filter` | `-k expr` |
| Parallelism | `t.Parallel()` opt-in | threads by default; nextest process-per-test | no | xdist plugin |
| Fixtures | `t.TempDir()`, `t.Cleanup`, `t.Setenv`, `testing/synctest` (fake time, 1.25) | none built in; tokio `pause()` | `testing.allocator` (leak checks), `testing.io` | fixtures (DI by parameter name), loved |
| Failure output | `t.Errorf` continues; no assert lib (testify very popular) | `assert_eq!` diff; stops at first | `expectEqual` | assertion rewriting shows values, loved |

**Lessons.**
- Subtests named by data (Go) and parametrize (pytest) are the two forms of table test people like.
- Process isolation (nextest) avoids one test's crash or global state killing a whole run. Eider has traps that abort, so it matters more here (#54).
- Assertion failures with diffs and the caller's line are basic, and Eider's #72 shows that is still missing. Being able to keep going after a failed check (Go's `t.Errorf`) is the other half; README "Known limits" says Eider stops at a test's first failed assert.
- Deterministic fake time (Go 1.25 `testing/synctest`, tokio `pause`) is the most-requested service-testing feature. Eider's capabilities make it natural: a test gets a fake `clock`.

### 5b. Property-based, snapshot, fuzzing, benchmarks, coverage, mutation

| Kind | Leading tool | What people love | What people hate |
|---|---|---|---|
| Property-based | Hypothesis (Python), proptest/quickcheck (Rust), fast-check (JS) | automatic **shrinking** to a minimal case; Hypothesis's example database replays failures | slow generators; writing strategies by hand; flaky when not seeded |
| Snapshot | insta (Rust), Jest snapshots | `cargo insta review` TUI to accept/reject; inline snapshots rewritten into the source | snapshot blindness (reviewers rubber-stamp huge diffs) |
| Fuzzing | `go test -fuzz` (Go 1.18, coverage-guided, corpus in `testdata/fuzz`), cargo-fuzz (libFuzzer), Zig's integrated fuzzer (`zig build --fuzz`, 0.14) | in the standard test runner, the same function signature as a test; failing inputs become regression tests automatically | cargo-fuzz needs nightly; Go fuzzing limited to primitive types |
| Benchmarks | Go `testing.B` (`B.Loop` in 1.24 [V]), criterion (Rust), `zig build` none | `go test -bench`, benchstat for A/B statistics; criterion's statistics and regression detection | `b.N` loops were error-prone (dead-code elimination, setup inside loop), fixed by `B.Loop` [V]; Rust's `#[bench]` still unstable |
| Coverage | `go test -cover` (built in, plus `go build -cover` for integration binaries, 1.20), cargo-llvm-cov | Go: one flag, HTML report | Rust: external tool, LLVM-only |
| Mutation | cargo-mutants, PIT (Java), Stryker (JS) | finds tests that assert nothing | slow (rebuild per mutant) |

**Lessons.**
- Everything belongs under one command. Go's `go test` runs tests, benchmarks, fuzzing, coverage, vet and examples, and that is why Go code is well tested. When fuzzing or benchmarks need a separate tool or nightly, as in Rust, fewer people use them.
- Fuzz targets and property tests are the same idea: a generator plus a property. Hypothesis and Go 1.18 both treat a failing input as a new permanent regression case.
- Deriving generators from types is what makes property testing cheap: proptest's `Arbitrary` derive, Hypothesis's `from_type`. Eider gets this free from comptime reflection (#20), the same machinery as JSON derive.
- A snapshot tool is only good if it has a review workflow (insta).

**Eider.** All in `eiderc test` (#30), in the compiler driver plus std/testing:
- `--filter`.
- Subtests: `t.case(name, ...)`, or `test "parse" for (input, want) in CASES { ... }` sugar if wanted.
- Continue-on-failure `check` alongside `assert`, with value diffs at the caller's line (#72).
- Each test in its own process by default, since a trap aborts. That needs fork-per-test in the generated driver.
- `bench` blocks with a `B.Loop` style API (no `b.N`), statistics printed with a confidence interval, and `--bench-compare old.json`.
- `fuzz` blocks in the test runner using `packages/fuzz` (coverage-guided through `-fsanitize-coverage=trace-pc-guard` with clang), corpus in `testdata/fuzz/<name>/`, failing inputs saved as regression cases.
- `Arbitrary` derived through reflection (#20), with integrated shrinking (Hypothesis-style choice sequences, which shrink any generator without writing a shrinker).
- `--cover` through `#line` (#25) plus gcov/llvm-cov on the C, mapped back to `.ei` lines.
- Snapshots: `testing.snapshot(name, value)` writing `Show` output to `testdata/snapshots/`, accepted with `EIDER_BLESS=1`. The repository already uses `BLESS=1` for the oracle.
- Fake capabilities, a fake clock and fake I/O in std/testing (some exist), and a deterministic scheduler for tasks once #14 lands.
- Mutation testing: later, as an eider-pkg-adjacent tool, not core.

## 6. Packages, registry and supply chain

| | crates.io / Cargo | Go modules | npm | PyPI | Zig |
|---|---|---|---|---|---|
| Source of truth | central registry (immutable versions, yanking) | VCS (any git host) + module proxy cache (proxy.golang.org) | central registry | central | URL + content hash in `build.zig.zon` |
| Integrity | `Cargo.lock` checksums | `go.sum` + **checksum database** (sum.golang.org, a transparency log; TOFU made global) | `package-lock.json` integrity hashes | hashes optional (`--require-hashes`) | hash mandatory |
| Version resolution | SAT-like with unification (one version per semver-major); pubgrub port in progress | **minimal version selection** (MVS): deterministic, no lockfile solver, no SAT | newest matching, duplicates allowed | pip resolver (backtracking) | exact |
| Install-time code | `build.rs` runs arbitrary code | none (no install scripts) | `postinstall` scripts, the main attack vector | `setup.py` | `build.zig` runs code |
| Publishing auth | trusted publishing via OIDC, July 2025 [V]; "trusted publishing only" mode Jan 2026 [V] | none needed (tag a git repo) | trusted publishing; after Shai-Hulud (Sept 2025) GitHub moved to FIDO 2FA, 7-day tokens, tokenless publishing by default [V] | trusted publishing (2023), PEP 740 attestations | none |
| Provenance | via Sigstore discussions | — | `npm publish --provenance` (Sigstore, SLSA) | PEP 740 Sigstore attestations | — |
| Advisories / audit | RustSec + cargo-audit, cargo-deny | **govulncheck** (call-graph reachability: reports only vulns your code actually calls) | `npm audit`, notoriously noisy | pip-audit | — |
| Review sharing | **cargo-vet** (Mozilla: shared audit records, import audits from others), cargo-crev | — | Socket etc. (commercial) | — | — |
| Typosquatting/namespaces | flat namespace; squatting common | domain-based paths, no squatting | scopes `@org/`; squatting and dependency confusion | flat | URLs |

**Lessons.**
- **npm is the cautionary tale:** event-stream (2018), ua-parser-js (2021), the chalk/debug phish (Sept 2025), and the self-replicating Shai-Hulud worm (Sept 2025, 500+ packages [V]). The causes are known: install scripts, long-lived tokens, huge transitive trees of tiny packages, and phishable 2FA. The fixes the industry converged on are tokenless OIDC publishing, FIDO 2FA, provenance attestations, and no install-time code.
- **Go's design is the safest default** and it is loved:
  - there are no install scripts;
  - module paths are domain names, so no squatting;
  - the checksum database is a public, append-only transparency log, so a registry or host can't serve different code to different users;
  - MVS gives reproducible builds without a solver, and upgrades only happen when someone asks for them;
  - govulncheck's reachability analysis cuts the noise that makes `npm audit` useless.
- The common complaints about Go are proxy caching surprises (a retracted tag stays forever) and the `v2` module path rule.
- **Cargo's experience is the most loved** (`cargo add`, workspaces, features). The complaints are `build.rs` and proc macros running arbitrary code, a flat namespace, and dependency trees of 300+ crates. cargo-vet is the best answer so far to "who reviewed this code": share audits instead of everyone re-reviewing.
- **Capabilities are Eider's advantage, and no other ecosystem has it:** a dependency's grant (`--uses net`) is checked against what the compiler says it uses (`eiderc caps`). A JSON library that suddenly needs `net` fails the build. This is the one defence against Shai-Hulud-style payloads that works without trusting the author.

**Eider.** eider-pkg (#10, #33). The order:
1. **Keep Go's model.** Packages are git repositories named by a URL-like path. MVS for resolution, which is simple, deterministic and explainable. No install-time code ever: comptime runs with no capabilities (README, "Comptime"), so keep it so.
2. **A checksum log before a registry.** `sum.eider.dev`, an append-only Merkle log (the same design as sumdb and Certificate Transparency) recording `module@version → hash of the tree`. eider-pkg verifies inclusion and caches the tree head, with `EIDER_NOSUMDB` patterns for private code. This gives most of the registry's security with none of its operations work.
3. **A proxy and index later** (`index.eider.dev`): the proxy caches git trees, so deleted repositories don't break builds; yanking is a flag, not a deletion.
4. **Capability diffs on update.** `eider-pkg update` prints, for every dependency, the capabilities gained since the locked version and refuses until the grant is widened. Show them in `eider-pkg tree --caps` and in the generated docs.
5. **`eider-pkg audit`.** An advisory database in OSV format (a git repository `eider-advisories`), matched with reachability: the compiler's call graph knows whether the vulnerable function is reachable, as govulncheck does.
6. **`eider-pkg vet`.** cargo-vet-style audit records (`supply-chain/audits.toml`) importable from trusted parties, with the capability set part of the audited criteria.
7. Provenance (Sigstore attestations tying a version to a CI build) when the registry exists.

## 7. Build, cross-compilation, reproducibility, deployment

| | Go | Zig | Rust | C (Eider today) |
|---|---|---|---|---|
| Cross-compile | `GOOS=linux GOARCH=arm64 go build`, no extra toolchain (pure Go; cgo breaks it) | `zig build -Dtarget=aarch64-linux-musl`; `zig cc` bundles libc headers/sources for ~40 targets | `rustup target add` + a linker (often `cross` / `cargo-zigbuild`) | needs a target C compiler and sysroot |
| Static binaries | default without cgo | default with musl | `x86_64-unknown-linux-musl` target | `-static` + musl |
| Reproducible | yes by default since Go 1.21 (toolchain itself bit-for-bit, `-trimpath`) | yes, aims for it | mostly (`--remap-path-prefix`) | depends on cc flags, `__DATE__`, paths |
| Containers | **ko** (build Go → OCI image with no Dockerfile, distroless base, SBOM), distroless/static | — | cargo-chef + distroless | — |
| Toolchain management | `toolchain` line in go.mod; `go` downloads the right version (1.21) | zigup/anyzig (community) | rustup + `rust-toolchain.toml` | — |
| Build tool deps | `tool` directive in go.mod (1.24) [V] | `build.zig` | `cargo install` (unpinned) | — |
| Embedded files | `//go:embed` | `@embedFile` | `include_bytes!` | — |

**Lessons.**
- Cross-compiling with one environment variable is one of Go's most loved features. Zig went further and made `zig cc` a drop-in cross C compiler that Rust and Go projects now use (cargo-zigbuild).
- Static binaries plus distroless/scratch images are the default way to deploy services. ko's "no Dockerfile" is loved.
- Reproducibility is cheap if designed in. Go made the whole toolchain reproducible and verifies it publicly; the requirements are no timestamps, path trimming, and sorted outputs.
- A pinned toolchain per project, downloaded automatically (Go 1.21 `toolchain`, `rust-toolchain.toml`), removes "works on my machine".

**Eider.**
- **Cross-compilation (#34) through `zig cc`.** Eider emits C11 and its core is one C file per OS, so `eiderc build --target aarch64-linux-musl` can drive `zig cc -target ...` when present (else `$CC`), with core objects cached per target. This is Eider's cheapest big win: the work Zig did is reused as a C compiler. Document `CC="zig cc -target x"` today as the stopgap.
- **`--static`** (musl).
- **Reproducibility.** Already a fixed point for the seed. Add path remapping (`-ffile-prefix-map`), no `__DATE__`, and a CI check that two builds are bit-identical (#33's acceptance criterion).
- **`eiderc embed`.** `const X: Bytes = comptime embed("file")`, which needs a narrow, read-only `fs` grant for comptime: one recorded exception.
- **Containers.** An `eider-pkg image` or `eiderc build --image` writing an OCI tarball from a static binary on `scratch`/distroless (ko-style, no Docker needed), with an SBOM from `eider.lock`. This could live in eider-pkg or a small `eider-ko` tool; start as a documented recipe.
- **Toolchain pin.** `eider = "0.1"` in `eider.toml` already records MAJOR.MINOR. A version manager (section 13) reads it.

## 8. Documentation

| | docs.rs + rustdoc | pkg.go.dev + go doc | HexDocs | Zig autodoc |
|---|---|---|---|---|
| Built for every published version automatically | yes | yes (proxy-triggered) | yes | no |
| Doc tests | yes (compiled, run by `cargo test`) | `Example` functions (compiled, output checked, shown with Run button) | doctests (IEx sessions) | `test` blocks shown |
| Search | in-page (`?search=`), type-based search (`-> String`) | site-wide, symbols | site-wide | in-page |
| Cross-package links | intra-doc links `[Type]` | automatic | automatic | — |
| Extra | feature flags, source view, all versions, badges | license detection, "imported by" counts, vuln badges | guides beside API | — |
| Love / hate | loved: always present; hated: no prose guides by default, feature-gated items | loved: plain; hated: weak prose formatting | loved: guides + API in one site | thin |

**Lessons.** Docs built automatically for every package version on one central site is what makes an ecosystem feel complete. Go's examples that run and print checked output (`// Output:`) give "Run" buttons and tests at once. Searching by type signature (rustdoc, Hoogle) is a power feature for typed languages.

**Eider.** eider-doc already has doc tests and a site.
- Add `// output:` checking on examples (Go style).
- Add the playground "Run" button once eider-play exists.
- Add intra-doc links `[Type]` and type-based search over the `eiderc doc --json` signatures.
- Show capabilities on every function and package page: "uses net, fs". A package page showing its whole capability footprint is unique and directly helps supply-chain review.
- Later, `docs.eider.dev`, built for every version recorded in the checksum log.

## 9. Editions, stability and compatibility

| | Rust | Go | Zig | Python |
|---|---|---|---|---|
| Promise | stability without stagnation; **editions** (2015, 2018, 2021, 2024) opt-in per crate, crates of different editions interoperate | **Go 1 compatibility promise** (2012): code that compiles keeps compiling and behaving | none before 1.0; breaks every release with migration notes | 2→3 split (the lesson of what not to do) |
| Breaking-change tool | `cargo fix --edition` automated migrations | `go fix`; **GODEBUG** settings keep old behaviour per module (`go` line in go.mod sets defaults, 1.21) | `zig fmt` rewrites some syntax | 2to3 |
| Testing changes | **crater**: compiles/tests all of crates.io before a change | Google's internal monorepo + ecosystem module checks | — | — |
| Loop-variable change | — | Go 1.22 changed `for` semantics, gated by the go.mod version | — | — |

**Lessons.**
- Editions plus automated fixes plus crater are the gold standard. A language can change keywords and defaults without splitting the ecosystem, because the edition is chosen per package and the compiler supports all of them.
- Go's GODEBUG shows a semantic change (the loopvar change) can be gated per module by its declared version, with a per-setting escape hatch.
- Python 3 shows what a split costs: about a decade.
- Being able to compile and test the whole ecosystem (crater) is what gives the confidence to make changes.

**Eider.** Eider is pre-1.0 and already has the pieces: `eider = "0.1"` in each manifest, `migrate-var` and `audit-refs` as migration tools, round-trip-verified fixes, and the deprecation path for `var` (#2).
- Formalise now: each manifest's `eider` field is the package's **edition**. The compiler keeps each removed behaviour for one MINOR with a warning and an `eiderc migrate --to 0.2` that applies every fix.
- After 1.0: editions as in Rust, and a crater-like `scripts/ecosystem.sh` that builds and tests every package in the checksum log (at first, the sibling repositories verify.sh already checks).
- Write the 1.0 compatibility promise early (Go 1 style). It is a selling point for services.

## 10. Error messages

| | Elm | Rust | Go | Zig |
|---|---|---|---|---|
| Style | conversational, first person, shows the code, suggests a fix, "hints" with links | structured: code (E0308), primary + secondary spans with labels, `help:`/`note:`, `--explain E0308`, machine-applicable suggestions | terse one-liners | terse, with reference traces |
| Machine-readable | `--report=json` | `--error-format=json`, used by rust-analyzer and cargo fix | — | — |
| Loved | widely cited as the best compiler errors ("Compiler errors for humans", 2015) | widely loved; borrow-checker errors hard but explained | fast to scan | — |
| Hated | none really | long cascades in generic/trait code; async errors | too little context | — |

**Lessons.**
- The best errors share four traits: the exact span with labels on related spans, one sentence of "why", a concrete fix (machine-applicable where possible), and a stable code with a long explanation.
- Type errors in generic code need the "expected X because of Y" chain (Rust's "required by this bound").
- Error cascades must be suppressed: report the cause, not the 40 errors that follow from it.

**Eider.** Eider already matches Rust's structure: stable codes, exact spans, `help:`, `--json`, round-trip-verified fixes. Add:
- **`eiderc explain E0308`** printing the long explanation from `docs/site/reference/errors.md`, which the analyzer shows on hover.
- Secondary labelled spans ("the reference taken here", "the write here" for E0308, which is a protection-rule error and the hardest one to understand).
- Track every message with the compile-fail suite (already done).
- Treat each confusing error report as a bug (Elm's rule) with an issue label `diagnostics`.

## 11. Debugging, observability and profiling

| | Go | Rust | Zig | JVM / .NET |
|---|---|---|---|---|
| Debugger | Delve (goroutine-aware), loved | gdb/lldb with pretty-printers (weak for enums, closures) | gdb/lldb | best in class |
| Race detection | `-race` (TSan) built in, loved | not needed (borrow checker); loom/Miri | — | — |
| Profiling | **pprof** built in: CPU, heap, goroutine, mutex, block; `net/http/pprof` endpoint for live services; PGO from profiles (1.21) | perf, samply, cargo-flamegraph (external) | Tracy integration | JFR, async-profiler |
| Tracing/metrics | OpenTelemetry Go SDK; `log/slog` (1.21); `runtime/trace` | `tracing` crate (spans + events), loved; OTel through tracing-opentelemetry | — | — |
| Continuous profiling | pprof format is the industry standard (Pyroscope, Parca, Grafana) | — | — | — |
| OTel status | traces, metrics, logs stable in most SDKs; OTLP the standard export; profiling signal in development | | | |

**Lessons.**
- A profiler that can be switched on in production (Go's pprof HTTP endpoint) is what service teams value most. Use the pprof protobuf format and all the visualisers work: Pyroscope, Parca, `go tool pprof`, speedscope.
- Debugging a language that compiles to C lives or dies on `#line` and pretty-printers. Nim and Vala users complain most about stepping through generated C.
- Go's `-race` flag is loved because it is one flag. Eider has TSan in verify, but users should get `eiderc run --race`.
- Rust's `tracing` (structured spans and events with fields, pluggable subscribers) is the model for structured logging and tracing together. OpenTelemetry's OTLP is the standard wire format, and W3C traceparent is the standard way to propagate context.

**Eider.**
- **#25 `#line`** first, P0.
- Then gdb/lldb pretty-printers for String, List, Map, Option/Result, records and enums: a Python script `eider-gdb.py` shipped in the toolchain and auto-loaded through `.debug_gdb_scripts`.
- `--sanitize=address|thread|undefined` flags in eiderc (today `EIDER_CFLAGS`), with sanitizer stack traces mapped to `.ei` through `#line`.
- **eider-profiler:** add **pprof export** (`eider-profiler export --pprof`) and a live endpoint in eider-http (`/debug/profile?seconds=30`), behind a grant, since it is a capability.
- Tracing and metrics in eider-http#5 as a small std-level `trace` API (spans with fields, events), with OTLP/HTTP+JSON export in a separate `eider-otel` package. It is JSON over HTTP, so no protobuf is needed at first. Prometheus text exposition for metrics.

## 12. Service essentials

| Need | Go | Rust | Java/Kotlin/.NET | Python/Node | Lesson |
|---|---|---|---|---|---|
| Config | env + flags; viper (hated: magic, huge); koanf | config, figment; serde into a struct | Spring `@ConfigurationProperties`; .NET options pattern, loved | pydantic-settings, loved | **Load into a typed record by derive**; layers: defaults < file < env < flags; fail at startup with all errors |
| Validation | go-playground/validator (struct tags) | validator, garde (derive) | Bean Validation (`@NotNull`) | **Pydantic**, Zod, loved | Validation rules as field attributes on the same types used for JSON/OpenAPI; errors list every field |
| Dependency injection | **none**: constructors + interfaces; wire/fx for the minority | none; pass `Arc<State>` (axum `State`) | Spring/Dagger/.NET DI built in; loved and hated (magic, startup cost) | FastAPI `Depends` | Explicit constructor wiring scales fine without a container; framework-level extractors (FastAPI, axum) give the useful part of DI |
| CLI parsing | `flag` (std, minimal), **cobra** (subcommands, completions; used by kubectl, gh), urfave/cli | **clap** derive, loved (help, completions, typo suggestions) | picocli | argparse, click, typer | Derive from a record; generated `--help`, shell completions, man page, typo suggestions |
| Logging | **`log/slog`** (1.21): structured, levels, JSON/text handlers, attrs, context | `tracing`, `log` | SLF4J + Logback | structlog, pino | Structured key/value, JSON lines in prod, human text in dev, a handler interface, request-scoped fields |
| Feature flags | OpenFeature SDKs | OpenFeature | OpenFeature, LaunchDarkly | OpenFeature | Vendor-neutral OpenFeature API; a library, not a language concern |
| Health checks | handlers by hand; gRPC health protocol | tower middleware | Spring Actuator `/health`, `/ready` | — | `/livez` and `/readyz` (Kubernetes convention), readiness tied to drain |
| Graceful shutdown | `http.Server.Shutdown(ctx)` + `signal.NotifyContext` | tokio `with_graceful_shutdown` | built in | — | SIGTERM → stop accepting → readiness false → drain with deadline → exit; must be the default |
| Background jobs | goroutines + errgroup; River (Postgres queue), asynq | tokio tasks; apalis | Quartz, Hangfire | Celery, Sidekiq (Ruby), BullMQ | In-process scheduled tasks in std; durable queues as a package on Postgres (River/Oban model, `SKIP LOCKED`) |
| Rate limiting | `golang.org/x/time/rate` (token bucket) | governor (GCRA), tower limit | Resilience4j | — | Token bucket/GCRA in the HTTP middleware; keyed by peer (eider-http#3) |
| Auth / JWT / OAuth | golang-jwt, x/oauth2, coreos/go-oidc | jsonwebtoken, oauth2, openidconnect | Spring Security (powerful, hated complexity) | authlib, passport | JWT verification with **algorithm pinning** (the `alg: none` / RS-HS confusion bugs), JWKS caching, OIDC discovery; avoid rolling password storage without argon2id |
| Templating | `html/template` (contextual auto-escaping, loved for safety) | askama (compile-time, typed), maud, minijinja | Thymeleaf | Jinja2 | **Compile-time checked, contextually auto-escaped templates** (askama + html/template) |

**Lessons.**
- The ecosystems people praise derive config, validation, CLI and serialization from **one typed record** with attributes: Pydantic, serde with clap derive and garde, .NET options. Eider's reflection (#20) and attributes (#19) are the key that opens all of them, so build them once and reuse them.
- Go shows services don't need a DI container: constructors, interfaces (`dyn Trait`, #18) and a `State` record are enough, and clearer. Eider's capabilities are already a form of explicit dependency passing.
- slog's design (a small std API with pluggable handlers) ended years of fragmentation in Go logging. Ship it in std early, before third-party loggers split the ecosystem.
- Graceful shutdown and health endpoints must be on by default in the HTTP framework, not a recipe.

**Eider.**

| Piece | Where |
|---|---|
| `std/log` (slog-like: levels, key/value fields, JSON and text handlers, context fields, a `Handler` trait) | eider-lang std (#24) |
| `std/config` (derive from a record: defaults, TOML file, env `APP_*`, flags; every error reported) | std for env and flags; the TOML source in eider-toml (#24) |
| `std/cli` (derive from a record: help, subcommands, completions, typo suggestions) | std, since the compiler and every tool need it; eider-pkg, eider-doc and eiderc can be rewritten on it |
| Validation attributes (`@validate(min = 1, max = 100, email)`) shared by JSON decode and OpenAPI schemas | eider-json (decode), eider-openapi (schema), the attribute vocabulary documented in one place |
| `/livez` and `/readyz`, SIGTERM drain on by default, rate limiting, CORS, request IDs | eider-http (#1, #3) |
| JWT verification, JWKS, OIDC client, argon2id password hashing | new repo `eider-auth` on core-crypto |
| Templating: compile-time typed templates with contextual escaping, by comptime | new repo `eider-template` (after #7, #20) |
| Background jobs: in-process scheduler in std (task groups, timers); a durable Postgres queue later | std runtime; `eider-jobs` after #36 |
| Feature flags: an OpenFeature-shaped trait | later, a package; not core |

## 13. Onboarding

| | rustup | Go | Zig | Bun/Deno | uv (Python) |
|---|---|---|---|---|---|
| Install | `curl ... \| sh`, rustup manages toolchains | tarball / installer; `go` self-updates per go.mod `toolchain` | tarball; community zigup/anyzig | one-line script, one binary | one-line script, loved |
| Version manager | rustup (toolchains, targets, components) | built into `go` (1.21) | community | built in (`bun upgrade`) | `uv python install` |
| New project | `cargo new`, `cargo init` | `go mod init` | `zig init` | `bun init`, `deno init` | `uv init` |
| Templates | cargo-generate (third-party) | `gonew` (experimental) | one template | `bun create <template>` | — |
| Tour | Rust Book, Rustlings | **Tour of Go** (in browser), loved | ziglings | — | — |

**Lessons.** Developers expect "install in one line, hello world in a minute". uv and Bun got popular partly by being a single static binary installed by one script. A toolchain that follows a pin in the project (Go 1.21) beats a separate version manager. Interactive exercises (Rustlings, ziglings, the Tour of Go) are where many developers start a language.

**Eider.**
- `install.sh` (curl | sh) that downloads the release bundle (#88 exists). Fallback: build from the seed with `cc`, which takes seconds, a selling point: "the whole bootstrap is one cc command".
- `eiderc` reads `eider = "x.y"` from the nearest `eider.toml` and re-execs the matching toolchain from `~/.eider/toolchains/` (Go 1.21 model), so no separate version manager is needed.
- `eider-pkg new <name> --template service|cli|lib|wasm`. A `service` template shows the conventions: eider-http, log, config, health, graceful shutdown, a test and a Dockerfile/OCI recipe.
- An "Eider tour" in eider-play, and `eider-lings` exercises later.

## 14. Community and governance for a new language

| | Rust | Go | Zig | Python | Gleam |
|---|---|---|---|---|---|
| Decisions | RFCs (rust-lang/rfcs), teams, FCP | proposal process (golang/proposal), review committee | BDFL (Andrew Kelley), ZSF non-profit | PEPs, Steering Council | BDFL, small core |
| Triage | labels, triagebot, rustbot | weekly proposal review minutes published | issue labels; "no LLM contributions" policy | — | — |
| Lessons | open process scales, but RFC threads can become exhausting | public minutes of proposal decisions are transparent and fast | a clear owner moves fast before 1.0 | — | a welcoming tone and a shipped 1.0 grew the community |

**Lessons.**
- Before 1.0, a single decision-maker with written, public reasoning (Zig, Gleam, early Go) moves fastest.
- Have a lightweight, written proposal format from the start, so decisions can be found later. Eider already records decisions (the C-numbered decisions in docs/compiler.md, the `Status: proposal, not decided` issues).
- A code of conduct, a CONTRIBUTING guide, "good first issue" labels and a changelog are basics expected on day one.

**Eider.**
- An `rfcs/` (or `docs/proposals/`) directory with a 1-page template (motivation, design, fit to the core rules, alternatives, migration). The existing issue labels: Status (proposal / planned / in progress) and Layer.
- A weekly triage note in the roadmap issue (#89).
- CONTRIBUTING.md, CODE_OF_CONDUCT.md, a SECURITY.md with a disclosure address (needed before any registry exists), and a CHANGELOG per release generated from merged PRs.
- Not before there are external contributors: teams and FCP.

---

## Recommendation for Eider, by repository

| Repository | Build |
|---|---|
| **eider-lang / compiler** | `eiderc fmt` (#9), `eiderc lint` (#85, expanded), `eiderc explain`, `#line` + `--sanitize`/`--race` flags (#25), `--target` via zig cc + `--static` (#34), `run/test --watch`, toolchain auto-selection from `eider.toml`, editions policy and `eiderc migrate` |
| **eider-lang / test driver + std/testing** | filters, subtests, continue-on-failure checks with diffs (#72), process isolation, `bench` blocks, `fuzz` blocks on packages/fuzz, `Arbitrary` derive + shrinking (after #20), snapshots, `--cover`, fake clock/capabilities (#30) |
| **eider-lang / std** | `std/log`, `std/config`, `std/cli` (#24), in-process scheduler |
| **eider-lang / packages/pkg (eider-pkg)** | MVS, checksum log client, capability diff on update, `audit` (OSV + reachability), `vet` audit records, `new --template` (#10, #33) |
| **eider-lang / packages/doc** | checked `// output:`, capability footprint per item and package, intra-doc links, type search, Run buttons |
| **eider-lang / repo root** | `install.sh`, CONTRIBUTING, SECURITY.md, `docs/proposals/` template |
| **eider-analyzer** | formatting, rename, signature help, inlay hints, fill-match-arms and other assists, test/bench/fuzz lenses, lint hints with fixes |
| **eider-profiler** | pprof export; live-profile protocol used by eider-http |
| **eider-http** | health endpoints and drain by default, rate limit (#3), tracing/metrics (#5), `/debug/profile`, test client (#30) |
| **eider-json / eider-openapi** | shared validation attribute vocabulary |
| **eider-toml** | config source for `std/config` |
| **new: eider-play** | sandboxed playground with share links (server first, wasm interpreter later) |
| **new: eider-sum** (service) and **eider-advisories** (data) | checksum transparency log; OSV advisory database |
| **new: eider-auth, eider-template, eider-otel** | JWT/OIDC/argon2id; compile-time typed templates; OTLP exporter |

---

## Ranked proposed features

Ranked by impact over effort, with dependencies that block taken into account. Impact and effort are H/M/L.

### 1. `eiderc fmt`: zero-config canonical formatter
Built on the compiler's lossless token stream, with no options, fixed width, and a trailing comma deciding multi-line layout. `--check` for CI. Fuzz-tested for idempotence and AST preservation (`packages/fuzz`). Used for analyzer formatting and to print every automated fix. Every successful modern language ships one from the start, and adding it later means a repository-wide reformat and arguments that a zero-config tool would have avoided.
- **Impact:** H. **Effort:** M.
- **Depends on:** #9 (this is its first criterion), #5. Applies to compiler/ via #95's migration.
- **Repo:** eider-lang (compiler); eider-analyzer for the LSP side.

### 2. `#line` debugging, pretty-printers and sanitizer flags
Emit `#line` (#25) so gdb/lldb, ASan/UBSan/TSan and trap backtraces point at `.ei` lines. Ship `eider-gdb.py`/lldb formatters for String, List, Map, Option, Result, records and enums. Add `--sanitize=address,undefined` and `--race` as first-class flags on `run`/`test` in place of `EIDER_CFLAGS`. Debugging generated C is the top complaint about compile-to-C languages, and this is also the base for coverage (feature 4).
- **Impact:** H. **Effort:** L–M.
- **Depends on:** #25, #80.
- **Repo:** eider-lang (compiler, toolchain bundle).

### 3. Cross-compilation through `zig cc`, static binaries, reproducible builds
`eiderc build --target <triple>` drives `zig cc -target` when available (else a configured `CC`), caches core objects per target, and adds `--static` (musl). Reproducibility comes from `-ffile-prefix-map` and a CI check that builds twice and compares. Going from Linux to arm64 or macOS in one flag reuses Zig's cross toolchain work at almost no cost and matches Go's most loved deployment feature.
- **Impact:** H. **Effort:** M.
- **Depends on:** #34, #57 (macOS/BSD core), #33 (reproducible-build criterion).
- **Repo:** eider-lang.

### 4. `eiderc test` as the one testing tool
Adds `--filter`, named subtests for table tests, `check` that keeps going with value diffs at the caller's line (#72), each test in its own process (a trap fails one test, not the run), `bench` blocks with a `B.Loop`-style API and saved comparisons, `fuzz` blocks driven by `packages/fuzz` with a corpus under `testdata/fuzz` and failures kept as regression cases, `--cover` mapped to `.ei` lines, and snapshot assertions accepted with `EIDER_BLESS=1`. One command is what makes Go code well tested.
- **Impact:** H. **Effort:** M–H (land in slices).
- **Depends on:** #30, #72, #25 (coverage), #54 (contained traps).
- **Repo:** eider-lang (driver, std/testing, packages/fuzz).

### 5. std service kit: `std/log`, `std/config`, `std/cli`
- `std/log`: slog-shaped, with structured fields, JSON-lines and text handlers, a `Handler` trait and context fields.
- `std/config`: a typed record filled from defaults, a TOML file, env and flags, with every error reported at startup.
- `std/cli`: argument parsing derived from a record, with help, subcommands, shell completions and "did you mean".

Shipping these in std before third-party alternatives exist avoids Go's ten years of logging fragmentation. The first versions can be written by hand; the derive versions follow #20.
- **Impact:** H. **Effort:** M.
- **Depends on:** #24, #17, #22, #19, #20 (derive), #18 (`Handler` trait).
- **Repo:** eider-lang std; the TOML source in eider-toml.

### 6. Supply chain: MVS plus a checksum transparency log plus capability diffs
- Resolve versions by minimal version selection.
- Run `sum.eider.dev`, an append-only Merkle log of `module@version → tree hash` that eider-pkg checks for inclusion.
- `eider-pkg update` fails when a dependency's capability use grows beyond its grant, and prints the diff.

Together these give Go-level integrity, with no install-time code (comptime has no capabilities). They also add a defence no other ecosystem has against Shai-Hulud-style compromises: a hijacked JSON library that starts using `net` fails the build. The log and the diffs come before any registry, since they need far less operations work.
- **Impact:** H. **Effort:** M (client), M (log service).
- **Depends on:** #10, #33, #60 (grants per module).
- **Repo:** eider-lang (packages/pkg); new eider-sum for the log service.

### 7. Analyzer: rename, signature help, inlay hints, fill-match-arms, test lenses
The next features users rank highest, in that order. Fill-match-arms reuses the exhaustiveness checker's list of missing patterns. "Add missing `uses`" already exists as a compiler fix. Run/debug lenses call `eiderc test --filter`. Lint results show as hints with quick fixes.
- **Impact:** H. **Effort:** M.
- **Depends on:** #9, #83, #94 (closed, keep in step), feature 1, #8 (latency).
- **Repo:** eider-analyzer.

### 8. `eiderc lint` with groups and `[lints]` in eider.toml
Lints run on the typed IR, use the compiler's diagnostic format and fix machinery, and fall into groups (correctness denied by default, suspicious, perf, style, pedantic). Levels are set in the manifest. The first lints are the ones only Eider can do: `unused_uses` (#85), needless `.copy()` and copy-on-write unshare in a loop (#11), an unused `Result`, and a blocking capability inside a lock scope. `eiderc test` runs the correctness group, the way `go test` runs vet.
- **Impact:** M–H. **Effort:** M.
- **Depends on:** #85, #11, #19 (`@allow`).
- **Repo:** eider-lang (compiler).

### 9. Onboarding: `install.sh`, a toolchain pinned by eider.toml, `eider-pkg new --template`
- A one-line installer for the release bundle (#88), with a fallback that builds from the seed.
- `eiderc` re-execs the toolchain matching the nearest `eider.toml`'s `eider = "x.y"` (Go 1.21 style), so no separate version manager is needed.
- Templates for `service`, `cli`, `lib` and `wasm`. The service template wires up eider-http, log, config, health, drain, a test and an OCI recipe, so the conventions show in the first project.
- **Impact:** H (adoption). **Effort:** L–M.
- **Depends on:** #88 (closed), #10, feature 5, eider-http#1.
- **Repo:** eider-lang (scripts, packages/pkg).

### 10. Production defaults in eider-http: health, drain, rate limit, pprof-compatible profiling
- `/livez` and `/readyz`.
- SIGTERM drain with a deadline, on by default, with readiness turning false at the start of the drain.
- Token-bucket and GCRA rate limiting keyed by peer.
- A gated `/debug/profile` endpoint backed by eider-profiler, which gains `export --pprof` so Pyroscope, Parca and `go tool pprof` work unchanged.
- **Impact:** H (services). **Effort:** M.
- **Depends on:** eider-http#1, #3, #5; #24; #87 (closed).
- **Repo:** eider-http, eider-profiler.

### 11. Playground with share links (eider-play), then Run buttons in docs
Start with a sandboxed server that runs `eiderc run` with no capability grants and short limits, with share links and a C-output view (like Rust's asm view). Once the comptime interpreter (#7) can run in wasm, move to a wasm interpreter in the browser, which also gives a REPL. eider-doc then adds a "Run" button to every example. The playground is how people try a language without installing it, and how they file bug reports.
- **Impact:** M–H. **Effort:** M (server), H (wasm).
- **Depends on:** #7, #84 (runtime sandbox).
- **Repo:** new eider-play; packages/doc.

### 12. Property testing by derive, with integrated shrinking
`Arbitrary` derived through comptime reflection for every record and enum (the same machinery as JSON derive), Hypothesis-style choice-sequence shrinking (so no hand-written shrinkers), a seed printed on failure, and failing inputs saved like fuzz cases. Property tests and fuzz targets share one API.
- **Impact:** M. **Effort:** M.
- **Depends on:** #20, #19, feature 4.
- **Repo:** eider-lang (std/testing, packages/fuzz).

### 13. `eider-pkg audit` (OSV and reachability) and `eider-pkg vet`
An `eider-advisories` repository in OSV format, matched only when the compiler's call graph shows that the affected function is reachable (govulncheck's noise fix). cargo-vet-style shared audit records include the audited capability set.
- **Impact:** M. **Effort:** M.
- **Depends on:** #33, feature 6.
- **Repo:** eider-lang (packages/pkg); new eider-advisories.

### 14. Editions policy, `eiderc migrate` and an ecosystem build check
- Declare `eider = "x.y"` in eider.toml to be the package's edition.
- Keep each removed behaviour for one MINOR with a warning, and apply all fixes with `eiderc migrate --to x.y`, generalising `migrate-var` and `audit-refs`.
- A crater-like `scripts/ecosystem.sh` builds and tests every sibling repository, and later every package in the log.
- Publish a 1.0 compatibility promise.
- **Impact:** M (H after 1.0). **Effort:** L–M.
- **Depends on:** #2, #95.
- **Repo:** eider-lang.

### 15. `eider-auth` and `eider-template`
- `eider-auth`: JWT verification with the algorithm pinned per key (no `alg` header trust), a JWKS cache, OIDC discovery and client, and argon2id hashing over core-crypto.
- `eider-template`: templates checked at compile time against typed records with contextual auto-escaping, combining askama and `html/template`, by comptime.
- **Impact:** M. **Effort:** M each.
- **Depends on:** #29, #7, #20, eider-http#1.
- **Repo:** new eider-auth, new eider-template.

Also worth doing, too small to rank:
- `eiderc explain <code>`, with the analyzer showing it on hover;
- `run --watch` / `test --watch`;
- `// output:` checks in eider-doc examples;
- the capability footprint on doc pages;
- CONTRIBUTING, SECURITY.md and a `docs/proposals/` template;
- fix #73 (eider-pkg errors on stdout), #67 (`run` can't pass args) and #79 (absolute std path in E0801). Users hit these papercuts in their first hour.

---

## Sources

**Checked this session [V]:**
- Go 1.24 release notes (`testing.B.Loop`, `tool` directives in go.mod): https://go.dev/doc/go1.24
- crates.io development update, July 2025 (Trusted Publishing, RFC 3691): https://blog.rust-lang.org/2025/07/11/crates-io-development-update-2025-07
- crates.io development update, January 2026 (Trusted Publishing Only mode): https://blog.rust-lang.org/2026/01/21/crates-io-development-update
- GitHub npm hardening after Shai-Hulud: https://www.helpnetsecurity.com/2025/09/23/npm-publishing-security-improvements/ ; https://sdtimes.com/security/github-details-upcoming-changes-to-improve-security-in-wake-of-shai-hulud-worm-in-npm-ecosystem/
- Shai-Hulud scope (500+ packages): https://versprite.com/resources/security/npm-supply-chain-attack-shai-hulud-worm-compromises-500-packages/

**Canonical references, not fetched this session [gk]:**
- **Formatting.** gofmt: https://go.dev/blog/gofmt ; Go Proverbs: https://go-proverbs.github.io/ ; rustfmt style editions: https://doc.rust-lang.org/edition-guide/rust-2024/rustfmt-style-edition.html ; Prettier rationale: https://prettier.io/docs/en/option-philosophy.html ; Ruff: https://docs.astral.sh/ruff/
- **Linting.** clippy: https://doc.rust-lang.org/clippy/ ; Cargo `[lints]`: https://doc.rust-lang.org/cargo/reference/manifest.html#the-lints-section ; go vet: https://pkg.go.dev/cmd/vet ; staticcheck: https://staticcheck.dev/ ; go/analysis: https://pkg.go.dev/golang.org/x/tools/go/analysis
- **Editors.** gopls v0.12 scalability: https://go.dev/blog/gopls-scalability ; rust-analyzer manual: https://rust-analyzer.github.io/manual.html
- **Playgrounds and watch mode.** Go playground: https://go.dev/play/ ; Rust playground: https://play.rust-lang.org/ ; Zig 0.14 release notes (`--watch`, fuzzing): https://ziglang.org/download/0.14.0/release-notes.html ; bacon: https://dioxus.github.io/bacon/ ; subsecond hot-patching: https://github.com/DioxusLabs/dioxus/tree/main/packages/subsecond ; Livebook: https://livebook.dev/
- **Testing.** Go fuzzing: https://go.dev/doc/security/fuzz/ ; testing/synctest: https://go.dev/blog/synctest ; coverage for integration tests: https://go.dev/doc/build-cover ; cargo-fuzz: https://rust-fuzz.github.io/book/ ; proptest: https://proptest-rs.github.io/proptest/ ; Hypothesis (and its shrinking design): https://hypothesis.readthedocs.io/ and https://hypothesis.works/articles/integrated-shrinking/ ; insta: https://insta.rs/ ; criterion: https://bheisler.github.io/criterion.rs/book/ ; nextest: https://nexte.st/ ; cargo-mutants: https://mutants.rs/ ; pytest parametrize: https://docs.pytest.org/en/stable/how-to/parametrize.html
- **Packages and supply chain.** Go module mirror and checksum DB: https://go.dev/blog/module-mirror-launch and https://go.dev/ref/mod#checksum-database ; MVS: https://research.swtch.com/vgo-mvs ; govulncheck: https://go.dev/blog/govulncheck ; cargo-vet: https://mozilla.github.io/cargo-vet/ ; RustSec / cargo-audit: https://rustsec.org/ ; npm provenance: https://docs.npmjs.com/generating-provenance-statements ; PyPI trusted publishing: https://docs.pypi.org/trusted-publishers/ ; PEP 740: https://peps.python.org/pep-0740/ ; Sigstore: https://www.sigstore.dev/ ; OSV: https://ossf.github.io/osv-schema/ ; SLSA: https://slsa.dev/ ; Zig build.zig.zon: https://ziglang.org/learn/build-system/
- **Builds and deployment.** zig cc: https://andrewkelley.me/post/zig-cc-powerful-drop-in-replacement-gcc-clang.html ; cargo-zigbuild: https://github.com/rust-cross/cargo-zigbuild ; reproducible Go toolchains: https://go.dev/blog/rebuild ; Go toolchains: https://go.dev/doc/toolchain ; ko: https://ko.build/ ; distroless: https://github.com/GoogleContainerTools/distroless ; reproducible-builds.org: https://reproducible-builds.org/
- **Docs.** docs.rs: https://docs.rs/about ; pkg.go.dev: https://pkg.go.dev/about ; Go testable examples: https://go.dev/blog/examples ; rustdoc doc tests: https://doc.rust-lang.org/rustdoc/write-documentation/documentation-tests.html
- **Stability.** Rust editions: https://doc.rust-lang.org/edition-guide/ ; crater: https://github.com/rust-lang/crater ; Go 1 compatibility: https://go.dev/doc/go1compat ; GODEBUG: https://go.dev/doc/godebug ; loopvar change: https://go.dev/blog/loopvar-preview
- **Error messages.** Elm, "Compiler errors for humans": https://elm-lang.org/news/compiler-errors-for-humans ; rustc diagnostics guide: https://rustc-dev-guide.rust-lang.org/diagnostics.html
- **Debugging, profiling, observability.** Delve: https://github.com/go-delve/delve ; pprof: https://github.com/google/pprof ; Go PGO: https://go.dev/doc/pgo ; Go race detector: https://go.dev/doc/articles/race_detector ; OpenTelemetry status: https://opentelemetry.io/status/ ; W3C Trace Context: https://www.w3.org/TR/trace-context/ ; tracing: https://docs.rs/tracing ; Prometheus exposition: https://prometheus.io/docs/instrumenting/exposition_formats/
- **Service libraries.** slog: https://go.dev/blog/slog ; clap: https://docs.rs/clap ; cobra: https://cobra.dev/ ; Pydantic: https://docs.pydantic.dev/ ; pydantic-settings: https://docs.pydantic.dev/latest/concepts/pydantic_settings/ ; garde: https://docs.rs/garde ; OpenFeature: https://openfeature.dev/ ; x/time/rate: https://pkg.go.dev/golang.org/x/time/rate ; governor: https://docs.rs/governor ; JWT best current practice, RFC 8725: https://www.rfc-editor.org/rfc/rfc8725 ; html/template: https://pkg.go.dev/html/template ; askama: https://docs.rs/askama ; River: https://riverqueue.com/ ; Oban: https://hexdocs.pm/oban ; Kubernetes probes: https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/
- **Onboarding and governance.** rustup: https://rustup.rs/ ; uv: https://docs.astral.sh/uv/ ; Tour of Go: https://go.dev/tour/ ; Rustlings: https://rustlings.rust-lang.org/ ; Rust RFCs: https://github.com/rust-lang/rfcs ; Go proposals: https://github.com/golang/proposal ; Zig Software Foundation: https://ziglang.org/zsf/

**Eider repository files read:** README.md, LAYERS.md, docs/design/roadmap.md, docs/research/rust.md, docs/research/zig.md, docs/site/SUMMARY.md, docs/site/tooling/{compiler,editors,eider-doc,eider-pkg,profiler,releases}.md, docs/site/guide/testing.md. Issues: klxdev/eider-lang #1–#97 (list), the bodies of #9, #10, #24, #25, #30, #33, #34 and #85; eider-http #1–#5, eider-rpc #1, eider-openapi #1–#2, eider-json #1. eider-toml, eider-markdown, eider-analyzer and tree-sitter-eider have no issues.
