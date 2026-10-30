use crate::ast::*;
use crate::diag::{Diag, Pos};
use crate::lexer::{Token, T};

type R<X> = Result<X, Diag>;

const KW: &[&str] = &[
    "fn", "type", "let", "var", "if", "else", "while", "for", "in", "return", "match", "true", "false", "uses", "test",
    "assert", "inout", "as", "const", "module", "break", "continue", "null", "import", "trait", "impl", "pub", "comptime", "extern",
    "export", "unsafe",
];

pub struct Parser {
    toks: Vec<Token>,
    i: usize,
    /// import alias -> module prefix (for `alias.Name` references)
    aliases: std::collections::HashMap<String, String>,
}

impl Parser {
    pub fn new(toks: Vec<Token>) -> Parser {
        Parser { toks, i: 0, aliases: Default::default() }
    }

    // ---- token helpers ----
    fn t(&self) -> &T {
        &self.toks[self.i].t
    }
    fn pos(&self) -> Pos {
        self.toks[self.i].pos
    }
    fn prev_end(&self) -> Pos {
        self.toks[self.i.saturating_sub(1)].end
    }
    fn adv(&mut self) {
        if self.i + 1 < self.toks.len() {
            self.i += 1;
        }
    }
    fn err<X>(&self, msg: impl Into<String>) -> R<X> {
        Err(Diag::new("E0001", self.pos(), msg))
    }
    fn skip_nl(&mut self) {
        while matches!(self.t(), T::Nl) {
            self.adv();
        }
    }
    fn skip_seps(&mut self) {
        while matches!(self.t(), T::Nl) || self.is_sym(";") {
            self.adv();
        }
    }
    fn peek_nonnl(&self) -> &T {
        let mut j = self.i;
        while matches!(self.toks[j].t, T::Nl) && j + 1 < self.toks.len() {
            j += 1;
        }
        &self.toks[j].t
    }
    fn is_sym(&self, s: &str) -> bool {
        matches!(self.t(), T::Sym(x) if *x == s)
    }
    fn eat_sym(&mut self, s: &str) -> bool {
        if self.is_sym(s) {
            self.adv();
            true
        } else {
            false
        }
    }
    fn expect_sym(&mut self, s: &str) -> R<Pos> {
        let p = self.pos();
        if self.eat_sym(s) {
            Ok(p)
        } else {
            self.err(format!("expected `{}`", s))
        }
    }
    fn is_kw(&self, s: &str) -> bool {
        matches!(self.t(), T::Id(x) if x == s)
    }
    fn eat_kw(&mut self, s: &str) -> bool {
        if self.is_kw(s) {
            self.adv();
            true
        } else {
            false
        }
    }
    fn expect_kw(&mut self, s: &str) -> R<Pos> {
        let p = self.pos();
        if self.eat_kw(s) {
            Ok(p)
        } else {
            self.err(format!("expected `{}`", s))
        }
    }
    /// After consuming `first`: if it is an import alias followed by `. Name`, consume both and
    /// return the module-qualified (mangled) name.
    fn qualified(&mut self, first: &str) -> Option<String> {
        let prefix = self.aliases.get(first)?.clone();
        if !self.is_sym(".") {
            return None;
        }
        match self.toks.get(self.i + 1).map(|t| &t.t) {
            Some(T::Id(n)) if !KW.contains(&n.as_str()) => {
                let n = n.clone();
                self.adv();
                self.adv();
                Some(format!("{}__{}", prefix, n))
            }
            _ => None,
        }
    }

    fn ident(&mut self) -> R<(String, Pos)> {
        let p = self.pos();
        match self.t().clone() {
            T::Id(s) if !KW.contains(&s.as_str()) => {
                self.adv();
                Ok((s, p))
            }
            T::Id(s) => self.err(format!("`{}` is a keyword and can't be used as a name", s)),
            _ => self.err("expected a name"),
        }
    }

