# Services

This guide builds two small network services step by step: a JSON-RPC 2.0 service and a
REST service with an OpenAPI 3.1 description. Both use the packages in this repository:
`packages/http` (HTTP/1.1 server and client, router, JSON-RPC, middleware) and
`packages/openapi` (operations, validation, `/openapi.json`), on std's sockets, deadlines
and thread pool.

Two complete services go further than this page, and are worth reading next to it:

- [`examples/kvstore`](../../../examples/kvstore/kv.ei): a key-value store and a calculator
  over JSON-RPC, a REST route, graceful shutdown on SIGTERM, an end-to-end test.
- [`examples/todo`](../../../examples/todo/todo.ei): a CRUD REST service described by
  OpenAPI, with bearer tokens, CORS, request ids, an access log, Prometheus metrics, a
  per-route timeout, and an end-to-end test that checks the served description against a
  golden file.

> **Note:** The code blocks on this page are marked `eider,ignore`: they import packages
> (`http`, `openapi`, `json`), and the docs' tests run each block alone, with no
> `eider.toml` or `eider.lock` to find them. Each one was built and run in a package set up
> as below, and the outputs shown are what it printed. The two examples above are tested on
> every `scripts/verify.sh` run.

## What a service is made of

| Piece | Module | |
|---|---|---|
| `http.Request`, `http.Response`, `http.Handler` | `http` | a handler is a plain function value, `fn(http.Request) -> http.Response` |
| the server | `http/server` | `server.listen(addr, cfg)` then `srv.serve(handler, token)`: a pool of worker threads, deadlines on every read and write, limits on heads and bodies, graceful shutdown when the token is cancelled |
| the router | `http/router` | `r.get("/items/:id", h)`, `r.post(...)`; 404 and 405 with `Allow` |
| JSON-RPC 2.0 | `http/jsonrpc` | a method table, typed parameters, batches and notifications, the HTTP handler and a client |
| OpenAPI | `openapi`, `openapi/schema` | one operation value drives routing, validation and the served description |
| middleware | `http/middleware`, `http/metrics`, `http/problem` | request ids, access logs, timeouts, CORS, bearer and Basic auth, metrics, problem+json errors |

The server speaks plain HTTP. Run it on loopback or a private interface behind a
TLS-terminating proxy; TLS 1.3 written in Eider is planned (repository
`docs/design/roadmap.md`, P1.4).

## A JSON-RPC service, step by step

### 1. The package

```sh
scripts/eider-pkg -C notes init
cd notes
$EIDER/scripts/eider-pkg add http --path $EIDER/packages/http --uses net,io,clock,threads
```

The `http` package needs `net`, `io`, `clock` and `threads` for its server and client, and
you grant them explicitly ([Capabilities](capabilities.md)):

```toml
[package]
name = "notes"
version = "0.1.0"
main = "main.ei"

[deps.http]
path = "/path/to/eider-lang/packages/http"
uses = ["net", "io", "clock", "threads"]
```

### 2. The state

The server runs handlers on several worker threads at once, so shared state goes in a
lock. `std/sync`'s `Lock[T]` is shared by every copy, and `with(f)` runs `f(state) ->
(new state, result)` as one critical section:

```eider,ignore
// notes.ei
import "std/sync"
import "http"
import "http/router"
import "http/jsonrpc"

/// The state, shared by every worker thread: copies of a Lock are the same lock.
pub type Store = { st: sync.Lock[List[List[u8]]] }

pub fn store() -> Store { Store(sync.lock(List.new())) }

impl Store {
    /// Adds a note and returns its id.
    fn add(self, text: List[u8]) -> i64 {
        self.st.with(|notes: List[List[u8]]| -> (List[List[u8]], i64) {
            let mut all = notes.copy()
            all.push(text)
            let id = all.len() as i64
            (all, id)
        })
    }

    /// The note with this id, if there is one.
    fn get(self, id: i64) -> Option[List[u8]] {
        self.st.with(|notes: List[List[u8]]| -> (List[List[u8]], Option[List[u8]]) {
            if id < 1 || id > notes.len() as i64 { return (notes, None) }
            let text = notes[(id - 1) as usize]
            (notes, Some(text))
        })
    }
}
```

Text on the wire is bytes (`List[u8]`), which is what the http and json packages speak
today.

### 3. The methods

A method is `fn(jsonrpc.Params) -> Result[List[u8], jsonrpc.Error]`, its result as JSON
text. `add_typed` composes three functions: one that reads the parameters into a value, the
service logic, and one that writes the result. The logic is then plain values in, a value
or an error out:

```eider,ignore
fn text_arg(p: jsonrpc.Params) -> Result[List[u8], jsonrpc.Error] {
    p.at_most(1)?
    p.str(0, "text")           // positional [text] or named {"text": ...}
}

