//! Statements, value forms (`if`/`match`/blocks) and pattern lowering.

use crate::ast::*;
use crate::check::*;
use crate::diag::{Diag, Pos};
use crate::pats::{self, Ctor, P};
use std::collections::HashMap;

#[derive(Default)]
struct Lowered {
    conds: Vec<String>,
    binds: Vec<(String, String, Ty, Pos)>,
}

impl<'a> Checker<'a> {
    pub fn block_body(&mut self, b: &Block, dest: &Dest, exp: Option<&Ty>) -> R<Ty> {
        self.scopes.push(HashMap::new());
        self.push_frame();
        let mut ty = Ty::Unit;
        let n = b.stmts.len();
        for (i, s) in b.stmts.iter().enumerate() {
            let last = i + 1 == n;
            ty = match (&s.k, last) {
                (SK::Expr(e), true) => self.compile_value(e, dest, exp)?,
                _ => self.stmt(s)?,
            };
        }
        self.scopes.pop();
        self.pop_frame(ty != Ty::Never);
        Ok(ty)
    }

    fn is_value_form(e: &Expr) -> bool {
        matches!(e.k, EK::If(..) | EK::Match(..) | EK::Block(..) | EK::Unsafe(..))
    }

    pub fn stmt(&mut self, s: &Stmt) -> R<Ty> {
        match &s.k {
            SK::Let { name, mutable, ty, init } => {
                let declared = match ty {
                    Some(t) => Some(self.resolve_ty(t)?),
                    None => None,
                };
                if Self::is_value_form(init) {
                    let cname = self.fresh(name);
                    let mark = self.out.len();
                    let indent = self.ind;
                    let t = self.compile_value(init, &Dest::Var(cname.clone()), declared.as_ref())?;
                    let fin = declared.clone().unwrap_or_else(|| t.clone());
                    self.check_bindable(&t, &fin, init.pos)?;
                    self.out.insert(mark, format!("{}{} {};", "  ".repeat(indent), self.ctype(&fin), cname));
                    self.register(&cname, &fin);
                    self.declare(name, s.pos, Var { ty: fin, mutable: *mutable, inout: false, cname, decl: Some(s.pos) })?;
                } else {
                    let v = self.expr(init, declared.as_ref())?;
                    let fin = declared.clone().unwrap_or_else(|| v.ty.clone());
                    self.check_bindable(&v.ty, &fin, init.pos)?;
                    let cname = self.fresh(name);
                    let c = self.take(&v);
                    self.emit(format!("{} {} = {};", self.ctype(&fin), cname, c));
                    self.register(&cname, &fin);
                    self.declare(name, s.pos, Var { ty: fin, mutable: *mutable, inout: false, cname, decl: Some(s.pos) })?;
                }
                Ok(Ty::Unit)
            }
            SK::LetPat { pat, mutable, init } => {
                let v = self.expr(init, None)?;
                self.check_bindable(&v.ty, &v.ty, init.pos)?;
                let acc = self.tmp();
                self.emit(format!("{} {} = {};", self.ctype(&v.ty), acc, v.c));
                let mut lw = Lowered::default();
                let ir = self.lower_pat(pat, &v.ty, &acc, &mut lw)?;
                {
                    let sig = |t: &Ty| self.sig_of(t);
                    if let Some(w) = pats::missing(&sig, &[vec![ir]], &[v.ty.clone()]) {
                        return Err(Diag::new("E0101", pat.pos, format!("refutable pattern in `let`: `{}` is not matched", w[0])).help("use `match` or `if let` for patterns that can fail"));
                    }
                }
                for (name, cexpr, ty, bp) in lw.binds {
                    let cname = self.fresh(&name);
                    self.bind_value(&cname, &ty, &cexpr);
                    self.declare(&name, bp, Var { ty, mutable: *mutable, inout: false, cname, decl: Some(s.pos) })?;
                }
                Ok(Ty::Unit)
            }
            SK::Assign { target, op, value } => {
                self.check_assignable(target, "assign to")?;
                let tv = self.expr(target, None)?;
                if op.is_none() && Self::is_value_form(value) {
                    let tmp = self.tmp();
                    let mark = self.out.len();
                    let indent = self.ind;
                    let t = self.compile_value(value, &Dest::Var(tmp.clone()), Some(&tv.ty))?;
                    self.check_bindable(&t, &tv.ty, value.pos)?;
                    self.out.insert(mark, format!("{}{} {};", "  ".repeat(indent), self.ctype(&tv.ty), tmp));
                    if self.owns(&tv.ty) {
                        self.emit_drop(&tv.c, &tv.ty);
                    }
                    self.emit(format!("{} = {};", tv.c, tmp));
                    return Ok(Ty::Unit);
                }
                let mark = self.out.len();
                let vv = self.expr(value, Some(&tv.ty))?;
                let _ = mark;
                if vv.ty != tv.ty {
                    return Err(mismatch(value.pos, &tv.ty, &vv.ty));
                }
                match op {
                    None => {
                        let c = self.take(&vv);
                        if self.owns(&tv.ty) {
                            self.emit_drop(&tv.c, &tv.ty);
                        }
                        self.emit(format!("{} = {};", tv.c, c));
                    }
                    Some(o) => {
                        let it = match &tv.ty {
                            Ty::Int(i) => *i,
                            t => return err("E0401", s.pos, format!("operator {}= needs integers, found {}", o.sym(), t)),
                        };
                        let p = self.tmp();
                        self.emit(format!("{}* {} = &{};", it.c(), p, wrap(&tv.c)));
                        let call = Self::arith_c(*o, it, &format!("*{}", p), &vv.c, s.pos.line);
                        self.emit(format!("*{} = {};", p, call));
                    }
                }
                Ok(Ty::Unit)
            }
            SK::Expr(e) => self.compile_value(e, &Dest::Discard, None),
            SK::While(c, body) => {
                let mark = self.out.len();
                let base = self.frames.len();
                self.push_frame(); // temporaries of the condition live for one iteration
                let cv = self.expr(c, Some(&Ty::Bool))?;
                if cv.ty != Ty::Bool {
                    return Err(mismatch(c.pos, &Ty::Bool, &cv.ty));
                }
                self.loops += 1;
                self.loop_bases.push(base);
                if self.out.len() > mark {
                    let lines = self.out.split_off(mark);
                    self.emit("for (;;) {");
                    self.out.extend(lines);
                    self.ind += 1;
                    if self.frames[base].is_empty() {
                        self.emit(format!("if (!({})) break;", cv.c));
                    } else {
                        self.emit(format!("if (!({})) {{", cv.c));
                        self.ind += 1;
                        self.drop_frames_from(base);
                        self.emit("break;");
                        self.ind -= 1;
                        self.emit("}");
                    }
                } else {
                    self.emit(format!("while ({}) {{", unparen(&cv.c)));
                    self.ind += 1;
                }
                self.block_inline(body)?;
                self.pop_frame(true);
                self.ind -= 1;
                self.emit("}");
                self.loop_bases.pop();
                self.loops -= 1;
                Ok(Ty::Unit)
            }
            SK::For { var, lo, hi, body } => {
                let (vl, vh);
                if is_lit(lo) && !is_lit(hi) {
                    vh = self.expr(hi, None)?;
                    vl = self.expr(lo, Some(&vh.ty))?;
                } else {
                    let mut l0 = self.expr(lo, None)?;
                    let mark = self.out.len();
                    vh = self.expr(hi, Some(&l0.ty))?;
                    self.fix_order(vec![&mut l0], mark);
                    vl = l0;
                }
                let it = match (&vl.ty, &vh.ty) {
                    (Ty::Int(a), Ty::Int(b)) if a == b => *a,
                    (Ty::Int(_), _) => return Err(mismatch(hi.pos, &vl.ty, &vh.ty)),
                    _ => return err("E0401", lo.pos, format!("range bounds must be integers, found {}", vl.ty)),
                };
                let mut pair = [vl, vh];
                {
                    let refs: Vec<&mut V> = pair.iter_mut().collect();
                    self.hoist(refs);
                }
                let [vl, vh] = pair;
                let cname = self.fresh(var);
                let end = self.tmp();
                self.emit(format!("for ({t} {v} = {lo}, {e} = {hi}; {v} < {e}; {v}++) {{", t = it.c(), v = cname, lo = vl.c, e = end, hi = vh.c));
                self.ind += 1;
                self.loops += 1;
                self.loop_bases.push(self.frames.len());
                self.scopes.push(HashMap::new());
                self.declare(var, s.pos, Var { ty: Ty::Int(it), mutable: false, inout: false, cname, decl: None })?;
                self.block_inline(body)?;
                self.scopes.pop();
                self.loop_bases.pop();
                self.loops -= 1;
                self.ind -= 1;
                self.emit("}");
                Ok(Ty::Unit)
            }
            SK::ForEach { var, iter, body } => {
                let v = self.expr(iter, None)?;
                let (et, is_list) = match &v.ty {
                    Ty::List(e) => ((**e).clone(), true),
                    Ty::Array(e, _) => ((**e).clone(), false),
                    t => {
                        return err("E0401", iter.pos, format!("can't iterate over a value of type {}", t))
                            .map_err(|d: Diag| d.help("iterate over a List or an array, or use a range: `for i in 0..n`"))
                    }
                };
                let base = self.tmp();
                let ct = self.ctype(&v.ty);
                if is_list {
                    self.emit(format!("{}* {} = &{};", ct, base, wrap(&v.c)));
                } else {
                    let copy = self.tmp();
                    self.emit(format!("{} {} = {};", ct, copy, v.c));
                    self.emit(format!("{}* {} = &{};", ct, base, copy));
                }
                let i = self.tmp();
                let limit = match &v.ty {
                    Ty::Array(_, n) => n.to_string(),
                    _ => format!("{}->len", base),
                };
                self.emit(format!("for (uint64_t {i} = 0; {i} < {lim}; {i}++) {{", i = i, lim = limit));
                self.ind += 1;
                self.loops += 1;
                self.loop_bases.push(self.frames.len());
                self.push_frame();
                self.scopes.push(HashMap::new());
                let cname = self.fresh(var);
                let place = if is_list { format!("{}->d[ei_idx({}, {}->len, {})]", base, i, base, s.pos.line) } else { format!("{}->d[{}]", base, i) };
                self.bind_value(&cname, &et, &place);
                self.declare(var, s.pos, Var { ty: et, mutable: false, inout: false, cname, decl: None })?;
                self.block_inline(body)?;
                self.scopes.pop();
                self.pop_frame(true);
                self.loop_bases.pop();
                self.loops -= 1;
                self.ind -= 1;
                self.emit("}");
                Ok(Ty::Unit)
            }
            SK::Return(e) => {
                match e {
                    None => {
                        if self.ret != Ty::Unit {
                            return err("E0401", s.pos, format!("`return` needs a value of type {}", self.ret));
                        }
                        self.drop_frames_from(0);
                        self.emit("return;");
                    }
                    Some(e) => {
                        if self.ret == Ty::Unit {
                            return err("E0401", e.pos, "this function returns (), it can't return a value");
                        }
                        let exp = self.ret.clone();
                        let t = self.compile_value(e, &Dest::Return, Some(&exp))?;
                        if t != exp && t != Ty::Never {
                            return Err(mismatch(e.pos, &exp, &t));
                        }
                    }
                }
                Ok(Ty::Never)
            }
            SK::Break | SK::Continue => {
                if self.loops == 0 {
                    return err("E0306", s.pos, "`break`/`continue` outside of a loop");
                }
                let base = *self.loop_bases.last().unwrap_or(&0);
                self.drop_frames_from(base);
                self.emit(if matches!(s.k, SK::Break) { "break;" } else { "continue;" });
                Ok(Ty::Never)
            }
            SK::Assert(c, msg) => {
                let cv = self.expr(c, Some(&Ty::Bool))?;
                if cv.ty != Ty::Bool {
                    return Err(mismatch(c.pos, &Ty::Bool, &cv.ty));
                }
                let m = msg.clone().unwrap_or_else(|| "assertion failed".to_string());
                self.emit(format!("if (!({})) ei_trap({}, {});", cv.c, cstr(&m), s.pos.line));
                Ok(Ty::Unit)
            }
        }
    }