    // ---- items ----
    pub fn program(&mut self) -> R<Vec<Item>> {
        let mut items = vec![];
        self.skip_seps();
        while !matches!(self.t(), T::Eof) {
            if self.is_kw("module") {
                self.adv();
                self.ident()?;
                while self.eat_sym(".") {
                    self.ident()?;
                }
                self.skip_seps();
                continue;
            }
            if self.is_kw("import") {
                let p = self.pos();
                self.adv();
                match self.t().clone() {
                    T::Str(path) => {
                        self.adv();
                        let prefix = crate::ns::prefix_of(&path);
                        let alias = if self.eat_kw("as") { self.ident()?.0 } else { prefix.clone() };
                        self.aliases.insert(alias.clone(), prefix);
                        items.push(Item::Import(path, p, alias));
                    }
                    _ => return self.err("expected a file path string after `import`, e.g. `import \"util.ei\"`"),
                }
                self.skip_seps();
                continue;
            }
            let mut public = self.eat_kw("pub");
            if self.is_kw("type") {
                let mut d = self.type_decl()?;
                d.public = public;
                items.push(Item::Type(d));
            } else if self.is_kw("extern") {
                self.adv();
                match self.t().clone() {
                    T::Str(abi) if abi == "c" => self.adv(),
                    _ => return self.err("expected the ABI string: `extern \"c\" fn ...`"),
                }
                let mut f = self.fn_decl(true)?;
                if f.body.is_some() {
                    return Err(Diag::new("E0001", f.pos, "an `extern \"c\"` function is only declared here; it has no body"));
                }
                f.is_extern = true;
                f.is_unsafe = true;
                f.public = public;
                items.push(Item::Fn(f));
            } else if self.is_kw("export") {
                self.adv();
                let mut f = self.fn_decl(false)?;
                f.is_export = true;
                f.public = true;
                items.push(Item::Fn(f));
            } else if self.is_kw("unsafe") {
                self.adv();
                let mut f = self.fn_decl(false)?;
                f.is_unsafe = true;
                f.public = public;
                items.push(Item::Fn(f));
            } else if self.is_kw("fn") {
                let mut f = self.fn_decl(false)?;
                f.public = public;
                items.push(Item::Fn(f));
            } else if self.is_kw("const") {
                let mut c = self.const_decl()?;
                c.public = public;
                items.push(Item::Const(c));
            } else if self.is_kw("test") {
                if public {
                    return self.err("`pub` doesn't apply to tests");
                }
                items.push(Item::Test(self.test_decl()?));
            } else if self.is_kw("trait") {
                let mut t = self.trait_decl()?;
                t.public = public;
                items.push(Item::Trait(t));
            } else if self.is_kw("impl") {
                if public {
                    return self.err("`pub` doesn't apply to `impl`; methods follow the visibility of their type");
                }
                items.push(Item::Impl(self.impl_decl()?));
            } else {
                public = false;
                let _ = public;
                return self.err("expected `fn`, `type`, `const`, `trait`, `impl`, `import` or `test`");
            }
            self.skip_seps();
        }
        Ok(items)
    }

    fn generics(&mut self) -> R<Vec<GenericParam>> {
        let mut gs = vec![];
        if !self.eat_sym("[") {
            return Ok(gs);
        }
        loop {
            self.skip_nl();
            let (name, pos) = self.ident()?;
            let mut bounds = vec![];
            if self.eat_sym(":") {
                loop {
                    let b = self.ident()?.0;
                    bounds.push(self.qualified(&b).unwrap_or(b));
                    if !self.eat_sym("+") {
                        break;
                    }
                }
            }
            gs.push(GenericParam { name, bounds, pos });
            self.skip_nl();
            if self.eat_sym("]") {
                return Ok(gs);
            }
            self.expect_sym(",")?;
        }
    }