fn id_arg(p: jsonrpc.Params) -> Result[i64, jsonrpc.Error] {
    p.at_most(1)?
    p.int(0, "id")
}

fn note_or_null(v: Option[List[u8]]) -> List[u8] {
    match v {
        Some(t) => jsonrpc.string(t)
        None => jsonrpc.nothing()
    }
}

/// The JSON-RPC methods: notes.add(text) -> id, notes.get(id) -> text or null.
pub fn rpc(s: Store) -> jsonrpc.Table {
    let mut t = jsonrpc.table()
    t.add_typed("notes.add", text_arg, jsonrpc.int, |text: List[u8]| -> Result[i64, jsonrpc.Error] {
        if text.len() == 0 { return Err(jsonrpc.error(-32000, "a note can't be empty")) }
        Ok(s.add(text))
    })
    t.add_typed("notes.get", id_arg, note_or_null, |id: i64| -> Result[Option[List[u8]], jsonrpc.Error] {
        Ok(s.get(id))
    })
    t
}
```

A missing or wrongly typed parameter is answered with `-32602 Invalid params` and the
reason, before your function runs. The decoders and encoders are written by hand today;
deriving them from the types is planned (JSON derive, roadmap P0.10).

### 4. Routes

```eider,ignore
/// POST /rpc for the methods, GET /health for probes.
pub fn app(s: Store) -> http.Handler {
    let mut r = router.new()
    r.post("/rpc", jsonrpc.handler(rpc(s)))
    r.get("/health", |q: http.Request| -> http.Response { http.text(200, "ok") })
    router.handler(r)
}
```

`jsonrpc.handler` checks the method (`POST`) and content type (`application/json`) and
answers `204` for a request with only notifications. Route patterns take parameters
(`/notes/:id`, read with `q.param("id")`) and a final `*rest`.

### 5. The server

```eider,ignore
// main.ei
import "std/net"
import "std/task"
import "http/server"
import "notes.ei"

