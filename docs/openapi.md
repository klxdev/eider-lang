# OpenAPI services (packages/openapi)

`packages/openapi` builds REST services with an OpenAPI 3.1 description on top of
packages/http (docs/services.md). Its rule is that a route is registered **together with its
operation**, and that one value drives everything that could otherwise drift apart:

1. **Routing.** The operation's path template (`/todos/{id}`) becomes the router pattern
   (`/todos/:id`).
2. **Validation.** Before the handler runs, path, query and header parameters and the JSON
   body are checked against their schemas. A request that doesn't match gets a 400
   `application/problem+json` (RFC 9457) that lists every error. A body that isn't
   `application/json` gets 415. A body over the operation's `max_body` gets 413, and a
   `secured` operation without a valid bearer token gets 401.
3. **The document.** `GET /openapi.json` serves the OpenAPI 3.1 description of every
   operation, including the 400, 401, 413 and 415 responses the checks above can give.

Decisions C90 to C95 in docs/decisions.md. `examples/todo` is a complete service.

```eider
import "http"
import "http/problem"
import "openapi"
import "openapi/schema"

fn decode_id(i: openapi.Input) -> Result[i64, problem.ApiError] { i.path_int("id") }

fn todo_json(t: Todo) -> List[u8] {
    openapi.obj().int("id", t.id).str("title", t.title).bool("done", t.done).done()
}

fn service(s: Store) -> fn(http.Request) -> http.Response {
    let mut svc = openapi.service("Todo API", "1.0.0")
    let mut todo = schema.object().closed()
    todo = todo.field("id", schema.integer().format("int64").min(1))     // required
    todo = todo.field("title", schema.string().min_length(1).max_length(200))
    todo = todo.field("done", schema.boolean())
    let todo_ref = svc.component("Todo", todo)                             // a $ref

    let mut get = openapi.op("GET", "/todos/{id}").operation_id("getTodo").summary("Get a todo")
    get = get.path_param("id", schema.integer().min(1))
    get = get.returns(200, "The todo", todo_ref).fails(404, "No such todo")
    svc.add(get, openapi.typed(decode_id, |id: i64| -> Result[Todo, problem.ApiError] {
        s.get(id).ok_or(problem.not_found("no such todo"))
    }, todo_json))
    svc.handler()                                          // the routes and /openapi.json
}
```

Builders are written as reassignments (`get = get.path_param(...)`) because a method chain
can't continue on the next line yet (gap O1 below).

## Modules

| Module | What |
|---|---|
| `openapi` (openapi.ei) | `Op` and its builder, `Service` (`component`, `bearer_auth`, `add`, `add_with`, `raw`, `document`, `handler`), `validate`/`validated`, `Input`, `typed`, `obj`/`arr` for writing JSON results, `pretty` |
| `openapi/schema` | `Schema` and its builder, `emit`/`to_json` (rendering), `check`/`validate` (JSON values), `check_text` (parameters), `parse_int` |

From packages/http: `http/problem` (`ApiError`, problem+json) and `http/middleware`
(`bearer`, `body_limit`), which the service applies to operations that ask for them. The
package's own code needs no capabilities. Its eider.toml still grants http `net, io, clock,
threads`, because a grant is checked against everything the program loads of http, its
server included (gap O2).

## Schemas

This is the subset of JSON Schema 2020-12 (the dialect of OpenAPI 3.1) that service types
need:

| Builder | Rendered | Validated |
|---|---|---|
| `object()`, `.field(name, s)` (required), `.prop(name, s)` (optional), `.closed()` | `type`, `properties`, `required`, `additionalProperties: false` | an object; every required member present; each known member against its schema; others refused only when closed |
| `array(items)`, `.min_length(n)`, `.max_length(n)` | `type`, `items`, `minItems`, `maxItems` | an array; its length; each item (pointer `#/2`) |
| `string()`, `.allow(v)` (enum), `.min_length`, `.max_length`, `.format(f)` | `type`, `enum`, `minLength`, `maxLength`, `format` | a string; one of the enum; length in Unicode scalars; `format` is documented only |
| `integer()`, `.min(n)`, `.max(n)` | `type`, `minimum`, `maximum` | a JSON integer literal in i64's range (`1.0` and `1e3` are refused); bounds |
| `boolean()` | `type` | `true` or `false` |
| `any()` | `{}` | anything |
| `.nullable()` | `{"anyOf": [<schema>, {"type": "null"}]}` | null, or the schema |
| `Service.component(name, s)` / `ref_to` | `{"$ref": "#/components/schemas/<name>"}` | the named schema (the reference carries it, so no lookup is needed) |
| `.describe(text)`, `.example(json)` | `description`, `examples` | nothing |