    fn type_decl(&mut self) -> R<TypeDecl> {
        self.expect_kw("type")?;
        let (name, pos) = self.ident()?;
        let gps = self.generics()?;
        if let Some(g) = gps.iter().find(|g| !g.bounds.is_empty()) {
            return Err(Diag::new("E0001", g.pos, "type parameters can't have bounds on a type declaration; put them on impls and functions"));
        }
        let generics = gps.into_iter().map(|g| g.name).collect();
        self.expect_sym("=")?;
        self.skip_nl();
        if self.is_sym("{") {
            self.adv();
            let mut fields = vec![];
            loop {
                self.skip_nl();
                if self.eat_sym("}") {
                    break;
                }
                let (f, fp) = self.ident()?;
                self.expect_sym(":")?;
                let t = self.ty()?;
                fields.push((f, t, fp));
                self.skip_nl();
                if !self.eat_sym(",") && !self.is_sym("}") && !matches!(self.t(), T::Nl) {
                    return self.err("expected `,` or `}`");
                }
            }
            Ok(TypeDecl { name, public: false, module: String::new(), pos, generics, kind: TypeKind::Record(fields) })
        } else {
            let mut vs = vec![];
            loop {
                self.expect_sym("|")?;
                self.skip_nl();
                let (vname, vpos) = self.ident()?;
                let mut fields = vec![];
                if self.eat_sym("(") {
                    loop {
                        self.skip_nl();
                        if self.eat_sym(")") {
                            break;
                        }
                        let named = matches!(self.t(), T::Id(_)) && matches!(self.toks[self.i + 1].t, T::Sym(":"));
                        if named {
                            let (f, _) = self.ident()?;
                            self.expect_sym(":")?;
                            fields.push((f, self.ty()?));
                        } else {
                            let t = self.ty()?;
                            fields.push((fields.len().to_string(), t));
                        }
                        self.skip_nl();
                        if !self.eat_sym(",") && !self.is_sym(")") {
                            return self.err("expected `,` or `)`");
                        }
                    }
                }
                vs.push(VariantDecl { name: vname, pos: vpos, fields });
                if matches!(self.peek_nonnl(), T::Sym("|")) {
                    self.skip_nl();
                } else {
                    break;
                }
            }
            Ok(TypeDecl { name, public: false, module: String::new(), pos, generics, kind: TypeKind::Enum(vs) })
        }
    }

    fn ty(&mut self) -> R<TyAst> {
        let p = self.pos();
        if self.is_kw("inout") {
            return Err(Diag::new("E0302", p, "`inout` is only valid on function parameters; types can't hold references")
                .help("store the value itself, or an index into a List, or Shared[Mutex[T]]"));
        }
        if self.is_kw("fn") {
            self.adv();
            self.expect_sym("(")?;
            let mut ps = vec![];
            loop {
                self.skip_nl();
                if self.eat_sym(")") {
                    break;
                }
                ps.push(self.ty()?);
                self.skip_nl();
                if !self.eat_sym(",") && !self.is_sym(")") {
                    return self.err("expected `,` or `)`");
                }
            }
            let ret = if self.eat_sym("->") { Some(Box::new(self.ty()?)) } else { None };
            return Ok(TyAst::Fn(ps, ret, p));
        }
        if self.eat_sym("[") {
            let t = self.ty()?;
            self.expect_sym(";")?;
            let n = match self.t().clone() {
                T::Int(n) if n >= 0 && n <= u32::MAX as i128 => {
                    self.adv();
                    n as u64
                }
                _ => return self.err("expected array length (integer literal)"),
            };
            self.expect_sym("]")?;
            return Ok(TyAst::Array(Box::new(t), n, p));
        }
        if self.eat_sym("(") {
            if self.eat_sym(")") {
                return Ok(TyAst::Unit);
            }
            let mut ts = vec![self.ty()?];
            let mut trailing = false;
            while self.eat_sym(",") {
                if self.is_sym(")") {
                    trailing = true;
                    break;
                }
                ts.push(self.ty()?);
            }
            self.expect_sym(")")?;
            return Ok(if ts.len() == 1 && !trailing { ts.pop().unwrap() } else { TyAst::Tuple(ts) });
        }
        match self.t().clone() {
            T::Id(s) if !KW.contains(&s.as_str()) => {
                self.adv();
                let s = self.qualified(&s).unwrap_or(s);
                if self.is_sym("[") {
                    self.adv();
                    let mut args = vec![];
                    loop {
                        self.skip_nl();
                        args.push(self.ty()?);
                        self.skip_nl();
                        if self.eat_sym("]") {
                            break;
                        }
                        self.expect_sym(",")?;
                    }
                    Ok(TyAst::Generic(s, args, p))
                } else {
                    Ok(TyAst::Name(s, p))
                }
            }
            _ => self.err("expected a type"),
        }
    }

