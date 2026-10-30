use crate::diag::Pos;

#[derive(Clone, Debug)]
pub enum TyAst {
    Name(String, Pos),
    Generic(String, Vec<TyAst>, Pos),
    Array(Box<TyAst>, u64, Pos),
    Tuple(Vec<TyAst>),
    /// `fn(A, B) -> R`
    Fn(Vec<TyAst>, Option<Box<TyAst>>, Pos),
    Unit,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    WAdd,
    WSub,
    WMul,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
}

impl BinOp {
    pub fn sym(self) -> &'static str {
        use BinOp::*;
        match self {
            Add => "+",
            Sub => "-",
            Mul => "*",
            Div => "/",
            Rem => "%",
            WAdd => "+%",
            WSub => "-%",
            WMul => "*%",
            Eq => "==",
            Ne => "!=",
            Lt => "<",
            Le => "<=",
            Gt => ">",
            Ge => ">=",
            And => "&&",
            Or => "||",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum UnOp {
    Neg,
    Not,
}

#[derive(Clone, Debug)]
pub struct Arg {
    pub inout: bool,
    pub e: Expr,
}

#[derive(Clone, Debug)]
pub struct Expr {
    pub k: EK,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub enum EK {
    Int(i128),
    Bool(bool),
    Str(String),
    Ident(String),
    Unary(UnOp, Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    Call(String, Vec<Arg>),
    /// receiver, method name, args
    MethodCall(Box<Expr>, String, Vec<Arg>),
    Field(Box<Expr>, String),
    Index(Box<Expr>, Box<Expr>),
    Cast(Box<Expr>, TyAst),
    ArrayLit(Vec<Expr>),
    ArrayRepeat(Box<Expr>, u64),
    Tuple(Vec<Expr>),
    Try(Box<Expr>),
    Unsafe(Box<Block>),
    /// `|a, b: T| -> R body`
    Lambda(Vec<(String, Option<TyAst>, Pos)>, Option<TyAst>, Box<Expr>),
    If(Box<Expr>, Box<Block>, Option<Box<Expr>>),
    /// scrutinee, arms, position of closing brace
    Match(Box<Expr>, Vec<Arm>, Pos),
    Block(Box<Block>),
}

#[derive(Clone, Debug)]
pub struct Block {
    pub stmts: Vec<Stmt>,
    pub end: Pos,
}

#[derive(Clone, Debug)]
pub struct Stmt {
    pub k: SK,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub enum SK {
    Let { name: String, mutable: bool, ty: Option<TyAst>, init: Expr },
    LetPat { pat: Pat, mutable: bool, init: Expr },
    Assign { target: Expr, op: Option<BinOp>, value: Expr },
    Expr(Expr),
    While(Expr, Block),
    For { var: String, lo: Expr, hi: Expr, body: Block },
    ForEach { var: String, iter: Expr, body: Block },
    Return(Option<Expr>),
    Break,
    Continue,
    Assert(Expr, Option<String>),
}

#[derive(Clone, Debug)]
pub struct Arm {
    pub pats: Vec<Pat>,
    pub body: ArmBody,
}

#[derive(Clone, Debug)]
pub enum ArmBody {
    Expr(Expr),
    Stmt(Stmt),
}

#[derive(Clone, Debug)]
pub struct Pat {
    pub k: PK,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub enum PK {
    Wild,
    /// a bare name: unit variant or binding
    Name(String),
    Int(i128),
    Bool(bool),
    Str(String),
    /// `Variant(p, q)` or `Record(p, q)`
    Variant(String, Vec<Pat>),
    Tuple(Vec<Pat>),
}

#[derive(Clone, Debug)]
pub enum Item {
    Type(TypeDecl),
    Fn(FnDecl),
    Const(ConstDecl),
    Test(TestDecl),
    Trait(TraitDecl),
    Impl(ImplDecl),
    /// path, position, alias (defaults to the file stem)
    Import(String, Pos, String),
}

#[derive(Clone, Debug)]
pub struct VariantDecl {
    pub name: String,
    pub pos: Pos,
    pub fields: Vec<(String, TyAst)>,
}

#[derive(Clone, Debug)]
pub struct TypeDecl {
    pub name: String,
    pub public: bool,
    pub module: String,
    pub pos: Pos,
    pub generics: Vec<String>,
    pub kind: TypeKind,
}

#[derive(Clone, Debug)]
pub enum TypeKind {
    Enum(Vec<VariantDecl>),
    Record(Vec<(String, TyAst, Pos)>),
}

#[derive(Clone, Debug)]
pub struct Param {
    pub name: String,
    pub inout: bool,
    pub ty: TyAst,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub struct GenericParam {
    pub name: String,
    pub bounds: Vec<String>,
    pub pos: Pos,
}

#[derive(Clone, Debug)]
pub struct FnDecl {
    pub name: String,
    pub public: bool,
    pub is_extern: bool,
    pub is_unsafe: bool,
    pub is_export: bool,
    pub module: String,
    pub pos: Pos,
    pub generics: Vec<GenericParam>,
    pub params: Vec<Param>,
    pub ret: Option<TyAst>,
    pub caps: Vec<(String, Pos)>,
    /// position right after the last token of the signature (where `uses` goes)
    pub sig_end: Pos,
    pub body: Option<Block>,
}

#[derive(Clone, Debug)]
pub struct TraitDecl {
    pub name: String,
    pub public: bool,
    pub module: String,
    pub pos: Pos,
    pub methods: Vec<FnDecl>,
}

#[derive(Clone, Debug)]
pub struct ImplDecl {
    pub module: String,
    pub pos: Pos,
    pub generics: Vec<GenericParam>,
    pub trait_: Option<(String, Pos)>,
    pub target: TyAst,
    pub methods: Vec<FnDecl>,
}

#[derive(Clone, Debug)]
pub struct ConstDecl {
    pub name: String,
    pub public: bool,
    pub module: String,
    pub pos: Pos,
    pub ty: TyAst,
    pub value: Expr,
    /// `const N: T = comptime expr`: evaluated by the compiler before checking
    pub comptime: bool,
}

#[derive(Clone, Debug)]
pub struct TestDecl {
    pub name: String,
    pub pos: Pos,
    pub body: Block,
}
