//! Expressions, calls (generic, method, constructor) and builtins.

use crate::ast::*;
use crate::check::*;
use crate::diag::{Diag, Pos};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

impl<'a> Checker<'a> {
    // ------------------------------------------------------------ evaluation order
    /// A later operand emitted statements at `mark`; earlier operands must be evaluated
    /// before those statements, so hoist them into temporaries inserted at `mark`.
    pub fn fix_order(&mut self, prev: Vec<&mut V>, mark: usize) {
        if self.out.len() == mark {
            return;
        }
        let mut at = mark;
        for v in prev {
            if v.k.is_none() && !is_tmp(&v.c) {
                let t = self.tmp();
                let line = format!("{}{} {} = {};", "  ".repeat(self.ind), self.ctype(&v.ty), t, v.c);
                self.out.insert(at, line);
                at += 1;
                v.c = t;
                v.pure = true;
            }
        }
    }

    pub fn hoist(&mut self, mut vs: Vec<&mut V>) {
        if vs.len() >= 2 && vs.iter().any(|v| !v.pure) {
            for v in vs.iter_mut() {
                if v.k.is_none() && !is_tmp(&v.c) {
                    let t = self.tmp();
                    self.emit(format!("{} {} = {};", self.ctype(&v.ty), t, v.c));
                    v.c = t;
                    v.pure = true;
                }
            }
        }
    }

    pub fn arith_c(op: BinOp, it: IntTy, a: &str, b: &str, line: u32) -> String {
        let h = it.h();
        let name = match op {
            BinOp::Add => "add",
            BinOp::Sub => "sub",
            BinOp::Mul => "mul",
            BinOp::Div => "div",
            BinOp::Rem => "rem",
            BinOp::WAdd => "wadd",
            BinOp::WSub => "wsub",
            BinOp::WMul => "wmul",
            _ => unreachable!(),
        };
        if matches!(op, BinOp::WAdd | BinOp::WSub | BinOp::WMul) {
            format!("({})ei_{}_{}({}, {})", it.c(), name, h, a, b)
        } else {
            format!("({})ei_{}_{}({}, {}, {})", it.c(), name, h, a, b, line)
        }
    }

    fn int_v(&self, t: IntTy, v: i128) -> V {
        V { ty: Ty::Int(t), c: lit_c(t, v), k: Some(v), pure: true }
    }

    fn is_type_name(&self, n: &str) -> bool {
        self.templates.contains_key(n) || IntTy::from_name(n).is_some() || ["bool", "str", "String", "List", "Map", "Box", "Task", "Mutex", "Chan"].contains(&n)
    }

    /// Is this expression a place (variable, field, index) rather than a fresh value?
    pub fn is_place(&self, e: &Expr) -> bool {
        match &e.k {
            EK::Ident(n) => self.lookup(n).is_some(),
            EK::Field(b, _) => match &b.k {
                EK::Ident(tn) if self.lookup(tn).is_none() && !self.consts.contains_key(tn) && self.templates.contains_key(tn) => false,
                _ => true,
            },
            EK::Index(..) => true,
            _ => false,
        }
    }

    // ------------------------------------------------------------ expressions
    /// Like `expr_raw`, but owned rvalues are hoisted into registered temporaries so they are
    /// dropped exactly once (or moved into new storage by `take`).
    pub fn expr(&mut self, e: &Expr, exp: Option<&Ty>) -> R<V> {
        let v = self.expr_raw(e, exp)?;
        if !self.owns(&v.ty) || self.is_place(e) || self.fresh.contains(&v.c) {
            return Ok(v);
        }
        Ok(self.mk_fresh(v))
    }