    fn fn_decl(&mut self, allow_no_body: bool) -> R<FnDecl> {
        self.expect_kw("fn")?;
        let (name, pos) = self.ident()?;
        let generics = self.generics()?;
        self.expect_sym("(")?;
        let mut params = vec![];
        loop {
            self.skip_nl();
            if self.eat_sym(")") {
                break;
            }
            let inout = self.eat_kw("inout");
            let (n, p) = self.ident()?;
            let ty = if n == "self" && !self.is_sym(":") { TyAst::Name("Self".into(), p) } else {
                self.expect_sym(":")?;
                self.ty()?
            };
            params.push(Param { name: n, inout, ty, pos: p });
            self.skip_nl();
            if !self.eat_sym(",") && !self.is_sym(")") {
                return self.err("expected `,` or `)`");
            }
        }
        let mut sig_end = self.prev_end();
        let mut ret = None;
        if matches!(self.peek_nonnl(), T::Sym("->")) {
            self.skip_nl();
            self.adv();
            ret = Some(self.ty()?);
            sig_end = self.prev_end();
        }
        let mut caps = vec![];
        if matches!(self.peek_nonnl(), T::Id(s) if s == "uses") {
            self.skip_nl();
            self.adv();
            loop {
                caps.push(self.ident()?);
                if !self.eat_sym(",") {
                    break;
                }
            }
            sig_end = self.prev_end();
        }
        if allow_no_body && !matches!(self.peek_nonnl(), T::Sym("{")) {
            return Ok(FnDecl { name, public: false, is_extern: false, is_unsafe: false, is_export: false, module: String::new(), pos, generics, params, ret, caps, sig_end, body: None });
        }
        self.skip_nl();
        let body = self.block()?;
        Ok(FnDecl { name, public: false, is_extern: false, is_unsafe: false, is_export: false, module: String::new(), pos, generics, params, ret, caps, sig_end, body: Some(body) })
    }

    fn trait_decl(&mut self) -> R<TraitDecl> {
        self.expect_kw("trait")?;
        let (name, pos) = self.ident()?;
        self.skip_nl();
        self.expect_sym("{")?;
        let mut methods = vec![];
        loop {
            self.skip_seps();
            if self.eat_sym("}") {
                break;
            }
            methods.push(self.fn_decl(true)?);
        }
        Ok(TraitDecl { name, public: false, module: String::new(), pos, methods })
    }

    fn impl_decl(&mut self) -> R<ImplDecl> {
        let pos = self.expect_kw("impl")?;
        let generics = self.generics()?;
        let first = self.ty()?;
        let (trait_, target) = if self.eat_kw("for") {
            let tn = match &first {
                TyAst::Name(n, p) => (n.clone(), *p),
                _ => return self.err("expected a trait name before `for`"),
            };
            (Some(tn), self.ty()?)
        } else {
            (None, first)
        };
        self.skip_nl();
        self.expect_sym("{")?;
        let mut methods = vec![];
        loop {
            self.skip_seps();
            if self.eat_sym("}") {
                break;
            }
            methods.push(self.fn_decl(false)?);
        }
        Ok(ImplDecl { module: String::new(), pos, generics, trait_, target, methods })
    }

    fn const_decl(&mut self) -> R<ConstDecl> {
        self.expect_kw("const")?;
        let (name, pos) = self.ident()?;
        self.expect_sym(":")?;
        let ty = self.ty()?;
        self.expect_sym("=")?;
        let comptime = self.is_kw("comptime");
        if comptime {
            self.adv();
        }
        let value = self.expr()?;
        Ok(ConstDecl { name, public: false, module: String::new(), pos, ty, value, comptime })
    }

    fn test_decl(&mut self) -> R<TestDecl> {
        let pos = self.expect_kw("test")?;
        let name = match self.t().clone() {
            T::Str(s) => {
                self.adv();
                s
            }
            _ => return self.err("expected test name string"),
        };
        self.skip_nl();
        let body = self.block()?;
        Ok(TestDecl { name, pos, body })
    }

    // ---- statements ----
    fn block(&mut self) -> R<Block> {
        self.expect_sym("{")?;
        let mut stmts = vec![];
        loop {
            self.skip_seps();
            if self.is_sym("}") {
                let end = self.pos();
                self.adv();
                return Ok(Block { stmts, end });
            }
            if matches!(self.t(), T::Eof) {
                return self.err("unexpected end of file, expected `}`");
            }
            stmts.push(self.stmt()?);
            if !(matches!(self.t(), T::Nl) || self.is_sym(";") || self.is_sym("}")) {
                return self.err("expected a newline or `;` after statement");
            }
        }
    }

