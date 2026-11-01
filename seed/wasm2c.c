/* wasm2c: translate the WebAssembly seed (seed/eiderc.wasm) to C, so that the compiler can be
   built from a fresh checkout with only a C compiler (seed/README.md, docs/compiler.md
   "Bootstrap chain").

     cc -std=c11 -O2 -o wasm2c seed/wasm2c.c
     ./wasm2c seed/eiderc.wasm -o eiderc.c
     cc -std=c11 -O1 -pthread -o eiderc eiderc.c core/eider_core.c

   The input is a module as LLVM's wasm32 backend and wasm-ld emit it for an Eider program
   built with `eiderc build --wasm-core`: the MVP integer instruction set plus the features
   that build enables (sign-ext, bulk-memory's memory.copy and memory.fill, mutable globals),
   one memory, one funcref table, active data and element segments, and function imports
   from module "env" named ec_* only: the C core's ABI (core/ABI.md), whose parameters and
   results are all int32_t or int64_t, so the output calls core/eider_core.c directly. The
   module must export `_start`, which the output's main runs. Anything else (floating point,
   SIMD, multi-value, threads, other imports) is an error, not a guess.

   The translator validates what it translates (types of every operand, block structure,
   indices, LEB128 encodings, section bounds), so malformed input is a message and exit 1,
   never undefined behaviour here or in the C it writes. The output checks every memory
   access against the memory's current size, division by zero and overflow, table bounds
   and call_indirect signatures, and call depth; a trap prints `wasm trap: <what>` and exits
   with 134. Signed operations are written in unsigned arithmetic, so the output has no
   implementation-defined or undefined behaviour either. */

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- errors */

static const char *in_name = "input";

static _Noreturn void fail(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "wasm2c: %s: ", in_name);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  exit(1);
}

static void *xalloc(size_t n, size_t size) {
  if (size && n > SIZE_MAX / size) fail("out of memory");
  void *p = calloc(n ? n : 1, size ? size : 1);
  if (!p) fail("out of memory");
  return p;
}

/* ---- output buffer */

typedef struct {
  char *p;
  size_t len, cap;
} buf;

static void bput(buf *b, const char *s, size_t n) {
  if (n > SIZE_MAX - b->len - 1) fail("out of memory");
  if (b->len + n + 1 > b->cap) {
    size_t c = b->cap ? b->cap : 4096;
    while (c < b->len + n + 1) {
      if (c > SIZE_MAX / 2) fail("out of memory");
      c *= 2;
    }
    char *q = realloc(b->p, c);
    if (!q) fail("out of memory");
    b->p = q;
    b->cap = c;
  }
  memcpy(b->p + b->len, s, n);
  b->len += n;
  b->p[b->len] = 0;
}

static void bf(buf *b, const char *fmt, ...) {
  char tmp[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
  va_end(ap);
  if (n < 0) fail("internal: bad format");
  if ((size_t)n < sizeof tmp) {
    bput(b, tmp, (size_t)n);
    return;
  }
  char *big = xalloc((size_t)n + 1, 1);
  va_start(ap, fmt);
  vsnprintf(big, (size_t)n + 1, fmt, ap);
  va_end(ap);
  bput(b, big, (size_t)n);
  free(big);
}

/* ---- reading the module */

typedef struct {
  const uint8_t *p;
  size_t pos, end;
} rd;

static uint8_t u8(rd *r) {
  if (r->pos >= r->end) fail("unexpected end at byte %zu", r->pos);
  return r->p[r->pos++];
}

static uint64_t uleb(rd *r, unsigned bits) {
  uint64_t v = 0;
  unsigned shift = 0;
  for (;;) {
    uint8_t b = u8(r);
    if (shift >= bits) fail("LEB128 too long at byte %zu", r->pos - 1);
    uint64_t chunk = b & 0x7f;
    if (bits - shift < 7 && (chunk >> (bits - shift)) != 0) fail("LEB128 out of range at byte %zu", r->pos - 1);
    v |= chunk << shift;
    shift += 7;
    if (!(b & 0x80)) return v;
  }
}

static uint32_t u32v(rd *r) { return (uint32_t)uleb(r, 32); }

/* A signed LEB128 of `bits` bits, as its two's complement bit pattern. */
static uint64_t sleb(rd *r, unsigned bits) {
  uint64_t v = 0;
  unsigned shift = 0;
  uint8_t b;
  for (;;) {
    b = u8(r);
    if (shift >= bits) fail("LEB128 too long at byte %zu", r->pos - 1);
    uint64_t chunk = b & 0x7f;
    unsigned left = bits - shift; /* bits still to fill, >= 1 */
    if (left < 7) {
      /* the unused high bits must be a sign extension of the last used one */
      uint64_t sign = (chunk >> (left - 1)) & 1;
      uint64_t high = chunk >> left;
      uint64_t want = sign ? (0x7fu >> left) : 0;
      if (high != want) fail("LEB128 out of range at byte %zu", r->pos - 1);
    }
    v |= chunk << shift;
    shift += 7;
    if (!(b & 0x80)) break;
  }
  if (shift < bits && (b & 0x40)) v |= ~(uint64_t)0 << shift;
  if (bits < 64) v &= ((uint64_t)1 << bits) - 1;
  return v;
}

/* a count of entries that each take at least one byte of what is left */
static uint32_t count(rd *r, const char *what) {
  uint32_t n = u32v(r);
  if (n > r->end - r->pos) fail("too many %s (%u)", what, n);
  return n;
}

/* ---- the module */

enum { T_I32 = 0x7f, T_I64 = 0x7e };

typedef struct {
  uint32_t np, nr;
  uint8_t params[64]; /* at most 64 parameters */
  uint8_t res;        /* the result type, or 0 */
  uint32_t canon;     /* the first type index with the same signature */
} ftype;

typedef struct {
  uint32_t type;
  int imported;
  char name[64]; /* an import's field name */
  size_t code, code_end; /* the body's bytes (defined functions) */
} func;

typedef struct {
  uint8_t type, mut;
  uint64_t init;
} global;

static ftype *types;
static uint32_t ntypes;
static func *funcs;
static uint32_t nfuncs, nimports;
static global *globals;
static uint32_t nglobals;
static int has_mem;
static uint64_t mem_min, mem_max; /* pages */
static int has_table;
static uint32_t table_min;
static uint32_t *table; /* function index + 1, 0 for none */
static int64_t start_fn = -1, entry_fn = -1;
typedef struct {
  uint32_t off;
  size_t pos, len;
} dseg;
static dseg *dsegs;
static uint32_t ndsegs;
static const uint8_t *mod;

static const char *tname(uint8_t t) { return t == T_I32 ? "u32" : "u64"; }

static uint8_t valtype(rd *r) {
  uint8_t t = u8(r);
  if (t == T_I32 || t == T_I64) return t;
  if (t == 0x7d || t == 0x7c) fail("floating point (type 0x%02x) is not supported", t);
  fail("value type 0x%02x is not supported", t);
  return 0;
}

static void read_types(rd *r) {
  ntypes = count(r, "types");
  types = xalloc(ntypes, sizeof *types);
  for (uint32_t i = 0; i < ntypes; i++) {
    if (u8(r) != 0x60) fail("type %u is not a function type", i);
    ftype *t = &types[i];
    t->np = count(r, "parameters");
    if (t->np > 64) fail("type %u has more than 64 parameters", i);
    for (uint32_t k = 0; k < t->np; k++) t->params[k] = valtype(r);
    t->nr = count(r, "results");
    if (t->nr > 1) fail("type %u has %u results (multi-value is not supported)", i, t->nr);
    t->res = t->nr ? valtype(r) : 0;
    t->canon = i;
    for (uint32_t j = 0; j < i; j++) {
      if (types[j].np == t->np && types[j].res == t->res && memcmp(types[j].params, t->params, t->np) == 0) {
        t->canon = j;
        break;
      }
    }
  }
}

static void read_imports(rd *r) {
  uint32_t n = count(r, "imports");
  funcs = xalloc(n, sizeof *funcs);
  for (uint32_t i = 0; i < n; i++) {
    uint32_t ml = count(r, "name bytes");
    const uint8_t *m = r->p + r->pos;
    r->pos += ml;
    uint32_t fl = count(r, "name bytes");
    const uint8_t *f = r->p + r->pos;
    r->pos += fl;
    uint8_t kind = u8(r);
    if (kind != 0) fail("import %u is not a function (kind %u)", i, kind);
    if (ml != 3 || memcmp(m, "env", 3) != 0) fail("import %u is not from module \"env\"", i);
    if (fl < 4 || fl >= sizeof funcs[i].name || memcmp(f, "ec_", 3) != 0)
      fail("import %u: only the C core's ec_* functions can be imported (core/ABI.md)", i);
    for (uint32_t k = 0; k < fl; k++) {
      uint8_t c = f[k];
      if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) fail("import %u: bad name", i);
    }
    uint32_t t = u32v(r);
    if (t >= ntypes) fail("import %u: type %u out of range", i, t);
    funcs[i].type = t;
    funcs[i].imported = 1;
    memcpy(funcs[i].name, f, fl);
    funcs[i].name[fl] = 0;
    for (uint32_t j = 0; j < i; j++)
      if (strcmp(funcs[j].name, funcs[i].name) == 0) fail("import %s twice", funcs[i].name);
  }
  nfuncs = nimports = n;
}