    fn expr_raw(&mut self, e: &Expr, exp: Option<&Ty>) -> R<V> {
        match &e.k {
            EK::Int(v) => {
                let t = match exp {
                    Some(Ty::Int(t)) => *t,
                    _ => IntTy::I32,
                };
                if *v > t.max() {
                    return err("E0501", e.pos, format!("literal {} doesn't fit in {} (max {})", v, t.name(), t.max()));
                }
                Ok(self.int_v(t, *v))
            }
            EK::Bool(b) => Ok(V { ty: Ty::Bool, c: b.to_string(), k: None, pure: true }),
            EK::Str(s) => Ok(V { ty: Ty::Str, c: cstr(s), k: None, pure: true }),
            EK::Ident(n) => {
                if let Some(v) = self.lookup(n) {
                    let c = if v.inout { format!("(*{})", v.cname) } else { v.cname.clone() };
                    return Ok(V { ty: v.ty.clone(), c, k: None, pure: true });
                }
                if let Some((t, k)) = self.consts.get(n) {
                    if let Some((m, public)) = self.const_vis.get(n) {
                        if !self.visible(m, *public) {
                            return err("E0801", e.pos, format!("constant `{}` is private to module `{}`", n, m));
                        }
                    }
                    return Ok(V { ty: t.clone(), c: format!("c_{}", n), k: *k, pure: true });
                }
                if let Some(tn) = self.variants_by_name.get(n).cloned() {
                    return self.construct(e.pos, &tn, Some(n), &[], exp);
                }
                if self.fns.contains_key(n) {
                    if let Some(t @ Ty::Fn(..)) = exp {
                        let t = t.clone();
                        return self.fn_as_value(e.pos, n, &t);
                    }
                    return err("E0110", e.pos, format!("`{}` is a function; call it with `{}(...)`", n, n));
                }
                err("E0110", e.pos, format!("unknown name `{}`", n))
            }
            EK::Field(b, f) => {
                if let EK::Ident(tn) = &b.k {
                    if self.lookup(tn).is_none() && !self.consts.contains_key(tn) {
                        if let Some(d) = self.templates.get(tn).cloned() {
                            if let TypeKind::Enum(vs) = &d.kind {
                                return if vs.iter().any(|v| &v.name == f) {
                                    self.construct(e.pos, tn, Some(f), &[], exp)
                                } else {
                                    err("E0114", e.pos, format!("enum `{}` has no variant `{}`", tn, f))
                                };
                            }
                        }
                    }
                }
                let v = self.expr(b, None)?;
                match &v.ty {
                    Ty::Record(r) => match self.rec_defs[r].fields.iter().find(|(n, _)| n == f) {
                        Some((_, ft)) => Ok(V { ty: ft.clone(), c: format!("{}.f_{}", wrap(&v.c), f), k: None, pure: v.pure }),
                        None => err("E0113", e.pos, format!("type `{}` has no field `{}`", r, f)),
                    },
                    Ty::Tuple(ts) => match f.parse::<usize>() {
                        Ok(i) if i < ts.len() => Ok(V { ty: ts[i].clone(), c: format!("{}.f_{}", wrap(&v.c), i), k: None, pure: v.pure }),
                        _ => err("E0113", e.pos, format!("tuple {} has no element `{}`", v.ty, f)),
                    },
                    t => err("E0113", e.pos, format!("type {} has no fields", t)),
                }
            }
            EK::Index(b, i) => {
                let mut vb = self.expr(b, None)?;
                if let Ty::List(el) = &vb.ty {
                    let el = (**el).clone();
                    let mark = self.out.len();
                    let vi = self.expr(i, Some(&Ty::Int(IntTy::Usize)))?;
                    self.fix_order(vec![&mut vb], mark);
                    if vi.ty != Ty::Int(IntTy::Usize) {
                        return Err(mismatch(i.pos, &Ty::Int(IntTy::Usize), &vi.ty));
                    }
                    if !vb.pure || !vi.pure {
                        let t = self.tmp();
                        self.emit(format!("{}* {} = &{};", self.ctype(&vb.ty), t, wrap(&vb.c)));
                        vb.c = format!("(*{})", t);
                    }
                    let ic = if vi.pure { vi.c.clone() } else {
                        let t = self.tmp();
                        self.emit(format!("uint64_t {} = {};", t, vi.c));
                        t
                    };
                    return Ok(V { ty: el, c: format!("{}.d[ei_idx({}, {}.len, {})]", wrap(&vb.c), ic, wrap(&vb.c), e.pos.line), k: None, pure: false });
                }
                let (et, n) = match &vb.ty {
                    Ty::Array(et, n) => ((**et).clone(), *n),
                    t => return err("E0401", e.pos, format!("cannot index a value of type {}", t)),
                };
                let mark = self.out.len();
                let mut vi = self.expr(i, Some(&Ty::Int(IntTy::Usize)))?;
                self.fix_order(vec![&mut vb], mark);
                if vi.ty != Ty::Int(IntTy::Usize) {
                    return Err(mismatch(i.pos, &Ty::Int(IntTy::Usize), &vi.ty));
                }
                if let Some(k) = vi.k {
                    if k >= n as i128 {
                        return err("E0503", i.pos, format!("index {} is out of bounds for an array of length {}", k, n));
                    }
                }
                if !vi.pure {
                    if !vb.pure {
                        let t = self.tmp();
                        self.emit(format!("{} {} = {};", self.ctype(&vb.ty), t, vb.c));
                        vb.c = t;
                        vb.pure = true;
                    }
                    let t = self.tmp();
                    self.emit(format!("uint64_t {} = {};", t, vi.c));
                    vi.c = t;
                    vi.pure = true;
                }
                Ok(V { ty: et, c: format!("{}.d[ei_idx({}, {}, {})]", wrap(&vb.c), vi.c, n, e.pos.line), k: None, pure: vb.pure && vi.pure })
            }
            EK::Unary(UnOp::Neg, x) => {
                if let EK::Int(v) = &x.k {
                    let t = match exp {
                        Some(Ty::Int(t)) => *t,
                        _ => IntTy::I32,
                    };
                    if !t.signed() {
                        return err("E0401", e.pos, format!("cannot negate an unsigned integer ({})", t.name()));
                    }
                    if -*v < t.min() {
                        return err("E0501", e.pos, format!("literal -{} doesn't fit in {}", v, t.name()));
                    }
                    return Ok(self.int_v(t, -*v));
                }
                let v = self.expr(x, exp)?;
                let it = match &v.ty {
                    Ty::Int(i) if i.signed() => *i,
                    t => return err("E0401", e.pos, format!("cannot negate a value of type {}", t)),
                };
                if let Some(k) = v.k {
                    if -k > it.max() {
                        return err("E0501", e.pos, format!("negating {} overflows {}", k, it.name()));
                    }
                    return Ok(self.int_v(it, -k));
                }
                Ok(V { ty: v.ty, c: format!("ei_neg_{}({}, {})", it.h(), v.c, e.pos.line), k: None, pure: v.pure })
            }
            EK::Unary(UnOp::Not, x) => {
                let v = self.expr(x, Some(&Ty::Bool))?;
                if v.ty != Ty::Bool {
                    return Err(mismatch(x.pos, &Ty::Bool, &v.ty));
                }
                Ok(V { ty: Ty::Bool, c: format!("(!{})", wrap(&v.c)), k: None, pure: v.pure })
            }
            EK::Binary(op, l, r) => self.binary(e, *op, l, r, exp),
            EK::Call(name, args) => self.call(e, name, args, exp),
            EK::MethodCall(recv, name, args) => self.method_call(e, recv, name, args, exp),
            EK::Cast(x, ta) => {
                let target = self.resolve_ty(ta)?;
                let tt = match &target {
                    Ty::Int(t) => *t,
                    t => return err("E0401", e.pos, format!("`as` only converts between integer types, not to {}", t)),
                };
                let v = self.expr(x, if is_lit(x) { Some(&target) } else { None })?;
                let st = match &v.ty {
                    Ty::Int(s) => *s,
                    t => return err("E0401", e.pos, format!("`as` only converts between integer types, not from {}", t)),
                };
                if let Some(k) = v.k {
                    if k < tt.min() || k > tt.max() {
                        return err("E0501", e.pos, format!("{} doesn't fit in {}", k, tt.name()));
                    }
                    return Ok(self.int_v(tt, k));
                }
                if st == tt {
                    return Ok(V { ty: target, ..v });
                }
                let line = e.pos.line;
                let c = match (st.signed(), tt.signed()) {
                    (true, true) => format!("({})ei_s2s((int64_t)({}), {}, {}, {})", tt.c(), v.c, tt.cmin(), tt.cmax(), line),
                    (true, false) => format!("({})ei_s2u((int64_t)({}), {}, {})", tt.c(), v.c, tt.cmax(), line),
                    (false, true) => format!("({})ei_u2s((uint64_t)({}), {}, {})", tt.c(), v.c, tt.cmax(), line),
                    (false, false) => format!("({})ei_u2u((uint64_t)({}), {}, {})", tt.c(), v.c, tt.cmax(), line),
                };
                Ok(V { ty: target, c, k: None, pure: v.pure })
            }
            EK::ArrayLit(es) => {
                let exp_elem = match exp {
                    Some(Ty::Array(t, _)) => Some((**t).clone()),
                    _ => None,
                };
                if es.is_empty() {
                    return err("E0401", e.pos, "cannot infer the element type of an empty array");
                }
                let mut vs: Vec<V> = vec![];
                for x in es {
                    let want = exp_elem.clone().or_else(|| vs.first().map(|f| f.ty.clone()));
                    let mark = self.out.len();
                    let v = self.expr(x, want.as_ref())?;
                    if let Some(w) = &want {
                        if v.ty != *w {
                            return Err(mismatch(x.pos, w, &v.ty));
                        }
                    }
                    self.fix_order(vs.iter_mut().collect(), mark);
                    vs.push(v);
                }
                let ty = Ty::Array(Box::new(vs[0].ty.clone()), es.len() as u64);
                self.note_ty(&ty);
                let pure = vs.iter().all(|v| v.pure);
                self.hoist(vs.iter_mut().collect());
                let cs: Vec<String> = vs.iter().map(|v| self.take(v)).collect();
                Ok(V { c: format!("({}){{{{{}}}}}", self.ctype(&ty), cs.join(", ")), ty, k: None, pure })
            }
            EK::ArrayRepeat(x, n) => {
                let exp_elem = match exp {
                    Some(Ty::Array(t, _)) => Some((**t).clone()),
                    _ => None,
                };
                let v = self.expr(x, exp_elem.as_ref())?;
                if let Some(w) = &exp_elem {
                    if v.ty != *w {
                        return Err(mismatch(x.pos, w, &v.ty));
                    }
                }
                if self.owns(&v.ty) {
                    return err("E0401", x.pos, format!("`[x; n]` can't repeat a {} (it owns heap memory); build the array element by element", v.ty));
                }
                let ty = Ty::Array(Box::new(v.ty.clone()), *n);
                self.note_ty(&ty);
                Ok(V { c: format!("{}_fill({})", self.ctype(&ty), v.c), ty, k: None, pure: v.pure })
            }
            EK::Tuple(es) => {
                let hints: Vec<Option<Ty>> = match exp {
                    Some(Ty::Tuple(ts)) if ts.len() == es.len() => ts.iter().cloned().map(Some).collect(),
                    _ => vec![None; es.len()],
                };
                let mut vs: Vec<V> = vec![];
                for (x, h) in es.iter().zip(hints.iter()) {
                    let mark = self.out.len();
                    let v = self.expr(x, h.as_ref())?;
                    if matches!(v.ty, Ty::Unit | Ty::Never) {
                        return err("E0401", x.pos, "tuple elements can't be ()");
                    }
                    self.fix_order(vs.iter_mut().collect(), mark);
                    vs.push(v);
                }
                let ty = Ty::Tuple(vs.iter().map(|v| v.ty.clone()).collect());
                self.note_ty(&ty);
                let pure = vs.iter().all(|v| v.pure);
                self.hoist(vs.iter_mut().collect());
                let cs: Vec<String> = vs.iter().map(|v| self.take(v)).collect();
                Ok(V { c: format!("({}){{{}}}", self.ctype(&ty), cs.join(", ")), ty, k: None, pure })
            }
            EK::Try(x) => self.try_op(e, x),
            EK::Lambda(params, ret, body) => self.lambda(e, params, ret, body, exp),
            EK::If(..) | EK::Match(..) | EK::Block(..) | EK::Unsafe(..) => Err(Diag::new(
                "E0103",
                e.pos,
                "`if`, `match` and blocks can only be used as a statement, a function's final expression, or the right side of `let`, `=` or `return`",
            )
            .help("bind the result first: `let x = match ... { ... }`, then use `x`")),
        }
    }

