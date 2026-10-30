mod ast;
mod check;
mod closure;
mod diag;
mod expr;
mod ffi;
mod heap;
mod lexer;
mod ns;
mod parser;
mod pats;
mod prelude;
mod stmt;
mod wasm_shim;
mod ty;

use check::Mode;
use diag::{apply_fix, Diag, ALL_CODES};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::{exit, Command};

fn tag_items(items: &mut [ast::Item], module: &str) {
    for it in items.iter_mut() {
        match it {
            ast::Item::Type(t) => t.module = module.to_string(),
            ast::Item::Const(c) => c.module = module.to_string(),
            ast::Item::Trait(t) => {
                t.module = module.to_string();
                t.methods.iter_mut().for_each(|m| m.module = module.to_string());
            }
            ast::Item::Fn(f) => f.module = module.to_string(),
            ast::Item::Impl(im) => {
                im.module = module.to_string();
                im.methods.iter_mut().for_each(|m| m.module = module.to_string());
            }
            ast::Item::Test(_) | ast::Item::Import(..) => {}
        }
    }
}

/// Parse `src` (the file `file`) and, recursively, everything it imports.
fn load_module(src: &str, file: &str, prefix: Option<&str>, seen: &mut HashSet<PathBuf>, prefixes: &mut std::collections::HashMap<String, PathBuf>, out: &mut Vec<ast::Item>) -> Result<(), Diag> {
    let toks = lexer::lex(src).map_err(|d| d.in_file(file))?;
    let mut items = parser::Parser::new(toks).program().map_err(|d| d.in_file(file))?;
    tag_items(&mut items, file);
    if let Some(p) = prefix {
        ns::mangle_module(&mut items, p);
    }
    let dir = Path::new(file).parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let mut own = vec![];
    for it in items {
        match it {
            ast::Item::Import(rel, pos, _alias) => {
                let mut path = dir.join(&rel);
                if path.extension().is_none() {
                    path.set_extension("ei");
                }
                let canon = std::fs::canonicalize(&path).unwrap_or(path.clone());
                let pre = ns::prefix_of(&rel);
                match prefixes.get(&pre) {
                    Some(other) if *other != canon => {
                        return Err(Diag::new("E0808", pos, format!("two different modules are both named `{}` ({} and {})", pre, other.display(), canon.display()))
                            .help("rename one of the files; a module's name is its file name")
                            .in_file(file));
                    }
                    _ => {
                        prefixes.insert(pre.clone(), canon.clone());
                    }
                }
                if !seen.insert(canon) {
                    continue; // already loaded (or an import cycle): modules are merged once
                }
                let text = std::fs::read_to_string(&path).map_err(|e| {
                    Diag::new("E0804", pos, format!("cannot read module `{}`: {}", path.display(), e)).in_file(file)
                })?;
                load_module(&text, &path.to_string_lossy(), Some(&pre), seen, prefixes, out)?;
            }
            other => own.push(other),
        }
    }
    out.extend(own);
    Ok(())
}

