# Services (layer/services)

What a networked Eider service is built from today: HTTP/1.1 and JSON-RPC 2.0 in
`packages/http`, on std's sockets, deadlines, tokens and thread pool (docs/runtime.md), and
`packages/json`. This is the first piece of the services layer (roadmap.md, P0.12 and the
first milestone of P1.1); decisions are C40 onwards in docs/decisions.md.

```
import "std/net"
import "std/task"
import "http"                 // Request, Response, headers, limits, writing messages
import "http/server"
import "http/router"
import "http/jsonrpc"

fn main() uses io, net, clock, threads {
    var rpc = jsonrpc.table()
    rpc.add("math.add", |p: jsonrpc.Params| -> Result[List[u8], jsonrpc.Error] {
        Ok(jsonrpc.int(p.int(0, "a")? + p.int(1, "b")?))
    })
    var r = router.new()
    r.post("/rpc", jsonrpc.handler(rpc))
    r.get("/users/:id", |q: http.Request| -> http.Response {
        http.respond(200, "text/plain", q.param("id").unwrap())
    })
    let srv = server.listen(net.ipv4(127, 0, 0, 1, 8080), server.config()).unwrap()
    let tok = task.root()                       // cancel it (e.g. on SIGTERM) to shut down
    let stats = srv.serve(router.handler(r), tok).unwrap()
}
```

`examples/kvstore` is a complete service (a key-value store and a calculator over JSON-RPC,
a REST route, graceful shutdown on SIGTERM), with an end-to-end test.

## Modules

| Module | What | Capabilities |
|---|---|---|
| `http` (http.ei) | `Request`, `Response`, `Header`, `Limits`; header lookup (case-insensitive), query parameters, percent-decoding; `write_request`, `write_response`, `chunked`; status reasons; IMF-fixdate | none |
| `http/parse` | the incremental parser for requests and responses | none |
| `http/server` | `listen`, `Server.serve(handler, token)`, `Config`, `Stats` | `net, io, clock, threads` |
| `http/client` | `connect`, `Conn.request`, `fetch`, `get`, `post` | `net, io, clock` |
| `http/router` | method + path patterns with parameters, 404/405 | none |
| `http/jsonrpc` | JSON-RPC 2.0: a dispatch table, typed methods, the HTTP handler, a client call | none (`net, io, clock` for the client calls) |
| `http/sock` | sending before a deadline, lingering close | `net, io, clock` |

A handler is a value of type `fn(http.Request) -> http.Response` (a closure takes the
capabilities of the function that writes it, so a handler can do what its author can). The
package's eider.toml grants its dependencies nothing (json and fuzz are pure); a program
that uses it grants it `net, io, clock, threads` (examples/kvstore/eider.toml).

## Architecture

**Parser** (`parse.ei`). A state machine fed bytes as they arrive: head (scanned once, byte
by byte, so every limit is checked before the head is complete), then a Content-Length
body, chunked body (size line, data, CRLF, trailers) or, for responses, a body read until
close. `next()` returns `More`, `Done(msg)` or `Bad(status, why)`; bytes after a message stay
for the next one, so pipelined requests come out one per call. After `Bad` the parser stays
failed: the connection's framing is lost and it must be closed. The tests check that every
input gives the same steps whether fed whole, byte by byte or in random pieces.

**Server** (`server.ei`), the concurrency model (C41). One accepting thread (the caller of
`serve`) and a fixed pool of worker threads (`std/task.Pool`). Each accepted connection is
a job; a worker serves it request after request with blocking-style code: wait (with a
deadline) on the connection and the stop signal, read, feed the parser, call the handler,
write the response before its deadline. It is the simplest sound model while there are no
stackless tasks (C4): no shared mutable state except one Lock of counters, a fixed number
of threads, and the handler is ordinary code. Its cost is an OS thread per connection being
served, so `workers` bounds concurrency. When the compiler makes stackless tasks, `serve`
keeps its signature and the worker loop runs as a task per connection on the event loop.