    fn stmt(&mut self) -> R<Stmt> {
        let pos = self.pos();
        let k = if self.is_kw("let") || self.is_kw("var") {
            let mutable = self.is_kw("var");
            self.adv();
            if self.is_sym("(") {
                let pat = self.pat()?;
                self.expect_sym("=")?;
                self.skip_nl();
                let init = self.expr()?;
                return Ok(Stmt { k: SK::LetPat { pat, mutable, init }, pos });
            }
            let (name, _) = self.ident()?;
            let ty = if self.eat_sym(":") { Some(self.ty()?) } else { None };
            self.expect_sym("=")?;
            self.skip_nl();
            let init = self.expr()?;
            SK::Let { name, mutable, ty, init }
        } else if self.eat_kw("while") {
            let c = self.expr()?;
            let b = self.block()?;
            SK::While(c, b)
        } else if self.eat_kw("for") {
            let (var, _) = self.ident()?;
            self.expect_kw("in")?;
            let lo = self.expr()?;
            if self.eat_sym("..") {
                let hi = self.expr()?;
                let body = self.block()?;
                SK::For { var, lo, hi, body }
            } else {
                let body = self.block()?;
                SK::ForEach { var, iter: lo, body }
            }
        } else if self.eat_kw("return") {
            if matches!(self.t(), T::Nl | T::Eof) || self.is_sym(";") || self.is_sym("}") {
                SK::Return(None)
            } else {
                SK::Return(Some(self.expr()?))
            }
        } else if self.eat_kw("break") {
            SK::Break
        } else if self.eat_kw("continue") {
            SK::Continue
        } else if self.eat_kw("assert") {
            let c = self.expr()?;
            let msg = if self.eat_sym(",") {
                match self.t().clone() {
                    T::Str(s) => {
                        self.adv();
                        Some(s)
                    }
                    _ => return self.err("expected message string"),
                }
            } else {
                None
            };
            SK::Assert(c, msg)
        } else {
            let e = self.expr()?;
            let op = match self.t() {
                T::Sym("=") => Some(None),
                T::Sym("+=") => Some(Some(BinOp::Add)),
                T::Sym("-=") => Some(Some(BinOp::Sub)),
                T::Sym("*=") => Some(Some(BinOp::Mul)),
                T::Sym("/=") => Some(Some(BinOp::Div)),
                T::Sym("%=") => Some(Some(BinOp::Rem)),
                _ => None,
            };
            if let Some(op) = op {
                self.adv();
                self.skip_nl();
                let value = self.expr()?;
                SK::Assign { target: e, op, value }
            } else {
                SK::Expr(e)
            }
        };
        Ok(Stmt { k, pos })
    }

    // ---- expressions ----
    pub fn expr(&mut self) -> R<Expr> {
        self.or()
    }

    fn bin(&self, op: BinOp, l: Expr, r: Expr, pos: Pos) -> Expr {
        Expr { k: EK::Binary(op, Box::new(l), Box::new(r)), pos }
    }

