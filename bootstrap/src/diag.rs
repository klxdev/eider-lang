//! Diagnostics: stable error codes, spans, machine-applicable fixes, human and JSON rendering.

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Pos {
    pub line: u32,
    pub col: u32,
}

/// A machine-applicable edit: delete `delete` chars at `pos`, then insert `insert`.
#[derive(Clone, Debug)]
pub struct Fix {
    pub pos: Pos,
    pub delete: usize,
    pub insert: String,
}

#[derive(Clone, Debug)]
pub struct Diag {
    pub code: &'static str,
    pub pos: Pos,
    pub msg: String,
    pub help: Option<String>,
    pub fix: Option<Fix>,
    /// Set when the error is in an imported file rather than the entry file.
    pub file: Option<String>,
}

/// Every error code the compiler can emit. The compile-fail runner reports coverage against this list.
pub const ALL_CODES: &[&str] = &[
    "E0001", "E0101", "E0102", "E0103", "E0107", "E0108", "E0110", "E0111", "E0112", "E0113",
    "E0114", "E0115", "E0201", "E0203", "E0301", "E0302", "E0303", "E0304", "E0305", "E0306", "E0401",
    "E0402", "E0405", "E0406", "E0409", "E0410", "E0501", "E0502", "E0503", "E0504", "E0601", "E0602", "E0603", "E0701", "E0801", "E0802", "E0803", "E0804", "E0805", "E0806", "E0807", "E0808",
];

impl Diag {
    pub fn new(code: &'static str, pos: Pos, msg: impl Into<String>) -> Diag {
        Diag { code, pos, msg: msg.into(), help: None, fix: None, file: None }
    }
    pub fn help(mut self, h: impl Into<String>) -> Diag {
        self.help = Some(h.into());
        self
    }
    pub fn in_file(mut self, f: &str) -> Diag {
        if self.file.is_none() && !f.is_empty() {
            self.file = Some(f.to_string());
        }
        self
    }
    pub fn fix(mut self, pos: Pos, delete: usize, insert: impl Into<String>) -> Diag {
        self.fix = Some(Fix { pos, delete, insert: insert.into() });
        self
    }

    pub fn render(&self, file: &str, src: &str) -> String {
        let mut s = format!("error[{}]: {}\n", self.code, self.msg);
        s.push_str(&format!("  --> {}:{}:{}\n", file, self.pos.line, self.pos.col));
        if let Some(l) = src.lines().nth(self.pos.line.saturating_sub(1) as usize) {
            let n = self.pos.line.to_string();
            let pad = " ".repeat(n.len());
            s.push_str(&format!("{} |\n{} | {}\n{} | {}^\n", pad, n, l, pad, " ".repeat(self.pos.col.saturating_sub(1) as usize)));
        }
        if let Some(h) = &self.help {
            s.push_str(&format!("  help: {}\n", h));
        }
        if let Some(f) = &self.fix {
            s.push_str(&format!("  fix: at {}:{} delete {} insert {:?}\n", f.pos.line, f.pos.col, f.delete, f.insert));
        }
        s
    }

    pub fn json(&self, file: &str) -> String {
        let file = self.file.as_deref().unwrap_or(file);
        let mut s = format!(
            "{{\"error\":\"{}\",\"span\":{{\"file\":{},\"line\":{},\"col\":{}}},\"message\":{}",
            self.code,
            jstr(file),
            self.pos.line,
            self.pos.col,
            jstr(&self.msg)
        );
        if let Some(h) = &self.help {
            s.push_str(&format!(",\"help\":{}", jstr(h)));
        }
        if let Some(f) = &self.fix {
            s.push_str(&format!(
                ",\"fix\":{{\"at\":{{\"line\":{},\"col\":{}}},\"delete\":{},\"insert\":{}}}",
                f.pos.line, f.pos.col, f.delete, jstr(&f.insert)
            ));
        }
        s.push('}');
        s
    }
}

fn jstr(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// Apply a fix to source text. Columns are 1-based char positions.
pub fn apply_fix(src: &str, f: &Fix) -> String {
    let (mut line, mut col) = (1u32, 1u32);
    let mut idx = src.len();
    for (i, ch) in src.char_indices() {
        if line == f.pos.line && col == f.pos.col {
            idx = i;
            break;
        }
        if ch == '\n' {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    let end = (idx + f.delete).min(src.len());
    format!("{}{}{}", &src[..idx], f.insert, &src[end..])
}
