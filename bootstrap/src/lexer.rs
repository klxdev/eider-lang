use crate::diag::{Diag, Pos};

#[derive(Clone, Debug, PartialEq)]
pub enum T {
    Id(String),
    Int(i128),
    Str(String),
    Sym(&'static str),
    Nl,
    Eof,
}

#[derive(Clone, Debug)]
pub struct Token {
    pub t: T,
    pub pos: Pos,
    pub end: Pos,
}

// Longest first.
const SYMS: &[&str] = &[
    "->", "=>", "==", "!=", "<=", ">=", "&&", "||", "+%", "-%", "*%", "+=", "-=", "*=", "/=", "%=", "..", "?", "(", ")",
    "{", "}", "[", "]", ",", ":", ";", ".", "+", "-", "*", "/", "%", "<", ">", "=", "!", "|",
];

pub fn lex(src: &str) -> Result<Vec<Token>, Diag> {
    let cs: Vec<char> = src.chars().collect();
    let (mut i, mut line, mut col) = (0usize, 1u32, 1u32);
    let mut out: Vec<Token> = Vec::new();
    let err = |code: &'static str, p: Pos, m: &str| Diag::new(code, p, m.to_string());

    while i < cs.len() {
        let c = cs[i];
        let start = Pos { line, col };
        if c == '\n' {
            if !matches!(out.last(), Some(Token { t: T::Nl, .. })) {
                out.push(Token { t: T::Nl, pos: start, end: Pos { line, col: col + 1 } });
            }
            i += 1;
            line += 1;
            col = 1;
            continue;
        }
        if c == ' ' || c == '\t' || c == '\r' {
            i += 1;
            col += 1;
            continue;
        }
        if c == '/' && cs.get(i + 1) == Some(&'/') {
            while i < cs.len() && cs[i] != '\n' {
                i += 1;
                col += 1;
            }
            continue;
        }
        if c == '/' && cs.get(i + 1) == Some(&'*') {
            i += 2;
            col += 2;
            loop {
                if i + 1 >= cs.len() {
                    return Err(err("E0001", start, "unterminated block comment"));
                }
                if cs[i] == '*' && cs[i + 1] == '/' {
                    i += 2;
                    col += 2;
                    break;
                }
                if cs[i] == '\n' {
                    line += 1;
                    col = 1;
                } else {
                    col += 1;
                }
                i += 1;
            }
            continue;
        }
        if c.is_ascii_digit() {
            let s = i;
            let mut v: i128 = 0;
            if c == '0' && matches!(cs.get(i + 1), Some('x') | Some('X')) {
                i += 2;
                let ds = i;
                while i < cs.len() && (cs[i].is_ascii_hexdigit() || cs[i] == '_') {
                    if cs[i] != '_' {
                        v = v.checked_mul(16).and_then(|v| v.checked_add(cs[i].to_digit(16).unwrap() as i128)).ok_or_else(|| err("E0001", start, "integer literal too large"))?;
                    }
                    i += 1;
                }
                if i == ds {
                    return Err(err("E0001", start, "expected hex digits after 0x"));
                }
            } else {
                while i < cs.len() && (cs[i].is_ascii_digit() || cs[i] == '_') {
                    if cs[i] != '_' {
                        v = v.checked_mul(10).and_then(|v| v.checked_add(cs[i].to_digit(10).unwrap() as i128)).ok_or_else(|| err("E0001", start, "integer literal too large"))?;
                    }
                    i += 1;
                }
            }
            col += (i - s) as u32;
            out.push(Token { t: T::Int(v), pos: start, end: Pos { line, col } });
            continue;
        }
        if c.is_ascii_alphabetic() || c == '_' {
            let s = i;
            while i < cs.len() && (cs[i].is_ascii_alphanumeric() || cs[i] == '_') {
                i += 1;
            }
            col += (i - s) as u32;
            out.push(Token { t: T::Id(cs[s..i].iter().collect()), pos: start, end: Pos { line, col } });
            continue;
        }
        if c == '"' {
            let mut s = String::new();
            i += 1;
            col += 1;
            loop {
                match cs.get(i) {
                    None | Some('\n') => return Err(err("E0001", start, "unterminated string literal")),
                    Some('"') => {
                        i += 1;
                        col += 1;
                        break;
                    }
                    Some('\\') => {
                        let e = cs.get(i + 1).copied();
                        s.push(match e {
                            Some('n') => '\n',
                            Some('t') => '\t',
                            Some('"') => '"',
                            Some('\\') => '\\',
                            _ => return Err(err("E0001", Pos { line, col }, "unknown escape sequence")),
                        });
                        i += 2;
                        col += 2;
                    }
                    Some(&ch) => {
                        s.push(ch);
                        i += 1;
                        col += 1;
                    }
                }
            }
            out.push(Token { t: T::Str(s), pos: start, end: Pos { line, col } });
            continue;
        }
        let mut matched = None;
        for s in SYMS {
            let sc: Vec<char> = s.chars().collect();
            if cs[i..].starts_with(&sc) {
                matched = Some(*s);
                break;
            }
        }
        match matched {
            Some(s) => {
                i += s.len();
                col += s.len() as u32;
                out.push(Token { t: T::Sym(s), pos: start, end: Pos { line, col } });
            }
            None => return Err(err("E0001", start, &format!("unexpected character `{}`", c))),
        }
    }
    let p = Pos { line, col };
    out.push(Token { t: T::Eof, pos: p, end: p });
    Ok(out)
}
