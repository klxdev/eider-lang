//! Owned heap types: `String`, `List[T]`, `Map[K, V]`, `Box[T]`.
//!
//! Semantics are plain value semantics. Reading an owned value out of a place (variable, field,
//! index) into new storage clones it; a freshly produced value (call result, constructor, ...) is
//! moved. Function parameters are borrowed, so the callee can't free or keep them without an
//! explicit clone. Every owned value lives in a "frame" (one per block) and is dropped when the
//! frame ends, or earlier on `return` / `break` / `continue` / `?`.

use crate::ast::*;
use crate::check::*;
use crate::diag::{Diag, Pos};

impl<'a> Checker<'a> {
    // ------------------------------------------------------------ ownership queries
    pub fn owns(&self, t: &Ty) -> bool {
        match t {
            Ty::String | Ty::List(_) | Ty::Map(..) | Ty::Box(_) | Ty::Fn(..) | Ty::Task(_) | Ty::Mutex(_) | Ty::Chan(_) => true,
            Ty::Enum(k) => self.enum_defs.get(k).map(|d| d.variants.iter().any(|v| v.fields.iter().any(|f| self.owns(&f.1)))).unwrap_or(false),
            Ty::Record(k) => self.rec_defs.get(k).map(|d| d.fields.iter().any(|f| self.owns(&f.1))).unwrap_or(false),
            Ty::Array(e, _) => self.owns(e),
            Ty::Tuple(ts) => ts.iter().any(|x| self.owns(x)),
            _ => false,
        }
    }

    pub fn check_map_key(&self, k: &Ty, pos: Pos) -> R<()> {
        match k {
            Ty::Int(_) | Ty::Bool | Ty::String | Ty::Str => Ok(()),
            t => err("E0701", pos, format!("{} can't be a Map key; keys must be integers, bool, str or String", t)),
        }
    }

    /// Does `==` work on this type? (Maps have no structural equality.)
    pub fn eq_supported(&self, t: &Ty) -> bool {
        match t {
            Ty::Map(..) | Ty::Fn(..) | Ty::Task(_) | Ty::Mutex(_) | Ty::Chan(_) => false,
            Ty::Enum(k) => self.enum_defs.get(k).map(|d| d.variants.iter().all(|v| v.fields.iter().all(|f| self.eq_supported_shallow(&f.1)))).unwrap_or(true),
            Ty::Record(k) => self.rec_defs.get(k).map(|d| d.fields.iter().all(|f| self.eq_supported_shallow(&f.1))).unwrap_or(true),
            Ty::Array(e, _) | Ty::List(e) | Ty::Box(e) => self.eq_supported_shallow(e),
            Ty::Tuple(ts) => ts.iter().all(|x| self.eq_supported_shallow(x)),
            _ => true,
        }
    }
    fn eq_supported_shallow(&self, t: &Ty) -> bool {
        match t {
            Ty::Map(..) | Ty::Fn(..) | Ty::Task(_) | Ty::Mutex(_) | Ty::Chan(_) => false,
            Ty::Enum(_) | Ty::Record(_) => true, // checked when that type's own == is generated
            _ => self.eq_supported(t),
        }
    }

    // ------------------------------------------------------------ frames
    pub fn push_frame(&mut self) {
        self.frames.push(vec![]);
    }

    pub fn pop_frame(&mut self, emit_drops: bool) {
        let f = self.frames.pop().unwrap_or_default();
        if emit_drops {
            for (n, t) in f.iter().rev() {
                self.emit_drop(n, t);
            }
        }
    }

    pub fn emit_drop(&mut self, name: &str, ty: &Ty) {
        self.need_glue(ty);
        self.emit(format!("ei_drop_{}(&{});", mangle(&ty.to_string()), name));
    }

    /// Drop everything in frames `base..` (innermost first) without popping them.
    pub fn drop_frames_from(&mut self, base: usize) {
        let items: Vec<(String, Ty)> = self.frames.iter().skip(base).rev().flat_map(|f| f.iter().rev().cloned().collect::<Vec<_>>()).collect();
        for (n, t) in items {
            self.emit_drop(&n, &t);
        }
    }

    pub fn has_pending_drops(&self) -> bool {
        self.frames.iter().any(|f| !f.is_empty())
    }

    pub fn register(&mut self, name: &str, ty: &Ty) {
        if self.owns(ty) {
            self.need_glue(ty);
            if let Some(f) = self.frames.last_mut() {
                f.push((name.to_string(), ty.clone()));
            }
        }
    }

    pub fn cancel(&mut self, name: &str) {
        for f in self.frames.iter_mut() {
            f.retain(|(n, _)| n != name);
        }
        self.fresh.remove(name);
    }

    pub fn need_glue(&mut self, ty: &Ty) {
        if matches!(ty, Ty::String) {
            return;
        }
        if self.owns(ty) && self.glue_seen.insert(mangle(&ty.to_string())) {
            self.glue_needed.push(ty.clone());
        }
    }

    /// Hoist an owned rvalue into a registered temporary.
    pub fn mk_fresh(&mut self, v: V) -> V {
        if !self.owns(&v.ty) || self.fresh.contains(&v.c) {
            return v;
        }
        let t = self.tmp();
        self.emit(format!("{} {} = {};", self.ctype(&v.ty), t, v.c));
        self.fresh.insert(t.clone());
        self.register(&t, &v.ty);
        V { ty: v.ty, c: t, k: None, pure: true }
    }

    /// C expression for an owned value ready to be moved into new storage.
    pub fn take(&mut self, v: &V) -> String {
        if !self.owns(&v.ty) {
            return v.c.clone();
        }
        if self.fresh.contains(&v.c) {
            self.cancel(&v.c);
            return v.c.clone();
        }
        self.need_glue(&v.ty);
        let t = self.tmp();
        self.emit(format!("{} {} = ei_clone_{}(&{});", self.ctype(&v.ty), t, mangle(&v.ty.to_string()), wrap(&v.c)));
        t
    }

    /// Declare a pattern binding: clones owned data out of the (still-owned) scrutinee.
    pub fn bind_value(&mut self, cname: &str, ty: &Ty, cexpr: &str) {
        if self.owns(ty) {
            self.need_glue(ty);
            self.emit(format!("{} {} = ei_clone_{}(&{});", self.ctype(ty), cname, mangle(&ty.to_string()), wrap(cexpr)));
            self.register(cname, ty);
        } else {
            self.emit(format!("{} {} = {};", self.ctype(ty), cname, cexpr));
        }
    }

    // ------------------------------------------------------------ generated C
    fn drop_stmt(&mut self, ft: &Ty, ptr: &str) -> Option<String> {
        if self.owns(ft) {
            self.need_glue(ft);
            Some(format!("ei_drop_{}({});", mangle(&ft.to_string()), ptr))
        } else {
            None
        }
    }

    fn clone_val(&mut self, ft: &Ty, ptr: &str) -> String {
        if self.owns(ft) {
            self.need_glue(ft);
            format!("ei_clone_{}({})", mangle(&ft.to_string()), ptr)
        } else {
            format!("(*{})", ptr)
        }
    }