    fn try_op(&mut self, e: &Expr, x: &Expr) -> R<V> {
        let v = self.expr(x, None)?;
        let (k, def) = match &v.ty {
            Ty::Enum(k) => (k.clone(), self.enum_defs[k].clone()),
            t => return err("E0406", e.pos, format!("`?` needs a Result or Option, found {}", t)),
        };
        if def.template != "Result" && def.template != "Option" {
            return err("E0406", e.pos, format!("`?` needs a Result or Option, found {}", v.ty));
        }
        let rk = match &self.ret {
            Ty::Enum(rk) if self.enum_defs[rk].template == def.template => rk.clone(),
            other => {
                return err("E0406", e.pos, format!("`?` on a {} needs the enclosing function to return a {}, but it returns {}", def.template, def.template, other))
            }
        };
        let t = if self.owns(&v.ty) {
            self.take(&v)
        } else {
            let t = self.tmp();
            self.emit(format!("{} {} = {};", self.ctype(&v.ty), t, v.c));
            t
        };
        let ret_c = self.ctype(&self.ret.clone());
        let (variant, payload, rvariant) = if def.template == "Result" {
            let (ea, eb) = (def.args[1].clone(), self.enum_defs[&rk].args[1].clone());
            if ea != eb {
                return err("E0401", e.pos, format!("`?` can't convert the error type {} into {}", ea, eb));
            }
            ("Err", format!(", .u.m_Err = {{ {}.u.m_Err.f_error }}", t), "Err")
        } else {
            ("None", String::new(), "None")
        };
        let rt = self.tmp();
        self.emit(format!("if ({}.tag == {}) {{", t, self.tag_const(&k, variant)));
        self.ind += 1;
        self.emit(format!("{ret} {rt} = ({ret}){{ .tag = {tag}{payload} }};", ret = ret_c, rt = rt, tag = self.tag_const(&rk, rvariant), payload = payload));
        self.drop_frames_from(0);
        self.emit(format!("return {};", rt));
        self.ind -= 1;
        self.emit("}");
        let (field, vname) = if def.template == "Result" { ("f_value", "Ok") } else { ("f_value", "Some") };
        Ok(V { ty: def.args[0].clone(), c: format!("{}.u.m_{}.{}", t, vname, field), k: None, pure: true })
    }