/// Evaluate `const X: T = comptime expr` by compiling the program (minus `main`, tests and
/// comptime consts) with a generated `main` that prints the value, running it, and splicing the
/// result back in as a literal. Integers and bool only.
fn eval_comptime(items: &mut Vec<ast::Item>, file: &str) -> Result<(), Diag> {
    use ast::*;
    let idx: Vec<usize> = (0..items.len()).filter(|&i| matches!(&items[i], Item::Const(c) if c.comptime)).collect();
    for i in idx {
        let c = match &items[i] {
            Item::Const(c) => c.clone(),
            _ => unreachable!(),
        };
        let fail = |msg: String| Diag::new("E0807", c.pos, msg).in_file(&c.module);
        let is_int = matches!(&c.ty, TyAst::Name(n, _) if ty::IntTy::from_name(n).is_some());
        let is_bool = matches!(&c.ty, TyAst::Name(n, _) if n == "bool");
        if !is_int && !is_bool {
            return Err(fail("`comptime` constants must be integers or bool".into()));
        }
        let mut stub = parser::Parser::new(lexer::lex("fn __ct() -> i32 { return 0 }\nfn main() uses io { print(__ct()) }").unwrap()).program().unwrap();
        for it in stub.iter_mut() {
            if let Item::Fn(f) = it {
                f.module = c.module.clone();
                if f.name == "__ct" {
                    f.ret = Some(c.ty.clone());
                    f.body = Some(Block { stmts: vec![Stmt { k: SK::Return(Some(c.value.clone())), pos: c.value.pos }], end: c.value.pos });
                }
            }
        }
        let mut prog: Vec<Item> = items
            .iter()
            .filter(|it| match it {
                Item::Const(k) => !k.comptime,
                Item::Test(_) => false,
                Item::Fn(f) => !(f.name == "main" && !f.is_extern),
                _ => true,
            })
            .cloned()
            .collect();
        prog.extend(stub);
        let (cc_src, _) = check::compile(&prog, file, Mode::Build).map_err(|mut d| {
            if d.code == "E0201" && d.fix.is_some() {
                // the capability is missing from the synthetic evaluator, not from user code
                d.fix = None;
                d.help = Some("`comptime` evaluation can't use capabilities".into());
            }
            d
        })?;
        let dir = std::env::temp_dir().join(format!("eider_ct_{}_{}", std::process::id(), i));
        let _ = std::fs::create_dir_all(&dir);
        let (cfile, exe) = (dir.join("ct.c"), dir.join("ct"));
        std::fs::write(&cfile, &cc_src).expect("write C file");
        let built = Command::new(cc_cmd()).args(["-std=c11", "-O1", "-pthread", "-w", "-o"]).arg(&exe).arg(&cfile).status();
        let res = match built {
            Ok(s) if s.success() => Command::new(&exe).output().ok(),
            _ => None,
        };
        let _ = std::fs::remove_dir_all(&dir);
        let out = res.ok_or_else(|| fail("could not build the comptime evaluator".into()))?;
        if !out.status.success() {
            let why = String::from_utf8_lossy(&out.stderr).lines().next().unwrap_or("").to_string();
            return Err(fail(format!("comptime evaluation of `{}` failed: {}", c.name, why)));
        }
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        let mut lines = text.lines();
        let (first, extra) = (lines.next().unwrap_or("").trim().to_string(), lines.next().is_some());
        if extra {
            return Err(fail("comptime evaluation can't perform I/O".into()));
        }
        let k = if is_bool {
            EK::Bool(first == "true")
        } else {
            match first.parse::<i128>() {
                Ok(v) if v < 0 => EK::Unary(UnOp::Neg, Box::new(Expr { k: EK::Int(-v), pos: c.value.pos })),
                Ok(v) => EK::Int(v),
                Err(_) => return Err(fail(format!("unexpected comptime result `{}`", first))),
            }
        };
        if let Item::Const(slot) = &mut items[i] {
            slot.value = Expr { k, pos: c.value.pos };
            slot.comptime = false;
        }
    }
    Ok(())
}

pub fn compile_full(src: &str, file: &str, mode: Mode) -> Result<(String, String), Diag> {
    let mut items = parser::Parser::new(lexer::lex(prelude::EIDER_PRELUDE).expect("prelude lexes")).program().expect("prelude parses");
    let mut seen = HashSet::new();
    seen.insert(std::fs::canonicalize(file).unwrap_or_else(|_| PathBuf::from(file)));
    let mut prefixes = std::collections::HashMap::new();
    load_module(src, file, None, &mut seen, &mut prefixes, &mut items)?;
    eval_comptime(&mut items, file)?;
    check::compile(&items, file, mode)
}

pub fn compile_src(src: &str, file: &str, mode: Mode) -> Result<String, Diag> {
    compile_full(src, file, mode).map(|r| r.0)
}

