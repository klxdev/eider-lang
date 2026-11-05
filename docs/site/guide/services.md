# Building services

Eider's service libraries live in repositories of their own, next to the toolchain: this
repository keeps the language and the tools an ecosystem needs (the compiler, core, std,
eider-pkg, eider-doc), and frameworks and general libraries are ordinary packages you
depend on by git. Each has its README, its design notes, a step-by-step guide and a
complete example with an end-to-end test.

| Repository | Package | What |
|---|---|---|
| [eider-http](https://github.com/klxdev/eider-http) | `http` | HTTP/1.1: a strict incremental parser, a server with deadlines, back-pressure and graceful shutdown, a client, a router, middleware (request ids, access logs, problem+json errors, body limits and timeouts per route, CORS, bearer and Basic auth), Prometheus metrics, and the profiler's labels and endpoints |
| [eider-rpc](https://github.com/klxdev/eider-rpc) | `rpc` | JSON-RPC 2.0 over eider-http: a method table, typed parameters, batches and notifications, the HTTP handler and a client; `examples/kvstore` |
| [eider-openapi](https://github.com/klxdev/eider-openapi) | `openapi` | OpenAPI 3.1 services: one operation value drives the route, validation (problem+json) and `/openapi.json`; typed handlers; `examples/todo` |
| [eider-json](https://github.com/klxdev/eider-json) | `json` | RFC 8259 JSON: an arena value tree, strict parsing with positions, writing, and typed values with derived codecs ([Deriving JSON](json.md)) |
| [eider-toml](https://github.com/klxdev/eider-toml) | `toml` | the TOML subset of `eider.toml` and `eider.lock` |
| [eider-markdown](https://github.com/klxdev/eider-markdown) | `markdown` | a CommonMark subset plus GFM tables, rendered to safe HTML |

The guides:

- a JSON-RPC service step by step: eider-rpc's `docs/guide.md`;
- a REST service with an OpenAPI description step by step: eider-openapi's `docs/guide.md`;
- the design of the HTTP layer (the concurrency model, every limit and default, the security
  posture, the known gaps): eider-http's `docs/services.md`.

## Depending on them

A service declares the libraries in its `eider.toml` and grants each what it uses
([Capabilities](capabilities.md)):

```toml
[package]
name = "notes"
version = "0.1.0"
eider = "0.7"
main = "main.ei"

[deps.http]
git = "https://github.com/klxdev/eider-http.git"
version = "0.1.0"
uses = ["net", "io", "clock", "threads"]

[deps.rpc]
git = "https://github.com/klxdev/eider-rpc.git"
version = "0.1.0"
uses = ["net", "io", "clock"]
```

`eider-pkg fetch` resolves them (eider-json comes along as their dependency) and writes
`eider.lock`; the code imports them by name, `import http.server`,
`import rpc.jsonrpc`. Before 1.0 each library's MAJOR.MINOR is the toolchain's (here
0.1), so a release of the library goes with a release of Eider.

To work offline, or on a checkout of a library with your own changes, name the checkouts in
`EIDER_PKG_OVERRIDE` when you fetch:

```sh
EIDER_PKG_OVERRIDE=http=../eider-http,rpc=../eider-rpc,json=../eider-json eider-pkg fetch
```

([eider-pkg](../tooling/eider-pkg.md#overriding-a-git-dependency) says how it works.)

## Logging, configuration and shutdown

Logging is a library, [eider-logging](https://github.com/klxdev/eider-logging) (it was `std/log`
up to Eider 0.7.2); configuration and shutdown are std modules every service wants, so that they
look the same in each one.

**`eider-logging`** (`import logging`) writes one JSON object per line to stderr (or stdout), with
a level, fields that every record of a logger carries, and typed fields per record. A level `Off`
silences a logger, a memory sink (`logging.memory()`, `logging.to_memory`) keeps the records for a
test, and `with_context` adds fields such as trace ids to every record:

```eider,ignore
import logging

fn main() uses io, clock {
    let lg = logging.new(logging.Info).with(logging.fields().text("service", String.from("kv")))
    lg.info("listening", logging.fields().text("addr", String.from(":8080")).int("workers", 4))
    lg.debug("not written", logging.fields())
}
```

```text
{"time":"2026-11-01T12:34:56.789Z","level":"info","msg":"listening","service":"kv","addr":":8080","workers":4}
```

**`std/config`** layers defaults, a TOML file, the environment and flags (each over the one
before) and reads typed values with errors that name the key, the text and the layer. The
defaults are the schema: the environment and the flags can only set keys that have one, and an
unknown flag is an error.

```eider,ignore
import std.config

fn load(toml: String, args: List[List[u8]]) -> Result[Settings, String] uses io {
    let c = config.new().default("addr", ":8080").default("workers", "4").default("grace", "10s")
    let c = c.toml(toml)?.env("APP")?.flags(args)?          // APP_WORKERS, --workers=8
    Ok(Settings(c.str("addr")?, c.int("workers")?, c.duration_ms("grace")?))
}
```

(The TOML read is the part services use: `key = value`, `[table]`, strings, numbers,
booleans; arrays and inline tables are an error. The eider-toml library parses all of TOML.
Filling a record by field name waits for reflection to reach std.)

**`std/service`** drains on SIGTERM and SIGINT: `cancel_on_term(token)` starts a watcher that
cancels a [`std/task`](concurrency.md) token when one arrives, so everything under it (a task
group, a server loop waiting on the token) finishes what it has and returns; and the exit codes
of `sysexits.h` (`EX_CONFIG`, `EX_UNAVAILABLE`, ...) for what `main` reports.

```eider,ignore
let root = task.root()
let watcher = service.cancel_on_term(root)?
serve(root)                    // returns once `root` is cancelled
let signal = watcher.join()    // 15 for SIGTERM, 2 for SIGINT
```

## What to know before you start

- The server speaks plain HTTP: run it on loopback or a private interface behind a
  TLS-terminating proxy. TLS 1.3 written in Eider is planned.
- One OS thread serves one connection at a time, from a fixed pool; serving a connection
  per task, which lifts this without changing the server's API, is the next step
  (docs/design/lightweight-tasks.md, M4).
- A trap in a handler ends the process ([Errors](errors.md)): validate input before
  arithmetic and indexing.
- Shared state goes in a `std/sync` `Lock[T]` ([Concurrency](concurrency.md)): handlers run
  on several worker threads at once.
- To profile a service, build it with `--profile` and use eider-http's `http/profiling`
  ([eider-profiler](../tooling/profiler.md)).
