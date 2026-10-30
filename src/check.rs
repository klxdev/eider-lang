//! Checker core: types, generics (monomorphization), items, C assembly.
//! Statements live in stmt.rs, expressions and calls in expr.rs.
//!
//! Checking and code generation are fused: `expr` returns the type, the C text, and
//! whether the expression is pure. Evaluation order is made explicit (left to right)
//! by hoisting operands into temporaries whenever a call is involved, so the generated C
//! never depends on C's unspecified evaluation order.

use crate::ast::*;
use crate::diag::{Diag, Pos};
use crate::prelude::prelude;
pub use crate::ty::*;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

pub type R<X> = Result<X, Diag>;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Build,
    Test,
    /// Library: no `main`; `export fn`s get C entry points and a header.
    Lib,
    /// WebAssembly library: like `Lib`, scalars only, freestanding runtime, TypeScript declarations.
    Wasm,
}

#[derive(Clone)]
pub struct VariantDef {
    pub name: String,
    pub fields: Vec<(String, Ty)>,
}

#[derive(Clone)]
pub struct EnumDef {
    pub template: String,
    pub args: Vec<Ty>,
    pub variants: Vec<VariantDef>,
    pub payload: bool,
}

#[derive(Clone)]
pub struct RecDef {
    pub template: String,
    pub args: Vec<Ty>,
    pub fields: Vec<(String, Ty)>,
}

#[derive(Clone)]
pub struct Sig {
    pub params: Vec<(String, bool, Ty)>,
    pub ret: Ty,
    pub caps: Vec<String>,
}

#[derive(Clone)]
pub struct Var {
    pub ty: Ty,
    pub mutable: bool,
    pub inout: bool,
    pub cname: String,
    pub decl: Option<Pos>,
}

#[derive(Clone)]
pub struct V {
    pub ty: Ty,
    pub c: String,
    pub k: Option<i128>,
    pub pure: bool,
}

#[derive(Clone)]
pub enum Dest {
    Return,
    Var(String),
    Discard,
}

#[derive(Clone)]
pub struct MethodInfo {
    pub decl: Rc<FnDecl>,
    pub impl_generics: Vec<GenericParam>,
    pub target: TyAst,
    pub trait_: Option<String>,
}

pub struct Pending {
    pub decl: Rc<FnDecl>,
    pub subst: HashMap<String, Ty>,
    pub cname: String,
    pub sig: Sig,
}

pub const KNOWN_CAPS: &[&str] = &["io", "clock", "fs", "net", "threads", "ffi", "python", "js", "wasm"];
pub const BUILTIN_FNS: &[&str] = &["print", "len", "now_ms", "panic", "spawn"];

pub fn err<X>(code: &'static str, pos: Pos, msg: impl Into<String>) -> R<X> {
    Err(Diag::new(code, pos, msg))
}

pub fn mismatch(pos: Pos, expected: &Ty, found: &Ty) -> Diag {
    let mut d = Diag::new("E0401", pos, format!("expected {}, found {}", expected, found));
    if let (Ty::Int(_), Ty::Int(_)) = (expected, found) {
        d = d.help(format!("there are no implicit conversions; use an explicit cast: `value as {}`", expected));
    }
    d
}

pub fn root(e: &Expr) -> Option<(&str, Pos)> {
    match &e.k {
        EK::Ident(n) => Some((n.as_str(), e.pos)),
        EK::Field(b, _) | EK::Index(b, _) => root(b),
        _ => None,
    }
}

pub fn idents(e: &Expr, out: &mut Vec<String>) {
    match &e.k {
        EK::Ident(n) => out.push(n.clone()),
        EK::Unary(_, x) | EK::Cast(x, _) | EK::Field(x, _) | EK::ArrayRepeat(x, _) | EK::Try(x) => idents(x, out),
        EK::Binary(_, a, b) | EK::Index(a, b) => {
            idents(a, out);
            idents(b, out)
        }
        EK::Call(_, args) => args.iter().for_each(|a| idents(&a.e, out)),
        EK::MethodCall(r, _, args) => {
            idents(r, out);
            args.iter().for_each(|a| idents(&a.e, out))
        }
        EK::ArrayLit(es) | EK::Tuple(es) => es.iter().for_each(|x| idents(x, out)),
        _ => {}
    }
}

pub fn is_lit(e: &Expr) -> bool {
    match &e.k {
        EK::Int(_) => true,
        EK::Unary(UnOp::Neg, x) => is_lit(x),
        _ => false,
    }
}

pub fn show_ast(t: &TyAst) -> String {
    match t {
        TyAst::Name(n, _) => n.clone(),
        TyAst::Generic(n, a, _) => format!("{}[{}]", n, a.iter().map(show_ast).collect::<Vec<_>>().join(", ")),
        TyAst::Array(e, n, _) => format!("[{}; {}]", show_ast(e), n),
        TyAst::Tuple(ts) => format!("({})", ts.iter().map(show_ast).collect::<Vec<_>>().join(", ")),
        TyAst::Fn(ps, r, _) => {
            let mut s = format!("fn({})", ps.iter().map(show_ast).collect::<Vec<_>>().join(", "));
            if let Some(r) = r {
                s.push_str(&format!(" -> {}", show_ast(r)));
            }
            s
        }
        TyAst::Unit => "()".into(),
    }
}

fn head_of_ast(t: &TyAst) -> String {
    match t {
        TyAst::Name(n, _) | TyAst::Generic(n, _, _) => n.clone(),
        TyAst::Array(..) => "[]".into(),
        TyAst::Tuple(_) | TyAst::Unit => "()".into(),
        TyAst::Fn(..) => "fn".into(),
    }
}