    /// Emit a block's statements in the current C scope (caller already opened `{`).
    pub fn block_inline(&mut self, b: &Block) -> R<()> {
        self.block_body(b, &Dest::Discard, None)?;
        Ok(())
    }

    pub fn check_bindable(&self, actual: &Ty, fin: &Ty, pos: Pos) -> R<()> {
        if *actual == Ty::Never {
            return err("E0401", pos, "this expression never produces a value");
        }
        if *actual == Ty::Unit {
            return err("E0401", pos, "cannot bind a value of type ()");
        }
        if actual != fin {
            return Err(mismatch(pos, fin, actual));
        }
        Ok(())
    }

    pub fn check_assignable(&self, target: &Expr, verb: &str) -> R<()> {
        let (name, pos) = match root(target) {
            Some(r) => r,
            None => return err("E0303", target.pos, format!("cannot {} this expression", verb)),
        };
        match self.lookup(name) {
            Some(v) if v.mutable || v.inout => Ok(()),
            Some(v) => {
                let d = Diag::new("E0303", pos, format!("cannot {} `{}`: it is not mutable", verb, name));
                Err(match v.decl {
                    Some(dp) => d.fix(dp, 3, "var").help(format!("declare `{}` with `var`", name)),
                    None => d.help("parameters are immutable; declare it `inout` to modify the caller's value"),
                })
            }
            None if self.consts.contains_key(name) => err("E0303", pos, format!("cannot {} constant `{}`", verb, name)),
            None => err("E0110", pos, format!("unknown name `{}`", name)),
        }
    }

