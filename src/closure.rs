//! Closures: `|x| expr` values of type `fn(T) -> U`.
//!
//! A closure captures a *snapshot* (copy / clone) of the variables it mentions, so it can never
//! outlive or alias the scope it was made in, and it can't mutate the caller's variables. The
//! captured values live in a heap environment owned by the closure value; cloning the closure
//! clones the environment, dropping it frees it.

use crate::ast::*;
use crate::check::*;
use crate::diag::{Diag, Pos};
use std::collections::HashMap;

fn walk_expr(e: &Expr, out: &mut Vec<String>) {
    match &e.k {
        EK::Ident(n) => out.push(n.clone()),
        EK::Int(_) | EK::Bool(_) | EK::Str(_) => {}
        EK::Unary(_, x) | EK::Cast(x, _) | EK::Field(x, _) | EK::ArrayRepeat(x, _) | EK::Try(x) => walk_expr(x, out),
        EK::Binary(_, a, b) | EK::Index(a, b) => {
            walk_expr(a, out);
            walk_expr(b, out);
        }
        EK::Call(n, args) => {
            out.push(n.clone());
            args.iter().for_each(|a| walk_expr(&a.e, out));
        }
        EK::MethodCall(r, _, args) => {
            walk_expr(r, out);
            args.iter().for_each(|a| walk_expr(&a.e, out));
        }
        EK::ArrayLit(es) | EK::Tuple(es) => es.iter().for_each(|x| walk_expr(x, out)),
        EK::Lambda(_, _, b) => walk_expr(b, out),
        EK::If(c, t, el) => {
            walk_expr(c, out);
            walk_block(t, out);
            if let Some(el) = el {
                walk_expr(el, out);
            }
        }
        EK::Match(s, arms, _) => {
            walk_expr(s, out);
            for a in arms {
                match &a.body {
                    ArmBody::Expr(x) => walk_expr(x, out),
                    ArmBody::Stmt(s) => walk_stmt(s, out),
                }
            }
        }
        EK::Block(b) | EK::Unsafe(b) => walk_block(b, out),
    }
}

fn walk_block(b: &Block, out: &mut Vec<String>) {
    b.stmts.iter().for_each(|s| walk_stmt(s, out));
}

fn walk_stmt(s: &Stmt, out: &mut Vec<String>) {
    match &s.k {
        SK::Let { init, .. } | SK::LetPat { init, .. } => walk_expr(init, out),
        SK::Assign { target, value, .. } => {
            walk_expr(target, out);
            walk_expr(value, out);
        }
        SK::Expr(e) => walk_expr(e, out),
        SK::While(c, b) => {
            walk_expr(c, out);
            walk_block(b, out);
        }
        SK::For { lo, hi, body, .. } => {
            walk_expr(lo, out);
            walk_expr(hi, out);
            walk_block(body, out);
        }
        SK::ForEach { iter, body, .. } => {
            walk_expr(iter, out);
            walk_block(body, out);
        }
        SK::Return(e) => {
            if let Some(e) = e {
                walk_expr(e, out);
            }
        }
        SK::Assert(e, _) => walk_expr(e, out),
        SK::Break | SK::Continue => {}
    }
}

impl<'a> Checker<'a> {
    pub fn is_value_form_expr(e: &Expr) -> bool {
        matches!(e.k, EK::If(..) | EK::Match(..) | EK::Block(..) | EK::Unsafe(..))
    }