static void read_functions(rd *r) {
  uint32_t n = count(r, "functions");
  func *f = xalloc((size_t)nimports + n, sizeof *f);
  if (nimports) memcpy(f, funcs, nimports * sizeof *f);
  free(funcs);
  funcs = f;
  for (uint32_t i = 0; i < n; i++) {
    uint32_t t = u32v(r);
    if (t >= ntypes) fail("function %u: type %u out of range", nimports + i, t);
    funcs[nimports + i].type = t;
  }
  nfuncs = nimports + n;
}

static void limits(rd *r, uint64_t *min, uint64_t *max, uint64_t cap, const char *what) {
  uint8_t flag = u8(r);
  if (flag > 1) fail("%s: limits flag %u (shared or 64-bit) is not supported", what, flag);
  *min = u32v(r);
  *max = flag ? u32v(r) : cap;
  if (*min > cap || *max > cap || *min > *max) fail("%s: bad limits", what);
}

static void read_tables(rd *r) {
  uint32_t n = count(r, "tables");
  if (n > 1 || has_table) fail("more than one table");
  if (n == 0) return;
  if (u8(r) != 0x70) fail("the table is not a funcref table");
  uint64_t min, max;
  limits(r, &min, &max, 1u << 20, "table");
  has_table = 1;
  table_min = (uint32_t)min;
  table = xalloc(table_min, sizeof *table);
}

static void read_memories(rd *r) {
  uint32_t n = count(r, "memories");
  if (n > 1 || has_mem) fail("more than one memory");
  if (n == 0) return;
  limits(r, &mem_min, &mem_max, 65536, "memory");
  has_mem = 1;
}

/* A constant expression of type t: t.const, then end. */
static uint64_t const_expr(rd *r, uint8_t t) {
  uint8_t op = u8(r);
  uint64_t v;
  if (op == 0x41 && t == T_I32) v = sleb(r, 32);
  else if (op == 0x42 && t == T_I64) v = sleb(r, 64);
  else fail("unsupported constant expression (opcode 0x%02x)", op);
  if (u8(r) != 0x0b) fail("constant expression without end");
  return v;
}

static void read_globals(rd *r) {
  nglobals = count(r, "globals");
  globals = xalloc(nglobals, sizeof *globals);
  for (uint32_t i = 0; i < nglobals; i++) {
    globals[i].type = valtype(r);
    uint8_t m = u8(r);
    if (m > 1) fail("global %u: bad mutability", i);
    globals[i].mut = m;
    globals[i].init = const_expr(r, globals[i].type);
  }
}

static void read_exports(rd *r) {
  uint32_t n = count(r, "exports");
  for (uint32_t i = 0; i < n; i++) {
    uint32_t l = count(r, "name bytes");
    const uint8_t *s = r->p + r->pos;
    r->pos += l;
    uint8_t kind = u8(r);
    uint32_t idx = u32v(r);
    if (kind == 0 && l == 6 && memcmp(s, "_start", 6) == 0) {
      if (idx >= nfuncs) fail("export _start: function %u out of range", idx);
      ftype *t = &types[funcs[idx].type];
      if (t->np || t->nr) fail("export _start must take and return nothing");
      entry_fn = idx;
    }
  }
}

static void read_elements(rd *r) {
  uint32_t n = count(r, "element segments");
  for (uint32_t i = 0; i < n; i++) {
    if (u32v(r) != 0) fail("element segment %u: only active segments of table 0 are supported", i);
    if (!has_table) fail("element segment %u without a table", i);
    uint64_t off = (uint32_t)const_expr(r, T_I32);
    uint32_t k = count(r, "elements");
    if (off + k > table_min) fail("element segment %u out of the table's bounds", i);
    for (uint32_t j = 0; j < k; j++) {
      uint32_t f = u32v(r);
      if (f >= nfuncs) fail("element segment %u: function %u out of range", i, f);
      table[off + j] = f + 1;
    }
  }
}

static void read_data(rd *r) {
  ndsegs = count(r, "data segments");
  dsegs = xalloc(ndsegs, sizeof *dsegs);
  for (uint32_t i = 0; i < ndsegs; i++) {
    if (u32v(r) != 0) fail("data segment %u: only active segments of memory 0 are supported", i);
    if (!has_mem) fail("data segment %u without a memory", i);
    dsegs[i].off = (uint32_t)const_expr(r, T_I32);
    uint32_t l = count(r, "data bytes");
    dsegs[i].pos = r->pos;
    dsegs[i].len = l;
    r->pos += l;
    if ((uint64_t)dsegs[i].off + l > mem_min * 65536) fail("data segment %u out of the memory's bounds", i);
  }
}

/* ---- translating a function */

enum { K_BLOCK, K_LOOP, K_IF, K_FUNC };

typedef struct {
  uint8_t kind, res, has_else, dead;
  uint32_t label, height;
} frame;

#define MAX_STACK 65536
#define MAX_FRAMES 65536
#define MAX_LOCALS 65536

static uint8_t stk[MAX_STACK];
static uint32_t sp;
static frame frames[MAX_FRAMES];
static uint32_t nframes;
static uint32_t maxd[2]; /* deepest slot used, per type (0: i32, 1: i64) */
static uint8_t *ltypes;
static uint32_t nlocals, nlabels;
static uint32_t cur_fn;