    pub fn gen_aux(&mut self) {
        loop {
            let mut progressed = false;
            while self.heap_i < self.heap_tys.len() {
                let t = self.heap_tys[self.heap_i].clone();
                self.heap_i += 1;
                progressed = true;
                self.gen_ops(&t);
            }
            while self.glue_i < self.glue_needed.len() {
                let t = self.glue_needed[self.glue_i].clone();
                self.glue_i += 1;
                progressed = true;
                self.gen_glue(&t);
            }
            while self.eq_i < self.eq_needed.len() {
                let t = self.eq_needed[self.eq_i].clone();
                self.eq_i += 1;
                progressed = true;
                self.gen_eq(&t);
            }
            if !progressed {
                break;
            }
        }
    }

    fn gen_eq(&mut self, ty: &Ty) {
        let ct = self.ctype(ty);
        let name = format!("ei_eq_{}", mangle(&ty.to_string()));
        self.aux_protos.push_str(&format!("static bool {}({} a, {} b);\n", name, ct, ct));
        let body = match ty {
            Ty::Record(k) => {
                let fs = self.rec_defs[k].fields.clone();
                let parts: Vec<String> = fs.iter().map(|(n, ft)| self.eq_expr(ft, &format!("a.f_{}", n), &format!("b.f_{}", n))).collect();
                format!("return {};", parts.join(" && "))
            }
            Ty::Tuple(ts) => {
                let parts: Vec<String> = ts.iter().enumerate().map(|(i, ft)| self.eq_expr(ft, &format!("a.f_{}", i), &format!("b.f_{}", i))).collect();
                format!("return {};", parts.join(" && "))
            }
            Ty::Array(e, n) => {
                let inner = self.eq_expr(e, "a.d[i]", "b.d[i]");
                format!("for (uint64_t i = 0; i < {}; i++) if (!{}) return false; return true;", n, inner)
            }
            Ty::List(e) => {
                let inner = self.eq_expr(e, "a.d[i]", "b.d[i]");
                format!("if (a.len != b.len) return false; for (uint64_t i = 0; i < a.len; i++) if (!{}) return false; return true;", inner)
            }
            Ty::Box(e) => {
                let inner = self.eq_expr(e, "(*a.p)", "(*b.p)");
                format!("return {};", inner)
            }
            Ty::Enum(k) => {
                let d = self.enum_defs[k].clone();
                let mut cases = String::new();
                for v in &d.variants {
                    if v.fields.is_empty() {
                        continue;
                    }
                    let parts: Vec<String> = v
                        .fields
                        .iter()
                        .map(|(n, ft)| self.eq_expr(ft, &format!("a.u.m_{}.f_{}", v.name, n), &format!("b.u.m_{}.f_{}", v.name, n)))
                        .collect();
                    cases.push_str(&format!("case {}: return {}; ", self.tag_const(k, &v.name), parts.join(" && ")));
                }
                format!("if (a.tag != b.tag) return false; switch (a.tag) {{ {}default: return true; }}", cases)
            }
            _ => "return true;".to_string(),
        };
        self.aux_bodies.push_str(&format!("static bool {}({} a, {} b) {{ {} }}\n", name, ct, ct, body));
    }