fn main() uses io, net, clock, threads {
    let srv = match server.listen(net.ipv4(127, 0, 0, 1, 8080), server.config()) {
        Ok(s) => s
        Err(e) => {
            print(e)
            return
        }
    }
    print("listening on 127.0.0.1:8080")
    let tok = task.root()          // cancel it to shut the server down
    match srv.serve(notes.app(notes.store()), tok) {
        Ok(st) => print(st.requests)
        Err(e) => print(e)
    }
}
```

`serve` blocks until the token is cancelled, then finishes the requests in flight, closes
idle connections and returns the counts. `server.config()` has the defaults (16 workers, a
queue of 64 connections, 5 s idle, 10 s read and write timeouts, 1 MiB bodies); change its
fields before `listen` (`cfg.workers = 4`).

Build it, start it, and call it from another terminal:

```sh
$EIDER/scripts/ei build main.ei -o notes-server
./notes-server
```

```text
$ curl -s localhost:8080/rpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"notes.add","params":["buy milk"],"id":1}'
{"jsonrpc":"2.0","result":1,"id":1}
$ curl -s localhost:8080/rpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"notes.get","params":{"id":1},"id":2}'
{"jsonrpc":"2.0","result":"buy milk","id":2}
$ curl -s localhost:8080/rpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"notes.get","params":[9],"id":3}'
{"jsonrpc":"2.0","result":null,"id":3}
$ curl -s localhost:8080/rpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"notes.add","params":[""],"id":4}'
{"jsonrpc":"2.0","error":{"code":-32000,"message":"a note can't be empty"},"id":4}
$ curl -s localhost:8080/rpc -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"notes.add","params":[1, 2],"id":5}'
{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params","data":"too many parameters"},"id":5}
```

Batches (a JSON array of calls) and notifications (calls without an `id`, never answered)
work as the specification says.

### 6. Shutting down on a signal

To stop cleanly on SIGTERM or Ctrl-C, watch the signals and cancel the token from a
thread. This is the code from `examples/kvstore/main.ei`:

```eider,ignore
    let tok = task.root()
    signal.watch(signal.TERM).unwrap()
    signal.watch(signal.INT).unwrap()
    let sig_fd = signal.events_fd().unwrap()
    let t = tok
    let waiter = spawn(|| -> i32 {
        let mut going = true
        while going {
            match fd.wait_ready(sig_fd, fd.READY_READ, t.deadline()) {
                Ok(true) => {
                    if signal.pending().unwrap_or(List.new()).len() > 0 { going = false }
                }
                Ok(false) => { going = false }
                Err(e) => { going = false }
            }
        }
        t.cancel()
        0
    })
    // ... srv.serve(handler, tok) as above, then:
    let z = waiter.join()
```

### 7. An end-to-end test

Start the server on port 0 (any free port), call it with `http/client` over loopback,
then cancel the token. No fixed ports and no sleeps, so the test is reliable in parallel
runs:

```eider,ignore
// tests/e2e_test.ei (needs `eider-pkg add json --path ...` too)
import "std/net"
import "std/task"
import "std/time"
import "json"
import "http/server"
import "http/client"
import "http/jsonrpc"
import "../notes.ei"

fn show(r: Result[jsonrpc.Reply, String]) uses io {
    match r {
        Ok(jsonrpc.Value(d, n)) => print(String.from_bytes(json.write(d, n)).unwrap())
        Ok(jsonrpc.Fault(e)) => print(e.code)
        Err(e) => print(e)
    }
}

fn main() uses io, net, clock, threads {
    let dl = time.after_ms(10000)
    let srv = server.listen(net.ipv4(127, 0, 0, 1, 0), server.config()).unwrap()
    let addr = srv.addr()
    let tok = task.root()
    let t = tok
    let h = notes.app(notes.store())
    let running = spawn(|| -> server.Stats { srv.serve(h, t).unwrap() })

    let mut c = client.connect(addr, dl).unwrap()
    show(jsonrpc.call(inout c, "/rpc", "notes.add", String.from("[\"buy milk\"]").bytes(), 1, dl))
    show(jsonrpc.call(inout c, "/rpc", "notes.get", String.from("[1]").bytes(), 2, dl))
    show(jsonrpc.call(inout c, "/rpc", "notes.add", String.from("[\"\"]").bytes(), 3, dl))

    tok.cancel()                   // graceful shutdown
    print(running.join().requests)
}
```

```text
1
"buy milk"
-32000
3
```

[`examples/kvstore/tests/e2e_test.ei`](../../../examples/kvstore/tests/e2e_test.ei) does
the same with batches, notifications, the REST route and four concurrent clients from a
task group.

## A REST service with OpenAPI, step by step

packages/openapi registers a route **together with its description**: one operation value
gives the router its pattern, validates parameters and bodies before your handler runs, and
produces `GET /openapi.json`. So the documentation can't drift from the code.

### 1. The package

```sh
$EIDER/scripts/eider-pkg add http --path $EIDER/packages/http --uses net,io,clock,threads
$EIDER/scripts/eider-pkg add openapi --path $EIDER/packages/openapi
```

openapi itself is pure, so it is granted nothing.

### 2. State, schemas and encoders

```eider,ignore
// items.ei
import "std/sync"
import "http"
import "http/problem"
import "openapi"
import "openapi/schema"

pub type Item = { id: i64, name: List[u8] }

type Db = { next: i64, items: Map[i64, Item] }

pub type Store = { st: sync.Lock[Db] }

pub fn store() -> Store { Store(sync.lock(Db(1, Map.new()))) }

impl Store {
    fn create(self, name: List[u8]) -> Item {
        self.st.with(|d: Db| -> (Db, Item) {
            let mut t = d.copy()
            let item = Item(t.next, name)
            t.items.insert(t.next, item)
            t.next += 1
            (t, item)
        })
    }

    fn get(self, id: i64) -> Option[Item] {
        self.st.with(|d: Db| -> (Db, Option[Item]) (d, d.items.get(id)))
    }
}

// schemas, decoders and encoders: written by hand until JSON derive
fn item_schema() -> schema.Schema {
    let mut s = schema.object().closed()
    s = s.field("id", schema.integer().format("int64").min(1))
    s.field("name", schema.string().min_length(1).max_length(100))
}

fn new_item_schema() -> schema.Schema {
    schema.object().closed().field("name", schema.string().min_length(1).max_length(100))
}

fn item_json(t: Item) -> List[u8] { openapi.obj().int("id", t.id).str("name", t.name).done() }

fn decode_id(i: openapi.Input) -> Result[i64, problem.ApiError] { i.path_int("id") }

fn decode_name(i: openapi.Input) -> Result[List[u8], problem.ApiError] { i.str("name") }
```

Schemas are the subset of JSON Schema 2020-12 that service types need: objects
(`field` required, `prop` optional, `closed()` refuses unknown members), arrays, strings
with lengths and enums, integers with bounds, booleans, `nullable()`, and named
components that become `$ref`s.

### 3. Operations

```eider,ignore
/// The service: GET /items/{id}, POST /items, and GET /openapi.json.
pub fn app(s: Store) -> http.Handler {
    let mut svc = openapi.service("Items API", "1.0.0")
    let item = svc.component("Item", item_schema())

    let mut get = openapi.op("GET", "/items/{id}").operation_id("getItem").summary("Get an item")
    get = get.path_param("id", schema.integer().min(1))
    get = get.returns(200, "The item", item).fails(404, "No such item")
    svc.add(get, openapi.typed(decode_id, |id: i64| -> Result[Item, problem.ApiError] {
        s.get(id).ok_or(problem.not_found("no such item"))
    }, item_json))

    let mut create = openapi.op("POST", "/items").operation_id("createItem").summary("Create an item")
    create = create.body(new_item_schema(), "The new item").returns(201, "The item", item)
    svc.add(create, openapi.typed(decode_name, |name: List[u8]| -> Result[Item, problem.ApiError] {
        Ok(s.create(name))
    }, item_json))

    svc.handler()
}
```

`openapi.typed(decode, f, encode)` is the handler: `decode` reads the validated request,
`f` is the logic (no HTTP in it), `encode` writes the result. The answer is the
operation's first 2xx status, or the error's `application/problem+json` (RFC 9457).
`svc.add` panics at start-up on a programming error, such as a `{name}` in the path
without a `path_param`, or two operations with the same id.

> **Note:** Builders are written as reassignments (`get = get.path_param(...)`) because the
> committed seed can't continue a method chain on the next line. Lines starting with `.`
> continue the expression in the compiler sources, and will work after the next seed
> regeneration.

### 4. Run it

`main.ei` is the same as the JSON-RPC service's, with `items.app(items.store())`. Then:

```text
$ curl -s localhost:8080/items -H 'Content-Type: application/json' -d '{"name": "lamp"}'
{"id":1,"name":"lamp"}
$ curl -s localhost:8080/items/1
{"id":1,"name":"lamp"}
$ curl -s localhost:8080/items/2
{"type":"about:blank","title":"Not Found","status":404,"detail":"no such item"}
$ curl -s localhost:8080/items -H 'Content-Type: application/json' -d '{"name": "", "color": "red"}'
{"type":"about:blank","title":"Bad Request","status":400,"detail":"the request does not match the API description","errors":[{"in":"body","pointer":"#/name","detail":"must not be empty"},{"in":"body","pointer":"#/color","detail":"is not allowed here"}]}
$ curl -s localhost:8080/items -d 'x'
{"type":"about:blank","title":"Unsupported Media Type","status":415,"detail":"the body must be application/json"}
$ curl -s localhost:8080/items/abc
{"type":"about:blank","title":"Bad Request","status":400,"detail":"the request does not match the API description","errors":[{"in":"path","name":"id","detail":"must be an integer"}]}
$ curl -s localhost:8080/openapi.json
{"openapi":"3.1.0","info":{"title":"Items API","version":"1.0.0"},"paths":{"/items/{id}":{"get":{"summary":"Get an item", ...
```

The served description includes the 400 and 415 responses the validation can give, and a
`Problem` component for them.

## Going further: what examples/todo adds

[`examples/todo/todo.ei`](../../../examples/todo/todo.ei) and
[`main.ei`](../../../examples/todo/main.ei) build on the same pieces:

- **Authentication.** `svc.bearer_auth("bearerAuth", check)` and `.secured("bearerAuth")`
  on the write operations: a missing or unknown token is 401 with `WWW-Authenticate`.
  `middleware.token_table` compares tokens in constant time.
- **Limits and timeouts per route.** `.max_body(4096)` (413 above it) and
  `svc.add_with(op, layer, h)` with `middleware.timeout(time.seconds(2), pool, h)`: 503 if
  the answer isn't ready by the deadline.
- **Middleware around the whole service**, outermost first: `request_id` (keeps a
  client's `X-Request-Id` or makes one), `access_log` (one JSON line per request, never
  headers or bodies), `metrics.wrap` (Prometheus counters and a latency histogram served at
  `/metrics`), `problems` (the router's own 404 and 405 as problem+json) and `cors`.
- **Query parameters and partial updates**: `list.query("done", schema.boolean(), ...)`,
  a PATCH whose body distinguishes a missing field from `null`.
- **An end-to-end test** that checks CRUD, every error status, CORS, concurrency, metrics,
  the access log, and the served `/openapi.json` against `tests/openapi.golden.json`.

## Limits to know

- One OS thread serves one connection at a time: `cfg.workers` bounds concurrency, and
  connections beyond the queue get 503. Stackless tasks, which lift this without changing
  `serve`'s signature, are planned.
- A trap in a handler (an overflow, an index out of bounds, `unwrap` on `None`) ends the
  process. Validate input before arithmetic; examples/kvstore checks for overflow before
  adding. Containing traps is planned.
- A handler that blocks forever holds a worker forever; `middleware.timeout` bounds the
  answer, not the thread. Pass `req.deadline` down to anything that waits.
- Bodies are read whole (up to `Limits.max_body`, 1 MiB by default); streaming bodies are
  planned. Floats aren't in the language yet, so there are no `number` schemas.
- No TLS in the server: put it behind a proxy.

The repository's `docs/services.md` and `docs/openapi.md` describe the architecture, the
limits and defaults, and the security posture in detail.