static int ti(uint8_t t) { return t == T_I64; }
static char sc(uint8_t t) { return t == T_I32 ? 'a' : 'b'; }

/* the C name of stack slot d (of type t) */
static void slot(char *out, uint8_t t, uint32_t d) { snprintf(out, 16, "%c%u", sc(t), d); }

static void push(uint8_t t) {
  if (sp >= MAX_STACK) fail("function %u: operand stack too deep", cur_fn);
  stk[sp++] = t;
  if (sp > maxd[ti(t)]) maxd[ti(t)] = sp;
}

/* the top-but-k slot's name (after checking its type) */
static const char *at(uint32_t k, uint8_t t) {
  static char names[4][16];
  static int n;
  if (sp < k + 1 || sp - k - 1 < frames[nframes - 1].height) fail("function %u: operand stack underflow", cur_fn);
  if (stk[sp - k - 1] != t) fail("function %u: operand type mismatch", cur_fn);
  char *s = names[n++ & 3];
  slot(s, t, sp - k - 1);
  return s;
}

static uint8_t blocktype(rd *r) {
  if (r->pos >= r->end) fail("unexpected end at byte %zu", r->pos);
  uint8_t b = r->p[r->pos];
  if (b == 0x40) {
    r->pos++;
    return 0;
  }
  if (b == T_I32 || b == T_I64) {
    r->pos++;
    return b;
  }
  fail("function %u: block type 0x%02x is not supported (multi-value)", cur_fn, b);
  return 0;
}

static void open_frame(uint8_t kind, uint8_t res) {
  if (nframes >= MAX_FRAMES) fail("function %u: blocks nested too deeply", cur_fn);
  frame *f = &frames[nframes++];
  f->kind = kind;
  f->res = res;
  f->has_else = 0;
  f->dead = 0;
  f->label = nlabels++;
  f->height = sp;
}

/* the value a branch to frame f carries (a block's result; a loop takes none) */
static uint8_t arity(const frame *f) { return f->kind == K_LOOP ? 0 : f->res; }

/* move the branch value (top of the stack) into the target's result slot, then jump */
static void branch(buf *o, const frame *f) {
  uint8_t t = arity(f);
  if (t) {
    char d[16];
    slot(d, t, f->height);
    const char *s = at(0, t);
    if (strcmp(d, s) != 0) bf(o, "%s = %s; ", d, s);
  }
  if (f->kind == K_LOOP) bf(o, "goto L%u_;\n", f->label);
  else bf(o, "goto L%u;\n", f->label);
}

static frame *target(uint32_t depth) {
  if (depth >= nframes) fail("function %u: branch depth %u out of range", cur_fn, depth);
  return &frames[nframes - 1 - depth];
}

/* skip an unreachable stretch up to the else/end of the current frame (not consumed) */
static void skip_dead(rd *r);

static void memarg(rd *r, uint32_t natural, uint32_t *off) {
  uint32_t a = u32v(r);
  if (a > natural) fail("function %u: alignment 2^%u over the natural one", cur_fn, a);
  *off = u32v(r);
  if (!has_mem) fail("function %u: memory access without a memory", cur_fn);
}

static void call_args(buf *o, const ftype *t, uint32_t base) {
  for (uint32_t k = 0; k < t->np; k++) {
    char s[16];
    slot(s, t->params[k], base + k);
    bf(o, "%s%s", k ? ", " : "", s);
  }
}

static void check_args(const ftype *t) {
  for (uint32_t k = 0; k < t->np; k++) (void)at(t->np - 1 - k, t->params[k]);
}

/* binary operators: `op` is a C expression over x and y (helpers for the rest) */
static void bin(buf *o, uint8_t t, uint8_t rt, const char *expr) {
  const char *y = at(0, t);
  char ys[16];
  strcpy(ys, y);
  const char *x = at(1, t);
  char xs[16];
  strcpy(xs, x);
  sp -= 2;
  push(rt);
  char d[16];
  slot(d, rt, sp - 1);
  bf(o, "%s = ", d);
  for (const char *c = expr; *c; c++) {
    if (*c == 'X') bput(o, xs, strlen(xs));
    else if (*c == 'Y') bput(o, ys, strlen(ys));
    else bput(o, c, 1);
  }
  bput(o, ";\n", 2);
}

static void un(buf *o, uint8_t t, uint8_t rt, const char *expr) {
  const char *x = at(0, t);
  char xs[16];
  strcpy(xs, x);
  sp -= 1;
  push(rt);
  char d[16];
  slot(d, rt, sp - 1);
  bf(o, "%s = ", d);
  for (const char *c = expr; *c; c++) {
    if (*c == 'X') bput(o, xs, strlen(xs));
    else bput(o, c, 1);
  }
  bput(o, ";\n", 2);
}

static const char *const ops32[] = {
  /* 0x67.. */ "clz32(X)", "ctz32(X)", "pop32(X)", "X + Y", "X - Y", "X * 1u * Y", "divs32(X, Y)", "divu32(X, Y)",
  "rems32(X, Y)", "remu32(X, Y)", "X & Y", "X | Y", "X ^ Y", "X << (Y & 31)", "shrs32(X, Y)", "X >> (Y & 31)",
  "rotl32(X, Y)", "rotr32(X, Y)",
};
static const char *const ops64[] = {
  /* 0x79.. */ "clz64(X)", "ctz64(X)", "pop64(X)", "X + Y", "X - Y", "X * Y", "divs64(X, Y)", "divu64(X, Y)",
  "rems64(X, Y)", "remu64(X, Y)", "X & Y", "X | Y", "X ^ Y", "X << (Y & 63)", "shrs64(X, Y)", "X >> (Y & 63)",
  "rotl64(X, Y)", "rotr64(X, Y)",
};
static const char *const cmps[] = {
  /* eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u */
  "X == Y", "X != Y", "(X ^ S) < (Y ^ S)", "X < Y", "(X ^ S) > (Y ^ S)", "X > Y",
  "(X ^ S) <= (Y ^ S)", "X <= Y", "(X ^ S) >= (Y ^ S)", "X >= Y",
};

static void cmp(buf *o, uint8_t t, int k) {
  /* S: the sign bit, so a signed comparison is an unsigned one with the sign flipped */
  char e[128];
  const char *s = t == T_I32 ? "0x80000000u" : "0x8000000000000000u";
  size_t n = 0;
  for (const char *c = cmps[k]; *c && n + 24 < sizeof e; c++) {
    if (*c == 'S') {
      memcpy(e + n, s, strlen(s));
      n += strlen(s);
    } else {
      e[n++] = *c;
    }
  }
  e[n] = 0;
  bin(o, t, T_I32, e);
}