    fn gen_glue(&mut self, ty: &Ty) {
        let ct = self.ctype(ty);
        let n = mangle(&ty.to_string());
        self.aux_protos.push_str(&format!("static void ei_drop_{n}({ct}* x);\nstatic {ct} ei_clone_{n}(const {ct}* x);\n", n = n, ct = ct));
        let mut drop = String::new();
        let mut clone = String::new();
        match ty {
            Ty::Record(k) => {
                let fs = self.rec_defs[k].fields.clone();
                clone.push_str(&format!("{} r = *x; ", ct));
                for (f, ft) in fs {
                    if let Some(d) = self.drop_stmt(&ft, &format!("&x->f_{}", f)) {
                        drop.push_str(&d);
                        drop.push(' ');
                        clone.push_str(&format!("r.f_{f} = {c}; ", f = f, c = self.clone_val(&ft, &format!("&x->f_{}", f))));
                    }
                }
                clone.push_str("return r;");
            }
            Ty::Tuple(ts) => {
                clone.push_str(&format!("{} r = *x; ", ct));
                for (i, ft) in ts.clone().iter().enumerate() {
                    if let Some(d) = self.drop_stmt(ft, &format!("&x->f_{}", i)) {
                        drop.push_str(&d);
                        drop.push(' ');
                        clone.push_str(&format!("r.f_{i} = {c}; ", i = i, c = self.clone_val(ft, &format!("&x->f_{}", i))));
                    }
                }
                clone.push_str("return r;");
            }
            Ty::Enum(k) => {
                let d = self.enum_defs[k].clone();
                let mut dcases = String::new();
                let mut ccases = String::new();
                for v in &d.variants {
                    let tag = self.tag_const(k, &v.name);
                    let mut ds = String::new();
                    let mut cs = String::new();
                    for (f, ft) in &v.fields {
                        if let Some(dd) = self.drop_stmt(ft, &format!("&x->u.m_{}.f_{}", v.name, f)) {
                            ds.push_str(&dd);
                            ds.push(' ');
                            cs.push_str(&format!("r.u.m_{v}.f_{f} = {c}; ", v = v.name, f = f, c = self.clone_val(ft, &format!("&x->u.m_{}.f_{}", v.name, f))));
                        }
                    }
                    if !ds.is_empty() {
                        dcases.push_str(&format!("case {}: {}break; ", tag, ds));
                        ccases.push_str(&format!("case {}: {}break; ", tag, cs));
                    }
                }
                drop.push_str(&format!("switch (x->tag) {{ {}default: break; }}", dcases));
                clone.push_str(&format!("{} r = *x; switch (x->tag) {{ {}default: break; }} return r;", ct, ccases));
            }
            Ty::Array(e, len) => {
                let e = (**e).clone();
                if let Some(d) = self.drop_stmt(&e, "&x->d[i]") {
                    drop.push_str(&format!("for (uint64_t i = 0; i < {}; i++) {}", len, d));
                }
                clone.push_str(&format!("{} r; for (uint64_t i = 0; i < {}; i++) r.d[i] = {}; return r;", ct, len, self.clone_val(&e, "&x->d[i]")));
            }
            Ty::List(e) => {
                let e = (**e).clone();
                if let Some(d) = self.drop_stmt(&e, "&x->d[i]") {
                    drop.push_str(&format!("for (uint64_t i = 0; i < x->len; i++) {} ", d));
                }
                drop.push_str("free(x->d); x->d = NULL; x->len = 0; x->cap = 0;");
                let et = self.ctype(&e);
                clone.push_str(&format!(
                    "{ct} r; r.len = x->len; r.cap = x->len; r.d = r.len ? ({et}*)ei_alloc(r.len * sizeof({et})) : NULL; for (uint64_t i = 0; i < x->len; i++) r.d[i] = {c}; return r;",
                    ct = ct,
                    et = et,
                    c = self.clone_val(&e, "&x->d[i]")
                ));
            }
            Ty::Task(e) | Ty::Mutex(e) | Ty::Chan(e) => {
                // shared handle: clone = share, drop = release (the last one frees)
                let e = (**e).clone();
                let inner = match ty {
                    Ty::Task(_) => {
                        let ft = Ty::Fn(vec![], Box::new(e.clone()));
                        let mut s = String::from("if (!x->p->joined) { pthread_join(x->p->th, NULL); x->p->joined = 1; } ");
                        s.push_str(&self.drop_stmt(&ft, "&x->p->f").unwrap_or_default());
                        s.push(' ');
                        if e != Ty::Unit {
                            s.push_str(&self.drop_stmt(&e, "&x->p->result").unwrap_or_default());
                        }
                        s.push_str(" pthread_mutex_destroy(&x->p->mu);");
                        s
                    }
                    Ty::Mutex(_) => format!("{} pthread_mutex_destroy(&x->p->mu);", self.drop_stmt(&e, "&x->p->v").unwrap_or_default()),
                    _ => {
                        let d = self.drop_stmt(&e, "&x->p->buf[(x->p->head + i) % x->p->cap]").unwrap_or_default();
                        format!("for (uint64_t i = 0; i < x->p->len; i++) {{ {} }} free(x->p->buf); pthread_mutex_destroy(&x->p->mu); pthread_cond_destroy(&x->p->cv);", d)
                    }
                };
                drop.push_str(&format!("if (x->p) {{ if (atomic_fetch_sub(&x->p->rc, 1) == 1) {{ {} free(x->p); }} x->p = NULL; }}", inner));
                clone.push_str("atomic_fetch_add(&x->p->rc, 1); return *x;");
            }
            Ty::Fn(..) => {
                drop.push_str("if (x->drop) x->drop(x->env); x->env = NULL;");
                clone.push_str(&format!("{} r = *x; if (x->clone) r.env = x->clone(x->env); return r;", ct));
            }
            Ty::Box(e) => {
                let e = (**e).clone();
                let et = self.ctype(&e);
                if let Some(d) = self.drop_stmt(&e, "x->p") {
                    drop.push_str(&format!("if (x->p) {{ {} }} ", d));
                }
                drop.push_str("free(x->p); x->p = NULL;");
                clone.push_str(&format!("{ct} r; r.p = ({et}*)ei_alloc(sizeof({et})); *r.p = {c}; return r;", ct = ct, et = et, c = self.clone_val(&e, "x->p")));
            }
            Ty::Map(k, v) => {
                let (k, v) = ((**k).clone(), (**v).clone());
                let (kt, vt) = (self.ctype(&k), self.ctype(&v));
                let mut inner = String::new();
                if let Some(d) = self.drop_stmt(&k, "&x->k[i]") {
                    inner.push_str(&d);
                    inner.push(' ');
                }
                if let Some(d) = self.drop_stmt(&v, "&x->v[i]") {
                    inner.push_str(&d);
                }
                if !inner.is_empty() {
                    drop.push_str(&format!("for (uint64_t i = 0; i < x->cap; i++) if (x->s[i] == 1) {{ {} }} ", inner));
                }
                drop.push_str("free(x->k); free(x->v); free(x->s); x->k = NULL; x->v = NULL; x->s = NULL; x->len = 0; x->cap = 0; x->used = 0;");
                clone.push_str(&format!(
                    "{ct} r; r.len = x->len; r.cap = x->cap; r.used = x->used; r.k = ({kt}*)ei_alloc(x->cap * sizeof({kt})); r.v = ({vt}*)ei_alloc(x->cap * sizeof({vt})); r.s = (uint8_t*)ei_alloc(x->cap); \
                     for (uint64_t i = 0; i < x->cap; i++) {{ r.s[i] = x->s[i]; if (x->s[i] == 1) {{ r.k[i] = {ck}; r.v[i] = {cv}; }} }} return r;",
                    ct = ct,
                    kt = kt,
                    vt = vt,
                    ck = self.clone_val(&k, "&x->k[i]"),
                    cv = self.clone_val(&v, "&x->v[i]")
                ));
            }
            _ => {}
        }
        self.aux_bodies.push_str(&format!("static void ei_drop_{n}({ct}* x) {{ {d} }}\nstatic {ct} ei_clone_{n}(const {ct}* x) {{ {c} }}\n", n = n, ct = ct, d = drop, c = clone));
    }

    fn hash_expr(&self, k: &Ty, v: &str) -> String {
        match k {
            Ty::String => format!("ei_hash_str({}.p)", wrap(v)),
            Ty::Str => format!("ei_hash_str({})", v),
            _ => format!("ei_hash_u64((uint64_t)({}))", v),
        }
    }