    fn binary(&mut self, e: &Expr, op: BinOp, l: &Expr, r: &Expr, exp: Option<&Ty>) -> R<V> {
        if matches!(op, BinOp::And | BinOp::Or) {
            let vl = self.expr(l, Some(&Ty::Bool))?;
            if vl.ty != Ty::Bool {
                return Err(mismatch(l.pos, &Ty::Bool, &vl.ty));
            }
            let mark = self.out.len();
            self.push_frame();
            let vr = match self.expr(r, Some(&Ty::Bool)) {
                Ok(v) => v,
                Err(d) => {
                    self.pop_frame(false);
                    return Err(d);
                }
            };
            if vr.ty != Ty::Bool {
                self.pop_frame(false);
                return Err(mismatch(r.pos, &Ty::Bool, &vr.ty));
            }
            if self.out.len() > mark {
                // rhs needs statements: they must only run if the lhs doesn't short-circuit
                let lines = self.out.split_off(mark);
                let t = self.tmp();
                self.emit(format!("bool {} = {};", t, vl.c));
                self.emit(if op == BinOp::And { format!("if ({}) {{", t) } else { format!("if (!{}) {{", t) });
                self.out.extend(lines);
                self.ind += 1;
                self.emit(format!("{} = {};", t, vr.c));
                self.pop_frame(true);
                self.ind -= 1;
                self.emit("}");
                return Ok(V { ty: Ty::Bool, c: t, k: None, pure: true });
            }
            self.pop_frame(false);
            return Ok(V { ty: Ty::Bool, c: format!("({} {} {})", vl.c, op.sym(), vr.c), k: None, pure: vl.pure && vr.pure });
        }
        let arith = matches!(op, BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem | BinOp::WAdd | BinOp::WSub | BinOp::WMul);
        let exp_operand = if arith { exp } else { None };
        let (mut vl, mut vr);
        if is_lit(l) && !is_lit(r) {
            vr = self.expr(r, exp_operand)?;
            vl = self.expr(l, Some(&vr.ty))?;
        } else {
            vl = self.expr(l, exp_operand)?;
            let mark = self.out.len();
            vr = self.expr(r, Some(&vl.ty))?;
            self.fix_order(vec![&mut vl], mark);
        }
        if vl.ty != vr.ty {
            return Err(mismatch(r.pos, &vl.ty, &vr.ty));
        }
        let ty = vl.ty.clone();
        if arith {
            let it = match &ty {
                Ty::Int(i) => *i,
                t => return err("E0401", e.pos, format!("operator {} needs integers, found {}", op.sym(), t)),
            };
            if matches!(op, BinOp::Div | BinOp::Rem) && vr.k == Some(0) {
                return err("E0502", r.pos, "division by zero");
            }
            if let (Some(a), Some(b)) = (vl.k, vr.k) {
                let (wide, wraps) = match op {
                    BinOp::Add => (a + b, false),
                    BinOp::Sub => (a - b, false),
                    BinOp::Mul => (a * b, false),
                    BinOp::Div => (a / b, false),
                    BinOp::Rem => (a % b, false),
                    BinOp::WAdd => (a + b, true),
                    BinOp::WSub => (a - b, true),
                    _ => (a * b, true),
                };
                let range = it.max() - it.min() + 1;
                if wraps {
                    let v = (wide - it.min()).rem_euclid(range) + it.min();
                    return Ok(self.int_v(it, v));
                }
                if wide < it.min() || wide > it.max() {
                    return err("E0501", e.pos, format!("{} {} {} = {} doesn't fit in {}", a, op.sym(), b, wide, it.name()))
                        .map_err(|d: Diag| d.help(format!("use the wrapping operator `{}` if overflow is intended", match op { BinOp::Add => "+%", BinOp::Sub => "-%", _ => "*%" })));
                }
                return Ok(self.int_v(it, wide));
            }
            let pure = vl.pure && vr.pure;
            self.hoist(vec![&mut vl, &mut vr]);
            let c = Self::arith_c(op, it, &vl.c, &vr.c, e.pos.line);
            return Ok(V { ty, c, k: None, pure: pure || (vl.pure && vr.pure) });
        }
        // comparisons
        if matches!(op, BinOp::Eq | BinOp::Ne) && !self.eq_supported(&ty) {
            return err("E0401", e.pos, format!("`==` is not supported for {} (Maps have no structural equality)", ty));
        }
        match (&ty, op) {
            (Ty::Int(_), _) => {}
            (Ty::Unit | Ty::Never, _) => return err("E0401", e.pos, format!("cannot compare values of type {}", ty)),
            (_, BinOp::Eq | BinOp::Ne) => {}
            (t, _) => return err("E0401", e.pos, format!("operator {} is not supported for {}", op.sym(), t)),
        }
        let pure = vl.pure && vr.pure;
        self.hoist(vec![&mut vl, &mut vr]);
        let c = match (&ty, op) {
            (Ty::Int(_), _) => format!("({} {} {})", vl.c, op.sym(), vr.c),
            (_, BinOp::Eq) => self.eq_expr(&ty, &vl.c, &vr.c),
            _ => format!("(!{})", self.eq_expr(&ty, &vl.c, &vr.c)),
        };
        Ok(V { ty: Ty::Bool, c, k: None, pure: pure || (vl.pure && vr.pure) })
    }

