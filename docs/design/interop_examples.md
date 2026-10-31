# Interop Examples

## 1. C: direct header import plus annotations

**The C library (real SQLite API, excerpt):**

```c
// sqlite3.h
int sqlite3_open(const char *filename, sqlite3 **ppDb);
int sqlite3_close(sqlite3 *db);
int sqlite3_exec(sqlite3 *db, const char *sql,
                 int (*callback)(void*, int, char**, char**),
                 void *arg, char **errmsg);
const char *sqlite3_errmsg(sqlite3 *db);
```

**Raw import (works with zero setup, but unsafe):**

```eider
import c "sqlite3.h" as raw          // bindings generated at compile time

fn open_raw(path: str) -> i32 uses ffi {
  var db: *raw.sqlite3 = null
  return unsafe { raw.sqlite3_open(path.cstr(), &db) }
}
```

**Annotation file that makes it safe:**

```toml
# bindings/sqlite3.api.toml
[types.sqlite3]
kind    = "owned_handle"
wrap_as = "Db"
destroy = "sqlite3_close"            # runs automatically when Db is dropped

[functions.sqlite3_open]
rename    = "Db.open"
out_param = "ppDb"                   # becomes the return value
errors    = { ok = 0, message = "sqlite3_errmsg" }

[functions.sqlite3_exec]
rename    = "Db.exec"
callback  = { fn = "callback", userdata = "arg" }   # becomes a closure
errors    = { ok = 0, message_out = "errmsg", free = "sqlite3_free" }

[functions.sqlite3_errmsg]
returns   = { borrowed = true, nullable = false }
```

**Safe usage:**

```eider
import c "sqlite3.h" with "bindings/sqlite3.api.toml" as sqlite

fn setup(path: str) -> Result[(), sqlite.Error] uses ffi, fs {
  let db = sqlite.Db.open(path)?                       // Result, not an int code
  db.exec("CREATE TABLE IF NOT EXISTS orders (id INT, sku TEXT)")?
  db.exec("SELECT * FROM orders", |row| print(row))?   // callback is a closure
  return Ok(())
}                                                      // sqlite3_close runs here
```

## 2. Zig: `export fn`, then treat it as C

**The Zig library:**

```zig
// vendor/mathx/mathx.zig
export fn mathx_dot(a: [*]const f64, b: [*]const f64, len: usize) f64 {
    var sum: f64 = 0;
    for (0..len) |i| sum += a[i] * b[i];
    return sum;
}
```