const USAGE: &str = "eider 0.1.0 (compiler: Eider -> C11)

usage:
  eider check <file.ei> [--json]          type-check only
  eider emit-c <file.ei>                  print generated C
  eider emit-header <file.ei>             print the C header for `export fn`s
  eider build <file.ei> [-o out] [-l lib] compile to a native binary via $CC (default: cc)
  eider build --lib <file.ei> [-o name]   build lib<name>.a, lib<name>.so and <name>.h from `export fn`s
  eider build --wasm <file.ei> [-o name]  build <name>.wasm, <name>.d.ts and <name>.js (loader) from `export fn`s
  eider run <file.ei> [--release]         build and run (-O0 unless --release; `build` is always -O2)
  eider test <file.ei>                    run `test` blocks
  eider test --compile-fail <dir>         run the compile-fail suite (<dir>/fail, <dir>/pass)
";

fn report(d: &Diag, file: &str, src: &str, json: bool) {
    let mut d = d.clone();
    d.msg = ns::demangle(&d.msg);
    d.help = d.help.map(|h| ns::demangle(&h));
    let d = &d;
    if json {
        println!("{}", d.json(file));
        return;
    }
    match &d.file {
        Some(f) if f != file => {
            let other = std::fs::read_to_string(f).unwrap_or_default();
            eprint!("{}", d.render(f, &other));
        }
        _ => eprint!("{}", d.render(file, src)),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut json = false;
    let mut lib = false;
    let mut wasm = false;
    let mut compile_fail = false;
    let mut out_opt: Option<String> = None;
    let mut libs: Vec<String> = vec![];
    let mut pos: Vec<String> = vec![];
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => json = true,
            "--lib" => lib = true,
            "--wasm" => wasm = true,
            "--release" => std::env::set_var("EIDER_RELEASE", "1"),
            "--compile-fail" => compile_fail = true,
            "-o" => {
                i += 1;
                out_opt = args.get(i).cloned();
            }
            "-l" => {
                i += 1;
                if let Some(l) = args.get(i) {
                    libs.push(l.clone());
                }
            }
            a => pos.push(a.to_string()),
        }
        i += 1;
    }
    let cmd = match pos.first() {
        Some(c) => c.as_str(),
        None => {
            print!("{}", USAGE);
            exit(2);
        }
    };
    match cmd {
        "test" if compile_fail => {
            let dir = pos.get(1).map(|s| s.as_str()).unwrap_or("tests/checks");
            exit(run_compile_fail(Path::new(dir)));
        }
        "check" | "emit-c" | "emit-header" | "build" | "run" | "test" => {
            let file = match pos.get(1) {
                Some(f) => f.as_str(),
                None => {
                    print!("{}", USAGE);
                    exit(2);
                }
            };
            let src = std::fs::read_to_string(file).unwrap_or_else(|e| {
                eprintln!("eider: cannot read {}: {}", file, e);
                exit(2)
            });
            let mode = if cmd == "test" {
                Mode::Test
            } else if wasm {
                Mode::Wasm
            } else if lib || cmd == "emit-header" {
                Mode::Lib
            } else {
                Mode::Build
            };
            let (c, header) = match compile_full(&src, file, mode) {
                Ok(c) => c,
                Err(d) => {
                    report(&d, file, &src, json);
                    exit(1);
                }
            };
            match cmd {
                "check" => {
                    if !json {
                        println!("ok");
                    }
                }
                "emit-c" => print!("{}", c),
                "emit-header" => print!("{}", header),
                _ if wasm => {
                    let stem = out_opt.clone().unwrap_or_else(|| Path::new(file).file_stem().unwrap().to_string_lossy().to_string());
                    exit(build_wasm(&c, &header, &stem));
                }
                _ if lib => {
                    let stem = out_opt.clone().unwrap_or_else(|| Path::new(file).file_stem().unwrap().to_string_lossy().to_string());
                    exit(build_lib(&c, &header, &stem, &libs));
                }
                _ => {
                    let out = out_opt.clone().unwrap_or_else(|| {
                        let stem = Path::new(file).file_stem().unwrap().to_string_lossy().to_string();
                        std::env::temp_dir().join(format!("eider_{}_{}", stem, std::process::id())).to_string_lossy().to_string()
                    });
                    exit(build_and_maybe_run(&c, file, &out, cmd == "run" || cmd == "test", &libs));
                }
            }
        }
        _ => {
            print!("{}", USAGE);
            exit(2);
        }
    }
}