    // ------------------------------------------------------------ constructors
    /// Enum variant or record construction, inferring generic arguments from the
    /// expected type and the argument types.
    fn construct(&mut self, pos: Pos, tmpl: &str, variant: Option<&str>, args: &[Arg], exp: Option<&Ty>) -> R<V> {
        let decl = self.templates[tmpl].clone();
        let field_asts: Vec<TyAst> = match (&decl.kind, variant) {
            (TypeKind::Enum(vs), Some(v)) => vs.iter().find(|x| x.name == v).unwrap().fields.iter().map(|f| f.1.clone()).collect(),
            (TypeKind::Record(fs), None) => fs.iter().map(|f| f.1.clone()).collect(),
            _ => return err("E0112", pos, format!("`{}` can't be called", tmpl)),
        };
        let label = variant.unwrap_or(tmpl);
        if args.len() != field_asts.len() {
            return err("E0405", pos, format!("`{}` takes {} value(s), but {} were given", label, field_asts.len(), args.len()));
        }
        let gs: HashSet<String> = decl.generics.iter().cloned().collect();
        let mut subst: HashMap<String, Ty> = HashMap::new();
        if let Some(Ty::Enum(k)) | Some(Ty::Record(k)) = exp {
            let (t, a) = match self.enum_defs.get(k) {
                Some(d) => (d.template.clone(), d.args.clone()),
                None => {
                    let d = &self.rec_defs[k];
                    (d.template.clone(), d.args.clone())
                }
            };
            if t == tmpl {
                for (g, ty) in decl.generics.iter().zip(a.into_iter()) {
                    subst.insert(g.clone(), ty);
                }
            }
        }
        let mut vs: Vec<V> = vec![];
        for (a, fa) in args.iter().zip(field_asts.iter()) {
            if a.inout {
                return err("E0304", a.e.pos, "`inout` is not allowed here");
            }
            let hint = if self.ast_has_unbound(fa, &subst, &gs) { None } else { Some(self.resolve_with(fa, &subst)?) };
            let mark = self.out.len();
            let v = self.expr(&a.e, hint.as_ref())?;
            match &hint {
                Some(h) => {
                    if v.ty != *h {
                        return Err(mismatch(a.e.pos, h, &v.ty));
                    }
                }
                None => {
                    if !self.unify_ast(fa, &v.ty, &mut subst, &gs) {
                        return err("E0401", a.e.pos, format!("this value has type {}, which doesn't fit field type `{}`", v.ty, show_ast(fa)));
                    }
                }
            }
            self.fix_order(vs.iter_mut().collect(), mark);
            vs.push(v);
        }
        let mut targs = vec![];
        for g in &decl.generics {
            match subst.get(g) {
                Some(t) => targs.push(t.clone()),
                None => {
                    return Err(Diag::new("E0409", pos, format!("cannot infer type parameter `{}` of `{}`", g, tmpl))
                        .help("add a type annotation, e.g. `let x: Option[i32] = None`"))
                }
            }
        }
        let ty = self.inst_type(tmpl, targs, pos)?;
        let pure = vs.iter().all(|v| v.pure);
        self.hoist(vs.iter_mut().collect());
        let cs: Vec<String> = vs.iter().map(|v| self.take(v)).collect();
        let c = match (&ty, variant) {
            (Ty::Enum(k), Some(v)) => {
                if self.is_unit_enum(k) {
                    self.tag_const(k, v)
                } else if cs.is_empty() {
                    format!("(({}){{ .tag = {} }})", self.ctype(&ty), self.tag_const(k, v))
                } else {
                    format!("(({}){{ .tag = {}, .u.m_{} = {{ {} }} }})", self.ctype(&ty), self.tag_const(k, v), v, cs.join(", "))
                }
            }
            _ => format!("({}){{ {} }}", self.ctype(&ty), cs.join(", ")),
        };
        Ok(V { ty, c, k: None, pure })
    }