    pub fn lambda(&mut self, e: &Expr, params: &[(String, Option<TyAst>, Pos)], ret: &Option<TyAst>, body: &Expr, exp: Option<&Ty>) -> R<V> {
        let hint: Option<(Vec<Option<Ty>>, Option<Ty>)> = match exp {
            Some(Ty::Fn(p, r)) => Some((p.iter().cloned().map(Some).collect(), Some((**r).clone()))),
            _ => self.lam_hint.clone(),
        };
        self.lam_hint = None;
        let (hp, hr) = hint.unwrap_or((vec![], None));
        if !hp.is_empty() && hp.len() != params.len() {
            return err("E0405", e.pos, format!("this closure takes {} parameter(s), but {} are expected here", params.len(), hp.len()));
        }
        let mut ptys: Vec<(String, Ty, Pos)> = vec![];
        for (i, (n, ta, pp)) in params.iter().enumerate() {
            let hinted = hp.get(i).cloned().flatten();
            let ty = match ta {
                Some(ta) => {
                    let t = self.resolve_ty(ta)?;
                    if let Some(h) = &hinted {
                        if *h != t {
                            return Err(mismatch(*pp, h, &t));
                        }
                    }
                    t
                }
                None => match hinted {
                    Some(h) => h,
                    None => {
                        return Err(Diag::new("E0409", *pp, format!("cannot infer the type of closure parameter `{}`", n)).help(format!("annotate it: `|{}: i32| ...`", n)));
                    }
                },
            };
            ptys.push((n.clone(), ty, *pp));
        }
        let ret_hint = match ret {
            Some(r) => Some(self.resolve_ty(r)?),
            None => hr,
        };

        // captured variables
        let mut names = vec![];
        walk_expr(body, &mut names);
        let mut caps: Vec<(String, Var)> = vec![];
        for n in names {
            if params.iter().any(|(p, _, _)| *p == n) || caps.iter().any(|(c, _)| *c == n) {
                continue;
            }
            if let Some(v) = self.lookup(&n) {
                caps.push((n.clone(), v.clone()));
            }
        }

        self.closure_n += 1;
        let id = self.closure_n;
        let saved = (
            std::mem::take(&mut self.out),
            self.ind,
            std::mem::take(&mut self.scopes),
            std::mem::take(&mut self.frames),
            self.ret.clone(),
            self.loops,
            std::mem::take(&mut self.loop_bases),
        );
        let res = self.lambda_body(&ptys, &caps, body, ret_hint);
        let body_lines = std::mem::replace(&mut self.out, saved.0);
        self.ind = saved.1;
        self.scopes = saved.2;
        self.frames = saved.3;
        self.ret = saved.4;
        self.loops = saved.5;
        self.loop_bases = saved.6;
        let rty = res?;

        let fty = Ty::Fn(ptys.iter().map(|p| p.1.clone()).collect(), Box::new(rty.clone()));
        self.note_ty(&fty);
        let fct = self.ctype(&fty);

        // environment type + helpers
        let env = format!("Env_{}", id);
        let mut cparams = vec!["void* env_".to_string()];
        cparams.extend(ptys.iter().map(|(n, t, _)| format!("{} v_{}", self.ctype(t), n)));
        let fname = format!("clo_{}", id);
        self.protos.push(format!("static {} {}({});", self.ctype(&rty), fname, cparams.join(", ")));
        let mut text = format!("static {} {}({}) {{\n", self.ctype(&rty), fname, cparams.join(", "));
        if caps.is_empty() {
            text.push_str("  (void)env_;\n");
        } else {
            text.push_str(&format!("  {env}* env = ({env}*)env_; (void)env;\n", env = env));
        }
        for l in &body_lines {
            text.push_str(l);
            text.push('\n');
        }
        if rty != Ty::Unit {
            text.push_str("  ei_unreachable();\n");
        }
        text.push_str("}\n");
        self.lifted.push(text);

        let (envc, dropc, clonec) = if caps.is_empty() {
            ("NULL".to_string(), "NULL".to_string(), "NULL".to_string())
        } else {
            let fields: Vec<String> = caps.iter().map(|(n, v)| format!("{} c_{};", self.ctype(&v.ty), n)).collect();
            self.lifted_types.push_str(&format!("typedef struct {{ {} }} {};\n", fields.join(" "), env));
            let mut drops = String::new();
            let mut clones = String::new();
            for (n, v) in &caps {
                if self.owns(&v.ty) {
                    self.need_glue(&v.ty);
                    let m = mangle(&v.ty.to_string());
                    drops.push_str(&format!("ei_drop_{}(&e->c_{}); ", m, n));
                    clones.push_str(&format!("n->c_{n} = ei_clone_{m}(&e->c_{n}); ", n = n, m = m));
                }
            }
            self.protos.push(format!("static void ei_envdrop_{}(void* p);\nstatic void* ei_envclone_{}(void* p);", id, id));
            self.lifted.push(format!(
                "static void ei_envdrop_{id}(void* p) {{ {env}* e = ({env}*)p; {drops}free(e); }}\nstatic void* ei_envclone_{id}(void* p) {{ {env}* e = ({env}*)p; {env}* n = ({env}*)ei_alloc(sizeof({env})); *n = *e; {clones}return n; }}\n",
                id = id,
                env = env,
                drops = drops,
                clones = clones
            ));
            let t = self.tmp();
            self.emit(format!("{env}* {t} = ({env}*)ei_alloc(sizeof({env}));", env = env, t = t));
            for (n, v) in &caps {
                let src = if v.inout { format!("(*{})", v.cname) } else { v.cname.clone() };
                let val = if self.owns(&v.ty) {
                    self.need_glue(&v.ty);
                    format!("ei_clone_{}(&{})", mangle(&v.ty.to_string()), src)
                } else {
                    src
                };
                self.emit(format!("{}->c_{} = {};", t, n, val));
            }
            (t, format!("ei_envdrop_{}", id), format!("ei_envclone_{}", id))
        };
        let c = format!("(({}){{ {}, {}, {}, {} }})", fct, envc, fname, dropc, clonec);
        Ok(V { ty: fty, c, k: None, pure: false })
    }