pub struct Checker<'a> {
    #[allow(dead_code)]
    pub file: &'a str,
    pub mode: Mode,
    pub templates: HashMap<String, Rc<TypeDecl>>,
    pub enum_defs: HashMap<String, EnumDef>,
    pub rec_defs: HashMap<String, RecDef>,
    pub type_order: Vec<Ty>,
    pub variants_by_name: HashMap<String, String>,
    pub fns: HashMap<String, Rc<FnDecl>>,
    pub traits: HashMap<String, Rc<TraitDecl>>,
    pub trait_impls: HashMap<String, Vec<(Vec<GenericParam>, TyAst)>>,
    pub methods: HashMap<String, Vec<MethodInfo>>,
    pub consts: HashMap<String, (Ty, Option<i128>)>,
    pub const_defs: Vec<String>,
    pub comps: Vec<Ty>,
    pub instances: HashMap<String, Sig>,
    pub pending: Vec<Pending>,
    pub tsubst: HashMap<String, Ty>,
    pub eq_needed: Vec<Ty>,
    pub eq_seen: HashSet<String>,
    pub scopes: Vec<HashMap<String, Var>>,
    pub out: Vec<String>,
    pub ind: usize,
    pub tmp: usize,
    pub ret: Ty,
    pub caps: Vec<String>,
    pub sig_end: Pos,
    pub loops: usize,
    pub protos: Vec<String>,
    pub tests: Vec<(String, String)>,
    // ownership
    pub frames: Vec<Vec<(String, Ty)>>,
    pub fresh: HashSet<String>,
    pub loop_bases: Vec<usize>,
    pub glue_needed: Vec<Ty>,
    pub glue_seen: HashSet<String>,
    pub glue_i: usize,
    pub eq_i: usize,
    pub heap_tys: Vec<Ty>,
    pub heap_i: usize,
    pub aux_protos: String,
    pub aux_bodies: String,
    // closures
    pub lam_hint: Option<(Vec<Option<Ty>>, Option<Ty>)>,
    pub closure_n: usize,
    pub lifted_types: String,
    pub lifted: Vec<String>,
    pub thunks: HashSet<String>,
    // modules / unsafe / exports
    pub cur_mod: String,
    pub unsafe_depth: usize,
    pub exports: Vec<(String, Sig)>,
    pub const_vis: HashMap<String, (String, bool)>,
    pub header_types: String,
    pub err_mod: String,
    pub uses_threads: bool,
    pub wasm_threads: bool,
}

pub fn compile(items: &[Item], file: &str, mode: Mode) -> R<(String, String)> {
    let mut c = Checker {
        file,
        mode,
        templates: HashMap::new(),
        enum_defs: HashMap::new(),
        rec_defs: HashMap::new(),
        type_order: vec![],
        variants_by_name: HashMap::new(),
        fns: HashMap::new(),
        traits: HashMap::new(),
        trait_impls: HashMap::new(),
        methods: HashMap::new(),
        consts: HashMap::new(),
        const_defs: vec![],
        comps: vec![],
        instances: HashMap::new(),
        pending: vec![],
        tsubst: HashMap::new(),
        eq_needed: vec![],
        eq_seen: HashSet::new(),
        scopes: vec![],
        out: vec![],
        ind: 0,
        tmp: 0,
        ret: Ty::Unit,
        caps: vec![],
        sig_end: Pos::default(),
        loops: 0,
        protos: vec![],
        tests: vec![],
        frames: vec![],
        fresh: HashSet::new(),
        loop_bases: vec![],
        glue_needed: vec![],
        glue_seen: HashSet::new(),
        glue_i: 0,
        eq_i: 0,
        heap_tys: vec![],
        heap_i: 0,
        aux_protos: String::new(),
        aux_bodies: String::new(),
        lam_hint: None,
        closure_n: 0,
        lifted_types: String::new(),
        lifted: vec![],
        thunks: HashSet::new(),
        cur_mod: "*".to_string(),
        unsafe_depth: 0,
        exports: vec![],
        const_vis: HashMap::new(),
        header_types: String::new(),
        err_mod: String::new(),
        uses_threads: false,
        wasm_threads: false,
    };
    c.run(items)
}

impl<'a> Checker<'a> {
    // ------------------------------------------------------------ utilities
    pub fn emit(&mut self, s: impl AsRef<str>) {
        let line = format!("{}{}", "  ".repeat(self.ind), s.as_ref());
        self.out.push(line);
    }
    pub fn tmp(&mut self) -> String {
        self.tmp += 1;
        format!("t{}", self.tmp)
    }
    pub fn lookup(&self, n: &str) -> Option<&Var> {
        self.scopes.iter().rev().find_map(|s| s.get(n))
    }
    pub fn fresh(&mut self, n: &str) -> String {
        if self.lookup(n).is_some() {
            self.tmp += 1;
            format!("v_{}__{}", n, self.tmp)
        } else {
            format!("v_{}", n)
        }
    }
    pub fn declare(&mut self, name: &str, pos: Pos, v: Var) -> R<()> {
        let sc = self.scopes.last_mut().unwrap();
        if sc.contains_key(name) {
            return err("E0305", pos, format!("`{}` is already declared in this scope", name))
                .map_err(|d: Diag| d.help("assign to it (declare with `var`), or pick a different name"));
        }
        sc.insert(name.to_string(), v);
        Ok(())
    }

    pub fn note_ty(&mut self, t: &Ty) {
        match t {
            Ty::Array(e, _) => {
                let e = (**e).clone();
                self.note_ty(&e);
            }
            Ty::Tuple(ts) => {
                for x in ts.clone() {
                    self.note_ty(&x);
                }
            }
            Ty::List(e) | Ty::Box(e) | Ty::Mutex(e) | Ty::Chan(e) | Ty::Task(e) => {
                let e = (**e).clone();
                self.note_ty(&e);
                if matches!(t, Ty::Task(_) | Ty::Mutex(_) | Ty::Chan(_)) {
                    if self.mode == Mode::Wasm {
                        self.wasm_threads = true;
                    }
                    self.uses_threads = true;
                }
                if let Ty::Task(_) = t {
                    let f = Ty::Fn(vec![], Box::new(e.clone()));
                    self.note_ty(&f);
                }
                if let Ty::Mutex(_) = t {
                    let f = Ty::Fn(vec![e.clone()], Box::new(e.clone()));
                    self.note_ty(&f);
                }
                if !self.heap_tys.contains(t) {
                    self.heap_tys.push(t.clone());
                }
            }
            Ty::Map(k, v) => {
                let (k, v) = ((**k).clone(), (**v).clone());
                self.note_ty(&k);
                self.note_ty(&v);
                if !self.heap_tys.contains(t) {
                    self.heap_tys.push(t.clone());
                }
            }
            Ty::Fn(ps, r) => {
                for x in ps.clone() {
                    self.note_ty(&x);
                }
                let r = (**r).clone();
                self.note_ty(&r);
            }
            _ => return,
        }
        if !self.comps.contains(t) {
            self.comps.push(t.clone());
        }
    }

    pub fn ctype(&self, t: &Ty) -> String {
        match t {
            Ty::Int(i) => i.c().into(),
            Ty::Bool => "bool".into(),
            Ty::Str => "const char*".into(),
            Ty::Unit | Ty::Never => "void".into(),
            Ty::Enum(n) => format!("E_{}", mangle(n)),
            Ty::Record(n) => format!("R_{}", mangle(n)),
            Ty::Array(..) => format!("A_{}", mangle(&t.to_string())),
            Ty::Tuple(_) => format!("T_{}", mangle(&t.to_string())),
            Ty::String => "ei_String".into(),
            Ty::List(_) => format!("L_{}", mangle(&t.to_string())),
            Ty::Map(..) => format!("M_{}", mangle(&t.to_string())),
            Ty::Box(_) => format!("B_{}", mangle(&t.to_string())),
            Ty::Fn(..) => format!("F_{}", mangle(&t.to_string())),
            Ty::Task(_) => format!("TK_{}", mangle(&t.to_string())),
            Ty::Mutex(_) => format!("MX_{}", mangle(&t.to_string())),
            Ty::Chan(_) => format!("CH_{}", mangle(&t.to_string())),
        }
    }

