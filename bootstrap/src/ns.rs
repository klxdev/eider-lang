//! Module namespacing. A module imported from `geo.ei` gets prefix `geo`; its top-level names
//! (types, variants, fns, consts, traits) are renamed `geo__Name` and every reference inside the
//! module is rewritten to match. Importers write `geo.Name` (or `alias.Name`); the parser turns
//! that into the same mangled identifier. Locals that shadow a top-level name are left alone.

use crate::ast::*;
use std::collections::HashSet;

pub fn prefix_of(path: &str) -> String {
    let stem = std::path::Path::new(path).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    stem.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' }).collect()
}

/// `a__B` -> `a.B` for messages (only between identifier characters).
pub fn demangle(s: &str) -> String {
    let b: Vec<char> = s.chars().collect();
    let mut o = String::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == '_' && i + 1 < b.len() && b[i + 1] == '_' && i > 0 && b[i - 1].is_ascii_alphanumeric() && i + 2 < b.len() && b[i + 2].is_ascii_alphabetic() {
            o.push('.');
            i += 2;
        } else {
            o.push(b[i]);
            i += 1;
        }
    }
    o
}

struct Ns<'a> {
    prefix: &'a str,
    own: HashSet<String>,
    /// generic parameter names currently in scope (they shadow type names)
    generics: Vec<String>,
    locals: HashSet<String>,
}

pub fn mangle_module(items: &mut [Item], prefix: &str) {
    let mut own = HashSet::new();
    for it in items.iter() {
        match it {
            Item::Type(t) => {
                own.insert(t.name.clone());
                if let TypeKind::Enum(vs) = &t.kind {
                    for v in vs {
                        own.insert(v.name.clone());
                    }
                }
            }
            Item::Fn(f) if !f.is_extern && f.name != "main" => {
                own.insert(f.name.clone());
            }
            Item::Const(c) => {
                own.insert(c.name.clone());
            }
            Item::Trait(t) => {
                own.insert(t.name.clone());
            }
            _ => {}
        }
    }
    let mut ns = Ns { prefix, own, generics: vec![], locals: HashSet::new() };
    for it in items.iter_mut() {
        match it {
            Item::Type(t) => {
                ns.generics = t.generics.clone();
                t.name = ns.name(&t.name);
                match &mut t.kind {
                    TypeKind::Enum(vs) => {
                        for v in vs {
                            v.name = ns.name(&v.name);
                            for (_, ty) in &mut v.fields {
                                ns.ty(ty);
                            }
                        }
                    }
                    TypeKind::Record(fs) => {
                        for (_, ty, _) in fs {
                            ns.ty(ty);
                        }
                    }
                }
            }
            Item::Fn(f) => {
                let rename = !f.is_extern && f.name != "main";
                ns.func(f, rename);
            }
            Item::Const(c) => {
                ns.generics.clear();
                c.name = ns.name(&c.name);
                ns.ty(&mut c.ty);
                ns.locals.clear();
                ns.expr(&mut c.value);
            }
            Item::Trait(t) => {
                ns.generics.clear();
                t.name = ns.name(&t.name);
                for m in &mut t.methods {
                    ns.func(m, false);
                }
            }
            Item::Impl(im) => {
                ns.generics = im.generics.iter().map(|g| g.name.clone()).collect();
                for g in &mut im.generics {
                    for b in &mut g.bounds {
                        *b = ns.name(b);
                    }
                }
                if let Some((n, _)) = &mut im.trait_ {
                    *n = ns.name(n);
                }
                ns.ty(&mut im.target);
                let gs = ns.generics.clone();
                for m in &mut im.methods {
                    ns.generics = gs.clone();
                    ns.func(m, false);
                }
            }
            Item::Test(t) => {
                ns.generics.clear();
                ns.locals.clear();
                ns.block(&mut t.body);
            }
            Item::Import(..) => {}
        }
    }
}

impl<'a> Ns<'a> {
    fn name(&self, n: &str) -> String {
        if self.own.contains(n) {
            format!("{}__{}", self.prefix, n)
        } else {
            n.to_string()
        }
    }