- *Back-pressure:* connections wait for a worker in the pool's bounded queue; when it is
  full, the acceptor answers `503` (`Retry-After: 1`) and closes. While any connection
  waits, a worker gives up keep-alive after its current response, so idle keep-alive
  clients can't starve new ones.
- *Deadlines (C45):* `idle_timeout` while no request is under way (a new connection, or
  between keep-alive requests: the connection is closed silently); `read_timeout` from a
  request's first byte to its last (then `408`); `write_timeout` per response (then the
  connection is dropped); `max_requests` per connection (then `Connection: close`).
- *Errors:* a request the parser refuses is answered with its status and the connection is
  closed. A response with a header that can't be written (a CR or LF in a value, a name
  that isn't a token) becomes `500`. Closing after a response is a lingering close: half
  close, drain what the client still sends (up to 1 s or 64 KiB), close, so the client reads
  the response instead of a reset.
- *Graceful shutdown (C49):* cancel the token passed to `serve`. A watcher thread blocked on
  the token wakes a waker that is never drained, so every poller watching it (the
  acceptor's and each connection's) sees the stop from then on. The acceptor takes what is
  already in the listen backlog and closes the listener; every worker finishes the request
  it is reading or handling and answers it with `Connection: close`; idle connections close
  at once; a queued connection is served only if its request has already arrived. `serve`
  returns the counts when every worker is done. There is no overall drain deadline: each
  connection is bounded by its own deadlines (and handlers must not block forever).

**Client** (`client.ei`). One connection at a time to one address, kept alive while the
server allows it and opened again by the next request when it was closed. Every call takes
a deadline for the whole exchange (non-blocking connect, send, response). It skips 1xx
interim responses, knows that a response to HEAD has no body, and reads bodies by length,
chunked or until close, with the same parser and limits.

**Router** (`router.ei`). Patterns of literal segments, `:name` and a final `*rest`. The path
is split at `/` before each segment is percent-decoded, so `%2F` stays in its segment. The
most specific route wins (literal over parameter over rest, segment by segment); routes
that match the path but not the method give `405` with `Allow`; HEAD falls back to GET.
Trailing slashes are significant.

**JSON-RPC 2.0** (`jsonrpc.ei`, C7, C47). A `Table` from method names to
`fn(Params) -> Result[List[u8], Error]` (the result as JSON text). `Params` reads positional
or named parameters with typed accessors (`int`, `str`, `bool`, `raw`, `none`, `at_most`);
a wrong or missing one is `-32602` with the reason in `data`. `add_typed(name, decode,
encode, f)` composes a decoder, a typed function and an encoder, which is how a typed
dispatch table is written until JSON derive (P0.10) can generate the decoders. Everything the
specification requires is covered by the spec's own examples in the tests: parse errors,
invalid requests (with or without a readable id), unknown methods, notifications (never
answered), batches (an empty one, all-notification ones, invalid members). Over HTTP:
`POST` with `Content-Type: application/json` (else 405 / 415), `200` with the response, or
`204` when there is nothing to send back. The client side has `call` and `notify` on a
`client.Conn`, and `parse_reply`, which checks the version, the id and that there is exactly
one of `result` and `error`.

## Limits and defaults

