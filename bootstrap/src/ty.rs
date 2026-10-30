//! Semantic types and small shared helpers.

use std::fmt;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum IntTy {
    I32,
    I64,
    U8,
    U32,
    U64,
    Usize,
}

impl IntTy {
    pub fn from_name(s: &str) -> Option<IntTy> {
        Some(match s {
            "i32" => IntTy::I32,
            "i64" => IntTy::I64,
            "u8" => IntTy::U8,
            "u32" => IntTy::U32,
            "u64" => IntTy::U64,
            "usize" => IntTy::Usize,
            _ => return None,
        })
    }
    pub fn name(self) -> &'static str {
        match self {
            IntTy::I32 => "i32",
            IntTy::I64 => "i64",
            IntTy::U8 => "u8",
            IntTy::U32 => "u32",
            IntTy::U64 => "u64",
            IntTy::Usize => "usize",
        }
    }
    pub fn signed(self) -> bool {
        matches!(self, IntTy::I32 | IntTy::I64)
    }
    pub fn bits(self) -> u32 {
        match self {
            IntTy::I32 | IntTy::U32 => 32,
            IntTy::U8 => 8,
            _ => 64,
        }
    }
    pub fn min(self) -> i128 {
        if self.signed() {
            -(1i128 << (self.bits() - 1))
        } else {
            0
        }
    }
    pub fn max(self) -> i128 {
        if self.signed() {
            (1i128 << (self.bits() - 1)) - 1
        } else {
            (1i128 << self.bits()) - 1
        }
    }
    pub fn c(self) -> &'static str {
        match self {
            IntTy::I32 => "int32_t",
            IntTy::I64 => "int64_t",
            IntTy::U8 => "uint8_t",
            IntTy::U32 => "uint32_t",
            IntTy::U64 | IntTy::Usize => "uint64_t",
        }
    }
    pub fn h(self) -> &'static str {
        match self {
            IntTy::Usize => "u64",
            t => t.name(),
        }
    }
    pub fn cmin(self) -> &'static str {
        match self {
            IntTy::I32 => "INT32_MIN",
            IntTy::I64 => "INT64_MIN",
            _ => "0",
        }
    }
    pub fn cmax(self) -> &'static str {
        match self {
            IntTy::I32 => "INT32_MAX",
            IntTy::I64 => "INT64_MAX",
            IntTy::U8 => "UINT8_MAX",
            IntTy::U32 => "UINT32_MAX",
            _ => "UINT64_MAX",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub enum Ty {
    Int(IntTy),
    Bool,
    Str,
    Unit,
    Never,
    /// Instance key such as `Color` or `Option[i32]`.
    Enum(String),
    Record(String),
    Array(Box<Ty>, u64),
    Tuple(Vec<Ty>),
    /// Owned heap types (value semantics: reads from a place clone, rvalues move).
    String,
    List(Box<Ty>),
    Map(Box<Ty>, Box<Ty>),
    Box(Box<Ty>),
    /// First-class function / closure value.
    Fn(Vec<Ty>, Box<Ty>),
    /// Shared (reference-counted) concurrency handles. Cloning one shares it.
    Task(Box<Ty>),
    Mutex(Box<Ty>),
    Chan(Box<Ty>),
}

impl fmt::Display for Ty {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Ty::Int(t) => write!(f, "{}", t.name()),
            Ty::Bool => write!(f, "bool"),
            Ty::Str => write!(f, "str"),
            Ty::Unit => write!(f, "()"),
            Ty::Never => write!(f, "!"),
            Ty::Enum(n) | Ty::Record(n) => write!(f, "{}", n),
            Ty::Array(t, n) => write!(f, "[{}; {}]", t, n),
            Ty::String => write!(f, "String"),
            Ty::List(t) => write!(f, "List[{}]", t),
            Ty::Map(k, v) => write!(f, "Map[{}, {}]", k, v),
            Ty::Box(t) => write!(f, "Box[{}]", t),
            Ty::Task(t) => write!(f, "Task[{}]", t),
            Ty::Mutex(t) => write!(f, "Mutex[{}]", t),
            Ty::Chan(t) => write!(f, "Chan[{}]", t),
            Ty::Fn(ps, r) => {
                write!(f, "fn(")?;
                for (i, p) in ps.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{}", p)?;
                }
                write!(f, ")")?;
                if **r != Ty::Unit {
                    write!(f, " -> {}", r)?;
                }
                Ok(())
            }
            Ty::Tuple(ts) => {
                write!(f, "(")?;
                for (i, t) in ts.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{}", t)?;
                }
                write!(f, ")")
            }
        }
    }
}

/// Make an arbitrary type key usable inside a C identifier.
pub fn mangle(s: &str) -> String {
    let mut o = String::new();
    for ch in s.chars() {
        match ch {
            c if c.is_ascii_alphanumeric() || c == '_' => o.push(c),
            '[' => o.push_str("_L"),
            ']' => o.push_str("_R"),
            ',' => o.push_str("_C"),
            ';' => o.push_str("_S"),
            '(' => o.push_str("_P"),
            ')' => o.push_str("_Q"),
            '-' => o.push_str("_m"),
            '>' => o.push_str("_g"),
            ' ' => {}
            _ => o.push('_'),
        }
    }
    o
}

pub fn lit_c(t: IntTy, v: i128) -> String {
    match t {
        IntTy::I64 => {
            if v == t.min() {
                "INT64_MIN".into()
            } else {
                format!("INT64_C({})", v)
            }
        }
        IntTy::U64 | IntTy::Usize => format!("UINT64_C({})", v),
        IntTy::I32 => {
            if v == t.min() {
                "INT32_MIN".into()
            } else {
                format!("((int32_t){})", v)
            }
        }
        IntTy::U8 => format!("((uint8_t){})", v),
        IntTy::U32 => format!("((uint32_t){}u)", v),
    }
}

pub fn wrap(c: &str) -> String {
    if c.chars().all(|ch| ch.is_alphanumeric() || ch == '_') {
        c.to_string()
    } else {
        format!("({})", c)
    }
}

pub fn cstr(s: &str) -> String {
    let mut o = String::from("\"");
    for ch in s.chars() {
        match ch {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\t' => o.push_str("\\t"),
            c if c.is_ascii() && !c.is_ascii_control() => o.push(c),
            c => {
                let mut b = [0u8; 4];
                for byte in c.encode_utf8(&mut b).bytes() {
                    o.push_str(&format!("\\{:03o}", byte));
                }
            }
        }
    }
    o.push('"');
    o
}

pub fn is_tmp(c: &str) -> bool {
    c.len() > 1 && c.starts_with('t') && c[1..].chars().all(|ch| ch.is_ascii_digit())
}