**Its header (write it by hand; it's one line):**

```c
// vendor/mathx/mathx.h
#include <stddef.h>
double mathx_dot(const double *a, const double *b, size_t len);
```

**A hand-written safe wrapper (for small APIs, simpler than annotations):**

```eider
import c "mathx.h" as raw

fn dot(a: List[f64], b: List[f64]) -> Result[f64, str] uses ffi {
  if a.len() != b.len() { return Err("length mismatch") }
  return Ok(unsafe { raw.mathx_dot(a.ptr(), b.ptr(), a.len()) })
}
```

## 3. C: a library that returns memory it owns

**The C library (any language with a C ABI looks the same from Eider):**

```c
// vendor/slug/slug.h
char *slugify(const char *input);   // malloc'd, or NULL on failure; free with slugify_free
void slugify_free(char *p);
```

```c
// vendor/slug/slug.c
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include "slug.h"

char *slugify(const char *input) {
    char *out = malloc(strlen(input) + 1);
    if (!out) return NULL;
    size_t n = 0;
    int gap = 0;
    for (const char *c = input; *c; c++) {
        if (isspace((unsigned char)*c)) { gap = n > 0; continue; }
        if (gap) { out[n++] = '-'; gap = 0; }
        out[n++] = (char)tolower((unsigned char)*c);
    }
    out[n] = '\0';
    return out;
}

void slugify_free(char *p) { free(p); }
```

**Annotation (memory allocated by the library must be freed by the library):**

```toml
[functions.slugify]
returns = { owned = true, nullable = true, free = "slugify_free", as = "str" }
```

**Usage:**

```eider
import c "slug.h" with "bindings/slug.api.toml" as slug

fn product_url(name: str) -> Option[str] uses ffi {
  let s = slug.slugify(name)?          // copied into a native str, then freed
  return Some(fmt"/products/{s}")
}
```

## 4. C++: declare a bridge, compiler generates the shim

**The C++ library (templates, classes, exceptions):**

```cpp
// vendor/geo/geo.hpp
namespace geo {
  template <typename T> struct Vec2 { T x, y; };

  class Router {
  public:
    explicit Router(const std::string& map_path);    // throws on bad file
    std::vector<Vec2<double>> route(Vec2<double> from, Vec2<double> to) const;
  };
}
```

**The bridge, declared in your language:**

```eider
// src/geo_bridge.ei
bridge cpp "geo.hpp" as geo {
  type Point = geo::Vec2<double> as { x: f64, y: f64 }   // template instantiated
  opaque type Router = geo::Router                      // destructor wired up

  fn Router.new(map_path: str) -> Result[Router, str]   // exceptions become Err
  fn Router.route(self, from: Point, to: Point) -> Result[List[Point], str]
}
```

**What the compiler generates (C++ shim with a C ABI):**

```cpp
extern "C" {
struct geo_point  { double x, y; };
struct geo_handle { void* ok; char* err; };
struct geo_points { geo_point* data; size_t len; char* err; };

geo_handle geo_router_new(const char* path) noexcept {
  try { return { new geo::Router(path), nullptr }; }
  catch (const std::exception& e) { return { nullptr, strdup(e.what()) }; }
  catch (...) { return { nullptr, strdup("unknown C++ exception") }; }
}

void geo_router_free(void* r) noexcept {
  delete static_cast<geo::Router*>(r);
}

geo_points geo_router_route(const void* r, geo_point a, geo_point b) noexcept {
  try {
    auto v = static_cast<const geo::Router*>(r)->route({a.x, a.y}, {b.x, b.y});
    auto* out = static_cast<geo_point*>(malloc(v.size() * sizeof(geo_point)));
    for (size_t i = 0; i < v.size(); ++i) out[i] = { v[i].x, v[i].y };
    return { out, v.size(), nullptr };
  } catch (const std::exception& e) {
    return { nullptr, 0, strdup(e.what()) };
  }
}
}
```

**Usage:**

```eider
import geo_bridge.geo

fn plan_route() -> Result[List[geo.Point], str] uses ffi {
  let router = geo.Router.new("maps/seattle.map")?
  return router.route(geo.Point(0.0, 0.0), geo.Point(5.0, 3.0))
}
```

## 5. Python: embed CPython via a std wrapper

`std.python` wraps `Python.h`. The GIL is a token that can't escape its closure, so the compiler enforces correct GIL handling.

```eider
import std.python as py

fn mean(xs: List[f64]) -> Result[f64, py.Error] uses python {
  return py.with_gil(|gil| {
    let stats = gil.import("statistics")?
    let result = stats.call("fmean", [gil.list(xs)])?
    return result.to[f64]()            // typed extraction; Err on wrong type
  })
}
```

## 6. JavaScript: both directions

**Calling JS: embed QuickJS (a small C engine) with resource limits:**

```eider
import std.js as js

fn check_rule(rule: str, qty: i64) -> Result[bool, js.Error] uses js {
  var rt = js.Runtime.new({ memory_bytes: 16_000_000, timeout_ms: 50 })
  let f = rt.eval(rule)?                     // e.g. "(qty) => qty > 10"
  return f.call([js.Value.int(qty)])?.to[bool]()
}
```

**Exposing to Node: the compiler generates N-API glue:**

```eider
// textkit.ei
export(node) fn word_count(text: str) -> u32 {
  return text.split_whitespace().count()
}
```

```js
const textkit = require("./build/textkit.node");
console.log(textkit.word_count("hello brave new world")); // 4
```

## 7. WASM components: sandboxed, any source language

**The WIT interface (the component itself could be written in C, Zig, Go, etc.):**

```wit
package acme:imaging@1.0.0;

interface resize {
  record image { width: u32, height: u32, rgba: list<u8> }
  resize: func(img: image, width: u32, height: u32) -> result<image, string>;
}

world imaging {
  export resize;
}
```

**Usage (types are generated from WIT, like C headers):**

```eider
import wasm "imaging.wasm" world "acme:imaging/imaging" as img

fn thumbnail(photo: img.Image) -> Result[img.Image, str] uses wasm {
  // No fs, net, or clock unless granted explicitly
  let sandbox = img.instantiate({ memory_mb: 64, fuel: 1_000_000_000 })?
  return sandbox.resize(photo, 128, 128)
}
```

## 8. Export: other languages calling yours

```eider
// textkit.ei
export fn word_count(text: str) -> u32 {
  return text.split_whitespace().count()
}
```

**Generated header:**

```c
// textkit.h
#include <stdint.h>
#include <stddef.h>
typedef struct { const uint8_t *ptr; size_t len; } tk_str;
uint32_t textkit_word_count(tk_str text);
```

**Called from C:**

```c
#include <string.h>
#include "textkit.h"
const char *s = "hello brave new world";
uint32_t n = textkit_word_count((tk_str){ (const uint8_t*)s, strlen(s) });
```

**Called from Python (ctypes):**

```python
import ctypes

class TkStr(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_char_p), ("len", ctypes.c_size_t)]

lib = ctypes.CDLL("./libtextkit.so")
lib.textkit_word_count.argtypes = [TkStr]
lib.textkit_word_count.restype = ctypes.c_uint32

s = b"hello brave new world"
print(lib.textkit_word_count(TkStr(s, len(s))))  # 4
```

## 9. Package manifest tying it together

```toml
# project.toml
[package]
name = "warehouse"
version = "0.1.0"

[native.sqlite3]
lang     = "c"
source   = { url = "https://…/sqlite-amalgamation.zip", sha256 = "…" }
files    = ["sqlite3.c"]
headers  = ["sqlite3.h"]
bindings = "bindings/sqlite3.api.toml"

[native.mathx]
lang = "zig"
path = "vendor/mathx"                # built with `zig build-lib`

[native.slug]
lang    = "c"
path    = "vendor/slug"
files   = ["slug.c"]
headers = ["slug.h"]

[native.geo]
lang   = "cpp"
path   = "vendor/geo"
bridge = "src/geo_bridge.ei"

[wasm.imaging]
component = "vendor/imaging.wasm"