    pub fn is_unit_enum(&self, k: &str) -> bool {
        !self.enum_defs[k].payload
    }

    pub fn head_of(&self, t: &Ty) -> String {
        match t {
            Ty::Enum(k) => self.enum_defs[k].template.clone(),
            Ty::Record(k) => self.rec_defs[k].template.clone(),
            Ty::Array(..) => "[]".into(),
            Ty::Tuple(_) | Ty::Unit => "()".into(),
            Ty::List(_) => "List".into(),
            Ty::Task(_) => "Task".into(),
            Ty::Mutex(_) => "Mutex".into(),
            Ty::Chan(_) => "Chan".into(),
            Ty::Map(..) => "Map".into(),
            Ty::Box(_) => "Box".into(),
            other => other.to_string(),
        }
    }

    pub fn tag_const(&self, k: &str, variant: &str) -> String {
        format!("E_{}_{}", mangle(k), variant)
    }

    // ------------------------------------------------------------ type resolution
    pub fn resolve_ty(&mut self, t: &TyAst) -> R<Ty> {
        match t {
            TyAst::Unit => Ok(Ty::Unit),
            TyAst::Tuple(ts) => {
                let mut v = vec![];
                for x in ts {
                    v.push(self.resolve_ty(x)?);
                }
                let t = Ty::Tuple(v);
                self.note_ty(&t);
                Ok(t)
            }
            TyAst::Array(e, n, p) => {
                if *n == 0 {
                    return err("E0111", *p, "array length must be at least 1");
                }
                let e = self.resolve_ty(e)?;
                let t = Ty::Array(Box::new(e), *n);
                self.note_ty(&t);
                Ok(t)
            }
            TyAst::Fn(ps, r, _) => {
                let mut v = vec![];
                for x in ps {
                    v.push(self.resolve_ty(x)?);
                }
                let r = match r {
                    Some(r) => self.resolve_ty(r)?,
                    None => Ty::Unit,
                };
                let t = Ty::Fn(v, Box::new(r));
                self.note_ty(&t);
                Ok(t)
            }
            TyAst::Generic(n, args, p) => {
                let mut v = vec![];
                for a in args {
                    v.push(self.resolve_ty(a)?);
                }
                let want = match n.as_str() {
                    "List" | "Box" | "Task" | "Mutex" | "Chan" => Some(1),
                    "Map" => Some(2),
                    _ => None,
                };
                if let Some(w) = want {
                    if v.len() != w {
                        return err("E0111", *p, format!("type `{}` takes {} type argument(s), but {} were given", n, w, v.len()));
                    }
                    if v.iter().any(|t| matches!(t, Ty::Unit | Ty::Never)) && n != "Task" {
                        return err("E0111", *p, format!("`{}` can't hold ()", n));
                    }
                    let t = match n.as_str() {
                        "List" => Ty::List(Box::new(v[0].clone())),
                        "Box" => Ty::Box(Box::new(v[0].clone())),
                        "Task" => Ty::Task(Box::new(v[0].clone())),
                        "Mutex" => Ty::Mutex(Box::new(v[0].clone())),
                        "Chan" => Ty::Chan(Box::new(v[0].clone())),
                        _ => {
                            self.check_map_key(&v[0], *p)?;
                            Ty::Map(Box::new(v[0].clone()), Box::new(v[1].clone()))
                        }
                    };
                    self.note_ty(&t);
                    return Ok(t);
                }
                self.inst_type(n, v, *p)
            }
            TyAst::Name(n, p) => {
                if let Some(t) = self.tsubst.get(n) {
                    return Ok(t.clone());
                }
                if let Some(i) = IntTy::from_name(n) {
                    return Ok(Ty::Int(i));
                }
                match n.as_str() {
                    "bool" => Ok(Ty::Bool),
                    "str" => Ok(Ty::Str),
                    "String" => Ok(Ty::String),
                    "List" | "Map" | "Box" | "Task" | "Mutex" | "Chan" => err("E0111", *p, format!("type `{}` needs type arguments: `{}[...]`", n, n)),
                    _ => match self.templates.get(n) {
                        Some(d) if d.generics.is_empty() => self.inst_type(n, vec![], *p),
                        Some(d) => err("E0111", *p, format!("type `{}` needs {} type argument(s): `{}[...]`", n, d.generics.len(), n)),
                        None => err("E0111", *p, format!("unknown type `{}`", n)),
                    },
                }
            }
        }
    }

    pub fn resolve_with(&mut self, t: &TyAst, subst: &HashMap<String, Ty>) -> R<Ty> {
        let saved = std::mem::replace(&mut self.tsubst, subst.clone());
        let r = self.resolve_ty(t);
        self.tsubst = saved;
        r
    }

    pub fn visible(&self, module: &str, public: bool) -> bool {
        public || module.is_empty() || self.cur_mod == "*" || module == self.cur_mod
    }