    fn lambda_body(&mut self, ptys: &[(String, Ty, Pos)], caps: &[(String, Var)], body: &Expr, ret_hint: Option<Ty>) -> R<Ty> {
        self.out = vec![];
        self.ind = 1;
        self.scopes = vec![HashMap::new()];
        self.frames = vec![vec![]];
        self.loops = 0;
        self.loop_bases.clear();
        for (n, v) in caps {
            let ty = v.ty.clone();
            self.declare(n, body.pos, Var { ty, mutable: false, inout: false, cname: format!("env->c_{}", n), decl: None })?;
        }
        for (n, t, pp) in ptys {
            self.declare(n, *pp, Var { ty: t.clone(), mutable: false, inout: false, cname: format!("v_{}", n), decl: None })?;
        }
        if Self::is_value_form_expr(body) {
            let ret = match ret_hint {
                Some(r) => r,
                None => return Err(Diag::new("E0409", body.pos, "cannot infer the closure's return type").help("write it: `|x| -> i32 { ... }`")),
            };
            self.ret = ret.clone();
            let dest = if ret == Ty::Unit { Dest::Discard } else { Dest::Return };
            let t = self.compile_value(body, &dest, Some(&ret))?;
            if ret != Ty::Unit && t != Ty::Never && t != ret {
                return Err(mismatch(body.pos, &ret, &t));
            }
            return Ok(ret);
        }
        let v = self.expr(body, ret_hint.as_ref())?;
        if let Some(h) = &ret_hint {
            if v.ty != *h && v.ty != Ty::Never {
                return Err(mismatch(body.pos, h, &v.ty));
            }
        }
        let ret = match (&ret_hint, &v.ty) {
            (Some(h), _) => h.clone(),
            (None, Ty::Never) => Ty::Unit,
            (None, t) => t.clone(),
        };
        self.ret = ret.clone();
        if v.ty == Ty::Never {
            self.emit(format!("{};", v.c));
        } else if ret == Ty::Unit {
            self.emit(format!("{};", v.c));
            self.drop_frames_from(0);
        } else {
            let c = self.take(&v);
            if self.has_pending_drops() {
                let r = self.tmp();
                self.emit(format!("{} {} = {};", self.ctype(&ret), r, c));
                self.drop_frames_from(0);
                self.emit(format!("return {};", r));
            } else {
                self.emit(format!("return {};", c));
            }
        }
        Ok(ret)
    }