static void translate(buf *o, uint32_t fi) {
  func *fn = &funcs[fi];
  ftype *ft = &types[fn->type];
  rd r = {mod, fn->code, fn->code_end};
  cur_fn = fi;
  /* locals */
  uint32_t ngroups = count(&r, "local groups");
  nlocals = ft->np;
  uint64_t total = ft->np;
  size_t save = r.pos;
  for (uint32_t g = 0; g < ngroups; g++) {
    total += u32v(&r);
    if (total > MAX_LOCALS) fail("function %u: too many locals", fi);
    (void)valtype(&r);
  }
  free(ltypes);
  ltypes = xalloc((size_t)total, 1);
  memcpy(ltypes, ft->params, ft->np);
  r.pos = save;
  for (uint32_t g = 0; g < ngroups; g++) {
    uint32_t n = u32v(&r);
    uint8_t t = valtype(&r);
    for (uint32_t k = 0; k < n; k++) ltypes[nlocals++] = t;
  }
  buf body = {0};
  buf *b = &body;
  sp = 0;
  nframes = 0;
  nlabels = 0;
  maxd[0] = maxd[1] = 0;
  open_frame(K_FUNC, ft->res);
  char d[16];
  while (nframes > 0) {
    if (frames[nframes - 1].dead) skip_dead(&r);
    uint8_t op = u8(&r);
    frame *top = &frames[nframes - 1];
    switch (op) {
    case 0x00: /* unreachable */
      bf(b, "trap(\"unreachable\");\n");
      top->dead = 1;
      break;
    case 0x01: break;
    case 0x02: /* block */
    case 0x03: { /* loop */
      uint8_t res = blocktype(&r);
      open_frame(op == 0x02 ? K_BLOCK : K_LOOP, res);
      if (op == 0x03) bf(b, "L%u_:;\n", frames[nframes - 1].label);
      break;
    }
    case 0x04: { /* if */
      uint8_t res = blocktype(&r);
      const char *c = at(0, T_I32);
      bf(b, "if (!%s) goto L%u_;\n", c, nlabels);
      sp--;
      open_frame(K_IF, res);
      break;
    }
    case 0x05: { /* else */
      if (top->kind != K_IF || top->has_else) fail("function %u: else without if", fi);
      if (!top->dead && sp != top->height + (top->res ? 1 : 0)) fail("function %u: bad stack height at else", fi);
      top->has_else = 1;
      top->dead = 0;
      sp = top->height;
      bf(b, "goto L%u;\nL%u_:;\n", top->label, top->label);
      break;
    }
    case 0x0b: { /* end */
      if (!top->dead && sp != top->height + (top->res ? 1 : 0)) fail("function %u: bad stack height at end", fi);
      if (top->kind == K_IF && !top->has_else) {
        if (top->res) fail("function %u: if with a result and no else", fi);
        bf(b, "L%u_:;\n", top->label);
      }
      sp = top->height;
      if (top->res) push(top->res);
      if (top->kind == K_FUNC) {
        bf(b, "L%u:;\n", top->label);
      } else if (top->kind != K_LOOP) {
        bf(b, "L%u:;\n", top->label);
      }
      nframes--;
      break;
    }
    case 0x0c: { /* br */
      frame *f = target(u32v(&r));
      branch(b, f);
      top->dead = 1;
      break;
    }
    case 0x0d: { /* br_if */
      frame *f = target(u32v(&r));
      const char *c = at(0, T_I32);
      char cs[16];
      strcpy(cs, c);
      sp--;
      bf(b, "if (%s) { ", cs);
      branch(b, f);
      bf(b, "}\n");
      break;
    }
    case 0x0e: { /* br_table */
      uint32_t n = count(&r, "br_table targets");
      const char *c = at(0, T_I32);
      char cs[16];
      strcpy(cs, c);
      sp--;
      bf(b, "switch (%s) {\n", cs);
      for (uint32_t k = 0; k <= n; k++) {
        frame *f = target(u32v(&r));
        if (k < n) bf(b, "case %u: ", k);
        else bf(b, "default: ");
        branch(b, f);
      }
      bf(b, "}\n");
      top->dead = 1;
      break;
    }
    case 0x0f: /* return */
      branch(b, &frames[0]);
      top->dead = 1;
      break;
    case 0x10: { /* call */
      uint32_t f = u32v(&r);
      if (f >= nfuncs) fail("function %u: call of function %u out of range", fi, f);
      ftype *t = &types[funcs[f].type];
      check_args(t);
      uint32_t base = sp - t->np;
      sp = base;
      if (t->res) {
        push(t->res);
        slot(d, t->res, base);
        bf(b, "%s = ", d);
      }
      bf(b, "f%u(", f);
      call_args(b, t, base);
      bf(b, ");\n");
      break;
    }
    case 0x11: { /* call_indirect */
      uint32_t ty = u32v(&r);
      if (ty >= ntypes) fail("function %u: call_indirect type %u out of range", fi, ty);
      if (u8(&r) != 0) fail("function %u: call_indirect of a table other than 0", fi);
      if (!has_table) fail("function %u: call_indirect without a table", fi);
      ftype *t = &types[ty];
      const char *k = at(0, T_I32);
      char ks[16];
      strcpy(ks, k);
      sp--;
      check_args(t);
      uint32_t base = sp - t->np;
      sp = base;
      bf(b, "if (%s >= TN || !TF[%s] || TT[%s] != %u) trap(%s >= TN || !TF[%s] ? \"undefined table element\" : \"indirect call signature mismatch\");\n", ks, ks, ks, t->canon, ks, ks);
      if (t->res) {
        push(t->res);
        slot(d, t->res, base);
        bf(b, "%s = ", d);
      }
      bf(b, "((%s (*)(", t->res ? tname(t->res) : "void");
      if (!t->np) bf(b, "void");
      for (uint32_t q = 0; q < t->np; q++) bf(b, "%s%s", q ? ", " : "", tname(t->params[q]));
      bf(b, "))TF[%s])(", ks);
      call_args(b, t, base);
      bf(b, ");\n");
      break;
    }
    case 0x1a: /* drop */
      if (sp <= top->height) fail("function %u: drop of nothing", fi);
      sp--;
      break;
    case 0x1b: /* select */
    case 0x1c: { /* select t */
      if (op == 0x1c) {
        if (u32v(&r) != 1) fail("function %u: select with %s types", fi, "several");
        (void)valtype(&r);
      }
      const char *c = at(0, T_I32);
      char cs[16];
      strcpy(cs, c);
      if (sp < 3 + top->height) fail("function %u: operand stack underflow", fi);
      uint8_t t = stk[sp - 2];
      if (op == 0x1c && t != r.p[r.pos - 1]) fail("function %u: select type mismatch", fi);
      const char *y = at(1, t);
      char ys[16];
      strcpy(ys, y);
      const char *x = at(2, t);
      bf(b, "if (!%s) %s = %s;\n", cs, x, ys);
      sp -= 2;
      break;
    }
    case 0x20: case 0x21: case 0x22: { /* local.get/set/tee */
      uint32_t l = u32v(&r);
      if (l >= nlocals) fail("function %u: local %u out of range", fi, l);
      uint8_t t = ltypes[l];
      if (op == 0x20) {
        push(t);
        slot(d, t, sp - 1);
        bf(b, "%s = l%u;\n", d, l);
      } else {
        bf(b, "l%u = %s;\n", l, at(0, t));
        if (op == 0x21) sp--;
      }
      break;
    }
    case 0x23: case 0x24: { /* global.get/set */
      uint32_t g = u32v(&r);
      if (g >= nglobals) fail("function %u: global %u out of range", fi, g);
      uint8_t t = globals[g].type;
      if (op == 0x23) {
        push(t);
        slot(d, t, sp - 1);
        bf(b, "%s = g%u;\n", d, g);
      } else {
        if (!globals[g].mut) fail("function %u: global.set of immutable global %u", fi, g);
        bf(b, "g%u = %s;\n", g, at(0, t));
        sp--;
      }
      break;
    }
    case 0x28: case 0x29: case 0x2c: case 0x2d: case 0x2e: case 0x2f:
    case 0x30: case 0x31: case 0x32: case 0x33: case 0x34: case 0x35: { /* loads */
      static const struct { uint8_t t; uint32_t bytes; const char *f; } L[] = {
        [0x28 - 0x28] = {T_I32, 4, "ld32(E)"}, [0x29 - 0x28] = {T_I64, 8, "ld64(E)"},
        [0x2c - 0x28] = {T_I32, 1, "sx8_32(ld8(E))"}, [0x2d - 0x28] = {T_I32, 1, "ld8(E)"},
        [0x2e - 0x28] = {T_I32, 2, "sx16_32(ld16(E))"}, [0x2f - 0x28] = {T_I32, 2, "ld16(E)"},
        [0x30 - 0x28] = {T_I64, 1, "sx8_64(ld8(E))"}, [0x31 - 0x28] = {T_I64, 1, "(u64)ld8(E)"},
        [0x32 - 0x28] = {T_I64, 2, "sx16_64(ld16(E))"}, [0x33 - 0x28] = {T_I64, 2, "(u64)ld16(E)"},
        [0x34 - 0x28] = {T_I64, 4, "sx32_64(ld32(E))"}, [0x35 - 0x28] = {T_I64, 4, "(u64)ld32(E)"},
      };
      uint32_t off;
      uint32_t nb = L[op - 0x28].bytes;
      memarg(&r, nb == 1 ? 0 : nb == 2 ? 1 : nb == 4 ? 2 : 3, &off);
      const char *a = at(0, T_I32);
      char as[16];
      strcpy(as, a);
      sp--;
      push(L[op - 0x28].t);
      slot(d, L[op - 0x28].t, sp - 1);
      bf(b, "%s = ", d);
      for (const char *c = L[op - 0x28].f; *c; c++) {
        if (*c == 'E') bf(b, "ea(%s, %uu, %u)", as, off, nb);
        else bput(b, c, 1);
      }
      bf(b, ";\n");
      break;
    }
    case 0x36: case 0x37: case 0x3a: case 0x3b: case 0x3c: case 0x3d: case 0x3e: { /* stores */
      uint8_t t = (op == 0x36 || op == 0x3a || op == 0x3b) ? T_I32 : T_I64;
      uint32_t nb = op == 0x36 ? 4 : op == 0x37 ? 8 : (op == 0x3a || op == 0x3c) ? 1 : (op == 0x3b || op == 0x3d) ? 2 : 4;
      uint32_t off;
      memarg(&r, nb == 1 ? 0 : nb == 2 ? 1 : nb == 4 ? 2 : 3, &off);
      const char *v = at(0, t);
      char vs[16];
      strcpy(vs, v);
      const char *a = at(1, T_I32);
      bf(b, "st%u(ea(%s, %uu, %u), %s%s);\n", nb * 8, a, off, nb, nb == 8 ? "" : t == T_I64 ? "(u32)" : "", vs);
      sp -= 2;
      break;
    }
    case 0x3f: /* memory.size */
      if (u8(&r) != 0 || !has_mem) fail("function %u: memory.size without memory 0", fi);
      push(T_I32);
      slot(d, T_I32, sp - 1);
      bf(b, "%s = (u32)(Msz / 65536);\n", d);
      break;
    case 0x40: /* memory.grow */
      if (u8(&r) != 0 || !has_mem) fail("function %u: memory.grow without memory 0", fi);
      bf(b, "%s = grow(%s);\n", at(0, T_I32), at(0, T_I32));
      break;
    case 0x41:
      push(T_I32);
      slot(d, T_I32, sp - 1);
      bf(b, "%s = %luu;\n", d, (unsigned long)sleb(&r, 32));
      break;
    case 0x42: {
      uint64_t v = sleb(&r, 64);
      push(T_I64);
      slot(d, T_I64, sp - 1);
      bf(b, "%s = %lluu;\n", d, (unsigned long long)v);
      break;
    }
    case 0x45: un(b, T_I32, T_I32, "X == 0"); break;
    case 0x50: un(b, T_I64, T_I32, "X == 0"); break;
    case 0xa7: un(b, T_I64, T_I32, "(u32)X"); break;
    case 0xac: un(b, T_I32, T_I64, "sx32_64(X)"); break;
    case 0xad: un(b, T_I32, T_I64, "(u64)X"); break;
    case 0xc0: un(b, T_I32, T_I32, "sx8_32(X & 0xffu)"); break;
    case 0xc1: un(b, T_I32, T_I32, "sx16_32(X & 0xffffu)"); break;
    case 0xc2: un(b, T_I64, T_I64, "sx8_64((u32)X & 0xffu)"); break;
    case 0xc3: un(b, T_I64, T_I64, "sx16_64((u32)X & 0xffffu)"); break;
    case 0xc4: un(b, T_I64, T_I64, "sx32_64((u32)X)"); break;
    case 0xfc: {
      uint32_t sub = u32v(&r);
      if (sub == 10) { /* memory.copy */
        if (u8(&r) != 0 || u8(&r) != 0 || !has_mem) fail("function %u: memory.copy without memory 0", fi);
        const char *n = at(0, T_I32);
        char ns[16];
        strcpy(ns, n);
        const char *s = at(1, T_I32);
        char ss[16];
        strcpy(ss, s);
        bf(b, "mcopy(%s, %s, %s);\n", at(2, T_I32), ss, ns);
        sp -= 3;
      } else if (sub == 11) { /* memory.fill */
        if (u8(&r) != 0 || !has_mem) fail("function %u: memory.fill without memory 0", fi);
        const char *n = at(0, T_I32);
        char ns[16];
        strcpy(ns, n);
        const char *v = at(1, T_I32);
        char vs[16];
        strcpy(vs, v);
        bf(b, "mfill(%s, %s, %s);\n", at(2, T_I32), vs, ns);
        sp -= 3;
      } else {
        fail("function %u: instruction 0xfc %u is not supported", fi, sub);
      }
      break;
    }
    default:
      if (op >= 0x46 && op <= 0x4f) cmp(b, T_I32, op - 0x46);
      else if (op >= 0x51 && op <= 0x5a) cmp(b, T_I64, op - 0x51);
      else if (op >= 0x67 && op <= 0x69) un(b, T_I32, T_I32, ops32[op - 0x67]);
      else if (op >= 0x6a && op <= 0x78) bin(b, T_I32, T_I32, ops32[op - 0x67]);
      else if (op >= 0x79 && op <= 0x7b) un(b, T_I64, T_I64, ops64[op - 0x79]);
      else if (op >= 0x7c && op <= 0x8a) bin(b, T_I64, T_I64, ops64[op - 0x79]);
      else fail("function %u: opcode 0x%02x at byte %zu is not supported", fi, op, r.pos - 1);
    }
  }
  if (r.pos != r.end) fail("function %u: code after the final end", fi);
  /* the function: signature, locals, slots, guard, body, exit */
  bf(o, "static %s f%u(", ft->res ? tname(ft->res) : "void", fi);
  if (!ft->np) bf(o, "void");
  for (uint32_t k = 0; k < ft->np; k++) bf(o, "%s%s l%u", k ? ", " : "", tname(ft->params[k]), k);
  bf(o, ") {\n");
  for (uint32_t k = ft->np; k < nlocals; k++) bf(o, "  %s l%u = 0;\n", tname(ltypes[k]), k);
  for (int t = 0; t < 2; t++) {
    for (uint32_t k = 0; k < maxd[t]; k++) {
      if (k % 16 == 0) bf(o, "%s  %s ", k ? ";\n" : "", t ? "u64" : "u32");
      else bf(o, ", ");
      bf(o, "%c%u = 0", t ? 'b' : 'a', k);
    }
    if (maxd[t]) bf(o, ";\n");
  }
  bf(o, "\n  if (++D > DMAX) trap(\"call stack exhausted\");\n");
  bput(o, body.p ? body.p : "", body.len);
  bf(o, "D--;\n");
  if (ft->res) bf(o, "return %c0;\n", sc(ft->res));
  bf(o, "}\n\n");
  free(body.p);
}