    /// Per-instance operations of List / Map / Box.
    fn gen_ops(&mut self, ty: &Ty) {
        let ct = self.ctype(ty);
        let n = mangle(&ty.to_string());
        let mut protos = String::new();
        let mut body = String::new();
        match ty {
            Ty::List(e) => {
                let e = (**e).clone();
                let et = self.ctype(&e);
                protos.push_str(&format!("static void ei_push_{n}({ct}* l, {et} x);\nstatic bool ei_has_{n}(const {ct}* l, {et} x);\n", n = n, ct = ct, et = et));
                body.push_str(&format!(
                    "static void ei_push_{n}({ct}* l, {et} x) {{ if (l->len == l->cap) {{ uint64_t nc = l->cap ? l->cap * 2 : 4; {et}* nd = ({et}*)ei_alloc(nc * sizeof({et})); if (l->len) memcpy(nd, l->d, l->len * sizeof({et})); free(l->d); l->d = nd; l->cap = nc; }} l->d[l->len++] = x; }}\n",
                    n = n, ct = ct, et = et
                ));
                let eq = self.eq_expr(&e, "l->d[i]", "x");
                body.push_str(&format!("static bool ei_has_{n}(const {ct}* l, {et} x) {{ for (uint64_t i = 0; i < l->len; i++) if ({eq}) return true; return false; }}\n", n = n, ct = ct, et = et, eq = crate::stmt::unparen(&eq)));
            }
            Ty::Mutex(e) => {
                let e = (**e).clone();
                let et = self.ctype(&e);
                let ft = Ty::Fn(vec![e.clone()], Box::new(e.clone()));
                let fc = self.ctype(&ft);
                let clone_v = self.clone_val(&e, "&m->p->v");
                let drop_v = self.drop_stmt(&e, "&m->p->v").unwrap_or_default();
                protos.push_str(&format!(
                    "static {ct} ei_mxnew_{n}({et} v);\nstatic {et} ei_mxget_{n}(const {ct}* m);\nstatic void ei_mxset_{n}(const {ct}* m, {et} v);\nstatic void ei_mxupd_{n}(const {ct}* m, {fc} f);\n",
                    ct = ct, n = n, et = et, fc = fc
                ));
                body.push_str(&format!(
                    "struct {ct}c {{ atomic_int rc; pthread_mutex_t mu; {et} v; }};\n\
                     static {ct} ei_mxnew_{n}({et} v) {{ {ct} m; m.p = ({ct}c*)ei_alloc(sizeof(*m.p)); atomic_init(&m.p->rc, 1); pthread_mutex_init(&m.p->mu, NULL); m.p->v = v; return m; }}\n\
                     static {et} ei_mxget_{n}(const {ct}* m) {{ pthread_mutex_lock(&m->p->mu); {et} r = {cv}; pthread_mutex_unlock(&m->p->mu); return r; }}\n\
                     static void ei_mxset_{n}(const {ct}* m, {et} v) {{ pthread_mutex_lock(&m->p->mu); {dv} m->p->v = v; pthread_mutex_unlock(&m->p->mu); }}\n\
                     static void ei_mxupd_{n}(const {ct}* m, {fc} f) {{ pthread_mutex_lock(&m->p->mu); {et} nv = f.call(f.env, m->p->v); {dv} m->p->v = nv; pthread_mutex_unlock(&m->p->mu); {df} }}\n",
                    ct = ct, n = n, et = et, fc = fc, cv = clone_v, dv = drop_v, df = self.drop_stmt(&ft, "&f").unwrap_or_default()
                ).replace("&m->p->v)", "&m->p->v)"));
            }
            Ty::Chan(e) => {
                let e = (**e).clone();
                let et = self.ctype(&e);
                protos.push_str(&format!(
                    "static {ct} ei_chnew_{n}(void);\nstatic void ei_chsend_{n}(const {ct}* c, {et} v);\nstatic bool ei_chrecv_{n}(const {ct}* c, {et}* out);\nstatic void ei_chclose_{n}(const {ct}* c);\n",
                    ct = ct, n = n, et = et
                ));
                body.push_str(&format!(
                    "struct {ct}c {{ atomic_int rc; pthread_mutex_t mu; pthread_cond_t cv; {et}* buf; uint64_t head, len, cap; bool closed; }};\n\
                     static {ct} ei_chnew_{n}(void) {{ {ct} c; c.p = ({ct}c*)ei_alloc(sizeof(*c.p)); atomic_init(&c.p->rc, 1); pthread_mutex_init(&c.p->mu, NULL); pthread_cond_init(&c.p->cv, NULL); c.p->buf = NULL; c.p->head = 0; c.p->len = 0; c.p->cap = 0; c.p->closed = false; return c; }}\n\
                     static void ei_chsend_{n}(const {ct}* c, {et} v) {{ {ct}c* q = c->p; pthread_mutex_lock(&q->mu); if (q->closed) {{ pthread_mutex_unlock(&q->mu); ei_trap(\"send on a closed channel\", 0); }} \
                       if (q->len == q->cap) {{ uint64_t nc = q->cap ? q->cap * 2 : 4; {et}* nb = ({et}*)ei_alloc(nc * sizeof({et})); for (uint64_t i = 0; i < q->len; i++) nb[i] = q->buf[(q->head + i) % q->cap]; free(q->buf); q->buf = nb; q->head = 0; q->cap = nc; }} \
                       q->buf[(q->head + q->len) % q->cap] = v; q->len++; pthread_cond_signal(&q->cv); pthread_mutex_unlock(&q->mu); }}\n\
                     static bool ei_chrecv_{n}(const {ct}* c, {et}* out) {{ {ct}c* q = c->p; pthread_mutex_lock(&q->mu); while (q->len == 0 && !q->closed) pthread_cond_wait(&q->cv, &q->mu); \
                       if (q->len == 0) {{ pthread_mutex_unlock(&q->mu); return false; }} *out = q->buf[q->head]; q->head = (q->head + 1) % q->cap; q->len--; pthread_mutex_unlock(&q->mu); return true; }}\n\
                     static void ei_chclose_{n}(const {ct}* c) {{ {ct}c* q = c->p; pthread_mutex_lock(&q->mu); q->closed = true; pthread_cond_broadcast(&q->cv); pthread_mutex_unlock(&q->mu); }}\n",
                    ct = ct, n = n, et = et
                ));
            }
            Ty::Task(e) => {
                let e = (**e).clone();
                let unit = e == Ty::Unit;
                let et = if unit { "void".to_string() } else { self.ctype(&e) };
                let ft = Ty::Fn(vec![], Box::new(e.clone()));
                let fc = self.ctype(&ft);
                protos.push_str(&format!("static {ct} ei_spawn_{n}({fc} f);\nstatic {et} ei_tkjoin_{n}(const {ct}* t);\n", ct = ct, n = n, fc = fc, et = et));
                let result_field = if unit { String::new() } else { format!("{} result;", et) };
                let run = if unit { "c->f.call(c->f.env);".to_string() } else { "c->result = c->f.call(c->f.env);".to_string() };
                let ret = if unit { String::new() } else { format!("return {};", self.clone_val(&e, "&t->p->result")) };
                body.push_str(&format!(
                    "struct {ct}c {{ atomic_int rc; pthread_t th; pthread_mutex_t mu; int joined; {fc} f; {rf} }};\n\
                     static void* ei_tkmain_{n}(void* p) {{ {ct}c* c = ({ct}c*)p; {run} return NULL; }}\n\
                     static {ct} ei_spawn_{n}({fc} f) {{ {ct} t; t.p = ({ct}c*)ei_alloc(sizeof(*t.p)); atomic_init(&t.p->rc, 1); pthread_mutex_init(&t.p->mu, NULL); t.p->joined = 0; t.p->f = f; \
                       if (pthread_create(&t.p->th, NULL, ei_tkmain_{n}, t.p) != 0) ei_trap(\"cannot create a thread\", 0); return t; }}\n\
                     static {et} ei_tkjoin_{n}(const {ct}* t) {{ pthread_mutex_lock(&t->p->mu); if (!t->p->joined) {{ pthread_join(t->p->th, NULL); t->p->joined = 1; }} pthread_mutex_unlock(&t->p->mu); {ret} }}\n",
                    ct = ct, n = n, fc = fc, rf = result_field, run = run, et = et, ret = ret
                ));
            }
            Ty::Box(e) => {
                let et = self.ctype(e);
                protos.push_str(&format!("static {ct} ei_bnew_{n}({et} v);\n", n = n, ct = ct, et = et));
                body.push_str(&format!("static {ct} ei_bnew_{n}({et} v) {{ {ct} b; b.p = ({et}*)ei_alloc(sizeof({et})); *b.p = v; return b; }}\n", n = n, ct = ct, et = et));
            }
            Ty::Map(k, v) => {
                let (k, v) = ((**k).clone(), (**v).clone());
                let (kt, vt) = (self.ctype(&k), self.ctype(&v));
                let h = |s: &Self, x: &str| s.hash_expr(&k, x);
                let eq_find = self.eq_expr(&k, "m->k[i]", "key");
                let hk = h(self, "key");
                let hmk = h(self, "m->k[j]");
                protos.push_str(&format!(
                    "static int64_t ei_mfind_{n}(const {ct}* m, {kt} key);\nstatic void ei_minsert_{n}({ct}* m, {kt} key, {vt} val);\nstatic bool ei_mremove_{n}({ct}* m, {kt} key);\nstatic {vt}* ei_mget_{n}(const {ct}* m, {kt} key);\n",
                    n = n, ct = ct, kt = kt, vt = vt
                ));
                body.push_str(&format!(
                    "static int64_t ei_mfind_{n}(const {ct}* m, {kt} key) {{ if (m->cap == 0) return -1; uint64_t i = {hk} & (m->cap - 1); for (uint64_t c = 0; c < m->cap; c++) {{ if (m->s[i] == 0) return -1; if (m->s[i] == 1 && {eq}) return (int64_t)i; i = (i + 1) & (m->cap - 1); }} return -1; }}\n",
                    n = n, ct = ct, kt = kt, hk = hk, eq = eq_find
                ));
                body.push_str(&format!(
                    "static {vt}* ei_mget_{n}(const {ct}* m, {kt} key) {{ int64_t f = ei_mfind_{n}(m, key); return f < 0 ? NULL : &m->v[f]; }}\n",
                    n = n, ct = ct, kt = kt, vt = vt
                ));
                let drop_k = self.drop_stmt(&k, "&m->k[f]").unwrap_or_default();
                let drop_v = self.drop_stmt(&v, "&m->v[f]").unwrap_or_default();
                let drop_key = self.drop_stmt(&k, "&key").unwrap_or_default();
                body.push_str(&format!(
                    "static bool ei_mremove_{n}({ct}* m, {kt} key) {{ int64_t f = ei_mfind_{n}(m, key); if (f < 0) return false; {dk} {dv} m->s[f] = 2; m->len--; return true; }}\n",
                    n = n, ct = ct, kt = kt, dk = drop_k, dv = drop_v
                ));
                body.push_str(&format!(
                    "static void ei_minsert_{n}({ct}* m, {kt} key, {vt} val) {{\n  int64_t f = ei_mfind_{n}(m, key);\n  if (f >= 0) {{ {dv} {dkey} m->v[f] = val; return; }}\n  if ((m->used + 1) * 4 > m->cap * 3) {{\n    uint64_t nc = m->cap ? m->cap * 2 : 8;\n    {kt}* nk = ({kt}*)ei_alloc(nc * sizeof({kt})); {vt}* nv = ({vt}*)ei_alloc(nc * sizeof({vt})); uint8_t* ns = (uint8_t*)ei_alloc(nc); memset(ns, 0, nc);\n    for (uint64_t j = 0; j < m->cap; j++) if (m->s[j] == 1) {{ uint64_t i = {hmk} & (nc - 1); while (ns[i]) i = (i + 1) & (nc - 1); nk[i] = m->k[j]; nv[i] = m->v[j]; ns[i] = 1; }}\n    free(m->k); free(m->v); free(m->s); m->k = nk; m->v = nv; m->s = ns; m->cap = nc; m->used = m->len;\n  }}\n  uint64_t i = {hk} & (m->cap - 1);\n  while (m->s[i] == 1) i = (i + 1) & (m->cap - 1);\n  if (m->s[i] == 0) m->used++;\n  m->k[i] = key; m->v[i] = val; m->s[i] = 1; m->len++;\n}}\n",
                    n = n, ct = ct, kt = kt, vt = vt, dv = drop_v, dkey = drop_key, hk = hk, hmk = hmk
                ));
            }
            _ => {}
        }
        self.aux_protos.push_str(&protos);
        self.aux_bodies.push_str(&body);
    }