    // ------------------------------------------------------------ calls
    fn call(&mut self, e: &Expr, name: &str, args: &[Arg], exp: Option<&Ty>) -> R<V> {
        if BUILTIN_FNS.contains(&name) {
            return self.builtin(e, name, args);
        }
        if let Some(tn) = self.variants_by_name.get(name).cloned() {
            return self.construct(e.pos, &tn, Some(name), args, exp);
        }
        if let Some(d) = self.templates.get(name) {
            if matches!(d.kind, TypeKind::Record(_)) {
                return self.construct(e.pos, name, None, args, exp);
            }
        }
        if let Some(var) = self.lookup(name).cloned() {
            let c = if var.inout { format!("(*{})", var.cname) } else { var.cname.clone() };
            let fv = V { ty: var.ty.clone(), c, k: None, pure: true };
            return self.call_value(e.pos, name, fv, args);
        }
        let decl = match self.fns.get(name).cloned() {
            Some(d) => d,
            None => return err("E0112", e.pos, format!("unknown function `{}`", name)),
        };
        if !self.visible(&decl.module, decl.public) {
            return err("E0801", e.pos, format!("function `{}` is private to module `{}`", name, decl.module))
                .map_err(|d: Diag| d.help("mark it `pub` in its own file to use it from other modules"));
        }
        self.call_decl(e.pos, name, &decl, None, HashMap::new(), None, args, exp, false)
    }

    fn method_call(&mut self, e: &Expr, recv: &Expr, name: &str, args: &[Arg], exp: Option<&Ty>) -> R<V> {
        let static_head = match &recv.k {
            EK::Ident(tn) if self.lookup(tn).is_none() && !self.consts.contains_key(tn) && self.is_type_name(tn) => Some(tn.clone()),
            _ => None,
        };
        if let Some(h) = &static_head {
            if ["String", "List", "Map", "Box", "Task", "Mutex", "Chan"].contains(&h.as_str()) {
                return self.heap_static(e, h, name, args, exp);
            }
        }
        let recv_v = if static_head.is_none() { Some(self.expr(recv, None)?) } else { None };
        if let Some(rv) = &recv_v {
            if matches!(rv.ty, Ty::String | Ty::List(_) | Ty::Map(..) | Ty::Box(_) | Ty::Task(_) | Ty::Mutex(_) | Ty::Chan(_)) {
                return self.heap_method(e, recv, rv.clone(), name, args);
            }
        }
        let head = match (&static_head, &recv_v) {
            (Some(h), _) => h.clone(),
            (None, Some(v)) => self.head_of(&v.ty),
            _ => unreachable!(),
        };
        let cands: Vec<MethodInfo> = self.methods.get(&head).map(|l| l.iter().filter(|m| m.decl.name == name).cloned().collect()).unwrap_or_default();
        let shown = match &recv_v {
            Some(v) => v.ty.to_string(),
            None => head.clone(),
        };
        if cands.is_empty() {
            if let Some(rv) = &recv_v {
                if let Ty::Record(r) = &rv.ty {
                    if let Some((_, ft @ Ty::Fn(..))) = self.rec_defs[r].fields.iter().find(|(n, _)| n == name).cloned() {
                        let fv = V { ty: ft, c: format!("{}.f_{}", wrap(&rv.c), name), k: None, pure: rv.pure };
                        return self.call_value(e.pos, name, fv, args);
                    }
                }
            }
            return err("E0115", e.pos, format!("type {} has no method `{}`", shown, name));
        }
        let mut chosen: Option<(MethodInfo, HashMap<String, Ty>)> = None;
        for cand in &cands {
            let gs: HashSet<String> = cand.impl_generics.iter().map(|g| g.name.clone()).collect();
            let mut subst = HashMap::new();
            if let Some(rv) = &recv_v {
                if !self.unify_ast(&cand.target, &rv.ty, &mut subst, &gs) {
                    continue;
                }
                subst.insert("Self".to_string(), rv.ty.clone());
            }
            chosen = Some((cand.clone(), subst));
            break;
        }
        let (cand, subst) = match chosen {
            Some(c) => c,
            None => return err("E0115", e.pos, format!("type {} has no method `{}`", shown, name)),
        };
        let recv_arg = recv_v.map(|v| (recv, v));
        self.call_decl(e.pos, &format!("{}.{}", head, name), &cand.decl, Some((&cand.impl_generics, &cand.target)), subst, recv_arg, args, exp, true)
    }