    fn func(&mut self, f: &mut FnDecl, rename: bool) {
        let outer = self.generics.clone();
        self.generics.extend(f.generics.iter().map(|g| g.name.clone()));
        for g in &mut f.generics {
            for b in &mut g.bounds {
                *b = self.name(b);
            }
        }
        if rename {
            f.name = self.name(&f.name);
        }
        for p in &mut f.params {
            self.ty(&mut p.ty);
        }
        if let Some(r) = &mut f.ret {
            self.ty(r);
        }
        self.locals.clear();
        for p in &f.params {
            self.locals.insert(p.name.clone());
        }
        if let Some(b) = &f.body {
            let mut found = HashSet::new();
            collect_block(b, &self.own, &mut found);
            self.locals.extend(found);
        }
        if let Some(b) = &mut f.body {
            self.block(b);
        }
        self.generics = outer;
    }

    fn ty(&self, t: &mut TyAst) {
        match t {
            TyAst::Name(n, _) => {
                if !self.generics.contains(n) {
                    *n = self.name(n);
                }
            }
            TyAst::Generic(n, args, _) => {
                if !self.generics.contains(n) {
                    *n = self.name(n);
                }
                for a in args {
                    self.ty(a);
                }
            }
            TyAst::Array(e, _, _) => self.ty(e),
            TyAst::Tuple(ts) => ts.iter_mut().for_each(|t| self.ty(t)),
            TyAst::Fn(ps, r, _) => {
                ps.iter_mut().for_each(|t| self.ty(t));
                if let Some(r) = r {
                    self.ty(r);
                }
            }
            TyAst::Unit => {}
        }
    }

    fn block(&mut self, b: &mut Block) {
        for s in &mut b.stmts {
            self.stmt(s);
        }
    }

    fn stmt(&mut self, s: &mut Stmt) {
        match &mut s.k {
            SK::Let { ty, init, .. } => {
                if let Some(t) = ty {
                    self.ty(t);
                }
                self.expr(init);
            }
            SK::LetPat { pat, init, .. } => {
                self.pat(pat);
                self.expr(init);
            }
            SK::Assign { target, value, .. } => {
                self.expr(target);
                self.expr(value);
            }
            SK::Expr(e) => self.expr(e),
            SK::While(c, b) => {
                self.expr(c);
                self.block(b);
            }
            SK::For { lo, hi, body, .. } => {
                self.expr(lo);
                self.expr(hi);
                self.block(body);
            }
            SK::ForEach { iter, body, .. } => {
                self.expr(iter);
                self.block(body);
            }
            SK::Return(e) => {
                if let Some(e) = e {
                    self.expr(e);
                }
            }
            SK::Break | SK::Continue => {}
            SK::Assert(e, _) => self.expr(e),
        }
    }

    fn expr(&mut self, e: &mut Expr) {
        match &mut e.k {
            EK::Int(_) | EK::Bool(_) | EK::Str(_) => {}
            EK::Ident(n) => {
                if !self.locals.contains(n.as_str()) {
                    *n = self.name(n);
                }
            }
            EK::Unary(_, a) | EK::Try(a) | EK::Field(a, _) => self.expr(a),
            EK::Binary(_, a, b) | EK::Index(a, b) => {
                self.expr(a);
                self.expr(b);
            }
            EK::Call(n, args) => {
                if !self.locals.contains(n.as_str()) {
                    *n = self.name(n);
                }
                for a in args {
                    self.expr(&mut a.e);
                }
            }
            EK::MethodCall(r, _, args) => {
                self.expr(r);
                for a in args {
                    self.expr(&mut a.e);
                }
            }
            EK::Cast(a, t) => {
                self.expr(a);
                self.ty(t);
            }
            EK::ArrayLit(es) | EK::Tuple(es) => es.iter_mut().for_each(|e| self.expr(e)),
            EK::ArrayRepeat(a, _) => self.expr(a),
            EK::Unsafe(b) => self.block(b),
            EK::Block(b) => self.block(b),
            EK::Lambda(ps, r, body) => {
                for (_, t, _) in ps {
                    if let Some(t) = t {
                        self.ty(t);
                    }
                }
                if let Some(r) = r {
                    self.ty(r);
                }
                self.expr(body);
            }
            EK::If(c, t, el) => {
                self.expr(c);
                self.block(t);
                if let Some(el) = el {
                    self.expr(el);
                }
            }
            EK::Match(s, arms, _) => {
                self.expr(s);
                for a in arms {
                    for p in &mut a.pats {
                        self.pat(p);
                    }
                    match &mut a.body {
                        ArmBody::Expr(e) => self.expr(e),
                        ArmBody::Stmt(s) => self.stmt(s),
                    }
                }
            }
        }
    }