    // ------------------------------------------------------------ methods
    fn eval_args(&mut self, rv: &mut V, args: &[Arg], tys: &[Ty], label: &str, pos: Pos) -> R<Vec<V>> {
        if args.len() != tys.len() {
            return err("E0405", pos, format!("`{}` takes {} argument(s), but {} were given", label, tys.len(), args.len()));
        }
        let mut vs: Vec<V> = vec![];
        for (a, t) in args.iter().zip(tys.iter()) {
            if a.inout {
                return err("E0304", a.e.pos, "`inout` is not allowed here");
            }
            let mark = self.out.len();
            let v = self.expr(&a.e, Some(t))?;
            if v.ty != *t {
                return Err(mismatch(a.e.pos, t, &v.ty));
            }
            let mut prev: Vec<&mut V> = vs.iter_mut().collect();
            // a mutated receiver must stay a place: hoisting it would copy the struct
            let mutating = matches!(label.rsplit('.').next().unwrap_or(""), "push_str" | "append" | "push" | "pop" | "clear" | "insert" | "remove" | "set");
            if !mutating {
                prev.push(rv);
            }
            self.fix_order(prev, mark);
            vs.push(v);
        }
        Ok(vs)
    }

    fn unit(c: String) -> V {
        V { ty: Ty::Unit, c, k: None, pure: false }
    }
    fn usz(&self, c: String) -> V {
        V { ty: Ty::Int(IntTy::Usize), c, k: None, pure: true }
    }