| What | Default | Where | Over it |
|---|---|---|---|
| Line length (request line, status line, a header, a chunk-size line) | 8 KiB | `Limits.max_line` | 414 for the request line, 431 for a header, 400 for a chunk line |
| Header fields (trailers count too) | 100 | `Limits.max_headers` | 431 |
| Whole head | 64 KiB | `Limits.max_head` | 431 |
| Body after chunked decoding | 1 MiB | `Limits.max_body` | 413 (a Content-Length above it is refused before reading) |
| Chunk size | 15 hex digits | parse.ei | 400 |
| Empty lines before a request line | 4 | parse.ei | 400 |
| Idle connection | 5 s | `Config.idle_timeout` | closed |
| Reading one request | 10 s from its first byte | `Config.read_timeout` | 408, closed |
| Writing one response | 10 s | `Config.write_timeout` | dropped |
| Requests per connection | 1000 | `Config.max_requests` | `Connection: close` |
| Connections served at once | 16 | `Config.workers` | queued |
| Connections queued | 64 | `Config.queue` | 503 |
| JSON-RPC batch | 100 calls | `Table.max_batch` | one -32600 |
| JSON nesting | 512 | packages/json | -32700 |

## Security posture

- **TLS: run behind a TLS-terminating proxy** (decision C3). The server speaks plain HTTP;
  bind it to loopback or a private interface and let the proxy (nginx, HAProxy, Envoy, a
  cloud load balancer) terminate TLS. TLS 1.3 written in Eider over the libcrypto backend is
  roadmap P1.4. The server does not interpret `Forwarded` / `X-Forwarded-*`: a handler that
  trusts them must know its proxy sets them.
- **Request smuggling** (C42). The parser refuses, with 400: Content-Length together with
  Transfer-Encoding; two Content-Length fields (even equal), or one that isn't only digits;
  two Transfer-Encoding fields; Transfer-Encoding in HTTP/1.0; a final coding other than
  chunked; obs-fold; a bare CR or LF anywhere in the head or a chunk line; whitespace between
  a field name and its colon; an HTTP/1.1 request without exactly one Host. Codings other
  than chunked are 501 (nothing decodes gzip). Conflicting framing is refused in responses
  too, also where the body is ignored (HEAD, 304). After any framing error the connection is
  closed, never reused.
- **Header injection.** Framing headers (Content-Length, Transfer-Encoding, Connection) are
  written by the package from the actual body and keep-alive decision; a handler's are
  dropped. Header names must be tokens and values may not contain CR, LF, NUL or other
  controls; a response that breaks this is replaced by 500, a client request is refused
  with Err.
- **Resource limits.** Every wait has a deadline; heads, bodies and batches have limits;
  threads and queued connections are bounded (503 beyond). A slow client can hold a worker
  for at most `read_timeout` (plus 1 s of lingering close).
- **Path handling.** Percent-decoding happens per segment after splitting (no `%2F` route
  confusion); the router does not resolve `..` (a handler serving files must). Fragments in
  a request-target are refused.
- **What can still go wrong.** A handler that blocks forever holds a worker forever; a trap
  in a handler (panic, overflow, out-of-bounds) ends the process, as any trap does today
  (needs N5). The kvstore example checks arithmetic before doing it so a caller can't crash
  it. There is no authentication or rate limiting in the package: both belong in handlers
  or middleware (next steps).

## Testing