/* Skip the instructions of an unreachable stretch, up to (not including) the else or end
   that closes the current frame; nested blocks are skipped whole. Immediates are parsed so
   that the stretch is walked correctly, and must be well formed. */
static void skip_dead(rd *r) {
  uint32_t depth = 0;
  for (;;) {
    if (r->pos >= r->end) fail("function %u: unexpected end of code", cur_fn);
    uint8_t op = r->p[r->pos];
    if (depth == 0 && (op == 0x05 || op == 0x0b)) return;
    r->pos++;
    switch (op) {
    case 0x02: case 0x03: case 0x04: (void)blocktype(r); depth++; break;
    case 0x0b: depth--; break;
    case 0x0c: case 0x0d: case 0x10: case 0x20: case 0x21: case 0x22: case 0x23: case 0x24: (void)u32v(r); break;
    case 0x0e: {
      uint32_t n = count(r, "br_table targets");
      for (uint32_t k = 0; k <= n; k++) (void)u32v(r);
      break;
    }
    case 0x11: (void)u32v(r); (void)u8(r); break;
    case 0x1c: {
      uint32_t n = count(r, "types");
      for (uint32_t k = 0; k < n; k++) (void)valtype(r);
      break;
    }
    case 0x3f: case 0x40: (void)u8(r); break;
    case 0x41: (void)sleb(r, 32); break;
    case 0x42: (void)sleb(r, 64); break;
    case 0xfc: {
      uint32_t sub = u32v(r);
      if (sub == 10) { (void)u8(r); (void)u8(r); }
      else if (sub == 11) (void)u8(r);
      else fail("function %u: instruction 0xfc %u is not supported", cur_fn, sub);
      break;
    }
    default:
      if ((op >= 0x28 && op <= 0x3e)) {
        if (op == 0x2a || op == 0x2b || op == 0x38 || op == 0x39) fail("function %u: floating point is not supported", cur_fn);
        (void)u32v(r);
        (void)u32v(r);
      } else if (op == 0x00 || op == 0x01 || op == 0x05 || op == 0x0f || op == 0x1a || op == 0x1b ||
                 (op >= 0x45 && op <= 0x5a) || (op >= 0x67 && op <= 0x8a) || op == 0xa7 || op == 0xac ||
                 op == 0xad || (op >= 0xc0 && op <= 0xc4)) {
        /* no immediates */
      } else {
        fail("function %u: opcode 0x%02x at byte %zu is not supported", cur_fn, op, r->pos - 1);
      }
    }
  }
}