    pub fn heap_static(&mut self, e: &Expr, head: &str, name: &str, args: &[Arg], exp: Option<&Ty>) -> R<V> {
        let label = format!("{}.{}", head, name);
        let mut dummy = V { ty: Ty::Unit, c: String::new(), k: None, pure: true };
        match (head, name) {
            ("String", "from") => {
                let vs = self.eval_args(&mut dummy, args, &[Ty::Str], &label, e.pos)?;
                Ok(V { ty: Ty::String, c: format!("ei_str_from({})", vs[0].c), k: None, pure: false })
            }
            ("String", "from_int") => {
                let vs = self.eval_args(&mut dummy, args, &[Ty::Int(IntTy::I64)], &label, e.pos)?;
                Ok(V { ty: Ty::String, c: format!("ei_str_from_i64({})", vs[0].c), k: None, pure: false })
            }
            ("List", "new") | ("Map", "new") => {
                let want_list = head == "List";
                let ty = match exp {
                    Some(t @ Ty::List(_)) if want_list => t.clone(),
                    Some(t @ Ty::Map(..)) if !want_list => t.clone(),
                    _ => {
                        return Err(Diag::new("E0409", e.pos, format!("cannot infer the type arguments of `{}`", head))
                            .help(format!("annotate the binding, e.g. `let x: {} = {}.new()`", if want_list { "List[i32]" } else { "Map[str, i32]" }, head)))
                    }
                };
                if !args.is_empty() {
                    return err("E0405", e.pos, format!("`{}` takes no arguments", label));
                }
                let c = if want_list { format!("(({}){{ NULL, 0, 0 }})", self.ctype(&ty)) } else { format!("(({}){{ NULL, NULL, NULL, 0, 0, 0 }})", self.ctype(&ty)) };
                Ok(V { ty, c, k: None, pure: true })
            }
            ("Box", "new") => {
                if args.len() != 1 {
                    return err("E0405", e.pos, "`Box.new` takes exactly one argument");
                }
                let hint = match exp {
                    Some(Ty::Box(t)) => Some((**t).clone()),
                    _ => None,
                };
                let v = self.expr(&args[0].e, hint.as_ref())?;
                if let Some(h) = &hint {
                    if v.ty != *h {
                        return Err(mismatch(args[0].e.pos, h, &v.ty));
                    }
                }
                if matches!(v.ty, Ty::Unit | Ty::Never) {
                    return err("E0401", args[0].e.pos, "can't box ()");
                }
                let ty = Ty::Box(Box::new(v.ty.clone()));
                self.note_ty(&ty);
                let c = format!("ei_bnew_{}({})", mangle(&ty.to_string()), self.take(&v));
                Ok(V { ty, c, k: None, pure: false })
            }
            ("Mutex", "new") => {
                if args.len() != 1 {
                    return err("E0405", e.pos, "`Mutex.new` takes exactly one argument");
                }
                let hint = match exp {
                    Some(Ty::Mutex(t)) => Some((**t).clone()),
                    _ => None,
                };
                let v = self.expr(&args[0].e, hint.as_ref())?;
                if let Some(h) = &hint {
                    if v.ty != *h {
                        return Err(mismatch(args[0].e.pos, h, &v.ty));
                    }
                }
                if matches!(v.ty, Ty::Unit | Ty::Never) {
                    return err("E0401", args[0].e.pos, "can't put () in a Mutex");
                }
                let ty = Ty::Mutex(Box::new(v.ty.clone()));
                self.note_ty(&ty);
                let c = format!("ei_mxnew_{}({})", mangle(&ty.to_string()), self.take(&v));
                Ok(V { ty, c, k: None, pure: false })
            }
            ("Chan", "new") => {
                let ty = match exp {
                    Some(t @ Ty::Chan(_)) => t.clone(),
                    _ => {
                        return Err(Diag::new("E0409", e.pos, "cannot infer the element type of `Chan`").help("annotate the binding, e.g. `let c: Chan[i32] = Chan.new()`"))
                    }
                };
                if !args.is_empty() {
                    return err("E0405", e.pos, "`Chan.new` takes no arguments");
                }
                self.note_ty(&ty);
                Ok(V { c: format!("ei_chnew_{}()", mangle(&ty.to_string())), ty, k: None, pure: false })
            }
            _ => err("E0115", e.pos, format!("`{}` has no associated function `{}`", head, name)),
        }
    }