    fn or(&mut self) -> R<Expr> {
        let mut l = self.and()?;
        while self.is_sym("||") {
            let p = self.pos();
            self.adv();
            self.skip_nl();
            let r = self.and()?;
            l = self.bin(BinOp::Or, l, r, p);
        }
        Ok(l)
    }
    fn and(&mut self) -> R<Expr> {
        let mut l = self.cmp()?;
        while self.is_sym("&&") {
            let p = self.pos();
            self.adv();
            self.skip_nl();
            let r = self.cmp()?;
            l = self.bin(BinOp::And, l, r, p);
        }
        Ok(l)
    }
    fn cmp(&mut self) -> R<Expr> {
        let mut l = self.add()?;
        loop {
            let op = match self.t() {
                T::Sym("==") => BinOp::Eq,
                T::Sym("!=") => BinOp::Ne,
                T::Sym("<") => BinOp::Lt,
                T::Sym("<=") => BinOp::Le,
                T::Sym(">") => BinOp::Gt,
                T::Sym(">=") => BinOp::Ge,
                _ => return Ok(l),
            };
            let p = self.pos();
            self.adv();
            self.skip_nl();
            let r = self.add()?;
            l = self.bin(op, l, r, p);
        }
    }
    fn add(&mut self) -> R<Expr> {
        let mut l = self.mul()?;
        loop {
            let op = match self.t() {
                T::Sym("+") => BinOp::Add,
                T::Sym("-") => BinOp::Sub,
                T::Sym("+%") => BinOp::WAdd,
                T::Sym("-%") => BinOp::WSub,
                _ => return Ok(l),
            };
            let p = self.pos();
            self.adv();
            self.skip_nl();
            let r = self.mul()?;
            l = self.bin(op, l, r, p);
        }
    }
    fn mul(&mut self) -> R<Expr> {
        let mut l = self.cast()?;
        loop {
            let op = match self.t() {
                T::Sym("*") => BinOp::Mul,
                T::Sym("/") => BinOp::Div,
                T::Sym("%") => BinOp::Rem,
                T::Sym("*%") => BinOp::WMul,
                _ => return Ok(l),
            };
            let p = self.pos();
            self.adv();
            self.skip_nl();
            let r = self.cast()?;
            l = self.bin(op, l, r, p);
        }
    }
    fn cast(&mut self) -> R<Expr> {
        let mut l = self.unary()?;
        while self.is_kw("as") {
            let p = self.pos();
            self.adv();
            let t = self.ty()?;
            l = Expr { k: EK::Cast(Box::new(l), t), pos: p };
        }
        Ok(l)
    }
    fn unary(&mut self) -> R<Expr> {
        let p = self.pos();
        if self.eat_sym("-") {
            let x = self.unary()?;
            return Ok(Expr { k: EK::Unary(UnOp::Neg, Box::new(x)), pos: p });
        }
        if self.eat_sym("!") {
            let x = self.unary()?;
            return Ok(Expr { k: EK::Unary(UnOp::Not, Box::new(x)), pos: p });
        }
        self.postfix()
    }

    fn args(&mut self) -> R<Vec<Arg>> {
        // after '('
        let mut args = vec![];
        loop {
            self.skip_nl();
            if self.eat_sym(")") {
                return Ok(args);
            }
            let inout = self.eat_kw("inout");
            let e = self.expr()?;
            args.push(Arg { inout, e });
            self.skip_nl();
            if !self.eat_sym(",") && !self.is_sym(")") {
                return self.err("expected `,` or `)`");
            }
        }
    }

    fn postfix(&mut self) -> R<Expr> {
        let mut e = self.primary()?;
        loop {
            let p = self.pos();
            if self.is_sym("(") {
                match &e.k {
                    EK::Ident(n) => {
                        let n = n.clone();
                        self.adv();
                        let a = self.args()?;
                        e = Expr { k: EK::Call(n, a), pos: e.pos };
                    }
                    _ => return self.err("only named functions can be called"),
                }
            } else if self.is_sym(".") {
                self.adv();
                let fp = self.pos();
                let f = match self.t().clone() {
                    T::Int(n) => {
                        self.adv();
                        n.to_string()
                    }
                    _ => self.ident()?.0,
                };
                if self.is_sym("(") {
                    self.adv();
                    let a = self.args()?;
                    e = Expr { k: EK::MethodCall(Box::new(e), f, a), pos: fp };
                } else {
                    e = Expr { k: EK::Field(Box::new(e), f), pos: fp };
                }
            } else if self.is_sym("[") {
                self.adv();
                self.skip_nl();
                let i = self.expr()?;
                self.skip_nl();
                self.expect_sym("]")?;
                e = Expr { k: EK::Index(Box::new(e), Box::new(i)), pos: p };
            } else if self.is_sym("?") {
                self.adv();
                e = Expr { k: EK::Try(Box::new(e)), pos: p };
            } else {
                return Ok(e);
            }
        }
    }