    pub fn inst_type(&mut self, name: &str, args: Vec<Ty>, pos: Pos) -> R<Ty> {
        let decl = match self.templates.get(name).cloned() {
            Some(d) => d,
            None => return err("E0111", pos, format!("unknown type `{}`", name)),
        };
        if !self.visible(&decl.module, decl.public) {
            return err("E0801", pos, format!("type `{}` is private to module `{}`", name, decl.module))
                .map_err(|d: Diag| d.help("mark it `pub` in its own file to use it from other modules"));
        }
        if args.len() != decl.generics.len() {
            return err("E0111", pos, format!("type `{}` takes {} type argument(s), but {} were given", name, decl.generics.len(), args.len()));
        }
        let key = if args.is_empty() {
            name.to_string()
        } else {
            format!("{}[{}]", name, args.iter().map(|a| a.to_string()).collect::<Vec<_>>().join(", "))
        };
        let is_enum = matches!(decl.kind, TypeKind::Enum(_));
        let ty = if is_enum { Ty::Enum(key.clone()) } else { Ty::Record(key.clone()) };
        if self.enum_defs.contains_key(&key) || self.rec_defs.contains_key(&key) {
            return Ok(ty);
        }
        let subst: HashMap<String, Ty> = decl.generics.iter().cloned().zip(args.iter().cloned()).collect();
        if is_enum {
            self.enum_defs.insert(key.clone(), EnumDef { template: name.to_string(), args: args.clone(), variants: vec![], payload: false });
        } else {
            self.rec_defs.insert(key.clone(), RecDef { template: name.to_string(), args: args.clone(), fields: vec![] });
        }
        let saved = std::mem::replace(&mut self.tsubst, subst);
        let saved_mod = std::mem::replace(&mut self.cur_mod, decl.module.clone());
        let r = self.fill_type(&decl, &key);
        self.cur_mod = saved_mod;
        self.tsubst = saved;
        r.map_err(|d| d.in_file(&decl.module))?;
        // by-value recursion would have infinite size
        let fields: Vec<Ty> = if is_enum {
            self.enum_defs[&key].variants.iter().flat_map(|v| v.fields.iter().map(|f| f.1.clone())).collect()
        } else {
            self.rec_defs[&key].fields.iter().map(|f| f.1.clone()).collect()
        };
        let mut seen = HashSet::new();
        if fields.iter().any(|ft| self.reaches(ft, &key, &mut seen)) {
            return err("E0108", decl.pos, format!("type `{}` contains itself and would have infinite size", key))
                .map_err(|d: Diag| d.help("use an index into a List, or Box[T], to express recursion"));
        }
        self.type_order.push(ty.clone());
        Ok(ty)
    }

    fn fill_type(&mut self, decl: &TypeDecl, key: &str) -> R<()> {
        match &decl.kind {
            TypeKind::Record(fs) => {
                if fs.is_empty() {
                    return err("E0111", decl.pos, "records need at least one field");
                }
                let mut fields: Vec<(String, Ty)> = vec![];
                for (n, ta, fp) in fs {
                    if fields.iter().any(|(m, _)| m == n) {
                        return err("E0107", *fp, format!("duplicate field `{}`", n));
                    }
                    let ty = self.resolve_ty(ta)?;
                    fields.push((n.clone(), ty));
                }
                self.rec_defs.get_mut(key).unwrap().fields = fields;
            }
            TypeKind::Enum(vs) => {
                let mut variants = vec![];
                for v in vs {
                    let mut fields: Vec<(String, Ty)> = vec![];
                    for (n, ta) in &v.fields {
                        if fields.iter().any(|(m, _)| m == n) {
                            return err("E0107", v.pos, format!("duplicate field `{}`", n));
                        }
                        fields.push((n.clone(), self.resolve_ty(ta)?));
                    }
                    variants.push(VariantDef { name: v.name.clone(), fields });
                }
                let payload = variants.iter().any(|v| !v.fields.is_empty());
                let d = self.enum_defs.get_mut(key).unwrap();
                d.variants = variants;
                d.payload = payload;
            }
        }
        Ok(())
    }

    pub fn reaches(&self, t: &Ty, target: &str, seen: &mut HashSet<String>) -> bool {
        match t {
            Ty::Enum(k) | Ty::Record(k) => {
                if k == target {
                    return true;
                }
                if !seen.insert(k.clone()) {
                    return false;
                }
                if let Some(d) = self.enum_defs.get(k) {
                    return d.variants.iter().any(|v| v.fields.iter().any(|f| self.reaches(&f.1, target, seen)));
                }
                if let Some(d) = self.rec_defs.get(k) {
                    return d.fields.iter().any(|f| self.reaches(&f.1, target, seen));
                }
                false
            }
            Ty::Array(e, _) => self.reaches(e, target, seen),
            Ty::Tuple(ts) => ts.iter().any(|x| self.reaches(x, target, seen)),
            _ => false,
        }
    }

    // ------------------------------------------------------------ generic inference
    pub fn ast_has_unbound(&self, ta: &TyAst, subst: &HashMap<String, Ty>, gs: &HashSet<String>) -> bool {
        match ta {
            TyAst::Name(n, _) => gs.contains(n) && !subst.contains_key(n),
            TyAst::Generic(_, args, _) => args.iter().any(|a| self.ast_has_unbound(a, subst, gs)),
            TyAst::Array(e, _, _) => self.ast_has_unbound(e, subst, gs),
            TyAst::Tuple(ts) => ts.iter().any(|a| self.ast_has_unbound(a, subst, gs)),
            TyAst::Fn(ps, r, _) => ps.iter().any(|a| self.ast_has_unbound(a, subst, gs)) || r.as_ref().map(|r| self.ast_has_unbound(r, subst, gs)).unwrap_or(false),
            TyAst::Unit => false,
        }
    }

    /// Bind generic names in `ta` by matching it against `actual`. False on conflict.
    pub fn unify_ast(&self, ta: &TyAst, actual: &Ty, subst: &mut HashMap<String, Ty>, gs: &HashSet<String>) -> bool {
        match ta {
            TyAst::Name(n, _) => {
                if gs.contains(n) {
                    match subst.get(n) {
                        Some(t) => t == actual,
                        None => {
                            subst.insert(n.clone(), actual.clone());
                            true
                        }
                    }
                } else {
                    true
                }
            }
            TyAst::Generic(n, args, _) if matches!(n.as_str(), "List" | "Map" | "Box" | "Task" | "Mutex" | "Chan") => {
                let parts: Vec<&Ty> = match actual {
                    Ty::List(e) if n == "List" => vec![&**e],
                    Ty::Box(e) if n == "Box" => vec![&**e],
                    Ty::Task(e) if n == "Task" => vec![&**e],
                    Ty::Mutex(e) if n == "Mutex" => vec![&**e],
                    Ty::Chan(e) if n == "Chan" => vec![&**e],
                    Ty::Map(k, v) if n == "Map" => vec![&**k, &**v],
                    _ => return false,
                };
                parts.len() == args.len() && args.iter().zip(parts.into_iter()).all(|(a, t)| self.unify_ast(a, t, subst, gs))
            }
            TyAst::Generic(n, args, _) => {
                let (tmpl, targs) = match actual {
                    Ty::Enum(k) => (&self.enum_defs[k].template, &self.enum_defs[k].args),
                    Ty::Record(k) => (&self.rec_defs[k].template, &self.rec_defs[k].args),
                    _ => return false,
                };
                tmpl == n && targs.len() == args.len() && args.iter().zip(targs.iter()).all(|(a, t)| self.unify_ast(a, t, subst, gs))
            }
            TyAst::Array(e, n, _) => match actual {
                Ty::Array(ae, an) => an == n && self.unify_ast(e, ae, subst, gs),
                _ => false,
            },
            TyAst::Tuple(ts) => match actual {
                Ty::Tuple(a) => a.len() == ts.len() && ts.iter().zip(a.iter()).all(|(x, y)| self.unify_ast(x, y, subst, gs)),
                _ => false,
            },
            TyAst::Fn(ps, r, _) => match actual {
                Ty::Fn(aps, ar) => {
                    aps.len() == ps.len()
                        && ps.iter().zip(aps.iter()).all(|(x, y)| self.unify_ast(x, y, subst, gs))
                        && match r {
                            Some(r) => self.unify_ast(r, ar, subst, gs),
                            None => **ar == Ty::Unit,
                        }
                }
                _ => false,
            },
            TyAst::Unit => *actual == Ty::Unit,
        }
    }