fn cc_cmd() -> String {
    std::env::var("CC").unwrap_or_else(|_| "cc".to_string())
}

/// Compile to `<stem>.wasm`, plus `<stem>.d.ts` and `<stem>.js` (loader). Needs clang with the wasm32 target and wasm-ld.
fn build_wasm(c: &str, ts: &str, stem: &str) -> i32 {
    let dir = std::env::temp_dir().join(format!("eider_wasm_{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    for (n, body) in wasm_shim::FILES {
        std::fs::write(dir.join(n), body).expect("write shim header");
    }
    let shim = dir.join("shim.c");
    std::fs::write(&shim, wasm_shim::SHIM_C).expect("write shim");
    let gen = dir.join("gen.c");
    std::fs::write(&gen, c).expect("write C");
    let clang = std::env::var("WASM_CC").unwrap_or_else(|_| "clang".to_string());
    let wasm = format!("{}.wasm", stem);
    let st = Command::new(&clang)
        .args(["--target=wasm32", "-std=c11", "-O2", "-ffreestanding", "-nostdlib", "-fno-builtin", "-Wno-unused-function", "-Wno-unused-variable", "-isystem"])
        .arg(&dir)
        .args(["-Wl,--no-entry", "-Wl,--allow-undefined", "-o", &wasm])
        .arg(&gen)
        .arg(&shim)
        .status();
    let ok = matches!(st, Ok(s) if s.success());
    let _ = std::fs::remove_dir_all(&dir);
    if !ok {
        eprintln!("eider: wasm build failed (needs clang with the wasm32 target and wasm-ld; set WASM_CC to override)");
        return 3;
    }
    let base = Path::new(&wasm).file_name().unwrap().to_string_lossy().to_string();
    let (dts, js) = ts.split_once('\u{1}').unwrap_or((ts, ""));
    std::fs::write(format!("{}.d.ts", stem), dts).expect("write d.ts");
    std::fs::write(format!("{}.js", stem), js.replace("@WASM@", &base)).expect("write js");
    println!("built {}, {}.d.ts, {}.js", wasm, stem, stem);
    0
}

fn build_lib(c: &str, header: &str, stem: &str, libs: &[String]) -> i32 {
    let cfile = format!("{}.eider.c", stem);
    let hfile = format!("{}.h", stem);
    std::fs::write(&cfile, c).expect("write C file");
    std::fs::write(&hfile, header).expect("write header");
    let cc = cc_cmd();
    let base = Path::new(stem);
    let name = base.file_name().unwrap().to_string_lossy().to_string();
    let dir = base.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let obj = format!("{}.o", stem);
    let a = dir.join(format!("lib{}.a", name)).to_string_lossy().to_string();
    let so = dir.join(format!("lib{}.so", name)).to_string_lossy().to_string();
    let ok = |r: std::io::Result<std::process::ExitStatus>| matches!(r, Ok(s) if s.success());
    if !ok(Command::new(&cc).args(["-std=c11", "-O2", "-fPIC", "-pthread", "-Wall", "-Wno-unused-function", "-Wno-unused-variable", "-c", "-o", &obj, &cfile]).status()) {
        eprintln!("eider: internal error: generated C failed to compile (kept at {})", cfile);
        return 3;
    }
    let _ = std::fs::remove_file(&a);
    if !ok(Command::new("ar").args(["rcs", &a, &obj]).status()) {
        eprintln!("eider: `ar` failed");
        return 3;
    }
    let mut so_cmd = Command::new(&cc);
    so_cmd.args(["-shared", "-pthread", "-o", &so, &obj]);
    for l in libs {
        so_cmd.arg(format!("-l{}", l));
    }
    if !ok(so_cmd.status()) {
        eprintln!("eider: linking the shared library failed");
        return 3;
    }
    let _ = std::fs::remove_file(&obj);
    let _ = std::fs::remove_file(&cfile);
    println!("built {}, {}, {}", a, so, hfile);
    0
}

fn fnv64(parts: &[&str]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for p in parts {
        for b in p.bytes().chain(std::iter::once(0u8)) {
            h ^= b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
    }
    h
}

/// Binary cache keyed by (generated C, compiler, flags): unchanged programs skip the C compiler.
/// `EIDER_CACHE=off` disables it; `EIDER_CACHE=<dir>` relocates it.
fn cache_dir() -> Option<PathBuf> {
    match std::env::var("EIDER_CACHE").ok().as_deref() {
        Some("off") => None,
        Some(d) => Some(PathBuf::from(d)),
        None => {
            let base = std::env::var("XDG_CACHE_HOME").map(PathBuf::from).or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".cache")));
            Some(base.unwrap_or_else(|_| std::env::temp_dir()).join("eider"))
        }
    }
}