`packages/http/tests` (run by `tests/packages.sh`, verify.sh's packages leg):

- `parse_test`: valid messages, framing, pipelining, keep-alive, incremental input (each
  case is also fed byte by byte and in pieces of 2 to 7 bytes and must give the same), a
  corpus of 56 malformed and smuggling requests, every limit.
- `fuzz_test`: with packages/fuzz's PRNG (a fixed seed, so the output is fixed): 300 random
  valid requests and responses round-trip through the writer and parser, alone and pipelined
  three at a time, fed whole, byte by byte and in random pieces; 1500 mutants (bytes flipped,
  inserted or deleted, framing headers added, CRLF turned into bare LF or CR, cut short,
  under default and tight limits) must parse identically however they are split, and every
  message the parser accepts must satisfy the framing invariants.
- `jsonrpc_test`: the specification's examples, typed methods, errors with data, the HTTP
  handler's checks, the client's reply checks.
- `server_test`: a server on 127.0.0.1 on an ephemeral port: routing, keep-alive,
  pipelining, chunked bodies, `Expect: 100-continue`, refused smuggling, the read and idle
  deadlines, `max_requests`, back-pressure (503 and keep-alive given up), graceful shutdown
  with a request in flight.

`examples/kvstore/tests/e2e_test` starts the example service on an ephemeral port, calls it
with the client (JSON-RPC on one connection, a batch, the REST route, four concurrent clients
from a task group) and shuts it down with its token. The two networked tests are also run
once under ThreadSanitizer by tests/packages.sh. They use only loopback, never a fixed port,
and never sleep to synchronise: a server listens before its thread starts, each step waits
(with a deadline) for the response it needs, and a timeout test waits for the server to act
and then checks how long it took.

## Needs (gaps found while building this)

Recorded rather than worked around; none blocks the design.

| # | Need | Where it showed | Today |
|---|---|---|---|
| N1 | Type aliases (`type Handler = fn(Request) -> Response`) | every handler signature | the fn type is spelled out |
| N2 | `\r`, `\xNN` and `\u{...}` string escapes, and literal concatenation | CRLF in messages, test corpora | bytes pushed by hand; tests map `\n` to CRLF and marker characters to control bytes (done in compiler/: docs/compiler.md "C8.17", same-line concatenation; usable after the next seed) |
| N3 | `std/net`: a send that reports would-block (`try_send`, like `try_recv`) | sock.send_by | wait for writability before every send (correct: one writer per socket) |
| N4 | Waiting on two descriptors with a deadline without a poller per connection (e.g. `fd.wait_any`, or one event.Loop per worker thread) | each connection waits on its socket and the stop signal | one epoll descriptor per connection (four system calls more per connection) |
| N5 | Containing a trap: a handler's panic or overflow ends the process | server | documented; validate input before arithmetic |
| N6 | Stackless tasks (C4) | thread per connection being served | a fixed pool; `serve` keeps its API when tasks arrive |
| N7 | References (8.6): reading a List out of a record copies it | the request path copies heads and bodies a few times | fine at these sizes, measured nothing yet |
| N8 | Comptime reflection and derive (P0.9, P0.10) | typed JSON-RPC parameters and results | decoder and encoder functions per type (`add_typed`) |
| N9 | Iterating a Map's keys | kvstore's `kv.keys` | a key list kept beside the Map |
| N10 | Calling a function stored in a field (`(self.h)(x)`) | router | bind it to a local first |
| N11 | Name resolution with a deadline | the client takes an `net.Addr` | `net.lookup` blocks; resolve first |
| N12 | Connection information in the handler (peer address, TLS later) | logging, rate limiting | not passed yet (no language gap: a field on Request) |

## Next steps toward OpenAPI

1. **Middleware and observability:** handler wrappers (logging as JSON lines with the peer
   address, request ids, panics turned into 500 once traps can be contained), metrics
   counters (P1.6), and a `Forwarded`-aware peer address behind a configured proxy.
2. **Streaming:** request and response bodies as readers and writers (P0.4) instead of
   whole Lists, chunked responses, and `Content-Length` checked against a stream.
3. **Typed services (P1.1):** with JSON derive (P0.10) and `dyn Trait` (P0.7), a service is a
   trait whose methods become `add_typed` entries and a client stub, generated from the
   types instead of written by hand; then Connect (HTTP + JSON) as the second wire format.
4. **OpenAPI (P1.2):** the router already knows each route's method, path pattern and
   parameters; with reflection over handler request and response types it can emit an
   OpenAPI 3.1 document at `/openapi.json` and validate requests from the same types. JSON-RPC
   methods can be described the same way (OpenRPC).
5. **Concurrency:** move the worker loop onto stackless tasks over std/event when the
   compiler has them (C4), keeping `serve` and the handler type; per-connection pollers go
   away (N4).
6. **TLS 1.3 in Eider** (P1.4), then HTTP/2 (P1.7) for gRPC.