    fn pat(&self, p: &mut Pat) {
        match &mut p.k {
            PK::Name(n) => {
                if self.own.contains(n.as_str()) {
                    *n = self.name(n);
                }
            }
            PK::Variant(n, ps) => {
                *n = self.name(n);
                ps.iter_mut().for_each(|p| self.pat(p));
            }
            PK::Tuple(ps) => ps.iter_mut().for_each(|p| self.pat(p)),
            PK::Wild | PK::Int(_) | PK::Bool(_) | PK::Str(_) => {}
        }
    }
}

// ---- binder collection: every name a function body binds locally (not scoped; conservative)

fn collect_pat(p: &Pat, own: &HashSet<String>, out: &mut HashSet<String>) {
    match &p.k {
        PK::Name(n) => {
            if !own.contains(n) {
                out.insert(n.clone());
            }
        }
        PK::Variant(_, ps) | PK::Tuple(ps) => ps.iter().for_each(|p| collect_pat(p, own, out)),
        _ => {}
    }
}

fn collect_block(b: &Block, own: &HashSet<String>, out: &mut HashSet<String>) {
    for s in &b.stmts {
        collect_stmt(s, own, out);
    }
}

fn collect_stmt(s: &Stmt, own: &HashSet<String>, out: &mut HashSet<String>) {
    match &s.k {
        SK::Let { name, init, .. } => {
            out.insert(name.clone());
            collect_expr(init, own, out);
        }
        SK::LetPat { pat, init, .. } => {
            collect_pat(pat, own, out);
            collect_expr(init, own, out);
        }
        SK::Assign { target, value, .. } => {
            collect_expr(target, own, out);
            collect_expr(value, own, out);
        }
        SK::Expr(e) | SK::Assert(e, _) => collect_expr(e, own, out),
        SK::While(c, b) => {
            collect_expr(c, own, out);
            collect_block(b, own, out);
        }
        SK::For { var, lo, hi, body } => {
            out.insert(var.clone());
            collect_expr(lo, own, out);
            collect_expr(hi, own, out);
            collect_block(body, own, out);
        }
        SK::ForEach { var, iter, body } => {
            out.insert(var.clone());
            collect_expr(iter, own, out);
            collect_block(body, own, out);
        }
        SK::Return(Some(e)) => collect_expr(e, own, out),
        _ => {}
    }
}

fn collect_expr(e: &Expr, own: &HashSet<String>, out: &mut HashSet<String>) {
    match &e.k {
        EK::Unary(_, a) | EK::Try(a) | EK::Field(a, _) | EK::Cast(a, _) | EK::ArrayRepeat(a, _) => collect_expr(a, own, out),
        EK::Binary(_, a, b) | EK::Index(a, b) => {
            collect_expr(a, own, out);
            collect_expr(b, own, out);
        }
        EK::Call(_, args) => args.iter().for_each(|a| collect_expr(&a.e, own, out)),
        EK::MethodCall(r, _, args) => {
            collect_expr(r, own, out);
            args.iter().for_each(|a| collect_expr(&a.e, own, out));
        }
        EK::ArrayLit(es) | EK::Tuple(es) => es.iter().for_each(|e| collect_expr(e, own, out)),
        EK::Unsafe(b) | EK::Block(b) => collect_block(b, own, out),
        EK::Lambda(ps, _, body) => {
            for (n, _, _) in ps {
                out.insert(n.clone());
            }
            collect_expr(body, own, out);
        }
        EK::If(c, t, el) => {
            collect_expr(c, own, out);
            collect_block(t, own, out);
            if let Some(el) = el {
                collect_expr(el, own, out);
            }
        }
        EK::Match(s, arms, _) => {
            collect_expr(s, own, out);
            for a in arms {
                a.pats.iter().for_each(|p| collect_pat(p, own, out));
                match &a.body {
                    ArmBody::Expr(e) => collect_expr(e, own, out),
                    ArmBody::Stmt(s) => collect_stmt(s, own, out),
                }
            }
        }
        _ => {}
    }
}