fn build_and_maybe_run(c: &str, file: &str, out: &str, run: bool, libs: &[String]) -> i32 {
    // the runtime reports the .ei file name in traps
    let c = c.replace("ei_file = \"program\";", &format!("ei_file = \"{}\";", file.replace('\\', "/")));
    let c = if c.contains("int main(void) {\n  int total") {
        c.replace("ei_jb = &jb;", &format!("ei_jb = &jb; ei_file = \"{}\";", file.replace('\\', "/")))
    } else {
        c
    };
    let cc = cc_cmd();
    // `run`/`test` favour turnaround (-O0, ~4x faster C compile); `build` and `--release` optimize
    let opt = if run && std::env::var("EIDER_RELEASE").is_err() { "-O0" } else { "-O2" };
    let flags = ["-std=c11", opt, "-Wall", "-Wno-unused-function", "-Wno-unused-variable", "-pthread"];
    let key = format!("{:016x}", fnv64(&[&cc, &flags.join(" "), &libs.join(" "), &c]));
    let cached = cache_dir().map(|d| d.join(&key));
    let mut exe = out.to_string();
    if let Some(p) = &cached {
        if p.exists() {
            exe = p.to_string_lossy().to_string();
            if !run {
                let _ = std::fs::copy(p, out);
            }
            return if run { Command::new(&exe).status().map(|s| s.code().unwrap_or(1)).unwrap_or(1) } else { 0 };
        }
    }
    let cfile = format!("{}.c", out);
    std::fs::write(&cfile, &c).expect("write C file");
    let mut cmd = Command::new(&cc);
    cmd.args(flags).args(["-o", out, &cfile]);
    for l in libs {
        cmd.arg(format!("-l{}", l));
    }
    match cmd.status() {
        Ok(s) if s.success() => {}
        Ok(_) => {
            eprintln!("eider: internal error: generated C failed to compile (kept at {})", cfile);
            return 3;
        }
        Err(e) => {
            eprintln!("eider: cannot run C compiler `{}`: {} (set $CC)", cc, e);
            return 3;
        }
    }
    let _ = std::fs::remove_file(&cfile);
    if let Some(p) = &cached {
        if let Some(d) = p.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let tmp = p.with_extension(format!("tmp{}", std::process::id()));
        if std::fs::copy(out, &tmp).is_ok() {
            let _ = std::fs::rename(&tmp, p);
        }
    }
    if run {
        let code = Command::new(&exe).status().map(|s| s.code().unwrap_or(1)).unwrap_or(1);
        let _ = std::fs::remove_file(out);
        code
    } else {
        0
    }
}