Validation collects up to 20 errors, each a `problem.FieldError` with a JSON pointer
(`#/items/1/title`; `~` and `/` escaped as `~0` and `~1`). Parameters are text: `check_text`
reads an integer strictly (an optional `-`, then digits, in i64's range) and a boolean as
`true` or `false`, and checks a string's enum and length. Object and array parameters are not
supported: an operation that declares one panics when it is added. Query parameters the
operation doesn't declare are ignored.

## Operations and the service

`openapi.op(method, path)` and then `.operation_id`, `.summary`, `.describe`, `.tag`,
`.path_param(name, s)`, `.query(name, s, desc)`, `.query_required`, `.header`,
`.body(s, desc)` (required) or `.optional_body`, `.max_body(n)`, `.returns(status, desc, s)`,
`.returns_empty(status, desc)`, `.fails(status, desc)` (a problem+json response) and
`.secured(scheme)`.

`Service.add(op, h)` checks the operation and **panics** on these programming errors, which
show up the first time the service starts:

- a `{name}` in the path without a `path_param`, or the other way round;
- a parameter declared twice;
- the same method and path, or the same operationId, added twice;
- a `secured` scheme that wasn't registered;
- a component named twice, or named `Problem` (that name belongs to the package).

It then wraps the handler. From the outside in: the route's `layer` (for `add_with`, such as a
timeout), then `body_limit` (`max_body`), then `bearer` (for a `secured` operation; the
check given to `bearer_auth` returns the principal), then validation, then `h`.

`h` gets an `Input`: the validated request (`i.req`), its parsed body, and the operation's
success status. It has typed accessors that return `Result[_, ApiError]`: `path`,
`path_int`, `query`, `query_int`, `query_bool`, `str`, `int`, `bool`, `opt_str`, `opt_int`,
`opt_bool`, `member`, `is_null` and `principal`. After validation these can't fail for
declared, required members; they still return Results, so a decoder needs no unwrap.

`Service.raw(method, pattern, h)` adds an undocumented route such as `/metrics` or
`/health`. `Service.handler()` renders the document once and returns the router with
`GET /openapi.json` added (`serve_doc_at` changes the path). Add every operation before
calling it.

**The document** has `openapi: 3.1.0`, `info`, and `paths` in the order paths were first
used (operations in the order they were added, responses by status). `components` holds the
registered schemas, then `Problem`, then `securitySchemes` (`{"type": "http", "scheme":
"bearer"}`). It is built as a `json.Doc` with packages/json's builder and written compact on
the wire. `openapi.pretty(doc, root)` indents it for people and goldens.
examples/todo/tests/openapi.golden.json is the todo service's description, and the
end-to-end test compares the served document against it. That golden passes
`openapi-spec-validator` (OpenAPI 3.1).

## Typed handlers

```eider
pub fn typed[T, U](decode: fn(Input) -> Result[T, problem.ApiError],
                   f: fn(T) -> Result[U, problem.ApiError],
                   encode: fn(U) -> List[u8]) -> fn(Input) -> http.Response
```

A handler is written as three parts:

- **decode** reads the validated request into a T;
- **f** is the service logic: plain values in, a value or an `ApiError` out, with no HTTP in
  it;
- **encode** writes U as JSON text.

The answer is the operation's first 2xx status with the encoded body (no body for 204), or
the error's problem+json. `no_input` and `no_output` fill the ends for operations without
them.

**This is the shape that generated code will fill.** With JSON derive (roadmap P0.10) or
comptime reflection (P0.9), decode, encode and the schema of T and U come from the types:
`schema_of[T]()`, `decode[T](input)`, `encode[U](u)`. An operation is then
`op(...).body_of[NewTodo]().returns_of[Todo](201)` with a function from `NewTodo` to
`Result[Todo, ApiError]`. Today the three are written by hand, next to each other
(examples/todo/todo.ei, "schemas, decoders and encoders"). The parts that stay are
`typed`'s signature, `Input` and `ApiError`. jsonrpc's `add_typed` (C47) has the same
shape, so one derive serves both.

## Errors (`http/problem`)

`ApiError { status, type_uri, title, detail, errors }` is written as RFC 9457 Problem
Details:

```json
{"type":"about:blank","title":"Bad Request","status":400,
 "detail":"the request does not match the API description",
 "errors":[{"in":"body","pointer":"#/title","detail":"must not be empty"},
           {"in":"query","name":"limit","detail":"must be at least 1"}]}
```

The title defaults to the status's reason phrase, as the RFC asks when the type is
`about:blank`. `.typed(uri, title)` gives the error a documented type. `middleware.problems`
rewrites the http package's own plain-text error responses, such as the router's 404 and
405, in this format, so a service answers every error the same way.

## Gaps

These are recorded rather than worked around. The services-wide list is docs/services.md
"Needs".

| # | Need | Effect today |
|---|---|---|
| O1 | A method chain continued on the next line (`.field(...)` starting a line, or a trailing `.`; N13) | builders are reassignments, `s = s.field(...)` |
| O2 | Grants per imported module: a grant is checked against everything the program loads of a package (N14) | openapi, which is pure, grants http `net, io, clock, threads` because programs load http/server |
| O3 | JSON derive / comptime reflection (P0.9, P0.10; N8) | decoders, encoders and schemas are written by hand per type |
| O4 | Floats (C9) | no `number` schemas and no fractional bounds |
| O5 | A List literal (`["a", "b"]` is a fixed array) | enums are `.allow("a").allow("b")` |
| O6 | `if`/`match` as a call argument (E0103) | values are bound to a `let` first |
| O7 | Response validation | a handler can return data that doesn't match its schema; generated encoders will make this hold by construction |
| O8 | Streaming bodies (docs/services.md next step 2) | `max_body` is checked after the server has read the body, up to `Limits.max_body` |