    // ------------------------------------------------------------ value forms (if / match / block)
    pub fn compile_value(&mut self, e: &Expr, dest: &Dest, exp: Option<&Ty>) -> R<Ty> {
        match &e.k {
            EK::If(c, then, els) => self.compile_if(c, then, els.as_deref(), dest, exp),
            EK::Match(s, arms, end) => self.compile_match(e, s, arms, *end, dest, exp),
            EK::Block(b) => {
                self.emit("{");
                self.ind += 1;
                let t = self.block_body(b, dest, exp)?;
                self.ind -= 1;
                self.emit("}");
                Ok(t)
            }
            EK::Unsafe(b) => {
                self.emit("{");
                self.ind += 1;
                self.unsafe_depth += 1;
                let t = self.block_body(b, dest, exp);
                self.unsafe_depth -= 1;
                let t = t?;
                self.ind -= 1;
                self.emit("}");
                Ok(t)
            }
            _ => {
                let v = self.expr(e, exp)?;
                if v.ty == Ty::Never {
                    self.emit(format!("{};", v.c));
                    return Ok(Ty::Never);
                }
                match dest {
                    Dest::Return => {
                        if v.ty != self.ret {
                            return Err(mismatch(e.pos, &self.ret.clone(), &v.ty));
                        }
                        let c = self.take(&v);
                        if self.has_pending_drops() {
                            let r = self.tmp();
                            self.emit(format!("{} {} = {};", self.ctype(&v.ty), r, c));
                            self.drop_frames_from(0);
                            self.emit(format!("return {};", r));
                        } else {
                            self.emit(format!("return {};", c));
                        }
                        Ok(v.ty)
                    }
                    Dest::Var(n) => {
                        if v.ty == Ty::Unit {
                            return err("E0401", e.pos, "cannot bind a value of type ()");
                        }
                        let c = self.take(&v);
                        self.emit(format!("{} = {};", n, c));
                        Ok(v.ty)
                    }
                    Dest::Discard => {
                        if v.ty == Ty::Unit {
                            self.emit(format!("{};", v.c));
                        } else {
                            self.emit(format!("(void)({});", v.c));
                        }
                        Ok(Ty::Unit)
                    }
                }
            }
        }
    }