// ------------------------------------------------------------------ compile-fail suite
fn ei_files(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().map(|x| x == "ei").unwrap_or(false)).collect())
        .unwrap_or_default();
    v.sort();
    v
}

/// Each fail file starts with `// expect: E0101 3:3`.
fn run_compile_fail(dir: &Path) -> i32 {
    let (mut pass, mut fail) = (0, 0);
    let mut seen: HashSet<String> = HashSet::new();
    println!("compile-fail tests ({}/fail)", dir.display());
    for f in ei_files(&dir.join("fail")) {
        let name = f.file_name().unwrap().to_string_lossy().to_string();
        let src = std::fs::read_to_string(&f).unwrap();
        let expect = src.lines().next().and_then(|l| l.strip_prefix("// expect:")).map(|s| s.trim().to_string());
        let (code, at) = match expect.as_deref().map(|s| s.split_whitespace().collect::<Vec<_>>()) {
            Some(p) if p.len() == 2 => (p[0].to_string(), p[1].to_string()),
            _ => {
                println!("  FAIL {:<28} missing `// expect: CODE LINE:COL` header", name);
                fail += 1;
                continue;
            }
        };
        let mode = if src.contains("// mode: test") { Mode::Test } else if src.contains("// mode: wasm") { Mode::Wasm } else { Mode::Build };
        match compile_src(&src, &f.to_string_lossy(), mode) {
            Ok(_) => {
                println!("  FAIL {:<28} compiled, expected {} at {}", name, code, at);
                fail += 1;
            }
            Err(d) => {
                let got_at = format!("{}:{}", d.pos.line, d.pos.col);
                if d.code != code || got_at != at {
                    println!("  FAIL {:<28} expected {} at {}, got {} at {}: {}", name, code, at, d.code, got_at, d.msg);
                    fail += 1;
                    continue;
                }
                seen.insert(code.clone());
                // fix round-trip: applying the suggested fix must remove this exact error
                let mut note = String::new();
                if let Some(fx) = &d.fix {
                    let fixed = apply_fix(&src, fx);
                    match compile_src(&fixed, &f.to_string_lossy(), mode) {
                        Ok(_) => note = " (fix compiles)".into(),
                        Err(d2) if d2.code != d.code || d2.pos != d.pos => note = format!(" (fix resolves it; next: {})", d2.code),
                        Err(_) => {
                            println!("  FAIL {:<28} suggested fix does not resolve {}", name, d.code);
                            fail += 1;
                            continue;
                        }
                    }
                }
                println!("  ok   {:<28} {} at {}{}", name, code, at, note);
                pass += 1;
            }
        }
    }
    println!("\ncompile-pass tests ({}/pass)", dir.display());
    for f in ei_files(&dir.join("pass")) {
        let name = f.file_name().unwrap().to_string_lossy().to_string();
        let src = std::fs::read_to_string(&f).unwrap();
        let mode = if src.contains("// mode: test") { Mode::Test } else if src.contains("// mode: wasm") { Mode::Wasm } else { Mode::Build };
        match compile_src(&src, &f.to_string_lossy(), mode) {
            Ok(_) => {
                println!("  ok   {}", name);
                pass += 1;
            }
            Err(d) => {
                println!("  FAIL {:<28} rejected valid code: {} {}", name, d.code, d.msg);
                fail += 1;
            }
        }
    }
    let missing: Vec<&&str> = ALL_CODES.iter().filter(|c| !seen.contains(**c)).collect();
    println!("\n{} passed, {} failed; error-code coverage {}/{}", pass, fail, ALL_CODES.len() - missing.len(), ALL_CODES.len());
    if !missing.is_empty() {
        println!("codes without a compile-fail test: {}", missing.iter().map(|s| **s).collect::<Vec<_>>().join(" "));
    }
    if fail > 0 {
        1
    } else {
        0
    }
}