/* ---- the runtime the output carries */

static const char *const prelude[] = {
  "#include <stdint.h>\n",
  "#include <stdio.h>\n",
  "#include <stdlib.h>\n",
  "#include <string.h>\n",
  "#include <pthread.h>\n",
  /* labels, slots and locals the translation doesn't use are fine */
  "#if defined(__GNUC__)\n",
  "#pragma GCC diagnostic ignored \"-Wunused-label\"\n",
  "#pragma GCC diagnostic ignored \"-Wunused-variable\"\n",
  "#pragma GCC diagnostic ignored \"-Wunused-parameter\"\n",
  "#pragma GCC diagnostic ignored \"-Wunused-function\"\n",
  "#pragma GCC diagnostic ignored \"-Wunused-but-set-variable\"\n",
  "#endif\n",
  "typedef uint32_t u32;\n",
  "typedef uint64_t u64;\n",
  "static uint8_t *M;\n",
  "static u64 Msz, Mmax;\n",
  "static u32 D;\n",
  "#define DMAX 50000u\n",
  "static void trap(const char *m) {\n",
  "  fflush(stdout);\n",
  "  fprintf(stderr, \"wasm trap: %s\\n\", m);\n",
  "  exit(134);\n",
  "}\n",
  "static u64 ea(u32 a, u32 off, u32 n) {\n",
  "  u64 e = (u64)a + off;\n",
  "  if (e + n > Msz) trap(\"out of bounds memory access\");\n",
  "  return e;\n",
  "}\n",
  "static u32 ld8(u64 e) { return M[e]; }\n",
  /* little-endian hosts copy the bytes (one load or store); others assemble them */
  "#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__\n",
  "static u32 ld16(u64 e) { uint16_t v; memcpy(&v, M + e, 2); return v; }\n",
  "static u32 ld32(u64 e) { u32 v; memcpy(&v, M + e, 4); return v; }\n",
  "static u64 ld64(u64 e) { u64 v; memcpy(&v, M + e, 8); return v; }\n",
  "static void st16(u64 e, u32 v) { uint16_t w = (uint16_t)v; memcpy(M + e, &w, 2); }\n",
  "static void st32(u64 e, u32 v) { memcpy(M + e, &v, 4); }\n",
  "static void st64(u64 e, u64 v) { memcpy(M + e, &v, 8); }\n",
  "#else\n",
  "static u32 ld16(u64 e) { return (u32)M[e] | (u32)M[e + 1] << 8; }\n",
  "static u32 ld32(u64 e) { return (u32)M[e] | (u32)M[e + 1] << 8 | (u32)M[e + 2] << 16 | (u32)M[e + 3] << 24; }\n",
  "static u64 ld64(u64 e) { return (u64)ld32(e) | (u64)ld32(e + 4) << 32; }\n",
  "static void st16(u64 e, u32 v) { M[e] = (uint8_t)v; M[e + 1] = (uint8_t)(v >> 8); }\n",
  "static void st32(u64 e, u32 v) { st16(e, v); st16(e + 2, v >> 16); }\n",
  "static void st64(u64 e, u64 v) { st32(e, (u32)v); st32(e + 4, (u32)(v >> 32)); }\n",
  "#endif\n",
  "static void st8(u64 e, u32 v) { M[e] = (uint8_t)v; }\n",
  "static u32 sx8_32(u32 x) { return (x ^ 0x80u) - 0x80u; }\n",
  "static u32 sx16_32(u32 x) { return (x ^ 0x8000u) - 0x8000u; }\n",
  "static u64 sx8_64(u32 x) { return ((u64)x ^ 0x80u) - 0x80u; }\n",
  "static u64 sx16_64(u32 x) { return ((u64)x ^ 0x8000u) - 0x8000u; }\n",
  "static u64 sx32_64(u32 x) { return ((u64)x ^ 0x80000000u) - 0x80000000u; }\n",
  "static u32 clz32(u32 x) { u32 n = 0; if (!x) return 32; while (!(x & 0x80000000u)) { x <<= 1; n++; } return n; }\n",
  "static u32 ctz32(u32 x) { u32 n = 0; if (!x) return 32; while (!(x & 1u)) { x >>= 1; n++; } return n; }\n",
  "static u32 pop32(u32 x) { u32 n = 0; while (x) { x &= x - 1; n++; } return n; }\n",
  "static u64 clz64(u64 x) { return (x >> 32) ? clz32((u32)(x >> 32)) : 32 + clz32((u32)x); }\n",
  "static u64 ctz64(u64 x) { return (u32)x ? ctz32((u32)x) : 32 + ctz32((u32)(x >> 32)); }\n",
  "static u64 pop64(u64 x) { return pop32((u32)x) + pop32((u32)(x >> 32)); }\n",
  "static u32 rotl32(u32 x, u32 n) { n &= 31; return n ? x << n | x >> (32 - n) : x; }\n",
  "static u32 rotr32(u32 x, u32 n) { n &= 31; return n ? x >> n | x << (32 - n) : x; }\n",
  "static u64 rotl64(u64 x, u64 n) { n &= 63; return n ? x << n | x >> (64 - n) : x; }\n",
  "static u64 rotr64(u64 x, u64 n) { n &= 63; return n ? x >> n | x << (64 - n) : x; }\n",
  "static u32 shrs32(u32 x, u32 n) { n &= 31; return x & 0x80000000u ? ~(~x >> n) : x >> n; }\n",
  "static u64 shrs64(u64 x, u64 n) { n &= 63; return x >> 63 ? ~(~x >> n) : x >> n; }\n",
  "static u32 divu32(u32 x, u32 y) { if (!y) trap(\"integer divide by zero\"); return x / y; }\n",
  "static u32 remu32(u32 x, u32 y) { if (!y) trap(\"integer divide by zero\"); return x % y; }\n",
  "static u64 divu64(u64 x, u64 y) { if (!y) trap(\"integer divide by zero\"); return x / y; }\n",
  "static u64 remu64(u64 x, u64 y) { if (!y) trap(\"integer divide by zero\"); return x % y; }\n",
  "static u32 divs32(u32 x, u32 y) {\n",
  "  if (!y) trap(\"integer divide by zero\");\n",
  "  if (x == 0x80000000u && y == 0xffffffffu) trap(\"integer overflow\");\n",
  "  u32 ax = x >> 31 ? 0u - x : x, ay = y >> 31 ? 0u - y : y, q = ax / ay;\n",
  "  return (x ^ y) >> 31 ? 0u - q : q;\n",
  "}\n",
  "static u32 rems32(u32 x, u32 y) {\n",
  "  if (!y) trap(\"integer divide by zero\");\n",
  "  u32 ax = x >> 31 ? 0u - x : x, ay = y >> 31 ? 0u - y : y, m = ax % ay;\n",
  "  return x >> 31 ? 0u - m : m;\n",
  "}\n",
  "static u64 divs64(u64 x, u64 y) {\n",
  "  if (!y) trap(\"integer divide by zero\");\n",
  "  if (x == 0x8000000000000000u && y == 0xffffffffffffffffu) trap(\"integer overflow\");\n",
  "  u64 ax = x >> 63 ? 0u - x : x, ay = y >> 63 ? 0u - y : y, q = ax / ay;\n",
  "  return (x ^ y) >> 63 ? 0u - q : q;\n",
  "}\n",
  "static u64 rems64(u64 x, u64 y) {\n",
  "  if (!y) trap(\"integer divide by zero\");\n",
  "  u64 ax = x >> 63 ? 0u - x : x, ay = y >> 63 ? 0u - y : y, m = ax % ay;\n",
  "  return x >> 63 ? 0u - m : m;\n",
  "}\n",
  "static u32 grow(u32 n) {\n",
  "  u64 old = Msz / 65536;\n",
  "  if (n == 0) return (u32)old;\n",
  "  if ((u64)n > Mmax - old) return 0xffffffffu;\n",
  "  u64 sz = (old + n) * 65536;\n",
  "  if (sz > SIZE_MAX) return 0xffffffffu;\n",
  "  uint8_t *p = realloc(M, (size_t)sz);\n",
  "  if (!p) return 0xffffffffu;\n",
  "  memset(p + Msz, 0, (size_t)(sz - Msz));\n",
  "  M = p;\n",
  "  Msz = sz;\n",
  "  return (u32)old;\n",
  "}\n",
  "static void mcopy(u32 d, u32 s, u32 n) {\n",
  "  if ((u64)d + n > Msz || (u64)s + n > Msz) trap(\"out of bounds memory access\");\n",
  "  if (n) memmove(M + d, M + s, n);\n",
  "}\n",
  "static void mfill(u32 d, u32 v, u32 n) {\n",
  "  if ((u64)d + n > Msz) trap(\"out of bounds memory access\");\n",
  "  if (n) memset(M + d, (int)(v & 0xffu), n);\n",
  "}\n",
  /* int32_t/int64_t from their bit patterns, without implementation-defined conversions */
  "static int32_t s32(u32 x) { return x < 0x80000000u ? (int32_t)x : (int32_t)(x - 0x80000000u) - 0x7fffffff - 1; }\n",
  "static int64_t s64(u64 x) { return x < 0x8000000000000000u ? (int64_t)x : (int64_t)(x - 0x8000000000000000u) - 0x7fffffffffffffff - 1; }\n",
};