    fn unify(a: Ty, b: Ty, pos: Pos) -> R<Ty> {
        if a == Ty::Never {
            Ok(b)
        } else if b == Ty::Never || a == b {
            Ok(a)
        } else {
            err("E0401", pos, format!("branches have different types: {} and {}", a, b))
        }
    }

    fn compile_if(&mut self, c: &Expr, then: &Block, els: Option<&Expr>, dest: &Dest, exp: Option<&Ty>) -> R<Ty> {
        let cv = self.expr(c, Some(&Ty::Bool))?;
        if cv.ty != Ty::Bool {
            return Err(mismatch(c.pos, &Ty::Bool, &cv.ty));
        }
        self.emit(format!("if ({}) {{", unparen(&cv.c)));
        self.ind += 1;
        let t1 = self.block_body(then, dest, exp)?;
        self.ind -= 1;
        match els {
            Some(el) => {
                self.emit("} else {");
                self.ind += 1;
                let t2 = match &el.k {
                    EK::Block(b) => self.block_body(b, dest, exp)?,
                    _ => self.compile_value(el, dest, exp)?,
                };
                self.ind -= 1;
                self.emit("}");
                Self::unify(t1, t2, el.pos)
            }
            None => {
                self.emit("}");
                Ok(Ty::Unit)
            }
        }
    }