    fn primary(&mut self) -> R<Expr> {
        let pos = self.pos();
        match self.t().clone() {
            T::Int(v) => {
                self.adv();
                Ok(Expr { k: EK::Int(v), pos })
            }
            T::Str(s) => {
                self.adv();
                Ok(Expr { k: EK::Str(s), pos })
            }
            T::Sym("(") => {
                self.adv();
                self.skip_nl();
                let first = self.expr()?;
                self.skip_nl();
                if self.is_sym(",") {
                    let mut es = vec![first];
                    while self.eat_sym(",") {
                        self.skip_nl();
                        if self.is_sym(")") {
                            break;
                        }
                        es.push(self.expr()?);
                        self.skip_nl();
                    }
                    self.expect_sym(")")?;
                    return Ok(Expr { k: EK::Tuple(es), pos });
                }
                self.expect_sym(")")?;
                Ok(first)
            }
            T::Sym("{") => {
                let b = self.block()?;
                Ok(Expr { k: EK::Block(Box::new(b)), pos })
            }
            T::Id(ref k) if k == "unsafe" => {
                self.adv();
                self.skip_nl();
                let b = self.block()?;
                Ok(Expr { k: EK::Unsafe(Box::new(b)), pos })
            }
            T::Sym("|") | T::Sym("||") => {
                let mut params = vec![];
                if self.is_sym("||") {
                    self.adv();
                } else {
                    self.adv();
                    loop {
                        if self.eat_sym("|") {
                            break;
                        }
                        let (n, np) = self.ident()?;
                        let t = if self.eat_sym(":") { Some(self.ty()?) } else { None };
                        params.push((n, t, np));
                        if !self.eat_sym(",") && !self.is_sym("|") {
                            return self.err("expected `,` or `|` in closure parameters");
                        }
                    }
                }
                let ret = if self.eat_sym("->") { Some(self.ty()?) } else { None };
                self.skip_nl();
                let body = self.expr()?;
                Ok(Expr { k: EK::Lambda(params, ret, Box::new(body)), pos })
            }
            T::Sym("[") => {
                self.adv();
                self.skip_nl();
                if self.eat_sym("]") {
                    return Ok(Expr { k: EK::ArrayLit(vec![]), pos });
                }
                let first = self.expr()?;
                self.skip_nl();
                if self.eat_sym(";") {
                    let n = match self.t().clone() {
                        T::Int(n) if n >= 1 && n <= u32::MAX as i128 => {
                            self.adv();
                            n as u64
                        }
                        _ => return self.err("expected a positive integer literal for the array length"),
                    };
                    self.expect_sym("]")?;
                    return Ok(Expr { k: EK::ArrayRepeat(Box::new(first), n), pos });
                }
                let mut es = vec![first];
                loop {
                    self.skip_nl();
                    if self.eat_sym("]") {
                        break;
                    }
                    if !self.eat_sym(",") {
                        return self.err("expected `,` or `]`");
                    }
                    self.skip_nl();
                    if self.eat_sym("]") {
                        break;
                    }
                    es.push(self.expr()?);
                }
                Ok(Expr { k: EK::ArrayLit(es), pos })
            }
            T::Id(s) => match s.as_str() {
                "true" => {
                    self.adv();
                    Ok(Expr { k: EK::Bool(true), pos })
                }
                "false" => {
                    self.adv();
                    Ok(Expr { k: EK::Bool(false), pos })
                }
                "null" => Err(Diag::new("E0402", pos, "`null` does not exist in Eider; absence is modelled with Option[T]")),
                "if" => self.if_expr(),
                "match" => self.match_expr(),
                _ => {
                    let (n, p) = self.ident()?;
                    let n = self.qualified(&n).unwrap_or(n);
                    Ok(Expr { k: EK::Ident(n), pos: p })
                }
            },
            _ => self.err("expected an expression"),
        }
    }

    fn if_expr(&mut self) -> R<Expr> {
        let pos = self.expect_kw("if")?;
        if self.eat_kw("let") {
            // `if let PAT = EXPR { A } else { B }` is sugar for a two-arm match
            let pat = self.pat()?;
            self.expect_sym("=")?;
            let scrut = self.expr()?;
            let then = self.block()?;
            let end = self.prev_end();
            let mut els: Option<Expr> = None;
            if matches!(self.peek_nonnl(), T::Id(s) if s == "else") {
                self.skip_nl();
                self.adv();
                els = Some(if self.is_kw("if") {
                    self.if_expr()?
                } else {
                    let p = self.pos();
                    let b = self.block()?;
                    Expr { k: EK::Block(Box::new(b)), pos: p }
                });
            }
            let else_body = els.unwrap_or(Expr { k: EK::Block(Box::new(Block { stmts: vec![], end })), pos });
            let arms = vec![
                Arm { pats: vec![pat], body: ArmBody::Expr(Expr { k: EK::Block(Box::new(then)), pos }) },
                Arm { pats: vec![Pat { k: PK::Wild, pos }], body: ArmBody::Expr(else_body) },
            ];
            return Ok(Expr { k: EK::Match(Box::new(scrut), arms, end), pos });
        }
        let c = self.expr()?;
        let then = self.block()?;
        let mut els = None;
        if matches!(self.peek_nonnl(), T::Id(s) if s == "else") {
            self.skip_nl();
            self.adv();
            if self.is_kw("if") {
                els = Some(Box::new(self.if_expr()?));
            } else {
                let p = self.pos();
                let b = self.block()?;
                els = Some(Box::new(Expr { k: EK::Block(Box::new(b)), pos: p }));
            }
        }
        Ok(Expr { k: EK::If(Box::new(c), Box::new(then), els), pos })
    }