static void import_wrapper(buf *o, uint32_t fi) {
  ftype *t = &types[funcs[fi].type];
  /* the C core's prototype, with fixed-width types (core/ABI.md rule 3) */
  bf(o, "%s %s(", t->res ? (t->res == T_I32 ? "int32_t" : "int64_t") : "void", funcs[fi].name);
  if (!t->np) bf(o, "void");
  for (uint32_t k = 0; k < t->np; k++) bf(o, "%s%s", k ? ", " : "", t->params[k] == T_I32 ? "int32_t" : "int64_t");
  bf(o, ");\nstatic %s f%u(", t->res ? tname(t->res) : "void", fi);
  if (!t->np) bf(o, "void");
  for (uint32_t k = 0; k < t->np; k++) bf(o, "%s%s l%u", k ? ", " : "", tname(t->params[k]), k);
  bf(o, ") { %s%s%s(", t->res ? "return " : "", t->res ? (t->res == T_I32 ? "(u32)" : "(u64)") : "", funcs[fi].name);
  for (uint32_t k = 0; k < t->np; k++) bf(o, "%s%s(l%u)", k ? ", " : "", t->params[k] == T_I32 ? "s32" : "s64", k);
  bf(o, "); }\n");
}

static void proto(buf *o, uint32_t fi) {
  ftype *t = &types[funcs[fi].type];
  bf(o, "static %s f%u(", t->res ? tname(t->res) : "void", fi);
  if (!t->np) bf(o, "void");
  for (uint32_t k = 0; k < t->np; k++) bf(o, "%s%s", k ? ", " : "", tname(t->params[k]));
  bf(o, ");\n");
}