    // ------------------------------------------------------------ patterns
    pub fn sig_of(&self, ty: &Ty) -> Option<Vec<(Ctor, Vec<Ty>)>> {
        match ty {
            Ty::Enum(k) => Some(self.enum_defs[k].variants.iter().map(|v| (Ctor::Variant(v.name.clone()), v.fields.iter().map(|f| f.1.clone()).collect())).collect()),
            Ty::Bool => Some(vec![(Ctor::Bool(true), vec![]), (Ctor::Bool(false), vec![])]),
            Ty::Tuple(ts) => Some(vec![(Ctor::Single(String::new()), ts.clone())]),
            Ty::Record(k) => {
                let d = &self.rec_defs[k];
                Some(vec![(Ctor::Single(d.template.clone()), d.fields.iter().map(|f| f.1.clone()).collect())])
            }
            _ => None,
        }
    }

    fn tag_test(&self, k: &str, acc: &str, variant: &str) -> String {
        if self.is_unit_enum(k) {
            format!("{} == {}", acc, self.tag_const(k, variant))
        } else {
            format!("{}.tag == {}", acc, self.tag_const(k, variant))
        }
    }

    fn lower_pat(&mut self, pat: &Pat, ty: &Ty, acc: &str, out: &mut Lowered) -> R<P> {
        match &pat.k {
            PK::Wild => Ok(P::Wild),
            PK::Name(n) => {
                if let Ty::Enum(k) = ty {
                    if let Some(v) = self.enum_defs[k].variants.iter().find(|v| &v.name == n).cloned() {
                        if !v.fields.is_empty() {
                            return Err(Diag::new("E0410", pat.pos, format!("variant `{}` has {} field(s); write `{}(...)`", n, v.fields.len(), n)));
                        }
                        out.conds.push(self.tag_test(k, acc, n));
                        return Ok(P::C(Ctor::Variant(n.clone()), vec![]));
                    }
                }
                if let Some(other) = self.variants_by_name.get(n) {
                    return err("E0401", pat.pos, format!("`{}` is a variant of {}, but the value has type {}", n, other, ty));
                }
                out.binds.push((n.clone(), acc.to_string(), ty.clone(), pat.pos));
                Ok(P::Wild)
            }
            PK::Int(v) => match ty {
                Ty::Int(it) => {
                    if *v < it.min() || *v > it.max() {
                        return err("E0501", pat.pos, format!("pattern {} doesn't fit in {}", v, it.name()));
                    }
                    out.conds.push(format!("{} == {}", acc, lit_c(*it, *v)));
                    Ok(P::C(Ctor::Int(*v), vec![]))
                }
                t => Err(mismatch(pat.pos, t, &Ty::Int(IntTy::I32))),
            },
            PK::Bool(b) => match ty {
                Ty::Bool => {
                    out.conds.push(if *b { acc.to_string() } else { format!("!{}", wrap(acc)) });
                    Ok(P::C(Ctor::Bool(*b), vec![]))
                }
                t => Err(mismatch(pat.pos, t, &Ty::Bool)),
            },
            PK::Str(s) => match ty {
                Ty::Str => {
                    out.conds.push(format!("strcmp({}, {}) == 0", acc, cstr(s)));
                    Ok(P::C(Ctor::Str(s.clone()), vec![]))
                }
                t => Err(mismatch(pat.pos, t, &Ty::Str)),
            },
            PK::Tuple(ps) => match ty {
                Ty::Tuple(ts) if ts.len() == ps.len() => {
                    let mut subs = vec![];
                    for (i, (p, t)) in ps.iter().zip(ts.clone().iter()).enumerate() {
                        subs.push(self.lower_pat(p, t, &format!("{}.f_{}", acc, i), out)?);
                    }
                    Ok(P::C(Ctor::Single(String::new()), subs))
                }
                Ty::Tuple(ts) => Err(Diag::new("E0410", pat.pos, format!("tuple pattern has {} elements, but the value has {}", ps.len(), ts.len()))),
                t => err("E0401", pat.pos, format!("tuple pattern used on a value of type {}", t)),
            },
            PK::Variant(n, ps) => {
                if let Ty::Enum(k) = ty {
                    if let Some(v) = self.enum_defs[k].variants.iter().find(|v| &v.name == n).cloned() {
                        if v.fields.len() != ps.len() {
                            return Err(Diag::new("E0410", pat.pos, format!("variant `{}` has {} field(s), but the pattern has {}", n, v.fields.len(), ps.len())));
                        }
                        out.conds.push(self.tag_test(k, acc, n));
                        let mut subs = vec![];
                        for (p, (fname, fty)) in ps.iter().zip(v.fields.iter()) {
                            subs.push(self.lower_pat(p, fty, &format!("{}.u.m_{}.f_{}", acc, n, fname), out)?);
                        }
                        return Ok(P::C(Ctor::Variant(n.clone()), subs));
                    }
                }
                if let Ty::Record(k) = ty {
                    let d = self.rec_defs[k].clone();
                    if &d.template == n {
                        if d.fields.len() != ps.len() {
                            return Err(Diag::new("E0410", pat.pos, format!("`{}` has {} field(s), but the pattern has {}", n, d.fields.len(), ps.len())));
                        }
                        let mut subs = vec![];
                        for (p, (fname, fty)) in ps.iter().zip(d.fields.iter()) {
                            subs.push(self.lower_pat(p, fty, &format!("{}.f_{}", acc, fname), out)?);
                        }
                        return Ok(P::C(Ctor::Single(n.clone()), subs));
                    }
                }
                match self.variants_by_name.get(n) {
                    Some(other) => err("E0401", pat.pos, format!("`{}` is a variant of {}, but the value has type {}", n, other, ty)),
                    None => err("E0114", pat.pos, format!("type {} has no variant or constructor `{}`", ty, n)),
                }
            }
        }
    }