    #[allow(clippy::too_many_arguments)]
    fn call_decl(
        &mut self,
        pos: Pos,
        label: &str,
        decl: &Rc<FnDecl>,
        impl_ctx: Option<(&[GenericParam], &TyAst)>,
        mut subst: HashMap<String, Ty>,
        recv: Option<(&Expr, V)>,
        args: &[Arg],
        exp: Option<&Ty>,
        is_method: bool,
    ) -> R<V> {
        let mut gs: HashSet<String> = decl.generics.iter().map(|g| g.name.clone()).collect();
        let mut all_generics: Vec<GenericParam> = vec![];
        if let Some((ig, _)) = impl_ctx {
            gs.extend(ig.iter().map(|g| g.name.clone()));
            gs.insert("Self".to_string());
            all_generics.extend(ig.iter().cloned());
        }
        all_generics.extend(decl.generics.iter().cloned());
        let has_self = decl.params.first().map(|p| p.name == "self").unwrap_or(false);
        if recv.is_some() && !has_self {
            return err("E0115", pos, format!("`{}` is an associated function; call it as `Type.{}(...)`", label, decl.name));
        }
        if recv.is_none() && has_self && is_method {
            return err("E0115", pos, format!("`{}` takes `self`; call it as `value.{}(...)`", label, decl.name));
        }
        let skip = if recv.is_some() { 1 } else { 0 };
        let params = &decl.params[skip..];
        if args.len() != params.len() {
            return err("E0405", pos, format!("`{}` takes {} argument(s), but {} were given", label, params.len(), args.len()));
        }
        // bind generics from the expected type, then from the receiver type
        if let (Some(r), Some(x)) = (&decl.ret, exp) {
            let mut s2 = subst.clone();
            if self.unify_ast(r, x, &mut s2, &gs) {
                subst = s2;
            }
        }
        if let (Some((_, target)), Some(self_ty)) = (impl_ctx, subst.get("Self").cloned()) {
            let mut s2 = subst.clone();
            if self.unify_ast(target, &self_ty, &mut s2, &gs) {
                subst = s2;
            }
        }

        // exclusivity of inout borrows
        let mut inout_roots: Vec<(String, Pos)> = vec![];
        if let Some((rexpr, _)) = &recv {
            if decl.params[0].inout {
                if let Some((r, p)) = root(rexpr) {
                    inout_roots.push((r.to_string(), p));
                }
            }
        }
        for (a, p) in args.iter().zip(params.iter()) {
            if p.inout && a.inout {
                if let Some((r, p)) = root(&a.e) {
                    if inout_roots.iter().any(|(x, _)| x == r) {
                        return err("E0301", p, format!("`{}` is borrowed mutably more than once in this call", r));
                    }
                    inout_roots.push((r.to_string(), p));
                }
            }
        }
        for (a, p) in args.iter().zip(params.iter()) {
            if !p.inout {
                let mut ids = vec![];
                idents(&a.e, &mut ids);
                for (r, _) in &inout_roots {
                    if ids.contains(r) {
                        return err("E0301", a.e.pos, format!("`{}` is borrowed mutably by another argument of this call and can't be read here", r));
                    }
                }
            }
        }

        let mut slots: Vec<Option<V>> = vec![];
        let mut cargs: Vec<String> = vec![String::new(); params.len() + skip];
        if let Some((rexpr, rv)) = recv {
            if decl.params[0].inout {
                self.check_assignable(rexpr, "borrow as inout")?;
                cargs[0] = format!("&{}", wrap(&rv.c));
                slots.push(None);
            } else {
                slots.push(Some(rv));
            }
        }
        for (i, (a, p)) in args.iter().zip(params.iter()).enumerate() {
            let idx = i + skip;
            let hint = if self.ast_has_unbound(&p.ty, &subst, &gs) { None } else { Some(self.resolve_with(&p.ty, &subst)?) };
            if hint.is_none() {
                if let (TyAst::Fn(fps, fr, _), EK::Lambda(..)) = (&p.ty, &a.e.k) {
                    let mut hp = vec![];
                    for t in fps {
                        hp.push(if self.ast_has_unbound(t, &subst, &gs) { None } else { Some(self.resolve_with(t, &subst)?) });
                    }
                    let hr = match fr {
                        Some(r) if !self.ast_has_unbound(r, &subst, &gs) => Some(self.resolve_with(r, &subst)?),
                        Some(_) => None,
                        None => Some(Ty::Unit),
                    };
                    self.lam_hint = Some((hp, hr));
                }
            }
            if p.inout && !a.inout {
                return Err(Diag::new("E0304", a.e.pos, format!("parameter `{}` is `inout`; pass the argument as `inout ...`", p.name)).fix(a.e.pos, 0, "inout "));
            }
            if !p.inout && a.inout {
                return Err(Diag::new("E0304", a.e.pos, format!("parameter `{}` is not `inout`; remove the `inout`", p.name)));
            }
            if p.inout {
                self.check_assignable(&a.e, "borrow as inout")?;
            }
            let mark = self.out.len();
            let mut hint2 = hint.clone();
            if hint2.is_none() {
                if let (TyAst::Fn(..), EK::Ident(fnname)) = (&p.ty, &a.e.k) {
                    if self.lookup(fnname).is_none() && self.fns.get(fnname).map(|d| d.generics.is_empty()).unwrap_or(false) {
                        let d = self.fns[fnname].clone();
                        let sig = self.instantiate(&d, &HashMap::new(), &format!("f_{}", fnname))?;
                        hint2 = Some(Ty::Fn(sig.params.iter().map(|x| x.2.clone()).collect(), Box::new(sig.ret.clone())));
                    }
                }
            }
            let v = self.expr(&a.e, hint2.as_ref())?;
            match &hint {
                Some(h) => {
                    if v.ty != *h {
                        return Err(mismatch(a.e.pos, h, &v.ty));
                    }
                }
                None => {
                    if !self.unify_ast(&p.ty, &v.ty, &mut subst, &gs) {
                        return err("E0401", a.e.pos, format!("argument of type {} doesn't match parameter type `{}`", v.ty, show_ast(&p.ty)));
                    }
                }
            }
            self.fix_order(slots.iter_mut().filter_map(|s| s.as_mut()).collect(), mark);
            if p.inout {
                cargs[idx] = format!("&{}", wrap(&v.c));
                slots.push(None);
            } else {
                slots.push(Some(v));
            }
        }

        // finish inference
        if let Some((_, target)) = impl_ctx {
            if !subst.contains_key("Self") && !self.ast_has_unbound(target, &subst, &gs) {
                let t = self.resolve_with(target, &subst)?;
                subst.insert("Self".to_string(), t);
            }
        }
        for g in &all_generics {
            if !subst.contains_key(&g.name) {
                return Err(Diag::new("E0409", pos, format!("cannot infer type parameter `{}` of `{}`", g.name, label)).help("add a type annotation to the binding that receives the result"));
            }
        }
        if impl_ctx.is_some() && !subst.contains_key("Self") {
            return Err(Diag::new("E0409", pos, format!("cannot infer the type for `{}`", label)));
        }
        for g in &all_generics {
            let ty = subst[&g.name].clone();
            for b in &g.bounds {
                if !self.traits.contains_key(b) {
                    return err("E0603", g.pos, format!("unknown trait `{}`", b));
                }
                if !self.implements(b, &ty) {
                    return err("E0601", pos, format!("type {} doesn't implement trait `{}` (required by `{}`)", ty, b, label));
                }
            }
        }
        for cap in decl.caps.iter().map(|c| &c.0) {
            if !self.caps.contains(cap) {
                return Err(self.cap_error(pos, label, cap));
            }
        }
        if decl.is_extern && !self.caps.iter().any(|c| c == "ffi") {
            return Err(self.cap_error(pos, label, "ffi"));
        }
        if (decl.is_extern || decl.is_unsafe) && self.unsafe_depth == 0 {
            return Err(Diag::new("E0802", pos, format!("call to {} `{}` is only allowed in an `unsafe` block or `unsafe fn`", if decl.is_extern { "C function" } else { "unsafe function" }, label))
                .help("wrap the call: `unsafe { ... }`"));
        }
        {
            let refs: Vec<&mut V> = slots.iter_mut().filter_map(|s| s.as_mut()).collect();
            self.hoist(refs);
        }
        for (i, s) in slots.iter().enumerate() {
            if let Some(v) = s {
                cargs[i] = v.c.clone();
            }
        }
        // instance name
        let mut cname = match impl_ctx {
            Some(_) => format!("m_{}_{}", mangle(&subst["Self"].to_string()), decl.name),
            None => format!("f_{}", decl.name),
        };
        for g in &all_generics {
            cname.push_str(&format!("__{}", mangle(&subst[&g.name].to_string())));
        }
        let sig = self.instantiate(decl, &subst, &cname)?;
        Ok(V { ty: sig.ret.clone(), c: format!("{}({})", cname, cargs.join(", ")), k: None, pure: false })
    }