    pub fn heap_method(&mut self, e: &Expr, recv: &Expr, mut rv: V, name: &str, args: &[Arg]) -> R<V> {
        let label = format!("{}.{}", rv.ty, name);
        let ty = rv.ty.clone();
        match (&ty, name) {
            (Ty::String, "len") | (Ty::List(_), "len") => {
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                Ok(self.usz(format!("{}.len", wrap(&rv.c))))
            }
            (Ty::String, "is_empty") | (Ty::List(_), "is_empty") | (Ty::Map(..), "is_empty") => {
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                Ok(V { ty: Ty::Bool, c: format!("({}.len == 0)", wrap(&rv.c)), k: None, pure: true })
            }
            (Ty::Map(..), "len") => {
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                Ok(self.usz(format!("{}.len", wrap(&rv.c))))
            }
            (Ty::String, "push_str") => {
                self.check_assignable(recv, "modify")?;
                let vs = self.eval_args(&mut rv, args, &[Ty::Str], &label, e.pos)?;
                Ok(Self::unit(format!("ei_str_push(&{}, {})", wrap(&rv.c), vs[0].c)))
            }
            (Ty::String, "append") => {
                self.check_assignable(recv, "modify")?;
                let vs = self.eval_args(&mut rv, args, &[Ty::String], &label, e.pos)?;
                Ok(Self::unit(format!("ei_str_append(&{}, &{})", wrap(&rv.c), wrap(&vs[0].c))))
            }
            (Ty::List(el), "push") => {
                self.check_assignable(recv, "modify")?;
                let el = (**el).clone();
                let vs = self.eval_args(&mut rv, args, &[el], &label, e.pos)?;
                let x = self.take(&vs[0]);
                Ok(Self::unit(format!("ei_push_{}(&{}, {})", mangle(&ty.to_string()), wrap(&rv.c), x)))
            }
            (Ty::List(el), "pop") => {
                self.check_assignable(recv, "modify")?;
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                let opt = self.inst_type("Option", vec![(**el).clone()], e.pos)?;
                let k = match &opt {
                    Ty::Enum(k) => k.clone(),
                    _ => unreachable!(),
                };
                let (p, t) = (self.tmp(), self.tmp());
                self.emit(format!("{}* {} = &{};", self.ctype(&ty), p, wrap(&rv.c)));
                self.emit(format!("{} {};", self.ctype(&opt), t));
                self.emit(format!(
                    "if ({p}->len == 0) {t} = ({o}){{ .tag = {none} }}; else {t} = ({o}){{ .tag = {some}, .u.m_Some = {{ {p}->d[--{p}->len] }} }};",
                    p = p,
                    t = t,
                    o = self.ctype(&opt),
                    none = self.tag_const(&k, "None"),
                    some = self.tag_const(&k, "Some")
                ));
                Ok(V { ty: opt, c: t, k: None, pure: true })
            }
            (Ty::List(_), "clear") => {
                self.check_assignable(recv, "modify")?;
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                self.need_glue(&ty);
                let m = mangle(&ty.to_string());
                let p = self.tmp();
                self.emit(format!("{}* {} = &{};", self.ctype(&ty), p, wrap(&rv.c)));
                self.emit(format!("ei_drop_{m}({p}); *{p} = ({ct}){{ NULL, 0, 0 }};", m = m, p = p, ct = self.ctype(&ty)));
                Ok(Self::unit("(void)0".into()))
            }
            (Ty::List(el), "get") => {
                let el = (**el).clone();
                let vs = self.eval_args(&mut rv, args, &[Ty::Int(IntTy::Usize)], &label, e.pos)?;
                if !rv.pure {
                    let t = self.tmp();
                    self.emit(format!("{} {} = {};", self.ctype(&ty), t, rv.c));
                    rv.c = t;
                }
                let place = format!("{}.d[ei_idx({}, {}.len, {})]", wrap(&rv.c), vs[0].c, wrap(&rv.c), e.pos.line);
                let c = if self.owns(&el) {
                    self.need_glue(&el);
                    format!("ei_clone_{}(&{})", mangle(&el.to_string()), place)
                } else {
                    place
                };
                Ok(V { ty: el, c, k: None, pure: false })
            }
            (Ty::List(el), "contains") => {
                let el = (**el).clone();
                let vs = self.eval_args(&mut rv, args, &[el], &label, e.pos)?;
                Ok(V { ty: Ty::Bool, c: format!("ei_has_{}(&{}, {})", mangle(&ty.to_string()), wrap(&rv.c), vs[0].c), k: None, pure: false })
            }
            (Ty::Map(k, v), "insert") => {
                self.check_assignable(recv, "modify")?;
                let (k, v) = ((**k).clone(), (**v).clone());
                let vs = self.eval_args(&mut rv, args, &[k, v], &label, e.pos)?;
                let kc = self.take(&vs[0]);
                let vc = self.take(&vs[1]);
                Ok(Self::unit(format!("ei_minsert_{}(&{}, {}, {})", mangle(&ty.to_string()), wrap(&rv.c), kc, vc)))
            }
            (Ty::Map(k, _), "contains") => {
                let k = (**k).clone();
                let vs = self.eval_args(&mut rv, args, &[k], &label, e.pos)?;
                Ok(V { ty: Ty::Bool, c: format!("(ei_mfind_{}(&{}, {}) >= 0)", mangle(&ty.to_string()), wrap(&rv.c), vs[0].c), k: None, pure: false })
            }
            (Ty::Map(k, _), "remove") => {
                self.check_assignable(recv, "modify")?;
                let k = (**k).clone();
                let vs = self.eval_args(&mut rv, args, &[k], &label, e.pos)?;
                Ok(V { ty: Ty::Bool, c: format!("ei_mremove_{}(&{}, {})", mangle(&ty.to_string()), wrap(&rv.c), vs[0].c), k: None, pure: false })
            }
            (Ty::Map(k, v), "get") => {
                let (k, v) = ((**k).clone(), (**v).clone());
                let vs = self.eval_args(&mut rv, args, &[k], &label, e.pos)?;
                let opt = self.inst_type("Option", vec![v.clone()], e.pos)?;
                let ok = match &opt {
                    Ty::Enum(k) => k.clone(),
                    _ => unreachable!(),
                };
                let (p, t) = (self.tmp(), self.tmp());
                let vt = self.ctype(&v);
                self.emit(format!("{}* {} = ei_mget_{}(&{}, {});", vt, p, mangle(&ty.to_string()), wrap(&rv.c), vs[0].c));
                self.emit(format!("{} {};", self.ctype(&opt), t));
                let val = self.clone_val(&v, &p);
                self.emit(format!(
                    "if ({p}) {t} = ({o}){{ .tag = {some}, .u.m_Some = {{ {val} }} }}; else {t} = ({o}){{ .tag = {none} }};",
                    p = p,
                    t = t,
                    o = self.ctype(&opt),
                    some = self.tag_const(&ok, "Some"),
                    none = self.tag_const(&ok, "None"),
                    val = val
                ));
                Ok(V { ty: opt, c: t, k: None, pure: true })
            }
            (Ty::List(el), "map") | (Ty::List(el), "filter") | (Ty::List(el), "for_each") | (Ty::List(el), "any") | (Ty::List(el), "all") => {
                let el = (**el).clone();
                if args.len() != 1 {
                    return err("E0405", e.pos, format!("`{}` takes exactly one closure", label));
                }
                let want_ret = match name {
                    "filter" | "any" | "all" => Some(Ty::Bool),
                    "for_each" => Some(Ty::Unit),
                    _ => None,
                };
                self.lam_hint = Some((vec![Some(el.clone())], want_ret.clone()));
                let mark = self.out.len();
                let mut fv = self.expr(&args[0].e, None)?;
                self.lam_hint = None;
                self.fix_order(vec![&mut rv], mark);
                let rt = match &fv.ty {
                    Ty::Fn(ps, r) if ps.len() == 1 && ps[0] == el => (**r).clone(),
                    t => return err("E0401", args[0].e.pos, format!("expected a closure taking {}, found {}", el, t)),
                };
                if let Some(w) = &want_ret {
                    if rt != *w {
                        return Err(mismatch(args[0].e.pos, w, &rt));
                    }
                }
                if !fv.pure {
                    let t = self.tmp();
                    self.emit(format!("{} {} = {};", self.ctype(&fv.ty), t, fv.c));
                    fv.c = t;
                }
                let p = self.tmp();
                self.emit(format!("{}* {} = &{};", self.ctype(&ty), p, wrap(&rv.c)));
                let f = wrap(&fv.c);
                let i = self.tmp();
                let item = format!("{}->d[{}]", p, i);
                match name {
                    "map" => {
                        if matches!(rt, Ty::Unit | Ty::Never) {
                            return err("E0401", args[0].e.pos, "`map` needs a closure that returns a value");
                        }
                        let out_ty = Ty::List(Box::new(rt.clone()));
                        self.note_ty(&out_ty);
                        let out = self.tmp();
                        self.emit(format!("{} {} = ({}){{ NULL, 0, 0 }};", self.ctype(&out_ty), out, self.ctype(&out_ty)));
                        self.emit(format!("for (uint64_t {i} = 0; {i} < {p}->len; {i}++) {{ {rc} r = {f}.call({f}.env, {item}); ei_push_{m}(&{out}, r); }}", i = i, p = p, rc = self.ctype(&rt), f = f, item = item, m = mangle(&out_ty.to_string()), out = out));
                        Ok(V { ty: out_ty, c: out, k: None, pure: true })
                    }
                    "filter" => {
                        let out = self.tmp();
                        self.emit(format!("{} {} = ({}){{ NULL, 0, 0 }};", self.ctype(&ty), out, self.ctype(&ty)));
                        let keep = self.clone_val(&el, &format!("&{}", item));
                        self.emit(format!("for (uint64_t {i} = 0; {i} < {p}->len; {i}++) {{ if ({f}.call({f}.env, {item})) ei_push_{m}(&{out}, {keep}); }}", i = i, p = p, f = f, item = item, m = mangle(&ty.to_string()), out = out, keep = keep));
                        Ok(V { ty: ty.clone(), c: out, k: None, pure: true })
                    }
                    "for_each" => {
                        self.emit(format!("for (uint64_t {i} = 0; {i} < {p}->len; {i}++) {f}.call({f}.env, {item});", i = i, p = p, f = f, item = item));
                        Ok(Self::unit("(void)0".into()))
                    }
                    _ => {
                        let any = name == "any";
                        let r = self.tmp();
                        self.emit(format!("bool {} = {};", r, if any { "false" } else { "true" }));
                        self.emit(format!(
                            "for (uint64_t {i} = 0; {i} < {p}->len; {i}++) {{ if ({neg}{f}.call({f}.env, {item})) {{ {r} = {val}; break; }} }}",
                            i = i, p = p, f = f, item = item, r = r, neg = if any { "" } else { "!" }, val = if any { "true" } else { "false" }
                        ));
                        Ok(V { ty: Ty::Bool, c: r, k: None, pure: true })
                    }
                }
            }
            (Ty::List(el), "fold") => {
                let el = (**el).clone();
                if args.len() != 2 {
                    return err("E0405", e.pos, "`fold` takes an initial value and a closure");
                }
                let mark = self.out.len();
                let init = self.expr(&args[0].e, None)?;
                self.fix_order(vec![&mut rv], mark);
                let acc_ty = init.ty.clone();
                self.lam_hint = Some((vec![Some(acc_ty.clone()), Some(el.clone())], Some(acc_ty.clone())));
                let mark = self.out.len();
                let mut fv = self.expr(&args[1].e, None)?;
                self.lam_hint = None;
                self.fix_order(vec![&mut rv], mark);
                match &fv.ty {
                    Ty::Fn(ps, r) if ps.len() == 2 && ps[0] == acc_ty && ps[1] == el && **r == acc_ty => {}
                    t => return err("E0401", args[1].e.pos, format!("expected fn({}, {}) -> {}, found {}", acc_ty, el, acc_ty, t)),
                }
                if !fv.pure {
                    let t = self.tmp();
                    self.emit(format!("{} {} = {};", self.ctype(&fv.ty), t, fv.c));
                    fv.c = t;
                }
                let p = self.tmp();
                self.emit(format!("{}* {} = &{};", self.ctype(&ty), p, wrap(&rv.c)));
                let acc = self.tmp();
                let ic = self.take(&init);
                self.emit(format!("{} {} = {};", self.ctype(&acc_ty), acc, ic));
                let f = wrap(&fv.c);
                let i = self.tmp();
                let n = self.tmp();
                let drop = self.drop_stmt(&acc_ty, &format!("&{}", acc)).unwrap_or_default();
                self.emit(format!(
                    "for (uint64_t {i} = 0; {i} < {p}->len; {i}++) {{ {ac} {n} = {f}.call({f}.env, {acc}, {p}->d[{i}]); {drop} {acc} = {n}; }}",
                    i = i, p = p, ac = self.ctype(&acc_ty), n = n, f = f, acc = acc, drop = drop
                ));
                Ok(V { ty: acc_ty, c: acc, k: None, pure: true })
            }
            (Ty::List(el), "sum") => {
                let it = match &**el {
                    Ty::Int(it) => *it,
                    t => return err("E0401", e.pos, format!("`sum` needs a List of integers, found List[{}]", t)),
                };
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                let p = self.tmp();
                self.emit(format!("{}* {} = &{};", self.ctype(&ty), p, wrap(&rv.c)));
                let acc = self.tmp();
                let i = self.tmp();
                self.emit(format!("{} {} = 0;", it.c(), acc));
                let add = Self::arith_c(BinOp::Add, it, &acc, &format!("{}->d[{}]", p, i), e.pos.line);
                self.emit(format!("for (uint64_t {i} = 0; {i} < {p}->len; {i}++) {acc} = {add};", i = i, p = p, acc = acc, add = add));
                Ok(V { ty: Ty::Int(it), c: acc, k: None, pure: true })
            }
            (Ty::Task(el), "join") => {
                let el = (**el).clone();
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                let c = format!("ei_tkjoin_{}(&{})", mangle(&ty.to_string()), wrap(&rv.c));
                Ok(V { ty: el, c, k: None, pure: false })
            }
            (Ty::Mutex(el), "get") => {
                let el = (**el).clone();
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                Ok(V { ty: el, c: format!("ei_mxget_{}(&{})", mangle(&ty.to_string()), wrap(&rv.c)), k: None, pure: false })
            }
            (Ty::Mutex(el), "set") => {
                let el = (**el).clone();
                let vs = self.eval_args(&mut rv, args, &[el], &label, e.pos)?;
                let x = self.take(&vs[0]);
                Ok(Self::unit(format!("ei_mxset_{}(&{}, {})", mangle(&ty.to_string()), wrap(&rv.c), x)))
            }
            (Ty::Mutex(el), "update") => {
                let el = (**el).clone();
                if args.len() != 1 {
                    return err("E0405", e.pos, "`update` takes exactly one closure");
                }
                self.lam_hint = Some((vec![Some(el.clone())], Some(el.clone())));
                let mark = self.out.len();
                let fv = self.expr(&args[0].e, None)?;
                self.lam_hint = None;
                self.fix_order(vec![&mut rv], mark);
                let want = Ty::Fn(vec![el.clone()], Box::new(el.clone()));
                if fv.ty != want {
                    return Err(mismatch(args[0].e.pos, &want, &fv.ty));
                }
                let f = if self.fresh.contains(&fv.c) { fv.c.clone() } else { self.take(&fv) };
                let _ = f;
                Ok(Self::unit(format!("ei_mxupd_{}(&{}, {})", mangle(&ty.to_string()), wrap(&rv.c), fv.c)))
            }
            (Ty::Chan(el), "send") => {
                let el = (**el).clone();
                let vs = self.eval_args(&mut rv, args, &[el], &label, e.pos)?;
                let x = self.take(&vs[0]);
                Ok(Self::unit(format!("ei_chsend_{}(&{}, {})", mangle(&ty.to_string()), wrap(&rv.c), x)))
            }
            (Ty::Chan(_), "close") => {
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                Ok(Self::unit(format!("ei_chclose_{}(&{})", mangle(&ty.to_string()), wrap(&rv.c))))
            }
            (Ty::Chan(el), "recv") => {
                let el = (**el).clone();
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                let opt = self.inst_type("Option", vec![el.clone()], e.pos)?;
                let ok = match &opt {
                    Ty::Enum(k) => k.clone(),
                    _ => unreachable!(),
                };
                let (item, got, t) = (self.tmp(), self.tmp(), self.tmp());
                self.emit(format!("{} {};", self.ctype(&el), item));
                self.emit(format!("bool {} = ei_chrecv_{}(&{}, &{});", got, mangle(&ty.to_string()), wrap(&rv.c), item));
                self.emit(format!("{} {};", self.ctype(&opt), t));
                self.emit(format!(
                    "if ({got}) {t} = ({o}){{ .tag = {some}, .u.m_Some = {{ {item} }} }}; else {t} = ({o}){{ .tag = {none} }};",
                    got = got, t = t, o = self.ctype(&opt), some = self.tag_const(&ok, "Some"), none = self.tag_const(&ok, "None"), item = item
                ));
                Ok(V { ty: opt, c: t, k: None, pure: true })
            }
            (Ty::Box(el), "get") => {
                let el = (**el).clone();
                self.eval_args(&mut rv, args, &[], &label, e.pos)?;
                let place = format!("(*{}.p)", wrap(&rv.c));
                let c = if self.owns(&el) {
                    self.need_glue(&el);
                    format!("ei_clone_{}(&{})", mangle(&el.to_string()), place)
                } else {
                    place
                };
                Ok(V { ty: el, c, k: None, pure: false })
            }
            (Ty::Box(el), "set") => {
                self.check_assignable(recv, "modify")?;
                let el = (**el).clone();
                let vs = self.eval_args(&mut rv, args, &[el.clone()], &label, e.pos)?;
                let x = self.take(&vs[0]);
                let p = self.tmp();
                self.emit(format!("{}* {} = &{};", self.ctype(&ty), p, wrap(&rv.c)));
                if let Some(d) = self.drop_stmt(&el, &format!("{}->p", p)) {
                    self.emit(d);
                }
                Ok(Self::unit(format!("*{}->p = {}", p, x)))
            }
            _ => err("E0115", e.pos, format!("type {} has no method `{}`", ty, name)),
        }
    }
}