    pub fn compile_match(&mut self, m: &Expr, scrut: &Expr, arms: &[Arm], _end: Pos, dest: &Dest, exp: Option<&Ty>) -> R<Ty> {
        let sv = self.expr(scrut, None)?;
        if matches!(sv.ty, Ty::Unit | Ty::Never) {
            return err("E0401", scrut.pos, format!("cannot match on a value of type {}", sv.ty));
        }
        if arms.is_empty() {
            return err("E0101", m.pos, "match has no arms");
        }
        let place = matches!(scrut.k, EK::Ident(_) | EK::Field(..) | EK::Index(..)) && sv.pure;
        let acc = if place || self.fresh.contains(&sv.c) {
            sv.c.clone()
        } else {
            let t = self.tmp();
            self.emit(format!("{} {} = {};", self.ctype(&sv.ty), t, sv.c));
            t
        };

        // lower every pattern, check reachability
        let mut rows: Vec<Vec<P>> = vec![];
        let mut lowered: Vec<(String, Vec<(String, String, Ty, Pos)>)> = vec![];
        for arm in arms {
            let mut alt_conds: Vec<String> = vec![];
            let mut binds = vec![];
            let mut arm_useful = false;
            for p in &arm.pats {
                let mut lw = Lowered::default();
                let ir = self.lower_pat(p, &sv.ty, &acc, &mut lw)?;
                if arm.pats.len() > 1 && !lw.binds.is_empty() {
                    return err("E0001", p.pos, "or-patterns can't bind names");
                }
                {
                    let sig = |t: &Ty| self.sig_of(t);
                    arm_useful |= pats::useful(&sig, &rows, &[ir.clone()], &[sv.ty.clone()]);
                }
                rows.push(vec![ir]);
                alt_conds.push(if lw.conds.is_empty() { "1".to_string() } else { lw.conds.join(" && ") });
                binds = lw.binds;
            }
            if !arm_useful {
                return err("E0102", arm.pats[0].pos, "unreachable arm: everything it matches is already handled above");
            }
            lowered.push((alt_conds.iter().map(|c| format!("({})", c)).collect::<Vec<_>>().join(" || "), binds));
        }
        {
            let sig = |t: &Ty| self.sig_of(t);
            if let Some(w) = pats::missing(&sig, &rows, &[sv.ty.clone()]) {
                return Err(Diag::new("E0101", m.pos, format!("non-exhaustive match: `{}` is not handled", w[0])).help("add an arm for it, or a `_` arm"));
            }
        }

        // emit
        let n = arms.len();
        let mut result = Ty::Never;
        for (i, arm) in arms.iter().enumerate() {
            let (cond, binds) = &lowered[i];
            let head = if n == 1 {
                "{".to_string()
            } else if i == 0 {
                format!("if ({}) {{", unparen(&cond))
            } else if i == n - 1 {
                "} else {".to_string()
            } else {
                format!("}} else if ({}) {{", unparen(&cond))
            };
            self.emit(head);
            self.ind += 1;
            self.scopes.push(HashMap::new());
            self.push_frame();
            for (name, cexpr, ty, bp) in binds {
                let cname = self.fresh(name);
                self.bind_value(&cname, ty, cexpr);
                self.declare(name, *bp, Var { ty: ty.clone(), mutable: false, inout: false, cname, decl: None })?;
            }
            let t = match &arm.body {
                ArmBody::Expr(e) => match &e.k {
                    EK::Block(b) => self.block_body(b, dest, exp)?,
                    _ => self.compile_value(e, dest, exp)?,
                },
                ArmBody::Stmt(s) => self.stmt(s)?,
            };
            self.pop_frame(t != Ty::Never);
            self.scopes.pop();
            self.ind -= 1;
            let pos = match &arm.body {
                ArmBody::Expr(e) => e.pos,
                ArmBody::Stmt(s) => s.pos,
            };
            result = Self::unify(result, t, pos)?;
        }
        self.emit("}");
        if matches!(dest, Dest::Discard) && result != Ty::Never {
            return Ok(Ty::Unit);
        }
        Ok(result)
    }
}

/// Strip one redundant pair of outer parentheses (keeps clang's -Wparentheses-equality quiet).
pub fn unparen(c: &str) -> &str {
    let b = c.as_bytes();
    if b.len() >= 2 && b[0] == b'(' && b[b.len() - 1] == b')' {
        let mut depth = 0;
        let mut in_str = false;
        let mut esc = false;
        for (i, ch) in b.iter().enumerate() {
            if in_str {
                if esc {
                    esc = false;
                } else if *ch == b'\\' {
                    esc = true;
                } else if *ch == b'"' {
                    in_str = false;
                }
                continue;
            }
            match ch {
                b'"' => in_str = true,
                b'(' => depth += 1,
                b')' => {
                    depth -= 1;
                    if depth == 0 && i != b.len() - 1 {
                        return c;
                    }
                }
                _ => {}
            }
        }
        return &c[1..c.len() - 1];
    }
    c
}
