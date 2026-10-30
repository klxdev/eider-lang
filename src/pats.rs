//! Pattern-matrix exhaustiveness and reachability (Maranget's algorithm).

use crate::ty::Ty;

#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub enum Ctor {
    /// enum variant by name
    Variant(String),
    /// the only constructor of a tuple (name "") or record (type name)
    Single(String),
    Bool(bool),
    Int(i128),
    Str(String),
}

#[derive(Clone, Debug)]
pub enum P {
    Wild,
    C(Ctor, Vec<P>),
}

/// For a type with a finite constructor set: every constructor with its field types.
/// `None` for types with infinitely many values (integers, strings).
pub type SigFn<'a> = &'a dyn Fn(&Ty) -> Option<Vec<(Ctor, Vec<Ty>)>>;

fn field_tys(sig: SigFn, ty: &Ty, c: &Ctor) -> Vec<Ty> {
    match sig(ty) {
        Some(all) => all.into_iter().find(|(c2, _)| c2 == c).map(|(_, f)| f).unwrap_or_default(),
        None => vec![],
    }
}

fn heads(rows: &[Vec<P>]) -> Vec<Ctor> {
    let mut v: Vec<Ctor> = vec![];
    for r in rows {
        if let P::C(c, _) = &r[0] {
            if !v.contains(c) {
                v.push(c.clone());
            }
        }
    }
    v
}

fn specialize(rows: &[Vec<P>], c: &Ctor, arity: usize) -> Vec<Vec<P>> {
    let mut out = vec![];
    for r in rows {
        match &r[0] {
            P::C(c2, args) if c2 == c => {
                let mut n = args.clone();
                n.extend_from_slice(&r[1..]);
                out.push(n);
            }
            P::Wild => {
                let mut n = vec![P::Wild; arity];
                n.extend_from_slice(&r[1..]);
                out.push(n);
            }
            _ => {}
        }
    }
    out
}

fn default_rows(rows: &[Vec<P>]) -> Vec<Vec<P>> {
    rows.iter().filter(|r| matches!(r[0], P::Wild)).map(|r| r[1..].to_vec()).collect()
}

/// Would `v` match some value that no row in `rows` matches?
pub fn useful(sig: SigFn, rows: &[Vec<P>], v: &[P], tys: &[Ty]) -> bool {
    if v.is_empty() {
        return rows.is_empty();
    }
    match &v[0] {
        P::C(c, args) => {
            let r2 = specialize(rows, c, args.len());
            let mut v2 = args.clone();
            v2.extend_from_slice(&v[1..]);
            let mut t2 = field_tys(sig, &tys[0], c);
            t2.extend_from_slice(&tys[1..]);
            useful(sig, &r2, &v2, &t2)
        }
        P::Wild => {
            let hs = heads(rows);
            match sig(&tys[0]) {
                Some(all) if all.iter().all(|(c, _)| hs.contains(c)) => all.iter().any(|(c, ftys)| {
                    let r2 = specialize(rows, c, ftys.len());
                    let mut v2 = vec![P::Wild; ftys.len()];
                    v2.extend_from_slice(&v[1..]);
                    let mut t2 = ftys.clone();
                    t2.extend_from_slice(&tys[1..]);
                    useful(sig, &r2, &v2, &t2)
                }),
                _ => useful(sig, &default_rows(rows), &v[1..], &tys[1..]),
            }
        }
    }
}

fn show(c: &Ctor, arity: usize, inner: &[String]) -> String {
    let args = if arity == 0 { String::new() } else { format!("({})", inner.join(", ")) };
    match c {
        Ctor::Variant(n) => format!("{}{}", n, args),
        Ctor::Single(n) => {
            if n.is_empty() {
                format!("({})", inner.join(", "))
            } else {
                format!("{}{}", n, args)
            }
        }
        Ctor::Bool(b) => b.to_string(),
        Ctor::Int(i) => i.to_string(),
        Ctor::Str(s) => format!("{:?}", s),
    }
}

/// A witness (one string per column) of a value no row matches, or None if rows are exhaustive.
pub fn missing(sig: SigFn, rows: &[Vec<P>], tys: &[Ty]) -> Option<Vec<String>> {
    if tys.is_empty() {
        return if rows.is_empty() { Some(vec![]) } else { None };
    }
    let hs = heads(rows);
    match sig(&tys[0]) {
        Some(all) if all.iter().all(|(c, _)| hs.contains(c)) => {
            for (c, ftys) in &all {
                let r2 = specialize(rows, c, ftys.len());
                let mut t2 = ftys.clone();
                t2.extend_from_slice(&tys[1..]);
                if let Some(w) = missing(sig, &r2, &t2) {
                    let n = ftys.len();
                    let mut out = vec![show(c, n, &w[..n])];
                    out.extend_from_slice(&w[n..]);
                    return Some(out);
                }
            }
            None
        }
        other => {
            let w = missing(sig, &default_rows(rows), &tys[1..])?;
            let head = match other {
                Some(all) => {
                    let (c, f) = all.iter().find(|(c, _)| !hs.contains(c)).unwrap();
                    show(c, f.len(), &vec!["_".to_string(); f.len()])
                }
                None => "_".to_string(),
            };
            let mut out = vec![head];
            out.extend(w);
            Some(out)
        }
    }
}