    fn builtin(&mut self, e: &Expr, name: &str, args: &[Arg]) -> R<V> {
        if let Some(a) = args.iter().find(|a| a.inout) {
            return err("E0304", a.e.pos, "`inout` is not allowed here");
        }
        match name {
            "print" => {
                if !self.caps.iter().any(|c| c == "io") {
                    return Err(self.cap_error(e.pos, name, "io"));
                }
                if args.len() != 1 {
                    return err("E0405", e.pos, "`print` takes exactly one argument");
                }
                let v = self.expr(&args[0].e, None)?;
                let c = match &v.ty {
                    Ty::Int(t) if t.signed() => format!("ei_print_i((long long)({}))", v.c),
                    Ty::Int(_) => format!("ei_print_u((unsigned long long)({}))", v.c),
                    Ty::Bool => format!("ei_print_b({})", v.c),
                    Ty::Str => format!("ei_print_s({})", v.c),
                    Ty::String => format!("ei_print_s({}.p)", wrap(&v.c)),
                    Ty::Enum(k) if self.is_unit_enum(k) => format!("ei_print_s({}_names[{}])", self.ctype(&v.ty), v.c),
                    t => return err("E0401", args[0].e.pos, format!("cannot print a value of type {} yet", t)),
                };
                Ok(V { ty: Ty::Unit, c, k: None, pure: false })
            }
            "len" => {
                if args.len() != 1 {
                    return err("E0405", e.pos, "`len` takes exactly one argument");
                }
                let v = self.expr(&args[0].e, None)?;
                match &v.ty {
                    Ty::Array(_, n) => Ok(self.int_v(IntTy::Usize, *n as i128)),
                    Ty::String | Ty::List(_) | Ty::Map(..) => Ok(V { ty: Ty::Int(IntTy::Usize), c: format!("{}.len", wrap(&v.c)), k: None, pure: v.pure }),
                    t => err("E0401", args[0].e.pos, format!("`len` needs an array, List, Map or String, found {}", t)),
                }
            }
            "spawn" => {
                if !self.caps.iter().any(|c| c == "threads") {
                    return Err(self.cap_error(e.pos, name, "threads"));
                }
                if args.len() != 1 {
                    return err("E0405", e.pos, "`spawn` takes exactly one closure");
                }
                let fv = self.expr(&args[0].e, None)?;
                let ret = match &fv.ty {
                    Ty::Fn(ps, r) if ps.is_empty() => (**r).clone(),
                    t => return err("E0401", args[0].e.pos, format!("`spawn` needs a closure with no parameters, found {}", t)),
                };
                if ret == Ty::Never {
                    return err("E0401", args[0].e.pos, "the closure never returns a value");
                }
                let ty = Ty::Task(Box::new(ret));
                self.note_ty(&ty);
                let f = self.take(&fv);
                Ok(V { c: format!("ei_spawn_{}({})", mangle(&ty.to_string()), f), ty, k: None, pure: false })
            }
            "panic" => {
                if args.len() != 1 {
                    return err("E0405", e.pos, "`panic` takes exactly one message");
                }
                let v = self.expr(&args[0].e, Some(&Ty::Str))?;
                if v.ty != Ty::Str {
                    return Err(mismatch(args[0].e.pos, &Ty::Str, &v.ty));
                }
                Ok(V { ty: Ty::Never, c: format!("ei_trap({}, {})", v.c, e.pos.line), k: None, pure: false })
            }
            _ => {
                if !self.caps.iter().any(|c| c == "clock") {
                    return Err(self.cap_error(e.pos, name, "clock"));
                }
                if !args.is_empty() {
                    return err("E0405", e.pos, "`now_ms` takes no arguments");
                }
                Ok(V { ty: Ty::Int(IntTy::U64), c: "ei_now_ms()".into(), k: None, pure: false })
            }
        }
    }
}