    fn match_expr(&mut self) -> R<Expr> {
        let pos = self.expect_kw("match")?;
        let s = self.expr()?;
        self.expect_sym("{")?;
        let mut arms = vec![];
        loop {
            while matches!(self.t(), T::Nl) || self.is_sym(",") {
                self.adv();
            }
            if self.is_sym("}") {
                let end = self.pos();
                self.adv();
                return Ok(Expr { k: EK::Match(Box::new(s), arms, end), pos });
            }
            let mut pats = vec![self.pat()?];
            while self.eat_sym("|") {
                self.skip_nl();
                pats.push(self.pat()?);
            }
            self.expect_sym("=>")?;
            self.skip_nl();
            let body = if self.is_kw("return") || self.is_kw("break") || self.is_kw("continue") || self.is_kw("assert") {
                ArmBody::Stmt(self.stmt()?)
            } else {
                ArmBody::Expr(self.expr()?)
            };
            arms.push(Arm { pats, body });
            if !(matches!(self.t(), T::Nl) || self.is_sym(",") || self.is_sym("}")) {
                return self.err("expected a newline, `,` or `}` after match arm");
            }
        }
    }

    pub fn pat(&mut self) -> R<Pat> {
        let pos = self.pos();
        match self.t().clone() {
            T::Int(v) => {
                self.adv();
                Ok(Pat { k: PK::Int(v), pos })
            }
            T::Str(s) => {
                self.adv();
                Ok(Pat { k: PK::Str(s), pos })
            }
            T::Sym("-") => {
                self.adv();
                match self.t().clone() {
                    T::Int(v) => {
                        self.adv();
                        Ok(Pat { k: PK::Int(-v), pos })
                    }
                    _ => self.err("expected integer after `-` in pattern"),
                }
            }
            T::Sym("(") => {
                self.adv();
                let mut ps = vec![];
                loop {
                    self.skip_nl();
                    if self.eat_sym(")") {
                        break;
                    }
                    ps.push(self.pat()?);
                    self.skip_nl();
                    if !self.eat_sym(",") && !self.is_sym(")") {
                        return self.err("expected `,` or `)`");
                    }
                }
                if ps.len() == 1 {
                    return Ok(ps.pop().unwrap());
                }
                Ok(Pat { k: PK::Tuple(ps), pos })
            }
            T::Id(s) if s == "_" => {
                self.adv();
                Ok(Pat { k: PK::Wild, pos })
            }
            T::Id(s) if s == "true" || s == "false" => {
                self.adv();
                Ok(Pat { k: PK::Bool(s == "true"), pos })
            }
            T::Id(_) => {
                let (mut n, mut p) = self.ident()?;
                if let Some(q) = self.qualified(&n) {
                    n = q;
                }
                while self.is_sym(".") {
                    self.adv();
                    let r = self.ident()?;
                    n = r.0;
                    p = r.1;
                }
                if self.eat_sym("(") {
                    let mut ps = vec![];
                    loop {
                        self.skip_nl();
                        if self.eat_sym(")") {
                            break;
                        }
                        ps.push(self.pat()?);
                        self.skip_nl();
                        if !self.eat_sym(",") && !self.is_sym(")") {
                            return self.err("expected `,` or `)`");
                        }
                    }
                    return Ok(Pat { k: PK::Variant(n, ps), pos: p });
                }
                Ok(Pat { k: PK::Name(n), pos: p })
            }
            _ => self.err("expected a pattern"),
        }
    }
}