    pub fn implements(&self, trait_: &str, ty: &Ty) -> bool {
        match self.trait_impls.get(trait_) {
            Some(list) => list.iter().any(|(gens, target)| {
                let gs: HashSet<String> = gens.iter().map(|g| g.name.clone()).collect();
                let mut s = HashMap::new();
                self.unify_ast(target, ty, &mut s, &gs)
            }),
            None => false,
        }
    }

    // ------------------------------------------------------------ instances
    pub fn instantiate(&mut self, decl: &Rc<FnDecl>, subst: &HashMap<String, Ty>, cname: &str) -> R<Sig> {
        if let Some(s) = self.instances.get(cname) {
            return Ok(s.clone());
        }
        let saved = std::mem::replace(&mut self.tsubst, subst.clone());
        let saved_mod = std::mem::replace(&mut self.cur_mod, decl.module.clone());
        let r = (|| -> R<Sig> {
            let mut params = vec![];
            for p in &decl.params {
                let ty = self.resolve_ty(&p.ty)?;
                if ty == Ty::Unit {
                    return err("E0111", p.pos, "parameters can't have type ()");
                }
                params.push((p.name.clone(), p.inout, ty));
            }
            let ret = match &decl.ret {
                Some(t) => self.resolve_ty(t)?,
                None => Ty::Unit,
            };
            let mut caps = vec![];
            for (c, cp) in &decl.caps {
                if !KNOWN_CAPS.contains(&c.as_str()) {
                    return err("E0203", *cp, format!("unknown capability `{}`", c)).map_err(|d: Diag| d.help(format!("known capabilities: {}", KNOWN_CAPS.join(", "))));
                }
                caps.push(c.clone());
            }
            Ok(Sig { params, ret, caps })
        })();
        self.tsubst = saved;
        self.cur_mod = saved_mod;
        let sig = r.map_err(|d| d.in_file(&decl.module))?;
        if decl.is_extern || decl.is_export {
            self.check_ffi_sig(decl, &sig).map_err(|d| d.in_file(&decl.module))?;
        }
        let cparams: Vec<String> = sig
            .params
            .iter()
            .map(|(n, inout, ty)| if *inout { format!("{}* v_{}", self.ctype(ty), n) } else { format!("{} v_{}", self.ctype(ty), n) })
            .collect();
        if decl.is_extern {
            // declared under our own name and bound to the C symbol with an asm label, so we
            // never clash with (or depend on) the user's C headers
            self.protos.push(format!(
                "extern {} {}({}) __asm__(\"{}\");",
                self.ctype(&sig.ret),
                cname,
                if cparams.is_empty() { "void".to_string() } else { cparams.join(", ") },
                decl.name
            ));
        } else {
            self.protos.push(format!(
                "static {} {}({});",
                self.ctype(&sig.ret),
                cname,
                if cparams.is_empty() { "void".to_string() } else { cparams.join(", ") }
            ));
        }
        self.instances.insert(cname.to_string(), sig.clone());
        if decl.body.is_some() {
            self.pending.push(Pending { decl: decl.clone(), subst: subst.clone(), cname: cname.to_string(), sig: sig.clone() });
        }
        Ok(sig)
    }

    pub fn cap_error(&self, pos: Pos, what: &str, cap: &str) -> Diag {
        let d = Diag::new("E0201", pos, format!("call to `{}` requires capability `{}`", what, cap));
        if self.caps.is_empty() {
            d.fix(self.sig_end, 0, format!(" uses {}", cap))
        } else {
            d.fix(self.sig_end, 0, format!(", {}", cap))
        }
    }

    // ------------------------------------------------------------ program
    fn run(&mut self, items: &[Item]) -> R<(String, String)> {
        let r = self.run_inner(items);
        r.map_err(|d| d.in_file(&self.err_mod))
    }