int main(int argc, char **argv) {
  const char *out_name = NULL;
  const char *path = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) out_name = argv[++i];
    else if (!path && argv[i][0] != '-') path = argv[i];
    else {
      fprintf(stderr, "usage: wasm2c <module.wasm> [-o <out.c>]\n");
      return 2;
    }
  }
  if (!path) {
    fprintf(stderr, "usage: wasm2c <module.wasm> [-o <out.c>]\n");
    return 2;
  }
  in_name = path;
  FILE *f = fopen(path, "rb");
  if (!f) fail("cannot open");
  buf in = {0};
  char chunk[65536];
  size_t n;
  while ((n = fread(chunk, 1, sizeof chunk, f)) > 0) bput(&in, chunk, n);
  if (ferror(f)) fail("cannot read");
  fclose(f);
  mod = (const uint8_t *)in.p;
  rd r = {mod, 0, in.len};
  if (in.len < 8 || memcmp(mod, "\0asm\1\0\0\0", 8) != 0) fail("not a WebAssembly module (version 1)");
  r.pos = 8;
  int last = 0;
  uint32_t ncode = 0;
  int have_funcs = 0;
  while (r.pos < r.end) {
    uint8_t id = u8(&r);
    uint32_t len = u32v(&r);
    if (len > r.end - r.pos) fail("section %u runs past the end", id);
    rd s = {mod, r.pos, r.pos + len};
    r.pos += len;
    if (id == 0) continue; /* custom sections: names, producers, debug info */
    if (id <= last && !(last == 12 && id > 9)) fail("section %u out of order", id);
    if (id == 12 && last >= 10) fail("section 12 out of order");
    last = id;
    switch (id) {
    case 1: read_types(&s); break;
    case 2: read_imports(&s); break;
    case 3: read_functions(&s); have_funcs = 1; break;
    case 4: read_tables(&s); break;
    case 5: read_memories(&s); break;
    case 6: read_globals(&s); break;
    case 7: read_exports(&s); break;
    case 8: {
      uint32_t sf = u32v(&s);
      if (sf >= nfuncs) fail("start function out of range");
      if (types[funcs[sf].type].np || types[funcs[sf].type].nr) fail("the start function must take and return nothing");
      start_fn = sf;
      break;
    }
    case 9: read_elements(&s); break;
    case 10: {
      ncode = count(&s, "function bodies");
      if (ncode != nfuncs - nimports) fail("%u function bodies for %u functions", ncode, nfuncs - nimports);
      for (uint32_t i = 0; i < ncode; i++) {
        uint32_t l = u32v(&s);
        if (l > s.end - s.pos) fail("function body %u runs past the section", i);
        funcs[nimports + i].code = s.pos;
        funcs[nimports + i].code_end = s.pos + l;
        s.pos += l;
      }
      break;
    }
    case 11: read_data(&s); break;
    case 12: (void)u32v(&s); break;
    default: fail("unknown section %u", id);
    }
    if (s.pos != s.end) fail("section %u has %zu bytes left over", id, s.end - s.pos);
  }
  if (have_funcs && ncode != nfuncs - nimports) fail("no code section");
  if (entry_fn < 0) fail("no exported function _start");
  buf o = {0};
  bf(&o, "/* generated by seed/wasm2c.c from %s: do not edit */\n", strrchr(path, '/') ? strrchr(path, '/') + 1 : path);
  for (size_t i = 0; i < sizeof prelude / sizeof *prelude; i++) bput(&o, prelude[i], strlen(prelude[i]));
  for (uint32_t i = 0; i < nglobals; i++)
    bf(&o, "static %s g%u = %lluu;\n", tname(globals[i].type), i, (unsigned long long)globals[i].init);
  for (uint32_t i = 0; i < nimports; i++) import_wrapper(&o, i);
  for (uint32_t i = nimports; i < nfuncs; i++) proto(&o, i);
  /* the table: each element as a generic function pointer, and its canonical type */
  bf(&o, "#define TN %uu\nstatic void (*const TF[%u])(void) = {", table_min, table_min ? table_min : 1);
  for (uint32_t i = 0; i < table_min; i++) {
    if (i % 8 == 0) bf(&o, "\n ");
    if (table[i]) bf(&o, " (void (*)(void))f%u,", table[i] - 1);
    else bf(&o, " 0,");
  }
  bf(&o, "\n};\nstatic const u32 TT[%u] = {", table_min ? table_min : 1);
  for (uint32_t i = 0; i < table_min; i++) {
    if (i % 16 == 0) bf(&o, "\n ");
    bf(&o, " %u,", table[i] ? types[funcs[table[i] - 1].type].canon : 0);
  }
  bf(&o, "\n};\n\n");
  for (uint32_t i = nimports; i < nfuncs; i++) translate(&o, i);
  /* the data segments */
  for (uint32_t i = 0; i < ndsegs; i++) {
    bf(&o, "static const uint8_t D%u[%zu] = {", i, dsegs[i].len ? dsegs[i].len : (size_t)1);
    for (size_t k = 0; k < dsegs[i].len; k++) {
      if (k % 24 == 0) bf(&o, "\n");
      bf(&o, "%u,", mod[dsegs[i].pos + k]);
    }
    bf(&o, "\n};\n");
  }
  bf(&o, "static void *run(void *x) {\n  (void)x;\n");
  if (start_fn >= 0) bf(&o, "  f%u();\n", (uint32_t)start_fn);
  bf(&o, "  f%u();\n  return NULL;\n}\n", (uint32_t)entry_fn);
  bf(&o, "int main(void) {\n  Mmax = %lluu;\n  Msz = %lluu * 65536;\n", (unsigned long long)mem_max, (unsigned long long)mem_min);
  bf(&o, "  M = calloc(Msz ? (size_t)Msz : 1, 1);\n  if (!M) { fprintf(stderr, \"wasm2c: out of memory\\n\"); return 134; }\n");
  for (uint32_t i = 0; i < ndsegs; i++)
    if (dsegs[i].len) bf(&o, "  memcpy(M + %uu, D%u, %zu);\n", dsegs[i].off, i, dsegs[i].len);
  bf(&o, "  /* deep recursion needs a deep C stack: run on a thread with 512 MiB of it (reserved,\n"
         "     not committed), or on this one if that can't be had */\n"
         "  pthread_attr_t a;\n  pthread_t t;\n"
         "  size_t sizes[] = {(size_t)512 << 20, (size_t)128 << 20, (size_t)32 << 20};\n"
         "  for (int i = 0; i < 3; i++) {\n"
         "    if (pthread_attr_init(&a) != 0) break;\n"
         "    int ok = pthread_attr_setstacksize(&a, sizes[i]) == 0 && pthread_create(&t, &a, run, NULL) == 0;\n"
         "    pthread_attr_destroy(&a);\n"
         "    if (ok) { pthread_join(t, NULL); return 0; }\n"
         "  }\n"
         "  run(NULL);\n  return 0;\n}\n");
  FILE *of = out_name ? fopen(out_name, "wb") : stdout;
  if (!of) fail("cannot write %s", out_name);
  if (fwrite(o.p, 1, o.len, of) != o.len || (out_name && fclose(of) != 0)) fail("cannot write the output");
  return 0;
}