    /// Call a closure value held in a variable or field.
    pub fn call_value(&mut self, pos: Pos, label: &str, mut f: V, args: &[Arg]) -> R<V> {
        let (ps, r) = match &f.ty {
            Ty::Fn(ps, r) => (ps.clone(), (**r).clone()),
            t => return err("E0112", pos, format!("`{}` has type {}, so it can't be called", label, t)),
        };
        if args.len() != ps.len() {
            return err("E0405", pos, format!("`{}` takes {} argument(s), but {} were given", label, ps.len(), args.len()));
        }
        let mut vs: Vec<V> = vec![];
        for (a, t) in args.iter().zip(ps.iter()) {
            if a.inout {
                return err("E0304", a.e.pos, "closures can't take `inout` arguments");
            }
            let mark = self.out.len();
            let v = self.expr(&a.e, Some(t))?;
            if v.ty != *t {
                return Err(mismatch(a.e.pos, t, &v.ty));
            }
            let mut prev: Vec<&mut V> = vs.iter_mut().collect();
            prev.push(&mut f);
            self.fix_order(prev, mark);
            vs.push(v);
        }
        {
            let mut all: Vec<&mut V> = vs.iter_mut().collect();
            all.push(&mut f);
            self.hoist(all);
        }
        let mut cargs = vec![format!("{}.env", wrap(&f.c))];
        cargs.extend(vs.iter().map(|v| v.c.clone()));
        Ok(V { ty: r, c: format!("{}.call({})", wrap(&f.c), cargs.join(", ")), k: None, pure: false })
    }

    /// A named top-level function used as a value.
    pub fn fn_as_value(&mut self, pos: Pos, name: &str, exp: &Ty) -> R<V> {
        let (eps, er) = match exp {
            Ty::Fn(p, r) => (p.clone(), (**r).clone()),
            _ => unreachable!(),
        };
        let decl = self.fns[name].clone();
        if !decl.generics.is_empty() {
            return err("E0409", pos, format!("generic function `{}` can't be used as a value; wrap it in a closure", name));
        }
        let cname = format!("f_{}", name);
        let sig = self.instantiate(&decl, &std::collections::HashMap::new(), &cname)?;
        if sig.params.iter().any(|p| p.1) {
            return err("E0304", pos, format!("`{}` has `inout` parameters and can't be used as a value", name));
        }
        let ptys: Vec<Ty> = sig.params.iter().map(|p| p.2.clone()).collect();
        let actual = Ty::Fn(ptys.clone(), Box::new(sig.ret.clone()));
        if ptys != eps || sig.ret != er {
            return Err(mismatch(pos, exp, &actual));
        }
        if !sig.caps.iter().all(|c| self.caps.contains(c)) {
            let miss = sig.caps.iter().find(|c| !self.caps.contains(c)).unwrap().clone();
            return Err(self.cap_error(pos, name, &miss));
        }
        self.note_ty(&actual);
        let thunk = format!("thk_{}", name);
        if self.thunks.insert(thunk.clone()) {
            let mut cparams = vec!["void* env_".to_string()];
            cparams.extend(ptys.iter().enumerate().map(|(i, t)| format!("{} a{}", self.ctype(t), i)));
            let call_args: Vec<String> = (0..ptys.len()).map(|i| format!("a{}", i)).collect();
            self.protos.push(format!("static {} {}({});", self.ctype(&sig.ret), thunk, cparams.join(", ")));
            let body = if sig.ret == Ty::Unit { format!("{}({});", cname, call_args.join(", ")) } else { format!("return {}({});", cname, call_args.join(", ")) };
            self.lifted.push(format!("static {} {}({}) {{ (void)env_; {} }}\n", self.ctype(&sig.ret), thunk, cparams.join(", "), body));
        }
        Ok(V { c: format!("(({}){{ NULL, {}, NULL, NULL }})", self.ctype(&actual), thunk), ty: actual, k: None, pure: true })
    }
}