    fn run_inner(&mut self, items: &[Item]) -> R<(String, String)> {
        // 1. type templates
        for it in items {
            if let Item::Type(t) = it {
                self.err_mod = t.module.clone();
                if self.templates.contains_key(&t.name) || IntTy::from_name(&t.name).is_some() || ["bool", "str", "Self", "String", "List", "Map", "Box", "Task", "Mutex", "Chan"].contains(&t.name.as_str()) {
                    return err("E0107", t.pos, format!("`{}` is already defined", t.name)).map_err(|d: Diag| d.in_file(&t.module));
                }
                if let TypeKind::Enum(vs) = &t.kind {
                    let mut seen: Vec<&String> = vec![];
                    for v in vs {
                        if seen.contains(&&v.name) || self.variants_by_name.contains_key(&v.name) {
                            return err("E0107", v.pos, format!("variant `{}` is already defined (variant names must be unique)", v.name));
                        }
                        seen.push(&v.name);
                        self.variants_by_name.insert(v.name.clone(), t.name.clone());
                    }
                }
                self.templates.insert(t.name.clone(), Rc::new(t.clone()));
            }
        }
        // 2. non-generic types
        for it in items {
            if let Item::Type(t) = it {
                self.err_mod = t.module.clone();
                if t.generics.is_empty() {
                    self.inst_type(&t.name, vec![], t.pos)?;
                }
            }
        }
        // 3. traits
        for it in items {
            if let Item::Trait(t) = it {
                self.err_mod = t.module.clone();
                if self.traits.contains_key(&t.name) || self.templates.contains_key(&t.name) {
                    return err("E0107", t.pos, format!("`{}` is already defined", t.name));
                }
                self.traits.insert(t.name.clone(), Rc::new(t.clone()));
            }
        }
        // 4. free functions
        for it in items {
            if let Item::Fn(f) = it {
                self.err_mod = f.module.clone();
                if self.fns.contains_key(&f.name) || self.templates.contains_key(&f.name) || self.variants_by_name.contains_key(&f.name) || BUILTIN_FNS.contains(&f.name.as_str()) {
                    return err("E0107", f.pos, format!("`{}` is already defined", f.name)).map_err(|d: Diag| d.in_file(&f.module));
                }
                if f.is_export && !f.generics.is_empty() {
                    return err("E0805", f.pos, "an `export fn` can't be generic").map_err(|d: Diag| d.in_file(&f.module).help("exported functions need a fixed C signature; export a concrete wrapper"));
                }
                if f.name == "main" && (!f.params.is_empty() || f.ret.is_some() || !f.generics.is_empty()) {
                    return err("E0111", f.pos, "`main` takes no parameters and returns ()");
                }
                for g in &f.generics {
                    if let Some(b) = g.bounds.iter().find(|b| !self.traits.contains_key(*b)) {
                        return err("E0603", g.pos, format!("unknown trait `{}`", b));
                    }
                }
                self.fns.insert(f.name.clone(), Rc::new(f.clone()));
            }
        }
        // 5. impls
        let mut concrete_methods: Vec<(Rc<FnDecl>, TyAst)> = vec![];
        for it in items {
            if let Item::Impl(im) = it {
                self.err_mod = im.module.clone();
                self.register_impl(im, &mut concrete_methods)?;
            }
        }
        // 6. constants
        for it in items {
            if let Item::Const(c) = it {
                self.err_mod = c.module.clone();
                self.cur_mod = c.module.clone();
                self.scopes = vec![HashMap::new()];
                if self.consts.contains_key(&c.name) || self.fns.contains_key(&c.name) {
                    return err("E0107", c.pos, format!("`{}` is already defined", c.name));
                }
                let ty = self.resolve_ty(&c.ty)?;
                if self.owns(&ty) {
                    return err("E0504", c.value.pos, "constants can't own heap memory; build the value in a function instead");
                }
                let v = self.expr(&c.value, Some(&ty))?;
                if v.ty != ty {
                    return Err(mismatch(c.value.pos, &ty, &v.ty));
                }
                let def = match (&ty, v.k, &c.value.k) {
                    (Ty::Int(t), Some(k), _) => format!("static const {} c_{} = {};", t.c(), c.name, lit_c(*t, k)),
                    (Ty::Bool, _, EK::Bool(b)) => format!("static const bool c_{} = {};", c.name, b),
                    (Ty::Str, _, EK::Str(s)) => format!("static const char* const c_{} = {};", c.name, cstr(s)),
                    _ => return err("E0504", c.value.pos, "constant initializers must be literals or compile-time integer expressions"),
                };
                self.const_defs.push(def);
                self.consts.insert(c.name.clone(), (ty, v.k));
                self.const_vis.insert(c.name.clone(), (c.module.clone(), c.public));
            }
        }
        self.cur_mod = "*".to_string();
        // 7. bodies: all concrete fns and methods, then everything they instantiate
        let free: Vec<Rc<FnDecl>> = items
            .iter()
            .filter_map(|it| if let Item::Fn(f) = it { Some(self.fns[&f.name].clone()) } else { None })
            .collect();
        for f in free {
            if f.generics.is_empty() {
                self.err_mod = f.module.clone();
                let cname = format!("f_{}", f.name);
                self.instantiate(&f, &HashMap::new(), &cname)?;
                if f.is_export {
                    let sig = self.instances[&cname].clone();
                    self.exports.push((f.name.clone(), sig));
                }
            }
        }
        for (decl, target) in concrete_methods {
            self.err_mod = decl.module.clone();
            self.cur_mod = decl.module.clone();
            let self_ty = self.resolve_ty(&target)?;
            self.cur_mod = "*".to_string();
            let mut subst = HashMap::new();
            subst.insert("Self".to_string(), self_ty.clone());
            let cname = format!("m_{}_{}", mangle(&self_ty.to_string()), decl.name);
            self.instantiate(&decl, &subst, &cname)?;
        }
        let mut test_n = 0;
        for it in items {
            if let Item::Test(t) = it {
                test_n += 1;
                self.compile_test(t, test_n)?;
            }
        }
        while let Some(p) = self.pending.pop() {
            self.compile_fn(&p)?;
        }
        self.err_mod = String::new();
        if self.mode == Mode::Build && !self.fns.contains_key("main") {
            return err("E0112", Pos { line: 1, col: 1 }, "no `main` function");
        }
        if matches!(self.mode, Mode::Lib | Mode::Wasm) && self.exports.is_empty() {
            return err("E0805", Pos { line: 1, col: 1 }, "a library needs at least one `export fn`");
        }
        if self.wasm_threads {
            return err("E0806", Pos { line: 1, col: 1 }, "threads (`spawn`, `Task`, `Mutex`, `Chan`) aren't available when targeting WebAssembly");
        }
        let c = self.assemble();
        let h = self.header();
        Ok((c, h))
    }

    fn register_impl(&mut self, im: &ImplDecl, concrete: &mut Vec<(Rc<FnDecl>, TyAst)>) -> R<()> {
        let head = head_of_ast(&im.target);
        let mut names: Vec<&String> = vec![];
        for m in &im.methods {
            if names.contains(&&m.name) {
                return err("E0107", m.pos, format!("method `{}` is defined twice in this impl", m.name));
            }
            names.push(&m.name);
        }
        if let Some((tn, tp)) = &im.trait_ {
            let tr = match self.traits.get(tn).cloned() {
                Some(t) => t,
                None => return err("E0603", *tp, format!("unknown trait `{}`", tn)),
            };
            for tm in &tr.methods {
                match im.methods.iter().find(|m| m.name == tm.name) {
                    None => return err("E0602", im.pos, format!("impl of `{}` is missing method `{}`", tn, tm.name)),
                    Some(m) => {
                        let norm = |t: &Option<TyAst>, target: &TyAst| -> String {
                            match t {
                                None => "()".to_string(),
                                Some(t) => show_ast(t).replace("Self", &show_ast(target)),
                            }
                        };
                        let sig_differs = norm(&m.ret, &im.target) != norm(&tm.ret, &im.target)
                            || m.params.iter().zip(tm.params.iter()).skip(1).any(|(a, b)| show_ast(&a.ty).replace("Self", &show_ast(&im.target)) != show_ast(&b.ty).replace("Self", &show_ast(&im.target)));
                        if sig_differs || m.params.len() != tm.params.len() || m.params.iter().zip(tm.params.iter()).any(|(a, b)| a.inout != b.inout) {
                            return err("E0602", m.pos, format!("method `{}` doesn't match the signature in trait `{}`", m.name, tn));
                        }
                    }
                }
            }
            for m in &im.methods {
                if !tr.methods.iter().any(|tm| tm.name == m.name) {
                    return err("E0602", m.pos, format!("trait `{}` has no method `{}`", tn, m.name));
                }
            }
            let dup = self.trait_impls.get(tn).map(|l| l.iter().any(|(_, t)| show_ast(t) == show_ast(&im.target))).unwrap_or(false);
            if dup {
                return err("E0107", im.pos, format!("`{}` is already implemented for `{}`", tn, show_ast(&im.target)));
            }
            self.trait_impls.entry(tn.clone()).or_default().push((im.generics.clone(), im.target.clone()));
        }
        for m in &im.methods {
            let existing = self.methods.get(&head).map(|l| l.iter().any(|x| x.decl.name == m.name && show_ast(&x.target) == show_ast(&im.target))).unwrap_or(false);
            if existing {
                return err("E0107", m.pos, format!("method `{}` is already defined for `{}`", m.name, show_ast(&im.target)));
            }
            let decl = Rc::new(m.clone());
            if im.generics.is_empty() && m.generics.is_empty() && m.body.is_some() {
                concrete.push((decl.clone(), im.target.clone()));
            }
            self.methods.entry(head.clone()).or_default().push(MethodInfo {
                decl,
                impl_generics: im.generics.clone(),
                target: im.target.clone(),
                trait_: im.trait_.as_ref().map(|t| t.0.clone()),
            });
        }
        Ok(())
    }

    // ------------------------------------------------------------ type definitions in C
    pub fn def_ty(&self, t: &Ty, done: &mut HashSet<String>, s: &mut String) {
        match t {
            Ty::Enum(k) => {
                let key = self.ctype(t);
                if !done.insert(key.clone()) {
                    return;
                }
                let d = &self.enum_defs[k];
                for v in &d.variants {
                    for (_, ft) in &v.fields {
                        self.def_ty(ft, done, s);
                    }
                }
                let tags: Vec<String> = d.variants.iter().map(|v| self.tag_const(k, &v.name)).collect();
                if !d.payload {
                    s.push_str(&format!("typedef enum {{ {} }} {};\n", tags.join(", "), key));
                    let names: Vec<String> = d.variants.iter().map(|v| cstr(&v.name)).collect();
                    s.push_str(&format!("static const char* const {}_names[] = {{ {} }};\n", key, names.join(", ")));
                } else {
                    s.push_str(&format!("enum {{ {} }};\n", tags.join(", ")));
                    let mut members = String::new();
                    for v in &d.variants {
                        if !v.fields.is_empty() {
                            let fs: Vec<String> = v.fields.iter().map(|(n, ft)| format!("{} f_{};", self.ctype(ft), n)).collect();
                            members.push_str(&format!("struct {{ {} }} m_{}; ", fs.join(" "), v.name));
                        }
                    }
                    s.push_str(&format!("struct {} {{ int tag; union {{ {}}} u; }};\n", key, members));
                }
            }
            Ty::Record(k) => {
                let key = self.ctype(t);
                if !done.insert(key.clone()) {
                    return;
                }
                for (_, ft) in &self.rec_defs[k].fields {
                    self.def_ty(ft, done, s);
                }
                let fields: Vec<String> = self.rec_defs[k].fields.iter().map(|(n, ft)| format!("{} f_{};", self.ctype(ft), n)).collect();
                s.push_str(&format!("struct {} {{ {} }};\n", key, fields.join(" ")));
            }
            Ty::Tuple(ts) => {
                let key = self.ctype(t);
                if !done.insert(key.clone()) {
                    return;
                }
                for ft in ts {
                    self.def_ty(ft, done, s);
                }
                let fields: Vec<String> = ts.iter().enumerate().map(|(i, ft)| format!("{} f_{};", self.ctype(ft), i)).collect();
                s.push_str(&format!("typedef struct {{ {} }} {};\n", fields.join(" "), key));
            }
            Ty::List(e) | Ty::Box(e) => {
                let key = self.ctype(t);
                if !done.insert(key.clone()) {
                    return;
                }
                self.def_elem(e, done, s);
                let et = self.ctype(e);
                if matches!(t, Ty::List(_)) {
                    s.push_str(&format!("typedef struct {{ {}* d; uint64_t len, cap; }} {};\n", et, key));
                } else {
                    s.push_str(&format!("typedef struct {{ {}* p; }} {};\n", et, key));
                }
            }
            Ty::Task(e) | Ty::Mutex(e) | Ty::Chan(e) => {
                let key = self.ctype(t);
                if !done.insert(key.clone()) {
                    return;
                }
                self.def_elem(e, done, s);
                s.push_str(&format!("typedef struct {k}c {k}c;\ntypedef struct {{ {k}c* p; }} {k};\n", k = key));
            }
            Ty::Fn(ps, r) => {
                let key = self.ctype(t);
                if !done.insert(key.clone()) {
                    return;
                }
                for p in ps {
                    self.def_elem(p, done, s);
                }
                self.def_elem(r, done, s);
                let mut args = vec!["void*".to_string()];
                args.extend(ps.iter().map(|p| self.ctype(p)));
                s.push_str(&format!("typedef struct {{ void* env; {} (*call)({}); void (*drop)(void*); void* (*clone)(void*); }} {};\n", self.ctype(r), args.join(", "), key));
            }
            Ty::Map(k, v) => {
                let key = self.ctype(t);
                if !done.insert(key.clone()) {
                    return;
                }
                self.def_elem(k, done, s);
                self.def_elem(v, done, s);
                s.push_str(&format!("typedef struct {{ {}* k; {}* v; uint8_t* s; uint64_t len, cap, used; }} {};\n", self.ctype(k), self.ctype(v), key));
            }
            Ty::Array(e, n) => {
                let key = self.ctype(t);
                if !done.insert(key.clone()) {
                    return;
                }
                self.def_ty(e, done, s);
                let et = self.ctype(e);
                s.push_str(&format!("typedef struct {{ {} d[{}]; }} {};\n", et, n, key));
                s.push_str(&format!(
                    "static {key} {key}_fill({et} v) {{ {key} a; for (uint64_t i = 0; i < {n}; i++) a.d[i] = v; return a; }}\n",
                    key = key,
                    et = et,
                    n = n
                ));
            }
            _ => {}
        }
    }

    /// Element of a pointer-based container: named structs only need a forward declaration.
    fn def_elem(&self, e: &Ty, done: &mut HashSet<String>, s: &mut String) {
        match e {
            Ty::Record(_) => {}
            Ty::Enum(k) if !self.is_unit_enum(k) => {}
            _ => self.def_ty(e, done, s),
        }
    }

    /// Structural equality expression; composite types get a generated function.
    pub fn eq_expr(&mut self, ty: &Ty, a: &str, b: &str) -> String {
        match ty {
            Ty::Int(_) | Ty::Bool => format!("({} == {})", a, b),
            Ty::String => format!("(strcmp({}.p, {}.p) == 0)", wrap(a), wrap(b)),
            Ty::Enum(k) if self.is_unit_enum(k) => format!("({} == {})", a, b),
            Ty::Str => format!("(strcmp({}, {}) == 0)", a, b),
            _ => {
                let f = format!("ei_eq_{}", mangle(&ty.to_string()));
                if self.eq_seen.insert(f.clone()) {
                    self.eq_needed.push(ty.clone());
                }
                format!("{}({}, {})", f, a, b)
            }
        }
    }

    fn assemble(&mut self) -> String {
        let mut s = prelude();
        s.push('\n');
        if self.uses_threads {
            s.push_str(crate::prelude::THREADS_HEAD);
        }
        let mut done = HashSet::new();
        let mut defs = String::new();
        for t in self.type_order.clone() {
            match &t {
                Ty::Record(_) => defs.push_str(&format!("typedef struct {k} {k};\n", k = self.ctype(&t))),
                Ty::Enum(k) if !self.is_unit_enum(k) => defs.push_str(&format!("typedef struct {k} {k};\n", k = self.ctype(&t))),
                _ => {}
            }
        }
        for t in self.type_order.clone() {
            self.def_ty(&t, &mut done, &mut defs);
        }
        for t in self.comps.clone() {
            self.def_ty(&t, &mut done, &mut defs);
        }
        s.push_str(&defs);
        s.push_str(&self.lifted_types);
        for c in &self.const_defs {
            s.push_str(c);
            s.push('\n');
        }
        for p in &self.protos {
            s.push_str(p);
            s.push('\n');
        }
        self.gen_aux();
        s.push_str(&self.aux_protos);
        s.push_str(&self.aux_bodies);
        s.push('\n');
        for l in &self.out {
            s.push_str(l);
            s.push('\n');
        }
        for l in &self.lifted {
            s.push_str(l);
            s.push('\n');
        }
        s.push('\n');
        match self.mode {
            Mode::Build => s.push_str("int main(void) {\n  ei_file = \"program\";\n  f_main();\n  return 0;\n}\n"),
            Mode::Lib | Mode::Wasm => {
                for (name, sig) in self.exports.clone() {
                    let params: Vec<String> = sig.params.iter().map(|(n, _, t)| format!("{} v_{}", self.ctype(t), n)).collect();
                    let args: Vec<String> = sig.params.iter().map(|(n, _, _)| format!("v_{}", n)).collect();
                    let call = format!("f_{}({})", name, args.join(", "));
                    let body = if sig.ret == Ty::Unit { format!("{};", call) } else { format!("return {};", call) };
                    let attr = if self.mode == Mode::Wasm { format!("__attribute__((export_name(\"eider_{}\"))) ", name) } else { String::new() };
                    s.push_str(&format!(
                        "{}{} eider_{}({}) {{ ei_file = \"lib\"; {} }}\n",
                        attr,
                        self.ctype(&sig.ret),
                        name,
                        if params.is_empty() { "void".to_string() } else { params.join(", ") },
                        body
                    ));
                }
            }
            Mode::Test => {
                s.push_str("int main(void) {\n  int total = 0, failed = 0;\n  jmp_buf jb;\n  ei_jb = &jb;\n");
                for (name, f) in &self.tests {
                    s.push_str(&format!(
                        "  total++; printf(\"test %s ... \", {}); fflush(stdout);\n  if (setjmp(jb) == 0) {{ {}(); printf(\"ok\\n\"); }} else {{ failed++; }}\n",
                        cstr(name),
                        f
                    ));
                }
                s.push_str("  printf(\"\\n%d tests, %d failed\\n\", total, failed);\n  return failed ? 1 : 0;\n}\n");
            }
        }
        s
    }

    // ------------------------------------------------------------ function bodies
    fn compile_fn(&mut self, p: &Pending) -> R<()> {
        let f = &p.decl;
        let sig = &p.sig;
        self.tsubst = p.subst.clone();
        self.cur_mod = f.module.clone();
        self.err_mod = f.module.clone();
        self.unsafe_depth = if f.is_unsafe { 1 } else { 0 };
        self.ret = sig.ret.clone();
        self.caps = sig.caps.clone();
        self.sig_end = f.sig_end;
        self.loops = 0;
        self.loop_bases.clear();
        self.frames = vec![vec![]];
        self.scopes = vec![HashMap::new()];
        let mut cparams = vec![];
        for (pp, (name, inout, ty)) in f.params.iter().zip(sig.params.iter()) {
            let cname = format!("v_{}", name);
            self.declare(name, pp.pos, Var { ty: ty.clone(), mutable: false, inout: *inout, cname: cname.clone(), decl: None })?;
            let ct = self.ctype(ty);
            cparams.push(if *inout { format!("{}* {}", ct, cname) } else { format!("{} {}", ct, cname) });
        }
        let head = format!(
            "static {} {}({})",
            self.ctype(&sig.ret),
            p.cname,
            if cparams.is_empty() { "void".to_string() } else { cparams.join(", ") }
        );
        self.emit(format!("{} {{", head));
        self.ind += 1;
        let dest = if sig.ret == Ty::Unit { Dest::Discard } else { Dest::Return };
        let exp = sig.ret.clone();
        let body = f.body.as_ref().unwrap();
        let t = self.block_body(body, &dest, Some(&exp))?;
        if sig.ret != Ty::Unit && t != Ty::Never && t != sig.ret {
            return Err(Diag::new(
                "E0401",
                body.end,
                format!("function `{}` must return {}, but its body ends without producing one", f.name, sig.ret),
            )
            .help("add a `return` or end the body with an expression of that type"));
        }
        if sig.ret != Ty::Unit {
            self.emit("ei_unreachable();"); // the checker proved every path returns; silences -O0 warnings
        }
        self.ind -= 1;
        self.emit("}");
        self.emit("");
        self.tsubst.clear();
        Ok(())
    }

    fn compile_test(&mut self, t: &TestDecl, n: usize) -> R<()> {
        self.tsubst.clear();
        self.cur_mod = "*".to_string();
        self.unsafe_depth = 0;
        self.ret = Ty::Unit;
        self.caps = KNOWN_CAPS.iter().map(|s| s.to_string()).collect();
        self.sig_end = t.pos;
        self.loops = 0;
        self.loop_bases.clear();
        self.frames = vec![vec![]];
        self.scopes = vec![HashMap::new()];
        let fname = format!("t_{}", n);
        self.protos.push(format!("static void {}(void);", fname));
        self.emit(format!("static void {}(void) {{", fname));
        self.ind += 1;
        self.block_body(&t.body, &Dest::Discard, None)?;
        self.ind -= 1;
        self.emit("}");
        self.emit("");
        self.tests.push((t.name.clone(), fname));
        Ok(())
    }
}
